import 'dart:convert';
import 'dart:io';

import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';

/// Builds a document containing one rule of each kind and checks it against the
/// real sing-box binary. A rule the core rejects would only surface at apply
/// time in the app, as "配置校验失败" with no hint of which rule caused it.
void main() async {
  final node = ProxyNode(
    id: 'n1',
    fingerprint: 'fp-probe',
    name: 'probe',
    protocol: ProxyProtocol.shadowsocks,
    server: '127.0.0.1',
    port: 1,
    secrets: const NodeSecrets(method: 'aes-256-gcm', password: 'x'),
    createdAtMs: 0,
  );

  final rules = <RoutingRule>[
    const RoutingRule(id: '1', kind: RuleKind.domainSuffix, value: 'example.com', action: RuleAction.direct),
    const RoutingRule(id: '2', kind: RuleKind.domain, value: 'exact.example.com', action: RuleAction.direct),
    const RoutingRule(id: '3', kind: RuleKind.domainKeyword, value: 'ads', action: RuleAction.direct),
    const RoutingRule(id: '4', kind: RuleKind.ipCidr, value: '10.0.0.0/8', action: RuleAction.direct),
    const RoutingRule(id: '5', kind: RuleKind.ipCidr, value: 'fd00::/8', action: RuleAction.direct),
    const RoutingRule(id: '6', kind: RuleKind.processName, value: 'chrome.exe', action: RuleAction.direct),
    const RoutingRule(id: '7', kind: RuleKind.processPath, value: r'C:\Games\x.exe', action: RuleAction.direct),
    const RoutingRule(id: '8', kind: RuleKind.port, value: '22', action: RuleAction.proxy),
    // Disabled: must not appear in the document at all.
    const RoutingRule(id: '9', kind: RuleKind.domainSuffix, value: 'skip.example', action: RuleAction.direct, enabled: false),
  ];

  final built = buildConfig(
    ConfigRequest(
      node: node,
      mode: RouteMode.rule,
      ports: const InboundPorts(mixed: 17888, clashApi: 9098),
      rules: rules,
    ),
    CoreCapabilities.singbox114,
  );
  if (!built.ok) {
    stderr.writeln('build failed: ${built.issues.map((i) => i.message).join('; ')}');
    exit(2);
  }
  final document = built.config!.document;

  // Disabled rule must be absent.
  final routeRules = (document['route'] as Map)['rules'] as List;
  final encoded = jsonEncode(routeRules);
  if (encoded.contains('skip.example')) {
    stderr.writeln('FAIL: disabled rule reached the document');
    exit(3);
  }
  for (final needle in ['example.com', 'exact.example.com', 'ads', '10.0.0.0/8', 'fd00::/8', 'chrome.exe', '22']) {
    if (!encoded.contains(needle)) {
      stderr.writeln('FAIL: rule value missing from document: $needle');
      exit(4);
    }
  }

  final file = File('_generated_rules.json');
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(document));
  stdout.writeln('rule count in document: $routeRules'.split(':').last);

  final result = await Process.run(
    '../../prototype/bin/sing-box.exe',
    ['check', '-c', file.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final output = '${result.stdout}${result.stderr}'.trim();
  stdout.writeln('sing-box check exit=${result.exitCode} ${output.isEmpty ? "(no output)" : output}');
  file.deleteSync();
  if (result.exitCode != 0) exit(5);
  stdout.writeln('PASS');
}
