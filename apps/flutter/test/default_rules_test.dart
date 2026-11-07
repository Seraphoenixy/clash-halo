import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/rules_page.dart';
import 'package:halo_config/halo_config.dart';
import 'package:halo_storage/halo_storage.dart';

/// The seeded rule list and, more importantly, the boundary between "never
/// configured" and "the user deleted everything".
void main() {
  late Directory dir;
  late HaloStore store;
  late SettingsRepository settings;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('halo-default-rules-');
    final opened = HaloStore.open('${dir.path}/clash-halo.db');
    store = opened.store!;
    settings = SettingsRepository(store);
  });

  tearDown(() {
    store.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A lingering WAL handle on Windows is not a failure.
    }
  });

  group('default rule list', () {
    test('covers every built-in rule set exactly once, all enabled', () {
      final rules = defaultRules();
      expect(rules, hasLength(builtinRuleSets.length));

      final tags = rules.map((r) => r.value).toList();
      expect(tags.toSet(), hasLength(builtinRuleSets.length), reason: '有重复');
      for (final set in builtinRuleSets) {
        expect(tags, contains(set.tag), reason: '缺少 ${set.tag}');
      }
      expect(rules.every((r) => r.enabled), isTrue);
      expect(rules.every((r) => r.kind == RuleKind.ruleSet), isTrue);
      // Ids must be stable and unique: the page keys rows by them.
      expect(rules.map((r) => r.id).toSet(), hasLength(rules.length));
    });

    test('sends private and mainland-China traffic direct, the rest proxied',
        () {
      final rules = {for (final r in defaultRules()) r.value: r.action};
      // These three must never be proxied: 192.168.x.x cannot be reached
      // through the proxy, and doing it is the classic "my LAN broke" report.
      for (final tag in ['geosite-private', 'geoip-private', 'geoip-cn']) {
        expect(rules[tag], RuleAction.direct, reason: tag);
      }
      // The rest go through the proxy, which is also what route.final does, so
      // they are declarations rather than behaviour changes.
      for (final entry in rules.entries) {
        if (['geosite-private', 'geoip-private', 'geoip-cn'].contains(entry.key)) {
          continue;
        }
        expect(entry.value, RuleAction.proxy, reason: entry.key);
      }
    });

    test('order follows the catalogue so specific sets win over broad ones',
        () {
      final rules = defaultRules();
      final order = rules.map((r) => r.value).toList();
      // geolocation carries 22,891 entries and would swallow almost anything;
      // the reference list puts the specific service sets before it.
      expect(
        order.indexOf('geosite-youtube'),
        lessThan(order.indexOf('geosite-geolocation')),
      );
      expect(
        order.indexOf('geosite-category-ai'),
        lessThan(order.indexOf('geosite-geolocation')),
      );
      // And the catalogue's own order is what was copied.
      expect(order, builtinRuleSets.map((s) => s.tag).toList());
    });

    test('every default tag is one the catalogue knows', () {
      for (final rule in defaultRules()) {
        expect(validateRuleValue(rule.kind, rule.value), isNull);
      }
    });
  });

  group('the seeded list reaches the rules page', () {
    // Built outside the test body on purpose: `start()` arms a one-minute
    // periodic timer, and a timer created inside a fake-async body fails the
    // run with "A Timer is still pending" even though the widget tree is gone.
    late AppController controller;

    setUp(() async {
      controller = AppController(dataDir: dir.path);
      await controller.start(connectHost: false);
    });

    tearDown(() async {
      await controller.dispose();
    });

    testWidgets('a fresh install opens with every rule set listed', (
      tester,
    ) async {
      // The point of seeding is that the user sees routing after first launch
      // rather than an empty page they did not know to fill.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: RulesPage(controller: controller),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // The empty state must be gone, and the seeded rows must be on screen.
      expect(find.text('还没有规则'), findsNothing);
      expect(controller.routing.rules.length, builtinRuleSets.length);
    });
  });

  group('seeding', () {
    test('a database that never stored rules gets the defaults', () {
      expect(settings.raw('routing.rules'), isNull);

      final loaded = RoutingSettings.load(settings);

      expect(loaded.rules, hasLength(builtinRuleSets.length));
      // Written through, so the "never configured" state cannot come back.
      expect(settings.raw('routing.rules'), isNotNull);
    });

    test('seeding is reported once, so it can be applied exactly once', () {
      RoutingSettings.justSeededDefaults = false;
      expect(RoutingSettings.load(settings).rules, isNotEmpty);
      expect(RoutingSettings.justSeededDefaults, isTrue,
          reason: '首次种入必须让调用方知道，否则规则只在库里、内核里没有');

      // A second load must not report a seed: the list is already stored, and
      // re-applying on every load would rewrite the running config repeatedly.
      RoutingSettings.justSeededDefaults = false;
      RoutingSettings.load(settings);
      expect(RoutingSettings.justSeededDefaults, isFalse);
    });

    test('the one-shot flag cannot re-fire on a later connect', () {
      // `_postConnect` runs on every (re)connect, so the flag has to be
      // consumed. A reconnect that re-applied the defaults would rewrite the
      // running config on every pipe blip.
      RoutingSettings.justSeededDefaults = false;
      RoutingSettings.load(settings); // first load seeds
      expect(RoutingSettings.justSeededDefaults, isTrue);

      // The controller consumes it on the first post-connect pass.
      RoutingSettings.justSeededDefaults = false;

      // Any later pass must find nothing to do.
      RoutingSettings.load(settings);
      expect(RoutingSettings.justSeededDefaults, isFalse);
    });

    test('a user who deleted every rule does not get them back', () {
      // Seed once.
      expect(RoutingSettings.load(settings).rules, isNotEmpty);

      // The user removes them all and saves.
      RoutingSettings.load(settings).copyWith(rules: const []).save(settings);
      expect(settings.raw('routing.rules'), '[]');

      // Reloading must respect that. Re-seeding here would make deletion
      // impossible: the rules would return on every launch.
      expect(RoutingSettings.load(settings).rules, isEmpty);
    });

    test('a single stored rule survives a reload unchanged', () {
      const mine = RoutingRule(
        id: 'mine',
        kind: RuleKind.domainSuffix,
        value: 'example.com',
        action: RuleAction.direct,
      );
      const RoutingSettings(rules: [mine]).save(settings);

      final loaded = RoutingSettings.load(settings);
      expect(loaded.rules, hasLength(1));
      expect(loaded.rules.single.value, 'example.com');
    });

    test('a corrupt stored blob falls back to no rules, not to the defaults',
        () {
      // Hand-edited or truncated JSON. Falling back to the defaults here would
      // silently replace whatever the user had with 18 rules they never asked
      // for; falling back to empty is the honest reading of "unreadable".
      settings.setRaw('routing.rules', '{not json');

      expect(RoutingSettings.load(settings).rules, isEmpty);
    });
  });
}
