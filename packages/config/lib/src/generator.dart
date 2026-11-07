/// sing-box configuration builder.
///
/// The generator emits a complete document from nodes plus app settings. It is
/// pure: no I/O, no clocks, no environment sniffing. Callers validate the
/// result with `sing-box check` before applying it.
///
/// Design rules enforced here:
///  * exactly one proxy outbound is active at a time (`route.final`), so
///    "switch node" means regenerate + apply, never a selector the UI mutates;
///  * the Clash API is bound to loopback only and is optional;
///  * unsupported nodes never reach generated output — they are filtered by
///    [partitionByCapability] before the builder is called;
///  * no credentials are logged or embedded in tags.
library;

import 'package:halo_domain/halo_domain.dart';

import 'builtin_rulesets.dart';
import 'capability.dart';
import 'rules.dart';

/// Loopback ports for the local inbound chain.
class InboundPorts {
  const InboundPorts({
    this.mixed = 7890,
    this.clashApi = 9090,
    this.enableClashApi = true,
  });

  final int mixed;
  final int clashApi;
  final bool enableClashApi;
}

/// Route/rule intent. Kept intentionally small: this is a first-version
/// feature set, not a full rule engine.
enum RouteMode {
  /// Follow generated rules, then the selected node.
  rule('rule'),

  /// All traffic through the selected node.
  global('global'),

  /// All traffic direct, node kept only for display.
  direct('direct');

  const RouteMode(this.wire);
  final String wire;

  static RouteMode fromWire(String value) =>
      RouteMode.values.firstWhere((m) => m.wire == value, orElse: () => RouteMode.rule);
}

class DnsSettings {
  const DnsSettings({
    this.enabled = true,
    this.server = 'https://223.5.5.5/dns-query',
    this.directServer = '223.5.5.5',
    this.fakeAddress = false,
  });

  final bool enabled;
  final String server;
  final String directServer;
  final bool fakeAddress;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'server': server,
        'directServer': directServer,
        'fakeAddress': fakeAddress,
      };

  factory DnsSettings.fromJson(Map<String, Object?> json) => DnsSettings(
        enabled: json['enabled'] as bool? ?? true,
        server: json['server'] as String? ?? 'https://223.5.5.5/dns-query',
        directServer: json['directServer'] as String? ?? '223.5.5.5',
        fakeAddress: json['fakeAddress'] as bool? ?? false,
      );
}

class TunSettings {
  const TunSettings({
    this.enabled = false,
    this.stack = 'mixed',
    this.mtu = 9000,
    this.autoRoute = true,
    this.strictRoute = true,
    this.interfaceName = 'halo-tun',
  });

  final bool enabled;
  final String stack;
  final int mtu;
  final bool autoRoute;
  final bool strictRoute;
  final String interfaceName;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'stack': stack,
        'mtu': mtu,
        'autoRoute': autoRoute,
        'strictRoute': strictRoute,
        'interfaceName': interfaceName,
      };

  factory TunSettings.fromJson(Map<String, Object?> json) => TunSettings(
        enabled: json['enabled'] as bool? ?? false,
        stack: json['stack'] as String? ?? 'mixed',
        mtu: (json['mtu'] as num?)?.toInt() ?? 9000,
        autoRoute: json['autoRoute'] as bool? ?? true,
        strictRoute: json['strictRoute'] as bool? ?? true,
        interfaceName: json['interfaceName'] as String? ?? 'halo-tun',
      );
}

/// Everything the generator needs. The host persists this, not the UI.
class ConfigRequest {
  const ConfigRequest({
    required this.node,
    this.mode = RouteMode.rule,
    this.ports = const InboundPorts(),
    this.dns = const DnsSettings(),
    this.tun = const TunSettings(),
    this.logLevel = 'warn',
    this.testPort,
    this.rules = const [],
  });

  final ProxyNode node;
  final RouteMode mode;
  final InboundPorts ports;
  final DnsSettings dns;
  final TunSettings tun;
  final String logLevel;

