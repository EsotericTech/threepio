# Threepio Enhancement Plan: Eino Feature Parity

> **Superseded.** This is the first, pre-0.9 plan for bringing Eino features to
> threepio. It was replaced by the plan for the 0.9 port of Eino v0.9.22
> (`docs/EINO_PARITY_PLAN.md`, a maintainers' working document that is not
> part of the repository or the package). What was built is described in the [README](../README.md),
> [MIGRATION.md](MIGRATION.md) and the [CHANGELOG](../CHANGELOG.md). This file
> is kept as a record. Its code blocks are design sketches: they do not compile
> against the current API and are not checked by the documentation tests.

## Executive Summary

This document outlines a comprehensive plan to enhance the Threepio Dart LLM framework with 4 high-value features from the ByteDance Eino framework, adapted for idiomatic Dart implementation.

### Feature Overview

| Feature | Value Proposition | Estimated Files |
|---------|-------------------|-----------------|
| **Checkpoint & Resume** | Fault tolerance, long-running tasks, human-in-the-loop | ~15 |
| **Advanced Agent Kit (ADK)** | Multi-agent patterns, workflow orchestration | ~18 |
| **Document Pipeline** | Production RAG with parsers, splitters, rerankers | ~22 |
| **Advanced Retrieval** | Better recall with multi-query, hybrid, routing | ~12 |

---

# Feature 1: Checkpoint & Resume System

## Overview

Enable fault-tolerant graph execution with state persistence, interrupt/resume capabilities, and human-in-the-loop patterns.

## Directory Structure

```
lib/src/graph/checkpoint/
├── checkpoint.dart              # Enhanced Checkpoint class
├── checkpoint_store.dart        # CheckpointStore interface
├── execution_address.dart       # Address-based execution targeting
├── serializer.dart              # Serialization interfaces
├── hitl.dart                    # Human-in-the-loop support
├── checkpoint_exports.dart      # Barrel exports
└── stores/
    ├── in_memory_store.dart     # In-memory implementation
    ├── file_store.dart          # File-based implementation
    └── stores_exports.dart      # Store exports
```

## Core Components

### 1.1 Enhanced Checkpoint Class

```dart
/// Types of interrupts that can occur during graph execution
enum InterruptType {
  /// Interrupt before node execution
  beforeNode,

  /// Interrupt after node execution
  afterNode,

  /// Human-in-the-loop interrupt requiring input
  humanInput,

  /// Conditional interrupt based on state
  conditional,

  /// Manual interrupt via API call
  manual,

  /// Error-triggered interrupt
  error,
}

/// Enhanced checkpoint with interrupt support
class Checkpoint<S extends GraphState> {
  const Checkpoint({
    required this.state,
    required this.currentNode,
    required this.path,
    required this.iteration,
    this.id,
    this.threadId,
    this.timestamp,
    this.metadata = const {},
    this.address,
    this.interruptReason,
    this.pendingInput,
    this.interruptType,
  });

  /// Unique identifier for this checkpoint
  final String? id;

  /// Thread ID for isolation
  final String? threadId;

  /// Current state at this checkpoint
  final S state;

  /// Current node being executed
  final String currentNode;

  /// Path taken so far
  final List<String> path;

  /// Current iteration number
  final int iteration;

  /// When this checkpoint was created
  final DateTime? timestamp;

  /// Additional metadata
  final Map<String, dynamic> metadata;

  /// Precise execution address (for nested graphs)
  final ExecutionAddress? address;

  /// Reason for interrupt (if applicable)
  final String? interruptReason;

  /// Pending human input (for HITL patterns)
  final dynamic pendingInput;

  /// Type of interrupt
  final InterruptType? interruptType;

  /// Whether this checkpoint was created due to an interrupt
  bool get isInterrupt => interruptType != null;

  /// Create with timestamp set to now
  factory Checkpoint.now({
    required S state,
    required String currentNode,
    required List<String> path,
    required int iteration,
    String? id,
    String? threadId,
    Map<String, dynamic>? metadata,
    ExecutionAddress? address,
    String? interruptReason,
    InterruptType? interruptType,
  }) {
    return Checkpoint(
      id: id,
      threadId: threadId,
      state: state,
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: DateTime.now(),
      metadata: metadata ?? {},
      address: address,
      interruptReason: interruptReason,
      interruptType: interruptType,
    );
  }

  /// Create copy with pending input
  Checkpoint<S> withPendingInput(dynamic input) {
    return Checkpoint<S>(
      id: id,
      threadId: threadId,
      state: state,
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: timestamp,
      metadata: metadata,
      address: address,
      interruptReason: interruptReason,
      pendingInput: input,
      interruptType: interruptType,
    );
  }
}
```

### 1.2 Execution Address

