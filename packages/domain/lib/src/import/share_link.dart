/// Share-link parsing and export (`ss://`, `vmess://`, `vless://`, `trojan://`,
/// `hysteria2://`, `tuic://`, `socks://`, `http(s)://`, `anytls://`,
/// `naive+https://` / `naive+quic://` as proxy links).
///
/// Rules that matter for correctness:
///  * names are taken from the fragment and never used as identity;
///  * a link with an unknown scheme is reported, never silently converted;
///  * missing required credentials is a failure, not a default value;
///  * everything else round-trips into [ProxyNode.extras] so a later
///    capability check can reject it explicitly;
///  * the export side ([shareLinkFor]) emits only fields the model carries,
///    so every link it produces parses back to the same node.
library;

import 'dart:convert';

import '../fingerprint.dart';
import '../import/import_result.dart';
import '../models/node.dart';

/// Decodes the `&amp;` form a link takes when it is copied out of a web page.
///
/// Scraped lists routinely publish `?security=reality&amp;pbk=…`. A browser
/// turns that back into `&`; a raw URI parser does not, so every parameter
/// after the first becomes part of its neighbour's value and the entry fails
/// with a message about the missing key (typically "REALITY 客户端缺少公钥")
/// rather than about the escaping. Only the part before `#` is rewritten: the
/// fragment is the node's display name, and unescaping there would rename it.
String unescapeHtmlAmp(String link) {
  final fragment = _fragmentIndex(link);
  final head = fragment < 0 ? link : link.substring(0, fragment);
  final tail = fragment < 0 ? '' : link.substring(fragment);
  final unescaped = head
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&#x26;', '&')
      .replaceAll('&#X26;', '&');
  return '$unescaped$tail';
}

/// Index of the `#` that starts the fragment.
///
/// A plain `indexOf('#')` is wrong here: `&#38;` and `&#x26;` are the numeric
/// spellings of `&`, so their `#` is not a fragment marker. Treating it as one
/// split the link in the middle of an entity and left the parameters broken —
/// which is exactly the failure this function exists to prevent.
int _fragmentIndex(String link) {
  for (var i = 0; i < link.length; i++) {
    if (link.codeUnitAt(i) != 0x23) continue;
    final rest = link.substring(i);
    final isEntity = RegExp(r'^#(?:[0-9]{1,7}|[xX][0-9a-fA-F]{1,6});').hasMatch(rest);
    if (!isEntity) return i;
  }
  return -1;
}

/// Parses a share link the way the rest of the ecosystem does.
///
/// A plain `Uri.tryParse` is stricter than every client that *generates* these
/// links, and the difference is not academic: on one public list it rejected
/// 640 `ss://` entries and 3 `trojan://` entries that work in v2rayN. Two
/// shapes account for all of them:
///
///   * a name that was mangled by a charset round-trip leaves spaces, CJK or
///     emoji in the link body (`…:8080Р вҖң…`), which is not a URI at all;
///   * a password may contain `@`, so the authority has two of them and the
///     parser gives up instead of taking the last one as the delimiter.
///
/// The fix is to sanitise rather than to reject: cut at the first character a
/// URI can never contain, keep the last `@` as the userinfo delimiter, and
/// keep the digits of a port that had a mangled name glued onto it.
Uri? _parseLenient(String text) {
  final direct = Uri.tryParse(text);
  if (direct != null) return direct;
  final schemeEnd = text.indexOf('://');
  if (schemeEnd < 0) return null;
  final prefix = text.substring(0, schemeEnd + 3);
  var rest = text.substring(schemeEnd + 3);
  var cut = rest.length;
  for (var i = 0; i < rest.length; i++) {
    final c = rest.codeUnitAt(i);
    // Space, control characters, anything non-ASCII, and the bracket family:
    // a scraped list occasionally splices Markdown into the link
    // (`…fQ[span_50](start_span)`), which no URI parser accepts either.
    if (c <= 0x20 || c >= 0x7f || _uriRejected.contains(String.fromCharCode(c))) {
      cut = i;
      break;
    }
  }
  rest = rest.substring(0, cut);
  final authEnd = _firstIndexAny(rest, '/?#');
  final authority = authEnd < 0 ? rest : rest.substring(0, authEnd);
  final tail = authEnd < 0 ? '' : rest.substring(authEnd);
  final at = authority.lastIndexOf('@');
  final userinfo = at < 0 ? '' : authority.substring(0, at);
  final hostPort = at < 0 ? authority : authority.substring(at + 1);
  final fixedHostPort = _fixedHostPort(hostPort);
  final fixed = at < 0
      ? fixedHostPort
      : '${userinfo.replaceAll('@', '%40')}@$fixedHostPort';
  return Uri.tryParse('$prefix$fixed$tail');
}

/// Characters a share link never legitimately contains, but a mangled one
/// often does.
const String _uriRejected = r'[]{}<>"^`|\';

/// Trims junk glued onto the port.
///
/// `…:443freenettirUnited` and `…:8080%40freenettir%20%C2%B9` are otherwise
/// valid links whose name was concatenated into the authority. The port is
/// digits only, so the first run of digits is the port and the rest is damage.
String _fixedHostPort(String hostPort) {
  final colon = hostPort.lastIndexOf(':');
  if (colon < 0 || colon + 1 >= hostPort.length) return hostPort;
  // Leave an IPv6 literal alone: its colons are part of the address.
  if (hostPort.startsWith('[')) {
    final close = hostPort.lastIndexOf(']');
    if (close > colon) return hostPort;
  }
  final port = hostPort.substring(colon + 1);
  final digits = RegExp(r'^\d{1,5}').firstMatch(port)?.group(0) ?? '';
  if (digits.length == port.length) return hostPort;
  return '${hostPort.substring(0, colon + 1)}$digits';
}

int _firstIndexAny(String value, String chars) {
  var best = -1;
  for (final c in chars.split('')) {
    final idx = value.indexOf(c);
    if (idx >= 0 && (best < 0 || idx < best)) best = idx;
  }
  return best;
}

