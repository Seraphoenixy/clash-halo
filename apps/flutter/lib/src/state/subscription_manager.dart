import 'dart:async';
import 'dart:convert';

import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

/// What one subscription refresh produced.
///
/// [failed] counts entries this build could not import (an unsupported
/// protocol, a damaged line, a missing field). It is reported rather than
/// thrown: the usable nodes are already in the database by then, and the row
/// should say "48 个节点，2 条未导入" instead of pretending the refresh failed.
class SubscriptionUpdate {
  const SubscriptionUpdate({
    required this.imported,
    required this.skipped,
    required this.failed,
    this.firstFailure,
    this.failureKinds = const {},
    this.failures = const [],
    this.skippedKinds = const {},
    this.skippedSamples = const [],
    this.viaProxy = false,
  });

  /// How many rejected entries are kept for display and for the import log.
  ///
  /// Twenty is enough to recognise the shape of the problem (the window shows
  /// them in a list) and small enough that a 4000-entry list does not copy
  /// itself into the database on every refresh.
  static const int sampleFailureLimit = 20;

  final int imported;
  final int skipped;
  final int failed;
  final String? firstFailure;

  /// Rejected entries by [ImportFailureKind.wire].
  ///
  /// Separate from [failed] because the count alone cannot answer which
  /// problem the user has: 1462 entries read as a protocol gap when 1300 of
  /// them were damaged lines.
  final Map<String, int> failureKinds;

  /// The first [sampleFailureLimit] rejected entries, each carrying its raw
  /// source text so the dialog can show what was refused.
  final List<ImportIssue> failures;

  /// Skipped entries by kind. Almost always just `duplicate`.
  ///
  /// Reported next to the failures because the two are routinely confused:
  /// "1461 条未导入" is mostly nodes that were already in the list, and only
  /// the split says so.
  final Map<String, int> skippedKinds;

  /// The first few skipped entries, so 重复 can be shown rather than counted.
  final List<ImportIssue> skippedSamples;

  /// Entries skipped because the same node appeared twice in the body.
  int get duplicateCount => skippedKinds['duplicate'] ?? 0;

  /// Whether this download went through the local proxy.
  ///
  /// Reported back so the batch message can say "经代理 7，直连 6". Without it
  /// the two channels are indistinguishable from the outside: both produce the
  /// same "已更新", and a user watching for proxy traffic has no way to tell
  /// whether the row's setting was honoured.
  final bool viaProxy;

  bool get partial => failed > 0;
}

/// Refreshes subscriptions: download, import, persist, and the auto-update
/// timer.
///
/// The controller still owns the nodes/subscriptions repositories and the
/// catalog revision; this class owns the refresh state machine — which profile
/// is already updating, which one the timer should pick, and what a partially
/// importable body means.
class SubscriptionManager {
  SubscriptionManager({
    required this.subscriptions,
    required this.nodes,
    required this.importLog,
    required this.store,
    required this.proxyEndpoint,
    required this.loadProfiles,
    required this.disposed,
    required this.onCatalogChanged,
  });

  final SubscriptionRepository Function() subscriptions;
  final NodeRepository Function() nodes;
  final ImportLogRepository? Function() importLog;
  final HaloStore Function() store;
  final String Function() proxyEndpoint;
  final List<SubscriptionProfile> Function() loadProfiles;
  final bool Function() disposed;
  final void Function() onCatalogChanged;

  final Set<String> _updating = <String>{};
  Timer? _timer;

  bool isUpdating(String profileId) => _updating.contains(profileId);

