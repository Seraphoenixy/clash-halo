import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo_contracts/halo_contracts.dart';

/// Channel dispatch: which consumers a snapshot change is allowed to wake.
///
/// Enabling the Windows proxy used to publish the coarse runtime channel, and
/// every consumer of it rebuilt — the sidebar, the status bar and the whole
/// current page, node table included. One boolean moved.
class _StubClient extends HaloClient {
  _StubClient() : super(pipeName: 'never-connected');

  bool proxyOn = true;
  int proxySetCalls = 0;

  /// Every field the snapshot renders, so a test can change exactly one.
  Map<String, Object?> snapshotJson() => {
    'stateVersion': 22,
    'coreState': 'running',
    'corePid': 4242,
    'tunState': 'disabled',
    'tunSupported': true,
    'mode': 'rule',
    'systemProxy': {
      'supported': true,
      'enabled': proxyOn,
      'endpoint': '127.0.0.1:7890',
    },
  };

  @override
  bool get isConnected => true;

  @override
  Future<HaloResponse> send(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (action == HaloAction.systemProxySet) {
      proxySetCalls++;
      return HaloResponse.success('fake', result: const {}, stateVersion: 22);
    }
    if (action == HaloAction.snapshotGet) {
      return HaloResponse.success(
        'fake',
        result: snapshotJson(),
        stateVersion: 22,
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

void main() {
  late Directory dir;
  late _StubClient client;
  late AppController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('halo-channel');
    client = _StubClient();
    controller = AppController(client: client, dataDir: dir.path);
    await controller.start(connectHost: false);
    controller.applySnapshotForTest(
      const RuntimeSnapshot(
        stateVersion: 21,
        coreState: CoreState.running,
        corePid: 4242,
        tunState: TunState.disabled,
        tunSupported: true,
        mode: ProxyMode.rule,
        systemProxy: SystemProxyState(
          supported: true,
          enabled: false,
          endpoint: '127.0.0.1:7890',
        ),
      ),
      connected: true,
    );
  });

  tearDown(() async {
    await controller.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('enabling the system proxy wakes only the proxy channel', () async {
    var runtime = 0;
    var proxy = 0;
    controller.runtimeRevision.addListener(() => runtime++);
    controller.proxyRevision.addListener(() => proxy++);

    await controller.setSystemProxy(true);

    expect(proxy, 1, reason: 'the switch itself changed');
    expect(
      runtime,
      0,
      reason: 'the coarse channel rebuilds the page, the sidebar and the '
          'status bar; one boolean does not justify that',
    );
  });

  test('a change to anything else still wakes the coarse channel', () async {
    // Same JSON shape, one rendered field different: the core pid. This is the
    // guard against the narrow path swallowing real changes.
    final json = client.snapshotJson()..['corePid'] = 5555;
    final next = RuntimeSnapshot.fromJson(json);
    var runtime = 0;
    var proxy = 0;
    controller.runtimeRevision.addListener(() => runtime++);
    controller.proxyRevision.addListener(() => proxy++);

    expect(controller.adoptSnapshot(next), isTrue);
    controller.runtimeChanged();

    expect(runtime, 1);
    expect(proxy, 0, reason: 'the proxy did not move');
  });

  test('a speed-test flag change is never treated as proxy-only', () async {
    final json = client.snapshotJson()..['speedTestRunning'] = true;
    expect(controller.adoptSnapshot(RuntimeSnapshot.fromJson(json)), isTrue);
  });

  test('a TUN change is never treated as proxy-only', () async {
    final json = client.snapshotJson()..['tunState'] = 'enabled';
    expect(controller.adoptSnapshot(RuntimeSnapshot.fromJson(json)), isTrue);
  });

  test('an auto-launch change is never treated as proxy-only', () async {
    final json = client.snapshotJson()..['autoLaunch'] = true;
    expect(controller.adoptSnapshot(RuntimeSnapshot.fromJson(json)), isTrue);
  });

  test('a proxy-only change reports the narrow channel', () async {
    // The setUp snapshot has the proxy off; turning it on is the only change.
    final json = client.snapshotJson()..['systemProxy'] = {
      'supported': true,
      'enabled': true,
      'endpoint': '127.0.0.1:7890',
      'restorable': false,
      'appliedValue': '',
      'appliedProxyEnable': 0,
      'previousValue': '',
      'previousEnable': 0,
    };
    expect(controller.adoptSnapshot(RuntimeSnapshot.fromJson(json)), isFalse);
  });

  test('the first snapshot always wakes the coarse channel', () async {
    final fresh = AppController(client: _StubClient(), dataDir: dir.path);
    addTearDown(fresh.dispose);
    expect(fresh.adoptSnapshot(RuntimeSnapshot.fromJson(client.snapshotJson())),
        isTrue);
  });

  test('dispose releases the proxy-only notifier', () async {
    // proxyRevision is the one channel dispose() used to forget. A
    // ChangeNotifier that is never disposed keeps its listeners and trips
    // debug assertions if anything touches it after the controller is gone.
    final fresh = AppController(client: _StubClient(), dataDir: dir.path);
    await fresh.start(connectHost: false);
    await fresh.dispose();

    expect(() => fresh.proxyRevision.addListener(() {}), throwsFlutterError);
    // Control: the coarse channel is released the same way.
    expect(() => fresh.runtimeRevision.addListener(() {}), throwsFlutterError);
  });
}
