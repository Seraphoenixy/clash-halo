import 'dart:async';
import 'dart:io' show pid;

import 'package:halo_config/halo_config.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// Owns one speed-test batch: its task id, the pending set, and the per-metric
/// result maps.
///
/// Events from a superseded batch are dropped here rather than in the page,
/// because the host keeps probing after a cancel and those late results would
/// otherwise be painted over the batch that replaced them.
class SpeedBatchTracker {
  SpeedBatchTracker({
    required this.command,
    required this.loadNodes,
    required this.storedConcurrency,
  });

  /// Sends one host command; the result must be the `speedtest.start` map.
  final Future<Map<String, Object?>> Function(
    String action,
    Map<String, Object?> params,
    Duration timeout,
  )
  command;

  final List<ProxyNode> Function() loadNodes;

  /// The stored concurrency preference, used when the caller passes 0.
  final int Function() storedConcurrency;

  final StreamController<SpeedResult> _updates =
      StreamController<SpeedResult>.broadcast();

  String? _taskId;
  final Set<String> _pending = <String>{};
  int _batchTotal = 0;
  SpeedMetric? _batchMetric;

  /// Latest latency per node.
  final Map<String, SpeedResult> results = {};

  /// Download throughput per node, kept separate from [results] on purpose: a
  /// node has one latency and one throughput at once.
  final Map<String, SpeedResult> downloadResults = {};

  /// TCP/UDP reachability per node, one entry per transport.
  final Map<String, Map<SpeedMetric, SpeedResult>> reachability = {};

  Stream<SpeedResult> get updates => _updates.stream;

  Set<String> get pending => Set<String>.unmodifiable(_pending);

  int get batchTotal => _batchTotal;

  SpeedMetric? get batchMetric => _batchMetric;

  String? get taskId => _taskId;

  bool get running => _pending.isNotEmpty;

  SpeedResult? reachabilityOf(String nodeId, SpeedMetric metric) =>
      reachability[nodeId]?[metric];

  /// Drops every measurement for one node (used when it is deleted).
  void forgetNode(String nodeId) {
    results.remove(nodeId);
    downloadResults.remove(nodeId);
    reachability.remove(nodeId);
  }

  /// Prepares the pending set and clears only the metric this run will fill.
  ///
  /// Shared by the host-driven [start] and the Android local runner so both
  /// paths keep the same "one batch at a time" state in the UI.
  String _beginBatch({
    required List<ProxyNode> selected,
    required SpeedMetric metric,
    required bool allNodes,
  }) {
    final taskId = 'speed-$pid-${DateTime.now().microsecondsSinceEpoch}';
    _taskId = taskId;
    final scoped = {for (final node in selected) node.id};
    _pending
      ..clear()
      ..addAll(scoped);
    _batchTotal = scoped.length;
    _batchMetric = metric;

    void forgetScoped(
      void Function(String id) remove,
      void Function() clearAll,
    ) {
      if (allNodes) {
        clearAll();
        return;
      }
      for (final id in scoped) {
        remove(id);
      }
    }

    switch (metric) {
      case SpeedMetric.download:
        forgetScoped(downloadResults.remove, downloadResults.clear);
      case SpeedMetric.tcp:
      case SpeedMetric.udp:
        forgetScoped((id) => reachability[id]?.remove(metric), () {
          for (final entry in reachability.values) {
            entry.remove(metric);
          }
        });
      case SpeedMetric.proxyLatency:
        forgetScoped(results.remove, results.clear);
    }
    return taskId;
  }

  /// Registers a local Android batch and returns its task id.
  ///
  /// The caller runs the probes and reports each terminal result through
  /// [recordLocalResult]; this keeps the node page, watchdog and result maps on
  /// the same contract as a host batch.
  String beginLocalBatch({
    required List<ProxyNode> selected,
    required SpeedMetric metric,
    bool allNodes = false,
  }) => _beginBatch(selected: selected, metric: metric, allNodes: allNodes);

