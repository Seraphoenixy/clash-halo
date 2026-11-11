import 'dart:async';

import 'package:flutter/material.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'pages/android_overview_page.dart';
import 'pages/connections_page.dart';
import 'pages/logs_page.dart';
import 'pages/nodes_page.dart';
import 'pages/overview_page.dart';
import 'pages/rules_page.dart';
import 'pages/settings_page.dart';
import 'pages/subscriptions_page.dart';
import 'pages/unlock_page.dart';
import 'shell.dart';
import 'status_bar.dart';

/// Root widget: wires the controller into a persistent shell and swaps pages.
class HaloApp extends StatefulWidget {
  const HaloApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<HaloApp> createState() => _HaloAppState();
}

class _HaloAppState extends State<HaloApp> {
  HaloPage _page = HaloPage.overview;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _sidebarCollapsed = false;

  /// Below this the rail does not fit beside a usable page: it becomes a
  /// drawer and the header gets a menu button.
  static const double _compactBreakpoint = 760;

  AppController get controller => widget.controller;

  void _open(HaloPage page) {
    if (page == _page) return;
    setState(() => _page = page);
  }

  /// Performs whatever the outstanding [NextStep] asks for.
  ///
  /// The steps that point at the overview page are where the user usually
  /// already is: navigating there was a no-op, so 「去启动」 looked like a dead
  /// button. It now runs the action the sentence describes. Steps that live on
  /// another page still navigate.
  Future<void> _runStep(NextStep step) async {
    switch (step.action) {
      case NextStepAction.startCore:
        try {
          await controller.startCore();
        } catch (_) {
          // The controller records the reason for the error strip.
        }
      case null:
        _open(HaloPage.forStep(step.page));
    }
  }

