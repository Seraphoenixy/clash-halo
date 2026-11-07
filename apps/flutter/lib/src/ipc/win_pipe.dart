import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Minimal Win32 named-pipe client.
///
/// `dart:io` cannot open Windows named pipes (`File('\\\\.\\pipe\\...')` fails
/// with errno 53), so the pipe is driven through `kernel32.dll` directly.
///
/// The connection is polled with `PeekNamedPipe` instead of blocking in
/// `ReadFile`: the UI isolate must stay responsive, and a blocking read
/// would also make the connection impossible to close on demand.
class WindowsPipe {
  WindowsPipe._(this._handle, {bool ownsHandle = true})
      : _ownsHandle = ownsHandle;

  int _handle;

  /// Whether [close] releases [_handle] with `CloseHandle`.
  ///
  /// Exactly one wrapper may own a handle value. When two wrappers share one
  /// value, the first `CloseHandle` frees it for reuse and the second then
  /// closes an unrelated handle the OS handed to the next connection.
  final bool _ownsHandle;

  /// Wraps an existing OS handle.
  ///
  /// The wrapper owns it unless [ownsHandle] is false, in which case [close]
  /// only forgets the value and leaves releasing it to the real owner.
  factory WindowsPipe.fromHandle(int handle, {bool ownsHandle = true}) =>
      WindowsPipe._(handle, ownsHandle: ownsHandle);

  /// Hands the raw handle to a new owner and stops owning it here.
  ///
  /// Only an owning wrapper may detach; a borrowing one has nothing to give.
  int detach() {
    assert(_ownsHandle, 'a borrowed handle cannot be detached');
    final handle = _handle;
    _handle = -1;
    return handle;
  }

  /// The raw OS handle, or null when this pipe has no one (test fakes).
  ///
  /// The blocking reader isolate needs the handle to service the pipe off the
  /// UI isolate; a pipe without a handle falls back to timer polling.
  int? get handle => _handle <= 0 ? null : _handle;

  bool get isOpen => _handle != -1;

  /// Duplicates the handle into a second wrapper that owns its own value.
  ///
  /// The blocking reader isolate services the pipe off the UI isolate, so
  /// without this both sides would wrap the same handle and eventually close
  /// it twice. The duplicate is a distinct value in the same process, so the
  /// UI can close its pipe while the reader still holds a valid handle.
  WindowsPipe duplicate() {
    if (!isOpen) throw const WindowsPipeException('管道已关闭', 109);
    final target = calloc<IntPtr>();
    try {
      final process = _getCurrentProcess();
      final ok = _duplicateHandle(
        process,
        _handle,
        process,
        target,
        0, // access is taken from the source with DUPLICATE_SAME_ACCESS
        0, // not inheritable
        0x00000002, // DUPLICATE_SAME_ACCESS
      );
      if (ok == 0) {
        final err = _lastError();
        throw WindowsPipeException('复制管道句柄失败（错误 $err）', err);
      }
      return WindowsPipe._(target.value);
    } finally {
      calloc.free(target);
    }
  }

