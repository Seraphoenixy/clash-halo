/// Per-service unlock checks.
///
/// Each check answers one question: through the active exit, does this service
/// work, and in which region does it think the user is. The logic follows the
/// reference client's checker module closely on purpose — these verdicts come
/// from reverse-engineered response markers, and inventing our own reading of a
/// page we cannot test against would produce confident nonsense.
///
/// Nothing here reads the clock or the filesystem: the caller supplies the
/// transport, so every branch below is reachable from a canned response.
library;

import 'dart:convert';

import 'unlock.dart';

/// A check's raw answer, before it is given an identity and a timestamp.
class UnlockVerdict {
  const UnlockVerdict(this.status, [this.region]);
  final String status;
  final String? region;
}

/// The services the page offers, in display order.
List<UnlockCheckSpec> defaultUnlockChecks() => const [
  UnlockCheckSpec('netflix', 'Netflix', checkNetflix),
  UnlockCheckSpec('disney_plus', 'Disney+', checkDisneyPlus),
  UnlockCheckSpec('youtube_premium', 'YouTube Premium', checkYouTubePremium),
  UnlockCheckSpec('chatgpt', 'ChatGPT Web', checkChatGpt),
  UnlockCheckSpec('claude', 'Claude', checkClaude),
  UnlockCheckSpec('gemini', 'Gemini', checkGemini),
  UnlockCheckSpec('spotify', 'Spotify', checkSpotify),
  UnlockCheckSpec('tiktok', 'TikTok', checkTikTok),
  UnlockCheckSpec('prime_video', 'Prime Video', checkPrimeVideo),
  UnlockCheckSpec('bilibili_cn', '哔哩哔哩大陆', checkBilibiliMainland),
  UnlockCheckSpec('bilibili_hk', '哔哩哔哩港澳台', checkBilibiliHkMcTw),
  UnlockCheckSpec('bahamut', 'Bahamut Anime', checkBahamutAnime),
  UnlockCheckSpec('muse_ai', 'Muse AI', checkMuseAi),
];

/// One named service check.
class UnlockCheckSpec {
  const UnlockCheckSpec(this.id, this.name, this.run);
  final String id;
  final String name;
  final Future<UnlockVerdict> Function(UnlockHttp http) run;
}

/// The list shown before anything has been checked.
///
/// It is also the shape a stored result is merged into, so a check added in a
/// later version still appears when the stored results predate it.
List<UnlockItem> pendingUnlockItems() => [
  for (final spec in defaultUnlockChecks())
    UnlockItem(id: spec.id, name: spec.name),
];

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// The `loc=XX` line of a Cloudflare `/cdn-cgi/trace` response.
///
/// That endpoint is used by several checks because it reports the exit region
/// without needing an account or a session, and it is the same answer every
/// service behind Cloudflare would see.
String? traceLocation(String body) {
  for (final line in const LineSplitter().convert(body)) {
    if (line.startsWith('loc=')) {
      final value = line.substring(4).trim();
      if (value.isNotEmpty) return value;
    }
  }
  return null;
}

/// The value of `"key":"value"` anywhere in [body], tolerating any spacing.
String? quotedField(String body, String key) {
  final marker = '"$key"';
  final start = body.indexOf(marker);
  if (start < 0) return null;
  var rest = body.substring(start + marker.length);
  final colon = rest.indexOf(':');
  if (colon < 0) return null;
  rest = rest.substring(colon + 1).trimLeft();
  if (!rest.startsWith('"')) return null;
  final end = rest.indexOf('"', 1);
  if (end < 0) return null;
  return rest.substring(1, end);
}

/// 403 and 451 are the two statuses that mean "this region is refused".
///
/// Any other non-2xx means the request did not get far enough to be a verdict
/// about the region, which is why it maps to Failed rather than No.
String? restrictedStatus(int status) {
  if (status == 403 || status == 451) return UnlockStatus.no;
  if (status < 200 || status >= 300) return UnlockStatus.failed;
  return null;
}

/// Runs [body], turning any transport failure into a plain Failed.
///
/// A check that throws would otherwise abort the whole batch and leave the rest
/// of the page saying "未检测" for a reason that has nothing to do with them.
Future<UnlockVerdict> _guard(Future<UnlockVerdict> Function() body) async {
  try {
    return await body();
  } on Object {
    return const UnlockVerdict(UnlockStatus.failed);
  }
}

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

