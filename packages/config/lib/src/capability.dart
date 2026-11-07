/// Protocol/feature capability matrix for the pinned sing-box version.
///
/// A node that parses but whose parameters are not representable in the
/// current core build must be rejected with a typed reason, never silently
/// degraded. The matrix is deliberately explicit rather than inferred from
/// "the protocol name is the same".
library;

import 'package:halo_domain/halo_domain.dart';

/// Core build feature flags. Kept as plain data so the host can report them
/// and the UI can show an "unsupported" badge with a reason.
class CoreCapabilities {
  const CoreCapabilities({
    required this.version,
    this.protocols = _defaultProtocols,
    this.transports = _defaultTransports,
    this.tlsKinds = _defaultTls,
    this.features = const {},
    this.tunSupported = false,
    this.tunRequiresElevation = false,
  });

  final String version;
  final Set<ProxyProtocol> protocols;
  final Set<TransportKind> transports;
  final Set<TlsKind> tlsKinds;

  /// Optional named features, e.g. `shadow-tls`, `hysteria-obfs`.
  final Set<String> features;

  /// Whether this build emits a TUN inbound the core accepts.
  ///
  /// Verified for the pinned Windows build: `sing-box 1.14.4 check` accepts
  /// the document produced by `applyTunInbound`. This says nothing about
  /// whether the interface can actually be opened — see
  /// [tunRequiresElevation].
  final bool tunSupported;

  /// Whether activating TUN needs an elevated process.
  ///
  /// Kept separate from [tunSupported] on purpose: creating the adapter on
  /// Windows needs administrator rights, so generation being supported must
  /// never be reported as "TUN works for free".
  final bool tunRequiresElevation;

  static const _defaultProtocols = {
    ProxyProtocol.shadowsocks,
    ProxyProtocol.vmess,
    ProxyProtocol.vless,
    ProxyProtocol.trojan,
    ProxyProtocol.hysteria2,
    ProxyProtocol.tuic,
    ProxyProtocol.socks,
    ProxyProtocol.http,
    // Naive is supported by the pinned core, but only when libcronet.dll sits
    // next to sing-box.exe; the build copies it. Without the DLL the core exits
    // with "cronet: library not found", which is reported as a startup failure
    // rather than a capability gap.
    ProxyProtocol.naive,
    // AnyTLS is an outbound in the pinned core (added in sing-box 1.12) and
    // `sing-box 1.14.4 check` accepts the document this generator emits.
    ProxyProtocol.anytls,
  };

  static const _defaultTransports = {
    TransportKind.tcp,
    TransportKind.ws,
    TransportKind.grpc,
    TransportKind.http,
    TransportKind.httpUpgrade,
  };

  static const _defaultTls = {TlsKind.none, TlsKind.tls, TlsKind.reality};

  /// sing-box 1.14.4 as shipped in `prototype/bin/sing-box.exe`.
  ///
  /// TUN generation is verified against this exact binary; activation still
  /// requires an elevated process, so the elevation caveat stays explicit.
  static const singbox114 = CoreCapabilities(
    version: '1.14.4',
    features: {'utls', 'reality', 'hysteria2-obfs', 'tuic', 'httpupgrade'},
    tunSupported: true,
    tunRequiresElevation: true,
  );
}

/// Why a node cannot be used with the current core.
class CapabilityIssue {
  const CapabilityIssue({
    required this.code,
    required this.message,
    this.field,
  });

  final String code;
  final String message;
  final String? field;

  @override
  String toString() => 'CapabilityIssue($code: $message)';
}

/// Result of checking one node against a capability set.
class CapabilityCheck {
  const CapabilityCheck({this.issues = const []});

  final List<CapabilityIssue> issues;

  bool get ok => issues.isEmpty;

  String get reason => issues.map((e) => e.message).join('；');

  static const okResult = CapabilityCheck();
}

const _blockedUnsupported = 'unsupported';

