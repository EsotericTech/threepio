import '../../schema/document.dart';
import 'retriever.dart';

/// Store for managing parent-child document relationships.
///
/// Used by [ParentRetriever] to retrieve parent documents
/// from child chunk IDs.
abstract class ParentDocumentStore {
  /// Get the parent document for a child chunk.
  Future<Document?> getParent(String childId);

  /// Store a parent document with its child chunks.
  Future<void> storeWithChildren(
    Document parent,
    List<Document> children,
  );

  /// Get all child chunk IDs for a parent.
  Future<List<String>> getChildIds(String parentId);

  /// Check if a child exists.
  Future<bool> hasChild(String childId);
}

/// In-memory implementation of [ParentDocumentStore].
class InMemoryParentDocumentStore implements ParentDocumentStore {
  InMemoryParentDocumentStore();

  /// Map from child ID to parent document
  final _childToParent = <String, Document>{};

  /// Map from parent ID to child IDs
  final _parentToChildren = <String, List<String>>{};

  @override
  Future<Document?> getParent(String childId) async {
    return _childToParent[childId];
  }

  @override
  Future<void> storeWithChildren(
    Document parent,
    List<Document> children,
  ) async {
    final parentId = parent.id ?? parent.content.hashCode.toString();

    final childIds = <String>[];
    for (final child in children) {
      final childId = child.id ?? child.content.hashCode.toString();
      _childToParent[childId] = parent;
      childIds.add(childId);
    }

    _parentToChildren[parentId] = childIds;
  }

  @override
  Future<List<String>> getChildIds(String parentId) async {
    return _parentToChildren[parentId] ?? [];
  }

  @override
  Future<bool> hasChild(String childId) async {
    return _childToParent.containsKey(childId);
  }

  /// Clear all stored documents.
  void clear() {
    _childToParent.clear();
    _parentToChildren.clear();
  }

  /// Get total number of stored relationships.
  int get size => _childToParent.length;
}

/// A retriever that searches over small chunks but returns larger parent documents.
///
/// This hierarchical retrieval pattern improves both precision and context:
/// - Small chunks provide precise matching for specific queries
/// - Parent documents provide broader context for understanding
///
/// Use cases:
/// - Searching through code files (chunks are functions, parents are files)
/// - Document sections (chunks are paragraphs, parents are sections)
/// - FAQ systems (chunks are individual Q&A, parents are topic groups)
///
/// Example:
/// ```dart
/// // Create the parent store
/// final parentStore = InMemoryParentDocumentStore();
///
/// // Create base retriever for chunk search
/// final chunkRetriever = VectorRetriever(
///   embedder: embedder,
///   vectorStore: vectorStore,
/// );
///
/// // Create parent retriever
/// final parentRetriever = ParentRetriever(
///   baseRetriever: chunkRetriever,
///   parentStore: parentStore,
/// );
///
/// // Index documents (typically done during ingestion)
/// for (final doc in documents) {
///   final chunks = splitter.splitDocuments([doc]);
///   await parentStore.storeWithChildren(doc, chunks);
///   // Also add chunks to vector store for searching
/// }
///
/// // Retrieve - searches chunks, returns parents
/// final parents = await parentRetriever.retrieve('specific function name');
/// ```
class ParentRetriever implements Retriever {
  ParentRetriever({
    required this.baseRetriever,
    required this.parentStore,
    this.returnChunks = false,
    this.includeChunkMetadata = true,
    this.deduplicateParents = true,
    this.parentScoreStrategy = ParentScoreStrategy.maxChildScore,
  });

  /// Base retriever for searching chunks.
  final Retriever baseRetriever;

  /// Store for parent-child relationships.
  final ParentDocumentStore parentStore;

  /// If true, return chunks alongside parents.
  final bool returnChunks;

  /// If true, add matched chunk info to parent metadata.
  final bool includeChunkMetadata;

  /// If true, deduplicate parents (when multiple chunks match same parent).
  final bool deduplicateParents;

  /// Strategy for computing parent score from child scores.
  final ParentScoreStrategy parentScoreStrategy;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Retrieve chunks from base retriever
    final chunks = await baseRetriever.retrieve(query, options: options);

    if (chunks.isEmpty) return [];

    if (returnChunks) {
      return chunks;
    }

    // Map chunks to parents
    final parentResults = <String, _ParentResult>{};

    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final chunkId = chunk.id ?? chunk.content.hashCode.toString();

