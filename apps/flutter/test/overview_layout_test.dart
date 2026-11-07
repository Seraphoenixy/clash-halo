import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/exit_info.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/overview_page.dart';
import 'package:halo/src/ui/widgets.dart';
import 'package:halo_contracts/halo_contracts.dart';

/// Geometry of the dashboard grid.
///
/// The page's complaint was "the spacing is uneven": cards were 8px apart
/// vertically, 0px apart where a column met the full-width card under it, and
/// the two columns ended at different heights, leaving a hole. These tests pin
/// the answer — one gap token, equal-height rows, one left edge — so the next
/// layout change cannot quietly reintroduce any of it.
void main() {
  late Directory dir;
  late AppController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-overview-layout');
    controller = AppController(dataDir: dir.path);
    await controller.start(connectHost: false);
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 3,
        // A stopped core: no exit lookup, hence no retry timer left pending at
        // the end of a test, and no banner (nothing is intercepted).
        coreState: CoreState.stopped,
        systemProxy: SystemProxyState.off,
        tunState: TunState.disabled,
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

  Future<void> pump(WidgetTester tester, {Size size = const Size(1000, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: OverviewPage(
            controller: controller,
            exitService: ExitInfoService(
              proxyResolver: () => '127.0.0.1:7890',
              transport: (url, proxy, timeout) async => const {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Rect cardRect(WidgetTester tester, String title) {
    final card = find.ancestor(
      of: find.text(title).first,
      matching: find.byType(SectionCard),
    );
    expect(card, findsWidgets, reason: title);
    return tester.getRect(card.first);
  }

  testWidgets('paired cards share one height and one gap', (tester) async {
    await pump(tester);

    // Row 1: 当前节点 | 实时流量 — equal heights, because a row is one band.
    final node = cardRect(tester, '当前节点');
    final traffic = cardRect(tester, '实时流量');
    expect(node.top, traffic.top);
    expect(node.height, moreOrLessEquals(traffic.height, epsilon: 0.5));

    // Row 2 and 3 are the other two pairs; every gap between rows must be the
    // same token. The old layout used 8 inside a column and 0 before the
    // full-width card, which is the unevenness the page was reporting.
    final core = cardRect(tester, '代理内核');
    final proxy = cardRect(tester, '系统代理');
    expect(
      core.top - node.bottom,
      moreOrLessEquals(HaloMetrics.cardGap, epsilon: 0.5),
      reason: 'the gap between row 1 and 2',
    );
    expect(
      proxy.top - core.bottom,
      moreOrLessEquals(HaloMetrics.cardGap, epsilon: 0.5),
      reason: 'the gap between row 2 and 3',
    );

    // The two columns are the same width and are separated by the same gap.
    expect(node.width, moreOrLessEquals(traffic.width, epsilon: 0.5));
    expect(
      traffic.left - node.right,
      moreOrLessEquals(HaloMetrics.cardGap, epsilon: 0.5),
    );
  });

  testWidgets('the full-width card under the grid uses the same gap', (
    tester,
  ) async {
    await pump(tester, size: const Size(1000, 1200));
    final tun = cardRect(tester, 'TUN 模式');
    final status = cardRect(tester, '运行信息');
    expect(status.left, lessThan(tun.left + 1));
    expect(
      status.top - tun.bottom,
      moreOrLessEquals(HaloMetrics.cardGap, epsilon: 0.5),
      reason: 'a full-width card must not butt against the grid above it',
    );
    // Full width: the two columns plus the gap between them.
    expect(
      status.width,
      moreOrLessEquals(tun.width * 2 + HaloMetrics.cardGap, epsilon: 1),
    );
  });

  testWidgets('a card title and its body share a left edge', (tester) async {
    await pump(tester);
    // 系统代理 holds a HaloSwitchTile, which used to carry 4px of side padding:
    // its switch row started 4px right of the heading above it.
    final title = tester.getTopLeft(find.text('系统代理'));
    final row = tester.getTopLeft(find.text('设置 Windows 系统代理'));
    expect(row.dx, moreOrLessEquals(title.dx, epsilon: 0.5));
  });

  testWidgets('the exit card aligns its values with its IP', (tester) async {
    await pump(tester);
    // No data is not the interesting case; the label column width is. The IP
    // used to start at the card edge while the rows under it were pushed 116px
    // right by a 104px label column. Both now start at the card padding.
    final card = cardRect(tester, '出口信息');
    final empty = find.textContaining('尚未查询出口');
    expect(empty, findsOneWidget);
    expect(tester.getTopLeft(empty).dx, greaterThan(card.left));
  });

  testWidgets('one column keeps the same gap between cards', (tester) async {
    await pump(tester, size: const Size(600, 1400));
    final node = cardRect(tester, '当前节点');
    final traffic = cardRect(tester, '实时流量');
    expect(node.left, traffic.left);
    expect(
      traffic.top - node.bottom,
      moreOrLessEquals(HaloMetrics.cardGap, epsilon: 0.5),
    );
  });
}
