import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/state/session_state.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/connections_page.dart';
import 'package:halo_contracts/halo_contracts.dart';

class _HostTrafficController extends AppController {
  _HostTrafficController() : super(dataDir: 'unused');

  @override
  Future<TrafficSessionState> fetchTrafficSession() async =>
      const TrafficSessionState(
        upRate: 1024,
        downRate: 2048,
        uploadTotal: 1234,
        downloadTotal: 5678,
        peakUp: 4096,
        peakDown: 8192,
        history: [(1024, 2048), (1024, 2048)],
        activeConnections: 1,
        updatedAtMs: 1,
        error: null,
      );
}

/// The connection page is the only place that shows what the proxy is doing
/// right now, so what it does with a snapshot matters: a blank column there is
/// indistinguishable from "that connection took no rule".
void main() {
  AppController controller() {
    final c = AppController(dataDir: 'unused');
    addTearDown(c.dispose);
    return c;
  }

  ConnectionsSnapshot sample({DateTime? now}) {
    final started = (now ?? DateTime.now()).subtract(
      const Duration(seconds: 90),
    );
    return ConnectionsSnapshot(
      controller: '127.0.0.1:9090',
      uploadTotal: 4096,
      downloadTotal: 8192,
      connections: [
        LiveConnection(
          id: 'a',
          host: 'example.com',
          network: 'tcp',
          type: 'HTTPS',
          rule: 'DomainSuffix',
          chains: const ['香港 01', 'DIRECT'],
          upload: 1024,
          download: 2048,
          start: started.toIso8601String(),
          process: 'chrome.exe',
          destinationIp: '93.184.216.34',
        ),
        LiveConnection(
          id: 'b',
          host: 'api.github.com',
          rule: 'GeoSite',
          chains: const ['日本 01'],
          upload: 10,
          download: 20,
          start: started.toIso8601String(),
          process: 'Code.exe',
        ),
      ],
    );
  }

  Widget harness(AppController c, ConnectionsLoader load) => MaterialApp(
    theme: buildHaloTheme(Brightness.light),
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 800,
        child: ConnectionsPage(controller: c, load: load),
      ),
    ),
  );

  testWidgets('renders host, process, rule and chain for each connection', (
    tester,
  ) async {
    await tester.pumpWidget(harness(controller(), () async => sample()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('chrome.exe'), findsOneWidget);
    expect(find.text('DomainSuffix'), findsOneWidget);
    // The chain is what tells the user which outbound actually carried it.
    expect(find.text('香港 01 → DIRECT'), findsOneWidget);
    expect(find.text('api.github.com'), findsOneWidget);

    // Totals in the subtitle, so the page states traffic as well as count.
    expect(find.textContaining('2 个活动连接'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('numeric headings and values share their right edge', (
    tester,
  ) async {
    final snapshot = ConnectionsSnapshot(
      controller: '127.0.0.1:9090',
      connections: [
        LiveConnection(
          id: 'a',
          host: 'example.com',
          rule: 'DomainSuffix',
          chains: const ['proxy'],
          upload: 999 * 1024 * 1024,
          download: 999 * 1024 * 1024,
          start: DateTime.now()
              .subtract(const Duration(seconds: 90))
              .toIso8601String(),
        ),
      ],
    );
    await tester.pumpWidget(harness(controller(), () async => snapshot));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    final heading = tester.getRect(find.text('流量').first);
    final reading = tester.getRect(find.text('↑999.0 MB ↓999.0 MB').first);
    expect(
      (heading.right - reading.right).abs(),
      lessThan(1.0),
      reason: '流量表头与数值必须共用右边线',
    );
    expect(reading.width, greaterThan(80), reason: '流量不能被截断到只剩箭头');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('headline traffic uses the host session, not the page counter', (
    tester,
  ) async {
    final host = _HostTrafficController();
    addTearDown(host.dispose);
    host.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.running),
      connected: true,
    );
    await tester.pumpWidget(harness(host, () async => sample()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    // The host session says 1.0/2.0 KB/s with 1.2/5.5 KB totals. The page's
    // own connection snapshot says 4.0/8.0 KB; a headline showing that would
    // be a different statistic from the overview card.
    expect(find.text('1.0 KB/s'), findsOneWidget);
    expect(find.text('2.0 KB/s'), findsOneWidget);
    expect(find.textContaining('代理流量'), findsOneWidget);
    expect(find.textContaining('上行 1.2 KB'), findsOneWidget);
    expect(find.textContaining('下行 5.5 KB'), findsOneWidget);
    expect(find.textContaining('上行 4.0 KB'), findsNothing);
    expect(find.textContaining('峰值 ↑4.0 KB/s ↓8.0 KB/s'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the filter narrows by host, process and rule', (tester) async {
    await tester.pumpWidget(harness(controller(), () async => sample()));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), 'Code.exe');
    await tester.pump();

    expect(find.text('api.github.com'), findsOneWidget);
    expect(find.text('example.com'), findsNothing);
    expect(find.textContaining('1 / 2 条匹配'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an empty snapshot explains what to do next', (tester) async {
    await tester.pumpWidget(
      harness(controller(), () async => const ConnectionsSnapshot()),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // The controller has no host here, so "the core is not running" is the
    // honest state: an empty table would hide the fact that nothing is running.
    // The phrase appears twice (subtitle and empty state), which is fine.
    expect(find.textContaining('代理内核未运行'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a narrow window does not overflow', (tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: ConnectionsPage(
            controller: controller(),
            load: () async => sample(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the speed strip shows both directions', (tester) async {
    // The feature the page exists for beyond the list: how fast, right now.
    await tester.pumpWidget(
      harness(controller(), () async => sample()),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('上行'), findsOneWidget);
    expect(find.text('下行'), findsOneWidget);
    expect(find.textContaining('峰值'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Ctrl+A selects every visible row', (tester) async {
    await tester.pumpWidget(
      harness(controller(), () async => sample()),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('已选 2'), findsOneWidget);

    // Escape clears it again.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('已选'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('arrow keys move the selection', (tester) async {
    await tester.pumpWidget(
      harness(controller(), () async => sample()),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('已选 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a column divider can be dragged', (tester) async {
    // The node table learned this the hard way: a resizer laid out inside a Row
    // with no explicit height has an empty hit area and cannot be dragged, and
    // the enclosing scroll view wins the horizontal gesture on top of that.
    await tester.pumpWidget(
      harness(controller(), () async => sample()),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final handles = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
    );
    expect(handles, findsWidgets, reason: '每个列边界都应可拖动');
    for (final element in handles.evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(rect.height, greaterThan(16),
          reason: '拖动条必须有可命中的高度，否则拖不动');
    }

    final before = tester.getTopLeft(find.text('进程')).dx;
    await tester.dragFrom(
      tester.getCenter(handles.first),
      const Offset(30, 0),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final after = tester.getTopLeft(find.text('进程')).dx;
    expect(after, greaterThan(before), reason: '拖动后右侧列应整体右移');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('every heading is rendered whole at the default widths', (
    tester,
  ) async {
    // A clipped heading still reports its full string through find.text, so the
    // check has to compare the glyphs' intrinsic width with the space the cell
    // gave them.
    await tester.pumpWidget(
      harness(controller(), () async => sample()),
    );
    await tester.pump(const Duration(milliseconds: 50));

    for (final heading in ['主机', '进程', '规则', '代理链', '流量', '上速', '下速', '时长']) {
      final finder = find.text(heading);
      expect(finder, findsWidgets, reason: '表头「$heading」缺失');
      final widget = tester.widget<Text>(finder.first);
      final painter = TextPainter(
        text: TextSpan(text: widget.data, style: widget.style),
        textDirection: TextDirection.ltr,
      )..layout();
      final needed = painter.width;
      final available = tester.getRect(finder.first).width;
      painter.dispose();
      expect(available + 1, greaterThanOrEqualTo(needed),
          reason: '表头「$heading」需要 ${needed.toStringAsFixed(1)}px，'
              '实际只有 ${available.toStringAsFixed(1)}px');
    }

    await tester.pumpWidget(const SizedBox());
  });
}
