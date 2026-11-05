/// An [Indexer] for the vector stores threepio already has.
library;

import 'package:uuid/uuid.dart';

import '../../core/run_context.dart';
import '../../schema/document.dart';
import '../component_type.dart';
import '../embedding/embedder.dart';
import '../vector_store/vector_store.dart';
import 'indexer.dart';

/// Stores documents in a [VectorStore] through the [Indexer] contract.
///
/// [VectorStore] is threepio's own storage interface; Eino has [Indexer] for
/// writing and `Retriever` for reading. This adapter is the writing half, and
/// `VectorRetriever` the reading half, of any vector store:
///
/// ```dart
/// final store = InMemoryVectorStore();
/// final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);
/// final ids = await indexer.store(ctx, documents);
/// ```
///
/// For every call it
///
/// 1. gives each document without an id a new one,
/// 2. computes the vectors of the documents that have none, with the embedder
///    of the call's options or else the one given here,
/// 3. records the sub-indexes of the options in the metadata of the documents
///    (`Document.subIndexes`), and
/// 4. hands the documents to the store in one `addDocuments` call.
final class VectorStoreIndexer implements Indexer, TypedComponent {
  /// An indexer that writes to [vectorStore].
  ///
  /// [embedder] computes the vectors of documents that come without one. It
  /// may be left out when every document already has its vector or when each
  /// call brings an embedder in its options. [idGenerator] makes the id of a
  /// document that has none; the default is a random UUID.
  VectorStoreIndexer({
    required this.vectorStore,
    this.embedder,
    String Function(Document document)? idGenerator,
  }) : _idGenerator = idGenerator ?? _randomId;

  /// The store the documents are written to.
  final VectorStore vectorStore;

  /// The embedder used when a call does not bring its own.
  final Embedder? embedder;

  final String Function(Document document) _idGenerator;

  static const _uuid = Uuid();

  static String _randomId(Document document) => _uuid.v4();

  @override
  String get componentTypeName => 'VectorStore';

  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async {
    ctx.cancelToken.throwIfCancelled();
    if (docs.isEmpty) return [];

    final subIndexes = options?.subIndexes;
    var prepared = [
      for (final doc in docs)
        _withSubIndexes(
          doc.id == null ? doc.copyWith(id: _idGenerator(doc)) : doc,
          subIndexes,
        ),
    ];

    prepared = await _embedMissing(ctx, prepared, options?.embedding);
    ctx.cancelToken.throwIfCancelled();

    final index = options?.index;
    await vectorStore.addDocuments(
      prepared,
      // The store interface knows nothing about indexes. A store that has
      // them finds the name here.
      options: index == null ? null : VectorStoreOptions(extra: {'index': index}),
    );

    return [for (final doc in prepared) doc.id!];
  }

  static Document _withSubIndexes(Document doc, List<String>? subIndexes) =>
      subIndexes == null || subIndexes.isEmpty
          ? doc
          : doc.withSubIndexes(subIndexes);

  Future<List<Document>> _embedMissing(
    RunContext ctx,
    List<Document> docs,
    Embedder? embedderOfCall,
  ) async {
    // A vector that is only in the metadata (`Document.withDenseVector` on a
    // document that came from JSON) counts: the store reads the field.
    final withVectors = [
      for (final doc in docs)
        if (_hasEmbedding(doc))
          doc
        else
          doc.copyWith(embedding: doc.denseVector),
    ];
    final missing = [
      for (final (index, doc) in withVectors.indexed)
        if (!_hasEmbedding(doc)) index,
    ];
    if (missing.isEmpty) return withVectors;

    final embedder = embedderOfCall ?? this.embedder;
    if (embedder == null) {
      throw StateError(
        'VectorStoreIndexer has no embedder, and ${missing.length} of the '
        '${docs.length} documents to store have no embedding. Give the '
        'indexer an embedder, pass one in IndexerOptions.embedding, or embed '
        'the documents first.',
      );
    }

    final vectors = await embedder.embedStrings(
      [for (final index in missing) withVectors[index].content],
      options: EmbedderOptions(runContext: ctx),
    );
    if (vectors.length != missing.length) {
      throw StateError(
        'The embedder returned ${vectors.length} vectors for '
        '${missing.length} texts.',
      );
    }

    for (final (position, index) in missing.indexed) {
      withVectors[index] =
          withVectors[index].copyWith(embedding: vectors[position]);
    }
    return withVectors;
  }

  static bool _hasEmbedding(Document doc) {
    final embedding = doc.embedding;
    return embedding != null && embedding.isNotEmpty;
  }
}
