/// Batch operations over node selections.
///
/// Every operation is expressed as a pure function over nodes so the UI can
/// preview the exact affected set (and its undo data) before writing.
library;

import 'fingerprint.dart';
import 'models/node.dart';

/// Outcome of a batch operation, including the undo payload needed to revert
/// destructive changes without a full backup.
class BatchOutcome {
  const BatchOutcome({
    required this.nodes,
    this.affected = 0,
    this.changed = 0,
    this.removedIds = const [],
    this.removedNodes = const [],
    this.renamed = const {},
    this.issues = const [],
  });

  final List<ProxyNode> nodes;

  /// How many nodes the selection matched.
  final int affected;

  /// How many nodes actually differ after the operation.
  final int changed;

  /// Ids deleted by [BatchOps.deleteNodes], for the undo log.
  final List<String> removedIds;
  final List<ProxyNode> removedNodes;

  /// old id -> old name pairs, for renaming undo.
  final Map<String, String> renamed;
  final List<String> issues;

  bool get isEmpty => changed == 0;

  /// Human summary shown in the confirmation dialog before applying.
  String get previewText {
    if (affected == 0) return '没有匹配的节点';
    if (changed == affected) return '将影响 $affected 个节点';
    return '将影响 $affected 个节点，其中 $changed 个发生变化';
  }
}

/// Selection predicate helpers used by the UI and by tests.
typedef NodeFilter = bool Function(ProxyNode node);

abstract final class BatchOps {
  /// Renames selected nodes; names are not part of the connection identity,
  /// so ids and fingerprints stay stable.
  static BatchOutcome rename(
    List<ProxyNode> nodes,
    NodeFilter selected,
    String Function(ProxyNode node, int index) newName,
  ) {
    final out = <ProxyNode>[];
    final renamed = <String, String>{};
    var affected = 0;
    var changed = 0;
    var index = 0;
    for (final node in nodes) {
      if (!selected(node)) {
        out.add(node);
        continue;
      }
      affected++;
      index++;
      final name = newName(node, index).trim();
      if (name.isEmpty || name == node.name) {
        out.add(node);
        continue;
      }
      changed++;
      renamed[node.id] = node.name;
      out.add(node.copyWith(name: name));
    }
    return BatchOutcome(
        nodes: out, affected: affected, changed: changed, renamed: renamed);
  }

  /// Applies a shared endpoint rewrite (the common "change connection
  /// parameters" case). Identity changes, so ids are recomputed and a node
  /// that collides with an existing fingerprint is reported instead of
  /// silently merged.
  static BatchOutcome editEndpoint(
    List<ProxyNode> nodes,
    NodeFilter selected,
    ({String? server, int? port}) Function(ProxyNode node) edit,
  ) {
    final out = <ProxyNode>[];
    final issues = <String>[];
    final knownFingerprints = <String>{
      for (final n in nodes) n.fingerprint,
    };
    final removedFingerprints = <String>{};
    var affected = 0;
    var changed = 0;
    for (final node in nodes) {
      if (!selected(node)) {
        out.add(node);
        continue;
      }
      affected++;
      final patch = edit(node);
      final next = node.copyWith(
        server: patch.server ?? node.server,
        port: patch.port ?? node.port,
      );
      if (next.server == node.server && next.port == node.port) {
        out.add(node);
        continue;
      }
      final reidentified = withIdentity(next);
      final collides = knownFingerprints.contains(reidentified.fingerprint);
      if (collides) {
        issues.add('${node.name}: 修改后与已有节点重复，已跳过');
        out.add(node);
        continue;
      }
      changed++;
      removedFingerprints.add(node.fingerprint);
      out.add(reidentified);
    }
    return BatchOutcome(
        nodes: out, affected: affected, changed: changed, issues: issues);
  }

  /// Deletes selected nodes, returning the removed nodes for undo.
  static BatchOutcome deleteNodes(List<ProxyNode> nodes, NodeFilter selected) {
    final removed = <ProxyNode>[];
    final out = <ProxyNode>[];
    for (final node in nodes) {
      if (selected(node)) {
        removed.add(node);
      } else {
        out.add(node);
      }
    }
    return BatchOutcome(
      nodes: out,
      affected: removed.length,
      changed: removed.length,
      removedIds: removed.map((n) => n.id).toList(),
      removedNodes: removed,
    );
  }

  /// Deduplicates by fingerprint, keeping the first occurrence (oldest
  /// import order) and reporting how many were dropped.
  static BatchOutcome dedupe(List<ProxyNode> nodes) {
    final seen = <String>{};
    final out = <ProxyNode>[];
    final removed = <ProxyNode>[];
    for (final node in nodes) {
      final key = node.fingerprint.isEmpty ? canonicalIdentity(node) : node.fingerprint;
      if (seen.add(key)) {
        out.add(node);
      } else {
        removed.add(node);
      }
    }
    return BatchOutcome(
      nodes: out,
      affected: nodes.length,
      changed: removed.length,
      removedIds: removed.map((n) => n.id).toList(),
      removedNodes: removed,
    );
  }

  /// Re-applies a previous [deleteNodes]/[dedupe] outcome.
  static List<ProxyNode> restore(List<ProxyNode> nodes, BatchOutcome removal) {
    final existing = nodes.map((n) => n.id).toSet();
    final merged = [
      ...nodes,
      ...removal.removedNodes.where((n) => !existing.contains(n.id)),
    ];
    merged.sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return merged;
  }

  /// Applies a stored rename map in reverse.
  static List<ProxyNode> undoRename(List<ProxyNode> nodes, Map<String, String> renamed) {
    if (renamed.isEmpty) return nodes;
    return [
      for (final node in nodes)
        renamed.containsKey(node.id) ? node.copyWith(name: renamed[node.id]) : node,
    ];
  }

  /// Persists a new explicit ordering; ids are untouched.
  static List<ProxyNode> reorder(List<ProxyNode> nodes, List<String> orderedIds) {
    final rank = <String, int>{};
    for (var i = 0; i < orderedIds.length; i++) {
      rank[orderedIds[i]] = i;
    }
    final copy = [...nodes];
    copy.sort((a, b) {
      final ra = rank[a.id] ?? orderedIds.length;
      final rb = rank[b.id] ?? orderedIds.length;
      if (ra != rb) return ra.compareTo(rb);
      return a.sortIndex.compareTo(b.sortIndex);
    });
    for (var i = 0; i < copy.length; i++) {
      copy[i] = copy[i].copyWith(sortIndex: i);
    }
    return copy;
  }

  /// Applies explicit sort indices after a drag-drop.
  static List<ProxyNode> reindex(List<ProxyNode> nodes) {
    final copy = [...nodes];
    for (var i = 0; i < copy.length; i++) {
      copy[i] = copy[i].copyWith(sortIndex: i);
    }
    return copy;
  }

  /// Groups nodes by protocol for the filter chips.
  static Map<ProxyProtocol, int> countByProtocol(List<ProxyNode> nodes) {
    final counts = <ProxyProtocol, int>{};
    for (final node in nodes) {
      counts[node.protocol] = (counts[node.protocol] ?? 0) + 1;
    }
    return counts;
  }

  /// Groups nodes by subscription profile id, with `null` meaning local.
  static Map<String?, int> countByProfile(List<ProxyNode> nodes) {
    final counts = <String?, int>{};
    for (final node in nodes) {
      final key = node.isFromSubscription ? node.profileId : null;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }
}
