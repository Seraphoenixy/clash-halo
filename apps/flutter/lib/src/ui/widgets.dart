import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

import '../theme.dart';

/// Shared Fluent-styled building blocks.
///
/// Pages compose these instead of hand-rolling `Container` + colour, so the
/// surface hierarchy (canvas → card) and the semantic colours stay consistent.
/// Every widget here resolves its neutrals through [HaloPalette] and pushes
/// semantic colours through [HaloColors.adapt], which is what keeps the light
/// and dark themes honest.

/// A Fluent card: 8px corners, one hairline stroke, and a shadow light enough
/// that it only lifts the card off the canvas.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });

  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final radius = BorderRadius.circular(HaloMetrics.radiusCard);
    // Shadow on the outer box, surface on an inner Material: a coloured
    // DecoratedBox would sit between a ListTile and its Material ancestor and
    // swallow the ink splashes (Flutter asserts on exactly that).
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: haloCardShadow(p),
      ),
      child: Material(
        color: p.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: p.border),
        ),
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: HaloMetrics.blockGap),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title!,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      ?trailing,
                    ],
                  ),
                ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A single label/value line, used by the overview and settings panes.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A fixed label column: flexing it across the full card width left a
          // ~200px hole between short labels and their values on wide windows.
          // 104 fits the longest labels the app uses (「Reality ShortId」 would
          // ellipsize, but that row only exists in the node details dialog,
          // which uses its own width); 132 wasted 28px on every row.
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: text.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            // No maxLines: SelectableText reserves the full maxLines height
            // even when the value is one line (measured: 38px for "0.1.0" at
            // maxLines 2 versus 19px without). Every InfoRow was therefore
            // 44px tall and a four-row card carried 76px of empty space.
            child: SelectableText(
              value,
              style: text.bodyMedium?.copyWith(
                color: valueColor == null
                    ? p.textPrimary
                    : HaloColors.adapt(valueColor!, p.isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A Fluent badge: a tinted pill with the semantic colour at full strength.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final c = HaloColors.adapt(color, p.isDark);
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        // A tinted fill keeps the badge quiet; the text carries the colour.
        color: c.withValues(alpha: p.isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        border: Border.all(color: c.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: c),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: c,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A pill-shaped filter chip: one row of mutually exclusive filters.
///
/// The node and subscription pages both filter a long list by a group; they
/// used two different components for it (a hand-drawn pill on 节点, Material's
/// `ChoiceChip` on 订阅), so the same control looked heavier on one page and
/// changed height between them. One widget keeps the row height, radius and
/// type consistent.
class HaloFilterChip extends StatelessWidget {
  const HaloFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;

  /// Optional count on the trailing side, dimmer than the label.
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Material(
      color: selected ? p.accentSubtle : p.card,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? p.accent : p.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? p.accent : p.textSecondary,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? p.accent : p.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.title,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.compact = false,
  });

  final String message;

  /// Optional headline. When present it carries the weight and [message] drops
  /// to the explanatory line, which is what keeps a page-sized empty state from
  /// reading as one long sentence stuck in the middle of a card.
  final String? title;
  final IconData icon;
  final Widget? action;

  /// Tighter spacing for empty states that live inside a card rather than
  /// owning the page, so a 200px card does not pay for a 300px layout.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 24,
          vertical: compact ? 12 : 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 28 : 36, color: p.textTertiary),
            SizedBox(height: compact ? 6 : 10),
            if (title != null) ...[
              Text(
                title!,
                textAlign: TextAlign.center,
                style: text.titleSmall?.copyWith(
                  fontSize: 13.5,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
            ],
            Text(message, textAlign: TextAlign.center, style: text.bodySmall),
            if (action != null) ...[
              SizedBox(height: compact ? 10 : 14),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A labelled control whose label sits *above* the field.
///
/// Fluent keeps labels fixed; Material's `InputDecoration.labelText` floats
/// them onto the border line, which is what made the routing and subscription
/// forms look like a different design system applied to one page.
class HaloField extends StatelessWidget {
  const HaloField({
    super.key,
    required this.label,
    required this.child,
    this.hint,
  });

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: text.labelMedium?.copyWith(color: p.textSecondary)),
        const SizedBox(height: 4),
        child,
        if (hint != null) ...[
          const SizedBox(height: 3),
          Text(hint!, style: text.bodySmall?.copyWith(color: p.textTertiary)),
        ],
      ],
    );
  }
}

/// A compact dropdown that matches the form controls around it.
///
/// [DropdownButton] ignores [InputDecorationTheme] and forces a 48px tap
/// target, so a bare one next to a 32px text field left the two on different
/// baselines — visible in the node filter bar, where the search box and the
/// protocol/latency dropdowns were 36 and 48 respectively. Wrapping it in a
/// themed [InputDecorator] gives it the same fill, border, radius and height as
/// every other field, and keeps the popup behaviour Material already provides.
/// A compact combo box whose open list is drawn by this widget, not by
/// Material's popup route.
///
/// The previous version wrapped a [DropdownButton] in an [InputDecorator]: the
/// closed field was an outlined input (1px borderStrong, radius 4, 12px inset,
/// filled) while the open list was a Material popup (elevation 8, radius 4 but
/// a drop shadow, 0px inset, unfilled, its own row height). Measured side by
/// side, the two states did not look like the same control — which is exactly
/// what the review said.
///
/// The fix is to stop delegating the overlay. Both states now come from
/// [_HaloDropdownStyle], so the border, radius, fill, horizontal inset, font and
/// row height are the same object in both places and cannot drift apart.
///
/// Material's own dropdown was not configurable enough to close the gap:
/// `itemHeight` may not go below [kMinInteractiveDimension], the popup is a
/// route with its own barrier and shape, and `menuMaxHeight`/`offset` are the
/// only geometry knobs. Reproducing an outlined field inside that route would
/// have meant fighting it; drawing 40 lines of list is simpler and testable.
class HaloDropdown<T> extends StatefulWidget {
  const HaloDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.width,
    this.fontSize = 12.5,
  });

  final T? value;

  /// Label for [value]; the placeholder is [hint].
  final List<(T, String)> items;
  final ValueChanged<T?>? onChanged;
  final String? hint;

  /// Null means "size to content", bounded by the parent.
  final double? width;
  final double fontSize;

  @override
  State<HaloDropdown<T>> createState() => _HaloDropdownState<T>();
}

