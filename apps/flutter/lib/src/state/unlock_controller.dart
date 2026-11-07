/// Runs the unlock checks and owns their results.
///
/// Two things make this a controller rather than page state:
///
///  * a full sweep takes tens of seconds, and switching to another page and
///    back must not abort it or lose what already arrived;
///  * the results outlive the session, so they are handed to a persistence
///    callback the moment a sweep ends instead of on dispose.
///
/// Verdicts are never merged with latency or reachability: those live in the
/// node table. This page answers a different question about the same exit.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'unlock.dart';
import 'unlock_checks.dart';

class UnlockController extends ChangeNotifier {
  UnlockController({
    required this.proxyResolver,
    this.nodeResolver,
    this.onPersist,
    UnlockHttp Function(String proxy)? httpFactory,
    this.concurrency = 4,
    this.checkTimeout = const Duration(seconds: 25),
  }) : _httpFactory = httpFactory ?? _defaultHttp,
       _specs = defaultUnlockChecks(),
       _results = {for (final item in pendingUnlockItems()) item.id: item};

  /// Where the checks should connect, or null/empty when there is nothing to
  /// check through. The core has to be running: the endpoint is its mixed
  /// inbound, and a request that bypassed it would report this machine's region
  /// as if it were the node's.
  final String? Function() proxyResolver;

  /// The node the requests will traverse. Recorded with the verdicts so a later
  /// node switch is visible instead of hidden behind a header naming the new
  /// node above cards describing the old one.
  final ({String id, String name})? Function()? nodeResolver;

  /// Called with the results whenever a sweep finishes or is cancelled, so a
  /// partially completed sweep is still worth keeping.
  final void Function(UnlockSnapshot snapshot)? onPersist;

  final UnlockHttp Function(String proxy) _httpFactory;
  final List<UnlockCheckSpec> _specs;
  final Map<String, UnlockItem> _results;

  /// How many checks run at once. The reference client uses four; more would
  /// have several services rate-limiting the same exit at the same time and
  /// turn a slow answer into a false "Failed".
  final int concurrency;

  /// Per-check ceiling. A service that never answers must not hold the sweep
  /// open, and 25 s is comfortably above the slowest healthy handshake
  /// (Disney+'s three-step token exchange).
  final Duration checkTimeout;

  final Set<String> _running = {};

  /// Bumped by [cancel]. A worker whose generation is stale drops its result
  /// instead of painting it over the sweep that replaced it.
  int _generation = 0;
  UnlockHttp? _http;
  String? _error;
  String? _checkedNodeId;
  String? _checkedNodeName;

  static UnlockHttp _defaultHttp(String proxy) => IoUnlockHttp(proxy: proxy);

  List<UnlockItem> get items => [for (final spec in _specs) _results[spec.id]!];

  bool get running => _running.isNotEmpty;
  int get runningCount => _running.length;
  bool isChecking(String id) => _running.contains(id);

  int get total => _specs.length;
  int get checkedCount => items.where((item) => !item.isPending).length;

  /// How many services currently hold a verdict of each tone.
  ///
  /// The page needs this to answer "is this node any good?" without asking the
  /// reader to count thirteen colour-coded cards. A pending card is excluded:
  /// not having tested something is not a failure.
  Map<UnlockTone, int> get toneCounts {
    final counts = <UnlockTone, int>{};
    for (final item in items) {
      if (item.isPending) continue;
      final tone = unlockTone(item.status);
      counts[tone] = (counts[tone] ?? 0) + 1;
    }
    return counts;
  }

  /// True once every service has a verdict, so the page can say the list is
  /// complete without recomputing it per card.
  bool get complete => items.every((item) => !item.isPending);

  String? get error => _error;

  int get lastCheckedAtMs => items.fold(
    0,
    (latest, item) => item.checkedAtMs > latest ? item.checkedAtMs : latest,
  );

  /// Merges stored results in, keeping the catalogue's order and leaving any
  /// service the stored list does not mention as 未检测.
  void restore(UnlockSnapshot snapshot) {
    for (final item in snapshot.items) {
      if (!_results.containsKey(item.id)) continue;
      _results[item.id] = item;
    }
    _checkedNodeId = snapshot.nodeId;
    _checkedNodeName = snapshot.nodeName;
    notifyListeners();
  }

