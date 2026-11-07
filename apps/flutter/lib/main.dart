import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/diagnostics/error_log.dart';
import 'src/state/app_controller.dart';
import 'src/theme.dart';
import 'src/ui/app.dart';
import 'src/ui/error_screen.dart';

/// Runtime theme choice, kept at the root so a change in settings can rebuild
/// the whole tree without passing a callback through every page.
final ValueNotifier<ThemeMode> haloThemeMode = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

/// Wall-clock data directory, matching the host's `%LOCALAPPDATA%\clash-halo`.
///
/// The host and the UI must resolve the same directory or the UI would show an
/// empty node list beside a running proxy. `HALO_DATA_DIR` overrides both, which
/// is what the runtime tests use.
String resolveDataDir() {
  final override = Platform.environment['HALO_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  final appDir = File(Platform.resolvedExecutable).parent;
  if (Platform.isWindows && File('${appDir.path}/portable.flag').existsSync()) {
    return '${appDir.path}${Platform.pathSeparator}user-data';
  }
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    return '$localAppData${Platform.pathSeparator}clash-halo';
  }
  return '${Directory.systemTemp.path}${Platform.pathSeparator}clash-halo';
}

Future<void> main() async {
  final dataDir = resolveDataDir();
  final errorLog = ErrorLog(dataDir);
  // Installed before anything else can throw. The default release error widget
  // is an empty grey box, which is indistinguishable from a window that never
  // rendered, so a failed first build would otherwise be unreportable.
  ErrorWidget.builder = (details) =>
      haloErrorWidget(details, logPath: errorLog.path);
  // Build and layout errors arrive here; anything that escapes the first build
  // entirely arrives at the platform handler below.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    errorLog.record(
      details.exception,
      details.stack,
      source: details.library ?? 'flutter',
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    errorLog.record(error, stack, source: 'uncaught');
    return true;
  };
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(dataDir: dataDir);
  // Start after the first frame has painted. The old path ran the whole
  // synchronous prefix of start() — including opening the SQLite database and
  // running its migrations — before runApp, so a large library or a slow
  // migration directly delayed the window's first paint. Deferring the work
  // lets the window come up immediately; the store-open path invalidates the
  // pages' caches and re-reads the saved theme once it lands.
  unawaited(() async {
    await WidgetsBinding.instance.endOfFrame;
    await controller.start();
  }());
  runApp(HaloRoot(controller: controller));
}

class HaloRoot extends StatefulWidget {
  const HaloRoot({super.key, required this.controller});

  final AppController controller;

  @override
  State<HaloRoot> createState() => _HaloRootState();
}

class _HaloRootState extends State<HaloRoot> with WidgetsBindingObserver {
  /// Drives the native caption colour; the runner cannot read the app's own
  /// theme choice, only Windows'.
  static const _windowTheme = MethodChannel('clash_halo/theme');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    haloThemeMode.addListener(_applyWindowTheme);
    // Restore the saved theme choice; the settings page writes it back. Read
    // through the non-throwing accessor: an exception here would abort the
    // first build, which is exactly how a missing database used to turn the
    // whole window into a blank grey rectangle.
    //
    // The store opens after the first frame now, so this first read may see
    // "no database yet"; the listener below re-reads once the store has
    // opened (its first connection-state notification follows it).
    _restoreSavedTheme();
    widget.controller.connectionRevision.addListener(_restoreSavedTheme);
    _applyWindowTheme();
  }

  void _restoreSavedTheme() {
    final saved = widget.controller.storedSetting('theme.mode');
    final restored = resolveThemeOverride() ?? _modeFrom(saved);
    if (restored != haloThemeMode.value) {
      haloThemeMode.value = restored;
    }
  }

  @override
  void dispose() {
    haloThemeMode.removeListener(_applyWindowTheme);
    widget.controller.connectionRevision.removeListener(_restoreSavedTheme);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _applyWindowTheme();

  void _applyWindowTheme() {
    if (!Platform.isWindows) return;
    final dark = switch (haloThemeMode.value) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark,
    };
    // A missing handler (widget tests, an older runner) must never break the
    // window; the caption simply stays on the system theme.
    unawaited(
      _windowTheme.invokeMethod<void>('setDark', dark).catchError((Object _) {}),
    );
  }

  static ThemeMode _modeFrom(String? saved) => switch (saved) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: haloThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Clash Halo',
        debugShowCheckedModeBanner: false,
        theme: buildHaloTheme(Brightness.light),
        darkTheme: buildHaloTheme(Brightness.dark),
        themeMode: mode,
        builder: (context, child) => DefaultSelectionStyle(
          selectionColor: HaloColors.primary.withValues(alpha: 0.25),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: HaloApp(controller: widget.controller)),
      ),
    );
  }
}

/// Theme override for the runtime checks, mirroring `HALO_DATA_DIR`.
///
/// Verifying a colour scheme means rendering it, and writing `theme.mode` into
/// a database first would make the check depend on the database working.
ThemeMode? resolveThemeOverride() =>
    switch (Platform.environment['HALO_THEME']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
