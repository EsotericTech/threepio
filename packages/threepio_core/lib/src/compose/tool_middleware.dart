/// What a tool call looks like to the middlewares of a tools node.
///
/// Port of the middleware types of eino `compose/tool_node.go`. The payload
/// types are named `ToolCall…` because `ToolOutput` is the name of the result
/// type of the agent runtime.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../components/tool/tool_options.dart';
import '../core/interrupt_signal.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../schema/tool_result.dart';
import '../streaming/stream_reader.dart';

part 'tool_middlewares/error_remover.dart';
part 'tool_middlewares/json_fix.dart';

/// One call of a tool. Port of eino `compose.ToolInput`.
@immutable
final class ToolCallInput {
  /// The call of the tool [name] with [arguments].
  const ToolCallInput({
    required this.name,
    required this.arguments,
    required this.callId,
    this.callOptions,
  });

  /// The name of the tool as the model called it.
  final String name;

  /// The arguments, a JSON object as text.
  final String arguments;

  /// The id of the tool call.
  final String callId;

  /// The options the tool is run with.
  final ToolOptions? callOptions;

  /// This call with the given fields replaced. A middleware that repairs the
  /// arguments passes the copy on.
  ToolCallInput copyWith({
    String? name,
    String? arguments,
    String? callId,
    ToolOptions? callOptions,
  }) =>
      ToolCallInput(
        name: name ?? this.name,
        arguments: arguments ?? this.arguments,
        callId: callId ?? this.callId,
        callOptions: callOptions ?? this.callOptions,
      );

  @override
  String toString() => 'ToolCallInput($name, $callId)';
}

/// The result of a tool call. Port of eino `compose.ToolOutput`.
@immutable
final class ToolCallOutput {
  /// A result with the text [result].
  const ToolCallOutput(this.result);

  /// What the tool returned.
  final String result;
}

/// The streamed result of a tool call. Port of eino
/// `compose.StreamToolOutput`.
@immutable
final class StreamToolCallOutput {
  /// A result that arrives as [result].
  const StreamToolCallOutput(this.result);

  /// The pieces of what the tool returns.
  final StreamReader<String> result;
}

/// The result of an enhanced tool call, which can hold more than text. Port
/// of eino `compose.EnhancedInvokableToolOutput`.
@immutable
final class EnhancedToolCallOutput {
  /// A result with the content [result].
  const EnhancedToolCallOutput(this.result);

  /// What the tool returned.
  final ToolResult result;
}

/// The streamed result of an enhanced tool call. Port of eino
/// `compose.EnhancedStreamableToolOutput`.
@immutable
final class EnhancedStreamToolCallOutput {
  /// A result that arrives as [result].
  const EnhancedStreamToolCallOutput(this.result);

  /// The pieces of what the tool returns.
  final StreamReader<ToolResult> result;
}

/// Runs a tool call and returns its result. Port of eino
/// `compose.InvokableToolEndpoint`.
typedef InvokableToolEndpoint = Future<ToolCallOutput> Function(
  RunContext ctx,
  ToolCallInput input,
);

/// Port of eino `compose.StreamableToolEndpoint`.
typedef StreamableToolEndpoint = Future<StreamToolCallOutput> Function(
  RunContext ctx,
  ToolCallInput input,
);

/// Port of eino `compose.EnhancedInvokableToolEndpoint`.
typedef EnhancedInvokableToolEndpoint = Future<EnhancedToolCallOutput> Function(
  RunContext ctx,
  ToolCallInput input,
);

/// Port of eino `compose.EnhancedStreamableToolEndpoint`.
typedef EnhancedStreamableToolEndpoint = Future<EnhancedStreamToolCallOutput>
    Function(
  RunContext ctx,
  ToolCallInput input,
);

/// Wraps an endpoint: gets the next one and returns the one to call instead.
/// Port of eino `compose.InvokableToolMiddleware`.
typedef InvokableToolMiddleware = InvokableToolEndpoint Function(
  InvokableToolEndpoint next,
);

/// Port of eino `compose.StreamableToolMiddleware`.
typedef StreamableToolMiddleware = StreamableToolEndpoint Function(
  StreamableToolEndpoint next,
);

/// Port of eino `compose.EnhancedInvokableToolMiddleware`.
typedef EnhancedInvokableToolMiddleware = EnhancedInvokableToolEndpoint
    Function(
  EnhancedInvokableToolEndpoint next,
);

/// Port of eino `compose.EnhancedStreamableToolMiddleware`.
typedef EnhancedStreamableToolMiddleware = EnhancedStreamableToolEndpoint
    Function(
  EnhancedStreamableToolEndpoint next,
);

/// Code that runs around every tool call of a tools node: logging, repairing
/// arguments, turning errors into results.
///
/// Port of eino `compose.ToolMiddleware`. A middleware has up to four parts,
/// one for each way a tool can be run; a part only sees the calls that are
/// run that way. A tool that is only invokable is also run when the node
/// streams, through its [invokable] part.
///
/// The first middleware of `ToolsNodeConfig.toolCallMiddlewares` is the
/// outermost.
///
/// A middleware that catches errors must let interrupts pass (`isInterrupt`),
/// or a tool can no longer pause the run.
///
/// [ErrorRemoverMiddleware] and [JsonFixMiddleware] are ready-made ones.
@immutable
final class ToolMiddleware {
  /// A middleware made of the given parts.
  const ToolMiddleware({
    this.invokable,
    this.streamable,
    this.enhancedInvokable,
    this.enhancedStreamable,
  });

  /// Wraps calls of tools that return a text.
  final InvokableToolMiddleware? invokable;

  /// Wraps calls of tools that return a stream of text.
  final StreamableToolMiddleware? streamable;

  /// Wraps calls of enhanced tools that return a result.
  final EnhancedInvokableToolMiddleware? enhancedInvokable;

  /// Wraps calls of enhanced tools that return a stream of results.
  final EnhancedStreamableToolMiddleware? enhancedStreamable;
}
