// Port of eino v0.9.22 `flow/retriever/parent/parent_test.go`
// (`TestParentRetriever`) and `flow/indexer/parent/parent_test.go`
// (`TestParentIndexer`), plus the behaviour of `parent.go` (both) the Go
// tests leave out; the indexer's grouping corners are golden values from a
// run of the Go code.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/flow.dart';
import 'package:threepio_core/src/flow/retriever/parent_retriever.dart'
    show FlowParentRetriever;

final ctx = RunContext.background();

/// Go's `testRetriever` (parent): one document per character of the query,
/// its parent id that character. Records its options.
final class _TestRetriever implements Retriever {
  final List<RetrieverOptions?> options = [];

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    this.options.add(options);
    return [
      for (final char in query.split(''))
        Document(id: '', content: '', metadata: {'parent': char}),
    ];
  }
}

/// Returns [docs] for every query.
final class _FixedRetriever implements Retriever {
  _FixedRetriever(this.docs);

  final List<Document> docs;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async =>
      docs;
}

/// Go's `testIndexer`: returns the ids and checks that each starts with the
/// parent id in its metadata. Records what it stored and its options.
final class _TestIndexer implements Indexer {
  List<Document> stored = const [];
  IndexerOptions? options;
  RunContext? ctx;

  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async {
    stored = docs;
    this.options = options;
    this.ctx = ctx;
    final ret = <String>[];
    for (final d in docs) {
      ret.add(d.id!);
      if (!d.id!.startsWith(d.metadata['parent'] as String)) {
        throw const ThreepioException('invalid parent key');
      }
    }
    return ret;
  }
}

/// Go's `testTransformer`: cuts each document's content in two halves, both
/// keeping the document's id and a copy of its metadata.
final class _TestTransformer implements DocumentTransformer {
  TransformerOptions? options;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    this.options = options;
    return [
      for (final d in documents) ...[
        Document(
          id: d.id,
          content: d.content.substring(0, d.content.length ~/ 2),
          metadata: Map.of(d.metadata),
        ),
        Document(
          id: d.id,
          content: d.content.substring(d.content.length ~/ 2),
          metadata: Map.of(d.metadata),
        ),
      ],
    ];
  }
}

/// Returns documents with the given ids, contents `0`, `1`, ….
final class _IdsTransformer implements DocumentTransformer {
  _IdsTransformer(this.ids);

  final List<String?> ids;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async =>
      [for (final (i, id) in ids.indexed) Document(id: id, content: '$i')];
}

/// Throws [error].
final class _ThrowingTransformer implements DocumentTransformer {
  _ThrowingTransformer(this.error);

  final Object error;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async =>
      throw error;
}

final class _Interrupt implements InterruptSignal {
  @override
  String toString() => 'interrupt';
}

List<String> _suffixIds(RunContext ctx, String parentId, int count) => [
      for (var i = 0; i < count; i++) '${parentId}_$i',
    ];

