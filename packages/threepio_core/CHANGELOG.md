# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Work towards parity with Eino v0.9 (`feat/eino-parity`). So far: the test
suite is safe to run, bugs found while auditing the code are fixed, and the
Eino `schema` package is ported (messages, tool definitions and results,
documents, templates, stream readers, chunk concatenation, the type registry)
together with the run context every later API takes.

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
- **`StateGraph`**: a graph that reaches `END` on exactly its last allowed
  step (`maxIterations`) returns its result instead of throwing
  `MaxIterationsExceededException`. The limit trips only when one more step
  would be needed.

### Added

- **`RunContext`** (`core/run_context.dart`): the explicit, immutable
  counterpart of Go's `context.Context`, with a `cancelToken` and typed values
  under `ContextKey`s (`value`, `withValue`, `withCancelToken`). New APIs take
  it as their first parameter.
- `CancelToken.any(tokens)`: one token that is cancelled as soon as any of
  the given ones is, in the same call that cancels it.
- **Streams** (port of Eino `schema/stream.go`). `StreamReader` is now pulled:
  nothing is taken from a source before `recv()` asks for it.
  - `StreamReader.convert(fn, {errWrapper, onEof})`: lazy conversion with an
    optionally asynchronous function; `errWrapper` replaces or skips the
    errors of the source, `onEof` adds a last item or error. `transform` is
    the same without the options.
  - `StreamReader.nextOrNull()`, `StreamReader.setAutomaticClose()`.
  - `StreamWriter.sendAsync` and `sendErrorAsync`: the awaitable counterpart
    of Go's blocking `Send`. They complete when the pipe has room, so the
    `capacity` of `pipe()` now holds a producer back. `send` still never
    waits.
  - `copy(n)` reads the source only as far as the fastest copy has got and
    keeps an item until the slowest copy has received it.
  - `mergeStreamReaders` and `mergeNamedStreamReaders` read at most one item
    ahead from each source and deliver items in the order they arrived.
  - `StreamReader.fromStream` pauses its subscription once 64 events are
    waiting to be received and resumes it when 16 are left.
- **Schema** (port of Eino `schema`):
  - `Message` is a `MessagesTemplate`: `format(ctx, vars, FormatType)` fills
    the placeholders in its content and in the text and media sources of its
    input parts. `FormatType.fString` (Python format strings as `pyfmt`
    reads them) and `FormatType.jinja2` (`package:jinja`);
    `FormatType.goTemplate` throws `UnsupportedError`. `MessagesPlaceholder`.
  - `concatMessages`, `concatMessageArray`, `concatMessageStream`,
    `concatToolResults` with Eino's rules, and `StreamConcat`, the registry of
    functions that join the chunks of a stream (`register`, `resolve`,
    `concatItems`, `concat`).
  - `ToolArgument`, `ToolResult`, `ToolOutputPart`, `ToolPartType`,
    `ToolOutputImage`/`Audio`/`Video`/`File`, `ToolSearchResult`,
    `ToolResult.toMessageInputParts()`.
  - `ParamsOneOf`, `ParameterInfo`, `DataType`; `ToolInfo.fromParams`,
    `ToolInfo.fromJsonSchema`, `ToolInfo.extra` and the getters `name`, `desc`
    and `paramsOneOf`.
  - `MessagePartCommon.fileId`, `MessageInputFile.name`,
    `MessageInputPart.toolSearchResult` and `.extra`, the factories
    `MessageInputPart.audio`/`.video`/`.file`, `MessageOutputReasoning`,
    `MessageStreamingMeta`, `MessageOutputPart.reasoning`, `.extra` and
    `.streamingMeta`, `ChatMessagePartType.reasoning` and `.toolSearchResult`,
    `PromptTokenDetails.cacheWriteTokens`.
  - `DocumentMetaX`: the Eino metadata accessors of `Document`
    (`withSubIndexes`/`subIndexes`, `withScore`/`effectiveScore`,
    `withExtraInfo`/`extraInfo`, `withDslInfo`/`dslInfo`,
    `withDenseVector`/`denseVector`, `withSparseVector`/`sparseVector`).
  - `MessageParser<T>` and `MessageJsonParser<T>`.
  - `TypeRegistry`: names for the types written to checkpoints
    (`registerName`, `encode`, `decode`, `canEncode`), with Eino's schema
    types registered.
- Entry points `package:threepio_core/schema.dart` and
  `package:threepio_core/streaming.dart`; the umbrella library exports both.
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
  added `logging`, `collection` and `jinja`.
- **The runtime's `RunContext` is now `AgentRunScope`** (the class
  `ChatModelAgent.run` takes as `context:`). `RunContext` is the new core
  context.
- **`MessageConcatenator.concat` follows Eino's `ConcatMessages`** (it calls
  `concatMessages`):
  - Tool calls come out with the ones that have no `index` first and the
    others by ascending index. Fragments of one call whose ids, types or names
    contradict each other throw an `ArgumentError`; the first non-empty value
    used to win silently.
  - Usage: the highest token counts and cost of all chunks and the last
    non-empty finish reason are kept, and log probabilities are appended. The
    `responseMeta` of the last chunk that had one used to be taken whole.
  - `extra`: strings under the same key are concatenated and maps are merged
    recursively; the last value used to win. Lists are still appended.
  - Neighbouring text, reasoning and base64-audio output parts, and
    neighbouring text input parts, are joined.
  - A list with a single message is processed as well instead of being
    returned as it is.
- `mergeNamedStreamReaders` with a single source reports the end of that
  source with a `SourceEOFException`, like it does for several sources.
- `StreamReader.asStream()` closes the reader when the stream ends or its
  listener cancels, also while it is waiting for the next item.
- A reader that was closed behind `mergeStreamReaders` or
  `concatStreamReaders` and is not one of this package's own counts as ended.
- `mergeStreamReaders`, `mergeNamedStreamReaders` and `concatStreamReaders`
  take over all the readers they are given or, when one of them was handed
  over before or is given twice, none.
- `AgentRunEndEvent.tokenUsage` is the schema `TokenUsage`; the look-alike
  class in `agent_event.dart` is gone. Its JSON is the one of the schema
  class; events stored with the old snake_case keys are still read.
- `pipe()` rejects a negative `capacity`.
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

### Deprecated

- `MessagePartCommon.extra`: use `MessageInputPart.extra` or
  `MessageOutputPart.extra`, as Eino does. A file name goes into
  `MessageInputFile.name`; the OpenAI and OpenRouter converters still read it
  from the old place.

### Removed

- The `@internal` members `StreamReader.fromController`,
  `StreamReader.controller` and `StreamWriter.fromController`, and the
  `@internal` plumbing that replaced them for a while (`StreamReader.buffered`,
  `feed`, `feedDone`, `drainTo`, `release`, `isReleased`,
  `StreamWriter.forReader`).

### Migration notes

- Rename `RunContext(...)` to `AgentRunScope(...)` where you pass a `context:`
  to `ChatModelAgent.run`. Code that goes through `Runner` is not affected.
- `StreamReader` can no longer be instantiated or extended; it never had a
  public constructor. A class that `implements` it (a test double) has to add
  `nextOrNull`, `convert` and `setAutomaticClose`.
- A `switch` over `ChatMessagePartType` without a `default` needs cases for
  `reasoning` and `toolSearchResult`.
- If you relied on `MessageConcatenator.concat` keeping the last value of a
  string in `extra`, or on it accepting tool-call fragments with different
  ids for one index, see "Changed" above.
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
