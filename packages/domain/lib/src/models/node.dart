/// Canonical node model. Parsers emit this shape; the config generator and
/// storage layer consume it. Nothing here knows about sing-box specifics.
library;

enum ProxyProtocol {
  shadowsocks('shadowsocks', 'Shadowsocks'),
  vmess('vmess', 'VMess'),
  vless('vless', 'VLESS'),
  trojan('trojan', 'Trojan'),
  hysteria2('hysteria2', 'Hysteria2'),
  tuic('tuic', 'TUIC'),
  socks('socks', 'SOCKS'),
  http('http', 'HTTP'),
  ssh('ssh', 'SSH'),

  /// NaiveProxy: HTTPS proxy over HTTP/2 or HTTP/3, using a real TLS certificate
  /// and (usually) a private CA. sing-box implements it behind libcronet.dll.
  naive('naive', 'Naive'),

  /// AnyTLS: TLS-carried proxy with padding-based traffic shaping. Always TLS,
  /// so the node carries `tls.kind == TlsKind.tls` even when the source config
  /// does not spell out `tls: true`.
  anytls('anytls', 'AnyTLS');

  const ProxyProtocol(this.wire, this.label);
  final String wire;
  final String label;

  /// Whether the protocol itself always speaks UDP.
  ///
  /// True only for protocols whose wire format is QUIC and nothing else. Not
  /// the whole answer: Naive is HTTP/2 (TCP) in one node and HTTP/3 (UDP) in
  /// the next, so the decision belongs to [ProxyNode.transportProtocol], which
  /// can look at the node's own configuration.
  bool get isAlwaysUdp => this == hysteria2 || this == tuic;

  static ProxyProtocol? fromWire(String value) {
    for (final p in ProxyProtocol.values) {
      if (p.wire == value) return p;
    }
    return null;
  }
}

enum TransportKind {
  tcp('tcp', 'TCP'),
  ws('ws', 'WebSocket'),
  grpc('grpc', 'gRPC'),
  http('http', 'HTTP'),
  httpUpgrade('httpupgrade', 'HTTP Upgrade');

  const TransportKind(this.wire, this.label);
  final String wire;
  final String label;

  static TransportKind fromWire(String value) {
    for (final t in TransportKind.values) {
      if (t.wire == value) return t;
    }
    return TransportKind.tcp;
  }
}

enum TlsKind {
  none('none'),
  tls('tls'),
  reality('reality');

  const TlsKind(this.wire);
  final String wire;

  static TlsKind fromWire(String value) {
    for (final t in TlsKind.values) {
      if (t.wire == value) return t;
    }
    return TlsKind.none;
  }
}

enum NodeSourceKind {
  manual('manual'),
  subscription('subscription');

  const NodeSourceKind(this.wire);
  final String wire;

  static NodeSourceKind fromWire(String value) =>
      NodeSourceKind.values.firstWhere((s) => s.wire == value,
          orElse: () => NodeSourceKind.manual);
}

/// Credentials. Only the fields relevant to the protocol are non-null; a
/// parser must never copy a password into a field the protocol does not use.
class NodeSecrets {
  const NodeSecrets({
    this.uuid,
    this.password,
    this.method,
    this.username,
    this.alterId,
    this.flow,
    this.security,
  });

  final String? uuid;
  final String? password;
  final String? method;
  final String? username;
  final int? alterId;
  final String? flow;
  final String? security;

  Map<String, Object?> toJson() => {
        if (uuid != null) 'uuid': uuid,
        if (password != null) 'password': password,
        if (method != null) 'method': method,
        if (username != null) 'username': username,
        if (alterId != null) 'alterId': alterId,
        if (flow != null) 'flow': flow,
        if (security != null) 'security': security,
      };

  factory NodeSecrets.fromJson(Map<String, Object?> json) => NodeSecrets(
        uuid: json['uuid'] as String?,
        password: json['password'] as String?,
        method: json['method'] as String?,
        username: json['username'] as String?,
        alterId: (json['alterId'] as num?)?.toInt(),
        flow: json['flow'] as String?,
        security: json['security'] as String?,
      );

  /// Stable identity component for fingerprinting.
  String get identityKey => [
        uuid ?? '',
        password ?? '',
        method ?? '',
        username ?? '',
        alterId?.toString() ?? '',
        flow ?? '',
        security ?? '',
      ].join('\u0001');
}

class TlsConfig {
  const TlsConfig({
    this.kind = TlsKind.none,
    this.serverName,
    this.insecure = false,
    this.alpn = const [],
    this.fingerprint,
    this.realityPublicKey,
    this.realityShortId,
    this.certificatePem,
  });

  final TlsKind kind;
  final String? serverName;
  final bool insecure;
  final List<String> alpn;
  final String? fingerprint;
  final String? realityPublicKey;
  final String? realityShortId;

  /// PEM of a private root CA the server uses. Naive nodes commonly pin one;
  /// without it the handshake fails and the symptom is an immediate close.
  final String? certificatePem;

