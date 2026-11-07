import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:halo_contracts/halo_contracts.dart';

import 'win_pipe.dart';

/// Connection state surfaced to the UI.
enum HostConnectionState {
  /// Never connected yet (first launch, or the host is still starting).
  idle,
  connecting,
  connected,

  /// The pipe came up, but the host speaks a different wire protocol.
  ///
  /// A distinct state, not [disconnected]: nothing is wrong with the transport
  /// or the host process, so reconnecting would only repeat the same failure.
  /// Every request would be rejected, and leaving the UI on [connected] made
  /// them time out behind a status that claimed the connection was healthy.
  versionMismatch,
  disconnected,
}

/// A single logical connection to the background host.
///
/// Guarantees required by the contract (spec 7.3):
///   * mutating commands are strictly serialised, so a button the user
///     double-clicks cannot interleave two config applies;
///   * every request is answered by id, so an interleaved event can never be
///     mistaken for the reply — and several requests may now be in flight at
///     once, because read-only queries ([sendRead]) do not join the command
///     queue (see below);
///   * after a reconnect the caller must fetch a fresh snapshot instead of
///     replaying missed events, so no event is ever buffered across a break.
///
/// Why reads bypass the queue: the host serialises mutating work in one
/// worker, and a TUN enable parks that worker for up to 90 seconds waiting on
/// a UAC answer. When every request — including the pages' polling — waited
/// behind it, the whole UI froze on its last frame for the duration. Reads
/// are pure queries host-side and are dispatched outside that worker, so the
/// client may write them immediately; responses are paired by id either way.
class HaloClient {
  HaloClient({
    this.pipeName = kPipeName,
    this.pollInterval = const Duration(milliseconds: 12),
    HostTransport? transport,
  }) : _transport = transport ?? const WindowsHostTransport();

  final String pipeName;

  /// Poll interval for pipes without a native handle (test fakes). Real pipes
  /// are serviced by a blocking reader isolate instead.
  final Duration pollInterval;
  final HostTransport _transport;

  final HaloCodec _codec = const HaloCodec();
  final StreamController<HaloEventMessage> _events =
      StreamController<HaloEventMessage>.broadcast();
  final StreamController<HostConnectionState> _connection =
      StreamController<HostConnectionState>.broadcast();

  WindowsPipe? _pipe;
  Timer? _pollTimer;

  /// A partially received line, held as a cursor over one growable buffer.
  ///
  /// Buffering raw bytes (not decoded text) matters: the host writes UTF-8
  /// log lines containing Chinese, and a chunk boundary can fall inside a
  /// multi-byte sequence. Decoding per chunk would corrupt those lines.
  ///
  /// A cursor instead of a take-and-put-back [BytesBuilder]: the old code
  /// copied the unconsumed tail twice per drain, which made a large frame
  /// split across N chunks cost O(N²) copies.
  Uint8List _buffer = Uint8List(0);
  int _bufferStart = 0;
  int _bufferEnd = 0;

  HostConnectionState _state = HostConnectionState.idle;

  /// Requests awaiting their reply, keyed by correlation id.
  final Map<String, _PendingRequest> _pending = {};

  /// Resolves when the last issued command's response arrived (or failed).
  /// The next command's frame is written only after that.
  Future<void> _commandSettled = Future<void>.value();

  int _nextId = 0;
  bool _disposed = false;

  /// The isolate that services the pipe when it has a real handle.
  Isolate? _reader;
  ReceivePort? _readerPort;
  StreamSubscription<dynamic>? _readerSub;

  /// The reader's own handle, owned and closed by this isolate.
  ///
  /// It is handed to the reader isolate as a number and borrowed there, so
  /// there is exactly one owner (and one `CloseHandle`) per handle value.
  WindowsPipe? _readerPipe;

  HostConnectionState get state => _state;

  Stream<HaloEventMessage> get events => _events.stream;

  Stream<HostConnectionState> get connectionState => _connection.stream;

  bool get isConnected => _state == HostConnectionState.connected;

  /// Opens the pipe and starts the reader. Safe to call again after a drop.
  Future<void> connect() async {
    if (_disposed) return;
    if (_state == HostConnectionState.connected) return;
    _setState(HostConnectionState.connecting);
    try {
      final pipe = await _transport.connect(pipeName);
      _pipe = pipe;
      _clearBuffer();
      _setState(HostConnectionState.connected);
      _startPump();
    } on Object {
      _setState(HostConnectionState.disconnected);
      rethrow;
    }
  }

