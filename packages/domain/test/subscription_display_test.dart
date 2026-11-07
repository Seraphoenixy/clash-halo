import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// `displayUrl` is what reaches a screenshot, a tooltip and a log line, so the
/// assertions here are about what must *not* be visible rather than about
/// formatting.
SubscriptionProfile profileWith(String url) =>
    SubscriptionProfile(id: 's', name: 'S', url: url);

void main() {
  group('subscription URL redaction', () {
    test('credentials before the host are hidden', () {
      final p = profileWith('https://user:secret@example.com/sub');
      expect(p.displayUrl.contains('secret'), isFalse);
      expect(p.displayUrl.contains('user'), isFalse);
      expect(p.displayUrl.startsWith('https://***@example.com'), isTrue);
    });

    test('a token in the query string is hidden', () {
      // The review found the list printing the whole endpoint. A token in the
      // query is the common shape for subscription providers, and printing it
      // meant an ordinary screenshot exposed an account credential.
      final p = profileWith('https://example.com/api/v1/client/abc/clash?token=s3cr3t');
      expect(p.displayUrl.contains('s3cr3t'), isFalse);
      expect(p.displayUrl.contains('token'), isFalse);
    });

    test('a token in the path is hidden', () {
      final p = profileWith('https://example.com/api/v1/client/9f8e7d6c/clash');
      expect(p.displayUrl.contains('9f8e7d6c'), isFalse);
      expect(p.displayUrl.contains('clash'), isFalse);
    });

    test('the host stays readable so subscriptions remain distinguishable', () {
      final a = profileWith('https://alpha.example.com/sub/one');
      final b = profileWith('https://beta.example.com/sub/two');
      expect(a.displayUrl, contains('alpha.example.com'));
      expect(b.displayUrl, contains('beta.example.com'));
      expect(a.displayUrl, isNot(b.displayUrl));
    });

    test('the port survives, since it is not a secret', () {
      final p = profileWith('https://example.com:8443/sub');
      expect(p.displayUrl, contains(':8443'));
    });

    test('a short single-segment path keeps one readable part', () {
      final p = profileWith('https://example.com/sub');
      expect(p.displayUrl, contains('example.com'));
      expect(p.displayUrl, contains('sub'));
    });

    test('an overlong first segment is itself truncated', () {
      final long = 'x' * 40;
      final p = profileWith('https://example.com/$long');
      expect(p.displayUrl.contains(long), isFalse);
      expect(p.displayUrl, contains('…'));
    });

    test('fullUrl still returns the exact address for copying', () {
      const url = 'https://user:secret@example.com/sub?token=abc';
      final p = profileWith(url);
      expect(p.fullUrl, url);
      expect(p.hasHiddenUrlParts, isTrue);
    });

    test('a URL with nothing to hide reports that, so no reveal is offered', () {
      final p = profileWith('https://example.com/sub');
      expect(p.hasHiddenUrlParts, isFalse);
    });

    test('a non-URL string is passed through unchanged', () {
      // Local file imports and hand-typed junk both land here; mangling them
      // would make the error message harder to match against what was typed.
      final p = profileWith('not-a-url');
      expect(p.displayUrl, 'not-a-url');
    });
  });
}
