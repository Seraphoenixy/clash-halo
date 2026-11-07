import 'dart:async';

import 'package:halo/src/ipc/halo_client.dart';

/// Owns the pipe lifecycle: connecting, the reconnect timer, and the
/// terminal "host is exiting" state.
///
/// This used to live inside AppController together with the store, snapshot and
/// catalog. Keeping it separate means the reconnect behaviour can be tested
/// without a database, and the controller only reacts to state changes instead
/// of implementing them as well.
class HostConnection {
  HostConnection({
    required this.client,
    required this.reconnectDelay,
    required this.onChanged,
    required this.onConnected,
    required this.onError,
    required this.onHostExiting,
    this.ensureHost,
  });

  final HaloClient client;

  /// Delay before a dropped pipe is retried.
  final Duration reconnectDelay;

  /// Called after every state change; the controller repaints its narrow
  /// connection channel from this.
  final void Function() onChanged;

  /// Called after a successful connect, before the state is published as
  /// usable. The controller re-subscribes, fetches a snapshot and refreshes the
  /// catalog here.
  final Future<void> Function() onConnected;

  /// A version mismatch is terminal for this build; the message is shown in
  /// the action-error strip and no reconnect is scheduled.
  final void Function(String message) onError;

  /// The host announced its own exit. The controller closes the window; this
  /// class only records the state.
  final void Function() onHostExiting;

  /// Starts the host binary if it is not running. Only available on Windows;
  /// null in tests and on other platforms.
  final Future<void> Function()? ensureHost;

  HostConnectionState _state = HostConnectionState.idle;
  bool _connecting = false;
  bool _hostExiting = false;
  bool _disposed = false;
  Timer? _reconnectTimer;
  StreamSubscription<HostConnectionState>? _subscription;

  HostConnectionState get state => _state;

  bool get connected => _state == HostConnectionState.connected;

  bool get hostExiting => _hostExiting;

  /// Subscribes to the client before the first connect attempt.
  ///
  /// [connect] is false for tests that drive the state directly; the
  /// subscription is still installed so a fake client behaves like the real
  /// one.
  Future<void> start({bool connect = true}) async {
    _subscription ??= client.connectionState.listen(_onClientState);
    if (connect) await connectNow();
  }

  /// One connect attempt. Failures schedule a retry; success runs
  /// [onConnected].
  Future<void> connectNow() async {
    if (_disposed || _hostExiting || _connecting || connected) return;
    _connecting = true;
    _reconnectTimer?.cancel();
    try {
      await client.connect();
      _state = HostConnectionState.connected;
      await onConnected();
    } on Object {
      _state = HostConnectionState.disconnected;
      scheduleReconnect();
    } finally {
      _connecting = false;
      onChanged();
    }
  }

  /// Retries immediately instead of waiting for the next scheduled attempt.
  ///
  /// This also re-probes for the host binary, which the background timer does
  /// not do: a user staring at a stuck status strip wants an answer now.
  Future<void> retry() async {
    if (_disposed || connected) return;
    _reconnectTimer?.cancel();
    if (_state == HostConnectionState.idle && ensureHost != null) {
      try {
        await ensureHost!();
      } on Object {
        // Reported through the status bar; a failed probe is not fatal.
      }
    }
    await connectNow();
  }

  /// Schedules the next connect attempt. Idempotent within one delay window.
  void scheduleReconnect() {
    if (_disposed || _hostExiting) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      if (_disposed) return;
      unawaited(connectNow());
    });
  }

  /// The pipe failed under an already-connected client (a request noticed it
  /// first). Publishes the state change without waiting for the stream.
  void noteDisconnected() {
    if (_disposed || _state != HostConnectionState.connected) return;
    if (client.isConnected) return;
    _state = HostConnectionState.disconnected;
    scheduleReconnect();
    onChanged();
  }

  /// The host announced `host.exiting`. Terminal: no reconnect is scheduled.
  void markHostExiting() {
    if (_hostExiting) return;
    _hostExiting = true;
    _reconnectTimer?.cancel();
    _state = HostConnectionState.disconnected;
    onChanged();
    onHostExiting();
  }

  /// Test seam: publishes a state without a real pipe.
  void setStateForTest(HostConnectionState next) {
    _state = next;
    onChanged();
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
  }

  void _onClientState(HostConnectionState state) {
    if (_disposed) return;
    _state = state;
    if (state == HostConnectionState.disconnected) scheduleReconnect();
    if (state == HostConnectionState.versionMismatch) {
      // Every frame from that host is rejected; reconnecting repeats the same
      // mismatch, so say what is wrong once and wait for a matching install.
      _reconnectTimer?.cancel();
      onError('后台服务协议版本不一致，请更新到同一版本后重新启动客户端');
    }
    onChanged();
  }
}
