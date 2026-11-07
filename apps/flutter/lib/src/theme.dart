import 'package:flutter/material.dart';

/// Fluent Design colour system.
///
/// Three layers, and every widget should take its colour from the layer it
/// belongs to rather than inventing one:
///
///   * **neutrals** — canvas, card and input surfaces, plus the three text
///     levels. These are the only colours that carry the light/dark switch.
///   * **accent** — the brand violet. One ramp with rest/hover/pressed plus a
///     subtle fill for selection, so pressed is visibly darker than hover
///     instead of the near-identical pair this used to have.
///   * **semantic** — success/warning/danger/info. Each has a *light* and a
///     *dark* value: the light-mode greens and reds are far too dark to read on
///     a #2A2A2A card, which is why status text used to disappear in dark mode.
///
/// [adapt] is the bridge for the semantic layer: widgets receive a semantic
/// colour without carrying a [BuildContext] through every helper, and it maps
/// the enum-level colour to the value that is legible on the current surface.
abstract final class HaloColors {
  // ---- accent (brand violet) -------------------------------------------
  static const primary = Color(0xFF6B4FBB);
  static const primaryHover = Color(0xFF7B5FCC);
  static const primaryPressed = Color(0xFF5A3FA6);

  /// Accent for text and icons in dark mode, where #6B4FBB has too little
  /// contrast against the card surface.
  static const primaryDark = Color(0xFFB4A0EA);

  /// Fill behind a selected navigation item or a pressed accent control.
  static const primarySubtleLight = Color(0xFFEFEBF9);
  static const primarySubtleDark = Color(0xFF342A4E);

  // ---- neutrals, light -------------------------------------------------
  static const lightBackground = Color(0xFFF3F3F3);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceAlt = Color(0xFFF7F7F7);
  static const lightSurfacePressed = Color(0xFFEDEDED);
  static const lightBorder = Color(0xFFE5E5E5);
  static const lightBorderStrong = Color(0xFFD6D6D6);
  static const lightTextPrimary = Color(0xFF1B1B1B);
  static const lightTextSecondary = Color(0xFF616161);
  static const lightTextTertiary = Color(0xFF8A8A8A);

  // ---- neutrals, dark --------------------------------------------------
  static const darkBackground = Color(0xFF1F1F1F);
  static const darkSurface = Color(0xFF2A2A2A);
  static const darkSurfaceAlt = Color(0xFF323232);
  static const darkSurfacePressed = Color(0xFF383838);
  static const darkBorder = Color(0xFF3D3D3D);
  static const darkBorderStrong = Color(0xFF4A4A4A);
  static const darkTextPrimary = Color(0xFFF2F2F2);
  static const darkTextSecondary = Color(0xFFB4B4B4);
  static const darkTextTertiary = Color(0xFF8C8C8C);

  // ---- semantic, light -------------------------------------------------
  static const success = Color(0xFF107C10);
  static const warning = Color(0xFF9D5D00);
  static const danger = Color(0xFFC42B1C);
  static const info = Color(0xFF0F6CBD);

  // ---- semantic, dark --------------------------------------------------
  static const successDark = Color(0xFF54B054);
  static const warningDark = Color(0xFFE0A33C);
  static const dangerDark = Color(0xFFFF7A70);
  static const infoDark = Color(0xFF6CB4E8);

  /// Maps a semantic or neutral token to the value that reads correctly on
  /// [dark]. Unknown colours pass through untouched, so custom tints survive.
  static Color adapt(Color color, bool dark) {
    if (!dark) return color;
    if (color == success) return successDark;
    if (color == warning) return warningDark;
    if (color == danger) return dangerDark;
    if (color == info) return infoDark;
    if (color == lightTextPrimary) return darkTextPrimary;
    if (color == lightTextSecondary) return darkTextSecondary;
    if (color == lightTextTertiary) return darkTextTertiary;
    if (color == lightBorder) return darkBorder;
    if (color == lightBorderStrong) return darkBorderStrong;
    return color;
  }
}

