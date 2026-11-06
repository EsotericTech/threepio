/// The graph an `AgenticChatModelAgent` with tools runs: the agentic model,
/// then its function tool calls, then the model again, until the model
/// answers without function tool calls.
///
/// Port of the agentic half of eino `adk/react.go` (`agenticState`,
/// `agenticReactInput`, `agenticReactConfig`, `newAgenticReact`,
/// `getAgenticReturnDirectlyToolCallID`, `genAgenticReactState`). The node
/// names, the topology and the safe points are those of the classic graph
/// (`ReactNodes`); message-specific steps go through [agenticMessageCodec].
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/model/agentic_model.dart';
import '../../compose/agentic_tools_node.dart';
import '../../compose/graph.dart';
import '../../compose/graph_branch.dart';
import '../../compose/graph_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/lambda.dart';
import '../../compose/local_state.dart';
import '../../compose/resume.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/agentic_message.dart';
import '../../schema/tool_info.dart';
import '../../schema/type_registry.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_action.dart';
import '../eino/agent_context.dart';
import '../eino/cancel.dart';
import '../eino/react_graph.dart' show ExceedMaxIterationsException, ReactNodes;
import 'agent_message_codec.dart';
import 'agentic_agent.dart';
import 'agentic_context.dart';
import 'agentic_wrappers.dart';

/// The state of one `AgenticChatModelAgent` run.
///
/// Port of eino's internal `agenticState` (`typedState[*schema.
/// AgenticMessage]`, registered as `_eino_adk_agentic_state`). Mutable;
/// reached through `processState<AgenticReactState>`. Its fields are those
/// of the classic `ReactState`, with agentic messages and events.
@internal
final class AgenticReactState implements RunLocalValueHolder {
  /// The state at the start of a run of the agent [agentName].
  AgenticReactState({this.agentName = '', this.remainingIterations = 20});

  /// A state from its JSON form; see [toJson].
  factory AgenticReactState.fromJson(Map<String, Object?> json) =>
      AgenticReactState(
        agentName: json['agent_name'] as String? ?? '',
        remainingIterations:
            (json['remaining_iterations'] as num?)?.toInt() ?? 0,
      )
        ..messages = [
          for (final message in (json['messages'] as List<Object?>?) ?? const [])
            agenticMessageCodec.decode((message! as Map).cast<String, Object?>()),
        ]
        ..extra = switch (json['extra']) {
          final Map<String, Object?> extra => {
              for (final MapEntry(:key, :value) in extra.entries)
                key: TypeRegistry.decode(value),
            },
          _ => null,
        }
        ..toolInfos = _toolInfos(json['tool_infos'])
        ..deferredToolInfos = _toolInfos(json['deferred_tool_infos'])
        ..returnDirectlyToolCallId =
            json['return_directly_tool_call_id'] as String? ?? ''
        ..toolGenActions = switch (json['tool_gen_actions']) {
          final Map<String, Object?> actions => {
              for (final MapEntry(:key, :value) in actions.entries)
                key: AgentAction.fromJson(value! as Map<String, Object?>),
            },
          _ => null,
        }
        ..returnDirectlyEvent = switch (json['return_directly_event']) {
          final Map<String, Object?> event => AgenticAgentEvent.fromJson(event),
          _ => null,
        }
        ..retryAttempt = (json['retry_attempt'] as num?)?.toInt() ?? 0
        ..toolMsgIds = switch (json['tool_msg_ids']) {
          final Map<String, Object?> ids => {
              for (final MapEntry(:key, :value) in ids.entries)
                key: (value! as Map).cast<String, String>(),
            },
          _ => null,
        };

  static List<ToolInfo>? _toolInfos(Object? json) => switch (json) {
        final List<Object?> infos => [
            for (final info in infos)
              ToolInfo.fromJson((info! as Map).cast<String, dynamic>()),
          ],
        _ => null,
      };

