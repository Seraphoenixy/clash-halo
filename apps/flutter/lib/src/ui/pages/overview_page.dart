import 'dart:async';

import 'package:flutter/material.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

import '../../state/app_controller.dart';
import '../../state/exit_info.dart';
import '../../state/home_cards.dart';
import '../../state/throughput.dart';
import '../../theme.dart';
import '../app.dart';
import '../shell.dart';
import '../tun_card.dart';
import '../widgets.dart';
import '../widgets/sparkline.dart';
import '../widgets/measurement.dart';

/// Dashboard: the answer to "is the proxy working, and what do I do next".
///
/// Follows the layout both reference clients converged on: one card per
/// question, each card carrying exactly *one* primary action, and every card
/// stating the observed state rather than the requested one. The previous
/// version put four mutually exclusive core buttons (start/stop/restart plus a
/// refresh in the header) on the same card, so the one button that could
/// actually help was rarely the one that looked available.
///
/// ## Rhythm
///
/// Cards are separated by [HaloMetrics.cardGap] and blocks *inside* a card by
/// [HaloMetrics.blockGap]; nothing here invents a third value. The previous
/// build mixed 8px (between cards), 8px (between the banner and the grid), 0px
/// (between the last card of a column and the full-width card under it), 2/4/6px
/// (inside cards) and 10px (banner padding) — four answers to "how far apart are
/// two things", which is what "the spacing is uneven" means in practice.
///
/// ## Hierarchy
///
/// A dashboard is read for *values*, so every measurable thing (latency,
/// throughput, the exit IP) is set in [haloMetricStyle] — one tabular figure
/// size — while its label drops to 11.5. Before this, the page used 10.5, 11,
/// 11.5, 12, 12.5, 13, 13.5 and 14px with no rule, so "0 B/s" was quieter than
/// the caption under it and no row read as the thing to look at.
class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.controller,
    this.onOpenPage,
    this.onRunStep,
    this.exitService,
  });

  final AppController controller;

  /// Overrides the exit lookup. Tests inject one so the dashboard never reaches
  /// the network for real: `flutter test` would otherwise attempt it on every
  /// build of the page with a running core.
  final ExitInfoService? exitService;

  /// Lets the page's empty and next-step states send the user to another page.
  final ValueChanged<HaloPage>? onOpenPage;

  /// Runs the outstanding step instead of merely navigating to it.
  ///
  /// Without this the next-step card's button was a dead end for a step that
  /// points at this very page (「去启动」): navigation saw it was already here
  /// and returned.
  final Future<void> Function(NextStep step)? onRunStep;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

/// Below this the cards stack. Two 380px columns of half-width labels are worse
/// than a longer page, and the breakpoint has to leave a pair of cards wide
/// enough for the 216px mode selector plus its label.
const double _twoColumnBreakpoint = 860;

class _OverviewPageState extends State<OverviewPage> {
  bool _busy = false;

  /// Which cards the user keeps on this page.
  HomeCards _cards = HomeCards.defaults;

  /// Set once [_cards] has actually been read from the store.
  ///
  /// The store opens after the first frame (see main), so initState may run
  /// before the settings are readable; the load is retried on the next
  /// runtime tick instead of being silently skipped.
  bool _cardsLoaded = false;

  final ThroughputMonitor _throughput = ThroughputMonitor(
    historyLength: 40,
    proxyOnly: true,
  );
  Timer? _trafficTimer;
  (int, int)? _trafficCore;
  bool _trafficPolling = false;

  /// Bumped when the traffic poll produces new data, so the poll repaints
  /// only the traffic card — the previous implementation called setState for
  /// the whole page every two seconds while five of the six cards had not
  /// changed.
  final ValueNotifier<int> _trafficRevision = ValueNotifier<int>(0);

  String? _trafficError;

  /// Exit information, fetched through the running node.
  ExitInfo? _exit;
  bool _exitBusy = false;
  ExitLookupError? _exitError;

  /// The node the exit information (or the failed attempt for it) belongs to.
  ///
  /// Kept separate from [ExitInfo] because a *failed* lookup must also stop
  /// retrying: the page rebuilds on every snapshot tick, and without this the
  /// card would fire a request at each of them.
  String? _exitNodeId;
  bool _exitAttempted = false;

  /// Automatic retries already spent for the current node.
  ///
  /// One is allowed because the first lookup usually happens the instant the
  /// snapshot says "running", which can be before the mixed inbound accepts
  /// connections; the failure then describes the startup race, not the exit.
  int _exitRetries = 0;

  /// A `tun.setEnabled` request is in flight.
  ///
  /// Enabling TUN raises a UAC prompt and the host may take up to 90 seconds to
  /// answer, so the page tracks the wait itself instead of relying on the
  /// generic [_busy] flag (which only covers short commands).
  bool _tunPending = false;
  String? _tunNotice;
  Color? _tunNoticeColor;

