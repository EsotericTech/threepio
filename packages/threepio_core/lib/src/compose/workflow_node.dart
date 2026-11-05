/// The nodes and branches of a workflow: where a node says what it depends
/// on.
///
/// Port of the `WorkflowNode` and `WorkflowBranch` half of eino
/// `compose/workflow.go`.
library;

import 'package:meta/meta.dart';

import 'errors.dart';
import 'field_mapping.dart';
import 'graph.dart';
import 'graph_branch.dart';

/// One declared dependency of a workflow node.
final class _PendingInput {
  const _PendingInput(
    this.from,
    this.mappings, {
    this.noDirectDependency = false,
    this.dependencyWithoutInput = false,
  });

  final String from;
  final List<FieldMapping> mappings;
  final bool noDirectDependency;
  final bool dependencyWithoutInput;
}

/// A node of a `Workflow`, on which its inputs and dependencies are
/// declared.
///
/// Port of eino `compose.WorkflowNode`. Every method returns the node, so
/// declarations chain:
///
/// ```dart
/// workflow.addLambdaNode('answer', answer)
///   ..addInput('retrieve', [FieldMapping.toField('documents')])
///   ..addInput(Graph.start, [FieldMapping.mapFields('question', 'question')])
///   ..setStaticValue(['language'], 'en');
/// ```
///
/// A mistake in a declaration (an unknown node, two mappings to one field) is
/// reported when the workflow is compiled.
final class WorkflowNode {
  /// The node [key] of a workflow built on [core].
  @internal
  WorkflowNode(this._core, this.key) : _mapped = MappedFieldPaths(key);

  final GraphCore _core;

  /// The key of the node.
  final String key;

  final List<_PendingInput> _inputs = [];
  /// The static values by target path (in the form of
  /// [FieldMapping.targetKey]), each with its mapping.
  final Map<String, (FieldMapping, Object?)> _staticValues = {};
  final MappedFieldPaths _mapped;

  /// Makes this node run after the node [from] and take its input from that
  /// node's output: all of it, or the fields [mappings] name.
  ///
  /// Port of eino `WorkflowNode.AddInput`. [from] may be `Graph.start`.
  WorkflowNode addInput(
    String from, [
    List<FieldMapping> mappings = const [],
  ]) {
    _inputs.add(_PendingInput(from, List.of(mappings)));
    return this;
  }

  /// Like [addInput]. With [noDirectDependency] the node takes data from
  /// [from] but does not wait for it directly: the order is left to another
  /// path that leads from [from] to this node.
  ///
  /// Port of eino `WorkflowNode.AddInputWithOptions` and
  /// `compose.WithNoDirectDependency`. It is needed where the two nodes are on
  /// different sides of a branch: a direct dependency would start this node
  /// although the branch did not choose it. A path with direct dependencies
  /// from [from] to this node must exist.
  WorkflowNode addInputWithOptions(
    String from,
    List<FieldMapping> mappings, {
    bool noDirectDependency = false,
  }) {
    _inputs.add(
      _PendingInput(
        from,
        List.of(mappings),
        noDirectDependency: noDirectDependency,
      ),
    );
    return this;
  }

  /// Makes this node run after the node [from], without taking anything from
  /// its output.
  ///
  /// Port of eino `WorkflowNode.AddDependency`.
  WorkflowNode addDependency(String from) {
    _inputs.add(_PendingInput(from, const [], dependencyWithoutInput: true));
    return this;
  }

  /// Gives the field at [path] of this node's input the fixed [value].
  ///
  /// Port of eino `WorkflowNode.SetStaticValue`. The field must not be mapped
  /// from another node as well. A second value for the same path replaces the
  /// first.
  WorkflowNode setStaticValue(List<String> path, Object? value) {
    final mapping = FieldMapping.toFieldPath(path);
    _staticValues[mapping.targetKey] = (mapping, value);
    return this;
  }

  /// Turns the declared inputs into edges of the graph.
  ///
  /// Port of the functions eino collects in `WorkflowNode.addInputs`.
  @internal
  void addInputsToGraph() {
    for (final input in _inputs) {
      final from = input.from;
      if (input.dependencyWithoutInput) {
        _core.addEdge(from, key, noData: true);
        continue;
      }
      final mappings = [
        for (final mapping in input.mappings) mapping.from(from),
      ];
      _mapped.add([for (final mapping in mappings) mapping.toPath]);
      _core.addEdge(
        from,
        key,
        noControl: input.noDirectDependency,
        mappings: mappings,
      );
    }
    _inputs.clear();
  }

  /// The static values of the node as the map of fields they add to its
  /// input, by target path; empty when it has none. Records the paths as
  /// mapped.
  @internal
  List<FieldMapping> takeStaticMappings(Map<String, Object?> into) {
    if (_staticValues.isEmpty) return const [];
    final mappings = <FieldMapping>[];
    final paths = <List<String>>[];
    for (final MapEntry(key: target, value: (mapping, value))
        in _staticValues.entries) {
      into[target] = value;
      mappings.add(mapping);
      paths.add(mapping.toPath);
    }
    _mapped.add(paths);
    return mappings;
  }
}

/// A branch of a workflow.
///
/// Port of eino `compose.WorkflowBranch`. Unlike the branch of a graph, it
/// only decides which nodes run: the nodes it can lead to declare their
/// inputs themselves, with [WorkflowNode.addInput] and
/// `noDirectDependency` where the data comes from the other side of the
/// branch.
final class WorkflowBranch {
  /// The [branch] behind the node [fromNodeKey].
  @internal
  WorkflowBranch(this.fromNodeKey, this.branch);

  /// The node whose output the condition looks at.
  final String fromNodeKey;

  /// The condition and the nodes it can choose.
  final GraphBranch branch;

  /// The nodes the branch can lead to.
  Set<String> get endNodes => branch.endNodes;

  /// Checks that the nodes the branch can lead to are nodes of the workflow.
  @internal
  void checkEndNodes(Set<String> nodeKeys) {
    for (final endNode in branch.endNodes) {
      if (endNode != Graph.end && !nodeKeys.contains(endNode)) {
        throw GraphBuildException(
          "branch end node '$endNode' needs to be added to graph first",
        );
      }
    }
  }
}
