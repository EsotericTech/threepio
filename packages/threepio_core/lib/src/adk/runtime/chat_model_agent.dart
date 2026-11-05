import 'dart:async';

import '../../components/model/base_chat_model.dart';
import '../../components/model/cancel_token.dart';
import '../../components/model/chat_model_options.dart';
import '../../components/tool/invokable_tool.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import '../../streaming/stream_utils.dart';
import '../../streaming/stream_writer.dart';
import '../events/agent_action.dart';
import '../events/agent_event.dart' hide TokenUsage;
import 'agent_handler.dart';
import 'tool_call_context.dart';

/// Which tool calls need the user's consent before they run.
class ApprovalPolicy {
  const ApprovalPolicy({
    this.toolsRequiringApproval = const {},
    this.reasonFor,
  });

  /// Always asks for these tool names.
  final Set<String> toolsRequiringApproval;

  /// Returns a reason to ask, or `null` to run without asking.
  final String? Function(ToolCall call)? reasonFor;

  /// `null` when the call may run unattended.
  String? approvalReason(ToolCall call) {
    if (toolsRequiringApproval.contains(call.function.name)) {
      return '${call.function.name} needs your confirmation';
    }
    return reasonFor?.call(call);
  }
}

/// Answers an approval request; `true` lets the tool run.
typedef ApprovalRequest = Future<bool> Function(ToolCall call, String? reason);

/// Per-run scope of the Kortney runtime: ids, cancellation and the approval
/// channel.
///
/// Called `RunContext` before 0.9. That name now belongs to the core context
/// every Eino-shaped API takes as its first parameter.
class AgentRunScope {
  AgentRunScope({
    String? runId,
    this.sessionId,
    CancelToken? cancelToken,
    this.requestApproval,
    this.metadata = const {},
  })  : runId = runId ?? 'run_${DateTime.now().microsecondsSinceEpoch}',
        cancelToken = cancelToken ?? CancelToken();

  final String runId;
  final String? sessionId;
  final CancelToken cancelToken;
  final ApprovalRequest? requestApproval;
  final Map<String, dynamic> metadata;
}

/// Configuration for [ChatModelAgent].
class ChatModelAgentConfig {
  const ChatModelAgentConfig({
    required this.name,
    required this.model,
    this.description = '',
    this.instruction,
    this.tools = const [],
    this.maxIterations = 20,
    this.handlers = const [],
    this.approvalPolicy = const ApprovalPolicy(),
    this.parallelToolExecution = true,
    this.toolTimeout = const Duration(seconds: 120),
    this.modelOptions,
    this.emitPartialOutputs = true,
  });

  final String name;
  final String description;

  /// System instruction placed first in the history.
  final String? instruction;
  final ToolCallingChatModel model;
  final List<BaseTool> tools;

  /// Model-call + tool-execution rounds before the run stops.
  final int maxIterations;
  final List<AgentHandler> handlers;
  final ApprovalPolicy approvalPolicy;

  /// Run several tool calls from one turn concurrently.
  final bool parallelToolExecution;

  /// Per tool call; a timed-out call becomes an error result.
  final Duration toolTimeout;

  /// Options sent on every model call (model id, temperature, extra…).
  final ChatModelOptions? modelOptions;

  /// Emit `AgentOutputEvent(isPartial: true)` for every text delta.
  final bool emitPartialOutputs;
}

/// Model + tools loop shaped after Eino's `ChatModelAgent` (v0.9):
///
/// 1. handlers' `beforeModel`
/// 2. stream the model; emit text and reasoning deltas
/// 3. append the assembled assistant turn (`AgentMessageEvent`)
/// 4. no tool calls → final `AgentOutputEvent` and `AgentRunEndEvent`
/// 5. otherwise ask for approval where the policy requires it, run the
///    tools (concurrently by default), append their results in the order
///    the model requested them, and loop
///
/// Cancellation is honoured at safe points: after the model call and after
/// tool execution. Tools still running at cancellation get synthetic
/// "cancelled" results so the history stays well-formed.
///
/// Run it through a [Runner] to get per-session run tracking, approval
/// plumbing and a `RunResult`.
class ChatModelAgent {
  ChatModelAgent(this.config);

  final ChatModelAgentConfig config;

  String get name => config.name;
  String get description => config.description;

