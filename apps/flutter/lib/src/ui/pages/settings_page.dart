import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_storage/halo_storage.dart';

import '../../../main.dart' show haloThemeMode;
import '../../ipc/halo_client.dart' show HostConnectionState;
import '../../platform/win_file_dialog.dart';
import '../../state/app_controller.dart';
import '../../state/diagnostics.dart';
import '../../state/routing_settings.dart';
import '../../theme.dart';
import '../app.dart';
import '../widgets.dart';

/// Shown in 「关于」 and in the diagnostic text. One constant so the two cannot
/// disagree once a build stamps a real version.
const String kSettingsAppVersion = '0.1.0';

/// One selectable log level, with the words the dropdown shows.
class LogLevelChoice {
  const LogLevelChoice(this.value, this.label);

  /// What the generator writes into `log.level`; must stay within [kLogLevels].
  final String value;
  final String label;
}

/// Presentational order, quietest first, so the list reads as a scale.
const List<LogLevelChoice> kLogLevelChoices = [
  LogLevelChoice('silent', '静默（不写日志）'),
  LogLevelChoice('error', '错误'),
  LogLevelChoice('warn', '警告（默认）'),
  LogLevelChoice('info', '信息'),
  LogLevelChoice('debug', '调试（日志明显变大）'),
];

/// The label for a stored level, falling back to the default's label.
String logLevelLabel(String value) => kLogLevelChoices
    .firstWhere((c) => c.value == value, orElse: () => kLogLevelChoices[2])
    .label;

/// Concurrency values offered for speed testing. All within the 1..32 the host
/// accepts, so the dropdown cannot produce a value that needs clamping.
const List<int> kSpeedConcurrencyChoices = [1, 2, 4, 8, 16, 32];

