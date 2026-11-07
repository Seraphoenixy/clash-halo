/// Subscription profile: a remote source plus its local update state.
library;

import '../subscription_url_policy.dart';

/// What kind of source a profile is.
///
/// `local` is the important one here. The 本地 nodes used to be modelled as "the
/// absence of a profile" (`profile_id IS NULL`), which meant they could not be
/// named, could not sit in a group, and needed a special case in every place
/// that enumerated sources: the node page's chips, the tray's 订阅 submenu, the
/// backup payload, the CLI's listing. Making the local list an actual profile
/// row removes those branches: there is one kind of thing, and some of them have
/// no URL to fetch.
enum SubscriptionKind {
  /// A remote URL. Refreshable.
  remote('remote'),

  /// Nodes pasted or imported from a file. Not refreshable, but renameable,
  /// groupable and groupable-into like any other source.
  local('local');

  const SubscriptionKind(this.wire);
  final String wire;

  static SubscriptionKind fromWire(String? value) =>
      SubscriptionKind.values.firstWhere(
        (k) => k.wire == value,
        orElse: () => SubscriptionKind.remote,
      );
}

class SubscriptionProfile {
  const SubscriptionProfile({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.autoUpdate = false,
    this.updateIntervalMinutes = 1440,
    this.lastUpdatedAtMs = 0,
    this.lastError,
    this.nodeCount = 0,
    this.etag,
    this.createdAtMs = 0,
    this.sortIndex = 0,
    this.kind = SubscriptionKind.remote,
    this.groupId,
    this.useProxy,
    this.proxyUrl,
  });

  final String id;
  final String name;
  final String url;
  final bool enabled;
  final bool autoUpdate;
  final int updateIntervalMinutes;
  final int lastUpdatedAtMs;
  final String? lastError;
  final int nodeCount;
  final String? etag;
  final int createdAtMs;
  final int sortIndex;

  /// Remote URL or a local bucket of imported nodes.
  final SubscriptionKind kind;

  /// Owning group, or null when ungrouped.
  final String? groupId;

  /// Endpoint used when [useProxy] is on, e.g. `http://127.0.0.1:7890`.
  ///
  /// Stored per profile rather than assumed: the core's port is user-editable,
  /// and a switch that silently fell back to a hard-coded port would keep
  /// failing on exactly the machines where the user moved it. Null means "use
  /// the current default", which is what a row created before this column means.
  final String? proxyUrl;

  /// Whether refreshing this source goes through the app's own proxy.
  ///
  /// **Tri-state.** `true` and `false` are explicit user choices; `null` means
  /// "never chosen", and only then does the host policy apply
  /// ([shouldUseProxyFor]). A plain bool could not express this: it made
  /// "the user turned it off" indistinguishable from "the default", so adding a
  /// host-based default would silently override a deliberate opt-out.
  ///
  /// Per-profile rather than global because the case that motivates it is
  /// specific: one provider is unreachable directly while everything else is
  /// fine, and a global switch would slow down everything that works.
  final bool? useProxy;

  /// The value a fetch should use, resolving `null` through the host policy.
  bool useProxyFor(String url) => shouldUseProxyFor(url, override: useProxy);

  /// True when this profile has a URL that can be fetched.
  bool get isRemote => kind == SubscriptionKind.remote;

