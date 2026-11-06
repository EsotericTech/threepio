// `VectorRetriever` reports its retrievals to the new callback chain, as the
// retrievers of eino-ext do (`EnsureRunInfo`, `OnStart` with a
// `retriever.CallbackInput`, `OnEnd` with a `retriever.CallbackOutput`,
// `OnError`, the embedder called under its own run info; e.g.
// `components/retriever/qdrant/retriever.go`). Coordinator decision 2 after
// P3 put this wiring in P10. The legacy `callbackManager` keeps firing.
// ignore_for_file: deprecated_member_use
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/threepio_core.dart'
    show
        BaseCallbackHandler,
        CallbackInput,
        CallbackManager,
        CallbackOutput,
        InMemoryVectorStore,
        SimilaritySearchResult,
        VectorRetriever,
        VectorStore,
        VectorStoreOptions;

import '../../support/log_capture.dart';

final ctx = RunContext.background();

/// Embeds every text as [vector]; records the options of each call. Says it
/// is `Axis`.
final class _AxisEmbedder implements Embedder, TypedComponent {
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

  @override
  String get componentTypeName => 'Axis';
}

/// Fails every search.
final class _BrokenStore extends InMemoryVectorStore {
  @override
  Future<List<SimilaritySearchResult>> similaritySearch({
    required List<double> queryEmbedding,
    int k = 4,
    VectorStoreOptions? options,
  }) async =>
      throw StateError('store down');
}

/// Records what a legacy handler hears.
final class _LegacyHandler extends BaseCallbackHandler {
  final List<String> events = [];

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    events.add('start ${info.name} ${input.data}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    events.add('end ${info.name}');
    return context;
  }
}

Future<VectorStore> _store() async {
  final store = InMemoryVectorStore();
  await store.addDocuments(const [
    Document(id: 'x', content: 'x', embedding: [1, 0]),
    Document(id: 'y', content: 'y', embedding: [0, 1]),
  ]);
  return store;
}

/// A handler that records its callbacks as text, and the payloads.
final class _Recorder {
  final List<String> events = [];
  final List<Object?> payloads = [];

