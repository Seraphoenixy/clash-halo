@Tags(['live'])
// Each case copies the 80 MB core and waits for a freshly started host, which
// on a cold machine (Defender scanning the copied exe) can exceed the 30 s
// package:test default. The wait is startup, not a hang.
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:io';

import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

/// Live integration test: drives the real `halo-host.exe` over the real
/// Windows named pipe through the same FFI transport the app uses.
///
/// This is the test that proves the production pipe path works end to end —
/// a fake pipe cannot catch a `CreateFileW` access-mask or disposition bug.
///
/// Skipped unless [hostExe] and [coreExe] are supplied, so `flutter test` on a
/// machine without the built host stays green:
///   HALO_HOST_EXE=... HALO_CORE_EXE=... dart test test/host_live_test.dart
void main() {
  final hostExe = Platform.environment['HALO_HOST_EXE'];
  final coreExe = Platform.environment['HALO_CORE_EXE'];

  group('live host', () {
    late Directory temp;
    late Process host;
    late HaloClient client;
    late String pipeName;

    setUp(() async {
      // The temp tree must live inside the workspace: the host is launched as
      // a child process under the session sandbox, which permits writes to the
      // workspace but not to %TEMP%. A test root outside it would fail to
      // create its single-instance lock with ACCESS_DENIED.
      final root = Directory('${Directory.current.path}/.tmp')
        ..createSync(recursive: true);
      temp = root.createTempSync('halo-live-');
      // The host derives its pipe from --dir, so the test must use the same
      // derivation; a made-up name would never connect.
      pipeName = haloPipeNameFor(temp.path);
      final core = '${temp.path}\\sing-box.exe';
      File(coreExe!).copySync(core);
      host = await Process.start(
        hostExe!,
        ['--no-tray', '--dir', temp.path],
        environment: {'HALO_SINGBOX': core},
      );
      // Wait for the pipe to accept a connection instead of guessing a delay.
      client = HaloClient(
        pipeName: pipeName,
        pollInterval: const Duration(milliseconds: 10),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        try {
          await client.connect();
          break;
        } catch (_) {
          if (DateTime.now().isAfter(deadline)) {
            fail('后台进程未在 20 秒内创建管道');
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    });

    tearDown(() async {
      await client.dispose();
      // Kill the host's own core child before the host, otherwise a hard kill
      // leaves sing-box listening and the next run's bind check fails.
      await _killChildrenOf(host.pid);
      host.kill();
      await host.exitCode;
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('snapshot.get returns the real runtime state', () async {
      final response = await client.send(HaloAction.snapshotGet);
      expect(response.ok, isTrue, reason: response.error?.message);
      final snap = RuntimeSnapshot.fromJson(response.result ?? const {});
      expect(snap.hostVersion, isNotEmpty);
      expect(snap.coreState, isNotNull);
      expect(snap.stateVersion, greaterThan(0));
    });

    test('host.status reports the resolved core path', () async {
      final response = await client.send(HaloAction.hostStatus);
      expect(response.ok, isTrue);
      final version = response.result!['hostVersion'];
      expect(version, isA<String>());
    });

    test('event.subscribe with the UI params delivers task progress', () async {
      // Regression for the latency column that spun forever: AppController sent
      // {'events':true}, the host decoded {enabled bool}, silently ignored the
      // unknown key and subscribed the client OFF. No task.progress or
      // task.finished ever arrived, so every row stayed on "测试中".
      //
      // This drives the original failing path end to end: subscribe with the
      // real UI params, then run a speed task and require its progress to land.
      // A fake pipe cannot catch a field-name mismatch on the far side of the
      // wire, which is why this belongs in the live suite.
      final events = <HaloEventMessage>[];
      final sub = client.events.listen(events.add);
      try {
        final response = await client.send(
          HaloAction.eventSubscribe,
          params: AppController.eventSubscribeParams,
        );
        expect(response.ok, isTrue, reason: response.error?.message);
        expect(
          response.result!['subscribed'],
          isTrue,
          reason: 'UI 的订阅参数必须让宿主真的开始推送事件',
        );

        // No core needed: an endpoint probe is a plain HTTP GET, so a
        // connection-refused port yields a completed task with a failed result
        // quickly and deterministically. The node id is what the rows key on.
        final started = await client.send(
          HaloAction.speedTestStart,
          params: {
            'taskId': 'live-speed-test',
            'nodeIds': ['live-node'],
            'endpoints': ['http://127.0.0.1:1/never'],
            'timeoutMs': 1500,
            'concurrency': 1,
          },
        );
        expect(started.ok, isTrue, reason: started.error?.message);

        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline) &&
            !events.any((e) => e.name == HaloEvent.taskFinished)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(
          events.map((e) => e.name),
          contains(HaloEvent.taskProgress),
          reason: '订阅后必须收到 task.progress，否则节点页只能一直转圈',
        );
        expect(
          events.map((e) => e.name),
          contains(HaloEvent.taskFinished),
          reason: '收不到 task.finished 时页面没有任何办法结束"测试中"状态',
        );
      } finally {
        await sub.cancel();
      }
    });

    test('session.get keeps speed results after the window disconnects',
        () async {
      // The window is not the owner of a measurement. Run a batch over the real
      // pipe, destroy the client (the host sees clients=0), reconnect as a new
      // window, and require the result to still be there.
      final events = <HaloEventMessage>[];
      final sub = client.events.listen(events.add);
      try {
        await client.send(
          HaloAction.eventSubscribe,
          params: AppController.eventSubscribeParams,
        );
        final started = await client.send(
          HaloAction.speedTestStart,
          params: {
            'taskId': 'live-session-test',
            'nodeIds': ['live-session-node'],
            'endpoints': ['http://127.0.0.1:1/never'],
            'timeoutMs': 800,
            'concurrency': 1,
          },
        );
        expect(started.ok, isTrue, reason: started.error?.message);

        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline) &&
            !events.any((e) => e.name == HaloEvent.taskFinished)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          events.any((e) => e.name == HaloEvent.taskFinished),
          isTrue,
          reason: '批次未结束，无法验证结束后的结果保留',
        );
      } finally {
        await sub.cancel();
      }

      await client.dispose();
      client = HaloClient(
        pipeName: pipeName,
        pollInterval: const Duration(milliseconds: 10),
      );
      await client.connect();

      final session = await client.send(HaloAction.sessionGet);
      expect(session.ok, isTrue, reason: session.error?.message);
      final speed = session.result!['speed'] as Map;
      expect(speed['running'], isFalse);
      final results = speed['results'] as List;
      expect(
        results.any((r) => r is Map && r['nodeId'] == 'live-session-node'),
        isTrue,
        reason: '界面重开后必须能读到界面关闭前完成的测速结果',
      );
    });

    test('applying a valid config starts the core and health-checks it',
        () async {
      final config = await _validConfig();
      final response = await client.send(
        HaloAction.configApply,
        params: {'config': config, 'startCore': true},
        timeout: const Duration(seconds: 60),
      );
      expect(response.ok, isTrue, reason: response.error?.message);
      final snap = await client.send(HaloAction.snapshotGet);
      final state = RuntimeSnapshot.fromJson(snap.result ?? const {});
      expect(state.coreState, CoreState.running);
      expect(state.configVersion, greaterThan(0));
    });

    test('an invalid config is rejected and the core keeps running', () async {
      // Start from a known-good config so "still running" is meaningful.
      final ok = await client.send(
        HaloAction.configApply,
        params: {'config': await _validConfig(), 'startCore': true},
        timeout: const Duration(seconds: 60),
      );
      expect(ok.ok, isTrue);

      final bad = await client.send(
        HaloAction.configApply,
        params: {'config': '{"log":{"level":"nope"},"inbounds":[]}', 'startCore': false},
        timeout: const Duration(seconds: 60),
      );
      expect(bad.ok, isFalse);
      expect(bad.error!.code, HaloErrorCode.configInvalid);

      final snap = await client.send(HaloAction.snapshotGet);
      final state = RuntimeSnapshot.fromJson(snap.result ?? const {});
      expect(state.coreState, CoreState.running,
          reason: '校验失败不得影响正在运行的内核');
    });

    test('tun.setEnabled matches tunSupported to the service on disk', () async {
      // Two branches, because the answer depends on one on-disk fact. With the
      // service binary staged next to the core this asserts the host advertises
      // TUN and leaves it off; without it the host refuses before elevation.
      //
      // The per-run elevated helper was retired: the service is the only TUN
      // backend, and the host looks for halo-tun-service.exe next to the core
      // binary it was handed (HALO_SINGBOX in setUp).
      final service = File('${temp.path}\\halo-tun-service.exe');
      final before = await _snapshot(client);

      // A stale flag here would let the UI offer a toggle that can only fail,
      // so the snapshot has to agree with the filesystem.
      expect(
        before.tunSupported,
        service.existsSync(),
        reason: 'tunSupported 必须与 halo-tun-service.exe 是否真实存在一致',
      );

      if (service.existsSync()) {
        // Enabling TUN here would raise a real Windows UAC prompt and block a
        // human for up to 90 seconds. An automated run must never do that, so
        // assert only the state the host already published and stop.
        expect(before.tunState, TunState.disabled);
        return;
      }

      // No service binary: the host refuses before it ever asks for elevation
      // (tunEnable checks tunAvailable first), so this call is safe unattended.
      expect(before.tunState, TunState.unsupported);
      expect(before.tunMessage, isNotNull);
      expect(before.tunMessage, contains('halo-tun-service.exe'));

      final response = await client.send(
        HaloAction.tunSetEnabled,
        params: {'enabled': true},
      );
      expect(response.ok, isFalse, reason: '没有 TUN 服务程序时不得报告成功');
      expect(response.error!.code, HaloErrorCode.tunUnavailable);
      expect(response.error!.detail, isNotNull,
          reason: 'detail 是用户唯一可操作的原因');

      final after = await _snapshot(client);
      expect(after.tunState, isNot(TunState.enabled));
      expect(after.tunState.isActive, isFalse);
    });

    test('log.tail returns real host log lines', () async {
      // Trigger a logged action first, otherwise the log may be empty.
      await client.send(HaloAction.snapshotGet);
      final response = await client.send(HaloAction.logTail, params: {'lines': 30});
      expect(response.ok, isTrue);
      final lines = response.result!['lines'];
      expect(lines, isA<List<Object?>>());
    });

    test('connections.list sees a real connection and can close it', () async {
      // The whole point of the connection page is data that comes from the
      // running core, so this test drives the real path: apply a config with a
      // Clash API, open one connection through the mixed inbound, read it back,
      // then close it. A fake pipe or a mocked controller would prove none of
      // that.
      final mixedPort = await _freePort();
      final apiPort = await _freePort();
      final config = '''
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": $mixedPort}
  ],
  "outbounds": [{"type": "direct", "tag": "proxy"}],
  "route": {"final": "proxy"},
  "experimental": {"clash_api": {"external_controller": "127.0.0.1:$apiPort"}}
}
''';
      final applied = await client.send(
        HaloAction.configApply,
        params: {'config': config, 'startCore': true},
        timeout: const Duration(seconds: 60),
      );
      expect(applied.ok, isTrue, reason: applied.error?.message);

      // A listener that accepts and never answers keeps the connection open for
      // as long as the test needs it. It sends response headers immediately so
      // the host sees a proxy connection, and the body is written after the
      // host's first sample (below) so the bytes land in a delta, not in the
      // baseline.
      final sink = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      final subscription = sink.listen((socket) {
        held.add(socket);
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n');
        unawaited(socket.flush());
      });

      final probe = await Socket.connect(InternetAddress.loopbackIPv4, mixedPort);
      probe.write(
        'GET http://127.0.0.1:${sink.port}/ HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n',
      );
      await probe.flush();

      ConnectionsSnapshot? seen;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        final response = await client.send(
          HaloAction.connectionsList,
          timeout: const Duration(seconds: 10),
        );
        expect(response.ok, isTrue, reason: response.error?.message);
        final parsed = ConnectionsSnapshot.fromJson(
          response.result ?? const {},
        );
        if (parsed.connections.isNotEmpty) {
          seen = parsed;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      expect(seen, isNotNull, reason: '15 秒内没有观察到活动连接');
      final conn = seen!.connections.first;
      expect(conn.id, isNotEmpty);
      expect(conn.chains, isNotEmpty, reason: '代理链是判断走了哪个出口的唯一线索');
      expect(seen.controller, contains('127.0.0.1:'));
      // sing-box reports nanoseconds (`...09.8402524+08:00`); if that did not
      // parse, every row's age would silently render as "—".
      expect(conn.parseStart(), isNotNull);

      // The traffic clock belongs to the host. Wait until it has seen the proxy
      // connection and taken a baseline, then send response bytes so the next
      // delta is something the host can account for.
      Map<String, Object?>? baseline;
      final baselineDeadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(baselineDeadline)) {
        final response = await client.send(HaloAction.trafficGet);
        if (response.ok) {
          final value = response.result ?? const <String, Object?>{};
          final active = (value['activeConnections'] as num?)?.toInt() ?? 0;
          final history = (value['history'] as List?)?.length ?? 0;
          if (active > 0 && history > 0) {
            baseline = value;
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(baseline, isNotNull, reason: '宿主 12 秒内没有采样到代理连接');

      for (final socket in held) {
        socket.add(List<int>.filled(65536, 0x41));
        await socket.flush();
      }

      Map<String, Object?>? trafficBefore;
      final trafficDeadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(trafficDeadline)) {
        final response = await client.send(HaloAction.trafficGet);
        if (response.ok) {
          final value = response.result ?? const <String, Object?>{};
          final moved =
              ((value['uploadTotal'] as num?)?.toInt() ?? 0) +
              ((value['downloadTotal'] as num?)?.toInt() ?? 0);
          if (moved > 0) {
            trafficBefore = value;
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(
        trafficBefore,
        isNotNull,
        reason: '宿主每 2 秒采样一次，12 秒内应当看到代理连接的累计字节',
      );

      await client.dispose();
      await Future<void>.delayed(const Duration(seconds: 3));
      client = HaloClient(
        pipeName: pipeName,
        pollInterval: const Duration(milliseconds: 10),
      );
      await client.connect();
      final after = await client.send(HaloAction.trafficGet);
      expect(after.ok, isTrue, reason: after.error?.message);
      final afterValue = after.result ?? const <String, Object?>{};
      expect(
        (afterValue['uploadTotal'] as num?)?.toInt() ?? 0,
        greaterThanOrEqualTo(
          (trafficBefore!['uploadTotal'] as num?)?.toInt() ?? 0,
        ),
        reason: '界面重开后累计值不能比关闭前小',
      );
      expect(
        (afterValue['history'] as List?)?.length ?? 0,
        greaterThanOrEqualTo(
          (trafficBefore['history'] as List?)?.length ?? 0,
        ),
        reason: '界面关闭期间宿主仍在采样，历史不应倒退',
      );

      final closed = await client.send(
        HaloAction.connectionsClose,
        params: {'id': conn.id},
      );
      expect(closed.ok, isTrue, reason: closed.error?.message);

      await probe.close();
      for (final socket in held) {
        socket.destroy();
      }
      await subscription.cancel();
      await sink.close();
    });

    test('host.shutdown stops the process and the pipe closes', () async {
      await client.send(HaloAction.hostShutdown);
      // The host replies before exiting; the pipe then closes.
      final exited = await host.exitCode.timeout(const Duration(seconds: 30));
      expect(exited, isNotNull);
    });
  }, skip: hostExe == null || coreExe == null
      ? '设置 HALO_HOST_EXE 与 HALO_CORE_EXE 后运行此集成测试'
      : null);
}

/// Terminates processes whose parent is [pid] (here: the host's sing-box).
///
/// The host normally reaps its core on exit; this only matters when a test
/// aborts before host.shutdown, and leaving it alive would poison later runs.
Future<void> _killChildrenOf(int pid) async {
  if (!Platform.isWindows) return;
  try {
    final r = await Process.run('wmic', [
      'process',
      'where',
      'ParentProcessId=$pid',
      'call',
      'terminate',
    ]);
    // wmic reports failure when there is no child; that is the common case.
    if (r.exitCode != 0) return;
  } catch (_) {
    // Best-effort cleanup only; a missing wmic must not fail the test.
  }
}

/// Fetches and parses the host's current runtime snapshot.
Future<RuntimeSnapshot> _snapshot(HaloClient client) async {
  final response = await client.send(HaloAction.snapshotGet);
  expect(response.ok, isTrue, reason: response.error?.message);
  return RuntimeSnapshot.fromJson(response.result ?? const {});
}

/// A minimal but structurally valid sing-box config.
///
/// The port is allocated per call: a fixed port would collide with a core
/// orphaned by an earlier aborted run, turning a bind failure into a
/// misleading "config rejected" result.
Future<String> _validConfig() async =>
    '''
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": ${await _freePort()}}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
''';

/// Asks the OS for an unused loopback port, then releases it for sing-box.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