  void recordLocalResult(SpeedResult result) {
    _store(result);
    _pending.remove(result.nodeId);
    if (!_updates.isClosed) _updates.add(result);
  }

  void finishLocalBatch() {
    _taskId = null;
    clearBatch();
  }

  /// Starts a batch and returns the host-assigned task id.
  Future<String> start({
    List<String> nodeIds = const [],
    List<String> endpoints = const [],
    SpeedMetric metric = SpeedMetric.proxyLatency,
    String url = '',
    int timeoutMs = 0,
    int concurrency = 0,
  }) async {
    // Registering the id before the call keeps the first `task.progress` (which
    // can arrive before the response does) attributed to this batch.
    final requestedIds = nodeIds.toSet();
    final selected = loadNodes()
        .where((n) => requestedIds.isEmpty || requestedIds.contains(n.id))
        .toList();
    final taskId = _beginBatch(
      selected: selected,
      metric: metric,
      allNodes: nodeIds.isEmpty,
    );

    final configs = <String>[];
    // A local copy: `endpoints` defaults to a const list, so appending to it
    // would throw at runtime the first time a TCP run needed to fill it in.
    final targets = List<String>.of(endpoints);
    if (targets.isEmpty) {
      if (selected.isEmpty) throw StateError('没有可测速的节点');
      if (metric == SpeedMetric.tcp) {
        // A TCP check talks to the node's own port; no core or generated config
        // is needed, and building one would cost a second per node.
        targets.addAll(selected.map((n) => n.endpoint));
      } else {
        for (final node in selected) {
          final built = buildConfig(
            ConfigRequest(
              node: node,
              mode: RouteMode.global,
              ports: const InboundPorts(enableClashApi: false),
            ),
            CoreCapabilities.singbox114,
          );
          if (!built.ok) {
            throw StateError(
              '${node.name}: ${built.issues.map((i) => i.message).join('；')}',
            );
          }
          configs.add(built.config!.toJsonString());
        }
      }
    }

    Map<String, Object?> result;
    try {
      result = await command(HaloAction.speedTestStart, {
        'taskId': taskId,
        'metric': metric.wire,
        'nodeIds': configs.isNotEmpty
            ? selected.map((n) => n.id).toList()
            : nodeIds,
        if (configs.isNotEmpty) 'configs': configs,
        if (targets.isNotEmpty) 'endpoints': targets,
        if (url.isNotEmpty) 'url': url,
        // Omitted when unset: an explicit 0 would still be a value the host
        // has to special-case, and its per-metric default is what we want.
        if (timeoutMs > 0) 'timeoutMs': timeoutMs,
        'concurrency': _effectiveConcurrency(
          metric == SpeedMetric.download && concurrency <= 0 ? 1 : concurrency,
        ),
      }, const Duration(seconds: 15));
    } catch (_) {
      clearBatch();
      rethrow;
    }
    final started = '${result['taskId'] ?? ''}';
    if (started.isNotEmpty && started != taskId) {
      // The host answers with the id it actually runs under.
      _taskId = started;
    }
    if (started.isEmpty) clearBatch();
    return started;
  }

  Future<void> cancel(String taskId) async {
    await command(HaloAction.taskCancel, {
      'taskId': taskId,
    }, const Duration(seconds: 30));
    if (taskId == _taskId) {
      _taskId = null;
      clearBatch();
    }
  }

  /// Handles one task event. Returns true when the caller should repaint the
  /// coarse runtime channel (a batch finished).
  bool onTaskEvent(HaloEventMessage event) {
    // Events from a superseded batch are dropped: `task.started` claims the id,
    // a stopped/finished batch releases it.
    final eventTask = event.data['taskId'];
    final started = event.name == HaloEvent.taskStarted;
    if (eventTask is String && eventTask.isNotEmpty) {
      if (started) {
        _taskId = eventTask;
      } else if (eventTask != _taskId) {
        return false;
      }
    }
    final results = event.data['results'] is List
        ? event.data['results'] as List
        : [event.data['result'] ?? event.data];
    for (final raw in results) {
      final result = _parseResult(raw);
      if (result == null) continue;
      _store(result);
      _pending.remove(result.nodeId);
      if (!_updates.isClosed) _updates.add(result);
    }
    if (event.name == HaloEvent.taskFinished) {
      final finishesCurrent =
          eventTask is! String || eventTask.isEmpty || eventTask == _taskId;
      if (finishesCurrent) {
        _taskId = null;
        clearBatch();
      }
      return true;
    }
    return false;
  }

