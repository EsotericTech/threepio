// Port of eino v0.9.22 `flow/retriever/router/router_test.go`
// (`TestRouterRetriever`, `TestRRF`), plus the behaviour of `router.go` the
// Go tests leave out: the defaults (all retrievers, RRF), the failures and
// their callbacks, the options, and the order of equal RRF scores.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/flow.dart';
import 'package:threepio_core/src/flow/retriever/router_retriever.dart'
    show FlowRouterRetriever, rrfFusion;

import '../support/log_capture.dart';

final ctx = RunContext.background();

/// Go's `mockRetriever`: one document per digit 1–5 in the query; says it is
/// `Mock`.
final class _MockRetriever implements Retriever, TypedComponent {
  final List<RetrieverOptions?> options = [];

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    this.options.add(options);
    return [
      for (final digit in ['1', '2', '3', '4', '5'])
        if (query.contains(digit)) Document(id: digit, content: digit),
    ];
  }

  @override
  String get componentTypeName => 'Mock';
}

/// Returns [docs] for every query.
final class _FixedRetriever implements Retriever {
  _FixedRetriever(this.docs);

  final List<Document> docs;
  int calls = 0;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    calls++;
    return docs;
  }
}

/// Fails with [error] after [delay] event-loop turns.
final class _FailingRetriever implements Retriever {
  _FailingRetriever(this.error, {this.delay = 0});

  final Object error;
  final int delay;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    for (var i = 0; i < delay; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    throw error;
  }
}

/// Records the values of [runKey] and [routerKey] in its run context.
final class _ContextRetriever implements Retriever {
  _ContextRetriever(this.runKey, this.routerKey, this.seen);

  final ContextKey<String> runKey;
  final ContextKey<String> routerKey;
  final List<String> seen;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    final ctx = options!.runContext!;
    seen.add('retriever ${ctx.value(runKey)} ${ctx.value(routerKey)}');
    return [_doc('1')];
  }
}

Document _doc(String id, [String? content]) =>
    Document(id: id, content: content ?? id);

