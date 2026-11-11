import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:halo_config/halo_config.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

import '../ipc/android_vpn.dart';
import '../ipc/halo_client.dart';
import 'catalog_store.dart';
import 'host_connection.dart';
import 'routing_settings.dart';
import 'runtime_store.dart';
import 'session_state.dart';
import 'speed_batch_tracker.dart';
import 'subscription_manager.dart';
import 'throughput.dart';
import 'tray_coordinator.dart';
import 'unlock.dart';
import 'unlock_controller.dart';

// SubscriptionUpdate is part of the controller's public result shape; tests
// and pages import it from here. The implementation moved to its own library.
export 'subscription_manager.dart' show SubscriptionUpdate;

// Android 侧没有 halo-host：代理内核（libbox）运行在 :vpn 进程的
// HaloVpnService 里，启停与配置经平台通道驱动。见 lib/src/ipc/android_vpn.dart。
final AndroidVpnClient _androidVpn = const AndroidVpnClient();

/// Android 上激活节点 id 的持久化键。Windows 上该状态由宿主快照持有，
/// Android 没有宿主，改由数据库的 settings 表持有。
const String _kAndroidActiveNode = 'android.activeNodeId';

/// Android 本地测速使用的目标地址，与 Windows 探测的默认值一致。
const String _kAndroidProbeUrl = 'https://www.gstatic.com/generate_204';
const String _kAndroidSpeedUrl =
    'https://speed.cloudflare.com/__down?bytes=5000000';

/// Owns every piece of state the UI renders.
///
/// Two sources are deliberately kept apart (spec 7.2):
///   * the background host is authoritative for *runtime* state (core status,
///     active node, system proxy, TUN, logs);
///   * the database is authoritative for *business* config (node list,
///     subscriptions, preferences).
/// Folding them into one store would let a stale snapshot overwrite a node the
/// user just imported, so they are merged only at read time.
/// Turns the host's `log.tail` payload into [LogEntry] values.
///
/// The two shapes differ on purpose: the host reports what it has — `{atMs,
/// text}` — while [LogEntry] is the richer event model. Reading the host maps
/// with `LogEntry.fromJson` looked correct and produced entries whose `message`
/// was always empty, so the log page rendered blank rows.
///
/// Kept as a free function so the mapping can be tested without a host.
List<LogEntry> logEntriesFromTail(Object? raw) {
  if (raw is! List) return const <LogEntry>[];
  final out = <LogEntry>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final map = entry.cast<String, Object?>();
    final text = (map['text'] as String?) ?? (map['message'] as String?) ?? '';
    if (text.isEmpty) continue;
    out.add(
      LogEntry(
        // `seq` is the line's byte offset in the host log, so it is stable
        // across polls. Falling back to the list index would look equivalent
        // and break the moment the host's 200-line window slides: every row
        // would renumber and the page would re-append the whole window.
        seq: (map['seq'] as num?)?.toInt() ?? 0,
        atMs: (map['atMs'] as num?)?.toInt() ?? 0,
        level: map['level'] as String? ?? 'info',
        source: map['source'] as String? ?? 'host',
        message: text,
      ),
    );
  }
  return out;
}

class AppController {
  AppController({
    HaloClient? client,
    required this.dataDir,
    this.reconnectDelay = const Duration(seconds: 2),
  }) : client =
           client ??
           HaloClient(
             // The host derives its pipe from the data directory, so the UI
             // must use the same derivation or it would connect to nothing.
             pipeName: haloPipeNameFor(dataDir),
           ) {
    host = HostConnection(
      client: this.client,
      reconnectDelay: reconnectDelay,
      onChanged: connectionChanged,
      onConnected: _postConnect,
      onError: _onConnectionError,
      onHostExiting: _onHostExitingEvent,
      ensureHost: Platform.isWindows ? _ensureHost : null,
    );
    tray = TrayCoordinator(
      dataDir: dataDir,
      connected: () => connected,
      storeReady: () => storeReady,
      loadProfiles: loadProfiles,
      loadNodes: loadNodes,
      activeNodeId: () => runtime.snapshot?.activeNodeId,
      activeProfileId: () => _activeProfileId,
      nodeExists: (id) => catalog.nodeByIdOrNull(id) != null,
      command: (action, params) async {
        await _command<void>(action, params: params);
      },
      selectNode: selectNode,
      selectProfile: selectProfile,
      setMode: setMode,
      refreshSnapshot: refreshSnapshot,
      onError: (message) {
        _lastActionError = message;
        errorChanged();
      },
    );
    speed = SpeedBatchTracker(
      command: (action, params, timeout) => _command<Map<String, Object?>>(
        action,
        params: params,
        timeout: timeout,
      ),
      loadNodes: loadNodes,
      storedConcurrency: () =>
          _settings?.getInt(SettingKeys.speedTestConcurrency) ?? 8,
    );
    subscriptions = SubscriptionManager(
      subscriptions: () => catalog.subscriptionRepo,
      nodes: () => catalog.nodeRepo,
      importLog: () => _importLog,
      store: () => store,
      proxyEndpoint: () => proxyEndpoint,
      loadProfiles: loadProfiles,
      disposed: () => _disposed,
      onCatalogChanged: () {
        invalidateCatalogCache();
        catalogChanged();
      },
    );
  }

  final HaloClient client;
  final String dataDir;
  final Duration reconnectDelay;

  /// Pipe lifecycle: connect/reconnect and the terminal host-exiting state.
  late final HostConnection host;

  /// Tray catalogue projection and request handling.
  late final TrayCoordinator tray;

  /// The current speed-test batch and its per-metric results.
  late final SpeedBatchTracker speed;

  /// Subscription refresh state machine and its auto-update timer.
  late final SubscriptionManager subscriptions;

  /// The exact params `event.subscribe` takes on the wire.
  ///
  /// The host decodes `{enabled bool}` and ignores unknown keys, so this field
  /// name is a contract detail, not an internal one: sending `{'events':true}`
  /// subscribed the UI *off* every event, which made the latency column spin
  /// forever because only `task.progress`/`task.finished` ever resolve a row.
  /// Kept public so a test can pin it against the host's decoder.
  static const Map<String, Object?> eventSubscribeParams = {'enabled': true};

  /// How the UI answers a host that has announced its own exit.
  ///
  /// Overridden by tests, where closing the "window" is meaningless and
  /// `exit(0)` would take the test runner down with it.
  static Future<void> Function() exitApp = _quitApp;

  /// Closes the window through the runner, which is the same path as the ×
  /// button: `Win32Window` posts WM_CLOSE and `main.cpp` runs
  /// `SetQuitOnClose(true)`, so the message loop ends and the process exits.
  ///
  /// Going through the window instead of `exit(0)` matters: a raw exit skips
  /// the runner's teardown (COM uninit, single-instance mutex release), the
  /// same way killing the host left a dead tray icon behind.
  static Future<void> _quitApp() async {
    if (!Platform.isWindows) {
      exit(0);
    }
    try {
      await _windowChannel.invokeMethod<void>('close');
    } on Object {
      // No handler (widget tests, an older runner): exiting is still correct,
      // and it is the only thing left that actually ends the process.
      exit(0);
    }
  }

  static const MethodChannel _windowChannel = MethodChannel(
    'clash_halo/window',
  );

  /// Set when the host said it is exiting, so the window can stop describing
  /// itself as "reconnecting" to a process that is already gone.
  bool get hostExiting => host.hostExiting;

  bool _exitCalled = false;

  /// Feeds one event through the same handler the pipe uses.
  ///
  /// Only for tests: the real path is `client.events`, and constructing a fake
  /// HaloClient just to push a single `host.exiting` would also have to fake the
  /// connect handshake the handler depends on.
  @visibleForTesting
  void applyEventForTest(HaloEventMessage event) => _onEvent(event);

  /// Narrow notification channels.
  ///
  /// One counter for everything meant that a log line arriving, an unrelated
  /// command failing, or the host link changing all rebuilt the sidebar *and*
  /// the whole current page. Each widget now listens to the narrowest channel
  /// that can actually change what it draws:
  ///
  ///   * [runtimeRevision] — the host snapshot (core, proxy, TUN, active node);
  ///   * [proxyRevision] — just the Windows-proxy switch;
  ///   * [catalogRevision] — the local node/subscription tables;
  ///   * [connectionRevision] — whether the host pipe is up;
  ///   * [errorRevision] — the one-line action-error strip.
  ///
  /// The first two live in [RuntimeStore]; the rest stay here because they are
  /// not snapshot state.
  late final RuntimeStore runtime = RuntimeStore();

  ValueNotifier<int> get runtimeRevision => runtime.revision;

  /// The Windows-proxy setting on its own.
  ///
  /// Toggling the proxy changes one boolean, but every consumer of
  /// [runtimeRevision] rebuilt: the sidebar, the status bar and the whole
  /// current page, including any table it holds. The card that draws this
  /// switch is the only widget that has to change.
  ValueNotifier<int> get proxyRevision => runtime.proxyRevision;
  final ValueNotifier<int> catalogRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> connectionRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> errorRevision = ValueNotifier<int>(0);

  /// Session throughput. Owned by the controller, not the overview page, so
  /// leaving the page does not reset the samples or the peak counters.
  final ThroughputMonitor _throughput = ThroughputMonitor(
    historyLength: 40,
    proxyOnly: true,
  );
  final ValueNotifier<int> trafficRevision = ValueNotifier<int>(0);

  /// Bumped after the host session is re-read. Node results live in the host,
  /// so a window that reconnects replaces its local view from this signal
  /// rather than keeping whatever it had before the pipe dropped.
  final ValueNotifier<int> sessionRevision = ValueNotifier<int>(0);
  Timer? _trafficTimer;
  bool _trafficPolling = false;
  (int, int)? _trafficCore;
  String? _trafficError;
  bool _snapshotInjectedForTest = false;

  final StreamController<LogEntry> _logLines =
      StreamController<LogEntry>.broadcast();

  /// Unlock checks for the active exit.
  ///
  /// Owned here rather than by the page: a sweep takes tens of seconds, and
  /// leaving the page must neither abort it nor lose the verdicts that already
  /// arrived. It is also the only place that can read the running core's port
  /// and write the results back to the database.
  late final UnlockController unlock = UnlockController(
    proxyResolver: _unlockProxy,
    nodeResolver: _activeNode,
    onPersist: _persistUnlockResults,
  );

