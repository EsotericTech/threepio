// Mirror of doc/NEW_FEATURES.md, "4. Advanced Retrieval Patterns > RouterRetriever".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> routerRetriever(Embedder embedder, VectorStore technicalDocsStore, VectorStore hrDocsStore, VectorStore legalDocsStore, BaseChatModel geminiModel, Retriever generalRetriever) async {
  // Create specialized retrievers
  final technicalRetriever = VectorRetriever(
    vectorStore: technicalDocsStore,
    embedder: embedder,
  );

  final hrRetriever = VectorRetriever(
    vectorStore: hrDocsStore,
    embedder: embedder,
  );

  final legalRetriever = VectorRetriever(
    vectorStore: legalDocsStore,
    embedder: embedder,
  );

  // Route by keywords
  final keywordRoutingStrategy = KeywordRoutingStrategy(
    routeKeywords: {
      'technical': ['code', 'api', 'programming', 'bug', 'feature'],
      'hr': ['vacation', 'salary', 'benefits', 'leave', 'policy'],
      'legal': ['contract', 'agreement', 'liability', 'compliance'],
    },
    matchThreshold: 1,
  );

  // Or let the LLM route
  final llmRoutingStrategy = LLMRoutingStrategy(
    chatModel: geminiModel,
    routeDescriptions: {
      'technical': 'Technical documentation and API references',
      'hr': 'Human resources policies and employee information',
      'legal': 'Legal documents, contracts, and compliance',
    },
    allowMultiple: true,
  );

  // Create router retriever
  final routerRetriever = RouterRetriever(
    routes: {
      'technical': technicalRetriever,
      'hr': hrRetriever,
      'legal': legalRetriever,
    },
    routingStrategy: llmRoutingStrategy, // or keywordRoutingStrategy
    fallbackRetriever: generalRetriever, // when no route is selected
    allowMultipleRoutes: true,
    maxRoutes: 2,
  );

  final results = await routerRetriever.retrieve(
    'What is the vacation policy for engineering contractors?',
  );

  // Query routed to 'hr' and possibly 'legal'; results of several routes
  // are fused with Reciprocal Rank Fusion
  print('${results.length} documents');
  print(keywordRoutingStrategy.routeKeywords.keys);
}
