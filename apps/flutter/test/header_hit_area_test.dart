import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/state/app_controller.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/pages/connections_page.dart';
import 'package:halo/src/ui/pages/nodes_page.dart';
import 'package:halo/src/ui/widgets/table_columns.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// The header's sort target and the column's resize handle have to meet.
///
/// They used to be separated by the cell's 8 px gutter, which sat *outside* the
/// InkWell: clicking the last 8 px of a heading neither sorted nor resized. On
/// a ten-column table that was 80 px of a 34 px-tall band where the cursor
/// stayed an arrow and the click fell through, so "where does the heading end
/// and the divider begin" had no answer.
Finder headerInk(String label) => find
    .ancestor(of: find.text(label).first, matching: find.byType(InkWell))
    .first;

void main() {
  testWidgets('a cell box makes its whole width tappable', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 34,
              child: CellBox(
                width: 120,
                onTap: () => taps++,
                child: const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('标题'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 3 px inside the right edge: inside the old gutter, outside the InkWell,
    // so this used to land on nothing.
    final rect = tester.getRect(find.byType(CellBox));
    await tester.tapAt(Offset(rect.right - 3, rect.center.dy));
    expect(taps, 1);
  });

  testWidgets('the node header sorts up to the resize handle', (tester) async {
    tester.view.physicalSize = const Size(2360, 1520);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final tempDir = Directory.systemTemp.createTempSync('halo_header_hit');
    final controller = AppController(dataDir: tempDir.path);
    await controller.start(connectHost: false);
    try {
      controller.applySnapshotForTest(
        const RuntimeSnapshot(stateVersion: 1, coreState: CoreState.stopped),
        connected: true,
      );
      controller.saveImport(importNodes('trojan://pw@a.example.com:443#节点甲'));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaloTheme(Brightness.light),
          home: Scaffold(body: NodesPage(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final name = tester.getRect(headerInk('名称'));
      final type = tester.getRect(headerInk('类型'));
      expect(type.left - name.right, kResizerWidth, reason: '排序区与拖动条之间不应再留空隙');

      // 3 px left of the handle: still the heading, not the gutter.
      final boundary = type.left - kResizerWidth;
      await tester.tapAt(Offset(boundary - 3, name.center.dy));
      await tester.pump();
      expect(
        find.descendant(
          of: headerInk('名称'),
          matching: find.byIcon(Icons.arrow_downward),
        ),
        findsOneWidget,
        reason: '名称列默认升序，点击后应切换为降序',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('the connection header sorts up to the resize handle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = AppController(dataDir: 'unused');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: ConnectionsPage(
            controller: controller,
            load: () async => const ConnectionsSnapshot(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    final host = tester.getRect(headerInk('主机'));
    final process = tester.getRect(headerInk('进程'));
    expect(process.left - host.right, kResizerWidth, reason: '排序区与拖动条之间不应再留空隙');

    final boundary = process.left - kResizerWidth;
    await tester.tapAt(Offset(boundary - 3, host.center.dy));
    await tester.pump();
    expect(
      find.descendant(
        of: headerInk('主机'),
        matching: find.byIcon(Icons.arrow_downward),
      ),
      findsOneWidget,
      reason: '主机列此前未参与排序，点击后应出现降序箭头',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