  /// When set, an isolated test inbound is added for speed testing so the
  /// user's active connection is untouched.
  final int? testPort;

  /// User rules, in the order they were arranged.
  ///
  /// Only used by [RouteMode.rule]: 全局 and 直连 mean "ignore the rule list",
  /// and honouring them there would make the mode selector lie about what it
  /// does.
  final List<RoutingRule> rules;
}

class GeneratedConfig {
  const GeneratedConfig({
    required this.document,
    required this.mixedPort,
    required this.clashApiPort,
    this.testPort,
    this.tunInbound = false,
  });

  final Map<String, Object?> document;
  final int mixedPort;
  final int? clashApiPort;
  final int? testPort;
  final bool tunInbound;

  String toJsonString() => encodePrettyJson(document);
}

/// Candidate configuration plus the log-safe summary used for diagnostics.
class ConfigBuildResult {
  const ConfigBuildResult({this.config, this.issues = const []});

  final GeneratedConfig? config;
  final List<CapabilityIssue> issues;

  bool get ok => config != null && issues.isEmpty;
}

/// Builds the document for exactly one active node.
ConfigBuildResult buildConfig(ConfigRequest request, CoreCapabilities caps) {
  final check = checkNode(request.node, caps);
  if (!check.ok) {
    return ConfigBuildResult(issues: check.issues);
  }
  final outbounds = <Map<String, Object?>>[
    _proxyOutbound(request.node),
    {'type': 'direct', 'tag': 'direct'},
    {'type': 'block', 'tag': 'block'},
  ];
  final inbounds = <Map<String, Object?>>[];
  if (request.tun.enabled) {
    inbounds.add({
      'type': 'tun',
      'tag': 'tun-in',
      'interface_name': request.tun.interfaceName,
      'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
      'mtu': request.tun.mtu,
      'auto_route': request.tun.autoRoute,
      'strict_route': request.tun.strictRoute,
      'stack': request.tun.stack,
    });
  }
  inbounds.add({
    'type': 'mixed',
    'tag': 'mixed-in',
    'listen': '127.0.0.1',
    'listen_port': request.ports.mixed,
    'set_system_proxy': false,
  });
  if (request.testPort != null) {
    inbounds.add({
      'type': 'http',
      'tag': 'test-in',
      'listen': '127.0.0.1',
      'listen_port': request.testPort,
    });
  }

  final routeFinal = switch (request.mode) {
    RouteMode.global || RouteMode.rule => 'proxy',
    RouteMode.direct => 'direct',
  };

  final doc = <String, Object?>{
    'log': {
      'level': request.logLevel,
      'timestamp': true,
      'output': 'halo-core.log',
    },
    'inbounds': inbounds,
    'outbounds': outbounds,
    'route': {
      // Only the rule sets a rule actually references are embedded. Shipping all
      // 18 would put ~640 KB of JSON into every config — including the ones for
      // 全局 and 直连, where no rule runs at all — and each apply writes and
      // re-validates that document.
      if (_ruleSetsFor(request) case final sets when sets.isNotEmpty)
        'rule_set': sets,
      'rules': _routeRules(request),
      'final': routeFinal,
      'auto_detect_interface': !request.tun.enabled,
    },
  };

  if (request.dns.enabled && request.mode != RouteMode.direct) {
    // sing-box 1.14 removed the legacy `address` DNS server form; each server
    // must declare a `type`. A domain resolver also has to be named
    // explicitly or dialing a domain outbound fails validation.
    doc['dns'] = {
      'servers': [
        _dnsServer(tag: 'remote', url: request.dns.server, detour: 'proxy'),
        // Deliberately no `detour`: sing-box 1.13+ rejects a detour pointing at
        // an empty direct outbound ("detour to an empty direct outbound makes
        // no sense"). That check runs when the DNS transport starts, not in
        // `sing-box check`, so the config validated and then the core aborted
        // on startup — every generated config failed to run. This resolver is
        // kept on the direct path by the ip rule in [_routeRules] instead.
        _dnsServer(tag: 'local', url: request.dns.directServer),
      ],
      'final': 'remote',
    };
    (doc['route'] as Map)['default_domain_resolver'] = {'server': 'local'};
  }

  final experimental = <String, Object?>{
    'cache_file': {'enabled': true, 'path': 'halo-cache.db'},
  };
  if (request.ports.enableClashApi) {
    experimental['clash_api'] = {
      'external_controller': '127.0.0.1:${request.ports.clashApi}',
      'default_mode': request.mode.wire,
    };
  }
  doc['experimental'] = experimental;

  return ConfigBuildResult(
    config: GeneratedConfig(
      document: doc,
      mixedPort: request.ports.mixed,
      clashApiPort: request.ports.enableClashApi ? request.ports.clashApi : null,
      testPort: request.testPort,
      tunInbound: request.tun.enabled,
    ),
  );
}

