import 'dart:convert';

import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

void main() {
  /// A minimal valid node, used where the test cares about one property rather
  /// than about parsing.
  ProxyNode buildNode(
    ProxyProtocol protocol, {
    Map<String, Object?> extras = const {},
  }) {
    final base = withIdentity(
      ProxyNode(
        id: '',
        fingerprint: '',
        name: 'n',
        protocol: protocol,
        server: 'h.example.com',
        port: 443,
        extras: extras,
      ),
    );
    return base;
  }

  group('share links', () {
    test('ss link with base64 credentials', () {
      final b64 = base64Encode(utf8.encode('aes-256-gcm:pass123'));
      final r = parseShareLink('ss://$b64@example.com:8388#Tokyo');
      final node = r.node!;
      expect(node.protocol, ProxyProtocol.shadowsocks);
      expect(node.server, 'example.com');
      expect(node.port, 8388);
      expect(node.name, 'Tokyo');
      expect(node.secrets.method, 'aes-256-gcm');
      expect(node.secrets.password, 'pass123');
      expect(node.fingerprint, isNotEmpty);
      expect(node.id, startsWith('n_'));
    });

    test('vmess json payload', () {
      final payload = jsonEncode({
        'v': '2',
        'ps': 'HK-01',
        'add': 'hk.example.com',
        'port': '443',
        'id': 'uuid-1',
        'aid': '0',
        'net': 'ws',
        'host': 'cdn.example.com',
        'path': '/ray',
        'tls': 'tls',
        'sni': 'cdn.example.com',
      });
      final link = 'vmess://${base64Encode(utf8.encode(payload))}';
      final node = parseShareLink(link).node!;
      expect(node.protocol, ProxyProtocol.vmess);
      expect(node.name, 'HK-01');
      expect(node.secrets.uuid, 'uuid-1');
      expect(node.transport.kind, TransportKind.ws);
      expect(node.transport.path, '/ray');
      expect(node.tls.kind, TlsKind.tls);
      expect(node.tls.serverName, 'cdn.example.com');
    });

    test('vless reality link carries public key and rejects missing key', () {
      final ok = parseShareLink(
              'vless://uuid-2@a.example.com:443?security=reality&pbk=PUBKEY&sid=ab&sni=x.example.com&type=grpc&serviceName=svc#R1')
          .node!;
      expect(ok.tls.kind, TlsKind.reality);
      expect(ok.tls.realityPublicKey, 'PUBKEY');
      expect(ok.tls.realityShortId, 'ab');
      expect(ok.transport.serviceName, 'svc');

      final bad = parseShareLink(
          'vless://uuid-2@a.example.com:443?security=reality&sni=x.example.com');
      expect(bad.node, isNull);
      expect(bad.issue!.kind, ImportFailureKind.missingRequired);
    });

    test('trojan and hysteria2 defaults', () {
      final trojan = parseShareLink('trojan://pw@t.example.com:443#T').node!;
      expect(trojan.protocol, ProxyProtocol.trojan);
      expect(trojan.tls.kind, TlsKind.tls);
      expect(trojan.tls.serverName, 't.example.com');

      final hy = parseShareLink(
              'hysteria2://pw@h.example.com:8443?sni=h.example.com&insecure=1#H')
          .node!;
      expect(hy.protocol, ProxyProtocol.hysteria2);
      expect(hy.tls.insecure, isTrue);
      expect(hy.port, 8443);
    });

    test('unknown scheme is reported, not converted', () {
      final r = parseShareLink('wireguard://key@x.example.com:51820');
      expect(r.node, isNull);
      expect(r.issue!.kind, ImportFailureKind.unsupportedProtocol);
    });

    test('missing required credential fails instead of defaulting', () {
      final r = parseShareLink('trojan://t.example.com:443');
      expect(r.node, isNull);
      expect(r.issue!.kind, ImportFailureKind.missingRequired);
    });

    test('malformed base64 is a decode error', () {
      final r = parseShareLink('ss://not_base64_@example.com:8388');
      expect(r.node, isNull);
      expect(r.issue!.kind, ImportFailureKind.decodeError);
    });
  });

  group('identity', () {
    test('a QUIC-only protocol is not judged by a TCP handshake', () {
      // Hysteria2 and TUIC listen on UDP. Treating a failed TCP connect as
      // "unreachable" would condemn a node that is working, so the model has
      // to say which transport a reachability check may use.
      expect(ProxyProtocol.hysteria2.isAlwaysUdp, isTrue);
      expect(ProxyProtocol.tuic.isAlwaysUdp, isTrue);
      expect(ProxyProtocol.vless.isAlwaysUdp, isFalse);
      expect(ProxyProtocol.naive.isAlwaysUdp, isFalse);
    });

    test('a Naive node is judged by its http version, not its protocol name', () {
      // The transport is a property of the node, not of the protocol: HTTP/2
      // and HTTP/3 are the same protocol over different transports. Reading
      // only the protocol name probed both H3 rows in this list with a TCP
      // handshake and reported them unreachable.
      ProxyNode naive({required bool quic}) => buildNode(
        ProxyProtocol.naive,
        extras: {
          if (quic) 'v2rayn': {'naiveQuic': true},
        },
      );
      expect(naive(quic: true).isUdpTransport, isTrue,
          reason: 'HTTP/3 走 QUIC，是 UDP');
      expect(naive(quic: false).isUdpTransport, isFalse,
          reason: 'HTTP/2 走 TCP');

      // The string form survives a JSON round trip, so it must count too.
      final fromJson = buildNode(
        ProxyProtocol.naive,
        extras: {
          'v2rayn': {'naiveQuic': 'true'},
        },
      );
      expect(fromJson.isUdpTransport, isTrue);
    });

    test('an explicit datagram transport overrides the protocol default', () {
      // VLESS is a TCP protocol, but VLESS over QUIC/KCP is not; guessing from
      // the protocol alone would hand a datagram node to a TCP handshake.
      expect(
        buildNode(ProxyProtocol.vless, extras: {'network': 'quic'}).isUdpTransport,
        isTrue,
      );
      expect(
        buildNode(ProxyProtocol.vless, extras: {'network': 'kcp'}).isUdpTransport,
        isTrue,
      );
      // WebSocket and gRPC ride on TCP even though they are not bare TCP.
      expect(
        buildNode(ProxyProtocol.vless, extras: {'network': 'ws'}).isUdpTransport,
        isFalse,
      );
      expect(buildNode(ProxyProtocol.trojan).isUdpTransport, isFalse);
    });

    test('rename does not change identity', () {
      final a = parseShareLink('ss://${base64Encode(utf8.encode('aes-128-gcm:p'))}@h:443#A').node!;
      final b = a.copyWith(name: 'B');
      expect(withIdentity(b).fingerprint, a.fingerprint);
    });

    test('different password or transport yields a different identity', () {
      final a = parseShareLink('ss://${base64Encode(utf8.encode('aes-128-gcm:p1'))}@h:443').node!;
      final b = parseShareLink('ss://${base64Encode(utf8.encode('aes-128-gcm:p2'))}@h:443').node!;
      expect(a.fingerprint, isNot(b.fingerprint));

      final ws = parseShareLink(
          'vless://u@h2:443?type=ws&path=%2Fa&security=tls').node!;
      final h2 = parseShareLink(
          'vless://u@h2:443?type=ws&path=%2Fb&security=tls').node!;
      expect(ws.fingerprint, isNot(h2.fingerprint));
    });

    test('same connection reimported keeps the same id', () {
      final link = 'trojan://pw@t.example.com:443?sni=t.example.com#One';
      final again = 'trojan://pw@t.example.com:443?sni=t.example.com#Two';
      expect(parseShareLink(link).node!.id, parseShareLink(again).node!.id);
    });

    test('host case and trailing whitespace are normalised', () {
      final a = parseShareLink('socks5://u:p@Host.Example.COM:1080').node!;
      final b = parseShareLink('socks5://u:p@host.example.com:1080').node!;
      expect(a.fingerprint, b.fingerprint);
    });

    test('duplicate grouping keeps order', () {
      final a = parseShareLink('ss://${base64Encode(utf8.encode('m:p'))}@h:1#A').node!;
      final b = a.copyWith(name: 'B');
      final groups = groupDuplicates([a, b, a.copyWith(name: 'C')]);
      expect(groups.keys.single, a.fingerprint);
      expect(groups.values.single.length, 3);
    });
  });

  group('clash yaml', () {
    const yaml = '''
port: 7890
proxies:
  - name: SS1
    type: ss
    server: s1.example.com
    port: 8388
    cipher: aes-256-gcm
    password: pw1
  - name: VM1
    type: vmess
    server: v1.example.com
    port: 443
    uuid: u-1
    alterId: 0
    cipher: auto
    tls: true
    servername: v1.example.com
    network: ws
    ws-opts:
      path: /ws
      headers:
        Host: cdn.example.com
  - name: HY1
    type: hysteria2
    server: h1.example.com
    port: 8443
    password: pw2
    sni: h1.example.com
proxy-groups:
  - name: PROXY
    type: select
    proxies: [SS1, VM1]
rules:
  - MATCH,PROXY
''';

    test('imports proxies and ignores routing sections', () {
      final result = parseClashYaml(yaml);
      expect(result.nodes.length, 3);
      expect(result.failed, isEmpty);
      expect(result.sourceFormat, 'clash_yaml');
      final ss = result.nodes.firstWhere((n) => n.name == 'SS1');
      expect(ss.protocol, ProxyProtocol.shadowsocks);
      expect(ss.secrets.password, 'pw1');
      final vm = result.nodes.firstWhere((n) => n.name == 'VM1');
      expect(vm.transport.kind, TransportKind.ws);
      expect(vm.transport.host, 'cdn.example.com');
      expect(vm.tls.serverName, 'v1.example.com');
      final hy = result.nodes.firstWhere((n) => n.name == 'HY1');
      expect(hy.protocol, ProxyProtocol.hysteria2);
    });

    test('unsupported protocol reports a typed issue and keeps the rest', () {
      final result = parseClashYaml('''
proxies:
  - name: WG
    type: wireguard
    server: wg.example.com
    port: 51820
  - name: OK
    type: trojan
    server: t.example.com
    port: 443
    password: pw
    sni: t.example.com
''');
      expect(result.nodes.length, 1);
      expect(result.failed.single.kind, ImportFailureKind.unsupportedProtocol);
      expect(result.failed.single.message, contains('wireguard'));
    });

    test('invalid yaml yields a single decode error', () {
      final result = parseClashYaml('proxies: [\n  - name: x\n');
      expect(result.nodes, isEmpty);
      expect(result.failed.single.kind, ImportFailureKind.decodeError);
    });

    test('missing port fails per entry without aborting', () {
      final result = parseClashYaml('''
proxies:
  - name: NoPort
    type: ss
    server: a.example.com
    cipher: aes-128-gcm
    password: p
  - name: Fine
    type: ss
    server: b.example.com
    port: 8388
    cipher: aes-128-gcm
    password: p
''');
      expect(result.nodes.length, 1);
      expect(result.failed.single.kind, ImportFailureKind.missingRequired);
      expect(result.failed.single.line, 1);
    });
  });

  group('singbox json', () {
    final doc = jsonEncode({
      'log': {'level': 'info'},
      'dns': {'servers': []},
      'inbounds': [
        {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 2080},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
        {
          'type': 'vless',
          'tag': 'NodeA',
          'server': 'a.example.com',
          'server_port': 443,
          'uuid': 'u-1',
          'flow': 'xtls-rprx-vision',
          'tls': {
            'enabled': true,
            'server_name': 'a.example.com',
            'utls': {'enabled': true, 'fingerprint': 'chrome'},
          },
          'transport': {'type': 'ws', 'path': '/ws'},
        },
        {
          'type': 'wireguard',
          'tag': 'wg',
          'server': 'wg.example.com',
          'server_port': 51820,
        },
      ],
      'route': {'rules': []},
    });

    test('extracts proxy outbounds only and reports skipped sections', () {
      final result = parseSingboxJson(doc);
      expect(result.nodes.length, 1);
      final node = result.nodes.single;
      expect(node.protocol, ProxyProtocol.vless);
      expect(node.tls.kind, TlsKind.tls);
      expect(node.tls.fingerprint, 'chrome');
      expect(node.transport.kind, TransportKind.ws);
      expect(result.skipped.any((s) => s.note == 'direct'), isTrue);
      expect(result.skipped.any((s) => s.note == 'route'), isTrue);
      expect(result.failed.single.kind, ImportFailureKind.unsupportedProtocol);
    });

    test('rejects non-json body', () {
      final result = parseSingboxJson('not json');
      expect(result.failed.single.kind, ImportFailureKind.decodeError);
    });
  });

  group('format detection and dispatch', () {
    test('detects each supported container', () {
      expect(detectFormat('vless://u@h:443'), SourceFormat.shareLinks);
      expect(detectFormat('proxies:\n  - name: a\n'), SourceFormat.clashYaml);
      expect(detectFormat('{"outbounds":[]}'), SourceFormat.singboxJson);
      expect(detectFormat('hello world'), SourceFormat.plainText);
    });

    test('base64 subscription unwraps and imports', () {
      final inner = 'ss://${base64Encode(utf8.encode('aes-128-gcm:p'))}@a.example.com:8388#A\n'
          'trojan://pw@b.example.com:443#B';
      final body = base64Encode(utf8.encode(inner));
      expect(detectFormat(body), SourceFormat.base64Text);
      final result = importNodes(body);
      expect(result.nodes.length, 2);
      expect(result.sourceFormat, 'base64_text');
    });

    test('empty input is reported', () {
      final result = importNodes('   ');
      expect(result.nodes, isEmpty);
      expect(result.failed.single.kind, ImportFailureKind.emptyInput);
    });

    test('plain text list dedupes and reports duplicates', () {
      final link = 'trojan://pw@t.example.com:443#Name1';
      final result = importNodes('$link\n$link\nbad line here');
      expect(result.nodes.length, 1);
      expect(result.skipped.single.kind, ImportFailureKind.duplicate);
      expect(result.failed.single.kind, ImportFailureKind.malformedLink);
    });
  });

  group('batch operations', () {
    List<ProxyNode> sample() => [
          parseShareLink('ss://${base64Encode(utf8.encode('a:p'))}@a.example.com:1#A').node!,
          parseShareLink('ss://${base64Encode(utf8.encode('a:p'))}@b.example.com:2#B').node!,
          parseShareLink('trojan://pw@c.example.com:443#C').node!,
        ];

    test('rename reports affected and changed separately', () {
      final nodes = sample();
      final out = BatchOps.rename(nodes, (n) => n.name != 'C', (n, i) => 'X$i');
      expect(out.affected, 2);
      expect(out.changed, 2);
      expect(out.nodes.map((n) => n.name), ['X1', 'X2', 'C']);
      expect(out.renamed.length, 2);
      expect(out.previewText, '将影响 2 个节点');
    });

    test('rename to identical name changes nothing', () {
      final nodes = sample();
      final out = BatchOps.rename(nodes, (n) => true, (n, i) => n.name);
      expect(out.changed, 0);
      expect(out.isEmpty, isTrue);
    });

    test('delete returns undo payload and restore reinstates', () {
      final nodes = sample();
      final out = BatchOps.deleteNodes(nodes, (n) => n.name == 'B');
      expect(out.nodes.length, 2);
      expect(out.removedNodes.single.name, 'B');
      final restored = BatchOps.restore(out.nodes, out);
      expect(restored.length, 3);
      expect(restored.any((n) => n.name == 'B'), isTrue);
    });

    test('dedupe removes exact duplicates only', () {
      final nodes = sample();
      final dup = nodes.first.copyWith(name: 'A2');
      final out = BatchOps.dedupe([...nodes, dup]);
      expect(out.nodes.length, 3);
      expect(out.changed, 1);
    });

    test('endpoint edit recomputes id and refuses collision', () {
      final nodes = sample();
      final out = BatchOps.editEndpoint(
          nodes, (n) => n.name == 'B', (n) => (server: 'a.example.com', port: 1));
      // Would collide with node A, so it is skipped and reported.
      expect(out.changed, 0);
      expect(out.issues.single, contains('重复'));

      final moved = BatchOps.editEndpoint(
          nodes, (n) => n.name == 'B', (n) => (server: 'new.example.com', port: 8443));
      expect(moved.changed, 1);
      final b = moved.nodes.firstWhere((n) => n.name == 'B');
      expect(b.id, isNot(nodes[1].id));
      expect(b.server, 'new.example.com');
    });

    test('reorder applies explicit ordering and reindexes', () {
      final nodes = sample();
      final ids = [nodes[2].id, nodes[0].id, nodes[1].id];
      final out = BatchOps.reorder(nodes, ids);
      expect(out.map((n) => n.name), ['C', 'A', 'B']);
      expect(out.map((n) => n.sortIndex), [0, 1, 2]);
    });

    test('grouping counts by protocol and profile', () {
      final nodes = sample();
      final byProtocol = BatchOps.countByProtocol(nodes);
      expect(byProtocol[ProxyProtocol.shadowsocks], 2);
      expect(byProtocol[ProxyProtocol.trojan], 1);
      final sub = nodes.first.copyWith(
          source: NodeSourceKind.subscription, profileId: 'p1');
      final counts = BatchOps.countByProfile([sub, nodes[1], sub.copyWith(name: 'A3')]);
      expect(counts['p1'], 2);
      expect(counts[null], 1);
    });

    test('undoRename restores previous names', () {
      final nodes = sample();
      final out = BatchOps.rename(nodes, (n) => true, (n, i) => '${n.name}!');
      final undone = BatchOps.undoRename(out.nodes, out.renamed);
      expect(undone.map((n) => n.name), ['A', 'B', 'C']);
    });

    test('movedToGroup can clear the profile, which copyWith cannot', () {
      // `copyWith(profileId: null)` means "keep the current value", so moving a
      // node back to 本地 could never be expressed through it. Every caller that
      // needed this used to rebuild the node by hand and got `source` wrong.
      final node = sample().first.copyWith(
        source: NodeSourceKind.subscription,
        profileId: 'p1',
      );
      final local = node.movedToGroup(null, nowMs: 42);
      expect(local.profileId, isNull);
      expect(local.source, NodeSourceKind.manual);
      expect(local.updatedAtMs, 42);
      // Identity and connection parameters must survive the move.
      expect(local.id, node.id);
      expect(local.fingerprint, node.fingerprint);
      expect(local.server, node.server);

      final filed = local.movedToGroup('p2', nowMs: 43);
      expect(filed.profileId, 'p2');
      expect(filed.source, NodeSourceKind.subscription);
    });
  });
}
