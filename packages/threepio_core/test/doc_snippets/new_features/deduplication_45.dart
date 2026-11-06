// Mirror of doc/NEW_FEATURES.md, "4. Advanced Retrieval Patterns > Deduplication Strategies".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> deduplication(Retriever vectorRetriever, KeywordSearcher keywordSearcher, List<ScoredDocument> scoredResults) async {
  // By document ID
  const idDedup = IdDeduplication(
    useContentHashAsFallback: true,
  );

  // By content
  const contentDedup = ContentDeduplication(
    normalizeWhitespace: true,
    caseSensitive: false,
  );

  // By custom key (the extractor gets the scored document)
  final keyDedup = KeyDeduplication<String>(
    keyExtractor: (scored) => scored.document.metadata['source'] as String?,
  );

  // Composite (apply multiple strategies)
  const compositeDedup = CompositeDeduplication([
    IdDeduplication(),
    ContentDeduplication(),
  ]);

  // Use one with a retriever, or on scored documents directly
  final retriever = HybridRetriever(
    vectorRetriever: vectorRetriever,
    keywordSearcher: keywordSearcher,
    deduplicationStrategy: compositeDedup,
  );
  final unique = await keyDedup.deduplicate(scoredResults);
  print([idDedup, contentDedup, retriever, unique.length]);
}