Future<UnlockVerdict> checkNetflix(UnlockHttp http) => _guard(() async {
  final cdn = await _netflixCdn(http);
  if (cdn.status == UnlockStatus.yes || cdn.status.startsWith('No')) return cdn;

  // The Fast.com answer said nothing, so fall back to asking the catalogue
  // itself. Two titles are used because one of them is a Netflix original that
  // is licensed nearly everywhere: a 404 on both means the catalogue is not
  // this exit's, not that the exit is blocked.
  final statuses = await Future.wait([
    _netflixTitleStatus(http, '81280792'),
    _netflixTitleStatus(http, '70143836'),
  ]);
  if (statuses.any((s) => s == null)) {
    return const UnlockVerdict(UnlockStatus.failed);
  }
  final a = statuses[0]!;
  final b = statuses[1]!;
  if (a == 404 && b == 404) {
    return const UnlockVerdict(UnlockStatus.originalsOnly);
  }
  if (a == 403 || b == 403) return const UnlockVerdict(UnlockStatus.no);
  if ([a, b].any((s) => s == 200 || s == 301)) return _netflixRegion(http);
  return UnlockVerdict('Failed (状态码: ${a}_$b)');
});

Future<UnlockVerdict> _netflixCdn(UnlockHttp http) async {
  try {
    final response = await http.get(
      Uri.parse(
        'https://api.fast.com/netflix/speedtest/v2?https=true'
        '&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5',
      ),
    );
    if (response.status == 403) {
      return const UnlockVerdict('No (IP Banned By Netflix)');
    }
    final decoded = jsonDecode(response.body);
    final targets = decoded is Map ? decoded['targets'] : null;
    if (targets is List && targets.isNotEmpty) {
      final location = (targets.first as Map)['location'];
      final country = location is Map ? location['country'] : null;
      if (country is String && country.isNotEmpty) {
        return UnlockVerdict(
          UnlockStatus.yes,
          unlockRegionLabel(country),
        );
      }
    }
    return const UnlockVerdict('Unknown');
  } on Object {
    // A blocked CDN is not a verdict on the node: the caller falls through to
    // the catalogue checks.
    return const UnlockVerdict('Failed (CDN API)');
  }
}

Future<int?> _netflixTitleStatus(UnlockHttp http, String id) async {
  try {
    // Redirects are not followed: a 301 is itself the useful signal that the
    // catalogue answered, and following it would hide the distinction between
    // "this title exists elsewhere" and "not found".
    final response = await http.get(
      Uri.parse('https://www.netflix.com/title/$id'),
      followRedirects: false,
    );
    return response.status;
  } on Object {
    return null;
  }
}

Future<UnlockVerdict> _netflixRegion(UnlockHttp http) async {
  try {
    final response = await http.get(
      Uri.parse('https://www.netflix.com/title/80018499'),
      followRedirects: false,
    );
    final location = response.header('location') ?? '';
    final segments = location.split('/');
    final region = segments.length > 3
        ? segments[3].split('-').first
        : '';
    return UnlockVerdict(
      UnlockStatus.yes,
      unlockRegionLabel(region.isEmpty ? 'us' : region),
    );
  } on Object {
    // The answer is still "this exit can open a Netflix title"; only the flag
    // is missing, and saying so beats discarding a working verdict.
    return const UnlockVerdict('Yes (但无法获取区域)');
  }
}