/// A fully transparent version of [color] that keeps its RGB.
///
/// Animating a fill to or from [Colors.transparent] is not a fade:
/// `Colors.transparent` is transparent **black**, and `ColorTween` interpolates
/// every ARGB channel, so a light hover fill passes through translucent dark
/// grey on the way in and out. On the sidebar that reads as a black frame
/// flashing as the pointer crosses the items. Fading the destination colour's
/// own alpha keeps the hue constant and only the opacity moves.
Color haloHidden(Color color) => color.withValues(alpha: 0);

/// The neutral layer resolved for the current brightness.
///
/// Widgets read `HaloPalette.of(context)` instead of writing
/// `dark ? HaloColors.darkX : HaloColors.lightX`, which is how the light-mode
/// tokens leaked into dark mode in the first place.
@immutable
class HaloPalette {
  const HaloPalette({
    required this.isDark,
    required this.canvas,
    required this.card,
    required this.cardHover,
    required this.input,
    required this.pressed,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSubtle,
    required this.onAccent,
    required this.shadow,
  });

  final bool isDark;
  final Color canvas;
  final Color card;
  final Color cardHover;
  final Color input;
  final Color pressed;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color accentSubtle;
  final Color onAccent;
  final Color shadow;

  static const _light = HaloPalette(
    isDark: false,
    canvas: HaloColors.lightBackground,
    card: HaloColors.lightSurface,
    cardHover: HaloColors.lightSurfaceAlt,
    input: HaloColors.lightSurface,
    pressed: HaloColors.lightSurfacePressed,
    border: HaloColors.lightBorder,
    borderStrong: HaloColors.lightBorderStrong,
    textPrimary: HaloColors.lightTextPrimary,
    textSecondary: HaloColors.lightTextSecondary,
    textTertiary: HaloColors.lightTextTertiary,
    accent: HaloColors.primary,
    accentSubtle: HaloColors.primarySubtleLight,
    onAccent: Colors.white,
    shadow: Color(0x14000000),
  );

  static const _dark = HaloPalette(
    isDark: true,
    canvas: HaloColors.darkBackground,
    card: HaloColors.darkSurface,
    cardHover: HaloColors.darkSurfaceAlt,
    input: HaloColors.darkSurfaceAlt,
    pressed: HaloColors.darkSurfacePressed,
    border: HaloColors.darkBorder,
    borderStrong: HaloColors.darkBorderStrong,
    textPrimary: HaloColors.darkTextPrimary,
    textSecondary: HaloColors.darkTextSecondary,
    textTertiary: HaloColors.darkTextTertiary,
    accent: HaloColors.primaryDark,
    accentSubtle: HaloColors.primarySubtleDark,
    onAccent: Colors.white,
    shadow: Color(0x33000000),
  );

  static HaloPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  static HaloPalette byBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;
}

/// [HaloColors.adapt] for call sites that already have a [BuildContext].
Color haloAdapt(BuildContext context, Color color) =>
    HaloColors.adapt(color, Theme.of(context).brightness == Brightness.dark);

/// Fluent geometry. Controls are 4px, containers 8px, and the two header bands
/// share one height so the sidebar divider lines up with the page header.
abstract final class HaloMetrics {
  static const radius = 4.0;
  static const radiusCard = 8.0;

  static const sidebarWidth = 200.0;
  static const logoBarHeight = 56.0;

  /// The header row above every page. One 32px control tall plus the
  /// title/subtitle stack beside it, with 4px of breathing room on each side.
  static const pageHeaderHeight = 56.0;

  /// Height of the always-visible status strip. Kept below the control height so
  /// it reads as chrome rather than as a row of buttons.
  static const statusBarHeight = 32.0;

  static const contentPadding = 16.0;
  static const scrollbarThickness = 8.0;

  /// Vertical rhythm on a page of stacked cards.
  ///
  /// One step, used *everywhere* a card meets another card or the banner above
  /// it. The overview page used to put 8px below each card, 8px between the
  /// banner and the grid, and 0px between the last card of a column and the
  /// full-width card underneath — three different answers to the same question,
  /// which is exactly what "the spacing is uneven" looks like.
  static const cardGap = 12.0;

