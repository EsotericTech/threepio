/// Options for embedding operations
class EmbedderOptions {
  const EmbedderOptions({
    this.model,
    this.extra,
  });

  /// Model name/identifier to use for embedding
  final String? model;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;
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
