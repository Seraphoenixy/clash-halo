import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/widgets/sparkline.dart';

void main() {
  // The callers pass the same mutable list on every rebuild (a throughput
  // monitor's rolling history). The old shouldRepaint compared only the
  // length, so once the buffer filled, the length stopped changing and the
  // curve froze while the data kept moving — a correctness bug, not just
  // efficiency.
  test('repaints when same-length samples change content', () {
    final history = <(double, double)>[(1, 2), (3, 4), (5, 6)];
    // Mirrors production: each build copies the live rolling history, so the
    // old painter holds a snapshot of what it painted, not the live list.
    final paintedEarlier = SparklinePainter(
      samples: List.of(history),
      up: Colors.red,
      down: Colors.blue,
      grid: Colors.grey,
    );

    // Same content at the next build: no repaint.
    final sameContent = SparklinePainter(
      samples: List.of(history),
      up: Colors.red,
      down: Colors.blue,
      grid: Colors.grey,
    );
    expect(sameContent.shouldRepaint(paintedEarlier), isFalse);

    // Same length, new content — exactly what happens after the rolling
    // buffer has filled: the curve must keep moving.
    history[2] = (9, 9);
    final contentChanged = SparklinePainter(
      samples: List.of(history),
      up: Colors.red,
      down: Colors.blue,
      grid: Colors.grey,
    );
    expect(contentChanged.shouldRepaint(paintedEarlier), isTrue,
        reason: 'same-length sample changes must repaint (buffer full case)');

    // The grid colour participates, so a theme switch does not leave the
    // baseline painted in the old palette.
    expect(
      SparklinePainter(
        samples: List.of(history),
        up: Colors.red,
        down: Colors.blue,
        grid: Colors.black,
      ).shouldRepaint(contentChanged),
      isTrue,
    );
  });

  testWidgets('one sample is still "no curve yet", in readable text', (
    tester,
  ) async {
    // The painter draws nothing but the baseline for fewer than two samples,
    // so a chart keyed on `samples.isEmpty` rendered a 30px blank band for the
    // first poll — the exact "empty box" the placeholder exists to prevent.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            child: Sparkline(
              samples: [(0, 0)],
              up: Colors.green,
              down: Colors.blue,
              grid: HaloColors.lightBorder,
              height: 30,
              placeholder: '等待采样…',
            ),
          ),
        ),
      ),
    );

    expect(find.text('等待采样…'), findsOneWidget);

    // The label used to take `grid` — the baseline hairline colour — so it was
    // invisible against the card. It must be a text token, not the grid colour.
    final style = tester.widget<Text>(find.text('等待采样…')).style!;
    expect(style.color, isNot(HaloColors.lightBorder));
    expect(style.color, HaloPalette.byBrightness(Brightness.light).textTertiary);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            child: Sparkline(
              samples: [(1, 2), (3, 4)],
              up: Colors.green,
              down: Colors.blue,
              grid: HaloColors.lightBorder,
              height: 30,
              placeholder: '等待采样…',
            ),
          ),
        ),
      ),
    );
    expect(find.text('等待采样…'), findsNothing);
  });
}
