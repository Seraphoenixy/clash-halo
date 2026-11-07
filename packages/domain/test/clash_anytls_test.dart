import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// AnyTLS and implicit TLS, both found by running a real airport subscription
/// through the importer.
///
/// The subscription served a Clash document whose TLS is implicit: AnyTLS,
/// Hysteria2, TUIC and Trojan omit `tls: true` because TLS is part of the
/// protocol. Importing them as "no TLS" produced documents the core rejects
/// with `initialize outbound: TLS required`, so 39 AnyTLS and 4 Hysteria2 nodes
/// looked imported and could never connect.
void main() {
  Map<String, Object?> anytlsEntry() => {
    'name': '香港01',
    'type': 'anytls',
    'server': 'r1336631.edge.example.com',
    'port': 443,
    'password': 'eb85f7d7-0000-0000-0000-000000000000',
    'alpn': ['h2', 'http/1.1'],
    'skip-cert-verify': false,
    'udp': true,
    'client-fingerprint': 'chrome',
    'sni': 'node-1.example.com',
  };

  test('an anytls entry keeps its password and its TLS parameters', () {
    final result = parseClashProxy(anytlsEntry(), line: 1);
    expect(result.issue, isNull, reason: '${result.issue?.message}');
    final node = result.node!;
    expect(node.protocol, ProxyProtocol.anytls);
    expect(node.secrets.password, 'eb85f7d7-0000-0000-0000-000000000000');
    // AnyTLS is TLS by definition, so TlsKind.none here is the bug this pins.
    expect(node.tls.kind, TlsKind.tls);
    expect(node.tls.serverName, 'node-1.example.com');
    expect(node.tls.alpn, ['h2', 'http/1.1']);
    expect(node.tls.fingerprint, 'chrome');
    expect(node.tls.insecure, isFalse);
  });

  test('skip-cert-verify becomes an insecure TLS block', () {
    final result = parseClashProxy({
      'name': 'h2',
      'type': 'anytls',
      'server': 'a.example.com',
      'port': 443,
      'password': 'p',
      'skip-cert-verify': true,
      'sni': 'a.example.com',
    }, line: 1);
    expect(result.node!.tls.kind, TlsKind.tls);
    expect(result.node!.tls.insecure, isTrue);
  });

  test('protocols whose TLS is not optional never import as plain', () {
    // Each of these carries TLS in the protocol itself; a Clash config omits
    // the `tls:` key for exactly that reason.
    for (final type in ['hysteria2', 'trojan', 'tuic']) {
      final result = parseClashProxy({
        'name': type,
        'type': type,
        'server': 'a.example.com',
        'port': 443,
        'password': 'p',
        'sni': 'a.example.com',
        'skip-cert-verify': true,
      }, line: 1);
      final node = result.node;
      expect(node, isNotNull, reason: '$type 应能解析：${result.issue?.message}');
      expect(
        node!.tls.kind,
        TlsKind.tls,
        reason: '$type 的 TLS 是协议固有的，不能导入成 TlsKind.none',
      );
    }
  });

  test('a protocol whose TLS is optional still defaults to no TLS', () {
    // The counter-case: vmess without `tls: true` really is plaintext, and
    // forcing TLS on it would break every working non-TLS vmess node.
    final result = parseClashProxy({
      'name': 'v',
      'type': 'vmess',
      'server': 'a.example.com',
      'port': 443,
      'uuid': '11111111-2222-3333-4444-555555555555',
      'cipher': 'auto',
    }, line: 1);
    expect(result.node!.tls.kind, TlsKind.none);
  });

  test('a document mixing anytls with known protocols imports them all', () {
    final result = importNodes('''
proxies:
  - { name: a1, type: anytls, server: a.example.com, port: 443, password: p1, sni: a.example.com }
  - { name: a2, type: anytls, server: b.example.com, port: 443, password: p2, sni: b.example.com }
  - { name: v1, type: vmess, server: c.example.com, port: 443, uuid: u1, cipher: auto, tls: true, servername: c.example.com }
  - { name: h1, type: hysteria2, server: d.example.com, port: 443, password: p3, skip-cert-verify: true }
''');
    expect(result.sourceFormat, 'clash_yaml');
    expect(result.failed, isEmpty);
    expect(result.nodes.map((n) => n.protocol), [
      ProxyProtocol.anytls,
      ProxyProtocol.anytls,
      ProxyProtocol.vmess,
      ProxyProtocol.hysteria2,
    ]);
  });

  test('an unknown protocol still fails without taking the list down', () {
    // `mieru` stands in for any node type this build does not implement: the
    // entry is reported and the rest of the list survives.
    final result = importNodes('''
proxies:
  - { name: a1, type: anytls, server: a.example.com, port: 443, password: p1 }
  - { name: m1, type: mieru, server: b.example.com, port: 443, password: p2 }
''');
    expect(result.nodes, hasLength(1));
    expect(result.failed, hasLength(1));
    expect(result.failed.single.message, contains('不支持的协议'));
  });
}
