import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/subscriptions_page.dart';
import 'package:halo_domain/halo_domain.dart';

/// Serves the fixed answer a refresh with rejected entries produces.
///
/// The real update path is exercised in `subscription_update_test.dart`, where
/// a local HTTP server is allowed; the widget binding answers every request
/// with 400, so a widget test has to hand the page the result instead of
/// making it fetch one.
class _StubController extends AppController {
  _StubController({required super.dataDir});

  /// 全部更新 is disabled unless the host is connected; the page has no other
  /// gate, so the batch path can be exercised without a host.
  @override
  bool get connected => true;

  @override
  Future<SubscriptionUpdate> updateSubscription(
    SubscriptionProfile profile, {
    bool viaProxy = false,
  }) async => SubscriptionUpdate(
    imported: 48,
    skipped: 5,
    failed: 2,
    firstFailure: '无法识别的链接',
    failureKinds: const {'malformed_link': 2},
    failures: const [
      ImportIssue(
        kind: ImportFailureKind.malformedLink,
        message: '无法识别的链接',
        line: 2,
        raw: 'trojan://!str@two@at.example:443#broken',
      ),
      ImportIssue(
        kind: ImportFailureKind.malformedLink,
        message: '无法识别的链接',
        line: 3,
        raw: 'not-a-link',
      ),
    ],
    // Duplicates are the other half of "why is this node missing": a real
    // refresh reported 1461 missing entries of which 1580 were repeats.
    skippedKinds: const {'duplicate': 5},
    skippedSamples: const [
      ImportIssue(
        kind: ImportFailureKind.duplicate,
        message: '重复节点已跳过',
        line: 4,
        raw: 'trojan://secret@ok.example:443#ok',
      ),
    ],
  );
}

/// The refresh message is the only place a user learns that a subscription
/// lost entries.
///
/// It used to say "N 条不支持" and nothing else, which read as a protocol the
/// build is missing. A real list reported 1462 that way while 1300 of those
/// were damaged lines: the count was right, the word was wrong, and there was
/// no way to look at what had been refused.
void main() {
  // Built outside the test body for the reason documented in
  // subscriptions_page_test.dart: `start()` arms a one-minute periodic timer,
  // and a timer created inside the body is still pending when the binding
  // checks for leaks.
  late Directory dir;
  late _StubController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-import-failures-');
    controller = _StubController(dataDir: dir.path);
    await controller.start(connectHost: false);
    controller.subscriptionRepo.upsert(
      const SubscriptionProfile(
        id: 'p',
        name: '测试订阅',
        url: 'https://example.com/sub',
      ),
    );
  });

  tearDown(() async {
    await controller.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // A lingering WAL file on Windows can keep the directory busy.
    }
  });

  Future<void> pumpPage(WidgetTester tester, Size physical) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: SubscriptionsPage(controller: controller, onOpenNodes: () {}),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Runs one refresh and opens 查看, leaving the dialog on screen.
  Future<void> openFailures(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('sub-update-p')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
  }

  testWidgets('a partial refresh names the causes and lists the entries', (
    tester,
  ) async {
    await pumpPage(tester, const Size(2400, 1400));
    await tester.tap(find.byKey(const ValueKey('sub-update-p')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // The count is not the whole answer: the kind is spelled out next to it,
    // and duplicates are reported apart from refusals.
    expect(find.textContaining('未导入 2 条'), findsOneWidget);
    expect(find.textContaining('格式损坏 2'), findsOneWidget);
    expect(find.textContaining('重复 5 条'), findsOneWidget);

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();

    expect(find.text('未导入的条目'), findsOneWidget);
    expect(find.textContaining('共 2 条：格式损坏 2'), findsOneWidget);
    expect(find.textContaining('另有 5 条重复'), findsOneWidget);
    // The raw text is what makes the count actionable; without it the dialog
    // would only repeat the messages that were already ambiguous.
    final raws = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data ?? '')
        .toList();
    expect(raws.any((text) => text.contains('two@at.example')), isTrue);
    expect(raws.any((text) => text.contains('not-a-link')), isTrue);
    // The duplicate sample carries its own entry, so "重复" can be inspected
    // rather than trusted.
    expect(raws.any((text) => text.contains('trojan://secret@ok.example')), isTrue);

    // The snackbar's own timer outlives the dialog; the widget binding treats a
    // pending timer at the end of a test as a leak, and this one is by design.
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('a batch refresh also says what the numbers are', (tester) async {
    // The case that produced the complaint: 13 subscriptions updated, "1461 条
    // 未导入" and no way to tell refusals from repeats. The batch line carries
    // the kinds and the duplicate count now, and the dialog still has the
    // entries.
    controller.subscriptionRepo.upsert(
      const SubscriptionProfile(
        id: 'q',
        name: '第二个订阅',
        url: 'https://example.com/q',
      ),
    );
    await pumpPage(tester, const Size(2400, 1400));

    await tester.tap(find.byKey(const ValueKey('sub-update-all')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.textContaining('成功 2'), findsOneWidget);
    // Two profiles × (2 failures, 5 duplicates) from the stub.
    expect(find.textContaining('未导入 4 条（格式损坏 4）'), findsOneWidget);
    expect(find.textContaining('重复 10 条'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('the dialog fits the smallest supported window', (tester) async {
    // 590x380 logical, the size the whole page is checked at: the dialog is
    // 560 wide before padding, so this is where it either shrinks or overflows.
    await pumpPage(tester, const Size(1180, 760));
    await openFailures(tester);

    expect(find.text('未导入的条目'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
