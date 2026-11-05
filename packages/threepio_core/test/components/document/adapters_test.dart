// The bridges between the Eino-shaped contracts (DocumentTransformer, Parser,
// Loader) and the components threepio already had (TextSplitter,
// DocumentParser, DocumentLoader, Reranker).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// A loader of the older kind: bound to one source when it is created.
final class _BoundLoader extends DocumentLoader {
  _BoundLoader(this.uri, {this.withSource = false});

  final String uri;
  final bool withSource;
  final List<DocumentLoaderOptions?> seenOptions = [];

  @override
  Future<List<Document>> load({DocumentLoaderOptions? options}) async {
    seenOptions.add(options);
    return [
      Document(
        content: 'content of $uri',
        metadata: {'loader': 'bound', ...?options?.metadata},
        source: withSource ? DocumentSource(uri: 'bound://$uri') : null,
      ),
    ];
  }

  @override
  Stream<Document> loadLazy({DocumentLoaderOptions? options}) async* {
    yield* Stream.fromIterable(await load(options: options));
  }
}

/// A transformer written against the contract: it has to declare `options`.
final class _UpperCase extends DocumentTransformer {
  const _UpperCase();

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async =>
      [for (final doc in documents) doc.copyWith(content: doc.content.toUpperCase())];
}

