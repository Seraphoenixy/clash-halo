/// One subscription-download implementation for both the window and the CLI.
///
/// It lived in `AppController` first, which meant the CLI had its own copy and
/// the two could — and did — disagree about timeouts, the User-Agent and what
/// counts as a failed body. A provider that worked in one entry point and failed
/// in the other is the worst kind of bug to explain, so the policy is here, in a
/// package both entry points already depend on.
///
/// **Proxying.** `dart:io`'s `HttpClient` never reads the system proxy, so a
/// provider that is only reachable through the running core needs an explicit
/// tunnel. [proxyUrl] sets it, and [HttpClient.findProxy] does the work: for an
/// `https` URL it issues `CONNECT host:port` to the local mixed inbound and
/// speaks TLS inside the tunnel. That was verified end to end against a real
/// CONNECT server rather than assumed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'subscription_url_policy.dart';

/// What providers are shown as the client.
///
/// Panels both gate on it (`403 PLEASE CHANGE CLIENT`) and pick the response
/// *format* with it. `clash.meta` yields the Clash document the importer handles
/// most completely, including node types a base64 share list cannot express.
const String kSubscriptionUserAgent = 'clash.meta';

/// Hard cap on a subscription body. A larger response is not a node list worth
/// importing, and reading it costs memory on the UI isolate.
const int kMaxSubscriptionBytes = 8 * 1024 * 1024;

/// Raised for every failure the user could act on: bad URL, HTTP status with a
/// body hint, timeout, refused connection, oversized body.
/// A download that succeeded, plus which candidate URL produced it.
class SubscriptionDownload {
  const SubscriptionDownload({
    required this.body,
    required this.usedUrl,
    this.fallbackDays = 0,
  });

  final String body;

  /// The URL that actually returned content; equal to the resolved URL when
  /// there was no fallback.
  final String usedUrl;

  /// How many days older than "today" the file is. Non-zero means a daily
  /// source had not published yet and an older file was used.
  final int fallbackDays;

  bool get usedFallback => fallbackDays > 0;
}

class SubscriptionFetchException implements Exception {
  SubscriptionFetchException(this.message, {this.notFound = false});

  final String message;

  /// Whether the server answered 404.
  ///
  /// A field rather than string-matching the message: the look-back for daily
  /// sources must react to the status code, and matching on "HTTP 404" would
  /// break the moment the wording changes or a body hint contains the digits.
  final bool notFound;

  bool get isNotFound => notFound;

  @override
  String toString() => message;
}

class SubscriptionFetcher {
  /// [timeout] bounds connect, headers and the gap between body chunks.
  ///
  /// [totalTimeout] is the wall-clock cap for the whole transfer. Without it a
  /// server that trickles one chunk just under the gap limit can stall for as
  /// long as it likes — observed on a multi-megabyte source that never returned.
  ///
  /// [proxyUrl] is a proxy the request is tunnelled through, e.g.
  /// `http://127.0.0.1:7890`. Null means direct.
  SubscriptionFetcher({
    this.timeout = const Duration(seconds: 20),
    Duration? totalTimeout,
    this.proxyUrl,
    this.userAgent = kSubscriptionUserAgent,
    this.onBadCertificate,
  }) : totalTimeout = totalTimeout ?? timeout * 3;

  final Duration timeout;
  final Duration totalTimeout;
  final String? proxyUrl;
  final String userAgent;

  /// Test-only escape hatch for a self-signed loopback server.
  ///
  /// Never set by production callers: accepting an arbitrary certificate for a
  /// subscription URL is exactly the MITM this client is meant to avoid.
  final bool Function(X509Certificate certificate, String host, int port)?
      onBadCertificate;

  /// The proxy in the form `HttpClient.findProxy` expects, or null.
  String? get _proxyDirective {
    final raw = proxyUrl?.trim();
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort
        ? uri.port
        : switch (uri.scheme) {
            'socks5' || 'socks' => 1080,
            _ => 8080,
          };
    // The core's mixed inbound answers both HTTP CONNECT and SOCKS on the same
    // port, so either spelling works. Keep the directive the user's scheme
    // implies rather than always claiming PROXY: a SOCKS-only proxy reached with
    // a CONNECT request fails with a confusing parse error inside the tunnel.
    if (uri.scheme == 'socks5' || uri.scheme == 'socks') {
      return 'SOCKS ${uri.host}:$port';
    }
    return 'PROXY ${uri.host}:$port';
  }

