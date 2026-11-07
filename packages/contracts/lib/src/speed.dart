/// Speed-test result model. TCP reachability, proxy latency and download
/// throughput are separate metrics and are never collapsed into one number.
library;

enum SpeedMetric {
  /// Plain TCP connect to the node endpoint, no proxy involved.
  tcp('tcp'),

  /// UDP reachability through the node, measured with a datagram exchange.
  ///
  /// Separate from [tcp] rather than a variant of it: TCP reachability says
  /// nothing about whether the node forwards datagrams, and a node that
  /// accepts TCP while dropping UDP breaks DNS and every QUIC connection
  /// while looking perfectly healthy in a TCP-only list.
  udp('udp'),

  /// HTTP latency through a dedicated test inbound, isolated from the
  /// user's active connection.
  proxyLatency('proxy_latency'),

  /// Byte throughput through the dedicated test inbound.
  download('download');

  const SpeedMetric(this.wire);
  final String wire;

  /// Whether this metric measures a delay in milliseconds rather than a rate
  /// or a reachability flag.
  bool get isDelay => this == tcp || this == udp || this == proxyLatency;

  /// Whether this metric is a plain reachability check, cheap enough to run
  /// before anything that starts a core.
  bool get isReachability => this == tcp || this == udp;

  static SpeedMetric fromWire(String value) =>
      SpeedMetric.values.firstWhere((m) => m.wire == value,
          orElse: () => SpeedMetric.tcp);
}

enum SpeedStatus {
  pending('pending'),
  running('running'),
  ok('ok'),
  failed('failed'),
  canceled('canceled'),
  skipped('skipped'),

  /// The probe cannot say anything about this node — e.g. a TCP handshake
  /// against a QUIC-only node. Distinct from [failed] because a check that
  /// does not apply must never be read as a verdict on the node.
  notApplicable('not_applicable');

  const SpeedStatus(this.wire);
  final String wire;

  static SpeedStatus fromWire(String value) =>
      SpeedStatus.values.firstWhere((s) => s.wire == value,
          orElse: () => SpeedStatus.pending);

  /// True once no further updates are expected for this node.
  bool get isTerminal =>
      this == SpeedStatus.ok || this == SpeedStatus.failed ||
      this == SpeedStatus.canceled || this == SpeedStatus.skipped ||
      this == SpeedStatus.notApplicable;
}

class SpeedResult {
  const SpeedResult({
    required this.nodeId,
    required this.metric,
    required this.status,
    this.valueMs,
    this.bytesPerSecond,
    this.bytesTransferred,
    this.errorCode,
    this.errorMessage,
    this.atMs = 0,
  });

  final String nodeId;
  final SpeedMetric metric;
  final SpeedStatus status;

  /// Milliseconds for [SpeedMetric.tcp], [SpeedMetric.udp] and
  /// [SpeedMetric.proxyLatency].
  final int? valueMs;

  /// Bytes per second for [SpeedMetric.download].
  final int? bytesPerSecond;
  final int? bytesTransferred;
  final String? errorCode;
  final String? errorMessage;
  final int atMs;

  /// [fallbackMetric] is used when the payload omits `metric`.
  ///
  /// The default is [SpeedMetric.tcp] for a bare decode, but a caller that
  /// already knows what it asked for must pass it: a payload without a metric
  /// is a legacy/partial one, and guessing `tcp` would file a latency reading
  /// under reachability.
  factory SpeedResult.fromJson(
    Map<String, Object?> json, {
    SpeedMetric fallbackMetric = SpeedMetric.tcp,
  }) =>
      SpeedResult(
        nodeId: json['nodeId'] as String? ?? '',
        metric: json['metric'] is String
            ? SpeedMetric.fromWire(json['metric'] as String)
            : fallbackMetric,
        status: SpeedStatus.fromWire(json['status'] as String? ?? 'pending'),
        valueMs: (json['valueMs'] as num?)?.toInt(),
        bytesPerSecond: (json['bytesPerSecond'] as num?)?.toInt(),
        bytesTransferred: (json['bytesTransferred'] as num?)?.toInt(),
        errorCode: json['errorCode'] as String?,
        errorMessage: json['errorMessage'] as String?,
        atMs: (json['atMs'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'nodeId': nodeId,
        'metric': metric.wire,
        'status': status.wire,
        'valueMs': valueMs,
        'bytesPerSecond': bytesPerSecond,
        'bytesTransferred': bytesTransferred,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
        'atMs': atMs,
      };

  /// Compact label used by the node list, e.g. `182 ms` or `4.2 MB/s`.
  String get label {
    switch (status) {
      case SpeedStatus.ok:
        if (metric == SpeedMetric.download) {
          final bps = bytesPerSecond ?? 0;
          if (bps >= 1024 * 1024) {
            return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
          }
          if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
          return '$bps B/s';
        }
        return '${valueMs ?? 0} ms';
      case SpeedStatus.failed:
        return '失败';
      case SpeedStatus.canceled:
        return '已取消';
      case SpeedStatus.skipped:
        return '跳过';
      case SpeedStatus.notApplicable:
        return '不适用';
      case SpeedStatus.running:
        return '测试中…';
      case SpeedStatus.pending:
        return '等待';
    }
  }
}
