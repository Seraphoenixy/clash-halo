import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/main.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/app.dart';
import 'package:halo/src/ui/error_screen.dart';
import 'package:halo/src/ui/shell.dart';

/// Regression tests for "the window is a blank grey rectangle".
///
/// A release build paints Flutter's default error widget, an empty grey box,
/// when the first build throws. The root widget used to throw whenever the
/// database was unavailable, so a store failure produced a grey window with no
/// text, no node list and nothing to report. These tests keep that from coming
/// back.
///
/// `start()` arms a periodic subscription timer, so the controller must be
/// disposed *inside* the test body: the test binding fails a test that leaves a
/// timer pending after the widget tree is torn down.
void main() {
  /// A data directory that cannot be created, because a *file* already sits at
  /// the path. That fails `Directory.createSync` inside `HaloStore.open`, which
  /// is the same shape as a permission or disk-full failure.
  late Directory root;
  late AppController controller;

  void blockedStore() {
    root = Directory.systemTemp.createTempSync('halo_store_fail');
    final blocker = File('${root.path}${Platform.pathSeparator}data')
      ..writeAsStringSync('not a directory');
    expect(blocker.existsSync(), isTrue);
    controller = AppController(
      dataDir: '${root.path}${Platform.pathSeparator}data',
    );
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        // A lingering WAL file on Windows can keep the directory busy.
      }
    });
  }

  testWidgets('a store failure does not throw out of the root widget',
      (tester) async {
    blockedStore();
    await controller.start(connectHost: false);
    expect(controller.storeReady, isFalse);
    expect(controller.storeError, isNotNull);

    // The original defect: this threw `Bad state: 数据库不可用` from initState.
    await tester.pumpWidget(HaloRoot(controller: controller));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('Clash Halo'), findsOneWidget);
    await controller.dispose();
  });

  testWidgets('the shell explains a dead store instead of crashing a page',
      (tester) async {
    blockedStore();
    await controller.start(connectHost: false);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(body: HaloApp(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('数据库不可用'), findsOneWidget);
    // The reason the store reported must reach the user, not just the symptom.
    expect(find.textContaining('无法打开数据库'), findsOneWidget);

    // Every page must stay reachable rather than throwing on a dead store.
    for (final page in HaloPage.values) {
      await tester.tap(find.text(page.label).first);
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: 'page ${page.label} threw');
      expect(find.text('数据库不可用'), findsWidgets);
    }
    await controller.dispose();
  });

  test('a dead store returns null from a preference read, not an exception',
      () async {
    blockedStore();
    await controller.start(connectHost: false);

    expect(controller.storedSetting('theme.mode'), isNull);
    // The throwing getter must stay throwing: it is a programming error to use
    // it without checking `storeReady` first.
    expect(() => controller.settingsRepo, throwsStateError);
    await controller.dispose();
  });

  testWidgets('the fallback error widget is readable, not a blank box',
      (tester) async {
    // Rendered standalone on purpose: ErrorWidget.builder runs wherever the
    // failure happened, with no MaterialApp or Scaffold above it.
    await tester.pumpWidget(
      haloErrorWidget(
        FlutterErrorDetails(exception: StateError('数据库不可用: 测试')),
      ),
    );
    await tester.pump();

    expect(find.text('界面渲染失败'), findsOneWidget);
    expect(find.textContaining('数据库不可用: 测试'), findsOneWidget);
  });

  // A 200%-scaled display gives the window only 590x380 logical pixels even
  // though it is 1180x760 on screen, so the panel must stay readable when the
  // viewport is half what the constants suggest.
  testWidgets('a failure discovered after the first frame replaces the page',
      (tester) async {
    // Production starts the controller only after the first frame (main.dart),
    // so the shell has already built when the database open fails. Without a
    // listener on errorRevision the panel never appeared and the window looked
    // normal but empty.
    blockedStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(body: HaloApp(controller: controller)),
      ),
    );
    await tester.pump();
    expect(find.text('数据库不可用'), findsNothing);

    await controller.start(connectHost: false);
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('数据库不可用'), findsOneWidget);
    await controller.dispose();
  });

  testWidgets('the explanation stays inside a 590x380 logical window',
      (tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    blockedStore();
    await controller.start(connectHost: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(body: HaloApp(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    final text = find.textContaining('无法打开数据库');
    expect(text, findsOneWidget);

    final rect = tester.getRect(text);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(screen.width));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(screen.height));

    await controller.dispose();
  });
}
