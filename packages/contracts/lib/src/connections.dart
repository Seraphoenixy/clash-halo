/// One live connection, as the host reports it from sing-box's Clash API.
///
/// The host flattens the API's nested `metadata` into these fields, so the UI
/// never has to know that `host` lives under `metadata` while `rule` does not.
/// Keeping the wire coupling in one small model is what makes "only verified
/// Clash API capabilities" true in practice rather than in comment.
class LiveConnection {
  const LiveConnection({
    required this.id,
    required this.host,
    this.network = '',
    this.type = '',
    this.rule = '',
    this.rulePayload = '',
    this.chains = const [],
    this.upload = 0,
    this.download = 0,
    this.start = '',
    this.process = '',
    this.processPath = '',
    this.sourceIp = '',
    this.destinationIp = '',
  });

  final String id;

  /// Requested host, or the destination IP when the connection was opened
  /// against an address literal.
  final String host;
  final String network;
  final String type;
  final String rule;
  final String rulePayload;

  /// Outbound chain, innermost first, ending with the final action (DIRECT or
  /// the node name).
  final List<String> chains;
  final int upload;
  final int download;

  /// RFC3339 timestamp as the core reported it. Kept raw so a clock format the
  /// UI does not understand still round-trips instead of becoming "1970".
  final String start;
  final String process;
  final String processPath;
  final String sourceIp;
  final String destinationIp;

  static LiveConnection fromJson(Map<String, Object?> json) => LiveConnection(
    id: json['id'] as String? ?? '',
    host: json['host'] as String? ?? '',
    network: json['network'] as String? ?? '',
    type: json['type'] as String? ?? '',
    rule: json['rule'] as String? ?? '',
    rulePayload: json['rulePayload'] as String? ?? '',
    chains: (json['chains'] as List?)?.whereType<String>().toList() ?? const [],
    upload: (json['upload'] as num?)?.toInt() ?? 0,
    download: (json['download'] as num?)?.toInt() ?? 0,
    start: json['start'] as String? ?? '',
    process: json['process'] as String? ?? '',
    processPath: json['processPath'] as String? ?? '',
    sourceIp: json['sourceIp'] as String? ?? '',
    destinationIp: json['destinationIp'] as String? ?? '',
  );

  /// How long the connection has been open, or null when the timestamp is
  /// missing or unparseable.
  ///
  /// The core reports nanoseconds (`...T08:00:00.123456789+08:00`), which
  /// `DateTime.parse` accepts; anything it rejects becomes null rather than
  /// throwing on a page that refreshes every second.
  Duration? ageFrom(DateTime now) {
    final started = parseStart();
    if (started == null) return null;
    final age = now.difference(started);
    return age.isNegative ? Duration.zero : age;
  }

  DateTime? parseStart() {
    if (start.isEmpty) return null;
    // Trim sub-microsecond digits: Dart tolerates them in most builds, but the
    // trimming is free and removes the whole class of parse failures.
    final match = RegExp(r'^([^.]+)\.(\d+)').firstMatch(start);
    final normalised = match == null
        ? start
        : '${match.group(1)}.${match.group(2)!.substring(0, match.group(2)!.length.clamp(0, 6))}';
    return DateTime.tryParse(normalised);
  }
}

/// Everything `connections.list` returns.
class ConnectionsSnapshot {
  const ConnectionsSnapshot({
    this.connections = const [],
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.memory = 0,
    this.controller = '',
  });

  final List<LiveConnection> connections;
  final int uploadTotal;
  final int downloadTotal;
  final int memory;

  /// Where the numbers came from. Empty means the host could not read a
  /// controller address, which is the difference between "no connections" and
  /// "we cannot see them".
  final String controller;

  int get uploadRateBytes => uploadTotal;

  static ConnectionsSnapshot fromJson(Map<String, Object?> json) =>
      ConnectionsSnapshot(
        connections: (json['connections'] as List? ?? const [])
            // Explicit type argument: strict-raw-types rejects a bare `Map` here,
            // and `Map<Object?, Object?>` is also the honest type — the array is
            // decoded untested and each element is validated by fromJson.
            .whereType<Map<Object?, Object?>>()
            .map((e) => LiveConnection.fromJson(e.cast<String, Object?>()))
            .toList(),
        uploadTotal: (json['uploadTotal'] as num?)?.toInt() ?? 0,
        downloadTotal: (json['downloadTotal'] as num?)?.toInt() ?? 0,
        memory: (json['memory'] as num?)?.toInt() ?? 0,
        controller: json['controller'] as String? ?? '',
      );
}
