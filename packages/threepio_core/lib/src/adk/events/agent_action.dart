/// Agent actions represent decisions made by an agent during execution.
///
/// Actions are emitted as events to provide visibility into agent reasoning
/// and enable external systems to track or intercept agent behavior.
library;

/// Base class for all agent actions.
///
/// Actions represent decisions the agent has made, such as calling a tool,
/// transferring to another agent, or finishing execution.
sealed class AgentAction {
  const AgentAction();

  /// Human-readable description of this action.
  String get description;

  /// Convert to JSON for serialization.
  Map<String, dynamic> toJson();

  /// Create an action from JSON.
  static AgentAction fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'tool_call' => ToolCallAction.fromJson(json),
      'transfer_to_agent' => TransferToAgentAction.fromJson(json),
      'finish' => FinishAction.fromJson(json),
      'think' => ThinkAction.fromJson(json),
      'request_input' => RequestInputAction.fromJson(json),
      _ => throw ArgumentError('Unknown action type: $type'),
    };
  }
}

/// Action to call a tool.
///
/// Represents the agent's decision to invoke a specific tool with arguments.
class ToolCallAction extends AgentAction {
  /// Creates a tool call action.
  const ToolCallAction({
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
  });

  /// Unique identifier for this tool call.
  final String toolCallId;

  /// Name of the tool to call.
  final String toolName;

  /// JSON-encoded arguments for the tool.
  final String arguments;

  @override
  String get description => 'Call tool: $toolName';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_call',
        'tool_call_id': toolCallId,
        'tool_name': toolName,
        'arguments': arguments,
      };

  /// Create from JSON.
  factory ToolCallAction.fromJson(Map<String, dynamic> json) {
    return ToolCallAction(
      toolCallId: json['tool_call_id'] as String,
      toolName: json['tool_name'] as String,
      arguments: json['arguments'] as String,
    );
  }

  @override
  String toString() => 'ToolCallAction($toolName)';
}

/// Action to transfer execution to another agent.
///
/// Used in multi-agent systems where one agent delegates work to another.
class TransferToAgentAction extends AgentAction {
  /// Creates a transfer action.
  const TransferToAgentAction({
    required this.targetAgent,
    this.reason,
    this.context,
  });

  /// Name of the agent to transfer to.
  final String targetAgent;

  /// Optional reason for the transfer.
  final String? reason;

  /// Optional context to pass to the target agent.
  final Map<String, dynamic>? context;

  @override
  String get description => 'Transfer to agent: $targetAgent';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'transfer_to_agent',
        'target_agent': targetAgent,
        if (reason != null) 'reason': reason,
        if (context != null) 'context': context,
      };

  /// Create from JSON.
  factory TransferToAgentAction.fromJson(Map<String, dynamic> json) {
    return TransferToAgentAction(
      targetAgent: json['target_agent'] as String,
      reason: json['reason'] as String?,
      context: json['context'] as Map<String, dynamic>?,
    );
  }

  @override
  String toString() => 'TransferToAgentAction($targetAgent)';
}

/// Action to finish execution with a result.
///
/// Represents the agent's decision to complete execution and return output.
class FinishAction extends AgentAction {
  /// Creates a finish action.
  const FinishAction({
    required this.output,
    this.summary,
  });

  /// The final output from the agent.
  final String output;

  /// Optional summary of what was accomplished.
  final String? summary;

  @override
  String get description => 'Finish with output';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'finish',
        'output': output,
        if (summary != null) 'summary': summary,
      };

  /// Create from JSON.
  factory FinishAction.fromJson(Map<String, dynamic> json) {
    return FinishAction(
      output: json['output'] as String,
      summary: json['summary'] as String?,
    );
  }

  @override
  String toString() => 'FinishAction(${output.length} chars)';
}

/// Action representing internal reasoning/thinking.
///
/// Used to expose the agent's chain of thought for debugging and transparency.
class ThinkAction extends AgentAction {
  /// Creates a think action.
  const ThinkAction({
    required this.thought,
  });

  /// The agent's internal thought/reasoning.
  final String thought;

  @override
  String get description => 'Think';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'think',
        'thought': thought,
      };

  /// Create from JSON.
  factory ThinkAction.fromJson(Map<String, dynamic> json) {
    return ThinkAction(
      thought: json['thought'] as String,
    );
  }

  @override
  String toString() => 'ThinkAction(${thought.length} chars)';
}

/// Action to request input from a human.
///
/// Used when the agent needs external input to proceed.
class RequestInputAction extends AgentAction {
  /// Creates a request input action.
  const RequestInputAction({
    required this.prompt,
    this.inputType,
    this.options,
  });

  /// The prompt to show the human.
  final String prompt;

  /// Optional type hint for expected input (text, choice, confirmation).
  final String? inputType;

  /// Optional choices for multiple-choice input.
  final List<String>? options;

  @override
  String get description => 'Request human input';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'request_input',
        'prompt': prompt,
        if (inputType != null) 'input_type': inputType,
        if (options != null) 'options': options,
      };

  /// Create from JSON.
  factory RequestInputAction.fromJson(Map<String, dynamic> json) {
    return RequestInputAction(
      prompt: json['prompt'] as String,
      inputType: json['input_type'] as String?,
      options: (json['options'] as List<dynamic>?)?.cast<String>(),
    );
  }

  @override
  String toString() => 'RequestInputAction("$prompt")';
}
