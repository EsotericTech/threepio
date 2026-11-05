import '../../core/run_context.dart';
import '../../internal/option_extensions.dart';

/// Options for embedding operations
///
/// Port of eino `embedding.Options`.
class EmbedderOptions {
  const EmbedderOptions({
    this.model,
    this.extra,
    this.runContext,
    this.extensions = const [],
  });

  /// Model name/identifier to use for embedding
  final String? model;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// The context of the run this call belongs to: its cancellation and its
  /// values.
  ///
  /// [Embedder.embedStrings] keeps the signature it had before [RunContext]
  /// existed, so the context travels here. A graph sets it for its embedding
  /// nodes.
  final RunContext? runContext;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines.
  ///
  /// The counterpart of eino's `embedding.WrapImplSpecificOptFn`.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `embedding.GetImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// A copy with the given fields replaced.
  EmbedderOptions copyWith({
    String? model,
    Map<String, dynamic>? extra,
    RunContext? runContext,
    List<Object>? extensions,
  }) =>
      EmbedderOptions(
        model: model ?? this.model,
        extra: extra ?? this.extra,
        runContext: runContext ?? this.runContext,
        extensions: extensions ?? this.extensions,
      );

  /// These options with what [other] sets taking precedence, field by field.
  /// The [extensions] of both are kept, those of [other] first.
  EmbedderOptions merge(EmbedderOptions? other) => other == null
      ? this
      : EmbedderOptions(
          model: other.model ?? model,
          extra: other.extra ?? extra,
          runContext: other.runContext ?? runContext,
          extensions: mergeExtensions(extensions, other.extensions),
        );
}

/// Interface for text embedding
///
/// Converts text strings into dense vector representations (embeddings)
/// that capture semantic meaning. Used for semantic search, similarity
/// comparison, and other NLP tasks.
///
/// Example usage:
/// ```dart
/// final embedder = MyEmbedder();
///
/// // Embed a single text
/// final embeddings = await embedder.embedStrings(['Hello world']);
/// print('Embedding dimension: ${embeddings.first.length}');
///
/// // Embed multiple texts
/// final texts = ['Hello', 'How are you?', 'Goodbye'];
/// final vectors = await embedder.embedStrings(texts);
///
/// // Each text gets its own embedding vector
/// for (var i = 0; i < texts.length; i++) {
///   print('${texts[i]}: ${vectors[i].length} dimensions');
/// }
/// ```
abstract class Embedder {
  /// Convert text strings to embedding vectors
  ///
  /// Returns a list of embedding vectors, one for each input text.
  /// Each embedding is represented as a list of floating-point numbers.
  /// The order of output embeddings matches the order of input texts.
  ///
  /// The [texts] parameter contains the strings to embed.
  /// Options can control the embedding model or other parameters.
  ///
  /// Throws if embedding fails or inputs are invalid.
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  });
}
