/// Action names. Actions are frozen strings; the Go host and Dart client must
/// agree on them exactly. Unknown actions fail with [HaloErrorCode.unknownAction].
class HaloAction {
  static const snapshotGet = 'snapshot.get';
  static const hostStatus = 'host.status';
  static const hostShutdown = 'host.shutdown';
  static const coreStart = 'core.start';
  static const coreStop = 'core.stop';
  static const coreRestart = 'core.restart';
  static const configApply = 'config.apply';
  static const nodeSelect = 'node.select';
  static const proxySetMode = 'proxy.setMode';
  static const systemProxySet = 'systemProxy.set';
  static const autoLaunchSet = 'autoLaunch.set';

  /// Toggles whether a core that was running last session is started again
  /// on the next host launch. Reading a node's config and starting the core
  /// is cheap and reversible; taking over the system proxy is not, and stays
  /// a separate, explicit act either way.
  static const coreResumeSet = 'coreResume.set';
  static const tunSetEnabled = 'tun.setEnabled';
  static const tunServiceStatus = 'tun.serviceStatus';
  static const tunServiceInstall = 'tun.serviceInstall';
  static const tunServiceUninstall = 'tun.serviceUninstall';
  static const speedTestStart = 'speedtest.start';
  static const taskCancel = 'task.cancel';
  static const logTail = 'log.tail';
  static const eventSubscribe = 'event.subscribe';

  /// Publishes a compact node catalogue to the host so the tray menu can list
  /// nodes. The database stays authoritative in Dart; the host only keeps a
  /// projection (id, name, subscription group) for the menu.
  static const trayPublish = 'tray.publish';

  /// Live connections are read through the host: the sing-box Clash API is
  /// loopback-only and the host already owns the running config that names it.
  static const connectionsList = 'connections.list';
  static const connectionsClose = 'connections.close';

  static const all = <String>{
    snapshotGet,
    hostStatus,
    hostShutdown,
    coreStart,
    coreStop,
    coreRestart,
    configApply,
    nodeSelect,
    proxySetMode,
    systemProxySet,
    autoLaunchSet,
    coreResumeSet,
    tunSetEnabled,
    tunServiceStatus,
    tunServiceInstall,
    tunServiceUninstall,
    speedTestStart,
    taskCancel,
    logTail,
    eventSubscribe,
    trayPublish,
    connectionsList,
    connectionsClose,
  };
}

/// Event names pushed by the host. Subscribers receive them after
/// [HaloAction.eventSubscribe]; a reconnect must call [HaloAction.snapshotGet]
/// first instead of replaying missed events.
class HaloEvent {
  static const stateChanged = 'state.changed';
  static const logAppended = 'log.appended';
  static const taskStarted = 'task.started';
  static const taskProgress = 'task.progress';
  static const taskFinished = 'task.finished';
  static const hostExiting = 'host.exiting';

  /// The tray asked for something the host cannot do alone (currently: switch
  /// to a node). The host also writes the same payload to `tray-request.json`,
  /// because the tray has to work with no UI process running.
  static const trayCommand = 'tray.command';
}
