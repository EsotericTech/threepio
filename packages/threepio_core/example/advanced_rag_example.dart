// ignore_for_file: avoid_print

/// Advanced RAG example demonstrating:
/// 1. Document ingestion: Markdown-aware splitting, embedding, storing
/// 2. Vector retrieval
/// 3. Hybrid retrieval (vector + keyword)
/// 4. MMR reranking for diversity
/// 5. Multi-query retrieval (a chat model writes alternative queries)
/// 6. Result fusion (reciprocal rank fusion)
/// 7. Deduplication strategies
///
/// These are threepio's own retrieval components. The ports of Eino's
/// `flow/retriever` (multiquery, parent, router) and `flow/indexer/parent`
/// are `MultiQueryRetriever.fromConfig`, `ParentRetriever.fromConfig`,
/// `RouterRetriever.fromConfig` and `ParentIndexer` in
/// `package:threepio_core/flow.dart`; see doc/RAG.md.
///
/// To run this example (OpenAI for the embeddings, Gemini for the
/// multi-query step):
///
/// ```bash
/// OPENAI_API_KEY=... GEMINI_API_KEY=... dart run example/advanced_rag_example.dart
/// ```
library;

import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> main() async {
  print('=== Advanced RAG Pipeline Example ===\n');

  // Check for API keys
  final geminiKey = Platform.environment['GEMINI_API_KEY'];
  final openaiKey = Platform.environment['OPENAI_API_KEY'];

  if (geminiKey == null ||
      geminiKey.isEmpty ||
      openaiKey == null ||
      openaiKey.isEmpty) {
    stderr.writeln('Set GEMINI_API_KEY and OPENAI_API_KEY to run this example.');
    return;
  }

  // Create components
  final embedder = OpenAIEmbedder(
    config: OpenAIConfig(apiKey: openaiKey),
  );
  final geminiModel = GeminiChatModel(
    config: GeminiConfig(apiKey: geminiKey),
  );
  try {
    await runPipeline(embedder, geminiModel);
  } finally {
    embedder.dispose();
    geminiModel.dispose();
  }
}

