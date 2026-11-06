// Port of eino-ext `components/embedding/cache/embedding_test.go`
// (TestEmbedder_EmbedStrings: "all cache hit", "partial cache hit", "all
// cache miss", "cache get error", "underlying embedder error", "cache set
// error, ignore"). The testify mocks become the recording fakes below, which
// fail on any call the Go mock was not told to expect.
//
// Not ported: "embedder not set cacher" and "embedder not set generator".
// `CachingEmbedder` takes the cache and the key generator as required
// parameters, so the `ErrCacherRequired`/`ErrGeneratorRequired` cases cannot
// be written in Dart.
//
// The tests after the Go group were written for the port: options and run
// context passed through, order, duplicates, the vector-count checks, the
// real caches, and the callbacks (or rather their absence, as in Go).
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/embedding/caching_embedder.dart';
import 'package:threepio_core/src/components/embedding/embedding_cache.dart';
import 'package:threepio_core/src/internal/embedding_call_callbacks.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/log_capture.dart';

typedef _Get = ({RunContext ctx, String key});
typedef _Set = ({
  RunContext ctx,
  String key,
  List<double> vector,
  Duration expiration,
});

/// Go: `mockCacher`. [hits] are the keys `Get` finds; [expectedGets] and
/// [expectedSets], when given, are the only keys it may be asked for.
///
/// An unexpected call is recorded and fails the test when it ends: the
/// embedder swallows what a store throws, a `fail` inside `set` included.
final class _MockCache implements EmbeddingCache {
  _MockCache({
    this.hits = const {},
    this.expectedGets,
    this.expectedSets,
    this.getError,
    this.setError,
  }) {
    addTearDown(() => expect(unexpected, isEmpty, reason: 'unexpected calls'));
  }

  final Map<String, List<double>> hits;
  final Set<String>? expectedGets;
  final Set<String>? expectedSets;
  final Object? getError;
  final Object? setError;

  final List<_Get> gets = [];
  final List<_Set> sets = [];
  final List<String> unexpected = [];

  @override
  Future<List<double>?> get(RunContext ctx, String key) async {
    gets.add((ctx: ctx, key: key));
    final expected = expectedGets;
    if (expected != null && !expected.contains(key)) {
      unexpected.add('Get($key)');
      fail('unexpected Get($key)');
    }
    final error = getError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    return hits[key];
  }

  @override
  Future<void> set(
    RunContext ctx,
    String key,
    List<double> vector,
    Duration expiration,
  ) async {
    sets.add((ctx: ctx, key: key, vector: vector, expiration: expiration));
    final expected = expectedSets;
    if (expected != null && !expected.contains(key)) {
      unexpected.add('Set($key)');
      fail('unexpected Set($key)');
    }
    final error = setError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
  }
}

/// Go: `mockEmbedder`. Answers with [respond], or fails with [error]; with
/// neither, a call is a test failure (the Go mock had no expectation).
final class _MockEmbedder extends Embedder {
  _MockEmbedder({this.respond, this.error});

  final List<List<double>> Function(List<String> texts)? respond;
  final Object? error;
  final List<({List<String> texts, EmbedderOptions? options})> calls = [];

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    calls.add((texts: List.of(texts), options: options));
    final error = this.error;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    final respond = this.respond;
    if (respond == null) fail('unexpected EmbedStrings($texts)');
    return respond(texts);
  }
}

/// Embeds a text as `[length, index in the call]`, so a test can tell which
/// call and which position a vector came from.
List<List<double>> _byLength(List<String> texts) => [
      for (var i = 0; i < texts.length; i++)
        [texts[i].length.toDouble(), i.toDouble()],
    ];

/// An embedder that reports its own calls, as the providers do.
final class _ReportingEmbedder extends Embedder
    implements TypedComponent, CallbackAwareComponent {
  int calls = 0;

  @override
  String get componentTypeName => 'Fake';

  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) =>
      EmbeddingCallCallbacks.run(
        options,
        typeName: componentTypeName,
        texts: texts,
        embed: () async {
          calls++;
          return (vectors: _byLength(texts), usage: null);
        },
      );
}

final class _Interrupted implements InterruptSignal {
  const _Interrupted();
}

