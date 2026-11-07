import 'dart:io';

import 'package:flutter/material.dart';

void main(List<String> args) {
  runApp(const MaterialApp(home: Probe()));
  if (args.length == 2 && args.first == '--lifecycle-probe') {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        const backend = String.fromEnvironment('HALO_BACKEND');
        final result = await Process.run(backend, ['status']);
        await File(args[1]).writeAsString(result.stdout as String);
        exit(result.exitCode);
      } catch (error) {
        await File(args[1]).writeAsString('ERROR: $error');
        exit(1);
      }
    });
  }
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  String status = '尚未连接';
  Future<void> command(String action) async {
    try {
      const path = String.fromEnvironment('HALO_BACKEND');
      if (path.isEmpty) throw StateError('缺少 HALO_BACKEND');
      final result = await Process.run(path, [
        action,
      ]).timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() => status = '${result.stdout}\n${result.stderr}');
      }
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('clash-halo 生命周期验证')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Text('仅本机测试，不设置系统代理或启用 TUN'),
          for (final action in ['status', 'start', 'stop'])
            TextButton(onPressed: () => command(action), child: Text(action)),
          TextButton(onPressed: () => exit(0), child: const Text('退出界面，保留后台')),
          SelectableText(status),
        ],
      ),
    ),
  );
}
