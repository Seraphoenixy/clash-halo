import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

/// Owns the catalogue repositories and the per-revision read caches.
///
/// Pages call [loadNodes] from `build`, so an uncached call is a full
/// `SELECT *` plus JSON decoding on every frame. Keeping the cache next to the
/// repositories (instead of in AppController) makes "every write invalidates
/// the reads" one object's rule. AppController still owns the revision
/// notifier; it calls [invalidate] and then bumps it.
class CatalogStore {
  NodeRepository? _nodes;
  SubscriptionRepository? _subscriptions;
  SubscriptionGroupRepository? _groups;

  List<ProxyNode>? _nodesCache;
  List<SubscriptionProfile>? _profilesCache;
  List<SubscriptionGroup>? _groupsCache;

  bool get ready => _nodes != null;

  /// Binds the repositories to an opened database. Re-attaching drops all
  /// cached reads, so a reopened store cannot serve rows from the old one.
  void attach(HaloStore store) {
    _nodes = NodeRepository(store);
    _subscriptions = SubscriptionRepository(store);
    _groups = SubscriptionGroupRepository(store);
    invalidate();
  }

  NodeRepository get nodeRepo => _nodes ?? (throw StateError('数据库不可用'));

  SubscriptionRepository get subscriptionRepo =>
      _subscriptions ?? (throw StateError('数据库不可用'));

  SubscriptionGroupRepository get groupRepo =>
      _groups ?? (throw StateError('数据库不可用'));

  /// Read paths degrade to an empty list when the database is unavailable:
  /// the UI must still render and explain the problem instead of throwing
  /// while building. Write paths keep using the throwing getters above.
  List<ProxyNode> loadNodes() {
    final cached = _nodesCache;
    if (cached != null) return cached;
    final repo = _nodes;
    final list = repo == null ? const <ProxyNode>[] : repo.allNodes();
    return _nodesCache = list;
  }

  List<SubscriptionProfile> loadProfiles() {
    final cached = _profilesCache;
    if (cached != null) return cached;
    final repo = _subscriptions;
    final list = repo == null ? const <SubscriptionProfile>[] : repo.allProfiles();
    return _profilesCache = list;
  }

  List<SubscriptionGroup> loadGroups() {
    final cached = _groupsCache;
    if (cached != null) return cached;
    final repo = _groups;
    final list = repo == null ? const <SubscriptionGroup>[] : repo.allGroups();
    return _groupsCache = list;
  }

  /// One node without materialising the list; null when the store is closed.
  ProxyNode? nodeByIdOrNull(String id) => _nodes?.nodeById(id);

  /// Drops the cached table reads. Any repository write must call this, or the
  /// pages keep rendering the previous list.
  void invalidate() {
    _nodesCache = null;
    _profilesCache = null;
    _groupsCache = null;
  }

  /// The built-in 本地 subscription, creating it on first use.
  ///
  /// Every locally imported node belongs to it, so the node page can treat
  /// 本地 like any other source instead of special-casing a NULL profile.
  SubscriptionProfile ensureLocalProfile() {
    final profile = subscriptionRepo.ensureLocalProfile(
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    invalidate();
    return profile;
  }
}
