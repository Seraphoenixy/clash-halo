/// Two polylines for a pair of rates, normalised to the window's own peak.
///
/// Shared rather than copied: the connection list and the home dashboard show
/// the same measurement, and two implementations would drift in stroke width and
/// in whether an idle list draws a flat line (it must not — see below).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';

class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.samples,
    required this.up,
    required this.down,
    required this.grid,
    this.height = 26,
    this.placeholder,
  });

  /// Oldest first, one entry per poll.
  final List<(double, double)> samples;
  final Color up;
  final Color down;
  final Color grid;
  final double height;

  /// Shown in place of the grid while there is nothing to plot.
  ///
  /// Without it an empty chart renders as a blank box or, worse, as the bare
  /// baseline — which looks like a broken graph rather than "no data yet".
  /// Passing null keeps the old behaviour for callers that draw their own
  /// caption.
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    // Fewer than two samples cannot be a line. The painter draws only the
    // baseline in that case, which is a hairline in the border tone — the card
    // then shows 34px of nothing, exactly the "empty box" the placeholder was
    // added to prevent. Keyed on `length < 2`, not `isEmpty`: the first poll
    // produces a sample with no interval behind it, so one sample is still
    // "no curve yet".
    if (samples.length < 2 && placeholder != null) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            placeholder!,
            // `grid` is the baseline colour — a hairline in the card border
            // tone. Text drawn in it is invisible, which made "no sample yet"
            // look like an empty box, the exact state the placeholder exists to
            // distinguish. Caption colour instead.
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 10.5,
              color: HaloPalette.of(context).textTertiary,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        // A copy, not the live list: the caller passes the same mutable history
        // every rebuild, so two painters holding the same instance would compare
        // equal against themselves forever and the curve would freeze once the
        // buffer filled. The copy is what makes the painter's content comparison
        // meaningful; at 40–60 samples per poll it costs nothing.
        painter: SparklinePainter(
          samples: List.of(samples),
          up: up,
          down: down,
          grid: grid,
        ),
      ),
    );
  }
}

class SparklinePainter extends CustomPainter {
  const SparklinePainter({
    required this.samples,
    required this.up,
    required this.down,
    required this.grid,
  });

  final List<(double, double)> samples;
  final Color up;
  final Color down;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      base,
    );
    if (samples.length < 2) return;

    // Normalise against the window's own peak, and draw nothing when that peak
    // is zero. Dividing by a floor of 1 instead would put an idle list's flat
    // zero line on the bottom edge, where it sits exactly on the baseline and
    // reads as a stray artefact rather than as "no traffic".
    var peak = 0.0;
    for (final s in samples) {
      peak = math.max(peak, math.max(s.$1, s.$2));
    }
    if (peak <= 0) return;

    void line(double Function((double, double)) pick, Color color) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = size.width * i / (samples.length - 1);
        final y = size.height * (1 - (pick(samples[i]) / peak).clamp(0.0, 1.0));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    line((s) => s.$1, up);
    line((s) => s.$2, down);
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      !_sameSamples(old.samples, samples) ||
      old.up != up ||
      old.down != down ||
      old.grid != grid;

  /// Compares sample *content*, not list identity or length.
  ///
  /// The callers pass the same mutable list every rebuild (a throughput
  /// monitor's rolling history), so once the buffer filled up, the length
  /// stopped changing and `shouldRepaint` went permanently false — the curve
  /// froze while the numbers underneath kept moving. The grid colour is
  /// compared too, or a theme switch left the baseline in the old palette.
  static bool _sameSamples(
    List<(double, double)> a,
    List<(double, double)> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