  late final ComponentCallbackHandler handler = CallbackHandlerBuilder()
      .onStart((ctx, info, input) {
        events.add('start ${info.componentType.name} ${info.type} '
            '"${info.name}"');
        payloads.add(input);
        return ctx;
      })
      .onEnd((ctx, info, output) {
        events.add('end ${info.componentType.name} ${info.type} '
            '"${info.name}"');
        payloads.add(output);
        return ctx;
      })
      .onError((ctx, info, error, stackTrace) {
        events.add('error ${info.type} $error');
        return ctx;
      })
      .build();
}

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  test('is typed Vector and fires its own callbacks', () async {
    final retriever =
        VectorRetriever(embedder: _AxisEmbedder(const [1, 0]), vectorStore: await _store());
    expect(retriever.componentTypeName, 'Vector');
    expect(componentTypeNameOf(retriever), 'Vector');
    expect(isCallbacksEnabled(retriever), isTrue);
  });

  test('reports the query, topK and threshold, then the documents', () async {
    failOnLoggedWarnings('threepio.callbacks');
    final recorder = _Recorder();
    final retriever = VectorRetriever(
      embedder: _AxisEmbedder(const [1, 0]),
      vectorStore: await _store(),
      defaultTopK: 1,
    );

    final docs = await retriever.retrieve(
      'q',
      options: RetrieverOptions(runContext: ctx.withHandlers([recorder.handler])),
    );

    expect(docs.single.id, 'x');
    expect(recorder.events, [
      'start retriever Vector ""',
      'end retriever Vector ""',
    ]);
    final input = recorder.payloads[0]! as RetrieverCallbackInput;
    expect(input.query, 'q');
    expect(input.topK, 1);
    expect(input.scoreThreshold, isNull);
    final output = recorder.payloads[1]! as RetrieverCallbackOutput;
    expect(output.docs, docs);
  });

  test('the options of the call show in the input', () async {
    final recorder = _Recorder();
    final retriever = VectorRetriever(
      embedder: _AxisEmbedder(const [0, 1]),
      vectorStore: await _store(),
    );

    final docs = await retriever.retrieve(
      'q',
      options: RetrieverOptions(
        topK: 1,
        scoreThreshold: 0.5,
        runContext: ctx.withHandlers([recorder.handler]),
      ),
    );

    expect(docs.single.id, 'y');
    final input = recorder.payloads[0]! as RetrieverCallbackInput;
    expect(input.topK, 1);
    expect(input.scoreThreshold, 0.5);
  });

  test('a failure is reported to the error callback and rethrown', () async {
    final recorder = _Recorder();
    final retriever = VectorRetriever(
      embedder: _AxisEmbedder(const [1, 0]),
      vectorStore: _BrokenStore(),
    );

    await expectLater(
      retriever.retrieve(
        'q',
        options: RetrieverOptions(runContext: ctx.withHandlers([recorder.handler])),
      ),
      throwsStateError,
    );
    expect(recorder.events, [
      'start retriever Vector ""',
      'error Vector Bad state: store down',
    ]);
  });

  test('the embedder is called in a context that introduces it as an '
      'embedder', () async {
    final recorder = _Recorder();
    final embedder = _AxisEmbedder(const [1, 0]);
    final retriever = VectorRetriever(embedder: embedder, vectorStore: await _store());

    await retriever.retrieve(
      'q',
      options: RetrieverOptions(runContext: ctx.withHandlers([recorder.handler])),
    );

    final info = embedder.seenOptions.single!.runContext!.runInfo!;
    expect(info.name, 'AxisEmbedding');
    expect(info.type, 'Axis');
    expect(info.componentType, ComponentType.embedder);
    expect(embedder.seenOptions.single!.runContext!.callbackHandlers,
        contains(recorder.handler));
  });

  test('the embedder of the call is the one introduced', () async {
    final recorder = _Recorder();
    final own = _AxisEmbedder(const [1, 0]);
    final ofCall = _AxisEmbedder(const [0, 1]);
    final retriever = VectorRetriever(embedder: own, vectorStore: await _store());

    final docs = await retriever.retrieve(
      'q',
      options: RetrieverOptions(
        topK: 1,
        embedding: ofCall,
        runContext: ctx.withHandlers([recorder.handler]),
      ),
    );

    expect(docs.single.id, 'y');
    expect(own.seenOptions, isEmpty);
    expect(ofCall.seenOptions.single!.runContext!.runInfo!.name, 'AxisEmbedding');
  });

  test('without handlers nothing changes: the embedder gets the run context '
      'of the call, or no options', () async {
    final embedder = _AxisEmbedder(const [1, 0]);
    final retriever = VectorRetriever(embedder: embedder, vectorStore: await _store());

    await retriever.retrieve('q', options: RetrieverOptions(runContext: ctx));
    await retriever.retrieve('q');
    await retriever.retrieveWithScores('q', options: RetrieverOptions(runContext: ctx));

    expect(embedder.seenOptions[0]!.runContext, same(ctx));
    expect(embedder.seenOptions[1], isNull);
    expect(embedder.seenOptions[2]!.runContext, same(ctx));
  });

  test('global handlers hear a call without a run context', () async {
    final recorder = _Recorder();
    GlobalCallbacks.append([recorder.handler]);
    final retriever =
        VectorRetriever(embedder: _AxisEmbedder(const [1, 0]), vectorStore: await _store());

    await retriever.retrieve('q');

    expect(recorder.events, [
      'start retriever Vector ""',
      'end retriever Vector ""',
    ]);
  });

  test('retrieveWithScores reports the documents of the results', () async {
    final recorder = _Recorder();
    final retriever = VectorRetriever(
      embedder: _AxisEmbedder(const [1, 0]),
      vectorStore: await _store(),
      defaultTopK: 2,
    );

    final results = await retriever.retrieveWithScores(
      'q',
      options: RetrieverOptions(runContext: ctx.withHandlers([recorder.handler])),
    );

    expect(results, hasLength(2));
    final output = recorder.payloads[1]! as RetrieverCallbackOutput;
    expect([for (final d in output.docs) d.id], [for (final r in results) r.document.id]);
  });

  test('a legacy callback manager still hears the call, around the new chain',
      () async {
    final recorder = _Recorder();
    final legacy = _LegacyHandler();
    final retriever =
        VectorRetriever(embedder: _AxisEmbedder(const [1, 0]), vectorStore: await _store());

    await retriever.retrieve(
      'q',
      options: RetrieverOptions(
        callbackManager: CallbackManager([legacy]),
        runContext: ctx.withHandlers([recorder.handler]),
      ),
    );

    expect(legacy.events, ['start VectorRetriever q', 'end VectorRetriever']);
    expect(recorder.events, hasLength(2));
  });

  test('in a graph the node keeps its name and the graph does not report the '
      'retriever a second time', () async {
    final recorder = _Recorder();
    final retriever =
        VectorRetriever(embedder: _AxisEmbedder(const [1, 0]), vectorStore: await _store());
    final graph = Graph<String, List<Document>>()
      ..addRetrieverNode(
        'search',
        retriever,
        options: const NodeOptions(name: 'kb search'),
      )
      ..addEdge(Graph.start, 'search')
      ..addEdge('search', Graph.end);
    final runnable = await graph.compile(ctx);

    final docs = await runnable.invoke(
      ctx,
      'q',
      options: [CallOption.callbacks([recorder.handler])],
    );

    expect(docs, isNotEmpty);
    final retrieverEvents =
        recorder.events.where((e) => e.contains(' retriever ')).toList();
    expect(retrieverEvents, [
      'start retriever Vector "kb search"',
      'end retriever Vector "kb search"',
    ]);
    expect(
      recorder.payloads.whereType<RetrieverCallbackInput>().single.query,
      'q',
    );
  });
}
