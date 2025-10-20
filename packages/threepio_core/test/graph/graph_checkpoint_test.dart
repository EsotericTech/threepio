import 'package:test/test.dart';
import 'package:threepio_core/src/graph/graph_checkpoint.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('Checkpoint', () {
    test('creates checkpoint with required fields', () {
      final state = TestState(value: 42, message: 'test');
      final checkpoint = Checkpoint<TestState>(
        state: state,
        currentNode: 'nodeA',
        path: ['start', 'nodeA'],
        iteration: 3,
      );

      expect(checkpoint.state.value, equals(42));
      expect(checkpoint.currentNode, equals('nodeA'));
      expect(checkpoint.path, equals(['start', 'nodeA']));
      expect(checkpoint.iteration, equals(3));
      expect(checkpoint.timestamp, isNull);
      expect(checkpoint.metadata, isEmpty);
    });

    test('creates checkpoint with timestamp', () {
      final state = TestState(value: 1, message: 'test');
      final timestamp = DateTime.now();
      final checkpoint = Checkpoint<TestState>(
        state: state,
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
        timestamp: timestamp,
      );

      expect(checkpoint.timestamp, equals(timestamp));
    });

    test('creates checkpoint with metadata', () {
      final state = TestState(value: 1, message: 'test');
      final checkpoint = Checkpoint<TestState>(
        state: state,
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
        metadata: {'custom': 'data', 'count': 5},
      );

      expect(checkpoint.metadata['custom'], equals('data'));
      expect(checkpoint.metadata['count'], equals(5));
    });

    test('Checkpoint.now creates checkpoint with current timestamp', () {
      final state = TestState(value: 1, message: 'test');
      final before = DateTime.now();

      final checkpoint = Checkpoint.now(
        state: state,
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      final after = DateTime.now();

      expect(checkpoint.timestamp, isNotNull);
      expect(
          checkpoint.timestamp!.isAfter(before.subtract(Duration(seconds: 1))),
          isTrue);
      expect(checkpoint.timestamp!.isBefore(after.add(Duration(seconds: 1))),
          isTrue);
    });

    test('Checkpoint.now with metadata', () {
      final state = TestState(value: 1, message: 'test');
      final checkpoint = Checkpoint.now(
        state: state,
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
        metadata: {'key': 'value'},
      );

      expect(checkpoint.timestamp, isNotNull);
      expect(checkpoint.metadata['key'], equals('value'));
    });

    test('preserves state immutability', () {
      final originalState = TestState(value: 10, message: 'original');
      final checkpoint = Checkpoint<TestState>(
        state: originalState,
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      // Modifying checkpoint state shouldn't affect original
      final modifiedState = checkpoint.state.copyWith(value: 20);

      expect(originalState.value, equals(10));
      expect(checkpoint.state.value, equals(10));
      expect(modifiedState.value, equals(20));
    });
  });

  group('InMemoryCheckpointStore', () {
    late InMemoryCheckpointStore<TestState> store;

    setUp(() {
      store = InMemoryCheckpointStore<TestState>();
    });

    test('creates empty store', () {
      expect(store.count, equals(0));
    });

    test('save stores checkpoint', () async {
      final checkpoint = Checkpoint.now(
        state: TestState(value: 1, message: 'test'),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      await store.save('id1', checkpoint);
      expect(store.count, equals(1));
    });

    test('load retrieves stored checkpoint', () async {
      final checkpoint = Checkpoint.now(
        state: TestState(value: 42, message: 'test'),
        currentNode: 'nodeA',
        path: ['start', 'nodeA'],
        iteration: 2,
      );

      await store.save('id1', checkpoint);
      final loaded = await store.load('id1');

      expect(loaded, isNotNull);
      expect(loaded!.state.value, equals(42));
      expect(loaded.currentNode, equals('nodeA'));
      expect(loaded.iteration, equals(2));
    });

    test('load returns null for non-existent id', () async {
      final loaded = await store.load('nonexistent');
      expect(loaded, isNull);
    });

    test('save overwrites existing checkpoint', () async {
      final checkpoint1 = Checkpoint.now(
        state: TestState(value: 1, message: 'first'),
        currentNode: 'node1',
        path: ['node1'],
        iteration: 1,
      );

      final checkpoint2 = Checkpoint.now(
        state: TestState(value: 2, message: 'second'),
        currentNode: 'node2',
        path: ['node1', 'node2'],
        iteration: 2,
      );

      await store.save('id1', checkpoint1);
      await store.save('id1', checkpoint2);

      expect(store.count, equals(1)); // Still just one entry

      final loaded = await store.load('id1');
      expect(loaded!.state.value, equals(2));
      expect(loaded.currentNode, equals('node2'));
    });

    test('delete removes checkpoint', () async {
      final checkpoint = Checkpoint.now(
        state: TestState(value: 1, message: 'test'),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      await store.save('id1', checkpoint);
      expect(store.count, equals(1));

      await store.delete('id1');
      expect(store.count, equals(0));

      final loaded = await store.load('id1');
      expect(loaded, isNull);
    });

    test('delete non-existent id is safe', () async {
      await store.delete('nonexistent');
      expect(store.count, equals(0));
    });

    test('list returns all checkpoint ids', () async {
      final checkpoint1 = Checkpoint.now(
        state: TestState(value: 1, message: 'test'),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      final checkpoint2 = Checkpoint.now(
        state: TestState(value: 2, message: 'test'),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      await store.save('id1', checkpoint1);
      await store.save('id2', checkpoint2);
      await store.save('id3', checkpoint1);

      final ids = await store.list();
      expect(ids, hasLength(3));
      expect(ids, containsAll(['id1', 'id2', 'id3']));
    });

    test('list returns empty for empty store', () async {
      final ids = await store.list();
      expect(ids, isEmpty);
    });

    test('clear removes all checkpoints', () async {
      final checkpoint = Checkpoint.now(
        state: TestState(value: 1, message: 'test'),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      await store.save('id1', checkpoint);
      await store.save('id2', checkpoint);
      await store.save('id3', checkpoint);

      expect(store.count, equals(3));

      await store.clear();
      expect(store.count, equals(0));

      final ids = await store.list();
      expect(ids, isEmpty);
    });

    test('clear on empty store is safe', () async {
      await store.clear();
      expect(store.count, equals(0));
    });

    test('supports multiple checkpoint types', () async {
      final testStore = InMemoryCheckpointStore<TestState>();
      final mapStore = InMemoryCheckpointStore<MapState>();

      final testCheckpoint = Checkpoint.now(
        state: TestState(value: 1, message: 'test'),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      final mapCheckpoint = Checkpoint.now(
        state: MapState({'key': 'value'}),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      await testStore.save('test', testCheckpoint);
      await mapStore.save('map', mapCheckpoint);

      final loadedTest = await testStore.load('test');
      final loadedMap = await mapStore.load('map');

      expect(loadedTest, isNotNull);
      expect(loadedMap, isNotNull);
      expect(loadedTest!.state, isA<TestState>());
      expect(loadedMap!.state, isA<MapState>());
    });

    test('handles concurrent saves', () async {
      final checkpoints = List.generate(
        100,
        (i) => Checkpoint.now(
          state: TestState(value: i, message: 'test'),
          currentNode: 'node$i',
          path: ['node$i'],
          iteration: i,
        ),
      );

      await Future.wait(
        checkpoints.asMap().entries.map(
              (entry) => store.save('id${entry.key}', entry.value),
            ),
      );

      expect(store.count, equals(100));

      final ids = await store.list();
      expect(ids, hasLength(100));
    });
  });

  group('JsonCheckpoint', () {
    test('creates json checkpoint with required fields', () {
      final jsonCheckpoint = JsonCheckpoint(
        state: {'value': 42, 'message': 'test'},
        currentNode: 'nodeA',
        path: ['start', 'nodeA'],
        iteration: 3,
      );

      expect(jsonCheckpoint.state['value'], equals(42));
      expect(jsonCheckpoint.currentNode, equals('nodeA'));
      expect(jsonCheckpoint.path, equals(['start', 'nodeA']));
      expect(jsonCheckpoint.iteration, equals(3));
    });

    test('creates json checkpoint with timestamp', () {
      final timestamp = DateTime.now().toIso8601String();
      final jsonCheckpoint = JsonCheckpoint(
        state: {'value': 1},
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
        timestamp: timestamp,
      );

      expect(jsonCheckpoint.timestamp, equals(timestamp));
    });

    test('creates json checkpoint with metadata', () {
      final jsonCheckpoint = JsonCheckpoint(
        state: {'value': 1},
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
        metadata: {'custom': 'data'},
      );

      expect(jsonCheckpoint.metadata['custom'], equals('data'));
    });

    test('toJson serializes checkpoint', () {
      final timestamp = DateTime(2024, 1, 1, 12, 0, 0).toIso8601String();
      final jsonCheckpoint = JsonCheckpoint(
        state: {'value': 42, 'message': 'test'},
        currentNode: 'nodeA',
        path: ['start', 'nodeA'],
        iteration: 3,
        timestamp: timestamp,
        metadata: {'key': 'value'},
      );

      final json = jsonCheckpoint.toJson();

      expect(json['state'], equals({'value': 42, 'message': 'test'}));
      expect(json['current_node'], equals('nodeA'));
      expect(json['path'], equals(['start', 'nodeA']));
      expect(json['iteration'], equals(3));
      expect(json['timestamp'], isNotNull);
      expect(json['metadata'], equals({'key': 'value'}));
    });

    test('fromJson deserializes checkpoint', () {
      final json = {
        'state': {'value': 42, 'message': 'test'},
        'current_node': 'nodeA',
        'path': ['start', 'nodeA'],
        'iteration': 3,
        'timestamp': DateTime(2024, 1, 1, 12, 0, 0).toIso8601String(),
        'metadata': {'key': 'value'},
      };

      final checkpoint = JsonCheckpoint.fromJson(json);

      expect(checkpoint.state['value'], equals(42));
      expect(checkpoint.state['message'], equals('test'));
      expect(checkpoint.currentNode, equals('nodeA'));
      expect(checkpoint.path, equals(['start', 'nodeA']));
      expect(checkpoint.iteration, equals(3));
      expect(checkpoint.timestamp, isNotNull);
      expect(checkpoint.metadata['key'], equals('value'));
    });

    test('roundtrip serialization preserves data', () {
      final original = JsonCheckpoint(
        state: {
          'value': 42,
          'nested': {'key': 'value'}
        },
        currentNode: 'nodeA',
        path: ['start', 'middle', 'nodeA'],
        iteration: 5,
        timestamp: DateTime.now().toIso8601String(),
        metadata: {'custom': 'data', 'count': 10},
      );

      final json = original.toJson();
      final restored = JsonCheckpoint.fromJson(json);

      expect(restored.state, equals(original.state));
      expect(restored.currentNode, equals(original.currentNode));
      expect(restored.path, equals(original.path));
      expect(restored.iteration, equals(original.iteration));
      expect(restored.metadata, equals(original.metadata));
    });
  });

  group('CheckpointStore interface', () {
    test('InMemoryCheckpointStore implements CheckpointStore', () {
      final store = InMemoryCheckpointStore<TestState>();
      expect(store, isA<CheckpointStore<TestState>>());
    });

    test('store can be used polymorphically', () async {
      CheckpointStore<TestState> store = InMemoryCheckpointStore<TestState>();

      final checkpoint = Checkpoint.now(
        state: TestState(value: 1, message: 'test'),
        currentNode: 'node',
        path: ['node'],
        iteration: 1,
      );

      await store.save('id', checkpoint);
      final loaded = await store.load('id');

      expect(loaded, isNotNull);
      expect(loaded!.state.value, equals(1));
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
