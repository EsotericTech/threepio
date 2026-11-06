# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Work towards parity with Eino v0.9 (`feat/eino-parity`). So far: the test
suite is safe to run, bugs found while auditing the code are fixed, the Eino
`schema` package is ported (messages, tool definitions and results,
documents, templates, stream readers, chunk concatenation, the type registry)
together with the run context every later API takes, and so is the Eino
`components` package (the contracts of chat models, tools, templates,
embedders, retrievers, indexers, loaders, parsers and transformers, their call
options and callback payloads, and the tools made from functions), the
Eino `callbacks` package with tracing to Langfuse over OpenTelemetry, and the
Eino `compose` package: runnables, lambdas, graphs, chains, workflows and the
tools node, with interrupt, checkpoint and resume, and the core of the Eino
`adk` package (agents, the runner, interrupt and resume of agents,
middlewares, retry and failover of the model), on which the Kortney runtime
now runs, its run control (cancel, the turn loop, the filesystem backend) and
its eight built-in middlewares.

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

- **ADK** (port of the classic half of Eino `adk`), in the new library
  `package:threepio_core/adk.dart`, which the umbrella library does not export
  (several of its names are also names of the Kortney runtime; import it with
  a prefix when both are needed). It re-exports `compose.dart`.
  - `Agent` and `ResumableAgent` (`run`/`resume` return a
    `StreamReader<AgentEvent>`), `AgentInput`, `AgentEvent` (with
    `AgentOutput`, `AgentAction`, an error in place of a failed stream),
    `MessageVariant.message`/`.stream` with `getMessage()`,
    `getMessageFromEvent`, `AgentEvent.fromMessage`.
  - `ChatModelAgent` (`ChatModelAgentConfig`, `ToolsConfig` with
    `returnDirectly` and `emitInternalEvents`, `GenModelInput` and
    `defaultGenModelInput`, which fills `{key}` placeholders of the
    instruction from session values): the ReAct loop of Eino on a compose
    graph (`Init`, `ChatModel`, `CancelCheck`, `ToolNode`, `AfterToolCalls`,
    `AfterToolCallsCancelCheck`, `AfterAgent`, `ToolNodeToEndConverter`), or
    one model call without tools; `ExceedMaxIterationsException`.
  - `Runner` (`run`, `query`, `resume`, `resumeWithParams` with
    `ResumeParams`; a checkpoint is saved under `AgentRunOption.checkpointId`
    when the run interrupts), `AgentRunOption` (`sessionValues`, `callbacks`,
    `checkpointId`, `chatModelOptions`, `toolOptions`, `agentToolRunOptions`,
    `afterToolCallsHook`, `custom<T>`/`customValues<T>`, `designateAgent`).
  - Interrupts of agents: `interruptEvent`, `statefulInterruptEvent`,
    `compositeInterruptEvent`, `AgentInterruptInfo`, `ResumeInfo`,
    `ChatModelAgentInterruptInfo`, `ChatModelAgentResumeData` (a history
    modifier given with `resumeWithParams`), `addressSegmentAgent`,
    `addressSegmentTool`. A tool that calls `interrupt` interrupts its
    agent, and resuming the run resumes the tool.
  - `extension AgentContext on RunContext`: `sessionValues`,
    `addSessionValue(s)`, `sessionValue`, `hasSessionValue`,
    `clearRunContext`, `setRunLocalValue`, `runLocalValue`,
    `deleteRunLocalValue`, `sendEvent`; and `sendToolGenAction`.
  - `ChatModelAgentMiddleware` (nine hooks with no-op defaults: `beforeAgent`,
    `afterAgent`, `beforeModelRewriteState`, `afterModelRewriteState`, four
    tool wrappers, `wrapModel`), `ChatModelAgentContext`,
    `ChatModelAgentState`, `ModelContext`, `ToolContext`, the endpoint
    typedefs, `EventSenderModelWrapper` and `EventSenderToolWrapper` (to place
    the event senders among the middlewares).
  - `ModelRetryConfig` (`shouldRetry` with `RetryContext`/`RetryDecision`,
    `backoff`), `RetryExhaustedException`, `WillRetryException` (ends the
    stream of an output that will be retried), `ModelFailoverConfig` with
    `FailoverContext`.
  - Message ids (`messageIdOf`, `ensureMessageId`, `einoMessageIdKey`): the
    model's messages (the first chunk of a stream) and tool results get ids,
    shared by the event and the agent's state.
  - `AgentTool` (`fullChatHistoryAsInput`, `inputSchema`): an agent as a
    tool of another, with shared session values, events passed on with
    `emitInternalEvents`, and interrupts that propagate.
  - Agent callbacks: `AgentCallbackInput`, `AgentCallbackOutput` (a stream of
    the events per handler), `typedAgentCallbackHandler`; the runner reports
    every agent as `ComponentType.agent` with its type (`ChatModel`).
  - `AdkLanguage`, `setAdkLanguage`, `adkLanguage`.
  - Human-in-the-loop tools of the Eino examples: `ApprovableTool`
    (`ApprovalInfo`, `ApprovalResult`), `ReviewEditTool` (`ReviewEditInfo`,
    `ReviewEditResult`), `FollowUpTool` (`FollowUpInfo`, `FollowUpState`).
- **ADK run control** (port of Eino `adk/cancel.go`, `turn_loop.go`,
  `turn_buffer.go`, `adk/filesystem` and eino-examples `graphtool`), in
  `package:threepio_core/adk.dart`:
  - Cancel: `withCancel()` returns an `AgentRunOption` and an
    `AgentCancelFunc` (`safePoints`, `timeout`, `recursive`). An empty set of
    `CancelSafePoint`s cancels at once (the agent's graph is interrupted with
    no wait, model and tool streams end with `StreamCanceledException`);
    `afterChatModel` / `afterToolCalls` cancel at the next safe point, with an
    optional timeout that escalates to an immediate cancel; `recursive`
    reaches the agents behind `AgentTool`s, whose interrupts end up in the
    checkpoint. The run ends with an event whose error is an
    `AgentRunCancelledException` (`AgentCancelInfo`, `interruptContexts`); the
    `Runner` saves a checkpoint of the cancelled run (with a store and a
    checkpoint id), which `resume`/`resumeWithParams` continue.
    `CancelHandle.wait()` reports a `CancelOutcome` (`cancelled`, `timedOut`,
    `executionEnded`); `CancelHandle.contributed` says whether the call took
    part in the cancel.
  - `TurnLoop<T>` with `TurnLoopConfig` (`genInput`, `genResume`,
    `prepareAgent`, `onAgentEvents`, `store`, `checkpointId`),
    `GenInputResult`, `GenResumeResult`, `TurnContext` (`preempted`,
    `stopped`, `stopCause`), `TurnLoopExitState` (`takeLateItems()`),
    `TurnLoopInterruptedException`, `PushOption` (`preempt`,
    `preemptTimeout`, `preemptDelay`, `strategy`) and `StopOption`
    (`graceful`, `immediate`, `gracefulTimeout`, `skipCheckpoint`, `cause`,
    `untilIdleFor`): items pushed while an agent runs are batched into the
    next turn, a push can preempt the running turn at a safe point, and a
    stopped, cancelled or interrupted loop writes a checkpoint a new loop
    continues.
  - Filesystem: `FilesystemBackend` (`lsInfo`, `read`, `grepRaw`,
    `globInfo`, `write`, `edit`), `MultiModalReader`, `Shell`,
    `StreamingShell`, their request and result types (`FileInfo`,
    `GrepMatch`, `ReadRequest` with a 1-based `offset`, `GrepRequest`,
    `GlobInfoRequest`, `WriteRequest`, `EditRequest`, `FileContent`,
    `FileContentPart`, `MultiFileContent`, `ExecuteRequest`,
    `ExecuteResponse`, ...), and `InMemoryBackend` (regex grep with context
    lines and multiline mode, globs through `package:glob`, ripgrep file
    types, exact-match edits).
  - `GraphTool.invokable<I, O>` / `GraphTool.streamable<I, O>`: a compose
    graph, chain or workflow as a tool of an agent, with interrupt and resume
    of the graph inside; `GraphToolOptions` for its call options.