  /// The batch whose results are currently wanted.
  ///
  /// A cancelled batch keeps running on the host — cancelling only closes its
  /// stop channel — and then reports its remaining probes under the old
  /// `taskId`. Without this the page took those stragglers as fresh numbers for
  /// the batch it had just started, so a node showed the previous run's latency
  /// or a `canceled` row while a new measurement was in flight.
  /// The batch whose results are currently wanted. See [SpeedBatchTracker];
  /// the tracker drops stragglers from a superseded batch.
  HaloStore? _store;

  /// Repositories and their read caches; bound when the database opens.
  late final CatalogStore catalog = CatalogStore();
  SettingsRepository? _settings;
  ImportLogRepository? _importLog;

  String? _fatalError;
  String? _lastActionError;

  StreamSubscription<HaloEventMessage>? _streamSub;
  bool _disposed = false;

  /// Android `:vpn` 进程的最近一次状态；Windows 上恒为 null。
  AndroidVpnStatus? _androidVpnStatus;
  Timer? _androidStatusTimer;
  bool _androidStatusPolling = false;

  /// Android 本地测速：串行切换 `:vpn` 配置，逐节点探测。
  bool _androidSpeedCanceled = false;
  String? _androidSpeedTaskId;
  Future<void>? _androidSpeedRun;

  /// Guards the launch auto-start against rapid reconnects.
  bool _autoCoreStartInFlight = false;

  /// Whether the launch auto-start already ran for this UI process.
  ///
  /// Opening clash-halo.exe is the one explicit act that justifies starting a
  /// stopped core. A pipe that later drops and reconnects is not: the user may
  /// have stopped the core on purpose in between, and re-running the ensure on
  /// every reconnect would override that. The host's supervisor already
  /// restarts a crashed core on its own, so once per launch is enough.
  bool _launchCoreEnsureDone = false;

  /// Set once the store failed to open; the UI then shows the error and
  /// disables everything that would need a database.
  bool get storeReady => _store != null;

  String? get storeError => _fatalError;

  /// How many node rows a schema migration removed because the old v2rayN
  /// importer had stored a protocol that contradicted the row's own
  /// `configType`. Read once at startup and shown as a one-off notice: the
  /// nodes disappear on first launch after the upgrade, and a silent
  /// disappearance would look like data loss.
  int _repairedNodeCount = 0;

  int get repairedNodeCount => _repairedNodeCount;

  /// Clears the startup repair notice after the UI has shown it.
  void acknowledgeRepairedNodes() {
    if (_repairedNodeCount == 0) return;
    _repairedNodeCount = 0;
    clearMeta(SettingKeys.repairedNodes);
  }

  /// Deletes one `meta` entry; used to consume one-shot startup notices.
  void clearMeta(String key) {
    final s = _store;
    if (s == null) return;
    deleteMeta(s.db, key);
  }

  HaloStore get store {
    final s = _store;
    if (s == null) throw StateError('数据库不可用: ${_fatalError ?? '未知原因'}');
    return s;
  }

  NodeRepository get nodeRepo => catalog.nodeRepo;

  SubscriptionRepository get subscriptionRepo => catalog.subscriptionRepo;

  SubscriptionGroupRepository get groupRepo => catalog.groupRepo;

  SettingsRepository get settingsRepo =>
      _settings ?? (throw StateError('数据库不可用'));

  /// Reads a stored preference without throwing when the database is missing.
  ///
  /// The root widget restores the saved theme before the first frame. Using the
  /// throwing [settingsRepo] there meant any database failure aborted the first
  /// build, and a release build then paints an empty grey box and never maps
  /// the window at all: the user got a blank window with no way to tell why.
  /// A dead database must degrade into [storeError], never into a blank window.
  String? storedSetting(String key) => _settings?.raw(key);

  RuntimeSnapshot? get snapshot => runtime.snapshot;

  HostConnectionState get connection => host.state;

  /// A short, user-facing reason for the last failed command, if any.
  String? get lastActionError => _lastActionError;

  bool get connected => host.connected;

  /// UI 上「节点/内核操作」是否可用。
  ///
  /// Windows 以宿主管道连接为准；Android 没有宿主——操作经平台通道直接驱动
  /// `:vpn` 服务，数据库打开即可（测延迟等确实依赖宿主的能力仍单独挂 [connected]，
  /// 在 Android 上如实保持禁用）。
  bool get canOperate => Platform.isAndroid ? storeReady : connected;

  /// 当前是否运行在 Android 上。
  ///
  /// UI 用它选择 Android 的 VPN 状态来源，而不是把 `Platform.isAndroid`
  /// 分散到各个页面。
  bool get isAndroid => Platform.isAndroid;

  /// `:vpn` 进程的最近一次状态；未读取到时为 null。
  AndroidVpnStatus? get androidVpnStatus => _androidVpnStatus;

  bool get androidVpnActive => _androidVpnStatus?.isActive ?? false;

  bool get androidVpnStarted => _androidVpnStatus?.isStarted ?? false;

  /// Whether a local Android speed batch is still running (including the
  /// restore step). The node page must not offer a new batch while the previous
  /// one is switching the VPN back.
  bool get androidSpeedTestRunning => _androidSpeedRun != null;

  /// 把 `:vpn` 状态映射到宿主模型的内核状态，供状态栏与徽标复用同一套
  /// 文案和颜色，不新增第二套状态枚举。
  CoreState get androidCoreState => switch (_androidVpnStatus?.state) {
    'Started' => CoreState.running,
    'Starting' => CoreState.starting,
    'Failed' => CoreState.failed,
    _ => CoreState.stopped,
  };

  String get androidVpnLabel => switch (_androidVpnStatus?.state) {
    'Started' => '已连接',
    'Starting' => '连接中',
    'Failed' => '启动失败',
    _ => '未连接',
  };

  /// The version string the host read out of the core binary on disk.
  ///
  /// Empty means the host did not report one — it never probed the binary, or
  /// the probe output was unparsable. Callers must show that as unknown; a
  /// fabricated default here is what made the about panel claim a version the
  /// running core might not have.
  String get coreVersion => runtime.snapshot?.coreVersion ?? '';

  Stream<LogEntry> get logLines => _logLines.stream;

  Stream<SpeedResult> get speedUpdates => speed.updates;

  /// Node ids still waiting for a result in the current batch.
  Set<String> get speedPending => speed.pending;

  /// How many nodes this batch started with. Zero when no batch is live.
  int get speedBatchTotal => speed.batchTotal;

  /// The metric the live batch measures, or null when idle.
  SpeedMetric? get speedBatchMetric => speed.batchMetric;

  /// The host task id of the live batch, if one is known.
  String? get speedTaskId => speed.taskId;

  /// Whether a batch is still waiting for at least one node.
  bool get speedBatchRunning => speed.running;

  /// Latest result per node, keyed by node id. The latency view only.
  Map<String, SpeedResult> get speedResults => speed.results;

  /// Download throughput per node, kept out of [speedResults] on purpose.
  Map<String, SpeedResult> get downloadResults => speed.downloadResults;

  /// Reachability per node, keyed by node id, one entry per transport.
  Map<String, Map<SpeedMetric, SpeedResult>> get reachability =>
      speed.reachability;

  /// The TCP or UDP reachability reading for one node, if any.
  SpeedResult? reachabilityOf(String nodeId, SpeedMetric metric) =>
      speed.reachabilityOf(nodeId, metric);

  /// Drops every measurement for one node (used when it is deleted).
  void forgetSpeedResult(String nodeId) {
    speed.forgetNode(nodeId);
    // The host keeps its own copy; without this, deleting a node and later
    // reviving the same id would bring the old reading back on the next reopen.
    if (!Platform.isWindows || !connected) return;
    unawaited(() async {
      try {
        await client.send(
          HaloAction.speedTestForget,
          params: {'nodeId': nodeId},
          timeout: const Duration(seconds: 5),
        );
      } on Object {
        // Cleanup is best-effort; the stale row is filtered by node existence.
      }
    }());
  }

  /// Live session throughput; retained across page navigation for the life of
  /// this UI process.
  ThroughputMonitor get throughput => _throughput;

  String? get trafficError => _trafficError;

  /// Opens the database and connects to the host.
  ///
  /// The database is opened first: a broken database must be reported as a
  /// database problem even when the host is fine.
  Future<void> start({bool connectHost = true}) async {
    _openStore();
    if (!storeReady) {
      _lastActionError =
          '数据目录不可写或数据库不可用：$dataDir。请检查当前用户的目录权限；便携版可在程序目录创建 portable.flag，数据将保存在 user-data。';
      errorChanged();
      return;
    }
    // The store may have opened after the first page already rendered: start()
    // is deferred past the first frame (see main), so a page that built in the
    // meantime cached an empty catalog. Drop it and tell the pages to re-read.
    invalidateCatalogCache();
    catalogChanged();
    _restoreUnlockResults();
    if (connectHost && Platform.isWindows) {
      try {
        await _ensureHost();
      } catch (_) {
        _lastActionError = '后台启动失败，请检查程序与内核是否完整';
      }
    }
    subscriptions.startTimer();
    if (Platform.isAndroid) {
      // Android 没有 halo-host。启动宿主连接只会每 2 秒尝试加载
      // kernel32.dll 并失败，状态改由 :vpn 的状态文件提供。
      _startAndroidStatusPolling();
      return;
    }
    if (!connectHost) return;
    _streamSub = client.events.listen(_onEvent);
    await host.start();
    if (connected) await refreshSnapshot();
    connectionChanged();
  }

