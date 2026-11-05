// Port of eino `components/document/parser/parser_test.go` (TestParser) and
// `option_test.go` (TestImplSpecificOpts), and tests for TextParser and
// ExtParser beyond them.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/src/internal/parser_utils.dart';
import 'package:threepio_core/threepio_core.dart';

/// `ParserForTest` of the Go test.
final class _ParserForTest implements Parser {
  _ParserForTest(this.mock);

  final Future<List<Document>> Function() mock;
  final List<ParserOptions?> seenOptions = [];
  final List<RunContext> seenContexts = [];

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    seenContexts.add(ctx);
    seenOptions.add(options);
    await bytes.drain<void>();
    return mock();
  }
}

/// `implSpecificOptions` of the Go option test.
final class _ImplSpecificOptions {
  const _ImplSpecificOptions({this.conf = '', this.index = 0});

  final String conf;
  final int index;
}

Stream<List<int>> _bytes(String text) => Stream.value(utf8.encode(text));

void main() {
  final ctx = RunContext.background();
  final fixture = File('test/components/document/testdata/test.md');

  group('TestParser', () {
    test('Test default parser', () async {
      final parser = ExtParser();

      final docs = await parser.parse(
        ctx,
        fixture.openRead(),
        options: const ParserOptions(uri: 'testdata/test.md'),
      );

      expect(docs, hasLength(1));
      expect(docs[0].content, '# Title\nhello world');
    });

    test('test types', () async {
      final mockParser = _ParserForTest(
        () async => [
          const Document(content: 'hello world', metadata: {'type': 'text'}),
        ],
      );
      final parser = ExtParser(parsers: {'.md': mockParser});

      final docs = await parser.parse(
        ctx,
        fixture.openRead(),
        options: const ParserOptions(uri: 'x/test.md'),
      );

      expect(docs, hasLength(1));
      expect(docs[0].content, 'hello world');
      expect(docs[0].metadata['type'], 'text');
    });

    test('test get parsers', () {
      final parser = ExtParser(parsers: {'.md': const TextParser()});

      expect(parser.parsers, hasLength(1));
      expect(parser.parsers['.md'], isA<TextParser>());
    });
  });

  group('TestImplSpecificOpts', () {
    test('a parser reads its own options from the extensions', () {
      const options = ParserOptions(
        extensions: [_ImplSpecificOptions(conf: 'test_conf', index: 1)],
      );

      final own = options.extension<_ImplSpecificOptions>();
      expect(own?.conf, 'test_conf');
      expect(own?.index, 1);
    });

    test('an option that is not there is null, so the parser uses its default',
        () {
      const options = ParserOptions(uri: 'a.txt', extensions: ['other']);

      final own = options.extension<_ImplSpecificOptions>() ??
          const _ImplSpecificOptions();
      expect(own.conf, '');
      expect(own.index, 0);
    });
  });

  group('ParserOptions', () {
    test('has no values by default', () {
      const options = ParserOptions();
      expect(options.uri, isNull);
      expect(options.extraMeta, isNull);
      expect(options.extensions, isEmpty);
    });

    test('copyWith replaces fields', () {
      const options = ParserOptions(uri: 'a.md', extraMeta: {'k': 1});

      final copy = options.copyWith(uri: 'b.md');
      expect(copy.uri, 'b.md');
      expect(copy.extraMeta, {'k': 1});
    });

    test('merge prefers what the other options set', () {
      const base = ParserOptions(
        uri: 'a.md',
        extraMeta: {'k': 1},
        extensions: [_ImplSpecificOptions(conf: 'base')],
      );

      final merged = base.merge(
        const ParserOptions(
          uri: 'b.md',
          extensions: [_ImplSpecificOptions(conf: 'call')],
        ),
      );

      expect(merged.uri, 'b.md');
      expect(merged.extraMeta, {'k': 1});
      expect(merged.extension<_ImplSpecificOptions>()?.conf, 'call');
      expect(base.merge(null), same(base));
    });
  });

  group('TextParser', () {
    test('returns the bytes as one document', () async {
      final docs = await const TextParser().parse(ctx, _bytes('plain text'));

      expect(docs, hasLength(1));
      expect(docs.single.content, 'plain text');
      expect(docs.single.id, isNull);
    });

    test('records the source under metaKeySource', () async {
      final docs = await const TextParser().parse(
        ctx,
        _bytes('text'),
        options: const ParserOptions(uri: 'notes/a.txt'),
      );

      expect(metaKeySource, '_source');
      expect(docs.single.metadata, {metaKeySource: 'notes/a.txt'});
    });

    test('without a URI the source is empty, as in Eino', () async {
      final docs = await const TextParser().parse(ctx, _bytes('text'));
      expect(docs.single.metadata, {metaKeySource: ''});
    });

    test('adds the extra metadata, which can replace the source', () async {
      final docs = await const TextParser().parse(
        ctx,
        _bytes('text'),
        options: const ParserOptions(
          uri: 'a.txt',
          extraMeta: {'lang': 'en', 'page': 3},
        ),
      );
      expect(docs.single.metadata, {
        metaKeySource: 'a.txt',
        'lang': 'en',
        'page': 3,
      });

      final replaced = await const TextParser().parse(
        ctx,
        _bytes('text'),
        options: const ParserOptions(
          uri: 'a.txt',
          extraMeta: {metaKeySource: 'elsewhere'},
        ),
      );
      expect(replaced.single.metadata[metaKeySource], 'elsewhere');
    });

    test('joins the chunks of the byte stream', () async {
      // "héllo wörld" with the two-byte characters split across chunks.
      final all = utf8.encode('héllo wörld');
      final docs = await const TextParser().parse(
        ctx,
        Stream.fromIterable([all.sublist(0, 2), all.sublist(2, 9), all.sublist(9)]),
      );

      expect(docs.single.content, 'héllo wörld');
    });

    test('an empty stream is an empty document', () async {
      final docs =
          await const TextParser().parse(ctx, const Stream<List<int>>.empty());
      expect(docs.single.content, '');
    });

    test('bytes that are not UTF-8 are replaced, not rejected', () async {
      final docs = await const TextParser().parse(
        ctx,
        Stream.value([0x61, 0xFF, 0x62]),
      );
      expect(docs.single.content, 'a\u{FFFD}b');
    });

    test('an error of the byte stream fails the call', () async {
      await expectLater(
        const TextParser().parse(
          ctx,
          Stream<List<int>>.error(const FileSystemException('gone')),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('names its type', () {
      expect(const TextParser().componentTypeName, 'Text');
    });
  });

  group('ExtParser', () {
    test('uses the parser registered for the extension of the URI', () async {
      final markdown = _ParserForTest(() async => [Document.simple('md')]);
      final html = _ParserForTest(() async => [Document.simple('html')]);
      final parser = ExtParser(parsers: {'.md': markdown, '.html': html});

      Future<String> parse(String uri) async => (await parser.parse(
            ctx,
            _bytes('raw'),
            options: ParserOptions(uri: uri),
          ))
              .single
              .content;

      expect(await parse('docs/readme.md'), 'md');
      expect(await parse('https://example.com/page.html'), 'html');
      expect(await parse('archive.tar.html'), 'html');
      // No parser for the extension: the fallback, a TextParser.
      expect(await parse('notes.txt'), 'raw');
      expect(await parse('README'), 'raw');
    });

    test('the extension has to match exactly', () async {
      final markdown = _ParserForTest(() async => [Document.simple('md')]);
      final parser = ExtParser(parsers: {'.md': markdown});

      final docs = await parser.parse(
        ctx,
        _bytes('raw'),
        options: const ParserOptions(uri: 'README.MD'),
      );

      expect(docs.single.content, 'raw');
      expect(markdown.seenOptions, isEmpty);
    });

    test('without options or URI it falls back', () async {
      final markdown = _ParserForTest(() async => [Document.simple('md')]);
      final parser = ExtParser(parsers: {'.md': markdown});

      expect((await parser.parse(ctx, _bytes('raw'))).single.content, 'raw');
      expect(
        (await parser.parse(ctx, _bytes('raw'), options: const ParserOptions()))
            .single
            .content,
        'raw',
      );
    });

    test('a fallback parser can be given', () async {
      final fallback = _ParserForTest(() async => [Document.simple('fallback')]);
      final parser = ExtParser(fallbackParser: fallback);

      final docs = await parser.parse(
        ctx,
        _bytes('raw'),
        options: const ParserOptions(uri: 'a.bin'),
      );

      expect(docs.single.content, 'fallback');
      expect(parser.fallbackParser, same(fallback));
      expect(ExtParser().fallbackParser, isA<TextParser>());
    });

    test('hands context and options on to the chosen parser', () async {
      final markdown = _ParserForTest(() async => [Document.simple('md')]);
      final parser = ExtParser(parsers: {'.md': markdown});
      const options = ParserOptions(uri: 'a.md', extraMeta: {'k': 'v'});

      await parser.parse(ctx, _bytes('raw'), options: options);

      expect(markdown.seenContexts.single, same(ctx));
      expect(markdown.seenOptions.single, same(options));
    });

    test('adds the extra metadata to what the parser returned', () async {
      final mock = _ParserForTest(
        () async => const [
          Document(content: 'one', metadata: {'type': 'text', 'k': 'old'}),
          Document(content: 'two'),
        ],
      );
      final parser = ExtParser(parsers: {'.md': mock});

      final docs = await parser.parse(
        ctx,
        _bytes('raw'),
        options: const ParserOptions(uri: 'a.md', extraMeta: {'k': 'new', 'n': 1}),
      );

      expect(docs[0].metadata, {'type': 'text', 'k': 'new', 'n': 1});
      expect(docs[1].metadata, {'k': 'new', 'n': 1});
    });

    test('an error of the chosen parser fails the call', () async {
      final failing =
          _ParserForTest(() async => throw const FormatException('broken'));
      final parser = ExtParser(parsers: {'.md': failing});

      await expectLater(
        parser.parse(ctx, _bytes('raw'), options: const ParserOptions(uri: 'a.md')),
        throwsFormatException,
      );
    });

    test('the map of parsers cannot be changed from outside', () {
      final given = <String, Parser>{'.md': const TextParser()};
      final parser = ExtParser(parsers: given);

      given['.txt'] = const TextParser();
      expect(parser.parsers.keys, ['.md']);
      expect(
        () => parser.parsers['.txt'] = const TextParser(),
        throwsUnsupportedError,
      );
    });

    test('names its type', () {
      expect(ExtParser().componentTypeName, 'Ext');
    });
  });

  group('fileExtensionOf (Go filepath.Ext)', () {
    test('is the last dot of the last path segment and what follows', () {
      expect(fileExtensionOf('a.md'), '.md');
      expect(fileExtensionOf('dir/a.tar.gz'), '.gz');
      expect(fileExtensionOf('testdata/test.md'), '.md');
      expect(fileExtensionOf(r'C:\docs\a.txt'), '.txt');
      expect(fileExtensionOf('.bashrc'), '.bashrc');
      expect(fileExtensionOf('a.'), '.');
    });

    test('is empty when the last segment has no dot', () {
      expect(fileExtensionOf(''), '');
      expect(fileExtensionOf('README'), '');
      expect(fileExtensionOf('dir.d/README'), '');
      expect(fileExtensionOf('dir.d/'), '');
    });
  });

  group('readAllBytes', () {
    test('collects every chunk in order', () async {
      final bytes = await readAllBytes(
        Stream.fromIterable([
          [1, 2],
          <int>[],
          [3],
        ]),
      );
      expect(bytes, [1, 2, 3]);
      expect(await readAllBytes(const Stream.empty()), isEmpty);
    });
  });
}
