import 'dart:async';

import 'package:flutter/material.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../../ipc/android_vpn.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';
import '../app.dart';
import '../overview_shared.dart';
import '../shell.dart';
import '../widgets.dart';

/// Android 的总览页。
///
/// Windows 的总览页以宿主快照为数据源；Android 没有宿主，`snapshot` 恒为
/// null。这里改用 `:vpn` 进程的状态与本地节点表，只展示实际存在的状态：
/// VPN 是否连接、当前节点、分流模式与权限。
class AndroidOverviewPage extends StatefulWidget {
  const AndroidOverviewPage({
    super.key,
    required this.controller,
    this.onOpenPage,
    this.onRunStep,
  });

  final AppController controller;
  final ValueChanged<HaloPage>? onOpenPage;
  final Future<void> Function(NextStep step)? onRunStep;

  @override
  State<AndroidOverviewPage> createState() => _AndroidOverviewPageState();
}

class _AndroidOverviewPageState extends State<AndroidOverviewPage> {
  bool _busy = false;
  bool? _permission;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPermission());
  }

  Future<void> _refreshPermission() async {
    try {
      final granted = await const AndroidVpnClient().permissionGranted();
      if (mounted) setState(() => _permission = granted);
    } on Object {
      if (mounted) setState(() => _permission = null);
    }
  }

  Future<void> _refresh() async {
    await c.refreshAndroidVpnStatus();
    await _refreshPermission();
  }

  Future<void> _start() async {
    if (c.activeNodeId == null) {
      widget.onOpenPage?.call(HaloPage.nodes);
      return;
    }
    setState(() => _busy = true);
    try {
      await c.startCore();
      await _refreshPermission();
      if (mounted) showHaloToast(context, 'VPN 已连接');
    } catch (error) {
      if (mounted) showHaloToast(context, '启动失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await c.stopCore();
      if (mounted) showHaloToast(context, 'VPN 已断开');
    } catch (error) {
      if (mounted) showHaloToast(context, '断开失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMode(ProxyMode mode) async {
    setState(() => _busy = true);
    try {
      await c.setMode(mode);
    } catch (error) {
      if (mounted) showHaloToast(context, '切换模式失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final status = c.androidVpnStatus;
    final core = c.androidCoreState;
    final hasNode = c.activeNodeId != null;
    final showBanner = haloOverviewBannerVisible(c);

    final statusCard = SectionCard(
      title: 'VPN',
      trailing: StatusChip(
        label: c.androidVpnLabel,
        color: coreStateColor(core),
        icon: core == CoreState.running
            ? Icons.vpn_lock_outlined
            : Icons.vpn_lock,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            status?.message.isNotEmpty == true
                ? status!.message
                : '尚未读取到 VPN 服务状态。',
            style: text.bodyMedium?.copyWith(
              color: core == CoreState.failed
                  ? HaloColors.adapt(HaloColors.danger, p.isDark)
                  : p.textSecondary,
            ),
          ),
          if (!hasNode) ...[
            const SizedBox(height: 8),
            Text('还没有启用的节点。先在「节点」页启用一个节点，再启动 VPN。', style: text.bodySmall),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (c.androidVpnActive)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _stop,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  icon: const Icon(Icons.power_settings_new, size: 16),
                  label: const Text('断开'),
                )
              else
                FilledButton.icon(
                  onPressed: _busy || !hasNode ? null : _start,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('启动'),
                ),
              if (!hasNode)
                TextButton(
                  onPressed: () => widget.onOpenPage?.call(HaloPage.nodes),
                  child: const Text('去选择节点'),
                ),
            ],
          ),
        ],
      ),
    );

    final nodeCard = SectionCard(
      title: '当前节点',
      trailing: TextButton(
        onPressed: () => widget.onOpenPage?.call(HaloPage.nodes),
        child: const Text('更换'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoRow(label: '节点', value: c.activeNodeName ?? '未选择'),
          InfoRow(
            label: '分流模式',
            value: modeLabel(ProxyMode.fromWire(c.routing.mode.wire)),
          ),
        ],
      ),
    );

    final modeCard = SectionCard(
      title: '分流模式',
      child: HaloSelector<ProxyMode>(
        options: const [
          (ProxyMode.rule, '规则'),
          (ProxyMode.global, '全局'),
          (ProxyMode.direct, '直连'),
        ],
        value: ProxyMode.fromWire(c.routing.mode.wire),
        enabled: c.storeReady && !_busy,
        height: 44,
        onChanged: c.storeReady && !_busy ? _setMode : null,
      ),
    );

    final infoCard = SectionCard(
      title: '运行信息',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoRow(
            label: 'VPN 权限',
            value: switch (_permission) {
              true => '已授权',
              false => '未授权',
              null => '检查中',
            },
          ),
          InfoRow(
            label: '内核进程',
            value: c.androidVpnActive ? ':vpn 运行中' : ':vpn 未运行',
          ),
          InfoRow(label: '数据目录', value: c.dataDir),
        ],
      ),
    );

    return HaloPageScaffold(
      title: '总览',
      subtitle: '运行状态与常用开关',
      actions: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh, size: 15),
          label: const Text('刷新'),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Same breakpoint and card order as the Windows overview: banner,
          // status card, then node/mode side by side when there is room.
          final twoColumns =
              constraints.maxWidth >= HaloMetrics.overviewTwoColumnBreakpoint;
          return ListView(
            children: [
              if (showBanner) ...[
                HaloNextStepCard(
                  controller: c,
                  onOpenPage: widget.onOpenPage,
                  onRunStep: widget.onRunStep,
                ),
                const SizedBox(height: HaloMetrics.cardGap),
              ],
              statusCard,
              const SizedBox(height: HaloMetrics.cardGap),
              if (twoColumns)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: nodeCard),
                    const SizedBox(width: HaloMetrics.cardGap),
                    Expanded(child: modeCard),
                  ],
                )
              else ...[
                nodeCard,
                const SizedBox(height: HaloMetrics.cardGap),
                modeCard,
              ],
              const SizedBox(height: HaloMetrics.cardGap),
              infoCard,
            ],
          );
        },
      ),
    );
  }
}
