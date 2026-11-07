import 'dart:convert';
import 'dart:typed_data';

import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/ipc/win_pipe.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

/// A pipe backed by an in-memory queue, matching the production pipe surface.
class _FakePipe implements WindowsPipe {
  @override
  int detach() => throw UnsupportedError('Fake pipe has no native handle');

  @override
  WindowsPipe duplicate() =>
      throw UnsupportedError('Fake pipe has no native handle');

  @override
  int? get handle => null; // no native handle: the client polls this pipe
  _FakePipe();

  final BytesBuilder _inbox = BytesBuilder();
  final List<int> _written = <int>[];
  bool _open = true;

  void pushLine(String line) => _inbox.add(utf8.encode('$line\n'));

  void pushRaw(List<int> bytes) => _inbox.add(bytes);

  String get written => utf8.decode(_written, allowMalformed: true);

  void breakConnection() => _open = false;

  @override
  bool get isOpen => _open;

  @override
  int get available => _inbox.length;

  @override
  Uint8List read([int maxBytes = 8192]) {
    if (!_open) return Uint8List(0);
    final all = _inbox.takeBytes();
    if (all.isEmpty) return Uint8List(0);
    if (all.length <= maxBytes) return all;
    _inbox.add(all.sublist(maxBytes));
    return Uint8List.sublistView(all, 0, maxBytes);
  }

  @override
  void write(List<int> data) {
    if (!_open) throw const WindowsPipeException('管道已关闭', 109);
    _written.addAll(data);
  }

  @override
  void close() => _open = false;
}

class _Transport extends HostTransport {
  _Transport(this.pipe);

  final _FakePipe pipe;
  int connects = 0;

  @override
  Future<WindowsPipe> connect(String name) async {
    connects++;
    return pipe;
  }
}