- **ADK middlewares** (port of Eino `adk/middlewares`), in
  `package:threepio_core/adk.dart`; each is a `ChatModelAgentMiddleware` for
  `ChatModelAgentConfig.handlers`, with Eino's English and Chinese prompts
  copied verbatim (the language of `setAdkLanguage`):
  - `PatchToolCallsMiddleware` (`PatchedToolResult`,
    `PatchedToolResultGenerator`): answers tool calls that have no tool
    message before the model sees the history.
  - `AgentsMdMiddleware`: puts agents.md files (with `@path` imports, at most
    five levels, each file once, byte budgets for all files and for each
    file) in front of the conversation as one user message, loaded once per
    run.
  - `SummarizationMiddleware` (`SummarizationTrigger`,
    `SummarizationRetryConfig`, `SummarizationFailoverConfig`,
    `SummarizationFailoverContext`, `TokenCounterInput`,
    `SummarizationAction` events): replaces a history that is over a token
    or message count by a summary written by a model, keeping the user's
    latest messages; `summarize(ctx, state)` for doing it at any time;
    `SummaryFinalizerBuilder` with `preserveSkills(PreserveSkillsConfig)` and
    `defaultSummaryFinalize` for the new history.
  - `ToolReductionMiddleware` (`ToolReductionConfig`, `ToolDetail`,
    `TruncResult`, `ClearResult`): cuts large tool results as they come
    (streams too) and offloads them to a `FileWriteBackend`, and clears old
    tool results when the conversation gets too long; handlers per tool.
  - `FilesystemMiddleware` (`FilesystemToolConfig`,
    `FilesystemToolDescriptions`): the tools `ls`, `read_file` (or a
    multimodal one for images and PDF pages), `write_file`, `edit_file`,
    `glob`, `grep` and `execute` (with a `Shell` or `StreamingShell`) on a
    `FilesystemBackend`.
  - `SkillMiddleware` (`SkillBackend`, `FilesystemSkillBackend`, `Skill`,
    `SkillFrontMatter`, `SkillContextMode`, `AgentHub`, `ModelHub`,
    `SkillSubAgentInput`, `SkillSubAgentOutput`): a `skill` tool that loads
    SKILL.md files and runs a skill inline, or in a sub-agent with or without
    the conversation.
  - `PlanTaskMiddleware` (`PlanTaskBackend`, `DeleteRequest`): the tools
    `TaskCreate`, `TaskGet`, `TaskUpdate` and `TaskList` over one JSON file
    per task, with dependencies (cycles refused).
  - `ToolSearchMiddleware.create(dynamicTools:, useModelToolSearch:)`: hides
    tools until the model finds them with `tool_search`, or hands them to a
    model with native tool search.
- **Filesystem**: `FileReadBackend` and `FileWriteBackend`, the read and write
  halves of `FilesystemBackend` (which implements both), and
  `FileNotFoundException`, which a backend throws for a missing file
  (`InMemoryBackend` does).
- **Langfuse**: the observation of an agent ends with the messages and custom
  outputs of its events; retry notifications of its model
  (`WillRetryException`) are kept as `eino_retry_events` metadata instead of
  failing it (port of eino-ext `endAgentOutput`).
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
- **Components** (port of Eino `components`), with the entry point
  `package:threepio_core/components.dart`, which the umbrella library exports:
  - **Tools.** `InvokableTool.invokableRun(ctx, argumentsJson, {options})` and
    `StreamableTool.streamableRun(...)`, the Eino-shaped entry points; their
    default implementations call `run` and `streamRun`, so existing tools work
    through them unchanged. `ToolOptions`. `EnhancedInvokableTool` and
    `EnhancedStreamableTool` for tools that return a multimodal `ToolResult`
    (`enhancedInvokableRun`, `enhancedStreamableRun`).
  - **Tools from functions** (port of `tool/utils`): `FunctionTool`,
    `StreamFunctionTool`, `EnhancedFunctionTool` and
    `EnhancedStreamFunctionTool`, each also `.fromInfo(toolInfo, …)`. Go infers
    the parameter schema from struct tags; here a tool is given its
    `ParamsOneOf` and a `fromJson` for its input.
  - `wrapToolWithErrorHandler`, `wrapInvokableToolWithErrorHandler` and
    `wrapStreamableToolWithErrorHandler`: a failed tool call returns the text
    a handler makes of the error instead of ending the run. An
    `InterruptSignal`, and anything thrown after the run was cancelled, is
    never handed to the handler.
  - `InterruptSignal`: the marker of an interrupt on its way up the call
    stack, and `isInterrupt(error)`, which also recognises one wrapped in
    another exception. The engine that creates and catches interrupts comes
    with the compose port; code that catches tool errors can already let it
    through, and `ToolExecutor` and the runtime `ChatModelAgent` do.
  - **Chat models.** `ChatModelOptions` gains `deferredTools`,
    `toolSearchTool`, `allowedToolNames`, `runContext` and `extensions` with
    `extension<T>()`. The providers that ship do not act on the first three
    yet.
  - **Chat templates.** `ChatTemplate.fromMessages(formatType, templates)`
    (`DefaultChatTemplate`, port of `prompt.FromMessages`): a list of
    `Message`s with placeholders and `MessagesPlaceholder`s, rendered as
    f-strings or Jinja2. `ChatTemplateOptions` gains `runContext` and
    `extensions`.
  - **Indexers.** `Indexer.store(ctx, docs, {options})`, `IndexerOptions`, and
    `VectorStoreIndexer`, which stores into any `VectorStore` and embeds the
    documents that come without a vector.
  - **Documents.** `Loader.load(ctx, source, {options})` with `LoaderOptions`;
    `Parser.parse(ctx, bytes, {options})` with `ParserOptions`, `TextParser`
    and `ExtParser` (a parser by file extension, with a fallback);
    `TransformerOptions`. `TextSplitter` is a `DocumentTransformer`
    (`transform`, and `withOptions` to fix the chunk size).
  - **Adapters** from the components threepio already had:
    `DocumentParser.asParser()` (`DocumentParserAdapter`), `LoaderAdapter` for
    `DocumentLoader`s, `RerankerTransformer` for `Reranker`s.
  - `RetrieverOptions` gains `index`, `subIndex`, `embedding`, `dslInfo`,
    `runContext` and `extensions`; `EmbedderOptions` gains `runContext` and
    `extensions`. Every option class has `copyWith` and `merge`
    (`HybridRetrieverOptions` and `MultiQueryRetrieverOptions` keep their own
    fields through both). `VectorRetriever` embeds the query with
    `RetrieverOptions.embedding` when a call brings one.
  - **Implementation-specific options.** Every option class carries
    `extensions`, a list of objects of types the implementation defines, read
    with `extension<T>()`. This replaces Eino's `WrapImplSpecificOptFn` and
    `GetImplSpecificOptions`. `OpenRouterRequestOptions.toOptions()` and
    `applyTo()` add themselves to it, and `OpenRouterChatModel` also accepts
    `ChatModelOptions(extensions: [OpenRouterRequestOptions(...)])`.
  - **Callback payloads** with `from(Object?)` (Eino's `ConvCallbackInput` and
    `ConvCallbackOutput`): `ModelCallbackInput`/`Output`/`Config`,
    `ToolCallbackInput`/`Output`, `PromptCallbackInput`/`Output`,
    `EmbeddingCallbackInput`/`Output`/`Config`,
    `RetrieverCallbackInput`/`Output`, `IndexerCallbackInput`/`Output`,
    `LoaderCallbackInput`/`Output`, `TransformerCallbackInput`/`Output`.
  - `TypedComponent` and `CallbackAwareComponent` (Eino `Typer` and
    `Checker`) with `componentTypeNameOf` and `isCallbacksEnabled`.
    `ComponentType` gains `indexer`, `loader`, `documentTransformer`, `graph`,
    `workflow`, `lambda` and `toolsNode`, and `einoName` on every value.
