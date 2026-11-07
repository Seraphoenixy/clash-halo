import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/exit_info.dart';
import 'package:halo/src/state/home_cards.dart';
import 'package:halo/src/state/routing_settings.dart';
import 'package:halo/src/state/app_controller.dart';

/// The home page's two new pieces of state, both of which are easy to get
/// subtly wrong: which cards survive a settings round-trip, and what the exit
/// lookup reports when a service is down.
void main() {
  group('home cards', () {
    test('everything is visible by default', () {
      final cards = HomeCards.defaults;
      for (final card in HomeCard.values) {
        expect(cards.isVisible(card), isTrue, reason: card.name);
      }
    });

    test('toggling one card leaves the others alone', () {
      final cards = HomeCards.defaults.toggle(HomeCard.tun).toggle(HomeCard.exit);
      expect(cards.isVisible(HomeCard.tun), isFalse);
      expect(cards.isVisible(HomeCard.exit), isFalse);
      expect(cards.isVisible(HomeCard.node), isTrue);
      expect(cards.isVisible(HomeCard.status), isTrue);
      // And back.
      expect(cards.toggle(HomeCard.tun).isVisible(HomeCard.tun), isTrue);
    });

    test('the hidden set survives a settings round-trip', () async {
      final dir = Directory.systemTemp.createTempSync('halo-home-cards');
      final controller = AppController(dataDir: dir.path);
      try {
        await controller.start(connectHost: false);
        final saved = HomeCards.defaults.toggle(HomeCard.traffic);
        saved.save(controller.settingsRepo);
        final loaded = HomeCards.load(controller.settingsRepo);
        expect(loaded.isVisible(HomeCard.traffic), isFalse);
        expect(loaded.isVisible(HomeCard.node), isTrue);
      } finally {
        await controller.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('a card added by a later version is visible for an existing user', () {
      // Regression for storing the visible list: that made every future card
      // invisible to anyone who had ever hidden one.
      final dir = Directory.systemTemp.createTempSync('halo-home-cards-2');
      final controller = AppController(dataDir: dir.path);
      addTearDown(() async {
        await controller.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      return controller.start(connectHost: false).then((_) {
        // A stored value written by a version that only knew some of the cards.
        controller.settingsRepo.setJson(HomeCards.storageKey, ['traffic']);
        final loaded = HomeCards.load(controller.settingsRepo);
        expect(loaded.isVisible(HomeCard.traffic), isFalse);
        // Every card the stored value does not mention stays visible, which is
        // what makes a newly added card appear instead of being swallowed.
        for (final card in HomeCard.values) {
          if (card == HomeCard.traffic) continue;
          expect(loaded.isVisible(card), isTrue, reason: card.name);
        }
      });
    });

    test('an unknown stored id is ignored rather than hiding anything', () {
      final dir = Directory.systemTemp.createTempSync('halo-home-cards-3');
      final controller = AppController(dataDir: dir.path);
      addTearDown(() async {
        await controller.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      return controller.start(connectHost: false).then((_) {
        controller.settingsRepo.setJson(HomeCards.storageKey, ['removed_card', 42]);
        final loaded = HomeCards.load(controller.settingsRepo);
        for (final card in HomeCard.values) {
          expect(loaded.isVisible(card), isTrue, reason: card.name);
        }
      });
    });
  });

  group('exit info', () {
    test('each service shape is read into the same model', () {
      final ipSb = ExitInfo.fromIpSb({
        'ip': '1.2.3.4',
        'country_code': 'JP',
        'country': 'Japan',
        'region': 'Tokyo',
        'city': 'Chiyoda',
        'organization': 'Example ISP',
        'asn': 2516,
        'timezone': 'Asia/Tokyo',
      })!;
      expect(ipSb.ip, '1.2.3.4');
      expect(ipSb.location, 'Japan · Tokyo · Chiyoda');
      expect(ipSb.asnLabel, 'AS2516');
      expect(ipSb.network, 'Example ISP · AS2516');

      // ipapi.co sends the ASN as a string.
      final ipapiCo = ExitInfo.fromIpapiCo({
        'ip': '5.6.7.8',
        'country_code': 'KR',
        'country_name': 'South Korea',
        'org': 'Korea Telecom',
        'asn': 'AS4766',
        'timezone': 'Asia/Seoul',
      })!;
      expect(ipapiCo.asn, 4766);
      expect(ipapiCo.country, 'South Korea');

      // ipapi.is nests the interesting fields.
      final ipapiIs = ExitInfo.fromIpapiIs({
        'ip': '9.9.9.9',
        'location': {
          'country_code': 'SG',
          'country': 'Singapore',
          'city': 'Singapore',
          'timezone': 'Asia/Singapore',
        },
        'asn': {'asn': 13335, 'org': 'Cloudflare'},
      })!;
      expect(ipapiIs.ip, '9.9.9.9');
      expect(ipapiIs.organization, 'Cloudflare');
      expect(ipapiIs.countryCode, 'SG');
    });

    test('a payload without an address is not a success', () {
      // A service that answers 200 with an error object must not be reported as
      // an exit of "empty string".
      expect(ExitInfo.fromIpSb({'error': 'rate limited'}), isNull);
      expect(ExitInfo.fromIpapiCo(const <String, Object?>{}), isNull);
      expect(ExitInfo.fromIpapiIs('nonsense'), isNull);
    });

    test('one failing service does not block a working one', () async {
      // The TLS services are raced, so a single broken host costs nothing: the
      // answer arrives from whichever of them works.
      final tried = <String>[];
      final service = ExitInfoService(
        proxyResolver: () => '127.0.0.1:7890',
        transport: (url, proxy, timeout) async {
          tried.add(url.host);
          if (url.host == 'api.ip.sb') throw StateError('HTTP 503');
          return {'ip': '42.42.42.42', 'country_code': 'US', 'country': 'United States'};
        },
      );
      final info = await service.lookup();
      expect(info.ip, '42.42.42.42');
      // ipapi.co answers; ipapi.is also gets asked because they race.
      expect(tried, contains('api.ip.sb'));
      expect(tried.where((h) => h == 'api.ip.sb'), hasLength(1),
          reason: '成功的服务出现后不应再走明文兜底');
    });

    test('the plain-HTTP retry is used and labelled', () async {
      // Found live: one airport blocked TLS to the echo hosts but answered the
      // same path over plain HTTP. The label keeps that visible.
      final service = ExitInfoService(
        proxyResolver: () => '127.0.0.1:7890',
        transport: (url, proxy, timeout) async {
          if (url.scheme == 'https') throw StateError('blocked');
          return {'ip': '7.7.7.7', 'country_code': 'US'};
        },
      );
      final info = await service.lookup();
      expect(info.ip, '7.7.7.7');
      expect(info.source, 'ip.sb（HTTP）');
    });

    test('every service failing is one actionable error', () async {
      final service = ExitInfoService(
        proxyResolver: () => '127.0.0.1:7890',
        transport: (url, proxy, timeout) async => throw StateError('blocked'),
      );
      await expectLater(
        service.lookup(),
        throwsA(
          isA<ExitLookupError>()
              // The card shows the summary; the detail is what the tooltip
              // carries, so both halves have to exist and stay separate.
              .having((e) => e.summary, 'summary', contains('都不可达'))
              .having((e) => e.details, 'details', allOf(
                contains('ip.sb'),
                contains('blocked'),
              )),
        ),
      );
    });

    test('without a running core it refuses instead of guessing', () async {
      // A direct request would report this machine's address as the node's.
      final service = ExitInfoService(
        proxyResolver: () => null,
        transport: (url, proxy, timeout) async => fail('不应该发起请求'),
      );
      await expectLater(
        service.lookup(),
        throwsA(
          isA<ExitLookupError>().having(
            (e) => e.summary,
            'summary',
            contains('内核未运行'),
          ),
        ),
      );
    });
  });

  group('routing log level', () {
    test('defaults to warn and round-trips through the database', () async {
      final dir = Directory.systemTemp.createTempSync('halo-log-level');
      final controller = AppController(dataDir: dir.path);
      try {
        await controller.start(connectHost: false);
        expect(const RoutingSettings().logLevel, 'warn');
        expect(RoutingSettings.load(controller.settingsRepo).logLevel, 'warn');

        const settings = RoutingSettings(logLevel: 'debug');
        settings.save(controller.settingsRepo);
        expect(RoutingSettings.load(controller.settingsRepo).logLevel, 'debug');
      } finally {
        await controller.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });
}