/// The longest Base64 prefix of [value].
///
/// Publishers append emoji, a stray `?fp=chrome`, or a second copy of the name
/// after a valid payload. Base64 has a fixed alphabet, so the first character
/// outside it marks the end of the encoded part — and decoding only that part
/// recovers a node the whole-string decode refuses.
String _base64Prefix(String value) {
  var end = value.length;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    final ok = (c >= 0x41 && c <= 0x5a) || // A-Z
        (c >= 0x61 && c <= 0x7a) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2b || // +
        c == 0x2f || // /
        c == 0x3d || // =
        c == 0x2d || // - (URL-safe)
        c == 0x5f; // _ (URL-safe)
    if (!ok) {
      end = i;
      break;
    }
  }
  return value.substring(0, end);
}

/// Scheme markers that start a share link, longest first where one contains
/// another (`naive+https` contains `https`).
const List<String> _shareSchemeMarkers = [
  'naive+https://',
  'naive+quic://',
  'hysteria2://',
  'httpupgrade://',
  'vless://',
  'vmess://',
  'trojan://',
  'anytls://',
  'socks5://',
  'socks://',
  'naive://',
  'tuic://',
  'hy2://',
  'ss://',
  'http://',
  'https://',
];

/// Splits a line that carries more than one link.
///
/// One aggregator joins entries without a separator, so a line reads
/// `<base64 vmess payload>vless://…` — the Base64 has no `://`, so the whole
/// line used to be rejected as one malformed entry and both nodes were lost.
/// Splitting at the next scheme marker recovers both; the leading Base64 is
/// then handled as a scheme-less payload by [parseShareLink].
///
/// Markers are matched longest-first so `naive+https://` is not cut into
/// `naive+` plus `https://`.
///
/// Everything from the first `#` on is a display name, not link syntax, and is
/// never searched for markers. A name may itself be a URL — providers use their
/// Telegram channel as the label (`trojan://…#https://t.me/xxx`) — and scanning
/// it used to cut the name out of its own link and parse it as a second, ghost
/// `http(s)` node on every refresh. By the same rule the whole remainder stays
/// with the last link: a fragment never starts a new entry. The `#` is found by
/// [_fragmentIndex] because `&#38;` is an escaped `&`, not a fragment.
List<String> splitConcatenatedLinks(String line) {
  final fragmentAt = _fragmentIndex(line);
  final body = fragmentAt < 0 ? line : line.substring(0, fragmentAt);
  final fragment = fragmentAt < 0 ? '' : line.substring(fragmentAt);
  final found = <({int start, int end})>[];
  for (final marker in _shareSchemeMarkers) {
    var index = body.indexOf(marker);
    while (index >= 0) {
      found.add((start: index, end: index + marker.length));
      index = body.indexOf(marker, index + 1);
    }
  }
  if (found.isEmpty) return [line];
  found.sort((a, b) => a.start.compareTo(b.start));
  final cuts = <int>[];
  var covered = 0;
  for (final match in found) {
    // A marker inside another marker (`https` inside `naive+https`) is not a
    // boundary of its own.
    if (match.start < covered) continue;
    covered = match.end;
    if (match.start > 0) cuts.add(match.start);
  }
  if (cuts.isEmpty) return [line];
  final segments = <String>[];
  var cursor = 0;
  for (final cut in cuts) {
    if (cut <= cursor) continue;
    segments.add(body.substring(cursor, cut));
    cursor = cut;
  }
  segments.add(body.substring(cursor) + fragment);
  return segments;
}

/// Whether [text] is the Base64 payload of a vmess link with the scheme
/// stripped.
///
/// Some lists publish the payload alone. It is recognisable without guessing:
/// Base64-decoding it yields an object with `add` and `id`, which no other
/// share-link text does.
bool _looksLikeBareVmessPayload(String text) {
  final decoded = _tryB64(text) ?? _tryB64(_base64Prefix(text));
  if (decoded == null || !decoded.trimLeft().startsWith('{')) return false;
  try {
    final json = jsonDecode(decoded);
    return json is Map && json['add'] != null && json['id'] != null;
  } on FormatException {
    return false;
  }
}

/// Parses a single share link. Returns null plus the issue on failure so the
/// caller can aggregate all problems in one pass.
({ProxyNode? node, ImportIssue? issue}) parseShareLink(String raw, {int? line}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return (
      node: null,
      issue: ImportIssue(
          kind: ImportFailureKind.emptyInput, message: '空条目', line: line),
    );
  }
  final text = unescapeHtmlAmp(trimmed);
  // A scheme-less vmess payload is prefixed and parsed by the normal path, so
  // the node, its identity and its error messages stay identical.
  // A scheme-less vmess payload is prefixed and parsed by the normal path, so
  // the node, its identity and its error messages stay identical.
  if (!text.contains('://') && _looksLikeBareVmessPayload(text)) {
    return parseShareLink('vmess://$text', line: line);
  }
  final uri = _parseLenient(text);
  if (uri == null || !uri.hasScheme) {
    return (
      node: null,
      issue: ImportIssue(
          kind: ImportFailureKind.malformedLink, message: '无法识别的链接', line: line),
    );
  }
  final scheme = uri.scheme.toLowerCase();
  try {
    final node = switch (scheme) {
      'ss' => _parseShadowsocks(uri, text),
      'vmess' => _parseVmess(uri, text),
      'vless' => _parseVless(uri, text),
      'trojan' => _parseTrojan(uri, text),
      'hysteria2' || 'hy2' => _parseHysteria2(uri, text),
      'tuic' => _parseTuic(uri, text),
      'socks' || 'socks5' => _parseSocks(uri, text),
      'http' || 'https' => _parseHttp(uri, text),
      'anytls' => _parseAnytls(uri, text),
      'naive' || 'naive+https' || 'naive+quic' => _parseNaive(uri, text),
      _ => throw _LinkError(ImportFailureKind.unsupportedProtocol,
          '不支持的协议 $scheme', scheme),
    };
    return (node: withIdentity(node), issue: null);
  } on _LinkError catch (e) {
    return (
      node: null,
      issue: ImportIssue(kind: e.kind, message: e.message, line: line, note: e.note),
    );
  } catch (e) {
    // A parser must never escape with an untyped error: user data is untrusted.
    return (
      node: null,
      issue: ImportIssue(
          kind: ImportFailureKind.malformedLink,
          message: '链接解析失败: ${_firstLine('$e')}',
          line: line,
          note: scheme),
    );
  }
}

