/// A named bucket that subscriptions can be filed under.
///
/// Why this exists: once a user has ten subscriptions, the flat list stops
/// being a list and becomes a wall — the rows they actually refresh are mixed
/// with sources they keep only for one node. A group is the smallest structure
/// that fixes that: one level, one name, no nesting. Nesting was considered and
/// rejected, because the node list has to stay flat at the point where a node is
/// actually chosen, so a tree would only add a second way to mis-file things.
///
/// A group owns no nodes and no connection state. Deleting one therefore never
/// orphans a node: its subscriptions simply become ungrouped, which is the same
/// state a fresh import is in.
library;

/// Fixed id of the group that "no group" is displayed under.
///
/// Stored membership is `NULL`, not this value: a `NULL` group_id is what an
/// old database (and a subscription created before groups existed) already
/// means, so no backfill can disagree with reality. The sentinel exists only for
/// filter state in the UI, where "所有" and "未分组" need distinct cases and
/// `null` is taken by "all".
const String kUngroupedGroupId = '__ungrouped__';

class SubscriptionGroup {
  const SubscriptionGroup({
    required this.id,
    required this.name,
    this.sortIndex = 0,
    this.createdAtMs = 0,
  });

  final String id;
  final String name;
  final int sortIndex;
  final int createdAtMs;

  SubscriptionGroup copyWith({
    String? name,
    int? sortIndex,
  }) =>
      SubscriptionGroup(
        id: id,
        name: name ?? this.name,
        sortIndex: sortIndex ?? this.sortIndex,
        createdAtMs: createdAtMs,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'sortIndex': sortIndex,
        'createdAtMs': createdAtMs,
      };

  factory SubscriptionGroup.fromJson(Map<String, Object?> json) =>
      SubscriptionGroup(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        sortIndex: (json['sortIndex'] as num?)?.toInt() ?? 0,
        createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      );

  /// Trims and rejects an empty name.
  ///
  /// Returns null rather than throwing so a dialog can keep the field open; an
  /// unnamed group would render as a blank chip that filters to something the
  /// user cannot identify.
  static String? normalizeName(String raw) {
    final name = raw.trim();
    return name.isEmpty ? null : name;
  }
}