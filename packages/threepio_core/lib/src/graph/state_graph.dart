import 'dart:async';

import 'package:uuid/uuid.dart';

import '../callbacks/callback_manager.dart';
import '../callbacks/run_info.dart';
import 'checkpoint/checkpoint.dart';
import 'checkpoint/checkpoint_config.dart';
import 'checkpoint/checkpoint_store.dart';
import 'checkpoint/exceptions.dart';
import 'checkpoint/execution_address.dart';
import 'checkpoint/hitl.dart';
import 'graph_edge.dart';
import 'graph_node.dart';
import 'graph_state.dart';

/// Builder and executor for state-based graphs
///
/// StateGraph provides a declarative API for building complex workflows
/// with branching, loops, and parallel execution.
///
/// Example:
/// ```dart
/// final graph = StateGraph<MyState>()
///   ..addNode('fetch', fetchNode)
///   ..addNode('process', processNode)
///   ..addNode('respond', respondNode)
///   ..addEdge('fetch', 'process')
///   ..addConditionalEdge('process', (state) {
///     return state.needsMoreData ? 'fetch' : 'respond';
///   })
///   ..setEntryPoint('fetch');
///
/// final result = await graph.invoke(MyState(query: 'hello'));
/// ```
class StateGraph<S extends GraphState> {
  StateGraph({
    this.maxIterations = 100,
    this.checkpointStore,
    this.checkpointConfig,
    String? graphId,
  }) : graphId = graphId ?? const Uuid().v4();

  /// Maximum iterations to prevent infinite loops
  final int maxIterations;

  /// Optional checkpoint store for persistence
  final CheckpointStore<S>? checkpointStore;

  /// Checkpoint configuration
  final CheckpointConfig? checkpointConfig;

  /// Unique identifier for this graph
  final String graphId;

  /// All nodes in the graph
  final Map<String, GraphNode<S>> _nodes = {};

  /// All edges in the graph
  final List<GraphEdge<S>> _edges = [];

  /// Human-in-the-loop nodes
  final Map<String, HumanInputNode<S, dynamic>> _hitlNodes = {};

  /// Entry point node name
  String? _entryPoint;

  /// Add a node to the graph
  ///
  /// [name] - Unique identifier for this node
  /// [function] - Function to execute when node is visited
  /// [description] - Optional description for debugging
  StateGraph<S> addNode(
    String name,
    NodeFunction<S> function, {
    String? description,
  }) {
    if (_nodes.containsKey(name)) {
      throw ArgumentError('Node "$name" already exists');
    }

    _nodes[name] = GraphNode<S>(
      name: name,
      function: function,
      description: description,
    );

    return this;
  }

  /// Add a direct edge between two nodes
  ///
  /// [from] - Source node name
  /// [to] - Target node name
  StateGraph<S> addEdge(String from, String to) {
    _validateNode(from);
    _validateNode(to, allowEnd: true);

    _edges.add(DirectEdge<S>(from: from, to: to));

    return this;
  }

  /// Add a conditional edge that routes based on state
  ///
  /// [from] - Source node name
  /// [router] - Function that returns the next node name based on state
  /// [description] - Optional description for debugging
  StateGraph<S> addConditionalEdge(
    String from,
    FutureOr<String> Function(S state) router, {
    String? description,
  }) {
    _validateNode(from);

    _edges.add(ConditionalEdge<S>(
      from: from,
      router: router,
      description: description,
    ));

    return this;
  }

  /// Add a conditional router with named routes
  ///
  /// [from] - Source node name
  /// [routes] - Map of route names to condition functions
  /// [defaultRoute] - Default route if no conditions match (defaults to END)
  StateGraph<S> addConditionalRouter(
    String from,
    Map<String, bool Function(S state)> routes, {
    String defaultRoute = END,
  }) {
    _validateNode(from);

    _edges.add(ConditionalRouter<S>(
      from: from,
      routes: routes,
      defaultRoute: defaultRoute,
    ));

    return this;
  }

