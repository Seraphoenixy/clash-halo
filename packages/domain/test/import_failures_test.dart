import 'package:halo_domain/halo_domain.dart';
import 'package:test/test.dart';

/// What a refresh reports when it refuses entries.
///
/// Two properties are pinned here, both of which the app got wrong at once:
/// a link copied out of a web page (`&amp;`) used to fail with a message about
/// a missing key, and the window reported the rejection count as "不支持" with
/// nothing that identified the entry. A user looking at "1462 条不支持" had no
/// way to learn that 1300 of those were damaged lines.
void main() {
  group('HTML-escaped share links', () {
    // The shape that exposed this: a REALITY link published with `&amp;`
    // separators. Read literally, every parameter after `security` becomes
    // part of its neighbour's name, so `pbk` is never seen and the parser
    // blames the link for missing a public key.
    const escaped =
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?security=reality&amp;encryption=none&amp;pbk=PUBKEY'
        '&amp;sid=abcd&amp;sni=edge.example.com&amp;fp=chrome'
        '&amp;type=tcp&amp;flow=xtls-rprx-vision#%E9%A6%99%E6%B8%AF';

    test('decodes &amp; so REALITY parameters are read', () {
      final parsed = parseShareLink(escaped);
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      final node = parsed.node!;
      expect(node.protocol, ProxyProtocol.vless);
      expect(node.tls.kind, TlsKind.reality);
      expect(node.tls.realityPublicKey, 'PUBKEY');
      expect(node.tls.realityShortId, 'abcd');
      expect(node.tls.serverName, 'edge.example.com');
      expect(node.secrets.flow, 'xtls-rprx-vision');
    });

    test('leaves a display name that contains &amp; alone', () {
      // The fragment is the node's name. Unescaping there would quietly rename
      // a node the user can see, which is worse than an odd-looking name.
      const link = 'trojan://secret@example.com:443#A&amp;B';
      final parsed = parseShareLink(link);
      expect(parsed.issue, isNull, reason: parsed.issue?.message);
      expect(parsed.node!.name, 'A&amp;B');
    });

    test('decodes the numeric forms as well', () {
      for (final entity in ['&#38;', '&#x26;', '&#X26;']) {
        final parsed = parseShareLink(
          'vless://11111111-2222-3333-4444-555555555555@example.com:443'
          '?security=reality${entity}pbk=PUBKEY${entity}sni=edge.example.com',
        );
        expect(parsed.issue, isNull, reason: '$entity: ${parsed.issue?.message}');
        expect(parsed.node!.tls.realityPublicKey, 'PUBKEY', reason: entity);
      }
    });

    test('only rewrites the part before the fragment', () {
      expect(
        unescapeHtmlAmp('http://a/b?x=1&amp;y=2#n&amp;m'),
        'http://a/b?x=1&y=2#n&amp;m',
      );
    });
  });

  group('a rejected entry keeps its raw text', () {
    test('share links report the line that was refused', () {
      // No scheme at all: the one shape the lenient parser still refuses.
      const broken = 'just some text';
      final result = parseShareLinks(['', broken]);
      expect(result.importedCount, 0);
      final issue = result.failed.single;
      expect(issue.kind, ImportFailureKind.malformedLink);
      expect(issue.raw, broken);
      expect(issue.line, 2);
    });

    test('Clash entries report the mapping they came from', () {
      final result = parseClashYaml('''
proxies:
  - name: wg
    type: wireguard
    server: wg.example.com
    port: 51820
''');
      final issue = result.failed.single;
      expect(issue.kind, ImportFailureKind.unsupportedProtocol);
      expect(issue.raw, contains('wireguard'));
      expect(issue.raw, contains('wg.example.com'));
    });

    test('sing-box outbounds report the object they came from', () {
      final result = parseSingboxJson(
        '{"outbounds":[{"type":"wireguard","tag":"wg","server":"wg.example.com",'
        '"server_port":51820}]}',
      );
      final issue = result.failed.single;
      expect(issue.kind, ImportFailureKind.unsupportedProtocol);
      expect(issue.raw, contains('"tag":"wg"'));
    });

    test('v2rayN rows report the row they came from', () {
      final result = parseV2rayNProfiles(
        '[{"ConfigType":1,"Remarks":"no address","Address":"","Port":443}]',
      );
      final issue = result.failed.single;
      expect(issue.kind, ImportFailureKind.missingRequired);
      expect(issue.raw, contains('no address'));
    });

    test('raw text is clipped to one line', () {
      expect(clipImportEntry('  a\n\tb   c  '), 'a b c');
      final long = clipImportEntry('x' * 500);
      expect(long.length, importRawLimit + 1);
      expect(long.endsWith('…'), isTrue);
      expect(clipImportEntry(null), '');
    });
  });

  group('failure breakdown', () {
    ImportResult resultWith(List<ImportIssue> issues) => ImportResult(
      nodes: const [],
      failed: issues,
      sourceFormat: 'share_links',
    );

    test('counts by kind', () {
      final result = resultWith([
        const ImportIssue(
          kind: ImportFailureKind.malformedLink,
          message: 'x',
        ),
        const ImportIssue(
          kind: ImportFailureKind.malformedLink,
          message: 'x',
        ),
        const ImportIssue(
          kind: ImportFailureKind.unsupportedProtocol,
          message: 'y',
        ),
      ]);
      expect(result.failureKinds, {
        'malformed_link': 2,
        'unsupported_protocol': 1,
      });
    });

    test('skips are counted apart from failures', () {
      const result = ImportResult(
        failed: [ImportIssue(kind: ImportFailureKind.malformedLink, message: 'x')],
        skipped: [
          ImportIssue(kind: ImportFailureKind.duplicate, message: '重复节点已跳过'),
          ImportIssue(kind: ImportFailureKind.duplicate, message: '重复节点已跳过'),
        ],
        sourceFormat: 'share_links',
      );
      expect(result.failureKinds, {'malformed_link': 1});
      // A duplicate is not a refusal: counting it as one is what made a list
      // with 1580 repeats look like 1461 lost nodes.
      expect(result.skippedKinds, {'duplicate': 2});
      expect(result.duplicateCount, 2);
    });

    test('renders the biggest cause first, with its own wording', () {
      expect(
        describeImportFailures({
          'unsupported_protocol': 51,
          'malformed_link': 1300,
          'missing_required': 574,
        }),
        '格式损坏 1300、缺少字段 574、协议不支持 51',
      );
    });

    test('folds kinds past the requested limit', () {
      final text = describeImportFailures({
        'malformed_link': 5,
        'missing_required': 4,
        'unsupported_protocol': 3,
        'unsupported_parameter': 2,
        'decode_error': 1,
      });
      expect(text, '格式损坏 5、缺少字段 4、协议不支持 3、传输不支持 2、等 5 类');
    });

    test('empty input renders nothing rather than a dangling separator', () {
      expect(describeImportFailures({}), '');
      expect(describeImportFailures({'malformed_link': 0}), '');
    });

    test('unknown kinds fall back to their wire name', () {
      expect(importFailureLabel('something_new'), 'something_new');
      expect(describeImportFailures({'something_new': 2}), 'something_new 2');
    });
  });
}
