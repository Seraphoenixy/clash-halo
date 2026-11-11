import 'dart:convert';
import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

ProxyNode _node(String suffix, {ProxyProtocol protocol = ProxyProtocol.shadowsocks}) =>
    withIdentity(ProxyNode(
      id: '',
      fingerprint: '',
      name: 'node-$suffix',
      protocol: protocol,
      server: 'host-$suffix.example.com',
      port: 8388,
      secrets: NodeSecrets(
        password: 'pw-$suffix',
        method: protocol == ProxyProtocol.shadowsocks ? 'aes-256-gcm' : null,
        uuid: protocol == ProxyProtocol.vmess ? 'uuid-$suffix' : null,
      ),
    ));

void main() {
  late Directory tmp;
  late HaloStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('halo-store-');
    final open = HaloStore.open('${tmp.path}/halo.db');
    expect(open.ok, isTrue, reason: open.error);
    store = open.store!;
  });

  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });

  group('schema', () {
    test('fresh database reports the current version', () {
      expect(metaOf(store.db, 'schema_version'), '${kSchemaVersion}');
      expect(store.integrityIssues(), isEmpty);
    });

    test('reopening an existing database keeps data and version', () {
      NodeRepository(store).insert(_node('a'), nowMs: 1000);
      store.close();
      final reopened = HaloStore.open('${tmp.path}/halo.db');
      expect(reopened.ok, isTrue);
      expect(metaOf(reopened.store!.db, 'schema_version'), '${kSchemaVersion}');
      expect(NodeRepository(reopened.store!).allNodes().length, 1);
      store = reopened.store!;
    });

    test('a database from a newer version is refused and quarantined', () {
      store.close();
      final db = sqlite3.open('${tmp.path}/halo.db');
      setMeta(db, 'schema_version', '9');
      db.close();
      final reopened = HaloStore.open('${tmp.path}/halo.db');
      expect(reopened.ok, isFalse);
      expect(reopened.error, contains('高于当前支持的'));
      final broken = tmp.listSync().whereType<File>().where((f) => f.path.contains('.broken-'));
      expect(broken, isNotEmpty, reason: '原文件应被保留而不是删除');
    });

    test('a foreign sqlite file without our schema is refused', () {
      store.close();
      final db = sqlite3.open('${tmp.path}/halo.db');
      db.execute('DROP TABLE meta');
      db.execute('CREATE TABLE other (x INTEGER)');
      db.close();
      final reopened = HaloStore.open('${tmp.path}/halo.db');
      expect(reopened.ok, isFalse);
      expect(reopened.error, contains('不是 clash-halo 数据库'));
    });

    test('migrations are idempotent when re-run', () {
      applyMigrations(store.db);
      applyMigrations(store.db);
      expect(metaOf(store.db, 'schema_version'), '${kSchemaVersion}');
    });

    group('migration v5 repairs nodes the old v2rayN importer mislabelled', () {
      /// Writes a node row directly, bypassing the importer, the way a database
      /// written before the fix looks on disk.
      void seed(String id, String protocol, Map<String, Object?> v2rayn) {
        final node = withIdentity(
          ProxyNode(
            id: '',
            fingerprint: '',
            name: id,
            protocol: ProxyProtocol.values.firstWhere((p) => p.wire == protocol),
            // A distinct server keeps each seed its own fingerprint; otherwise
            // the repository's identity dedupe would merge two seeds and the
            // test would be measuring that instead of the migration.
            server: '$id.test',
            port: 443,
            extras: {'v2rayn': v2rayn},
          ),
        );
        // The id is derived from the fingerprint, so force the name to identify
        // the row in assertions.
        NodeRepository(store).insert(node, nowMs: 1);
      }

      /// Re-runs the v5 step on a database that has already been migrated: set
      /// the version back to 4 the way a failed upgrade would leave it.
      ///
      /// A literal 4, not `kSchemaVersion - 1`: that expression silently started
      /// meaning "rewind to v5" when v6 was added, so the v5 step stopped running
      /// and this group would have gone on passing while testing nothing.
      void rewind() => setMeta(store.db, 'schema_version', '4');

      test('deletes only rows whose protocol contradicts their configType', () {
        seed('broken', 'trojan', {'configType': 5}); // 5 is VLESS, not Trojan
        seed('healthy', 'vless', {'configType': 5});
        seed('naive', 'naive', {'configType': 12});
        seed('noExtra', 'trojan', {});

        final before = NodeRepository(store).allNodes().length;
        expect(before, 4);

        rewind();
        applyMigrations(store.db);

        final names = NodeRepository(store).allNodes().map((n) => n.name).toList();
        expect(names, containsAll(['healthy', 'naive', 'noExtra']));
        expect(names, isNot(contains('broken')));
        expect(metaOf(store.db, SettingKeys.repairedNodes), '1');
      });

      test('leaves a database with nothing to repair untouched', () {
        seed('healthy', 'vless', {'configType': 5});
        seed('deep', 'trojan', {'configType': 6});
        rewind();
        applyMigrations(store.db);
        expect(NodeRepository(store).allNodes(), hasLength(2));
        expect(metaOf(store.db, SettingKeys.repairedNodes), isNull,
            reason: '不需要修复时不该留下痕迹');
      });

      test('survives a row whose extras are not valid JSON', () {
        // A corrupt extras column must not abort the upgrade and quarantine the
        // whole database; it is simply not evidence of anything.
        seed('healthy', 'vless', {'configType': 5});
        store.db.execute(
          "UPDATE nodes SET extras = '{not json' WHERE name = 'healthy'",
        );
        rewind();
        applyMigrations(store.db);
        expect(NodeRepository(store).allNodes(), hasLength(1));
      });
    });

    test('transaction rolls back on throw', () {
      final repo = NodeRepository(store);
      expect(
        () => store.transaction((db) {
          repo.insert(_node('tx'), nowMs: 1);
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(repo.allNodes(), isEmpty);
    });
  });

  group('node repository', () {
    test('inserts, reads back every field', () {
      final node = withIdentity(ProxyNode(
        id: '',
        fingerprint: '',
        name: 'full',
        protocol: ProxyProtocol.vless,
        server: 'v.example.com',
        port: 443,
        secrets: const NodeSecrets(uuid: 'u-1', flow: 'xtls-rprx-vision'),
        tls: const TlsConfig(
            kind: TlsKind.reality,
            serverName: 'v.example.com',
            realityPublicKey: 'pbk',
            realityShortId: 'sid',
            fingerprint: 'chrome',
            alpn: ['h2']),
        transport: const TransportConfig(
            kind: TransportKind.ws,
            path: '/ws',
            host: 'cdn.example.com',
            headers: {'X-Test': '1'},
            earlyData: 2048),
        extras: const {'note': 'keep-me'},
      ));
      final stored = NodeRepository(store).insert(node, nowMs: 5);
      final read = NodeRepository(store).nodeById(stored.id)!;
      expect(read.protocol, ProxyProtocol.vless);
      expect(read.secrets.flow, 'xtls-rprx-vision');
      expect(read.tls.realityPublicKey, 'pbk');
      expect(read.tls.alpn, ['h2']);
      expect(read.transport.headers['X-Test'], '1');
      expect(read.transport.earlyData, 2048);
      expect(read.extras['note'], 'keep-me');
      expect(read.fingerprint, node.fingerprint);
    });

    test('re-inserting the same connection updates instead of duplicating', () {
      final repo = NodeRepository(store);
      final first = repo.insert(_node('dup'), nowMs: 100);
      final again = repo.insert(_node('dup').copyWith(name: 'renamed'), nowMs: 200);
      expect(again.id, first.id);
      expect(repo.allNodes().length, 1);
      expect(repo.nodeById(first.id)!.name, 'renamed');
      expect(repo.nodeById(first.id)!.createdAtMs, 100);
      expect(repo.nodeById(first.id)!.updatedAtMs, 200);
    });

    test('delete and reorder', () {
      final repo = NodeRepository(store);
      final a = repo.insert(_node('a'), nowMs: 1);
      final b = repo.insert(_node('b'), nowMs: 2);
      final c = repo.insert(_node('c'), nowMs: 3);
      repo.reorderNodes([c.id, a.id, b.id]);
      expect(repo.allNodes().map((n) => n.name), ['node-c', 'node-a', 'node-b']);
      repo.deleteNodes([b.id]);
      expect(repo.allNodes().map((n) => n.name), ['node-c', 'node-a']);
    });

    test('batch rename persists names without changing identity', () {
      final repo = NodeRepository(store);
      final node = repo.insert(_node('r'), nowMs: 1);
      repo.renameNodes({node.id: '自定义名称'}, nowMs: 2);
      final read = repo.nodeById(node.id)!;
      expect(read.name, '自定义名称');
      expect(read.fingerprint, node.fingerprint);
    });

    test('profile nodes are replaced atomically and keep local renames', () {
      final subs = SubscriptionRepository(store);
      subs.upsert(const SubscriptionProfile(
          id: 'p1', name: 'Sub', url: 'https://example.com/sub', createdAtMs: 1));
      final repo = NodeRepository(store);
      final first = repo.replaceProfileNodes(
          'p1', [_node('x'), _node('y')],
          nowMs: 10, keepNames: true);
      repo.renameNodes({first.stored.first.id: '我的节点'}, nowMs: 11);
      final second = repo.replaceProfileNodes(
          'p1', [_node('x'), _node('z')],
          nowMs: 20, keepNames: true);
      expect(repo.nodesForProfile('p1').length, 2);
      expect(second.stored.first.name, '我的节点');
      expect(repo.nodesForProfile('p1').any((n) => n.name == 'node-z'), isTrue);
    });

    test('deleting a profile keeps its nodes, moving them to 本地', () {
      final subs = SubscriptionRepository(store);
      subs.upsert(const SubscriptionProfile(
          id: 'p2', name: 'Sub2', url: 'https://example.com/s2'));
      final repo = NodeRepository(store);
      repo.replaceProfileNodes('p2', [_node('keep')], nowMs: 1);
      subs.deleteProfile('p2');
      final node = repo.allNodes().single;
      // Since v6 "no profile" is not a state a node can be in: 本地 is a real
      // subscription, so deleting one subscription re-files its nodes rather
      // than orphaning them.
      expect(node.profileId, kLocalProfileId);
      expect(node.source, NodeSourceKind.subscription);
      expect(subs.profileById(kLocalProfileId), isNotNull);
    });
  });

  group('subscription repository', () {
    test('upsert and refresh bookkeeping', () {
      final repo = SubscriptionRepository(store);
      repo.upsert(const SubscriptionProfile(
        id: 's1',
        name: 'S1',
        url: 'https://example.com/sub',
        createdAtMs: 1,
        sortIndex: 0,
      ));
      repo.markUpdated('s1', atMs: 42, nodeCount: 3, etag: 'W/"abc"');
      final read = repo.profileById('s1')!;
      expect(read.lastUpdatedAtMs, 42);
      expect(read.nodeCount, 3);
      expect(read.etag, 'W/"abc"');
      expect(read.lastError, isNull);

      repo.markFailed('s1', atMs: 100, error: 'timeout');
      final failed = repo.profileById('s1')!;
      expect(failed.lastError, 'timeout');
      // The previous success timestamp is preserved: a failed refresh must not
      // look like a successful update.
      expect(failed.lastUpdatedAtMs, 42);
      expect(failed.nodeCount, 3);
    });

    test('displayUrl masks credentials', () {
      final profile = const SubscriptionProfile(
        id: 's',
        name: 'S',
        url: 'https://user:secret@example.com/sub?token=a',
      );
      expect(profile.displayUrl.contains('secret'), isFalse);
      expect(profile.displayUrl.contains('user'), isFalse);
    });

    test('error text is truncated, never unbounded', () {
      final repo = SubscriptionRepository(store);
      repo.upsert(const SubscriptionProfile(id: 's3', name: 'S3', url: 'u'));
      repo.markFailed('s3', atMs: 1, error: 'x' * 2000);
      expect(repo.profileById('s3')!.lastError!.length, lessThanOrEqualTo(513));
    });
  });

  group('settings', () {
    test('typed accessors round trip and keep unknown keys', () {
      final repo = SettingsRepository(store);
      repo.setBool(SettingKeys.systemProxy, true);
      repo.setInt(SettingKeys.speedTestConcurrency, 4);
      repo.setJson('custom.thing', {'a': 1});
      expect(repo.getBool(SettingKeys.systemProxy), isTrue);
      expect(repo.getInt(SettingKeys.speedTestConcurrency), 4);
      expect(repo.getJson('custom.thing'), {'a': 1});
      expect(repo.getBool('missing'), isNull);
      expect(repo.all().length, 3);
    });
  });

  group('import log', () {
    test('records entries and caps the table', () {
      final repo = ImportLogRepository(store);
      for (var i = 0; i < 250; i++) {
        repo.record(
            atMs: i,
            source: 'file',
            format: 'share_links',
            imported: 1,
            skipped: 0,
            failed: 0);
      }
      expect(store.tableCounts()[Tables.importLog], 200);
      final recent = repo.recent(limit: 2);
      expect(recent.first['at'], 249);
      expect(recent.length, 2);
    });

    test('keeps a failure detail longer than one sample', () {
      // The detail is a JSON blob: counts by kind plus the raw text of the
      // rejected entries. The old 512-character ceiling cut it off inside the
      // first sample, so the record could not answer "which entries were
      // refused" — the question it is written for.
      final repo = ImportLogRepository(store);
      final raw = 'x' * 600;
      final detail = '{"samples":[{"raw":"$raw"}]}';
      repo.record(
        atMs: 1,
        source: 'sub',
        format: 'share_links',
        imported: 1,
        skipped: 0,
        failed: 1,
        detail: detail,
      );
      final stored = '${repo.recent(limit: 1).first['detail']}';
      expect(stored, startsWith('{"samples":[{"raw":"xxxx'));
      expect(stored.length, greaterThan(512));
      expect(stored, contains('x' * 600));
    });
  });

  group('applied config audit', () {
    test('records, prunes and marks rollback', () {
      final repo = AppliedConfigRepository(store);
      for (var v = 1; v <= 25; v++) {
        repo.record(
            version: v,
            mode: 'rule',
            configHash: 'hash-$v',
            payload: '{}',
            createdAtMs: v,
            nodeName: 'n$v');
      }
      repo.prune(keep: 5);
      final latest = repo.latest()!;
      expect(latest['version'], 25);
      repo.markRolledBack(25);
      expect(repo.latest()!['rolledBack'], isTrue);
      expect(store.tableCounts()[Tables.appliedConfig], 5);
    });
  });

  group('backup', () {
    BackupPayload seed() => Backup.collect(store, nowMs: 7, appVersion: '0.1.0');

    test('round trips nodes, subscriptions and settings unencrypted', () async {
      final node = NodeRepository(store).insert(_node('bk'), nowMs: 1);
      SubscriptionRepository(store)
          .upsert(const SubscriptionProfile(id: 'bs', name: 'BS', url: 'https://e/sub'));
      SettingsRepository(store).setBool(SettingKeys.autoLaunch, true);
      // Device-specific settings must be excluded from the export.
      SettingsRepository(store).setBool('system.proxyEnabled', true);

      final payload = seed();
      final exported = await Backup.exportSafe(payload, password: '');
      expect(exported.ok, isTrue);
      final decoded = jsonDecode(exported.text!) as Map;
      expect(decoded['magic'], kBackupMagic);
      expect(decoded['encrypted'], isFalse);
      final inPayload = (decoded['payload'] as Map)['settings'] as Map;
      expect(inPayload.containsKey('system.proxyEnabled'), isFalse);
      expect(inPayload.containsKey(SettingKeys.autoLaunch), isTrue);

      final result = await Backup.inspectAsync(
        exported.text!,
        existingNodeCountsByFingerprint: const {},
        existingSubscriptionCount: 0,
      );
      expect(result.error, isNull);
      expect(result.preview!.payload.nodes.single.name, 'node-bk');
      expect(result.preview!.conflicts, 0);
      expect(result.preview!.encrypted, isFalse);
      expect(node.fingerprint, result.preview!.payload.nodes.single.fingerprint);
    });

    test('encrypted export hides credentials and needs the right password', () async {
      NodeRepository(store).insert(_node('secret'), nowMs: 1);
      final exported = await Backup.exportSafe(seed(), password: 'correct horse');
      expect(exported.ok, isTrue, reason: exported.error?.message);
      expect(exported.encrypted, isTrue);
      expect(exported.text!.contains('pw-secret'), isFalse, reason: '密码不得以明文出现在文件中');

      final noPassword = await Backup.inspectAsync(exported.text!,
          existingNodeCountsByFingerprint: const {}, existingSubscriptionCount: 0);
      expect(noPassword.error!.code, 'password_required');

      final wrong = await Backup.inspectAsync(exported.text!,
          existingNodeCountsByFingerprint: const {},
          existingSubscriptionCount: 0,
          password: 'wrong');
      expect(wrong.error!.code, 'wrong_password');

      final ok = await Backup.inspectAsync(exported.text!,
          existingNodeCountsByFingerprint: const {},
          existingSubscriptionCount: 0,
          password: 'correct horse');
      expect(ok.error, isNull);
      expect(ok.preview!.payload.nodes.single.secrets.password, 'pw-secret');
    });

    test('password on an unencrypted backup is rejected explicitly', () async {
      final exported = await Backup.exportSafe(seed());
      final result = await Backup.inspectAsync(exported.text!,
          existingNodeCountsByFingerprint: const {},
          existingSubscriptionCount: 0,
          password: 'x');
      expect(result.error!.code, 'not_encrypted');
    });

    test('foreign or truncated files are rejected with reasons', () async {
      final notBackup = await Backup.inspectAsync('{"hello":"world"}',
          existingNodeCountsByFingerprint: const {}, existingSubscriptionCount: 0);
      expect(notBackup.error!.code, 'bad_magic');

      final truncated = await Backup.inspectAsync('{',
          existingNodeCountsByFingerprint: const {}, existingSubscriptionCount: 0);
      expect(truncated.error!.code, 'bad_format');

      final future = await Backup.inspectAsync(
          jsonEncode({
            'magic': kBackupMagic,
            'formatVersion': kBackupFormatVersion + 5,
            'encrypted': false
          }),
          existingNodeCountsByFingerprint: const {},
          existingSubscriptionCount: 0);
      expect(future.error!.code, 'too_new');
    });

    test('preview reports conflicts and deltas', () async {
      NodeRepository(store).insert(_node('d1'), nowMs: 1);
      NodeRepository(store).insert(_node('d2'), nowMs: 1);
      SubscriptionRepository(store)
          .upsert(const SubscriptionProfile(id: 'sp', name: 'SP', url: 'u'));
      final incoming = BackupPayload(
        nodes: [_node('d1'), _node('d3')],
        subscriptions: [
          const SubscriptionProfile(id: 'sp', name: 'SP', url: 'u'),
          const SubscriptionProfile(id: 'sp2', name: 'SP2', url: 'u2'),
        ],
        settings: const {SettingKeys.themeMode: 'dark'},
        exportedAtMs: 10,
        appVersion: '1.0.0',
      );
      final exported = await Backup.exportSafe(incoming);
      final result = await Backup.inspectAsync(
        exported.text!,
        existingNodeCountsByFingerprint:
            Backup.fingerprintIndex(NodeRepository(store)),
        existingSubscriptionCount: 1,
      );
      expect(result.preview!.conflicts, 1);
      expect(result.preview!.nodeDelta, 1);
      expect(result.preview!.subscriptionDelta, 1);
      expect(result.preview!.summary, contains('2 个节点'));
    });

    test('restore merges data and always produces a rollback backup', () async {
      final payload = BackupPayload(
        nodes: [_node('r1')],
        subscriptions: const [
          SubscriptionProfile(id: 'rs', name: 'RS', url: 'https://e/rs'),
        ],
        settings: const {SettingKeys.themeMode: 'light', 'system.proxyEnabled': '1'},
        exportedAtMs: 1,
        appVersion: '1.0.0',
        platform: 'windows',
      );
      final exported = await Backup.exportSafe(payload);
      final preview = (await Backup.inspectAsync(exported.text!,
              existingNodeCountsByFingerprint: const {}, existingSubscriptionCount: 0))
          .preview!;
      final result = Backup.apply(store, preview, nowMs: 50, appVersion: '0.1.0');
      expect(result.applied, isTrue, reason: result.error?.message);
      expect(result.nodesImported, 1);
      expect(result.subscriptionsImported, 1);
      expect(result.rollbackBackup, isNotNull);
      expect(NodeRepository(store).allNodes().single.name, 'node-r1');
      // The restored profile is present; a 本地 subscription may also exist
      // because locally-imported nodes now have a real profile row.
      expect(
        SubscriptionRepository(store).allProfiles().map((p) => p.id),
        contains('rs'),
      );
      expect(SettingsRepository(store).raw(SettingKeys.themeMode), 'light');
      // Device-specific keys from another platform are not applied.
      expect(SettingsRepository(store).raw('system.proxyEnabled'), isNull);
    });

    test('restore does not duplicate already-present connections', () async {
      NodeRepository(store).insert(_node('same'), nowMs: 1);
      final payload = BackupPayload(
        nodes: [_node('same'), _node('new')],
        subscriptions: const [],
        settings: const {},
        exportedAtMs: 1,
        appVersion: '1.0.0',
      );
      final exported = await Backup.exportSafe(payload);
      final preview = (await Backup.inspectAsync(exported.text!,
              existingNodeCountsByFingerprint:
                  Backup.fingerprintIndex(NodeRepository(store)),
              existingSubscriptionCount: 0))
          .preview!;
      Backup.apply(store, preview, nowMs: 60, appVersion: '0.1.0');
      expect(NodeRepository(store).allNodes().length, 2);
    });

    test('a restored backup still passes integrity checks', () async {
      Backup.apply(
          store,
          (await Backup.inspectAsync(
                  (await Backup.exportSafe(seed())).text!,
                  existingNodeCountsByFingerprint: const {},
                  existingSubscriptionCount: 0))
              .preview!,
          nowMs: 70,
          appVersion: '0.1.0');
      expect(store.integrityIssues(), isEmpty);
      expect(metaOf(store.db, 'last_restore_at'), '70');
    });
  });

  group('insertAll (batched import)', () {
    test('inserts a fresh batch and matches per-row insert semantics', () {
      final repo = NodeRepository(store);
      final nodes = [_node('b1'), _node('b2'), _node('b3')];
      final out = repo.insertAll(nodes, nowMs: 10);
      expect(out.stored, hasLength(3));
      expect(out.stored.every((n) => n.id.startsWith('n_')), isTrue);
      expect(out.stored.every((n) => n.updatedAtMs == 10), isTrue);
      expect(repo.allNodes(), hasLength(3));
    });

    test('re-importing the same batch updates in place, not duplicates', () {
      final repo = NodeRepository(store);
      final first = repo.insertAll([_node('b1'), _node('b2')], nowMs: 10);
      final renamed =
          first.stored.map((n) => n.copyWith(name: '${n.name}-v2')).toList();
      final second = repo.insertAll(renamed, nowMs: 20);
      expect(repo.allNodes(), hasLength(2),
          reason: 'identity is the fingerprint');
      // The second run won and the ids survived.
      for (final node in second.stored) {
        final stored = repo.nodeById(node.id)!;
        expect(stored.name, endsWith('-v2'));
        expect(stored.updatedAtMs, 20);
      }
    });

    test('duplicates inside one batch keep the first occurrence', () {
      final repo = NodeRepository(store);
      final base = _node('dup');
      // Identity is deduped at every layer with the same rule the importers
      // report ("已保留第一条"): first occurrence wins, later ones are
      // reported as skips instead of silently overwriting the winner.
      final out =
          repo.insertAll([base, base.copyWith(name: 'dup-renamed')], nowMs: 10);
      final all = repo.allNodes();
      expect(all, hasLength(1));
      expect(all.single.name, 'node-dup');
      expect(out.stored, hasLength(1));
      expect(out.skippedDuplicates, hasLength(1));
      expect(out.skippedDuplicates.single.sameBatch, isTrue);
      expect(out.skippedDuplicates.single.node.name, 'dup-renamed');
    });

    test('an empty batch is a no-op', () {
      final repo = NodeRepository(store);
      expect(repo.insertAll(const [], nowMs: 1).stored, isEmpty);
      expect(repo.allNodes(), isEmpty);
    });

    test('a connection another profile owns is skipped, not duplicated', () {
      final repo = NodeRepository(store);
      repo.insertAll([_node('owned')], nowMs: 10);

      // Same connection, different profile: the paste must not put a second
      // copy of a node a subscription already carries into the pool.
      final out = repo.insertAll([
        _node('owned').copyWith(
          profileId: 'other-profile',
          name: '换个名字的同一台服务器',
        ),
      ], nowMs: 20);

      expect(out.stored, isEmpty);
      expect(out.skippedDuplicates, hasLength(1));
      expect(out.skippedDuplicates.single.sameBatch, isFalse);
      expect(out.skippedDuplicates.single.ownerProfileId, kLocalProfileId,
          reason: 'the first import owns the connection');
      expect(repo.allNodes(), hasLength(1));
      expect(repo.allNodes().single.name, 'node-owned');
    });

    test('re-importing into the owning profile still updates in place', () {
      final repo = NodeRepository(store);
      final first = repo.insertAll([_node('same')], nowMs: 10);
      final out = repo.insertAll(
        [first.stored.single.copyWith(name: 'node-same-v2')],
        nowMs: 20,
      );
      expect(out.stored, hasLength(1));
      expect(out.skippedDuplicates, isEmpty);
      expect(repo.allNodes().single.name, 'node-same-v2');
    });
  });

  group('replaceProfileNodes (cross-profile identity)', () {
    test('a refresh skips connections another profile already owns', () {
      final subs = SubscriptionRepository(store);
      subs.upsert(const SubscriptionProfile(
          id: 'p1', name: 'A', url: 'https://example.com/a'));
      subs.upsert(const SubscriptionProfile(
          id: 'p2', name: 'B', url: 'https://example.com/b'));
      final repo = NodeRepository(store);

      // The two aggregators publish the same node; p1 got there first.
      final shared = _node('shared');
      repo.replaceProfileNodes('p1', [shared, _node('only-a')], nowMs: 10);

      final out = repo.replaceProfileNodes(
        'p2',
        [shared.copyWith(name: 'node-shared-renamed'), _node('only-b')],
        nowMs: 20,
      );

      expect(out.stored, hasLength(1), reason: 'only the p2-only node lands');
      expect(out.stored.single.name, 'node-only-b');
      expect(out.skippedDuplicates, hasLength(1));
      expect(out.skippedDuplicates.single.ownerProfileId, 'p1');
      expect(out.skippedDuplicates.single.node.name, 'node-shared-renamed');

      final all = repo.allNodes();
      expect(all, hasLength(3), reason: 'shared, only-a, only-b — one copy each');
      expect(all.where((n) => n.fingerprint == shared.fingerprint), hasLength(1));
      expect(repo.nodesForProfile('p2').map((n) => n.name),
          ['node-only-b']);
    });
  });
}
