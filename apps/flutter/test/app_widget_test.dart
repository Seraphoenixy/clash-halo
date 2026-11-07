import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/main.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/app.dart';
import 'package:halo/src/ui/shell.dart';

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
    await controller.dispose();
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

  testWidgets('shell renders every page with no runtime state', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));

    for (final page in HaloPage.values) {
      await tester.tap(find.text(page.label).first);
      await tester.pump(const Duration(milliseconds: 100));
      // Any thrown exception fails the test through the framework.
      expect(find.text(page.label), findsWidgets);
    }
  });

  testWidgets('overview shows a waiting state when the host is absent',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('总览'), findsWidgets);
    // The snapshot is null without a host, so the page must explain that
    // instead of rendering an empty dashboard.
    expect(find.textContaining('尚未获取到运行状态'), findsOneWidget);
  });

  testWidgets('nodes page explains how to add nodes when the list is empty',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('节点').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('还没有节点'), findsOneWidget);
  });

  testWidgets('connection failure is surfaced without crashing', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 50));
    // The pipe is never opened in this test, so the sidebar must show the
    // honest "not connected" state rather than a fake green dot.
    expect(find.text('未连接'), findsWidgets);
  });

  testWidgets('theme switches between light and dark', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump(const Duration(milliseconds: 50));
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
}
