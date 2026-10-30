import 'dart:async';

import '../../components/model/base_chat_model.dart';
import '../../components/tool/tool_executor.dart';
import '../../components/tool/tool_registry.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import '../../streaming/stream_utils.dart';
import '../../streaming/stream_writer.dart';
import '../core/agent_exception.dart';
import '../core/base_agent.dart';
import '../events/agent_action.dart';
import '../events/agent_event.dart';

/// Configuration for ChatModelAgent execution.
class LegacyChatModelAgentConfig {
  /// Creates agent configuration.
  const LegacyChatModelAgentConfig({
    this.maxIterations = 10,
    this.maxToolCalls = 50,
    this.emitPartialOutputs = true,
    this.emitThinking = false,
  });

  /// Maximum iterations for the ReAct loop.
  final int maxIterations;

  /// Maximum total tool calls across all iterations.
  final int maxToolCalls;

  /// Whether to emit partial outputs during streaming.
  final bool emitPartialOutputs;

  /// Whether to emit thinking/reasoning events.
  final bool emitThinking;
}

/// Previous-generation chat model agent (v0.5-era Eino ADK shape).
///
/// Superseded by `ChatModelAgent` + `Runner` in `adk/runtime`, which add
/// cancellation at safe points, tool approval, parallel tool execution with
/// ordered results, handlers (middleware) and reasoning events. Kept for
/// compatibility; new code should not use it.
///
/// Implements the ReAct (Reasoning + Acting) pattern with full event
/// visibility. Emits events for all actions, tool calls, and state changes.
///
/// Example:
/// ```dart
/// final agent = LegacyChatModelAgent(
///   name: 'assistant',
///   description: 'A helpful assistant',
///   model: chatModel,
///   toolRegistry: registry,
/// );
///
/// // Stream events
/// final stream = await agent.run([Message.user('Calculate 2+2')]);
/// await for (final event in stream.asStream()) {
///   switch (event) {
///     case AgentActionEvent(:final action):
///       print('Action: ${action.description}');
///     case ToolResultEvent(:final result):
///       print('Tool result: $result');
///     case AgentOutputEvent(:final message):
///       print('Output: ${message.content}');
///   }
/// }
/// ```
class LegacyChatModelAgent with AgentMixin implements BaseAgent {
  /// Creates a chat model agent.
  LegacyChatModelAgent({
    required this.name,
    required this.description,
    required ToolCallingChatModel model,
    required ToolRegistry toolRegistry,
    this.systemPrompt,
    this.config = const LegacyChatModelAgentConfig(),
  })  : _model = model,
        _toolRegistry = toolRegistry,
        _executor = ToolExecutor(registry: toolRegistry);

  @override
  final String name;

  @override
  final String description;

  final ToolCallingChatModel _model;
  final ToolRegistry _toolRegistry;
  final ToolExecutor _executor;

  /// Optional system prompt prepended to all conversations.
  final String? systemPrompt;

  /// Agent configuration.
  final LegacyChatModelAgentConfig config;

  @override
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final ctx = context ?? AgentRunContext();

    // Create output stream
    final (reader, writer) = pipe<AgentEvent>();

    // Run agent loop in background
    _runLoop(messages, writer, ctx)
        .then((_) => writer.close())
        .catchError((Object error, StackTrace stackTrace) {
      writer.send(AgentErrorEvent(
        error: error.toString(),
        stackTrace: stackTrace.toString(),
        runId: ctx.runId,
      ));
      writer.close();
    });