  /// URL safe to render in a list, a screenshot or a log line.
  ///
  /// Two things are hidden, because either can be a credential:
  ///
  ///  * `userInfo` before the `@` — the obvious case;
  ///  * most of the path and *all* of the query string — subscription providers
  ///    routinely put the token there (`/sub?token=…`,
  ///    `/api/v1/client/<uuid>/clash`), so showing the path verbatim leaks the
  ///    same secret in a less obvious place. The review found that the list
  ///    printed the full endpoint, which means an ordinary screenshot exposed it.
  ///
  /// The first path segment is kept so two subscriptions on the same host stay
  /// distinguishable at a glance; the rest of the path becomes `…`. The full
  /// URL is still available deliberately, through [fullUrl], which the row puts
  /// behind an explicit reveal action.
  String get displayUrl {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (!uri.hasAuthority) return url;
    final user = uri.userInfo.isEmpty ? '' : '***@';
    final port = uri.hasPort ? ':${uri.port}' : '';
    final host = '${uri.scheme}://$user${uri.host}$port';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return uri.hasQuery ? '$host/…' : '$host/';
    }
    // One segment plus an ellipsis reads as "there is more", which is the
    // truth; printing the whole path reads as "this is the address".
    final head = segments.first.length > 12
        ? '${segments.first.substring(0, 12)}…'
        : segments.first;
    final hidden = segments.length > 1 || uri.hasQuery;
    return '$host/$head${hidden ? '/…' : ''}';
  }

  /// The unredacted URL, for a deliberate copy or reveal action.
  ///
  /// Kept as a named getter rather than reaching for [url] directly so the
  /// places that expose a credential are greppable in one step.
  String get fullUrl => url;

  /// True when [displayUrl] is hiding something, so the UI only offers the
  /// reveal affordance when it would show anything new.
  bool get hasHiddenUrlParts => displayUrl != url;

  SubscriptionProfile copyWith({
    String? name,
    String? url,
    bool? enabled,
    bool? autoUpdate,
    int? updateIntervalMinutes,
    int? lastUpdatedAtMs,
    String? lastError,
    bool clearLastError = false,
    int? nodeCount,
    String? etag,
    int? sortIndex,
    SubscriptionKind? kind,
    bool? useProxy,
    bool clearUseProxy = false,
    String? proxyUrl,
    String? groupId,
    bool clearGroup = false,
  }) =>
      SubscriptionProfile(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        enabled: enabled ?? this.enabled,
        autoUpdate: autoUpdate ?? this.autoUpdate,
        updateIntervalMinutes: updateIntervalMinutes ?? this.updateIntervalMinutes,
        lastUpdatedAtMs: lastUpdatedAtMs ?? this.lastUpdatedAtMs,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        nodeCount: nodeCount ?? this.nodeCount,
        etag: etag ?? this.etag,
        createdAtMs: createdAtMs,
        sortIndex: sortIndex ?? this.sortIndex,
        kind: kind ?? this.kind,
        // null is a real value here ("ungrouped"), so moving a subscription out
        // of a group needs its own flag instead of passing null.
        groupId: clearGroup ? null : (groupId ?? this.groupId),
        // `null` is a real stored state here, so clearing back to "no choice"
        // needs its own flag rather than a null argument.
        useProxy: clearUseProxy ? null : (useProxy ?? this.useProxy),
        proxyUrl: proxyUrl ?? this.proxyUrl,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'autoUpdate': autoUpdate,
        'updateIntervalMinutes': updateIntervalMinutes,
        'lastUpdatedAtMs': lastUpdatedAtMs,
        if (lastError != null) 'lastError': lastError,
        'nodeCount': nodeCount,
        if (etag != null) 'etag': etag,
        'createdAtMs': createdAtMs,
        'sortIndex': sortIndex,
        'kind': kind.wire,
        if (groupId != null) 'groupId': groupId,
        if (useProxy != null) 'useProxy': useProxy,
        if (proxyUrl != null) 'proxyUrl': proxyUrl,
      };

  factory SubscriptionProfile.fromJson(Map<String, Object?> json) => SubscriptionProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        autoUpdate: json['autoUpdate'] as bool? ?? false,
        updateIntervalMinutes: (json['updateIntervalMinutes'] as num?)?.toInt() ?? 1440,
        lastUpdatedAtMs: (json['lastUpdatedAtMs'] as num?)?.toInt() ?? 0,
        lastError: json['lastError'] as String?,
        nodeCount: (json['nodeCount'] as num?)?.toInt() ?? 0,
        etag: json['etag'] as String?,
        createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
        sortIndex: (json['sortIndex'] as num?)?.toInt() ?? 0,
        kind: SubscriptionKind.fromWire(json['kind'] as String?),
        groupId: json['groupId'] as String?,
        // Absent means "never chosen", which is different from `false`.
        useProxy: json['useProxy'] as bool?,
        proxyUrl: json['proxyUrl'] as String?,
      );
}
