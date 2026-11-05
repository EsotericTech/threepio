/// What the hooks of a `ChatModelAgentMiddleware` see.
///
/// Port of the context types of eino `adk/handler.go` and of
/// `ChatModelAgentState` in `adk/chatmodel.go`.
library;

import 'package:meta/meta.dart';

import '../../components/tool/invokable_tool.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import 'model_failover.dart';
import 'model_retry.dart';

/// The setup of one `ChatModelAgent` run, which `beforeAgent` may change.
///
/// Port of eino `adk.ChatModelAgentContext`. Mutable on purpose: a
/// middleware changes the fields and returns the object.
final class ChatModelAgentContext {
  /// The setup of a run.
  ChatModelAgentContext({
    required this.instruction,
    required List<BaseTool> tools,
    required Set<String> returnDirectly,
    this.toolSearchTool,
  })  : tools = List.of(tools),
        returnDirectly = Set.of(returnDirectly);

  /// The system instruction of the run.
  String instruction;

  /// The tools the run can call. Changing the list changes both what the
  /// model is told and what can be executed, for the whole run.
  List<BaseTool> tools;

  /// The names of the tools whose result ends the run.
  Set<String> returnDirectly;

  /// The tool-search tool for a model with native tool search.
  ToolInfo? toolSearchTool;
}

/// The conversation of a `ChatModelAgent` around a model call.
///
/// Port of eino `adk.ChatModelAgentState`. Mutable on purpose: the
/// `beforeModelRewriteState` and `afterModelRewriteState` hooks change it,
/// and what they leave is kept in the agent's state.
final class ChatModelAgentState {
  /// A state with [messages].
  ChatModelAgentState({
    required List<Message> messages,
    List<ToolInfo> toolInfos = const [],
    List<ToolInfo>? deferredToolInfos,
  })  : messages = List.of(messages),
        toolInfos = List.of(toolInfos),
        deferredToolInfos =
            deferredToolInfos == null ? null : List.of(deferredToolInfos);

  /// The whole conversation, sent to the model on the next call.
  List<Message> messages;

  /// The tools the model is told about. Changes are kept for later calls.
  List<ToolInfo> toolInfos;

  /// Tools the model can look up on the server side
  /// (`ChatModelOptions.deferredTools`); `null` when not used.
  List<ToolInfo>? deferredToolInfos;
}

/// What a model hook knows about the model call.
///
/// Port of eino `adk.ModelContext`. Its deprecated `Tools` field is not
/// ported: use [ChatModelAgentState.toolInfos].
@immutable
final class ModelContext {
  /// The context of a model call.
  const ModelContext({this.modelRetryConfig, this.modelFailoverConfig});

  /// The retry policy of the agent's model, if any.
  final ModelRetryConfig? modelRetryConfig;

  /// The failover policy of the agent's model, if any.
  final ModelFailoverConfig? modelFailoverConfig;
}

/// The tool call a tool wrapper wraps. Port of eino `adk.ToolContext`.
@immutable
final class ToolContext {
  /// The call [callId] of the tool [name].
  const ToolContext({required this.name, required this.callId});

  /// The name of the tool.
  final String name;

  /// The id of the tool call.
  final String callId;

  @override
  bool operator ==(Object other) =>
      other is ToolContext && other.name == name && other.callId == callId;

  @override
  int get hashCode => Object.hash(name, callId);

  @override
  String toString() => 'ToolContext($name, $callId)';
}
