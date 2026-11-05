/// Agent-specific exceptions for the ADK.
///
/// Provides typed exceptions for common agent failure modes,
/// enabling proper error handling and recovery strategies.
library;

import '../../errors.dart';

/// Base class for all agent exceptions.
abstract class AgentException implements ThreepioException {
  /// Creates an agent exception.
  const AgentException({
    required this.message,
    this.agentName,
    this.runId,
    this.cause,
  });

  /// Description of what went wrong.
  @override
  final String message;

  /// Name of the agent that encountered the error.
  final String? agentName;

  /// Run ID where the error occurred.
  final String? runId;

  /// Underlying cause of this exception.
  @override
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer(runtimeType.toString());
    buffer.write(': $message');
    if (agentName != null) buffer.write(' (agent: $agentName)');
    if (runId != null) buffer.write(' [run: $runId]');
    return buffer.toString();
  }
}

/// Exception thrown when an agent exceeds its maximum iterations.
class MaxIterationsExceededException extends AgentException {
  /// Creates a max iterations exceeded exception.
  const MaxIterationsExceededException({
    required this.iterations,
    required this.maxIterations,
    super.agentName,
    super.runId,
  }) : super(
          message:
              'Agent exceeded maximum iterations: $iterations >= $maxIterations',
        );

  /// Number of iterations executed.
  final int iterations;

  /// Maximum allowed iterations.
  final int maxIterations;
}

/// Exception thrown when a tool execution fails.
class ToolExecutionException extends AgentException {
  /// Creates a tool execution exception.
  const ToolExecutionException({
    required this.toolName,
    required String message,
    super.agentName,
    super.runId,
    super.cause,
    this.toolCallId,
    this.arguments,
  }) : super(message: 'Tool "$toolName" failed: $message');

  /// Name of the tool that failed.
  final String toolName;

  /// ID of the tool call.
  final String? toolCallId;

  /// Arguments that were passed to the tool.
  final String? arguments;
}

/// Exception thrown when an agent transfer fails.
class AgentTransferException extends AgentException {
  /// Creates an agent transfer exception.
  const AgentTransferException({
    required this.targetAgent,
    required String message,
    super.agentName,
    super.runId,
    super.cause,
  }) : super(message: 'Transfer to "$targetAgent" failed: $message');

  /// Target agent that couldn't be reached.
  final String targetAgent;
}

/// Exception thrown when agent configuration is invalid.
class AgentConfigurationException extends AgentException {
  /// Creates an agent configuration exception.
  const AgentConfigurationException({
    required String message,
    super.agentName,
    this.configKey,
    this.configValue,
  }) : super(message: message);

  /// The configuration key that was invalid.
  final String? configKey;

  /// The invalid value.
  final dynamic configValue;
}

/// Exception thrown when agent input is invalid.
class InvalidAgentInputException extends AgentException {
  /// Creates an invalid agent input exception.
  const InvalidAgentInputException({
    required String message,
    super.agentName,
    super.runId,
    this.inputType,
  }) : super(message: message);

  /// Type of input that was invalid.
  final String? inputType;
}

/// Exception thrown when an agent run times out.
class AgentTimeoutException extends AgentException {
  /// Creates an agent timeout exception.
  AgentTimeoutException({
    required this.timeout,
    super.agentName,
    super.runId,
  }) : super(
          message: 'Agent execution timed out after ${timeout.inSeconds}s',
        );

  /// The timeout duration that was exceeded.
  final Duration timeout;
}

/// Exception thrown when agent execution is cancelled.
class AgentCancelledException extends AgentException {
  /// Creates an agent cancelled exception.
  const AgentCancelledException({
    super.agentName,
    super.runId,
    String? reason,
  }) : super(message: reason ?? 'Agent execution was cancelled');
}

/// Exception thrown when a required tool is not found.
class ToolNotFoundException extends AgentException {
  /// Creates a tool not found exception.
  const ToolNotFoundException({
    required this.toolName,
    super.agentName,
    super.runId,
    this.availableTools,
  }) : super(message: 'Tool not found: $toolName');

  /// Name of the tool that wasn't found.
  final String toolName;

  /// List of available tools (for helpful error messages).
  final List<String>? availableTools;

  @override
  String toString() {
    final base = super.toString();
    if (availableTools != null && availableTools!.isNotEmpty) {
      return '$base. Available tools: ${availableTools!.join(", ")}';
    }
    return base;
  }
}

/// Exception thrown during planning phase failures.
class PlanningException extends AgentException {
  /// Creates a planning exception.
  const PlanningException({
    required String message,
    super.agentName,
    super.runId,
    super.cause,
    this.partialPlan,
  }) : super(message: message);

  /// Any partial plan that was generated before failure.
  final List<String>? partialPlan;
}

/// Exception thrown when workflow execution fails.
class WorkflowException extends AgentException {
  /// Creates a workflow exception.
  const WorkflowException({
    required String message,
    super.agentName,
    super.runId,
    super.cause,
    this.failedStep,
    this.stepIndex,
  }) : super(message: message);

  /// Name of the step that failed.
  final String? failedStep;

  /// Index of the failed step.
  final int? stepIndex;
}