  /// Add a parallel edge that executes multiple nodes concurrently
  ///
  /// [from] - Source node name
  /// [to] - List of target node names to execute in parallel
  /// [merger] - Optional function to merge results from parallel branches
  StateGraph<S> addParallelEdge(
    String from,
    List<String> to, {
    S Function(S originalState, List<S> results)? merger,
  }) {
    _validateNode(from);
    for (final target in to) {
      _validateNode(target);
    }

    _edges.add(ParallelEdge<S>(
      from: from,
      to: to,
      merger: merger,
    ));

    return this;
  }

  /// Set the entry point of the graph
  ///
  /// This is the first node to execute.
  StateGraph<S> setEntryPoint(String nodeName) {
    _validateNode(nodeName);
    _entryPoint = nodeName;
    return this;
  }

  /// Add a human-in-the-loop node to the graph.
  ///
  /// HITL nodes pause execution and throw [HumanInputRequired] when reached.
  /// Use [resumeWithHumanInput] to continue execution with the provided input.
  ///
  /// Example:
  /// ```dart
  /// final approvalNode = HumanInputNode<MyState, bool>(
  ///   name: 'approval',
  ///   prompt: (state) => 'Approve: ${state.summary}?',
  ///   processInput: (state, approved) => state.copyWith(approved: approved),
  /// );
  ///
  /// graph.addHumanInputNode(approvalNode);
  /// ```
  StateGraph<S> addHumanInputNode<I>(HumanInputNode<S, I> hitlNode) {
    // Store the HITL node for later resume
    _hitlNodes[hitlNode.name] = hitlNode;

    // Add a node that triggers the interrupt
    return addNode(
      hitlNode.name,
      (state) async {
        // Create checkpoint for the interrupt
        final checkpoint = Checkpoint<S>.now(
          state: state,
          currentNode: hitlNode.name,
          path: [], // Will be filled by execution context
          iteration: 0, // Will be filled by execution context
          interruptType: InterruptType.humanInput,
          interruptReason: hitlNode.prompt(state),
        );

        throw HumanInputRequired<S, I>(
          nodeName: hitlNode.name,
          prompt: hitlNode.prompt(state),
          checkpoint: checkpoint,
          validator: hitlNode.validator,
          timeout: hitlNode.timeout,
        );
      },
      description: hitlNode.description ?? 'Human input: ${hitlNode.name}',
    );
  }

  /// Resume execution from a checkpoint with human input.
  ///
  /// Use this after catching [HumanInputRequired] to continue execution.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await graph.invoke(initialState, threadId: 'user-123');
  /// } on HumanInputRequired<MyState, bool> catch (e) {
  ///   final userApproval = await getUserApproval();
  ///   final result = await graph.resumeWithHumanInput<bool>(
  ///     e.checkpoint.id!,
  ///     input: userApproval,
  ///     threadId: 'user-123',
  ///   );
  /// }
  /// ```
  Future<GraphResult<S>> resumeWithHumanInput<I>(
    String checkpointId, {
    required I input,
    String? threadId,
    CallbackManager? callbackManager,
  }) async {
    if (checkpointStore == null) {
      throw StateError(
        'Cannot resume without checkpoint store. '
        'Provide checkpointStore when creating StateGraph.',
      );
    }

    final checkpoint = await checkpointStore!.load(checkpointId, threadId: threadId);
    if (checkpoint == null) {
      throw CheckpointNotFoundException(checkpointId, threadId: threadId);
    }

    final hitlNode = _hitlNodes[checkpoint.currentNode];
    if (hitlNode == null) {
      throw CheckpointIncompatibleException(
        'Node "${checkpoint.currentNode}" is not a HITL node',
        checkpointId: checkpointId,
      );
    }

    // Process the input and update state
    final updatedState = hitlNode.resumeWithInput(checkpoint.state, input);

    // Find the next node after the HITL node
    final nextNodes = await _getNextNodes(checkpoint.currentNode, updatedState);
    final nextNode = nextNodes.isNotEmpty ? nextNodes.first : END;

    // Continue execution from the next node
    return _executeGraph(
      updatedState,
      startNode: nextNode,
      startIteration: checkpoint.iteration,
      existingPath: [...checkpoint.path, checkpoint.currentNode],
      threadId: threadId,
    );
  }