void main() {
  const generator = SimpleCacheKeyGenerator();
  final ctx = RunContext.background();

  group('TestEmbedder_EmbedStrings', () {
    const texts = ['foo', 'bar'];
    const embeddings = [
      [1.1, 2.2],
      [3.3, 4.4],
    ];
    const expiration = Duration(minutes: 1);
    const generatorOpt = CacheKeyOptions();
    final key0 = generator.generate(ctx, texts[0], generatorOpt);
    final key1 = generator.generate(ctx, texts[1], generatorOpt);

    test('all cache hit', () async {
      failOnLoggedWarnings('threepio.embedding');
      final mc = _MockCache(
        hits: {key0: embeddings[0], key1: embeddings[1]},
        expectedGets: {key0, key1},
        expectedSets: {},
      );
      final me = _MockEmbedder();
      final e = CachingEmbedder(
        me,
        cache: mc,
        keyGenerator: generator,
        expiration: expiration,
      );

      final result = await e.embedStrings(texts);

      expect(result, embeddings);
      expect(mc.gets.map((g) => g.key), [key0, key1]);
      expect(mc.sets, isEmpty);
      expect(me.calls, isEmpty);
    });

    test('partial cache hit', () async {
      failOnLoggedWarnings('threepio.embedding');
      final mc = _MockCache(
        hits: {key1: embeddings[1]},
        expectedGets: {key0, key1},
        expectedSets: {key0},
      );
      final me = _MockEmbedder(respond: (_) => [embeddings[0]]);
      final e = CachingEmbedder(
        me,
        cache: mc,
        keyGenerator: generator,
        expiration: expiration,
      );

      final result = await e.embedStrings(texts);

      expect(result, embeddings);
      expect(me.calls.single.texts, [texts[0]]);
      expect(mc.sets, hasLength(1));
      expect(mc.sets.single.key, key0);
      expect(mc.sets.single.vector, embeddings[0]);
      expect(mc.sets.single.expiration, expiration);
    });

    test('all cache miss', () async {
      failOnLoggedWarnings('threepio.embedding');
      final mc = _MockCache(
        expectedGets: {key0, key1},
        expectedSets: {key0, key1},
      );
      final me = _MockEmbedder(respond: (_) => embeddings);
      final e = CachingEmbedder(
        me,
        cache: mc,
        keyGenerator: generator,
        expiration: expiration,
      );

      final result = await e.embedStrings(texts);

      expect(result, embeddings);
      expect(me.calls.single.texts, texts);
      expect(mc.sets.map((s) => s.key), [key0, key1]);
      expect(mc.sets.map((s) => s.vector), embeddings);
      expect(mc.sets.map((s) => s.expiration), [expiration, expiration]);
    });

    test('cache get error', () async {
      final mc = _MockCache(
        expectedGets: {key0},
        expectedSets: {},
        getError: Exception('cache error'),
      );
      final me = _MockEmbedder();
      final e = CachingEmbedder(
        me,
        cache: mc,
        keyGenerator: generator,
        expiration: expiration,
      );

      await expectLater(
        e.embedStrings([texts[0]]),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('cache error'),
        )),
      );
      expect(mc.gets, hasLength(1));
      expect(me.calls, isEmpty);
    });

    test('underlying embedder error', () async {
      final mc = _MockCache(expectedGets: {key0}, expectedSets: {});
      final me = _MockEmbedder(error: Exception('embed error'));
      final e = CachingEmbedder(
        me,
        cache: mc,
        keyGenerator: generator,
        expiration: expiration,
      );

      await expectLater(
        e.embedStrings([texts[0]]),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('embed error'),
        )),
      );
      expect(me.calls.single.texts, [texts[0]]);
      expect(mc.sets, isEmpty);
    });

    test('cache set error, ignore', () async {
      final logs = captureLogs('threepio.embedding');
      final mc = _MockCache(
        expectedGets: {key0},
        expectedSets: {key0},
        setError: Exception('set error'),
      );
      final me = _MockEmbedder(respond: (_) => [embeddings[0]]);
      final e = CachingEmbedder(
        me,
        cache: mc,
        keyGenerator: generator,
        expiration: expiration,
      );

      final result = await e.embedStrings([texts[0]]);

      expect(result, [embeddings[0]]);
      expect(mc.sets.single.key, key0);
      // Dart extra: the ignored failure is logged.
      expect(logs.single.level, Level.WARNING);
      expect(logs.single.error.toString(), contains('set error'));
    });
  });

  group('CachingEmbedder', () {
    test('stores for two hours unless told otherwise, as Go', () async {
      expect(CachingEmbedder.defaultExpiration, const Duration(hours: 2));
      final mc = _MockCache();
      final e = CachingEmbedder(
        _MockEmbedder(respond: _byLength),
        cache: mc,
        keyGenerator: generator,
      );
      expect(e.expiration, const Duration(hours: 2));

      await e.embedStrings(['a']);

      expect(mc.sets.single.expiration, const Duration(hours: 2));
    });

    test('keys use the model of the call; the options go on unchanged', () async {
      final mc = _MockCache(hits: {'cached-m': const [9.0]});
      final me = _MockEmbedder(respond: _byLength);
      final e = CachingEmbedder(me, cache: mc, keyGenerator: generator);
      final options = EmbedderOptions(
        model: 'm',
        extra: const {'dimensions': 2},
        runContext: ctx,
        extensions: const ['impl'],
      );

      final result = await e.embedStrings(['cached', 'new'], options: options);

      expect(result, [
        [9.0],
        [3.0, 0.0],
      ]);
      expect(mc.gets.map((g) => g.key), ['cached-m', 'new-m']);
      expect(mc.sets.single.key, 'new-m');
      expect(me.calls.single.options, same(options));
    });

    test('without a model the keys end in a dash (Go zero value)', () async {
      final mc = _MockCache();
      final e = CachingEmbedder(
        _MockEmbedder(respond: _byLength),
        cache: mc,
        keyGenerator: generator,
      );

      await e.embedStrings(['x'], options: const EmbedderOptions());

      expect(mc.gets.single.key, 'x-');
    });

    test('passes the run context of the options to the generator and cache',
        () async {
      final seen = <RunContext>[];
      final mc = _MockCache();
      final e = CachingEmbedder(
        _MockEmbedder(respond: _byLength),
        cache: mc,
        keyGenerator: _RecordingGenerator(seen),
      );
      final callCtx = RunContext.background();

      await e.embedStrings(['a'], options: EmbedderOptions(runContext: callCtx));

      expect(seen.single, same(callCtx));
      expect(mc.gets.single.ctx, same(callCtx));
      expect(mc.sets.single.ctx, same(callCtx));
    });

    test('uses one background context for a call without a run context',
        () async {
      final seen = <RunContext>[];
      final mc = _MockCache();
      final e = CachingEmbedder(
        _MockEmbedder(respond: _byLength),
        cache: mc,
        keyGenerator: _RecordingGenerator(seen),
      );

      await e.embedStrings(['a', 'b']);

      expect(seen, hasLength(2));
      expect(seen[1], same(seen[0]));
      expect(mc.gets.map((g) => g.ctx), everyElement(same(seen[0])));
      expect(mc.sets.map((s) => s.ctx), everyElement(same(seen[0])));
      expect(seen[0].cancelToken.isCancelled, isFalse);
    });

    test('keeps the order of the texts with hits and misses interleaved',
        () async {
      final mc = _MockCache(hits: {
        'bb-': const [-2.0],
        'dddd-': const [-4.0],
      });
      final me = _MockEmbedder(respond: _byLength);
      final e = CachingEmbedder(me, cache: mc, keyGenerator: generator);

      final result = await e.embedStrings(['a', 'bb', 'ccc', 'dddd', 'eeeee']);

      expect(me.calls.single.texts, ['a', 'ccc', 'eeeee']);
      expect(result, [
        [1.0, 0.0],
        [-2.0],
        [3.0, 1.0],
        [-4.0],
        [5.0, 2.0],
      ]);
      expect(mc.sets.map((s) => s.key), ['a-', 'ccc-', 'eeeee-']);
      expect(mc.sets.map((s) => s.vector), [
        [1.0, 0.0],
        [3.0, 1.0],
        [5.0, 2.0],
      ]);
    });

    test('embeds a missed text as often as it appears, as Go', () async {
      final mc = _MockCache();
      final me = _MockEmbedder(respond: _byLength);
      final e = CachingEmbedder(me, cache: mc, keyGenerator: generator);

      final result = await e.embedStrings(['dup', 'dup']);

      expect(me.calls.single.texts, ['dup', 'dup']);
      expect(mc.gets.map((g) => g.key), ['dup-', 'dup-']);
      expect(mc.sets.map((s) => s.key), ['dup-', 'dup-']);
      expect(result, [
        [3.0, 0.0],
        [3.0, 1.0],
      ]);
    });

    test('no texts: no lookup and no call to the embedder', () async {
      final mc = _MockCache(expectedGets: {}, expectedSets: {});
      final me = _MockEmbedder();
      final e = CachingEmbedder(me, cache: mc, keyGenerator: generator);

      expect(await e.embedStrings(const []), isEmpty);
      expect(me.calls, isEmpty);
    });

    test('stops at the first lookup that fails', () async {
      final mc = _MockCache(getError: StateError('down'));
      final e = CachingEmbedder(_MockEmbedder(), cache: mc, keyGenerator: generator);

      await expectLater(e.embedStrings(['a', 'b']), throwsStateError);
      expect(mc.gets.map((g) => g.key), ['a-']);
    });

    test('fewer vectors than texts is an error, and nothing is cached',
        () async {
      final mc = _MockCache();
      final me = _MockEmbedder(respond: (texts) => [const [1.0]]);
      final e = CachingEmbedder(me, cache: mc, keyGenerator: generator);

      await expectLater(
        e.embedStrings(['a', 'b']),
        throwsA(isA<ThreepioException>().having(
          (e) => e.message,
          'message',
          allOf(contains('1 vectors'), contains('2 texts')),
        )),
      );
      expect(mc.sets, isEmpty);
    });

    test('extra vectors are ignored, as Go', () async {
      final mc = _MockCache();
      final me = _MockEmbedder(
        respond: (texts) => const [
          [1.0],
          [2.0],
          [3.0],
        ],
      );
      final e = CachingEmbedder(me, cache: mc, keyGenerator: generator);

      expect(await e.embedStrings(['a', 'b']), [
        [1.0],
        [2.0],
      ]);
      expect(mc.sets, hasLength(2));
    });

    test('an interrupt thrown by the cache store gets through', () async {
      final mc = _MockCache(setError: const _Interrupted());
      final e = CachingEmbedder(
        _MockEmbedder(respond: _byLength),
        cache: mc,
        keyGenerator: generator,
      );

      await expectLater(e.embedStrings(['a']), throwsA(isA<_Interrupted>()));
    });

    test('with an in-memory cache, a second call hits', () async {
      final me = _MockEmbedder(respond: _byLength);
      final e = CachingEmbedder(
        me,
        cache: InMemoryEmbeddingCache(),
        keyGenerator: const HashCacheKeyGenerator(_xorDigest),
      );

      final first = await e.embedStrings(['one', 'three']);
      final second = await e.embedStrings(['three', 'one', 'four']);
      final otherModel = await e.embedStrings(
        ['one'],
        options: const EmbedderOptions(model: 'other'),
      );

      expect(first, [
        [3.0, 0.0],
        [5.0, 1.0],
      ]);
      expect(second, [
        [5.0, 1.0],
        [3.0, 0.0],
        [4.0, 0.0],
      ]);
      expect(otherModel, [
        [3.0, 0.0],
      ]);
      expect(me.calls.map((c) => c.texts), [
        ['one', 'three'],
        ['four'],
        ['one'],
      ]);
    });

    test('is neither typed nor callback-aware, like Go cache.Embedder', () {
      final e = CachingEmbedder(
        _MockEmbedder(),
        cache: InMemoryEmbeddingCache(),
        keyGenerator: generator,
      );

      expect(componentTypeNameOf(e), isNull);
      expect(isCallbacksEnabled(e), isFalse);
    });

    test('in a chain, the node reports the call and the inner embedder only '
        'its misses', () async {
      final events = <String>[];
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            if (info.componentType == ComponentType.embedder) {
              final texts = EmbeddingCallbackInput.from(input)?.texts;
              events.add('start ${info.type} $texts');
            }
            return ctx;
          })
          .onEnd((ctx, info, output) {
            if (info.componentType == ComponentType.embedder) {
              final n = EmbeddingCallbackOutput.from(output)?.embeddings.length;
              events.add('end ${info.type} $n');
            }
            return ctx;
          })
          .build();
      final runCtx = RunContext.background().withHandlers([handler]);
      final inner = _ReportingEmbedder();
      final chain = Chain<List<String>, List<List<double>>>()
        ..appendEmbedding(
          CachingEmbedder(
            inner,
            cache: InMemoryEmbeddingCache(),
            keyGenerator: generator,
          ),
        );
      final runnable = await chain.compile(runCtx);

      await runnable.invoke(runCtx, ['a', 'bb']);
      expect(events, [
        'start CachingEmbedder [a, bb]',
        'start Fake [a, bb]',
        'end Fake 2',
        'end CachingEmbedder 2',
      ]);

      events.clear();
      await runnable.invoke(runCtx, ['bb', 'ccc']);
      expect(events, [
        'start CachingEmbedder [bb, ccc]',
        'start Fake [ccc]',
        'end Fake 1',
        'end CachingEmbedder 2',
      ]);

      events.clear();
      await runnable.invoke(runCtx, ['a', 'ccc']);
      expect(events, [
        'start CachingEmbedder [a, ccc]',
        'end CachingEmbedder 2',
      ]);
      expect(inner.calls, 2);
    });
  });
}

/// A generator that records the contexts it is given.
final class _RecordingGenerator implements CacheKeyGenerator {
  _RecordingGenerator(this.seen);

  final List<RunContext> seen;

  @override
  String generate(RunContext ctx, String text, CacheKeyOptions options) {
    seen.add(ctx);
    return const SimpleCacheKeyGenerator().generate(ctx, text, options);
  }
}

/// A toy four-byte digest: the bytes folded into four lanes.
List<int> _xorDigest(List<int> bytes) {
  final digest = [0, 0, 0, 0];
  for (var i = 0; i < bytes.length; i++) {
    digest[i % 4] = (digest[i % 4] * 31 + bytes[i]) & 0xff;
  }
  return digest;
}