/// The `route.rule_set` entries for the rule sets [ConfigRequest.rules] uses.
///
/// Deduplicated by tag, in first-reference order, so a rule list that mentions
/// the same set twice does not declare it twice — sing-box rejects duplicate
/// tags, and the error it gives ("duplicate rule-set tag") does not say which
/// rule caused it.
List<Map<String, Object?>> _ruleSetsFor(ConfigRequest request) {
  if (request.mode != RouteMode.rule) return const [];
  final seen = <String>{};
  final out = <Map<String, Object?>>[];
  for (final rule in request.rules) {
    if (!rule.enabled || rule.kind != RuleKind.ruleSet) continue;
    final tag = rule.value.trim();
    if (tag.isEmpty || !seen.add(tag)) continue;
    final set = builtinRuleSetByTag(tag);
    // A tag the catalogue does not know is dropped here rather than emitted:
    // `validateRuleValue` already refuses it on input, and a stale stored rule
    // must not make every later apply fail with a core-side rule-set error.
    if (set == null) continue;
    out.add({
      'tag': set.tag,
      'type': 'inline',
      'rules': decodeRuleSetPayload(set),
    });
  }
  return out;
}

List<Map<String, Object?>> _routeRules(ConfigRequest request) {
  final rules = <Map<String, Object?>>[];
  // The local resolver carries no detour (see buildConfig), so its own traffic
  // must be pinned to the direct outbound by destination. Routing it through
  // the proxy would make the proxy resolve its own server name.
  if (request.dns.enabled) {
    final resolver = _ipv4(request.dns.directServer);
    if (resolver != null) {
      rules.add({
        'ip_cidr': ['$resolver/32'],
        'outbound': 'direct',
      });
    }
  }
  switch (request.mode) {
    case RouteMode.direct:
    case RouteMode.global:
      return rules;
    case RouteMode.rule:
      rules.addAll(const [
        // Keep local/private traffic off the proxy by default.
        {'ip_is_private': true, 'outbound': 'direct'},
        {'protocol': 'dns', 'outbound': 'direct'},
        {'clash_mode': 'direct', 'outbound': 'direct'},
      ]);
      // User rules sit after the non-negotiables above and before the final
      // outbound. They must come after the private-network rule: putting a
      // user rule first would let a broad "direct everything" entry shadow
      // the LAN guard, and the failure mode (local traffic through the proxy,
      // which cannot reach 192.168.x.x) looks like the proxy is broken.
      for (final rule in request.rules) {
        final document = ruleToDocument(rule);
        if (document != null) rules.add(document);
      }
      return rules;
  }
}

final _ipv4Pattern = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

/// Returns [value] when it is a bare IPv4 literal, so it can be used in an
/// `ip_cidr` rule. Hostnames and IPv6 are left alone.
String? _ipv4(String value) {
  final trimmed = value.trim();
  final match = _ipv4Pattern.firstMatch(trimmed);
  if (match == null) return null;
  for (var i = 1; i <= 4; i++) {
    if (int.parse(match.group(i)!) > 255) return null;
  }
  return trimmed;
}