```dart
/// Represents a precise location in graph execution
///
/// Addresses allow resumption from exact points, including nested graphs
/// and parallel branches.
class ExecutionAddress {
  const ExecutionAddress({
    required this.graphId,
    required this.nodeName,
    this.parentAddress,
    this.branchIndex,
    this.depth = 0,
  });

  /// Unique identifier for the graph
  final String graphId;

  /// Current node name
  final String nodeName;

  /// Parent address for nested graphs
  final ExecutionAddress? parentAddress;

  /// Branch index for parallel execution
  final int? branchIndex;

  /// Nesting depth (0 for root graph)
  final int depth;

  /// Create address for entering a subgraph
  ExecutionAddress enterSubgraph(String subgraphId, String entryNode) {
    return ExecutionAddress(
      graphId: subgraphId,
      nodeName: entryNode,
      parentAddress: this,
      depth: depth + 1,
    );
  }

  /// Create address for entering a parallel branch
  ExecutionAddress enterBranch(int index, String nodeName) {
    return ExecutionAddress(
      graphId: graphId,
      nodeName: nodeName,
      parentAddress: this,
      branchIndex: index,
      depth: depth,
    );
  }

  /// Get full path as string (e.g., "graph1/nodeA/subgraph/nodeB")
  String get fullPath {
    if (parentAddress != null) {
      return '${parentAddress!.fullPath}/$nodeName';
    }
    return '$graphId/$nodeName';
  }

  Map<String, dynamic> toJson() => {
    'graph_id': graphId,
    'node_name': nodeName,
    'parent': parentAddress?.toJson(),
    'branch_index': branchIndex,
    'depth': depth,
  };

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
}
```

### 1.3 Checkpoint Store Interface

```dart
/// Configuration for checkpoint storage
class CheckpointStoreConfig {
  const CheckpointStoreConfig({
    this.maxCheckpointsPerThread = 100,
    this.ttl,
    this.compressData = false,
  });

  /// Maximum checkpoints to retain per thread
  final int maxCheckpointsPerThread;

  /// Time-to-live for checkpoints
  final Duration? ttl;

  /// Whether to compress checkpoint data
  final bool compressData;
}

/// Metadata about a stored checkpoint (without full state)
class CheckpointMetadata {
  const CheckpointMetadata({
    required this.id,
    required this.threadId,
    required this.currentNode,
    required this.iteration,
    required this.timestamp,
    this.interruptReason,
    this.interruptType,
  });

  final String id;
  final String threadId;
  final String currentNode;
  final int iteration;
  final DateTime timestamp;
  final String? interruptReason;
  final InterruptType? interruptType;
}

/// Interface for persisting and retrieving checkpoints
abstract class CheckpointStore<S extends GraphState> {
  /// Save a checkpoint with optional thread ID
  Future<String> save(
    Checkpoint<S> checkpoint, {
    String? threadId,
    String? checkpointId,
  });

  /// Load a checkpoint by ID
  Future<Checkpoint<S>?> load(String checkpointId, {String? threadId});

  /// Load the latest checkpoint for a thread
  Future<Checkpoint<S>?> loadLatest({required String threadId});

  /// Delete a checkpoint
  Future<void> delete(String checkpointId, {String? threadId});

  /// List all checkpoints for a thread
  Future<List<CheckpointMetadata>> list({String? threadId});

  /// Clear all checkpoints (optionally for a specific thread)
  Future<void> clear({String? threadId});

  /// Get checkpoint history for a thread
  Future<List<Checkpoint<S>>> getHistory({
    required String threadId,
    int? limit,
    DateTime? before,
    DateTime? after,
  });
}
```

### 1.4 Serializer Interface

```dart
/// Interface for serializing/deserializing checkpoint state
abstract class CheckpointSerializer<S extends GraphState> {
  /// Serialize checkpoint to bytes
  Future<List<int>> serialize(Checkpoint<S> checkpoint);

  /// Deserialize bytes to checkpoint
  Future<Checkpoint<S>> deserialize(List<int> data);

  /// Content type identifier
  String get contentType;
}

/// JSON-based serializer for states with toJson/fromJson
class JsonCheckpointSerializer<S extends GraphState>
    implements CheckpointSerializer<S> {
  JsonCheckpointSerializer({
    required this.stateFromJson,
    required this.stateToJson,
  });

  final S Function(Map<String, dynamic> json) stateFromJson;
  final Map<String, dynamic> Function(S state) stateToJson;

  @override
  String get contentType => 'application/json';

  @override
  Future<List<int>> serialize(Checkpoint<S> checkpoint) async {
    final json = {
      'id': checkpoint.id,
      'thread_id': checkpoint.threadId,
      'state': stateToJson(checkpoint.state),
      'current_node': checkpoint.currentNode,
      'path': checkpoint.path,
      'iteration': checkpoint.iteration,
      'timestamp': checkpoint.timestamp?.toIso8601String(),
      'metadata': checkpoint.metadata,
      'address': checkpoint.address?.toJson(),
      'interrupt_reason': checkpoint.interruptReason,
      'interrupt_type': checkpoint.interruptType?.name,
    };
    return utf8.encode(jsonEncode(json));
  }

  @override
  Future<Checkpoint<S>> deserialize(List<int> data) async {
    final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    return Checkpoint<S>(
      id: json['id'] as String?,
      threadId: json['thread_id'] as String?,
      state: stateFromJson(json['state'] as Map<String, dynamic>),
      currentNode: json['current_node'] as String,
      path: List<String>.from(json['path'] as List),
      iteration: json['iteration'] as int,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? {},
      address: json['address'] != null
          ? ExecutionAddress.fromJson(json['address'] as Map<String, dynamic>)
          : null,
      interruptReason: json['interrupt_reason'] as String?,
      interruptType: json['interrupt_type'] != null
          ? InterruptType.values.byName(json['interrupt_type'] as String)
          : null,
    );
  }
}
```

