// Port of eino-ext `components/document/loader/file/file_loader_test.go`
// (TestFileLoader_Load), and tests written for the port: the file name as
// id with one and several documents, the metadata, the parser options of
// the call merged on top, the default ExtParser/TextParser, Go's error
// texts (from `file_loader.go`; the texts of the operating system as Go's
// `os` package writes them), a failing parser, cancellations and
// interrupts, and the loader callbacks. Temporary files only, plus the Go
// fixture `testdata/test.md`.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/loader/file_loader.dart';
import 'package:threepio_core/src/components/document/parser/eino_html_parser.dart';
import 'package:threepio_core/threepio_core.dart';

const _fixture = 'test/components/document/testdata/eino_ext/loader/file/test.md';

/// Returns [docs] for every call, or throws [error]; records what it gets.
final class _FakeParser implements Parser {
  _FakeParser({this.docs = const [Document(content: 'parsed')], this.error});

  final List<Document> docs;
  final Object? error;
  final List<RunContext> contexts = [];
  final List<ParserOptions?> options = [];
  final List<List<int>> bytes = [];

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    contexts.add(ctx);
    this.options.add(options);
    this.bytes.add([await for (final chunk in bytes) ...chunk]);
    final error = this.error;
    if (error != null) throw error;
    return docs;
  }
}

final class _Interrupt implements InterruptSignal {
  const _Interrupt();
}

/// A handler that records its callbacks as text, and the payloads.
final class _Recorder {
  final List<String> events = [];
  final List<Object?> payloads = [];

  late final ComponentCallbackHandler handler = CallbackHandlerBuilder()
      .onStart((ctx, info, input) {
        events.add('start ${info.componentType.name} ${info.type} "${info.name}"');
        payloads.add(input);
        return ctx;
      })
      .onEnd((ctx, info, output) {
        events.add('end ${info.componentType.name} ${info.type} "${info.name}"');
        payloads.add(output);
        return ctx;
      })
      .onError((ctx, info, error, stackTrace) {
        events.add('error ${info.type} $error');
        return ctx;
      })
      .build();
}

Matcher _failsWith(String message) => throwsA(
      isA<ThreepioException>().having((e) => e.message, 'message', message),
    );