  /// Latency results arrive through a stream that bumps no revision, so a card
  /// showing "测延迟" would never repaint without listening to it.
  StreamSubscription<SpeedResult>? _speedSub;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _ensureCards();
    _speedSub = c.speedUpdates.listen((_) {
      if (mounted) setState(() {});
    });
    c.runtimeRevision.addListener(_onRuntime);
    _onRuntime();
  }

  @override
  void dispose() {
    _trafficTimer?.cancel();
    _speedSub?.cancel();
    _trafficRevision.dispose();
    c.runtimeRevision.removeListener(_onRuntime);
    super.dispose();
  }

  /// Reads the card preferences once the store is actually open.
  void _ensureCards() {
    if (_cardsLoaded || !c.storeReady) return;
    _cards = HomeCards.load(c.settingsRepo);
    _cardsLoaded = true;
  }

  /// Reacts to the core starting or stopping: polling and the exit lookup both
  /// need a running core, and neither may run when nothing is listening.
  void _onRuntime() {
    _ensureCards();
    _syncTrafficPolling();
    final activeId = c.snapshot?.activeNodeId;
    if (activeId != _exitNodeId) {
      // The previous answer described another exit. Showing it under the new
      // node's name would be the same mistake as a stale latency next to a
      // freshly measured row.
      _exitNodeId = activeId;
      _exit = null;
      _exitAttempted = false;
      _exitError = null;
      _exitRetries = 0;
    }
    if (_ready && !_exitAttempted) {
      _exitAttempted = true;
      unawaited(_refreshExit());
    }
    if (mounted) setState(() {});
  }

  bool get _ready => c.connected && (c.snapshot?.coreState.isRunning ?? false);

  late final ExitInfoService _exitService =
      widget.exitService ?? ExitInfoService(proxyResolver: _proxyEndpoint);

  void _syncTrafficPolling() {
    // Polling a stopped core would answer with the host's "busy" error twice a
    // second and paint an error on a card about a feature that is simply idle.
    final snap = c.snapshot;
    final core = _cards.isVisible(HomeCard.traffic) && _ready && snap != null
        ? (snap.corePid, snap.tunPid)
        : null;
    if (core == _trafficCore) return;
    _trafficCore = core;
    _trafficTimer?.cancel();
    _trafficTimer = null;
    _throughput.reset();
    _trafficError = null;
    if (core != null) {
      _trafficTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_pollTraffic());
      });
      unawaited(_pollTraffic());
    }
  }

  Future<void> _pollTraffic() async {
    final timer = _trafficTimer;
    if (timer == null || _trafficPolling) return;
    _trafficPolling = true;
    try {
      final snapshot = await c.fetchConnections();
      if (!mounted || timer != _trafficTimer) return;
      _throughput.sample(snapshot, DateTime.now());
      _trafficError = null;
      _trafficRevision.value++;
    } catch (error) {
      if (!mounted || timer != _trafficTimer) return;
      _trafficError = '$error';
      _trafficRevision.value++;
    } finally {
      _trafficPolling = false;
    }
  }

  Future<void> _refreshExit({bool automatic = false}) async {
    if (_exitBusy) return;
    if (!automatic) _exitRetries = 0;
    _exitAttempted = true;
    setState(() {
      _exitBusy = true;
      _exitError = null;
    });
    try {
      final info = await _exitService.lookup();
      if (!mounted) return;
      setState(() => _exit = info);
    } on ExitLookupError catch (error) {
      if (!mounted) return;
      setState(() => _exitError = error);
      if (_exitRetries < 1) {
        _exitRetries++;
        Timer(const Duration(seconds: 5), () {
          if (mounted && _exit == null) {
            unawaited(_refreshExit(automatic: true));
          }
        });
      }
    } catch (error) {
      if (!mounted) return;
      // Anything else is ours, not the service's: show it verbatim so a bug in
      // this page is not dressed up as "the node is restrictive".
      setState(() => _exitError = ExitLookupError('查询失败', '$error'));
    } finally {
      if (mounted) setState(() => _exitBusy = false);
    }
  }

  /// The mixed inbound of the running core, read from the same settings the
  /// config was generated from. Null unless the core is actually running.
  String? _proxyEndpoint() {
    if (!_ready) return null;
    final port = c.routing.mixedPort;
    return port > 0 ? '127.0.0.1:$port' : null;
  }

  Future<void> _testActiveNode() async {
    final id = c.snapshot?.activeNodeId;
    if (id == null || id.isEmpty) return;
    try {
      await c.startSpeedTest(nodeIds: [id]);
    } catch (error) {
      if (!mounted) return;
      showHaloToast(context, '测延迟失败：$error');
    }
  }

  Future<void> _openCardSettings() async {
    final next = await showDialog<HomeCards>(
      context: context,
      builder: (context) => _CardSettingsDialog(cards: _cards),
    );
    if (next == null || !mounted) return;
    setState(() => _cards = next);
    if (c.storeReady) next.save(c.settingsRepo);
    _syncTrafficPolling();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) await c.refreshSnapshot();
    } catch (_) {
      // The controller records the message for the status bar; the page only
      // needs to stop showing a spinner.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Toggles TUN and keeps the outcome next to the switch.
  ///
  /// A refused UAC prompt arrives as `elevation_denied`; that is a normal
  /// answer from the user, so it is shown as information rather than as a
  /// crash. Everything else keeps the host's `detail`, the only actionable
  /// text for a broken service or a bad config.
  Future<void> _toggleTun(bool enabled) async {
    if (_tunPending) return;
    setState(() {
      _tunPending = true;
      _tunNotice = null;
      _tunNoticeColor = null;
    });
    try {
      await c.setTun(enabled);
      if (mounted) {
        setState(() {
          _tunNotice = enabled ? 'TUN 已启用。' : 'TUN 已关闭。';
          _tunNoticeColor = HaloColors.success;
        });
      }
    } on HaloError catch (error) {
      if (mounted) {
        setState(() {
          _tunNotice = tunErrorText(error);
          _tunNoticeColor = tunErrorColor(error.code);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _tunNotice = 'TUN 操作失败：$error';
          _tunNoticeColor = HaloColors.danger;
        });
      }
    } finally {
      if (mounted) await c.refreshSnapshot();
      if (mounted) setState(() => _tunPending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = c.snapshot;
    return HaloPageScaffold(
      title: '总览',
      // A description of the page, not a third copy of the next step.
      //
      // The connection state was stated here, in the sidebar and in the status
      // bar at once; replacing it with the next-step *title* made it worse,
      // because that sentence is also in the banner below and in the status
      // bar. The banner is where the detail belongs (it has the action and the
      // explanation), the status bar is the persistent summary, and this line
      // just says what the page is.
      subtitle: c.connected ? '运行状态与常用开关' : '正在等待后台服务…',
      actions: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(right: 10),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        OutlinedButton.icon(
          onPressed: c.connected && !_busy
              ? () => _run(c.refreshSnapshot)
              : null,
          icon: const Icon(Icons.refresh, size: 15),
          label: const Text('刷新'),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _openCardSettings,
          tooltip: '选择要显示的卡片',
          iconSize: 17,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.tune),
        ),
      ],
      child: snap == null
          ? const EmptyState(
              message: '尚未获取到运行状态。\n请确认后台服务已启动，然后点击刷新。',
              icon: Icons.cloud_off_outlined,
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // Two columns only when there is room for two readable cards;
                // below that the same widgets stack, because a 380px column of
                // half-width labels is worse than a longer page.
                final twoColumns = constraints.maxWidth >= _twoColumnBreakpoint;
                // Visual order — deliberately *not* the enum order. Cards are
                // placed in pairs, and the pairs are chosen so the two cards of
                // a row are similar heights and belong to the same question:
                //
                //   当前节点 | 实时流量      who am I going through, how fast
                //   代理内核 | 出口信息      is it up, where does it come out
                //   系统代理 | TUN 模式      the two switches that take over
                //
                // The old order put 出口信息 (tall) next to 代理内核 and left
                // TUN (short) beside nothing, so one row ended 75px below its
                // neighbour. Pairing by height *and* by subject removes the
                // hole without hiding a card the user asked for.
                final cards = <Widget>[
                  if (_cards.isVisible(HomeCard.node))
                    _CurrentNodeCard(
                      controller: c,
                      snapshot: snap,
                      onTestLatency: _ready ? _testActiveNode : null,
                      onOpenNodes: () =>
                          widget.onOpenPage?.call(HaloPage.nodes),
                    ),
                  if (_cards.isVisible(HomeCard.traffic))
                    ValueListenableBuilder<int>(
                      valueListenable: _trafficRevision,
                      builder: (context, _, _) => _TrafficCard(
                        throughput: _throughput,
                        error: _trafficError,
                        running: _ready,
                      ),
                    ),
                  if (_cards.isVisible(HomeCard.core))
                    _CoreCard(
                      controller: c,
                      snapshot: snap,
                      busy: _busy,
                    ),
                  if (_cards.isVisible(HomeCard.exit))
                    _ExitCard(
                      info: _exit,
                      busy: _exitBusy,
                      error: _exitError,
                      onRefresh: _ready ? _refreshExit : null,
                    ),
                  if (_cards.isVisible(HomeCard.proxy))
                    // The proxy switch has its own channel: flipping it must
                    // repaint this card, not the page holding it.
                    ValueListenableBuilder<int>(
                      valueListenable: c.proxyRevision,
                      builder: (context, _, _) => _ProxyCard(
                        controller: c,
                        snapshot: c.snapshot ?? snap,
                        busy: _busy,
                      ),
                    ),
                  if (_cards.isVisible(HomeCard.tun))
                    // Its subtitle changes with the proxy switch ("启用后将关闭
                    // 系统代理"), so it listens to that channel too.
                    ValueListenableBuilder<int>(
                      valueListenable: c.proxyRevision,
                      builder: (context, _, _) => TunCard(
                        snapshot: c.snapshot ?? snap,
                        connected: c.connected && !_busy,
                        pending: _tunPending,
                        notice: _tunNotice,
                        noticeColor: _tunNoticeColor,
                        onToggle: (v) => _toggleTun(v),
                      ),
                    ),
                ];

                // Cards are laid out as *rows of two* that share one height,
                // not as two independent columns.
                //
                // The independent-column version needed no intrinsic height,
                // but each row then ended wherever its own content ended, so
                // the left column finished 80px above the right one and the
                // full-width card underneath started after a hole. Equal-height
                // rows keep one baseline across the page; the price is that the
                // shorter card of a pair carries some empty space at its bottom,
                // which reads as breathing room rather than as a missing card.
                //
                // This works because no card contains a `LayoutBuilder` any
                // more: a layout builder cannot report an intrinsic height, and
                // that is what made the previous attempt at paired rows leave a
                // hole. The old detail lists used one to switch between one and
                // two columns; they now take their column count as a parameter.
                final Widget body;
                if (!twoColumns) {
                  body = Column(
                    children: _separated(
                      cards,
                      const SizedBox(height: HaloMetrics.cardGap),
                    ),
                  );
                } else {
                  final rows = <Widget>[];
                  for (var i = 0; i < cards.length; i += 2) {
                    final left = cards[i];
                    final right = i + 1 < cards.length ? cards[i + 1] : null;
                    rows.add(
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: left),
                            const SizedBox(width: HaloMetrics.cardGap),
                            Expanded(child: right ?? const SizedBox.shrink()),
                          ],
                        ),
                      ),
                    );
                  }
                  body = Column(
                    children: _separated(
                      rows,
                      const SizedBox(height: HaloMetrics.cardGap),
                    ),
                  );
                }

                final showBanner = _bannerVisible(c);
                return ListView(
                  children: [
                    if (showBanner) ...[
                      _NextStepCard(
                        controller: c,
                        onOpenPage: widget.onOpenPage,
                        onRunStep: widget.onRunStep,
                      ),
                      const SizedBox(height: HaloMetrics.cardGap),
                    ],
                    body,
                    if (_cards.isVisible(HomeCard.status)) ...[
                      SizedBox(height: cards.isEmpty ? 0 : HaloMetrics.cardGap),
                      _StatusCard(
                        snapshot: snap,
                        // Three columns need room for a label *and* a value in
                        // each cell. At 420px (a 200%-scaled window showing one
                        // column) a third made 更新时间 wrap onto three lines;
                        // the card is a reference table, not a puzzle.
                        columns: constraints.maxWidth >= 880
                            ? 3
                            : constraints.maxWidth >= 560
                            ? 2
                            : 1,
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

/// Inserts [gap] between [children] and nowhere else.
List<Widget> _separated(List<Widget> children, Widget gap) {
  final out = <Widget>[];
  for (var i = 0; i < children.length; i++) {
    if (i > 0) out.add(gap);
    out.add(children[i]);
  }
  return out;
}

/// Whether the page has anything to say at the top.
///
/// Shared with [_NextStepCard] so the card and the gap before it agree: a
/// `SizedBox.shrink` banner plus an unconditional gap would leave 12px of dead
/// space at the top of an otherwise finished page.
bool _bannerVisible(AppController controller) {
  if (controller.nextStep != null) return true;
  final snap = controller.snapshot;
  if (snap == null) return false;
  return snap.systemProxy.enabled || snap.tunState == TunState.enabled;
}

/// The one outstanding instruction, or a green "all set" line.
///
/// This is the page-local twin of the status bar hint: on the home page the user
/// gets the full sentence plus the button, because that is where they land after
/// a cold start.
class _NextStepCard extends StatelessWidget {
  const _NextStepCard({
    required this.controller,
    this.onOpenPage,
    this.onRunStep,
  });

  final AppController controller;
  final ValueChanged<HaloPage>? onOpenPage;
  final Future<void> Function(NextStep step)? onRunStep;

  @override
  Widget build(BuildContext context) {
    final step = controller.nextStep;
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    if (step == null) {
      // Nothing outstanding. Only claim readiness when it is true.
      //
      // With the 流量还没有接管 step gone, "nothing outstanding" now also covers
      // "core running but system proxy and TUN both off" — a state in which the
      // green 代理已就绪 line would be a lie. In that case the page shows no
      // banner at all: the 系统代理 and TUN cards directly below already carry
      // 已关闭 and their own switches, which is the whole point of removing the
      // banner.
      final snap = controller.snapshot;
      final intercepted =
          (snap?.systemProxy.enabled ?? false) ||
          ((snap?.tunState ?? TunState.disabled) == TunState.enabled);
      if (!intercepted) return const SizedBox.shrink();
      final success = HaloColors.adapt(HaloColors.success, p.isDark);
      return SectionCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 15, color: success),
            const SizedBox(width: 8),
            Text(
              '代理已就绪，流量正走当前节点。',
              style: text.bodyMedium?.copyWith(color: success),
            ),
          ],
        ),
      );
    }
    // Only `waiting` spins: it means something is actually in flight (the host
    // is still booting). A stopped host will not change on its own, so showing
    // a spinner there is what made a dead background service look like a
    // forever-loading app.
    final waiting = step.kind == NextStepKind.waiting;
    final stopped = step.kind == NextStepKind.stopped;
    final accent = HaloColors.adapt(
      waiting
          ? HaloColors.info
          : stopped
          ? HaloColors.danger
          : HaloColors.warning,
      p.isDark,
    );
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(
        children: [
          Icon(
            waiting
                ? Icons.hourglass_top
                : stopped
                ? Icons.power_settings_new
                : Icons.arrow_circle_right_outlined,
            size: 16,
            color: accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: text.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: HaloMetrics.hairGap),
                Text(step.detail, style: text.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // No button and no spinner for a stopped host: there is no action to
          // run (`onRunStep` would retry a dead pipe) and nothing in flight. The
          // title/detail above already say what to do.
          if (!waiting && !stopped)
            FilledButton(
              onPressed: onRunStep != null
                  ? () => onRunStep!(step)
                  : onOpenPage == null
                  ? null
                  : () => onOpenPage!(HaloPage.forStep(step.page)),
              child: Text(step.actionLabel),
            )
          else if (waiting)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _CoreCard extends StatelessWidget {
  const _CoreCard({
    required this.controller,
    required this.snapshot,
    required this.busy,
  });

  final AppController controller;
  final RuntimeSnapshot snapshot;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final state = snapshot.coreState;
    final running = state.isRunning;
    final enabled = controller.connected && !busy;
    final path = (snapshot.singboxPath ?? '').trim();
    final error = (snapshot.lastErrorMessage ?? '').trim();
    // Under TUN the core is the service's child, not this host's, so corePid is
    // deliberately 0 — showing "—" there read as "no process" next to a card
    // claiming 运行中. The tunnel's own pid is the honest number.
    final tunOn = snapshot.tunState == TunState.enabled;
    final pidText = tunOn
        ? (snapshot.tunPid == 0 ? 'TUN 内核' : '${snapshot.tunPid}（TUN）')
        : (snapshot.corePid == 0 ? '—' : '${snapshot.corePid}');
    return SectionCard(
      title: '代理内核',
      trailing: StatusChip(
        label: coreStateLabel(state),
        color: coreStateColor(state),
        icon: running ? Icons.play_circle_outline : Icons.pause_circle_outline,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // One primary action, chosen by state, plus the two secondary ones.
          // Restart is the only thing that ever needs pressing twice.
          Row(
            children: [
              if (!running)
                FilledButton.icon(
                  onPressed: enabled ? () => _guard(controller.startCore) : null,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('启动内核'),
                )
              else
                OutlinedButton.icon(
                  onPressed: enabled ? () => _guard(controller.stopCore) : null,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('停止内核'),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: enabled && running
                    ? () => _guard(controller.restartCore)
                    : null,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重启'),
              ),
            ],
          ),
          const SizedBox(height: HaloMetrics.blockGap),
          _Facts(
            items: [
              ('进程 PID', pidText),
              (
                '内核版本',
                snapshot.coreVersion.isEmpty ? '未知' : snapshot.coreVersion,
              ),
              ('重启次数', '${snapshot.coreRestarts}'),
              (
                '配置版本',
                snapshot.configVersion == 0
                    ? '尚未应用'
                    : 'v${snapshot.configVersion}',
              ),
            ],
          ),
          // The path is one long, copyable value; it gets its own full-width
          // line with an ellipsis and a tooltip rather than wrapping into two
          // fragments no one can read or paste.
          if (path.isNotEmpty) ...[
            const SizedBox(height: HaloMetrics.lineGap),
            Tooltip(
              message: path,
              child: _Fact(
                label: '内核路径',
                value: path,
                maxLines: 1,
                selectable: false,
              ),
            ),
          ],
          // An empty string is not an error. Rendering the label with no value
          // cost a whole row and read as a field that failed to load.
          if (error.isNotEmpty) ...[
            const SizedBox(height: HaloMetrics.lineGap),
            Text(
              '最近错误：$error',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: haloAdapt(context, HaloColors.danger),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProxyCard extends StatelessWidget {
  const _ProxyCard({
    required this.controller,
    required this.snapshot,
    required this.busy,
  });

  final AppController controller;
  final RuntimeSnapshot snapshot;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final proxy = snapshot.systemProxy;
    final on = proxy.enabled;
    // The two switches are one choice: only one core runs, and TUN holding the
    // inbound is what made the ordinary core die on the port. Turning this one
    // on is how the user switches back, so it stays clickable — greying it left
    // TUN as the only reachable mode from this card.
    final tunOn = snapshot.tunState == TunState.enabled;
    final enabled = controller.connected && !busy && proxy.supported;
    final text = Theme.of(context).textTheme;
    return SectionCard(
      title: '系统代理',
      trailing: StatusChip(
        label: on ? '已开启' : '已关闭',
        color: on ? HaloColors.success : HaloColors.lightTextSecondary,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HaloSwitchTile(
            title: '设置 Windows 系统代理',
            subtitle: tunOn
                ? '开启将关闭 TUN，切回普通代理'
                : proxy.supported
                ? (on ? '当前指向 ${proxy.endpoint}' : proxy.endpoint)
                : '当前系统不支持自动设置',
            value: on,
            onChanged: enabled
                ? (v) => _guard(() => controller.setSystemProxy(v))
                : null,
          ),
          const SizedBox(height: HaloMetrics.lineGap),
          // Explaining the restore rule matters: users otherwise blame the app
          // for "losing" a proxy another program set. It belongs directly under
          // the switch it describes — 4, not 8, or it reads as a new block.
          Text(
            on
                ? (proxy.restorable
                      ? '关闭时会恢复为开启前的系统设置。'
                      : '开启前的设置已变化，关闭时将保留当前值，不会覆盖其他程序的修改。')
                : '开启后关闭可恢复原设置；不会在退出时残留。',
            style: text.bodySmall,
          ),
          const SizedBox(height: HaloMetrics.blockGap),
          // The mode selector is a control on the same right-hand rail as the
          // switch above it, so the two line up instead of one filling the card
          // and the other hugging its left edge.
          Row(
            children: [
              Text('分流模式', style: text.bodySmall),
              const SizedBox(width: 12),
              const Spacer(),
              // A fixed width: the selector is a three-segment control, and
              // letting it fill the card turned it into a two-metre bar with
              // 8px labels floating in it.
              SizedBox(
                width: 216,
                child: HaloSelector<ProxyMode>(
                  options: const [
                    (ProxyMode.rule, '规则'),
                    (ProxyMode.global, '全局'),
                    (ProxyMode.direct, '直连'),
                  ],
                  value: snapshot.mode,
                  enabled: controller.connected && !busy,
                  onChanged: controller.connected && !busy
                      ? (mode) => _guard(() => controller.setMode(mode))
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.snapshot, required this.columns});

  final RuntimeSnapshot snapshot;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '运行信息',
      child: _Facts(
        columns: columns,
        items: [
          // No 当前节点 row here: the dedicated card above shows the same node
          // with its protocol, address and latency, and two labels for one fact
          // make the page look like it is reporting two different nodes.
          ('后台版本', snapshot.hostVersion),
          ('订阅更新', snapshot.subscriptionRunnerActive ? '进行中' : '空闲'),
          ('测速任务', snapshot.speedTestRunning ? '进行中' : '空闲'),
          ('日志大小', formatBytes(snapshot.logBytes)),
          ('状态版本', '${snapshot.stateVersion}'),
          ('更新时间', formatDateTime(snapshot.updatedAtMs)),
        ],
      ),
    );
  }
}

/// A grid of short label/value facts.
///
/// Takes its column count instead of measuring itself: `LayoutBuilder` cannot
/// report an intrinsic height, and a single one of them anywhere inside a card
/// breaks the equal-height rows the page uses to keep one baseline across both
/// columns.
class _Facts extends StatelessWidget {
  const _Facts({required this.items, this.columns = 2, this.labelWidth = 64});

  final List<(String, String)> items;
  final int columns;

  /// Width of the label column. Wide enough for 内核路径 / 重启次数; the exit
  /// card passes 48 because its labels are all two characters and every pixel
  /// of label inset is a pixel of value width lost.
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += columns) {
      final cells = <Widget>[];
      for (var column = 0; column < columns; column++) {
        final index = i + column;
        if (column > 0) cells.add(const SizedBox(width: 12));
        cells.add(
          Expanded(
            child: index < items.length
                ? _Fact(
                    label: items[index].$1,
                    value: items[index].$2,
                    labelWidth: labelWidth,
                  )
                : const SizedBox.shrink(),
          ),
        );
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: HaloMetrics.rowGap));
      rows.add(
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}

/// One label/value pair: 11.5 tertiary label, 13 primary value.
///
/// The old `InfoRow` (104px label column, values at 13) is still used by the
/// settings forms where the labels are long. Here the labels are two to four
/// characters and a 104px column pushed every value 116px away from the left
/// edge of the card it belongs to.
class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    this.labelWidth = 64,
    this.maxLines,
    this.selectable = true,
  });

  final String label;
  final String value;
  final double labelWidth;
  final int? maxLines;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final style = text.bodyLarge?.copyWith(color: p.textPrimary, height: 1.35);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: selectable
              // No maxLines: SelectableText reserves the full maxLines height
              // even for a one-line value (measured 38px versus 19px), which is
              // how every detail row grew to 44px.
              ? SelectableText(value, style: style)
              : Text(
                  value,
                  maxLines: maxLines,
                  overflow: maxLines == null ? null : TextOverflow.ellipsis,
                  style: style,
                ),
        ),
      ],
    );
  }
}

/// Wraps a controller call so a host rejection surfaces as a snackbar instead
/// of an unhandled async error.
void _guard(Future<void> Function() action) {
  unawaited(action().catchError((Object _) {}));
}

/// The node currently carrying traffic, with the two actions that belong here.
///
/// The reference client's home page leads with this card, and for good reason:
/// "which exit am I using, and how far away is it" is the question a dashboard
/// is opened to answer, and the status bar alone cannot show the latency.
class _CurrentNodeCard extends StatelessWidget {
  const _CurrentNodeCard({
    required this.controller,
    required this.snapshot,
    required this.onTestLatency,
    required this.onOpenNodes,
  });

  final AppController controller;
  final RuntimeSnapshot snapshot;
  final Future<void> Function()? onTestLatency;
  final VoidCallback onOpenNodes;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final id = snapshot.activeNodeId;
    ProxyNode? node;
    if (id != null && id.isNotEmpty) {
      for (final candidate in controller.loadNodes()) {
        if (candidate.id == id) {
          node = candidate;
          break;
        }
      }
    }
    final result = id == null || id.isEmpty
        ? null
        : controller.speedResults[id];
    final (label, color) = _latencyOf(p, result);

    return SectionCard(
      title: '当前节点',
      trailing: TextButton(
        onPressed: onOpenNodes,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 24),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          // A literal TextStyle here drops the theme's font *fallback* list,
          // and Segoe UI has no CJK glyphs — the label then renders as tofu.
          // Take the token instead.
          textStyle: Theme.of(context).textTheme.labelMedium,
        ),
        child: const Text('选择节点'),
      ),
      child: node == null
          ? const EmptyState(
              compact: true,
              icon: Icons.router_outlined,
              title: '尚未启用节点',
              message: '在「节点」页启用一个节点之后，流量才会走代理。',
            )
          // A one-line headline plus a single detail line, then one row holding
          // the measurement and its action. The old body stacked name, 协议 and
          // 地址 as separate label/value rows (~34px each because InfoRow
          // reserves a 104px label column) plus a fourth row for latency, so
          // four short facts took ~248px and pushed TUN and the runtime card
          // below the fold. Nothing here needs a label column: the values
          // identify themselves.
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                const SizedBox(height: HaloMetrics.hairGap),
                Text(
                  '${node.protocol.label} · ${node.server}:${node.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
                const SizedBox(height: HaloMetrics.blockGap),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('延迟', style: text.bodySmall),
                        const SizedBox(height: HaloMetrics.hairGap),
                        // The measurement is the reason this card exists, so it
                        // is set at the metric size instead of sharing 12px
                        // with the label above it.
                        Text(
                          label,
                          style: haloMetricStyle(
                            context,
                            size: 18,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: onTestLatency == null
                          ? null
                          : () => onTestLatency!(),
                      icon: const Icon(Icons.speed, size: 15),
                      label: const Text('测延迟'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  /// One label per measurement state, never a number that could be mistaken for
  /// a fresh reading: 未测, 测试中, 不可用 and 已取消 are different answers.
  (String, Color) _latencyOf(HaloPalette p, SpeedResult? result) {
    if (result == null) return ('未测', p.textTertiary);
    final ms = result.valueMs;
    return switch (result.status) {
      SpeedStatus.ok when ms != null => ('$ms ms', latencyColor(ms)),
      SpeedStatus.ok => ('不可用', HaloColors.warning),
      SpeedStatus.failed => ('不可用', HaloColors.danger),
      SpeedStatus.canceled => ('已取消', p.textTertiary),
      SpeedStatus.notApplicable => ('不适用', p.textSecondary),
      _ => ('测试中', p.textTertiary),
    };
  }
}

/// Live throughput for the traffic actually flowing through the node.
class _TrafficCard extends StatelessWidget {
  const _TrafficCard({
    required this.throughput,
    required this.error,
    required this.running,
  });

  final ThroughputMonitor throughput;
  final String? error;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final down = HaloColors.adapt(HaloColors.success, p.isDark);
    return SectionCard(
      title: '实时流量',
      child: !running
          ? const EmptyState(
              compact: true,
              icon: Icons.swap_vert,
              message: '内核未运行，暂无实时流量。启动内核后这里会显示上下行速率。',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _rate(
                        context,
                        '下行',
                        throughput.downRate,
                        down,
                        Icons.arrow_downward,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _rate(
                        context,
                        '上行',
                        throughput.upRate,
                        p.accent,
                        Icons.arrow_upward,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: HaloMetrics.blockGap),
                Sparkline(
                  samples: throughput.history,
                  up: p.accent,
                  down: down,
                  grid: p.border,
                  height: 34,
                  // "No sample yet" and "zero traffic" are different states and
                  // used to render identically as an empty box. The monitor only
                  // appends to history once it has two timestamps to difference.
                  placeholder: throughput.hasCurve ? null : '等待采样…',
                ),
                const SizedBox(height: HaloMetrics.blockGap),
                // The two footer lines are one block: without grouping them,
                // spaceBetween in a stretched card would push them apart and
                // they would stop reading as the caption under the chart.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '代理连接 ${throughput.activeConnections}',
                          style: text.labelSmall,
                        ),
                        const Spacer(),
                        Text(
                          '峰值 ↑${rateLabel(throughput.peakUp)} '
                          '↓${rateLabel(throughput.peakDown)}',
                          style: text.labelSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: HaloMetrics.hairGap),
                    Text(
                      '采样累计 ↑${formatBytes(throughput.uploadTotal)} '
                      '↓${formatBytes(throughput.downloadTotal)}',
                      style: text.labelSmall,
                    ),
                  ],
                ),
                if (error != null) ...[
                  const SizedBox(height: HaloMetrics.lineGap),
                  Text(
                    '读取连接失败：$error',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: haloAdapt(context, HaloColors.danger),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  /// One direction of the meter: a labelled icon row, then the rate itself at
  /// metric size.
  ///
  /// The two halves are `Expanded`, so the down and up figures sit on the same
  /// two vertical rails whether they read `0 B/s` or `12.4 MB/s`; the previous
  /// version packed them into one left-aligned row and the second figure moved
  /// with the width of the first.
  Widget _rate(
    BuildContext context,
    String label,
    double value,
    Color color,
    IconData icon,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ],
        ),
        const SizedBox(height: HaloMetrics.hairGap),
        Text(rateLabel(value), style: haloMetricStyle(context, color: color)),
      ],
    );
  }
}

/// What the outside world sees: the exit address, and who owns it.
///
/// Derived from a service reached through the node rather than from the node's
/// name, because a node labelled "日本" routinely exits in Korea.
class _ExitCard extends StatelessWidget {
  const _ExitCard({
    required this.info,
    required this.busy,
    required this.error,
    required this.onRefresh,
  });

  final ExitInfo? info;
  final bool busy;
  final ExitLookupError? error;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    return SectionCard(
      title: '出口信息',
      trailing: SizedBox(
        width: 28,
        height: 28,
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(7),
                child: CircularProgressIndicator(strokeWidth: 1.6),
              )
            : IconButton(
                onPressed: onRefresh == null ? null : () => onRefresh!(),
                tooltip: '重新查询',
                iconSize: 15,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh),
              ),
      ),
      child: info == null
          ? (error == null
                ? const EmptyState(
                    compact: true,
                    icon: Icons.public,
                    title: '尚未查询出口',
                    message: '内核运行后，会经当前节点查询这里显示的地址。',
                  )
                : Tooltip(
                    // The per-service reasons are the useful part but they are
                    // four lines of exception text; the card says the outcome.
                    message: error!.details,
                    child: Text(
                      '${error!.summary}（点右上角重试）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: haloAdapt(context, HaloColors.danger),
                      ),
                    ),
                  ))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  info!.ip,
                  style: haloMetricStyle(context, size: 20),
                ),
                const SizedBox(height: HaloMetrics.blockGap),
                _Facts(
                  columns: 1,
                  labelWidth: 48,
                  items: [
                    ('位置', _compactLocation(info!.location)),
                    ('网络', info!.network),
                    ('时区', info!.timezone.isEmpty ? '—' : info!.timezone),
                  ],
                ),
                const SizedBox(height: HaloMetrics.lineGap),
                // spaceBetween in a stretched card pushes the source line to the
                // bottom edge, level with the 代理内核 card's last detail row.
                Text(
                  '来自 ${info!.source}',
                  style: text.labelSmall?.copyWith(color: p.textTertiary),
                ),
              ],
            ),
    );
  }
}

