// Mirror of doc/MIGRATION.md, break 2: DocumentTransformer options.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

/// Drops documents shorter than [minLength].
class ShortDocumentFilter extends DocumentTransformer {
  const ShortDocumentFilter(this.minLength);

  final int minLength;

  // Before 0.9: Future<List<Document>> transform(List<Document> documents)
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async =>
      [
        for (final document in documents)
          if (document.content.length >= minLength) document,
      ];
}
