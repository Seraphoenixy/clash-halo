import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// The `{date}` look-back: which status codes may trigger it, and what the
/// caller is told about the file it ended up with.
///
/// The important rule is that *only* a 404 falls back. A timeout or a 5xx is a
/// property of the source or the network and will repeat for every candidate, so
/// retrying seven of them would make a real failure take seven times as long to
/// report without any chance of succeeding.
void main() {
  /// Serves per-path responses. `hits` records the paths requested, in order.
  Future<(HttpServer, List<String>)> serve(
    Future<void> Function(HttpRequest) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hits = <String>[];
    server.listen((request) async {
      hits.add(request.uri.path);
      await handler(request);
    });
    addTearDown(() => server.close(force: true));
    return (server, hits);
  }

  String base(HttpServer s) => 'http://127.0.0.1:${s.port}';

  /// Answers 200 for [okPath], 404 for everything else.
  Future<void> Function(HttpRequest) onlyOk(String okPath) =>
      (request) async {
        if (request.uri.path == okPath) {
          request.response.write('node-body');
        } else {
          request.response.statusCode = 404;
          request.response.write('404: Not Found');
        }
        await request.response.close();
      };

  test('a 404 on today falls back and reports which file was used', () async {
    // today = 2026-11-06 -> /v20261106 is missing, /v20261105 exists
    final (server, hits) = await serve(onlyOk('/v20261105'));

    final download = await SubscriptionFetcher()
        .fetchWithDateFallback(
          '${base(server)}/v{date}',
          now: DateTime(2026, 11, 6),
        );

    expect(download.body, 'node-body');
    expect(hits, ['/v20261106', '/v20261105']);
    expect(download.usedUrl, '${base(server)}/v20261105');
    expect(download.fallbackDays, 1);
    expect(download.usedFallback, isTrue);
  });

  test('today\'s file is preferred when it exists', () async {
    final (server, hits) = await serve(onlyOk('/v20261106'));

    final download = await SubscriptionFetcher()
        .fetchWithDateFallback(
          '${base(server)}/v{date}',
          now: DateTime(2026, 11, 6),
        );

    // Exactly one request: no speculative look-back when today works.
    expect(hits, ['/v20261106']);
    expect(download.fallbackDays, 0);
    expect(download.usedFallback, isFalse);
  });

  test('a 500 does not fall back, it fails immediately', () async {
    final (server, hits) = await serve((request) async {
      request.response.statusCode = 500;
      request.response.write('bad gateway');
      await request.response.close();
    });

    await expectLater(
      SubscriptionFetcher().fetchWithDateFallback(
        '${base(server)}/v{date}',
        now: DateTime(2026, 11, 6),
      ),
      throwsA(isA<SubscriptionFetchException>()),
    );
    // One attempt only: a 5xx is not "the file is not published yet".
    expect(hits, ['/v20261106']);
  });

  test('every candidate 404 means a real failure', () async {
    final (server, hits) = await serve((request) async {
      request.response.statusCode = 404;
      await request.response.close();
    });

    await expectLater(
      SubscriptionFetcher().fetchWithDateFallback(
        '${base(server)}/v{date}',
        now: DateTime(2026, 11, 6),
      ),
      throwsA(
        isA<SubscriptionFetchException>()
            .having((e) => e.message, 'message', contains('404')),
      ),
    );
    // It did try the whole bounded window.
    expect(hits, hasLength(kDateLookbackDays + 1));
  });

  test('a URL without a placeholder is fetched once, as written', () async {
    final (server, hits) = await serve(onlyOk('/stable'));

    final download = await SubscriptionFetcher()
        .fetchWithDateFallback('${base(server)}/stable');

    expect(hits, ['/stable']);
    expect(download.usedFallback, isFalse);
    expect(download.body, 'node-body');
  });

  test('a 404 on a non-templated URL is not retried', () async {
    final (server, hits) = await serve((request) async {
      request.response.statusCode = 404;
      await request.response.close();
    });

    await expectLater(
      SubscriptionFetcher().fetchWithDateFallback('${base(server)}/stable'),
      throwsA(isA<SubscriptionFetchException>()),
    );
    expect(hits, ['/stable']);
  });
}