  /// Execute the graph with the given initial state
  ///
  /// [initialState] - Starting state (ignored if resuming from checkpoint)
  /// [callbackManager] - Optional callback manager for observability
  /// [checkpointId] - Optional checkpoint ID to resume from
  /// [threadId] - Optional thread ID for checkpoint isolation
  Future<GraphResult<S>> invoke(
    S initialState, {
    CallbackManager? callbackManager,
    String? checkpointId,
    String? threadId,
  }) async {
    // Resume from checkpoint if provided
    if (checkpointId != null) {
      return _resumeFromCheckpoint(
        checkpointId,
        threadId: threadId,
      );
    }

    if (_entryPoint == null) {
      throw StateError('Entry point not set. Call setEntryPoint() first.');
    }

    if (callbackManager != null) {
      final runInfo = RunInfo(
        name: 'StateGraph',
        type: 'StateGraph<$S>',
        componentType: ComponentType.custom,
        metadata: {
          'entry_point': _entryPoint,
          'node_count': _nodes.length,
          'edge_count': _edges.length,
          'graph_id': graphId,
        },
      );

      return await callbackManager.runWithCallbacks(
        {},
        runInfo,
        initialState,
        () => _executeGraph(
          initialState,
          threadId: threadId,
        ),
      );
    } else {
      return _executeGraph(
        initialState,
        threadId: threadId,
      );
    }
  }

  /// Resume execution from a checkpoint.
  Future<GraphResult<S>> _resumeFromCheckpoint(
    String checkpointId, {
    String? threadId,
  }) async {
    if (checkpointStore == null) {
      throw StateError(
        'Cannot resume without checkpoint store. '
        'Provide checkpointStore when creating StateGraph.',
      );
    }

    final checkpoint = await checkpointStore!.load(checkpointId, threadId: threadId);
    if (checkpoint == null) {
      throw CheckpointNotFoundException(checkpointId, threadId: threadId);
    }

    // For HITL checkpoints, throw error - use resumeWithHumanInput instead
    if (checkpoint.interruptType == InterruptType.humanInput) {
      throw CheckpointIncompatibleException(
        'Checkpoint requires human input. Use resumeWithHumanInput() instead.',
        checkpointId: checkpointId,
      );
    }

    // Determine start node based on interrupt type
    String startNode;
    if (checkpoint.interruptType == InterruptType.beforeNode) {
      // Resume at the node that was about to execute
      startNode = checkpoint.currentNode;
    } else {
      // Resume at next node after the checkpoint node
      final nextNodes = await _getNextNodes(checkpoint.currentNode, checkpoint.state);
      startNode = nextNodes.isNotEmpty ? nextNodes.first : END;
    }

    return _executeGraph(
      checkpoint.state,
      startNode: startNode,
      startIteration: checkpoint.iteration,
      existingPath: checkpoint.path,
      threadId: threadId ?? checkpoint.threadId,
    );
  }

