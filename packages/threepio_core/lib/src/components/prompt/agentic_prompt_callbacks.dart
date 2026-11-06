/// What an agentic chat template reports to callback handlers.
///
/// Port of eino `components/prompt/agentic_callback_extra.go`. **Beta**, as
/// the whole agentic path is upstream.
library;

import 'package:meta/meta.dart';

import '../../schema/agentic_message.dart';
import '../../schema/agentic_message_template.dart';

/// The input of an agentic chat template, as callback handlers see it.
///
/// Port of eino `prompt.AgenticCallbackInput`.
@immutable
final class AgenticPromptCallbackInput {
  /// The input of a formatting call with [variables].
  const AgenticPromptCallbackInput({
    required this.variables,
    this.templates,
    this.extra,
  });

  /// The values the template is filled with.
  final Map<String, Object?> variables;

  /// The agentic message templates that are rendered.
  final List<AgenticMessagesTemplate>? templates;

  /// Whatever else the template wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of an agentic chat template, or returns `null`
  /// when it is not one.
  ///
  /// Port of eino `prompt.ConvAgenticCallbackInput`: accepts an
  /// [AgenticPromptCallbackInput] or the plain map of variables a graph node
  /// reports.
  static AgenticPromptCallbackInput? from(Object? raw) => switch (raw) {
        final AgenticPromptCallbackInput input => input,
        final Map<String, Object?> variables =>
          AgenticPromptCallbackInput(variables: variables),
        _ => null,
      };

  @override
  String toString() =>
      'AgenticPromptCallbackInput(variables: ${variables.keys}, '
      'templates: ${templates?.length})';
}

/// The output of an agentic chat template, as callback handlers see it.
///
/// Port of eino `prompt.AgenticCallbackOutput`.
@immutable
final class AgenticPromptCallbackOutput {
  /// The output of a formatting call that produced [result].
  const AgenticPromptCallbackOutput({
    required this.result,
    this.templates,
    this.extra,
  });

  /// The rendered messages.
  final List<AgenticMessage> result;

  /// The agentic message templates that were rendered.
  final List<AgenticMessagesTemplate>? templates;

  /// Whatever else the template wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of an agentic chat template, or returns
  /// `null` when it is not one.
  ///
  /// Port of eino `prompt.ConvAgenticCallbackOutput`: accepts an
  /// [AgenticPromptCallbackOutput] or the plain list of agentic messages a
  /// graph node reports.
  static AgenticPromptCallbackOutput? from(Object? raw) => switch (raw) {
        final AgenticPromptCallbackOutput output => output,
        final List<AgenticMessage> messages =>
          AgenticPromptCallbackOutput(result: messages),
        final List<Object?> items when items.isNotEmpty &&
            items.every((item) => item is AgenticMessage) =>
          AgenticPromptCallbackOutput(result: items.cast<AgenticMessage>()),
        _ => null,
      };

  @override
  String toString() =>
      'AgenticPromptCallbackOutput(result: ${result.length}, '
      'templates: ${templates?.length})';
}