/// Builds a modern `dns.servers` entry from a URL-ish setting.
///
/// [detour] is optional: only outbounds that can actually dial may be named
/// here, and a plain `direct` outbound is not one of them on sing-box 1.13+.
Map<String, Object?> _dnsServer({
  required String tag,
  required String url,
  String? detour,
}) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    return {
      'type': 'local',
      'tag': tag,
      if (detour != null) 'detour': detour,
    };
  }
  final lower = trimmed.toLowerCase();
  final type = switch (lower.split(':').first) {
    'https' => 'https',
    'http' => 'http',
    'tls' => 'tls',
    'quic' || 'h3' => 'quic',
    'dhcp' => 'dhcp',
    _ => 'udp',
  };
  final endpoint = type == 'https' ? Uri.tryParse(trimmed) : null;
  final isDohUrl = endpoint != null && endpoint.hasAuthority && endpoint.host.isNotEmpty;
  return {
    'type': type,
    'tag': tag,
    'server': isDohUrl ? endpoint.host : trimmed,
    if (isDohUrl && endpoint.hasPort) 'server_port': endpoint.port,
    if (isDohUrl && endpoint.path.isNotEmpty) 'path': endpoint.path,
    if (detour != null) 'detour': detour,
  };
}

Map<String, Object?> _proxyOutbound(ProxyNode node) {
  final common = <String, Object?>{
    'type': node.protocol.wire,
    'tag': 'proxy',
    'server': node.server,
    'server_port': node.port,
  };
  switch (node.protocol) {
    case ProxyProtocol.shadowsocks:
      common['method'] = node.secrets.method;
      common['password'] = node.secrets.password;
    case ProxyProtocol.vmess:
      common['uuid'] = node.secrets.uuid;
      common['alter_id'] = node.secrets.alterId ?? 0;
      if (node.secrets.security != null && node.secrets.security != 'auto') {
        common['security'] = node.secrets.security;
      }
    case ProxyProtocol.vless:
      common['uuid'] = node.secrets.uuid;
      if ((node.secrets.flow ?? '').isNotEmpty) common['flow'] = node.secrets.flow;
    case ProxyProtocol.trojan:
      common['password'] = node.secrets.password;
    case ProxyProtocol.hysteria2:
      common['password'] = node.secrets.password;
      final obfs = node.extras['obfs'];
      if (obfs is String && obfs.isNotEmpty) {
        common['obfs'] = {
          'type': obfs,
          if (node.extras['obfsPassword'] != null)
            'password': node.extras['obfsPassword'],
        };
      }
    case ProxyProtocol.tuic:
      common['uuid'] = node.secrets.uuid;
      common['password'] = node.secrets.password;
    case ProxyProtocol.socks:
    case ProxyProtocol.http:
      if ((node.secrets.username ?? '').isNotEmpty) {
        common['username'] = node.secrets.username;
      }
      if ((node.secrets.password ?? '').isNotEmpty) {
        common['password'] = node.secrets.password;
      }
    case ProxyProtocol.ssh:
      break;
    case ProxyProtocol.anytls:
      // Password only: the TLS block below carries server_name/alpn/utls, and
      // sing-box takes anytls' padding configuration from the protocol defaults.
      common['password'] = node.secrets.password;
    case ProxyProtocol.naive:
      // Naive is an HTTPS proxy: credentials are basic auth, and HTTP/3 is a
      // per-outbound switch rather than a separate transport.
      if ((node.secrets.username ?? '').isNotEmpty) {
        common['username'] = node.secrets.username;
      }
      common['password'] = node.secrets.password;
      if (node.isUdpTransport) common['quic'] = true;
  }
  final tls = _tlsBlock(node);
  if (tls != null) common['tls'] = tls;
  final transport = _transportBlock(node);
  if (transport != null) common['transport'] = transport;
  return common;
}

