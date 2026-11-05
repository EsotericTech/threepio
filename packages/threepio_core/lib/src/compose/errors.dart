/// What building and running a graph can throw.
library;

import '../core/interrupt_signal.dart';
import '../errors.dart';
import 'node_path.dart';

/// A graph, chain or one of their parts was put together wrongly: an unknown
/// node, an edge between nodes whose types do not fit, a missing start or end.
///
/// Thrown by the `add…` methods of a graph and by `compile`. Once a graph has
/// thrown one, every later `add…` call and `compile` throw it again, as in
/// Eino, where the first build error sticks to the graph.
class GraphBuildException extends ThreepioException {
  /// A build error described by [message].
  const GraphBuildException(super.message, {super.cause});

  @override
  String toString() => 'GraphBuildException: $message';
}

/// A graph was changed after it had been compiled.
///
/// Port of eino `compose.ErrGraphCompiled`.
class GraphCompiledException extends GraphBuildException {
  /// The error of a graph that was compiled already.
  const GraphCompiledException()
      : super('graph has been compiled, cannot be modified');

  @override
  String toString() => 'GraphCompiledException: $message';
}

/// A chain was changed after it had been compiled.
///
/// Port of eino `compose.ErrChainCompiled`.
class ChainCompiledException extends GraphBuildException {
  /// The error of a chain that was compiled already.
  const ChainCompiledException()
      : super('chain has been compiled, cannot be modified');

  @override
  String toString() => 'ChainCompiledException: $message';
}

/// A graph that runs in DAG mode has a cycle.
///
/// Port of eino `compose.DAGInvalidLoopErr`.
class DagLoopException extends GraphBuildException {
  /// The error for the cycles in [loops].
  DagLoopException(this.loops)
      : super('DAG is invalid, has loop: ${_format(loops)}');

  /// The cycles that were found. Each one lists its nodes in order and ends
  /// with the node it started from.
  final List<List<String>> loops;

  static String _format(List<List<String>> loops) => [
        for (final loop in loops)
          if (loop.isNotEmpty) '[${loop.join('->')}]',
      ].join();

  @override
  String toString() => 'DagLoopException: $message';
}

/// A graph ran more steps than it is allowed to.
///
/// Port of eino `compose.ErrExceedMaxSteps`. It is the [cause] of the
/// [GraphRunException] the run fails with; find it with
/// `ThreepioException.findCause<ExceedMaxStepsException>(error)`.
class ExceedMaxStepsException extends ThreepioException {
  /// The error of a run that needed more steps than its limit.
  const ExceedMaxStepsException() : super('exceeds max steps');

  @override
  String toString() => 'ExceedMaxStepsException: $message';
}

/// A value did not have the type a node, a branch or an option expected.
///
/// Types are checked when a graph is built. Where an edge leads from a wider
/// type to a narrower one (`Object?` to `String`), the check can only happen
/// when the value is there, and this is what it throws.
class ComposeTypeException extends ThreepioException {
  /// A type error described by [message].
  const ComposeTypeException(super.message);

  @override
  String toString() => 'ComposeTypeException: $message';
}

/// Reading a stream inside a graph failed, or the stream had nothing in it.
class StreamReadException extends ThreepioException {
  /// A failure to read described by [message].
  const StreamReadException(super.message, {super.cause})
      : isEmptyStream = false;

  /// The error for a stream that ended without a single chunk.
  const StreamReadException.empty()
      : isEmptyStream = true,
        super('concat stream reader fail: stream reader is empty, concat fail');

  /// Whether this is the error of a stream that had no chunk, as opposed to
  /// one that failed.
  final bool isEmptyStream;

  @override
  String toString() => 'StreamReadException: $message';
}

/// A value of a checkpoint could not be turned into bytes, because its type
/// is neither JSON nor registered with `TypeRegistry`.
///
/// It names the value: the state of the graph, the input or the output of a
/// node. The run that was interrupted fails with it instead of leaving a
/// checkpoint that could not be resumed.
class CheckpointEncodeException extends ThreepioException {
  /// The failure described by [message].
  const CheckpointEncodeException(super.message);

  @override
  String toString() => 'CheckpointEncodeException: $message';
}

/// A stream was ended on purpose, because the run it belongs to is being
/// cancelled.
///
/// Port of eino `core.ErrStreamCanceled`. The layer that cancels a run (the
/// agent runtime) ends the streams of tools and models with it. A tools node
/// treats a tool whose stream ended this way as not finished: it interrupts,
/// and the tool runs again when the run is resumed.
class StreamCanceledException extends ThreepioException {
  /// The marker of a cancelled stream.
  const StreamCanceledException([super.message = 'stream canceled']);

  @override
  String toString() => 'StreamCanceledException: $message';
}

/// A graph run failed.
///
/// Port of eino's internal graph run error. Either the run itself went wrong
/// (the step limit, a cancelled context, a branch that chose an unknown node),
/// in which case [nodePath] is empty for the graph that was called, or a node
/// failed, which is a [NodeExecutionException].
class GraphRunException extends ThreepioException {
  /// A failed run described by [message].
  GraphRunException(super.message, {super.cause, NodePath? nodePath})
      : nodePath = nodePath ?? NodePath(const []);

  /// Where the failure happened: the keys of the nested graph nodes that lead
  /// to it, outermost first, and for a [NodeExecutionException] the key of the
  /// failed node last.
  final NodePath nodePath;

  /// The same failure, seen from the graph that contains the node [key].
  GraphRunException within(String key) =>
      GraphRunException(message, cause: cause, nodePath: nodePath.prepend(key));

  /// Eino's name for the kind of failure.
  String get kind => 'GraphRunError';

  @override
  String toString() {
    final buffer = StringBuffer('[$kind] $message');
    if (nodePath.path.isNotEmpty) {
      buffer
        ..write('\n------------------------\n')
        ..write('node path: $nodePath');
    }
    return buffer.toString();
  }
}

/// A node of a graph failed.
///
/// Port of eino's internal node run error. [cause] is what the node threw and
/// [nodePath] leads to the node.
class NodeExecutionException extends GraphRunException {
  /// The failure of the node at [nodePath] with [cause].
  NodeExecutionException(NodePath nodePath, Object cause)
      : super(_describe(cause), cause: cause, nodePath: nodePath);

  /// The key of the failed node inside its own graph.
  String get nodeKey => nodePath.path.last;

  @override
  NodeExecutionException within(String key) =>
      NodeExecutionException(nodePath.prepend(key), cause!);

  @override
  String get kind => 'NodeRunError';

  static String _describe(Object cause) =>
      cause is ThreepioException ? cause.message : cause.toString();
}

/// What a graph throws for [error] thrown by its node [nodeKey].
///
/// Port of eino `wrapGraphNodeError`: an interrupt passes as it is, a failure
/// of a nested graph gets the node key in front of its path, anything else
/// becomes a [NodeExecutionException].
///
/// As in Eino (`errors.As`), the failure of a nested run is also found when
/// the node wrapped it in an error of its own, for instance a tool that runs
/// a graph: the path then leads through the node into that run, and what the
/// node wrapped around it is dropped.
Object wrapGraphNodeError(String nodeKey, Object error) {
  if (isInterrupt(error)) return error;
  final nested = ThreepioException.findCause<GraphRunException>(error);
  if (nested != null) return nested.within(nodeKey);
  return NodeExecutionException(NodePath([nodeKey]), error);
}
