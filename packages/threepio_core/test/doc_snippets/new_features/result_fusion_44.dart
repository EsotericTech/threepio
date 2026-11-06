// Mirror of doc/NEW_FEATURES.md, "4. Advanced Retrieval Patterns > Result Fusion Strategies".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> resultFusion(Retriever vectorRetriever, KeywordSearcher keywordSearcher, List<ScoredDocument> firstResults, List<ScoredDocument> secondResults) async {
  // Reciprocal Rank Fusion (default of the multi-query and router retrievers)
  const rrfFusion = ReciprocalRankFusion(k: 60.0);

  // Weighted Score Fusion (default of the hybrid retriever)
  const weightedFusion = WeightedScoreFusion(
    weights: [0.6, 0.4],  // Weights for each result set
    normalizeScores: true,
  );

  // Union Fusion (combine all unique documents)
  const unionFusion = UnionFusion(
    keepHighestScore: true,
  );

  // Use with hybrid retriever
  final retriever = HybridRetriever(
    vectorRetriever: vectorRetriever,
    keywordSearcher: keywordSearcher,
    fusionStrategy: rrfFusion,
  );

  // Or fuse result sets of your own
  final fused = unionFusion.fuse([firstResults, secondResults]);
  print([weightedFusion, retriever, fused.length]);
}
