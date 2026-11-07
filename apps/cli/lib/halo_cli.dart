/// clash-halo command line entry point.
///
/// Exit codes are part of the interface (scripts depend on them):
///   0 success, 1 the command ran but failed (e.g. a download), 2 bad usage.
library;

export 'src/cli.dart'
    show Cli, LineSink, UsageException, cliVersion, isClosedPipeError;
export 'src/paths.dart' show resolveDataDir, resolveDbPath;