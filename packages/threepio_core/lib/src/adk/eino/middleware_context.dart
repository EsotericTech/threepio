/// What the hooks of a `ChatModelAgentMiddleware` see.
///
/// Port of the context types of eino `adk/handler.go` and of
/// `ChatModelAgentState` in `adk/chatmodel.go`.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../components/tool/invokable_tool.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import 'cancel.dart';
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
        toolInfos = toolInfos is UnsetToolInfos && toolInfos.isEmpty
            ? UnsetToolInfos()
            : List.of(toolInfos),
        deferredToolInfos =
            deferredToolInfos == null ? null : List.of(deferredToolInfos);

  /// The whole conversation, sent to the model on the next call.
  List<Message> messages;

  /// The tools the model is told about. Changes are kept for later calls.
  List<ToolInfo> toolInfos;

  /// Tools the model can look up on the server side
  /// (`ChatModelOptions.deferredTools`); `null` when not used.
  List<ToolInfo>? deferredToolInfos;

  /// Sets [toolInfos] to Go's nil list: the model is told about no tools on
  /// this call, and before its next call the agent fills the list with every
  /// tool again, as eino's state wrapper backfills a nil `ToolInfos`.
  /// Appending to the list (or replacing it) makes it an ordinary list.
  @internal
  void unsetToolInfos() => toolInfos = UnsetToolInfos();

  /// Whether [toolInfos] is still the nil list of [unsetToolInfos].
  @internal
  bool get hasUnsetToolInfos =>
      toolInfos is UnsetToolInfos && toolInfos.isEmpty;
}

/// The tool list of a [ChatModelAgentState] that stands for Go's nil
/// `ToolInfos` (see [ChatModelAgentState.unsetToolInfos]). It is an empty,
/// growable list; a state built from it gets a nil list of its own rather than
/// an ordinary empty copy, as a Go state keeps a nil slice.
@internal
final class UnsetToolInfos extends DelegatingList<ToolInfo> {
  /// An empty list.
  UnsetToolInfos() : super(<ToolInfo>[]);
}

/// What a model hook knows about the model call.
///
/// Port of eino `adk.ModelContext`. Its deprecated `Tools` field is not
/// ported: use [ChatModelAgentState.toolInfos].
@immutable
final class ModelContext {
  /// The context of a model call.
  const ModelContext({this.modelRetryConfig, this.modelFailoverConfig})
      : cancelContext = null;

  /// The context of a model call of a run that can be cancelled.
  @internal
  const ModelContext.cancellable({
    this.modelRetryConfig,
    this.modelFailoverConfig,
    this.cancelContext,
  });

  /// The retry policy of the agent's model, if any.
  final ModelRetryConfig? modelRetryConfig;

  /// The failover policy of the agent's model, if any.
  final ModelFailoverConfig? modelFailoverConfig;

  /// The cancel context of the run; [EventSenderModelWrapper] makes the
  /// model's streams obey it. Port of eino's unexported `cancelContext`.
  @internal
  final CancelContext? cancelContext;
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
