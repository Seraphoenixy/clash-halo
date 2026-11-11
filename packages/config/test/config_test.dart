import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// The pinned core used for real validation. Tests are skipped when the
/// binary is absent so a fresh checkout can still run unit tests.
final _singbox = File('${Directory.current.path}/prototype/bin/sing-box.exe');

ProxyNode _node(ProxyProtocol protocol,
        {Map<String, String?> secrets = const {},
        TlsConfig tls = const TlsConfig(),
        TransportConfig transport = const TransportConfig(),
        Map<String, Object?> extras = const {},
        String server = 'example.com',
        int port = 443}) =>
    withIdentity(ProxyNode(
      id: '',
      fingerprint: '',
      name: 'test-${protocol.wire}',
      protocol: protocol,
      server: server,
      port: port,
      secrets: NodeSecrets(
        uuid: secrets['uuid'],
        password: secrets['password'],
        method: secrets['method'],
        username: secrets['username'],
        alterId: int.tryParse(secrets['alterId'] ?? ''),
        flow: secrets['flow'],
        security: secrets['security'],
      ),
      tls: tls,
      transport: transport,
      extras: extras,
    ));

ProxyNode _naiveNode({required bool quic}) => _node(
      ProxyProtocol.naive,
      secrets: {'username': 'test-user', 'password': 'test-password'},
      tls: const TlsConfig(kind: TlsKind.tls),
      extras: {if (quic) 'naiveQuic': true},
    );

