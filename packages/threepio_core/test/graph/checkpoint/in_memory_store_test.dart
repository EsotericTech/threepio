import 'package:test/test.dart';
import 'package:threepio_core/src/graph/checkpoint/checkpoint.dart';
import 'package:threepio_core/src/graph/checkpoint/checkpoint_store.dart';
import 'package:threepio_core/src/graph/checkpoint/stores/in_memory_store.dart';
import 'package:threepio_core/src/graph/graph_state.dart';

void main() {
  group('InMemoryCheckpointStore', () {
    late InMemoryCheckpointStore<MapState> store;

    setUp(() {
      store = InMemoryCheckpointStore<MapState>();
    });

    Checkpoint<MapState> createTestCheckpoint({
      String? id,
      String? threadId,
      String currentNode = 'test-node',
      int iteration = 1,
    }) {
      return Checkpoint<MapState>.now(
        id: id,
        threadId: threadId,
        state: MapState({'value': iteration}),
        currentNode: currentNode,
        path: ['start'],
        iteration: iteration,
      );
    }

    group('save', () {
      test('saves checkpoint and returns ID', () async {
        final checkpoint = createTestCheckpoint();
        final id = await store.save(checkpoint);

        expect(id, isNotEmpty);
        expect(await store.count(), 1);
      });

      test('uses provided checkpoint ID', () async {
        final checkpoint = createTestCheckpoint(id: 'custom-id');
        final id = await store.save(checkpoint);

        expect(id, 'custom-id');
      });

      test('uses provided checkpointId parameter', () async {
        final checkpoint = createTestCheckpoint();
        final id = await store.save(checkpoint, checkpointId: 'override-id');

        expect(id, 'override-id');
      });

      test('isolates checkpoints by thread', () async {
        final cp1 = createTestCheckpoint(iteration: 1);
        final cp2 = createTestCheckpoint(iteration: 2);

        await store.save(cp1, threadId: 'thread-1');
        await store.save(cp2, threadId: 'thread-2');

        expect(await store.count(threadId: 'thread-1'), 1);
        expect(await store.count(threadId: 'thread-2'), 1);
        expect(await store.count(), 2);
      });
    });

    group('load', () {
      test('loads saved checkpoint by ID', () async {
        final checkpoint = createTestCheckpoint(iteration: 42);
        final id = await store.save(checkpoint, threadId: 'test');

        final loaded = await store.load(id, threadId: 'test');

        expect(loaded, isNotNull);
        expect(loaded!.iteration, 42);
        expect(loaded.state.get<int>('value'), 42);
      });

      test('returns null for non-existent ID', () async {
        final loaded = await store.load('non-existent');
        expect(loaded, isNull);
      });

      test('loads from correct thread', () async {
        final cp1 = createTestCheckpoint(id: 'same-id', iteration: 1);
        final cp2 = createTestCheckpoint(id: 'same-id', iteration: 2);

        await store.save(cp1, threadId: 'thread-1');
        await store.save(cp2, threadId: 'thread-2');

        final loaded1 = await store.load('same-id', threadId: 'thread-1');
        final loaded2 = await store.load('same-id', threadId: 'thread-2');

        expect(loaded1!.iteration, 1);
        expect(loaded2!.iteration, 2);
      });

      test('searches all threads when no threadId provided', () async {
        final checkpoint = createTestCheckpoint(id: 'unique-id');
        await store.save(checkpoint, threadId: 'some-thread');

        final loaded = await store.load('unique-id');
        expect(loaded, isNotNull);
      });
    });

    group('loadLatest', () {
      test('returns latest checkpoint by timestamp', () async {
        // Save checkpoints with different timestamps
        await store.save(
          createTestCheckpoint(id: 'cp1', iteration: 1),
          threadId: 'test',
        );

        await Future.delayed(Duration(milliseconds: 10));

        await store.save(
          createTestCheckpoint(id: 'cp2', iteration: 2),
          threadId: 'test',
        );

        await Future.delayed(Duration(milliseconds: 10));

        await store.save(
          createTestCheckpoint(id: 'cp3', iteration: 3),
          threadId: 'test',
        );

        final latest = await store.loadLatest(threadId: 'test');

        expect(latest, isNotNull);
        expect(latest!.id, 'cp3');
        expect(latest.iteration, 3);
      });

      test('returns null for empty thread', () async {
        final latest = await store.loadLatest(threadId: 'empty');
        expect(latest, isNull);
      });
    });

    group('delete', () {
      test('removes checkpoint by ID', () async {
        final id = await store.save(createTestCheckpoint(), threadId: 'test');

        expect(await store.exists(id, threadId: 'test'), true);

        await store.delete(id, threadId: 'test');

        expect(await store.exists(id, threadId: 'test'), false);
      });

      test('removes from specific thread only', () async {
        await store.save(
          createTestCheckpoint(id: 'shared-id'),
          threadId: 'thread-1',
        );
        await store.save(
          createTestCheckpoint(id: 'shared-id'),
          threadId: 'thread-2',
        );

        await store.delete('shared-id', threadId: 'thread-1');

        expect(await store.exists('shared-id', threadId: 'thread-1'), false);
        expect(await store.exists('shared-id', threadId: 'thread-2'), true);
      });
    });

    group('list', () {
      test('returns all checkpoint metadata', () async {
        await store.save(createTestCheckpoint(id: 'cp1'), threadId: 'test');
        await store.save(createTestCheckpoint(id: 'cp2'), threadId: 'test');

        final list = await store.list(threadId: 'test');

        expect(list.length, 2);
        expect(list.map((m) => m.id), containsAll(['cp1', 'cp2']));
      });

      test('filters by thread', () async {
        await store.save(createTestCheckpoint(), threadId: 'thread-1');
        await store.save(createTestCheckpoint(), threadId: 'thread-2');

        final list1 = await store.list(threadId: 'thread-1');
        final list2 = await store.list(threadId: 'thread-2');
        final listAll = await store.list();

        expect(list1.length, 1);
        expect(list2.length, 1);
        expect(listAll.length, 2);
      });

      test('returns metadata sorted by timestamp descending', () async {
        await store.save(createTestCheckpoint(id: 'old'), threadId: 'test');
        await Future.delayed(Duration(milliseconds: 10));
        await store.save(createTestCheckpoint(id: 'new'), threadId: 'test');

        final list = await store.list(threadId: 'test');

        expect(list.first.id, 'new');
        expect(list.last.id, 'old');
      });
    });

    group('clear', () {
      test('clears all checkpoints', () async {
        await store.save(createTestCheckpoint(), threadId: 'thread-1');
        await store.save(createTestCheckpoint(), threadId: 'thread-2');

        await store.clear();

        expect(await store.count(), 0);
      });

      test('clears only specified thread', () async {
        await store.save(createTestCheckpoint(), threadId: 'thread-1');
        await store.save(createTestCheckpoint(), threadId: 'thread-2');

        await store.clear(threadId: 'thread-1');

        expect(await store.count(threadId: 'thread-1'), 0);
        expect(await store.count(threadId: 'thread-2'), 1);
      });
    });

    group('getHistory', () {
      test('returns checkpoints in reverse chronological order', () async {
        for (var i = 1; i <= 5; i++) {
          await store.save(
            createTestCheckpoint(id: 'cp$i', iteration: i),
            threadId: 'test',
          );
          await Future.delayed(Duration(milliseconds: 5));
        }

        final history = await store.getHistory(threadId: 'test');

        expect(history.length, 5);
        expect(history.first.id, 'cp5');
        expect(history.last.id, 'cp1');
      });

      test('respects limit', () async {
        for (var i = 1; i <= 10; i++) {
          await store.save(
            createTestCheckpoint(id: 'cp$i'),
            threadId: 'test',
          );
        }

        final history = await store.getHistory(threadId: 'test', limit: 3);

        expect(history.length, 3);
      });

      test('filters by time range', () async {
        final now = DateTime.now();

        // Save checkpoint with old timestamp
        final oldCheckpoint = Checkpoint<MapState>(
          id: 'old',
          state: MapState({}),
          currentNode: 'node',
          path: [],
          iteration: 1,
          timestamp: now.subtract(Duration(hours: 2)),
        );
        await store.save(oldCheckpoint, threadId: 'test');

        // Save checkpoint with recent timestamp
        final newCheckpoint = Checkpoint<MapState>(
          id: 'new',
          state: MapState({}),
          currentNode: 'node',
          path: [],
          iteration: 2,
          timestamp: now,
        );
        await store.save(newCheckpoint, threadId: 'test');

        final afterHistory = await store.getHistory(
          threadId: 'test',
          after: now.subtract(Duration(hours: 1)),
        );

        expect(afterHistory.length, 1);
        expect(afterHistory.first.id, 'new');
      });
    });

    group('exists', () {
      test('returns true for existing checkpoint', () async {
        await store.save(createTestCheckpoint(id: 'exists'), threadId: 'test');

        expect(await store.exists('exists', threadId: 'test'), true);
      });

      test('returns false for non-existing checkpoint', () async {
        expect(await store.exists('not-exists', threadId: 'test'), false);
      });
    });

    group('max checkpoints enforcement', () {
      test('removes oldest when limit exceeded', () async {
        final limitedStore = InMemoryCheckpointStore<MapState>(
          config: CheckpointStoreConfig(maxCheckpointsPerThread: 3),
        );

        for (var i = 1; i <= 5; i++) {
          await limitedStore.save(
            createTestCheckpoint(id: 'cp$i', iteration: i),
            threadId: 'test',
          );
          await Future.delayed(Duration(milliseconds: 5));
        }

        expect(await limitedStore.count(threadId: 'test'), 3);

        // Oldest (cp1, cp2) should be removed
        expect(await limitedStore.exists('cp1', threadId: 'test'), false);
        expect(await limitedStore.exists('cp2', threadId: 'test'), false);

        // Newest should remain
        expect(await limitedStore.exists('cp3', threadId: 'test'), true);
        expect(await limitedStore.exists('cp4', threadId: 'test'), true);
        expect(await limitedStore.exists('cp5', threadId: 'test'), true);
      });
    });

    group('utility getters', () {
      test('totalCount returns count across all threads', () async {
        await store.save(createTestCheckpoint(), threadId: 'thread-1');
        await store.save(createTestCheckpoint(), threadId: 'thread-1');
        await store.save(createTestCheckpoint(), threadId: 'thread-2');

        expect(store.totalCount, 3);
      });

      test('threadCount returns number of threads', () async {
        await store.save(createTestCheckpoint(), threadId: 'thread-1');
        await store.save(createTestCheckpoint(), threadId: 'thread-2');
        await store.save(createTestCheckpoint(), threadId: 'thread-3');

        expect(store.threadCount, 3);
      });

      test('threadIds returns all thread IDs', () async {
        await store.save(createTestCheckpoint(), threadId: 'a');
        await store.save(createTestCheckpoint(), threadId: 'b');

        expect(store.threadIds, containsAll(['a', 'b']));
      });
    });
  });
}
