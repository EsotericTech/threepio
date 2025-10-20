import 'dart:convert';

import 'package:threepio_core/src/schema/message.dart';

import 'invokable_tool.dart';
import 'tool_registry.dart';

/// Result of executing a single tool call
class ToolExecutionResult {
  ToolExecutionResult({
    required this.toolCallId,
    required this.toolName,
    required this.output,
    this.error,
  });

  /// The tool call ID from the model's request
  final String toolCallId;

  /// The name of the tool that was executed
  final String toolName;

  /// The output from the tool (JSON string)
  final String output;

  /// Error message if execution failed
  final String? error;

  /// Whether execution was successful
  bool get isSuccess => error == null;

  /// Convert to a Message for sending back to the model
  Message toMessage() {
    return Message(
      role: RoleType.tool,
      content: isSuccess ? output : 'Error: $error',
      toolCallId: toolCallId,
      name: toolName,
    );
  }
}

/// Executes tool calls from model responses
///
/// Handles executing one or more tool calls using a [ToolRegistry],
/// with proper error handling and result formatting.
///
/// Example usage:
/// ```dart
/// final registry = ToolRegistry();
/// registry.register(WeatherTool());
///
/// final executor = ToolExecutor(registry: registry);
///
/// // Execute tool calls from model response
/// final results = await executor.executeToolCalls(message.toolCalls!);
///
/// // Convert to messages for next model call
/// final toolMessages = results.map((r) => r.toMessage()).toList();
/// ```
class ToolExecutor {
  ToolExecutor({required this.registry});

  /// Registry containing available tools
  final ToolRegistry registry;

  /// Execute a single tool call
  ///
  /// Returns a [ToolExecutionResult] with the output or error.
  Future<ToolExecutionResult> executeToolCall(ToolCall toolCall) async {
    try {
      // Get the tool from registry
      final tool = registry.getTool(toolCall.function.name);
      if (tool == null) {
        return ToolExecutionResult(
          toolCallId: toolCall.id,
          toolName: toolCall.function.name,
          output: '',
          error: 'Tool not found: ${toolCall.function.name}',
        );
      }

      // Validate arguments are valid JSON
      try {
        jsonDecode(toolCall.function.arguments);
      } catch (e) {
        return ToolExecutionResult(
          toolCallId: toolCall.id,
          toolName: toolCall.function.name,
          output: '',
          error: 'Invalid JSON arguments: $e',
        );
      }

      // Execute based on tool type
      String output;
      if (tool is InvokableTool) {
        output = await tool.run(toolCall.function.arguments);
      } else if (tool is StreamableTool) {
        // For streaming tools, collect all results
        final reader = await tool.streamRun(toolCall.function.arguments);
        final chunks = await reader.collectAll();
        output = chunks.join();
        await reader.close();
      } else {
        return ToolExecutionResult(
          toolCallId: toolCall.id,
          toolName: toolCall.function.name,
          output: '',
          error: 'Tool does not support execution',
        );
      }

      return ToolExecutionResult(
        toolCallId: toolCall.id,
        toolName: toolCall.function.name,
        output: output,
      );
    } catch (e, stackTrace) {
      return ToolExecutionResult(
        toolCallId: toolCall.id,
        toolName: toolCall.function.name,
        output: '',
        error: 'Execution failed: $e\n$stackTrace',
      );
    }
  }

  /// Execute multiple tool calls
  ///
  /// Returns a list of [ToolExecutionResult]s, one for each tool call.
  /// Executes all tool calls, even if some fail.
  Future<List<ToolExecutionResult>> executeToolCalls(
    List<ToolCall> toolCalls,
  ) async {
    final results = <ToolExecutionResult>[];
    for (final toolCall in toolCalls) {
      results.add(await executeToolCall(toolCall));
    }
    return results;
  }

  /// Execute multiple tool calls in parallel
  ///
  /// Returns a list of [ToolExecutionResult]s, one for each tool call.
  /// Faster than [executeToolCalls] but may use more resources.
  Future<List<ToolExecutionResult>> executeToolCallsParallel(
    List<ToolCall> toolCalls,
  ) async {
    final futures = toolCalls.map((tc) => executeToolCall(tc)).toList();
    return Future.wait(futures);
  }

  /// Execute tool calls from a message and convert results to messages
  ///
  /// Convenience method that extracts tool calls from a message,
  /// executes them, and returns the results as tool messages.
  ///
  /// Returns null if the message has no tool calls.
  Future<List<Message>?> executeFromMessage(Message message) async {
    if (message.toolCalls == null || message.toolCalls!.isEmpty) {
      return null;
    }

    final results = await executeToolCalls(message.toolCalls!);
    return results.map((r) => r.toMessage()).toList();
  }
}
