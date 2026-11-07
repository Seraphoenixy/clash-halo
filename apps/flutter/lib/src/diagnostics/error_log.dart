import 'dart:io';

/// Appends uncaught errors to a file.
///
/// A failure while the first frame is being built leaves almost no evidence: a
/// release build paints an empty box instead of a message, the window is not
/// even mapped until a frame succeeds so the app can look like it never
/// started, and `print` only reaches a console that a double-clicked app does
/// not have. Writing the error next to the host's log is what makes such a
/// failure reportable at all.
///
/// Recording must never become a failure of its own, so every path here
/// swallows its exceptions: diagnostics that throw are worse than no
/// diagnostics.
class ErrorLog {
  ErrorLog(this.preferredDir);

  /// Where the app would normally write, i.e. the data directory. It is only a
  /// preference: a broken data directory is one of the things being diagnosed,
  /// so the temp directory is used when it is unusable.
  final String preferredDir;

  /// The file that was actually opened, or null while nothing has been written.
  String? path;

  File? _file;
  String? _lastMessage;

  Iterable<String> get _candidates => [preferredDir, Directory.systemTemp.path];

  File? _open() {
    if (_file != null) return _file;
    for (final base in _candidates) {
      try {
        final dir = Directory('$base${Platform.pathSeparator}logs');
        dir.createSync(recursive: true);
        final file = File('${dir.path}${Platform.pathSeparator}ui-error.log');
        // Prove it is actually writable now rather than at the first failure.
        file.writeAsStringSync('', mode: FileMode.append, flush: true);
        path = file.path;
        return _file = file;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Records one failure. Consecutive identical messages are collapsed, because
  /// a widget that throws on every rebuild would otherwise fill the disk.
  void record(Object error, StackTrace? stack, {String source = ''}) {
    final message = '$source|$error';
    if (message == _lastMessage) return;
    _lastMessage = message;
    try {
      _open()?.writeAsStringSync(
        '${DateTime.now().toIso8601String()} [$source] $error\n'
        '${stack ?? StackTrace.empty}\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Nothing useful can be done here, and throwing would replace the real
      // error with a reporting error.
    }
  }
}
