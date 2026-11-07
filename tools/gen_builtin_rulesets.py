"""Generate the built-in rule-set catalogue from Clash Verge Rev's live profile.

Reads `clash-verge.yaml` from %APPDATA%, converts each `rule-providers` entry to
the sing-box `inline` rule_set shape, and writes one Dart file with the payloads
plus a small metadata table (tag, Chinese label, entry count, category).

Dev-time tool, run from the repo root:

    python tools/gen_builtin_rulesets.py
"""

import io
import json
import os
import re

SRC = os.path.join(
    os.environ['APPDATA'],
    'io.github.clash-verge-rev.clash-verge-rev',
    'clash-verge.yaml',
)
OUT = 'packages/config/lib/src/builtin_rulesets.dart'

# Chinese labels for the tags Verge ships. Anything unknown keeps its tag, which
# is honest rather than a guessed translation.
LABELS = {
    'geosite-youtube': 'YouTube',
    'geosite-bilibili': '哔哩哔哩',
    'geosite-netflix': 'Netflix',
    'geosite-disney': 'Disney+',
    'geosite-category-ai': 'AI 服务',
    'geosite-github': 'GitHub',
    'geosite-telegram': 'Telegram',
    'geosite-google': 'Google',
    'geosite-apple': 'Apple',
    'geosite-microsoft': '微软',
    'geosite-tiktok': 'TikTok',
    'geosite-category-games': '游戏平台',
    'geosite-private': '私有域名',
    'geosite-geolocation': '地理定位/广告',
    'geoip-private': '私有地址段',
    'geoip-cn': '中国大陆 IP',
    'geoip-netflix': 'Netflix IP',
    'geoip-telegram': 'Telegram IP',
}

# Order matters: it is the match order in the generated document, and Verge's
# order is the one with the observed behaviour. geosite-geolocation must come
# before geoip-cn, or Chinese CDN domains would be captured by the IP rule.
ORDER = [
    'geosite-youtube',
    'geosite-bilibili',
    'geosite-netflix',
    'geosite-disney',
    'geosite-category-ai',
    'geosite-github',
    'geosite-telegram',
    'geosite-google',
    'geosite-apple',
    'geosite-microsoft',
    'geosite-tiktok',
    'geosite-category-games',
    'geosite-private',
    'geosite-geolocation',
    'geoip-private',
    'geoip-netflix',
    'geoip-telegram',
    'geoip-cn',
]


def parse_providers():
    lines = io.open(SRC, encoding='utf-8').read().split('\n')
    start = next(i for i, l in enumerate(lines) if l.startswith('rule-providers:'))
    end = next(i for i, l in enumerate(lines) if l.startswith('rules:'))
    prov = {}
    cur = None
    for line in lines[start + 1:end]:
        m = re.match(r'^  ([\w\-\.]+):\s*$', line)
        if m:
            cur = m.group(1)
            prov[cur] = {'behavior': None, 'items': []}
            continue
        if cur is None:
            continue
        m = re.match(r'^    behavior:\s*(\S+)', line)
        if m:
            prov[cur]['behavior'] = m.group(1)
            continue
        m = re.match(r'^    - (.+)$', line)
        if m:
            prov[cur]['items'].append(m.group(1).strip())
    return prov


def to_rules(items, behavior):
    """Clash provider items -> sing-box rule payloads.

    `domain` behaviour is a mix of bare hosts and `+.suffix` wildcards; sing-box
    distinguishes `domain` (exact) from `domain_suffix` (suffix), so the list is
    split instead of being approximated with one kind.
    """
    if behavior == 'ipcidr':
        return [{'ip_cidr': items}]
    suffix, exact = [], []
    for item in items:
        value = item.strip()
        if not value:
            continue
        if value.startswith('+.') or value.startswith('*.'):
            suffix.append(value[2:])
        elif value.startswith('.'):
            suffix.append(value[1:])
        else:
            exact.append(value)
    out = []
    if exact:
        out.append({'domain': exact})
    if suffix:
        out.append({'domain_suffix': suffix})
    return out


