import 'package:test/test.dart';
import 'package:threepio_core/src/graph/graph_builder.dart';
import 'package:threepio_core/src/graph/graph_node.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('GraphBuilder', () {
    test('creates empty builder', () {
      final builder = GraphBuilder<TestState>();
      expect(builder, isNotNull);
    });

    test('creates builder with custom max iterations', () {
      final builder = GraphBuilder<TestState>(maxIterations: 50);
      final graph = builder.build();
      expect(graph.maxIterations, equals(50));
    });

    test('withNode adds node', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('test', (state) => state.copyWith(value: 10));

      final graph = builder.build();
      expect(() => graph.setEntryPoint('test'), returnsNormally);
    });

    test('withNode supports fluent chaining', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('A', (state) => state)
        ..withNode('B', (state) => state)
        ..withNode('C', (state) => state);

      final graph = builder.build();
      expect(graph, isNotNull);
    });

    test('withNode with description', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('test', (state) => state, description: 'Test node');

      expect(builder.build(), isNotNull);
    });

    test('connect adds edge', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('A', (state) => state)
        ..withNode('B', (state) => state)
        ..connect('A', 'B');

      expect(builder.build(), isNotNull);
    });

    test('routeIf adds conditional routing', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('check', (state) => state)
        ..withNode('yes', (state) => state)
        ..withNode('no', (state) => state)
        ..routeIf(
          from: 'check',
          condition: (state) => state.value > 10,
          then: 'yes',
          otherwise: 'no',
        );

      expect(builder.build(), isNotNull);
    });

    test('routeWhen adds named routes', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('router', (state) => state)
        ..withNode('high', (state) => state)
        ..withNode('low', (state) => state)
        ..routeWhen(
          from: 'router',
          routes: {
            'high': (state) => state.value > 50,
            'low': (state) => state.value <= 50,
          },
        );

      expect(builder.build(), isNotNull);
    });

    test('parallel adds parallel edge', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('split', (state) => state)
        ..withNode('A', (state) => state)
        ..withNode('B', (state) => state)
        ..parallel(from: 'split', to: ['A', 'B']);

      expect(builder.build(), isNotNull);
    });

    test('parallel with merger', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('split', (state) => state)
        ..withNode('A', (state) => state)
        ..withNode('B', (state) => state)
        ..parallel(
          from: 'split',
          to: ['A', 'B'],
          merger: (original, results) => results.last,
        );

      expect(builder.build(), isNotNull);
    });

    test('startFrom sets entry point', () {
      final builder = GraphBuilder<TestState>()
        ..withNode('start', (state) => state)
        ..startFrom('start');

      final graph = builder.build();
      expect(
        () => graph.invoke(TestState(value: 0, message: 'test')),
        returnsNormally,
      );
    });

    test('build returns StateGraph', () {
      final builder = GraphBuilder<TestState>();
      final graph = builder.build();

      expect(graph, isNotNull);
      expect(graph.maxIterations, equals(100));
    });

    test('complete fluent example', () async {
      final graph = (GraphBuilder<TestState>()
            ..withNode('start', (state) => state.copyWith(value: 0))
            ..withNode(
                'increment', (state) => state.copyWith(value: state.value + 1))
            ..withNode(
                'double', (state) => state.copyWith(value: state.value * 2))
            ..withNode('finish', (state) => state.copyWith(message: 'done'))
            ..connect('start', 'increment')
            ..routeIf(
              from: 'increment',
              condition: (state) => state.value < 5,
              then: 'increment',
              otherwise: 'double',
            )
            ..connect('double', 'finish')
            ..connect('finish', END)
            ..startFrom('start'))
          .build();

      final result = await graph.invoke(TestState(value: 999, message: ''));

      expect(result.state.value, equals(10)); // (0+1+1+1+1+1)*2
      expect(result.state.message, equals('done'));
    });
  });

  group('GraphPatterns.linear', () {
    test('creates linear graph from nodes', () {
      final graph = GraphPatterns.linear<TestState>([
        MapEntry('A', (state) => state.copyWith(value: 1)),
        MapEntry('B', (state) => state.copyWith(value: 2)),
        MapEntry('C', (state) => state.copyWith(value: 3)),
      ]);

      expect(graph, isNotNull);
    });

    test('linear graph executes in order', () async {
      final graph = GraphPatterns.linear<TestState>([
        MapEntry('step1', (state) => state.copyWith(value: state.value + 1)),
        MapEntry('step2', (state) => state.copyWith(value: state.value + 10)),
        MapEntry('step3', (state) => state.copyWith(value: state.value + 100)),
      ]);

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(111)); // 0 + 1 + 10 + 100
      expect(result.path, equals(['step1', 'step2', 'step3']));
    });

    test('linear graph with single node', () async {
      final graph = GraphPatterns.linear<TestState>([
        MapEntry('only', (state) => state.copyWith(value: 42)),
      ]);

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(42));
    });

    test('linear graph with MapState', () async {
      final graph = GraphPatterns.linear<MapState>([
        MapEntry('init', (state) => state.set('step', 1)),
        MapEntry('process', (state) => state.set('step', 2)),
        MapEntry('finalize', (state) => state.set('step', 3)),
      ]);

      final result = await graph.invoke(MapState());

      expect(result.state.get<int>('step'), equals(3));
    });
  });

  group('GraphPatterns.loop', () {
    test('creates loop graph', () {
      final graph = GraphPatterns.loop<TestState>(
        entryNode: 'start',
        nodes: [
          MapEntry('start', (state) => state.copyWith(value: state.value + 1)),
        ],
        shouldContinue: (state) => state.value < 5,
      );

      expect(graph, isNotNull);
    });

    test('loop executes until condition false', () async {
      final graph = GraphPatterns.loop<TestState>(
        entryNode: 'increment',
        nodes: [
          MapEntry(
              'increment', (state) => state.copyWith(value: state.value + 1)),
        ],
        shouldContinue: (state) => state.value < 5,
      );

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(5));
    });

    test('loop with multiple nodes', () async {
      final graph = GraphPatterns.loop<TestState>(
        entryNode: 'double',
        nodes: [
          MapEntry('double', (state) => state.copyWith(value: state.value * 2)),
          MapEntry(
              'increment', (state) => state.copyWith(value: state.value + 1)),
        ],
        shouldContinue: (state) => state.value < 100,
      );

      final result = await graph.invoke(TestState(value: 1, message: 'test'));

      // 1 -> 2 -> 3 -> 6 -> 7 -> 14 -> 15 -> 30 -> 31 -> 62 -> 63 -> 126
      expect(result.state.value, greaterThanOrEqualTo(100));
    });

    test('loop with zero iterations', () async {
      final graph = GraphPatterns.loop<TestState>(
        entryNode: 'node',
        nodes: [
          MapEntry('node', (state) => state.copyWith(value: state.value + 1)),
        ],
        shouldContinue: (state) => false, // Never continue
      );

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(1)); // Executes once, then exits
    });

    test('loop with accumulation', () async {
      final graph = GraphPatterns.loop<MapState>(
        entryNode: 'accumulate',
        nodes: [
          MapEntry('accumulate', (state) {
            final count = state.get<int>('count') ?? 0;
            final sum = state.get<int>('sum') ?? 0;
            return state.setAll({
              'count': count + 1,
              'sum': sum + count,
            });
          }),
        ],
        shouldContinue: (state) => (state.get<int>('count') ?? 0) < 10,
      );

      final result = await graph.invoke(MapState({'count': 0, 'sum': 0}));

      expect(result.state.get<int>('count'), equals(10));
      expect(result.state.get<int>('sum'), equals(45)); // 0+1+2+...+9
    });
  });

  group('GraphPatterns.retry', () {
    test('creates retry graph', () {
      final graph = GraphPatterns.retry<TestState>(
        tryNode: 'attempt',
        tryFunction: (state) => state.copyWith(value: state.value + 1),
        isSuccess: (state) => state.value >= 3,
        maxRetries: 5,
      );

      expect(graph, isNotNull);
    });

    test('succeeds when condition met', () async {
      final graph = GraphPatterns.retry<TestState>(
        tryNode: 'try',
        tryFunction: (state) => state.copyWith(value: 10),
        isSuccess: (state) => state.value >= 5,
        maxRetries: 3,
      );

      final result = await graph.invoke(TestState(value: 0, message: 'test'));

      expect(result.state.value, equals(10));
    });
  });

  group('GraphPatterns.mapReduce', () {
    test('creates map-reduce graph', () {
      final graph = GraphPatterns.mapReduce<TestState>(
        splitNode: 'split',
        splitFunction: (state) => state,
        mappers: [
          MapEntry('mapA', (state) => state.copyWith(value: state.value + 1)),
          MapEntry('mapB', (state) => state.copyWith(value: state.value + 2)),
        ],
        mergeNode: 'merge',
        mergeFunction: (state) => state,
      );

      expect(graph, isNotNull);
    });

    test('executes map-reduce workflow', () async {
      final graph = GraphPatterns.mapReduce<TestState>(
        splitNode: 'split',
        splitFunction: (state) => state.copyWith(value: 5),
        mappers: [
          MapEntry('double', (state) => state.copyWith(value: state.value * 2)),
          MapEntry('triple', (state) => state.copyWith(value: state.value * 3)),
        ],
        mergeNode: 'merge',
        mergeFunction: (state) => state.copyWith(message: 'merged'),
      );

      final result = await graph.invoke(TestState(value: 0, message: ''));

      expect(result.state.message, equals('merged'));
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
