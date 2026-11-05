/// Branches: edges whose target is chosen when the graph runs.
///
/// Port of eino `compose/branch.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'errors.dart';
import 'stream_conversion.dart';
import 'type_ref.dart';

/// Chooses one node to go on with. Port of eino
/// `compose.GraphBranchCondition`.
typedef GraphBranchCondition<T> = FutureOr<String> Function(
  RunContext ctx,
  T input,
);

/// Chooses the nodes to go on with. Port of eino
/// `compose.GraphMultiBranchCondition`.
typedef GraphMultiBranchCondition<T> = FutureOr<Set<String>> Function(
  RunContext ctx,
  T input,
);

/// Chooses one node from a stream, of which it may read only the beginning.
/// Port of eino `compose.StreamGraphBranchCondition`.
typedef StreamGraphBranchCondition<T> = FutureOr<String> Function(
  RunContext ctx,
  StreamReader<T> input,
);

/// Chooses nodes from a stream. Port of eino
/// `compose.StreamGraphMultiBranchCondition`.
typedef StreamGraphMultiBranchCondition<T> = FutureOr<Set<String>> Function(
  RunContext ctx,
  StreamReader<T> input,
);

/// A branch of a graph: a condition that looks at the output of a node and
/// names the node or nodes that run next, out of a fixed set.
///
/// Port of eino `compose.GraphBranch`. The four static methods are the ports
/// of `NewGraphBranch`, `NewGraphMultiBranch`, `NewStreamGraphBranch` and
/// `NewStreamGraphMultiBranch`; they are methods and not constructors because
/// they capture the input type [T] of the condition, which the graph checks
/// against the output type of the node the branch starts from.
///
/// ```dart
/// graph.addBranch(
///   'model',
///   GraphBranch.single<Message>(
///     (ctx, message) =>
///         message.toolCalls?.isNotEmpty ?? false ? 'tools' : Graph.end,
///     {'tools', Graph.end},
///   ),
/// );
/// ```
///
/// A stream condition gets the output of the node as a stream when the graph
/// is run in a streaming way and can decide after the first chunks. It must
/// close the stream it is given. A condition that takes a value gets the
/// joined chunks, so it waits for the whole output.
final class GraphBranch {
  GraphBranch._({
    required this.inputType,
    required this.helper,
    required Set<String> endNodes,
    required Future<List<String>> Function(RunContext ctx, Object? input)
        invoke,
    required Future<List<String>> Function(
      RunContext ctx,
      StreamReader<Object?> input,
    ) collect,
    this.index = 0,
    this.noDataFlow = false,
  })  : endNodes = Set.unmodifiable(endNodes),
        _invoke = invoke,
        _collect = collect;

  /// A branch that goes on with the one node [condition] returns. Port of
  /// eino `compose.NewGraphBranch`.
  static GraphBranch single<T>(
    GraphBranchCondition<T> condition,
    Set<String> endNodes,
  ) =>
      multi<T>((ctx, input) async => {await condition(ctx, input)}, endNodes);

  /// A branch that goes on with all the nodes [condition] returns. Port of
  /// eino `compose.NewGraphMultiBranch`.
  static GraphBranch multi<T>(
    GraphMultiBranchCondition<T> condition,
    Set<String> endNodes,
  ) =>
      newGraphBranch<T>(
        RunnablePacker<T, List<String>, Object?>(
          invoke: (ctx, input, _) async =>
              _checked(await condition(ctx, input), endNodes),
        ),
        endNodes,
      );

  /// A branch whose [condition] reads the stream. Port of eino
  /// `compose.NewStreamGraphBranch`.
  static GraphBranch stream<T>(
    StreamGraphBranchCondition<T> condition,
    Set<String> endNodes,
  ) =>
      streamMulti<T>(
        (ctx, input) async => {await condition(ctx, input)},
        endNodes,
      );

  /// A branch whose [condition] reads the stream and may return several
  /// nodes. Port of eino `compose.NewStreamGraphMultiBranch`.
  static GraphBranch streamMulti<T>(
    StreamGraphMultiBranchCondition<T> condition,
    Set<String> endNodes,
  ) =>
      newGraphBranch<T>(
        RunnablePacker<T, List<String>, Object?>(
          collect: (ctx, input, _) async =>
              _checked(await condition(ctx, input), endNodes),
        ),
        endNodes,
      );

  /// The nodes the branch can lead to. Port of eino `GraphBranch.GetEndNode`.
  final Set<String> endNodes;

  /// The input type of the condition.
  @internal
  final TypeRef<Object?> inputType;

  /// The type-dependent operations for the condition's input.
  @internal
  final GenericHelper helper;

  /// The position of this branch among the branches of its start node.
  @internal
  final int index;

  /// Whether the branch only decides what runs and carries no data. Used by
  /// workflows.
  @internal
  final bool noDataFlow;

  final Future<List<String>> Function(RunContext ctx, Object? input) _invoke;
  final Future<List<String>> Function(
    RunContext ctx,
    StreamReader<Object?> input,
  ) _collect;

  /// Runs the condition on a value.
  @internal
  Future<List<String>> invoke(RunContext ctx, Object? input) =>
      _invoke(ctx, input);

  /// Runs the condition on a stream.
  @internal
  Future<List<String>> collect(RunContext ctx, StreamReader<Object?> input) =>
      _collect(ctx, input);

  /// This branch with some of its parts replaced. A graph uses it to place
  /// the branch, a chain to translate the keys the condition returns.
  @internal
  GraphBranch copyWith({
    Set<String>? endNodes,
    int? index,
    bool? noDataFlow,
    Future<List<String>> Function(RunContext ctx, Object? input)? invoke,
    Future<List<String>> Function(
      RunContext ctx,
      StreamReader<Object?> input,
    )? collect,
  }) =>
      GraphBranch._(
        inputType: inputType,
        helper: helper,
        endNodes: endNodes ?? this.endNodes,
        index: index ?? this.index,
        noDataFlow: noDataFlow ?? this.noDataFlow,
        invoke: invoke ?? _invoke,
        collect: collect ?? _collect,
      );

  @override
  String toString() => 'GraphBranch<${inputType.name}>($endNodes)';
}

/// The branch that runs the condition packed in [packer].
///
/// Port of eino `newGraphBranch`.
@internal
GraphBranch newGraphBranch<T>(
  RunnablePacker<T, List<String>, Object?> packer,
  Set<String> endNodes,
) {
  final inputType = TypeRef<T>();
  return GraphBranch._(
    inputType: inputType,
    helper: GenericHelper.of<T, T>(),
    endNodes: endNodes,
    invoke: (ctx, input) async {
      if (input is! T) {
        throw ComposeTypeException(
          'unexpected input type. expected: $T, got: ${input.runtimeType}',
        );
      }
      return packer.invoke(ctx, input, const []);
    },
    collect: (ctx, input) async =>
        packer.collect(ctx, inputType.stream(input), const []),
  );
}

List<String> _checked(Set<String> chosen, Set<String> endNodes) {
  for (final end in chosen) {
    if (!endNodes.contains(end)) {
      throw GraphRunException(
        'branch invocation returns unintended end node: $end',
      );
    }
  }
  return chosen.toList();
}