void main() {
  final ctx = RunContext.background();
  late Directory temp;

  setUp(() {
    GlobalCallbacks.clear();
    temp = Directory.systemTemp.createTempSync('threepio_p12_');
  });

  tearDown(() {
    GlobalCallbacks.clear();
    temp.deleteSync(recursive: true);
  });

  String write(String name, String content) {
    final file = File(p.join(temp.path, name))..writeAsStringSync(content);
    return file.path;
  }

  group('TestFileLoader_Load', () {
    test('TestFileLoader_Load', () async {
      final loader = FileLoader(const FileLoaderConfig(useNameAsId: true));

      final docs = await loader.load(ctx, const DocumentSource(uri: _fixture));

      expect(docs, hasLength(1));
      expect(docs[0].id, 'test.md');
      expect(docs[0].content, '# Title\n\n- Bullet 1\n- Bullet 2');
      expect(docs[0].metadata, hasLength(3));
      expect(docs[0].metadata[fileLoaderMetaKeyFileName], 'test.md');
      expect(docs[0].metadata[fileLoaderMetaKeyExtension], '.md');
      expect(docs[0].metadata[metaKeySource], _fixture);
    });
  });

  group('useNameAsId', () {
    test('several documents are <name>_<index>', () async {
      final path = write('table.csv', 'a\nb');
      final loader = FileLoader(
        FileLoaderConfig(
          useNameAsId: true,
          parser: _FakeParser(
            docs: const [
              Document(id: 'x', content: 'a'),
              Document(content: 'b'),
              Document(content: 'c'),
            ],
          ),
        ),
      );

      final docs = await loader.load(ctx, DocumentSource(uri: path));

      expect(docs.map((d) => d.id), ['table.csv_0', 'table.csv_1', 'table.csv_2']);
      expect(docs.map((d) => d.content), ['a', 'b', 'c']);
    });

    test('no document stays no document; off keeps the ids', () async {
      final path = write('empty.txt', '');
      final none = FileLoader(
        FileLoaderConfig(useNameAsId: true, parser: _FakeParser(docs: const [])),
      );
      final off = FileLoader(
        FileLoaderConfig(parser: _FakeParser(docs: const [Document(id: 'mine', content: '')])),
      );

      expect(await none.load(ctx, DocumentSource(uri: path)), isEmpty);
      expect((await off.load(ctx, DocumentSource(uri: path))).single.id, 'mine');
      expect(
        (await FileLoader().load(ctx, DocumentSource(uri: path))).single.id,
        isNull,
      );
    });
  });

  group('the parser', () {
    test('gets the bytes, the path as URI and the file metadata', () async {
      final path = write('README', 'hello');
      final parser = _FakeParser();

      await FileLoader(FileLoaderConfig(parser: parser))
          .load(ctx, DocumentSource(uri: path));

      expect(String.fromCharCodes(parser.bytes.single), 'hello');
      final options = parser.options.single!;
      expect(options.uri, path);
      expect(options.extraMeta, {
        fileLoaderMetaKeyExtension: '',
        fileLoaderMetaKeyFileName: 'README',
        metaKeySource: path,
      });
    });

    test('the parser options of the call are applied on top', () async {
      final path = write('notes.md', 'x');
      final parser = _FakeParser();
      final loader = FileLoader(FileLoaderConfig(parser: parser));
      const marker = Object();

      await loader.load(
        ctx,
        DocumentSource(uri: path),
        options: const LoaderOptions(
          parserOptions: ParserOptions(extraMeta: {'k': 'v'}, extensions: [marker]),
        ),
      );
      await loader.load(
        ctx,
        DocumentSource(uri: path),
        options: const LoaderOptions(parserOptions: ParserOptions(uri: 'other.html')),
      );

      // As Go's WithExtraMeta, the call's extra metadata replaces the
      // loader's; the URI stays the path unless the call sets one.
      expect(parser.options[0]!.uri, path);
      expect(parser.options[0]!.extraMeta, {'k': 'v'});
      expect(parser.options[0]!.extension<Object>(), same(marker));
      expect(parser.options[1]!.uri, 'other.html');
      expect(parser.options[1]!.extraMeta, hasLength(3));
    });

    test('defaults to an ExtParser that falls back to the TextParser',
        () async {
      final loader = FileLoader();
      expect(loader.parser, isA<ExtParser>());
      final ext = loader.parser as ExtParser;
      expect(ext.parsers, isEmpty);
      expect(ext.fallbackParser, isA<TextParser>());

      final path = write('page.html', '<p>raw</p>');
      final docs = await loader.load(ctx, DocumentSource(uri: path));
      expect(docs.single.content, '<p>raw</p>');
      expect(docs.single.metadata, {
        metaKeySource: path,
        fileLoaderMetaKeyExtension: '.html',
        fileLoaderMetaKeyFileName: 'page.html',
      });
    });

    test('an ExtParser picks the parser by the extension of the path',
        () async {
      final path = write(
        'page.html',
        '<html><head><title>T</title></head><body>Body &amp; soul</body></html>',
      );
      final loader = FileLoader(
        FileLoaderConfig(
          parser: ExtParser(parsers: {'.html': HtmlParser.fromConfig()}),
        ),
      );

      final docs = await loader.load(ctx, DocumentSource(uri: path));

      expect(docs.single.content, 'TBody &amp; soul');
      expect(docs.single.metadata, {
        htmlMetaKeyTitle: 'T',
        metaKeySource: path,
        fileLoaderMetaKeyExtension: '.html',
        fileLoaderMetaKeyFileName: 'page.html',
      });
    });
  });

  group('errors, with Go\'s texts', () {
    test('an empty path', () async {
      await expectLater(
        FileLoader().load(ctx, const DocumentSource(uri: '')),
        _failsWith('read single file from path, path is empty'),
      );
    });

    test('a path that does not exist', () async {
      final path = p.join(temp.path, 'missing.md');
      await expectLater(
        FileLoader().load(ctx, DocumentSource(uri: path)),
        _failsWith(
          'read single file from path, error while checking file stat: '
          'stat $path: no such file or directory, path= $path',
        ),
      );
    });

    test('a directory', () async {
      await expectLater(
        FileLoader().load(ctx, DocumentSource(uri: temp.path)),
        _failsWith(
          'read single file from path can only accept non-dir path, '
          'actual= ${temp.path}',
        ),
      );
    });

    test('a file that cannot be opened', () async {
      final path = write('secret.txt', 'x');
      final chmod = Process.runSync('chmod', ['000', path]);
      expect(chmod.exitCode, 0);
      try {
        File(path).openSync().closeSync();
        markTestSkipped('the file can still be opened (running as root?)');
        return;
      } on FileSystemException {
        // As expected.
      }

      await expectLater(
        FileLoader().load(ctx, DocumentSource(uri: path)),
        throwsA(
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                'flat loader open file path failed with err: '
                    'open $path: permission denied, path= $path',
              )
              .having((e) => e.cause, 'cause', isA<FileSystemException>()),
        ),
      );
    });

    test('a failing parser', () async {
      final path = write('a.txt', 'x');
      const error = ThreepioException('broken');

      await expectLater(
        FileLoader(FileLoaderConfig(parser: _FakeParser(error: error)))
            .load(ctx, DocumentSource(uri: path)),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'file parse err of [$path]: broken')
              .having((e) => e.cause, 'cause', same(error)),
        ),
      );
    });

    test('a cancellation or an interrupt of the parser gets through',
        () async {
      final path = write('a.txt', 'x');

      await expectLater(
        FileLoader(FileLoaderConfig(parser: _FakeParser(error: const CancelledException('stop'))))
            .load(ctx, DocumentSource(uri: path)),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        FileLoader(FileLoaderConfig(parser: _FakeParser(error: const _Interrupt())))
            .load(ctx, DocumentSource(uri: path)),
        throwsA(isA<_Interrupt>()),
      );
    });

    test('a cancelled context stops the load before the file is read',
        () async {
      final path = write('a.txt', 'x');
      final parser = _FakeParser();
      final token = CancelToken()..cancel('stop');

      await expectLater(
        FileLoader(FileLoaderConfig(parser: parser))
            .load(RunContext.background(cancelToken: token), DocumentSource(uri: path)),
        throwsA(isA<CancelledException>()),
      );
      expect(parser.contexts, isEmpty);
    });
  });

  group('callbacks', () {
    test('is typed FileLoader and fires its own callbacks', () {
      final loader = FileLoader();
      expect(loader.componentTypeName, 'FileLoader');
      expect(componentTypeNameOf(loader), 'FileLoader');
      expect(isCallbacksEnabled(loader), isTrue);
    });

    test('start with the source, end with the source and the documents',
        () async {
      final path = write('a.md', 'x');
      final recorder = _Recorder();
      final parser = _FakeParser();
      final source = DocumentSource(uri: path);

      final docs = await FileLoader(FileLoaderConfig(parser: parser))
          .load(ctx.withHandlers([recorder.handler]), source);

      expect(recorder.events, [
        'start loader FileLoader ""',
        'end loader FileLoader ""',
      ]);
      final input = recorder.payloads[0]! as LoaderCallbackInput;
      expect(input.source, source);
      final output = recorder.payloads[1]! as LoaderCallbackOutput;
      expect(output.source, source);
      expect(output.docs, docs);
      // The parser runs in the context the start callback returned.
      expect(parser.contexts.single.hasCallbacks, isTrue);
    });

    test('a failure is reported to the error callback and rethrown',
        () async {
      final recorder = _Recorder();

      await expectLater(
        FileLoader().load(
          ctx.withHandlers([recorder.handler]),
          const DocumentSource(uri: ''),
        ),
        throwsA(isA<ThreepioException>()),
      );
      expect(recorder.events, [
        'start loader FileLoader ""',
        'error FileLoader ThreepioException: read single file from path, '
            'path is empty',
      ]);
    });

    test('global handlers hear the loader too', () async {
      final path = write('a.md', 'x');
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder.handler]);

      await FileLoader().load(ctx, DocumentSource(uri: path));

      expect(recorder.events, [
        'start loader FileLoader ""',
        'end loader FileLoader ""',
      ]);
    });

    test('without any handler the parser gets the caller\'s context',
        () async {
      final path = write('a.md', 'x');
      final parser = _FakeParser();

      await FileLoader(FileLoaderConfig(parser: parser))
          .load(ctx, DocumentSource(uri: path));

      expect(parser.contexts.single, same(ctx));
    });
  });
}
