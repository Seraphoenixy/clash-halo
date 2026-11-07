/// Wire contract for the clash-halo Windows host <-> Flutter bridge.
///
/// The transport is one JSON object per line (NDJSON) over a restricted
/// Windows named pipe. Every line is either a request, a response or an event.
library;

export 'src/actions.dart';
export 'src/codec.dart';
export 'src/connections.dart';
export 'src/envelope.dart';
export 'src/errors.dart';
export 'src/speed.dart';
export 'src/state.dart';
export 'src/version.dart';
