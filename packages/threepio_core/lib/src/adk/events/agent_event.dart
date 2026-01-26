/// Events emitted during agent execution.
///
/// Agent events provide real-time visibility into what an agent is doing,
/// enabling streaming UIs, logging, debugging, and external control.
library;

import 'package:uuid/uuid.dart';

import '../../schema/message.dart';
import 'agent_action.dart';

const _uuid = Uuid();

/// Base class for all agent events.
///
/// Events are emitted during agent execution to provide visibility into
/// the agent's reasoning and actions.
sealed class AgentEvent {
  /// Creates an agent event.
  AgentEvent({
    String? runId,
    DateTime? timestamp,
  })  : runId = runId ?? _uuid.v4(),
        timestamp = timestamp ?? DateTime.now();

  /// Unique identifier for this agent run.
  final String runId;

  /// When this event occurred.
  final DateTime timestamp;

  /// Human-readable event type name.
  String get eventType;

  /// Convert to JSON for serialization.
  Map<String, dynamic> toJson();

  /// Create an event from JSON.
  static AgentEvent fromJson(Map<String, dynamic> json) {
    final type = json['event_type'] as String;
    return switch (type) {
      'run_start' => AgentRunStartEvent.fromJson(json),
      'run_end' => AgentRunEndEvent.fromJson(json),
      'output' => AgentOutputEvent.fromJson(json),
      'action' => AgentActionEvent.fromJson(json),
      'tool_result' => ToolResultEvent.fromJson(json),
      'transfer' => AgentTransferEvent.fromJson(json),
      'error' => AgentErrorEvent.fromJson(json),
      'state_update' => AgentStateUpdateEvent.fromJson(json),
      _ => throw ArgumentError('Unknown event type: $type'),
    };
  }
}

/// Event emitted when an agent run starts.
class AgentRunStartEvent extends AgentEvent {
  /// Creates a run start event.
  AgentRunStartEvent({
    required this.agentName,
    required this.inputMessages,
    super.runId,
    super.timestamp,
    this.parentRunId,
    this.metadata,
  });

  /// Name of the agent starting.
  final String agentName;

  /// Input messages to the agent.
  final List<Message> inputMessages;

  /// Parent run ID if this is a nested agent call.
  final String? parentRunId;

  /// Optional metadata about the run.
  final Map<String, dynamic>? metadata;

  @override
  String get eventType => 'run_start';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'agent_name': agentName,
        'input_messages': inputMessages.map((m) => m.toJson()).toList(),
        if (parentRunId != null) 'parent_run_id': parentRunId,
        if (metadata != null) 'metadata': metadata,
      };

  /// Create from JSON.
  factory AgentRunStartEvent.fromJson(Map<String, dynamic> json) {
    return AgentRunStartEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      agentName: json['agent_name'] as String,
      inputMessages: (json['input_messages'] as List<dynamic>)
          .map((m) => Message.fromJson(m as Map<String, dynamic>))
          .toList(),
      parentRunId: json['parent_run_id'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Event emitted when an agent run completes.
class AgentRunEndEvent extends AgentEvent {
  /// Creates a run end event.
  AgentRunEndEvent({
    required this.agentName,
    required this.outputMessage,
    required this.durationMs,
    super.runId,
    super.timestamp,
    this.toolCallCount,
    this.tokenUsage,
  });

  /// Name of the agent completing.
  final String agentName;

  /// Final output message from the agent.
  final Message outputMessage;

  /// Duration of the run in milliseconds.
  final int durationMs;

  /// Number of tool calls made during execution.
  final int? toolCallCount;

  /// Token usage statistics if available.
  final TokenUsage? tokenUsage;

  @override
  String get eventType => 'run_end';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'agent_name': agentName,
        'output_message': outputMessage.toJson(),
        'duration_ms': durationMs,
        if (toolCallCount != null) 'tool_call_count': toolCallCount,
        if (tokenUsage != null) 'token_usage': tokenUsage!.toJson(),
      };

  /// Create from JSON.
  factory AgentRunEndEvent.fromJson(Map<String, dynamic> json) {
    return AgentRunEndEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      agentName: json['agent_name'] as String,
      outputMessage:
          Message.fromJson(json['output_message'] as Map<String, dynamic>),
      durationMs: json['duration_ms'] as int,
      toolCallCount: json['tool_call_count'] as int?,
      tokenUsage: json['token_usage'] != null
          ? TokenUsage.fromJson(json['token_usage'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// Event emitted when an agent produces output.
class AgentOutputEvent extends AgentEvent {
  /// Creates an output event.
  AgentOutputEvent({
    required this.message,
    super.runId,
    super.timestamp,
    this.isPartial = false,
  });

  /// The output message.
  final Message message;

  /// Whether this is a partial (streaming) output.
  final bool isPartial;

  @override
  String get eventType => 'output';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'message': message.toJson(),
        'is_partial': isPartial,
      };

  /// Create from JSON.
  factory AgentOutputEvent.fromJson(Map<String, dynamic> json) {
    return AgentOutputEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      message: Message.fromJson(json['message'] as Map<String, dynamic>),
      isPartial: json['is_partial'] as bool? ?? false,
    );
  }
}

/// Event emitted when an agent takes an action.
class AgentActionEvent extends AgentEvent {
  /// Creates an action event.
  AgentActionEvent({
    required this.action,
    super.runId,
    super.timestamp,
    this.stepNumber,
  });

  /// The action taken.
  final AgentAction action;

  /// Step number in the execution sequence.
  final int? stepNumber;

  @override
  String get eventType => 'action';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'action': action.toJson(),
        if (stepNumber != null) 'step_number': stepNumber,
      };

  /// Create from JSON.
  factory AgentActionEvent.fromJson(Map<String, dynamic> json) {
    return AgentActionEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      action: AgentAction.fromJson(json['action'] as Map<String, dynamic>),
      stepNumber: json['step_number'] as int?,
    );
  }
}

/// Event emitted when a tool execution completes.
class ToolResultEvent extends AgentEvent {
  /// Creates a tool result event.
  ToolResultEvent({
    required this.toolCallId,
    required this.toolName,
    required this.result,
    super.runId,
    super.timestamp,
    this.isError = false,
    this.durationMs,
  });

  /// ID of the tool call this result is for.
  final String toolCallId;

  /// Name of the tool that was called.
  final String toolName;

  /// Result from the tool execution.
  final String result;

  /// Whether the result is an error.
  final bool isError;

  /// Duration of tool execution in milliseconds.
  final int? durationMs;

  @override
  String get eventType => 'tool_result';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'tool_call_id': toolCallId,
        'tool_name': toolName,
        'result': result,
        'is_error': isError,
        if (durationMs != null) 'duration_ms': durationMs,
      };

  /// Create from JSON.
  factory ToolResultEvent.fromJson(Map<String, dynamic> json) {
    return ToolResultEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      toolCallId: json['tool_call_id'] as String,
      toolName: json['tool_name'] as String,
      result: json['result'] as String,
      isError: json['is_error'] as bool? ?? false,
      durationMs: json['duration_ms'] as int?,
    );
  }
}

