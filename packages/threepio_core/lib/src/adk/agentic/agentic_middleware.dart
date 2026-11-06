/// The middleware contract of an `AgenticChatModelAgent`.
///
/// Port of eino `adk.TypedChatModelAgentMiddleware[*schema.AgenticMessage]`,
/// `adk.TypedBaseChatModelAgentMiddleware`, `TypedChatModelAgentState` and
/// `TypedModelContext` (`adk/handler.go`, `adk/chatmodel.go`). **Beta**.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/model/agentic_model.dart';
import '../../core/run_context.dart';
import '../../schema/agentic_message.dart';
import '../../schema/tool_info.dart';
import '../eino/cancel.dart';
import '../eino/middleware.dart';
import '../eino/middleware_context.dart';

/// The conversation of an `AgenticChatModelAgent` around a model call.
///
/// Port of eino `adk.TypedChatModelAgentState[*schema.AgenticMessage]`.
/// Mutable on purpose: the `beforeModelRewriteState` and
/// `afterModelRewriteState` hooks change it, and what they leave is kept in
/// the agent's state.
final class AgenticChatModelAgentState {
  /// A state with [messages].
  AgenticChatModelAgentState({
    required List<AgenticMessage> messages,
    List<ToolInfo> toolInfos = const [],
    List<ToolInfo>? deferredToolInfos,
  })  : messages = List.of(messages),
        toolInfos = List.of(toolInfos),
        deferredToolInfos =
            deferredToolInfos == null ? null : List.of(deferredToolInfos);

  /// The whole conversation, sent to the model on the next call.
  List<AgenticMessage> messages;

  /// The tools the model is told about (`ChatModelOptions.tools`). Changes
  /// are kept for later calls.
  List<ToolInfo> toolInfos;

  /// Tools the model can look up on the server side
  /// (`ChatModelOptions.deferredTools`); `null` when not used.
  List<ToolInfo>? deferredToolInfos;
}

/// What a model hook of an agentic middleware knows about the model call.
///
/// Port of eino `adk.TypedModelContext[*schema.AgenticMessage]`. Its
/// deprecated `Tools` field is not ported (use
/// [AgenticChatModelAgentState.toolInfos]); `ModelRetryConfig` and
/// `ModelFailoverConfig` are not ported either, because retry and failover
/// are not built for agentic models yet.
@immutable
final class AgenticModelContext {
  /// The context of a model call.
  const AgenticModelContext() : cancelContext = null;

  /// The context of a model call of a run that can be cancelled.
  @internal
  const AgenticModelContext.cancellable({this.cancelContext});

  /// The cancel context of the run; the agent's event sender makes the
  /// model's streams obey it. Port of eino's unexported `cancelContext`.
  @internal
  final CancelContext? cancelContext;
}

/// Hooks around an `AgenticChatModelAgent` run, its model calls and its
/// tool calls.
///
/// Port of eino `adk.TypedChatModelAgentMiddleware[*schema.AgenticMessage]`;
/// it also plays the role of eino's `TypedBaseChatModelAgentMiddleware`:
/// every hook does nothing by default, so a middleware `extends` this class
/// and overrides what it needs. The agent context ([ChatModelAgentContext]),
/// the tool endpoints and [ToolContext] are those of the classic
/// `ChatModelAgentMiddleware`: tools speak text and `ToolResult`s on both
/// paths.
///
/// Order: middlewares run in the order of
/// `AgenticChatModelAgentConfig.handlers`. For the wrappers the first one is
/// the outermost. A hook that throws fails the run.
abstract class AgenticChatModelAgentMiddleware {
  /// A middleware that does nothing until a hook is overridden.
  const AgenticChatModelAgentMiddleware();

  /// Runs once when the agent starts; may change its instruction, tools and
  /// `returnDirectly` tools for this run. Port of `BeforeAgent`.
  FutureOr<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) =>
      (ctx, agent);

  /// Runs once when the agent has its final answer, with the final state.
  /// Port of `AfterAgent`.
  FutureOr<RunContext> afterAgent(
    RunContext ctx,
    AgenticChatModelAgentState state,
  ) =>
      ctx;

  /// Runs before every model call; what it returns is what the model sees
  /// and is kept. Port of `BeforeModelRewriteState`.
  FutureOr<(RunContext, AgenticChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticModelContext model,
  ) =>
      (ctx, state);

  /// Runs after every model call; the model's message is the last of
  /// `state.messages`. Port of `AfterModelRewriteState`.
  FutureOr<(RunContext, AgenticChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticModelContext model,
  ) =>
      (ctx, state);

  /// Wraps every call of a tool that returns text. Port of
  /// `WrapInvokableToolCall`.
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      next;

  /// Wraps every call of a tool that streams text. Port of
  /// `WrapStreamableToolCall`.
  StreamableToolCallEndpoint wrapStreamableToolCall(
    RunContext ctx,
    StreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      next;

  /// Wraps every call of a tool that returns a structured result. Port of
  /// `WrapEnhancedInvokableToolCall`.
  EnhancedInvokableToolCallEndpoint wrapEnhancedInvokableToolCall(
    RunContext ctx,
    EnhancedInvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      next;

  /// Wraps every call of a tool that streams structured results. Port of
  /// `WrapEnhancedStreamableToolCall`.
  EnhancedStreamableToolCallEndpoint wrapEnhancedStreamableToolCall(
    RunContext ctx,
    EnhancedStreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      next;

  /// Wraps the model for one call. Port of `WrapModel`. Prefer
  /// [beforeModelRewriteState] for changing the tools: what a wrapper
  /// changes is not kept.
  AgenticModel wrapModel(
    RunContext ctx,
    AgenticModel model,
    AgenticModelContext context,
  ) =>
      model;
}

/// The tool hooks of an agentic middleware as a classic middleware, so that
/// the tools node gets them through the shared `handlersToToolMiddlewares`
/// (tools are message-agnostic). Only the four tool hooks are forwarded.
@internal
final class AgenticToolHooks extends ChatModelAgentMiddleware {
  /// The tool hooks of [handler].
  const AgenticToolHooks(this.handler);

  /// The agentic middleware.
  final AgenticChatModelAgentMiddleware handler;

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      handler.wrapInvokableToolCall(ctx, next, tool);

  @override
  StreamableToolCallEndpoint wrapStreamableToolCall(
    RunContext ctx,
    StreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      handler.wrapStreamableToolCall(ctx, next, tool);

  @override
  EnhancedInvokableToolCallEndpoint wrapEnhancedInvokableToolCall(
    RunContext ctx,
    EnhancedInvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      handler.wrapEnhancedInvokableToolCall(ctx, next, tool);

  @override
  EnhancedStreamableToolCallEndpoint wrapEnhancedStreamableToolCall(
    RunContext ctx,
    EnhancedStreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      handler.wrapEnhancedStreamableToolCall(ctx, next, tool);
}
