import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../../state/app_controller.dart';
import '../../state/throughput.dart';
import '../../theme.dart';
import '../app.dart';
import '../widgets.dart';
import '../widgets/table_columns.dart';
import '../widgets/sparkline.dart';

/// Reads one connection snapshot.
///
/// Injected so the page can be rendered against a fixed list in tests without a
/// host, and so a future transport change does not have to be re-derived inside
/// the widget.
typedef ConnectionsLoader = Future<ConnectionsSnapshot> Function();

/// The live connection list, with a throughput monitor.
///
/// This page answers two questions that a proxy client cannot answer anywhere
/// else: what is going through the proxy right now, and how fast. The rule and
/// chain columns are how a broken rule set is debugged — a site that "does not
/// work" is usually a connection that took the wrong outbound — and the rate
/// columns are how a slow one is explained.
///
/// Data comes from sing-box's Clash API through the host rather than over HTTP
/// from here: the controller listens on loopback inside the host's process, and
/// the host already owns the running config that names it.
class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.controller, this.load});

  final AppController controller;

  /// Defaults to [AppController.fetchConnections].
  final ConnectionsLoader? load;

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

enum _SortKey { host, process, rule, chain, traffic, upRate, downRate, age }

const List<TableColumn> _kColumns = [
  // Widths total 724 px at their defaults, so all eight columns fit beside the
  // close button inside a 1180-px window.
  TableColumn(label: '主机', defaultWidth: 138, minWidth: 96),
  TableColumn(label: '进程', defaultWidth: 76, minWidth: 60),
  TableColumn(label: '规则', defaultWidth: 88, minWidth: 64),
  TableColumn(label: '代理链', defaultWidth: 96, minWidth: 70),
  TableColumn(label: '流量', defaultWidth: 84, minWidth: 70, numeric: true),
  TableColumn(label: '上速', defaultWidth: 62, minWidth: 54, numeric: true),
  TableColumn(label: '下速', defaultWidth: 62, minWidth: 54, numeric: true),
  TableColumn(label: '时长', defaultWidth: 56, minWidth: 46, numeric: true),
];

const double _kRowHeight = 38;
const double _kCloseWidth = 34;

class _ConnectionsPageState extends State<ConnectionsPage> {
  /// Fast enough that opening a site shows up while you watch, slow enough that
  /// a 500-row list is not decoded ten times a second. The shell disposes the
  /// page when it is not visible, so the cost is tied to actually looking.
  static const _pollInterval = Duration(milliseconds: 1500);

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _tableFocus = FocusNode();
  final ThroughputMonitor _throughput = ThroughputMonitor();

  String _query = '';
  List<LiveConnection> _connections = const [];
  int _uploadTotal = 0;
  int _downloadTotal = 0;
  String _controllerName = '';
  DateTime? _updatedAt;
  String? _error;
  bool _busy = false;
  bool _paused = false;
  Timer? _timer;

  /// Guards against overlapping polls: a snapshot that takes longer than the
  /// poll interval used to stack a second request on top of the first, so a
  /// slow controller read grew into an ever-deeper queue.
  bool _refreshing = false;

  final Set<String> _selected = {};
  String? _anchorId;
  _SortKey _sortKey = _SortKey.downRate;
  bool _sortAscending = false;
  final TableColumnWidths _widths = TableColumnWidths(_kColumns);

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _tableFocus.dispose();
    _widths.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Data
  // ------------------------------------------------------------------

