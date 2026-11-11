import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart' show kLocalProfileId;

import '../../state/app_controller.dart';
import '../../theme.dart';
import '../app.dart';
import '../widgets.dart';
import '../widgets/table_columns.dart';
import '../widgets/measurement.dart';

/// The node list: the one page where nodes are inspected, tested and enabled.
///
/// ## What changed and why
///
/// The previous version was already a table, but it was a table with one way in:
/// a flat list of every node, a permanent checkbox gutter, and an "启用" button
/// on every row. With two subscriptions and a hundred nodes it became a wall of
/// checkboxes where the two things users actually do — *find the group I care
/// about* and *see which node is live* — were the hardest things to see.
///
/// This version follows v2rayN's server list where it earns its keep:
///
///  1. **Subscription groups are chips above the table**, first chip "全部", and
///     the choice is remembered. Switching groups is one click, not a trip to
///     another page.
///  2. **Selection is the row, not a checkbox.** Click selects, Ctrl+click adds,
///     Shift+click extends. The checkbox gutter is gone, which is what makes the
///     table readable; batch actions live in the toolbar and the context menu.
///  3. **The live node is marked, not coloured like a selection.** A 3px accent
///     bar plus a "使用中" badge. Selection keeps its own fill, so a multi-select
///     batch edit can never be mistaken for a proxy switch.
///  4. **Latency is a sortable column with one colour semantic**, and rows under
///     test say "测试中…" instead of showing a stale number.
///  5. **Keys for the whole workflow**: Enter enables, Delete removes, Ctrl+A
///     selects all, Ctrl+F searches, Ctrl+C copies the share link, Esc stops the
///     run.
///
/// Deliberately not copied from v2rayN: the row-number gutter, the four traffic
/// columns (this app has no per-node accounting, and empty columns are worse than
/// no columns), and the "press Enter to search" behaviour, which hides the
/// result of typing.
class NodesPage extends StatefulWidget {
  const NodesPage({
    super.key,
    required this.controller,
    this.onOpenSubscriptions,
  });

  final AppController controller;

  /// Sends the user to the import page from the empty state.
  final VoidCallback? onOpenSubscriptions;

  @override
  State<NodesPage> createState() => _NodesPageState();
}

/// Sentinel for the 本地 chip: nodes imported locally rather than downloaded.
///
/// It cannot collide with a profile id, which is generated as
/// `sub_<microseconds>` — but it also no longer means "profile_id IS NULL",
/// since the local nodes belong to the built-in 本地 subscription.
const String _kLocalGroup = '__local__';

/// Prefix for a group chip's filter value, so one string field can carry
/// "all", "local", "one profile" and "one group" without a second enum.
const String _kGroupPrefix = 'grp:';

class _NodesPageState extends State<NodesPage> {
  /// Touch needs to drag the table horizontally to reach the right-hand
  /// columns. On desktop the drag is left to the header's resize handles.
  Set<PointerDeviceKind> _tableDragDevices(BuildContext context) =>
      haloTouchPlatform(context)
      ? const {PointerDeviceKind.touch, PointerDeviceKind.stylus}
      : const {};

  final Set<String> _selected = <String>{};

  /// Anchor for Shift+click range selection, in the current visible order.
  String? _anchorId;

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _tableFocus = FocusNode();

  String _query = '';
  ProxyProtocol? _protocolFilter;

  /// null = all nodes, otherwise only rows matching this measurement state.
  ///
  /// The point of measuring every node is to act on the result: after a batch
  /// the user wants "the ones that answered", "the ones that timed out", or
  /// "the ones I have not measured yet" — usually to delete the dead ones or
  /// select the good ones. Sorting by latency finds the fastest single node
  /// but cannot express "hide the failures".
  LatencyFilter? _latencyFilter;

  /// null = all groups, [_kLocalGroup] = local nodes, otherwise a profile id.
  String? _groupFilter;

  _SortColumn _sortColumn = _SortColumn.name;
  bool _sortAscending = true;

  /// Column widths, shared by the header and every row. Owned here so a drag
  /// on the header immediately re-lays out the body.
  final _ColumnWidths _widths = _ColumnWidths();

  /// The filtered and sorted list, cached across rebuilds. See
  /// [visibleNodes] and [_computeVisible].
  List<ProxyNode>? _visibleCache;
  List<ProxyNode>? _visibleSource;
  bool _visibleDirty = true;

  /// Lowercased display names keyed by node id, rebuilt when the catalog
  /// list identity changes, so the name sort stops calling toLowerCase()
  /// O(n log n) times per sort.
  Map<String, String> _nameKeys = const {};
  List<ProxyNode>? _nameKeysSource;

  /// Whether the current filter or sort actually reads the measurement maps.
  /// When it does not, an incoming speed result invalidates nothing — this is
  /// what keeps a batch run on a name-sorted table from re-sorting per result.
  bool get _visibleDependsOnMeasurements =>
      _latencyFilter != null ||
      _sortColumn == _SortColumn.latency ||
      _sortColumn == _SortColumn.reachability ||
      _sortColumn == _SortColumn.throughput;

  /// An enable/delete/test start is in flight. Row actions lock so a double
  /// click cannot start two config writes.
  bool _busy = false;

  /// A latency batch is running. Kept apart from [_busy] so testing a long list
  /// does not disable "启用".
  bool _testing = false;
  Completer<bool>? _reachabilityBatchEnd;
  String? _taskId;

  /// Nodes whose latency is being measured right now. Their cell says so,
  /// instead of showing the previous (now meaningless) number.
  final Set<String> _testingIds = <String>{};

  /// How many nodes the running batch was started for.
  ///
  /// The strip's progress denominator has to be the run, not the table. It used
  /// to be `visible.length`, while the numerator was `visible.length -
  /// _testingIds.length`: testing one row of three reported "2/3" before any
  /// probe answered, and the last result drove it back to "0/3" because the
  /// remaining set was empty. Neither number described the batch, and a filter
  /// or a search could push the numerator negative. Zero when no batch runs.
  int _batchTotal = 0;

  /// Live latency results keyed by node id, seeded from the controller so
  /// results survive leaving and returning to this page.
  final Map<String, SpeedResult> _results = <String, SpeedResult>{};

  /// Live throughput results, the complements of [_results]. Kept apart so a
  /// download run cannot overwrite a latency reading in the same cell.
  final Map<String, SpeedResult> _speedResults = <String, SpeedResult>{};

  /// TCP/UDP reachability per node, keyed by node id then transport.
  ///
  /// Reachability is not a latency: it is answered without a core, it is far
  /// cheaper, and a node can be reachable over one transport and not the
  /// other. Sharing a cell with [_results] would let a 4 ms handshake be read
  /// as a 4 ms round trip through the proxy.
  final Map<String, Map<SpeedMetric, SpeedResult>> _reachability =
      <String, Map<SpeedMetric, SpeedResult>>{};
  StreamSubscription<SpeedResult>? _speedSub;

  /// A reversible batch edit, kept until the next edit or an undo.
  _Undo _undo = const _Undo.empty();

  AppController get c => widget.controller;

  List<ProxyNode> get _nodes => c.loadNodes();

  @override
  void initState() {
    super.initState();
    _adoptSessionResults();
    // A batch started before this page was opened is still running in the
    // controller. Seed the progress from it instead of showing an idle table:
    // switching pages used to lose the strip and the per-row "测试中" markers
    // while the host kept probing.
    final batchRunning =
        c.androidSpeedTestRunning ||
        c.speedBatchRunning ||
        (c.snapshot?.speedTestRunning ?? false);
    if (batchRunning) {
      _testing = true;
      _taskId = c.speedTaskId;
      _testingIds.addAll(c.speedPending);
      _batchTotal = c.speedBatchTotal > 0
          ? c.speedBatchTotal
          : c.speedPending.length;
      _ensureWatchdog();
    }
    _speedSub = c.speedUpdates.listen((result) {
      if (!mounted) return;
      setState(() {
        _testingIds.remove(result.nodeId);
        switch (result.metric) {
          case SpeedMetric.download:
            _speedResults[result.nodeId] = result;
          case SpeedMetric.tcp:
          case SpeedMetric.udp:
            (_reachability[result.nodeId] ??= {})[result.metric] = result;
          case SpeedMetric.proxyLatency:
            _results[result.nodeId] = result;
        }
        // A result only changes the list when the filter or sort reads the
        // measurement maps; on a name-sorted, unfiltered table the row's own
        // repaint is all that changed.
        if (_visibleDependsOnMeasurements) _visibleDirty = true;
      });
    });
    // A batch ends on the host, not on the last result: the host also reports
    // cancelled batches, which produce no final result at all.
    c.runtimeRevision.addListener(_onRuntime);
    c.sessionRevision.addListener(_onSession);
    c.catalogRevision.addListener(_onCatalog);
    _announceRepairedNodes();
  }

  /// Replaces the page's local copies after the host session is re-read.
  ///
  /// Results outlive the window, so a window that reconnects must not keep the
  /// maps it built before the pipe dropped: the host may be the same process
  /// with new readings, or a new process whose session is empty.
  void _onSession() {
    if (!mounted) return;
    setState(() {
      _adoptSessionResults();
      _taskId = c.speedTaskId;
      _testingIds
        ..clear()
        ..addAll(c.speedPending);
      _batchTotal = c.speedBatchTotal > 0
          ? c.speedBatchTotal
          : c.speedPending.length;
      _testing =
          c.androidSpeedTestRunning ||
          c.speedBatchRunning ||
          (c.snapshot?.speedTestRunning ?? false);
      if (!_testing) _batchTotal = 0;
    });
    if (_testing) {
      _ensureWatchdog();
    } else {
      _watchdog?.cancel();
      _watchdog = null;
      _finishReachabilityWait(c.canOperate);
    }
  }

  void _adoptSessionResults() {
    _results
      ..clear()
      ..addAll(c.speedResults);
    _speedResults
      ..clear()
      ..addAll(c.downloadResults);
    _reachability.clear();
    for (final entry in c.reachability.entries) {
      _reachability[entry.key] = Map<SpeedMetric, SpeedResult>.of(entry.value);
    }
  }