/// Ranks by how often the query occurs in the document.
final class _CountingReranker implements Reranker {
  final List<(String, RerankerOptions?)> calls = [];

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    calls.add((query, options));
    final results = [
      for (final (index, doc) in documents.indexed)
        RerankResult(
          document: doc,
          score: query.allMatches(doc.content).length.toDouble(),
          originalIndex: index,
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final topK = options?.topK;
    return topK == null ? results : results.take(topK).toList();
  }
}

Stream<List<int>> _bytes(String text) => Stream.value(utf8.encode(text));

void main() {
  final ctx = RunContext.background();

  group('TextSplitter as DocumentTransformer', () {
    final text = List.generate(40, (i) => 'word$i').join(' ');
    final documents = [
      Document(id: 'doc-1', content: text, metadata: const {'lang': 'en'}),
    ];

    test('every splitter is a transformer', () {
      expect(RecursiveCharacterTextSplitter(), isA<DocumentTransformer>());
      expect(CharacterTextSplitter(), isA<DocumentTransformer>());
      expect(MarkdownSplitter(), isA<DocumentTransformer>());
      expect(HtmlSplitter(), isA<DocumentTransformer>());
    });

    test('transform() is splitDocuments() with the default options', () async {
      final splitter = RecursiveCharacterTextSplitter();

      final viaTransform = await splitter.transform(documents);
      final viaSplit = await splitter.splitDocuments(documents);

      expect(viaTransform, viaSplit);
      // 276 characters fit into one chunk of the default size.
      expect(viaTransform, hasLength(1));
    });

    test('the splitter options of a call travel as an extension', () async {
      final splitter = RecursiveCharacterTextSplitter();
      const splitterOptions = TextSplitterOptions(chunkSize: 60, chunkOverlap: 10);

      final viaTransform = await splitter.transform(
        documents,
        options: const TransformerOptions(extensions: [splitterOptions]),
      );
      final viaSplit =
          await splitter.splitDocuments(documents, options: splitterOptions);

      expect(viaTransform, viaSplit);
      expect(viaTransform.length, greaterThan(3));
      expect(viaTransform.every((chunk) => chunk.content.length <= 60), isTrue);
      expect(viaTransform.first.metadata['parent_id'], 'doc-1');
      expect(viaTransform.first.metadata['lang'], 'en');
      expect(viaTransform.first.metadata['chunk_index'], 0);
    });

    test('withOptions() fixes the options for callers that only know '
        'transform()', () async {
      const splitterOptions = TextSplitterOptions(chunkSize: 60, chunkOverlap: 10);
      final splitter = RecursiveCharacterTextSplitter();
      final DocumentTransformer chunker = splitter.withOptions(splitterOptions);

      expect(
        await chunker.transform(documents),
        await splitter.splitDocuments(documents, options: splitterOptions),
      );
    });

    test('options of the call take precedence over the fixed ones', () async {
      final splitter = RecursiveCharacterTextSplitter();
      final chunker = splitter.withOptions(
        const TextSplitterOptions(chunkSize: 60, chunkOverlap: 10),
      );
      const perCall = TextSplitterOptions(chunkSize: 120, chunkOverlap: 0);

      expect(
        await chunker.transform(
          documents,
          options: const TransformerOptions(extensions: [perCall]),
        ),
        await splitter.splitDocuments(documents, options: perCall),
      );
    });

    test('invalid options are reported as by the splitter itself', () async {
      await expectLater(
        RecursiveCharacterTextSplitter().transform(
          documents,
          options: const TransformerOptions(
            extensions: [TextSplitterOptions(chunkSize: 10, chunkOverlap: 10)],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a splitter can be a transformer of the ingestion pipeline', () async {
      final pipeline = IngestionPipeline(
        transformers: [
          ContentCleanerTransformer(),
          RecursiveCharacterTextSplitter().withOptions(
            const TextSplitterOptions(chunkSize: 60, chunkOverlap: 0),
          ),
          MetadataTransformer(metadata: const {'stage': 'chunked'}),
        ],
      );

      final result = await pipeline.ingest(documents: documents);

      expect(result.errors, isEmpty);
      expect(result.documentsProcessed, 1);
      expect(result.chunksCreated, greaterThan(3));
    });
  });

  group('DocumentTransformer', () {
    final documents = [Document.simple('  Hello  '), Document.simple('skip me')];

    test('the transformers of the pipeline accept options', () async {
      final options = TransformerOptions(runContext: ctx);

      final withMeta = await MetadataTransformer(metadata: const {'k': 'v'})
          .transform(documents, options: options);
      expect(withMeta.every((doc) => doc.metadata['k'] == 'v'), isTrue);

      final filtered = await FilterTransformer(
        predicate: (doc) => !doc.content.startsWith('skip'),
      ).transform(documents, options: options);
      expect(filtered.single.content, '  Hello  ');

      final cleaned =
          await ContentCleanerTransformer().transform(documents, options: options);
      expect(cleaned.first.content, 'Hello');
    });

    test('and still work without', () async {
      expect(
        await MetadataTransformer(metadata: const {'k': 'v'}).transform(documents),
        hasLength(2),
      );
    });

    test('can be extended and implemented', () async {
      const DocumentTransformer upper = _UpperCase();
      expect(
        (await upper.transform(documents)).map((doc) => doc.content),
        ['  HELLO  ', 'SKIP ME'],
      );
    });

    test('is the same type whether imported from the pipeline or not', () {
      // `ingestion_pipeline.dart` used to declare the class and still
      // provides it.
      const Object transformer = _UpperCase();
      expect(transformer, isA<DocumentTransformer>());
      expect(MetadataTransformer(metadata: const {}), isA<DocumentTransformer>());
    });
  });

  group('existing parsers through Parser', () {
    const html = '<html><head><title>Greeting</title></head>'
        '<body><h1>Hello</h1><p>World of <b>parsers</b>.</p>'
        '<script>ignored()</script></body></html>';

    test('HtmlParser.asParser() parses a stream of bytes', () async {
      final legacy = HtmlParser();
      final Parser parser = legacy.asParser();

      final docs = await parser.parse(ctx, _bytes(html));
      final direct = await legacy.parseString(html);

      expect(parser, isA<DocumentParserAdapter>());
      expect(docs, hasLength(1));
      expect(docs.single.content, direct.document.content);
      expect(docs.single.content, contains('Hello'));
      expect(docs.single.content, contains('World of'));
      expect(docs.single.content, isNot(contains('ignored')));
      expect(docs.single.metadata, direct.document.metadata);
    });

    test('the bytes may arrive in pieces', () async {
      final all = utf8.encode(html);
      final docs = await HtmlParser().asParser().parse(
            ctx,
            Stream.fromIterable([all.sublist(0, 17), all.sublist(17)]),
          );

      expect(docs.single.content, contains('World of'));
    });

    test('the URI of the call becomes the source of the documents', () async {
      final docs = await HtmlParser().asParser().parse(
            ctx,
            _bytes(html),
            options: const ParserOptions(uri: 'https://example.com/page.html'),
          );

      expect(docs.single.metadata[metaKeySource], 'https://example.com/page.html');
      expect(docs.single.source?.uri, 'https://example.com/page.html');
    });

    test('extra metadata of the call is added', () async {
      final docs = await HtmlParser().asParser().parse(
            ctx,
            _bytes(html),
            options: const ParserOptions(extraMeta: {'crawl': 7}),
          );

      expect(docs.single.metadata['crawl'], 7);
      expect(docs.single.metadata.containsKey(metaKeySource), isFalse);
      expect(docs.single.source, isNull);
    });

    test('options of the wrapped parser: fixed, or with the call', () async {
      const tableHtml = '<table><tr><th>A</th></tr><tr><td>1</td></tr></table>';
      final legacy = HtmlParser();

      final plain = await legacy.asParser().parse(ctx, _bytes(tableHtml));
      final fixed = await legacy
          .asParser(options: const DocumentParserOptions(metadata: {'from': 'fixed'}))
          .parse(ctx, _bytes(tableHtml));
      final perCall = await legacy
          .asParser(options: const DocumentParserOptions(metadata: {'from': 'fixed'}))
          .parse(
            ctx,
            _bytes(tableHtml),
            options: const ParserOptions(
              extensions: [DocumentParserOptions(metadata: {'from': 'call'})],
            ),
          );

      expect(plain.single.metadata.containsKey('from'), isFalse);
      expect(fixed.single.metadata['from'], 'fixed');
      expect(perCall.single.metadata['from'], 'call');
    });

    test('MarkdownParser and PlainTextParser work the same way', () async {
      final markdown = await MarkdownParser().asParser().parse(
            ctx,
            _bytes('---\ntitle: Notes\n---\n# Heading\n\nBody text.'),
            options: const ParserOptions(uri: 'notes.md'),
          );
      expect(markdown.single.content, contains('Body text.'));
      expect(markdown.single.metadata[metaKeySource], 'notes.md');

      final plain =
          await PlainTextParser().asParser().parse(ctx, _bytes('just text'));
      expect(plain.single.content, 'just text');
    });

    test('ExtParser picks the existing parsers by extension', () async {
      final parser = ExtParser(
        parsers: {
          '.html': HtmlParser().asParser(),
          '.md': MarkdownParser().asParser(),
        },
      );

      final fromHtml = await parser.parse(
        ctx,
        _bytes(html),
        options: const ParserOptions(uri: 'site/page.html', extraMeta: {'k': 1}),
      );
      final fromText = await parser.parse(
        ctx,
        _bytes(html),
        options: const ParserOptions(uri: 'site/page.txt'),
      );

      expect(fromHtml.single.content, isNot(contains('<h1>')));
      expect(fromHtml.single.metadata['k'], 1);
      expect(fromHtml.single.metadata[metaKeySource], 'site/page.html');
      // The fallback is the text parser: the markup stays.
      expect(fromText.single.content, html);
    });

    test('a cancelled context stops before the parser runs', () async {
      final token = CancelToken()..cancel('stop');

      await expectLater(
        HtmlParser().asParser().parse(
              RunContext.background(cancelToken: token),
              _bytes(html),
            ),
        throwsA(isA<CancelledException>()),
      );
    });

    test('names its type', () {
      expect(DocumentParserAdapter(HtmlParser()).componentTypeName, 'DocumentParser');
      expect(DocumentParserAdapter(HtmlParser()).parser, isA<HtmlParser>());
    });
  });

  group('LoaderAdapter', () {
    const source = DocumentSource(uri: 'notes/a.txt');

    test('creates the loader for the source of each call', () async {
      final created = <String>[];
      final Loader loader = LoaderAdapter((source) {
        created.add(source.uri);
        return _BoundLoader(source.uri);
      });

      final first = await loader.load(ctx, source);
      final second = await loader.load(ctx, const DocumentSource(uri: 'notes/b.txt'));

      expect(created, ['notes/a.txt', 'notes/b.txt']);
      expect(first.single.content, 'content of notes/a.txt');
      expect(second.single.content, 'content of notes/b.txt');
    });

    test('documents without a source get the source of the call', () async {
      final loader = LoaderAdapter((source) => _BoundLoader(source.uri));
      final docs = await loader.load(ctx, source);

      expect(docs.single.source, source);
      expect(docs.single.metadata, {'loader': 'bound'});
    });

    test('a source the loader set itself is kept', () async {
      final loader = LoaderAdapter(
        (source) => _BoundLoader(source.uri, withSource: true),
      );
      final docs = await loader.load(ctx, source);

      expect(docs.single.source?.uri, 'bound://notes/a.txt');
    });

    test('extra metadata of the parser options is added to every document',
        () async {
      final loader = LoaderAdapter(
        (source) => _BoundLoader(source.uri, withSource: true),
      );

      final docs = await loader.load(
        ctx,
        source,
        options: const LoaderOptions(
          parserOptions: ParserOptions(extraMeta: {'batch': 3, 'loader': 'new'}),
        ),
      );

      expect(docs.single.metadata, {'loader': 'new', 'batch': 3});
      expect(docs.single.source?.uri, 'bound://notes/a.txt');
    });

    test('options of the wrapped loader: fixed, or with the call', () async {
      late _BoundLoader created;
      final loader = LoaderAdapter(
        (source) => created = _BoundLoader(source.uri),
        options: const DocumentLoaderOptions(metadata: {'from': 'fixed'}),
      );

      final fixed = await loader.load(ctx, source);
      expect(fixed.single.metadata['from'], 'fixed');
      expect(created.seenOptions.single?.metadata, {'from': 'fixed'});

      final perCall = await loader.load(
        ctx,
        source,
        options: const LoaderOptions(
          extensions: [DocumentLoaderOptions(metadata: {'from': 'call'})],
        ),
      );
      expect(perCall.single.metadata['from'], 'call');
    });

    test('a subclass of the loader options is found among the extensions',
        () async {
      late _BoundLoader created;
      final loader = LoaderAdapter((source) => created = _BoundLoader(source.uri));
      const urlOptions = UrlLoaderOptions(userAgent: 'threepio-test');

      await loader.load(
        ctx,
        source,
        options: const LoaderOptions(extensions: [urlOptions]),
      );

      expect(created.seenOptions.single, same(urlOptions));
    });

    test('a cancelled context stops before a loader is created', () async {
      var created = false;
      final loader = LoaderAdapter((source) {
        created = true;
        return _BoundLoader(source.uri);
      });
      final token = CancelToken()..cancel();

      await expectLater(
        loader.load(RunContext.background(cancelToken: token), source),
        throwsA(isA<CancelledException>()),
      );
      expect(created, isFalse);
    });

    test('an error of the wrapped loader fails the call', () async {
      final loader = LoaderAdapter(
        (source) => throw DocumentLoaderException('File not found: ${source.uri}'),
      );

      await expectLater(
        loader.load(ctx, source),
        throwsA(isA<DocumentLoaderException>()),
      );
    });

    test('names its type', () {
      expect(
        LoaderAdapter((source) => _BoundLoader(source.uri)).componentTypeName,
        'DocumentLoader',
      );
    });
  });

  group('RerankerTransformer', () {
    final documents = [
      Document.simple('dart'),
      Document.simple('dart dart dart'),
      Document.simple('go'),
      Document.simple('dart dart'),
    ];

    test('returns the documents in ranked order with their scores', () async {
      final reranker = _CountingReranker();
      final DocumentTransformer transformer =
          RerankerTransformer(reranker, query: 'dart');

      final ranked = await transformer.transform(documents);

      expect(
        ranked.map((doc) => doc.content),
        ['dart dart dart', 'dart dart', 'dart', 'go'],
      );
      expect(ranked.map((doc) => doc.score), [3, 2, 1, 0]);
      expect(ranked.first.effectiveScore, 3);
      expect(reranker.calls.single.$1, 'dart');
    });

    test('the query of a call takes precedence over the fixed one', () async {
      final reranker = _CountingReranker();
      final transformer = RerankerTransformer(reranker, query: 'dart');

      final ranked = await transformer.transform(
        documents,
        options: const TransformerOptions(extensions: [RerankQuery('go')]),
      );

      expect(ranked.first.content, 'go');
      expect(reranker.calls.single.$1, 'go');
    });

    test('reranker options: fixed, or with the call', () async {
      final reranker = _CountingReranker();
      final transformer = RerankerTransformer(
        reranker,
        query: 'dart',
        options: const RerankerOptions(topK: 2),
      );

      expect(await transformer.transform(documents), hasLength(2));
      expect(
        await transformer.transform(
          documents,
          options: const TransformerOptions(extensions: [RerankerOptions(topK: 1)]),
        ),
        hasLength(1),
      );
      expect(reranker.calls.map((call) => call.$2?.topK), [2, 1]);
    });

    test('without any query it says how to give one', () async {
      await expectLater(
        RerankerTransformer(_CountingReranker()).transform(documents),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('RerankQuery')),
        ),
      );
    });

    test('works with a reranker threepio ships', () async {
      final transformer = RerankerTransformer(ScoreReranker(), query: 'unused');

      final ranked = await transformer.transform(const [
        Document(content: 'low', score: 0.1),
        Document(content: 'high', score: 0.9),
      ]);

      expect(ranked.map((doc) => doc.content), ['high', 'low']);
    });
  });
}
