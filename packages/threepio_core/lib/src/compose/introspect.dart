/// The structure of a compiled graph, for tools that display or inspect it.
///
/// Port of eino `compose/introspect.go`, with the Mermaid rendering of the
/// eino examples (`devops/visualize`).
library;

import 'package:meta/meta.dart';

import '../callbacks/run_info.dart';
import 'graph_branch.dart';
import 'graph_options.dart';
import 'local_state.dart';

/// What a graph knows about one of its nodes.
///
/// Port of eino `compose.GraphNodeInfo`.
@immutable
final class GraphNodeInfo {
  /// The description of a node.
  const GraphNodeInfo({
    required this.component,
    required this.name,
    this.instance,
    this.options,
    this.inputType,
    this.outputType,
    this.inputKey = '',
    this.outputKey = '',
    this.graphInfo,
    this.isPassthrough = false,
  });

  /// The kind of component the node runs.
  final ComponentType component;

  /// The component itself: the chat model, the lambda, the nested graph.
  /// `null` for a passthrough node.
  final Object? instance;

  /// The options the node was added with.
  final NodeOptions? options;

  /// The input type of the node. `null` for a passthrough node whose type
  /// follows from no neighbour.
  final Type? inputType;

  /// The output type of the node.
  final Type? outputType;

  /// The display name of the node, empty when it was given none.
  final String name;

  /// The input key of the node, or the empty string.
  final String inputKey;

  /// The output key of the node, or the empty string.
  final String outputKey;

  /// For a node that is a graph, its structure.
  final GraphInfo? graphInfo;

  /// Whether the node is a passthrough node.
  final bool isPassthrough;
}

/// The structure of a graph: its nodes, edges and branches.
///
/// Port of eino `compose.GraphInfo`. A [GraphCompileCallback] receives it when
/// a graph has been compiled.
@immutable
final class GraphInfo {
  /// The description of a graph.
  const GraphInfo({
    required this.nodes,
    required this.edges,
    required this.dataEdges,
    required this.branches,
    required this.inputType,
    required this.outputType,
    required this.component,
    this.name = '',
    this.compileOptions,
    this.localState,
  });

  /// The options the graph was compiled with.
  final GraphCompileOptions? compileOptions;

  /// The nodes by key.
  final Map<String, GraphNodeInfo> nodes;

  /// The control edges: for a node key, the keys of the nodes that run after
  /// it. `Graph.start` and `Graph.end` appear as keys of their own.
  final Map<String, List<String>> edges;

  /// The data edges: for a node key, the keys of the nodes that get its
  /// output. In a graph or a chain these are the same as [edges].
  final Map<String, List<String>> dataEdges;

  /// The branches by the key of the node they start from.
  final Map<String, List<GraphBranch>> branches;

  /// The input type of the graph.
  final Type inputType;

  /// The output type of the graph.
  final Type outputType;

  /// Whether this is a graph, a chain or a workflow.
  final ComponentType component;

  /// The name the graph was compiled with.
  final String name;

  /// The state the graph keeps per run, if any.
  final LocalState? localState;

  /// The graph as a Mermaid flowchart (`graph TD`).
  ///
  /// Port of the Mermaid generator of the eino examples. Nodes are labelled
  /// with their key and kind, lambdas are rounded, nested graphs become
  /// sub-graphs, a branch is a diamond between its start node and the nodes
  /// it can lead to. Edges that carry data without deciding the order (in
  /// workflows) are dotted.
  String toMermaid() {
    final buffer = StringBuffer('graph TD\n');
    _render(buffer, this, '', 1);
    return buffer.toString();
  }

  static const _start = 'start';
  static const _end = 'end';

  static void _render(
    StringBuffer buffer,
    GraphInfo info,
    String prefix,
    int level,
  ) {
    final indent = '  ' * level;

    String id(String key) {
      if (key == _start) return '${prefix}start_node';
      if (key == _end) return '${prefix}end_node';
      return prefix + key.replaceAll(' ', '_').replaceAll('-', '_');
    }

    final keys = <String>{
      ...info.nodes.keys,
      for (final MapEntry(key: from, value: to) in info.edges.entries) ...[
        from,
        ...to,
      ],
      for (final MapEntry(key: from, value: to) in info.dataEdges.entries) ...[
        from,
        ...to,
      ],
      for (final MapEntry(key: from, value: branches)
          in info.branches.entries) ...[
        from,
        for (final branch in branches) ...branch.endNodes,
      ],
    }.toList()
      ..sort();

    for (final key in keys) {
      final node = info.nodes[key];
      if (node == null) {
        if (key == _start || key == _end) {
          buffer.writeln('$indent${id(key)}([$key])');
        }
        continue;
      }
      final sub = node.graphInfo;
      if (sub != null) {
        buffer.writeln(
          '${indent}subgraph ${id(key)} ["$key (${node.component.einoName})"]',
        );
        _render(buffer, sub, '${id(key)}_', level + 1);
        buffer.writeln('${indent}end');
        continue;
      }
      final kind = node.isPassthrough ? 'Passthrough' : node.component.einoName;
      final (open, close) =
          node.component == ComponentType.lambda ? ('(', ')') : ('[', ']');
      buffer.writeln('$indent${id(key)}$open"$key<br/>($kind)"$close');
    }

    for (final from in info.edges.keys.toList()..sort()) {
      for (final to in info.edges[from]!) {
        buffer.writeln('$indent${id(from)} --> ${id(to)}');
      }
    }

    for (final from in info.dataEdges.keys.toList()..sort()) {
      for (final to in info.dataEdges[from]!) {
        if (info.edges[from]?.contains(to) ?? false) continue;
        buffer.writeln('$indent${id(from)} -.-> ${id(to)}');
      }
    }

    for (final from in info.branches.keys.toList()..sort()) {
      for (final (index, branch) in info.branches[from]!.indexed) {
        final decision = '${id(from)}_branch_$index';
        buffer
          ..writeln('$indent$decision{"branch"}')
          ..writeln('$indent${id(from)} --> $decision');
        for (final to in branch.endNodes.toList()..sort()) {
          buffer.writeln('$indent$decision --> ${id(to)}');
        }
      }
    }
  }
}
