import 'dart:convert';
import 'dart:io';

import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// The pinned core, used to prove the generated document is one the core
/// actually accepts. A generator that emits plausible JSON the core refuses is
/// exactly the failure these tests exist to catch.
///
/// Resolved by walking up from the current directory instead of assuming the
/// test runs from the package root: `dart test` does not promise that, and a
/// wrong assumption here silently turns both core tests into skips — a green
/// run that verified nothing.
final File _singbox = _findSingbox();

File _findSingbox() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate =
        File('${dir.path}${Platform.pathSeparator}prototype${Platform.pathSeparator}bin${Platform.pathSeparator}sing-box.exe');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  // Also try the package-relative location for a direct `dart test` run.
  return File(
    '${Directory.current.path}${Platform.pathSeparator}..${Platform.pathSeparator}..'
    '${Platform.pathSeparator}prototype${Platform.pathSeparator}bin${Platform.pathSeparator}sing-box.exe',
  );
}

ProxyNode _node() => withIdentity(ProxyNode(
      id: '',
      fingerprint: '',
      name: 'test-trojan',
      protocol: ProxyProtocol.trojan,
      server: 'example.com',
      port: 443,
      secrets: const NodeSecrets(password: 'pw'),
      tls: const TlsConfig(kind: TlsKind.tls, serverName: 'example.com'),
    ));

RoutingRule _ruleSetRule(String tag, {RuleAction action = RuleAction.direct}) =>
    RoutingRule(
      id: 'r-$tag',
      kind: RuleKind.ruleSet,
      value: tag,
      action: action,
    );

ConfigBuildResult _build(List<RoutingRule> rules, {RouteMode mode = RouteMode.rule}) =>
    buildConfig(
      ConfigRequest(node: _node(), rules: rules, mode: mode),
      CoreCapabilities.singbox114,
    );

Map<String, Object?> _route(ConfigBuildResult result) =>
    (result.config!.document['route'] as Map).cast<String, Object?>();

void main() {
  group('built-in rule set catalogue', () {
    test('carries the reference client\'s sets and entry counts', () {
      expect(builtinRuleSets, hasLength(18));
      expect(builtinRuleSetEntryTotal, greaterThan(30000));
      // The two big ones are the reason inline embedding is worth measuring.
      expect(builtinRuleSetByTag('geoip-cn')!.entryCount, greaterThan(9000));
      expect(
        builtinRuleSetByTag('geosite-geolocation')!.entryCount,
        greaterThan(20000),
      );
      for (final set in builtinRuleSets) {
        expect(set.label, isNotEmpty);
        expect(set.kind, anyOf('domain', 'ip'));
        expect(set.entryCount, greaterThan(0));
      }
    });

    test('every payload decodes to sing-box rule maps', () {
      for (final set in builtinRuleSets) {
        final rules = decodeRuleSetPayload(set);
        expect(rules, isNotEmpty, reason: set.tag);
        var counted = 0;
        for (final rule in rules) {
          // Exactly one matcher key per payload object, plus no outbound: the
          // outbound belongs to the referencing rule, not the set.
          expect(rule.keys, isNot(contains('outbound')), reason: set.tag);
          final matcher = rule.keys.single;
          expect(
            matcher,
            anyOf('domain', 'domain_suffix', 'ip_cidr'),
            reason: '${set.tag} used $matcher',
          );
          counted += (rule[matcher]! as List).length;
        }
        expect(counted, set.entryCount, reason: '${set.tag} count mismatch');
      }
    });

    test('a tag from the catalogue validates, an unknown one does not', () {
      expect(validateRuleValue(RuleKind.ruleSet, 'geosite-youtube'), isNull);
      expect(
        validateRuleValue(RuleKind.ruleSet, 'geosite-nope'),
        contains('没有这个内置规则集'),
      );
    });
  });

  group('route.rule_set', () {
    test('only referenced sets are embedded, deduplicated', () {
      final result = _build([
        _ruleSetRule('geosite-github'),
        // Same set twice: sing-box rejects a duplicate tag, and its error does
        // not name the rule that caused it, so the generator must dedupe.
        _ruleSetRule('geosite-github'),
        _ruleSetRule('geoip-private'),
      ]);

      final sets = (_route(result)['rule_set']! as List).cast<Map>();
      expect(sets.map((s) => s['tag']), ['geosite-github', 'geoip-private']);
      expect(sets.every((s) => s['type'] == 'inline'), isTrue);
    });

    test('no rule sets are embedded when no rule references one', () {
      final result = _build(const []);
      expect(_route(result).containsKey('rule_set'), isFalse);
    });

    test('全局 and 直连 embed nothing, because no rule runs there', () {
      for (final mode in [RouteMode.global, RouteMode.direct]) {
        final result = _build([_ruleSetRule('geosite-google')], mode: mode);
        expect(
          _route(result).containsKey('rule_set'),
          isFalse,
          reason: '$mode',
        );
      }
    });

    test('a disabled rule set rule embeds nothing', () {
      final result = _build([
        _ruleSetRule('geosite-youtube').copyWith(enabled: false),
      ]);
      expect(_route(result).containsKey('rule_set'), isFalse);
    });

    test('a stored tag the catalogue no longer has is dropped, not emitted', () {
      // An old database can carry a tag this build does not ship. Emitting it
      // would make every apply fail with a core-side "rule-set not found".
      final result = _build([_ruleSetRule('geosite-removed-in-a-future-build')]);
      expect(_route(result).containsKey('rule_set'), isFalse);
      expect(result.ok, isTrue);
    });

    test('the rule list references the set by tag with the chosen outbound', () {
      final result = _build([
        _ruleSetRule('geosite-netflix', action: RuleAction.proxy),
      ]);
      final rules = (_route(result)['rules']! as List).cast<Map>();
      final rule = rules.firstWhere((r) => r['rule_set'] != null);
      expect(rule['rule_set'], ['geosite-netflix']);
      expect(rule['outbound'], 'proxy');
    });
  });

  group('real core validation', () {
    test('the core accepts a document embedding every rule set', () {
      final result = _build([
        for (final set in builtinRuleSets) _ruleSetRule(set.tag),
      ]);
      expect(result.ok, isTrue, reason: result.issues.map((i) => i.message).join('; '));

      // The full catalogue is ~640 KB of JSON. That is the number this test is
      // really about: if the embedding strategy ever grows past what the core
      // will parse at startup, this is where it shows up.
      final json = result.config!.toJsonString();
      expect(json.length, greaterThan(500000));

      final temp = Directory.systemTemp.createTempSync('halo-ruleset-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/config.json')..writeAsStringSync(json);
      final check = Process.runSync(_singbox.path, ['check', '-c', file.path]);
      expect(
        check.exitCode,
        0,
        reason: 'core rejected the document: ${check.stdout}${check.stderr}',
      );
    }, skip: _singbox.existsSync() ? false : 'pinned sing-box not present');

    test('a single-set document is valid too', () {
      final result = _build([_ruleSetRule('geosite-private')]);
      final temp = Directory.systemTemp.createTempSync('halo-ruleset1-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/config.json')
        ..writeAsStringSync(jsonEncode(result.config!.document));
      final check = Process.runSync(_singbox.path, ['check', '-c', file.path]);
      expect(check.exitCode, 0,
          reason: '${check.stdout}${check.stderr}');
    }, skip: _singbox.existsSync() ? false : 'pinned sing-box not present');
  });
}
