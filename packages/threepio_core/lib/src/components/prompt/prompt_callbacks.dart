/// What a chat template reports to callback handlers.
///
/// Port of eino `components/prompt/callback_extra.go`.
library;

import 'package:meta/meta.dart';

import '../../schema/message.dart';
import '../../schema/message_template.dart';

/// The input of a chat template, as callback handlers see it.
///
/// Port of eino `prompt.CallbackInput`.
@immutable
final class PromptCallbackInput {
  /// The input of a formatting call with [variables].
  const PromptCallbackInput({
    required this.variables,
    this.templates,
    this.extra,
  });

  /// The values the template is filled with.
  final Map<String, Object?> variables;

  /// The message templates that are rendered.
  final List<MessagesTemplate>? templates;

  /// Whatever else the template wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of a chat template, or returns `null` when it
  /// is not one.
  ///
  /// Port of eino `prompt.ConvCallbackInput`: accepts a
  /// [PromptCallbackInput] or the plain map of variables a graph node
  /// reports.
  static PromptCallbackInput? from(Object? raw) => switch (raw) {
        final PromptCallbackInput input => input,
        final Map<String, Object?> variables =>
          PromptCallbackInput(variables: variables),
        _ => null,
      };

  @override
  String toString() => 'PromptCallbackInput(variables: ${variables.keys}, '
      'templates: ${templates?.length})';
}

/// The output of a chat template, as callback handlers see it.
///
/// Port of eino `prompt.CallbackOutput`.
@immutable
final class PromptCallbackOutput {
  /// The output of a formatting call that produced [result].
  const PromptCallbackOutput({
    required this.result,
    this.templates,
    this.extra,
  });

  /// The rendered messages.
  final List<Message> result;

  /// The message templates that were rendered.
  final List<MessagesTemplate>? templates;

  /// Whatever else the template wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of a chat template, or returns `null` when it
  /// is not one.
  ///
  /// Port of eino `prompt.ConvCallbackOutput`: accepts a
  /// [PromptCallbackOutput] or the plain list of messages a graph node
  /// reports.
  static PromptCallbackOutput? from(Object? raw) => switch (raw) {
        final PromptCallbackOutput output => output,
        final List<Message> messages => PromptCallbackOutput(result: messages),
        final List<Object?> items
            when items.isNotEmpty && items.every((item) => item is Message) =>
          PromptCallbackOutput(result: items.cast<Message>()),
        _ => null,
      };

  @override
  String toString() => 'PromptCallbackOutput(result: ${result.length}, '
      'templates: ${templates?.length})';
}
