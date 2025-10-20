import 'package:test/test.dart';
import 'package:threepio_core/src/graph/graph_node.dart';
import 'package:threepio_core/src/graph/graph_state.dart';
import 'package:threepio_core/src/graph/state_graph.dart';

void main() {
  group('StateGraph Construction', () {
    test('creates empty graph with default max iterations', () {
      final graph = StateGraph<TestState>();
      expect(graph.maxIterations, equals(100));
    });

    test('creates graph with custom max iterations', () {
      final graph = StateGraph<TestState>(maxIterations: 50);
      expect(graph.maxIterations, equals(50));
    });

    test('addNode adds node successfully', () {
      final graph = StateGraph<TestState>();
      final result = graph.addNode(
        'test',
        (state) => state.copyWith(value: state.value + 1),
      );

      expect(result, same(graph)); // Returns self for chaining
    });

    test('addNode with description', () {
      final graph = StateGraph<TestState>();
      graph.addNode(
        'test',
        (state) => state,
        description: 'Test node',
      );

      // Graph should not throw
      expect(() => graph.setEntryPoint('test'), returnsNormally);
    });

    test('addNode throws on duplicate name', () {
      final graph = StateGraph<TestState>();
      graph.addNode('duplicate', (state) => state);

      expect(
        () => graph.addNode('duplicate', (state) => state),
        throwsArgumentError,
      );
    });

    test('addEdge connects two nodes', () {
      final graph = StateGraph<TestState>()
        ..addNode('A', (state) => state)
        ..addNode('B', (state) => state)
        ..addEdge('A', 'B');

      expect(() => graph.setEntryPoint('A'), returnsNormally);
    });

    test('addEdge allows END as target', () {
      final graph = StateGraph<TestState>()
        ..addNode('last', (state) => state)
        ..addEdge('last', END);

      expect(() => graph.setEntryPoint('last'), returnsNormally);
    });

    test('addEdge throws for non-existent source node', () {
      final graph = StateGraph<TestState>()..addNode('B', (state) => state);

      expect(
        () => graph.addEdge('nonexistent', 'B'),
        throwsArgumentError,
      );
    });

    test('addEdge throws for non-existent target node', () {
      final graph = StateGraph<TestState>()..addNode('A', (state) => state);

      expect(
        () => graph.addEdge('A', 'nonexistent'),
        throwsArgumentError,
      );
    });

    test('setEntryPoint sets entry point successfully', () {
      final graph = StateGraph<TestState>()..addNode('start', (state) => state);

      final result = graph.setEntryPoint('start');
      expect(result, same(graph)); // Returns self for chaining
    });

    test('setEntryPoint throws for non-existent node', () {
      final graph = StateGraph<TestState>();

      expect(
        () => graph.setEntryPoint('nonexistent'),
        throwsArgumentError,
      );
    });

    test('supports fluent API', () {
      final graph = StateGraph<TestState>()
        ..addNode('A', (state) => state.copyWith(value: 1))
        ..addNode('B', (state) => state.copyWith(value: 2))
        ..addNode('C', (state) => state.copyWith(value: 3))
        ..addEdge('A', 'B')
        ..addEdge('B', 'C')
        ..addEdge('C', END)
        ..setEntryPoint('A');

      expect(() => graph, returnsNormally);
    });
  });

  group('StateGraph Execution - Linear', () {
    test('executes simple linear graph', () async {
      final graph = StateGraph<TestState>()
        ..addNode('step1', (state) => state.copyWith(value: state.value + 1))
        ..addNode('step2', (state) => state.copyWith(value: state.value * 2))
        ..addNode('step3', (state) => state.copyWith(value: state.value + 10))
        ..addEdge('step1', 'step2')
        ..addEdge('step2', 'step3')
        ..addEdge('step3', END)
        ..setEntryPoint('step1');

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      // (0 + 1) * 2 + 10 = 12
      expect(result.state.value, equals(12));
      expect(result.path, equals(['step1', 'step2', 'step3']));
    });

    test('executes graph with single node', () async {
      final graph = StateGraph<TestState>()
        ..addNode('only', (state) => state.copyWith(value: 42))
        ..addEdge('only', END)
        ..setEntryPoint('only');

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(42));
      expect(result.path, equals(['only']));
    });

    test('executes graph without explicit END edge', () async {
      final graph = StateGraph<TestState>()
        ..addNode('last', (state) => state.copyWith(value: 100))
        ..setEntryPoint('last');

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(100));
      expect(result.path, equals(['last']));
    });

    test('includes metadata in result', () async {
      final graph = StateGraph<TestState>()
        ..addNode('node', (state) => state)
        ..setEntryPoint('node');

      final result = await graph.invoke(TestState(value: 1, message: 'test'));

      expect(result.metadata['iterations'], isNotNull);
      expect(result.metadata['iterations'], greaterThan(0));
    });
  });

  group('StateGraph Execution - Conditional', () {
    test('routes based on state condition', () async {
      final graph = StateGraph<TestState>()
        ..addNode('check', (state) => state)
        ..addNode('low', (state) => state.copyWith(message: 'low'))
        ..addNode('high', (state) => state.copyWith(message: 'high'))
        ..addConditionalEdge(
          'check',
          (state) => state.value > 10 ? 'high' : 'low',
        )
        ..addEdge('low', END)
        ..addEdge('high', END)
        ..setEntryPoint('check');

      final lowResult = await graph.invoke(TestState(value: 5, message: ''));
      expect(lowResult.state.message, equals('low'));
      expect(lowResult.path, equals(['check', 'low']));

      final highResult = await graph.invoke(TestState(value: 15, message: ''));
      expect(highResult.state.message, equals('high'));
      expect(highResult.path, equals(['check', 'high']));
    });

    test('conditional edge can route to END', () async {
      final graph = StateGraph<TestState>()
        ..addNode('check', (state) => state.copyWith(value: state.value + 1))
        ..addNode('continue', (state) => state.copyWith(message: 'continued'))
        ..addConditionalEdge(
          'check',
          (state) => state.value > 5 ? END : 'continue',
        )
        ..addEdge('continue', END)
        ..setEntryPoint('check');

      final endResult = await graph.invoke(TestState(value: 10, message: ''));
      expect(endResult.path, equals(['check']));

      final continueResult =
          await graph.invoke(TestState(value: 0, message: ''));
      expect(continueResult.path, equals(['check', 'continue']));
    });

    test('supports multi-way conditional routing', () async {
      final graph = StateGraph<TestState>()
        ..addNode('classify', (state) => state)
        ..addNode('negative', (state) => state.copyWith(message: 'neg'))
        ..addNode('zero', (state) => state.copyWith(message: 'zero'))
        ..addNode('positive', (state) => state.copyWith(message: 'pos'))
        ..addConditionalEdge('classify', (state) {
          if (state.value < 0) return 'negative';
          if (state.value == 0) return 'zero';
          return 'positive';
        })
        ..addEdge('negative', END)
        ..addEdge('zero', END)
        ..addEdge('positive', END)
        ..setEntryPoint('classify');

      expect(
        (await graph.invoke(TestState(value: -5, message: ''))).state.message,
        equals('neg'),
      );
      expect(
        (await graph.invoke(TestState(value: 0, message: ''))).state.message,
        equals('zero'),
      );
      expect(
        (await graph.invoke(TestState(value: 5, message: ''))).state.message,
        equals('pos'),
      );
    });

    test('addConditionalRouter works with named routes', () async {
      final graph = StateGraph<TestState>()
        ..addNode('check', (state) => state)
        ..addNode('even', (state) => state.copyWith(message: 'even'))
        ..addNode('odd', (state) => state.copyWith(message: 'odd'))
        ..addConditionalRouter('check', {
          'even': (state) => state.value % 2 == 0,
          'odd': (state) => state.value % 2 != 0,
        })
        ..addEdge('even', END)
        ..addEdge('odd', END)
        ..setEntryPoint('check');

      final evenResult = await graph.invoke(TestState(value: 4, message: ''));
      expect(evenResult.state.message, equals('even'));

      final oddResult = await graph.invoke(TestState(value: 5, message: ''));
      expect(oddResult.state.message, equals('odd'));
    });
  });

  group('StateGraph Execution - Loops', () {
    test('supports simple loop', () async {
      final graph = StateGraph<TestState>()
        ..addNode(
            'increment', (state) => state.copyWith(value: state.value + 1))
        ..addConditionalEdge(
          'increment',
          (state) => state.value < 5 ? 'increment' : END,
        )
        ..setEntryPoint('increment');

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(5));
      expect(
          result.path,
          equals([
            'increment',
            'increment',
            'increment',
            'increment',
            'increment'
          ]));
    });

    test('prevents infinite loops with maxIterations', () async {
      final graph = StateGraph<TestState>(maxIterations: 10)
        ..addNode('loop', (state) => state.copyWith(value: state.value + 1))
        ..addEdge('loop', 'loop') // Infinite loop
        ..setEntryPoint('loop');

      expect(
        () => graph.invoke(TestState(value: 0, message: 'test')),
        throwsStateError,
      );
    });

    test('loop with accumulation', () async {
      final graph = StateGraph<MapState>()
        ..addNode('accumulate', (state) {
          final count = state.get<int>('count') ?? 0;
          final sum = state.get<int>('sum') ?? 0;
          return state.setAll({
            'count': count + 1,
            'sum': sum + count,
          });
        })
        ..addConditionalEdge(
          'accumulate',
          (state) => (state.get<int>('count') ?? 0) < 10 ? 'accumulate' : END,
        )
        ..setEntryPoint('accumulate');

      final result = await graph.invoke(MapState({'count': 0, 'sum': 0}));

      expect(result.state.get<int>('count'), equals(10));
      expect(result.state.get<int>('sum'), equals(45)); // 0+1+2+...+9
    });
  });

  group('StateGraph Execution - Parallel', () {
    test('executes parallel branches', () async {
      final graph = StateGraph<TestState>()
        ..addNode('split', (state) => state)
        ..addNode('branchA', (state) => state.copyWith(value: state.value + 10))
        ..addNode('branchB', (state) => state.copyWith(value: state.value + 20))
        ..addParallelEdge('split', ['branchA', 'branchB'])
        ..setEntryPoint('split');

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      // Without merger, last result is used
      expect(result.state.value, equals(20)); // branchB result
      expect(result.path, contains('split'));
    });

    test('parallel edge with merger function', () async {
      final graph = StateGraph<TestState>()
        ..addNode('split', (state) => state)
        ..addNode('double', (state) => state.copyWith(value: state.value * 2))
        ..addNode('square',
            (state) => state.copyWith(value: state.value * state.value))
        ..addParallelEdge(
          'split',
          ['double', 'square'],
          merger: (original, results) {
            // Sum all results
            final sum = results.fold<int>(0, (acc, s) => acc + s.value);
            return original.copyWith(value: sum);
          },
        )
        ..setEntryPoint('split');

      final result = await graph.invoke(TestState(value: 3, message: 'test'));

      // 3*2 + 3*3 = 6 + 9 = 15
      expect(result.state.value, equals(15));
    });

    test('parallel execution with three branches', () async {
      final graph = StateGraph<MapState>()
        ..addNode('start', (state) => state.set('initialized', true))
        ..addNode('task1', (state) => state.set('task1', 'done'))
        ..addNode('task2', (state) => state.set('task2', 'done'))
        ..addNode('task3', (state) => state.set('task3', 'done'))
        ..addParallelEdge(
          'start',
          ['task1', 'task2', 'task3'],
          merger: (original, results) {
            // Merge all task results
            var merged = original;
            for (final result in results) {
              if (result.get<String>('task1') != null) {
                merged = merged.set('task1', result.get('task1'));
              }
              if (result.get<String>('task2') != null) {
                merged = merged.set('task2', result.get('task2'));
              }
              if (result.get<String>('task3') != null) {
                merged = merged.set('task3', result.get('task3'));
              }
            }
            return merged;
          },
        )
        ..setEntryPoint('start');

      final result = await graph.invoke(MapState());

      expect(result.state.get<bool>('initialized'), isTrue);
      expect(result.state.get<String>('task1'), equals('done'));
      expect(result.state.get<String>('task2'), equals('done'));
      expect(result.state.get<String>('task3'), equals('done'));
    });
  });

  group('StateGraph Error Handling', () {
    test('throws when entry point not set', () async {
      final graph = StateGraph<TestState>()..addNode('node', (state) => state);

      expect(
        () => graph.invoke(TestState(value: 1, message: 'test')),
        throwsStateError,
      );
    });

    test('node errors propagate to caller', () async {
      final graph = StateGraph<TestState>()
        ..addNode('failing', (state) => throw Exception('Node failed'))
        ..setEntryPoint('failing');

      expect(
        () => graph.invoke(TestState(value: 1, message: 'test')),
        throwsException,
      );
    });

    test('async node errors propagate', () async {
      final graph = StateGraph<TestState>()
        ..addNode('asyncFail', (state) async {
          await Future.delayed(Duration(milliseconds: 10));
          throw Exception('Async failure');
        })
        ..setEntryPoint('asyncFail');

      expect(
        () => graph.invoke(TestState(value: 1, message: 'test')),
        throwsException,
      );
    });
  });

  group('StateGraph Visualization', () {
    test('toMermaid generates diagram', () {
      final graph = StateGraph<TestState>()
        ..addNode('A', (state) => state)
        ..addNode('B', (state) => state)
        ..addEdge('A', 'B')
        ..addEdge('B', END)
        ..setEntryPoint('A');

      final mermaid = graph.toMermaid();

      expect(mermaid, contains('graph TD'));
      expect(mermaid, contains('START'));
      expect(mermaid, contains('A'));
      expect(mermaid, contains('B'));
      expect(mermaid, contains('END'));
    });

    test('toMermaid includes node descriptions', () {
      final graph = StateGraph<TestState>()
        ..addNode('process', (state) => state, description: 'Process data')
        ..setEntryPoint('process');

      final mermaid = graph.toMermaid();

      expect(mermaid, contains('Process data'));
    });

    test('toString provides summary', () {
      final graph = StateGraph<TestState>()
        ..addNode('A', (state) => state)
        ..addNode('B', (state) => state)
        ..addEdge('A', 'B')
        ..setEntryPoint('A');

      final str = graph.toString();

      expect(str, contains('StateGraph'));
      expect(str, contains('nodes: 2'));
      expect(str, contains('edges: 1'));
      expect(str, contains('entry: A'));
    });
  });

  group('GraphExecutionException', () {
    test('creates exception with message', () {
      final ex = GraphExecutionException('Test error');
      expect(ex.message, equals('Test error'));
      expect(ex.nodeName, isNull);
      expect(ex.cause, isNull);
    });

    test('creates exception with node name', () {
      final ex = GraphExecutionException('Error', nodeName: 'testNode');
      expect(ex.nodeName, equals('testNode'));
    });

    test('creates exception with cause', () {
      final cause = Exception('Root cause');
      final ex = GraphExecutionException('Error', cause: cause);
      expect(ex.cause, equals(cause));
    });

    test('toString includes all information', () {
      final cause = Exception('Root cause');
      final ex = GraphExecutionException(
        'Test error',
        nodeName: 'failingNode',
        cause: cause,
      );

      final str = ex.toString();
      expect(str, contains('GraphExecutionException'));
      expect(str, contains('Test error'));
      expect(str, contains('failingNode'));
      expect(str, contains('Root cause'));
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
