import 'package:flutter/material.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'widgets.dart';

/// The always-visible strip along the bottom of the window.
///
/// Both reference clients make one surface the single authority for "what state
/// am I in", and neither buries it: v2rayN's status bar carries the inbound
/// ports, the TUN switch, the system-proxy mode, the routing mode, the current
/// server and the live speed; Verge's home tabs each carry a status dot plus a
/// caption of the *observed* state. Ours had that information only on the
/// overview page, so every other page was blind — you could sit on 日志 and have
/// no idea the proxy was off.
///
/// Reading order matches the data path, left to right: 内核 → 节点 → 系统代理 /
/// TUN → 模式. The right side is the single next step, or a quiet "已就绪".
class HaloStatusBar extends StatelessWidget {
  const HaloStatusBar({
    super.key,
    required this.snapshot,
    required this.connected,
    required this.nextStep,
    required this.activeNodeName,
    this.isAndroid = false,
    this.androidCoreState,
    this.androidVpnLabel,
    this.mode,
    this.intercepted,
    this.onOpenStep,
    this.onRetryConnect,
  });

  final RuntimeSnapshot? snapshot;
  final bool connected;
  final NextStep? nextStep;
  final String? activeNodeName;

  /// Android 上状态来自 `:vpn` 进程，不来自宿主快照。
  final bool isAndroid;
  final CoreState? androidCoreState;
  final String? androidVpnLabel;

  /// Android 的分流模式保存在本地设置里，快照为空。
  final ProxyMode? mode;

