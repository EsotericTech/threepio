// Ports eino-ext components/indexer/qdrant/indexer_test.go: TestIndexer (its
// one scenario: collection missing → CollectionExists and CreateCollection
// called, Store of two documents with batch size 10 → one Upsert, the ids
// are the document ids). Go mocks `qdrant.Client` with mockey; here the
// indexer talks REST to a fake Qdrant server (`../qdrant/fake_qdrant.dart`)
// that records the requests and answers with Qdrant's JSON shapes. Go's
// mockEmbeddingQdrant returns random vectors; the port's embedder returns
// fixed ones so that the request bodies can be checked. Nothing in the Go
// file is left out.
//
// Plus tests written for the port: the create request (vector size,
// distance), no create when the collection exists, the defaults (collection,
// batch size), batching (23 documents in batches of 10 → 3 embedder calls and
// 3 upserts), the upsert bodies (ids, vectors, payload `content`/`metadata`,
// no `wait`, as Go sets none), ids for documents without one, Go's error
// messages (embedding failed, invalid vector length, upsert failed, ensure
// collection), a payload Qdrant cannot store, the embedder of the call,
// cancellation, callbacks (start/end/error payloads, the embedder's run info,
// no handler → no wrapper, global handlers, a graph node).
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/indexer/qdrant/qdrant_indexer.dart';
import 'package:threepio_core/src/components/qdrant/qdrant_client.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/log_capture.dart';
import '../qdrant/fake_qdrant.dart';

const _collection = 'test_collection';

final _ctx = RunContext.background();

/// Go's d1 and d2.
const _d1 = Document(id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6', content: 'asd');
const _d2 = Document(
  id: '7b83aca0-5f6c-4491-8dd4-22e15e9d582e',
  content: 'qwe',
  metadata: {
    'mock_field_1': {'extra_field_1': 'asd'},
    'mock_field_2': 123,
  },
);

/// The vector [_MockEmbedder] returns for [text].
List<double> _vectorOf(String text, int dims) =>
    [for (var j = 0; j < dims; j++) (text.length * 10 + j) / 100];

/// Go's mockEmbeddingQdrant with fixed vectors: embeds every text as
/// [_vectorOf], or throws [error]. [count] overrides the number of vectors
/// returned. Records the texts and options of each call.
final class _MockEmbedder implements Embedder, TypedComponent {
  _MockEmbedder({this.dims = 4, this.error, this.count, this.type = 'Mock'});

  final int dims;
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
    final vectors = [for (final text in texts) _vectorOf(text, dims)];
    final count = this.count;
    return count == null ? vectors : vectors.take(count).toList();
  }
}

/// An embedder that does not name its implementation.
final class _AnonymousEmbedder implements Embedder {
  final List<EmbedderOptions?> seenOptions = [];

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    seenOptions.add(options);
    return [for (final text in texts) _vectorOf(text, 2)];
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

Future<QdrantIndexer> _indexer(
  FakeQdrant fake, {
  Embedder? embedding,
  String? collection = _collection,
  int? batchSize = 10,
}) =>
    QdrantIndexer.create(
      _ctx,
      QdrantIndexerConfig(
        client: QdrantClient(httpClient: fake.client),
        collection: collection,
        batchSize: batchSize,
        embedding: embedding ?? _MockEmbedder(),
        vectorDim: 4,
        distance: QdrantDistance.cosine,
      ),
    );

List<Document> _docs(int n) => [
      for (var i = 0; i < n; i++)
        Document(
          id: '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          content: 'doc $i',
        ),
    ];

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  group('TestIndexer', () {
    test('Given a Qdrant indexer with mocked client: the indexer is created, '
        'stores the documents and returns their ids', () async {
      final fake = FakeQdrant();
      final embedder = _MockEmbedder();

      final indexer = await _indexer(fake, embedding: embedder);

      // Then the indexer should be created successfully
      expect(indexer, isNotNull);

      final ids = await indexer.store(_ctx, const [_d1, _d2]);

      // Then the store operation should succeed
      expect(ids, hasLength(2));
      // And the returned IDs should match the document IDs
      expect(ids, [_d1.id, _d2.id]);
      // And the mock methods should be called correctly
      expect(fake.requestsTo('/exists', method: 'GET'), hasLength(1));
      expect(fake.requestsTo('/$_collection', method: 'PUT'), hasLength(1));
      expect(fake.upsertBodies, hasLength(1));
      expect(embedder.calls, [
        ['asd', 'qwe'],
      ]);
    });
  });