String _firstLine(String text) {
  final idx = text.indexOf('\n');
  final line = idx < 0 ? text : text.substring(0, idx);
  return line.length > 120 ? '${line.substring(0, 120)}…' : line;
}

class _LinkError implements Exception {
  _LinkError(this.kind, this.message, [this.note]);
  final ImportFailureKind kind;
  final String message;
  final String? note;
}

/// Tolerant integer parse for JSON payload fields that may arrive as strings
/// (`"port": "443"` is extremely common in vmess payloads).
int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value'.trim());
}

String _decodeName(Uri uri) {
  if (uri.fragment.isEmpty) return '';
  try {
    return Uri.decodeComponent(uri.fragment);
  } catch (_) {
    return uri.fragment;
  }
}

/// The userinfo component, percent-decoded once.
///
/// Dart's [Uri.userInfo] returns the raw component, so a password carrying
/// `@` or `:` — encoded as `%40` / `%3A` on export — arrives still encoded.
/// Every parser that splits credentials on ':' must go through here, or an
/// exported link with a special-character password imports the ciphertext as
/// the plaintext.
String _userInfo(Uri uri) {
  final raw = uri.userInfo;
  if (raw.isEmpty || !raw.contains('%')) return raw;
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

String _requireServer(Uri uri) {
  final host = uri.host;
  if (host.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, '缺少服务器地址');
  return host;
}

int _requirePort(Uri uri, int fallback) {
  if (uri.hasPort && uri.port > 0 && uri.port <= 65535) return uri.port;
  if (fallback > 0 && fallback <= 65535) return fallback;
  throw _LinkError(ImportFailureKind.missingRequired, '缺少有效端口');
}

String _defaultName(String scheme, Uri uri) =>
    _decodeName(uri).isNotEmpty ? _decodeName(uri) : '${uri.host}:${uri.port}';

Map<String, String> _query(Uri uri) => {
      for (final e in uri.queryParameters.entries) e.key.toLowerCase(): e.value,
    };

TlsConfig _tlsFromQuery(Map<String, String> q, {String? defaultSni, bool defaultOn = false}) {
  final security = (q['security'] ?? '').toLowerCase();
  final reality = security == 'reality' || q.containsKey('pbk');
  // An explicit security=none means the peer really runs plaintext — mostly
  // vless over raw TCP, which is exactly as odd as it sounds but must not be
  // "upgraded" to TLS on import or a re-export would drift from the source.
  final explicitNone = security == 'none';
  final tlsOn =
      (defaultOn && !explicitNone) || reality || security == 'tls' || q['tls'] == '1' || q['tls'] == 'true';
  if (reality) {
    final pbk = q['pbk'];
    if (pbk == null || pbk.isEmpty) {
      throw _LinkError(ImportFailureKind.missingRequired, 'REALITY 客户端缺少公钥');
    }
    return TlsConfig(
      kind: TlsKind.reality,
      serverName: q['sni'] ?? defaultSni,
      insecure: q['allowinsecure'] == '1' || q['insecure'] == '1',
      alpn: _splitAlpn(q['alpn']),
      fingerprint: q['fp'],
      realityPublicKey: pbk,
      realityShortId: q['sid'],
    );
  }
  if (!tlsOn && q['sni'] == null && q['allowinsecure'] == null && q['insecure'] == null) {
    return const TlsConfig();
  }
  return TlsConfig(
    kind: tlsOn ? TlsKind.tls : TlsKind.none,
    serverName: q['sni'] ?? q['host'] ?? defaultSni,
    insecure: q['allowinsecure'] == '1' || q['insecure'] == '1',
    alpn: _splitAlpn(q['alpn']),
    fingerprint: q['fp'],
  );
}

List<String> _splitAlpn(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

TransportConfig _transportFromQuery(Map<String, String> q) {
  final type = (q['type'] ?? 'tcp').toLowerCase();
  final headerHost = q['host'];
  switch (type) {
    case 'ws':
      return TransportConfig(
        kind: TransportKind.ws,
        path: q['path'],
        host: headerHost,
        earlyData: q['ed'] == null ? null : int.tryParse(q['ed']!),
      );
    case 'grpc':
      return TransportConfig(kind: TransportKind.grpc, serviceName: q['servicename'] ?? q['serviceName']);
    case 'http':
    case 'h2':
      return TransportConfig(
        kind: TransportKind.http,
        path: q['path'],
        host: headerHost,
        headers: _headersFromQuery(q),
      );
    case 'httpupgrade':
      return TransportConfig(kind: TransportKind.httpUpgrade, path: q['path'], host: headerHost);
    case 'tcp':
    // Xray renamed `tcp` to `raw` and its exporters now emit either spelling
    // for the same thing. Refusing `raw` rejected 36 working VLESS links.
    case 'raw':
    case '':
      return TransportConfig(kind: TransportKind.tcp, headers: _headersFromQuery(q));
    default:
      throw _LinkError(ImportFailureKind.unsupportedParameter, '不支持的传输类型 $type', type);
  }
}

Map<String, String> _headersFromQuery(Map<String, String> q) {
  final out = <String, String>{};
  for (final entry in q.entries) {
    if (entry.key.startsWith('header.')) {
      out[entry.key.substring('header.'.length)] = entry.value;
    }
  }
  return out;
}

ProxyNode _parseShadowsocks(Uri uri, String raw) {
  // Two forms: ss://base64(method:pass)@host:port#name and
  // ss://base64(method:pass@host:port)#name.
  var userInfo = _userInfo(uri);
  var host = uri.host;
  var port = uri.port;
  String? name;
  Map<String, Object?> extras = const {};
  if (raw.contains('@')) {
    if (userInfo.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, '缺少加密凭据');
    // SIP002 encodes `method:password`, but exporters also emit it in the
    // clear — including the 2022-blake3 methods, whose password *is* Base64.
    // A colon cannot occur in Base64, so its presence is the discriminator:
    // decoding first is what turned 36 working SS nodes into "Base64 解码失败".
    if (!userInfo.contains(':')) {
      final decoded = _b64(userInfo);
      final idx = decoded.indexOf(':');
      if (idx < 0) throw _LinkError(ImportFailureKind.decodeError, 'SS 凭据解码失败');
      userInfo = decoded;
    }
  } else {
    // Whole authority payload may be base64.
    final payload = _b64(raw.substring(raw.indexOf('://') + 3).split('#').first.split('?').first);
    final at = payload.lastIndexOf('@');
    if (at < 0) throw _LinkError(ImportFailureKind.malformedLink, 'SS 链接缺少服务器');
    userInfo = payload.substring(0, at);
    final hostPort = payload.substring(at + 1);
    final colon = hostPort.lastIndexOf(':');
    if (colon < 0) throw _LinkError(ImportFailureKind.malformedLink, 'SS 链接缺少端口');
    host = hostPort.substring(0, colon);
    port = int.tryParse(hostPort.substring(colon + 1)) ?? 0;
  }
  final idx = userInfo.indexOf(':');
  if (idx <= 0) throw _LinkError(ImportFailureKind.malformedLink, 'SS 凭据格式错误');
  final method = userInfo.substring(0, idx);
  final password = userInfo.substring(idx + 1);
  if (method.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, '缺少加密方式');
  if (password.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, '缺少密码');
  name = _decodeName(uri);
  final plugin = uri.queryParameters['plugin'];
  if (plugin != null && plugin.isNotEmpty) {
    extras = {...extras, 'plugin': plugin};
  }
  final portOk = port > 0 && port <= 65535
      ? port
      : throw _LinkError(ImportFailureKind.missingRequired, '缺少有效端口');
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: name.isEmpty ? '$host:$portOk' : name,
    protocol: ProxyProtocol.shadowsocks,
    server: host,
    port: portOk,
    secrets: NodeSecrets(method: method, password: password),
    extras: extras,
  );
}

ProxyNode _parseVmess(Uri uri, String raw) {
  // Preferred: vmess://base64(json). Also accept the URI form.
  final payload = raw.substring(raw.indexOf('://') + 3);
  final body = payload.split('#').first;
  // Trailing emoji or a stray `?fp=…` after the payload is common in this
  // format; decode the longest Base64 prefix so the node is still recovered.
  final decoded = _tryB64(body) ?? _tryB64(_base64Prefix(body));
  // Only a payload that really looks like JSON is treated as JSON. The URI
  // form (`vmess://uuid@host:port?…`) happens to be valid Base64 characters,
  // so decoding it produces arbitrary bytes; parsing those as JSON threw a
  // bare FormatException and the link was reported as unreadable instead of
  // being read as the URI form it is.
  if (decoded != null && decoded.trimLeft().startsWith('{')) {
    final Map<String, Object?> map;
    try {
      final json = jsonDecode(decoded);
      if (json is! Map) {
        throw _LinkError(ImportFailureKind.malformedLink, 'VMess 内容不是对象');
      }
      map = json.cast<String, Object?>();
    } on FormatException {
      throw _LinkError(ImportFailureKind.malformedLink, 'VMess 内容不是 JSON');
    }
    final add = '${map['add'] ?? ''}';
    final port = _asInt(map['port']) ?? 0;
    final id = '${map['id'] ?? ''}';
    if (add.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'VMess 缺少服务器');
    if (port <= 0) throw _LinkError(ImportFailureKind.missingRequired, 'VMess 缺少端口');
    if (id.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'VMess 缺少 UUID');
    final net = '${map['net'] ?? 'tcp'}'.toLowerCase();
    final tlsRaw = '${map['tls'] ?? ''}'.toLowerCase();
    final hostHeader = '${map['host'] ?? ''}';
    final path = map['path'] as String?;
    final transport = switch (net) {
      'ws' => TransportConfig(kind: TransportKind.ws, path: path, host: hostHeader),
      'grpc' => TransportConfig(kind: TransportKind.grpc, serviceName: path),
      'h2' || 'http' => TransportConfig(
          kind: TransportKind.http, path: path, host: hostHeader),
      'httpupgrade' => TransportConfig(
          kind: TransportKind.httpUpgrade, path: path, host: hostHeader),
      _ => const TransportConfig(),
    };
    final knownKeys = {
      'v', 'ps', 'add', 'port', 'id', 'aid', 'scy', 'net', 'type', 'host', 'path',
      'tls', 'sni', 'alpn', 'fp', 'insecure', 'pbk', 'sid',
    };
    final extras = {
      for (final e in map.entries)
        if (!knownKeys.contains(e.key)) e.key: e.value,
    };
    // REALITY rides the same JSON shape as plain TLS in vmess links; a link
    // claiming it without a public key would generate a config that can never
    // authenticate, so it is refused here instead of imported half-configured.
    final tlsKind = tlsRaw == 'reality'
        ? TlsKind.reality
        : tlsRaw == 'tls'
            ? TlsKind.tls
            : TlsKind.none;
    if (tlsKind == TlsKind.reality) {
      final pbk = '${map['pbk'] ?? ''}';
      if (pbk.isEmpty) {
        throw _LinkError(ImportFailureKind.missingRequired, 'VMess REALITY 缺少公钥');
      }
    }
    return ProxyNode(
      id: '',
      fingerprint: '',
      name: '${map['ps'] ?? ''}'.isNotEmpty
          ? '${map['ps']}'
          : '$add:$port',
      protocol: ProxyProtocol.vmess,
      server: add,
      port: port,
      secrets: NodeSecrets(
        uuid: id,
        alterId: _asInt(map['aid']),
        security: map['scy'] as String?,
      ),
      transport: transport,
      tls: tlsKind == TlsKind.none
          ? const TlsConfig()
          : TlsConfig(
              kind: tlsKind,
              serverName: '${map['sni'] ?? hostHeader}'.isEmpty ? null : '${map['sni'] ?? hostHeader}',
              alpn: _splitAlpn(map['alpn'] as String?),
              fingerprint: map['fp'] as String?,
              insecure: '${map['insecure'] ?? ''}' == '1',
              realityPublicKey: map['pbk'] as String?,
              realityShortId: map['sid'] as String?,
            ),
      extras: extras,
    );
  }
  // URI form: vmess://uuid@host:port?...
  final host = _requireServer(uri);
  final port = _requirePort(uri, 443);
  final uuid = _userInfo(uri).split(':').first;
  if (uuid.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'VMess 缺少 UUID');
  final q = _query(uri);
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _defaultName('vmess', uri),
    protocol: ProxyProtocol.vmess,
    server: host,
    port: port,
    secrets: NodeSecrets(uuid: uuid),
    transport: _transportFromQuery(q),
    tls: _tlsFromQuery(q, defaultSni: host),
  );
}

