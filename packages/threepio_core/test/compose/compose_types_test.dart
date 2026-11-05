// The small public types of the compose port: paths, options, errors, the
// checkpoint store, graph introspection.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

final class _Info implements GraphCompileCallback {
  final List<GraphInfo> infos = [];

  @override
  void onFinish(RunContext ctx, GraphInfo info) => infos.add(info);
}

Lambda<String, String> _same() =>
    Lambda<String, String>.invokable((ctx, input) => input);

void main() {
  final ctx = RunContext.background();

  group('NodePath', () {
    test('compares by its keys', () {
      expect(NodePath(const ['a', 'b']), NodePath(const ['a', 'b']));
      expect(NodePath(const ['a', 'b']).hashCode, NodePath(const ['a', 'b']).hashCode);
      expect(NodePath(const ['a']), isNot(NodePath(const ['b'])));
      expect(NodePath(const ['a', 'b']).toString(), '[a, b]');
      expect(NodePath(const ['b']).prepend('a').path, ['a', 'b']);
    });

    test('does not change with the list it was made from', () {
      final keys = ['a'];
      final path = NodePath(keys);
      keys.add('b');
      expect(path.path, ['a']);
      expect(() => path.path.add('c'), throwsUnsupportedError);
    });
  });

  group('CallOption', () {
    test('is aimed with designateNode and designateNodeWithPath', () {
      final option = CallOption.chatModel(const ChatModelOptions(model: 'm'));
      expect(option.paths, isEmpty);

      final aimed = option.designateNode(['a', 'b']).designateNodeWithPath([
        NodePath(const ['sub', 'c']),
      ]);
      expect(aimed.paths, [
        NodePath(const ['a']),
        NodePath(const ['b']),
        NodePath(const ['sub', 'c']),
      ]);
      // The original is not changed.
      expect(option.paths, isEmpty);
    });

    test('every factory makes an option', () {
      final options = <CallOption>[
        CallOption.callbacks(const []),
        CallOption.chatModel(const ChatModelOptions()),
        CallOption.chatTemplate(const ChatTemplateOptions()),
        CallOption.toolsNode(const ToolsNodeOptions()),
        CallOption.tool(const ToolOptions()),
        CallOption.embedding(const EmbedderOptions()),
        CallOption.retriever(const RetrieverOptions()),
        CallOption.loader(const LoaderOptions()),
        CallOption.documentTransformer(const TransformerOptions()),
        CallOption.indexer(const IndexerOptions()),
        CallOption.runtimeMaxSteps(3),
        CallOption.checkpointId('a'),
        CallOption.writeToCheckpointId('b'),
        CallOption.forceNewRun(),
        CallOption.stateModifier((ctx, path, state) {}),
        CallOption.lambda<int>([1, 2]),
      ];
      for (final option in options) {
        expect(option.designateNode(['n']).paths, [NodePath(const ['n'])]);
        expect(option.toString(), isNotEmpty);
      }
    });

    test('an option reaches the nodes declared with its option type',
        () async {
      final seen = <String, List<Object?>>{};
      Lambda<String, String> taking<T>(String name) =>
          Lambda.invokableWithOption<String, String, T>((ctx, input, options) {
            seen[name] = options;
            return input;
          });
      final runnable = await (Chain<String, String>()
            ..appendLambda(taking<String>('string'))
            ..appendLambda(taking<Object>('object'))
            ..appendLambda(taking<num>('num'))
            ..appendLambda(taking<int>('int')))
          .compile(ctx);

      await runnable.invoke(
        ctx,
        'x',
        options: [
          CallOption.lambda<String>(['s']),
          CallOption.lambda<int>([1, 2]),
          CallOption.chatModel(const ChatModelOptions(model: 'm')),
        ],
      );

      // A lambda with a wide option type does not collect the options that
      // were made for other nodes.
      expect(seen, {
        'string': ['s'],
        'object': isEmpty,
        'num': isEmpty,
        'int': [1, 2],
      });

      await runnable.invoke(
        ctx,
        'x',
        options: [
          CallOption.lambda<Object>(['for the wide one']),
        ],
      );
      expect(seen['object'], ['for the wide one']);

      await expectLater(
        runnable.invoke(
          ctx,
          'x',
          options: [
            CallOption.lambda<int>([1]).designateNode(['node_2']),
          ],
        ),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            contains(
              'option type[int] is different from which the designated '
              'node[node_2] expects[num]',
            ),
          ),
        ),
      );
    });

    test('the step limit of a call replaces the compiled one', () async {
      var steps = 0;
      final graph = Graph<int, int>()
        ..addLambdaNode('inc', Lambda<int, int>.invokable((ctx, i) => ++steps))
        ..addEdge(Graph.start, 'inc')
        ..addBranch(
          'inc',
          GraphBranch.single<int>((ctx, i) => 'inc', {'inc', Graph.end}),
        );
      final runnable = await graph.compile(
        ctx,
        options: const GraphCompileOptions(maxRunSteps: 50),
      );

      await expectLater(
        runnable.invoke(ctx, 0, options: [CallOption.runtimeMaxSteps(3)]),
        throwsA(isA<GraphRunException>()),
      );
      expect(steps, 3);
    });

    test('a DAG takes no step limit, at compile time or per call', () async {
      Graph<String, String> dag() => Graph<String, String>()
        ..addLambdaNode('a', _same())
        ..addEdge(Graph.start, 'a')
        ..addEdge('a', Graph.end);

      await expectLater(
        dag().compile(
          ctx,
          options: const GraphCompileOptions(
            nodeTriggerMode: NodeTriggerMode.allPredecessor,
            maxRunSteps: 5,
          ),
        ),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            'cannot set max run steps in dag mode',
          ),
        ),
      );

      final runnable = await dag().compile(
        ctx,
        options: const GraphCompileOptions(
          nodeTriggerMode: NodeTriggerMode.allPredecessor,
        ),
      );
      await expectLater(
        runnable.invoke(ctx, 'x', options: [CallOption.runtimeMaxSteps(5)]),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            'cannot set max run steps in dag',
          ),
        ),
      );
    });
  });

  group('errors', () {
    test('a graph run error prints like Eino and keeps its cause', () {
      const cause = FormatException('bad');
      final error = NodeExecutionException(NodePath(const ['a']), cause);

      expect(error.kind, 'NodeRunError');
      expect(error.nodeKey, 'a');
      expect(error.cause, same(cause));
      expect(
        error.toString(),
        '[NodeRunError] FormatException: bad\n'
        '------------------------\n'
        'node path: [a]',
      );

      final outer = error.within('sub');
      expect(outer, isA<NodeExecutionException>());
      expect(outer.nodePath.path, ['sub', 'a']);
      expect(outer.nodeKey, 'a');
      expect(outer.cause, same(cause));
      // The original is not changed.
      expect(error.nodePath.path, ['a']);
    });

    test('a run error of the graph itself has an empty path', () {
      final error = GraphRunException(
        'exceeds max steps',
        cause: const ExceedMaxStepsException(),
      );
      expect(error.kind, 'GraphRunError');
      expect(error.nodePath.path, isEmpty);
      expect(error.toString(), '[GraphRunError] exceeds max steps');
      expect(error.within('sub').nodePath.path, ['sub']);
      expect(error.within('sub'), isNot(isA<NodeExecutionException>()));
      expect(
        ThreepioException.findCause<ExceedMaxStepsException>(error),
        isNotNull,
      );
    });

    test('the build errors are ThreepioExceptions with Eino texts', () {
      expect(
        const GraphCompiledException().message,
        'graph has been compiled, cannot be modified',
      );
      expect(
        const ChainCompiledException().message,
        'chain has been compiled, cannot be modified',
      );
      final loop = DagLoopException(const [
        ['a', 'b', 'a'],
      ]);
      expect(loop.message, 'DAG is invalid, has loop: [a->b->a]');
      expect(loop, isA<GraphBuildException>());
      expect(const StreamReadException.empty().message,
          contains('stream reader is empty, concat fail'));
      expect(const ComposeTypeException('x'), isA<ThreepioException>());
    });

    test('a graph cannot be changed after compile, but compiled again',
        () async {
      final graph = Graph<String, String>()
        ..addLambdaNode('a', _same())
        ..addEdge(Graph.start, 'a')
        ..addEdge('a', Graph.end);
      await graph.compile(ctx);

      expect(
        () => graph.addLambdaNode('b', _same()),
        throwsA(isA<GraphCompiledException>()),
      );
      expect(
        () => graph.addEdge('a', 'a'),
        throwsA(isA<GraphCompiledException>()),
      );
      final again = await graph.compile(ctx);
      expect(await again.invoke(ctx, 'x'), 'x');
    });

    test('the first build error sticks to the graph', () async {
      final graph = Graph<String, String>()..addLambdaNode('a', _same());

      Object? first;
      try {
        graph.addEdge('a', 'missing');
      } on GraphBuildException catch (error) {
        first = error;
      }
      expect(first, isNotNull);
      expect(
        () => graph.addEdge(Graph.start, 'a'),
        throwsA(same(first)),
      );
      await expectLater(graph.compile(ctx), throwsA(same(first)));
    });

    test('a chain reports its first error at compile', () async {
      final chain = Chain<String, String>()
        ..appendLambda(_same())
        ..appendLambda(Lambda<int, String>.invokable((ctx, i) => '$i'))
        ..appendLambda(_same());

      await expectLater(
        chain.compile(ctx),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            contains('mismatch'),
          ),
        ),
      );
    });

    test('an empty chain cannot be compiled', () async {
      await expectLater(
        Chain<String, String>().compile(ctx),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            contains('pre node keys not set'),
          ),
        ),
      );
    });
  });

  group('lambdas and state handlers', () {
    test('Lambda.any needs at least one function', () {
      expect(() => Lambda<String, String>.any(), throwsArgumentError);
      expect(
        () => Lambda.anyWithOption<String, String, int>(),
        throwsArgumentError,
      );
    });

    test('a node has one handler in front and one behind', () {
      final pre = StateHandler.pre<String, List<String>>((ctx, i, s) => i);
      final streamPre =
          StateHandler.streamPre<String, List<String>>((ctx, i, s) => i);
      final post = StateHandler.post<String, List<String>>((ctx, o, s) => o);
      final graph = Graph<String, String>(
        localState: LocalState.of<List<String>>((ctx) => []),
      );

      expect(
        () => graph.addLambdaNode(
          'both',
          _same(),
          options: NodeOptions(
            statePreHandler: pre,
            streamStatePreHandler: streamPre,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => graph.addLambdaNode(
          'wrong-side',
          _same(),
          options: NodeOptions(statePreHandler: post),
        ),
        throwsArgumentError,
      );
      expect(
        () => graph.addLambdaNode(
          'wrong-form',
          _same(),
          options: NodeOptions(statePreHandler: streamPre),
        ),
        throwsArgumentError,
      );
      // None of these stuck to the graph as a build error.
      expect(
        () => graph.addLambdaNode(
          'ok',
          _same(),
          options: NodeOptions(statePreHandler: pre, statePostHandler: post),
        ),
        returnsNormally,
      );
    });

    test('a state handler needs a graph with a state', () {
      final graph = Graph<String, String>();
      expect(
        () => graph.addLambdaNode(
          'a',
          _same(),
          options: NodeOptions(
            statePreHandler:
                StateHandler.pre<String, List<String>>((ctx, i, s) => i),
          ),
        ),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            "node 'a' needs state but graph state is not enabled",
          ),
        ),
      );
    });

    test('processState outside a graph with a state is a StateError',
        () async {
      await expectLater(
        () => processState<List<String>>(ctx, (ctx, state) {}),
        throwsStateError,
      );
    });

    test('the handlers and the state describe themselves', () {
      expect(
        LocalState.of<List<String>>((ctx) => []).toString(),
        'LocalState<List<String>>',
      );
      expect(
        StateHandler.pre<String, List<String>>((ctx, i, s) => i).toString(),
        'StateHandler.pre<String, List<String>>',
      );
      expect(
        StateHandler.streamPost<int, Object>((ctx, o, s) => o).toString(),
        'StateHandler.streamPost<int, Object>',
      );
    });
  });

  group('options', () {
    test('GraphCompileOptions.copyWith keeps what is not replaced', () {
      const options = GraphCompileOptions(
        maxRunSteps: 3,
        graphName: 'g',
        nodeTriggerMode: NodeTriggerMode.anyPredecessor,
        eagerExecutionDisabled: true,
        fanInMergeConfig: {
          'a': FanInMergeConfig(streamMergeWithSourceEof: true),
        },
      );
      final copy = options.copyWith(graphName: 'h');
      expect(copy.graphName, 'h');
      expect(copy.maxRunSteps, 3);
      expect(copy.nodeTriggerMode, NodeTriggerMode.anyPredecessor);
      expect(copy.eagerExecutionDisabled, isTrue);
      expect(copy.fanInMergeConfig['a']!.streamMergeWithSourceEof, isTrue);
      expect(const GraphCompileOptions().graphName, '');
      expect(const FanInMergeConfig().streamMergeWithSourceEof, isFalse);
    });

    test('NodeOptions.copyWith keeps what is not replaced', () {
      const options = NodeOptions(name: 'n', key: 'k', inputKey: 'i');
      final copy = options.copyWith(outputKey: 'o');
      expect(
        [copy.name, copy.key, copy.inputKey, copy.outputKey],
        ['n', 'k', 'i', 'o'],
      );
    });

    test('ToolsNodeOptions.merge lets the later options win', () {
      const first = ToolsNodeOptions(
        toolOptions: ToolOptions(extensions: ['a']),
        toolAliases: {'t': ToolAliasConfig(nameAliases: ['x'])},
      );
      const second = ToolsNodeOptions(
        toolOptions: ToolOptions(extensions: [1]),
        toolList: [],
      );
      final merged = first.merge(second);
      expect(merged.toolOptions!.extension<String>(), 'a');
      expect(merged.toolOptions!.extension<int>(), 1);
      expect(merged.toolList, isEmpty);
      expect(merged.toolAliases!.keys, ['t']);
      expect(first.merge(null), same(first));
      expect(
        const ToolsNodeOptions().merge(second).toolOptions!.extension<int>(),
        1,
      );
    });

    test('only a chain takes a node key', () {
      expect(
        () => Graph<String, String>().addLambdaNode(
          'a',
          _same(),
          options: const NodeOptions(key: 'mine'),
        ),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            'only chain support node key option',
          ),
        ),
      );
    });

    test('a chain does not take a node trigger mode', () async {
      await expectLater(
        (Chain<String, String>()..appendLambda(_same())).compile(
          ctx,
          options: const GraphCompileOptions(
            nodeTriggerMode: NodeTriggerMode.allPredecessor,
          ),
        ),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            "Chain doesn't support node trigger mode option",
          ),
        ),
      );
    });
  });

  group('fan-in', () {
    tearDown(ValuesMerge.reset);

    Graph<String, O> twoInto<O>(Lambda<String, O> a, Lambda<String, O> b) =>
        Graph<String, O>()
          ..addLambdaNode('a', a)
          ..addLambdaNode('b', b)
          ..addEdge(Graph.start, 'a')
          ..addEdge(Graph.start, 'b')
          ..addEdge('a', Graph.end)
          ..addEdge('b', Graph.end);

    test('maps merge by default', () async {
      final runnable = await twoInto<Map<String, Object?>>(
        Lambda.invokable((ctx, s) => {'a': s}),
        Lambda.invokable((ctx, s) => {'b': s.length}),
      ).compile(ctx);

      expect(await runnable.invoke(ctx, 'xy'), {'a': 'xy', 'b': 2});
      expect(
        await (await runnable.stream(ctx, 'xy')).collectAll(),
        unorderedEquals([
          {'a': 'xy'},
          {'b': 2},
        ]),
      );
    });

    test('a narrower map type says which merge function is missing',
        () async {
      Graph<String, Map<String, String>> graph() =>
          twoInto<Map<String, String>>(
            Lambda.invokable((ctx, s) => {'a': s}),
            Lambda.invokable((ctx, s) => {'b': s}),
          );

      await expectLater(
        (await graph().compile(ctx)).invoke(ctx, 'x'),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            contains('ValuesMerge.register<Map<String, String>>'),
          ),
        ),
      );

      ValuesMerge.register<Map<String, String>>(
        (maps) => {for (final map in maps) ...map},
      );
      expect(
        await (await graph().compile(ctx)).invoke(ctx, 'x'),
        {'a': 'x', 'b': 'x'},
      );
    });

    test('values that are neither maps nor registered cannot fan in',
        () async {
      final runnable = await twoInto<String>(
        Lambda.invokable((ctx, s) => s),
        Lambda.invokable((ctx, s) => s),
      ).compile(ctx);

      await expectLater(
        runnable.invoke(ctx, 'x'),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            contains('(mergeValues) unsupported type: String'),
          ),
        ),
      );
    });
  });

  group('cancellation', () {
    test('a node that would start after the cancel does not run', () async {
      final token = CancelToken();
      final cancellable = RunContext.background(cancelToken: token);
      var ran = false;
      final graph = Graph<String, String>(
        localState: LocalState.of<List<String>>((ctx) => []),
      )
        ..addLambdaNode(
          'a',
          Lambda<String, String>.invokable((ctx, s) {
            ran = true;
            return s;
          }),
          options: NodeOptions(
            // Cancelled between the check of the step and the node.
            statePreHandler: StateHandler.pre<String, List<String>>(
              (ctx, input, state) {
                token.cancel('stop');
                return input;
              },
            ),
          ),
        )
        ..addEdge(Graph.start, 'a')
        ..addEdge('a', Graph.end);
      final runnable = await graph.compile(cancellable);

      await expectLater(
        runnable.invoke(cancellable, 'x'),
        throwsA(
          isA<NodeExecutionException>()
              .having((e) => e.nodePath.path, 'path', ['a'])
              .having((e) => e.cause, 'cause', isA<CancelledException>()),
        ),
      );
      expect(ran, isFalse);
    });

    test('a run is not started with a cancelled token', () async {
      final token = CancelToken()..cancel();
      final cancelled = RunContext.background(cancelToken: token);
      var ran = false;
      final runnable = await (Chain<String, String>()
            ..appendLambda(
              Lambda<String, String>.invokable((ctx, s) {
                ran = true;
                return s;
              }),
            ))
          .compile(ctx);

      await expectLater(
        runnable.invoke(cancelled, 'x'),
        throwsA(
          isA<GraphRunException>()
              .having((e) => e.message, 'message', 'context has been canceled')
              .having((e) => e.cause, 'cause', isA<CancelledException>()),
        ),
      );
      expect(ran, isFalse);
    });
  });

  group('InMemoryCheckpointStore', () {
    test('stores, replaces and deletes copies of the bytes', () async {
      final store = InMemoryCheckpointStore();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await store.set('a', bytes);
      bytes[0] = 9;
      expect(await store.get('a'), [1, 2, 3]);

      final read = (await store.get('a'))!..[0] = 7;
      expect(read, [7, 2, 3]);
      expect(await store.get('a'), [1, 2, 3]);

      await store.set('a', Uint8List.fromList([4]));
      expect(await store.get('a'), [4]);
      expect(store.keys, ['a']);

      await store.delete('a');
      await store.delete('a');
      expect(await store.get('a'), isNull);
      expect(store.keys, isEmpty);
    });
  });

  group('GraphInfo', () {
    tearDown(GraphCompileCallbacks.clearGlobal);

    Graph<String, String> build() {
      final inner = Chain<String, String>()
        ..appendLambda(_same(), options: const NodeOptions(name: 'inner'))
        ..appendPassthrough();
      return Graph<String, String>()
        ..addLambdaNode('a b', _same(), options: const NodeOptions(name: 'A'))
        ..addGraphNode(
          'sub',
          inner,
          options: const NodeOptions(
            compileOptions: GraphCompileOptions(graphName: 'inner chain'),
          ),
        )
        ..addLambdaNode('c', _same())
        ..addEdge(Graph.start, 'a b')
        ..addBranch(
          'a b',
          GraphBranch.single<String>((ctx, s) => 'sub', {'sub', 'c'}),
        )
        ..addEdge('sub', Graph.end)
        ..addEdge('c', Graph.end);
    }

    test('a compile callback gets the structure, nested graphs included',
        () async {
      final callback = _Info();
      final global = _Info();
      GraphCompileCallbacks.appendGlobal([global]);
      expect(GraphCompileCallbacks.global, [global]);

      await build().compile(
        ctx,
        options: GraphCompileOptions(
          graphName: 'outer',
          compileCallbacks: [callback],
        ),
      );

      expect(global.infos, hasLength(1));
      final info = callback.infos.single;
      expect(info.name, 'outer');
      expect(info.component, ComponentType.graph);
      expect(info.inputType, String);
      expect(info.outputType, String);
      expect(info.compileOptions!.graphName, 'outer');
      expect(info.localState, isNull);
      expect(info.nodes.keys, ['a b', 'sub', 'c']);
      expect(info.edges, {
        Graph.start: ['a b'],
        'sub': [Graph.end],
        'c': [Graph.end],
      });
      expect(info.dataEdges, info.edges);
      expect(info.branches['a b']!.single.endNodes, {'sub', 'c'});

      final a = info.nodes['a b']!;
      expect(a.component, ComponentType.lambda);
      expect(a.name, 'A');
      expect(a.instance, isA<Lambda<String, String>>());
      expect(a.inputType, String);
      expect(a.outputType, String);
      expect(a.options!.name, 'A');
      expect(a.graphInfo, isNull);
      expect(a.isPassthrough, isFalse);

      final sub = info.nodes['sub']!;
      expect(sub.component, ComponentType.chain);
      expect(sub.instance, isA<Chain<String, String>>());
      final nested = sub.graphInfo!;
      expect(nested.name, 'inner chain');
      expect(nested.component, ComponentType.chain);
      expect(nested.nodes.keys, ['node_0', 'node_1']);
      expect(nested.nodes['node_0']!.name, 'inner');
      final passthrough = nested.nodes['node_1']!;
      expect(passthrough.isPassthrough, isTrue);
      expect(passthrough.instance, isNull);
      // A passthrough node has the type of its neighbours.
      expect(passthrough.inputType, String);
      expect(nested.edges, {
        Graph.start: ['node_0'],
        'node_0': ['node_1'],
        'node_1': [Graph.end],
      });
    });

    test('without a compile callback nothing is collected or called',
        () async {
      final runnable = await build().compile(ctx);
      expect(await runnable.invoke(ctx, 'x'), 'x');
    });

    test('a graph describes itself before it is compiled', () {
      final info = build().info;
      expect(info.nodes.keys, ['a b', 'sub', 'c']);
      expect(info.name, '');
      // The nested chain is described as far as it is built: it gets its
      // edge to the end when it is compiled.
      expect(info.nodes['sub']!.graphInfo!.nodes.keys, ['node_0', 'node_1']);
    });

    test('toMermaid draws nodes, edges, branches and sub-graphs', () async {
      final graph = build();
      await graph.compile(ctx);

      expect(graph.toMermaid(), '''
graph TD
  a_b("a b<br/>(Lambda)")
  c("c<br/>(Lambda)")
  end_node([end])
  start_node([start])
  subgraph sub ["sub (Chain)"]
    sub_end_node([end])
    sub_node_0("node_0<br/>(Lambda)")
    sub_node_1["node_1<br/>(Passthrough)"]
    sub_start_node([start])
    sub_node_0 --> sub_node_1
    sub_node_1 --> sub_end_node
    sub_start_node --> sub_node_0
  end
  c --> end_node
  start_node --> a_b
  sub --> end_node
  a_b_branch_0{"branch"}
  a_b --> a_b_branch_0
  a_b_branch_0 --> c
  a_b_branch_0 --> sub
''');
    });
  });
}
