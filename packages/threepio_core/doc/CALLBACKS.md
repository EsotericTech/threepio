# Callbacks and tracing

Callbacks let code outside a component watch it run: a handler hears when a
chat model, a tool, a retriever, a graph node or an agent starts, ends or
fails, and sees its input and output. Logging, metrics and tracing (Langfuse,
LangSmith, OpenTelemetry) are built on them.

`package:threepio_core/callbacks.dart` is the port of Eino's `callbacks` and
`utils/callbacks` packages, and of the Langfuse and LangSmith handlers of
eino-ext. The umbrella library `package:threepio_core/threepio_core.dart`
exports all of it except the functions a component fires its callbacks with
(see [Firing callbacks from your own component](#firing-callbacks-from-your-own-component)).

## Contents

- [Concepts](#concepts)
- [Writing a handler](#writing-a-handler)
- [Using handlers](#using-handlers)
- [A hook that throws](#a-hook-that-throws)
- [Firing callbacks from your own component](#firing-callbacks-from-your-own-component)
- [Tracing](#tracing)
- [Differences from Eino](#differences-from-eino)
- [Legacy API (before 0.9)](#legacy-api-before-09)

## Concepts

**Run info.** Every callback says which component it is about with a
`RunInfo` (Go `callbacks.RunInfo`):

| Field | Meaning | Example |
|---|---|---|
| `name` | the name of this use of the component: the node name in a graph, the agent's name | `'summarize'` |
| `type` | the implementation (`TypedComponent.componentTypeName`) | `'OpenRouter'` |
| `componentType` | the kind of component, a `ComponentType` | `ComponentType.chatModel` |

`ComponentType.einoName` is Eino's name for each kind (`chatModel` is
`'ChatModel'`, `promptTemplate` is `'ChatTemplate'`, `embedder` is
`'Embedding'`, `custom` is `'Unknown'`). Besides the component kinds
(`chatModel`, `promptTemplate`, `tool`, `retriever`, `embedder`, `indexer`,
`loader`, `documentTransformer`, `agent`) there are the compose kinds
(`graph`, `chain`, `workflow`, `lambda`, `toolsNode`) and the agentic ones
(beta). A handler that gets `RunInfo.unknown` (empty name and type, kind
`custom`) was called by a component that did not say what it is.

**Timings.** A component calls its handlers at five moments
(`CallbackTiming`, Go `callbacks.CallbackTiming`):

| Hook | When | Payload |
|---|---|---|
| `onStart` | before the component runs | its input |
| `onEnd` | after it returned | its output |
| `onError` | after it failed | the error and stack trace |
| `onStartWithStreamInput` | before it runs on a stream | a copy of the input stream |
| `onEndWithStreamOutput` | after it returned a stream | a copy of the output stream |

**Payloads.** A component that fires its own callbacks reports a typed
payload (`ModelCallbackInput`, `ToolCallbackOutput`, `RetrieverCallbackInput`,
…); a graph that fires them around a node reports the node's plain input and
output. The `from` function of each payload type accepts both:
`ModelCallbackInput.from(input)` is the payload whether `input` was a
`ModelCallbackInput` or a `List<Message>`. `HandlerHelper` does that for you.

## Writing a handler

### Extend ComponentCallbackHandler

`ComponentCallbackHandler` (Go `callbacks.Handler`) has the five hooks; the
ones you do not override do nothing. Every hook returns a `RunContext`: what
`onStart` returns is the context the component runs with and the one its
`onEnd` or `onError` gets, so a value stored there is how a handler recognises
a call again.

```dart
import 'package:logging/logging.dart';
import 'package:threepio_core/callbacks.dart';

final log = Logger('app.callbacks');

/// Logs how long every component takes.
final class Stopwatches extends ComponentCallbackHandler
    implements TimingChecker {
  static const _started = ContextKey<DateTime>('stopwatches.started');

  // Only the start and end callbacks: no stream copies are made for it.
  @override
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing) =>
      timing == CallbackTiming.onStart || timing == CallbackTiming.onEnd;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) =>
      ctx.withValue(_started, DateTime.now());

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    final started = ctx.value(_started);
    if (started != null) {
      final took = DateTime.now().difference(started);
      log.info('${info.componentType.einoName} ${info.name}: $took');
    }
    return ctx;
  }
}
```

A component that returns a stream reports `onEndWithStreamOutput` instead of
`onEnd`, so this handler does not time streamed calls.

Implementing `TimingChecker` (Go `callbacks.TimingChecker`) is optional: a
handler that does is asked before each callback and left out when it answers
`false`. That matters most for streams, because every handler that is called
for a stream gets a copy of it of its own.

### Handlers from functions

`CallbackHandlerBuilder` (Go `callbacks.HandlerBuilder`) builds a handler from
the hooks you set; it asks only for the callbacks it has a function for:

```dart
// Go: callbacks.NewHandlerBuilder().OnStartFn(...).OnErrorFn(...).Build().
final handler = CallbackHandlerBuilder()
    .onStart((ctx, info, input) {
      log.info('${info.name} starts');
      return ctx;
    })
    .onError((ctx, info, error, stackTrace) {
      log.warning('${info.name} failed', error, stackTrace);
      return ctx;
    })
    .build();
```

### Typed payloads: HandlerHelper

`HandlerHelper` (Go `utils/callbacks.HandlerHelper`) puts one handler
together from handlers per kind of component, each with the payload types of
its kind. A payload of another type reaches the hook as `null`.

```dart
// Go: utils/callbacks.NewHandlerHelper().ChatModel(...).Tool(...).Handler().
final handler = HandlerHelper()
    .chatModel(
      ModelCallbackHandler(
        onEnd: (ctx, info, output) {
          log.info('tokens: ${output?.tokenUsage?.totalTokens}');
          return ctx;
        },
        // A streamed answer. Read it in the background and return; the
        // stream is this handler's own copy and is closed by asStream.
        onEndWithStreamOutput: (ctx, info, chunks) {
          unawaited(
            chunks.asStream().fold<int>(0, (count, _) => count + 1).then(
                  (count) => log.info('${info.name}: $count chunks'),
                  onError: (Object error) => log.warning('$error'),
                ),
          );
          return ctx;
        },
      ),
    )
    .tool(
      ToolCallbackHandler(
        onStart: (ctx, info, input) {
          log.info('${info.name}(${input?.argumentsJson})');
          return ctx;
        },
      ),
    )
    .retriever(
      RetrieverCallbackHandler(
        onEnd: (ctx, info, output) {
          log.info('${output?.docs.length} documents');
          return ctx;
        },
      ),
    )
    // Graphs, chains and lambdas have no payload type of their own.
    .graph(
      CallbackHandlerBuilder().onEnd((ctx, info, output) {
        log.info('graph ${info.name} done');
        return ctx;
      }).build(),
    )
    .handler();
```

| `HandlerHelper` method | Handler | Payloads |
|---|---|---|
| `prompt` | `PromptCallbackHandler` | `PromptCallbackInput`, `PromptCallbackOutput` |
| `chatModel` | `ModelCallbackHandler` | `ModelCallbackInput`, `ModelCallbackOutput` (stream hook) |
| `embedding` | `EmbeddingCallbackHandler` | `EmbeddingCallbackInput`, `EmbeddingCallbackOutput` |
| `indexer` | `IndexerCallbackHandler` | `IndexerCallbackInput`, `IndexerCallbackOutput` |
| `retriever` | `RetrieverCallbackHandler` | `RetrieverCallbackInput`, `RetrieverCallbackOutput` |
| `loader` | `LoaderCallbackHandler` | `LoaderCallbackInput`, `LoaderCallbackOutput` |
| `transformer` | `TransformerCallbackHandler` | `TransformerCallbackInput`, `TransformerCallbackOutput` |
| `tool` | `ToolCallbackHandler` | `ToolCallbackInput`, `ToolCallbackOutput` (stream hook) |
| `toolsNode` | `ToolsNodeCallbackHandlers` | `Message` in, `List<Message?>` out (stream hook) |
| `agent` | `AgentCallbackHandler` (see below) | `AgentCallbackInput`, `AgentCallbackOutput` |
| `graph`, `chain`, `lambda` | any `ComponentCallbackHandler` | plain values (no `workflow` method, as in Eino) |

`agenticPrompt`, `agenticModel`, `agenticToolsNode` and `agenticAgent` are the
agentic counterparts (beta).

### Agents

An agent (from `package:threepio_core/adk.dart`) reports an
`AgentCallbackInput` when it starts (`input` for a new run, `resumeInfo` when
it resumes) and an `AgentCallbackOutput` when it ends, which holds the stream
of its events. `typedAgentCallbackHandler` (Go
`utils/callbacks.AgentCallbackHandler`) hands those to its functions typed:

```dart
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:threepio_core/adk.dart';

final log = Logger('app.agents');

/// Logs every agent run and the errors among its events.
ComponentCallbackHandler agentLogger() {
  final agents = typedAgentCallbackHandler(
    onStart: (ctx, info, input) {
      log.info('${info.name} starts with ${input?.input?.messages.length} '
          'messages (resumed: ${input?.resumeInfo != null})');
      return ctx;
    },
    onEnd: (ctx, info, output) {
      final events = output?.events;
      // The events arrive while the agent runs: read them in the background.
      if (events != null) unawaited(_logErrors(info.name, events));
      return ctx;
    },
  );
  return HandlerHelper().agent(agents).handler();
}

Future<void> _logErrors(String agent, StreamReader<AgentEvent> events) async {
  try {
    for (var event = await events.nextOrNull();
        event != null;
        event = await events.nextOrNull()) {
      if (event.error != null) log.warning('$agent: ${event.error}');
    }
  } finally {
    await events.close();
  }
}
```

Every handler gets an event stream of its own, and the agent does not wait for
it: start reading in `onEnd` and return. `AgentCallbackHandler` itself is the
low-level form: its functions get the payloads as `Object?`, as reported.

### Streams in hooks

The stream hooks get a copy of the stream that belongs to the handler alone,
and **the handler has to close it**, also when it does not read it (the
default implementations close it unread; `asStream()` closes it when it ends).
Read it in the background and return at once: a hook that waits for the end
of the stream holds the component's caller up until the stream is over.

## Using handlers

### For one run

A `RunContext` carries the handlers of the run it belongs to; every component
called with it reports to them:

```dart
// Every component called with this context reports to the handler.
final ctx = RunContext.background().withHandlers([handler]);

// A component called on its own gets the context through its options.
await model.generate(
  [Message.user('Hello')],
  options: ChatModelOptions(runContext: ctx),
);

// A compiled graph takes it as the context of the run...
await runnable.invoke(ctx, 'Hello');

// ...or takes handlers as a call option, which can be aimed at a node.
await runnable.invoke(
  RunContext.background(),
  'Hello',
  options: [
    CallOption.callbacks([handler]).designateNode(['model']),
  ],
);
```

`withHandlers` keeps the handlers the context already has. Inside a graph,
each node reports to the handlers of the run with a `RunInfo` of its own:
`NodeOptions.name` as its name (empty when not given), its implementation as
its type, and its kind; the graph itself reports under
`GraphCompileOptions.graphName`. `ctx.runInfo`, `ctx.hasCallbacks` and
`ctx.callbackHandlers` read what a context carries.

### For every run: GlobalCallbacks

```dart
// Go: callbacks.AppendGlobalHandlers. Once, when the application starts.
GlobalCallbacks.append([tracing]);

// Global state: take it out again where that matters (tests).
GlobalCallbacks.remove(tracing);
```

A global handler hears every component of every run, whatever handlers the run
was given: every agent, model and tool event, as Eino's global handlers do. A
chat model provider that is called without a run context still reports to the
global handlers. A run takes the list as it is when its callbacks are set up;
handlers added later are seen by runs that start after that.

**Order.** When a component starts, the handlers are called last to first,
the global ones before those of the run; when it ends or fails, first to last,
the global ones at the end. Each hook gets the context the one before it
returned.

## A hook that throws

A hook that throws does not fail the component: the error is logged (logger
`threepio.callbacks`, level `WARNING`) and the run goes on with the context the
hook was given; a stream copy the hook did not get to close is closed for it.
This is a deliberate difference from Go, where a handler's panic propagates:
an observer must not be able to break a run. In tests, an `expect` inside a
hook therefore proves nothing by itself; listen to the logger to make a
logged warning fail the test.

## Firing callbacks from your own component

A component that reports its own calls, with typed payloads, implements
`CallbackAwareComponent` (`isCallbacksEnabled == true`, Go
`components.Checker`) so that a graph does not report them a second time, and
`TypedComponent` (Go `components.Typer`) to name its implementation. It calls
`ensureRunInfo` (Go `callbacks.EnsureRunInfo`) and then the firing functions:

```dart
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

/// A retriever that reports its own calls, with typed payloads.
final class KeywordRetriever
    implements Retriever, TypedComponent, CallbackAwareComponent {
  KeywordRetriever(this.documents);

  final List<Document> documents;

  /// Shown as `KeywordRetriever` in traces. Go: components.Typer.
  @override
  String get componentTypeName => 'Keyword';

  /// A graph leaves the callbacks of this node to it. Go: components.Checker.
  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Keeps the run info of the graph node it runs as, if any.
    var ctx = callbacks.ensureRunInfo(
      options?.runContext ?? RunContext.background(),
      componentTypeName,
      ComponentType.retriever,
    );
    ctx = await callbacks.onStart(ctx, RetrieverCallbackInput(query: query));
    try {
      final found = [
        for (final document in documents)
          if (document.content.contains(query)) document,
      ];
      await callbacks.onEnd(ctx, RetrieverCallbackOutput(docs: found));
      return found;
    } catch (error, stackTrace) {
      await callbacks.onError(ctx, error, stackTrace);
      rethrow;
    }
  }
}
```

`onStart`, `onEnd`, `onError`, `onStartWithStreamInput` and
`onEndWithStreamOutput` (and `onEndWithCopies`) are exported from
`package:threepio_core/callbacks.dart` only, not from the umbrella library. In
Dart an imported top-level function takes precedence over an inherited
member, so a class that inherits a member called `onStart`, `onEnd` or
`onError` (every handler does) and calls it without `this.` would call the
imported function instead. Import `callbacks.dart`, with a prefix as above
when the names could collide.

* `ensureRunInfo(ctx, type, kind)` keeps the run info of the graph node the
  component runs as; called directly, the component gets a run info with an
  empty name, and the global handlers when the context had none.
* `onStart` uses that run info up: a component run inside has to report itself
  before its own start.
* `onEnd` and `onError` take the context `onStart` returned. The error itself
  still has to be rethrown.
* The stream functions hand the stream over and return the one to read on:

```dart
// The stream is handed over: every interested handler gets a copy, and
// the caller reads the returned reader instead of `output`.
final (_, forCaller) = await callbacks.onEndWithStreamOutput<String>(
  ctx,
  output,
);
return forCaller;
```

`initCallbacks`, `reuseHandlers` and `appendHandlers` (Go `InitCallbacks`,
`ReuseHandlers` and the internal `AppendHandlers`) set up the callbacks of a
context for code that runs components itself. On a context without handlers
the firing functions do nothing and cost nothing.

## Tracing

### Langfuse

`LangfuseHandler` (port of eino-ext `callbacks/langfuse/v2`) sends a run to
[Langfuse](https://langfuse.com) as a trace: a chat model becomes a
*generation* with its model, parameters and token usage, an agent an *agent*,
a tool a *tool*, a retriever a *retriever*, an embedder an *embedding*, a chat
template a *chain*, anything else a *span*, each beneath the component it ran
in.

```dart
final langfuse = LangfuseHandler(
  LangfuseConfig(
    host: 'https://cloud.langfuse.com',
    publicKey: publicKey, // 'pk-lf-...'
    secretKey: secretKey, // 'sk-lf-...'
  ),
);
GlobalCallbacks.append([langfuse]);

// One trace per request; the components of the run appear beneath it.
final ctx = langfuse.startTrace(
  RunContext.background(),
  name: 'answer-question',
  userId: 'user-123',
  sessionId: 'conversation-456',
  input: question,
);
final answer = await runnable.invoke(ctx, question);
langfuse.endTrace(ctx, answer.content);

await langfuse.shutdown(); // before the application exits
```

Without an `exporter`, the constructor throws an `ArgumentError` when the
host is not a URL or a key is empty. The spans go over OpenTelemetry's
protocol (OTLP/HTTP, JSON) to `/api/public/otel/v1/traces`; exporting runs in the background and never fails
the run (losses are counted in `losses` and logged). `LangfuseConfig` also
sets the environment, release, tags, sampling, masking (`mask`) and limits.
The handler has not been verified against a live Langfuse project yet; see
[LANGFUSE_DESIGN.md](LANGFUSE_DESIGN.md) for the design and what differs from
Go.

### LangSmith

`LangSmithHandler` (port of eino-ext `callbacks/langsmith`) records a run in
[LangSmith](https://smith.langchain.com) as a tree of runs: a chat model is an
`llm` run, a tool a `tool` run, anything else a `chain` run. `LangSmithTrace.set`
names the project, the tags and the metadata of the runs of a context:

```dart
final langSmith = LangSmithHandler(
  LangSmithConfig(apiKey: apiKey), // 'lsv2_...'
);

// The project, tags and metadata of the runs of this context.
final ctx = LangSmithTrace.set(
  RunContext.background().withHandlers([langSmith]),
  sessionName: 'support-bot',
  tags: ['production'],
);
final answer = await runnable.invoke(ctx, question);

await langSmith.shutdown(); // sends what is queued, closes the client
```

The hooks only queue requests, which are sent one at a time in the background
(Go sends each request inside the callback); `flush` waits for them. Failed
requests are logged and counted (`failedRequests`), not retried; requests
beyond `LangSmithConfig.maxQueueSize` are dropped (`droppedRequests`).
`LangSmithFlowTrace` opens and closes spans by hand, to join several runs, or
processes (`spanToString`/`stringToSpan`), into one trace:

```dart
// Several runs (or processes) in one trace.
final flow = LangSmithFlowTrace(config);
final (ctx, spanId) = await flow.startSpan(
  LangSmithTrace.set(RunContext.background(), sessionName: 'support-bot'),
  'conversation',
);
try {
  await runnable.invoke(ctx, 'first question');
  await runnable.invoke(ctx, 'second question');
} finally {
  await flow.finishSpan(ctx, spanId);
}
```

### OpenTelemetry

`OtlpHttpTraceExporter` sends `OtlpSpan`s to any OpenTelemetry collector that
accepts OTLP/HTTP with JSON (gRPC and protobuf are not supported). It batches,
retries 429/502/503/504 with back-off, masks attributes when asked, and never
fails the work it observes.

```dart
// Spans over OTLP/HTTP (JSON) to any collector.
final exporter = OtlpHttpTraceExporter(
  OtlpExporterConfig(
    endpoint: Uri.parse('http://localhost:4318/v1/traces'),
    serviceName: 'my-app',
  ),
);

// The Langfuse handler can send its spans there instead of to Langfuse;
// its shutdown then flushes the exporter and leaves closing it to you.
final handler = LangfuseHandler(const LangfuseConfig(), exporter: exporter);
```

### Logging, metrics and tracing handlers

`LoggingHandler`, `MetricsHandler` and `TracingHandler` are handlers of the
older API (see below); in a run of the new kind, wrap them in
`LegacyCallbackHandlerAdapter`. They write to `package:logging` (loggers
`threepio.callbacks.logging`, `.metrics`, `.tracing`, level `INFO`), not to the
console:

```dart
// LoggingHandler, MetricsHandler.printSummary and TracingHandler.printTrace
// write to package:logging (threepio.callbacks.*), not to the console.
Logger.root.level = Level.INFO;
Logger.root.onRecord.listen((record) => stdout.writeln(record.message));
```

## Differences from Eino

* **A hook that throws is logged and swallowed** (Go: the panic propagates).
* **Hooks always get a `RunInfo`**: where Go passes `nil` they get
  `RunInfo.unknown`.
* **The firing functions are not in the umbrella library**: import
  `callbacks.dart`.
* **Typed agent payloads** come from `typedAgentCallbackHandler`; the raw
  `AgentCallbackHandler` passes them as `Object?`.
* **Global handlers** also hear a provider call that has no run context; in Go
  every call has a context.
* **Langfuse**: no OpenTelemetry SDK (spans are plain records sent by
  `OtlpHttpTraceExporter`, JSON only), limits are in UTF-16 code units, the
  trace options are named parameters of `startTrace`, and `flush`/`shutdown`
  take a `timeout` instead of a context. **LangSmith**: requests are queued
  instead of sent inside the hook.

## Legacy API (before 0.9)

The older callback API passes a `Map<String, dynamic>` from hook to hook and
wraps payloads in `CallbackInput`/`CallbackOutput`. `CallbackHandler`,
`BaseCallbackHandler` and `CallbackManager` are deprecated and keep working:
`StateGraph`, the older chains, and the model providers, `OpenAIEmbedder`,
`VectorRetriever` and `InMemoryVectorStore` when given a `callbackManager`
still fire them.
`ComponentCallbackHandler`, `RunContext.withHandlers` and `GlobalCallbacks`
replace them.

```dart
/// A handler of the older API: a map for context, wrapped payloads.
class StartLogger extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    log.info('${info.name} <- ${input.data}');
    return {...context, 'started': DateTime.now()};
  }
}
```

```dart
final manager = CallbackManager([StartLogger(), LoggingHandler()]);
final summary = await manager.runWithCallbacks(
  <String, dynamic>{},
  const RunInfo(
    name: 'summarize',
    type: 'Summarizer',
    componentType: ComponentType.custom,
  ),
  text,
  () async => text.substring(0, text.length.clamp(0, 80)),
);
```

`CallbackManager.addGlobalHandler` registers a handler for every manager.
`runStreamWithCallbacks` also fires a final `onEnd` when the stream is over.

**`LegacyCallbackHandlerAdapter`** runs such a handler in a run of the new
kind:

```dart
// An existing handler in a run of the new kind.
final ctx = RunContext.background().withHandlers([
  LegacyCallbackHandlerAdapter(StartLogger()),
  LegacyCallbackHandlerAdapter(MetricsHandler()),
]);
```

The map travels inside the `RunContext`: every hook gets a copy of the map of
its context, and what it returns becomes the map of the context that follows,
so the end hook of a component sees what its start hook left, and all adapted
handlers of a run share it. What a component inside adds does not reach the
component around it or one next to it. A typed payload arrives unwrapped (the
messages of a `ModelCallbackInput`, …), with the payload itself in
`metadata['payload']`. Stream hooks get a Dart `Stream` of the handler's copy;
listen before the hook returns, or the copy is closed. There is no extra
`onEnd` at the end of a stream.

**Migrating a handler** from `BaseCallbackHandler` to
`ComponentCallbackHandler`: take `RunContext ctx` where the hook took the
`Map<String, dynamic> context`, keep what the handler remembers in the context
under a private `ContextKey` and return the context; take the payload as
`Object?` where it was a `CallbackInput` or `CallbackOutput`. Where a component
reports a typed payload (a model's `ModelCallbackInput` where the older API had
its list of messages), read it with the payload's `from`
(`ModelCallbackInput.from(input)`) or use `HandlerHelper`. Give a run its handlers with
`RunContext.background().withHandlers([...])` instead of
`CallbackManager([...])`, and register global ones with
`GlobalCallbacks.append` instead of `CallbackManager.addGlobalHandler`. The
handler above becomes:

```dart
/// The same handler on the new API.
final class StartLoggerV2 extends ComponentCallbackHandler {
  static const _started = ContextKey<DateTime>('start_logger.started');

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    log.info('${info.name} <- $input');
    return ctx.withValue(_started, DateTime.now());
  }
}
```
