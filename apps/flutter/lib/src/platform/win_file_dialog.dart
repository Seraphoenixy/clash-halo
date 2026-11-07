/// Windows 文件选择对话框，直接调用 `comdlg32.dll`。
///
/// 不走 `file_selector` 之类的插件：本项目的 Windows 外壳在缺少 CMake 组件时由
/// `scripts/build-runner.ps1` 用 cl/link 手写编译（见 docs/agents/build.md），
/// 插件要注册进生成的 `generated_plugin_registrant.cc` 并额外链接自己的 DLL，
/// 这条构建路径就断了。同一条约束下，命名管道也是直接用 FFI 调的 kernel32
/// （lib/src/ipc/win_pipe.dart），这里沿用同一种做法。
///
/// 用的是 `GetOpenFileNameW`（Vista 之前就有，至今仍受支持），不是 COM 的
/// `IFileOpenDialog`：后者要通过 FFI 手写 vtable，几十行偏移量一旦写错就是崩溃，
/// 而这里要的只是「选一个 .chb 文件」。
library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';


/// 对话框里「文件类型」下拉的条目。
typedef FileFilter = ({String label, String pattern});

/// 默认过滤项：备份文件优先，其次所有文件。
///
/// 「所有文件」这一项不是凑数：备份是可以被用户改名、或者从别的机器拷来的，
/// 只剩一项时扩展名不符会让人以为文件不存在。
const List<FileFilter> backupFileFilters = [
  (label: 'Clash Halo 备份 (*.chb)', pattern: '*.chb'),
  (label: '所有文件 (*.*)', pattern: '*.*'),
];

String? pickFileForOpen({
  required String title,
  required String initialDirectory,
  List<FileFilter> filters = backupFileFilters,
}) {
  if (!Platform.isWindows) return null;
  return _openFileName(
    title: title,
    initialDirectory: initialDirectory,
    filters: filters,
  );
}

// ---------------------------------------------------------------------------
// 纯函数部分：可测，且这里出错的后果是对话框打不开或返回空字符串
// ---------------------------------------------------------------------------

/// 拼出 `OPENFILENAMEW.lpstrFilter` 需要的那段 UTF-16。
///
/// 格式是「显示名 \0 通配符 \0」成对重复，**最后再加一个 \0 结束**。少最后那一
/// 个，对话框会读到缓冲区之外；用单个 \0 分隔则会全部挤成一项。
Uint16List buildFilterBuffer(List<FileFilter> filters) {
  final buffer = <int>[];
  for (final filter in filters) {
    buffer.addAll('${filter.label}\u0000${filter.pattern}\u0000'.codeUnits);
  }
  buffer.add(0);
  return Uint16List.fromList(buffer);
}

/// `GetOpenFileNameW` 的 flags。
///
/// `ofnNoChangeDir` 是必需的，不是保守：内核日志按**当前工作目录**写盘
/// （packages/config 生成的 `log.output` 是相对路径，宿主用数据目录作为工作
/// 目录），文件对话框默认会把进程的当前目录改成用户最后进入的目录。少了这一位，
/// 选完备份文件之后内核日志就开始写到别处。
class OpenFileFlags {
  static const noChangeDir = 0x00000008;
  static const hideReadOnly = 0x00000004;
  static const pathMustExist = 0x00000800;
  static const fileMustExist = 0x00001000;
  static const explorer = 0x00080000;

  static const value =
      noChangeDir | hideReadOnly | pathMustExist | fileMustExist | explorer;
}

/// 从对话框写回的缓冲区里取出路径。
///
/// 未选择时每个字节都是 0；成功时是整条路径加结尾的 \0，且后面可能还留着上一次
/// 的长度残影，所以必须按第一个 \0 截断，不能整个缓冲区转成字符串。
String? readPathFromBuffer(Uint16List buffer) {
  final end = buffer.indexOf(0);
  if (end <= 0) return null;
  final text = String.fromCharCodes(buffer.sublist(0, end));
  return text.isEmpty ? null : text;
}

