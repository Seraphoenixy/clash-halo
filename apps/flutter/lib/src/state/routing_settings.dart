import 'dart:convert';

import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

/// The routing half of the generated config, as the user last set it.
///
/// This exists because those values used to live in a page's `State`: the
/// routing page held port/DNS/mode in local fields, so reopening the app forgot
/// them, and "应用配置" on the overview page rebuilt the document from defaults.
/// Worse, switching a node rebuilt the config with `RouteMode.rule` and default
/// ports regardless of what the user had configured, silently undoing both.
///
/// Persisting them makes one source of truth for "how traffic should be routed",
/// read by every path that generates a config: node selection, the mode
/// selector on the overview page, and the routing page's apply button.
/// The log levels the generator may emit.
///
/// `trace` is deliberately absent: sing-box accepts it, but at that level a
/// single browsing session fills the rotated log files (2 MiB x 3) and makes the
/// log page useless. The five here are the ones a user can reason about.
const List<String> kLogLevels = ['silent', 'error', 'warn', 'info', 'debug'];

/// Falls back to `warn` for anything unknown.
///
/// A stored value the core does not accept would make every later apply fail
/// with `initialize log: unknown level`, which reads as a broken client rather
/// than as one bad setting. The database is the only writer, but it is also
/// hand-editable and survives downgrades.
String normalizeLogLevel(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  return kLogLevels.contains(value) ? value : 'warn';
}

class RoutingSettings {
  const RoutingSettings({
    this.mode = RouteMode.rule,
    this.mixedPort = 7890,
    this.clashApiPort = 9090,
    this.enableClashApi = true,
    this.dnsEnabled = true,
    this.dnsServer = 'https://223.5.5.5/dns-query',
    this.directDns = '223.5.5.5',
    this.fakeIp = false,
    this.logLevel = 'warn',
    this.rules = const [],
  });

  final RouteMode mode;
  final int mixedPort;
  final int clashApiPort;
  final bool enableClashApi;
  final bool dnsEnabled;
  final String dnsServer;
  final String directDns;
  final bool fakeIp;

  /// `log.level` of the generated document. Lower levels make the core write
  /// more, which is why `debug` is offered with a warning rather than as a
  /// default.
  final String logLevel;

  /// User rules, in list order. Only applied in [RouteMode.rule].
  final List<RoutingRule> rules;

  static const _kMode = 'routing.mode';
  static const _kMixed = 'routing.mixedPort';
  static const _kClashApi = 'routing.clashApiPort';
  static const _kClashApiEnabled = 'routing.clashApiEnabled';
  static const _kDnsEnabled = 'routing.dnsEnabled';
  static const _kDnsServer = 'routing.dnsServer';
  static const _kDirectDns = 'routing.directDns';
  static const _kFakeIp = 'routing.fakeIp';
  static const _kLogLevel = 'routing.logLevel';
  static const _kRules = 'routing.rules';

  /// Reads the stored settings, falling back per-field so a partially written
  /// row (an older version, a hand-edited database) cannot lose the rest.
  static RoutingSettings load(SettingsRepository repo) {
    final defaults = const RoutingSettings();
    return RoutingSettings(
      mode: RouteMode.fromWire(repo.raw(_kMode) ?? defaults.mode.wire),
      mixedPort: _int(repo.raw(_kMixed), defaults.mixedPort),
      clashApiPort: _int(repo.raw(_kClashApi), defaults.clashApiPort),
      enableClashApi: _bool(repo.raw(_kClashApiEnabled), defaults.enableClashApi),
      dnsEnabled: _bool(repo.raw(_kDnsEnabled), defaults.dnsEnabled),
      dnsServer: repo.raw(_kDnsServer) ?? defaults.dnsServer,
      directDns: repo.raw(_kDirectDns) ?? defaults.directDns,
      fakeIp: _bool(repo.raw(_kFakeIp), defaults.fakeIp),
      logLevel: normalizeLogLevel(repo.raw(_kLogLevel)),
      // A missing key is "never configured", not "no rules": the two must not
      // be conflated. An empty stored array is a user who deleted every rule,
      // and re-seeding that on each load would make deletion impossible.
      rules: _loadRules(repo),
    );
  }

  /// The stored rules, or the shipped defaults on a database that has never
  /// stored any.
  ///
  /// The defaults are *written through* rather than only returned, so the next
  /// load sees a stored array and the "never configured" state cannot come
  /// back. Without that write, a user who deleted the defaults would be given
  /// them again on the next launch, because the key would still be absent.
  static List<RoutingRule> _loadRules(SettingsRepository repo) {
    final raw = repo.raw(_kRules);
    if (raw == null) {
      final seeded = defaultRules();
      if (seeded.isEmpty) return const [];
      repo.setRaw(_kRules, jsonEncode([for (final r in seeded) r.toJson()]));
      // Recorded so the controller knows this load created the list and has to
      // apply it: a rule list that exists only in the database reads as "the
      // rules are on" while the running core still has the four built-ins.
      justSeededDefaults = true;
      return seeded;
    }
    return _rules(raw);
  }