  /// Downloads [rawUrl], expanding `{date}` and looking back a few days when a
  /// daily source has not published today's file yet.
  ///
  /// Only a 404 triggers the look-back. A timeout, a DNS failure or a 5xx is a
  /// real problem with the network or the source and would fail the same way for
  /// every candidate, so retrying seven of them would just make the error take
  /// seven times as long to appear.
  Future<SubscriptionDownload> fetchWithDateFallback(
    String rawUrl, {
    DateTime? now,
  }) async {
    final candidates = dateCandidateUrls(rawUrl, now: now);
    if (candidates.isEmpty) {
      final body = await fetch(Uri.parse(rawUrl));
      return SubscriptionDownload(body: body, usedUrl: rawUrl);
    }
    Object? firstError;
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      try {
        final body = await fetch(Uri.parse(candidate));
        return SubscriptionDownload(
          body: body,
          usedUrl: candidate,
          fallbackDays: index,
        );
      } on SubscriptionFetchException catch (error) {
        firstError ??= error;
        if (!error.isNotFound) rethrow;
      }
    }
    throw firstError is SubscriptionFetchException
        ? firstError
        : SubscriptionFetchException('订阅下载失败：$rawUrl');
  }

  Future<String> fetch(Uri uri) async {
    if (!uri.isScheme('http') && !uri.isScheme('https')) {
      // Never interpolate the whole URI: it carries the subscription token,
      // and this message is persisted as last_error and printed by the CLI.
      throw SubscriptionFetchException(
        '订阅地址必须是 HTTP 或 HTTPS（收到 ${uri.scheme}://）',
      );
    }
    final directive = _proxyDirective;
    final client = HttpClient()..connectionTimeout = timeout;
    final checkCertificate = onBadCertificate;
    if (checkCertificate != null) {
      client.badCertificateCallback = checkCertificate;
    }
    if (directive != null) {
      client.findProxy = (_) => directive;
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        // Read a little of the body: these panels put the real instruction
        // ("PLEASE CHANGE CLIENT") in it, and a bare code sends the reader
        // looking for a network fault.
        final hint = await _peek(response);
        throw SubscriptionFetchException(
          'HTTP ${response.statusCode}${hint.isEmpty ? '' : '：$hint'}',
          notFound: response.statusCode == 404,
        );
      }
      final bytes = <int>[];
      final deadline = DateTime.now().add(totalTimeout);
      await for (final chunk in response.timeout(timeout)) {
        if (DateTime.now().isAfter(deadline)) {
          throw SubscriptionFetchException(
            '下载超过 ${totalTimeout.inSeconds}s 总时长上限',
          );
        }
        if (bytes.length + chunk.length > kMaxSubscriptionBytes) {
          throw SubscriptionFetchException('订阅超过 8 MiB 限制');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on SubscriptionFetchException {
      rethrow;
    } on TimeoutException {
      throw SubscriptionFetchException(
        '下载超时（${timeout.inSeconds}s）${_where(directive)}',
      );
    } on SocketException catch (error) {
      // A refused/timed-out proxy is worth naming separately: the user turned the
      // proxy switch on, so "connect to 127.0.0.1:7890 failed" is the actual
      // problem and "无法连接 raw.githubusercontent.com" is a misdirection.
      if (directive != null) {
        throw SubscriptionFetchException(
          '经代理 $proxyUrl 请求失败：${error.message}。'
          '请确认内核已启动（代理未运行时代理端口没人监听）',
        );
      }
      throw SubscriptionFetchException('无法连接 ${uri.host}：${error.message}');
    } on HttpException catch (error) {
      throw SubscriptionFetchException('下载失败：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  String _where(String? directive) =>
      directive == null ? '' : '（经代理 $proxyUrl）';

  /// Reads at most 200 bytes of a non-200 body for a human-readable hint.
  Future<String> _peek(HttpClientResponse response) async {
    final buffer = StringBuffer();
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 2))) {
        buffer.write(utf8.decode(chunk, allowMalformed: true));
        if (buffer.length >= 200) break;
      }
    } catch (_) {
      // A failed peek must not replace the status code we already have.
    }
    final text = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}