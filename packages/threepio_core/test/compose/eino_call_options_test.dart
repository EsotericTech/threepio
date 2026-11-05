// Port of eino `compose/graph_call_options_test.go`, plus the error paths of
// `extractOption` in `compose/utils.go`, which no Go test of that file covers.

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// Go: `testModel`. It records the options of every call instead of checking
/// them in place (Go: `checkOption` and the package variable `optionSuccess`).
final class _TestModel extends BaseChatModel {
  final List<ChatModelOptions?> seen = [];

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    seen.add(options);
    return Message.assistant('');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    seen.add(options);
    final (reader, writer) = pipe<Message>(capacity: 1);
    writer.send(Message.assistant(''));
    await writer.close();
    return reader;
  }
}

/// Go: gomock `MockEmbedder`.
final class _FakeEmbedder extends Embedder {
  final List<EmbedderOptions?> calls = [];

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    calls.add(options);
    return [];
  }
}

/// Go: gomock `MockRetriever`.
final class _FakeRetriever extends Retriever {
  final List<RetrieverOptions?> calls = [];

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    calls.add(options);
    return [];
  }
}

/// Go: `implOption{uid int64}`, an option only one loader understands.
final class _ImplOption {
  const _ImplOption(this.uid);
  final int uid;
}

/// Go: gomock `MockLoader`.
final class _FakeLoader implements Loader {
  final List<_ImplOption> calls = [];

  @override
  Future<List<Document>> load(
    RunContext ctx,
    DocumentSource source, {
    LoaderOptions? options,
  }) async {
    // Go: GetLoaderImplSpecificOptions(&implOption{uid: 1}, opts...).
    calls.add(options?.extension<_ImplOption>() ?? const _ImplOption(1));
    return [];
  }
}

/// Go: `option{uid int64}` of the sub-test common_option.
final class _UidOption {
  const _UidOption(this.uid);
  final int uid;
}

// Go: `type child1Option string` and its siblings, four types of their own.
final class _Child1Option {
  const _Child1Option(this.value);
  final String value;
}

final class _Child2Option {
  const _Child2Option(this.value);
  final String value;
}

final class _ParentOption {
  const _ParentOption(this.value);
  final String value;
}

final class _GrandparentOption {
  const _GrandparentOption(this.value);
  final String value;
}

/// A handler that writes down the name (and the kind) of what starts.
ComponentCallbackHandler _recorder(
  List<String> names, [
  List<ComponentType>? components,
]) =>
    CallbackHandlerBuilder().onStart((ctx, info, input) {
      names.add(info.name);
      components?.add(info.componentType);
      return ctx;
    }).build();

Matcher _failsWith(String text) => throwsA(
      isA<GraphRunException>().having(
        (e) => e.toString(),
        'text',
        contains(text),
      ),
    );

