import 'package:flutter/material.dart';

/// Replacement for Flutter's default build-error widget.
///
/// A release build paints an empty grey box here and says nothing, so a failed
/// first build is indistinguishable from a window that never rendered: the user
/// sees a grey rectangle with no text, and the window is not even mapped until
/// the first frame, so it can look like the app simply did not start.
///
/// Showing the reason costs nothing and turns an unexplainable blank window into
/// a reportable error, so this is installed as [ErrorWidget.builder] before
/// `runApp`.
Widget haloErrorWidget(FlutterErrorDetails details, {String? logPath}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ClipRect(
      child: ColoredBox(
        color: const Color(0xFF241F27),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '界面渲染失败',
                style: TextStyle(
                  color: Color(0xFFFFB4A9),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                details.exceptionAsString(),
                style: const TextStyle(
                  color: Color(0xFFF2E7E4),
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                logPath == null
                    ? '来源: ${details.library ?? '未知'}。请把这段文字反馈。'
                    : '来源: ${details.library ?? '未知'}。完整堆栈已写入 $logPath',
                style: const TextStyle(
                  color: Color(0xFFB9AEB6),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
