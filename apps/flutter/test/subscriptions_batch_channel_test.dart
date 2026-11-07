import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/subscriptions_page.dart';
import 'package:halo_domain/halo_domain.dart';

/// Records which rows went out, and through which channel.
class _RecordingController extends AppController {
  _RecordingController({required super.dataDir});

  final List<({String id, bool? useProxy, bool viaProxy})> calls = [];

  @override
  bool get connected => true;

  @override
  bool get proxyAvailable => true;

  @override
  Future<SubscriptionUpdate> updateSubscription(
    SubscriptionProfile profile, {
    bool viaProxy = false,
  }) async {
    calls.add((id: profile.id, useProxy: profile.useProxy, viaProxy: viaProxy));
    return SubscriptionUpdate(
      imported: 1,
      skipped: 0,
      failed: 0,
      viaProxy: viaProxy,
    );
  }
}

/// The batch buttons differ only in the channel they ask for.
///
/// 全部更新 must pass every row through with its own switch intact (the
/// controller then resolves 直连 / 经代理 / 自动), while 代理更新 forces the
/// proxy for this one run. If the page flattened either into a fixed value,
/// the per-row setting would be silently dead — which is what a user sees as
/// "全部更新 doesn't use my proxy".
void main() {
  late Directory dir;
  late _RecordingController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-batch-channel-');
    controller = _RecordingController(dataDir: dir.path);
    await controller.start(connectHost: false);
    controller.subscriptionRepo.upsert(
      const SubscriptionProfile(
        id: 'auto',
        name: '自动行',
        url: 'https://raw.githubusercontent.com/o/r/main/list.txt',
      ),
    );
    controller.subscriptionRepo.upsert(
      const SubscriptionProfile(
        id: 'proxied',
        name: '代理行',
        url: 'https://example.com/sub',
        useProxy: true,
      ),
    );
    controller.subscriptionRepo.upsert(
      const SubscriptionProfile(
        id: 'direct',
        name: '直连行',
        url: 'https://example.com/direct',
        useProxy: false,
      ),
    );
    controller.notifyExternalChange();
  });

  tearDown(() async {
    await controller.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // A lingering WAL file on Windows can keep the directory busy.
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 1400);
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

  testWidgets('全部更新 hands every row over with its own channel', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('sub-update-all')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(controller.calls, hasLength(3));
    // The page must not decide anything: it forwards the stored choice and
    // leaves the resolution (including the host policy for `null`) to the
    // controller.
    expect(
      {for (final call in controller.calls) call.id: call.useProxy},
      {'auto': null, 'proxied': true, 'direct': false},
    );
    expect(controller.calls.every((call) => call.viaProxy == false), isTrue);
    // The batch line has to say which channel was used; otherwise a run that
    // quietly went direct looks exactly like one that followed the rows.
    expect(find.textContaining('经代理 0，直连 3'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('代理更新 forces the proxy for that one run', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('sub-update-all-proxy')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(controller.calls, hasLength(3));
    expect(controller.calls.every((call) => call.viaProxy), isTrue);
    // The stored switches are untouched: the override is per run.
    expect(
      {for (final call in controller.calls) call.id: call.useProxy},
      {'auto': null, 'proxied': true, 'direct': false},
    );
    expect(find.textContaining('经代理 3，直连 0'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
