import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';

/// The Android config is the Windows document plus a forced
/// `route.auto_detect_interface`. Removing that assignment makes the first
/// expectation fail, which is the point: the field is what makes the core
/// protect its own sockets instead of routing them back into tun0.
void main() {
  ProxyNode node() => ProxyNode(
    id: 'n1',
    fingerprint: 'fp',
    name: 'n1',
    protocol: ProxyProtocol.trojan,
    server: 'a.example.com',
    port: 443,
    secrets: const NodeSecrets(password: 'p'),
    tls: const TlsConfig(kind: TlsKind.tls, serverName: 'a.example.com'),
    source: NodeSourceKind.manual,
  );

  test('withTun forces route.auto_detect_interface to true', () {
    final tuned = const RoutingSettings().build(node(), withTun: true);
    expect(
      tuned.ok,
      isTrue,
      reason: tuned.issues.map((issue) => issue.message).join('；'),
    );
    final route = tuned.config!.document['route'] as Map;
    expect(route['auto_detect_interface'], isTrue);
  });

  test('the generator alone would leave it false when TUN is enabled', () {
    // This is the value RoutingSettings.build has to override. If the
    // generator ever starts emitting true here, the override is no longer the
    // thing keeping protect() working and this test must be revisited.
    final raw = buildConfig(
      ConfigRequest(node: node(), tun: const TunSettings(enabled: true)),
      CoreCapabilities.singbox114,
    );
    expect(raw.ok, isTrue);
    final route = raw.config!.document['route'] as Map;
    expect(route['auto_detect_interface'], isFalse);
  });

  test('IPv6 is off by default and can be enabled', () {
    expect(const RoutingSettings().ipv6, isFalse);
    expect(const RoutingSettings().copyWith(ipv6: true).ipv6, isTrue);
  });

  test('IPv6 off rejects AAAA answers, on leaves them to the resolver', () {
    final off = buildConfig(
      ConfigRequest(node: node(), dns: const DnsSettings(ipv6: false)),
      CoreCapabilities.singbox114,
    );
    expect(off.ok, isTrue);
    final offDns = off.config!.document['dns'] as Map;
    expect(
      (offDns['rules'] as List).single,
      {'ip_version': 6, 'action': 'reject'},
    );

    final on = buildConfig(
      ConfigRequest(node: node(), dns: const DnsSettings(ipv6: true)),
      CoreCapabilities.singbox114,
    );
    expect(on.ok, isTrue);
    final onDns = on.config!.document['dns'] as Map;
    expect(onDns['rules'], isNull);
  });

  test('without TUN the generator already detects the interface', () {
    final desktop = const RoutingSettings().build(node());
    expect(desktop.ok, isTrue);
    final route = desktop.config!.document['route'] as Map;
    expect(route['auto_detect_interface'], isTrue);
  });
}
