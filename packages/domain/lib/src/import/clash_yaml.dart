/// Clash-style YAML proxy list importer.
///
/// Only `proxies` entries are imported. `rules`, `dns`, `proxy-groups`,
/// `tun`, `experimental` and other sections belong to the Clash engine and are
/// deliberately ignored, because clash-halo runs sing-box and must not
/// pretend a Mihomo config is a sing-box config.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../fingerprint.dart';
import '../import/import_result.dart';
import '../models/node.dart';

ImportResult parseClashYaml(String source) {
  Object? doc;
  try {
    doc = loadYaml(source, recover: false);
  } catch (e) {
    return ImportResult(
      sourceFormat: 'clash_yaml',
      failed: [
        ImportIssue(
            kind: ImportFailureKind.decodeError, message: 'YAML 解析失败: ${_short(e)}'),
      ],
    );
  }
  if (doc is! Map) {
    return const ImportResult(
      sourceFormat: 'clash_yaml',
      failed: [
        ImportIssue(kind: ImportFailureKind.malformedLink, message: 'YAML 根节点不是映射'),
      ],
    );
  }
  final proxies = doc['proxies'] ?? doc['Proxy'] ?? doc['proxy'];
  if (proxies is! List) {
    return const ImportResult(
      sourceFormat: 'clash_yaml',
      failed: [
        ImportIssue(
            kind: ImportFailureKind.missingRequired, message: '未找到 proxies 节点列表'),
      ],
    );
  }
  final nodes = <ProxyNode>[];
  final failed = <ImportIssue>[];
  final skipped = <ImportIssue>[];
  final seen = <String>{};
  for (var i = 0; i < proxies.length; i++) {
    final entry = proxies[i];
    final line = i + 1;
    if (entry is! Map) {
      failed.add(ImportIssue(
          kind: ImportFailureKind.malformedLink, message: '节点条目不是映射', line: line));
      continue;
    }
    final map = entry.map((k, v) => MapEntry('$k', v));
    final parsed = parseClashProxy(map, line: line);
    if (parsed.node == null) {
      // JSON rather than `map.toString()`: the detail is shown in a list and
      // read by humans, and a quoted single-line form survives both.
      failed.add(parsed.issue!.withRaw(jsonEncode(map)));
      continue;
    }
    if (!seen.add(parsed.node!.fingerprint)) {
      skipped.add(ImportIssue(
          kind: ImportFailureKind.duplicate,
          message: '重复节点已跳过',
          line: line,
          note: parsed.node!.name).withRaw(jsonEncode(map)));
      continue;
    }
    nodes.add(parsed.node!);
  }
  return ImportResult(
      nodes: nodes, failed: failed, skipped: skipped, sourceFormat: 'clash_yaml');
}

String _short(Object? e) {
  final s = '$e'.split('\n').first;
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}

/// Converts one Clash `proxies[]` mapping. Kept public so the fixture tests can
/// exercise individual entries.
({ProxyNode? node, ImportIssue? issue}) parseClashProxy(
  Map<String, Object?> map, {
  int? line,
}) {
  final type = '${map['type'] ?? ''}'.toLowerCase();
  final name = '${map['name'] ?? ''}';
  final server = '${map['server'] ?? ''}';
  final port = _asInt(map['port']);
  if (server.isEmpty) {
    return (
      node: null,
      issue: ImportIssue(
          kind: ImportFailureKind.missingRequired, message: '缺少服务器', line: line),
    );
  }
  if (port == null || port <= 0 || port > 65535) {
    return (
      node: null,
      issue: ImportIssue(
          kind: ImportFailureKind.missingRequired, message: '缺少有效端口', line: line),
    );
  }
  try {
    final proto = switch (type) {
      'ss' => ProxyProtocol.shadowsocks,
      'vmess' => ProxyProtocol.vmess,
      'vless' => ProxyProtocol.vless,
      'trojan' => ProxyProtocol.trojan,
      'hysteria2' || 'hy2' => ProxyProtocol.hysteria2,
      'tuic' => ProxyProtocol.tuic,
      'socks5' || 'socks' => ProxyProtocol.socks,
      'http' => ProxyProtocol.http,
      'ssh' => ProxyProtocol.ssh,
      'anytls' => ProxyProtocol.anytls,
      _ => throw _ClashError(ImportFailureKind.unsupportedProtocol, '不支持的协议 $type', type),
    };
    final node = ProxyNode(
      id: '',
      fingerprint: '',
      name: name.isEmpty ? '$server:$port' : name,
      protocol: proto,
      server: server,
      port: port,
      secrets: NodeSecrets(
        uuid: _str(map['uuid']),
        password: _str(map['password']),
        method: _str(map['cipher']) ?? _str(map['method']),
        username: _str(map['username']),
        alterId: _asInt(map['alterId'] ?? map['alter-id']),
        flow: _str(map['flow']),
        security: _str(map['security']),
      ),
      transport: _clashTransport(map, type),
      // These four protocols are TLS by definition, so a Clash config omits
      // `tls: true` for them. Importing them as TlsKind.none produced documents
      // the core rejects outright (`initialize outbound: TLS required`), which
      // is how four Hysteria2 nodes in one real subscription became unusable
      // while looking perfectly imported.
      tls: _clashTls(map, implicitTls: _tlsIsImplicit.contains(proto)),
      source: NodeSourceKind.manual,
      extras: _clashExtras(map, type),
    );
    return (node: withIdentity(node), issue: null);
  } on _ClashError catch (e) {
    return (
      node: null,
      issue: ImportIssue(
          kind: e.kind, message: e.message, line: line, note: e.note),
    );
  }
}

class _ClashError implements Exception {
  _ClashError(this.kind, this.message, [this.note]);
  final ImportFailureKind kind;
  final String message;
  final String? note;
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  return int.tryParse('$v');
}

