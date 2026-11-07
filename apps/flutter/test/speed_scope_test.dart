import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// A host that accepts every speed-test batch and reports nothing.
class _AcceptingClient extends HaloClient {
  _AcceptingClient() : super(pipeName: 'never-connected');

  final List<Map<String, Object?>> started = [];

  @override
  bool get isConnected => true;

  @override
  Future<HaloResponse> send(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (action == HaloAction.speedTestStart) {
      started.add(Map<String, Object?>.of(params));
      return HaloResponse.success(
        'fake',
        result: {'taskId': '${params['taskId']}'},
      );
    }
    return HaloResponse.success('fake', result: const {});
  }

  @override
  Future<HaloResponse> sendRead(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) => send(action, params: params, timeout: timeout);
}

/// Which readings a new batch is allowed to erase.
///
/// Regression: `startSpeedTest` cleared the whole latency map regardless of
/// which nodes the run covered. The node page clears only the ids it re-tests
/// (so "test the selection" keeps the other rows readable), and that intent was
/// silently undone one layer down: measuring three nodes threw away the
/// numbers for every other node on screen.
void main() {
  late Directory tempDir;
  late AppController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('halo_speed_scope');
    controller = AppController(
      client: _AcceptingClient(),
      dataDir: tempDir.path,
    );
    await controller.start(connectHost: false);
  });

  tearDown(() async {
    await controller.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Stores a latency reading the way the host would: start, then progress.
  void feedLatency(String taskId, Map<String, int> byNodeId) {
    controller.applyEventForTest(
      HaloEventMessage(
        name: HaloEvent.taskStarted,
        data: {'taskId': taskId, 'count': byNodeId.length},
      ),
    );
    controller.applyEventForTest(
      HaloEventMessage(
        name: HaloEvent.taskProgress,
        data: {
          'taskId': taskId,
          'results': [
            for (final entry in byNodeId.entries)
              {
                'nodeId': entry.key,
                'metric': SpeedMetric.proxyLatency.wire,
                'ok': true,
                'latencyMs': entry.value,
              },
          ],
        },
      ),
    );
  }

  test('a scoped batch keeps the readings of the nodes it did not touch', () async {
    controller.saveImport(
      importNodes(
        'trojan://pw@a.example.com:443#甲\n'
        'trojan://pw@b.example.com:443#乙\n'
        'trojan://pw@c.example.com:443#丙',
      ),
    );
    final ids = controller.loadNodes().map((n) => n.id).toList();
    expect(ids, hasLength(3));

    feedLatency('first', {for (final id in ids) id: 120});
    expect(controller.speedResults, hasLength(3));

    await controller.startSpeedTest(nodeIds: [ids.first]);

    expect(controller.speedResults.containsKey(ids.first), isFalse);
    expect(
      controller.speedResults.keys,
      containsAll([ids[1], ids[2]]),
      reason: '只测一个节点时，其它节点的延迟读数必须保留',
    );
  });

  test('a whole-list batch still clears the list', () async {
    // The complement of the scoped case: an empty nodeIds means "everything",
    // and the old numbers would then be indistinguishable from the new ones.
    controller.saveImport(
      importNodes(
        'trojan://pw@a.example.com:443#甲\n'
        'trojan://pw@b.example.com:443#乙',
      ),
    );
    final ids = controller.loadNodes().map((n) => n.id).toList();
    feedLatency('first', {for (final id in ids) id: 120});
    expect(controller.speedResults, hasLength(2));

    await controller.startSpeedTest();
    expect(controller.speedResults, isEmpty);
  });

  test('reachability is scoped per transport too', () async {
    controller.saveImport(
      importNodes(
        'trojan://pw@a.example.com:443#甲\n'
        'trojan://pw@b.example.com:443#乙',
      ),
    );
    final ids = controller.loadNodes().map((n) => n.id).toList();
    feedLatency('tcp-first', {for (final id in ids) id: 30});
    controller.applyEventForTest(
      HaloEventMessage(
        name: HaloEvent.taskStarted,
        data: const {'taskId': 'tcp-first'},
      ),
    );
    // Re-file the same readings as TCP reachability, which is a separate map.
    for (final id in ids) {
      controller.applyEventForTest(
        HaloEventMessage(
          name: HaloEvent.taskProgress,
          data: {
            'taskId': 'tcp-first',
            'nodeId': id,
            'metric': SpeedMetric.tcp.wire,
            'ok': true,
            'latencyMs': 30,
          },
        ),
      );
    }
    expect(controller.reachability.keys, containsAll(ids));

    await controller.startSpeedTest(
      nodeIds: [ids.first],
      metric: SpeedMetric.tcp,
    );

    expect(controller.reachability[ids.first]?.containsKey(SpeedMetric.tcp), isFalse);
    expect(
      controller.reachability[ids[1]]?[SpeedMetric.tcp],
      isNotNull,
      reason: '只重测一个节点的 TCP 时，另一个节点的连通结果必须保留',
    );
  });
}
