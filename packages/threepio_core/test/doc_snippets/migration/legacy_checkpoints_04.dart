// Mirror of doc/MIGRATION.md, break 3: legacy checkpoint classes.
// ignore_for_file: avoid_print
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

class CounterState implements GraphState {
  const CounterState([this.count = 0]);

  final int count;

  @override
  CounterState copyWith({int? count}) => CounterState(count ?? this.count);
}

Future<void> main() async {
  // Before 0.9: InMemoryCheckpointStore<CounterState>(), from the umbrella.
  final store = legacy.InMemoryCheckpointStore<CounterState>();
  final graph = StateGraph<CounterState>(
    checkpointStore: store,
    checkpointConfig: const CheckpointConfig(checkpointEveryNode: true),
  )
    ..addNode('count', (state) async => state.copyWith(count: state.count + 1))
    ..addEdge('count', END)
    ..setEntryPoint('count');

  final result = await graph.invoke(const CounterState(), threadId: 'thread-1');
  final saved = await store.list(threadId: 'thread-1');
  print('count ${result.state.count}, ${saved.length} checkpoints');
}
