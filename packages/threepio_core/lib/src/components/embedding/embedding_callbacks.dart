/// What an embedder reports to callback handlers.
///
/// Port of eino `components/embedding/callback_extra.go`.
library;

import 'package:meta/meta.dart';

import '../../schema/message.dart';
import 'embedder.dart';

/// The settings an embedding call was made with.
///
/// Port of eino `embedding.Config`.
@immutable
final class EmbeddingCallbackConfig {
  /// The settings of a call.
  const EmbeddingCallbackConfig({this.model, this.encodingFormat});

  /// The settings in [options]. [defaultModel] is the model the embedder
  /// uses when the options name none.
  factory EmbeddingCallbackConfig.fromOptions(
    EmbedderOptions? options, {
    String? defaultModel,
    String? encodingFormat,
  }) =>
      EmbeddingCallbackConfig(
        model: options?.model ?? defaultModel,
        encodingFormat: encodingFormat,
      );

  /// The name of the embedding model.
  final String? model;

  /// The format the vectors are requested in, `float` or `base64` for
  /// example.
  final String? encodingFormat;

  @override
  String toString() =>
      'EmbeddingCallbackConfig(model: $model, encodingFormat: $encodingFormat)';
}

/// The input of an embedding call, as callback handlers see it.
///
/// Port of eino `embedding.CallbackInput`.
@immutable
final class EmbeddingCallbackInput {
  /// The input of a call that embeds [texts].
  const EmbeddingCallbackInput({required this.texts, this.config, this.extra});

  /// The texts to embed.
  final List<String> texts;

  /// The settings of the call.
  final EmbeddingCallbackConfig? config;

  /// Whatever else the embedder wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of an embedding call, or returns `null` when it
  /// is not one.
  ///
  /// Port of eino `embedding.ConvCallbackInput`: accepts an
  /// [EmbeddingCallbackInput] or the plain list of texts a graph node
  /// reports.
  static EmbeddingCallbackInput? from(Object? raw) => switch (raw) {
        final EmbeddingCallbackInput input => input,
        final List<String> texts => EmbeddingCallbackInput(texts: texts),
        _ => null,
      };

  @override
  String toString() =>
      'EmbeddingCallbackInput(texts: ${texts.length}, config: $config)';
}

/// The output of an embedding call, as callback handlers see it.
///
/// Port of eino `embedding.CallbackOutput`.
@immutable
final class EmbeddingCallbackOutput {
  /// The output of a call that produced [embeddings].
  const EmbeddingCallbackOutput({
    required this.embeddings,
    this.config,
    this.tokenUsage,
    this.extra,
  });

  /// One vector for each text, in the order of the texts.
  final List<List<double>> embeddings;

  /// The settings of the call.
  final EmbeddingCallbackConfig? config;

  /// The tokens the call used. Embedding has no completion, so only the
  /// prompt and total counts are set.
  final TokenUsage? tokenUsage;

  /// Whatever else the embedder wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of an embedding call, or returns `null` when
  /// it is not one.
  ///
  /// Port of eino `embedding.ConvCallbackOutput`: accepts an
  /// [EmbeddingCallbackOutput] or the plain list of vectors a graph node
  /// reports.
  static EmbeddingCallbackOutput? from(Object? raw) => switch (raw) {
        final EmbeddingCallbackOutput output => output,
        final List<List<double>> embeddings =>
          EmbeddingCallbackOutput(embeddings: embeddings),
        _ => null,
      };

  @override
  String toString() => 'EmbeddingCallbackOutput(embeddings: '
      '${embeddings.length}, config: $config, tokenUsage: $tokenUsage)';
}
