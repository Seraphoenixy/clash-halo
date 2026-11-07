/// NDJSON envelope: one JSON object per line on the pipe.
///
/// Discriminator rules (mirrored in the Go host):
///   request  -> has `action`
///   response -> has `id` and `ok`
///   event    -> has `event`
library;

import 'errors.dart';
import 'version.dart';

/// Base class for every wire message.
sealed class HaloMessage {
  const HaloMessage();

  Map<String, Object?> toJson();

  /// Parses one already-decoded map. Throws [HaloProtocolException] when the
  /// envelope is structurally invalid.
  static HaloMessage fromJson(Map<String, Object?> json) {
    final version = (json['v'] as num?)?.toInt();
    if (version == null) {
      throw const HaloProtocolException(
          HaloErrorCode.badRequest, 'missing protocol version');
    }
    if (version != kProtocolVersion) {
      throw HaloProtocolException(
          HaloErrorCode.versionMismatch, 'unsupported protocol version $version');
    }
    if (json.containsKey('action')) return HaloRequest.fromJson(json);
    if (json.containsKey('event')) return HaloEventMessage.fromJson(json);
    if (json.containsKey('ok')) return HaloResponse.fromJson(json);
    throw const HaloProtocolException(
        HaloErrorCode.badRequest, 'envelope is neither request, response nor event');
  }
}

/// Protocol violations are local and must not be confused with host-side
/// business errors.
class HaloProtocolException implements Exception {
  const HaloProtocolException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'HaloProtocolException($code: $message)';
}

class HaloRequest extends HaloMessage {
  const HaloRequest({
    required this.id,
    required this.action,
    this.params = const {},
  });

  final String id;
  final String action;
  final Map<String, Object?> params;

  /// Correlation key for the single in-flight command.
  HaloRequest copyWith({String? id, Map<String, Object?>? params}) =>
      HaloRequest(id: id ?? this.id, action: action, params: params ?? this.params);

  factory HaloRequest.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const HaloProtocolException(HaloErrorCode.badRequest, 'missing request id');
    }
    final action = json['action'];
    if (action is! String || action.isEmpty) {
      throw const HaloProtocolException(HaloErrorCode.badRequest, 'missing action');
    }
    return HaloRequest(
      id: id,
      action: action,
      params: (json['params'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  @override
  Map<String, Object?> toJson() => {
        'v': kProtocolVersion,
        'id': id,
        'action': action,
        if (params.isNotEmpty) 'params': params,
      };
}

class HaloResponse extends HaloMessage {
  const HaloResponse({
    required this.id,
    required this.ok,
    this.result,
    this.error,
    this.stateVersion = 0,
  });

  final String id;
  final bool ok;
  final Map<String, Object?>? result;
  final HaloError? error;

  /// Host state version the response was produced against, so the UI can
  /// discard stale echoes.
  final int stateVersion;

  factory HaloResponse.success(String id,
          {Map<String, Object?>? result, int stateVersion = 0}) =>
      HaloResponse(id: id, ok: true, result: result, stateVersion: stateVersion);

  factory HaloResponse.failure(String id, HaloError error, {int stateVersion = 0}) =>
      HaloResponse(id: id, ok: false, error: error, stateVersion: stateVersion);

  factory HaloResponse.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const HaloProtocolException(HaloErrorCode.badRequest, 'response without id');
    }
    final ok = json['ok'];
    if (ok is! bool) {
      throw const HaloProtocolException(HaloErrorCode.badRequest, 'response without ok flag');
    }
    return HaloResponse(
      id: id,
      ok: ok,
      result: (json['result'] as Map?)?.cast<String, Object?>(),
      error: ok
          ? null
          : HaloError.fromJson((json['error'] as Map?)?.cast<String, Object?>() ?? const {}),
      stateVersion: (json['stateVersion'] as num?)?.toInt() ?? 0,
    );
  }

  /// Throws [HaloError] when the host reported a failure.
  Map<String, Object?> unwrap() {
    if (ok) return result ?? const {};
    throw error ?? const HaloError(HaloErrorCode.internal);
  }

  @override
  Map<String, Object?> toJson() => {
        'v': kProtocolVersion,
        'id': id,
        'ok': ok,
        if (result != null) 'result': result,
        if (error != null) 'error': error!.toJson(),
        'stateVersion': stateVersion,
      };
}

class HaloEventMessage extends HaloMessage {
  const HaloEventMessage({
    required this.name,
    this.seq = 0,
    this.data = const {},
    this.stateVersion = 0,
  });

  final String name;

  /// Monotonic per-host event sequence; a gap after reconnect is expected and
  /// must be resolved by fetching a fresh snapshot.
  final int seq;
  final Map<String, Object?> data;
  final int stateVersion;

  factory HaloEventMessage.fromJson(Map<String, Object?> json) {
    final name = json['event'];
    if (name is! String || name.isEmpty) {
      throw const HaloProtocolException(HaloErrorCode.badRequest, 'event without name');
    }
    return HaloEventMessage(
      name: name,
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      data: (json['data'] as Map?)?.cast<String, Object?>() ?? const {},
      stateVersion: (json['stateVersion'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Map<String, Object?> toJson() => {
        'v': kProtocolVersion,
        'event': name,
        'seq': seq,
        if (data.isNotEmpty) 'data': data,
        'stateVersion': stateVersion,
      };
}