/// Collapses repeated segments in a location such as
/// `South Korea · Seoul · Seoul`, which the lookup service does emit.
///
/// Repeating the city is not "more accurate": it reads as a bug in the row.
String _compactLocation(String raw) {
  final parts = raw
      .split('·')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty);
  final out = <String>[];
  for (final part in parts) {
    if (out.isEmpty || out.last != part) out.add(part);
  }
  return out.isEmpty ? '—' : out.join(' · ');
}

/// Chooses which cards the page shows.
class _CardSettingsDialog extends StatefulWidget {
  const _CardSettingsDialog({required this.cards});

  final HomeCards cards;

  @override
  State<_CardSettingsDialog> createState() => _CardSettingsDialogState();
}

class _CardSettingsDialogState extends State<_CardSettingsDialog> {
  late HomeCards _draft = widget.cards;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('显示的卡片'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final card in HomeCard.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      card.label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontSize: 12.5,
                        color: HaloPalette.of(context).textPrimary,
                      ),
                    ),
                  ),
                  HaloSwitch(
                    value: _draft.isVisible(card),
                    onChanged: (v) =>
                        setState(() => _draft = _draft.toggle(card)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: HaloMetrics.rowGap),
          Text(
            '「当前步骤」始终显示：它是这个页面存在的理由。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_draft),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
