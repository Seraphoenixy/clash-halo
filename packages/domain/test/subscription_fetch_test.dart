import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// A minimal CONNECT proxy that records what it tunnelled, so a test can prove
/// the request went *through* it rather than merely succeeding.
class FakeConnectProxy {
  FakeConnectProxy._(this._server);

  final ServerSocket _server;
  final List<String> requests = [];
  int established = 0;

  int get port => _server.port;

  static Future<FakeConnectProxy> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = FakeConnectProxy._(server);
    server.listen(proxy._handle);
    return proxy;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    final buffer = <int>[];
    final iterator = StreamIterator<List<int>>(client);
    var headerEnd = -1;
    while (await iterator.moveNext()) {
      buffer.addAll(iterator.current);
      headerEnd =
          utf8.decode(buffer, allowMalformed: true).indexOf('\r\n\r\n');
      if (headerEnd >= 0) break;
    }
    if (headerEnd < 0) {
      client.destroy();
      await iterator.cancel();
      return;
    }
    final header = utf8.decode(buffer, allowMalformed: true);
    final requestLine = header.split('\r\n').first;
    requests.add(requestLine);
    if (!requestLine.startsWith('CONNECT ')) {
      client.write('HTTP/1.1 405 Method Not Allowed\r\n\r\n');
      await client.flush();
      client.destroy();
      await iterator.cancel();
      return;
    }
    final target = requestLine.split(' ')[1];
    final port = int.parse(target.split(':').last);
    final tail = buffer.sublist(headerEnd + 4);

    final upstream = await Socket.connect(InternetAddress.loopbackIPv4, port);
    established++;
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    await client.flush();
    if (tail.isNotEmpty) upstream.add(tail);
    unawaited(() async {
      while (await iterator.moveNext()) {
        upstream.add(iterator.current);
      }
      await upstream.flush();
      upstream.destroy();
    }());
    await client.addStream(upstream);
    await client.flush();
    client.destroy();
  }
}

/// `dart test` runs from a kernel snapshot in a temp directory, so
/// `Platform.script` is useless here; the package root is resolved from the
/// current directory instead, which the documented test command fixes.
SecurityContext _testCertContext() {
  final root = Directory.current.path;
  return SecurityContext()
    ..useCertificateChain('$root/test/fixtures/tls/test_cert.pem')
    ..usePrivateKey('$root/test/fixtures/tls/test_key.pem');
}

/// Serves a fixed body over loopback HTTP.
Future<HttpServer> _serve(String body, {int status = 200}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response.statusCode = status;
    request.response.write(body);
    request.response.close();
  });
  return server;
}

void main() {
  test('a plain fetch returns the body', () async {
    final server = await _serve('trojan://a@b:443#x');
    addTearDown(() => server.close(force: true));

    final body = await SubscriptionFetcher()
        .fetch(Uri.parse('http://127.0.0.1:${server.port}/sub'));

    expect(body, 'trojan://a@b:443#x');
  });

  test('an https subscription really goes through the proxy via CONNECT',
      () async {
    final tls = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      _testCertContext(),
    );
    tls.listen((request) {
      request.response.write('via-proxy');
      request.response.close();
    });
    final proxy = await FakeConnectProxy.start();
    addTearDown(() => tls.close(force: true));
    addTearDown(proxy.close);

    final fetcher = SubscriptionFetcher(
      proxyUrl: 'http://127.0.0.1:${proxy.port}',
      onBadCertificate: (_, _, _) => true,
    );
    final body = await fetcher.fetch(
      Uri.parse('https://127.0.0.1:${tls.port}/sub'),
    );

    // The body alone proves nothing — a direct request returns it too. The
    // proxy's own log is what proves the tunnel carried it, and CONNECT is the
    // form `findProxy` uses for https (plain http uses absolute-form requests).
    expect(body, 'via-proxy');
    expect(proxy.requests, hasLength(1));
    expect(proxy.requests.single, startsWith('CONNECT '));
    expect(proxy.requests.single, contains('127.0.0.1:${tls.port}'));
    expect(proxy.established, 1);
  });

  test('without proxyUrl the proxy sees nothing', () async {
    final server = await _serve('direct');
    final proxy = await FakeConnectProxy.start();
    addTearDown(() => server.close(force: true));
    addTearDown(proxy.close);

    await SubscriptionFetcher()
        .fetch(Uri.parse('http://127.0.0.1:${server.port}/sub'));

    expect(proxy.requests, isEmpty);
  });

  test('a dead proxy names the proxy, not the remote host', () async {
    final fetcher = SubscriptionFetcher(
      timeout: const Duration(seconds: 1),
      proxyUrl: 'http://127.0.0.1:9',
    );

    await expectLater(
      fetcher.fetch(Uri.parse('http://example.test/sub')),
      throwsA(
        isA<SubscriptionFetchException>().having(
          (error) => error.message,
          'message',
          allOf(contains('经代理'), contains('127.0.0.1:9')),
        ),
      ),
    );
  });

  test('proxyUrl accepts a bare host:port', () {
    // No scheme is the shape a port field in the UI has; parsing it must not
    // silently fall back to "direct".
    expect(
      SubscriptionFetcher(proxyUrl: '127.0.0.1:7890').proxyUrl,
      '127.0.0.1:7890',
    );
  });

  test('a non-200 body contributes its hint', () async {
    final server = await _serve('PLEASE CHANGE CLIENT', status: 403);
    addTearDown(() => server.close(force: true));

    await expectLater(
      SubscriptionFetcher(timeout: const Duration(seconds: 2))
          .fetch(Uri.parse('http://127.0.0.1:${server.port}/sub')),
      throwsA(
        isA<SubscriptionFetchException>().having(
          (error) => error.message,
          'message',
          allOf(contains('403'), contains('PLEASE CHANGE CLIENT')),
        ),
      ),
    );
  });

  test('a trickling body is cut off by the total deadline', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final timers = <Timer>[];
    server.listen((request) {
      request.response.bufferOutput = false;
      request.response.write('trojan://');
      timers.add(Timer.periodic(const Duration(milliseconds: 40), (timer) async {
        try {
          request.response.write('x');
          await request.response.flush();
        } on Object {
          timer.cancel();
        }
      }));
    });

    final fetcher = SubscriptionFetcher(
      timeout: const Duration(seconds: 2),
      totalTimeout: const Duration(milliseconds: 300),
    );
    final watch = Stopwatch()..start();
    await expectLater(
      fetcher.fetch(Uri.parse('http://127.0.0.1:${server.port}/sub')),
      throwsA(isA<SubscriptionFetchException>()),
    );
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    for (final timer in timers) {
      timer.cancel();
    }
  });

  test('non-http schemes are refused before opening a socket', () async {
    await expectLater(
      SubscriptionFetcher().fetch(Uri.parse('file:///etc/passwd')),
      throwsA(isA<SubscriptionFetchException>()),
    );
  });
}