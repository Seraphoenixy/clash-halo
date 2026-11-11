/// Importer for v2rayN's exported JSON profiles.
///
/// v2rayN stores servers in `guiConfigs/guiNDB.db` (SQLite). A database cannot be
/// parsed by the text importers, and two facts that make its Naive entries work
/// are not expressible in a share link:
///
///   * the private root CA in the `Cert` column, which must be pinned or the
///     handshake is rejected (the failure looks like an immediate close), and
///   * `ProtoExtra.NaiveQuic`, which selects HTTP/3 over HTTP/2.
///
/// Accepted input is a JSON array of ProfileItem rows, or an object with a
/// `servers` array. Unsupported protocols are reported as skipped instead of
/// being dropped silently.
library;

import 'dart:convert';

import '../fingerprint.dart';
import '../models/node.dart';
import 'import_result.dart';

/// Maps v2rayN's ConfigType numbers onto this project's protocols.
///
/// Taken from v2rayN's `EConfigType` (ServiceLib/Enums/EConfigType.cs). The
/// previous table was guessed and shifted by one from `ConfigType 5` onward,
/// which mis-imported every VLESS node as Trojan and made real Trojan nodes
/// look like "HTTP 代理" and get skipped:
///
///     VMess=1 Custom=2 Shadowsocks=3 SOCKS=4 VLESS=5 Trojan=6
///     Hysteria2=7 TUIC=8 WireGuard=9 HTTP=10 Anytls=11 Naive=12
///     Outbound=13 MASQUE=14 PolicyGroup=101 ProxyChain=102
///
/// A wrong entry here does not fail loudly: it produces a node whose protocol
/// disagrees with v2rayN until the first connect. The test file pins every
/// value against a row shape copied from a real guiNDB.db.
const _configTypes = <int, ProxyProtocol>{
  1: ProxyProtocol.vmess,
  3: ProxyProtocol.shadowsocks,
  4: ProxyProtocol.socks,
  5: ProxyProtocol.vless,
  6: ProxyProtocol.trojan,
  7: ProxyProtocol.hysteria2,
  12: ProxyProtocol.naive,
  10: ProxyProtocol.http,
};

/// v2rayN types this project cannot carry, with the name shown to the user.
const _unsupported = <int, String>{
  2: '自定义配置（Custom）',
  8: 'TUIC',
  9: 'WireGuard',
  11: 'AnyTLS',
  13: 'Outbound 自定义出站',
  14: 'MASQUE',
  101: '策略组（PolicyGroup）',
  102: '代理链（ProxyChain）',
};

