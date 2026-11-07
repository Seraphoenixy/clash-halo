import 'package:halo/src/state/app_controller.dart';
import 'package:test/test.dart';

/// Pins the wire shape of `event.subscribe`.
///
/// Regression: the UI sent `{'events': true}`, the Go host decoded
/// `{enabled bool}` and silently ignored the unknown key, so every client was
/// subscribed *off*. No `task.progress`/`task.finished` ever arrived and the
/// latency column spun on "测试中" with no way out. The names must agree, and
/// a mismatch has to fail here rather than in a user's window.
void main() {
  test('event.subscribe sends the field the host actually reads', () {
    expect(AppController.eventSubscribeParams, {'enabled': true});
    expect(
      AppController.eventSubscribeParams.keys,
      isNot(contains('events')),
      reason: '宿主只解 enabled；events 会被忽略并让客户端静默退订',
    );
  });

  test('subscribing is on, never a defaulted false', () {
    // A missing field is rejected by the host now, but defaulting to false would
    // reintroduce the same silent blackout.
    expect(AppController.eventSubscribeParams['enabled'], isTrue);
  });
}
