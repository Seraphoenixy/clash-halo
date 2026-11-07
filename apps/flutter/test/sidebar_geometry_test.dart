import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/shell.dart';

/// Measures the sidebar status footer at the shipping window size.
///
/// Written because a screenshot suggested the state word was clipped at the
/// right edge. A clipped Text keeps its data, so `find.text` cannot tell; the
/// only honest check is comparing the space the row gave the text against the
/// width the glyphs need.
void main() {
  testWidgets('the sidebar state word is not clipped', (tester) async {
    tester.view.physicalSize = const Size(2360, 1520);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Row(
            children: [
              HaloSidebar(
                current: HaloPage.overview,
                onSelect: (_) {},
                connected: true,
                coreRunning: true,
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    for (final label in ['已连接', '运行中']) {
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: '侧栏缺少「$label」');
      final widget = tester.widget<Text>(finder);
      final painter = TextPainter(
        text: TextSpan(text: widget.data, style: widget.style),
        textDirection: TextDirection.ltr,
      )..layout();
      final needed = painter.width;
      final available = tester.getRect(finder).width;
      painter.dispose();
      expect(
        available + 1,
        greaterThanOrEqualTo(needed),
        reason: '「$label」需要 ${needed.toStringAsFixed(1)}px，'
            '实际只有 ${available.toStringAsFixed(1)}px，会被截断',
      );
    }

    // The footer must also stay inside the sidebar, not overflow it.
    final sidebarWidth = HaloMetrics.sidebarWidth;
    for (final label in ['已连接', '运行中']) {
      final rect = tester.getRect(find.text(label));
      expect(
        rect.right,
        lessThanOrEqualTo(sidebarWidth),
        reason: '「$label」超出侧栏右边界（${rect.right} > $sidebarWidth）',
      );
    }
  });
}