bool _truthy(Object? v) =>
    v == true || v == 'true' || v == 1 || v == '1';


/// First element of a Clash option that may be written as a list.
///
/// `headers: {Host: [edge.example.com]}` is the documented shape; reading the
/// list as one string produced `[edge.example.com]`, which is not a Host header.
Object? _firstValue(Object? value) => value is List ? value.firstOrNull : value;

TransportConfig _clashTransport(Map<String, Object?> map, String type) {
  final net = '${map['network'] ?? 'tcp'}'.toLowerCase();
  final wsOpts = map['ws-opts'] ?? map['ws_opts'];
  final grpcOpts = map['grpc-opts'] ?? map['grpc_opts'];
  final h2Opts = map['h2-opts'] ?? map['h2_opts'];
  Map<String, Object?> opts(Object? v) =>
      v is Map ? v.map((k, val) => MapEntry('$k', val)) : const {};
  switch (net) {
    case 'ws':
      final o = opts(wsOpts);
      final headers = o['headers'];
      return TransportConfig(
        kind: TransportKind.ws,
        path: _str(o['path']),
        host: headers is Map ? _str(_firstValue(headers['Host'] ?? headers['host'])) : null,
        earlyData: _asInt(o['max-early-data'] ?? o['max_early_data']),
      );
    case 'grpc':
      final o = opts(grpcOpts);
      return TransportConfig(
          kind: TransportKind.grpc, serviceName: _str(o['grpc-service-name'] ?? o['serviceName']));
    case 'h2':
      final o = opts(h2Opts);
      return TransportConfig(
        kind: TransportKind.http,
        path: o['path'] is List ? _str((o['path'] as List).firstOrNull) : _str(o['path']),
        host: o['host'] is List ? _str((o['host'] as List).firstOrNull) : _str(o['host']),
      );
    case 'httpupgrade':
      final o = opts(map['httpupgrade-opts'] ?? map['httpupgrade_opts']);
      return TransportConfig(
          kind: TransportKind.httpUpgrade, path: _str(o['path']), host: _str(o['host']));
    case 'http':
      // Clash Meta spells the HTTP transport `http` and keeps its options under
      // `http-opts`, with `path` and `headers` as lists.
      final o = opts(map['http-opts'] ?? map['http_opts']);
      final headers = o['headers'];
      final path = o['path'];
      return TransportConfig(
        kind: TransportKind.http,
        path: path is List ? _str(path.firstOrNull) : _str(path),
        host: headers is Map ? _str(_firstValue(headers['Host'] ?? headers['host'])) : null,
      );
    case 'tcp':
    case 'raw':
    // Xray renamed tcp to raw; Clash Meta accepts both spellings for the same
    // thing, and refusing `raw` dropped a working node.
    case '':
      return const TransportConfig();
    default:
      throw _ClashError(
          ImportFailureKind.unsupportedParameter, '不支持的传输类型 $net', net);
  }
}

/// Protocols whose TLS is not optional, and which therefore leave `tls:` out of
/// the source config.
const _tlsIsImplicit = {
  ProxyProtocol.anytls,
  ProxyProtocol.hysteria2,
  ProxyProtocol.tuic,
  ProxyProtocol.trojan,
};

/// [implicitTls] is for protocols whose TLS is not optional and which therefore
/// omit `tls: true` from the config (AnyTLS, and in practice most Trojan
/// entries). Without it a node imported from such a config would lose its
/// server name and ALPN, and the core would fail the handshake at connect time.
TlsConfig _clashTls(Map<String, Object?> map, {bool implicitTls = false}) {
  final reality = _truthy(map['reality-opts'] != null && map['reality-opts'] is Map)
      ? (map['reality-opts'] as Map)
      : null;
  if (reality != null) {
    final pbk = _str(reality['public-key'] ?? reality['public_key']);
    if (pbk == null) {
      throw _ClashError(ImportFailureKind.missingRequired, 'REALITY 缺少公钥');
    }
    return TlsConfig(
      kind: TlsKind.reality,
      serverName: _str(map['servername'] ?? map['sni']),
      insecure: _truthy(map['skip-cert-verify']),
      alpn: _alpn(map['alpn']),
      fingerprint: _str(map['client-fingerprint']),
      realityPublicKey: pbk,
      realityShortId: _str(reality['short-id'] ?? reality['short_id']),
    );
  }
  if (!implicitTls && !_truthy(map['tls'])) return const TlsConfig();
  return TlsConfig(
    kind: TlsKind.tls,
    serverName: _str(map['servername'] ?? map['sni']),
    insecure: _truthy(map['skip-cert-verify']),
    alpn: _alpn(map['alpn']),
    fingerprint: _str(map['client-fingerprint']),
  );
}

List<String> _alpn(Object? v) {
  if (v is List) return v.map((e) => '$e').toList();
  if (v is String && v.isNotEmpty) return v.split(',').map((e) => e.trim()).toList();
  return const [];
}

Map<String, Object?> _clashExtras(Map<String, Object?> map, String type) {
  const known = {
    'name', 'type', 'server', 'port', 'uuid', 'password', 'cipher', 'method',
    'username', 'alterId', 'alter-id', 'flow', 'security', 'network', 'tls',
    'sni', 'servername', 'skip-cert-verify', 'alpn', 'client-fingerprint',
    'ws-opts', 'ws_opts', 'grpc-opts', 'grpc_opts', 'h2-opts', 'h2_opts',
    'httpupgrade-opts', 'httpupgrade_opts', 'reality-opts',
  };
  final extras = <String, Object?>{
    for (final e in map.entries)
      if (!known.contains(e.key)) e.key: e.value,
  };
  return extras;
}
