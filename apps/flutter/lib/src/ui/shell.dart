import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';

/// The left navigation rail.
///
/// Fluent's NavigationView puts the pane on the canvas rather than on a card:
/// the pane and the page share one background, the selection is marked by a
/// vertical accent indicator plus a subtle fill, and items react to hover with
/// a fill rather than a colour change. Everything here follows that.
///
/// The order encodes the work, not the feature list. Both reference clients do
/// this: v2rayN keeps 配置项 and 订阅 at the top and buries configuration in a
/// settings menu; its main window is a server list plus a status bar, with no
/// separate "test" page — latency lives in a column of that list. Ours follows
/// that: one flat list where the first four entries are the daily path, and
/// speed testing is a column on 节点 rather than a destination of its own.
enum HaloPage {
  overview('总览', Icons.dashboard_outlined),
  subscriptions('订阅', Icons.rss_feed_outlined),
  nodes('节点', Icons.dns_outlined),
  routing('规则', Icons.alt_route_outlined),
  // After routing and before logs: the connection list is where a routing rule
  // is checked, so it belongs next to the rules that produced it.
  // hub_outlined, not swap_vert_outlined: the two-arrow glyph is drawn with
  // much thinner strokes than its siblings and read as a faded icon next to
  // them.
  // The unlock page sits after the daily path and before the diagnostics:
  // "which services does this exit unlock" is a question about the node that is
  // currently carrying traffic, and its answer is thirteen independent verdicts
  // with regions, which no column of the node table could hold.
  test('测试', Icons.travel_explore),
  connections('连接', Icons.hub_outlined),
  logs('日志', Icons.receipt_long_outlined),
  settings('设置', Icons.settings_outlined);

  const HaloPage(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Maps the controller's navigation targets onto the shell's pages.
  static HaloPage forStep(HaloStepPage step) => switch (step) {
    HaloStepPage.overview => HaloPage.overview,
    HaloStepPage.nodes => HaloPage.nodes,
    HaloStepPage.subscriptions => HaloPage.subscriptions,
  };
}

class HaloSidebar extends StatelessWidget {
  const HaloSidebar({
    super.key,
    required this.current,
    required this.onSelect,
    required this.connected,
    required this.coreRunning,
    this.blockedPage,
  });

  final HaloPage current;
  final ValueChanged<HaloPage> onSelect;
  final bool connected;
  final bool coreRunning;

  /// The page the current [NextStep] points at, marked with a dot so the
  /// sidebar itself says where the work is. Null once nothing is outstanding.
  final HaloPage? blockedPage;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Container(
      width: HaloMetrics.sidebarWidth,
      decoration: BoxDecoration(
        color: p.canvas,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BrandBar(palette: p),
          Divider(height: 1, color: p.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              children: [
                for (final page in HaloPage.values)
                  HaloNavItem(
                    page: page,
                    selected: page == current,
                    needsAttention: page == blockedPage,
                    onTap: () => onSelect(page),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: p.border),
          _StatusFooter(connected: connected, coreRunning: coreRunning),
        ],
      ),
    );
  }
}

/// App mark plus product name. Height matches the page header so the divider
/// below it lines up with the header's own divider.
class _BrandBar extends StatelessWidget {
  const _BrandBar({required this.palette});

