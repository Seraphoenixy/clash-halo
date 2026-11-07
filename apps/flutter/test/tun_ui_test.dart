import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/theme.dart';
import 'package:halo/src/ui/tun_card.dart';
import 'package:halo/src/ui/widgets.dart';
import 'package:halo_contracts/halo_contracts.dart';

/// Offline tests for the TUN control.
///
/// They never touch a host: enabling TUN for real raises a Windows UAC prompt,
/// so every case here is driven by a hand-built snapshot exactly like the one
/// the host publishes.
void main() {
  RuntimeSnapshot snap({
    TunState state = TunState.disabled,
    bool supported = true,
    String? message,
    String? adapter,
  }) => RuntimeSnapshot(
    stateVersion: 1,
    coreState: CoreState.stopped,
    tunState: state,
    tunSupported: supported,
    tunMessage: message,
    tunAdapter: adapter,
  );

  Widget harness(Widget child) => MaterialApp(
    theme: buildHaloTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  group('tunStateLabel', () {
    test('pending reads as waiting for authorisation, not as starting', () {
      final label = tunStateLabel(TunState.pending);
      expect(label, contains('授权'));
      expect(label, isNot('启动中'));
    });

    test('unverified is labelled as a legacy snapshot, never as unverified TUN',
        () {
      final label = tunStateLabel(TunState.unverified);
      expect(label, isNot('未验证'));
      expect(label, contains('旧版'));
    });

    test('failed and enabled keep distinct labels and colours', () {
      expect(tunStateLabel(TunState.failed), '失败');
      expect(tunStateColor(TunState.failed), HaloColors.danger);
      expect(tunStateColor(TunState.enabled), HaloColors.success);
      expect(tunStateColor(TunState.pending), HaloColors.warning);
    });
  });

  group('tunCanToggle', () {
    test('is false when the host reports no service', () {
      expect(
        tunCanToggle(
          snap(supported: false, state: TunState.unsupported),
          connected: true,
          pending: false,
        ),
        isFalse,
      );
    });

    test('is false while a request is in flight and when disconnected', () {
      expect(
        tunCanToggle(snap(), connected: true, pending: true),
        isFalse,
      );
      expect(
        tunCanToggle(snap(), connected: false, pending: false),
        isFalse,
      );
      expect(
        tunCanToggle(
          snap(state: TunState.pending),
          connected: true,
          pending: false,
        ),
        isFalse,
      );
    });

    test('is true only for a connected, supported, idle host', () {
      expect(
        tunCanToggle(snap(), connected: true, pending: false),
        isTrue,
      );
      // A previous failure is retryable.
      expect(
        tunCanToggle(
          snap(state: TunState.failed),
          connected: true,
          pending: false,
        ),
        isTrue,
      );
    });
  });

  group('tunHintText', () {
    test('surfaces the host message on failure', () {
      expect(
        tunHintText(
          snap(
            state: TunState.failed,
            message: 'configure tun interface: Access is denied.',
          ),
          pending: false,
        ),
        'configure tun interface: Access is denied.',
      );
    });

    test('surfaces the missing binary when unsupported', () {
      expect(
        tunHintText(
          snap(
            state: TunState.unsupported,
            supported: false,
            message: '找不到 TUN 服务程序 halo-tun-service.exe',
          ),
          pending: false,
        ),
        contains('halo-tun-service.exe'),
      );
    });

    test('explains the UAC wait while pending', () {
      for (final hint in [
        tunHintText(snap(state: TunState.pending), pending: false),
        tunHintText(snap(), pending: true),
      ]) {
        expect(hint, contains('管理员授权'));
        expect(hint, contains('90'));
      }
    });

    test('mentions the authorisation prompt before enabling', () {
      expect(tunHintText(snap(), pending: false), contains('管理员授权'));
    });
  });

  group('tunErrorText', () {
    test('a declined UAC prompt is a normal outcome, not a crash', () {
      const error = HaloError(
        HaloErrorCode.elevationDenied,
        '管理员授权被取消',
        'TUN 未启用；系统代理模式不受影响',
      );
      final text = tunErrorText(error);
      expect(text, contains('已取消管理员授权'));
      expect(text, contains('系统代理'));
      expect(tunErrorColor(error.code), HaloColors.warning);
    });

    test('tun_unavailable shows the host detail, the only actionable text', () {
      const error = HaloError(
        HaloErrorCode.tunUnavailable,
        'TUN 模式当前不可用',
        'configure tun interface: Access is denied.',
      );
      expect(tunErrorText(error), contains('Access is denied.'));
      expect(tunErrorColor(error.code), HaloColors.danger);
    });

    test('config_invalid and internal keep their detail', () {
      expect(
        tunErrorText(
          const HaloError(
            HaloErrorCode.configInvalid,
            '没有可用的配置',
            '请先应用节点或订阅，再启用 TUN',
          ),
        ),
        contains('请先应用节点或订阅'),
      );
      expect(
        tunErrorText(
          const HaloError(HaloErrorCode.internal, '内部错误', 'boom'),
        ),
        contains('boom'),
      );
    });
  });

  group('TunCard rendering', () {
    testWidgets('the switch is disabled and the reason shown when unsupported',
        (tester) async {
      await tester.pumpWidget(
        harness(
          TunCard(
            snapshot: snap(
              state: TunState.unsupported,
              supported: false,
              message: '找不到 TUN 服务程序 halo-tun-service.exe',
            ),
            connected: true,
            onToggle: (_) => fail('unsupported TUN must not toggle'),
          ),
        ),
      );

      final tile = tester.widget<HaloSwitchTile>(find.byType(HaloSwitchTile));
      expect(tile.onChanged, isNull);
      expect(find.text('找不到 TUN 服务程序 halo-tun-service.exe'), findsOneWidget);
      expect(find.text('不支持'), findsOneWidget);
    });

    testWidgets('pending shows the waiting label, a spinner and no toggle',
        (tester) async {
      await tester.pumpWidget(
        harness(
          TunCard(
            snapshot: snap(state: TunState.pending, message: '等待管理员授权'),
            connected: true,
            onToggle: (_) => fail('a pending TUN must not toggle again'),
          ),
        ),
      );

      expect(find.text('等待管理员授权'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final tile = tester.widget<HaloSwitchTile>(find.byType(HaloSwitchTile));
      expect(tile.onChanged, isNull);
    });

    testWidgets('a local in-flight toggle is locked too', (tester) async {
      await tester.pumpWidget(
        harness(
          TunCard(
            snapshot: snap(),
            connected: true,
            pending: true,
            onToggle: (_) => fail('a second toggle must not start'),
          ),
        ),
      );

      final tile = tester.widget<HaloSwitchTile>(find.byType(HaloSwitchTile));
      expect(tile.onChanged, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('90'), findsWidgets);
    });

    testWidgets('a failure renders tunMessage without opening a log page',
        (tester) async {
      await tester.pumpWidget(
        harness(
          TunCard(
            snapshot: snap(
              state: TunState.failed,
              message: 'configure tun interface: Access is denied.',
            ),
            connected: true,
            onToggle: (_) {},
          ),
        ),
      );

      expect(
        find.text('configure tun interface: Access is denied.'),
        findsOneWidget,
      );
      expect(find.text('失败'), findsOneWidget);
    });

    testWidgets('the last toggle outcome is rendered next to the control',
        (tester) async {
      await tester.pumpWidget(
        harness(
          TunCard(
            snapshot: snap(state: TunState.failed),
            connected: true,
            notice: '已取消管理员授权，TUN 未启用；系统代理模式不受影响。',
            noticeColor: HaloColors.warning,
            onToggle: (_) {},
          ),
        ),
      );

      expect(find.textContaining('已取消管理员授权'), findsOneWidget);
      expect(find.textContaining('系统代理'), findsOneWidget);
    });

    testWidgets('a supported idle host offers the switch', (tester) async {
      var toggled = false;
      await tester.pumpWidget(
        harness(
          TunCard(
            snapshot: snap(),
            connected: true,
            onToggle: (value) => toggled = value,
          ),
        ),
      );

      await tester.tap(find.byType(HaloSwitchTile));
      await tester.pump();
      expect(toggled, isTrue);
      expect(find.textContaining('管理员授权'), findsWidgets);
    });
  });
}
