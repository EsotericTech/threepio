import 'dart:math' as math;

import '../../../schema/document.dart';
import '../../embedding/embedder.dart';
import 'scored_document.dart';

/// Interface for document deduplication strategies.
abstract class DeduplicationStrategy {
  /// Remove duplicate documents from a list.
  ///
  /// Returns a list with duplicates removed, keeping the highest-scored
  /// version of each document.
  Future<List<ScoredDocument>> deduplicate(List<ScoredDocument> documents);
}

/// Deduplicate by document ID.
///
/// The simplest form of deduplication - removes documents with the same ID.
class IdDeduplication implements DeduplicationStrategy {
  const IdDeduplication({
    this.useContentHashAsFallback = true,
  });

  /// If true, use content hash when document ID is null.
  final bool useContentHashAsFallback;

  @override
  Future<List<ScoredDocument>> deduplicate(List<ScoredDocument> documents) async {
    if (documents.isEmpty) return documents;

    final seen = <String>{};
    final result = <ScoredDocument>[];

    // Pre-sort by score descending to keep highest-scored versions
    final sorted = List<ScoredDocument>.from(documents)
      ..sort((a, b) => b.score.compareTo(a.score));

    for (final doc in sorted) {
      String id;
      if (doc.document.id != null) {
        id = doc.document.id!;
      } else if (useContentHashAsFallback) {
        id = doc.document.content.hashCode.toString();
      } else {
        // No deduplication possible without ID
        result.add(doc);
        continue;
      }

      if (!seen.contains(id)) {
        seen.add(id);
        result.add(doc);
      }
    }

    return result;
  }
}

/// Deduplicate by exact content match.
///
/// Removes documents with identical content, keeping the highest-scored version.
class ContentDeduplication implements DeduplicationStrategy {
  const ContentDeduplication({
    this.normalizeWhitespace = true,
    this.caseSensitive = true,
  });

  /// Normalize whitespace before comparison.
  final bool normalizeWhitespace;

  /// Whether comparison is case-sensitive.
  final bool caseSensitive;

  @override
  Future<List<ScoredDocument>> deduplicate(List<ScoredDocument> documents) async {
    if (documents.isEmpty) return documents;

    final seen = <String>{};
    final result = <ScoredDocument>[];

    // Pre-sort by score descending
    final sorted = List<ScoredDocument>.from(documents)
      ..sort((a, b) => b.score.compareTo(a.score));

    for (final doc in sorted) {
      var content = doc.document.content;

      if (normalizeWhitespace) {
        content = content.replaceAll(RegExp(r'\s+'), ' ').trim();
      }

      if (!caseSensitive) {
        content = content.toLowerCase();
      }

      final contentKey = content.hashCode.toString();

      if (!seen.contains(contentKey)) {
        seen.add(contentKey);
        result.add(doc);
      }
    }

    return result;
  }
}

/// Deduplicate by semantic similarity.
///
/// Uses embeddings to identify semantically similar documents and removes
/// near-duplicates based on cosine similarity threshold.
///
/// Example:
/// ```dart
/// final dedup = SemanticDeduplication(
///   embedder: openAIEmbedder,
///   similarityThreshold: 0.95,  // 95% similarity = duplicate
/// );
/// final unique = await dedup.deduplicate(documents);
/// ```
class SemanticDeduplication implements DeduplicationStrategy {
  SemanticDeduplication({
    required this.embedder,
    this.similarityThreshold = 0.95,
    this.useDocumentEmbeddings = true,
  });

  /// Embedder for computing document similarity.
  final Embedder embedder;

  /// Cosine similarity threshold above which documents are considered duplicates.
  /// Default is 0.95 (95% similarity).
  final double similarityThreshold;

  /// If true, use existing document embeddings when available.
  final bool useDocumentEmbeddings;

  @override
  Future<List<ScoredDocument>> deduplicate(List<ScoredDocument> documents) async {
    if (documents.isEmpty) return documents;
    if (documents.length == 1) return documents;

    // Pre-sort by score descending
    final sorted = List<ScoredDocument>.from(documents)
      ..sort((a, b) => b.score.compareTo(a.score));

    // Get or compute embeddings
    final embeddings = await _getEmbeddings(sorted);

    final result = <ScoredDocument>[];
    final keptEmbeddings = <List<double>>[];

    for (var i = 0; i < sorted.length; i++) {
      final doc = sorted[i];
      final embedding = embeddings[i];

      // Check if this document is too similar to any already-kept document
      var isDuplicate = false;

      for (final keptEmbedding in keptEmbeddings) {
        final similarity = _cosineSimilarity(embedding, keptEmbedding);
        if (similarity >= similarityThreshold) {
          isDuplicate = true;
          break;
        }
      }

      if (!isDuplicate) {
        result.add(doc);
        keptEmbeddings.add(embedding);
      }
    }

    return result;
  }

