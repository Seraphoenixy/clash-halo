import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/widgets.dart';

/// Control geometry is a contract, not a coincidence.
///
/// Measured before this file existed: TextField 36, bare DropdownButton 48,
/// DropdownButtonFormField 40, buttons 48 — four heights in one toolbar, none
/// of them the 32 that [HaloMetrics.controlHeight] claims. The visible symptom
/// is a filter row where the search box and the two dropdowns sit on visibly
/// different baselines.
///
/// These tests pin the target: every form control is exactly
/// [HaloMetrics.controlHeight] tall, so a future change that lets one grow is
/// caught here rather than by eye.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: Center(child: SizedBox(width: 900, child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double heightOf(WidgetTester tester, String key) =>
      tester.getSize(find.byKey(ValueKey(key))).height;

  testWidgets('a text field is one control tall', (tester) async {
    await pump(
      tester,
      const SizedBox(
        key: ValueKey('field'),
        width: 230,
        child: TextField(decoration: InputDecoration(hintText: '搜索')),
      ),
    );
    expect(heightOf(tester, 'field'), HaloMetrics.controlHeight);
  });

  testWidgets('a HaloDropdown is one control tall', (tester) async {
    await pump(
      tester,
      HaloDropdown<String>(
        key: const ValueKey('dropdown'),
        width: 132,
        value: null,
        hint: '全部协议',
        items: const [('', '全部协议'), ('a', 'Naive')],
        onChanged: (_) {},
      ),
    );
    expect(heightOf(tester, 'dropdown'), HaloMetrics.controlHeight);
  });

  // A labelled form field is 2px taller: the floating label straddles the top
  // border. What matters is that it tracks controlHeight rather than drifting
  // to its own value.
  testWidgets('a labelled form dropdown is one control plus its label', (
    tester,
  ) async {
    await pump(
      tester,
      SizedBox(
        key: const ValueKey('form'),
        width: 240,
        child: DropdownButtonFormField<String>(
          initialValue: 'a',
          decoration: const InputDecoration(labelText: '间隔'),
          items: const [DropdownMenuItem(value: 'a', child: Text('a'))],
          onChanged: (_) {},
        ),
      ),
    );
    expect(heightOf(tester, 'form'), HaloMetrics.controlHeight + 2);
  });

  testWidgets('buttons are one control tall', (tester) async {
    await pump(
      tester,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            key: const ValueKey('outlined'),
            onPressed: () {},
            child: const Text('按钮'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('filled'),
            onPressed: () {},
            child: const Text('按钮'),
          ),
        ],
      ),
    );
    expect(heightOf(tester, 'outlined'), HaloMetrics.controlHeight);
    expect(heightOf(tester, 'filled'), HaloMetrics.controlHeight);
  });
}
