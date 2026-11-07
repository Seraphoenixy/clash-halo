import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/nodes_page.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// Records what the page asks the host to measure.
class _RecordingClient extends HaloClient {
  _RecordingClient() : super(pipeName: 'never-connected');

  final List<String> metrics = [];

  @override
  bool get isConnected => true;

  @override
  Future<HaloResponse> send(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (action == HaloAction.speedTestStart) {
      metrics.add('${params['metric']}');
      return HaloResponse.success(
        'fake',
        result: {'taskId': '${params['taskId']}', 'accepted': true},
      );
    }
    if (action == HaloAction.snapshotGet) {
      return HaloResponse.success(
        'fake',
        result: {'speedTestRunning': true, 'stateVersion': 1},
      );
    }
    return HaloResponse.success('fake', result: const {});
  }

  @override
  Future<HaloResponse> sendRead(
    String action, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) => send(action, params: params, timeout: timeout);
}

/// The node table's keyboard and pointer behaviour.
///
/// Every case here was broken at once when `_NodeRow` and the surrounding
/// `Focus` were rebuilt: the shortcuts were still defined in `_onKey`, but
/// nothing ever gave that Focus node the keyboard, and the row's tap handlers
/// were dropped entirely. The list looked fine and did nothing when clicked.
void main() {
  late Directory tempDir;
  late _RecordingClient client;
  late AppController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('halo_node_keys');
    client = _RecordingClient();
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

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2360, 1520);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    controller.applySnapshotForTest(
      const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
      connected: true,
    );
    controller.saveImport(
      importNodes(
        'trojan://pw@a.example.com:443#节点甲\n'
        'trojan://pw@b.example.com:443#节点乙\n'
        'trojan://pw@c.example.com:443#节点丙',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(body: NodesPage(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
  }

  /// Flushes the double-tap timer, so a later tap on the same row is read as a
  /// new click rather than the second half of a double click.
  Future<void> settleTap(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The status strip is where selection is visible; reading it is closer to
  /// what a user sees than poking at private state.
  String strip(WidgetTester tester) => find
      .textContaining(RegExp(r'已选'))
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .join(' | ');

  testWidgets('clicking a row selects it', (tester) async {
    await pumpPage(tester);
    expect(strip(tester), isEmpty, reason: '初始不应有选中');

    await tester.tap(find.text('节点乙').first);
    await settleTap(tester);
    expect(strip(tester), contains('已选 1'));
  });

  testWidgets('a click selects on the press, not 300 ms later', (tester) async {
    // The row recognises a double click, and a double-tap recognizer holds the
    // gesture arena open for kDoubleTapTimeout (300 ms) waiting for a second
    // tap. While the row selected through a sibling onTap, that hold withheld
    // the selection too, so every click landed a third of a second after the
    // button came up: the table read as unresponsive under the mouse.
    await pumpPage(tester);
    await tester.tap(find.text('节点乙').first);
    // One frame, no elapsed time: nothing may wait for the double-tap window.
    await tester.pump();
    expect(strip(tester), contains('已选 1'),
        reason: '按下鼠标左键就应当选中，不能等双击窗口关闭');

    // The double click must still be recognised after that instant selection.
    await settleTap(tester);
    await tester.tap(find.text('节点乙').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('节点乙').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('节点详情'), findsWidgets,
        reason: '按下即选中，不能让双击不再打开详情');
  });

  testWidgets('Shift-click extends the range on the press', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('节点乙').first);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('节点丙').first);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(strip(tester), contains('已选 2'),
        reason: 'Shift 多选也必须按下即生效，否则连点几行都像没反应');
    // Flush the double-tap countdown the press started.
    await settleTap(tester);
  });

  testWidgets('Shift-clicking extends the selection to a range', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('节点乙').first);
    await settleTap(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('节点丙').first);
    await settleTap(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(strip(tester), contains('已选 2'));
  });

  testWidgets('double-clicking a row opens its details', (tester) async {
    await pumpPage(tester);
    final row = find.text('节点甲').first;
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('节点详情'), findsWidgets);
  });

  testWidgets('Ctrl+A selects everything and again clears it', (tester) async {
    await pumpPage(tester);
    await ctrl(tester, LogicalKeyboardKey.keyA);
    expect(strip(tester), contains('已选 3'));
    await ctrl(tester, LogicalKeyboardKey.keyA);
    expect(strip(tester), isEmpty);
  });

  testWidgets('arrow keys move the selection by one row', (tester) async {
    await pumpPage(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 200));
    expect(strip(tester), contains('已选 1'));
  });

  testWidgets('Delete asks before deleting', (tester) async {
    await pumpPage(tester);
    // Deleting nothing is a no-op; select first so the dialog has a target.
    await ctrl(tester, LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('删除'), findsWidgets);
  });

  testWidgets('Ctrl+D opens details for the current selection', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('节点甲').first);
    await settleTap(tester);
    await ctrl(tester, LogicalKeyboardKey.keyD);
    expect(find.textContaining('节点详情'), findsWidgets);
  });

  testWidgets('Ctrl+C copies a share link', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('节点甲').first);
    await settleTap(tester);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = '${(call.arguments as Map)['text']}';
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await ctrl(tester, LogicalKeyboardKey.keyC);
    expect(copied, isNotNull, reason: 'Ctrl+C 应写入剪贴板');
    expect(copied, contains('trojan://'));
  });

  testWidgets('Ctrl+F puts the caret in the search field', (tester) async {
    await pumpPage(tester);
    await ctrl(tester, LogicalKeyboardKey.keyF);
    await tester.enterText(find.byType(TextField).first, '甲');
    await tester.pump(const Duration(milliseconds: 300));

    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, '甲');
    // 节点乙 must be filtered out; 「节点」 in the result set is the page title.
    expect(find.text('节点乙'), findsNothing);
    expect(find.text('节点甲'), findsWidgets);
  });

  testWidgets('F5 starts a latency run, never a download', (tester) async {
    await pumpPage(tester);
    client.metrics.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump(const Duration(milliseconds: 400));

    expect(client.metrics, isNotEmpty, reason: 'F5 应发起测速');
    expect(client.metrics, everyElement('proxy_latency'),
        reason: 'F5 是延迟测试，不能变成耗流量的下载测速');

    // Let the batch settle so the watchdog timer is not left pending.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('the shortcuts survive a round trip through the search box', (
    tester,
  ) async {
    // Focus is the thing that broke: using Ctrl+F once used to leave the
    // keyboard in the text field, after which every shortcut silently stopped
    // working until the page was reopened.
    await pumpPage(tester);
    await ctrl(tester, LogicalKeyboardKey.keyF);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump(const Duration(milliseconds: 200));

    // Clicking back into the table must hand the keyboard back.
    await tester.tap(find.text('节点甲').first);
    await settleTap(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));

    expect(strip(tester), contains('已选'),
        reason: '从搜索框回到表格后，快捷键必须仍然有效');
  });
}