### 1.5 StateGraph Integration

```dart
/// Configuration for checkpoint behavior in StateGraph
class CheckpointConfig {
  const CheckpointConfig({
    this.interruptBefore = const [],
    this.interruptAfter = const [],
    this.checkpointEveryNode = false,
    this.checkpointOnError = true,
    this.autoSave = false,
    this.threadIdProvider,
  });

  /// Node names to interrupt BEFORE executing
  final List<String> interruptBefore;

  /// Node names to interrupt AFTER executing
  final List<String> interruptAfter;

  /// Create checkpoint after every node (useful for debugging)
  final bool checkpointEveryNode;

  /// Create checkpoint on error for recovery
  final bool checkpointOnError;

  /// Automatically save checkpoints to store
  final bool autoSave;

  /// Function to provide thread ID for checkpoint isolation
  final String Function()? threadIdProvider;
}

/// Exception thrown when graph execution is interrupted
class GraphInterruptException<S extends GraphState> implements Exception {
  GraphInterruptException({
    required this.checkpoint,
    required this.reason,
  });

  final Checkpoint<S> checkpoint;
  final String reason;

  @override
  String toString() => 'GraphInterruptException: $reason';
}
```

### 1.6 Human-in-the-Loop Support

```dart
/// Node that requires human input before continuing
class HumanInputNode<S extends GraphState, I> {
  HumanInputNode({
    required this.name,
    required this.prompt,
    required this.processInput,
    this.validator,
    this.timeout,
  });

  /// Node name
  final String name;

  /// Function to generate prompt from current state
  final String Function(S state) prompt;

  /// Function to process human input and update state
  final S Function(S state, I input) processInput;

  /// Optional validator for human input
  final bool Function(I input)? validator;

  /// Optional timeout for human input
  final Duration? timeout;
}

/// Exception thrown when human input is required
class HumanInputRequired<S extends GraphState, I> implements Exception {
  HumanInputRequired({
    required this.nodeName,
    required this.prompt,
    required this.checkpoint,
    this.validator,
  });

  final String nodeName;
  final String prompt;
  final Checkpoint<S> checkpoint;
  final bool Function(I input)? validator;
}
```

## Usage Examples

### Basic Checkpoint & Resume

```dart
// Create checkpoint store
final store = InMemoryCheckpointStore<MyState>();

// Configure graph with checkpoints
final graph = StateGraph<MyState>(
  checkpointStore: store,
  checkpointConfig: CheckpointConfig(
    interruptBefore: ['human_review'],
    autoSave: true,
  ),
);

graph
  ..addNode('fetch', fetchDataNode)
  ..addNode('process', processDataNode)
  ..addNode('human_review', reviewNode)
  ..addNode('finalize', finalizeNode)
  ..addEdge('fetch', 'process')
  ..addEdge('process', 'human_review')
  ..addEdge('human_review', 'finalize')
  ..addEdge('finalize', END)
  ..setEntryPoint('fetch');

// Execute - will interrupt before 'human_review'
try {
  await graph.invoke(MyState(data: initialData), threadId: 'user-123');
} on GraphInterruptException<MyState> catch (e) {
  print('Interrupted at: ${e.checkpoint.currentNode}');

  // Store checkpoint ID for later
  final checkpointId = e.checkpoint.id;

  // Later, resume execution
  final result = await graph.invoke(
    MyState(), // Ignored, loaded from checkpoint
    checkpointId: checkpointId,
    threadId: 'user-123',
  );
}
```

### Human-in-the-Loop

```dart
// Define HITL node
final approvalNode = HumanInputNode<MyState, bool>(
  name: 'approval',
  prompt: (state) => 'Review and approve: ${state.summary}',
  processInput: (state, approved) => state.copyWith(approved: approved),
  validator: (input) => input is bool,
);

graph.addHumanInputNode(approvalNode);

// Handle human input request
try {
  await graph.invoke(initialState, threadId: 'user-123');
} on HumanInputRequired<MyState, bool> catch (e) {
  print(e.prompt);

  // Get user approval (e.g., from UI)
  final userApproval = await getUserApproval();

  // Resume with input
  final result = await graph.resumeWithHumanInput<bool>(
    e.checkpoint.id!,
    input: userApproval,
    threadId: 'user-123',
  );
}
```

---

# Feature 2: Advanced Agent Development Kit (ADK)

## Overview

Enhanced agent patterns with event streaming, multi-agent coordination, and prebuilt orchestration patterns.

## Directory Structure

