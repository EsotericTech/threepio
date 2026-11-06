// Port of eino v0.9.22 `flow/retriever/multiquery/multi_query_test.go`
// (`TestMultiQueryRetriever`), plus the behaviour of `multi_query.go` the Go
// test leaves out: the default prompt (golden, from a run of the Go code),
// the default parser, `MaxQueriesNum`, a custom template and parser, the
// fusion, failures, the callbacks, and use as a compose node.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/flow.dart';
import 'package:threepio_core/src/flow/retriever/multi_query_retriever.dart'
    show
        FlowMultiQueryRetriever,
        deduplicateFusion,
        defaultMaxQueries,
        defaultQueryVariable,
        defaultRewritePrompt;

import '../support/log_capture.dart';

final ctx = RunContext.background();

/// Go's `mockRetriever`: one document per digit 1–5 in the query, in digit
/// order. Records what it was asked.
final class _MockRetriever implements Retriever {
  final List<String> queries = [];
  final List<RetrieverOptions?> options = [];

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    queries.add(query);
    this.options.add(options);
    return [
      for (final digit in ['1', '2', '3', '4', '5'])
        if (query.contains(digit)) Document(id: digit, content: 'q=$query'),
    ];
  }
}

/// Go's `mockModel`: always answers [content]. Records its inputs.
final class _MockModel implements BaseChatModel {
  _MockModel([this.content = '12\n23\n34\n14\n23\n45']);

  final String content;
  final List<List<Message>> inputs = [];

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    inputs.add(input);
    return Message.assistant(content);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      throw UnimplementedError('implement me');
}

Future<List<Document>> _viaChain(Retriever retriever, String query) async {
  final chain = Chain<String, List<Document>>()..appendRetriever(retriever);
  final runnable = await chain.compile(ctx);
  return runnable.invoke(ctx, query);
}

List<String?> _ids(List<Document> docs) => [for (final d in docs) d.id];

