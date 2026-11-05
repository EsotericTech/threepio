/// The graph a `ChatModelAgent` with tools runs: the model, then its tool
/// calls, then the model again, until the model answers without tool calls.
///
/// Port of eino `adk/react.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/model/base_chat_model.dart';
import '../../compose/graph.dart';
import '../../compose/graph_branch.dart';
import '../../compose/graph_options.dart';
import '../../compose/lambda.dart';
import '../../compose/local_state.dart';
import '../../compose/resume.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../schema/type_registry.dart';
import 'agent_action.dart';
import 'agent_context.dart';
import 'agent_event.dart';
import 'event_senders.dart';
import 'message_id.dart';

/// A `ChatModelAgent` reached its `maxIterations` without a final answer.
///
/// Port of eino `adk.ErrExceedMaxIterations`.
class ExceedMaxIterationsException extends ThreepioException {
  /// The limit was reached.
  const ExceedMaxIterationsException() : super('exceeds max iterations');

  @override
  String toString() => 'ExceedMaxIterationsException: $message';
}

/// The state of one `ChatModelAgent` run.
///
/// Port of eino's internal `typedState` (exported in eino only for
/// checkpoint compatibility as the deprecated `State`; here it is internal).
/// Mutable; reached through `processState<ReactState>`.
@internal
final class ReactState {
  /// The state at the start of a run of the agent [agentName].
  ReactState({this.agentName = '', this.remainingIterations = 20});