// ---------------------------------------------------------------------------
// 原生调用
// ---------------------------------------------------------------------------

final class _OpenFileNameW extends Struct {
  @Uint32()
  external int structSize;
  @IntPtr()
  external int hwndOwner;
  @IntPtr()
  external int hInstance;
  @IntPtr()
  external int filter;
  @IntPtr()
  external int customFilter;
  @Uint32()
  external int maxCustomFilter;
  @Uint32()
  external int filterIndex;
  @IntPtr()
  external int file;
  @Uint32()
  external int maxFile;
  @IntPtr()
  external int fileTitle;
  @Uint32()
  external int maxFileTitle;
  @IntPtr()
  external int initialDir;
  @IntPtr()
  external int title;
  @Uint32()
  external int flags;
  @Uint16()
  external int fileOffset;
  @Uint16()
  external int fileExtension;
  @IntPtr()
  external int defaultExt;
  @IntPtr()
  external int customData;
  @IntPtr()
  external int hook;
  @IntPtr()
  external int templateName;
  @IntPtr()
  external int reserved;
  @Uint32()
  external int reserved2;
  @Uint32()
  external int flagsEx;
}

/// 路径缓冲区长度。Windows 的 MAX_PATH 是 260，长路径可达 32767；取 4096 足够
/// 覆盖实际使用，又不至于为一次对话框占用太多内存。
const int _pathBufferChars = 4096;

String? _openFileName({
  required String title,
  required String initialDirectory,
  required List<FileFilter> filters,
}) {
  final comdlg32 = DynamicLibrary.open('comdlg32.dll');
  final getOpenFileName = comdlg32.lookupFunction<
    Int32 Function(Pointer<_OpenFileNameW>),
    int Function(Pointer<_OpenFileNameW>)
  >('GetOpenFileNameW');
  final extendedError = comdlg32
      .lookupFunction<Uint32 Function(), int Function()>(
        'CommDlgExtendedError',
      );
  final user32 = DynamicLibrary.open('user32.dll');
  final findWindow = user32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
    int Function(Pointer<Utf16>, Pointer<Utf16>)
  >('FindWindowW');

  final filter = buildFilterBuffer(filters);
  final filterPtr = calloc<Uint16>(filter.length);
  final filePtr = calloc<Uint16>(_pathBufferChars);
  final struct = calloc<_OpenFileNameW>();
  final titlePtr = title.toNativeUtf16();
  final initialDirPtr = initialDirectory.toNativeUtf16();
  final classNamePtr = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();

  try {
    filterPtr.asTypedList(filter.length).setAll(0, filter);
    struct.ref
      ..structSize = sizeOf<_OpenFileNameW>()
      // 以 Flutter 的窗口作为 owner，对话框才是模态的；owner 为 0 时它会跑到
      // 应用窗口后面，看起来像按钮没反应。
      ..hwndOwner = findWindow(classNamePtr, nullptr)
      ..filter = filterPtr.address
      ..filterIndex = 1
      ..file = filePtr.address
      ..maxFile = _pathBufferChars
      ..initialDir = initialDirPtr.address
      ..title = titlePtr.address
      ..flags = OpenFileFlags.value
      ..defaultExt = 0;

    final ok = getOpenFileName(struct);
    if (ok == 0) {
      // 0 且扩错误码为 0 表示用户取消，这是正常结果，不是失败。
      final code = extendedError();
      if (code != 0) {
        throw WindowsFileDialogException('文件对话框打开失败（错误 $code）', code);
      }
      return null;
    }
    return readPathFromBuffer(filePtr.asTypedList(_pathBufferChars));
  } finally {
    calloc.free(struct);
    calloc.free(filterPtr);
    calloc.free(filePtr);
    calloc.free(titlePtr);
    calloc.free(initialDirPtr);
    calloc.free(classNamePtr);
  }
}

class WindowsFileDialogException implements Exception {
  WindowsFileDialogException(this.message, this.code);

  final String message;
  final int code;

  @override
  String toString() => message;
}
