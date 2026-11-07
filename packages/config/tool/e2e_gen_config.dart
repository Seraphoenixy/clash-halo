// Generates a config containing user rules, for the end-to-end pipe check.
//
// Split from the pipe call on purpose: scripts/host-action.ps1 already speaks
// the protocol correctly, and re-implementing a Windows named-pipe client in
// Dart would test the client rather than the rules.
import 'dart:io';

import 'package:halo_config/halo_config.dart';
import 'package:halo_domain/halo_domain.dart';

void main(List<String> args) {
  final out = args.isEmpty ? '_e2e_config.json' : args.first;

  final rules = <RoutingRule>[
    const RoutingRule(
      id: 'e2e1',
      kind: RuleKind.domainSuffix,
      value: 'e2e-probe.example',
      action: RuleAction.direct,
    ),
    const RoutingRule(
      id: 'e2e2',
      kind: RuleKind.ipCidr,
      value: '203.0.113.0/24',
      action: RuleAction.direct,
    ),
    // Must not appear: proves disabling works end to end, not just in a unit
    // test of the pure function.
    const RoutingRule(
      id: 'e2e3',
      kind: RuleKind.domainSuffix,
      value: 'e2e-disabled.example',
      action: RuleAction.direct,
      enabled: false,
    ),
  ];

  final built = buildConfig(
    ConfigRequest(
      node: ProxyNode(
        id: 'e2e-node',
        fingerprint: 'e2e-fp',
        name: 'e2e probe',
        protocol: ProxyProtocol.shadowsocks,
        server: '127.0.0.1',
        port: 1,
        secrets: const NodeSecrets(method: 'aes-256-gcm', password: 'x'),
      ),
      mode: RouteMode.rule,
      ports: const InboundPorts(mixed: 7890, clashApi: 9090),
      rules: rules,
    ),
    CoreCapabilities.singbox114,
  );
  if (!built.ok) {
    stderr.writeln('build failed: ${built.issues.map((i) => i.message).join('; ')}');
    exit(2);
  }
  File(out).writeAsStringSync(built.config!.toJsonString());
  stdout.writeln(out);
}