  bool get enabled => kind != TlsKind.none;

  Map<String, Object?> toJson() => {
        'kind': kind.wire,
        if (serverName != null) 'serverName': serverName,
        if (insecure) 'insecure': true,
        if (alpn.isNotEmpty) 'alpn': alpn,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (realityPublicKey != null) 'realityPublicKey': realityPublicKey,
        if (realityShortId != null) 'realityShortId': realityShortId,
        if (certificatePem != null) 'certificatePem': certificatePem,
      };

  factory TlsConfig.fromJson(Map<String, Object?> json) => TlsConfig(
        kind: TlsKind.fromWire(json['kind'] as String? ?? 'none'),
        serverName: json['serverName'] as String?,
        insecure: json['insecure'] as bool? ?? false,
        alpn: (json['alpn'] as List?)?.map((e) => '$e').toList() ?? const [],
        fingerprint: json['fingerprint'] as String?,
        realityPublicKey: json['realityPublicKey'] as String?,
        realityShortId: json['realityShortId'] as String?,
        certificatePem: json['certificatePem'] as String?,
      );

  String get identityKey => [
        kind.wire,
        serverName ?? '',
        insecure ? '1' : '0',
        alpn.join(','),
        fingerprint ?? '',
        realityPublicKey ?? '',
        certificatePem ?? '',
        realityShortId ?? '',
      ].join('\u0001');
}

class TransportConfig {
  const TransportConfig({
    this.kind = TransportKind.tcp,
    this.path,
    this.host,
    this.serviceName,
    this.headers = const {},
    this.earlyData,
  });

  final TransportKind kind;
  final String? path;
  final String? host;
  final String? serviceName;
  final Map<String, String> headers;

  /// Only meaningful for WebSocket; retained because different values are
  /// different connections.
  final int? earlyData;

  Map<String, Object?> toJson() => {
        'kind': kind.wire,
        if (path != null) 'path': path,
        if (host != null) 'host': host,
        if (serviceName != null) 'serviceName': serviceName,
        if (headers.isNotEmpty) 'headers': headers,
        if (earlyData != null) 'earlyData': earlyData,
      };