  /// Explains a one-off upgrade repair: rows written by the old v2rayN importer
  /// were removed because they contradicted themselves, and they cannot be
  /// repaired in place. Saying so once beats a node vanishing unexplained.
  void _announceRepairedNodes() {
    final count = c.repairedNodeCount;
    if (count <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      c.acknowledgeRepairedNodes();
      _snack(
        '已移除 $count 个无法修复的节点（旧版本导入 v2rayN 数据时协议判断有误）。'
        '请到「订阅」页重新导入一次，这些节点会正确还原。',
      );
    });
  }

  @override
  void dispose() {
    _finishReachabilityWait(false);
    _watchdog?.cancel();
    c.runtimeRevision.removeListener(_onRuntime);
    c.sessionRevision.removeListener(_onSession);
    c.catalogRevision.removeListener(_onCatalog);
    _speedSub?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _tableFocus.dispose();
    super.dispose();
  }

  /// The catalog moved (import, rename, subscription refresh, the store
  /// opening after the first frame). The new list instance invalidates the
  /// visible cache through its identity check; this listener is what makes
  /// the page repaint at all.
  void _onCatalog() {
    if (!mounted) return;
    _announceRepairedNodes();
    setState(() {});
  }

  void _onRuntime() {
    if (!mounted) return;
    // Repaint on every runtime change, not only while a batch is running.
    //
    // This used to return early unless `_testing` was set, which meant the row
    // that is actually carrying traffic kept its old marker: enabling a node
    // changed `activeNodeId` on the host, the revision fired, and the page
    // ignored it. The 使用中 marker and the row highlight then described
    // whatever was active when the page was first built.
    // Windows trusts the host's snapshot: it is the authority even when the
    // event stream stalled and the tracker's pending set did not clear. Android
    // has no snapshot, so its local runner is the only source.
    final hostRunning = c.snapshot?.speedTestRunning;
    final batchRunning = c.isAndroid
        ? c.androidSpeedTestRunning
        : (hostRunning ?? c.speedBatchRunning);
    if (_testing && !batchRunning) {
      setState(() {
        _testing = false;
        _testingIds.clear();
        _batchTotal = 0;
      });
      _watchdog?.cancel();
      _watchdog = null;
      _finishReachabilityWait(c.canOperate);
      return;
    }
    if (_testing) return;
    setState(() {});
  }

  /// Polls the snapshot while a batch is in flight.
  ///
  /// [speedTestRunning] is the only thing that tells this page a batch is over,
  /// and it arrives on `state.changed`. When that event stream stalls — the
  /// client was unsubscribed, a write failed, a frame was dropped — every row
  /// stayed on "测试中" forever with no way back, because the page had no other
  /// source of truth. A budgeted poll makes the page converge on its own: the
  /// button still shows progress, but a stalled batch can never pin the table.
  void _ensureWatchdog() {
    _watchdog ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || !_testing) {
        _watchdog?.cancel();
        _watchdog = null;
        return;
      }
      if (c.isAndroid) {
        await c.refreshAndroidVpnStatus();
      } else {
        await c.refreshSnapshot();
      }
    });
  }

  Timer? _watchdog;

  // ------------------------------------------------------------------
  // Grouping, filtering and ordering
  // ------------------------------------------------------------------

  Map<String?, String> _profileNames() => {
    for (final p in c.loadProfiles()) p.id: p.name,
  };

  String _groupLabel(ProxyNode node, Map<String?, String> names) {
    // Since v6 there is no such thing as a node without a profile: locally
    // imported nodes belong to the built-in 本地 subscription, which is a normal
    // row and therefore appears in `names` like any other.
    final id = node.profileId;
    if (id == null) return '本地';
    return names[id] ?? '订阅';
  }

  /// The filtered and sorted list for the current filters, cached across
  /// rebuilds.
  ///
  /// Every build used to run the full filter + O(n log n) sort at least twice
  /// (table plus status strip) and again on every key press, with a
  /// toLowerCase() inside the name comparator. The cache is invalidated by
  /// the mutators below, by a new catalog list instance, and — only when the
  /// filter or sort actually reads measurements — by incoming results.
  List<ProxyNode> get visibleNodes {
    final all = _nodes;
    if (_visibleDirty ||
        _visibleCache == null ||
        !identical(_visibleSource, all)) {
      _visibleCache = _computeVisible(all);
      _visibleSource = all;
      _visibleDirty = false;
    }
    return _visibleCache!;
  }

  void _ensureNameKeys() {
    final all = _nodes;
    if (identical(_nameKeysSource, all)) return;
    _nameKeys = {for (final n in all) n.id: n.name.toLowerCase()};
    _nameKeysSource = all;
  }

  List<ProxyNode> _computeVisible(List<ProxyNode> all) {
    _ensureNameKeys();
    var list = all;
    final groupFilter = _groupFilter;
    if (groupFilter != null) {
      list = groupFilter == _kLocalGroup
          // Kept as a separate chip so 本地 stays one click away even when the
          // profile is absent from the database (a fresh install before the
          // first local import).
          ? list.where((n) => n.profileId == kLocalProfileId).toList()
          // A group chip selects every subscription in that group, which is the
          // reason the group exists on this page: with twenty subscriptions a
          // per-subscription chip row is unreadable.
          : groupFilter.startsWith(_kGroupPrefix)
          ? list
                .where(
                  (n) => c.loadProfiles().any(
                    (p) =>
                        p.id == n.profileId &&
                        p.groupId ==
                            groupFilter.substring(_kGroupPrefix.length),
                  ),
                )
                .toList()
          : list.where((n) => n.profileId == groupFilter).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where(
            (n) =>
                n.name.toLowerCase().contains(q) ||
                n.server.toLowerCase().contains(q) ||
                n.protocol.wire.contains(q) ||
                n.transport.kind.wire.contains(q),
          )
          .toList();
    }
    if (_protocolFilter != null) {
      list = list.where((n) => n.protocol == _protocolFilter).toList();
    }
    final latency = _latencyFilter;
    if (latency != null) {
      list = list.where((n) => latency.matches(_results[n.id])).toList();
    }
    list = [...list];
    final asc = _sortAscending ? 1 : -1;
    switch (_sortColumn) {
      case _SortColumn.name:
        // Precomputed keys: a name sort over 5000 rows used to lowercase both
        // operands of every comparison — tens of thousands of string
        // allocations per sort.
        list.sort(
          (a, b) =>
              asc *
              (_nameKeys[a.id] ?? a.name.toLowerCase()).compareTo(
                _nameKeys[b.id] ?? b.name.toLowerCase(),
              ),
        );
      case _SortColumn.protocol:
        list.sort((a, b) => asc * a.protocol.wire.compareTo(b.protocol.wire));
      case _SortColumn.server:
        list.sort((a, b) => asc * a.server.compareTo(b.server));
      case _SortColumn.port:
        list.sort((a, b) => asc * a.port.compareTo(b.port));
      case _SortColumn.transport:
        list.sort(
          (a, b) =>
              asc * a.transport.kind.wire.compareTo(b.transport.kind.wire),
        );
      case _SortColumn.tls:
        list.sort((a, b) => asc * a.tls.kind.wire.compareTo(b.tls.kind.wire));
      case _SortColumn.group:
        final names = _profileNames();
        list.sort(
          (a, b) =>
              asc * _groupLabel(a, names).compareTo(_groupLabel(b, names)),
        );
      case _SortColumn.latency:
        // Untested and unreachable sort last in *both* directions: "no number"
        // is not "fast", so it must not float to the top of an ascending sort
        // where the best node belongs.
        int rank(ProxyNode n) {
          final r = _results[n.id];
          if (r == null) return 1 << 30;
          if (r.status != SpeedStatus.ok || r.valueMs == null) {
            return (1 << 30) + 1;
          }
          return r.valueMs!;
        }

        list.sort((a, b) => asc * rank(a).compareTo(rank(b)));
      case _SortColumn.reachability:
        // Reachable first in both directions: "not checked" is not "reachable",
        // so it must not float to the top of an ascending sort.
        int rank(ProxyNode n) {
          final m = _reachability[n.id];
          if (m == null || m.isEmpty) return 1 << 30;
          final ok = m.values.where((r) => r.status == SpeedStatus.ok).length;
          final bad = m.values
              .where((r) => r.status == SpeedStatus.failed)
              .length;
          if (ok > 0) return 0;
          if (bad > 0) return 1;
          return 2; // only 不适用
        }

        list.sort((a, b) => asc * rank(a).compareTo(rank(b)));
      case _SortColumn.throughput:
        // Same rule as latency: a node with no throughput reading is not "slow
        // but unknown", it is absent, so it must not sort as the fastest.
        int rank(ProxyNode n) {
          final r = c.downloadResults[n.id];
          if (r == null || r.status != SpeedStatus.ok) return -1;
          return r.bytesPerSecond ?? -1;
        }

        list.sort((a, b) => asc * rank(a).compareTo(rank(b)));
    }
    return list;
  }

  void _sortBy(_SortColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
      _visibleDirty = true;
    });
  }

  // ------------------------------------------------------------------
  // Selection
  // ------------------------------------------------------------------

  /// Applies one click to the selection, with the usual Explorer semantics.
  ///
  /// The modifiers come from [HardwareKeyboard] rather than from a GestureDetector
  /// flag because this is a desktop table: Ctrl and Shift are held on the
  /// keyboard, and the pointer event itself does not carry them.
  void _selectRow(ProxyNode node, List<ProxyNode> visible) {
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed;
    final shift = keys.isShiftPressed;
    if (shift && _anchorId != null) {
      final from = visible.indexWhere((n) => n.id == _anchorId);
      final to = visible.indexWhere((n) => n.id == node.id);
      if (from >= 0 && to >= 0) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        final range = visible.sublist(lo, hi + 1).map((n) => n.id).toSet();
        // A repeat Shift-click on the row that already ends the range — the
        // second press of a double click, or a click on the same edge — must
        // not rebuild the table for a selection that did not move.
        if (_selected.length == range.length && _selected.containsAll(range)) {
          return;
        }
        setState(() {
          _selected
            ..clear()
            ..addAll(range);
        });
        return;
      }
    }
    setState(() {
      if (ctrl) {
        if (!_selected.remove(node.id)) _selected.add(node.id);
        _anchorId = node.id;
        return;
      }
      // A plain click on an already-single-selected row keeps the selection:
      // collapsing it would make the next context-menu action hit nothing.
      if (_selected.length == 1 && _selected.contains(node.id)) {
        _anchorId = node.id;
        return;
      }
      _selected
        ..clear()
        ..add(node.id);
      _anchorId = node.id;
    });
  }

  void _toggleAll(List<ProxyNode> visible) {
    setState(() {
      if (_selected.length == visible.length && visible.isNotEmpty) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(visible.map((n) => n.id));
      }
    });
  }

  List<ProxyNode> _selectedNodes() =>
      _nodes.where((n) => _selected.contains(n.id)).toList();

  ProxyNode? _primarySelection() {
    final selected = _selectedNodes();
    if (selected.isEmpty) return null;
    // The most recently clicked row is the "primary" one for single-target
    // actions such as enable or edit.
    for (final node in selected) {
      if (node.id == _anchorId) return node;
    }
    return selected.first;
  }

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------

  /// Applies [node] and reports the outcome once.
  Future<void> _enableNode(ProxyNode node) async {
    setState(() => _busy = true);
    try {
      await c.selectNode(node.id);
      _snack('已启用「${node.name}」');
    } catch (e) {
      _snack('启用失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enableSelected() async {
    final node = _primarySelection();
    if (node == null) return;
    await _enableNode(node);
  }

  Future<void> _testSelected() async {
    if (_selected.isEmpty) return;
    await _startTest(_selected.toList());
  }

  Future<void> _testAll() async {
    final ids = visibleNodes.map((n) => n.id).toList();
    if (ids.isEmpty) return;
    await _startTest(ids);
  }

  /// Download throughput for the selection or the visible set.
  ///
  /// A separate action from the latency test, because it is a separate
  /// measurement: it downloads real bytes and costs real traffic, so it must
  /// never be what a user triggers when they only wanted to know which nodes
  /// answer quickly.
  Future<void> _testThroughput({bool all = false}) async {
    final ids = all
        ? visibleNodes.map((n) => n.id).toList()
        : _selected.toList();
    if (ids.isEmpty) return;
    await _startTest(ids, metric: SpeedMetric.download);
  }

  /// Checks TCP and UDP reachability for [ids], without starting any core for
  /// the TCP half.
  ///
  /// This is the cheap question, and it is worth asking first: a node whose
  /// port does not answer at all cannot produce a latency number, and finding
  /// that out by handshake takes milliseconds instead of the seconds a proxy
  /// probe costs. UDP requires a core, so it runs afterwards and only for
  /// protocols where it is meaningful.
  Future<void> _testReachability({
    List<String> ids = const [],
    bool all = false,
  }) async {
    final targets = all
        ? visibleNodes.map((n) => n.id).toList()
        : (ids.isEmpty ? _selected.toList() : ids);
    if (targets.isEmpty) return;
    final nodes = c.loadNodes().where((n) => targets.contains(n.id)).toList();
    // Which transport a node actually listens on comes from its own
    // configuration, not its protocol name: two Naive nodes on one host are
    // HTTP/2 (TCP) and HTTP/3 (UDP). Probing an HTTP/3 node with a TCP
    // handshake reports "不通" for a node that is fine.
    final tcpIds = nodes
        .where((n) => !n.isUdpTransport)
        .map((n) => n.id)
        .toList();
    final udpIds = nodes
        .where((n) => n.isUdpTransport)
        .map((n) => n.id)
        .toList();
    if (tcpIds.isNotEmpty) {
      await _startTest(tcpIds, metric: SpeedMetric.tcp);
      if (!mounted || !_testing || udpIds.isEmpty) return;
      final done = Completer<bool>();
      _reachabilityBatchEnd = done;
      if (!await done.future || !mounted) return;
    }
    if (udpIds.isNotEmpty && mounted) {
      await _startTest(udpIds, metric: SpeedMetric.udp);
    }
  }

  void _finishReachabilityWait(bool completed) {
    final done = _reachabilityBatchEnd;
    _reachabilityBatchEnd = null;
    done?.complete(completed);
  }

  /// Starts a latency batch, clearing the old numbers first.
  ///
  /// Clearing is not cosmetic: a previous result sitting next to a row while a
  /// new run is in progress reads as a fresh measurement, which is exactly how a
  /// user ends up picking a dead node.
  Future<void> _startTest(
    List<String> ids, {
    SpeedMetric metric = SpeedMetric.proxyLatency,
  }) async {
    _finishReachabilityWait(false);
    // A run that is still going must be stopped first. The host refuses a
    // second batch with ErrBusy, and surfacing that as "测速失败：已有测速任务在
    // 运行" makes re-testing a selection look broken: pressing 测试所选 while a
    // batch runs is the normal way to re-measure after editing a node.
    final running = _taskId;
    if (_testing && running != null) {
      setState(() => _busy = true);
      try {
        await c.cancelTask(running);
      } on HaloError catch (error) {
        if (error.code != HaloErrorCode.notFound) {
          if (mounted) {
            setState(() => _busy = false);
            _snack('停止测试失败：$error');
          }
          return;
        }
      } catch (error) {
        if (mounted) {
          setState(() => _busy = false);
          _snack('停止测试失败：$error');
        }
        return;
      }
      if (!mounted) return;
    }
    setState(() {
      _busy = true;
      for (final id in ids) {
        // Clear only the metric being measured. Wiping both would throw away
        // the throughput the user just earned while re-measuring latency —
        // and forgetSpeedResult drops every metric for the node, so calling it
        // here erased the latency reading too.
        switch (metric) {
          case SpeedMetric.download:
            c.downloadResults.remove(id);
            _speedResults.remove(id);
          case SpeedMetric.tcp:
          case SpeedMetric.udp:
            // Remove only the transport being re-measured. Clearing the whole
            // entry threw away the other transport's answer, which is exactly
            // the "one reading erases the other" bug this map exists to avoid.
            c.reachability[id]?.remove(metric);
            _reachability[id]?.remove(metric);
          case SpeedMetric.proxyLatency:
            c.speedResults.remove(id);
            _results.remove(id);
        }
      }
      _testingIds
        ..clear()
        ..addAll(ids);
      _batchTotal = ids.length;
      _testing = false;
      _taskId = null;
      // Clearing the measurements only reorders the list when the filter or
      // sort reads them.
      if (_visibleDependsOnMeasurements) _visibleDirty = true;
    });
    try {
      if (c.isAndroid) {
        _snack('Android 测速期间会暂时断开或切换 VPN，完成后恢复原节点');
      }
      final taskId = await c.startSpeedTest(nodeIds: ids, metric: metric);
      if (!mounted) return;
      setState(() {
        _taskId = taskId;
        _testing = c.isAndroid
            ? c.androidSpeedTestRunning
            : c.speedBatchRunning;
        if (!_testing) {
          _testingIds.clear();
          _batchTotal = 0;
        }
      });
      if (_testing) _ensureWatchdog();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testingIds.clear();
        _batchTotal = 0;
      });
      _snack('测速失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopTest() async {
    _finishReachabilityWait(false);
    final id = _taskId;
    setState(() => _busy = true);
    try {
      if (id != null) await c.cancelTask(id);
    } catch (_) {
      // A task that already finished cannot be cancelled; not an error.
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _testingIds.clear();
          _batchTotal = 0;
          _busy = false;
        });
        _watchdog?.cancel();
        _watchdog = null;
      }
    }
  }

  /// A node is invalid when it has at least one failed measurement and no
  /// successful one. Untested, cancelled, not-applicable and unconfirmed
  /// readings are not evidence of invalidity; neither is a slow node.
  bool _isInvalidNode(String id) {
    var failed = false;
    var succeeded = false;
    void note(SpeedResult? r) {
      if (r == null) return;
      if (r.status == SpeedStatus.ok) succeeded = true;
      if (r.status == SpeedStatus.failed) failed = true;
    }

    note(_results[id]);
    final reach = _reachability[id];
    if (reach != null) {
      for (final r in reach.values) {
        note(r);
      }
    }
    // A successful download proves the node usable even when a latency probe
    // failed; a failed download alone does not invalidate it (slow or empty
    // body are not the same as unreachable).
    if (_speedResults[id]?.status == SpeedStatus.ok) succeeded = true;
    return failed && !succeeded;
  }

  /// The invalid nodes inside the current filter/search, in table order.
  List<ProxyNode> _visibleInvalidNodes() => visibleNodes
      .where((node) => _isInvalidNode(node.id))
      .toList(growable: false);

  Future<void> _confirmRemoveInvalid() async {
    final targets = _visibleInvalidNodes();
    if (targets.isEmpty) {
      _snack('当前列表没有可移除的无效节点');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除无效节点'),
        content: Text(
          '当前列表中有 ${targets.length} 个节点没有任何成功结果，'
          '且至少一项测速或连通性检查失败。移除后可以用工具栏的撤销恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _deleteNodes(
      targets.map((n) => n.id),
      note: '已移除 ${targets.length} 个无效节点，可撤销',
    );
  }

  Future<void> _confirmDelete() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除节点'),
        content: Text('确定删除所选 $count 个节点？删除后可以用工具栏的撤销恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _applyDelete();
  }

  void _applyDelete() => _deleteNodes(_selected);

  /// Deletes [ids] and keeps an undo snapshot. The selection is pruned rather
  /// than cleared so a bulk cleanup of the visible set does not also drop an
  /// unrelated selection elsewhere in the list.
  void _deleteNodes(Iterable<String> ids, {String? note}) {
    final targets = ids.toSet();
    if (targets.isEmpty) return;
    final previous = [
      for (final n in _nodes.where((n) => targets.contains(n.id))) n,
    ];
    if (previous.isEmpty) return;
    c.deleteNodes(targets);
    setState(() {
      // A deleted node's measurements must go with it: an id can be revived by
      // undo or by re-import, and a stale row of numbers would then look like a
      // reading of the new node.
      for (final id in targets) {
        c.forgetSpeedResult(id);
        _results.remove(id);
        _speedResults.remove(id);
        _reachability.remove(id);
      }
      _selected.removeAll(targets);
      _undo = _Undo(deleted: previous);
      if (_visibleDependsOnMeasurements) _visibleDirty = true;
    });
    _snack(note ?? '已删除 ${previous.length} 个节点，可撤销');
  }

  Future<void> _applyRename(String prefix, {bool renameAll = false}) async {
    final all = _nodes;
    final targets = renameAll
        ? all
        : all.where((n) => _selected.contains(n.id)).toList();
    if (targets.isEmpty) return;
    final previous = {for (final n in targets) n.id: n.name};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < targets.length; i++) {
      final node = targets[i];
      c.nodeRepo.update(node.copyWith(name: '$prefix${i + 1}'), nowMs: now);
    }
    setState(() => _undo = _Undo(names: previous));
    c.notifyExternalChange();
    _snack('已重命名 ${targets.length} 个节点，可撤销');
  }

  Future<void> _applyReorder() async {
    final visible = visibleNodes;
    final reordered = [
      ...visible,
      ..._nodes.where((n) => !visible.contains(n)),
    ];
    final previous = <String, int>{};
    for (final node in _nodes) {
      previous[node.id] = node.sortIndex;
    }
    c.nodeRepo.reorderNodes(reordered.map((n) => n.id).toList());
    setState(() => _undo = _Undo(order: previous));
    c.notifyExternalChange();
    _snack('已按当前顺序保存 ${visible.length} 个节点，可撤销');
  }

  /// Moves the selection into [profileId] (`null` = 本地).
  Future<void> _moveToGroup(String? profileId, String label) async {
    final targets = _selectedNodes();
    if (targets.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = <ProxyNode>[];
    for (final node in targets) {
      previous.add(node);
      c.nodeRepo.update(node.movedToGroup(profileId, nowMs: now), nowMs: now);
    }
    setState(() {
      _undo = _Undo(moved: previous);
      _selected.clear();
    });
    c.notifyExternalChange();
    _snack('已移动 ${previous.length} 个节点到「$label」');
  }

  void _undoLast() {
    final undo = _undo;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (undo.names.isNotEmpty) {
      c.nodeRepo.renameNodes(undo.names, nowMs: now);
    }
    if (undo.order.isNotEmpty) {
      final ids = undo.order.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      c.nodeRepo.reorderNodes(ids.map((e) => e.key).toList());
    }
    if (undo.moved.isNotEmpty) {
      for (final node in undo.moved) {
        c.nodeRepo.update(node, nowMs: now);
      }
    }
    if (undo.deleted.isNotEmpty) {
      for (final node in undo.deleted) {
        c.nodeRepo.insert(node, nowMs: now);
      }
    }
    setState(() => _undo = const _Undo.empty());
    c.notifyExternalChange();
    _snack('已撤销上一次批量修改');
  }

  /// Copies a share link for [node].
  ///
  /// v2rayN binds this to Ctrl+C and puts it in the row menu; it is the most
  /// used "get this config out of the app" action.
  Future<void> _copyLink(ProxyNode node) async {
    final link = shareLinkFor(node);
    if (link == null) {
      _snack('该协议暂不支持导出分享链接');
      return;
    }
    await Clipboard.setData(ClipboardData(text: link));
    _snack('已复制分享链接');
  }

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    showHaloToast(context, message, action: action);
  }

  Future<void> _runBatchPreview({
    required String title,
    required String Function() preview,
    required Future<void> Function() apply,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 380),
          child: SingleChildScrollView(
            child: Text(
              preview(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await apply();
  }

  Future<void> _promptRename(bool all) async {
    final controller = TextEditingController(text: '节点 ');
    final pattern = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(all ? '重命名全部节点' : '重命名选中节点'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('新名称将使用前缀加序号，例如「香港 01」。'),
            const SizedBox(height: HaloMetrics.blockGap),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称前缀'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pattern == null || pattern.isEmpty) return;
    final count = all ? _nodes.length : _selected.length;
    await _runBatchPreview(
      title: '预览重命名',
      preview: () => [
        '将重命名 $count 个节点：',
        '',
        for (var i = 0; i < (count > 10 ? 10 : count); i++)
          '  $pattern${i + 1}',
        if (count > 10) '  …（其余 ${count - 10} 个省略）',
      ].join('\n'),
      apply: () => _applyRename(pattern, renameAll: all),
    );
  }

  /// Node details: every item the node's configuration carries, plus the two
  /// fields that are safe to change in place.
  ///
  /// Server, port, credentials, transport and TLS are shown (see
  /// [_nodeDetailRows]) but not edited here: they are part of the node's
  /// fingerprint, which is its identity for de-duplication and for matching
  /// against a subscription. Editing them in place would leave the stored
  /// identity lying about what the connection actually is, so the honest path
  /// is to re-import the corrected link.
  Future<void> _showNodeDetails(ProxyNode node) async {
    final rename = TextEditingController(text: node.name);
    final profiles = c.loadProfiles();
    String? group = node.profileId;
    // Credentials are masked until asked for: the dialog may sit open on an
    // unattended screen, and the reveal is one tap away.
    var revealSecrets = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('节点详情'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HaloField(
                    label: '名称',
                    child: TextField(
                      controller: rename,
                      autofocus: true,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: HaloMetrics.blockGap),
                  HaloField(
                    label: '订阅分组',
                    child: HaloDropdown<String?>(
                      // Was a bare DropdownButtonFormField: it ignores the
                      // theme's fill, border and radius, draws a 48px list and
                      // floats its label onto the border — none of which is
                      // how the rest of this app's forms look. HaloDropdown is
                      // the same control the toolbar uses, so the two dialogs
                      // that change a node's group finally match.
                      key: const ValueKey('node-detail-group'),
                      width: double.infinity,
                      value: group,
                      hint: '选择分组',
                      items: [for (final p in profiles) (p.id, p.name)],
                      onChanged: (v) => setDialogState(() => group = v),
                    ),
                  ),
                  const SizedBox(height: HaloMetrics.blockGap),
                  ..._nodeDetailRows(node, revealSecrets),
                  if (_hasMaskableSecrets(node)) ...[
                    TextButton.icon(
                      onPressed: () =>
                          setDialogState(() => revealSecrets = !revealSecrets),
                      icon: Icon(
                        revealSecrets
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 15,
                      ),
                      label: Text(revealSecrets ? '隐藏凭据' : '显示凭据'),
                    ),
                  ],
                  const SizedBox(height: HaloMetrics.blockGap),
                  Text(
                    '仅名称与分组可以就地修改；地址、端口、凭据与传输参数属于节点的'
                    '身份标识，需要更正时请重新导入正确的分享链接。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final name = rename.text.trim();
    rename.dispose();
    if (result != true) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (name.isNotEmpty && name != node.name) {
      c.nodeRepo.update(node.copyWith(name: name), nowMs: now);
    }
    if (group != node.profileId) {
      await _moveToGroupSingle(node, group);
    }
    c.notifyExternalChange();
    if (mounted) setState(() {});
  }

  Future<void> _moveToGroupSingle(ProxyNode node, String? profileId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    c.nodeRepo.update(node.movedToGroup(profileId, nowMs: now), nowMs: now);
  }

  Future<void> _promptMoveToGroup() async {
    if (_selected.isEmpty) return;
    final profiles = c.loadProfiles();
    final choice = await showDialog<String?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('移动 ${_selected.length} 个节点到'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(kLocalProfileId),
            child: const Text('本地（内置的本地订阅）'),
          ),
          for (final p in profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(p.id),
              child: Text(p.name),
            ),
        ],
      ),
    );
    if (choice == null) return;
    final name = profiles.firstWhere((p) => p.id == choice).name;
    await _moveToGroup(choice, name);
  }

  /// Right-click menu, mirroring the reference client's row menu but grouped so
  /// that "switch", "measure", "edit" and "destroy" never sit next to each other.
  Future<void> _showRowMenu(ProxyNode node, Offset globalPosition) async {
    final active = node.id == c.activeNodeId;
    // Right-clicking outside the current selection retargets the menu at the
    // row under the cursor, the way Explorer does; right-clicking inside it
    // keeps the whole selection so a batch delete still works.
    if (!_selected.contains(node.id)) {
      setState(() {
        _selected
          ..clear()
          ..add(node.id);
        _anchorId = node.id;
      });
    }
    final multi = _selected.length > 1;
    final chosen = await showHaloMenu<String>(
      context: context,
      position: globalPosition,
      entries: [
        HaloMenuItem(
          value: 'enable',
          label: '设为当前节点',
          shortcut: 'Enter',
          enabled: !active && !multi,
        ),
        HaloMenuItem(
          value: 'reachability',
          label: multi ? '检查所选连通性' : '检查该节点连通性',
        ),
        HaloMenuItem(value: 'test', label: multi ? '测试所选延迟' : '测试该节点延迟'),
        HaloMenuItem(
          value: 'throughput',
          label: multi ? '测下载速度（耗流量）' : '测该节点下载速度（耗流量）',
        ),
        const HaloMenuDivider(),
        HaloMenuItem(
          value: 'details',
          label: '节点详情…',
          shortcut: 'Ctrl+D',
          enabled: !multi,
        ),
        const HaloMenuItem(value: 'rename', label: '批量重命名…'),
        const HaloMenuItem(value: 'move', label: '移动到订阅分组…'),
        HaloMenuItem(
          value: 'copy',
          label: '复制分享链接',
          shortcut: 'Ctrl+C',
          enabled: !multi,
        ),
        const HaloMenuDivider(),
        HaloMenuItem(
          value: 'delete',
          label: multi ? '删除所选（${_selected.length}）' : '删除',
          shortcut: 'Delete',
          danger: true,
        ),
      ],
    );
    if (!mounted || chosen == null) return;
    switch (chosen) {
      case 'enable':
        await _enableNode(node);
      case 'reachability':
        await _testReachability(ids: _selected.toList());
      case 'test':
        await _startTest(_selected.toList());
      case 'throughput':
        await _testThroughput();
      case 'details':
        await _showNodeDetails(node);
      case 'rename':
        await _promptRename(false);
      case 'move':
        await _promptMoveToGroup();
      case 'copy':
        await _copyLink(node);
      case 'delete':
        await _confirmDelete();
    }
  }

  // ------------------------------------------------------------------
  // Keyboard
  // ------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed;
    // Reuse the cached list: a key press must not re-run the whole filter +
    // sort pipeline on its own.
    final visible = visibleNodes;

    if (event.logicalKey == LogicalKeyboardKey.f5) {
      unawaited(_testAll());
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyA) {
      _toggleAll(visible);
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_testing) unawaited(_stopTest());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      unawaited(_enableSelected());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      unawaited(_confirmDelete());
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyC) {
      final node = _primarySelection();
      if (node != null) unawaited(_copyLink(node));
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyD) {
      final node = _primarySelection();
      if (node != null) unawaited(_showNodeDetails(node));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (visible.isEmpty) return KeyEventResult.handled;
      final current = visible.indexWhere((n) => n.id == _anchorId);
      final next = event.logicalKey == LogicalKeyboardKey.arrowDown
          ? (current < 0 ? 0 : (current + 1).clamp(0, visible.length - 1))
          : (current < 0 ? 0 : (current - 1).clamp(0, visible.length - 1));
      setState(() {
        _selected
          ..clear()
          ..add(visible[next].id);
        _anchorId = visible[next].id;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final all = _nodes;
    final visible = visibleNodes;
    final names = _profileNames();
    final activeId = c.activeNodeId;
    final activeNode = activeId == null
        ? null
        : all.where((n) => n.id == activeId).firstOrNull;

    // One pass over the table for every chip's count: the per-profile
    // `all.where(...)` inside the chips built an O(nodes × profiles) scan per
    // frame — two thousand predicate calls per profile on a 5000-node list.
    var localCount = 0;
    final profileCounts = <String, int>{};
    for (final node in all) {
      final id = node.profileId;
      if (id == null || id == kLocalProfileId) {
        localCount++;
      } else {
        profileCounts[id] = (profileCounts[id] ?? 0) + 1;
      }
    }
    // Per-group totals in the same single pass: summing the profile counts
    // through the profile list instead would read as O(profiles x groups).
    final groupOf = <String, String?>{
      for (final p in c.loadProfiles()) p.id: p.groupId,
    };
    final groupCounts = <String, int>{};
    for (final entry in profileCounts.entries) {
      final groupId = groupOf[entry.key];
      if (groupId == null) continue;
      groupCounts[groupId] = (groupCounts[groupId] ?? 0) + entry.value;
    }

    return HaloPageScaffold(
      title: '节点',
      // The total is already on the group chip and in the table's status
      // strip; the page subtitle states only the thing those cannot: which
      // node is carrying traffic.
      subtitle: activeNode == null ? '尚未启用节点' : '正在使用「${activeNode.name}」',
      actions: [
        if (_testing)
          OutlinedButton.icon(
            onPressed: _busy ? null : _stopTest,
            icon: const Icon(Icons.stop, size: 15),
            label: const Text('停止测速'),
          )
        else ...[
          // Reachability first and cheap: it answers "is anything listening"
          // without starting a core, so it is the right first click before a
          // latency run that costs seconds per node.
          OutlinedButton.icon(
            onPressed: c.canOperate && all.isNotEmpty && !_busy
                ? () => _testReachability(all: true)
                : null,
            icon: const Icon(Icons.wifi_tethering, size: 15),
            label: const Text('连通性（全部）'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: c.canOperate && all.isNotEmpty && !_busy
                ? _testAll
                : null,
            icon: const Icon(Icons.bolt, size: 15),
            label: const Text('测延迟（全部）'),
          ),
        ],
        const SizedBox(width: 8),
        FilledButton.icon(
          // Android 没有宿主管道：以数据库可用为门槛（见 canOperate）。
          onPressed: c.canOperate && _selected.length == 1 && !_busy
              ? _enableSelected
              : null,
          icon: const Icon(Icons.play_arrow, size: 15),
          // Label states the action, never the condition. "选中一个以启用" made
          // the button look like a broken control; the reason it is disabled
          // belongs in the tooltip and in the page subtitle.
          label: const Text('启用所选'),
        ),
      ],
      child: all.isEmpty
          ? EmptyState(
              title: '还没有节点',
              message: '到「订阅」页添加订阅，或直接粘贴分享链接导入。',
              icon: Icons.dns_outlined,
              action: FilledButton(
                onPressed: widget.onOpenSubscriptions,
                child: const Text('去导入节点'),
              ),
            )
          : Focus(
              focusNode: _tableFocus,
              onKeyEvent: _onKey,
              // The table must actually own the keyboard, or every shortcut in
              // _onKey is dead code: Focus only dispatches to a node that has
              // focus, and nothing ever gave it any. Enter, Delete, Ctrl+A,
              // Ctrl+C, Ctrl+D and F5 all silently did nothing.
              autofocus: true,
              child: Column(
                children: [
                  _GroupChips(
                    profiles: c.loadProfiles(),
                    groups: c.loadGroups(),
                    selected: _groupFilter,
                    totalCount: all.length,
                    localCount: localCount,
                    counts: profileCounts,
                    groupCounts: groupCounts,
                    onSelect: (id) => setState(() {
                      _groupFilter = id;
                      _selected.clear();
                      _visibleDirty = true;
                    }),
                  ),
                  const SizedBox(height: HaloMetrics.blockGap),
                  _Toolbar(
                    invalidCount: visible
                        .where((node) => _isInvalidNode(node.id))
                        .length,
                    onRemoveInvalid: (_busy || _testing)
                        ? null
                        : _confirmRemoveInvalid,
                    search: _search,
                    searchFocus: _searchFocus,
                    onQuery: (v) => setState(() {
                      _query = v.trim();
                      _visibleDirty = true;
                    }),
                    protocol: _protocolFilter,
                    onProtocol: (v) => setState(() {
                      _protocolFilter = v;
                      _visibleDirty = true;
                    }),
                    latency: _latencyFilter,
                    onLatency: (v) => setState(() {
                      _latencyFilter = v;
                      _visibleDirty = true;
                      // A row hidden by the new filter must not stay selected:
                      // the next batch action would then hit invisible rows.
                      final next = visibleNodes.map((n) => n.id).toSet();
                      _selected.removeWhere((id) => !next.contains(id));
                    }),
                    onSelectAll: () => _toggleAll(visible),
                    onTestSelected: _selected.isEmpty || !c.canOperate || _busy
                        ? null
                        : _testSelected,
                    onRenameSelected: _selected.isEmpty || _busy
                        ? null
                        : () => _promptRename(false),
                    onRenameAll: all.isEmpty || _busy
                        ? null
                        : () => _promptRename(true),
                    onMove: _selected.isEmpty || _busy
                        ? null
                        : _promptMoveToGroup,
                    onReorder: visible.isEmpty || _busy
                        ? null
                        : () => _runBatchPreview(
                            title: '重排节点顺序',
                            preview: () =>
                                '将按当前列表顺序保存 ${visible.length} 个节点的排序。',
                            apply: _applyReorder,
                          ),
                    onDelete: _selected.isEmpty || _busy
                        ? null
                        : _confirmDelete,
                    onUndo: _undo.hasAnything ? _undoLast : null,
                    onShowColumns: (col) => setState(
                      () => _widths.setVisible(col, !_widths.isVisible(col)),
                    ),
                  ),
                  const SizedBox(height: HaloMetrics.blockGap),
                  Expanded(
                    child: Card(
                      // One horizontal scroll view wraps the header *and*
                      // the rows. Two independent scrollers would let the
                      // header stay put while the rows slid sideways, so the
                      // columns would stop lining up with their titles.
                      // Rebuilds the whole table — header *and* rows — when a
                      // column is dragged. Listening only around the header
                      // resized the titles while the body kept its old widths,
                      // so the columns stopped lining up.
                      child: AnimatedBuilder(
                        animation: _widths,
                        builder: (context, _) => LayoutBuilder(
                          builder: (context, constraints) => ScrollConfiguration(
                            // The header's resize handles must win a horizontal
                            // drag. With the default configuration the enclosing
                            // scroll view competed for it and won, so the divider
                            // scrolled the table instead of resizing a column.
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(dragDevices: _tableDragDevices(context)),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: _widths.total > constraints.maxWidth
                                    ? _widths.total
                                    : constraints.maxWidth,
                                child: Column(
                                  // Left-aligned, not centred. Column centres its
                                  // children by default, and the header is a fixed
                                  // width narrower than the window, so it sat 184 px
                                  // right of the rows it labels — every column
                                  // title pointed at the wrong column.
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _HeaderRow(
                                      sortColumn: _sortColumn,
                                      ascending: _sortAscending,
                                      onSort: _sortBy,
                                      widths: _widths,
                                    ),
                                    Divider(
                                      height: 1,
                                      color: HaloPalette.of(context).border,
                                    ),
                                    Expanded(
                                      child: visible.isEmpty
                                          ? EmptyState(
                                              message:
                                                  _groupFilter != null ||
                                                      _query.isNotEmpty ||
                                                      _protocolFilter != null ||
                                                      _latencyFilter != null
                                                  ? '没有匹配的节点。\n调整分组、搜索、协议或延迟状态筛选。'
                                                  : '这个分组里还没有节点。',
                                              icon: Icons.search_off,
                                            )
                                          // A lazily built list keeps a 10k-node
                                          // subscription responsive; only visible rows
                                          // are laid out.
                                          // Restore touch drag for the rows.
                                          : ScrollConfiguration(
                                              behavior: ScrollConfiguration.of(
                                                context,
                                              ),
                                              child: ListView.builder(
                                                itemCount: visible.length,
                                                itemExtent: _kRowHeight,
                                                itemBuilder: (context, index) {
                                                  final node = visible[index];
                                                  final active =
                                                      node.id == activeId;
                                                  return _NodeRow(
                                                    widths: _widths,
                                                    node: node,
                                                    groupLabel: _groupLabel(
                                                      node,
                                                      names,
                                                    ),
                                                    selected: _selected
                                                        .contains(node.id),
                                                    active: active,
                                                    result: _results[node.id],
                                                    speedResult:
                                                        _speedResults[node.id],
                                                    reachability:
                                                        _reachability[node.id],
                                                    testing: _testingIds
                                                        .contains(node.id),
                                                    onSelect: () => _selectRow(
                                                      node,
                                                      visible,
                                                    ),
                                                    onDetails: () =>
                                                        _showNodeDetails(node),
                                                    onMenu: (pos) =>
                                                        _showRowMenu(node, pos),
                                                  );
                                                },
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _StatusStrip(
                    total: all.length,
                    visible: visible.length,
                    selected: _selected.length,
                    testing: _testing,
                    // The batch, not the table: a subset run must not divide by
                    // the rows around it, and the last result must read as
                    // "n/n" rather than wrapping to zero.
                    batchTotal: _batchTotal,
                    tested: (_batchTotal - _testingIds.length).clamp(
                      0,
                      _batchTotal,
                    ),
                    busy: _busy,
                  ),
                ],
              ),
            ),
    );
  }
}

const double _kRowHeight = 38;

/// Height of the header row's content box: 11.5 px text line plus 9 px of
/// vertical padding on each side. The resize handle uses it so its hit area
/// covers the whole header.
const double _kHeaderHeight = 34;

/// Sortable columns, in display order.
enum _SortColumn {
  name,
  protocol,
  server,
  port,
  transport,
  tls,
  group,
  latency,
  reachability,
  throughput,
}

/// The table's columns, in display order.
///
/// Reachability precedes latency because a node that cannot be reached has no
/// latency to show; putting them the other way round invited reading a blank
/// delay as a fault.
enum _Col {
  // Defaults are the widths measured from the 1600-px screenshot: all ten
  // columns fit there, and a narrower window scrolls horizontally instead of
  // clipping a value. An earlier set totalled 1126 px in a ~780 px viewport,
  // which pushed 端口连通 / 延迟 / 速度 off screen entirely.
  //
  // The set below trades space from the short technical columns to the ones
  // that identify a node. 名称 and 地址 were both clipped (「AnyT…」, 「api1…」)
  // while 端口, 传输 and TLS held fixed columns for values of at most five
  // characters: the four fields a person uses to pick a node were the four that
  // did not fit. 传输 and TLS are also the two that can be hidden outright, via
  // [_optional], because they are verification detail rather than identity.
  name('名称', 148, 96, numeric: false),
  protocol('类型', 62, 48, numeric: false),
  server('地址', 132, 80, numeric: false),
  // 62, not 36: a port is up to five digits ("10443") plus 16 px of cell
  // padding and the 9 px sort slot shared with the header. At 36 it rendered
  // as "4..." — a port that silently loses digits is worse than one that
  // ellipsises, because it looks like a port.
  port('端口', 62, 52, numeric: true),
  transport('传输', 50, 46, numeric: false, optional: true),
  // TLS needs room for its three characters plus the reserved sort slot,
  // which is taken from every column whether or not it is the active sort.
  // Measured: 34.5 px of glyphs, so 54 clipped it to 29 and rendered "TL…".
  tls('TLS', 62, 54, numeric: false, optional: true),
  // 120, not 84: the column holds the subscription (source) name, and at 84
  // every host-shaped name rendered as "chengaop…". The whole row needs
  // 1006 px including the resizers; wider windows show it whole, narrower ones
  // scroll, and the cell keeps a tooltip for names that are longer still.
  group('分组', 120, 46, numeric: false),
  // 112, not 84: the widest common reading is "TCP 通 1251ms" (measured at
  // ~84 px of glyphs) and the cell also reserves the header's sort slot. At 84
  // the text ran left out of its column and collided with 分组.
  reachability('端口连通', 112, 96, numeric: true),
  latency('延迟', 76, 60, numeric: true),
  // 98, not 58: a KB/s reading is "1023 KB/s" (9 monospace chars ≈ 57 px of
  // glyphs) and an MB/s one carries a decimal ("118.0 MB/s"), so at 58 px the
  // cell clipped mid-number — exactly the digit a user compares rows by. The
  // extra 9 px is the reserved sort slot shared with the header.
  throughput('速度', 98, 64, numeric: true);

  const _Col(
    this.label,
    this.defaultWidth,
    this.minWidth, {
    required this.numeric,
    this.optional = false,
  });

  final String label;
  final double defaultWidth;
  final double minWidth;

  /// Right-aligned: a number is compared by its last digit, not its first.
  final bool numeric;

  /// Hideable, because it is verification detail rather than identity.
  ///
  /// Only the columns that a person does not need in order to recognise a node
  /// are optional: hiding 名称 or 地址 would leave nothing to choose by. Each
  /// hidden column gives its width back to the ones that remain.
  final bool optional;
}

const double _kResizerWidth = 7;
const double _kTableLead = 10;
const double _kTableTail = 4;

/// Current width of every column, shared by the header and all rows.
class _ColumnWidths extends ChangeNotifier {
  _ColumnWidths() {
    for (final c in _Col.values) {
      _widths[c] = c.defaultWidth;
    }
  }

  final Map<_Col, double> _widths = {};

  /// Columns currently hidden. Optional ones only, enforced in [setVisible].
  final Set<_Col> _hidden = {};

  /// The columns to render, in display order.
  ///
  /// Everything that walks the table (header, every row, the total width) must
  /// use this rather than [_Col.values], or a hidden column keeps reserving
  /// space while drawing nothing.
  List<_Col> get visible =>
      _Col.values.where((c) => !_hidden.contains(c)).toList(growable: false);

  bool isVisible(_Col c) => !_hidden.contains(c);

  /// Shows or hides a column.
  ///
  /// Only [optional] columns may be hidden — a table with no 名称 or 地址 has
  /// nothing left to identify a row by — and the last visible column is never
  /// removed, so the table can never collapse into a header with no data.
  void setVisible(_Col c, bool show) {
    if (!c.optional) return;
    if (show) {
      if (_hidden.remove(c)) notifyListeners();
      return;
    }
    if (_hidden.contains(c)) return;
    if (visible.length <= 1) return;
    _hidden.add(c);
    notifyListeners();
  }

  double operator [](_Col c) => _widths[c] ?? c.defaultWidth;

  /// Applies a drag delta, clamped so a column can never be squeezed to
  /// nothing: a zero-width column is indistinguishable from a missing one.
  void resize(_Col c, double delta) {
    final next = (this[c] + delta).clamp(c.minWidth, 600.0);
    if ((next - this[c]).abs() < 0.5) return;
    _widths[c] = next;
    notifyListeners();
  }

  /// Total width the table needs, including the resizer slot after every
  /// *visible* column and the leading/trailing gaps.
  ///
  /// Counting only the column widths left the row 74 px wider than the box it
  /// was given, which Flutter reports as an overflow. Counting hidden columns
  /// here would do the same thing in the other direction: a row wider than its
  /// content, which shows as a scrollbar with nothing to scroll to.
  double get total =>
      visible.fold(0.0, (sum, c) => sum + this[c]) +
      _kResizerWidth * visible.length +
      _kTableLead +
      _kTableTail;
}

/// A draggable divider between two columns.
class _ColumnResizer extends StatefulWidget {
  const _ColumnResizer({super.key, required this.column, required this.widths});

  final _Col column;
  final _ColumnWidths widths;

  @override
  State<_ColumnResizer> createState() => _ColumnResizerState();
}

class _ColumnResizerState extends State<_ColumnResizer> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {},
        onHorizontalDragUpdate: (d) =>
            widget.widths.resize(widget.column, d.delta.dx),
        // Explicit height, not just width: inside a Row the handle was laid out
        // 0 px tall, so it had an empty hit area and no drag could ever start on
        // it. The visible line is still 1 px.
        child: SizedBox(
          width: _kResizerWidth,
          height: _kHeaderHeight,
          child: Center(
            child: Container(
              width: 1,
              color: _hovering ? p.borderStrong : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}

/// The sortable header row.
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.sortColumn,
    required this.ascending,
    required this.onSort,
    required this.widths,
  });

  final _SortColumn sortColumn;
  final bool ascending;
  final ValueChanged<_SortColumn> onSort;
  final _ColumnWidths widths;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);

    Widget cell(_Col column, _SortColumn sort) {
      final sorted = sortColumn == sort;
      return CellBox(
        width: widths[column],
        onTap: () => onSort(sort),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            mainAxisAlignment: column.numeric
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            // The arrow sits after the label on every column, numeric or not,
            // so the indicator has one position across the whole table. It
            // used to lead the number columns and trail the text ones, which
            // made the arrow jump sides halfway across the header.
            //
            // The slot is reserved whether or not this column is the active
            // sort: clicking a header then swaps the glyph rather than nudging
            // the label sideways.
            children: [
              Flexible(
                child: Text(
                  column.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: column.numeric ? TextAlign.right : TextAlign.left,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: sorted ? p.textPrimary : p.textSecondary,
                  ),
                ),
              ),
              SortArrowSlot(ascending: sorted ? ascending : null),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      width: widths.total,
      child: Padding(
        padding: const EdgeInsets.only(right: _kTableTail),
        child: Row(
          children: [
            const SizedBox(width: _kTableLead),
            for (final col in widths.visible) ...[
              // Keyed so a width change rebuilds the handle's parent without
              // replacing the handle's State.
              cell(col, _sortFor(col)),
              _ColumnResizer(key: ValueKey(col), column: col, widths: widths),
            ],
          ],
        ),
      ),
    );
  }

  static _SortColumn _sortFor(_Col c) => switch (c) {
    _Col.name => _SortColumn.name,
    _Col.protocol => _SortColumn.protocol,
    _Col.server => _SortColumn.server,
    _Col.port => _SortColumn.port,
    _Col.transport => _SortColumn.transport,
    _Col.tls => _SortColumn.tls,
    _Col.group => _SortColumn.group,
    _Col.reachability => _SortColumn.reachability,
    _Col.latency => _SortColumn.latency,
    _Col.throughput => _SortColumn.throughput,
  };
}

/// The subscription group filter, as chips directly above the table.
///
/// This is the single biggest usability change from the flat list: with two
/// subscriptions, "show me only the nodes I just imported" was previously a
/// scroll-and-squint exercise. First chip is always 全部 and the local group is
/// always present so pasted links are never orphaned behind a filter.
class _GroupChips extends StatelessWidget {
  const _GroupChips({
    required this.profiles,
    required this.groups,
    required this.selected,
    required this.totalCount,
    required this.localCount,
    required this.counts,
    required this.groupCounts,
    required this.onSelect,
  });

  final List<SubscriptionProfile> profiles;
  final List<SubscriptionGroup> groups;
  final String? selected;
  final int totalCount;
  final int localCount;
  final Map<String, int> counts;

  /// Nodes per group id, summed over the subscriptions filed under it.
  final Map<String, int> groupCounts;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    Widget chip(String? id, String label, int count) {
      final active = selected == id;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: HaloFilterChip(
          label: label,
          count: count,
          selected: active,
          onTap: () => onSelect(id),
        ),
      );
    }

    // Wrap, not a horizontal ListView.
    //
    // The strip held one line and overflowed: the last subscription sources sat
    // outside the viewport, and a horizontal ListView is effectively
    // unreachable with a mouse (a plain wheel scrolls vertically and desktop
    // drag devices exclude the mouse), so those sources could not be selected
    // at all. Wrapping shows every source; the sighted rows are capped at three
    // so an account with dozens of subscriptions cannot squeeze the table out
    // of the window — beyond that the strip scrolls vertically, which the wheel
    // does support.
    const maxChipRows = 3;
    const chipHeight = 26.0;
    const chipSpacing = 6.0;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: maxChipRows * chipHeight + (maxChipRows - 1) * chipSpacing,
      ),
      child: SingleChildScrollView(
        key: const ValueKey('node-group-chips'),
        child: Wrap(
          spacing: chipSpacing,
          runSpacing: chipSpacing,
          children: [
            chip(null, '全部', totalCount),
            chip(_kLocalGroup, '本地', localCount),
            // Groups first, then the individual subscriptions: a group is the
            // coarser and more useful cut, and burying it after thirty profile
            // chips would leave it functionally invisible.
            for (final group in groups)
              chip(
                '$_kGroupPrefix${group.id}',
                group.name,
                groupCounts[group.id] ?? 0,
              ),
            for (final profile in profiles)
              if (profile.isRemote)
                chip(profile.id, profile.name, counts[profile.id] ?? 0),
          ],
        ),
      ),
    );
  }
}

/// The action bar above the table.
///
/// Icon buttons with tooltips, as in v2rayN: the toolbar carries eight actions,
/// and labelling all of them would make it wider than the window while a bare
/// glyph plus a tooltip stays one hover away.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.invalidCount,
    required this.onRemoveInvalid,
    required this.search,
    required this.searchFocus,
    required this.onQuery,
    required this.protocol,
    required this.onProtocol,
    required this.latency,
    required this.onLatency,
    required this.onSelectAll,
    required this.onTestSelected,
    required this.onRenameSelected,
    required this.onRenameAll,
    required this.onMove,
    required this.onReorder,
    required this.onDelete,
    required this.onUndo,
    required this.onShowColumns,
  });

  final int invalidCount;
  final VoidCallback? onRemoveInvalid;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onQuery;
  final ProxyProtocol? protocol;
  final ValueChanged<ProxyProtocol?> onProtocol;
  final LatencyFilter? latency;
  final ValueChanged<LatencyFilter?> onLatency;
  final VoidCallback onSelectAll;
  final VoidCallback? onTestSelected;
  final VoidCallback? onRenameSelected;
  final VoidCallback? onRenameAll;
  final VoidCallback? onMove;
  final VoidCallback? onReorder;
  final VoidCallback? onDelete;
  final VoidCallback? onUndo;

  /// Toggles an optional column's visibility.
  final void Function(_Col column)? onShowColumns;

  @override
  Widget build(BuildContext context) {
    final searchField = SizedBox(
      width: 230,
      child: TextField(
        controller: search,
        focusNode: searchFocus,
        onChanged: onQuery,
        decoration: InputDecoration(
          hintText: haloTouchPlatform(context)
              ? '搜索名称、地址、协议'
              : '搜索名称、地址、协议（Ctrl+F）',
          prefixIcon: const Icon(Icons.search, size: 16),
        ),
      ),
    );

    // Both dropdowns are HaloDropdown so they share the search field's fill,
    // border and exactly-32px height. A bare DropdownButton stood 48 tall beside
    // a 36-tall TextField, which is what made this row look misaligned.
    final protocolDropdown = HaloDropdown<ProxyProtocol?>(
      key: const ValueKey('filter-protocol'),
      width: 150,
      value: protocol,
      hint: '全部协议',
      items: [
        (null, '全部协议'),
        for (final proto in ProxyProtocol.values) (proto, proto.label),
      ],
      onChanged: onProtocol,
    );

    final latencyDropdown = HaloDropdown<LatencyFilter?>(
      key: const ValueKey('filter-latency'),
      width: 168,
      value: latency,
      hint: '全部延迟',
      items: [
        (null, '全部延迟'),
        for (final f in LatencyFilter.values) (f, f.label),
      ],
      onChanged: onLatency,
    );

    // Grouped by frequency and named, not a row of nine bare glyphs.
    //
    // The previous bar was eight icons whose meaning came only from a tooltip:
    // 文字样式, 文件夹箭头, 排序 and 撤销 are not distinguishable by shape, and
    // 整理 / 重命名 / 移动 in particular are all "edit the list" with different
    // consequences. The three actions people reach for constantly carry a short
    // label; the rest live behind 更多, where the consequence can be spelled
    // out and a disabled entry can say why.
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BarButton(
          icon: Icons.checklist,
          label: '全选',
          tooltip: '全选 / 取消全选（当前列表）\tCtrl+A',
          onPressed: onSelectAll,
        ),
        _BarButton(
          icon: Icons.speed,
          label: '测延迟',
          tooltip: '测试所选节点的延迟',
          onPressed: onTestSelected,
        ),
        _BarButton(
          icon: Icons.cleaning_services_outlined,
          label: '清理无效',
          tooltip: invalidCount > 0
              ? '移除当前列表的 $invalidCount 个无效节点'
              : '当前列表没有可移除的无效节点（先测速或检查连通性）',
          danger: true,
          onPressed: onRemoveInvalid,
        ),
        _BarButton(
          icon: Icons.delete_outline,
          label: '删除',
          tooltip: '删除所选节点\tDelete',
          danger: true,
          onPressed: onDelete,
        ),
        const _BarSeparator(),
        _MoreMenu(
          onRenameSelected: onRenameSelected,
          onRenameAll: onRenameAll,
          onMove: onMove,
          onReorder: onReorder,
          onUndo: onUndo,
          showColumns: onShowColumns,
        ),
      ],
    );

    // Two layouts, because one Row cannot hold a 230px search box and nine
    // buttons in a 590px window: it overflowed by 115px at 200% scaling. Below
    // the breakpoint the actions move to their own line instead of being
    // clipped or shrunk into unreadable glyphs.
    return LayoutBuilder(
      builder: (context, constraints) {
        // Raised from 760 when the latency filter joined the row: search (230)
        // + protocol (118) + latency (132) + gaps + the action bar need the
        // extra room, and a too-low breakpoint clips the actions rather than
        // moving them, which reads as a broken layout.
        final compact = constraints.maxWidth < 900;
        if (!compact) {
          return Row(
            children: [
              searchField,
              const SizedBox(width: 8),
              protocolDropdown,
              const SizedBox(width: 6),
              latencyDropdown,
              const Spacer(),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Flexible wrappers: at 590 logical px the three fixed widths plus
            // the count overflowed by 14px once the controls grew to 48. Letting
            // the search box shrink first keeps both dropdowns readable, which
            // is the useful degradation — a truncated placeholder is still
            // obvious, a truncated filter is not.
            Row(
              children: [
                Flexible(flex: 3, child: searchField),
                const SizedBox(width: 8),
                Flexible(flex: 2, child: protocolDropdown),
                const SizedBox(width: 6),
                Flexible(flex: 2, child: latencyDropdown),
              ],
            ),
            const SizedBox(height: HaloMetrics.rowGap),
            Align(
              alignment: Alignment.centerRight,
              // Still scrollable rather than clipped: a future tenth action
              // should degrade into a scroll, not an overflow stripe.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: actions,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A hairline between action groups. v2rayN groups its toolbar into
/// select/test | edit | destructive, and the gap is what makes that legible.
class _BarSeparator extends StatelessWidget {
  const _BarSeparator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: HaloPalette.of(context).border,
    );
  }
}

class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.label,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Short text beside the glyph.
  ///
  /// Present for the actions people use every time. A bare icon in a row of
  /// eight forced every meaning into a tooltip, and 整理 / 重命名 / 移动 are not
  /// distinguishable by shape at 16 px.
  final String? label;
  final bool danger;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final enabled = widget.onPressed != null;
    final danger = HaloColors.adapt(HaloColors.danger, p.isDark);
    final foreground = !enabled
        ? p.textTertiary
        : widget.danger
        ? danger
        : (_hovered ? p.accent : p.textSecondary);
    final icon = Icon(widget.icon, size: 16, color: foreground);
    final label = widget.label;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: label == null
              ? SizedBox(width: 24, height: 24, child: icon)
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      icon,
                      const SizedBox(width: 3),
                      Text(
                        label,
                        style: TextStyle(fontSize: 11.5, color: foreground),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// The toolbar's overflow menu.
///
/// Holds the actions that are occasional rather than constant, and states what
/// each one does. A disabled entry explains its precondition in its subtitle
/// instead of being a grey glyph with no reason given.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.onRenameSelected,
    required this.onRenameAll,
    required this.onMove,
    required this.onReorder,
    required this.onUndo,
    required this.showColumns,
  });

  final VoidCallback? onRenameSelected;
  final VoidCallback? onRenameAll;
  final VoidCallback? onMove;
  final VoidCallback? onReorder;
  final VoidCallback? onUndo;

  /// Called with the column the user wants to toggle; null means "no menu".
  final void Function(_Col column)? showColumns;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Builder(
      builder: (context) => GestureDetector(
        key: const ValueKey('nodes-more'),
        onTap: () => _open(context),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.more_horiz, size: 16, color: p.textSecondary),
                const SizedBox(width: 3),
                Text(
                  '更多',
                  style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    // Anchored under the trigger, not at the pointer: this button is a menu
    // entry point in a toolbar, and a toolbar menu that opens at the mouse
    // would drift between clicks.
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final position = box.localToGlobal(Offset(0, box.size.height));
    final chosen = await showHaloMenu<String>(
      context: context,
      position: position,
      entries: [
        HaloMenuItem(
          value: 'rename-selected',
          label: '重命名所选',
          subtitle: '批量改选中的节点名',
          enabled: onRenameSelected != null,
        ),
        HaloMenuItem(
          value: 'rename-all',
          label: '重命名全部',
          subtitle: '按规则改写当前列表的节点名',
          enabled: onRenameAll != null,
        ),
        HaloMenuItem(
          value: 'move',
          label: '移动到分组',
          subtitle: '把所选节点归到某个订阅下',
          enabled: onMove != null,
        ),
        HaloMenuItem(
          value: 'reorder',
          label: '保存排序',
          subtitle: '按当前排序写回列表顺序',
          enabled: onReorder != null,
        ),
        const HaloMenuDivider(),
        HaloMenuItem(
          value: 'undo',
          label: '撤销上次修改',
          subtitle: '恢复上一批批量改动',
          enabled: onUndo != null,
        ),
        const HaloMenuDivider(),
        HaloMenuItem(
          value: 'columns',
          label: '显示列…',
          subtitle: '隐藏传输 / TLS 等技术字段',
          enabled: showColumns != null,
        ),
      ],
    );
    if (!context.mounted || chosen == null) return;
    switch (chosen) {
      case 'rename-selected':
        onRenameSelected?.call();
      case 'rename-all':
        onRenameAll?.call();
      case 'move':
        onMove?.call();
      case 'reorder':
        onReorder?.call();
      case 'undo':
        onUndo?.call();
      case 'columns':
        _pickColumns(context);
    }
  }

  /// Opens the column picker.
  void _pickColumns(BuildContext context) {
    final picker = showColumns;
    if (picker == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('显示列'),
        children: [
          for (final col in _Col.values)
            if (col.optional)
              SimpleDialogOption(
                onPressed: () {
                  picker(col);
                  Navigator.of(context).pop();
                },
                child: Text('切换「${col.label}」列'),
              ),
        ],
      ),
    );
  }
}

/// One node: a table row.
class _NodeRow extends StatefulWidget {
  const _NodeRow({
    required this.node,
    required this.groupLabel,
    required this.selected,
    required this.active,
    required this.onSelect,
    required this.onMenu,
    required this.onDetails,
    required this.widths,
    this.result,
    this.speedResult,
    this.reachability,
    this.testing = false,
  });

  final ProxyNode node;
  final String groupLabel;
  final bool selected;
  final bool active;
  final VoidCallback onSelect;
  final ValueChanged<Offset> onMenu;
  final VoidCallback onDetails;

  /// Column widths, shared with the header so a drag moves both.
  final _ColumnWidths widths;

  /// The latency reading for this row (never a throughput one).
  final SpeedResult? result;

  /// The throughput reading for this row, kept separate on purpose.
  final SpeedResult? speedResult;

  /// TCP/UDP reachability for this row, keyed by transport.
  final Map<SpeedMetric, SpeedResult>? reachability;
  final bool testing;

  @override
  State<_NodeRow> createState() => _NodeRowState();
}

class _NodeRowState extends State<_NodeRow> {
  bool _hovered = false;

  /// One cell's content, keyed by column.
  ///
  /// Reachability comes before latency on purpose: a node whose port does not
  /// answer has no latency to report, so the reader should meet "unreachable"
  /// before a blank delay, not after it.
  Widget _cellContent(_Col col) {
    final p = HaloPalette.of(context);
    final node = widget.node;
    final success = HaloColors.adapt(HaloColors.success, p.isDark);
    TextStyle cellStyle({bool mono = false}) => TextStyle(
      fontSize: 12,
      fontFamily: mono ? 'Consolas' : null,
      color: p.textPrimary,
    );
    Widget right(Widget child) =>
        Align(alignment: Alignment.centerRight, child: child);

    switch (col) {
      case _Col.name:
        return Row(
          children: [
            Expanded(
              // The name is the row's identity, and long names are the norm
              // (subscriptions prefix them). The tooltip carries the whole
              // value so a clipped name is still readable in full.
              child: Tooltip(
                message: node.name,
                waitDuration: const Duration(milliseconds: 400),
                child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: widget.active
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: p.textPrimary,
                  ),
                ),
              ),
            ),
            // One word, at the end of the name. The dot that used to sit at the
            // *left* of the name is gone: it repeated what the 使用中 badge and
            // the 3px green edge already say, and it pushed the name itself
            // 10px right on exactly the row a user is looking for.
            if (widget.active)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: success.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '使用中',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: success,
                    ),
                  ),
                ),
              ),
          ],
        );
      case _Col.protocol:
        return Text(
          protocolLabel(node.protocol),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: cellStyle(),
        );
      case _Col.server:
        return Tooltip(
          message: node.server,
          waitDuration: const Duration(milliseconds: 400),
          child: Text(
            node.server,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: cellStyle(mono: true),
          ),
        );
      case _Col.port:
        return Text(
          '${node.port}',
          textAlign: TextAlign.right,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: cellStyle(mono: true),
        );
      case _Col.transport:
        return Text(
          node.transport.kind.wire,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: cellStyle(),
        );
      case _Col.tls:
        return Text(
          node.tls.enabled ? node.tls.kind.wire : '无',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: cellStyle(),
        );
      case _Col.group:
        // A subscription name can be arbitrarily long (a host-like
        // `api1.0443.org.uk` is one of them), so the column will always clip
        // *something*. What it must not do is hide the value: the tooltip
        // carries it whole, which is the review's "完整值可查看".
        return Tooltip(
          message: widget.groupLabel,
          waitDuration: const Duration(milliseconds: 400),
          child: Text(
            widget.groupLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: cellStyle(),
          ),
        );
      case _Col.reachability:
        return right(
          _ReachabilityCell(
            result: widget.reachability,
            udpOnly: node.isUdpTransport,
          ),
        );
      case _Col.latency:
        // The in-progress marker lives in the throughput column, not here: a
        // run can be a latency batch or a download batch, and marking the
        // latency cell claimed one specific measurement was being taken even
        // when the user had asked for speed.
        return right(_LatencyCell(result: widget.result));
      case _Col.throughput:
        return right(
          widget.testing
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '测试中',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: cellStyle(),
                      ),
                    ),
                  ],
                )
              : _ThroughputCell(result: widget.speedResult),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final active = widget.active;
    final success = HaloColors.adapt(HaloColors.success, p.isDark);

    final Color background;
    if (widget.selected) {
      background = p.accentSubtle;
    } else if (active) {
      background = p.cardHover;
    } else if (_hovered) {
      background = p.cardHover.withValues(alpha: 0.6);
    } else {
      background = Colors.transparent;
    }

    // Left click selects, double click opens details. Both were dropped when
    // the row was rebuilt: only the right-click menu survived, so the table
    // had become a list you could not select by clicking and could not open
    // by double clicking.
    //
    // The click is a Listener, not GestureDetector's onTap, because the row
    // also recognises a double click: a double-tap recognizer holds the gesture
    // arena open for kDoubleTapTimeout (300 ms) so a second tap can still
    // arrive, and that hold withholds the sibling onTap as well. Every single
    // click therefore landed a third of a second after the button went up --
    // the table felt dead under the mouse. Selecting on the press is instant,
    // and it is what Explorer does.
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (event) {
          // Right and middle presses belong to the menu, never to selection.
          if ((event.buttons & kPrimaryButton) == 0) return;
          widget.onSelect();
        },
        child: GestureDetector(
          onDoubleTap: widget.onDetails,
          onSecondaryTapUp: (details) => widget.onMenu(details.globalPosition),
          // Touch has no secondary button; long-press opens the same menu at
          // the pressed row. Desktop keeps the right-click path.
          onLongPressStart: (details) => widget.onMenu(details.globalPosition),
          child: Container(
            height: _kRowHeight,
            color: background,
            child: Stack(
              children: [
                if (active)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 3, color: success),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: _kTableTail),
                  child: Row(
                    children: [
                      const SizedBox(width: _kTableLead),
                      for (final col in widget.widths.visible) ...[
                        CellBox(
                          width: widget.widths[col],
                          reserveSortSlot: col.numeric,
                          child: _cellContent(col),
                        ),
                        const SizedBox(width: _kResizerWidth),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The latency cell: one number, one colour meaning.
class _LatencyCell extends StatelessWidget {
  const _LatencyCell({this.result});

  final SpeedResult? result;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final r = result;
    // The table is where a latency is compared across rows, so it keeps the
    // dashboard's tabular figures — just at the table's 11.5, not the card's 20.
    final base = haloMetricStyle(context, size: 11.5);
    if (r == null) {
      return Text('—', style: base.copyWith(color: p.textTertiary));
    }
    if (r.status != SpeedStatus.ok) {
      final failed = r.status == SpeedStatus.failed;
      final color = failed
          ? HaloColors.adapt(HaloColors.danger, p.isDark)
          : p.textTertiary;
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.remove_circle_outline,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              failed ? '不可用' : '已取消',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(color: color),
            ),
          ),
        ],
      );
    }
    final ms = r.valueMs;
    if (ms == null) {
      return Text('—', style: base.copyWith(color: p.textTertiary));
    }
    return Text(
      '$ms ms',
      maxLines: 1,
      style: base.copyWith(
        fontWeight: FontWeight.w600,
        color: HaloColors.adapt(latencyColor(ms), p.isDark),
      ),
    );
  }
}

/// The throughput cell: bytes per second, never milliseconds.
class _ThroughputCell extends StatelessWidget {
  const _ThroughputCell({this.result});

  final SpeedResult? result;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final r = result;
    // The table is where a latency is compared across rows, so it keeps the
    // dashboard's tabular figures — just at the table's 11.5, not the card's 20.
    final base = haloMetricStyle(context, size: 11.5);
    if (r == null) {
      return Text('—', style: base.copyWith(color: p.textTertiary));
    }
    if (r.status != SpeedStatus.ok) {
      final failed = r.status == SpeedStatus.failed;
      final color = failed
          ? HaloColors.adapt(HaloColors.danger, p.isDark)
          : p.textTertiary;
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.remove_circle_outline,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              // Not 不可用: that is what the latency column says about a node
              // that cannot be reached at all. A speed test can fail while the
              // node itself answers fine, so the two must not share a word.
              failed ? '测速失败' : '已取消',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(color: color),
            ),
          ),
        ],
      );
    }
    final bps = r.bytesPerSecond;
    if (bps == null || bps <= 0) {
      return Text('—', style: base.copyWith(color: p.textTertiary));
    }
    return Text(
      throughputLabel(bps),
      maxLines: 1,
      style: base.copyWith(
        fontWeight: FontWeight.w600,
        color: HaloColors.adapt(throughputColor(bps), p.isDark),
      ),
    );
  }
}