void main() {
  group('TestMultiQueryRetriever', () {
    test('use default llm', () async {
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: _MockModel(),
          origRetriever: _MockRetriever(),
        ),
      );
      final result = await _viaChain(mqr, 'query');
      expect(result, hasLength(4));
    });

    test('use custom', () async {
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1', '3', '5'],
          origRetriever: _MockRetriever(),
        ),
      );
      final result = await _viaChain(mqr, 'query');
      expect(result, hasLength(3));
    });
  });

  group('MultiQueryRetriever.fromConfig (Dart)', () {
    test('the model gets eino\'s default prompt, rendered as Go renders it',
        () async {
      final model = _MockModel();
      final retriever = _MockRetriever();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(rewriteModel: model, origRetriever: retriever),
      );

      final docs = await mqr.retrieve('how to build agent with eino');

      // Golden values from eino v0.9.22 (scratchpad/p10/goprobe).
      expect(model.inputs.single, hasLength(1));
      expect(model.inputs.single.single.role, RoleType.user);
      expect(
        model.inputs.single.single.content,
        'You are an helpful assistant.\n\tYour role is to create three '
        'different versions of the user query to retrieve relevant documents '
        'from store.\n    Your goal is to improve the performance of '
        'similarity search by generating text from different perspectives '
        'based on the user query.\n\tOnly provide the generated queries and '
        'separate them by newlines. \n\tuser query: how to build agent with '
        'eino',
      );
      expect(
        [for (final d in docs) '${d.id}|${d.content}'],
        ['1|q=12', '2|q=12', '3|q=23', '4|q=34'],
      );
      // Six lines, five used.
      expect(retriever.queries, unorderedEquals(['12', '23', '34', '14', '23']));
    });

    test('the query is inserted as it is, not rendered or escaped', () async {
      final model = _MockModel();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: model,
          origRetriever: _MockRetriever(),
        ),
      );
      const query = 'a <b>&"x"\'y\' {{ z }} {% if %}';

      await mqr.retrieve(query);

      expect(
        model.inputs.single.single.content,
        endsWith('\n\tuser query: a <b>&"x"\'y\' {{ z }} {% if %}'),
      );
    });

    test('the constants are eino\'s', () {
      expect(defaultQueryVariable, 'query');
      expect(defaultMaxQueries, 5);
      expect(defaultRewritePrompt, startsWith('You are an helpful assistant.\n\t'));
      expect(defaultRewritePrompt, endsWith('newlines. \n\tuser query: {{query}}'));
      expect(defaultRewritePrompt.split('\n'), hasLength(5));
    });

    test('the default parser splits at line breaks and keeps empty lines',
        () async {
      final retriever = _MockRetriever();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: _MockModel(' 1 \n\n2'),
          origRetriever: retriever,
        ),
      );

      final docs = await mqr.retrieve('q');

      expect(retriever.queries, unorderedEquals([' 1 ', '', '2']));
      expect(_ids(docs), ['1', '2']);
    });

    test('at most maxQueries queries are retrieved, the first ones', () async {
      final retriever = _MockRetriever();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1', '2', '3', '4'],
          origRetriever: retriever,
          maxQueries: 2,
        ),
      );

      final docs = await mqr.retrieve('q');

      expect(retriever.queries, unorderedEquals(['1', '2']));
      expect(_ids(docs), ['1', '2']);
    });

    test('maxQueries of zero or less means five', () async {
      for (final maxQueries in [0, -3]) {
        final retriever = _MockRetriever();
        final mqr = await MultiQueryRetriever.fromConfig(
          ctx,
          MultiQueryRetrieverConfig(
            rewriteHandler: (ctx, query) => ['1', '2', '3', '4', '5', '1'],
            origRetriever: retriever,
            maxQueries: maxQueries,
          ),
        );
        await mqr.retrieve('q');
        expect(retriever.queries, hasLength(5), reason: '$maxQueries');
      }
    });

    test('a custom template gets the query under queryVar', () async {
      final model = _MockModel('3');
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: model,
          rewriteTemplate: ChatTemplate.fromMessages(FormatType.fString, [
            Message.system('rewrite'),
            Message.user('Q: {question}'),
          ]),
          queryVar: 'question',
          origRetriever: _MockRetriever(),
        ),
      );

      final docs = await mqr.retrieve('what is 3?');

      expect([for (final m in model.inputs.single) m.content], [
        'rewrite',
        'Q: what is 3?',
      ]);
      expect(_ids(docs), ['3']);
    });

    test('without a template queryVar is ignored', () async {
      final model = _MockModel('1');
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: model,
          queryVar: 'ignored',
          origRetriever: _MockRetriever(),
        ),
      );

      await mqr.retrieve('q');

      expect(
        model.inputs.single.single.content,
        endsWith('\n\tuser query: q'),
      );
    });

    test('a custom output parser gets the context and the message', () async {
      RunContext? seenCtx;
      Message? seenMessage;
      final retriever = _MockRetriever();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: _MockModel('4;5'),
          outputParser: (ctx, message) async {
            seenCtx = ctx;
            seenMessage = message;
            return message.content.split(';');
          },
          origRetriever: retriever,
        ),
      );

      final docs = await mqr.retrieve('q');

      expect(seenCtx, isNotNull);
      expect(seenMessage!.content, '4;5');
      expect(_ids(docs), ['4', '5']);
    });

    test('the handler takes precedence over the model', () async {
      final model = _MockModel();
      String? handled;
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: model,
          rewriteHandler: (ctx, query) {
            handled = query;
            return ['2'];
          },
          origRetriever: _MockRetriever(),
        ),
      );

      final docs = await mqr.retrieve('orig');

      expect(handled, 'orig');
      expect(model.inputs, isEmpty);
      expect(_ids(docs), ['2']);
    });

    test('neither a model nor a handler is an ArgumentError', () async {
      await expectLater(
        MultiQueryRetriever.fromConfig(
          ctx,
          MultiQueryRetrieverConfig(origRetriever: _MockRetriever()),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('rewriteHandler and rewriteModel'),
          ),
        ),
      );
    });

    test('a custom fusion gets the results in the order of the queries',
        () async {
      List<List<Document>>? seen;
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['5', '12', '5'],
          origRetriever: _MockRetriever(),
          fusion: (ctx, docs) {
            seen = docs;
            return [for (final list in docs.reversed) ...list];
          },
        ),
      );

      final docs = await mqr.retrieve('q');

      expect([for (final list in seen!) _ids(list)], [
        ['5'],
        ['1', '2'],
        ['5'],
      ]);
      expect(_ids(docs), ['5', '1', '2', '5']);
    });

    test('the default fusion keeps the first document of each id, and counts '
        'documents without an id as one', () async {
      final docs = await deduplicateFusion(ctx, const [
        [Document(id: 'a', content: '1'), Document(content: 'no id 1')],
        [
          Document(id: 'a', content: '2'),
          Document(id: '', content: 'empty id'),
          Document(id: 'b', content: '3'),
          Document(content: 'no id 2'),
        ],
      ]);
      expect([for (final d in docs) d.content], ['1', 'no id 1', '3']);
      expect(await deduplicateFusion(ctx, const []), isEmpty);
    });

    test('the retrievals run at the same time', () async {
      final started = <String>[];
      final gate = Completer<void>();
      final retriever = _GatedRetriever(started, gate.future);
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1', '2', '3'],
          origRetriever: retriever,
        ),
      );

      final result = mqr.retrieve('q');
      await pumpEventQueue();
      expect(started, unorderedEquals(['1', '2', '3']));
      gate.complete();
      expect(_ids(await result), ['1', '2', '3']);
    });

    test('the first failed retrieval in query order fails the call', () async {
      // '2' fails first in time, '3' first in the order of the queries.
      final retriever = _FailingRetriever(
        {'2': 'second', '3': 'third'},
        delays: {'3': 3},
      );
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1', '3', '2'],
          origRetriever: retriever,
        ),
      );

      await expectLater(
        mqr.retrieve('q'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'third')),
      );
    });

    test('a failing rewrite fails the call', () async {
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => throw StateError('no rewrite'),
          origRetriever: _MockRetriever(),
        ),
      );

      await expectLater(
        mqr.retrieve('q'),
        throwsA(
          predicate<Object>(
            (e) => '$e'.contains('no rewrite'),
            'mentions the failure',
          ),
        ),
      );
    });

    test('the options of the call reach every retrieval, with the run context',
        () async {
      final retriever = _MockRetriever();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1', '2'],
          origRetriever: retriever,
        ),
      );
      final runCtx = RunContext.background();

      await mqr.retrieve(
        'q',
        options: RetrieverOptions(topK: 7, index: 'kb', runContext: runCtx),
      );

      expect(retriever.options, hasLength(2));
      for (final options in retriever.options) {
        expect(options!.topK, 7);
        expect(options.index, 'kb');
        // No handlers: the retrieval runs in the caller's context itself.
        expect(options.runContext, same(runCtx));
      }
    });

    test('is a TypedComponent named MultiQuery and not callback-aware',
        () async {
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => [query],
          origRetriever: _MockRetriever(),
        ),
      );
      expect(mqr, isA<FlowMultiQueryRetriever>());
      expect(mqr, isNot(isA<MultiQueryRetriever>()));
      expect(componentTypeNameOf(mqr), 'MultiQuery');
      expect(isCallbacksEnabled(mqr), isFalse);
      expect('$mqr', contains('maxQueries: 5'));
    });

    test('works as a graph node and with call options for it', () async {
      final retriever = _MockRetriever();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => [query, '${query}5'],
          origRetriever: retriever,
        ),
      );
      final graph = Graph<String, List<Document>>()
        ..addRetrieverNode('mq', mqr)
        ..addEdge(Graph.start, 'mq')
        ..addEdge('mq', Graph.end);
      final runnable = await graph.compile(ctx);

      final docs = await runnable.invoke(
        ctx,
        '1',
        options: [CallOption.retriever(const RetrieverOptions(topK: 3))],
      );

      expect(_ids(docs), ['1', '5']);
      expect([for (final o in retriever.options) o!.topK], [3, 3]);
    });
  });

  group('callbacks', () {
    setUp(GlobalCallbacks.clear);
    tearDown(GlobalCallbacks.clear);

    test('the rewrite chain, every retrieval and the fusion report to the '
        'handlers of the run', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final starts = <String>[];
      final ends = <String, Object?>{};
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            starts.add('${info.componentType.name}:${info.name}');
            return ctx;
          })
          .onEnd((ctx, info, output) {
            ends['${info.componentType.name}:${info.name}'] = output;
            return ctx;
          })
          .build();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteModel: _MockModel('1\n2'),
          origRetriever: _TypedRetriever(),
        ),
      );

      await mqr.retrieve(
        'q',
        options: RetrieverOptions(
          runContext: RunContext.background().withHandlers([handler]),
        ),
      );

      expect(starts.first, 'chain:QueryRewrite');
      expect(
        starts,
        containsAll([
          'lambda:Converter',
          'promptTemplate:',
          'chatModel:',
          'lambda:OutputParser',
          'retriever:MockRetriever',
          'lambda:FusionFuncLambda',
        ]),
      );
      expect(starts.where((s) => s == 'retriever:MockRetriever'), hasLength(2));
      expect(starts.last, 'lambda:FusionFuncLambda');
      expect(ends['chain:QueryRewrite'], ['1', '2']);
      expect(ends['retriever:MockRetriever'], isA<List<Document>>());
      expect(_ids(ends['lambda:FusionFuncLambda']! as List<Document>), ['1', '2']);
    });

    test('the fusion input is the results by query; its failure is reported',
        () async {
      Object? fusionInput;
      Object? fusionError;
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            if (info.name == 'FusionFuncLambda') fusionInput = input;
            return ctx;
          })
          .onError((ctx, info, error, stackTrace) {
            if (info.name == 'FusionFuncLambda') fusionError = error;
            return ctx;
          })
          .build();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1', '2'],
          origRetriever: _MockRetriever(),
          fusion: (ctx, docs) => throw const ThreepioException('no fusion'),
        ),
      );

      await expectLater(
        mqr.retrieve(
          'q',
          options: RetrieverOptions(
            runContext: RunContext.background().withHandlers([handler]),
          ),
        ),
        throwsA(isA<ThreepioException>()),
      );

      expect(fusionInput, isA<List<List<Document>>>());
      expect(fusionInput, hasLength(2));
      expect('$fusionError', contains('no fusion'));
    });

    test('a failed retrieval is reported to the error callback of that '
        'retrieval', () async {
      final errors = <String>[];
      final handler = CallbackHandlerBuilder()
          .onError((ctx, info, error, stackTrace) {
            errors.add('${info.name}: $error');
            return ctx;
          })
          .build();
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1', '2'],
          origRetriever: _FailingRetriever({'2': 'bad'}),
        ),
      );

      await expectLater(
        mqr.retrieve(
          'q',
          options: RetrieverOptions(
            runContext: RunContext.background().withHandlers([handler]),
          ),
        ),
        throwsStateError,
      );

      expect(errors, ['Retriever: Bad state: bad']);
    });

    test('global handlers hear a call without a run context', () async {
      final names = <String>[];
      GlobalCallbacks.append([
        CallbackHandlerBuilder().onEnd((ctx, info, output) {
          names.add(info.name);
          return ctx;
        }).build(),
      ]);
      final mqr = await MultiQueryRetriever.fromConfig(
        ctx,
        MultiQueryRetrieverConfig(
          rewriteHandler: (ctx, query) => ['1'],
          origRetriever: _MockRetriever(),
        ),
      );

      await mqr.retrieve('q');

      expect(names, containsAll(['QueryRewrite', 'Retriever', 'FusionFuncLambda']));
    });
  });
}

/// Like [_MockRetriever] but says it is `Mock`, as Go's router test does.
final class _TypedRetriever extends _MockRetriever implements TypedComponent {
  @override
  String get componentTypeName => 'Mock';
}

/// Records which queries started and finishes only once [gate] completes.
final class _GatedRetriever implements Retriever {
  _GatedRetriever(this.started, this.gate);

  final List<String> started;
  final Future<void> gate;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    started.add(query);
    await gate;
    return [Document(id: query, content: query)];
  }
}

/// Fails for the queries in [failures] (query → message) and finds the
/// query itself otherwise, after [delays] (query → event-loop turns; a
/// success waits until the queue is empty).
final class _FailingRetriever implements Retriever {
  _FailingRetriever(this.failures, {this.delays = const {}});

  final Map<String, String> failures;
  final Map<String, int> delays;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    for (var i = 0; i < (delays[query] ?? 0); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final message = failures[query];
    if (message != null) throw StateError(message);
    await pumpEventQueue();
    return [Document(id: query, content: query)];
  }
}
