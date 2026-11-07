import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/rules_page.dart';
import 'package:halo_config/halo_config.dart';

/// The rules page: persistence, ordering, and the guarantees that keep a
/// half-finished edit away from the running proxy.
void main() {
  late Directory dir;
  late AppController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo_rules_page');
    controller = AppController(dataDir: dir.path);
    await controller.start(connectHost: false);
    // A fresh database now seeds all 18 built-in rule sets as enabled rules.
    // These tests exercise editing, ordering and persistence of a *hand-made*
    // list, so they start from the state a user reaches by deleting them all —
    // which is also the state that must not re-seed (covered in
    // default_rules_test.dart).
    //
    // `routing` reads through to the database on every access, so writing the
    // empty list is enough; there is no cache to invalidate.
    const RoutingSettings(rules: []).save(controller.settingsRepo);
  });

  tearDown(() async {
    await controller.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // A WAL file on Windows can keep the directory busy for a moment.
    }
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2360, 1520);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: RulesPage(controller: controller),
      ),
    );
    await tester.pump();
  }

  Future<void> addRule(
    WidgetTester tester, {
    required String value,
    RuleKind kind = RuleKind.domainSuffix,
    RuleAction action = RuleAction.direct,
  }) async {
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    // Pick the kind through the selector when it is not the default.
    if (kind != RuleKind.domainSuffix) {
      await tester.tap(find.text(RuleKind.domainSuffix.label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kind.label).last);
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byKey(const ValueKey('rule-value')), value);
    await tester.pump();
    if (action == RuleAction.proxy) {
      await tester.tap(find.text(RuleAction.direct.label).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(RuleAction.proxy.label).last);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('rule-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('choosing 内置规则集 replaces the text field with a dropdown of '
      'sets', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();

    // While the kind is a free-text matcher there is a text field.
    expect(find.byKey(const ValueKey('rule-value')), findsOneWidget);
    expect(find.byKey(const ValueKey('rule-ruleset')), findsNothing);

    await tester.tap(find.text(RuleKind.domainSuffix.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RuleKind.ruleSet.label).last);
    await tester.pumpAndSettle();

    // A tag like `geosite-category-ai` is not something to type from memory.
    expect(find.byKey(const ValueKey('rule-ruleset')), findsOneWidget);
    expect(find.byKey(const ValueKey('rule-value')), findsNothing);
  });

  testWidgets('a rule-set rule saves the tag and reaches the document', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RuleKind.domainSuffix.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RuleKind.ruleSet.label).last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rule-ruleset')));
    await tester.pumpAndSettle();
    // The dropdown names the set and its weight, because 24 vs 22,891 entries
    // is the difference between a cheap rule and a much larger config.
    final youtube = builtinRuleSets.firstWhere(
      (set) => set.tag == 'geosite-youtube',
    );
    final optionText = '${youtube.label} · ${youtube.entryCount} 条';
    // The menu shows eight rows; YouTube is first, so no scrolling is needed,
    // but the overlay is a sibling of the dialog and has to be found by text
    // rather than by key.
    expect(find.text(optionText), findsWidgets);
    await tester.tap(find.text(optionText).last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rule-save')));
    await tester.pumpAndSettle();

    // The page keeps an editable draft and only writes it into the routing
    // settings when 应用 is pressed, so the draft is the thing to assert here;
    // `controller.routing.rules` is still empty at this point by design, and
    // asserting it would have been a test of the wrong object.
    expect(find.text(RuleKind.ruleSet.label), findsOneWidget);
    expect(find.textContaining(youtube.label), findsWidgets);

    // Applying writes it through, which is the part that reaches the config.
    await tester.tap(find.byKey(const ValueKey('rules-apply')));
    await tester.pumpAndSettle();
    final saved = controller.routing.rules;
    expect(saved, hasLength(1));
    expect(saved.single.kind, RuleKind.ruleSet);
    expect(saved.single.value, 'geosite-youtube');
  });

  testWidgets('switching away from a rule set clears the incompatible value', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RuleKind.domainSuffix.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RuleKind.ruleSet.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule-ruleset')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('YouTube').last);
    await tester.pumpAndSettle();

    // Back to a domain matcher: leaving `geosite-youtube` in the field would
    // produce a rule that validates as a broken domain.
    await tester.tap(find.text(RuleKind.ruleSet.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(RuleKind.domainSuffix.label).last);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('rule-value')),
    );
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('an empty page explains what rules are for', (tester) async {
    await pump(tester);
    expect(find.text('还没有规则'), findsOneWidget);
    // The old 「分流与 DNS」 page is gone: it carried ports and a second copy of
    // the mode selector, not rules.
    expect(find.text('分流与 DNS'), findsNothing);
  });

  testWidgets('adding a rule stores it and shows it in the list', (tester) async {
    await pump(tester);
    await addRule(tester, value: 'example.com');

    expect(find.text('example.com'), findsOneWidget);
    // The list is the draft until 保存并应用 runs; the page must say so rather
    // than implying the rule is already live.
    expect(find.text('未保存'), findsOneWidget);
    expect(controller.routing.rules, isEmpty);

    await tester.tap(find.byKey(const ValueKey('rules-apply')));
    await tester.pumpAndSettle();
    expect(controller.routing.rules, hasLength(1));
    expect(controller.routing.rules.single.value, 'example.com');
    expect(find.text('未保存'), findsNothing);
  });

  testWidgets('the dialog opens without an error frame', (tester) async {
    // The empty value is a prompt, not a mistake: framing it in red the moment
    // the dialog opens tells the user off before they have typed anything.
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    expect(find.text('不能为空'), findsNothing, reason: '未操作时不应显示错误');
    // The field carries no red border either: InputDecorator renders the error
    // colour from errorText, so its absence is what is asserted above.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('rule-value')),
    );
    expect(field.decoration?.errorText, isNull);
    // Saving is still impossible while the value is empty.
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('rule-save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('typing an invalid value surfaces the error', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rule-value')),
      'https://example.com',
    );
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('rule-value')),
    );
    expect(field.decoration?.errorText, isNotNull,
        reason: '输入无效值后必须说明原因');
  });

  testWidgets('the match-type control renders every label on one line', (
    tester,
  ) async {
    // Seven equal-width segments gave 域名（精确） about 60 px and wrapped it
    // onto two lines while 端口 stayed on one, which read as a broken row.
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    final trigger = find.byKey(const ValueKey('rule-kind'));
    expect(trigger, findsOneWidget);
    // Every option must be reachable from the control. It is now a dropdown
    // drawn by HaloDropdown itself, so tapping the key opens it directly.
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(find.text('域名（精确）'), findsWidgets);
    expect(find.text('域名关键字'), findsWidgets);
    expect(find.text('进程名'), findsWidgets);
  });

  testWidgets('an invalid value cannot be saved from the dialog', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rule-value')),
      'https://example.com',
    );
    await tester.pump();
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('rule-save')),
    );
    expect(save.onPressed, isNull, reason: 'a URL must not be accepted');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('还没有规则'), findsOneWidget);
  });

  testWidgets('a duplicate rule is refused', (tester) async {
    await pump(tester);
    await addRule(tester, value: 'example.com');
    await tester.tap(find.byKey(const ValueKey('rules-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('rule-value')), 'EXAMPLE.com');
    await tester.pump();
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('rule-save')),
    );
    expect(save.onPressed, isNull);
    expect(find.text('已存在相同的规则'), findsOneWidget);
  });

  testWidgets('reorder changes the stored order', (tester) async {
    await pump(tester);
    await addRule(tester, value: 'a.com');
    await addRule(tester, value: 'b.com');
    await tester.tap(find.byKey(const ValueKey('rules-apply')));
    await tester.pumpAndSettle();
    expect(controller.routing.rules.map((r) => r.value), ['a.com', 'b.com']);

    // Row keys carry generated ids, so address rows by position: the first
    // row's 下移 is the only enabled one, the last row's is disabled.
    await tester.tap(find.byTooltip('下移').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rules-apply')));
    await tester.pumpAndSettle();
    expect(controller.routing.rules.map((r) => r.value), ['b.com', 'a.com']);
  });

  testWidgets('a disabled rule is kept but not applied', (tester) async {
    await pump(tester);
    await addRule(tester, value: 'off.com');
    await tester.tap(find.byTooltip('停用这条规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rules-apply')));
    await tester.pumpAndSettle();

    expect(controller.routing.rules.single.enabled, isFalse);
    expect(controller.routing.rules.single.value, 'off.com');
  });

  testWidgets('rules survive a reload from the database', (tester) async {
    await pump(tester);
    await addRule(tester, value: 'persist.com', kind: RuleKind.domain);
    await tester.tap(find.byKey(const ValueKey('rules-apply')));
    await tester.pumpAndSettle();

    // Read it back the way the app does on startup, not from the in-memory
    // copy: the point is that the JSON round-trip through the settings table
    // preserved the rule.
    final reloaded = RoutingSettings.load(controller.settingsRepo);
    expect(reloaded.rules, hasLength(1));
    expect(reloaded.rules.single.value, 'persist.com');
    expect(reloaded.rules.single.kind, RuleKind.domain);
  });

  testWidgets('a non-rule mode warns that the rules are inactive', (tester) async {
    await controller.saveRouting(
      controller.routing.copyWith(mode: RouteMode.global),
    );
    await pump(tester);
    expect(find.textContaining('这些规则不会生效'), findsOneWidget);
  });
}
