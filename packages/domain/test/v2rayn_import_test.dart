import 'dart:convert';

import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// v2rayN profile import.
///
/// The five profiles this project actually had to ingest are the fixtures: one
/// VLESS over WebSocket and four Naive, all with a pinned private root CA.
/// Two v2rayN details are easy to get subtly wrong and are pinned here: the
/// `ConfigType` numbers are not the order the protocols are listed in, and the
/// UUID of a VMess/VLESS node lives in the `Password` column while `Id` is
/// empty. Naive is equally easy to get wrong — HTTP/3 is a per-outbound `quic`
/// flag, and the CA has to be inlined into `tls.certificate` — so both are
/// asserted here
/// rather than left to a live connection test.
void main() {
  const caPem = '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----';

  Map<String, Object?> profile({
    required int type,
    required String remarks,
    String address = 'img.example.test',
    int port = 443,
    String? username,
    String? password,
    String network = '',
    String streamSecurity = 'tls',
    String? sni,
    String? cert,
    String? protoExtra,
  }) =>
      <String, Object?>{
        'ConfigType': type,
        'Remarks': remarks,
        'Address': address,
        'Port': port,
        'Username': username,
        'Password': password,
        'Network': network,
        'StreamSecurity': streamSecurity,
        'Sni': sni,
        'Cert': cert,
        'ProtoExtra': protoExtra,
        'IndexId': 'idx-$remarks',
      };

  group('parseV2rayNProfiles', () {
    test('imports a Naive profile with CA pinning and QUIC', () {
      final body = jsonEncode([
        profile(
          type: 12,
          remarks: 'CN-Naive-H3',
          username: 'naive',
          password: 'secret',
          sni: 'img.example.test',
          cert: caPem,
          protoExtra: '{"Uot":true,"NaiveQuic":true}',
        ),
      ]);

      final result = parseV2rayNProfiles(body);
      expect(result.nodes, hasLength(1));
      expect(result.failed, isEmpty);
      expect(result.skipped, isEmpty);

      final node = result.nodes.single;
      expect(node.protocol, ProxyProtocol.naive);
      expect(node.name, 'CN-Naive-H3');
      expect(node.server, 'img.example.test');
      expect(node.port, 443);
      expect(node.secrets.username, 'naive');
      expect(node.secrets.password, 'secret');
      // Naive is HTTPS even when v2rayN leaves StreamSecurity empty.
      expect(node.tls.kind, TlsKind.tls);
      expect(node.tls.serverName, 'img.example.test');
      expect(node.tls.certificatePem, caPem);
      expect((node.extras['v2rayn'] as Map)['naiveQuic'], isTrue);
    });

    test('imports VLESS over WebSocket with its transport', () {
      // ConfigType 5 is VLESS in v2rayN's EConfigType, and the row below is the
      // shape a real guiNDB.db has for CN-WS-CDN: an Id (UUID) credential, a ws
      // network, and — crucially — the path and host in TransportExtra, with the
      // Path/RequestHost columns empty.
      //
      // Both were wrong before: the protocol came out as Trojan, and the path
      // was dropped so the node could never handshake.
      final body = jsonEncode([
        {
          ...profile(
            type: 5,
            remarks: 'CN-WS-CDN',
            address: 'api.example.test',
            network: 'ws',
            sni: 'api.example.test',
          ),
          'Id': 'c0ca7deb-97e1-44e7-b346-624e0f029f12',
          'Password': '',
          'TransportExtra': '{"Host":"api.example.test","Path":"/channel-abc"}',
          'Alpn': 'http/1.1',
        },
      ]);

      final result = parseV2rayNProfiles(body);
      final node = result.nodes.single;
      expect(node.protocol, ProxyProtocol.vless);
      expect(node.transport.kind, TransportKind.ws);
      expect(node.secrets.uuid, 'c0ca7deb-97e1-44e7-b346-624e0f029f12');
      expect(node.transport.path, '/channel-abc');
      expect(node.transport.host, 'api.example.test');
      expect(node.tls.kind, TlsKind.tls);
      expect(node.tls.alpn, ['http/1.1']);
    });

    test('ConfigType 6 is Trojan, not an unsupported HTTP proxy', () {
      // It used to land in the skipped bucket, so a real Trojan node silently
      // never reached the list.
      final body = jsonEncode([
        profile(type: 6, remarks: 'US-Trojan', password: 'pw'),
      ]);
      final result = parseV2rayNProfiles(body);
      expect(result.nodes.single.protocol, ProxyProtocol.trojan);
      expect(result.skipped, isEmpty);
      // Trojan really does keep its secret in Password; only VMess/VLESS move
      // the UUID there.
      expect(result.nodes.single.secrets.password, 'pw');
    });

    test('a VMess/VLESS UUID comes from the Password column', () {
      // v2rayN's own outbound builder does `id = _node.Password` for both
      // protocols, and the Id column is empty on a real row. Reading Id alone
      // gave a node that looked fine and then refused to generate.
      for (final entry in {
        5: 'vless',
        1: 'vmess',
      }.entries) {
        final body = jsonEncode([
          {
            ...profile(
              type: entry.key,
              remarks: 'U${entry.key}',
              network: 'ws',
            ),
            'Id': '',
            'Password': 'c0ca7deb-97e1-44e7-b346-624e0f029f12',
          },
        ]);
        final node = parseV2rayNProfiles(body).nodes.single;
        expect(node.secrets.uuid, 'c0ca7deb-97e1-44e7-b346-624e0f029f12',
            reason: '${entry.value} 的 UUID 在 Password 列');
        expect(node.secrets.password, isNull,
            reason: 'Password 列装的是 UUID，不能同时当密码');
      }
    });

    test('a v2rayN VLESS node generates a usable outbound', () {
      // The end-to-end case behind the report: this node is the one in the list,
      // and before the fixes it built as Trojan with no path and no uuid.
      final body = jsonEncode([
        {
          ...profile(
            type: 5,
            remarks: 'CN-WS-CDN',
            address: 'api.301998.xyz',
            network: 'ws',
            sni: 'api.301998.xyz',
          ),
          'Id': '',
          'Password': 'c0ca7deb-97e1-44e7-b346-624e0f029f12',
          'Alpn': 'http/1.1',
          'TransportExtra':
              '{"Host":"api.301998.xyz","Path":"/channel-Xyty8H6L2Fo88TweOiUv9g8HaCjUl0qA"}',
        },
      ]);
      final node = parseV2rayNProfiles(body).nodes.single;
      final built = buildConfig(
        ConfigRequest(
          node: node,
          mode: RouteMode.global,
          ports: const InboundPorts(enableClashApi: false),
        ),
        CoreCapabilities.singbox114,
      );
      expect(built.ok, isTrue,
          reason: built.issues.map((i) => i.message).join('；'));

      final outboundJson = jsonDecode(built.config!.toJsonString());
      final outbound = (outboundJson['outbounds'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((o) => o['tag'] == 'proxy');
      expect(outbound['type'], 'vless');
      expect(outbound['uuid'], 'c0ca7deb-97e1-44e7-b346-624e0f029f12');
      final transport =
          (outbound['transport'] as Map).cast<String, Object?>();
      expect(transport['type'], 'ws');
      expect(transport['path'], '/channel-Xyty8H6L2Fo88TweOiUv9g8HaCjUl0qA');
      expect((transport['headers'] as Map)['Host'], 'api.301998.xyz');
    });

    test('every supported ConfigType maps to the protocol v2rayN means', () {
      // One table, checked against the enum rather than against a remembered
      // mapping: a shifted entry imports cleanly and only fails at connect.
      const expected = {
        1: ProxyProtocol.vmess,
        3: ProxyProtocol.shadowsocks,
        4: ProxyProtocol.socks,
        5: ProxyProtocol.vless,
        6: ProxyProtocol.trojan,
        7: ProxyProtocol.hysteria2,
        10: ProxyProtocol.http,
        12: ProxyProtocol.naive,
      };
      for (final entry in expected.entries) {
        final body = jsonEncode([
          profile(
            type: entry.key,
            remarks: 'T${entry.key}',
            password: 'pw',
          ),
        ]);
        final result = parseV2rayNProfiles(body);
        expect(result.nodes.single.protocol, entry.value,
            reason: 'ConfigType ${entry.key} 应映射为 ${entry.value.label}');
      }
    });

    test('types this project cannot carry are reported, not dropped', () {
      for (final type in [2, 8, 9, 11, 13, 14, 101, 102]) {
        final body = jsonEncode([profile(type: type, remarks: 'U$type')]);
        final result = parseV2rayNProfiles(body);
        expect(result.nodes, isEmpty, reason: 'ConfigType $type 不能导入');
        expect(result.skipped, isNotEmpty, reason: 'ConfigType $type 必须报告');
        expect(result.skipped.single.kind, ImportFailureKind.unsupportedProtocol);
      }
    });

    test('every imported node carries its own identity', () {
      // The importer used to leave `fingerprint` empty on every node. The
      // repository stores by fingerprint, so an empty one meant "no identity":
      // a five-row export was written as ONE row literally named `n_`, last
      // row winning and the other four lost. The bug was invisible here because
      // this test file called withIdentity() itself before comparing.
      final body = jsonEncode([
        profile(type: 5, remarks: 'CN-WS-CDN'),
        profile(type: 12, remarks: 'CN-Naive-H2', protoExtra: '{"NaiveQuic":false}'),
        profile(type: 12, remarks: 'CN-Naive-H3', protoExtra: '{"NaiveQuic":true}'),
      ]);

      final result = parseV2rayNProfiles(body);
      expect(result.nodes, hasLength(3));

      for (final node in result.nodes) {
        expect(node.fingerprint, isNotEmpty,
            reason: '${node.name} 必须自带指纹，否则入库时没有身份');
        expect(node.id, isNotEmpty, reason: '${node.name} 的 id 必须由指纹派生');
      }
      // Three distinct connections, so three distinct identities — the check
      // that would have caught all three being stored over each other.
      expect(result.nodes.map((n) => n.fingerprint).toSet(), hasLength(3));
      expect(result.nodes.map((n) => n.id).toSet(), hasLength(3));
    });

    test('HTTP/2 and HTTP/3 of the same host stay separate nodes', () {
      // Same address and credentials, different wire format. They used to hash
      // to one fingerprint, so importing both kept only one node.
      final body = jsonEncode([
        profile(type: 12, remarks: 'CN-Naive-H2', password: 'x',
            protoExtra: '{"NaiveQuic":false}'),
        profile(type: 12, remarks: 'CN-Naive-H3', password: 'x',
            protoExtra: '{"NaiveQuic":true}'),
      ]);

      final result = parseV2rayNProfiles(body);
      expect(result.nodes, hasLength(2));

      final ids = result.nodes.map((n) => n.fingerprint).toSet();
      expect(ids, hasLength(2),
          reason: 'H2 与 H3 是不同的连接，指纹必须不同');
    });

    test('reports unsupported protocols instead of dropping them', () {
      // 9 is WireGuard in v2rayN's EConfigType, which this project cannot carry;
      // 12 is Naive, which it can. The old version of this test used 7 here and
      // labelled it WireGuard — 7 is actually Hysteria2, so it passed only
      // because both sides of the shift were wrong in the same direction.
      final body = jsonEncode([
        profile(type: 9, remarks: 'WireGuard node'),
        profile(type: 12, remarks: 'Naive node', password: 'x'),
      ]);

      final result = parseV2rayNProfiles(body);
      expect(result.nodes, hasLength(1));
      expect(result.skipped, hasLength(1));
      expect(result.skipped.single.message, contains('WireGuard node'));
      expect(result.nodes.single.protocol, ProxyProtocol.naive);
    });

    test('importNodes routes a v2rayN export to this parser', () {
      // The subscription box pastes whatever the user has; a v2rayN export must
      // not be mistaken for a sing-box document (both are JSON).
      final body = jsonEncode([
        profile(type: 12, remarks: 'Naive node', password: 'x', cert: caPem),
      ]);
      expect(detectFormat(body), SourceFormat.v2rayNJson);

      final imported = importNodes(body);
      expect(imported.nodes.single.protocol, ProxyProtocol.naive);
      expect(imported.sourceFormat, 'v2rayn_json');
    });

    test('a sing-box document is still recognised as sing-box', () {
      final body = jsonEncode({
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'}
        ]
      });
      expect(detectFormat(body), SourceFormat.singboxJson);
    });

    test('rejects a body that is not a profile list', () {
      final result = parseV2rayNProfiles('{"nope": 1}');
      expect(result.nodes, isEmpty);
      expect(result.failed.single.kind, ImportFailureKind.decodeError);
    });
  });

  group('buildConfig for Naive', () {
    test('keeps QUIC after a Naive share-link round trip', () {
      final original = importNodes('naive+quic://user:pass@example.com:443');
      final link = shareLinkFor(original.nodes.single)!;
      final node = importNodes(link).nodes.single;
      final result = buildConfig(
        ConfigRequest(node: node),
        CoreCapabilities.singbox114,
      );
      final proxy = (result.config!.document['outbounds'] as List).first as Map;
      expect(proxy['quic'], isTrue);
    });

    ProxyNode naiveNode({bool quic = true, String? cert}) => ProxyNode(
          id: '',
          fingerprint: '',
          name: 'CN-Naive-H3',
          protocol: ProxyProtocol.naive,
          server: 'img.example.test',
          port: 443,
          secrets: const NodeSecrets(username: 'naive', password: 'secret'),
          tls: TlsConfig(
            kind: TlsKind.tls,
            serverName: 'img.example.test',
            certificatePem: cert ?? caPem,
          ),
          extras: {
            'v2rayn': {if (quic) 'naiveQuic': true},
          },
        );

    test('emits a naive outbound with quic and the pinned certificate', () {
      final result =
          buildConfig(ConfigRequest(node: naiveNode()), CoreCapabilities.singbox114);
      expect(result.ok, isTrue, reason: '${result.issues.map((i) => i.message)}');

      final outbacks = result.config!.document['outbounds'] as List;
      final proxy = outbacks.firstWhere((o) => (o as Map)['tag'] == 'proxy') as Map;
      expect(proxy['type'], 'naive');
      expect(proxy['username'], 'naive');
      expect(proxy['password'], 'secret');
      expect(proxy['quic'], isTrue);

      final tls = proxy['tls'] as Map;
      expect(tls['enabled'], isTrue);
      expect(tls['server_name'], 'img.example.test');
      expect(tls['certificate'], caPem);
    });

    test('omits quic for an HTTP/2 node', () {
      final result = buildConfig(
          ConfigRequest(node: naiveNode(quic: false)), CoreCapabilities.singbox114);
      final proxy = (result.config!.document['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'proxy') as Map;
      expect(proxy.containsKey('quic'), isFalse);
    });

    test('a Naive node without a password is refused before generation', () {
      final node = ProxyNode(
        id: '',
        fingerprint: '',
        name: 'no-pass',
        protocol: ProxyProtocol.naive,
        server: 'img.example.test',
        port: 443,
        tls: TlsConfig(kind: TlsKind.tls, serverName: 'img.example.test'),
      );
      final result = buildConfig(ConfigRequest(node: node), CoreCapabilities.singbox114);
      expect(result.ok, isFalse);
      expect(result.issues.single.message, contains('Naive 缺少密码'));
    });
  });
}
