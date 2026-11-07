/// Share-link export tests.
///
/// Two properties are pinned per protocol:
///  1. the link matches the v2rayN URI shape (the interchange format other
///     clients read), and
///  2. export → parseShareLink round-trips the node — identity fields,
///     transport and TLS all survive, because a link the app itself cannot
///     re-import is a one-way trap for the user's own data.
library;

import 'dart:convert';

import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

ProxyNode _node({
  String name = 'n',
  String server = 'example.com',
  int port = 443,
  ProxyProtocol protocol = ProxyProtocol.trojan,
  String? password = 'secret',
  String? uuid,
  String? method,
  String? username,
  String? security,
  int? alterId,
  String? flow,
  TransportConfig transport = const TransportConfig(),
  TlsConfig tls = const TlsConfig(),
  Map<String, Object?> extras = const {},
}) =>
    withIdentity(ProxyNode(
      id: '',
      fingerprint: '',
      name: name,
      protocol: protocol,
      server: server,
      port: port,
      secrets: NodeSecrets(
        password: password,
        uuid: uuid,
        method: method,
        username: username,
        security: security,
        alterId: alterId,
        flow: flow,
      ),
      transport: transport,
      tls: tls,
      extras: extras,
    ));

ProxyNode _reimport(String link) {
  final result = parseShareLink(link);
  expect(result.node, isNotNull, reason: '导出的链接必须能被本应用再次导入: $link');
  return result.node!;
}

