# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Work towards parity with Eino v0.9 (`feat/eino-parity`). This first step makes
the test suite safe to run and fixes bugs found while auditing the code; it
adds no Eino APIs yet.

### Fixed

- **Text splitters**: `MarkdownSplitter`, `HtmlSplitter` and
  `RecursiveCharacterTextSplitter` no longer loop forever, allocating memory
  until the process dies, when a segment longer than `chunkSize` has no
  separator and `chunkOverlap` is greater than zero.
- **`StreamReader`**
  - `close()` completes a `recv()` that is waiting for an item with
    `StreamClosedException` instead of leaving it pending forever.
  - `StreamReader.fromIterable` reports the end of the stream right after the
    last item.
  - Readers returned by `copy`, `transform`, `mergeStreamReaders`,
    `mergeNamedStreamReaders` and `concatStreamReaders` buffer from the moment
    they are created; items that arrive before the first `recv()` are no
    longer lost, and closing one copy no longer breaks the others.
  - `StreamReader.fromStream` cancels its subscription when the reader is
    closed.
  - `StreamWriter.send` returns `true` once the reader of its pipe was closed
    instead of throwing.
  - `collectAll()` and `asStream()` skip the `SourceEOFException` markers of a
    named merge instead of failing on the first one.
- **`Runner`**
  - `RunHandle.result` completes even when nobody listens to
    `RunHandle.events`.
  - A session is reserved as soon as `run()` is called, so two runs for the
    same `sessionId` started back to back can no longer both begin.
- **`ToolRegistry`**: `register` no longer loses tools when the registry is
  used right away. `getToolInfoList()`, the new `findTool()` and
  `ToolExecutor` wait for pending registrations; `count` and `getAllTools()`
  reflect a registration at once.
- **HTTP clients**: `OpenAIChatModel`, `OpenRouterChatModel`,
  `GeminiChatModel` and `OpenAIEmbedder` created a new `http.Client` for every
  request and never closed it. Each now creates one client, shares it with its
  `withTools` copies and closes it in the new `dispose()`.

### Added

- `ToolRegistry.ready` and `ToolRegistry.findTool(name)`.
- `dispose()` on `OpenAIChatModel`, `OpenRouterChatModel`, `GeminiChatModel`
  and `OpenAIEmbedder`. A client passed as `httpClient` is never closed by it.
- Test tooling: `dart_test.yaml` (30 s timeout, one suite at a time, an
  `integration` tag), `tool/test_shards.sh`, `tool/test_file_audit.sh` and
  `tool/run_capped.sh` (wall-clock and memory caps), `tool/consumer_gate.sh`
  with recorded consumer baselines, and golden transcripts of the
  `Runner`/`ChatModelAgent` runtime under `test/adk/golden/`.

### Changed

- **SDK**: `environment: sdk: ^3.9.0` (was `>=3.0.0 <4.0.0`). The package's own
  code generators already required Dart 3.9.
- **Dependencies**: removed the unused `rxdart`, `equatable` and `async`;
  added `logging` and `collection`.
- `concatStreamReaders` passes the errors of a source on in place and keeps
  reading that source; it used to skip the rest of a source after its first
  error.
- A reader passed to `transform`, `mergeStreamReaders`,
  `mergeNamedStreamReaders` or `concatStreamReaders` now belongs to the
  returned reader, as with `copy`: `recv()` on it throws
  `StreamClosedException`, closing it does nothing, and handing it over a
  second time throws a `StateError`. Close the returned reader to release the
  source.
- Integration tests (tag `integration`) run only when `THREEPIO_INTEGRATION=1`
  is set and read their API keys from the environment; they no longer load a
  `.env` file from an absolute path.

### Removed

- The `@internal` members `StreamReader.fromController`,
  `StreamReader.controller` and `StreamWriter.fromController`.

### Migration notes

- `ToolRegistry.register` used to add the tool some time after it returned.
  Code that waited for that (for example with `Future.delayed`) keeps working.
  Code that looked a tool up by name in the same synchronous block still
  cannot see it, because the name comes from the asynchronous `info()`: use
  `await registry.findTool(name)` or `await registry.ready`. A tool whose
  `info()` throws is now reported by `ready`, `findTool` and
  `getToolInfoList` instead of surfacing as an unhandled asynchronous error.
- Projects on a Dart SDK older than 3.9 can no longer depend on this package.
- Call `dispose()` on a model or embedder you created without an `httpClient`
  when you no longer need it. Using it afterwards throws a `StateError`.

## [0.1.0] - 2024-10-19

### Added

#### Core Components
- **Runnables & Lambda**: Composable execution units with type-safe transformations
- **Message Schema**: Comprehensive message types (System, User, Assistant, Tool)
- **Prompt Templates**: Dynamic prompt generation with variable substitution
- **Chat Models**: OpenAI integration with streaming support
- **Tool Calling**: Function calling with JSON schema validation

#### RAG (Retrieval Augmented Generation)
- **Document Loaders**: Text file and directory loaders
- **Text Splitters**: Character and recursive splitting strategies
- **Embeddings**: OpenAI embeddings support
- **Vector Stores**: In-memory vector store with similarity search
- **Retrievers**: Document retrieval with configurable parameters

#### Advanced Features
- **Graph Orchestration**: Build complex workflows with conditional routing and parallel execution
- **Agents**: ReAct agent with tool execution and iterative problem-solving
- **Memory & Persistence**: Multiple memory strategies (buffer, window, token-limited, summarization)
- **Callbacks**: Lifecycle hooks for monitoring and debugging
- **Streaming**: Full support for streaming responses

#### Observability & Cost Tracking
- **Langfuse Integration**: Production-ready observability with traces, spans, and generations
- **Cost Tracking Models**: Token usage tracking and cost calculation infrastructure
- **Batch Processing**: Efficient event batching with configurable flush intervals
- **Retry Logic**: Exponential backoff for robust API communication

#### Structured Output Parsing
- **Output Parsers**: JSON, List, Enum, Boolean, Number parsers
- **Schema Validation**: JSON Schema validation with detailed error messages
- **Auto-Retry**: LLM-powered error correction
- **Type-Safe**: Pydantic-style transformations to Dart objects

### Documentation
- Comprehensive README with 3,600+ lines covering all features
- Code examples for every major component
- API documentation with usage patterns
- Architecture overview and design principles

### Testing
- Unit tests for core components
- Integration tests with real OpenAI API calls
- Structured output parsing test suite (25 tests)
- Langfuse client tests (18 tests)

[0.1.0]: https://github.com/EsotericTech/threepio/releases/tag/v0.1.0