/// Every visual decision the dropdown makes, in one place.
///
/// Shared by the trigger and the open list. If this object is not used by both,
/// the two states will differ — which is the bug this class exists to prevent.
class _HaloDropdownStyle {
  const _HaloDropdownStyle({
    required this.filled,
    required this.fill,
    required this.border,
    required this.inset,
    required this.radius,
    required this.textStyle,
    required this.rowHeight,
    required this.hover,
  });

  final bool filled;
  final Color fill;
  final Color border;

  /// Horizontal padding of the text, identical in the field and the rows so the
  /// label does not jump sideways when the list opens.
  final double inset;
  final double radius;
  final TextStyle textStyle;
  final double rowHeight;
  final Color hover;

  static const insetValue = 10.0;

  /// Row height is the control height: a menu row that differs from the field
  /// it unfolds from is the specific mismatch the review reported.
  static const rowHeightValue = HaloMetrics.controlHeight;

  factory _HaloDropdownStyle.of(BuildContext context, double fontSize) {
    final p = HaloPalette.of(context);
    return _HaloDropdownStyle(
      filled: true,
      fill: p.input,
      border: p.borderStrong,
      inset: insetValue,
      radius: HaloMetrics.radius,
      textStyle: TextStyle(fontSize: fontSize, color: p.textPrimary),
      rowHeight: rowHeightValue,
      hover: p.cardHover,
    );
  }
}

class _HaloDropdownState<T> extends State<HaloDropdown<T>> {
  bool _open = false;
  bool _hovered = false;
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;
  final FocusNode _focus = FocusNode(debugLabel: 'halo-dropdown');

  bool get _enabled => widget.onChanged != null;

  T? get _value => widget.value;

  String? get _label {
    for (final (value, label) in widget.items) {
      if (value == _value) return label;
    }
    return null;
  }

  @override
  void dispose() {
    _removeOverlay();
    _focus.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
    _open = false;
  }

  void _toggle() {
    if (!_enabled) return;
    if (_open) {
      _close();
    } else {
      _show();
    }
  }

