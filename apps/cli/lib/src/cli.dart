/// The `halo-cli` command line.
///
/// Scope: subscription and node import only. Measurement (延迟/速度/连通性) is
/// deliberately absent — the three are separate measurements with separate
/// owners (docs/agents/measurement.md), and a CLI that quietly ran one would
/// be a second implementation of the part most likely to lie.
///
/// The database is opened directly, through the same [HaloStore] the window
/// uses. That is not a second storage layer: the Go host never opens SQLite
/// (grep shows the host only projects what Dart publishes to it), so the Dart
/// process is the database authority by construction. The alternative — a new
/// pipe action that makes the host parse Clash YAML, sing-box JSON, Base64 and
/// share links — would duplicate the importer in Go.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';

import 'paths.dart';

/// Kept in step with pubspec.yaml; the CLI prints it for `--version`.
const cliVersion = '0.1.0';

typedef LineSink = void Function(String line);

/// Raised for anything the user can fix by changing the command line: wrong
/// number of arguments, an unknown option, a selector that matches nothing.
/// Exit code 2 distinguishes it from "the command ran and failed" (1).
class UsageException implements Exception {
  UsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

class Cli {
  Cli(
    this.arguments, {
    LineSink? out,
    LineSink? err,
    this.fetcherFactory,
    Map<String, String>? environment,
    String? resolvedExecutable,
  })  : out = GuardedSink(out ?? stdout.writeln),
        err = GuardedSink(err ?? stderr.writeln),
        environment = environment ?? Platform.environment,
        resolvedExecutable = resolvedExecutable ?? Platform.resolvedExecutable;

  final List<String> arguments;
  final GuardedSink out;
  final GuardedSink err;
  /// Builds the fetcher from the parsed flags. Tests inject their own so they
  /// can serve canned bodies; production leaves it null.
  ///
  /// A factory rather than a ready-made instance: `--proxy` and `--timeout` are
  /// only known after parsing, and an injected instance would silently ignore
  /// both — which is exactly the bug the proxy tests caught.
  final SubscriptionFetcher Function({
    required Duration timeout,
    String? proxyUrl,
  })? fetcherFactory;
  final Map<String, String> environment;
  final String resolvedExecutable;

  /// The fetcher actually used for the next command.
  ///
  /// Rebuilt from `--timeout` and `--proxy` rather than mutated, so one command
  /// cannot inherit the previous one's transport.
  late SubscriptionFetcher _activeFetcher;

  /// Builds the fetcher for a parsed command line.
  ///
  /// `--proxy` takes an explicit endpoint (`127.0.0.1:7890`); `--via-system-proxy`
  /// is not offered on purpose, because there is no reliable way to read a
  /// Windows system proxy from Dart and guessing would produce the wrong tunnel.
  SubscriptionFetcher _buildFetcher(_Parsed parsed) {
    final seconds = int.tryParse(parsed.values['timeout'] ?? '');
    final timeout = seconds == null || seconds <= 0
        ? const Duration(seconds: 20)
        : Duration(seconds: seconds);
    final factory = fetcherFactory;
    if (factory != null) {
      return factory(timeout: timeout, proxyUrl: parsed.values['proxy']);
    }
    return SubscriptionFetcher(
      timeout: timeout,
      proxyUrl: parsed.values['proxy'],
    );
  }

  /// The fetcher for one refresh.
  ///
  /// `--proxy` names an endpoint explicitly; a profile with its own switch on
  /// but no endpoint given uses the conventional local port, because that is
  /// where this app's core listens unless the user moved it. Guessing here is
  /// preferable to silently going direct, which is the bug the switch exists to
  /// prevent.
  SubscriptionFetcher _fetcherFor({
    required bool viaProxy,
    String? proxyOverride,
  }) {
    if (!viaProxy) return _activeFetcher;
    // Whatever `--proxy` said wins verbatim: normalising it would make the value
    // the user typed unrecognisable in diagnostics, and the fetcher already
    // accepts both `host:port` and a full URL.
    final endpoint =
        proxyOverride ?? _activeFetcher.proxyUrl ?? _defaultProxyEndpoint;
    final factory = fetcherFactory;
    if (factory != null) {
      return factory(timeout: _activeFetcher.timeout, proxyUrl: endpoint);
    }
    return SubscriptionFetcher(
      timeout: _activeFetcher.timeout,
      totalTimeout: _activeFetcher.totalTimeout,
      proxyUrl: endpoint,
    );
  }

