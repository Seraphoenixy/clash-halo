/// Node and subscription repositories.
library;

import 'dart:convert';

import 'package:halo_contracts/halo_contracts.dart' show kProtocolVersion;
import 'package:halo_domain/halo_domain.dart';
import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';
import 'local_profile.dart';
import 'store.dart';

/// Persistence boundary for proxy nodes.
class NodeRepository {
  NodeRepository(this._store);

  final HaloStore _store;

  Database get _db => _store.db;

  /// All nodes in display order.
  List<ProxyNode> allNodes() {
    final rows = _db.select(
        'SELECT * FROM ${Tables.nodes} ORDER BY sort_index ASC, created_at ASC, id ASC');
    return rows.map(_rowToNode).toList();
  }

  ProxyNode? nodeById(String id) {
    final rows = _db.select('SELECT * FROM ${Tables.nodes} WHERE id = ?', [id]);
    return rows.isEmpty ? null : _rowToNode(rows.first);
  }

  List<ProxyNode> nodesForProfile(String profileId) {
    final rows = _db.select(
        'SELECT * FROM ${Tables.nodes} WHERE profile_id = ? '
        'ORDER BY sort_index ASC, created_at ASC',
        [profileId]);
    return rows.map(_rowToNode).toList();
  }

  /// Inserts a node. Nodes are identity-unique: an insert that collides with
  /// an existing fingerprint updates that row instead of creating a duplicate,
  /// which is what keeps re-imports from doubling the list.
  ///
  /// Returns the stored node.
  ProxyNode insert(ProxyNode node, {required int nowMs}) {
    return insertAll([node], nowMs: nowMs).single;
  }

  /// Inserts [nodes] in one transaction with one identity prefetch for the
  /// whole batch.
  ///
  /// The per-node [insert] runs a fingerprint SELECT and its own implicit
  /// commit per row, so pasting a 5000-node list paid ~10k statements and 5000
  /// journal fsyncs on the UI isolate. Prefetching the (fingerprint, profile)
  /// collisions once and writing the batch inside a single savepoint turns
  /// that into one statement per node and one commit.
  List<ProxyNode> insertAll(List<ProxyNode> nodes, {required int nowMs}) {
    if (nodes.isEmpty) return const <ProxyNode>[];
    return _store.transaction((db) {
      // A node with no profile is a node imported locally, and since v6 the
      // local list *is* a subscription. Adopting here rather than at each caller
      // keeps that invariant in one place: the UI's paste box, the CLI's
      // `import` and a backup restore all pass through this method, so none of
      // them can create the orphan rows the migration just cleaned up.
      final adoptsLocal = nodes.any((n) => n.profileId == null);
      if (adoptsLocal) SubscriptionRepository(_store).ensureLocalProfile(nowMs: nowMs);
      final incoming = adoptsLocal
          ? [
              for (final node in nodes)
                node.profileId == null
                    ? node.copyWith(
                        profileId: kLocalProfileId,
                        source: NodeSourceKind.subscription,
                      )
                    : node,
            ]
          : nodes;
      // Group fingerprints by their target profile so one query per profile
      // covers the whole batch.
      final fingerprintsByProfile = <String?, Set<String>>{};
      for (final node in incoming) {
        if (node.fingerprint.isEmpty) continue;
        fingerprintsByProfile
            .putIfAbsent(node.profileId, () => <String>{})
            .add(node.fingerprint);
      }
      final existing = <(String?, String), ProxyNode>{};
      for (final entry in fingerprintsByProfile.entries) {
        final fps = entry.value.toList();
        final placeholders = List.filled(fps.length, '?').join(', ');
        final rows = db.select(
          'SELECT * FROM ${Tables.nodes} '
          'WHERE fingerprint IN ($placeholders) AND profile_id IS ?',
          [...fps, entry.key],
        );
        for (final row in rows) {
          existing[(
            row['profile_id'] as String?,
            '${row['fingerprint']}',
          )] = _rowToNode(row);
        }
      }
      final out = <ProxyNode>[];
      for (final node in incoming) {
        final hit = existing[(node.profileId, node.fingerprint)];
        if (hit != null) {
          final stored = node.copyWith(
            id: hit.id,
            sortIndex: hit.sortIndex,
            createdAtMs: hit.createdAtMs,
            updatedAtMs: nowMs,
          );
          _write(stored, replacingId: hit.id);
          out.add(stored);
          continue;
        }
        final stored = node.copyWith(
          id: node.id.isEmpty ? 'n_${node.fingerprint}' : node.id,
          createdAtMs: node.createdAtMs == 0 ? nowMs : node.createdAtMs,
          updatedAtMs: nowMs,
        );
        _write(stored);
        out.add(stored);
      }
      if (adoptsLocal) {
        db.execute(
          'UPDATE ${Tables.subscriptions} SET node_count = '
          '(SELECT COUNT(*) FROM ${Tables.nodes} WHERE profile_id = ?) WHERE id = ?',
          [kLocalProfileId, kLocalProfileId],
        );
      }
      return out;
    });
  }

