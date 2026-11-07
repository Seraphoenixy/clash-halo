import 'dart:convert';

/// Current wire protocol version. Bump on any incompatible change; both the
/// Dart bridge and the Go host reject envelopes whose `v` differs.
const int kProtocolVersion = 1;

/// Base pipe name used by the background host (current user only).
const String kPipeName = r'\\.\pipe\clash-halo-host-v1';

/// Logical name the Flutter side uses to start the host executable.
const String kHostExecutable = 'halo-host.exe';

/// Pipe name for a data directory.
///
/// Mirrors `contract.PipeNameFor` in Go exactly: a single global name would let
/// two installations steal each other's pipe, so the name is derived from the
/// directory. The hash must match the Go FNV-1a implementation byte for byte.
String haloPipeNameFor(String? base) {
  if (base == null || base.isEmpty) return kPipeName;
  final normalized = base
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .join('/')
      .toLowerCase();
  return '$kPipeName-${_fnv64(normalized)}';
}

/// FNV-1a over the UTF-8 bytes, matching Go's `for i := 0; i < len(s); i++`
/// loop byte for byte (a Windows path may contain non-ASCII directory names).
String _fnv64(String input) {
  // The offset basis and prime exceed 2^53, so use BigInt and mask to 64 bits
  // explicitly; a double would silently round and break the pipe name.
  var hash = BigInt.parse('14695981039346656037');
  const prime = 1099511628211;
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final b in utf8.encode(input)) {
    hash ^= BigInt.from(b);
    hash = (hash * BigInt.from(prime)) & mask;
  }
  return hash.toRadixString(16);
}