  void _close() {
    if (!_open) return;
    setState(_removeOverlay);
  }

  void _show() {
    final style = _HaloDropdownStyle.of(context, widget.fontSize);
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    _overlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // A transparent full-screen barrier: clicking anywhere else closes the
          // list, which is what a popup menu does and what a bare overlay would
          // not.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            // No gap: the open list is the field's own body, so it must join it
            // rather than float 2px below as a separate panel. With a gap the
            // field's 1px border and the list's 1px border left a seam that
            // read as two stacked controls.
            offset: Offset(0, size.height),
            showWhenUnlinked: false,
            child: Align(
              alignment: Alignment.topLeft,
              child: _HaloDropdownMenu<T>(
                style: style,
                width: size.width,
                items: widget.items,
                value: _value,
                // The border between the field and the list is the field's own
                // bottom edge, drawn by the menu's top border only.
                drawTopBorder: true,
                onPick: (picked) {
                  _close();
                  widget.onChanged?.call(picked);
                },
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_overlay!);
    setState(() => _open = true);
  }

  @override
  Widget build(BuildContext context) {
    final style = _HaloDropdownStyle.of(context, widget.fontSize);
    final p = HaloPalette.of(context);
    final label = _label;
    final shown = label ?? widget.hint ?? '';
    final isHint = label == null;

    final field = Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space) {
          _toggle();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape && _open) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: _toggle,
          child: CompositedTransformTarget(
            link: _link,
            child: Container(
              height: HaloMetrics.controlHeight,
              padding: EdgeInsets.symmetric(horizontal: style.inset),
              decoration: BoxDecoration(
                color: _hovered && _enabled ? p.cardHover : style.fill,
                // While open, the field's bottom corners square off so it joins
                // the list below it instead of ending in two rounded corners
                // with the list starting underneath.
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(style.radius),
                  topRight: Radius.circular(style.radius),
                  bottomLeft: Radius.circular(_open ? 0 : style.radius),
                  bottomRight: Radius.circular(_open ? 0 : style.radius),
                ),
                // The accent border marks focus, and it is the one thing that
                // changes between the two states — the list keeps the field's
                // neutral border, and is joined to it rather than detached.
                border: _open
                    ? Border(
                        left: BorderSide(color: p.accent),
                        right: BorderSide(color: p.accent),
                        top: BorderSide(color: p.accent),
                        bottom: BorderSide.none,
                      )
                    : Border.all(color: style.border, width: 1),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      shown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.textStyle.copyWith(
                        color: isHint
                            ? p.textTertiary
                            : (_enabled ? p.textPrimary : p.textTertiary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 16,
                    color: _enabled ? p.textSecondary : p.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return SizedBox(width: widget.width, child: field);
  }
}

/// The open list, drawn with the same style object as the trigger.
class _HaloDropdownMenu<T> extends StatefulWidget {
  const _HaloDropdownMenu({
    required this.style,
    required this.width,
    required this.items,
    required this.value,
    required this.onPick,
    this.drawTopBorder = true,
  });

  final _HaloDropdownStyle style;
  final double width;
  final List<(T, String)> items;
  final T? value;
  final ValueChanged<T> onPick;

  /// Whether to draw the seam between the field and the list.
  ///
  /// The two together are one control: the field owns its left, right and top
  /// edges and the list owns left, right and bottom, so neither draws a doubled
  /// line where they meet.
  final bool drawTopBorder;

  /// Enough to show eight rows before scrolling, which covers the filter lists
  /// the app actually ships without turning the menu into a page.
  static const maxRows = 8;

  @override
  State<_HaloDropdownMenu<T>> createState() => _HaloDropdownMenuState<T>();
}

class _HaloDropdownMenuState<T> extends State<_HaloDropdownMenu<T>> {
  int? _hoveredRow;

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final p = HaloPalette.of(context);
    final rows = widget.items.length;
    final listHeight =
        style.rowHeight *
            (rows < _HaloDropdownMenu.maxRows
                ? rows
                : _HaloDropdownMenu.maxRows) +
        2;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: widget.width,
        constraints: BoxConstraints(maxHeight: listHeight),
        decoration: BoxDecoration(
          color: p.card,
          // Only the bottom corners are rounded: the list continues the field
          // downward, so its top edge is a seam, not a corner.
          borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(style.radius),
            bottomRight: Radius.circular(style.radius),
          ),
          // One line at the seam and one closing the bottom, in the same colour
          // as the field's border. Drawing all four would double the seam with
          // the field's own bottom border.
          border: Border(
            left: BorderSide(color: style.border),
            right: BorderSide(color: style.border),
            bottom: BorderSide(color: style.border),
            top: widget.drawTopBorder
                ? BorderSide(color: style.border)
                : BorderSide.none,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(style.radius),
            bottomRight: Radius.circular(style.radius),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 1),
            shrinkWrap: true,
            itemCount: rows,
            itemExtent: style.rowHeight,
            itemBuilder: (context, index) {
              final (value, label) = widget.items[index];
              final selected = value == widget.value;
              final hovered = _hoveredRow == index;
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hoveredRow = index),
                onExit: (_) => setState(() => _hoveredRow = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onPick(value),
                  child: Container(
                    color: selected
                        ? p.accentSubtle
                        : (hovered ? style.hover : Colors.transparent),
                    padding: EdgeInsets.symmetric(horizontal: style.inset),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style.textStyle.copyWith(
                              color: selected ? p.textPrimary : p.textPrimary,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check, size: 14, color: p.accent),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One row of a [showHaloMenu] popup.
///
/// A sealed pair rather than a nullable list entry: a divider has no value and
/// no label, and giving it the same shape as a row would let a caller pass a
/// half-filled item by mistake.
sealed class HaloMenuEntry<T> {
  const HaloMenuEntry();
}

/// A selectable row.
final class HaloMenuItem<T> extends HaloMenuEntry<T> {
  const HaloMenuItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.shortcut,
    this.icon,
    this.enabled = true,
    this.danger = false,
  });

  final T value;
  final String label;

  /// Second line explaining what the action does, for menus whose entries are
  /// occasional rather than memorised. Present on the toolbar's 更多 menu.
  final String? subtitle;

  /// The keyboard equivalent, drawn in its own right-hand column.
  ///
  /// It used to be appended to the label with a literal tab:
  /// `Text('设为当前节点\tEnter')`. A tab is not a column — the renderer drew
  /// it as a run of spaces inside the sentence, so the shortcut ended up a
  /// ragged distance from the label and read as part of the action's name.
  final String? shortcut;

  final IconData? icon;
  final bool enabled;

  /// Renders the label in the danger colour. Deleting a node is not reversible
  /// by undo once the confirmation passes, so it must not look like 复制.
  final bool danger;
}

/// A hairline separator between groups of rows.
final class HaloMenuDivider<T> extends HaloMenuEntry<T> {
  const HaloMenuDivider();
}

/// A popup menu drawn by this app rather than by Flutter's popup route.
///
/// [showMenu] was the source of three separate complaints at once, and none of
/// them was reachable through its parameters:
///
///   * **Rows were 48 tall around 18px of text.** `PopupMenuItem.height`
///     defaults to [kMinInteractiveDimension], the Material *touch* target. That
///     is 30px of nothing per row; a ten-entry right-click menu stood 500px
///     tall and read as a mostly empty panel.
///   * **The width was forced to a multiple of 56px.** The route wraps its
///     content in `IntrinsicWidth(stepWidth: 56)`, so the menu was always
///     rounded up — up to 55px of dead space on the right, which is the other
///     half of "又大又空".
///   * **The text style could not be set from the theme.** With
///     `useMaterial3: true` the route reads `labelTextStyle`, not `textStyle`,
///     so the 12px entry in [popupMenuTheme] was silently ignored and every
///     menu in the app rendered at 13px semi-bold — the same weight as a card
///     title, one step *above* the button that opened it.
///
/// Everything here therefore uses the same numbers as [HaloDropdown]: 32px
/// rows, 10px inset, 4px radius, the same border and text style. A menu and the
/// field that unfolds it are the same control in two states, and drawing them
/// from one set of constants is the only way that stays true.
Future<T?> showHaloMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<HaloMenuEntry<T>> entries,
}) {
  final overlayState = Overlay.of(context);
  final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
  if (overlayBox == null || entries.isEmpty) return Future<T?>.value();

  final completer = Completer<T?>();
  late final OverlayEntry entry;

  void close([T? value]) {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete(value);
  }

  entry = OverlayEntry(
    builder: (_) => Stack(
      children: [
        // A full-screen barrier: clicking anywhere else dismisses the menu the
        // way a native one does, and a right-click elsewhere moves it.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
            onSecondaryTap: close,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _HaloMenuPositionDelegate(position),
            child: _HaloMenuPanel<T>(entries: entries, onPicked: close),
          ),
        ),
      ],
    ),
  );

  overlayState.insert(entry);
  return completer.future;
}

/// Places the panel at the pointer and keeps it on screen.
///
/// The delegate, rather than a predicted `Offset`, because the menu's size is
/// only known after it has been laid out: measuring first would mean building
/// it twice, and a second build is a second thing to keep in sync.
class _HaloMenuPositionDelegate extends SingleChildLayoutDelegate {
  const _HaloMenuPositionDelegate(this.anchor);