  void _write(ProxyNode node, {String? replacingId}) {
    final id = replacingId ?? node.id;
    _db.execute(
      '''
      INSERT INTO ${Tables.nodes}
        (id, fingerprint, name, protocol, server, port, secrets, transport, tls,
         source, profile_id, sort_index, created_at, updated_at, extras)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        fingerprint = excluded.fingerprint,
        name = excluded.name,
        protocol = excluded.protocol,
        server = excluded.server,
        port = excluded.port,
        secrets = excluded.secrets,
        transport = excluded.transport,
        tls = excluded.tls,
        source = excluded.source,
        profile_id = excluded.profile_id,
        sort_index = excluded.sort_index,
        updated_at = excluded.updated_at,
        extras = excluded.extras
      ''',
      [
        id,
        node.fingerprint,
        node.name,
        node.protocol.wire,
        node.server,
        node.port,
        jsonEncode(node.secrets.toJson()),
        jsonEncode(node.transport.toJson()),
        jsonEncode(node.tls.toJson()),
        node.source.wire,
        node.profileId,
        node.sortIndex,
        node.createdAtMs,
        node.updatedAtMs,
        jsonEncode(node.extras),
      ],
    );
  }

  /// Replaces every node belonging to [profileId] in one transaction. Used by
  /// subscription updates: a failed download never reaches this call, so the
  /// previous content survives.
  ///
  /// [keepNames] preserves locally renamed nodes by fingerprint, because
  /// subscription priority overrides local connection edits but a display
  /// rename is not a connection edit.
  List<ProxyNode> replaceProfileNodes(
    String profileId,
    List<ProxyNode> nodes, {
    required int nowMs,
    bool keepNames = false,
  }) {
    return _store.transaction((db) {
      // The previous-name lookup costs a full table read plus four JSON
      // decodes per row; the only caller leaves [keepNames] false, so the map
      // is built only when a caller actually asks for it, and always before
      // the rows are deleted.
      final Map<String, ProxyNode> previous = keepNames
          ? {for (final n in nodesForProfile(profileId)) n.fingerprint: n}
          : const {};
      db.execute('DELETE FROM ${Tables.nodes} WHERE profile_id = ?', [profileId]);
      final out = <ProxyNode>[];
      for (var i = 0; i < nodes.length; i++) {
        final node = nodes[i];
        final prior = keepNames ? previous[node.fingerprint] : null;
        final prepared = withIdentity(node.copyWith(
          id: '',
          profileId: profileId,
          source: NodeSourceKind.subscription,
          sortIndex: i,
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
          name: prior?.name ?? node.name,
        )).copyWith(id: 'sub_${profileId}_${node.fingerprint}');
        _write(prepared);
        out.add(prepared);
      }
      return out;
    });
  }

  void deleteNodes(Iterable<String> ids) {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    _db.execute('DELETE FROM ${Tables.nodes} WHERE id IN ($placeholders)', ids.toList());
  }

  /// Re-applies a batch rename payload.
  void renameNodes(Map<String, String> names, {required int nowMs}) {
    if (names.isEmpty) return;
    _store.transaction((db) {
      for (final entry in names.entries) {
        db.execute(
            'UPDATE ${Tables.nodes} SET name = ?, updated_at = ? WHERE id = ?',
            [entry.value, nowMs, entry.key]);
      }
    });
  }

  /// Re-applies explicit ordering.
  void reorderNodes(List<String> orderedIds) {
    if (orderedIds.isEmpty) return;
    _store.transaction((db) {
      for (var i = 0; i < orderedIds.length; i++) {
        db.execute('UPDATE ${Tables.nodes} SET sort_index = ? WHERE id = ?',
            [i, orderedIds[i]]);
      }
    });
  }

