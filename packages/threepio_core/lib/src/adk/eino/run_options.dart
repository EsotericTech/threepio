/// The options of one agent run.
///
/// Port of eino `adk/call_option.go` and of the run options in
/// `adk/chatmodel.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../callbacks/component_callback_handler.dart';
import '../../components/model/chat_model_options.dart';
import '../../components/tool/tool_options.dart';
import '../../core/run_context.dart';
import 'cancel.dart';

/// One option of an agent run, by default seen by every agent of the run.
///
/// Port of eino `adk.AgentRunOption`. [designateAgent] limits an option to
/// the agents with the given names, for example an option meant for the
/// agent behind an `AgentTool`.
///
/// ```dart
/// runner.run(ctx, messages, options: [
///   AgentRunOption.sessionValues({'user': 'Ada'}),
///   AgentRunOption.chatModelOptions(const ChatModelOptions(temperature: 0))
///       .designateAgent(['researcher']),
/// ]);
/// ```
sealed class AgentRunOption {
  const AgentRunOption._(this.agentNames);

  /// Values every agent of the run can read and write
  /// (`AgentContext.sessionValues`). Port of eino `adk.WithSessionValues`.
  factory AgentRunOption.sessionValues(Map<String, Object?> values) =>
      _SessionValuesOption(Map.unmodifiable(values), const []);

  /// Callback handlers for the agents of the run and everything they call.
  /// Port of eino `adk.WithCallbacks`.
  factory AgentRunOption.callbacks(List<ComponentCallbackHandler> handlers) =>
      _CallbacksOption(List.unmodifiable(handlers), const []);

  /// The id the runner saves a checkpoint under when the run interrupts.
  /// Port of eino `adk.WithCheckPointID`.
  factory AgentRunOption.checkpointId(String id) =>
      _CheckpointIdOption(id, const []);

  /// Options for every model call of a `ChatModelAgent`. Port of eino
  /// `adk.WithChatModelOptions`.
  factory AgentRunOption.chatModelOptions(ChatModelOptions options) =>
      _ChatModelOptionsOption(options, const []);

  /// Options for every tool call of a `ChatModelAgent`. Port of eino
  /// `adk.WithToolOptions`.
  factory AgentRunOption.toolOptions(ToolOptions options) =>
      _ToolOptionsOption(options, const []);

  /// Run options for the agents behind `AgentTool`s, by tool name. Port of
  /// eino `adk.WithAgentToolRunOptions`.
  factory AgentRunOption.agentToolRunOptions(
    Map<String, List<AgentRunOption>> options,
  ) =>
      _AgentToolRunOptionsOption(Map.unmodifiable(options), const []);

  /// A function a `ChatModelAgent` calls after the tool calls of a turn have
  /// finished, before its next model call. Port of eino
  /// `adk.WithAfterToolCallsHook`.
  factory AgentRunOption.afterToolCallsHook(
    FutureOr<void> Function(RunContext ctx) hook,
  ) =>
      _AfterToolCallsHookOption(hook, const []);

  /// An option of a custom agent: [value] is handed to the agent, which
  /// reads it with [customValues].
  ///
  /// Port of eino `adk.WrapImplSpecificOptFn`. A static method and not a
  /// constructor because it captures [T].
  static AgentRunOption custom<T extends Object>(T value) =>
      _CustomOption<T>(value, const []);

  /// The values of the [custom] options of type [T] in [options], in order.
  ///
  /// Port of eino `adk.GetImplSpecificOptions`.
  static List<T> customValues<T extends Object>(
    Iterable<AgentRunOption> options,
  ) =>
      [
        for (final option in options)
          if (option is _CustomOption && option.value is T) option.value as T,
      ];

  /// The names of the agents this option is meant for; empty means all.
  final List<String> agentNames;

  /// This option, meant only for the agents named [names]. Port of eino
  /// `AgentRunOption.DesignateAgent`.
  AgentRunOption designateAgent(List<String> names) =>
      _withNames(List.unmodifiable([...agentNames, ...names]));

  AgentRunOption _withNames(List<String> names);
}

final class _SessionValuesOption extends AgentRunOption {
  const _SessionValuesOption(this.values, super.agentNames) : super._();

  final Map<String, Object?> values;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _SessionValuesOption(values, names);
}

final class _CallbacksOption extends AgentRunOption {
  const _CallbacksOption(this.handlers, super.agentNames) : super._();

  final List<ComponentCallbackHandler> handlers;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _CallbacksOption(handlers, names);
}

final class _CheckpointIdOption extends AgentRunOption {
  const _CheckpointIdOption(this.id, super.agentNames) : super._();

  final String id;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _CheckpointIdOption(id, names);
}

final class _ChatModelOptionsOption extends AgentRunOption {
  const _ChatModelOptionsOption(this.options, super.agentNames) : super._();

  final ChatModelOptions options;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _ChatModelOptionsOption(options, names);
}

final class _ToolOptionsOption extends AgentRunOption {
  const _ToolOptionsOption(this.options, super.agentNames) : super._();

  final ToolOptions options;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _ToolOptionsOption(options, names);
}

final class _AgentToolRunOptionsOption extends AgentRunOption {
  const _AgentToolRunOptionsOption(this.options, super.agentNames) : super._();

  final Map<String, List<AgentRunOption>> options;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _AgentToolRunOptionsOption(options, names);
}

