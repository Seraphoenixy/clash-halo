/// Runtime snapshot owned by the background host. The UI never authors these
/// values; it merges whatever the host reports after a reconnect.
library;

enum CoreState {
  stopped('stopped'),
  starting('starting'),
  running('running'),
  stopping('stopping'),
  crashed('crashed'),

  /// The host gave up on the core: the process exited, or the config was
  /// rejected. The reason travels in `lastErrorCode`/`lastErrorMessage`.
  ///
  /// This is the value `native/windows/internal/state` writes as `CoreFailed`.
  /// It must never fall back to [stopped]: a crashed core would then display
  /// as 已停止, which hides both the failure and the fact. ([crashed] is a
  /// Dart-side value that no host build emits.)
  failed('failed');

  const CoreState(this.wire);
  final String wire;

  static CoreState fromWire(String value) =>
      CoreState.values.firstWhere((s) => s.wire == value,
          orElse: () => CoreState.stopped);

  bool get isRunning => this == CoreState.running;
  bool get isBusy => this == CoreState.starting || this == CoreState.stopping;
}

enum ProxyMode {
  rule('rule'),
  global('global'),
  direct('direct');

  const ProxyMode(this.wire);
  final String wire;

  static ProxyMode fromWire(String value) =>
      ProxyMode.values.firstWhere((m) => m.wire == value,
          orElse: () => ProxyMode.rule);
}

/// TUN states reported by the host.
///
/// [unverified] is a legacy value from a build that refused activation while
/// TUN was not implemented. Nothing reports it any more; it is kept so an old
/// snapshot still parses. [enabled] means a real tunnel is capturing traffic,
/// and [failed] carries the reason in `tunMessage`.
enum TunState {
  disabled('disabled'),
  pending('pending'),
  enabled('enabled'),
  failed('failed'),
  unsupported('unsupported'),
  unverified('unverified');

  const TunState(this.wire);
  final String wire;

  static TunState fromWire(String value) => TunState.values
      .firstWhere((s) => s.wire == value, orElse: () => TunState.disabled);

  /// True only when traffic is genuinely being captured.
  bool get isActive => this == TunState.enabled;
}

/// System proxy bookkeeping owned by the host.
///
/// [restorable] is true only while the current registry value is still the
/// one we wrote; once the user or another tool changes it, restoring on exit
/// would silently undo someone else's choice, so the host refuses.
class SystemProxyState {
  const SystemProxyState({
    this.supported = false,
    this.enabled = false,
    this.restorable = false,
    this.endpoint = '',
    this.appliedValue = '',
    this.appliedProxyEnable = 0,
    this.previousValue = '',
    this.previousEnable = 0,
  });

  final bool supported;
  final bool enabled;
  final bool restorable;
  final String endpoint;
  final String appliedValue;
  final int appliedProxyEnable;
  final String previousValue;
  final int previousEnable;

  static const off = SystemProxyState();

  factory SystemProxyState.fromJson(Map<String, Object?> json) {
    int asInt(Object? v) => (v as num?)?.toInt() ?? 0;
    bool asBool(Object? v) => v as bool? ?? false;
    String asString(Object? v) => v as String? ?? '';
    return SystemProxyState(
      supported: asBool(json['supported']),
      enabled: asBool(json['enabled']),
      restorable: asBool(json['restorable']),
      endpoint: asString(json['endpoint']),
      appliedValue: asString(json['appliedValue']),
      appliedProxyEnable: asInt(json['appliedProxyEnable']),
      previousValue: asString(json['previousValue']),
      previousEnable: asInt(json['previousEnable']),
    );
  }

  Map<String, Object?> toJson() => {
        'supported': supported,
        'enabled': enabled,
        'restorable': restorable,
        'endpoint': endpoint,
        'appliedValue': appliedValue,
        'appliedProxyEnable': appliedProxyEnable,
        'previousValue': previousValue,
        'previousEnable': previousEnable,
      };

