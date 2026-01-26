import 'package:test/test.dart';
import 'package:threepio_core/src/graph/checkpoint/checkpoint.dart';
import 'package:threepio_core/src/graph/checkpoint/execution_address.dart';
import 'package:threepio_core/src/graph/checkpoint/serializer.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('JsonCheckpointSerializer', () {
    late JsonCheckpointSerializer<MapState> serializer;

    setUp(() {
      serializer = JsonCheckpointSerializer<MapState>(
        stateFromJson: (json) => MapState(json),
        stateToJson: (state) => state.toMap(),
      );
    });

    test('content type is application/json', () {
      expect(serializer.contentType, 'application/json');
    });

    test('serializes and deserializes basic checkpoint', () async {
      final original = Checkpoint<MapState>.now(
        id: 'test-id',
        threadId: 'thread-1',
        state: MapState({'key': 'value', 'number': 42}),
        currentNode: 'process',
        path: ['start', 'fetch'],
        iteration: 5,
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.id, original.id);
      expect(restored.threadId, original.threadId);
      expect(restored.currentNode, original.currentNode);
      expect(restored.path, original.path);
      expect(restored.iteration, original.iteration);
      expect(restored.state.get<String>('key'), 'value');
      expect(restored.state.get<int>('number'), 42);
    });

    test('serializes and deserializes checkpoint with interrupt', () async {
      final original = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'approval',
        path: ['start'],
        iteration: 2,
        interruptType: InterruptType.humanInput,
        interruptReason: 'Awaiting approval',
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.interruptType, InterruptType.humanInput);
      expect(restored.interruptReason, 'Awaiting approval');
    });

    test('serializes and deserializes checkpoint with address', () async {
      final address = ExecutionAddress(
        graphId: 'main',
        nodeName: 'outer',
      ).enterSubgraph('sub', 'inner');

      final original = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'inner',
        path: ['outer'],
        iteration: 1,
        address: address,
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.address, isNotNull);
      expect(restored.address!.graphId, 'sub');
      expect(restored.address!.nodeName, 'inner');
      expect(restored.address!.parentAddress, isNotNull);
      expect(restored.address!.parentAddress!.graphId, 'main');
    });

    test('serializes and deserializes all interrupt types', () async {
      for (final type in InterruptType.values) {
        final original = Checkpoint<MapState>.now(
          state: MapState({}),
          currentNode: 'node',
          path: [],
          iteration: 1,
          interruptType: type,
        );

        final bytes = await serializer.serialize(original);
        final restored = await serializer.deserialize(bytes);

        expect(restored.interruptType, type,
            reason: 'Failed for ${type.name}');
      }
    });

    test('handles empty state', () async {
      final original = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'node',
        path: [],
        iteration: 0,
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.state.toMap(), isEmpty);
    });

    test('handles complex nested state', () async {
      final original = Checkpoint<MapState>.now(
        state: MapState({
          'list': [1, 2, 3],
          'nested': {'a': 'b', 'c': 'd'},
          'mixed': [
            {'key': 'value'},
            42,
            'string',
          ],
        }),
        currentNode: 'node',
        path: [],
        iteration: 1,
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.state.get<List>('list'), [1, 2, 3]);
      expect(restored.state.get<Map>('nested'), {'a': 'b', 'c': 'd'});
    });

    test('preserves timestamp', () async {
      final timestamp = DateTime(2024, 6, 15, 10, 30, 45);
      final original = Checkpoint<MapState>(
        state: MapState({}),
        currentNode: 'node',
        path: [],
        iteration: 1,
        timestamp: timestamp,
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.timestamp, timestamp);
    });

    test('handles null optional fields', () async {
      final original = Checkpoint<MapState>(
        state: MapState({}),
        currentNode: 'node',
        path: [],
        iteration: 1,
        // All optional fields are null
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.id, isNull);
      expect(restored.threadId, isNull);
      expect(restored.timestamp, isNull);
      expect(restored.address, isNull);
      expect(restored.interruptType, isNull);
      expect(restored.interruptReason, isNull);
    });
  });

  group('MapStateCheckpointSerializer', () {
    late MapStateCheckpointSerializer serializer;

    setUp(() {
      serializer = const MapStateCheckpointSerializer();
    });

    test('content type is application/json', () {
      expect(serializer.contentType, 'application/json');
    });

    test('serializes and deserializes checkpoint', () async {
      final original = Checkpoint<MapState>.now(
        state: MapState({'key': 'value'}),
        currentNode: 'node',
        path: ['a', 'b'],
        iteration: 3,
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.state.get<String>('key'), 'value');
      expect(restored.currentNode, 'node');
      expect(restored.path, ['a', 'b']);
      expect(restored.iteration, 3);
    });
  });

  group('Custom Serializer', () {
    test('works with custom state class', () async {
      // Define a custom state
      final serializer = JsonCheckpointSerializer<MapState>(
        stateFromJson: (json) {
          // Custom deserialization logic
          return MapState({
            'transformed': json['original'],
          });
        },
        stateToJson: (state) {
          // Custom serialization logic
          return {
            'original': state.get('data'),
          };
        },
      );

      final original = Checkpoint<MapState>.now(
        state: MapState({'data': 'test-value'}),
        currentNode: 'node',
        path: [],
        iteration: 1,
      );

      final bytes = await serializer.serialize(original);
      final restored = await serializer.deserialize(bytes);

      expect(restored.state.get<String>('transformed'), 'test-value');
    });
  });
}
