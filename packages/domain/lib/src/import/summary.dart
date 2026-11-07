/// Wording for import failures, shared by the window and the command line.
///
/// Kept in the domain package rather than in the UI because the CLI reports
/// the same number and used to call it 不支持 just like the window did. One
/// vocabulary means a breakdown cannot drift between the two front ends.
library;

/// Human labels keyed by [ImportFailureKind.wire].
///
/// "不支持" is deliberately split in two: 协议不支持 (the build cannot speak the
/// protocol) and 传输不支持 (it knows the protocol but not the transport). Those
/// are capability gaps the user cannot fix by editing the subscription, while
/// 格式损坏 and 缺少字段 are damaged entries in the source list.
const Map<String, String> importFailureLabels = {
  'unsupported_protocol': '协议不支持',
  'unsupported_parameter': '传输不支持',
  'malformed_link': '格式损坏',
  'missing_required': '缺少字段',
  'decode_error': '解码失败',
  'empty_input': '内容为空',
  'duplicate': '重复条目',
};

String importFailureLabel(String wire) => importFailureLabels[wire] ?? wire;

/// Renders failure counts as "格式损坏 1300、缺少字段 574、传输不支持 61".
///
/// Count-descending, so the cause worth acting on is read first. At most
/// [maxKinds] groups are spelled out and the remainder is folded into
/// "等 N 类": this string sits in a snackbar, and a list of seven kinds would
/// only make it wrap without telling the user anything extra.
String describeImportFailures(Map<String, int> kinds, {int maxKinds = 4}) {
  final entries = kinds.entries.where((e) => e.value > 0).toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      if (byCount != 0) return byCount;
      // Stable for equal counts: the order must not depend on map iteration,
      // or the message would reshuffle between two identical refreshes.
      return importFailureLabel(a.key).compareTo(importFailureLabel(b.key));
    });
  if (entries.isEmpty) return '';
  final shown = entries.take(maxKinds).toList();
  final parts = [
    for (final entry in shown) '${importFailureLabel(entry.key)} ${entry.value}',
  ];
  if (entries.length > shown.length) parts.add('等 ${entries.length} 类');
  return parts.join('、');
}