  SystemProxyState copyWith({
    bool? supported,
    bool? enabled,
    bool? restorable,
    String? endpoint,
    String? appliedValue,
    int? appliedProxyEnable,
    String? previousValue,
    int? previousEnable,
  }) =>
      SystemProxyState(
        supported: supported ?? this.supported,
        enabled: enabled ?? this.enabled,
        restorable: restorable ?? this.restorable,
        endpoint: endpoint ?? this.endpoint,
        appliedValue: appliedValue ?? this.appliedValue,
        appliedProxyEnable: appliedProxyEnable ?? this.appliedProxyEnable,
        previousValue: previousValue ?? this.previousValue,
        previousEnable: previousEnable ?? this.previousEnable,
      );
}

/// Immutable view of the host runtime. [stateVersion] increases on every
/// host-side mutation and is used to discard stale UI echoes.
class RuntimeSnapshot {
  const RuntimeSnapshot({
    required this.stateVersion,
    required this.coreState,
    this.corePid = 0,
    this.coreStartedAtMs = 0,
    this.coreRestarts = 0,
    this.activeNodeId,
    this.activeNodeName,
    this.activeProfileId,
    this.configVersion = 0,
    this.configHash,
    this.mode = ProxyMode.rule,
    this.systemProxy = SystemProxyState.off,
    this.tunState = TunState.disabled,
    this.tunSupported = false,
    this.tunMessage,
    this.tunPid = 0,
    this.tunAdapter,
    this.tunElevated = false,
    this.autoLaunch = false,
    this.coreWanted = false,
    this.hostVersion = '',
    this.coreVersion = '',
    this.singboxPath,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.logBytes = 0,
    this.updatedAtMs = 0,
    this.subscriptionRunnerActive = false,
    this.speedTestRunning = false,
  });

  final int stateVersion;
  final CoreState coreState;
  final int corePid;
  final int coreStartedAtMs;
  final int coreRestarts;
  final String? activeNodeId;
  final String? activeNodeName;
  final String? activeProfileId;
  final int configVersion;
  final String? configHash;
  final ProxyMode mode;
  final SystemProxyState systemProxy;

  /// Convenience accessor: is the system proxy pointing at our core right now.
  bool get systemProxyEnabled => systemProxy.enabled;
  final TunState tunState;
  final bool tunSupported;
  final String? tunMessage;

  /// The elevated sing-box process. Distinct from [corePid]: in TUN mode the
  /// elevated core replaces the normal one, so the two are never both live.
  final int tunPid;

  /// Adapter name the helper reported creating, not the name that was asked
  /// for: the UI must show what actually exists.
  final String? tunAdapter;

  /// True only when the helper confirmed an elevated token. Set by the helper
  /// alone, so a false claim would require a genuine elevation check to lie.
  final bool tunElevated;
  final bool autoLaunch;

  /// The user's standing intent about the core, as opposed to [coreState],
  /// which only says whether a process is alive right now.
  ///
  /// The host resets [coreState] to `stopped` on every restart (a dead process
  /// must not be reported as live) and uses this flag to decide whether to
  /// start the core again. The UI reads it to tell "this happens to be stopped"
  /// apart from "the user does not want it running".
  final bool coreWanted;
  final String hostVersion;
  final String coreVersion;
  final String? singboxPath;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final int logBytes;
  final int updatedAtMs;

  /// True while the host is still refreshing subscriptions for a connected
  /// UI. Refreshes stop once the last UI disconnects (spec 7.2).
  final bool subscriptionRunnerActive;
  final bool speedTestRunning;

  static const empty = RuntimeSnapshot(stateVersion: 0, coreState: CoreState.stopped);