  Future<void> _refresh() async {
    if (_paused || _refreshing) return;
    // The connectivity guard belongs to the host-backed loader only; an injected
    // loader is what the tests use and has no host behind it.
    if (widget.load == null && !c.connected) return;

    _refreshing = true;
    try {
      final snapshot = await (widget.load ?? c.fetchConnections).call();
      if (!mounted) return;
      setState(() {
        _error = null;
        _updatedAt = DateTime.now();
        _throughput.sample(snapshot, _updatedAt!);
        _connections = snapshot.connections;
        _uploadTotal = snapshot.uploadTotal;
        _downloadTotal = snapshot.downloadTotal;
        _controllerName = snapshot.controller;
        // Selection is by id, and ids disappear when a connection closes; drop
        // the stale ones so "delete selected" cannot target something gone.
        final alive = {for (final conn in _connections) conn.id};
        _selected.removeWhere((id) => !alive.contains(id));
        if (_anchorId != null && !alive.contains(_anchorId)) {
          _anchorId = _selected.isEmpty ? null : _selected.first;
        }
        _visibleCache = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _readableError(e));
    } finally {
      _refreshing = false;
    }
  }

  /// Turns the pipe's error into a sentence. The raw form —
  /// `HaloError(core_not_running: 代理内核未运行)` — is a diagnosis for whoever
  /// reads the log, not something to put in a banner above a table.
  static String _readableError(Object error) {
    final text = error.toString();
    if (text.contains('core_not_running')) {
      return '代理内核未运行。到「总览」启动内核后，连接会实时出现在这里。';
    }
    if (text.contains('host_unavailable') ||
        text.contains('host.disconnected')) {
      return '后台服务未连接，暂时读不到连接列表。';
    }
    return '读取连接失败：$text';
  }

  Future<void> _close(LiveConnection connection) async {
    setState(() => _busy = true);
    try {
      await c.closeConnection(connection.id);
      if (!mounted) return;
      setState(() {
        _connections = [
          for (final item in _connections)
            if (item.id != connection.id) item,
        ];
        _selected.remove(connection.id);
        _visibleCache = null;
      });
      _snack('已关闭到 ${connection.host} 的连接');
    } catch (e) {
      _snack('关闭连接失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      final match = _connections.where((conn) => conn.id == id).firstOrNull;
      if (match != null) await _close(match);
    }
  }

  Future<void> _closeAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭所有连接'),
        content: const Text(
          '当前所有连接都会断开，正在进行的下载或上传会中断。\n'
          '代理本身不受影响，新的请求会重新建立连接。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('全部关闭'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await c.closeAllConnections();
      if (!mounted) return;
      setState(() {
        _connections = const [];
        _selected.clear();
        _visibleCache = null;
      });
      _snack('已关闭所有连接');
    } catch (e) {
      _snack('关闭全部失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message, {Duration? duration}) {
    if (!mounted) return;
    // This page's messages are all confirmations of an action whose result is
    // already on screen (a closed connection, a copied row), so the default is
    // the short confirmation rather than the notice length.
    showHaloToast(
      context,
      message,
      duration: duration ?? HaloToastDuration.confirm,
    );
  }

  // ------------------------------------------------------------------
  // Derivation
  // ------------------------------------------------------------------

  /// The filtered, sorted list. Computed once per build and invalidated by
  /// the mutators below; [build] and [_onKey] both read the cache, so a key
  /// event no longer re-sorts the whole table on its own.
  List<LiveConnection>? _visibleCache;

  List<LiveConnection> get _visible {
    final cached = _visibleCache;
    if (cached != null) return cached;
    // One clock reading per sort: the age comparator used to call
    // DateTime.now() twice per comparison, which is both wasted work and a
    // violation of the consistency a sort's comparator must promise (two
    // elements could swap between comparisons as the clock moved).
    final now = DateTime.now();
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? [..._connections]
        : [
            for (final conn in _connections)
              if (conn.host.toLowerCase().contains(q) ||
                  conn.process.toLowerCase().contains(q) ||
                  conn.rule.toLowerCase().contains(q) ||
                  conn.rulePayload.toLowerCase().contains(q) ||
                  conn.chains.any((chain) => chain.toLowerCase().contains(q)))
                conn,
          ];
    list.sort((a, b) => _compare(a, b, now));
    return _visibleCache = list;
  }

  int _compare(LiveConnection a, LiveConnection b, DateTime now) {
    final sign = _sortAscending ? 1 : -1;
    int byNum(double x, double y) => sign * x.compareTo(y);
    int byText(String x, String y) =>
        sign * x.toLowerCase().compareTo(y.toLowerCase());

    switch (_sortKey) {
      case _SortKey.host:
        return byText(a.host, b.host);
      case _SortKey.process:
        return byText(a.process, b.process);
      case _SortKey.rule:
        return byText(a.rule, b.rule);
      case _SortKey.chain:
        return byText(a.chains.join('>'), b.chains.join('>'));
      case _SortKey.traffic:
        return byNum(
          (a.upload + a.download).toDouble(),
          (b.upload + b.download).toDouble(),
        );
      case _SortKey.upRate:
        return byNum(
          _throughput.perConnection[a.id]?.$1 ?? 0,
          _throughput.perConnection[b.id]?.$1 ?? 0,
        );
      case _SortKey.downRate:
        return byNum(
          _throughput.perConnection[a.id]?.$2 ?? 0,
          _throughput.perConnection[b.id]?.$2 ?? 0,
        );
      case _SortKey.age:
        // Younger connections first when ascending: "what just started" is the
        // usual reason to sort by age.
        return byNum(
          a.ageFrom(now)?.inMilliseconds.toDouble() ?? -1,
          b.ageFrom(now)?.inMilliseconds.toDouble() ?? -1,
        );
    }
  }

  void _sortBy(_SortKey key) {
    setState(() {
      if (_sortKey == key) {
        _sortAscending = !_sortAscending;
      } else {
        _sortKey = key;
        _sortAscending = false;
      }
      _visibleCache = null;
    });
  }

  // ------------------------------------------------------------------
  // Interaction
  // ------------------------------------------------------------------

  void _selectRow(LiveConnection conn, List<LiveConnection> visible) {
    final keys = HardwareKeyboard.instance;
    setState(() {
      if (keys.isShiftPressed && _anchorId != null) {
        final from = visible.indexWhere((n) => n.id == _anchorId);
        final to = visible.indexWhere((n) => n.id == conn.id);
        if (from >= 0 && to >= 0) {
          final lo = math.min(from, to);
          final hi = math.max(from, to);
          _selected
            ..clear()
            ..addAll(visible.sublist(lo, hi + 1).map((n) => n.id));
          return;
        }
      }
      if (keys.isControlPressed) {
        if (!_selected.remove(conn.id)) _selected.add(conn.id);
      } else {
        _selected
          ..clear()
          ..add(conn.id);
      }
      _anchorId = conn.id;
    });
  }

  void _moveSelection(int delta, List<LiveConnection> visible) {
    if (visible.isEmpty) return;
    final current = visible.indexWhere((n) => n.id == _anchorId);
    final next = current < 0
        ? 0
        : (current + delta).clamp(0, visible.length - 1);
    setState(() {
      _selected
        ..clear()
        ..add(visible[next].id);
      _anchorId = visible[next].id;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed;
    // Reuse the list the last build computed; a key event must not re-sort
    // the whole table on its own.
    final visible = _visibleCache ?? _visible;

    if (event.logicalKey == LogicalKeyboardKey.f5) {
      unawaited(_refresh());
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyA) {
      setState(() {
        if (_selected.length == visible.length) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll(visible.map((n) => n.id));
        }
        _anchorId = visible.isEmpty ? null : visible.first.id;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _selected.clear());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      unawaited(_closeSelected());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveSelection(
        event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1,
        visible,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _showRowMenu(LiveConnection conn, Offset position) async {
    final chosen = await showHaloMenu<String>(
      context: context,
      position: position,
      entries: [
        const HaloMenuItem(value: 'close', label: '关闭该连接', shortcut: 'Delete'),
        const HaloMenuDivider(),
        const HaloMenuItem(value: 'copyHost', label: '复制主机名'),
        HaloMenuItem(
          value: 'copyChain',
          label: '复制代理链',
          enabled: conn.chains.isNotEmpty,
        ),
        const HaloMenuItem(value: 'filterHost', label: '只看该主机'),
      ],
    );
    if (!mounted || chosen == null) return;
    switch (chosen) {
      case 'close':
        await _close(conn);
      case 'copyHost':
        await Clipboard.setData(ClipboardData(text: conn.host));
        _snack('已复制 ${conn.host}');
      case 'copyChain':
        await Clipboard.setData(ClipboardData(text: conn.chains.join(' → ')));
        _snack('已复制代理链');
      case 'filterHost':
        setState(() {
          _search.text = conn.host;
          _query = conn.host;
          _visibleCache = null;
        });
    }
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final running = c.snapshot?.coreState.isRunning ?? false;
    // Whether anything actually routes traffic into the core. A running core
    // with the system proxy and TUN both off is unreachable for ordinary
    // programs, so "open a browser" would produce no connections at all.
    final intercepted =
        (c.snapshot?.systemProxy.enabled ?? false) ||
        ((c.snapshot?.tunState ?? TunState.disabled) == TunState.enabled);
    final visible = _visible;
    final now = DateTime.now();
    final p = HaloPalette.of(context);

    final subtitle = _connections.isNotEmpty && _updatedAt != null
        ? '${_connections.length} 个活动连接 · 上行 ${formatBytes(_uploadTotal)} · '
              '下行 ${formatBytes(_downloadTotal)}'
        : !running
        ? '代理内核未运行，启动后才能看到连接'
        : _updatedAt == null
        ? '正在读取连接…'
        // The empty state inside the table already says "当前没有活动连接",
        // and the row under the search box already states the refresh interval;
        // the header describes the page instead of repeating either.
        : '实时连接列表';

    return HaloPageScaffold(
      title: '连接',
      subtitle: subtitle,
      actions: [
        OutlinedButton.icon(
          onPressed: () => setState(() => _paused = !_paused),
          icon: Icon(_paused ? Icons.play_arrow : Icons.pause, size: 15),
          label: Text(_paused ? '继续刷新' : '暂停'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed:
              (c.connected || widget.load != null) &&
                  _connections.isNotEmpty &&
                  !_busy
              ? _closeAll
              : null,
          icon: const Icon(Icons.link_off, size: 15),
          label: const Text('关闭全部'),
          style: FilledButton.styleFrom(
            backgroundColor: haloAdapt(context, HaloColors.danger),
          ),
        ),
      ],
      child: Column(
        children: [
          _SpeedStrip(
            throughput: _throughput,
            paused: _paused || !(_updatedAt != null),
          ),
          const SizedBox(height: HaloMetrics.blockGap),
          Row(
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  onChanged: (v) => setState(() {
                    _query = v.trim();
                    _visibleCache = null;
                  }),
                  decoration: const InputDecoration(
                    hintText: '搜索主机、进程、规则或代理链（Ctrl+F）',
                    prefixIcon: Icon(Icons.search, size: 16),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  _query.isEmpty
                      ? '每 1.5 秒刷新'
                      : '${visible.length} / ${_connections.length} 条匹配',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                ),
              ),
              const Spacer(),
              if (_controllerName.isNotEmpty)
                // Showing the source is how a stale list is told from an empty
                // one after changing the API port.
                Text(
                  '控制器 $_controllerName',
                  style: TextStyle(fontSize: 11, color: p.textTertiary),
                ),
            ],
          ),
          // The empty state already says the core is down; a red banner with
          // the same sentence above it reads as two different faults.
          if (_error != null && (running || _connections.isNotEmpty)) ...[
            const SizedBox(height: HaloMetrics.blockGap),
            _Notice(message: _error!),
          ],
          const SizedBox(height: HaloMetrics.blockGap),
          Expanded(
            child: Card(
              child: Focus(
                focusNode: _tableFocus,
                onKeyEvent: _onKey,
                // The table must own the keyboard or every shortcut in _onKey is
                // dead code: Focus only dispatches to a node that has focus.
                autofocus: true,
                child: Listener(
                  // Clicking the table takes focus back from the search box;
                  // otherwise using Ctrl+F once left the keyboard in the field
                  // and every shortcut stopped working.
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) {
                    if (!_tableFocus.hasFocus) _tableFocus.requestFocus();
                  },
                  child: AnimatedBuilder(
                    animation: _widths,
                    builder: (context, _) => LayoutBuilder(
                      builder: (context, constraints) => ScrollConfiguration(
                        // The resize handles must win a horizontal drag; with
                        // the default configuration the scroll view competes for
                        // it and wins, so the divider scrolls instead of
                        // resizing.
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(dragDevices: const {}),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width:
                                _widths.total + _kCloseWidth >
                                    constraints.maxWidth
                                ? _widths.total + _kCloseWidth
                                : constraints.maxWidth,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _Header(
                                  widths: _widths,
                                  sortKey: _sortKey,
                                  ascending: _sortAscending,
                                  onSort: _sortBy,
                                ),
                                Divider(height: 1, color: p.border),
                                Expanded(
                                  child: !running && _connections.isEmpty
                                      ? const EmptyState(
                                          compact: true,
                                          title: '代理内核未运行',
                                          message:
                                              '到「总览」页启动内核后，经过代理的连接会实时出现在这里。',
                                          icon: Icons.power_settings_new,
                                        )
                                      : visible.isEmpty
                                      ? EmptyState(
                                          compact: true,
                                          title: _query.isNotEmpty
                                              ? '没有匹配的连接'
                                              : '当前没有活动连接',
                                          // The advice has to match the
                                          // takeover state. With both the
                                          // system proxy and TUN off, "open a
                                          // browser" produces nothing: an app
                                          // that is not configured to use a
                                          // proxy never reaches this core. The
                                          // old text told the user to do
                                          // something that would visibly fail.
                                          message: _query.isNotEmpty
                                              ? '换个关键词试试（主机、进程、规则或代理链）。'
                                              : (intercepted
                                                    ? '已经接管流量，打开浏览器或任意联网程序后，'
                                                          '这里的列表会随流量出现。'
                                                    : '系统代理与 TUN 都关着，普通程序不会走这里。'
                                                          '先到「总览」开启系统代理或 TUN，'
                                                          '或把这个程序配置成本机代理。'),
                                          icon: Icons.link_off,
                                        )
                                      : ListView.builder(
                                          itemCount: visible.length,
                                          itemExtent: _kRowHeight,
                                          itemBuilder: (context, index) {
                                            final conn = visible[index];
                                            return _Row(
                                              widths: _widths,
                                              connection: conn,
                                              now: now,
                                              selected: _selected.contains(
                                                conn.id,
                                              ),
                                              rates: _throughput
                                                  .perConnection[conn.id],
                                              onSelect: () =>
                                                  _selectRow(conn, visible),
                                              onMenu: (pos) =>
                                                  _showRowMenu(conn, pos),
                                              onClose: _busy
                                                  ? null
                                                  : () => _close(conn),
                                            );
                                          },
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
            ),
          ),
          const SizedBox(height: HaloMetrics.blockGap),
          _StatusStrip(
            total: _connections.length,
            visible: visible.length,
            selected: _selected.length,
            busy: _busy,
          ),
        ],
      ),
    );
  }
}

/// Aggregate throughput, with a sparkline of the last minute.
class _SpeedStrip extends StatelessWidget {
  const _SpeedStrip({required this.throughput, required this.paused});

  final ThroughputMonitor throughput;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final up = throughput.upRate;
    final down = throughput.downRate;

    Widget figure(String label, double rate, Color color, IconData icon) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11.5, color: p.textSecondary)),
          const SizedBox(width: 6),
          SizedBox(
            width: 88,
            child: Text(
              rateLabel(rate),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontFamily: 'Consolas',
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: p.card,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
      ),
      child: Row(
        children: [
          figure('上行', up, p.accent, Icons.arrow_upward),
          const SizedBox(width: 20),
          figure(
            '下行',
            down,
            HaloColors.adapt(HaloColors.success, p.isDark),
            Icons.arrow_downward,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Sparkline(
              samples: throughput.history,
              up: p.accent,
              down: HaloColors.adapt(HaloColors.success, p.isDark),
              grid: p.border,
              // An empty chart used to draw its baseline across the strip,
              // which read as a divider rather than as "no sample yet".
              placeholder: throughput.hasCurve ? null : '等待采样…',
            ),
          ),
          const SizedBox(width: 12),
          Text(
            paused
                ? '已暂停'
                : '峰值 ↑${rateLabel(throughput.peakUp)} '
                      '↓${rateLabel(throughput.peakDown)}',
            style: TextStyle(fontSize: 11, color: p.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.widths,
    required this.sortKey,
    required this.ascending,
    required this.onSort,
  });

  final TableColumnWidths widths;
  final _SortKey sortKey;
  final bool ascending;
  final ValueChanged<_SortKey> onSort;

  static _SortKey _keyFor(int index) => switch (index) {
    0 => _SortKey.host,
    1 => _SortKey.process,
    2 => _SortKey.rule,
    3 => _SortKey.chain,
    4 => _SortKey.traffic,
    5 => _SortKey.upRate,
    6 => _SortKey.downRate,
    _ => _SortKey.age,
  };

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: kTableTail),
      child: Row(
        children: [
          const SizedBox(width: kTableLead),
          for (var i = 0; i < _kColumns.length; i++) ...[
            CellBox(
              width: widths[i],
              alignRight: _kColumns[i].numeric,
              onTap: () => onSort(_keyFor(i)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                // The arrow sits after the label on every column, numeric or
                // not, so the indicator has one position across the whole
                // table; leading the numbers and trailing the text made it
                // jump sides halfway across the header.
                //
                // The slot is reserved whether or not this column is the
                // active sort, so clicking a header swaps the glyph rather
                // than nudging the label sideways.
                child: Row(
                  mainAxisAlignment: _kColumns[i].numeric
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        _kColumns[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: _kColumns[i].numeric
                            ? TextAlign.right
                            : TextAlign.left,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: sortKey == _keyFor(i)
                              ? p.textPrimary
                              : p.textSecondary,
                        ),
                      ),
                    ),
                    SortArrowSlot(
                      ascending: sortKey == _keyFor(i) ? ascending : null,
                    ),
                  ],
                ),
              ),
            ),
            ColumnResizer(
              key: ValueKey('resizer-$i'),
              onDelta: (d) => widths.resize(i, d),
            ),
          ],
          const SizedBox(width: _kCloseWidth),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.widths,
    required this.connection,
    required this.now,
    required this.selected,
    required this.onSelect,
    required this.onMenu,
    required this.onClose,
    this.rates,
  });

  final TableColumnWidths widths;
  final LiveConnection connection;
  final DateTime now;
  final bool selected;
  final (double, double)? rates;
  final VoidCallback onSelect;
  final ValueChanged<Offset> onMenu;
  final VoidCallback? onClose;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final conn = widget.connection;
    final age = conn.ageFrom(widget.now);
    final upRate = widget.rates?.$1 ?? 0;
    final downRate = widget.rates?.$2 ?? 0;

    TextStyle style({bool mono = false, double size = 11.5, Color? color}) =>
        TextStyle(
          fontSize: size,
          fontFamily: mono ? 'Consolas' : null,
          color: color ?? p.textSecondary,
        );

    final background = widget.selected
        ? p.accentSubtle
        : _hovered
        ? p.cardHover.withValues(alpha: 0.6)
        : Colors.transparent;

    return GestureDetector(
      onTap: widget.onSelect,
      onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          height: _kRowHeight,
          color: background,
          child: Padding(
            padding: const EdgeInsets.only(right: kTableTail),
            child: Row(
              children: [
                const SizedBox(width: kTableLead),
                CellBox(
                  width: widget.widths[0],
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        conn.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style(size: 12, color: p.textPrimary),
                      ),
                      // The destination IP is only worth its own line when it is
                      // not already the host: a connection opened against an IP
                      // literal rendered the same string twice, which reads as a
                      // duplicated column rather than as detail.
                      if (conn.destinationIp.isNotEmpty &&
                          conn.destinationIp != conn.host)
                        Text(
                          conn.destinationIp,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style(
                            size: 10.5,
                            mono: true,
                            color: p.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: kResizerWidth),
                CellBox(
                  width: widget.widths[1],
                  child: Text(
                    conn.process.isEmpty ? '—' : conn.process,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(),
                  ),
                ),
                const SizedBox(width: kResizerWidth),
                CellBox(
                  width: widget.widths[2],
                  child: Text(
                    conn.rule.isEmpty ? '—' : conn.rule,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(),
                  ),
                ),
                const SizedBox(width: kResizerWidth),
                CellBox(
                  width: widget.widths[3],
                  child: Text(
                    conn.chains.isEmpty ? '—' : conn.chains.join(' → '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(),
                  ),
                ),
                const SizedBox(width: kResizerWidth),
                CellBox(
                  width: widget.widths[4],
                  alignRight: true,
                  child: Text(
                    '↑${formatBytes(conn.upload)} ↓${formatBytes(conn.download)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: style(mono: true),
                  ),
                ),
                const SizedBox(width: kResizerWidth),
                CellBox(
                  width: widget.widths[5],
                  alignRight: true,
                  child: _RateText(rate: upRate, dim: true),
                ),
                const SizedBox(width: kResizerWidth),
                CellBox(
                  width: widget.widths[6],
                  alignRight: true,
                  child: _RateText(rate: downRate),
                ),
                const SizedBox(width: kResizerWidth),
                CellBox(
                  width: widget.widths[7],
                  alignRight: true,
                  child: Text(
                    age == null ? '—' : _shortDuration(age),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(mono: true),
                  ),
                ),
                const SizedBox(width: kResizerWidth),
                SizedBox(
                  width: _kCloseWidth,
                  child: widget.onClose == null
                      ? null
                      : IconButton(
                          tooltip: '关闭该连接',
                          iconSize: 14,
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close),
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

/// A rate cell. Zero is written as a dash, not as "0 B/s": a connection that is
/// idle and one that has never been sampled should not look the same as a
/// connection that is transferring nothing measurable.
class _RateText extends StatelessWidget {
  const _RateText({required this.rate, this.dim = false});

  final double rate;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    if (rate <= 0) {
      return Text(
        '—',
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: 'Consolas',
          color: p.textTertiary,
        ),
      );
    }
    return Text(
      rateLabel(rate),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 11.5,
        fontFamily: 'Consolas',
        fontWeight: dim ? FontWeight.w400 : FontWeight.w600,
        color: dim
            ? p.textSecondary
            : HaloColors.adapt(HaloColors.success, p.isDark),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.total,
    required this.visible,
    required this.selected,
    required this.busy,
  });

  final int total;
  final int visible;
  final int selected;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final parts = [
      visible == total ? '$total 条连接' : '$visible / $total 条连接',
      if (selected > 0) '已选 $selected',
      if (busy) '处理中…',
    ];
    return Row(
      children: [
        Text(
          parts.join(' · '),
          style: TextStyle(fontSize: 11.5, color: p.textSecondary),
        ),
        const Spacer(),
        Text(
          'Ctrl+A 全选 · Delete 关闭 · Ctrl+F 搜索 · F5 刷新',
          style: TextStyle(fontSize: 11, color: p.textTertiary),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Row(
      children: [
        Icon(
          Icons.error_outline,
          size: 14,
          color: HaloColors.adapt(HaloColors.danger, p.isDark),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: HaloColors.adapt(HaloColors.danger, p.isDark),
            ),
          ),
        ),
      ],
    );
  }
}

/// A duration short enough for a 50 px column: `12s`, `4m`, `1h2m`.
String _shortDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  final hours = d.inHours;
  final minutes = d.inMinutes - hours * 60;
  return '${hours}h${minutes}m';
}
