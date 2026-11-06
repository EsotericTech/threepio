import 'package:meta/meta.dart';

import '../../../../core/run_context.dart';
import '../../../../schema/message.dart';
import '../../chat_model_options.dart';
import '../openrouter/openrouter_options.dart';

/// Changes the request body of an OpenAI-compatible call just before it is
/// sent.
///
/// Port of eino-ext `openai.RequestPayloadModifier`. Go hands over the raw
/// JSON bytes; here the decoded body is handed over, and what the function
/// returns is sent. [input] are the messages of the call, [ctx] its run
/// context (`ChatModelOptions.runContext`).
typedef RequestPayloadModifier = Map<String, Object?> Function(
  RunContext? ctx,
  List<Message> input,
  Map<String, Object?> body,
);

/// Changes the message parsed from a complete response.
///
/// Port of eino-ext `openai.ResponseMessageModifier`. [rawBody] is the
/// decoded response.
typedef ResponseMessageModifier = Message Function(
  RunContext? ctx,
  Message message,
  Map<String, Object?> rawBody,
);

/// Changes each message parsed from a streamed chunk.
///
/// Port of eino-ext `openai.ResponseChunkMessageModifier`. It is called for
/// every message the stream emits with the decoded chunk it came from, and
/// once more at the end with [end] `true` and the message that was held
/// back because it was empty (or `null` when there was none) and no chunk.
/// Returning `null` drops the message.
typedef ResponseChunkMessageModifier = Message? Function(
  RunContext? ctx,
  Message? message,
  Map<String, Object?>? rawChunk, {
  required bool end,
});

/// Output modalities of the OpenAI Chat Completions API.
///
/// Port of eino-ext `openai.Modality`.
enum OpenAIModality {
  /// Text output.
  text('text'),

  /// Audio output; needs an [OpenAIAudioConfig].
  audio('audio');

  const OpenAIModality(this.wireName);

  /// The value sent in `modalities`.
  final String wireName;
}

/// The audio output settings, required with [OpenAIModality.audio].
///
/// Port of eino-ext `openai.Audio`.
@immutable
final class OpenAIAudioConfig {
  /// Audio in [format] (`wav`, `mp3`, `flac`, `opus`, `pcm16`) spoken with
  /// [voice] (`alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`,
  /// `verse`, …).
  const OpenAIAudioConfig({required this.format, required this.voice});

  /// The output audio format.
  final String format;

  /// The voice the model answers with.
  final String voice;

  /// The `audio` request field.
  Map<String, Object?> toJson() => {'format': format, 'voice': voice};
}

/// Per-call options of the OpenAI and OpenAI-compatible chat models.
///
/// Port of the eino-ext `openai` call options `WithExtraFields`,
/// `WithExtraHeader`, `WithReasoningEffort`, `WithMaxCompletionTokens`,
/// `WithRequestPayloadModifier`, `WithResponseMessageModifier` and
/// `WithResponseChunkMessageModifier`. Pass it in
/// `ChatModelOptions.extensions` (or build options with [toOptions]); what is
/// set here replaces the corresponding setting of the model's config for this
/// call, as in Go.
///
/// ```dart
/// final reply = await model.generate(
///   messages,
///   options: const OpenAIRequestOptions(
///     reasoningEffort: ReasoningEffort.low,
///   ).toOptions(),
/// );
/// ```
@immutable
final class OpenAIRequestOptions {
  /// Options for one call.
  const OpenAIRequestOptions({
    this.extraFields,
    this.extraHeaders,
    this.reasoningEffort,
    this.maxCompletionTokens,
    this.requestPayloadModifier,
    this.responseMessageModifier,
    this.responseChunkMessageModifier,
  });

  /// Request fields added to the body, overriding fields of the same name.
  /// Replaces the config's `extraFields` (Go `WithExtraFields`).
  final Map<String, Object?>? extraFields;

  /// HTTP headers added to the request. Replaces the config's
  /// `customHeaders` (Go `WithExtraHeader`).
  final Map<String, String>? extraHeaders;

  /// How much the model reasons (`reasoning_effort`).
  final ReasoningEffort? reasoningEffort;

  /// The upper bound of generated tokens, reasoning tokens included
  /// (`max_completion_tokens`).
  final int? maxCompletionTokens;

  /// Changes the body just before it is sent.
  final RequestPayloadModifier? requestPayloadModifier;

  /// Changes the message of a complete response.
  final ResponseMessageModifier? responseMessageModifier;

  /// Changes each streamed message.
  final ResponseChunkMessageModifier? responseChunkMessageModifier;

  /// [ChatModelOptions] that carry these options in `extensions`.
  ChatModelOptions toOptions({
    String? model,
    double? temperature,
    int? maxTokens,
    double? topP,
    List<String>? stop,
  }) =>
      ChatModelOptions(
        model: model,
        temperature: temperature,
        maxTokens: maxTokens,
        topP: topP,
        stop: stop,
        extensions: [this],
      );
}
