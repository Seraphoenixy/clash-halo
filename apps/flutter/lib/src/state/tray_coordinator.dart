import 'dart:convert';
import 'dart:io';

import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// Projects the local catalogue to the host tray and applies tray requests.
///
/// The host owns the tray, the Dart process owns the database, so this is the
/// one place that translates between them. It is deliberately best-effort: a
/// tray missing one node is a small inconvenience, and turning that into a
/// modal error on every catalog change would be worse.
class TrayCoordinator {
  TrayCoordinator({
    required this.dataDir,
    required this.connected,
    required this.storeReady,
    required this.loadProfiles,
    required this.loadNodes,
    required this.activeNodeId,
    required this.activeProfileId,
    required this.nodeExists,
    required this.command,
    required this.selectNode,
    required this.selectProfile,
    required this.setMode,
    required this.refreshSnapshot,
    required this.onError,
  });

  final String dataDir;
  final bool Function() connected;
  final bool Function() storeReady;
  final List<SubscriptionProfile> Function() loadProfiles;
  final List<ProxyNode> Function() loadNodes;
  final String? Function() activeNodeId;
  final String? Function() activeProfileId;
  final bool Function(String nodeId) nodeExists;
  final Future<void> Function(String action, Map<String, Object?> params) command;
  final Future<void> Function(String nodeId) selectNode;
  final Future<void> Function(String profileId) selectProfile;
  final Future<void> Function(ProxyMode mode) setMode;
  final Future<void> Function() refreshSnapshot;
  final void Function(String message) onError;

  /// Sends the compact node/profile catalogue to the host.
  Future<void> publishCatalog() async {
    if (!connected() || !storeReady()) return;
    final profiles = {for (final p in loadProfiles()) p.id: p.name};
    final nodes = loadNodes();
    try {
      await command(HaloAction.trayPublish, {
        'nodes': [
          for (final n in nodes.take(60))
            {
              'id': n.id,
              'name': n.name,
              'group': n.profileId == null ? '' : (profiles[n.profileId] ?? ''),
            },
        ],
        'activeNodeId': activeNodeId() ?? '',
        // The tray's 订阅 submenu mirrors Verge's: one ticked radio per
        // profile. The host cannot infer a subscription from a node, so the
        // list is published explicitly.
        'profiles': [
          for (final p in loadProfiles())
            if (p.enabled) {'id': p.id, 'name': p.name},
        ],
        'activeProfileId': activeProfileId() ?? '',
      });
    } catch (_) {
      // See the class comment: the tray is a shortcut, not a dependency.
    }
  }

  /// Applies an action requested by the tray menu.
  ///
  /// The host cannot build a config (the generator lives in Dart), so the tray
  /// records the request and hands it here. The request is delivered two ways —
  /// an event for a running UI, and `tray-request.json` for a UI that is being
  /// started by the same click — and this method is the single place that
  /// applies it, so the two paths cannot diverge.
  Future<void> applyRequest(Map<String, Object?> payload) async {
    final action = payload['action'];
    try {
      if (!storeReady()) return;
      switch (action) {
        case 'selectNode':
          final nodeId = payload['nodeId'];
          if (nodeId is! String || nodeId.isEmpty) return;
          if (!nodeExists(nodeId)) return;
          await selectNode(nodeId);
        case 'selectProfile':
          final profileId = payload['profileId'];
          if (profileId is! String || profileId.isEmpty) return;
          await selectProfile(profileId);
        case 'setMode':
          final wire = payload['mode'];
          if (wire is! String) return;
          final mode = ProxyMode.values.firstWhere(
            (m) => m.wire == wire,
            orElse: () => ProxyMode.rule,
          );
          await setMode(mode);
        default:
          return;
      }
      await refreshSnapshot();
    } catch (e) {
      onError('托盘操作失败：$e');
    }
  }

  /// Reads a pending tray request written while no UI was running.
  ///
  /// Stale requests are ignored: the file survives a crash or a manual delete,
  /// and silently switching the user's node on the next unrelated launch would
  /// be a surprising side effect.
  Future<void> consumePendingRequest() async {
    final file = File('$dataDir${Platform.pathSeparator}tray-request.json');
    try {
      if (!await file.exists()) return;
      final text = await file.readAsString();
      await file.delete();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final requestedAt = decoded['requestedAtMs'];
      final ageMs = requestedAt is int
          ? DateTime.now().millisecondsSinceEpoch - requestedAt
          : -1;
      if (ageMs < 0 || ageMs > const Duration(minutes: 2).inMilliseconds) {
        return;
      }
      await applyRequest(decoded.cast<String, Object?>());
    } catch (_) {
      // A malformed or unreadable request is not worth reporting: the tray
      // falls back to opening the window, which is where the user can choose.
    }
  }
}
