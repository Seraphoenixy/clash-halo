import 'package:flutter/material.dart';
import 'package:halo_config/halo_config.dart';

import '../../state/app_controller.dart';
import '../../state/unlock.dart';
import '../../theme.dart';
import '../app.dart';
import '../widgets.dart';

/// The test page: what the active exit unlocks, service by service.
///
/// This page exists because the answer cannot live in a column. The node table
/// has one latency and one reachability per node, and thirteen independent
/// per-service verdicts with regions do not fit in a row — trying to compress
/// them would produce the one thing this app keeps out of its tables, a single
/// number that means several different things.
///
/// Every request goes through the running core, so the list describes the node
/// that is actually carrying traffic; the page never starts a core of its own.
class UnlockPage extends StatelessWidget {
  const UnlockPage({
    super.key,
    required this.controller,
    required this.onOpenNodes,
  });

  final AppController controller;
  final VoidCallback onOpenNodes;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final unlock = c.unlock;
    return AnimatedBuilder(
      animation: unlock,
      builder: (context, _) {
        final coreRunning = c.snapshot?.coreState.isRunning ?? false;
        final ready = c.connected && coreRunning;
        final activeName = _activeNodeName(c);
        return HaloPageScaffold(
          title: '测试',
          subtitle: activeName == null
              ? '解锁检测：通过当前节点判断各流媒体与 AI 服务是否可用'
              : '解锁检测 · 当前节点 $activeName',
          actions: [
            if (unlock.running)
              OutlinedButton.icon(
                onPressed: unlock.cancel,
                icon: const Icon(Icons.stop, size: 15),
                label: Text('停止（${unlock.runningCount}）'),
              )
            else
              FilledButton.icon(
                onPressed: ready ? unlock.checkAll : null,
                icon: const Icon(Icons.playlist_add_check, size: 15),
                label: const Text('全部检测'),
              ),
            if (!ready)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: OutlinedButton.icon(
                  onPressed: onOpenNodes,
                  icon: const Icon(Icons.arrow_forward, size: 15),
                  label: const Text('去启用节点'),
                ),
              ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!ready)
                _Notice(
                  // Two different blockers, two different fixes: without the
                  // distinction the user retries the connection when what is
                  // missing is a running core.
                  message: !c.connected
                      ? '后台服务未连接，暂时无法检测。'
                      : '内核未运行。解锁检测必须通过当前节点发起请求，'
                            '请先在「节点」页启用一个节点。',
                ),
              if (unlock.error != null) _Notice(message: unlock.error!),
              if (ready && c.routing.mode == RouteMode.direct)
                // In direct mode the mixed inbound is still listening, so every
                // request succeeds — through the local connection. The verdicts
                // would describe this machine's region while the page claims
                // they describe the node.
                const _Notice(
                  message:
                      '当前是「直连」模式，内核不经过节点转发，'
                      '所以下面的结果描述的是本机出口而不是节点。'
                      '请先切到「规则」或「全局」模式再检测。',
                ),
              if (unlock.staleFor(c.snapshot?.activeNodeId))
                _Notice(
                  // The verdicts belong to an exit, so a node switch makes them
                  // describe the previous node. Saying so beats both silently
                  // clearing them and letting them pass as current.
                  message:
                      '下面的结果是 '
                      '${unlock.checkedNodeName ?? '上一个节点'} 的，'
                      '当前节点是 ${activeName ?? '未启用'}，建议重新检测。',
                ),
              Expanded(
                child: GridView.builder(
                  // No padding of its own: the page already insets its body,
                  // and 12 more on each side pushed the grid out of line with
                  // the header above it.
                  padding: EdgeInsets.zero,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    // 320 fits at most three columns at the 1180px window;
                    // 300 produced four 231px cards, where the region chip had
                    // to be truncated to fit beside the verdict chip.
                    maxCrossAxisExtent: 320,
                    // One title row, one chip row and one timestamp line. The
                    // old 92 left a Spacer-sized hole under every card and
                    // overflowed as soon as the region chip wrapped.
                    mainAxisExtent: 84,
                    // Same token as the overview grid and the card stack: a
                    // card-to-card gap is 12 wherever two cards meet.
                    crossAxisSpacing: HaloMetrics.cardGap,
                    mainAxisSpacing: HaloMetrics.cardGap,
                  ),
                  itemCount: unlock.items.length,
                  itemBuilder: (context, index) {
                    final item = unlock.items[index];
                    return _UnlockCard(
                      item: item,
                      checking: unlock.isChecking(item.id),
                      onRetest: ready && !unlock.running
                          ? () => unlock.checkOne(item.id)
                          : null,
                    );
                  },
                ),
              ),
              _UnlockStatusStrip(
                checked: unlock.checkedCount,
                total: unlock.total,
                running: unlock.running,
                lastCheckedAtMs: unlock.lastCheckedAtMs,
                counts: unlock.toneCounts,
              ),
            ],
          ),
        );
      },
    );
  }
}

String? _activeNodeName(AppController c) {
  final id = c.snapshot?.activeNodeId;
  if (id == null || id.isEmpty) return null;
  for (final node in c.loadNodes()) {
    if (node.id == id) return node.name;
  }
  return null;
}