  Future<List<List<double>>> _getEmbeddings(List<ScoredDocument> documents) async {
    // Check if we can use existing embeddings
    if (useDocumentEmbeddings) {
      final hasAllEmbeddings = documents.every(
        (d) => d.document.embedding != null && d.document.embedding!.isNotEmpty,
      );

      if (hasAllEmbeddings) {
        return documents.map((d) => d.document.embedding!).toList();
      }
    }

    // Compute embeddings for all documents
    final contents = documents.map((d) => d.document.content).toList();
    return await embedder.embedStrings(contents);
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have the same length');
    }

    var dotProduct = 0.0;
    var normA = 0.0;
    var normB = 0.0;

    for (var i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denominator = math.sqrt(normA) * math.sqrt(normB);
    if (denominator == 0) return 0.0;

    return dotProduct / denominator;
  }
}

/// Composite deduplication that applies multiple strategies in sequence.
///
/// Useful for applying fast ID-based deduplication first, then more
/// expensive semantic deduplication on remaining documents.
///
/// Example:
/// ```dart
/// final dedup = CompositeDeduplication([
///   IdDeduplication(),
///   ContentDeduplication(),
///   SemanticDeduplication(embedder: embedder, similarityThreshold: 0.9),
/// ]);
/// final unique = await dedup.deduplicate(documents);
/// ```
class CompositeDeduplication implements DeduplicationStrategy {
  const CompositeDeduplication(this.strategies);

  /// Deduplication strategies to apply in order.
  final List<DeduplicationStrategy> strategies;

  @override
  Future<List<ScoredDocument>> deduplicate(List<ScoredDocument> documents) async {
    var result = documents;

    for (final strategy in strategies) {
      result = await strategy.deduplicate(result);
    }

    return result;
  }
}

/// Deduplicate documents by custom key function.
///
/// Allows flexible deduplication based on any document attribute.
///
/// Example:
/// ```dart
/// // Deduplicate by source URL
/// final dedup = KeyDeduplication<String>(
///   keyExtractor: (doc) => doc.document.metadata['source_url'] as String?,
/// );
/// ```
class KeyDeduplication<K> implements DeduplicationStrategy {
  const KeyDeduplication({
    required this.keyExtractor,
  });

  /// Function to extract deduplication key from a document.
  /// Returns null if the document should not be deduplicated by this strategy.
  final K? Function(ScoredDocument doc) keyExtractor;

  @override
  Future<List<ScoredDocument>> deduplicate(List<ScoredDocument> documents) async {
    if (documents.isEmpty) return documents;

    final seen = <K>{};
    final result = <ScoredDocument>[];

    // Pre-sort by score descending
    final sorted = List<ScoredDocument>.from(documents)
      ..sort((a, b) => b.score.compareTo(a.score));

    for (final doc in sorted) {
      final key = keyExtractor(doc);

      if (key == null) {
        // No key, keep the document
        result.add(doc);
        continue;
      }

      if (!seen.contains(key)) {
        seen.add(key);
        result.add(doc);
      }
    }

    return result;
  }
}

/// Extension methods for Document deduplication.
extension DocumentDeduplication on List<Document> {
  /// Deduplicate by document ID.
  List<Document> deduplicateById() {
    final seen = <String>{};
    final result = <Document>[];

    for (final doc in this) {
      final id = doc.id ?? doc.content.hashCode.toString();
      if (!seen.contains(id)) {
        seen.add(id);
        result.add(doc);
      }
    }

    return result;
  }

  /// Deduplicate by content.
  List<Document> deduplicateByContent({bool normalizeWhitespace = true}) {
    final seen = <String>{};
    final result = <Document>[];

    for (final doc in this) {
      var content = doc.content;
      if (normalizeWhitespace) {
        content = content.replaceAll(RegExp(r'\s+'), ' ').trim();
      }

      final contentKey = content.hashCode.toString();
      if (!seen.contains(contentKey)) {
        seen.add(contentKey);
        result.add(doc);
      }
    }

    return result;
  }
}
