import 'package:halo/src/state/runtime_store.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

RuntimeSnapshot _snapshot({
  bool proxyEnabled = false,
  String? nodeId,
  int version = 1,
}) {
  return RuntimeSnapshot(
    stateVersion: version,
    coreState: CoreState.running,
    activeNodeId: nodeId,
    systemProxy: SystemProxyState(supported: true, enabled: proxyEnabled),
  );
}

void main() {
  test('the first snapshot is a coarse change', () {
    final store = RuntimeStore();
    addTearDown(store.dispose);

    expect(store.adopt(_snapshot()), isTrue);
    expect(store.snapshot, isNotNull);
    expect(store.revision.value, 0,
        reason: 'the caller bumps the coarse channel; the store only decides');
  });

  test('a proxy-only change publishes the narrow channel and skips coarse', () {
    final store = RuntimeStore();
    addTearDown(store.dispose);

    store.adopt(_snapshot());
    final coarse = store.adopt(_snapshot(proxyEnabled: true));

    expect(coarse, isFalse);
    expect(store.proxyRevision.value, 1);
    expect(store.revision.value, 0);
  });

  test('any other field keeps the coarse channel', () {
    final store = RuntimeStore();
    addTearDown(store.dispose);

    store.adopt(_snapshot(nodeId: 'n_a'));
    final coarse = store.adopt(_snapshot(nodeId: 'n_b'));

    expect(coarse, isTrue);
    expect(store.proxyRevision.value, 0);
  });
}