/// Event emitted when control transfers between agents.
class AgentTransferEvent extends AgentEvent {
  /// Creates a transfer event.
  AgentTransferEvent({
    required this.fromAgent,
    required this.toAgent,
    super.runId,
    super.timestamp,
    this.reason,
    this.context,
  });

  /// Agent transferring from.
  final String fromAgent;

  /// Agent transferring to.
  final String toAgent;

  /// Reason for the transfer.
  final String? reason;

  /// Context passed to the target agent.
  final Map<String, dynamic>? context;

  @override
  String get eventType => 'transfer';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'from_agent': fromAgent,
        'to_agent': toAgent,
        if (reason != null) 'reason': reason,
        if (context != null) 'context': context,
      };

  /// Create from JSON.
  factory AgentTransferEvent.fromJson(Map<String, dynamic> json) {
    return AgentTransferEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      fromAgent: json['from_agent'] as String,
      toAgent: json['to_agent'] as String,
      reason: json['reason'] as String?,
      context: json['context'] as Map<String, dynamic>?,
    );
  }
}

/// Event emitted when an error occurs during agent execution.
class AgentErrorEvent extends AgentEvent {
  /// Creates an error event.
  AgentErrorEvent({
    required this.error,
    super.runId,
    super.timestamp,
    this.stackTrace,
    this.isRecoverable = false,
  });

  /// The error message.
  final String error;

  /// Optional stack trace.
  final String? stackTrace;

  /// Whether the error is recoverable.
  final bool isRecoverable;

  @override
  String get eventType => 'error';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'error': error,
        if (stackTrace != null) 'stack_trace': stackTrace,
        'is_recoverable': isRecoverable,
      };

  /// Create from JSON.
  factory AgentErrorEvent.fromJson(Map<String, dynamic> json) {
    return AgentErrorEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      error: json['error'] as String,
      stackTrace: json['stack_trace'] as String?,
      isRecoverable: json['is_recoverable'] as bool? ?? false,
    );
  }
}

/// Event emitted when agent internal state changes.
class AgentStateUpdateEvent extends AgentEvent {
  /// Creates a state update event.
  AgentStateUpdateEvent({
    required this.stateName,
    required this.newValue,
    super.runId,
    super.timestamp,
    this.previousValue,
  });

  /// Name of the state variable that changed.
  final String stateName;

  /// New value of the state.
  final dynamic newValue;

  /// Previous value (if available).
  final dynamic previousValue;

  @override
  String get eventType => 'state_update';

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'run_id': runId,
        'timestamp': timestamp.toIso8601String(),
        'state_name': stateName,
        'new_value': newValue,
        if (previousValue != null) 'previous_value': previousValue,
      };

  /// Create from JSON.
  factory AgentStateUpdateEvent.fromJson(Map<String, dynamic> json) {
    return AgentStateUpdateEvent(
      runId: json['run_id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      stateName: json['state_name'] as String,
      newValue: json['new_value'],
      previousValue: json['previous_value'],
    );
  }
}

/// Token usage statistics for an agent run.
class TokenUsage {
  /// Creates token usage statistics.
  const TokenUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
  });

  /// Number of tokens in the prompt.
  final int? promptTokens;

  /// Number of tokens in the completion.
  final int? completionTokens;

  /// Total tokens used.
  final int? totalTokens;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
        if (promptTokens != null) 'prompt_tokens': promptTokens,
        if (completionTokens != null) 'completion_tokens': completionTokens,
        if (totalTokens != null) 'total_tokens': totalTokens,
      };

  /// Create from JSON.
  factory TokenUsage.fromJson(Map<String, dynamic> json) {
    return TokenUsage(
      promptTokens: json['prompt_tokens'] as int?,
      completionTokens: json['completion_tokens'] as int?,
      totalTokens: json['total_tokens'] as int?,
    );
  }
}
