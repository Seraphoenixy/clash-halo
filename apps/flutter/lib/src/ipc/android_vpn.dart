import 'package:flutter/services.dart';

/// `:vpn` 进程的运行状态，由服务写入 `vpn-state.json` 后经平台通道读出。
///
/// `updatedAt` 是服务写入状态的时刻（毫秒）。启动请求返回请求时刻，
/// [AndroidVpnClient.startAndWait] 用它忽略上一次运行留下的旧状态。
class AndroidVpnStatus {
  const AndroidVpnStatus({
    required this.state,
    required this.message,
    required this.updatedAt,
  });

  final String state;
  final String message;
  final int updatedAt;

  bool get isStopped => state == 'Stopped';
  bool get isStarting => state == 'Starting';
  bool get isStarted => state == 'Started';
  bool get isFailed => state == 'Failed';
  bool get isActive => isStarting || isStarted;

  factory AndroidVpnStatus.fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) {
      return const AndroidVpnStatus(
        state: 'Stopped',
        message: '服务未运行',
        updatedAt: 0,
      );
    }
    return AndroidVpnStatus(
      state: raw['state'] as String? ?? 'Stopped',
      message: raw['message'] as String? ?? '',
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() => 'AndroidVpnStatus($state: $message)';
}

class AndroidVpnException implements Exception {
  const AndroidVpnException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A backup written through Android's document picker.
class AndroidBackupSaved {
  const AndroidBackupSaved({required this.name, required this.uri});

  final String name;
  final String uri;

  factory AndroidBackupSaved.fromMap(Map<Object?, Object?> raw) =>
      AndroidBackupSaved(
        name: raw['name'] as String? ?? '',
        uri: raw['uri'] as String? ?? '',
      );
}

/// A backup selected and read through Android's document picker.
class AndroidBackupPicked {
  const AndroidBackupPicked({required this.name, required this.text});

  final String name;
  final String text;

  factory AndroidBackupPicked.fromMap(Map<Object?, Object?> raw) =>
      AndroidBackupPicked(
        name: raw['name'] as String? ?? '',
        text: raw['text'] as String? ?? '',
      );
}

/// Android 侧 VPN 服务的平台通道客户端。
///
/// 与 Windows 的命名管道宿主不同：Android 没有 halo-host，代理内核
/// （libbox）运行在 `:vpn` 进程的 HaloVpnService 里，由本通道驱动。
/// 配置经固定路径共享（见 native/android/README.md），通道只传配置内容，
/// 不传路径。服务状态由同一应用目录下的状态文件提供。
class AndroidVpnClient {
  const AndroidVpnClient();

  static const MethodChannel _channel = MethodChannel('clash_halo/android_vpn');

  /// 应用数据目录（持久，非缓存）。Android 上 [resolveDataDir] 的
  /// `Directory.systemTemp` 回退会落进 code_cache——系统重装即清空，
  /// 数据库必须放在这里返回的目录。
  Future<String> dataDir() async =>
      await _channel.invokeMethod<String>('dataDir') ?? '';

  /// Writes a backup through `ACTION_CREATE_DOCUMENT`.
  ///
  /// The platform owns the destination URI; null means the picker was
  /// cancelled, which is not an error.
  Future<AndroidBackupSaved?> exportBackup({
    required String fileName,
    required String content,
  }) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'exportBackup',
      {'fileName': fileName, 'content': content},
    );
    if (raw == null) return null;
    return AndroidBackupSaved.fromMap(raw);
  }

  /// Reads a backup through `ACTION_OPEN_DOCUMENT`.
  ///
  /// Null means the picker was cancelled.
  Future<AndroidBackupPicked?> importBackup() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'importBackup',
    );
    if (raw == null) return null;
    return AndroidBackupPicked.fromMap(raw);
  }

  /// 系统是否已授予本应用 VPN 权限（不弹窗）。
  Future<bool> permissionGranted() async =>
      await _channel.invokeMethod<bool>('permissionGranted') ?? false;

  /// 请求 VPN 权限；首次调用会弹系统授权对话框。
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  /// 读取 `:vpn` 进程内的服务状态。
  Future<AndroidVpnStatus> status() async {
    final raw = await _channel.invokeMethod<Object?>('status');
    if (raw is Map) {
      return AndroidVpnStatus.fromMap(Map<Object?, Object?>.from(raw));
    }
    return AndroidVpnStatus.fromMap(null);
  }

  /// 写入配置并启动 `:vpn` 服务（含 TUN 建立）；返回请求时刻。
  ///
  /// 通道返回时服务尚未完成启动；需要结果时用 [startAndWait]。
  Future<int> start(String configJson) async {
    final value = await _channel.invokeMethod<int>('start', {
      'config': configJson,
    });
    return value ?? DateTime.now().millisecondsSinceEpoch;
  }

  Future<int> stop() async {
    final value = await _channel.invokeMethod<int>('stop');
    return value ?? DateTime.now().millisecondsSinceEpoch;
  }

  /// 启动并等待服务进入 Started 或 Failed。
  ///
  /// 只看 `updatedAt` 不早于本次请求的状态，避免把上一次运行留下的
  /// Started/Stopped 当成这一次的结果。失败时抛出带服务消息的异常；
  /// 30 秒仍未进入终态则超时。
  Future<AndroidVpnStatus> startAndWait(
    String configJson, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestedAt = await start(configJson);
    final startedClock = DateTime.now();
    final deadline = DateTime.now().add(timeout);
    AndroidVpnStatus? last;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final status = await this.status();
      last = status;
      if (status.updatedAt < requestedAt) continue;
      if (status.isFailed) {
        throw AndroidVpnException(
          status.message.isEmpty ? 'VPN 启动失败' : status.message,
        );
      }
      if (status.isStarted) return status;
      if (status.isStopped) {
        // ActivityManager may not list the freshly started :vpn process for
        // a moment; a Stopped reading inside this window is not a failure.
        if (DateTime.now().difference(startedClock) <
            const Duration(seconds: 2)) {
          continue;
        }
        throw AndroidVpnException(
          status.message.isEmpty ? 'VPN 服务未启动' : status.message,
        );
      }
    }
    throw AndroidVpnException('等待 VPN 启动超时（${last?.message ?? '无状态'}）');
  }

  /// 停止并等待服务离开 Starting/Started。
  Future<AndroidVpnStatus> stopAndWait({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await stop();
    final deadline = DateTime.now().add(timeout);
    AndroidVpnStatus? last;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final status = await this.status();
      last = status;
      if (!status.isActive) return status;
    }
    throw AndroidVpnException('等待 VPN 停止超时（${last?.message ?? '无状态'}）');
  }
}
