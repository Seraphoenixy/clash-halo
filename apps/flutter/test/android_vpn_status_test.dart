import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halo/src/ipc/android_vpn.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('clash_halo/android_vpn');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('parses the state document', () {
    final status = AndroidVpnStatus.fromMap({
      'state': 'Started',
      'message': '已连接',
      'updatedAt': 1234,
    });
    expect(status.isStarted, isTrue);
    expect(status.isActive, isTrue);
    expect(status.message, '已连接');
    expect(status.updatedAt, 1234);
  });

  test('a missing document means stopped', () {
    final status = AndroidVpnStatus.fromMap(null);
    expect(status.isStopped, isTrue);
    expect(status.isActive, isFalse);
  });

  test('exportBackup passes the suggested name and parses the saved URI', () async {
    MethodCall? call;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (incoming) async {
          call = incoming;
          return {
            'name': 'halo-backup-1.chb',
            'uri': 'content://downloads/1',
          };
        });

    final saved = await const AndroidVpnClient().exportBackup(
      fileName: 'halo-backup-1.chb',
      content: 'backup-body',
    );
    expect(call?.method, 'exportBackup');
    expect(call?.arguments, {
      'fileName': 'halo-backup-1.chb',
      'content': 'backup-body',
    });
    expect(saved?.name, 'halo-backup-1.chb');
    expect(saved?.uri, 'content://downloads/1');
  });

  test('importBackup returns the selected document text', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (incoming) async {
          expect(incoming.method, 'importBackup');
          return {'name': 'restore.chb', 'text': 'backup-body'};
        });

    final picked = await const AndroidVpnClient().importBackup();
    expect(picked?.name, 'restore.chb');
    expect(picked?.text, 'backup-body');
  });

  test('a cancelled document picker returns null, not an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (incoming) async => null);

    expect(
      await const AndroidVpnClient().exportBackup(
        fileName: 'x.chb',
        content: 'x',
      ),
      isNull,
    );
    expect(await const AndroidVpnClient().importBackup(), isNull);
  });

  test('startAndWait ignores the previous run and returns Started', () async {
    var statusCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'start':
              return 1000;
            case 'status':
              statusCalls++;
              if (statusCalls == 1) {
                // Old run, still on disk: older than the start request.
                return {
                  'state': 'Started',
                  'message': '旧的连接',
                  'updatedAt': 900,
                };
              }
              if (statusCalls == 2) {
                return {
                  'state': 'Starting',
                  'message': '正在启动…',
                  'updatedAt': 1001,
                };
              }
              return {'state': 'Started', 'message': '已连接', 'updatedAt': 1002};
            default:
              return null;
          }
        });

    final status = await const AndroidVpnClient().startAndWait('{}');
    expect(status.isStarted, isTrue);
    expect(status.message, '已连接');
    expect(statusCalls, greaterThanOrEqualTo(3));
  });

  test('startAndWait surfaces the service failure message', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'start':
              return 2000;
            case 'status':
              return {
                'state': 'Failed',
                'message': '配置不存在：请先在应用内选择节点并启动',
                'updatedAt': 2001,
              };
            default:
              return null;
          }
        });

    await expectLater(
      const AndroidVpnClient().startAndWait('{}'),
      throwsA(
        isA<AndroidVpnException>().having(
          (error) => error.message,
          'message',
          contains('配置不存在'),
        ),
      ),
    );
  });

  test('stopAndWait returns once the service is no longer active', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'stop':
              return 3000;
            case 'status':
              return {'state': 'Stopped', 'message': '已停止', 'updatedAt': 3001};
            default:
              return null;
          }
        });

    final status = await const AndroidVpnClient().stopAndWait();
    expect(status.isStopped, isTrue);
  });
}