  /// Starts a run; events arrive on the returned reader.
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunScope? context,
  }) async {
    final ctx = context ?? AgentRunScope();
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(
      _runLoop(messages, writer, ctx).then(
        (_) => writer.close(),
        onError: (Object error, StackTrace stackTrace) {
          writer.send(
            AgentErrorEvent(
              runId: ctx.runId,
              error: error.toString(),
              stackTrace: stackTrace.toString(),
              isRecoverable: false,
            ),
          );
          return writer.close();
        },
      ),
    );
    return reader;
  }

  Future<void> _runLoop(
    List<Message> input,
    StreamWriter<AgentEvent> writer,
    AgentRunScope ctx,
  ) async {
    final runId = ctx.runId;
    final cancel = ctx.cancelToken;
    final stopwatch = Stopwatch()..start();

    final toolInfos = <ToolInfo>[];
    final toolsByName = <String, BaseTool>{};
    for (final tool in config.tools) {
      final info = await tool.info();
      toolInfos.add(info);
      toolsByName[info.function.name] = tool;
    }

    final state = ChatModelAgentState(
      messages: [
        if (config.instruction != null) Message.system(config.instruction!),
        ...input,
      ],
      toolInfos: toolInfos,
      instruction: config.instruction,
    );

    writer.send(
      AgentRunStartEvent(
        runId: runId,
        agentName: name,
        inputMessages: input,
        metadata: ctx.metadata,
      ),
    );

    var totalUsage = TokenUsage.zero;
    var toolCallCount = 0;
    Message? lastAssistant;

    void finish(Message output) {
      writer.send(
        AgentRunEndEvent(
          runId: runId,
          agentName: name,
          outputMessage: output,
          durationMs: stopwatch.elapsedMilliseconds,
          toolCallCount: toolCallCount,
        ),
      );
    }

    for (state.iteration = 0;
        state.iteration < config.maxIterations;
        state.iteration++) {
      if (cancel.isCancelled) {
        writer.send(AgentCancelledEvent(runId: runId, reason: cancel.reason));
        return;
      }

      for (final handler in config.handlers) {
        await handler.beforeModel(state);
      }
      _syncInstruction(state);

      final model = state.toolInfos.isEmpty
          ? config.model
          : config.model.withTools(state.toolInfos);
      final options = (config.modelOptions ?? const ChatModelOptions())
          .copyWith(cancelToken: cancel);

      final callStopwatch = Stopwatch()..start();
      final chunks = <Message>[];
      try {
        final reader = await model.stream(state.messages, options: options);
        await for (final chunk in reader.asStream()) {
          chunks.add(chunk);
          if (config.emitPartialOutputs && chunk.content.isNotEmpty) {
            writer.send(
              AgentOutputEvent(runId: runId, message: chunk, isPartial: true),
            );
          }
          final reasoning = chunk.reasoningContent;
          if (reasoning != null && reasoning.isNotEmpty) {
            writer.send(AgentReasoningEvent(runId: runId, delta: reasoning));
          }
        }
      } on CancelledException {
        writer.send(AgentCancelledEvent(runId: runId, reason: cancel.reason));
        return;
      }
      if (cancel.isCancelled) {
        writer.send(AgentCancelledEvent(runId: runId, reason: cancel.reason));
        return;
      }

      final response = _assemble(chunks);
      final usage = response.responseMeta?.usage;
      if (usage != null) {
        totalUsage = totalUsage + usage;
        writer.send(
          AgentUsageEvent(
            runId: runId,
            usage: usage,
            model: options.model,
            latency: callStopwatch.elapsed,
          ),
        );
      }

      for (final handler in config.handlers) {
        await handler.afterModel(state, response);
      }
      state.messages.add(response);
      lastAssistant = response;
      writer.send(AgentMessageEvent(runId: runId, message: response));

      final calls = response.toolCalls ?? const <ToolCall>[];
      if (calls.isEmpty) {
        writer.send(AgentOutputEvent(runId: runId, message: response));
        finish(response);
        return;
      }

      toolCallCount += calls.length;
      for (final call in calls) {
        writer.send(
          AgentActionEvent(
            runId: runId,
            action: ToolCallAction(
              toolCallId: call.id,
              toolName: call.function.name,
              arguments: call.function.arguments,
            ),
            stepNumber: state.iteration,
          ),
        );
      }

      final (toolMessages, cancelledIds) = await _executeToolCalls(
        calls,
        toolsByName,
        writer,
        ctx,
      );
      state.messages.addAll(toolMessages);
      for (final message in toolMessages) {
        writer.send(AgentMessageEvent(runId: runId, message: message));
      }
      if (cancel.isCancelled) {
        writer.send(
          AgentCancelledEvent(
            runId: runId,
            reason: cancel.reason,
            cancelledToolCallIds: cancelledIds,
          ),
        );
        return;
      }
    }

    writer.send(
      AgentErrorEvent(
        runId: runId,
        error:
            'Stopped after ${config.maxIterations} iterations without a final answer',
        isRecoverable: true,
      ),
    );
    final output = lastAssistant ?? Message.assistant('');
    writer.send(AgentOutputEvent(runId: runId, message: output));
    finish(output);
  }

  /// Keeps the leading system message in step with `state.instruction`.
  void _syncInstruction(ChatModelAgentState state) {
    final instruction = state.instruction;
    final hasSystem = state.messages.isNotEmpty &&
        state.messages.first.role == RoleType.system;
    if (instruction == null || instruction.isEmpty) {
      if (hasSystem && config.instruction != null) state.messages.removeAt(0);
      return;
    }
    if (hasSystem) {
      if (state.messages.first.content != instruction) {
        state.messages[0] = Message.system(instruction);
      }
    } else {
      state.messages.insert(0, Message.system(instruction));
    }
  }

  /// Merges streamed deltas into one assistant message.
  Message _assemble(List<Message> chunks) {
    if (chunks.isEmpty) return Message.assistant('');
    final merged = MessageConcatenator.concat(
      chunks.map((c) => c.copyWith(role: RoleType.assistant)).toList(),
    );
    // Strip empty tool-call shells and streaming-only index noise.
    final calls = merged.toolCalls
        ?.where((c) => c.function.name.isNotEmpty)
        .toList();
    return merged.copyWith(
      toolCalls: calls == null || calls.isEmpty ? null : calls,
    );
  }

  Future<(List<Message>, List<String>)> _executeToolCalls(
    List<ToolCall> calls,
    Map<String, BaseTool> toolsByName,
    StreamWriter<AgentEvent> writer,
    AgentRunScope ctx,
  ) async {
    final cancel = ctx.cancelToken;
    final results = List<Message?>.filled(calls.length, null);

    Future<void> runAt(int i) async {
      results[i] = await _runOne(calls[i], toolsByName, writer, ctx);
    }

    if (config.parallelToolExecution) {
      final all = Future.wait([for (var i = 0; i < calls.length; i++) runAt(i)]);
      await Future.any<void>([all, cancel.whenCancelled]);
    } else {
      for (var i = 0; i < calls.length; i++) {
        if (cancel.isCancelled) break;
        await runAt(i);
      }
    }

    final cancelledIds = <String>[];
    final messages = <Message>[];
    for (var i = 0; i < calls.length; i++) {
      final done = results[i];
      if (done != null) {
        messages.add(done);
      } else {
        cancelledIds.add(calls[i].id);
        messages.add(
          Message.tool(
            content: 'Error: cancelled by the user before it finished.',
            toolCallId: calls[i].id,
            toolName: calls[i].function.name,
          ),
        );
      }
    }
    return (messages, cancelledIds);
  }

  Future<Message> _runOne(
    ToolCall call,
    Map<String, BaseTool> toolsByName,
    StreamWriter<AgentEvent> writer,
    AgentRunScope ctx,
  ) async {
    final runId = ctx.runId;
    final name = call.function.name;
    final stopwatch = Stopwatch()..start();
    final context = ToolCallContext(
      runId: runId,
      sessionId: ctx.sessionId,
      toolCall: call,
      cancelToken: ctx.cancelToken,
      metadata: ctx.metadata,
    );

    ToolOutput output;
    final tool = toolsByName[name];
    final reason = config.approvalPolicy.approvalReason(call);
    if (tool == null) {
      output = ToolOutput.error('Unknown tool: $name');
    } else if (reason != null && !await _approved(call, reason, writer, ctx)) {
      output = const ToolOutput.error('The user declined to run this tool.');
    } else {
      Future<ToolOutput> invoke(ToolCallContext c, String args) async {
        if (tool is ContextualTool) return tool.runWithContext(c, args);
        if (tool is InvokableTool) {
          return ToolOutput(content: await tool.run(args));
        }
        return ToolOutput.error('Tool $name cannot be invoked');
      }

      ToolCallNext chain = invoke;
      for (final handler in config.handlers.reversed) {
        final next = chain;
        chain = (c, args) => handler.wrapToolCall(c, args, next);
      }

      try {
        output = await chain(context, call.function.arguments)
            .timeout(config.toolTimeout);
      } on TimeoutException {
        output = ToolOutput.error(
          '$name timed out after ${config.toolTimeout.inSeconds}s',
        );
      } on CancelledException {
        output = const ToolOutput.error(
          'Cancelled by the user before it finished.',
        );
      } catch (error) {
        output = ToolOutput.error('$name failed: $error');
      }
    }

    writer.send(
      ToolResultEvent(
        runId: runId,
        toolCallId: call.id,
        toolName: name,
        result: output.content,
        isError: output.isError,
        durationMs: stopwatch.elapsedMilliseconds,
      ),
    );
    for (final artifact in output.artifacts) {
      writer.send(
        AgentArtifactEvent(
          runId: runId,
          artifact: artifact,
          toolCallId: call.id,
        ),
      );
    }

    return Message(
      role: RoleType.tool,
      content: output.isError ? 'Error: ${output.content}' : output.content,
      toolCallId: call.id,
      toolName: name,
      extra: {
        if (output.isError) 'is_error': true,
        if (output.data != null) 'data': output.data,
        if (output.artifacts.isNotEmpty)
          'artifacts': output.artifacts.map((a) => a.toJson()).toList(),
      },
    );
  }

  Future<bool> _approved(
    ToolCall call,
    String reason,
    StreamWriter<AgentEvent> writer,
    AgentRunScope ctx,
  ) async {
    writer.send(
      AgentApprovalRequestEvent(
        runId: ctx.runId,
        toolCall: call,
        reason: reason,
      ),
    );
    final request = ctx.requestApproval;
    if (request == null) return false;
    final decision = await Future.any<bool>([
      request(call, reason),
      ctx.cancelToken.whenCancelled.then((_) => false),
    ]);
    return decision && !ctx.cancelToken.isCancelled;
  }
}