  /// A state from its JSON form; see [toJson].
  factory ReactState.fromJson(Map<String, Object?> json) => ReactState(
        agentName: json['agent_name'] as String? ?? '',
        remainingIterations: (json['remaining_iterations'] as num?)?.toInt() ?? 0,
      )
        ..messages = [
          for (final message in (json['messages'] as List<Object?>?) ?? const [])
            Message.fromJson((message! as Map).cast<String, dynamic>()),
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
          final Map<String, Object?> event => AgentEvent.fromJson(event),
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
  List<Message> messages = [];

  /// The run-local values (`AgentContext.setRunLocalValue`).
  Map<String, Object?>? extra;

  /// The tools the model is told about; `null` until a middleware sets them.
  List<ToolInfo>? toolInfos;

  /// The tools of the model's server-side tool search.
  List<ToolInfo>? deferredToolInfos;

  /// The call of a `returnDirectly` tool in the current turn, or `''`.
  String returnDirectlyToolCallId = '';

  /// Whether a `returnDirectly` tool was called in the current turn.
  bool get hasReturnDirectly => returnDirectlyToolCallId.isNotEmpty;

  /// Actions tools left with `sendToolGenAction`, by call id or tool name.
  Map<String, AgentAction>? toolGenActions;

  /// The agent the state belongs to.
  String agentName;

  /// Model calls left before `maxIterations` is reached.
  int remainingIterations;

  /// The event of the `returnDirectly` tool, sent once the tools node is done.
  AgentEvent? returnDirectlyEvent;

  /// The attempt of the model call in progress, from 0.
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
        'messages': [for (final message in messages) message.toJson()],
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

/// The input of the ReAct graph. Port of eino `reactInput`.
@internal
@immutable
final class ReactInput {
  /// The messages the model starts with.
  ReactInput(List<Message> messages) : messages = List.unmodifiable(messages);

  /// An input from its JSON form.
  factory ReactInput.fromJson(Map<String, Object?> json) => ReactInput([
        for (final message in (json['messages'] as List<Object?>?) ?? const [])
          Message.fromJson((message! as Map).cast<String, dynamic>()),
      ]);

  final List<Message> messages;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'messages': [for (final message in messages) message.toJson()],
      };
}

/// Registers [ReactState] and [ReactInput] under eino's names. Idempotent.
@internal
void registerReactTypes() {
  if (!TypeRegistry.isRegistered<ReactState>()) {
    TypeRegistry.registerName<ReactState>(
      '_eino_adk_react_state',
      fromJson: ReactState.fromJson,
      toJson: (state) => state.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<ReactInput>()) {
    TypeRegistry.registerName<ReactInput>(
      '_eino_adk_react_input',
      fromJson: ReactInput.fromJson,
      toJson: (input) => input.toJson(),
    );
  }
}

/// What the ReAct graph is built from. Port of eino `reactConfig`.
@internal
final class ReactConfig {
  /// The configuration of a ReAct graph.
  ReactConfig({
    required this.model,
    required this.toolsConfig,
    this.modelWrapperConfig,
    this.toolsReturnDirectly = const {},
    this.agentName = '',
    this.maxIterations = 0,
    this.afterAgent,
  });

  /// The agent's model, before the wrappers.
  final BaseChatModel model;

  /// The tools and middlewares of the tools node.
  final ToolsNodeConfig toolsConfig;

  /// The wrappers around the model; without it the model is used as it is.
  final ModelWrapperConfig? modelWrapperConfig;

  /// The tools whose result ends the run.
  final Set<String> toolsReturnDirectly;

  /// The name of the agent, kept in the state.
  final String agentName;

  /// Model calls before the run fails; 20 when 0.
  final int maxIterations;

  /// Called with the final answer when the run ends normally; runs as a node,
  /// so the state can be reached.
  final Future<Message> Function(RunContext ctx, Message message)? afterAgent;

  // P7 attaches the cancel context here (eino `reactConfig.cancelCtx`): the
  // `CancelCheck` and `AfterToolCallsCancelCheck` nodes then interrupt at
  // their safe points.
}

/// The names of the nodes of the ReAct graph, as in eino.
@internal
abstract final class ReactNodes {
  static const init = 'Init';
  static const chatModel = 'ChatModel';
  static const cancelCheck = 'CancelCheck';
  static const toolNode = 'ToolNode';
  static const afterToolCalls = 'AfterToolCalls';
  static const afterToolCallsCancelCheck = 'AfterToolCallsCancelCheck';
  static const afterAgent = 'AfterAgent';
  static const toolNodeToEndConverter = 'ToolNodeToEndConverter';
}

/// Builds the ReAct graph. Port of eino `newReact`.
@internal
Future<Graph<ReactInput?, Message>> newReactGraph(
  RunContext ctx,
  ReactConfig config,
) async {
  registerReactTypes();
  final maxIterations = config.maxIterations > 0 ? config.maxIterations : 20;
  final graph = Graph<ReactInput?, Message>(
    localState: LocalState.of<ReactState>(
      (_) => ReactState(
        agentName: config.agentName,
        remainingIterations: maxIterations,
      ),
    ),
  );

  graph.addLambdaNode(
    ReactNodes.init,
    Lambda.invokable((RunContext ctx, ReactInput? input) async {
      if (input == null) {
        throw const ThreepioException('react: init input is nil');
      }
      await processState<ReactState>(
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
      : buildModelWrappers(config.model, wrapperConfig);
  final toolsNode = await ToolsNode.create(config.toolsConfig);

  graph.addChatModelNode(
    ReactNodes.chatModel,
    model,
    options: NodeOptions(
      name: ReactNodes.chatModel,
      statePreHandler: StateHandler.pre<List<Message>, ReactState>(
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

  // The safe point after the model call, on the way to the tools; P7's
  // cancel interrupts here (`CancelAfterChatModel`). After such an
  // interrupt the saved model message is used.
  graph.addLambdaNode(
    ReactNodes.cancelCheck,
    Lambda.invokable((RunContext ctx, Message message) {
      final saved = getInterruptState<Message>(ctx);
      return saved.wasInterrupted && saved.hasState ? saved.state! : message;
    }),
    options: const NodeOptions(name: ReactNodes.cancelCheck),
  );

  graph.addToolsNode(
    ReactNodes.toolNode,
    toolsNode,
    options: NodeOptions(
      name: ReactNodes.toolNode,
      statePreHandler: StateHandler.pre<Message, ReactState>(
        (ctx, _, state) {
          final input = state.messages.last;
          final runtime = execContextOf(ctx)?.runtimeReturnDirectly;
          final returnDirectly = runtime != null && runtime.isNotEmpty
              ? runtime
              : config.toolsReturnDirectly;
          if (returnDirectly.isNotEmpty) {
            for (final call in input.toolCalls ?? const <ToolCall>[]) {
              if (returnDirectly.contains(call.function.name)) {
                state.returnDirectlyToolCallId = call.id;
              }
            }
          }
          return input;
        },
      ),
      streamStatePostHandler:
          StateHandler.streamPost<List<Message>, ReactState>(
        (ctx, output, state) {
          final event = state.returnDirectlyEvent;
          if (event != null) {
            execContextOf(ctx)?.send(event);
            state.returnDirectlyEvent = null;
          }
          return output;
        },
      ),
    ),
  );

  graph.addLambdaNode(
    ReactNodes.afterToolCalls,
    Lambda.invokable((RunContext ctx, List<Message> results) async {
      final withIds = <Message>[];
      await processState<ReactState>(ctx, (_, state) {
        for (final message in results) {
          final id = state.popToolMsgId(
            message.toolName ?? '',
            message.toolCallId ?? '',
          );
          final identified = id.isNotEmpty
              ? withMessageId(message, id)
              : ensureMessageId(message);
          withIds.add(identified);
          state.messages.add(identified);
        }
      });
      final hook = execContextOf(ctx)?.afterToolCallsHook;
      if (hook != null) await hook(ctx);
      return withIds;
    }),
    options: const NodeOptions(name: ReactNodes.afterToolCalls),
  );

  // The safe point after the tool calls; P7's cancel interrupts here
  // (`CancelAfterToolCalls`).
  graph.addLambdaNode(
    ReactNodes.afterToolCallsCancelCheck,
    Lambda.invokable((RunContext ctx, List<Message> results) => results),
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
      GraphBranch.stream<Message>(
        (ctx, stream) async {
          try {
            for (var chunk = await stream.nextOrNull();
                chunk != null;
                chunk = await stream.nextOrNull()) {
              if (chunk.toolCalls?.isNotEmpty ?? false) {
                return ReactNodes.cancelCheck;
              }
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
        Lambda.invokable((RunContext ctx, List<Message> results) async {
          final id = await returnDirectlyToolCallIdOf(ctx);
          for (final message in results) {
            if (message.toolCallId == id) return message;
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
        GraphBranch.single<List<Message>>(
          (ctx, _) async => (await returnDirectlyToolCallIdOf(ctx)).isNotEmpty
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
/// of eino `getReturnDirectlyToolCallID`.
@internal
Future<String> returnDirectlyToolCallIdOf(RunContext ctx) async {
  var id = '';
  try {
    await processState<ReactState>(
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