  /// The step *inside* a card, between two blocks of content (a switch row and
  /// its caption, a detail list and the buttons above it).
  ///
  /// 12 outside, 8 inside: a card must be tighter than the gaps that separate
  /// it from its neighbours, or a stack of cards reads as one long table.
  static const blockGap = 8.0;

  /// Two lines of the same block (a name and its endpoint, a caption under the
  /// control it explains). Half of [blockGap], so a paragraph of caption looks
  /// like one block rather than several.
  static const lineGap = 4.0;

  /// The tightest step: a label and the number under it, a headline and its
  /// one-line subtitle. Anything closer than this merges into one line.
  static const hairGap = 2.0;

  /// Between consecutive rows of a label/value list.
  ///
  /// Between [lineGap] and [blockGap]: rows of text need more air than two
  /// lines of one sentence, but a list of six facts must not read as six
  /// separate blocks either.
  static const rowGap = 6.0;

  /// Standard control height (buttons, inputs, comboboxes).
  ///
  /// 32 is Fluent's desktop control height. The 48 this used to carry was
  /// Material's touch target leaking into a mouse-and-keyboard app: every
  /// toolbar, filter row and dialog grew a third taller than its content, and
  /// the buttons read as oversized next to 13–14px text.
  ///
  /// The reason it was raised — `DropdownButton` refuses menu rows below
  /// [kMinInteractiveDimension] — no longer applies: [HaloDropdown] draws its
  /// own list, so the trigger and its rows are both 32.
  static const controlHeight = 32.0;

  /// Flutter's minimum interactive dimension, kept for Material widgets that
  /// require a touch-sized target (dialog actions). Halo's own controls use
  /// [controlHeight]; do not copy this into page layouts.
  static const touchTarget = 48.0;

  /// Navigation item height; slightly taller than a control so the list breathes.
  static const navItemHeight = 34.0;

  /// Fluent's easing pair. Hover/press feedback is short; larger transitions
  /// stay under 250ms so the UI never feels sluggish.
  static const fastCurve = Curves.easeOut;
  static const fastDuration = Duration(milliseconds: 120);
  static const mediumCurve = Curves.easeOutCubic;
  static const mediumDuration = Duration(milliseconds: 220);
}

/// The one style a card uses to render a *number* rather than a sentence.
///
/// A dashboard is opened to read values — latency, throughput, an exit address.
/// They used to be set ad hoc (10.5, 11, 12, 12.5, 13, 13.5 and 14 all appear in
/// the old overview page), so 0 B/s was quieter than the caption explaining it
/// and nothing on the page read as the thing to look at. One tabular-figure
/// style, one step above body text, gives every metric the same weight.
TextStyle haloMetricStyle(
  BuildContext context, {
  double size = 20,
  Color? color,
}) {
  final p = HaloPalette.of(context);
  return TextStyle(
    fontSize: size,
    height: 1.15,
    fontWeight: FontWeight.w600,
    fontFamily: 'Consolas',
    // Digits must not shift the layout as a rate changes width.
    fontFeatures: const [FontFeature.tabularFigures()],
    color: color ?? p.textPrimary,
  );
}

/// Card elevation. Fluent keeps depth subtle: a 1px stroke does most of the
/// work and the shadow only separates the card from the canvas.
List<BoxShadow> haloCardShadow(HaloPalette palette) => [
  BoxShadow(color: palette.shadow, blurRadius: 4, offset: const Offset(0, 1)),
];

