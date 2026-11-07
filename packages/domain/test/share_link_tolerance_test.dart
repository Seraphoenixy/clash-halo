import 'dart:convert';

import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// Links that other clients accept and this importer used to refuse.
///
/// Every case below is a real entry from a public subscription that reported
/// "格式损坏". The label was wrong: the links are valid in v2rayN, and the
/// parser was stricter than the clients that produce them. On one list this
/// turned 1300 accepted nodes into 1300 rejections.
void main() {
  group('a password may contain @', () {
    // The whole link failed to parse, because the authority had two '@'.
    const link =
        'trojan://!str18844@zxcvbn@os-tr-5.cats22.net:443#@DeltaKroneckerGithub';

    test('the last @ is the userinfo delimiter', () {
      final parsed = parseShareLink(link);
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      final node = parsed.node!;
      expect(node.protocol, ProxyProtocol.trojan);
      expect(node.server, 'os-tr-5.cats22.net');
      expect(node.port, 443);
      expect(node.secrets.password, '!str18844@zxcvbn');
    });
  });

  group('Shadowsocks credentials', () {
    test('plain method:password is accepted, not Base64-decoded', () {
      final parsed =
          parseShareLink('ss://aes-128-gcm:shadowsocks@173.244.56.9:443#node');
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.secrets.method, 'aes-128-gcm');
      expect(parsed.node!.secrets.password, 'shadowsocks');
    });

    test('a Base64 password in the plain form survives', () {
      // 2022-blake3 keys are Base64 themselves; decoding them again threw.
      final parsed = parseShareLink(
        'ss://2022-blake3-aes-128-gcm:jUbDNsFamcyDfpm%2BrI3Zyw%3D%3D'
        '@38.145.220.193:8443#node',
      );
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.secrets.method, '2022-blake3-aes-128-gcm');
      expect(parsed.node!.secrets.password, 'jUbDNsFamcyDfpm+rI3Zyw==');
    });

    test('a name glued onto the port is dropped', () {
      // `freenettirUnited` and `<br/><br/>` are scrape debris, not part of the
      // authority.
      for (final tail in ['freenettirUnited', '<br/><br/>', '%40freenettir%20%C2%B9']) {
        final parsed = parseShareLink(
          'ss://YWVzLTEyOC1nY206c2hhZG93c29ja3M=@156.146.38.169:443$tail#node',
        );
        expect(parsed.issue, isNull, reason: '$tail: ${parsed.issue?.message}');
        expect(parsed.node!.port, 443, reason: tail);
        expect(parsed.node!.server, '156.146.38.169', reason: tail);
      }
    });
  });

  group('VMess payloads with junk after them', () {
    String payload() => base64Encode(utf8.encode(jsonEncode({
      'v': '2',
      'ps': 'example node',
      'add': '203.0.113.7',
      'port': '443',
      'id': '11111111-2222-3333-4444-555555555555',
      'aid': '0',
      'net': 'ws',
      'path': '/ws',
      'tls': 'tls',
      'sni': 'example.com',
    })));

    test('an emoji after the payload no longer breaks decoding', () {
      final parsed = parseShareLink('vmess://${payload()}👈');
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.server, '203.0.113.7');
      expect(parsed.node!.secrets.uuid, '11111111-2222-3333-4444-555555555555');
    });

    test('a mojibake name after the payload is dropped', () {
      final parsed = parseShareLink('vmess://${payload()}Р вҖңРІТ–Т°');
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.port, 443);
    });

    test('a query appended without a fragment separator is ignored', () {
      final parsed = parseShareLink('vmess://${payload()}?fp=chrome');
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.transport.kind, TransportKind.ws);
    });

    test('a payload cut off inside its padding still decodes', () {
      // The Base64 body may end with '=' and then more padding is appended by
      // the decoder; `A===` used to be rejected outright.
      final parsed = parseShareLink('vmess://${payload()}=#node');
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.server, '203.0.113.7');
    });
  });

  group('VMess URI form', () {
    test('uuid@host:port is read as a node, not as broken Base64', () {
      final parsed = parseShareLink(
        'vmess://5c040f1d-45db-43bd-8d46-e4950e433735@193.108.117.61:1270'
        '?type=tcp&security=tls&sni=xmfhlpy.com#node',
      );
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.protocol, ProxyProtocol.vmess);
      expect(parsed.node!.secrets.uuid, '5c040f1d-45db-43bd-8d46-e4950e433735');
      expect(parsed.node!.port, 1270);
      expect(parsed.node!.tls.kind, TlsKind.tls);
    });
  });

  group('transports', () {
    test('Xray\'s raw spelling is plain TCP', () {
      final parsed = parseShareLink(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?security=reality&type=raw&pbk=PUBKEY&sni=example.com&flow=xtls-rprx-vision',
      );
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.transport.kind, TransportKind.tcp);
    });

    test('an unknown transport is still refused', () {
      final parsed = parseShareLink(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?security=tls&type=xhttp',
      );
      expect(parsed.issue?.kind, ImportFailureKind.unsupportedParameter);
      expect(parsed.issue?.message, contains('xhttp'));
    });
  });

  group('entries joined on one line', () {
    String payload() => base64Encode(
      utf8.encode(
        jsonEncode({
          'v': '2',
          'ps': 'joined',
          'add': '203.0.113.7',
          'port': '443',
          'id': '11111111-2222-3333-4444-555555555555',
          'aid': '0',
          'net': 'ws',
          'path': '/ws',
          'tls': 'tls',
          'sni': 'example.com',
        }),
      ),
    );

    test('a Base64 payload followed by a vless link yields both nodes', () {
      // One aggregator publishes exactly this: the payload, then the next link,
      // with no separator. Used to be one "格式损坏" and two lost nodes.
      final line =
          '${payload()}vless://11111111-2222-3333-4444-555555555555'
          '@example.com:443?security=tls&type=ws&path=%2Fws#vless-node';
      expect(splitConcatenatedLinks(line), hasLength(2));

      final result = parseShareLinks([line]);
      expect(result.importedCount, 2, reason: result.failed.map((e) => e.message).join('; '));
      expect(result.failed, isEmpty);
    });

    test('a Base64 payload followed by an ss link yields both nodes', () {
      final line =
          '${payload()}ss://YWVzLTEyOC1nY206cGFzcw==@198.51.100.9:8388#ss-node';
      final result = parseShareLinks([line]);
      expect(result.importedCount, 2, reason: result.failed.map((e) => e.message).join('; '));
    });

    test('a bare Base64 payload is read as a vmess node', () {
      final parsed = parseShareLink(payload());
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.protocol, ProxyProtocol.vmess);
      expect(parsed.node!.server, '203.0.113.7');
      expect(parsed.node!.secrets.uuid, '11111111-2222-3333-4444-555555555555');
    });

    test('a single link is not split', () {
      expect(
        splitConcatenatedLinks('vless://a@b.example:443?type=ws#n'),
        hasLength(1),
      );
      // `https` inside `naive+https` is not a boundary of its own.
      expect(
        splitConcatenatedLinks('naive+https://u:p@b.example:443#n'),
        hasLength(1),
      );
    });

    test('a URL-shaped name on a later link stays on that link', () {
      // The fragment belongs to the last link; it never starts a new entry.
      final line =
          '${payload()}vless://11111111-2222-3333-4444-555555555555'
          '@example.com:443?security=tls&type=ws#https://t.me/chan';
      expect(splitConcatenatedLinks(line), hasLength(2));

      final result = parseShareLinks([line]);
      expect(result.importedCount, 2, reason: result.failed.map((e) => e.message).join('; '));
      expect(result.nodes.last.name, 'https://t.me/chan');
    });
  });

  group('a URL-shaped display name is a name, not a node', () {
    // Providers label nodes with their Telegram channel. The fragment used to
    // be scanned for scheme markers like the rest of the line, so
    // `#https://t.me/xxx` was cut out of its own link and imported as a second,
    // ghost HTTP node pointing at t.me — one extra node on every refresh.
    const link = 'trojan://secret@example.com:443#https://t.me/some_channel';

    test('the whole fragment is the node name and no second node appears', () {
      expect(splitConcatenatedLinks(link), [link]);

      final result = parseShareLinks([link]);
      expect(result.failed, isEmpty);
      expect(result.importedCount, 1);
      expect(result.nodes.single.protocol, ProxyProtocol.trojan);
      expect(result.nodes.single.name, 'https://t.me/some_channel');
      expect(result.nodes.single.server, 'example.com');
    });

    test('the name round-trips through export and re-import as one node', () {
      final node = parseShareLinks([link]).nodes.single;
      final exported = shareLinkFor(node)!;
      final back = parseShareLinks([exported]);
      expect(back.importedCount, 1);
      expect(back.nodes.single.name, 'https://t.me/some_channel');
      expect(back.nodes.single.fingerprint, node.fingerprint);
    });

    test('a fragment-less link still parses', () {
      final result = parseShareLinks(['trojan://secret@example.com:443']);
      expect(result.importedCount, 1);
      expect(result.nodes.single.name, 'example.com:443');
      expect(result.nodes.single.secrets.password, 'secret');
    });

    test('a name repeating the link scheme is not a boundary', () {
      // Guards the head-only scan: the fragment's `https://` must not be
      // collected as a marker position beyond the end of the link body.
      const httpLink = 'https://user:pw@example.com:8443#https://t.me/chan';
      expect(splitConcatenatedLinks(httpLink), [httpLink]);

      final result = parseShareLinks([httpLink]);
      expect(result.importedCount, 1);
      expect(result.nodes.single.server, 'example.com');
      expect(result.nodes.single.name, 'https://t.me/chan');
    });
  });

  group('Clash transport spellings', () {
    Map<String, Object?> entry(Map<String, Object?> extra) => {
      'name': 'n',
      'type': 'vless',
      'server': 'example.com',
      'port': 443,
      'uuid': '11111111-2222-3333-4444-555555555555',
      ...extra,
    };

    test('network: raw is plain TCP', () {
      final parsed = parseClashProxy(entry({'network': 'raw'}));
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.transport.kind, TransportKind.tcp);
    });

    test('network: http keeps the path and Host header', () {
      final parsed = parseClashProxy(entry({
        'network': 'http',
        'http-opts': {
          'path': ['/probe'],
          'headers': {'Host': ['edge.example.com']},
        },
      }));
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.transport.kind, TransportKind.http);
      expect(parsed.node!.transport.path, '/probe');
      expect(parsed.node!.transport.host, 'edge.example.com');
    });
  });

  test('a valid IPv6 literal still parses', () {
    final parsed = parseShareLink('ss://YWVzLTEyOC1nY206cGFzcw==@[2001:db8::1]:443#v6');
    expect(parsed.issue, isNull, reason: parsed.issue?.message);
    expect(parsed.node!.port, 443);
    expect(parsed.node!.server, contains('2001:db8'));
  });

  test('the truly corrupted entry is still reported, with its reason', () {
    // The publisher percent-encoded a fragment into the query: `type` really
    // does contain `#🎗️100@…`. Nothing can import that; saying so is correct.
    final parsed = parseShareLink(
      'vless://814bd064-544d-4255-a070-5705c03f6da9@67.220.73.204:18662'
      '?type=tcp%23%F0%9F%8E%97%EF%B8%8F100%40oneclickvpnkeys',
    );
    expect(parsed.issue, isNotNull);
    expect(parsed.issue!.kind, ImportFailureKind.unsupportedParameter);
  });
}
