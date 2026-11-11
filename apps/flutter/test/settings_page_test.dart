import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/diagnostics.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/settings_page.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

void main() {
  group('diagnostic text', () {
    test('carries versions and row counts', () {
      final text = buildDiagnosticsText(
        DiagnosticsInput(
          appVersion: '0.1.0',
          hostVersion: '0.1.0',
          coreVersion: 'sing-box 1.14.4',
          dataDir: r'C:\Users\x\AppData\Local\clash-halo',
          connectionLabel: '已连接',
          coreStateLabel: '运行中',
          stateVersion: 42,
          coreRestarts: 1,
          configVersion: 7,
          proxyMode: 'rule',
          systemProxyEnabled: true,
          tunEnabled: false,
          tunSupported: true,
          speedTestRunning: false,
          logBytes: 3 * 1024 * 1024,
          themeModeLabel: '跟随系统',
          logLevelLabel: '警告（默认）',
          logLevelApplied: true,
          speedTestConcurrency: 4,
          tableCounts: const {'nodes': 5, 'subscriptions': 0, 'settings': 12},
          now: DateTime(2026, 11, 4, 20, 30, 15),
        ),
      );
      expect(text, contains('0.1.0'));
      expect(text, contains('sing-box 1.14.4'));
      expect(text, contains('节点: 5 条'));
      expect(text, contains('订阅: 0 条'));
      expect(text, contains('设置项: 12 条'));
      expect(text, contains('测速并发: 4'));
      expect(text, contains('日志级别: 警告（默认）'));
      expect(text, contains('3.0 MB'));
      expect(text, contains('2026-11-04 20:30:15'));
    });

    test('a saved-but-unapplied log level says so', () {
      DiagnosticsInput withApplied(bool applied) => DiagnosticsInput(
        appVersion: '0.1.0',
        hostVersion: '—',
        coreVersion: '—',
        dataDir: 'C:/data',
        connectionLabel: '未连接',
        coreStateLabel: '已停止',
        stateVersion: 0,
        coreRestarts: 0,
        configVersion: 0,
        proxyMode: 'rule',
        systemProxyEnabled: false,
        tunEnabled: false,
        tunSupported: false,
        speedTestRunning: false,
        logBytes: 0,
        themeModeLabel: '浅色',
        logLevelLabel: '调试（日志明显变大）',
        logLevelApplied: applied,
        speedTestConcurrency: 8,
        tableCounts: const {},
        now: DateTime(2026, 1, 1),
      );
      expect(buildDiagnosticsText(withApplied(true)), isNot(contains('尚未应用')));
      expect(buildDiagnosticsText(withApplied(false)), contains('尚未应用'));
      // An unopened database must read as unknown, not as "0 条".
      expect(buildDiagnosticsText(withApplied(true)), contains('未知'));
    });

    test('a database full of secrets produces a text without them', () async {
      final dir = Directory.systemTemp.createTempSync('halo-diagnostics-');
      final controller = AppController(dataDir: dir.path);
      try {
        await controller.start(connectHost: false);
        // Real values of every shape the report must not carry: a share link
        // with a password, a subscription URL with a token, and a node name that
        // an airport filled with an e-mail address.
        controller.saveImport(
          importNodes(
            'trojan://SuperSecretPw@api.secret-host.xyz:443#客服a@b.com',
          ),
        );
        controller.subscriptionRepo.upsert(
          const SubscriptionProfile(
            id: 'sub1',
            name: '机场甲',
            url: 'https://api.example.xyz/sub?token=TOPSECRETTOKEN',
          ),
        );
        controller.notifyExternalChange();

        final text = buildDiagnosticsText(
          diagnosticsFor(
            controller,
            themeMode: 'system',
            routing: const RoutingSettings(),
            concurrency: 4,
          ),
        );

        expect(text, contains('节点: 1 条'));
        expect(text, contains('订阅: 1 条'));
        for (final secret in [
          'SuperSecretPw',
          'secret-host.xyz',
          'api.example.xyz',
          'TOPSECRETTOKEN',
          'token=',
          'a@b.com',
          '机场甲',
          'https://',
        ]) {
          expect(text.contains(secret), isFalse, reason: '诊断信息不得包含「$secret」');
        }
      } finally {
        await controller.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('log level setting', () {
    late Directory dir;
    late HaloStore store;
    late SettingsRepository settings;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('halo-log-level-');
      final open = HaloStore.open('${dir.path}/halo.db');
      expect(open.ok, isTrue, reason: open.error);
      store = open.store!;
      settings = SettingsRepository(store);
    });

    tearDown(() {
      store.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('defaults to warn and survives a save/load round trip', () {
      expect(const RoutingSettings().logLevel, 'warn');
      expect(RoutingSettings.load(settings).logLevel, 'warn');

      const RoutingSettings(logLevel: 'debug').save(settings);
      expect(RoutingSettings.load(settings).logLevel, 'debug');
      expect(settings.raw('routing.logLevel'), 'debug');
    });

    test('an unusable stored value falls back instead of breaking apply', () {
      // `trace` is accepted by the core but not offered here; a hand-edited or
      // downgraded database must not make every later apply fail.
      settings.setRaw('routing.logLevel', 'trace');
      expect(RoutingSettings.load(settings).logLevel, 'warn');
      settings.setRaw('routing.logLevel', '');
      expect(RoutingSettings.load(settings).logLevel, 'warn');
    });

    test('copyWith and equality include the level', () {
      const base = RoutingSettings();
      expect(base.copyWith(logLevel: 'info').logLevel, 'info');
      expect(base.copyWith(), base);
      expect(base == base.copyWith(logLevel: 'info'), isFalse);
      expect(
        base.copyWith(logLevel: 'info').hashCode ==
            base.copyWith(logLevel: 'info').hashCode,
        isTrue,
      );
    });

    test('the generated document carries the saved level', () {
      // The generator always had the parameter; nothing passed it, so every
      // document said `warn`. Reverse-checking this by hardcoding 'warn' in
      // build() is what proves the wire is connected.
      final node = ProxyNode(
        id: 'n1',
        fingerprint: 'fp',
        name: 'n1',
        protocol: ProxyProtocol.trojan,
        server: 'a.example.com',
        port: 443,
        secrets: const NodeSecrets(password: 'p'),
        tls: const TlsConfig(kind: TlsKind.tls, serverName: 'a.example.com'),
        source: NodeSourceKind.manual,
      );
      for (final level in kLogLevels) {
        final built = RoutingSettings(logLevel: level).build(node);
        expect(
          built.ok,
          isTrue,
          reason: built.issues.map((i) => i.message).join('；'),
        );
        final doc = built.config!.document;
        expect((doc['log'] as Map)['level'], level, reason: '保存的日志级别必须进入生成文档');
      }
    });
  });

  group('option tables', () {
    test('every log level the page offers is one the generator accepts', () {
      expect(kLogLevelChoices.map((c) => c.value).toSet(), kLogLevels.toSet());
      expect(kLogLevels, contains('warn'));
      for (final choice in kLogLevelChoices) {
        expect(choice.label.trim(), isNotEmpty);
      }
      // The one that costs disk must say so where the choice is made.
      expect(logLevelLabel('debug'), contains('变大'));
      expect(logLevelLabel('nonsense'), logLevelLabel('warn'));
    });

    test('concurrency choices sit inside what the host accepts', () {
      // 8 is the default the page loads when nothing is stored, so it has to be
      // one of the offered values or the dropdown would show a stale number.
      expect(kSpeedConcurrencyChoices, contains(8));
      for (final value in kSpeedConcurrencyChoices) {
        expect(value, inInclusiveRange(1, 32));
        expect(AppController.clampConcurrency(value), value);
      }
    });

    test('clamping is bounded on both ends', () {
      expect(AppController.clampConcurrency(0), 1);
      expect(AppController.clampConcurrency(-5), 1);
      expect(AppController.clampConcurrency(1), 1);
      expect(AppController.clampConcurrency(4), 4);
      expect(AppController.clampConcurrency(8), 8);
      expect(AppController.clampConcurrency(16), 16);
      expect(AppController.clampConcurrency(32), 32);
      expect(AppController.clampConcurrency(33), 32);
      expect(AppController.clampConcurrency(1024), 32);
    });
  });

  group('page', () {
    late Directory dir;
    late AppController controller;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('halo-settings-page-');
      controller = AppController(dataDir: dir.path);
      await controller.start(connectHost: false);
    });

    tearDown(() async {
      await controller.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('sections appear in the documented order', (tester) async {
      // The order encodes the daily path: engine settings first, then how the
      // app runs, then appearance, then data, then about.
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 2200,
              child: SettingsPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);

      const titles = ['代理与内核', '运行方式', '界面', '数据与诊断', '关于'];
      final tops = <double>[];
      for (final title in titles) {
        final finder = find.text(title);
        expect(finder, findsWidgets, reason: '缺少分区「$title」');
        tops.add(tester.getRect(finder.first).top);
      }
      for (var i = 1; i < tops.length; i++) {
        expect(
          tops[i] > tops[i - 1],
          isTrue,
          reason: '「${titles[i]}」应排在「${titles[i - 1]}」之后',
        );
      }

      // The two new settings and the copy button must be reachable.
      expect(find.text('日志级别'), findsOneWidget);
      expect(find.text('IPv6'), findsOneWidget);
      expect(find.text('测速并发'), findsOneWidget);
      // Nothing stored yet, so the dropdown shows the default, not 4.
      expect(find.byKey(const ValueKey('speed-concurrency-8')), findsOneWidget);
      expect(find.text('复制诊断信息'), findsOneWidget);
      // Read-only, never a control: the host owns the rotation size.
      expect(find.textContaining('2 MiB'), findsWidgets);
    });

    testWidgets('IPv6 defaults off and the toggle persists', (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 2200,
              child: SettingsPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(RoutingSettings.load(controller.settingsRepo).ipv6, isFalse);
      await tester.tap(find.byKey(const ValueKey('ipv6')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(RoutingSettings.load(controller.settingsRepo).ipv6, isTrue);
    });

    testWidgets('the about card carries versions, not build-status prose', (
      tester,
    ) async {
      // The card used to describe the project's own development state — which
      // components existed, what had been verified, what Android was — and its
      // TUN sentence had gone stale. A settings page states settings, not the
      // retired elevated helper.
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 2200,
              child: SettingsPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('基础功能已接入'), findsNothing);
      expect(find.textContaining('halo-tun-helper'), findsNothing);
      expect(find.textContaining('Android 端'), findsNothing);
      expect(find.textContaining('验证记录验收'), findsNothing);
      // What it still knows stays: the two facts a bug report needs.
      expect(find.text('版本'), findsWidgets);
      expect(find.text('代理内核'), findsWidgets);
    });

    testWidgets('choosing a log level writes it to the routing settings', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 1500,
              child: SettingsPage(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      // The stored default is what the dropdown shows before anything is picked.
      expect(find.text('警告（默认）'), findsOneWidget);

      await tester.tap(find.text('警告（默认）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调试（日志明显变大）').last);
      await tester.pumpAndSettle();

      // The whole path: dropdown → RoutingSettings → database.
      expect(
        controller.settingsRepo.raw('routing.logLevel'),
        'debug',
        reason: '选择后必须落到 routing.logLevel',
      );
      expect(RoutingSettings.load(controller.settingsRepo).logLevel, 'debug');
    });
  });
}
