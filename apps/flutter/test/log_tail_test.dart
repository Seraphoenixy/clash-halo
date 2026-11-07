import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';

/// The host and the UI do not use the same shape for a log line.
///
/// `log.tail` answers with `{atMs, text}`; the event model is `{seq, atMs,
/// level, source, message}`. Feeding the former to `LogEntry.fromJson` compiles,
/// runs, and produces entries whose message is the empty string — which is
/// exactly what shipped: a log page that rendered blank rows and looked like it
/// had no data even when the host log was full.
void main() {
  test('host tail lines carry text, not message', () {
    final entries = logEntriesFromTail([
      {'atMs': 1000, 'text': '[host] listening on pipe'},
      {'atMs': 1001, 'text': '[host] 托盘图标已应用（idle）'},
    ]);

    expect(entries, hasLength(2));
    expect(entries.first.message, '[host] listening on pipe');
    expect(entries.first.atMs, 1000);
    // Level and source are not in the wire payload; the defaults must not be
    // empty strings, or the level filter would hide every line.
    expect(entries.first.level, 'info');
    expect(entries.first.source, 'host');
    expect(entries.last.message, contains('托盘图标'));
  });

  test('empty or malformed payloads do not produce blank rows', () {
    expect(logEntriesFromTail(null), isEmpty);
    expect(logEntriesFromTail('not a list'), isEmpty);
    expect(
      logEntriesFromTail([
        {'atMs': 1, 'text': ''},
        {'atMs': 2},
        'nonsense',
        null,
      ]),
      isEmpty,
    );
  });

  test('the richer event shape still parses', () {
    // If the host ever starts emitting log.appended with the full shape, the
    // same reader must keep working.
    final entries = logEntriesFromTail([
      {
        'seq': 7,
        'atMs': 5,
        'level': 'error',
        'source': 'core',
        'message': 'sing-box exited',
      },
    ]);
    expect(entries.single.level, 'error');
    expect(entries.single.source, 'core');
    expect(entries.single.message, 'sing-box exited');
    expect(entries.single.seq, 7);
  });
}
