# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - 2026-11-06

Parity with Eino v0.9.22 and the eino-ext components that make sense in Dart.
The version tracks Eino's minor version; the package stays 0.x until the
names that collide between the two API generations are settled (see the
README, "Which API do I use?").

This release ports the Eino packages `schema` (messages, tool definitions and
results, documents, templates, pull-based streams, chunk concatenation, the
type registry) with the run context every API takes; `components` (the
contracts of chat models, tools, templates, embedders, retrievers, indexers,
loaders, parsers and transformers, their options and callback payloads, tools
made from functions); `callbacks` and `utils/callbacks`, with tracing to
Langfuse over OpenTelemetry and to LangSmith; `compose` (runnables, lambdas,
graphs, chains, workflows, the tools node, interrupt, checkpoint and resume);
`adk` (agents, the runner, interrupt and resume, middlewares, retry and
failover of the model, cancel, the turn loop, the filesystem backend, the
eight built-in middlewares, the deep agent and plan-execute-replan), on which
the Kortney runtime now runs; and the retrieval flows of `flow`. From
eino-ext: the chat model providers (OpenAI, OpenRouter, Claude, Gemini,
Ollama, OpenAI-compatible endpoints), embedders and an embedding cache, the
MCP client with its tools and prompt template, the local filesystem backend,
document loaders, parsers and transformers, the HTTP request, search,
Wikipedia, sequential-thinking and command-line tools, and the Qdrant indexer
and retriever. The agentic path, which upstream labels beta, is ported as
beta: agentic messages of typed content blocks, the agentic model, template
and tools node, the agentic chat model agent and runner, and the OpenAI
Responses and Claude agentic models.

The older API stays exported with its names, signatures and behaviour (see
"Migration notes" and `doc/MIGRATION.md`); the few intentional breaks are
listed there. The entries below were written phase by phase on the branch, so
some describe a change against an earlier pre-release build of 0.9 rather
than against 0.1.0; `doc/MIGRATION.md` lists only what changed against 0.1.x.

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