  /// Internal graph execution with checkpoint support.
  Future<GraphResult<S>> _executeGraph(
    S initialState, {
    String? startNode,
    int startIteration = 0,
    List<String>? existingPath,
    String? threadId,
  }) async {
    var currentState = initialState;
    var currentNode = startNode ?? _entryPoint!;
    final path = existingPath?.toList() ?? <String>[];
    var iterations = startIteration;

    final config = checkpointConfig;
    final effectiveThreadId = threadId ?? config?.threadIdProvider?.call();

    while (currentNode != END && iterations < maxIterations) {
      iterations++;

      // Check for interrupt BEFORE node
      if (config != null && config.shouldInterruptBefore(currentNode)) {
        final checkpoint = await _createCheckpoint(
          state: currentState,
          currentNode: currentNode,
          path: path,
          iteration: iterations,
          threadId: effectiveThreadId,
          interruptType: InterruptType.beforeNode,
          interruptReason: 'Interrupt before node: $currentNode',
        );

        throw GraphInterruptException<S>(
          checkpoint: checkpoint,
          reason: 'Interrupt before node: $currentNode',
        );
      }

      path.add(currentNode);

      // Execute current node
      final node = _nodes[currentNode]!;
      try {
        currentState = await node.execute(currentState);
      } on HumanInputRequired<S, dynamic> catch (e) {
        // Update checkpoint with current execution context
        final checkpoint = Checkpoint<S>.now(
          state: e.checkpoint.state,
          currentNode: currentNode,
          path: path,
          iteration: iterations,
          threadId: effectiveThreadId,
          interruptType: InterruptType.humanInput,
          interruptReason: e.prompt,
          address: ExecutionAddress(graphId: graphId, nodeName: currentNode),
        );

        // Save checkpoint if configured
        if (checkpointStore != null && (config?.autoSave ?? false)) {
          await checkpointStore!.save(checkpoint, threadId: effectiveThreadId);
        }

        throw HumanInputRequired<S, dynamic>(
          nodeName: e.nodeName,
          prompt: e.prompt,
          checkpoint: checkpoint,
          validator: e.validator,
          timeout: e.timeout,
        );
      } catch (error) {
        // Create checkpoint on error if configured
        if (config != null && config.checkpointOnError && checkpointStore != null) {
          final errorCheckpoint = await _createCheckpoint(
            state: currentState,
            currentNode: currentNode,
            path: path,
            iteration: iterations,
            threadId: effectiveThreadId,
            interruptType: InterruptType.error,
            interruptReason: 'Error: $error',
          );

          await checkpointStore!.save(errorCheckpoint, threadId: effectiveThreadId);
        }
        rethrow;
      }

      // Check for interrupt AFTER node
      if (config != null && config.shouldInterruptAfter(currentNode)) {
        final checkpoint = await _createCheckpoint(
          state: currentState,
          currentNode: currentNode,
          path: path,
          iteration: iterations,
          threadId: effectiveThreadId,
          interruptType: InterruptType.afterNode,
          interruptReason: 'Interrupt after node: $currentNode',
        );

        throw GraphInterruptException<S>(
          checkpoint: checkpoint,
          reason: 'Interrupt after node: $currentNode',
        );
      }

      // Checkpoint every node if configured
      if (config != null && config.checkpointEveryNode && checkpointStore != null) {
        final nodeCheckpoint = await _createCheckpoint(
          state: currentState,
          currentNode: currentNode,
          path: path,
          iteration: iterations,
          threadId: effectiveThreadId,
        );
        await checkpointStore!.save(nodeCheckpoint, threadId: effectiveThreadId);
      }

      // Find next node(s)
      final nextNodes = await _getNextNodes(currentNode, currentState);

      if (nextNodes.isEmpty || nextNodes.first == END) {
        break;
      }

      // Handle parallel execution
      if (nextNodes.length > 1) {
        currentState = await _executeParallel(
          nextNodes,
          currentState,
          currentNode,
        );
        // After parallel, check for edges from any of the parallel nodes
        currentNode = await _findNextAfterParallel(nextNodes, currentState);
      } else {
        currentNode = nextNodes.first;
      }
    }

    if (iterations >= maxIterations) {
      // Create checkpoint before throwing
      if (config != null && config.checkpointOnError && checkpointStore != null) {
        final maxIterCheckpoint = await _createCheckpoint(
          state: currentState,
          currentNode: currentNode,
          path: path,
          iteration: iterations,
          threadId: effectiveThreadId,
          interruptType: InterruptType.error,
          interruptReason: 'Max iterations exceeded',
        );
        await checkpointStore!.save(maxIterCheckpoint, threadId: effectiveThreadId);
      }

      throw MaxIterationsExceededException(
        maxIterations: maxIterations,
        currentNode: currentNode,
      );
    }

    return GraphResult<S>(
      state: currentState,
      path: path,
      metadata: {
        'iterations': iterations,
        'graph_id': graphId,
        if (effectiveThreadId != null) 'thread_id': effectiveThreadId,
      },
    );
  }

