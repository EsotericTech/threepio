// Port of eino `components/indexer/option_test.go` (TestOptions) and
// `callback_extra_test.go` (TestConvIndexer), and tests for
// VectorStoreIndexer, the Indexer over threepio's VectorStore.
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// `embedding.MockEmbedder` of the Go tests: the vector of a text is made of
/// its length and of the number of times it was asked.
final class _MockEmbedder extends Embedder {
  _MockEmbedder([this.tag = 1]);

  final double tag;
  final List<List<String>> calls = [];
  final List<EmbedderOptions?> seenOptions = [];

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    calls.add(texts);
    seenOptions.add(options);
    return [
      for (final text in texts) [text.length.toDouble(), tag],
    ];
  }
}

/// Returns one vector too few.
final class _ShortEmbedder extends Embedder {
  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async =>
      [
        for (final text in texts.skip(1)) [text.length.toDouble(), 0],
      ];
}

/// A store that records what it is given.
final class _RecordingStore implements VectorStore {
  final List<List<Document>> added = [];
  final List<VectorStoreOptions?> seenOptions = [];

  @override
  Future<void> addDocuments(
    List<Document> documents, {
    VectorStoreOptions? options,
  }) async {
    added.add(documents);
    seenOptions.add(options);
  }

  @override
  Future<void> clear() async => added.clear();

  @override
  Future<int> count() async =>
      added.fold<int>(0, (total, batch) => total + batch.length);

  @override
  Future<int> delete(List<String> ids) async => 0;

  @override
  Future<List<SimilaritySearchResult>> similaritySearch({
    required List<double> queryEmbedding,
    int k = 4,
    VectorStoreOptions? options,
  }) async =>
      [];

  @override
  Future<List<SimilaritySearchResult>> similaritySearchWithThreshold({
    required List<double> queryEmbedding,
    required double scoreThreshold,
    VectorStoreOptions? options,
  }) async =>
      [];
}

/// An indexer written directly against the contract.
final class _CountingIndexer implements Indexer {
  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async =>
      [for (final (index, _) in docs.indexed) '${options?.index ?? 'default'}-$index'];
}