  factory TransportConfig.fromJson(Map<String, Object?> json) => TransportConfig(
        kind: TransportKind.fromWire(json['kind'] as String? ?? 'tcp'),
        path: json['path'] as String?,
        host: json['host'] as String?,
        serviceName: json['serviceName'] as String?,
        headers: (json['headers'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ??
            const {},
        earlyData: (json['earlyData'] as num?)?.toInt(),
      );

  String get identityKey => [
        kind.wire,
        path ?? '',
        host ?? '',
        serviceName ?? '',
        (headers.keys.toList()..sort()).map((k) => '$k=${headers[k]}').join('&'),
        earlyData?.toString() ?? '',
      ].join('\u0001');
}

/// Immutable proxy node as stored in the business database.
class ProxyNode {
  const ProxyNode({
    required this.id,
    required this.fingerprint,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    this.secrets = const NodeSecrets(),
    this.transport = const TransportConfig(),
    this.tls = const TlsConfig(),
    this.source = NodeSourceKind.manual,
    this.profileId,
    this.sortIndex = 0,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.extras = const {},
  });

  /// Stable id derived from [fingerprint]; never re-assigned on rename.
  final String id;

  /// Digest of the canonical connection identity (name excluded), produced by
  /// `defaultDigest`: a 96-bit FNV-1a value, not a cryptographic hash.
  final String fingerprint;
  final String name;
  final ProxyProtocol protocol;
  final String server;
  final int port;
  final NodeSecrets secrets;
  final TransportConfig transport;
  final TlsConfig tls;
  final NodeSourceKind source;
  final String? profileId;
  final int sortIndex;
  final int createdAtMs;
  final int updatedAtMs;

  /// Original fields we did not model, kept for round-trip fidelity and for
  /// surfacing unsupported parameters instead of silently dropping them.
  final Map<String, Object?> extras;

  bool get isFromSubscription => source == NodeSourceKind.subscription;

  /// `server:port`, safe to show in lists.
  String get endpoint => '$server:$port';

  /// Which transport this particular node listens on: `true` means UDP.
  ///
  /// Decided from the node's own configuration rather than its protocol name,
  /// because a protocol name is not enough. Two Naive nodes on the same server
  /// and port are different connections: HTTP/2 runs over TCP, HTTP/3 runs
  /// over QUIC/UDP, and telling them apart is the entire reason the importer
  /// keeps `naiveQuic` in extras. Probing an HTTP/3 node with a TCP handshake
  /// finds nothing — not because the node is down, but because the test asked
  /// the wrong question — and the first version of this code did exactly that
  /// to both H3 rows in the user's list.
  ///
  /// The rules, each of which has a way to be wrong if guessed:
  ///  * Hysteria2 and TUIC are QUIC-only: always UDP.
  ///  * Naive is UDP only when the node carries `naiveQuic`; otherwise HTTP/2
  ///    over TCP.
  ///  * A UDP `network` on an otherwise TCP protocol (VLESS/VMess/Trojan with
  ///    `network: udp`, e.g. QUIC or KCP) also listens on UDP.
  ///  * Everything else — Shadowsocks, SOCKS, HTTP, SSH, gRPC, WebSocket,
  ///    HTTP/2 — connects over TCP.
  bool get isUdpTransport {
    if (protocol.isAlwaysUdp) return true;
    if (protocol == ProxyProtocol.naive) return _naiveUsesQuic;
    return _networkSaysUdp;
  }

  /// `naiveQuic` is recorded by the v2rayN importer; the value is a real bool
  /// in that path, but extras round-trip through JSON, so accept the string
  /// form rather than silently treating "true" as false.
  bool get _naiveUsesQuic {
    final v2rayn = extras['v2rayn'];
    if (v2rayn is Map) {
      final q = v2rayn['naiveQuic'];
      if (q == true || q == 'true') return true;
    }
    final direct = extras['naiveQuic'];
    return direct == true || direct == 'true';
  }

  /// A transport that is explicitly a datagram protocol. `quic` and `kcp` are
  /// the two sing-box names that mean "not TCP"; WebSocket, gRPC and HTTP all
  /// ride on TCP even though they are not plain TCP.
  bool get _networkSaysUdp {
    final kind = transport.kind.wire.toLowerCase();
    if (kind == 'quic' || kind == 'kcp') return true;
    final network = extras['network'];
    if (network is String) {
      final n = network.toLowerCase();
      return n == 'quic' || n == 'kcp';
    }
    return false;
  }

  /// Returns a copy filed under [profileId], where null means "local".
  ///
  /// A dedicated method rather than `copyWith(profileId: ...)`: `copyWith`
  /// treats a null argument as "keep the current value", so moving a node back
  /// to 本地 was impossible through it and every caller that needed it had to
  /// rebuild the object by hand.
  ProxyNode movedToGroup(String? profileId, {required int nowMs}) => ProxyNode(
    id: id,
    fingerprint: fingerprint,
    name: name,
    protocol: protocol,
    server: server,
    port: port,
    secrets: secrets,
    transport: transport,
    tls: tls,
    source: profileId == null
        ? NodeSourceKind.manual
        : NodeSourceKind.subscription,
    profileId: profileId,
    sortIndex: sortIndex,
    createdAtMs: createdAtMs,
    updatedAtMs: nowMs,
    extras: extras,
  );

  ProxyNode copyWith({
    String? id,
    String? fingerprint,
    String? name,
    ProxyProtocol? protocol,
    String? server,
    int? port,
    NodeSecrets? secrets,
    TransportConfig? transport,
    TlsConfig? tls,
    NodeSourceKind? source,
    String? profileId,
    int? sortIndex,
    int? createdAtMs,
    int? updatedAtMs,
    Map<String, Object?>? extras,
  }) =>
      ProxyNode(
        id: id ?? this.id,
        fingerprint: fingerprint ?? this.fingerprint,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        server: server ?? this.server,
        port: port ?? this.port,
        secrets: secrets ?? this.secrets,
        transport: transport ?? this.transport,
        tls: tls ?? this.tls,
        source: source ?? this.source,
        profileId: profileId ?? this.profileId,
        sortIndex: sortIndex ?? this.sortIndex,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        extras: extras ?? this.extras,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'fingerprint': fingerprint,
        'name': name,
        'protocol': protocol.wire,
        'server': server,
        'port': port,
        'secrets': secrets.toJson(),
        'transport': transport.toJson(),
        'tls': tls.toJson(),
        'source': source.wire,
        if (profileId != null) 'profileId': profileId,
        'sortIndex': sortIndex,
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
        if (extras.isNotEmpty) 'extras': extras,
      };

  factory ProxyNode.fromJson(Map<String, Object?> json) {
    final protocol = ProxyProtocol.fromWire(json['protocol'] as String? ?? '');
    if (protocol == null) {
      throw FormatException('unknown protocol ${json['protocol']}');
    }
    return ProxyNode(
      id: json['id'] as String? ?? '',
      fingerprint: json['fingerprint'] as String? ?? '',
      name: json['name'] as String? ?? '',
      protocol: protocol,
      server: json['server'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      secrets: NodeSecrets.fromJson(
          (json['secrets'] as Map?)?.cast<String, Object?>() ?? const {}),
      transport: TransportConfig.fromJson(
          (json['transport'] as Map?)?.cast<String, Object?>() ?? const {}),
      tls: TlsConfig.fromJson((json['tls'] as Map?)?.cast<String, Object?>() ?? const {}),
      source: NodeSourceKind.fromWire(json['source'] as String? ?? 'manual'),
      profileId: json['profileId'] as String?,
      sortIndex: (json['sortIndex'] as num?)?.toInt() ?? 0,
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      extras: (json['extras'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  /// Log-safe description: never includes credentials.
  @override
  String toString() => 'ProxyNode(${protocol.wire} $endpoint name=$name)';
}
