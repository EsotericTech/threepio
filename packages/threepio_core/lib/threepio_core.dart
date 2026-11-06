/// Threepio Core - LLM Application Development Framework for Flutter/Dart
///
/// A port of the CloudWeGo Eino framework, providing component abstractions,
/// composition framework, and streaming infrastructure for building LLM applications.
library threepio_core;

// Callbacks (port of the Eino packages `callbacks` and `utils/callbacks`),
// the older callback API, and tracing (OTLP, Langfuse).
//
// The five functions a component fires its callbacks with are left out:
// `onStart`, `onEnd` and `onError` are names that classes all over an
// application inherit (from `BaseCallbackHandler`, among others), and an
// imported top-level function takes precedence over an inherited member in
// Dart, so exporting them here could change what existing code calls. Code
// that fires callbacks imports `package:threepio_core/callbacks.dart`.
export 'callbacks.dart'
    hide
        onEnd,
        onEndWithCopies,
        onEndWithStreamOutput,
        onError,
        onStart,
        onStartWithStreamInput;
export 'src/components/embedding/embedder.dart';
export 'src/components/embedding/openai_embedder.dart';
// Component exports
export 'src/components/document_loader/document_loader_exports.dart';
export 'src/components/document_parser/document_parser_exports.dart';
export 'src/components/model/base_chat_model.dart';
export 'src/components/model/cancel_token.dart';
export 'src/components/model/chat_model_options.dart';
export 'src/components/model/model_errors.dart';
export 'src/components/model/resilient_chat_models.dart';
export 'src/components/pipeline/pipeline_exports.dart';
export 'src/components/prompt/chat_template.dart';
export 'src/components/reranker/reranker_exports.dart';
export 'src/components/retriever/retriever_exports.dart';
export 'src/components/text_splitter/text_splitter_exports.dart';
export 'src/components/tool/invokable_tool.dart';
export 'src/components/tool/agent.dart';
export 'src/components/tool/tool_executor.dart';
export 'src/components/tool/tool_registry.dart';
export 'src/components/vector_store/vector_store_exports.dart';
// Orchestration: runnables, lambdas, graphs, chains and the tools node (port
// of the Eino package `compose`).
export 'compose.dart';
// Retrieval flows: the multi-query, parent and router retrievers as Eino
// builds them, the parent indexer and concurrent retrieval (port of the Eino
// package `flow`).
export 'flow.dart';
// The state graph that predates the compose port. Its five checkpoint names
// that compose uses for its own contracts are left out here; they are in
// `package:threepio_core/legacy_graph.dart`.
export 'src/graph/graph_exports.dart'
    hide
        CheckpointSerializer,
        CheckpointStore,
        FileCheckpointStore,
        InMemoryCheckpointStore,
        JsonCheckpointSerializer;
// Advanced Agent Development Kit exports
export 'src/adk/adk_exports.dart';
// Memory and persistence exports
export 'src/memory/memory_exports.dart';
// Structured output parsing exports
export 'src/output_parser/output_parser_exports.dart';
// Component contracts, options, callback payloads, tool utilities and the
// platform-neutral implementations (port of the Eino package `components`).
// The individual component exports above stay: they add what `components.dart`
// leaves out (providers, file loaders, the pre-ADK tool registry and agent).
export 'components.dart';
// Schema exports (messages, tools, documents, templates, concat, registry),
// the core run context and the exception base types
export 'schema.dart';
// Streaming exports
export 'streaming.dart';

// Provider exports
export 'src/components/model/providers/gemini/gemini_chat_model.dart';
export 'src/components/model/providers/gemini/gemini_config.dart';
export 'src/components/model/providers/gemini/gemini_message_extras.dart'
    hide
        geminiVideoMetaDataKey,
        geminiThoughtSignatureKey,
        geminiSpecialPartKey,
        geminiGroundMetadataKey,
        geminiDisplayNameKey,
        geminiThoughtSignatureBase64;
export 'src/components/model/providers/gemini/gemini_options.dart';
export 'src/components/model/providers/openai/openai_chat_model.dart'
    hide OpenAIExceptionErrors;
export 'src/components/model/providers/openai/openai_converters.dart'
    show reasoningDetailsKey, openAIGeneratedAudioIdKey;
export 'src/components/model/providers/openai/openai_config.dart';
export 'src/components/model/providers/openai/openai_options.dart';
export 'src/components/model/providers/openrouter/openrouter_cache_control.dart';
export 'src/components/model/providers/openrouter/openrouter_chat_model.dart';
export 'src/components/model/providers/openrouter/openrouter_config.dart';
export 'src/components/model/providers/openrouter/openrouter_options.dart';
// OpenAI-compatible endpoints (DeepSeek, Qwen, Ark, …), Claude and Ollama
export 'src/components/model/openai_compatible/client.dart'
    show openAIRequestIdKey, openAIAudioTranscriptKey;
export 'src/components/model/openai_compatible/errors.dart';
export 'src/components/model/openai_compatible/presets.dart';
export 'src/components/model/providers/claude/claude_chat_model.dart';
export 'src/components/model/providers/claude/claude_config.dart';
export 'src/components/model/providers/claude/claude_message_extras.dart';
export 'src/components/model/providers/claude/claude_options.dart';
export 'src/components/model/providers/ollama/ollama_chat_model.dart';
export 'src/components/model/providers/ollama/ollama_config.dart';
export 'src/components/model/providers/ollama/ollama_options.dart';
// Agentic models (beta): OpenAI Responses API and Claude
export 'src/components/model/providers/claude_agentic/claude_agentic_config.dart';
export 'src/components/model/providers/claude_agentic/claude_agentic_consts.dart';
export 'src/components/model/providers/claude_agentic/claude_agentic_content_block_extra.dart';
export 'src/components/model/providers/claude_agentic/claude_agentic_extension.dart';
export 'src/components/model/providers/claude_agentic/claude_agentic_message_extra.dart';
export 'src/components/model/providers/claude_agentic/claude_agentic_model.dart';
export 'src/components/model/providers/claude_agentic/claude_agentic_options.dart';
export 'src/components/model/providers/claude_agentic/claude_agentic_register.dart';
export 'src/components/model/providers/openai_responses/openai_responses_config.dart';
export 'src/components/model/providers/openai_responses/openai_responses_consts.dart';
export 'src/components/model/providers/openai_responses/openai_responses_exception.dart'
    show OpenAIResponsesException;
export 'src/components/model/providers/openai_responses/openai_responses_extension.dart';
export 'src/components/model/providers/openai_responses/openai_responses_model.dart';
export 'src/components/model/providers/openai_responses/openai_responses_options.dart';
export 'src/components/embedding/gemini_embedder.dart';
export 'src/components/embedding/ollama_embedder.dart' hide OllamaEmbedResponse;
