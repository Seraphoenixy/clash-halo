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
    this.isAndroid = false,
    this.collapsed = false,
    this.compact = false,
    this.onToggle,
    this.blockedPage,
  });

  final HaloPage current;
  final ValueChanged<HaloPage> onSelect;
  final bool connected;
  final bool coreRunning;

  /// Android 上第一个状态表示 `:vpn` 服务，而不是 Windows 宿主管道；
  /// 文案随平台切换，避免把两种连接混为一谈。
  final bool isAndroid;

  /// Icon-only rail. The page area gets the reclaimed width.
  final bool collapsed;

  /// Narrow layout / drawer: taller rows and no desktop hover copy.
  final bool compact;

  /// Expands or collapses the rail; null in the drawer, which is always open.
  final VoidCallback? onToggle;

  /// The page the current [NextStep] points at, marked with a dot so the
  /// sidebar itself says where the work is. Null once nothing is outstanding.
  final HaloPage? blockedPage;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final touch = compact || haloTouchPlatform(context);
    return AnimatedContainer(
      duration: HaloMetrics.fastDuration,
      curve: HaloMetrics.fastCurve,
      width: collapsed
          ? HaloMetrics.sidebarCollapsedWidth
          : HaloMetrics.sidebarWidth,
      decoration: BoxDecoration(
        color: p.canvas,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BrandBar(palette: p, collapsed: collapsed, onToggle: onToggle),
          Divider(height: 1, color: p.border),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                collapsed ? 6 : 8,
                6,
                collapsed ? 6 : 8,
                6,
              ),
              children: [
                for (final page in HaloPage.values)
                  HaloNavItem(
                    page: page,
                    selected: page == current,
                    needsAttention: page == blockedPage,
                    collapsed: collapsed,
                    compact: touch,
                    onTap: () => onSelect(page),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: p.border),
          _StatusFooter(
            connected: connected,
            coreRunning: coreRunning,
            isAndroid: isAndroid,
            collapsed: collapsed,
          ),
        ],
      ),
    );
  }
}

/// App mark plus product name. Height matches the page header so the divider
/// below it lines up with the header's own divider.
///
/// Collapsed, the bar becomes a single expand control: the mark still
/// identifies the app and the tap target is larger than the icon it replaces.
class _BrandBar extends StatelessWidget {
  const _BrandBar({
    required this.palette,
    required this.collapsed,
    this.onToggle,
  });

  final HaloPalette palette;
  final bool collapsed;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final mark = ClipRRect(
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
    );

    if (collapsed) {
      return SizedBox(
        height: HaloMetrics.logoBarHeight,
        child: Tooltip(
          message: '展开导航栏',
          child: InkWell(
            onTap: onToggle,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  mark,
                  // A collapsed rail otherwise hides the only way back.
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Icon(
                      Icons.chevron_right,
                      size: 11,
                      color: palette.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: HaloMetrics.logoBarHeight,
      child: Row(
        children: [
          const SizedBox(width: 14),
          mark,
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
          if (onToggle != null)
            IconButton(
              onPressed: onToggle,
              tooltip: '收起导航栏',
              iconSize: 16,
              icon: const Icon(Icons.chevron_left),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
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
    this.collapsed = false,
    this.compact = false,
  });

  final HaloPage page;
  final bool selected;
  final VoidCallback onTap;

  /// Draws a dot on the trailing edge. Used for the page the outstanding
  /// [NextStep] points at, so the sidebar advertises unfinished setup instead of
  /// leaving the user to find it.
  final bool needsAttention;

  /// Icon-only rail: the label is kept in the tooltip and semantics only.
  final bool collapsed;

  /// Touch-sized row (44px) instead of the desktop 34px row.
  final bool compact;

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
    final height = widget.compact
        ? HaloMetrics.mobileNavItemHeight
        : HaloMetrics.navItemHeight;

    final attentionDot = widget.needsAttention
        ? Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: HaloColors.adapt(HaloColors.warning, p.isDark),
            ),
          )
        : null;

    if (widget.collapsed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Tooltip(
          message: widget.page.label,
          child: Semantics(
            label: widget.page.label,
            selected: selected,
            button: true,
            child: GestureDetector(
              onTap: widget.onTap,
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: HaloMetrics.fastDuration,
                curve: HaloMetrics.fastCurve,
                height: height,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(HaloMetrics.radius),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(widget.page.icon, size: 18, color: foreground),
                    if (attentionDot != null)
                      Positioned(top: 8, right: 8, child: attentionDot),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        label: widget.page.label,
        selected: selected,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: HaloMetrics.fastDuration,
              curve: HaloMetrics.fastCurve,
              height: height,
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
                  Icon(
                    widget.page.icon,
                    size: widget.compact ? 18 : 16,
                    color: foreground,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.page.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: widget.compact ? 14 : 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: foreground,
                      ),
                    ),
                  ),
                  if (attentionDot != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: attentionDot,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Platform liveness, the two things a user checks first.
class _StatusFooter extends StatelessWidget {
  const _StatusFooter({
    required this.connected,
    required this.coreRunning,
    required this.isAndroid,
    required this.collapsed,
  });

  final bool connected;
  final bool coreRunning;
  final bool isAndroid;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            _dotOnly(context, connected, '代理服务'),
            const SizedBox(height: 8),
            _dotOnly(context, coreRunning, '代理内核'),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dot(connected, '代理服务', onLabel: '已连接', offLabel: '未连接'),
          const SizedBox(height: 6),
          _dot(
            coreRunning,
            '代理内核',
            // Windows 的内核是独立程序，用「未运行」；Android 的内核在
            // :vpn 服务里，用「未启动」区分服务未启动。
            onLabel: '运行中',
            offLabel: isAndroid ? '未启动' : '未运行',
          ),
        ],
      ),
    );
  }

  /// Icon-only footer for the collapsed rail: the state colour is still
  /// visible, and the tooltip carries the two words that no longer fit.
  Widget _dotOnly(BuildContext context, bool ok, String label) {
    final p = HaloPalette.of(context);
    final color = ok
        ? HaloColors.adapt(HaloColors.success, p.isDark)
        : p.textTertiary;
    return Tooltip(
      message: '$label：${ok ? '正常' : '未运行'}',
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }

  Widget _dot(
    bool ok,
    String label, {
    required String onLabel,
    required String offLabel,
  }) {
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
          onLabel: onLabel,
          offLabel: offLabel,
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