/// Checks a single node. Returns every issue, not just the first, so the UI
/// can list them.
CapabilityCheck checkNode(ProxyNode node, CoreCapabilities caps) {
  final issues = <CapabilityIssue>[];
  if (!caps.protocols.contains(node.protocol)) {
    issues.add(CapabilityIssue(
      code: _blockedUnsupported,
      message: '内核 ${caps.version} 不支持协议 ${node.protocol.label}',
      field: 'protocol',
    ));
  }
  if (!caps.transports.contains(node.transport.kind)) {
    issues.add(CapabilityIssue(
      code: _blockedUnsupported,
      message: '内核 ${caps.version} 不支持传输 ${node.transport.kind.label}',
      field: 'transport',
    ));
  }
  if (!caps.tlsKinds.contains(node.tls.kind)) {
    issues.add(CapabilityIssue(
      code: _blockedUnsupported,
      message: '内核 ${caps.version} 不支持 TLS 方式 ${node.tls.kind.wire}',
      field: 'tls',
    ));
  }
  // Protocol-specific parameter checks.
  switch (node.protocol) {
    case ProxyProtocol.shadowsocks:
      if ((node.secrets.method ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'Shadowsocks 缺少加密方式', field: 'method'));
      }
      if ((node.secrets.password ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'Shadowsocks 缺少密码', field: 'password'));
      }
    case ProxyProtocol.vmess:
      if ((node.secrets.uuid ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'VMess 缺少 UUID', field: 'uuid'));
      }
    case ProxyProtocol.vless:
      if ((node.secrets.uuid ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'VLESS 缺少 UUID', field: 'uuid'));
      }
      if (node.tls.kind == TlsKind.reality && (node.tls.realityPublicKey ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required',
            message: 'REALITY 缺少公钥',
            field: 'realityPublicKey'));
      }
    case ProxyProtocol.trojan:
      if ((node.secrets.password ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'Trojan 缺少密码', field: 'password'));
      }
    case ProxyProtocol.hysteria2:
      if ((node.secrets.password ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'Hysteria2 缺少密码', field: 'password'));
      }
    case ProxyProtocol.tuic:
      if ((node.secrets.uuid ?? '').isEmpty || (node.secrets.password ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'TUIC 缺少 UUID 或密码', field: 'uuid'));
      }
    case ProxyProtocol.naive:
      // Naive needs a password; the username is optional in the protocol but
      // every deployment seen so far sets one.
      if ((node.secrets.password ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'Naive 缺少密码', field: 'password'));
      }
    case ProxyProtocol.anytls:
      // AnyTLS carries its TLS certificate pinning and password in the
      // outbound; a node without a password cannot authenticate at all.
      if ((node.secrets.password ?? '').isEmpty) {
        issues.add(const CapabilityIssue(
            code: 'missing_required', message: 'AnyTLS 缺少密码', field: 'password'));
      }
    case ProxyProtocol.socks:
    case ProxyProtocol.http:
    case ProxyProtocol.ssh:
      break;
  }
  // Importers mark parameters they could not model in transport.headers so a
  // node is blocked instead of being silently downgraded to another transport.
  final unsupported = node.transport.headers['unsupported_transport'];
  if (unsupported != null) {
    issues.add(CapabilityIssue(
      code: _blockedUnsupported,
      message: '不支持的传输参数 $unsupported',
      field: 'transport',
    ));
  }
  if (node.port <= 0 || node.port > 65535) {
    issues.add(const CapabilityIssue(
        code: 'missing_required', message: '端口无效', field: 'port'));
  }
  if (node.server.trim().isEmpty) {
    issues.add(const CapabilityIssue(
        code: 'missing_required', message: '服务器地址为空', field: 'server'));
  }
  return CapabilityCheck(issues: issues);
}

/// Splits nodes into usable and rejected ones, preserving input order.
({List<ProxyNode> usable, Map<String, CapabilityCheck> rejected}) partitionByCapability(
  Iterable<ProxyNode> nodes,
  CoreCapabilities caps,
) {
  final usable = <ProxyNode>[];
  final rejected = <String, CapabilityCheck>{};
  for (final node in nodes) {
    final check = checkNode(node, caps);
    if (check.ok) {
      usable.add(node);
    } else {
      rejected[node.id] = check;
    }
  }
  return (usable: usable, rejected: rejected);
}
