import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo/src/state/unlock.dart';
import 'package:halo/src/state/unlock_checks.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/unlock_page.dart';
import 'package:halo/src/ui/shell.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_config/halo_config.dart';

import 'dart:io';

/// A client that never connects: these tests are about what the page draws, and
/// a real sweep would fire thirteen requests at the live services.
class _QuietClient extends HaloClient {
  _QuietClient() : super(pipeName: 'never-connected');

  @override
  bool get isConnected => true;

  @override
  Future<HaloResponse> send(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async => HaloResponse.success('fake', result: const {});

  @override
  Future<HaloResponse> sendRead(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) => send(action, params: params, timeout: timeout);
}

void main() {
  Widget harness(AppController controller) => MaterialApp(
    theme: buildHaloTheme(Brightness.light),
    home: Scaffold(
      body: SizedBox(
        width: 1100,
        height: 700,
        child: UnlockPage(controller: controller, onOpenNodes: () {}),
      ),
    ),
  );

  late Directory tempDir;
  late AppController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('halo_unlock_page');
    controller = AppController(client: _QuietClient(), dataDir: tempDir.path);
    await controller.start(connectHost: false);
  });

  tearDown(() async {
    await controller.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('a stopped core is explained instead of failing thirteen ways', (
    tester,
  ) async {
    // The default test viewport is 800x600, which fits three cards per row and
    // pushes the last row out of the grid's cache extent: the page would look
    // as if it were missing services that are simply not built yet.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // Without the notice the user presses 全部检测, gets thirteen "检测失败"
    // cards and concludes the node is broken, when the real problem is that
    // nothing is listening to send the requests through.
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
      connected: true,
    );
    await tester.pumpWidget(harness(controller));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('内核未运行'), findsOneWidget);
    for (final item in pendingUnlockItems()) {
      // Every service is listed even before anything has been measured; a page
      // that only appears after a run gives the user nothing to press.
      expect(find.text(item.name), findsOneWidget, reason: item.name);
    }
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '全部检测'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('stored verdicts paint with their region and time', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.running),
      connected: true,
    );
    controller.unlock.restore(UnlockSnapshot(items: [
      const UnlockItem(
        id: 'netflix',
        name: 'Netflix',
        status: UnlockStatus.yes,
        region: 'US',
        checkedAtMs: 1700000000000,
      ),
      const UnlockItem(
        id: 'disney_plus',
        name: 'Disney+',
        status: UnlockStatus.no,
        checkedAtMs: 1700000000000,
      ),
    ]));
    await tester.pumpWidget(harness(controller));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('解锁'), findsOneWidget);
    expect(find.text('不支持'), findsOneWidget);
    // A raw country code is not a region name: the chip pairs the code with
    // its Chinese name.
    expect(find.text('US · 美国'), findsOneWidget);
    // A compound verdict is shown verbatim, and 未检测 never becomes a failure.
    expect(find.text('未检测'), findsNWidgets(pendingUnlockItems().length - 2));
    expect(find.text('已检测 2 / 13'), findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '全部检测'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('re-testing is offered only when the request can go somewhere', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
      connected: true,
    );
    await tester.pumpWidget(harness(controller));
    await tester.pump(const Duration(milliseconds: 50));

    // A refresh button that fires at a closed port produces thirteen failures
    // that describe the missing core rather than the node.
    IconButton refresh() => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh).first,
    );
    expect(refresh().onPressed, isNull);

    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.running),
      connected: true,
    );
    // The page is a StatelessWidget: in the app it is rebuilt by HaloApp's
    // runtimeRevision listener, so the test has to trigger the same rebuild.
    await tester.pumpWidget(harness(controller));
    await tester.pump(const Duration(milliseconds: 50));
    expect(refresh().onPressed, isNotNull);
  });

  testWidgets('direct mode is called out because the requests bypass the node', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // In direct mode the mixed inbound still answers, so all thirteen checks
    // would succeed — through the local line. Reporting that as the node's
    // unlocks is the one wrong answer that looks entirely plausible.
    await controller.saveRouting(const RoutingSettings(mode: RouteMode.direct));
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.running),
      connected: true,
    );
    await tester.pumpWidget(harness(controller));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('直连'), findsOneWidget);
  });

  test('the test page is a sidebar destination with a label', () {
    expect(HaloPage.test.label, '测试');
    expect(HaloPage.values.contains(HaloPage.test), isTrue);
  });

  group('region labels', () {
    // The canonical form stays alpha-2 (that is what the existing contract
    // pins), and the display form adds the readable name on top of it.
    test('alpha-2 codes keep their code', () {
      expect(unlockRegionLabel('US'), 'US');
      expect(unlockRegionLabel('JP'), 'JP');
    });

    test('alpha-3 folds to alpha-2 before naming, so KOR reads 韩国', () {
      // Gemini answers alpha-3 where every other check answers alpha-2; one
      // card in thirteen used to read `KOR`.
      expect(unlockRegionLabel('KOR'), 'KR');
      expect(unlockRegionDisplay('KOR'), 'KR · 韩国');
    });

    test('the display form adds the Chinese name', () {
      expect(unlockRegionDisplay('US'), 'US · 美国');
      expect(unlockRegionDisplay('HK'), 'HK · 香港');
    });

    test('Disney-plus internal codes are named rather than shown raw', () {
      expect(unlockRegionDisplay('ALISG'), contains('新加坡'));
    });

    test('an unknown code is passed through, never invented', () {
      expect(unlockRegionLabel('ZZ'), 'ZZ');
      // No name means no name: `ZZ · 未知` would be worse than `ZZ`.
      expect(unlockRegionDisplay('ZZ'), 'ZZ');
      expect(unlockRegionLabel(''), '');
      expect(unlockRegionDisplay(''), '');
    });

    test('case and padding do not change the answer', () {
      expect(unlockRegionLabel(' us '), 'US');
      expect(unlockRegionLabel('kor'), 'KR');
    });
  });

  testWidgets('the footer summarises verdicts instead of leaving them to be '
      'counted', (tester) async {
    // Thirteen colour-coded cards with no tally forced the reader to count. The
    // strip now leads with how many worked, how many were limited and how many
    // failed.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.running),
      connected: true,
    );
    controller.unlock.restore(UnlockSnapshot(items: [
      const UnlockItem(
        id: 'netflix',
        name: 'Netflix',
        status: UnlockStatus.yes,
        checkedAtMs: 1700000000000,
      ),
      const UnlockItem(
        id: 'disney_plus',
        name: 'Disney+',
        status: UnlockStatus.no,
        checkedAtMs: 1700000000000,
      ),
    ]));
    await tester.pumpWidget(harness(controller));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('可用 1'), findsOneWidget);
    expect(find.text('不可用 1'), findsOneWidget);
    // A tone with no verdicts is omitted rather than shown as 0.
    expect(find.text('受限 0'), findsNothing);
  });

  test('toneCounts ignores pending cards', () {
    final counters = controller.unlock;
    counters.restore(UnlockSnapshot(items: [
      const UnlockItem(id: 'netflix', name: 'Netflix', status: UnlockStatus.yes),
      const UnlockItem(
        id: 'disney_plus',
        name: 'Disney+',
        status: UnlockStatus.no,
      ),
    ]));
    final counts = counters.toneCounts;
    // Eleven services are still pending; they must not be counted as failures.
    expect(counts[UnlockTone.pending], isNull);
    expect(counts[UnlockTone.ok], 1);
    expect(counts[UnlockTone.bad], 1);
  });
}