- **`ThreepioException`**: the base of the exceptions threepio throws for
  failures a caller is expected to handle, with `message`, `cause` and
  `ThreepioException.findCause<T>(error)`. The exception types that existed
  (`OpenRouterException` and every other `ChatModelException`,
  `CancelledException`, `AgentException` and its subclasses, the loader,
  parser, vector store, graph and checkpoint exceptions, …) implement it and
  keep their names, fields and `toString()`. `ThreepioFormatException` is a
  `FormatException` that is also a `ThreepioException`; templates, message
  parsers and function tools throw it for input they cannot read. Stream
  signals (`StreamEOFException`, …) and `InterruptSignal` are deliberately not
  threepio exceptions, and mistakes in the calling code stay `ArgumentError`
  and `StateError`.
- **Callbacks** (`package:threepio_core/callbacks.dart`, port of the Eino
  packages `callbacks` and `utils/callbacks`): a way to watch the components
  of a run from outside.
  - `ComponentCallbackHandler`: the contract of a handler, with the hooks
    `onStart`, `onEnd`, `onError`, `onStartWithStreamInput` and
    `onEndWithStreamOutput`. Each gets the `RunContext`, the `RunInfo` of the
    component and its payload, and returns the context the run goes on with.
    Stream hooks get a copy of the stream of their own. A hook that throws is
    logged (`threepio.callbacks`) and does not fail the run.
  - `CallbackHandlerBuilder` builds a handler from functions;
    `HandlerHelper` builds one from typed handlers per kind of component
    (`ModelCallbackHandler`, `ToolCallbackHandler`, `PromptCallbackHandler`,
    `EmbeddingCallbackHandler`, `RetrieverCallbackHandler`,
    `IndexerCallbackHandler`, `LoaderCallbackHandler`,
    `TransformerCallbackHandler`, `ToolsNodeCallbackHandlers`,
    `AgentCallbackHandler`, and plain handlers for graphs, chains and
    lambdas). `CallbackTiming` and `TimingChecker` let a handler say which
    callbacks it wants, which saves the stream copies it would not read.
  - Handlers travel in the run context: `RunContext.withHandlers`,
    `runInfo`, `hasCallbacks` and `callbackHandlers` (extension
    `CallbackContext`). `GlobalCallbacks` holds the handlers of every run.
  - For code that fires callbacks: `ensureRunInfo`, `initCallbacks`,
    `reuseHandlers`, `appendHandlers`, and `onStart`, `onEnd`, `onError`,
    `onStartWithStreamInput`, `onEndWithStreamOutput`, `onEndWithCopies`.
    The last six are exported from `callbacks.dart` only (see "Migration
    notes").
  - `LegacyCallbackHandlerAdapter` runs a `CallbackHandler` of the older API
    as a `ComponentCallbackHandler`; the map that API passes around travels
    in the run context.
  - `RunInfo.unknown` and `RunInfo.isUnknown`: what a handler is given when a
    component did not say what it is.
- **The chat model providers and `DefaultChatTemplate` fire the new
  callbacks.** `OpenAIChatModel`, `OpenRouterChatModel` and `GeminiChatModel`
  report `generate` and `stream` to the handlers of
  `ChatModelOptions.runContext` and to `GlobalCallbacks` (the latter also
  when a call has no run context), with a `ModelCallbackInput` and a
  `ModelCallbackOutput` that carry the model configuration and the token
  usage; a handler gets the chunks of a streamed answer through a copy of the
  stream. The three are `TypedComponent`s (`OpenAI`, `OpenRouter`, `Gemini`)
  and `CallbackAwareComponent`s. A `CallbackManager` in the options is called
  as before.
- **Tracing** (also in `callbacks.dart`):
  - `LangfuseHandler`, a port of eino-ext `callbacks/langfuse/v2`. It turns
    the components of a run into Langfuse observations (generation, agent,
    tool, retriever, embedding, chain, span) and sends them with
    OpenTelemetry's protocol to `/api/public/otel/v1/traces`. `startTrace`
    and `endTrace` open and close the root of a trace, with its name, user,
    session, tags, release, environment, version and metadata; `flush` and
    `shutdown` deliver what is pending. `LangfuseConfig` has the sample rate,
    a mask function for what must not leave the application, limits for the
    size of a value and of a span, queue and batch sizes, the retry policy,
    and the option to leave out the spans of an agent's own machinery.
  - `OtlpHttpTraceExporter` exports spans to any OpenTelemetry collector that
    takes OTLP over HTTP in the JSON encoding: a bounded queue (`SpanQueue`),
    batches by size and by flush interval, retries with back-off
    (`OtlpRetryConfig`), sampling per trace, masking. `OtlpSpan`,
    `OtlpSpanEvent`, `OtlpStatus` and `encodeOtlpTraces` are the data model,
    `SpanExporter` the interface to plug in another transport.
- **`package:threepio_core/compose.dart`**: the core of the Eino `compose`
  package, also exported by the umbrella library.
  - `Runnable<I, O>`: `invoke`, `stream`, `collect` and `transform`, each with
    the run context first and `List<CallOption>` options. Whatever is
    compiled offers all four; a part that implements only some is given the
    joined chunks of a stream where it needs a value, and its value is passed
    on as a stream of one chunk.
  - `Lambda<I, O>`: a function as a node. `Lambda.invokable`, `.streamable`,
    `.collectable`, `.transformable` and `.any`; the static methods
    `invokableWithOption` (and the three others, and `anyWithOption`) for
    functions that take call options of their own type; `Lambda.toList` and
    `Lambda.messageParser`; `LambdaOptions`.
  - `Graph<I, O>`: `addChatModelNode`, `addChatTemplateNode`, `addToolsNode`,
    `addRetrieverNode`, `addEmbeddingNode`, `addIndexerNode`,
    `addLoaderNode`, `addDocumentTransformerNode`, `addLambdaNode`,
    `addGraphNode` and `addPassthroughNode`, `addEdge`, `addBranch`,
    `compile`. `Graph.start` and `Graph.end` stand for input and output. The
    types along every edge are checked when the edge is added; an edge from a
    wider type to a narrower one is checked when the value is there. A graph
    runs in steps and may have cycles (`GraphCompileOptions.maxRunSteps`
    bounds a run), or as a directed acyclic graph
    (`NodeTriggerMode.allPredecessor`). Graphs nest.
  - `GraphBranch.single`, `.multi`, `.stream` and `.streamMulti`: conditions
    that choose the next node or nodes, from a value or from a stream.
  - `Chain<I, O>` with `append…` for every kind of node, `ChainBranch` and
    `Parallel`.
  - `NodeOptions` (name, input and output key, state handlers, compile
    options of a nested graph; a node key in a chain) and
    `GraphCompileOptions` (step limit, graph name, trigger mode, compile
    callbacks, fan-in merge settings, eager execution, and the checkpoint
    settings that become effective with the checkpoint engine).
  - Local state: `LocalState.of<S>` gives a graph a state object per run,
    `StateHandler.pre`, `.post`, `.streamPre` and `.streamPost` read and
    change it around a node, `processState<S>` from inside one. Access takes
    turns, so nodes that run side by side can share the state.
  - `CallOption`: `callbacks`, `chatModel`, `chatTemplate`, `toolsNode`,
    `tool`, `embedding`, `retriever`, `loader`, `documentTransformer`,
    `indexer`, `lambda<TOption>`, `runtimeMaxSteps`, and the checkpoint
    options; `designateNode` and `designateNodeWithPath` (`NodePath`) aim an
    option at single nodes, also inside nested graphs.
  - Callbacks: a graph fires the callbacks of its nodes (unless a component
    fires its own) and of itself, to the handlers of the context, the global
    ones and those of the call.
  - `ToolsNode`: runs the tool calls of an assistant message, side by side or
    in order, as a value or as a stream. Name and argument aliases
    (`ToolAliasConfig`), an arguments handler, a handler for unknown tools,
    tools that implement the enhanced contracts, `ToolsNodeOptions` per call,
    `toolCallIdOf(ctx)`. `ToolMiddleware` wraps every tool call
    (`ToolCallInput`, `ToolCallOutput`, `StreamToolCallOutput`,
    `EnhancedToolCallOutput`, `EnhancedStreamToolCallOutput`);
    `ErrorRemoverMiddleware` turns a failed call into a result the model can
    read and `JsonFixMiddleware` repairs arguments that are not valid JSON.
  - `ValuesMerge.register<T>`: how the outputs of several nodes that lead to
    one node are merged. Maps are merged by default.
  - `GraphInfo`, `GraphNodeInfo`, `GraphCompileCallback` and
    `GraphCompileCallbacks.appendGlobal`: the structure of a compiled graph;
    `toMermaid()` on a graph, a chain and a `GraphInfo`.
  - `CheckpointStore`, `CheckpointDeleter`, `CheckpointSerializer` and
    `InMemoryCheckpointStore`: the contracts for the checkpoints of
    interrupted runs.
  - **Interrupt and resume.** A node or a tool pauses the run with
    `throw interrupt(ctx, info)`, `statefulInterrupt(ctx, info, state)` or,
    for a component that runs interruptible parts of its own,
    `compositeInterrupt(ctx, info, state, subErrors)`. A graph can also be
    compiled to stop in front of or behind nodes
    (`GraphCompileOptions.interruptBeforeNodes`, `interruptAfterNodes`), and a
    caller can interrupt a running graph from outside:
    `ctx.withGraphInterrupt()` gives the context to run with and a
    `GraphInterrupter` (`interrupt({timeout})`). An interrupted run throws
    `GraphInterruptedException`; its `GraphInterruptInfo` has the state of
    the graph, the nodes it stopped at, the nodes that run again, the infos
    of nested graphs and one `InterruptCtx` per interrupt point (`id`,
    `Address`, `info`, the chain of `parent`s). `extractInterruptInfo(error)`
    finds it in any error. The run goes on when the graph is called again on
    `ctx.resume(ids)`, `ctx.resumeWithData(id, data)` or
    `ctx.batchResumeWithData({...})`; a component finds what it saved with
    `getInterruptState<T>(ctx)` and what it is resumed with with
    `getResumeContext<T>(ctx)`. `ctx.currentAddress` and
    `ctx.appendAddressSegment(type, id)` (`Address`, `AddressSegment`,
    `AddressSegmentType`) say where in a run a component is.
  - **Checkpoints.** With `GraphCompileOptions.checkpointStore` and
    `CallOption.checkpointId` an interrupted run is written to the store and
    resumed from it; `CallOption.writeToCheckpointId`, `forceNewRun` and
    `stateModifier` (also for the states of nested graphs) steer that. Nested
    graphs keep their checkpoints inside the checkpoint of the graph around
    them. `JsonCheckpointSerializer` (the default serializer) writes JSON and
    names every other value through `TypeRegistry`; `FileCheckpointStore` in
    the new `package:threepio_core/io.dart` keeps checkpoints as files (one
    per id, written atomically, named so that no two ids share a file);
    `migrateCheckpointState` rewrites the states inside a stored checkpoint.
    `CheckpointEncodeException` names a value that cannot be written.
  - **Tools node.** A tool that interrupts interrupts its tools node: the
    calls that finished keep their results, only the others run again when
    the run is resumed. `ToolsInterruptAndRerunExtra` reports both. A tool
    stream that ends with `StreamCanceledException` leaves its call
    unfinished in the same way.
  - `Workflow<I, O>`: a graph whose nodes declare what they depend on and
    which fields of which outputs make up their input. Every `add…Node`
    returns a `WorkflowNode` (`addInput`, `addInputWithOptions` with
    `noDirectDependency`, `addDependency`, `setStaticValue`); `end()` is the
    node of the output and `addBranch` returns a `WorkflowBranch`.
    `FieldMapping.fromField`, `.toField`, `.mapFields`, `.fromFieldPath`,
    `.toFieldPath`, `.mapFieldPaths`, with a `customExtractor`. Fields are keys
    of a `Map<String, Object?>` or fields of a class that implements the new
    `FieldAddressable` (`getField`, `withField`;
    `FieldAddressable.registerBlank<T>` for a class that mappings write to).
    `Message` and `Document` implement it. `GraphNodeInfo.mappings` lists the
    mappings of a node. `FieldMappingException` is what a mapping that cannot
    be applied throws.
  - `BatchNode<I, O>`: runs a graph, chain or workflow once per item of a
    list, in order or several at a time, each item at an address of its own.
    Items that interrupt are resumed one by one; the results of the others
    are kept, also across a second interrupt (the node of the eino examples
    loses them there). Port of the batch node of the eino examples.
  - `GraphCompileCallbacks.setGlobal`: replaces the global compile callbacks,
    as Eino's `InitGraphCompileCallbacks` does. `appendGlobal` still adds.
  - `TypeRegistry` matches a state type that is an interface a registered
    class implements.
  - Errors: `GraphBuildException` (with `GraphCompiledException`,
    `ChainCompiledException`, `DagLoopException`), `GraphRunException` and
    `NodeExecutionException` (the path to the failed node and its cause),
    `ExceedMaxStepsException`, `ComposeTypeException`,
    `StreamReadException`, `ToolsNodeException`.
- `package:threepio_core/io.dart`: what needs `dart:io`. For now the
  `FileCheckpointStore` of the compose graphs.
- `package:threepio_core/legacy_graph.dart` (the state graph that predates
  the port, with all its checkpoint classes, and the runnable over Dart
  streams) and `package:threepio_core/legacy_chains.dart` (`BaseChain`,
  `LLMChain`, `SequentialChain`, `RetrievalQAChain` and their relatives).
- `MessageConcatException`, a `ThreepioException`: what the strict concat
  functions throw for chunks that contradict each other (see "Changed").
- `ToolRegistry.ready` and `ToolRegistry.findTool(name)`.
- `dispose()` on `OpenAIChatModel`, `OpenRouterChatModel`, `GeminiChatModel`
  and `OpenAIEmbedder`. A client passed as `httpClient` is never closed by it.
- Test tooling: `dart_test.yaml` (30 s timeout, one suite at a time, an
  `integration` tag), `tool/test_shards.sh`, `tool/test_file_audit.sh` and
  `tool/run_capped.sh` (wall-clock and memory caps), `tool/consumer_gate.sh`
  with recorded consumer baselines, and golden transcripts of the
  `Runner`/`ChatModelAgent` runtime under `test/adk/golden/`.

### Changed

- New dependencies: `clock` (the cancel timeouts and TurnLoop deadlines read
  `clock.now()`, so that `package:fake_async` drives them), `glob` (2.2 or
  later, whose `**/` may match no directory, as Eino's doublestar does) and
  `path` (POSIX paths of the in-memory filesystem backend). All three were
  already transitive dependencies.
- The engine's `ChatModelAgent` installs a tool middleware of its own inside
  the user's tool middlewares; it changes nothing unless the run was started
  with `withCancel()`.
- New dependency: `yaml` (the front matter of SKILL.md files); it was already
  a transitive dependency.
- `TurnLoop.push` returns `resolved` as `Future<void>?`: `null` for a push
  that does not preempt and for a push that is not accepted, where Eino
  returns a nil channel (it was an already completed future). Code that
  awaited it keeps working (`await null` completes); code that passes it on
  as a `Future<void>` adds `!` for a preemptive push.
- `InMemoryBackend` throws `FileNotFoundException` (a `ThreepioException`
  with the same message) for a missing file.

- **Kortney runtime** (`Runner`, `ChatModelAgent`, `AgentHandler`,
  `ContextualTool` of the umbrella library): the loop now runs on the
  Eino-shaped `ChatModelAgent` and `Runner` of `adk.dart`. The handlers, the
  approval policy and the tool timeout are middlewares of that agent; its
  events are mapped to the events of this runtime. The public API, the
  events, their order and the messages the model is sent are those of
  earlier releases (pinned by the golden transcripts under
  `test/adk/golden/`). Approval stays an in-process `Completer` (no
  checkpoint, no serialization). What a consumer can notice: a tool that
  calls `interrupt` still ends the run with a non-recoverable
  `AgentErrorEvent`, whose text now names the interrupt report (it used to
  be the signal's own text); and handlers registered with `GlobalCallbacks`
  now also hear the agent, its graph, its lambdas, the tools node and the
  tools of a run, and hear the model call under the graph node's run info
  (`ChatModel`) instead of the provider's own (callback handlers given to
  the legacy `CallbackManager` are not affected).
- `ContextualTool.invokableRun(ctx, …)` builds the `ToolCallContext` from
  `ctx`: the tool call id the tools node set and the tool's name (instead of
  `direct`), the cancel token of `ctx`, and inside a run of the Kortney
  runtime its run id, session id, metadata and the tool call as the model
  sent it.
- **Compose**: compiling a graph with a checkpoint store or with interrupt
  nodes works (it threw `UnimplementedError`). A graph that is compiled with a
  checkpoint store refuses, at `compile`, a local state type that is neither
  JSON nor registered with `TypeRegistry.registerName`.
- **Compose**: an `InterruptSignal` made by `interrupt`, `statefulInterrupt`
  or `compositeInterrupt` no longer passes through a graph: the graph (and a
  tools node, for its tools) collects it, writes a checkpoint and throws a
  `GraphInterruptedException`. An `InterruptSignal` of another class still
  passes through unchanged.
- **Compose**: a context that runs a compiled graph has an address
  (`runnable:<graph name>`), its nodes `node:<key>` below it, tool calls
  `tool:<name>:<call id>` below their tools node.
- `tool/consumer_gate.sh` measures its own baseline in every run: it analyzes
  the application as it is, then with this checkout, and fails only on errors
  that this checkout introduces. Errors the application has of its own are
  printed and no longer fail the gate. The recorded baseline files are kept
  for reference.
- **SDK**: `environment: sdk: ^3.9.0` (was `>=3.0.0 <4.0.0`). The package's own
  code generators already required Dart 3.9.
- **Dependencies**: removed the unused `rxdart`, `equatable` and `async`;
  added `logging`, `collection` and `jinja`.
- **The runtime's `RunContext` is now `AgentRunScope`** (the class
  `ChatModelAgent.run` takes as `context:`). `RunContext` is the new core
  context.