/// Renders the reachability cell in isolation, for tests that pin its wording.
///
/// The cell's job is to be readable without a legend, so its labels are part of
/// the contract rather than a styling detail worth leaving untested.
@visibleForTesting
Widget buildReachabilityCellForTest({
  Map<SpeedMetric, SpeedResult>? readings,
  bool udpOnly = false,
}) => _ReachabilityCell(result: readings, udpOnly: udpOnly);

/// TCP/UDP reachability for one node, spelled out.
///
/// The first version printed a letter plus a tick: a single character standing
/// for the transport, coloured by outcome. That was unreadable twice over --
/// the letters need a legend, and red/green already mean slow/fast in the
/// latency column next door.
class _ReachabilityCell extends StatelessWidget {
  const _ReachabilityCell({this.result, this.udpOnly = false});

  final Map<SpeedMetric, SpeedResult>? result;

  /// True for QUIC-only protocols, where a TCP handshake is meaningless.
  final bool udpOnly;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    // Contains handshake times ("TCP 通 38ms"): tabular figures, same as the
    // latency and throughput columns beside it.
    final base = haloMetricStyle(context, size: 11.5);
    final r = result;
    if (r == null || r.isEmpty) {
      return Text('—', style: base.copyWith(color: p.textTertiary));
    }
    final order = udpOnly
        ? const [SpeedMetric.udp, SpeedMetric.tcp]
        : const [SpeedMetric.tcp, SpeedMetric.udp];
    final parts = <Widget>[];
    for (final metric in order) {
      final v = r[metric];
      if (v == null) continue;
      if (parts.isNotEmpty) parts.add(const SizedBox(width: 8));
      final name = metric == SpeedMetric.tcp ? 'TCP' : 'UDP';
      final (text, color) = switch (v.status) {
        // The handshake time goes with the verdict: TCP 通 alone leaves the
        // reader unable to tell a node that answers in 8 ms from one that takes
        // 3 s, which is the difference worth acting on.
        SpeedStatus.ok => (
          v.valueMs == null ? '$name 通' : '$name 通 ${v.valueMs}ms',
          HaloColors.adapt(HaloColors.success, p.isDark),
        ),
        // UDP silence is "could not confirm", not "broken", and not "the check
        // does not apply" either.
        _ when v.errorCode == 'udp_unconfirmed' => (
          '$name 未确认',
          p.textTertiary,
        ),
        // 不适用 must not read as a fault: a QUIC-only node has no TCP listener.
        SpeedStatus.notApplicable => ('$name 不适用', p.textTertiary),
        SpeedStatus.running => ('$name 测试中', p.textSecondary),
        SpeedStatus.canceled => ('$name 已取消', p.textTertiary),
        // Deliberately not red: red already means "slow" in the latency column.
        _ => ('$name 不通', p.textSecondary),
      };
      parts.add(
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: base.copyWith(color: color),
          ),
        ),
      );
    }
    if (parts.isEmpty) {
      return Text('—', style: base.copyWith(color: p.textTertiary));
    }
    return Tooltip(
      message:
          'TCP 通 12ms＝节点端口能在 12ms 内建立连接（握手耗时，不是延迟）\n'
          'UDP 通＝经节点转发数据报成功（DNS/QUIC 才需要）\n'
          '不适用＝该协议不走 TCP，这一项对它没有意义',
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: parts),
    );
  }
}