  /// Runs the command and returns the process exit code.
  Future<int> run() async {
    final _Parsed parsed;
    try {
      parsed = _parse(arguments);
    } on UsageException catch (error) {
      err(error.message);
      err('运行 halo-cli --help 查看用法');
      return 2;
    }
    if (parsed.flags.contains('help')) {
      for (final line in _helpLines) {
        out(line);
      }
      return 0;
    }
    if (parsed.flags.contains('version')) {
      out('halo-cli $cliVersion');
      return 0;
    }
    if (parsed.positional.isEmpty) {
      err('缺少命令');
      err('运行 halo-cli --help 查看用法');
      return 2;
    }
    final timeout = parsed.values['timeout'];
    if (timeout != null) {
      final seconds = int.tryParse(timeout);
      if (seconds == null || seconds <= 0) {
        err('--timeout 需要正整数秒，例如 --timeout 30');
        return 2;
      }
    }
    // An injected fetcher (tests) wins; otherwise `--timeout` and `--proxy` build
    // one. Reading the flag here keeps every subcommand consistent.
    _activeFetcher = _buildFetcher(parsed);
    try {
      return await _dispatch(parsed);
    } on UsageException catch (error) {
      err(error.message);
      err('运行 halo-cli --help 查看用法');
      return 2;
    }
  }

  Future<int> _dispatch(_Parsed parsed) async {
    final command = parsed.positional.first;
    final rest = parsed.positional.sublist(1);
    switch (command) {
      case 'sub':
        return _subscription(parsed, rest);
      case 'nodes':
        return _nodes(parsed, rest);
      case 'groups':
        return _groups(parsed, rest);
      case 'import':
        return _importFile(parsed, rest);
      default:
        throw UsageException('未知命令：$command');
    }
  }

  // ------------------------------------------------------------------
  // sub
  // ------------------------------------------------------------------

  Future<int> _subscription(_Parsed parsed, List<String> rest) async {
    if (rest.isEmpty) throw UsageException('sub 需要子命令：list / add / update / remove');
    final action = rest.first;
    final args = rest.sublist(1);
    return switch (action) {
      'list' => _subList(parsed),
      'add' => _subAdd(parsed, args),
      'update' => _subUpdate(parsed, args),
      'remove' => _subRemove(parsed, args),
      _ => throw UsageException('未知的 sub 子命令：$action'),
    };
  }

  Future<int> _subList(_Parsed parsed) => _withStore(parsed, (session) {
        final profiles = session.subscriptions.allProfiles();
        if (parsed.flags.contains('json')) {
          out(const JsonEncoder.withIndent('  ').convert({
            'database': session.dbPath,
            'groups': [
              for (final g in session.groups.allGroups()) g.toJson(),
            ],
            'subscriptions': [
              for (final p in profiles)
                {
                  ...p.toJson(),
                  'groupNodes': session.nodes.nodesForProfile(p.id).length,
                },
            ],
          }));
          return 0;
        }
        final total = session.nodes.allNodes().length;
        final groupNames = {
          for (final g in session.groups.allGroups()) g.id: g.name,
        };
        out('${profiles.length} 条订阅 · $total 个节点 · ${session.dbPath}');
        for (final profile in profiles) {
          final updated = profile.lastUpdatedAtMs == 0
              ? '未更新'
              : _stamp(profile.lastUpdatedAtMs);
          final status = profile.lastError != null
              ? '错误：${profile.lastError}'
              : (profile.nodeCount == 0 ? '空' : '正常');
          final group =
              profile.groupId == null ? '' : '  「${groupNames[profile.groupId]}」';
          out('${profile.name}  [${profile.nodeCount} 节点]  $updated  $status$group'
              '${profile.enabled ? '' : '  [已停用]'}'
              '${_proxyMarker(profile)}');
          out('    ${profile.id}  '
              '${profile.isRemote ? profile.displayUrl : '（本地订阅）'}');
        }
        return 0;
      });