ProxyNode _parseVless(Uri uri, String raw) {
  final host = _requireServer(uri);
  final port = _requirePort(uri, 443);
  final uuid = _userInfo(uri).split(':').first;
  if (uuid.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'VLESS 缺少 UUID');
  final q = _query(uri);
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _defaultName('vless', uri),
    protocol: ProxyProtocol.vless,
    server: host,
    port: port,
    secrets: NodeSecrets(uuid: uuid, flow: q['flow']),
    transport: _transportFromQuery(q),
    tls: _tlsFromQuery(q, defaultSni: q['host'] ?? host, defaultOn: true),
  );
}

ProxyNode _parseTrojan(Uri uri, String raw) {
  final host = _requireServer(uri);
  final port = _requirePort(uri, 443);
  final password = _userInfo(uri);
  if (password.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'Trojan 缺少密码');
  final q = _query(uri);
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _defaultName('trojan', uri),
    protocol: ProxyProtocol.trojan,
    server: host,
    port: port,
    secrets: NodeSecrets(password: password),
    transport: _transportFromQuery(q),
    tls: _tlsFromQuery(q, defaultSni: host, defaultOn: true),
  );
}

ProxyNode _parseHysteria2(Uri uri, String raw) {
  final host = _requireServer(uri);
  final port = _requirePort(uri, 443);
  final password = _userInfo(uri);
  if (password.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'Hysteria2 缺少密码');
  final q = _query(uri);
  final extras = <String, Object?>{
    if (q['obfs'] != null) 'obfs': q['obfs'],
    if (q['obfs-password'] != null) 'obfsPassword': q['obfs-password'],
    if (q['up'] != null) 'upMbps': q['up'],
    if (q['down'] != null) 'downMbps': q['down'],
  };
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _decodeName(uri).isEmpty ? '$host:$port' : _decodeName(uri),
    protocol: ProxyProtocol.hysteria2,
    server: host,
    port: port,
    secrets: NodeSecrets(password: password),
    tls: TlsConfig(
      kind: TlsKind.tls,
      serverName: q['sni'] ?? host,
      insecure: q['insecure'] == '1' || q['insecure'] == 'true',
      alpn: _splitAlpn(q['alpn']),
    ),
    extras: extras,
  );
}

