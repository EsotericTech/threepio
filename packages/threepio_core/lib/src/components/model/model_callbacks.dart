/// What a chat model reports to callback handlers.
///
/// Port of eino `components/model/callback_extra.go`.
library;

import 'package:meta/meta.dart';

import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import 'chat_model_options.dart';

/// The settings a chat model call was made with.
///
/// Port of eino `model.Config`. A field is `null` when the call left the
/// setting to the provider.
@immutable
final class ModelCallbackConfig {
  /// The settings of a call.
  const ModelCallbackConfig({
    this.model,
    this.maxTokens,
    this.temperature,
    this.topP,
    this.stop,
  });

  /// The settings in [options]. [defaultModel] is the model the provider
  /// uses when the options name none.
  factory ModelCallbackConfig.fromOptions(
    ChatModelOptions? options, {
    String? defaultModel,
  }) =>
      ModelCallbackConfig(
        model: options?.model ?? defaultModel,
        maxTokens: options?.maxTokens,
        temperature: options?.temperature,
        topP: options?.topP,
        stop: options?.stop,
      );

  /// The name of the model.
  final String? model;

  /// The most tokens the model may generate.
  final int? maxTokens;

  /// The sampling temperature.
  final double? temperature;

  /// The nucleus sampling threshold.
  final double? topP;

  /// The sequences that end the generation.
  final List<String>? stop;

  @override
  String toString() => 'ModelCallbackConfig(model: $model, maxTokens: '
      '$maxTokens, temperature: $temperature, topP: $topP, stop: $stop)';
}

/// The input of a chat model call, as callback handlers see it.
///
/// Port of eino `model.CallbackInput`.
@immutable
final class ModelCallbackInput {
  /// The input of a call with [messages].
  const ModelCallbackInput({
    required this.messages,
    this.tools,
    this.toolChoice,
    this.config,
    this.extra,
  });

  /// The messages sent to the model.
  final List<Message> messages;

  /// The tools the model may call.
  final List<ToolInfo>? tools;

  /// Whether the model may, must or must not call a tool.
  final ToolChoice? toolChoice;

  /// The settings of the call.
  final ModelCallbackConfig? config;

  /// Whatever else the model wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of a chat model call, or returns `null` when it
  /// is not one.
  ///
  /// Port of eino `model.ConvCallbackInput`. A handler receives a
  /// [ModelCallbackInput] from a model that fires its own callbacks, and the
  /// plain list of messages from a graph node that fires them for the model.
  static ModelCallbackInput? from(Object? raw) => switch (raw) {
        final ModelCallbackInput input => input,
        final List<Message> messages => ModelCallbackInput(messages: messages),
        // A list that was not created as a list of messages but holds
        // nothing else.
        final List<Object?> items
            when items.isNotEmpty && items.every((item) => item is Message) =>
          ModelCallbackInput(messages: items.cast<Message>()),
        _ => null,
      };

  @override
  String toString() => 'ModelCallbackInput(messages: ${messages.length}, '
      'tools: ${tools?.length}, toolChoice: $toolChoice, config: $config)';
}

/// The output of a chat model call, as callback handlers see it.
///
/// Port of eino `model.CallbackOutput`. For a streamed answer, each chunk is
/// reported as one of these.
@immutable
final class ModelCallbackOutput {
  /// The output of a call.
  const ModelCallbackOutput({
    this.message,
    this.config,
    this.tokenUsage,
    this.extra,
  });

  /// The message the model generated, or a chunk of it.
  final Message? message;

  /// The settings of the call.
  final ModelCallbackConfig? config;

  /// The tokens the call used.
  final TokenUsage? tokenUsage;

  /// Whatever else the model wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of a chat model call, or returns `null` when
  /// it is not one.
  ///
  /// Port of eino `model.ConvCallbackOutput`: accepts a [ModelCallbackOutput]
  /// or the plain [Message] a graph node reports. The token usage of a plain
  /// message is taken from its response metadata.
  static ModelCallbackOutput? from(Object? raw) => switch (raw) {
        final ModelCallbackOutput output => output,
        final Message message => ModelCallbackOutput(
            message: message,
            tokenUsage: message.responseMeta?.usage,
          ),
        _ => null,
      };

  @override
  String toString() => 'ModelCallbackOutput(message: $message, config: '
      '$config, tokenUsage: $tokenUsage)';
}