  /// Starts whichever reader the pipe supports.
  ///
  /// A real pipe hands its handle to a long-lived isolate that does blocking
  /// reads, so the UI isolate is only woken when data actually arrived; the
  /// previous 12 ms [Timer] kept the isolate polling ~83 times a second for
  /// the entire life of the app, window minimized or not. Pipes without a
  /// handle (test fakes) keep the timer.
  void _startPump() {
    final pipe = _pipe;
    final handle = pipe?.handle;
    if (pipe == null || handle == null) {
      _startPolling();
      return;
    }
    final WindowsPipe readerPipe;
    try {
      // A duplicate, not the UI's own handle: both sides used to close the
      // same value, and a stale `CloseHandle` then killed whichever
      // connection had been handed that value next.
      readerPipe = pipe.duplicate();
    } on Object {
      // Duplication failing is not fatal: polling still reads the pipe from
      // this isolate.
      _startPolling();
      return;
    }
    _readerPipe = readerPipe;
    _startReader(readerPipe.handle!);
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _drain());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _startReader(int handle) {
    final port = ReceivePort();
    _readerPort = port;
    _readerSub = port.listen((message) {
      if (message is Uint8List) {
        _appendChunk(message);
        _consumeLines();
        return;
      }
      if (message == _kReaderClosed) _handleDrop();
    });
    Isolate.spawn(_readerLoop, _ReaderConfig(handle, port.sendPort))
        .then<void>((isolate) {
      // The connection may have dropped (or been replaced) while the isolate
      // was starting. _stopReader could not kill an isolate it did not know
      // about yet, so the late one is stopped here instead of being left to
      // poll a handle its owner has already closed.
      if (_disposed || !identical(_readerPort, port)) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _reader = isolate;
    }, onError: (Object _) {
      // A superseded spawn failure must not tear down the reader that
      // replaced it.
      if (!identical(_readerPort, port)) return;
      // No isolate support in this environment: poll rather than go deaf.
      _stopReader();
      _startPolling();
    });
  }

  void _stopReader() {
    _readerSub?.cancel();
    _readerSub = null;
    _readerPort?.close();
    _readerPort = null;
    _reader?.kill(priority: Isolate.immediate);
    _reader = null;
    // The reader only borrowed its handle. Closing the duplicate here — after
    // the isolate is gone, and only from its owner — is the one release that
    // happens for it, so a reader killed mid-read can never close a handle
    // value the OS has already reused.
    _readerPipe?.close();
    _readerPipe = null;
  }

  /// The blocking read loop. Runs in its own isolate for the pipe's lifetime.
  ///
  /// When nothing is ready the loop sleeps with a short backoff instead of
  /// spinning: data that is ready is picked up within ~2 ms, and an idle
  /// session (minimized window, no traffic) settles at 16 ms — wakeups that
  /// cost nanoseconds in a background thread instead of a full FFI round
  /// trip on the UI isolate.
  static Future<void> _readerLoop(_ReaderConfig config) async {
    // The handle is borrowed: the UI isolate owns it and releases it once this
    // isolate is gone. Calling `CloseHandle` here would be a second close of a
    // value the OS may already have reused for a new connection.
    final pipe = WindowsPipe.fromHandle(config.handle, ownsHandle: false);
    var backoff = 2;
    while (true) {
      if (!pipe.isOpen) {
        config.port.send(_kReaderClosed);
        return;
      }
      Uint8List chunk;
      try {
        chunk = pipe.read(_kReaderChunkBytes);
      } on Object {
        config.port.send(_kReaderClosed);
        return;
      }
      if (chunk.isEmpty) {
        await Future<void>.delayed(Duration(milliseconds: backoff));
        if (backoff < 16) backoff *= 2;
        continue;
      }
      backoff = 2;
      config.port.send(chunk);
    }
  }

  void _stopPump() {
    _stopPolling();
    _stopReader();
  }

  /// Reads everything currently available and dispatches complete lines.
  ///
  /// Only used for pipes without a handle; real pipes are read in the reader
  /// isolate.
  void _drain() {
    final pipe = _pipe;
    if (pipe == null || !pipe.isOpen) {
      _handleDrop();
      return;
    }
    try {
      while (true) {
        final chunk = pipe.read();
        if (chunk.isEmpty) break;
        _appendChunk(chunk);
      }
      _consumeLines();
    } on Object {
      _handleDrop();
    }
  }

