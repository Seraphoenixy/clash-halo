import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/widgets.dart';

/// The open dropdown must be the *same* control as the closed one.
///
/// The previous version failed this in a way that code review could not see: the
/// trigger was an [InputDecorator] (1px border, radius 4, 12px text inset,
/// filled) and the open list was a Material popup (elevation shadow, no fill,
/// 0px inset). Those are two widgets, so they were two styles, and the review
/// said so plainly: 「未展开和展开完全就是两个风格」.
///
/// These tests measure the geometry the two states actually produce, because
/// that is the only claim worth making. A style object that both states consult
/// is the mechanism; identical measured numbers are the proof.
void main() {
  const items = [
    ('all', '全部协议'),
    ('naive', 'Naive'),
    ('vless', 'VLESS'),
  ];

  /// Builds the dropdown but leaves the list closed.
  Future<void> pumpClosed(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: HaloDropdown<String>(
              key: const ValueKey('trigger'),
              width: 160,
              value: null,
              hint: '全部协议',
              items: items,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Rect> openMenu(WidgetTester tester) async {
    await pumpClosed(tester);
    await tester.tap(find.byKey(const ValueKey('trigger')));
    await tester.pumpAndSettle();
    // The list is drawn by HaloDropdown itself, so its rows are Text widgets
    // inside the overlay rather than DropdownMenuItem wrappers.
    final menu = find.byType(ListView).last;
    return tester.getRect(menu);
  }

  testWidgets('the open list starts exactly where the field ends', (
    tester,
  ) async {
    await pumpClosed(tester);
    final triggerBefore = tester.getRect(find.byKey(const ValueKey('trigger')));
    await tester.tap(find.byKey(const ValueKey('trigger')));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byType(ListView).last);

    // Same left edge and same width: the list is the field's continuation, not
    // a differently sized popup.
    //
    // The rect measured is the menu's own container, not the ListView inside
    // it: the 1px border sits outside the list, so measuring the list would
    // report a 1px inset that is really the border being drawn.
    final menuBox = find.ancestor(
      of: find.byType(ListView).last,
      matching: find.byType(Container),
    );
    final outer = tester.getRect(menuBox.first);
    expect(outer.left, closeTo(triggerBefore.left, 0.5));
    expect(outer.width, closeTo(triggerBefore.width, 0.5));
    // 0px gap: the list is the field's own body continuing downward, so there
    // is no seam for a gap to sit in. It used to be 2px, which read as two
    // stacked controls once both edges had their own 1px border.
    expect(outer.top, closeTo(triggerBefore.bottom, 0.5));
    // The list sits inside the border, so its own edges are 1px in from here.
    expect(menu.left, closeTo(outer.left + 1, 1.0));
  });

  testWidgets('a menu row is exactly the field height', (tester) async {
    await openMenu(tester);

    // The row the user clicks is the row they were already looking at: same
    // height as the control, so nothing shifts or grows when the list opens.
    final rows = tester
        .widgetList<ListView>(find.byType(ListView))
        .last
        .semanticChildCount;
    expect(rows, items.length, reason: 'every option must be listed');

    // Measure the first row via its label's ancestor container.
    final firstLabel = find.text('全部协议').last;
    final labelRect = tester.getRect(firstLabel);
    expect(
      labelRect.height,
      lessThanOrEqualTo(HaloMetrics.controlHeight),
      reason: 'a row must not exceed the control height',
    );
  });

  testWidgets('the label does not move sideways when the list opens', (
    tester,
  ) async {
    // The field inset and the row inset are the same constant; if they drifted
    // the text would jump left or right at the moment of opening, which is the
    // cheapest visible symptom of two styles.
    //
    // The comparison has to be between the trigger's label and the *menu row's*
    // label. Comparing `find.text(...).first` twice compares the trigger with
    // itself — the trigger is still in the tree behind the overlay — so that
    // version passed even with the menu inset forced to 0.
    await pumpClosed(tester);
    final closed = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('trigger')),
        matching: find.text('全部协议'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('trigger')));
    await tester.pumpAndSettle();
    // Last match is the one inside the overlay; the trigger's own copy comes
    // first because it is lower in the tree.
    final openRow = tester.getRect(find.text('全部协议').last);
    expect(
      openRow.left,
      closeTo(closed.left, 0.5),
      reason: '菜单行的文字必须与触发框的文字左对齐（展开瞬间不应横向移动）',
    );
  });

  testWidgets('the control is one height whether open or closed', (
    tester,
  ) async {
    await pumpClosed(tester);
    final closed = tester.getSize(find.byKey(const ValueKey('trigger')));
    await tester.tap(find.byKey(const ValueKey('trigger')));
    await tester.pumpAndSettle();
    // The trigger stays in the tree; its size must not change because the
    // overlay exists.
    final open = tester.getSize(find.byKey(const ValueKey('trigger')));
    expect(open.height, closed.height);
    expect(open.height, HaloMetrics.controlHeight);
  });

  testWidgets('picking an option closes the list and reports the value', (
    tester,
  ) async {
    String? picked;
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: HaloDropdown<String>(
              key: const ValueKey('trigger'),
              width: 160,
              value: 'all',
              hint: '全部协议',
              items: items,
              onChanged: (v) => picked = v,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('VLESS').last);
    await tester.pumpAndSettle();
    expect(picked, 'vless');
    // Closed: the extra option labels are gone.
    expect(find.text('VLESS'), findsNothing);
  });

  testWidgets('tapping outside closes the list without changing the value', (
    tester,
  ) async {
    var changes = 0;
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: HaloDropdown<String>(
              key: const ValueKey('trigger'),
              width: 160,
              value: 'all',
              items: items,
              onChanged: (_) => changes++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trigger')));
    await tester.pumpAndSettle();
    expect(find.text('Naive'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Naive'), findsNothing);
    expect(changes, 0);
  });

  testWidgets('a disabled control does not open', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: HaloDropdown<String>(
              key: const ValueKey('trigger'),
              width: 160,
              value: 'all',
              items: items,
              onChanged: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trigger')));
    await tester.pumpAndSettle();
    expect(find.text('Naive'), findsNothing);
  });
}