  factory RuntimeSnapshot.fromJson(Map<String, Object?> json) {
    int asInt(Object? v) => (v as num?)?.toInt() ?? 0;
    String? asString(Object? v) => v as String?;
    bool asBool(Object? v) => v as bool? ?? false;
    return RuntimeSnapshot(
      stateVersion: asInt(json['stateVersion']),
      coreState: CoreState.fromWire(json['coreState'] as String? ?? 'stopped'),
      corePid: asInt(json['corePid']),
      coreStartedAtMs: asInt(json['coreStartedAtMs']),
      coreRestarts: asInt(json['coreRestarts']),
      activeNodeId: asString(json['activeNodeId']),
      activeNodeName: asString(json['activeNodeName']),
      activeProfileId: asString(json['activeProfileId']),
      configVersion: asInt(json['configVersion']),
      configHash: asString(json['configHash']),
      mode: ProxyMode.fromWire(json['mode'] as String? ?? 'rule'),
      systemProxy: SystemProxyState.fromJson(
          (json['systemProxy'] as Map?)?.cast<String, Object?>() ?? const {}),
      tunState: TunState.fromWire(json['tunState'] as String? ?? 'disabled'),
      tunSupported: asBool(json['tunSupported']),
      tunMessage: asString(json['tunMessage']),
      tunPid: asInt(json['tunPid']),
      tunAdapter: asString(json['tunAdapter']),
      tunElevated: asBool(json['tunElevated']),
      autoLaunch: asBool(json['autoLaunch']),
      coreWanted: asBool(json['coreWanted']),
      hostVersion: json['hostVersion'] as String? ?? '',
      coreVersion: json['coreVersion'] as String? ?? '',
      singboxPath: asString(json['singboxPath']),
      lastErrorCode: asString(json['lastErrorCode']),
      lastErrorMessage:
          asString(json['lastErrorMsg']) ?? asString(json['lastErrorMessage']),
      logBytes: asInt(json['logBytes']),
      updatedAtMs: asInt(json['updatedAtMs']),
      subscriptionRunnerActive: asBool(json['subscriptionRunnerActive']),
      speedTestRunning: asBool(json['speedTestRunning']),
    );
  }

  Map<String, Object?> toJson() => {
        'stateVersion': stateVersion,
        'coreState': coreState.wire,
        'corePid': corePid,
        'coreStartedAtMs': coreStartedAtMs,
        'coreRestarts': coreRestarts,
        'activeNodeId': activeNodeId,
        'activeNodeName': activeNodeName,
        'activeProfileId': activeProfileId,
        'configVersion': configVersion,
        'configHash': configHash,
        'mode': mode.wire,
        'systemProxy': systemProxy.toJson(),
        'tunState': tunState.wire,
        'tunSupported': tunSupported,
        'tunMessage': tunMessage,
        'tunPid': tunPid,
        'tunAdapter': tunAdapter,
        'tunElevated': tunElevated,
        'autoLaunch': autoLaunch,
        'coreWanted': coreWanted,
        'hostVersion': hostVersion,
        'coreVersion': coreVersion,
        'singboxPath': singboxPath,
        'lastErrorCode': lastErrorCode,
        'lastErrorMsg': lastErrorMessage,
        'logBytes': logBytes,
        'updatedAtMs': updatedAtMs,
        'subscriptionRunnerActive': subscriptionRunnerActive,
        'speedTestRunning': speedTestRunning,
      };

