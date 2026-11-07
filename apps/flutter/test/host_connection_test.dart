import 'dart:async';

import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/host_connection.dart';
import 'package:test/test.dart';

class _FakeClient extends HaloClient {
  _FakeClient() : super(pipeName: 'fake-pipe');

  final StreamController<HostConnectionState> _states =
      StreamController<HostConnectionState>.broadcast();

  bool failConnect = false;
  int connects = 0;
  bool _connected = false;

  @override
  Stream<HostConnectionState> get connectionState => _states.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    connects++;
    if (failConnect) throw StateError('no host');
  }

  void emit(HostConnectionState state) {
    _connected = state == HostConnectionState.connected;
    _states.add(state);
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await super.dispose();
  }
}

HostConnection _connection(
  _FakeClient client, {
  void Function()? onChanged,
  Future<void> Function()? onConnected,
  void Function(String)? onError,
  void Function()? onHostExiting,
}) {
  return HostConnection(
    client: client,
    reconnectDelay: const Duration(milliseconds: 10),
    onChanged: onChanged ?? () {},
    onConnected: onConnected ?? () async {},
    onError: onError ?? (_) {},
    onHostExiting: onHostExiting ?? () {},
  );
}

void main() {
  test('a successful connect publishes connected and runs onConnected',
      () async {
    final client = _FakeClient();
    var changed = 0;
    var connectedCalls = 0;
    final host = _connection(
      client,
      onChanged: () => changed++,
      onConnected: () async => connectedCalls++,
    );
    addTearDown(() async {
      await host.dispose();
      await client.dispose();
    });

    await host.start();

    expect(host.state, HostConnectionState.connected);
    expect(host.connected, isTrue);
    expect(connectedCalls, 1);
    expect(changed, greaterThan(0));
  });

  test('a failed connect schedules a retry', () async {
    final client = _FakeClient()..failConnect = true;
    final host = _connection(client);
    addTearDown(() async {
      await host.dispose();
      await client.dispose();
    });

    await host.start();
    expect(host.state, HostConnectionState.disconnected);
    expect(client.connects, 1);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.connects, greaterThan(1),
        reason: 'the reconnect timer must try again');
  });

  test('a version mismatch is terminal and reported once', () async {
    final client = _FakeClient();
    var messages = <String>[];
    final host = _connection(client, onError: messages.add);
    addTearDown(() async {
      await host.dispose();
      await client.dispose();
    });

    await host.start();
    client.emit(HostConnectionState.versionMismatch);
    await Future<void>.delayed(Duration.zero);

    expect(host.state, HostConnectionState.versionMismatch);
    expect(messages, hasLength(1));
    expect(messages.single, contains('协议版本'));

    final connectsAfterMismatch = client.connects;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.connects, connectsAfterMismatch,
        reason: 'reconnecting to a different wire version cannot help');
  });

  test('host exiting is terminal and calls back once', () async {
    final client = _FakeClient();
    var exits = 0;
    final host = _connection(client, onHostExiting: () => exits++);
    addTearDown(() async {
      await host.dispose();
      await client.dispose();
    });

    await host.start();
    host.markHostExiting();
    host.markHostExiting();

    expect(host.hostExiting, isTrue);
    expect(host.state, HostConnectionState.disconnected);
    expect(exits, 1);

    final connects = client.connects;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.connects, connects, reason: 'a dead host must not be retried');
  });
}
