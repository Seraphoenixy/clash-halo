import 'package:flutter/material.dart';
import 'package:halo_config/halo_config.dart';
import 'package:halo_contracts/halo_contracts.dart';

import '../../state/app_controller.dart';
import '../../theme.dart';
import '../app.dart';
import '../widgets.dart';

/// Routing rules: which traffic should not go through the proxy.
///
/// Replaces the old 「分流与 DNS」 page, which carried a second copy of the mode
/// selector already on 总览, ports nobody changes, and a preview pane. What it
/// never carried was the thing the name promised: actual rules. A user who
/// wants "this site should go direct" had no way to say so.
///
/// Design notes:
///  * Rules are ordered and the order is visible. First match wins in the
///    generated document, so a list that hid its order would make a rule that
///    never fires look like a rule that is broken.
///  * Every edit applies only after 保存并应用. Nothing here mutates the running
///    core on keystroke: a half-typed domain must never become a live rule.
///  * Invalid input is refused at the field, not at apply time. `sing-box check`
///    would report the failure as a whole-document error with no line number.
class RulesPage extends StatefulWidget {
  const RulesPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  late List<RoutingRule> _draft;
  late List<RoutingRule> _saved;
  bool _busy = false;
  String? _notice;
  String? _error;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _saved = List<RoutingRule>.of(c.routing.rules);
    _draft = List<RoutingRule>.of(_saved);
  }

  @override
  void didUpdateWidget(covariant RulesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final latest = c.routing.rules;
    if (!_dirty && !_sameRules(latest, _saved)) {
      setState(() {
        _saved = List<RoutingRule>.of(latest);
        _draft = List<RoutingRule>.of(latest);
      });
    }
  }

  static bool _sameRules(List<RoutingRule> a, List<RoutingRule> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool get _dirty => !_sameRules(_draft, _saved);

  Future<void> _apply() async {
    // Validate the whole list before touching the database: a save that wrote
    // half the rules and then failed would leave the stored set disagreeing
    // with the screen.
    for (final rule in _draft) {
      final problem = validateRuleValue(rule.kind, rule.value);
      if (problem != null) {
        setState(() {
          _error = '「${rule.value}」无法保存：$problem';
          _notice = null;
        });
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await c.saveRouting(c.routing.copyWith(rules: _draft));
      // Ask, do not assume. saveRouting is a no-op on the core when no node is
      // active, and the first version of this notice claimed the config had
      // been reapplied in exactly that case — a message that says something
      // happened when nothing did is worse than saying nothing.
      final applied = c.snapshot?.activeNodeId?.isNotEmpty ?? false;
      if (mounted) {
        setState(() {
          _saved = List<RoutingRule>.of(_draft);
          _notice = applied && c.connected
              ? '规则已保存，并已重新生成配置应用到运行中的内核。'
              : '规则已保存。当前没有启用中的节点，下次启用节点时会带上这些规则。';
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addRule() async {
    final created = await showDialog<RoutingRule>(
      context: context,
      builder: (_) => _RuleEditorDialog(existingLabels: _draft),
    );
    if (created == null || !mounted) return;
    setState(() {
      _draft = [..._draft, created];
      _notice = null;
      _error = null;
    });
  }

  Future<void> _editRule(int index) async {
    final updated = await showDialog<RoutingRule>(
      context: context,
      builder: (_) =>
          _RuleEditorDialog(existingLabels: _draft, initial: _draft[index]),
    );
    if (updated == null || !mounted) return;
    setState(() {
      final next = List<RoutingRule>.of(_draft);
      next[index] = updated;
      _draft = next;
      _notice = null;
      _error = null;
    });
  }

  void _removeRule(int index) {
    setState(() {
      final next = List<RoutingRule>.of(_draft)..removeAt(index);
      _draft = next;
      _notice = null;
    });
  }

  void _reorder(int from, int to) {
    if (to < 0 || to >= _draft.length || from == to) return;
    setState(() {
      final next = List<RoutingRule>.of(_draft);
      final item = next.removeAt(from);
      next.insert(to, item);
      _draft = next;
    });
  }

  void _toggle(int index, bool value) {
    setState(() {
      final next = List<RoutingRule>.of(_draft);
      next[index] = next[index].copyWith(enabled: value);
      _draft = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final snapshot = c.snapshot;
    final mode = c.routing.mode;
    final ruleModeActive = mode == RouteMode.rule;

    return HaloPageScaffold(
      title: '规则',
      subtitle: _draft.isEmpty
          ? '让指定流量直连，不走代理'
          : '按顺序匹配，共 ${_draft.length} 条 · 第一条命中的规则决定走向',
      actions: [
        if (_dirty)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              '未保存',
              style: TextStyle(
                fontSize: 11.5,
                color: haloAdapt(context, HaloColors.warning),
              ),
            ),
          ),
        OutlinedButton.icon(
          key: const ValueKey('rules-add'),
          onPressed: _busy ? null : _addRule,
          icon: const Icon(Icons.add, size: 15),
          label: const Text('添加规则'),
          style: _compactButton,
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          key: const ValueKey('rules-apply'),
          onPressed: _busy || !_dirty ? null : _apply,
          icon: const Icon(Icons.check, size: 15),
          label: const Text('保存并应用'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!ruleModeActive)
            _ModeWarning(
              mode: mode,
              enabled: c.connected && !_busy,
              onSwitch: () async {
                setState(() => _busy = true);
                try {
                  await c.setMode(ProxyMode.rule);
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
            ),
          if (_notice != null)
            _Banner(
              text: _notice!,
              color: haloAdapt(context, HaloColors.success),
            ),
          if (_error != null)
            _Banner(
              text: _error!,
              color: haloAdapt(context, HaloColors.danger),
            ),
          Expanded(
            child: _draft.isEmpty
                ? EmptyState(
                    title: '还没有规则',
                    message:
                        '添加规则后，匹配的流量会按你指定的方式走。\n'
                        '例如把常访问的国内站点设为直连，避免绕一圈代理。',
                    icon: Icons.alt_route_outlined,
                    action: OutlinedButton.icon(
                      onPressed: _busy ? null : _addRule,
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('添加第一条规则'),
                    ),
                  )
                : Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                          child: Row(
                            children: [
                              Text(
                                '规则列表',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: p.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '从上到下依次匹配',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: p.textTertiary,
                                ),
                              ),
                              const Spacer(),
                              if (snapshot?.activeNodeId == null)
                                Text(
                                  '尚未选择节点，规则保存后不会立即生效',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: p.textTertiary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView.separated(
                            key: const ValueKey('rules-list'),
                            itemCount: _draft.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final rule = _draft[index];
                              return _RuleRow(
                                key: ValueKey('rule-${rule.id}'),
                                rule: rule,
                                index: index,
                                total: _draft.length,
                                busy: _busy,
                                onToggle: (v) => _toggle(index, v),
                                onEdit: () => _editRule(index),
                                onRemove: () => _removeRule(index),
                                onUp: () => _reorder(index, index - 1),
                                onDown: () => _reorder(index, index + 1),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Says plainly that the rules below are not in effect right now.
///
/// Without this the page silently lies: the list is full of rules, the mode is
/// 全局, and nothing the user configured is happening.
class _ModeWarning extends StatelessWidget {
  const _ModeWarning({
    required this.mode,
    required this.enabled,
    required this.onSwitch,
  });

  final RouteMode mode;
  final bool enabled;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: haloAdapt(context, HaloColors.warning).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 16,
            color: haloAdapt(context, HaloColors.warning),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前是「${mode == RouteMode.global ? '全局' : '直连'}」模式，'
              '这些规则不会生效。规则只在「规则」模式下使用。',
              style: TextStyle(fontSize: 12, color: p.textPrimary),
            ),
          ),
          TextButton(
            onPressed: enabled ? onSwitch : null,
            child: const Text('切换到规则模式'),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.rule,
    required this.index,
    required this.total,
    required this.busy,
    required this.onToggle,
    required this.onEdit,
    required this.onRemove,
    required this.onUp,
    required this.onDown,
  });

  final RoutingRule rule;
  final int index;
  final int total;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    final p = HaloPalette.of(context);
    final dim = !rule.enabled;
    final direct = rule.action == RuleAction.direct;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${index + 1}',
              style: TextStyle(fontSize: 11.5, color: p.textTertiary),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: p.pressed,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        rule.kind.label,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: p.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        // A rule-set rule's value is an internal tag
                        // (`geosite-youtube`). The list shows the label the user
                        // picked, with the tag kept after it so the stored value
                        // is still visible for anyone comparing with the
                        // generated document.
                        rule.kind == RuleKind.ruleSet
                            ? _ruleSetLabel(rule.value)
                            : rule.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: rule.kind == RuleKind.ruleSet
                              ? null
                              : 'Consolas',
                          color: dim ? p.textTertiary : p.textPrimary,
                          decoration: dim ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                  ],
                ),
                if (rule.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      rule.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: p.textTertiary),
                    ),
                  ),
              ],
            ),
          ),
          // A StatusChip, not a hand-drawn pill: the hand-drawn one had its own
          // radius (10 vs 4+4), its own alpha (0.14 vs 0.10/0.18) and its own
          // text size, so the same kind of label looked different here than on
          // every other page that shows a state.
          StatusChip(
            label: rule.action.label,
            color: direct ? HaloColors.lightTextSecondary : HaloColors.primary,
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: busy ? null : () => onToggle(!rule.enabled),
            tooltip: rule.enabled ? '停用这条规则' : '启用这条规则',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              rule.enabled
                  ? Icons.toggle_on_outlined
                  : Icons.toggle_off_outlined,
              color: rule.enabled ? p.accent : p.textTertiary,
            ),
          ),
          IconButton(
            onPressed: busy || index == 0 ? null : onUp,
            tooltip: '上移',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            onPressed: busy || index == total - 1 ? null : onDown,
            tooltip: '下移',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_downward),
          ),
          IconButton(
            onPressed: busy ? null : onEdit,
            tooltip: '编辑规则',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            onPressed: busy ? null : onRemove,
            tooltip: '删除规则',
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

/// Add / edit one rule.
///
/// Validation runs on every keystroke and blocks 保存, so the dialog cannot
/// produce a rule the generator would refuse.
class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog({required this.existingLabels, this.initial});

  final List<RoutingRule> existingLabels;
  final RoutingRule? initial;

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  late RuleKind _kind;
  late RuleAction _action;
  late TextEditingController _value;
  late TextEditingController _note;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _kind = initial?.kind ?? RuleKind.domainSuffix;
    _action = initial?.action ?? RuleAction.direct;
    _enabled = initial?.enabled ?? true;
    _value = TextEditingController(text: initial?.value ?? '');
    _note = TextEditingController(text: initial?.note ?? '');
  }

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  String? get _problem => validateRuleValue(_kind, _value.text);

  /// Whether the field has been touched, so an error may be shown.
  ///
  /// `validateRuleValue` returns 「不能为空」 for empty input, which is correct
  /// — and which, rendered unconditionally, framed the field in red the instant
  /// the dialog opened. The user had not typed anything yet and was already
  /// being told they were wrong. The empty case is a *prompt*, not an error, so
  /// errors appear only after a keystroke or a submit attempt; 保存 stays
  /// disabled until the value is valid.
  bool _touched = false;

  /// The error to display, or null while the field is still pristine.
  String? get _visibleError {
    if (!_touched) return _duplicate;
    return _duplicate ?? _problem;
  }

  /// A duplicate is not an error the core would catch, but it is always a
  /// mistake: the later copy can never match, because the earlier one already
  /// did. Refusing it here is friendlier than a rule that silently never fires.
  String? get _duplicate {
    final text = _value.text.trim();
    if (text.isEmpty) return null;
    for (final other in widget.existingLabels) {
      if (identical(other, widget.initial)) continue;
      if (other.id == widget.initial?.id) continue;
      if (other.kind == _kind &&
          other.value.trim().toLowerCase() == text.toLowerCase()) {
        return '已存在相同的规则';
      }
    }
    return null;
  }

  bool get _canSave => _problem == null && _duplicate == null;

  void _save() {
    if (!_canSave) return;
    final initial = widget.initial;
    Navigator.of(context).pop(
      RoutingRule(
        id: initial?.id ?? 'new-${DateTime.now().microsecondsSinceEpoch}',
        kind: _kind,
        value: _value.text.trim(),
        action: _action,
        enabled: _enabled,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '添加规则' : '编辑规则'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HaloField(
              label: '匹配类型',
              // A dropdown, not seven equal segments.
              //
              // HaloSelector splits its width evenly, so 域名（精确） and
              // 域名关键字 were each given one seventh of 460 px — about 60 px
              // — and wrapped onto two lines while 端口 sat on one. Mixed line
              // counts inside one control made the row look broken, and the
              // widest label was the one a user most needs to read correctly.
              // The option set is also open-ended (seven today), which is
              // exactly the case a dropdown handles and a segmented control
              // does not.
              child: HaloDropdown<RuleKind>(
                key: const ValueKey('rule-kind'),
                value: _kind,
                hint: '选择匹配类型',
                items: [for (final kind in RuleKind.values) (kind, kind.label)],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    // A tag and a domain cannot share a field: keeping the old
                    // text would leave 域名（精确） pre-filled with
                    // `geosite-youtube`, which validation would then reject as
                    // "不要带 '-'…" only after the user had already chosen.
                    if (v == RuleKind.ruleSet && _kind != RuleKind.ruleSet) {
                      _value.clear();
                    } else if (v != RuleKind.ruleSet &&
                        _kind == RuleKind.ruleSet) {
                      _value.clear();
                    }
                    _kind = v;
                    _touched = false;
                  });
                },
              ),
            ),
            const SizedBox(height: HaloMetrics.blockGap),
            HaloField(
              label: _kind == RuleKind.ruleSet ? '规则集' : '匹配内容',
              child: _kind == RuleKind.ruleSet
                  // A dropdown, not a text field. The operand is a tag like
                  // `geosite-category-ai`, and asking a user to type that from
                  // memory would produce a rule that either never matches or
                  // fails validation for a name they cannot see anywhere.
                  //
                  // The label carries the entry count because the sets differ
                  // by three orders of magnitude (24 vs 22,891 entries), which
                  // is the difference between "cheap" and "noticeably larger
                  // config".
                  ? HaloDropdown<String>(
                      key: const ValueKey('rule-ruleset'),
                      value: _value.text.isEmpty ? null : _value.text,
                      hint: '选择内置规则集',
                      width: double.infinity,
                      items: [
                        for (final set in builtinRuleSets)
                          (
                            set.tag,
                            '${set.label} · ${set.entryCount} 条'
                                '${set.kind == 'ip' ? '（IP）' : ''}',
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _value.text = v;
                          _touched = true;
                        });
                      },
                    )
                  : TextField(
                      key: const ValueKey('rule-value'),
                      controller: _value,
                      autofocus: true,
                      onChanged: (_) => setState(() => _touched = true),
                      onSubmitted: (_) {
                        setState(() => _touched = true);
                        if (_canSave) _save();
                      },
                      decoration: InputDecoration(
                        hintText: _hintFor(_kind),
                        errorText: _visibleError,
                      ),
                    ),
            ),
            // The dropdown has no `errorText`, so the shared validation result
            // is shown once underneath instead.
            if (_kind == RuleKind.ruleSet && _visibleError != null) ...[
              const SizedBox(height: HaloMetrics.lineGap),
              Text(
                _visibleError!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: haloAdapt(context, HaloColors.danger),
                ),
              ),
            ],
            const SizedBox(height: HaloMetrics.blockGap),
            HaloField(
              label: '走向',
              child: HaloSelector<RuleAction>(
                options: [
                  for (final action in RuleAction.values)
                    (action, action.label),
                ],
                value: _action,
                onChanged: (v) => setState(() => _action = v),
              ),
            ),
            const SizedBox(height: HaloMetrics.blockGap),
            HaloField(
              label: '备注（可选）',
              child: TextField(
                controller: _note,
                decoration: const InputDecoration(hintText: '例如：内网服务，不经代理'),
              ),
            ),
            const SizedBox(height: HaloMetrics.blockGap),
            Row(
              children: [
                HaloSwitch(
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                const SizedBox(width: 10),
                Text(
                  _enabled ? '启用' : '停用（保存但不下发到配置）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('rule-save'),
          onPressed: _canSave ? _save : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// Display text for a rule that references a built-in set.
///
/// Falls back to the bare tag for a tag this build no longer ships, rather than
/// showing nothing: an unreadable rule is still better than an invisible one,
/// because the user can then delete it.
String _ruleSetLabel(String tag) {
  final set = builtinRuleSetByTag(tag.trim());
  if (set == null) return '$tag（已不存在）';
  return '${set.label} · ${set.entryCount} 条（$tag）';
}

String _hintFor(RuleKind kind) {
  switch (kind) {
    case RuleKind.ruleSet:
      // Unreachable: this kind renders a dropdown, not a free-text field. The
      // case exists because the switch is exhaustive.
      return '从上方列表选择';
    case RuleKind.domain:
      return 'exact.example.com';
    case RuleKind.domainSuffix:
      return 'example.com（含所有子域名）';
    case RuleKind.domainKeyword:
      return 'ads';
    case RuleKind.ipCidr:
      return '10.0.0.0/8 或 fd00::/8';
    case RuleKind.processName:
      return 'chrome.exe';
    case RuleKind.processPath:
      return r'C:\Games\game.exe';
    case RuleKind.port:
      return '22';
  }
}

final ButtonStyle _compactButton = OutlinedButton.styleFrom(
  textStyle: const TextStyle(fontSize: 12.5),
  minimumSize: const Size(0, 32),
  padding: const EdgeInsets.symmetric(horizontal: 12),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);
