// Mirrors "Legacy API (before 0.9): StateGraph" of doc/GRAPHS.md.
// #docregion basics
import 'package:threepio_core/threepio_core.dart';

/// The state flows through the nodes; each node returns a new one.
class CounterState implements GraphState {
  const CounterState({this.count = 0});

  final int count;

  @override
  CounterState copyWith({int? count}) =>
      CounterState(count: count ?? this.count);
}

Future<GraphResult<CounterState>> countToThree() {
  final graph = StateGraph<CounterState>()
    ..addNode('increment', (state) => state.copyWith(count: state.count + 1))
    ..addConditionalEdge(
      'increment',
      (state) => state.count < 3 ? 'increment' : END,
    )
    ..setEntryPoint('increment');
  // result.state.count == 3, result.path == ['increment', 'increment', ...]
  return graph.invoke(const CounterState());
}
// #enddocregion basics

StateGraph<CounterState> builder() {
  // #docregion builder
  return GraphBuilder<CounterState>()
      .withNode('increment', (state) => state.copyWith(count: state.count + 1))
      .routeIf(
        from: 'increment',
        condition: (state) => state.count < 3,
        then: 'increment',
        otherwise: END,
      )
      .startFrom('increment')
      .build();
  // #enddocregion builder
}

Future<CounterState> asRunnable(StateGraph<CounterState> graph) async {
  // #docregion runnable
  // A LegacyRunnable over Dart Streams; not a compose Runnable.
  final runnable = graph.toRunnable();
  final result = await runnable.invoke(const CounterState());
  // #enddocregion runnable
  return result.state;
}
