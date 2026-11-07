/// Versioned SQLite schema and migrations.
///
/// The database is the single authority for user business data. Only this
/// package opens it for writing; the Go host and Android native code never
/// touch it.
///
/// Migration policy: every version is a forward-only step that is safe to run
/// on an existing database. Before applying a migration the caller is expected
/// to have exported a backup (`StorageBackup.export`), so a failed upgrade is
/// always recoverable rather than silently lossy.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'local_profile.dart';

/// Current schema version. Bump together with a new case in [applyMigrations].
const int kSchemaVersion = 7;

/// Table and index names, kept in one place for backup/restore and tests.
abstract final class Tables {
  static const meta = 'meta';
  static const subscriptions = 'subscriptions';
  static const groups = 'subscription_groups';
  static const nodes = 'nodes';
  static const settings = 'settings';
  static const appliedConfig = 'applied_config';
  static const importLog = 'import_log';
}

/// Creates an empty schema at [kSchemaVersion].
void createSchema(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS ${Tables.meta} (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS ${Tables.subscriptions} (
      id             TEXT PRIMARY KEY,
      name           TEXT NOT NULL,
      url            TEXT NOT NULL,
      enabled        INTEGER NOT NULL DEFAULT 1,
      auto_update    INTEGER NOT NULL DEFAULT 0,
      interval_min   INTEGER NOT NULL DEFAULT 1440,
      last_updated   INTEGER NOT NULL DEFAULT 0,
      last_error     TEXT,
      node_count     INTEGER NOT NULL DEFAULT 0,
      etag           TEXT,
      created_at     INTEGER NOT NULL DEFAULT 0,
      sort_index     INTEGER NOT NULL DEFAULT 0,
      kind           TEXT NOT NULL DEFAULT 'remote',
      group_id       TEXT,
      use_proxy      INTEGER,
      proxy_url      TEXT
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS ${Tables.groups} (
      id          TEXT PRIMARY KEY,
      name        TEXT NOT NULL,
      sort_index  INTEGER NOT NULL DEFAULT 0,
      created_at  INTEGER NOT NULL DEFAULT 0
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS ${Tables.nodes} (
      id           TEXT PRIMARY KEY,
      fingerprint  TEXT NOT NULL,
      name         TEXT NOT NULL,
      protocol     TEXT NOT NULL,
      server       TEXT NOT NULL,
      port         INTEGER NOT NULL,
      secrets      TEXT NOT NULL DEFAULT '{}',
      transport    TEXT NOT NULL DEFAULT '{}',
      tls          TEXT NOT NULL DEFAULT '{}',
      source       TEXT NOT NULL DEFAULT 'manual',
      profile_id   TEXT,
      sort_index   INTEGER NOT NULL DEFAULT 0,
      created_at   INTEGER NOT NULL DEFAULT 0,
      updated_at   INTEGER NOT NULL DEFAULT 0,
      extras       TEXT NOT NULL DEFAULT '{}',
      FOREIGN KEY (profile_id) REFERENCES ${Tables.subscriptions}(id) ON DELETE SET NULL
    )
  ''');
  db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_fingerprint ON ${Tables.nodes}(fingerprint, COALESCE(profile_id, ''))");
  db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_profile ON ${Tables.nodes}(profile_id)');
  db.execute('CREATE INDEX IF NOT EXISTS idx_nodes_sort ON ${Tables.nodes}(sort_index)');
  db.execute('''
    CREATE TABLE IF NOT EXISTS ${Tables.settings} (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS ${Tables.appliedConfig} (
      version     INTEGER PRIMARY KEY,
      node_id     TEXT,
      node_name   TEXT,
      mode        TEXT NOT NULL,
      config_hash TEXT NOT NULL,
      payload     TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      rolled_back INTEGER NOT NULL DEFAULT 0
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS ${Tables.importLog} (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      at          INTEGER NOT NULL,
      source      TEXT NOT NULL,
      format      TEXT NOT NULL,
      imported    INTEGER NOT NULL,
      skipped     INTEGER NOT NULL,
      failed      INTEGER NOT NULL,
      detail      TEXT
    )
  ''');
  setMeta(db, 'schema_version', '$kSchemaVersion');
}

/// Adds a column only when the table does not have it yet, so a migration
/// step is idempotent even when the fresh-install script created the column.
void _addColumnIfMissing(
    Database db, String table, String column, String definition) {
  final info = db.select('PRAGMA table_info($table)');
  final has = info.any((row) => '${row['name']}' == column);
  if (!has) db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
}

/// Adds a schema version marker row, used to detect foreign/corrupt files.
void assertSchemaVersion(Database db) {
  final rows = db.select('SELECT value FROM ${Tables.meta} WHERE key = ?',
      ['schema_version']);
  if (rows.isEmpty) {
    throw StateError('数据库缺少版本标记，可能不是 clash-halo 数据库');
  }
  final version = int.tryParse('${rows.first['value']}');
  if (version == null) {
    throw StateError('数据库版本标记损坏');
  }
  if (version > kSchemaVersion) {
    throw StateError('数据库版本 $version 高于当前支持的 $kSchemaVersion，请升级应用');
  }
}

/// Applies forward migrations up to [kSchemaVersion].
///
/// Steps are written defensively (`IF NOT EXISTS`, backfill `UPDATE`) so a
/// partially applied migration can be re-run safely.
void applyMigrations(Database db) {
  db.execute('CREATE TABLE IF NOT EXISTS ${Tables.meta} (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  final existing = db.select('SELECT value FROM ${Tables.meta} WHERE key = ?', ['schema_version']);
  final from = existing.isEmpty ? 0 : (int.tryParse('${existing.first['value']}') ?? 0);
  if (from == 0) {
    createSchema(db);
    return;
  }
  if (from > kSchemaVersion) {
    throw StateError('数据库版本 $from 高于当前支持的 $kSchemaVersion');
  }
  for (var v = from + 1; v <= kSchemaVersion; v++) {
    switch (v) {
      case 1:
        createSchema(db);
      case 2:
        // v2: track subscription ETag and per-node updatedAt for change
        // detection during subscription refresh. A database created by the
        // v1 script may already carry these columns, so adding is conditional.
        _addColumnIfMissing(
            db, Tables.nodes, 'updated_at', 'INTEGER NOT NULL DEFAULT 0');
        _addColumnIfMissing(db, Tables.subscriptions, 'etag', 'TEXT');
      case 3:
        // v3: keep an audit trail of applied configs so a rollback is
        // explainable without relying on host-side files only.
        db.execute('''
          CREATE TABLE IF NOT EXISTS ${Tables.appliedConfig} (
            version     INTEGER PRIMARY KEY,
            node_id     TEXT,
            node_name   TEXT,
            mode        TEXT NOT NULL,
            config_hash TEXT NOT NULL,
            payload     TEXT NOT NULL,
            created_at  INTEGER NOT NULL,
            rolled_back INTEGER NOT NULL DEFAULT 0
          )
        ''');
      case 4:
        db.execute('DROP INDEX IF EXISTS idx_nodes_fingerprint');
        db.execute("CREATE UNIQUE INDEX idx_nodes_fingerprint ON ${Tables.nodes}(fingerprint, COALESCE(profile_id, ''))");
      case 5:
        // v5: repair rows written by the v2rayN importer before it knew that
        // `ConfigType` is not "the protocol in list order". Those rows disagree
        // with themselves: `extras.v2rayn.configType` says one protocol and
        // `protocol` says another. The stored row cannot be healed in place —
        // the old import also dropped the WebSocket path and host, and the
        // secret sat in the wrong field — so the only safe repair is to drop
        // the broken rows and let the user re-import, which now works. Rows
        // whose two halves agree are untouched, so a healthy database is a
        // no-op.
        _repairMisParsedV2rayNRows(db);
      case 6:
        // v6: subscription groups, per-profile proxy switch, and 本地 nodes as a
        // real subscription.
        //
        // Until now "local" meant `profile_id IS NULL`, so local nodes had no
        // row that could carry a name, a group or a proxy preference, and every
        // enumerator needed a special case. The backfill gives those nodes a
        // profile row and re-points them at it. It is written to be re-runnable:
        // the profile id is derived from the data directory-independent literal
        // below, and the UPDATE only touches rows that are still NULL.
        db.execute('''
          CREATE TABLE IF NOT EXISTS ${Tables.groups} (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            sort_index  INTEGER NOT NULL DEFAULT 0,
            created_at  INTEGER NOT NULL DEFAULT 0
          )
        ''');
        _addColumnIfMissing(
            db, Tables.subscriptions, 'kind', "TEXT NOT NULL DEFAULT 'remote'");
        _addColumnIfMissing(db, Tables.subscriptions, 'group_id', 'TEXT');
        _addColumnIfMissing(
            db, Tables.subscriptions, 'use_proxy', 'INTEGER NOT NULL DEFAULT 0');
        _addColumnIfMissing(db, Tables.subscriptions, 'proxy_url', 'TEXT');
        backfillLocalProfile(db);
      case 7:
        // v7: `use_proxy` becomes nullable, because the per-subscription proxy
        // switch is now tri-state: 1 = on, 0 = off, NULL = "no opinion, follow
        // the host policy". With NOT NULL the "no opinion" state was
        // indistinguishable from an explicit "off", so a host-based default
        // (GitHub sources prefer the proxy) could not be introduced without
        // silently overriding a user who had deliberately turned it off.
        //
        // SQLite cannot drop a NOT NULL constraint in place: the documented
        // approach is a new table plus a copy. The copy lists its columns
        // explicitly rather than using `SELECT *`, so this migration keeps
        // working even if a later version adds a column.
        _relaxUseProxyNullability(db);
      default:
        throw StateError('未知的迁移版本 $v');
    }
  }
  setMeta(db, 'schema_version', '$kSchemaVersion');
  db.execute('PRAGMA user_version = $kSchemaVersion');
}

/// Rebuilds `subscriptions` with a nullable `use_proxy`.
///
/// Re-runnable: it checks the current column definition and does nothing when
/// `use_proxy` already accepts NULL, so a migration interrupted between the
/// copy and the rename cannot leave the database unusable.
void _relaxUseProxyNullability(Database db) {
  final info = db.select('PRAGMA table_info(${Tables.subscriptions})');
  if (info.isEmpty) return; // no table yet: createSchema will build the new shape
  final useProxy = info.where((row) => '${row['name']}' == 'use_proxy').toList();
  if (useProxy.isEmpty) return;
  // `notnull` is 0 for a nullable column.
  final notNull = (useProxy.first['notnull'] as int? ?? 0) != 0;
  if (!notNull) return;

  const temp = 'subscriptions_v7';
  db.execute('DROP TABLE IF EXISTS $temp');
  db.execute('''
    CREATE TABLE $temp (
      id             TEXT PRIMARY KEY,
      name           TEXT NOT NULL,
      url            TEXT NOT NULL,
      enabled        INTEGER NOT NULL DEFAULT 1,
      auto_update    INTEGER NOT NULL DEFAULT 0,
      interval_min   INTEGER NOT NULL DEFAULT 1440,
      last_updated   INTEGER NOT NULL DEFAULT 0,
      last_error     TEXT,
      node_count     INTEGER NOT NULL DEFAULT 0,
      etag           TEXT,
      created_at     INTEGER NOT NULL DEFAULT 0,
      sort_index     INTEGER NOT NULL DEFAULT 0,
      kind           TEXT NOT NULL DEFAULT 'remote',
      group_id       TEXT,
      use_proxy      INTEGER,
      proxy_url      TEXT
    )
  ''');
  db.execute('''
    INSERT INTO $temp
      (id, name, url, enabled, auto_update, interval_min, last_updated,
       last_error, node_count, etag, created_at, sort_index, kind, group_id,
       use_proxy, proxy_url)
    SELECT
       id, name, url, enabled, auto_update, interval_min, last_updated,
       last_error, node_count, etag, created_at, sort_index, kind, group_id,
       use_proxy, proxy_url
    FROM ${Tables.subscriptions}
  ''');
  // `nodes.profile_id` references this table, so the swap has to happen with
  // foreign keys off; otherwise the DROP fails the constraint check.
  db.execute('PRAGMA foreign_keys = OFF');
  try {
    db.execute('DROP TABLE ${Tables.subscriptions}');
    db.execute('ALTER TABLE $temp RENAME TO ${Tables.subscriptions}');
  } finally {
    db.execute('PRAGMA foreign_keys = ON');
  }

  // Legacy rows carry `use_proxy = 0` because the old column was NOT NULL with
  // a 0 default — the value could not distinguish "the user turned it off" from
  // "never chosen". Treating all of them as explicit "off" would make the new
  // host policy dead code on every existing database.
  //
  // The signal that separates the two: `proxy_url` is only written when the
  // switch is turned on (`setUseProxy(..., proxyUrl: proxyEndpoint)`). So a row
  // with `use_proxy = 0` and no endpoint has never had the proxy enabled, and
  // its 0 is a default, not a decision. A row that was turned on and later off
  // keeps its endpoint, and stays an explicit off.
  db.execute('''
    UPDATE ${Tables.subscriptions}
       SET use_proxy = NULL
     WHERE use_proxy = 0 AND proxy_url IS NULL
  ''');
}

/// The v2rayN `EConfigType` numbers whose meaning the importer once got wrong.
///
/// Kept here rather than imported from the domain package so this migration
/// stays a statement about *stored data*: it must keep meaning the same thing
/// even if the importer's table changes again. Only the types that were
/// actually misread are listed, so an untouched database loses nothing.
const Map<int, String> _kMisParsedConfigTypes = {
  5: 'vless', // read as trojan
  6: 'trojan', // was skipped as an HTTP proxy
  7: 'hysteria2', // read as wireguard
  10: 'http',
  12: 'naive',
  1: 'vmess',
  3: 'shadowsocks',
  4: 'socks',
};

/// Deletes nodes where the stored `configType` and the stored `protocol`
/// contradict each other.
///
/// A row that is internally consistent is kept even if it was imported by the
/// old code, because it may simply be correct; only a row that says two
/// different things is provably broken. The repair is a delete rather than an
/// in-place rewrite because the old importer also lost the transport path/host
/// and put the UUID in the password field, so a patched row would still not
/// connect — and re-importing from v2rayN now produces a complete row.
int _repairMisParsedV2rayNRows(Database db) {
  final rows = db.select(
    'SELECT id, protocol, extras FROM ${Tables.nodes} '
    "WHERE extras IS NOT NULL AND extras <> ''",
  );
  final broken = <String>[];
  for (final row in rows) {
    final extras = row['extras'];
    if (extras is! String || extras.isEmpty) continue;
    final configType = _configTypeOf(extras);
    if (configType == null) continue;
    final expected = _kMisParsedConfigTypes[configType];
    if (expected == null) continue;
    if ('${row['protocol']}' != expected) broken.add('${row['id']}');
  }
  for (final id in broken) {
    db.execute('DELETE FROM ${Tables.nodes} WHERE id = ?', [id]);
  }
  if (broken.isNotEmpty) {
    // Recorded so the UI can tell the user why a node vanished instead of
    // leaving them to wonder.
    setMeta(db, SettingKeys.repairedNodes, '${broken.length}');
  }
  return broken.length;
}

/// Reads `configType` out of a node's `extras.v2rayn` object without pulling in
/// the domain model: this runs during schema migration, before repositories.
int? _configTypeOf(String extrasJson) {
  try {
    final decoded = jsonDecode(extrasJson);
    if (decoded is! Map) return null;
    final v2rayn = decoded['v2rayn'];
    if (v2rayn is! Map) return null;
    final value = v2rayn['configType'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  } catch (_) {
    // Unparseable extras are not evidence of corruption; leave the row alone.
    return null;
  }
}

String? metaOf(Database db, String key) {  final rows = db.select('SELECT value FROM ${Tables.meta} WHERE key = ?', [key]);
  return rows.isEmpty ? null : '${rows.first['value']}';
}

void setMeta(Database db, String key, String value) {
  db.execute(
    'INSERT INTO ${Tables.meta}(key, value) VALUES(?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, value],
  );
}

void deleteMeta(Database db, String key) {
  db.execute('DELETE FROM ${Tables.meta} WHERE key = ?', [key]);
}

/// Setting keys with defined semantics. Everything else is stored as a
/// string-keyed JSON value so callers can extend without a migration.
abstract final class SettingKeys {
  static const themeMode = 'ui.themeMode';
  static const lastSelectedNode = 'ui.lastSelectedNode';
  static const proxyMode = 'core.proxyMode';
  static const systemProxy = 'system.proxyEnabled';
  static const autoLaunch = 'app.autoLaunch';
  static const autoUpdateSubscriptions = 'sub.autoUpdate';
  static const speedTestConcurrency = 'speed.concurrency';
  static const logLimitBytes = 'log.limitBytes';
  static const language = 'ui.language';

  /// How many nodes migration v5 removed because their stored protocol and
  /// stored v2rayN `configType` disagreed. Read once by the UI so the removal is
  /// explained rather than mysterious.
  static const repairedNodes = 'db.repairedNodes';
}
