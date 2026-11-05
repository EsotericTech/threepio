import 'dart:async';

import '../../schema/document.dart';
import '../document/transformer.dart';
import '../document_loader/document_loader.dart';
import '../document_parser/document_parser.dart';
import '../embedding/embedder.dart';
import '../text_splitter/text_splitter.dart';
import '../vector_store/vector_store.dart';

// `DocumentTransformer` used to be declared in this file. It moved next to
// the other document contracts; importers of this library still get it.
export '../document/transformer.dart';

/// Options for document ingestion.
class IngestionOptions {
  const IngestionOptions({
    this.batchSize = 100,
    this.loaderOptions,
    this.parserOptions,
    this.splitterOptions,
    this.embedderOptions,
    this.vectorStoreOptions,
    this.continueOnError = true,
    this.deduplicateByContent = false,
    this.maxDocuments,
    this.metadata,
  });

  /// Number of documents to process in each batch.
  final int batchSize;

  /// Options for document loading.
  final DocumentLoaderOptions? loaderOptions;

  /// Options for document parsing.
  final DocumentParserOptions? parserOptions;

  /// Options for text splitting.
  final TextSplitterOptions? splitterOptions;

  /// Options for embedding generation.
  final EmbedderOptions? embedderOptions;

  /// Options for vector store insertion.
  final Map<String, dynamic>? vectorStoreOptions;

  /// Whether to continue processing if some documents fail.
  final bool continueOnError;

  /// Whether to deduplicate documents by content hash.
  final bool deduplicateByContent;

  /// Maximum number of documents to process.
  final int? maxDocuments;

  /// Additional metadata to add to all documents.
  final Map<String, dynamic>? metadata;
}

/// Result of document ingestion.
class IngestionResult {
  const IngestionResult({
    required this.documentsProcessed,
    required this.chunksCreated,
    required this.chunksStored,
    this.errors = const [],
    this.duration,
    this.metadata,
  });

  /// Number of source documents processed.
  final int documentsProcessed;

  /// Number of chunks created after splitting.
  final int chunksCreated;

  /// Number of chunks stored in vector store.
  final int chunksStored;

  /// Errors encountered during processing.
  final List<IngestionError> errors;

  /// Total processing duration.
  final Duration? duration;

  /// Additional metadata about the ingestion.
  final Map<String, dynamic>? metadata;

  @override
  String toString() {
    return 'IngestionResult(documents: $documentsProcessed, chunks: $chunksCreated, '
        'stored: $chunksStored, errors: ${errors.length})';
  }
}

/// Progress update during ingestion.
class IngestionProgress {
  const IngestionProgress({
    required this.stage,
    required this.current,
    required this.total,
    this.message,
    this.document,
  });

  /// Current processing stage.
  final IngestionStage stage;

  /// Current item being processed.
  final int current;

  /// Total items to process.
  final int total;

  /// Progress message.
  final String? message;

  /// Current document being processed.
  final Document? document;

  /// Progress percentage (0-100).
  double get percentage => total > 0 ? (current / total) * 100 : 0;
}

/// Stages of the ingestion pipeline.
enum IngestionStage {
  loading,
  parsing,
  splitting,
  embedding,
  storing,
  complete,
}

/// Error during ingestion.
class IngestionError {
  const IngestionError({
    required this.stage,
    required this.message,
    this.documentId,
    this.exception,
  });

  /// Stage where the error occurred.
  final IngestionStage stage;

  /// Error message.
  final String message;

  /// ID of the document that caused the error.
  final String? documentId;

  /// Original exception.
  final Object? exception;

  @override
  String toString() {
    return 'IngestionError(stage: $stage, message: $message'
        '${documentId != null ? ', doc: $documentId' : ''})';
  }
}

