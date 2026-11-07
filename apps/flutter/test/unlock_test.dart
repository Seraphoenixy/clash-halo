import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/unlock.dart';
import 'package:halo/src/state/unlock_checks.dart';
import 'package:halo/src/state/unlock_controller.dart';

/// A transport that answers from a table instead of the network.
///
/// The checks exist to read a service's answer correctly, and that reading is
/// what these tests pin. Hitting the live services would make the suite depend
/// on thirteen third parties' current markup and on this machine's exit region.
class _FakeHttp implements UnlockHttp {
  _FakeHttp(this.routes, {this.delay = Duration.zero});

  /// Keyed by a substring of the request URL; the first match wins.
  final Map<String, UnlockResponse Function(Uri url)> routes;
  final Duration delay;
  final List<String> calls = [];
  final List<Map<String, Object?>> jsonBodies = [];
  final List<String> formBodies = [];

  @override
  Future<UnlockResponse> get(
    Uri url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    calls.add(url.toString());
    return _route(url);
  }

  @override
  Future<UnlockResponse> postJson(
    Uri url,
    Object body, {
    Map<String, String>? headers,
  }) async {
    calls.add(url.toString());
    jsonBodies.add(body as Map<String, Object?>);
    return _route(url);
  }

  @override
  Future<UnlockResponse> postForm(
    Uri url,
    Map<String, String> fields, {
    Map<String, String>? headers,
  }) async {
    calls.add(url.toString());
    formBodies.add(Uri(queryParameters: fields).query);
    return _route(url);
  }

  UnlockResponse _route(Uri url) {
    for (final entry in routes.entries) {
      if (url.toString().contains(entry.key)) return entry.value(url);
    }
    throw StateError('没有为 $url 配置响应');
  }

  @override
  void close() {}
}

UnlockResponse _res(
  int status,
  String body, {
  String url = 'https://example.test/',
  Map<String, String> headers = const {},
}) => UnlockResponse(
  status: status,
  finalUrl: Uri.parse(url),
  body: body,
  headers: headers,
);

Future<UnlockVerdict> _run(
  Future<UnlockVerdict> Function(UnlockHttp http) check,
  Map<String, UnlockResponse Function(Uri url)> routes,
) => check(_FakeHttp(routes));

