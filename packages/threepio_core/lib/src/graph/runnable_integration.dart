import '../callbacks/callback_manager.dart';
import '../compose/runnable.dart';
import 'graph_node.dart';
import 'graph_state.dart';
import 'state_graph.dart';

/// Extension to convert StateGraph to Runnable
///
/// This allows graphs to be used anywhere Runnables are expected.
///
/// Example:
/// ```dart
/// final graph = StateGraph<MyState>()...build();
/// final runnable = graph.toRunnable();
///
/// // Use in chains or pipes
/// final pipeline = someRunnable.pipe(runnable);
/// ```
extension StateGraphRunnable<S extends GraphState> on StateGraph<S> {
  /// Convert this graph to a Runnable
  Runnable<S, GraphResult<S>> toRunnable() {
    return _GraphRunnable<S>(this);
  }
}

/// Internal Runnable wrapper for StateGraph
class _GraphRunnable<S extends GraphState>
    implements Runnable<S, GraphResult<S>> {
  _GraphRunnable(this.graph);

  final StateGraph<S> graph;

  @override
  Future<GraphResult<S>> invoke(
    S input, {
    RunnableOptions? options,
  }) async {
    return await graph.invoke(
      input,
      callbackManager: options?.callbackManager as CallbackManager?,
    );
  }

  @override
  Stream<GraphResult<S>> stream(
    S input, {
    RunnableOptions? options,
  }) async* {
    // For graphs, streaming means yielding the final result
    // Could be enhanced to stream intermediate states
    final result = await invoke(input, options: options);
    yield result;
  }

  @override
  Future<GraphResult<S>> collect(
    Stream<S> input, {
    RunnableOptions? options,
  }) async {
    // Take first input and invoke
    final firstInput = await input.first;
    return await invoke(firstInput, options: options);
  }

  @override
  Stream<GraphResult<S>> transform(
    Stream<S> input, {
    RunnableOptions? options,
  }) {
    // Map each input through the graph
    return input.asyncMap((item) => invoke(item, options: options));
  }

  @override
  Runnable<S, O2> pipe<O2>(Runnable<GraphResult<S>, O2> next) {
    return _PipeRunnable<S, GraphResult<S>, O2>(first: this, second: next);
  }

  @override
  Future<List<GraphResult<S>>> batch(
    List<S> inputs, {
    RunnableOptions? options,
  }) async {
    final results = <GraphResult<S>>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<GraphResult<S>>> batchParallel(
    List<S> inputs, {
    RunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Internal pipe implementation
class _PipeRunnable<I, M, O> implements Runnable<I, O> {
  _PipeRunnable({
    required this.first,
    required this.second,
  });

  final Runnable<I, M> first;
  final Runnable<M, O> second;

  @override
  Future<O> invoke(I input, {RunnableOptions? options}) async {
    final intermediate = await first.invoke(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> stream(I input, {RunnableOptions? options}) {
    final intermediateStream = first.stream(input, options: options);
    return second.transform(intermediateStream, options: options);
  }

  @override
  Future<O> collect(Stream<I> input, {RunnableOptions? options}) async {
    final intermediate = await first.collect(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> transform(Stream<I> input, {RunnableOptions? options}) {
    final intermediateStream = first.transform(input, options: options);
    return second.transform(intermediateStream, options: options);
  }

  @override
  Runnable<I, O2> pipe<O2>(Runnable<O, O2> next) {
    return _PipeRunnable<I, O, O2>(first: this, second: next);
  }

  @override
  Future<List<O>> batch(
    List<I> inputs, {
    RunnableOptions? options,
  }) async {
    final results = <O>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<O>> batchParallel(
    List<I> inputs, {
    RunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Extension to use Runnables as graph nodes
extension RunnableNode<I, O> on Runnable<I, O> {
  /// Convert this Runnable to a node function
  ///
  /// The state type must have a way to extract input and set output.
  ///
  /// Example:
  /// ```dart
  /// final myRunnable = lambda<String, int>((s) async => s.length);
  ///
  /// graph.addNode('process', myRunnable.asNode<MyState>(
  ///   getInput: (state) => state.text,
  ///   setOutput: (state, result) => state.copyWith(length: result),
  /// ));
  /// ```
  NodeFunction<S> asNode<S extends GraphState>({
    required I Function(S state) getInput,
    required S Function(S state, O result) setOutput,
  }) {
    return (S state) async {
      final input = getInput(state);
      final output = await invoke(input);
      return setOutput(state, output);
    };
  }
}
