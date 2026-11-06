/// Reordering documents so that the best ones are at both ends of the list,
/// where a language model pays the most attention ("lost in the middle").
///
/// Port of eino-ext `components/document/transformer/reranker/score`.
library;

import '../../../schema/document.dart';
import '../../component_type.dart';
import '../transformer.dart';

/// Reorders documents by score: the best first, the second best last, the
/// third best second, the fourth best second to last, and so on, so that the
/// worst end up in the middle.
///
/// Port of eino-ext `score.NewReranker`. Language models use what is at the
/// start and at the end of their context better than what is in the middle
/// (the "primacy and recency effect", https://arxiv.org/abs/2307.03172);
/// this puts the most relevant documents there. Unlike threepio's
/// `ScoreReranker`, which keeps the top documents in score order, nothing is
/// dropped:
///
/// ```dart
/// const reorder = ScoreReorderTransformer();
/// // Scores 0, 1, 2, 3, 4 come out as 4, 2, 0, 1, 3.
/// final ordered = await reorder.transform(retrieved);
/// ```
///
/// The documents are returned as they are (the same objects, unchanged), and
/// the input list is not modified. The sort by score is stable: documents with
/// the same score are ranked in their input order before they are spread to
/// both ends (so equal scores a, b, c, d, e come out as a, c, e, d, b). Go's
/// `sort.Sort` is not stable and may rank equal scores either way.
final class ScoreReorderTransformer
    implements DocumentTransformer, TypedComponent {
  /// A transformer that reads the score from [scoreFieldKey] or, when that
  /// is `null`, from the document's score.
  const ScoreReorderTransformer({this.scoreFieldKey});

  /// The metadata key that holds the score of a document. Port of
  /// `Config.ScoreFieldKey`.
  ///
  /// `null` (the default) means the document's own score: its
  /// [Document.score], else its Eino `_score` metadata entry
  /// ([DocumentMetaX.effectiveScore]; Go's `Document.Score()`), else 0.
  ///
  /// With a key, the score is the entry under it when that is a number,
  /// else 0. Go accepts only a `float64` there; an `int` counts here as the
  /// same number (a score decoded from JSON may come as an `int` in Dart,
  /// where Go always has a `float64`).
  final String? scoreFieldKey;

  /// Port of `score.reranker.GetType`.
  @override
  String get componentTypeName => 'ScoreReranker';

  /// The documents, best ones at both ends and worst in the middle. Port of
  /// `reranker.Transform`.
  ///
  /// A NaN score counts as lower than every other score (Go's comparison
  /// gives no consistent order for it).
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    final length = documents.length;
    final scores = [for (final doc in documents) _scoreOf(doc)];
    final order = List<int>.generate(length, (i) => i)
      ..sort((a, b) {
        final byScore = _compareDescending(scores[a], scores[b]);
        return byScore != 0 ? byScore : a.compareTo(b);
      });

    final result = List<Document?>.filled(length, null);
    for (var i = 0; i < length; i++) {
      final doc = documents[order[i]];
      if (i.isEven) {
        result[i ~/ 2] = doc;
      } else {
        result[length - 1 - i ~/ 2] = doc;
      }
    }
    return [for (final doc in result) doc!];
  }

  /// Port of the score getter `NewReranker` builds.
  double _scoreOf(Document doc) {
    final key = scoreFieldKey;
    if (key == null) return doc.effectiveScore ?? 0;
    return switch (doc.metadata[key]) {
      final num score => score.toDouble(),
      _ => 0,
    };
  }

  /// Higher scores first; NaN after every number.
  static int _compareDescending(double a, double b) {
    if (a > b) return -1;
    if (a < b) return 1;
    if (a.isNaN) return b.isNaN ? 0 : 1;
    if (b.isNaN) return -1;
    return 0;
  }

  @override
  String toString() => 'ScoreReorderTransformer(scoreFieldKey: $scoreFieldKey)';
}
