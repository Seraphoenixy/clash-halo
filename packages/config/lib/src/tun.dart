/// TUN inbound generation for the pinned sing-box core.
///
/// The host (Go) injects its own copy of this inbound into the runtime config,
/// so the emitted shape is a contract between two languages rather than a
/// private detail of this package. `tests/fixtures/singbox/tun_inbound.json`
/// pins that contract: [buildTunInbound] with all defaults must keep producing
/// exactly the fixture object.
///
/// Only the modern address form is emitted. The legacy `inet4_address` /
/// `inet6_address` fields were deprecated in sing-box 1.10.0 and removed in
/// 1.12.0 — the pinned 1.14.4 binary rejects them with
/// "legacy tun address fields ... removed", while the `address` list is
/// accepted by `sing-box check`.
library;

/// Tag of the generated TUN inbound, shared with the host's copy.
const String kTunInboundTag = 'tun-in';

/// Builds one `tun` inbound object.
///
/// Keys are emitted unconditionally rather than only when they differ from a
/// default: the host mirrors this function and the shared fixture is compared
/// byte for byte, so an "omit when default" rule would make the contract
/// depend on both sides agreeing about which values count as defaults, and
/// would silently change the document whenever a default is retuned. The one
/// exception is [mtu]: it is omitted when zero, mirroring the host's
/// `Options.MTU` (`json:"mtu,omitempty"`, where 0 means "let the core choose"),
/// so both languages render the same document for the same settings.
///
/// Key order matters too: [applyTunInbound] callers compare serialised output,
/// so the order here is the order of the fixture and of the host's struct.
///
/// [adapterName] becomes `interface_name`, [address] and [address6] become the
/// `address` list, and [stack] must be one of `system`, `gvisor`, `mixed` —
/// the pinned build carries the `with_gvisor` tag, so `mixed` is the default:
/// it uses the Windows TCP stack for TCP and gvisor only for UDP, which is
/// faster than putting every stream through a userspace stack.
Map<String, Object?> buildTunInbound({
  String adapterName = 'clash-halo',
  String address = '172.19.0.1/30',
  String address6 = 'fdfe:dcba:9876::1/126',
  String stack = 'mixed',
  int mtu = 9000,
  bool autoRoute = true,
  bool strictRoute = true,
}) => {
  'type': 'tun',
  'tag': kTunInboundTag,
  'interface_name': adapterName,
  'address': [address, if (address6.isNotEmpty) address6],
  if (mtu != 0) 'mtu': mtu,
  'auto_route': autoRoute,
  'strict_route': strictRoute,
  'stack': stack,
};

/// Returns a copy of [config] with exactly one `tun` inbound.
///
/// An existing `tun` inbound is replaced in place — its position is kept and
/// every duplicate is dropped — so the result never carries two TUN inbounds.
/// When none exists the generated inbound is appended.
///
/// `route.auto_detect_interface` is forced to `true` (creating `route` when it
/// is missing) so that on Windows the core detects the physical interface and
/// does not route its own outbound traffic back into the tunnel.
///
/// The input map is not mutated, and neither are any of its nested lists/maps:
/// the result is an independent deep copy that callers may edit freely.
Map<String, Object?> applyTunInbound(
  Map<String, Object?> config, {
  String adapterName = 'clash-halo',
  String address = '172.19.0.1/30',
  String address6 = 'fdfe:dcba:9876::1/126',
  String stack = 'mixed',
  int mtu = 9000,
  bool autoRoute = true,
  bool strictRoute = true,
}) {
  final result = <String, Object?>{
    for (final entry in config.entries) entry.key: _copyJson(entry.value),
  };

  final inbounds = <Object?>[
    if (result['inbounds'] is List) ...result['inbounds'] as List,
  ];
  final firstTun = inbounds.indexWhere(_isTunInbound);
  inbounds.removeWhere(_isTunInbound);
  final tun = buildTunInbound(
    adapterName: adapterName,
    address: address,
    address6: address6,
    stack: stack,
    mtu: mtu,
    autoRoute: autoRoute,
    strictRoute: strictRoute,
  );
  if (firstTun < 0) {
    inbounds.add(tun);
  } else {
    // Removing the tun entries can only shorten the list, so the original
    // index is still a valid insertion point (at worst equal to the length).
    inbounds.insert(firstTun, tun);
  }
  result['inbounds'] = inbounds;

  final route = <String, Object?>{
    if (result['route'] is Map)
      ...(result['route'] as Map).cast<String, Object?>(),
  };
  route['auto_detect_interface'] = true;
  result['route'] = route;
  return result;
}

/// Whether [config] already contains a `tun` inbound.
///
/// The Dart-side counterpart of the host's `tunconfig.HasTunInbound`. Callers
/// that only need "is TUN already in this document" use this instead of
/// running [applyTunInbound] and diffing the result.
bool hasTunInbound(Map<String, Object?> config) {
  final inbounds = config['inbounds'];
  return inbounds is List && inbounds.any(_isTunInbound);
}

bool _isTunInbound(Object? value) => value is Map && value['type'] == 'tun';

/// Deep-copies a JSON-shaped value so the result never aliases the input.
Object? _copyJson(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) '${entry.key}': _copyJson(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _copyJson(item)];
  return value;
}
