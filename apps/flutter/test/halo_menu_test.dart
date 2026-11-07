import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/widgets.dart';

/// The popup menu is a control, and its rows are the control height.
///
/// Measured before this file existed, on the node page's right-click menu:
/// every row was 48 tall around 18px of text, so a ten-entry menu stood about
/// 500px tall and read as a mostly empty panel; the panel's width was forced to
/// a multiple of 56 by `IntrinsicWidth(stepWidth: 56)` inside Flutter's popup
/// route, leaving up to 55px of dead space on the right; and the entry that
/// stated its shortcut as `Text('设为当前节点\tEnter')` drew the tab as spaces
/// *inside the sentence*, so the shortcut sat a ragged distance from the label.
///
/// These tests pin the three numbers that make the menu read as one control:
/// a 32px row, a panel that fits its labels, and a shortcut column with one
/// shared right edge.
void main() {
  setUp(() {
    // The menu is a real overlay with a full-screen barrier; a large surface
    // keeps positioning deterministic rather than clamped by the test window.
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return ctx;
  }

  const entries = <HaloMenuEntry<String>>[
    HaloMenuItem(value: 'enable', label: '设为当前节点', shortcut: 'Enter'),
    HaloMenuItem(value: 'reach', label: '检查该节点连通性'),
    HaloMenuItem(value: 'throughput', label: '测该节点下载速度（耗流量）'),
    HaloMenuDivider(),
    HaloMenuItem(value: 'details', label: '节点详情…', shortcut: 'Ctrl+D'),
    HaloMenuItem(value: 'delete', label: '删除', shortcut: 'Delete', danger: true),
  ];

  testWidgets('a menu row is one control tall, not a touch target', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    showHaloMenu<String>(
      context: ctx,
      position: const Offset(100, 100),
      entries: entries,
    );
    await tester.pumpAndSettle();

    // Row pitch, measured between two adjacent labels: 48 would be Material's
    // kMinInteractiveDimension leaking the touch target into a mouse app.
    final first = tester.getRect(find.text('设为当前节点')).top;
    final second = tester.getRect(find.text('检查该节点连通性')).top;
    final pitch = second - first;
    expect(
      pitch,
      closeTo(HaloMetrics.controlHeight, 0.5),
      reason: '菜单行高必须是控件高度 32，实测 $pitch；48 是触摸目标，不是桌面菜单',
    );
  });

  testWidgets('the panel fits its labels instead of a 56px multiple', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    showHaloMenu<String>(
      context: ctx,
      position: const Offset(100, 100),
      entries: entries,
    );
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byType(IntrinsicWidth).last);
    final widest = tester.getRect(find.text('测该节点下载速度（耗流量）'));
    // The panel must be wide enough for the longest label...
    expect(
      panel.width,
      greaterThan(widest.right - panel.left),
      reason: '最长的标签不能被裁掉',
    );
    // ...and not rounded up to a multiple of 56 the way the Material route did.
    // The old panel measured in exact multiples of 56 regardless of content.
    expect(
      panel.width % 56,
      isNot(0),
      reason: '面板宽度仍是 56 的整数倍，说明还在用 Material 弹窗路由的取整',
    );
  });

  testWidgets('shortcuts share one right edge, and are not inside the label', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    showHaloMenu<String>(
      context: ctx,
      position: const Offset(100, 100),
      entries: entries,
    );
    await tester.pumpAndSettle();

    final enter = tester.getRect(find.text('Enter'));
    final ctrlD = tester.getRect(find.text('Ctrl+D'));
    final del = tester.getRect(find.text('Delete'));

    // Right-aligned to the same edge across rows whose labels differ in width.
    expect(ctrlD.right, closeTo(enter.right, 0.5));
    expect(del.right, closeTo(enter.right, 0.5));

    // And the label itself carries no tab-joined shortcut: a `\t` inside the
    // label is drawn as spaces, which is what made the column ragged.
    expect(find.text('节点详情…'), findsOneWidget);
    expect(find.text('节点详情…\tCtrl+D'), findsNothing);
  });

  testWidgets('rows behave like a menu: click, Escape, and disabled', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    String? picked;
    showHaloMenu<String>(
      context: ctx,
      position: const Offset(100, 100),
      entries: const [
        HaloMenuItem(value: 'a', label: '可执行'),
        HaloMenuItem(value: 'b', label: '不可用', enabled: false),
      ],
    ).then((v) => picked = v);
    await tester.pumpAndSettle();

    // A disabled row does not report a value.
    await tester.tap(find.text('不可用'));
    await tester.pumpAndSettle();
    expect(picked, isNull, reason: '禁用的行不应把值交回去');
    expect(find.text('可执行'), findsOneWidget, reason: '点禁用行不应关闭菜单');

    await tester.tap(find.text('可执行'));
    await tester.pumpAndSettle();
    expect(picked, 'a');
    expect(find.text('可执行'), findsNothing, reason: '选中后菜单必须关闭');
  });

  testWidgets('Escape dismisses without a value, and arrows plus Enter pick', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    var closed = false;
    String? picked;
    showHaloMenu<String>(
      context: ctx,
      position: const Offset(100, 100),
      entries: const [
        HaloMenuItem(value: 'a', label: '第一项'),
        HaloMenuItem(value: 'b', label: '第二项'),
      ],
    ).then((v) {
      closed = true;
      picked = v;
    });
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(picked, 'b', reason: '两次下箭头应停在第二项');

    // Reopen for the Escape path.
    showHaloMenu<String>(
      context: ctx,
      position: const Offset(100, 100),
      entries: const [HaloMenuItem(value: 'a', label: '第一项')],
    ).then((v) => picked = v);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('第一项'), findsNothing, reason: 'Escape 必须关闭菜单');
  });

  testWidgets('a menu near the window edge is pulled back into view', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    showHaloMenu<String>(
      context: ctx,
      position: Offset(size.width - 4, size.height - 4),
      entries: entries,
    );
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byType(IntrinsicWidth).last);
    expect(
      panel.right,
      lessThanOrEqualTo(size.width),
      reason: '面板不能超出窗口右边',
    );
    expect(panel.bottom, lessThanOrEqualTo(size.height), reason: '面板不能超出窗口底边');
    expect(panel.left, greaterThanOrEqualTo(0), reason: '翻到左侧后仍要在窗口内');
    expect(panel.top, greaterThanOrEqualTo(0), reason: '翻到上侧后仍要在窗口内');
  });

  testWidgets('menu text has a Material ancestor, so it is not underlined', (
    tester,
  ) async {
    // Text outside any Material gets Flutter's "missing material" decoration:
    // every label rendered with two yellow underlines. A widget test does not
    // fail on it — the real window did, and only a screen capture showed it.
    // This pins the ancestor that prevents it, which is the whole point: the
    // panel is inserted into an overlay, not under a Scaffold's Material.
    final ctx = await pumpHost(tester);
    showHaloMenu<String>(
      context: ctx,
      position: const Offset(100, 100),
      entries: entries,
    );
    await tester.pumpAndSettle();

    for (final label in ['设为当前节点', '检查该节点连通性', '删除']) {
      expect(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(Material),
        ),
        findsWidgets,
        reason: '「$label」必须有一个 Material 祖先，否则真实窗口里会画出黄色下划线',
      );
    }
  });
}
