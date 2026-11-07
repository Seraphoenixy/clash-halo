/// User-authored routing rules.
///
/// Rules live in the config package, not the domain package: they are an input
/// to document generation, they never touch the node table, and the generator
/// is the only thing that consumes them.
///
/// A rule is stored as a small typed record rather than a raw
/// `DOMAIN-SUFFIX,example.com,DIRECT` string because a string has to be
/// re-parsed on every read and every malformed rule then becomes a runtime
/// failure at apply time. Parsing happens once, on input, where the error can
/// be shown next to the field the user is editing.
library;

import 'builtin_rulesets.dart';

/// What a rule matches on.
///
/// Deliberately a closed set. sing-box accepts many more matchers, but each one
/// added here is a promise that the UI can explain it and the generator can
/// validate it without launching the core to find out.
enum RuleKind {
  domain('domain', '域名（精确）'),
  domainSuffix('domain_suffix', '域名后缀'),
  domainKeyword('domain_keyword', '域名关键字'),
  ipCidr('ip_cidr', 'IP 段'),
  processName('process_name', '进程名'),
  processPath('process_path', '进程路径'),
  port('port', '目标端口'),

  /// Matches everything in one of the built-in rule sets.
  ///
  /// A separate kind rather than an eighth matcher, because the operand is not
  /// a pattern the user writes: it is the [tag] of a set shipped in
  /// `builtin_rulesets.dart`. Keeping it distinct means [validateRuleValue]
  /// can check the tag against the catalogue instead of guessing what a
  /// plausible domain looks like.
  ruleSet('rule_set', '内置规则集');

  const RuleKind(this.wire, this.label);

  /// The sing-box rule field this kind writes.
  final String wire;

  /// What the rule page calls it.
  final String label;

  static RuleKind fromWire(String value) => RuleKind.values.firstWhere(
    (k) => k.wire == value,
    orElse: () => RuleKind.domainSuffix,
  );
}

/// Where a matching connection goes.
///
/// `proxy` is the selected node; `direct` bypasses it. REJECT is absent on
/// purpose: this app's promise is "some traffic should not go through the
/// proxy", not a firewall, and a rule that silently drops the user's traffic is
/// a much bigger hammer than the feature asks for.
enum RuleAction {
  direct('direct', '直连'),
  proxy('proxy', '代理');

  const RuleAction(this.wire, this.label);

  final String wire;
  final String label;

  static RuleAction fromWire(String value) =>
      RuleAction.values.firstWhere((a) => a.wire == value, orElse: () => RuleAction.proxy);
}

/// One user rule: match [value] by [kind], send the connection to [action].
class RoutingRule {
  const RoutingRule({
    required this.id,
    required this.kind,
    required this.value,
    required this.action,
    this.enabled = true,
    this.note = '',
  });

  /// Stable identity for the UI's reorder/remove operations. Not persisted
  /// semantics: it exists so a list rebuild does not have to key on [value],
  /// which the user can duplicate.
  final String id;

  final RuleKind kind;

  /// The matcher's operand. `domain_suffix` takes one suffix, `ip_cidr` one
  /// CIDR, `port` one number — a single value per rule keeps every rule
  /// explainable as one line in the list and one line in the document.
  final String value;

  final RuleAction action;
  final bool enabled;

  /// Free text the user attaches to remember why the rule exists.
  final String note;

  RoutingRule copyWith({
    RuleKind? kind,
    String? value,
    RuleAction? action,
    bool? enabled,
    String? note,
  }) => RoutingRule(
    id: id,
    kind: kind ?? this.kind,
    value: value ?? this.value,
    action: action ?? this.action,
    enabled: enabled ?? this.enabled,
    note: note ?? this.note,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.wire,
    'value': value,
    'action': action.wire,
    'enabled': enabled,
    if (note.isNotEmpty) 'note': note,
  };