  /// Re-probes the platform's status source.
  ///
  /// Windows retries the host pipe; Android re-reads the `:vpn` status and
  /// starts it again only when it is genuinely stopped or failed.
  Future<void> _retryConnection() async {
    try {
      if (controller.isAndroid) {
        await controller.retryAndroidVpn();
      } else {
        await controller.retryConnect();
      }
    } catch (_) {
      // The controller records the reason for the error strip.
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < _compactBreakpoint;
        if (compact) {
          return Scaffold(
            key: _scaffoldKey,
            drawer: Drawer(
              width: HaloMetrics.sidebarWidth,
              child: SafeArea(
                bottom: false,
                child: _buildSidebar(compact: true, closeDrawer: true),
              ),
            ),
            body: SafeArea(
              child: HaloPageMenu(
                onOpen: () => _scaffoldKey.currentState?.openDrawer(),
                child: content,
              ),
            ),
          );
        }
        return SafeArea(
          child: Row(
            children: [
              _buildSidebar(compact: false, closeDrawer: false),
              Expanded(child: content),
            ],
          ),
        );
      },
    );
  }

  /// The sidebar listens to connection, runtime and catalog revisions because
  /// its footer and the attention dot change on all three.
  Widget _buildSidebar({required bool compact, required bool closeDrawer}) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.connectionRevision,
      builder: (context, _, _) => ValueListenableBuilder<int>(
        valueListenable: controller.runtimeRevision,
        builder: (context, _, _) => ValueListenableBuilder<int>(
          valueListenable: controller.catalogRevision,
          builder: (context, _, _) {
            final step = controller.nextStep;
            final isAndroid = controller.isAndroid;
            return HaloSidebar(
              current: _page,
              onSelect: (page) {
                if (closeDrawer) _scaffoldKey.currentState?.closeDrawer();
                _open(page);
              },
              connected: isAndroid
                  ? controller.androidVpnActive
                  : controller.connected,
              coreRunning: isAndroid
                  ? controller.androidVpnStarted
                  : (controller.snapshot?.coreState.isRunning ?? false),
              isAndroid: isAndroid,
              compact: compact,
              collapsed: !compact && _sidebarCollapsed,
              onToggle: compact
                  ? null
                  : () =>
                        setState(() => _sidebarCollapsed = !_sidebarCollapsed),
              blockedPage: step == null ? null : HaloPage.forStep(step.page),
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        Expanded(
          child: ValueListenableBuilder<int>(
            // start() is deferred past the first frame, so a store that
            // fails to open is only discovered after this subtree has
            // already built. Without a listener here the error panel
            // never rendered and the user got a normal-looking but empty
            // window.
            valueListenable: controller.errorRevision,
            builder: (context, _, _) => _PageHost(
              page: _page,
              controller: controller,
              onOpenPage: _open,
              onRunStep: _runStep,
            ),
          ),
        ),
        ValueListenableBuilder<int>(
          valueListenable: controller.runtimeRevision,
          builder: (context, _, _) => ValueListenableBuilder<int>(
            // The strip shows 系统代理, which arrives on its own channel.
            valueListenable: controller.proxyRevision,
            builder: (context, _, _) => ValueListenableBuilder<int>(
              valueListenable: controller.connectionRevision,
              builder: (context, _, _) => ValueListenableBuilder<int>(
                valueListenable: controller.catalogRevision,
                builder: (context, _, _) {
                  final snap = controller.snapshot;
                  final isAndroid = controller.isAndroid;
                  return HaloStatusBar(
                    snapshot: snap,
                    connected: controller.connected,
                    nextStep: controller.nextStep,
                    activeNodeName: controller.activeNodeName,
                    isAndroid: isAndroid,
                    androidCoreState: isAndroid
                        ? controller.androidCoreState
                        : null,
                    androidVpnLabel: isAndroid
                        ? controller.androidVpnLabel
                        : null,
                    mode: isAndroid
                        ? ProxyMode.fromWire(controller.routing.mode.wire)
                        : null,
                    intercepted: isAndroid
                        ? controller.androidVpnStarted
                        : null,
                    onOpenStep: () {
                      final step = controller.nextStep;
                      if (step != null) unawaited(_runStep(step));
                    },
                    onRetryConnect: () => unawaited(_retryConnection()),
                  );
                },
              ),
            ),
          ),
        ),
        ValueListenableBuilder<int>(
          valueListenable: controller.errorRevision,
          builder: (context, _, _) {
            final message = controller.lastActionError;
            if (message == null) return const SizedBox.shrink();
            return _ActionErrorBar(message: message);
          },
        ),
      ],
    );
  }
}

/// Hosts the current page inside the standard header + padded body.
///
/// The page is wrapped in the listeners its content actually depends on. This is
/// the counterpart to the narrow channels on the controller: dropping the
/// whole-tree rebuild also dropped the delivery, so a page that renders the
/// snapshot would keep showing "尚未获取到运行状态" after the host had connected.
/// Only the *current* page is rebuilt, which is the whole point.
class _PageHost extends StatelessWidget {
  const _PageHost({
    required this.page,
    required this.controller,
    required this.onOpenPage,
    required this.onRunStep,
  });

  final HaloPage page;
  final AppController controller;
  final ValueChanged<HaloPage> onOpenPage;
  final Future<void> Function(NextStep step) onRunStep;