```
lib/src/adk/
├── adk_exports.dart                # Barrel exports
├── core/
│   ├── base_agent.dart             # BaseAgent interface
│   ├── agent_run_context.dart      # Execution context
│   └── agent_exception.dart        # Agent exceptions
├── events/
│   ├── agent_event.dart            # Event types
│   ├── agent_action.dart           # Action types
│   └── events_exports.dart         # Events barrel
├── agents/
│   ├── chat_model_agent.dart       # Enhanced ReAct agent
│   ├── workflow_agent.dart         # Workflow orchestration
│   ├── plan_execute_agent.dart     # Plan-then-execute
│   ├── supervisor_agent.dart       # Multi-agent supervisor
│   └── agents_exports.dart         # Agents barrel
├── tools/
│   ├── agent_tool.dart             # Wrap agent as tool
│   └── tools_exports.dart          # Tools barrel
└── patterns/
    ├── deep_research_agent.dart    # Research pattern
    └── patterns_exports.dart       # Patterns barrel
```

## Core Components

### 2.1 Agent Events

```dart
/// Base class for all agent events
sealed class AgentEvent {
  const AgentEvent({
    required this.runId,
    required this.timestamp,
    this.metadata,
  });

  final String runId;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;
}

/// Event emitted when agent produces output
class AgentOutputEvent extends AgentEvent {
  const AgentOutputEvent({
    required super.runId,
    required super.timestamp,
    required this.message,
    this.isPartial = false,
    super.metadata,
  });

  final Message message;
  final bool isPartial; // True for streaming chunks
}

/// Event emitted when agent takes an action
class AgentActionEvent extends AgentEvent {
  const AgentActionEvent({
    required super.runId,
    required super.timestamp,
    required this.action,
    this.reasoning,
    super.metadata,
  });

  final AgentAction action;
  final String? reasoning;
}

/// Event emitted when tool execution completes
class ToolResultEvent extends AgentEvent {
  const ToolResultEvent({
    required super.runId,
    required super.timestamp,
    required this.toolCallId,
    required this.toolName,
    required this.result,
    this.error,
    super.metadata,
  });

  final String toolCallId;
  final String toolName;
  final String result;
  final String? error;
}

/// Event emitted when agent transfers to another agent
class AgentTransferEvent extends AgentEvent {
  const AgentTransferEvent({
    required super.runId,
    required super.timestamp,
    required this.fromAgent,
    required this.toAgent,
    this.reason,
    super.metadata,
  });

  final String fromAgent;
  final String toAgent;
  final String? reason;
}
```

### 2.2 Agent Actions

```dart
/// Represents an action an agent can take
sealed class AgentAction {
  const AgentAction();
}

/// Call a tool
class ToolCallAction extends AgentAction {
  const ToolCallAction({
    required this.toolName,
    required this.arguments,
    this.id,
  });

  final String toolName;
  final String arguments; // JSON string
  final String? id;
}

/// Transfer control to another agent
class TransferToAgentAction extends AgentAction {
  const TransferToAgentAction({
    required this.targetAgent,
    this.context,
  });

  final String targetAgent;
  final Map<String, dynamic>? context;
}

/// Finish execution with final output
class FinishAction extends AgentAction {
  const FinishAction({
    required this.output,
  });

  final String output;
}
```

### 2.3 Base Agent Interface

```dart
/// Configuration for agent execution context
class AgentRunContext {
  const AgentRunContext({
    this.runId,
    this.parentRunId,
    this.metadata,
    this.callbackManager,
    this.maxDepth = 10,
    this.currentDepth = 0,
  });

  final String? runId;
  final String? parentRunId;
  final Map<String, dynamic>? metadata;
  final CallbackManager? callbackManager;
  final int maxDepth;
  final int currentDepth;

  AgentRunContext incrementDepth() {
    return AgentRunContext(
      runId: runId,
      parentRunId: parentRunId,
      metadata: metadata,
      callbackManager: callbackManager,
      maxDepth: maxDepth,
      currentDepth: currentDepth + 1,
    );
  }

  bool get isMaxDepthReached => currentDepth >= maxDepth;
}

/// Base interface for all agents in the ADK
abstract class BaseAgent {
  /// Unique name for this agent
  String get name;

  /// Description of what this agent does
  String get description;

  /// Run the agent with event streaming
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  });

  /// Run the agent and get final result only
  Future<Message> invoke(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final reader = await run(messages, context: context);
    Message? finalMessage;

    try {
      while (true) {
        final event = await reader.recv();
        if (event is AgentOutputEvent && !event.isPartial) {
          finalMessage = event.message;
        }
      }
    } on StreamEOFException {
      // Expected end of stream
    }

    if (finalMessage == null) {
      throw AgentException('Agent completed without producing output');
    }
    return finalMessage;
  }

  /// Called when this agent is set as a sub-agent
  void onSetAsSubAgent(BaseAgent parent) {}

  /// Called when sub-agents are assigned to this agent
  void onSetSubAgents(List<BaseAgent> subAgents) {}
}
```

### 2.4 Workflow Agent