  factory RoutingRule.fromJson(Map<String, Object?> json) => RoutingRule(
    id: json['id'] as String? ?? '',
    kind: RuleKind.fromWire(json['kind'] as String? ?? ''),
    value: json['value'] as String? ?? '',
    action: RuleAction.fromWire(json['action'] as String? ?? ''),
    enabled: json['enabled'] as bool? ?? true,
    note: json['note'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is RoutingRule &&
      other.id == id &&
      other.kind == kind &&
      other.value == value &&
      other.action == action &&
      other.enabled == enabled &&
      other.note == note;

  @override
  int get hashCode => Object.hash(id, kind, value, action, enabled, note);
}

/// The rule list a fresh install starts with: every built-in rule set, enabled,
/// in the catalogue's match order.
///
/// Mirrors the reference client's routing intent. Its own rule list sends
/// private ranges and mainland-China IPs direct and everything else through the
/// proxy; this app has one proxy outbound and `route.final = proxy`, so the
/// direct entries are the ones that actually change behaviour and the rest are
/// declarations that still match what happens.
///
/// Order is deliberate and is the catalogue's order, not alphabetical: the
/// reference list puts the specific service sets before the broad
/// `geolocation` one, so a domain that belongs to both is classified by the
/// specific set.
List<RoutingRule> defaultRules() => [
  for (var i = 0; i < builtinRuleSets.length; i++)
    RoutingRule(
      id: builtinRuleSets[i].tag,
      kind: RuleKind.ruleSet,
      value: builtinRuleSets[i].tag,
      // The sets that bypass the proxy, by tag rather than by position: the
      // catalogue can be regenerated with a different order, and a positional
      // table would then silently send private traffic through the proxy.
      action: _directRuleSets.contains(builtinRuleSets[i].tag)
          ? RuleAction.direct
          : RuleAction.proxy,
      note: '',
    ),
];

/// Built-in sets that should bypass the proxy.
///
/// Private ranges, the mainland IP table, and private domains must never be
/// proxied: sending 192.168.x.x or a local host name through the proxy cannot
/// work, and routing it there is the classic "the proxy broke my LAN" report.
const Set<String> _directRuleSets = {
  'geosite-private',
  'geoip-private',
  'geoip-cn',
};

/// Why a rule cannot be used, or null when it is fine.
///
/// Every message names the field it is about: the UI shows it under the input,
/// so "格式不对" alone would leave the user guessing which part.
String? validateRuleValue(RuleKind kind, String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '不能为空';
  switch (kind) {
    case RuleKind.domain:
    case RuleKind.domainSuffix:
      // A scheme or a path here means the user pasted a URL, which would
      // silently never match: sing-box compares hostnames.
      if (value.contains('://')) return '只填主机名，不要带 http:// 等前缀';
      if (value.contains('/')) return '不要带路径';
      if (value.contains(' ')) return '不能包含空格';
      if (RegExp(r'^\d').hasMatch(value) && !value.contains('.')) {
        return '看起来不像域名';
      }
      return null;
    case RuleKind.domainKeyword:
      if (value.contains(' ')) return '不能包含空格';
      return null;
    case RuleKind.ipCidr:
      return _validateCidr(value);
    case RuleKind.processName:
      if (value.contains('/') || value.contains(r'\')) {
        return '只填文件名，路径用「进程路径」';
      }
      if (value.contains(' ')) return '不能包含空格';
      return null;
    case RuleKind.processPath:
      return null;
    case RuleKind.port:
      final port = int.tryParse(value);
      if (port == null) return '必须是数字';
      if (port < 1 || port > 65535) return '端口范围是 1–65535';
      return null;
    case RuleKind.ruleSet:
      // Checked against the catalogue, not against a pattern: a tag that does
      // not exist would generate a document the core rejects with
      // "rule-set not found", which reads as a client fault rather than a
      // field the user can fix.
      if (builtinRuleSetByTag(value) == null) {
        return '没有这个内置规则集：$value';
      }
      return null;
  }
}

String? _validateCidr(String value) {
  final parts = value.split('/');
  if (parts.length != 2) return '格式应为 地址/前缀，例如 10.0.0.0/8';
  final addr = parts[0];
  final prefix = int.tryParse(parts[1]);
  if (prefix == null) return '前缀长度必须是数字';
  final isV6 = addr.contains(':');
  final maxPrefix = isV6 ? 128 : 32;
  if (prefix < 0 || prefix > maxPrefix) {
    return '前缀长度范围是 0–$maxPrefix';
  }
  if (isV6) {
    if (!RegExp(r'^[0-9a-fA-F:]+$').hasMatch(addr) || addr.split(':').length > 8) {
      return 'IPv6 地址格式不对';
    }
    return null;
  }
  final octets = addr.split('.');
  if (octets.length != 4) return 'IPv4 地址应为四段';
  for (final o in octets) {
    final n = int.tryParse(o);
    if (n == null || n < 0 || n > 255) return 'IPv4 每段范围是 0–255';
  }
  return null;
}

/// The document fragment for one rule, as sing-box wants it.
///
/// Returns null for a disabled rule so callers can filter without branching.
/// The caller is responsible for [validateRuleValue]; this method assumes it
/// already passed, so a malformed value cannot reach the document.
Map<String, Object?>? ruleToDocument(RoutingRule rule) {
  if (!rule.enabled) return null;
  final value = rule.value.trim();
  if (value.isEmpty) return null;
  switch (rule.kind) {
    case RuleKind.ruleSet:
      return {
        'rule_set': [value],
        'outbound': rule.action.wire,
      };
    case RuleKind.port:
      final port = int.tryParse(value);
      if (port == null) return null;
      return {'port': [port], 'outbound': rule.action.wire};
    case RuleKind.processName:
    case RuleKind.processPath:
    case RuleKind.domain:
    case RuleKind.domainSuffix:
    case RuleKind.domainKeyword:
    case RuleKind.ipCidr:
      return {
        rule.kind.wire: [value],
        'outbound': rule.action.wire,
      };
  }
}
