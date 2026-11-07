import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:halo/src/ipc/win_pipe.dart';
import 'package:test/test.dart';

/// Handle ownership is the part of [WindowsPipe] that can be pinned without a
/// running halo-host.
///
/// The named-pipe server side cannot be stood up from a unit test, so
/// `connect` and a live host are not covered here. What is covered is who
/// closes what: real anonymous-pipe handles from kernel32 go through the same
/// `DuplicateHandle`/`CloseHandle` paths the reader isolate uses, and closing
/// the wrong one is exactly the reconnect bug.
typedef _CreatePipeNative =
    IntPtr Function(
      Pointer<IntPtr> read,
      Pointer<IntPtr> write,
      Pointer<Void> attributes,
      Uint32 size,
    );
typedef _CreatePipeDart =
    int Function(
      Pointer<IntPtr> read,
      Pointer<IntPtr> write,
      Pointer<Void> attributes,
      int size,
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

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _createPipeFn = _kernel32
    .lookupFunction<_CreatePipeNative, _CreatePipeDart>('CreatePipe');
final _writeFile = _kernel32.lookupFunction<_WriteFileNative, _WriteFileDart>(
  'WriteFile',
);
final _closeHandle = _kernel32
    .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
final _getLastError = _kernel32
    .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');

void main() {
  // These tests bind kernel32 directly instead of going through WindowsPipe,
  // so on another OS the lookup would fail rather than skip.
  final skip = Platform.isWindows ? null : '需要 kernel32（Windows）';

  group('handle ownership', () {
    test('duplicate() owns a handle the UI can close independently', () {
      final pipe = _createPipe();
      final ui = WindowsPipe.fromHandle(pipe.read);
      final reader = ui.duplicate();
      try {
        expect(reader.handle, isNotNull);
        expect(
          reader.handle,
          isNot(ui.handle),
          reason: '两个包装器必须各自持有一个句柄值：共用一个值时第一次 '
              'CloseHandle 会把值还给操作系统，第二次就会关掉下一个连接',
        );

        // The UI side drops its pipe while the reader still owns its copy.
        ui.close();
        _writeBytes(pipe.write, const [1, 2, 3]);

        // Reading through the duplicate proves it stayed valid. If both
        // wrappers had shared one value, the close above would have freed it
        // and ReadFile would fail on an invalid handle.
        final chunk = _readAvailable(reader);
        expect(chunk, isNotNull, reason: '复制出的句柄必须仍然可读');
        expect(chunk, orderedEquals(const [1, 2, 3]));
      } finally {
        reader.close();
        _close(pipe.write);
      }
    });

    test('a borrowing wrapper never closes the handle it reads', () {
      final pipe = _createPipe();
      // This is the reader isolate's side: it uses the handle but does not own
      // it, because immediate isolate termination cannot be relied on to run a
      // finalizer that would release it.
      final borrowed = WindowsPipe.fromHandle(pipe.read, ownsHandle: false);
      final owner = WindowsPipe.fromHandle(pipe.read);
      try {
        borrowed.close();
        expect(borrowed.isOpen, isFalse);

        // Had close() called CloseHandle, this value would now be invalid and
        // the bytes would never arrive.
        _writeBytes(pipe.write, const [9, 8]);
        final chunk = _readAvailable(owner);
        expect(chunk, orderedEquals(const [9, 8]));
      } finally {
        owner.close();
        _close(pipe.write);
      }
    });

    test('duplicate() refuses a pipe that is already closed', () {
      // Borrowing wrapper over a value that is never a real handle: close()
      // only forgets it, so nothing is released.
      final pipe = WindowsPipe.fromHandle(0x7FFF, ownsHandle: false)..close();
      expect(() => pipe.duplicate(), throwsA(isA<WindowsPipeException>()));
    });
  }, skip: skip);
}

/// Creates an anonymous pipe and returns both ends as raw handle values.
({int read, int write}) _createPipe() {
  final read = calloc<IntPtr>();
  final write = calloc<IntPtr>();
  try {
    final ok = _createPipeFn(read, write, nullptr, 0);
    if (ok == 0) fail('CreatePipe 失败（错误 $_lastError）');
    return (read: read.value, write: write.value);
  } finally {
    calloc.free(read);
    calloc.free(write);
  }
}

void _writeBytes(int handle, List<int> bytes) {
  final buffer = calloc<Uint8>(bytes.length);
  final written = calloc<Uint32>();
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    final ok = _writeFile(handle, buffer, bytes.length, written, nullptr);
    if (ok == 0) fail('WriteFile 失败（错误 $_lastError）');
  } finally {
    calloc.free(buffer);
    calloc.free(written);
  }
}

/// Reads the bytes already in the pipe, retrying briefly so a scheduling
/// hiccup cannot make the test flaky.
Uint8List? _readAvailable(WindowsPipe pipe) {
  for (var attempt = 0; attempt < 100; attempt++) {
    final chunk = pipe.read();
    if (chunk.isNotEmpty) return chunk;
  }
  return null;
}

void _close(int handle) {
  _closeHandle(handle);
}

int get _lastError => _getLastError();
