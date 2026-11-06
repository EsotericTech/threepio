// What the P11 port (eino-ext wave 1) exports, and from which library. The
// file compiles only while every name used below is exported where it says.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:threepio_core/components.dart' as components;
import 'package:threepio_core/io.dart' as io;
import 'package:threepio_core/threepio_core.dart' as umbrella;

void main() {
  test('the umbrella exports the providers and embedders', () {
    expect(
      <Type>[
        umbrella.OpenAIRequestOptions,
        umbrella.OpenAIModality,
        umbrella.OpenAIAudioConfig,
        umbrella.OpenAICompatibleChatModel,
        umbrella.OpenAICompatibleConfig,
        umbrella.OpenAICompatiblePreset,
        umbrella.DeepSeekThinking,
        umbrella.ProviderErrorDetail,
        umbrella.OpenRouterCacheControl,
        umbrella.OpenRouterCacheControlTtl,
        umbrella.ReasoningSummary,
        umbrella.ClaudeChatModel,
        umbrella.ClaudeConfig,
        umbrella.ClaudeRequestOptions,
        umbrella.ClaudeException,
        umbrella.OllamaChatModel,
        umbrella.OllamaConfig,
        umbrella.OllamaRequestOptions,
        umbrella.OllamaException,
        umbrella.OllamaEmbedder,
        umbrella.GeminiRequestOptions,
        umbrella.GeminiEmbedder,
        umbrella.GeminiCachedContent,
        umbrella.EmbeddingEncodingFormat,
      ],
      hasLength(24),
    );
    expect(umbrella.openAIRequestIdKey, 'openai-request-id');
    expect(umbrella.isRetryableHttpStatus(429), isTrue);
    expect(umbrella.looksLikeModelUnavailable(404, ''), isTrue);
  });

  test('components.dart exports the platform-neutral parts', () {
    expect(
      <Type>[
        components.CachingEmbedder,
        components.EmbeddingCache,
        components.InMemoryEmbeddingCache,
        components.SimpleCacheKeyGenerator,
        components.HashCacheKeyGenerator,
        components.McpClient,
        components.McpToolkit,
        components.McpSession,
        components.StreamableHttpTransport,
        components.SseTransport,
        components.McpPromptTemplate,
      ],
      hasLength(11),
    );
    // The umbrella re-exports components.dart.
    expect(umbrella.McpToolkit, components.McpToolkit);
  });

  test('io.dart exports the dart:io parts', () {
    expect(
      <Type>[
        io.LocalFilesystemBackend,
        io.LocalMultiModalReadConfig,
        io.LocalShell,
        io.FileEmbeddingCache,
        io.StdioTransport,
      ],
      hasLength(5),
    );
  });

  test('the existing provider constructors still work as before', () {
    final openRouter = umbrella.OpenRouterChatModel(
      config: const umbrella.OpenRouterConfig(apiKey: 'test-key'),
    );
    expect(openRouter.componentTypeName, 'OpenRouter');
    openRouter.dispose();
    final openAI = umbrella.OpenAIChatModel(
      config: const umbrella.OpenAIConfig(apiKey: 'test-key'),
    );
    expect(openAI.componentTypeName, 'OpenAI');
    openAI.dispose();
    final gemini = umbrella.GeminiChatModel(
      config: const umbrella.GeminiConfig(apiKey: 'test-key'),
    );
    expect(gemini.componentTypeName, 'Gemini');
    gemini.dispose();
    expect(
      const umbrella.OpenRouterRequestOptions(
        reasoningEffort: umbrella.ReasoningEffort.low,
      ).toRequestFields()['reasoning'],
      {'effort': 'low'},
    );
  });
}
