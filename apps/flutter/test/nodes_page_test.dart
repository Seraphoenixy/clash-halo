import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/nodes_page.dart';
import 'package:halo/src/ui/widgets/measurement.dart';
import 'package:halo/src/ui/widgets/table_columns.dart';
import 'package:halo/src/ui/shell.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

import 'dart:io';

/// A client that answers `snapshot.get` and `speedtest.start` but never emits
/// an event, standing in for the desubscribed client that caused the hang.
class _SilentClient extends HaloClient {
  _SilentClient() : super(pipeName: 'never-connected');

  final List<String> startedTasks = [];
  final List<String> startedMetrics = [];
  final List<Map<String, Object?>> startedParams = [];
  bool _batchRunning = false;
  bool holdBatch = false;

  @override
  bool get isConnected => true;

  @override
  Future<HaloResponse> send(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (action) {
      case HaloAction.speedTestStart:
        startedTasks.add('${params['taskId']}');
        startedMetrics.add('${params['metric']}');
        startedParams.add(Map<String, Object?>.of(params));
        _batchRunning = true;
        return HaloResponse.success(
          'fake',
          result: {'taskId': '${params['taskId']}', 'accepted': true},
        );
      case HaloAction.snapshotGet:
        // The host clears the flag when the batch goroutine returns.
        final running = _batchRunning;
        if (!holdBatch) _batchRunning = false;
        return HaloResponse.success(
          'fake',
          result: {'speedTestRunning': running, 'stateVersion': 1},
        );
      default:
        return HaloResponse.success('fake', result: const {});
    }
  }

  @override
  Future<HaloResponse> sendRead(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) => send(action, params: params, timeout: timeout);
}

