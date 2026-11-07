/// What the outside world sees when traffic leaves through the current node.
///
/// This is deliberately not derived from the config: a node named "日本" can exit
/// in Korea, and a subscription's advertised region is marketing rather than
/// fact. The only honest source is an IP-echo service reached *through* the node,
/// which is why the lookup goes through the running core's mixed inbound exactly
/// like a browser on this machine would.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One echo service's answer, normalised.
@immutable
class ExitInfo {
  const ExitInfo({
    required this.ip,
    this.countryCode = '',
    this.country = '',
    this.region = '',
    this.city = '',
    this.organization = '',
    this.asn = 0,
    this.timezone = '',
    this.source = '',
  });

  final String ip;
  final String countryCode;
  final String country;
  final String region;
  final String city;
  final String organization;
  final int asn;
  final String timezone;

  /// Which service answered. Shown in the card so a surprising answer can be
  /// traced to the service rather than blamed on the node.
  final String source;

  /// Country code plus the country name, when the service supplied both.
  String get location {
    final parts = [
      if (country.isNotEmpty) country,
      if (region.isNotEmpty) region,
      if (city.isNotEmpty) city,
    ];
    return parts.isEmpty ? (countryCode.isEmpty ? '—' : countryCode) : parts.join(' · ');
  }

  String get asnLabel => asn > 0 ? 'AS$asn' : '';