  final Offset anchor;

  /// Gap between the panel and the window edge when it has to be pushed back.
  static const margin = 4.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Right of the pointer, or left of it when that would overflow — the same
    // flip a native context menu performs near the right edge.
    var dx = anchor.dx;
    if (dx + childSize.width + margin > size.width) {
      dx = anchor.dx - childSize.width;
    }
    var dy = anchor.dy;
    if (dy + childSize.height + margin > size.height) {
      dy = anchor.dy - childSize.height;
    }
    // Then clamp, so a menu taller than the window is not pushed off the top.
    return Offset(
      dx.clamp(margin, math.max(margin, size.width - childSize.width - margin)),
      dy.clamp(margin, math.max(margin, size.height - childSize.height - margin)),
    );
  }

  @override
  bool shouldRelayout(_HaloMenuPositionDelegate oldDelegate) =>
      anchor != oldDelegate.anchor;
}

/// The menu surface: border, rows, dividers, hover and keyboard handling.
class _HaloMenuPanel<T> extends StatefulWidget {
  const _HaloMenuPanel({required this.entries, required this.onPicked});

  final List<HaloMenuEntry<T>> entries;
  final void Function([T? value]) onPicked;

  /// Rows scroll rather than growing past the window.
  static const maxHeight = 420.0;

