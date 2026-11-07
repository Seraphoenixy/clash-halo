/// Database handle, connection policy, and corruption guard.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Result of opening a store.
class StoreOpenResult {
  const StoreOpenResult({this.store, this.error});

  final HaloStore? store;
  final String? error;

  bool get ok => store != null;
}

/// Owns the SQLite connection and applies the schema.
class HaloStore {
  HaloStore._(this.db, this.path);

  final Database db;
  final String path;

  /// Opens (creating if needed) the business database at [dbPath].
  ///
  /// A file that fails to open or fails the version guard is quarantined
  /// beside the original instead of being deleted, so the user can still
  /// recover it manually.
  static StoreOpenResult open(String dbPath) {
    final file = File(dbPath);
    try {
      file.parent.createSync(recursive: true);
      final db = sqlite3.open(dbPath);
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA synchronous = NORMAL');
      try {
        if (_hasMetaTable(db)) {
          assertSchemaVersion(db);
          applyMigrations(db);
        } else if (_isEmptyDatabase(db)) {
          createSchema(db);
          db.execute('PRAGMA user_version = $kSchemaVersion');
        } else {
          throw StateError('数据库中缺少版本表，可能不是 clash-halo 数据库');
        }
      } on StateError catch (e) {
        db.close();
        final moved = _quarantine(file);
        return StoreOpenResult(
            error: '${e.message}${moved == null ? '' : '（原文件已保留为 $moved）'}');
      }
      return StoreOpenResult(store: HaloStore._(db, dbPath));
    } catch (e) {
      return StoreOpenResult(error: '无法打开数据库: $e');
    }
  }

  static bool _hasMetaTable(Database db) {
    final rows = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [Tables.meta]);
    return rows.isNotEmpty;
  }

  static bool _isEmptyDatabase(Database db) {
    final rows = db.select("SELECT name FROM sqlite_master WHERE type = 'table'");
    return rows.isEmpty;
  }

  static String? _quarantine(File file) {
    if (!file.existsSync()) return null;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = '${file.path}.broken-$stamp';
    try {
      file.renameSync(target);
    } catch (_) {
      return null;
    }
    return target.split(Platform.pathSeparator).last;
  }

  /// Runs [action] in a transaction, rolling back on any thrown error.
  int _transactionId = 0;
  T transaction<T>(T Function(Database db) action) {
    final savepoint = 'halo_${_transactionId++}';
    db.execute('SAVEPOINT $savepoint');
    try {
      final result = action(db);
      db.execute('RELEASE SAVEPOINT $savepoint');
      return result;
    } catch (_) {
      db.execute('ROLLBACK TO SAVEPOINT $savepoint');
      db.execute('RELEASE SAVEPOINT $savepoint');
      rethrow;
    }
  }

  /// Full integrity check used after restore and before backup.
  List<String> integrityIssues() {
    final rows = db.select('PRAGMA integrity_check');
    return [
      for (final row in rows)
        if ('${row.values.first}'.toLowerCase() != 'ok') '${row.values.first}',
    ];
  }

  /// Counts rows per business table, for the restore preview.
  Map<String, int> tableCounts() {
    final counts = <String, int>{};
    for (final table in [
      Tables.nodes,
      Tables.subscriptions,
      Tables.groups,
      Tables.settings,
      Tables.importLog,
      Tables.appliedConfig,
    ]) {
      final rows = db.select('SELECT COUNT(*) AS c FROM $table');
      counts[table] = (rows.first['c'] as int?) ?? 0;
    }
    return counts;
  }

  void close() {
    db.close();
  }
}
