import 'dart:convert';

import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('envelope', () {
    test('request round trips through the wire format', () {
      const request = HaloRequest(
        id: 'r1',
        action: HaloAction.snapshotGet,
        params: {'limit': 10},
      );
      final encoded = const HaloCodec().encode(request);
      expect(encoded.endsWith('\n'), isTrue);
      expect(encoded.trim().split('\n').length, 1);
      final decoded = const HaloCodec().decode(encoded);
      expect(decoded, isA<HaloRequest>());
      final again = decoded as HaloRequest;
      expect(again.id, 'r1');
      expect(again.action, HaloAction.snapshotGet);
      expect(again.params['limit'], 10);
    });

    test('response carries structured error and state version', () {
      const response = HaloResponse(
        id: 'r2',
        ok: false,
        error: HaloError(
          HaloErrorCode.configInvalid,
          '配置无效',
          '第 3 行',
        ),
        stateVersion: 7,
      );
      final json = jsonDecode(const HaloCodec().encode(response).trim())
          as Map<String, Object?>;
      expect(json['ok'], isFalse);
      expect(json['stateVersion'], 7);
      expect((json['error'] as Map)['code'], HaloErrorCode.configInvalid);
      // A failure must be parseable again: clients retry after reading it.
      final back = HaloMessage.fromJson(json) as HaloResponse;
      expect(back.error!.code, HaloErrorCode.configInvalid);
      expect(back.error!.detail, '第 3 行');
    });

    test('rejects a wrong protocol version instead of guessing', () {
      expect(
        () => HaloMessage.fromJson({'v': 2, 'id': 'x', 'ok': true}),
        throwsA(isA<HaloProtocolException>().having(
            (e) => e.code, 'code', HaloErrorCode.versionMismatch)),
      );
    });

    test('rejects an envelope that is none of the three kinds', () {
      expect(
        () => HaloMessage.fromJson({'v': 1}),
        throwsA(isA<HaloProtocolException>()),
      );
    });

    test('event keeps sequence and data', () {
      const event = HaloEventMessage(
        name: HaloEvent.taskProgress,
        seq: 12,
        data: {'completed': 3, 'total': 10},
      );
      final decoded = const HaloCodec().decode(const HaloCodec().encode(event));
      expect(decoded, isA<HaloEventMessage>());
      final again = decoded as HaloEventMessage;
      expect(again.name, HaloEvent.taskProgress);
      expect(again.seq, 12);
      expect(again.data['completed'], 3);
    });
  });

  group('codec', () {
    test('decodes several messages from one buffer and keeps the remainder', () {
      final buffer = '${jsonEncode({
            'v': 1,
            'id': 'a',
            'ok': true,
            'stateVersion': 1,
          })}\n'
          '${jsonEncode({
            'v': 1,
            'event': HaloEvent.stateChanged,
            'seq': 2,
            'data': {'coreState': 'running'},
          })}\n'
          'partial';
      final batch = const HaloCodec().decodeLines(buffer);
      expect(batch.messages.length, 2);
      expect(batch.messages[0], isA<HaloResponse>());
      expect(batch.messages[1], isA<HaloEventMessage>());
      expect(batch.remainder, 'partial');
    });

    test('ignores CRLF and blank lines', () {
      final batched = const HaloCodec().decodeLines('\r\n\r\n');
      expect(batched.messages, isEmpty);
      expect(batched.remainder, '');
    });

    test('a JSON object without a version is a protocol error, not a crash', () {
      expect(
        () => const HaloCodec().decode('{"id":"x"}'),
        throwsA(isA<HaloProtocolException>()),
      );
    });
  });

  group('snapshot model', () {
    // Captured verbatim from a running halo-host.exe (`snapshot.get`), so a
    // field rename on either side fails this test instead of silently
    // rendering an empty UI.
    final hostFrame = jsonDecode(r'''
      {"v":1,"id":"e2e","ok":true,"result":{
        "stateVersion":3,"coreState":"running","corePid":13848,"coreRestarts":0,
        "activeNodeId":"","activeNodeName":"","mode":"rule",
        "configVersion":1,
        "configHash":"a63f9850c9b1d9089bda14dedc9a90058b60e25772d989eec276fc5d70f428f2",
        "systemProxy":{"supported":false,"enabled":false,"restorable":false,
          "endpoint":"","appliedValue":"","appliedProxyEnable":0,
          "previousValue":"","previousEnable":0},
        "tunState":"disabled","tunSupported":false,
        "tunMessage":"TUN 尚未验证，需要显式确认","autoLaunch":false,
        "hostVersion":"0.1.0","coreVersion":"",
        "singboxPath":"C:\\Users\\Xuan\\AppData\\Local\\Temp\\TestHostEndToEnd46282848\\001\\sing-box.exe",
        "lastErrorCode":"","lastErrorMsg":"","logBytes":0,
        "updatedAtMs":1793661551851,"subscriptionRunnerActive":true,
        "speedTestRunning":false},
      "stateVersion":3}
    ''') as Map<String, Object?>;

    test('parses a real host snapshot without losing fields', () {
      final response = HaloMessage.fromJson(hostFrame) as HaloResponse;
      final result = response.unwrap();
      final snap = RuntimeSnapshot.fromJson(result);
      expect(snap.coreState, CoreState.running);
      expect(snap.corePid, 13848);
      expect(snap.stateVersion, 3);
      expect(snap.configVersion, 1);
      expect(snap.mode, ProxyMode.rule);
      expect(snap.tunState, TunState.disabled);
      // The host reports TUN as unverified; the model must never present that
      // as an active tunnel.
      expect(snap.tunState.isActive, isFalse);
      expect(snap.systemProxy.enabled, isFalse);
      expect(snap.systemProxy.supported, isFalse);
      expect(snap.subscriptionRunnerActive, isTrue);
      expect(response.stateVersion, 3);
    });

    test('round trips through toJson and keeps the version', () {
      final snap = RuntimeSnapshot.fromJson({
        'stateVersion': 12,
        'coreState': 'running',
        'corePid': 4242,
        'mode': 'global',
        'tunState': 'unverified',
        'systemProxy': {'supported': true, 'enabled': true, 'restorable': true},
        'coreRestarts': 2,
        'logBytes': 4096,
      });
      expect(snap.coreState.isRunning, isTrue);
      expect(snap.mode, ProxyMode.global);
      expect(snap.systemProxy.enabled, isTrue);
      expect(snap.systemProxy.restorable, isTrue);
      expect(snap.tunState, TunState.unverified);
      expect(RuntimeSnapshot.fromJson(snap.toJson()).stateVersion, 12);
      expect(RuntimeSnapshot.fromJson(snap.toJson()).systemProxy.enabled, isTrue);
    });

    test('unknown enum wire values fall back without throwing', () {
      expect(CoreState.fromWire('future'), CoreState.stopped);
      expect(ProxyMode.fromWire('future'), ProxyMode.rule);
      expect(TunState.fromWire('future'), TunState.disabled);
    });

    test('the host "failed" core state parses instead of becoming stopped', () {
      // state.CoreFailed in native/windows/internal/state. Falling back to
      // stopped made a crashed core render as 已停止 and hid the failure.
      expect(CoreState.fromWire('failed'), CoreState.failed);
      expect(CoreState.failed.wire, 'failed');
      // A failed core is neither live nor mid-transition: the UI must offer
      // start (not treat it as busy) and must not claim traffic is flowing.
      expect(CoreState.failed.isRunning, isFalse);
      expect(CoreState.failed.isBusy, isFalse);
      final snap = RuntimeSnapshot.fromJson({
        'stateVersion': 4,
        'coreState': 'failed',
        'corePid': 0,
        'lastErrorCode': 'config_apply_failed',
        'lastErrorMsg': 'exit status 1',
      });
      expect(snap.coreState, CoreState.failed);
      expect(snap.lastErrorMessage, 'exit status 1');
      expect(RuntimeSnapshot.fromJson(snap.toJson()).coreState, CoreState.failed);
    });

    test('a missing systemProxy object is treated as disabled', () {
      final snap = RuntimeSnapshot.fromJson({'stateVersion': 1});
      expect(snap.systemProxy.enabled, isFalse);
      expect(snap.systemProxy.supported, isFalse);
    });
  });

  group('speed result', () {
    test('labels distinguish latency from throughput', () {
      expect(
        const SpeedResult(nodeId: 'n', metric: SpeedMetric.proxyLatency, status: SpeedStatus.ok, valueMs: 182).label,
        '182 ms',
      );
      expect(
        const SpeedResult(nodeId: 'n', metric: SpeedMetric.download, status: SpeedStatus.ok, bytesPerSecond: 3 * 1024 * 1024).label,
        '3.0 MB/s',
      );
    });

    test('a probe that does not apply is not a failure', () {
      // A TCP handshake against a QUIC-only node says nothing about it.
      // Rendering that as 失败 would tell the user a working node is broken.
      const na = SpeedResult(
        nodeId: 'n',
        metric: SpeedMetric.tcp,
        status: SpeedStatus.notApplicable,
      );
      expect(na.label, '不适用');
      expect(na.status.isTerminal, isTrue);
      expect(na.label, isNot(contains('失败')));
    });

    test('udp is its own reachability metric, not a latency variant', () {
      expect(const SpeedResult(nodeId: 'n', metric: SpeedMetric.udp, status: SpeedStatus.ok, valueMs: 40).label, '40 ms');
      // Both are reachability checks, which is what lets the UI run them as a
      // pre-check before anything that starts a core.
      expect(SpeedMetric.tcp.isReachability, isTrue);
      expect(SpeedMetric.udp.isReachability, isTrue);
      expect(SpeedMetric.proxyLatency.isReachability, isFalse);
      // Only the delay metrics carry a millisecond value; a rate must not be
      // formatted as a delay.
      expect(SpeedMetric.download.isDelay, isFalse);
      expect(SpeedMetric.udp.isDelay, isTrue);
    });
  });
}