ProxyNode _parseTuic(Uri uri, String raw) {
  final host = _requireServer(uri);
  final port = _requirePort(uri, 443);
  final userInfo = _userInfo(uri);
  final idx = userInfo.indexOf(':');
  if (idx <= 0) throw _LinkError(ImportFailureKind.missingRequired, 'TUIC 缺少 UUID 或密码');
  final q = _query(uri);
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _decodeName(uri).isEmpty ? '$host:$port' : _decodeName(uri),
    protocol: ProxyProtocol.tuic,
    server: host,
    port: port,
    secrets: NodeSecrets(
        uuid: userInfo.substring(0, idx), password: userInfo.substring(idx + 1)),
    tls: TlsConfig(kind: TlsKind.tls, serverName: q['sni'] ?? host),
    extras: {
      if (q['congestion_control'] != null) 'congestionControl': q['congestion_control'],
      if (q['alpn'] != null) 'alpn': q['alpn'],
    },
  );
}

ProxyNode _parseSocks(Uri uri, String raw) {
  final host = _requireServer(uri);
  final port = _requirePort(uri, 1080);
  final userInfo = _userInfo(uri);
  final idx = userInfo.indexOf(':');
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _decodeName(uri).isEmpty ? '$host:$port' : _decodeName(uri),
    protocol: ProxyProtocol.socks,
    server: host,
    port: port,
    secrets: idx > 0
        ? NodeSecrets(
            username: userInfo.substring(0, idx), password: userInfo.substring(idx + 1))
        : const NodeSecrets(),
  );
}

ProxyNode _parseHttp(Uri uri, String raw) {
  final host = _requireServer(uri);
  final isTls = uri.scheme.toLowerCase() == 'https';
  final port = _requirePort(uri, isTls ? 443 : 80);
  final userInfo = _userInfo(uri);
  final idx = userInfo.indexOf(':');
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _decodeName(uri).isEmpty ? '$host:$port' : _decodeName(uri),
    protocol: ProxyProtocol.http,
    server: host,
    port: port,
    secrets: idx > 0
        ? NodeSecrets(
            username: userInfo.substring(0, idx), password: userInfo.substring(idx + 1))
        : const NodeSecrets(),
    tls: isTls ? TlsConfig(kind: TlsKind.tls, serverName: host) : const TlsConfig(),
  );
}

