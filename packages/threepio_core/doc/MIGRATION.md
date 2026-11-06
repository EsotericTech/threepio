# Migrating to 0.9

Release 0.9 ports Eino v0.9.22 (Go) and much of eino-ext to Dart. This guide
is for two kinds of reader:

* people with code written against threepio 0.1.x, before the port, and
* people who know Eino in Go.

Code written against 0.1.x keeps compiling, apart from the
[intentional breaks](#intentional-breaks) below, and the older APIs keep
working. [From the legacy API to the Eino-shaped API](#from-the-legacy-api-to-the-eino-shaped-api)
shows how to move to the new ones when you want to. The
[CHANGELOG](../CHANGELOG.md) lists every change in detail, including the
"Differences from Eino" lists for each area.

## Libraries

The package has one umbrella library and ten focused ones. The focused
libraries follow Eino's packages.

| Library (`package:threepio_core/…`) | What it holds | Eino counterpart |
|---|---|---|
| `threepio_core.dart` | The umbrella: everything it exported in 0.1.x except the five checkpoint classes of `StateGraph` (below), plus `schema.dart`, `streaming.dart`, `components.dart`, `compose.dart`, `callbacks.dart` and `flow.dart`, and the model providers and embedders | — |
| `schema.dart` | Messages, tool definitions and results, documents, message templates, chunk concatenation, `TypeRegistry`, `RunContext`, `ThreepioException`, agentic messages (beta) | `schema` |
| `streaming.dart` | `StreamReader`, `StreamWriter`, `pipe`, copy, merge and concat of readers | `schema.StreamReader` |
| `components.dart` | Component contracts (`BaseChatModel`, `ToolCallingChatModel`, `Embedder`, `Retriever`, `Indexer`, `Loader`, `Parser`, `DocumentTransformer`, `ChatTemplate`), their options and callback payloads, `FunctionTool`, the eino-ext tools, parsers, transformers, MCP and Qdrant | `components`, eino-ext `components` |
| `compose.dart` | `Runnable`, `Lambda`, `Graph`, `Chain`, `Workflow`, `ToolsNode`, interrupt, checkpoint and resume (re-exports `components.dart`, `schema.dart`, `streaming.dart`) | `compose` |
| `callbacks.dart` | `ComponentCallbackHandler`, `CallbackHandlerBuilder`, `HandlerHelper`, `GlobalCallbacks`, the functions a component fires callbacks with, `LangfuseHandler`, LangSmith, the OTLP exporter, and the older callback API | `callbacks`, `utils/callbacks`, eino-ext `callbacks` |
| `flow.dart` | `ParentIndexer`, `concurrentRetrieve` and `RetrieveTask`; re-exports `components.dart`, whose retriever classes have the `fromConfig` methods Eino's flow retrievers became (`MultiQueryRetriever.fromConfig`, `ParentRetriever.fromConfig`, `RouterRetriever.fromConfig`) | `flow` |
| `adk.dart` | Agents: `Agent`, `ChatModelAgent`, `Runner`, `AgentTool`, interrupt and resume, cancel, `TurnLoop`, the middlewares, `PlanExecute`, `DeepAgent`, the filesystem backend, agentic agents (beta). Re-exports `compose.dart`. **Not exported by the umbrella** | `adk` |
| `io.dart` | What needs `dart:io`: `FileCheckpointStore`, `FileLoader`, `LocalFilesystemBackend`, `LocalShell`, `LocalOperator`, the stdio MCP transport, the file embedding cache | — |
| `legacy_graph.dart` | `StateGraph` and everything that belongs to it, including the five checkpoint classes the umbrella hides, and `LegacyRunnable` and its relatives | — |
| `legacy_chains.dart` | The LangChain-style chains (`BaseChain`, `LLMChain`, `SequentialChain`, `ParallelChain`, `TransformChain`, `RouterChain`, `RetrievalQAChain`), reachable only through `src/` imports before 0.9 | — |

The umbrella leaves out two groups of names on purpose:

* the functions a component fires its callbacks with (`onStart`, `onEnd`,
  `onError`, `onStartWithStreamInput`, `onEndWithStreamOutput`,
  `onEndWithCopies`): see [Callbacks](#callbacks);
* the five checkpoint classes of `StateGraph`, whose names now belong to
  compose: see [break 3](#3-the-checkpoint-classes-of-stategraph-come-from-legacy_graphdart).

**`adk.dart` is not in the umbrella in 0.9.** Its `Agent`, `AgentEvent`,
`AgentAction`, `Runner`, `ChatModelAgent`, `ChatModelAgentConfig`,
`ChatModelAgentState` and `AgentTool` have the same names as older types the
umbrella exports (the Kortney runtime and the older agents). Code that needs
both imports `adk.dart` with a prefix:

```dart
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// Builds both agents called `ChatModelAgent`.
void bothAgents(ToolCallingChatModel model) {
  // The umbrella's ChatModelAgent: the Kortney runtime.
  final kortney = ChatModelAgent(
    ChatModelAgentConfig(name: 'assistant', model: model),
  );

  // The Eino-shaped ChatModelAgent of adk.dart (Go `adk.NewChatModelAgent`).
  final agent = adk.ChatModelAgent(
    adk.ChatModelAgentConfig(
      name: 'assistant',
      description: 'Answers questions',
      model: model,
    ),
  );

  print('${kortney.name} and ${agent.name}');
}
```

Code that uses only the Eino-shaped API can import `adk.dart` (or
`compose.dart`) without a prefix, plus `callbacks.dart` for
`RunContext.withHandlers`, `GlobalCallbacks` and the tracing handlers. The
providers (`OpenAIChatModel`, `ClaudeChatModel`, …) are only in the umbrella;
for those, import the umbrella with `show`.

## Eino names next to older threepio names

Where an Eino name was already taken by an older threepio export, 0.9 gives
the Eino-shaped type these names:

| Eino (Go) | Dart name in 0.9 | Library | Older threepio type it sits next to |
|---|---|---|---|
| `adk.Agent` | `Agent` | `adk.dart` | `Agent` and `AgentConfig`: the older ReAct loop (umbrella) |
| `adk.AgentEvent`, `adk.AgentAction` | `AgentEvent`, `AgentAction` | `adk.dart` | the sealed `AgentEvent` and `AgentAction` of the Kortney runtime (umbrella) |
| `adk.Runner`, `adk.ChatModelAgent`, `adk.ChatModelAgentConfig`, `adk.ChatModelAgentState` | the same four names | `adk.dart` | the same four names: the Kortney runtime (umbrella) |
| `adk.NewAgentTool` | `AgentTool` | `adk.dart` | `AgentTool`, which wraps an older `BaseAgent` (umbrella) |
| `adk.InterruptInfo` | `AgentInterruptInfo` | `adk.dart` | — |
| `compose.InterruptInfo` | `GraphInterruptInfo` | `compose.dart` | — |
| `adk.CancelError` | `AgentRunCancelledException` | `adk.dart` | `AgentCancelledException` of the older agents (umbrella) |
| `planexecute.New`, `NewPlanner`, `NewExecutor`, `NewReplanner` | `PlanExecute.create`, `PlanExecute.planner`, `PlanExecute.executor`, `PlanExecute.replanner` | `adk.dart` | `PlanExecuteAgent` (umbrella) |
| `planexecute.Config`, `PlannerConfig`, `ExecutorConfig`, `ReplannerConfig`, `Plan` | `PlanExecuteLoopConfig`, `PlannerConfig`, `ExecutorConfig`, `ReplannerConfig`, `Plan` | `adk.dart` | `PlanExecuteConfig`, `PlanStep`, `ExecutionPlan` (umbrella) |
| `compose.ToolInput`, `ToolOutput`, `StreamToolOutput`, `EnhancedInvokableToolOutput`, `EnhancedStreamableToolOutput` | `ToolCallInput`, `ToolCallOutput`, `StreamToolCallOutput`, `EnhancedToolCallOutput`, `EnhancedStreamToolCallOutput` | `compose.dart`, umbrella | `ToolOutput`, the result of a Kortney tool (umbrella) |
| `compose.CheckPointStore`, `compose.Serializer` and the stores | `CheckpointStore`, `CheckpointSerializer`, `JsonCheckpointSerializer`, `InMemoryCheckpointStore` (`compose.dart`, umbrella); `FileCheckpointStore` (`io.dart` only) | see left | `CheckpointStore<S>`, `CheckpointSerializer<S>`, `JsonCheckpointSerializer<S>`, `InMemoryCheckpointStore<S>`, `FileCheckpointStore<S>` of `StateGraph` (now `legacy_graph.dart` only) |
| `compose.START`, `compose.END` | `Graph.start`, `Graph.end` (`'start'`, `'end'`) | `compose.dart` | the constants `START`, `END` (`'__start__'`, `'__end__'`) of `StateGraph` |
| `compose.Runnable`, the `Lambda` constructors | `Runnable`, `Lambda` | `compose.dart`, umbrella | the runnable over Dart streams that `StateGraph.toRunnable()` returns, renamed `LegacyRunnable`, `LegacyLambda`, `LegacyRunnableSequence`, `LegacyRunnableOptions`, `LegacyRunnableException` (`legacy_graph.dart`) |
| `callbacks.Handler`, `callbacks.HandlerBuilder` | `ComponentCallbackHandler`, `CallbackHandlerBuilder` | `callbacks.dart`, umbrella | `CallbackHandler`, `BaseCallbackHandler` (deprecated) |
| `callbacks.RunInfo`, `components.Component` | `RunInfo`, `ComponentType` (more values) | `callbacks.dart`, `compose.dart` (`ComponentType` also `components.dart`), umbrella | the same types |
| `document.Transformer` | `DocumentTransformer` (`transform` gains `options`) | `components.dart`, umbrella | the same type |
| `parser.TextParser` | `TextParser` | `components.dart`, umbrella | `PlainTextParser`, a `DocumentParser` |
| eino-ext `parser/html` (`html.NewParser`) | `HtmlParser.fromConfig(HtmlParserConfig)`, which returns an `HtmlContentParser` | `components.dart`, umbrella | `HtmlParser`, a `DocumentParser`; as a `Parser`: `HtmlParser().asParser()` |
| `schema.TokenUsage` | `TokenUsage` | `schema.dart` | a duplicate in the agent events, deleted |
| `context.Context` | `RunContext` | `schema.dart` | the Kortney runtime's `RunContext`, renamed `AgentRunScope` |
| `schema.MCPToolCall`, `MCPToolResult`, `MCPToolCallError`, `MCPListToolsResult`, `MCPListToolsItem`, `MCPToolApprovalRequest`, `MCPToolApprovalResponse` | `AgenticMcpToolCall`, `AgenticMcpToolResult`, `AgenticMcpToolCallError`, `AgenticMcpListToolsResult`, `AgenticMcpListToolsItem`, `AgenticMcpToolApprovalRequest`, `AgenticMcpToolApprovalResponse` | `schema.dart` | the `Mcp…` types of the MCP client, also new in 0.9 (`McpListToolsResult`, …) |
| `schema/openai`, `schema/claude`, `schema/gemini` (`ReasoningEffort`, `ResponseMetaExtension`, …) | prefixed with the package: `OpenAIReasoningEffort`, `OpenAIResponseMetaExtension`, `ClaudeResponseMetaExtension`, `GeminiGroundingMetadata`, … | `schema.dart` | OpenRouter's `ReasoningEffort` and `ReasoningSummary` |

The [README's mapping table](../README.md#mapping-from-eino-go) maps the other
Go packages and symbols to their Dart names.

## Intentional breaks

Breaks 1–4 and the [smaller source changes](#smaller-source-changes) can stop
0.1.x code from compiling; break 5 changes behaviour and raises the SDK
floor; break 6 adds deprecation infos. Each snippet is the 0.9 form; a
`// Before 0.9:` comment shows what it replaces.

### 1. `RunContext` of the Kortney runtime is `AgentRunScope`

The class `ChatModelAgent.run` (umbrella) takes as `context:` was called
`RunContext`. That name now belongs to the core context every Eino-shaped API
takes first. Code that goes through `Runner` is not affected.

```dart
final reader = await agent.run(
  messages,
  // Before 0.9: context: RunContext(sessionId: 'chat-1'),
  context: AgentRunScope(sessionId: 'chat-1'),
);
await for (final event in reader.asStream()) {
  print(event.eventType);
}
```

### 2. `DocumentTransformer.transform` takes `options`

`transform` gained an optional named parameter, `{TransformerOptions? options}`,
which carries the run context and implementation-specific options (Go's
`document.TransformerOption`). A class that extends or implements
`DocumentTransformer` has to declare it, also when it ignores it. The class
moved to `components/document/transformer.dart`; the umbrella and
`ingestion_pipeline.dart` still export it.

```dart
import 'package:threepio_core/threepio_core.dart';

/// Drops documents shorter than [minLength].
class ShortDocumentFilter extends DocumentTransformer {
  const ShortDocumentFilter(this.minLength);

  final int minLength;

  // Before 0.9: Future<List<Document>> transform(List<Document> documents)
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async =>
      [
        for (final document in documents)
          if (document.content.length >= minLength) document,
      ];
}
```

### 3. The checkpoint classes of `StateGraph` come from `legacy_graph.dart`

The umbrella no longer exports `CheckpointStore<S>`, `CheckpointSerializer<S>`,
`JsonCheckpointSerializer<S>`, `InMemoryCheckpointStore<S>` and
`FileCheckpointStore<S>` of the state graph: `CheckpointStore`,
`CheckpointSerializer`, `JsonCheckpointSerializer` and `InMemoryCheckpointStore`
now name the compose types there. Import `legacy_graph.dart`, with a prefix
when the umbrella is imported too. Everything else of the state graph
(`StateGraph`, `GraphState`, `CheckpointConfig`, `START`, `END`, the
exceptions) is still in the umbrella.

```dart
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

class CounterState implements GraphState {
  const CounterState([this.count = 0]);

  final int count;

  @override
  CounterState copyWith({int? count}) => CounterState(count ?? this.count);
}

Future<void> main() async {
  // Before 0.9: InMemoryCheckpointStore<CounterState>(), from the umbrella.
  final store = legacy.InMemoryCheckpointStore<CounterState>();
  final graph = StateGraph<CounterState>(
    checkpointStore: store,
    checkpointConfig: const CheckpointConfig(checkpointEveryNode: true),
  )
    ..addNode('count', (state) async => state.copyWith(count: state.count + 1))
    ..addEdge('count', END)
    ..setEntryPoint('count');

  final result = await graph.invoke(const CounterState(), threadId: 'thread-1');
  final saved = await store.list(threadId: 'thread-1');
  print('count ${result.state.count}, ${saved.length} checkpoints');
}
```

### 4. The runnable of `StateGraph.toRunnable()` is `LegacyRunnable`

The runnable over Dart `Stream`s that `StateGraph.toRunnable()` returns and the
chains implement was renamed to free the names for Eino's `Runnable` and
`Lambda`: `Runnable` → `LegacyRunnable`, `Lambda` → `LegacyLambda`,
`RunnableSequence` → `LegacyRunnableSequence`, `RunnableOptions` →
`LegacyRunnableOptions`, `RunnableException` → `LegacyRunnableException`. They
were never exported; `legacy_graph.dart` exports them now. `toRunnable()` and
`asNode()` work as before.

```dart
import 'package:threepio_core/legacy_graph.dart';

Future<void> main() async {
  final graph = StateGraph<MapState>()
    ..addNode('greet', (state) async => state.set('greeting', 'hello'))
    ..addEdge('greet', END)
    ..setEntryPoint('greet');

  // Before 0.9 the types were Runnable and Lambda, imported from src/compose/.
  final runnable = graph.toRunnable().pipe(
        LegacyLambda<GraphResult<MapState>, String>(
          invoke: (result, options) async =>
              result.state.get<String>('greeting') ?? '',
        ),
      );
  print(await runnable.invoke(MapState()));
}
```

### 5. `ToolRegistry.register` takes effect at once; Dart 3.9 or later

`register` used to add the tool some time after it returned. Now the tool
counts at once (`count`, `getAllTools()`), and the asynchronous accessors
(`ready`, `findTool`, `getToolInfoList`) wait for every pending registration.
A lookup by name in the same synchronous block still cannot see the tool,
because its name comes from the asynchronous `info()`. A tool whose `info()`
throws is reported by `ready`, `findTool` and `getToolInfoList` instead of
surfacing as an unhandled asynchronous error. Code that waited with
`Future.delayed` keeps working.

```dart
final registry = ToolRegistry()..register(weatherTool);
print(registry.count); // 1, at once

// Before 0.9: await Future<void>.delayed(Duration.zero) and registry.getTool(…)
final tool = await registry.findTool('get_weather');
print(tool != null);
```

The package needs **Dart 3.9** or later (`environment: sdk: ^3.9.0`); its own
code generators already did.

### 6. Deprecations

Nothing was removed; these are annotations, and the analyzer now reports their
uses as `deprecated_member_use` infos:

* `CallbackHandler`, `BaseCallbackHandler` and `CallbackManager`, the older
  callback API. Nothing changes where they are used today (`StateGraph`, the
  providers, `OpenAIEmbedder`, `VectorRetriever`, `InMemoryVectorStore`, the
  chains). New handlers extend `ComponentCallbackHandler`
  ([how](#basecallbackhandler--componentcallbackhandler)); an existing one
  joins a run of the new kind through `LegacyCallbackHandlerAdapter`.
* `RetrieverOptions.callbackManager` and `RetrieverOptions.context`: put the
  handlers on `RetrieverOptions.runContext`.
* `MessagePartCommon.extra`: use `MessageInputPart.extra` or
  `MessageOutputPart.extra`, as Eino does. A file name goes into
  `MessageInputFile.name`.
* The client for Langfuse's ingestion API in `src/observability/langfuse/`
  (`LangfuseClient` and what belongs to it). It was never exported; Langfuse
  deprecated that API. `LangfuseHandler` replaces it
  ([how](#the-langfuse-ingestion-client--langfusehandler)).

The older agents (`LegacyChatModelAgent`, `WorkflowAgent`, `PlanExecuteAgent`,
`SupervisorAgent`, the umbrella's `AgentTool`) and the umbrella's `Agent` are
superseded by `adk.dart` but not annotated.

```dart
import 'package:threepio_core/threepio_core.dart';

/// A handler written for the older API keeps working …
class PrintingHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    print('start ${info.name}');
    return context;
  }
}

/// … and joins a run of the new kind through the adapter.
RunContext contextWithLegacyHandler() => RunContext.background()
    .withHandlers([LegacyCallbackHandlerAdapter(PrintingHandler())]);
```

### Smaller source changes

Each of these touches only code that switches over an enum, implements a
class of the package, or imports a library with a clashing name:

* A `switch` over `ComponentType` without a `default` needs cases for the
  eleven new values: `indexer`, `loader`, `documentTransformer`, `graph`,
  `workflow`, `lambda`, `toolsNode`, `agenticModel`, `agenticChatTemplate`,
  `agenticToolsNode`, `agenticAgent`.
* A `switch` over `ChatMessagePartType` without a `default` needs cases for
  `reasoning` and `toolSearchResult`.
* A class that `implements` `InvokableTool` or `StreamableTool` (instead of
  extending it) adds `invokableRun` / `streamableRun`. A subclass overrides
  either `run` / `streamRun`, which are no longer abstract, or the new
  `invokableRun` / `streamableRun`, which take a `RunContext`. `ToolExecutor`
  and the Kortney `ChatModelAgent` call the new pair; a tool that overrides
  only `run` behaves as before.
* `StreamReader` is an abstract class now: the `@internal`
  `StreamReader.fromController` is gone (`fromStream` and `fromIterable`
  stay). A class that `implements` it, such as a test double, adds
  `nextOrNull`, `convert` and `setAutomaticClose`.
* A class that `implements TextSplitter` (instead of extending it) adds
  `transform` and `withOptions`. A class that `implements` an exception type
  of the package, or `ChatModelException`, adds `Object? get cause` (and
  `String get message` where the type had none).
* A class that `implements` `OpenAIChatModel`, `OpenRouterChatModel` or
  `GeminiChatModel` (instead of extending it) adds `componentTypeName` and
  `isCallbacksEnabled`.
* The umbrella exports several hundred new names (`Graph`, `Chain`,
  `Lambda`, `Parallel`, `Workflow`, `Runnable`, `Parser`, `Loader`,
  `Indexer`, `RunContext`, …). Where one clashes with a name another import
  of the same file declares, the analyzer reports an ambiguous import: `hide`
  the name or import one of the libraries with a prefix.

## Other changes you can notice

Code that compiles unchanged behaves differently in these places. Only APIs
that existed in 0.1.x are listed; everything else in 0.9 is new (the
[CHANGELOG](../CHANGELOG.md)'s "Added" section), and the
[CHANGELOG](../CHANGELOG.md#changed) has the details of each change.

### Messages and streams

* **`MessageConcatenator.concat` joins chunks the way Eino does** and stays
  as lenient as it was: tool calls without an `index` come first, the others
  by ascending index; usage keeps the highest token counts and cost and the
  last non-empty finish reason; strings under one `extra` key are
  concatenated and maps merged (the last value used to win; lists are still
  appended); neighbouring text, reasoning and audio parts are joined; a list
  with a single message is processed too. For fragments of one tool call it
  keeps the first non-empty id, type and name, and it throws `ArgumentError`
  for different roles, names, tool call ids or tool names, as before.
* **Streams**:
  * `close()` completes a waiting `recv()` with `StreamClosedException`;
    `StreamReader.fromIterable` reports the end right after the last item;
    closing a reader made by `fromStream` cancels the subscription.
  * Readers from `copy`, `transform`, `mergeStreamReaders`,
    `mergeNamedStreamReaders` and `concatStreamReaders` buffer from the
    start, and a reader passed to one of them now belongs to the returned
    reader (close the returned reader to release it).
  * `asStream()` closes the reader when the stream ends or its listener
    cancels; `collectAll()` and `asStream()` skip the `SourceEOFException`
    markers of a named merge.
  * `mergeNamedStreamReaders` with a single source reports its end with a
    `SourceEOFException`, as with several sources (a loop that only expects
    `StreamEOFException` must handle it).
  * `concatStreamReaders` passes a source's error on and keeps reading that
    source.
  * `StreamWriter.send` returns `true` once the reader was closed, instead of
    throwing. `pipe()` rejects a negative capacity.

`concatMessages`, `concatMessageArray`, `concatMessageStream` and
`concatToolResults` are new: the strict port of Eino's `ConcatMessages`. Where
chunks do not fit together (different roles, names, tool call ids or tool
names, fragments of one tool call that disagree, `extra` values that cannot
be joined) they throw a `MessageConcatException`, a `ThreepioException`;
calling them without any chunk is an `ArgumentError`.

```dart
try {
  return concatMessages(chunks);
} on MessageConcatException catch (e) {
  print('the provider streamed chunks that do not fit together: $e');
  return MessageConcatenator.concat(chunks);
}
```

### Callbacks

* **The shipped handlers log instead of printing.** `LoggingHandler`,
  `MetricsHandler.printSummary`, `TracingHandler.printTrace`/`printTimeline`
  and `CallbackManager` (for a handler that throws) write to
  `package:logging` (loggers `threepio.callbacks.logging`, `.metrics`,
  `.tracing`, and `threepio.callbacks`). Nothing reaches the console unless
  the application listens (add `logging` to your own `pubspec.yaml`):

  ```dart
  import 'package:logging/logging.dart';

  void showThreepioLogs() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((r) => print('${r.loggerName}: ${r.message}'));
  }
  ```

* The providers, `OpenAIEmbedder` and `VectorRetriever` also report to the
  new callback chain (the handlers of `options.runContext` and
  `GlobalCallbacks`); a `callbackManager` in the options is still called as
  before.

The new callback API has two things to know. The functions a component fires
callbacks with (`onStart`, `onEnd`, `onError`, `onStartWithStreamInput`,
`onEndWithStreamOutput`, `onEndWithCopies`) are only in `callbacks.dart`: a
class that inherits a member called `onStart`, `onEnd` or `onError` (every
`BaseCallbackHandler` does) and calls it without `this.` would call an
imported function of the same name instead, so the umbrella leaves them out.
Import `callbacks.dart`, with a prefix if the names collide with your own. And
a hook that throws does not fail the component: it is logged
(`threepio.callbacks`, `WARNING`) and the run goes on, where Go lets the error
propagate.

```dart
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/threepio_core.dart';

/// A component of your own that reports its work to the run's handlers.
Future<String> shout(RunContext callerCtx, String text) async {
  var ctx = ensureRunInfo(callerCtx, 'Shout', ComponentType.lambda);
  ctx = await callbacks.onStart(ctx, text);
  try {
    final output = text.toUpperCase();
    await callbacks.onEnd(ctx, output);
    return output;
  } catch (error, stackTrace) {
    await callbacks.onError(ctx, error, stackTrace);
    rethrow;
  }
}
```

### Model providers and embedders

* **Call `dispose()`** on a model or embedder you created without an
  `httpClient` when you no longer need it; using it afterwards throws a
  `StateError`. `OpenAIChatModel`, `OpenRouterChatModel`, `GeminiChatModel`
  and `OpenAIEmbedder` used to create an HTTP client per request and never
  close it; each now has one, shared with its `withTools` copies.
* **`OpenAIChatModel`** runs on the shared OpenAI-compatible client: a stream
  merges chunks that carry nothing into the next one and ends with a
  usage-only chunk; an `error` object inside a stream fails it; zero
  `max_tokens`/`top_p` are not sent; the call's cancel token cancels the
  request; `OpenAIException` implements `ChatModelException`.
* **`OpenRouterChatModel`** sends the same requests. A cancel while the
  response headers are awaited throws `CancelledException` from `stream()` at
  once; a chunk that cannot be parsed ends the stream with an
  `OpenRouterException`.
* **`GeminiChatModel`**: bound tools imply `ToolChoice.allowed`;
  `reasoningContent` and assistant media are sent back; chunks with only a
  finish reason or usage are emitted; a malformed stream chunk fails the
  stream; `GeminiException` implements `ChatModelException`.
* `OpenAIConverters.messageToOpenAI`: base64 images become data URLs, audio
  and video parts are sent (they threw `UnimplementedError`).
* `OpenAIEmbedder` sends `encoding_format` and no longer copies the
  `callbackManager`/`context` entries of `extra` into the request body.
* A header value the platform refuses (an API key with a trailing newline)
  fails with `invalid header field value for "<name>"`, without the value.
* `OpenRouterChatModel` and `RetryingChatModel`'s back-off also stop when the
  cancel token of the new `ChatModelOptions.runContext` is cancelled.

### Kortney runtime

The umbrella's `Runner`, `ChatModelAgent`, `AgentHandler` and `ContextualTool`
now run on the `ChatModelAgent` and `Runner` of `adk.dart`. The public API,
the events, their order and the messages the model is sent are those of 0.1.x
(pinned by golden transcripts). What you can notice:

* `RunHandle.result` completes even when nobody listens to
  `RunHandle.events`, and a session is reserved as soon as `run()` is called,
  so two runs for one `sessionId` started back to back can no longer both
  begin;
* `AgentRunEndEvent.tokenUsage` is the schema `TokenUsage` (events stored with
  the old snake_case keys are still read);
* handlers registered with the new `GlobalCallbacks` hear every agent, graph,
  lambda, tools node, tool and model call of a Kortney run.

### Graphs, splitters and dependencies

* A `StateGraph` that reaches `END` on exactly its last allowed step returns
  its result instead of throwing `MaxIterationsExceededException`.
* `MarkdownSplitter`, `HtmlSplitter` and `RecursiveCharacterTextSplitter` no
  longer loop forever on a long segment without a separator when
  `chunkOverlap` is greater than zero.
* Dependencies: `rxdart`, `equatable` and `async` were removed; `logging`,
  `collection`, `jinja`, `clock`, `glob`, `path`, `yaml`, `archive`, `html`
  and `xml` were added.

### If you used a pre-release build of 0.9

Builds of the parity branch before the release differ from 0.9 in a few
places the CHANGELOG notes: the strict concat functions threw `ArgumentError`
(now `MessageConcatException`); `FunctionTool` wrote backspace and form feed
as `\b` and `\f` (now `\u0008` and `\u000c`, as Go's `sonic`); MCP tool input
schemas were mapped onto `JSONSchema` (now kept as the server sends them);
`TurnLoop.push` returned an already completed `resolved` future (now `null`
for a push that does not preempt or is not accepted); a missing agents.md
file was skipped with every backend (now it fails the run unless the backend
throws `FileNotFoundException`); a tool of a Kortney run that calls
`interrupt` ends the run with an `AgentErrorEvent` whose text names the
interrupt report.

## From the legacy API to the Eino-shaped API

The older APIs stay. Nothing has to move. When
you do move, these are the usual replacements; each pair of snippets does the
same thing.

### Kortney `Runner` and `ChatModelAgent` → `adk.Runner` and `adk.ChatModelAgent`

Before, with the umbrella's runtime:

```dart
import 'package:threepio_core/threepio_core.dart';

Future<void> askKortney(ToolCallingChatModel model, BaseTool weather) async {
  final runner = Runner(
    agent: ChatModelAgent(
      ChatModelAgentConfig(
        name: 'assistant',
        instruction: 'You are a helpful assistant.',
        model: model,
        tools: [weather],
      ),
    ),
  );
  final handle = await runner.run(
    [Message.user('Weather in Lisbon?')],
    sessionId: 'chat-1',
  );
  await for (final event in handle.events) {
    if (event is AgentOutputEvent && !event.isPartial) {
      print(event.message.content);
    }
  }
  final result = await handle.result;
  print('${result.messages.length} messages to keep');
}
```

After, with `adk.dart`:

```dart
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

Future<void> askAgent(ToolCallingChatModel model, BaseTool weather) async {
  final runner = adk.Runner(
    agent: adk.ChatModelAgent(
      adk.ChatModelAgentConfig(
        name: 'assistant',
        description: 'Answers questions about the weather',
        instruction: 'You are a helpful assistant.',
        model: model,
        toolsConfig: adk.ToolsConfig(
          toolsNode: adk.ToolsNodeConfig(tools: [weather]),
        ),
      ),
    ),
  );
  final events = runner.query(RunContext.background(), 'Weather in Lisbon?');
  for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
    if (e.error != null) {
      print('error: ${e.error}');
      break;
    }
    final message = await adk.getMessageFromEvent(e);
    // The final answer: an assistant message without tool calls (tool
    // results arrive as messages of their own).
    if (message != null &&
        message.role == RoleType.assistant &&
        (message.toolCalls?.isEmpty ?? true)) {
      print(message.content);
    }
  }
}
```

| Kortney runtime (umbrella) | `adk.dart` |
|---|---|
| `ChatModelAgentConfig(instruction:, maxIterations:)` | `ChatModelAgentConfig(instruction:, maxIterations:)`; `name` and `description` are needed for an `AgentTool`. With session values the instruction is an f-string template (`{key}`), so literal braces are written `{{` and `}}` |
| `tools: [...]` | `toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [...]))` |
| `parallelToolExecution: false` | `ToolsNodeConfig(executeSequentially: true)` |
| `modelOptions:` | `AgentRunOption.chatModelOptions(...)` per run |
| `emitPartialOutputs` | `Runner(enableStreaming: true)`; read streamed messages with `getMessageFromEvent` |
| `AgentHandler` (`beforeModel`, `afterModel`, `wrapToolCall`) | `ChatModelAgentMiddleware` in `ChatModelAgentConfig.handlers`, or a `ToolMiddleware` in `ToolsNodeConfig(toolCallMiddlewares:)` |
| `ApprovalPolicy` and `RunHandle.approve` | `ApprovableTool` interrupts the run; `Runner.resumeWithParams` answers (needs a `CheckpointStore` and `AgentRunOption.checkpointId`) |
| `RunHandle.cancel()` | `final (option, cancel) = withCancel();` pass `option` to the run, call `cancel()` |
| `AgentRunScope` (`runId`, `sessionId`, `metadata`) | `RunContext` and session values (`AgentRunOption.sessionValues`) |
| `RunResult` | the events themselves; `getMessageFromEvent` reads each message |
| one run per `sessionId` | not provided; keep track of runs yourself |

See [GRAPHS.md](GRAPHS.md) for the graph the agent runs on and the README's
quick start for interrupt and resume.

### `StateGraph` → `Graph` with local state

`StateGraph` passes one state object from node to node. Eino's `Graph` passes
typed values along its edges; a state, when you need one, is local to the run
and is read and written by state handlers and `processState`.

Before:

```dart
import 'package:threepio_core/threepio_core.dart';

class DraftState implements GraphState {
  const DraftState({this.text = '', this.round = 0});

  final String text;
  final int round;

  @override
  DraftState copyWith({String? text, int? round}) =>
      DraftState(text: text ?? this.text, round: round ?? this.round);
}

Future<String> reviseWithStateGraph(String draft) async {
  final graph = StateGraph<DraftState>()
    ..addNode(
      'write',
      (state) async =>
          state.copyWith(text: '${state.text}, revised', round: state.round + 1),
    )
    ..addConditionalEdge('write', (state) => state.round >= 3 ? END : 'write')
    ..setEntryPoint('write');
  final result = await graph.invoke(DraftState(text: draft));
  return result.state.text;
}
```

After:

```dart
import 'package:threepio_core/compose.dart';

/// The state of one run (Go `compose.WithGenLocalState`).
final class Rounds {
  int count = 0;
}

Future<String> reviseWithGraph(String draft) async {
  final graph = Graph<String, String>(
    localState: LocalState.of<Rounds>((ctx) => Rounds()),
  )
    ..addLambdaNode(
      'write',
      Lambda.invokable((RunContext ctx, String text) => '$text, revised'),
      options: NodeOptions(
        statePreHandler: StateHandler.pre<String, Rounds>((ctx, input, state) {
          state.count++;
          return input;
        }),
      ),
    )
    ..addEdge(Graph.start, 'write')
    ..addBranch(
      'write',
      GraphBranch.single<String>((ctx, text) async {
        var rounds = 0;
        await processState<Rounds>(ctx, (ctx, state) {
          rounds = state.count;
        });
        return rounds >= 3 ? Graph.end : 'write';
      }, {'write', Graph.end}),
    );

  final ctx = RunContext.background();
  final runnable = await graph.compile(
    ctx,
    options: const GraphCompileOptions(maxRunSteps: 10),
  );
  return runnable.invoke(ctx, draft);
}
```

| `StateGraph` | `Graph` |
|---|---|
| `addNode(name, (state) async => …)` | `addLambdaNode(key, Lambda.invokable(…))`, `addChatModelNode`, `addToolsNode`, `addRetrieverNode`, … |
| `setEntryPoint(name)` | `addEdge(Graph.start, key)` |
| `addEdge(name, END)` | `addEdge(key, Graph.end)` |
| `addConditionalEdge(from, router)` | `addBranch(from, GraphBranch.single(condition, endNodes))` |
| `StateGraph(maxIterations:)` | `GraphCompileOptions(maxRunSteps:)` |
| `toRunnable()` | `compile(ctx)` returns a `Runnable` (invoke, stream, collect, transform) |
| `StateGraph(checkpointStore:)`, `invoke(…, threadId:, checkpointId:)` | `GraphCompileOptions(checkpointStore:)`, `invoke(ctx, input, options: [CallOption.checkpointId(id)])` |
| `CheckpointConfig(interruptBefore:, interruptAfter:)` | `GraphCompileOptions(interruptBeforeNodes:, interruptAfterNodes:)`, or `throw interrupt(ctx, info)` inside a node |
| `GraphInterruptException` | `GraphInterruptedException` with a `GraphInterruptInfo` |

[GRAPHS.md](GRAPHS.md) covers graphs, chains, workflows, interrupt and
checkpoints.

### `BaseCallbackHandler` → `ComponentCallbackHandler`

Extend `ComponentCallbackHandler`, take the `RunContext` where the hook took
the `Map<String, dynamic>` context (keep what the handler remembers under a
private `ContextKey`, and return the context), and take the payload as
`Object?` where it was a `CallbackInput` or `CallbackOutput`: the payload is
what `input.data` was. Give a run its handlers with
`RunContext.background().withHandlers([...])` instead of
`CallbackManager([...])`.

Before:

```dart
import 'package:threepio_core/threepio_core.dart';

/// Prints how long each component takes.
class TimingHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async =>
      {...context, 'started': DateTime.now()};

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    final started = context['started'] as DateTime?;
    if (started != null) {
      print('${info.name} took ${DateTime.now().difference(started)}');
    }
    return context;
  }
}

Future<Message> ask(BaseChatModel model) => model.generate(
      [Message.user('Hello')],
      options: ChatModelOptions(callbackManager: CallbackManager([TimingHandler()])),
    );
```

After:

```dart
import 'package:threepio_core/threepio_core.dart';

const _started = ContextKey<DateTime>('timing.started');

/// Prints how long each component takes.
class TimingHandler extends ComponentCallbackHandler {
  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) =>
      ctx.withValue(_started, DateTime.now());

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    final started = ctx.value(_started);
    if (started != null) {
      print('${info.name} took ${DateTime.now().difference(started)}');
    }
    return ctx;
  }
}

Future<Message> ask(BaseChatModel model) => model.generate(
      [Message.user('Hello')],
      options: ChatModelOptions(
        runContext: RunContext.background().withHandlers([TimingHandler()]),
      ),
    );
```

`CallbackHandlerBuilder` builds a handler from functions, `HandlerHelper`
gives typed payloads per component kind (`typedAgentCallbackHandler` of
`adk.dart` for agents), and `GlobalCallbacks.append` registers handlers for
every run. See
[CALLBACKS.md](CALLBACKS.md).

### LangChain-style chains → `Chain`

The chains of `legacy_chains.dart` pass `Map<String, dynamic>` from step to
step. Eino's `Chain<I, O>` is a typed graph built in a line.

Before:

```dart
import 'package:threepio_core/legacy_chains.dart';
import 'package:threepio_core/threepio_core.dart';

Future<String> answerWithLLMChain(BaseChatModel model, String question) async {
  final chain = LLMChain(
    template: ChatTemplate.fromMessages(FormatType.fString, [
      Message.system('You are a concise assistant.'),
      Message.user('{question}'),
    ]),
    model: model,
    outputKey: 'answer',
  );
  final outputs = await chain.run({'question': question});
  return outputs['answer'] as String;
}
```

After:

```dart
import 'package:threepio_core/compose.dart';

Future<String> answerWithChain(BaseChatModel model, String question) async {
  final chain = Chain<Map<String, dynamic>, Message>()
    ..appendChatTemplate(
      ChatTemplate.fromMessages(FormatType.fString, [
        Message.system('You are a concise assistant.'),
        Message.user('{question}'),
      ]),
    )
    ..appendChatModel(model);
  final ctx = RunContext.background();
  final runnable = await chain.compile(ctx);
  final answer = await runnable.invoke(ctx, {'question': question});
  return answer.content;
}
```

| Legacy chain | `Chain` |
|---|---|
| `LLMChain` | `appendChatTemplate` + `appendChatModel` |
| `TransformChain` | `appendLambda(Lambda.invokable(…))` |
| `SequentialChain` | one `Chain` with the steps appended in order, or `appendGraph` for a sub-chain, graph or workflow (compiled with the chain) |
| `ParallelChain` | `appendParallel(Parallel()..addLambda(…))` |
| `RouterChain` | `appendBranch(ChainBranch…)` |
| `RetrievalQAChain` | `appendRetriever` + a lambda that formats the documents + template + model; see [RAG.md](RAG.md) |

### The older agents → the agents of `adk.dart`

| Older agent (umbrella) | `adk.dart` |
|---|---|
| `Agent` and `AgentConfig` (the ReAct loop of `components/tool/agent.dart`) | `ChatModelAgent` + `Runner` |
| `LegacyChatModelAgent` | `ChatModelAgent` + `Runner` |
| `PlanExecuteAgent` | `PlanExecute.create` with `PlanExecute.planner`, `.executor`, `.replanner` |
| `SupervisorAgent` | `DeepAgent.create` with `subAgents` (it delegates through its `task` tool), or a `ChatModelAgent` whose tools are `AgentTool`s |
| `WorkflowAgent` (sequential, parallel, loop) | not ported: Eino marks its workflow agents as not recommended. Run agents from the nodes of a compose `Graph` or `Workflow`, or keep `WorkflowAgent` |
| `AgentTool` of the umbrella (wraps a `BaseAgent`) | `AgentTool(agent)` |
| `AgentRunContext` (`shouldCancel`) | the run's `RunContext` and its `CancelToken`, or `withCancel()` |

```dart
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// Plan, execute, replan (Go `planexecute.New`).
Future<adk.Agent> planExecuteAgent(
  ToolCallingChatModel model,
  List<BaseTool> tools,
) async {
  final ctx = RunContext.background();
  return adk.PlanExecute.create(
    ctx,
    adk.PlanExecuteLoopConfig(
      planner: await adk.PlanExecute.planner(
        ctx,
        adk.PlannerConfig(toolCallingChatModel: model),
      ),
      executor: await adk.PlanExecute.executor(
        ctx,
        adk.ExecutorConfig(
          model: model,
          toolsConfig: adk.ToolsConfig(
            toolsNode: adk.ToolsNodeConfig(tools: tools),
          ),
        ),
      ),
      replanner: await adk.PlanExecute.replanner(
        ctx,
        adk.ReplannerConfig(chatModel: model),
      ),
    ),
  );
}

/// A coordinator that hands work to a researcher, two ways.
Future<List<adk.Agent>> coordinators(
  ToolCallingChatModel model,
  adk.Agent researcher,
) async {
  // A deep agent delegates to its sub-agents (Go `deep.New`).
  final deep = await adk.DeepAgent.create(
    RunContext.background(),
    adk.DeepAgentConfig(
      chatModel: model,
      name: 'coordinator',
      description: 'Plans the work and delegates research',
      subAgents: [researcher],
    ),
  );

  // A chat model agent calls the researcher as a tool (Go `adk.NewAgentTool`).
  final withTool = adk.ChatModelAgent(
    adk.ChatModelAgentConfig(
      name: 'coordinator',
      description: 'Answers with the help of a researcher',
      model: model,
      toolsConfig: adk.ToolsConfig(
        toolsNode: adk.ToolsNodeConfig(tools: [adk.AgentTool(researcher)]),
      ),
    ),
  );
  return [deep, withTool];
}
```

### The Langfuse ingestion client → `LangfuseHandler`

The client in `src/observability/langfuse/` was never exported and used an
API Langfuse has deprecated. `LangfuseHandler` (`callbacks.dart`, umbrella)
exports traces over OpenTelemetry (port of eino-ext `callbacks/langfuse/v2`):

```dart
import 'package:threepio_core/threepio_core.dart';

Future<void> tracedAnswer(
  BaseChatModel model,
  String publicKey,
  String secretKey,
) async {
  final langfuse = LangfuseHandler(
    LangfuseConfig(
      host: 'https://cloud.langfuse.com',
      publicKey: publicKey,
      secretKey: secretKey,
    ),
  );
  final ctx = langfuse.startTrace(
    RunContext.background().withHandlers([langfuse]),
    name: 'answer-question',
    input: 'What is a DAG?',
  );
  final answer = await model.generate(
    [Message.user('What is a DAG?')],
    options: ChatModelOptions(runContext: ctx),
  );
  langfuse.endTrace(ctx, answer.content);
  await langfuse.shutdown(); // before the application exits
}
```

## For Eino (Go) users

The Dart API keeps Eino's structure and names. These rules translate the
rest:

* **`context.Context` → `RunContext`**, the first positional parameter of
  every Eino-shaped API (`runnable.invoke(ctx, input)`,
  `invokableRun(ctx, args)`, `agent.run(ctx, input)`). It is immutable:
  `withValue`, `withHandlers` and `withCancelToken` return copies. Cancellation
  is its `CancelToken`. Component contracts that predate the port
  (`BaseChatModel.generate`, `Retriever.retrieve`, `Embedder`, `ChatTemplate`,
  `DocumentTransformer`, …) take it as `options.runContext`; graph nodes set it
  for you.
* **Functional options → option objects.** A component's options are one
  immutable class with named parameters (`ChatModelOptions(temperature: …)`),
  merged field by field; implementation-specific options go into
  `extensions` (Go `WrapImplSpecificOptFn`). Scoped run options are sealed
  classes with one factory per `WithX`: `CallOption.callbacks(…)`,
  `CallOption.checkpointId(…)`, `AgentRunOption.sessionValues(…)`, each with
  `designateNode` / `designateAgent`. Config structs are classes with named
  parameters (`ChatModelAgentConfig`, `GraphCompileOptions`).
* **Streams are pull streams**: `StreamReader<T>` with `recv()` (throws
  `StreamEOFException` at the end), `nextOrNull()` (`null` at the end, the
  shape of a Go `Recv` loop), `copy(n)` and `close()`. Eino's `AsyncIterator`
  and `AsyncGenerator` are `StreamReader` and `StreamWriter`/`pipe()`.
  `asStream()` gives a Dart `Stream` for `await for`.
* **Errors are exceptions.** Domain errors extend or implement
  `ThreepioException` (with `cause`, Go's `Unwrap`; `findCause` is
  `errors.As`); misuse is `ArgumentError` or `StateError` where Go panics.
  An interrupt is thrown (`throw interrupt(ctx, info)`) and a graph surfaces
  it as `GraphInterruptedException`; code that catches errors lets
  `InterruptSignal` through.
* **Interfaces → abstract classes.** New pure contracts are
  `abstract interface class` (`Agent`, `CheckpointStore`, `Indexer`); contracts
  with default behaviour are `abstract class`es you extend
  (`ComponentCallbackHandler`, `ChatModelAgentMiddleware`); sum types are
  `sealed` (`CallOption`, `AgentRunOption`, `ParamsOneOf`). Go generic
  constructors become static generic methods (`StateHandler.pre<I, S>`,
  `GraphBranch.single<T>`, `Lambda.invokableWithOption<I, O, T>`).
* **No reflection.** Registries match values with `is T`, never by
  `runtimeType`: `TypeRegistry.registerName<T>` (Go `schema.RegisterName`),
  `StreamConcat.register<T>`, `ValuesMerge.register<T>`. `utils.InferTool`
  becomes `FunctionTool` with the parameters and a `fromJson` written out;
  workflow field mapping works on maps and on classes that implement
  `FieldAddressable`.
* **Checkpoints are JSON, not `gob`.** Every value in a checkpoint that is not
  JSON (a graph's state, an interrupt's state, the session values of an
  agent) is registered with `TypeRegistry.registerName` before the run is
  interrupted or resumed. The schema types are registered already.

```dart
import 'package:threepio_core/compose.dart';

/// The state of a review graph, written to checkpoints as JSON.
final class ReviewState {
  ReviewState(this.round);

  factory ReviewState.fromJson(Map<String, Object?> json) =>
      ReviewState(json['round']! as int);

  final int round;

  Map<String, Object?> toJson() => {'round': round};
}

/// Call once, before a run is interrupted or resumed.
void registerReviewState() {
  // Go: schema.RegisterName[*ReviewState]("review_state")
  TypeRegistry.registerName<ReviewState>(
    'review_state',
    fromJson: ReviewState.fromJson,
    toJson: (state) => state.toJson(),
  );
}

Future<void> goToDart(
  Runnable<String, String> runnable,
  ComponentCallbackHandler handler,
) async {
  // Go: ctx := context.Background()
  final ctx = RunContext.background();

  // Go: out, err := runnable.Invoke(ctx, "hi", compose.WithCallbacks(handler))
  try {
    final out = await runnable.invoke(
      ctx,
      'hi',
      options: [CallOption.callbacks([handler])],
    );
    print(out);
  } on ThreepioException catch (e) {
    print('failed: $e');
  }

  // Go: sr, err := runnable.Stream(ctx, "hi"); for { chunk, err := sr.Recv() … }
  final reader = await runnable.stream(ctx, 'hi');
  try {
    for (var chunk = await reader.nextOrNull();
        chunk != null;
        chunk = await reader.nextOrNull()) {
      print(chunk);
    }
  } finally {
    await reader.close();
  }
}
```

The [README's mapping table](../README.md#mapping-from-eino-go) maps each Go
package and symbol to its Dart name; the CHANGELOG's "Differences from Eino"
lists say where the Dart port behaves differently and why.