/// End-to-end document ingestion pipeline.
///
/// Coordinates loading, parsing, splitting, embedding, and storing
/// documents in a vector store for retrieval.
///
/// Example:
/// ```dart
/// final pipeline = IngestionPipeline(
///   loader: UrlLoader(url: 'https://example.com/docs'),
///   parser: HtmlParser(),
///   splitter: MarkdownSplitter(),
///   embedder: openAIEmbedder,
///   vectorStore: chromaStore,
/// );
///
/// final result = await pipeline.ingest();
/// print('Processed ${result.documentsProcessed} documents');
/// print('Created ${result.chunksStored} chunks');
/// ```
class IngestionPipeline {
  /// Creates an ingestion pipeline.
  IngestionPipeline({
    this.loader,
    this.parser,
    this.splitter,
    this.embedder,
    this.vectorStore,
    this.transformers = const [],
  });

  /// Document loader (optional if documents are provided directly).
  final DocumentLoader? loader;

  /// Document parser (optional if content is already text).
  final DocumentParser? parser;

  /// Text splitter for chunking.
  final TextSplitter? splitter;

  /// Embedder for generating embeddings.
  final Embedder? embedder;

  /// Vector store for persisting documents.
  final VectorStore? vectorStore;

  /// Optional document transformers.
  final List<DocumentTransformer> transformers;

  /// Ingest documents through the pipeline.
  ///
  /// If [documents] is provided, uses those directly instead of loading.
  Future<IngestionResult> ingest({
    List<Document>? documents,
    IngestionOptions? options,
  }) async {
    final opts = options ?? const IngestionOptions();
    final errors = <IngestionError>[];
    final startTime = DateTime.now();

    var docs = documents ?? <Document>[];

    // Stage 1: Load documents
    if (docs.isEmpty && loader != null) {
      try {
        docs = await loader!.load(options: opts.loaderOptions);
      } catch (e) {
        errors.add(IngestionError(
          stage: IngestionStage.loading,
          message: 'Failed to load documents: $e',
          exception: e,
        ));
        if (!opts.continueOnError) {
          return IngestionResult(
            documentsProcessed: 0,
            chunksCreated: 0,
            chunksStored: 0,
            errors: errors,
            duration: DateTime.now().difference(startTime),
          );
        }
      }
    }

    // Limit documents if specified
    if (opts.maxDocuments != null && docs.length > opts.maxDocuments!) {
      docs = docs.take(opts.maxDocuments!).toList();
    }

    final documentsProcessed = docs.length;

    // Stage 2: Apply transformers
    for (final transformer in transformers) {
      try {
        docs = await transformer.transform(docs);
      } catch (e) {
        errors.add(IngestionError(
          stage: IngestionStage.parsing,
          message: 'Transformer failed: $e',
          exception: e,
        ));
        if (!opts.continueOnError) {
          return IngestionResult(
            documentsProcessed: documentsProcessed,
            chunksCreated: 0,
            chunksStored: 0,
            errors: errors,
            duration: DateTime.now().difference(startTime),
          );
        }
      }
    }

    // Stage 3: Split documents into chunks
    var chunks = <Document>[];
    if (splitter != null) {
      try {
        chunks = await splitter!.splitDocuments(docs, options: opts.splitterOptions);
      } catch (e) {
        errors.add(IngestionError(
          stage: IngestionStage.splitting,
          message: 'Failed to split documents: $e',
          exception: e,
        ));
        if (!opts.continueOnError) {
          return IngestionResult(
            documentsProcessed: documentsProcessed,
            chunksCreated: 0,
            chunksStored: 0,
            errors: errors,
            duration: DateTime.now().difference(startTime),
          );
        }
        // Fallback to unsplit documents
        chunks = docs;
      }
    } else {
      chunks = docs;
    }

    // Add global metadata
    if (opts.metadata != null) {
      chunks = chunks.map((chunk) => Document(
        content: chunk.content,
        metadata: {...chunk.metadata, ...opts.metadata!},
        source: chunk.source,
        score: chunk.score,
      )).toList();
    }

    // Deduplicate if requested
    if (opts.deduplicateByContent) {
      chunks = _deduplicateByContent(chunks);
    }

    final chunksCreated = chunks.length;
    var chunksStored = 0;

    // Stage 4 & 5: Embed and store in batches
    if (vectorStore != null) {
      for (var i = 0; i < chunks.length; i += opts.batchSize) {
        final batch = chunks.skip(i).take(opts.batchSize).toList();

        try {
          // Generate embeddings if embedder is provided
          var docsToStore = batch;
          if (embedder != null) {
            final contents = batch.map((d) => d.content).toList();
            final embeddings = await embedder!.embedStrings(
              contents,
              options: opts.embedderOptions,
            );

            // Set embeddings on documents
            docsToStore = <Document>[];
            for (var j = 0; j < batch.length; j++) {
              docsToStore.add(batch[j].copyWith(embedding: embeddings[j]));
            }
          }

          // Add documents to vector store
          await vectorStore!.addDocuments(docsToStore);

          chunksStored += batch.length;
        } catch (e) {
          errors.add(IngestionError(
            stage: IngestionStage.storing,
            message: 'Failed to store batch ${i ~/ opts.batchSize}: $e',
            exception: e,
          ));
          if (!opts.continueOnError) {
            break;
          }
        }
      }
    } else {
      // No vector store, just count as stored
      chunksStored = chunksCreated;
    }

    return IngestionResult(
      documentsProcessed: documentsProcessed,
      chunksCreated: chunksCreated,
      chunksStored: chunksStored,
      errors: errors,
      duration: DateTime.now().difference(startTime),
      metadata: {
        'deduplicated': opts.deduplicateByContent,
        'batch_size': opts.batchSize,
      },
    );
  }