/// The bottom strip: what is selected, what is running, and the keys that do the
/// common things. v2rayN relies on muscle memory alone; spelling the shortcuts
/// out once is the difference between a discoverable table and a hidden one.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.total,
    required this.visible,
    required this.selected,
    required this.testing,
    required this.batchTotal,
    required this.tested,
    required this.busy,
  });

  final int total;
  final int visible;
  final int selected;
  final bool testing;

  /// Nodes the running batch was started for — the progress denominator.
  final int batchTotal;
  final int tested;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final style = TextStyle(fontSize: 11, color: p.textSecondary);
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          // Every text child is Flexible: the strip is the one place that must
          // never overflow, because it renders at any window width and at 200%
          // scaling, where the hints alone are wider than the window.
          Flexible(
            child: Text(
              '$visible / $total 个节点'
              '${selected > 0 ? ' · 已选 $selected' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const Spacer(),
          if (testing)
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      haloTouchPlatform(context)
                          ? '正在测速 · $tested/$batchTotal'
                          : '正在测速 · $tested/$batchTotal · Esc 停止',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: Text(
                // Short enough to survive a 1180px window: the longer list used
                // to ellipsise at "Ctrl+…", which told the user nothing.
                // Touch has no keyboard: point at the gesture that does exist.
                haloTouchPlatform(context)
                    ? '长按节点打开菜单 · 点按选择'
                    : 'Enter 启用 · Delete 删除 · Ctrl+A 全选',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: style.copyWith(color: p.textTertiary),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// A measurement-state filter, so a batch result can be acted on.
///
/// Every bucket maps to an existing row state; nothing is inferred. That
/// matters because the three "no number" states are the ones users get wrong:
/// 未测 has never run, 已取消 was stopped, 不可用 was measured and failed.
enum LatencyFilter {
  reachable('可用的'),
  fast('快的（≤$kLatencyFastMs ms）'),
  slow('慢的（> $kLatencySlowMs ms）'),
  unreachable('不可用的'),
  untested('未测过的'),
  untestedOrUnreachable('未确认可用的');

  const LatencyFilter(this.label);
  final String label;

  bool matches(SpeedResult? r) {
    final ms = r?.status == SpeedStatus.ok ? r?.valueMs : null;
    switch (this) {
      case LatencyFilter.reachable:
        return ms != null;
      case LatencyFilter.fast:
        return ms != null && ms <= kLatencyFastMs;
      case LatencyFilter.slow:
        return ms != null && ms > kLatencySlowMs;
      case LatencyFilter.unreachable:
        return r != null && r.status == SpeedStatus.failed;
      case LatencyFilter.untested:
        return r == null;
      case LatencyFilter.untestedOrUnreachable:
        return ms == null;
    }
  }
}

/// Whether the node carries a credential the details dialog masks by default.
bool _hasMaskableSecrets(ProxyNode node) =>
    node.secrets.uuid != null ||
    node.secrets.password != null ||
    _extrasHaveSecrets(node.extras);

/// Key names whose values are credentials, not configuration.
bool _isSecretExtraKey(String key) {
  final k = key.toLowerCase();
  return k.contains('password') ||
      k.contains('passwd') ||
      k.contains('secret') ||
      k.contains('token') ||
      k.contains('credential') ||
      k == 'pwd' ||
      k == 'pass' ||
      k == 'auth' ||
      k == 'authorization' ||
      k.contains('apikey') ||
      k.contains('api_key') ||
      k.contains('api-key') ||
      k.contains('privatekey') ||
      k.contains('private_key') ||
      k.contains('private-key') ||
      k.contains('accesskey') ||
      k.contains('access-key');
}

/// Credentials embedded in an otherwise harmless option string, such as an
/// SS plugin's `password=` parameter. Masking the whole string would hide the
/// plugin type and host too.
final _inlineSecretPattern = RegExp(
  r'\b(password|passwd|pwd|token|secret)=([^;&\s]+)',
  caseSensitive: false,
);

bool _extrasHaveSecrets(Object? value, [String key = '']) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (_extrasHaveSecrets(entry.value, '${entry.key}')) return true;
    }
    return false;
  }
  if (value is List) {
    return value.any((item) => _extrasHaveSecrets(item, key));
  }
  if (value == null || '$value'.isEmpty) return false;
  return _isSecretExtraKey(key) ||
      (value is String && _inlineSecretPattern.hasMatch(value));
}