  /// The conversation of the run.
  List<AgenticMessage> messages = [];

  /// The run-local values (`AgentContext.setRunLocalValue`).
  @override
  Map<String, Object?>? extra;

  /// The tools the model is told about; `null` until the first model call.
  List<ToolInfo>? toolInfos;

  /// The tools of the model's server-side tool search.
  List<ToolInfo>? deferredToolInfos;

  /// The call of a `returnDirectly` tool in the current turn, or `''`.
  String returnDirectlyToolCallId = '';

  /// Whether a `returnDirectly` tool was called in the current turn.
  bool get hasReturnDirectly => returnDirectlyToolCallId.isNotEmpty;

  /// Actions kept for the tool events, by call id or tool name.
  Map<String, AgentAction>? toolGenActions;

  /// The agent the state belongs to.
  String agentName;

  /// Model calls left before `maxIterations` is reached.
  int remainingIterations;

  /// The event of the `returnDirectly` tool, sent once the tools node is
  /// done.
  AgenticAgentEvent? returnDirectlyEvent;

  /// The attempt of the model call in progress, from 0 (kept for the shape
  /// of eino's state; retry is not built for agentic models).
  int retryAttempt = 0;

  /// The ids of the tool events, by tool name and call id, so that the tool
  /// messages in the state get the ids of their events.
  Map<String, Map<String, String>>? toolMsgIds;

  /// Keeps [action] for the tool event of [key].
  void setToolGenAction(String key, AgentAction action) =>
      (toolGenActions ??= {})[key] = action;

  /// Takes the action kept for [key].
  AgentAction? popToolGenAction(String key) => toolGenActions?.remove(key);

  /// Notes the id [id] of the event of the call [callId] of [toolName].
  void setToolMsgId(String toolName, String callId, String id) =>
      ((toolMsgIds ??= {})[toolName] ??= {})[callId] = id;

  /// Takes the id noted for the call [callId] of [toolName], or `''`.
  String popToolMsgId(String toolName, String callId) {
    final byCall = toolMsgIds?[toolName];
    if (byCall == null) return '';
    final id = byCall.remove(callId) ?? '';
    if (byCall.isEmpty) toolMsgIds!.remove(toolName);
    return id;
  }

  /// The JSON form, as a checkpoint keeps it.
  Map<String, Object?> toJson() => {
        'messages': [
          for (final message in messages) agenticMessageCodec.encode(message),
        ],
        if (extra != null)
          'extra': {
            for (final MapEntry(:key, :value) in extra!.entries)
              key: TypeRegistry.encode(value),
          },
        if (toolInfos != null)
          'tool_infos': [for (final info in toolInfos!) info.toJson()],
        if (deferredToolInfos != null)
          'deferred_tool_infos': [
            for (final info in deferredToolInfos!) info.toJson(),
          ],
        if (returnDirectlyToolCallId.isNotEmpty)
          'return_directly_tool_call_id': returnDirectlyToolCallId,
        if (toolGenActions != null)
          'tool_gen_actions': {
            for (final MapEntry(:key, :value) in toolGenActions!.entries)
              key: value.toJson(),
          },
        'agent_name': agentName,
        'remaining_iterations': remainingIterations,
        if (returnDirectlyEvent != null)
          'return_directly_event': returnDirectlyEvent!.toJson(),
        if (retryAttempt != 0) 'retry_attempt': retryAttempt,
        if (toolMsgIds != null) 'tool_msg_ids': toolMsgIds,
      };
}

/// The input of the agentic ReAct graph. Port of eino `agenticReactInput`
/// (registered as `_eino_adk_agentic_react_input`).
@internal
@immutable
final class AgenticReactInput {
  /// The messages the model starts with.
  AgenticReactInput(List<AgenticMessage> messages)
      : messages = List.unmodifiable(messages);