  /// Arms the one-minute auto-update check. Every due profile is refreshed
  /// independently; a failing one does not stop the others.
  void startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      for (final profile in loadProfiles()) {
        if (!profile.enabled ||
            !profile.autoUpdate ||
            _updating.contains(profile.id) ||
            DateTime.now().millisecondsSinceEpoch - profile.lastUpdatedAtMs <
                profile.updateIntervalMinutes * 60000) {
          continue;
        }
        // A scheduled refresh reports its outcome to nobody: the row's own
        // state (last update time, node count, lastError) is the record.
        unawaited(
          update(profile).then<void>((_) {}).catchError((Object _) {}),
        );
      }
    });
  }

  /// Refreshes one subscription.
  ///
  /// Returns what the body actually yielded. A refresh that lands 48 of 50
  /// nodes is a success with a caveat, not a failure, and the caller needs the
  /// counts to say so instead of reporting a bare "已更新".
  ///
  /// [viaProxy] forces the download through the local mixed inbound even when
  /// the profile does not have its own switch set. That is what the
  /// 「经代理更新」button uses: the switch is the standing preference, and the
  /// button is the one-off "try it the other way" a user needs when a source is
  /// blocked and they have not yet noticed the per-row toggle.
  Future<SubscriptionUpdate> update(
    SubscriptionProfile profile, {
    bool viaProxy = false,
  }) async {
    if (!_updating.add(profile.id)) {
      return const SubscriptionUpdate(imported: 0, skipped: 0, failed: 0);
    }
    try {
      // `{date}` is expanded at fetch time, not stored expanded: a daily source
      // would otherwise be pinned to the day it was added and 404 tomorrow.
      final resolvedUrl = resolveSubscriptionUrl(profile.url);
      final uri = Uri.tryParse(resolvedUrl);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw StateError('订阅地址必须是 HTTP 或 HTTPS');
      }
      // A profile that is not remote (the built-in 本地 one) has no URL to fetch.
      // Refreshing it is a no-op that must not be reported as a failure.
      if (!profile.isRemote) {
        throw StateError('「${profile.name}」是本地订阅，没有可下载的地址');
      }
      // The button forces the proxy; otherwise the row's own choice wins, and an
      // unset choice falls back to the host policy (GitHub sources go through
      // the proxy, because connecting to them directly is reset on this class of
      // network).
      final useProxy = viaProxy || profile.useProxyFor(resolvedUrl);
      // Downloading policy lives in halo_domain so the CLI cannot drift from the
      // window: same User-Agent, same timeouts, same 8 MiB ceiling.
      // The profile's own endpoint wins over the current default: a row set up
      // while the core listened on a different port must keep working after the
      // user moves the port back, and vice versa.
      final download = await SubscriptionFetcher(
        proxyUrl: useProxy ? (profile.proxyUrl ?? proxyEndpoint()) : null,
      ).fetchWithDateFallback(profile.url);
      final body = download.body;
      final imported = importNodes(body);
      // A subscription is a list, not an all-or-nothing document: one node of a
      // protocol this build does not implement must not cost the user the other
      // fifty. Only a body that yields nothing at all is a failed download.
      if (imported.nodes.isEmpty) {
        final why = imported.failed.isEmpty
            ? '响应里没有节点'
            : imported.failed.first.message;
        // The first bytes of the body are the evidence a user needs: this
        // source answers `Cg==` (an empty Base64 body) and a blocked one answers
        // `PLEASE CHANGE CLIENT`, and "无法识别的链接" describes neither.
        final head = body.replaceAll(RegExp(r'\s+'), ' ').trim();
        final peek = head.length <= 60 ? head : '${head.substring(0, 60)}…';
        throw StateError(
          '订阅响应不是节点列表（开头：$peek），已保留旧数据'
          '${imported.failed.isEmpty ? '' : '；解析：$why'}',
        );
      }
      if (disposed()) {
        return const SubscriptionUpdate(imported: 0, skipped: 0, failed: 0);
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final samples = imported.failed
          .take(SubscriptionUpdate.sampleFailureLimit)
          .toList();
      final skippedSamples = imported.skipped
          .take(SubscriptionUpdate.sampleFailureLimit)
          .toList();
      store().transaction((_) {
        nodes().replaceProfileNodes(profile.id, imported.nodes, nowMs: now);
        subscriptions().upsert(
          profile.copyWith(
            lastUpdatedAtMs: now,
            // A daily source that fell back to an older file must say so. Left
            // silent, a subscription serving last week's nodes looks exactly
            // like a fresh one, and the user has no way to notice the source
            // stopped publishing.
            lastError: download.usedFallback
                ? '当天文件尚未发布，已使用 ${download.fallbackDays} 天前的文件'
                : null,
            clearLastError: !download.usedFallback,
            nodeCount: imported.nodes.length,
          ),
        );
        // The audit row is written in the same transaction as the nodes it
        // describes: a refresh that stored 48 nodes and lost the record of the
        // other 1462 would leave exactly the question this log answers
        // unanswerable.
        importLog()?.record(
          atMs: now,
          source: profile.name,
          format: imported.sourceFormat,
          imported: imported.nodes.length,
          skipped: imported.skippedCount,
          failed: imported.failedCount,
          detail: jsonEncode({
            'kinds': imported.failureKinds,
            'samples': [for (final issue in samples) issue.toJson()],
            'omitted': imported.failedCount - samples.length,
            'skippedKinds': imported.skippedKinds,
            'skippedSamples': [
              for (final issue in skippedSamples) issue.toJson(),
            ],
            'skippedOmitted': imported.skippedCount - skippedSamples.length,
            'channel': useProxy ? 'proxy' : 'direct',
          }),
        );
      });
      return SubscriptionUpdate(
        imported: imported.nodes.length,
        skipped: imported.skippedCount,
        failed: imported.failedCount,
        firstFailure: imported.failed.isEmpty
            ? null
            : imported.failed.first.message,
        failureKinds: imported.failureKinds,
        failures: samples,
        skippedKinds: imported.skippedKinds,
        skippedSamples: skippedSamples,
        viaProxy: useProxy,
      );
    } catch (error) {
      if (!disposed()) {
        subscriptions().markFailed(
          profile.id,
          atMs: DateTime.now().millisecondsSinceEpoch,
          error: '$error',
        );
      }
      rethrow;
    } finally {
      _updating.remove(profile.id);
      if (!disposed()) {
        onCatalogChanged();
      }
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