  /// Narrow enough to read at a glance, wide enough for 「检查该节点连通性」.
  static const minWidth = 176.0;

  /// The shortcut column. Reserved only when some row has a shortcut, so a
  /// menu whose entries have none does not pay for an empty gutter.
  static const shortcutWidth = 56.0;

  @override
  State<_HaloMenuPanel<T>> createState() => _HaloMenuPanelState<T>();
}

class _HaloMenuPanelState<T> extends State<_HaloMenuPanel<T>> {
  final FocusNode _focus = FocusNode(debugLabel: 'halo-menu');

  /// Index into [widget.entries] of the row the keyboard is on. Null until the
  /// user presses an arrow, matching a native menu that opens with nothing
  /// highlighted.
  int? _highlighted;

  bool get _hasShortcut =>
      widget.entries.any((e) => e is HaloMenuItem<T> && e.shortcut != null);

  @override
  void initState() {
    super.initState();
    // Asked for explicitly rather than via `autofocus: true`. The menu is
    // inserted into an overlay *inside* an existing route, whose modal scope
    // already holds focus; autofocus only claims a scope that has no focused
    // descendant yet, so it silently did nothing and every key — Escape,
    // arrows, Enter — went to the page underneath.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      // A second request for the frame in which the panel is first laid out:
      // the node is attached by now but the manager defers the update.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final items = <int>[
      for (var i = 0; i < widget.entries.length; i++)
        if (widget.entries[i] case HaloMenuItem<T>(:final enabled) when enabled)
          i,
    ];
    if (items.isEmpty) return;
    final current = items.indexOf(_highlighted ?? -1);
    final next = current < 0
        ? (delta > 0 ? 0 : items.length - 1)
        : (current + delta).clamp(0, items.length - 1);
    setState(() => _highlighted = items[next]);
  }

  void _activate() {
    final index = _highlighted;
    if (index == null) return;
    if (widget.entries[index] case HaloMenuItem<T>(
      :final enabled,
      :final value,
    ) when enabled) {
      widget.onPicked(value);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        widget.onPicked();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        _activate();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: _HaloMenuPanel.minWidth,
          maxWidth: 380,
          maxHeight: _HaloMenuPanel.maxHeight,
        ),
        // IntrinsicWidth so the panel fits its longest row instead of a fixed
        // guess. Each row is a Row with a flexible label and a fixed-width
        // shortcut column, so the intrinsic width is label + column and the
        // shortcut lands on the panel's right edge for every row at once.
        child: IntrinsicWidth(
          // A Material ancestor, because text drawn outside one gets Flutter's
          // "missing material" decoration: every label came out underlined in
          // double yellow. The overlay this panel lives in has no Material
          // above it — HaloDropdown wraps its own overlay for the same reason.
          // Transparent, so the card surface below still shows through.
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(HaloMetrics.radius),
                border: Border.all(color: p.border),
                boxShadow: haloCardShadow(p),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(HaloMetrics.radius),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.entries.length; i++)
                        _buildEntry(context, i),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(BuildContext context, int index) {
    final entry = widget.entries[index];
    if (entry is HaloMenuDivider<T>) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(height: 1, color: HaloPalette.of(context).border),
      );
    }
    final item = entry as HaloMenuItem<T>;
    final p = HaloPalette.of(context);
    final highlighted = _highlighted == index;
    final danger = HaloColors.adapt(HaloColors.danger, p.isDark);
    final foreground = !item.enabled
        ? p.textTertiary
        : item.danger
        ? danger
        : p.textPrimary;

    return _HaloMenuRow(
      key: ValueKey('halo-menu-${item.value}'),
      // Two lines for an entry that explains itself, one control height for a
      // menu of short verbs. Both are measured, not guessed: 18px of text plus
      // padding, floored at the 32px control height.
      dense: item.subtitle == null,
      highlighted: highlighted,
      enabled: item.enabled,
      onHover: item.enabled ? () => setState(() => _highlighted = index) : null,
      onHoverExit: () => setState(() {
        if (_highlighted == index) _highlighted = null;
      }),
      onTap: item.enabled ? () => widget.onPicked(item.value) : null,
      child: Row(
        children: [
          if (item.icon != null) ...[
            Icon(item.icon, size: 15, color: foreground),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: foreground),
                ),
                if (item.subtitle != null)
                  Text(
                    item.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                  ),
              ],
            ),
          ),
          if (_hasShortcut) ...[
            const SizedBox(width: 16),
            // The box is reserved even for a row without a shortcut, so the
            // column is one edge for every row rather than a per-row position.
            SizedBox(
              width: _HaloMenuPanel.shortcutWidth,
              child: item.shortcut == null
                  ? null
                  : Text(
                      item.shortcut!,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One row's hover/press feedback, shared by every entry.
class _HaloMenuRow extends StatefulWidget {
  const _HaloMenuRow({
    super.key,
    required this.child,
    required this.dense,
    required this.highlighted,
    required this.enabled,
    required this.onTap,
    required this.onHover,
    required this.onHoverExit,
  });

  final Widget child;
  final bool dense;
  final bool highlighted;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onHover;
  final VoidCallback onHoverExit;

  @override
  State<_HaloMenuRow> createState() => _HaloMenuRowState();
}

class _HaloMenuRowState extends State<_HaloMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final active = widget.highlighted || _hovered;
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover?.call();
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onHoverExit();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          constraints: BoxConstraints(
            minHeight: widget.dense ? HaloMetrics.controlHeight : 0,
          ),
          color: active && widget.enabled ? p.cardHover : Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: _HaloDropdownStyle.insetValue,
            vertical: 4,
          ),
          alignment: Alignment.centerLeft,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Fluent toggle switch.
/// Material's switch is 52×32 with a 20px thumb, which reads as Material next
/// to Fluent controls. This is the Fluent geometry: a 40×20 track with a 12px
/// thumb, accent fill when on and a hairline outline when off, with hover and
/// press feedback on the track rather than the thumb.
class HaloSwitch extends StatefulWidget {
  const HaloSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;

  /// Null disables the control, matching the `onChanged` contract of the
  /// Material widgets it replaces.
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  State<HaloSwitch> createState() => _HaloSwitchState();
}

class _HaloSwitchState extends State<HaloSwitch> {
  bool _hovered = false;

  bool get _enabled => widget.onChanged != null;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final on = widget.value;
    // The off state is a transparent fill and the on state is solid: tweening
    // between them would run through translucent black (Colors.transparent is
    // transparent black, not "no colour"), which flashes a dark caption around
    // the track. Keep the RGB of the state being entered and move only alpha.
    final trackBase = !_enabled
        ? (p.isDark ? p.pressed : p.border)
        : on
        ? (_hovered ? HaloColors.primaryHover : HaloColors.primary)
        : p.cardHover;
    final track = trackBase.withValues(
      alpha: _enabled && !on && !_hovered ? 0 : 1,
    );
    final borderBase = _enabled ? p.borderStrong : p.border;
    final border = borderBase.withValues(alpha: on ? 0 : 1);

    return Semantics(
      label: widget.semanticLabel,
      toggled: on,
      enabled: _enabled,
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: _enabled ? () => widget.onChanged!(!on) : null,
          child: AnimatedContainer(
            duration: HaloMetrics.fastDuration,
            curve: HaloMetrics.fastCurve,
            width: 40,
            height: 20,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: border),
            ),
            child: AnimatedAlign(
              duration: HaloMetrics.fastDuration,
              curve: HaloMetrics.mediumCurve,
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: !_enabled
                      ? p.textTertiary
                      : on
                      ? Colors.white
                      : p.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A Fluent settings row: text on the left, control on the right, whole row
/// clickable while the control is enabled.
///
/// No horizontal padding: the row's text is the first thing in the card body
/// and must sit on the same left edge as the card title. It used to carry 4px,
/// so every switch row (系统代理, TUN, 开机自动启动) started 4px to the right of
/// the heading above it — small enough to be hard to name, large enough to make
/// a card look misaligned.
class HaloSwitchTile extends StatelessWidget {
  const HaloSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged!(!value) : null,
      borderRadius: BorderRadius.circular(HaloMetrics.radius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: text.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: enabled ? p.textPrimary : p.textTertiary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(subtitle!, style: text.bodySmall),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            HaloSwitch(
              value: value,
              onChanged: onChanged,
              semanticLabel: title,
            ),
          ],
        ),
      ),
    );
  }
}