```dart
/// Execution mode for workflow agent
enum WorkflowMode {
  /// Execute steps sequentially
  sequential,

  /// Execute steps in a loop until condition
  loop,

  /// Execute steps in parallel
  parallel,
}

/// Configuration for workflow agent
class WorkflowConfig {
  const WorkflowConfig({
    this.mode = WorkflowMode.sequential,
    this.maxLoopIterations = 10,
    this.loopCondition,
    this.mergeStrategy,
  });

  final WorkflowMode mode;
  final int maxLoopIterations;
  final bool Function(WorkflowState state)? loopCondition;
  final WorkflowState Function(List<WorkflowState> results)? mergeStrategy;
}

/// A workflow step
abstract class WorkflowStep {
  String get name;
  Future<WorkflowState> execute(WorkflowState state);
}

/// Workflow step wrapping an agent
class AgentStep implements WorkflowStep {
  AgentStep({required this.agent, String? stepName})
      : _name = stepName ?? agent.name;

  final BaseAgent agent;
  final String _name;

  @override
  String get name => _name;

  @override
  Future<WorkflowState> execute(WorkflowState state) async {
    final result = await agent.invoke(state.messages);
    return state.copyWith(
      messages: [...state.messages, result],
      results: {...state.results, name: result.content},
    );
  }
}

/// Agent that orchestrates multiple steps in a workflow
class WorkflowAgent extends BaseAgent {
  WorkflowAgent({
    required this.steps,
    this.agentName,
    this.agentDescription,
    this.config = const WorkflowConfig(),
  });

  final List<WorkflowStep> steps;
  final String? agentName;
  final String? agentDescription;
  final WorkflowConfig config;

  @override
  String get name => agentName ?? 'WorkflowAgent';

  @override
  String get description =>
      agentDescription ?? 'Workflow executing ${steps.length} steps';
}
```

### 2.5 Plan-Execute Agent

```dart
/// A step in the execution plan
class PlanStep {
  const PlanStep({
    required this.id,
    required this.description,
    this.toolName,
    this.dependencies = const [],
    this.expectedOutput,
  });

  final String id;
  final String description;
  final String? toolName;
  final List<String> dependencies;
  final String? expectedOutput;
}

/// The execution plan
class ExecutionPlan {
  const ExecutionPlan({
    required this.steps,
    this.reasoning,
    this.goal,
  });

  final List<PlanStep> steps;
  final String? reasoning;
  final String? goal;
}

/// Agent that creates a plan then executes it
class PlanExecuteAgent extends BaseAgent {
  PlanExecuteAgent({
    required this.planner,
    required this.executor,
    this.agentName,
    this.agentDescription,
    this.maxReplans = 3,
    this.replanOnFailure = true,
  });

  /// Agent responsible for creating the plan
  final BaseAgent planner;

  /// Agent responsible for executing each step
  final BaseAgent executor;

  final String? agentName;
  final String? agentDescription;
  final int maxReplans;
  final bool replanOnFailure;

  @override
  String get name => agentName ?? 'PlanExecuteAgent';

  @override
  String get description =>
      agentDescription ?? 'Agent that plans then executes tasks';
}
```

### 2.6 Supervisor Agent

```dart
/// Supervisor agent that coordinates multiple worker agents
class SupervisorAgent extends BaseAgent {
  SupervisorAgent({
    required this.supervisor,
    required this.workers,
    this.agentName,
    this.agentDescription,
    this.routingStrategy = RoutingStrategy.llmBased,
    this.maxDelegations = 10,
  });

  /// The supervisor agent that decides delegation
  final ChatModelAgent supervisor;

  /// Map of worker name to worker agent
  final Map<String, BaseAgent> workers;

  final String? agentName;
  final String? agentDescription;
  final RoutingStrategy routingStrategy;
  final int maxDelegations;

  @override
  String get name => agentName ?? 'SupervisorAgent';

  @override
  String get description =>
      agentDescription ?? 'Supervisor coordinating ${workers.length} workers';
}

enum RoutingStrategy {
  llmBased,
  keywordBased,
  roundRobin,
}
```

### 2.7 Agent Tool

```dart
/// Wraps an agent as a tool for composition
class AgentTool extends InvokableTool {
  AgentTool({
    required this.agent,
    this.toolName,
    this.toolDescription,
    this.inputSchema,
  });

  final BaseAgent agent;
  final String? toolName;
  final String? toolDescription;
  final Map<String, JSONSchemaProperty>? inputSchema;

  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: toolName ?? 'agent_${agent.name}',
      description: toolDescription ?? agent.description,
      properties: inputSchema ?? {
        'message': JSONSchemaProperty.string(
          description: 'The message to send to the agent',
        ),
      },
      required: ['message'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final message = args['message'] as String;
    final result = await agent.invoke([Message.user(message)]);
    return result.content;
  }
}

/// Extension to convert agents to tools
extension AgentToToolExtension on BaseAgent {
  AgentTool asTool({
    String? toolName,
    String? toolDescription,
  }) {
    return AgentTool(
      agent: this,
      toolName: toolName,
      toolDescription: toolDescription,
    );
  }
}
```

## Usage Examples

