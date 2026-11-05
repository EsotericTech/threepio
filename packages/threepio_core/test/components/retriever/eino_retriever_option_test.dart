// Port of eino `components/retriever/option_test.go` (TestOptions) and
// `callback_extra_test.go` (TestConvRetriever).
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// `embedding.MockEmbedder` of the Go test.
final class _MockEmbedder extends Embedder {
  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async =>
      [
        for (final _ in texts) [0.0],
      ];
}

/// Embeds every text as [vector] and records the options it was given.
final class _AxisEmbedder extends Embedder {
  _AxisEmbedder(this.vector);

  final List<double> vector;
  final List<EmbedderOptions?> seenOptions = [];

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    seenOptions.add(options);
    return [for (final _ in texts) vector];
  }
}

/// A retriever that returns its options, so a test can look at them.
final class _OptionProbe extends Retriever {
  RetrieverOptions? seen;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    seen = options;
    return [Document.simple(query)];
  }
}

void main() {
  group('TestOptions', () {
    test('the options of a call are applied over the defaults', () {
      final embedder = _MockEmbedder();
      const dslInfo = {'dsl': 'dsl'};

      final options = const RetrieverOptions(topK: 1).merge(
        RetrieverOptions(
          index: 'index',
          topK: 2,
          scoreThreshold: 4,
          subIndex: 'sub_index',
          dslInfo: dslInfo,
          embedding: embedder,
        ),
      );

      expect(options.index, 'index');
      expect(options.topK, 2);
      expect(options.scoreThreshold, 4.0);
      expect(options.subIndex, 'sub_index');
      expect(options.dslInfo, same(dslInfo));
      expect(options.embedding, same(embedder));
    });

    test('what a call leaves unset keeps its default', () {
      final options = const RetrieverOptions(topK: 1, index: 'kb')
          .merge(const RetrieverOptions(scoreThreshold: 0.5));

      expect(options.topK, 1);
      expect(options.index, 'kb');
      expect(options.scoreThreshold, 0.5);
    });

    test('nothing new is set by default', () {
      const options = RetrieverOptions(topK: 3);
      expect(options.index, isNull);
      expect(options.subIndex, isNull);
      expect(options.embedding, isNull);
      expect(options.dslInfo, isNull);
      expect(options.runContext, isNull);
      expect(options.extensions, isEmpty);
      expect(options.merge(null), same(options));
    });
  });

  group('RetrieverOptions', () {
    test('carries the run context and extensions', () {
      final ctx = RunContext.background();
      final options = const RetrieverOptions(topK: 3)
          .copyWith(runContext: ctx, extensions: const ['mine']);

      expect(options.topK, 3);
      expect(options.runContext, same(ctx));
      expect(options.extension<String>(), 'mine');
      expect(options.extension<int>(), isNull);

      final merged =
          options.merge(const RetrieverOptions(extensions: ['theirs', 7]));
      expect(merged.extension<String>(), 'theirs');
      expect(merged.extension<int>(), 7);
      expect(merged.runContext, same(ctx));
    });

    test('the fields of the legacy callback API still work', () {
      final context = <String, dynamic>{'trace': 't'};
      final manager = CallbackManager([]);
      final options = RetrieverOptions(callbackManager: manager, context: context);

      expect(options.callbackManager, same(manager));
      expect(options.getOrCreateContext(), same(context));
      expect(const RetrieverOptions().getOrCreateContext(), isEmpty);

      // They survive copyWith and merge.
      expect(options.copyWith(topK: 2).callbackManager, same(manager));
      expect(
        const RetrieverOptions(topK: 1).merge(options).context,
        same(context),
      );
    });

    test('HybridRetrieverOptions keeps its own fields through copyWith and '
        'merge', () {
      final ctx = RunContext.background();
      const options = HybridRetrieverOptions(
        topK: 5,
        vectorTopK: 3,
        overrideKeywordWeight: 0.2,
      );

      // What a graph node does to hand its context to the retriever.
      final RetrieverOptions withContext = options.copyWith(runContext: ctx);
      expect(withContext, isA<HybridRetrieverOptions>());
      expect(withContext.runContext, same(ctx));
      expect(withContext.topK, 5);
      expect((withContext as HybridRetrieverOptions).vectorTopK, 3);
      expect(withContext.overrideKeywordWeight, 0.2);
      expect(options.copyWith(keywordTopK: 9).keywordTopK, 9);

      final merged = options.merge(RetrieverOptions(topK: 7, runContext: ctx));
      expect(merged.topK, 7);
      expect(merged.vectorTopK, 3);
      expect(merged.runContext, same(ctx));

      final mergedWithHybrid =
          options.merge(const HybridRetrieverOptions(vectorTopK: 1));
      expect(mergedWithHybrid.vectorTopK, 1);
      expect(mergedWithHybrid.overrideKeywordWeight, 0.2);
      expect(mergedWithHybrid.topK, 5);
      expect(options.merge(null), same(options));
    });

    test('MultiQueryRetrieverOptions keeps its own fields through copyWith '
        'and merge', () {
      final ctx = RunContext.background();
      const options = MultiQueryRetrieverOptions(
        topK: 4,
        customQueries: ['a', 'b'],
        skipQueryGeneration: true,
      );

      final RetrieverOptions withContext = options.copyWith(runContext: ctx);
      expect(withContext, isA<MultiQueryRetrieverOptions>());
      expect((withContext as MultiQueryRetrieverOptions).customQueries, ['a', 'b']);
      expect(withContext.skipQueryGeneration, isTrue);
      expect(withContext.runContext, same(ctx));
      expect(withContext.topK, 4);

      final merged = options.merge(const RetrieverOptions(scoreThreshold: 0.5));
      expect(merged.customQueries, ['a', 'b']);
      expect(merged.skipQueryGeneration, isTrue);
      expect(merged.scoreThreshold, 0.5);

      final replaced = options.merge(
        const MultiQueryRetrieverOptions(customQueries: ['c']),
      );
      expect(replaced.customQueries, ['c']);
      expect(replaced.skipQueryGeneration, isFalse);
    });

    test('VectorRetriever embeds with the embedder of the call, under its '
        'context', () async {
      final store = InMemoryVectorStore();
      await store.addDocuments(const [
        Document(id: 'x', content: 'x', embedding: [1, 0]),
        Document(id: 'y', content: 'y', embedding: [0, 1]),
      ]);
      final own = _AxisEmbedder(const [1, 0]);
      final ofCall = _AxisEmbedder(const [0, 1]);
      final retriever =
          VectorRetriever(embedder: own, vectorStore: store, defaultTopK: 1);
      final ctx = RunContext.background();

      expect((await retriever.retrieve('q')).single.id, 'x');
      expect(own.seenOptions.single, isNull);

      final found = await retriever.retrieve(
        'q',
        options: RetrieverOptions(embedding: ofCall, runContext: ctx),
      );
      expect(found.single.id, 'y');
      expect(ofCall.seenOptions.single?.runContext, same(ctx));
      expect(own.seenOptions, hasLength(1));

      final scored = await retriever.retrieveWithScores(
        'q',
        options: RetrieverOptions(embedding: ofCall),
      );
      expect(scored.single.document.id, 'y');
    });

    test('the options of the retrievers threepio ships accept the new fields',
        () async {
      final ctx = RunContext.background();
      final hybrid = HybridRetrieverOptions(
        topK: 5,
        vectorTopK: 3,
        index: 'kb',
        runContext: ctx,
        extensions: const ['x'],
      );
      final multiQuery = MultiQueryRetrieverOptions(
        skipQueryGeneration: true,
        subIndex: 'faq',
        dslInfo: const {'term': 'a'},
        runContext: ctx,
      );

      expect(hybrid.index, 'kb');
      expect(hybrid.vectorTopK, 3);
      expect(hybrid.runContext, same(ctx));
      expect(hybrid.extension<String>(), 'x');
      expect(multiQuery.subIndex, 'faq');
      expect(multiQuery.dslInfo, {'term': 'a'});
      expect(multiQuery.skipQueryGeneration, isTrue);

      // And they are still RetrieverOptions for any retriever.
      final probe = _OptionProbe();
      await probe.retrieve('q', options: hybrid);
      expect(probe.seen, same(hybrid));
    });
  });

  group('TestConvRetriever', () {
    test('RetrieverCallbackInput.from', () {
      const input = RetrieverCallbackInput(query: 'q');
      expect(RetrieverCallbackInput.from(input), same(input));
      expect(RetrieverCallbackInput.from('asd'), isNotNull);
      expect(RetrieverCallbackInput.from(<String>[]), isNull);
    });

    test('RetrieverCallbackOutput.from', () {
      const output = RetrieverCallbackOutput(docs: []);
      expect(RetrieverCallbackOutput.from(output), same(output));
      expect(RetrieverCallbackOutput.from(<Document>[]), isNotNull);
      expect(RetrieverCallbackOutput.from('asd'), isNull);
    });

    test('the query a graph node reports becomes the input', () {
      final input = RetrieverCallbackInput.from('what is eino')!;
      expect(input.query, 'what is eino');
      expect(input.topK, isNull);
      expect(input.filter, isNull);
      expect(input.scoreThreshold, isNull);
      expect(input.extra, isNull);
    });

    test('a retriever reports what it searched with', () {
      const input = RetrieverCallbackInput(
        query: 'q',
        topK: 5,
        filter: 'lang = "en"',
        scoreThreshold: 0.7,
        extra: {'index': 'kb'},
      );
      expect(input.topK, 5);
      expect(input.filter, 'lang = "en"');
      expect(input.scoreThreshold, 0.7);
      expect(input.extra, {'index': 'kb'});
      expect(input.toString(), contains('topK: 5'));

      final docs = [Document.simple('a')];
      final output = RetrieverCallbackOutput.from(docs)!;
      expect(output.docs, same(docs));
      expect(output.extra, isNull);
    });
  });
}
