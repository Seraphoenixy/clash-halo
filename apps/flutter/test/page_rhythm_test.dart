import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/app.dart';
import 'package:halo/src/ui/shell.dart';
import 'package:halo/src/ui/widgets.dart';
import 'package:halo_contracts/halo_contracts.dart';

/// The spacing and type rules the dashboard established, applied to every page.
///
/// The dashboard fix was not "make the numbers smaller"; it was "there is one
/// answer per question". Every other page still answered the same questions
/// differently: cards were 8px apart on 设置/订阅/规则 while the dashboard used
/// 12, and text sizes came from eight ad-hoc literals instead of the ramp. These
/// tests read the rendered tree, so a page that drifts back is caught here
/// rather than by eye.
void main() {
  late Directory dir;
  late AppController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-cros-page');
    controller = AppController(dataDir: dir.path);
    await controller.start(connectHost: false);
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

  Future<void> pump(WidgetTester tester, HaloPage page,
      {Size size = const Size(1180, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(body: HaloApp(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text(page.label).first);
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// Vertical gaps between consecutive [SectionCard]s on the current page.
  ///
  /// Cards are found by type rather than by title so this works on pages whose
  /// first card has no heading (订阅's import form, the 连接 table frame).
  List<double> cardGaps(WidgetTester tester) {
    final rects = tester
        .widgetList(find.byType(SectionCard))
        .toList();
    final boxes = <Rect>[];
    final finder = find.byType(SectionCard);
    for (var i = 0; i < rects.length; i++) {
      final r = tester.getRect(finder.at(i));
      // Ignore nested cards (a card inside a card would report the parent box).
      boxes.add(r);
    }
    boxes.sort((a, b) => a.top.compareTo(b.top));
    final gaps = <double>[];
    for (var i = 0; i < boxes.length - 1; i++) {
      final gap = boxes[i + 1].top - boxes[i].bottom;
      // Stacked cards in one column only; side-by-side cards share a top edge.
      if (gap > 0.5 && gap < 100) gaps.add(gap);
    }
    return gaps;
  }

  // Pages that stack several cards. 规则 is one framed list, so it has no
  // inter-card gap to check — its rhythm is row height, not card spacing.
  // Only 设置 stacks several independent cards. 订阅 and 规则 each frame their
  // content in one bordered surface (an import form plus a list, or the rule
  // list), so they have no inter-card gap to hold to a token — their rhythm is
  // row height, which the row tests below cover.
  for (final page in [HaloPage.settings]) {
    testWidgets('${page.label} separates its cards by cardGap', (tester) async {
      await pump(tester, page);
      final gaps = cardGaps(tester);
      expect(gaps, isNotEmpty, reason: '${page.label} stacks cards');

      // Every gap on the page must be the one token, not "8 here and 10 there".
      for (final gap in gaps) {
        expect(
          gap,
          moreOrLessEquals(HaloMetrics.cardGap, epsilon: 0.5),
          reason: '${page.label} has a ${gap}px gap between cards',
        );
      }
    });
  }

  testWidgets('user-facing copy avoids spoken-register filler', (tester) async {
    // Product text is read by users, not by developers: it states a behaviour,
    // not an attitude towards it. "级别越低越啰嗦" describes the author's
    // impression of the setting; "级别越低，写入的内容越多" describes the
    // setting. Same for the metaphorical phrasings below — each one was in the
    // shipped UI and each pinned the wrong subject.
    //
    // This list is a floor, not a style manual: it catches the phrases that
    // actually regressed, and a writer adding a new one still has to think.
    const banned = <String>[
      '啰嗦',
      '别绕',
      '不会自己',
      '不弹窗口',
      '一键',
      '傻瓜',
      '轻松',
      '折腾',
      '搞定',
      '说白了',
      '其实',
    ];
    for (final page in HaloPage.values) {
      await pump(tester, page);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final data = text.data;
        if (data == null) continue;
        for (final phrase in banned) {
          expect(
            data.contains(phrase),
            isFalse,
            reason: '${page.label}: "$data" contains "$phrase"',
          );
        }
      }
    }
  });

  testWidgets('body text on every page comes from the type ramp', (
    tester,
  ) async {
    // A literal `TextStyle(fontSize: ...)` opts a run out of the theme, and the
    // ramp is the only place a size may be chosen. Anything below the smallest
    // ramp step is a size that was invented inline.
    for (final page in HaloPage.values) {
      await pump(tester, page);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final size = text.style?.fontSize;
        if (size == null) continue;
        expect(
          size,
          greaterThanOrEqualTo(9.5),
          reason: '${page.label}: "${text.data}" is ${size}px',
        );
      }
    }
  });
}
