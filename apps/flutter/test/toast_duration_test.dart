import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/widgets.dart';

// The length of a floating message was previously whatever each call site
// happened to pass: Flutter's 4s default in most places, 2s on one page, 8s on
// another, with no rule connecting the number to the message. These pin the rule
// so a new call site inherits it instead of picking a fourth number.
void main() {
  group('duration rule', () {
    test('short confirmations are brief', () {
      expect(HaloToastDuration.forMessage('已复制分享链接'), HaloToastDuration.notice);
      expect(HaloToastDuration.confirm, const Duration(seconds: 2));
    });

    test('a message with detail gets longer than a one-liner', () {
      expect(HaloToastDuration.notice.inSeconds, lessThan(HaloToastDuration.detail.inSeconds));
      // Real examples from the pages, not invented strings.
      const verbose =
          '已更新，1462 条未导入：格式损坏 1300、缺少字段 574、传输不支持 61';
      expect(HaloToastDuration.forMessage(verbose), HaloToastDuration.detail);
    });

    test('nothing is shown longer than the documented maximum', () {
      // 8s was the old outlier and is what made a toast feel stuck on screen.
      expect(HaloToastDuration.longest.inSeconds, lessThan(8));
      final veryLong = 'x' * 500;
      expect(HaloToastDuration.forMessage(veryLong), HaloToastDuration.longest);
    });

    test('an explicit duration is respected but still capped', () {
      const two = Duration(seconds: 2);
      expect(
        HaloToastDuration.forMessage('很短', fallback: two),
        two,
        reason: '调用点自己知道得更清楚时应当被采纳',
      );
      const thirty = Duration(seconds: 30);
      expect(
        HaloToastDuration.forMessage('很短', fallback: thirty),
        HaloToastDuration.longest,
        reason: '任何消息都不应长时间盖住页面',
      );
    });
  });

  group('showHaloToast', () {
    Future<void> pumpWithButton(
      WidgetTester tester,
      void Function(BuildContext) onTap,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => onTap(context),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows the message with the computed duration', (tester) async {
      await pumpWithButton(tester, (context) {
        showHaloToast(context, '已复制分享链接');
      });
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.text('已复制分享链接'), findsOneWidget);
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(bar.duration, HaloToastDuration.notice);
    });

    testWidgets('a toast with an action still goes away on its own', (
      tester,
    ) async {
      // Flutter defaults `SnackBar.persist` to `action != null`, so a bar with
      // 查看 / 撤销 stayed until it was dismissed by hand. This is the regression
      // that made the batch-update message sit on screen forever.
      await pumpWithButton(tester, (context) {
        showHaloToast(
          context,
          '更新完成：成功 12（经代理 12，直连 0），失败 1，未导入 159 条',
          action: SnackBarAction(label: '查看', onPressed: () {}),
        );
      });
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('更新完成'), findsOneWidget);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, isFalse);

      await tester.pump(HaloToastDuration.longest);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('更新完成'), findsNothing);
    });

    testWidgets('a second message replaces the first instead of queueing', (
      tester,
    ) async {
      late BuildContext captured;
      await pumpWithButton(tester, (context) {
        captured = context;
        showHaloToast(context, '已删除 3 个节点，可撤销');
      });
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(find.text('已删除 3 个节点，可撤销'), findsOneWidget);

      showHaloToast(captured, '已撤销上一次批量修改');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Stacked bars used to overlap on this exact pair of calls.
      expect(find.text('已撤销上一次批量修改'), findsOneWidget);
      expect(find.text('已删除 3 个节点，可撤销'), findsNothing);
    });
  });
}
