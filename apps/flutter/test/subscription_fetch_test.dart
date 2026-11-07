import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo_domain/halo_domain.dart';

/// What a subscription refresh does with a real airport response.
///
/// Both behaviours here were found by pointing the app at an actual
/// subscription: the provider answered `403 PLEASE CHANGE CLIENT` until the
/// request carried a client User-Agent, and the body mixed AnyTLS entries with
/// a couple of info rows, which the old code treated as a total failure.
void main() {
  late Directory dir;
  late HttpServer server;
  late AppController controller;
  var body = '';
  var status = 200;
  final userAgents = <String>[];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-sub-ua-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      userAgents.add(request.headers.value(HttpHeaders.userAgentHeader) ?? '');
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
    controller = AppController(dataDir: dir.path);
    await controller.start(connectHost: false);
  });

  tearDown(() async {
    await controller.dispose();
    await server.close(force: true);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<SubscriptionUpdate> refresh() {
    final profile = SubscriptionProfile(
      id: 'test',
      name: 'test',
      url: 'http://127.0.0.1:${server.port}/sub',
    );
    controller.subscriptionRepo.upsert(profile);
    return controller.updateSubscription(profile);
  }

  test('the download carries a client User-Agent', () async {
    // Providers both gate on this header and pick the response format with it,
    // so leaving it as the Dart default is what turns a working subscription
    // into `403 PLEASE CHANGE CLIENT`.
    body = 'trojan://pw@a.example.com:443#a';
    await refresh();
    expect(userAgents, isNotEmpty);
    expect(userAgents.last, AppController.subscriptionUserAgent);
  });

  test('one unsupported node does not cost the user the whole list', () async {
    body = '''
proxies:
  - { name: good1, type: anytls, server: a.example.com, port: 443, password: p1 }
  - { name: odd, type: mieru, server: b.example.com, port: 443, password: p2 }
  - { name: good2, type: anytls, server: c.example.com, port: 443, password: p3 }
''';
    final result = await refresh();
    expect(result.imported, 2);
    expect(result.failed, 1);
    expect(result.partial, isTrue);
    expect(result.firstFailure, contains('不支持的协议'));
    // The two usable nodes really are in the database.
    expect(controller.nodeRepo.nodesForProfile('test'), hasLength(2));
    expect(controller.subscriptionRepo.profileById('test')!.nodeCount, 2);
  });

  test('a list with nothing usable is still a failed refresh', () async {
    // The complement: accepting partial results must not turn a body that
    // parsed to nothing into a silent "0 个节点".
    body = 'not a subscription at all';
    await expectLater(refresh(), throwsStateError);
    expect(controller.subscriptionRepo.profileById('test')!.lastError, isNotNull);
  });

  test('a client-rejection response explains itself', () async {
    status = 403;
    body = 'PLEASE CHANGE CLIENT';
    await expectLater(
      refresh(),
      throwsA(
        predicate<Object>(
          (e) => '$e'.contains('PLEASE CHANGE CLIENT') && '$e'.contains('403'),
          '错误里要带上服务端给的理由',
        ),
      ),
    );
  });
}