  /// Ingest documents with progress streaming.
  Stream<IngestionProgress> ingestStream({
    List<Document>? documents,
    IngestionOptions? options,
  }) async* {
    final opts = options ?? const IngestionOptions();
    var docs = documents ?? <Document>[];

    // Stage 1: Load
    if (docs.isEmpty && loader != null) {
      yield const IngestionProgress(
        stage: IngestionStage.loading,
        current: 0,
        total: 1,
        message: 'Loading documents...',
      );

      docs = await loader!.load(options: opts.loaderOptions);

      yield IngestionProgress(
        stage: IngestionStage.loading,
        current: 1,
        total: 1,
        message: 'Loaded ${docs.length} documents',
      );
    }

    // Limit documents
    if (opts.maxDocuments != null && docs.length > opts.maxDocuments!) {
      docs = docs.take(opts.maxDocuments!).toList();
    }

    // Stage 2: Transform
    for (var i = 0; i < transformers.length; i++) {
      yield IngestionProgress(
        stage: IngestionStage.parsing,
        current: i,
        total: transformers.length,
        message: 'Applying transformer ${i + 1}/${transformers.length}',
      );
      docs = await transformers[i].transform(docs);
    }

    // Stage 3: Split
    var chunks = <Document>[];
    if (splitter != null) {
      yield IngestionProgress(
        stage: IngestionStage.splitting,
        current: 0,
        total: docs.length,
        message: 'Splitting documents...',
      );

      for (var i = 0; i < docs.length; i++) {
        final docChunks = await splitter!.splitDocuments(
          [docs[i]],
          options: opts.splitterOptions,
        );
        chunks.addAll(docChunks);

        yield IngestionProgress(
          stage: IngestionStage.splitting,
          current: i + 1,
          total: docs.length,
          message: 'Split ${i + 1}/${docs.length} documents',
          document: docs[i],
        );
      }
    } else {
      chunks = docs;
    }

    // Add metadata
    if (opts.metadata != null) {
      chunks = chunks.map((chunk) => Document(
        content: chunk.content,
        metadata: {...chunk.metadata, ...opts.metadata!},
        source: chunk.source,
        score: chunk.score,
      )).toList();
    }

    // Deduplicate
    if (opts.deduplicateByContent) {
      chunks = _deduplicateByContent(chunks);
    }

    // Stage 4 & 5: Embed and store
    if (vectorStore != null) {
      final totalBatches = (chunks.length / opts.batchSize).ceil();

      for (var batchIdx = 0; batchIdx < totalBatches; batchIdx++) {
        final start = batchIdx * opts.batchSize;
        final batch = chunks.skip(start).take(opts.batchSize).toList();

        // Embed
        if (embedder != null) {
          yield IngestionProgress(
            stage: IngestionStage.embedding,
            current: batchIdx,
            total: totalBatches,
            message: 'Embedding batch ${batchIdx + 1}/$totalBatches',
          );

          final contents = batch.map((d) => d.content).toList();
          final embeddings = await embedder!.embedStrings(
            contents,
            options: opts.embedderOptions,
          );

          // Set embeddings on documents
          final docsToStore = <Document>[];
          for (var j = 0; j < batch.length; j++) {
            docsToStore.add(batch[j].copyWith(embedding: embeddings[j]));
          }

          // Store
          yield IngestionProgress(
            stage: IngestionStage.storing,
            current: batchIdx,
            total: totalBatches,
            message: 'Storing batch ${batchIdx + 1}/$totalBatches',
          );

          await vectorStore!.addDocuments(docsToStore);
        } else {
          yield IngestionProgress(
            stage: IngestionStage.storing,
            current: batchIdx,
            total: totalBatches,
            message: 'Storing batch ${batchIdx + 1}/$totalBatches',
          );

          await vectorStore!.addDocuments(batch);
        }
      }
    }

    yield IngestionProgress(
      stage: IngestionStage.complete,
      current: chunks.length,
      total: chunks.length,
      message: 'Ingestion complete: ${chunks.length} chunks processed',
    );
  }