/// Indexes three documents and queries them in several ways.
Future<void> runPipeline(Embedder embedder, BaseChatModel chatModel) async {
  final vectorStore = InMemoryVectorStore();

  // Sample documents to index
  const sampleDocs = [
    Document(
      id: 'doc1',
      content: '''
# Introduction to Machine Learning

Machine learning is a subset of artificial intelligence that enables systems
to learn and improve from experience without being explicitly programmed.
It focuses on developing algorithms that can access data and use it to learn
for themselves.

## Types of Machine Learning

1. **Supervised Learning**: Learning from labeled data
2. **Unsupervised Learning**: Finding patterns in unlabeled data
3. **Reinforcement Learning**: Learning through trial and error
''',
      metadata: {'source': 'ml_intro.md', 'category': 'tutorial'},
    ),
    Document(
      id: 'doc2',
      content: '''
# Deep Learning Fundamentals

Deep learning is a machine learning technique that teaches computers to do
what comes naturally to humans: learn by example. Deep learning uses neural
networks with many layers (hence "deep") to progressively extract higher-level
features from raw input.

## Neural Network Architecture

- **Input Layer**: Receives the raw data
- **Hidden Layers**: Process and transform data
- **Output Layer**: Produces the final prediction

## Common Architectures

- Convolutional Neural Networks (CNNs) for images
- Recurrent Neural Networks (RNNs) for sequences
- Transformers for natural language processing
''',
      metadata: {'source': 'deep_learning.md', 'category': 'tutorial'},
    ),
    Document(
      id: 'doc3',
      content: '''
# Natural Language Processing

Natural Language Processing (NLP) is a field of AI that gives machines the
ability to read, understand, and derive meaning from human languages.

## Key NLP Tasks

- **Text Classification**: Categorizing text into predefined classes
- **Named Entity Recognition**: Identifying entities like names, places
- **Sentiment Analysis**: Determining emotional tone
- **Machine Translation**: Converting text between languages
- **Question Answering**: Answering questions based on context

## Modern NLP Models

Large Language Models (LLMs) like GPT and BERT have revolutionized NLP,
achieving state-of-the-art results on many benchmarks.
''',
      metadata: {'source': 'nlp_overview.md', 'category': 'overview'},
    ),
  ];

  // === 1. Document Ingestion Pipeline ===
  print('1. Running Ingestion Pipeline...\n');

  // Each chunk starts with its header and the header breadcrumbs (both on
  // by default).
  final splitter = MarkdownRAGSplitter();

  // Split documents with options
  final chunks = await splitter.splitDocuments(
    sampleDocs,
    options: const TextSplitterOptions(
      chunkSize: 300,
      chunkOverlap: 50,
    ),
  );
  print('   Split ${sampleDocs.length} documents into ${chunks.length} chunks');

  // Embed and store
  for (final chunk in chunks) {
    final embedding = await embedder.embedStrings([chunk.content]);
    await vectorStore.addDocuments([
      chunk.copyWith(embedding: embedding.first),
    ]);
  }
  print('   Indexed ${chunks.length} chunks in vector store\n');

  // === 2. Basic Vector Retrieval ===
  print('2. Basic Vector Retrieval...\n');

  final vectorRetriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
    defaultTopK: 5,
  );

  const query = 'What are the different types of neural networks?';
  print('   Query: "$query"\n');

  final vectorResults = await vectorRetriever.retrieve(query);
  print('   Found ${vectorResults.length} results:');
  for (var i = 0; i < vectorResults.length && i < 3; i++) {
    final doc = vectorResults[i];
    print('   ${i + 1}. ${_truncate(doc.content, 80)}');
    print('      Source: ${doc.metadata['source']}');
  }

  // === 3. Hybrid Retrieval ===
  print('\n3. Hybrid Retrieval (Vector + Keyword)...\n');

  // Create keyword searcher
  final keywordSearcher = InMemoryBM25Searcher();
  await keywordSearcher.addDocuments(chunks);

  final hybridRetriever = HybridRetriever(
    vectorRetriever: vectorRetriever,
    keywordSearcher: keywordSearcher,
    vectorWeight: 0.7,
    keywordWeight: 0.3,
    // The scores of both sides are normalized before they are combined (the
    // default, normalizeScores: true).
  );

  final hybridResults = await hybridRetriever.retrieve(query);
  print('   Hybrid results:');
  for (var i = 0; i < hybridResults.length && i < 3; i++) {
    final doc = hybridResults[i];
    print('   ${i + 1}. ${_truncate(doc.content, 80)}');
  }

  // === 4. MMR Reranking for Diversity ===
  print('\n4. MMR Reranking for Diversity...\n');

  final reranker = MMRReranker(
    embedder: embedder,
    lambda: 0.7, // Balance relevance (1.0) vs diversity (0.0)
  );

  final rerankedResults = await reranker.rerank(
    query,
    hybridResults,
    options: const RerankerOptions(topK: 5),
  );

  print('   Reranked results (optimized for diversity):');
  for (var i = 0; i < rerankedResults.length && i < 3; i++) {
    final result = rerankedResults[i];
    print('   ${i + 1}. Score: ${result.score.toStringAsFixed(3)}');
    print('      ${_truncate(result.document.content, 70)}');
  }

  // === 5. Multi-Query Retrieval ===
  print('\n5. Multi-Query Retrieval...\n');

  // The chat model writes three alternative queries; the original query is
  // searched too (the defaults numQueries: 3, includeOriginalQuery: true).
  final multiQueryRetriever = MultiQueryRetriever(
    baseRetriever: vectorRetriever,
    chatModel: chatModel,
  );

  print('   Original query: "$query"');
  print('   Generating alternative queries...');

  final multiResults = await multiQueryRetriever.retrieve(query);
  print('   Found ${multiResults.length} unique results from multiple queries\n');

  // === 6. Result Fusion Strategies ===
  print('6. Result Fusion Strategies...\n');

  // Reciprocal Rank Fusion (k: 60, the default)
  const rrfFusion = ReciprocalRankFusion();

  // Simulate two result sets
  final resultSet1 = vectorResults.take(5).toList();
  final resultSet2 = await keywordSearcher.search(query, topK: 5);

  final scoredSet1 = resultSet1.asMap().entries.map((e) =>
    ScoredDocument(document: e.value, score: 1.0 / (e.key + 1))
  ).toList();

  final scoredSet2 = resultSet2.asMap().entries.map((e) =>
    ScoredDocument(document: e.value, score: 1.0 / (e.key + 1))
  ).toList();

  final fusedResults = rrfFusion.fuse([scoredSet1, scoredSet2]);
  print('   RRF Fusion combined ${resultSet1.length + resultSet2.length} results');
  print('   After deduplication: ${fusedResults.length} unique results\n');

  // === 7. Deduplication Strategies ===
  print('7. Deduplication Strategies...\n');

  // By document ID, with a content hash for documents without one (the
  // default, useContentHashAsFallback: true)
  const idDedup = IdDeduplication();
  final dedupedById = await idDedup.deduplicate(fusedResults);
  print('   ID deduplication: ${fusedResults.length} -> ${dedupedById.length}');

  // By content, whitespace normalized (the default) and case ignored
  const contentDedup = ContentDeduplication(caseSensitive: false);
  final dedupedByContent = await contentDedup.deduplicate(fusedResults);
  print('   Content deduplication: ${fusedResults.length} -> ${dedupedByContent.length}');

  print('\n=== RAG Pipeline Complete ===');
}

String _truncate(String text, int maxLength) {
  final cleaned = text.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.length <= maxLength) return cleaned;
  return '${cleaned.substring(0, maxLength)}...';
}
