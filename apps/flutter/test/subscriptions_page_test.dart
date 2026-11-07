import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/subscription_tests.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/subscriptions_page.dart';
import 'package:halo/src/ui/widgets.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// Tests for the subscription page's roll-ups, interval presets and batch mode.
///
/// The properties pinned here are the ones that are easy to get subtly wrong
/// and expensive to notice by hand: an average that quietly includes nodes that
/// never answered, a "manual" choice that leaves auto-update armed, and batch
/// buttons that stay live with nothing selected.
void main() {
  ProxyNode node(String id, {String profile = 'p'}) => ProxyNode(
    id: id,
    fingerprint: 'fp-$id',
    name: id,
    protocol: ProxyProtocol.trojan,
    server: 'example.com',
    port: 443,
    secrets: const NodeSecrets(password: 'secret'),
    profileId: profile,
  );

  SpeedResult latency(
    String id,
    SpeedStatus status, {
    int? ms,
    SpeedMetric metric = SpeedMetric.proxyLatency,
  }) => SpeedResult(
    nodeId: id,
    metric: metric,
    status: status,
    valueMs: ms,
  );

  group('subscription latency roll-up', () {
    test('counts only answered nodes, and only answered values', () {
      final nodes = [node('n1'), node('n2'), node('n3'), node('n4'), node('n5')];
      final results = <String, SpeedResult>{
        'n1': latency('n1', SpeedStatus.ok, ms: 120),
        'n2': latency('n2', SpeedStatus.ok, ms: 300),
        'n3': latency('n3', SpeedStatus.failed),
        // Not terminal: the host has not produced a verdict, so it is neither
        // "available" nor "failed".
        'n4': latency('n4', SpeedStatus.running, ms: 999),
        // n5 never reported at all.
      };
      final summary = summarizeSubscriptionLatency(nodes, results);
      expect(summary.total, 5);
      expect(summary.ok, 2);
      expect(summary.failed, 1);
      expect(summary.tested, 3);
      expect(summary.untested, 2);
      // The running node's 999 ms must not drag the average: only ok values
      // count, so the average is (120+300)/2.
      expect(summary.fastestMs, 120);
      expect(summary.averageMs, 210);
      expect(summary.label, '可用 2/5 · 最快 120 ms · 平均 210 ms · 失败 1');
    });

    test('a non-latency reading for the same node is not a delay', () {
      final nodes = [node('n1')];
      final results = <String, SpeedResult>{
        'n1': latency('n1', SpeedStatus.ok, ms: 40, metric: SpeedMetric.tcp),
        'n1-dl': SpeedResult(
          nodeId: 'n1-dl',
          metric: SpeedMetric.download,
          status: SpeedStatus.ok,
          bytesPerSecond: 1024,
        ),
      };
      final summary = summarizeSubscriptionLatency(nodes, results);
      expect(summary.isUntested, isTrue);
      expect(summary.label, '未测试');
    });

    test('an all-failed subscription says so without inventing an average', () {
      final nodes = [node('n1'), node('n2')];
      final results = <String, SpeedResult>{
        'n1': latency('n1', SpeedStatus.failed),
        'n2': latency('n2', SpeedStatus.failed),
      };
      final summary = summarizeSubscriptionLatency(nodes, results);
      expect(summary.averageMs, isNull);
      expect(summary.label, '不可用 2/2');
    });
  });

  group('update interval presets', () {
    test('manual turns auto-update off and keeps the stored minutes', () {
      final manual = resolveIntervalChoice(
        option: kUpdateIntervalPresets.first,
        customMinutes: 0,
        storedMinutes: 720,
      );
      expect(manual.autoUpdate, isFalse);
      // Switching back must not lose what the user last chose.
      expect(manual.minutes, 720);
    });

    test('each preset stores its own minutes and arms auto-update', () {
      const expected = {30: 30, 60: 60, 360: 360, 720: 720, 1440: 1440};
      for (final entry in expected.entries) {
        final option = kUpdateIntervalPresets.firstWhere(
          (o) => o.minutes == entry.key,
        );
        final resolved = resolveIntervalChoice(
          option: option,
          customMinutes: 0,
          storedMinutes: 1,
        );
        expect(resolved.autoUpdate, isTrue, reason: option.label);
        expect(resolved.minutes, entry.value, reason: option.label);
      }
    });

    test('custom clamps to a positive interval', () {
      final custom = kUpdateIntervalPresets.last;
      expect(
        resolveIntervalChoice(
          option: custom,
          customMinutes: 45,
          storedMinutes: 1,
        ).minutes,
        45,
      );
      // 0 or a blank field must not store an interval that never elapses.
      expect(
        resolveIntervalChoice(
          option: custom,
          customMinutes: 0,
          storedMinutes: 1,
        ).minutes,
        1,
      );
    });

    test('the picker opens on what the profile stores', () {
      expect(
        intervalOptionFor(
          const SubscriptionProfile(
            id: 'a',
            name: 'a',
            url: 'https://x/a',
            autoUpdate: false,
            updateIntervalMinutes: 1440,
          ),
        ).isManual,
        isTrue,
        reason: 'autoUpdate false is manual whatever the minutes say',
      );
      expect(
        intervalOptionFor(
          const SubscriptionProfile(
            id: 'a',
            name: 'a',
            url: 'https://x/a',
            autoUpdate: true,
            updateIntervalMinutes: 1440,
          ),
        ).minutes,
        1440,
      );
      // A value no preset names has to land on 自定义, or the dialog would
      // silently rewrite it to whichever preset happened to be nearest.
      expect(
        intervalOptionFor(
          const SubscriptionProfile(
            id: 'a',
            name: 'a',
            url: 'https://x/a',
            autoUpdate: true,
            updateIntervalMinutes: 45,
          ),
        ).custom,
        isTrue,
      );
    });

    test('the row chip names the interval instead of its smallest unit', () {
      expect(intervalChipLabel(30), '每 30 分钟更新');
      expect(intervalChipLabel(60), '每 1 小时更新');
      expect(intervalChipLabel(360), '每 6 小时更新');
      expect(intervalChipLabel(1440), '每天更新');
      expect(intervalChipLabel(2880), '每 2 天更新');
    });
  });

  group('remote detection', () {
    test('only an http(s) address with a host can be refreshed', () {
      SubscriptionProfile at(String url) =>
          SubscriptionProfile(id: 'a', name: 'a', url: url);
      expect(isRemoteProfile(at('https://example.com/sub')), isTrue);
      expect(isRemoteProfile(at('http://example.com:8080/sub')), isTrue);
      // The pasted-node case: a "url" that is a slice of share links can never
      // be fetched, so batch update must skip it rather than fail it forever.
      expect(isRemoteProfile(at('ss://YWVz@example.com:443#node')), isFalse);
      expect(isRemoteProfile(at('trojan://pw@example.com:443')), isFalse);
      expect(isRemoteProfile(at('')), isFalse);
      expect(isRemoteProfile(at('https://')), isFalse);
    });
  });

  group('batch mode', () {
    // The controller is built in setUp/tearDown rather than inside the test
    // body: `start()` arms a one-minute periodic timer, and a timer created
    // inside the body lives in the fake-async zone, where the binding fails the
    // test for leaving it pending after the widget tree is disposed.
    late Directory dir;
    late AppController controller;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('halo_subs_page');
      controller = AppController(dataDir: dir.path);
      await controller.start(connectHost: false);
      for (final id in ['a', 'b']) {
        controller.subscriptionRepo.upsert(
          SubscriptionProfile(
            id: id,
            name: '订阅 $id',
            url: 'https://example.com/$id',
            createdAtMs: 1,
          ),
        );
      }
    });

    tearDown(() async {
      await controller.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // A lingering WAL file on Windows can keep the directory busy.
      }
    });

    /// Mounts the page on a window wide enough that nothing here is really
    /// about layout.
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(2400, 1400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    bool enabled<T extends ButtonStyleButton>(WidgetTester tester, String key) =>
        tester.widget<T>(find.byKey(ValueKey(key))).onPressed != null;

    testWidgets('the toolbar appears with the mode and follows the selection', (
      tester,
    ) async {
      await pump(tester);

      // Out of batch mode there is no checkbox gutter and no batch toolbar: the
      // row is about the subscription, not about a selection nobody started.
      expect(find.byKey(const ValueKey('sub-check-a')), findsNothing);
      expect(find.byKey(const ValueKey('sub-select-all')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sub-batch-toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sub-check-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('sub-check-b')), findsOneWidget);
      expect(find.textContaining('已选 0 / 2'), findsOneWidget);
      // Nothing is selected: 全选 is the only thing that can do anything.
      expect(enabled<TextButton>(tester, 'sub-select-all'), isTrue);
      expect(enabled<TextButton>(tester, 'sub-clear'), isFalse);
      expect(enabled<OutlinedButton>(tester, 'sub-batch-update'), isFalse);
      expect(enabled<OutlinedButton>(tester, 'sub-batch-delete'), isFalse);

      await tester.tap(find.byKey(const ValueKey('sub-select-all')));
      await tester.pump();
      expect(find.textContaining('已选 2 / 2'), findsOneWidget);
      expect(enabled<TextButton>(tester, 'sub-select-all'), isFalse);
      expect(enabled<TextButton>(tester, 'sub-clear'), isTrue);
      expect(enabled<OutlinedButton>(tester, 'sub-batch-update'), isTrue);
      expect(enabled<OutlinedButton>(tester, 'sub-batch-delete'), isTrue);

      await tester.tap(find.byKey(const ValueKey('sub-clear')));
      await tester.pump();
      expect(find.textContaining('已选 0 / 2'), findsOneWidget);
      expect(enabled<TextButton>(tester, 'sub-clear'), isFalse);
      expect(enabled<OutlinedButton>(tester, 'sub-batch-delete'), isFalse);

      // Ticking one row is a partial selection, so 全选 is live again.
      await tester.tap(find.byKey(const ValueKey('sub-check-b')));
      await tester.pump();
      expect(find.textContaining('已选 1 / 2'), findsOneWidget);
      expect(enabled<TextButton>(tester, 'sub-select-all'), isTrue);
      expect(enabled<OutlinedButton>(tester, 'sub-batch-delete'), isTrue);
    });

    testWidgets('测试入口已从订阅页移除', (tester) async {
      // Latency testing is the node page's job. This page used to carry a
      // header 「测试全部」 and a per-row 「测试」; both were removed, and this
      // pins their absence so neither comes back by accident.
      controller.applySnapshotForTest(
        const RuntimeSnapshot(
          stateVersion: 1,
          coreState: CoreState.stopped,
        ),
        connected: true,
      );
      controller.nodeRepo.replaceProfileNodes(
        'a',
        importNodes('trojan://pw@b.example.com:443#乙').nodes,
        nowMs: 2,
      );
      controller.notifyExternalChange();
      await pump(tester);

      expect(find.byKey(const ValueKey('sub-test-all')), findsNothing);
      expect(find.byKey(const ValueKey('sub-test-a')), findsNothing);
      expect(find.byKey(const ValueKey('sub-test-b')), findsNothing);
      expect(find.byKey(const ValueKey('sub-stop-a')), findsNothing);
      expect(find.byKey(const ValueKey('sub-stop-b')), findsNothing);
      // No control on this page may offer to start a test either.
      expect(find.text('测试全部'), findsNothing);
      expect(find.text('测试'), findsNothing);
    });

    testWidgets('leaving the mode clears the selection', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('sub-batch-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sub-check-a')));
      await tester.pump();
      expect(find.textContaining('已选 1 / 2'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sub-batch-toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sub-check-a')), findsNothing);
      // Re-entering must not resurrect the old ticks: a batch action against a
      // selection the user cannot see again is how a wrong delete happens.
      await tester.tap(find.byKey(const ValueKey('sub-batch-toggle')));
      await tester.pump();
      expect(find.textContaining('已选 0 / 2'), findsOneWidget);
    });

    testWidgets('a row reports the latency of its own nodes', (tester) async {
      // Inserted before the first build, because `loadNodes` caches on the
      // first read and a row would otherwise render the list from before it.
      controller.nodeRepo.insert(
        ProxyNode(
          id: 'n1',
          fingerprint: 'fp-n1',
          name: 'n1',
          protocol: ProxyProtocol.trojan,
          server: 'example.com',
          port: 443,
          secrets: const NodeSecrets(password: 'x'),
          source: NodeSourceKind.subscription,
          profileId: 'a',
        ),
        nowMs: 1,
      );
      controller.nodeRepo.insert(
        ProxyNode(
          id: 'n2',
          fingerprint: 'fp-n2',
          name: 'n2',
          protocol: ProxyProtocol.trojan,
          server: 'example.com',
          port: 8443,
          secrets: const NodeSecrets(password: 'x'),
          source: NodeSourceKind.subscription,
          profileId: 'a',
        ),
        nowMs: 1,
      );
      controller.speedResults['n1'] = SpeedResult(
        nodeId: 'n1',
        metric: SpeedMetric.proxyLatency,
        status: SpeedStatus.ok,
        valueMs: 150,
      );
      controller.speedResults['n2'] = const SpeedResult(
        nodeId: 'n2',
        metric: SpeedMetric.proxyLatency,
        status: SpeedStatus.failed,
      );
      await pump(tester);

      // The row reads the shared result map, so a batch driven from the nodes
      // page shows up here too — and the count comes from the database, not
      // from the number recorded at the last update.
      expect(
        find.textContaining('https://example.com/a · 2 个节点'),
        findsOneWidget,
      );
      expect(
        find.text('可用 1/2 · 最快 150 ms · 平均 150 ms · 失败 1'),
        findsOneWidget,
      );
      expect(find.text('未测试'), findsNothing);
    });

    testWidgets('renders in a 1180px window at 200% scaling', (tester) async {
      // 590x380 logical. The header carries four actions normally and five in
      // batch mode, and the import form above the list is 260px tall: this is
      // the case where one control too many overflows the page.
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.subscriptionRepo.upsert(
        const SubscriptionProfile(
          id: 'c',
          name: '订阅 c',
          url: 'https://example.com/c',
          autoUpdate: true,
          updateIntervalMinutes: 1440,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('sub-batch-toggle')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('review fixes', () {
    // Same lifecycle rule as 批量 mode above: `start()` arms a periodic timer,
    // which must not be created inside a fake-async test body.
    late Directory dir;
    late AppController controller;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('halo_subs_review');
      controller = AppController(dataDir: dir.path);
      await controller.start(connectHost: false);
    });

    tearDown(() {
      controller.dispose();
      try {
        dir.deleteSync(recursive: true);
      } on Object {
        // A Windows file lock on the sqlite file is not a test failure.
      }
    });

    /// Builds the page with one subscription and returns nothing.
    Future<void> pumpWithProfile(
      WidgetTester tester,
      AppController controller, {
      String url = 'https://example.com/sub',
      bool autoUpdate = true,
    }) async {
      controller.subscriptionRepo.upsert(
        SubscriptionProfile(
          id: 'p1',
          name: '主订阅',
          url: url,
          autoUpdate: autoUpdate,
          updateIntervalMinutes: 1440,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('the auto-update switch carries a visible label', (
      tester,
    ) async {
      // A bare switch beside a 正常 badge read as "disable this subscription";
      // it only controls auto-update. The word 开/关 that used to sit after the
      // switch is gone — the switch's own position already states it, and the
      // row's trailing action cluster is the tightest part of the layout.
      await pumpWithProfile(tester, controller);
      expect(find.text('自动更新'), findsOneWidget);
      final switches = tester.widgetList<HaloSwitch>(find.byType(HaloSwitch));
      expect(
        switches.any((s) => s.semanticLabel == '自动更新'),
        isTrue,
        reason: '自动更新的开关必须能读屏识别，而不是只靠旁边的文字',
      );
    });

    testWidgets('a token in the subscription URL is not on screen', (
      tester,
    ) async {
      // The row used to print the endpoint verbatim, so an ordinary screenshot
      // carried a working subscription token.
      await pumpWithProfile(
        tester,
        controller,
        url: 'https://example.com/api/v1/client/abc/clash?token=s3cr3t',
      );
      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join('\n');
      expect(rendered.contains('s3cr3t'), isFalse);
      expect(rendered.contains('token='), isFalse);
      expect(rendered.contains('example.com'), isTrue);
    });

    testWidgets('the proxy button sits left of 全部更新 and explains itself when '
        'the core is down', (tester) async {
      await pumpWithProfile(tester, controller);

      final proxy = find.byKey(const ValueKey('sub-update-all-proxy'));
      final plain = find.byKey(const ValueKey('sub-update-all'));
      expect(proxy, findsOneWidget);
      expect(plain, findsOneWidget);
      // Ordered as asked: proxy first, then the direct update.
      expect(
        tester.getCenter(proxy).dx,
        lessThan(tester.getCenter(plain).dx),
      );
      // No host is connected in this test, so the button is disabled: turning it
      // on with nothing listening would only produce "connection refused" on
      // localhost, which reads as a broken client.
      expect(
        tester
            .widget<OutlinedButton>(proxy)
            .onPressed,
        isNull,
      );
    });

    testWidgets('group chips filter the list and 未分组 counts the rest', (
      tester,
    ) async {
      // Two subscriptions, one filed under a group.
      controller.subscriptionRepo.upsert(
        SubscriptionProfile(
          id: 'p1',
          name: '主订阅',
          url: 'https://example.com/sub',
        ),
      );
      final group = controller.saveGroup(name: '工作');
      expect(group, isNotNull);
      controller.setProfileGroup('p1', group!.id);
      controller.subscriptionRepo.upsert(
        SubscriptionProfile(
          id: 'p2',
          name: '备用订阅',
          url: 'https://example.com/sub2',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // Both rows visible under 全部.
      expect(find.text('主订阅'), findsOneWidget);
      expect(find.text('备用订阅'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('sub-group-chip-${group.id}')));
      await tester.pump();
      expect(find.text('主订阅'), findsOneWidget);
      expect(find.text('备用订阅'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sub-group-chip-__ungrouped__')));
      await tester.pump();
      expect(find.text('主订阅'), findsNothing);
      expect(find.text('备用订阅'), findsOneWidget);
    });

    testWidgets('deleting a group ungroups its subscriptions instead of '
        'deleting them', (tester) async {
      controller.subscriptionRepo.upsert(
        SubscriptionProfile(
          id: 'p1',
          name: '主订阅',
          url: 'https://example.com/sub',
        ),
      );
      final group = controller.saveGroup(name: '工作')!;
      controller.setProfileGroup('p1', group.id);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('sub-group-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('sub-group-delete-${group.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(controller.loadGroups(), isEmpty);
      expect(controller.loadProfiles().map((p) => p.id), contains('p1'));
      expect(
        controller.loadProfiles().firstWhere((p) => p.id == 'p1').groupId,
        isNull,
      );
    });

    testWidgets('a group can be renamed from the 集合 dialog and keeps its '
        'subscriptions', (tester) async {
      controller.subscriptionRepo.upsert(
        SubscriptionProfile(
          id: 'p1',
          name: '主订阅',
          url: 'https://example.com/sub',
        ),
      );
      final group = controller.saveGroup(name: '工作')!;
      controller.setProfileGroup('p1', group.id);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('sub-group-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('sub-group-rename-${group.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sub-group-rename-field')),
        '公司',
      );
      await tester.tap(find.byKey(const ValueKey('sub-group-rename-save')));
      await tester.pumpAndSettle();

      final renamed = controller.loadGroups().single;
      expect(renamed.name, '公司');
      // Same id means the membership survived; a delete-and-recreate would have
      // left p1 ungrouped.
      expect(renamed.id, group.id);
      expect(
        controller.loadProfiles().firstWhere((p) => p.id == 'p1').groupId,
        group.id,
      );
      // The dialog's own list must show the new name. `findsWidgets` would have
      // passed even with a stale dialog, because the page behind it repaints and
      // its row chips also read 公司 — the assertion has to name the ListTile
      // title inside the dialog.
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('公司'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('工作'),
        ),
        findsNothing,
      );
    });

    testWidgets('renaming onto a taken name shows the error and changes '
        'nothing', (tester) async {
      final first = controller.saveGroup(name: '工作')!;
      controller.saveGroup(name: '公司');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('sub-group-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('sub-group-rename-${first.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sub-group-rename-field')),
        '公司',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sub-group-rename-save')));
      await tester.pumpAndSettle();

      // The dialog stays open with the reason visible, and both groups survive.
      expect(find.text('已存在同名集合'), findsOneWidget);
      final names = controller.loadGroups().map((g) => g.name).toList();
      expect(names, containsAll(['工作', '公司']));
      expect(names, hasLength(2));
    });

    test('creating many groups never overwrites an earlier one', () {
      // The id used to be a millisecond stamp, so two creates in the same tick
      // shared an id and `upsert` *renamed the first group* instead of adding a
      // second — "I made 工作 and 公司, I only have 公司".
      //
      // Creating in a tight loop is the realistic way to land twice in one tick,
      // and the assertion is about the outcome (n creates => n rows), not about
      // which clock value the generator happened to pick.
      final created = <String>[];
      for (var i = 0; i < 200; i++) {
        final group = controller.saveGroup(name: '集合$i');
        expect(group, isNotNull, reason: '第 $i 次创建被拒绝');
        created.add(group!.id);
      }

      final uniqueIds = created.toSet().length;
      expect(uniqueIds, 200, reason: '200 次创建只产生了 $uniqueIds 个不同 id');
      final groups = controller.loadGroups();
      expect(groups.length, 200);
      // No name was silently replaced either: an overwrite would drop a name.
      final uniqueNames = groups.map((g) => g.name).toSet().length;
      expect(uniqueNames, 200, reason: '200 次创建只留下 $uniqueNames 个不同名字');
    });

    testWidgets('a duplicate group name is refused, not merged', (tester) async {
      controller.saveGroup(name: '工作');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('sub-group-manage')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sub-group-name')),
        '工作',
      );
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();

      expect(controller.loadGroups(), hasLength(1));
      expect(find.text('已存在同名集合'), findsOneWidget);
    });

    testWidgets('the import form starts folded and can be opened and folded '
        'again', (tester) async {
      await pumpWithProfile(tester, controller);
      // Folded by default: import is rare, 更新 is daily, and an open editor
      // pushed the list below the fold.
      expect(find.byKey(const ValueKey('sub-import-collapsed')), findsOneWidget);
      expect(find.text('导入节点'), findsOneWidget);
      // The entry point is always reachable, never merely hidden.
      expect(find.byKey(const ValueKey('sub-import-expand')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sub-import-expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sub-import-collapsed')), findsNothing);
      expect(find.byKey(const ValueKey('sub-import-collapse')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sub-import-collapse')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sub-import-collapsed')), findsOneWidget);
    });

    testWidgets('a fresh install with no subscriptions can still open and '
        'fold the form', (tester) async {
      // The collapsed bar used to require at least one subscription, so a
      // first-run window whose form was closed by the new default would have no
      // way back — or, worse, would show an open form that the 收起 button
      // appeared to have closed.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SubscriptionsPage(
              controller: controller,
              onOpenNodes: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const ValueKey('sub-import-collapsed')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sub-import-expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sub-import-collapse')), findsOneWidget);
    });
  });
}
