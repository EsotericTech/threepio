// Ports eino-ext components/retriever/qdrant/retriever_test.go:
// TestNewRetrieverValidation ("Given config with empty collection"),
// TestRetrieverRetrieve, TestRetrieverRetrieveWithError and
// TestRetrieverTypeAndCallbacks. Go mocks `qdrant.Client.Query` with mockey;
// here the retriever talks REST to a fake Qdrant server
// (`../qdrant/fake_qdrant.dart`) that answers with the JSON shape of
// `POST /collections/{c}/points/query`. Not ported: the "nil config", "nil
// embedding" and "nil client" cases of TestNewRetrieverValidation (the
// configuration, its embedder and its client are required, non-nullable
// parameters in Dart, so those mistakes do not compile).
//
// Plus tests written for the port: the query request (vector, limit,
// threshold, filter, payload), the options of a call overriding the
// configuration (topK, score threshold, embedder, filter), the documents
// built as Go builds them (UUID id, empty id for a numeric one, content,
// metadata under `metadata`, the float32 score), Go's error messages, a
// payload whose `metadata` is not an object, cancellation, callbacks (the
// input with the filter as JSON, end/error payloads, the embedder's run info,
// no handler → no wrapper, global handlers, a graph node), and a round trip
// with the Qdrant indexer through the same fake server.
//
// Deliberate deviations these tests pin (documented on the classes): the
// score threshold of the call is sent (Go sends only the configured one,
// though it reports the call's to the callbacks); the callback filter is the
// JSON of the REST filter, or null without one (Go: the JSON of its protobuf
// filter, or "null"); the `metadata` entry is a plain JSON map (Go: go-client
// values); a `metadata` field that is not an object is a format error (Go
// panics on the nil struct).
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/indexer/qdrant/qdrant_indexer.dart';
import 'package:threepio_core/src/components/qdrant/qdrant_client.dart';
import 'package:threepio_core/src/components/retriever/qdrant/qdrant_retriever.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/log_capture.dart';
import '../qdrant/fake_qdrant.dart';

const _collection = 'test_collection';

final _ctx = RunContext.background();

/// Go's mock answer of `Query`.
const _goPoint = {
  'id': 'fba95545-ef38-4880-bf4a-b98174554103',
  'version': 0,
  'score': 0.95,
  'payload': {'content': 'Test content 1'},
};

/// The float32 nearest to [value], widened back, as Go reads a score.
double _f32(double value) => (Float32List(1)..[0] = value)[0];

/// Go's mockEmbeddingQdrant with a fixed vector: embeds every text as
/// [vector], or throws [error]. [count] overrides the number of vectors.
/// Records the texts and options of each call.
final class _MockEmbedder implements Embedder, TypedComponent {
  _MockEmbedder({
    this.vector = const [0.1, 0.2, 0.3, 0.4],
    this.error,
    this.count,
    this.type = 'Mock',
  });

  final List<double> vector;
  final Object? error;
  final int? count;
  final String type;
  final List<List<String>> calls = [];
  final List<EmbedderOptions?> seenOptions = [];

  @override
  String get componentTypeName => type;

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    calls.add(texts);
    seenOptions.add(options);
    final error = this.error;
    if (error != null) throw error;
    return [for (var i = 0; i < (count ?? texts.length); i++) vector];
  }
}

/// A handler that records its callbacks as text, and the payloads.
final class _Recorder {
  final List<String> events = [];
  final List<Object?> payloads = [];
  final List<Object> errors = [];

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
        events.add('error ${info.componentType.name} ${info.type}');
        errors.add(error);
        return ctx;
      })
      .build();
}

QdrantRetriever _retriever(
  FakeQdrant fake, {
  Embedder? embedding,
  int? topK = 5,
  double? scoreThreshold,
}) =>
    QdrantRetriever(
      QdrantRetrieverConfig(
        client: QdrantClient(httpClient: fake.client),
        collection: _collection,
        embedding: embedding ?? _MockEmbedder(),
        topK: topK,
        scoreThreshold: scoreThreshold,
      ),
    );