Map<String, Object?>? _tlsBlock(ProxyNode node) {
  switch (node.tls.kind) {
    case TlsKind.none:
      return null;
    case TlsKind.tls:
      final block = <String, Object?>{
        'enabled': true,
        if ((node.tls.serverName ?? '').isNotEmpty) 'server_name': node.tls.serverName,
        if (node.tls.insecure) 'insecure': true,
        if (node.tls.alpn.isNotEmpty) 'alpn': node.tls.alpn,
      };
      if ((node.tls.fingerprint ?? '').isNotEmpty) {
        block['utls'] = {'enabled': true, 'fingerprint': node.tls.fingerprint};
      }
      // Pinned private CA (Naive servers usually present a self-signed root).
      // Inlined rather than referenced: the generator is pure and cannot write
      // a certificate file, and `sing-box check` accepts `certificate` inline.
      final pem = node.tls.certificatePem;
      if (pem != null && pem.trim().isNotEmpty) {
        block['certificate'] = pem.trim();
      }
      return block;
    case TlsKind.reality:
      return {
        'enabled': true,
        if ((node.tls.serverName ?? '').isNotEmpty) 'server_name': node.tls.serverName,
        if (node.tls.insecure) 'insecure': true,
        if (node.tls.alpn.isNotEmpty) 'alpn': node.tls.alpn,
        if ((node.tls.fingerprint ?? '').isNotEmpty)
          'utls': {'enabled': true, 'fingerprint': node.tls.fingerprint},
        'reality': {
          'enabled': true,
          'public_key': node.tls.realityPublicKey,
          if ((node.tls.realityShortId ?? '').isNotEmpty)
            'short_id': node.tls.realityShortId,
        },
      };
  }
}

Map<String, Object?>? _transportBlock(ProxyNode node) {
  final t = node.transport;
  switch (t.kind) {
    case TransportKind.tcp:
      return null;
    case TransportKind.ws:
      return {
        'type': 'ws',
        if ((t.path ?? '').isNotEmpty) 'path': t.path,
        if ((t.host ?? '').isNotEmpty) 'headers': {'Host': t.host},
        if (t.earlyData != null && t.earlyData! > 0) 'max_early_data': t.earlyData,
      };
    case TransportKind.grpc:
      return {
        'type': 'grpc',
        if ((t.serviceName ?? '').isNotEmpty) 'service_name': t.serviceName,
      };
    case TransportKind.http:
      return {
        'type': 'http',
        if ((t.path ?? '').isNotEmpty) 'path': t.path,
        if ((t.host ?? '').isNotEmpty) 'host': [t.host],
      };
    case TransportKind.httpUpgrade:
      return {
        'type': 'httpupgrade',
        if ((t.path ?? '').isNotEmpty) 'path': t.path,
        if ((t.host ?? '').isNotEmpty) 'host': t.host,
      };
  }
}

/// Deterministic, indented JSON encoding (2 spaces) so that generated files
/// are diffable and their hash is stable across platforms.
String encodePrettyJson(Object? value, {int indent = 0}) {
  final pad = '  ' * indent;
  final childPad = '  ' * (indent + 1);
  if (value == null) return 'null';
  if (value is bool || value is num) return '$value';
  if (value is String) return _encodeString(value);
  if (value is List) {
    if (value.isEmpty) return '[]';
    final items = value.map((e) => '$childPad${encodePrettyJson(e, indent: indent + 1)}');
    return '[\n${items.join(',\n')}\n$pad]';
  }
  if (value is Map) {
    if (value.isEmpty) return '{}';
    final keys = value.keys.map((k) => '$k').toList()..sort();
    final entries = keys.map((k) =>
        '$childPad${_encodeString(k)}: ${encodePrettyJson(value[k], indent: indent + 1)}');
    return '{\n${entries.join(',\n')}\n$pad}';
  }
  return _encodeString('$value');
}

String _encodeString(String s) {
  final buf = StringBuffer('"');
  for (final unit in s.codeUnits) {
    switch (unit) {
      case 0x22:
        buf.write(r'\"');
      case 0x5C:
        buf.write(r'\\');
      case 0x0A:
        buf.write(r'\n');
      case 0x0D:
        buf.write(r'\r');
      case 0x09:
        buf.write(r'\t');
      default:
        if (unit < 0x20) {
          buf.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          buf.writeCharCode(unit);
        }
    }
  }
  buf.write('"');
  return buf.toString();
}
