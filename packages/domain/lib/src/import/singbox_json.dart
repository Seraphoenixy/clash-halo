/// sing-box JSON importer.
///
/// A full sing-box document is not a user running config. We extract only the
/// `outbounds` that represent proxy servers, ignore `direct`/`block`/`dns`
/// system outbounds, and report everything else as skipped. Route, DNS, inbound
/// and experimental sections are never adopted.
library;

import 'dart:convert';

import '../fingerprint.dart';
import '../import/import_result.dart';
import '../models/node.dart';

ImportResult parseSingboxJson(String source) {
  Object? doc;
  try {
    doc = jsonDecode(source);
  } on FormatException catch (e) {
    return ImportResult(
      sourceFormat: 'singbox_json',
      failed: [
        ImportIssue(kind: ImportFailureKind.decodeError, message: 'JSON 解析失败: ${e.message}'),
      ],
    );
  }
  if (doc is! Map) {
    return const ImportResult(
      sourceFormat: 'singbox_json',
      failed: [
        ImportIssue(kind: ImportFailureKind.malformedLink, message: 'JSON 根节点不是对象'),
      ],
    );
  }
  final map = doc.cast<String, Object?>();
  final outbounds = map['outbounds'];
  if (outbounds is! List) {
    return const ImportResult(
      sourceFormat: 'singbox_json',
      failed: [
        ImportIssue(kind: ImportFailureKind.missingRequired, message: '未找到 outbounds'),
      ],
    );
  }
  final nodes = <ProxyNode>[];
  final skipped = <ImportIssue>[];
  final failed = <ImportIssue>[];
  final seen = <String>{};
  for (var i = 0; i < outbounds.length; i++) {
    final entry = outbounds[i];
    final line = i + 1;
    if (entry is! Map) {
      failed.add(ImportIssue(
          kind: ImportFailureKind.malformedLink, message: 'outbound 不是对象', line: line)
          .withRaw(entry));
      continue;
    }
    final om = entry.map((k, v) => MapEntry('$k', v));
    final type = '${om['type'] ?? ''}'.toLowerCase();
    if (_systemOutboundTypes.contains(type)) {
      skipped.add(ImportIssue(
        kind: ImportFailureKind.unsupportedParameter,
        message: '系统出站（$type）不作为节点导入',
        line: line,
        note: _str(om['tag']),
      ).withRaw(jsonEncode(om)));
      continue;
    }
    final parsed = parseSingboxOutbound(om, line: line);
    if (parsed.node == null) {
      failed.add(parsed.issue!.withRaw(jsonEncode(om)));
      continue;
    }
    if (!seen.add(parsed.node!.fingerprint)) {
      skipped.add(ImportIssue(
          kind: ImportFailureKind.duplicate,
          message: '重复节点已跳过',
          line: line,
          note: parsed.node!.name).withRaw(jsonEncode(om)));
      continue;
    }
    nodes.add(parsed.node!);
  }
  // Report ignored top-level sections so the user knows nothing was adopted.
  const ignoredSections = {'route', 'dns', 'inbounds', 'experimental', 'log', 'ntp'};
  final ignored = <ImportIssue>[
    for (final section in ignoredSections)
      if (map.containsKey(section))
        ImportIssue(
          kind: ImportFailureKind.unsupportedParameter,
          message: '已忽略配置段 $section',
          note: section,
        ),
  ];
  return ImportResult(
    nodes: nodes,
    failed: failed,
    skipped: [...skipped, ...ignored],
    sourceFormat: 'singbox_json',
  );
}

const _systemOutboundTypes = {
  'direct',
  'block',
  'dns',
  'selector',
  'urltest',
  'tor',
};

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  return int.tryParse('$v');
}

