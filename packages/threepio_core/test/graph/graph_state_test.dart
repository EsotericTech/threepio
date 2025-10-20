import 'package:test/test.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('GraphState', () {
    test('custom state implements copyWith', () {
      final state = TestState(value: 42, message: 'hello');
      final copied = state.copyWith(value: 100);

      expect(copied.value, equals(100));
      expect(copied.message, equals('hello')); // Unchanged
      expect(state.value, equals(42)); // Original unchanged
    });

    test('custom state supports immutability', () {
      final state = TestState(value: 1, message: 'test');
      final updated = state.copyWith(message: 'updated');

      expect(state.message, equals('test'));
      expect(updated.message, equals('updated'));
    });
  });

  group('MapState', () {
    test('creates empty state', () {
      final state = MapState();
      expect(state.get<String>('key'), isNull);
    });

    test('creates state with initial data', () {
      final state = MapState({'name': 'Alice', 'age': 30});
      expect(state.get<String>('name'), equals('Alice'));
      expect(state.get<int>('age'), equals(30));
    });

    test('get returns correct type', () {
      final state = MapState({'count': 42, 'name': 'Bob'});
      expect(state.get<int>('count'), equals(42));
      expect(state.get<String>('name'), equals('Bob'));
    });

    test('get returns null for missing key', () {
      final state = MapState();
      expect(state.get<String>('missing'), isNull);
    });

    test('set creates new state with updated value', () {
      final state = MapState({'x': 1});
      final updated = state.set('y', 2);

      expect(state.get<int>('y'), isNull); // Original unchanged
      expect(updated.get<int>('x'), equals(1));
      expect(updated.get<int>('y'), equals(2));
    });

    test('set overwrites existing value', () {
      final state = MapState({'x': 1});
      final updated = state.set('x', 10);

      expect(state.get<int>('x'), equals(1)); // Original unchanged
      expect(updated.get<int>('x'), equals(10));
    });

    test('setAll merges multiple values', () {
      final state = MapState({'a': 1});
      final updated = state.setAll({'b': 2, 'c': 3});

      expect(updated.get<int>('a'), equals(1));
      expect(updated.get<int>('b'), equals(2));
      expect(updated.get<int>('c'), equals(3));
    });

    test('setAll overwrites existing values', () {
      final state = MapState({'x': 1, 'y': 2});
      final updated = state.setAll({'y': 20, 'z': 30});

      expect(state.get<int>('y'), equals(2)); // Original unchanged
      expect(updated.get<int>('x'), equals(1));
      expect(updated.get<int>('y'), equals(20)); // Overwritten
      expect(updated.get<int>('z'), equals(30));
    });

    test('copyWith creates independent copy', () {
      final state = MapState({'a': 1});
      final copied = state.copyWith();
      final modified = copied.set('b', 2);

      expect(state.get<int>('b'), isNull);
      expect(copied.get<int>('b'), isNull);
      expect(modified.get<int>('b'), equals(2));
    });

    test('maintains immutability through chained operations', () {
      final initial = MapState({'x': 1});
      final step1 = initial.set('y', 2);
      final step2 = step1.set('z', 3);

      expect(initial.get<int>('y'), isNull);
      expect(initial.get<int>('z'), isNull);
      expect(step1.get<int>('z'), isNull);
      expect(step2.get<int>('x'), equals(1));
      expect(step2.get<int>('y'), equals(2));
      expect(step2.get<int>('z'), equals(3));
    });

    test('supports complex types', () {
      final state = MapState({
        'list': [1, 2, 3],
        'map': {'nested': 'value'},
        'object': TestState(value: 42, message: 'test'),
      });

      expect(state.get<List<int>>('list'), equals([1, 2, 3]));
      expect(
          state.get<Map<String, String>>('map'), equals({'nested': 'value'}));
      expect(state.get<TestState>('object')?.value, equals(42));
    });

    test('toString returns meaningful representation', () {
      final state = MapState({'x': 1, 'y': 2});
      final str = state.toString();

      expect(str, contains('MapState'));
      expect(str, contains('2')); // Number of entries
    });
  });

  group('GraphResult', () {
    test('creates result with required fields', () {
      final state = TestState(value: 100, message: 'done');
      final result = GraphResult<TestState>(
        state: state,
        path: ['node1', 'node2'],
      );

      expect(result.state.value, equals(100));
      expect(result.path, equals(['node1', 'node2']));
      expect(result.metadata, isEmpty);
    });

    test('includes metadata when provided', () {
      final state = TestState(value: 1, message: 'test');
      final result = GraphResult<TestState>(
        state: state,
        path: ['start'],
        metadata: {'iterations': 5, 'duration': 100},
      );

      expect(result.metadata['iterations'], equals(5));
      expect(result.metadata['duration'], equals(100));
    });

    test('supports empty path', () {
      final state = TestState(value: 1, message: 'test');
      final result = GraphResult<TestState>(
        state: state,
        path: [],
      );

      expect(result.path, isEmpty);
    });

    test('preserves state type information', () {
      final state = MapState({'result': 'success'});
      final result = GraphResult<MapState>(
        state: state,
        path: ['process'],
      );

      expect(result.state, isA<MapState>());
      expect(result.state.get<String>('result'), equals('success'));
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
