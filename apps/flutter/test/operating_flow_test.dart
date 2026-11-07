import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/halo_client.dart' show HostConnectionState;
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/app.dart';
import 'package:halo/src/ui/shell.dart';
import 'package:halo/src/ui/status_bar.dart';
import 'package:halo/src/ui/widgets/measurement.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// Tests for the restructured operation flow.
///
/// Two things used to be true and are pinned here so they cannot come back:
///
///  * the app never said what to do next — a user with no subscription, no
///    active node and no proxy saw a dashboard of inert cards;
///  * every page was blind to the running state, because the only place that
///    showed it was the overview.
///
/// `nextStep` is the single source of that guidance, and the status bar and the
/// overview card both render it, so it is the right thing to unit-test.
void main() {
  late Directory tempDir;
  late AppController controller;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('halo_flow_test');
    controller = AppController(dataDir: tempDir.path);
  });

  tearDown(() async {
    await controller.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // A lingering WAL file can keep the directory busy on Windows.
    }
  });

  /// Seeds [count] nodes through the real import path so the fingerprint/dedupe
  /// behaviour matches what the app does.
  void seedNodes({int count = 1}) {
    final body = [
      for (var i = 0; i < count; i++)
        'trojan://password@host$i.example.com:443#node$i',
    ].join('\n');
    controller.saveImport(importNodes(body));
  }

  group('nextStep guidance', () {
    test('nothing is reported while the store is unavailable', () {
      // A controller that never started has no store: there is nothing
      // actionable to say yet, and inventing an instruction would be a lie.
      expect(controller.storeReady, isFalse);
      expect(controller.nextStep, isNull);
    });

    test('a missing host reads as waiting, not as a failure', () async {
      await controller.start(connectHost: false);
      final step = controller.nextStep;
      expect(step, isNotNull);
      expect(step!.title, contains('连接后台'));
      expect(step.kind, NextStepKind.waiting);
      expect(step.page, HaloStepPage.overview);
    });

    test('a version mismatch is reported as stopped, not as connecting',
        () async {
      // The pipe is up but the host speaks another wire version: every
      // request fails, so the guidance must not keep spinning as if the host
      // were still starting.
      await controller.start(connectHost: false);
      controller.applyConnectionStateForTest(
        HostConnectionState.versionMismatch,
      );

      expect(controller.connected, isFalse);
      final step = controller.nextStep!;
      expect(step.kind, NextStepKind.stopped);
      expect(step.title, contains('版本'));
    });

    test('a host that exits takes the window with it', () async {
      // The reported defect: tray 「退出」 stopped the host, but the Flutter
      // window stayed on screen — it treated host.exiting as a dropped
      // connection and kept scheduling reconnects against a dying process.
      await controller.start(connectHost: false);
      var exits = 0;
      final original = AppController.exitApp;
      AppController.exitApp = () async => exits++;
      addTearDown(() => AppController.exitApp = original);

      controller.applyEventForTest(
        const HaloEventMessage(name: HaloEvent.hostExiting),
      );

      expect(exits, 1, reason: '宿主退出后窗口必须退出');
      expect(controller.hostExiting, isTrue);
      expect(controller.connected, isFalse);
      // And it must not describe itself as "正在连接后台服务" any more.
      expect(controller.nextStep!.kind, NextStepKind.stopped);
      expect(controller.nextStep!.title, '后台服务已退出');
    });

    test('a host exit exits the window exactly once', () async {
      await controller.start(connectHost: false);
      var exits = 0;
      final original = AppController.exitApp;
      AppController.exitApp = () async => exits++;
      addTearDown(() => AppController.exitApp = original);

      controller.applyEventForTest(
        const HaloEventMessage(name: HaloEvent.hostExiting),
      );
      controller.applyEventForTest(
        const HaloEventMessage(name: HaloEvent.hostExiting),
      );
      expect(exits, 1, reason: '重复的 host.exiting 不能退出第二次');
    });

    test('a detached connection drop still reconnects', () async {
      // The fix must not turn every disconnect into an exit: a host that is
      // restarting or momentarily unreachable is the normal case, and the UI is
      // supposed to wait for it.
      await controller.start(connectHost: false);
      var exits = 0;
      final original = AppController.exitApp;
      AppController.exitApp = () async => exits++;
      addTearDown(() => AppController.exitApp = original);

      controller.applyEventForTest(
        const HaloEventMessage(name: HaloEvent.stateChanged, data: {}),
      );
      expect(exits, 0);
      expect(controller.hostExiting, isFalse);
      expect(controller.nextStep!.kind, NextStepKind.waiting);
    });

    test('a cancelled batch cannot paint its tail onto the next one', () async {
      // Cancelling closes the host's stop channel, nothing more: the probes
      // already in flight still finish and still report under the old taskId.
      // Without filtering, a user who presses 测试所选 again mid-run sees the
      // previous batch's numbers land on rows the new batch is still measuring
      // — the row stops spinning and shows a stale latency as if it were fresh.
      await controller.start(connectHost: false);
      final seen = <String>[];
      final sub = controller.speedUpdates.listen((r) => seen.add(r.nodeId));
      addTearDown(sub.cancel);

      controller.applyEventForTest(
        const HaloEventMessage(
          name: HaloEvent.taskStarted,
          data: {'taskId': 'batch-old', 'count': 2},
        ),
      );
      controller.applyEventForTest(
        const HaloEventMessage(
          name: HaloEvent.taskFinished,
          data: {'taskId': 'batch-old', 'canceled': true},
        ),
      );
      // The replacement batch, admitted by the host.
      controller.applyEventForTest(
        const HaloEventMessage(
          name: HaloEvent.taskStarted,
          data: {'taskId': 'batch-new', 'count': 1},
        ),
      );
      // A straggler from the cancelled batch arrives late.
      controller.applyEventForTest(
        const HaloEventMessage(
          name: HaloEvent.taskProgress,
          data: {
            'taskId': 'batch-old',
            'result': {'nodeId': 'stale', 'status': 'ok', 'valueMs': 42},
          },
        ),
      );
      controller.applyEventForTest(
        const HaloEventMessage(
          name: HaloEvent.taskProgress,
          data: {
            'taskId': 'batch-new',
            'result': {'nodeId': 'fresh', 'status': 'ok', 'valueMs': 77},
          },
        ),
      );

      // StreamController.broadcast delivers asynchronously, so the pending
      // event has to be drained before the listener's log can be read.
      await pumpEventQueue();

      expect(seen, ['fresh'], reason: '旧任务的残留结果必须被丢弃');
      expect(controller.speedResults.containsKey('stale'), isFalse,
          reason: '旧任务的结果不能进入当前结果表');
      expect(controller.speedResults['fresh']?.valueMs, 77);
    });

    test('nodes are imported by parsing a plain share link', () async {
      await controller.start(connectHost: false);
      seedNodes();
      expect(controller.loadNodes(), hasLength(1));
    });

    test('a core being restored does not flash a blocking step', () async {
      await controller.start(connectHost: false);
      seedNodes();
      controller.applySnapshotForTest(
        const RuntimeSnapshot(
          stateVersion: 1,
          coreState: CoreState.stopped,
          activeNodeId: 'node-1',
          activeNodeName: 'node-1',
          // The host restores this on launch; the window between the pipe
          // connecting and sing-box listening used to be reported as
          // "代理内核未运行" with a blocking button that resolved itself.
          coreWanted: true,
        ),
        connected: true,
      );
      expect(controller.nextStep, isNull);
    });

    test('a core that is really stopped still asks to be started', () async {
      await controller.start(connectHost: false);
      seedNodes();
      controller.applySnapshotForTest(
        const RuntimeSnapshot(
          stateVersion: 1,
          coreState: CoreState.stopped,
          activeNodeId: 'node-1',
          activeNodeName: 'node-1',
          coreWanted: false,
        ),
        connected: true,
      );
      final step = controller.nextStep;
      expect(step, isNotNull);
      expect(step!.action, NextStepAction.startCore);
    });
  });

  group('catalog cache', () {
    test('a read is cached until the catalog is invalidated', () async {
      await controller.start(connectHost: false);
      seedNodes();
      final first = controller.loadNodes();
      // Identity, not just equality: pages call this from build, and a fresh
      // list per call is what made a 10k-row page re-sort and re-layout on every
      // snapshot tick.
      expect(identical(controller.loadNodes(), first), isTrue);

      controller.notifyExternalChange();
      expect(identical(controller.loadNodes(), first), isFalse);
      expect(controller.loadNodes(), hasLength(1));
    });

    test('saveImport invalidates the cache itself', () async {
      await controller.start(connectHost: false);
      seedNodes();
      final before = controller.loadNodes();
      seedNodes(count: 2);
      final after = controller.loadNodes();
      expect(identical(before, after), isFalse);
      expect(after.length, greaterThanOrEqualTo(2));
    });
  });

  group('notification channels', () {
    test('narrow channels move independently', () {
      final runtime = controller.runtimeRevision.value;
      final catalog = controller.catalogRevision.value;
      final connection = controller.connectionRevision.value;
      final error = controller.errorRevision.value;

      controller.runtimeChanged();
      expect(controller.runtimeRevision.value, runtime + 1);
      expect(controller.catalogRevision.value, catalog);
      expect(controller.connectionRevision.value, connection);

      controller.catalogChanged();
      expect(controller.catalogRevision.value, catalog + 1);
      expect(controller.errorRevision.value, error);
      expect(controller.runtimeRevision.value, runtime + 1);

      controller.errorChanged();
      expect(controller.errorRevision.value, error + 1);
      expect(controller.connectionRevision.value, connection);
    });
  });

  group('HaloPage order', () {
    test('the daily workflow comes before the diagnostics', () {
      // The order is the flow: import, pick, then everything else. This is what
      // both reference clients do by position, and the flat alphabetical-ish
      // list this replaced was part of why the flow read as unclear.
      expect(HaloPage.values.take(3), [
        HaloPage.overview,
        HaloPage.subscriptions,
        HaloPage.nodes,
      ]);
      // Testing lives on the node list, not on a page of its own: v2rayN keeps
      // latency in a column of its server list, and a separate "连接与测速"
      // destination made the user leave the list they were choosing from.
      expect(
        HaloPage.values.map((p) => p.label),
        isNot(contains('连接与测速')),
      );
      expect(
        HaloPage.values.map((p) => p.label),
        containsAll(['总览', '订阅', '节点', '规则', '日志', '设置']),
      );
      // 分流与 DNS was replaced by 规则: it held ports, a second copy of the
      // mode selector and a config preview, but no rules — the one thing its
      // name promised. The bare name is deliberate: the page is about rules,
      // and a qualifier only invites the question of what else it covers.
      expect(
        HaloPage.values.map((p) => p.label),
        isNot(contains('分流与 DNS')),
      );
      expect(
        HaloPage.values.map((p) => p.label),
        isNot(contains('分流规则')),
      );
    });

    test('every step target maps onto a real page', () {
      for (final step in HaloStepPage.values) {
        expect(HaloPage.forStep(step), isNotNull);
      }
      expect(HaloPage.forStep(HaloStepPage.subscriptions), HaloPage.subscriptions);
      expect(HaloPage.forStep(HaloStepPage.overview), HaloPage.overview);
    });
  });

  group('HaloStatusBar', () {
    Widget harness({
      RuntimeSnapshot? snapshot,
      bool connected = true,
      NextStep? nextStep,
      String? activeNodeName,
      double width = 1000,
      double height = 400,
    }) {
      return MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: Column(
                children: [
                  const Spacer(),
                  HaloStatusBar(
                    snapshot: snapshot,
                    connected: connected,
                    nextStep: nextStep,
                    activeNodeName: activeNodeName,
                    onOpenStep: () {},
                    onRetryConnect: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    const step = NextStep(
      page: HaloStepPage.subscriptions,
      title: '先导入节点',
      detail: '粘贴订阅链接或分享链接。',
      actionLabel: '去导入',
      kind: NextStepKind.blocking,
    );

    testWidgets('shows 内核 and 节点 at every width without overflowing', (
      tester,
    ) async {
      // 590 logical pixels is what a 200%-scaled display gives this window, and
      // it is where the first version of this strip painted a RenderFlex
      // overflow (yellow hazard tape across the window bottom).
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      for (final width in [560.0, 590.0, 700.0, 1000.0, 1400.0]) {
        await tester.pumpWidget(harness(width: width));
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'status bar overflowed at width $width',
        );
        expect(find.textContaining('内核'), findsWidgets);
        expect(find.textContaining('未选择'), findsOneWidget);
      }
    });

    testWidgets('narrow widths drop the widest segments', (tester) async {
      // The default test viewport is 800x600, which would clamp the 1200px case
      // and hide the difference this test is about.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(width: 560));
      await tester.pump();
      // 模式 is the first thing to go, and TUN with it. The label is 模式 rather
      // than 分流 because the page it reports on is called 规则.
      expect(find.textContaining('模式'), findsNothing);
      expect(find.textContaining('TUN'), findsNothing);

      await tester.pumpWidget(harness(width: 760));
      await tester.pump();
      expect(find.textContaining('TUN'), findsWidgets);
      expect(find.textContaining('模式'), findsNothing);

      await tester.pumpWidget(harness(width: 1200));
      await tester.pump();
      expect(find.textContaining('模式'), findsWidgets);
    });

    testWidgets('an outstanding step offers its action', (tester) async {
      await tester.pumpWidget(harness(nextStep: step));
      await tester.pump();
      expect(find.text('先导入节点'), findsOneWidget);
      expect(find.text('去导入'), findsOneWidget);
    });

    testWidgets('nothing outstanding reads as ready once traffic is carried', (
      tester,
    ) async {
      // 已就绪 is a claim about traffic, so it needs a snapshot that shows the
      // system proxy on. A bare "no step" is no longer enough: with the
      // 流量还没有接管 step removed, that state also covers "core up, nothing
      // intercepted", where a green tick would be a lie.
      await tester.pumpWidget(
        harness(
          snapshot: const RuntimeSnapshot(
            stateVersion: 1,
            coreState: CoreState.running,
            systemProxy: SystemProxyState(enabled: true),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('已就绪'), findsOneWidget);
      expect(find.text('去导入'), findsNothing);
    });

    testWidgets('nothing outstanding but nothing intercepted stays quiet', (
      tester,
    ) async {
      // The review asked for the 流量还没有接管 banner to go, and it has. What it
      // must not do is take the truth with it: the bar refuses to claim 已就绪
      // while the system proxy and TUN are both off. 系统代理 and TUN say 已关闭
      // a few pixels to the left, which is the fact stated once.
      await tester.pumpWidget(
        harness(
          snapshot: const RuntimeSnapshot(
            stateVersion: 1,
            coreState: CoreState.running,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('已就绪'), findsNothing);
      expect(find.text('流量还没有接管'), findsNothing);
      expect(find.text('去开启'), findsNothing);
    });

    testWidgets('the waiting state retries instead of navigating', (
      tester,
    ) async {
      const waiting = NextStep(
        page: HaloStepPage.overview,
        title: '正在连接后台服务',
        detail: '请确认 halo-host.exe 存在。',
        actionLabel: '重试连接',
        kind: NextStepKind.waiting,
      );
      await tester.pumpWidget(
        harness(connected: false, nextStep: waiting),
      );
      await tester.pump();
      expect(find.text('重试连接'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('a stopped host shows no spinner and no retry offer', (
      tester,
    ) async {
      // The defect: after the tray quit, the strip kept spinning on
      // "正在连接后台服务" forever, which reads as a hung app rather than as
      // "the background service exited". A spinner belongs to `waiting` only.
      const stopped = NextStep(
        page: HaloStepPage.overview,
        title: '后台服务已退出',
        detail: '重新从开始菜单启动 Clash Halo 即可继续使用。',
        actionLabel: '知道了',
        kind: NextStepKind.stopped,
      );
      await tester.pumpWidget(
        harness(connected: false, nextStep: stopped),
      );
      await tester.pump();
      expect(find.text('后台服务已退出'), findsOneWidget);
      expect(find.text('重试连接'), findsNothing);
      expect(find.text('知道了'), findsNothing, reason: '不存在可执行动作');
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('page delivery of state changes', () {
    testWidgets('a snapshot arriving repaints the current page', (tester) async {
      // The regression this pins: narrowing the notification channels also
      // stopped *delivering* them, so the overview kept showing
      // "尚未获取到运行状态" while the status bar already showed live state. The
      // page host now subscribes on the page's behalf.
      //
      // Deliberately does not call `start()`: that opens the store, arms a
      // periodic subscription timer and (because the host is unreachable) puts a
      // spinner in the status bar, all of which fight the fake clock. None of it
      // is needed to prove that a tick reaches the page.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: HaloApp(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('尚未获取到运行状态'), findsOneWidget);

      // Publish a snapshot the way the host does, then tick the channel.
      controller.applySnapshotForTest(
        const RuntimeSnapshot(
          stateVersion: 3,
          coreState: CoreState.stopped,
          hostVersion: '0.1.0',
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('尚未获取到运行状态'), findsNothing);
      // The page's own card header. "代理内核" also labels the sidebar's liveness
      // dot, so the count is two, not one — what matters is that the card is
      // there at all.
      expect(find.text('代理内核'), findsWidgets);
    });
  });

  group('latency colour', () {
    test('is a single semantic: reachable, slow, unreachable', () {
      // Copied from the reference client's converter and applied identically
      // everywhere a latency appears, so a colour never means two things.
      expect(latencyColor(30), HaloColors.success);
      expect(latencyColor(200), HaloColors.success);
      expect(latencyColor(201), HaloColors.warning);
      expect(latencyColor(600), HaloColors.warning);
      expect(latencyColor(601), HaloColors.danger);
    });
  });

  group('HaloSidebar', () {
    testWidgets('marks the page the outstanding step points at', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: HaloMetrics.sidebarWidth,
              height: 700,
              child: HaloSidebar(
                current: HaloPage.overview,
                onSelect: (_) {},
                connected: true,
                coreRunning: false,
                blockedPage: HaloPage.subscriptions,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final page in HaloPage.values) {
        expect(find.text(page.label), findsWidgets);
      }
    });

    testWidgets('renders all pages inside a short window', (tester) async {
      // 380 logical pixels at 200% scaling: the sidebar must scroll rather than
      // clip the last items.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: HaloMetrics.sidebarWidth,
              height: 380,
              child: HaloSidebar(
                current: HaloPage.overview,
                onSelect: (_) {},
                connected: false,
                coreRunning: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
