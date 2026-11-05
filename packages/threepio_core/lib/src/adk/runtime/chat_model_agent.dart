import 'dart:async';

import '../../components/model/base_chat_model.dart';
import '../../components/model/cancel_token.dart';
import '../../components/model/chat_model_options.dart';
import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_event.dart' as eino;
import '../eino/chat_model_agent.dart' as eino;
import '../eino/react_graph.dart' as eino;
import '../eino/chat_model_agent_config.dart' as eino;
import '../eino/event_senders.dart' as eino;
import '../eino/run_options.dart' as eino;
import '../eino/runner.dart' as eino;
import '../events/agent_event.dart' hide TokenUsage;
import 'agent_handler.dart';
import 'approval_middleware.dart';
import 'event_mapper.dart';
import 'legacy_handler_middleware.dart';
import 'legacy_run.dart';
import 'tool_call_context.dart';
import 'tool_timeout_middleware.dart';

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
///
/// Since 0.9 the loop runs on the Eino-shaped engine of
/// `package:threepio_core/adk.dart` (its `ChatModelAgent` and `Runner`): the
/// handlers, the approval and the tool timeout are middlewares of that
/// agent, and its events are mapped to the events of this runtime. The
/// events, their order and the messages the model is sent are those of
/// earlier releases.
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
      _run(messages, writer, ctx).then(
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

  Future<void> _run(
    List<Message> input,
    StreamWriter<AgentEvent> writer,
    AgentRunScope scope,
  ) async {
    final toolInfos = <ToolInfo>[];
    final tools = <BaseTool>[];
    for (final tool in config.tools) {
      final info = await tool.info();
      toolInfos.add(info);
      tools.add(_LegacyTool(tool, info));
    }

    final run = LegacyRun(
      scope: scope,
      config: config,
      state: ChatModelAgentState(
        messages: [
          if (config.instruction != null) Message.system(config.instruction!),
          ...input,
        ],
        toolInfos: toolInfos,
        instruction: config.instruction,
      ),
    );
    final mapper = LegacyEventMapper(run: run, writer: writer, input: input)
      ..start();
    if (config.maxIterations <= 0) {
      // The legacy loop ran no iteration; the engine would take the default.
      await mapper.map(
        StreamReader.fromIterable([
          eino.AgentEvent(error: const eino.ExceedMaxIterationsException()),
        ]),
      );
      return;
    }

    final agent = eino.ChatModelAgent(
      eino.ChatModelAgentConfig(
        name: config.name,
        description: config.description,
        instruction: config.instruction ?? '',
        model: config.model,
        maxIterations: config.maxIterations,
        toolsConfig: eino.ToolsConfig(
          toolsNode: ToolsNodeConfig(
            tools: tools,
            executeSequentially: !config.parallelToolExecution,
            unknownToolsHandler: legacyUnknownTool,
          ),
        ),
        handlers: [
          const LegacyTurnMiddleware(),
          ApprovalMiddleware(config.approvalPolicy),
          ToolTimeoutMiddleware(config.toolTimeout),
          for (final handler in config.handlers) LegacyHandlerMiddleware(handler),
          const LegacyTurnEndMiddleware(),
          // Innermost: the model events carry every chunk as the model
          // streamed it, before the legacy assembly.
          const eino.EventSenderModelWrapper(),
        ],
      ),
    );
    final options = (config.modelOptions ?? const ChatModelOptions())
        .copyWith(cancelToken: scope.cancelToken);
    final events = eino.Runner(agent: agent, enableStreaming: true).run(
      withLegacyRun(RunContext.background(cancelToken: scope.cancelToken), run),
      input,
      options: [eino.AgentRunOption.chatModelOptions(options)],
    );
    await mapper.map(events);
  }
}

/// A tool of the legacy configuration as a tool of the engine: it runs the
/// tool with the [ToolCallContext] of the call (or, for a plain
/// [InvokableTool], through `invokableRun`) and hands the [ToolOutput] to
/// the facade's middlewares.
final class _LegacyTool extends InvokableTool {
  _LegacyTool(this.tool, this._info);

  final BaseTool tool;
  final ToolInfo _info;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final run = legacyRunOf(ctx)!;
    final name = _info.function.name;
    final call = run.toolCallFor(toolCallIdOf(ctx) ?? '', name, argumentsJson);
    final context = run.contextFor(call);
    final tool = this.tool;
    final ToolOutput output;
    if (tool is ContextualTool) {
      output = await tool.runWithContext(context, argumentsJson);
    } else if (tool is InvokableTool) {
      // `invokableRun` reaches every tool: one that only overrides the
      // older `run` is called through its default implementation.
      final toolContext = RunContext.background(cancelToken: context.cancelToken);
      output = ToolOutput(content: await tool.invokableRun(toolContext, argumentsJson));
    } else {
      output = ToolOutput.error('Tool $name cannot be invoked');
    }
    run.setOutput(call.id, output);
    return legacyToolContent(output);
  }
}
