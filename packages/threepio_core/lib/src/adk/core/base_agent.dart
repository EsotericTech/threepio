import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import '../events/agent_event.dart';
import 'agent_exception.dart';

/// Base interface for all agents in the ADK.
///
/// Agents are autonomous units that can process messages, use tools,
/// and optionally delegate to other agents. All agents emit events
/// during execution for observability.
///
/// Example:
/// ```dart
/// final agent = MyChatAgent(
///   name: 'assistant',
///   model: chatModel,
///   tools: [searchTool, calculatorTool],
/// );
///
/// // Streaming execution
/// final stream = await agent.run([HumanMessage('What is 2+2?')]);
/// await for (final event in stream.asStream()) {
///   print('Event: ${event.eventType}');
/// }
///
/// // Single invocation
/// final result = await agent.invoke([HumanMessage('Hello!')]);
/// print(result.text);
/// ```
abstract class BaseAgent {
  /// Unique name identifying this agent.
  String get name;

  /// Human-readable description of what this agent does.
  String get description;

  /// Run the agent with streaming events.
  ///
  /// Returns a [StreamReader] that emits [AgentEvent]s as the agent executes.
  /// This enables real-time visibility into agent reasoning and actions.
  ///
  /// [messages] - Input messages to process
  /// [context] - Optional execution context
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  });

  /// Invoke the agent and wait for final result.
  ///
  /// This is a convenience method that runs the agent and returns
  /// only the final output message.
  ///
  /// [messages] - Input messages to process
  /// [context] - Optional execution context
  Future<Message> invoke(
    List<Message> messages, {
    AgentRunContext? context,
  });

  /// Create a copy of this agent with modified parameters.
  ///
  /// Useful for creating variants with different configurations.
  BaseAgent copyWith({
    String? name,
    String? description,
  });
}

/// Context for agent execution.
///
/// Provides shared state and configuration that can be passed through
/// nested agent calls and tool executions.
class AgentRunContext {
  /// Creates an agent run context.
  AgentRunContext({
    String? runId,
    this.parentRunId,
    this.maxIterations = 10,
    this.timeout,
    Map<String, dynamic>? metadata,
    this.onEvent,
    this.shouldCancel,
  })  : runId = runId ?? _generateId(),
        metadata = metadata ?? {};

  /// Unique ID for this run.
  final String runId;

  /// Parent run ID if this is a nested agent call.
  final String? parentRunId;

  /// Maximum number of iterations before stopping.
  final int maxIterations;

  /// Optional timeout for the entire run.
  final Duration? timeout;

  /// Arbitrary metadata attached to this run.
  final Map<String, dynamic> metadata;

  /// Callback for all events (useful for logging/tracing).
  final void Function(AgentEvent event)? onEvent;

  /// Function to check if the run should be cancelled.
  final bool Function()? shouldCancel;

  /// Whether cancellation has been requested.
  bool get isCancelled => shouldCancel?.call() ?? false;

  /// Create a child context for nested agent calls.
  AgentRunContext child({
    String? runId,
    int? maxIterations,
    Duration? timeout,
    Map<String, dynamic>? additionalMetadata,
  }) {
    return AgentRunContext(
      runId: runId,
      parentRunId: this.runId,
      maxIterations: maxIterations ?? this.maxIterations,
      timeout: timeout ?? this.timeout,
      metadata: {
        ...metadata,
        if (additionalMetadata != null) ...additionalMetadata,
      },
      onEvent: onEvent,
      shouldCancel: shouldCancel,
    );
  }

  /// Create a copy with modified values.
  AgentRunContext copyWith({
    String? runId,
    String? parentRunId,
    int? maxIterations,
    Duration? timeout,
    Map<String, dynamic>? metadata,
    void Function(AgentEvent event)? onEvent,
    bool Function()? shouldCancel,
  }) {
    return AgentRunContext(
      runId: runId ?? this.runId,
      parentRunId: parentRunId ?? this.parentRunId,
      maxIterations: maxIterations ?? this.maxIterations,
      timeout: timeout ?? this.timeout,
      metadata: metadata ?? this.metadata,
      onEvent: onEvent ?? this.onEvent,
      shouldCancel: shouldCancel ?? this.shouldCancel,
    );
  }

  static int _counter = 0;
  static String _generateId() {
    _counter++;
    return 'run_${DateTime.now().millisecondsSinceEpoch}_$_counter';
  }
}

/// Result from a single agent step.
///
/// Encapsulates the output from one iteration of agent execution,
/// including any messages generated and actions taken.
class AgentStepResult {
  /// Creates an agent step result.
  const AgentStepResult({
    required this.messages,
    required this.actions,
    this.shouldContinue = true,
    this.error,
  });

  /// Messages produced in this step.
  final List<Message> messages;

  /// Actions taken in this step.
  final List<AgentEvent> actions;

  /// Whether the agent should continue execution.
  final bool shouldContinue;

  /// Error if the step failed.
  final Object? error;

  /// Whether this step completed with an error.
  bool get hasError => error != null;
}

/// Mixin providing common agent functionality.
mixin AgentMixin implements BaseAgent {
  /// Emit an event through the context callback if available.
  void emitEvent(AgentEvent event, AgentRunContext? context) {
    context?.onEvent?.call(event);
  }

  /// Check if cancellation has been requested.
  void checkCancellation(AgentRunContext? context) {
    if (context?.isCancelled ?? false) {
      throw AgentCancelledException(agentName: name, runId: context?.runId);
    }
  }
}