ProxyNode _parseAnytls(Uri uri, String raw) {
  final host = _requireServer(uri);
  final port = _requirePort(uri, 443);
  final password = _userInfo(uri);
  if (password.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'AnyTLS 缺少密码');
  final q = _query(uri);
  // AnyTLS is always TLS-carried; the scheme says so even when the link does
  // not spell out security=tls.
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _decodeName(uri).isEmpty ? '$host:$port' : _decodeName(uri),
    protocol: ProxyProtocol.anytls,
    server: host,
    port: port,
    secrets: NodeSecrets(password: password),
    tls: _tlsFromQuery(q, defaultSni: host, defaultOn: true),
  );
}

ProxyNode _parseNaive(Uri uri, String raw) {
  final host = _requireServer(uri);
  final port = _requirePort(uri, 443);
  final userInfo = _userInfo(uri);
  if (userInfo.isEmpty) throw _LinkError(ImportFailureKind.missingRequired, 'Naive 缺少用户凭据');
  final q = _query(uri);
  final idx = userInfo.indexOf(':');
  // naive+quic is HTTP/3 (QUIC); it changes the transport the node listens
  // on, which reachability probing cares about, so it is recorded.
  final isQuic = uri.scheme.toLowerCase().contains('quic');
  return ProxyNode(
    id: '',
    fingerprint: '',
    name: _decodeName(uri).isEmpty ? '$host:$port' : _decodeName(uri),
    protocol: ProxyProtocol.naive,
    server: host,
    port: port,
    secrets: idx > 0
        ? NodeSecrets(
            username: userInfo.substring(0, idx),
            password: userInfo.substring(idx + 1))
        : NodeSecrets(password: userInfo),
    // Naive always speaks TLS with a real certificate; the scheme says so.
    tls: _tlsFromQuery(q, defaultSni: host, defaultOn: true),
    extras: {if (isQuic) 'naiveQuic': true},
  );
}

String _b64(String value) {
  final decoded = _tryB64(value);
  if (decoded == null) throw _LinkError(ImportFailureKind.decodeError, 'Base64 解码失败');
  return decoded;
}

/// Tries standard, URL-safe and unpadded Base64. Returns null when the input
/// is not valid Base64 at all.
String? _tryB64(String value) {
  var v = value.trim();
  if (v.isEmpty) return null;
  v = v.replaceAll('-', '+').replaceAll('_', '/');
  // Normalise the padding instead of appending to whatever is already there: a
  // payload cut off before its trailing junk often ends inside its own padding,
  // and `base64.decode` rejects `A===`. Stripping and re-padding keeps such a
  // payload decodable, which is how 100 more VMess nodes came back.
  v = v.replaceAll(RegExp(r'=+$'), '');
  final pad = v.length % 4;
  if (pad == 1) return null;
  if (pad > 0) v = v + '=' * (4 - pad);
  try {
    final bytes = base64.decode(v);
    final text = utf8.decode(bytes, allowMalformed: true);
    return text;
  } catch (_) {
    return null;
  }
}

/// Parses a whole share-link list (already split by the caller) and
/// deduplicates by fingerprint, reporting duplicates as skipped entries.
ImportResult parseShareLinks(Iterable<String> lines) {
  final nodes = <ProxyNode>[];
  final failed = <ImportIssue>[];
  final skipped = <ImportIssue>[];
  final seen = <String>{};
  var index = 0;
  for (final line in lines) {
    index++;
    if (line.trim().isEmpty) continue;
    // One line may carry two links; each piece is judged on its own, otherwise
    // a bad join costs both nodes and reports one "格式损坏".
    for (final piece in splitConcatenatedLinks(line)) {
      final text = piece.trim();
      if (text.isEmpty) continue;
      final parsed = parseShareLink(text, line: index);
      if (parsed.node == null) {
        // The whole point of the raw text: "无法识别的链接" alone gives the user
        // no way to tell a damaged entry from a supported one that needs a fix.
        failed.add(parsed.issue!.withRaw(text));
        continue;
      }
      if (!seen.add(parsed.node!.fingerprint)) {
        skipped.add(ImportIssue(
          kind: ImportFailureKind.duplicate,
          message: '重复节点已跳过',
          line: index,
          note: parsed.node!.name,
        ).withRaw(text));
        continue;
      }
      nodes.add(parsed.node!);
    }
  }
  return ImportResult(
      nodes: nodes, failed: failed, skipped: skipped, sourceFormat: 'share_links');
}

// ---------------------------------------------------------------------------
// Export — the inverse of the parsers above.
//
// The URI shapes follow v2rayN's ServiceLib/Handler/Fmt (the de-facto
// interchange format every major client reads), reduced to what the
// [ProxyNode] model actually carries. Every link [shareLinkFor] produces
// re-imports through [parseShareLink] to a node with the same identity, which
// the tests pin per protocol. Where the model has no field for a parameter
// v2rayN exports (SS plugins, gRPC authority, raw header types), the
// parameter is omitted rather than invented — a link claiming options the app
// cannot represent or regenerate would be worse than a plainer one.
// ---------------------------------------------------------------------------