  group('create', () {
    test('creates a missing collection with the vector size and distance',
        () async {
      final fake = FakeQdrant();

      await QdrantIndexer.create(
        _ctx,
        QdrantIndexerConfig(
          client: QdrantClient(httpClient: fake.client),
          collection: 'docs',
          vectorDim: 1024,
          distance: QdrantDistance.euclid,
          embedding: _MockEmbedder(),
        ),
      );

      expect([for (final r in fake.requests) '${r.method} ${r.url.path}'], [
        'GET /collections/docs/exists',
        'PUT /collections/docs',
      ]);
      expect(fake.requests[1].body, {
        'vectors': {'size': 1024, 'distance': 'Euclid'},
      });
    });

    test('an existing collection is left as it is', () async {
      final fake = FakeQdrant(collections: [_collection]);

      await _indexer(fake);

      expect([for (final r in fake.requests) '${r.method} ${r.url.path}'], [
        'GET /collections/$_collection/exists',
      ]);
    });

    test('the defaults: collection eino_collection, batch size 10', () async {
      for (final collection in [null, '']) {
        final fake = FakeQdrant();
        final indexer =
            await _indexer(fake, collection: collection, batchSize: null);
        expect(indexer.collection, 'eino_collection');
        expect(indexer.collection, QdrantIndexer.defaultCollection);
        expect(indexer.batchSize, 10);
        expect(fake.requests.first.url.path,
            '/collections/eino_collection/exists');
      }
      final zero = await _indexer(FakeQdrant(), batchSize: 0);
      expect(zero.batchSize, QdrantIndexer.defaultBatchSize);
      expect(zero.toString(),
          'QdrantIndexer(collection: $_collection, batchSize: 10)');
    });

    test('a negative batch size is refused before any request', () async {
      final fake = FakeQdrant();

      await expectLater(
        _indexer(fake, batchSize: -1),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            '[NewIndexer] batch size may not be negative')),
      );
      expect(fake.requests, isEmpty);
    });

