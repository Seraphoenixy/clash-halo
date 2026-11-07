import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/exit_info.dart';
import 'package:halo/src/state/home_cards.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/overview_page.dart';
import 'package:halo/src/ui/widgets.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

class _OverviewController extends AppController {
  _OverviewController({required super.dataDir});

  ConnectionsSnapshot? connections;

  @override
  Future<ConnectionsSnapshot> fetchConnections() async =>
      connections ?? await super.fetchConnections();
}

/// The dashboard is now a card grid whose contents the user chooses, so the
/// things worth pinning are: every card is reachable, the choice survives, and
/// the layout holds at the narrow window.
void main() {
  late Directory dir;
  late _OverviewController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-overview');
    controller = _OverviewController(dataDir: dir.path);
    await controller.start(connectHost: false);
    // A stopped core: no timers, no exit lookup, nothing that needs a network.
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 3,
        coreState: CoreState.stopped,
        hostVersion: '0.1.0',
      ),
      connected: true,
    );
  });

  tearDown(() async {
    await controller.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1500, 1000),
    ExitInfoService? exitService,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: OverviewPage(
            controller: controller,
            exitService: exitService,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('every default card is on the page', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    for (final title in [
      '当前节点',
      '实时流量',
      '出口信息',
      '代理内核',
      '系统代理',
      '运行信息',
    ]) {
      expect(find.text(title), findsWidgets, reason: title);
    }
    // A stopped core says so on the traffic and exit cards instead of showing
    // zeros or an error.
    expect(find.textContaining('内核未运行，暂无实时流量'), findsOneWidget);
    expect(find.textContaining('尚未查询'), findsOneWidget);
  });

  testWidgets('a card can be switched off and the choice is stored', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('实时流量'), findsOneWidget);

    await tester.tap(find.byTooltip('选择要显示的卡片'));
    await tester.pump(const Duration(milliseconds: 200));
    // HomeCard order is node, traffic, exit, ... so traffic is the second switch.
    // Scoped to the dialog: the page's own cards carry switches too (系统代理,
    // TUN), so an unscoped index would flip one of those instead.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(HaloSwitch),
      ).at(1),
    );
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('实时流量'), findsNothing);
    expect(find.text('出口信息'), findsOneWidget);
    // Stored as the hidden set, so a later card is visible by default.
    expect(controller.settingsRepo.getJson(HomeCards.storageKey), ['traffic']);
  });

  testWidgets('the stored choice is honoured on the next build', (tester) async {
    HomeCards.defaults.toggle(HomeCard.exit).save(controller.settingsRepo);
    await pump(tester);
    expect(find.text('出口信息'), findsNothing);
    // 当前节点 also labels a row inside 运行信息, so "one widget" is wrong here.
    expect(find.text('当前节点'), findsWidgets);
  });

  testWidgets('the exit card re-queries when the active node changes', (
    tester,
  ) async {
    // A verdict about an exit belongs to that exit. Carrying it over to the
    // next node is the same mistake as a stale latency next to a fresh row.
    // The answer is keyed off the node, not off a request counter: the TLS
    // services are raced, so several requests run at once and a counter would
    // make the expectation depend on which one finished first.
    var answer = '10.0.0.1';
    final service = ExitInfoService(
      proxyResolver: () => '127.0.0.1:7890',
      transport: (url, proxy, timeout) async => {
        'ip': answer,
        'country_code': 'JP',
        'country': 'Japan',
      },
    );
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 4,
        coreState: CoreState.running,
        activeNodeId: 'node-a',
      ),
      connected: true,
    );
    await pump(tester, exitService: service);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('10.0.0.1'), findsOneWidget);

    answer = '10.0.0.2';
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 5,
        coreState: CoreState.running,
        activeNodeId: 'node-b',
      ),
      connected: true,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('10.0.0.2'), findsOneWidget);
    expect(find.text('10.0.0.1'), findsNothing);
  });

  testWidgets('two columns do not overflow at the breakpoint', (tester) async {
    // 860px is where the grid switches to two columns, so each card gets ~425px —
    // the narrowest it will ever be while still being a half card. The system
    // proxy card's mode selector is the widest thing on the page.
    await pump(tester, size: const Size(880, 900));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the grid collapses to one column in a narrow window', (
    tester,
  ) async {
    // 1180x760 at 200% scaling is the case the rest of the app pins.
    await pump(tester, size: const Size(1180, 760));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('当前节点'), findsWidgets);
    expect(find.text('出口信息'), findsOneWidget);
  });

  /// A started core with a selected node makes the exit card query, which owns
  /// a timer. Supplying a transport that answers instantly keeps the test free
  /// of pending timers while still exercising the real page.
  ExitInfoService stubExit() => ExitInfoService(
    proxyResolver: () => '127.0.0.1:7890',
    transport: (url, proxy, timeout) async => {
      'ip': '10.0.0.9',
      'country_code': 'JP',
      'country': 'Japan',
    },
  );

  testWidgets('traffic card shows sampled totals and only proxy connections', (
    tester,
  ) async {
    controller.connections = const ConnectionsSnapshot(
      uploadTotal: 7000,
      downloadTotal: 9000,
      connections: [
        LiveConnection(id: 'a', host: 'proxy.example', chains: ['proxy']),
        LiveConnection(id: 'b', host: 'direct.example', chains: ['direct']),
      ],
    );
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 4, coreState: CoreState.running),
      connected: true,
    );
    await pump(tester, exitService: stubExit());

    expect(find.text('代理连接 1'), findsOneWidget);
    expect(find.text('采样累计 ↑0 B ↓0 B'), findsOneWidget);
  });

  testWidgets('no banner when the core runs but nothing is intercepted', (
    tester,
  ) async {
    // The 流量还没有接管 prompt was removed on request: the system proxy and TUN
    // already have their own switches on this page and their own status items in
    // the bar, so a third, louder copy of the same fact was a nag.
    controller.saveImport(importNodes('trojan://pw@a.example.com:443#节点甲'));
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 40,
        coreState: CoreState.running,
        activeNodeId: 'node-a',
        systemProxy: SystemProxyState.off,
        tunState: TunState.disabled,
      ),
      connected: true,
    );
    await pump(tester, exitService: stubExit());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('流量还没有接管'), findsNothing);
    expect(find.text('去开启'), findsNothing);
    // Removing the prompt must not leave a false all-clear behind it.
    expect(find.textContaining('代理已就绪'), findsNothing);
  });

  testWidgets('the ready banner appears only when traffic is intercepted', (
    tester,
  ) async {
    controller.saveImport(importNodes('trojan://pw@a.example.com:443#节点甲'));
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 41,
        coreState: CoreState.running,
        activeNodeId: 'node-a',
        systemProxy: SystemProxyState(enabled: true),
      ),
      connected: true,
    );
    await pump(tester, exitService: stubExit());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('代理已就绪'), findsOneWidget);
  });

  // The two switches are one choice: the host stops one when the other turns
  // on, so the page must not show both as independently enabled.
  testWidgets('the system-proxy switch stays usable and names the trade', (
    tester,
  ) async {
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 41,
        coreState: CoreState.running,
        tunState: TunState.enabled,
        tunPid: 4242,
        tunSupported: true,
        systemProxy: SystemProxyState(
          supported: true,
          enabled: false,
          endpoint: '127.0.0.1:7890',
        ),
      ),
      connected: true,
    );
    await pump(tester, exitService: stubExit());
    await tester.pump(const Duration(milliseconds: 100));

    // Ticking this switch is how the user leaves TUN, so it must stay live.
    final tile = tester.widget<HaloSwitchTile>(
      find.widgetWithText(HaloSwitchTile, '设置 Windows 系统代理'),
    );
    expect(tile.onChanged, isNotNull);
    // The click stops the tunnel; that consequence is stated up front.
    expect(find.text('开启将关闭 TUN，切回普通代理'), findsOneWidget);
    // The card reports this setting's own state, not the tunnel's.
    expect(find.text('已关闭'), findsOneWidget);
    expect(find.text('TUN 接管中'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the TUN switch warns before it turns the system proxy off', (
    tester,
  ) async {
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 42,
        coreState: CoreState.running,
        tunState: TunState.disabled,
        tunSupported: true,
        systemProxy: SystemProxyState(
          supported: true,
          enabled: true,
          endpoint: '127.0.0.1:7890',
        ),
      ),
      connected: true,
    );
    await pump(tester, exitService: stubExit());
    await tester.pump(const Duration(milliseconds: 100));

    // Reaching across the page from a switch in another card needs to be said
    // before the click, not discovered afterwards.
    expect(find.text('启用后将关闭系统代理，由 TUN 接管全部流量'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the core card names the tunnel process instead of a dash', (
    tester,
  ) async {
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 43,
        coreState: CoreState.running,
        tunState: TunState.enabled,
        tunPid: 4242,
        tunSupported: true,
      ),
      connected: true,
    );
    await pump(tester, exitService: stubExit());
    await tester.pump(const Duration(milliseconds: 100));

    // corePid is deliberately 0 under TUN (the core is the service's child);
    // showing "—" beside a 运行中 chip read as "no process".
    expect(find.text('4242（TUN）'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