  final HaloPalette palette;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: HaloMetrics.logoBarHeight,
      child: Row(
        children: [
          const SizedBox(width: 14),
          // The same cat mark as the window icon and the tray icon. It used to be
          // a violet rounded square with a Material bolt, which matched neither.
          ClipRRect(
            borderRadius: BorderRadius.circular(HaloMetrics.radius + 2),
            child: Image.asset(
              'assets/brand/brand_cat.png',
              width: 24,
              height: 24,
              filterQuality: FilterQuality.high,
              // A missing asset must not take the sidebar down with it: the
              // label alone still identifies the app.
              errorBuilder: (context, error, stack) => _FallbackMark(palette),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Clash Halo',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the navigation rail.
///
/// Public because the hover/press fill is easy to regress without noticing and
/// the widget is worth testing directly: see `nav_hover_test.dart`, which pins
/// that the animated fill never darkens below the hover colour.
class HaloNavItem extends StatefulWidget {
  const HaloNavItem({
    super.key,
    required this.page,
    required this.selected,
    required this.onTap,
    this.needsAttention = false,
  });

  final HaloPage page;
  final bool selected;
  final VoidCallback onTap;

  /// Draws a dot on the trailing edge. Used for the page the outstanding
  /// [NextStep] points at, so the sidebar advertises unfinished setup instead of
  /// leaving the user to find it.
  final bool needsAttention;

  @override
  State<HaloNavItem> createState() => _HaloNavItemState();
}

class _HaloNavItemState extends State<HaloNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final selected = widget.selected;
    // Fade the destination colour's alpha instead of tweening to
    // Colors.transparent: see haloHidden(). Interpolating to transparent black
    // is what produced the black frame that flashed while the pointer moved
    // down the sidebar.
    final fill = (selected ? p.accentSubtle : p.cardHover).withValues(
      alpha: selected || _hovered ? 1 : 0,
    );
    final foreground = selected
        ? p.accent
        : _hovered
        ? p.textPrimary
        : p.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: HaloMetrics.fastDuration,
            curve: HaloMetrics.fastCurve,
            height: HaloMetrics.navItemHeight,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(HaloMetrics.radius),
            ),
            child: Row(
              children: [
                // Fluent marks the current pane with a vertical accent bar
                // instead of relying on the fill alone, which carries the
                // selection even in high-contrast or on a tinted background.
                AnimatedContainer(
                  duration: HaloMetrics.fastDuration,
                  curve: HaloMetrics.fastCurve,
                  width: 3,
                  height: 16,
                  margin: const EdgeInsets.only(left: 3, right: 9),
                  decoration: BoxDecoration(
                    // Same reasoning as the row fill: animate the accent's own
                    // alpha so the bar cannot pass through translucent black.
                    color: p.accent.withValues(alpha: selected ? 1 : 0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(widget.page.icon, size: 16, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.page.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: foreground,
                    ),
                  ),
                ),
                if (widget.needsAttention)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: HaloColors.adapt(HaloColors.warning, p.isDark),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Host and core liveness, the two things a user checks first.
class _StatusFooter extends StatelessWidget {
  const _StatusFooter({required this.connected, required this.coreRunning});

  final bool connected;
  final bool coreRunning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dot(connected, '后台服务'),
          const SizedBox(height: 6),
          _dot(coreRunning, '代理内核'),
        ],
      ),
    );
  }

  Widget _dot(bool ok, String label) {
    return Builder(
      builder: (context) {
        final p = HaloPalette.of(context);
        return _StatusDot(
          ok: ok,
          label: label,
          palette: p,
          // 后台服务 is a pipe this process holds open, so 已连接/未连接 is
          // literally what happened. 代理内核 is a separate program that runs
          // or does not; calling it 已连接 in one place and 运行中 in another
          // described the same fact with two words and invited the reading
          // that the *core* had connected to something.
          onLabel: label == '代理内核' ? '运行中' : '已连接',
          offLabel: label == '代理内核' ? '未运行' : '未连接',
        );
      },
    );
  }
}

/// One status row: dot, label, and the state word, right-aligned.
class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.ok,
    required this.label,
    required this.palette,
    required this.onLabel,
    required this.offLabel,
  });

  final bool ok;
  final String label;
  final HaloPalette palette;
  final String onLabel;
  final String offLabel;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final color = ok
        ? HaloColors.adapt(HaloColors.success, p.isDark)
        : p.textTertiary;
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 12, color: p.textSecondary)),
        const Spacer(),
        Text(
          ok ? onLabel : offLabel,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// Stand-in for the brand mark when the asset cannot be loaded (widget tests
/// without assets, or a broken build). Keeps the row's height identical so the
/// layout does not jump.
class _FallbackMark extends StatelessWidget {
  const _FallbackMark(this.palette);

  final HaloPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: palette.accent,
        borderRadius: BorderRadius.circular(HaloMetrics.radius + 2),
      ),
      child: Icon(Icons.pets, size: 15, color: palette.onAccent),
    );
  }
}
