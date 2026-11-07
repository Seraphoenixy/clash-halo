/// Subscription URL policy: the `{date}` template and when to go through the
/// proxy.
///
/// Both live here rather than in the window (or the CLI) because both are
/// *policy about a stored string*, and the two entry points already diverged
/// once on download behaviour. A subscription that refreshes in one and 404s in
/// the other is the kind of bug that costs an afternoon.
library;

/// The placeholder a subscription URL may carry in place of a date.
///
/// Public data sources are routinely published under a per-day name
/// (`.../node/20261105.txt`, `.../v20261105`). Storing that URL as-is means the
/// subscription is guaranteed to 404 the next day, and nothing in the app
/// noticed: the row simply started reporting an error and the user had to
/// remember to re-add it.
const String kDatePlaceholder = '{date}';

/// The value `{date}` expands to: the local date as `yyyyMMdd`.
///
/// Local, not UTC: these sources publish on their own timezone's date, and a
/// user in UTC+8 checking at 01:00 must get today's file, not yesterday's. The
/// host and the UI run on the same clock, so there is one answer.
String formatDatePlaceholder(DateTime now) {
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '${now.year}$month$day';
}

/// Whether [url] carries the date placeholder.
bool hasDatePlaceholder(String url) => url.contains(kDatePlaceholder);

/// Expands `{date}` in [url].
///
/// A URL with no placeholder is returned unchanged, so callers can apply this
/// unconditionally. Every occurrence is replaced: a source could legitimately
/// repeat the token (`.../{date}/list-{date}.txt`).
String resolveSubscriptionUrl(String url, {DateTime? now}) {
  if (!hasDatePlaceholder(url)) return url;
  return url.replaceAll(
    kDatePlaceholder,
    formatDatePlaceholder(now ?? DateTime.now()),
  );
}

/// How many days back a `{date}` URL may look when today's file is missing.
///
/// Bounded rather than open-ended: a source that stopped publishing should
/// eventually report an error instead of silently serving a week-old list, and
/// a user looking at the row needs the "this is 5 days old" signal rather than
/// an endless supply of stale data.
const int kDateLookbackDays = 7;

/// The candidate URLs for a templated source, newest first.
///
/// Empty when [url] has no placeholder: callers then fetch the single URL as
/// written, and a failure is a real failure rather than a stale-file search.
List<String> dateCandidateUrls(String url, {DateTime? now}) {
  if (!hasDatePlaceholder(url)) return const [];
  final base = now ?? DateTime.now();
  return [
    for (var back = 0; back <= kDateLookbackDays; back++)
      resolveSubscriptionUrl(url, now: base.subtract(Duration(days: back))),
  ];
}

/// How many days before [now] the given expanded candidate is, or 0.
///
/// Used to tell the user which file was actually used; without it a subscription
/// silently serving last week's nodes looks identical to a fresh one.
int? dateCandidateAgeDays(String url, String usedUrl, {DateTime? now}) {
  final candidates = dateCandidateUrls(url, now: now);
  final index = candidates.indexOf(usedUrl);
  return index < 0 ? null : index;
}

/// Hosts that serve the same content only through the proxy on a typical
/// mainland-China network.
///
/// Not a hard-coded "always use the proxy" list: it decides the *default* only.
/// The per-subscription switch still overrides it in both directions, because a
/// user behind a working route to GitHub must be able to turn it off, and one
/// with a private mirror wants it off for that host too.
const Set<String> _proxyFirstHosts = {
  'raw.githubusercontent.com',
  'gist.githubusercontent.com',
  'gist.github.com',
  'github.com',
  'objects.githubusercontent.com',
  'codeload.github.com',
};

/// Whether [url] should default to going through the proxy.
///
/// Evidence for these hosts: connecting to `raw.githubusercontent.com` directly
/// fails with "Connection was reset" on this machine while the same URL through
/// the local mixed inbound returns in about a second. A 60-second timeout is
/// what the user actually sees otherwise.
///
/// `github.com` is included with its content hosts on purpose: a release
/// download redirects through `objects.githubusercontent.com`, so exempting the
/// front page would only move the failure one hop.
bool defaultsToProxy(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  if (_proxyFirstHosts.contains(host)) return true;
  // Subdomains of a listed host inherit the policy.
  for (final listed in _proxyFirstHosts) {
    if (host.endsWith('.$listed')) return true;
  }
  return false;
}

/// The effective proxy decision for one refresh.
///
/// [override] is the per-subscription switch, which is tri-state: true and false
/// are explicit user choices, null means "no choice stored, use the policy".
/// This is why the switch cannot be a plain bool on the row: `use_proxy = 0`
/// currently means both "user turned it off" and "default", and only the second
/// should follow the host policy.
bool shouldUseProxyFor(String url, {bool? override}) {
  if (override != null) return override;
  return defaultsToProxy(url);
}
