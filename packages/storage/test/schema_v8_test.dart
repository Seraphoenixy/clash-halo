import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';
import 'package:test/test.dart';

/// schema v8 collapses the node table to one row per connection and makes the
/// fingerprint index globally unique.
///
/// The risk this pins down: a migration that merges the wrong row (the newest
/// instead of the first import), keeps two rows of the same connection, or
/// leaves the old per-profile index in place so the repositories' global skip
/// rule has nothing to stand on. All three would be silent — the list would
/// keep showing the same connection under several names.
void main() {
  late Directory tmp;
  late HaloStore store;
  late SubscriptionRepository subs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('halo-v8-');
    final open = HaloStore.open('${tmp.path}/halo.db');
    expect(open.ok, isTrue, reason: open.error);
    store = open.store!;
    subs = SubscriptionRepository(store);
  });

  tearDown(() {
    store.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A WAL handle on Windows is not a failure.
    }
  });

  /// Puts the database back into its pre-v8 shape: the identity index scoped
  /// per profile, so the same connection may exist once per subscription.
  void rewindToV7() {
    store.db.execute('DROP INDEX IF EXISTS idx_nodes_fingerprint');
    store.db.execute(
      "CREATE UNIQUE INDEX idx_nodes_fingerprint ON nodes"
      "(fingerprint, COALESCE(profile_id, ''))",
    );
    setMeta(store.db, 'schema_version', '7');
  }

  /// Writes a node row directly, bypassing the repositories: pre-v8 data was
  /// written by code that allowed one row per (fingerprint, profile).
  void insertRawRow({
    required String id,
    required String fingerprint,
    required String name,
    required String profileId,
    required int createdAt,
  }) {
    store.db.execute(
      'INSERT INTO nodes '
      '(id, fingerprint, name, protocol, server, port, secrets, transport, '
      ' tls, source, profile_id, sort_index, created_at, updated_at, extras) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        fingerprint,
        name,
        'trojan',
        'edge.example.com',
        '443',
        '{"password":"x"}',
        '{}',
        '{}',
        'subscription',
        profileId,
        0,
        createdAt,
        createdAt,
        '{}',
      ],
    );
  }

  int nodeCount() =>
      (store.db.select('SELECT COUNT(*) AS c FROM nodes').first['c'] as int);

  String indexSql() => '${(store.db.select(
        "SELECT sql FROM sqlite_master WHERE name = 'idx_nodes_fingerprint'",
      ).first['sql'])}';

  test('a fresh database already has the global unique index', () {
    expect(kSchemaVersion, greaterThanOrEqualTo(8));
    expect(indexSql(), contains('(fingerprint)'));
    expect(indexSql(), isNot(contains('profile_id')));
  });

  test('v8 merges duplicate rows and keeps the earliest import', () {
    subs.upsert(const SubscriptionProfile(
        id: 'p1', name: '先来', url: 'https://example.com/a', createdAtMs: 1));
    subs.upsert(const SubscriptionProfile(
        id: 'p2', name: '后来', url: 'https://example.com/b', createdAtMs: 2));
    rewindToV7();
    // The same connection under two profiles. p2's copy is the older row even
    // though p1 exists: the survivor is decided by created_at, not by profile
    // order, matching the "first import wins" rule the write paths use.
    insertRawRow(
      id: 'sub_p1_fp1',
      fingerprint: 'fp1',
      name: '副本（后导入）',
      profileId: 'p1',
      createdAt: 200,
    );
    insertRawRow(
      id: 'sub_p2_fp1',
      fingerprint: 'fp1',
      name: '原件（先导入）',
      profileId: 'p2',
      createdAt: 100,
    );

    applyMigrations(store.db);

    expect(nodeCount(), 1);
    final row = store.db
        .select('SELECT id, name, profile_id FROM nodes')
        .single;
    expect(row['id'], 'sub_p2_fp1');
    expect(row['name'], '原件（先导入）');
    expect(row['profile_id'], 'p2');
    expect(metaOf(store.db, SettingKeys.mergedDuplicateNodes), '1');
  });

  test('after v8 a fingerprint can exist only once, in any profile', () {
    subs.upsert(const SubscriptionProfile(
        id: 'p1', name: 'a', url: 'https://example.com/a', createdAtMs: 1));
    insertRawRow(
      id: 'sub_p1_fp1',
      fingerprint: 'fp1',
      name: 'n',
      profileId: 'p1',
      createdAt: 100,
    );
    applyMigrations(store.db);

    expect(
      () => insertRawRow(
        id: 'sub_p1_fp1-copy',
        fingerprint: 'fp1',
        name: 'n2',
        profileId: 'p1',
        createdAt: 200,
      ),
      throwsA(isA<Exception>()),
      reason: 'the unique index is global now',
    );
  });

  test('v8 is re-runnable', () {
    subs.upsert(const SubscriptionProfile(
        id: 'p1', name: 'a', url: 'https://example.com/a', createdAtMs: 1));
    insertRawRow(
      id: 'sub_p1_fp1',
      fingerprint: 'fp1',
      name: 'n',
      profileId: 'p1',
      createdAt: 100,
    );
    applyMigrations(store.db);
    final afterFirst = nodeCount();

    // A crash between the version bump and the commit would leave v7 again.
    rewindToV7();
    applyMigrations(store.db);

    expect(nodeCount(), afterFirst);
    expect(metaOf(store.db, SettingKeys.mergedDuplicateNodes), isNull,
        reason: 'the second run found nothing to merge');
  });
}