/// Disney+ needs a three-step handshake (device assertion → refresh token →
/// GraphQL session) because the region is only exposed to a session that the
/// service considers a real browser.
Future<UnlockVerdict> checkDisneyPlus(UnlockHttp http) => _guard(() async {
  const auth =
      'Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.'
      'Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84';

  final device = await http.postJson(
    Uri.parse('https://disney.api.edge.bamgrid.com/devices'),
    const {
      'deviceFamily': 'browser',
      'applicationRuntime': 'chrome',
      'deviceProfile': 'windows',
      'attributes': <String, Object?>{},
    },
    headers: {'authorization': auth},
  );
  if (device.status == 403) {
    return const UnlockVerdict('No (IP Banned By Disney+)');
  }
  final assertion = quotedField(device.body, 'assertion');
  if (assertion == null) {
    return const UnlockVerdict('Failed (Cannot extract assertion)');
  }

  final token = await http.postForm(
    Uri.parse('https://disney.api.edge.bamgrid.com/token'),
    {
      'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
      'latitude': '0',
      'longitude': '0',
      'platform': 'browser',
      'subject_token': assertion,
      'subject_token_type': 'urn:bamtech:params:oauth:token-type:device',
    },
    headers: {'authorization': auth},
  );
  if (token.status == 403 ||
      token.body.contains('forbidden-location') ||
      token.body.contains('403 ERROR')) {
    return const UnlockVerdict('No (IP Banned By Disney+)');
  }
  final refreshToken = quotedField(token.body, 'refresh_token');
  if (refreshToken == null) {
    return UnlockVerdict('Failed (Cannot extract refresh token: ${token.status})');
  }

  // A region that cannot even serve the marketing page is a different answer
  // from a region that serves it but is not supported yet.
  final unavailable = await _disneyUnavailable(http);

  final response = await http.postJson(
    Uri.parse('https://disney.api.edge.bamgrid.com/graph/v1/device/graphql'),
    {
      // `$input` is GraphQL's own variable syntax, not Dart interpolation, so
      // the string is raw.
      'query': r'mutation refreshToken($input: RefreshTokenInput!) '
          r'{ refreshToken(refreshToken: $input) { activeSession { sessionId } } }',
      'variables': {
        'input': {'refreshToken': refreshToken},
      },
    },
    headers: {'authorization': auth},
  );
  if (!response.ok || response.body.isEmpty) {
    return await _disneyFallbackRegion(http) ??
        UnlockVerdict('Failed (GraphQL: ${response.status})');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(response.body);
  } on Object {
    return await _disneyFallbackRegion(http) ??
        const UnlockVerdict('Failed (Invalid GraphQL Response)');
  }
  final region = _findString(decoded, 'countryCode');
  if (region == null) {
    return await _disneyFallbackRegion(http) ??
        const UnlockVerdict(UnlockStatus.no);
  }
  // Japan runs a separate service whose session response does not carry the
  // supported-location flag at all.
  if (region == 'JP') {
    return UnlockVerdict(UnlockStatus.yes, unlockRegionLabel(region));
  }
  if (unavailable) return const UnlockVerdict(UnlockStatus.no);
  final supported = _findBool(decoded, 'inSupportedLocation');
  if (supported == true) {
    return UnlockVerdict(UnlockStatus.yes, unlockRegionLabel(region));
  }
  if (supported == false) {
    return UnlockVerdict(
      UnlockStatus.soon,
      '${unlockRegionLabel(region)}（即将上线）',
    );
  }
  return UnlockVerdict('Failed (Unknown region status for $region)');
});

Future<bool> _disneyUnavailable(UnlockHttp http) async {
  try {
    final response = await http.get(Uri.parse('https://disneyplus.com'));
    final url = response.finalUrl.toString();
    return url.contains('preview') || url.contains('unavailable');
  } on Object {
    // Unreachable is treated as unavailable, matching the reference: if the
    // marketing page cannot be fetched, the session result is not trustworthy.
    return true;
  }
}

Future<UnlockVerdict?> _disneyFallbackRegion(UnlockHttp http) async {
  try {
    final response = await http.get(Uri.parse('https://www.disneyplus.com/'));
    final region = quotedField(response.body, 'region');
    if (region == null) return null;
    return UnlockVerdict(
      UnlockStatus.yes,
      '${unlockRegionLabel(region)} (from main page)',
    );
  } on Object {
    return null;
  }
}

Future<UnlockVerdict> checkYouTubePremium(UnlockHttp http) => _guard(() async {
  final response = await http.get(
    Uri.parse('https://www.youtube.com/premium?hl=en'),
  );
  final body = response.body;
  final lower = body.toLowerCase();

  final region = _youTubeRegion(body);

  const unavailable = [
    'youtube premium is not available in your country',
    'premium is not available in your country',
    'premium is not available in your region',
  ];
  if (unavailable.any(lower.contains)) {
    return UnlockVerdict(UnlockStatus.no, region);
  }
  if (response.ok &&
      (lower.contains('youtube premium') ||
          lower.contains('ad-free') ||
          lower.contains('"browseid":"spunlimited"'))) {
    return UnlockVerdict(UnlockStatus.yes, region);
  }
  return UnlockVerdict(UnlockStatus.failed, region);
});