/// Tests for the v2rayN-shaped node table.
///
/// The properties pinned here are the ones that were missing and that are easy to
/// regress: sortable columns including latency, the two-tier "selected vs in
/// use" distinction, the single colour semantic for latency, and the fact that
/// `shareLinkFor` refuses rather than emitting a link that would silently break
/// in another client.
void main() {
  ProxyNode node({
    String name = 'n',
    String server = 'example.com',
    int port = 443,
    ProxyProtocol protocol = ProxyProtocol.trojan,
    String? password = 'secret',
    String? uuid,
  }) => ProxyNode(
    id: name,
    fingerprint: 'fp-$name',
    name: name,
    protocol: protocol,
    server: server,
    port: port,
    secrets: NodeSecrets(password: password, uuid: uuid),
  );

  group('latency colour', () {
    test('is one semantic: reachable, slow, unreachable', () {
      // Boundaries matter: the reference converter's thresholds are what users
      // learn, so 200 and 600 themselves stay in the lower band.
      expect(latencyColor(0), HaloColors.success);
      expect(latencyColor(200), HaloColors.success);
      expect(latencyColor(201), HaloColors.warning);
      expect(latencyColor(600), HaloColors.warning);
      expect(latencyColor(601), HaloColors.danger);
    });
  });

  group('latency filter', () {
    SpeedResult ok(int ms) => SpeedResult(
      nodeId: 'n',
      metric: SpeedMetric.proxyLatency,
      status: SpeedStatus.ok,
      valueMs: ms,
    );
    const failed = SpeedResult(
      nodeId: 'n',
      metric: SpeedMetric.proxyLatency,
      status: SpeedStatus.failed,
    );
    const canceled = SpeedResult(
      nodeId: 'n',
      metric: SpeedMetric.proxyLatency,
      status: SpeedStatus.canceled,
    );

    test('keeps untested, cancelled and unreachable distinct', () {
      // These are the states a user acts on differently, so no filter may fold
      // them together: 未测 means "not measured", 已取消 means "I stopped it",
      // 不可用 means "it was measured and failed".
      expect(LatencyFilter.untested.matches(null), isTrue);
      expect(LatencyFilter.untested.matches(failed), isFalse);
      expect(LatencyFilter.untested.matches(canceled), isFalse);

      expect(LatencyFilter.unreachable.matches(failed), isTrue);
      expect(LatencyFilter.unreachable.matches(canceled), isFalse);
      expect(LatencyFilter.unreachable.matches(null), isFalse);

      expect(LatencyFilter.reachable.matches(ok(120)), isTrue);
      expect(LatencyFilter.reachable.matches(failed), isFalse);
      expect(LatencyFilter.reachable.matches(null), isFalse);
    });

    test('the fast and slow buckets split at the colour thresholds', () {
      // The filter must agree with the colour the same number is drawn in:
      // 200 is still green and still "fast", 601 is red and "slow".
      expect(LatencyFilter.fast.matches(ok(kLatencyFastMs)), isTrue);
      expect(LatencyFilter.fast.matches(ok(kLatencyFastMs + 1)), isFalse);
      expect(LatencyFilter.slow.matches(ok(kLatencySlowMs)), isFalse);
      expect(LatencyFilter.slow.matches(ok(kLatencySlowMs + 1)), isTrue);
      expect(latencyColor(kLatencyFastMs), HaloColors.success);
      expect(latencyColor(kLatencySlowMs + 1), HaloColors.danger);
    });

    test('未确认可用的 covers both untested and unreachable', () {
      // This is the batch delete case: the rows with no usable number.
      expect(LatencyFilter.untestedOrUnreachable.matches(null), isTrue);
      expect(LatencyFilter.untestedOrUnreachable.matches(failed), isTrue);
      expect(LatencyFilter.untestedOrUnreachable.matches(ok(300)), isFalse);
    });
  });

  group('shareLinkFor', () {
    // The per-protocol export formats and their round trips live in the
    // domain package (packages/domain/test/share_link_export_test.dart),
    // next to the importer they must stay consistent with. What the UI pins
    // here is the refusal contract the row menu relies on: a protocol with no
    // unambiguous URI form, or a node missing its credential, yields null so
    // the menu can say 该协议暂不支持导出 instead of pasting a dead link.
    test('refuses rather than emitting a broken link', () {
      expect(
        shareLinkFor(node(protocol: ProxyProtocol.ssh, password: 'key-material')),
        isNull,
        reason: 'ssh needs a key file; no URI form is unambiguous',
      );
      expect(
        shareLinkFor(node(password: null)),
        isNull,
        reason: 'trojan without a password is not exportable',
      );
      expect(
        shareLinkFor(node(protocol: ProxyProtocol.vless, password: null, uuid: null)),
        isNull,
      );
    });
  });

  group('NodesPage rendering', () {
    /// A controller with no host and no store: enough to render the empty state
    /// and the shell chrome without starting timers.
    Widget harness(AppController controller) => MaterialApp(
      theme: buildHaloTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 1100,
          height: 700,
          child: NodesPage(controller: controller),
        ),
      ),
    );

    testWidgets('the empty state offers the fix, not just the diagnosis', (
      tester,
    ) async {
      final controller = AppController(dataDir: 'unused');
      addTearDown(controller.dispose);
      await tester.pumpWidget(harness(controller));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('还没有节点'), findsOneWidget);
      // The button that actually adds nodes, which the old page did not have.
      expect(find.text('去导入节点'), findsOneWidget);
    });

    testWidgets('renders inside a narrow window without overflowing', (
      tester,
    ) async {
      // 590x380 logical is a 1180x760 window at 200% scaling, the same case the
      // status bar and the store-failure pane are pinned against.
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final controller = AppController(dataDir: 'unused');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });

  group('the sort arrow does not move the heading', () {
    // Rendering the arrow only on the sorted column shifted the label by the
    // arrow's width plus its gap the moment a sort was applied, so every heading
    // in the row jumped. The slot is now always reserved.

    testWidgets('a heading stays put when its column becomes the sort', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      final tempDir = Directory.systemTemp.createTempSync('halo_arrow');
      final controller = AppController(
        client: _SilentClient(),
        dataDir: tempDir.path,
      );
      await controller.start(connectHost: false);
      try {
        controller.applySnapshotForTest(
          const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
          connected: true,
        );
        controller.saveImport(
          importNodes('trojan://pw@a.example.com:443#节点甲'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildHaloTheme(Brightness.light),
            home: Scaffold(body: NodesPage(controller: controller)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Default sort is 名称, so 延迟 has no arrow yet.
        const target = '延迟';
        final before = tester.getRect(find.text(target).first);

        // Sort by 延迟, which puts an arrow in its slot.
        await tester.tap(find.text(target).first);
        await tester.pump(const Duration(milliseconds: 200));

        final after = tester.getRect(find.text(target).first);
        expect(after.left, closeTo(before.left, 0.5),
            reason: '启用排序箭头后，表头文字不应横向移动');
        expect(after.width, closeTo(before.width, 0.5),
            reason: '文字可用宽度应保持不变');
      } finally {
        await controller.dispose();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets('the arrow follows the label on numeric columns too', (
      tester,
    ) async {
      // The first version led the numbers and trailed the text, so the arrow
      // jumped sides halfway across the header. One rule now: label, then arrow.
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      final tempDir = Directory.systemTemp.createTempSync('halo_arrow3');
      final controller = AppController(
        client: _SilentClient(),
        dataDir: tempDir.path,
      );
      await controller.start(connectHost: false);
      try {
        controller.applySnapshotForTest(
          const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
          connected: true,
        );
        controller.saveImport(
          importNodes('trojan://pw@a.example.com:443#节点甲'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildHaloTheme(Brightness.light),
            home: Scaffold(body: NodesPage(controller: controller)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Sort 延迟 (numeric) so it carries an arrow, then check the arrow sits
        // to the right of the label, not to its left.
        await tester.tap(find.text('延迟').first);
        await tester.pump(const Duration(milliseconds: 200));

        final label = tester.getRect(find.text('延迟').first);
        final slots = find
            .byType(SortArrowSlot)
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .where((r) => (r.top - label.top).abs() < 8)
            .toList();
        expect(slots, isNotEmpty, reason: '延迟列表头应有箭头占位');
        // Geometry is a poor judge here: the label is flexed to fill the cell,
        // so an arrow on either side lands within a few pixels of the edge.
        // Reading the row's own child order is unambiguous.
        final rowFinder = find.ancestor(
          of: find.text('延迟').first,
          matching: find.byType(Row),
        ).first;
        final row = tester.widget<Row>(rowFinder);
        final labelIndex = row.children.indexWhere(
          (w) => w is Flexible && w.child is Text,
        );
        final arrowIndex = row.children.indexWhere(
          (w) => w is SortArrowSlot,
        );
        expect(labelIndex, isNonNegative, reason: '表头行里应有文字');
        expect(arrowIndex, greaterThan(labelIndex),
            reason: '箭头应排在文字之后，不能因列是数字列而前置');
      } finally {
        await controller.dispose();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets('every heading reserves the same slot regardless of sort', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      final tempDir = Directory.systemTemp.createTempSync('halo_arrow2');
      final controller = AppController(
        client: _SilentClient(),
        dataDir: tempDir.path,
      );
      await controller.start(connectHost: false);
      try {
        controller.applySnapshotForTest(
          const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
          connected: true,
        );
        controller.saveImport(
          importNodes('trojan://pw@a.example.com:443#节点甲'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildHaloTheme(Brightness.light),
            home: Scaffold(body: NodesPage(controller: controller)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        final slots = find.byType(SortArrowSlot);
        // No y-threshold: the table header is the only place this page builds
        // SortArrowSlot. The old `top > 160` filter encoded the header's
        // position at the previous control height, so tightening the toolbar
        // moved one slot above 160 and the count silently dropped to 9.
        final headerSlots = slots.evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .toList();
        // One slot per column, including the ones that are not sorted.
        expect(headerSlots.length, greaterThanOrEqualTo(10),
            reason: '每列都应预留排序箭头位置');
        for (final r in headerSlots) {
          expect(r.width, closeTo(SortArrowSlot.width, 0.5));
        }
      } finally {
        await controller.dispose();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('review fixes', () {
    /// Builds a page with one node, optionally the active one.
    Future<AppController> pumpNodes(
      WidgetTester tester, {
      String? activeNodeId,
    }) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final tempDir = Directory.systemTemp.createTempSync('halo_nodes_review');
      final controller = AppController(
        client: _SilentClient(),
        dataDir: tempDir.path,
      );
      await controller.start(connectHost: false);
      controller.saveImport(
        importNodes('trojan://pw@a.example.com:10443#节点甲'),
      );
      // The snapshot is applied *after* the import: `saveImport` rebuilds the
      // node list, and a snapshot written before it was overwritten on the
      // next change notification, which made an active-node assertion look at
      // a null id.
      final id = activeNodeId ?? controller.loadNodes().first.id;
      controller.applySnapshotForTest(
        RuntimeSnapshot(
          stateVersion: 1,
          coreState: CoreState.running,
          activeNodeId: id,
        ),
        connected: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      return controller;
    }

    testWidgets('the toolbar names its frequent actions instead of showing '
        'bare glyphs', (tester) async {
      // 整理 / 重命名 / 移动 were three icons whose meaning lived only in a
      // tooltip; the frequent ones now carry a label and the rest moved into a
      // named menu.
      final controller = await pumpNodes(tester);
      try {
        expect(find.text('全选'), findsOneWidget);
        expect(find.text('测延迟'), findsOneWidget);
        expect(find.text('删除'), findsWidgets);
        expect(find.text('更多'), findsOneWidget);
        // The low-frequency actions are behind the menu, not on the bar.
        expect(find.text('移动到分组'), findsNothing);
        expect(find.text('重命名全部'), findsNothing);
      } finally {
        controller.dispose();
      }
    });

    testWidgets('the overflow menu spells out each action', (tester) async {
      final controller = await pumpNodes(tester);
      try {
        await tester.tap(find.byKey(const ValueKey('nodes-more')));
        await tester.pumpAndSettle();
        expect(find.text('重命名所选'), findsOneWidget);
        expect(find.text('移动到分组'), findsOneWidget);
        expect(find.text('保存排序'), findsOneWidget);
        expect(find.text('显示列…'), findsOneWidget);
      } finally {
        controller.dispose();
      }
    });

    testWidgets('the active row says 使用中 in words', (tester) async {
      // A selected row and a row that is actually carrying traffic looked the
      // same: a dot plus a coloured left edge. The difference matters, because
      // the selected row may be one the user is about to switch to.
      final controller = await pumpNodes(tester, activeNodeId: 'pending');
      try {
        final nodes = controller.loadNodes();
        expect(nodes, isNotEmpty, reason: '导入后必须有节点，否则本测试空转');
        // Re-point the snapshot at the real id, which only exists after import.
        controller.applySnapshotForTest(
          RuntimeSnapshot(
            stateVersion: 2,
            coreState: CoreState.running,
            activeNodeId: nodes.first.id,
          ),
          connected: true,
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('使用中'), findsOneWidget);
      } finally {
        controller.dispose();
      }
    });

    testWidgets('the active row does not indent its name with a dot', (
      tester,
    ) async {
      // The green dot sat *before* the name, so the one row the user is looking
      // for started 10px right of every other row and of its own column
      // heading. It also repeated what the 使用中 badge and the 3px left edge
      // already say. The name now starts exactly on the column's left edge.
      final controller = await pumpNodes(tester);
      try {
        final name = tester.getTopLeft(find.text('节点甲'));
        final header = tester.getTopLeft(find.text('名称'));
        expect(
          name.dx,
          closeTo(header.dx, 0.5),
          reason: '当前节点的名称应与列标题左对齐，不能被前置圆点推开',
        );
      } finally {
        controller.dispose();
      }
    });

    testWidgets('a technical column can be hidden and its space is returned', (
      tester,
    ) async {
      final controller = await pumpNodes(tester);
      try {
        expect(find.text('传输'), findsWidgets);
        // Hide it through the same path the UI uses.
        final state = tester.state(find.byType(NodesPage));
        expect(state, isNotNull);
        // Drive the menu instead of reaching into private state: the behaviour
        // under test is that the column disappears from the header and the row.
        await tester.tap(find.byKey(const ValueKey('nodes-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('显示列…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换「传输」列'));
        await tester.pumpAndSettle();
        expect(find.text('传输'), findsNothing);
      } finally {
        controller.dispose();
      }
    });
  });

  group('default column widths', () {
    // Readings and headings must fit without being clipped at the default
    // width. Each of these was silently cut at some point: a port rendered as
    // "4...", 传输 as "T...", and a latency reading as "4316 m...". A clipped
    // number in a table of numbers is worse than a narrow column, because it
    // reads as a different value.

    testWidgets('every column shows its content without ellipsis', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      final tempDir = Directory.systemTemp.createTempSync('halo_widths');
      final controller = AppController(
        client: _SilentClient(),
        dataDir: tempDir.path,
      );
      await controller.start(connectHost: false);
      try {
        controller.applySnapshotForTest(
          const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
          connected: true,
        );
        // A five-digit port and a five-digit latency: the widest realistic
        // content for those columns.
        controller.saveImport(
          importNodes(
            'trojan://pw@a.example.com:10443#节点甲\n'
            'trojan://pw@b.example.com:443#节点乙',
          ),
        );
        controller.applyEventForTest(
          const HaloEventMessage(
            name: HaloEvent.taskStarted,
            data: {'taskId': 'w', 'count': 1},
          ),
        );
        controller.applyEventForTest(
          const HaloEventMessage(
            name: HaloEvent.taskProgress,
            data: {
              'taskId': 'w',
              'nodeId': 'x',
              'metric': 'proxy_latency',
              'ok': true,
              'latencyMs': 4316,
            },
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: buildHaloTheme(Brightness.light),
            home: Scaffold(body: NodesPage(controller: controller)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        // Column headings must be rendered whole, not clipped to "T...".
        // find.text alone cannot tell: a clipped Text keeps its data, so the
        // string is still findable. Compare the painted width against the
        // width the glyphs actually need.
        for (final heading in [
          '名称', '类型', '地址', '端口', '传输', 'TLS',
          '分组', '端口连通', '延迟', '速度',
        ]) {
          final finder = find.text(heading);
          expect(finder, findsWidgets, reason: '表头「$heading」缺失');
          // Compare the space the cell gave the text against the width the
          // glyphs need. A clipped Text still fills its box, so measuring the
          // box alone proves nothing; overflow shows up as available < needed.
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
                  '实际只有 ${available.toStringAsFixed(1)}px，会被截断');
        }

        // A five-digit port must fit its cell. find.text alone is not enough:
        // when a Text is clipped it still reports the same data, so the string
        // is found even though the glyphs were replaced by an ellipsis. The
        // real check is that the cell is at least as wide as the text needs.
        expect(find.text('10443'), findsWidgets,
            reason: '端口列必须能显示五位端口');
        final portHeader = tester.getRect(find.text('端口').first);
        // 5 digits in the cell's monospace font is about 35 px; with 16 px of
        // padding the column cannot be much under 50.
        expect(portHeader.width, greaterThan(0));
        final portText = tester.getRect(find.text('10443').first);
        expect(portText.width, greaterThan(28),
            reason: '被截断成「4…」时文字宽度会塌缩到几个像素');

        // Every row's cells stay inside the viewport at the default width.
        final viewport =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        final speedHeader = tester.getRect(find.text('速度').first);
        expect(speedHeader.right, lessThan(viewport),
            reason: '默认列宽下速度列必须可见');
      } finally {
        await controller.dispose();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  testWidgets('端口连通 data fits its heading and shares its right edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2360, 1520);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final tempDir = Directory.systemTemp.createTempSync('halo_reach_width');
    final controller = AppController(
      client: _SilentClient(),
      dataDir: tempDir.path,
    );
    await controller.start(connectHost: false);
    try {
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(
        importNodes('trojan://pw@a.example.com:443#节点甲'),
      );
      final id = controller.loadNodes().first.id;
      controller.applyEventForTest(
        const HaloEventMessage(
          name: HaloEvent.taskStarted,
          data: {'taskId': 'r'},
        ),
      );
      controller.applyEventForTest(
        HaloEventMessage(
          name: HaloEvent.taskProgress,
          data: {
            'taskId': 'r',
            'nodeId': id,
            'metric': 'tcp',
            'ok': true,
            'latencyMs': 1251,
          },
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);

      final heading = tester.getRect(find.text('端口连通').first);
      final reading = tester.getRect(find.text('TCP 通 1251ms').first);
      // The header reserves the sort slot and a numeric cell now reserves the
      // same slot, so both right edges describe one column edge.
      expect(
        (heading.right - reading.right).abs(),
        lessThan(1.0),
        reason: '端口连通表头与数据必须共用右边线',
      );
      expect(reading.width, greaterThan(60), reason: '数据不能被截断到几个像素');
    } finally {
      await controller.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('NodesPage with nodes', () {
    late Directory tempDir;
    late AppController controller;

    testWidgets('column widths can be dragged and the columns stay in order', (
      tester,
    ) async {
      // Two regressions this pins: the default widths once totalled 1126 px in
      // a ~780 px viewport, pushing 端口连通/延迟/速度 off screen entirely; and
      // the divider sat inside a horizontal scrollable, which won the drag
      // arena so the width could not be changed at all.
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(
        importNodes('trojan://pw@hk.example.com:443#香港%2001'),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // Reading order: reachability, then latency, then throughput.
      // A column title must sit over its own data. The header is a fixed-width
      // row inside a Column, and Column centres its children by default, so it
      // was drawn 184 px right of the body: every title pointed at the wrong
      // column while both used identical widths.
      final nameHeader = tester.getTopLeft(find.text('名称')).dx;
      final nameCell = tester.getTopLeft(find.text('香港 01')).dx;
      expect((nameHeader - nameCell).abs(), lessThan(2),
          reason: '名称表头必须与其数据左对齐');
      final serverHeader = tester.getTopLeft(find.text('地址')).dx;
      final serverCell = tester.getTopLeft(find.text('hk.example.com')).dx;
      expect((serverHeader - serverCell).abs(), lessThan(2),
          reason: '地址表头必须与其数据左对齐');

      final reach = tester.getTopLeft(find.text('端口连通')).dx;
      final latency = tester.getTopLeft(find.text('延迟')).dx;
      final speed = tester.getTopLeft(find.text('速度')).dx;
      expect(reach, lessThan(latency), reason: '端口连通应在延迟之前');
      expect(latency, lessThan(speed), reason: '延迟应在速度之前');

      // Every measurement column must be on screen at the default width.
      final viewport = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(speed + 40, lessThan(viewport),
          reason: '默认列宽下速度列必须可见，否则它等于不存在');

      // Dragging the divider after 名称 must actually move the boundary. The
      // handle sits _kResizerWidth to the right of the name cell, so it is
      // located from the rendered geometry rather than a guessed coordinate.
      final before = tester.getTopLeft(find.text('类型')).dx;
      // Located through the widget tree rather than a guessed coordinate: the
      // handle is a private widget, so it is found by its cursor region, which
      // is the first resizeColumn MouseRegion in the header.
      final handles = find.byWidgetPredicate(
        (w) =>
            w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
      );
      expect(handles, findsWidgets, reason: '每个列边界都应可拖动');
      // Each handle must have a real hit area. It was laid out 0 px tall in the
      // header Row, which made it invisible to the pointer and the column
      // undraggable despite the callback being wired correctly.
      for (final element in handles.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.height, greaterThan(16),
            reason: '拖动条必须有可命中的高度，否则拖不动');
      }
      final firstHandle = tester.getCenter(handles.first);

      // Walk the pointer by hand: Listener reports moves, and a single
      // dragFrom would still deliver them, but this makes a missed hit test
      // obvious in the failure message.
      final gesture = await tester.startGesture(firstHandle);
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(5, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      final after = tester.getTopLeft(find.text('类型')).dx;
      expect(after, greaterThan(before),
          reason: '拖动分隔线后，右侧各列应整体右移');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('halo_nodes_page');
      controller = AppController(dataDir: tempDir.path);
      await controller.start(connectHost: false);
    });

    tearDown(() async {
      await controller.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // A lingering WAL file can keep the directory busy on Windows.
      }
    });

    Widget harness() => MaterialApp(
      theme: buildHaloTheme(Brightness.light),
      home: Scaffold(body: NodesPage(controller: controller)),
    );

    testWidgets('node rows scroll vertically with a touch drag', (tester) async {
      controller.saveImport(
        importNodes(
          List.generate(40, (i) => 'trojan://pw@node$i.example.com:443#Node$i')
              .join('\n'),
        ),
      );
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final list = find.byType(ListView);
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, 0);

      await tester.drag(list, const Offset(0, -160));
      await tester.pumpAndSettle();

      expect(position.pixels, greaterThan(0));
    });

    /// The table only renders when there is at least one node, so the tests
    /// above exercise nothing but the empty state. This seeds nodes through the
    /// real import path and checks that rows, group chips and the status strip
    /// all appear.
    testWidgets('renders the table, group chips and status strip', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      controller.saveImport(
        importNodes(
          [
            'trojan://pw@hk.example.com:443#香港%2001',
            // A five-digit port: the column used to clip it to "844", which is
            // a silently wrong port rather than a visible truncation.
            'hysteria2://pw@jp.example.com:8443#日本%2001',
          ].join('\n'),
        ),
      );
      controller.subscriptionRepo.upsert(
        SubscriptionProfile(
          id: 'sub_1',
          name: '机场 A',
          url: 'https://example.com/sub',
          createdAtMs: 1,
        ),
      );

      await tester.pumpWidget(harness());
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);

      // Rows.
      expect(find.text('香港 01'), findsOneWidget);
      expect(find.text('日本 01'), findsOneWidget);
      // The full port is on screen, not a clipped prefix.
      expect(find.text('8443'), findsOneWidget);
      // Group filter, including the profile that owns no nodes yet. "本地" is
      // both a chip and the group cell of each local node, so this counts
      // widgets rather than asserting a unique label.
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('本地'), findsWidgets);
      expect(find.text('机场 A'), findsOneWidget);
      // Column headers are the reason this is a table and not a card list.
      expect(find.text('传输'), findsOneWidget);
      expect(find.text('TLS'), findsOneWidget);
      expect(find.text('延迟'), findsOneWidget);
      // The trailing "启用 / 当前" column is gone: enabling lives in the header
      // button, the context menu and Enter, and "current" is already the 3px bar
      // plus the 使用中 badge. A fourth copy of the same fact cost the table
      // 64px of width for nothing.
      expect(find.text('启用'), findsNothing);
      expect(find.text('当前'), findsNothing);
      // Bottom strip names the keys, so the shortcuts are discoverable.
      expect(find.textContaining('Enter 启用'), findsOneWidget);
    });

    testWidgets('every subscription source stays inside the filter strip', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      // One line of 9-11 chips is wider than a 1180px window. The strip used to
      // be a horizontal ListView, so the last sources sat past the right edge
      // and were unreachable: a plain wheel scrolls vertically, and Flutter's
      // desktop drag devices exclude the mouse. Wrapping is the only layout in
      // which every source is both painted and clickable.
      const names = [
        'api1.0443.org.uk',
        'clashgithub',
        'zrfme',
        'free-nodes/v2rayfree',
        'ovmvo/FreeSub',
        'snakem982/proxypool',
        '白嫖二号',
      ];
      controller.saveImport(
        importNodes('trojan://pw@hk.example.com:443#香港%2001'),
      );
      for (var i = 0; i < names.length; i++) {
        controller.subscriptionRepo.upsert(
          SubscriptionProfile(
            id: 'p$i',
            name: names[i],
            url: 'https://example.com/${names[i]}',
            createdAtMs: 1,
          ),
        );
      }

      await tester.pumpWidget(harness());
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);

      final stripRect = tester.getRect(
        find.byKey(const ValueKey('node-group-chips')),
      );
      for (final name in names) {
        final finder = find.text(name);
        expect(finder, findsOneWidget, reason: '订阅源「$name」应有筛选 chip');
        final rect = tester.getRect(finder);
        expect(
          rect.right,
          lessThanOrEqualTo(stripRect.right + 0.5),
          reason: '订阅源「$name」超出筛选条右边界，鼠标无法点到',
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(stripRect.bottom + 0.5),
          reason: '订阅源「$name」被折到筛选条可视区之外',
        );
      }
      // At most three rows: the cap is what keeps a long subscription list from
      // squeezing the node table off the page.
      expect(stripRect.height, lessThanOrEqualTo(90.0));
    });

    testWidgets('the latency filter is reachable from the toolbar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.saveImport(
        importNodes('trojan://pw@hk.example.com:443#香港%2001'),
      );
      await tester.pumpWidget(harness());
      await tester.pump(const Duration(milliseconds: 100));

      // It sits beside the protocol filter and defaults to "no filter", so a
      // user who never measures is not confronted with an empty list.
      expect(find.text('全部延迟'), findsOneWidget);
      await tester.tap(find.text('全部延迟'));
      await tester.pumpAndSettle();
      // Every bucket is offered by name; the thresholds appear in the labels so
      // "fast" cannot quietly mean something other than the green band.
      expect(find.text('可用的'), findsOneWidget);
      expect(find.text('快的（≤200 ms）'), findsOneWidget);
      expect(find.text('慢的（> 600 ms）'), findsOneWidget);
      expect(find.text('不可用的'), findsOneWidget);
      expect(find.text('未测过的'), findsOneWidget);
      expect(find.text('未确认可用的'), findsOneWidget);
    });

    testWidgets('choosing a latency filter hides the rows that do not match', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.saveImport(
        importNodes(
          [
            'trojan://pw@hk.example.com:443#香港%2001',
            'hysteria2://pw@jp.example.com:8443#日本%2001',
          ].join('\n'),
        ),
      );
      // One node answered, the other was never measured. The filter has to
      // separate them, otherwise "the ones that work" is not actionable.
      final nodes = controller.loadNodes();
      controller.speedResults[nodes.first.id] = SpeedResult(
        nodeId: nodes.first.id,
        metric: SpeedMetric.proxyLatency,
        status: SpeedStatus.ok,
        valueMs: 120,
      );

      await tester.pumpWidget(harness());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('香港 01'), findsOneWidget);
      expect(find.text('日本 01'), findsOneWidget);

      await tester.tap(find.text('全部延迟'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('未测过的').last);
      await tester.pumpAndSettle();

      // The measured node is hidden, the unmeasured one remains, and the state
      // does not mistake "未被测过" for "不可用".
      final measured = nodes.first.name;
      final other = nodes.last.name;
      expect(find.text(measured), findsNothing);
      expect(find.text(other), findsOneWidget);
      expect(find.text('未测过的'), findsOneWidget);
    });

    testWidgets('a node row still fits at 200% scaling on a small window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.saveImport(
        importNodes('trojan://pw@a-very-long-hostname.example.com:443#n'),
      );
      await tester.pumpWidget(harness());
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });

  group('a one-off upgrade repair is explained, not silent', () {
    late Directory tempDir;
    late AppController controller;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('halo_nodes_repair');
      controller = AppController(dataDir: tempDir.path);
    });

    tearDown(() async {
      await controller.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // WAL can hold the directory on Windows.
      }
    });

    test('nothing is announced when nothing was repaired', () async {
      // The overwhelmingly common case: no migration, no notice, no noise.
      await controller.start(connectHost: false);
      expect(controller.storeReady, isTrue);
      expect(controller.repairedNodeCount, 0);
    });

    test('the count is read at open and consumed on acknowledgement', () async {
      // Simulate a database that migration v5 already repaired: the meta entry
      // has to exist before the controller opens the store, which is exactly
      // the order that happens on a real upgrade launch.
      final dbPath = '${tempDir.path}${Platform.pathSeparator}clash-halo.db';
      final seed = HaloStore.open(dbPath);
      setMeta(seed.store!.db, SettingKeys.repairedNodes, '2');
      seed.store!.close();

      final fresh = AppController(dataDir: tempDir.path);
      addTearDown(fresh.dispose);
      await fresh.start(connectHost: false);
      expect(fresh.repairedNodeCount, 2, reason: '启动时应读到修复条数');

      fresh.acknowledgeRepairedNodes();
      expect(metaOf(fresh.store.db, SettingKeys.repairedNodes), isNull,
          reason: '确认后不该再提示第二次');
      expect(fresh.repairedNodeCount, 0);
    });
  });

  group('cleanup invalid nodes', () {
    late Directory tempDir;
    late AppController controller;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('halo_nodes_cleanup');
      controller = AppController(dataDir: tempDir.path);
      await controller.start(connectHost: false);
    });

    tearDown(() async {
      await controller.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // WAL can hold the directory on Windows.
      }
    });

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    List<String> importedIds() =>
        controller.loadNodes().map((n) => n.id).toList();

    testWidgets('removes only nodes with failure and no success', (
      tester,
    ) async {
      controller.saveImport(
        importNodes(
          'trojan://p1@a.example.com:443#a\n'
          'trojan://p2@b.example.com:443#b\n'
          'trojan://p3@c.example.com:443#c',
        ),
      );
      final byName = {
        for (final n in controller.loadNodes()) n.name: n.id,
      };
      controller.speedResults[byName['a']!] = SpeedResult(
        nodeId: byName['a']!,
        metric: SpeedMetric.proxyLatency,
        status: SpeedStatus.ok,
        valueMs: 120,
      );
      controller.speedResults[byName['b']!] = SpeedResult(
        nodeId: byName['b']!,
        metric: SpeedMetric.proxyLatency,
        status: SpeedStatus.failed,
      );
      // c was never tested: not evidence of invalidity.
      await pumpPage(tester);

      await tester.tap(find.text('清理无效'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('移除无效节点'), findsOneWidget);
      expect(find.textContaining('1 个节点'), findsOneWidget);

      await tester.tap(find.text('移除'));
      await tester.pump(const Duration(milliseconds: 300));
      final remaining = importedIds();
      expect(remaining, isNot(contains(byName['b'])));
      expect(remaining, containsAll(<String>[byName['a']!, byName['c']!]));
    });

    testWidgets('a failed node hidden by the filter is preserved', (
      tester,
    ) async {
      controller.saveImport(
        importNodes(
          'trojan://p1@a.example.com:443#a\n'
          'trojan://p2@b.example.com:443#b\n'
          'trojan://p3@c.example.com:443#c',
        ),
      );
      final byName = {
        for (final n in controller.loadNodes()) n.name: n.id,
      };
      for (final name in ['b', 'c']) {
        final id = byName[name]!;
        controller.speedResults[id] = SpeedResult(
          nodeId: id,
          metric: SpeedMetric.proxyLatency,
          status: SpeedStatus.failed,
        );
      }
      await pumpPage(tester);

      // Only b is in the current visible set; c is invalid but filtered out.
      await tester.enterText(find.byType(TextField), 'b');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('清理无效'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('1 个节点'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pump(const Duration(milliseconds: 300));

      final remaining = importedIds();
      expect(remaining, contains(byName['c']), reason: '被搜索过滤掉的无效应保留');
      expect(remaining, isNot(contains(byName['b'])));
    });

    testWidgets('nothing to clean leaves the action disabled', (tester) async {
      controller.saveImport(
        importNodes('trojan://p1@a.example.com:443#a'),
      );
      await pumpPage(tester);
      await tester.tap(find.text('清理无效'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('移除无效节点'), findsNothing);
      expect(controller.loadNodes(), hasLength(1));
    });
  });

  group('navigation', () {
    test('the node page is still a first-class destination', () {
      // It carries the speed test now, so it must not have been folded away.
      expect(HaloPage.values, contains(HaloPage.nodes));
      expect(HaloPage.nodes.label, '节点');
    });
  });

  group('speed results are typed', () {
    test('a download run defaults to serial and keeps the host timeout', () async {
      // The host gives a download 20 s and 10 MB because a slow-but-working
      // node is the one worth finding. Sending a fixed 8 s from the client
      // overrode that budget and made such a node fail for being slow, which
      // is the exact opposite of what a speed test is for.
      final tempDir = Directory.systemTemp.createTempSync('halo_budget');
      final client = _SilentClient();
      final controller = AppController(client: client, dataDir: tempDir.path);
      await controller.start(connectHost: false);
      try {
        controller.saveImport(
          importNodes('trojan://pw@hk.example.com:443#香港%2001'),
        );
        final node = controller.loadNodes().first;
        await controller.startSpeedTest(
          nodeIds: [node.id],
          metric: SpeedMetric.download,
        );
        final sent = client.startedParams.last;
        expect(sent['metric'], 'download');
        expect(sent['concurrency'], 1);
        // Absent, not 8000: the host's per-metric default is the budget.
        expect(
          sent.containsKey('timeoutMs'),
          isFalse,
          reason: '客户端不应覆盖宿主为下载测速准备的预算',
        );
      } finally {
        await controller.dispose();
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a latency run sends the stored concurrency, 8 when unset', () async {
      // The setting has three sources — caller, stored value, default — and the
      // default used to be 4 while the dropdown offered 1/2/4/8. The host then
      // clamped at 16, so the UI could never exceed 8 even though the pool
      // would have accepted 32. One default, one ceiling, both asserted here.
      final tempDir = Directory.systemTemp.createTempSync('halo_workers');
      final client = _SilentClient();
      final controller = AppController(client: client, dataDir: tempDir.path);
      await controller.start(connectHost: false);
      try {
        controller.saveImport(
          importNodes('trojan://pw@hk.example.com:443#香港%2001'),
        );
        final node = controller.loadNodes().first;
        await controller.startSpeedTest(nodeIds: [node.id]);
        expect(client.startedParams.last['concurrency'], 8);

        // A stored value wins over the default, and the ceiling still applies.
        controller.settingsRepo.setInt(
          SettingKeys.speedTestConcurrency,
          32,
        );
        await controller.startSpeedTest(nodeIds: [node.id]);
        expect(client.startedParams.last['concurrency'], 32);

        controller.settingsRepo.setInt(SettingKeys.speedTestConcurrency, 99);
        await controller.startSpeedTest(nodeIds: [node.id]);
        expect(
          client.startedParams.last['concurrency'],
          32,
          reason: '手改设置文件也不能超过宿主上限',
        );
      } finally {
        await controller.dispose();
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a failed result is distinguishable from an untested node', () {
      // The cell renders "—" for unknown and "不可用" for failed; the difference
      // lives in the status, so the model must carry it.
      const failed = SpeedResult(
        nodeId: 'n',
        metric: SpeedMetric.proxyLatency,
        status: SpeedStatus.failed,
        errorMessage: 'timeout',
      );
      const ok = SpeedResult(
        nodeId: 'n',
        metric: SpeedMetric.proxyLatency,
        status: SpeedStatus.ok,
        valueMs: 120,
      );
      expect(failed.status, isNot(ok.status));
      expect(ok.valueMs, 120);
    });

    test('a download reading does not erase the latency reading', () async {
      // Both measurements describe one node at the same time. When they shared
      // a single map the second one overwrote the first, so asking for speed
      // made the latency column blank and vice versa. This drives the real
      // event path so the routing — not the test — decides which collection a
      // result lands in.
      final tempDir = Directory.systemTemp.createTempSync('halo_metric_split');
      final controller = AppController(
        client: _SilentClient(),
        dataDir: tempDir.path,
      );
      await controller.start(connectHost: false);
      try {
        // `task.started` claims the id; without it both progress events are
        // treated as stragglers from another batch and dropped.
        controller.applyEventForTest(
          const HaloEventMessage(
            name: HaloEvent.taskStarted,
            data: {'taskId': 'batch-metric', 'count': 1},
          ),
        );
        // A latency result, then a throughput result for the same node.
        controller.applyEventForTest(
          const HaloEventMessage(
            name: HaloEvent.taskProgress,
            data: {
              'taskId': 'batch-metric',
              'nodeId': 'n1',
              'metric': 'proxy_latency',
              'ok': true,
              'latencyMs': 180,
            },
          ),
        );
        controller.applyEventForTest(
          const HaloEventMessage(
            name: HaloEvent.taskProgress,
            data: {
              'taskId': 'batch-metric',
              'nodeId': 'n1',
              'metric': 'download',
              'ok': true,
              'latencyMs': 90,
              'downloadBps': 4194304,
            },
          ),
        );

        expect(controller.speedResults['n1']?.valueMs, 180);
        expect(
          controller.downloadResults['n1']?.bytesPerSecond,
          4194304,
        );
        // A throughput reading must not claim a delay: 90 ms was its connect
        // time, not a latency the latency column may show.
        expect(controller.downloadResults['n1']?.valueMs, isNull);
      } finally {
        await controller.dispose();
        tempDir.deleteSync(recursive: true);
      }
    });

    test('tcp and udp readings land in the reachability slot, not the latency one',
        () async {
      // A handshake and a datagram round trip are reachability, not latency.
      // Storing them in speedResults would have put a 4 ms connect next to a
      // 180 ms proxy round trip in the same cell and invited the reader to
      // compare two different quantities.
      final tempDir = Directory.systemTemp.createTempSync('halo_reachability');
      final controller = AppController(
        client: _SilentClient(),
        dataDir: tempDir.path,
      );
      await controller.start(connectHost: false);
      try {
        controller.applyEventForTest(
          const HaloEventMessage(
            name: HaloEvent.taskStarted,
            data: {'taskId': 'batch-reach', 'count': 1},
          ),
        );
        for (final payload in [
          {'nodeId': 'n1', 'metric': 'tcp', 'ok': true, 'latencyMs': 4},
          {'nodeId': 'n1', 'metric': 'udp', 'ok': true, 'latencyMs': 41},
          // A QUIC-only node: the TCP check does not apply to it, and that must
          // not be stored as a failure. A different node, because one batch
          // yields one reading per node and transport.
          {
            'nodeId': 'n2',
            'metric': 'tcp',
            'ok': false,
            'errorCode': 'not_applicable',
          },
        ]) {
          controller.applyEventForTest(
            HaloEventMessage(
              name: HaloEvent.taskProgress,
              data: {'taskId': 'batch-reach', ...payload},
            ),
          );
        }

        expect(controller.reachabilityOf('n1', SpeedMetric.tcp)?.valueMs, 4);
        expect(controller.reachabilityOf('n1', SpeedMetric.udp)?.valueMs, 41);
        // The latency column must stay empty: nothing here measured a proxy
        // round trip.
        expect(controller.speedResults.containsKey('n1'), isFalse);
        // 不适用 is its own status, not failed.
        expect(
          controller.reachabilityOf('n2', SpeedMetric.tcp)?.status,
          SpeedStatus.notApplicable,
        );
        expect(
          controller.reachabilityOf('n2', SpeedMetric.tcp)?.status,
          isNot(SpeedStatus.failed),
        );
      } finally {
        await controller.dispose();
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('the reachability cell says what it means', () {
    // The cell first printed 「T ✓」 / 「U ✗」: a letter standing for the
    // transport, coloured by outcome. Two problems at once — the letters need
    // a legend, and red/green already mean slow/fast one column to the left,
    // so the colour carried a second, contradictory meaning.

    Future<void> renderCell(
      WidgetTester tester,
      Map<SpeedMetric, SpeedResult> readings,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: buildReachabilityCellForTest(readings: readings),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('success and failure are spelled out, not lettered', (
      tester,
    ) async {
      await renderCell(tester, {
        SpeedMetric.tcp: const SpeedResult(
          nodeId: 'n',
          metric: SpeedMetric.tcp,
          status: SpeedStatus.ok,
        ),
        SpeedMetric.udp: const SpeedResult(
          nodeId: 'n',
          metric: SpeedMetric.udp,
          status: SpeedStatus.failed,
        ),
      });
      // Words, with the transport named in full.
      expect(find.text('TCP 通'), findsOneWidget);
      expect(find.text('UDP 不通'), findsOneWidget);
      // No bare letters left standing in for a transport.
      expect(find.text('T'), findsNothing);
      expect(find.text('U'), findsNothing);
    });

    testWidgets('a reachable port also reports how long the handshake took', (
      tester,
    ) async {
      // "TCP 通" alone cannot separate a node answering in 8 ms from one taking
      // three seconds, which is the difference a user acts on. The number is a
      // port connect time, not a proxy round trip, so it is shown next to the
      // verdict rather than in the latency column.
      await renderCell(tester, {
        SpeedMetric.tcp: const SpeedResult(
          nodeId: 'n',
          metric: SpeedMetric.tcp,
          status: SpeedStatus.ok,
          valueMs: 12,
        ),
      });
      expect(find.text('TCP 通 12ms'), findsOneWidget);
    });

    testWidgets('a failed or unconfirmed check stays wordless', (
      tester,
    ) async {
      // There is no number to show for these, and inventing "0ms" would read
      // as instant rather than as no answer at all.
      await renderCell(tester, {
        SpeedMetric.tcp: const SpeedResult(
          nodeId: 'n',
          metric: SpeedMetric.tcp,
          status: SpeedStatus.failed,
        ),
        SpeedMetric.udp: const SpeedResult(
          nodeId: 'n',
          metric: SpeedMetric.udp,
          status: SpeedStatus.notApplicable,
          errorCode: 'udp_unconfirmed',
        ),
      });
      expect(find.text('TCP 不通'), findsOneWidget);
      expect(find.text('UDP 未确认'), findsOneWidget);
      expect(find.textContaining('ms'), findsNothing);
    });

    testWidgets('a check that does not apply is never coloured as a fault', (
      tester,
    ) async {
      await renderCell(tester, {
        SpeedMetric.tcp: const SpeedResult(
          nodeId: 'n',
          metric: SpeedMetric.tcp,
          status: SpeedStatus.notApplicable,
        ),
      });
      expect(find.text('TCP 不适用'), findsOneWidget);
      // 不适用 must not be written as a failure word: a QUIC-only node has no
      // TCP listener and is not broken.
      expect(find.textContaining('不通'), findsNothing);
    });

    testWidgets('UDP silence reads as unconfirmed, never as unreachable', (
      tester,
    ) async {      // A filtered UDP port and a dead node look identical from outside, so
      // silence cannot become 「不通」 — that would be a confident claim about
      // a node nobody managed to test.
      await renderCell(tester, {
        SpeedMetric.udp: const SpeedResult(
          nodeId: 'n',
          metric: SpeedMetric.udp,
          status: SpeedStatus.notApplicable,
          errorCode: 'udp_unconfirmed',
        ),
      });
      expect(find.text('UDP 未确认'), findsOneWidget);
      expect(find.text('UDP 不适用'), findsNothing);
      expect(find.textContaining('不通'), findsNothing);
    });
  });

  group('a lost event stream cannot pin the table', () {
    // The original bug: the client was subscribed off, so `task.finished` never
    // arrived and every row stayed on "测试中" forever. A polling fallback is the
    // independent source of truth that ends the batch, so this drives the real
    // batch path with a client that never emits a single event.

    late Directory tempDir;
    late _SilentClient client;
    late AppController controller;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('halo_nodes_watchdog');
      client = _SilentClient();
      controller = AppController(client: client, dataDir: tempDir.path);
      await controller.start(connectHost: false);
    });

    tearDown(() async {
      await controller.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // WAL can hold the directory on Windows; the temp tree is disposable.
      }
    });

    testWidgets('the batch ends even when no event ever arrives', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      // The button is gated on `connected`, which normally comes from the pipe.
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(
        importNodes('trojan://pw@hk.example.com:443#香港%2001'),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('测延迟（全部）'));
      await tester.pump(const Duration(milliseconds: 200));
      // The batch is now in flight: the stop button and the strip are the two
      // ways "测试中" is observable.
      expect(find.text('停止测速'), findsOneWidget);
      expect(find.textContaining('正在测速'), findsOneWidget);
      expect(client.startedTasks, isNotEmpty, reason: '测速必须真的发起');
      // Latency and throughput are separate measurements; this button must
      // never ask the host to download bytes.
      expect(
        client.startedMetrics,
        everyElement(isNot('download')),
        reason: '延迟测试不能变成下载测速',
      );

      // The client emits nothing at all — no task.progress, no task.finished,
      // no state.changed. Only the watchdog poll can end the batch. Two ticks
      // are needed: the first (2 s) clears the fake host's running flag, the
      // second (4 s) observes it cleared — the controller no longer spends an
      // extra snapshot.get after every command, so the flag is cleared one
      // tick later than it used to be.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('停止测速'), findsNothing, reason: '批次必须自行结束');
      expect(find.textContaining('正在测速'), findsNothing);
      // Back to the idle toolbar, and the row is not left spinning.
      expect(find.text('测延迟（全部）'), findsOneWidget);
      expect(find.text('测试中'), findsNothing);
      expect(tester.takeException(), isNull);

      // The poll must stop once the batch is over: a timer left running would
      // keep hammering the host for as long as the page is open.
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching pages keeps the in-flight progress', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      client.holdBatch = true;
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 0, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(
        importNodes('trojan://pw@hk.example.com:443#香港%2001'),
      );

      Widget page() => MaterialApp(
            theme: buildHaloTheme(Brightness.light),
            home: Scaffold(body: NodesPage(controller: controller)),
          );

      await tester.pumpWidget(page());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('测延迟（全部）'));
      await tester.pump(const Duration(milliseconds: 200));
      // The fake host now reports the batch as running.
      await controller.refreshSnapshot();
      await tester.pump();
      expect(find.textContaining('正在测速'), findsOneWidget);

      // Leave the node page; the host keeps probing.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('elsewhere'))),
      );
      await tester.pump();

      // Return: the strip and the per-row marker must describe the live batch,
      // not reset to an idle table.
      await tester.pumpWidget(page());
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.textContaining('正在测速'),
        findsOneWidget,
        reason: '切换页面后测速进度必须仍在',
      );
      expect(find.text('停止测速'), findsOneWidget);
      expect(find.text('测试中'), findsWidgets);

      // Stop the batch and dispose the page so no watchdog timer survives.
      await tester.tap(find.text('停止测速'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a subset run counts the batch, not the whole table', (
      tester,
    ) async {
      // The strip used to divide by the catalog and subtract from the
      // visible rows: with three nodes on screen and one selected it read
      // "2/3" before any probe had answered, and fell back to "0/3" once
      // the only result landed. The denominator has to be the batch this
      // run actually started, not the table around it.
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(importNodes('trojan://pw@a.example.com:443#甲'));
      controller.saveImport(importNodes('trojan://pw@b.example.com:443#乙'));
      controller.saveImport(importNodes('trojan://pw@c.example.com:443#丙'));

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // A plain click selects; the double click that opens details is
      // recognised separately, so the selection no longer waits for it.
      await tester.tap(find.text('甲'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('已选 1'), findsWidgets);

      await tester.tap(find.text('测延迟'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.text('正在测速 · 0/1 · Esc 停止'),
        findsOneWidget,
        reason: '一次只测一个节点时，分母必须是一次运行，而不是整张表',
      );

      // One result consumed must reach 1/1 rather than wrap back to 0/1.
      final taskId = client.startedTasks.last;
      final testedId = controller
          .loadNodes()
          .firstWhere((n) => n.name == '甲')
          .id;
      controller.applyEventForTest(
        HaloEventMessage(name: HaloEvent.taskStarted, data: {'taskId': taskId}),
      );
      controller.applyEventForTest(
        HaloEventMessage(
          name: HaloEvent.taskProgress,
          data: {
            'taskId': taskId,
            'results': [
              {
                'nodeId': testedId,
                'metric': SpeedMetric.proxyLatency.wire,
                'ok': true,
                'latencyMs': 120,
              },
            ],
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('正在测速 · 1/1 · Esc 停止'), findsOneWidget);

      // The watchdog still owns the end of a silent batch, so the corrected
      // counter must not pin the strip.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('正在测速'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the in-progress marker sits in the speed column, not latency', (
      tester,
    ) async {
      // A running batch may be a latency run or a download run. Marking the
      // latency cell claimed a specific measurement was in flight even when the
      // user had asked for throughput, so the marker moved to 速度, which is
      // where "a measurement is happening" reads as true for either run.
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(
        importNodes('trojan://pw@hk.example.com:443#香港%2001'),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('测延迟（全部）'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('测试中'), findsOneWidget);
      // Its x must fall under the 速度 header, not under 延迟.
      final marker = tester.getCenter(find.text('测试中')).dx;
      final speedHeader = tester.getCenter(find.text('速度')).dx;
      final latencyHeader = tester.getCenter(find.text('延迟')).dx;
      expect((marker - speedHeader).abs(), lessThan(40),
          reason: '测试中应出现在速度列下方');
      expect((marker - latencyHeader).abs(), greaterThan(40),
          reason: '测试中不应再占用延迟列');

      // Let the batch end so the watchdog timer is not left pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });

    testWidgets('UDP waits for TCP completion beyond 30 seconds', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(
        importNodes(
          'trojan://pw@tcp.example.com:443#TCP\n'
          'hysteria2://pw@udp.example.com:443#UDP',
        ),
      );
      client.holdBatch = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('连通性（全部）'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(client.startedMetrics, ['tcp']);
      client.holdBatch = false;
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 2, coreState: CoreState.stopped),
        connected: true,
      );
      await tester.pump();
      expect(client.startedMetrics, ['tcp', 'udp']);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the reachability button asks for a handshake, not a proxy probe', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(
        importNodes('trojan://pw@hk.example.com:443#香港%2001'),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('连通性（全部）'));
      await tester.pump(const Duration(milliseconds: 300));

      // Reachability is the cheap pre-check: it must ask the host for a TCP
      // handshake. Asking for proxy_latency would start a core per node and
      // make the "fast" check as slow as the thing it was meant to precede.
      expect(client.startedMetrics, contains('tcp'));
      expect(
        client.startedMetrics,
        everyElement(isNot('download')),
        reason: '连通性检查不能下载数据',
      );
      expect(
        client.startedMetrics,
        everyElement(isNot('proxy_latency')),
        reason: '连通性检查在起内核之前就该有答案',
      );

      // Let the batch finish so the watchdog timer is not left pending when
      // the tree is disposed; a live timer fails the test harness.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });
  });

  group('node details dialog', () {
    late Directory tempDir;
    late _SilentClient client;
    late AppController controller;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('halo_nodes_details');
      client = _SilentClient();
      controller = AppController(client: client, dataDir: tempDir.path);
      await controller.start(connectHost: false);
    });

    tearDown(() async {
      await controller.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // WAL can hold the directory on Windows; the temp tree is disposable.
      }
    });

    /// Dialog-scoped finder: the table behind it shares several labels
    /// (名称, TLS…) with the rows inside the dialog.
    Finder inDialog(Finder child) =>
        find.descendant(of: find.byType(AlertDialog), matching: child);

    testWidgets('shows every configured item of the node', (tester) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      // Inserted through the repository directly so this test pins the
      // dialog's completeness, not the importer's field mapping.
      NodeRepository(controller.store).insert(
        withIdentity(const ProxyNode(
          id: '',
          fingerprint: '',
          name: '香港 VMess',
          protocol: ProxyProtocol.vmess,
          server: 'hk.example.com',
          port: 443,
          secrets: NodeSecrets(
            uuid: 'b8ddf3e2-4f6e-4c3f-9d2a-7b1c2d3e4f5a',
            security: 'auto',
            alterId: 0,
          ),
          transport: TransportConfig(
            kind: TransportKind.ws,
            host: 'cdn.example.com',
            path: '/ws',
            headers: {'Host': 'cdn.example.com'},
            earlyData: 2048,
          ),
          tls: TlsConfig(
            kind: TlsKind.tls,
            serverName: 'sni.example.com',
            alpn: ['h2', 'http/1.1'],
            fingerprint: 'chrome',
          ),
        )),
        nowMs: 1,
      );
      controller.notifyExternalChange();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      await tester.tap(find.text('香港 VMess').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      // Credentials, transport and TLS: the fields the old dialog omitted.
      expect(inDialog(find.text('UUID')), findsOneWidget);
      expect(inDialog(find.text('加密')), findsOneWidget,
          reason: 'vmess security 是一个配置项');
      expect(inDialog(find.text('auto')), findsOneWidget);
      expect(inDialog(find.text('alterId')), findsOneWidget);
      expect(inDialog(find.text('Host')), findsOneWidget);
      expect(inDialog(find.text('路径')), findsOneWidget);
      expect(inDialog(find.text('/ws')), findsOneWidget);
      expect(inDialog(find.text('Header · Host')), findsOneWidget);
      expect(inDialog(find.text('早期数据')), findsOneWidget);
      expect(inDialog(find.text('2048 字节')), findsOneWidget);
      expect(inDialog(find.text('SNI')), findsOneWidget);
      expect(inDialog(find.text('ALPN')), findsOneWidget);
      expect(inDialog(find.text('h2, http/1.1')), findsOneWidget);
      expect(inDialog(find.text('uTLS 指纹')), findsOneWidget);
      expect(inDialog(find.text('chrome')), findsOneWidget);
      expect(inDialog(find.text('来源')), findsOneWidget);

      // Secrets are masked until asked for, and the toggle is reversible.
      expect(inDialog(find.text('••••••••')), findsOneWidget);
      expect(inDialog(find.textContaining('b8ddf3e2')), findsNothing);
      // The rows overflow the dialog on this viewport; the toggle sits below
      // the fold and must be scrolled into view before it can be tapped.
      await tester.ensureVisible(inDialog(find.text('显示凭据')));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('显示凭据')));
      await tester.pumpAndSettle();
      expect(inDialog(find.textContaining('b8ddf3e2')), findsOneWidget);
      await tester.ensureVisible(inDialog(find.text('隐藏凭据')));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('隐藏凭据')));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('••••••••')), findsOneWidget);
      expect(inDialog(find.textContaining('b8ddf3e2')), findsNothing);
    });

    testWidgets('a plain node shows no credentials rows and no toggle',
        (tester) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      NodeRepository(controller.store).insert(
        withIdentity(const ProxyNode(
          id: '',
          fingerprint: '',
          name: '裸 SOCKS',
          protocol: ProxyProtocol.socks,
          server: 'plain.example.com',
          port: 1080,
        )),
        nowMs: 1,
      );
      controller.notifyExternalChange();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      await tester.tap(find.text('裸 SOCKS').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(inDialog(find.text('UUID')), findsNothing);
      expect(inDialog(find.text('密码')), findsNothing);
      expect(inDialog(find.text('加密方式')), findsNothing);
      expect(inDialog(find.text('显示凭据')), findsNothing);
      // The protocol-free defaults still answer: transport and TLS state.
      expect(inDialog(find.text('TCP')), findsOneWidget);
      expect(inDialog(find.text('无')), findsOneWidget);
    });

    testWidgets('shows the preserved importer fields and the full CA', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      const pem = '-----BEGIN CERTIFICATE-----\n'
          'MIIBszCCAVmgAwIBAgIUY2xhc2gtaGFsbw==\n'
          '-----END CERTIFICATE-----';
      NodeRepository(controller.store).insert(
        withIdentity(const ProxyNode(
          id: '',
          fingerprint: '',
          name: '香港 Hysteria2',
          protocol: ProxyProtocol.hysteria2,
          server: 'hy2.example.com',
          port: 443,
          secrets: NodeSecrets(password: 'hy2-pass'),
          tls: TlsConfig(
            kind: TlsKind.tls,
            serverName: 'hy2.example.com',
            certificatePem: pem,
          ),
          // Parameters the model has no column for: the importer keeps them
          // in extras, and obfs really does reach the generated config.
          extras: {
            'obfs': 'salamander',
            'obfsPassword': 'obfs-secret',
            'upMbps': '30',
            'downMbps': '200',
            'v2rayn': {'naiveQuic': true},
          },
        )),
        nowMs: 1,
      );
      controller.notifyExternalChange();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      await tester.tap(find.text('香港 Hysteria2').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(inDialog(find.textContaining('额外配置')), findsOneWidget);
      expect(
        inDialog(find.textContaining('"obfs": "salamander"')),
        findsOneWidget,
        reason: 'Hysteria2 混淆是被生成器消费的配置，不是来源元数据',
      );
      expect(
        inDialog(find.textContaining('"upMbps": "30"')),
        findsOneWidget,
      );
      expect(
        inDialog(find.textContaining('"naiveQuic": true')),
        findsOneWidget,
        reason: '嵌套的导入字段也要展开显示',
      );

      // Credentials inside extras follow the same toggle as UUID/password.
      expect(
        inDialog(find.textContaining('"obfsPassword": "••••••••"')),
        findsOneWidget,
      );
      expect(inDialog(find.textContaining('obfs-secret')), findsNothing);

      // The pinned CA used to be summarized as a character count only.
      expect(inDialog(find.text('已内置（${pem.length} 字符）')), findsOneWidget);
      expect(
        inDialog(find.textContaining('MIIBszCCAVmgAwIBAgIUY2xhc2gtaGFsbw==')),
        findsOneWidget,
      );

      await tester.ensureVisible(inDialog(find.text('显示凭据')));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('显示凭据')));
      await tester.pumpAndSettle();
      expect(
        inDialog(find.textContaining('"obfsPassword": "obfs-secret"')),
        findsOneWidget,
      );
    });

    testWidgets('the group field is the same dropdown as the rest of the app', (
      tester,
    ) async {
      // It was a bare DropdownButtonFormField: that widget ignores the theme's
      // fill, border and radius, draws a 48px list, and floats its label onto
      // the border. Next to the app's own 32px HaloDropdown it read as a
      // control from a different program — which is the report this pins.
      tester.view.physicalSize = const Size(2360, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      NodeRepository(controller.store).insert(
        withIdentity(const ProxyNode(
          id: '',
          fingerprint: '',
          name: '分组测试',
          protocol: ProxyProtocol.socks,
          server: 'g.example.com',
          port: 1080,
        )),
        nowMs: 1,
      );
      controller.notifyExternalChange();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      await tester.tap(find.text('分组测试').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(
        inDialog(find.byType(DropdownButtonFormField<String?>)),
        findsNothing,
        reason: '节点详情里的分组下拉已改为 HaloDropdown，不应再出现 Material 的表单下拉',
      );
      final group = find.byKey(const ValueKey('node-detail-group'));
      expect(inDialog(group), findsOneWidget);
      // One control tall, like every other dropdown and field.
      expect(
        tester.getSize(group).height,
        closeTo(HaloMetrics.controlHeight, 0.5),
        reason: '分组下拉必须与全站控件同高 32',
      );
    });
  });
}