  Future<int> _subAdd(_Parsed parsed, List<String> args) async {
    if (args.length != 1) {
      throw UsageException('用法：halo-cli sub add <url> [--name 名称] [--no-fetch]');
    }
    final url = args.first.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !_isRemote(uri)) {
      throw UsageException('订阅地址必须是 HTTP 或 HTTPS：$url');
    }
    final name = parsed.values['name']?.trim();
    final noFetch = parsed.flags.contains('no-fetch');
    // `--proxy <endpoint>` is both the transport for this fetch and the standing
    // preference for later updates, so the row ends up configured the way it was
    // just fetched. Without it the stored switch keeps its default (direct).
    final proxyUrl = parsed.values['proxy'];
    final useProxy = proxyUrl != null;
    return _withStore(parsed, (session) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final matches =
          session.subscriptions.allProfiles().where((p) => p.url == url);
      final existing = matches.isEmpty ? null : matches.first;
      final profile = existing != null
          ? existing.copyWith(
              name: (name == null || name.isEmpty) ? null : name,
              useProxy: useProxy ? true : null,
              proxyUrl: proxyUrl,
            )
          : SubscriptionProfile(
              id: 'sub_$now',
              name: (name == null || name.isEmpty) ? uri.host : name,
              url: url,
              createdAtMs: now,
              sortIndex: session.nextSortIndex(),
              useProxy: useProxy,
              proxyUrl: proxyUrl,
            );
      session.subscriptions.upsert(profile);
      if (existing != null) {
        out('订阅已存在，改用现有条目：${profile.name}（${profile.id}）');
      } else {
        out('已添加订阅 ${profile.name}（${profile.id}）');
      }
      if (noFetch) {
        out('未下载节点（--no-fetch）；稍后可用 halo-cli sub update ${profile.id} 更新');
        return 0;
      }
      return _refreshAndReport(session, profile, viaProxy: useProxy);
    });
  }

  Future<int> _subUpdate(_Parsed parsed, List<String> args) => _withStore(
        parsed,
        (session) async {
          final all = session.subscriptions.allProfiles();
          final List<SubscriptionProfile> targets;
          if (parsed.flags.contains('all')) {
            if (args.isNotEmpty) {
              throw UsageException('--all 与指定订阅不能同时使用');
            }
            targets = all.where((p) => _isRemote(Uri.tryParse(p.url))).toList();
          } else {
            if (args.length != 1) {
              throw UsageException(
                  '用法：halo-cli sub update <id|名称> 或 halo-cli sub update --all');
            }
            final profile = _select(all, args.first);
            if (!_isRemote(Uri.tryParse(profile.url))) {
              throw UsageException('该订阅不是 HTTP 订阅，无法更新：${profile.name}');
            }
            targets = [profile];
          }
          if (targets.isEmpty) {
            out('没有可更新的 HTTP 订阅');
            return 0;
          }
          var failures = 0;
          final viaProxy = parsed.flags.contains('via-proxy');
          for (final profile in targets) {
            final code = await _refreshAndReport(
              session,
              profile,
              prefix: true,
              viaProxy: viaProxy,
            );
            if (code != 0) failures++;
          }
          if (targets.length > 1) {
            out('更新完成：${targets.length - failures} 成功 / $failures 失败');
          }
          return failures == 0 ? 0 : 1;
        },
      );

  Future<int> _subRemove(_Parsed parsed, List<String> args) {
    if (args.length != 1) {
      throw UsageException(
          '用法：halo-cli sub remove <id|名称> [--purge-nodes]');
    }
    return _withStore(parsed, (session) {
      final profile = _select(session.subscriptions.allProfiles(), args.first);
      final owned = session.nodes.nodesForProfile(profile.id).length;
      if (parsed.flags.contains('purge-nodes')) {
        session.store.transaction((db) {
          db.execute('DELETE FROM ${Tables.nodes} WHERE profile_id = ?', [profile.id]);
          db.execute('DELETE FROM ${Tables.subscriptions} WHERE id = ?', [profile.id]);
        });
        out('已删除订阅 ${profile.name} 及其 $owned 个节点');
      } else {
        // Repository behaviour: nodes survive as 本地 nodes, so removing a
        // subscription cannot silently break the active connection.
        session.subscriptions.deleteProfile(profile.id);
        out('已删除订阅 ${profile.name}；$owned 个节点保留为本地节点'
            '（需要一起删除时加 --purge-nodes）');
      }
      return 0;
    });
  }

  // ------------------------------------------------------------------
  // nodes / import
  // ------------------------------------------------------------------

  Future<int> _nodes(_Parsed parsed, List<String> rest) async {
    if (rest.isEmpty || rest.first != 'list') {
      throw UsageException('nodes 需要子命令：list');
    }
    if (rest.length > 1) throw UsageException('用法：halo-cli nodes list [--sub <id|名称>]');
    return _withStore(parsed, (session) {
      final profiles = {
        for (final p in session.subscriptions.allProfiles()) p.id: p,
      };
      final selector = parsed.values['sub'];
      SubscriptionProfile? only;
      if (selector != null && selector.isNotEmpty) {
        only = _select(session.subscriptions.allProfiles(), selector);
      }
      final nodes = only == null
          ? session.nodes.allNodes()
          : session.nodes.nodesForProfile(only.id);
      if (parsed.flags.contains('json')) {
        out(const JsonEncoder.withIndent('  ').convert({
          'database': session.dbPath,
          'subscription': only?.toJson(),
          'nodes': [
            for (final n in nodes)
              {...n.toJson(), 'group': profiles[n.profileId]?.name},
          ],
        }));
        return 0;
      }
      out('${nodes.length} 个节点'
          '${only == null ? '' : '（${only.name}）'} · ${session.dbPath}');
      for (final node in nodes) {
        final group = profiles[node.profileId]?.name ?? '本地';
        out('${node.name}  [${node.protocol.wire}]  '
            '${node.server}:${node.port}  $group');
      }
      return 0;
    });
  }

  // ------------------------------------------------------------------
  // groups
  // ------------------------------------------------------------------

  Future<int> _groups(_Parsed parsed, List<String> rest) async {
    if (rest.isEmpty) {
      throw UsageException(
        'groups 需要子命令：list / add / rename / remove / assign');
    }
    final action = rest.first;
    final args = rest.sublist(1);
    switch (action) {
      case 'list':
        return _withStore(parsed, (session) {
          final groups = session.groups.allGroups();
          final profiles = session.subscriptions.allProfiles();
          if (parsed.flags.contains('json')) {
            out(const JsonEncoder.withIndent('  ').convert({
              'database': session.dbPath,
              'groups': [
                for (final g in groups)
                  {
                    ...g.toJson(),
                    'subscriptions': [
                      for (final p in profiles)
                        if (p.groupId == g.id) p.id,
                    ],
                  },
              ],
              'ungrouped': [
                for (final p in profiles)
                  if (p.groupId == null) p.id,
              ],
            }));
            return 0;
          }
          out('${groups.length} 个集合 · ${session.dbPath}');
          for (final group in groups) {
            final members = profiles.where((p) => p.groupId == group.id);
            out('${group.name}  [${members.length} 条]  ${group.id}');
            for (final profile in members) {
              out('    ${profile.name}');
            }
          }
          final ungrouped = profiles.where((p) => p.groupId == null);
          if (ungrouped.isNotEmpty) {
            out('未分组  [${ungrouped.length} 条]');
            for (final profile in ungrouped) {
              out('    ${profile.name}');
            }
          }
          return 0;
        });
      case 'add':
        if (args.length != 1) {
          throw UsageException('用法：halo-cli groups add <名称>');
        }
        return _withStore(parsed, (session) {
          final name = SubscriptionGroup.normalizeName(args.first);
          if (name == null) throw UsageException('集合名不能为空');
          final now = DateTime.now().millisecondsSinceEpoch;
          // Microseconds plus a collision check: a millisecond stamp let two
          // `groups add` calls in the same tick share an id, and `upsert` then
          // renamed the first group instead of creating a second.
          var stamp = DateTime.now().microsecondsSinceEpoch;
          while (session.groups.groupById('grp_$stamp') != null) {
            stamp++;
          }
          final group = session.groups.upsert(
            SubscriptionGroup(
              id: 'grp_$stamp',
              name: name,
              createdAtMs: now,
              sortIndex: session.groups.allGroups().length,
            ),
          );
          if (group == null) {
            err('已存在同名集合：$name');
            return 1;
          }
          out('已创建集合 ${group.name}（${group.id}）');
          return 0;
        });
      case 'rename':
        if (args.length != 2) {
          throw UsageException('用法：halo-cli groups rename <id|名称> <新名称>');
        }
        return _withStore(parsed, (session) {
          final group = _selectGroup(session, args.first);
          final name = SubscriptionGroup.normalizeName(args[1]);
          if (name == null) throw UsageException('集合名不能为空');
          if (name == group.name) {
            out('集合名未改变：${group.name}');
            return 0;
          }
          // Renaming keeps the id, so memberships are untouched. A collision is
          // refused rather than merged, for the same reason the repository does:
          // merging moves subscriptions the user never selected.
          final saved = session.groups.upsert(group.copyWith(name: name));
          if (saved == null) {
            err('已存在同名集合：$name');
            return 1;
          }
          out('集合 ${group.name} 已重命名为 ${saved.name}（${saved.id}）');
          return 0;
        });
      case 'remove':
        if (args.length != 1) {
          throw UsageException('用法：halo-cli groups remove <id|名称>');
        }
        return _withStore(parsed, (session) {
          final group = _selectGroup(session, args.first);
          final affected = session.groups.deleteGroup(group.id);
          out('已删除集合 ${group.name}；$affected 条订阅变为未分组');
          return 0;
        });
      case 'assign':
        if (args.length != 2) {
          throw UsageException(
            '用法：halo-cli groups assign <订阅 id|名称> <集合 id|名称|none>',
          );
        }
        return _withStore(parsed, (session) {
          final profile =
              _select(session.subscriptions.allProfiles(), args.first);
          final target = args[1].trim();
          if (target == 'none' || target == '-' || target == '未分组') {
            session.subscriptions.setGroup(profile.id, null);
            out('「${profile.name}」已移到未分组');
            return 0;
          }
          final group = _selectGroup(session, target);
          session.subscriptions.setGroup(profile.id, group.id);
          out('「${profile.name}」已移到集合「${group.name}」');
          return 0;
        });
      default:
        throw UsageException('未知的 groups 子命令：$action');
    }
  }

  /// Resolves a group by id, exact name, then a unique name fragment.
  /// How the listing marks a subscription's proxy state.
  ///
  /// Three states, so the two markers differ: an explicit choice says so, and an
  /// unset one reports what the policy will actually do. Printing nothing for
  /// "automatic" would hide that a GitHub row is going through the proxy.
  String _proxyMarker(SubscriptionProfile profile) {
    if (!profile.useProxyFor(profile.url)) return '';
    return profile.useProxy == null ? '  [经代理·自动]' : '  [经代理]';
  }

  SubscriptionGroup _selectGroup(_Session session, String selector) {
    final groups = session.groups.allGroups();
    final needle = selector.trim();
    for (final match in [
      groups.where((g) => g.id == needle),
      groups.where((g) => g.name == needle),
      groups.where((g) => g.name.toLowerCase().contains(needle.toLowerCase())),
    ]) {
      final hits = match.toList();
      if (hits.length == 1) return hits.first;
      if (hits.length > 1) {
        throw UsageException(
          '“$needle”匹配到多个集合，请改用 id：\n'
          '${hits.map((g) => '  ${g.id}  ${g.name}').join('\n')}',
        );
      }
    }
    throw UsageException(
      '没有匹配“$needle”的集合。现有集合：\n'
      '${groups.isEmpty ? '  （无）' : groups.map((g) => '  ${g.id}  ${g.name}').join('\n')}',
    );
  }

  Future<int> _importFile(_Parsed parsed, List<String> args) async {
    if (args.length != 1) {
      throw UsageException('用法：halo-cli import <文件> [--name 提示]');
    }
    final file = File(args.first);
    if (!file.existsSync()) {
      throw UsageException('文件不存在：${file.absolute.path}');
    }
    final body = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    final result = importNodes(body);
    if (result.nodes.isEmpty) {
      final why = result.failed.isEmpty
          ? '内容里没有可识别的节点'
          : result.failed.first.message;
      err('导入失败：$why');
      return 1;
    }
    return _withStore(parsed, (session) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final written = session.nodes.insertAll(result.nodes, nowMs: now);
      final name = parsed.values['name']?.trim();
      out('已导入 ${written.stored.length} 个节点'
          '${name == null || name.isEmpty ? '' : '（$name）'}'
          '${result.failed.isEmpty ? '' : '，${result.failed.length} 条未导入：${describeImportFailures(result.failureKinds)}'}'
          '${result.duplicateCount > 0 ? '，${result.duplicateCount} 条重复' : ''}'
          '${written.skippedDuplicates.isEmpty ? '' : '，跨订阅重复 ${written.skippedDuplicates.length} 条（节点池只保留一份）'}');
      if (result.skipped.isNotEmpty) {
        out('跳过 ${result.skipped.length} 条：${result.skipped.first.message}');
      }
      return 0;
    });
  }

  // ------------------------------------------------------------------
  // plumbing
  // ------------------------------------------------------------------

  /// Opens the database, hands [body] a session and always closes it.
  Future<int> _withStore(
    _Parsed parsed,
    FutureOr<int> Function(_Session session) body,
  ) async {
    final dataDir = resolveDataDir(
      overrideDir: parsed.values['dir'],
      environment: environment,
      resolvedExecutable: resolvedExecutable,
    );
    final dbPath = resolveDbPath(dbPath: parsed.values['db'], dataDir: dataDir);
    final opened = HaloStore.open(dbPath);
    if (!opened.ok) {
      err('无法打开数据库：$dbPath');
      err(opened.error ?? '未知错误');
      return 1;
    }
    final session = _Session(
      store: opened.store!,
      dbPath: dbPath,
      subscriptions: SubscriptionRepository(opened.store!),
      nodes: NodeRepository(opened.store!),
      groups: SubscriptionGroupRepository(opened.store!),
    );
    try {
      return await body(session);
    } finally {
      opened.store!.close();
    }
  }

  /// Refreshes one subscription and prints the outcome; 0 on success, 1 on a
  /// failed download. The old nodes stay untouched on failure.
  Future<int> _refreshAndReport(
    _Session session,
    SubscriptionProfile profile, {
    bool prefix = false,
    bool viaProxy = false,
  }) async {
    final label = prefix ? '${profile.name}：' : '';
    try {
      if (!profile.isRemote) {
        throw SubscriptionFetchException('本地订阅没有可下载的地址');
      }
      // `{date}` expands at fetch time so a daily source keeps working, and a
      // source that has not published today's file falls back a few days. The
      // stored URL stays the template.
      final download = await _fetcherFor(
        viaProxy: viaProxy || profile.useProxyFor(profile.url),
        proxyOverride: profile.proxyUrl,
      ).fetchWithDateFallback(profile.url);
      final body = download.body;
      final result = importNodes(body);
      if (result.nodes.isEmpty) {
        final why = result.failed.isEmpty
            ? '响应里没有节点'
            : result.failed.first.message;
        throw SubscriptionFetchException('解析失败（$why），已保留旧数据');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      NodeWriteResult replaced = const NodeWriteResult();
      session.store.transaction((_) {
        replaced = session.nodes
            .replaceProfileNodes(profile.id, result.nodes, nowMs: now);
        // The row count is what this profile owns after the replace, not what
        // the source listed: connections another subscription already owns are
        // skipped, and the source count would disagree with the node list.
        session.subscriptions.upsert(profile.copyWith(
          lastUpdatedAtMs: now,
          lastError: download.usedFallback
              ? '当天文件尚未发布，已使用 ${download.fallbackDays} 天前的文件'
              : null,
          clearLastError: !download.usedFallback,
          nodeCount: replaced.stored.length,
        ));
      });
      out('$label已导入 ${result.nodes.length} 个节点'
          '${result.failed.isEmpty ? '' : '，${result.failed.length} 条未导入：${describeImportFailures(result.failureKinds)}'}'
          '${result.duplicateCount > 0 ? '，${result.duplicateCount} 条重复' : ''}'
          '${replaced.skippedDuplicates.isEmpty ? '' : '，跨订阅重复 ${replaced.skippedDuplicates.length} 条'}');
      return 0;
    } catch (error) {
      session.subscriptions.markFailed(
        profile.id,
        atMs: DateTime.now().millisecondsSinceEpoch,
        error: '$error',
      );
      err('$label更新失败：$error');
      return 1;
    }
  }

  /// Resolves a subscription by id, exact name, then a unique name/url
  /// fragment. Ambiguity is an error with the candidates listed, never a guess.
  SubscriptionProfile _select(
      List<SubscriptionProfile> profiles, String selector) {
    final needle = selector.trim();
    for (final match in [
      profiles.where((p) => p.id == needle),
      profiles.where((p) => p.name == needle),
      profiles.where((p) => p.name.toLowerCase() == needle.toLowerCase()),
      profiles.where((p) =>
          p.name.toLowerCase().contains(needle.toLowerCase()) ||
          p.url.contains(needle)),
    ]) {
      final hits = match.toList();
      if (hits.length == 1) return hits.first;
      if (hits.length > 1) {
        throw UsageException(
          '“$needle”匹配到多个订阅，请改用 id：\n'
          '${hits.map((p) => '  ${p.id}  ${p.name}').join('\n')}',
        );
      }
    }
    throw UsageException(
      '没有匹配“$needle”的订阅。现有订阅：\n'
      '${profiles.isEmpty ? '  （无）' : profiles.map((p) => '  ${p.id}  ${p.name}').join('\n')}',
    );
  }
}