final class _AfterToolCallsHookOption extends AgentRunOption {
  const _AfterToolCallsHookOption(this.hook, super.agentNames) : super._();

  final FutureOr<void> Function(RunContext ctx) hook;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _AfterToolCallsHookOption(hook, names);
}

final class _SharedParentSessionOption extends AgentRunOption {
  const _SharedParentSessionOption(super.agentNames) : super._();

  @override
  AgentRunOption _withNames(List<String> names) =>
      _SharedParentSessionOption(names);
}

final class _CustomOption<T extends Object> extends AgentRunOption {
  const _CustomOption(this.value, super.agentNames) : super._();

  final T value;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _CustomOption<T>(value, names);
}

final class _CancelContextOption extends AgentRunOption {
  const _CancelContextOption(this.cancelContext, super.agentNames) : super._();

  final CancelContext cancelContext;

  @override
  AgentRunOption _withNames(List<String> names) =>
      _CancelContextOption(cancelContext, names);
}

/// The option of a cancellable run: `withCancel` returns it. Port of the
/// option eino's `WithCancel` builds (it sets `options.cancelCtx`).
@internal
AgentRunOption cancelContextOption(CancelContext cancelContext) =>
    _CancelContextOption(cancelContext, const []);

/// [options] without the option of a cancellable run: the agents inside a
/// run reach its cancel context through the `RunContext`. Port of eino
/// `filterCancelOption`.
@internal
List<AgentRunOption> filterCancelOption(List<AgentRunOption> options) => [
      for (final option in options)
        if (option is! _CancelContextOption) option,
    ];

/// [options] without the callback handlers the wrapper of the workflow agent
/// [currentAgentName] installed already: those for every agent and those
/// meant for it. Its sub-agents inherit them through the context and must not
/// add them a second time. Port of eino `filterCallbackHandlersForNestedAgents`.
@internal
List<AgentRunOption> filterCallbackHandlersForNestedAgents(
  String currentAgentName,
  List<AgentRunOption> options,
) =>
    [
      for (final option in options)
        if (!(option is _CallbacksOption &&
            option.handlers.isNotEmpty &&
            (option.agentNames.isEmpty ||
                option.agentNames.contains(currentAgentName))))
          option,
    ];

/// The run shares the session values of the run it is nested in. Port of
/// eino `withSharedParentSession`; an `AgentTool` uses it.
@internal
AgentRunOption sharedParentSessionOption() =>
    const _SharedParentSessionOption([]);

/// The options every agent reads. Port of eino's `options`.
@internal
final class CommonAgentOptions {
  CommonAgentOptions._(Iterable<AgentRunOption> options) {
    for (final option in options) {
      switch (option) {
        case _SessionValuesOption(:final values):
          sessionValues = values;
        case _CallbacksOption(:final handlers):
          this.handlers.addAll(handlers);
        case _CheckpointIdOption(:final id):
          checkpointId = id;
        case _SharedParentSessionOption():
          sharedParentSession = true;
        case _CancelContextOption(:final cancelContext):
          this.cancelContext = cancelContext;
        case _ChatModelOptionsOption() ||
              _ToolOptionsOption() ||
              _AgentToolRunOptionsOption() ||
              _AfterToolCallsHookOption() ||
              _CustomOption():
          break;
      }
    }
  }

  /// The common options in [options]. Port of eino `getCommonOptions`.
  factory CommonAgentOptions.of(Iterable<AgentRunOption> options) =>
      CommonAgentOptions._(options);

  bool sharedParentSession = false;
  Map<String, Object?> sessionValues = const {};
  String? checkpointId;
  final List<ComponentCallbackHandler> handlers = [];

  /// The cancel context of a run started with `withCancel`.
  CancelContext? cancelContext;
}

/// The options a `ChatModelAgent` reads. Port of eino
/// `chatModelAgentRunOptions`.
@internal
final class ChatModelAgentRunOptions {
  ChatModelAgentRunOptions._(Iterable<AgentRunOption> options) {
    for (final option in options) {
      switch (option) {
        case _ChatModelOptionsOption(:final options):
          chatModelOptions = options;
        case _ToolOptionsOption(:final options):
          toolOptions = options;
        case _AgentToolRunOptionsOption(:final options):
          agentToolOptions = options;
        case _AfterToolCallsHookOption(:final hook):
          afterToolCallsHook = hook;
        case _SessionValuesOption() ||
              _CallbacksOption() ||
              _CheckpointIdOption() ||
              _SharedParentSessionOption() ||
              _CancelContextOption() ||
              _CustomOption():
          break;
      }
    }
  }

  /// The `ChatModelAgent` options in [options].
  factory ChatModelAgentRunOptions.of(Iterable<AgentRunOption> options) =>
      ChatModelAgentRunOptions._(options);

  ChatModelOptions? chatModelOptions;
  ToolOptions? toolOptions;
  Map<String, List<AgentRunOption>> agentToolOptions = const {};
  FutureOr<void> Function(RunContext ctx)? afterToolCallsHook;
}

/// The options of [options] that the agent [agentName] sees. Port of eino
/// `filterOptions`.
@internal
List<AgentRunOption> filterOptions(
  String agentName,
  List<AgentRunOption> options,
) =>
    [
      for (final option in options)
        if (option.agentNames.isEmpty || option.agentNames.contains(agentName))
          option,
    ];
