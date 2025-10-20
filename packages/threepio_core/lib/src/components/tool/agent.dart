import 'package:threepio_core/src/components/model/base_chat_model.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';
import 'package:threepio_core/src/streaming/stream_utils.dart';
import 'package:threepio_core/src/streaming/stream_writer.dart';

import 'tool_executor.dart';
import 'tool_registry.dart';

/// Configuration for agent execution
class AgentConfig {
  const AgentConfig({
    this.maxIterations = 10,
    this.maxToolCalls = 20,
    this.throwOnMaxIterations = false,
  });

  /// Maximum number of model-tool iterations
  final int maxIterations;

  /// Maximum total number of tool calls across all iterations
  final int maxToolCalls;

  /// Whether to throw an exception when max iterations is reached
  final bool throwOnMaxIterations;
}

/// Exception thrown when agent limits are exceeded
class AgentLimitException implements Exception {
  AgentLimitException(this.message);

  final String message;

  @override
  String toString() => 'AgentLimitException: $message';
}

/// Agent that orchestrates model and tool execution (ReAct pattern)
///
/// Implements the Reasoning + Acting pattern where the model can:
/// 1. Reason about what to do
/// 2. Call tools to take actions
/// 3. Observe tool results
/// 4. Continue reasoning until task is complete
///
/// Example usage:
/// ```dart
/// final model = OpenAIChatModel(config: config);
/// final registry = ToolRegistry();
/// registry.register(WeatherTool());
/// registry.register(CalculatorTool());
///
/// final agent = Agent(
///   model: model,
///   toolRegistry: registry,
///   config: AgentConfig(maxIterations: 5),
/// );
///
/// final messages = [Message.user('What is the weather in NYC?')];
/// final response = await agent.run(messages);
/// print(response.content);
/// ```
class Agent {
  Agent({
    required this.model,
    required this.toolRegistry,
    this.config = const AgentConfig(),
  }) : _executor = ToolExecutor(registry: toolRegistry);

  /// The chat model to use for reasoning
  final ToolCallingChatModel model;

  /// Registry of available tools
  final ToolRegistry toolRegistry;

  /// Agent configuration
  final AgentConfig config;

  /// Tool executor
  final ToolExecutor _executor;

  /// Run the agent with the given messages
  ///
  /// Executes the ReAct loop:
  /// 1. Call model with messages
  /// 2. If model requests tool calls, execute them
  /// 3. Add tool results to messages
  /// 4. Repeat until model returns final response or limit reached
  ///
  /// Returns the final message from the model.
  Future<Message> run(List<Message> messages) async {
    // Get tool info and bind to model
    final toolInfoList = await toolRegistry.getToolInfoList();
    final modelWithTools = model.withTools(toolInfoList);

    // Track iterations and tool calls
    var iteration = 0;
    var totalToolCalls = 0;
    final conversationHistory = List<Message>.from(messages);

    while (iteration < config.maxIterations) {
      iteration++;

      // Call model
      final response = await modelWithTools.generate(conversationHistory);

      // Check if model wants to call tools
      if (response.toolCalls == null || response.toolCalls!.isEmpty) {
        // No tool calls - this is the final response
        return response;
      }

      // Check tool call limit
      totalToolCalls += response.toolCalls!.length;
      if (totalToolCalls > config.maxToolCalls) {
        throw AgentLimitException(
          'Exceeded maximum tool calls: $totalToolCalls > ${config.maxToolCalls}',
        );
      }

      // Add assistant message with tool calls to history
      conversationHistory.add(response);

      // Execute tool calls
      final toolResults = await _executor.executeToolCalls(response.toolCalls!);

      // Add tool results to history
      for (final result in toolResults) {
        conversationHistory.add(result.toMessage());
      }

      // Continue loop for next iteration
    }

    // Max iterations reached
    if (config.throwOnMaxIterations) {
      throw AgentLimitException(
        'Exceeded maximum iterations: ${config.maxIterations}',
      );
    }

    // Return last message in history (likely a tool result)
    return conversationHistory.last;
  }