List<String?> _ids(List<Document> docs) => [for (final d in docs) d.id];

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  test('TestRouterRetriever', () async {
    failOnLoggedWarnings('threepio.callbacks');
    final r = RouterRetriever.fromConfig(
      retrievers: {
        '1': _MockRetriever(),
        '2': _MockRetriever(),
        '3': _MockRetriever(),
      },
      router: (ctx, query) => ['2', '3'],
      fusion: (ctx, result) => [for (final v in result.values) ...v],
    );

    final ends = <String>[];
    final errors = <Object>[];
    final handler = CallbackHandlerBuilder()
        .onEnd((ctx, info, output) {
          switch (info.name) {
            case 'FusionFuncLambda':
              expect(output, isA<List<Document>>());
            case 'RouterLambda':
              expect(output, isA<List<String>>());
            case 'MockRetriever':
              expect(output, isA<List<Document>>());
            default:
              fail('unknown name: ${info.name}');
          }
          ends.add(info.name);
          return ctx;
        })
        .onError((ctx, info, error, stackTrace) {
          errors.add(error);
          return ctx;
        })
        .build();
    final runCtx = initCallbacks(ctx, RunInfo.unknown, [handler]);

    final result =
        await r.retrieve('3', options: RetrieverOptions(runContext: runCtx));

    expect(result, hasLength(2));
    expect(errors, isEmpty);
    expect(ends, [
      'RouterLambda',
      'MockRetriever',
      'MockRetriever',
      'FusionFuncLambda',
    ]);
  });

  test('TestRRF', () async {
    final doc1 = _doc('1');
    final doc2 = _doc('2');
    final doc3 = _doc('3');
    final doc4 = _doc('4');
    final doc5 = _doc('5');

    final input = {
      '1': [doc1, doc2, doc3, doc4, doc5],
      '2': [doc2, doc3, doc4, doc5, doc1],
      '3': [doc3, doc4, doc5, doc1, doc2],
    };

    final result = await rrfFusion(ctx, input);
    expect(result, [doc3, doc2, doc4, doc1, doc5]);
    for (final (i, doc) in [doc3, doc2, doc4, doc1, doc5].indexed) {
      expect(result[i], same(doc));
    }
  });

  group('RRF (Dart)', () {
    test('a single list is returned as it is', () async {
      final list = [_doc('a'), _doc('a'), _doc('b')];
      expect(await rrfFusion(ctx, {'only': list}), same(list));
    });

    test('no lists is a ThreepioException', () async {
      await expectLater(
        rrfFusion(ctx, {}),
        throwsA(
          isA<ThreepioException>().having((e) => e.message, 'message', 'no documents'),
        ),
      );
    });

    test('equal scores keep the order of first appearance; the document of '
        'the last list wins', () async {
      final result = await rrfFusion(ctx, {
        'x': [_doc('a', 'a1'), _doc('b', 'b1')],
        'y': [_doc('b', 'b2'), _doc('a', 'a2')],
        'z': [_doc('c')],
      });
      // a and b both score 1/60 + 1/61, c scores 1/60.
      expect(_ids(result), ['a', 'b', 'c']);
      expect([for (final d in result) d.content], ['a2', 'b2', 'c']);
    });

    test('documents without an id are one document', () async {
      final result = await rrfFusion(ctx, {
        'x': [const Document(content: 'first'), _doc('a')],
        'y': [const Document(id: '', content: 'second')],
      });
      expect([for (final d in result) d.content], ['second', 'a']);
    });
  });

  group('RouterRetriever.fromConfig (Dart)', () {
    test('without a router every retriever is asked, in the order given, '
        'and the results are fused by RRF', () async {
      final a = _FixedRetriever([_doc('1'), _doc('2')]);
      final b = _FixedRetriever([_doc('2'), _doc('3')]);
      String? routerOutput;
      final handler = CallbackHandlerBuilder().onEnd((ctx, info, output) {
        if (info.name == 'RouterLambda') routerOutput = '$output';
        return ctx;
      }).build();
      final r = RouterRetriever.fromConfig(retrievers: {'b': b, 'a': a});

      final result = await r.retrieve(
        'q',
        options: RetrieverOptions(runContext: ctx.withHandlers([handler])),
      );

      expect(routerOutput, '[b, a]');
      expect(a.calls, 1);
      expect(b.calls, 1);
      // 2 scores 1/60 + 1/61; 3 and 1 score 1/61 and 1/60.
      expect(_ids(result), ['2', '1', '3']);
    });

    test('the router gets the run context and the query', () async {
      final runCtx = RunContext.background();
      String? seenQuery;
      RunContext? seenCtx;
      final r = RouterRetriever.fromConfig(
        retrievers: {'a': _MockRetriever()},
        router: (ctx, query) async {
          seenCtx = ctx;
          seenQuery = query;
          return ['a'];
        },
      );

      expect(_ids(await r.retrieve('12', options: RetrieverOptions(runContext: runCtx))), [
        '1',
        '2',
      ]);
      expect(seenQuery, '12');
      // No handlers: the router runs in the caller's context itself.
      expect(seenCtx, same(runCtx));
    });

    test('the retrievals and the fusion run in the caller\'s context, not in '
        'the one the router\'s start callback returned', () async {
      final runKey = ContextKey<String>('run');
      final routerKey = ContextKey<String>('router');
      final seen = <String>[];
      final handler = CallbackHandlerBuilder().onStart((ctx, info, input) {
        if (info.name == 'RouterLambda') return ctx.withValue(routerKey, 'x');
        return ctx;
      }).build();
      final r = RouterRetriever.fromConfig(
        retrievers: {'a': _ContextRetriever(runKey, routerKey, seen)},
        router: (ctx, query) {
          seen.add('router ${ctx.value(runKey)} ${ctx.value(routerKey)}');
          return ['a'];
        },
        fusion: (ctx, result) {
          seen.add('fusion ${ctx.value(runKey)} ${ctx.value(routerKey)}');
          return result['a']!;
        },
      );
      final runCtx = ctx.withValue(runKey, 'run').withHandlers([handler]);

      await r.retrieve('q', options: RetrieverOptions(runContext: runCtx));

      expect(seen, [
        'router run x',
        'retriever run null',
        'fusion run null',
      ]);
    });

    test('no retrievers is an ArgumentError', () {
      expect(
        () => RouterRetriever.fromConfig(retrievers: {}),
        throwsA(
          isA<ArgumentError>().having((e) => e.message, 'message', 'retrievers is empty'),
        ),
      );
    });

    test('a router that picks nothing fails the call and reports it', () async {
      final errors = <String>[];
      final handler = CallbackHandlerBuilder()
          .onError((ctx, info, error, stackTrace) {
            errors.add('${info.name}: ${(error as ThreepioException).message}');
            return ctx;
          })
          .build();
      final r = RouterRetriever.fromConfig(
        retrievers: {'a': _MockRetriever()},
        router: (ctx, query) => [],
      );

      await expectLater(
        r.retrieve('q', options: RetrieverOptions(runContext: ctx.withHandlers([handler]))),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'no retriever has been selected'),
        ),
      );
      expect(errors, ['RouterLambda: no retriever has been selected']);
    });

    test('a router that fails fails the call and reports it', () async {
      final errors = <String>[];
      final handler = CallbackHandlerBuilder()
          .onError((ctx, info, error, stackTrace) {
            errors.add(info.name);
            return ctx;
          })
          .build();
      final r = RouterRetriever.fromConfig(
        retrievers: {'a': _MockRetriever()},
        router: (ctx, query) => throw StateError('router down'),
      );

      await expectLater(
        r.retrieve('q', options: RetrieverOptions(runContext: ctx.withHandlers([handler]))),
        throwsStateError,
      );
      expect(errors, ['RouterLambda']);
    });

    test('a name that is not a retriever fails the call before any retrieval',
        () async {
      final a = _FixedRetriever([_doc('1')]);
      final r = RouterRetriever.fromConfig(
        retrievers: {'a': a},
        router: (ctx, query) => ['a', 'nope'],
      );

      await expectLater(
        r.retrieve('q'),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'router output[nope] has not registered'),
        ),
      );
      expect(a.calls, 0);
    });

    test('the first failure in the order of the router fails the call',
        () async {
      final r = RouterRetriever.fromConfig(
        retrievers: {
          'ok': _FixedRetriever([_doc('1')]),
          'slow': _FailingRetriever(StateError('slow'), delay: 3),
          'fast': _FailingRetriever(StateError('fast')),
        },
        router: (ctx, query) => ['ok', 'slow', 'fast'],
      );

      await expectLater(
        r.retrieve('q'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'slow')),
      );
    });

    test('the options of the call reach every retrieval', () async {
      final a = _MockRetriever();
      final b = _MockRetriever();
      final r = RouterRetriever.fromConfig(retrievers: {'a': a, 'b': b});

      await r.retrieve('1', options: const RetrieverOptions(topK: 2, subIndex: 's'));

      for (final options in [...a.options, ...b.options]) {
        expect(options!.topK, 2);
        expect(options.subIndex, 's');
      }
    });

    test('the fusion gets the results by name; its failure is reported',
        () async {
      Object? fusionInput;
      final errors = <String>[];
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            if (info.name == 'FusionFuncLambda') fusionInput = input;
            return ctx;
          })
          .onError((ctx, info, error, stackTrace) {
            errors.add(info.name);
            return ctx;
          })
          .build();
      final r = RouterRetriever.fromConfig(
        retrievers: {'x': _MockRetriever(), 'y': _MockRetriever()},
        fusion: (ctx, result) => throw const ThreepioException('fusion down'),
      );

      await expectLater(
        r.retrieve('12', options: RetrieverOptions(runContext: ctx.withHandlers([handler]))),
        throwsA(isA<ThreepioException>()),
      );
      expect(fusionInput, isA<Map<String, List<Document>>>());
      expect((fusionInput! as Map).keys, ['x', 'y']);
      expect(errors, ['FusionFuncLambda']);
    });

    test('a router that names a retriever twice asks it twice; the last '
        'result is kept', () async {
      final a = _FixedRetriever([_doc('1')]);
      Map<String, List<Document>>? fused;
      final r = RouterRetriever.fromConfig(
        retrievers: {'a': a},
        router: (ctx, query) => ['a', 'a'],
        fusion: (ctx, result) {
          fused = result;
          return result['a']!;
        },
      );

      await r.retrieve('q');

      expect(a.calls, 2);
      expect(fused!.keys, ['a']);
    });

    test('later changes to the map given do not change the retriever',
        () async {
      final retrievers = <String, Retriever>{'a': _FixedRetriever([_doc('1')])};
      final r = RouterRetriever.fromConfig(retrievers: retrievers);
      retrievers['b'] = _FixedRetriever([_doc('2')]);

      expect(_ids(await r.retrieve('q')), ['1']);
    });

    test('is a TypedComponent named Router and not callback-aware', () {
      final r = RouterRetriever.fromConfig(retrievers: {'a': _MockRetriever()});
      expect(r, isA<FlowRouterRetriever>());
      expect(r, isNot(isA<RouterRetriever>()));
      expect(componentTypeNameOf(r), 'Router');
      expect(isCallbacksEnabled(r), isFalse);
      expect('$r', contains('[a]'));
    });

    test('works as a chain node; the chain reports it under its implementation '
        'name', () async {
      final infos = <String>[];
      final handler = CallbackHandlerBuilder().onStart((ctx, info, input) {
        infos.add('${info.componentType.name}:${info.type}:${info.name}');
        return ctx;
      }).build();
      final r = RouterRetriever.fromConfig(retrievers: {'m': _MockRetriever()});
      final chain = Chain<String, List<Document>>()..appendRetriever(r);
      final runnable = await chain.compile(ctx);

      final docs = await runnable.invoke(
        ctx,
        '45',
        options: [CallOption.callbacks([handler])],
      );

      expect(_ids(docs), ['4', '5']);
      expect(infos, contains(startsWith('retriever:Router:')));
      expect(infos, contains('lambda:Router:RouterLambda'));
      expect(infos, contains('retriever:Mock:MockRetriever'));
      expect(infos, contains('lambda:FusionFunc:FusionFuncLambda'));
    });
  });
}