String? _youTubeRegion(String body) {
  for (final key in const ['GL', 'countryCode', 'country_code']) {
    final value = quotedField(body, key);
    if (value != null && value.isNotEmpty) return unlockRegionLabel(value);
  }
  // The premium page also embeds the country in a plain element, which is the
  // only place it appears when the JSON blobs above are absent.
  final marker = body.contains('id="country-code"')
      ? 'id="country-code"'
      : (body.contains("id='country-code'") ? "id='country-code'" : null);
  if (marker == null) return null;
  final rest = body.substring(body.indexOf(marker) + marker.length);
  final open = rest.indexOf('>');
  if (open < 0) return null;
  final value = rest.substring(open + 1).split('<').first.trim();
  return value.isEmpty ? null : unlockRegionLabel(value);
}

Future<UnlockVerdict> checkChatGpt(UnlockHttp http) => _guard(() async {
  String? region;
  try {
    final trace = await http.get(
      Uri.parse('https://chat.openai.com/cdn-cgi/trace'),
    );
    final loc = traceLocation(trace.body);
    if (loc != null && loc.isNotEmpty) region = unlockRegionLabel(loc);
  } on Object {
    // The region is a nice-to-have; the verdict below is the answer.
  }

  try {
    final response = await http.get(
      Uri.parse('https://api.openai.com/compliance/cookie_requirements'),
    );
    final status = response.body.toLowerCase().contains('unsupported_country')
        ? UnlockStatus.unsupportedRegion
        : UnlockStatus.yes;
    return UnlockVerdict(status, region);
  } on Object {
    return UnlockVerdict(UnlockStatus.failed, region);
  }
});

/// Claude's own list of unsupported countries, which is a policy question and
/// not something that can be inferred from a status code.
const _claudeBlocked = {
  'AF', 'BY', 'CN', 'CU', 'HK', 'IR', 'KP', 'MO', 'RU', 'SY',
};

Future<UnlockVerdict> checkClaude(UnlockHttp http) => _guard(() async {
  final trace = await http.get(Uri.parse('https://claude.ai/cdn-cgi/trace'));
  final code = traceLocation(trace.body)?.trim().toUpperCase();
  if (code == null || code.isEmpty) {
    return const UnlockVerdict(UnlockStatus.failed);
  }
  final status = _claudeBlocked.contains(code)
      ? UnlockStatus.no
      : UnlockStatus.yes;
  return UnlockVerdict(status, unlockRegionLabel(code));
});

const _geminiBlocked = {
  'CHN', 'RUS', 'BLR', 'CUB', 'IRN', 'PRK', 'SYR', 'HKG', 'MAC',
};

Future<UnlockVerdict> checkGemini(UnlockHttp http) => _guard(() async {
  final response = await http.get(Uri.parse('https://gemini.google.com'));
  // The region sits at the end of a numeric tuple. Observed live the page
  // returns `,2,1,200,"KOR"`, while the reference client matches an escaped
  // quote (`,2,1,200,\"KOR"`), which is the JSON-in-JS form of the same thing.
  // The marker therefore stops before the quote and any quoting is skipped, so
  // both shapes answer instead of one of them silently reporting 检测失败.
  const marker = ',2,1,200,';
  final at = response.body.indexOf(marker);
  if (at < 0) return const UnlockVerdict(UnlockStatus.failed);
  final rest = response.body
      .substring(at + marker.length)
      .replaceFirst(RegExp(r'^[\\"]+'), '');
  if (rest.length < 3) return const UnlockVerdict(UnlockStatus.failed);
  final code = rest.substring(0, 3);
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
    return const UnlockVerdict(UnlockStatus.failed);
  }
  final status = _geminiBlocked.contains(code)
      ? UnlockStatus.no
      : UnlockStatus.yes;
  return UnlockVerdict(status, unlockRegionLabel(code));
});