void main() {
  group('trojan', () {
    test('bare node stays bare', () {
      final link = shareLinkFor(_node(name: 'HK 01'));
      expect(link, 'trojan://secret@example.com:443#HK%2001');
    });

    test('tls and ws transport survive the round trip', () {
      final node = _node(
        name: '香港 中转',
        tls: TlsConfig(
          kind: TlsKind.tls,
          serverName: 'cdn.example.com',
          alpn: ['h2', 'http/1.1'],
          fingerprint: 'chrome',
          insecure: true,
        ),
        transport: const TransportConfig(
          kind: TransportKind.ws,
          host: 'ws.example.com',
          path: '/ws?x=1',
          earlyData: 2048,
        ),
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('trojan://secret@'));
      expect(link, contains('security=tls'));
      expect(link, contains('sni=cdn.example.com'));
      expect(link, contains('fp=chrome'));
      expect(link, contains('allowInsecure=1'));
      expect(link, contains('type=ws'));
      expect(link, contains('host=ws.example.com'));
      expect(link, contains('ed=2048'));
      expect(link, endsWith('#%E9%A6%99%E6%B8%AF%20%E4%B8%AD%E8%BD%AC'));

      final back = _reimport(link);
      expect(back.secrets.password, 'secret');
      expect(back.tls.kind, TlsKind.tls);
      expect(back.tls.serverName, 'cdn.example.com');
      expect(back.tls.alpn, ['h2', 'http/1.1']);
      expect(back.tls.fingerprint, 'chrome');
      expect(back.tls.insecure, isTrue);
      expect(back.transport.kind, TransportKind.ws);
      expect(back.transport.host, 'ws.example.com');
      expect(back.transport.path, '/ws?x=1');
      expect(back.transport.earlyData, 2048);
      expect(back.name, '香港 中转');
      // Identity is preserved: the round trip is the same node, not a lookalike.
      expect(back.fingerprint, node.fingerprint);
    });

    test('reality parameters ride the query', () {
      final node = _node(
        tls: TlsConfig(
          kind: TlsKind.reality,
          serverName: 'www.microsoft.com',
          realityPublicKey: 'pbk-value',
          realityShortId: 'ab12',
          fingerprint: 'chrome',
        ),
      );
      final link = shareLinkFor(node)!;
      expect(link, contains('security=reality'));
      expect(link, contains('pbk=pbk-value'));
      expect(link, contains('sid=ab12'));
      final back = _reimport(link);
      expect(back.tls.kind, TlsKind.reality);
      expect(back.tls.realityPublicKey, 'pbk-value');
      expect(back.tls.realityShortId, 'ab12');
      expect(back.fingerprint, node.fingerprint);
    });
  });

  group('vless', () {
    test('plain uuid node emits the v2rayN query form', () {
      final link = shareLinkFor(_node(
        protocol: ProxyProtocol.vless,
        password: null,
        uuid: 'abc-123',
      ));
      expect(
        link,
        'vless://abc-123@example.com:443?encryption=none&security=none#n',
      );
    });

    test('flow and grpc serviceName survive', () {
      final node = _node(
        name: '视觉流',
        protocol: ProxyProtocol.vless,
        password: null,
        uuid: 'u1',
        flow: 'xtls-rprx-vision',
        tls: const TlsConfig(kind: TlsKind.tls, serverName: 'sni.example.com'),
        transport: const TransportConfig(
          kind: TransportKind.grpc,
          serviceName: 'grpc-svc',
        ),
      );
      final link = shareLinkFor(node)!;
      expect(link, contains('flow=xtls-rprx-vision'));
      expect(link, contains('type=grpc'));
      expect(link, contains('serviceName=grpc-svc'));
      final back = _reimport(link);
      expect(back.secrets.flow, 'xtls-rprx-vision');
      expect(back.transport.kind, TransportKind.grpc);
      expect(back.transport.serviceName, 'grpc-svc');
      expect(back.tls.serverName, 'sni.example.com');
      expect(back.fingerprint, node.fingerprint);
    });
  });

  group('vmess', () {
    test('base64 JSON round trip with ws + tls', () {
      final node = _node(
        name: 'VM-01',
        protocol: ProxyProtocol.vmess,
        password: null,
        uuid: 'b8ddf3e2-4f6e-4c3f-9d2a-7b1c2d3e4f5a',
        security: 'auto',
        alterId: 0,
        transport: const TransportConfig(
          kind: TransportKind.ws,
          host: 'cdn.example.com',
          path: '/v2',
        ),
        tls: const TlsConfig(
          kind: TlsKind.tls,
          serverName: 'sni.example.com',
          alpn: ['h2'],
          fingerprint: 'firefox',
        ),
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('vmess://'));
      final json =
          jsonDecode(utf8.decode(base64.decode(link.substring(8)))) as Map;
      expect(json['v'], 2);
      expect(json['ps'], 'VM-01');
      expect(json['add'], 'example.com');
      expect(json['port'], 443);
      expect(json['id'], 'b8ddf3e2-4f6e-4c3f-9d2a-7b1c2d3e4f5a');
      expect(json['aid'], 0);
      expect(json['scy'], 'auto');
      expect(json['net'], 'ws');
      expect(json['host'], 'cdn.example.com');
      expect(json['path'], '/v2');
      expect(json['tls'], 'tls');
      expect(json['sni'], 'sni.example.com');
      expect(json['alpn'], 'h2');
      expect(json['fp'], 'firefox');
      expect(json['insecure'], '0');

      final back = _reimport(link);
      expect(back.protocol, ProxyProtocol.vmess);
      expect(back.secrets.uuid, node.secrets.uuid);
      expect(back.secrets.security, 'auto');
      expect(back.secrets.alterId, 0);
      expect(back.transport.kind, TransportKind.ws);
      expect(back.transport.host, 'cdn.example.com');
      expect(back.transport.path, '/v2');
      expect(back.tls.kind, TlsKind.tls);
      expect(back.tls.serverName, 'sni.example.com');
      expect(back.tls.fingerprint, 'firefox');
      expect(back.name, 'VM-01');
      expect(back.fingerprint, node.fingerprint);
    });

    test('reality keeps its public key (beyond what v2rayN preserves)', () {
      final node = _node(
        protocol: ProxyProtocol.vmess,
        password: null,
        uuid: 'u-reality',
        security: 'auto',
        alterId: 0,
        tls: const TlsConfig(
          kind: TlsKind.reality,
          serverName: 'www.apple.com',
          realityPublicKey: 'pbk-1',
          realityShortId: 'cd34',
        ),
      );
      final link = shareLinkFor(node)!;
      final json =
          jsonDecode(utf8.decode(base64.decode(link.substring(8)))) as Map;
      expect(json['tls'], 'reality');
      expect(json['pbk'], 'pbk-1');
      expect(json['sid'], 'cd34');
      final back = _reimport(link);
      expect(back.tls.kind, TlsKind.reality);
      expect(back.tls.realityPublicKey, 'pbk-1');
      expect(back.tls.realityShortId, 'cd34');
    });
  });

  group('shadowsocks', () {
    test('SIP002 base64 userinfo round trip, special password included', () {
      final node = _node(
        protocol: ProxyProtocol.shadowsocks,
        method: 'aes-256-gcm',
        password: 'p@ss:word/1',
        port: 8388,
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('ss://'));
      final back = _reimport(link);
      expect(back.protocol, ProxyProtocol.shadowsocks);
      expect(back.secrets.method, 'aes-256-gcm');
      expect(back.secrets.password, 'p@ss:word/1');
      expect(back.server, 'example.com');
      expect(back.port, 8388);
      expect(back.fingerprint, node.fingerprint);
    });

    test('missing cipher is refused', () {
      expect(
        shareLinkFor(_node(
          protocol: ProxyProtocol.shadowsocks,
          method: null,
        )),
        isNull,
      );
    });
  });

  group('socks and http', () {
    test('socks with credentials round trip', () {
      final node = _node(
        protocol: ProxyProtocol.socks,
        username: 'user',
        password: 'p:1@a',
        port: 1080,
      );
      final back = _reimport(shareLinkFor(node)!);
      expect(back.secrets.username, 'user');
      expect(back.secrets.password, 'p:1@a');
      expect(back.fingerprint, node.fingerprint);
    });

    test('credential-free socks stays bare', () {
      final node = _node(
        protocol: ProxyProtocol.socks,
        username: null,
        password: null,
        port: 1080,
      );
      expect(shareLinkFor(node), 'socks://example.com:1080#n');
    });

    test('http proxy switches scheme on tls', () {
      final plain = _node(
        protocol: ProxyProtocol.http,
        username: 'u',
        password: 'p',
        port: 8080,
      );
      expect(shareLinkFor(plain), 'http://u:p@example.com:8080#n');
      final secured = _node(
        protocol: ProxyProtocol.http,
        username: 'u',
        password: 'p',
        tls: const TlsConfig(kind: TlsKind.tls),
      );
      expect(shareLinkFor(secured), 'https://u:p@example.com:443#n');
    });
  });

  group('tuic', () {
    test('uuid:password with sni and congestion control round trip', () {
      final node = _node(
        protocol: ProxyProtocol.tuic,
        uuid: 'tuic-uuid',
        tls: const TlsConfig(kind: TlsKind.tls, serverName: 'sni.example.com'),
        extras: {'congestionControl': 'bbr'},
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('tuic://tuic-uuid:secret@'));
      expect(link, contains('sni=sni.example.com'));
      expect(link, contains('congestion_control=bbr'));
      final back = _reimport(link);
      expect(back.secrets.uuid, 'tuic-uuid');
      expect(back.secrets.password, 'secret');
      expect(back.tls.serverName, 'sni.example.com');
      expect(back.extras['congestionControl'], 'bbr');
    });
  });

  group('hysteria2', () {
    test('tls fields and extras round trip', () {
      final node = _node(
        name: 'HY-01',
        protocol: ProxyProtocol.hysteria2,
        password: 'hy2-pw',
        port: 8443,
        tls: const TlsConfig(
          kind: TlsKind.tls,
          serverName: 'hy.example.com',
          alpn: ['h3'],
          insecure: true,
        ),
        extras: {'obfsPassword': 'obfs-pw', 'upMbps': '30', 'downMbps': '200'},
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('hysteria2://hy2-pw@'));
      expect(link, contains('sni=hy.example.com'));
      expect(link, contains('alpn=h3'));
      expect(link, contains('insecure=1'));
      expect(link, contains('obfs=salamander'));
      expect(link, contains('obfs-password=obfs-pw'));
      expect(link, contains('up=30'));
      expect(link, contains('down=200'));
      final back = _reimport(link);
      expect(back.secrets.password, 'hy2-pw');
      expect(back.tls.serverName, 'hy.example.com');
      expect(back.tls.insecure, isTrue);
      expect(back.extras['obfsPassword'], 'obfs-pw');
      expect(back.extras['upMbps'], '30');
      expect(back.extras['downMbps'], '200');
      expect(back.name, 'HY-01');
    });
  });

  group('naive', () {
    test('h2 form with credentials round trip', () {
      final node = _node(
        protocol: ProxyProtocol.naive,
        username: 'user',
        password: 'pass',
        tls: const TlsConfig(kind: TlsKind.tls, serverName: 'naive.example.com'),
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('naive+https://user:pass@'));
      expect(link, contains('sni=naive.example.com'));
      final back = _reimport(link);
      expect(back.protocol, ProxyProtocol.naive);
      expect(back.secrets.username, 'user');
      expect(back.secrets.password, 'pass');
      expect(back.tls.serverName, 'naive.example.com');
    });

    test('the quic variant keeps its transport flag', () {
      final node = _node(
        protocol: ProxyProtocol.naive,
        username: 'u',
        password: 'p',
        tls: const TlsConfig(kind: TlsKind.tls),
        extras: {'naiveQuic': true},
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('naive+quic://u:p@'));
      final back = _reimport(link);
      expect(back.extras['naiveQuic'], isTrue);
      expect(back.isUdpTransport, isTrue, reason: 'naive+quic 走 QUIC/UDP');
    });
  });

  group('anytls', () {
    test('password with sni and insecure round trip', () {
      final node = _node(
        protocol: ProxyProtocol.anytls,
        password: 'at-pw',
        tls: const TlsConfig(
          kind: TlsKind.tls,
          serverName: 'at.example.com',
          insecure: true,
        ),
      );
      final link = shareLinkFor(node)!;
      expect(link, startsWith('anytls://at-pw@'));
      expect(link, contains('sni=at.example.com'));
      expect(link, contains('allowInsecure=1'));
      final back = _reimport(link);
      expect(back.protocol, ProxyProtocol.anytls);
      expect(back.secrets.password, 'at-pw');
      expect(back.tls.serverName, 'at.example.com');
      expect(back.tls.insecure, isTrue);
    });
  });

  group('refusals', () {
    test('ssh has no exportable URI form', () {
      expect(
        shareLinkFor(_node(
          protocol: ProxyProtocol.ssh,
          username: 'root',
          password: 'k',
        )),
        isNull,
      );
    });

    test('missing credentials are refused per protocol', () {
      expect(shareLinkFor(_node(password: null)), isNull, reason: 'trojan');
      expect(
        shareLinkFor(_node(protocol: ProxyProtocol.vless, password: null, uuid: null)),
        isNull,
      );
      expect(
        shareLinkFor(_node(protocol: ProxyProtocol.vmess, password: null, uuid: null)),
        isNull,
      );
      expect(
        shareLinkFor(_node(protocol: ProxyProtocol.hysteria2, password: null)),
        isNull,
      );
      expect(
        shareLinkFor(_node(
          protocol: ProxyProtocol.shadowsocks,
          method: 'aes-256-gcm',
          password: null,
        )),
        isNull,
      );
      expect(
        shareLinkFor(_node(
          protocol: ProxyProtocol.tuic,
          password: null,
          uuid: null,
        )),
        isNull,
      );
      expect(
        shareLinkFor(_node(protocol: ProxyProtocol.anytls, password: null)),
        isNull,
      );
      expect(
        shareLinkFor(_node(protocol: ProxyProtocol.naive, username: null, password: null)),
        isNull,
      );
    });
  });

  group('userinfo percent-encoding is symmetric with the importer', () {
    // Export used `encodeQueryComponent` while import used `decodeComponent`.
    // Those are not inverses: a space left as '+', so a passphrase with a space
    // came back as "pass+phrase" and the round trip silently changed the
    // credential the user would connect with.
    test('a password containing a space round-trips unchanged', () {
      // The importer turns TLS on for every trojan link, so the fixture does
      // too; otherwise the identity differs for a reason unrelated to this test.
      final node = _node(
        password: 'pass phrase',
        tls: const TlsConfig(kind: TlsKind.tls, serverName: 'example.com'),
      );
      final link = shareLinkFor(node)!;
      expect(link, contains('pass%20phrase@'));
      expect(link, isNot(contains('pass+phrase@')));

      final back = _reimport(link);
      expect(back.secrets.password, 'pass phrase');
      expect(back.fingerprint, node.fingerprint);
    });

    test('a literal + in a password survives', () {
      final node = _node(
        password: 'a+b',
        tls: const TlsConfig(kind: TlsKind.tls, serverName: 'example.com'),
      );
      final link = shareLinkFor(node)!;
      // '+' must be escaped so the importer cannot mistake it for a space.
      expect(link, contains('a%2Bb@'));

      final back = _reimport(link);
      expect(back.secrets.password, 'a+b');
      expect(back.fingerprint, node.fingerprint);
    });

    test('space and plus together, and a username with a space', () {
      final node = _node(
          protocol: ProxyProtocol.socks,
          username: 'user name',
          password: 'p +q');
      final link = shareLinkFor(node)!;
      final back = _reimport(link);
      expect(back.secrets.username, 'user name');
      expect(back.secrets.password, 'p +q');
      expect(back.fingerprint, node.fingerprint);
    });
  });
}