/// Fluent selector bar: one outline around a set of segments, with the selected
/// segment raised onto the card surface.
class HaloSelector<T> extends StatelessWidget {
  const HaloSelector({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final List<(T value, String label)> options;
  final T value;
  final ValueChanged<T>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      height: HaloMetrics.controlHeight,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.isDark ? p.input : HaloColors.lightSurfaceAlt,
        borderRadius: BorderRadius.circular(HaloMetrics.radius + 1),
        border: Border.all(color: p.borderStrong),
      ),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: _Segment(
                label: option.$2,
                selected: option.$1 == value,
                onTap: enabled && onChanged != null
                    ? () => onChanged!(option.$1)
                    : null,
                palette: p,
                textTheme: text,
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.palette,
    required this.textTheme,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final HaloPalette palette;
  final TextTheme textTheme;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final selected = widget.selected;
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: HaloMetrics.fastDuration,
          curve: HaloMetrics.fastCurve,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Same rule as the sidebar: an unselected segment is a transparent
            // fill, so animate alpha of the state being entered rather than
            // tweening to transparent black.
            color: (selected ? p.card : p.pressed).withValues(
              alpha: selected || (_hovered && enabled) ? 1 : 0,
            ),
            borderRadius: BorderRadius.circular(HaloMetrics.radius),
            border: Border.all(
              color: p.border.withValues(alpha: selected ? 1 : 0),
            ),
            boxShadow: selected ? haloCardShadow(p) : const [],
          ),
          child: Text(
            widget.label,
            style: widget.textTheme.bodyLarge?.copyWith(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: !enabled
                  ? p.textTertiary
                  : selected
                  ? p.textPrimary
                  : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Maps runtime state to a colour, so every page colours status identically.
///
/// The returned value is the *light-mode* token; widgets push it through
/// [HaloColors.adapt] so dark mode gets the legible variant.
Color coreStateColor(CoreState state) => switch (state) {
  CoreState.running => HaloColors.success,
  CoreState.starting || CoreState.stopping => HaloColors.warning,
  CoreState.crashed || CoreState.failed => HaloColors.danger,
  _ => HaloColors.lightTextSecondary,
};

String coreStateLabel(CoreState state) => switch (state) {
  CoreState.running => '运行中',
  CoreState.starting => '启动中',
  CoreState.stopping => '停止中',
  CoreState.stopped => '已停止',
  CoreState.crashed => '异常',
  CoreState.failed => '异常',
};

/// Colours a TUN state identically everywhere it is shown.
///
/// `pending` is amber because it is a real wait (the user has a UAC window on
/// screen), `failed` is red because it carries an actionable `tunMessage`, and
/// `unsupported` is amber because the host can still explain what is missing.
Color tunStateColor(TunState state) => switch (state) {
  TunState.enabled => HaloColors.success,
  TunState.pending => HaloColors.warning,
  TunState.failed => HaloColors.danger,
  TunState.unsupported => HaloColors.warning,
  TunState.unverified => HaloColors.lightTextSecondary,
  TunState.disabled => HaloColors.lightTextSecondary,
};

String tunStateLabel(TunState state) => switch (state) {
  TunState.enabled => '已启用',
  TunState.disabled => '已关闭',
  // Not a generic "starting": the host is blocked on a Windows UAC prompt and
  // the user has to answer it for the state to move at all.
  TunState.pending => '等待管理员授权',
  TunState.failed => '失败',
  TunState.unsupported => '不支持',
  // Legacy value: only an old snapshot can report it, and it means "unknown",
  // not "this build cannot do TUN".
  TunState.unverified => '旧版状态未知',
};

String modeLabel(ProxyMode mode) => switch (mode) {
  ProxyMode.rule => '规则',
  ProxyMode.global => '全局',
  ProxyMode.direct => '直连',
};

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatTime(int ms) {
  if (ms <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String formatDateTime(int ms) {
  if (ms <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

/// Protocol badge, mirroring how the reference client tags node rows.
String protocolLabel(ProxyProtocol protocol) => protocol.label;

// ---------------------------------------------------------------------------
// 提示条
// ---------------------------------------------------------------------------

/// How long a floating message stays on screen.
///
/// Flutter's default is 4s for every message regardless of length, and the call
/// sites here had drifted to three different answers (the default, 2s, 8s) with
/// no rule behind any of them. The intent is "long enough to read once, short
/// enough not to sit on top of the page":
///
///   * 2s — the result is already visible (a copied link, a switch that moved).
///     The message only confirms it.
///   * 3s — one line stating what happened.
///   * 5s — a line carrying detail worth re-reading: counts of what was skipped,
///     a path, an error reason. Not the old 8s, which outlived the action that
///     caused it by long enough to look like part of the page.
abstract final class HaloToastDuration {
  static const confirm = Duration(seconds: 2);
  static const notice = Duration(seconds: 3);
  static const detail = Duration(seconds: 5);

  /// Longest any message is shown, so a very long error cannot extend it past
  /// [detail]. Anything that genuinely needs longer to read belongs in a dialog,
  /// not in a bar that covers the page.
  static const longest = detail;

  /// Picks a duration from the message itself, so a call site cannot forget to.
  ///
  /// Length stands in for "carries numbers or a path", which is what makes a
  /// message worth re-reading. A message with an action button keeps the
  /// caller's [fallback]: an action is still usable while the bar is up, and the
  /// caller knows whether it needs the extra time.
  static Duration forMessage(String message, {Duration? fallback}) {
    final chosen = fallback ?? (message.length > 30 ? detail : notice);
    return chosen > longest ? longest : chosen;
  }
}

/// Shows one floating message, replacing whatever is already on screen.
///
/// Replacing rather than queueing: pages that report a batch edit and then its
/// undo hint call this twice in a row, and two stacked bars used to overlap. The
/// older message is stale by then anyway.
void showHaloToast(
  BuildContext context,
  String message, {
  Duration? duration,
  SnackBarAction? action,
}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: HaloToastDuration.forMessage(message, fallback: duration),
        persist: false,
        // Flutter defaults `persist` to `action != null`, so every toast that
        // offers 查看 / 撤销 would stay on screen until it was dismissed by hand.
        // These messages are informational: the bar goes away on its own, and the
        // action is usable while it is up.
        action: action,
      ),
    );
}
