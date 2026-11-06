/// An agentic agent as a tool of another agent.
///
/// Port of eino `adk.NewTypedAgentTool[*schema.AgenticMessage]`
/// (`adk/agent_tool.go`). **Beta**.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/resume.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_tool.dart'
    show
        AgentToolRunOptions,
        AgentToolStreaming,
        agentToolRequestOf,
        defaultAgentToolParams;
import '../eino/cancel.dart';
import '../eino/interrupt.dart';
import '../eino/run_options.dart';
import 'agent_message_codec.dart';
import 'agentic_agent.dart';
import 'agentic_runner.dart';

/// A tool that runs the agentic agent [agent]: the model of another agent
/// (classic or agentic) calls it like any tool and gets the text of the
/// agent's last message as the result.
///
/// Port of eino `adk.NewTypedAgentTool[*schema.AgenticMessage]`. The agent
/// gets a fresh conversation: one user message with the `request` argument,
/// or with [inputSchema] the raw arguments. (Eino's
/// `WithFullChatHistoryAsInput` is refused for agentic agents, so it is not
/// offered here.) The agent shares the caller's session values. When the
/// caller is an `AgenticChatModelAgent` with `ToolsConfig.emitInternalEvents`
/// its events reach the caller's caller as they happen. An interrupt of the
/// agent interrupts the caller, and resuming the caller resumes the agent.
/// The result is the agent's assistant text (eino `extractTextContent`:
/// the `AssistantGenText` blocks joined with newlines).
final class AgenticAgentTool extends InvokableTool {
  /// A tool that runs [agent]. The agent needs a non-empty name and
  /// description, which become the tool's.
  AgenticAgentTool(this.agent, {this.inputSchema});

  /// The agent the tool runs.
  final AgenticAgent agent;

  /// The parameters of the tool; the arguments become the agent's user
  /// message as they are. Port of eino `adk.WithAgentInputSchema`.
  final ParamsOneOf? inputSchema;

  @override
  Future<ToolInfo> info() async {
    final name = agent.name;
    if (name.isEmpty) {
      throw const ThreepioException('agent tool requires a non-empty Name');
    }
    final description = agent.description;
    if (description.isEmpty) {
      throw const ThreepioException(
        'agent tool requires a non-empty Description',
      );
    }
    return ToolInfo.fromParamsOneOf(
      name: name,
      desc: description,
      params: inputSchema ?? defaultAgentToolParams,
    );
  }

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    // A recursive cancel of the caller waits for this agent's interrupt.
    cancelContextOf(ctx)?.markCheckpointAwareDescendant();
    final sink = options?.extension<AgenticAgentToolEventSink>();
    final streaming = options?.extension<AgentToolStreaming>() != null;
    final ownOptions = [
      for (final extension in options?.extensions ?? const <Object>[])
        if (extension is AgentToolRunOptions && extension.agentName == agent.name)
          ...extension.options,
    ];
    // Port of eino `extractAndDeriveAgentToolCancelCtx`.
    final childCancel = deriveCheckpointAwareSubAgentCancelContext(
      ctx,
      ownOptions,
    );
    final agentOptions = appendCancelContextOption(ownOptions, childCancel);
    try {
      return await _run(ctx, argumentsJson, sink, streaming, agentOptions);
    } finally {
      // The agent's run marks it done; this covers a failure before the run.
      childCancel?.markDone();
    }
  }

  Future<String> _run(
    RunContext ctx,
    String argumentsJson,
    AgenticAgentToolEventSink? sink,
    bool streaming,
    List<AgentRunOption> agentOptions,
  ) async {
    final BridgeStore store;
    final StreamReader<AgenticAgentEvent> reader;
    final interrupted = getInterruptState<String>(ctx);
    if (!interrupted.wasInterrupted) {
      store = BridgeStore();
      final text =
          inputSchema == null ? agentToolRequestOf(argumentsJson) : argumentsJson;
      reader = AgenticRunner(
        agent: agent,
        enableStreaming: streaming,
        checkpointStore: store,
      ).run(
        ctx,
        [agenticMessageCodec.user(text)],
        options: [
          ...agentOptions,
          AgentRunOption.checkpointId(bridgeCheckpointId),
          sharedParentSessionOption(),
        ],
      );
    } else {
      final state = interrupted.state;
      if (!interrupted.hasState || state == null) {
        throw ThreepioException(
          "agent tool '${agent.name}' interrupt has happened, but cannot find "
          'interrupt state',
        );
      }
      store = BridgeStore.resume(bridgeCheckpointId, base64Decode(state));
      reader = await AgenticRunner(
        agent: agent,
        enableStreaming: streaming,
        checkpointStore: store,
      ).resume(
        ctx,
        bridgeCheckpointId,
        options: [...agentOptions, sharedParentSessionOption()],
      );
    }

    AgenticAgentEvent? last;
    for (var event = await reader.nextOrNull();
        event != null;
        event = await reader.nextOrNull()) {
      final previousStream = last?.output?.messageOutput?.messageStream;
      if (previousStream != null) await previousStream.close();
      final error = event.error;
      if (error != null) {
        await reader.close();
        Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
      }
      var kept = event;
      if (sink != null && event.action?.interrupted == null) {
        kept = copyAgenticAgentEvent(event);
        sink.writer.send(event);
      }
      last = kept;
    }

    final signal = last?.action?.interruptSignal;
    if (last?.action?.interrupted != null && signal == null) {
      throw ThreepioException(
        "agent tool '${agent.name}': the agent interrupted without an "
        'interrupt signal (build interrupt events with agenticInterruptEvent '
        'and its relatives, and add data with AgentAction.withInterruptData)',
      );
    }
    if (last?.action?.interrupted != null && signal != null) {
      final data = await store.get(bridgeCheckpointId);
      if (data == null) {
        throw const ThreepioException(
          'interrupt has happened, but cannot find interrupt info',
        );
      }
      throw compositeInterrupt(
        ctx,
        'agent tool interrupt',
        base64Encode(data),
        [signal],
      );
    }
    if (last == null) throw const ThreepioException('no event returned');
    final output = last.output?.messageOutput;
    if (output == null) return '';
    return agenticMessageCodec.textContent(await output.getMessage());
  }

  @override
  String toString() => 'AgenticAgentTool(${agent.name})';
}

/// Where the events of the agentic agents behind agentic agent tools go
/// when the calling agentic agent passes them on
/// (`ToolsConfig.emitInternalEvents`). Port of eino
/// `typedAgentToolEventOptions[*schema.AgenticMessage]`.
@internal
final class AgenticAgentToolEventSink {
  /// A sink that writes to [writer].
  const AgenticAgentToolEventSink(this.writer);

  final StreamWriter<AgenticAgentEvent> writer;
}