FakeQdrant _answering(List<Map<String, Object?>> points) =>
    FakeQdrant(collections: [_collection])..queryAnswer = points;

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  group('TestNewRetrieverValidation', () {
    test('Given config with empty collection: it returns an error', () {
      expect(
        () => QdrantRetriever(
          QdrantRetrieverConfig(
            client: QdrantClient(httpClient: FakeQdrant().client),
            collection: '',
            embedding: _MockEmbedder(),
          ),
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message',
                  '[NewRetriever] qdrant collection not provided')
              .having((e) => '$e', 'text', contains('collection not provided')),
        ),
      );
    });
  });

  group('TestRetrieverRetrieve', () {
    test('Given a valid retriever: it retrieves the document Query returns',
        () async {
      final fake = _answering([_goPoint]);
      final retriever = _retriever(fake);

      // Then the retriever should be created successfully
      expect(retriever, isNotNull);

      final docs = await retriever.retrieve('test query');

      // Then the retrieve operation should succeed
      expect(docs, hasLength(1));
      // And the document should have correct content
      expect(docs[0].content, 'Test content 1');
      expect(docs[0].id, 'fba95545-ef38-4880-bf4a-b98174554103');
      // And the mock Query method should be called
      expect(fake.queryBodies, hasLength(1));
    });
  });

  group('TestRetrieverRetrieveWithError', () {
    test('Given a retriever with failing embedding: the retrieval fails with '
        "the embedder's error", () async {
      final fake = _answering([_goPoint]);
      final failure = StateError('embedding failed');
      final retriever = _retriever(fake, embedding: _MockEmbedder(error: failure));

      final error = await retriever
          .retrieve('test query')
          .then<Object>((_) => fail('no error'), onError: (Object e) => e);

      // Go returns the embedder's error as it is.
      expect(error, same(failure));
      expect('$error', contains('embedding failed'));
      expect(fake.queryBodies, isEmpty);
    });
  });

  group('TestRetrieverTypeAndCallbacks', () {
    test('Given a valid retriever: GetType is Qdrant and callbacks are '
        'enabled', () {
      final retriever = _retriever(FakeQdrant());

      expect(retriever.componentTypeName, 'Qdrant');
      expect(componentTypeNameOf(retriever), 'Qdrant');
      expect(retriever.isCallbacksEnabled, isTrue);
      expect(isCallbacksEnabled(retriever), isTrue);
      expect(retriever, isA<Retriever>());
    });
  });

  group('query request', () {
    test('POSTs the query vector with the limit and the payloads', () async {
      final fake = _answering([]);
      final embedder = _MockEmbedder();

      await _retriever(fake, embedding: embedder).retrieve('test query');

      expect(embedder.calls, [
        ['test query'],
      ]);
      final request = fake.requestsTo('/points/query').single;
      expect(request.method, 'POST');
      expect(request.url.path, '/collections/$_collection/points/query');
      expect(request.body, {
        'query': [0.1, 0.2, 0.3, 0.4],
        'limit': 5,
        'with_payload': true,
      });
    });

    test('topK: 5 by default, the configured one, the one of the call',
        () async {
      final fake = _answering([]);

      await _retriever(fake, topK: null).retrieve('q');
      await _retriever(fake, topK: 0).retrieve('q');
      await _retriever(fake, topK: 3).retrieve('q');
      await _retriever(fake, topK: 3)
          .retrieve('q', options: const RetrieverOptions(topK: 8));

      expect([for (final body in fake.queryBodies) body['limit']], [5, 5, 3, 8]);
      expect(_retriever(fake, topK: null).topK, QdrantRetriever.defaultTopK);
    });

    test('the score threshold: none, the configured one, the one of the call',
        () async {
      final fake = _answering([]);

      await _retriever(fake).retrieve('q');
      await _retriever(fake, scoreThreshold: 0.5).retrieve('q');
      await _retriever(fake, scoreThreshold: 0.5)
          .retrieve('q', options: const RetrieverOptions(scoreThreshold: 0.8));

      expect(fake.queryBodies[0].containsKey('score_threshold'), isFalse);
      expect(fake.queryBodies[1]['score_threshold'], 0.5);
      expect(fake.queryBodies[2]['score_threshold'], 0.8);
    });

    test('the filter of the call is sent as it is', () async {
      final fake = _answering([]);
      const filter = {
        'must': [
          {
            'key': 'metadata.country',
            'match': {'value': 'France'},
          },
        ],
        'must_not': [
          {
            'key': 'metadata.year',
            'range': {'lt': 1900},
          },
        ],
      };

      await _retriever(fake).retrieve(
        'q',
        options: const RetrieverOptions(
          extensions: [QdrantRetrieverOptions(filter: filter)],
        ),
      );

      expect(fake.queryBodies.single['filter'], filter);
    });

    test('the embedder of the call replaces the configured one', () async {
      final fake = _answering([]);
      final own = _MockEmbedder();
      final ofCall = _MockEmbedder(vector: const [1, 0]);

      await _retriever(fake, embedding: own)
          .retrieve('q', options: RetrieverOptions(embedding: ofCall));

      expect(own.calls, isEmpty);
      expect(ofCall.calls, [
        ['q'],
      ]);
      expect(fake.queryBodies.single['query'], [1.0, 0.0]);
    });
  });

  group('documents', () {
    test('id, content, metadata under "metadata" and the float32 score',
        () async {
      final fake = _answering([
        {
          'id': 'fba95545-ef38-4880-bf4a-b98174554103',
          'version': 2,
          'score': 0.95,
          'payload': {
            'content': 'Eiffel Tower',
            'metadata': {
              'country': 'France',
              'year': 1889,
              'tags': ['tower', 'paris'],
              'location': {'lat': 48.8584},
            },
            'other': 'not read',
          },
        },
        {
          'id': '7b83aca0-5f6c-4491-8dd4-22e15e9d582e',
          'version': 2,
          'score': 0.5,
          'payload': {'content': 'Colosseum'},
        },
      ]);

      final docs = await _retriever(fake).retrieve('q');

      expect(docs[0].id, 'fba95545-ef38-4880-bf4a-b98174554103');
      expect(docs[0].content, 'Eiffel Tower');
      expect(docs[0].metadata, {
        'metadata': {
          'country': 'France',
          'year': 1889,
          'tags': ['tower', 'paris'],
          'location': {'lat': 48.8584},
        },
        '_score': _f32(0.95),
      });
      // Go: doc.WithScore(float64(pt.Score)) with a float32 score.
      expect(docs[0].score, _f32(0.95));
      expect(docs[0].score, isNot(0.95));
      expect(docs[0].effectiveScore, _f32(0.95));
      expect(docs[1].metadata, {'_score': 0.5});
      expect(docs[1].score, 0.5);
    });

    test('a numeric id gives an empty id, as Go GetUuid does', () async {
      final fake = _answering([
        {'id': 42, 'version': 0, 'score': 1, 'payload': {'content': 'n'}},
      ]);

      final docs = await _retriever(fake).retrieve('q');

      expect(docs.single.id, '');
      expect(docs.single.content, 'n');
    });

    test('no payload, or a content that is not a string, gives an empty '
        'content', () async {
      final fake = _answering([
        {'id': 'a', 'version': 0, 'score': 0.25, 'payload': null},
        {'id': 'b', 'version': 0, 'score': 0.25, 'payload': {'content': 7}},
        {'id': 'c', 'version': 0, 'score': 0.25, 'payload': <String, Object?>{}},
      ]);

      final docs = await _retriever(fake).retrieve('q');

      expect([for (final d in docs) d.content], ['', '', '']);
      expect([for (final d in docs) d.metadata], [
        {'_score': 0.25},
        {'_score': 0.25},
        {'_score': 0.25},
      ]);
    });

    test('an empty metadata object is kept', () async {
      final fake = _answering([
        {
          'id': 'a',
          'version': 0,
          'score': 0.25,
          'payload': {'content': 'x', 'metadata': <String, Object?>{}},
        },
      ]);

      final docs = await _retriever(fake).retrieve('q');

      expect(docs.single.metadata, {
        'metadata': <String, Object?>{},
        '_score': 0.25,
      });
    });

    test('a metadata field that is not an object is a format error',
        () async {
      for (final bad in [null, 'text', 3, ['a']]) {
        final fake = _answering([
          {
            'id': 'a',
            'version': 0,
            'score': 0.25,
            'payload': {'content': 'x', 'metadata': bad},
          },
        ]);
        await expectLater(
          _retriever(fake).retrieve('q'),
          throwsA(
            isA<ThreepioFormatException>().having(
              (e) => e.message,
              'message',
              '[qdrant retriever] the payload field "metadata" of point a is '
                  'not an object: $bad',
            ),
          ),
          reason: '$bad',
        );
      }
    });

    test('no points: no documents', () async {
      expect(await _retriever(_answering([])).retrieve('q'), isEmpty);
    });
  });

  group('errors', () {
    test('another number of vectors than one is "[qdrant retriever] invalid '
        'return length of vector"', () async {
      for (final count in [0, 2]) {
        final fake = _answering([_goPoint]);
        await expectLater(
          _retriever(fake, embedding: _MockEmbedder(count: count))
              .retrieve('q'),
          throwsA(isA<ThreepioException>().having((e) => e.message, 'message',
              '[qdrant retriever] invalid return length of vector, '
                  'got=$count, expected=1')),
        );
        expect(fake.queryBodies, isEmpty);
      }
    });

    test('a failed query is "[Retriever] qdrant search failed: …"', () async {
      final fake = FakeQdrant(); // the collection does not exist

      await expectLater(
        _retriever(fake).retrieve('q'),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message',
                  '[Retriever] qdrant search failed: Query() failed: '
                      '$_collection: HTTP 404: Not found: Collection '
                      "`$_collection` doesn't exist!")
              .having((e) => e.cause, 'cause',
                  isA<QdrantException>().having((e) => e.statusCode, 'status', 404)),
        ),
      );
    });

    test('an unreadable answer is a failed search too', () async {
      final fake = FakeQdrant()
        ..override = (_) async => qdrantOk({'hits': <Object?>[]});

      await expectLater(
        _retriever(fake).retrieve('q'),
        throwsA(isA<ThreepioException>().having((e) => e.message, 'message',
            '[Retriever] qdrant search failed: Query() failed: '
                '$_collection: unexpected answer: no "points" list')),
      );
    });
  });

  group('cancellation', () {
    test('a cancelled run context embeds and sends nothing', () async {
      final fake = _answering([_goPoint]);
      final embedder = _MockEmbedder();

      await expectLater(
        _retriever(fake, embedding: embedder).retrieve(
          'q',
          options: RetrieverOptions(
            runContext:
                RunContext.background(cancelToken: CancelToken()..cancel('x')),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(embedder.calls, isEmpty);
      expect(fake.requests, isEmpty);
    });

    test('cancelling while the query is awaited abandons the retrieval',
        () async {
      final fake = _answering([_goPoint]);
      final sent = Completer<void>();
      fake.override = (_) {
        sent.complete();
        return Completer<http.Response?>().future; // never answers
      };
      final token = CancelToken();

      final docs = _retriever(fake).retrieve(
        'q',
        options: RetrieverOptions(
          runContext: RunContext.background(cancelToken: token),
        ),
      );
      await sent.future;
      token.cancel('user');

      await expectLater(docs, throwsA(isA<CancelledException>()));
    });
  });

  group('callbacks', () {
    test('reports the query, topK and threshold, then the documents',
        () async {
      failOnLoggedWarnings('threepio.callbacks');
      final recorder = _Recorder();
      final fake = _answering([_goPoint]);

      final docs = await _retriever(fake, topK: 3, scoreThreshold: 0.2)
          .retrieve(
        'test query',
        options: RetrieverOptions(runContext: _ctx.withHandlers([recorder.handler])),
      );

      expect(recorder.events, [
        'start retriever Qdrant ""',
        'end retriever Qdrant ""',
      ]);
      final input = recorder.payloads[0]! as RetrieverCallbackInput;
      expect(input.query, 'test query');
      expect(input.topK, 3);
      expect(input.scoreThreshold, 0.2);
      expect(input.filter, isNull);
      final output = recorder.payloads[1]! as RetrieverCallbackOutput;
      expect(output.docs, docs);
    });

    test('the options of the call show in the input, the filter as JSON',
        () async {
      final recorder = _Recorder();
      final fake = _answering([]);

      await _retriever(fake, scoreThreshold: 0.2).retrieve(
        'q',
        options: RetrieverOptions(
          topK: 1,
          scoreThreshold: 0.9,
          runContext: _ctx.withHandlers([recorder.handler]),
          extensions: const [
            QdrantRetrieverOptions(filter: {
              'must': [
                {
                  'key': 'metadata.lang',
                  'match': {'value': 'en'},
                },
              ],
            }),
          ],
        ),
      );

      final input = recorder.payloads[0]! as RetrieverCallbackInput;
      expect(input.topK, 1);
      expect(input.scoreThreshold, 0.9);
      expect(
        input.filter,
        '{"must":[{"key":"metadata.lang","match":{"value":"en"}}]}',
      );
    });

    test('a filter that cannot be written as JSON shows as an empty string',
        () async {
      final recorder = _Recorder();
      final fake = _answering([]);

      await expectLater(
        _retriever(fake).retrieve(
          'q',
          options: RetrieverOptions(
            runContext: _ctx.withHandlers([recorder.handler]),
            extensions: [
              QdrantRetrieverOptions(filter: {'when': DateTime.utc(2025)}),
            ],
          ),
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect((recorder.payloads[0]! as RetrieverCallbackInput).filter, '');
      expect(recorder.events.last, 'error retriever Qdrant');
      expect(fake.requests, isEmpty);
    });

    test('a failure is reported to the error callback and rethrown', () async {
      final recorder = _Recorder();
      final failure = StateError('embedding failed');

      await expectLater(
        _retriever(_answering([]), embedding: _MockEmbedder(error: failure))
            .retrieve(
          'q',
          options:
              RetrieverOptions(runContext: _ctx.withHandlers([recorder.handler])),
        ),
        throwsA(same(failure)),
      );
      expect(recorder.events, [
        'start retriever Qdrant ""',
        'error retriever Qdrant',
      ]);
      expect(recorder.errors.single, same(failure));
    });

    test('the query runs in the context the start callback returned',
        () async {
      final fake = _answering([_goPoint]);
      final embedder = _MockEmbedder();
      final scoped = CallbackHandlerBuilder()
          .onStart((ctx, info, input) =>
              ctx.withCancelToken(CancelToken()..cancel('handler scope')))
          .build();

      await expectLater(
        _retriever(fake, embedding: embedder).retrieve(
          'q',
          options: RetrieverOptions(runContext: _ctx.withHandlers([scoped])),
        ),
        throwsA(isA<CancelledException>()
            .having((e) => e.reason, 'reason', 'handler scope')),
      );
      expect(embedder.calls, isEmpty);
      expect(fake.requests, isEmpty);
    });

    test('the embedder is called in a context that introduces it as an '
        'embedder', () async {
      final recorder = _Recorder();
      final embedder = _MockEmbedder();

      await _retriever(_answering([]), embedding: embedder).retrieve(
        'q',
        options: RetrieverOptions(runContext: _ctx.withHandlers([recorder.handler])),
      );

      final info = embedder.seenOptions.single!.runContext!.runInfo!;
      expect(info.name, 'MockEmbedding');
      expect(info.type, 'Mock');
      expect(info.componentType, ComponentType.embedder);
      expect(embedder.seenOptions.single!.runContext!.callbackHandlers,
          contains(recorder.handler));
    });

    test('the embedder of the call is the one introduced', () async {
      final recorder = _Recorder();
      final ofCall = _MockEmbedder(type: 'Other');

      await _retriever(_answering([])).retrieve(
        'q',
        options: RetrieverOptions(
          embedding: ofCall,
          runContext: _ctx.withHandlers([recorder.handler]),
        ),
      );

      expect(ofCall.seenOptions.single!.runContext!.runInfo!.name,
          'OtherEmbedding');
    });

    test('without handlers nothing changes: the embedder gets the run '
        'context of the call, or no options', () async {
      final embedder = _MockEmbedder();
      final retriever = _retriever(_answering([]), embedding: embedder);

      await retriever.retrieve('q', options: RetrieverOptions(runContext: _ctx));
      await retriever.retrieve('q');

      expect(embedder.seenOptions[0]!.runContext, same(_ctx));
      expect(embedder.seenOptions[1], isNull);
    });

    test('global handlers hear a call without a run context', () async {
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder.handler]);

      await _retriever(_answering([])).retrieve('q');

      expect(recorder.events, [
        'start retriever Qdrant ""',
        'end retriever Qdrant ""',
      ]);
    });

    test('in a graph the node keeps its name and the graph does not report '
        'the retriever a second time', () async {
      final recorder = _Recorder();
      final graph = Graph<String, List<Document>>()
        ..addRetrieverNode(
          'search',
          _retriever(_answering([_goPoint])),
          options: const NodeOptions(name: 'kb search'),
        )
        ..addEdge(Graph.start, 'search')
        ..addEdge('search', Graph.end);
      final runnable = await graph.compile(_ctx);

      final docs = await runnable.invoke(
        _ctx,
        'q',
        options: [CallOption.callbacks([recorder.handler])],
      );

      expect(docs.single.content, 'Test content 1');
      final retrieverEvents =
          recorder.events.where((e) => e.contains(' retriever ')).toList();
      expect(retrieverEvents, [
        'start retriever Qdrant "kb search"',
        'end retriever Qdrant "kb search"',
      ]);
    });
  });

  test('round trip: what the Qdrant indexer stores, the retriever finds',
      () async {
    final fake = FakeQdrant();
    final client = QdrantClient(httpClient: fake.client);
    final vectors = {
      'Eiffel Tower: Paris, France': [1.0, 0.0, 0.0],
      'Great Wall: China': [0.0, 1.0, 0.0],
      'Louvre Museum: Paris, France': [0.9, 0.1, 0.0],
      'tourist attraction in Paris': [1.0, 0.05, 0.0],
    };
    final embedder = _TableEmbedder(vectors);
    final indexer = await QdrantIndexer.create(
      _ctx,
      QdrantIndexerConfig(
        client: client,
        collection: _collection,
        vectorDim: 3,
        distance: QdrantDistance.cosine,
        embedding: embedder,
      ),
    );
    await indexer.store(_ctx, const [
      Document(
        id: '00000000-0000-4000-8000-000000000001',
        content: 'Eiffel Tower: Paris, France',
        metadata: {'country': 'France', 'built': 1889},
      ),
      Document(
        id: '00000000-0000-4000-8000-000000000002',
        content: 'Great Wall: China',
        metadata: {'country': 'China'},
      ),
      Document(
        id: '00000000-0000-4000-8000-000000000003',
        content: 'Louvre Museum: Paris, France',
        metadata: {'country': 'France'},
      ),
    ]);
    final retriever = QdrantRetriever(
      QdrantRetrieverConfig(
        client: client,
        collection: _collection,
        embedding: embedder,
        topK: 2,
      ),
    );

    final docs = await retriever.retrieve('tourist attraction in Paris');

    expect(fake.created[_collection], {'size': 3, 'distance': 'Cosine'});
    expect([for (final d in docs) d.content], [
      'Eiffel Tower: Paris, France',
      'Louvre Museum: Paris, France',
    ]);
    expect(docs.first.id, '00000000-0000-4000-8000-000000000001');
    expect(docs.first.metadata['metadata'], {'country': 'France', 'built': 1889});
    expect(docs.first.score, greaterThan(docs.last.score!));
  });
}

/// Embeds each text as its entry in [table].
final class _TableEmbedder implements Embedder {
  _TableEmbedder(this.table);

  final Map<String, List<double>> table;

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async =>
      [for (final text in texts) table[text]!];
}
