import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:halo_domain/halo_domain.dart';

import '../../state/app_controller.dart';
import '../../state/subscription_tests.dart';
import '../../theme.dart';
import '../app.dart';
import '../widgets.dart';
import '../widgets/measurement.dart';

// The latency colour scale is shared, not copied: a second copy is how the same
// millisecond ends up "fast" on one page and "slow" on the other.

/// Subscription management: paste a link or subscription URL, choose to update
/// the node list, and record what happened per entry.
///
/// Three things this page owns, and one it deliberately does not:
///
///  1. **Import** — a subscription URL is fetched at once; a pasted share link
///     or whole config becomes a preview first, because a half-written paste is
///     not something a row can undo.
///  2. **The list** — every row carries its own update, edit, delete, interval
///     and test actions, so finding out whether a subscription is any good no
///     longer means leaving the page.
///  3. **Latency testing** — one subscription at a time, or all of them in a
///     queue. Only latency: throughput and reachability are different questions
///     with different costs (docs/agents/measurement.md) and stay on the nodes
///     page, which is the only place with columns for them.
class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({
    super.key,
    required this.controller,
    required this.onOpenNodes,
  });

  final AppController controller;
  final VoidCallback onOpenNodes;

  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _busy = false;
  ImportResult? _preview;
  String _previewSource = '';

  /// Subscription ids with a refresh in flight, so each row can spin on its own
  /// instead of one page-wide flag freezing the whole list.
  final Set<String> _updating = {};

  /// Multi-select mode for batch update/delete.
  bool _batchMode = false;

  /// Group filter: null = every group, [kUngroupedGroupId] = ungrouped only,
  /// otherwise a group id.
  String? _groupFilter;
  final Set<String> _selected = {};

  AppController get c => widget.controller;

  /// Whether the import form is folded down to a header.
  ///
  /// Starts folded. Import is a rare act and 更新 is the daily one, so an open
  /// editor spent the top of the page on something the user is not doing and
  /// pushed the list — the thing being managed — below the fold. The entry point
  /// stays visible as a one-line bar with 展开导入, so nothing is hidden, only
  /// given back its space.
  bool _importCollapsed = true;

  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    super.dispose();
  }

  void _snack(String message, {SnackBarAction? action, Duration? duration}) {
    if (!mounted) return;
    showHaloToast(context, message, action: action, duration: duration);
  }

  // ------------------------------------------------------------------
  // Import
  // ------------------------------------------------------------------

  Future<void> _parse() async {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    final uri = Uri.tryParse(body);
    if (uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        !body.contains('\n')) {
      setState(() => _busy = true);
      try {
        final existing = c
            .loadProfiles()
            .where((p) => p.url == body)
            .firstOrNull;
        final profile =
            existing ??
            SubscriptionProfile(
              id: 'sub_${DateTime.now().microsecondsSinceEpoch}',
              name: _name.text.trim().isEmpty ? uri.host : _name.text.trim(),
              url: body,
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
            );
        c.subscriptionRepo.upsert(profile);
        // No forced override here: `updateSubscription` resolves the row's own
        // switch, and an unset switch falls back to the host policy — which is
        // what makes a GitHub URL work on first add without the user knowing
        // they needed the proxy.
        final result = await c.updateSubscription(profile);
        if (mounted) {
          setState(() {
            _input.clear();
            _preview = null;
          });
        }
        if (mounted &&
            (result.partial ||
                result.duplicateCount > 0 ||
                result.crossDuplicateCount > 0)) {
          // The usable nodes are already stored; saying how many were left out
          // — and how many were simply repeats — keeps "订阅里怎么少了几个"
          // from becoming a mystery.
          _snack(
            '已导入 ${result.imported} 个节点，'
            '${_importTally(unsupported: result.failed, kinds: result.failureKinds, duplicates: result.duplicateCount, crossDuplicates: result.crossDuplicateCount)}',
            duration: HaloToastDuration.detail,
            action: SnackBarAction(
              label: '查看',
              onPressed: () => _showImportFailures(
                kinds: result.failureKinds,
                samples: result.failures,
                total: result.failed,
                duplicates: result.duplicateCount,
                duplicateSamples: result.skippedSamples,
                crossDuplicates: result.crossDuplicateCount,
                crossSamples: result.crossDuplicates,
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) showHaloToast(context, '$e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    setState(() {
      _preview = importNodes(body);
      _previewSource = body.length > 200 ? '${body.substring(0, 200)}…' : body;
    });
  }

  Future<void> _commit() async {
    final preview = _preview;
    if (preview == null || preview.isEmpty) return;
    setState(() => _busy = true);
    try {
      final (:total, :duplicates) = c.saveImport(preview, source: _previewSource);
      // Deliberately no subscription record here.
      //
      // This path only ever handles pasted content (a URL is imported by
      // `_parse` and never reaches the preview), and it used to create a record
      // whose URL was either empty or a 200-character truncation of the pasted
      // text. Those records could never update: every "更新" failed with
      // "订阅地址必须是 HTTP 或 HTTPS", and with scheduled updates on they would
      // fail once a minute and mark themselves broken. Pasted nodes are local
      // nodes; a group only exists when a real URL does.
      if (mounted) {
        // "已导入" says what landed; the skips say why the two numbers can
        // disagree when the paste overlaps a subscription the user already
        // has — the connection exists once and this write did not duplicate it.
        showHaloToast(
          context,
          '已导入 ${preview.importedCount} 个节点，现有 $total 个'
          '${duplicates.isEmpty ? '' : '，${duplicates.length} 条已存在，未重复添加'}',
        );
      }
      setState(() {
        _input.clear();
        _name.clear();
        _preview = null;
        // Fold the form away once it has done its job: an import just happened,
        // so the next action is looking at the result, not pasting more.
        _importCollapsed = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------
  // Updates
  // ------------------------------------------------------------------

  /// Refreshes [profiles], one at a time, and reports the outcome once.
  ///
  /// Serial on purpose: each refresh replaces that subscription's node rows in
  /// one transaction, and several at once would interleave against the host's
  /// reads for no gain — the wait is on the network, not on the disk.
  Future<void> _updateProfiles(
    List<SubscriptionProfile> profiles, {
    bool viaProxy = false,
  }) async {
    final targets = profiles.where(isRemoteProfile).toList();
    final skipped = profiles.length - targets.length;
    if (targets.isEmpty) {
      _snack(skipped > 0 ? '所选订阅都不是远程订阅，没有可更新的地址' : '没有可更新的订阅');
      return;
    }
    final single = targets.length == 1;
    setState(() {
      for (final profile in targets) {
        _updating.add(profile.id);
      }
    });
    var ok = 0;
    var proxied = 0;
    var direct = 0;
    var unsupported = 0;
    var duplicates = 0;
    var crossDuplicates = 0;
    final kinds = <String, int>{};
    final skippedKinds = <String, int>{};
    final samples = <ImportIssue>[];
    final skippedSamples = <ImportIssue>[];
    final crossSamples = <ImportIssue>[];
    SubscriptionProfile? firstFailure;
    String? firstFailureError;
    for (final profile in targets) {
      if (!mounted) return;
      try {
        final result = await c.updateSubscription(profile, viaProxy: viaProxy);
        if (result.partial) {
          unsupported += result.failed;
          for (final entry in result.failureKinds.entries) {
            kinds.update(
              entry.key,
              (value) => value + entry.value,
              ifAbsent: () => entry.value,
            );
          }
          samples.addAll(result.failures);
        }
        // Duplicates are not failures: they were usable entries the source
        // listed twice. They are still worth reporting — a refresh that says
        // "1461 条未导入" and nothing else reads as 1461 lost nodes.
        if (result.skipped > 0) {
          duplicates += result.duplicateCount;
          for (final entry in result.skippedKinds.entries) {
            skippedKinds.update(
              entry.key,
              (value) => value + entry.value,
              ifAbsent: () => entry.value,
            );
          }
          skippedSamples.addAll(result.skippedSamples);
        }
        // Connections another subscription already owns. Not a failure and not
        // a repeat inside this body: the pool simply keeps one copy.
        if (result.crossDuplicateCount > 0) {
          crossDuplicates += result.crossDuplicateCount;
          crossSamples.addAll(result.crossDuplicates);
        }
        if (result.viaProxy) {
          proxied++;
        } else {
          direct++;
        }
        ok++;
      } catch (e) {
        firstFailure ??= profile;
        firstFailureError ??= '$e';
      } finally {
        if (mounted) setState(() => _updating.remove(profile.id));
      }
    }
    if (!mounted) return;
    final failed = targets.length - ok;
    if (single && failed == 1) {
      // One row, one failure: the reason belongs next to that row, and the row
      // already shows it. Silence would be worse — the refresh button would
      // look like it did nothing.
      _snack('更新失败：${firstFailureError ?? '未知原因'}');
      return;
    }
    if (single) {
      // A single row that updated but left entries out still needs to say so.
      if (unsupported > 0 || duplicates > 0 || crossDuplicates > 0) {
        _snack(
          '已更新，${_importTally(unsupported: unsupported, kinds: kinds, duplicates: duplicates, crossDuplicates: crossDuplicates)}',
          duration: HaloToastDuration.detail,
          action: SnackBarAction(
            label: '查看',
            onPressed: () => _showImportFailures(
              kinds: kinds,
              samples: samples,
              total: unsupported,
              duplicates: duplicates,
              duplicateSamples: skippedSamples,
              crossDuplicates: crossDuplicates,
              crossSamples: crossSamples,
            ),
          ),
        );
      }
      return;
    }
    final parts = [
      // Which channel each row used is not visible anywhere else: a batch that
      // quietly goes direct for every row reads exactly like one that followed
      // the per-row settings.
      '成功 $ok（经代理 $proxied，直连 $direct）',
      if (failed > 0) '失败 $failed',
      if (unsupported > 0)
        '未导入 $unsupported 条（${describeImportFailures(kinds)}）',
      if (duplicates > 0) '重复 $duplicates 条',
      if (crossDuplicates > 0) '跨订阅重复 $crossDuplicates 条',
    ];
    final notice = skipped > 0
        ? '更新完成：${parts.join('，')}，跳过 $skipped 个非远程记录'
        : '更新完成：${parts.join('，')}';
    _snack(
      notice,
      // The list above can carry up to four numbers plus the skipped count, so
      // this one asks for the detail length explicitly; it is the only call site
      // whose message length does not reliably predict how long it needs.
      duration: HaloToastDuration.detail,
      // Two different questions can be pending here, and they are answered in
      // different dialogs: which entries were left out, or why a download
      // failed. The count is the more common one, so it owns the action.
      action: unsupported > 0 || duplicates > 0 || crossDuplicates > 0
          ? SnackBarAction(
              label: '查看',
              onPressed: () => _showImportFailures(
                kinds: kinds,
                samples: samples,
                total: unsupported,
                duplicates: duplicates,
                duplicateSamples: skippedSamples,
                crossDuplicates: crossDuplicates,
                crossSamples: crossSamples,
              ),
            )
          : firstFailure == null
          ? null
          : SnackBarAction(
              label: '查看原因',
              onPressed: () => _showError(firstFailure),
            ),
    );
  }

  Future<void> _updateNow(SubscriptionProfile profile) =>
      _updateProfiles([profile]);

  /// Flips the scheduled-update flag.
  ///
  /// This used to be a long-press, which nobody could discover; it is a normal
  /// switch in the row now, and the interval is editable in the same dialog
  /// rather than being a hidden default.
  void _toggleAutoUpdate(SubscriptionProfile profile, bool enabled) {
    c.subscriptionRepo.upsert(
      profile.copyWith(autoUpdate: enabled, enabled: enabled),
    );
    c.notifyExternalChange();
  }

  Future<void> _editProfile(SubscriptionProfile profile) async {
    final name = TextEditingController(text: profile.name);
    final url = TextEditingController(text: profile.url);
    final custom = TextEditingController(
      text: '${profile.updateIntervalMinutes}',
    );
    var option = intervalOptionFor(profile);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Derived, never stored: the warning has to follow the choice the
          // user is looking at right now, including a value they are typing.
          final minutes = option.custom
              ? int.tryParse(custom.text.trim())
              : option.minutes;
          final aggressive =
              !option.isManual &&
              minutes != null &&
              minutes < kAggressiveIntervalMinutes;
          return AlertDialog(
            title: const Text('编辑订阅'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HaloField(
                    label: '名称',
                    child: TextField(
                      controller: name,
                      autofocus: true,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: HaloMetrics.blockGap),
                  HaloField(
                    label: '订阅链接',
                    child: TextField(
                      controller: url,
                      decoration: const InputDecoration(),
                    ),
                  ),
                  const SizedBox(height: HaloMetrics.blockGap),
                  HaloField(
                    label: '自动更新间隔',
                    child: HaloDropdown<String>(
                      key: const ValueKey('sub-interval'),
                      width: double.infinity,
                      value: option.label,
                      hint: '选择间隔',
                      items: [
                        for (final preset in kUpdateIntervalPresets)
                          (preset.label, preset.label),
                      ],
                      onChanged: (label) => setDialogState(() {
                        option = kUpdateIntervalPresets.firstWhere(
                          (preset) => preset.label == label,
                        );
                      }),
                    ),
                  ),
                  if (option.custom) ...[
                    const SizedBox(height: HaloMetrics.blockGap),
                    HaloField(
                      label: '间隔（分钟）',
                      child: TextField(
                        controller: custom,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setDialogState(() {}),
                        decoration: const InputDecoration(),
                      ),
                    ),
                  ],
                  const SizedBox(height: HaloMetrics.blockGap),
                  Text(
                    '仅在界面运行期间执行，关闭界面后不再更新。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (aggressive)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '间隔过短会频繁触发内核重载并中断现有连接，'
                        '建议使用默认值（每 24 小时）。',
                        style: TextStyle(
                          fontSize: 11,
                          color: haloAdapt(context, HaloColors.warning),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    final newName = name.text.trim();
    final newUrl = url.text.trim();
    final customMinutes = int.tryParse(custom.text.trim()) ?? 0;
    name.dispose();
    url.dispose();
    custom.dispose();
    if (saved != true) return;
    final resolved = resolveIntervalChoice(
      option: option,
      customMinutes: customMinutes,
      storedMinutes: profile.updateIntervalMinutes,
    );
    c.subscriptionRepo.upsert(
      profile.copyWith(
        name: newName.isEmpty ? profile.name : newName,
        url: newUrl.isEmpty ? profile.url : newUrl,
        autoUpdate: resolved.autoUpdate,
        updateIntervalMinutes: resolved.minutes,
        // A record switched back on must not keep a stale "enabled" of false,
        // or the row's switch turns itself off again on the next read.
        enabled: resolved.autoUpdate ? true : profile.enabled,
      ),
    );
    c.notifyExternalChange();
    if (mounted) setState(() {});
  }

  /// Deletes [profiles], asking what to do with the nodes they own.
  ///
  /// The previous dialog promised to delete "其 N 个节点" but the repository kept
  /// them, leaving rows whose profile no longer existed: they appeared under 全部,
  /// belonged to no filter chip, and could never be updated again. The choice is
  /// explicit now, because both answers are legitimate — removing a dead airport
  /// should take its nodes with it, while dropping a link you plan to re-add
  /// should not lose the working nodes you already tested.
  Future<void> _deleteProfiles(List<SubscriptionProfile> profiles) async {
    if (profiles.isEmpty) return;
    final all = c.loadNodes();
    final owned = <ProxyNode>[];
    for (final profile in profiles) {
      owned.addAll(all.where((n) => n.profileId == profile.id));
    }
    final head = profiles.length == 1
        ? '「${profiles.first.name}」下有 ${owned.length} 个节点。'
        : '所选的 ${profiles.length} 个订阅共 ${owned.length} 个节点。';
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          profiles.length == 1 ? '删除订阅' : '删除 ${profiles.length} 个订阅',
        ),
        content: Text(
          '$head\n\n'
          '只删订阅：保留这些节点，移到「本地」分组继续可用。\n'
          '删除订阅和节点：连同节点一起移除。\n\n'
          '已经应用到内核的配置不会被中断，下次启用节点时才会失效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('keep'),
            child: const Text('只删订阅'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('purge'),
            child: const Text('删除订阅和节点'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'purge') {
      c.deleteNodes(owned.map((n) => n.id));
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final node in owned) {
        c.nodeRepo.update(node.movedToGroup(null, nowMs: now), nowMs: now);
      }
    }
    for (final profile in profiles) {
      c.subscriptionRepo.deleteProfile(profile.id);
      _selected.remove(profile.id);
    }
    c.notifyExternalChange();
    if (mounted) setState(() {});
  }

  void _showError(SubscriptionProfile? profile) {
    if (profile == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('订阅更新失败'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile.name),
            const SizedBox(height: HaloMetrics.blockGap),
            SelectableText(profile.lastError ?? '没有记录到具体原因'),
            const SizedBox(height: HaloMetrics.blockGap),
            Text(
              '旧节点会保留，只有下载并校验成功才会替换。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_updateNow(profile));
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  /// "未导入 1 条（传输不支持 1），重复 1580 条" — the tally both numbers.
  String _importTally({
    required int unsupported,
    required Map<String, int> kinds,
    required int duplicates,
    int crossDuplicates = 0,
  }) {
    final parts = <String>[
      if (unsupported > 0)
        '未导入 $unsupported 条（${describeImportFailures(kinds)}）',
      if (duplicates > 0) '重复 $duplicates 条',
      if (crossDuplicates > 0) '跨订阅重复 $crossDuplicates 条',
    ];
    return parts.join('，');
  }

  /// Lists what a refresh refused, by kind and with the first few entries.
  ///
  /// The count alone cannot be acted on: "1462 条未导入" reads as a protocol
  /// the build is missing, while the breakdown shows that most of them are
  /// damaged lines in the source list and nothing is wrong here. Duplicates
  /// are listed apart because they are not refusals at all.
  Future<void> _showImportFailures({
    required Map<String, int> kinds,
    required List<ImportIssue> samples,
    required int total,
    int duplicates = 0,
    List<ImportIssue> duplicateSamples = const [],
    int crossDuplicates = 0,
    List<ImportIssue> crossSamples = const [],
  }) {
    final theme = Theme.of(context);
    final breakdown = describeImportFailures(kinds, maxKinds: 8);
    final allSamples = [...samples, ...duplicateSamples, ...crossSamples];
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未导入的条目'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(breakdown.isEmpty ? '共 $total 条' : '共 $total 条：$breakdown'),
              if (duplicates > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '另有 $duplicates 条重复：同一份订阅里出现了多次，已保留第一条。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (crossDuplicates > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '另有 $crossDuplicates 条连接已由其他订阅提供，节点池里只保留一份。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: HaloMetrics.blockGap),
              Text(
                '能用的节点已经写入数据库，下面这些被跳过。'
                '原文截断到 $importRawLimit 个字符。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: HaloMetrics.blockGap),
              if (allSamples.isEmpty)
                Text('这次没有留下明细：只有总数，无法逐条查看。', style: theme.textTheme.bodySmall)
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: allSamples.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) => _failureRow(
                      context,
                      allSamples[index],
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _failureRow(BuildContext context, ImportIssue issue) {
    final theme = Theme.of(context);
    final palette = HaloPalette.of(context);
    final where = issue.line == null ? '' : ' · 第 ${issue.line} 行';
    final raw = issue.raw;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${importFailureLabel(issue.kind.wire)}$where',
            style: theme.textTheme.labelSmall?.copyWith(
              color: palette.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(issue.message, style: theme.textTheme.bodySmall),
          if (raw != null && raw.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              raw,
              maxLines: 2,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Shows and copies the unredacted subscription URL on request.
  ///
  /// The list deliberately shows a masked form, so this is the one place the
  /// real address appears. It is a dialog rather than a row label because a
  /// dialog is a deliberate act: the user asked to see it, and it is not
  /// sitting on screen for the next screenshot.
  void _showUrl(SubscriptionProfile profile) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('订阅地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile.name),
            const SizedBox(height: HaloMetrics.blockGap),
            SelectableText(
              profile.fullUrl,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11.5),
            ),
            const SizedBox(height: HaloMetrics.blockGap),
            Text(
              '这个地址可能包含订阅凭据，截图或分享时请注意。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              unawaited(
                Clipboard.setData(ClipboardData(text: profile.fullUrl)),
              );
              Navigator.of(context).pop();
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  void _toggleBatchMode() {
    setState(() {
      _batchMode = !_batchMode;
      if (!_batchMode) _selected.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final profiles = c.storeReady
        ? c.loadProfiles()
        : const <SubscriptionProfile>[];
    final allNodes = c.storeReady ? c.loadNodes() : const <ProxyNode>[];
    final nodeCount = allNodes.length;
    // One pass for every row's node list, instead of scanning the whole table
    // once per row on every rebuild.
    final nodesByProfile = <String, List<ProxyNode>>{};
    for (final node in allNodes) {
      final id = node.profileId;
      if (id == null) continue;
      (nodesByProfile[id] ??= <ProxyNode>[]).add(node);
    }
    // The list is what the filter leaves; the batch selection keeps using
    // `profiles` so "全选" still means the whole set, not the visible page.
    final groups = c.storeReady ? c.loadGroups() : const <SubscriptionGroup>[];
    final groupNames = {for (final g in groups) g.id: g.name};
    final filtered = _groupFilter == null
        ? profiles
        : _groupFilter == kUngroupedGroupId
        ? profiles.where((p) => p.groupId == null).toList()
        : profiles.where((p) => p.groupId == _groupFilter).toList();
    final ids = profiles.map((p) => p.id).toSet();
    // A subscription deleted elsewhere must not stay selected: the next batch
    // action would then address a row that no longer exists. Mutating here is
    // safe because this build is already the frame that would show it.
    _selected.removeWhere((id) => !ids.contains(id));

    final remoteCount = profiles.where(isRemoteProfile).length;

    return HaloPageScaffold(
      title: '订阅',
      // In batch mode the header *is* the toolbar. A bar of its own above the
      // list cost a fixed 34px of height on a page that already spends its top
      // 260 on the import form, which pushed the list past the bottom of a
      // 1180x760 window at 200% scaling.
      subtitle: _batchMode
          ? '已选 ${_selected.length} / ${profiles.length} · 操作只作用于勾选的订阅'
          : (nodeCount == 0
                ? '第一步：导入订阅或分享链接，导入后到「节点」页启用一个节点'
                : '已有 $nodeCount 个节点 · 支持分享链接、Clash YAML、sing-box JSON、Base64 订阅'),
      actions: _batchMode
          ? _batchActions(profiles, ids)
          : _defaultActions(profiles, nodeCount, remoteCount),
      child: Column(
        children: [
          // The import form is a fixed-height block above a list that takes the
          // rest. At 590x380 logical it is taller than the viewport on its own,
          // and controls are 48 tall now, so it needs to scroll rather than
          // paint an overflow stripe over the page.
          //
          // Once a subscription exists the form collapses to its header. Daily
          // work is 更新, and a permanently open editor pushed the list — the
          // thing being managed — below it.
          // Folded regardless of whether any subscription exists: the default
          // is folded now, and tying the collapsed bar to `profiles.isNotEmpty`
          // would leave a first-run window showing a full editor that the
          // 收起 button appears to have closed.
          if (_importCollapsed)
            _collapsedImportHeader(context)
          else
            Flexible(
              child: SingleChildScrollView(
                child: SectionCard(
                  title: '导入节点',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message:
                            '订阅链接会立即下载；粘贴单个分享链接或整段配置会先解析预览，'
                            '确认后再写入。',
                        child: Icon(
                          Icons.info_outline,
                          size: 14,
                          color: HaloPalette.of(context).textTertiary,
                        ),
                      ),
                      // Offered even with an empty list: since the form starts
                      // collapsed, the expand/collapse pair has to be
                      // symmetric, or a fresh install can open the form once and
                      // never fold it again.
                      IconButton(
                        key: const ValueKey('sub-import-collapse'),
                        tooltip: '收起导入区',
                        onPressed: () =>
                            setState(() => _importCollapsed = true),
                        iconSize: 15,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.expand_less),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HaloField(
                        label: '分享链接 / 订阅内容',
                        hint:
                            '支持 ss / vmess / vless / trojan / hysteria2 分享链接，'
                            '或整段 Clash / sing-box / v2rayN 导出的配置。',
                        child: TextField(
                          controller: _input,
                          minLines: 3,
                          maxLines: 6,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'Consolas',
                          ),
                          decoration: const InputDecoration(
                            hintText: '粘贴链接或整段配置…',
                          ),
                        ),
                      ),
                      const SizedBox(height: HaloMetrics.blockGap),
                      if (_preview != null) _ImportPreview(result: _preview!),
                      const SizedBox(height: HaloMetrics.blockGap),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SizedBox(
                            width: 240,
                            child: HaloField(
                              label: '订阅名称（仅订阅链接需要）',
                              child: TextField(
                                controller: _name,
                                decoration: const InputDecoration(
                                  hintText: '例如：HK 线路',
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (_preview != null) ...[
                            TextButton(
                              onPressed: () => setState(() => _preview = null),
                              child: const Text('清除预览'),
                            ),
                            const SizedBox(width: 8),
                          ],
                          // The primary action follows the state: parse, then commit.
                          // Two always-visible buttons made the second one look
                          // available before there was anything to commit.
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : (_preview != null &&
                                          _preview!.isEmpty == false
                                      ? _commit
                                      : _parse),
                            icon: const Icon(
                              Icons.fact_check_outlined,
                              size: 15,
                            ),
                            label: Text(
                              _preview != null && _preview!.isEmpty == false
                                  ? '写入节点列表（${_preview!.importedCount}）'
                                  : '解析并预览',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: HaloMetrics.blockGap),
          // Shown when there is anything to file or anything already filed. A
          // group with no subscriptions is still worth showing: the user created
          // it *in order* to put something in it on the next step, and hiding
          // the bar until then would hide the 集合 button that does the filing.
          if (profiles.isNotEmpty || groups.isNotEmpty) ...[
            _groupBar(context, groups, profiles, groupNames),
            const SizedBox(height: HaloMetrics.rowGap),
          ],
          // The list is sized to its content, not stretched to the remaining
          // height. One subscription used to occupy a full-height white card
          // with its single row pinned at the top, which read as a table with
          // 400px of missing rows.
          Expanded(
            child: Card(
              child: profiles.isEmpty
                  ? const EmptyState(
                      title: '还没有订阅',
                      message:
                          '导入订阅后会在这里显示上次更新时间；'
                          '单个分享链接导入的节点直接进「节点」页。',
                      icon: Icons.rss_feed_outlined,
                    )
                  : filtered.isEmpty
                  ? EmptyState(
                      title: '这个集合里还没有订阅',
                      message: '用「移动到集合」把订阅归到一起，或切回「全部」。',
                      icon: Icons.folder_open,
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final profile = filtered[index];
                        final nodes =
                            nodesByProfile[profile.id] ?? const <ProxyNode>[];
                        return _ProfileRow(
                          key: ValueKey('sub-row-${profile.id}'),
                          profile: profile,
                          nodeCount: nodes.length,
                          groupName: profile.groupId == null
                              ? null
                              : groupNames[profile.groupId],
                          groups: groups,
                          proxyAvailable: c.proxyAvailable,
                          onMoveToGroup: () => _moveToGroup(profile, groups),
                          onToggleProxy: (v) {
                            c.setProfileUseProxy(profile.id, v);
                            setState(() {});
                          },
                          selectable: _batchMode,
                          selected: _selected.contains(profile.id),
                          updating: _updating.contains(profile.id),
                          busy: _busy,
                          summary: summarizeSubscriptionLatency(
                            nodes,
                            c.speedResults,
                          ),
                          onToggleSelect: () => _toggleSelected(profile.id),
                          onUpdate: _busy || _updating.contains(profile.id)
                              ? null
                              : () => _updateNow(profile),
                          onEdit: () => _editProfile(profile),
                          onDelete: () => _deleteProfiles([profile]),
                          onToggleAuto: (v) => _toggleAutoUpdate(profile, v),
                          onShowError: () => _showError(profile),
                          onShowUrl: () => _showUrl(profile),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Groups
  // ------------------------------------------------------------------

  /// The chip row above the list: 全部 / 未分组 / each group, plus 集合.
  ///
  /// A filter, not a tree: the point is to cut a long list down to the rows a
  /// user works with, and a second level of nesting would make "which group is
  /// this row in" a question the row itself cannot answer at a glance.
  Widget _groupBar(
    BuildContext context,
    List<SubscriptionGroup> groups,
    List<SubscriptionProfile> profiles,
    Map<String, String> names,
  ) {
    final counts = <String, int>{};
    var ungrouped = 0;
    for (final profile in profiles) {
      final id = profile.groupId;
      if (id == null) {
        ungrouped++;
      } else {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    Widget chip(String? id, String label, int count) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: HaloFilterChip(
          key: ValueKey('sub-group-chip-${id ?? 'all'}'),
          label: label,
          count: count,
          selected: _groupFilter == id,
          onTap: () => setState(() => _groupFilter = id),
        ),
      );
    }

    return SizedBox(
      height: 26,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                chip(null, '全部', profiles.length),
                chip(kUngroupedGroupId, '未分组', ungrouped),
                for (final group in groups)
                  chip(
                    group.id,
                    names[group.id] ?? group.name,
                    counts[group.id] ?? 0,
                  ),
              ],
            ),
          ),
          TextButton.icon(
            key: const ValueKey('sub-group-manage'),
            onPressed: () => _manageGroups(groups, profiles),
            icon: const Icon(Icons.folder_outlined, size: 15),
            label: const Text('集合'),
            style: _compactTextButton,
          ),
        ],
      ),
    );
  }

  /// Create, rename and delete groups in one dialog.
  Future<void> _manageGroups(
    List<SubscriptionGroup> groups,
    List<SubscriptionProfile> profiles,
  ) async {
    final controller = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Read through the controller on every rebuild rather than closing
          // over the `groups`/`profiles` arguments. Those are the snapshots the
          // page had when it opened the dialog, so after a rename the visible
          // rows kept the old names while the database — and the page behind the
          // dialog — already showed the new one.
          final liveGroups = c.loadGroups();
          final liveProfiles = c.loadProfiles();
          void submit() {
            final name = SubscriptionGroup.normalizeName(controller.text);
            if (name == null) {
              setDialogState(() => error = '集合名不能为空');
              return;
            }
            final created = c.saveGroup(name: name);
            if (created == null) {
              setDialogState(() => error = '已存在同名集合');
              return;
            }
            controller.clear();
            setDialogState(() => error = null);
            setState(() {});
          }

          return AlertDialog(
            title: const Text('订阅集合'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('sub-group-name'),
                          controller: controller,
                          decoration: InputDecoration(
                            labelText: '新建集合',
                            errorText: error,
                          ),
                          onSubmitted: (_) => submit(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: submit, child: const Text('新建')),
                    ],
                  ),
                  const SizedBox(height: HaloMetrics.blockGap),
                  if (liveGroups.isEmpty)
                    const Text('还没有集合。集合只是一层分组，删除集合不会删除订阅。')
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final group in liveGroups)
                            ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.folder_outlined,
                                size: 16,
                              ),
                              title: Text(group.name),
                              subtitle: Text(
                                '${liveProfiles.where((p) => p.groupId == group.id).length} 个订阅',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Rename lives on the row rather than on a
                                  // separate "edit mode": the group list is the
                                  // only place a user can be looking when they
                                  // decide a name is wrong.
                                  IconButton(
                                    key: ValueKey(
                                      'sub-group-rename-${group.id}',
                                    ),
                                    tooltip: '重命名集合',
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 16,
                                    ),
                                    onPressed: () async {
                                      final renamed = await _renameGroup(group);
                                      if (renamed) setDialogState(() {});
                                    },
                                  ),
                                  IconButton(
                                    key: ValueKey(
                                      'sub-group-delete-${group.id}',
                                    ),
                                    tooltip: '删除集合（订阅保留，变为未分组）',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 16,
                                    ),
                                    onPressed: () {
                                      final affected = c.deleteGroup(group.id);
                                      setState(() {
                                        if (_groupFilter == group.id) {
                                          _groupFilter = null;
                                        }
                                      });
                                      setDialogState(() {});
                                      _snack('已删除集合，$affected 个订阅变为未分组');
                                    },
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }

  /// Renames [group], keeping its id and therefore its memberships.
  ///
  /// Renaming goes through the id, not through delete-and-recreate: the latter
  /// would drop every subscription in the group back to 未分组, which is the one
  /// outcome a rename must never have.
  ///
  /// The dialog is its own widget so it owns the text controller. Holding the
  /// controller here and disposing it right after `showDialog` returns disposed
  /// it while the route was still animating out, and the still-mounted TextField
  /// then threw `_dependents.isEmpty` on rebuild.
  Future<bool> _renameGroup(SubscriptionGroup group) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameGroupDialog(
        group: group,
        onSave: (name) => c.saveGroup(id: group.id, name: name),
      ),
    );
    if (name == null || !mounted) return false;
    // The chip row is built from the same list, so it needs a repaint too.
    setState(() {});
    return true;
  }

  /// Files [profile] under a group, or creates one on the spot.
  Future<void> _moveToGroup(
    SubscriptionProfile profile,
    List<SubscriptionGroup> groups,
  ) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('把「${profile.name}」移动到'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('__none__'),
            child: const Text('未分组'),
          ),
          for (final group in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(group.id),
              child: Text(group.name),
            ),
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(context).pop();
              _newGroupAndMove(profile);
            },
            child: const Text('新建集合…'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    c.setProfileGroup(profile.id, choice == '__none__' ? null : choice);
    if (mounted) setState(() {});
  }

  Future<void> _newGroupAndMove(SubscriptionProfile profile) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建集合并移入'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '集合名'),
          onSubmitted: (value) =>
              Navigator.of(context).pop(value.trim().isEmpty ? null : value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              controller.text.trim().isEmpty ? null : controller.text.trim(),
            ),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    final group = c.saveGroup(name: name);
    if (group == null) {
      _snack('已存在同名集合');
      return;
    }
    c.setProfileGroup(profile.id, group.id);
    if (mounted) setState(() {});
  }

  /// The import form reduced to a single clickable bar.
  ///
  /// Keeps 导入 visible — the entry point must never disappear — while giving
  /// the space back to the list.
  Widget _collapsedImportHeader(BuildContext context) {
    final p = HaloPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SectionCard(
        key: const ValueKey('sub-import-collapsed'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.add_link, size: 15, color: p.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '导入节点',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              key: const ValueKey('sub-import-expand'),
              onPressed: () => setState(() => _importCollapsed = false),
              icon: const Icon(Icons.expand_more, size: 15),
              label: const Text('展开导入'),
              style: _compactTextButton,
            ),
          ],
        ),
      ),
    );
  }

  /// The header in batch mode: selection first, then what can be done with it.
  List<Widget> _batchActions(
    List<SubscriptionProfile> profiles,
    Set<String> ids,
  ) {
    final selected = profiles.where((p) => _selected.contains(p.id)).toList();
    return [
      TextButton(
        key: const ValueKey('sub-select-all'),
        // Nothing to add once everything is selected; a live button that does
        // nothing reads as broken.
        onPressed: _selected.length < profiles.length
            ? () => setState(
                () => _selected
                  ..clear()
                  ..addAll(ids),
              )
            : null,
        style: _compactTextButton,
        child: const Text('全选'),
      ),
      TextButton(
        key: const ValueKey('sub-clear'),
        onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
        style: _compactTextButton,
        child: const Text('清除'),
      ),
      OutlinedButton.icon(
        key: const ValueKey('sub-batch-update'),
        // A refresh batch already running would make the second one return
        // early per subscription (the controller refuses a profile it is
        // already updating) and report a misleading success count.
        onPressed: _selected.isEmpty || _updating.isNotEmpty
            ? null
            : () => _updateProfiles(selected),
        icon: const Icon(Icons.refresh, size: 15),
        label: const Text('批量更新'),
        style: _compactButton,
      ),
      OutlinedButton.icon(
        key: const ValueKey('sub-batch-delete'),
        onPressed: _selected.isEmpty ? null : () => _deleteProfiles(selected),
        icon: Icon(
          Icons.delete_outline,
          size: 15,
          color: haloAdapt(context, HaloColors.danger),
        ),
        label: const Text('批量删除'),
        style: _compactButton.copyWith(
          foregroundColor: WidgetStatePropertyAll(
            haloAdapt(context, HaloColors.danger),
          ),
        ),
      ),
      TextButton(
        key: const ValueKey('sub-batch-toggle'),
        onPressed: _toggleBatchMode,
        style: _compactTextButton,
        child: const Text('退出批量'),
      ),
    ];
  }

  /// The header when the page is doing its normal job.
  List<Widget> _defaultActions(
    List<SubscriptionProfile> profiles,
    int nodeCount,
    int remoteCount,
  ) {
    final activeId = c.activeNodeId;
    final hasActiveNode = activeId != null && activeId.isNotEmpty;
    return [
      OutlinedButton.icon(
        key: const ValueKey('sub-batch-toggle'),
        onPressed: profiles.isEmpty ? null : _toggleBatchMode,
        icon: const Icon(Icons.checklist_rtl, size: 15),
        label: const Text('批量'),
        style: _compactButton,
      ),
      // 「代理更新」 sits immediately to the left of 全部更新: they are the same
      // action with one different transport, and separating them would suggest
      // a scope difference that does not exist.
      //
      // Text only, no icon: at 1180px/200% the header has 590 logical pixels and
      // the icons plus labels already overflowed by 14px once this button
      // arrived (caught by the 1180px layout test). The tooltip carries the
      // explanation, and the glyph added nothing a two-character label did not.
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Tooltip(
          message: c.proxyAvailable
              ? '本次忽略每行设置，全部经代理下载（${c.proxyEndpoint}）；用于直连下不动的订阅源'
              : '内核未运行，代理端口没人监听；先启动代理再点这里',
          child: OutlinedButton(
            key: const ValueKey('sub-update-all-proxy'),
            onPressed:
                !_busy &&
                    _updating.isEmpty &&
                    remoteCount > 0 &&
                    c.proxyAvailable
                ? () => _updateProfiles(
                    profiles.where(isRemoteProfile).toList(),
                    viaProxy: true,
                  )
                : null,
            style: _compactButton,
            child: const Text('代理更新'),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 8),
        // The rows decide this one, so the tooltip has to say so: otherwise
        // "全部更新" reads as "全部直连", and a source that only works through
        // the proxy looks broken until the user finds the per-row switch.
        child: Tooltip(
          message: '按每行「更新时直连 / 经代理 / 自动」的设置逐个下载',
          child: OutlinedButton.icon(
            key: const ValueKey('sub-update-all'),
            onPressed:
                c.connected && !_busy && _updating.isEmpty && remoteCount > 0
                ? () =>
                      _updateProfiles(profiles.where(isRemoteProfile).toList())
                : null,
            icon: const Icon(Icons.refresh, size: 15),
            label: const Text('全部更新'),
            style: _compactButton,
          ),
        ),
      ),
      if (nodeCount > 0)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: FilledButton.icon(
            onPressed: widget.onOpenNodes,
            icon: Icon(
              // The strongest button on the page should name the real next step.
              // It used to read 下一步：选择节点 unconditionally, long after a node
              // was chosen and enabled — at which point the actual next step is
              // enabling the system proxy or TUN, so the page pointed at work
              // that was already done and disagreed with the status bar.
              hasActiveNode ? Icons.open_in_new : Icons.arrow_forward,
              size: 15,
            ),
            label: Text(hasActiveNode ? '查看节点' : '下一步：选择节点'),
          ),
        ),
    ];
  }
}

/// Compact geometry for the header's and the rows' secondary actions.
///
/// The default button padding is sized for a dialog; four of them in a 56px
/// page header overflow a 1180px window at 200% scaling, where the logical
/// width is only 590.
final ButtonStyle _compactButton = OutlinedButton.styleFrom(
  textStyle: const TextStyle(fontSize: 12.5),
  minimumSize: const Size(0, 32),
  padding: const EdgeInsets.symmetric(horizontal: 10),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

final ButtonStyle _compactTextButton = TextButton.styleFrom(
  textStyle: const TextStyle(fontSize: 12.5),
  minimumSize: const Size(0, 32),
  padding: const EdgeInsets.symmetric(horizontal: 8),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// One subscription record.
///
/// Everything the record can do is visible on the row: test, update, edit,
/// delete and the scheduled-update switch. The previous version put the switch
/// on a long press and offered no delete at all, which meant a subscription
/// could be added and never removed.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    super.key,
    required this.profile,
    required this.nodeCount,
    required this.selectable,
    required this.selected,
    required this.updating,
    required this.summary,
    required this.busy,
    required this.onToggleSelect,
    required this.onUpdate,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleAuto,
    required this.onToggleProxy,
    required this.onMoveToGroup,
    required this.onShowError,
    required this.onShowUrl,
    required this.groups,
    required this.proxyAvailable,
    this.groupName,
  });

  final SubscriptionProfile profile;

  /// Name of the group this row is filed under, or null when ungrouped.
  final String? groupName;

  /// Whether the proxy port has a core behind it right now.
  final bool proxyAvailable;

  /// Every group, for the "move to" dialog this row offers.
  final List<SubscriptionGroup> groups;

  /// The nodes actually in the database, not the count recorded at the last
  /// update: rows deleted on the nodes page must not keep being claimed here.
  final int nodeCount;
  final bool selectable;
  final bool selected;
  final bool updating;
  final SubscriptionLatencySummary summary;
  final bool busy;

  final VoidCallback onToggleSelect;
  final VoidCallback? onUpdate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggleAuto;
  final ValueChanged<bool> onToggleProxy;
  final VoidCallback onMoveToGroup;
  final VoidCallback onShowError;
  final VoidCallback onShowUrl;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final failed = profile.lastError != null;
    final remote = isRemoteProfile(profile);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          if (selectable)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: _SubCheckbox(
                key: ValueKey('sub-check-${profile.id}'),
                checked: selected,
                onTap: onToggleSelect,
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusChip(
                      label: failed ? '更新失败' : (nodeCount > 0 ? '正常' : '无节点'),
                      color: failed
                          ? HaloColors.danger
                          : (nodeCount > 0
                                ? HaloColors.success
                                : HaloColors.warning),
                    ),
                    if (profile.enabled && profile.autoUpdate) ...[
                      const SizedBox(width: 6),
                      StatusChip(
                        label: intervalChipLabel(profile.updateIntervalMinutes),
                        color: HaloColors.info,
                      ),
                    ],
                    // Where the row is filed, on the row itself. Without it a
                    // filtered list is indistinguishable from an unfiltered one
                    // once the chip above scrolls out of view.
                    if (groupName != null) ...[
                      const SizedBox(width: 6),
                      StatusChip(label: groupName!, color: HaloColors.info),
                    ],
                  ],
                ),
                const SizedBox(height: HaloMetrics.hairGap),
                // The masked form, with the full address behind an explicit
                // action. Printing the endpoint verbatim meant a screenshot of
                // the app could carry a working subscription token.
                InkWell(
                  onTap: profile.hasHiddenUrlParts ? onShowUrl : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          '${profile.displayUrl} · $nodeCount 个节点 · '
                          '上次更新 ${formatDateTime(profile.lastUpdatedAtMs)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: p.textSecondary),
                        ),
                      ),
                      if (profile.hasHiddenUrlParts) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.visibility_outlined,
                          size: 11,
                          color: p.textTertiary,
                        ),
                      ],
                    ],
                  ),
                ),
                if (!summary.isUntested) ...[
                  const SizedBox(height: HaloMetrics.hairGap),
                  _LatencyLine(summary: summary),
                ],
                if (failed)
                  // The reason has to be reachable: "更新失败" without a message
                  // leaves the user with no way to tell a dead URL from a
                  // certificate problem.
                  InkWell(
                    onTap: onShowError,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        profile.lastError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: haloAdapt(context, HaloColors.danger),
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // A bare switch next to a 正常 badge read as "disable this
          // subscription", but it only controls auto-update. The label states
          // what the switch actually does and its current position; the tooltip
          // is now a supplement rather than the only explanation.
          Tooltip(
            message: profile.autoUpdate
                ? '每 ${profile.updateIntervalMinutes} 分钟自动获取一次；'
                      '关闭后仍可手动点「更新」'
                : '不自动更新，只能手动点「更新」',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '自动更新',
                  style: TextStyle(fontSize: 11, color: p.textSecondary),
                ),
                const SizedBox(width: 6),
                HaloSwitch(
                  value: profile.enabled && profile.autoUpdate,
                  semanticLabel: '自动更新',
                  onChanged: onToggleAuto,
                ),
              ],
            ),
          ),
          // Only remote rows have something to fetch, so only they get the
          // toggle; showing it on 本地 would imply a download that can never
          // happen.
          //
          // An icon toggle rather than a labelled switch: the row already carries
          // a switch with a label and a 更新 button plus three icons, and at
          // 590px logical the labelled version overflowed the row by 14px. The
          // tooltip and the filled/hollow glyph carry the state instead.
          if (remote) ...[
            const SizedBox(width: 4),
            // Three states have to be distinguishable at a glance:
            //  * on        — the user chose the proxy
            //  * off       — the user chose direct
            //  * automatic — no choice stored; the host policy decides, so a
            //                GitHub row is proxied and everything else is direct
            // Rendering "automatic" as a plain off switch would make the row
            // disagree with what the next update actually does.
            Builder(
              builder: (context) {
                final auto = profile.useProxy == null;
                final effective = profile.useProxyFor(profile.url);
                final label = auto
                    ? (effective
                          ? '更新时经代理（自动：该来源默认走代理，点击改为强制直连）'
                          : '更新时直连（自动：该来源默认直连，点击改为经代理）')
                    : (effective
                          ? '更新时经代理（已手动设定，点击改为直连）'
                          : '更新时直连（已手动设定，点击改为经代理）');
                return IconButton(
                  key: ValueKey('sub-proxy-${profile.id}'),
                  onPressed: busy ? null : () => onToggleProxy(!effective),
                  tooltip: label,
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  isSelected: effective,
                  icon: Icon(
                    effective ? Icons.vpn_lock : Icons.vpn_lock_outlined,
                    color: auto
                        ? (effective ? p.accent : p.textTertiary)
                        : (effective ? p.accent : p.textSecondary),
                  ),
                );
              },
            ),
          ],
          const SizedBox(width: 6),
          Tooltip(
            // The row's own 更新 button uses the same decision the batch does;
            // saying it here is the only way to check it without watching the
            // proxy's connection list.
            message:
                '更新：${profile.useProxyFor(profile.url) ? '经代理' : '直连'}'
                '${profile.useProxy == null ? '（自动）' : ''}',
            child: TextButton.icon(
              key: ValueKey('sub-update-${profile.id}'),
              onPressed: onUpdate,
              icon: updating
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const Icon(Icons.refresh, size: 15),
              label: Text(updating ? '更新中' : '更新'),
              style: _compactTextButton,
            ),
          ),
          IconButton(
            key: ValueKey('sub-group-${profile.id}'),
            onPressed: busy ? null : onMoveToGroup,
            tooltip: groupName == null ? '移动到集合' : '移动到其他集合',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.drive_file_move_outline),
          ),
          IconButton(
            onPressed: busy ? null : onEdit,
            tooltip: '编辑订阅',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            onPressed: busy ? null : onDelete,
            tooltip: remote ? '删除订阅及其节点' : '删除订阅',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.delete_outline,
              color: haloAdapt(context, HaloColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// The row's latency roll-up for this subscription's nodes.
class _LatencyLine extends StatelessWidget {
  const _LatencyLine({required this.summary});

  final SubscriptionLatencySummary summary;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final average = summary.averageMs;
    return Text(
      summary.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        // Same three bands as the node table: one scale, so a number cannot
        // read as fast here and slow one page over. The average carries the
        // colour because it describes the subscription, not its best node.
        color: average == null
            ? p.textTertiary
            : haloAdapt(context, latencyColor(average)),
      ),
    );
  }
}

/// A Fluent checkbox.
///
/// Material's is 48px of tap target with its own ripple geometry, twice the
/// height of the controls next to it; this keeps the 16px box and the palette
/// the rest of the page uses.
class _SubCheckbox extends StatelessWidget {
  const _SubCheckbox({super.key, required this.checked, required this.onTap});

  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Semantics(
      checked: checked,
      label: '选择订阅',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: checked ? p.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: checked ? p.accent : p.borderStrong,
                width: checked ? 1 : 1.2,
              ),
            ),
            child: checked
                ? Icon(Icons.check, size: 12, color: p.onAccent)
                : null,
          ),
        ),
      ),
    );
  }
}

class _ImportPreview extends StatelessWidget {
  const _ImportPreview({required this.result});

  final ImportResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? HaloColors.darkSurfaceAlt
            : HaloColors.lightSurfaceAlt,
        borderRadius: BorderRadius.circular(HaloMetrics.radius),
      ),
      padding: const EdgeInsets.all(8),
      child: Scrollbar(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '格式：${result.sourceFormat} · 成功 ${result.importedCount} · '
                '跳过 ${result.skippedCount} · 失败 ${result.failedCount}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: HaloMetrics.rowGap),
              // Failures are listed with their reason so a paste that half
              // worked is obvious before anything is written.
              for (final issue in result.failed.take(20))
                Text(
                  '第 ${issue.line ?? '?'} 项：${issue.message}${issue.note == null ? '' : '（${issue.note}）'}',
                  style: TextStyle(
                    fontSize: 11,
                    color: haloAdapt(context, HaloColors.danger),
                  ),
                ),
              for (final node in result.nodes.take(8))
                Text(
                  '+ ${node.name} (${node.protocol.label})',
                  style: const TextStyle(fontSize: 11),
                ),
              if (result.nodes.length > 8)
                Text(
                  '… 其余 ${result.nodes.length - 8} 个节点',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renames one subscription group.
///
/// A StatefulWidget rather than a `StatefulBuilder` inside the caller, because
/// the text controller's lifetime has to follow the *route's*, not the caller's:
/// disposing it as soon as `showDialog` completes happens while the exit
/// animation still has the TextField mounted, which trips a framework assertion
/// on the next rebuild.
class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.group, required this.onSave});

  final SubscriptionGroup group;

  /// Persists the new name. Returns the stored group, or null when the name is
  /// empty or already taken by another group.
  final SubscriptionGroup? Function(String name) onSave;

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.group.name,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = SubscriptionGroup.normalizeName(_controller.text);
    if (name == null) {
      setState(() => _error = '集合名不能为空');
      return;
    }
    if (name == widget.group.name) {
      // A no-op rename must not look like a failure; closing is the honest
      // answer.
      Navigator.of(context).pop(name);
      return;
    }
    final saved = widget.onSave(name);
    if (saved == null) {
      // The repository refuses a name another group already has instead of
      // merging them: merging would file subscriptions the user never selected
      // under a different group, with no undo.
      setState(() => _error = '已存在同名集合');
      return;
    }
    Navigator.of(context).pop(saved.name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名集合'),
      content: TextField(
        key: const ValueKey('sub-group-rename-field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: '集合名', errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('sub-group-rename-save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
