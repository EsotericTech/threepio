import '../../schema/document.dart';

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
abstract class TextSplitter {
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
