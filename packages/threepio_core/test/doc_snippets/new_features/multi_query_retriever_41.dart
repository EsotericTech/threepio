// Mirror of doc/NEW_FEATURES.md, "4. Advanced Retrieval Patterns > MultiQueryRetriever".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> multiQueryRetriever(Retriever vectorRetriever, BaseChatModel geminiModel) async {
  final multiQueryRetriever = MultiQueryRetriever(
    baseRetriever: vectorRetriever,
    chatModel: geminiModel,
    numQueries: 3,
    includeOriginalQuery: true,
    queryGenerationPrompt: '''
  Generate {num_queries} different versions of the following question
  to help find relevant documents. Return one query per line.

  Original question: {question}

  Alternative queries:
  ''',
  );

  // The retriever will:
  // 1. Generate 3 alternative queries using the LLM
  // 2. Run all queries (including original) against the base retriever
  // 3. Fuse results using Reciprocal Rank Fusion

  final results = await multiQueryRetriever.retrieve(
    'What are the benefits of renewable energy?',
    options: const RetrieverOptions(topK: 10),
  );
  print('${results.length} documents');

  // With the fusion details: how many of the queries found each document
  final scored = await multiQueryRetriever.retrieveWithScores(
    'What are the benefits of renewable energy?',
  );
  for (final result in scored) {
    print('${result.document.id}: found by ${result.metadata['source_count']} queries');
  }
}
