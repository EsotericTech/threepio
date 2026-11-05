import '../../schema/document.dart';
import '../document/transformer.dart';

/// Options for text splitting operations
class TextSplitterOptions {
  const TextSplitterOptions({
    this.chunkSize = 1000,
    this.chunkOverlap = 200,
    this.keepSeparator = false,
    this.extra,
  });

  /// Maximum size of each chunk in characters
  final int chunkSize;

  /// Number of characters to overlap between chunks
  final int chunkOverlap;

  /// Whether to keep the separator in the chunks
  final bool keepSeparator;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// Validate that options are reasonable
  void validate() {
    if (chunkSize <= 0) {
      throw ArgumentError('chunkSize must be positive');
    }
    if (chunkOverlap < 0) {
      throw ArgumentError('chunkOverlap cannot be negative');
    }
    if (chunkOverlap >= chunkSize) {
      throw ArgumentError(
        'chunkOverlap ($chunkOverlap) must be less than chunkSize ($chunkSize)',
      );
    }
  }
}

/// Interface for splitting text into smaller chunks
///
/// Text splitters break large documents into smaller pieces that fit
/// within model context windows or embedding size limits. They try to
/// preserve semantic boundaries when possible.
///
/// Example usage:
/// ```dart
/// final splitter = RecursiveCharacterTextSplitter();
///
/// // Split text
/// final text = 'Long document content...';
/// final chunks = splitter.splitText(
///   text,
///   options: TextSplitterOptions(
///     chunkSize: 500,
///     chunkOverlap: 50,
///   ),
/// );
///
/// print('Created ${chunks.length} chunks');
///
/// // Split documents
/// final documents = [
///   Document.simple('Document 1 content...'),
///   Document.simple('Document 2 content...'),
/// ];
///
/// final splitDocs = await splitter.splitDocuments(documents);
/// ```
///
/// A splitter is also a [DocumentTransformer], Eino's contract for everything
/// that turns documents into documents, and can be used wherever one is
/// expected: see [transform] and [withOptions].
abstract class TextSplitter implements DocumentTransformer {
  /// Split a single text string into chunks
  ///
  /// Returns a list of text chunks, each respecting the configured
  /// chunk size and overlap parameters.
  List<String> splitText(
    String text, {
    TextSplitterOptions? options,
  });

  /// Split multiple documents into chunks
  ///
  /// Each document is split individually, preserving metadata.
  /// Returns a list of new documents, one per chunk.
  Future<List<Document>> splitDocuments(
    List<Document> documents, {
    TextSplitterOptions? options,
  });

  /// Splits [documents] into chunks: [splitDocuments] under the name of the
  /// [DocumentTransformer] contract.
  ///
  /// The chunk size and the other [TextSplitterOptions] of the call are taken
  /// from the extensions of [options],
  /// `TransformerOptions(extensions: [TextSplitterOptions(chunkSize: 500)])`,
  /// and are the defaults when there are none. Use [withOptions] to fix them
  /// once instead of passing them with every call.
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) =>
      splitDocuments(
        documents,
        options: options?.extension<TextSplitterOptions>(),
      );

  /// A transformer that splits with this splitter and [options].
  ///
  /// This is the form to give to a pipeline or a graph, which call
  /// `transform` without knowing that they are talking to a splitter:
  ///
  /// ```dart
  /// final chunker = RecursiveCharacterTextSplitter()
  ///     .withOptions(const TextSplitterOptions(chunkSize: 500, chunkOverlap: 50));
  /// final chunks = await chunker.transform(documents);
  /// ```
  ///
  /// [TextSplitterOptions] among the extensions of a call still take
  /// precedence over [options].
  DocumentTransformer withOptions(TextSplitterOptions options) =>
      _SplitterWithOptions(this, options);

  /// Create metadata for a chunk
  ///
  /// Generates appropriate metadata for a document chunk,
  /// including position, parent document info, etc.
  Map<String, dynamic> createChunkMetadata({
    required Document originalDoc,
    required int chunkIndex,
    required int totalChunks,
    int? startPosition,
    int? endPosition,
  }) {
    return {
      ...originalDoc.metadata,
      'chunk_index': chunkIndex,
      'total_chunks': totalChunks,
      'parent_id': originalDoc.id,
      if (startPosition != null) 'start_position': startPosition,
      if (endPosition != null) 'end_position': endPosition,
    };
  }
}

/// A [TextSplitter] together with the options it splits with.
final class _SplitterWithOptions extends DocumentTransformer {
  const _SplitterWithOptions(this._splitter, this._options);

  final TextSplitter _splitter;
  final TextSplitterOptions _options;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) =>
      _splitter.splitDocuments(
        documents,
        options: options?.extension<TextSplitterOptions>() ?? _options,
      );
}