      final parent = await parentStore.getParent(chunkId);
      if (parent == null) {
        // No parent found, include chunk as-is
        final key = 'chunk_$chunkId';
        parentResults[key] = _ParentResult(
          document: chunk,
          matchedChunks: [chunk],
          chunkScores: [chunk.score ?? 0.0],
          chunkRanks: [i + 1],
        );
        continue;
      }

      final parentId = parent.id ?? parent.content.hashCode.toString();

      if (parentResults.containsKey(parentId)) {
        // Add to existing parent result
        parentResults[parentId]!.matchedChunks.add(chunk);
        parentResults[parentId]!.chunkScores.add(chunk.score ?? 0.0);
        parentResults[parentId]!.chunkRanks.add(i + 1);
      } else {
        // New parent
        parentResults[parentId] = _ParentResult(
          document: parent,
          matchedChunks: [chunk],
          chunkScores: [chunk.score ?? 0.0],
          chunkRanks: [i + 1],
        );
      }
    }

    // Compute parent scores and build result list
    final results = parentResults.values.map((result) {
      final score = _computeParentScore(result);

      if (includeChunkMetadata) {
        final metadata = Map<String, dynamic>.from(result.document.metadata);
        metadata['matched_chunks_count'] = result.matchedChunks.length;
        metadata['matched_chunk_ids'] = result.matchedChunks
            .map((c) => c.id ?? c.content.hashCode.toString())
            .toList();
        metadata['parent_score_strategy'] = parentScoreStrategy.name;

        return result.document.copyWith(
          score: score,
          metadata: metadata,
        );
      }

      return result.document.copyWith(score: score);
    }).toList();

    // Sort by score
    results.sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0));

    // Apply topK if specified
    final topK = options?.topK;
    if (topK != null && results.length > topK) {
      return results.take(topK).toList();
    }

    return results;
  }

  double _computeParentScore(_ParentResult result) {
    if (result.chunkScores.isEmpty) return 0.0;

    switch (parentScoreStrategy) {
      case ParentScoreStrategy.maxChildScore:
        return result.chunkScores.reduce((a, b) => a > b ? a : b);

      case ParentScoreStrategy.averageChildScore:
        return result.chunkScores.reduce((a, b) => a + b) / result.chunkScores.length;

      case ParentScoreStrategy.sumChildScore:
        return result.chunkScores.reduce((a, b) => a + b);

      case ParentScoreStrategy.bestRank:
        // Lower rank is better, so we convert to a score
        final bestRank = result.chunkRanks.reduce((a, b) => a < b ? a : b);
        return 1.0 / bestRank;

      case ParentScoreStrategy.matchCount:
        return result.matchedChunks.length.toDouble();
    }
  }
}

/// Strategies for computing parent document scores.
enum ParentScoreStrategy {
  /// Use the highest score among matched chunks.
  maxChildScore,

  /// Use the average score of matched chunks.
  averageChildScore,

  /// Sum scores of all matched chunks.
  sumChildScore,

  /// Use the best (lowest) rank among matched chunks.
  bestRank,

  /// Score based on number of matched chunks.
  matchCount,
}

class _ParentResult {
  _ParentResult({
    required this.document,
    required this.matchedChunks,
    required this.chunkScores,
    required this.chunkRanks,
  });

  final Document document;
  final List<Document> matchedChunks;
  final List<double> chunkScores;
  final List<int> chunkRanks;
}

/// Extension for building parent-child document relationships.
extension ParentRetrieverSetup on ParentDocumentStore {
  /// Index a document with automatic chunking.
  ///
  /// Splits the parent document into chunks, stores the relationship,
  /// and returns the chunks (typically to be added to a vector store).
  Future<List<Document>> indexDocument(
    Document parent,
    List<String> Function(String content) splitter, {
    String? parentIdPrefix,
  }) async {
    final chunks = splitter(parent.content);

    final parentId = parent.id ?? '${parentIdPrefix ?? 'doc'}_${parent.content.hashCode}';
    final parentWithId = parent.copyWith(id: parentId);

    final chunkDocs = chunks.asMap().entries.map((entry) {
      final chunkId = '${parentId}_chunk_${entry.key}';
      return Document(
        id: chunkId,
        content: entry.value,
        metadata: {
          ...parent.metadata,
          'parent_id': parentId,
          'chunk_index': entry.key,
          'total_chunks': chunks.length,
        },
      );
    }).toList();

    await storeWithChildren(parentWithId, chunkDocs);

    return chunkDocs;
  }
}