  /// Whether the most recent [load] created the default rule list.
  ///
  /// Cleared by the caller once it has acted on it. A process-wide flag rather
  /// than a return value because [load] is called from a getter that many
  /// widgets reach; threading a result through them would touch every call site
  /// for a one-shot launch concern.
  static bool justSeededDefaults = false;

  /// Rules are stored as one JSON array under a single key.
  ///
  /// One row, not one row per rule: the list is ordered, and an ordering
  /// spread across rows would have to be rebuilt from a sort index that can
  /// drift. A document that fails to parse falls back to no rules rather than
  /// taking the whole settings load down — a bad blob must not make the app
  /// unable to start.
  static List<RoutingRule> _rules(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map<String, Object?>) RoutingRule.fromJson(item),
      ];
    } on FormatException {
      return const [];
    }
  }

  void save(SettingsRepository repo) {
    repo.setRaw(_kMode, mode.wire);
    repo.setRaw(_kMixed, '$mixedPort');
    repo.setRaw(_kClashApi, '$clashApiPort');
    repo.setRaw(_kClashApiEnabled, enableClashApi ? '1' : '0');
    repo.setRaw(_kDnsEnabled, dnsEnabled ? '1' : '0');
    repo.setRaw(_kDnsServer, dnsServer);
    repo.setRaw(_kDirectDns, directDns);
    repo.setRaw(_kFakeIp, fakeIp ? '1' : '0');
    repo.setRaw(_kLogLevel, logLevel);
    repo.setRaw(_kRules, jsonEncode([for (final r in rules) r.toJson()]));
  }

  RoutingSettings copyWith({
    RouteMode? mode,
    int? mixedPort,
    int? clashApiPort,
    bool? enableClashApi,
    bool? dnsEnabled,
    String? dnsServer,
    String? directDns,
    bool? fakeIp,
    String? logLevel,
    List<RoutingRule>? rules,
  }) => RoutingSettings(
    mode: mode ?? this.mode,
    mixedPort: mixedPort ?? this.mixedPort,
    clashApiPort: clashApiPort ?? this.clashApiPort,
    enableClashApi: enableClashApi ?? this.enableClashApi,
    dnsEnabled: dnsEnabled ?? this.dnsEnabled,
    dnsServer: dnsServer ?? this.dnsServer,
    directDns: directDns ?? this.directDns,
    fakeIp: fakeIp ?? this.fakeIp,
    logLevel: logLevel ?? this.logLevel,
    rules: rules ?? this.rules,
  );

  /// Builds the sing-box document for [node] with these settings.
  ///
  /// TUN stays out of the document on purpose: the host composes its own
  /// runtime config (a copy plus a tun inbound) when the user enables TUN, and a
  /// tun inbound baked in here would be started unelevated and fail.
  ConfigBuildResult build(ProxyNode node) => buildConfig(
    ConfigRequest(
      node: node,
      mode: mode,
      ports: InboundPorts(
        mixed: mixedPort,
        clashApi: clashApiPort,
        enableClashApi: enableClashApi,
      ),
      dns: DnsSettings(
        enabled: dnsEnabled,
        server: dnsServer,
        directServer: directDns,
        fakeAddress: fakeIp,
      ),
      tun: const TunSettings(enabled: false),
      // The generator has carried this parameter all along; nothing passed it,
      // so every document said `warn` no matter what the user chose.
      logLevel: logLevel,
      rules: rules,
    ),
    CoreCapabilities.singbox114,
  );

  static int _int(String? raw, int fallback) =>
      raw == null ? fallback : (int.tryParse(raw) ?? fallback);

  static bool _bool(String? raw, bool fallback) {
    if (raw == null) return fallback;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  @override
  bool operator ==(Object other) =>
      other is RoutingSettings &&
      other.mode == mode &&
      other.mixedPort == mixedPort &&
      other.clashApiPort == clashApiPort &&
      other.enableClashApi == enableClashApi &&
      other.dnsEnabled == dnsEnabled &&
      other.dnsServer == dnsServer &&
      other.directDns == directDns &&
      other.fakeIp == fakeIp &&
      other.logLevel == logLevel &&
      _sameRules(other.rules, rules);

  /// Orders matter: the same rules in a different order route traffic
  /// differently, so a reorder has to count as a change.
  static bool _sameRules(List<RoutingRule> a, List<RoutingRule> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    mode,
    mixedPort,
    clashApiPort,
    enableClashApi,
    dnsEnabled,
    dnsServer,
    directDns,
    fakeIp,
    logLevel,
    Object.hashAll(rules),
  );
}
