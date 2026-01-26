import '../../../schema/document.dart';

/// A document with an associated relevance score.
///
/// Used in retrieval fusion to track documents with their scores
/// from different retrieval sources before final ranking.
class ScoredDocument {
  const ScoredDocument({
    required this.document,
    required this.score,
    this.sourceId,
    this.rank,
    this.metadata = const {},
  });

  /// The retrieved document.
  final Document document;

  /// The relevance score (higher is better).
  final double score;

  /// Optional identifier for the source retriever.
  final String? sourceId;

  /// Optional rank from the source retriever (1-indexed).
  final int? rank;

  /// Additional metadata about this result.
  final Map<String, dynamic> metadata;

  /// Creates a copy with updated fields.
  ScoredDocument copyWith({
    Document? document,
    double? score,
    String? sourceId,
    int? rank,
    Map<String, dynamic>? metadata,
  }) {
    return ScoredDocument(
      document: document ?? this.document,
      score: score ?? this.score,
      sourceId: sourceId ?? this.sourceId,
      rank: rank ?? this.rank,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Creates a ScoredDocument from a document with an optional score.
  factory ScoredDocument.fromDocument(
    Document doc, {
    double? score,
    String? sourceId,
    int? rank,
  }) {
    return ScoredDocument(
      document: doc,
      score: score ?? doc.score ?? 0.0,
      sourceId: sourceId,
      rank: rank,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScoredDocument &&
        other.document.id == document.id &&
        other.score == score;
  }

  @override
  int get hashCode => Object.hash(document.id, score);

  @override
  String toString() {
    return 'ScoredDocument(score: $score, sourceId: $sourceId, '
        'id: ${document.id}, content: ${document.content.take(50)}...)';
  }
}

extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