- **`MessageConcatenator.concat` joins chunks the way Eino's `ConcatMessages`
  does**, and stays as tolerant as it was. `concatMessages` is the strict
  port: where the fragments of one tool call carry different ids, types or
  names, or two values under one key of `extra` cannot be joined, it throws a
  `MessageConcatException`. `MessageConcatenator.concat` keeps the first
  non-empty id, type and name, as it always did, and the last of two values
  that cannot be joined. What changed for both:
  - Tool calls come out with the ones that have no `index` first and the
    others by ascending index.
  - Usage: the highest token counts and cost of all chunks and the last
    non-empty finish reason are kept, and log probabilities are appended. The
    `responseMeta` of the last chunk that had one used to be taken whole.
  - `extra`: strings under the same key are concatenated and maps are merged
    recursively; the last value used to win. Lists are still appended.
  - Neighbouring text, reasoning and base64-audio output parts, and
    neighbouring text input parts, are joined.
  - A list with a single message is processed as well instead of being
    returned as it is.
- **`DocumentTransformer.transform` has an optional named parameter**,
  `{TransformerOptions? options}`, which carries the run context and the
  options of the call. The class moved to
  `components/document/transformer.dart`; `ingestion_pipeline.dart` still
  exports it.
- `InvokableTool.run` and `StreamableTool.streamRun` are no longer abstract:
  a tool overrides either them or `invokableRun` / `streamableRun`. The
  default of the older pair fails with `UnimplementedError`.
