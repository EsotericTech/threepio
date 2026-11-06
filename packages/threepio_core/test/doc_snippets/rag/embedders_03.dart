// Mirrors "Embedders" of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

Future<void> openAIExample(RunContext ctx, String apiKey) async {
  final openAI = OpenAIEmbedder(
    config: OpenAIConfig(apiKey: apiKey),
    defaultModel: 'text-embedding-3-large',
    dimensions: 1024, // shorter vectors, for the models that support it
  );
  try {
    final vectors = await openAI.embedStrings(
      ['What is Eino?', 'How do I split a PDF?'],
      options: EmbedderOptions(runContext: ctx),
    );
    print('${vectors.length} vectors of ${vectors.first.length} dimensions');
  } finally {
    openAI.dispose();
  }
}

List<Embedder> otherEmbedders(String dashScopeKey, String geminiKey) {
  final dashScope = OpenAIEmbedder.dashScope(
    apiKey: dashScopeKey,
    model: 'text-embedding-v3',
  );

  final gemini = GeminiEmbedder(
    config: GeminiEmbeddingConfig(
      apiKey: geminiKey,
      model: 'gemini-embedding-001',
      taskType: GeminiEmbeddingTaskType.retrievalDocument,
      outputDimensionality: 768,
    ),
  );

  final ollama = OllamaEmbedder(
    config: const OllamaEmbedderConfig(model: 'nomic-embed-text'),
  );
  return [dashScope, gemini, ollama];
}
