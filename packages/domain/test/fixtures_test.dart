import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// Runs the shared fixtures under `tests/fixtures` through the real importer.
///
/// The fixtures exist so that every parser has one agreed corpus; this test is
/// what keeps them from rotting into decoration.
/// `dart test` runs from the package directory, `dart test packages/x` from the
/// repository root; try both instead of depending on how it was invoked.
String _fixture(String relative) {
  final candidates = <String>[
    '../../tests/fixtures/$relative',
    'tests/fixtures/$relative',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('缺少测试语料 tests/fixtures/$relative');
}

void main() {
  group('share link fixtures', () {
    test('basic.txt imports every line with the right protocol', () {
      final result = importNodes(_fixture('share_links/basic.txt'));
      expect(result.sourceFormat, SourceFormat.shareLinks.wire);
      expect(result.importedCount, 5);
      expect(result.failedCount, 0, reason: result.failed.toString());

      final protocols = result.nodes.map((n) => n.protocol).toSet();
      expect(protocols, contains(ProxyProtocol.vless));
      expect(protocols, contains(ProxyProtocol.vmess));
      expect(protocols, contains(ProxyProtocol.trojan));
      expect(protocols, contains(ProxyProtocol.shadowsocks));
      expect(protocols, contains(ProxyProtocol.hysteria2));
    });

    test('names decoded from the fragment are not percent-escaped', () {
      final result = importNodes(_fixture('share_links/basic.txt'));
      final first = result.nodes.first;
      expect(first.name, contains('香港'));
      expect(first.name, isNot(contains('%')));
    });

    test('bad_lines.txt reports failures instead of silently dropping them', () {
      final result = importNodes(_fixture('share_links/bad_lines.txt'));
      expect(result.failedCount, greaterThan(0));
      expect(result.nodes.length + result.failedCount, 6,
          reason: '每一行都必须落进节点或失败清单');
    });

    test('base64.txt is decoded and classified', () {
      final result = importNodes(_fixture('share_links/base64.txt'));
      expect(result.sourceFormat, SourceFormat.base64Text.wire);
      expect(result.importedCount, 2);
      expect(result.nodes.first.name, 'node-a');
    });
  });

  group('clash fixtures', () {
    test('yaml_basic.yaml imports the supported proxies', () {
      final result = importNodes(_fixture('clash/yaml_basic.yaml'));
      expect(result.sourceFormat, SourceFormat.clashYaml.wire);
      expect(result.nodes.length, greaterThanOrEqualTo(2));

      final vmess = result.nodes.firstWhere((n) => n.protocol == ProxyProtocol.vmess);
      expect(vmess.server, 'example.com');
      expect(vmess.port, 443);
    });

    test('yaml_bad.yaml reports issues rather than inventing nodes', () {
      final result = importNodes(_fixture('clash/yaml_bad.yaml'));
      expect(result.failedCount + result.skippedCount, greaterThan(0));
      // A "direct" proxy is not a remote node and must never be counted.
      expect(result.nodes.where((n) => n.server.isEmpty), isEmpty);
    });
  });

  group('sing-box fixtures', () {
    test('json_basic.json imports outbounds and skips direct', () {
      final result = importNodes(_fixture('singbox/json_basic.json'));
      expect(result.sourceFormat, SourceFormat.singboxJson.wire);
      expect(result.nodes.length, 2);
      expect(result.nodes.map((n) => n.name), containsAll(<String>['香港-01', '新加坡-02']));
    });

    test('json_bad.json reports issues and keeps going', () {
      final result = importNodes(_fixture('singbox/json_bad.json'));
      expect(result.failedCount + result.skippedCount, greaterThan(0));
      expect(result.isEmpty, isTrue);
    });
  });

  group('malformed fixtures', () {
    test('empty file produces no nodes and no crash', () {
      final result = importNodes(_fixture('malformed/empty.txt'));
      expect(result.isEmpty, isTrue);
    });

    test('whitespace-only file is treated as empty', () {
      final result = importNodes(_fixture('malformed/whitespace.txt'));
      expect(result.isEmpty, isTrue);
      expect(detectFormat(_fixture('malformed/whitespace.txt')), SourceFormat.unknown);
    });

    test('random prose is not mistaken for a subscription', () {
      final body = _fixture('malformed/random.txt');
      expect(detectFormat(body), SourceFormat.plainText);
      final result = importNodes(body);
      expect(result.nodes, isEmpty);
    });
  });
}
