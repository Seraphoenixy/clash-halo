/// Structured error codes shared by the host and the UI. The UI switches on
/// these codes, never on message text.
class HaloErrorCode {
  static const unknownAction = 'unknown_action';
  static const badRequest = 'bad_request';
  static const versionMismatch = 'version_mismatch';
  static const unauthorized = 'unauthorized';
  static const forbidden = 'forbidden';
  static const notFound = 'not_found';
  static const conflict = 'conflict';
  static const coreNotRunning = 'core_not_running';
  static const coreFailed = 'core_failed';
  static const configInvalid = 'config_invalid';
  static const configApplyFailed = 'config_apply_failed';
  static const unsupportedCapability = 'unsupported_capability';
  static const tunUnavailable = 'tun_unavailable';
  /// The host can perform the privileged action but has no verified helper yet,
  /// which is different from the user refusing the prompt.
  static const elevationRequired = 'elevation_required';
  static const elevationDenied = 'elevation_denied';
  static const systemProxyFailed = 'system_proxy_failed';
  static const taskNotFound = 'task_not_found';
  static const taskCanceled = 'task_canceled';
  static const alreadyRunning = 'already_running';
  static const busy = 'busy';
  static const internal = 'internal';

  static const _descriptions = <String, String>{
    unknownAction: '未知请求动作',
    badRequest: '请求格式错误',
    versionMismatch: '协议版本不一致',
    unauthorized: '连接未被授权',
    forbidden: '操作被拒绝',
    notFound: '对象不存在',
    conflict: '存在冲突的并发状态',
    coreNotRunning: '内核未运行',
    coreFailed: '内核异常退出',
    configInvalid: '配置校验未通过',
    configApplyFailed: '配置应用失败',
    unsupportedCapability: '当前平台或内核不支持该能力',
    tunUnavailable: 'TUN 模式当前不可用',
    elevationRequired: '该操作需要管理员授权以创建 TUN 适配器',
    elevationDenied: '提权被拒绝（未授予管理员权限）',
    systemProxyFailed: '系统代理设置失败',
    taskNotFound: '任务不存在',
    taskCanceled: '任务已取消',
    alreadyRunning: '目标已在运行',
    busy: '后台正在执行其他命令',
    internal: '内部错误',
  };

  /// Human-readable, non-sensitive text. Never contains credentials.
  static const descriptions = _descriptions;

  /// Localised text for [code], falling back to the code itself so that
  /// unexpected future codes stay displayable.
  static String describe(String code) => _descriptions[code] ?? code;
}

/// Error payload carried by a failed response.
class HaloError implements Exception {
  const HaloError(this.code, [this.message, this.detail]);

  final String code;
  final String? message;

  /// Human-readable extra context from the host (for example the first lines
  /// of a core stderr dump). It is a plain string on the wire: the Go host
  /// sends `detail` as text so a client never has to interpret a free-form
  /// structure just to show why a command failed.
  final String? detail;

  /// Localised text: explicit [message] wins, otherwise the code description.
  String get displayMessage => message ?? HaloErrorCode.describe(code);

  factory HaloError.fromJson(Map<String, Object?> json) => HaloError(
        json['code'] as String? ?? HaloErrorCode.internal,
        json['message'] as String?,
        json['detail'] as String?,
      );

  Map<String, Object?> toJson() => {
        'code': code,
        if (message != null) 'message': message,
        if (detail != null) 'detail': detail,
      };

  @override
  String toString() => 'HaloError($code: $displayMessage)';
}
