// Mirror of doc/NEW_FEATURES.md, "Complete RAG Application Example".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'dart:io';

import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// The input of the search tool, decoded from the JSON arguments the model
/// writes.
final class SearchQuery {
  const SearchQuery(this.query);

  factory SearchQuery.fromJson(Map<String, Object?> json) =>
      SearchQuery(json['query']! as String);

  final String query;
}

Future<void> main() async {
  // 1. Configure providers
  final env = Platform.environment;
  final model = GeminiChatModel(
    config: GeminiConfig(apiKey: env['GEMINI_API_KEY']!),
  );
  final embedder = OpenAIEmbedder(
    config: OpenAIConfig(apiKey: env['OPENAI_API_KEY']!),
  );
  final vectorStore = InMemoryVectorStore();

  try {
    // 2. Load, clean and split the documents
    final loaded = await DirectoryLoader(dirPath: './docs', glob: '**/*.md').load();
    final cleaned = await ContentCleanerTransformer().transform(loaded);
    final split = await MarkdownRAGSplitter(includeHeadersInChunks: true).splitDocuments(
      cleaned,
      options: const TextSplitterOptions(chunkSize: 500, chunkOverlap: 50),
    );
    // Both indexes must know a chunk by the same id
    final chunks = [
      for (var i = 0; i < split.length; i++) split[i].copyWith(id: 'chunk_$i'),
    ];

    // 3. Index the chunks for vector search (embed and store) and for
    //    keyword search
    print('Ingesting documents...');
    await VectorStoreIndexer(vectorStore: vectorStore, embedder: embedder)
        .store(RunContext.background(), chunks);
    final keywordSearcher = InMemoryBM25Searcher();
    await keywordSearcher.addDocuments(chunks);
    print('Indexed ${chunks.length} chunks');

    // 4. Hybrid retrieval, reranked for diversity
    final hybridRetriever = HybridRetriever(
      vectorRetriever: VectorRetriever(embedder: embedder, vectorStore: vectorStore),
      keywordSearcher: keywordSearcher,
      vectorWeight: 0.7,
      keywordWeight: 0.3,
    );
    final reranker = MMRReranker(embedder: embedder, lambda: 0.8);

    // 5. The search tool (Eino `utils.InferTool`)
    final searchTool = FunctionTool<SearchQuery, String>(
      name: 'search_knowledge',
      description: 'Search the knowledge base for relevant information',
      params: const ParamsOneOf.params({
        'query': ParameterInfo(type: DataType.string, desc: 'Search query', required: true),
      }),
      fromJson: SearchQuery.fromJson,
      invoke: (ctx, input, options) async {
        final docs = await hybridRetriever.retrieve(
          input.query,
          options: RetrieverOptions(topK: 10, runContext: ctx),
        );
        final reranked = await reranker.rerank(
          input.query,
          docs,
          options: const RerankerOptions(topK: 5),
        );
        return reranked
            .map((r) => '${r.document.metadata['current_header'] ?? 'Document'}:\n'
                '${r.document.content}')
            .join('\n\n---\n\n');
      },
    );

    // 6. The agent (Eino `adk.NewChatModelAgent`) and its runner
    final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
      name: 'rag-assistant',
      description: 'Answers questions from the knowledge base',
      instruction: '''
You are a helpful assistant with access to a knowledge base.
Use the search_knowledge tool to find relevant information before answering questions.
Always cite your sources.
''',
      model: model,
      toolsConfig: adk.ToolsConfig(
        toolsNode: adk.ToolsNodeConfig(tools: [searchTool]),
      ),
    ));
    final runner = adk.Runner(agent: agent);

    // 7. Run a conversation; the questions and answers are kept as history
    print('\nRAG Assistant ready. Type your questions:');
    final history = <Message>[];
    while (true) {
      stdout.write('\nYou: ');
      final input = stdin.readLineSync();
      if (input == null || input.isEmpty) break;
      history.add(Message.user(input));

      final events = runner.run(RunContext.background(), [...history]);
      for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
        if (e.error != null) {
          print('Error: ${e.error}');
          continue;
        }
        final message = await adk.getMessageFromEvent(e);
        if (message == null || message.role != RoleType.assistant) continue;
        if (message.toolCalls?.isNotEmpty ?? false) continue;
        print('\nAssistant: ${message.content}');
        history.add(message);
      }
    }
  } finally {
    model.dispose();
    embedder.dispose();
  }
}