/// Colour for a verdict category.
///
/// 未检测 is neutral grey on purpose: red already means "this service does not
/// work", and a freshly opened page showing thirteen red cards would be a
/// verdict on the node rather than on the check.
Color _toneColor(UnlockTone tone, BuildContext context) => switch (tone) {
  UnlockTone.ok => HaloColors.success,
  UnlockTone.bad => HaloColors.danger,
  UnlockTone.warn => HaloColors.warning,
  UnlockTone.unknown => HaloColors.info,
  UnlockTone.pending => HaloPalette.of(context).textTertiary,
};

IconData? _toneIcon(UnlockTone tone) => switch (tone) {
  UnlockTone.ok => Icons.check_circle_outline,
  UnlockTone.bad => Icons.cancel_outlined,
  UnlockTone.warn => Icons.help_outline,
  UnlockTone.unknown => Icons.help_outline,
  UnlockTone.pending => null,
};

class _UnlockCard extends StatelessWidget {
  const _UnlockCard({
    required this.item,
    required this.checking,
    required this.onRetest,
  });

  final UnlockItem item;
  final bool checking;
  final VoidCallback? onRetest;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final tone = unlockTone(item.status);
    final accent = haloAdapt(context, _toneColor(tone, context));
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(HaloMetrics.radiusCard),
        border: Border.all(color: p.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The reference client marks each card with a coloured left edge. It
          // survives the greyscale of a screenshot and reads faster than a chip
          // when thirteen cards are on screen at once.
          Container(width: 3, color: accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: checking
                            ? const Padding(
                                padding: EdgeInsets.all(7),
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                ),
                              )
                            : IconButton(
                                onPressed: onRetest,
                                tooltip: '重新检测',
                                iconSize: 14,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.refresh),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: HaloMetrics.lineGap),
                  // One row, not a Wrap. A long region label ("ALISG · 新加坡
                  // （Disney+ 标识）") used to wrap onto a second line, which
                  // overflowed the fixed card height and painted the reason text
                  // over the timestamp. Flexible lets the chip ellipsize
                  // instead, and the timestamp keeps its line.
                  Row(
                    children: [
                      Flexible(
                        child: StatusChip(
                          label: checking
                              ? '检测中'
                              : unlockStatusLabel(item.status),
                          color: _toneColor(tone, context),
                          icon: checking ? null : _toneIcon(tone),
                        ),
                      ),
                      if (item.region != null && item.region!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        // The code with its name. `ALISG` on its own is not a
                        // country code at all — it is Disney's Singapore marker
                        // — and sitting next to a `US` chip it read as a
                        // rendering fault rather than as a region.
                        Flexible(
                          // The card is ~300px wide, so a long region marker
                          // ("ALISG · 新加坡（Disney+ 标识）") is ellipsized;
                          // the tooltip keeps the full text reachable.
                          child: Tooltip(
                            message: unlockRegionDisplay(item.region!),
                            child: StatusChip(
                              label: unlockRegionDisplay(item.region!),
                              color: HaloColors.info,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const Spacer(),
                  // Pending cards said "尚未检测" under a chip that already said
                  // 未检测. Only a real timestamp adds information.
                  if (!item.isPending)
                    Text(
                      '检测于 ${formatDateTime(item.checkedAtMs)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A blocking condition, stated once above the grid instead of thirteen times.
///
/// No button of its own: the header already carries 「去启用节点」, and two
/// controls that do the same thing on one screen read as two different fixes.
class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final color = haloAdapt(context, HaloColors.warning);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: p.isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11.5, color: p.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// The bottom strip: progress, the last run, and the one key that does the
/// common thing. Thirteen cards cannot carry a "how far along is this" state on
/// their own without every card shouting at once.
class _UnlockStatusStrip extends StatelessWidget {
  const _UnlockStatusStrip({
    required this.checked,
    required this.total,
    required this.running,
    required this.lastCheckedAtMs,
    required this.counts,
  });

  final int checked;
  final int total;
  final bool running;
  final int lastCheckedAtMs;

  /// Verdicts by tone, so the strip can lead with the summary.
  final Map<UnlockTone, int> counts;

  /// Zero-count tones are omitted: a row of 可用 0 · 受限 0 · 失败 0 on a freshly
  /// opened page says less than nothing.
  List<Widget> _summaryChips(BuildContext context) {
    final order = <(UnlockTone, String)>[
      (UnlockTone.ok, '可用'),
      (UnlockTone.warn, '受限'),
      (UnlockTone.bad, '不可用'),
      (UnlockTone.unknown, '未知'),
    ];
    final chips = <Widget>[];
    for (final (tone, label) in order) {
      final n = counts[tone] ?? 0;
      if (n == 0) continue;
      if (chips.isNotEmpty) chips.add(const SizedBox(width: 10));
      chips.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _toneIcon(tone) ?? Icons.circle,
              size: 11,
              color: _toneColor(tone, context),
            ),
            const SizedBox(width: 3),
            Text(
              '$label $n',
              maxLines: 1,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _toneColor(tone, context),
              ),
            ),
          ],
        ),
      );
    }
    return chips;
  }

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final style = TextStyle(fontSize: 11, color: p.textSecondary);
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          // The summary leads: with thirteen cards the question is "how many
          // work", not "which of these did I already test".
          ..._summaryChips(context),
          const SizedBox(width: 14),
          Flexible(
            child: Text(
              '已检测 $checked / $total',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 14),
          if (lastCheckedAtMs > 0)
            Flexible(
              child: Text(
                '上次 ${formatDateTime(lastCheckedAtMs)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          const Spacer(),
          if (running)
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '检测中，可关闭本页继续运行',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: Text(
                '结果会保存，重启后仍然可见',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: style.copyWith(color: p.textTertiary),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}
