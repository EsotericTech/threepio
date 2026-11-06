/// An agent as a tool of another agent.
///
/// Port of eino `adk.NewAgentTool` (`adk/agent_tool.go`).
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/local_state.dart';
import '../../compose/resume.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import 'agent.dart';
import 'agent_event.dart';
import 'cancel.dart';
import 'interrupt.dart';
import 'language.dart';
import 'react_graph.dart';
import 'run_options.dart';
import 'runner.dart';

const _uuid = Uuid();

/// The parameters of an agent tool without an input schema. Port of eino
/// `defaultAgentToolParam`.
const ParamsOneOf _defaultAgentToolParams = ParamsOneOf.params({
  'request': ParameterInfo(
    type: DataType.string,
    desc: 'request to be processed',
    required: true,
  ),
});

/// A tool that runs [agent]: the model of another agent calls it like any
/// tool, and gets the agent's last message as the result.
///
/// Port of eino `adk.NewAgentTool`. This is how agents work together in the
/// ADK (eino recommends it over agent transfer):
///
/// ```dart
/// final researcher = ChatModelAgent(ChatModelAgentConfig(
///   name: 'researcher', description: 'Finds facts', model: model));
/// final lead = ChatModelAgent(ChatModelAgentConfig(
///   name: 'lead', description: 'Plans', model: model,
///   toolsConfig: ToolsConfig(
///     toolsNode: ToolsNodeConfig(tools: [AgentTool(researcher)]),
///     emitInternalEvents: true,
///   )));
/// ```
///
/// The agent gets a fresh conversation: by default one user message with the
/// `request` argument; with [inputSchema] the raw arguments; with
/// [fullChatHistoryAsInput] the caller's conversation so far. It shares the
/// caller's session values. With `ToolsConfig.emitInternalEvents` on the
/// caller its events reach the caller's caller as they happen. An interrupt
/// of the agent interrupts the caller, and resuming the caller resumes the
/// agent.
///
/// This is the Eino-shaped `AgentTool` of `package:threepio_core/adk.dart`;
/// the umbrella library exports an unrelated, older `AgentTool` that wraps a
/// legacy `BaseAgent`.
final class AgentTool extends InvokableTool {
  /// A tool that runs [agent]. The agent needs a non-empty name and
  /// description, which become the tool's.
  AgentTool(
    this.agent, {
    this.fullChatHistoryAsInput = false,
    this.inputSchema,
  });

  /// The agent the tool runs.
  final Agent agent;

  /// Whether the agent gets the caller's conversation instead of a request.
  /// Port of eino `adk.WithFullChatHistoryAsInput`.
  final bool fullChatHistoryAsInput;

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
    final params = inputSchema ?? _defaultAgentToolParams;
    return ToolInfo.fromParamsOneOf(
      name: name,
      desc: description,
      params: params,
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
    final sink = options?.extension<AgentToolEventSink>();
    final streaming = options?.extension<AgentToolStreaming>() != null;
    final ownOptions = [
      for (final extension in options?.extensions ?? const <Object>[])
        if (extension is AgentToolRunOptions && extension.agentName == agent.name)
          ...extension.options,
    ];
    // Port of eino `extractAndDeriveAgentToolCancelCtx`: the agent's run gets
    // a cancel context of its own that obeys the caller's recursive cancels.
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
    AgentToolEventSink? sink,
    bool streaming,
    List<AgentRunOption> agentOptions,
  ) async {

    final BridgeStore store;
    final Future<StreamReader<AgentEvent>> events;
    final interrupted = getInterruptState<String>(ctx);
    if (!interrupted.wasInterrupted) {
      store = BridgeStore();
      final List<Message> input;
      if (fullChatHistoryAsInput) {
        input = await _reactChatHistory(ctx, agent.name);
      } else if (inputSchema == null) {
        input = [Message.user(_requestOf(argumentsJson))];
      } else {
        input = [Message.user(argumentsJson)];
      }
      events = Future.value(
        Runner(agent: agent, enableStreaming: streaming, checkpointStore: store)
            .run(
          ctx,
          input,
          options: [
            ...agentOptions,
            AgentRunOption.checkpointId(bridgeCheckpointId),
            sharedParentSessionOption(),
          ],
        ),
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
      events =
          Runner(agent: agent, enableStreaming: streaming, checkpointStore: store)
              .resume(
        ctx,
        bridgeCheckpointId,
        options: [...agentOptions, sharedParentSessionOption()],
      );
    }

    AgentEvent? last;
    final reader = await events;
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
        kept = copyAgentEvent(event);
        sink.writer.send(event);
      }
      last = kept;
    }

    final signal = last?.action?.interruptSignal;
    if (last?.action?.interrupted != null && signal == null) {
      throw ThreepioException(
        "agent tool '${agent.name}': the agent interrupted without an "
        'interrupt signal (build interrupt events with interruptEvent and '
        'its relatives, and add data with AgentAction.withInterruptData)',
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
    return (await output.getMessage()).content;
  }

  static String _requestOf(String argumentsJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(argumentsJson);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'agent tool arguments are not JSON: ${error.message}',
        cause: error,
      );
    }
    if (decoded is! Map) {
      throw ThreepioFormatException(
        'agent tool arguments must be a JSON object, got $argumentsJson',
      );
    }
    final request = decoded['request'];
    if (request == null) return '';
    if (request is! String) {
      throw ThreepioFormatException(
        'agent tool argument "request" must be a string, got $request',
      );
    }
    return request;
  }

  @override
  String toString() => 'AgentTool(${agent.name})';
}

