import '../../schema/document.dart';

/// Options for document loading operations
class DocumentLoaderOptions {
  const DocumentLoaderOptions({
    this.encoding = 'utf-8',
    this.metadata,
    this.extra,
  });

  /// Text encoding to use when reading files
  final String encoding;

  /// Additional metadata to add to loaded documents
  final Map<String, dynamic>? metadata;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;
}

/// Interface for loading documents from various sources
///
/// Document loaders read content from files, URLs, databases, or other
/// sources and convert them into Document objects for processing.
///
/// Example usage:
/// ```dart
/// final loader = TextLoader(filePath: 'document.txt');
///
/// // Load documents
/// final documents = await loader.load();
///
/// for (final doc in documents) {
///   print('Content: ${doc.content}');
///   print('Source: ${doc.source?.uri}');
/// }
/// ```
abstract class DocumentLoader {
  /// Load documents from the source
  ///
  /// Returns a list of documents loaded from the configured source.
  /// Options can control encoding, add metadata, or pass loader-specific parameters.
  ///
  /// Throws if loading fails or the source is inaccessible.
  Future<List<Document>> load({
    DocumentLoaderOptions? options,
  });

  /// Load documents lazily as a stream
  ///
  /// Useful for large sources where loading all documents at once
  /// would consume too much memory. Documents are loaded on-demand.
  Stream<Document> loadLazy({
    DocumentLoaderOptions? options,
  });
}
