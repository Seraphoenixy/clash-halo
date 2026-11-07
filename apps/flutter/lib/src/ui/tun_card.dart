import 'package:flutter/material.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../theme.dart';
import 'widgets.dart';

/// The TUN control on the overview page.
///
/// TUN is the one operation that can block for a long time: enabling it raises
/// a real Windows UAC prompt, and the host waits up to 90 seconds for the user
/// to answer. Everything this card renders therefore comes straight from the
/// snapshot the host publishes (`tunState` / `tunSupported` / `tunMessage`),
/// and the switch is locked while a request is in flight so a second click can
/// never start a second install request.
class TunCard extends StatelessWidget {
  const TunCard({
    super.key,
    required this.snapshot,
    required this.connected,
    this.pending = false,
    this.notice,
    this.noticeColor,
    this.onToggle,
  });

  final RuntimeSnapshot snapshot;

  /// Whether the host pipe is up; nothing can be toggled without it.
  final bool connected;

  /// True while this page is awaiting a `tun.setEnabled` reply. The snapshot
  /// also reports `TunState.pending` during the same window, but the local flag
  /// covers the moment before the first `stateChanged` event arrives and the
  /// moment after a failure.
  final bool pending;

  /// Outcome of the last toggle that is not already in [RuntimeSnapshot]: a
  /// refusal, a missing service, a rejected config. It is shown next to the
  /// control so the user never has to open the log page.
  final String? notice;
  final Color? noticeColor;

  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = HaloPalette.of(context);
    final state = snapshot.tunState;
    final waiting = tunWaiting(snapshot, pending: pending);
    final canToggle = tunCanToggle(
      snapshot,
      connected: connected,
      pending: pending,
    );
    // A failure is the one case where the chip alone is not enough; the reason
    // lives in tunMessage and must be reachable without opening the log page.
    final message = tunHintText(snapshot, pending: pending);
    return SectionCard(
      title: 'TUN 模式',
      trailing: Tooltip(
        message: message,
        child: StatusChip(
          label: tunStateLabel(state),
          color: tunStateColor(state),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HaloSwitchTile(
            title: '启用 TUN',
            // Only states that the switch itself cannot show belong here. The
            // idle case used to repeat the hint underneath almost word for word
            // ("启用时会弹出系统授权窗口" over "启用时将请求一次管理员授权…"),
            // so the card said the same thing twice and looked padded.
            //
            // The system-proxy case is different: enabling TUN turns that switch
            // off, and a control that silently reaches across the page needs to
            // say so before the click, not in a log afterwards.
            subtitle: waiting
                ? null
                : (!snapshot.tunSupported
                      ? '缺少必要的组件'
                      : (!state.isActive && snapshot.systemProxy.enabled
                            ? '启用后将关闭系统代理，由 TUN 接管全部流量'
                            : null)),
            value: state.isActive,
            onChanged: canToggle && onToggle != null ? onToggle : null,
          ),
          const SizedBox(height: HaloMetrics.lineGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (waiting) ...[
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  message,
                  style: waiting
                      ? Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: HaloColors.adapt(
                            HaloColors.warning,
                            palette.isDark,
                          ),
                        )
                      : Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (notice != null) ...[
            const SizedBox(height: HaloMetrics.lineGap),
            Text(
              notice!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: HaloColors.adapt(
                  noticeColor ?? palette.textSecondary,
                  palette.isDark,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Whether the switch may be toggled right now.
///
/// Unsupported means the host found no service/core: the switch must be dead
/// and the reason shown instead of pretending a click could work.
bool tunCanToggle(
  RuntimeSnapshot snapshot, {
  required bool connected,
  required bool pending,
}) =>
    connected &&
    !pending &&
    snapshot.tunSupported &&
    snapshot.tunState != TunState.pending;

/// True while the host is blocked on the Windows UAC prompt.
bool tunWaiting(RuntimeSnapshot snapshot, {required bool pending}) =>
    pending || snapshot.tunState == TunState.pending;

/// The line under the TUN switch.
///
/// `tunMessage` is authoritative whenever it carries something: on a failure it
/// is the host's `error.detail` (for example
/// `configure tun interface: Access is denied.`), which is the only actionable
/// text the user gets.
String tunHintText(RuntimeSnapshot snapshot, {required bool pending}) {
  final message = _nonEmpty(snapshot.tunMessage);
  final state = snapshot.tunState;
  if (tunWaiting(snapshot, pending: pending)) {
    // The host names the current phase ("首次启用：正在安装 TUN 服务…" or
    // "等待 TUN 服务启动内核"). Skip it when it only repeats the state chip,
    // which is already visible above.
    if (message != null && message != tunStateLabel(state)) {
      return message;
    }
    return '正在等待管理员授权：请在 Windows 授权窗口中点击「是」；'
        '首次启用会先安装 TUN 服务，内核启动最长约 90 秒。';
  }
  if (!snapshot.tunSupported || state == TunState.unsupported) {
    return message ?? 'TUN 模式当前不可用：缺少 TUN 服务程序或内核程序。';
  }
  if (state == TunState.failed) {
    return message ?? 'TUN 启动失败，请查看后台日志了解原因。';
  }
  if (state == TunState.unverified) {
    return '当前快照来自旧版本后台，无法确认 TUN 状态；重新连接后台即可刷新。';
  }
  if (state == TunState.enabled) {
    final adapter = _nonEmpty(snapshot.tunAdapter);
    return message ??
        (adapter == null ? 'TUN 已启用。' : 'TUN 已启用：适配器 $adapter。');
  }
  return message ?? '首次启用会安装 TUN 服务并请求一次管理员授权，之后不再询问。';
}

/// Maps a failed `tun.setEnabled` reply to text the user can act on.
///
/// A declined UAC prompt is a normal outcome, not an error: the user simply
/// said no, and the system-proxy mode keeps working.
String tunErrorText(HaloError error) {
  final detail = _nonEmpty(error.detail);
  final fallback = _nonEmpty(error.message) ?? HaloErrorCode.describe(error.code);
  return switch (error.code) {
    HaloErrorCode.elevationDenied =>
      '已取消管理员授权，TUN 未启用；系统代理模式不受影响。',
    HaloErrorCode.tunUnavailable => 'TUN 不可用：${detail ?? fallback}',
    HaloErrorCode.configInvalid => '无法启用 TUN：${detail ?? fallback}',
    // An old host may still answer with the pre-implementation code; say so
    // rather than pretending the user refused anything.
    HaloErrorCode.elevationRequired =>
      '当前后台版本仍依赖旧的按需提权助手；请更新应用后重试。',
    _ => 'TUN 操作失败：${detail ?? fallback}',
  };
}

/// Colour for [tunErrorText] output: a refused prompt is a warning, a broken
/// service or config is a real failure.
Color tunErrorColor(String code) => switch (code) {
  HaloErrorCode.elevationDenied ||
  HaloErrorCode.elevationRequired => HaloColors.warning,
  _ => HaloColors.danger,
};

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
