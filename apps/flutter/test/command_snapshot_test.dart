import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'dart:io';

/// Records which wire calls the controller makes, and lets a test decide what
/// stateVersion each response carries.
class _RecordingClient extends HaloClient {
  _RecordingClient() : super(pipeName: 'never-connected');

  final List<String> calls = <String>[];

  /// What a mutating command's response reports as the host's version.
  /// Null means "unchanged" (the event stream already delivered the update).
  int? nextCommandStateVersion;

  @override
  bool get isConnected => true;

  @override
  Future<HaloResponse> send(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add('send:$action');
    return HaloResponse.success(
      'fake',
      result: const {},
      stateVersion: nextCommandStateVersion ?? 1,
    );
  }

  @override
  Future<HaloResponse> sendRead(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add('sendRead:$action');
    if (action == HaloAction.snapshotGet) {
      // A real host returns the full snapshot; the version travels with it.
      return HaloResponse.success('fake', result: {
        'stateVersion': nextCommandStateVersion ?? 1,
      }, stateVersion: nextCommandStateVersion ?? 1);
    }
    return HaloResponse.success('fake', result: const {}, stateVersion: 1);
  }
}

void main() {
  late Directory tempDir;
  late _RecordingClient client;
  late AppController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('halo_command_gate');
    client = _RecordingClient();
    controller = AppController(client: client, dataDir: tempDir.path);
    await controller.start(connectHost: false);
    // The event stream has delivered version 1 already.
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
      connected: true,
    );
    client.calls.clear();
  });

  tearDown(() async {
    await controller.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // WAL can hold the directory on Windows; the temp tree is disposable.
    }
  });

  test('a command whose version the events already delivered pulls no snapshot',
      () async {
    client.nextCommandStateVersion = null; // response version == delivered (1)
    await controller.setCoreResume(false);

    expect(client.calls, contains('send:coreResume.set'));
    expect(
      client.calls,
      isNot(contains('sendRead:snapshot.get')),
      reason: 'the state.changed event arrives before the response on a real '
          'host, so re-fetching after every command was a wasted round trip',
    );
  });

  test('a command whose version is ahead of what we have still pulls one',
      () async {
    client.nextCommandStateVersion = 2; // host is ahead of the event stream
    await controller.setCoreResume(false);

    expect(
      client.calls,
      contains('sendRead:snapshot.get'),
      reason: 'an unserved event stream (failed subscription, dropped frame) '
          'must still converge on the new state',
    );
    expect(controller.snapshot?.stateVersion, 2);
  });

  group('auto core start on UI launch', () {
    /// Installs a snapshot the way a fresh connect would see it.
    void seeSnapshot(
      CoreState core, {
      bool configApplied = true,
      TunState tun = TunState.disabled,
    }) {
      controller.applySnapshotForTest(
        RuntimeSnapshot(
          stateVersion: 1,
          coreState: core,
          configVersion: configApplied ? 3 : 0,
          configHash: configApplied ? 'abc' : null,
          tunState: tun,
        ),
        connected: true,
      );
      client.calls.clear();
    }

    test('a stopped core with an applied config is started', () async {
      seeSnapshot(CoreState.stopped);
      await controller.ensureCoreRunningForLaunch();

      expect(client.calls, contains('send:core.start'),
          reason: '启动 clash-halo.exe 本身就是"要代理在工作"的请求');
      expect(controller.lastActionError, isNull);
    });

    test('a running core is left alone', () async {
      seeSnapshot(CoreState.running);
      await controller.ensureCoreRunningForLaunch();
      expect(client.calls, isNot(contains('send:core.start')));
    });

    test('a core mid-start is left alone', () async {
      seeSnapshot(CoreState.starting);
      await controller.ensureCoreRunningForLaunch();
      expect(client.calls, isNot(contains('send:core.start')));
    });

    test('a fresh install with nothing applied starts nothing', () async {
      seeSnapshot(CoreState.stopped, configApplied: false);
      await controller.ensureCoreRunningForLaunch();
      expect(client.calls, isNot(contains('send:core.start')),
          reason: '没有可启动的配置，报「没有可用的配置」只会是噪音');
    });

    test('a TUN session owns the core and is not fought', () async {
      seeSnapshot(CoreState.stopped, tun: TunState.enabled);
      await controller.ensureCoreRunningForLaunch();
      expect(client.calls, isNot(contains('send:core.start')));
    });

    test('runs once per UI process, not on every reconnect', () async {
      seeSnapshot(CoreState.stopped);
      await controller.ensureCoreRunningForLaunch();
      expect(client.calls.where((c) => c == 'send:core.start'), hasLength(1));

      // A later reconnect (the same controller, a fresh snapshot that still
      // says stopped) must not re-run it: the user may have stopped the core
      // on purpose in between.
      client.calls.clear();
      seeSnapshot(CoreState.stopped);
      await controller.ensureCoreRunningForLaunch();
      expect(client.calls, isNot(contains('send:core.start')));
    });
  });
}