- `ToolExecutor` and the runtime `ChatModelAgent` call a tool through
  `invokableRun` / `streamableRun`, so that tools written against the new
  entry points run in them. For existing tools nothing changes.
  `ContextualTool.invokableRun` hands the cancel token of its context to the
  tool.
- `OpenRouterChatModel` and the back-off of `RetryingChatModel` also stop when
  the cancel token of `ChatModelOptions.runContext` is cancelled, not only the
  one in `ChatModelOptions.cancelToken`.
- **Chunks that contradict each other are a `MessageConcatException`**, not
  an `ArgumentError`, in `concatMessages`, `concatMessageArray`,
  `concatMessageStream` and `concatToolResults`: different roles, names, tool
  call ids or tool names, fragments of one tool call that disagree, values of
  `extra` that cannot be joined, lists of different lengths, a non-text part
  of a tool result in two chunks. That is a matter of the data a provider
  streamed, not of the calling code. Calling one of these functions without
  any chunk is still an `ArgumentError`, and `MessageConcatenator.concat`
  reports everything it rejects as `ArgumentError`, as before.
- **`LoggingHandler`, `MetricsHandler`, `TracingHandler` and
  `CallbackManager` write to `package:logging` instead of `print`.** The
  loggers are `threepio.callbacks.logging`, `.metrics` and `.tracing` (level
  `INFO`) and `threepio.callbacks` (level `WARNING`, for a handler that
  throws). Nothing appears on the console unless the application listens to
  `Logger.root.onRecord`.
