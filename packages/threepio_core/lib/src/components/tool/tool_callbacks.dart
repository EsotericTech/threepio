/// What a tool reports to callback handlers.
///
/// Port of eino `components/tool/callback_extra.go`.
library;

import 'package:meta/meta.dart';

import '../../schema/tool_result.dart';

/// The input of a tool call, as callback handlers see it.
///
/// Port of eino `tool.CallbackInput`.
@immutable
final class ToolCallbackInput {
  /// The input of a call with [argumentsJson].
  const ToolCallbackInput({required this.argumentsJson, this.extra});

  /// The arguments of the call, as the JSON the model wrote.
  final String argumentsJson;

  /// Whatever else the tool wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of a tool call, or returns `null` when it is
  /// not one.
  ///
  /// Port of eino `tool.ConvCallbackInput`. A handler receives a
  /// [ToolCallbackInput] from a tool that fires its own callbacks, and the
  /// plain argument (a JSON `String`, or a [ToolArgument] for an enhanced
  /// tool) from a graph node that fires them for the tool.
  static ToolCallbackInput? from(Object? raw) => switch (raw) {
        final ToolCallbackInput input => input,
        final String arguments => ToolCallbackInput(argumentsJson: arguments),
        final ToolArgument argument =>
          ToolCallbackInput(argumentsJson: argument.text),
        _ => null,
      };

  @override
  String toString() => 'ToolCallbackInput(argumentsJson: $argumentsJson)';
}

/// The output of a tool call, as callback handlers see it.
///
/// Port of eino `tool.CallbackOutput`.
@immutable
final class ToolCallbackOutput {
  /// The output of a call: [response] for a plain tool, [toolOutput] for an
  /// enhanced one.
  const ToolCallbackOutput({this.response, this.toolOutput, this.extra});

  /// The text result of a plain tool.
  final String? response;

  /// The structured result of an enhanced tool.
  final ToolResult? toolOutput;

  /// Whatever else the tool wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of a tool call, or returns `null` when it is
  /// not one.
  ///
  /// Port of eino `tool.ConvCallbackOutput`: accepts a [ToolCallbackOutput],
  /// the `String` a plain tool returned, or the [ToolResult] of an enhanced
  /// one.
  static ToolCallbackOutput? from(Object? raw) => switch (raw) {
        final ToolCallbackOutput output => output,
        final String response => ToolCallbackOutput(response: response),
        final ToolResult result => ToolCallbackOutput(toolOutput: result),
        _ => null,
      };

  @override
  String toString() =>
      'ToolCallbackOutput(response: $response, toolOutput: $toolOutput)';
}
