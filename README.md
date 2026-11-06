# Threepio

> The package is in [`packages/threepio_core`](packages/threepio_core); this file is a copy of its README with links relative to the repository root.

Threepio is a Dart port of [Eino](https://github.com/cloudwego/eino), the LLM
application framework from CloudWeGo (ByteDance), together with the
components of [eino-ext](https://github.com/cloudwego/eino-ext). It follows
Eino v0.9.22: the same packages (`schema`, `components`, `compose`,
`callbacks`, `flow`, `adk`), the same concepts and, wherever Dart allows, the
same names. Code and documentation written for Eino translate almost line by
line; the [mapping table](#mapping-from-eino-go) below lists the Dart names of
the Go symbols a user meets most.

Version 0.9.0 tracks Eino v0.9. The package is still 0.x: the names that
collide with older threepio classes stay as they are until 1.0, which decides
them (see [Which API do I use?](#which-api-do-i-use)). Parts that upstream labels
**beta** (the agentic path) are labelled beta here too. Threepio runs on the
Dart VM and in Flutter. `schema.dart`, `streaming.dart`, `components.dart`,
`compose.dart`, `callbacks.dart`, `flow.dart` and `adk.dart` do not import
`dart:io` (they are meant to run on the web too; that is not tested);
`io.dart` and the umbrella library (its older file loaders and stores, the
Gemini provider's configuration) need it.

## Contents

- [Installation](#installation)
- [Libraries](#libraries)
- [Which API do I use?](#which-api-do-i-use)
- [Quick start](#quick-start)
- [Mapping from Eino (Go)](#mapping-from-eino-go)
- [Examples](#examples)
- [Documentation](#documentation)
- [Legacy API (before 0.9)](#legacy-api-before-09)
- [Development](#development)
- [Versioning](#versioning)
- [License and acknowledgments](#license-and-acknowledgments)

## Installation

Threepio needs Dart 3.9 or later (Flutter 3.35 or later). It is not published
on pub.dev; depend on the repository:

```yaml
dependencies:
  threepio_core:
    git:
      url: https://github.com/EsotericTech/threepio.git
      path: packages/threepio_core
      ref: main # or a commit
```

## Libraries

Import the umbrella library, or the libraries one by one.

| Library | Contents | Eino package |
|---|---|---|
| `package:threepio_core/threepio_core.dart` | The umbrella: `schema`, `streaming`, `components`, `compose`, `callbacks` (without the six functions that fire callbacks) and `flow`, plus the model providers, the older APIs and the Kortney agent runtime. Not `adk.dart`, `io.dart` or `legacy_chains.dart`, nor, of `legacy_graph.dart`, the five checkpoint names compose took over (`CheckpointStore`, `InMemoryCheckpointStore`, `FileCheckpointStore`, `CheckpointSerializer`, `JsonCheckpointSerializer`) and `LegacyRunnable`/`LegacyLambda` | — |
| `package:threepio_core/schema.dart` | `Message`, `ToolInfo`, `Document`, templates, concatenation, `TypeRegistry`, `RunContext`, exceptions, agentic messages (beta) | `schema` |
| `package:threepio_core/streaming.dart` | `StreamReader`, `StreamWriter`, `pipe`, merge and copy | `schema` (streams) |
| `package:threepio_core/components.dart` | Component contracts (chat model, tool, template, embedder, retriever, indexer, loader, parser, transformer), their options and callback payloads; platform-neutral implementations (tools, MCP, Qdrant, document parsers and splitters) | `components`, eino-ext |
| `package:threepio_core/compose.dart` | `Runnable`, `Lambda`, `Graph`, `Chain`, `Workflow`, `ToolsNode`, interrupt, checkpoint, resume; re-exports `components.dart`, `schema.dart`, `streaming.dart` | `compose` |
| `package:threepio_core/callbacks.dart` | Callback handlers, `HandlerHelper`, global handlers, Langfuse and LangSmith tracing, OTLP export | `callbacks`, `utils/callbacks`, eino-ext `callbacks` |
| `package:threepio_core/flow.dart` | The parent indexer and `concurrentRetrieve`; re-exports `components.dart`, where the multi-query, parent and router retrievers (`fromConfig`) live | `flow` |
| `package:threepio_core/adk.dart` | Agents: `ChatModelAgent`, `Runner`, `AgentTool`, interrupt and resume, cancel, `TurnLoop`, middlewares, `DeepAgent`, `PlanExecute`, the agentic agent (beta); re-exports `compose.dart` | `adk` |
| `package:threepio_core/io.dart` | What needs `dart:io`: `FileCheckpointStore`, `FileLoader`, `FileEmbeddingCache`, the local filesystem backend and shell, the stdio MCP transport, `LocalOperator` | — |
| `package:threepio_core/legacy_graph.dart` | The pre-0.9 `StateGraph` with all its checkpoint classes (including the five the umbrella hides), `LegacyRunnable` and `LegacyLambda` | — |
| `package:threepio_core/legacy_chains.dart` | The pre-0.9 LangChain-style chains | — |

## Which API do I use?

> Threepio 0.9 contains two generations of API. Some names exist in both, so
> the choice matters:
>
> | For | Use | Import |
> |---|---|---|
> | Agents, in new code | `ChatModelAgent`, `Runner`, `AgentTool`, `DeepAgent`, `PlanExecute`, the middlewares — the Eino ADK | `adk.dart`, with the prefix `as adk` when the umbrella is imported too |
> | An app already on the Kortney runtime | the umbrella's `Runner`, `ChatModelAgent`, sealed `AgentEvent`, `RunHandle.approve` | `threepio_core.dart`. A compatibility facade, built on `adk.dart`; its events and behaviour are pinned by golden transcripts |
> | Pipelines and orchestration | `Chain`, `Graph`, `Workflow`, `Lambda` | `compose.dart` or the umbrella |
> | Messages | `Message`. Keep it unless you need a model's native agentic protocol (server tools, MCP blocks): then `AgenticMessage` and the agentic models (beta) | `schema.dart` or the umbrella |
> | Observing a run | `ComponentCallbackHandler`, `HandlerHelper`, `RunContext.withHandlers` — not `BaseCallbackHandler` | `callbacks.dart` or the umbrella |
>
> `adk.dart` is the one Eino-shaped library the umbrella does not export, because its
> `Agent`, `AgentEvent`, `AgentAction`, `Runner`, `ChatModelAgent`,
> `ChatModelAgentConfig`, `ChatModelAgentState` and `AgentTool` are also the
> names of the older classes. Code that needs both imports them like this:
>
> ```dart
> import 'package:threepio_core/adk.dart' as adk;
> import 'package:threepio_core/threepio_core.dart';
> ```
>
> Whether the umbrella switches to the Eino names is a 1.0 decision.

## Quick start

The Eino-shaped APIs (runnables, graphs, chains, tools, agents, callbacks)
take a `RunContext` as their first argument (Go's `context.Context`): it
carries cancellation, callback handlers and run-scoped values.
`RunContext.background()` is the root. The component contracts that predate
the port (`BaseChatModel.generate`/`stream`, `Retriever.retrieve`,
`Embedder.embedStrings`, `ChatTemplate.format`,
`DocumentTransformer.transform`) take it as `options.runContext` instead
(`ChatModelOptions(runContext: ctx)`); graph nodes and agents set it for you.

The snippets use `OpenAIChatModel`; `OpenRouterChatModel`, `ClaudeChatModel`,
`GeminiChatModel`, `OllamaChatModel` and `OpenAICompatibleChatModel` (DeepSeek,
Qwen, Ark and other OpenAI-compatible endpoints) are drop-in replacements.

### 1. A template and a model in a chain

```dart
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> main() async {
  final model = OpenAIChatModel(
    config: OpenAIConfig(apiKey: Platform.environment['OPENAI_API_KEY']!),
  );

  // A chat template (Eino `prompt.FromMessages`): f-string variables and a
  // placeholder for earlier messages.
  final template = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system('You are a {role}.'),
    const MessagesPlaceholder('history', optional: true),
    Message.user('{question}'),
  ]);

  // template → model, compiled into a Runnable (Eino `compose.NewChain`).
  final chain = Chain<Map<String, dynamic>, Message>()
    ..appendChatTemplate(template)
    ..appendChatModel(model);
  final ctx = RunContext.background();
  final runnable = await chain.compile(ctx);

  final variables = {'role': 'concise assistant', 'question': 'What is a DAG?'};
  final answer = await runnable.invoke(ctx, variables);
  print(answer.content);

  // The same runnable streams; chunks arrive as the model writes them.
  final chunks = await runnable.stream(ctx, variables);
  for (var c = await chunks.nextOrNull(); c != null; c = await chunks.nextOrNull()) {
    stdout.write(c.content);
  }

  model.dispose();
}
```

A compiled runnable has Eino's four modes: `invoke` (value in, value out),
`stream` (value in, stream out), `collect` (stream in, value out) and
`transform` (stream in, stream out); components that implement only some of
them are adapted. Streams are pull-based `StreamReader`s (`recv()`,
`nextOrNull()`, `close()`), as in Go.

### 2. An agent: `adk.ChatModelAgent` and `adk.Runner`

```dart
import 'dart:io';

import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// The input of the tool, decoded from the JSON arguments the model writes.
final class WeatherQuery {
  const WeatherQuery(this.city);

  factory WeatherQuery.fromJson(Map<String, Object?> json) =>
      WeatherQuery(json['city']! as String);

  final String city;
}

Future<void> main() async {
  final model = OpenAIChatModel(
    config: OpenAIConfig(apiKey: Platform.environment['OPENAI_API_KEY']!),
  );

  // A tool from a typed function (Eino `utils.InferTool`; without reflection
  // the parameters and the decoder are written out).
  final weather = FunctionTool<WeatherQuery, String>(
    name: 'get_weather',
    description: 'The current weather in a city',
    params: const ParamsOneOf.params({
      'city': ParameterInfo(type: DataType.string, desc: 'City name', required: true),
    }),
    fromJson: WeatherQuery.fromJson,
    invoke: (ctx, query, options) => 'Sunny and 21 °C in ${query.city}',
  );

  // Eino `adk.NewChatModelAgent`: the model calls tools in a loop until it
  // answers.
  final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
    name: 'assistant',
    description: 'Answers questions about the weather',
    instruction: 'You are a helpful assistant. Use the tools you have.',
    model: model,
    toolsConfig: adk.ToolsConfig(
      toolsNode: adk.ToolsNodeConfig(tools: [weather]),
    ),
  ));

  // Eino `adk.NewRunner` + `Runner.Query`: a pull stream of AgentEvents.
  final runner = adk.Runner(agent: agent);
  final events = runner.query(RunContext.background(), 'Weather in Lisbon?');
  for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
    if (e.error != null) {
      print('error: ${e.error}');
      break;
    }
    final message = await adk.getMessageFromEvent(e);
    if (message == null) continue;
    if (message.toolCalls?.isNotEmpty ?? false) {
      print('[calls ${message.toolCalls!.map((c) => c.function.name).join(', ')}]');
    } else {
      print('${message.role.name}: ${message.content}');
    }
  }

  model.dispose();
}
```

`Runner(enableStreaming: true)` streams the messages of the events; session
values, callbacks and model options go in as `AgentRunOption`s. Middlewares
(`ChatModelAgentConfig.handlers`) hook into the run, the model calls and the
tool calls; the built-in ones summarise long histories, offload large tool
results, add filesystem tools, skills, task plans and tool search, patch
dangling tool calls and load AGENTS.md files.

### 3. Interrupt and resume

A run can stop for a human and continue later, in the same process or —
with a persistent `CheckpointStore` — in another one. `ApprovableTool` is the
ready-made case: it interrupts before the tool it wraps runs.

```dart
import 'dart:io';

import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// Books a ticket: something to do only after asking.
final class BookTicket extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'book_ticket',
        desc: 'Books a train ticket',
        params: const {
          'destination': ParameterInfo(type: DataType.string, required: true),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'booked $argumentsJson';
}

Future<void> main() async {
  final model = OpenAIChatModel(
    config: OpenAIConfig(apiKey: Platform.environment['OPENAI_API_KEY']!),
  );
  final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
    name: 'booker',
    description: 'Books train tickets',
    instruction: 'Book what the user asks for with book_ticket.',
    model: model,
    toolsConfig: adk.ToolsConfig(
      // ApprovableTool interrupts the run before the wrapped tool runs.
      toolsNode: adk.ToolsNodeConfig(tools: [adk.ApprovableTool(BookTicket())]),
    ),
  ));

  // A checkpoint store and a checkpoint id make the run resumable.
  final runner = adk.Runner(
    agent: agent,
    checkpointStore: adk.InMemoryCheckpointStore(),
  );
  final ctx = RunContext.background();
  final events = runner.query(ctx, 'A ticket to Porto, please.',
      options: [adk.AgentRunOption.checkpointId('trip-1')]);

  // Read until the interrupt; its contexts say what waits, and where.
  adk.InterruptCtx? waiting;
  for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
    final interrupted = e.action?.interrupted;
    if (interrupted != null) waiting = interrupted.interruptContexts.first;
  }
  if (waiting == null) return;
  print(waiting.info); // tool 'book_ticket' interrupted with arguments …

  // Later, here or in another process with a persistent store: the answer.
  stdout.write('Approve? [y/N] ');
  final approved = stdin.readLineSync()?.trim().toLowerCase() == 'y';
  final resumed = await runner.resumeWithParams(
    ctx,
    'trip-1',
    adk.ResumeParams(
      targets: {waiting.id: adk.ApprovalResult(approved: approved)},
    ),
  );
  for (var e = await resumed.nextOrNull(); e != null; e = await resumed.nextOrNull()) {
    final message = await adk.getMessageFromEvent(e);
    if (message != null) print('${message.role.name}: ${message.content}');
  }

  model.dispose();
}
```

Any tool or graph node can interrupt itself by throwing `interrupt(ctx, info)`,
`statefulInterrupt(…)` or `compositeInterrupt(…)` (Go returns them as errors)
and read the saved state and the answer on resume with `getInterruptState`
and `getResumeContext`
([`example/hitl_approval_example.dart`](packages/threepio_core/example/hitl_approval_example.dart)
does that by hand). Checkpoints are JSON; types stored in them are registered
with `TypeRegistry.registerName`. `FileCheckpointStore` (`io.dart`) keeps them
on disk. The same mechanism works for a compose `Graph`, see
[doc/GRAPHS.md](packages/threepio_core/doc/GRAPHS.md).

### 4. A graph with state

```dart
import 'package:threepio_core/compose.dart';

/// The state of one run (Eino `compose.WithGenLocalState`).
final class DraftState {
  int round = 0;
  final List<String> drafts = [];
}

Future<void> main() async {
  final graph = Graph<String, String>(
    localState: LocalState.of<DraftState>((ctx) => DraftState()),
  )
    ..addLambdaNode(
      'write',
      Lambda.invokable((RunContext ctx, String text) => '$text, revised'),
      options: NodeOptions(
        // Before the node runs (Eino `WithStatePreHandler`).
        statePreHandler: StateHandler.pre<String, DraftState>(
          (ctx, input, state) {
            state.round++;
            return input;
          },
        ),
        // After it ran (Eino `WithStatePostHandler`).
        statePostHandler: StateHandler.post<String, DraftState>(
          (ctx, output, state) {
            state.drafts.add(output);
            return output;
          },
        ),
      ),
    )
    ..addLambdaNode(
      'review',
      Lambda.invokable((RunContext ctx, String draft) => '$draft (reviewed)'),
    )
    ..addEdge(Graph.start, 'write')
    ..addEdge('write', 'review')
    // A branch reads the state with processState (Eino `ProcessState`).
    ..addBranch(
      'review',
      GraphBranch.single<String>((ctx, draft) async {
        var round = 0;
        await processState<DraftState>(ctx, (ctx, state) {
          round = state.round;
        });
        return round >= 3 ? Graph.end : 'write';
      }, {'write', Graph.end}),
    );

  final ctx = RunContext.background();
  final runnable = await graph.compile(
    ctx,
    options: const GraphCompileOptions(maxRunSteps: 10),
  );
  print(await runnable.invoke(ctx, 'A first draft'));
  print(graph.toMermaid());
}
```

It prints `A first draft, revised (reviewed), revised (reviewed), revised
(reviewed)` and the graph as a Mermaid flowchart. The types along every edge
are checked when the edge is added; a graph runs in Pregel steps (cycles
allowed, bounded by `maxRunSteps`) unless compiled with
`NodeTriggerMode.allPredecessor` (a DAG). Chat models, templates, tools
nodes, retrievers, embedders, indexers, loaders, transformers, lambdas and
other graphs are all nodes.

## Mapping from Eino (Go)

The Dart names of the Eino symbols a user meets most. Go's `PascalCase` becomes
`lowerCamelCase` for members and functions; `NewX(cfg)` becomes a
constructor `X(config)` or a static method where a constructor cannot do
the job.

### Translation rules

| Go | Dart |
|---|---|
| `ctx context.Context` first parameter | `RunContext ctx` first positional parameter of the Eino-shaped APIs; the older component contracts (`generate`, `retrieve`, `embedStrings`, `format`, `transform`) take `options.runContext`; `RunContext.background()`; values with `ContextKey<T>` and `ctx.withValue` |
| Functional options (`WithTemperature(0.2)`, `compose.WithCallbacks(h)`) | Option objects (`ChatModelOptions(temperature: 0.2)`, `CallOption.callbacks([h])`, `AgentRunOption.checkpointId('id')`) |
| Implementation-specific options (`WrapImplSpecificOptFn`, `GetImplSpecificOptions`) | `extensions: [OpenAIRequestOptions(…)]` on the options object (each provider has its own `…RequestOptions`), read back with `options.extension<T>()` |
| `(T, error)` | `Future<T>` that throws; domain errors implement `ThreepioException` |
| `*schema.StreamReader[T]`, `AsyncIterator[T]` | `StreamReader<T>` (pull-based; `recv()` throws at the end, `nextOrNull()` returns `null`) |
| `NewAsyncIteratorPair`, `schema.Pipe` | `pipe<T>()` |
| Interfaces | `abstract interface class` / `abstract class`; sum types are `sealed` |
| Generic functions keyed by type (`ProcessState[S]`, `GetInterruptState[T]`) | Generic functions (`processState<S>`, `getInterruptState<T>`), matched with `is T` |
| Reflection (`utils.InferTool`, gob) | Explicit `ParamsOneOf` + `fromJson`; JSON checkpoints with `TypeRegistry.registerName` |
| `compose.START`, `compose.END` | `Graph.start`, `Graph.end` |
| Panics recovered as errors | Exceptions; node errors carry the node key |

### `schema` → `schema.dart`, `streaming.dart`

| Eino (Go) | Dart |
|---|---|
| `Message`, `SystemMessage`, `UserMessage`, `AssistantMessage`, `ToolMessage` | `Message`, `Message.system`, `Message.user`, `Message.assistant`, `Message.tool` (immutable; `copyWith`) |
| `RoleType`, `ToolCall`, `FunctionCall`, `ResponseMeta`, `TokenUsage`, `LogProbs` | same names |
| `MessageInputPart`, `MessageOutputPart`, `UserInputMultiContent`, `AssistantGenMultiContent` | same names (`Message.userInputMultiContent`, `assistantGenMultiContent`) |
| `MessagesTemplate`, `MessagesPlaceholder`, `FormatType` (`FString`, `Jinja2`, `GoTemplate`) | same names; `FormatType.goTemplate` throws `UnsupportedError` |
| `ConcatMessages`, `ConcatMessageArray`, `ConcatMessageStream`, `ConcatToolResults` | `concatMessages`, `concatMessageArray`, `concatMessageStream`, `concatToolResults` (conflicts throw `MessageConcatException`) |
| `ToolInfo`, `ParameterInfo`, `DataType` | `ToolInfo` (`ToolInfo.fromParams`, `.fromJsonSchemaMap`), `ParameterInfo`, `DataType` |
| `ParamsOneOf`, `NewParamsOneOfByParams`, `NewParamsOneOfByJSONSchema` | `ParamsOneOf`, `ParamsOneOf.params`, `ParamsOneOf.jsonSchemaMap` |
| `ToolChoice` (`Forbidden`, `Allowed`, `Forced`) | `ToolChoice.forbidden`, `.allowed`, `.forced` |
| `ToolArgument`, `ToolResult`, `ToolOutputPart` | same names |
| `Document`, `WithScore`/`Score`, `WithSubIndexes`, `WithDenseVector`, `WithExtraInfo`, `WithDSLInfo` | `Document` and its extension `DocumentMetaX`: `withScore`/`effectiveScore`, `withSubIndexes`/`subIndexes`, `withDenseVector`/`denseVector`, `withExtraInfo`, `withDslInfo` |
| `MessageJSONParser`, `MessageJSONParseConfig` (`ParseFrom`, `ParseKeyPath`) | `MessageJsonParser` (`MessageParseFrom`, `parseKeyPath`) |
| `StreamReader`, `StreamWriter`, `Pipe`, `StreamReaderFromArray`, `StreamReaderWithConvert` | `StreamReader`, `StreamWriter`, `pipe`, `StreamReader.fromIterable`, `reader.convert` |
| `MergeStreamReaders`, `MergeNamedStreamReaders`, `SourceEOF` | `mergeStreamReaders`, `mergeNamedStreamReaders`, `SourceEOFException` |
| `compose.RegisterStreamChunkConcatFunc` | `StreamConcat.register` |
| `RegisterName[T]` | `TypeRegistry.registerName<T>` |
| `AgenticMessage`, `ContentBlock`, block types, `ConcatAgenticMessages` (beta) | same names; the MCP blocks are `AgenticMcp…`; provider extensions carry an `OpenAI`/`Claude`/`Gemini` prefix |

### `components` → `components.dart` (providers in the umbrella)

| Eino (Go) | Dart |
|---|---|
| `model.BaseChatModel` (`Generate`, `Stream`) | `BaseChatModel` (`generate`, `stream`; no `ctx` parameter: `generate(messages, options: ChatModelOptions(runContext: ctx))`) |
| `model.ToolCallingChatModel.WithTools` | `ToolCallingChatModel.withTools` |
| `model.Option`s, `model.Options` | `ChatModelOptions` |
| `model.CallbackInput`, `CallbackOutput` (and those of every component) | `ModelCallbackInput`, `ModelCallbackOutput` (`ToolCallbackInput`, `RetrieverCallbackInput`, …) |
| `prompt.ChatTemplate`, `prompt.FromMessages` | `ChatTemplate`, `ChatTemplate.fromMessages` (a `DefaultChatTemplate`) |
| `tool.BaseTool`, `InvokableTool`, `StreamableTool`, `EnhancedInvokableTool`, `EnhancedStreamableTool` | same names |
| `utils.NewTool`, `utils.InferTool`, `utils.InferStreamTool`, `utils.InferEnhancedTool`, `utils.InferEnhancedStreamTool`, `utils.WrapToolWithErrorHandler` | `FunctionTool.fromInfo`, `FunctionTool`, `StreamFunctionTool`, `EnhancedFunctionTool`, `EnhancedStreamFunctionTool`, `wrapToolWithErrorHandler` |
| `embedding.Embedder`, `indexer.Indexer`, `retriever.Retriever` | `Embedder`, `Indexer`, `Retriever` |
| `document.Loader`, `parser.Parser`, `parser.TextParser`, `parser.ExtParser`, `document.Transformer` | `Loader`, `Parser`, `TextParser`, `ExtParser`, `DocumentTransformer` |
| `components.Typer`, `components.Checker` | `TypedComponent`, `CallbackAwareComponent` |
| `model.AgenticModel`, `prompt.AgenticChatTemplate` (beta) | `AgenticModel`, `AgenticChatTemplate` |

### `compose` → `compose.dart`

| Eino (Go) | Dart |
|---|---|
| `Runnable[I, O]` (`Invoke`, `Stream`, `Collect`, `Transform`) | `Runnable<I, O>` (`invoke`, `stream`, `collect`, `transform`) |
| `InvokableLambda`, `StreamableLambda`, `CollectableLambda`, `TransformableLambda`, `AnyLambda` | `Lambda.invokable`, `.streamable`, `.collectable`, `.transformable`, `.any` (and `…WithOption` static methods) |
| `NewGraph[I, O]`, `WithGenLocalState` | `Graph<I, O>(localState: LocalState.of<S>(…))` |
| `AddChatModelNode`, `AddChatTemplateNode`, `AddToolsNode`, `AddLambdaNode`, `AddGraphNode`, `AddRetrieverNode`, … | `addChatModelNode`, `addChatTemplateNode`, `addToolsNode`, `addLambdaNode`, `addGraphNode`, `addRetrieverNode`, … |
| `AddEdge`, `AddBranch`, `NewGraphBranch`, `NewGraphMultiBranch`, `NewStreamGraphBranch`, `NewStreamGraphMultiBranch` | `addEdge`, `addBranch`, `GraphBranch.single`, `.multi`, `.stream`, `.streamMulti` |
| `WithNodeName`, `WithNodeKey`, `WithInputKey`, `WithOutputKey`, `WithStatePreHandler`, `WithStatePostHandler`, `WithStreamStatePreHandler`, `WithStreamStatePostHandler`, `WithGraphCompileOptions` | `NodeOptions(name:, key:, inputKey:, outputKey:, statePreHandler: StateHandler.pre(…), statePostHandler: StateHandler.post(…), streamStatePreHandler: StateHandler.streamPre(…), streamStatePostHandler: StateHandler.streamPost(…), compileOptions:)` |
| `ProcessState[S]` | `processState<S>` |
| `WithMaxRunSteps`, `WithNodeTriggerMode`, `WithCheckPointStore`, `WithInterruptBeforeNodes`, `WithInterruptAfterNodes`, `WithFanInMergeConfig` | `GraphCompileOptions(maxRunSteps:, nodeTriggerMode:, checkpointStore:, interruptBeforeNodes:, interruptAfterNodes:, fanInMergeConfig:)` |
| `InitGraphCompileCallbacks` | `GraphCompileCallbacks.setGlobal` (`appendGlobal` adds) |
| `WithCallbacks`, `WithChatModelOption`, `WithChatTemplateOption`, `WithToolsNodeOption`, `WithLambdaOption`, `WithEmbeddingOption`, `WithRetrieverOption`, `WithLoaderOption`, `WithDocumentTransformerOption`, `WithIndexerOption` | `CallOption.callbacks`, `.chatModel`, `.chatTemplate`, `.toolsNode`, `.lambda`, `.embedding`, `.retriever`, `.loader`, `.documentTransformer`, `.indexer` |
| `WithCheckPointID`, `WithWriteToCheckPointID`, `WithForceNewRun`, `WithStateModifier`, `WithRuntimeMaxSteps`, `DesignateNode` | `CallOption.checkpointId`, `.writeToCheckpointId`, `.forceNewRun`, `.stateModifier`, `.runtimeMaxSteps`, `option.designateNode` |
| `NewChain`, `AppendChatModel`, `AppendChatTemplate`, `AppendLambda`, …, `NewChainBranch`, `NewChainMultiBranch`, `NewStreamChainBranch`, `NewStreamChainMultiBranch`, `NewParallel` | `Chain<I, O>()`, `appendChatModel`, `appendChatTemplate`, `appendLambda`, …, `ChainBranch.single`, `.multi`, `.stream`, `.streamMulti`, `Parallel()` |
| `NewWorkflow`, `AddInput`, `AddDependency`, `SetStaticValue`, `End` | `Workflow<I, O>()`, `addInput`, `addDependency`, `setStaticValue`, `end()` |
| `FromField`, `ToField`, `MapFields`, `FromFieldPath`, `ToFieldPath`, `MapFieldPaths` | `FieldMapping.fromField`, `.toField`, `.mapFields`, `.fromFieldPath`, `.toFieldPath`, `.mapFieldPaths` |
| `NewToolNode(ToolsNodeConfig)`, `ToolMiddleware`, `GetToolCallID` | `ToolsNode(ToolsNodeConfig(tools:, toolAliases:, unknownToolsHandler:, executeSequentially:, toolArgumentsHandler:, toolCallMiddlewares:))`, `ToolMiddleware`, `toolCallIdOf(ctx)` |
| `ToolInput`, `ToolOutput`, `StreamToolOutput`, `EnhancedInvokableToolOutput`, `EnhancedStreamableToolOutput` | `ToolCallInput`, `ToolCallOutput`, `StreamToolCallOutput`, `EnhancedToolCallOutput`, `EnhancedStreamToolCallOutput` (`ToolOutput` is the Kortney runtime's tool result, a different type) |
| `RegisterValuesMergeFunc` | `ValuesMerge.register` |
| `Interrupt`, `StatefulInterrupt`, `CompositeInterrupt`, `ExtractInterruptInfo`, `InterruptInfo` | `interrupt`, `statefulInterrupt`, `compositeInterrupt`, `extractInterruptInfo`, `GraphInterruptInfo` (thrown as `GraphInterruptedException`) |
| `GetInterruptState[T]`, `GetResumeContext[T]`, `InterruptCtx`, `IsInterruptRerunError` | `getInterruptState<T>`, `getResumeContext<T>`, `InterruptCtx`, `isInterrupt` |
| `Resume`, `ResumeWithData`, `BatchResumeWithData` | `ctx.resume(ids)`, `ctx.resumeWithData(id, data)`, `ctx.batchResumeWithData(map)` |
| `WithGraphInterrupt` | `ctx.withGraphInterrupt()` → `(RunContext, GraphInterrupter)` |
| `CheckPointStore`, `Serializer` | `CheckpointStore`, `CheckpointSerializer`, `InMemoryCheckpointStore`, `FileCheckpointStore` (`io.dart`) |
| `ErrExceedMaxSteps`, `ErrGraphCompiled`, `ErrChainCompiled` | `ExceedMaxStepsException`, `GraphCompiledException`, `ChainCompiledException` |
| `GraphInfo`, `GraphCompileCallback` | `GraphInfo` (also `toMermaid()`), `GraphCompileCallback` |
| `NewAgenticToolsNode` (beta) | `AgenticToolsNode` |

### `callbacks`, `utils/callbacks` → `callbacks.dart`

| Eino (Go) | Dart |
|---|---|
| `callbacks.Handler` | `ComponentCallbackHandler` (`CallbackHandler` is the older API) |
| `NewHandlerBuilder` | `CallbackHandlerBuilder` |
| `utils/callbacks.NewHandlerHelper` | `HandlerHelper` |
| `RunInfo`, `CallbackTiming`, `TimingChecker` | same names |
| `AppendGlobalHandlers` | `GlobalCallbacks.append` |
| Run-scoped handlers (`compose.WithCallbacks`, `adk.WithCallbacks`) | `RunContext.withHandlers`, `CallOption.callbacks`, `AgentRunOption.callbacks` |
| `OnStart`, `OnEnd`, `OnError`, `OnStartWithStreamInput`, `OnEndWithStreamOutput` | same names in lower camel case, from `callbacks.dart` only (the umbrella hides them) |
| `EnsureRunInfo`, `InitCallbacks`, `ReuseHandlers` | `ensureRunInfo`, `initCallbacks`, `reuseHandlers` |

### `adk` → `adk.dart`

| Eino (Go) | Dart |
|---|---|
| `Agent`, `ResumableAgent`, `AgentInput`, `AgentEvent`, `AgentOutput`, `MessageVariant`, `AgentAction` | same names (in `adk.dart` only) |
| `GetMessage(event)`, `EventFromMessage` | `getMessageFromEvent(event)`, `AgentEvent.fromMessage` |
| `NewChatModelAgent(ChatModelAgentConfig)`, `ToolsConfig` | `ChatModelAgent(ChatModelAgentConfig(…))`, `ToolsConfig(toolsNode: ToolsNodeConfig(…))` |
| `NewRunner(RunnerConfig)`, `Run`, `Query`, `Resume`, `ResumeWithParams` | `Runner(agent:, enableStreaming:, checkpointStore:)`, `run`, `query`, `resume`, `resumeWithParams` |
| `WithSessionValues`, `WithCallbacks`, `WithCheckPointID`, `WithChatModelOptions`, `WithToolOptions` | `AgentRunOption.sessionValues`, `.callbacks`, `.checkpointId`, `.chatModelOptions`, `.toolOptions` |
| `GetSessionValue`, `GetSessionValues`, `AddSessionValue`, `AddSessionValues`, `SetRunLocalValue`, `GetRunLocalValue`, `DeleteRunLocalValue`, `SendEvent` | `ctx.sessionValue`, `ctx.sessionValues`, `ctx.addSessionValue`, `ctx.addSessionValues`, `ctx.setRunLocalValue`, `ctx.runLocalValue`, `ctx.deleteRunLocalValue`, `ctx.sendEvent` |
| `WithAfterToolCallsHook` | `AgentRunOption.afterToolCallsHook` |
| `InterruptInfo`, `ResumeInfo`, `ResumeParams` | `AgentInterruptInfo`, `ResumeInfo`, `ResumeParams` |
| `Interrupt`, `StatefulInterrupt`, `CompositeInterrupt` (events) | `interruptEvent`, `statefulInterruptEvent`, `compositeInterruptEvent` |
| `ChatModelAgentMiddleware`, `BaseChatModelAgentMiddleware` | `ChatModelAgentMiddleware` (`ChatModelAgentConfig.handlers`) |
| `ChatModelAgentState`, `ChatModelAgentContext`, `ModelContext`, `ToolContext` | same names (in `adk.dart` only) |
| `AgentCallbackInput`, `AgentCallbackOutput`, `ConvAgentCallbackInput`/`Output` | same names, `AgentCallbackInput.from`; `typedAgentCallbackHandler(onStart:, onEnd:)` |
| `ModelRetryConfig`, `RetryContext`, `RetryDecision`, `WillRetryError`, `RetryExhaustedError`, `ModelFailoverConfig`, `FailoverContext`, `ErrExceedMaxIterations` | `ModelRetryConfig`, `RetryContext`, `RetryDecision`, `WillRetryException`, `RetryExhaustedException`, `ModelFailoverConfig`, `FailoverContext`, `ExceedMaxIterationsException` |
| `WithCancel`, `CancelError`, `ErrStreamCanceled`, `StreamCanceledError` | `withCancel`, `AgentRunCancelledException`, `StreamCanceledException` (`compose.dart`, re-exported by `adk.dart`) |
| `NewAgentTool(agent, WithFullChatHistoryAsInput, WithAgentInputSchema)` | `AgentTool(agent, fullChatHistoryAsInput:, inputSchema:)` |
| `SendToolGenAction`, `GetMessageID`, `EnsureMessageID`, `SetLanguage` | `sendToolGenAction`, `messageIdOf`, `ensureMessageId`, `setAdkLanguage` |
| `NewTurnLoop(TurnLoopConfig)`, TurnLoop `InterruptError` | `TurnLoop(TurnLoopConfig(…))`, `TurnLoopInterruptedException` |
| `filesystem.Backend`, `Shell`, `StreamingShell` | `FilesystemBackend`, `Shell`, `StreamingShell`; `InMemoryBackend` |
| `prebuilt/deep.New` | `DeepAgent.create(ctx, DeepAgentConfig(…))` |
| `prebuilt/planexecute.New`, `NewPlanner`, `NewExecutor`, `NewReplanner` | `PlanExecute.create`, `PlanExecute.planner`, `.executor`, `.replanner` (`PlanExecuteLoopConfig`, `PlannerConfig`, `ExecutorConfig`, `ReplannerConfig`, `Plan`) |
| `middlewares/{patchtoolcalls, summarization, agentsmd, reduction, filesystem, skill, plantask, dynamictool/toolsearch}` | `PatchToolCallsMiddleware`, `SummarizationMiddleware`, `AgentsMdMiddleware`, `ToolReductionMiddleware`, `FilesystemMiddleware`, `SkillMiddleware`, `PlanTaskMiddleware`, `ToolSearchMiddleware` |
| Agentic `TypedChatModelAgent`, `TypedRunner` (beta) | `AgenticChatModelAgent`, `AgenticRunner` |
| eino-examples `adk/common/tool`: `InvokableApprovableTool`, `InvokableReviewEditTool`, `FollowUp`, `graphtool` | `ApprovableTool`, `ReviewEditTool`, `FollowUpTool`, `GraphTool` |

### `flow` → `flow.dart`

| Eino (Go) | Dart |
|---|---|
| `retriever/multiquery.NewRetriever` | `MultiQueryRetriever.fromConfig` |
| `retriever/parent.NewRetriever` | `ParentRetriever.fromConfig` |
| `retriever/router.NewRetriever` | `RouterRetriever.fromConfig` |
| `retriever/utils.ConcurrentRetrieveWithCallback` | `concurrentRetrieve` |
| `indexer/parent.NewIndexer` | `ParentIndexer` |

### eino-ext

| eino-ext | Dart | Library |
|---|---|---|
| `model/openai`, `model/openrouter`, `model/claude`, `model/gemini`, `model/ollama` | `OpenAIChatModel`, `OpenRouterChatModel`, `ClaudeChatModel`, `GeminiChatModel`, `OllamaChatModel` | umbrella |
| `model/deepseek`, `model/qwen`, `model/ark` | `OpenAICompatibleChatModel` with `OpenAICompatibleConfig.deepSeek`, `.qwen`, `.ark` | umbrella |
| `model/agenticopenai` (Responses API), `model/agenticclaude` (beta) | `OpenAIResponsesModel`, `ClaudeAgenticModel` | umbrella |
| `embedding/openai`, `embedding/dashscope`, `embedding/gemini`, `embedding/ollama` | `OpenAIEmbedder` (`OpenAIEmbedder.dashScope`), `GeminiEmbedder`, `OllamaEmbedder` | umbrella |
| `embedding/cache` | `CachingEmbedder`, `EmbeddingCache`; `FileEmbeddingCache` | `components.dart`; `io.dart` |
| `indexer/qdrant`, `retriever/qdrant` | `QdrantIndexer.create`, `QdrantRetriever` | `components.dart` |
| `document/loader/file`, `document/loader/url` | `FileLoader`; `UrlLoader.fromConfig` | `io.dart`; `components.dart` |
| `document/parser/html`, `pdf`, `docx`, `xlsx` | `HtmlParser.fromConfig`, `PdfParser`, `DocxParser`, `XlsxParser` | `components.dart` |
| `document/transformer/splitter/{recursive, markdown, html, semantic}`, `reranker/score` | `RecursiveCharacterTextSplitter.fromConfig`, `MarkdownSplitter.fromHeaderConfig`, `HtmlSplitter.fromHeaderConfig`, `SemanticSplitter`, `ScoreReorderTransformer` | `components.dart` |
| `tool/mcp`, `prompt/mcp` | `McpClient`, `McpToolkit`, `McpPromptTemplate`; `StreamableHttpTransport`, `SseTransport`; `StdioTransport` | `components.dart`; `io.dart` |
| `tool/httprequest`, `googlesearch`, `wikipedia`, `duckduckgo/v2`, `searxng`, `sequentialthinking` | `HttpRequestToolkit`, `GoogleSearchTool`, `WikipediaTool`, `DuckDuckGoSearchTool`, `SearxngSearchTool`, `SequentialThinkingTool` | `components.dart` |
| `tool/commandline` | `PyExecutorTool`, `StrReplaceEditorTool`; `LocalOperator` | `components.dart`; `io.dart` |
| `adk/backend/local` | `LocalFilesystemBackend`, `LocalShell` | `io.dart` |
| `callbacks/langfuse/v2`, `callbacks/langsmith` | `LangfuseHandler`, `LangSmithHandler` | `callbacks.dart` |

### Not ported

- **Deprecated upstream**: `model.ChatModel.BindTools` (use `withTools`),
  `Message.MultiContent`, `InterruptAndRerun`, `RegisterSerializableType`,
  `Workflow.AddEnd`, the struct-based `adk.AgentMiddleware`, and the other
  members Eino marks `Deprecated`.
- **Not recommended upstream**: agent transfer (sub-agents,
  `TransferToAgentAction`, `ExitTool`, run paths, `OutputKey`), the workflow
  agents (sequential, parallel, loop) and the supervisor. **Superseded by
  the ADK** in Eino's guides (not marked in the code): `flow/agent/react`
  and the multi-agent host. Use `ChatModelAgent` with `AgentTool`s, or
  `DeepAgent`; for a hand-built ReAct graph see
  [`example/graph_react_example.dart`](packages/threepio_core/example/graph_react_example.dart).
- **Not possible or not useful in Dart**: Go templates, `gob`, reflection
  (`InferTool` takes explicit parameters), services that need gRPC, raw TCP
  or vendor request signing, or that no consumer needs (Milvus, Redis,
  Elasticsearch, OpenSearch, VikingDB, Claude and Gemini through Bedrock or
  Vertex, …), the Docker sandbox, browser-use, CozeLoop, the devops server.
- **Deferred** (agentic path, beta): agentic retry, failover and turn loop;
  the agentic Gemini model and the agentic chat-completions adapters.

Every difference in behaviour between the Go and the Dart port is listed in
the [CHANGELOG](packages/threepio_core/CHANGELOG.md) ("Differences from Eino …").

## Examples

Run them with `dart run example/<file>.dart`. Most examples that need a model
read `OPENROUTER_API_KEY` (model `OPENROUTER_MODEL`) or `OPENAI_API_KEY`
(model `OPENAI_MODEL`, endpoint `OPENAI_BASE_URL`); the provider examples and
the older ones read their own keys, see
[example/README.md](packages/threepio_core/example/README.md).

| Example | Shows |
|---|---|
| [`graph_react_example.dart`](packages/threepio_core/example/graph_react_example.dart) | A ReAct agent built by hand from a `Graph` with state, a tools node and a branch |
| [`workflow_example.dart`](packages/threepio_core/example/workflow_example.dart) | A `Workflow` with field mapping and fan-in |
| [`hitl_approval_example.dart`](packages/threepio_core/example/hitl_approval_example.dart) | Interrupt and resume written by hand in a tool, with a checkpoint store |
| [`deep_agent_example.dart`](packages/threepio_core/example/deep_agent_example.dart) | `DeepAgent`: todos, filesystem tools, a sub-agent |
| [`turn_loop_example.dart`](packages/threepio_core/example/turn_loop_example.dart) | `TurnLoop`: pushed inputs become agent turns |
| [`mcp_tools_example.dart`](packages/threepio_core/example/mcp_tools_example.dart) | Tools from an MCP server (stdio or streamable HTTP) given to an agent |
| [`agentic_agent_example.dart`](packages/threepio_core/example/agentic_agent_example.dart) | The agentic path (beta): `OpenAIResponsesModel` and `AgenticChatModelAgent` |
| [`eino_examples/`](packages/threepio_core/example/eino_examples/) | Ports of eino-examples: `quickstart/chat`, `quickstart/todoagent`, `compose/graph/state`, `adk/human-in-the-loop/1_approval` |
| [`basic_chat_example.dart`](packages/threepio_core/example/basic_chat_example.dart), [`openrouter_example.dart`](packages/threepio_core/example/openrouter_example.dart), [`gemini_example.dart`](packages/threepio_core/example/gemini_example.dart) | Calling chat model providers directly |
| [`advanced_rag_example.dart`](packages/threepio_core/example/advanced_rag_example.dart) | Retrieval with threepio's own components: splitting, vector and hybrid retrieval, MMR reranking, multi-query, rank fusion |
| [`adk_agents_example.dart`](packages/threepio_core/example/adk_agents_example.dart), [`checkpoint_example.dart`](packages/threepio_core/example/checkpoint_example.dart) | The older APIs: the Kortney runtime, legacy agents, `StateGraph` checkpoints and human input |

## Documentation

| Document | Covers |
|---|---|
| [doc/GRAPHS.md](packages/threepio_core/doc/GRAPHS.md) | Chains, graphs, workflows, lambdas, state, call options, streaming, interrupt and checkpoints; the legacy `StateGraph` |
| [doc/CALLBACKS.md](packages/threepio_core/doc/CALLBACKS.md) | Callback handlers, global handlers, firing callbacks from a component, tracing; the legacy callback API |
| [doc/RAG.md](packages/threepio_core/doc/RAG.md) | Embedders, indexers, retrievers, loaders, parsers, splitters, the flow retrievers, a RAG graph |
| [doc/LANGFUSE_DESIGN.md](packages/threepio_core/doc/LANGFUSE_DESIGN.md) | How the Langfuse (and LangSmith) tracing is built |
| [doc/MIGRATION.md](packages/threepio_core/doc/MIGRATION.md) | Moving to 0.9: libraries, renamed and colliding names, intentional breaks, legacy → Eino-shaped API |
| [doc/NEW_FEATURES.md](packages/threepio_core/doc/NEW_FEATURES.md) | Features added before the Eino port (Gemini, older agents, `StateGraph` checkpoints, retrieval, splitters) |
| [CHANGELOG.md](packages/threepio_core/CHANGELOG.md) | Every change, with the differences from Eino per area |

The API reference is in the dartdoc comments; each public type names the Go
symbol it ports (`/// Port of eino compose.Interrupt.`).

## Legacy API (before 0.9)

These APIs predate the Eino port. They stay exported and get no new
features; two apps depend on them. Apart from the intentional breaks listed
in [doc/MIGRATION.md](packages/threepio_core/doc/MIGRATION.md#intentional-breaks) (the Kortney
`RunContext` is now `AgentRunScope`; the five `StateGraph` checkpoint classes
and `LegacyRunnable` come from `legacy_graph.dart`; `ToolRegistry.register`
takes effect at once) and bug fixes, their names, signatures and behaviour
are unchanged. Some are annotated `@Deprecated`, which only produces analyzer
infos.

| Legacy | What it is | Use instead |
|---|---|---|
| `Runner`, `ChatModelAgent`, `ChatModelAgentConfig`, sealed `AgentEvent`/`AgentAction`, `RunHandle`, `ContextualTool`, `ToolOutput` (umbrella) | The Kortney runtime: an app-facing agent runtime with in-process approval, now a facade over `adk.dart` | `adk.ChatModelAgent`, `adk.Runner`, `adk.ApprovableTool` |
| `StateGraph`, `GraphBuilder`, `GraphState`, `START`/`END`, `GraphPatterns` (umbrella); its checkpoint stores (`legacy_graph.dart`) | The original state-machine graph | `Graph` with `LocalState`, compose checkpoints |
| `LegacyRunnable`, `LegacyLambda` (`legacy_graph.dart`) | The `Stream`-based runnable `StateGraph.toRunnable()` returns | `Runnable`, `Lambda` |
| `BaseChain`, `LLMChain`, `RetrievalQAChain`, … (`legacy_chains.dart`) | LangChain-style chains over `Map<String, dynamic>` | `Chain<I, O>` |
| `CallbackHandler`, `BaseCallbackHandler`, `CallbackManager`, `LoggingHandler`, `MetricsHandler`, `TracingHandler` | The first callback API | `ComponentCallbackHandler`, `RunContext.withHandlers`; `LegacyCallbackHandlerAdapter` runs an old handler under the new API |
| `Agent`, `AgentConfig`, `ToolRegistry`, `ToolExecutor` | The first ReAct loop and its tool registry | `adk.ChatModelAgent` |
| `LegacyChatModelAgent`, `WorkflowAgent`, `PlanExecuteAgent`, `SupervisorAgent`, `BaseAgent`, the umbrella's `AgentTool` | Agents of the first ADK attempt | `adk.ChatModelAgent`, `adk.PlanExecute`, `adk.DeepAgent`, `adk.AgentTool`; for `WorkflowAgent`, a compose `Graph` or `Workflow` whose nodes run agents (Eino does not recommend its workflow agents) |
| `ConversationBufferMemory` and the other memories; the output parsers | threepio-only modules without an Eino counterpart | kept as they are; `MessageJsonParser` and `Lambda` cover parsing in a chain |
| The constructors of `MultiQueryRetriever`, `ParentRetriever`, `RouterRetriever`; the older loaders, splitters and parsers | The first RAG components (still working; they implement the Eino contracts where one exists) | the Eino-shaped entry points (`MultiQueryRetriever.fromConfig`, `RecursiveCharacterTextSplitter.fromConfig`, `FileLoader`, …), see [doc/RAG.md](packages/threepio_core/doc/RAG.md) |

[doc/MIGRATION.md](packages/threepio_core/doc/MIGRATION.md) shows each move with before/after code.

## Development

```bash
cd packages/threepio_core
dart analyze --fatal-warnings lib
tool/test_shards.sh test/adk test/callbacks test/components test/compose test/core test/flow test/graph test/schema test/streaming test/unit test/minimal_stream_test.dart
```

Run tests through `tool/test_shards.sh` (or `tool/test_file_audit.sh` for
single files): both cap memory and time per process. A bare `dart test` over
the whole package is never needed. Tests tagged `integration` call live APIs;
they are skipped unless `THREEPIO_INTEGRATION=1` and the provider's key are
set, for example:

```bash
THREEPIO_INTEGRATION=1 OPENROUTER_API_KEY=… tool/run_capped.sh 300 4096 \
  dart test -j 1 --tags integration test/integration/openrouter_agentic_smoke_test.dart
```

Every ` ```dart ` block of this README and of `doc/` is mirrored in a file the
analyzer checks (`test/doc_snippets/`, `example/`);
`test/unit/docs/doc_snippets_test.dart` fails when a block has no mirror.

## Versioning

0.9.x follows Eino v0.9. Breaking changes are listed in the
[CHANGELOG](packages/threepio_core/CHANGELOG.md) with migration notes; the names that collide
between the two API generations stay as they are until 1.0.

## License and acknowledgments

MIT, see [LICENSE](packages/threepio_core/LICENSE). Threepio ports
[Eino](https://github.com/cloudwego/eino) and
[eino-ext](https://github.com/cloudwego/eino-ext) by CloudWeGo, both under
the Apache License 2.0; Go doc comments and tests were translated with their
behaviour. Some older modules (memory, output parsers, chains) were inspired
by [LangChain](https://github.com/langchain-ai/langchain).
