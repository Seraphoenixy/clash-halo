import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// `{date}` expansion and the host-based proxy default.
///
/// Both exist because of observed failures: a daily GitHub source 404'd the day
/// after it was added, and two GitHub-hosted sources timed out on direct
/// connections while the same URLs answered in about a second through the proxy.
void main() {
  group('{date} template', () {
    test('expands to the local yyyyMMdd', () {
      final resolved = resolveSubscriptionUrl(
        'https://example.com/node/{date}.txt',
        now: DateTime(2026, 11, 5),
      );
      expect(resolved, 'https://example.com/node/20261105.txt');
    });

    test('pads single-digit months and days', () {
      expect(
        resolveSubscriptionUrl(
          'https://example.com/{date}.txt',
          now: DateTime(2026, 1, 9),
        ),
        'https://example.com/20260109.txt',
      );
    });

    test('uses the local date, not UTC', () {
      // A user at 01:00 local on the 6th must get the 6th's file. Formatting in
      // UTC would hand them the previous day for the first eight hours of every
      // day, and the file would 404.
      final local = DateTime(2026, 11, 6, 1, 30);
      expect(
        resolveSubscriptionUrl('https://e.com/{date}', now: local),
        'https://e.com/20261106',
      );
    });

    test('replaces every occurrence', () {
      expect(
        resolveSubscriptionUrl(
          'https://e.com/{date}/list-{date}.txt',
          now: DateTime(2026, 11, 5),
        ),
        'https://e.com/20261105/list-20261105.txt',
      );
    });

    test('a URL without the token is untouched', () {
      const url = 'https://example.com/stable/sub';
      expect(resolveSubscriptionUrl(url, now: DateTime(2026, 11, 5)), url);
      expect(hasDatePlaceholder(url), isFalse);
    });

    test('the trailing-digit mistake is not silently repaired', () {
      // `v202611051` (an extra 1) is a 404. The template must not guess; the
      // stored value is what the user wrote.
      expect(
        resolveSubscriptionUrl(
          'https://e.com/v{date}1',
          now: DateTime(2026, 11, 5),
        ),
        'https://e.com/v202611051',
      );
    });
  });

  group('date look-back', () {
    test('candidates run from today back to the bound', () {
      final urls = dateCandidateUrls(
        'https://e.com/v{date}',
        now: DateTime(2026, 11, 6),
      );
      expect(urls, hasLength(kDateLookbackDays + 1));
      expect(urls.first, 'https://e.com/v20261106');
      expect(urls[1], 'https://e.com/v20261105');
      expect(urls.last, 'https://e.com/v20261030');
    });

    test('a URL with no token yields no candidates', () {
      expect(dateCandidateUrls('https://e.com/stable'), isEmpty);
    });

    test('the age of the chosen candidate is reported', () {
      // This is what turns "it updated" into "it updated with 5-day-old data".
      expect(
        dateCandidateAgeDays(
          'https://e.com/v{date}',
          'https://e.com/v20261106',
          now: DateTime(2026, 11, 6),
        ),
        0,
      );
      expect(
        dateCandidateAgeDays(
          'https://e.com/v{date}',
          'https://e.com/v20261101',
          now: DateTime(2026, 11, 6),
        ),
        5,
      );
      expect(
        dateCandidateAgeDays(
          'https://e.com/v{date}',
          'https://e.com/nonsense',
          now: DateTime(2026, 11, 6),
        ),
        isNull,
      );
    });

    test('the look-back crosses a month boundary correctly', () {
      final urls = dateCandidateUrls(
        'https://e.com/{date}',
        now: DateTime(2026, 3, 2),
      );
      expect(urls[0], 'https://e.com/20260302');
      expect(urls[1], 'https://e.com/20260301');
      expect(urls[2], 'https://e.com/20260228');
    });
  });

  group('proxy default by host', () {
    test('GitHub content hosts default to the proxy', () {
      for (final url in [
        'https://raw.githubusercontent.com/a/b/main/v.txt',
        'https://gist.githubusercontent.com/a/b/raw/x',
        'https://objects.githubusercontent.com/x',
        'https://github.com/a/b/releases/download/v1/x.zip',
      ]) {
        expect(defaultsToProxy(url), isTrue, reason: url);
      }
    });

    test('other hosts default to direct', () {
      for (final url in [
        'https://d.zrfme.com/vless-base64',
        'https://clashgithub.com/wp-content/uploads/rss/x.txt',
        'https://stairnode.cczzuu.top/node/x.txt',
      ]) {
        expect(defaultsToProxy(url), isFalse, reason: url);
      }
    });

    test('a look-alike host is not treated as GitHub', () {
      // `raw.githubusercontent.com.evil.test` must not inherit the policy;
      // suffix matching has to be anchored on the dot.
      expect(defaultsToProxy('https://raw.githubusercontent.com.evil.test/x'),
          isFalse);
      expect(defaultsToProxy('https://notgithub.com/x'), isFalse);
    });

    test('an explicit choice overrides the policy in both directions', () {
      const github = 'https://raw.githubusercontent.com/a/b/main/v.txt';
      const other = 'https://d.zrfme.com/vless';

      expect(shouldUseProxyFor(github, override: false), isFalse);
      expect(shouldUseProxyFor(github), isTrue);
      expect(shouldUseProxyFor(other, override: true), isTrue);
      expect(shouldUseProxyFor(other), isFalse);
      // null is "no opinion", which is the only case the policy decides.
      expect(shouldUseProxyFor(github, override: null), isTrue);
    });

    test('a malformed URL does not throw', () {
      expect(defaultsToProxy(''), isFalse);
      expect(defaultsToProxy('not a url'), isFalse);
    });
  });

  group('profile resolves its own switch', () {
    SubscriptionProfile profile({bool? useProxy, String? url}) =>
        SubscriptionProfile(
          id: 'p1',
          name: 'p',
          url: url ?? 'https://raw.githubusercontent.com/a/b/main/v.txt',
          useProxy: useProxy,
        );

    test('unset follows the host policy', () {
      expect(profile().useProxyFor(profile().url), isTrue);
      expect(
        profile(url: 'https://d.zrfme.com/vless').useProxyFor(
          'https://d.zrfme.com/vless',
        ),
        isFalse,
      );
    });

    test('an explicit off is respected on a GitHub URL', () {
      final p = profile(useProxy: false);
      expect(p.useProxyFor(p.url), isFalse);
    });

    test('clearing back to no-opinion is expressible', () {
      final p = profile(useProxy: false).copyWith(clearUseProxy: true);
      expect(p.useProxy, isNull);
      expect(p.useProxyFor(p.url), isTrue);
    });
  });
}