void main() {
  final ctx = RunContext.background();

  group('TestOptions', () {
    test('the options of a call are applied over the defaults', () {
      final embedder = _MockEmbedder();
      const subIndexes = ['index_1', 'index_2'];

      final options = const IndexerOptions().merge(
        IndexerOptions(
          index: 'index',
          subIndexes: subIndexes,
          embedding: embedder,
        ),
      );

      expect(options.index, 'index');
      expect(options.subIndexes, subIndexes);
      expect(options.embedding, same(embedder));
    });

    test('what a call leaves unset keeps its default', () {
      final embedder = _MockEmbedder();
      final options = IndexerOptions(index: 'default', embedding: embedder)
          .merge(const IndexerOptions(subIndexes: ['a']));

      expect(options.index, 'default');
      expect(options.embedding, same(embedder));
      expect(options.subIndexes, ['a']);
    });

    test('nothing is set by default', () {
      const options = IndexerOptions();
      expect(options.index, isNull);
      expect(options.subIndexes, isNull);
      expect(options.embedding, isNull);
      expect(options.extensions, isEmpty);
      expect(options.merge(null), same(options));
    });

    test('copyWith and extensions', () {
      final options = const IndexerOptions(index: 'a', extensions: ['x'])
          .copyWith(subIndexes: const ['s']);

      expect(options.index, 'a');
      expect(options.subIndexes, ['s']);
      expect(options.extension<String>(), 'x');
      expect(
        options.merge(const IndexerOptions(extensions: ['y'])).extension<String>(),
        'y',
      );
    });
  });

  group('TestConvIndexer', () {
    test('IndexerCallbackInput.from', () {
      const input = IndexerCallbackInput(docs: []);
      expect(IndexerCallbackInput.from(input), same(input));
      expect(IndexerCallbackInput.from(<Document>[]), isNotNull);
      expect(IndexerCallbackInput.from('asd'), isNull);
    });

    test('IndexerCallbackOutput.from', () {
      const output = IndexerCallbackOutput(ids: []);
      expect(IndexerCallbackOutput.from(output), same(output));
      expect(IndexerCallbackOutput.from(<String>[]), isNotNull);
      expect(IndexerCallbackOutput.from('asd'), isNull);
    });

    test('the plain values a graph node reports are wrapped', () {
      final docs = [Document.simple('a')];
      expect(IndexerCallbackInput.from(docs)?.docs, same(docs));
      expect(IndexerCallbackOutput.from(<String>['id-1'])?.ids, ['id-1']);
      expect(
        const IndexerCallbackOutput(ids: ['id-1'], extra: {'k': 1}).extra,
        {'k': 1},
      );
    });
  });

  group('Indexer', () {
    test('is a contract anyone can implement', () async {
      final Indexer indexer = _CountingIndexer();

      expect(
        await indexer.store(ctx, [Document.simple('a'), Document.simple('b')]),
        ['default-0', 'default-1'],
      );
      expect(
        await indexer.store(
          ctx,
          [Document.simple('a')],
          options: const IndexerOptions(index: 'kb'),
        ),
        ['kb-0'],
      );
    });
  });

  group('VectorStoreIndexer', () {
    test('embeds, stores and returns one id per document, in order', () async {
      final store = _RecordingStore();
      final embedder = _MockEmbedder();
      final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);

      final ids = await indexer.store(ctx, [
        const Document(id: 'a', content: 'one'),
        const Document(id: 'b', content: 'three'),
      ]);

      expect(ids, ['a', 'b']);
      expect(embedder.calls, [
        ['one', 'three'],
      ]);
      final stored = store.added.single;
      expect(stored.map((doc) => doc.id), ['a', 'b']);
      expect(stored.map((doc) => doc.embedding), [
        [3.0, 1.0],
        [5.0, 1.0],
      ]);
      expect(stored.map((doc) => doc.content), ['one', 'three']);
    });

    test('documents without an id get one, and it is the id returned',
        () async {
      final store = _RecordingStore();
      final indexer =
          VectorStoreIndexer(vectorStore: store, embedder: _MockEmbedder());

      final ids = await indexer.store(ctx, [
        Document.simple('first'),
        const Document(id: 'kept', content: 'second'),
        Document.simple('third'),
      ]);

      expect(ids, hasLength(3));
      expect(ids[1], 'kept');
      expect(ids[0], isNotEmpty);
      expect(ids[0], isNot(ids[2]));
      expect(store.added.single.map((doc) => doc.id), ids);
    });

    test('an id generator replaces the random ids', () async {
      final indexer = VectorStoreIndexer(
        vectorStore: _RecordingStore(),
        embedder: _MockEmbedder(),
        idGenerator: (doc) => 'doc-${doc.content.length}',
      );

      expect(
        await indexer.store(ctx, [Document.simple('ab'), Document.simple('abcd')]),
        ['doc-2', 'doc-4'],
      );
    });

    test('only the documents without a vector are embedded', () async {
      final store = _RecordingStore();
      final embedder = _MockEmbedder();
      final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);

      await indexer.store(ctx, [
        const Document(id: 'a', content: 'has one', embedding: [9, 9]),
        const Document(id: 'b', content: 'needs one'),
        const Document(id: 'c', content: 'empty', embedding: []),
      ]);

      expect(embedder.calls, [
        ['needs one', 'empty'],
      ]);
      expect(store.added.single.map((doc) => doc.embedding), [
        [9.0, 9.0],
        [9.0, 1.0],
        [5.0, 1.0],
      ]);
    });

    test('a vector in the metadata counts as the vector of the document',
        () async {
      final store = _RecordingStore();
      final embedder = _MockEmbedder();
      final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);
      // What a document written by Eino-shaped code looks like after JSON.
      final fromJson = Document.fromJson(
        const Document(id: 'a', content: 'x').withDenseVector([1, 2]).toJson()
          ..remove('embedding'),
      );
      expect(fromJson.embedding, isNull);

      await indexer.store(ctx, [fromJson]);

      expect(embedder.calls, isEmpty);
      expect(store.added.single.single.embedding, [1.0, 2.0]);
    });

    test('documents that all have vectors need no embedder', () async {
      final store = _RecordingStore();
      final indexer = VectorStoreIndexer(vectorStore: store);

      final ids = await indexer.store(ctx, [
        const Document(id: 'a', content: 'x', embedding: [1, 2]),
      ]);

      expect(ids, ['a']);
      expect(store.added.single.single.embedding, [1.0, 2.0]);
    });

    test('without an embedder, a document without a vector is a StateError',
        () async {
      final store = _RecordingStore();
      final indexer = VectorStoreIndexer(vectorStore: store);

      await expectLater(
        indexer.store(ctx, [
          const Document(id: 'a', content: 'x', embedding: [1, 2]),
          Document.simple('no vector'),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('no embedder'), contains('1 of the 2')),
          ),
        ),
      );
      expect(store.added, isEmpty);
    });

    test('the embedder of the call replaces the one of the indexer', () async {
      final store = _RecordingStore();
      final own = _MockEmbedder();
      final ofCall = _MockEmbedder(2);
      final indexer = VectorStoreIndexer(vectorStore: store, embedder: own);

      await indexer.store(
        ctx,
        [Document.simple('text')],
        options: IndexerOptions(embedding: ofCall),
      );

      expect(own.calls, isEmpty);
      expect(ofCall.calls, hasLength(1));
      expect(store.added.single.single.embedding, [4.0, 2.0]);
    });

    test('the embedder is called under the context of the call', () async {
      final embedder = _MockEmbedder();
      final indexer =
          VectorStoreIndexer(vectorStore: _RecordingStore(), embedder: embedder);

      await indexer.store(ctx, [Document.simple('text')]);

      expect(embedder.seenOptions.single?.runContext, same(ctx));
    });

    test('sub-indexes of the call are recorded on the documents', () async {
      final store = _RecordingStore();
      final indexer =
          VectorStoreIndexer(vectorStore: store, embedder: _MockEmbedder());

      await indexer.store(
        ctx,
        [const Document(id: 'a', content: 'x', metadata: {'k': 'v'})],
        options: const IndexerOptions(subIndexes: ['faq', 'en']),
      );

      final stored = store.added.single.single;
      expect(stored.subIndexes, ['faq', 'en']);
      expect(stored.metadata['k'], 'v');
    });

    test('the index of the call is handed to the store', () async {
      final store = _RecordingStore();
      final indexer =
          VectorStoreIndexer(vectorStore: store, embedder: _MockEmbedder());

      await indexer.store(ctx, [Document.simple('a')]);
      await indexer.store(
        ctx,
        [Document.simple('b')],
        options: const IndexerOptions(index: 'kb-2'),
      );

      expect(store.seenOptions[0], isNull);
      expect(store.seenOptions[1]?.extra, {'index': 'kb-2'});
    });

    test('no documents, no work', () async {
      final store = _RecordingStore();
      final embedder = _MockEmbedder();
      final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);

      expect(await indexer.store(ctx, const []), isEmpty);
      expect(store.added, isEmpty);
      expect(embedder.calls, isEmpty);
    });

    test('a cancelled context stops before anything is embedded or stored',
        () async {
      final store = _RecordingStore();
      final embedder = _MockEmbedder();
      final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);
      final token = CancelToken()..cancel('stop');

      await expectLater(
        indexer.store(
          RunContext.background(cancelToken: token),
          [Document.simple('a')],
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(embedder.calls, isEmpty);
      expect(store.added, isEmpty);
    });

    test('an embedder that returns the wrong number of vectors is an error',
        () async {
      final store = _RecordingStore();
      final indexer =
          VectorStoreIndexer(vectorStore: store, embedder: _ShortEmbedder());

      await expectLater(
        indexer.store(ctx, [Document.simple('a'), Document.simple('b')]),
        throwsStateError,
      );
      expect(store.added, isEmpty);
    });

    test('names its type', () {
      final indexer = VectorStoreIndexer(vectorStore: _RecordingStore());
      expect(indexer.componentTypeName, 'VectorStore');
      expect(indexer.vectorStore, isA<_RecordingStore>());
      expect(indexer.embedder, isNull);
    });

    test('what it stores, a VectorRetriever over the same store finds',
        () async {
      final store = InMemoryVectorStore();
      final embedder = _MockEmbedder();
      final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);

      final ids = await indexer.store(ctx, [
        const Document(id: 'short', content: 'ab'),
        const Document(id: 'long', content: 'abcdefghijklmnopqrstuvwxyz'),
      ]);
      expect(ids, ['short', 'long']);
      expect(await store.count(), 2);

      final retriever = VectorRetriever(
        vectorStore: store,
        embedder: embedder,
        defaultTopK: 1,
      );
      final found = await retriever.retrieve('xy');
      expect(found.single.id, 'short');
    });
  });
}