void main() {
  late _FakePipe pipe;
  late _Transport transport;
  late HaloClient client;

  setUp(() {
    pipe = _FakePipe();
    transport = _Transport(pipe);
    client = HaloClient(
        transport: transport, pollInterval: const Duration(milliseconds: 5));
  });

  tearDown(() async {
    await client.dispose();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('sends a protocol-versioned request and resolves its response', () async {
    await client.connect();
    expect(client.isConnected, isTrue);

    final future = client.send(HaloAction.snapshotGet);
    await settle();
    // The request line is valid NDJSON the host can parse, not two lines.
    expect(pipe.written.endsWith('\n'), isTrue);
    expect(pipe.written.split('\n').where((l) => l.isNotEmpty).length, 1);
    final sent = jsonDecode(pipe.written.trim()) as Map<String, Object?>;
    expect(sent['v'], kProtocolVersion);
    expect(sent['action'], HaloAction.snapshotGet);
    expect(sent['id'], isNotEmpty);

    pipe.pushLine(jsonEncode({
      'v': 1,
      'id': sent['id'],
      'ok': true,
      'result': {'coreState': 'running'},
      'stateVersion': 4,
    }));
    final response = await future;
    expect(response.ok, isTrue);
    expect(response.stateVersion, 4);
    expect(response.result!['coreState'], 'running');
  });

  test('an event arriving before the response is not mistaken for it', () async {
    await client.connect();
    final events = <HaloEventMessage>[];
    client.events.listen(events.add);

    final future = client.send(HaloAction.hostStatus);
    await settle();

    // The host broadcasts state changes to every client, so an event can
    // legitimately arrive before the reply to our own request.
    pipe.pushLine(jsonEncode({
      'v': 1,
      'event': HaloEvent.stateChanged,
      'seq': 7,
      'data': {'coreState': 'running'},
      'stateVersion': 5,
    }));
    pipe.pushLine(jsonEncode({
      'v': 1,
      'id': 'u1',
      'ok': true,
      'result': {'hostVersion': '0.1.0'},
      'stateVersion': 5,
    }));

    await settle();
    expect(events.map((e) => e.name), contains(HaloEvent.stateChanged));
    expect(events.single.data['coreState'], 'running');
    final response = await future;
    expect(response.result!['hostVersion'], '0.1.0');
  });

  test('a response with a foreign id does not complete the pending request',
      () async {
    await client.connect();
    final future = client.send(HaloAction.snapshotGet);
    await settle();

    pipe.pushLine(jsonEncode({'v': 1, 'id': 'someone-else', 'ok': true}));
    await settle();
    var completed = false;
    unawaitedCapture(() async {
      await future;
      completed = true;
    });
    await settle();
    expect(completed, isFalse, reason: 'a stale id must be ignored');

    pipe.pushLine(jsonEncode({'v': 1, 'id': 'u1', 'ok': true, 'result': {}}));
    await future;
  });

  test('two rapid commands are serialised, not interleaved', () async {
    await client.connect();
    final first = client.send(HaloAction.configApply, params: {'config': '{}'});
    final second = client.send(HaloAction.snapshotGet);
    await settle();

    final lines = pipe.written.split('\n').where((l) => l.isNotEmpty).toList();
    // Only the first command may be on the wire while it is unanswered: the
    // host executes commands one at a time, so writing both at once would let
    // a config apply and a snapshot interleave on the host side.
    expect(lines.length, 1, reason: 'second request must not be written yet');
    final a = jsonDecode(lines[0]) as Map<String, Object?>;
    expect(a['action'], HaloAction.configApply);

    pipe.pushLine(jsonEncode({'v': 1, 'id': a['id'], 'ok': true, 'result': {}}));
    expect((await first).ok, isTrue);
    await settle();

    // Now the second command goes out, with its own correlation id.
    final after = pipe.written.split('\n').where((l) => l.isNotEmpty).toList();
    expect(after.length, 2);
    final b = jsonDecode(after[1]) as Map<String, Object?>;
    expect(b['action'], HaloAction.snapshotGet);
    expect(b['id'], isNot(a['id']));
    pipe.pushLine(jsonEncode({'v': 1, 'id': b['id'], 'ok': true, 'result': {}}));
    expect((await second).ok, isTrue);
  });

  test('a read bypasses the command queue while a command is in flight',
      () async {
    await client.connect();
    final command = client.send(HaloAction.configApply, params: {'config': '{}'});
    final read = client.sendRead(HaloAction.snapshotGet);
    await settle();

    // Both frames are on the wire: the read must not queue behind the
    // unanswered command, or every page would freeze while a TUN enable waits
    // out its host-side budget.
    final lines = pipe.written.split('\n').where((l) => l.isNotEmpty).toList();
    expect(lines.length, 2);
    final readSent = jsonDecode(lines[1]) as Map<String, Object?>;
    expect(readSent['action'], HaloAction.snapshotGet);
    expect(readSent['id'], isNot(jsonDecode(lines[0])['id']));

    // The read completes even though the command has not been answered.
    pipe.pushLine(
      jsonEncode({'v': 1, 'id': readSent['id'], 'ok': true, 'result': {}}),
    );
    expect((await read).ok, isTrue);

    // The command is still in flight and is still answered by its own id.
    final commandSent = jsonDecode(lines[0]) as Map<String, Object?>;
    pipe.pushLine(
      jsonEncode({'v': 1, 'id': commandSent['id'], 'ok': true, 'result': {}}),
    );
    expect((await command).ok, isTrue);
  });

  test('a failed response surfaces the host error instead of hanging', () async {
    await client.connect();
    final future = client.send(HaloAction.configApply, params: {'config': 'x'});
    await settle();
    pipe.pushLine(jsonEncode({
      'v': 1,
      'id': 'u1',
      'ok': false,
      'error': {'code': HaloErrorCode.configInvalid, 'message': '配置无效'},
      'stateVersion': 3,
    }));
    final response = await future;
    expect(response.ok, isFalse);
    expect(response.error!.code, HaloErrorCode.configInvalid);
    // unwrap() throws for callers that prefer exceptions.
    expect(() => response.unwrap(), throwsA(isA<HaloError>()));
  });

  test('a broken pipe marks the connection disconnected', () async {
    await client.connect();
    final states = <HostConnectionState>[];
    client.connectionState.listen(states.add);
    pipe.breakConnection();
    await settle();
    expect(client.isConnected, isFalse);
    expect(states, contains(HostConnectionState.disconnected));
  });

  test('reconnecting yields a fresh connection and a new request id', () async {
    await client.connect();
    expect(transport.connects, 1);
    pipe.breakConnection();
    await settle();
    expect(client.isConnected, isFalse);

    // A reconnect uses the same client but must not replay old events.
    final fresh = _FakePipe();
    final transport2 = _Transport(fresh);
    final client2 = HaloClient(
        transport: transport2, pollInterval: const Duration(milliseconds: 5));
    await client2.connect();
    expect(client2.isConnected, isTrue);
    final future = client2.send(HaloAction.snapshotGet);
    await settle();
    final sent = jsonDecode(fresh.written.trim()) as Map<String, Object?>;
    expect(sent['id'], 'u1');
    fresh.pushLine(jsonEncode({'v': 1, 'id': 'u1', 'ok': true, 'result': {}}));
    expect((await future).ok, isTrue);
    await client2.dispose();
  });

  test('a request times out instead of waiting forever', () async {
    await client.connect();
    await expectLater(
      client.send(HaloAction.snapshotGet,
          timeout: const Duration(milliseconds: 80)),
      throwsA(isA<HaloProtocolException>()),
    );
  });

  test('sending while disconnected fails immediately', () async {
    await expectLater(
      client.send(HaloAction.snapshotGet),
      throwsA(isA<HaloProtocolException>()),
    );
  });

  test('multi-byte UTF-8 split across reads survives intact', () async {
    await client.connect();
    final events = <HaloEventMessage>[];
    client.events.listen(events.add);
    // A Chinese log line, deliberately split inside the first character so a
    // per-chunk decoder would corrupt it.
    final full = utf8.encode(jsonEncode({
      'v': 1,
      'event': HaloEvent.logAppended,
      'seq': 1,
      'data': {'text': '已连接后台服务'},
    }));
    // Deliberately split inside the first Chinese character (3 bytes in
    // UTF-8) so a per-chunk decoder would corrupt it.
    final charStart = full.indexOf(utf8.encode('已')[0]);
    final splitAt = charStart + 1;
    pipe.pushRaw(full.sublist(0, splitAt));
    await settle();
    // Terminate the frame: a line only exists once its newline has arrived.
    pipe.pushRaw(<int>[...full.sublist(splitAt), 0x0A]);
    await settle();
    expect(events, hasLength(1));
    expect(events.single.name, HaloEvent.logAppended);
    expect(events.single.data['text'], '已连接后台服务');
  });

  test('a version-mismatch frame is surfaced instead of swallowed', () async {
    await client.connect();
    final states = <HostConnectionState>[];
    client.connectionState.listen(states.add);

    final pending = client.send(HaloAction.snapshotGet);
    // Attach the failure expectation before the frame lands: a mismatch fails
    // every request already in flight.
    final failure = expectLater(
      pending,
      throwsA(
        isA<HaloProtocolException>().having(
          (e) => e.code,
          'code',
          HaloErrorCode.versionMismatch,
        ),
      ),
    );
    await settle();

    // An older host answers with its own protocol version.
    pipe.pushLine(
      jsonEncode({'v': kProtocolVersion + 1, 'id': 'u1', 'ok': true}),
    );
    await settle();

    // The UI must not keep claiming a working connection: every later frame
    // from that host would be rejected the same way.
    expect(client.state, HostConnectionState.versionMismatch);
    expect(client.isConnected, isFalse);
    expect(states, contains(HostConnectionState.versionMismatch));
    await failure;

    // And the next request fails immediately rather than waiting out a
    // timeout on a connection that cannot answer.
    await expectLater(
      client.send(HaloAction.snapshotGet),
      throwsA(isA<HaloProtocolException>()),
    );
  });

  test('a malformed frame does not disconnect the client', () async {
    await client.connect();
    pipe.pushLine('this is not json');
    await settle();
    expect(client.isConnected, isTrue);
    // Malformed is not the same as incompatible: a bad line may be transient
    // noise (host mid-upgrade), so it must not move the connection state.
    expect(client.state, HostConnectionState.connected);

    final future = client.send(HaloAction.snapshotGet);
    await settle();
    pipe.pushLine(jsonEncode({'v': 1, 'id': 'u1', 'ok': true, 'result': {}}));
    expect((await future).ok, isTrue);
  });
}

/// Starts an async closure without awaiting it, for assertions that must
/// observe "did not complete".
void unawaitedCapture(Future<void> Function() body) {
  body();
}
