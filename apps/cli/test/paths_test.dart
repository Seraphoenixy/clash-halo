import 'dart:io';

import 'package:halo_cli/halo_cli.dart';
import 'package:test/test.dart';

void main() {
  final sep = Platform.pathSeparator;

  test('--dir wins over the environment and the portable flag', () {
    final dir = resolveDataDir(
      overrideDir: '$sep' 'tmp${sep}explicit',
      environmentOverride: r'D:\env\dir',
      environment: {'HALO_DATA_DIR': r'D:\env\dir'},
      resolvedExecutable: '$sep' 'tmp${sep}app${sep}halo-cli.exe',
    );
    expect(dir, endsWith('explicit'));
  });

  test('HALO_DATA_DIR beats the portable flag and LOCALAPPDATA', () {
    final dir = resolveDataDir(
      environment: {
        'HALO_DATA_DIR': r'D:\env\dir',
        'LOCALAPPDATA': r'C:\Users\x\AppData\Local',
      },
      resolvedExecutable: '$sep' 'tmp${sep}app${sep}halo-cli.exe',
    );
    expect(dir, r'D:\env\dir');
  });

  test('the portable flag beside the executable selects user-data', () {
    final temp = Directory.systemTemp.createTempSync('halo-cli-paths-');
    addTearDown(() => temp.deleteSync(recursive: true));
    File('${temp.path}${sep}portable.flag').writeAsStringSync('');

    final dir = resolveDataDir(
      environment: {'LOCALAPPDATA': r'C:\Users\x\AppData\Local'},
      resolvedExecutable: '${temp.path}${sep}halo-cli.exe',
    );

    expect(dir, '${temp.path}${sep}user-data');
  });

  test('LOCALAPPDATA is the fallback, and the database sits inside it', () {
    final dir = resolveDataDir(
      environment: {'LOCALAPPDATA': r'C:\Users\x\AppData\Local'},
      resolvedExecutable: '$sep' 'tmp${sep}app${sep}halo-cli.exe',
    );
    expect(dir, r'C:\Users\x\AppData\Local\clash-halo');
    expect(resolveDbPath(dataDir: dir), '$dir${sep}clash-halo.db');
  });

  test('an explicit --db path is used verbatim', () {
    final computed = resolveDbPath(
      dbPath: 'somewhere${sep}custom.db',
      dataDir: r'C:\ignored',
    );
    expect(computed, endsWith('custom.db'));
    expect(computed, isNot(contains('ignored')));
  });
}