  String get network {
    final parts = [
      if (organization.isNotEmpty) organization,
      if (asnLabel.isNotEmpty) asnLabel,
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  ExitInfo withSource(String value) => ExitInfo(
    ip: ip,
    countryCode: countryCode,
    country: country,
    region: region,
    city: city,
    organization: organization,
    asn: asn,
    timezone: timezone,
    source: value,
  );

  static String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');
  static int _int(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) {
      return int.tryParse(v.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    }
    return 0;
  }

  /// `https://api.ip.sb/geoip`
  static ExitInfo? fromIpSb(Object? json) {
    if (json is! Map) return null;
    final ip = _str(json['ip']);
    if (ip.isEmpty) return null;
    return ExitInfo(
      ip: ip,
      countryCode: _str(json['country_code']),
      country: _str(json['country']),
      region: _str(json['region']),
      city: _str(json['city']),
      organization: _str(json['organization'] ?? json['isp']),
      asn: _int(json['asn']),
      timezone: _str(json['timezone']),
      source: 'ip.sb',
    );
  }

  /// `https://ipapi.co/json` — `asn` arrives as `"AS12345"`.
  static ExitInfo? fromIpapiCo(Object? json) {
    if (json is! Map) return null;
    final ip = _str(json['ip']);
    if (ip.isEmpty) return null;
    return ExitInfo(
      ip: ip,
      countryCode: _str(json['country_code']),
      country: _str(json['country_name']),
      region: _str(json['region']),
      city: _str(json['city']),
      organization: _str(json['org']),
      asn: _int(json['asn']),
      timezone: _str(json['timezone']),
      source: 'ipapi.co',
    );
  }

  /// `https://api.ipapi.is/` — nested under `location` and `asn`.
  static ExitInfo? fromIpapiIs(Object? json) {
    if (json is! Map) return null;
    final ip = _str(json['ip']);
    if (ip.isEmpty) return null;
    final location = json['location'];
    final asn = json['asn'];
    String pick(Object? map, String key) =>
        map is Map ? _str(map[key]) : '';
    return ExitInfo(
      ip: ip,
      countryCode: pick(location, 'country_code'),
      country: pick(location, 'country'),
      region: pick(location, 'state'),
      city: pick(location, 'city'),
      organization: pick(asn, 'org'),
      asn: asn is Map ? _int(asn['asn']) : 0,
      timezone: pick(location, 'timezone'),
      source: 'ipapi.is',
    );
  }
}

/// A failed lookup, split into what to show and what to explain.
///
/// The raw reasons (a timeout per service, a TLS handshake failure) belong in a
/// tooltip: printing them in the card turns one line of "not reachable" into
/// four lines of Dart exception text.
class ExitLookupError implements Exception {
  const ExitLookupError(this.summary, this.details);
  final String summary;
  final String details;

  @override
  String toString() => summary;
}

/// One echo service and how to read its answer.
class ExitService {
  const ExitService(this.name, this.url, this.parse, {this.secure = true});
  final String name;
  final String url;
  final ExitInfo? Function(Object? json) parse;

  /// Whether the request is encrypted end to end. The plain-HTTP entries are
  /// tried only after every TLS service has failed, so a working airport is
  /// never downgraded just because the cleartext host answered faster.
  final bool secure;
}

/// The services tried in order.
///
/// The plain-HTTP entry sits second on purpose. Measured on a real airport
/// that allows only a narrow set of TLS destinations: `https://api.ip.sb/geoip`
/// failed while `http://` on the same host and path answered in five seconds.
/// Trying the same host over the other scheme before moving to another service
/// is not a guess about the network, and the card labels which scheme answered
/// so a reader knows the value crossed the wire in the clear.
const exitServices = [
  ExitService('ip.sb', 'https://api.ip.sb/geoip', ExitInfo.fromIpSb),
  ExitService(
    'ip.sb（HTTP）',
    'http://api.ip.sb/geoip',
    _ipSbInsecure,
    secure: false,
  ),
  ExitService('ipapi.co', 'https://ipapi.co/json', ExitInfo.fromIpapiCo),
  ExitService('ipapi.is', 'https://api.ipapi.is/', ExitInfo.fromIpapiIs),
];

ExitInfo? _ipSbInsecure(Object? json) =>
    ExitInfo.fromIpSb(json)?.withSource('ip.sb（HTTP）');

/// Fetches the exit information through the running node.
///
/// [transport] exists so the parsing and the fallback order can be tested
/// without a network: it takes a URL and returns the decoded JSON object.
class ExitInfoService {
  ExitInfoService({
    required this.proxyResolver,
    this.transport,
    // Ten: the measured round trip through a working airport was 7.4 s, so a
    // tighter budget rejects the exits this card exists for. The TLS services
    // are raced, so the whole attempt is still bounded by this one value (plus
    // one more for the cleartext fallback).
    this.timeout = const Duration(seconds: 10),
  });

  /// The mixed inbound of the running core, or null when it is not running.
  final String? Function() proxyResolver;

  /// Overrides the HTTP call. Receives the URL and must return decoded JSON.
  final Future<Object?> Function(Uri url, String proxy, Duration timeout)?
  transport;

  final Duration timeout;

  /// Tries every service in order and returns the first usable answer.
  ///
  /// Throws [StateError] with the collected reasons only when nothing answered:
  /// a partially failed lookup that still produced an IP is a success.
  Future<ExitInfo> lookup() async {
    final proxy = proxyResolver();
    if (proxy == null || proxy.isEmpty) {
      throw const ExitLookupError(
        '内核未运行，无法查询',
        '出口信息必须经当前节点查询，直连会把本机地址当成节点地址',
      );
    }
    final failures = <String>[];
    // Race the TLS services instead of walking them one by one: a real airport
    // answered this host in 7.4 s but also returned a 502 after 10 s, so a
    // sequential walk spends its whole budget on the first unlucky service.
    final secure = await _race(
      exitServices.where((service) => service.secure).toList(),
      proxy,
      failures,
    );
    if (secure != null) return secure;
    final fallback = await _race(
      exitServices.where((service) => !service.secure).toList(),
      proxy,
      failures,
    );
    if (fallback != null) return fallback;
    throw ExitLookupError(
      '出口查询服务都不可达',
      // Several exits only allow a narrow set of hosts, so this is a common and
      // not very actionable outcome: the summary says what happened, the detail
      // says which service failed how, for the tooltip.
      failures.join('；'),
    );
  }

  /// The first usable answer among [services], or null when all of them failed.
  ///
  /// Every service is asked at once, so the result arrives as soon as any one
  /// of them answers and the total wait is one timeout rather than the sum of
  /// all of them.
  Future<ExitInfo?> _race(
    List<ExitService> services,
    String proxy,
    List<String> failures,
  ) async {
    if (services.isEmpty) return null;
    final completer = Completer<ExitInfo?>();
    var pending = services.length;
    void settle(ExitInfo? info) {
      if (completer.isCompleted) return;
      if (info != null) {
        completer.complete(info);
        return;
      }
      pending--;
      if (pending == 0) completer.complete(null);
    }

    for (final service in services) {
      unawaited(() async {
        try {
          final json = await (transport ?? _httpJson)(
            Uri.parse(service.url),
            proxy,
            timeout,
          );
          final info = service.parse(json);
          if (info == null) failures.add('${service.name}：响应里没有 IP');
          settle(info);
        } on Object catch (e) {
          failures.add('${service.name}：${_short(e)}');
          settle(null);
        }
      }());
    }
    return completer.future;
  }

  static String _short(Object e) {
    final text = '$e';
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }

  /// A single GET through [proxy], decoded as JSON.
  ///
  /// No environment proxy and no direct fallback: a request that escaped the
  /// node would report this machine's address, which is the one wrong answer
  /// that looks completely plausible.
  Future<Object?> _httpJson(Uri url, String proxy, Duration timeout) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (_, _, _) => true;
    client.findProxy = (_) => 'PROXY $proxy';
    client.userAgent = 'clash-halo-exitinfo/1';
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > 64 << 10) break;
      }
      return jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } finally {
      client.close(force: true);
    }
  }
}
