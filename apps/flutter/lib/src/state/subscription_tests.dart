/// Pure helpers behind the subscription page.
///
/// The two decisions that are easy to get subtly wrong — what a subscription's
/// latency roll-up means, and what a chosen update interval stores — live here
/// as functions rather than inside widgets, because both can then be pinned by
/// a test that needs no window, no pipe and no host.
library;

import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';

/// Whether [profile] can be refreshed over the network.
///
/// A record whose url is not http(s) can never update: that is the pasted-node
/// case, where the "url" is a truncated copy of the paste. "Update all" has to
/// skip those instead of failing them once a minute and painting the row red.
bool isRemoteProfile(SubscriptionProfile profile) {
  final uri = Uri.tryParse(profile.url);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// One subscription's latency roll-up, in the units it was measured.
///
/// Latency only. A throughput reading is bytes per second and a reachability
/// reading is a boolean; averaging either into a millisecond column would
/// produce a number that means nothing (see docs/agents/measurement.md).
class SubscriptionLatencySummary {
  const SubscriptionLatencySummary({
    required this.total,
    required this.ok,
    required this.failed,
    this.fastestMs,
    this.averageMs,
  });

  /// Nodes belonging to the subscription, tested or not.
  final int total;

  /// Nodes that answered with a round trip.
  final int ok;

  /// Nodes that produced a terminal result without answering. A node the host
  /// never got to is *not* counted here — see [untested].
  final int failed;

  final int? fastestMs;
  final int? averageMs;

  /// No node has a terminal result yet.
  bool get isUntested => tested == 0;

  /// Nodes the host has already answered for, in either direction.
  int get tested => ok + failed;

  /// Nodes still without a verdict. Kept separate from [failed] so a cancelled
  /// run cannot be presented as a subscription full of dead nodes.
  int get untested => total - tested;

  /// The row's one-line roll-up.
  ///
  /// The denominator is the subscription's node count rather than the number
  /// tested: after a cancelled run "可用 2/2" would claim a perfect
  /// subscription while eight nodes were never asked.
  String get label {
    if (isUntested) return '未测试';
    if (ok == 0) return '不可用 $failed/$total';
    final fastest = fastestMs ?? 0;
    final average = averageMs ?? 0;
    final tail = failed > 0 ? ' · 失败 $failed' : '';
    return '可用 $ok/$total · 最快 $fastest ms · 平均 $average ms$tail';
  }

  static const empty = SubscriptionLatencySummary(
    total: 0,
    ok: 0,
    failed: 0,
  );
}

/// Rolls the latency results of [nodes] up into one summary.
///
/// Only [SpeedMetric.proxyLatency] counts, and only a terminal status counts:
/// `pending`/`running` are not answers, and counting them as tested would let
/// the row report a verdict the host has not produced yet.
SubscriptionLatencySummary summarizeSubscriptionLatency(
  List<ProxyNode> nodes,
  Map<String, SpeedResult> results,
) {
  var ok = 0;
  var failed = 0;
  var sum = 0;
  int? fastest;
  for (final node in nodes) {
    final result = results[node.id];
    if (result == null) continue;
    if (result.metric != SpeedMetric.proxyLatency) continue;
    if (!result.status.isTerminal) continue;
    final ms = result.valueMs;
    if (result.status == SpeedStatus.ok && ms != null) {
      ok++;
      sum += ms;
      fastest = (fastest == null || ms < fastest) ? ms : fastest;
    } else {
      failed++;
    }
  }
  return SubscriptionLatencySummary(
    total: nodes.length,
    ok: ok,
    failed: failed,
    fastestMs: fastest,
    averageMs: ok == 0 ? null : (sum / ok).round(),
  );
}

/// One entry of the update-interval picker.
class UpdateIntervalOption {
  const UpdateIntervalOption(this.label, {this.minutes, this.custom = false});

  final String label;

  /// The interval this choice stores, or null for [isManual].
  final int? minutes;

  /// This choice opens a minutes field instead of fixing the value.
  final bool custom;

  /// Manual: automatic refresh off. Distinct from [custom], which is on.
  bool get isManual => minutes == null && !custom;
}

const String kManualIntervalLabel = '手动更新';
const String kCustomIntervalLabel = '自定义';

/// The picker's choices, in the order the reference client presents them.
const List<UpdateIntervalOption> kUpdateIntervalPresets = [
  UpdateIntervalOption(kManualIntervalLabel),
  UpdateIntervalOption('每 30 分钟', minutes: 30),
  UpdateIntervalOption('每 1 小时', minutes: 60),
  UpdateIntervalOption('每 6 小时', minutes: 360),
  UpdateIntervalOption('每 12 小时', minutes: 720),
  UpdateIntervalOption('每 24 小时', minutes: 1440),
  UpdateIntervalOption(kCustomIntervalLabel, custom: true),
];

/// Below this, an automatic refresh reloads the core often enough to drop live
/// connections, so the editor warns instead of accepting the value in silence.
const int kAggressiveIntervalMinutes = 60;

/// The picker entry that matches what [profile] already stores.
///
/// Auto-update off is "manual" whatever the stored minutes say, so the dialog
/// cannot open showing an interval for a subscription that never refreshes.
UpdateIntervalOption intervalOptionFor(SubscriptionProfile profile) {
  if (!profile.autoUpdate) return kUpdateIntervalPresets.first;
  for (final option in kUpdateIntervalPresets) {
    if (option.custom) continue;
    if (option.minutes == profile.updateIntervalMinutes) return option;
  }
  return kUpdateIntervalPresets.last;
}

/// What a picker choice stores.
///
/// Manual keeps the stored minutes, so switching back to an interval returns to
/// the value the user last chose instead of a default they never picked.
({bool autoUpdate, int minutes}) resolveIntervalChoice({
  required UpdateIntervalOption option,
  required int customMinutes,
  required int storedMinutes,
}) {
  if (option.isManual) return (autoUpdate: false, minutes: storedMinutes);
  if (option.custom) {
    return (autoUpdate: true, minutes: customMinutes < 1 ? 1 : customMinutes);
  }
  return (autoUpdate: true, minutes: option.minutes!);
}

/// The row chip's text for a stored interval.
///
/// `每 1440 分钟` is what the raw value reads as, and it is unreadable: the
/// reference client names the interval, not its smallest unit.
String intervalChipLabel(int minutes) {
  if (minutes >= 1440 && minutes % 1440 == 0) {
    final days = minutes ~/ 1440;
    return days == 1 ? '每天更新' : '每 $days 天更新';
  }
  if (minutes >= 60 && minutes % 60 == 0) return '每 ${minutes ~/ 60} 小时更新';
  return '每 $minutes 分钟更新';
}