  /// Updates a single node's full row, e.g. after a manual edit.
  void update(ProxyNode node, {required int nowMs}) {
    _write(node.copyWith(updatedAtMs: nowMs));
  }

  ProxyNode _rowToNode(Row row) {
    final protocol = ProxyProtocol.fromWire('${row['protocol']}');
    if (protocol == null) {
      throw StateError('数据库中节点 ${row['id']} 的协议无法识别: ${row['protocol']}');
    }
    return ProxyNode(
      id: '${row['id']}',
      fingerprint: '${row['fingerprint']}',
      name: '${row['name']}',
      protocol: protocol,
      server: '${row['server']}',
      port: row['port'] as int,
      secrets: NodeSecrets.fromJson(_jsonMap(row['secrets'])),
      transport: TransportConfig.fromJson(_jsonMap(row['transport'])),
      tls: TlsConfig.fromJson(_jsonMap(row['tls'])),
      source: NodeSourceKind.fromWire('${row['source']}'),
      profileId: row['profile_id'] as String?,
      sortIndex: row['sort_index'] as int? ?? 0,
      createdAtMs: row['created_at'] as int? ?? 0,
      updatedAtMs: row['updated_at'] as int? ?? 0,
      extras: _jsonMap(row['extras']),
    );
  }
}

Map<String, Object?> _jsonMap(Object? raw) {
  if (raw is Map) return raw.cast<String, Object?>();
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {
      // One unreadable column must not take the whole node list down: a
      // malformed `secrets`/`extras` value would otherwise throw out of
      // `allNodes` and leave the user with an empty, unexplained table. Treat
      // the column as absent so the rest of the row still loads.
    }
  }
  return const {};
}

/// Persistence boundary for subscription profiles.
class SubscriptionRepository {
  SubscriptionRepository(this._store);

  final HaloStore _store;

  Database get _db => _store.db;

  List<SubscriptionProfile> allProfiles() {
    final rows = _db.select(
        'SELECT * FROM ${Tables.subscriptions} ORDER BY sort_index ASC, created_at ASC');
    return rows.map(_rowToProfile).toList();
  }

  SubscriptionProfile? profileById(String id) {
    final rows = _db.select('SELECT * FROM ${Tables.subscriptions} WHERE id = ?', [id]);
    return rows.isEmpty ? null : _rowToProfile(rows.first);
  }

  void upsert(SubscriptionProfile profile) {
    _db.execute(
      '''
      INSERT INTO ${Tables.subscriptions}
        (id, name, url, enabled, auto_update, interval_min, last_updated,
         last_error, node_count, etag, created_at, sort_index, kind, group_id,
         use_proxy, proxy_url)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        url = excluded.url,
        enabled = excluded.enabled,
        auto_update = excluded.auto_update,
        interval_min = excluded.interval_min,
        last_updated = excluded.last_updated,
        last_error = excluded.last_error,
        node_count = excluded.node_count,
        etag = excluded.etag,
        sort_index = excluded.sort_index,
        kind = excluded.kind,
        group_id = excluded.group_id,
        use_proxy = excluded.use_proxy,
        proxy_url = excluded.proxy_url
      ''',
      [
        profile.id,
        profile.name,
        profile.url,
        profile.enabled ? 1 : 0,
        profile.autoUpdate ? 1 : 0,
        profile.updateIntervalMinutes,
        profile.lastUpdatedAtMs,
        profile.lastError,
        profile.nodeCount,
        profile.etag,
        profile.createdAtMs,
        profile.sortIndex,
        profile.kind.wire,
        profile.groupId,
        switch (profile.useProxy) {
          null => null,
          false => 0,
          true => 1,
        },
        profile.proxyUrl,
      ],
    );
  }

