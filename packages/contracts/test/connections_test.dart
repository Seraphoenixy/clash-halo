import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

/// The host flattens the Clash API's nested `metadata` before sending it, so
/// these wire names are the contract between `native/windows/internal/app/
/// connections.go` and this library. A rename on either side has to fail here
/// rather than on a user's screen showing blank columns.
void main() {
  test('a connection snapshot parses the host wire shape', () {
    final snapshot = ConnectionsSnapshot.fromJson({
      'controller': '127.0.0.1:9090',
      'uploadTotal': 120455,
      'downloadTotal': 913422,
      'memory': 0,
      'connections': [
        {
          'id': 'c1a2b3',
          'host': 'example.com',
          'network': 'tcp',
          'type': 'HTTPS',
          'rule': 'DomainSuffix',
          'rulePayload': 'example.com',
          'chains': ['节点 A', 'DIRECT'],
          'upload': 1000,
          'download': 2000,
          'start': '2026-11-04T08:00:00.123456789+08:00',
          'process': 'chrome.exe',
          'processPath': r'C:\Program Files\Google\Chrome\chrome.exe',
          'sourceIp': '127.0.0.1',
          'destinationIp': '93.184.216.34',
        },
      ],
    });

    expect(snapshot.controller, '127.0.0.1:9090');
    expect(snapshot.uploadTotal, 120455);
    expect(snapshot.connections, hasLength(1));

    final conn = snapshot.connections.single;
    expect(conn.host, 'example.com');
    expect(conn.rule, 'DomainSuffix');
    expect(conn.chains, ['节点 A', 'DIRECT']);
    expect(conn.process, 'chrome.exe');
    expect(conn.upload, 1000);
    // Nanoseconds are trimmed before parsing; without that the whole timestamp
    // would fail and every row would show "—" for its age.
    expect(conn.parseStart(), isNotNull);
  });

  test('missing fields degrade instead of throwing', () {
    final snapshot = ConnectionsSnapshot.fromJson({
      'connections': [
        {'id': 'x'},
      ],
    });
    final conn = snapshot.connections.single;
    expect(conn.host, '');
    expect(conn.chains, isEmpty);
    expect(conn.parseStart(), isNull);

    // A snapshot with no controller is how the UI tells "nothing connected"
    // from "the host cannot see the core".
    expect(ConnectionsSnapshot.fromJson(const {}).controller, '');
    expect(ConnectionsSnapshot.fromJson(const {}).connections, isEmpty);
  });

  test('age is clamped and survives a bad timestamp', () {
    final now = DateTime.parse('2026-11-04T08:00:10+08:00');
    final conn = LiveConnection(
      id: 'a',
      host: 'h',
      start: '2026-11-04T08:00:00+08:00',
    );
    expect(conn.ageFrom(now), const Duration(seconds: 10));

    // A clock skew can put the start in the future; a negative age would render
    // as "-3s" and look like a bug in the app rather than in the clock.
    final future = LiveConnection(
      id: 'b',
      host: 'h',
      start: '2026-11-04T09:00:00+08:00',
    );
    expect(future.ageFrom(now), Duration.zero);

    expect(const LiveConnection(id: 'c', host: 'h').ageFrom(now), isNull);
    expect(
      const LiveConnection(id: 'd', host: 'h', start: 'nonsense').ageFrom(now),
      isNull,
    );
  });

  test('the new actions are declared once and shared', () {
    // The UI and the host switch on these strings; a typo would surface as
    // "unknown_action" at runtime instead of a compile error.
    expect(HaloAction.connectionsList, 'connections.list');
    expect(HaloAction.connectionsClose, 'connections.close');
    expect(HaloAction.all, contains(HaloAction.connectionsList));
    expect(HaloAction.all, contains(HaloAction.connectionsClose));
  });
}