- `DefaultChatTemplate.isCallbacksEnabled` is `true`: the template reports
  its work to the callback handlers of `ChatTemplateOptions.runContext`
  itself.
- `OpenAIChatModel`, `OpenRouterChatModel` and `GeminiChatModel` implement
  `TypedComponent` and `CallbackAwareComponent`.
- `fake_async` is a dev dependency.
- `ChatTemplate` and `DocumentTransformer` have a `const` constructor.
- The messages of `FormatException`s thrown by `MessageJsonParser` for a
  `fromJson` that itself throws a `FormatException` now start with `failed to
  unmarshal content:`; the original exception is the `cause`.
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
- The umbrella library no longer exports the five checkpoint classes of the
  state graph whose names the compose port uses for its own contracts:
  `CheckpointStore`, `CheckpointSerializer`, `JsonCheckpointSerializer`,
  `InMemoryCheckpointStore` and `FileCheckpointStore`. `CheckpointStore`,
  `CheckpointSerializer` and `InMemoryCheckpointStore` now name the compose
  types there. The state graph classes are unchanged and are exported from
  `package:threepio_core/legacy_graph.dart` (see "Migration notes").
- The runnable over Dart `Stream`s that `StateGraph.toRunnable()` returns and
  the chains implement was renamed to free the names for the port of Eino's
  `Runnable` and `Lambda`: `Runnable` → `LegacyRunnable`, `Lambda` →
  `LegacyLambda`, `RunnableSequence` → `LegacyRunnableSequence`,
  `RunnableOptions` → `LegacyRunnableOptions`, `RunnableException` →
  `LegacyRunnableException`. They moved from `src/compose/` to
  `src/graph/legacy_runnable.dart` and were never exported; they are now
  exported from `legacy_graph.dart`.
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

- `CallbackHandler`, `BaseCallbackHandler` and `CallbackManager`, the older
  callback API. Nothing is removed and nothing changes where they are used
  today (`StateGraph`, the model providers, `OpenAIEmbedder`,
  `VectorRetriever`, `InMemoryVectorStore`, the chains); the analyzer now
  points at them. New handlers extend `ComponentCallbackHandler`; an existing
  one joins a run of the new kind through `LegacyCallbackHandlerAdapter`.
- `RetrieverOptions.callbackManager` and `RetrieverOptions.context`: put the
  handlers on `RetrieverOptions.runContext` instead.
- The client for Langfuse's ingestion API (`/api/public/ingestion`) in
  `src/observability/langfuse/` (`LangfuseClient` and what belongs to it). It
  was never exported; Langfuse has deprecated that API. `LangfuseHandler`
  replaces it.
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

- **Catching concat conflicts.** Code that caught `ArgumentError` around
  `concatMessages`, `concatMessageArray`, `concatMessageStream` or
  `concatToolResults` to deal with a malformed stream catches
  `MessageConcatException` (or `ThreepioException`) instead. Code that calls
  `MessageConcatenator.concat` is not affected.
- **From `BaseCallbackHandler` to `ComponentCallbackHandler`.** Nothing has
  to change now. To move a handler: extend `ComponentCallbackHandler`, take
  `RunContext ctx` where the hook took the `Map<String, dynamic> context`
  (keep what the handler remembers in the context with a private
  `ContextKey`, and return the context), and take the payload as `Object?`
  where it was a `CallbackInput` or `CallbackOutput` (`input` itself is what
  `input.data` was). Give a run its handlers with
  `RunContext.background().withHandlers([...])` in place of
  `CallbackManager([...])`.
- **Firing callbacks from your own component.** `onStart`, `onEnd`, `onError`,
  `onStartWithStreamInput`, `onEndWithStreamOutput` and `onEndWithCopies` are
  not exported from `package:threepio_core/threepio_core.dart`, because a
  class that inherits a member called `onStart`, `onEnd` or `onError` and
  calls it without `this.` would call the imported function instead. Import
  `package:threepio_core/callbacks.dart`, with a prefix if the names collide
  with your own.
- **Console output of the shipped callback handlers.** `LoggingHandler`,
  `MetricsHandler.printSummary`, `TracingHandler.printTrace` and
  `printTimeline` no longer print. To see their output, listen to the logger:
  `Logger.root.onRecord.listen((r) => print(r.message));`.
- **The checkpoint classes of `StateGraph`.** Code that names
  `CheckpointStore<S>`, `CheckpointSerializer<S>`,
  `JsonCheckpointSerializer<S>`, `InMemoryCheckpointStore<S>` or
  `FileCheckpointStore<S>` imports
  `package:threepio_core/legacy_graph.dart`, with a prefix when the umbrella
  library is imported too (`import '…/legacy_graph.dart' as legacy;` and
  `legacy.InMemoryCheckpointStore<MyState>()`). Everything else of the state
  graph (`StateGraph`, `GraphBuilder`, `GraphState`, `GraphNode`,
  `GraphResult`, `START`, `END`, `CheckpointConfig`, the exceptions) is in
  the umbrella library as before.
- **The renamed runnable.** Code that imported `src/compose/runnable.dart` or
  `src/compose/lambda.dart` imports `package:threepio_core/legacy_graph.dart`
  and uses the `Legacy…` names. `StateGraph.toRunnable()` and `asNode()` work
  as before.
