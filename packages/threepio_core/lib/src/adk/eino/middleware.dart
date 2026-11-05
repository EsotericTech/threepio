/// The middleware contract of a `ChatModelAgent`.
///
/// Port of eino `adk.ChatModelAgentMiddleware` and
/// `adk.BaseChatModelAgentMiddleware` (`adk/handler.go`).
library;

import 'dart:async';

import '../../components/model/base_chat_model.dart';
import '../../components/tool/tool_options.dart';
import '../../core/run_context.dart';
import '../../schema/tool_result.dart';
import '../../streaming/stream_reader.dart';
import 'middleware_context.dart';

/// Calls a tool that returns text. Port of eino
/// `adk.InvokableToolCallEndpoint`.
typedef InvokableToolCallEndpoint = Future<String> Function(
  RunContext ctx,
  String argumentsJson,
  ToolOptions? options,
);

/// Calls a tool that streams text. Port of eino
/// `adk.StreamableToolCallEndpoint`.
typedef StreamableToolCallEndpoint = Future<StreamReader<String>> Function(
  RunContext ctx,
  String argumentsJson,
  ToolOptions? options,
);

/// Calls a tool that returns a structured result. Port of eino
/// `adk.EnhancedInvokableToolCallEndpoint`.
typedef EnhancedInvokableToolCallEndpoint = Future<ToolResult> Function(
  RunContext ctx,
  ToolArgument argument,
  ToolOptions? options,
);

/// Calls a tool that streams structured results. Port of eino
/// `adk.EnhancedStreamableToolCallEndpoint`.
typedef EnhancedStreamableToolCallEndpoint = Future<StreamReader<ToolResult>>
    Function(
  RunContext ctx,
  ToolArgument argument,
  ToolOptions? options,
);

/// Hooks around a `ChatModelAgent` run, its model calls and its tool calls.
///
/// Port of eino `adk.ChatModelAgentMiddleware`; it also plays the role of
/// eino's `BaseChatModelAgentMiddleware`: every hook does nothing by default,
/// so a middleware `extends` this class and overrides what it needs.
///
/// Order: middlewares run in the order of `ChatModelAgentConfig.handlers`.
/// For the wrappers the first one is the outermost: `[a, b]` calls `a`'s
/// wrapper, which calls `b`'s, which calls the tool or model. A hook that
/// throws fails the run.
///
/// ```dart
/// class Timing extends ChatModelAgentMiddleware {
///   @override
///   InvokableToolCallEndpoint wrapInvokableToolCall(
///     RunContext ctx, InvokableToolCallEndpoint next, ToolContext tool) =>
///       (ctx, args, options) async {
///         final watch = Stopwatch()..start();
///         try {
///           return await next(ctx, args, options);
///         } finally {
///           log('${tool.name} took ${watch.elapsed}');
///         }
///       };
/// }
/// ```
abstract class ChatModelAgentMiddleware {
  /// A middleware that does nothing until a hook is overridden.
  const ChatModelAgentMiddleware();

  /// Runs once when the agent starts; may change its instruction, tools and
  /// `returnDirectly` tools for this run. Port of `BeforeAgent`.
  FutureOr<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) =>
      (ctx, agent);

  /// Runs once when the agent has its final answer, with the final state.
  /// Port of `AfterAgent`.
  FutureOr<RunContext> afterAgent(RunContext ctx, ChatModelAgentState state) =>
      ctx;

  /// Runs before every model call; what it returns is what the model sees
  /// and is kept. Port of `BeforeModelRewriteState`.
  FutureOr<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) =>
      (ctx, state);

  /// Runs after every model call; the model's message is the last of
  /// `state.messages`. Port of `AfterModelRewriteState`.
  FutureOr<(RunContext, ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
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
  /// [beforeModelRewriteState] for changing the tools: what a wrapper changes
  /// is not kept.
  BaseChatModel wrapModel(
    RunContext ctx,
    BaseChatModel model,
    ModelContext context,
  ) =>
      model;
}