  /// Opens [name], waiting up to [timeout] for the host to create the pipe.
  ///
  /// The host may still be starting, so a busy pipe is retried rather than
  /// reported as a hard failure.
  static WindowsPipe connect(
    String name, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    final namePtr = name.toNativeUtf16();
    final deadline = DateTime.now().add(timeout);
    try {
      while (true) {
        final handle = _createFileW(
          namePtr.cast<Utf16>(),
          0xC0000000 /* READ|WRITE */,
          0,
          nullptr,
          3 /* OPEN_EXISTING */,
          0,
          nullptr,
        );
        if (handle != -1 && handle != 0) {
          return WindowsPipe._(handle);
        }
        final err = _lastError();
        // 2 = file not found (no server yet), 231 = all instances busy.
        if (err != 2 && err != 231) {
          throw WindowsPipeException('无法连接到后台服务（错误 $err）', err);
        }
        if (DateTime.now().isAfter(deadline)) {
          throw WindowsPipeException(
            err == 2 ? '后台服务尚未启动' : '后台服务忙，请稍后重试',
            err,
          );
        }
        // WaitNamedPipeW blocks; its timeout is short so the deadline above
        // still governs the overall wait.
        _waitNamedPipeW(namePtr.cast<Utf16>(), 200);
      }
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Bytes currently sitting in the pipe, without consuming them.
  int get available {
    if (!isOpen) return 0;
    final availPtr = calloc<Uint32>();
    try {
      final ok = _peekNamedPipe(
        _handle,
        nullptr,
        0,
        nullptr,
        availPtr,
        nullptr,
      );
      if (ok == 0) {
        final err = _lastError();
        // 109 = broken pipe: the host went away. Report it as closed so the
        // caller can reconnect instead of spinning on a dead handle.
        if (err == 109 || err == 232 || err == 8) {
          close();
          return 0;
        }
        return 0;
      }
      return availPtr.value;
    } finally {
      calloc.free(availPtr);
    }
  }

  /// Reads up to [maxBytes] of the available data. Returns an empty list when
  /// the pipe has nothing ready (never null), so callers can poll.
  Uint8List read([int maxBytes = 8192]) {
    if (!isOpen) return Uint8List(0);
    final readPtr = calloc<Uint32>();
    try {
      final available = this.available;
      if (available == 0) return Uint8List(0);
      final want = available < maxBytes ? available : maxBytes;
      final native = calloc<Uint8>(want);
      try {
        final ok = _readFile(_handle, native, want, readPtr, nullptr);
        if (ok == 0) {
          final err = _lastError();
          if (err == 109 || err == 232) {
            close();
            return Uint8List(0);
          }
          throw WindowsPipeException('读取后台消息失败（错误 $err）', err);
        }
        // Copy out of the native buffer before freeing it.
        return Uint8List.fromList(native.asTypedList(readPtr.value));
      } finally {
        calloc.free(native);
      }
    } finally {
      calloc.free(readPtr);
    }
  }

  /// Writes [data], looping until the whole payload is accepted.
  ///
  /// The payload is copied into one native allocation with a bulk
  /// [TypedList.setAll] — the previous per-byte loop spent microseconds per
  /// byte on multi-megabyte speed-test frames before a single byte reached
  /// the pipe.
  void write(List<int> data) {
    if (!isOpen) throw const WindowsPipeException('管道已关闭', 109);
    if (data.isEmpty) return;
    final written = calloc<Uint32>();
    final native = calloc<Uint8>(data.length);
    try {
      native.asTypedList(data.length).setAll(0, data);
      var offset = 0;
      while (offset < data.length) {
        final ok = _writeFile(
          _handle,
          native + offset,
          data.length - offset,
          written,
          nullptr,
        );
        if (ok == 0) {
          final err = _lastError();
          throw WindowsPipeException('发送消息失败（错误 $err）', err);
        }
        if (written.value == 0) {
          throw const WindowsPipeException('管道拒绝写入', 109);
        }
        offset += written.value;
      }
    } finally {
      calloc.free(native);
      calloc.free(written);
    }
  }

  void close() {
    if (_handle != -1) {
      // A borrowing wrapper must never call CloseHandle: the owner may already
      // have closed that value, and the OS may have reused it for the next
      // connection (see [_ownsHandle]).
      if (_ownsHandle) _closeHandle(_handle);
      _handle = -1;
    }
  }
}

class WindowsPipeException implements Exception {
  const WindowsPipeException(this.message, this.code);

  final String message;
  final int code;

  @override
  String toString() => 'WindowsPipeException($code): $message';
}

// ---------------------------------------------------------------------------
// Bindings
// ---------------------------------------------------------------------------

typedef _CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16> name,
      Uint32 access,
      Uint32 share,
      Pointer<Void> security,
      Uint32 disposition,
      Uint32 flags,
      Pointer<IntPtr> template,
    );
typedef _CreateFileWDart =
    int Function(
      Pointer<Utf16> name,
      int access,
      int share,
      Pointer<Void> security,
      int disposition,
      int flags,
      Pointer<IntPtr> template,
    );

typedef _WaitNamedPipeWNative =
    IntPtr Function(Pointer<Utf16> name, Uint32 timeout);
typedef _WaitNamedPipeWDart = int Function(Pointer<Utf16> name, int timeout);

typedef _PeekNamedPipeNative =
    IntPtr Function(
      IntPtr pipe,
      Pointer<Uint8> buffer,
      Uint32 size,
      Pointer<Uint32> bytesRead,
      Pointer<Uint32> totalAvailable,
      Pointer<Uint32> leftThisMessage,
    );
typedef _PeekNamedPipeDart =
    int Function(
      int pipe,
      Pointer<Uint8> buffer,
      int size,
      Pointer<Uint32> bytesRead,
      Pointer<Uint32> totalAvailable,
      Pointer<Uint32> leftThisMessage,
    );

typedef _ReadFileNative =
    IntPtr Function(
      IntPtr file,
      Pointer<Uint8> buffer,
      Uint32 count,
      Pointer<Uint32> read,
      Pointer<Void> overlapped,
    );
typedef _ReadFileDart =
    int Function(
      int file,
      Pointer<Uint8> buffer,
      int count,
      Pointer<Uint32> read,
      Pointer<Void> overlapped,
    );

typedef _WriteFileNative =
    IntPtr Function(
      IntPtr file,
      Pointer<Uint8> buffer,
      Uint32 count,
      Pointer<Uint32> written,
      Pointer<Void> overlapped,
    );
typedef _WriteFileDart =
    int Function(
      int file,
      Pointer<Uint8> buffer,
      int count,
      Pointer<Uint32> written,
      Pointer<Void> overlapped,
    );

typedef _CloseHandleNative = IntPtr Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

typedef _DuplicateHandleNative =
    IntPtr Function(
      IntPtr sourceProcess,
      IntPtr sourceHandle,
      IntPtr targetProcess,
      Pointer<IntPtr> targetHandle,
      Uint32 desiredAccess,
      Int32 inheritHandle,
      Uint32 options,
    );
typedef _DuplicateHandleDart =
    int Function(
      int sourceProcess,
      int sourceHandle,
      int targetProcess,
      Pointer<IntPtr> targetHandle,
      int desiredAccess,
      int inheritHandle,
      int options,
    );

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createFileW = _kernel32
    .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
final _waitNamedPipeW = _kernel32
    .lookupFunction<_WaitNamedPipeWNative, _WaitNamedPipeWDart>(
      'WaitNamedPipeW',
    );
final _peekNamedPipe = _kernel32
    .lookupFunction<_PeekNamedPipeNative, _PeekNamedPipeDart>('PeekNamedPipe');
final _readFile = _kernel32.lookupFunction<_ReadFileNative, _ReadFileDart>(
  'ReadFile',
);
final _writeFile = _kernel32.lookupFunction<_WriteFileNative, _WriteFileDart>(
  'WriteFile',
);
final _closeHandle = _kernel32
    .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
final _getLastError = _kernel32
    .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
final _getCurrentProcess = _kernel32
    .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
      'GetCurrentProcess',
    );
final _duplicateHandle = _kernel32
    .lookupFunction<_DuplicateHandleNative, _DuplicateHandleDart>(
      'DuplicateHandle',
    );

int _lastError() => _getLastError();