  /// Run the agent with streaming responses
  ///
  /// Similar to [run], but streams the model's responses as they are generated.
  /// Note: Only the model's reasoning is streamed, not tool execution.
  ///
  /// Returns a [StreamReader] that emits:
  /// - Model response chunks during reasoning
  /// - Complete messages after tool execution
  Future<StreamReader<Message>> stream(List<Message> messages) async {
    // Get tool info and bind to model
    final toolInfoList = await toolRegistry.getToolInfoList();
    final modelWithTools = model.withTools(toolInfoList);

    // Create output stream
    final (reader, writer) = pipe<Message>();

    // Run agent loop in background
    _runStreamingLoop(
      modelWithTools,
      messages,
      writer,
    )
        .then((_) => writer.close())
        .catchError((Object error, StackTrace stackTrace) {
      writer.sendError(error, stackTrace);
      writer.close();
    });

    return reader;
  }

  /// Internal streaming loop
  Future<void> _runStreamingLoop(
    ToolCallingChatModel modelWithTools,
    List<Message> messages,
    StreamWriter<Message> writer,
  ) async {
    var iteration = 0;
    var totalToolCalls = 0;
    final conversationHistory = List<Message>.from(messages);

    while (iteration < config.maxIterations) {
      iteration++;

      // Stream model response
      final responseReader = await modelWithTools.stream(conversationHistory);

      // Collect chunks and reconstruct full message
      final chunks = <Message>[];
      try {
        while (true) {
          final chunk = await responseReader.recv();
          chunks.add(chunk);
          writer.send(chunk); // Stream to output
        }
      } on StreamEOFException {
        // Stream complete
      }
      await responseReader.close();

      // Reconstruct full message from chunks
      final fullMessage = _reconstructMessage(chunks);

      // Check if model wants to call tools
      if (fullMessage.toolCalls == null || fullMessage.toolCalls!.isEmpty) {
        // No tool calls - this is the final response
        return;
      }

      // Check tool call limit
      totalToolCalls += fullMessage.toolCalls!.length;
      if (totalToolCalls > config.maxToolCalls) {
        throw AgentLimitException(
          'Exceeded maximum tool calls: $totalToolCalls > ${config.maxToolCalls}',
        );
      }

      // Add assistant message with tool calls to history
      conversationHistory.add(fullMessage);

      // Execute tool calls
      final toolResults =
          await _executor.executeToolCalls(fullMessage.toolCalls!);

      // Add tool results to history and output stream
      for (final result in toolResults) {
        final message = result.toMessage();
        conversationHistory.add(message);
        writer.send(message); // Stream tool results
      }

      // Continue loop for next iteration
    }

    // Max iterations reached
    if (config.throwOnMaxIterations) {
      throw AgentLimitException(
        'Exceeded maximum iterations: ${config.maxIterations}',
      );
    }
  }

  /// Reconstruct a complete message from streaming chunks
  Message _reconstructMessage(List<Message> chunks) {
    if (chunks.isEmpty) {
      return Message(role: RoleType.assistant, content: '');
    }

    // Combine content from all chunks
    final contentBuffer = StringBuffer();
    final toolCalls = <ToolCall>[];
    ResponseMeta? responseMeta;

    for (final chunk in chunks) {
      if (chunk.content.isNotEmpty) {
        contentBuffer.write(chunk.content);
      }

      if (chunk.toolCalls != null) {
        // In streaming, tool calls come incrementally
        // We need to merge them by index
        for (final tc in chunk.toolCalls!) {
          if (tc.index != null) {
            // Ensure we have enough slots
            while (toolCalls.length <= tc.index!) {
              toolCalls.add(
                ToolCall(
                  id: '',
                  type: 'function',
                  function: FunctionCall(name: '', arguments: ''),
                ),
              );
            }

            // Merge this chunk into the existing tool call
            final existing = toolCalls[tc.index!];
            toolCalls[tc.index!] = ToolCall(
              id: tc.id.isNotEmpty ? tc.id : existing.id,
              type: tc.type,
              function: FunctionCall(
                name: tc.function.name.isNotEmpty
                    ? tc.function.name
                    : existing.function.name,
                arguments: existing.function.arguments + tc.function.arguments,
              ),
              index: tc.index,
            );
          } else {
            toolCalls.add(tc);
          }
        }
      }

      if (chunk.responseMeta != null) {
        responseMeta = chunk.responseMeta;
      }
    }

    return Message(
      role: RoleType.assistant,
      content: contentBuffer.toString(),
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      responseMeta: responseMeta,
    );
  }
}
