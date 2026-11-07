import 'dart:math' as math;

import 'package:halo_contracts/halo_contracts.dart';

/// Live throughput, derived by differencing the core's cumulative counters.
///
/// The core reports totals, not rates, so a rate only exists as a difference
/// between two samples. Keeping that arithmetic out of the widget is what makes
/// it testable: the caller supplies the timestamp, so a test can advance two
/// seconds without waiting two seconds.
///
/// Three things here are easy to get wrong and are handled deliberately:
///
///  * A negative delta means the core restarted and its counters went back to
///    zero. Reporting the raw difference would draw a large negative rate, so it
///    becomes a fresh baseline instead.
///  * A connection seen for the first time has no interval behind it. Its rate
///    is unknown, not zero, so it is left out of [perConnection] until the next
///    poll — otherwise every new connection would briefly claim 0 B/s.
///  * A connection that disappears stops being counted. Its bytes remain in
///    the core's aggregate, or in the accumulated samples in proxy-only mode.
class ThroughputMonitor {
  ThroughputMonitor({this.historyLength = 60, this.proxyOnly = false});

  /// How many samples the sparkline keeps, one per poll.
  final int historyLength;

  /// In this mode, only sampled bytes from Halo's proxy outbound count.
  /// The core's aggregate includes direct traffic and cannot be used here.
  final bool proxyOnly;

  DateTime? _at;
  int _up = 0;
  int _down = 0;
  final Map<String, (int, int)> _bytes = {};

  /// Bytes per second across the connections included in this monitor.
  double upRate = 0;
  double downRate = 0;

  /// Per-connection rates in bytes per second, keyed by connection id.
  Map<String, (double, double)> perConnection = {};

  /// Peaks since the monitor started, so a burst that has already ended is
  /// still visible rather than lost between polls.
  double peakUp = 0;
  double peakDown = 0;

  /// The last [historyLength] total rates, oldest first.
  final List<(double, double)> history = [];

  bool get hasSample => _at != null;

  /// Whether there is a curve to draw, not merely a sample.
  ///
  /// The first poll establishes a baseline but produces no rate (there is no
  /// earlier timestamp to difference against), so "has a sample" and "can draw"
  /// are different questions. A chart keyed on [hasSample] therefore rendered
  /// as a bare baseline for one poll — a 34px blank band under the rates.
  bool get hasCurve => history.length >= 2;
  int get uploadTotal => _up;
  int get downloadTotal => _down;
  int get activeConnections => _bytes.length;

  /// The interval below which a delta is too short to divide by: two polls
  /// closer together than this are either a duplicate or a clock problem.
  static const minimumInterval = Duration(milliseconds: 50);

  void sample(ConnectionsSnapshot snapshot, DateTime at) {
    final previousAt = _at;
    final dt = previousAt == null ? Duration.zero : at.difference(previousAt);
    if (proxyOnly && previousAt != null && dt < minimumInterval) return;
    final connections = proxyOnly
        ? snapshot.connections.where((c) => c.chains.contains('proxy'))
        : snapshot.connections;

    if (dt >= minimumInterval) {
      final seconds = dt.inMilliseconds / 1000.0;
      var upDelta = proxyOnly ? 0 : snapshot.uploadTotal - _up;
      var downDelta = proxyOnly ? 0 : snapshot.downloadTotal - _down;

      final next = <String, (double, double)>{};
      for (final conn in connections) {
        final before = _bytes[conn.id];
        final rowUp = math.max(0, conn.upload - (before?.$1 ?? 0));
        final rowDown = math.max(0, conn.download - (before?.$2 ?? 0));
        if (proxyOnly) {
          upDelta += rowUp;
          downDelta += rowDown;
        }
        if (before != null) {
          next[conn.id] = (rowUp / seconds, rowDown / seconds);
        }
      }
      perConnection = next;
      if (proxyOnly) {
        _up += upDelta;
        _down += downDelta;
      }
      upRate = upDelta >= 0 ? upDelta / seconds : 0;
      downRate = downDelta >= 0 ? downDelta / seconds : 0;

      peakUp = math.max(peakUp, upRate);
      peakDown = math.max(peakDown, downRate);

      history.add((upRate, downRate));
      while (history.length > historyLength) {
        history.removeAt(0);
      }

    }

    _at = at;
    if (!proxyOnly) {
      _up = snapshot.uploadTotal;
      _down = snapshot.downloadTotal;
    }
    _bytes
      ..clear()
      ..addEntries(
        connections.map((c) => MapEntry(c.id, (c.upload, c.download))),
      );
  }

  /// Forgets everything, including the peaks. Used when the core is known to
  /// have restarted so a stale peak does not outlive the numbers behind it.
  void reset() {
    _at = null;
    _up = 0;
    _down = 0;
    _bytes.clear();
    upRate = 0;
    downRate = 0;
    peakUp = 0;
    peakDown = 0;
    perConnection = {};
    history.clear();
  }
}

/// Bytes per second as a compact string.
///
/// Reuses [formatBytes]-style units rather than reimplementing them, so a rate
/// and a total cannot drift apart.
///
/// Zero renders as `0 B/s`, not as a dash. A dash reads as "we do not know",
/// and an idle connection's rate *is* known: it is zero. The dash made an idle
/// list indistinguishable from a broken sample.
String rateLabel(double bytesPerSecond) {
  final rounded = bytesPerSecond.round();
  if (rounded <= 0) return '0 B/s';
  if (rounded < 1024) return '$rounded B/s';
  if (rounded < 1024 * 1024) return '${(rounded / 1024).toStringAsFixed(1)} KB/s';
  if (rounded < 1024 * 1024 * 1024) {
    return '${(rounded / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }
  return '${(rounded / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
}