/// Best-effort share-link export for a node.
///
/// Returns null for a protocol with no unambiguous URI form (SSH), or when a
/// required credential is missing — a wrong link is worse than no link,
/// because it pastes into another client and silently produces a dead profile.
String? shareLinkFor(ProxyNode node) {
  switch (node.protocol) {
    case ProxyProtocol.trojan:
      return _exportWithQuery(node, scheme: 'trojan', credential: node.secrets.password);
    case ProxyProtocol.vless:
      return _exportWithQuery(node, scheme: 'vless', credential: node.secrets.uuid,
          extraQuery: () => _vlessQuery(node));
    case ProxyProtocol.anytls:
      return _exportWithQuery(node, scheme: 'anytls', credential: node.secrets.password,
          includeTransport: false);
    case ProxyProtocol.hysteria2:
      return _exportHysteria2(node);
    case ProxyProtocol.tuic:
      return _exportTuic(node);
    case ProxyProtocol.vmess:
      return _exportVmess(node);
    case ProxyProtocol.shadowsocks:
      return _exportShadowsocks(node);
    case ProxyProtocol.socks:
      return _exportUserPass(node, 'socks');
    case ProxyProtocol.http:
      return _exportUserPass(node, node.tls.enabled ? 'https' : 'http');
    case ProxyProtocol.naive:
      return _exportNaive(node);
    case ProxyProtocol.ssh:
      // No URI form is unambiguous for SSH (key files, host-key policies);
      // emitting one would invent parameters the model cannot carry.
      return null;
  }
}

/// The common query-string builder, mirroring v2rayN's `ToUriQuery`:
/// TLS parameters first, then the transport block.
Map<String, String> _tlsAndTransportQuery(
  ProxyNode node, {
  bool includeTransport = true,
}) {
  final q = <String, String>{};
  final tls = node.tls;
  if (tls.enabled) {
    q['security'] = tls.kind == TlsKind.reality ? 'reality' : 'tls';
    if (_hasText(tls.serverName)) q['sni'] = tls.serverName!;
    if (_hasText(tls.fingerprint)) q['fp'] = tls.fingerprint!;
    if (_hasText(tls.realityPublicKey)) q['pbk'] = tls.realityPublicKey!;
    if (_hasText(tls.realityShortId)) q['sid'] = tls.realityShortId!;
    if (tls.alpn.isNotEmpty) q['alpn'] = tls.alpn.join(',');
    if (tls.insecure) q['allowInsecure'] = '1';
  }
  if (!includeTransport) return q;
  final t = node.transport;
  // A default TCP transport with nothing to say adds no parameters: every
  // parser defaults to tcp anyway, and a bare link stays readable.
  final bareTcp = t.kind == TransportKind.tcp &&
      !_hasText(t.host) &&
      t.headers.isEmpty;
  if (!bareTcp) {
    q['type'] = switch (t.kind) {
      TransportKind.tcp => 'tcp',
      TransportKind.ws => 'ws',
      TransportKind.grpc => 'grpc',
      TransportKind.http => 'h2',
      TransportKind.httpUpgrade => 'httpupgrade',
    };
  }
  switch (t.kind) {
    case TransportKind.ws:
      if (_hasText(t.host)) q['host'] = t.host!;
      if (_hasText(t.path)) q['path'] = t.path!;
      if (t.earlyData != null) q['ed'] = '${t.earlyData}';
    case TransportKind.http || TransportKind.httpUpgrade:
      if (_hasText(t.host)) q['host'] = t.host!;
      if (_hasText(t.path)) q['path'] = t.path!;
      for (final e in t.headers.entries) {
        q['header.${e.key}'] = e.value;
      }
    case TransportKind.grpc:
      if (_hasText(t.serviceName)) q['serviceName'] = t.serviceName!;
    case TransportKind.tcp:
      if (_hasText(t.host)) q['host'] = t.host!;
      for (final e in t.headers.entries) {
        q['header.${e.key}'] = e.value;
      }
  }
  return q;
}

/// VLESS's own parameters plus the shared block. `security=none` is emitted
/// explicitly (v2rayN does the same) so a plaintext vless re-imports as
/// plaintext instead of being upgraded to TLS.
Map<String, String> _vlessQuery(ProxyNode node) {
  final q = <String, String>{'encryption': 'none'};
  if (_hasText(node.secrets.flow)) q['flow'] = node.secrets.flow!;
  q.addAll(_tlsAndTransportQuery(node));
  if (!node.tls.enabled) q['security'] = 'none';
  return q;
}

/// vless / trojan / anytls share one shape: credential in the userinfo, TLS
/// and transport in the query.
String? _exportWithQuery(
  ProxyNode node, {
  required String scheme,
  required String? credential,
  Map<String, String> Function()? extraQuery,
  bool includeTransport = true,
}) {
  if (!_hasText(credential)) return null;
  var q = <String, String>{};
  if (extraQuery != null) {
    q = extraQuery();
  } else {
    q = _tlsAndTransportQuery(node, includeTransport: includeTransport);
  }
  return _uri(scheme, credential, node, q);
}

String? _exportHysteria2(ProxyNode node) {
  if (!_hasText(node.secrets.password)) return null;
  final q = _tlsLiteQuery(node);
  if (node.tls.insecure) q['insecure'] = '1';
  // obfs / up / down are not modelled fields, but the importer keeps them in
  // extras; exporting them back keeps a round trip lossless for the values it
  // accepted.
  final obfs = _text(node.extras['obfs']);
  final obfsPassword = _text(node.extras['obfsPassword']);
  if (_hasText(obfsPassword)) {
    q['obfs'] = _hasText(obfs) ? obfs! : 'salamander';
    q['obfs-password'] = obfsPassword!;
  }
  final up = _text(node.extras['upMbps']);
  final down = _text(node.extras['downMbps']);
  if (_hasText(up)) q['up'] = up!;
  if (_hasText(down)) q['down'] = down!;
  return _uri('hysteria2', node.secrets.password, node, q);
}

String? _exportTuic(ProxyNode node) {
  final uuid = node.secrets.uuid;
  if (!_hasText(uuid)) return null;
  final q = _tlsLiteQuery(node);
  if (node.tls.insecure) q['allow_insecure'] = '1';
  final congestion = _text(node.extras['congestionControl']);
  if (_hasText(congestion)) q['congestion_control'] = congestion!;
  return _uri('tuic', '$uuid:${node.secrets.password ?? ''}', node, q);
}

