import 'dart:async';

import 'package:flutter/material.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../../state/app_controller.dart';
import '../../theme.dart';
import '../app.dart';
import '../widgets.dart';

/// Bounded log viewer. The host keeps the file capped; this keeps the in-memory
/// ring capped too, so a long session cannot grow the UI without limit.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const _maxLines = 2000;

  /// Log lines are appended by the host in bursts (core startup prints dozens in
  /// a row). Rebuilding the whole list once per line turned a burst into a
  /// visible stall, so appends are collected here and flushed on a timer — the
  /// same batching the reference client does at 50 ms.
  static const _flushDelay = Duration(milliseconds: 80);

  final List<LogEntry> _lines = <LogEntry>[];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<LogEntry>? _sub;
  Timer? _flush;
  Timer? _poll;
  final List<LogEntry> _pending = <LogEntry>[];
  bool _follow = true;
  String _filter = '';
  String? _levelFilter;

  /// Whether host lines describing the client's own polling are hidden.
  ///
  /// The host logs every dispatch (`action=snapshot.get id=...`), and the UI
  /// polls three actions continuously, so the default view is dominated by
  /// records of the UI reading the log it is showing. They are hidden by
  /// default and the switch above brings them back; anything that is not a
  /// routine read stays visible regardless, so an error is never hidden.
  bool _routineHidden = true;

  /// Actions the UI issues on a timer. Matched against the `action=` field the
  /// host writes, not against free text, so a genuine error mentioning one of
  /// these names is still shown.
  static const _routineActions = {
    'snapshot.get',
    'connections.list',
    'log.tail',
    'host.status',
  };

  /// True for a host line that only records the UI's own routine polling.
  ///
  /// A line qualifies only when it carries the host's `[host] action=... id=...`
  /// shape *and* names a routine action. Requiring both means a failed request
  /// (logged at another level, with a different shape) is never swallowed.
  static bool _isRoutinePoll(LogEntry line) {
    if (line.level.toLowerCase() != 'info') return false;
    final msg = line.message;
    if (!msg.startsWith('[host] action=')) return false;
    final start = msg.indexOf('action=') + 'action='.length;
    var end = msg.indexOf(' ', start);
    if (end < 0) end = msg.length;
    return _routineActions.contains(msg.substring(start, end));
  }

  /// How often the page re-reads the host log.
  ///
  /// The host does not push `log.appended` events today (it only answers
  /// `log.tail`), so a page that subscribed alone would show nothing at all:
  /// the single tail fetched at connect time arrived before this page existed.
  /// Polling is the smallest honest fix and keeps the protocol unchanged; the
  /// interval is long enough that a 200-line tail costs nothing.
  static const _pollInterval = Duration(milliseconds: 1500);

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _sub = c.logLines.listen(_onLine);
    unawaited(_pollOnce());
    _poll = Timer.periodic(_pollInterval, (_) => unawaited(_pollOnce()));
  }

  @override
  void dispose() {
    _flush?.cancel();
    _poll?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Fetches the tail and appends only the lines this page has not shown yet.
  ///
  /// A plain `addAll` would re-append the same 200 lines every poll. The
  /// overlap used to be found by matching the currently-last line on
  /// `atMs + message`; that was doubly wrong. `atMs` was the log *file's*
  /// modification time on every row, so one append shifted the whole history,
  /// and text-matching breaks outright on two identical consecutive lines.
  /// The host now stamps each line with a stable byte offset, so "new" is
  /// exactly "seq greater than the last seq shown" — no searching, and it
  /// degrades correctly after rotation, when seq restarts below the mark.
  Future<void> _pollOnce() async {
    final fresh = await c.fetchLogTail();
    if (!mounted || fresh.isEmpty) return;
    final List<LogEntry> append;
    if (_lines.isEmpty) {
      append = fresh;
    } else {
      final lastSeq = _lines.last.seq;
      final rotated = fresh.last.seq < lastSeq;
      append = rotated
          ? fresh
          : fresh.where((l) => l.seq > lastSeq).toList(growable: false);
    }
    if (append.isEmpty) return;
    setState(() {
      _lines.addAll(append);
      if (_lines.length > _maxLines) {
        _lines.removeRange(0, _lines.length - _maxLines);
      }
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _onLine(LogEntry entry) {
    if (!mounted) return;
    _pending.add(entry);
    // A single pending flush serves the whole burst: the first line arms it and
    // every following line rides along.
    _flush ??= Timer(_flushDelay, _applyPending);
  }

  void _applyPending() {
    _flush = null;
    if (!mounted || _pending.isEmpty) return;
    setState(() {
      _lines.addAll(_pending);
      _pending.clear();
      if (_lines.length > _maxLines) {
        _lines.removeRange(0, _lines.length - _maxLines);
      }
    });
    if (_follow) {
      // Jump to the newest line only while following, so scrolling up to read
      // something does not fight the incoming stream.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  List<LogEntry> get _filtered {
    var list = _lines;
    if (_levelFilter != null) {
      list = list.where((l) => l.level.toLowerCase() == _levelFilter).toList();
    }
    if (_routineHidden) {
      list = list.where((l) => !_isRoutinePoll(l)).toList();
    }
    if (_filter.isNotEmpty) {
      final q = _filter.toLowerCase();
      list = list.where((l) => l.message.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    // One filter pass per build: the getter used to be re-evaluated for
    // isEmpty, for itemCount and once per visible row, scanning the whole
    // 2000-line buffer up to "rows + 2" times per frame while a filter was
    // active.
    final visible = _filtered;
    final p = HaloPalette.of(context);
    return HaloPageScaffold(
      title: '日志',
      subtitle: '最多保留 $_maxLines 行；日志已脱敏，不包含密码或令牌',
      actions: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The reference design has one switch and one segmented control;
            // this page used a bare Material Switch, which renders at a
            // different size from every other switch in the app.
            // Label before control, left to right, like every other row on
            // this page: the switch used to sit to the left of its own label.
            const Text('跟随', style: TextStyle(fontSize: 11.5)),
            const SizedBox(width: 6),
            HaloSwitch(
              value: _follow,
              semanticLabel: '跟随最新',
              onChanged: (v) => setState(() => _follow = v),
            ),
            const SizedBox(width: 12),
            HaloDropdown<String?>(
              key: const ValueKey('log-level-filter'),
              width: 150,
              value: _levelFilter,
              hint: '全部级别',
              items: const [
                (null, '全部级别'),
                ('info', 'info'),
                ('warn', 'warn'),
                ('error', 'error'),
              ],
              onChanged: (v) => setState(() => _levelFilter = v),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => setState(_lines.clear),
              icon: const Icon(Icons.delete_sweep_outlined, size: 15),
              label: const Text('清空显示'),
            ),
          ],
        ),
      ],
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _filter = v),
                  decoration: const InputDecoration(
                    hintText: '过滤日志内容',
                    prefixIcon: Icon(Icons.filter_alt_outlined, size: 16),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Routine request logging is what the host writes for every poll
              // the UI itself makes (`snapshot.get`, `connections.list`,
              // `log.tail`). Left on, the page is a wall of the client talking
              // to itself and the one line that explains a failure is lost.
              // Off by default, but still reachable: hiding is a display
              // choice, not a cap on what the host records.
              // One line, matching the 32px search field beside it. This was a
              // two-line HaloSwitchTile, which made the whole filter row 52px
              // tall to accommodate a 12px caption.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '例行请求',
                    style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                  ),
                  const SizedBox(width: 6),
                  HaloSwitch(
                    value: !_routineHidden,
                    semanticLabel: '显示例行请求',
                    onChanged: (v) => setState(() => _routineHidden = !v),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _routineHidden ? '隐藏中' : '显示',
                    style: TextStyle(fontSize: 11, color: p.textTertiary),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: HaloMetrics.blockGap),
          Expanded(
            child: Card(
              child: visible.isEmpty
                  ? EmptyState(
                      title: '暂无日志',
                      message: _routineHidden
                          ? '后台服务写入的日志会实时出现在这里。\n例行轮询记录当前已隐藏。'
                          : '后台服务写入的日志会实时出现在这里。',
                      icon: Icons.receipt_long_outlined,
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: visible.length,
                        itemExtent: 22,
                        itemBuilder: (context, index) {
                          final line = visible[index];
                          return _LogRow(line: line);
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.line});

  final LogEntry line;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (line.level.toLowerCase()) {
      'error' => HaloColors.danger,
      'warn' => HaloColors.warning,
      'debug' =>
        dark ? HaloColors.darkTextSecondary : HaloColors.lightTextSecondary,
      _ => dark ? HaloColors.darkTextPrimary : HaloColors.lightTextPrimary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Text(
            formatTime(line.atMs),
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'Consolas',
              color: dark
                  ? HaloColors.darkTextSecondary
                  : HaloColors.lightTextSecondary,
            ),
          ),
          const SizedBox(width: 8),
          // A dot carries the severity at a glance; the word stays for anyone
          // filtering or copying the line.
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 40,
            child: Text(
              line.level.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'Consolas',
                color: color,
              ),
            ),
          ),
          Expanded(
            child: Text(
              line.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'Consolas',
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
