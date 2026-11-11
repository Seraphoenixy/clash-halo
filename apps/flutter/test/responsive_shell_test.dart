import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/app.dart';
import 'package:halo/src/ui/shell.dart';

void main() {
  testWidgets('collapsed rail keeps icons and an expand target', (
    tester,
  ) async {
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: Scaffold(
          body: HaloSidebar(
            current: HaloPage.overview,
            onSelect: (_) {},
            connected: true,
            coreRunning: true,
            collapsed: true,
            compact: true,
            onToggle: () => expanded = true,
          ),
        ),
      ),
    );

    expect(find.text('总览'), findsNothing);
    expect(find.byIcon(Icons.dashboard_outlined), findsOneWidget);
    await tester.tap(find.byType(InkWell).first);
    expect(expanded, isTrue);
  });

  testWidgets('narrow page header exposes the drawer menu', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHaloTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: Scaffold(
            body: HaloPageMenu(
              onOpen: () => opened = true,
              child: HaloPageScaffold(
                title: '节点',
                subtitle: '正在使用「n1」',
                actions: [
                  FilledButton(onPressed: () {}, child: const Text('启用所选')),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('连通性（全部）'),
                  ),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('测延迟（全部）'),
                  ),
                ],
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.menu));
    expect(opened, isTrue);
  });
}
