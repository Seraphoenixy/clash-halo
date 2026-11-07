/// Unlock checking: can the current exit node reach a service at all, and in
/// which region does that service see it.
///
/// This is deliberately *not* a speed or reachability measurement. A node with
/// a perfect 90 ms round trip can still land in a region Netflix refuses, and a
/// node that answers every TCP handshake can be blocked by ChatGPT. The verdict
/// is per service and per exit, so it lives in its own model, its own page and
/// its own stored results.
///
/// The checks run from the UI process through the running core's mixed inbound.
/// That is the same path a browser on this machine would take, which is exactly
/// what makes the answer meaningful: it reports what the *active* node unlocks,
/// not what a disposable core for some other node would.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A desktop Chrome UA.
///
/// Several of these services answer a non-browser client with a bot wall or a
/// generic error page, and the verdict would then describe the client rather
/// than the exit node. The value is the same one the reference client sends.
const defaultUnlockUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

/// Verdict constants, mirroring the reference client's wires so a stored result
/// keeps its meaning across versions.
///
/// Compound verdicts are not enumerated: several checks append the reason
/// ("Failed (GraphQL: 403)"), and inventing a constant per combination would
/// turn a diagnostic into a lookup table. [unlockTone] classifies by prefix.
abstract final class UnlockStatus {
  static const pending = 'Pending';
  static const yes = 'Yes';
  static const no = 'No';
  static const failed = 'Failed';
  static const risky = 'Risky';
  static const soon = 'Soon';
  static const unsupportedRegion = 'Unsupported Country/Region';
  static const originalsOnly = 'Originals Only';
  static const disallowedIsp = 'Disallowed ISP';
}

/// How a verdict should be painted. Kept separate from the verdict text so a
/// new compound status cannot silently render with the wrong colour.
enum UnlockTone { pending, ok, warn, bad, unknown }

UnlockTone unlockTone(String status) {
  if (status == UnlockStatus.pending || status.isEmpty) return UnlockTone.pending;
  if (status == UnlockStatus.yes) return UnlockTone.ok;
  if (status == UnlockStatus.soon || status == UnlockStatus.risky) {
    return UnlockTone.warn;
  }
  // "No", "No (IP Banned By Netflix)", "Failed", "Failed (Network Connection)",
  // "Unsupported Country/Region", "Originals Only" and "Disallowed ISP" all mean
  // the same thing to the user: this exit cannot use the service.
  if (status.startsWith('No') ||
      status.startsWith('Failed') ||
      status == UnlockStatus.unsupportedRegion ||
      status == UnlockStatus.originalsOnly ||
      status == UnlockStatus.disallowedIsp) {
    return UnlockTone.bad;
  }
  return UnlockTone.unknown;
}

/// Chinese label for the verdicts a user actually sees.
///
/// An unmapped verdict is returned unchanged: "Failed (GraphQL: 403)" carries
/// more information than any label we could invent for it.
String unlockStatusLabel(String status) => switch (status) {
  '' || UnlockStatus.pending => '未检测',
  UnlockStatus.yes => '解锁',
  UnlockStatus.no => '不支持',
  UnlockStatus.failed => '检测失败',
  UnlockStatus.risky => '存疑',
  UnlockStatus.soon => '即将上线',
  UnlockStatus.unsupportedRegion => '地区不支持',
  UnlockStatus.originalsOnly => '仅自制剧',
  UnlockStatus.disallowedIsp => '运营商被限制',
  'No (IP Banned By Netflix)' || 'No (IP Banned By Disney+)' => 'IP 被封禁',
  'Failed (Network Connection)' => '连接失败',
  _ => status,
};

/// One service's verdict for the active exit.
@immutable
class UnlockItem {
  const UnlockItem({
    required this.id,
    required this.name,
    this.status = UnlockStatus.pending,
    this.region,
    this.checkedAtMs = 0,
  });

  /// Stable key. The display name is translated and the same service can be
  /// listed twice under different names (哔哩哔哩 has two entries), so identity
  /// is the id and never the name.
  final String id;
  final String name;

  /// The raw verdict; see [unlockTone] and [unlockStatusLabel].
  final String status;

  /// Exit region as the service itself reported it, e.g. `🇺🇸US`. Null when the
  /// service did not say, which is not the same as "unknown region is fine".
  final String? region;
  final int checkedAtMs;

  bool get isPending => status == UnlockStatus.pending;

