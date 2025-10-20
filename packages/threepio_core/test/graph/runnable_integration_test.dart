import 'package:test/test.dart';
import 'package:threepio_core/src/compose/lambda.dart';
import 'package:threepio_core/src/compose/runnable.dart';
import 'package:threepio_core/src/graph/graph_node.dart';
import 'package:threepio_core/src/graph/graph_state.dart';
import 'package:threepio_core/src/graph/runnable_integration.dart';
import 'package:threepio_core/src/graph/state_graph.dart';

void main() {
  group('StateGraphRunnable Extension', () {
    test('toRunnable converts graph to Runnable', () {
      final graph = StateGraph<TestState>()
        ..addNode('node', (state) => state.copyWith(value: 42))
        ..setEntryPoint('node');

      final runnable = graph.toRunnable();

      expect(runnable, isA<Runnable<TestState, GraphResult<TestState>>>());
    });

    test('graph runnable invoke works', () async {
      final graph = StateGraph<TestState>()
        ..addNode(
            'increment', (state) => state.copyWith(value: state.value + 1))
        ..setEntryPoint('increment');

      final runnable = graph.toRunnable();
      final result =
          await runnable.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(1));
      expect(result.path, equals(['increment']));
    });

    test('graph runnable stream works', () async {
      final graph = StateGraph<TestState>()
        ..addNode('double', (state) => state.copyWith(value: state.value * 2))
        ..setEntryPoint('double');

      final runnable = graph.toRunnable();
      final results =
          await runnable.stream(TestState(value: 5, message: 'test')).toList();

      expect(results, hasLength(1));
      expect(results.first.state.value, equals(10));
    });

    test('graph runnable collect works', () async {
      final graph = StateGraph<TestState>()
        ..addNode('process', (state) => state.copyWith(value: state.value + 10))
        ..setEntryPoint('process');

      final runnable = graph.toRunnable();
      final inputStream = Stream.fromIterable([
        TestState(value: 1, message: 'test'),
        TestState(value: 2, message: 'test'),
      ]);

      final result = await runnable.collect(inputStream);

      // Takes first input
      expect(result.state.value, equals(11));
    });

    test('graph runnable transform works', () async {
      final graph = StateGraph<TestState>()
        ..addNode('square',
            (state) => state.copyWith(value: state.value * state.value))
        ..setEntryPoint('square');

      final runnable = graph.toRunnable();
      final inputStream = Stream.fromIterable([
        TestState(value: 2, message: 'test'),
        TestState(value: 3, message: 'test'),
        TestState(value: 4, message: 'test'),
      ]);

      final results = await runnable.transform(inputStream).toList();

      expect(results, hasLength(3));
      expect(results[0].state.value, equals(4));
      expect(results[1].state.value, equals(9));
      expect(results[2].state.value, equals(16));
    });

    test('graph runnable batch works', () async {
      final graph = StateGraph<TestState>()
        ..addNode(
            'increment', (state) => state.copyWith(value: state.value + 1))
        ..setEntryPoint('increment');

      final runnable = graph.toRunnable();
      final inputs = [
        TestState(value: 0, message: 'test'),
        TestState(value: 5, message: 'test'),
        TestState(value: 10, message: 'test'),
      ];

      final results = await runnable.batch(inputs);

      expect(results, hasLength(3));
      expect(results[0].state.value, equals(1));
      expect(results[1].state.value, equals(6));
      expect(results[2].state.value, equals(11));
    });

    test('graph runnable batchParallel works', () async {
      final graph = StateGraph<TestState>()
        ..addNode('async', (state) async {
          await Future.delayed(Duration(milliseconds: 10));
          return state.copyWith(value: state.value * 2);
        })
        ..setEntryPoint('async');

      final runnable = graph.toRunnable();
      final inputs = [
        TestState(value: 1, message: 'test'),
        TestState(value: 2, message: 'test'),
        TestState(value: 3, message: 'test'),
      ];

      final results = await runnable.batchParallel(inputs);

      expect(results, hasLength(3));
      expect(results[0].state.value, equals(2));
      expect(results[1].state.value, equals(4));
      expect(results[2].state.value, equals(6));
    });

    test('graph runnable pipe works', () async {
      final graph = StateGraph<TestState>()
        ..addNode(
            'increment', (state) => state.copyWith(value: state.value + 1))
        ..setEntryPoint('increment');

      final extractValue = lambda<GraphResult<TestState>, int>(
        (result) async => result.state.value,
      );

      final piped = graph.toRunnable().pipe(extractValue);

      final result = await piped.invoke(TestState(value: 5, message: 'test'));

      expect(result, equals(6));
    });

    test('complex graph as runnable', () async {
      final graph = StateGraph<TestState>()
        ..addNode('start', (state) => state.copyWith(value: 0))
        ..addNode(
            'increment', (state) => state.copyWith(value: state.value + 1))
        ..addNode('double', (state) => state.copyWith(value: state.value * 2))
        ..addNode('finish', (state) => state.copyWith(message: 'done'))
        ..addEdge('start', 'increment')
        ..addConditionalEdge(
          'increment',
          (state) => state.value < 5 ? 'increment' : 'double',
        )
        ..addEdge('double', 'finish')
        ..setEntryPoint('start');

      final runnable = graph.toRunnable();
      final result = await runnable.invoke(TestState(value: 999, message: ''));

      expect(result.state.value, equals(10)); // (0+1+1+1+1+1)*2
      expect(result.state.message, equals('done'));
    });
  });

  group('RunnableNode Extension', () {
    test('asNode converts Runnable to node function', () async {
      final runnable = lambda<String, int>((s) async => s.length);

      final nodeFunc = runnable.asNode<MapState>(
        getInput: (state) => state.get<String>('text') ?? '',
        setOutput: (state, result) => state.set('length', result),
      );

      final state = MapState({'text': 'hello'});
      final result = await nodeFunc(state);

      expect(result.get<int>('length'), equals(5));
    });

    test('runnable as node in graph', () async {
      final countWords = lambda<String, int>(
        (text) async => text.split(' ').length,
      );

      final graph = StateGraph<MapState>()
        ..addNode(
          'count',
          countWords.asNode<MapState>(
            getInput: (state) => state.get<String>('text') ?? '',
            setOutput: (state, count) => state.set('wordCount', count),
          ),
        )
        ..setEntryPoint('count');

      final result = await graph.invoke(MapState({'text': 'hello world test'}));

      expect(result.state.get<int>('wordCount'), equals(3));
    });

    test('runnable with transformation in graph', () async {
      final uppercase = lambda<String, String>(
        (s) async => s.toUpperCase(),
      );

      final graph = StateGraph<TestState>()
        ..addNode(
          'uppercase',
          uppercase.asNode<TestState>(
            getInput: (state) => state.message,
            setOutput: (state, result) => state.copyWith(message: result),
          ),
        )
        ..setEntryPoint('uppercase');

      final result = await graph.invoke(TestState(value: 0, message: 'hello'));

      expect(result.state.message, equals('HELLO'));
    });

    test('multiple runnables as nodes', () async {
      final double = lambda<int, int>((n) async => n * 2);
      final square = lambda<int, int>((n) async => n * n);

      final graph = StateGraph<TestState>()
        ..addNode(
          'double',
          double.asNode<TestState>(
            getInput: (state) => state.value,
            setOutput: (state, result) => state.copyWith(value: result),
          ),
        )
        ..addNode(
          'square',
          square.asNode<TestState>(
            getInput: (state) => state.value,
            setOutput: (state, result) => state.copyWith(value: result),
          ),
        )
        ..addEdge('double', 'square')
        ..setEntryPoint('double');

      final result = await graph.invoke(TestState(value: 3, message: 'test'));

      expect(result.state.value, equals(36)); // (3 * 2) ^ 2
    });

    test('runnable node with async operations', () async {
      final asyncOperation = lambda<int, int>((n) async {
        await Future.delayed(Duration(milliseconds: 10));
        return n + 100;
      });

      final graph = StateGraph<TestState>()
        ..addNode(
          'async',
          asyncOperation.asNode<TestState>(
            getInput: (state) => state.value,
            setOutput: (state, result) => state.copyWith(value: result),
          ),
        )
        ..setEntryPoint('async');

      final result = await graph.invoke(TestState(value: 5, message: 'test'));

      expect(result.state.value, equals(105));
    });

    test('runnable node preserves other state fields', () async {
      final increment = lambda<int, int>((n) async => n + 1);

      final graph = StateGraph<TestState>()
        ..addNode(
          'increment',
          increment.asNode<TestState>(
            getInput: (state) => state.value,
            setOutput: (state, result) => state.copyWith(value: result),
          ),
        )
        ..setEntryPoint('increment');

      final result =
          await graph.invoke(TestState(value: 0, message: 'preserve me'));

      expect(result.state.value, equals(1));
      expect(result.state.message, equals('preserve me')); // Preserved
    });
  });

  group('Graph and Runnable Composition', () {
    test('runnable -> graph -> runnable pipeline', () async {
      // First runnable: double the value
      final doubleValue = lambda<int, TestState>(
        (n) async => TestState(value: n * 2, message: 'doubled'),
      );

      // Graph: increment until >= 10
      final graph = StateGraph<TestState>()
        ..addNode(
            'increment', (state) => state.copyWith(value: state.value + 1))
        ..addConditionalEdge(
          'increment',
          (state) => state.value >= 10 ? END : 'increment',
        )
        ..setEntryPoint('increment');

      // Final runnable: extract value
      final extractValue = lambda<GraphResult<TestState>, int>(
        (result) async => result.state.value,
      );

      // Compose pipeline
      final pipeline = doubleValue.pipe(graph.toRunnable()).pipe(extractValue);

      final result = await pipeline.invoke(3);

      expect(result, equals(10)); // 3 * 2 = 6, then increment to 10
    });

    test('graph with runnable nodes piped to another runnable', () async {
      final processText = lambda<String, String>(
        (s) async => s.trim().toLowerCase(),
      );

      final graph = StateGraph<MapState>()
        ..addNode(
          'process',
          processText.asNode<MapState>(
            getInput: (state) => state.get<String>('input') ?? '',
            setOutput: (state, result) => state.set('processed', result),
          ),
        )
        ..setEntryPoint('process');

      final extractResult = lambda<GraphResult<MapState>, String>(
        (result) async => result.state.get<String>('processed') ?? '',
      );

      final pipeline = graph.toRunnable().pipe(extractResult);

      final result =
          await pipeline.invoke(MapState({'input': '  HELLO WORLD  '}));

      expect(result, equals('hello world'));
    });

    test('parallel graphs as runnables', () async {
      final graph1 = StateGraph<TestState>()
        ..addNode('add10', (state) => state.copyWith(value: state.value + 10))
        ..setEntryPoint('add10');

      final graph2 = StateGraph<TestState>()
        ..addNode(
            'multiply3', (state) => state.copyWith(value: state.value * 3))
        ..setEntryPoint('multiply3');

      final runnable1 = graph1.toRunnable();
      final runnable2 = graph2.toRunnable();

      final input = TestState(value: 5, message: 'test');

      final results = await Future.wait([
        runnable1.invoke(input),
        runnable2.invoke(input),
      ]);

      expect(results[0].state.value, equals(15)); // 5 + 10
      expect(results[1].state.value, equals(15)); // 5 * 3
    });

    test('nested graph composition', () async {
      // Inner graph: double value
      final innerGraph = StateGraph<TestState>()
        ..addNode('double', (state) => state.copyWith(value: state.value * 2))
        ..setEntryPoint('double');

      // Outer graph: uses inner graph as a node
      final outerGraph = StateGraph<TestState>()
        ..addNode('add5', (state) => state.copyWith(value: state.value + 5))
        ..addNode(
          'inner',
          (state) async {
            final result = await innerGraph.invoke(state);
            return result.state;
          },
        )
        ..addNode(
            'subtract3', (state) => state.copyWith(value: state.value - 3))
        ..addEdge('add5', 'inner')
        ..addEdge('inner', 'subtract3')
        ..setEntryPoint('add5');

      final result =
          await outerGraph.invoke(TestState(value: 10, message: 'test'));

      expect(result.state.value, equals(27)); // (10 + 5) * 2 - 3
    });

    test('runnable batch through graph', () async {
      final graph = StateGraph<TestState>()
        ..addNode('triple', (state) => state.copyWith(value: state.value * 3))
        ..setEntryPoint('triple');

      final runnable = graph.toRunnable();

      final inputs = List.generate(
        10,
        (i) => TestState(value: i, message: 'test'),
      );

      final results = await runnable.batch(inputs);

      expect(results, hasLength(10));
      for (var i = 0; i < 10; i++) {
        expect(results[i].state.value, equals(i * 3));
      }
    });
  });

  group('Error Handling in Integration', () {
    test('graph errors propagate through runnable', () async {
      final graph = StateGraph<TestState>()
        ..addNode('failing', (state) => throw Exception('Graph failed'))
        ..setEntryPoint('failing');

      final runnable = graph.toRunnable();

      expect(
        () => runnable.invoke(TestState(value: 1, message: 'test')),
        throwsException,
      );
    });

    test('runnable node errors propagate in graph', () async {
      final failingRunnable = lambda<int, int>(
        (n) async => throw Exception('Runnable failed'),
      );

      final graph = StateGraph<TestState>()
        ..addNode(
          'failing',
          failingRunnable.asNode<TestState>(
            getInput: (state) => state.value,
            setOutput: (state, result) => state.copyWith(value: result),
          ),
        )
        ..setEntryPoint('failing');

      expect(
        () => graph.invoke(TestState(value: 1, message: 'test')),
        throwsException,
      );
    });

    test('pipeline errors propagate correctly', () async {
      final graph = StateGraph<TestState>()
        ..addNode('node', (state) => throw Exception('Graph error'))
        ..setEntryPoint('node');

      final afterGraph = lambda<GraphResult<TestState>, int>(
        (result) async => result.state.value,
      );

      final pipeline = graph.toRunnable().pipe(afterGraph);

      expect(
        () => pipeline.invoke(TestState(value: 1, message: 'test')),
        throwsException,
      );
    });
  });
}

// Helper test state class
class TestState implements GraphState {
  const TestState({required this.value, required this.message});

  final int value;
  final String message;

  @override
  TestState copyWith({int? value, String? message}) {
    return TestState(
      value: value ?? this.value,
      message: message ?? this.message,
    );
  }
}