def main():
    prov = parse_providers()
    missing = [t for t in ORDER if t not in prov]
    if missing:
        raise SystemExit(f'参考配置缺少这些规则集: {missing}')

    entries = []
    for tag in ORDER:
        info = prov[tag]
        rules = to_rules(info['items'], info['behavior'])
        count = sum(len(next(iter(r.values()))) for r in rules)
        entries.append(
            {
                'tag': tag,
                'label': LABELS.get(tag, tag),
                'kind': 'ip' if info['behavior'] == 'ipcidr' else 'domain',
                'count': count,
                'rules': rules,
            }
        )

    total = sum(e['count'] for e in entries)

    body = io.StringIO()
    body.write('''/// Built-in rule sets, generated from Clash Verge Rev's live profile.
///
/// **Generated file — do not edit by hand.** Regenerate with
/// `python tools/gen_builtin_rulesets.py`, which reads the reference client's
/// `clash-verge.yaml` and rewrites this file.
///
/// Why these live in code rather than being downloaded: the app has no
/// rule-provider fetcher, and adding one would make routing depend on a network
/// call at apply time — a failure mode where the proxy rules silently fall back
/// to "everything through the proxy" is worse than shipping a fixed snapshot.
/// The cost is size: the payloads total roughly 640 KB of JSON, which is why
/// they are stored as compact string literals and decoded once, not as nested
/// Dart maps that the compiler would have to emit as thousands of instructions.
library;

import 'dart:convert';

/// One built-in rule set: identity, display metadata and the sing-box payloads.
class BuiltinRuleSet {
  const BuiltinRuleSet({
    required this.tag,
    required this.label,
    required this.kind,
    required this.entryCount,
    required this.payloadJson,
  });

  /// Stable id, also the `tag` written into `route.rule_set`.
  final String tag;

  /// Chinese label the rules page shows.
  final String label;

  /// `domain` or `ip`, so the UI can say what an entry matches.
  final String kind;

  /// How many individual entries the set carries, for the UI's summary.
  final int entryCount;

  /// The `rules` array of the sing-box `inline` rule_set, as compact JSON.
  ///
  /// A string rather than a `List<Map>` because a 22k-entry list built as Dart
  /// literals is ~10x the source size and slows every start-up; the generator
  /// only needs to splice it into the document once.
  final String payloadJson;
}

/// Every built-in rule set, in match order.
const List<BuiltinRuleSet> builtinRuleSets = [
''')

    for e in entries:
        payload = json.dumps(e['rules'], separators=(',', ':'), ensure_ascii=False)
        # Escape for a Dart raw-ish single-quoted string: the payload contains
        # no apostrophes (domain names never do) but may contain $, which would
        # start an interpolation if the string were not raw.
        assert "'''" not in payload
        assert '$' not in payload, 'payload contains $'
        assert "'" not in payload, 'payload contains a single quote'
        body.write("  BuiltinRuleSet(\n")
        body.write(f"    tag: '{e['tag']}',\n")
        body.write(f"    label: '{e['label']}',\n")
        body.write(f"    kind: '{e['kind']}',\n")
        body.write(f"    entryCount: {e['count']},\n")
        body.write("    payloadJson:\n")
        body.write(f"        r'''{payload}''',\n")
        body.write('  ),\n')

    body.write('''];

/// Decodes one set's payload for the generator.
///
/// Cached per tag: the generator asks once per apply, but a user who toggles a
/// few rules re-applies repeatedly, and re-parsing 369 KB of JSON for the
/// geolocation set on every keystroke-driven rebuild was measurable. The cache
/// is process-wide and the payloads are immutable, so there is nothing to
/// invalidate.
final Map<String, List<Map<String, Object?>>> _payloadCache = {};

List<Map<String, Object?>> decodeRuleSetPayload(BuiltinRuleSet set) {
  final cached = _payloadCache[set.tag];
  if (cached != null) return cached;
  final decoded = jsonDecode(set.payloadJson);
  final rules = <Map<String, Object?>>[
    for (final entry in decoded as List)
      (entry as Map).cast<String, Object?>(),
  ];
  return _payloadCache[set.tag] = rules;
}

/// Total entries across every built-in set.
int get builtinRuleSetEntryTotal =>
    builtinRuleSets.fold(0, (sum, set) => sum + set.entryCount);

/// Looks a set up by tag.
BuiltinRuleSet? builtinRuleSetByTag(String tag) {
  for (final set in builtinRuleSets) {
    if (set.tag == tag) return set;
  }
  return null;
}
''')

    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(body.getvalue())
    size = os.path.getsize(OUT)
    print(f'wrote {OUT}: {len(entries)} rule sets, {total} entries, {size/1024:.0f} KB')


if __name__ == '__main__':
    main()