ThemeData buildHaloTheme(Brightness brightness) {
  final p = HaloPalette.byBrightness(brightness);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: HaloColors.primaryHover,
    onSecondary: Colors.white,
    error: HaloColors.adapt(HaloColors.danger, p.isDark),
    onError: Colors.white,
    surface: p.card,
    onSurface: p.textPrimary,
    surfaceContainerHighest: p.input,
    outline: p.borderStrong,
    outlineVariant: p.border,
  );

  final text = _textTheme(p);
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.canvas,
    dividerColor: p.border,
    textTheme: text,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radiusCard),
        side: BorderSide(color: p.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.textSecondary, size: 16),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(HaloMetrics.scrollbarThickness),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(
        p.isDark ? HaloColors.darkTextTertiary : HaloColors.lightTextTertiary,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: _accentButton(p, text)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _outlineButton(p, text),
    ),
    textButtonTheme: TextButtonThemeData(style: _textButton(p, text)),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        // 36 with visualDensity.compact at the call sites lands on 28: an icon
        // button is a mouse target, not a finger target. The previous default
        // (48, or 40 after compact) was what made five icon actions on a rules
        // row occupy a sixth of the width and inflate the row to 54px.
        minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
        maximumSize: const WidgetStatePropertyAll(Size(36, 36)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HaloMetrics.radius),
          ),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? p.textTertiary
              : (s.contains(WidgetState.hovered) ? p.accent : p.textSecondary),
        ),
      ),
    ),
    // Dropdowns are form controls like any other. Sized here rather than at
    // each call site: there are five of them across three pages, and the two in
    // the node filter bar had drifted to a bare 48px text row while the search
    // box beside them was 36.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : p.textTertiary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.borderStrong,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.accent,
      inactiveTrackColor: p.border,
      thumbColor: p.accent,
      overlayColor: p.accent.withValues(alpha: 0.12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.input,
      // Sized for the 32px box: 32 - 2*1px border - ~18px line box = 12, split
      // evenly. contentPadding is the lever, not constraints — constraints are a
      // minimum and the text's own line box overrides them.
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      constraints: const BoxConstraints(minHeight: HaloMetrics.controlHeight),
      // Material's default prefix/suffix icon box is 48x48 — a touch-target
      // size that silently raises the whole field to 48 no matter what
      // contentPadding says. A 16px glyph needs 28 to sit next to the text.
      prefixIconConstraints: const BoxConstraints(
        minWidth: 30,
        minHeight: 22,
        maxHeight: 22,
      ),
      suffixIconConstraints: const BoxConstraints(
        minWidth: 30,
        minHeight: 22,
        maxHeight: 22,
      ),
      hintStyle: text.bodyMedium?.copyWith(color: p.textTertiary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        borderSide: BorderSide(color: p.borderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        borderSide: BorderSide(color: p.borderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        borderSide: BorderSide(color: p.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        borderSide: BorderSide(
          color: HaloColors.adapt(HaloColors.danger, p.isDark),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radiusCard),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    // The popup a DropdownButton opens is a menu route, so its geometry comes
    // from here. It used radiusCard (8) and had no elevation, which made the
    // open list look like a floating card instead of the sheet that just
    // unfolded from the 4dp-radius field above it.
    popupMenuTheme: PopupMenuThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        side: BorderSide(color: p.border),
      ),
      textStyle: text.bodyMedium?.copyWith(fontSize: 12, color: p.textPrimary),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark ? p.cardHover : const Color(0xFF2B2B2B),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: p.isDark ? p.cardHover : const Color(0xFF2B2B2B),
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        border: Border.all(color: p.isDark ? p.border : Colors.transparent),
      ),
      textStyle: const TextStyle(fontSize: 12, color: Colors.white),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelColor: p.accent,
      unselectedLabelColor: p.textSecondary,
      indicatorColor: p.accent,
      dividerColor: p.border,
      labelStyle: text.titleMedium,
      unselectedLabelStyle: text.bodyMedium,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.border,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.textSecondary,
      textColor: p.textPrimary,
      dense: true,
      // DropdownMenuItem rows are ListTiles. Without these the open list had
      // 48px rows next to a 32px trigger.
      minVerticalPadding: 2,
      horizontalTitleGap: 8,
      titleTextStyle: const TextStyle(fontSize: 12),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.24),
      selectionHandleColor: p.accent,
    ),
  );
}

/// Segoe UI is the Fluent typeface; the CJK fallbacks matter because most of
/// the interface is Chinese and Segoe UI has no glyphs for it.
const _fontFamily = 'Segoe UI';
const _fontFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Segoe UI Variable Text',
  'Noto Sans SC',
];