  /// Android 上 VPN 已连接时覆盖「是否已接管流量」的判断。
  final bool? intercepted;
  final VoidCallback? onOpenStep;
  final VoidCallback? onRetryConnect;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final snap = snapshot;
    final core = androidCoreState ?? snap?.coreState ?? CoreState.stopped;
    final proxyOn = !isAndroid && (snap?.systemProxy.enabled ?? false);
    final tunOn = !isAndroid && snap?.tunState == TunState.enabled;
    final currentMode = mode ?? snap?.mode ?? ProxyMode.rule;
    return Container(
      height: HaloMetrics.statusBarHeight,
      decoration: BoxDecoration(
        color: p.isDark ? p.card : HaloColors.lightSurfaceAlt,
        border: Border(top: BorderSide(color: p.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The strip sheds segments instead of overflowing. A 200%-scaled
          // display gives the window as little as 590 logical pixels, and a
          // RenderFlex overflow there paints the yellow-black hazard tape across
          // the bottom of the window — far worse than showing fewer facts. The
          // order of sacrifice follows importance: mode, then TUN, then the
          // system-proxy endpoint; 内核 and 节点 stay at every width because
          // they are the two things that explain "nothing works".
          final wide = constraints.maxWidth >= 900;
          final medium = constraints.maxWidth >= 700;
          final narrow = constraints.maxWidth >= 560;
          final compact = constraints.maxWidth < 640;
          if (compact) {
            final step = nextStep;
            return Row(
              children: [
                _Item(
                  icon: Icons.memory,
                  label: '内核',
                  value: coreStateLabel(core),
                  color: coreStateColor(core),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: _Item(
                    icon: isAndroid
                        ? Icons.vpn_lock_outlined
                        : Icons.dns_outlined,
                    label: isAndroid ? 'VPN' : '节点',
                    value: isAndroid
                        ? (androidVpnLabel ?? '未连接')
                        : (activeNodeName ?? '未选择'),
                    color: isAndroid
                        ? (core == CoreState.running
                              ? HaloColors.success
                              : (core == CoreState.failed
                                    ? HaloColors.danger
                                    : null))
                        : (activeNodeName == null
                              ? HaloColors.warning
                              : p.textPrimary),
                    muted: isAndroid
                        ? core == CoreState.stopped
                        : activeNodeName == null,
                  ),
                ),
                const Spacer(),
                if (step != null)
                  Tooltip(
                    message: step.detail,
                    child: IconButton(
                      onPressed: step.kind == NextStepKind.waiting
                          ? onRetryConnect
                          : onOpenStep,
                      iconSize: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      icon: Icon(
                        step.kind == NextStepKind.waiting
                            ? Icons.sync
                            : step.kind == NextStepKind.stopped
                            ? Icons.power_settings_new
                            : Icons.arrow_circle_right_outlined,
                        color: HaloColors.adapt(
                          step.kind == NextStepKind.stopped
                              ? HaloColors.danger
                              : HaloColors.info,
                          p.isDark,
                        ),
                      ),
                    ),
                  )
                else if (intercepted ?? false)
                  Tooltip(
                    message: '已就绪',
                    child: Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: HaloColors.adapt(HaloColors.success, p.isDark),
                    ),
                  ),
              ],
            );
          }
          return Row(
            children: [
              _Item(
                icon: Icons.memory,
                label: '内核',
                value: coreStateLabel(core),
                color: coreStateColor(core),
              ),
              _Divider(color: p.border),
              _Item(
                icon: Icons.dns_outlined,
                label: '节点',
                value: activeNodeName ?? '未选择',
                color: activeNodeName == null
                    ? HaloColors.warning
                    : p.textPrimary,
                muted: activeNodeName == null,
              ),
              if (isAndroid) ...[
                _Divider(color: p.border),
                _Item(
                  icon: Icons.vpn_lock_outlined,
                  label: 'VPN',
                  value: androidVpnLabel ?? '未连接',
                  color: core == CoreState.running
                      ? HaloColors.success
                      : (core == CoreState.failed ? HaloColors.danger : null),
                  muted: core == CoreState.stopped,
                ),
              ],
              if (!isAndroid && narrow) ...[
                _Divider(color: p.border),
                _Item(
                  icon: Icons.lan_outlined,
                  label: '系统代理',
                  value: proxyOn
                      ? (wide ? (snap?.systemProxy.endpoint ?? '已开启') : '已开启')
                      : '已关闭',
                  color: proxyOn ? HaloColors.success : null,
                  muted: !proxyOn,
                ),
              ],
              if (!isAndroid && medium) ...[
                const SizedBox(width: 14),
                _Item(
                  icon: Icons.shield_outlined,
                  label: 'TUN',
                  value: tunStateLabel(snap?.tunState ?? TunState.disabled),
                  color: tunOn
                      ? HaloColors.success
                      : (snap?.tunState == TunState.failed
                            ? HaloColors.danger
                            : null),
                  muted: !tunOn,
                ),
              ],
              if (wide) ...[
                _Divider(color: p.border),
                _Item(
                  icon: Icons.alt_route,
                  label: '模式',
                  value: modeLabel(currentMode),
                ),
              ],
              const Spacer(),
              Flexible(
                child: _Hint(
                  nextStep: nextStep,
                  connected: connected,
                  snapshot: snap,
                  intercepted: intercepted,
                  onOpenStep: onOpenStep,
                  onRetryConnect: onRetryConnect,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One "label: value" pair. The label stays tertiary so a scan lands on the
/// value, which is the part that can be wrong.
class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final tone = color == null
        ? (muted ? p.textTertiary : p.textPrimary)
        : HaloColors.adapt(color!, p.isDark);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: p.textTertiary),
        const SizedBox(width: 5),
        Text(
          '$label ',
          style: TextStyle(fontSize: 11.5, color: p.textTertiary),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 190),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: color,
    );
  }
}

/// The right-hand end: either the one outstanding instruction, or "已就绪".
class _Hint extends StatelessWidget {
  const _Hint({
    required this.nextStep,
    required this.connected,
    required this.snapshot,
    this.intercepted,
    this.onOpenStep,
    this.onRetryConnect,
  });

  final NextStep? nextStep;
  final bool connected;

  /// The runtime snapshot, read only to decide whether traffic is actually
  /// intercepted before claiming 已就绪.
  final RuntimeSnapshot? snapshot;

  /// Android 上 VPN 已连接即表示流量已接管；Windows 从快照推导。
  final bool? intercepted;
  final VoidCallback? onOpenStep;
  final VoidCallback? onRetryConnect;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final step = nextStep;
    if (step == null) {
      // "已就绪" is a claim about traffic, so it is only made when traffic is
      // actually intercepted.
      //
      // Removing the 流量还没有接管 step made "nothing outstanding" also cover
      // "core up, system proxy and TUN both off". The green tick would then say
      // the proxy is working while nothing routes through it. In that state the
      // bar stays quiet: 系统代理 and TUN already sit a few pixels to the left
      // saying 已关闭, which is the fact, stated once.
      final snap = snapshot;
      final interceptedNow =
          intercepted ??
          ((snap?.systemProxy.enabled ?? false) ||
              ((snap?.tunState ?? TunState.disabled) == TunState.enabled));
      if (!interceptedNow) return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 13,
            color: HaloColors.adapt(HaloColors.success, p.isDark),
          ),
          const SizedBox(width: 5),
          Text(
            '已就绪',
            style: TextStyle(
              fontSize: 11.5,
              color: HaloColors.adapt(HaloColors.success, p.isDark),
            ),
          ),
        ],
      );
    }
    final waiting = step.kind == NextStepKind.waiting;
    final stopped = step.kind == NextStepKind.stopped;
    final color = HaloColors.adapt(
      waiting
          ? HaloColors.info
          : stopped
          ? HaloColors.danger
          : HaloColors.warning,
      p.isDark,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Tooltip(
            message: step.detail,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A spinner only while the pipe is coming up: something is
                // genuinely in flight. A stopped host will not change on its
                // own, and a spinner there reads as "hang forever".
                if (waiting)
                  SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: color,
                    ),
                  )
                else if (stopped)
                  Icon(Icons.power_settings_new, size: 13, color: color)
                else
                  Icon(Icons.info_outline, size: 13, color: color),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    step.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // A stopped host has no action worth taking: retrying connects to a
        // process that is shutting down, and opening the step page only points
        // at the overview. The text alone carries the message.
        if (!stopped) ...[
          const SizedBox(width: 8),
          SizedBox(
            height: 22,
            child: TextButton(
              onPressed: waiting ? onRetryConnect : onOpenStep,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 22),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 11.5),
              ),
              child: Text(step.actionLabel),
            ),
          ),
        ],
      ],
    );
  }
}
