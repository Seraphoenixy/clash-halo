import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// The AnyTLS outbound the generator emits for a node imported from a real
/// subscription.
///
/// Verified against the shipped core: `sing-box 1.14.4 check` accepts exactly
/// this document, and a request through it returns 204.
void main() {
  ProxyNode anytlsNode() => ProxyNode(
    id: 'n1',
    fingerprint: 'fp',
    name: '香港01',
    protocol: ProxyProtocol.anytls,
    server: 'r1336631.edge.example.com',
    port: 443,
    secrets: const NodeSecrets(password: 'p@ss'),
    tls: const TlsConfig(
      kind: TlsKind.tls,
      serverName: 'node-1.example.com',
      alpn: ['h2', 'http/1.1'],
      fingerprint: 'chrome',
    ),
    source: NodeSourceKind.subscription,
  );

  ConfigBuildResult build(ProxyNode node) => buildConfig(
    ConfigRequest(
      node: node,
      mode: RouteMode.global,
      ports: const InboundPorts(enableClashApi: false),
    ),
    CoreCapabilities.singbox114,
  );

  test('anytls is a supported protocol for the pinned core', () {
    expect(CoreCapabilities.singbox114.protocols, contains(ProxyProtocol.anytls));
  });

  test('the outbound carries the password and the TLS block', () {
    final built = build(anytlsNode());
    expect(built.ok, isTrue, reason: built.issues.map((i) => i.message).join('；'));
    final doc = built.config!.document;
    final outbound = (doc['outbounds'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((o) => o['tag'] == 'proxy');
    expect(outbound['type'], 'anytls');
    expect(outbound['server'], 'r1336631.edge.example.com');
    expect(outbound['server_port'], 443);
    expect(outbound['password'], 'p@ss');
    final tls = outbound['tls'] as Map<String, Object?>;
    expect(tls['enabled'], isTrue);
    expect(tls['server_name'], 'node-1.example.com');
    expect(tls['alpn'], ['h2', 'http/1.1']);
    expect(tls['utls'], {'enabled': true, 'fingerprint': 'chrome'});
  });

  test('a node without a password is refused, not degraded', () {
    final node = anytlsNode().copyWith(secrets: const NodeSecrets());
    final built = build(node);
    expect(built.ok, isFalse);
    expect(
      built.issues.map((i) => i.message).join('；'),
      contains('AnyTLS 缺少密码'),
    );
  });

  test('an insecure node emits insecure TLS rather than nothing', () {
    final node = anytlsNode().copyWith(
      tls: const TlsConfig(kind: TlsKind.tls, serverName: 'a', insecure: true),
    );
    final outbound = (build(node).config!.document['outbounds'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((o) => o['tag'] == 'proxy');
    expect((outbound['tls'] as Map<String, Object?>)['insecure'], true);
  });
}