  /// The node the current verdicts describe, when it is known.
  String? get checkedNodeId => _checkedNodeId;
  String? get checkedNodeName => _checkedNodeName;

  /// True when the list describes some *other* node than the active one.
  ///
  /// The page says so rather than clearing the results: the previous node's
  /// verdicts are still informative ("that node unlocked Netflix, this one may
  /// not"), and silently wiping them would look like the check had never run.
  bool staleFor(String? activeNodeId) {
    if (activeNodeId == null || activeNodeId.isEmpty) return false;
    if (checkedCount == 0) return false;
    final checked = _checkedNodeId;
    if (checked == null || checked.isEmpty) return false;
    return checked != activeNodeId;
  }

  UnlockSnapshot _snapshot() => UnlockSnapshot(
    items: items,
    nodeId: _checkedNodeId,
    nodeName: _checkedNodeName,
  );

  Future<void> checkAll() async {
    final proxy = proxyResolver();
    if (proxy == null || proxy.isEmpty) {
      _error = '还没有可用的代理端口：先在「节点」页启用一个节点并启动内核';
      notifyListeners();
      return;
    }
    _error = null;
    // Recorded before the first request: if the user switches node mid-sweep,
    // the results then describe the node they started on and the page can say
    // the list no longer matches.
    _rememberNode();
    final generation = ++_generation;
    _running
      ..clear()
      ..addAll(_specs.map((spec) => spec.id));
    notifyListeners();

    final http = _httpFactory(proxy);
    _http = http;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (_generation != generation || next >= _specs.length) return;
        final spec = _specs[next++];
        await _run(spec, http, generation);
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < concurrency && i < _specs.length; i++) worker(),
    ];
    await Future.wait(workers);
    _http = null;
    http.close();
    if (_generation != generation) return;
    _running.clear();
    onPersist?.call(_snapshot());
    notifyListeners();
  }

  Future<void> checkOne(String id) async {
    final spec = _specs.where((spec) => spec.id == id).firstOrNull;
    if (spec == null || _running.contains(id)) return;
    final proxy = proxyResolver();
    if (proxy == null || proxy.isEmpty) {
      _error = '还没有可用的代理端口：先在「节点」页启用一个节点并启动内核';
      notifyListeners();
      return;
    }
    _error = null;
    _rememberNode();
    final generation = _generation;
    _running.add(id);
    notifyListeners();
    final http = _httpFactory(proxy);
    try {
      await _run(spec, http, generation);
    } finally {
      http.close();
      if (_generation == generation) onPersist?.call(_snapshot());
    }
  }

  /// Stops the sweep. Requests already in flight are aborted by closing the
  /// shared client, because waiting for a 25 s timeout per service is not what
  /// "停止" means to the person who pressed it.
  void cancel() {
    if (_running.isEmpty) return;
    _generation++;
    _running.clear();
    _http?.close();
    _http = null;
    onPersist?.call(_snapshot());
    notifyListeners();
  }

  /// Records which node the requests will traverse.
  ///
  /// A null [nodeResolver] (tests, and any caller that does not track a node)
  /// leaves the previous value alone rather than clearing it: forgetting which
  /// node a list describes is worse than the list being unlabelled.
  void _rememberNode() {
    final node = nodeResolver?.call();
    if (node == null) return;
    _checkedNodeId = node.id;
    _checkedNodeName = node.name;
  }

  Future<void> _run(
    UnlockCheckSpec spec,
    UnlockHttp http,
    int generation,
  ) async {
    if (_generation != generation) return;
    UnlockVerdict verdict;
    try {
      verdict = await spec.run(http).timeout(checkTimeout);
    } on Object {
      // A check that threw is reported as failed rather than dropped: a card
      // that silently returns to 未检测 cannot be distinguished from one that
      // was never asked.
      verdict = const UnlockVerdict(UnlockStatus.failed);
    }
    if (_generation != generation) return;
    _results[spec.id] = UnlockItem(
      id: spec.id,
      name: spec.name,
      status: verdict.status,
      region: verdict.region,
      checkedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _running.remove(spec.id);
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    _http?.close();
    _http = null;
    super.dispose();
  }
}
