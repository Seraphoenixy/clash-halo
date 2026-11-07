import 'dart:async';
import 'dart:io';

import 'package:halo_cli/halo_cli.dart';

Future<void> main(List<String> args) async {
  final completion = Completer<int>();
  // stdout write failures are reported through the zone, not thrown by
  // `writeln`, so `| head` can only be handled here. See isClosedPipeError.
  runZonedGuarded(
    () async {
      final code = await Cli(args).run();
      try {
        // Flushing explicitly keeps piped output intact when the process exits
        // right after the last line.
        await stdout.flush();
        await stderr.flush();
      } on FileSystemException catch (error) {
        if (!isClosedPipeError(error)) rethrow;
      }
      if (!completion.isCompleted) completion.complete(code);
    },
    (error, stack) {
      if (isClosedPipeError(error)) {
        // The reader stopped; the truncation is what it asked for. Finish with
        // success instead of writing the remaining lines into a dead pipe.
        if (!completion.isCompleted) completion.complete(0);
        return;
      }
      if (completion.isCompleted) return;
      try {
        stderr.writeln('未处理的错误：$error');
      } on Object {
        // A dead stderr must not turn one error into a second exception.
      }
      completion.complete(1);
    },
  );
  exit(await completion.future);
}