void main() {
  group('generator structure', () {
    test('enables Naive UDP forwarding over HTTP/2 and HTTP/3', () {
      for (final quic in [false, true]) {
        final result = buildConfig(
          ConfigRequest(node: _naiveNode(quic: quic)),
          CoreCapabilities.singbox114,
        );
        expect(result.ok, isTrue);
        final outbound = (result.config!.document['outbounds'] as List).first as Map;
        expect(outbound['udp_over_tcp'], isTrue);
        expect(outbound['quic'] == true, quic);
      }
    });

    test('encodes DoH URLs as a server, optional port and path', () {
      final node = _node(ProxyProtocol.socks, server: '1.2.3.4', port: 1080);
      Map remote(DnsSettings dns) {
        final result = buildConfig(
          ConfigRequest(node: node, dns: dns),
          CoreCapabilities.singbox114,
        );
        return ((result.config!.document['dns'] as Map)['servers'] as List)
            .first as Map;
      }

      expect(remote(const DnsSettings()), {
        'type': 'https',
        'tag': 'remote',
        'server': '223.5.5.5',
        'path': '/dns-query',
        'detour': 'proxy',
      });
      expect(
        remote(const DnsSettings(server: 'https://[2001:db8::1]:8443/custom')),
        {
          'type': 'https',
          'tag': 'remote',
          'server': '2001:db8::1',
          'server_port': 8443,
          'path': '/custom',
          'detour': 'proxy',
        },
      );
    });

    test('proxy server name is resolved by the direct resolver', () {
      List dnsRules(String server, {bool ipv6 = false}) {
        final result = buildConfig(
          ConfigRequest(
            node: _node(ProxyProtocol.socks, server: server, port: 1080),
            dns: DnsSettings(ipv6: ipv6),
          ),
          CoreCapabilities.singbox114,
        );
        return (result.config!.document['dns'] as Map)['rules'] as List? ??
            const [];
      }

      // Android's Naive outbound resolves its server through the system
      // resolver. Without this rule that query is answered by the proxied DoH
      // resolver, which itself needs the proxy: a deadlock that shows up as a
      // connected VPN with no working traffic.
      expect(dnsRules('img.example.com'), [
        {'domain': ['img.example.com'], 'server': 'local'},
        {'ip_version': 6, 'action': 'predefined', 'rcode': 'NOERROR'},
      ]);
      // An IP literal has nothing to resolve, and sing-box rejects addresses
      // in a `domain` rule.
      expect(dnsRules('203.0.113.7'), [
        {'ip_version': 6, 'action': 'predefined', 'rcode': 'NOERROR'},
      ]);
      expect(dnsRules('203.0.113.7', ipv6: true), isEmpty);
    });

    test('emits a single active proxy outbound and system tags', () {
      final node = _node(ProxyProtocol.trojan,
          secrets: {'password': 'pw'},
          tls: const TlsConfig(kind: TlsKind.tls, serverName: 'example.com'));
      final result = buildConfig(ConfigRequest(node: node), CoreCapabilities.singbox114);
      expect(result.ok, isTrue);
      final doc = result.config!.document;
      final outbounds = (doc['outbounds'] as List).cast<Map<String, Object?>>();
      expect(outbounds.length, 3);
      expect(outbounds.map((o) => o['tag']), ['proxy', 'direct', 'block']);
      expect(outbounds.first['type'], 'trojan');
      expect((doc['route'] as Map)['final'], 'proxy');
      final inbounds = (doc['inbounds'] as List).cast<Map<String, Object?>>();
      expect(inbounds.single['listen'], '127.0.0.1');
      expect(inbounds.single['listen_port'], 7890);
      expect(inbounds.single['set_system_proxy'], isFalse);
    });

    test('clash api is loopback only and can be disabled', () {
      final node = _node(ProxyProtocol.socks, server: '1.2.3.4', port: 1080);
      final on = buildConfig(
          ConfigRequest(node: node, ports: const InboundPorts(clashApi: 9091)),
          CoreCapabilities.singbox114);
      final api = ((on.config!.document['experimental'] as Map)['clash_api'] as Map);
      expect(api['external_controller'], '127.0.0.1:9091');

      final off = buildConfig(
          ConfigRequest(
              node: node, ports: const InboundPorts(enableClashApi: false)),
          CoreCapabilities.singbox114);
      expect((off.config!.document['experimental'] as Map).containsKey('clash_api'),
          isFalse);
      expect(off.config!.clashApiPort, isNull);
    });

    test('direct mode still keeps the node but routes everything direct', () {
      final node = _node(ProxyProtocol.shadowsocks,
          secrets: {'method': 'aes-128-gcm', 'password': 'pw'});
      final result = buildConfig(
          ConfigRequest(node: node, mode: RouteMode.direct), CoreCapabilities.singbox114);
      final route = result.config!.document['route'] as Map;
      expect(route['final'], 'direct');
      expect(result.config!.document.containsKey('dns'), isFalse);
    });

    test('sniff action leads every route mode', () {
      final node = _node(ProxyProtocol.socks, server: '1.2.3.4', port: 1080);
      for (final mode in RouteMode.values) {
        final result = buildConfig(
            ConfigRequest(node: node, mode: mode), CoreCapabilities.singbox114);
        final rules =
            ((result.config!.document['route'] as Map)['rules'] as List)
                .cast<Map>();
        expect(rules.first, {
          'action': 'sniff',
          'sniffer': ['tls', 'http', 'quic'],
          'timeout': '300ms',
        }, reason: mode.wire);
      }
    });

    test('test inbound is added only when a test port is requested', () {
      final node = _node(ProxyProtocol.socks, server: '1.2.3.4', port: 1080);
      final withTest = buildConfig(
          ConfigRequest(node: node, testPort: 7895), CoreCapabilities.singbox114);
      final inbounds = (withTest.config!.document['inbounds'] as List).cast<Map>();
      expect(inbounds.length, 2);
      expect(inbounds.last['tag'], 'test-in');
      expect(withTest.config!.testPort, 7895);
    });

    test('tun inbound uses the requested stack and disables auto_detect_interface', () {
      final node = _node(ProxyProtocol.socks, server: '1.2.3.4', port: 1080);
      final result = buildConfig(
          ConfigRequest(
              node: node,
              tun: const TunSettings(enabled: true, stack: 'gvisor', mtu: 1500)),
          CoreCapabilities.singbox114);
      final inbounds = (result.config!.document['inbounds'] as List).cast<Map>();
      final tun = inbounds.first;
      expect(tun['type'], 'tun');
      expect(tun['stack'], 'gvisor');
      expect(tun['mtu'], 1500);
      expect((result.config!.document['route'] as Map)['auto_detect_interface'], isFalse);
      expect(result.config!.tunInbound, isTrue);
    });

    test('protocol-specific parameters are emitted, not dropped', () {
      final ws = buildConfig(
          ConfigRequest(
            node: _node(ProxyProtocol.vless,
                secrets: {'uuid': 'u-1', 'flow': 'xtls-rprx-vision'},
                tls: const TlsConfig(
                    kind: TlsKind.reality,
                    serverName: 'a.example.com',
                    realityPublicKey: 'pbk',
                    realityShortId: 'sid',
                    fingerprint: 'chrome'),
                transport: const TransportConfig(
                    kind: TransportKind.ws, path: '/ws', host: 'cdn.example.com')),
          ),
          CoreCapabilities.singbox114);
      final proxy = ((ws.config!.document['outbounds'] as List).first as Map);
      expect(proxy['flow'], 'xtls-rprx-vision');
      final tls = proxy['tls'] as Map;
      expect(tls['server_name'], 'a.example.com');
      expect((tls['reality'] as Map)['public_key'], 'pbk');
      expect((tls['reality'] as Map)['short_id'], 'sid');
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      final transport = proxy['transport'] as Map;
      expect(transport['path'], '/ws');
      expect((transport['headers'] as Map)['Host'], 'cdn.example.com');
    });

    test('vmess alterId defaults to zero and explicit security is preserved', () {
      final result = buildConfig(
          ConfigRequest(
              node: _node(ProxyProtocol.vmess, secrets: {'uuid': 'u', 'security': 'aes-128-gcm'})),
          CoreCapabilities.singbox114);
      final proxy = ((result.config!.document['outbounds'] as List).first as Map);
      expect(proxy['alter_id'], 0);
      expect(proxy['security'], 'aes-128-gcm');
    });

    test('generated json is deterministic for the same input', () {
      final node = _node(ProxyProtocol.shadowsocks,
          secrets: {'method': 'aes-256-gcm', 'password': 'pw'});
      final a = buildConfig(ConfigRequest(node: node), CoreCapabilities.singbox114);
      final b = buildConfig(ConfigRequest(node: node), CoreCapabilities.singbox114);
      expect(a.config!.toJsonString(), b.config!.toJsonString());
      expect(jsonDecode(a.config!.toJsonString()), a.config!.document);
    });

    test('strings containing quotes and newlines are escaped', () {
      final node = _node(ProxyProtocol.trojan,
          secrets: {'password': 'a"b\\c'},
          tls: const TlsConfig(kind: TlsKind.tls));
      final json = buildConfig(ConfigRequest(node: node), CoreCapabilities.singbox114)
          .config!
          .toJsonString();
      expect(jsonDecode(json), isA<Map>());
    });

    test('credentials never appear in tags or names', () {
      final node = _node(ProxyProtocol.trojan,
          secrets: {'password': 'super-secret-pw'},
          tls: const TlsConfig(kind: TlsKind.tls));
      final doc = buildConfig(ConfigRequest(node: node), CoreCapabilities.singbox114)
          .config!
          .document;
      final tags = (doc['outbounds'] as List).map((o) => (o as Map)['tag']).toList();
      expect(tags.every((t) => !t.toString().contains('super-secret-pw')), isTrue);
      expect(tags.every((t) => t.toString().length <= 8), isTrue);
    });
  });

  group('capability checks', () {
    test('unsupported protocol is rejected before generation', () {
      final result = buildConfig(
          ConfigRequest(node: _node(ProxyProtocol.ssh)), CoreCapabilities.singbox114);
      expect(result.ok, isFalse);
      expect(result.config, isNull);
      expect(result.issues.single.code, 'unsupported');
      expect(result.issues.single.message, contains('SSH'));
    });

    test('missing required parameters are all reported, not just the first', () {
      final node = _node(ProxyProtocol.vless,
          tls: const TlsConfig(kind: TlsKind.reality));
      final check = checkNode(node, CoreCapabilities.singbox114);
      expect(check.issues.length, 2);
      expect(check.reason, contains('UUID'));
      expect(check.reason, contains('公钥'));
    });

    test('unsupported transport parameter blocks the node', () {
      final node = withIdentity(ProxyNode(
        id: '',
        fingerprint: '',
        name: 'weird',
        protocol: ProxyProtocol.trojan,
        server: 'x.example.com',
        port: 443,
        secrets: const NodeSecrets(password: 'pw'),
        transport: const TransportConfig(
            kind: TransportKind.tcp, headers: {'unsupported_transport': 'kcp'}),
      ));
      final check = checkNode(node, CoreCapabilities.singbox114);
      expect(check.ok, isFalse);
      expect(check.reason, contains('kcp'));
    });

    test('a restricted capability set rejects specific transports', () {
      const noGrpc = CoreCapabilities(
        version: 'test',
        transports: {TransportKind.tcp, TransportKind.ws},
      );
      final node = _node(ProxyProtocol.vless,
          secrets: {'uuid': 'u'},
          transport: const TransportConfig(kind: TransportKind.grpc, serviceName: 's'));
      final check = checkNode(node, noGrpc);
      expect(check.ok, isFalse);
      expect(check.reason, contains('gRPC'));
    });

    test('partition keeps order and reports per-node reasons', () {
      final good = _node(ProxyProtocol.socks, server: '1.2.3.4', port: 1080);
      final bad = _node(ProxyProtocol.hysteria2);
      final split = partitionByCapability([good, bad], CoreCapabilities.singbox114);
      expect(split.usable.map((n) => n.name), ['test-socks']);
      expect(split.rejected.keys.single, bad.id);
      expect(split.rejected.values.single.reason, contains('密码'));
    });
  });

  group('real sing-box validation', () {
    setUpAll(() {
      if (!_singbox.existsSync()) {
        markTestSkipped('sing-box binary not present');
      }
    });

    Map<String, ProxyNode> candidates() => {
          'ss': _node(ProxyProtocol.shadowsocks,
              secrets: {'method': 'aes-256-gcm', 'password': 'pw'}),
          'vmess-ws-tls': _node(ProxyProtocol.vmess,
              secrets: {'uuid': '11111111-1111-1111-1111-111111111111', 'alterId': '0'},
              tls: const TlsConfig(kind: TlsKind.tls, serverName: 'example.com'),
              transport: const TransportConfig(
                  kind: TransportKind.ws, path: '/ws', host: 'example.com')),
          'vless-reality': _node(ProxyProtocol.vless,
              secrets: {'uuid': '11111111-1111-1111-1111-111111111111'},
              tls: const TlsConfig(
                  kind: TlsKind.reality,
                  serverName: 'www.microsoft.com',
                  realityPublicKey:
                      'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
                  fingerprint: 'chrome'),
              transport: const TransportConfig(kind: TransportKind.grpc, serviceName: 'grpc')),
          'vless-ws-httpupgrade': _node(ProxyProtocol.vless,
              secrets: {'uuid': '11111111-1111-1111-1111-111111111111'},
              tls: const TlsConfig(kind: TlsKind.tls),
              transport: const TransportConfig(kind: TransportKind.httpUpgrade, path: '/x')),
          'trojan': _node(ProxyProtocol.trojan,
              secrets: {'password': 'pw'},
              tls: const TlsConfig(kind: TlsKind.tls)),
          'hysteria2': _node(ProxyProtocol.hysteria2,
              secrets: {'password': 'pw'},
              tls: const TlsConfig(kind: TlsKind.tls, serverName: 'example.com'),
              port: 8443),
          'tuic': _node(ProxyProtocol.tuic,
              secrets: {'uuid': '11111111-1111-1111-1111-111111111111', 'password': 'pw'},
              tls: const TlsConfig(kind: TlsKind.tls),
              port: 443),
          'socks': _node(ProxyProtocol.socks, server: '1.2.3.4', port: 1080),
          'http': _node(ProxyProtocol.http, server: '1.2.3.4', port: 8080),
          'naive-h2': _naiveNode(quic: false),
          'naive-h3': _naiveNode(quic: true),
        };

    test('every generated protocol config passes sing-box check', () {
      if (!_singbox.existsSync()) return;
      final dir = Directory.systemTemp.createTempSync('halo-cfg-');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final entry in candidates().entries) {
        final result =
            buildConfig(ConfigRequest(node: entry.value), CoreCapabilities.singbox114);
        expect(result.ok, isTrue, reason: '${entry.key} should support generation');
        final file = File('${dir.path}/${entry.key}.json');
        file.writeAsStringSync(result.config!.toJsonString());
        final check = Process.runSync(_singbox.path, ['check', '-c', file.path]);
        expect(check.exitCode, 0,
            reason: '${entry.key}: ${check.stdout}${check.stderr}');
      }
    });

    test('tun and isolated test inbound config passes sing-box check', () {
      if (!_singbox.existsSync()) return;
      final dir = Directory.systemTemp.createTempSync('halo-cfg-tun-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final result = buildConfig(
        ConfigRequest(
          node: candidates()['trojan']!,
          tun: const TunSettings(enabled: true, stack: 'gvisor', mtu: 1500),
          testPort: 7895,
          ports: const InboundPorts(mixed: 7891, clashApi: 9091),
        ),
        CoreCapabilities.singbox114,
      );
      final file = File('${dir.path}/tun.json');
      file.writeAsStringSync(result.config!.toJsonString());
      final check = Process.runSync(_singbox.path, ['check', '-c', file.path]);
      expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
    });

    test('an invalid config is rejected by the real core', () {
      if (!_singbox.existsSync()) return;
      final dir = Directory.systemTemp.createTempSync('halo-cfg-bad-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/bad.json');
      // An unknown outbound type is a hard decode error; a merely incomplete
      // node is accepted by `check` and would fail at dial time, so this test
      // deliberately uses a structural error.
      file.writeAsStringSync(jsonEncode({
        'outbounds': [
          {'type': 'definitely-not-a-protocol', 'tag': 'proxy', 'server': 'x', 'server_port': 1}
        ]
      }));
      final check = Process.runSync(_singbox.path, ['check', '-c', file.path]);
      expect(check.exitCode, isNot(0));
    });

    test('every route mode actually starts the core, not just `check`', () async {
      if (!_singbox.existsSync()) return;
      final dir = Directory.systemTemp.createTempSync('halo-cfg-run-');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final mode in RouteMode.values) {
        final result = buildConfig(
          ConfigRequest(
            node: candidates()['vmess-ws-tls']!,
            mode: mode,
            logLevel: 'info',
            ports: InboundPorts(
              mixed: await _freePort(),
              enableClashApi: false,
            ),
          ),
          CoreCapabilities.singbox114,
        );
        expect(result.ok, isTrue, reason: mode.wire);
        final file = File('${dir.path}/${mode.name}.json');
        final document = result.config!.document;
        (document['log'] as Map).remove('output');
        file.writeAsStringSync(jsonEncode(document));

        final process = await Process.start(
          _singbox.path,
          ['run', '-c', file.path, '--disable-color'],
          workingDirectory: dir.path,
        );
        final output = StringBuffer();
        final ready = Completer<bool>();
        void readLine(String line) {
          output.writeln(line);
          if (!ready.isCompleted && line.contains('sing-box started')) {
            ready.complete(true);
          }
        }

        final stdoutDone = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(readLine);
        final stderrDone = process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(readLine);
        final exited = process.exitCode;
        try {
          final started = await Future.any([
            ready.future,
            Future.wait([exited, stdoutDone, stderrDone]).then((_) => false),
          ]).timeout(const Duration(seconds: 5), onTimeout: () => false);
          expect(started, isTrue, reason: '${mode.wire} 模式启动失败:\n$output');
        } finally {
          process.kill();
          await Future.wait([exited, stdoutDone, stderrDone]);
        }
      }
    });
  });
}

/// Asks the OS for an unused loopback port.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
