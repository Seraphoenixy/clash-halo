import 'dart:io';

import 'package:halo_contracts/halo_contracts.dart';
import 'package:test/test.dart';

/// The UI switches on error codes and the host emits them, so the two sides
/// must agree on every string. This test reads the Go constant block and
/// compares it with [HaloErrorCode], turning a silent "UI shows the raw code"
/// regression into a failure.
void main() {
  test('every Go error code exists in HaloErrorCode', () {
    // `dart test` may run from the package directory or the repository root.
    final candidates = <String>[
      '../../native/windows/internal/contract/contract.go',
      'native/windows/internal/contract/contract.go',
    ];
    final file = candidates.map(File.new).where((f) => f.existsSync()).firstOrNull;
    if (file == null) {
      fail('找不到 Go 契约文件，无法核对错误码');
    }
    final source = file.readAsStringSync();

    // Err<Name> = "<code>" — the declaration form the Go file uses.
    final matches =
        RegExp(r'Err\w+\s*=\s*"([a-z_]+)"').allMatches(source).toList();
    expect(matches, isNotEmpty, reason: '没有解析到任何 Go 错误码');

    final goCodes = matches.map((m) => m.group(1)!).toSet();
    // `tun_unavailable`, `elevation_required` and friends must all be present;
    // a code the host can emit but the UI cannot name becomes an opaque string.
    for (final code in goCodes) {
      expect(HaloErrorCode.descriptions.containsKey(code), isTrue,
          reason: 'Go 会返回 "$code"，但 Dart 没有对应常量/描述');
    }
  });

  test('elevation_required is distinct from elevation_denied', () {
    // These mean different things to the user: "an administrator token is
    // needed for this action" versus "you declined the prompt". Collapsing them
    // would misreport a missing permission as a user decision.
    expect(HaloErrorCode.elevationRequired,
        isNot(HaloErrorCode.elevationDenied));
    expect(HaloErrorCode.describe(HaloErrorCode.elevationRequired),
        contains('管理员'));
    expect(HaloErrorCode.describe(HaloErrorCode.elevationDenied),
        contains('拒绝'));
    // TUN is implemented and verified, so the text must no longer describe the
    // capability itself as unverified — that was true of an earlier build and
    // would now mislead the user into thinking the feature does not exist.
    expect(HaloErrorCode.describe(HaloErrorCode.elevationRequired),
        isNot(contains('未验证')));
    expect(HaloErrorCode.describe(HaloErrorCode.tunUnavailable),
        isNot(contains('未验证')));
  });

  test('descriptions cover every declared code', () {
    for (final code in <String>[
      HaloErrorCode.unknownAction,
      HaloErrorCode.badRequest,
      HaloErrorCode.versionMismatch,
      HaloErrorCode.unauthorized,
      HaloErrorCode.forbidden,
      HaloErrorCode.notFound,
      HaloErrorCode.conflict,
      HaloErrorCode.coreNotRunning,
      HaloErrorCode.coreFailed,
      HaloErrorCode.configInvalid,
      HaloErrorCode.configApplyFailed,
      HaloErrorCode.unsupportedCapability,
      HaloErrorCode.tunUnavailable,
      HaloErrorCode.elevationRequired,
      HaloErrorCode.elevationDenied,
      HaloErrorCode.systemProxyFailed,
      HaloErrorCode.taskNotFound,
      HaloErrorCode.taskCanceled,
      HaloErrorCode.alreadyRunning,
      HaloErrorCode.busy,
      HaloErrorCode.internal,
    ]) {
      expect(HaloErrorCode.descriptions, contains(code));
    }
  });
}