/// Fluent type ramp, tuned for a dense desktop window: 11.5 caption, 13 body,
/// 14 body-strong, 18 title.
///
/// The previous ramp ran 12/14/16/20. At 200% display scaling that made card
/// titles (16) read as page titles and pushed whole toolbars out of the
/// viewport; the desktop scale below keeps one clear step between a heading and
/// the text it introduces.
TextTheme _textTheme(HaloPalette p) {
  final primary = TextStyle(
    fontSize: 13,
    height: 1.45,
    color: p.textPrimary,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
  );
  return TextTheme(
    // 18 / title — page titles and dialog titles
    displaySmall: primary.copyWith(
      fontSize: 18,
      height: 1.35,
      fontWeight: FontWeight.w600,
    ),
    titleLarge: primary.copyWith(
      fontSize: 18,
      height: 1.35,
      fontWeight: FontWeight.w600,
    ),
    // 14 / body strong — card and section titles
    titleMedium: primary.copyWith(
      fontSize: 14,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: primary.copyWith(
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    // 13 / body
    bodyLarge: primary,
    bodyMedium: primary.copyWith(color: p.textSecondary),
    // 11.5 / caption
    bodySmall: primary.copyWith(
      fontSize: 11.5,
      height: 1.4,
      color: p.textSecondary,
    ),
    labelLarge: primary.copyWith(
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: primary.copyWith(fontSize: 11.5, fontWeight: FontWeight.w600),
    labelSmall: primary.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: p.textTertiary,
    ),
  );
}

ButtonStyle _accentButton(HaloPalette p, TextTheme text) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(0, HaloMetrics.controlHeight),
    ),
    // Material pads the tap target to 48 regardless of minimumSize; that is
    // where the 48px buttons came from. shrinkWrap removes the padding, and the
    // fixedSize below then makes the box exactly one control tall instead of
    // whatever the label happens to measure.
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    fixedSize: const WidgetStatePropertyAll(
      Size.fromHeight(HaloMetrics.controlHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 0),
    ),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    backgroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled)
          ? p.border
          : s.contains(WidgetState.pressed)
          ? HaloColors.primaryPressed
          : s.contains(WidgetState.hovered)
          ? HaloColors.primaryHover
          : HaloColors.primary,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? p.textTertiary : Colors.white,
    ),
    elevation: const WidgetStatePropertyAll(0),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
      ),
    ),
  );
}

ButtonStyle _outlineButton(HaloPalette p, TextTheme text) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(0, HaloMetrics.controlHeight),
    ),
    // Material pads the tap target to 48 regardless of minimumSize; that is
    // where the 48px buttons came from. shrinkWrap removes the padding, and the
    // fixedSize below then makes the box exactly one control tall instead of
    // whatever the label happens to measure.
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    fixedSize: const WidgetStatePropertyAll(
      Size.fromHeight(HaloMetrics.controlHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 0),
    ),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    backgroundColor: WidgetStateProperty.resolveWith(
      // Material tweens its background colour, so the idle state must be a
      // transparent *instance of the hover colour*, not transparent black —
      // otherwise every hover passes through a dark wash. See haloHidden.
      (s) => s.contains(WidgetState.pressed)
          ? p.pressed
          : s.contains(WidgetState.hovered)
          ? p.cardHover
          : haloHidden(p.cardHover),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? p.textTertiary : p.textPrimary,
    ),
    side: WidgetStatePropertyAll(BorderSide(color: p.borderStrong)),
    elevation: const WidgetStatePropertyAll(0),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
      ),
    ),
  );
}

ButtonStyle _textButton(HaloPalette p, TextTheme text) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(0, HaloMetrics.controlHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 0),
    ),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    backgroundColor: WidgetStateProperty.resolveWith(
      // Material tweens its background colour, so the idle state must be a
      // transparent *instance of the hover colour*, not transparent black —
      // otherwise every hover passes through a dark wash. See haloHidden.
      (s) => s.contains(WidgetState.pressed)
          ? p.pressed
          : s.contains(WidgetState.hovered)
          ? p.cardHover
          : haloHidden(p.cardHover),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? p.textTertiary : p.textPrimary,
    ),
    elevation: const WidgetStatePropertyAll(0),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
      ),
    ),
  );
}