void main() {
  group('TestParentRetriever', () {
    test('success', () async {
      final r = ParentRetriever.fromConfig(
        retriever: _TestRetriever(),
        parentIdKey: 'parent',
        origDocGetter: (ctx, ids) => [
          for (final id in ids) Document(id: id, content: ''),
        ],
      );
      final ret = await r.retrieve('123233');
      expect(ret, const [
        Document(id: '1', content: ''),
        Document(id: '2', content: ''),
        Document(id: '3', content: ''),
      ]);
    });
  });

  group('ParentRetriever.fromConfig (Dart)', () {
    test('skips sub-documents without the key or with a value that is not a '
        'string', () async {
      List<String>? seen;
      final r = ParentRetriever.fromConfig(
        retriever: _FixedRetriever(const [
          Document(content: 'a', metadata: {'pid': 'p1'}),
          Document(content: 'b', metadata: {'other': 'p9'}),
          Document(content: 'c', metadata: {'pid': 7}),
          Document(content: 'd', metadata: {'pid': null}),
          Document(content: 'e', metadata: {'pid': ''}),
          Document(content: 'f', metadata: {'pid': 'p1'}),
          Document(content: 'g', metadata: {'pid': 'p0'}),
        ]),
        parentIdKey: 'pid',
        origDocGetter: (ctx, ids) {
          seen = ids;
          return const [];
        },
      );

      await r.retrieve('q');

      expect(seen, ['p1', '', 'p0']);
    });

    test('the getter is called with no ids when nothing has a parent, and its '
        'result is returned as it is', () async {
      List<String>? seen;
      const parents = [Document(id: 'x', content: 'whole', score: 0.5)];
      final r = ParentRetriever.fromConfig(
        retriever: _FixedRetriever(const []),
        parentIdKey: 'pid',
        origDocGetter: (ctx, ids) async {
          seen = ids;
          return parents;
        },
      );

      expect(await r.retrieve('q'), same(parents));
      expect(seen, isEmpty);
    });

    test('the options go to the inner retriever as they are; the getter gets '
        'the run context', () async {
      final inner = _TestRetriever();
      RunContext? seenCtx;
      final r = ParentRetriever.fromConfig(
        retriever: inner,
        parentIdKey: 'parent',
        origDocGetter: (ctx, ids) {
          seenCtx = ctx;
          return const [];
        },
      );
      final runCtx = RunContext.background();
      final options = RetrieverOptions(topK: 3, runContext: runCtx);

      await r.retrieve('1', options: options);

      expect(inner.options.single, same(options));
      expect(seenCtx, same(runCtx));
    });

    test('failures of the inner retriever and of the getter are rethrown',
        () async {
      final failing = ParentRetriever.fromConfig(
        retriever: _FixedRetriever(const [
          Document(content: 'a', metadata: {'pid': 'p'}),
        ]),
        parentIdKey: 'pid',
        origDocGetter: (ctx, ids) => throw StateError('store down'),
      );
      await expectLater(failing.retrieve('q'), throwsStateError);
    });

    test('is a plain Retriever, not typed and not callback-aware', () {
      final r = ParentRetriever.fromConfig(
        retriever: _TestRetriever(),
        parentIdKey: 'parent',
        origDocGetter: (ctx, ids) => const [],
      );
      expect(r, isA<FlowParentRetriever>());
      expect(r, isNot(isA<ParentRetriever>()));
      expect(componentTypeNameOf(r), isNull);
      expect(isCallbacksEnabled(r), isFalse);
      expect('$r', contains('parentIdKey: parent'));
    });

    test('works with ParentIndexer as a chain of indexing and retrieval',
        () async {
      final store = <String, Document>{};
      final indexer = ParentIndexer(
        indexer: _MapIndexer(store),
        transformer: _TestTransformer(),
        parentIdKey: 'parent_id',
        subIdGenerator: _suffixIds,
      );
      const parents = [
        Document(id: 'doc1', content: 'aaaaBBBB'),
        Document(id: 'doc2', content: 'ccccDDDD'),
      ];
      await indexer.store(ctx, parents);
      final retriever = ParentRetriever.fromConfig(
        retriever: _ContainsRetriever(store),
        parentIdKey: 'parent_id',
        origDocGetter: (ctx, ids) => [
          for (final id in ids) parents.firstWhere((p) => p.id == id),
        ],
      );
      final chain = Chain<String, List<Document>>()..appendRetriever(retriever);
      final runnable = await chain.compile(ctx);

      expect(store.keys, ['doc1_0', 'doc1_1', 'doc2_0', 'doc2_1']);
      expect([for (final d in await runnable.invoke(ctx, 'DDDD')) d.id], ['doc2']);
      expect(
        [for (final d in await runnable.invoke(ctx, 'B')) d.content],
        ['aaaaBBBB'],
      );
    });
  });

  group('TestParentIndexer', () {
    test('success', () async {
      final index = ParentIndexer(
        indexer: _TestIndexer(),
        transformer: _TestTransformer(),
        parentIdKey: 'parent',
        subIdGenerator: (ctx, parentId, num) => [
          for (var i = 0; i < num; i++) '$parentId$i',
        ],
      );
      final ret = await index.store(ctx, const [
        Document(id: 'id', content: '1234567890'),
        Document(id: 'ID', content: '0987654321'),
      ]);
      expect(ret, ['id0', 'id1', 'ID0', 'ID1']);
    });
  });

  group('ParentIndexer (Dart)', () {
    test('groups consecutive sub-documents by id, as Go does (golden)',
        () async {
      final calls = <String>[];
      final indexer = ParentIndexer(
        indexer: _RecordingIndexer(null),
        transformer: _IdsTransformer(['a', 'a', 'b', 'a', '', null]),
        parentIdKey: 'pid',
        subIdGenerator: (ctx, parentId, count) {
          calls.add('$parentId:$count');
          return _suffixIds(ctx, parentId, count);
        },
      );

      final ids = await indexer.store(ctx, const [Document(id: 'x', content: '')]);

      // Golden values from eino v0.9.22 (scratchpad/p10/goprobe).
      expect(ids, ['a_0', 'a_1', 'b_0', 'a_0', '_0', '_1']);
      expect(calls, ['a:2', 'b:1', 'a:1', ':2']);
      expect(
        [
          for (final d in (indexer.indexer as _RecordingIndexer).stored)
            '${d.id}|${d.content}|${d.metadata}',
        ],
        [
          'a_0|0|{pid: a}',
          'a_1|1|{pid: a}',
          'b_0|2|{pid: b}',
          'a_0|3|{pid: a}',
          '_0|4|{pid: }',
          '_1|5|{pid: }',
        ],
      );
    });

    test('keeps the metadata of the sub-documents and overwrites the key',
        () async {
      final recording = _RecordingIndexer(null);
      final indexer = ParentIndexer(
        indexer: recording,
        transformer: _TestTransformer(),
        parentIdKey: 'pid',
        subIdGenerator: _suffixIds,
      );

      await indexer.store(ctx, const [
        Document(id: 'd', content: 'abcd', metadata: {'lang': 'en', 'pid': 'old'}),
      ]);

      expect([for (final d in recording.stored) d.metadata], [
        {'lang': 'en', 'pid': 'd'},
        {'lang': 'en', 'pid': 'd'},
      ]);
      expect([for (final d in recording.stored) d.content], ['ab', 'cd']);
    });

    test('a single sub-document gets one id', () async {
      final indexer = ParentIndexer(
        indexer: _RecordingIndexer(null),
        transformer: _IdsTransformer(['only']),
        parentIdKey: 'pid',
        subIdGenerator: _suffixIds,
      );
      expect(await indexer.store(ctx, const []), ['only_0']);
    });

    test('the input documents are not changed', () async {
      final metadata = <String, dynamic>{'k': 'v'};
      final input = [Document(id: 'd', content: 'abcd', metadata: metadata)];
      final indexer = ParentIndexer(
        indexer: _RecordingIndexer(null),
        transformer: _PassThroughTransformer(),
        parentIdKey: 'pid',
        subIdGenerator: _suffixIds,
      );

      await indexer.store(ctx, input);

      expect(input.single.id, 'd');
      expect(metadata, {'k': 'v'});
    });

    test('the transformer gets the run context; the inner indexer gets the '
        'context and the options', () async {
      final transformer = _TestTransformer();
      final inner = _TestIndexer();
      final indexer = ParentIndexer(
        indexer: inner,
        transformer: transformer,
        parentIdKey: 'parent',
        subIdGenerator: _suffixIds,
      );
      final runCtx = RunContext.background();
      const options = IndexerOptions(index: 'kb');

      await indexer.store(
        runCtx,
        const [Document(id: 'p', content: 'xy')],
        options: options,
      );

      expect(transformer.options!.runContext, same(runCtx));
      expect(inner.ctx, same(runCtx));
      expect(inner.options, same(options));
    });

    test('a failing transformer is wrapped as Go wraps it', () async {
      final indexer = ParentIndexer(
        indexer: _RecordingIndexer(null),
        transformer: _ThrowingTransformer(const ThreepioException('split failed')),
        parentIdKey: 'pid',
        subIdGenerator: _suffixIds,
      );

      await expectLater(
        indexer.store(ctx, const []),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'transform docs fail: split failed')
              .having((e) => e.cause, 'cause', isA<ThreepioException>()),
        ),
      );
    });

    test('an interrupt from the transformer passes through unwrapped',
        () async {
      final interrupt = _Interrupt();
      final indexer = ParentIndexer(
        indexer: _RecordingIndexer(null),
        transformer: _ThrowingTransformer(interrupt),
        parentIdKey: 'pid',
        subIdGenerator: _suffixIds,
      );

      await expectLater(indexer.store(ctx, const []), throwsA(same(interrupt)));
    });

    test('a transformer that returns nothing is an error', () async {
      final indexer = ParentIndexer(
        indexer: _RecordingIndexer(null),
        transformer: _IdsTransformer([]),
        parentIdKey: 'pid',
        subIdGenerator: _suffixIds,
      );

      await expectLater(
        indexer.store(ctx, const [Document(id: 'x', content: 'x')]),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'doc transformer returned no documents',
          ),
        ),
      );
    });

    test('a generator that returns the wrong number of ids is an error, in '
        'the middle and at the end', () async {
      for (final ids in [
        ['a', 'b'],
        ['a', 'a'],
      ]) {
        final recording = _RecordingIndexer(null);
        final indexer = ParentIndexer(
          indexer: recording,
          transformer: _IdsTransformer(ids),
          parentIdKey: 'pid',
          subIdGenerator: (ctx, parentId, count) => [parentId, parentId, parentId],
        );

        await expectLater(
          indexer.store(ctx, const []),
          throwsA(
            isA<ThreepioException>().having(
              (e) => e.message,
              'message',
              "generated sub IDs' num is unexpected",
            ),
          ),
          reason: '$ids',
        );
        expect(recording.stored, isEmpty);
      }
    });

    test('what the generator and the indexer throw is rethrown as it is',
        () async {
      final generatorError = StateError('no ids');
      final failingGenerator = ParentIndexer(
        indexer: _RecordingIndexer(null),
        transformer: _IdsTransformer(['a']),
        parentIdKey: 'pid',
        subIdGenerator: (ctx, parentId, count) async => throw generatorError,
      );
      await expectLater(
        failingGenerator.store(ctx, const []),
        throwsA(same(generatorError)),
      );

      final failingIndexer = ParentIndexer(
        indexer: _TestIndexer(),
        transformer: _IdsTransformer(['a']),
        parentIdKey: 'parent',
        subIdGenerator: (ctx, parentId, count) => ['zzz'],
      );
      await expectLater(
        failingIndexer.store(ctx, const []),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'invalid parent key'),
        ),
      );
    });

    test('works as an indexer node of a chain', () async {
      final inner = _TestIndexer();
      final indexer = ParentIndexer(
        indexer: inner,
        transformer: _TestTransformer(),
        parentIdKey: 'parent',
        subIdGenerator: _suffixIds,
      );
      final chain = Chain<List<Document>, List<String>>()..appendIndexer(indexer);
      final runnable = await chain.compile(ctx);

      expect(
        await runnable.invoke(ctx, const [Document(id: 'p', content: 'abcd')]),
        ['p_0', 'p_1'],
      );
    });
  });
}

/// Records what it is asked to store, then hands it to [inner] (or returns
/// the ids).
final class _RecordingIndexer implements Indexer {
  _RecordingIndexer(this.inner);

  final Indexer? inner;
  List<Document> stored = const [];

  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async {
    stored = docs;
    final inner = this.inner;
    if (inner != null) return inner.store(ctx, docs, options: options);
    return [for (final d in docs) d.id!];
  }
}

/// Stores documents in [store] by id.
final class _MapIndexer implements Indexer {
  _MapIndexer(this.documents);

  final Map<String, Document> documents;

  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async {
    for (final d in docs) {
      documents[d.id!] = d;
    }
    return [for (final d in docs) d.id!];
  }
}

/// Finds the stored documents whose content contains the query.
final class _ContainsRetriever implements Retriever {
  _ContainsRetriever(this.store);

  final Map<String, Document> store;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async =>
      [for (final d in store.values) if (d.content.contains(query)) d];
}

/// Returns the documents it is given.
final class _PassThroughTransformer implements DocumentTransformer {
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async =>
      documents;
}