void main() {
  final ctx = RunContext.background();

  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  test('TestCallOption', () async {
    final lambdaOptions = <List<String>>[];
    final model2 = _TestModel();
    final model3 = _TestModel();

    final g = Graph<List<Message>, Message>()
      ..addLambdaNode(
        '1',
        Lambda.invokableWithOption<List<Message>, List<Message>, String>(
          (ctx, input, opts) {
            lambdaOptions.add(List.of(opts));
            return input;
          },
        ),
      )
      ..addChatModelNode('2', model2)
      ..addLambdaNode(
        '-',
        Lambda<Message, List<Message>>.invokable((ctx, input) => [input]),
      )
      ..addChatModelNode('3', model3)
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', '-')
      ..addEdge('-', '3')
      ..addEdge('3', Graph.end);

    final r = await g.compile(ctx);

    const sessionKey = ContextKey<String>('session');
    var startCnt = 0;
    var endCnt = 0;
    final opts = [
      CallOption.chatModel(const ChatModelOptions(model: '123'))
          .designateNode(['2']),
      CallOption.chatModel(const ChatModelOptions(model: '456'))
          .designateNode(['3']),
      CallOption.chatModel(const ChatModelOptions(topP: 1)),
      CallOption.callbacks([
        CallbackHandlerBuilder().onStart((ctx, info, input) {
          startCnt++;
          return ctx.withValue(sessionKey, 'start');
        }).onEnd((ctx, info, output) {
          if (ctx.value(sessionKey) == 'start') {
            endCnt++;
            return ctx.withValue(sessionKey, 'end');
          }
          return ctx;
        }).build(),
      ]).designateNode(['3']),
      CallOption.lambda<String>(['1']).designateNode(['1']),
    ];

    // Go: checkOption. There the model gets two options (its own and the
    // common one) and merges them; here it gets the one merged object.
    void expectOptions(int runs, String mode) {
      expect(lambdaOptions, hasLength(runs), reason: '$mode: lambda calls');
      expect(lambdaOptions.last, ['1'], reason: '$mode: lambda option');

      expect(model2.seen, hasLength(runs), reason: '$mode: calls of node 2');
      expect(model2.seen.last?.topP, 1.0, reason: '$mode: topP of node 2');
      expect(model2.seen.last?.model, '123', reason: '$mode: model of node 2');

      expect(model3.seen, hasLength(runs), reason: '$mode: calls of node 3');
      expect(model3.seen.last?.topP, 1.0, reason: '$mode: topP of node 3');
      expect(model3.seen.last?.model, '456', reason: '$mode: model of node 3');
    }

    await r.invoke(ctx, <Message>[], options: opts);
    expectOptions(1, 'invoke');
    expect(startCnt, 1, reason: 'node callback fail');
    expect(endCnt, 1, reason: 'node callback fail');

    final streamed = await r.stream(ctx, <Message>[], options: opts);
    await streamed.close();
    expectOptions(2, 'stream');

    final (srOfCollect, swOfCollect) = pipe<List<Message>>(capacity: 1);
    swOfCollect.send(<Message>[]);
    await swOfCollect.close();
    await r.collect(ctx, srOfCollect, options: opts);
    expectOptions(3, 'collect');

    final (srOfTransform, swOfTransform) = pipe<List<Message>>(capacity: 1);
    swOfTransform.send(<Message>[]);
    await swOfTransform.close();
    final transformed = await r.transform(ctx, srOfTransform, options: opts);
    await transformed.close();
    expectOptions(4, 'transform');
  });

  group('TestCallOptionsOneByOne', () {
    test('common_option', () {
      // Go: withComponentOption(&option{uid: 100}).
      final opt = CallOption.lambda<_UidOption>(const [_UidOption(100)]);
      expect(opt.componentOptions, hasLength(1));
      expect(
        opt.componentOptions.single,
        isA<_UidOption>().having((o) => o.uid, 'uid', 100),
      );
    });

    test('embedding_option', () async {
      final inst = _FakeEmbedder();
      final ch = Chain<Map<String, Object?>, Map<String, Object?>>()
        ..appendEmbedding(
          inst,
          options: const NodeOptions(inputKey: 'input', outputKey: 'output'),
        );
      final r = await ch.compile(ctx);
      final outs = await r.invoke(
        ctx,
        {'input': <String>[]},
        options: [CallOption.embedding(const EmbedderOptions(model: '123'))],
      );
      expect(outs, contains('output'));

      expect(inst.calls, hasLength(1));
      expect(inst.calls.single?.model, '123');
    });

    test('retriever_option', () async {
      final inst = _FakeRetriever();
      final ch = Chain<Map<String, Object?>, Map<String, Object?>>()
        ..appendRetriever(
          inst,
          options: const NodeOptions(inputKey: 'input', outputKey: 'output'),
        );
      final r = await ch.compile(ctx);
      final outs = await r.invoke(
        ctx,
        {'input': 'hi'},
        options: [CallOption.retriever(const RetrieverOptions(index: '123'))],
      );
      expect(outs, contains('output'));

      expect(inst.calls, hasLength(1));
      expect(inst.calls.single?.index, '123');
    });

    test('loader_option', () async {
      final inst = _FakeLoader();
      final ch = Chain<Map<String, Object?>, Map<String, Object?>>()
        ..appendLoader(
          inst,
          options: const NodeOptions(inputKey: 'input', outputKey: 'output'),
        );
      final r = await ch.compile(ctx);
      final outs = await r.invoke(
        ctx,
        {'input': const DocumentSource(uri: '')},
        options: [
          // Go: WithLoaderOption(withUID(123)).
          CallOption.loader(const LoaderOptions(extensions: [_ImplOption(123)])),
        ],
      );
      expect(outs, contains('output'));

      expect(inst.calls, hasLength(1));
      expect(inst.calls.single.uid, 123);
    });
  });

  test('TestCallOptionInSubGraph', () async {
    // The options every lambda got, by the name of its node.
    final seen = <String, List<String>>{};

    final child1 = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda.invokableWithOption<String, String, _Child1Option>(
          (ctx, input, opts) {
            seen['child1-1'] = [for (final opt in opts) opt.value];
            return '$input child1-1';
          },
        ),
        options: const NodeOptions(name: 'child1-1'),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final child2 = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda.invokableWithOption<String, String, _Child2Option>(
          (ctx, input, opts) {
            seen['child2-1'] = [for (final opt in opts) opt.value];
            return '$input child2-1';
          },
        ),
        options: const NodeOptions(name: 'child2-1'),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final parent = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda.invokableWithOption<String, String, _ParentOption>(
          (ctx, input, opts) {
            seen['parent-1'] = [for (final opt in opts) opt.value];
            return '$input parent-1';
          },
        ),
        options: const NodeOptions(name: 'parent-1'),
      )
      ..addGraphNode('2', child1, options: const NodeOptions(name: 'child1'))
      ..addGraphNode('3', child2, options: const NodeOptions(name: 'child2'))
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', '3')
      ..addEdge('3', Graph.end);

    final grandParent = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda.invokableWithOption<String, String, _GrandparentOption>(
          (ctx, input, opts) {
            seen['grandparent-1'] = [for (final opt in opts) opt.value];
            return '$input grandparent-1';
          },
        ),
        options: const NodeOptions(name: 'grandparent-1'),
      )
      ..addGraphNode('2', parent, options: const NodeOptions(name: 'parent'))
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', Graph.end);

    final r = await grandParent.compile(
      ctx,
      options: const GraphCompileOptions(graphName: 'grandparent'),
    );

    // Go checks the names inside the handlers; a hook that throws is only
    // logged here, so the handlers write down what they hear.
    final grandCommon = <String>[];
    final grandCommonComponents = <ComponentType>[];
    final grand1 = <String>[];
    final parentCommon = <String>[];
    final child1Common = <String>[];
    final child2Only = <String>[];

    final result = await r.invoke(
      ctx,
      'input',
      options: [
        CallOption.callbacks([_recorder(grandCommon, grandCommonComponents)]),
        CallOption.callbacks([_recorder(parentCommon)]).designateNodeWithPath([
          NodePath(const ['2']),
        ]),
        CallOption.callbacks([_recorder(grand1)]).designateNode(['1']),
        CallOption.callbacks([_recorder(child1Common)]).designateNodeWithPath([
          NodePath(const ['2', '2']),
        ]),
        CallOption.callbacks([_recorder(child2Only)]).designateNodeWithPath([
          NodePath(const ['2', '3', '1']),
        ]),
        CallOption.lambda<_GrandparentOption>(
          const [_GrandparentOption('grandparent-1')],
        ).designateNodeWithPath([
          NodePath(const ['1']),
        ]),
        CallOption.lambda<_ParentOption>(const [_ParentOption('parent-1')])
            .designateNodeWithPath([
          NodePath(const ['2', '1']),
        ]),
        CallOption.lambda<_Child1Option>(const [_Child1Option('child1-1')])
            .designateNodeWithPath([
          NodePath(const ['2', '2', '1']),
        ]),
        CallOption.lambda<_Child2Option>(const [_Child2Option('child2-1')])
            .designateNodeWithPath([
          NodePath(const ['2', '3', '1']),
        ]),
      ],
    );
    expect(result, 'input grandparent-1 parent-1 child1-1 child2-1');

    expect(seen, {
      'grandparent-1': ['grandparent-1'],
      'parent-1': ['parent-1'],
      'child1-1': ['child1-1'],
      'child2-1': ['child2-1'],
    });

    expect(grandCommon, [
      'grandparent',
      'grandparent-1',
      'parent',
      'parent-1',
      'child1',
      'child1-1',
      'child2',
      'child2-1',
    ]);
    expect(grandCommonComponents.first, ComponentType.graph);
    expect(grand1, ['grandparent-1']);
    expect(parentCommon, [
      'parent',
      'parent-1',
      'child1',
      'child1-1',
      'child2',
      'child2-1',
    ]);
    expect(child1Common, ['child1', 'child1-1']);
    expect(child2Only, ['child2-1']);
  });

  // Not Go tests: the errors of `extractOption` (compose/utils.go). A run
  // with an option that is aimed wrongly fails, with Go's message.
  group('extractOption errors', () {
    late Runnable<String, String> r;

    setUp(() async {
      final sub = Graph<String, String>()
        ..addLambdaNode(
          'inner',
          Lambda.invokableWithOption<String, String, String>(
            (ctx, input, opts) => input,
          ),
        )
        ..addEdge(Graph.start, 'inner')
        ..addEdge('inner', Graph.end);

      final g = Graph<String, String>()
        ..addLambdaNode(
          'node',
          Lambda.invokableWithOption<String, String, String>(
            (ctx, input, opts) => input,
          ),
        )
        ..addGraphNode('sub', sub)
        ..addEdge(Graph.start, 'node')
        ..addEdge('node', 'sub')
        ..addEdge('sub', Graph.end);
      r = await g.compile(ctx);
    });

    Future<void> expectFails(CallOption option, String text) async {
      await expectLater(
        r.invoke(ctx, 'in', options: [option]),
        _failsWith(text),
        reason: 'invoke',
      );
      await expectLater(
        r.stream(ctx, 'in', options: [option]),
        _failsWith(text),
        reason: 'stream',
      );
    }

    test('the graph runs with a well-aimed option', () async {
      expect(
        await r.invoke(
          ctx,
          'in',
          options: [
            CallOption.lambda<String>(['x']).designateNode(['node']),
            CallOption.lambda<String>(['y']).designateNodeWithPath([
              NodePath(const ['sub', 'inner']),
            ]),
          ],
        ),
        'in',
      );
    });

    test('an empty path', () async {
      await expectFails(
        CallOption.lambda<String>(['x']).designateNodeWithPath([
          NodePath(const []),
        ]),
        'call option has designated an empty path',
      );
    });

    test('an unknown node', () async {
      await expectFails(
        CallOption.lambda<String>(['x']).designateNode(['nowhere']),
        'option has designated an unknown node',
      );
    });

    test('an unknown node, for callbacks', () async {
      await expectFails(
        CallOption.callbacks([_recorder([])]).designateNode(['nowhere']),
        'option has designated an unknown node',
      );
    });

    test('an unknown node inside a nested graph', () async {
      final option = CallOption.lambda<String>(['x']).designateNodeWithPath([
        NodePath(const ['sub', 'nowhere']),
      ]);
      await expectFails(option, 'option has designated an unknown node');
      await expectLater(
        r.invoke(ctx, 'in', options: [option]),
        throwsA(
          isA<GraphRunException>()
              .having((e) => e.nodePath.path, 'nodePath', ['sub']),
        ),
      );
    });

    test('an option of the wrong type designated at a node', () async {
      await expectFails(
        CallOption.chatModel(const ChatModelOptions(model: 'x'))
            .designateNode(['node']),
        'is different from which the designated node',
      );
    });

    test('a sub-path designated at a component', () async {
      await expectFails(
        CallOption.lambda<String>(['x']).designateNodeWithPath([
          NodePath(const ['node', 'inner']),
        ]),
        'cannot designate sub path of a component',
      );
    });
  });
}