  /// Deletes a profile. Its nodes are kept: the plan requires that removing a
  /// subscription never silently breaks the active connection, so nodes outlive
  /// the profile. They move to the built-in 本地 subscription rather than to a
  /// NULL profile, because since v6 "no profile" is no longer a state a node can
  /// be in — every node belongs to exactly one source.
  ///
  /// The built-in 本地 profile itself is not deletable; [deleteProfile] is a
  /// no-op for it so a caller cannot strand the local nodes.
  void deleteProfile(String id) {
    if (id == kLocalProfileId) return;
    // The nodes are about to point at 本地, and `nodes.profile_id` is a foreign
    // key: the target row has to exist *before* the UPDATE, or the delete fails
    // with a constraint error on a database that never had local nodes.
    ensureLocalProfile(nowMs: DateTime.now().millisecondsSinceEpoch);
    _store.transaction((db) {
      db.execute(
        'UPDATE ${Tables.nodes} SET profile_id = ?, source = ? WHERE profile_id = ?',
        [kLocalProfileId, NodeSourceKind.subscription.wire, id],
      );
      db.execute('DELETE FROM ${Tables.subscriptions} WHERE id = ?', [id]);
      db.execute(
        'UPDATE ${Tables.subscriptions} SET node_count = '
        '(SELECT COUNT(*) FROM ${Tables.nodes} WHERE profile_id = ?) WHERE id = ?',
        [kLocalProfileId, kLocalProfileId],
      );
    });
  }

  /// Deletes a profile and every node it owns.
  ///
  /// The explicit "yes, take its nodes too" answer, which the UI offers as a
  /// choice: dropping a dead airport should clear its nodes, while re-adding a
  /// link later should not lose nodes the user already tested.
  void deleteProfileWithNodes(String id) {
    if (id == kLocalProfileId) return;
    _store.transaction((db) {
      db.execute('DELETE FROM ${Tables.nodes} WHERE profile_id = ?', [id]);
      db.execute('DELETE FROM ${Tables.subscriptions} WHERE id = ?', [id]);
    });
  }

  /// The built-in 本地 profile, created on demand.
  ///
  /// The v6 migration creates it for databases that had local nodes, but a
  /// fresh database has no reason to show an empty 本地 subscription until
  /// something is actually imported there.
  SubscriptionProfile ensureLocalProfile({required int nowMs}) {
    final existing = profileById(kLocalProfileId);
    if (existing != null) return existing;
    final profile = SubscriptionProfile(
      id: kLocalProfileId,
      name: kLocalProfileName,
      url: '',
      kind: SubscriptionKind.local,
      createdAtMs: nowMs,
      sortIndex: 0,
    );
    upsert(profile);
    return profile;
  }

  /// Only the profiles that a refresh can actually fetch.
  List<SubscriptionProfile> remoteProfiles() =>
      allProfiles().where((p) => p.isRemote).toList();

  /// Sets the per-profile switch. `null` stores "no choice", which is what the
  /// host policy then fills in.
  void setUseProxy(String id, bool? useProxy, {String? proxyUrl}) {
    _db.execute(
      'UPDATE ${Tables.subscriptions} SET use_proxy = ?, '
      'proxy_url = COALESCE(?, proxy_url) WHERE id = ?',
      [
        switch (useProxy) {
          null => null,
          false => 0,
          true => 1,
        },
        proxyUrl,
        id,
      ],
    );
  }

  /// Files [id] under [groupId] (null = ungrouped).
  void setGroup(String id, String? groupId) {
    _db.execute(
      'UPDATE ${Tables.subscriptions} SET group_id = ? WHERE id = ?',
      [groupId, id],
    );
  }

  /// Records a successful refresh.
  void markUpdated(
      String id, {
      required int atMs,
      required int nodeCount,
      String? etag,
    }) {
    _db.execute(
      'UPDATE ${Tables.subscriptions} SET last_updated = ?, last_error = NULL, '
      'node_count = ?, etag = COALESCE(?, etag) WHERE id = ?',
      [atMs, nodeCount, etag, id],
    );
  }

  /// Records a failed refresh, keeping the previous nodes untouched.
  void markFailed(String id, {required int atMs, required String error}) {
    _db.execute(
      'UPDATE ${Tables.subscriptions} SET last_error = ?, last_updated = last_updated '
      'WHERE id = ?',
      [_truncate(error), id],
    );
  }

  SubscriptionProfile _rowToProfile(Row row) => SubscriptionProfile(
        id: '${row['id']}',
        name: '${row['name']}',
        url: '${row['url']}',
        enabled: (row['enabled'] as int? ?? 1) != 0,
        autoUpdate: (row['auto_update'] as int? ?? 0) != 0,
        updateIntervalMinutes: row['interval_min'] as int? ?? 1440,
        lastUpdatedAtMs: row['last_updated'] as int? ?? 0,
        lastError: row['last_error'] as String?,
        nodeCount: row['node_count'] as int? ?? 0,
        etag: row['etag'] as String?,
        createdAtMs: row['created_at'] as int? ?? 0,
        sortIndex: row['sort_index'] as int? ?? 0,
        kind: SubscriptionKind.fromWire(row['kind'] as String?),
        groupId: row['group_id'] as String?,
        // NULL is "never chosen"; 0 and 1 are explicit. Reading NULL as false
        // would turn "no opinion" into "user said direct".
        useProxy: switch (row['use_proxy'] as int?) {
          null => null,
          0 => false,
          _ => true,
        },
        proxyUrl: row['proxy_url'] as String?,
      );
}