class _Session {
  _Session({
    required this.store,
    required this.dbPath,
    required this.subscriptions,
    required this.nodes,
    required this.groups,
  });

  final HaloStore store;
  final String dbPath;
  final SubscriptionRepository subscriptions;
  final NodeRepository nodes;
  final SubscriptionGroupRepository groups;

  int nextSortIndex() {
    final profiles = subscriptions.allProfiles();
    if (profiles.isEmpty) return 0;
    return profiles.map((p) => p.sortIndex).reduce((a, b) => a > b ? a : b) + 1;
  }
}

/// One parsed command line: positionals, valued options and boolean flags.
class _Parsed {
  final List<String> positional = <String>[];
  final Map<String, String> values = <String, String>{};
  final Set<String> flags = <String>{};
}

/// Where this app's core listens for mixed traffic unless the user moved it.
///
/// A literal rather than a read of `routing.mixedPort`: the CLI has no settings
/// repository open at the point a fetch is built, and reading one just to print
/// a default would make `--help` touch the database.
const String _defaultProxyEndpoint = 'http://127.0.0.1:7890';

const _valueOptions = {
  'db',
  'dir',
  'timeout',
  'name',
  'sub',
  'proxy',
  'group',
};
const _flagOptions = {
  'json',
  'help',
  'version',
  'no-fetch',
  'all',
  'purge-nodes',
  // `--via-proxy` is the one-off "fetch it through the tunnel this time";
  // `--proxy <endpoint>` both sets the transport and stores the preference.
  'via-proxy',
};