  void _appendChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    final live = _bufferEnd - _bufferStart;
    if (_buffer.length < live + chunk.length) {
      var capacity = _buffer.isEmpty ? 8192 : _buffer.length * 2;
      while (capacity < live + chunk.length) {
        capacity *= 2;
      }
      final next = Uint8List(capacity);
      if (live > 0) {
        next.setRange(0, live, _buffer, _bufferStart);
      }
      _buffer = next;
      _bufferStart = 0;
      _bufferEnd = live;
    } else if (_buffer.length - _bufferEnd < chunk.length) {
      // Enough room in total, not enough at the tail: compact in place.
      if (live > 0) {
        _buffer.setRange(0, live, _buffer, _bufferStart);
      }
      _bufferEnd = live;
      _bufferStart = 0;
    }
    _buffer.setRange(_bufferEnd, _bufferEnd + chunk.length, chunk);
    _bufferEnd += chunk.length;
  }

  void _clearBuffer() {
    _buffer = Uint8List(0);
    _bufferStart = 0;
    _bufferEnd = 0;
  }

  /// Splits the buffered bytes on `\n`, decoding only complete lines.
  void _consumeLines() {
    var start = _bufferStart;
    for (var i = start; i < _bufferEnd; i++) {
      if (_buffer[i] != 0x0A) continue;
      final line = utf8.decode(
        Uint8List.sublistView(_buffer, start, i),
        allowMalformed: true,
      );
      start = i + 1;
      if (line.trim().isEmpty) continue;
      _dispatchLine(line);
    }
    _bufferStart = start;
    if (_bufferStart == _bufferEnd) {
      _clearBuffer();
    } else if (_bufferStart > 0 && _bufferStart * 2 > _bufferEnd) {
      // Reclaim the consumed prefix so an idle stream cannot grow the buffer
      // without bound (log bursts repeatedly overwrite this frontier).
      final live = _bufferEnd - _bufferStart;
      _buffer.setRange(0, live, _buffer, _bufferStart);
      _bufferStart = 0;
      _bufferEnd = live;
    }
  }

  void _dispatchLine(String line) {
    HaloMessage message;
    try {
      message = _codec.decode(line);
    } on HaloProtocolException catch (error) {
      // A malformed frame must not kill the connection: the host may be
      // mid-upgrade, and a single bad line should not log the user out.
      //
      // A version mismatch is not noise. Every frame from that host is
      // rejected the same way, so staying connected only leaves requests
      // timing out behind a status that says everything is fine.
      if (error.code == HaloErrorCode.versionMismatch) {
        _handleVersionMismatch(error);
      }
      return;
    }
    switch (message) {
      case HaloResponse():
        _completePending(message);
      case HaloEventMessage():
        if (!_events.isClosed) _events.add(message);
      case HaloRequest():
        // The client never receives requests; ignoring one is safer than
        // treating it as a reply.
        break;
    }
  }

  void _completePending(HaloResponse response) {
    final pending = _pending.remove(response.id);
    // A reply whose id matches nothing in flight is dropped: only a request
    // we actually sent may complete a future.
    if (pending == null) return;
    pending.timer?.cancel();
    if (!pending.completer.isCompleted) pending.completer.complete(response);
  }

  /// Sends [action] and waits for its response, serialised behind every other
  /// mutating command.
  ///
  /// Commands are strictly serialised: the next command's frame is not
  /// written until the previous one has been answered. Applying a config and
  /// then switching a node must therefore happen in the order the user
  /// clicked, never interleaved (spec 7.3). A response whose id does not match
  /// is ignored (see [_completePending]); if the host never answers, the
  /// request fails with a timeout rather than hanging the UI forever.
  Future<HaloResponse> send(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) {
    final failure = _preflight();
    if (failure != null) return failure;
    final id = 'u${++_nextId}';
    final line = _codec.encode(
      HaloRequest(id: id, action: action, params: params),
    );
    // The chain awaits the whole round trip, so a queued command is written
    // only after its predecessor is answered (or has failed).
    final result = _commandSettled.then((_) => _writeNow(id, line, timeout));
    // Keep the chain alive even when a request fails, so one failure does not
    // permanently block every later command.
    _commandSettled = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Sends a read-only request immediately, without waiting for any command's
  /// response.
  ///
  /// Intended for the four query actions the host dispatches on its read fast
  /// path (`snapshot.get`, `host.status`, `connections.list`, `log.tail`).
  /// Using it for a mutating action would break the serialisation invariant
  /// that two rapid config applies cannot race the core.
  ///
  /// The write is still scheduled through a microtask rather than performed
  /// inline, so a read issued *after* a command whose gate is already
  /// resolved cannot overtake that command's frame on the wire.
  Future<HaloResponse> sendRead(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) {
    final failure = _preflight();
    if (failure != null) return failure;
    final id = 'r${++_nextId}';
    final line = _codec.encode(
      HaloRequest(id: id, action: action, params: params),
    );
    return Future<void>.value().then((_) => _writeNow(id, line, timeout));
  }

  Future<HaloResponse>? _preflight() {
    if (_disposed) {
      return Future<HaloResponse>.error(
        const HaloProtocolException(HaloErrorCode.internal, '客户端已关闭'),
      );
    }
    if (!isConnected) {
      return Future<HaloResponse>.error(
        const HaloProtocolException(HaloErrorCode.internal, '后台服务未连接'),
      );
    }
    return null;
  }

  /// Registers [id] and writes [line] to the pipe synchronously, returning
  /// the future completed by the matching response.
  ///
  /// The timeout only starts once the frame is actually on the wire: a
  /// command queued behind another one must not have its budget spent on the
  /// wait.
  Future<HaloResponse> _writeNow(
    String id,
    String line,
    Duration timeout,
  ) {
    final pipe = _pipe;
    if (pipe == null || !isConnected) {
      // Checked before anything is registered: a throw after registering the
      // timer would leave it pending forever.
      throw const HaloProtocolException(HaloErrorCode.internal, '后台服务未连接');
    }
    final pending = _PendingRequest();
    _pending[id] = pending;
    pending.timer = Timer(timeout, () {
      if (_pending.remove(id) != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          HaloProtocolException(HaloErrorCode.internal, '等待响应超时'),
        );
      }
    });
    try {
      pipe.write(utf8.encode(line));
    } on Object {
      _pending.remove(id);
      pending.timer?.cancel();
      _handleDrop();
      rethrow;
    }
    return pending.completer.future;
  }

  void _failAllPending(Object error) {
    final pending = List<_PendingRequest>.of(_pending.values);
    _pending.clear();
    for (final entry in pending) {
      entry.timer?.cancel();
      if (!entry.completer.isCompleted) entry.completer.completeError(error);
    }
  }

  /// Fails the connection when a frame declares a protocol version this build
  /// cannot speak.
  ///
  /// [HostConnectionState.versionMismatch] is terminal: the host process is
  /// healthy and the pipe works, but every future frame will be rejected, so
  /// reconnecting cannot help and in-flight requests must fail now instead of
  /// timing out one by one.
  void _handleVersionMismatch(HaloProtocolException error) {
    _stopPump();
    _pipe?.close();
    _pipe = null;
    _setState(HostConnectionState.versionMismatch);
    _failAllPending(error);
  }

  void _handleDrop() {
    _stopPump();
    _pipe?.close();
    _pipe = null;
    _clearBuffer();
    _failAllPending(
      const HaloProtocolException(HaloErrorCode.internal, '与后台服务的连接已断开'),
    );
    if (_state != HostConnectionState.disconnected) {
      _setState(HostConnectionState.disconnected);
    }
  }

  void _setState(HostConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_connection.isClosed) _connection.add(next);
  }

  Future<void> dispose() async {
    _disposed = true;
    _stopPump();
    _pipe?.close();
    _pipe = null;
    _failAllPending(
      const HaloProtocolException(HaloErrorCode.internal, '客户端已关闭'),
    );
    await _events.close();
    await _connection.close();
  }
}

/// One request awaiting its reply.
class _PendingRequest {
  final Completer<HaloResponse> completer = Completer<HaloResponse>();
  Timer? timer;
}

/// Message the reader isolate sends when the pipe is gone.
const String _kReaderClosed = 'reader-closed';

/// How much the reader isolate reads per round trip.
const int _kReaderChunkBytes = 256 * 1024;

/// Plain data handed to the reader isolate.
class _ReaderConfig {
  const _ReaderConfig(this.handle, this.port);

  final int handle;
  final SendPort port;
}

/// Abstract transport so tests can drive a fake pipe.
abstract class HostTransport {
  const HostTransport();

  Future<WindowsPipe> connect(String name);
}

/// Real transport: opens the Windows named pipe through Win32 FFI.
class WindowsHostTransport extends HostTransport {
  const WindowsHostTransport({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  @override
  Future<WindowsPipe> connect(String name) async => WindowsPipe.fromHandle(
    await Isolate.run(
      () => WindowsPipe.connect(name, timeout: timeout).detach(),
    ),
  );
}