/// The conversation of the calling agent, rewritten for the agent behind the
/// tool. Port of eino `getReactChatHistory`.
Future<List<Message>> _reactChatHistory(
  RunContext ctx,
  String destinationAgent,
) async {
  var messages = <Message>[];
  var agentName = '';
  try {
    await processState<ReactState>(ctx, (_, state) {
      agentName = state.agentName;
      if (state.messages.isEmpty) return;
      messages = state.messages.sublist(0, state.messages.length - 1);
    });
    // Outside a ChatModelAgent there is no history to read.
    // ignore: avoid_catching_errors
  } on StateError catch (error) {
    throw ThreepioException(
      'failed to get chat history from state: ${error.message}',
      cause: error,
    );
  }
  final (assistant, tool) = _transferMessages(destinationAgent);
  return [
    for (final message in [...messages, assistant, tool])
      if (message.role != RoleType.system)
        message.role == RoleType.assistant || message.role == RoleType.tool
            ? _rewriteMessage(message, agentName)
            : message,
  ];
}

const _transferToolName = 'transfer_to_agent';

/// Port of eino `GenTransferMessages` (kept private: agent transfer is not
/// ported, only the history an agent tool builds with it).
(Message, Message) _transferMessages(String destination) {
  final callId = _uuid.v4();
  final assistant = Message.assistant(
    '',
    toolCalls: [
      ToolCall(
        id: callId,
        function: FunctionCall(name: _transferToolName, arguments: destination),
      ),
    ],
  );
  final output = selectPrompt(
    const I18nPrompts(
      english: 'successfully transferred to agent [%s]',
      chinese: '成功移交任务至 agent [%s]',
    ),
  ).replaceFirst('%s', destination);
  return (
    assistant,
    Message.tool(content: output, toolCallId: callId, toolName: _transferToolName),
  );
}

/// What another agent's message is turned into for this agent. Port of eino
/// `rewriteMessage`.
Message _rewriteMessage(Message message, String agentName) {
  final text = StringBuffer('For context:');
  if (message.role == RoleType.assistant) {
    if (message.content.isNotEmpty) {
      text.write(' [$agentName] said: ${message.content}.');
    }
    for (final call in message.toolCalls ?? const <ToolCall>[]) {
      text.write(
        ' [$agentName] called tool: `${call.function.name}` with arguments: '
        '${call.function.arguments}.',
      );
    }
  } else if (message.role == RoleType.tool && message.content.isNotEmpty) {
    text.write(
      ' [$agentName] `${message.toolName ?? ''}` tool returned result: '
      '${message.content}.',
    );
  }
  final parts = <MessageInputPart>[...?message.userInputMultiContent];
  for (final part in message.assistantGenMultiContent ?? const <MessageOutputPart>[]) {
    final converted = _inputPartOf(part);
    if (converted != null) parts.add(converted);
  }
  return Message.user(text.toString()).copyWith(
    userInputMultiContent:
        message.userInputMultiContent == null && parts.isEmpty ? null : parts,
  );
}

/// [part] of an assistant message as a part of a user message: text and
/// media are kept, reasoning is dropped. Part of eino `rewriteMessage`.
MessageInputPart? _inputPartOf(MessageOutputPart part) => switch (part.type) {
      ChatMessagePartType.text =>
        MessageInputPart(type: part.type, text: part.text, extra: part.extra),
      ChatMessagePartType.imageUrl when part.image != null => MessageInputPart(
          type: part.type,
          image: MessageInputImage(common: part.image!),
          extra: part.extra,
        ),
      ChatMessagePartType.audioUrl when part.audio != null => MessageInputPart(
          type: part.type,
          audio: MessageInputAudio(common: part.audio!),
          extra: part.extra,
        ),
      ChatMessagePartType.videoUrl when part.video != null => MessageInputPart(
          type: part.type,
          video: MessageInputVideo(common: part.video!),
          extra: part.extra,
        ),
      _ => null,
    };

/// Where the events of the agents behind agent tools go when the calling
/// agent passes them on (`ToolsConfig.emitInternalEvents`). Port of eino
/// `typedAgentToolEventOptions`.
@internal
final class AgentToolEventSink {
  /// A sink that writes to [writer].
  const AgentToolEventSink(this.writer);

  final StreamWriter<AgentEvent> writer;
}

/// Marks a streaming run: the agents behind agent tools stream too. Port of
/// eino `withAgentToolEnableStreaming`.
@internal
final class AgentToolStreaming {
  /// The marker.
  const AgentToolStreaming();
}

/// Run options for the agent behind the agent tool [agentName]. Port of eino
/// `withAgentToolOptions`.
@internal
final class AgentToolRunOptions {
  /// The options of [agentName].
  const AgentToolRunOptions(this.agentName, this.options);

  final String agentName;
  final List<AgentRunOption> options;
}
