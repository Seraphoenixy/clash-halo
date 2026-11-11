import 'package:halo_contracts/halo_contracts.dart';

/// Host-owned measurements, read back when a window connects.
///
/// The host outlives the window. Keeping these two shapes here — rather than
/// inside the page that happens to draw them — makes that ownership explicit:
/// the controller hydrates from them and never invents a session of its own.

class SpeedSessionState {
  const SpeedSessionState({
    required this.running,
    required this.taskId,
    required this.metric,
    required this.total,
    required this.done,
    required this.pending,
    required this.results,
    required this.updatedAtMs,
  });

  final bool running;
  final String? taskId;
  final SpeedMetric? metric;
  final int total;
  final int done;
  final List<String> pending;

  /// Raw `ProbeResult` maps. [SpeedBatchTracker] owns the status/metric
  /// interpretation, so the wire shape is not duplicated here.
  final List<Map<String, Object?>> results;
  final int updatedAtMs;

  factory SpeedSessionState.fromJson(Map<String, Object?> json) {
    final metricWire = json['metric'];
    final rawResults = json['results'];
    return SpeedSessionState(
      running: json['running'] == true,
      taskId: (json['taskId'] as String?)?.isEmpty == false
          ? json['taskId'] as String
          : null,
      metric: metricWire is String && metricWire.isNotEmpty
          ? SpeedMetric.fromWire(metricWire)
          : null,
      total: (json['total'] as num?)?.toInt() ?? 0,
      done: (json['done'] as num?)?.toInt() ?? 0,
      pending: [
        if (json['pending'] is List)
          for (final id in json['pending'] as List)
            if (id is String) id,
      ],
      results: [
        if (rawResults is List)
          for (final raw in rawResults)
            if (raw is Map) raw.cast<String, Object?>(),
      ],
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class TrafficSessionState {
  const TrafficSessionState({
    required this.upRate,
    required this.downRate,
    required this.uploadTotal,
    required this.downloadTotal,
    required this.peakUp,
    required this.peakDown,
    required this.history,
    required this.activeConnections,
    required this.updatedAtMs,
    required this.error,
  });

  final double upRate;
  final double downRate;
  final int uploadTotal;
  final int downloadTotal;
  final double peakUp;
  final double peakDown;
  final List<(double, double)> history;
  final int activeConnections;
  final int updatedAtMs;
  final String? error;

  factory TrafficSessionState.fromJson(Map<String, Object?> json) {
    final rawHistory = json['history'];
    return TrafficSessionState(
      upRate: (json['upRate'] as num?)?.toDouble() ?? 0,
      downRate: (json['downRate'] as num?)?.toDouble() ?? 0,
      uploadTotal: (json['uploadTotal'] as num?)?.toInt() ?? 0,
      downloadTotal: (json['downloadTotal'] as num?)?.toInt() ?? 0,
      peakUp: (json['peakUp'] as num?)?.toDouble() ?? 0,
      peakDown: (json['peakDown'] as num?)?.toDouble() ?? 0,
      history: [
        if (rawHistory is List)
          for (final raw in rawHistory)
            if (raw is Map)
              (
                (raw['up'] as num?)?.toDouble() ?? 0,
                (raw['down'] as num?)?.toDouble() ?? 0,
              ),
      ],
      activeConnections: (json['activeConnections'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      error: (json['error'] as String?)?.isEmpty == false
          ? json['error'] as String
          : null,
    );
  }
}

class HaloSessionState {
  const HaloSessionState({required this.speed, required this.traffic});

  final SpeedSessionState speed;
  final TrafficSessionState traffic;

  factory HaloSessionState.fromJson(Map<String, Object?> json) {
    final rawSpeed = json['speed'];
    final rawTraffic = json['traffic'];
    return HaloSessionState(
      speed: SpeedSessionState.fromJson(
        rawSpeed is Map ? rawSpeed.cast<String, Object?>() : const {},
      ),
      traffic: TrafficSessionState.fromJson(
        rawTraffic is Map ? rawTraffic.cast<String, Object?>() : const {},
      ),
    );
  }
}
