import 'dart:convert';

import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// User rules: validation, document shape, and ordering.
///
/// The document assertions are written against sing-box's rule vocabulary,
/// which is closed and strict — an unknown field fails `sing-box check` with
/// "json: unknown field" rather than being ignored. That is why a rule kind is
/// a closed enum here and not a free-text type the user types.
void main() {
  ProxyNode node() => ProxyNode(
    id: 'n1',
    fingerprint: 'fp',
    name: 'probe',
    protocol: ProxyProtocol.shadowsocks,
    server: '127.0.0.1',
    port: 1,
    secrets: const NodeSecrets(method: 'aes-256-gcm', password: 'x'),
  );

  List<Map<String, Object?>> rulesOf(ConfigRequest request) {
    final built = buildConfig(request, CoreCapabilities.singbox114);
    expect(built.ok, isTrue, reason: built.issues.map((i) => i.message).join('; '));
    final doc = built.config!.document;
    return [
      for (final r in (doc['route'] as Map)['rules'] as List)
        (r as Map).cast<String, Object?>(),
    ];
  }

  RoutingRule rule(
    RuleKind kind,
    String value, {
    RuleAction action = RuleAction.direct,
    bool enabled = true,
    String id = 'r1',
  }) => RoutingRule(
    id: id,
    kind: kind,
    value: value,
    action: action,
    enabled: enabled,
  );

  group('validation', () {
    test('an empty value is refused for every kind', () {
      for (final kind in RuleKind.values) {
        expect(validateRuleValue(kind, '   '), isNotNull, reason: kind.name);
      }
    });

    test('a URL is refused where a hostname is required', () {
      // Sing-box compares hostnames, so a pasted URL would never match. The
      // message has to say that, not just "invalid".
      final problem = validateRuleValue(RuleKind.domainSuffix, 'https://a.com');
      expect(problem, contains('http'));
      expect(validateRuleValue(RuleKind.domain, 'a.com/path'), isNotNull);
    });

    test('CIDR accepts IPv4 and IPv6 and rejects a bad prefix', () {
      expect(validateRuleValue(RuleKind.ipCidr, '10.0.0.0/8'), isNull);
      expect(validateRuleValue(RuleKind.ipCidr, '192.168.1.0/24'), isNull);
      expect(validateRuleValue(RuleKind.ipCidr, 'fd00::/8'), isNull);
      expect(validateRuleValue(RuleKind.ipCidr, '10.0.0.0/33'), isNotNull);
      expect(validateRuleValue(RuleKind.ipCidr, 'fd00::/129'), isNotNull);
      expect(validateRuleValue(RuleKind.ipCidr, '10.0.0.0'), isNotNull);
      expect(validateRuleValue(RuleKind.ipCidr, '10.0.0.256/8'), isNotNull);
    });

    test('port must be inside 1-65535', () {
      expect(validateRuleValue(RuleKind.port, '443'), isNull);
      expect(validateRuleValue(RuleKind.port, '0'), isNotNull);
      expect(validateRuleValue(RuleKind.port, '65536'), isNotNull);
      expect(validateRuleValue(RuleKind.port, 'abc'), isNotNull);
    });

    test('process name refuses a path', () {
      // The two are separate sing-box fields; a path in process_name would
      // silently match nothing.
      expect(validateRuleValue(RuleKind.processName, 'chrome.exe'), isNull);
      expect(validateRuleValue(RuleKind.processName, r'C:\a\chrome.exe'), isNotNull);
      expect(validateRuleValue(RuleKind.processPath, r'C:\a\chrome.exe'), isNull);
    });
  });

  group('document', () {
    test('each kind writes the field sing-box expects', () {
      final cases = <RuleKind, String>{
        RuleKind.domain: 'domain',
        RuleKind.domainSuffix: 'domain_suffix',
        RuleKind.domainKeyword: 'domain_keyword',
        RuleKind.ipCidr: 'ip_cidr',
        RuleKind.processName: 'process_name',
        RuleKind.processPath: 'process_path',
      };
      for (final entry in cases.entries) {
        final fragment = ruleToDocument(rule(entry.key, 'v'));
        expect(fragment, isNotNull, reason: entry.key.name);
        expect(fragment!.keys, contains(entry.value), reason: entry.key.name);
      }
    });

    test('port is emitted as an integer array, not a string', () {
      // sing-box types this field; a string fails the whole document.
      final fragment = ruleToDocument(rule(RuleKind.port, '443'))!;
      expect(fragment['port'], [443]);
      expect((fragment['port'] as List).first, isA<int>());
    });

    test('a disabled rule produces no fragment at all', () {
      expect(ruleToDocument(rule(RuleKind.domainSuffix, 'a.com', enabled: false)), isNull);
    });

    test('user rules land after every built-in guard', () {
      // Asserted by index in the rule array, not by substring position in the
      // encoded JSON: a substring probe passed even when the rule was moved
      // ahead of the guards, because the guards themselves had been reordered
      // in the same edit. Comparing positions in the actual list is the only
      // version that fails when the ordering regresses.
      final rules = rulesOf(
        ConfigRequest(
          node: node(),
          rules: [rule(RuleKind.domainSuffix, 'example.com')],
        ),
      );
      int indexOf(bool Function(Map<String, Object?>) predicate, String what) {
        final i = rules.indexWhere(predicate);
        expect(i, greaterThanOrEqualTo(0), reason: '$what missing from document');
        return i;
      }

      final privateAt = indexOf((r) => r['ip_is_private'] == true, 'ip_is_private');
      final dnsAt = indexOf((r) => r['protocol'] == 'dns', 'protocol dns');
      final userAt = indexOf(
        (r) => (r['domain_suffix'] as List?)?.contains('example.com') ?? false,
        'user rule',
      );
      expect(userAt, greaterThan(privateAt),
          reason: 'a user rule must not be able to shadow the LAN guard');
      expect(userAt, greaterThan(dnsAt),
          reason: 'a user rule must not shadow the DNS guard');
    });

    test('order is preserved: the list is the match order', () {
      final rules = rulesOf(
        ConfigRequest(
          node: node(),
          rules: [
            rule(RuleKind.domainSuffix, 'first.com', id: 'a'),
            rule(RuleKind.domainSuffix, 'second.com', id: 'b'),
            rule(RuleKind.domainSuffix, 'third.com', id: 'c'),
          ],
        ),
      );
      final encoded = jsonEncode(rules);
      expect(encoded.indexOf('first.com'), lessThan(encoded.indexOf('second.com')));
      expect(encoded.indexOf('second.com'), lessThan(encoded.indexOf('third.com')));
    });

    test('disabled rules are absent from the document', () {
      final rules = rulesOf(
        ConfigRequest(
          node: node(),
          rules: [
            rule(RuleKind.domainSuffix, 'on.com', id: 'a'),
            rule(RuleKind.domainSuffix, 'off.com', id: 'b', enabled: false),
          ],
        ),
      );
      final encoded = jsonEncode(rules);
      expect(encoded, contains('on.com'));
      expect(encoded, isNot(contains('off.com')));
    });

    test('global and direct modes ignore the rule list', () {
      // Otherwise the mode selector would lie: 全局 is supposed to send
      // everything through the node.
      for (final mode in [RouteMode.global, RouteMode.direct]) {
        final rules = rulesOf(
          ConfigRequest(
            node: node(),
            mode: mode,
            rules: [rule(RuleKind.domainSuffix, 'ignored.com')],
          ),
        );
        expect(jsonEncode(rules), isNot(contains('ignored.com')), reason: mode.wire);
      }
    });

    test('a direct rule and a proxy rule differ only in outbound', () {
      final direct = ruleToDocument(rule(RuleKind.domainSuffix, 'a.com'))!;
      final proxy = ruleToDocument(
        rule(RuleKind.domainSuffix, 'a.com', action: RuleAction.proxy),
      )!;
      expect(direct['outbound'], 'direct');
      expect(proxy['outbound'], 'proxy');
    });
  });

  group('serialization', () {
    test('round-trips through JSON', () {
      final original = RoutingRule(
        id: 'r7',
        kind: RuleKind.ipCidr,
        value: '10.0.0.0/8',
        action: RuleAction.direct,
        enabled: false,
        note: '内网',
      );
      final restored = RoutingRule.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
      );
      expect(restored, original);
    });

    test('an unknown kind or action falls back instead of throwing', () {
      // A database written by a newer build must not make this one unable to
      // read its own settings.
      final restored = RoutingRule.fromJson({
        'id': 'x',
        'kind': 'from-the-future',
        'value': 'v',
        'action': 'also-unknown',
      });
      expect(restored.kind, RuleKind.domainSuffix);
      expect(restored.action, RuleAction.proxy);
    });
  });
}