- **Differences from Eino in the ADK port.**
  - *Not ported*, because Eino marks it as not recommended or deprecated:
    agent transfer (sub-agents, `TransferToAgentAction`, `ExitTool`,
    `GenTransferMessages`, `WithSkipTransferMessages`, `RunPath`), the
    workflow agents (sequential, parallel, loop), `OutputKey` (write a session
    value in a middleware's `afterAgent` instead), the struct-based
    `AgentMiddleware`/`Middlewares`, `ModelRetryConfig.IsRetryAble` (without
    `shouldRetry` every error is retried, Eino's default), `ModelContext.Tools`,
    `WithHistoryModifier`, the embedded `InterruptInfo` of `ResumeInfo`, the
    deprecated `Info` of the runner's checkpoint, and the agentic message
    types (later, optional phase).
  - *Checkpoints* are JSON, not `gob`: the runner's checkpoint keeps the
    session values, the input of the run, the streaming flag and the
    interrupt points; there is no event history (it served agent transfer).
    The interrupt state of a `ChatModelAgent` and of an `AgentTool` (the
    checkpoint of their inner graph or runner) is a Base64 string, where Go
    keeps `[]byte`. Values in session values, run-local values and interrupt
    states must be JSON or registered with `TypeRegistry`.
    `setRunLocalValue` refuses a value that cannot be written.
  - *Events* are immutable (`copyWith`); `MessageVariant.role` is nullable
    (Go's empty role). A streamed message is read once; `getMessage()` keeps
    the joined message, and `getMessageFromEvent` reads a copy so that the
    event stays readable.
  - *Run-local values* are read and written synchronously (Go returns an
    error; Dart throws `StateError` outside a `ChatModelAgent` run).
  - *Tools of the model*: a `ChatModelAgent` passes them in
    `ChatModelOptions.tools` and, for a `ToolCallingChatModel`, also binds
    them with `withTools`.
  - *Layer payload*: Go keeps the run path of the interrupting agent in the
    interrupt state; without run paths it is empty here.
  - *Callbacks*: `AgentCallbackHandler` of the umbrella library still passes
    payloads on as they are (earlier releases relied on it);
    `typedAgentCallbackHandler` gives the typed reports.
  - *Streams*: the agent reads the output stream of its graph to its end
    (Go closes it unread), so that an error inside it is not lost.
- **Differences from Eino in the run-control port.**
  - *Cancel results*: `AgentCancelFunc` returns a `CancelHandle` whose
    `contributed` is Go's second return value, and `wait()` returns a
    `CancelOutcome` where Go returns `nil`, `ErrCancelTimeout` or
    `ErrExecutionEnded`.
  - *An immediate cancel abandons* the running model or tool call: Dart
    cannot stop a future, so its result is ignored and it runs again on
    resume. A recursive immediate cancel of a run in which an `AgentTool` has
    run waits up to 1 s for the nested agents' interrupts before it
    interrupts the agent's own graph (Go: the same grace period, and the same
    rule); the `AgentCancelFunc` call itself does not block during it (Go's
    does).
  - *Tool middlewares* of a `ChatModelAgent` must let a
    `StreamCanceledException` through: the agent ends tool streams with it
    on an immediate cancel (its own middleware sits inside the user's).
  - *TurnLoop*: checkpoints are JSON, items go through `TypeRegistry` (JSON
    values or registered types). `push` returns `resolved`, which is `null`
    where Go returns a nil channel (a push that does not preempt, or is not
    accepted). Push strategies are synchronous. A preempt or stop takes effect
    through a watcher that runs in a microtask after the push or stop call.
    A loop whose context is cancelled exits with a `CancelledException`
    (Go: `context.Canceled` or `context.DeadlineExceeded`). Invalid
    arguments and misuse throw `ArgumentError` / `StateError` where Go
    panics.
  - *Filesystem*: grep patterns are Dart regular expressions (Go: RE2); a
    leading inline flag group (`(?i)`, `(?m)`, `(?s)`) is understood, inline
    flags elsewhere are not, nor are RE2-only escapes such as `\A`, `\z`,
    `\pL` or `[[:alpha:]]`; `.` matches everything but `\n`, as in RE2.
    Globs keep Eino's doublestar syntax and are matched with `package:glob`
    after translation; contrived corners still differ: a `**` that only
    becomes a whole segment through brace expansion (`{a/,b/}**/x`, or
    `{**}`), classes inside brace options (`{[,]x,y}`), and the classes
    `[/]` and `[z-a]`, which `package:glob` rejects.
    `FileInfo.modifiedAt` is UTC ISO 8601 (Go: local RFC 3339 with
    nanoseconds); sizes are UTF-8 byte lengths, as in Go.
  - *GraphTool* (an eino-examples package in Go) takes `params` and a
    `fromJson` function where Go infers the schema from the input struct; the
    graph's checkpoint in the tool's interrupt state is Base64.
- **Differences from Eino in the middleware port.**
  - *Not ported*, because Eino deprecates them: the filesystem middleware's
    `Config`/`NewMiddleware` path with its large tool result offloading (use
    `ToolReductionMiddleware`) and the `Custom*ToolDesc` fields (use
    `FilesystemToolConfig.desc`); `reduction.NewClearToolResult` and
    `NewToolResultMiddleware`; `skill.New` and `Config.UseChinese`;
    `patchtoolcalls.Config.PatchedContentGenerator`. The agentic-message
    variants (`NewTyped[*schema.AgenticMessage]`) belong to the agentic port.
  - *Construction*: a configuration Go's `New` rejects makes the constructor
    throw `ArgumentError` with Go's text. `ToolSearchMiddleware.create` is
    asynchronous because a tool's `info()` is. `SkillMiddleware` builds a
    custom system prompt once, with a background context (Go: the context
    given to `New`).
  - *Missing files*: the agents.md middleware skips a file whose read throws
    `FileNotFoundException` (Go: an error wrapping `os.ErrNotExist`); since
    `InMemoryBackend` throws it, a missing file is a warning with that
    backend too (Eino's in-memory backend does not wrap `os.ErrNotExist`, so
    the same setup fails in Go).
  - *Lengths* (budgets, truncation points, token estimates) are UTF-8 byte
    counts, as in Go. The default token estimators measure a tool the way Go
    does (its name and description, not its parameters).
  - *`SkillMiddleware.wrapModel`* is synchronous in Dart: the model a skill
    switched to is asked of the `ModelHub` when it is called, so a hub
    failure surfaces from that call.
  - *Errors* are thrown (`ThreepioException` with Go's text, the wrapped
    error as `cause`). The summarization middleware's attempts still treat a
    model failure as a value that `shouldRetry`/`shouldFailover` decide on,
    as Go does.
  - *Messages are immutable*: where Go edits messages in place (the clear
    phase of the reduction middleware, the summary's content type), the Dart
    port puts changed copies in the state's message list.
  - *Filesystem tools*: the parameter schemas Go infers from struct tags are
    written out (same names, descriptions and required fields; `replace_all`
    has no `default: false`, which `ParameterInfo` cannot express). `grep`
    sorts by path and line with a stable sort, as Go's `sort.SliceStable`.
    `FilesystemMiddleware`'s `customSystemPrompt` has no default text, as in
    Eino v0.9.22. The streaming `execute` tool releases the command's stream
    when its consumer closes early.
  - *Tool arguments* are decoded with exact key names (Go's `encoding/json`
    also accepts other capitalisations) and accept a whole-number float for
    an integer field.
  - *Run context of tool infos*: Dart's `BaseTool.info()` takes no context.
    The skill tool also implements an internal context-aware variant, which
    the `ChatModelAgent` uses for the tools middlewares add, so its skill
    list is built with the run's context (session values) as in Go.
  - *Reduction history*: within a run the cleared results stay in the
    agent's state; Go also edits the caller's message objects in place, so a
    caller who feeds the original history to a new run gets it cleared (and
    offloaded) again in Dart. Carry the history forward from the agent's
    final state.
  - *Tool search, model-native mode without static tools*: the tools the
    model is told about stay empty on later calls; in Go a nil list makes
    the engine refill it with every tool.
  - *Summarization events* register `SummarizationAction` with
    `TypeRegistry` when a `SummarizationMiddleware` is created (Go: at
    package initialisation).
- **Differences from Eino in the compose port.** Mistakes in building a graph
  throw (`GraphBuildException`) where Go returns an error, and a chain reports
  its first mistake from `compile`. An edge may lead from any supertype to a
  subtype, not only from an interface, and is then checked at run time. The
  default fan-in merge gives a `Map<String, Object?>`; a node that takes a
  narrower map type behind a fan-in needs `ValuesMerge.register`. A stream of
  a `ToolsNode` carries empty tool messages where Go has `nil` entries. The
  order in which nodes of a step are started, and in which map-valued inputs
  are merged, is the order in which nodes and edges were added. Component
  options are one object per kind that is merged, not a list of functions,
  and an option reaches the nodes that take options of the type it was made
  for (`CallOption.lambda<T>` the lambdas declared with `T`). There is no
  `Passthrough` component kind; `GraphNodeInfo.isPassthrough` says it. A
  compile callback that throws is logged (`threepio.compose`) and does not
  fail `compile`. A node checks for cancellation before it starts, in
  addition to the check between steps. `JsonFixMiddleware` repairs with a
  small reader of its own, and a tools node that applies an argument alias
  writes the arguments anew.
- **Interrupt, resume and checkpoints compared with Eino.**
  - *Types in checkpoints.* Go writes checkpoints with `gob` and finds types
    by reflection. Here a checkpoint is JSON, and every value in it that is
    not JSON has to be registered with `TypeRegistry.registerName` before a
    run is interrupted or resumed: the state of a graph, what a component
    passes to `statefulInterrupt`, the inputs and outputs of nodes that can
    be in flight when the run stops. Messages, documents and the other schema
    types are registered. A value that cannot be written fails the run with a
    `CheckpointEncodeException` that names it, instead of leaving a
    checkpoint that could not be resumed. Lists and maps lose their element
    types in JSON; the engine gives the inputs and outputs of nodes, and the
    states `getInterruptState` returns, the types the nodes declare, as wide
    as the declared type allows (`List<num>` for a list of integers, a
    `List<String>` that can grow for an empty list). An empty list for an
    element type the engine does not know (not registered, no blank) takes no
    elements.
  - *The input of a node that runs again.* In Go a node that interrupted
    from inside runs again with the zero value of its input type, and keeps
    its input only under `WithGraphInterrupt`. Dart has no zero value for
    most types. A node whose input type has an empty value (`String`, `num`,
    `bool`, a nullable type, a `List`, a `Map`) gets that value, as in Go; a
    node whose input type has none (a non-nullable class such as `Message`)
    gets the input it had, which is kept in the checkpoint. Under
    `ctx.withGraphInterrupt()` every node gets its input back, as in Go. Use
    `getInterruptState` to tell a first run from a resumed one, not the
    input.
  - *Field mappings.* Go maps struct fields by reflection and checks field
    names and types when a workflow is compiled. Here a class takes part
    through `FieldAddressable`, and an unknown field or a value that does not
    fit a field is found when the workflow runs (`FieldMappingException`).
    Still found at `compile`: a successor or predecessor that cannot hold
    fields, a map whose keys are not strings, two mappings to one field, a
    field that is mapped twice as a whole. A class that mappings write to, or
    that has to be created on the way to a field (Go creates the struct of a
    nil pointer from the field's type), registers its empty value
    (`FieldAddressable.registerBlank`); `Message` (a user message without
    content) and `Document` have one. The text form of a mapping joins the
    names of a path with a dot where Go prints its separator (U+001F).
  - `InterruptAndRerun`, `NewInterruptAndRerunErr`,
    `WrapInterruptAndRerunIfNeeded`, `RegisterSerializableType` and
    `Workflow.AddEnd` are deprecated in Eino and not ported: use `interrupt`,
    `TypeRegistry.registerName` and `Workflow.end()`.
  - `CallOption.forceNewRun()` takes effect wherever it is in the option
    list (in Go only as the last option).
  - `GraphInterruptedException` is an `InterruptSignal`, so that code which
    catches errors lets it through. A graph that gets one from a node which
    did not wrap it with `compositeInterrupt` passes it on unchanged and
    writes no checkpoint of its own, as in Eino.
  - A custom `CheckpointSerializer` gets the checkpoint as an object that
    only `JsonCheckpointSerializer.toJson` can take apart, and has to return
    what `JsonCheckpointSerializer.fromJson` gives: it wraps the JSON form
    (compression, encryption) rather than replacing it.
  - A tool whose stream ends without a chunk has the empty result; Eino
    v0.9.22 fails the stream of the tools node there.
  - The time `GraphInterrupter.interrupt(timeout:)` gives runs from the call,
    as in Eino. It is measured in real time; a test on fake time that
    interrupts before the run has started gets the timeout from the start of
    the run.
  - Interrupt ids are UUIDs; node and task order is the order of insertion.
- A class that `implements` `OpenAIChatModel`, `OpenRouterChatModel` or
  `GeminiChatModel` (instead of extending it) has to add `componentTypeName`
  and `isCallbacksEnabled`.
- Rename `RunContext(...)` to `AgentRunScope(...)` where you pass a `context:`
  to `ChatModelAgent.run`. Code that goes through `Runner` is not affected.
- `StreamReader` can no longer be instantiated or extended; it never had a
  public constructor. A class that `implements` it (a test double) has to add
  `nextOrNull`, `convert` and `setAutomaticClose`.
- A `switch` over `ChatMessagePartType` without a `default` needs cases for
  `reasoning` and `toolSearchResult`.
- If you relied on `MessageConcatenator.concat` keeping the last value of a
  string in `extra`, see "Changed" above.
- A class that extends or implements `DocumentTransformer` has to add the
  parameter to its `transform`:
  `Future<List<Document>> transform(List<Document> documents, {TransformerOptions? options})`.
- A class that `implements TextSplitter` (instead of extending it) has to add
  `transform` and `withOptions`. A class that `implements` one of the
  exception types of this package, or `ChatModelException`, has to add
  `Object? get cause` (and `String get message` where the type had none).
- A `switch` over `ComponentType` without a `default` needs cases for the
  seven new values.
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