/// Copies [value] with credentials replaced, leaving the rest of the
/// configuration visible. `reveal` is the dialog's one toggle.
Object? _maskExtraValue(
  Object? value, {
  required String key,
  required bool reveal,
}) {
  if (reveal) return value;
  if (value is Map) {
    return {
      for (final entry in value.entries)
        '${entry.key}': _maskExtraValue(
          entry.value,
          key: '${entry.key}',
          reveal: false,
        ),
    };
  }
  if (value is List) {
    return [
      for (final item in value) _maskExtraValue(item, key: key, reveal: false),
    ];
  }
  if (value == null) return null;
  if (_isSecretExtraKey(key)) return '••••••••';
  if (value is String) {
    return value.replaceAllMapped(
      _inlineSecretPattern,
      (match) => '${match[1]}=••••••••',
    );
  }
  return value;
}

/// The full certificate, not just its length: Naive nodes pin a private CA
/// here and the value is the only way to tell two servers apart when every
/// other field looks the same.
class _CertificatePem extends StatelessWidget {
  const _CertificatePem({required this.pem});

  final String pem;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: p.input,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(HaloMetrics.radius),
        ),
        child: SelectableText(
          pem,
          // Full width: a PEM body line is 64 characters and wraps at 11.5
          // when the block is indented to the value column.
          style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
        ),
      ),
    );
  }
}