  /// An input from its JSON form.
  factory AgenticReactInput.fromJson(Map<String, Object?> json) =>
      AgenticReactInput([
        for (final message in (json['messages'] as List<Object?>?) ?? const [])
          agenticMessageCodec.decode((message! as Map).cast<String, Object?>()),
      ]);

  final List<AgenticMessage> messages;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'messages': [
          for (final message in messages) agenticMessageCodec.encode(message),
        ],
      };
}

/// Registers what an agentic agent writes into checkpoints, under eino's
/// names: the state, the graph input, the agent input and the event.
/// Idempotent; survives `TypeRegistry.reset()` when called again.
@internal
void registerAgenticAdkTypes() {
  if (!TypeRegistry.isRegistered<AgenticReactState>()) {
    TypeRegistry.registerName<AgenticReactState>(
      '_eino_adk_agentic_state',
      fromJson: AgenticReactState.fromJson,
      toJson: (state) => state.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<AgenticReactInput>()) {
    TypeRegistry.registerName<AgenticReactInput>(
      '_eino_adk_agentic_react_input',
      fromJson: AgenticReactInput.fromJson,
      toJson: (input) => input.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<AgenticAgentInput>()) {
    TypeRegistry.registerName<AgenticAgentInput>(
      '_eino_adk_agentic_agent_input',
      fromJson: AgenticAgentInput.fromJson,
      toJson: (input) => input.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<AgenticAgentEvent>()) {
    TypeRegistry.registerName<AgenticAgentEvent>(
      '_eino_adk_agentic_event',
      fromJson: AgenticAgentEvent.fromJson,
      toJson: (event) => event.toJson(),
    );
  }
}

/// What the agentic ReAct graph is built from. Port of eino
/// `agenticReactConfig`.
@internal
final class AgenticReactConfig {
  /// The configuration of an agentic ReAct graph.
  AgenticReactConfig({
    required this.model,
    required this.toolsConfig,
    this.modelWrapperConfig,
    this.toolsReturnDirectly = const {},
    this.agentName = '',
    this.maxIterations = 0,
    this.afterAgent,
    this.cancelContext,
  });

  /// The agent's model, before the wrappers.
  final AgenticModel model;

  /// The tools and middlewares of the tools node.
  final ToolsNodeConfig toolsConfig;

  /// The wrappers around the model; without it the model is used as it is.
  final AgenticModelWrapperConfig? modelWrapperConfig;

  /// The tools whose result ends the run.
  final Set<String> toolsReturnDirectly;

  /// The name of the agent, kept in the state.
  final String agentName;

  /// Model calls before the run fails; 20 when 0.
  final int maxIterations;

  /// Called with the final answer when the run ends normally; runs as a
  /// node, so the state can be reached.
  final Future<AgenticMessage> Function(RunContext ctx, AgenticMessage message)?
      afterAgent;

  /// The cancel context of the run: the `CancelCheck` and
  /// `AfterToolCallsCancelCheck` nodes interrupt at their safe points when a
  /// cancel there is pending.
  final CancelContext? cancelContext;
}

/// Builds the agentic ReAct graph. Port of eino `newAgenticReact`.
@internal
Future<Graph<AgenticReactInput?, AgenticMessage>> newAgenticReactGraph(
  RunContext ctx,
  AgenticReactConfig config,
) async {
  registerAgenticAdkTypes();
  const codec = agenticMessageCodec;
  final maxIterations = config.maxIterations > 0 ? config.maxIterations : 20;
  final graph = Graph<AgenticReactInput?, AgenticMessage>(
    localState: LocalState.of<AgenticReactState>(
      (_) => AgenticReactState(
        agentName: config.agentName,
        remainingIterations: maxIterations,
      ),
    ),
  );

  graph.addLambdaNode(
    ReactNodes.init,
    Lambda.invokable((RunContext ctx, AgenticReactInput? input) async {
      if (input == null) {
        throw const ThreepioException('agentic react: init input is nil');
      }
      await processState<AgenticReactState>(
        ctx,
        (_, state) => state.messages.addAll(input.messages),
      );
      return input.messages;
    }),
    options: const NodeOptions(name: ReactNodes.init),
  );

  final wrapperConfig = config.modelWrapperConfig;
  final model = wrapperConfig == null
      ? config.model
      : buildAgenticModelWrappers(config.model, wrapperConfig);
  final toolsNode = await AgenticToolsNode.create(config.toolsConfig, ctx: ctx);

  graph.addAgenticModelNode(
    ReactNodes.chatModel,
    model,
    options: NodeOptions(
      name: ReactNodes.chatModel,
      statePreHandler: StateHandler.pre<List<AgenticMessage>, AgenticReactState>(
        (ctx, input, state) {
          if (state.remainingIterations <= 0) {
            throw const ExceedMaxIterationsException();
          }
          state.remainingIterations--;
          return input;
        },
      ),
    ),
  );

  // The safe point after the model call, on the way to the tools: a pending
  // cancel at `afterChatModel` interrupts here, keeping the model's message.
  final cancelContext = config.cancelContext;
  graph.addLambdaNode(
    ReactNodes.cancelCheck,
    Lambda.invokable((RunContext ctx, AgenticMessage message) {
      if (cancelContext != null &&
          cancelContext.shouldCancel &&
          cancelContext.mode.contains(CancelSafePoint.afterChatModel)) {
        throw statefulInterrupt(ctx, 'CancelAfterChatModel', message);
      }
      final saved = getInterruptState<AgenticMessage>(ctx);
      return saved.wasInterrupted && saved.hasState ? saved.state! : message;
    }),
    options: const NodeOptions(name: ReactNodes.cancelCheck),
  );

  graph.addAgenticToolsNode(
    ReactNodes.toolNode,
    toolsNode,
    options: NodeOptions(
      name: ReactNodes.toolNode,
      // As in the classic graph: eino's handler ignores its input and reads
      // the last message of the state; taking the stream (and leaving it
      // unread) makes it work also when the node runs again after an
      // interrupt out of its output stream.
      streamStatePreHandler:
          StateHandler.streamPre<AgenticMessage, AgenticReactState>(
        (ctx, ignored, state) async {
          await ignored.close();
          final input = state.messages.last;
          final runtime = agenticExecContextOf(ctx)?.runtimeReturnDirectly;
          final returnDirectly = runtime != null && runtime.isNotEmpty
              ? runtime
              : config.toolsReturnDirectly;
          if (returnDirectly.isNotEmpty) {
            for (final call in codec.toolCallsOf(input)) {
              if (returnDirectly.contains(call.name)) {
                state.returnDirectlyToolCallId = call.callId;
              }
            }
          }
          return StreamReader<AgenticMessage>.fromIterable([input]);
        },
      ),
      streamStatePostHandler:
          StateHandler.streamPost<List<AgenticMessage>, AgenticReactState>(
        (ctx, output, state) {
          final event = state.returnDirectlyEvent;
          if (event != null) {
            agenticExecContextOf(ctx)?.send(event);
            state.returnDirectlyEvent = null;
          }
          return output;
        },
      ),
    ),
  );

  graph.addLambdaNode(
    ReactNodes.afterToolCalls,
    Lambda.invokable((RunContext ctx, List<AgenticMessage> results) async {
      final withIds = <AgenticMessage>[];
      await processState<AgenticReactState>(ctx, (_, state) {
        for (final message in results) {
          final result = codec.toolResultOf(message);
          final id = state.popToolMsgId(result.toolName, result.callId);
          final identified = id.isNotEmpty
              ? codec.withMessageId(message, id)
              : ensureMessageIdWith(codec, message);
          withIds.add(identified);
          state.messages.add(identified);
        }
      });
      final hook = agenticExecContextOf(ctx)?.afterToolCallsHook;
      if (hook != null) await hook(ctx);
      return withIds;
    }),
    options: const NodeOptions(name: ReactNodes.afterToolCalls),
  );

  // The safe point after the tool calls.
  graph.addLambdaNode(
    ReactNodes.afterToolCallsCancelCheck,
    Lambda.invokable((RunContext ctx, List<AgenticMessage> results) {
      if (cancelContext != null &&
          cancelContext.shouldCancel &&
          cancelContext.mode.contains(CancelSafePoint.afterToolCalls)) {
        throw interrupt(ctx, 'CancelAfterToolCalls');
      }
      return results;
    }),
    options: const NodeOptions(name: ReactNodes.afterToolCallsCancelCheck),
  );

  graph
    ..addEdge(Graph.start, ReactNodes.init)
    ..addEdge(ReactNodes.init, ReactNodes.chatModel);

  var terminal = Graph.end;
  final afterAgent = config.afterAgent;
  if (afterAgent != null) {
    graph
      ..addLambdaNode(
        ReactNodes.afterAgent,
        Lambda.invokable(afterAgent),
        options: const NodeOptions(name: ReactNodes.afterAgent),
      )
      ..addEdge(ReactNodes.afterAgent, Graph.end);
    terminal = ReactNodes.afterAgent;
  }

  graph
    ..addBranch(
      ReactNodes.chatModel,
      GraphBranch.stream<AgenticMessage>(
        (ctx, stream) async {
          try {
            for (var chunk = await stream.nextOrNull();
                chunk != null;
                chunk = await stream.nextOrNull()) {
              if (codec.hasToolCalls(chunk)) return ReactNodes.cancelCheck;
            }
            return terminal;
          } finally {
            await stream.close();
          }
        },
        {terminal, ReactNodes.cancelCheck},
      ),
    )
    ..addEdge(ReactNodes.cancelCheck, ReactNodes.toolNode)
    ..addEdge(ReactNodes.toolNode, ReactNodes.afterToolCalls)
    ..addEdge(ReactNodes.afterToolCalls, ReactNodes.afterToolCallsCancelCheck);

  if (config.toolsReturnDirectly.isNotEmpty) {
    graph
      ..addLambdaNode(
        ReactNodes.toolNodeToEndConverter,
        Lambda.invokable((RunContext ctx, List<AgenticMessage> results) async {
          final id = await agenticReturnDirectlyToolCallIdOf(ctx);
          for (final message in results) {
            if (codec.toolResultOf(message).callId == id) return message;
          }
          throw const ThreepioException(
            'return directly tool call result not found',
          );
        }),
        options: const NodeOptions(name: ReactNodes.toolNodeToEndConverter),
      )
      ..addEdge(ReactNodes.toolNodeToEndConverter, terminal)
      ..addBranch(
        ReactNodes.afterToolCallsCancelCheck,
        GraphBranch.single<List<AgenticMessage>>(
          (ctx, _) async =>
              (await agenticReturnDirectlyToolCallIdOf(ctx)).isNotEmpty
                  ? ReactNodes.toolNodeToEndConverter
                  : ReactNodes.chatModel,
          {ReactNodes.toolNodeToEndConverter, ReactNodes.chatModel},
        ),
      );
  } else {
    graph.addEdge(ReactNodes.afterToolCallsCancelCheck, ReactNodes.chatModel);
  }
  return graph;
}

/// The call of the `returnDirectly` tool of the current turn, or `''`. Port
/// of eino `getAgenticReturnDirectlyToolCallID`.
@internal
Future<String> agenticReturnDirectlyToolCallIdOf(RunContext ctx) async {
  var id = '';
  try {
    await processState<AgenticReactState>(
      ctx,
      (_, state) => id = state.returnDirectlyToolCallId,
    );
    // Outside the graph there is no such call.
    // ignore: avoid_catching_errors
  } on StateError {
    return '';
  }
  return id;
}