/// Persistence for subscription groups.
///
/// A group is only a name and an order; membership lives on the profile row so
/// there is one fact, not two that can disagree. That also means deleting a group
/// is a single UPDATE that cannot leave a dangling id behind, which is why
/// [deleteGroup] clears memberships itself instead of relying on a foreign key
/// (the schema has no FK on `group_id`, because a partial migration must not
/// fail on pre-existing rows).
class SubscriptionGroupRepository {
  SubscriptionGroupRepository(this._store);

  final HaloStore _store;

  Database get _db => _store.db;

  List<SubscriptionGroup> allGroups() {
    final rows = _db.select(
      'SELECT * FROM ${Tables.groups} ORDER BY sort_index ASC, created_at ASC, id ASC',
    );
    return rows.map(_rowToGroup).toList();
  }

  SubscriptionGroup? groupById(String id) {
    final rows =
        _db.select('SELECT * FROM ${Tables.groups} WHERE id = ?', [id]);
    return rows.isEmpty ? null : _rowToGroup(rows.first);
  }

  /// Creates or renames a group.
  ///
  /// A rename that collides with another group is refused rather than merged:
  /// silently merging two groups would move subscriptions the user never
  /// selected, and there is no undo. Returns the stored group, or null when the
  /// name is empty or already taken by a different id.
  SubscriptionGroup? upsert(SubscriptionGroup group) {
    final name = SubscriptionGroup.normalizeName(group.name);
    if (name == null) return null;
    final clash = _db.select(
      'SELECT id FROM ${Tables.groups} WHERE name = ? AND id <> ?',
      [name, group.id],
    );
    if (clash.isNotEmpty) return null;
    final stored = group.copyWith(name: name);
    _db.execute(
      '''
      INSERT INTO ${Tables.groups} (id, name, sort_index, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        sort_index = excluded.sort_index
      ''',
      [stored.id, stored.name, stored.sortIndex, stored.createdAtMs],
    );
    return stored;
  }

  /// Deletes the group and ungroups its subscriptions.
  ///
  /// Returns how many subscriptions were ungrouped, so the caller can say so
  /// instead of leaving "where did my rows go" unanswered. No subscription is
  /// deleted: a group is a label, and removing a label must not remove data.
  int deleteGroup(String id) {
    return _store.transaction((db) {
      final affected = db
          .select(
              'SELECT COUNT(*) AS c FROM ${Tables.subscriptions} WHERE group_id = ?',
              [id])
          .first['c'] as int? ?? 0;
      db.execute(
          'UPDATE ${Tables.subscriptions} SET group_id = NULL WHERE group_id = ?',
          [id]);
      db.execute('DELETE FROM ${Tables.groups} WHERE id = ?', [id]);
      return affected;
    });
  }

  /// Reorders groups to match [orderedIds]; unknown ids are ignored.
  void reorder(List<String> orderedIds) {
    _store.transaction((db) {
      for (var i = 0; i < orderedIds.length; i++) {
        db.execute(
            'UPDATE ${Tables.groups} SET sort_index = ? WHERE id = ?',
            [i, orderedIds[i]]);
      }
    });
  }

  SubscriptionGroup _rowToGroup(Row row) => SubscriptionGroup(
        id: '${row['id']}',
        name: '${row['name']}',
        sortIndex: row['sort_index'] as int? ?? 0,
        createdAtMs: row['created_at'] as int? ?? 0,
      );
}

/// Settings as string-keyed JSON. Unknown keys survive so features can be
/// added without a schema migration.
class SettingsRepository {
  SettingsRepository(this._store);

  final HaloStore _store;

  String? raw(String key) {
    final rows = _store.db.select(
        'SELECT value FROM ${Tables.settings} WHERE key = ?', [key]);
    return rows.isEmpty ? null : '${rows.first['value']}';
  }