/// Settings: theme, lifecycle expectations and data maintenance.
/// Assembles the diagnostic input from live state.
///
/// A top-level function rather than a method on the page so a test can build it
/// against a database that really does contain secrets, and assert none of them
/// reach the text. The page only copies; the decision about *what* is safe
/// belongs here, where it can be pinned.
DiagnosticsInput diagnosticsFor(
  AppController c, {
  required String themeMode,
  required RoutingSettings routing,
  required int concurrency,
}) {
  final snap = c.snapshot;
  return DiagnosticsInput(
    appVersion: kSettingsAppVersion,
    hostVersion: snap?.hostVersion ?? '—',
    coreVersion: snap?.coreVersion ?? '—',
    dataDir: c.dataDir,
    connectionLabel: switch (c.connection) {
      HostConnectionState.connected => '已连接',
      HostConnectionState.connecting => '连接中',
      HostConnectionState.versionMismatch => '协议版本不一致',
      HostConnectionState.disconnected => '已断开',
      HostConnectionState.idle => '未连接',
    },
    coreStateLabel: switch (snap?.coreState) {
      CoreState.running => '运行中',
      CoreState.starting => '启动中',
      CoreState.stopping => '停止中',
      CoreState.crashed => '异常退出',
      CoreState.failed => '异常退出',
      CoreState.stopped || null => '已停止',
    },
    stateVersion: snap?.stateVersion ?? 0,
    coreRestarts: snap?.coreRestarts ?? 0,
    configVersion: snap?.configVersion ?? 0,
    proxyMode: snap?.mode.wire ?? '—',
    systemProxyEnabled: snap?.systemProxy.enabled ?? false,
    tunEnabled: snap?.tunState == TunState.enabled,
    tunSupported: snap?.tunSupported ?? false,
    speedTestRunning: snap?.speedTestRunning ?? false,
    logBytes: snap?.logBytes ?? 0,
    themeModeLabel: switch (themeMode) {
      'light' => '浅色',
      'dark' => '深色',
      _ => '跟随系统',
    },
    logLevelLabel: logLevelLabel(routing.logLevel),
    // Only a running core with an active node has had the current routing
    // document applied; otherwise the level is saved but not in effect yet.
    logLevelApplied:
        c.storeReady &&
        c.connected &&
        (snap?.coreState.isRunning ?? false) &&
        (snap?.activeNodeId?.isNotEmpty ?? false),
    speedTestConcurrency: concurrency,
    tableCounts: c.storeReady ? c.store.tableCounts() : const <String, int>{},
    localSubscriptionCount: c.storeReady
        ? c.loadProfiles().where((p) => !p.isRemote).length
        : 0,
    now: DateTime.now(),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _themeMode = 'system';
  bool _loaded = false;

  /// The routing half of the config, which now owns the log level.
  RoutingSettings _routing = const RoutingSettings();

  /// Probes per batch, read from [SettingKeys.speedTestConcurrency].
  int _concurrency = 8;

  /// A backup export or restore is running. Both touch the whole database, so
  /// the buttons lock rather than allowing two at once.
  bool _busy = false;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (!c.storeReady) return;
    setState(() {
      _themeMode = c.settingsRepo.raw('theme.mode') ?? 'system';
      _routing = RoutingSettings.load(c.settingsRepo);
      _concurrency = AppController.clampConcurrency(
        c.settingsRepo.getInt(SettingKeys.speedTestConcurrency) ?? 8,
      );
      _loaded = true;
    });
  }

  void _setTheme(String mode) {
    setState(() => _themeMode = mode);
    if (c.storeReady) {
      c.settingsRepo.setRaw('theme.mode', mode);
    }
    haloThemeMode.value = switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> _exportBackup() async {
    if (!c.storeReady) return;
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出备份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '备份包含节点、订阅与设置。留空则导出明文文件，'
              '填写密码则使用 AES-256-GCM 加密。',
            ),
            const SizedBox(height: HaloMetrics.blockGap),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: '密码（可留空）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('导出'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null) return;
    setState(() => _busy = true);
    try {
      final payload = Backup.collect(
        c.store,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        appVersion: '0.1.0',
        platform: 'windows',
      );
      final result = await Backup.exportSafe(
        payload,
        password: password.isEmpty ? null : password,
      );
      if (result.text == null) {
        throw StateError(result.error?.message ?? '备份失败');
      }
      final path =
          '${c.dataDir}${Platform.pathSeparator}'
          'halo-backup-${DateTime.now().millisecondsSinceEpoch}.chb';
      await File(path).writeAsString(result.text!);
      if (mounted) showHaloToast(context, '备份已保存到 $path');
    } catch (e) {
      if (mounted) showHaloToast(context, '备份失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Restores a backup file: pick → inspect → preview → apply.
  ///
  /// Every step is shown before anything is written. `Backup.apply` writes a
  /// plaintext rollback snapshot first, so a restore that turns out to be wrong
  /// is recoverable without the user having prepared anything.
  Future<void> _restoreBackup() async {
    if (!c.storeReady) return;
    final picked = await _pickBackupPath();
    if (picked == null) return;

    // Everything from here on is inside the try. Reading the file used to happen
    // before it, so a missing/unreadable file threw into the void: the dialog
    // closed, no message appeared, and the button looked broken.
    setState(() => _busy = true);
    try {
      final text = await File(picked).readAsString();
      final password = await _askPassword(encryptedHint: '如果备份设置了密码，请在此输入。');
      if (password == null) return;
      final inspected = await Backup.inspectAsync(
        text,
        existingNodeCountsByFingerprint: {
          for (final node in c.loadNodes()) node.fingerprint: 1,
        },
        existingSubscriptionCount: c.loadProfiles().length,
        password: password.isEmpty ? null : password,
      );
      if (inspected.preview == null) {
        throw StateError(inspected.error?.message ?? '备份无法识别');
      }
      final preview = inspected.preview!;
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认恢复'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(preview.summary),
              const SizedBox(height: HaloMetrics.blockGap),
              Text(
                '恢复只增改，不删除现有节点；写入前会自动保存一份回退备份。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('恢复'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      final result = Backup.apply(
        c.store,
        preview,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        appVersion: '0.1.0',
        platform: 'windows',
      );
      if (!result.applied) {
        throw StateError(result.error?.message ?? '恢复失败');
      }
      c.notifyExternalChange();
      if (!mounted) return;
      showHaloToast(
        context,
        '已恢复 ${result.nodesImported} 个节点、'
        '${result.subscriptionsImported} 个订阅、'
        '${result.settingsImported} 项设置'
        '${result.rollbackBackup == null ? '' : '；回退备份：${result.rollbackBackup}'}',
      );
    } catch (e) {
      if (mounted) showHaloToast(context, '恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks the backup file to restore through the system file dialog.
  ///
  /// This used to be a text field pre-filled with the data directory and an
  /// instruction to type a full path. The comment explaining it said a native
  /// picker "would need a plugin" — that was the wrong call: the project has no
  /// plugins because the Windows shell is hand-compiled when CMake is missing
  /// (docs/agents/build.md), and the named pipe already bypasses that constraint
  /// with direct FFI. comdlg32 is the same trick, so the field is gone.
  ///
  /// Starts in the data directory, where 导出备份 puts the file, and stays there
  /// on cancel: a cancelled dialog is not a failure and must not open another
  /// one.
  Future<String?> _pickBackupPath() async {
    String? path;
    try {
      path = pickFileForOpen(
        title: '选择要恢复的备份文件',
        initialDirectory: c.dataDir,
      );
    } on WindowsFileDialogException catch (e) {
      // A dialog that failed to open is a real error, unlike a cancel; saying
      // only "找不到该备份文件" would blame the user's file for it.
      if (mounted) {
        showHaloToast(context, '$e');
      }
      return null;
    }
    if (path == null || path.isEmpty) return null;
    if (!File(path).existsSync()) {
      if (mounted) showHaloToast(context, '找不到该备份文件');
      return null;
    }
    return path;
  }

  Future<String?> _askPassword({required String encryptedHint}) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('备份密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(encryptedHint),
            const SizedBox(height: HaloMetrics.blockGap),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: '密码（未加密则留空）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return password;
  }

  /// Toggles the run-at-login entry.
  ///
  /// The switch shows the value the host reported, not the value that was
  /// requested: the host re-reads the registry after writing, so a rejected
  /// write (a locked-down policy) leaves the switch where it actually is.
  Future<void> _setCoreResume(bool enabled) async {
    setState(() => _busy = true);
    try {
      await c.setCoreResume(enabled);
      if (!mounted) return;
      showHaloToast(
        context,
        enabled ? '以后启动时会自动恢复内核' : '以后启动时不再自动恢复内核',
      );
    } catch (e) {
      if (!mounted) return;
      showHaloToast(context, '设置失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setAutoLaunch(bool enabled) async {
    setState(() => _busy = true);
    try {
      await c.setAutoLaunch(enabled);
      if (!mounted) return;
      showHaloToast(context, enabled ? '已启用开机自启' : '已关闭开机自启');
    } catch (e) {
      if (!mounted) return;
      showHaloToast(context, '设置开机自启失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens [path] in Explorer.
  ///
  /// Failure is silent by design: the folder may not exist yet on a fresh
  /// install, and a modal error for "nothing to show" would be noise. Explorer
  /// itself tells the user when a path is missing.
  Future<void> _openDirectory(String path) async {
    try {
      await Process.run('explorer.exe', [path]);
    } catch (_) {
      // See above.
    }
  }

  Future<void> _shutdownHost() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出后台代理'),
        content: const Text(
          '后台服务会停止内核并恢复系统代理，托盘图标消失，'
          '这个窗口也会一起关闭。\n'
          '之后可以重新从开始菜单启动 Clash Halo。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await c.shutdownHost();
    } catch (_) {
      // The host may close the pipe as it exits; that is the expected ending.
    }
  }

  /// True when the saved routing settings are what the running core was built
  /// with.
  ///
  /// Mirrors `reapplyRoutingIfPossible`: without a store, a pipe or an active
  /// node there is nothing to apply to, and the page must say "待生效" rather
  /// than let a user believe a level they just picked is already in effect.
  bool get _appliedToCore =>
      c.storeReady &&
      c.connected &&
      (c.snapshot?.coreState.isRunning ?? false) &&
      (c.snapshot?.activeNodeId?.isNotEmpty ?? false);

  Future<void> _setLogLevel(String level) async {
    final next = _routing.copyWith(logLevel: level);
    setState(() => _routing = next);
    try {
      // saveRouting persists and then re-applies, so a running core picks the
      // new level up immediately; when nothing is running it waits for the next
      // apply, which is exactly what the status line below the dropdown says.
      await c.saveRouting(next);
      if (!mounted) return;
      _snack(
        _appliedToCore
            ? '日志级别已改为「${logLevelLabel(level)}」，并已重新应用到内核'
            : '日志级别已保存为「${logLevelLabel(level)}」，将在下次应用配置后生效',
      );
    } catch (e) {
      if (!mounted) return;
      _snack('保存日志级别失败：$e');
    }
  }

  void _setConcurrency(int value) {
    final clamped = AppController.clampConcurrency(value);
    setState(() => _concurrency = clamped);
    if (c.storeReady) {
      c.settingsRepo.setInt(SettingKeys.speedTestConcurrency, clamped);
    }
    _snack('测速并发已改为 $clamped，下次开始测速时生效');
  }

  void _snack(String message) {
    if (!mounted) return;
    showHaloToast(context, message);
  }

  /// Copies the diagnostic block to the clipboard.
  ///
  /// Assembled from counts, versions and state only — see
  /// `state/diagnostics.dart`, whose input type has no field that could carry a
  /// subscription URL, a token or a node secret.
  Future<void> _copyDiagnostics() async {
    final input = diagnosticsFor(
      c,
      themeMode: _themeMode,
      routing: _routing,
      concurrency: _concurrency,
    );
    await Clipboard.setData(ClipboardData(text: buildDiagnosticsText(input)));
    if (!mounted) return;
    _snack('已复制诊断信息');
  }

  @override
  Widget build(BuildContext context) {
    final snap = c.snapshot;
    final counts = c.storeReady ? c.store.tableCounts() : const <String, int>{};
    return HaloPageScaffold(
      title: '设置',
      subtitle: '代理与内核 · 界面 · 数据与诊断',
      // A settings row is a label and its control, not two ends of a runway.
      // Full-width cards put them ~800px apart on a wide window.
      maxContentWidth: 760,
      child: ListView(
        children: [
          SectionCard(
            title: '代理与内核',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingField(
                  label: '日志级别',
                  hint:
                      '级别越低，写入的内容越多：silent 不写任何日志，debug 会使日志文件'
                      '明显增大。保存后立即重新应用配置；内核未运行时，下一次应用配置时生效。',
                  trailing: HaloDropdown<String>(
                    // Keyed by the value so a save that failed (and therefore
                    // reverted the model) also reverts what the field shows.
                    key: ValueKey('log-level-${_routing.logLevel}'),
                    width: 210,
                    value: _routing.logLevel,
                    fontSize: 12.5,
                    items: [
                      for (final choice in kLogLevelChoices)
                        (choice.value, choice.label),
                    ],
                    onChanged: c.storeReady
                        ? (value) {
                            if (value != null) _setLogLevel(value);
                          }
                        : null,
                  ),
                ),
                const SizedBox(height: HaloMetrics.rowGap),
                Text(
                  _appliedToCore
                      ? '当前状态：已应用到运行中的内核。'
                      : '当前状态：已保存，尚未应用（内核未运行或没有启用节点）。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    color: _appliedToCore
                        ? haloAdapt(context, HaloColors.success)
                        : haloAdapt(context, HaloColors.warning),
                  ),
                ),
                const SizedBox(height: HaloMetrics.blockGap),
                _SettingField(
                  label: '测速并发',
                  hint:
                      '延迟与连通性测试同时探测的节点数，默认 8，最多 32。'
                      '下载测速逐个进行，避免多个节点同时占用带宽。',
                  trailing: HaloDropdown<int>(
                    key: ValueKey('speed-concurrency-$_concurrency'),
                    width: 120,
                    value: _concurrency,
                    fontSize: 12.5,
                    items: [
                      for (final value in kSpeedConcurrencyChoices)
                        (value, '$value'),
                    ],
                    onChanged: c.storeReady
                        ? (value) {
                            if (value != null) _setConcurrency(value);
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: HaloMetrics.cardGap),
          SectionCard(
            title: '运行方式',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '关闭本窗口仅退出界面，后台代理继续运行，托盘图标保留在系统托盘中。'
                  '需要完全停止时，请使用本页最下方的「退出后台代理」。',
                ),
                const SizedBox(height: HaloMetrics.blockGap),
                HaloSwitchTile(
                  title: '开机自动启动',
                  subtitle: snap?.autoLaunch == true
                      ? '已写入当前用户的启动项：登录后自动启动并恢复代理，不显示窗口'
                      : '登录 Windows 后在后台启动并恢复代理，需要时再从托盘打开界面',
                  value: snap?.autoLaunch == true,
                  onChanged: c.connected && !_busy
                      ? (v) => _setAutoLaunch(v)
                      : null,
                ),
                HaloSwitchTile(
                  title: '启动时恢复内核',
                  // The subtitle has to be precise about what is *not* included:
                  // this is the exact place a user would assume "恢复代理" also
                  // puts the system proxy back, and then be surprised either way.
                  subtitle: snap?.coreWanted == true
                      ? '下一步启动会重新拉起上次在用的内核；不会自动打开系统代理或 TUN'
                      : '未勾选时，已停止的内核在下次启动后仍保持停止；勾选后启动时重新启用上次在用的节点',
                  value: snap?.coreWanted == true,
                  onChanged: c.connected && !_busy
                      ? (v) => _setCoreResume(v)
                      : null,
                ),
                InfoRow(label: '后台版本', value: snap?.hostVersion ?? '—'),
                InfoRow(label: '数据目录', value: c.dataDir),
              ],
            ),
          ),
          const SizedBox(height: HaloMetrics.cardGap),
          SectionCard(
            title: '界面',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Same segmented control as the mode switch on the overview and
                // the action picker in the rules dialog. Material's
                // SegmentedButton is a different shape, height and radius, and
                // sitting next to HaloSelector elsewhere made the two look like
                // unrelated components.
                // Three segments, not the full card width: a 700px runway for
                // three two-character labels is the same "control pinned to
                // the far edge" problem the form rows had.
                SizedBox(
                  width: 216,
                  child: HaloSelector<String>(
                    options: const [
                      ('system', '跟随系统'),
                      ('light', '浅色'),
                      ('dark', '深色'),
                    ],
                    value: _themeMode,
                    onChanged: _setTheme,
                  ),
                ),
                const SizedBox(height: HaloMetrics.rowGap),
                Text(
                  // The old text said 下次启动时生效, but the content area
                  // switches immediately — the message contradicted what the
                  // click visibly did.
                  '立即生效，并在下次启动时保留。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: HaloMetrics.cardGap),
          SectionCard(
            title: '数据与诊断',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in counts.entries)
                  InfoRow(
                    label: tableLabel(entry.key),
                    value: '${entry.value} 条',
                  ),
                // Read-only: the host rotates at 2 MiB x 3 (logs.DefaultOptions)
                // and nothing in the app can change it, so a control here would
                // be a switch wired to nothing.
                InfoRow(label: '日志轮转', value: '2 MiB × 3 个文件（上限 6 MiB）'),
                if ((snap?.logBytes ?? 0) > 0)
                  InfoRow(
                    label: '日志当前大小',
                    value: formatByteSize(snap!.logBytes),
                  ),
                const SizedBox(height: HaloMetrics.blockGap),
                Wrap(
                  // Buttons are controls, not cards: they take the tighter
                  // block gap so a row of them stays one group.
                  spacing: HaloMetrics.blockGap,
                  runSpacing: HaloMetrics.blockGap,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: c.storeReady && !_busy ? _exportBackup : null,
                      icon: const Icon(Icons.save_outlined, size: 15),
                      label: const Text('导出备份'),
                    ),
                    // Restore was fully implemented in `Backup` (inspect →
                    // preview → apply, with an automatic rollback snapshot) and
                    // simply never had a button, so a backup could be written and
                    // never read back on this machine.
                    OutlinedButton.icon(
                      onPressed: c.storeReady && !_busy ? _restoreBackup : null,
                      icon: const Icon(Icons.settings_backup_restore, size: 15),
                      label: const Text('从备份恢复'),
                    ),
                    // The tray menu already opens these directories; having the
                    // same two buttons here means a user who never opens the tray
                    // can still find the logs and the database.
                    OutlinedButton.icon(
                      onPressed: () => _openDirectory(c.dataDir),
                      icon: const Icon(Icons.folder_outlined, size: 15),
                      label: const Text('打开数据目录'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _openDirectory(
                        '${c.dataDir}${Platform.pathSeparator}logs',
                      ),
                      icon: const Icon(Icons.description_outlined, size: 15),
                      label: const Text('打开日志目录'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _copyDiagnostics,
                      icon: const Icon(Icons.copy_all_outlined, size: 15),
                      label: const Text('复制诊断信息'),
                    ),
                    if (_busy)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: HaloMetrics.blockGap),
                Text(
                  '导出时可选择密码加密；恢复会先预览再写入，并自动保存一份回退备份。'
                  '诊断信息只含版本、状态与行数，适用于提交问题报告。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: HaloMetrics.cardGap),
          SectionCard(
            title: '关于',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const InfoRow(label: '版本', value: kSettingsAppVersion),
                // The core version comes from the host, which read it out of the
                // binary on disk when it started. This used to be the literal
                // 'sing-box 1.14.4': a claim about the build, not about the
                // file being run, and it disagreed with the overview, which
                // showed a dash for the same process.
                InfoRow(
                  label: '代理内核',
                  value: c.coreVersion.isEmpty
                      ? '未知（后台服务未报告版本）'
                      : 'sing-box ${c.coreVersion}',
                ),
              ],
            ),
          ),
          // Last card on the page, and it must stay last: the 运行方式 card
          // points here, and the review found the pointer wrong — the button
          // sat above 界面 / 数据与诊断 / 关于, so 「页面最下方」 led nowhere.
          // A destructive action also belongs at the end, where it cannot be
          // hit while reaching for a toggle.
          const SizedBox(height: HaloMetrics.cardGap),
          SectionCard(
            title: '退出后台代理',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('退出后代理立即停止，界面也无法再连上后台；下次启动应用时不会自动恢复。'),
                const SizedBox(height: HaloMetrics.blockGap),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: c.connected ? _shutdownHost : null,
                    icon: const Icon(Icons.power_settings_new, size: 15),
                    label: const Text('退出后台代理'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: haloAdapt(context, HaloColors.danger),
                      side: BorderSide(
                        color: haloAdapt(
                          context,
                          HaloColors.danger,
                        ).withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!_loaded && !c.storeReady)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                c.storeError ?? '',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: 12,
                  color: haloAdapt(context, HaloColors.danger),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One labelled setting: the label and its control on one line, the
/// explanation underneath across the card width.
///
/// The explanation used to live under the label in a fixed 240px column. The
/// log-level hint is four sentences long, so it wrapped to four lines inside
/// 240px while 250px of the card sat empty to the right of the 210px dropdown —
/// the row became the tallest thing on the page for no information gain. Below
/// the label row it fits on one line, and the control stays next to its label
/// instead of being pushed to the far edge.
class _SettingField extends StatelessWidget {
  const _SettingField({
    required this.label,
    required this.hint,
    required this.trailing,
  });

  final String label;
  final String hint;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 200,
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 16),
            trailing,
          ],
        ),
        const SizedBox(height: HaloMetrics.lineGap),
        Text(
          hint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ],
    );
  }
}