  /// Creates a checkpoint at the current execution point.
  Future<Checkpoint<S>> _createCheckpoint({
    required S state,
    required String currentNode,
    required List<String> path,
    required int iteration,
    String? threadId,
    InterruptType? interruptType,
    String? interruptReason,
  }) async {
    final checkpoint = Checkpoint<S>.now(
      state: state,
      currentNode: currentNode,
      path: List.from(path),
      iteration: iteration,
      threadId: threadId,
      address: ExecutionAddress(
        graphId: graphId,
        nodeName: currentNode,
      ),
      interruptType: interruptType,
      interruptReason: interruptReason,
    );

    // Auto-save if configured
    if (checkpointStore != null && (checkpointConfig?.autoSave ?? false)) {
      await checkpointStore!.save(checkpoint, threadId: threadId);
    }

    return checkpoint;
  }

  /// Get next node(s) from current node
  Future<List<String>> _getNextNodes(String from, S state) async {
    final matchingEdges = _edges.where((e) => e.from == from).toList();

    if (matchingEdges.isEmpty) {
      return [END];
    }

    // For parallel edges, return all targets
    if (matchingEdges.first is ParallelEdge<S>) {
      return await matchingEdges.first.getNext(state);
    }

    // For regular/conditional edges, return first match
    return await matchingEdges.first.getNext(state);
  }

  /// Execute multiple nodes in parallel
  Future<S> _executeParallel(
    List<String> nodeNames,
    S currentState,
    String fromNode,
  ) async {
    // Find the parallel edge to get merger function
    final parallelEdge = _edges
        .whereType<ParallelEdge<S>>()
        .firstWhere((e) => e.from == fromNode);

    // Execute all nodes in parallel
    final futures = nodeNames.map((name) async {
      final node = _nodes[name]!;
      return await node.execute(currentState);
    });

    final results = await Future.wait(futures);

    // Merge results if merger is provided, otherwise use last result
    if (parallelEdge.merger != null) {
      return parallelEdge.merger!(currentState, results);
    } else {
      return results.last;
    }
  }

  /// Find next node after parallel execution
  Future<String> _findNextAfterParallel(
    List<String> parallelNodes,
    S state,
  ) async {
    // Check if any of the parallel nodes have outgoing edges
    for (final node in parallelNodes) {
      final nextNodes = await _getNextNodes(node, state);
      if (nextNodes.isNotEmpty && nextNodes.first != END) {
        return nextNodes.first;
      }
    }

    return END;
  }

  /// Validate that a node exists
  void _validateNode(String name, {bool allowEnd = false}) {
    if (name == END && allowEnd) return;
    if (!_nodes.containsKey(name)) {
      throw ArgumentError('Node "$name" does not exist');
    }
  }

  /// Get a visual representation of the graph
  String toMermaid() {
    final buffer = StringBuffer();
    buffer.writeln('graph TD');

    // Add entry point
    if (_entryPoint != null) {
      buffer.writeln('    START(( ))');
      buffer.writeln('    START --> $_entryPoint');
    }

    // Add nodes
    for (final node in _nodes.values) {
      final desc = node.description ?? '';
      buffer.writeln(
          '    ${node.name}[${node.name}${desc.isNotEmpty ? '<br/>$desc' : ''}]');
    }

    // Add edges
    for (final edge in _edges) {
      if (edge is DirectEdge<S>) {
        buffer.writeln('    ${edge.from} --> ${edge.to}');
      } else if (edge is ConditionalEdge<S>) {
        final desc = edge.description ?? '?';
        buffer.writeln('    ${edge.from} -->|$desc| ?');
      } else if (edge is ParallelEdge<S>) {
        for (final to in edge.to) {
          buffer.writeln('    ${edge.from} -.-> $to');
        }
      }
    }

    // Add END node
    buffer.writeln('    END(( ))');

    return buffer.toString();
  }

  /// Get summary of the graph
  @override
  String toString() {
    return 'StateGraph<$S>(nodes: ${_nodes.length}, edges: ${_edges.length}, entry: $_entryPoint)';
  }
}

/// Exception thrown during graph execution
class GraphExecutionException implements Exception {
  GraphExecutionException(this.message, {this.nodeName, this.cause});

  final String message;
  final String? nodeName;
  final dynamic cause;

  @override
  String toString() {
    final buffer = StringBuffer('GraphExecutionException: $message');
    if (nodeName != null) {
      buffer.write(' (node: $nodeName)');
    }
    if (cause != null) {
      buffer.write('\nCaused by: $cause');
    }
    return buffer.toString();
  }
}
