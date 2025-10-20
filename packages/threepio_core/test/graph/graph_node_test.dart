import 'package:test/test.dart';
import 'package:threepio_core/src/graph/graph_node.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('GraphNode', () {
    test('creates node with name and function', () {
      final node = GraphNode<TestState>(
        name: 'testNode',
        function: (state) => state.copyWith(value: state.value + 1),
      );

      expect(node.name, equals('testNode'));
      expect(node.description, isNull);
    });

    test('creates node with description', () {
      final node = GraphNode<TestState>(
        name: 'testNode',
        function: (state) => state,
        description: 'Test node description',
      );

      expect(node.description, equals('Test node description'));
    });

    test('execute runs synchronous function', () async {
      final node = GraphNode<TestState>(
        name: 'increment',
        function: (state) => state.copyWith(value: state.value + 1),
      );

      final initialState = TestState(value: 0, message: 'test');
      final result = await node.execute(initialState);

      expect(result.value, equals(1));
      expect(result.message, equals('test')); // Unchanged
    });

    test('execute runs asynchronous function', () async {
      final node = GraphNode<TestState>(
        name: 'asyncIncrement',
        function: (state) async {
          await Future.delayed(Duration(milliseconds: 10));
          return state.copyWith(value: state.value + 10);
        },
      );

      final initialState = TestState(value: 5, message: 'test');
      final result = await node.execute(initialState);

      expect(result.value, equals(15));
    });

    test('execute can modify multiple fields', () async {
      final node = GraphNode<TestState>(
        name: 'update',
        function: (state) => state.copyWith(
          value: state.value * 2,
          message: 'updated',
        ),
      );

      final initialState = TestState(value: 3, message: 'original');
      final result = await node.execute(initialState);

      expect(result.value, equals(6));
      expect(result.message, equals('updated'));
    });

    test('execute maintains immutability', () async {
      final node = GraphNode<TestState>(
        name: 'modify',
        function: (state) => state.copyWith(value: 999),
      );

      final initialState = TestState(value: 1, message: 'test');
      final result = await node.execute(initialState);

      expect(initialState.value, equals(1)); // Original unchanged
      expect(result.value, equals(999));
    });

    test('execute handles complex transformations', () async {
      final node = GraphNode<MapState>(
        name: 'process',
        function: (state) {
          final count = state.get<int>('count') ?? 0;
          return state.setAll({
            'count': count + 1,
            'processed': true,
            'timestamp': DateTime.now().toIso8601String(),
          });
        },
      );

      final initialState = MapState({'count': 0});
      final result = await node.execute(initialState);

      expect(result.get<int>('count'), equals(1));
      expect(result.get<bool>('processed'), isTrue);
      expect(result.get<String>('timestamp'), isNotNull);
    });

    test('execute can throw errors', () async {
      final node = GraphNode<TestState>(
        name: 'failing',
        function: (state) => throw Exception('Node failed'),
      );

      final initialState = TestState(value: 1, message: 'test');

      expect(
        () => node.execute(initialState),
        throwsException,
      );
    });

    test('execute works with conditional logic', () async {
      final node = GraphNode<TestState>(
        name: 'conditional',
        function: (state) {
          if (state.value > 10) {
            return state.copyWith(message: 'high');
          } else {
            return state.copyWith(message: 'low');
          }
        },
      );

      final lowState = TestState(value: 5, message: '');
      final lowResult = await node.execute(lowState);
      expect(lowResult.message, equals('low'));

      final highState = TestState(value: 15, message: '');
      final highResult = await node.execute(highState);
      expect(highResult.message, equals('high'));
    });
  });

  group('Node Constants', () {
    test('END constant is defined', () {
      expect(END, equals('__end__'));
    });

    test('START constant is defined', () {
      expect(START, equals('__start__'));
    });

    test('constants are distinct', () {
      expect(END, isNot(equals(START)));
    });
  });

  group('NodeFunction typedef', () {
    test('accepts sync function', () async {
      NodeFunction<TestState> func = (state) => state.copyWith(value: 10);

      final result = await func(TestState(value: 1, message: 'test'));
      expect(result.value, equals(10));
    });

    test('accepts async function', () async {
      NodeFunction<TestState> func = (state) async {
        await Future.delayed(Duration(milliseconds: 1));
        return state.copyWith(value: 20);
      };

      final result = await func(TestState(value: 1, message: 'test'));
      expect(result.value, equals(20));
    });

    test('can be assigned to variables', () {
      final NodeFunction<TestState> increment =
          (state) => state.copyWith(value: state.value + 1);

      final NodeFunction<TestState> decrement =
          (state) => state.copyWith(value: state.value - 1);

      expect(increment, isA<NodeFunction<TestState>>());
      expect(decrement, isA<NodeFunction<TestState>>());
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