  UnlockItem copyWith({String? status, String? region, int? checkedAtMs}) =>
      UnlockItem(
        id: id,
        name: name,
        status: status ?? this.status,
        region: region ?? this.region,
        checkedAtMs: checkedAtMs ?? this.checkedAtMs,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'status': status,
    if (region != null) 'region': region,
    'checkedAtMs': checkedAtMs,
  };

  static UnlockItem? fromJson(Map<String, Object?> json) {
    final id = json['id'] as String? ?? '';
    if (id.isEmpty) return null;
    return UnlockItem(
      id: id,
      name: json['name'] as String? ?? id,
      status: json['status'] as String? ?? UnlockStatus.pending,
      region: json['region'] as String?,
      checkedAtMs: (json['checkedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A stored sweep, together with the node it describes.
///
/// The node is part of the result, not decoration: these verdicts are properties
/// of an exit, and a list that outlives a node switch would otherwise sit under
/// a header naming the *new* node while every card still describes the old one.
/// That is the same class of mistake as a stale latency next to a fresh row.
@immutable
class UnlockSnapshot {
  const UnlockSnapshot({required this.items, this.nodeId, this.nodeName});

  final List<UnlockItem> items;
  final String? nodeId;
  final String? nodeName;

  Map<String, Object?> toJson() => {
    if (nodeId != null) 'nodeId': nodeId,
    if (nodeName != null) 'nodeName': nodeName,
    'items': [for (final item in items) item.toJson()],
  };

  /// Reads both the current shape and a bare list.
  ///
  /// The list form is what an earlier build wrote; discarding it would silently
  /// drop results a user can still see the value of, and the node is simply
  /// unknown in that case.
  static UnlockSnapshot? fromJson(Object? raw) {
    final Object? entries;
    String? nodeId;
    String? nodeName;
    if (raw is List) {
      entries = raw;
    } else if (raw is Map) {
      entries = raw['items'];
      nodeId = raw['nodeId'] as String?;
      nodeName = raw['nodeName'] as String?;
    } else {
      return null;
    }
    if (entries is! List) return null;
    final items = <UnlockItem>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final item = UnlockItem.fromJson(entry.cast<String, Object?>());
      if (item != null) items.add(item);
    }
    if (items.isEmpty) return null;
    return UnlockSnapshot(items: items, nodeId: nodeId, nodeName: nodeName);
  }
}

/// Country code to the one form the page displays.
///
/// Two things made the badges disagree, and both are fixed here rather than in
/// the page:
///
///  * The reference client prefixes a flag emoji. Windows ships no flag glyphs,
///    so the two regional indicators render as their own letters: the flag plus
///    `JP` reached the screen as `JPJP`, while `KOR` (which has no flag) stayed
///    alone.
/// * Gemini reports an alpha-3 code where every other check reports alpha-2, so
///    one card in thirteen read `KOR` next to twelve reading `KR`.
///
/// So: no emoji, and alpha-3 is folded to alpha-2. The table is the ISO 3166-1
/// mapping reported by .NET's `RegionInfo`, generated rather than typed; an
/// unknown three-letter code is passed through unchanged instead of guessed at.
///
/// The code stays the canonical form — it is what gets stored, compared and
/// sorted, and what the existing contract pins. [unlockRegionDisplay] is what
/// the UI shows.
String unlockRegionLabel(String code) {
  final trimmed = code.trim();
  if (trimmed.isEmpty) return '';
  final upper = trimmed.toUpperCase();
  if (upper.length == 3) return _alpha3ToAlpha2[upper] ?? upper;
  return upper;
}

/// The label to put on a chip: the code, plus its name when one is known.
///
/// The review's complaint was that a Chinese interface showed bare codes, and
/// that `ALISG` next to `US` read as a rendering fault rather than as a region.
/// The code is kept because it is unambiguous and排序友好; the name is added
/// because it is what most people can actually read.
///
/// A code with no known name is returned alone rather than dressed up: `ZZ`
/// with no name is honest, `ZZ（未知）` is noise.
String unlockRegionDisplay(String code) {
  final label = unlockRegionLabel(code);
  if (label.isEmpty) return '';
  final name = _regionNames[label];
  if (name == null) return label;
  return '$label · $name';
}

/// Common ISO 3166-1 alpha-2 codes plus the service-specific codes observed in
/// real results, mapped to their Chinese name.
///
/// Not exhaustive on purpose: an unlisted code still renders, just without a
/// name. Disney+ reports its own internal codes — `ALISG` is Disney's Singapore
/// marker, not a country code at all.
const Map<String, String> _regionNames = {
  'US': '美国',
  'HK': '香港',
  'TW': '台湾',
  'JP': '日本',
  'SG': '新加坡',
  'KR': '韩国',
  'GB': '英国',
  'DE': '德国',
  'FR': '法国',
  'NL': '荷兰',
  'CA': '加拿大',
  'AU': '澳大利亚',
  'RU': '俄罗斯',
  'IN': '印度',
  'BR': '巴西',
  'TR': '土耳其',
  'AR': '阿根廷',
  'CH': '瑞士',
  'SE': '瑞典',
  'PL': '波兰',
  'IT': '意大利',
  'ES': '西班牙',
  'MY': '马来西亚',
  'TH': '泰国',
  'VN': '越南',
  'PH': '菲律宾',
  'ID': '印度尼西亚',
  'CN': '中国',
  'MO': '澳门',
  'ALISG': '新加坡（Disney+ 标识）',
};

/// Alpha-3 to alpha-2, five characters per entry, grouped into lines only so
/// the source stays readable.
final Map<String, String> _alpha3ToAlpha2 = {
  for (final line in const [
  'ABWAW,AFGAF,AGOAO,AIAAI,ALAAX,ALBAL,ANDAD,AREAE,ARGAR,ARMAM,ASMAS,ATGAG,AUSAU,AUTAT,'
  'AZEAZ,BDIBI,BELBE,BENBJ,BESBQ,BFABF,BGDBD,BGRBG,BHRBH,BHSBS,BIHBA,BLMBL,BLRBY,BLZBZ,'
  'BMUBM,BOLBO,BRABR,BRBBB,BRNBN,BTNBT,BWABW,CAFCF,CANCA,CCKCC,CHECH,CHLCL,CHNCN,CIVCI,'
  'CMRCM,CODCD,COGCG,COKCK,COLCO,COMKM,CPVCV,CRICR,CUBCU,CUWCW,CXRCX,CYMKY,CYPCY,CZECZ,'
  'DEUDE,DJIDJ,DMADM,DNKDK,DOMDO,DZADZ,ECUEC,EGYEG,ERIER,ESPES,ESTEE,ETHET,FINFI,FJIFJ,'
  'FLKFK,FRAFR,FROFO,FSMFM,GABGA,GBRGB,GEOGE,GGYGG,GHAGH,GIBGI,GINGN,GLPGP,GMBGM,GNBGW,'
  'GNQGQ,GRCGR,GRDGD,GRLGL,GTMGT,GUFGF,GUMGU,GUYGY,HKGHK,HNDHN,HRVHR,HTIHT,HUNHU,IDNID,'
  'IMNIM,INDIN,IOTIO,IRLIE,IRNIR,IRQIQ,ISLIS,ISRIL,ITAIT,JAMJM,JEYJE,JORJO,JPNJP,KAZKZ,'
  'KENKE,KGZKG,KHMKH,KIRKI,KNAKN,KORKR,KWTKW,LAOLA,LBNLB,LBRLR,LBYLY,LCALC,LIELI,LKALK,'
  'LSOLS,LTULT,LUXLU,LVALV,MACMO,MAFMF,MARMA,MCOMC,MDAMD,MDGMG,MDVMV,MEXMX,MHLMH,MKDMK,'
  'MLIML,MLTMT,MMRMM,MNEME,MNGMN,MNPMP,MOZMZ,MRTMR,MSRMS,MTQMQ,MUSMU,MWIMW,MYSMY,MYTYT,'
  'NAMNA,NCLNC,NERNE,NFKNF,NGANG,NICNI,NIUNU,NLDNL,NORNO,NPLNP,NRUNR,NZLNZ,OMNOM,PAKPK,'
  'PANPA,PCNPN,PERPE,PHLPH,PLWPW,PNGPG,POLPL,PRIPR,PRKKP,PRTPT,PRYPY,PSEPS,PYFPF,QATQA,'
  'REURE,ROURO,RUSRU,RWARW,SAUSA,SDNSD,SENSN,SGPSG,SHNSH,SJMSJ,SLBSB,SLESL,SLVSV,SMRSM,'
  'SOMSO,SPMPM,SRBRS,SSDSS,STPST,SURSR,SVKSK,SVNSI,SWESE,SWZSZ,SXMSX,SYCSC,SYRSY,TCATC,'
  'TCDTD,TGOTG,THATH,TJKTJ,TKLTK,TKMTM,TLSTL,TONTO,TTOTT,TUNTN,TURTR,TUVTV,TWNTW,TZATZ,'
  'UGAUG,UKRUA,UMIUM,URYUY,USAUS,UZBUZ,VATVA,VCTVC,VENVE,VGBVG,VIRVI,VNMVN,VUTVU,WLFWF,'
  'WSMWS,YEMYE,ZAFZA,ZMBZM,ZWEZW,'
  ])
    for (final entry in line.split(','))
      if (entry.length >= 5) entry.substring(0, 3): entry.substring(3, 5),
};

/// One HTTP round trip, reduced to what the checks read.
@immutable
class UnlockResponse {
  const UnlockResponse({
    required this.status,
    required this.finalUrl,
    required this.body,
    this.headers = const {},
  });

  final int status;

  /// Where the request ended up. Several checks ask a domain-neutral question
  /// ("which country does this service think I am in") whose answer is only in
  /// the redirect target.
  final Uri finalUrl;
  final String body;

  /// Lower-cased header names, comma-joined when repeated.
  final Map<String, String> headers;

  bool get ok => status >= 200 && status < 300;
  String? header(String name) => headers[name.toLowerCase()];
}

/// The transport seam.
///
/// The checks are the part worth testing, and they need to be testable against
/// canned responses rather than the live internet: a service that changes its
/// markup would otherwise turn a green suite red for no reason.
abstract interface class UnlockHttp {
  Future<UnlockResponse> get(
    Uri url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  });

  Future<UnlockResponse> postJson(
    Uri url,
    Object body, {
    Map<String, String>? headers,
  });

  Future<UnlockResponse> postForm(
    Uri url,
    Map<String, String> fields, {
    Map<String, String>? headers,
  });

  void close();
}

/// [UnlockHttp] over the running core's mixed inbound.
///
/// Every request goes through the node under test or not at all: no environment
/// proxy, no direct fallback. A silent direct request would report *this
/// machine's* region as the node's, which is the one wrong answer that looks
/// completely plausible.
class IoUnlockHttp implements UnlockHttp {
  IoUnlockHttp({
    required String proxy,
    Duration timeout = const Duration(seconds: 20),
    String userAgent = defaultUnlockUserAgent,
  }) : _timeout = timeout,
       _userAgent = userAgent {
    _client = HttpClient()
      ..connectionTimeout = timeout
      // A middlebox that re-signs TLS is common on the networks where someone
      // reaches for this page; refusing its certificate would report "blocked"
      // for a service that answered fine.
      ..badCertificateCallback = (_, _, _) => true;
    if (proxy.isNotEmpty) {
      _client.findProxy = (_) => 'PROXY $proxy';
    }
  }

  final Duration _timeout;
  final String _userAgent;
  late final HttpClient _client;

  /// Enough for the largest page any check reads (a YouTube or Netflix landing
  /// page is a few hundred KiB) while bounding what a hostile/broken endpoint
  /// can make this process allocate.
  static const _bodyLimit = 4 << 20;

  @override
  Future<UnlockResponse> get(
    Uri url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) => _send('GET', url, headers: headers, followRedirects: followRedirects);

  @override
  Future<UnlockResponse> postJson(
    Uri url,
    Object body, {
    Map<String, String>? headers,
  }) => _send(
    'POST',
    url,
    headers: {...?headers, 'content-type': 'application/json'},
    body: jsonEncode(body),
  );

  @override
  Future<UnlockResponse> postForm(
    Uri url,
    Map<String, String> fields, {
    Map<String, String>? headers,
  }) => _send(
    'POST',
    url,
    headers: {
      ...?headers,
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: Uri(queryParameters: fields).query,
  );

  Future<UnlockResponse> _send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    String? body,
    bool followRedirects = true,
  }) async {
    final request = await _client.openUrl(method, url).timeout(_timeout);
    request.followRedirects = followRedirects;
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    headers?.forEach(request.headers.set);
    if (body != null) request.write(body);
    final response = await request.close().timeout(_timeout);

    final headerMap = <String, String>{};
    response.headers.forEach((name, values) {
      headerMap[name.toLowerCase()] = values.join(', ');
    });

    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _bodyLimit) break;
    }
    return UnlockResponse(
      status: response.statusCode,
      // `redirects` records the chain even when it was followed, so the final
      // hop is available without observing the 3xx by hand.
      finalUrl: response.redirects.isEmpty
          ? url
          : url.resolveUri(response.redirects.last.location),
      body: utf8.decode(bytes, allowMalformed: true),
      headers: headerMap,
    );
  }

  @override
  void close() => _client.close(force: true);
}
