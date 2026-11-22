import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

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

  test('fake-IP is on by default and can be disabled', () {
    expect(const RoutingSettings().fakeIp, isTrue);
    expect(const RoutingSettings().copyWith(fakeIp: false).fakeIp, isFalse);

    final built = const RoutingSettings().build(node());
    expect(built.ok, isTrue);
    final dns = built.config!.document['dns'] as Map;
    expect((dns['servers'] as List).last, {
      'type': 'fakeip',
      'tag': 'fakeip',
      'inet4_range': kFakeIpv4Range,
    });
  });

  test('the unused legacy fake-IP key does not disable the migration', () {
    final dir = Directory.systemTemp.createTempSync('halo-fakeip-migration-');
    final opened = HaloStore.open('${dir.path}/halo.db');
    final repository = SettingsRepository(opened.store!);
    try {
      repository.setRaw('routing.fakeIp', '0');
      expect(RoutingSettings.load(repository).fakeIp, isTrue);

      const RoutingSettings(fakeIp: false).save(repository);
      expect(RoutingSettings.load(repository).fakeIp, isFalse);
      expect(repository.raw('routing.fakeIp.v1'), '0');
    } finally {
      opened.store!.close();
      dir.deleteSync(recursive: true);
    }
  });

  test(
    'LAN CIDRs persist, validate and generate a direct rule in every mode',
    () {
      final dir = Directory.systemTemp.createTempSync('halo-lan-cidrs-');
      final opened = HaloStore.open('${dir.path}/halo.db');
      final repository = SettingsRepository(opened.store!);
      try {
        repository.setRaw(
          'routing.lanCidrs.v1',
          jsonEncode([
            '100.64.0.0/10',
            'FD7A:115C:A1E0::/48',
            '100.64.0.0/10',
            'not-a-cidr',
          ]),
        );
        final settings = RoutingSettings.load(repository);
        expect(settings.lanCidrs, ['100.64.0.0/10', 'fd7a:115c:a1e0::/48']);

        for (final mode in RouteMode.values) {
          final built = settings.copyWith(mode: mode).build(node());
          expect(built.ok, isTrue);
          final rules =
              ((built.config!.document['route'] as Map)['rules'] as List)
                  .cast<Map>();
          final lanAt = rules.indexWhere(
            (rule) => rule['ip_cidr'] == settings.lanCidrs,
          );
          final sniffAt = rules.indexWhere((rule) => rule['action'] == 'sniff');
          expect(lanAt, greaterThanOrEqualTo(0), reason: mode.wire);
          expect(lanAt, lessThan(sniffAt), reason: mode.wire);
          expect(rules[lanAt]['outbound'], 'direct', reason: mode.wire);
        }
      } finally {
        opened.store!.close();
        dir.deleteSync(recursive: true);
      }
    },
  );

  test('IPv6 off suppresses AAAA while leaving A answers resolver-routed', () {
    final off = buildConfig(
      ConfigRequest(node: node(), dns: const DnsSettings(ipv6: false)),
      CoreCapabilities.singbox114,
    );
    expect(off.ok, isTrue);
    final offDns = off.config!.document['dns'] as Map;
    expect(
      (offDns['rules'] as List)
          .cast<Map>()
          .where((rule) => rule['ip_version'] == 6)
          .single,
      {'ip_version': 6, 'action': 'predefined', 'rcode': 'NOERROR'},
    );

    final on = buildConfig(
      ConfigRequest(node: node(), dns: const DnsSettings(ipv6: true)),
      CoreCapabilities.singbox114,
    );
    expect(on.ok, isTrue);
    final onDns = on.config!.document['dns'] as Map;
    expect(
      (onDns['rules'] as List).cast<Map>().where(
        (rule) => rule['ip_version'] == 6,
      ),
      isEmpty,
    );
  });

  test('without TUN the generator already detects the interface', () {
    final desktop = const RoutingSettings().build(node());
    expect(desktop.ok, isTrue);
    final route = desktop.config!.document['route'] as Map;
    expect(route['auto_detect_interface'], isTrue);
  });
}