  RuntimeSnapshot copyWith({
    int? stateVersion,
    CoreState? coreState,
    int? corePid,
    int? coreStartedAtMs,
    int? coreRestarts,
    String? activeNodeId,
    String? activeNodeName,
    String? activeProfileId,
    int? configVersion,
    String? configHash,
    ProxyMode? mode,
    SystemProxyState? systemProxy,
    TunState? tunState,
    bool? tunSupported,
    String? tunMessage,
    int? tunPid,
    String? tunAdapter,
    bool? tunElevated,
    bool? autoLaunch,
    bool? coreWanted,
    String? hostVersion,
    String? coreVersion,
    String? singboxPath,
    String? lastErrorCode,
    String? lastErrorMessage,
    int? logBytes,
    int? updatedAtMs,
    bool? subscriptionRunnerActive,
    bool? speedTestRunning,
  }) =>
      RuntimeSnapshot(
        stateVersion: stateVersion ?? this.stateVersion,
        coreState: coreState ?? this.coreState,
        corePid: corePid ?? this.corePid,
        coreStartedAtMs: coreStartedAtMs ?? this.coreStartedAtMs,
        coreRestarts: coreRestarts ?? this.coreRestarts,
        activeNodeId: activeNodeId ?? this.activeNodeId,
        activeNodeName: activeNodeName ?? this.activeNodeName,
        activeProfileId: activeProfileId ?? this.activeProfileId,
        configVersion: configVersion ?? this.configVersion,
        configHash: configHash ?? this.configHash,
        mode: mode ?? this.mode,
        systemProxy: systemProxy ?? this.systemProxy,
        tunState: tunState ?? this.tunState,
        tunSupported: tunSupported ?? this.tunSupported,
        tunMessage: tunMessage ?? this.tunMessage,
        tunPid: tunPid ?? this.tunPid,
        tunAdapter: tunAdapter ?? this.tunAdapter,
        tunElevated: tunElevated ?? this.tunElevated,
        autoLaunch: autoLaunch ?? this.autoLaunch,
        coreWanted: coreWanted ?? this.coreWanted,
        hostVersion: hostVersion ?? this.hostVersion,
        coreVersion: coreVersion ?? this.coreVersion,
        singboxPath: singboxPath ?? this.singboxPath,
        lastErrorCode: lastErrorCode ?? this.lastErrorCode,
        lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
        logBytes: logBytes ?? this.logBytes,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        subscriptionRunnerActive:
            subscriptionRunnerActive ?? this.subscriptionRunnerActive,
        speedTestRunning: speedTestRunning ?? this.speedTestRunning,
      );
}

/// One bounded log line as exposed to the UI.
class LogEntry {
  const LogEntry({
    required this.seq,
    required this.atMs,
    required this.level,
    required this.source,
    required this.message,
  });

  final int seq;
  final int atMs;
  final String level;
  final String source;
  final String message;

  factory LogEntry.fromJson(Map<String, Object?> json) => LogEntry(
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        atMs: (json['atMs'] as num?)?.toInt() ?? 0,
        level: json['level'] as String? ?? 'info',
        source: json['source'] as String? ?? 'host',
        message: json['message'] as String? ?? '',
      );

  Map<String, Object?> toJson() => {
        'seq': seq,
        'atMs': atMs,
        'level': level,
        'source': source,
        'message': message,
      };
}

enum TaskKind {
  speedTest('speed_test'),
  subscriptionUpdate('subscription_update'),
  versionCheck('version_check');

  const TaskKind(this.wire);
  final String wire;

  static TaskKind fromWire(String value) =>
      TaskKind.values.firstWhere((k) => k.wire == value, orElse: () => TaskKind.speedTest);
}

enum TaskStatus {
  running('running'),
  finished('finished'),
  canceled('canceled'),
  failed('failed');

  const TaskStatus(this.wire);
  final String wire;

  static TaskStatus fromWire(String value) =>
      TaskStatus.values.firstWhere((s) => s.wire == value, orElse: () => TaskStatus.running);

  bool get isTerminal => this != TaskStatus.running;
}

/// Long-running work handle returned by the host.
class TaskInfo {
  const TaskInfo({
    required this.id,
    required this.kind,
    required this.status,
    this.total = 0,
    this.completed = 0,
    this.message,
    this.startedAtMs = 0,
  });

  final String id;
  final TaskKind kind;
  final TaskStatus status;
  final int total;
  final int completed;
  final String? message;
  final int startedAtMs;

  factory TaskInfo.fromJson(Map<String, Object?> json) => TaskInfo(
        id: json['id'] as String? ?? '',
        kind: TaskKind.fromWire(json['kind'] as String? ?? 'speed_test'),
        status: TaskStatus.fromWire(json['status'] as String? ?? 'running'),
        total: (json['total'] as num?)?.toInt() ?? 0,
        completed: (json['completed'] as num?)?.toInt() ?? 0,
        message: json['message'] as String?,
        startedAtMs: (json['startedAtMs'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.wire,
        'status': status.wire,
        'total': total,
        'completed': completed,
        'message': message,
        'startedAtMs': startedAtMs,
      };
}