Future<UnlockVerdict> checkSpotify(UnlockHttp http) => _guard(() async {
  final response = await http.get(
    Uri.parse(
      'https://www.spotify.com/api/content/v1/country-selector'
      '?platform=web&format=json',
    ),
  );
  final region =
      _spotifyRegionFromUrl(response.finalUrl) ??
      quotedField(response.body, 'countryCode');
  final restricted = restrictedStatus(response.status);
  if (restricted != null) {
    return UnlockVerdict(restricted, region == null ? null : unlockRegionLabel(region));
  }
  final status = response.body.toLowerCase().contains(
    'not available in your country',
  )
      ? UnlockStatus.no
      : UnlockStatus.yes;
  return UnlockVerdict(status, region == null ? null : unlockRegionLabel(region));
});

/// Spotify answers with a country-specific redirect, so the path segment is the
/// region whenever it is not the API prefix itself.
String? _spotifyRegionFromUrl(Uri url) {
  final segments = url.pathSegments.where((s) => s.isNotEmpty);
  if (segments.isEmpty) return null;
  final first = segments.first;
  if (first == 'api') return null;
  final code = first.split('-').first;
  return code.isEmpty ? null : code;
}

Future<UnlockVerdict> checkTikTok(UnlockHttp http) => _guard(() async {
  var (status, region) = await _tikTokProbe(
    http,
    'https://www.tiktok.com/cdn-cgi/trace',
  );
  if (region == null || status == UnlockStatus.failed) {
    final (fallbackStatus, fallbackRegion) = await _tikTokProbe(
      http,
      'https://www.tiktok.com/',
    );
    // A definite "No" from the trace endpoint outranks the landing page, which
    // serves the same blocked shell to everyone.
    if (status != UnlockStatus.no) status = fallbackStatus;
    region ??= fallbackRegion;
  }
  return UnlockVerdict(status, region);
});

Future<(String, String?)> _tikTokProbe(UnlockHttp http, String url) async {
  try {
    final response = await http.get(Uri.parse(url));
    final restricted = restrictedStatus(response.status);
    final status = restricted ?? _tikTokStatus(response.body);
    final raw = quotedField(response.body, 'region');
    final region = raw == null || raw.isEmpty
        ? null
        : unlockRegionLabel(raw.split('-').first);
    return (status, region);
  } on Object {
    return (UnlockStatus.failed, null);
  }
}

String _tikTokStatus(String body) {
  final lower = body.toLowerCase();
  const blocked = [
    'access denied',
    'not available in your region',
    'tiktok is not available',
  ];
  return blocked.any(lower.contains) ? UnlockStatus.no : UnlockStatus.yes;
}

Future<UnlockVerdict> checkPrimeVideo(UnlockHttp http) => _guard(() async {
  final response = await http.get(Uri.parse('https://www.primevideo.com'));
  if (response.body.contains('isServiceRestricted')) {
    return const UnlockVerdict('No (Service Not Available)');
  }
  final region = quotedField(response.body, 'currentTerritory');
  if (region == null || region.isEmpty) {
    return const UnlockVerdict('Failed (PAGE ERROR)');
  }
  return UnlockVerdict(UnlockStatus.yes, unlockRegionLabel(region));
});

/// The two 哔哩哔哩 rows are separate because mainland and HK/Macau/Taiwan
/// licensing are separate: a node routinely unlocks one and not the other.
Future<UnlockVerdict> checkBilibiliMainland(UnlockHttp http) => _bilibili(
  http,
  'https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type='
  '&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi',
);

Future<UnlockVerdict> checkBilibiliHkMcTw(UnlockHttp http) => _bilibili(
  http,
  'https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777'
  '&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi',
);

Future<UnlockVerdict> _bilibili(UnlockHttp http, String url) => _guard(() async {
  final response = await http.get(Uri.parse(url));
  final Object? decoded;
  try {
    decoded = jsonDecode(response.body);
  } on Object {
    return const UnlockVerdict(UnlockStatus.failed);
  }
  if (decoded is! Map) return const UnlockVerdict(UnlockStatus.failed);
  return switch ((decoded['code'] as num?)?.toInt()) {
    0 => const UnlockVerdict(UnlockStatus.yes),
    // The documented "地区限制" code: the API answered, and the answer is that
    // this region has no rights to the title.
    -10403 => const UnlockVerdict(UnlockStatus.no),
    _ => const UnlockVerdict(UnlockStatus.failed),
  };
});

