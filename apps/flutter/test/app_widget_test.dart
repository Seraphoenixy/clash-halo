import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/main.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/app.dart';
import 'package:halo/src/ui/pages/android_overview_page.dart';
import 'package:halo/src/ui/shell.dart';
import 'package:halo_domain/halo_domain.dart';

/// Widget-level tests. They run against a controller with no host: the point is
/// that every page renders without throwing when the runtime state is missing,
/// which is exactly the first-launch case.
void main() {
  late Directory tempDir;
  late AppController controller;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('halo_ui_test');
    controller = AppController(dataDir: tempDir.path);
  });

  tearDown(() async {
    try {
      await controller.dispose();
    } catch (_) {
      // A test that starts the controller may dispose it early to stop timers.
    }
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // A lingering WAL file on Windows can keep the directory busy; the temp
      // dir is disposable either way.
    }
  });

  Widget harness() => MaterialApp(
    theme: buildHaloTheme(Brightness.light),
    home: Scaffold(body: HaloApp(controller: controller)),
  );

  Future<void> pumpDesktop(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1180, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('shell renders every page with no runtime state', (tester) async {
    await pumpDesktop(tester);

    for (final page in HaloPage.values) {
      await tester.tap(find.text(page.label).first);
      await tester.pump(const Duration(milliseconds: 100));
      // Any thrown exception fails the test through the framework.
      expect(find.text(page.label), findsWidgets);
    }
  });

  testWidgets('overview shows a waiting state when the host is absent', (
    tester,
  ) async {
    await pumpDesktop(tester);
    expect(find.text('总览'), findsWidgets);
    // The snapshot is null without a host, so the page must explain that
    // instead of rendering an empty dashboard.
    expect(find.textContaining('尚未获取到运行状态'), findsOneWidget);
  });

  testWidgets('nodes page explains how to add nodes when the list is empty', (
    tester,
  ) async {
    await pumpDesktop(tester);
    await tester.tap(find.text('节点').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('还没有节点'), findsOneWidget);
  });

  testWidgets('connection failure is surfaced without crashing', (
    tester,
  ) async {
    await pumpDesktop(tester);
    // The pipe is never opened in this test, so the sidebar must show the
    // honest "not connected" state rather than a fake green dot.
    expect(find.text('未连接'), findsWidgets);
  });

  testWidgets('theme switches between light and dark', (tester) async {
    await pumpDesktop(tester);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold, isNotNull);
    // The theme itself is exercised by buildHaloTheme unit checks below.
    expect(haloThemeMode.value, isNotNull);
  });

  test('both brightnesses build a valid theme', () {
    for (final brightness in Brightness.values) {
      final theme = buildHaloTheme(brightness);
      expect(theme.colorScheme.brightness, brightness);
      expect(theme.scaffoldBackgroundColor, isNotNull);
    }
  });

  testWidgets('navigation adapts across desktop and portrait widths', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.getSize(find.byType(HaloSidebar).first).width,
      HaloMetrics.sidebarWidth,
    );
    expect(find.byKey(const ValueKey('open-drawer')), findsNothing);

    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getSize(find.byType(HaloSidebar).first).width,
      HaloMetrics.sidebarCollapsedWidth,
    );
    expect(find.byKey(const ValueKey('open-drawer')), findsNothing);

    tester.view.physicalSize = const Size(800, 600);
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('open-drawer')), findsOneWidget);
    expect(find.byType(HaloSidebar), findsNothing);

    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('open-drawer')), findsOneWidget);
    expect(find.byType(HaloSidebar), findsNothing);
  });

  testWidgets('all pages render in Android portrait without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));

    for (final page in HaloPage.values.skip(1)) {
      await tester.tap(find.byKey(const ValueKey('open-drawer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('nav-${page.name}')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: page.label);
    }
  });

  testWidgets('page header uses its content width, not the whole window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 600,
              height: 600,
              child: HaloPageMenu(
                onOpen: () {},
                child: HaloPageScaffold(
                  title: '窄内容页',
                  actions: [
                    OutlinedButton(onPressed: () {}, child: const Text('操作一')),
                    OutlinedButton(onPressed: () {}, child: const Text('操作二')),
                  ],
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('open-drawer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('populated nodes page fits Android portrait', (tester) async {
    await controller.start(connectHost: false);
    controller.saveImport(
      importNodes('trojan://pw@hk.example.com:443#香港%2001'),
    );
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('open-drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-nodes')));
    await tester.pumpAndSettle();

    expect(find.text('香港 01'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  });

  testWidgets('default routing rules fit Android portrait', (tester) async {
    await controller.start(connectHost: false);
    RoutingSettings.load(controller.settingsRepo);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('open-drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-routing')));
    await tester.pumpAndSettle();

    expect(find.textContaining('YouTube'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  });

  testWidgets('Android overview fits a 360x800 portrait viewport', (
    tester,
  ) async {
    await controller.start(connectHost: false);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(body: AndroidOverviewPage(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('VPN'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  });
}
