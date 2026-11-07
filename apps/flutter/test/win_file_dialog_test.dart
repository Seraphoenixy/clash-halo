import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/platform/win_file_dialog.dart';

// The native call itself cannot be tested here (it needs a real window and a
// human), so the parts that can silently corrupt a path are pinned: the filter
// layout, the flags, and reading the answer back out of the buffer.
void main() {
  group('filter buffer', () {
    test('is pairs of "label\\0pattern\\0" with one extra terminator', () {
      final buffer = buildFilterBuffer(const [
        (label: '备份 (*.chb)', pattern: '*.chb'),
        (label: '所有文件 (*.*)', pattern: '*.*'),
      ]);
      final text = String.fromCharCodes(buffer);
      // Each entry ends in \0 and the whole list ends in one more \0: without
      // it the dialog reads past the buffer, and a single \0 between entries
      // would collapse them into one filter.
      expect(text, '备份 (*.chb)\u0000*.chb\u0000所有文件 (*.*)\u0000*.*\u0000\u0000');
      // The buffer has to end with exactly one extra NUL after the last pair.
      expect(buffer[buffer.length - 1], 0);
      expect(buffer[buffer.length - 2], 0);
      expect(buffer[buffer.length - 3], '*'.codeUnitAt(0));
    });

    test('a single filter still terminates correctly', () {
      final buffer = buildFilterBuffer(const [
        (label: '备份', pattern: '*.chb'),
      ]);
      expect(String.fromCharCodes(buffer), '备份\u0000*.chb\u0000\u0000');
    });
  });

  group('flags', () {
    test('keeps NoChangeDir', () {
      // The dialog changes the process working directory unless this bit is
      // set. The core log path is relative (`log.output` is `halo-core.log`
      // written with the data directory as the working directory), so losing
      // this bit moves the kernel log for the rest of the session.
      expect(OpenFileFlags.value & OpenFileFlags.noChangeDir, isNonZero);
      expect(OpenFileFlags.value & OpenFileFlags.fileMustExist, isNonZero);
      expect(OpenFileFlags.value & OpenFileFlags.pathMustExist, isNonZero);
      // The modern-looking dialog, not the Windows 3.1 one.
      expect(OpenFileFlags.value & OpenFileFlags.explorer, isNonZero);
    });
  });

  group('reading the answer', () {
    Uint16List bufferFor(String? text) {
      final out = Uint16List(64);
      if (text != null) {
        final units = text.codeUnits;
        out.setAll(0, units);
      }
      return out;
    }

    test('returns the path up to the first NUL', () {
      expect(
        readPathFromBuffer(bufferFor(r'C:\Users\x\AppData\Local\clash-halo\a.chb')),
        r'C:\Users\x\AppData\Local\clash-halo\a.chb',
      );
    });

    test('stops at the terminator instead of reading a stale tail', () {
      // The dialog writes the path plus a NUL and leaves whatever was in the
      // buffer before it. Reading the whole buffer would append garbage from a
      // longer previous selection.
      final buffer = bufferFor(r'C:\a.chb');
      expect(buffer[8], 0, reason: '路径必须以 NUL 结尾'); // the terminator
      buffer[12] = 'X'.codeUnitAt(0); // junk past the terminator
      expect(readPathFromBuffer(buffer), r'C:\a.chb');
    });

    test('a cancelled dialog (all zeros) is null, not an empty path', () {
      expect(readPathFromBuffer(Uint16List(64)), isNull);
      expect(readPathFromBuffer(Uint16List(1)), isNull);
    });

    test('a path is not truncated by a non-ASCII character', () {
      const path = r'C:\Users\用户\备份\a.chb';
      expect(readPathFromBuffer(bufferFor(path)), path);
    });
  });
}