_Parsed _parse(List<String> args) {
  final parsed = _Parsed();
  var i = 0;
  var positionalOnly = false;
  while (i < args.length) {
    final arg = args[i];
    if (positionalOnly) {
      parsed.positional.add(arg);
      i++;
      continue;
    }
    if (arg == '--') {
      positionalOnly = true;
      i++;
      continue;
    }
    if (arg == '-h') {
      parsed.flags.add('help');
      i++;
      continue;
    }
    if (arg.startsWith('--')) {
      final eq = arg.indexOf('=');
      final name = (eq >= 0 ? arg.substring(2, eq) : arg.substring(2))
          .toLowerCase();
      if (_flagOptions.contains(name)) {
        if (eq >= 0) throw UsageException('--$name 不接受取值');
        parsed.flags.add(name);
        i++;
        continue;
      }
      if (!_valueOptions.contains(name)) throw UsageException('未知选项：$arg');
      final String value;
      if (eq >= 0) {
        value = arg.substring(eq + 1);
        i++;
      } else {
        if (i + 1 >= args.length) throw UsageException('--$name 需要一个值');
        value = args[i + 1];
        i += 2;
      }
      if (value.isEmpty) throw UsageException('--$name 的值不能为空');
      parsed.values[name] = value;
      continue;
    }
    if (arg.startsWith('-') && arg.length > 1) {
      throw UsageException('未知选项：$arg');
    }
    parsed.positional.add(arg);
    i++;
  }
  return parsed;
}