### Multi-Agent Supervisor

```dart
// Create specialist agents
final researchAgent = ChatModelAgent(
  model: model,
  toolRegistry: ToolRegistry()..register(SearchTool()),
  agentName: 'Researcher',
);

final writerAgent = ChatModelAgent(
  model: model,
  toolRegistry: ToolRegistry(),
  agentName: 'Writer',
);

// Create supervisor
final supervisor = SupervisorAgent(
  supervisor: ChatModelAgent(
    model: model,
    toolRegistry: ToolRegistry(),
    systemPrompt: '''You coordinate research and writing tasks.
    Available workers: Researcher, Writer.
    Delegate tasks appropriately.''',
  ),
  workers: {
    'Researcher': researchAgent,
    'Writer': writerAgent,
  },
);

// Use supervisor
final eventReader = await supervisor.run([
  Message.user('Research AI trends and write a summary'),
]);

await for (final event in eventReader.asStream()) {
  switch (event) {
    case AgentOutputEvent():
      print('Output: ${event.message.content}');
    case AgentTransferEvent():
      print('Delegating to: ${event.toAgent}');
  }
}
```

---

# Feature 3: Document Processing Pipeline

## Overview

Comprehensive document ingestion with pluggable parsers, advanced splitters, and rerankers for production RAG.

## Directory Structure

```
lib/src/components/
├── document_parser/
│   ├── document_parser.dart         # Interface
│   ├── document_parser_exports.dart # Exports
│   ├── parser_registry.dart         # Auto-selection
│   ├── pdf_parser.dart
│   ├── html_parser.dart
│   ├── docx_parser.dart
│   ├── xlsx_parser.dart
│   ├── markdown_parser.dart
│   └── text_parser.dart
├── document_loader/
│   ├── url_loader.dart
│   ├── multi_source_loader.dart
│   └── s3_loader.dart              # Optional
├── text_splitter/
│   ├── html_splitter.dart
│   ├── markdown_splitter.dart
│   ├── semantic_splitter.dart
│   └── code_splitter.dart
├── reranker/
│   ├── reranker.dart               # Interface
│   ├── reranker_exports.dart
│   ├── score_reranker.dart
│   ├── mmr_reranker.dart
│   └── cohere_reranker.dart
└── pipeline/
    ├── document_pipeline.dart
    └── ingestion_pipeline.dart
```

## Core Components

### 3.1 Document Parser Interface

```dart
/// Options for document parsing
class DocumentParserOptions {
  const DocumentParserOptions({
    this.encoding = 'utf-8',
    this.preserveFormatting = false,
    this.extractMetadata = true,
    this.extra,
  });

  final String encoding;
  final bool preserveFormatting;
  final bool extractMetadata;
  final Map<String, dynamic>? extra;
}

/// Result of parsing a document
class ParseResult {
  const ParseResult({
    required this.content,
    this.metadata = const {},
    this.sections,
    this.errors,
  });

  final String content;
  final Map<String, dynamic> metadata;
  final List<DocumentSection>? sections;
  final List<ParseError>? errors;
}

/// A section within a parsed document
class DocumentSection {
  const DocumentSection({
    required this.content,
    required this.type,
    this.level,
    this.metadata,
  });

  final String content;
  final SectionType type;
  final int? level;
  final Map<String, dynamic>? metadata;
}

enum SectionType { heading, paragraph, list, table, code, image, unknown }

/// Interface for document parsers
abstract class DocumentParser {
  /// Parse raw bytes
  Future<ParseResult> parse(
    List<int> bytes, {
    DocumentParserOptions? options,
  });

  /// Parse from string
  Future<ParseResult> parseString(
    String content, {
    DocumentParserOptions? options,
  });

  /// Check extension support
  bool supportsExtension(String extension);

  /// Check MIME type support
  bool supportsMimeType(String mimeType);
}
```

### 3.2 Reranker Interface

```dart
/// Options for reranking
class RerankerOptions {
  const RerankerOptions({
    this.topK,
    this.scoreThreshold,
    this.extra,
  });

  final int? topK;
  final double? scoreThreshold;
  final Map<String, dynamic>? extra;
}

/// Result from reranking
class RerankResult {
  const RerankResult({
    required this.document,
    required this.score,
    this.originalRank,
  });

  final Document document;
  final double score;
  final int? originalRank;
}

/// Interface for rerankers
abstract class Reranker {
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  });
}
```

### 3.3 Ingestion Pipeline

```dart
/// End-to-end document ingestion pipeline
class IngestionPipeline {
  IngestionPipeline({
    required this.loader,
    required this.vectorStore,
    this.parser,
    this.splitter,
    this.embedder,
    this.onProgress,
  });

  final DocumentLoader loader;
  final VectorStore vectorStore;
  final DocumentParser? parser;
  final TextSplitter? splitter;
  final Embedder? embedder;
  final void Function(int processed, int total)? onProgress;

  /// Ingest documents
  Future<IngestionResult> ingest({
    DocumentLoaderOptions? loaderOptions,
    TextSplitterOptions? splitterOptions,
  }) async {
    // 1. Load documents
    // 2. Split if configured
    // 3. Generate embeddings
    // 4. Store in vector store
  }

  /// Stream-based ingestion for large sets
  Stream<IngestionProgress> ingestStream({
    DocumentLoaderOptions? loaderOptions,
    TextSplitterOptions? splitterOptions,
  }) async* {
    // Process documents one at a time, yielding progress
  }
}

class IngestionResult {
  const IngestionResult({
    required this.documentsLoaded,
    required this.chunksCreated,
    required this.documentsStored,
  });

  final int documentsLoaded;
  final int chunksCreated;
  final int documentsStored;
}
```

