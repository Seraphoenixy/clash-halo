import 'package:flutter/material.dart';

import '../../theme.dart';

/// A resizable table's column definition.
///
/// Extracted after the node table grew one: both tables want the same behaviour
/// (headers that drag, widths that survive a rebuild, a minimum below which a
/// column stops being readable), and having written it once for 节点 it is
/// cheaper to reuse than to describe again.
class TableColumn {
  const TableColumn({
    required this.label,
    required this.defaultWidth,
    required this.minWidth,
    this.numeric = false,
  });

  final String label;

  /// The width used before anyone drags anything. Chosen so every column fits
  /// the window at 100%: a column only reachable by scrolling reads as missing.
  final double defaultWidth;

  /// Below this the header or the content stops being legible.
  final double minWidth;

  /// Right-aligned: numbers are compared by their last digit, not their first.
  final bool numeric;
}

const double kResizerWidth = 7;
const double kTableLead = 8;
const double kTableTail = 4;

/// Width of every column, shared by the header and all rows.
///
/// A `ChangeNotifier` rather than lifted state because a drag has to repaint the
/// whole table: listening only around the header resized the titles while the
/// body kept its old widths, so the columns stopped lining up.
class TableColumnWidths extends ChangeNotifier {
  TableColumnWidths(this.columns) {
    for (var i = 0; i < columns.length; i++) {
      _widths[i] = columns[i].defaultWidth;
    }
  }

  final List<TableColumn> columns;
  final Map<int, double> _widths = {};

  double operator [](int index) {
    if (index < 0 || index >= columns.length) return 0;
    return _widths[index] ?? columns[index].defaultWidth;
  }

  /// Applies a drag delta, clamped so a column can never be squeezed to nothing:
  /// a zero-width column is indistinguishable from a missing one.
  void resize(int index, double delta) {
    if (index < 0 || index >= columns.length) return;
    final next = (this[index] + delta).clamp(columns[index].minWidth, 520.0);
    if ((next - this[index]).abs() < 0.5) return;
    _widths[index] = next;
    notifyListeners();
  }

  /// Total width the table needs, including the resizer slot after every column
  /// and the leading/trailing gaps.
  ///
  /// Counting only the column widths leaves the row wider than the box it was
  /// given, which Flutter reports as an overflow: the resizer slots are part of
  /// the layout, not decoration.
  double get total {
    var sum = 0.0;
    for (var i = 0; i < columns.length; i++) {
      sum += this[i];
    }
    return sum + kResizerWidth * columns.length + kTableLead + kTableTail;
  }
}

/// The sort indicator, with a permanently reserved slot.
///
/// Rendering the arrow only on the sorted column made the headings shift
/// sideways the moment a sort was applied: the label lost 13 px to the arrow and
/// every heading in that row moved. Reserving the space unconditionally means
/// clicking a header changes the arrow's glyph, not the layout.
///
/// [ascending] is null when the column is not the active sort, in which case the
/// slot is still occupied but empty.
class SortArrowSlot extends StatelessWidget {
  const SortArrowSlot({super.key, required this.ascending, this.size = 9});

  final bool? ascending;
  final double size;

  /// Width of the whole slot, including the gap before the glyph.
  ///
  /// This width is taken from the label on every column, sorted or not, so with
  /// ten columns it costs 90 px of the window at 9 px each. A Material arrow at
  /// its natural 11 px plus a 2 px gap cost 13 and pushed three headings into
  /// ellipsis, which traded a jumping layout for an unreadable one.
  static const double width = 9;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final dir = ascending;
    return SizedBox(
      width: width,
      child: dir == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 1),
              child: Icon(
                dir ? Icons.arrow_upward : Icons.arrow_downward,
                size: size,
                color: p.textSecondary,
              ),
            ),
    );
  }
}

/// A fixed-width cell that clips its content instead of overflowing.
class CellBox extends StatelessWidget {
  const CellBox({
    super.key,
    required this.width,
    required this.child,
    this.alignRight = false,
    this.onTap,
  });

  final double width;
  final Widget child;
  final bool alignRight;

  /// When set, the whole column width becomes one tap target.
  ///
  /// The 8 px gutter stays *inside* the target. It used to sit outside the
  /// InkWell, so the last 8 px of every header cell — right next to the resize
  /// handle — neither sorted nor resized, and the boundary between "click" and
  /// "drag" was a 16 px band of nothing instead of a line.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = alignRight
        ? Align(alignment: Alignment.centerRight, child: child)
        : child;
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: content,
    );
    return SizedBox(
      width: width,
      child: onTap == null ? padded : InkWell(onTap: onTap, child: padded),
    );
  }
}

/// A draggable divider after a column.
///
/// The hit area is 7 px wide while the visible line is 1 px, and the height is
/// explicit: laid out inside a Row without one, a handle like this was 0 px tall
/// with an empty hit area, so the drag never started and the column could not be
/// resized despite the callback being wired correctly.
class ColumnResizer extends StatefulWidget {
  const ColumnResizer({
    super.key,
    required this.onDelta,
    this.height = 34,
  });

  final ValueChanged<double> onDelta;
  final double height;

  @override
  State<ColumnResizer> createState() => _ColumnResizerState();
}

class _ColumnResizerState extends State<ColumnResizer> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {},
        onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
        child: SizedBox(
          width: kResizerWidth,
          height: widget.height,
          child: Center(
            child: Container(
              width: 1,
              color: _hovering ? p.borderStrong : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}
