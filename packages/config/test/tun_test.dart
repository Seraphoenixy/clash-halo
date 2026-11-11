import 'dart:convert';
import 'dart:io';

import 'package:halo_config/halo_config.dart';
import 'package:test/test.dart';

/// The pinned core, used for the real `sing-box check` at the end.
final _singbox = File('${Directory.current.path}/prototype/bin/sing-box.exe');

/// Reads a shared fixture. Mirrors `packages/domain/test/fixtures_test.dart`:
/// `dart test` runs from the package directory, `dart test packages/config`
/// from the repository root, so both roots are tried instead of depending on
/// how it was invoked.
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

/// The host serialises its copy of the inbound with `json.MarshalIndent`,
/// which keeps key order; `encodePrettyJson` sorts keys, so it cannot be used
/// to compare against the fixture byte for byte.
String _prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

Map<String, Object?> _baseConfig() => {
  'log': {'level': 'warn'},
  'inbounds': [
    {
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': '127.0.0.1',
      'listen_port': 7890,
    },
  ],
  'outbounds': [
    {'type': 'direct', 'tag': 'direct'},
  ],
};

void main() {
  group('tun fixture', () {
    test('all-default output is byte-identical to the shared fixture', () {
      final contents = _fixture('singbox/tun_inbound.json');
      expect(contents, '${_prettyJson(buildTunInbound())}\n');
      expect(jsonDecode(contents), jsonDecode(jsonEncode(buildTunInbound())));
      expect(jsonDecode(contents), buildTunInbound());
    });

    test('generated inbound never carries the removed legacy fields', () {
      final tun = buildTunInbound();
      // `inet4_address` / `inet6_address` were deprecated in sing-box 1.10.0
      // and removed in 1.12.0; the pinned 1.14.4 core refuses to start with
      // them, and the package ships no config validator that would catch it
      // later, so it is asserted right here.
      expect(tun.containsKey('inet4_address'), isFalse);
      expect(tun.containsKey('inet6_address'), isFalse);
      expect(tun['address'], ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
    });
  });

  group('buildTunInbound', () {
    test('defaults match the measured working config', () {
      expect(buildTunInbound(), {
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'clash-halo',
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'mtu': 9000,
        'auto_route': true,
        'strict_route': true,
        'stack': 'mixed',
      });
    });

    test('honours every parameter, including the other valid stacks', () {
      final tun = buildTunInbound(
        adapterName: 'halo-tun',
        address: '10.7.0.1/30',
        address6: 'fd00::1/126',
        stack: 'system',
        mtu: 1500,
        autoRoute: false,
        strictRoute: false,
      );
      expect(tun['interface_name'], 'halo-tun');
      expect(tun['address'], ['10.7.0.1/30', 'fd00::1/126']);
      expect(tun['stack'], 'system');
      expect(tun['mtu'], 1500);
      expect(tun['auto_route'], isFalse);
      expect(tun['strict_route'], isFalse);
      expect(buildTunInbound(stack: 'mixed')['stack'], 'mixed');
    });

    test('mtu 0 means "let the core choose" and omits the key', () {
      expect(buildTunInbound(mtu: 0).containsKey('mtu'), isFalse);
    });
  });

  group('applyTunInbound', () {
    test('appends the inbound when the config has none', () {
      final out = applyTunInbound(_baseConfig());
      final inbounds = (out['inbounds'] as List).cast<Map>();
      expect(inbounds.length, 2);
      expect(inbounds.first['tag'], 'mixed-in');
      expect(inbounds.last, buildTunInbound());
    });

    test('replaces an existing tun inbound in place instead of appending', () {
      final config = {
        'inbounds': [
          {'type': 'tun', 'tag': 'tun-in', 'stack': 'system'},
          {'type': 'mixed', 'tag': 'mixed-in', 'listen_port': 7890},
        ],
      };
      final inbounds = (applyTunInbound(config)['inbounds'] as List)
          .cast<Map>();
      expect(inbounds.length, 2);
      expect(inbounds.first, buildTunInbound());
      expect(inbounds.first['stack'], 'mixed');
      expect(inbounds.last['tag'], 'mixed-in');
    });

    test('collapses duplicate tun inbounds into exactly one', () {
      final config = {
        'inbounds': [
          {'type': 'mixed', 'tag': 'mixed-in'},
          {'type': 'tun', 'tag': 'hand-edited'},
          {'type': 'tun', 'tag': 'tun-in'},
        ],
      };
      final inbounds = (applyTunInbound(config)['inbounds'] as List)
          .cast<Map>();
      expect(inbounds.where((i) => i['type'] == 'tun').length, 1);
      expect(inbounds.length, 2);
      expect(inbounds.first['tag'], 'mixed-in');
      expect(inbounds.last, buildTunInbound());
    });

    test(
      'forces route.auto_detect_interface and creates route when missing',
      () {
        final out = applyTunInbound(_baseConfig());
        expect((out['route'] as Map)['auto_detect_interface'], isTrue);

        final forced = applyTunInbound({
          'route': {'auto_detect_interface': false, 'final': 'proxy'},
        });
        expect((forced['route'] as Map)['auto_detect_interface'], isTrue);
        expect((forced['route'] as Map)['final'], 'proxy');
      },
    );

    test('preserves unrelated inbounds, outbounds and route keys', () {
      final config = _baseConfig();
      (config['inbounds'] as List).add({'type': 'http', 'tag': 'test-in'});
      (config['outbounds'] as List).add({'type': 'block', 'tag': 'block'});
      config['route'] = {'final': 'proxy'};
      config['experimental'] = {
        'cache_file': {'enabled': true},
      };

      final out = applyTunInbound(config);
      final inbounds = (out['inbounds'] as List).cast<Map>();
      expect(inbounds.map((i) => i['tag']), ['mixed-in', 'test-in', 'tun-in']);
      expect((out['outbounds'] as List), config['outbounds']);
      expect((out['route'] as Map)['final'], 'proxy');
      expect(out['experimental'], config['experimental']);
    });

    test('never mutates the input document, including nested values', () {
      final config = _baseConfig();
      config['route'] = {'auto_detect_interface': false};
      final before = jsonEncode(config);

      final out = applyTunInbound(config, adapterName: 'other-tun');
      expect(jsonEncode(config), before);
      expect((config['inbounds'] as List).length, 1);
      expect(config.containsKey('route'), isTrue);
      expect((config['route'] as Map)['auto_detect_interface'], isFalse);

      // The result is a deep copy: editing it must not reach back into input.
      expect(identical(out['inbounds'], config['inbounds']), isFalse);
      expect(
        identical(
          (out['inbounds'] as List).first,
          (config['inbounds'] as List).first,
        ),
        isFalse,
      );
      expect(identical(out['route'], config['route']), isFalse);
      (out['inbounds'] as List).clear();
      expect((config['inbounds'] as List).length, 1);
    });

    test('tolerates a missing or malformed inbounds value', () {
      for (final config in <Map<String, Object?>>[
        {},
        {'inbounds': 'not-a-list'},
      ]) {
        final inbounds = (applyTunInbound(config)['inbounds'] as List)
            .cast<Map>();
        expect(inbounds.single, buildTunInbound());
      }
    });
  });

  group('hasTunInbound', () {
    test('false when there is no tun inbound', () {
      expect(hasTunInbound({}), isFalse);
      expect(hasTunInbound(_baseConfig()), isFalse);
      expect(hasTunInbound({'inbounds': 'not-a-list'}), isFalse);
      expect(
        hasTunInbound({
          'inbounds': [
            {'type': 'mixed'},
          ],
        }),
        isFalse,
      );
    });

    test('true when a tun inbound is present, wherever it sits', () {
      expect(
        hasTunInbound({
          'inbounds': [buildTunInbound()],
        }),
        isTrue,
      );
      expect(
        hasTunInbound({
          'inbounds': [
            {'type': 'mixed'},
            {'type': 'tun', 'tag': 'tun-in'},
          ],
        }),
        isTrue,
      );
    });

    test('agrees with applyTunInbound for a fresh config', () {
      final out = applyTunInbound(_baseConfig());
      expect(hasTunInbound(out), isTrue);
    });
  });

  group('capability model', () {
    test('the pinned core reports TUN as supported but not free', () {
      expect(CoreCapabilities.singbox114.tunSupported, isTrue);
      expect(CoreCapabilities.singbox114.tunRequiresElevation, isTrue);
    });

    test('a capability set that did not opt in stays unsupported', () {
      const bare = CoreCapabilities(version: 'test');
      expect(bare.tunSupported, isFalse);
      expect(bare.tunRequiresElevation, isFalse);
    });
  });

  group('real sing-box validation', () {
    setUpAll(() {
      if (!_singbox.existsSync()) {
        markTestSkipped('sing-box binary not present');
      }
    });

    test('an injected tun inbound passes sing-box check', () {
      if (!_singbox.existsSync()) return;
      final dir = Directory.systemTemp.createTempSync('halo-tun-inject-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/config.json');
      file.writeAsStringSync(
        _prettyJson(applyTunInbound(_baseConfig())) + '\n',
      );
      final check = Process.runSync(_singbox.path, ['check', '-c', file.path]);
      expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
    });

    test('the legacy address field is rejected by the real core', () {
      if (!_singbox.existsSync()) return;
      final dir = Directory.systemTemp.createTempSync('halo-tun-legacy-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/config.json');
      final legacy = buildTunInbound()
        ..remove('address')
        ..['inet4_address'] = '172.19.0.1/30';
      file.writeAsStringSync(
        _prettyJson({
          'inbounds': [legacy],
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
          ],
        }),
      );
      final check = Process.runSync(_singbox.path, ['check', '-c', file.path]);
      expect(check.exitCode, isNot(0));
      expect('${check.stdout}${check.stderr}', contains('legacy tun address'));
    });
  });
}