ImportResult parseV2rayNProfiles(String body) {
  final text = body.trim();
  if (text.isEmpty) {
    return const ImportResult(
      sourceFormat: 'v2rayn_json',
      failed: [
        ImportIssue(kind: ImportFailureKind.emptyInput, message: '内容为空'),
      ],
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return ImportResult(
      sourceFormat: 'v2rayn_json',
      failed: [
        ImportIssue(
          kind: ImportFailureKind.decodeError,
          message: '不是合法的 JSON：${e.message}',
        ),
      ],
    );
  }

  final List<Object?> rows;
  if (decoded is List) {
    rows = decoded;
  } else if (decoded is Map && decoded['servers'] is List) {
    rows = decoded['servers'] as List;
  } else {
    return const ImportResult(
      sourceFormat: 'v2rayn_json',
      failed: [
        ImportIssue(
          kind: ImportFailureKind.decodeError,
          message: 'v2rayN 配置必须是数组，或含 servers 数组的对象',
        ),
      ],
    );
  }

  final nodes = <ProxyNode>[];
  final skipped = <ImportIssue>[];
  final failed = <ImportIssue>[];
  final seen = <String>{};

  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row is! Map) {
      failed.add(ImportIssue(
        kind: ImportFailureKind.malformedLink,
        message: '第 ${i + 1} 项不是对象',
      ).withRaw(row));
      continue;
    }
    final item = row.map((k, v) => MapEntry('$k', v));
    // Every rejection below quotes the row it came from. Attaching it here
    // keeps the per-branch code about the reason, not about bookkeeping.
    void fail(ImportIssue issue, {List<ImportIssue>? into}) =>
        (into ?? failed).add(issue.withRaw(jsonEncode(item)));
    final remarks = _str(item['Remarks']) ?? '未命名 ${i + 1}';
    final type = _int(item['ConfigType']);

    if (type == null) {
      fail(ImportIssue(
        kind: ImportFailureKind.malformedLink,
        message: '$remarks：缺少 ConfigType',
      ));
      continue;
    }

    final protocol = _configTypes[type];
    if (protocol == null) {
      final why = _unsupported[type] ?? '未知类型 $type';
      fail(
        ImportIssue(
          kind: ImportFailureKind.unsupportedProtocol,
          message: '$remarks：暂不支持（$why）',
        ),
        into: skipped,
      );
      continue;
    }

    final host = _str(item['Address']);
    final port = _int(item['Port']);
    if (host == null) {
      fail(ImportIssue(
        kind: ImportFailureKind.missingRequired,
        message: '$remarks：缺少服务器地址',
      ));
      continue;
    }
    if (port == null || port <= 0 || port > 65535) {
      fail(ImportIssue(
        kind: ImportFailureKind.missingRequired,
        message: '$remarks：端口无效（${item['Port']}）',
      ));
      continue;
    }

    final network = (_str(item['Network']) ?? '').toLowerCase();
    final streamTls =
        (_str(item['StreamSecurity']) ?? '').toLowerCase() == 'tls';
    final protoExtra = _jsonMap(_str(item['ProtoExtra']));
    // ws/gRPC details live in TransportExtra, not in the Path/RequestHost
    // columns: those are empty on a real v2rayN row and reading them alone
    // imported a WebSocket node with a bare "/" path, which cannot handshake.
    // Both spellings are read because v2rayN writes PascalCase here and some
    // older exports use lowercase.
    final transportExtra = _jsonMap(_str(item['TransportExtra']));
    final path =
        _str(item['Path']) ?? _extra(transportExtra, 'Path', 'path');
    final reqHost =
        _str(item['RequestHost']) ?? _extra(transportExtra, 'Host', 'host');

    // v2rayN stores the UUID of a VMess/VLESS node in the Password column:
    // `outboundSettings.id = _node.Password` in its own V2rayOutboundService.
    // The Id column exists but is empty on a real row, so reading Id alone
    // produced a node that looked complete and then refused to generate with
    // "VLESS 缺少 UUID".
    final uuidLike =
        protocol == ProxyProtocol.vmess || protocol == ProxyProtocol.vless;
    final rawPassword = _str(item['Password']);
    final rawId = _str(item['Id']);
    final uuid = uuidLike ? (rawId ?? rawPassword) : rawId;

    final node = ProxyNode(
      id: '',
      fingerprint: '',
      name: remarks,
      protocol: protocol,
      server: host,
      port: port,
      secrets: NodeSecrets(
        uuid: uuid,
        // For VMess/VLESS the Password column held the UUID, so it must not
        // also become the node's password.
        password: uuidLike ? null : rawPassword,
        method: _str(item['Security']),
        username: _str(item['Username']),
        alterId: _int(item['AlterId']),
        flow: _str(item['Flow']),
      ),
      transport: TransportConfig(
        kind: _transportFor(network),
        path: path,
        host: reqHost,
        // For gRPC, v2rayN keeps the service name in Path too.
        serviceName: path,
      ),
      tls: TlsConfig(
        // Naive is HTTPS by definition; v2rayN still records StreamSecurity.
        kind: (streamTls || protocol == ProxyProtocol.naive)
            ? TlsKind.tls
            : TlsKind.none,
        serverName: _str(item['Sni']) ?? host,
        insecure: (_str(item['AllowInsecure']) ?? '') == 'true',
        alpn: _alpn(item['Alpn']),
        certificatePem: _str(item['Cert']),
      ),
      extras: {
        'v2rayn': {
          'configType': type,
          if (protoExtra.isNotEmpty) 'protoExtra': protoExtra,
          if (transportExtra.isNotEmpty) 'transportExtra': transportExtra,
          // Kept so the generator can emit `quic: true` for HTTP/3 nodes.
          if (protoExtra['NaiveQuic'] == true) 'naiveQuic': true,
        },
      },
    );
    // Every other importer stamps the fingerprint here. Without it a node has
    // an empty fingerprint, and the repository's identity check treats that as
    // "no identity" — so a five-row export was written as a *single* row named
    // `n_`, with the last row winning and the rest silently lost.
    final stamped = withIdentity(node);
    // Same connection twice under different remarks: report it like the
    // share-link, Clash YAML and sing-box importers do, instead of letting it
    // collapse silently at the database layer.
    if (!seen.add(stamped.fingerprint)) {
      skipped.add(ImportIssue(
        kind: ImportFailureKind.duplicate,
        message: '重复节点已跳过',
        line: i + 1,
        note: stamped.name,
      ).withRaw(jsonEncode(item)));
      continue;
    }
    nodes.add(stamped);
  }

  return ImportResult(
    nodes: nodes,
    skipped: skipped,
    failed: failed,
    sourceFormat: 'v2rayn_json',
  );
}

TransportKind _transportFor(String network) {
  switch (network) {
    case 'ws':
      return TransportKind.ws;
    case 'grpc':
      return TransportKind.grpc;
    case 'h2':
    case 'http':
      return TransportKind.http;
    default:
      return TransportKind.tcp;
  }
}

List<String> _alpn(Object? raw) {
  final value = _str(raw);
  if (value == null) return const [];
  return value
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

Map<String, Object?> _jsonMap(String? raw) {
  if (raw == null) return const {};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? decoded.map((k, v) => MapEntry('$k', v))
        : const {};
  } on FormatException {
    return const {};
  }
}

/// Reads the first present key, case-sensitively in the order given.
///
/// `TransportExtra` is written by v2rayN with PascalCase keys, but exports from
/// other tools use lowercase, and a node that silently loses its path cannot
/// connect: it fails at handshake time with no usable explanation.
String? _extra(Map<String, Object?> map, String first, String second) {
  for (final key in [first, second]) {
    final value = _str(map[key]);
    if (value != null) return value;
  }
  return null;
}

String? _str(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
