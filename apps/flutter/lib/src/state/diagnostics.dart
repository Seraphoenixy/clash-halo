/// The text a user pastes into an issue when something goes wrong.
///
/// Two rules shape this file, and both are about what is *absent*:
///
///  * No secrets: no subscription URL, no token, no node password, key or
///    server address. The input type has no field that could carry one, so a
///    later edit cannot accidentally start leaking them.
///  * Counts instead of contents: "节点 5" answers "did the import work", while a
///    node name would leak whatever the airport put in it (real subscriptions do
///    put an e-mail address in the node name).
library;

/// Everything the diagnostic text is built from, already reduced to
/// non-sensitive values.
class DiagnosticsInput {
  const DiagnosticsInput({
    required this.appVersion,
    required this.hostVersion,
    required this.coreVersion,
    required this.dataDir,
    required this.connectionLabel,
    required this.coreStateLabel,
    required this.stateVersion,
    required this.coreRestarts,
    required this.configVersion,
    required this.proxyMode,
    required this.systemProxyEnabled,
    required this.tunEnabled,
    required this.tunSupported,
    required this.speedTestRunning,
    required this.logBytes,
    required this.themeModeLabel,
    required this.logLevelLabel,
    required this.logLevelApplied,
    required this.speedTestConcurrency,
    required this.tableCounts,
    this.localSubscriptionCount = 0,
    required this.now,
  });

  final String appVersion;
  final String hostVersion;
  final String coreVersion;

  /// Where the data lives. Part of the answer to "which install is this", and
  /// not a secret: it is a local path the user can see in Settings.
  final String dataDir;

  final String connectionLabel;
  final String coreStateLabel;
  final int stateVersion;
  final int coreRestarts;
  final int configVersion;
  final String proxyMode;
  final bool systemProxyEnabled;
  final bool tunEnabled;
  final bool tunSupported;
  final bool speedTestRunning;
  final int logBytes;
  final String themeModeLabel;
  final String logLevelLabel;

  /// Whether the running core was built with [logLevelLabel].
  ///
  /// Shown because the level only takes effect once a config is applied, and a
  /// user reporting "I set debug but the log is empty" needs to see the
  /// difference between "saved" and "in effect".
  final bool logLevelApplied;

  final int speedTestConcurrency;

  /// Row counts by table name, e.g. `{'nodes': 5}`.
  final Map<String, int> tableCounts;

  /// How many of [tableCounts]'s subscription rows are the built-in 本地 one.
  ///
  /// Local imports are a subscription since v6, so the raw row count would claim
  /// one more subscription than the user actually has. Reported separately
  /// instead of silently subtracted, because "本地: 1 条" is information the user
  /// may want when explaining where their nodes came from.
  final int localSubscriptionCount;
  final DateTime now;
}

/// Chinese label for a table name, shared by the page and the diagnostic text so
/// the two can never disagree about what "import_log" is called.
String tableLabel(String table) => switch (table) {
  'nodes' => '节点',
  'subscriptions' => '订阅',
  'settings' => '设置项',
  'import_log' => '导入记录',
  'applied_config' => '配置历史',
  _ => table,
};

/// Renders [input] as stable, greppable plain text.
///
/// Deliberately not JSON: the reader is a human triaging a report, and a fixed
/// `label: value` shape survives being pasted into a chat window.
String buildDiagnosticsText(DiagnosticsInput input) {
  String stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  final buffer = StringBuffer()
    ..writeln('Clash Halo 诊断信息')
    ..writeln('生成时间: ${stamp(input.now)}')
    ..writeln()
    ..writeln('[版本]')
    ..writeln('应用: ${input.appVersion}')
    ..writeln('后台: ${input.hostVersion}')
    ..writeln('内核: ${input.coreVersion}')
    ..writeln()
    ..writeln('[运行状态]')
    ..writeln('连接: ${input.connectionLabel}')
    ..writeln('内核状态: ${input.coreStateLabel}（已重启 ${input.coreRestarts} 次）')
    ..writeln('代理模式: ${input.proxyMode}')
    ..writeln('系统代理: ${input.systemProxyEnabled ? '开启' : '关闭'}')
    ..writeln(
      'TUN: ${input.tunEnabled ? '开启' : '关闭'}'
      '${input.tunSupported ? '' : '（当前环境不支持）'}',
    )
    ..writeln('测速任务: ${input.speedTestRunning ? '运行中' : '空闲'}')
    ..writeln('状态版本: ${input.stateVersion} · 配置版本: ${input.configVersion}')
    ..writeln()
    ..writeln('[设置]')
    ..writeln('主题: ${input.themeModeLabel}')
    ..writeln(
      '日志级别: ${input.logLevelLabel}'
      '${input.logLevelApplied ? '' : '（尚未应用到内核，下次应用配置后生效）'}',
    )
    ..writeln('测速并发: ${input.speedTestConcurrency}')
    ..writeln('日志当前大小: ${formatByteSize(input.logBytes)}（2 MiB × 3 个文件轮转）')
    ..writeln()
    ..writeln('[数据]')
    ..writeln('数据目录: ${input.dataDir}');

  if (input.tableCounts.isEmpty) {
    buffer.writeln('表行数: 未知（数据库未打开）');
  } else {
    final keys = input.tableCounts.keys.toList()..sort();
    for (final key in keys) {
      final isSubscriptions = key == 'subscriptions';
      final local = input.localSubscriptionCount.clamp(
        0,
        input.tableCounts[key] ?? 0,
      );
      final shown = isSubscriptions
          ? (input.tableCounts[key] ?? 0) - local
          : input.tableCounts[key];
      buffer.writeln('${tableLabel(key)}: $shown 条');
      if (isSubscriptions && local > 0) {
        buffer.writeln('本地订阅: $local 条（导入的本地节点所属）');
      }
    }
  }
  buffer.writeln();
  buffer.writeln('[说明]');
  buffer.writeln('以上只包含版本号、状态与行数，不含订阅地址、令牌、节点密钥或服务器地址。');
  return buffer.toString().trimRight();
}

/// Byte count as a short human string. Shared with the settings page so the
/// log size it shows and the size in the pasted report are the same rendering.
String formatByteSize(int value) {
  if (value <= 0) return '0 B';
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
  return '$value B';
}
