// What `package:threepio_core/compose.dart`, `legacy_graph.dart`,
// `legacy_chains.dart` and the umbrella library export after the compose
// port, and that the state graph the applications use is where it was.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart' as compose;
import 'package:threepio_core/legacy_chains.dart' as chains;
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

/// A state written like the ones in the applications.
class _Counter implements GraphState {
  const _Counter(this.value);

  final int value;

  @override
  _Counter copyWith({int? value}) => _Counter(value ?? this.value);
}

void main() {
  group('the umbrella library', () {
    test('still resolves the state graph API the applications use', () async {
      final graph = StateGraph<_Counter>()
        ..addNode('inc', (state) => state.copyWith(value: state.value + 1))
        ..addEdge('inc', END)
        ..setEntryPoint('inc');

      final GraphResult<_Counter> result = await graph.invoke(const _Counter(1));

      expect(result.state.value, 2);
      expect(result.path, contains('inc'));
      expect(START, '__start__');
      expect(END, '__end__');
      expect(GraphBuilder<_Counter>(), isA<GraphBuilder<_Counter>>());
      expect(MapState(), isA<GraphState>());
    });

    test('CheckpointStore now means the compose interface', () async {
      // Not generic any more: the compose store keeps bytes under a key.
      final CheckpointStore store = InMemoryCheckpointStore();
      expect(store, isA<compose.CheckpointStore>());
      expect(store, isA<CheckpointDeleter>());
      expect(store, isNot(isA<legacy.CheckpointStore<_Counter>>()));

      await store.set('a', Uint8List.fromList([1, 2, 3]));
      expect(await store.get('a'), [1, 2, 3]);
      expect(await store.get('b'), isNull);
    });

    test('exports the compose port', () {
      expect(Graph.start, 'start');
      expect(Graph.end, 'end');
      expect(Graph<String, String>(), isA<compose.Graph<String, String>>());
      expect(Chain<String, String>(), isA<AnyGraph>());
      expect(Parallel(), isA<compose.Parallel>());
      expect(NodePath(const ['a']), compose.NodePath(const ['a']));
      expect(
        Lambda<String, String>.invokable((ctx, input) => input),
        isA<compose.Lambda<String, String>>(),
      );
      expect(
        CallOption.runtimeMaxSteps(3),
        isA<compose.CallOption>(),
      );
      expect(ToolsNode(const ToolsNodeConfig(tools: [])), isA<Runnable<Message, List<Message>>>());
      expect(const GraphCompiledException(), isA<GraphBuildException>());
      expect(const GraphCompiledException(), isA<ThreepioException>());
      expect(GraphRunException('x'), isA<ThreepioException>());
    });
  });

  group('legacy_graph.dart', () {
    test('has the five checkpoint names the umbrella leaves out', () async {
      final store = legacy.InMemoryCheckpointStore<_Counter>();
      expect(store, isA<legacy.CheckpointStore<_Counter>>());
      expect(
        legacy.JsonCheckpointSerializer<legacy.MapState>,
        isNot(compose.CheckpointSerializer),
      );
      expect(legacy.FileCheckpointStore<legacy.MapState>, isA<Type>());
      expect(legacy.CheckpointSerializer<legacy.MapState>, isA<Type>());
      // The rest of the legacy graph API is the same as in the umbrella.
      expect(legacy.StateGraph<_Counter>(), isA<StateGraph<_Counter>>());
      expect(legacy.END, END);
    });

    test('has the renamed runnable that StateGraph.toRunnable returns',
        () async {
      final graph = StateGraph<_Counter>()
        ..addNode('inc', (state) => state.copyWith(value: state.value + 1))
        ..addEdge('inc', END)
        ..setEntryPoint('inc');

      final runnable = graph.toRunnable();

      expect(
        runnable,
        isA<legacy.LegacyRunnable<_Counter, GraphResult<_Counter>>>(),
      );
      expect((await runnable.invoke(const _Counter(5))).state.value, 6);

      final lambda = legacy.LegacyLambda<int, int>(
        invoke: (input, options) async => input * 2,
      );
      expect(await lambda.invoke(4), 8);
      expect(const legacy.LegacyRunnableOptions(), isNotNull);
    });
  });

  group('legacy_chains.dart', () {
    test('exports the LangChain-style chains', () async {
      final chain = chains.TransformChain.sync(
        inputKey: 'a',
        outputKey: 'b',
        transformFn: (input) => '$input!',
      );
      expect(chain, isA<chains.BaseChain>());
      expect(chain, isA<legacy.LegacyRunnable<Map<String, dynamic>, Map<String, dynamic>>>());
      expect(await chain.invoke({'a': 'x'}), containsPair('b', 'x!'));
    });
  });

  group('checkpointing', () {
    final ctx = RunContext.background();

    Graph<String, String> graph() => Graph<String, String>()
      ..addLambdaNode('a', Lambda<String, String>.invokable((ctx, s) => s))
      ..addEdge(Graph.start, 'a')
      ..addEdge('a', Graph.end);

    test('compile takes a checkpoint store', () async {
      final runnable = await graph().compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
      );
      expect(await runnable.invoke(ctx, 'x'), 'x');
    });

    test('compile takes interrupt nodes, and a run stops at them', () async {
      final before = await graph().compile(
        ctx,
        options: const GraphCompileOptions(interruptBeforeNodes: ['a']),
      );
      await expectLater(
        before.invoke(ctx, 'x'),
        throwsA(
          isA<GraphInterruptedException>()
              .having((e) => e.info.beforeNodes, 'beforeNodes', ['a']),
        ),
      );

      // As in Eino, a run that reaches the end is not interrupted behind its
      // last node: there has to be a node left to run.
      final last = await graph().compile(
        ctx,
        options: const GraphCompileOptions(interruptAfterNodes: ['a']),
      );
      expect(await last.invoke(ctx, 'x'), 'x');

      final twoNodes = Graph<String, String>()
        ..addLambdaNode('a', Lambda<String, String>.invokable((ctx, s) => s))
        ..addLambdaNode('b', Lambda<String, String>.invokable((ctx, s) => s))
        ..addEdge(Graph.start, 'a')
        ..addEdge('a', 'b')
        ..addEdge('b', Graph.end);
      final after = await twoNodes.compile(
        ctx,
        options: const GraphCompileOptions(interruptAfterNodes: ['a']),
      );
      await expectLater(
        after.invoke(ctx, 'x'),
        throwsA(
          isA<GraphInterruptedException>()
              .having((e) => e.info.afterNodes, 'afterNodes', ['a']),
        ),
      );
    });

    test('a run refuses a checkpoint id without a store', () async {
      final runnable = await graph().compile(ctx);
      await expectLater(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('cp')]),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            contains('have not set checkpoint store'),
          ),
        ),
      );
    });
  });
}