    return reader;
  }

  @override
  Future<Message> invoke(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final reader = await run(messages, context: context);
    Message? lastOutput;

    try {
      while (true) {
        final event = await reader.recv();
        if (event is AgentOutputEvent && !event.isPartial) {
          lastOutput = event.message;
        }
        if (event is AgentRunEndEvent) {
          return event.outputMessage;
        }
      }
    } on StreamEOFException {
      // Stream ended
    } finally {
      await reader.close();
    }

    return lastOutput ?? Message.assistant('');
  }

  @override
  BaseAgent copyWith({
    String? name,
    String? description,
  }) {
    return LegacyChatModelAgent(
      name: name ?? this.name,
      description: description ?? this.description,
      model: _model,
      toolRegistry: _toolRegistry,
      systemPrompt: systemPrompt,
      config: config,
    );
  }

  Future<void> _runLoop(
    List<Message> messages,
    StreamWriter<AgentEvent> writer,
    AgentRunContext context,
  ) async {
    final startTime = DateTime.now();

    // Emit run start
    writer.send(AgentRunStartEvent(
      agentName: name,
      inputMessages: messages,
      runId: context.runId,
      parentRunId: context.parentRunId,
    ));
    emitEvent(
      AgentRunStartEvent(
        agentName: name,
        inputMessages: messages,
        runId: context.runId,
        parentRunId: context.parentRunId,
      ),
      context,
    );

    // Prepare conversation history
    final history = <Message>[];
    if (systemPrompt != null) {
      history.add(Message.system(systemPrompt!));
    }
    history.addAll(messages);

    // Get tool info and bind to model
    final toolInfoList = await _toolRegistry.getToolInfoList();
    final modelWithTools = _model.withTools(toolInfoList);

    var iteration = 0;
    var totalToolCalls = 0;
    Message? finalOutput;

    while (iteration < config.maxIterations) {
      // Check for cancellation
      checkCancellation(context);

      iteration++;

      // Generate response with streaming
      final responseReader = await modelWithTools.stream(history);
      final chunks = <Message>[];

      try {
        while (true) {
          final chunk = await responseReader.recv();
          chunks.add(chunk);

          // Emit partial output if enabled
          if (config.emitPartialOutputs && chunk.content.isNotEmpty) {
            writer.send(AgentOutputEvent(
              message: chunk,
              isPartial: true,
              runId: context.runId,
            ));
          }
        }
      } on StreamEOFException {
        // Stream complete
      }
      await responseReader.close();

      // Reconstruct full message
      final response = _reconstructMessage(chunks);

      // Check for tool calls
      if (response.toolCalls == null || response.toolCalls!.isEmpty) {
        // Final response
        finalOutput = response;

        // Emit final output
        writer.send(AgentOutputEvent(
          message: response,
          isPartial: false,
          runId: context.runId,
        ));

        // Emit finish action
        writer.send(AgentActionEvent(
          action: FinishAction(output: response.content),
          runId: context.runId,
          stepNumber: iteration,
        ));

        break;
      }

      // Process tool calls
      totalToolCalls += response.toolCalls!.length;
      if (totalToolCalls > config.maxToolCalls) {
        throw MaxIterationsExceededException(
          iterations: totalToolCalls,
          maxIterations: config.maxToolCalls,
          agentName: name,
          runId: context.runId,
        );
      }

      // Add assistant message to history
      history.add(response);

      // Execute each tool call
      for (final toolCall in response.toolCalls!) {
        // Emit tool call action
        writer.send(AgentActionEvent(
          action: ToolCallAction(
            toolCallId: toolCall.id,
            toolName: toolCall.function.name,
            arguments: toolCall.function.arguments,
          ),
          runId: context.runId,
          stepNumber: iteration,
        ));
      }

      // Execute tools
      final toolStart = DateTime.now();
      final results = await _executor.executeToolCalls(response.toolCalls!);
      final toolDuration =
          DateTime.now().difference(toolStart).inMilliseconds;

      // Add results to history and emit events
      for (var i = 0; i < results.length; i++) {
        final result = results[i];
        final toolCall = response.toolCalls![i];

        // Add to history
        history.add(result.toMessage());

        // Emit tool result event
        writer.send(ToolResultEvent(
          toolCallId: toolCall.id,
          toolName: toolCall.function.name,
          result: result.output,
          isError: !result.isSuccess,
          durationMs: toolDuration ~/ results.length,
          runId: context.runId,
        ));
      }
    }

    // Check if we hit max iterations
    if (finalOutput == null) {
      throw MaxIterationsExceededException(
        iterations: iteration,
        maxIterations: config.maxIterations,
        agentName: name,
        runId: context.runId,
      );
    }

    // Emit run end
    final endEvent = AgentRunEndEvent(
      agentName: name,
      outputMessage: finalOutput,
      durationMs: DateTime.now().difference(startTime).inMilliseconds,
      toolCallCount: totalToolCalls,
      runId: context.runId,
    );
    writer.send(endEvent);
    emitEvent(endEvent, context);
  }

  Message _reconstructMessage(List<Message> chunks) {
    if (chunks.isEmpty) {
      return Message(role: RoleType.assistant, content: '');
    }

    final contentBuffer = StringBuffer();
    final toolCalls = <ToolCall>[];
    ResponseMeta? responseMeta;
    String? reasoningContent;

    for (final chunk in chunks) {
      if (chunk.content.isNotEmpty) {
        contentBuffer.write(chunk.content);
      }

      if (chunk.reasoningContent != null) {
        reasoningContent = (reasoningContent ?? '') + chunk.reasoningContent!;
      }

      if (chunk.toolCalls != null) {
        for (final tc in chunk.toolCalls!) {
          if (tc.index != null) {
            while (toolCalls.length <= tc.index!) {
              toolCalls.add(
                ToolCall(
                  id: '',
                  type: 'function',
                  function: FunctionCall(name: '', arguments: ''),
                ),
              );
            }

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
      reasoningContent: reasoningContent,
    );
  }
}
