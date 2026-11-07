@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:halo/src/ipc/halo_client.dart';
import 'package:halo_config/halo_config.dart';
import 'package:halo_contracts/halo_contracts.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// End-to-end functional test of the V2Ray import path.
///
/// It does not mock anything: a real `vmess://` link is parsed by the real
/// importer, the real generator turns that node into a sing-box document, the
/// real `halo-host.exe` validates and runs it, and a real HTTP request is read
/// back through the resulting tunnel.
///
/// The design point is how the traffic is *proved* to have gone through VMess.
/// The client asks for `http://203.0.113.9:8080/`, an address in TEST-NET-3 that
/// is never routable, while the local VMess server rewrites every destination to
/// the loopback origin. So:
///
///   * direct/unproxied traffic cannot succeed — the address does not exist;
///   * only the server-side rewrite can reach the origin;
///   * therefore a 200 with the origin's token proves the request went
///     client → mixed inbound → vmess outbound → vmess inbound → origin.
///
/// This replaces a remote V2Ray server with a local one speaking the same
/// protocol, so the test needs no credentials and no network beyond loopback.
void main() {
  final hostExe = Platform.environment['HALO_HOST_EXE'];
  final coreExe = Platform.environment['HALO_CORE_EXE'];

  group('v2ray import → real traffic', () {
    late Directory temp;
    late Process host;
    late Process vmessServer;
    late HaloClient client;
    late HttpServer origin;
    final serverLog = StringBuffer();

    setUp(() async {
      // Workspace-local, because the host runs as a sandboxed child process and
      // cannot create its lock file in %TEMP%.
      final root = Directory('${Directory.current.path}/.tmp')
        ..createSync(recursive: true);
      temp = root.createTempSync('halo-v2ray-');
    });

    tearDown(() async {
      await origin.close(force: true).catchError((Object _) {});
      await client.dispose();
      await _killChildrenOf(host.pid);
      host.kill();
      await host.exitCode;
      vmessServer.kill();
      await vmessServer.exitCode;
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('导入 vmess 分享链接后,真实流量确实经过该节点', () async {
      const uuid = '6f1b8a3e-2c4d-4e5f-8a9b-0c1d2e3f4a5b';
      const token = 'HALO-VMESS-OK';
      final mixedPort = await _freePort();
      final vmessPort = await _freePort();

      // ---- 1. Origin: the only server that can answer the probe -----------
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.text
          ..write('$token ${request.uri.path}');
        request.response.close();
      });

      // ---- 2. A local VMess server, i.e. the peer the link points at ------
      final serverConfig = File('${temp.path}/vmess-server.json');
      serverConfig.writeAsStringSync(
        jsonEncode({
          'log': {'level': 'info'},
          'inbounds': [
            {
              'type': 'vmess',
              'tag': 'vmess-in',
              'listen': '127.0.0.1',
              'listen_port': vmessPort,
              'users': [
                {'uuid': uuid},
              ],
            },
          ],
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
          ],
          // sing-box 1.13 removed destination override on the direct outbound;
          // it is a route action now. Only this side rewrites the destination.
          'route': {
            'rules': [
              {
                'action': 'route',
                'outbound': 'direct',
                'override_address': '127.0.0.1',
                'override_port': origin.port,
              },
            ],
          },
        }),
      );
      // Validate before running: a schema error here would otherwise look like a
      // failing import.
      final check = await Process.run(coreExe!, [
        'check',
        '-c',
        serverConfig.path,
        '--disable-color',
      ]);
      expect(check.exitCode, 0, reason: '本地 vmess 服务端配置不合法: ${check.stderr}');

      vmessServer = await Process.start(coreExe, [
        'run',
        '-c',
        serverConfig.path,
        '--disable-color',
      ]);
      vmessServer.stdout.transform(utf8.decoder).listen(serverLog.write);
      vmessServer.stderr.transform(utf8.decoder).listen(serverLog.write);
      await _waitPort(vmessPort);

      // ---- 3. Import a real `vmess://` link (v2rayN base64-JSON form) -----
      final link =
          'vmess://${base64.encode(utf8.encode(jsonEncode({
                'v': '2',
                'ps': 'local-vmess',
                'add': '127.0.0.1',
                'port': '$vmessPort',
                'id': uuid,
                'aid': '0',
                'net': 'tcp',
                'type': 'none',
                'host': '',
                'path': '',
                'tls': '',
              })))}';

      final imported = importNodes(link);
      expect(imported.failed, isEmpty, reason: '分享链接不应被拒绝');
      expect(imported.nodes, hasLength(1));
      final node = imported.nodes.single;
      expect(node.name, 'local-vmess');
      expect(node.protocol, ProxyProtocol.vmess);
      expect(node.server, '127.0.0.1');
      expect(node.port, vmessPort);
      expect(node.secrets.uuid, uuid);

      // ---- 4. Generate the document the app would send -------------------
      final built = buildConfig(
        ConfigRequest(
          node: node,
          mode: RouteMode.global,
          ports: InboundPorts(mixed: mixedPort, enableClashApi: false),
        ),
        const CoreCapabilities(version: '1.14.4'),
      );
      expect(built.ok, isTrue, reason: '生成失败: ${built.issues}');
      final config = jsonEncode(built.config!.document);

      // ---- 5. Real host over the real named pipe ------------------------
      final core = '${temp.path}\\sing-box.exe';
      File(coreExe).copySync(core);
      host = await Process.start(hostExe!, [
        '--no-tray',
        '--dir',
        temp.path,
      ], environment: {'HALO_SINGBOX': core});
      final hostLog = StringBuffer();
      host.stdout.transform(utf8.decoder).listen(hostLog.write);
      host.stderr.transform(utf8.decoder).listen(hostLog.write);

      client = HaloClient(
        pipeName: haloPipeNameFor(temp.path),
        pollInterval: const Duration(milliseconds: 10),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        try {
          await client.connect();
          break;
        } catch (_) {
          if (DateTime.now().isAfter(deadline)) {
            fail('后台进程未在 20 秒内创建管道\n$hostLog');
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }

      // ---- 6. Apply it; the host starts the core -------------------------
      final applied = await client.send(
        HaloAction.configApply,
        params: {
          'config': config,
          'mode': 'global',
          'nodeId': node.id,
          'nodeName': node.name,
          'startCore': true,
        },
        timeout: const Duration(seconds: 60),
      );
      final afterApply = await _snapshot(client);
      expect(
        applied.ok,
        isTrue,
        reason: '${applied.error?.message}\n'
            'detail: ${applied.error?.detail}\n'
            'core: ${afterApply.lastErrorMessage}\n'
            'host: $hostLog',
      );

      final running = await _waitCoreRunning(client);
      expect(running.coreState, CoreState.running);
      expect(running.activeNodeName, 'local-vmess');

      // ---- 7. Send real traffic through the tunnel ----------------------
      final http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
      String body;
      try {
        final request = await http.getUrl(
          Uri.parse('http://203.0.113.9:8080/probe'),
        );
        final response = await request.close();
        body = await response.transform(utf8.decoder).join();
        expect(response.statusCode, 200);
      } finally {
        http.close(force: true);
      }
      expect(body, startsWith(token));

      // The token proves reachability; this proves the *protocol* was spoken,
      // because the server only logs an inbound connection after a successful
      // VMess handshake.
      final sawInbound = await _waitFor(
        () => serverLog.toString().contains('vmess-in'),
        const Duration(seconds: 5),
      );
      expect(
        sawInbound,
        isTrue,
        reason: '本地 vmess 服务端没有记录入站连接:\n$serverLog',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: hostExe == null || coreExe == null
      ? '设置 HALO_HOST_EXE 与 HALO_CORE_EXE 后运行此集成测试'
      : null);
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Polls until [port] accepts a TCP connection.
Future<void> _waitPort(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (true) {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      return;
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('端口 $port 在 20 秒内没有开始监听');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

Future<bool> _waitFor(bool Function() predicate, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return predicate();
}

Future<RuntimeSnapshot> _snapshot(HaloClient client) async {
  final response = await client.send(HaloAction.snapshotGet);
  return RuntimeSnapshot.fromJson(response.result ?? const {});
}

Future<RuntimeSnapshot> _waitCoreRunning(HaloClient client) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  RuntimeSnapshot last;
  while (true) {
    final response = await client.send(HaloAction.snapshotGet);
    last = RuntimeSnapshot.fromJson(response.result ?? const {});
    if (last.coreState == CoreState.running) return last;
    if (DateTime.now().isAfter(deadline)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> _killChildrenOf(int pid) async {
  if (!Platform.isWindows) return;
  try {
    await Process.run('wmic', [
      'process',
      'where',
      'ParentProcessId=$pid',
      'call',
      'terminate',
    ]);
  } catch (_) {
    // Best effort; a missing wmic must not fail the test.
  }
}