---

# Feature 4: Advanced Retrieval Patterns

## Overview

Improved retrieval quality through multi-query expansion, hierarchical retrieval, query routing, and hybrid search.

## Directory Structure

```
lib/src/components/retriever/
├── retriever_exports.dart          # Updated exports
├── multi_query_retriever.dart
├── parent_retriever.dart
├── router_retriever.dart
├── hybrid_retriever.dart
└── fusion/
    ├── fusion_exports.dart
    ├── scored_document.dart
    ├── result_fusion.dart
    └── deduplication.dart
```

## Core Components

### 4.1 Fusion Utilities

```dart
/// Document with computed score
class ScoredDocument {
  const ScoredDocument({
    required this.document,
    required this.score,
    this.source,
    this.metadata,
  });

  final Document document;
  final double score;
  final String? source;
  final Map<String, dynamic>? metadata;
}

/// Strategy for fusing results
abstract class ResultFusionStrategy {
  List<ScoredDocument> fuse(List<List<ScoredDocument>> resultSets);
}

/// Reciprocal Rank Fusion
class ReciprocalRankFusion implements ResultFusionStrategy {
  const ReciprocalRankFusion({this.k = 60.0});

  final double k;

  @override
  List<ScoredDocument> fuse(List<List<ScoredDocument>> resultSets) {
    // RRF(d) = sum(1 / (k + rank(d))) for each result set
  }
}

/// Weighted score fusion
class WeightedScoreFusion implements ResultFusionStrategy {
  const WeightedScoreFusion({
    required this.weights,
    this.normalizeScores = true,
  });

  final List<double> weights;
  final bool normalizeScores;
}
```

### 4.2 MultiQuery Retriever

```dart
/// Generates multiple query variants and retrieves for each
class MultiQueryRetriever implements Retriever {
  MultiQueryRetriever({
    required this.chatModel,
    required this.baseRetriever,
    ResultFusionStrategy? fusionStrategy,
    this.defaultQueryCount = 3,
    this.includeOriginalQuery = true,
    this.promptTemplate,
  }) : fusionStrategy = fusionStrategy ?? const ReciprocalRankFusion();

  final BaseChatModel chatModel;
  final Retriever baseRetriever;
  final ResultFusionStrategy fusionStrategy;
  final int defaultQueryCount;
  final bool includeOriginalQuery;
  final String? promptTemplate;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // 1. Generate query variants using LLM
    // 2. Retrieve documents for each query in parallel
    // 3. Fuse and deduplicate results
  }
}
```

### 4.3 Parent Retriever

```dart
/// Store for parent-child document relationships
abstract class ParentDocumentStore {
  Future<void> storeWithChunks({
    required Document parent,
    required List<Document> chunks,
  });

  Future<Document?> getParentByChildId(String childId);
  Future<Document?> getParent(String parentId);
  Future<List<Document>> getChildren(String parentId);
}

/// Searches chunks but returns parent documents
class ParentRetriever implements Retriever {
  ParentRetriever({
    required this.childRetriever,
    required this.documentStore,
    this.textSplitter,
  });

  final Retriever childRetriever;
  final ParentDocumentStore documentStore;
  final TextSplitter? textSplitter;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // 1. Retrieve relevant child chunks
    // 2. Map children to parents (deduplicate)
    // 3. Return parent documents with context
  }
}
```

### 4.4 Router Retriever

```dart
/// Route definition
class RetrieverRoute {
  const RetrieverRoute({
    required this.name,
    required this.description,
    required this.retriever,
    this.keywords,
  });

  final String name;
  final String description;
  final Retriever retriever;
  final List<String>? keywords;
}

/// Routing strategy
abstract class RoutingStrategy {
  Future<List<RetrieverRoute>> route(
    String query,
    List<RetrieverRoute> availableRoutes,
  );
}

/// Routes queries to appropriate retrievers
class RouterRetriever implements Retriever {
  RouterRetriever({
    required this.routes,
    required this.routingStrategy,
    this.fusionStrategy,
    this.fallbackRetriever,
  });

  final List<RetrieverRoute> routes;
  final RoutingStrategy routingStrategy;
  final ResultFusionStrategy? fusionStrategy;
  final Retriever? fallbackRetriever;
}
```

### 4.5 Hybrid Retriever

