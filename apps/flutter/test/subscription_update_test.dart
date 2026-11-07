import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

void main() {
  // The subject of this test is the update path: a refresh replaces that
  // subscription's nodes, a locally edited copy survives, and a body that
  // parses to nothing rolls back instead of emptying the list.
  //
  // It used to locate the local copy with `profileId == null`. That was the
  // representation before schema v6, when 本地 was the absence of a profile;
  // since v6 本地 is a real subscription row (`id = 'local'`) and
  // `NodeRepository.insertAll` adopts every orphan, so `profileId == null` is
  // no longer a reachable state on a healthy database. The assertion was
  // therefore checking an invariant the storage layer deliberately removed —
  // and failing for that reason, not because anything regressed.
  //
  // Anchoring on `kLocalProfileId` keeps the original intent (the local copy is
  // still there, with its original server) and makes the test state what the
  // current schema actually promises.
  test(
    'subscription refresh replaces its nodes, preserves local copies and rolls back bad downloads',
    () async {
      final dir = Directory.systemTemp.createTempSync('halo-subscription-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var body = 'trojan://password@first.example:443#original';
      server.listen((request) async {
        request.response.write(body);
        await request.response.close();
      });
      final controller = AppController(dataDir: dir.path);
      try {
        await controller.start(connectHost: false);
        final local = importNodes(body);
        controller.saveImport(local);
        final profile = SubscriptionProfile(
          id: 'test',
          name: 'test',
          url: 'http://127.0.0.1:${server.port}',
        );
        controller.subscriptionRepo.upsert(profile);
        await controller.updateSubscription(profile);
        // One from the paste box, one from the subscription.
        expect(controller.loadNodes(), hasLength(2));

        final original = controller.nodeRepo.nodesForProfile(profile.id).single;
        controller.nodeRepo.update(original.copyWith(name: 'local edit'), nowMs: 1);
        await controller.updateSubscription(profile);
        // A local rename must not survive as the name of the subscription's node.
        expect(controller.nodeRepo.nodesForProfile(profile.id).single.name, 'original');

        body = 'trojan://password@second.example:443#replacement';
        await controller.updateSubscription(profile);
        expect(
          controller.nodeRepo.nodesForProfile(profile.id).single.server,
          'second.example',
        );
        // The pasted copy is untouched by the refresh: it lives under the
        // built-in 本地 subscription, not under the refreshed one.
        final localCopies = controller.nodeRepo.nodesForProfile(kLocalProfileId);
        expect(localCopies, hasLength(1));
        expect(localCopies.single.server, 'first.example');
        // The adoption is what makes that true, so it is asserted rather than
        // assumed: no node may be left outside a subscription.
        expect(
          controller.loadNodes().where((n) => n.profileId == null),
          isEmpty,
          reason: 'schema v6 起不存在无归属节点，本地节点必须挂在 local 订阅下',
        );

        body = 'not a subscription';
        await expectLater(controller.updateSubscription(profile), throwsStateError);
        // A failed download keeps the last good nodes and records why.
        expect(
          controller.nodeRepo.nodesForProfile(profile.id).single.server,
          'second.example',
        );
        expect(controller.subscriptionRepo.profileById(profile.id)!.lastError, isNotNull);
      } finally {
        await controller.dispose();
        await server.close(force: true);
        dir.deleteSync(recursive: true);
      }
    },
  );

  test('a refresh records what it refused, with the entries themselves', () async {
    final dir = Directory.systemTemp.createTempSync('halo-subscription-log-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write(
        'trojan://pw@ok.example:443#ok\n'
        'not-a-link\n'
        // The same node again: skipped, not refused. The window has to tell
        // these two apart, which is why the log records both.
        'trojan://pw@ok.example:443#ok\n',
      );
      await request.response.close();
    });
    final controller = AppController(dataDir: dir.path);
    try {
      await controller.start(connectHost: false);
      const profile = SubscriptionProfile(
        id: 'test',
        name: '测试订阅',
        url: 'http://127.0.0.1:0',
      );
      // The port is only known after bind, so the stored profile is replaced.
      final subscribed = profile.copyWith(url: 'http://127.0.0.1:${server.port}');
      controller.subscriptionRepo.upsert(subscribed);

      final update = await controller.updateSubscription(subscribed);
      expect(update.imported, 1);
      expect(update.failed, 1);
      expect(update.failureKinds, {'malformed_link': 1});
      // The raw entry is what the window shows; without it the count is a
      // number with nothing behind it.
      expect(update.failures.single.raw, 'not-a-link');
      // A duplicate is a skip, not a failure: reporting it as a failure is how
      // "1461 条未导入" made a list with 1580 repeats look like lost nodes.
      expect(update.duplicateCount, 1);
      expect(update.skippedKinds, {'duplicate': 1});
      expect(update.skippedSamples.single.raw, contains('ok.example'));

      final logged = ImportLogRepository(controller.store).recent(limit: 1).single;
      expect(logged['source'], '测试订阅');
      expect(logged['imported'], 1);
      expect(logged['failed'], 1);
      expect(logged['skipped'], 1);
      final detail = jsonDecode('${logged['detail']}') as Map<String, Object?>;
      expect(detail['kinds'], {'malformed_link': 1});
      expect(detail['skippedKinds'], {'duplicate': 1});
      final samples = (detail['samples'] as List).cast<Map<String, Object?>>();
      expect(samples.single['raw'], 'not-a-link');
      expect(samples.single['kind'], 'malformed_link');
      final skipped =
          (detail['skippedSamples'] as List).cast<Map<String, Object?>>();
      expect(skipped.single['kind'], 'duplicate');
    } finally {
      await controller.dispose();
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    }
  });

  test('an empty body reports what the server actually sent', () async {
    // The failing source answers `Cg==` — Base64 of a single newline. The old
    // message ("无法识别的链接") described the parser, not the source.
    final dir = Directory.systemTemp.createTempSync('halo-subscription-empty-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write('Cg==');
      await request.response.close();
    });
    final controller = AppController(dataDir: dir.path);
    try {
      await controller.start(connectHost: false);
      final profile = SubscriptionProfile(
        id: 'empty',
        name: '空订阅',
        url: 'http://127.0.0.1:${server.port}',
      );
      controller.subscriptionRepo.upsert(profile);

      await expectLater(
        controller.updateSubscription(profile),
        throwsA(
          predicate(
            (error) =>
                '$error'.contains('开头：Cg==') &&
                '$error'.contains('已保留旧数据'),
            'mentions the body snippet and that the old nodes were kept',
          ),
        ),
      );
      // A failed refresh must not empty the row.
      expect(
        controller.subscriptionRepo.profileById('empty')!.lastError,
        contains('Cg=='),
      );
    } finally {
      await controller.dispose();
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    }
  });
}
