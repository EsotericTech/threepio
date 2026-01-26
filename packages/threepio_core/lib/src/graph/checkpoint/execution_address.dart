/// Represents a precise location in graph execution.
///
/// Addresses allow resumption from exact points, including nested graphs
/// and parallel branches. Each address contains:
/// - The graph ID to identify which graph is executing
/// - The current node name within that graph
/// - Optional parent address for nested graph contexts
/// - Optional branch index for parallel execution paths
///
/// Example:
/// ```dart
/// // Root graph at node 'process'
/// final address = ExecutionAddress(
///   graphId: 'main-graph',
///   nodeName: 'process',
/// );
///
/// // Entering a subgraph
/// final subAddress = address.enterSubgraph('sub-graph', 'start');
/// print(subAddress.fullPath); // 'main-graph/process/sub-graph/start'
/// ```
class ExecutionAddress {
  /// Creates an execution address.
  const ExecutionAddress({
    required this.graphId,
    required this.nodeName,
    this.parentAddress,
    this.branchIndex,
    this.depth = 0,
  });

  /// Unique identifier for the graph.
  final String graphId;

  /// Current node name within the graph.
  final String nodeName;

  /// Parent address for nested graphs.
  ///
  /// When a graph invokes a subgraph, the subgraph's address will have
  /// this set to the parent graph's address at the invocation point.
  final ExecutionAddress? parentAddress;

  /// Branch index for parallel execution.
  ///
  /// When a graph executes multiple nodes in parallel, each parallel
  /// execution path gets a unique branch index (0, 1, 2, etc.).
  final int? branchIndex;

  /// Nesting depth (0 for root graph).
  ///
  /// This is automatically incremented when entering subgraphs.
  final int depth;

  /// Creates an address for entering a subgraph.
  ///
  /// The new address has this address as its parent and incremented depth.
  ExecutionAddress enterSubgraph(String subgraphId, String entryNode) {
    return ExecutionAddress(
      graphId: subgraphId,
      nodeName: entryNode,
      parentAddress: this,
      depth: depth + 1,
    );
  }

  /// Creates an address for entering a parallel branch.
  ///
  /// The new address has the same graph but tracks the branch index.
  ExecutionAddress enterBranch(int index, String nodeName) {
    return ExecutionAddress(
      graphId: graphId,
      nodeName: nodeName,
      parentAddress: this,
      branchIndex: index,
      depth: depth,
    );
  }

  /// Creates an address for moving to the next node.
  ExecutionAddress moveTo(String nextNode) {
    return ExecutionAddress(
      graphId: graphId,
      nodeName: nextNode,
      parentAddress: parentAddress,
      branchIndex: branchIndex,
      depth: depth,
    );
  }

  /// Gets the full path as a string.
  ///
  /// Example: "graph1/nodeA/subgraph/nodeB"
  String get fullPath {
    if (parentAddress != null) {
      return '${parentAddress!.fullPath}/$nodeName';
    }
    return '$graphId/$nodeName';
  }

  /// Gets the root address (top-level graph).
  ExecutionAddress get root {
    if (parentAddress == null) return this;
    return parentAddress!.root;
  }

  /// Checks if this address is a descendant of another address.
  bool isDescendantOf(ExecutionAddress other) {
    if (parentAddress == null) return false;
    if (parentAddress == other) return true;
    return parentAddress!.isDescendantOf(other);
  }

  /// Converts the address to a JSON map.
  Map<String, dynamic> toJson() => {
        'graph_id': graphId,
        'node_name': nodeName,
        if (parentAddress != null) 'parent': parentAddress!.toJson(),
        if (branchIndex != null) 'branch_index': branchIndex,
        'depth': depth,
      };

  /// Creates an address from a JSON map.
  factory ExecutionAddress.fromJson(Map<String, dynamic> json) {
    return ExecutionAddress(
      graphId: json['graph_id'] as String,
      nodeName: json['node_name'] as String,
      parentAddress: json['parent'] != null
          ? ExecutionAddress.fromJson(json['parent'] as Map<String, dynamic>)
          : null,
      branchIndex: json['branch_index'] as int?,
      depth: json['depth'] as int? ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExecutionAddress &&
          runtimeType == other.runtimeType &&
          graphId == other.graphId &&
          nodeName == other.nodeName &&
          parentAddress == other.parentAddress &&
          branchIndex == other.branchIndex &&
          depth == other.depth;

  @override
  int get hashCode => Object.hash(
        graphId,
        nodeName,
        parentAddress,
        branchIndex,
        depth,
      );

  @override
  String toString() {
    final branch = branchIndex != null ? '[branch:$branchIndex]' : '';
    return 'ExecutionAddress($fullPath$branch)';
  }
}
