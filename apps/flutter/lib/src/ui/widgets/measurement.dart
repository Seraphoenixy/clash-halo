/// How a measurement is drawn: the colour scales and the unit strings.
///
/// These live outside the pages because they are the one thing the whole app
/// must agree on. A latency of 400 ms is amber wherever it appears, and a
/// throughput of 3 MiB/s is green, and those two answers come from two
/// different scales: reusing the latency scale for throughput painted 3 MB/s
/// red because 3,145,728 milliseconds is above 600.
///
/// The rule is in docs/agents/measurement.md — merging the scales, or letting
/// one page keep its own copy, is the mistake this file exists to prevent.
library;

import 'package:flutter/painting.dart';

import '../../theme.dart';

/// Green under 200 ms, amber under 600 ms, red above — the single semantic the
/// reference client uses, applied identically wherever a latency appears.
Color latencyColor(int ms) {
  if (ms <= kLatencyFastMs) return HaloColors.success;
  if (ms <= kLatencySlowMs) return HaloColors.warning;
  return HaloColors.danger;
}

/// Thresholds for [latencyColor], named so a filter cannot drift from the
/// colour it is supposed to match.
const kLatencyFastMs = 200;
const kLatencySlowMs = 600;

/// Green above 2 MB/s, amber above 500 kB/s, red below — a throughput scale,
/// not the latency one.
Color throughputColor(int bytesPerSecond) {
  if (bytesPerSecond >= kThroughputFastBps) return HaloColors.success;
  if (bytesPerSecond >= kThroughputSlowBps) return HaloColors.warning;
  return HaloColors.danger;
}

const kThroughputFastBps = 2 * 1024 * 1024;
const kThroughputSlowBps = 500 * 1024;

/// Throughput as a compact string. Deliberately separate from latency: bytes
/// per second and milliseconds must never be printed in the same column with
/// the same colour scale.
String throughputLabel(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  }
  return '$bytesPerSecond B/s';
}
