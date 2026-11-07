import 'dart:convert';
import 'dart:io';

import 'package:halo/src/state/tray_coordinator.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('halo_tray_test');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  TrayCoordinator build({
    bool storeReady = true,
    Future<void> Function(String action, Map<String, Object?> params)? command,
    Future<void> Function(String id)? onSelectNode,
    Future<void> Function(ProxyMode mode)? onSetMode,
    void Function(String message)? onError,
  }) {
    return TrayCoordinator(
      dataDir: dir.path,
      connected: () => true,
      storeReady: () => storeReady,
      loadProfiles: () => const <SubscriptionProfile>[],
      loadNodes: () => const <ProxyNode>[],
      activeNodeId: () => 'n_active',
      activeProfileId: () => 'p1',
      nodeExists: (id) => id == 'n_active',
      command: command ?? (_, _) async {},
      selectNode: onSelectNode ?? (_) async {},
      selectProfile: (_) async {},
      setMode: onSetMode ?? (_) async {},
      refreshSnapshot: () async {},
      onError: onError ?? (_) {},
    );
  }

  test('publish sends active ids and the enabled-profile list', () async {
    String? action;
    Map<String, Object?>? params;
    final tray = build(
      command: (a, p) async {
        action = a;
        params = p;
      },
    );

    await tray.publishCatalog();

    expect(action, HaloAction.trayPublish);
    expect(params!['activeNodeId'], 'n_active');
    expect(params!['activeProfileId'], 'p1');
    expect(params!['nodes'], isEmpty);
  });

  test('a tray action is applied only for an existing node', () async {
    var selected = <String>[];
    var refreshed = 0;
    final tray = TrayCoordinator(
      dataDir: dir.path,
      connected: () => true,
      storeReady: () => true,
      loadProfiles: () => const <SubscriptionProfile>[],
      loadNodes: () => const <ProxyNode>[],
      activeNodeId: () => null,
      activeProfileId: () => null,
      nodeExists: (id) => id == 'known',
      command: (_, _) async {},
      selectNode: (id) async => selected.add(id),
      selectProfile: (_) async {},
      setMode: (_) async {},
      refreshSnapshot: () async => refreshed++,
      onError: (_) {},
    );

    await tray.applyRequest({'action': 'selectNode', 'nodeId': 'unknown'});
    expect(selected, isEmpty);
    expect(refreshed, 0);

    await tray.applyRequest({'action': 'selectNode', 'nodeId': 'known'});
    expect(selected, ['known']);
    expect(refreshed, 1);
  });

  test('setMode maps the wire value', () async {
    ProxyMode? mode;
    final tray = build(onSetMode: (m) async => mode = m);
    await tray.applyRequest({'action': 'setMode', 'mode': 'global'});
    expect(mode, ProxyMode.global);
  });

  test('a pending request file is consumed once, stale files are ignored',
      () async {
    var selected = <String>[];
    final tray = TrayCoordinator(
      dataDir: dir.path,
      connected: () => true,
      storeReady: () => true,
      loadProfiles: () => const <SubscriptionProfile>[],
      loadNodes: () => const <ProxyNode>[],
      activeNodeId: () => null,
      activeProfileId: () => null,
      nodeExists: (id) => id == 'known',
      command: (_, _) async {},
      selectNode: (id) async => selected.add(id),
      selectProfile: (_) async {},
      setMode: (_) async {},
      refreshSnapshot: () async {},
      onError: (_) {},
    );
    final file = File('${dir.path}${Platform.pathSeparator}tray-request.json');

    await file.writeAsString(jsonEncode({
      'action': 'selectNode',
      'nodeId': 'known',
      'requestedAtMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await tray.consumePendingRequest();
    expect(selected, ['known']);
    expect(file.existsSync(), isFalse, reason: 'the request is one-shot');

    await file.writeAsString(jsonEncode({
      'action': 'selectNode',
      'nodeId': 'known',
      'requestedAtMs': DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch,
    }));
    await tray.consumePendingRequest();
    expect(selected, ['known'], reason: 'a stale request must not switch nodes');
  });

  test('a failing action is reported, not thrown', () async {
    String? message;
    final tray = TrayCoordinator(
      dataDir: dir.path,
      connected: () => true,
      storeReady: () => true,
      loadProfiles: () => const <SubscriptionProfile>[],
      loadNodes: () => const <ProxyNode>[],
      activeNodeId: () => null,
      activeProfileId: () => null,
      nodeExists: (id) => true,
      command: (_, _) async {},
      selectNode: (_) async => throw StateError('boom'),
      selectProfile: (_) async {},
      setMode: (_) async {},
      refreshSnapshot: () async {},
      onError: (m) => message = m,
    );

    await tray.applyRequest({'action': 'selectNode', 'nodeId': 'n1'});
    expect(message, contains('托盘操作失败'));
  });
}
