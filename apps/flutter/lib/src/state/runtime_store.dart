import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:halo_contracts/halo_contracts.dart';

/// Owns the host snapshot and its two narrow notification channels.
///
/// The snapshot is written only by [adopt]; the controller decides when to
/// repaint by consulting the return value instead of comparing snapshots in
/// every consumer. A proxy-only change publishes [proxyRevision] and returns
/// false, which is what keeps the whole page (and a 10k-row table) from
/// rebuilding when one boolean moved.
class RuntimeStore {
  /// Core, system proxy, TUN, active node and versions changed.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Only the Windows-proxy switch changed.
  final ValueNotifier<int> proxyRevision = ValueNotifier<int>(0);

  RuntimeSnapshot? _snapshot;

  RuntimeSnapshot? get snapshot => _snapshot;

  /// Takes a new snapshot and reports whether the coarse channel is needed.
  ///
  /// Returns true for every change except a proxy-only update, including the
  /// first snapshot.
  bool adopt(RuntimeSnapshot next) {
    final previous = _snapshot;
    _snapshot = next;
    if (previous == null) return true;
    if (proxyOnlyChange(previous, next)) {
      proxyRevision.value++;
      return false;
    }
    return true;
  }

  void dispose() {
    revision.dispose();
    proxyRevision.dispose();
  }
}

/// True when the two snapshots differ only in the Windows-proxy block.
///
/// Compares whole serialised maps with `systemProxy` removed rather than a
/// hand-written field list. The list version was wrong in both directions:
/// `SystemProxyState` has no value equality, so "proxy changed" was always
/// true, and fields the list did not name — the speed-test flag, the
/// subscription runner, auto-launch — were swallowed by the narrow path and
/// silently froze the node page mid-batch.
bool proxyOnlyChange(RuntimeSnapshot a, RuntimeSnapshot b) {
  if (jsonEncode(a.systemProxy.toJson()) ==
      jsonEncode(b.systemProxy.toJson())) {
    return false;
  }
  // `stateVersion` and `updatedAtMs` are bookkeeping: the host bumps both on
  // every mutation, so comparing them made this always false and the narrow
  // channel never fired. The timestamp catches up on the next coarse change,
  // which is a page that repaints for a reason anyway.
  final left = Map<String, Object?>.of(a.toJson())
    ..remove('systemProxy')
    ..remove('stateVersion')
    ..remove('updatedAtMs');
  final right = Map<String, Object?>.of(b.toJson())
    ..remove('systemProxy')
    ..remove('stateVersion')
    ..remove('updatedAtMs');
  return jsonEncode(left) == jsonEncode(right);
}