- **Documentation and examples for 0.9.** The README is rewritten around the
  Eino shape: quick start (template → model chain, `adk.ChatModelAgent` with
  `adk.Runner`, interrupt and resume, a graph with state), the mapping from
  Eino's Go names to the Dart ones, "Which API do I use?", and the legacy
  API. `doc/GRAPHS.md`, `doc/CALLBACKS.md`, `doc/RAG.md` and
  `doc/LANGFUSE_DESIGN.md` describe the Eino-shaped API, each with a section
  on the older one; `doc/MIGRATION.md` is new; `doc/NEW_FEATURES.md` is
  brought up to date; `doc/eino_feature_parity_plan.md` is marked superseded.
  New examples: `graph_react_example.dart`, `workflow_example.dart`,
  `hitl_approval_example.dart`, `deep_agent_example.dart`,
  `mcp_tools_example.dart`, `turn_loop_example.dart`,
  `agentic_agent_example.dart`, and ports of the eino-examples
  `quickstart/chat`, `quickstart/todoagent`, `compose/graph/state` and
  `adk/human-in-the-loop/1_approval` in `example/eino_examples/`. The
  new examples read their model from the environment (`example/support/`; the
  agentic example builds its own `OpenAIResponsesModel`) and are run offline,
  with `checkpoint_example.dart`, by `test/unit/examples/`; no example imports
  `src/` any more. Every ```` ```dart ```` block of the README and of `doc/`
  (except the superseded plan) is mirrored in a file
  the analyzer checks (`test/doc_snippets/`, `example/`), and
  `test/unit/docs/doc_snippets_test.dart` fails when a block has no mirror.
- **Live smoke test of the agentic providers through OpenRouter**
  (`test/integration/openrouter_agentic_smoke_test.dart`, tagged
  `integration`): `OpenAIResponsesModel` against OpenRouter's
  `/api/v1/responses` and `ClaudeAgenticModel` against `/api/v1/messages`
  (bearer authentication, no library change needed): generate, stream and a
  function-tool round trip through `AgenticChatModelAgent` and
  `AgenticRunner`. With `OPENROUTER_SERVER_TOOLS=1` it also asks for the
  server tools whose wire names could not be checked against the SDK
  sources (Responses web search, shell and deferred tool search; Claude's
  2026 web search, web fetch and code execution). It runs only with
  `THREEPIO_INTEGRATION=1` and `OPENROUTER_API_KEY`, never prints the key,
  and logs the item, block and usage field names it sees, marking those the
  converters do not know. It has not been run yet.
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
- **ADK prebuilt agents** (port of Eino `adk/prebuilt`), in `adk.dart`:
  - `DeepAgent.create(ctx, DeepAgentConfig(...))`: a `ChatModelAgent` with
    Eino's instruction, a `write_todos` tool (the todo list, `Todo`, is the
    session value `DeepAgent.sessionKeyTodos`), the file and shell tools of
    `FilesystemMiddleware` when there is a backend, and a `task` tool that
    starts a sub-agent (one of `subAgents` or a general-purpose copy of the
    agent) on a task with a fresh context (`TaskToolDescriptionGenerator`
    for a custom description).
  - `PlanExecute.planner/executor/replanner/create` (`PlannerConfig`,
    `ExecutorConfig`, `ReplannerConfig`, `PlanExecuteLoopConfig`, `Plan`,
    `PlanDecoder`, `ExecutionContext`, `ExecutedStep`,
    `PlanExecuteResponse`, the typedefs `PlannerModelInput` and
    `ExecutionModelInput`): a planner writes a plan, then, in a loop, an
    executor (a `ChatModelAgent` with tools) does its first step and a
    replanner revises the plan or answers; Eino's prompts, plan and respond
    tools and session keys; an interrupt inside the executor is resumed
    there.
  - `PlanExecute.breakLoopAction(agentName)` (port of `adk.NewBreakLoopAction`):
    the action with which a custom replanner (or any agent in the loop) ends
    the loop. It is the only public piece of Eino's workflow agents, which
    stay internal.
- **Retrieval flows** (port of Eino `flow/retriever` and `flow/indexer`), in
  the new library `package:threepio_core/flow.dart` (also exported by the
  umbrella library):
  - `MultiQueryRetriever.fromConfig(ctx, MultiQueryRetrieverConfig(...))`
    (`multiquery.NewRetriever`): a chat model (with Eino's prompt unless
    another template is given) or a handler writes several queries, at most
    `maxQueries` (5) of them are retrieved from `origRetriever` at the same
    time, and the results are fused (by default each document id once). The
    rewrite runs as the compose chain `QueryRewrite`; the call is
    asynchronous because that chain is compiled (under `ctx`).
  - `ParentRetriever.fromConfig(retriever:, parentIdKey:, origDocGetter:)`
    (`parent.NewRetriever`): finds sub-documents and returns their parents,
    fetched by the parent ids in the sub-documents' metadata.
  - `RouterRetriever.fromConfig(retrievers:, router:, fusion:)`
    (`router.NewRetriever`): a router picks retrievers (all of them by
    default), each is asked at the same time, and the results are fused by
    reciprocal rank (by default).
  - `ParentIndexer(indexer:, transformer:, parentIdKey:, subIdGenerator:)`
    (`parent.NewIndexer`): splits documents with a transformer, gives the
    pieces ids of their own and their parent's id in the metadata, and
    stores them.
  - `concurrentRetrieve(ctx, tasks)` and `RetrieveTask`
    (`utils.ConcurrentRetrieveWithCallback`): runs retrievals side by side,
    each reported to the callback handlers as a retriever; results and
    errors are left in the tasks.

  The three retrievers are static methods of the existing classes, whose
  constructors and behaviour are unchanged, and return a plain `Retriever`
  that works on its own and as a graph or chain node. They report their
  inner steps to the callback handlers of the run (`options.runContext`):
  the router and the fusion as the lambdas `RouterLambda` and
  `FusionFuncLambda`, every retrieval as a retriever named after its
  implementation (`MockRetriever`, `VectorRetriever`), the multi-query
  rewrite as the chain `QueryRewrite`.
- **OpenAI-compatible providers** (port of eino-ext `libs/acl/openai`,
  `model/openai`, `model/openrouter`, `model/qwen`, `model/deepseek`,
  `embedding/openai`, `embedding/dashscope`):
  - One client for every Chat Completions API (internal): request building,
    server-sent events with an idle timeout, usage in streams
    (`stream_options.include_usage`), cancellation through
    `ChatModelOptions.cancelToken` and `runContext`, classification of
    failures (`isRetryable`, `isModelUnavailable`), payload and response
    modifiers, extra headers and fields. `OpenAIChatModel` and
    `OpenRouterChatModel` both run on it.
  - `OpenAIConfig` gains Eino's `ChatModelConfig` fields: `byAzure`,
    `apiVersion`, `azureModelMapper` (Azure OpenAI routing with an `api-key`
    header), `temperature`, `topP`, `stop`, `maxCompletionTokens`,
    `presencePenalty`, `frequencyPenalty`, `responseFormat` (the existing
    `ResponseFormat`), `seed`, `logitBias`, `user`, `logProbs`,
    `topLogProbs`, `reasoningEffort` (the existing `ReasoningEffort`),
    `extraFields`, `customHeaders`, `modalities` + `audio`
    (`OpenAIModality`, `OpenAIAudioConfig`), `idleTimeout`. All optional; the
    existing constructor calls are unchanged.
  - `OpenAIRequestOptions` (Eino `WithExtraFields`, `WithExtraHeader`,
    `WithReasoningEffort`, `WithMaxCompletionTokens`,
    `WithRequestPayloadModifier`, `WithResponseMessageModifier`,
    `WithResponseChunkMessageModifier`) in `ChatModelOptions.extensions`;
    the modifier types `RequestPayloadModifier`, `ResponseMessageModifier`,
    `ResponseChunkMessageModifier`.
  - `OpenAIChatModel` now cancels, parses `reasoning_content`, log
    probabilities, cache-write and reasoning tokens and generated audio,
    honours `allowedToolNames` (Eino's `allowed_tools` tool choice), and
    keeps the response id in `extra['openai-request-id']`.
  - `OpenRouterRequestOptions` gains `models` (fallback list), `metadata`,
    `reasoningEnabled`, `reasoningSummary` (`ReasoningSummary`),
    `cacheControl` (`OpenRouterCacheControl`, `OpenRouterCacheControlTtl`),
    `logprobs` and `topLogprobs`; cache breakpoints on single messages and
    parts with `withOpenRouterCacheControl()` (Eino
    `EnableMessageContentCacheControl`,
    `EnableMessageInputPartCacheControl`,
    `EnableMessageOutputPartCacheControl`); `allowedToolNames`; log
    probabilities in responses.
  - `OpenAICompatibleChatModel` with `OpenAICompatibleConfig` and the presets
    `OpenAICompatibleConfig.deepSeek` (`DeepSeekThinking`; chat prefix
    completion with `withDeepSeekPrefix()`), `.qwen` (`enableThinking`,
    `qwenThinkingFields`) and `.ark` (the OpenAI-compatible Ark endpoint), or
    any other compatible server.
  - `OpenAIEmbedder` gains `dimensions`, `encodingFormat`
    (`EmbeddingEncodingFormat`; base64 vectors are decoded), `user`, Azure
    routing, cancellation through `options.runContext`, and
    `OpenAIEmbedder.dashScope` (Eino `dashscope.NewEmbedder`).
  - Shared helpers for provider errors: `isRetryableHttpStatus`,
    `looksLikeModelUnavailable`, `ProviderErrorDetail`.
- **Claude** (port of eino-ext `model/claude`, Anthropic Messages API only;
  Bedrock and Vertex are not ported): `ClaudeChatModel`, `ClaudeConfig`
  (`ClaudeThinkingConfig` with `ClaudeThinkingEnabled`, `ClaudeThinkingAdaptive`,
  `ClaudeThinkingDisabled`; `ClaudeCacheControl`, `ClaudeCacheTtl`,
  `ClaudeResponseFormat`, `ClaudeToolSearchAlgorithm`), `ClaudeRequestOptions`
  (Eino `WithTopK`, `WithThinkingConfig`, `WithDisableParallelToolUse`,
  `WithAutoCacheControl`, `WithResponseFormat`, `WithRequestTimeout`,
  `WithCustomHeaders`), `ClaudeException`, and the message helpers
  `claudeThinking`, `withClaudeCacheControl()` (messages and tools),
  `claudeCacheCreationInputTokens`, `claudeToolSearchEvents`. Tool use,
  thinking with its signature round trip, cache breakpoints (also
  automatic), structured output, server-side tool search events, streaming.
- **Ollama** (port of eino-ext `model/ollama` and `embedding/ollama`):
  `OllamaChatModel` with `OllamaConfig` (`OllamaFormat`, `OllamaOptions`,
  `OllamaThinkValue`/`OllamaThinkLevel`, `keepAlive`), `OllamaRequestOptions`
  (`WithSeed`), `OllamaException`, the request metrics as `msg.ollamaMetrics`
  (and in the callback output's `extra['ollama_metrics']`, as Eino reports
  them), and `OllamaEmbedder` with `OllamaEmbedderConfig`.
- **Gemini** (port of eino-ext `model/gemini` and `embedding/gemini`):
  `GeminiRequestOptions` (thinking, cached content, custom headers, extra
  fields, response schema and modalities, safety settings, image config,
  media resolution, `topK`, log probabilities) and the same knobs plus the
  server tools (code execution, Google Search and Search retrieval, URL
  context, file search, Google Maps, computer use) on `GeminiConfig`;
  thought parts as `reasoningContent` and thought signatures kept and sent
  back; `createPrefixCache` (`GeminiCachedContent`); the message helpers of
  `gemini_message_extras.dart`; cancellation; `GeminiEmbedder` with
  `GeminiEmbeddingConfig` and `GeminiEmbeddingTaskType`.
- **Embedding cache** (port of eino-ext `embedding/cache`): `CachingEmbedder`
  over an `EmbeddingCache` (`InMemoryEmbeddingCache`; `FileEmbeddingCache` in
  `io.dart`, standing in for the Redis backend) with a `CacheKeyGenerator`
  (`SimpleCacheKeyGenerator`, `HashCacheKeyGenerator` with an injected hash
  function).
- **Embedders report to callbacks**: `OpenAIEmbedder`, `OllamaEmbedder` and
  `GeminiEmbedder` fire `EmbeddingCallbackInput`/`Output` (with the token
  usage) to the handlers of `options.runContext` and the global ones, and
  are `TypedComponent`/`CallbackAwareComponent`.
- **MCP** (port of eino-ext `tool/mcp`, `tool/mcp/officialmcp` and
  `prompt/mcp`), in `components.dart`: `McpClient` (JSON-RPC 2.0:
  `initialize`, `tools/list` with pagination, `tools/call`, `prompts/list`,
  `prompts/get`, `ping`) with the protocol types (`McpTool`,
  `McpCallToolResult`, the sealed `McpContent`, `McpPrompt`, …) and
  `McpException`; transports `StreamableHttpTransport` (JSON and SSE replies,
  sessions, resumption) and `SseTransport`, and `StdioTransport` in
  `io.dart`; `McpToolkit.getTools(ctx, …)` with Eino's tool-name list and
  mapper, list mode and page limit, metadata mode, description and result
  policies and result handlers, returning tools that are both
  `InvokableTool` (text) and `EnhancedInvokableTool` (multimodal
  `ToolResult`); `McpSession` (connect from a server config, reconnect once on
  a connection error); `McpPromptTemplate`, a `ChatTemplate` backed by
  `prompts/get`.
- **Local filesystem backend** (port of eino-ext `adk/backend/local`), in
  `io.dart`: `LocalFilesystemBackend` (one class, like Go's `Local`, that is
  a `FilesystemBackend`, `MultiModalReader`, `Shell` and `StreamingShell`):
  `lsInfo`, `read`, `grepRaw` (ripgrep's behaviour, emulated in-process),
  `globInfo`, `write`, `edit`, image and PDF reads with Eino's size limits
  (`LocalMultiModalReadConfig`), and commands through `/bin/sh -c` with an
  optional `CommandValidator`; `LocalShell` runs commands on its own.
- **Filesystem**: `FileReadBackend` and `FileWriteBackend`, the read and write
  halves of `FilesystemBackend` (which implements both), and
  `FileNotFoundException`, which a backend throws for a missing file that the
  agents.md middleware should skip (Go: an error wrapping `os.ErrNotExist`).
  `InMemoryBackend`, like eino's in-memory backend, does not: it reports a
  missing file with a plain `ThreepioException`.
- **Tool infos that keep a JSON Schema document as it is** (coordinator
  decision after P11; Go `schema.NewParamsOneOfByJSONSchema` for any
  schema): `ToolInfo.fromJsonSchemaMap`, `ParamsOneOf.jsonSchemaMap` (with
  the getter `jsonSchemaMap`), `FunctionInfo.parametersJsonSchema` (left out of `toJson` when `null`) and
  `ToolInfo.fromParamsOneOf` (the tool info for any `ParamsOneOf` form).
  Every keyword survives (`anyOf`, `$ref`, `$defs`, `format`, `default`, …);
  `function.parameters` holds the part threepio's `JSONSchema` can describe.
  The providers send the document as given: OpenAI-compatible models and
  OpenRouter as `parameters`, Gemini as `parametersJsonSchema`, Claude its
  `properties` and `required`, Ollama each property's `anyOf`, type (lists
  too), items, description and enum, as eino-ext does for every schema.
- **Document transformers** (port of eino-ext `transformer/splitter/*` and
  `transformer/reranker/score`), in `components.dart`, as
  `DocumentTransformer`s: `RecursiveCharacterTextSplitter.fromConfig`
  (`RecursiveSplitterConfig`: `chunkSize`, `overlapSize`, `separators`,
  `lenFunc`, `keepType` with `SplitterKeepType`, `idGenerator` with
  `SplitIdGenerator`), `MarkdownSplitter.fromHeaderConfig`
  (`MarkdownHeaderSplitterConfig`: header map, `trimHeaders`, `idGenerator`;
  lines inside ``` or ~~~ fences are never headers),
  `HtmlSplitter.fromHeaderConfig` (`HtmlHeaderSplitterConfig`, on
  `package:html`), `SemanticSplitter` (`SemanticSplitterConfig`: embedder,
  buffer size, minimum chunk size, separators, percentile) and
  `ScoreReorderTransformer` ("lost in the middle": the best documents at both
  ends). The existing splitter classes are unchanged.
- **Qdrant** (port of eino-ext `indexer/qdrant` and `retriever/qdrant`, over
  Qdrant's REST API instead of gRPC): `QdrantIndexer.create`
  (`QdrantIndexerConfig`:
  collection, vector size, `QdrantDistance`, batch size, embedder; creates the
  collection when it is missing) and `QdrantRetriever`
  (`QdrantRetrieverConfig`, per-call `QdrantRetrieverOptions` with a filter),
  both firing the indexer/retriever callbacks, on `QdrantClient`
  (`QdrantPoint`, `QdrantScoredPoint`, `QdrantUpdateResult` with
  `QdrantUpdateStatus`, `QdrantException`). Queries use
  `POST /collections/{c}/points/query` (Qdrant 1.10 or later), the REST
  counterpart of the go-client's `Query`.
- **Tools** (port of eino-ext `tool/*`), in `components.dart`:
  - `HttpRequestToolkit` with `HttpGetRequestTool`, `HttpPostRequestTool`,
    `HttpPutRequestTool`, `HttpDeleteRequestTool` (`httprequest`;
    `HttpRequestToolConfig`, `HttpRequestToolkitConfig`).
  - `GoogleSearchTool` (`googlesearch`, the Custom Search JSON API;
    `GoogleSearchConfig`, `GoogleSearchRequest`, `GoogleSearchResult`,
    `GoogleApiException`).
  - `WikipediaTool` (`wikipedia`; `WikipediaConfig`, `WikipediaException`,
    `WikipediaApiException`).
  - `DuckDuckGoSearchTool` (`duckduckgo/v2`, scraping DuckDuckGo's HTML
    page: not meant for production, as upstream says; `DuckDuckGoConfig`,
    `DuckDuckGoRegion`, `DuckDuckGoTimeRange`, `DuckDuckGoSearchClient`).
  - `SearxngSearchTool` and `SearxngClient` (`searxng`; `SearxngClientConfig`,
    `SearxngSearchRequestConfig` with `SearxngTimeRange`, `SearxngLanguage`,
    `SearxngSafeSearch`, `SearxngEngine`).
  - `SequentialThinkingTool` (`sequentialthinking`).
  - `PyExecutorTool` and `StrReplaceEditorTool` over a
    `CommandLineOperator` (`commandline`); `LocalOperator` (in `io.dart`)
    runs commands with `dart:io` processes, without a shell. The Docker
    sandbox is not ported.
  - The search tools answer the model exactly as Go does and also give Dart
    callers their hits as the shared `SearchResult` (title, URL, snippet,
    extra).
- **LangSmith** (port of eino-ext `callbacks/langsmith`), in
  `callbacks.dart`: `LangSmithHandler` (`LangSmithConfig`), a
  `ComponentCallbackHandler` that creates a run with `POST /runs` at the start
  of every component and updates it with `PATCH /runs/{id}` at its end;
  `LangSmithTrace` (session, tags, metadata, reference example of a run;
  `LangSmithTraceOptions`, `LangSmithState`), `LangSmithFlowTrace` (several
  runs in one trace), `LangSmithClient` (`LangSmithApi`, `LangSmithRun`,
  `LangSmithRunPatch`, `LangSmithRunType`, `LangSmithException`). Requests
  are sent in the background, in order, never blocking or breaking the run;
  `flush()` and `shutdown()` wait for them. Not yet verified against a live
  LangSmith project: `test/integration/langsmith_integration_test.dart` does
  that check when run with `THREEPIO_INTEGRATION=1` and a key.
- **Document loaders and parsers** (port of eino-ext `loader/file`,
  `loader/url`, `parser/html`, `parser/pdf`, `parser/docx`,
  `parser/xlsx`): `FileLoader` (`FileLoaderConfig`; in `io.dart`) and the
  URL loader `UrlLoader.fromConfig` (`UrlContentLoader`, `UrlLoaderConfig`
  with a parser, a client, a request builder and a timeout), both
  `Loader`s that fire the loader callbacks; eino-ext's HTML parser
  `HtmlParser.fromConfig` (`HtmlContentParser`, `HtmlParserConfig` with a
  CSS selector, `htmlBodySelector`; on `package:html`, with the text passed
  through a port of bluemonday's UGC policy as Go does), `PdfParser`
  (`PdfParserConfig`, `PdfParserOptions`; the text comes from an injected
  `PdfTextExtractor`, since there is no pure-Dart PDF text extraction),
  `DocxParser` (`DocxParserConfig`: sections, headers, footers, tables as
  Markdown, a port of docx2md; `DocxParser.sectionTypeOf`) and `XlsxParser`
  (`XlsxParserConfig`: sheet, header row, id prefix; one document per row),
  both reading the zip archive themselves with `package:archive` and
  `package:xml`. The metadata keys are top-level constants
  (`fileLoaderMetaKeyFileName`, `htmlMetaKeyTitle`, `docxMetaKeySectionType`,
  `xlsxMetaKeyRow`, …). The legacy `HtmlParser` gains an optional
  `selector`: when it is set, the parser works on the elements it selects
  (the outermost ones, in document order); without it nothing changes.
- **Agentic path (beta; port of the `AgenticMessage` half of Eino and of
  eino-ext's agentic models).** Upstream labels all of it beta and advises
  to keep `Message` unless model-native agentic protocols are needed; the
  classic path is unchanged and stays the default.
  - *Schema* (`schema.dart`, umbrella): `AgenticMessage` (`role`, ordered
    `contentBlocks`, `responseMeta`, `extra`; `AgenticMessage.system`,
    `.user`), `ContentBlock` (`content`, `streamingMeta`, `extra`; typed
    getters) over the sealed `ContentBlockVariant` hierarchy — `Reasoning`,
    `UserInputText/Image/Audio/Video/File` (sealed `UserInputVariant`),
    `AssistantGenText/Image/Audio/Video`, `FunctionToolCall`,
    `FunctionToolResult` (`FunctionToolResultContentBlock`),
    `ToolSearchFunctionToolResult`, `ServerToolCall`, `ServerToolResult`,
    `AgenticMcpToolCall`, `AgenticMcpToolResult`, `AgenticMcpListToolsResult`,
    `AgenticMcpToolApprovalRequest`, `AgenticMcpToolApprovalResponse` (Go's
    `MCP…` blocks; the `Mcp…` names belong to the MCP client) —,
    `ContentBlockType`, `AgenticRoleType`, `AgenticResponseMeta`,
    `StreamingMeta`; Go's JSON form and `String()` text; `concatAgenticMessages`
    and `concatAgenticMessagesArray`; `AgenticMessagesTemplate`,
    `AgenticMessagesPlaceholder` and `AgenticMessage.format`;
    `AgenticToolChoice` (`AgenticAllowedToolChoice`, `AgenticForcedToolChoice`,
    sealed `AllowedTool` = `AllowedFunctionTool` | `AllowedMcpTool` |
    `AllowedServerTool`); the provider extensions `OpenAI…`, `Claude…` and
    `Gemini…` (`src/schema/extensions/`, Go's `schema/openai|claude|gemini`)
    with their concat functions.
    `AgenticMessage` and `List<AgenticMessage>` are registered with
    `TypeRegistry` (`_eino_agentic_message`, `_eino_agentic_message_slice`) and
    `StreamConcat`; `AgenticMessage` is `FieldAddressable` and a built-in
    blank of workflow field mappings.
  - *Components* (`components.dart`): `AgenticModel` (`generate`/`stream`;
    tools per call in `ChatModelOptions.tools`),
    `ChatModelOptions.agenticToolChoice`, the callback payloads
    `AgenticModelCallbackInput/Output/Config`; `AgenticChatTemplate`
    (`AgenticChatTemplate.fromAgenticMessages`, `DefaultAgenticChatTemplate`)
    with `AgenticPromptCallbackInput/Output`; the `ComponentType` values
    `agenticModel`, `agenticChatTemplate`, `agenticToolsNode`, `agenticAgent`.
  - *Compose* (`compose.dart`): `AgenticToolsNode` (a `ToolsNode` behind
    Go's conversions: function calls in, one user message with a
    `FunctionToolResult` or `ToolSearchFunctionToolResult` per call out);
    `addAgenticModelNode`, `addAgenticChatTemplateNode`,
    `addAgenticToolsNode` on `Graph` and `Workflow`, `appendAgentic…` on
    `Chain`, `addAgentic…` on `ChainBranch` and `Parallel`.
  - *Callbacks* (`callbacks.dart`): `HandlerHelper.agenticModel`,
    `.agenticPrompt`, `.agenticToolsNode`, `.agenticAgent` with
    `AgenticModelCallbackHandler`, `AgenticPromptCallbackHandler`,
    `AgenticToolsNodeCallbackHandlers`, `AgenticAgentCallbackHandler`.
    `LangfuseHandler` traces agentic models as generations, agentic
    templates as chains and agentic agents as agents (with the messages of
    their events).
  - *ADK* (`adk.dart`): `AgenticChatModelAgent` (`AgenticChatModelAgentConfig`,
    `AgenticGenModelInput`, `defaultAgenticGenModelInput`) — the ReAct loop
    over an `AgenticModel` and an `AgenticToolsNode`, `returnDirectly`,
    `maxIterations`, streaming, the nine-hook `AgenticChatModelAgentMiddleware`
    (`AgenticChatModelAgentState`, `AgenticModelContext`), interrupts from
    tools, cancel at the safe points (`withCancel`), callbacks with
    `ComponentType.agenticAgent` (`AgenticAgentCallbackInput/Output`,
    `typedAgenticAgentCallbackHandler`); `AgenticRunner` (`run`, `query`,
    `resume`, `resumeWithParams`, checkpoints in the classic format plus the
    agentic root input); `AgenticAgent`, `ResumableAgenticAgent`,
    `AgenticAgentInput`, `AgenticAgentEvent`, `AgenticAgentOutput`,
    `AgenticMessageVariant`, `getAgenticMessageFromEvent`, the
    `agentic…InterruptEvent` helpers, `AgenticAgentContext`,
    `agenticMessageIdOf`/`ensureAgenticMessageId`; `AgenticAgentTool` (an
    agentic agent as a tool, with interrupt and resume). Actions, interrupt
    infos, resume parameters, run options and session values are the
    classic types. The agentic engine shares the classic one's internals
    through an internal message codec; the classic `Agent`, `Runner` and
    `ChatModelAgent` stay as they are (not generic over the message type).
  - *Providers* (umbrella): `OpenAIResponsesModel` (port of eino-ext
    `agenticopenai`'s Responses model: `OpenAIResponsesConfig`,
    `OpenAIResponsesOptions` for the per-call options (`WithResponses*`,
    `WithCustomHeaders`, `WithExtraFields`, `WithHeadPreviousResponseID`),
    server tools web search, file search, code interpreter and shell, MCP
    tools,
    `previous_response_id` (`headPreviousResponseId`, or automatically with
    `OpenAIResponsesConfig.enableAutoCache`), prompt cache, reasoning,
    the server-tool payload types, `OpenAIResponsesException`, openai-go's
    retries) and `ClaudeAgenticModel` (port of eino-ext `agenticclaude`,
    Anthropic Messages API only: `ClaudeAgenticConfig`,
    `ClaudeAgenticOptions`, the server tools web search, web fetch, code
    execution and tool search (BM25, regex), thinking, cache control on
    blocks and tools, the server-tool payload types). Both fire the
    agentic model callbacks, cancel their requests with the run, and
    register their payload types for checkpoints
    (`OpenAIResponsesModel.ensureTypesRegistered`,
    `ensureClaudeAgenticTypesRegistered`).
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

- **HTTP providers: a header value the platform client refuses names the
  header, not the value.** `dart:io` rejects control characters in header
  values (an API key read from a file with its trailing newline, for
  example) with a `FormatException` that quotes the value, and the
  providers put the text of the error into their own exceptions, so the key
  reached logs. The shared request helpers now fail with a
  `ThreepioFormatException('invalid header field value for "<name>"')`
  (Go's `net/http` wording) without the value; every provider that sends
  through them (OpenAI, OpenRouter, OpenAI-compatible, Claude, Gemini,
  Ollama, the embedders, Qdrant, LangSmith, and the OpenAI Responses and
  Claude agentic models) wraps that instead; the Claude agentic model also
  checks its headers before sending, with the same wording. Clients that
  send through code of their own (the SearXNG and DuckDuckGo tools, for
  example) are not covered.
- **HTTP providers: a streamed response that arrives after the header
  timeout is drained**, so that its connection is let go (only a cancelled
  wait did that before).
- **An interrupted `ToolsNode` keeps registered types in the `extra` of
  its tool calls.** Its checkpoint state (`ToolsInterruptAndRerunExtra` and
  the rerun state) writes an `extra` of the input message or of a tool
  call that `jsonEncode` cannot write (one that holds a registered type
  without a `toJson()`) through `TypeRegistry`, marked by a `$typed_extra`
  key next to it, as Go's checkpoint serializer writes the registered
  types in `ToolCall.Extra`. The agentic tools node hands the block extras
  of a model to its inner `ToolsNode` there (the OpenAI Responses model
  keeps its item ids and statuses as registered types), so an agentic run
  whose tool interrupted could not be checkpointed before. Every other
  `extra` (plain JSON, also with a `$type` key, and objects with a
  `toJson()`) is written byte for byte as before, and a checkpoint written
  before is read as it was.
- **`ComponentType` has four more values** (`agenticModel`,
  `agenticChatTemplate`, `agenticToolsNode`, `agenticAgent`). A `switch`
  over `ComponentType` without a default case must add them.
- **MCP tools keep their input schema exactly as the server sends it**
  (`ToolInfo.fromJsonSchemaMap`): the providers now receive every keyword
  (`anyOf`, `$ref`, `$defs`, `format`, `default`, …), which used to be
  dropped by the mapping onto `JSONSchema`; `function.parameters` still
  holds that mapping. The client's protocol negotiation is unchanged in
  behaviour (it asks for `2025-11-25` and speaks `2025-06-18`, `2025-03-26`
  or `2024-11-05` when the server answers with one of them) and is now
  documented and tested against each.
- **`FunctionTool`, `StreamFunctionTool`**: a result that is not a `String`
  is written as Go's `sonic.MarshalString` writes it, so backspace and form
  feed are `\u0008` and `\u000c` (they were `\b` and `\f`); everything else
  is unchanged. `FunctionTool`, `StreamFunctionTool`, `EnhancedFunctionTool`,
  `EnhancedStreamFunctionTool`, `GraphTool.invokable`/`streamable` and
  `AgentTool` keep a
  `ParamsOneOf.jsonSchemaMap` document in their tool info (built with the new
  `ToolInfo.fromParamsOneOf`); the other `ParamsOneOf` forms give the same
  tool info as before.
- **`LangfuseHandler`**'s documentation says it has not been verified
  against a live Langfuse project; the `integration`-tagged
  `test/integration/langfuse_integration_test.dart` checks an export end to
  end when run with `THREEPIO_INTEGRATION=1` and the project's keys.
- New dependencies: `archive` (`^4.0.0`), `html` (`^0.15.5`) and `xml`
  (`^6.5.0`), for the HTML parser, the HTML splitter and web tools, and the
  DOCX and XLSX parsers. All three were already in `sourcery_main`'s
  dependency graph.
- **`OpenAIChatModel`** runs on the shared OpenAI-compatible client. Visible
  differences: a stream holds back messages without content, tool calls or
  reasoning and merges them into the next one (as Eino does; the first frame
  of parallel tool calls can be empty), and emits the final usage-only chunk
  (the request asks for it with `stream_options.include_usage`); an `error`
  object inside a stream now fails it (malformed lines are still skipped);
  zero `max_tokens`/`top_p` are no longer sent (Go's `omitempty`); the
  request is cancelled by the call's cancel token; `OpenAIException`
  implements `ChatModelException` (408/429/5xx, timeouts and transport
  failures are retryable, 404 or an unknown model is "model unavailable") and
  has the new optional `errorCode`, `isRetryable`, `isModelUnavailable` and
  `cause` constructor parameters.
- **`OpenRouterChatModel`** runs on the same client with its own request
  builder, parser, chunking and error texts, so its requests and streams are
  unchanged. Small runtime differences: a cancel while the response headers
  are awaited throws `CancelledException` from `stream()` at once (it used to
  arrive as a stream error once the headers came); an exception thrown while
  a stream chunk is parsed ends the stream with a non-retryable
  `OpenRouterException('Invalid stream chunk: …')` (it escaped as an uncaught
  error and the stream went on), and a chunk that is not a JSON object is
  skipped; a stream whose reader was closed stops reading the response.
  `OpenRouterException` has an optional `cause`.
- **`OpenAIConverters.messageToOpenAI`**: a base64 image becomes a data URL
  (it was sent without a URL), base64 audio becomes an `input_audio` part
  and a video a `video_url` part (both threw `UnimplementedError`); an image
  part with neither a URL nor base64 data is an `ArgumentError` (it was sent
  with `url: null`); a tool call without a type (assembled from stream
  fragments) is sent as a `function` call.
- **`OpenAIEmbedder`** sends `encoding_format` (`float` by default, as Eino),
  fires the new callback chain, and no longer copies the `callbackManager`
  and `context` entries that `withCallbacks` keeps in `extra` into the
  request body (which made the request fail).
- **`GeminiChatModel`** (Eino-faithful or fixes): bound tools imply
  `ToolChoice.allowed`, so `toolConfig` `AUTO` is sent with function
  declarations and callbacks report the choice; `reasoningContent` and
  assistant media are sent back; any tool-role message becomes a
  `functionResponse` named after `toolName`, else `toolCallId`; chunks with
  only a finish reason or usage are emitted; a malformed stream chunk fails
  the stream (it was skipped); errors on non-JSON bodies keep the HTTP
  status; timeouts and transport failures are retryable; an explicit
  `mimeType` on URL media wins over the guess; a `models/` prefix on the model
  name is not doubled; empty input is an `ArgumentError`; base64 data and file
  ids on input parts are used; no `x-goog-api-key` header is sent when the
  key is empty. `GeminiException` (moved to `gemini_errors.dart`, still
  exported from `gemini_chat_model.dart`) implements `ChatModelException`.
- **`ModelCallCallbacks`** (internal) can add a provider's `extra` to the
  callback output.

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
- A missing agents.md file fails the run when the backend reports it with a
  plain error, as `InMemoryBackend` does (as in Eino, whose in-memory
  backend does not wrap `os.ErrNotExist`); only a `FileNotFoundException`
  is skipped with a warning. Earlier builds of this branch skipped it.
- `ToolSearchMiddleware` in model-native mode without static tools: after
  the first call (which is told about no tools) the agent is told about
  every tool again, as Eino's engine fills a nil tool list; earlier builds of
  this branch kept the list empty. (Go's nil list has no public counterpart
  in `ChatModelAgentState.toolInfos`; only the built-in middleware can ask
  for the refill.)
- `ToolsNode.create` takes an optional `ctx` (Go's `NewToolNode(ctx, …)`),
  and a tools node asks a tool whose description depends on the run (the
  skill tool, the deep agent's `task` tool) with the context it is created
  or called with.
- **`VectorRetriever` fires the new callback chain** (as eino-ext's
  retrievers do): `retrieve` and `retrieveWithScores` report a
  `RetrieverCallbackInput` (query, `topK`, score threshold) and a
  `RetrieverCallbackOutput` (the documents), or the error, to the handlers
  of `options.runContext` and the global handlers, and call the embedder in
  a context that introduces it as an embedder (`<type>Embedding`). It is a
  `TypedComponent` (`Vector`, shown as `VectorRetriever`) and a
  `CallbackAwareComponent`, so a graph no longer fires node callbacks around
  it: handlers of a graph see the typed payloads under the node's name
  instead of the plain query and documents. A legacy `callbackManager` in
  the options is still called, around the new chain. Without any handler
  nothing changes (the embedder gets the run context of the call as
  before). Inside a flow retriever (`concurrentRetrieve`) it is reported
  twice, once by the flow (`VectorRetriever`) and once by itself (empty
  name), as a callback-aware retriever is in Eino.
- The built-in replanner of the plan-execute agent ends the loop with
  `PlanExecute.breakLoopAction`; the loop behaves as before.

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
  where it was a `CallbackInput` or `CallbackOutput`. The payload is what
  the component reports to the new API, which is not always what
  `input.data` was: the components ported from Eino report typed payloads
  (a chat model reports a `ModelCallbackInput`, not the list of messages;
  `ModelCallbackInput.from` reads either form). Give a run its handlers with
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
  - *Missing files*: Go's `os.ErrNotExist` is `FileNotFoundException`: the
    agents.md middleware skips (with a warning) a file whose read throws it
    and fails on any other error. `InMemoryBackend`, like eino's in-memory
    backend, reports a missing file with a plain `ThreepioException`
    (`file not found: <path>`), so a missing agents.md fails the run with
    that backend, as it does in Go.
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
  - *Summarization events* register `SummarizationAction` with
    `TypeRegistry` when a `SummarizationMiddleware` is created (Go: at
    package initialisation).
- **Differences from Eino in the prebuilt agents.**
  - *Not ported*, because Eino marks them as not recommended: the supervisor
    (`prebuilt/supervisor`), the workflow agents `planexecute.New` is built
    from (`NewSequentialAgent`, `NewLoopAgent`, `NewBreakLoopAction`,
    `WorkflowInterruptInfo`; the plan-execute agent uses two private runners
    instead, exported by no library), the deep agent's `OutputKey` and the
    executor's (`OutputKey: ExecutedStepSessionKey` is a private middleware
    that writes the same session value), and the deprecated `Middlewares`.
    The agentic variants (`NewTyped[*schema.AgenticMessage]`) belong to the
    agentic port; gob checkpoint compatibility is not ported.
  - *The end of the loop*: the replanner ends the loop with
    `PlanExecute.breakLoopAction` (Eino: `NewBreakLoopAction`, which a custom
    replanner calls too); the loop does not pass the action on (Eino marks
    its `BreakLoopAction` done and forwards the event), so the caller sees
    the replanner's answer as the last event. The action is public only as
    that static method of `PlanExecute`; the loop runner it is meant for
    stays internal.
  - *Sub-agent input*: a sub-agent of the plan-execute agent gets the run's
    input; Eino gives it that input plus the earlier agents' messages
    rewritten as "For context: …" (the history of agent transfer). The
    built-in planner, executor and replanner read session values instead and
    see no difference; a custom part that reads its input does.
  - *Interrupts*: the plan-execute agent's interrupt reports no `data` (Eino
    fills the deprecated field with a `WorkflowInterruptInfo`); the interrupt
    contexts are the same. After a cancel of the whole run (`withCancel`), a
    resume continues the interrupted part (the executor) from its own
    checkpoint and in the same round. This is a deliberate difference: Eino
    runs that part again from the start, because its cancel checkpoint drops
    the `WorkflowInterruptInfo` the workflow agents resume from (behind an
    `AgentTool`, Eino resumes it too), which reads as an accident of its
    wiring; resuming also keeps the executor's tool calls from being made
    twice. The API docs of `PlanExecute` say so as well.
  - *Executor*: the private middleware that writes `ExecutedStep` adds an
    `AfterAgent` node to the executor's graph, which callback handlers see
    (Eino's executor has none).
  - *Plans*: `PlanDecoder` builds a plan from the JSON text (Eino fills an
    empty plan with `UnmarshalJSON`); `Plan.toJson` returns a JSON object
    (Go's `MarshalJSON` may write any JSON value); the default plan's and the
    `task` tool's field names must match exactly (Go also accepts other
    letter cases). Custom plans need a `TypeRegistry` registration to survive
    a checkpoint, as in Eino.
  - *Deep agent*: like Eino's, it does not summarize by itself (add a
    `SummarizationMiddleware`); its general-purpose sub-agent gets the
    failover configuration but not the retry configuration, as in Eino. The
    `task` tool's description is built with the run's context.
  - *Construction*: the factories are asynchronous and throw
    `ArgumentError` where Go's return an error or panic on a missing model
    (`PlannerConfig` with neither model, a shell without a backend).
- **Differences from Eino in the flow port.**
  - *Entry points*: Eino's `NewRetriever` constructors return the
    `retriever.Retriever` interface; here they are static `fromConfig`
    methods of the existing `MultiQueryRetriever`, `ParentRetriever` and
    `RouterRetriever` classes that return a `Retriever`, not an instance of
    the class (the classes' required settings, such as a chat model, a
    parent store or a routing strategy, have no counterpart in Eino's
    configurations). `MultiQueryRetriever.fromConfig` is asynchronous,
    because compiling its rewrite chain is. Missing required parts are
    compile-time errors (required parameters); "neither a rewrite model nor
    a handler" and "no retrievers" are `ArgumentError`s; the checks the
    flows make while they run fail with `ThreepioException`s that carry
    Eino's texts (`no retriever has been selected`, `router output[…] has
    not registered`, `no documents`, `doc transformer returned no
    documents`, `generated sub IDs' num is unexpected`, `transform docs
    fail: …`). What a retriever, router, fusion, rewrite, getter, id
    generator or indexer of yours throws is rethrown as it is.
  - *Options*: the multi-query retriever passes the options of `retrieve`
    on to every retrieval (Eino passes none); the router and parent
    retrievers pass them on as Eino does.
  - *Router*: without a router every retriever is asked, as Eino's
    documentation and code intend; Eino v0.9.22 computes that router but
    stores the missing one, so a router retriever without a router fails at
    its first call there. The default router keeps the order of the map it
    was given (Go: map order).
  - *Order*: documents with equal reciprocal-rank scores keep the order in
    which their ids first appeared, and the fusion input of the router
    keeps the router's order (Go: map iteration, random).
  - *Ids*: a `Document` without an id counts as one with the empty id
    (Eino's ids are strings, empty by default): the default fusions treat
    all such documents as one, and `ParentIndexer` gives them the parent id
    `''`.
  - *`maxQueries`*: zero or less means 5 (Eino: zero means 5, a negative
    value panics).
  - *Functions* in the configurations take the `RunContext` first and may
    return a value or a `Future` (`FutureOr`).
  - *`ParentIndexer`* lets an interrupt from the transformer through
    unwrapped (Eino wraps every transformer error, `%w`, which `errors.As`
    sees through). It stores copies of the transformer's documents with the
    new ids and metadata and leaves the documents themselves alone; Eino
    changes them in place, so with a transformer that hands its input back,
    the caller's documents get the new ids there.
  - *`concurrentRetrieve`* records whatever a retriever throws as the
    task's error, unwrapped; Eino also recovers a panic and records it as
    `retrieve panic, query: …` (Dart has no panics to recover).
  - *Not ported*: `flow/agent/react` and `flow/agent/multiagent/host`, which
    Eino's guides tell users to replace with the ADK (`ChatModelAgent`,
    `AgentTool`); the legacy `Agent` of the umbrella library stays as it is.
- **Differences from Eino in the ext providers (wave 1).**
  - *No SDKs*: every provider speaks the REST API with `package:http`. The
    retries the Go SDKs do by themselves are left to `RetryingChatModel`.
    Bedrock, Vertex, Ollama request signing and credentials from environment
    variables are not ported.
  - *Errors*: contradictory settings (a forced tool choice without tools, an
    unknown allowed tool, an audio modality without audio settings, Qwen's
    and DeepSeek's unsupported tool choices) are `ArgumentError`s with Go's
    messages; bad input data is a `ThreepioFormatException`; HTTP and stream
    failures are the provider's `ChatModelException`. Transport and HTTP
    failures of a stream are thrown by `stream()` itself, so that the retry
    and failover decorators can act (Go reports some through the stream).
    `CancelledException` passes through unwrapped.
  - *Modifiers*: the payload and response modifiers of
    `OpenAIRequestOptions` take and return decoded JSON maps, synchronously
    (Go: raw bytes).
  - *OpenAI-compatible messages* are converted leniently: user parts on any
    role, unsupported assistant output parts skipped (Go fails), and the
    audio MIME-type table without Go's swapped `audio/mpeg`/`audio/x-wav`
    entries. The reasoning is in `Message.reasoningContent` only (Go also
    copies it to `extra['reasoning-content']`); the response id is set once
    per stream (Go on every chunk, with a concat function). Tools keep their
    serialization (Go sorts `required` arrays). `withTools` does not set
    `ToolChoice.allowed` on the OpenAI-compatible models (Go does; the wire
    is the same, only the callback input differs). A generated audio's id is
    on the first audio part of a stream only (Go repeats it on every part and
    deduplicates it in a concat function; threepio's concat joins strings). A
    reader closed early is noticed when the next line arrives. OpenRouter
    does not parse log probabilities on its image response paths.
  - *OpenRouter* keeps threepio's request builder (Go's `allowed_tools` tool
    choice only with `allowedToolNames`), streams its chunks without merging
    empty ones, keeps `reasoning_details` under `extra['reasoning_details']`,
    and throws `OpenRouterException` for an in-stream error instead of Go's
    `GetStreamTerminatedError`. An assistant message's output parts are sent
    as content parts only when one of them is a cache breakpoint.
  - *Claude*: `model` and `maxTokens` are required; `timeout` (10 minutes)
    and `idleTimeout` (90 s, `null` for none) have defaults; a model is
    unavailable only on HTTP 404 or `not_found_error`;
    `additionalRequestFields` follows sjson's path rules (a scalar met
    mid-path is replaced); a last event without its blank line is still
    read (the SDK drops it); `disableAutoCacheControl` stands
    for Go's `WithAutoCacheControl(nil)`; a streamed server-side tool search
    is recorded when its block ends (Go records it with empty input and then
    treats its input fragments as an ordinary tool call); an event without an
    `event:` line is routed by its `type`; `ChatModelOptions.extra` is not
    used (use `additionalRequestFields`). Kept as Go: thinking is sent back
    only with text and signature, `redacted_thinking` blocks are dropped,
    `web_search` results throw.
  - *Ollama*: the chat model defaults to `http://localhost:11434`;
    `maxTokens` becomes `options.num_predict` (Go ignores it); the config's
    sampling settings are the defaults of every call; zero values are sent;
    `tool_name` is sent for tool results; `allowedToolNames` is an
    `ArgumentError` and the tool choice is ignored, as in Go; blank NDJSON
    lines are skipped; for `stream()` the `timeout` bounds the response
    headers only (`idleTimeout` bounds silence); the metrics are also in
    `Message.extra`, as nanosecond integers; the embedder also reports
    `prompt_eval_count` as token usage and sends the call's model (Go sends
    the configured one).
  - *Gemini* keeps threepio's wire choices that its tests pin (snake_case
    `inline_data`/`file_data`, text tool results as `{"result": …}`, system
    messages joined, lowercase finish reasons, the text in `Message.content`
    with its thought signature in `Message.extra`, images as data URLs);
    streamed text signatures are attached to the finish chunk (Go fails to
    concatenate two); `toolConfig` is only sent with function declarations;
    thought parts are concatenated (Go keeps the last); Vertex-only settings
    are `ArgumentError`s.
  - *Embedding cache*: `HashCacheKeyGenerator` hashes the key text (Go's
    `hasher.Sum(b)` appends the digest of empty input to the text instead) and
    takes the hash as a function; an expiration of zero or less means no
    limit; an inner embedder that returns fewer vectors than texts is an error
    (Go panics); `CachingEmbedder` is not callback-aware, as in Go.
  - *MCP*: one `McpToolkit` covers both Go packages (officialmcp's errors and
    policies; the older package's custom headers and `_meta`); its tools are
    also `EnhancedInvokableTool`s; a tool error (`isError`) throws
    `McpToolkitException` unless `errorAsError: false`, as officialmcp does;
    the client asks for protocol `2025-11-25` and accepts the three earlier
    revisions (`2025-06-18`, `2025-03-26`, `2024-11-05`) when the server
    answers with one of them, as the specification's lifecycle requires;
    input schemas are kept exactly as the server sends them
    (`ToolInfo.fromJsonSchemaMap`, since P12; before, they were mapped onto
    threepio's `JSONSchema` and lost the keywords it has no field for);
    policy output has a fixed key order;
    `McpPromptTemplate` uses the new multi-content fields.
  - *Local backend*: a missing file is a plain `ThreepioException` with Go's
    text (`file not found: <path>`; never `FileNotFoundException`, so the
    agents.md middleware fails on it as Go's does); `grepRaw` searches in
    Dart instead of running `rg`, sorted by path, without `.gitignore`
    support or `\p{…}` classes; paged PDF reads are not supported (no
    PDFium), whole PDFs and images are; a cancelled command ends with
    `CancelledException` (Go: `context canceled`, exit code -1); `read`
    with no limit reads 2000 lines, as Go; bytes that are not UTF-8 are read
    as U+FFFD.
- **Differences from Eino in the ext components (wave 2).**
  - *Tool schemas*: a tool info built from a JSON Schema document is sent as
    given; acl/openai's `sortArrayFields` (which sorts `required`) is not
    applied. Claude gets `{}` for a document without `properties` (Go:
    `null`).
  - *Documents*: `FileLoader` reports any failing `stat` with Go's "no such
    file or directory" text (`dart:io` does not tell the causes apart) and
    streams the file after checking it can be opened. The URL loader also
    hands the call's `LoaderOptions` to the request builder, reads the whole
    body before parsing (so a timeout and a cancellation cover it, and a
    broken body fails the load rather than the parser), creates and closes a
    client per load when none is given (Go: `http.DefaultClient`), and has a
    `timeout` standing in for `http.Client.Timeout` (zero or negative: none,
    as in Go); a cancellation or a timeout stops reading the body. The HTML
    parser decodes invalid UTF-8 as U+FFFD, evaluates selectors with
    `package:html` (cascadia's extensions such as `:contains` match nothing),
    lets `package:html` decode entities, and walks the page without
    recursion; a selector other than a plain tag name on a page nested too
    deeply for `package:html` throws a `ThreepioFormatException` (the legacy
    `HtmlParser`'s `selector` too). `PdfParser` has no text extraction of
    its own. `DocxParser` returns the sections in the fixed order headers,
    main text, tables, footers (Go walks a map), reads a file without
    `word/styles.xml` without styles (Go panics), and reports XML syntax
    errors with `package:xml`'s texts. `XlsxParser` applies the General
    number format only (no dates, percentages or custom formats; `t="d"`
    cells are not converted), stops a sheet after row 1,048,576, takes the
    first of two sheets whose names differ only in case (Go picks either),
    and checks no CRCs. A part with no XML element at all reads as Go
    reads it: missing for the XLSX parser (excelize ignores the `io.EOF`),
    an empty body or `open Docx document failed: EOF` for the DOCX parser. `IncludeComments` (deprecated upstream) is not
    ported.
  - *Transformers*: lengths default to UTF-8 bytes (Go's `len`); a chunk
    keeps its source document's id, metadata (copied), and `source`, not its
    `embedding`/`score` fields (the metadata entries Eino uses for them are
    copied, as in Go); `SplitIdGenerator` returns `null` for Go's `""`;
    configuration mistakes are `ArgumentError`s with Go's messages, and the
    semantic splitter throws where Go panics (too few or short vectors, a
    percentile outside the range); orders Go takes from a map are fixed. The
    HTML header splitter works on `package:html`'s tree, which differs from
    `x/net/html`'s in corners (`<main>`, `<dialog>`, `<search>` inside an
    open `<p>`, `<isindex>`, `<template>`). The score reorder sorts stably,
    ranks NaN lowest and also counts an `int` score.
  - *Qdrant*: REST instead of gRPC (queries need Qdrant 1.10 or later); the
    retriever applies a per-call score threshold (Go applies only the
    configured one, although it reports the per-call one to callbacks);
    its callback input reports the REST filter, or `null` (Go: the protobuf
    filter, or `"null"`); retrieved metadata is a plain JSON map; a document
    whose id is `null` gets a UUID (an empty id is sent as Go sends it, and
    Qdrant refuses it); payload
    values Go would panic on are `ThreepioFormatException`s; every request
    has a 60 s default timeout (`QdrantClient.defaultTimeout`).
  - *Web tools*: the answers to the model are Go's byte for byte (sonic's
    escapes included); argument decoding errors use `encoding/json`'s
    wording. Errors never contain an API key or a URL password (Go's
    `url.Error` quotes the Google key; passwords show as `***`, as Go's
    `stripPassword` writes them). As in Go, a zero timeout means no limit
    for the HTTP request and Google tools, and the Go default for Wikipedia
    (15 s, also when negative), DuckDuckGo and SearXNG (30 s; negative: no
    limit); an explicit timeout also applies to an injected client. Redirects are followed
    by hand with Go's rules (method changes, credential stripping,
    `Referer`), checking the cancel token before each hop. The HTTP tools
    send a Dart `User-Agent`. Google: a hit without `pagemap` gets an empty
    description (Go fails the whole call), a response without `queries`, a
    `null` hit or a 204 is tolerated (Go panics), trailing data after the
    JSON is refused, `lang` is sent as `gl` (as Go does), no
    `x-goog-api-client` header. Wikipedia counts `DocMaxChars` in UTF-8
    bytes (Go's `len`) and, of several pages in an answer, takes the first
    in answer order (Go walks a map).
    DuckDuckGo picks from 8 desktop user agents (Go: uarand's list), its
    page delay (`pageDelay`, Go: a fixed 3 s) is configurable and
    cancellable, and any region code can be given
    (`DuckDuckGoRegion('es-es')`). SearXNG: its retry delay (`retryDelay`,
    Go: a fixed 1 s) is configurable and cancellable, a negative
    `maxRetries` is an `ArgumentError` (Go crashes on the first search), a
    `null` hit is written as an empty object, `searchResults` returns an
    empty list where the tool fails with "no search results found"; the
    unused proxy setting is not ported.
  - *Command line and sequential thinking*: the three tools' schemas are
    Go's exactly; JSON keys of the arguments match ignoring case, as Go's
    decoders do. The editor's
    ranged `view` numbers lines from the start of the range (Go's shadowed
    `initLine` numbers them from 1, against its own description), and an
    empty `old_str` in an empty file writes `new_str` (Go panics); Go's
    other quirks are kept (`create` is recorded in the undo history, tabs
    are expanded in the whole file, the executor ignores stderr and the exit
    code and leaves its `.py` file behind). `LocalOperator` runs commands
    without a shell, with a 30 s default timeout, reports `128 + signal` for
    a killed process on POSIX and the unsigned exit code on Windows, and is
    killed by a cancellation. The Docker sandbox is not ported. Sequential
    thinking lists branches in first-seen order.
  - *LangSmith*: requests are queued and sent in the background, in order,
    a child's creation after its parent's (Go sends them synchronously in
    the hook); a failed request is logged and counted, not retried; the
    queue holds `LangSmithConfig.maxQueueSize` requests (2048 by default;
    more are dropped, with one warning); the
    update of a run whose creation was dropped is dropped too; after
    `shutdown()` begins, no new run is created but the runs already created
    are still ended. Dotted orders carry the microseconds of the start time,
    as LangSmith's own clients write them (Go's layout writes a literal
    `000000`, so runs that start within the same second sort at random).
    Payloads are written with threepio's JSON form (camelCase message
    fields); a successful creation's body is not read; a streamed output
    keeps the extra values its streamed input added (Go drops them).
    Caller metadata is never mutated, and a payload that cannot be encoded
    still creates its run (Go fails or panics in those cases).
- **Differences from Eino in the agentic path (beta).**
  - *Types*: hand-written immutable classes, not freezed: Go's JSON nests a
    block's payload under its type key, which freezed unions do not write.
    A `ContentBlock` always has a payload (Go's struct can carry a type with
    a nil payload); a block without one reads back as the zero-valued
    payload. Go's string zero values are kept as defaults (`callId: ''`).
    The role of a message is required, so `concatAgenticMessages([])`
    throws `ArgumentError` (Go returns a message without a role); conflicts
    throw `MessageConcatException`. Values only the producer knows the type
    of (`extension`, server tool `arguments`/`content`, `extra`) are written
    to JSON through `TypeRegistry` (registered types are tagged with their
    name and come back as themselves; anything else that is not plain JSON
    makes `toJson` throw). `extension` and server tool `arguments`/
    `content` are joined through `StreamConcat`, which merges two
    string-keyed maps where Go's `ConcatSliceValue` fails; `extra` maps are
    merged key by key, each key's values through `StreamConcat`.
    `ToolSearchResult` uses threepio's JSON form. The field mappings of an
    `AgenticMessage` (`getField`/`withField`) take the Dart field names and
    Go's as aliases.
  - *Tools node*: the classic `ToolsNode` fills the positions of the other
    calls in a stream chunk with empty messages, so the agentic node gives
    those positions as user messages without blocks (Go: `nil`), and a call
    whose pieces were all empty gets its result block in one final chunk.
    The joined result equals Go's except that a call whose only chunk was
    joined with others loses its `StreamingMeta`. A tool that streams
    nothing gives an empty result (Go fails; as the classic `ToolsNode`
    does).
  - *Callbacks*: `AgenticPromptCallbackHandler` receives the agentic prompt
    payloads (Go v0.9.22 types it with the classic ones, so its end hook
    always gets `nil`); `LangfuseHandler` records the input, output, model
    and usage of agentic models (Go reads them with the classic converters
    and records `null`).
  - *ADK*: not built — model retry (`ShouldRetry`) and failover for agentic
    models (the classic retry and failover types are bound to `Message`;
    building them needs a parallel copy or a generic rewrite of the classic
    engine), the turn loop over agentic agents, and `OutputKey`/transfer
    (not recommended upstream, see the ADK notes). `AgenticMessageVariant`
    has no role or tool name (Go leaves them empty for agentic messages);
    events are named when their agent name is empty (run paths are not
    ported); run-local values come from the nearest agent state of either
    kind; `AgenticAgentTool` has no `fullChatHistoryAsInput` (Go refuses it
    for agentic agents).
  - *OpenAI Responses*: no SDK; requests are JSON written with openai-go's
    field rules and the SSE stream is parsed as openai-go does. openai-go's
    retries are kept (2 by default; 408, 409, 429, 5xx and transport errors;
    `retry-after-ms`, `retry-after` in seconds, `x-should-retry`; a timed-out
    attempt is not retried, as in openai-go); an HTTP-date `retry-after` is
    not parsed. The timeout bounds the headers of a stream (Go: the whole
    stream) and an `idleTimeout` ends a stalled one.
    `OpenAIResponsesModel.invalidateMessageCaches` returns copies (Go edits
    the messages in place); the item ids and statuses in block `extra` are
    internal wrapper types registered for checkpoints. Extra fields are
    top-level keys (no dotted paths). Server-tool payload maps are read
    leniently. Streamed API errors are classified as retryable by their
    code or type. The newest wire names (`shell_call`, `tool_search_call`,
    `cache_write_tokens`, `defer_loading`) follow openai-go v3.44, whose
    source was not available to check.
  - *Claude agentic*: no SDK, no environment variables, no SDK retries;
    `requestTimeout` (10 minutes) bounds the headers of a stream, an
    `idleTimeout` (90 s) a stalled one. `tool_search_tool_result` blocks
    become `ServerToolResult`s when their tool search call came first (Go
    fails `generate` and drops them from a stream; a stream here still
    drops one whose call it has not seen); streamed server tool calls can
    be joined (Go registers no concat function for their arguments); an
    empty `input_json_delta` of a server tool call gives no chunk (Go fails
    the stream); streamed web search and fetch results keep their caller in
    `extra`. In `generate`, function tool-call arguments are decoded and
    re-encoded (number formatting can differ from the bytes the API sent).
    `anthropic-beta` values are joined in a fixed order. The server-tool
    definitions of the 2026 tool versions could not be checked
    against anthropic-sdk-go v1.56 (not available); they follow the Go
    code's use and the SDK's naming.
  - *Not ported*: the agentic Gemini model, eino-ext's agentic
    chat-completions models (`agenticopenai.NewChatModel`, DeepSeek, Qwen),
    the Ark agentic model (Ark's Responses API) and the Bedrock and Vertex
    variants of Claude.
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
    `GraphRunException` caused by a `CheckpointEncodeException` that names
    it, instead of leaving a
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
  - Node and task order is the order of insertion. (Interrupt ids are
    UUIDs, as in Eino.)
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
  eleven new values (seven for the compose and component kinds, four for the
  agentic path).
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
