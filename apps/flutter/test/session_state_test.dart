import 'package:halo/src/state/session_state.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

void main() {
  test('session.get shape hydrates speed and traffic', () {
    final state = HaloSessionState.fromJson({
      'speed': {
        'running': true,
        'taskId': 'host-1',
        'metric': 'proxy_latency',
        'total': 2,
        'done': 1,
        'pending': ['n2'],
        'results': [
          {
            'nodeId': 'n1',
            'metric': 'proxy_latency',
            'ok': true,
            'latencyMs': 12,
          },
        ],
        'updatedAtMs': 123,
      },
      'traffic': {
        'upRate': 1.5,
        'downRate': 2.5,
        'uploadTotal': 10,
        'downloadTotal': 20,
        'peakUp': 3.0,
        'peakDown': 4.0,
        'history': [
          {'up': 1.0, 'down': 2.0},
        ],
        'activeConnections': 3,
        'updatedAtMs': 456,
      },
    });

    expect(state.speed.running, isTrue);
    expect(state.speed.taskId, 'host-1');
    expect(state.speed.metric, SpeedMetric.proxyLatency);
    expect(state.speed.pending, ['n2']);
    expect(state.speed.results.single['nodeId'], 'n1');
    expect(state.traffic.uploadTotal, 10);
    expect(state.traffic.history, [(1.0, 2.0)]);
    expect(state.traffic.activeConnections, 3);
    expect(state.traffic.error, isNull);
  });

  test('an empty host session is a valid, empty session', () {
    final state = HaloSessionState.fromJson(const {});
    expect(state.speed.running, isFalse);
    expect(state.speed.results, isEmpty);
    expect(state.traffic.history, isEmpty);
    expect(state.traffic.uploadTotal, 0);
  });
}
