import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo_domain/halo_domain.dart';

const _body = 'trojan://pw@ok.example:443#ok';

/// Records the first request line, then either serves [_body] or fails.
///
/// A minimal HTTP proxy: enough to prove a download was routed through it (a
/// direct fetch never reaches this socket), and with `body == null` it fails
/// fast instead of waiting for a network timeout. It answers only after the
/// request line has arrived, so the recorded call is never a race with the
/// response.
class _FakeProxy {
  _FakeProxy(this._socket);

  final ServerSocket _socket;
  final List<String> requests = [];

  int get port => _socket.port;

  static Future<_FakeProxy> start({String? body}) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _FakeProxy(socket);
    socket.listen((client) {
      var buffer = '';
      var answered = false;
      client.listen((data) {
        if (answered) return;
        buffer += String.fromCharCodes(data);
        final end = buffer.indexOf('\r\n');
        if (end < 0) return;
        answered = true;
        proxy.requests.add(buffer.substring(0, end));
        final response = body == null
            ? 'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n'
            : 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
                  'Content-Length: ${body.length}\r\n\r\n$body';
        client.write(response);
        client.flush().then((_) => client.destroy());
      });
    });
    return proxy;
  }

  Future<void> close() => _socket.close();
}

/// Which channel a refresh actually used, observed from the sockets.
///
/// The window's two batch buttons differ only in this decision, and a wrong
/// one is invisible in the UI: both show "已更新". These tests therefore look
/// at who received the request, not at what the page said.
void main() {
  late Directory dir;
  late AppController controller;
  late HttpServer direct;
  late List<String> directRequests;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-channel-');
    controller = AppController(dataDir: dir.path);
    await controller.start(connectHost: false);
    directRequests = [];
    direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    direct.listen((request) async {
      directRequests.add(request.uri.toString());
      request.response.write(_body);
      await request.response.close();
    });
  });

  tearDown(() async {
    await controller.dispose();
    await direct.close(force: true);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // A lingering WAL file on Windows can keep the directory busy.
    }
  });

  Future<_FakeProxy> fakeProxy({String? body}) async {
    final proxy = await _FakeProxy.start(body: body);
    addTearDown(proxy.close);
    return proxy;
  }

  /// Inserts the row the way the window does, then refreshes it.
  Future<SubscriptionUpdate> refresh(
    SubscriptionProfile row, {
    bool viaProxy = false,
  }) async {
    controller.subscriptionRepo.upsert(row);
    return controller.updateSubscription(row, viaProxy: viaProxy);
  }

  SubscriptionProfile profile({
    bool? useProxy,
    String? url,
    required _FakeProxy proxy,
  }) => SubscriptionProfile(
    id: 'p',
    name: 'p',
    url: url ?? 'http://127.0.0.1:${direct.port}/sub',
    useProxy: useProxy,
    proxyUrl: 'http://127.0.0.1:${proxy.port}',
  );

  test('a row set to 经代理 is downloaded through the proxy', () async {
    final proxy = await fakeProxy(body: _body);
    final row = profile(useProxy: true, proxy: proxy);
    final result = await refresh(row);

    expect(result.imported, 1);
    expect(result.viaProxy, isTrue);
    expect(proxy.requests, hasLength(1));
    expect(
      proxy.requests.single,
      contains('127.0.0.1:${direct.port}'),
      reason: '代理收到的是绝对形式请求，目标应是源站',
    );
    expect(directRequests, isEmpty, reason: '经代理的行不得到达源站直连');
  });

  test('a row set to 直连 is downloaded directly', () async {
    final proxy = await fakeProxy(body: _body);
    final row = profile(useProxy: false, proxy: proxy);
    final result = await refresh(row);

    expect(result.imported, 1);
    expect(result.viaProxy, isFalse);
    expect(directRequests, hasLength(1));
    expect(proxy.requests, isEmpty, reason: '直连的行不得经代理');
    expect(controller.nodeRepo.nodesForProfile('p'), hasLength(1));
  });

  test('a row with no choice follows the source policy', () async {
    // GitHub content hosts are the documented default: proxy. The fake proxy
    // receives CONNECT instead of the request reaching the network.
    final proxy = await fakeProxy();
    final row = profile(
      url: 'https://raw.githubusercontent.com/o/r/main/list.txt',
      proxy: proxy,
    );
    await expectLater(refresh(row), throwsA(anything));
    expect(proxy.requests, hasLength(1));
    expect(proxy.requests.single, startsWith('CONNECT raw.githubusercontent.com'));
  });

  test('the forced proxy overrides a row set to 直连', () async {
    final proxy = await fakeProxy(body: _body);
    final row = profile(useProxy: false, proxy: proxy);
    final result = await refresh(row, viaProxy: true);

    expect(result.viaProxy, isTrue, reason: 'viaProxy 应无视该行的直连设置');
    expect(proxy.requests, hasLength(1));
    expect(directRequests, isEmpty);
  });
}
