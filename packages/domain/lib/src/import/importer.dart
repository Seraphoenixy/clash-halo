/// Entry point that classifies raw text and dispatches to the right importer.
///
/// Order: explicit URI list -> Clash YAML -> sing-box JSON -> Base64 text
/// subscription -> plain text subscription.
library;

import 'dart:convert';

import 'clash_yaml.dart';
import 'import_result.dart';
import 'share_link.dart';
import 'singbox_json.dart';
import 'v2rayn_json.dart';

/// Detected container format of a subscription body.
enum SourceFormat {
  shareLinks('share_links'),
  clashYaml('clash_yaml'),
  singboxJson('singbox_json'),
  /// v2rayN's exported ProfileItem rows. Distinguished from sing-box JSON by
  /// carrying `ConfigType`/`Remarks` instead of `outbounds`.
  v2rayNJson('v2rayn_json'),
  plainText('plain_text'),
  base64Text('base64_text'),
  unknown('unknown');

  const SourceFormat(this.wire);
  final String wire;
}

SourceFormat detectFormat(String body) {
  final text = body.trim();
  if (text.isEmpty) return SourceFormat.unknown;
  if (text.startsWith('{') || text.startsWith('[')) {
    // v2rayN exports ProfileItem rows: ConfigType + Remarks, no outbounds.
    if (!text.contains('"outbounds"') &&
        text.contains('"ConfigType"') &&
        (text.contains('"Remarks"') || text.contains('"Address"'))) {
      return SourceFormat.v2rayNJson;
    }
    return SourceFormat.singboxJson;
  }
  if (_looksLikeYaml(text)) return SourceFormat.clashYaml;
  if (_hasShareScheme(text)) return SourceFormat.shareLinks;
  final decoded = tryDecodeBase64Body(text);
  if (decoded != null) return SourceFormat.base64Text;
  return SourceFormat.plainText;
}

/// A subscription body may be Base64-wrapped. Returns the decoded text when
/// the decoded result looks like a plausible node list, otherwise null.
String? tryDecodeBase64Body(String body) {
  final compact = body.replaceAll(RegExp(r'\s'), '');
  if (compact.isEmpty) return null;
  var v = compact.replaceAll('-', '+').replaceAll('_', '/');
  final pad = v.length % 4;
  if (pad == 1) return null;
  if (pad > 0) v = v + '=' * (4 - pad);
  try {
    final decoded = utf8.decode(base64.decode(v), allowMalformed: false);
    if (_hasShareScheme(decoded) || _looksLikeYaml(decoded)) {
      final inner = detectFormatUnwrapped(decoded);
      if (inner != SourceFormat.unknown) return decoded;
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Format detection without trying Base64 again (avoids recursion).
SourceFormat detectFormatUnwrapped(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return SourceFormat.unknown;
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    if (!trimmed.contains('"outbounds"') &&
        trimmed.contains('"ConfigType"') &&
        (trimmed.contains('"Remarks"') || trimmed.contains('"Address"'))) {
      return SourceFormat.v2rayNJson;
    }
    return SourceFormat.singboxJson;
  }
  if (_looksLikeYaml(trimmed)) return SourceFormat.clashYaml;
  if (_hasShareScheme(trimmed)) return SourceFormat.shareLinks;
  return SourceFormat.unknown;
}

bool _hasShareScheme(String text) =>
    RegExp(r'(^|\n)\s*(ss|ssr|vmess|vless|trojan|hysteria2|hy2|tuic|socks|socks5|http|https)://',
            caseSensitive: false)
        .hasMatch(text);

bool _looksLikeYaml(String text) =>
    RegExp(r'^(proxies|proxy-groups|proxy:|port:|socks-port:|mixed-port:)\s*:',
            multiLine: true)
        .hasMatch(text) ||
    (text.contains('proxies:') && text.contains('  - '));

/// Parses any supported body, delegating per format.
///
/// Detection and parsing share one pass: a Base64 body is decoded **once**,
/// for the format it actually turns out to be. The old path decoded it inside
/// [detectFormat] and then again here, doubling the decode cost of every
/// Base64 subscription.
ImportResult importNodes(String body, {SourceFormat? forcedFormat}) {
  if (forcedFormat != null) {
    return _parseAs(body, forcedFormat);
  }
  // Same order as [detectFormat]: explicit URI list -> Clash YAML ->
  // sing-box / v2rayN JSON -> Base64 subscription -> plain text.
  final text = body.trim();
  if (text.isEmpty) {
    return const ImportResult(
      sourceFormat: 'unknown',
      failed: [
        ImportIssue(kind: ImportFailureKind.emptyInput, message: '内容为空或格式无法识别'),
      ],
    );
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    // v2rayN exports ProfileItem rows: ConfigType + Remarks, no outbounds.
    if (!text.contains('"outbounds"') &&
        text.contains('"ConfigType"') &&
        (text.contains('"Remarks"') || text.contains('"Address"'))) {
      return parseV2rayNProfiles(body);
    }
    return parseSingboxJson(body);
  }
  if (_looksLikeYaml(text)) return parseClashYaml(body);
  if (_hasShareScheme(text)) return parseShareLinks(body.split('\n'));
  final decoded = tryDecodeBase64Body(text);
  if (decoded != null) {
    // tryDecodeBase64Body already validated that the decoded text is a
    // recognised node list, so the recursive call re-detects it without ever
    // taking the Base64 branch again.
    final inner = importNodes(decoded);
    return ImportResult(
      nodes: inner.nodes,
      skipped: inner.skipped,
      failed: inner.failed,
      sourceFormat: 'base64_text',
    );
  }
  return parseShareLinks(body.split('\n'));
}

/// Parses [body] as [format], with no detection of its own.
ImportResult _parseAs(String body, SourceFormat format) {
  switch (format) {
    case SourceFormat.clashYaml:
      return parseClashYaml(body);
    case SourceFormat.singboxJson:
      return parseSingboxJson(body);
    case SourceFormat.v2rayNJson:
      return parseV2rayNProfiles(body);
    case SourceFormat.base64Text:
      final decoded = tryDecodeBase64Body(body) ?? '';
      if (decoded.isEmpty) {
        return const ImportResult(
          sourceFormat: 'base64_text',
          failed: [
            ImportIssue(kind: ImportFailureKind.decodeError, message: 'Base64 订阅解码失败'),
          ],
        );
      }
      final inner = importNodes(decoded);
      return ImportResult(
        nodes: inner.nodes,
        skipped: inner.skipped,
        failed: inner.failed,
        sourceFormat: 'base64_text',
      );
    case SourceFormat.shareLinks:
    case SourceFormat.plainText:
      return parseShareLinks(body.split('\n'));
    case SourceFormat.unknown:
      return const ImportResult(
        sourceFormat: 'unknown',
        failed: [
          ImportIssue(kind: ImportFailureKind.emptyInput, message: '内容为空或格式无法识别'),
        ],
      );
  }
}