/// The importer's untouched fields, human-readable and still complete.
class _ExtraConfigBlock extends StatelessWidget {
  const _ExtraConfigBlock({required this.extras, required this.revealSecrets});

  final Map<String, Object?> extras;
  final bool revealSecrets;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final masked = _maskExtraValue(extras, key: '', reveal: revealSecrets);
    return Padding(
      padding: const EdgeInsets.only(top: HaloMetrics.blockGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('额外配置（导入时保留，部分参与连接）', style: text.bodySmall),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: p.input,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(HaloMetrics.radius),
            ),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(masked),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every item the node's configuration carries, protocol-aware, in display
/// order.
///
/// A field the protocol does not use is never shown (the model guarantees a
/// parser never copies a password into a field the protocol ignores); a field
/// it does use is never omitted — completeness is the whole point of the
/// details dialog. Importers keep parameters the model has no dedicated field
/// for in `extras`; they are shown too, because several of them configure the
/// connection (Hysteria2 obfs, SS plugins, the v2rayN QUIC flag).
List<Widget> _nodeDetailRows(ProxyNode node, bool revealSecrets) {
  final s = node.secrets;
  String masked(String value) => revealSecrets ? value : '••••••••';

  final rows = <Widget>[
    InfoRow(label: '协议', value: protocolLabel(node.protocol)),
    InfoRow(label: '地址', value: node.server),
    InfoRow(label: '端口', value: '${node.port}'),
  ];
  if (s.uuid != null) {
    rows.add(InfoRow(label: 'UUID', value: masked(s.uuid!)));
  }
  if (s.password != null) {
    rows.add(InfoRow(label: '密码', value: masked(s.password!)));
  }
  if (s.method != null) {
    rows.add(InfoRow(label: '加密方式', value: s.method!));
  }
  if (s.username != null) {
    rows.add(InfoRow(label: '用户名', value: s.username!));
  }
  if (s.security != null) {
    rows.add(InfoRow(label: '加密', value: s.security!));
  }
  if (s.alterId != null) {
    rows.add(InfoRow(label: 'alterId', value: '${s.alterId}'));
  }
  if (s.flow != null) {
    rows.add(InfoRow(label: 'Flow', value: s.flow!));
  }

  final t = node.transport;
  rows.add(InfoRow(label: '传输', value: t.kind.label));
  if (t.host != null) {
    rows.add(InfoRow(label: 'Host', value: t.host!));
  }
  if (t.path != null) {
    rows.add(InfoRow(label: '路径', value: t.path!));
  }
  if (t.serviceName != null) {
    rows.add(InfoRow(label: 'gRPC 服务名', value: t.serviceName!));
  }
  if (t.earlyData != null) {
    rows.add(InfoRow(label: '早期数据', value: '${t.earlyData} 字节'));
  }
  for (final entry in t.headers.entries) {
    rows.add(InfoRow(label: 'Header · ${entry.key}', value: entry.value));
  }

  if (node.tls.enabled) {
    rows.add(
      InfoRow(
        label: 'TLS',
        value: node.tls.kind == TlsKind.reality ? 'REALITY' : 'TLS',
      ),
    );
    if (node.tls.serverName != null) {
      rows.add(InfoRow(label: 'SNI', value: node.tls.serverName!));
    }
    if (node.tls.alpn.isNotEmpty) {
      rows.add(InfoRow(label: 'ALPN', value: node.tls.alpn.join(', ')));
    }
    rows.add(InfoRow(label: '跳过证书校验', value: node.tls.insecure ? '是' : '否'));
    if (node.tls.fingerprint != null) {
      rows.add(InfoRow(label: 'uTLS 指纹', value: node.tls.fingerprint!));
    }
    if (node.tls.realityPublicKey != null) {
      rows.add(InfoRow(label: 'Reality 公钥', value: node.tls.realityPublicKey!));
    }
    if (node.tls.realityShortId != null) {
      rows.add(
        InfoRow(label: 'Reality ShortId', value: node.tls.realityShortId!),
      );
    }
    final pem = node.tls.certificatePem;
    if (pem != null) {
      rows.add(InfoRow(label: '自定义 CA', value: '已内置（${pem.length} 字符）'));
      // The PEM used to be reduced to its length, which hid a parameter the
      // handshake depends on. It is public certificate material, not a
      // credential, so it is shown in full and stays selectable.
      rows.add(_CertificatePem(pem: pem));
    }
  } else {
    rows.add(InfoRow(label: 'TLS', value: '无'));
  }

  if (node.extras.isNotEmpty) {
    rows.add(
      _ExtraConfigBlock(extras: node.extras, revealSecrets: revealSecrets),
    );
  }

  rows.add(
    InfoRow(label: '来源', value: node.isFromSubscription ? '订阅' : '手动导入'),
  );
  return rows;
}

class _Undo {
  const _Undo({
    this.names = const {},
    this.order = const {},
    this.deleted = const [],
    this.moved = const [],
  });

  const _Undo.empty()
    : names = const {},
      order = const {},
      deleted = const [],
      moved = const [];

  final Map<String, String> names;
  final Map<String, int> order;
  final List<ProxyNode> deleted;
  final List<ProxyNode> moved;

  bool get hasAnything =>
      names.isNotEmpty ||
      order.isNotEmpty ||
      deleted.isNotEmpty ||
      moved.isNotEmpty;
}
