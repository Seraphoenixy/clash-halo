/// Where the business database lives, resolved the same way the host does.
///
/// The CLI must be able to find the *same* file the UI and the host use, or it
/// would silently edit a database nobody reads. The host's `resolveDir`
/// (native/windows/cmd/halo-host/main.go) is the reference:
///
///   1. an explicit override (`--dir` here, `--dir` there)
///   2. `HALO_DATA_DIR`
///   3. `portable.flag` next to the executable -> `<exe dir>/user-data`
///   4. `%LOCALAPPDATA%\clash-halo`
library;

import 'dart:io';

/// The directory holding `clash-halo.db`, `configs/`, `logs/` and `runtime.json`.
String resolveDataDir({
  String? overrideDir,
  String? environmentOverride,
  String? resolvedExecutable,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (overrideDir != null && overrideDir.trim().isNotEmpty) {
    return _clean(overrideDir);
  }
  final fromEnv = environmentOverride ?? env['HALO_DATA_DIR'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) {
    return _clean(fromEnv);
  }
  final exe = resolvedExecutable ?? Platform.resolvedExecutable;
  final exeDir = File(exe).parent;
  if (File('${exeDir.path}${Platform.pathSeparator}portable.flag').existsSync()) {
    return '${exeDir.path}${Platform.pathSeparator}user-data';
  }
  final localAppData = env['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    return '$localAppData${Platform.pathSeparator}clash-halo';
  }
  // Falling back to the home path mirrors the host's last resort so a
  // non-Windows check still resolves somewhere predictable.
  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;
  return '$home${Platform.pathSeparator}.local${Platform.pathSeparator}clash-halo';
}

/// Absolute path of the SQLite file, or [dbPath] when the caller named one.
String resolveDbPath({String? dbPath, String dataDir = ''}) {
  if (dbPath != null && dbPath.trim().isNotEmpty) return _clean(dbPath);
  return '$dataDir${Platform.pathSeparator}clash-halo.db';
}

/// Expands `~` and normalises separators; a bare relative path is resolved
/// against the current directory so the resolved target can be printed.
String _clean(String path) {
  var value = path.trim();
  if (value == '~') {
    value = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        value;
  } else if (value.startsWith('~${Platform.pathSeparator}')) {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    value = '$home${value.substring(1)}';
  }
  return File(value).absolute.path;
}