import 'package:halo/src/state/speed_batch_tracker.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

SpeedBatchTracker _tracker() {
  return SpeedBatchTracker(
    command: (_, _, _) async => const {},
    loadNodes: () => const [],
    storedConcurrency: () => 8,
  );
}

HaloEventMessage _task(
  String name,
  String taskId, {
  Map<String, Object?>? result,
}) {
  return HaloEventMessage(
    name: name,
    data: {
      'taskId': taskId,
      'result': ?result,
    },
  );
}

void main() {
  test('task.started claims the id and later events are attributed to it', () {
    final tracker = _tracker();
    addTearDown(tracker.dispose);

    tracker.onTaskEvent(_task(HaloEvent.taskStarted, 't1'));
    expect(tracker.taskId, 't1');
  });

  test('a straggler from another batch is dropped', () {
    final tracker = _tracker();
    addTearDown(tracker.dispose);

    tracker.onTaskEvent(_task(HaloEvent.taskStarted, 't1'));
    final handled = tracker.onTaskEvent(_task(
      HaloEvent.taskProgress,
      't2',
      result: {'nodeId': 'n2', 'metric': 'proxy_latency', 'latencyMs': 5},
    ));

    expect(handled, isFalse);
    expect(tracker.results, isEmpty);
    expect(tracker.taskId, 't1');
  });

  test('results are routed by metric, not by guess', () {
    final tracker = _tracker();
    addTearDown(tracker.dispose);

    tracker.onTaskEvent(_task(HaloEvent.taskStarted, 't1'));
    tracker.onTaskEvent(_task(
      HaloEvent.taskProgress,
      't1',
      result: {'nodeId': 'n1', 'metric': 'proxy_latency', 'latencyMs': 12},
    ));
    tracker.onTaskEvent(_task(
      HaloEvent.taskProgress,
      't1',
      result: {'nodeId': 'n1', 'metric': 'download', 'downloadBps': 1000},
    ));
    tracker.onTaskEvent(_task(
      HaloEvent.taskProgress,
      't1',
      result: {'nodeId': 'n1', 'metric': 'tcp', 'latencyMs': 3},
    ));

    expect(tracker.results['n1']?.valueMs, 12);
    expect(tracker.downloadResults['n1']?.bytesPerSecond, 1000);
    expect(tracker.reachability['n1']?[SpeedMetric.tcp]?.valueMs, 3);
  });

  test('task.finished releases the id and asks for a coarse repaint', () {
    final tracker = _tracker();
    addTearDown(tracker.dispose);

    tracker.onTaskEvent(_task(HaloEvent.taskStarted, 't1'));
    expect(tracker.onTaskEvent(_task(HaloEvent.taskFinished, 't2')), isFalse,
        reason: 'another batch finishing must not clear this one');
    expect(tracker.taskId, 't1');

    expect(tracker.onTaskEvent(_task(HaloEvent.taskFinished, 't1')), isTrue);
    expect(tracker.taskId, isNull);
    expect(tracker.running, isFalse);
    expect(tracker.batchTotal, 0);
  });
}