  @override
  Widget build(BuildContext context) {
    // A failed database is reported by the pane, because every page except the
    // shell needs the store and rendering one would otherwise throw inside
    // `build` and say less than the store's own error message does.
    //
    // Keyed on the error rather than on `storeReady`: a store that was never
    // opened is not a failure, and the pages are already written to survive a
    // missing runtime state.
    if (controller.storeError != null) {
      return _StoreUnavailable(
        dataDir: controller.dataDir,
        reason: controller.storeError,
      );
    }
    // Diagnostics pages are self-sufficient: logs stream, settings reads once,
    // and neither renders runtime state that a snapshot tick would change.
    final body = switch (page) {
      HaloPage.overview =>
        controller.isAndroid
            ? _watching(
                () => AndroidOverviewPage(
                  controller: controller,
                  onOpenPage: onOpenPage,
                  onRunStep: onRunStep,
                ),
              )
            : _watching(
                () => OverviewPage(
                  controller: controller,
                  onOpenPage: onOpenPage,
                  onRunStep: onRunStep,
                ),
              ),
      HaloPage.nodes => _watching(
        () => NodesPage(
          controller: controller,
          onOpenSubscriptions: () => onOpenPage(HaloPage.subscriptions),
        ),
      ),
      HaloPage.subscriptions => _watching(
        () => SubscriptionsPage(
          controller: controller,
          onOpenNodes: () => onOpenPage(HaloPage.nodes),
        ),
      ),
      HaloPage.routing => _watching(() => RulesPage(controller: controller)),
      HaloPage.test => _watching(
        () => UnlockPage(
          controller: controller,
          onOpenNodes: () => onOpenPage(HaloPage.nodes),
        ),
      ),
      HaloPage.connections => _watching(
        () => ConnectionsPage(controller: controller),
      ),
      HaloPage.logs => LogsPage(controller: controller),
      HaloPage.settings => _watching(
        () => SettingsPage(controller: controller),
      ),
    };
    return body;
  }

  /// Rebuilds the page when runtime, catalog or connection state changes.
  ///
  /// Takes a *factory*, not a widget. Returning a pre-built instance would hand
  /// Flutter the identical object on the next update, and `updateChild`
  /// short-circuits that case — the listeners would fire and nothing would
  /// repaint, which is exactly the bug this wrapper exists to prevent.
  ///
  /// The proxy switch is *not* here: the controller reports it on
  /// [AppController.proxyRevision] instead of the coarse runtime channel, so
  /// flipping it repaints that one card rather than rebuilding the page.
  Widget _watching(Widget Function() build) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.runtimeRevision,
      builder: (context, _, _) => ValueListenableBuilder<int>(
        valueListenable: controller.catalogRevision,
        builder: (context, _, _) => ValueListenableBuilder<int>(
          valueListenable: controller.connectionRevision,
          builder: (context, _, _) => build(),
        ),
      ),
    );
  }
}

/// Lets a page header open the compact drawer without every page threading a
/// callback down. The scope exists only while the rail is a drawer; on wide
/// layouts [maybeOf] returns null and no menu button is drawn.
class HaloPageMenu extends InheritedWidget {
  const HaloPageMenu({super.key, required this.onOpen, required super.child});

  final VoidCallback onOpen;

  static HaloPageMenu? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HaloPageMenu>();

  @override
  bool updateShouldNotify(HaloPageMenu oldWidget) => oldWidget.onOpen != onOpen;
}

/// A page frame: header with title/actions and a scrollable body.
///
/// The header sits directly on the canvas with a hairline underneath, which is
/// how Fluent separates window chrome from content without introducing another
/// surface colour.
///
/// Below 760 logical pixels the header becomes two rows: the title row carries
/// the drawer button, and the actions sit in a horizontally scrollable row.
/// No button is hidden, and the header no longer overflows when a page has
/// three or four actions.
class HaloPageScaffold extends StatelessWidget {
  const HaloPageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.maxContentWidth,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// Caps the body and centres it. A form card stretched to the full window
  /// puts a 200px label and its control 1000px apart; tables and lists pass
  /// null because they use the width they are given.
  final double? maxContentWidth;
  final Widget child;

  /// Keep in sync with [_HaloAppState._compactBreakpoint].
  static const double compactBreakpoint = 760;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final menu = HaloPageMenu.maybeOf(context);
    final compact = MediaQuery.sizeOf(context).width < compactBreakpoint;
    final horizontal = compact ? 8.0 : HaloMetrics.contentPadding;

