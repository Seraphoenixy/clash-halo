import 'dart:convert';

import 'envelope.dart';
import 'errors.dart';

/// Text-level codec for the NDJSON pipe framing. Kept separate from the
/// transport so tests can round-trip without a real pipe.
class HaloCodec {
  const HaloCodec();

  /// Serialises a message as exactly one JSON line (no embedded newlines).
  String encode(HaloMessage message) =>
      '${jsonEncode(message.toJson())}\n';

  /// Encodes an opaquely-structured response that already is a JSON map.
  String encodeRaw(Map<String, Object?> json) => '${jsonEncode(json)}\n';

  /// Decodes one line. Blank lines must be skipped by the caller before
  /// calling this; trailing `\r` from CRLF transports is tolerated.
  HaloMessage decode(String line) {
    final trimmed = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    Object? parsed;
    try {
      parsed = jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw HaloProtocolException(HaloErrorCode.badRequest, 'invalid JSON: ${e.message}');
    }
    if (parsed is! Map) {
      throw const HaloProtocolException(
          HaloErrorCode.badRequest, 'envelope must be a JSON object');
    }
    return HaloMessage.fromJson(parsed.cast<String, Object?>());
  }

  /// Splits a possibly multi-line buffer into a remainder plus decoded
  /// messages. Used by both the Dart client and the Go host tests.
  DecodeBatchResult decodeLines(String buffer) {
    final messages = <HaloMessage>[];
    final lines = buffer.split('\n');
    // The last element is either empty (buffer ended with \n) or a partial line.
    final remainder = lines.removeLast();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      messages.add(decode(line));
    }
    return DecodeBatchResult(remainder, messages);
  }
}

class DecodeBatchResult {
  const DecodeBatchResult(this.remainder, this.messages);

  final String remainder;
  final List<HaloMessage> messages;
}
