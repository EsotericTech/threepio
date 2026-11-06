/// The components an LLM application is built from, as contracts: chat
/// models, tools, chat templates, embedders, retrievers, indexers, document
/// loaders, parsers and transformers, each with its call options and with the
/// payloads it reports to callback handlers.
///
/// Port of the Eino package `components` and its sub-packages (`model`,
/// `tool` and `tool/utils`, `prompt`, `embedding`, `retriever`, `indexer`,
/// `document` and `document/parser`).
///
/// Next to the contracts, the library exports the implementations threepio
/// ships that run on every platform: retrievers, text splitters, rerankers,
/// the in-memory vector store, the document parsers, the ingestion pipeline,
/// and the adapters between the Eino-shaped contracts and threepio's older
/// ones (`VectorStoreIndexer`, `LoaderAdapter`, `DocumentParserAdapter`).
/// It also exports the eino-ext components that run on every platform: the
/// MCP client and its tools, the Qdrant indexer and retriever, the URL
/// loader, the HTML, PDF, DOCX and XLSX parsers, the splitters and the score
/// reorder, the HTTP request, search, Wikipedia, sequential-thinking and
/// command-line tools (eino-ext's `FileLoader` and the local operator that
/// runs commands are in `package:threepio_core/io.dart`).
///
/// Not in here, but in `package:threepio_core/threepio_core.dart`: the model
/// providers, the older loaders that read files (they need `dart:io`), and
/// the tool registry, tool executor and agent loop threepio had before the
/// ADK.
library;

export 'src/callbacks/run_info.dart' show ComponentType;
export 'src/components/component_type.dart';
export 'src/components/document/document_callbacks.dart';
export 'src/components/document/loader.dart';
export 'src/components/document/loader/url_loader.dart';
export 'src/components/document/parser/docx_parser.dart';
export 'src/components/document/parser/eino_html_parser.dart';
export 'src/components/document/parser/ext_parser.dart';
export 'src/components/document/parser/parser.dart';
export 'src/components/document/parser/pdf_parser.dart';
export 'src/components/document/parser/text_parser.dart';
export 'src/components/document/parser/xlsx_parser.dart';
export 'src/components/document/transformer.dart';
export 'src/components/document/transformer/score_reorder.dart';
export 'src/components/document/transformer/semantic_splitter.dart';
export 'src/components/document/transformer/splitter/html_header_splitter.dart'
    show HtmlHeaderSplitterConfig;
export 'src/components/document/transformer/splitter/markdown_header_splitter.dart'
    show MarkdownHeaderSplitterConfig;
export 'src/components/document/transformer/splitter/recursive_splitter.dart'
    show RecursiveSplitterConfig, SplitterKeepType;
export 'src/components/document/transformer/splitter/split_id_generator.dart'
    show SplitIdGenerator;
export 'src/components/document_loader/document_loader.dart';
export 'src/components/document_loader/loader_adapter.dart';
export 'src/components/document_loader/url_loader.dart';
export 'src/components/document_parser/document_parser_exports.dart';
export 'src/components/embedding/caching_embedder.dart';
export 'src/components/embedding/embedder.dart';
export 'src/components/embedding/embedding_cache.dart';
export 'src/components/embedding/embedding_callbacks.dart';
export 'src/components/indexer/indexer.dart';
export 'src/components/indexer/indexer_callbacks.dart';
export 'src/components/indexer/qdrant/qdrant_indexer.dart';
export 'src/components/indexer/vector_store_indexer.dart';
export 'src/components/model/base_chat_model.dart';
export 'src/components/model/cancel_token.dart';
export 'src/components/model/chat_model_options.dart';
export 'src/components/model/model_callbacks.dart';
export 'src/components/model/model_errors.dart';
export 'src/components/model/resilient_chat_models.dart';
export 'src/components/pipeline/pipeline_exports.dart';
export 'src/components/prompt/chat_template.dart';
export 'src/components/prompt/default_chat_template.dart';
export 'src/components/prompt/prompt_callbacks.dart';
export 'src/components/qdrant/qdrant_client.dart';
export 'src/components/reranker/reranker_exports.dart';
export 'src/components/retriever/qdrant/qdrant_retriever.dart';
export 'src/components/retriever/retriever_callbacks.dart';
export 'src/components/retriever/retriever_exports.dart';
export 'src/components/text_splitter/text_splitter_exports.dart';
export 'src/components/tool/command_line/command_line_operator.dart';
export 'src/components/tool/command_line/py_executor_tool.dart';
export 'src/components/tool/command_line/str_replace_editor_tool.dart';
export 'src/components/tool/duckduckgo/duckduckgo_search.dart';
export 'src/components/tool/duckduckgo/duckduckgo_types.dart';
export 'src/components/tool/enhanced_tool.dart';
export 'src/components/tool/function_tool.dart';
export 'src/components/tool/google_search/google_search_tool.dart';
export 'src/components/tool/http_request/http_request_tool.dart';
export 'src/components/tool/invokable_tool.dart';
export 'src/components/tool/search_result.dart';
export 'src/components/tool/searxng/searxng_client.dart';
export 'src/components/tool/searxng/searxng_types.dart';
export 'src/components/tool/sequential_thinking/sequential_thinking_tool.dart';
export 'src/components/tool/tool_callbacks.dart';
export 'src/components/tool/tool_error_handler.dart';
export 'src/components/tool/tool_options.dart';
export 'src/components/tool/wikipedia/wikipedia_errors.dart';
export 'src/components/tool/wikipedia/wikipedia_tool.dart';
export 'src/components/vector_store/vector_store_exports.dart';
export 'src/components/prompt/mcp_prompt_template.dart';
export 'src/components/tool/mcp/mcp_client.dart';
export 'src/components/tool/mcp/mcp_session.dart';
export 'src/components/tool/mcp/mcp_toolkit.dart';
export 'src/components/tool/mcp/transports.dart' hide decodeMcpMessages;
export 'src/core/interrupt_signal.dart';
export 'src/core/run_context.dart';
export 'src/errors.dart';