void main() {
  group('transport', () {
    // The three rules below are the ones that decide whether the page tells the
    // truth: a request that escapes the proxy reports this machine's region as
    // the node's, which is the one wrong answer that looks entirely plausible.

    test('every request goes through the given proxy, never direct', () async {
      final seen = <String>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((request) async {
        seen.add('${request.method} ${request.uri}');
        request.response
          ..statusCode = 200
          ..write('proxied');
        await request.response.close();
      });
      final http = IoUnlockHttp(proxy: '127.0.0.1:${proxy.port}');
      try {
        // `.invalid` never resolves, so a 200 can only have come from the
        // proxy: a direct request could not have produced one.
        final response = await http.get(Uri.parse('http://unlock.invalid/probe'));
        expect(response.status, 200);
        expect(response.body, 'proxied');
        expect(seen.single, contains('unlock.invalid/probe'));
      } finally {
        http.close();
        await proxy.close(force: true);
      }
    });

    test('a dead proxy fails instead of quietly falling back to direct', () async {
      // Port 1 is closed. A client that retried without the proxy would still
      // reach the real service and turn a broken setup into a confident verdict.
      final http = IoUnlockHttp(
        proxy: '127.0.0.1:1',
        timeout: const Duration(seconds: 5),
      );
      try {
        await expectLater(
          http.get(Uri.parse('http://example.com/')),
          throwsA(anything),
        );
      } finally {
        http.close();
      }
    });
  });

  group('verdict presentation', () {
    test('tone separates "not checked" from "does not work"', () {
      // 未检测 must not borrow the colour of a failure, and every compound
      // "No (...)" / "Failed (...)" the checks can emit must land in the same
      // bucket as the plain form.
      expect(unlockTone(UnlockStatus.pending), UnlockTone.pending);
      expect(unlockTone(''), UnlockTone.pending);
      expect(unlockTone(UnlockStatus.yes), UnlockTone.ok);
      expect(unlockTone(UnlockStatus.no), UnlockTone.bad);
      expect(unlockTone('No (IP Banned By Netflix)'), UnlockTone.bad);
      expect(unlockTone('No (IP Banned By Disney+)'), UnlockTone.bad);
      expect(unlockTone('Failed (GraphQL: 403)'), UnlockTone.bad);
      expect(unlockTone(UnlockStatus.originalsOnly), UnlockTone.bad);
      expect(unlockTone(UnlockStatus.unsupportedRegion), UnlockTone.bad);
      expect(unlockTone(UnlockStatus.risky), UnlockTone.warn);
      expect(unlockTone(UnlockStatus.soon), UnlockTone.warn);
    });

    test('labels translate the known verdicts and pass the rest through', () {
      expect(unlockStatusLabel(UnlockStatus.yes), '解锁');
      expect(unlockStatusLabel(UnlockStatus.no), '不支持');
      expect(unlockStatusLabel('No (IP Banned By Disney+)'), 'IP 被封禁');
      expect(unlockStatusLabel(UnlockStatus.pending), '未检测');
      // A compound verdict is its own explanation; replacing it with a label
      // would throw away the only diagnostic the user has.
      expect(unlockStatusLabel('Failed (GraphQL: 403)'), 'Failed (GraphQL: 403)');
    });

    test('a region is displayed in one form: alpha-2, no flag', () async {
      // The reference client builds "flag + code". Windows has no flag glyphs,
      // so the two regional indicators render as their own letters and `JP`
      // reached the screen as `JPJP`; Gemini's alpha-3 made one card read `KOR`
      // next to twelve reading `KR`. Both are fixed by showing just alpha-2.
      expect(unlockRegionLabel('us'), 'US');
      expect(unlockRegionLabel('JP'), 'JP');
      expect(unlockRegionLabel('KOR'), 'KR');
      expect(unlockRegionLabel('USA'), 'US');
      expect(unlockRegionLabel('HKG'), 'HK');
      expect(unlockRegionLabel('MAC'), 'MO');
      // No regional-indicator code point may survive into the label: those are
      // exactly the characters Windows cannot draw.
      for (final label in ['US', 'JP', 'KR', 'SG']) {
        final shown = unlockRegionLabel(label);
        expect(
          shown.runes.any((r) => r >= 0x1F1E6 && r <= 0x1F1FF),
          isFalse,
          reason: '区域标签不能含旗帜字符（$shown）',
        );
      }
      // An unknown three-letter code is shown as-is rather than guessed at.
      expect(unlockRegionLabel('ZZZ'), 'ZZZ');
      expect(unlockRegionLabel(''), '');
      expect(unlockRegionLabel('--'), '--');
    });
  });

  group('checks', () {
    test('ChatGPT reports an unsupported region as its own verdict', () {
      // "Unsupported Country/Region" is not "Failed": the service answered, and
      // the answer is about policy. Collapsing it into Failed would send the
      // user hunting for a network problem that does not exist.
      return _run(checkChatGpt, {
        'chat.openai.com/cdn-cgi/trace': (_) => _res(200, 'ip=1.2.3.4\nloc=HK\n'),
        'cookie_requirements': (_) =>
            _res(200, '{"unsupported_country":true}'),
      }).then((verdict) {
        expect(verdict.status, UnlockStatus.unsupportedRegion);
        expect(verdict.region, 'HK');
      });
    });

    test('Claude uses its own blocked-country list', () async {
      final blocked = await _run(checkClaude, {
        'claude.ai/cdn-cgi/trace': (_) => _res(200, 'loc=CN\n'),
      });
      expect(blocked.status, UnlockStatus.no);
      expect(blocked.region, 'CN');

      final allowed = await _run(checkClaude, {
        'claude.ai/cdn-cgi/trace': (_) => _res(200, 'loc=JP\n'),
      });
      expect(allowed.status, UnlockStatus.yes);
    });

    test('Bilibili maps its license code, not the HTTP status', () async {
      // The API answers 200 in both cases; only `code` carries the verdict.
      final ok = await _run(checkBilibiliMainland, {
        'bilibili': (_) => _res(200, '{"code":0}'),
      });
      expect(ok.status, UnlockStatus.yes);

      final region = await _run(checkBilibiliMainland, {
        'bilibili': (_) => _res(200, '{"code":-10403}'),
      });
      expect(region.status, UnlockStatus.no);

      final weird = await _run(checkBilibiliMainland, {
        'bilibili': (_) => _res(200, '{"code":-412}'),
      });
      expect(weird.status, UnlockStatus.failed);
    });

    test('YouTube distinguishes "not available here" from a broken page', () async {
      final no = await _run(checkYouTubePremium, {
        'youtube.com/premium': (_) => _res(
          200,
          '"GL":"DE" YouTube Premium is not available in your country',
        ),
      });
      expect(no.status, UnlockStatus.no);
      expect(no.region, 'DE');

      final yes = await _run(checkYouTubePremium, {
        'youtube.com/premium': (_) => _res(200, '"GL":"US" Ad-free YouTube Premium'),
      });
      expect(yes.status, UnlockStatus.yes);

      final broken = await _run(checkYouTubePremium, {
        'youtube.com/premium': (_) => _res(200, '<html>consent</html>'),
      });
      expect(broken.status, UnlockStatus.failed);
    });

    test('Netflix reports a banned IP from the CDN answer', () async {
      // Fast.com refusing the exit is a different verdict from "no catalogue",
      // and the reference client calls it out explicitly.
      final banned = await _run(checkNetflix, {
        'api.fast.com': (_) => _res(403, ''),
      });
      expect(banned.status, 'No (IP Banned By Netflix)');
      expect(unlockTone(banned.status), UnlockTone.bad);

      final region = await _run(checkNetflix, {
        'api.fast.com': (_) => _res(
          200,
          '{"targets":[{"location":{"country":"sg"}}]}',
        ),
      });
      expect(region.status, UnlockStatus.yes);
      expect(region.region, 'SG');
    });

    test('Netflix falls back to the catalogue when the CDN says nothing', () async {
      // Both titles 404 means the catalogue is not this exit's, which the
      // reference reports as "Originals Only" rather than a failure.
      final originalsOnly = await _run(checkNetflix, {
        'api.fast.com': (_) => _res(500, ''),
        'netflix.com/title/81280792': (_) => _res(404, ''),
        'netflix.com/title/70143836': (_) => _res(404, ''),
      });
      expect(originalsOnly.status, UnlockStatus.originalsOnly);

      final blocked = await _run(checkNetflix, {
        'api.fast.com': (_) => _res(500, ''),
        'netflix.com/title/81280792': (_) => _res(403, ''),
        'netflix.com/title/70143836': (_) => _res(404, ''),
      });
      expect(blocked.status, UnlockStatus.no);
    });

    test('Netflix reads the region out of the redirect', () async {
      final verdict = await _run(checkNetflix, {
        'api.fast.com': (_) => _res(500, ''),
        'netflix.com/title/81280792': (_) => _res(301, ''),
        'netflix.com/title/70143836': (_) => _res(404, ''),
        'netflix.com/title/80018499': (_) => _res(
          301,
          '',
          headers: {'location': 'https://www.netflix.com/tw/title/80018499'},
        ),
      });
      expect(verdict.status, UnlockStatus.yes);
      expect(verdict.region, 'TW');
    });

    test('Spotify treats a restricted status as a verdict', () async {
      final no = await _run(checkSpotify, {
        'country-selector': (_) => _res(403, ''),
      });
      expect(no.status, UnlockStatus.no);

      final yes = await _run(checkSpotify, {
        'country-selector': (url) => _res(
          200,
          '{"countryCode":"gb"}',
          url: 'https://www.spotify.com/',
        ),
      });
      expect(yes.status, UnlockStatus.yes);
      expect(yes.region, 'GB');
    });

    test('TikTok reads the trace region and the deny text', () async {
      final no = await _run(checkTikTok, {
        'tiktok.com/cdn-cgi/trace': (_) =>
            _res(200, 'loc=US\n"region":"US-CA" access denied'),
      });
      expect(no.status, UnlockStatus.no);

      final yes = await _run(checkTikTok, {
        'tiktok.com/cdn-cgi/trace': (_) => _res(200, '"region":"JP-13"'),
      });
      expect(yes.status, UnlockStatus.yes);
      expect(yes.region, 'JP');
    });

    test('Prime Video reports a restricted service as unavailable', () async {
      final restricted = await _run(checkPrimeVideo, {
        'primevideo.com': (_) => _res(200, 'var isServiceRestricted = true;'),
      });
      expect(restricted.status, 'No (Service Not Available)');

      final ok = await _run(checkPrimeVideo, {
        'primevideo.com': (_) => _res(200, '{"currentTerritory":"US"}'),
      });
      expect(ok.status, UnlockStatus.yes);
      expect(ok.region, 'US');
    });

    test('Muse is called out as uncertain behind its anti-bot gateway', () async {
      // The exit reached Muse's auth infrastructure; whether the app works
      // cannot be decided over plain HTTP, so claiming "解锁" would be a guess.
      final verdict = await _run(checkMuseAi, {
        'cloudflare.com/cdn-cgi/trace': (_) => _res(200, 'loc=US\n'),
        'muse.ai': (url) => _res(
          200,
          'static.facebook.com/images/logos',
          url: 'https://auth.muse.ai/',
        ),
      });
      expect(verdict.status, UnlockStatus.risky);
      expect(unlockTone(verdict.status), UnlockTone.warn);
    });

    test('Gemini accepts both quoting shapes it has been observed to use', () async {
      // Live, the page answers `,2,1,200,"KOR"`. The reference client matches
      // the escaped form (`,2,1,200,\"KOR"`), which is the same value inside a
      // JS string. Matching only the escaped one made a working exit report
      // 检测失败 — found by running the sweep against a real node.
      final plain = await _run(checkGemini, {
        'gemini.google.com': (_) => _res(200, ',2,1,200,"KOR"'),
      });
      expect(plain.status, UnlockStatus.yes);
      // Gemini answers alpha-3; the page shows the same alpha-2 form as the
      // other twelve badges, so the card does not read `KOR` next to `KR`.
      expect(plain.region, 'KR');

      final escaped = await _run(checkGemini, {
        'gemini.google.com': (_) => _res(200, r'x,2,1,200,\"HKG"y'),
      });
      expect(escaped.status, UnlockStatus.no);
      expect(escaped.region, 'HK');

      final noMarker = await _run(checkGemini, {
        'gemini.google.com': (_) => _res(200, '<html>consent</html>'),
      });
      expect(noMarker.status, UnlockStatus.failed);
    });

    test('Bahamut walks the device token and reads an HTML attribute region', () async {
      final verdict = await _run(checkBahamutAnime, {
        'getdeviceid.php': (_) => _res(200, '{"deviceid":"d1"}'),
        'token.php': (_) => _res(200, '{"animeSn":37783}'),
        // The region is an attribute, not a JSON field: the first version
        // reused the JSON field reader here and silently reported no region.
        'ani.gamer.com.tw/': (_) => _res(200, '<body data-geo="TW">'),
      });
      expect(verdict.status, UnlockStatus.yes);
      expect(verdict.region, 'TW');

      final no = await _run(checkBahamutAnime, {
        'getdeviceid.php': (_) => _res(200, '{"deviceid":"d1"}'),
        'token.php': (_) => _res(200, '{"error":"region"}'),
      });
      expect(no.status, UnlockStatus.no);
    });

    test('Disney+ walks the device handshake to reach a region', () async {
      // Three requests, and the region only exists in the third response: a
      // check that stopped after the token exchange would have no answer.
      final fake = _FakeHttp({
        'bamgrid.com/devices': (_) => _res(200, '{"assertion":"A"}'),
        'bamgrid.com/token': (_) => _res(200, '{"refresh_token":"R"}'),
        'disneyplus.com': (url) => _res(200, '', url: 'https://www.disneyplus.com/'),
        'graphql': (_) => _res(
          200,
          '{"data":{"refreshToken":{"activeSession":{"sessionId":"s",'
          '"countryCode":"NL","inSupportedLocation":true}}}}',
        ),
      });
      final verdict = await checkDisneyPlus(fake);
      expect(verdict.status, UnlockStatus.yes);
      expect(verdict.region, 'NL');
      // The assertion must travel in the token exchange; without it Disney+
      // answers 400 and the check would report a failure that is our bug.
      expect(fake.formBodies.single, contains('subject_token=A'));
    });

    test('Disney+ reports a banned exit before trying the session', () async {
      final verdict = await _run(checkDisneyPlus, {
        'bamgrid.com/devices': (_) => _res(403, ''),
      });
      expect(verdict.status, 'No (IP Banned By Disney+)');
    });

    test('a transport failure is a verdict, not an aborted sweep', () async {
      // The fake has no route for this host, so the check throws. The page must
      // still receive an item, or the card would stay on 未检测 forever.
      final verdict = await checkChatGpt(_FakeHttp(const {}));
      expect(verdict.status, UnlockStatus.failed);
    });
  });

  group('UnlockController', () {
    test('a sweep fills every card and persists once', () async {
      final persisted = <UnlockSnapshot>[];
      final unlock = UnlockController(
        proxyResolver: () => '127.0.0.1:7890',
        onPersist: persisted.add,
        httpFactory: (_) => _FakeHttp({
          'cdn-cgi/trace': (_) => _res(200, 'loc=US\n'),
          'cookie_requirements': (_) => _res(200, '{}'),
          'claude.ai': (_) => _res(200, 'loc=US\n'),
          'gemini.google.com': (_) => _res(200, r',2,1,200,\"USA"'),
          'youtube.com/premium': (_) => _res(200, '"GL":"US" YouTube Premium'),
          'bilibili': (_) => _res(200, '{"code":0}'),
          'spotify.com': (_) => _res(200, '{"countryCode":"US"}'),
          'tiktok.com': (_) => _res(200, '"region":"US-1"'),
          'primevideo.com': (_) => _res(200, '{"currentTerritory":"US"}'),
          'ani.gamer.com.tw/ajax/getdeviceid.php': (_) => _res(200, '{"deviceid":"d"}'),
          'ani.gamer.com.tw/ajax/token.php': (_) => _res(200, '{"animeSn":1}'),
          'ani.gamer.com.tw/': (_) => _res(200, '"data-geo":"TW"'),
          'muse.ai': (_) => _res(200, 'ok'),
          'cloudflare.com/cdn-cgi/trace': (_) => _res(200, 'loc=US\n'),
          'api.fast.com': (_) => _res(200, '{"targets":[{"location":{"country":"US"}}]}'),
          'bamgrid.com/devices': (_) => _res(200, '{"assertion":"A"}'),
          'bamgrid.com/token': (_) => _res(200, '{"refresh_token":"R"}'),
          'disneyplus.com': (url) => _res(200, '', url: 'https://www.disneyplus.com/'),
          'graphql': (_) => _res(200, '{"countryCode":"US","inSupportedLocation":true}'),
        }),
      );

      expect(unlock.checkedCount, 0);
      await unlock.checkAll();
      expect(unlock.checkedCount, unlock.total);
      expect(unlock.complete, isTrue);
      expect(unlock.running, isFalse);
      expect(unlock.error, isNull);
      // One write at the end, not one per card: thirteen writes would be
      // thirteen transactions for a single user action.
      expect(persisted, hasLength(1));
      expect(persisted.single.items, hasLength(unlock.total));
    });

    test('without a running core it refuses instead of failing every card', () async {
      final unlock = UnlockController(
        proxyResolver: () => null,
        httpFactory: (_) => _FakeHttp(const {}),
      );
      await unlock.checkAll();
      expect(unlock.error, isNotNull);
      expect(unlock.checkedCount, 0);
      expect(unlock.running, isFalse);
    });

    test('cancel drops the results still in flight', () async {
      final unlock = UnlockController(
        proxyResolver: () => '127.0.0.1:7890',
        httpFactory: (_) => _FakeHttp(
          {
            'cdn-cgi/trace': (_) => _res(200, 'loc=US\n'),
            'bilibili': (_) => _res(200, '{"code":0}'),
          },
          delay: const Duration(milliseconds: 30),
        ),
      );
      final sweep = unlock.checkAll();
      unlock.cancel();
      await sweep;
      // A cancelled sweep must not leave half a page claiming to be current.
      expect(unlock.items.every((item) => item.isPending), isTrue);
      expect(unlock.running, isFalse);
    });

    test('checkOne replaces only its own card', () async {
      final unlock = UnlockController(
        proxyResolver: () => '127.0.0.1:7890',
        httpFactory: (_) => _FakeHttp({
          'cdn-cgi/trace': (_) => _res(200, 'loc=JP\n'),
        }),
      );
      await unlock.checkOne('claude');
      expect(unlock.items.firstWhere((i) => i.id == 'claude').status, isNot(UnlockStatus.pending));
      expect(unlock.checkedCount, 1);
    });

    test('restore keeps catalogue order and survives an older stored list', () {
      final unlock = UnlockController(proxyResolver: () => null);
      unlock.restore(UnlockSnapshot(items: [
        // An id this version does not have must be ignored, not crash.
        const UnlockItem(id: 'removed_service', name: 'Gone', status: UnlockStatus.yes),
        const UnlockItem(
          id: 'netflix',
          name: 'Netflix',
          status: UnlockStatus.yes,
          region: 'US',
          checkedAtMs: 42,
        ),
      ]));
      expect(unlock.items.first.id, 'netflix');
      expect(unlock.items.first.status, UnlockStatus.yes);
      expect(unlock.lastCheckedAtMs, 42);
    });

    test('a stored sweep keeps the node it describes', () {
      const snapshot = UnlockSnapshot(
        items: [
          UnlockItem(
            id: 'netflix',
            name: 'Netflix',
            status: UnlockStatus.yes,
            checkedAtMs: 7,
          ),
        ],
        nodeId: 'n1',
        nodeName: 'CN-WS-CDN',
      );
      final restored = UnlockSnapshot.fromJson(snapshot.toJson())!;
      expect(restored.nodeId, 'n1');
      expect(restored.nodeName, 'CN-WS-CDN');
      expect(restored.items.single.id, 'netflix');

      // The bare-list shape an earlier build wrote still loads; only the node
      // label is lost, which is not a reason to throw the verdicts away.
      final legacy = UnlockSnapshot.fromJson([
        {'id': 'netflix', 'name': 'Netflix', 'status': 'Yes', 'checkedAtMs': 7},
      ])!;
      expect(legacy.nodeId, isNull);
      expect(legacy.items.single.status, UnlockStatus.yes);

      expect(UnlockSnapshot.fromJson('nonsense'), isNull);
      expect(UnlockSnapshot.fromJson(const <Object?>[]), isNull);
    });

    test('a sweep labels its verdicts with the node that produced them', () async {
      final unlock = UnlockController(
        proxyResolver: () => '127.0.0.1:7890',
        nodeResolver: () => (id: 'n1', name: 'CN-WS-CDN'),
        httpFactory: (_) => _FakeHttp({
          'cdn-cgi/trace': (_) => _res(200, 'loc=JP\n'),
        }),
      );
      await unlock.checkOne('claude');
      expect(unlock.checkedNodeId, 'n1');
      expect(unlock.checkedNodeName, 'CN-WS-CDN');
    });

    test('verdicts from another node are called out, not passed off as current', () {
      final unlock = UnlockController(proxyResolver: () => null);
      // Nothing measured yet: there is nothing to be stale about.
      expect(unlock.staleFor('n2'), isFalse);

      unlock.restore(
        const UnlockSnapshot(
          items: [
            UnlockItem(
              id: 'netflix',
              name: 'Netflix',
              status: UnlockStatus.yes,
              checkedAtMs: 1,
            ),
          ],
          nodeId: 'n1',
          nodeName: 'CN-WS-CDN',
        ),
      );
      expect(unlock.staleFor('n1'), isFalse);
      expect(unlock.staleFor('n2'), isTrue);
      // No active node at all is not a mismatch: the page already says so.
      expect(unlock.staleFor(null), isFalse);
      expect(unlock.staleFor(''), isFalse);
    });
  });
}
