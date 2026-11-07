import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/throughput.dart';
import 'package:halo_contracts/halo_contracts.dart';

/// The core reports cumulative counters, so every rate on the connection page is
/// a difference this class computes. Getting it wrong shows a plausible number,
/// which is the worst kind of wrong in a monitor.
void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);

  ConnectionsSnapshot snap({
    int up = 0,
    int down = 0,
    List<LiveConnection> connections = const [],
  }) => ConnectionsSnapshot(
    uploadTotal: up,
    downloadTotal: down,
    connections: connections,
  );

  LiveConnection conn(String id, {int up = 0, int down = 0}) =>
      LiveConnection(id: id, host: '$id.example', upload: up, download: down);

  test('the first sample establishes a baseline and reports no rate', () {
    // Nothing has been measured yet: a rate needs an interval, and inventing
    // one from zero would show a huge spike on the first poll.
    final m = ThroughputMonitor();
    m.sample(snap(up: 5000, down: 9000), t0);
    expect(m.upRate, 0);
    expect(m.downRate, 0);
    expect(m.hasSample, isTrue);
    // A baseline is not a curve. Charts key their "等待采样…" placeholder on
    // hasCurve; using hasSample left the band blank for the first poll, which
    // reads as a chart that failed to load.
    expect(m.hasCurve, isFalse);
  });

  test('a curve exists only once two samples can be differenced', () {
    final m = ThroughputMonitor();
    m.sample(snap(up: 1000, down: 2000), t0);
    expect(m.hasCurve, isFalse);
    // The first sample has no interval behind it, so it appends nothing; two
    // plotted points need three polls.
    m.sample(snap(up: 3000, down: 2200), t0.add(const Duration(seconds: 2)));
    expect(m.hasCurve, isFalse);
    m.sample(snap(up: 4000, down: 2600), t0.add(const Duration(seconds: 4)));
    expect(m.hasCurve, isTrue);
    m.reset();
    expect(m.hasCurve, isFalse);
  });

  test('the rate is the delta divided by elapsed time', () {
    final m = ThroughputMonitor();
    m.sample(snap(up: 1000, down: 2000), t0);
    m.sample(snap(up: 3000, down: 2200), t0.add(const Duration(seconds: 2)));
    // (3000-1000)/2 = 1000 B/s, (2200-2000)/2 = 100 B/s.
    expect(m.upRate, 1000);
    expect(m.downRate, 100);
  });

  test('a core restart resets the baseline instead of showing a negative', () {
    // Counters go back to zero when the core restarts. Subtracting blindly
    // yields a large negative rate, which draws a cliff through the sparkline
    // and reads as "traffic stopped".
    final m = ThroughputMonitor();
    m.sample(snap(up: 100000, down: 200000), t0);
    m.sample(snap(up: 500, down: 700), t0.add(const Duration(seconds: 1)));
    expect(m.upRate, 0);
    expect(m.downRate, 0);

    // The new baseline is then usable again.
    m.sample(snap(up: 1500, down: 2700), t0.add(const Duration(seconds: 2)));
    expect(m.upRate, 1000);
    expect(m.downRate, 2000);
  });

  test('per-connection rates need two samples of that connection', () {
    final m = ThroughputMonitor();
    m.sample(snap(up: 100, down: 100, connections: [conn('a', up: 10)]), t0);
    // A connection with no history has an unknown rate, not a zero one: every
    // new connection would otherwise briefly claim 0 B/s.
    expect(m.perConnection.containsKey('a'), isFalse);

    m.sample(
      snap(up: 300, down: 300, connections: [conn('a', up: 110, down: 40)]),
      t0.add(const Duration(seconds: 1)),
    );
    expect(m.perConnection['a'], (100.0, 40.0));
  });

  test('a connection that disappears stops being reported', () {
    final m = ThroughputMonitor();
    m.sample(snap(up: 0, down: 0, connections: [conn('a'), conn('b')]), t0);
    m.sample(
      snap(up: 100, down: 100, connections: [conn('a', up: 10), conn('b')]),
      t0.add(const Duration(seconds: 1)),
    );
    expect(m.perConnection.keys, containsAll(['a', 'b']));

    m.sample(
      snap(up: 200, down: 200, connections: [conn('a', up: 20)]),
      t0.add(const Duration(seconds: 2)),
    );
    expect(m.perConnection.containsKey('b'), isFalse);
  });

  test('the aggregate comes from the totals, not the rows', () {
    // A closed connection's bytes are already in the totals but no longer in any
    // row, so summing rows would understate the rate whenever connections end.
    final m = ThroughputMonitor();
    m.sample(snap(up: 0, down: 0, connections: [conn('a')]), t0);
    m.sample(
      snap(up: 4096, down: 0, connections: [conn('a', up: 100)]),
      t0.add(const Duration(seconds: 1)),
    );
    expect(m.upRate, 4096);
    expect(m.perConnection['a']?.$1, 100.0);
  });

  test('proxy traffic accumulates only sampled proxy bytes', () {
    final monitor = ThroughputMonitor(proxyOnly: true);
    LiveConnection row(String id, List<String> chains, int up, int down) =>
        LiveConnection(
          id: id,
          host: id,
          chains: chains,
          upload: up,
          download: down,
        );

    monitor.sample(snap(connections: [row('a', ['proxy'], 10, 20)]), t0);
    expect(monitor.uploadTotal, 0);
    monitor.sample(
      snap(
        up: 10000,
        down: 20000,
        connections: [
          row('a', ['proxy'], 210, 420),
          row('b', ['proxy'], 40, 80),
          row('direct', ['direct'], 1000, 2000),
          row('block', ['block'], 1000, 2000),
          row('unknown', [], 1000, 2000),
        ],
      ),
      t0.add(const Duration(seconds: 2)),
    );
    expect(monitor.activeConnections, 2);
    expect(monitor.uploadTotal, 240);
    expect(monitor.downloadTotal, 480);
    expect(monitor.upRate, 120);
    expect(monitor.downRate, 240);
    expect(monitor.history.last, (120.0, 240.0));

    monitor.sample(
      snap(connections: [row('direct', ['direct'], 2000, 3000)]),
      t0.add(const Duration(seconds: 4)),
    );
    expect(monitor.activeConnections, 0);
    expect(monitor.uploadTotal, 240);
    expect(monitor.downloadTotal, 480);
    expect(monitor.upRate, 0);
    expect(monitor.peakDown, 240);
    monitor.reset();
    expect(monitor.downloadTotal, 0);
  });

  test('history is capped and keeps the newest samples', () {
    final m = ThroughputMonitor(historyLength: 3);
    for (var i = 1; i <= 5; i++) {
      m.sample(snap(up: i * 1000, down: 0), t0.add(Duration(seconds: i)));
    }
    expect(m.history.length, 3);
    // The last sample's rate is (5000-4000)/1 = 1000.
    expect(m.history.last.$1, 1000);
  });

  test('peaks survive later quiet periods', () {
    final m = ThroughputMonitor();
    m.sample(snap(up: 0, down: 0), t0);
    m.sample(snap(up: 10000, down: 0), t0.add(const Duration(seconds: 1)));
    m.sample(snap(up: 10000, down: 0), t0.add(const Duration(seconds: 2)));
    expect(m.upRate, 0);
    expect(m.peakUp, 10000);
  });

  test('two samples closer together than the floor are ignored', () {
    final m = ThroughputMonitor();
    m.sample(snap(up: 0), t0);
    m.sample(snap(up: 999), t0.add(const Duration(milliseconds: 10)));
    expect(m.upRate, 0, reason: '过短的间隔不应产生速率');
  });

  test('rate labels use the same units as totals', () {
    // Zero is a measurement, not a missing one: it renders 0 B/s. A dash here
    // made an idle connection indistinguishable from a failed sample.
    expect(rateLabel(0), '0 B/s');
    expect(
      rateLabel(-1),
      '0 B/s',
      reason: 'a negative rate is clamped, not dashed',
    );
    expect(rateLabel(512), '512 B/s');
    expect(rateLabel(1536), '1.5 KB/s');
    expect(rateLabel(3 * 1024 * 1024), '3.00 MB/s');
  });
}