```dart
/// Interface for keyword search
abstract class KeywordSearcher {
  Future<List<ScoredDocument>> search(String query, {int limit = 10});
  Future<void> addDocuments(List<Document> documents);
}

/// BM25 implementation
class InMemoryBM25Searcher implements KeywordSearcher {
  InMemoryBM25Searcher({
    this.k1 = 1.5,
    this.b = 0.75,
  });

  final double k1;
  final double b;
}

/// Combines vector and keyword search
class HybridRetriever implements Retriever {
  HybridRetriever({
    required this.vectorRetriever,
    required this.keywordSearcher,
    ResultFusionStrategy? fusionStrategy,
    this.defaultVectorWeight = 0.5,
    this.defaultKeywordWeight = 0.5,
  }) : fusionStrategy = fusionStrategy ?? const ReciprocalRankFusion();

  final VectorRetriever vectorRetriever;
  final KeywordSearcher keywordSearcher;
  final ResultFusionStrategy fusionStrategy;
  final double defaultVectorWeight;
  final double defaultKeywordWeight;
}
```

---

# Implementation Roadmap

## Phase 1: Checkpoint & Resume (Weeks 1-2)

1. **Week 1**: Core infrastructure
   - `Checkpoint` class with all fields
   - `ExecutionAddress` for nested graphs
   - `CheckpointSerializer` interface + JSON implementation
   - `CheckpointStore` interface
   - `InMemoryCheckpointStore`

2. **Week 2**: Integration
   - `FileCheckpointStore`
   - `CheckpointConfig` in StateGraph
   - Interrupt hooks in execution loop
   - `GraphInterruptException`
   - Human-in-the-loop support
   - Unit and integration tests

## Phase 2: Advanced Agent Kit (Weeks 3-4)

1. **Week 3**: Core and ReAct
   - Agent events and actions
   - `BaseAgent` interface
   - `AgentRunContext`
   - `ChatModelAgent` with event streaming
   - Unit tests

2. **Week 4**: Advanced agents
   - `WorkflowAgent` (all three modes)
   - `PlanExecuteAgent`
   - `SupervisorAgent`
   - `AgentTool` wrapper
   - Integration tests

## Phase 3: Document Pipeline (Weeks 5-6)

1. **Week 5**: Parsers and loaders
   - `DocumentParser` interface
   - `ParserRegistry`
   - PDF, HTML, DOCX, XLSX, Markdown parsers
   - `URLLoader`, `MultiSourceLoader`

2. **Week 6**: Splitters and pipeline
   - HTML, Markdown, Semantic, Code splitters
   - `Reranker` interface
   - Score, MMR, Cohere rerankers
   - `DocumentPipeline`, `IngestionPipeline`
   - Tests with fixtures

## Phase 4: Advanced Retrieval (Weeks 7-8)

1. **Week 7**: Foundation
   - `ScoredDocument`
   - Fusion strategies (RRF, weighted)
   - Deduplication utilities
   - `MultiQueryRetriever`

2. **Week 8**: Advanced retrievers
   - `ParentRetriever` + `ParentDocumentStore`
   - `RouterRetriever` + routing strategies
   - `HybridRetriever` + `InMemoryBM25Searcher`
   - Integration tests

## Phase 5: Documentation & Polish (Week 9)

1. API documentation
2. Usage examples for each feature
3. Integration examples
4. README updates
5. Package exports

---

# Testing Strategy

## Unit Tests

Each component gets dedicated test files:
- Checkpoint serialization roundtrip
- Store CRUD operations
- Agent event emission
- Parser output validation
- Fusion algorithm correctness
- BM25 scoring accuracy

## Integration Tests

- Full graph with checkpoints and resume
- Multi-agent workflows
- Document ingestion pipeline
- Advanced retrieval patterns

## Test Fixtures

```
test/fixtures/
├── documents/
│   ├── sample.pdf
│   ├── sample.html
│   ├── sample.docx
│   ├── sample.xlsx
│   └── sample.md
└── checkpoints/
    └── test_checkpoint.json
```

---

# Dependencies to Add

```yaml
dependencies:
  # PDF parsing
  dart_pdf_reader: ^1.0.0

  # HTML parsing
  html: ^0.15.4

  # Excel parsing
  excel: ^4.0.2

  # DOCX parsing (ZIP + XML)
  archive: ^3.4.0
  xml: ^6.3.0

  # Markdown parsing
  markdown: ^7.1.1

  # Utilities
  mime: ^1.0.4
```

---

# Files Summary

| Feature | New Files | Test Files | Total |
|---------|-----------|------------|-------|
| Checkpoint & Resume | 8 | 7 | 15 |
| Advanced Agent Kit | 10 | 8 | 18 |
| Document Pipeline | 17 | 10 | 27 |
| Advanced Retrieval | 7 | 5 | 12 |
| **Total** | **42** | **30** | **72** |

---

# Critical Existing Files to Modify

1. `lib/src/graph/state_graph.dart` - Add checkpoint integration
2. `lib/threepio_core.dart` - Export new modules
3. `pubspec.yaml` - Add dependencies
4. `lib/src/components/retriever/retriever_exports.dart` - Export new retrievers
5. `lib/src/graph/graph_exports.dart` - Export checkpoint module
