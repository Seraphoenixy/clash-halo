import 'package:flutter/material.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'shell.dart';
import 'widgets.dart';

/// Whether the overview has anything to say at the top.
///
/// Windows reports interception through the host snapshot; Android has no
/// snapshot and reports it through the `:vpn` status.
bool haloOverviewBannerVisible(AppController controller) {
  if (controller.nextStep != null) return true;
  if (controller.androidVpnStarted) return true;
  final snap = controller.snapshot;
  if (snap == null) return false;
  return snap.systemProxy.enabled || snap.tunState == TunState.enabled;
}

/// The one outstanding instruction, or a green "all set" line.
///
/// Shared by the Windows and Android overviews: the wording, colour and action
/// placement stay the same even though the state sources differ.
class HaloNextStepCard extends StatelessWidget {
  const HaloNextStepCard({
    super.key,
    required this.controller,
    this.onOpenPage,
    this.onRunStep,
  });

  final AppController controller;
  final ValueChanged<HaloPage>? onOpenPage;
  final Future<void> Function(NextStep step)? onRunStep;

  @override
  Widget build(BuildContext context) {
    final step = controller.nextStep;
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    if (step == null) {
      // Nothing outstanding. Only claim readiness when traffic is actually
      // intercepted. Windows reads the snapshot; Android reads the VPN state.
      final snap = controller.snapshot;
      final intercepted =
          controller.androidVpnStarted ||
          (snap?.systemProxy.enabled ?? false) ||
          ((snap?.tunState ?? TunState.disabled) == TunState.enabled);
      if (!intercepted) return const SizedBox.shrink();
      final success = HaloColors.adapt(HaloColors.success, p.isDark);
      return SectionCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 15, color: success),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '代理已就绪，流量正走当前节点。',
                style: text.bodyMedium?.copyWith(color: success),
              ),
            ),
          ],
        ),
      );
    }
    // Only `waiting` spins: it means something is actually in flight. A
    // stopped service will not change on its own, so a spinner there reads as
    // a forever-loading app.
    final waiting = step.kind == NextStepKind.waiting;
    final stopped = step.kind == NextStepKind.stopped;
    final accent = HaloColors.adapt(
      waiting
          ? HaloColors.info
          : stopped
          ? HaloColors.danger
          : HaloColors.warning,
      p.isDark,
    );
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(
        children: [
          Icon(
            waiting
                ? Icons.hourglass_top
                : stopped
                ? Icons.power_settings_new
                : Icons.arrow_circle_right_outlined,
            size: 16,
            color: accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: text.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: HaloMetrics.hairGap),
                Text(step.detail, style: text.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (!waiting && !stopped)
            FilledButton(
              onPressed: onRunStep != null
                  ? () => onRunStep!(step)
                  : onOpenPage == null
                  ? null
                  : () => onOpenPage!(HaloPage.forStep(step.page)),
              child: Text(step.actionLabel),
            )
          else if (waiting)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}
