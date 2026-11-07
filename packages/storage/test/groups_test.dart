import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';
import 'package:test/test.dart';

ProxyNode _node(String suffix) => withIdentity(ProxyNode(
      id: '',
      fingerprint: '',
      name: 'node-$suffix',
      protocol: ProxyProtocol.shadowsocks,
      server: 'host-$suffix.example.com',
      port: 8388,
      secrets: const NodeSecrets(password: 'pw', method: 'aes-256-gcm'),
    ));

SubscriptionProfile _remote(String id, {String? groupId}) => SubscriptionProfile(
      id: id,
      name: id,
      url: 'https://$id.example/sub',
      groupId: groupId,
    );

void main() {
  late Directory tmp;
  late HaloStore store;
  late SubscriptionRepository subs;
  late SubscriptionGroupRepository groups;
  late NodeRepository nodes;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('halo-v6-');
    final open = HaloStore.open('${tmp.path}/halo.db');
    expect(open.ok, isTrue, reason: open.error);
    store = open.store!;
    subs = SubscriptionRepository(store);
    groups = SubscriptionGroupRepository(store);
    nodes = NodeRepository(store);
  });

  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });

  group('migration v6', () {
    /// Rebuilds the pre-v6 shape: no kind/group_id/use_proxy columns, no groups
    /// table, and 本地 nodes expressed as `profile_id IS NULL`.
    void rewindToV5() {
      subs.upsert(_remote('p1'));
      nodes.insert(withIdentity(_node('remote').copyWith(profileId: 'p1')),
          nowMs: 1);
      // Insert through SQL so the row really has a NULL profile: the repository
      // would otherwise attach it to whatever the domain thinks is "local".
      final local = _node('local');
      store.db.execute(
        'INSERT INTO nodes (id, fingerprint, name, protocol, server, port, '
        'secrets, transport, tls, source, profile_id, sort_index, created_at, '
        'updated_at, extras) '
        "VALUES (?, ?, ?, ?, ?, ?, '{}', '{}', '{}', 'manual', NULL, 0, 0, 0, '{}')",
        [
          'local-node',
          local.fingerprint,
          local.name,
          local.protocol.wire,
          local.server,
          local.port,
        ],
      );
      // Drop back to the v5 schema so applyMigrations runs the v6 step again.
      store.db.execute('DROP TABLE subscription_groups');
      store.db.execute('ALTER TABLE subscriptions DROP COLUMN kind');
      store.db.execute('ALTER TABLE subscriptions DROP COLUMN group_id');
      store.db.execute('ALTER TABLE subscriptions DROP COLUMN use_proxy');
      setMeta(store.db, 'schema_version', '5');
    }

    test('local nodes become a real 本地 subscription', () {
      rewindToV5();

      applyMigrations(store.db);

      final local = subs.profileById(kLocalProfileId);
      expect(local, isNotNull);
      expect(local!.name, kLocalProfileName);
      expect(local.kind, SubscriptionKind.local);
      expect(local.isRemote, isFalse);
      expect(subs.allProfiles().where((p) => p.kind == SubscriptionKind.local),
          hasLength(1));
      // No node is left without a source: that is the whole point of the
      // backfill, and it is what lets every enumerator drop its NULL case.
      expect(store.db.select('SELECT id FROM nodes WHERE profile_id IS NULL'),
          isEmpty);
      expect(nodes.nodesForProfile(kLocalProfileId), hasLength(1));
      expect(local.nodeCount, 1);
    });

    test('remote profiles get kind=remote and stay ungrouped', () {
      rewindToV5();
      applyMigrations(store.db);

      final p1 = subs.profileById('p1')!;
      expect(p1.kind, SubscriptionKind.remote);
      expect(p1.groupId, isNull);
      // v7 turns a legacy `use_proxy = 0` with no recorded endpoint into
      // "no opinion" (NULL), because the old NOT NULL column could not tell a
      // default apart from a deliberate off. The host policy then decides.
      expect(p1.useProxy, isNull);
    });

    test('re-running v6 does not create a second local profile', () {
      rewindToV5();
      applyMigrations(store.db);
      final first = subs.profileById(kLocalProfileId)!;

      // Simulate a crash between "profile created" and "version bumped".
      setMeta(store.db, 'schema_version', '5');
      applyMigrations(store.db);

      expect(
        subs.allProfiles().where((p) => p.kind == SubscriptionKind.local),
        hasLength(1),
      );
      expect(subs.profileById(kLocalProfileId)!.createdAtMs, first.createdAtMs);
    });

    test('a database with no local nodes gets no empty 本地 subscription', () {
      // Fresh v6 database: the user has never imported anything locally, so a
      // 本地 row would be a subscription they cannot explain.
      expect(subs.profileById(kLocalProfileId), isNull);
    });
  });

  group('subscription groups', () {
    test('files a profile under a group and reads it back', () {
      final group = groups.upsert(const SubscriptionGroup(id: 'g1', name: '工作'));
      expect(group, isNotNull);
      subs.upsert(_remote('p1'));
      subs.setGroup('p1', 'g1');

      expect(subs.profileById('p1')!.groupId, 'g1');
      expect(groups.allGroups().single.name, '工作');
    });

    test('moving a profile out of a group clears the id', () {
      groups.upsert(const SubscriptionGroup(id: 'g1', name: '工作'));
      subs.upsert(_remote('p1', groupId: 'g1'));

      // copyWith(null) cannot express "clear", which is why the model has an
      // explicit flag; this pins that the flag actually reaches the database.
      subs.upsert(subs.profileById('p1')!.copyWith(clearGroup: true));

      expect(subs.profileById('p1')!.groupId, isNull);
    });

    test('a duplicate name is refused instead of merged', () {
      expect(groups.upsert(const SubscriptionGroup(id: 'g1', name: '工作')),
          isNotNull);
      expect(groups.upsert(const SubscriptionGroup(id: 'g2', name: '工作')),
          isNull);
      expect(groups.allGroups(), hasLength(1));
    });

    test('an empty or whitespace name is refused', () {
      expect(groups.upsert(const SubscriptionGroup(id: 'g1', name: '   ')),
          isNull);
      expect(groups.allGroups(), isEmpty);
    });

    test('renaming keeps existing memberships', () {
      groups.upsert(const SubscriptionGroup(id: 'g1', name: '工作'));
      subs.upsert(_remote('p1', groupId: 'g1'));

      groups.upsert(groups.groupById('g1')!.copyWith(name: '公司'));

      expect(subs.profileById('p1')!.groupId, 'g1');
      expect(groups.groupById('g1')!.name, '公司');
    });

    test('deleting a group ungroups its profiles and keeps them', () {
      groups.upsert(const SubscriptionGroup(id: 'g1', name: '工作'));
      subs.upsert(_remote('p1', groupId: 'g1'));
      subs.upsert(_remote('p2', groupId: 'g1'));

      final affected = groups.deleteGroup('g1');

      expect(affected, 2);
      expect(groups.allGroups(), isEmpty);
      expect(subs.allProfiles(), hasLength(2));
      expect(subs.allProfiles().every((p) => p.groupId == null), isTrue);
    });
  });

  group('per-profile proxy switch', () {
    test('defaults to no opinion and persists an explicit switch', () {
      subs.upsert(_remote('p1'));
      // NULL, not false: an unset switch lets the host policy decide (GitHub
      // sources through the proxy), while `false` would be a user decision that
      // overrides it.
      expect(subs.profileById('p1')!.useProxy, isNull);

      subs.setUseProxy('p1', true);
      expect(subs.profileById('p1')!.useProxy, isTrue);

      // A later upsert from the UI must not silently reset it: useProxy is part
      // of the row, so it round-trips through copyWith like the other columns.
      final profile = subs.profileById('p1')!.copyWith(name: '改名');
      subs.upsert(profile);
      expect(subs.profileById('p1')!.useProxy, isTrue);
    });
  });

  group('deleting a profile', () {
    test('moves its nodes to 本地 instead of orphaning them', () {
      subs.upsert(_remote('p1'));
      nodes.replaceProfileNodes('p1', [_node('a'), _node('b')], nowMs: 1);
      subs.ensureLocalProfile(nowMs: 1);

      subs.deleteProfile('p1');

      expect(subs.profileById('p1'), isNull);
      expect(nodes.nodesForProfile(kLocalProfileId), hasLength(2));
      expect(store.db.select('SELECT id FROM nodes WHERE profile_id IS NULL'),
          isEmpty);
    });

    test('with nodes: --purge-nodes takes them too', () {
      subs.upsert(_remote('p1'));
      nodes.replaceProfileNodes('p1', [_node('a')], nowMs: 1);

      subs.deleteProfileWithNodes('p1');

      expect(nodes.allNodes(), isEmpty);
    });

    test('the 本地 profile itself cannot be deleted', () {
      subs.ensureLocalProfile(nowMs: 1);
      nodes.replaceProfileNodes(kLocalProfileId, [_node('a')], nowMs: 1);

      subs.deleteProfile(kLocalProfileId);

      expect(subs.profileById(kLocalProfileId), isNotNull);
      expect(nodes.nodesForProfile(kLocalProfileId), hasLength(1));
    });
  });

  group('remoteProfiles', () {
    test('excludes the local profile', () {
      subs.upsert(_remote('p1'));
      subs.ensureLocalProfile(nowMs: 1);

      expect(subs.remoteProfiles().map((p) => p.id), ['p1']);
    });
  });
}