    test('a failed check is "[NewIndexer] failed to ensure collection"',
        () async {
      final fake = FakeQdrant()
        ..override = (_) async => qdrantError(500, 'Service internal error');

      await expectLater(
        _indexer(fake),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message',
                  '[NewIndexer] failed to ensure collection: '
                      'CollectionExists() failed: $_collection: HTTP 500: '
                      'Service internal error')
              .having((e) => e.cause, 'cause',
                  isA<QdrantException>().having((e) => e.statusCode, 'status', 500)),
        ),
      );
    });

    test('a failed creation is "[NewIndexer] failed to ensure collection"',
        () async {
      final fake = FakeQdrant()
        ..override = (request) async => request.method == 'PUT'
            ? qdrantError(400, 'Wrong input: Vector size must be at least 1')
            : null;

      await expectLater(
        _indexer(fake),
        throwsA(isA<ThreepioException>().having((e) => e.message, 'message',
            '[NewIndexer] failed to ensure collection: CreateCollection() '
                'failed: $_collection: HTTP 400: Wrong input: Vector size '
                'must be at least 1')),
      );
    });

    test('is typed Qdrant and fires its own callbacks', () async {
      final indexer = await _indexer(FakeQdrant());

      expect(indexer.componentTypeName, 'Qdrant');
      expect(componentTypeNameOf(indexer), 'Qdrant');
      expect(isCallbacksEnabled(indexer), isTrue);
      expect(indexer, isA<Indexer>());
    });
  });

  group('store', () {
    test('upserts one point per document: id, vector, content and metadata',
        () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake);

      await indexer.store(_ctx, const [_d1, _d2]);

      final upsert = fake.requestsTo('/points').single;
      expect(upsert.method, 'PUT');
      expect(upsert.url.path, '/collections/$_collection/points');
      // Go sets no `Wait`, so the server does not wait either.
      expect(upsert.url.hasQuery, isFalse);
      expect(upsert.body, {
        'points': [
          {
            'id': 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
            'vector': _vectorOf('asd', 4),
            'payload': {'content': 'asd', 'metadata': <String, Object?>{}},
          },
          {
            'id': '7b83aca0-5f6c-4491-8dd4-22e15e9d582e',
            'vector': _vectorOf('qwe', 4),
            'payload': {
              'content': 'qwe',
              'metadata': {
                'mock_field_1': {'extra_field_1': 'asd'},
                'mock_field_2': 123,
              },
            },
          },
        ],
      });
      expect(fake.points[_collection]!.keys, [_d1.id, _d2.id]);
    });

    test('23 documents in batches of 10: 3 embedder calls and 3 upserts',
        () async {
      final fake = FakeQdrant(collections: [_collection]);
      final embedder = _MockEmbedder();
      final indexer = await _indexer(fake, embedding: embedder);
      final docs = _docs(23);

      final ids = await indexer.store(_ctx, docs);

      expect(ids, [for (final doc in docs) doc.id]);
      expect([for (final call in embedder.calls) call.length], [10, 10, 3]);
      expect(embedder.calls.last, ['doc 20', 'doc 21', 'doc 22']);
      final batches = [
        for (final body in fake.upsertBodies)
          [
            for (final point in body['points']! as List<Object?>)
              (point! as Map<String, Object?>)['id'],
          ],
      ];
      expect(batches, [
        ids.sublist(0, 10),
        ids.sublist(10, 20),
        ids.sublist(20),
      ]);
      expect(fake.points[_collection], hasLength(23));
    });

    test('a batch size larger than the documents gives one batch', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake, batchSize: 100);

      await indexer.store(_ctx, _docs(7));

      expect(fake.upsertBodies, hasLength(1));
    });

    test('a batch size of 1 upserts each document alone', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake, batchSize: 1);

      await indexer.store(_ctx, _docs(3));

      expect(fake.upsertBodies, hasLength(3));
    });

    test('no documents: no request, no ids', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final embedder = _MockEmbedder();
      final indexer = await _indexer(fake, embedding: embedder);
      fake.requests.clear();

      expect(await indexer.store(_ctx, const []), isEmpty);
      expect(fake.requests, isEmpty);
      expect(embedder.calls, isEmpty);
    });

    test('a document without an id is given a random UUID', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake);

      final ids = await indexer.store(_ctx, const [
        Document(content: 'no id'),
        _d1,
        Document(content: 'no id either'),
      ]);

      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(ids[0], matches(uuid));
      expect(ids[1], _d1.id);
      expect(ids[2], matches(uuid));
      expect(ids[0], isNot(ids[2]));
      final sent = [
        for (final point in fake.upsertBodies.single['points']! as List<Object?>)
          (point! as Map<String, Object?>)['id'],
      ];
      expect(sent, ids);
    });

    test('the embedder of the call replaces the configured one', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final own = _MockEmbedder();
      final ofCall = _MockEmbedder(dims: 2);
      final indexer = await _indexer(fake, embedding: own);

      await indexer.store(
        _ctx,
        const [_d1],
        options: IndexerOptions(embedding: ofCall),
      );

      expect(own.calls, isEmpty);
      expect(ofCall.calls, [
        ['asd'],
      ]);
      final point =
          (fake.upsertBodies.single['points']! as List<Object?>).single! as Map;
      expect(point['vector'], _vectorOf('asd', 2));
    });
  });

  group('errors', () {
    test('an embedder failure is "[batchUpsert] embedding failed, …"',
        () async {
      final fake = FakeQdrant(collections: [_collection]);
      final failure = StateError('embedding failed');
      final indexer =
          await _indexer(fake, embedding: _MockEmbedder(error: failure));

      await expectLater(
        indexer.store(_ctx, const [_d1, _d2]),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message',
                  '[batchUpsert] embedding failed, Bad state: embedding failed')
              .having((e) => e.cause, 'cause', same(failure)),
        ),
      );
      expect(fake.upsertBodies, isEmpty);
    });

    test('a threepio exception of the embedder is quoted by its message',
        () async {
      final indexer = await _indexer(
        FakeQdrant(collections: [_collection]),
        embedding: _MockEmbedder(error: const ThreepioException('quota')),
      );

      await expectLater(
        indexer.store(_ctx, const [_d1]),
        throwsA(isA<ThreepioException>().having((e) => e.message, 'message',
            '[batchUpsert] embedding failed, quota')),
      );
    });

    test('a cancellation of the embedder is not wrapped', () async {
      final indexer = await _indexer(
        FakeQdrant(collections: [_collection]),
        embedding: _MockEmbedder(error: const CancelledException('stop')),
      );

      await expectLater(
        indexer.store(_ctx, const [_d1]),
        throwsA(isA<CancelledException>()),
      );
    });

    test('another number of vectors than texts is "[batchUpsert] invalid '
        'vector length"', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake, embedding: _MockEmbedder(count: 1));

      await expectLater(
        indexer.store(_ctx, const [_d1, _d2]),
        throwsA(isA<ThreepioException>().having((e) => e.message, 'message',
            '[batchUpsert] invalid vector length, expected=2, got=1')),
      );
      expect(fake.upsertBodies, isEmpty);
    });

    test('a refused upsert is "[batchUpsert] failed to upsert points to '
        'qdrant, …"', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake);
      fake.override = (request) async => request.url.path.endsWith('/points')
          ? qdrantError(
              400,
              'Wrong input: Vector dimension error: expected dim: 8, got 4',
            )
          : null;

      await expectLater(
        indexer.store(_ctx, const [_d1]),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message',
                  '[batchUpsert] failed to upsert points to qdrant, Upsert() '
                      'failed: $_collection: HTTP 400: Wrong input: Vector '
                      'dimension error: expected dim: 8, got 4')
              .having((e) => e.cause, 'cause',
                  isA<QdrantException>().having((e) => e.statusCode, 'status', 400)),
        ),
      );
    });

    test('a failure in the second batch leaves the first one stored',
        () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake, batchSize: 2);
      var upserts = 0;
      fake.override = (request) async {
        if (!request.url.path.endsWith('/points')) return null;
        upserts++;
        return upserts == 2 ? qdrantError(503, 'Service unavailable') : null;
      };

      await expectLater(
        indexer.store(_ctx, _docs(5)),
        throwsA(isA<ThreepioException>()),
      );
      expect(fake.points[_collection], hasLength(2));
      expect(upserts, 2);
    });

    test('a metadata value Qdrant cannot store is a format error and nothing '
        'is sent', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake);

      await expectLater(
        indexer.store(_ctx, [
          Document(
            id: _d1.id,
            content: 'x',
            metadata: {'created': DateTime.utc(2025)},
          ),
        ]),
        throwsA(
          isA<ThreepioFormatException>()
              .having((e) => e.message, 'message', 'invalid type: DateTime'),
        ),
      );
      expect(fake.upsertBodies, isEmpty);
    });
  });

  group('cancellation', () {
    test('a cancelled context embeds and sends nothing', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final embedder = _MockEmbedder();
      final indexer = await _indexer(fake, embedding: embedder);
      fake.requests.clear();

      await expectLater(
        indexer.store(
          RunContext.background(cancelToken: CancelToken()..cancel('stop')),
          const [_d1],
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(embedder.calls, isEmpty);
      expect(fake.requests, isEmpty);
    });

    test('cancelling while an upsert is awaited abandons the store', () async {
      final fake = FakeQdrant(collections: [_collection]);
      final indexer = await _indexer(fake, batchSize: 1);
      final sent = Completer<void>();
      fake.override = (request) {
        if (!request.url.path.endsWith('/points')) {
          return Future<http.Response?>.value();
        }
        sent.complete();
        return Completer<http.Response?>().future; // never answers
      };
      final token = CancelToken();

      final store = indexer.store(
        RunContext.background(cancelToken: token),
        _docs(3),
      );
      await sent.future;
      token.cancel('user');

      await expectLater(store, throwsA(isA<CancelledException>()));
      expect(fake.upsertBodies, hasLength(1));
    });

    test('a cancelled context fails the creation without a request', () async {
      final fake = FakeQdrant();

      await expectLater(
        QdrantIndexer.create(
          RunContext.background(cancelToken: CancelToken()..cancel()),
          QdrantIndexerConfig(
            client: QdrantClient(httpClient: fake.client),
            embedding: _MockEmbedder(),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('callbacks', () {
    test('reports the documents, then the ids', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final recorder = _Recorder();
      final indexer = await _indexer(FakeQdrant(collections: [_collection]));
      const docs = [_d1, Document(content: 'no id')];

      final ids = await indexer.store(
        _ctx.withHandlers([recorder.handler]),
        docs,
      );

      expect(recorder.events, [
        'start indexer Qdrant ""',
        'end indexer Qdrant ""',
      ]);
      final input = recorder.payloads[0]! as IndexerCallbackInput;
      expect(input.docs, docs);
      final output = recorder.payloads[1]! as IndexerCallbackOutput;
      expect(output.ids, ids);
    });

    test('a failure is reported to the error callback and rethrown', () async {
      final recorder = _Recorder();
      final indexer = await _indexer(
        FakeQdrant(collections: [_collection]),
        embedding: _MockEmbedder(count: 0),
      );

      await expectLater(
        indexer.store(_ctx.withHandlers([recorder.handler]), const [_d1]),
        throwsA(isA<ThreepioException>()),
      );
      expect(recorder.events, [
        'start indexer Qdrant ""',
        'error indexer Qdrant',
      ]);
      expect(
        recorder.errors.single,
        isA<ThreepioException>().having((e) => e.message, 'message',
            '[batchUpsert] invalid vector length, expected=1, got=0'),
      );
    });

    test('the embedder is called in a context that introduces it as an '
        'embedder', () async {
      final recorder = _Recorder();
      final embedder = _MockEmbedder();
      final indexer = await _indexer(
        FakeQdrant(collections: [_collection]),
        embedding: embedder,
      );

      await indexer.store(
        _ctx.withHandlers([recorder.handler]),
        _docs(12),
      );

      expect(embedder.seenOptions, hasLength(2));
      for (final options in embedder.seenOptions) {
        final info = options!.runContext!.runInfo!;
        expect(info.name, 'MockEmbedding');
        expect(info.type, 'Mock');
        expect(info.componentType, ComponentType.embedder);
        expect(options.runContext!.callbackHandlers, contains(recorder.handler));
      }
    });

    test('the upserts run in the context the start callback returned',
        () async {
      final fake = FakeQdrant(collections: [_collection]);
      final embedder = _MockEmbedder();
      final indexer = await _indexer(fake, embedding: embedder);
      fake.requests.clear();
      final scoped = CallbackHandlerBuilder()
          .onStart((ctx, info, input) =>
              ctx.withCancelToken(CancelToken()..cancel('handler scope')))
          .build();

      await expectLater(
        indexer.store(_ctx.withHandlers([scoped]), const [_d1]),
        throwsA(isA<CancelledException>()
            .having((e) => e.reason, 'reason', 'handler scope')),
      );
      expect(embedder.calls, isEmpty);
      expect(fake.requests, isEmpty);
    });

    test('an embedder that does not name itself is introduced as '
        '"Embedding"', () async {
      final recorder = _Recorder();
      final embedder = _AnonymousEmbedder();
      final indexer = await _indexer(
        FakeQdrant(collections: [_collection]),
        embedding: embedder,
      );

      await indexer.store(_ctx.withHandlers([recorder.handler]), const [_d1]);

      final info = embedder.seenOptions.single!.runContext!.runInfo!;
      expect(info.name, 'Embedding');
      expect(info.type, '');
    });

    test('the embedder of the call is the one introduced', () async {
      final recorder = _Recorder();
      final ofCall = _MockEmbedder(type: 'Other');
      final indexer = await _indexer(FakeQdrant(collections: [_collection]));

      await indexer.store(
        _ctx.withHandlers([recorder.handler]),
        const [_d1],
        options: IndexerOptions(embedding: ofCall),
      );

      expect(ofCall.seenOptions.single!.runContext!.runInfo!.name,
          'OtherEmbedding');
    });

    test('without handlers nothing is fired and the embedder gets the '
        'context of the call', () async {
      final embedder = _MockEmbedder();
      final indexer = await _indexer(
        FakeQdrant(collections: [_collection]),
        embedding: embedder,
      );

      await indexer.store(_ctx, const [_d1]);

      expect(embedder.seenOptions.single!.runContext, same(_ctx));
    });

    test('global handlers hear a call made with a plain context', () async {
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder.handler]);
      final indexer = await _indexer(FakeQdrant(collections: [_collection]));

      await indexer.store(_ctx, const [_d1]);

      expect(recorder.events, [
        'start indexer Qdrant ""',
        'end indexer Qdrant ""',
      ]);
    });

    test('in a graph the node keeps its name and the graph does not report '
        'the indexer a second time', () async {
      final recorder = _Recorder();
      final indexer = await _indexer(FakeQdrant(collections: [_collection]));
      final graph = Graph<List<Document>, List<String>>()
        ..addIndexerNode(
          'store',
          indexer,
          options: const NodeOptions(name: 'kb store'),
        )
        ..addEdge(Graph.start, 'store')
        ..addEdge('store', Graph.end);
      final runnable = await graph.compile(_ctx);

      final ids = await runnable.invoke(
        _ctx,
        const [_d1],
        options: [CallOption.callbacks([recorder.handler])],
      );

      expect(ids, [_d1.id]);
      final indexerEvents =
          recorder.events.where((e) => e.contains(' indexer ')).toList();
      expect(indexerEvents, [
        'start indexer Qdrant "kb store"',
        'end indexer Qdrant "kb store"',
      ]);
    });
  });
}