  /// Replaces the local view with the host's session snapshot.
  ///
  /// The host outlives the window, so this is what makes a reopened node page
  /// show the readings and the still-running batch that were produced while no
  /// window existed. The host is authoritative here: a new host starts with an
  /// empty session, and that empty snapshot must also clear this view.
  void hydrateSession({
    required bool running,
    String? taskId,
    SpeedMetric? metric,
    required int total,
    required List<String> pending,
    required List<Map<String, Object?>> results,
  }) {
    this.results.clear();
    downloadResults.clear();
    reachability.clear();
    for (final raw in results) {
      final result = _parseResult(
        raw,
        fallbackMetric: metric ?? SpeedMetric.proxyLatency,
      );
      if (result != null) _store(result);
    }
    _taskId = running ? taskId : null;
    _batchMetric = running ? metric : null;
    _batchTotal = running ? total : 0;
    _pending.clear();
    if (running) _pending.addAll(pending);
  }

  SpeedResult? _parseResult(
    Object? raw, {
    SpeedMetric fallbackMetric = SpeedMetric.proxyLatency,
  }) {
    if (raw is! Map || raw['nodeId'] is! String) return null;
    // The host states which quantity it measured; guessing proxyLatency let a
    // throughput reading be stored in the latency slot.
    final metric = raw['metric'] is String
        ? SpeedMetric.fromWire(raw['metric'] as String)
        : fallbackMetric;
    return raw.containsKey('status')
        ? SpeedResult.fromJson(
            raw.cast<String, Object?>(),
            // The event already told us what was measured; a payload that
            // omits `metric` must not be re-guessed as TCP.
            fallbackMetric: metric,
          )
        : SpeedResult(
            nodeId: raw['nodeId'] as String,
            metric: metric,
            status: raw['ok'] == true
                ? SpeedStatus.ok
                : raw['errorCode'] == 'canceled'
                ? SpeedStatus.canceled
                : raw['errorCode'] == 'not_applicable'
                ? SpeedStatus.notApplicable
                // UDP silence is not a verdict: a filtered port and a
                // dead node look identical.
                : raw['errorCode'] == 'udp_unconfirmed'
                ? SpeedStatus.notApplicable
                : SpeedStatus.failed,
            // A throughput reading is not a delay.
            valueMs: metric == SpeedMetric.download
                ? null
                : (raw['latencyMs'] as num?)?.toInt(),
            bytesPerSecond: (raw['downloadBps'] as num?)?.toInt(),
            errorCode: raw['errorCode'] as String?,
            errorMessage: raw['errorMsg'] as String?,
          );
  }

  void clearBatch() {
    _pending.clear();
    _batchTotal = 0;
    _batchMetric = null;
  }

  Future<void> dispose() => _updates.close();

  void _store(SpeedResult result) {
    switch (result.metric) {
      case SpeedMetric.download:
        downloadResults[result.nodeId] = result;
      case SpeedMetric.tcp:
      case SpeedMetric.udp:
        (reachability[result.nodeId] ??= {})[result.metric] = result;
      case SpeedMetric.proxyLatency:
        results[result.nodeId] = result;
    }
  }

  int _effectiveConcurrency(int requested) {
    final stored = storedConcurrency();
    return clampConcurrency(requested > 0 ? requested : stored);
  }

  /// Bounds a concurrency value to what the host accepts.
  static int clampConcurrency(int value) {
    if (value < 1) return 1;
    if (value > 32) return 32;
    return value;
  }
}
