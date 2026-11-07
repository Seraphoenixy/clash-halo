/// Connection-identity fingerprinting.
///
/// Two nodes are the same connection only when protocol, endpoint, credentials
/// and transport/TLS parameters all match after canonicalisation. Names are
/// explicitly excluded, which is why renaming never re-identifies a node.
library;

import 'dart:convert';

import 'models/node.dart';

/// Canonical, order-stable string for the connection identity.
String canonicalIdentity(ProxyNode node) {
  final headers = node.transport.headers.keys.toList()..sort();
  return <String>[
    node.protocol.wire,
    node.server.trim().toLowerCase(),
    '${node.port}',
    node.secrets.identityKey,
    node.transport.kind.wire,
    node.transport.path ?? '',
    node.transport.host ?? '',
    node.transport.serviceName ?? '',
    headers.map((k) => '$k=${node.transport.headers[k]}').join('&'),
    node.transport.earlyData?.toString() ?? '',
    node.tls.identityKey,
    connectionVariant(node),
  ].join('\u0002');
}

/// Extra identity for outbounds whose wire format is switched outside the
/// transport and TLS blocks. Naive HTTP/2 and HTTP/3 are different connections
/// to the same host:port; without this they fingerprint identically and the
/// second import would overwrite the first.
String connectionVariant(ProxyNode node) {
  final extra = node.extras['v2rayn'];
  if (extra is! Map) return '';
  return extra['naiveQuic'] == true ? 'quic' : '';
}

/// Deterministic 32-bit fallback hash (FNV-1a) used only when SHA-256 is not
/// available, e.g. inside a pure-Dart unit test without crypto import.
int fnv1a32(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Deterministic node id from the canonical identity. Uses a stable digest so
/// that re-importing the same connection does not create a second node.
String nodeIdFor(String canonical, {DigestFn? digest}) {
  final d = digest ?? defaultDigest;
  return d(canonical);
}

typedef DigestFn = String Function(String input);

/// Default digest: a 96-bit FNV-1a expansion (64-bit plus 32-bit) over the
/// UTF-16 code units of the canonical identity.
///
/// This is an identifier, not a security boundary. It is not SHA-256 and no
/// crypto provider exists; a deliberate collision is cheap at 96 non-crypto
/// bits. Switching to SHA-256 would change every persisted id and needs an
/// explicit data migration, so the comment states what the code does rather
/// than what a future version might do.
String defaultDigest(String input) {
  final fnv = fnv1a64(input);
  return '${fnv}_${fnv1a32(input)}';
}

int fnv1a64(String input) {
  // 64-bit FNV-1a implemented with two 32-bit lanes to stay portable across
  // web and native targets without BigInt in the hot path.
  var hi = 0xcbf29ce4;
  var lo = 0x84222325;
  for (final unit in input.codeUnits) {
    lo ^= unit;
    // multiply by 0x100000001b3 = (2^40 + 0x1b3)
    final lo2 = (lo * 0x1b3) & 0xFFFFFFFF;
    final hi2 = (hi * 0x1b3 + ((lo * 0x1b3) >> 32)) & 0xFFFFFFFF;
    hi = (hi2 + (lo2 << 8) + (lo2 >> 24)) & 0xFFFFFFFF;
    lo = lo2;
  }
  return (hi << 32) | lo;
}

/// Recomputes [ProxyNode.fingerprint] and [ProxyNode.id] for a node.
ProxyNode withIdentity(ProxyNode node, {DigestFn? digest}) {
  final canonical = canonicalIdentity(node);
  final fingerprint = nodeIdFor(canonical, digest: digest);
  return node.copyWith(fingerprint: fingerprint, id: 'n_$fingerprint');
}

/// Normalised name used for dedupe reporting only, never for identity.
String normalizedName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Duplicate groups keyed by fingerprint. Order follows first appearance.
Map<String, List<ProxyNode>> groupDuplicates(Iterable<ProxyNode> nodes) {
  final groups = <String, List<ProxyNode>>{};
  for (final node in nodes) {
    final key = node.fingerprint.isEmpty ? canonicalIdentity(node) : node.fingerprint;
    groups.putIfAbsent(key, () => []).add(node);
  }
  return {
    for (final e in groups.entries)
      if (e.value.length > 1) e.key: e.value,
  };
}

/// Returns one node per fingerprint, keeping the first occurrence and dropping
/// later duplicates.
List<ProxyNode> dedupeNodes(Iterable<ProxyNode> nodes) {
  final seen = <String>{};
  final out = <ProxyNode>[];
  for (final node in nodes) {
    final key = node.fingerprint.isEmpty ? canonicalIdentity(node) : node.fingerprint;
    if (seen.add(key)) out.add(node);
  }
  return out;
}

/// Debug helper used by tests and the fixture generator.
String describeIdentity(ProxyNode node) =>
    base64Url.encode(utf8.encode(canonicalIdentity(node)));