({ProxyNode? node, ImportIssue? issue}) parseSingboxOutbound(
  Map<String, Object?> om, {
  int? line,
}) {
  final type = '${om['type'] ?? ''}'.toLowerCase();
  final tag = _str(om['tag']) ?? '';
  final server = _str(om['server']) ?? '';
  final port = _int(om['server_port'] ?? om['server-port']);
  if (server.isEmpty) {
    return (
      node: null,
      issue: ImportIssue(
          kind: ImportFailureKind.missingRequired, message: '缺少 server', line: line),
    );
  }
  if (port == null || port <= 0 || port > 65535) {
    return (
      node: null,
      issue: ImportIssue(
          kind: ImportFailureKind.missingRequired, message: '缺少 server_port', line: line),
    );
  }
  final proto = switch (type) {
    'shadowsocks' => ProxyProtocol.shadowsocks,
    'vmess' => ProxyProtocol.vmess,
    'vless' => ProxyProtocol.vless,
    'trojan' => ProxyProtocol.trojan,
    'hysteria2' => ProxyProtocol.hysteria2,
    'tuic' => ProxyProtocol.tuic,
    'socks' => ProxyProtocol.socks,
    'http' => ProxyProtocol.http,
    _ => null,
  };
  if (proto == null) {
    return (
      node: null,
      issue: ImportIssue(
        kind: ImportFailureKind.unsupportedProtocol,
        message: '不支持的协议 $type',
        line: line,
        note: type,
      ),
    );
  }
  final node = ProxyNode(
    id: '',
    fingerprint: '',
    name: tag.isEmpty ? '$server:$port' : tag,
    protocol: proto,
    server: server,
    port: port,
    secrets: NodeSecrets(
      uuid: _str(om['uuid']),
      password: _str(om['password']) ?? _str(om['auth']),
      method: _str(om['method']),
      username: _str(om['username']),
      alterId: _int(om['alter_id']) ?? _int(om['alterId']),
      flow: _str(om['flow']),
      security: _str(om['security']),
    ),
    transport: _singboxTransport(om),
    tls: _singboxTls(om),
    extras: _singboxExtras(om),
  );
  return (node: withIdentity(node), issue: null);
}

TransportConfig _singboxTransport(Map<String, Object?> om) {
  final t = om['transport'];
  if (t is! Map) return const TransportConfig();
  final tm = t.map((k, v) => MapEntry('$k', v));
  final kind = '${tm['type'] ?? 'tcp'}'.toLowerCase();
  switch (kind) {
    case 'ws':
      final headersRaw = tm['headers'];
      return TransportConfig(
        kind: TransportKind.ws,
        path: _str(tm['path']),
        host: headersRaw is Map ? _str(headersRaw['Host'] ?? headersRaw['host']) : null,
        earlyData: _int(tm['max_early_data']),
      );
    case 'grpc':
      return TransportConfig(kind: TransportKind.grpc, serviceName: _str(tm['service_name']));
    case 'http':
      final headers = <String, String>{};
      final h = tm['headers'];
      if (h is Map) {
        for (final e in h.entries) {
          final v = e.value;
          headers['${e.key}'] = v is List ? v.join(',') : '$v';
        }
      }
      return TransportConfig(
        kind: TransportKind.http,
        path: _str(tm['path']),
        host: headers['Host'] ?? headers['host'],
      );
    case 'httpupgrade':
      return TransportConfig(
          kind: TransportKind.httpUpgrade, path: _str(tm['path']), host: _str(tm['host']));
    case 'tcp':
      return const TransportConfig();
    default:
      return TransportConfig(kind: TransportKind.tcp, headers: {'unsupported_transport': kind});
  }
}

TlsConfig _singboxTls(Map<String, Object?> om) {
  final t = om['tls'];
  if (t is! Map) return const TlsConfig();
  final tm = t.map((k, v) => MapEntry('$k', v));
  final reality = tm['reality'];
  final insecure = tm['insecure'] == true;
  final alpnRaw = tm['alpn'];
  final alpn = alpnRaw is List ? alpnRaw.map((e) => '$e').toList() : const <String>[];
  if (reality is Map) {
    final rm = reality.map((k, v) => MapEntry('$k', v));
    return TlsConfig(
      kind: TlsKind.reality,
      serverName: _str(tm['server_name']),
      insecure: insecure,
      alpn: alpn,
      fingerprint: _str(tm['utls'] is Map ? (tm['utls'] as Map)['fingerprint'] : null),
      realityPublicKey: _str(rm['public_key']),
      realityShortId: _str(rm['short_id']),
    );
  }
  return TlsConfig(
    kind: tm['enabled'] == true ? TlsKind.tls : TlsKind.none,
    serverName: _str(tm['server_name']),
    insecure: insecure,
    alpn: alpn,
    fingerprint: _str(tm['utls'] is Map ? (tm['utls'] as Map)['fingerprint'] : null),
  );
}

Map<String, Object?> _singboxExtras(Map<String, Object?> om) {
  const known = {
    'type', 'tag', 'server', 'server_port', 'server-port', 'uuid', 'password',
    'auth', 'method', 'username', 'alter_id', 'alterId', 'flow', 'security',
    'transport', 'tls',
  };
  return {
    for (final e in om.entries)
      if (!known.contains(e.key)) e.key: e.value,
  };
}