Future<UnlockVerdict> checkBahamutAnime(UnlockHttp http) => _guard(() async {
  // Bahamut's device handshake rejects a client whose UA is not a browser, and
  // it checks a UA of its own rather than the shared one.
  const headers = {
    'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  };

  final device = await http.get(
    Uri.parse('https://ani.gamer.com.tw/ajax/getdeviceid.php'),
    headers: headers,
  );
  final deviceId = quotedField(device.body, 'deviceid');
  if (deviceId == null || deviceId.isEmpty) {
    return const UnlockVerdict(UnlockStatus.failed);
  }

  final token = await http.get(
    Uri.parse(
      'https://ani.gamer.com.tw/ajax/token.php'
      '?adID=89422&sn=37783&device=$deviceId',
    ),
    headers: headers,
  );
  if (!token.body.contains('animeSn')) {
    return const UnlockVerdict(UnlockStatus.no);
  }

  String? region;
  try {
    final page = await http.get(
      Uri.parse('https://ani.gamer.com.tw/'),
      headers: headers,
    );
    // This one is an HTML attribute, not a JSON field, so `quotedField` cannot
    // see it: it looks for `"data-geo"` and the page says `data-geo="TW"`.
    const marker = 'data-geo="';
    final at = page.body.indexOf(marker);
    if (at >= 0) {
      final rest = page.body.substring(at + marker.length);
      final end = rest.indexOf('"');
      if (end > 0) region = unlockRegionLabel(rest.substring(0, end));
    }
  } on Object {
    // The verdict is already known; the region is not worth failing over.
  }
  return UnlockVerdict(UnlockStatus.yes, region);
});

Future<UnlockVerdict> checkMuseAi(UnlockHttp http) => _guard(() async {
  String? region;
  try {
    final trace = await http.get(
      Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'),
    );
    final loc = traceLocation(trace.body)?.trim().toUpperCase();
    if (loc != null && loc.isNotEmpty) region = unlockRegionLabel(loc);
  } on Object {
    // Region only.
  }

  final UnlockResponse response;
  try {
    response = await http.get(Uri.parse('https://muse.ai'));
  } on Object {
    return UnlockVerdict('Failed (Network Connection)', region);
  }

  // Every region is redirected to the aymh anti-bot gateway before the app
  // loads, and a plain HTTP client cannot finish the JavaScript challenge: it
  // gets Meta's generic error page instead. Reaching that proves the exit can
  // talk to Muse's auth infrastructure and nothing more, so it is called out as
  // uncertain rather than reported as a working service.
  const markers = ['Sorry, something went wrong', 'static.facebook.com/images/logos'];
  final behindAntiBot =
      response.finalUrl.host == 'auth.muse.ai' ||
      markers.any(response.body.contains);

  if (behindAntiBot) return UnlockVerdict(UnlockStatus.risky, region);
  if (response.ok) return UnlockVerdict(UnlockStatus.yes, region);
  return UnlockVerdict(restrictedStatus(response.status) ?? UnlockStatus.failed, region);
});

// ---------------------------------------------------------------------------
// JSON helpers for the GraphQL-shaped responses
// ---------------------------------------------------------------------------

/// Depth-first search for a string field.
///
/// Disney+ nests the country under a different path per region, and the
/// reference implementation searches rather than pins a path for exactly that
/// reason: a pinned path broke whenever their response shape changed.
String? _findString(Object? value, String key) {
  if (value is Map) {
    final direct = value[key];
    if (direct is String) return direct;
    for (final nested in value.values) {
      final found = _findString(nested, key);
      if (found != null) return found;
    }
    return null;
  }
  if (value is List) {
    for (final nested in value) {
      final found = _findString(nested, key);
      if (found != null) return found;
    }
  }
  return null;
}

bool? _findBool(Object? value, String key) {
  if (value is Map) {
    final direct = value[key];
    if (direct is bool) return direct;
    for (final nested in value.values) {
      final found = _findBool(nested, key);
      if (found != null) return found;
    }
    return null;
  }
  if (value is List) {
    for (final nested in value) {
      final found = _findBool(nested, key);
      if (found != null) return found;
    }
  }
  return null;
}
