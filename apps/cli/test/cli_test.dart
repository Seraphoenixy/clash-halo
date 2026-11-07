import 'dart:convert';
import 'dart:io';

import 'package:halo_cli/halo_cli.dart';
import 'package:halo_domain/halo_domain.dart';
import 'package:halo_storage/halo_storage.dart';
import 'package:test/test.dart';

/// Two trojan links, the smallest body every importer path agrees on.
const _twoNodes = 'trojan://pw@hk01.example.com:443#香港01\n'
    'trojan://pw@hk02.example.com:443#香港02\n';

/// Serves canned bodies per URL; a URL absent from [bodies] fails like a 404.
class FakeFetcher extends SubscriptionFetcher {
  FakeFetcher(this.bodies, {super.proxyUrl});

  final Map<String, String> bodies;

  /// A copy configured with [proxyUrl], which is how the CLI rebuilds a fetcher
  /// once it has parsed `--proxy` or seen the profile's own switch.
  FakeFetcher forProxy(String? proxyUrl) =>
      FakeFetcher(bodies, proxyUrl: proxyUrl);

  @override
  Future<String> fetch(Uri uri) async {
    final body = bodies[uri.toString()];
    if (body == null) throw SubscriptionFetchException('HTTP 404');
    return body;
  }
}

/// A fake that records the proxy endpoint every fetcher was built with.
///
/// The record has to survive [forProxy] rebuilding the object, so the log is
/// shared between copies: a per-instance list would only ever show the endpoint
/// of the copy the test happens to hold.
class ProxyRecordingFetcher extends FakeFetcher {
  ProxyRecordingFetcher(super.bodies, this.proxyUrls);

  final List<String?> proxyUrls;

  @override
  FakeFetcher forProxy(String? proxyUrl) {
    proxyUrls.add(proxyUrl);
    return ProxyRecordingFetcher(bodies, proxyUrls);
  }
}

class Harness {
  Harness()
      : dir = Directory.systemTemp.createTempSync('halo-cli-test-');

  final Directory dir;
  final out = <String>[];
  final err = <String>[];
  var fetcher = FakeFetcher(const {});

  /// The endpoint log, when the test armed a [ProxyRecordingFetcher].
  List<String?> get proxyLog =>
      fetcher is ProxyRecordingFetcher
          ? (fetcher as ProxyRecordingFetcher).proxyUrls
          : const [];

  String get dbPath => '${dir.path}${Platform.pathSeparator}clash-halo.db';

  Future<int> run(List<String> args, {FakeFetcher? withFetcher}) {
    if (withFetcher != null) fetcher = withFetcher;
    return Cli(
      [...args, '--dir', dir.path],
      out: out.add,
      err: err.add,
      // A factory, not an instance: the CLI builds its fetcher *after* parsing,
      // so --proxy/--timeout reach it. The factory hands back the fake the test
      // armed, rebuilt with whatever proxy the CLI decided on, which is what the
      // proxy tests assert.
      fetcherFactory: ({required Duration timeout, String? proxyUrl}) =>
          fetcher.forProxy(proxyUrl),
      environment: const {},
      resolvedExecutable: 'C:\\nonexistent\\halo-cli.exe',
    ).run();
  }

  /// Reads the database the command wrote, after the command closed it.
  T read<T>(T Function(HaloStore store) body) {
    final opened = HaloStore.open(dbPath);
    final store = opened.store;
    if (store == null) throw StateError('open failed: ${opened.error}');
    try {
      return body(store);
    } finally {
      store.close();
    }
  }

  void clean() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the SQLite file open for a moment.
    }
  }
}

