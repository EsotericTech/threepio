/// The model contract of the agentic path and what it reports to callback
/// handlers.
///
/// Port of eino `model.AgenticModel` (`components/model/interface.go`) and
/// `components/model/agentic_callback_extra.go`. **Beta**, as the whole
/// agentic path is upstream.
library;

import 'package:meta/meta.dart';

import '../../schema/agentic_message.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import 'chat_model_options.dart';

/// A model that takes and gives [AgenticMessage]s: content blocks for
/// reasoning, text, media and function, server and MCP tool calls.
///
/// Port of eino `model.AgenticModel` (`BaseModel[*schema.AgenticMessage]`).
/// Unlike `ToolCallingChatModel` it has no `withTools`: tools travel per
/// call in [ChatModelOptions.tools], and how they may be called in
/// [ChatModelOptions.agenticToolChoice].
abstract interface class AgenticModel {
  /// The complete answer to [input].
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  });

  /// The answer to [input] as chunks; a chunk's blocks carry
  /// `StreamingMeta`s that say where they go in the joined message.
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  });
}

/// The settings an agentic model call was made with. Port of eino
/// `model.AgenticConfig`; a field is `null` when the call left it to the
/// provider.
@immutable
final class AgenticModelCallbackConfig {
  /// The settings of one call.
  const AgenticModelCallbackConfig({
    this.model,
    this.maxTokens,
    this.temperature,
    this.topP,
  });

  /// The settings in [options]; [defaultModel] is the model the provider
  /// uses when the options name none.
  factory AgenticModelCallbackConfig.fromOptions(
    ChatModelOptions? options, {
    String? defaultModel,
  }) =>
      AgenticModelCallbackConfig(
        model: options?.model ?? defaultModel,
        maxTokens: options?.maxTokens,
        temperature: options?.temperature,
        topP: options?.topP,
      );

  /// The model name. Port of the field `Model`.
  final String? model;

  /// The most output tokens. Port of the field `MaxTokens`.
  final int? maxTokens;

  /// How random the answer is. Port of the field `Temperature`.
  final double? temperature;

  /// The nucleus sampling cut-off. Port of the field `TopP`.
  final double? topP;

  @override
  String toString() => 'AgenticModelCallbackConfig(model: $model, '
      'maxTokens: $maxTokens, temperature: $temperature, topP: $topP)';
}

/// What an agentic model reports when a call starts. Port of eino
/// `model.AgenticCallbackInput`.
@immutable
final class AgenticModelCallbackInput {
  /// The input of a call with [messages].
  const AgenticModelCallbackInput({
    required this.messages,
    this.tools,
    this.config,
    this.extra,
  });

  /// The messages sent to the model. Port of the field `Messages`.
  final List<AgenticMessage> messages;

  /// The tools the model may call. Port of the field `Tools`.
  final List<ToolInfo>? tools;

  /// The settings of the call. Port of the field `Config`.
  final AgenticModelCallbackConfig? config;

  /// Whatever else the model wants handlers to know. Port of the field
  /// `Extra`.
  final Map<String, Object?>? extra;

  /// [raw] as an agentic model input, or `null` when it is none. Port of
  /// eino `model.ConvAgenticCallbackInput`: the plain list of messages a
  /// graph node reports is accepted too (also a list that was not created
  /// as a list of agentic messages but holds nothing else).
  static AgenticModelCallbackInput? from(Object? raw) => switch (raw) {
        final AgenticModelCallbackInput input => input,
        final List<AgenticMessage> messages =>
          AgenticModelCallbackInput(messages: messages),
        final List<Object?> items when items.isNotEmpty &&
            items.every((item) => item is AgenticMessage) =>
          AgenticModelCallbackInput(messages: items.cast<AgenticMessage>()),
        _ => null,
      };

  @override
  String toString() => 'AgenticModelCallbackInput(messages: '
      '${messages.length}, tools: ${tools?.length}, config: $config)';
}

/// What an agentic model reports when a call ends (once per chunk for a
/// stream). Port of eino `model.AgenticCallbackOutput`.
@immutable
final class AgenticModelCallbackOutput {
  /// The output of a call (or one chunk of it).
  const AgenticModelCallbackOutput({
    this.message,
    this.config,
    this.tokenUsage,
    this.extra,
  });

  /// The message (or chunk) the model gave. Port of the field `Message`.
  final AgenticMessage? message;

  /// The settings of the call. Port of the field `Config`.
  final AgenticModelCallbackConfig? config;

  /// The tokens the call used. Port of the field `TokenUsage`.
  final TokenUsage? tokenUsage;

  /// Whatever else the model wants handlers to know. Port of the field
  /// `Extra`.
  final Map<String, Object?>? extra;

  /// [raw] as an agentic model output, or `null` when it is none. Port of
  /// eino `model.ConvAgenticCallbackOutput`: the plain message a graph node
  /// reports is accepted too, and its token usage is read from its response
  /// meta (as `ModelCallbackOutput.from` does; Go leaves it empty).
  static AgenticModelCallbackOutput? from(Object? raw) => switch (raw) {
        final AgenticModelCallbackOutput output => output,
        final AgenticMessage message => AgenticModelCallbackOutput(
            message: message,
            tokenUsage: message.responseMeta?.tokenUsage,
          ),
        _ => null,
      };

  @override
  String toString() => 'AgenticModelCallbackOutput(message: $message, '
      'config: $config, tokenUsage: $tokenUsage)';
}