  void _startAndroidStatusPolling() {
    _androidStatusTimer?.cancel();
    unawaited(refreshAndroidVpnStatus());
    _androidStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(refreshAndroidVpnStatus());
    });
  }

  /// 重新读取 `:vpn` 状态；状态变化时才通知界面重组。
  Future<void> refreshAndroidVpnStatus() async {
    if (!Platform.isAndroid || _disposed || _androidStatusPolling) return;
    _androidStatusPolling = true;
    try {
      final next = await _androidVpn.status();
      _applyAndroidVpnStatus(next);
    } on Object {
      // 通道暂时不可用（例如服务正在被杀）：保持上一次可读状态，
      // 下一次轮询会自然恢复；不要把界面重置成连接失败。
    } finally {
      _androidStatusPolling = false;
    }
  }

  void _applyAndroidVpnStatus(AndroidVpnStatus next) {
    final previous = _androidVpnStatus;
    _androidVpnStatus = next;
    if (previous == null ||
        previous.state != next.state ||
        previous.message != next.message ||
        previous.updatedAt != next.updatedAt) {
      runtimeChanged();
    }
  }

  void _openStore() {
    final dbPath = '$dataDir${Platform.pathSeparator}clash-halo.db';
    final result = HaloStore.open(dbPath);
    if (result.store == null) {
      _fatalError = result.error ?? '无法打开数据库';
      return;
    }
    _store = result.store;
    catalog.attach(_store!);
    _settings = SettingsRepository(_store!);
    _importLog = ImportLogRepository(_store!);
    _repairedNodeCount =
        int.tryParse(metaOf(_store!.db, SettingKeys.repairedNodes) ?? '') ?? 0;
  }

  /// Publishes a snapshot as if the host had pushed one.
  ///
  /// Only for tests and runtime checks: the host is the authority for this
  /// state, and a production path that called this would fight it.
  @visibleForTesting
  void applySnapshotForTest(RuntimeSnapshot snapshot, {bool? connected}) {
    _snapshotInjectedForTest = true;
    try {
      adoptSnapshot(snapshot);
      // The guidance rules short-circuit on connection state, so a test that
      // wants to exercise the snapshot-driven rules has to be able to say "the
      // pipe is up" without standing up a real host.
      if (connected != null) {
        host.setStateForTest(
          connected
              ? HostConnectionState.connected
              : HostConnectionState.disconnected,
        );
      }
      // Widget tests end before the controller's dispose, so starting the
      // periodic session timer here would leave a pending timer. Sample once
      // instead; production starts the timer from adoptSnapshot.
      if (connected == true) _pollTrafficOnceForTest();
    } finally {
      _snapshotInjectedForTest = false;
    }
    runtimeChanged();
  }

  void _pollTrafficOnceForTest() {
    if (!Platform.isWindows) return;
    final snap = runtime.snapshot;
    if (snap == null || !snap.coreState.isRunning) return;
    _trafficCore = (snap.corePid, snap.tunPid);
    unawaited(_pollTraffic());
  }

  /// Publishes a connection state as if the client had reported it.
  ///
  /// Only for tests and runtime checks: the pipe is the authority for this
  /// state, and a production path that called this would let the UI disagree
  /// with the connection it actually has.
  @visibleForTesting
  void applyConnectionStateForTest(HostConnectionState state) {
    host.setStateForTest(state);
  }

  /// Takes a new snapshot and reports whether the coarse channel is needed.
  ///
  /// Returns true for every other change, including the first snapshot. The
  /// proxy-only decision and its narrow channel live in [RuntimeStore].
  bool adoptSnapshot(RuntimeSnapshot snapshot) {
    final changed = runtime.adopt(snapshot);
    // A core start/stop changes whether throughput can be sampled at all.
    _syncTrafficPolling();
    return changed;
  }

  /// Retries immediately instead of waiting for the next scheduled attempt.
  ///
  /// The status bar offers this while it says "正在连接后台服务". The automatic
  /// backoff is two seconds, but a user staring at a stuck strip wants an
  /// answer now, and a manual retry also re-probes for the host binary, which
  /// the background timer does not do.
  Future<void> retryConnect() => host.retry();

  Future<void> _postConnect() async {
    // Resubscribe first so a state change occurring during the snapshot fetch
    // is not lost; duplicates are harmless because they carry a sequence.
    try {
      // The field is `enabled`, not `events`: the host decodes
      // `{enabled bool}` and silently ignores unknown fields, so the earlier
      // `{'events': true}` set subscribed=false and left this client deaf to
      // every event. That looked like a latency test that spins forever, because
      // only `task.progress`/`task.finished` ever clear those rows.
      await client.send(
        HaloAction.eventSubscribe,
        params: AppController.eventSubscribeParams,
      );
    } on Object {
      // Subscription is best-effort; the snapshot below still works.
    }
    await refreshSnapshot();
    // The host owns speed results and traffic for its whole lifetime. Read them
    // after the snapshot so the traffic clock's core identity is already known;
    // this is what a freshly opened window shows instead of starting at zero.
    await _loadSessionState();
    // 启动 clash-halo.exe 应自动启动内核：连接建立后内核仍不在运行，就把它
    // 拉起来（见 [ensureCoreRunningForLaunch]）。
    unawaited(ensureCoreRunningForLaunch());
    // A freshly seeded rule list lives only in the database until something
    // applies it, and this is the first moment a snapshot exists — which is
    // what `reapplyRoutingIfPossible` requires. It cannot go inside
    // `ensureCoreRunningForLaunch`: that returns early whenever the core is
    // already running, which is exactly the normal case on a warm start.
    unawaited(_applySeededRules());
    unawaited(_refreshTail());
    // Push the catalogue early so the tray menu is complete even if the user
    // never opens the node page, and pick up a request the tray left while this
    // window was closed.
    unawaited(publishTrayCatalog());
    unawaited(_consumeTrayRequest());
  }

  /// Reads the host's lifetime session and replaces the local view.
  ///
  /// Failure is non-fatal: the window still paints and the normal reconnect
  /// path will try again. It must not raise the one-line error strip either —
  /// this is background state, not an action the user asked for.
  Future<void> _loadSessionState() async {
    if (_disposed || !Platform.isWindows || !connected) return;
    try {
      final response = await client.send(
        HaloAction.sessionGet,
        timeout: const Duration(seconds: 5),
      );
      if (!response.ok) return;
      final session = HaloSessionState.fromJson(_jsonMap(response.result));
      final speedState = session.speed;
      speed.hydrateSession(
        running: speedState.running,
        taskId: speedState.taskId,
        metric: speedState.metric,
        total: speedState.total,
        pending: speedState.pending,
        results: speedState.results,
      );
      _applyTraffic(session.traffic);
      sessionRevision.value++;
      trafficRevision.value++;
      runtimeChanged();
    } on Object {
      // Keep the local view; a reconnect will read the session again.
    }
  }

  static Map<String, Object?> _jsonMap(Object? raw) =>
      raw is Map ? raw.cast<String, Object?>() : const <String, Object?>{};

  void _applyTraffic(TrafficSessionState state) {
    _throughput.restore(
      uploadTotal: state.uploadTotal,
      downloadTotal: state.downloadTotal,
      upRate: state.upRate,
      downRate: state.downRate,
      peakUp: state.peakUp,
      peakDown: state.peakDown,
      history: state.history,
      activeConnections: state.activeConnections,
    );
    _trafficError = state.error;
  }

  void _onEvent(HaloEventMessage event) {
    switch (event.name) {
      case HaloEvent.stateChanged:
        final data = event.data;
        // The host sends the whole snapshot on state changes, so a partial
        // merge cannot exist.
        RuntimeSnapshot? next;
        if (data['snapshot'] is Map) {
          next = RuntimeSnapshot.fromJson(
            (data['snapshot'] as Map).cast<String, Object?>(),
          );
        } else if (data.isNotEmpty) {
          next = RuntimeSnapshot.fromJson(data);
        }
        if (next != null && !adoptSnapshot(next)) return;
        runtimeChanged();
      case HaloEvent.logAppended:
        final line = LogEntry.fromJson(event.data);
        if (!_logLines.isClosed) _logLines.add(line);
      case HaloEvent.taskProgress:
      case HaloEvent.taskFinished:
      case HaloEvent.taskStarted:
        // Stragglers from a superseded batch are dropped by the tracker.
        if (speed.onTaskEvent(event)) runtimeChanged();
      case HaloEvent.hostExiting:
        // The host is going away for good: tray 「退出」, or 设置页's
        // host.shutdown. Reconnecting is pointless — the process is dying — and
        // the branch that used to live here did exactly that, so the window
        // stayed on screen showing "正在连接后台服务" forever while the tray
        // icon was already gone: the "tray quit but the window did not" report.
        //
        // The UI does not own the host's lifetime, so it must not kill it; it
        // owns the window, so it exits. A host this UI started is detached and
        // dies on its own shutdown path.
        host.markHostExiting();
      case HaloEvent.trayCommand:
        // The tray asked for a node switch or a mode change. The host also
        // wrote the same request to disk, so a UI that starts later performs it;
        // this branch is the fast path for a window that is already open.
        final payload = event.data;
        if (payload['action'] is String) {
          unawaited(applyTrayRequest(payload));
        }
    }
  }

  /// Opens the app with the proxy actually running.
  ///
  /// Launching clash-halo.exe is itself the request for a working proxy, and
  /// both reference clients start their core on launch. The host's own resume
  /// (halo-host's ResumeCore, which runs only at host boot) deliberately
  /// respects a core the user stopped on purpose, because nobody was there to
  /// ask; this path runs when the user is *right here* opening the app, so a
  /// stopped core is answered by starting it instead of by a 「去启动」 card.
  /// Guards:
  ///
  ///   * nothing applied yet (fresh install) — there is nothing to start, and
  ///     manufacturing a "没有可用的配置" error would be noise;
  ///   * TUN enabled or pending — the elevated core owns the machine
  ///     exclusively and the normal core must not fight it;
  ///   * the core is already running or mid-transition;
  ///   * an auto-start is already in flight (rapid reconnects);
  ///   * it already ran for this UI process — see [_launchCoreEnsureDone].
  ///
  /// A failed start keeps the reason in the status bar via [_command]; the
  /// overview's next-step card remains the fallback for acting on it.
  Future<void> ensureCoreRunningForLaunch() async {
    if (_launchCoreEnsureDone) return;
    final snap = runtime.snapshot;
    if (snap == null || hostExiting || _autoCoreStartInFlight) return;
    if (snap.coreState.isRunning || snap.coreState.isBusy) return;
    if (snap.tunState == TunState.enabled ||
        snap.tunState == TunState.pending) {
      return;
    }
    if (snap.configVersion <= 0 &&
        (snap.configHash == null || snap.configHash!.isEmpty)) {
      return;
    }
    _launchCoreEnsureDone = true;
    _autoCoreStartInFlight = true;
    try {
      await startCore();
    } on HaloError catch (error) {
      if (error.code == HaloErrorCode.alreadyRunning) {
        // The host's own resume won the race; that is success from where we
        // stand, and the "核心已在运行" the failed command recorded is noise.
        _lastActionError = null;
        errorChanged();
      }
    } on Object {
      // The pipe dropped mid-command: the reconnect loop re-runs this path.
    } finally {
      _autoCoreStartInFlight = false;
    }
  }

  /// Fetches runtime state from the host.
  ///
  /// A read, not a command: it goes out immediately even while a long command
  /// (a TUN enable, a config apply) is in flight, which is what keeps the
  /// pages repainting during those waits.
  Future<void> refreshSnapshot() async {
    if (!connected) return;
    var coarse = true;
    try {
      final response = await client.sendRead(HaloAction.snapshotGet);
      if (response.ok) {
        coarse = adoptSnapshot(
          RuntimeSnapshot.fromJson(response.result ?? const {}),
        );
        _lastActionError = null;
      } else {
        _lastActionError = response.error?.message;
      }
    } on Object catch (e) {
      // A version mismatch already has its own state and actionable message,
      // set by the connection listener. Reporting it as a dropped pipe here
      // would overwrite that text and schedule reconnects to a host that
      // cannot answer this build.
      if (client.state == HostConnectionState.versionMismatch) return;
      _lastActionError = '$e';
      host.noteDisconnected();
    }
    // Only repaint globally when something other than the proxy switch moved.
    if (coarse) runtimeChanged();
    errorChanged();
  }

  /// Reads the host log tail.
  ///
  /// The host's wire shape for a line is `{atMs, text}`, which is deliberately
  /// not the [LogEntry] JSON shape (that one is `{seq, atMs, level, source,
  /// message}`). Feeding the host's maps straight into `LogEntry.fromJson`
  /// produced entries with an empty message — the log page rendered a column of
  /// blank rows and looked like it had no data at all. The mapping lives here so
  /// there is exactly one reader of that shape.
  Future<List<LogEntry>> fetchLogTail({int lines = 200}) async {
    if (!connected) return const <LogEntry>[];
    try {
      final response = await client.sendRead(
        HaloAction.logTail,
        params: {'lines': lines},
      );
      if (!response.ok) return const <LogEntry>[];
      final raw = response.result?['lines'];
      return logEntriesFromTail(raw);
    } on Object {
      // The tail is a convenience; a failure here must not disturb the UI.
      return const <LogEntry>[];
    }
  }

  Future<void> _refreshTail({int lines = 200}) async {
    for (final line in await fetchLogTail(lines: lines)) {
      if (!_logLines.isClosed) _logLines.add(line);
    }
  }

  /// Runs a host command and reports failure to the caller as an exception,
  /// while also recording it for the status bar.
  ///
  /// The snapshot refetch at the end is version-gated: the host broadcasts
  /// `state.changed` from inside every store update, and that broadcast is
  /// written to the pipe *before* this response (the handler runs before the
  /// reply is encoded), so by the time a successful response arrives the event
  /// has usually already delivered the updated snapshot. Refetching on every
  /// command doubled the round trips and rebuilt every runtime-listening page
  /// twice per click. Only a response that is ahead of what we have — an
  /// unserved event stream, a subscriber that failed — still pulls a snapshot.
  Future<T> _command<T>(
    String action, {
    Map<String, Object?> params = const {},
    T Function(Map<String, Object?> result)? parse,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await client.send(
      action,
      params: params,
      timeout: timeout,
    );
    if (!response.ok) {
      final message = response.error?.message ?? '操作失败';
      _lastActionError = message;
      errorChanged();
      throw HaloError(
        response.error?.code ?? HaloErrorCode.internal,
        message,
        response.error?.detail,
      );
    }
    _lastActionError = null;
    errorChanged();
    final result = response.result ?? const <String, Object?>{};
    final seen = runtime.snapshot?.stateVersion ?? -1;
    if (response.stateVersion > seen) {
      await refreshSnapshot();
    }
    return parse == null ? result as T : parse(result);
  }

  // ------------------------------------------------------------------
  // Core / routing
  // ------------------------------------------------------------------

  Future<void> startCore() async {
    if (Platform.isAndroid) {
      await _startAndroidVpn();
      return;
    }
    await _command(HaloAction.coreStart);
  }

  Future<void> stopCore() async {
    if (Platform.isAndroid) {
      final status = await _androidVpn.stopAndWait();
      _applyAndroidVpnStatus(status);
      return;
    }
    await _command(HaloAction.coreStop);
  }

  Future<void> restartCore() async {
    if (Platform.isAndroid) {
      await startCore();
      return;
    }
    await _command(HaloAction.coreRestart);
  }

  /// Android：为激活节点构建带 TUN inbound 的文档，交给 `:vpn` 服务启动。
  ///
  /// Windows 上 TUN 由宿主注入自己的 inbound；Android 没有宿主，TUN 的提供方
  /// 就是 VpnService 本身，所以文档直接携带 tun inbound。
  Future<void> _startAndroidVpn() async {
    try {
      if (!storeReady) throw StateError('数据库不可用');
      final id = _activeNodeId;
      final node = id == null ? null : nodeRepo.nodeById(id);
      if (node == null) {
        throw StateError('还没有启用的节点：请先在节点页启用一个节点');
      }
      final built = routing.build(node, withTun: true);
      if (!built.ok) {
        throw StateError(built.issues.map((i) => i.message).join('；'));
      }
      if (!await _androidVpn.permissionGranted()) {
        final granted = await _androidVpn.requestPermission();
        if (!granted) throw StateError('未授予 VPN 权限');
      }
      final status = await _androidVpn.startAndWait(
        built.config!.toJsonString(),
      );
      _applyAndroidVpnStatus(status);
      _lastActionError = null;
      errorChanged();
    } on Object catch (error) {
      _lastActionError = '$error';
      errorChanged();
      rethrow;
    }
  }

  /// 状态栏「刷新/重试」在 Android 上的入口：先读真实状态，只有确实
  /// 未运行或失败时才重新启动。
  Future<void> retryAndroidVpn() async {
    await refreshAndroidVpnStatus();
    final status = _androidVpnStatus;
    if (status != null && status.isActive) return;
    try {
      await startCore();
    } on Object catch (error) {
      _lastActionError = '$error';
      errorChanged();
      rethrow;
    }
  }

  /// 激活节点 id。Windows 读宿主快照（宿主是运行时状态的权威）；
  /// Android 没有宿主，由数据库 settings 表持有。
  String? get _activeNodeId {
    if (Platform.isAndroid) {
      if (!storeReady) return null;
      final value = settingsRepo.raw(_kAndroidActiveNode) ?? '';
      return value.isEmpty ? null : value;
    }
    final id = runtime.snapshot?.activeNodeId;
    return (id == null || id.isEmpty) ? null : id;
  }

  /// 当前激活节点；UI 统一从这里取值，不再直接读宿主快照。
  String? get activeNodeId => _activeNodeId;

  /// 当前激活节点的显示名。Windows 优先用宿主快照里的名称（节点行可能
  /// 已被删除但宿主仍在运行）；Android 从本地节点表读取。
  String? get activeNodeName {
    if (Platform.isAndroid) {
      final id = _activeNodeId;
      if (id == null || !storeReady) return null;
      return nodeRepo.nodeById(id)?.name;
    }
    final fromSnapshot = runtime.snapshot?.activeNodeName;
    if (fromSnapshot != null && fromSnapshot.isNotEmpty) return fromSnapshot;
    final id = _activeNodeId;
    if (id == null || !storeReady) return null;
    return nodeRepo.nodeById(id)?.name;
  }

  Future<void> setMode(ProxyMode mode) async {
    // Persist first: the routing mode is part of the generated document, not
    // just a runtime flag. Recording it here means the next config build (node
    // switch, routing apply, app restart) uses the mode the user just picked
    // instead of silently reverting to "rule".
    final current = routing;
    final wire = mode.wire;
    final routeMode = RouteMode.fromWire(wire);
    if (storeReady) {
      current.copyWith(mode: routeMode).save(settingsRepo);
    }
    if (Platform.isAndroid) {
      // 没有宿主可通知；配置会经 reapply 重新生成并交给 :vpn 服务。
      await reapplyRoutingIfPossible();
      runtimeChanged();
      return;
    }
    // Tell the host as well so its snapshot (and the tray menu, which renders
    // from it) shows the new mode immediately, even when no node is applied.
    await _command(HaloAction.proxySetMode, params: {'mode': wire});
    await reapplyRoutingIfPossible();
  }

  /// The persisted routing settings, or the defaults when the database is not
  /// open. Reading from the database on every access keeps the overview page,
  /// the routing page and node selection from drifting apart.
  RoutingSettings get routing =>
      storeReady ? RoutingSettings.load(settingsRepo) : const RoutingSettings();

  /// Stores [settings], then re-applies the config so the change takes effect
  /// on the running core rather than only in the database.
  Future<void> saveRouting(RoutingSettings settings) async {
    if (!storeReady) throw StateError('数据库不可用');
    settings.save(settingsRepo);
    await reapplyRoutingIfPossible();
    runtimeChanged();
  }

  /// Rebuilds and applies the active node's config with the current routing
  /// settings.
  ///
  /// Returns true when a config was applied. It is a no-op — not an error —
  /// when no node is active or the host is disconnected: the settings are still
  /// saved, and the next node selection will use them.
  Future<bool> reapplyRoutingIfPossible() async {
    if (!storeReady) return false;
    if (!connected && !Platform.isAndroid) return false;
    final activeId = _activeNodeId;
    if (activeId == null || activeId.isEmpty) return false;
    final node = nodeRepo.nodeById(activeId);
    if (node == null) return false;
    if (Platform.isAndroid) {
      // 统一走 _startAndroidVpn：它包含权限检查、启动回执与状态刷新，
      // 避免这里成为绕过授权检查的第二条启动路径。
      await _startAndroidVpn();
      return true;
    }
    final built = routing.build(node);
    if (!built.ok) {
      throw StateError(built.issues.map((i) => i.message).join('；'));
    }
    await applyConfig(built.config!.toJsonString());
    await refreshSnapshot();
    return true;
  }

  /// The subscription the active node belongs to, or null for a local node.
  ///
  /// Derived rather than stored: a subscription is "current" precisely because
  /// the node being proxied came from it. Caching it would create a second
  /// source of truth that the next node switch could silently contradict.
  String? get _activeProfileId {
    final activeId = _activeNodeId;
    if (activeId == null || activeId.isEmpty) return null;
    return nodeRepo.nodeById(activeId)?.profileId;
  }

  /// Makes [profileId] the active subscription by enabling its first node.
  ///
  /// Switching a subscription has no meaning on its own — the proxy runs a node,
  /// not a subscription — so this picks the subscription's first node and applies
  /// it. Nodes already being used are left alone, and an empty subscription is
  /// reported rather than silently doing nothing.
  Future<void> selectProfile(String profileId) async {
    final profile = subscriptionRepo.profileById(profileId);
    if (profile == null) {
      throw StateError('订阅已不存在');
    }
    final candidates = nodeRepo.nodesForProfile(profileId);
    if (candidates.isEmpty) {
      throw StateError('订阅「${profile.name}」还没有节点，请先更新该订阅');
    }
    final activeId = _activeNodeId;
    final keep = candidates.where((n) => n.id == activeId).firstOrNull;
    await selectNode((keep ?? candidates.first).id);
  }

  /// Applies [document] as the running config.
  ///
  /// The host validates it with `sing-box check` before promoting it, so this
  /// is the only path that should ever write `active.json`.
  Future<void> applyConfig(
    String document, {
    String? configHash,
    bool startCore = true,
  }) async {
    await _command(
      HaloAction.configApply,
      params: {
        'config': document,
        'configHash': ?configHash,
        'startCore': startCore,
      },
      // Validation plus a health check can legitimately take several seconds.
      timeout: const Duration(seconds: 60),
    );
    if (storeReady) settingsRepo.setRaw('routing.template', document);
  }

  Future<void> selectNode(
    String nodeId, {
    String? nodeName,
    String? config,
    String? configHash,
  }) async {
    if (config == null) {
      final node = nodeRepo.nodeById(nodeId);
      if (node == null) throw StateError('节点已不存在');
      // Built from the persisted routing settings, not from defaults: the old
      // path always used RouteMode.rule and port 7890, so switching a node
      // silently discarded the user's DNS and routing choices.
      final built = routing.build(node, withTun: Platform.isAndroid);
      if (!built.ok) {
        throw StateError(built.issues.map((i) => i.message).join('；'));
      }
      config = built.config!.toJsonString();
      nodeName ??= node.name;
      if (Platform.isAndroid) {
        // Windows 由宿主在 nodeSelect 里持久化激活节点并应用配置；
        // Android 存在本地 settings，配置直接交给 :vpn 服务。
        if (!storeReady) throw StateError('数据库不可用');
        if (!await _androidVpn.permissionGranted()) {
          final granted = await _androidVpn.requestPermission();
          if (!granted) throw StateError('未授予 VPN 权限');
        }
        // 先等内核进入 Started 再记录激活节点：启动失败时界面不能把
        // 一个没有运行的节点标成“使用中”。
        final status = await _androidVpn.startAndWait(config);
        settingsRepo.setRaw(_kAndroidActiveNode, nodeId);
        _applyAndroidVpnStatus(status);
        catalogChanged();
        return;
      }
      _publishTrayCatalog();
    }
    await _command(
      HaloAction.nodeSelect,
      params: {
        'nodeId': nodeId,
        'nodeName': ?nodeName,
        'config': config,
        'configHash': ?configHash,
      },
      // Under TUN this reloads the elevated core, which includes the shared
      // startup budget (up to 50 s). The default 30 s would abort a switch
      // that the host is still completing.
      timeout: const Duration(seconds: 60),
    );
    // The tray menu marks the active node, so republish after every switch.
    // This is what turns the check mark in the menu into something the user can
    // trust without opening the window.
    unawaited(publishTrayCatalog());
  }

  /// Points the Windows proxy at this app's mixed inbound.
  ///
  /// The endpoint is derived from the saved routing settings rather than from a
  /// constant: the mixed port is editable on the routing page, and a hard-coded
  /// 7890 meant that changing it left Windows pointing at a port nothing
  /// listened on while the dashboard still claimed the proxy was on.
  Future<void> setSystemProxy(bool enabled, {String? endpoint}) => _command(
    HaloAction.systemProxySet,
    params: {
      'enabled': enabled,
      'endpoint': endpoint ?? '127.0.0.1:${routing.mixedPort}',
    },
  );

  /// Registers or removes the run-at-login entry.
  ///
  /// The host owns the registry write: only it knows the absolute path of the
  /// binary Windows should start.
  Future<void> setAutoLaunch(bool enabled) =>
      _command(HaloAction.autoLaunchSet, params: {'enabled': enabled});

  /// Chooses whether the next launch starts the core again.
  ///
  /// Separate from [startCore] and [stopCore] on purpose: this changes what
  /// happens *later*, it does not touch the process running right now. Turning
  /// it off while the proxy is up must not silently kill the user's traffic.
  Future<void> setCoreResume(bool enabled) =>
      _command(HaloAction.coreResumeSet, params: {'enabled': enabled});

  /// Enables or disables TUN.
  ///
  /// Enabling blocks much longer than any other command. The first enable
  /// installs the TUN service (one administrator prompt), and the host waits
  /// up to 120 seconds for the installer plus up to 90 seconds for the core.
  /// Later enables only talk to the resident service. The default command
  /// timeout would abort a prompt the user was still reading, so this path
  /// carries its own, longer budget. Failures are reported with the host's code
  /// (`elevation_denied`, `tun_unavailable`, `config_invalid`), which the UI
  /// maps to distinct messages.
  Future<void> setTun(
    bool enabled, {
    String? adapterName,
    String? stack,
    String? address,
    int? mtu,
  }) => _command(
    HaloAction.tunSetEnabled,
    params: {
      'enabled': enabled,
      'adapterName': ?adapterName,
      'stack': ?stack,
      'address': ?address,
      'mtu': ?mtu,
    },
    // Install (first enable only) + core start + the round trip.
    timeout: const Duration(seconds: 240),
  );

  Future<void> shutdownHost() => _command(HaloAction.hostShutdown);

  // ------------------------------------------------------------------
  // Tray
  // ------------------------------------------------------------------

  /// Publishes the node catalogue to the host. See [TrayCoordinator].
  Future<void> publishTrayCatalog() => tray.publishCatalog();

  /// Applies an action requested by the tray menu. See [TrayCoordinator].
  Future<void> applyTrayRequest(Map<String, Object?> payload) =>
      tray.applyRequest(payload);

  /// Reads a pending tray request written while no UI was running.
  Future<void> _consumeTrayRequest() => tray.consumePendingRequest();

  // ------------------------------------------------------------------
  // Connections
  // ------------------------------------------------------------------

  /// Reads the live connection list from the host.
  ///
  /// Deliberately not routed through [_command]: that helper refreshes the whole
  /// runtime snapshot after every call, and this one runs every 1.5 seconds
  /// while the page is open. Polling is what the host's Clash API integration
  /// supports today — it answers `connections.list` on demand rather than
  /// pushing.
  Future<ConnectionsSnapshot> fetchConnections() async {
    if (!connected) throw StateError('后台未连接');
    final response = await client.sendRead(
      HaloAction.connectionsList,
      // A controller that is busy starting up can take a moment; the page
      // treats a timeout as "retry next tick" rather than as an error banner.
      timeout: const Duration(seconds: 10),
    );
    if (!response.ok) {
      throw HaloError(
        response.error?.code ?? HaloErrorCode.internal,
        response.error?.message ?? '读取连接列表失败',
        response.error?.detail,
      );
    }
    return ConnectionsSnapshot.fromJson(response.result ?? const {});
  }

  /// Closes one connection through the core's controller.
  Future<void> closeConnection(String id) =>
      _command(HaloAction.connectionsClose, params: {'id': id});

  /// Closes every connection.
  Future<void> closeAllConnections() =>
      _command(HaloAction.connectionsClose, params: const {});

  // ------------------------------------------------------------------
  // Speed test
  // ------------------------------------------------------------------

  /// Starts a speed test for [nodeIds] (all nodes when empty) and returns the
  /// host-assigned task id.
  /// Starts a speed test for [nodeIds] (all nodes when empty) and returns the
  /// host-assigned task id. See [SpeedBatchTracker].
  Future<String> startSpeedTest({
    List<String> nodeIds = const [],
    List<String> endpoints = const [],

    /// Which quantity to measure. Latency and throughput are separate runs.
    SpeedMetric metric = SpeedMetric.proxyLatency,
    String url = '',

    /// Left at 0 so the host can apply the budget the metric needs.
    int timeoutMs = 0,

    /// Zero uses the stored preference; downloads default to serial.
    int concurrency = 0,
  }) {
    if (Platform.isAndroid) {
      return _startAndroidSpeedTest(
        nodeIds: nodeIds,
        metric: metric,
        url: url,
        timeoutMs: timeoutMs,
        concurrency: concurrency,
      );
    }
    return speed.start(
      nodeIds: nodeIds,
      endpoints: endpoints,
      metric: metric,
      url: url,
      timeoutMs: timeoutMs,
      concurrency: concurrency,
    );
  }

  /// Bounds a concurrency value to what the host accepts. Kept on the
  /// controller because the settings page and its tests call it here.
  static int clampConcurrency(int value) =>
      SpeedBatchTracker.clampConcurrency(value);

  Future<void> cancelTask(String taskId) async {
    if (Platform.isAndroid) {
      if (_androidSpeedTaskId != taskId) return;
      _androidSpeedCanceled = true;
      await _androidSpeedRun;
      return;
    }
    await speed.cancel(taskId);
  }

  /// Android 本地测速入口。
  ///
  /// 没有宿主来启动一次性探测内核，所以这里串行地让 `:vpn` 服务载入每个
  /// 节点的配置，测完再恢复原来的节点。测速期间 VPN 会短暂切换；这是当前
  /// 单服务架构的边界，不是测速结果本身的一部分。
  Future<String> _startAndroidSpeedTest({
    required List<String> nodeIds,
    required SpeedMetric metric,
    required String url,
    required int timeoutMs,
    required int concurrency,
  }) async {
    if (!storeReady) throw StateError('数据库不可用');
    if (_androidSpeedRun != null) throw StateError('已有测速任务在运行');
    final requested = nodeIds.toSet();
    final selected = loadNodes()
        .where((n) => requested.isEmpty || requested.contains(n.id))
        .toList();
    if (selected.isEmpty) throw StateError('没有可测速的节点');
    final taskId = speed.beginLocalBatch(
      selected: selected,
      metric: metric,
      allNodes: nodeIds.isEmpty,
    );
    _androidSpeedTaskId = taskId;
    _androidSpeedCanceled = false;
    final run = _runAndroidSpeedTest(
      nodes: selected,
      metric: metric,
      url: url,
      timeoutMs: timeoutMs,
    );
    _androidSpeedRun = run;
    unawaited(run);
    return taskId;
  }

  Future<void> _runAndroidSpeedTest({
    required List<ProxyNode> nodes,
    required SpeedMetric metric,
    required String url,
    required int timeoutMs,
  }) async {
    await refreshAndroidVpnStatus();
    final wasRunning = androidVpnStarted;
    final previousNodeId = activeNodeId;
    final previousNode = previousNodeId == null
        ? null
        : nodeRepo.nodeById(previousNodeId);
    String? previousConfig;
    if (previousNode != null) {
      final built = routing.build(previousNode, withTun: true);
      if (built.ok) previousConfig = built.config!.toJsonString();
    }
    final target = url.isNotEmpty
        ? url
        : metric == SpeedMetric.download
        ? _kAndroidSpeedUrl
        : _kAndroidProbeUrl;
    final timeout = Duration(
      milliseconds: timeoutMs > 0
          ? timeoutMs
          : (metric == SpeedMetric.download ? 30000 : 8000),
    );
    try {
      if (metric != SpeedMetric.tcp && !await _androidVpn.permissionGranted()) {
        final granted = await _androidVpn.requestPermission();
        if (!granted) {
          for (final node in nodes) {
            speed.recordLocalResult(
              _androidFailure(node, metric, 'vpn_permission', '未授予 VPN 权限'),
            );
          }
          return;
        }
      }
      if (metric == SpeedMetric.tcp && androidVpnStarted) {
        // A raw TCP connect from the UI process would otherwise be captured by
        // the active tunnel and measure the active node, not the node row.
        final status = await _androidVpn.stopAndWait();
        _applyAndroidVpnStatus(status);
        // The status file flips to Stopped before the service closes tun0;
        // give the TUN teardown a moment so the direct sockets are not still
        // captured by the old interface.
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      for (final node in nodes) {
        if (_androidSpeedCanceled) {
          speed.recordLocalResult(_androidCanceled(node, metric));
          continue;
        }
        SpeedResult result;
        try {
          result = await _probeAndroidNode(node, metric, target, timeout);
        } on Object catch (error) {
          result = _androidFailure(
            node,
            metric,
            'probe_failed',
            error.toString(),
          );
        }
        speed.recordLocalResult(result);
      }
    } on Object catch (error) {
      for (final node in nodes) {
        if (!speed.pending.contains(node.id)) continue;
        speed.recordLocalResult(
          _androidFailure(node, metric, 'probe_failed', error.toString()),
        );
      }
    } finally {
      for (final id in speed.pending.toList()) {
        final node = nodes.where((n) => n.id == id).firstOrNull;
        if (node != null) {
          speed.recordLocalResult(_androidCanceled(node, metric));
        }
      }
      try {
        if (wasRunning && previousConfig != null) {
          final status = await _androidVpn.startAndWait(previousConfig);
          _applyAndroidVpnStatus(status);
        } else if (androidVpnStarted) {
          final status = await _androidVpn.stopAndWait();
          _applyAndroidVpnStatus(status);
        }
      } on Object {
        // Restore is best-effort; the next status poll reports what the
        // service actually ended up doing.
        await refreshAndroidVpnStatus();
      } finally {
        speed.finishLocalBatch();
        _androidSpeedTaskId = null;
        _androidSpeedCanceled = false;
        _androidSpeedRun = null;
        runtimeChanged();
      }
    }
  }

  Future<SpeedResult> _probeAndroidNode(
    ProxyNode node,
    SpeedMetric metric,
    String target,
    Duration timeout,
  ) async {
    switch (metric) {
      case SpeedMetric.tcp:
        if (node.isUdpTransport) {
          return SpeedResult(
            nodeId: node.id,
            metric: metric,
            status: SpeedStatus.notApplicable,
            errorCode: 'not_applicable',
            errorMessage: '该节点使用 UDP 传输，不适用 TCP 握手检查',
          );
        }
        return _probeAndroidTcp(node, timeout);
      case SpeedMetric.udp:
        if (!node.isUdpTransport) {
          return SpeedResult(
            nodeId: node.id,
            metric: metric,
            status: SpeedStatus.notApplicable,
            errorCode: 'not_applicable',
            errorMessage: '该节点不使用 UDP 传输',
          );
        }
        return _probeAndroidThroughVpnWithRetry(node, metric, target, timeout);
      case SpeedMetric.proxyLatency:
      case SpeedMetric.download:
        return _probeAndroidThroughVpnWithRetry(node, metric, target, timeout);
    }
  }

  /// One retry covers the reload race: the status can flip to Started a
  /// fraction before the mixed inbound is actually accepting requests.
  Future<SpeedResult> _probeAndroidThroughVpnWithRetry(
    ProxyNode node,
    SpeedMetric metric,
    String target,
    Duration timeout,
  ) async {
    final first = await _probeAndroidThroughVpn(node, metric, target, timeout);
    if (first.status != SpeedStatus.failed ||
        first.errorCode == 'http_status' ||
        _androidSpeedCanceled) {
      return first;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return _probeAndroidThroughVpn(node, metric, target, timeout);
  }

  Future<SpeedResult> _probeAndroidTcp(ProxyNode node, Duration timeout) async {
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        node.server,
        node.port,
        timeout: timeout,
      );
      socket.destroy();
      return SpeedResult(
        nodeId: node.id,
        metric: SpeedMetric.tcp,
        status: SpeedStatus.ok,
        valueMs: watch.elapsedMilliseconds,
      );
    } on Object catch (error) {
      return _androidFailure(
        node,
        SpeedMetric.tcp,
        'tcp_failed',
        error.toString(),
        valueMs: watch.elapsedMilliseconds,
      );
    }
  }

  Future<SpeedResult> _probeAndroidThroughVpn(
    ProxyNode node,
    SpeedMetric metric,
    String target,
    Duration timeout,
  ) async {
    // Probe configs use 全局 so the test always goes through the node, even
    // when the user's current routing mode is 直连.
    final testSettings = routing.copyWith(mode: RouteMode.global);
    final built = testSettings.build(node, withTun: true);
    if (!built.ok) {
      return _androidFailure(
        node,
        metric,
        'config_invalid',
        built.issues.map((i) => i.message).join('；'),
      );
    }
    try {
      final status = await _androidVpn.startAndWait(
        built.config!.toJsonString(),
      );
      _applyAndroidVpnStatus(status);
    } on Object catch (error) {
      return _androidFailure(node, metric, 'vpn_start', error.toString());
    }
    final port = routing.mixedPort;
    if (!await _waitForLocalPort(port, const Duration(seconds: 5))) {
      return _androidFailure(node, metric, 'proxy_not_ready', '本地代理入口未就绪');
    }
    // The listener can accept before the core has finished wiring its
    // outbound; a short settle keeps the first request from racing startup.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port');
    final watch = Stopwatch()..start();
    try {
      final request = await client.getUrl(Uri.parse(target)).timeout(timeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'clash-halo-speedtest/1',
      );
      final response = await request.close().timeout(timeout);
      final latency = watch.elapsedMilliseconds;
      if (response.statusCode >= 400) {
        await response.drain<void>().timeout(timeout).catchError((_) {});
        return _androidFailure(
          node,
          metric,
          'http_status',
          'HTTP ${response.statusCode}',
          valueMs: latency,
        );
      }
      if (metric == SpeedMetric.download) {
        final readWatch = Stopwatch()..start();
        var bytes = 0;
        await for (final chunk in response.timeout(timeout)) {
          bytes += chunk.length;
          if (bytes >= 5 * 1024 * 1024) break;
        }
        final elapsed = readWatch.elapsedMilliseconds;
        if (bytes == 0) {
          return _androidFailure(
            node,
            metric,
            'empty_body',
            '测速地址没有返回数据',
            valueMs: latency,
          );
        }
        return SpeedResult(
          nodeId: node.id,
          metric: metric,
          status: SpeedStatus.ok,
          bytesPerSecond: elapsed > 0 ? (bytes * 1000 ~/ elapsed) : null,
          bytesTransferred: bytes,
        );
      }
      await response.drain<void>().timeout(timeout);
      return SpeedResult(
        nodeId: node.id,
        metric: metric,
        status: SpeedStatus.ok,
        valueMs: latency,
      );
    } on Object catch (error) {
      return _androidFailure(
        node,
        metric,
        'probe_failed',
        error.toString(),
        valueMs: watch.elapsedMilliseconds,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _waitForLocalPort(int port, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        socket.destroy();
        return true;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return false;
  }

  SpeedResult _androidCanceled(ProxyNode node, SpeedMetric metric) =>
      SpeedResult(
        nodeId: node.id,
        metric: metric,
        status: SpeedStatus.canceled,
        errorCode: 'canceled',
        errorMessage: '任务已取消',
      );

  SpeedResult _androidFailure(
    ProxyNode node,
    SpeedMetric metric,
    String code,
    String message, {
    int? valueMs,
  }) => SpeedResult(
    nodeId: node.id,
    metric: metric,
    status: SpeedStatus.failed,
    valueMs: valueMs,
    errorCode: code,
    errorMessage: message,
  );

  // ------------------------------------------------------------------
  // Node list (database side)
  // ------------------------------------------------------------------

  /// Read paths degrade to an empty list when the database is unavailable.
  ///
  /// The UI must still render (and explain the problem) instead of throwing
  /// while building; write paths keep using the throwing repository getters.
  ///
  /// The result is cached until [catalogRevision] moves. Pages call this from
  /// `build`, and an uncached call is a full `SELECT *` plus JSON decoding per
  /// node on every frame — enough on its own to make scrolling feel heavy.
  List<ProxyNode> loadNodes() => catalog.loadNodes();

  List<SubscriptionProfile> loadProfiles() => catalog.loadProfiles();

  List<SubscriptionGroup> loadGroups() => catalog.loadGroups();

  /// Drops the cached table reads. Any repository write must call this, or the
  /// pages keep rendering the previous list.
  void invalidateCatalogCache() => catalog.invalidate();

  /// The built-in 本地 subscription, creating it on first use.
  ///
  /// Every locally imported node belongs to it, so the node page can treat 本地
  /// like any other source instead of special-casing a NULL profile.
  SubscriptionProfile ensureLocalProfile() => catalog.ensureLocalProfile();

  /// Creates or renames a group. Returns null when the name is empty or taken.
  SubscriptionGroup? saveGroup({String? id, required String name}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = id == null ? null : groupRepo.groupById(id);
    final group = groupRepo.upsert(
      existing == null
          ? SubscriptionGroup(
              // Microseconds plus a real collision check. A millisecond stamp
              // made two groups created in the same tick share an id, and
              // `upsert` then *renamed the first one* instead of adding a
              // second: "I created 工作 and 公司, but I only have 公司". A tight
              // loop of 200 creates produced only ~115 distinct ids with the
              // clock alone, which is why the check below cannot be omitted.
              id: _freshGroupId(),
              name: name,
              createdAtMs: now,
              sortIndex: loadGroups().length,
            )
          : existing.copyWith(name: name),
    );
    if (group == null) return null;
    notifyExternalChange();
    return group;
  }

  /// A group id that no row currently uses.
  ///
  /// The loop is not paranoia about clocks: two creates in the same microsecond
  /// are possible when a script drives this in a tight loop, and the consequence
  /// of a collision is silent data loss (one group overwrites another).
  String _freshGroupId() {
    var stamp = DateTime.now().microsecondsSinceEpoch;
    while (groupRepo.groupById('grp_$stamp') != null) {
      stamp++;
    }
    return 'grp_$stamp';
  }

  /// Deletes a group; its subscriptions become ungrouped. Returns how many.
  int deleteGroup(String id) {
    final affected = groupRepo.deleteGroup(id);
    notifyExternalChange();
    return affected;
  }

  /// Files a subscription under a group (null = ungrouped).
  void setProfileGroup(String profileId, String? groupId) {
    subscriptionRepo.setGroup(profileId, groupId);
    notifyExternalChange();
  }

  /// Flips the per-subscription proxy switch.
  void setProfileUseProxy(String profileId, bool useProxy) {
    // Record the endpoint in force at the moment the switch was turned on, so
    // the row keeps a working target even if the port changes later.
    subscriptionRepo.setUseProxy(
      profileId,
      useProxy,
      proxyUrl: useProxy ? proxyEndpoint : null,
    );
    notifyExternalChange();
  }

  /// Stores an import result and returns the node total plus the connections
  /// that were skipped because another profile already owns them.
  ///
  /// Re-importing the same connection updates rows in place instead of
  /// duplicating them, because identity is the node fingerprint — and that
  /// identity is global now: pasting a list a subscription already carries
  /// does not create a second copy, it reports the skips. The whole batch
  /// goes through one transactioned [insertAll]: the per-row insert ran
  /// a SELECT and an implicit commit per node, which on a 5000-node paste
  /// meant ~10k statements on the UI isolate.
  ({int total, List<SkippedDuplicate> duplicates}) saveImport(
    ImportResult result, {
    String source = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final written = nodeRepo.insertAll(result.nodes, nowMs: now);
    invalidateCatalogCache();
    catalogChanged();
    // Imported nodes are exactly what the tray menu's node list is made of, so
    // the catalogue has to be republished here; otherwise the tray keeps showing
    // the list it had before the import until something else changes.
    _publishTrayCatalog();
    return (total: loadNodes().length, duplicates: written.skippedDuplicates);
  }

  void deleteNodes(Iterable<String> ids) {
    nodeRepo.deleteNodes(ids);
    invalidateCatalogCache();
    catalogChanged();
    _publishTrayCatalog();
  }

  /// The endpoint the unlock checks must go through: the running core's mixed
  /// inbound.
  ///
  /// Null unless the core is actually running. Handing back the configured port
  /// anyway would fire thirteen requests at a closed port and paint thirteen
  /// failures, which reads as "this node unlocks nothing" — a wrong answer that
  /// looks exactly like a real one.
  String? _unlockProxy() {
    if (!storeReady || !connected) return null;
    final snapshot = runtime.snapshot;
    if (snapshot == null || !snapshot.coreState.isRunning) return null;
    final port = routing.mixedPort;
    if (port <= 0) return null;
    return '127.0.0.1:$port';
  }

  static const _kUnlockResults = 'unlock.results';

  void _persistUnlockResults(UnlockSnapshot snapshot) {
    if (_disposed || !storeReady) return;
    _settings?.setJson(_kUnlockResults, snapshot.toJson());
  }

  /// Restores the previous sweep.
  ///
  /// Without this, every launch shows thirteen 未检测 cards for a question that
  /// was already answered, and the user has no way to tell "not checked yet"
  /// from "checked and the result was thrown away".
  void _restoreUnlockResults() {
    final snapshot = UnlockSnapshot.fromJson(
      _settings?.getJson(_kUnlockResults),
    );
    if (snapshot != null) unlock.restore(snapshot);
  }

  /// The node currently carrying traffic, for labelling a measurement with what
  /// it actually measured.
  ({String id, String name})? _activeNode() {
    final id = runtime.snapshot?.activeNodeId;
    if (id == null || id.isEmpty) return null;
    final node = catalog.nodeByIdOrNull(id);
    if (node == null) return null;
    return (id: node.id, name: node.name);
  }

  /// Anything that wrote a node/subscription row outside [_command] calls this.
  void notifyExternalChange() {
    invalidateCatalogCache();
    catalogChanged();
    // Imports, deletions, renames and batch edits all land here, so this is the
    // one place that keeps the tray's node list in step with the database.
    _publishTrayCatalog();
  }

  /// Applies the shipped default rule list the first time it is seeded.
  ///
  /// Without this the window shows 18 enabled rules while the running core has
  /// only its built-in four, and the difference stays invisible until someone
  /// notices that a rule "does not work".
  ///
  /// Called from the launch path *after* a snapshot exists, because
  /// `reapplyRoutingIfPossible` needs a connected host and an active node;
  /// calling it during `start()` returned false every time and the seeded list
  /// never reached the core.
  ///
  /// Best-effort: a failure here must never block start-up, and the next node
  /// selection carries the rules anyway since `build` reads the settings.
  Future<void> _applySeededRules() async {
    if (!RoutingSettings.justSeededDefaults) return;
    RoutingSettings.justSeededDefaults = false;
    try {
      // The host's `activeNodeId` can name a node this database no longer has:
      // it survives in the host's snapshot from an earlier session, and a node
      // that was deleted or re-imported with a different id leaves it dangling.
      // `reapplyRoutingIfPossible` then returns false without an error, so the
      // seeded rules never reach the core and the page claims they are on.
      //
      // Selecting a replacement is the same repair "apply routing" would need,
      // and it is the behaviour a user expects: pick something usable rather
      // than silently keep a broken selection.
      final activeId = runtime.snapshot?.activeNodeId;
      final stale =
          activeId == null ||
          activeId.isEmpty ||
          nodeRepo.nodeById(activeId) == null;
      if (stale) {
        final fallback = loadNodes().firstOrNull;
        if (fallback == null) return;
        await selectNode(fallback.id);
        return;
      }
      if (await reapplyRoutingIfPossible()) runtimeChanged();
    } catch (_) {
      // The rules are stored; applying them is a refresh, not a requirement.
    }
  }

  /// Fire-and-forget wrapper: every caller is a UI action that must not wait on
  /// the tray, and a failure is already swallowed inside [publishTrayCatalog].
  void _publishTrayCatalog() {
    unawaited(publishTrayCatalog());
  }

  Future<void> _ensureHost() async {
    final override = Platform.environment['HALO_HOST_EXE'];
    final base = File(Platform.resolvedExecutable).parent;
    final candidates = [?override, '${base.path}/halo-host.exe'];
    for (final candidate in candidates) {
      if (!await File(candidate).exists()) continue;
      // Detached host lifetime must not depend on this UI's standard handles.
      final check = await Process.run(candidate, [
        '--status',
        '--dir',
        dataDir,
      ]).timeout(const Duration(seconds: 5));
      final status = jsonDecode('${check.stdout}') as Map;
      if (status['running'] != true) {
        await Process.start(candidate, [
          '--dir',
          dataDir,
          // Marks this host as started *by* a UI. Such a host must never open a
          // window when it loses the single-instance race; otherwise the UI and
          // the tray keep launching each other and the desktop fills with UI
          // processes, one every couple of seconds.
          '--from-ui',
        ], mode: ProcessStartMode.detached);
      }
      return;
    }
    _lastActionError = '未找到后台程序，请将 halo-host.exe 和 sing-box.exe 放在应用目录';
  }

  /// Refreshes one subscription. See [SubscriptionManager].
  Future<SubscriptionUpdate> updateSubscription(
    SubscriptionProfile profile, {
    bool viaProxy = false,
  }) => subscriptions.update(profile, viaProxy: viaProxy);

  /// Address of the running core's mixed inbound, for proxied downloads.
  ///
  /// Read from the persisted routing settings rather than hard-coded, so a user
  /// who moved the port still gets a working tunnel. The mixed inbound accepts
  /// HTTP CONNECT, which is what a proxied https download needs.
  String get proxyEndpoint => 'http://127.0.0.1:${routing.mixedPort}';

  /// Whether a proxied download has anything to talk to.
  ///
  /// Turning the switch on with no core running produces `connection refused` on
  /// localhost, which reads as "the client is broken". The page asks this first
  /// so it can say what is actually missing.
  bool get proxyAvailable =>
      runtime.snapshot?.coreState == CoreState.running && connected;

  /// The client name providers key their response on.
  ///
  /// Kept as a re-export of the shared constant so existing callers and tests
  /// that mention AppController keep compiling.
  static const subscriptionUserAgent = kSubscriptionUserAgent;

  /// Asks every listener to re-read. Removed: no caller ever used it, and a
  /// full fan-out is exactly what the narrow channels exist to avoid.

  /// The host snapshot moved: core, system proxy, TUN, active node, versions.
  void runtimeChanged() {
    if (_disposed) return;
    runtime.revision.value++;
  }

  /// The Windows-proxy switch alone moved. Only its card has to repaint.
  void proxyChanged() {
    if (_disposed) return;
    runtime.proxyRevision.value++;
  }

  /// A node or subscription row was written.
  void catalogChanged() {
    if (_disposed) return;
    catalogRevision.value++;
  }

  /// The pipe came up or went down.
  void connectionChanged() {
    if (_disposed) return;
    connectionRevision.value++;
    _syncTrafficPolling();
  }

  /// Starts/stops the session throughput sampler.
  ///
  /// The sampler lives on the controller so the history and accumulated bytes
  /// survive leaving and reopening the overview. Only Windows has the host
  /// connection list this is derived from.
  void _syncTrafficPolling() {
    if (_snapshotInjectedForTest) return;
    if (_disposed || !Platform.isWindows) {
      _stopTrafficPolling(reset: true);
      return;
    }
    if (!connected) {
      // Keep the samples across a transient pipe drop: the host may come back
      // with the same core, and the session totals are still meaningful.
      _trafficTimer?.cancel();
      _trafficTimer = null;
      return;
    }
    final snap = runtime.snapshot;
    final running = connected && snap != null && snap.coreState.isRunning;
    final key = running ? (snap.corePid, snap.tunPid) : null;
    if (key == _trafficCore) {
      if (running && _trafficTimer == null) _startTrafficPolling();
      if (!running && _trafficTimer != null) {
        _stopTrafficPolling(reset: true);
      }
      return;
    }
    _trafficCore = key;
    _stopTrafficPolling(reset: true);
    if (running) _startTrafficPolling();
    trafficRevision.value++;
  }

  void _startTrafficPolling() {
    _trafficTimer?.cancel();
    _trafficTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollTraffic());
    });
    // Sample immediately: otherwise a fresh page shows "等待采样…" for two
    // seconds even though the connections are already available.
    unawaited(_pollTraffic());
  }

  void _stopTrafficPolling({required bool reset}) {
    _trafficTimer?.cancel();
    _trafficTimer = null;
    if (reset) {
      _throughput.reset();
      _trafficError = null;
    }
  }

  Future<void> _pollTraffic() async {
    if (_trafficPolling || _disposed || !Platform.isWindows) return;
    _trafficPolling = true;
    try {
      _applyTraffic(await fetchTrafficSession());
    } on Object catch (error) {
      _trafficError = '$error';
    } finally {
      _trafficPolling = false;
      if (!_disposed) trafficRevision.value++;
    }
  }

  /// Reads the host's traffic clock.
  ///
  /// Overridable so a widget test can supply a snapshot without standing up a
  /// host pipe; the production path is a host action and never samples the
  /// connection list from this isolate.
  @visibleForTesting
  Future<TrafficSessionState> fetchTrafficSession() async {
    final response = await client.send(
      HaloAction.trafficGet,
      timeout: const Duration(seconds: 4),
    );
    if (!response.ok) {
      throw HaloError(
        response.error?.code ?? HaloErrorCode.internal,
        response.error?.message ?? '读取流量统计失败',
        response.error?.detail,
      );
    }
    return TrafficSessionState.fromJson(_jsonMap(response.result));
  }

  /// Only the one-line action-error strip needs repainting.
  void errorChanged() {
    if (_disposed) return;
    errorRevision.value++;
  }

  /// HostConnection callback for a terminal protocol mismatch.
  void _onConnectionError(String message) {
    _lastActionError = message;
    errorChanged();
  }

  /// HostConnection callback for `host.exiting`: the window closes, the host is
  /// not ours to kill.
  void _onHostExitingEvent() {
    if (_exitCalled) return;
    _exitCalled = true;
    unawaited(exitApp());
  }

  Future<void> dispose() async {
    _disposed = true;
    _androidStatusTimer?.cancel();
    _androidStatusTimer = null;
    _trafficTimer?.cancel();
    _trafficTimer = null;
    unlock.dispose();
    subscriptions.dispose();
    await _streamSub?.cancel();
    await host.dispose();
    await client.dispose();
    _store?.close();
    await _logLines.close();
    await speed.dispose();
    runtime.dispose();
    trafficRevision.dispose();
    sessionRevision.dispose();
    catalogRevision.dispose();
    connectionRevision.dispose();
    errorRevision.dispose();
  }

  // ------------------------------------------------------------------
  // Guidance
  // ------------------------------------------------------------------

  /// The single next step a user should take, or null when the app is running.
  ///
  /// Both reference clients answer "what do I do now?" in one visible place —
  /// v2rayN's status bar turns into "Invalid configuration, please check or
  /// reselect", Verge's home cards each carry exactly one primary action. This
  /// is that one answer, derived from state the UI already holds so no page has
  /// to duplicate the rules:
  ///
  ///   1. no database            → everything is unavailable;
  ///   2. host pipe down         → wait for the background service;
  ///   3. no nodes               → import a subscription;
  ///   4. no active node applied → pick a node;
  ///   5. core not running       → start it;
  ///   6. no traffic path        → turn on the system proxy or TUN.
  /// Android 的下一步提示。与 Windows 的宿主状态无关：节点表来自数据库，
  /// 运行状态来自 `:vpn` 的状态文件。
  NextStep? _androidNextStep() {
    final nodes = loadNodes();
    if (nodes.isEmpty) {
      return NextStep(
        page: HaloStepPage.subscriptions,
        title: '先导入节点',
        detail: '粘贴订阅链接或分享链接，导入后节点会出现在「节点」页。',
        actionLabel: '去导入',
        kind: NextStepKind.blocking,
      );
    }
    final activeId = activeNodeId;
    if (activeId == null || activeId.isEmpty) {
      return NextStep(
        page: HaloStepPage.nodes,
        title: '选择一个节点',
        detail: '已有 ${nodes.length} 个节点，选中一个并启用后才会开始代理。',
        actionLabel: '去选择',
        kind: NextStepKind.blocking,
      );
    }
    final status = _androidVpnStatus;
    if (status != null && status.isFailed) {
      return NextStep(
        page: HaloStepPage.overview,
        title: 'VPN 启动失败',
        detail: status.message.isEmpty ? '内核未能建立隧道，请查看日志后重试。' : status.message,
        actionLabel: '重试',
        action: NextStepAction.startCore,
        kind: NextStepKind.blocking,
      );
    }
    if (status != null && status.isStarting) {
      return const NextStep(
        page: HaloStepPage.overview,
        title: '正在连接 VPN',
        detail: '服务正在建立隧道。',
        actionLabel: '刷新',
        kind: NextStepKind.waiting,
      );
    }
    if (status != null && status.isStarted) return null;
    return const NextStep(
      page: HaloStepPage.overview,
      title: '代理未启动',
      detail: '节点已选择。启动 VPN 后，流量才会经代理转发。',
      actionLabel: '启动',
      action: NextStepAction.startCore,
      kind: NextStepKind.blocking,
    );
  }

  NextStep? get nextStep {
    if (!storeReady) return null;
    if (Platform.isAndroid) return _androidNextStep();
    if (hostExiting) {
      // The host said goodbye and is shutting down. Offering 「重试连接」 here
      // would ask the user to reconnect to a process that is being torn down,
      // and the window is about to go anyway.
      return const NextStep(
        page: HaloStepPage.overview,
        title: '后台服务已退出',
        detail: '代理已停止，系统代理正在恢复。重新从开始菜单启动 Clash Halo 即可继续使用。',
        actionLabel: '知道了',
        kind: NextStepKind.stopped,
      );
    }
    if (connection == HostConnectionState.versionMismatch) {
      // The pipe works but the two processes disagree about the wire format.
      // This is a stopped state, not the "connecting" spinner: no retry can
      // fix it, the user has to install a matching UI and host.
      return const NextStep(
        page: HaloStepPage.overview,
        title: '后台服务版本不一致',
        detail: '界面与 halo-host.exe 的协议版本不同，请求无法送达。请使用同一版本的安装包更新后重新启动。',
        actionLabel: '重试连接',
        kind: NextStepKind.stopped,
      );
    }
    if (!connected) {
      return const NextStep(
        page: HaloStepPage.overview,
        title: '正在连接后台服务',
        detail: '如果一直停在这里，请确认 halo-host.exe 与 halo-host 在同一目录。',
        actionLabel: '重试连接',
        kind: NextStepKind.waiting,
      );
    }
    final nodes = loadNodes();
    if (nodes.isEmpty) {
      return NextStep(
        page: HaloStepPage.subscriptions,
        title: '先导入节点',
        detail: '粘贴订阅链接或分享链接，导入后节点会出现在「节点」页。',
        actionLabel: '去导入',
        kind: NextStepKind.blocking,
      );
    }
    final snap = runtime.snapshot;
    final activeId = snap?.activeNodeId;
    if (activeId == null || activeId.isEmpty) {
      return NextStep(
        page: HaloStepPage.nodes,
        title: '选择一个节点',
        detail: '已有 ${nodes.length} 个节点，选中一个并启用后才会开始代理。',
        actionLabel: '去选择',
        kind: NextStepKind.blocking,
      );
    }
    if (snap != null && !snap.coreState.isRunning) {
      // The host restores a core that was running last session (coreWanted),
      // and that takes a moment after the pipe connects. Reporting "代理内核未
      // 运行" during that window made every launch flash a blocking step that
      // was already being resolved, and the next line down would then claim the
      // core *is* running. Silence is the honest answer while it comes up.
      final comingUp =
          snap.coreState.isBusy ||
          (snap.coreWanted &&
              (snap.lastErrorMessage == null ||
                  snap.lastErrorMessage!.isEmpty));
      if (comingUp) return null;
      return const NextStep(
        page: HaloStepPage.overview,
        title: '代理内核未运行',
        detail: '节点已选好，启动内核后系统代理才能生效。',
        actionLabel: '去启动',
        action: NextStepAction.startCore,
        kind: NextStepKind.blocking,
      );
    }
    // Deliberately no step for "core is running but the system proxy and TUN
    // are both off".
    //
    // It was a blocking banner reading 流量还没有接管 with a 去开启 button, and it
    // earned none of the space it took: the system proxy and TUN already have
    // their own status items in the status bar and their own switches on the
    // overview, both of which say 已关闭 in plain words the moment they are off.
    // A second, louder copy of the same fact on the page the user is already
    // looking at is a nag, not guidance — and it also duplicated the status bar
    // on every other page.
    //
    // The state is not hidden: turn the proxy off and both switches, both
    // status-bar items and the 连接 page's empty state change immediately.
    return null;
  }
}

/// What a [NextStep] should do when it cannot navigate anywhere useful.
///
/// The overview steps point at the overview page itself, so "navigate" there is
/// a no-op: the button in the next-step card and the one in the status bar both
/// did nothing at all. Carrying the action means the same button performs the
/// thing the sentence describes.
///
/// `enableSystemProxy` used to live here for the 流量还没有接管 step. With that
/// step gone nothing produces it, so it is gone too rather than left as an
/// action that no caller can reach.
enum NextStepAction { startCore }

/// Where a [NextStep] sends the user.
///
/// Deliberately a page enum of its own: the shell owns the navigation state, and
/// the controller must not depend on a widget-layer enum.
enum HaloStepPage { overview, nodes, subscriptions }

/// What kind of step this is, which decides how it is drawn.
///
/// `waiting` renders as a spinner because the app is genuinely waiting for
/// something (the host is still booting). `stopped` is the opposite: nothing
/// will change until the user acts, so a spinner there is a lie — and a
/// permanently spinning strip is exactly the "stuck forever" look users report.
enum NextStepKind { blocking, waiting, stopped }

/// One concrete "do this next" instruction.
class NextStep {
  const NextStep({
    required this.page,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.kind,
    this.action,
  });

  final HaloStepPage page;
  final String title;
  final String detail;
  final String actionLabel;
  final NextStepKind kind;

  /// The thing to do when [page] is already the page the user is looking at.
  /// Null means "just navigate".
  final NextStepAction? action;
}