  List<Document> _deduplicateByContent(List<Document> documents) {
    final seen = <int>{};
    final unique = <Document>[];

    for (final doc in documents) {
      final hash = doc.content.hashCode;
      if (!seen.contains(hash)) {
        seen.add(hash);
        unique.add(doc);
      }
    }

    return unique;
  }
}

/// Transformer that adds metadata to all documents.
class MetadataTransformer implements DocumentTransformer {
  /// Creates a metadata transformer.
  MetadataTransformer({
    required this.metadata,
    this.overwrite = false,
  });

  /// Metadata to add.
  final Map<String, dynamic> metadata;

  /// Whether to overwrite existing metadata keys.
  final bool overwrite;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    return documents.map((doc) {
      final newMetadata = overwrite
          ? {...doc.metadata, ...metadata}
          : {...metadata, ...doc.metadata};

      return Document(
        content: doc.content,
        metadata: newMetadata,
        source: doc.source,
        score: doc.score,
      );
    }).toList();
  }
}

/// Transformer that filters documents by content or metadata.
class FilterTransformer implements DocumentTransformer {
  /// Creates a filter transformer.
  FilterTransformer({
    required this.predicate,
  });

  /// Predicate to filter documents.
  final bool Function(Document) predicate;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    return documents.where(predicate).toList();
  }
}

/// Transformer that cleans document content.
class ContentCleanerTransformer implements DocumentTransformer {
  /// Creates a content cleaner transformer.
  ContentCleanerTransformer({
    this.trimWhitespace = true,
    this.normalizeNewlines = true,
    this.removeEmptyLines = false,
    this.maxConsecutiveNewlines = 2,
  });

  /// Whether to trim leading/trailing whitespace.
  final bool trimWhitespace;

  /// Whether to normalize different newline styles.
  final bool normalizeNewlines;

  /// Whether to remove empty lines.
  final bool removeEmptyLines;

  /// Maximum consecutive newlines to allow.
  final int maxConsecutiveNewlines;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    return documents.map((doc) {
      var content = doc.content;

      if (normalizeNewlines) {
        content = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      }

      if (removeEmptyLines) {
        content = content.split('\n').where((line) => line.trim().isNotEmpty).join('\n');
      } else if (maxConsecutiveNewlines > 0) {
        final pattern = '\n' * (maxConsecutiveNewlines + 1);
        final replacement = '\n' * maxConsecutiveNewlines;
        while (content.contains(pattern)) {
          content = content.replaceAll(pattern, replacement);
        }
      }

      if (trimWhitespace) {
        content = content.trim();
      }

      return Document(
        content: content,
        metadata: doc.metadata,
        source: doc.source,
        score: doc.score,
      );
    }).toList();
  }
}
