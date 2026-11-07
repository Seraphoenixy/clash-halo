import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/shell.dart';

/// Regression tests for the "black frame flashes while the pointer crosses the
/// sidebar" bug.
///
/// The item fill used to animate between `Colors.transparent` and
/// `p.cardHover`. `Colors.transparent` is transparent **black**, and a colour
/// tween interpolates every ARGB channel, so mid-animation the fill is a
/// translucent dark grey: on a light sidebar that is a black box blinking in and
/// out on every hover. Two layers of assertions pin the fix:
///
///  * the idle decoration must be a zero-alpha *instance of the hover colour*,
///    not `Colors.transparent`, so the tween never leaves the hue; and
///  * the actual pixels sampled halfway through the fade must stay as light as
///    the hover fill (this is what the user sees).
void main() {
  final boundaryKey = GlobalKey();

  Widget harness({required Brightness brightness}) {
    return MaterialApp(
      theme: buildHaloTheme(brightness),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: boundaryKey,
            // The canvas colour has to be *inside* the boundary. Sampling the
            // layer directly would read premultiplied pixels of a translucent
            // fill over nothing, which looks dark no matter what the fill is.
            child: Builder(
              builder: (context) => ColoredBox(
                color: HaloPalette.of(context).canvas,
                child: SizedBox(
                  width: HaloMetrics.sidebarWidth,
                  child: HaloNavItem(
                    page: HaloPage.overview,
                    selected: false,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The row's own AnimatedContainer (the accent bar is the second one).
  BoxDecoration decorationOf(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byType(HaloNavItem),
      matching: find.byType(AnimatedContainer),
    );
    final container = tester.widget<AnimatedContainer>(finder.first);
    return container.decoration! as BoxDecoration;
  }

  /// Starts the pointer well outside the row: the row sits at the top-left
  /// corner, so a pointer created at Offset.zero would already be hovering it.
  Future<TestGesture> beginOutside(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(900, 700));
    addTearDown(gesture.removePointer);
    await tester.pump();
    return gesture;
  }

  Future<Uint32List> sampleRow(WidgetTester tester) async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late ByteData bytes;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    final width = boundary.size.width.toInt();
    // Middle of the row, vertically centred: no text or icon glyph there for
    // this label, and away from the accent bar.
    final x = width - 12;
    final y = HaloMetrics.navItemHeight ~/ 2;
    final offset = (y * width + x) * 4;
    return Uint32List.fromList([
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    ]);
  }

  testWidgets('idle fill is transparent hover colour, not transparent black', (
    tester,
  ) async {
    await tester.pumpWidget(harness(brightness: Brightness.light));
    final palette = HaloPalette.of(tester.element(find.byType(HaloNavItem)));

    final idle = decorationOf(tester).color!;
    expect(idle.a, 0, reason: 'an idle row must be invisible');
    expect(idle.r, closeTo(palette.cardHover.r, 0.001));
    expect(idle.g, closeTo(palette.cardHover.g, 0.001));
    expect(idle.b, closeTo(palette.cardHover.b, 0.001));
  });

  testWidgets('halfway through the hover fade the pixels stay light', (
    tester,
  ) async {
    await tester.pumpWidget(harness(brightness: Brightness.light));
    final before = await sampleRow(tester);

    final gesture = await beginOutside(tester);
    await gesture.moveTo(tester.getCenter(find.byType(HaloNavItem)));
    await tester.pump();
    await tester.pump(HaloMetrics.fastDuration ~/ 2);

    final mid = await sampleRow(tester);
    // With the old tween this pixel was roughly 0xB7 on a 0xF3 canvas; the fix
    // keeps it at ~0xF5. The threshold separates those two worlds with room for
    // anti-aliasing.
    expect(
      mid[2],
      greaterThan(0xE0),
      reason: 'hover fade must not darken the row (got ${mid[2].toRadixString(16)})',
    );
    expect(mid[2], greaterThanOrEqualTo(before[2] - 2));

    await tester.pump(HaloMetrics.fastDuration);
    final settled = decorationOf(tester).color!;
    expect(settled.a, 1);
    expect(
      settled.toARGB32(),
      HaloPalette.of(tester.element(find.byType(HaloNavItem))).cardHover.toARGB32(),
    );
  });

  testWidgets('leaving the row fades back without a dark pass', (tester) async {
    await tester.pumpWidget(harness(brightness: Brightness.light));
    final gesture = await beginOutside(tester);
    await gesture.moveTo(tester.getCenter(find.byType(HaloNavItem)));
    await tester.pump(HaloMetrics.fastDuration);
    expect(decorationOf(tester).color!.a, 1);

    await gesture.moveTo(const Offset(900, 700));
    await tester.pump();
    await tester.pump(HaloMetrics.fastDuration ~/ 2);

    final mid = await sampleRow(tester);
    expect(
      mid[2],
      greaterThan(0xE0),
      reason: 'un-hovering must not flash a dark rectangle',
    );

    await tester.pump(HaloMetrics.fastDuration);
    expect(decorationOf(tester).color!.a, 0);
  });

  testWidgets('dark theme fades to the dark hover fill', (tester) async {
    await tester.pumpWidget(harness(brightness: Brightness.dark));
    final palette = HaloPalette.of(tester.element(find.byType(HaloNavItem)));
    expect(palette.isDark, isTrue);

    final gesture = await beginOutside(tester);
    await gesture.moveTo(tester.getCenter(find.byType(HaloNavItem)));
    await tester.pump(HaloMetrics.fastDuration);

    final fill = decorationOf(tester).color!;
    expect(fill.a, 1);
    expect(fill.toARGB32(), palette.cardHover.toARGB32());
  });
}