  void setRaw(String key, String value) {
    _store.db.execute(
      'INSERT INTO ${Tables.settings}(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  bool? getBool(String key) {
    final value = raw(key);
    if (value == null) return null;
    return value == '1' || value.toLowerCase() == 'true';
  }

  void setBool(String key, bool value) => setRaw(key, value ? '1' : '0');

  int? getInt(String key) {
    final value = raw(key);
    return value == null ? null : int.tryParse(value);
  }

  void setInt(String key, int value) => setRaw(key, '$value');

  Object? getJson(String key) {
    final value = raw(key);
    if (value == null) return null;
    try {
      return jsonDecode(value);
    } catch (_) {
      return null;
    }
  }

  void setJson(String key, Object? value) => setRaw(key, jsonEncode(value));

  Map<String, String> all() {
    final rows = _store.db.select('SELECT key, value FROM ${Tables.settings}');
    return {
      for (final row in rows) '${row['key']}': '${row['value']}',
    };
  }
}

/// Bounded audit trail of imports, so a user can see when a list changed.
class ImportLogRepository {
  ImportLogRepository(this._store);

  final HaloStore _store;

  void record({
    required int atMs,
    required String source,
    required String format,
    required int imported,
    required int skipped,
    required int failed,
    String? detail,
  }) {
    _store.db.execute(
      'INSERT INTO ${Tables.importLog}(at, source, format, imported, skipped, failed, detail) '
      'VALUES(?, ?, ?, ?, ?, ?, ?)',
      [
        atMs,
        source,
        format,
        imported,
        skipped,
        failed,
        // The detail carries the failure breakdown plus a few rejected entries
        // (kind, message, raw text). The old 512-character ceiling cut that off
        // in the middle of the first sample, which made the record useless for
        // the question it exists to answer.
        detail == null ? null : _truncate(detail, 8192),
      ],
    );
    // Keep only the most recent entries; this table is informational and must
    // not grow without bound.
    _store.db.execute(
      'DELETE FROM ${Tables.importLog} WHERE id NOT IN '
      '(SELECT id FROM ${Tables.importLog} ORDER BY at DESC LIMIT 200)',
    );
  }

  List<Map<String, Object?>> recent({int limit = 50}) {
    final rows = _store.db.select(
        'SELECT * FROM ${Tables.importLog} ORDER BY at DESC LIMIT ?', [limit]);
    return [
      for (final row in rows)
        {
          'at': row['at'],
          'source': row['source'],
          'format': row['format'],
          'imported': row['imported'],
          'skipped': row['skipped'],
          'failed': row['failed'],
          'detail': row['detail'],
        },
    ];
  }
}

/// Audit trail of applied configurations.
class AppliedConfigRepository {
  AppliedConfigRepository(this._store);

  final HaloStore _store;

  void record({
    required int version,
    required String mode,
    required String configHash,
    required String payload,
    required int createdAtMs,
    String? nodeId,
    String? nodeName,
  }) {
    _store.db.execute(
      'INSERT INTO ${Tables.appliedConfig}'
      '(version, node_id, node_name, mode, config_hash, payload, created_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?)',
      [version, nodeId, nodeName, mode, configHash, payload, createdAtMs],
    );
  }

  Map<String, Object?>? latest() {
    final rows = _store.db
        .select('SELECT * FROM ${Tables.appliedConfig} ORDER BY version DESC LIMIT 1');
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'version': row['version'],
      'nodeId': row['node_id'],
      'nodeName': row['node_name'],
      'mode': row['mode'],
      'configHash': row['config_hash'],
      'payload': row['payload'],
      'createdAt': row['created_at'],
      'rolledBack': (row['rolled_back'] as int? ?? 0) != 0,
    };
  }

  void markRolledBack(int version) {
    _store.db.execute(
        'UPDATE ${Tables.appliedConfig} SET rolled_back = 1 WHERE version = ?', [version]);
  }

  /// Retains only the newest [keep] entries.
  void prune({int keep = 20}) {
    _store.db.execute(
      'DELETE FROM ${Tables.appliedConfig} WHERE version NOT IN '
      '(SELECT version FROM ${Tables.appliedConfig} ORDER BY version DESC LIMIT ?)',
      [keep],
    );
  }
}

String _truncate(String value, [int max = 512]) =>
    value.length <= max ? value : '${value.substring(0, max)}…';

/// Contract version guard: a backup or export written by a newer app must not
/// be read as if it were compatible.
class CompatibilityGuard {
  static bool backupCompatible(int version) => version <= kProtocolVersion;
}