/// SNI / ALPN only: hysteria2 and tuic have no transport block and no REALITY.
Map<String, String> _tlsLiteQuery(ProxyNode node) {
  final q = <String, String>{};
  if (_hasText(node.tls.serverName)) q['sni'] = node.tls.serverName!;
  if (node.tls.alpn.isNotEmpty) q['alpn'] = node.tls.alpn.join(',');
  return q;
}

/// VMess is the base64-JSON form. `pbk`/`sid` ride along for REALITY (our
/// importer reads them; clients that do not simply ignore them), which is
/// strictly more information than v2rayN's own vmess export preserves.
String? _exportVmess(ProxyNode node) {
  final uuid = node.secrets.uuid;
  if (!_hasText(uuid)) return null;
  final t = node.transport;
  final tls = node.tls;
  final doc = <String, Object?>{
    'v': 2,
    'ps': node.name,
    'add': node.server,
    'port': node.port,
    'id': uuid,
    'aid': node.secrets.alterId ?? 0,
    'scy': node.secrets.security ?? 'auto',
    'net': switch (t.kind) {
      TransportKind.tcp => 'tcp',
      TransportKind.ws => 'ws',
      TransportKind.grpc => 'grpc',
      TransportKind.http => 'h2',
      TransportKind.httpUpgrade => 'httpupgrade',
    },
    'type': 'none',
    if (t.kind == TransportKind.ws ||
        t.kind == TransportKind.http ||
        t.kind == TransportKind.httpUpgrade) ...{
      'host': t.host ?? '',
      'path': t.path ?? '',
    },
    if (t.kind == TransportKind.grpc) 'path': t.serviceName ?? '',
    'tls': !tls.enabled
        ? ''
        : tls.kind == TlsKind.reality
            ? 'reality'
            : 'tls',
    if (tls.enabled) ...{
      if (_hasText(tls.serverName)) 'sni': tls.serverName!,
      if (tls.alpn.isNotEmpty) 'alpn': tls.alpn.join(','),
      if (_hasText(tls.fingerprint)) 'fp': tls.fingerprint!,
      if (_hasText(tls.realityPublicKey)) 'pbk': tls.realityPublicKey!,
      if (_hasText(tls.realityShortId)) 'sid': tls.realityShortId!,
    },
    'insecure': tls.insecure ? '1' : '0',
  };
  final json = jsonEncode(doc);
  return 'vmess://${base64.encode(utf8.encode(json))}';
}

/// SIP002: `ss://base64(method:password)@host:port#name`.
///
/// SS plugins (obfs-local / v2ray-plugin) are deliberately not exported: the
/// model has no plugin field, so a ws-transport SS node would export a plugin
/// the app cannot represent or regenerate.
String? _exportShadowsocks(ProxyNode node) {
  final method = node.secrets.method;
  final password = node.secrets.password;
  if (!_hasText(method) || !_hasText(password)) return null;
  final userinfo = base64.encode(utf8.encode('$method:$password')).replaceAll('=', '');
  return _uri('ss', userinfo, node, const {});
}

String? _exportUserPass(ProxyNode node, String scheme) {
  final user = node.secrets.username ?? '';
  final pass = node.secrets.password ?? '';
  final userinfo = user.isEmpty && pass.isEmpty ? null : '$user:$pass';
  return _uri(scheme, userinfo, node, const {});
}

String? _exportNaive(ProxyNode node) {
  final user = node.secrets.username ?? '';
  final pass = node.secrets.password ?? '';
  if (user.isEmpty && pass.isEmpty) return null;
  final q = _tlsLiteQuery(node);
  if (node.tls.insecure) q['allowInsecure'] = '1';
  // The QUIC variant is HTTP/3; the extras flag the v2rayN importer records
  // decides which scheme the link carries.
  final isQuic = _boolFlag(node.extras['naiveQuic']) ||
      _boolFlag((node.extras['v2rayn'] as Map?)?['naiveQuic']);
  final scheme = isQuic ? 'naive+quic' : 'naive+https';
  return _uri(scheme, user.isEmpty ? pass : '$user:$pass', node, q);
}

bool _hasText(Object? value) => value is String && value.isNotEmpty;

String? _text(Object? value) => value is String ? value : null;

bool _boolFlag(Object? value) => value == true || value == 'true';

/// One `scheme://[userinfo@]host:port[?query]#name`, mirroring v2rayN's
/// `BaseFmt.ToUri`: userinfo and query values percent-encoded, IPv6 hosts in
/// brackets, the name in the fragment.
String _uri(
  String scheme,
  String? userinfo,
  ProxyNode node,
  Map<String, String> query,
) {
  final buffer = StringBuffer('$scheme://');
  if (_hasText(userinfo)) {
    // ':' is legal inside userinfo and is the user:password separator, so it
    // must survive: encode each colon-separated part, never the separators.
    //
    // [Uri.encodeComponent] is the exact inverse of the [Uri.decodeComponent]
    // every importer applies to userinfo (`_userInfo`). The previous
    // `encodeQueryComponent` was not: it writes a space as '+' and a literal
    // '+' as '%2B', while `decodeComponent` maps neither back — so a password
    // containing a space re-imported as "pass+phrase". `%20` now comes back as
    // a space and `%2B` as a plus. Exports made before this fix are already
    // lossy for spaces: a stored '+' cannot be told apart from a real '+' and
    // the space it replaced is unrecoverable.
    buffer
      ..write(userinfo!.split(':').map(Uri.encodeComponent).join(':'))
      ..write('@');
  }
  var host = node.server;
  if (host.contains(':') && !host.startsWith('[')) {
    host = '[$host]';
  }
  buffer
    ..write(host)
    ..write(':')
    ..write(node.port);
  if (query.isNotEmpty) {
    buffer..write('?')..write(
      query.entries
          .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'),
    );
  }
  if (node.name.isNotEmpty) {
    buffer..write('#')..write(Uri.encodeComponent(node.name));
  }
  return buffer.toString();
}