bool _isRemote(Uri? uri) =>
    uri != null &&
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty;

String _stamp(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

const _helpLines = <String>[
  'halo-cli $cliVersion — clash-halo 命令行（订阅与节点导入，不含测速）',
  '',
  '用法：',
  '  halo-cli <命令> [参数] [选项]',
  '',
  '命令：',
  '  sub list                      列出订阅（含所属集合与「经代理」标记）',
  '  sub add <url> [--name 名称]   添加订阅并立即下载节点',
  '        [--no-fetch]            只加订阅条目，不下载',
  '  sub update <id|名称>          更新一条订阅',
  '        [--via-proxy]           本次强制经代理下载',
  '  sub update --all [--via-proxy]',
  '                                依次更新所有 HTTP 订阅',
  '  groups list                   列出集合及其订阅',
  '  groups add <名称>             新建集合',
  '  groups rename <id|名称> <新名> 重命名集合（成员不变）',
  '  groups assign <订阅> <集合|none>',
  '                                把订阅移入集合，none 表示未分组',
  '  groups remove <id|名称>       删除集合（订阅保留，变为未分组）',
  '  sub remove <id|名称> [--purge-nodes]',
  '                                删除订阅（默认保留节点为本地节点）',
  '  nodes list [--sub <id|名称>]  列出节点',
  '  import <文件>                 从本地文件导入节点',
  '                                （Clash YAML / sing-box / v2rayN / Base64 / 分享链接）',
  '',
  '选项：',
  '  --dir <目录>                  数据目录（含 clash-halo.db）',
  '  --db <文件>                   直接指定数据库文件',
  '  --json                        以 JSON 输出（sub list / nodes list）',
  '  --proxy <地址>                经该代理下载，如 127.0.0.1:7890；同时存为该订阅的偏好',
  '  --via-proxy                   本次更新强制经代理（端点取订阅已存的值或默认端口）',
  '  --timeout <秒>                单次等待上限（连接/分片），默认 20；总时长 3 倍',
  '  --no-fetch                    只写入订阅条目',
  '  --all                         作用于全部 HTTP 订阅',
  '  --purge-nodes                 删除订阅时一并删除其节点',
  '  -h, --help                    显示帮助',
  '  --version                     显示版本',
  '',
  '数据目录解析顺序：--dir > HALO_DATA_DIR > 便携版 user-data > %LOCALAPPDATA%\\clash-halo',
  '退出码：0 成功，1 命令执行失败（如下载失败），2 用法错误',
  '',
  '示例：',
  r'  halo-cli --dir D:\project\clash-halo\build\windows-x64\user-data sub list',
  '  halo-cli sub add "https://example.com/sub" --name 机场A',
  '  halo-cli sub update --all',
  '  halo-cli nodes list --sub 机场A',
  '  halo-cli sub add "https://example.com/sub" --proxy 127.0.0.1:7890',
  '  halo-cli groups add 工作 && halo-cli groups assign 机场A 工作',
];
/// Writes one line, and treats a closed downstream as the end of output.
///
/// `halo-cli nodes list | head` closes the pipe after a few lines. Dart's
/// stdout reports that write as a [FileSystemException] (Windows 232
/// "管道正在被关闭", POSIX EPIPE) rather than the SIGPIPE a C program never
/// sees, so the old code surfaced an unhandled exception and a stack trace
/// while the user had only asked for the first lines. A reader that stops
/// reading is a normal end of output, not a program fault.
class GuardedSink {
  GuardedSink(this._sink);

  final LineSink _sink;
  bool _closed = false;

  void call(String line) {
    if (_closed) return;
    try {
      _sink(line);
    } on FileSystemException catch (error) {
      if (!isClosedPipeError(error)) rethrow;
      _closed = true;
    }
  }

}

/// Whether [error] is a downstream that stopped reading (`halo-cli ... | head`).
///
/// Dart reports this asynchronously through the zone, not from the `writeln`
/// call, so the check has to be available to the entry point as well as to
/// [GuardedSink].
bool isClosedPipeError(Object error) {
  if (error is! FileSystemException) return false;
  final code = error.osError?.errorCode;
  // 109 ERROR_BROKEN_PIPE, 232 ERROR_NO_DATA, 32 EPIPE.
  if (code == 109 || code == 232 || code == 32) return true;
  return error.message.contains('管道正在被关闭') ||
      error.message.contains('Broken pipe') ||
      (error.message.contains('writeFrom failed') &&
          error.message.contains('pipe'));
}