void main() {
  late Harness h;

  setUp(() => h = Harness());
  tearDown(() => h.clean());

  test('sub add downloads and stores the subscription nodes', () async {
    h.fetcher = FakeFetcher({'https://example.com/sub': _twoNodes});

    final code = await h.run(
      ['sub', 'add', 'https://example.com/sub', '--name', '机场A'],
    );

    expect(code, 0);
    expect(h.out.join('\n'), contains('已导入 2 个节点'));
    h.read((store) {
      final profiles = SubscriptionRepository(store).allProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.single.name, '机场A');
      expect(profiles.single.nodeCount, 2);
      expect(profiles.single.lastError, isNull);
      expect(NodeRepository(store).nodesForProfile(profiles.single.id), hasLength(2));
    });
  });

  test('sub add --no-fetch writes only the profile, then update fills nodes',
      () async {
    h.fetcher = FakeFetcher({'https://example.com/sub': _twoNodes});

    expect(await h.run(['sub', 'add', 'https://example.com/sub', '--no-fetch']),
        0);
    h.read((store) {
      final profile = SubscriptionRepository(store).allProfiles().single;
      expect(profile.nodeCount, 0);
      expect(NodeRepository(store).nodesForProfile(profile.id), isEmpty);
    });

    expect(await h.run(['sub', 'update', 'example.com']), 0);
    h.read((store) {
      final profile = SubscriptionRepository(store).allProfiles().single;
      expect(profile.nodeCount, 2);
      expect(NodeRepository(store).nodesForProfile(profile.id), hasLength(2));
    });
  });

  test('a failed update keeps the previous nodes and records the error',
      () async {
    h.fetcher = FakeFetcher({'https://example.com/sub': _twoNodes});
    expect(await h.run(['sub', 'add', 'https://example.com/sub']), 0);

    h.fetcher = FakeFetcher(const {});
    final code = await h.run(['sub', 'update', '--all']);

    expect(code, 1);
    expect(h.err.join('\n'), contains('HTTP 404'));
    h.read((store) {
      final profile = SubscriptionRepository(store).allProfiles().single;
      expect(profile.lastError, contains('404'));
      // The failure left the working node list alone: that is the whole point
      // of marking the profile instead of replacing it.
      expect(NodeRepository(store).nodesForProfile(profile.id), hasLength(2));
    });
  });

  test('sub remove refiles its nodes into 本地 unless --purge-nodes', () async {
    h.fetcher = FakeFetcher({'https://example.com/sub': _twoNodes});
    expect(await h.run(['sub', 'add', 'https://example.com/sub']), 0);

    expect(await h.run(['sub', 'remove', 'example.com']), 0);
    h.read((store) {
      // The removed subscription is gone, but the built-in 本地 one now holds its
      // nodes: since v6 every node belongs to exactly one source.
      final profiles = SubscriptionRepository(store).allProfiles();
      expect(profiles.map((p) => p.id), ['local']);
      final nodes = NodeRepository(store).allNodes();
      expect(nodes, hasLength(2));
      expect(nodes.every((n) => n.profileId == kLocalProfileId), isTrue);
    });
  });

  test('sub remove --purge-nodes deletes the owned nodes too', () async {
    h.fetcher = FakeFetcher({'https://example.com/sub': _twoNodes});
    expect(await h.run(['sub', 'add', 'https://example.com/sub']), 0);

    expect(await h.run(['sub', 'remove', 'example.com', '--purge-nodes']), 0);
    h.read((store) {
      expect(SubscriptionRepository(store).allProfiles(), isEmpty);
      expect(NodeRepository(store).allNodes(), isEmpty);
    });
  });

  test('import reads a local file into the built-in 本地 subscription', () async {
    final file = File('${h.dir.path}${Platform.pathSeparator}nodes.txt')
      ..writeAsStringSync(_twoNodes);

    final code = await h.run(['import', file.path]);

    expect(code, 0);
    expect(h.out.join('\n'), contains('已导入 2 个节点'));
    h.read((store) {
      // 本地 is a real subscription row, created on first import: that is what
      // makes it renameable, groupable and listable like any other source.
      final local = SubscriptionRepository(store).profileById(kLocalProfileId);
      expect(local, isNotNull);
      expect(local!.kind, SubscriptionKind.local);
      expect(local.nodeCount, 2);
      final nodes = NodeRepository(store).allNodes();
      expect(nodes, hasLength(2));
      expect(nodes.every((n) => n.profileId == kLocalProfileId), isTrue);
    });
  });

  test('nodes list --json is machine readable', () async {
    h.fetcher = FakeFetcher({'https://example.com/sub': _twoNodes});
    expect(await h.run(['sub', 'add', 'https://example.com/sub']), 0);
    h.out.clear();

    expect(await h.run(['nodes', 'list', '--json']), 0);
    final payload = jsonDecode(h.out.join('\n')) as Map<String, Object?>;
    expect(payload['nodes'], hasLength(2));
  });

  test('sub list reports the redacted URL, not the token-bearing one',
      () async {
    h.fetcher = FakeFetcher({
      'https://example.com/api?token=secret': _twoNodes,
    });
    expect(
      await h.run(['sub', 'add', 'https://example.com/api?token=secret']),
      0,
    );
    h.out.clear();

    expect(await h.run(['sub', 'list']), 0);
    final text = h.out.join('\n');
    expect(text, contains('example.com'));
    expect(text, isNot(contains('secret')));
  });

  test('ambiguous selectors are refused instead of guessed', () async {
    expect(await h.run(['sub', 'add', 'https://a.example/sub', '--no-fetch', '--name', '机场A']), 0);
    expect(await h.run(['sub', 'add', 'https://b.example/sub', '--no-fetch', '--name', '机场B']), 0);
    h.err.clear();

    final code = await h.run(['sub', 'update', '机场']);

    expect(code, 2);
    expect(h.err.join('\n'), contains('匹配到多个订阅'));
  });

  test('unknown option and bad subcommand are usage errors (exit 2)', () async {
    expect(await h.run(['sub', 'list', '--bogus']), 2);
    expect(await h.run(['sub', 'frobnicate']), 2);
    expect(await h.run(['sub', 'add', 'file:///etc/passwd']), 2);
  });

  test('--help and --version succeed without touching the database', () async {
    expect(await h.run(['--help']), 0);
    expect(h.out.join('\n'), contains('halo-cli'));
    expect(File(h.dbPath).existsSync(), isFalse);

    h.out.clear();
    expect(await h.run(['--version']), 0);
    expect(h.out.single, 'halo-cli $cliVersion');
  });

  group('groups', () {
    test('create, assign, list and delete keep the subscriptions', () async {
      h.fetcher = FakeFetcher({
        'https://a.example/sub': _twoNodes,
        'https://b.example/sub': _twoNodes,
      });
      expect(await h.run(['sub', 'add', 'https://a.example/sub', '--name', 'A']),
          0);
      expect(await h.run(['sub', 'add', 'https://b.example/sub', '--name', 'B']),
          0);

      expect(await h.run(['groups', 'add', '工作']), 0);
      expect(await h.run(['groups', 'assign', 'A', '工作']), 0);

      h.out.clear();
      expect(await h.run(['groups', 'list', '--json']), 0);
      final listed =
          jsonDecode(h.out.join('\n')) as Map<String, Object?>;
      final groups = listed['groups'] as List;
      expect(groups, hasLength(1));
      expect((groups.single as Map)['subscriptions'], hasLength(1));

      h.read((store) {
        final profiles = SubscriptionRepository(store).allProfiles();
        final a = profiles.firstWhere((p) => p.name == 'A');
        final b = profiles.firstWhere((p) => p.name == 'B');
        expect(a.groupId, isNotNull);
        expect(b.groupId, isNull);
      });

      // Deleting the group ungroups A but keeps both subscriptions.
      h.out.clear();
      expect(await h.run(['groups', 'remove', '工作']), 0);
      h.read((store) {
        final profiles = SubscriptionRepository(store).allProfiles();
        expect(profiles, hasLength(2));
        expect(profiles.every((p) => p.groupId == null), isTrue);
      });
    });

    test('assigning to "none" ungroups', () async {
      h.fetcher = FakeFetcher({'https://a.example/sub': _twoNodes});
      await h.run(['sub', 'add', 'https://a.example/sub', '--name', 'A']);
      await h.run(['groups', 'add', '工作']);
      await h.run(['groups', 'assign', 'A', '工作']);

      expect(await h.run(['groups', 'assign', 'A', 'none']), 0);

      h.read((store) {
        expect(
          SubscriptionRepository(store).allProfiles().single.groupId,
          isNull,
        );
      });
    });

    test('rename keeps the id, and with it every membership', () async {
      h.fetcher = FakeFetcher({'https://a.example/sub': _twoNodes});
      await h.run(['sub', 'add', 'https://a.example/sub', '--name', 'A']);
      await h.run(['groups', 'add', '工作']);
      await h.run(['groups', 'assign', 'A', '工作']);
      final before = h.read(
        (store) => SubscriptionGroupRepository(store).allGroups().single,
      );

      expect(await h.run(['groups', 'rename', '工作', '公司']), 0);

      final after = h.read((store) {
        final group = SubscriptionGroupRepository(store).allGroups().single;
        return (
          group: group,
          profile: SubscriptionRepository(store).allProfiles().firstWhere(
            (p) => p.name == 'A',
          ),
        );
      });
      expect(after.group.name, '公司');
      // The id is what membership points at, so it must survive the rename;
      // delete-and-recreate would silently ungroup every subscription.
      expect(after.group.id, before.id);
      expect(after.profile.groupId, before.id);
    });

    test('rename can address the group by its id, not just its name', () async {
      await h.run(['groups', 'add', '工作']);
      final id = h.read(
        (store) => SubscriptionGroupRepository(store).allGroups().single.id,
      );

      expect(await h.run(['groups', 'rename', id, '公司']), 0);

      expect(
        h.read(
          (store) => SubscriptionGroupRepository(store).allGroups().single.name,
        ),
        '公司',
      );
    });

    test('renaming onto an existing name is refused, both kept', () async {
      await h.run(['groups', 'add', '工作']);
      await h.run(['groups', 'add', '公司']);

      expect(await h.run(['groups', 'rename', '工作', '公司']), 1);

      expect(h.err.join('\n'), contains('已存在同名集合'));
      final names = h.read(
        (store) => SubscriptionGroupRepository(store)
            .allGroups()
            .map((g) => g.name)
            .toList(),
      );
      expect(names, containsAll(['工作', '公司']));
      expect(names, hasLength(2));
    });

    test('renaming to the same name is a no-op that succeeds', () async {
      await h.run(['groups', 'add', '工作']);

      expect(await h.run(['groups', 'rename', '工作', '工作']), 0);
      expect(h.out.join('\n'), contains('未改变'));
    });

    test('an empty new name is a usage error', () async {
      await h.run(['groups', 'add', '工作']);

      expect(await h.run(['groups', 'rename', '工作', '   ']), 2);
    });

    test('a duplicate group name is refused with exit 1', () async {
      await h.run(['groups', 'add', '工作']);

      expect(await h.run(['groups', 'add', '工作']), 1);
      expect(h.err.join('\n'), contains('已存在同名集合'));
    });

    test('an unknown group is a usage error listing what exists', () async {
      await h.run(['groups', 'add', '工作']);

      expect(await h.run(['groups', 'remove', '不存在']), 2);
      expect(h.err.join('\n'), contains('工作'));
    });
  });

  group('proxy', () {
    test('--proxy is passed to the fetcher and stored on the profile', () async {
      h.fetcher = ProxyRecordingFetcher({
        'https://a.example/sub': _twoNodes,
      }, []);

      expect(
        await h.run([
          'sub',
          'add',
          'https://a.example/sub',
          '--proxy',
          '127.0.0.1:7890',
        ]),
        0,
      );

      // Two fetchers are built: one for the command, one for the refresh once
      // the stored switch says "proxy". Neither goes direct.
      expect(h.proxyLog, isNot(contains(null)));
      expect(h.proxyLog.first, '127.0.0.1:7890');
      h.read((store) {
        expect(
          SubscriptionRepository(store).allProfiles().single.useProxy,
          isTrue,
        );
      });
    });

    test('--via-proxy forces the tunnel even when the row prefers direct',
        () async {
      h.fetcher = ProxyRecordingFetcher({
        'https://a.example/sub': _twoNodes,
      }, []);
      await h.run(['sub', 'add', 'https://a.example/sub', '--no-fetch']);
      expect(
        h.read((store) =>
            SubscriptionRepository(store).allProfiles().single.useProxy),
        isFalse,
      );

      h.proxyLog.clear();
      expect(await h.run(['sub', 'update', 'a.example', '--via-proxy']), 0);

      // No endpoint was given, so the conventional local port is used; the point
      // is that the download did not go direct.
      expect(h.proxyLog.last, 'http://127.0.0.1:7890');
    });

    test('a profile with its own switch on is fetched through the proxy',
        () async {
      h.fetcher = ProxyRecordingFetcher({
        'https://a.example/sub': _twoNodes,
      }, []);
      await h.run([
        'sub',
        'add',
        'https://a.example/sub',
        '--proxy',
        '10.0.0.1:8888',
      ]);

      h.proxyLog.clear();
      expect(await h.run(['sub', 'update', 'a.example']), 0);

      expect(h.proxyLog.last, '10.0.0.1:8888');
    });
  });

  test('closed-pipe classification covers Windows and POSIX errors', () {
    expect(
      isClosedPipeError(FileSystemException(
        'writeFrom failed',
        '',
        const OSError('管道正在被关闭。', 232),
      )),
      isTrue,
    );
    expect(
      isClosedPipeError(
        FileSystemException('Broken pipe', '', const OSError('', 32)),
      ),
      isTrue,
    );
    expect(
      isClosedPipeError(
        FileSystemException('disk full', '', const OSError('no space', 112)),
      ),
      isFalse,
    );
    expect(isClosedPipeError(StateError('other')), isFalse);
  });

  test('a closed downstream ends output instead of throwing', () async {
    h.fetcher = FakeFetcher({'https://example.com/sub': _twoNodes});
    expect(await h.run(['sub', 'add', 'https://example.com/sub']), 0);

    var writes = 0;
    final code = await Cli(
      ['sub', 'list', '--dir', h.dir.path],
      out: (line) {
        writes++;
        if (writes > 1) {
          // What Dart raises when `| head` closed the pipe after line one.
          throw FileSystemException(
            'writeFrom failed',
            '',
            const OSError('管道正在被关闭。', 232),
          );
        }
      },
      err: (_) {},
      fetcherFactory: ({required Duration timeout, String? proxyUrl}) =>
          h.fetcher.forProxy(proxyUrl),
      environment: const {},
      resolvedExecutable: 'C:\\nonexistent\\halo-cli.exe',
    ).run();

    expect(code, 0);
    // First line went out, the second was reported closed, the rest were
    // dropped without another attempt.
    expect(writes, 2);
  });
}