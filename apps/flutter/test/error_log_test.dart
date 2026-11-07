import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/diagnostics/error_log.dart';

/// The error log exists for failures that produce no visible evidence, so the
/// important properties are that it lands somewhere findable and that it never
/// turns a diagnostic into a second failure.
void main() {
  test('writes the error and the stack to the data directory', () {
    final dir = Directory.systemTemp.createTempSync('halo_errlog');
    addTearDown(() => dir.deleteSync(recursive: true));

    final log = ErrorLog(dir.path);
    log.record(StateError('数据库不可用'), StackTrace.current, source: 'build');

    expect(log.path, isNotNull);
    final text = File(log.path!).readAsStringSync();
    expect(text, contains('[build] Bad state: 数据库不可用'));
    expect(text, contains('error_log_test.dart'));
  });

  test('falls back to the temp directory when the data directory is unusable',
      () {
    // A *file* where the directory should be, i.e. the store-failure case.
    final root = Directory.systemTemp.createTempSync('halo_errlog_blocked');
    addTearDown(() => root.deleteSync(recursive: true));
    final blocked = File('${root.path}${Platform.pathSeparator}blocked')
      ..writeAsStringSync('not a directory');

    final log = ErrorLog(blocked.path);
    log.record('boom', null, source: 'uncaught');

    expect(log.path, isNotNull);
    expect(log.path, startsWith(Directory.systemTemp.path));
    expect(File(log.path!).readAsStringSync(), contains('boom'));
  });

  test('collapses a repeating identical error', () {
    final dir = Directory.systemTemp.createTempSync('halo_errlog_dup');
    addTearDown(() => dir.deleteSync(recursive: true));

    final log = ErrorLog(dir.path);
    for (var i = 0; i < 50; i++) {
      log.record('same', null, source: 'build');
    }
    log.record('different', null, source: 'build');

    final text = File(log.path!).readAsStringSync();
    expect('same'.allMatches(text).length, 1);
    expect(text, contains('different'));
  });

  test('recording an error never throws, even with nowhere to write', () {
    // An empty preferred directory and a temp directory that cannot be
    // addressed as a child; the call must still return normally.
    final log = ErrorLog('');
    expect(() => log.record('x', null), returnsNormally);
  });
}