    final titleBlock = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.titleLarge,
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall,
            ),
          ),
      ],
    );

    final actionRow = actions.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in actions) ...[
                const SizedBox(width: 8),
                action,
              ],
            ],
          );

    // Touch platforms get the larger action targets even in the wide header;
    // a tablet with a mouse still benefits, and a desktop window keeps 32 px.
    final touch = haloTouchPlatform(context);
    final themedActions = actionRow == null
        ? null
        : (compact || touch)
        ? _compactActionTheme(context, actionRow)
        : actionRow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: BoxConstraints(
            minHeight: compact ? 92 : HaloMetrics.pageHeaderHeight,
          ),
          padding: EdgeInsets.fromLTRB(
            horizontal,
            compact ? 6 : 0,
            horizontal,
            compact ? 6 : 0,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.border)),
          ),
          child: compact
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        if (menu != null)
                          IconButton(
                            onPressed: menu.onOpen,
                            tooltip: '打开导航',
                            icon: const Icon(Icons.menu),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                          ),
                        Expanded(child: titleBlock),
                      ],
                    ),
                    if (themedActions != null)
                      SizedBox(
                        height: 40,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: themedActions,
                        ),
                      ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: titleBlock),
                    if (themedActions != null)
                      Flexible(
                        fit: FlexFit.loose,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: themedActions,
                        ),
                      ),
                  ],
                ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.all(compact ? 10 : HaloMetrics.contentPadding),
            child: maxContentWidth == null
                ? child
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxContentWidth!),
                      child: child,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// Tougher vertical targets in the compact header. Explicit styles on a page
  /// button still win; this only lifts the defaults to a touch-sized 40 px.
  Widget _compactActionTheme(BuildContext context, Widget child) {
    final base = Theme.of(context);
    final size = const Size(0, 40);
    const padding = EdgeInsets.symmetric(horizontal: 14);
    return Theme(
      data: base.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: size, padding: padding),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: size, padding: padding),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(minimumSize: size, padding: padding),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(40, 40)),
        ),
      ),
      child: child,
    );
  }
}

/// Shown in place of any page when the database could not be opened.
///
/// The alternative is a per-page crash, and a crash inside `build` says less
/// about the problem than the store's own error message does.
class _StoreUnavailable extends StatelessWidget {
  const _StoreUnavailable({required this.dataDir, required this.reason});

  final String dataDir;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final danger = HaloColors.adapt(HaloColors.danger, p.isDark);
    return HaloPageScaffold(
      title: '数据库不可用',
      subtitle: dataDir,
      // Scrollable rather than centred: a store failure can carry a long
      // exception string, and a centred child taller than the pane is clipped at
      // both ends. An error message the user cannot finish reading is worth
      // less than the space the centring saves.
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(HaloMetrics.radiusCard),
              border: Border.all(color: p.border),
              boxShadow: haloCardShadow(p),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: danger),
                    const SizedBox(width: 8),
                    // Deliberately not "无法打开数据库": that phrase already
                    // appears in the reason below, and tests (rightly) assert
                    // exactly one explanation of the failure on screen.
                    Text(
                      '数据库无法打开',
                      style: text.titleMedium?.copyWith(color: danger),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SelectableText(
                  reason ?? '未能读取数据库原因',
                  style: text.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                Divider(height: 1, color: p.border),
                const SizedBox(height: 16),
                Text(
                  '节点、订阅、分流与设置都存在这个数据库里，所以它们暂时不可用。'
                  '代理内核本身不受影响，如果它已经在运行，继续按原来的规则工作。',
                  style: text.bodyMedium?.copyWith(height: 1.6),
                ),
                const SizedBox(height: 10),
                Text(
                  '常见原因: 数据目录没有写权限、磁盘已满、或数据库文件被安全软件锁住。'
                  '确认目录可写后重启即可;数据库损坏时它会被改名保留，重启后自动重建。',
                  style: text.bodyMedium?.copyWith(height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The one-line strip at the bottom for a command that failed but did not
/// change the page: a declined action, a rejected import.
class _ActionErrorBar extends StatelessWidget {
  const _ActionErrorBar({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final warning = HaloColors.adapt(HaloColors.warning, p.isDark);
    return Container(
      width: double.infinity,
      color: warning.withValues(alpha: p.isDark ? 0.16 : 0.10),
      padding: const EdgeInsets.symmetric(
        horizontal: HaloMetrics.contentPadding,
        vertical: 8,
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 15, color: warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: p.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
