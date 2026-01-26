import 'package:test/test.dart';
import 'package:threepio_core/src/graph/checkpoint/checkpoint.dart';
import 'package:threepio_core/src/graph/checkpoint/execution_address.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('Checkpoint', () {
    test('creates checkpoint with required fields', () {
      final state = MapState({'value': 42});
      final checkpoint = Checkpoint<MapState>(
        state: state,
        currentNode: 'process',
        path: ['start', 'fetch'],
        iteration: 2,
      );

      expect(checkpoint.state.get<int>('value'), 42);
      expect(checkpoint.currentNode, 'process');
      expect(checkpoint.path, ['start', 'fetch']);
      expect(checkpoint.iteration, 2);
      expect(checkpoint.isInterrupt, false);
    });

    test('Checkpoint.now sets timestamp and generates ID', () {
      final checkpoint = Checkpoint<MapState>.now(
        state: MapState({'key': 'value'}),
        currentNode: 'node1',
        path: [],
        iteration: 1,
      );

      expect(checkpoint.id, isNotNull);
      expect(checkpoint.timestamp, isNotNull);
      expect(checkpoint.timestamp!.difference(DateTime.now()).inSeconds.abs(),
          lessThan(2));
    });

    test('checkpoint with interrupt fields', () {
      final checkpoint = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'approval',
        path: ['start'],
        iteration: 1,
        interruptType: InterruptType.humanInput,
        interruptReason: 'Awaiting user approval',
      );

      expect(checkpoint.isInterrupt, true);
      expect(checkpoint.isAwaitingInput, true);
      expect(checkpoint.interruptType, InterruptType.humanInput);
      expect(checkpoint.interruptReason, 'Awaiting user approval');
    });

    test('withPendingInput creates copy with input', () {
      final checkpoint = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'approval',
        path: [],
        iteration: 1,
        interruptType: InterruptType.humanInput,
      );

      final withInput = checkpoint.withPendingInput('user-response');

      expect(withInput.pendingInput, 'user-response');
      expect(withInput.currentNode, checkpoint.currentNode);
      expect(withInput.interruptType, checkpoint.interruptType);
    });

    test('withMetadata merges metadata', () {
      final checkpoint = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'node',
        path: [],
        iteration: 1,
        metadata: {'key1': 'value1'},
      );

      final updated = checkpoint.withMetadata({'key2': 'value2'});

      expect(updated.metadata['key1'], 'value1');
      expect(updated.metadata['key2'], 'value2');
    });

    test('withId creates copy with new ID', () {
      final checkpoint = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'node',
        path: [],
        iteration: 1,
      );

      final originalId = checkpoint.id;
      final withNewId = checkpoint.withId('custom-id');

      expect(withNewId.id, 'custom-id');
      expect(withNewId.id, isNot(originalId));
    });

    test('withThreadId creates copy with new thread ID', () {
      final checkpoint = Checkpoint<MapState>.now(
        state: MapState({}),
        currentNode: 'node',
        path: [],
        iteration: 1,
        threadId: 'thread-1',
      );

      final updated = checkpoint.withThreadId('thread-2');

      expect(updated.threadId, 'thread-2');
    });
  });

  group('CheckpointMetadata', () {
    test('creates metadata with required fields', () {
      final metadata = CheckpointMetadata(
        id: 'cp-1',
        threadId: 'thread-1',
        currentNode: 'process',
        iteration: 5,
        timestamp: DateTime(2024, 1, 15),
      );

      expect(metadata.id, 'cp-1');
      expect(metadata.threadId, 'thread-1');
      expect(metadata.currentNode, 'process');
      expect(metadata.iteration, 5);
      expect(metadata.isInterrupt, false);
    });

    test('metadata with interrupt info', () {
      final metadata = CheckpointMetadata(
        id: 'cp-1',
        threadId: 'thread-1',
        currentNode: 'approval',
        iteration: 3,
        timestamp: DateTime(2024, 1, 15),
        interruptType: InterruptType.beforeNode,
        interruptReason: 'Manual interrupt',
      );

      expect(metadata.isInterrupt, true);
      expect(metadata.interruptType, InterruptType.beforeNode);
    });
  });

  group('InterruptType', () {
    test('all interrupt types are defined', () {
      expect(InterruptType.values.length, 6);
      expect(InterruptType.values, contains(InterruptType.beforeNode));
      expect(InterruptType.values, contains(InterruptType.afterNode));
      expect(InterruptType.values, contains(InterruptType.humanInput));
      expect(InterruptType.values, contains(InterruptType.conditional));
      expect(InterruptType.values, contains(InterruptType.manual));
      expect(InterruptType.values, contains(InterruptType.error));
    });
  });

  group('ExecutionAddress', () {
    test('creates simple address', () {
      final address = ExecutionAddress(
        graphId: 'main-graph',
        nodeName: 'process',
      );

      expect(address.graphId, 'main-graph');
      expect(address.nodeName, 'process');
      expect(address.depth, 0);
      expect(address.parentAddress, isNull);
      expect(address.fullPath, 'main-graph/process');
    });

    test('enterSubgraph creates nested address', () {
      final parent = ExecutionAddress(
        graphId: 'main',
        nodeName: 'outer',
      );

      final child = parent.enterSubgraph('sub-graph', 'inner');

      expect(child.graphId, 'sub-graph');
      expect(child.nodeName, 'inner');
      expect(child.depth, 1);
      expect(child.parentAddress, parent);
      expect(child.fullPath, 'main/outer/inner');
    });

    test('enterBranch creates branch address', () {
      final main = ExecutionAddress(
        graphId: 'graph',
        nodeName: 'fork',
      );

      final branch = main.enterBranch(0, 'parallel-1');

      expect(branch.branchIndex, 0);
      expect(branch.nodeName, 'parallel-1');
      expect(branch.parentAddress, main);
    });

    test('moveTo creates address at next node', () {
      final current = ExecutionAddress(
        graphId: 'graph',
        nodeName: 'node1',
      );

      final next = current.moveTo('node2');

      expect(next.graphId, 'graph');
      expect(next.nodeName, 'node2');
      expect(next.depth, current.depth);
    });

    test('root returns top-level address', () {
      final root = ExecutionAddress(graphId: 'root', nodeName: 'start');
      final child = root.enterSubgraph('sub1', 'a');
      final grandchild = child.enterSubgraph('sub2', 'b');

      expect(grandchild.root, root);
      expect(child.root, root);
      expect(root.root, root);
    });

    test('isDescendantOf checks ancestry', () {
      final root = ExecutionAddress(graphId: 'root', nodeName: 'start');
      final child = root.enterSubgraph('sub1', 'a');
      final grandchild = child.enterSubgraph('sub2', 'b');
      final unrelated = ExecutionAddress(graphId: 'other', nodeName: 'x');

      expect(grandchild.isDescendantOf(root), true);
      expect(grandchild.isDescendantOf(child), true);
      expect(child.isDescendantOf(root), true);
      expect(root.isDescendantOf(child), false);
      expect(grandchild.isDescendantOf(unrelated), false);
    });

    test('toJson and fromJson roundtrip', () {
      final original = ExecutionAddress(
        graphId: 'main',
        nodeName: 'node',
        depth: 2,
        branchIndex: 1,
      );

      final json = original.toJson();
      final restored = ExecutionAddress.fromJson(json);

      expect(restored.graphId, original.graphId);
      expect(restored.nodeName, original.nodeName);
      expect(restored.depth, original.depth);
      expect(restored.branchIndex, original.branchIndex);
    });

    test('nested address toJson and fromJson', () {
      final parent = ExecutionAddress(graphId: 'main', nodeName: 'outer');
      final child = parent.enterSubgraph('sub', 'inner');

      final json = child.toJson();
      final restored = ExecutionAddress.fromJson(json);

      expect(restored.graphId, 'sub');
      expect(restored.nodeName, 'inner');
      expect(restored.parentAddress, isNotNull);
      expect(restored.parentAddress!.graphId, 'main');
    });

    test('equality', () {
      final a = ExecutionAddress(graphId: 'g', nodeName: 'n', depth: 1);
      final b = ExecutionAddress(graphId: 'g', nodeName: 'n', depth: 1);
      final c = ExecutionAddress(graphId: 'g', nodeName: 'n', depth: 2);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, b.hashCode);
    });
  });
}
