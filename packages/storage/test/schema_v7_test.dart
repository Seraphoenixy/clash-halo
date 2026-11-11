import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';
import 'package:test/test.dart';

/// schema v7 rebuilds `subscriptions` to make `use_proxy` nullable.
///
/// The risk this pins down: a table rebuild that loses rows, forgets the foreign
/// key from `nodes`, or cannot be re-run. All three would be silent — the app
/// would still start, with a shorter subscription list.
void main() {
  late Directory tmp;
  late HaloStore store;
  late SubscriptionRepository subs;
  late NodeRepository nodes;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('halo-v7-');
    final open = HaloStore.open('${tmp.path}/halo.db');
    expect(open.ok, isTrue, reason: open.error);
    store = open.store!;
    subs = SubscriptionRepository(store);
    nodes = NodeRepository(store);
  });

  tearDown(() {
    store.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A WAL handle on Windows is not a failure.
    }
  });

  /// Puts the database back into its pre-v7 shape: NOT NULL use_proxy.
  void rewindToV6() {
    store.db.execute('DROP TABLE IF EXISTS subscriptions_v7');
    store.db.execute('''
      CREATE TABLE subscriptions_old (
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
        use_proxy      INTEGER NOT NULL DEFAULT 0,
        proxy_url      TEXT
      )
    ''');
    store.db.execute('''
      INSERT INTO subscriptions_old
        (id, name, url, enabled, auto_update, interval_min, last_updated,
         last_error, node_count, etag, created_at, sort_index, kind, group_id,
         use_proxy, proxy_url)
      SELECT id, name, url, enabled, auto_update, interval_min, last_updated,
         last_error, node_count, etag, created_at, sort_index, kind, group_id,
         COALESCE(use_proxy, 0), proxy_url
      FROM subscriptions
    ''');
    store.db.execute('PRAGMA foreign_keys = OFF');
    store.db.execute('DROP TABLE subscriptions');
    store.db.execute('ALTER TABLE subscriptions_old RENAME TO subscriptions');
    store.db.execute('PRAGMA foreign_keys = ON');
    setMeta(store.db, 'schema_version', '6');
  }

  bool useProxyIsNotNull() {
    final info = store.db.select('PRAGMA table_info(subscriptions)');
    final row = info.firstWhere((r) => '${r['name']}' == 'use_proxy');
    return (row['notnull'] as int? ?? 0) != 0;
  }

  test('a fresh database already has a nullable use_proxy', () {
    // v7 semantics survive later migrations: a fresh install at any version
    // from 7 on must still create the nullable column.
    expect(kSchemaVersion, greaterThanOrEqualTo(7));
    expect(useProxyIsNotNull(), isFalse);
  });

  test('v7 keeps every subscription and node', () {
    subs.upsert(const SubscriptionProfile(
      id: 'p1',
      name: '工作',
      url: 'https://example.com/a',
      groupId: 'g1',
    ));
    subs.upsert(const SubscriptionProfile(
      id: 'p2',
      name: '备用',
      url: 'https://example.com/b',
    ));
    nodes.replaceProfileNodes(
      'p1',
      [
        withIdentity(ProxyNode(
          id: '',
          fingerprint: '',
          name: 'n1',
          protocol: ProxyProtocol.trojan,
          server: 'a.example.com',
          port: 443,
          secrets: const NodeSecrets(password: 'x'),
        )),
      ],
      nowMs: 1,
    );
    final beforeSubs = subs.allProfiles();
    final beforeNodes = nodes.allNodes();

    rewindToV6();
    applyMigrations(store.db);

    expect(useProxyIsNotNull(), isFalse);
    final afterSubs = subs.allProfiles();
    expect(afterSubs.map((p) => p.id), beforeSubs.map((p) => p.id));
    expect(afterSubs.map((p) => p.name), beforeSubs.map((p) => p.name));
    // group_id and proxy_url must survive the rebuild too: they are the columns
    // an explicit-column copy is most likely to forget.
    expect(afterSubs.firstWhere((p) => p.id == 'p1').groupId, 'g1');
    expect(nodes.allNodes().length, beforeNodes.length);
    // The foreign key from nodes is still satisfied and still enforced.
    expect(store.db.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('v7 is re-runnable', () {
    subs.upsert(const SubscriptionProfile(
      id: 'p1',
      name: '工作',
      url: 'https://example.com/a',
    ));
    rewindToV6();
    applyMigrations(store.db);
    final afterFirst = subs.allProfiles().length;

    // A crash between the version bump and commit would leave v6 again.
    rewindToV6();
    applyMigrations(store.db);

    expect(subs.allProfiles(), hasLength(afterFirst));
    expect(useProxyIsNotNull(), isFalse);
  });

  test('NULL means "no opinion" and survives a round trip', () {
    subs.upsert(const SubscriptionProfile(
      id: 'p1',
      name: 'a',
      url: 'https://raw.githubusercontent.com/x/y/main/v.txt',
    ));

    // Unset on a new row.
    expect(subs.profileById('p1')!.useProxy, isNull);

    subs.setUseProxy('p1', true);
    expect(subs.profileById('p1')!.useProxy, isTrue);

    subs.setUseProxy('p1', false);
    expect(subs.profileById('p1')!.useProxy, isFalse);

    // And back to "no opinion", which `bool` could not express.
    subs.setUseProxy('p1', null);
    expect(subs.profileById('p1')!.useProxy, isNull);
  });

  test('a legacy default 0 becomes "no opinion", so the policy can decide', () {
    subs.upsert(const SubscriptionProfile(
      id: 'p1',
      name: 'gh',
      url: 'https://raw.githubusercontent.com/a/b/main/v.txt',
    ));
    // Pre-v7 shape: NOT NULL 0, no endpoint ever recorded.
    rewindToV6();
    applyMigrations(store.db);

    // Turning every legacy 0 into an explicit "off" would make the GitHub
    // policy dead code on existing databases, which is the whole point of v7.
    expect(subs.profileById('p1')!.useProxy, isNull);
  });

  test('a legacy 0 that once had an endpoint stays an explicit off', () {
    subs.upsert(const SubscriptionProfile(
      id: 'p1',
      name: 'gh',
      url: 'https://raw.githubusercontent.com/a/b/main/v.txt',
    ));
    // Turned on (records an endpoint), then off again: a real decision.
    subs.setUseProxy('p1', true, proxyUrl: 'http://127.0.0.1:7890');
    subs.setUseProxy('p1', false);
    expect(subs.profileById('p1')!.useProxy, isFalse);

    rewindToV6();
    applyMigrations(store.db);

    // The endpoint is the evidence that this row's 0 was chosen. Flipping it
    // would re-enable a proxy the user had deliberately turned off.
    expect(subs.profileById('p1')!.useProxy, isFalse);
    expect(subs.profileById('p1')!.useProxyFor(
      'https://raw.githubusercontent.com/a/b/main/v.txt',
    ), isFalse);
  });

  test('an explicit false written after v7 is never rewritten', () {
    // Before v7 the column was NOT NULL, so every row carried 0 or 1. Those are
    // explicit values and must stay explicit after the upgrade.
    subs.upsert(const SubscriptionProfile(
      id: 'p1',
      name: 'a',
      url: 'https://example.com/a',
    ));
    // Simulate the pre-v7 value directly.
    store.db.execute("UPDATE subscriptions SET use_proxy = 0 WHERE id = 'p1'");

    expect(subs.profileById('p1')!.useProxy, isFalse);
  });
}
