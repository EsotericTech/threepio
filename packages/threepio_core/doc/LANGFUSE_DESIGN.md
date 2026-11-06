# Langfuse tracing: the design as built

`LangfuseHandler` records what the components of a run do as a trace in
[Langfuse](https://langfuse.com). It is a port of eino-ext
`callbacks/langfuse/v2`: a callback handler that turns every component into an
OpenTelemetry span and sends the finished spans with OTLP over HTTP, in the
JSON encoding, to Langfuse's OTLP endpoint (`/api/public/otel/v1/traces`).

This document describes the code in `lib/src/observability/` as it is. The
pre-implementation design this file used to hold (a client for Langfuse's
ingestion REST API, with cost tracking) was built first and then replaced; it
is summarised under [The legacy REST client](#the-legacy-rest-client).

> **Status: not yet verified against a live Langfuse project.** The spans are
> sent as OTLP/JSON, which Langfuse documents as supported ("Langfuse supports
> OTLP over HTTP/protobuf and HTTP/JSON", eino-ext's v2 README), but no export
> has been checked against a real project. The opt-in test
> `test/integration/langfuse_integration_test.dart` is that check (coordinator
> decision 1 after P3, decision 4 after P12); see
> [Verifying against Langfuse](#verifying-against-langfuse).

## Contents

- [Architecture](#architecture)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Traces](#traces)
- [What becomes an observation](#what-becomes-an-observation)
- [Size limits, masking and sampling](#size-limits-masking-and-sampling)
- [Batching and export](#batching-and-export)
- [Flush and shutdown](#flush-and-shutdown)
- [Error handling](#error-handling)
- [Other exporters and collectors](#other-exporters-and-collectors)
- [Differences from eino-ext](#differences-from-eino-ext)
- [Verifying against Langfuse](#verifying-against-langfuse)
- [The legacy REST client](#the-legacy-rest-client)
- [LangSmith](#langsmith)

## Architecture

```text
 components of a run                     lib/src/callbacks/
 (chat models, tools, retrievers,        callback chain of the RunContext
  templates, graphs, agents, ...)  --->  (ctx.withHandlers, GlobalCallbacks,
                                          CallOption.callbacks)
                                                 |
                                                 | onStart / onEnd / onError
                                                 | and the stream variants
                                                 v
 lib/src/observability/langfuse/  LangfuseHandler (ComponentCallbackHandler)
                                  - one open span per running component,
                                    kept in the RunContext (parent links)
                                  - attributes: langfuse.observation.*,
                                    langfuse.trace.*, gen_ai.usage.*
                                  - reads streamed inputs and outputs in the
                                    background
                                                 |
                                                 | add(OtlpSpan), when a span ends
                                                 v
 lib/src/observability/otlp/      SpanExporter
                                  OtlpHttpTraceExporter
                                  - SpanQueue (bounded, drops when full)
                                  - batches by size or after batchTimeout
                                  - one request at a time, retry with back-off
                                                 |
                                                 | POST application/json
                                                 | Authorization: Basic base64(pk:sk)
                                                 | x-langfuse-ingestion-version: 4
                                                 v
                                  <host>/api/public/otel/v1/traces
```

There is no OpenTelemetry SDK in Dart that this could sit on, so the pieces an
SDK provides are part of the package:

| File | What it is |
|---|---|
| `observability/langfuse/langfuse_handler.dart` | `LangfuseHandler`, `LangfuseConfig`, `LangfuseObservationType` |
| `observability/langfuse/langfuse_values.dart`, `langfuse_agentic_values.dart` | Internal: payloads as JSON, masking, truncation that keeps JSON valid |
| `observability/otlp/otlp_json.dart` | `OtlpSpan`, `OtlpSpanEvent`, `OtlpStatus`, the JSON encoding (`encodeOtlpTraces`), ids (`newTraceId`, `newSpanId`), `isTraceSampled` |
| `observability/otlp/span_queue.dart` | `SpanQueue`: bounded first-in-first-out queue of finished spans |
| `observability/otlp/otlp_http_trace_exporter.dart` | `SpanExporter`, `OtlpHttpTraceExporter`, `OtlpExporterConfig`, `OtlpRetryConfig`, `OtlpExportException` |

All of them except the two internal ones are exported by
`package:threepio_core/callbacks.dart` (and the umbrella library).

## Quick start

```dart
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';

final langfuse = LangfuseHandler(
  LangfuseConfig(
    host: 'https://cloud.langfuse.com',
    publicKey: publicKey,
    secretKey: secretKey,
    environment: 'staging',
    release: '1.4.0',
  ),
);
GlobalCallbacks.append([langfuse]); // or ctx.withHandlers([langfuse]) per run

final ctx = langfuse.startTrace(
  RunContext.background(),
  name: 'answer-question',
  userId: 'user-123',
  sessionId: 'conversation-456',
  input: question,
  tags: ['rag'],
);
final answer = await rag.invoke(ctx, question);
langfuse.endTrace(ctx, answer.content);

await langfuse.shutdown(); // before the application exits
```

`rag` is any `Runnable` (here the RAG graph of [RAG.md](RAG.md)); a component
called directly works the same when it gets `ctx` (`ChatModelOptions(runContext:
ctx)`, `RetrieverOptions(runContext: ctx)`). The constructor throws an
`ArgumentError` when the sample rate is not between 0 and 1 and, without an
`exporter`, when the host is not a URL or a key is missing.

## Configuration

`LangfuseConfig` is the port of eino-ext's `langfuse.Config`.

| Field | Default | Go | Meaning |
|---|---|---|---|
| `host` | (required without `exporter`) | `Host` | Base URL (`https://cloud.langfuse.com`), a URL ending in `/api/public/otel`, or the full `/api/public/otel/v1/traces` endpoint |
| `publicKey`, `secretKey` | (required without `exporter`) | `PublicKey`, `SecretKey` | Project keys, sent as HTTP Basic credentials |
| `serviceName` | `threepio-langfuse` | `ServiceName` | The resource's `service.name` |
| `environment`, `release`, `version`, `tags` | none | same | Defaults for every trace; `startTrace` overrides them (tags are added) |
| `name`, `userId`, `sessionId`, `public` | none, `false` | same | Defaults for every trace |
| `timeout` | 10 s | `Timeout` | One request to Langfuse |
| `retry` | `OtlpRetryConfig()` | `RetryConfig` | When a request is tried again |
| `sampleRate` | 1 | `SampleRate` | Share of traces exported, each whole or not at all; `0` exports everything, as in Go (leave the handler out to trace nothing) |
| `collapseAgentInternalSpans` | `false` | `CollapseAgentInternalSpans` | Leave out an agent's own machinery (see below) |
| `maxQueueSize` | 2048 | `MaxQueueSize` | Finished spans waiting to be sent |
| `maxExportBatchSize` | 512 (or `maxQueueSize` if less) | `MaxExportBatchSize` | Spans per request |
| `batchTimeout` | 5 s | `BatchTimeout` | Longest wait of a finished span |
| `maxAttributeValueLength` | 1,000,000 | `MaxAttributeValueLength` | UTF-16 code units per input, output or metadata value; negative: no limit |
| `maxSpanAttributeLength` | 4,000,000 | `MaxSpanAttributeBytes` | UTF-16 code units of everything the handler writes to one span; negative: no limit |
| `mask` | none | `MaskFunc` | Applied to every input, output, metadata value and error message |

The constructor also takes `httpClient` (used for the requests, closed by the
caller), `exporter` (replaces the transport; see
[Other exporters and collectors](#other-exporters-and-collectors)), and
`random` and `clock` for tests.

```dart
final config = LangfuseConfig(
  host: 'https://langfuse.internal.example.com',
  publicKey: publicKey,
  secretKey: secretKey,
  sampleRate: 0.25, // a quarter of the traces
  collapseAgentInternalSpans: true,
  maxAttributeValueLength: 20000,
  batchTimeout: const Duration(seconds: 2),
  retry: const OtlpRetryConfig(maxElapsedTime: Duration(seconds: 30)),
  mask: (value) => value.replaceAll(RegExp(r'\b\d{16}\b'), '[card number]'),
);
```

## Traces

`startTrace(ctx, …)` opens the root observation of a trace and returns the
context to run the components with; `endTrace(ctx, [output])` closes it. The
root is of `observationType` (`span` by default) and called `name`
(`threepio-trace` when neither the call nor the configuration names it).
`input` is shown as its input; `id` makes the trace use a given trace id (32
hexadecimal digits).

* The root ends only after the components of the trace that are still
  running have ended. Its output is, in this order: what `endTrace` was
  given, the reason the context was cancelled, the output of the outermost
  agent, the output of the component that ended last.
* The root also ends when the cancel token of the context given to
  `startTrace` is cancelled, and at `shutdown`.
* The trace attributes (`langfuse.trace.name`, `langfuse.user.id`,
  `langfuse.session.id`, `langfuse.release`, `langfuse.environment`,
  `langfuse.version`, `langfuse.trace.tags`, `langfuse.trace.public`,
  `langfuse.trace.metadata.<key>`) are written on the root and repeated on
  every observation of the trace, which is how Langfuse finds the user,
  session and tags of an observation.
* A component that runs with a context that has no trace starts a trace of
  its own, with itself as the root.

## What becomes an observation

Every component that starts becomes one observation (a span), a child of the
observation of the component it runs in. Its name is the component's name
(`NodeOptions.name` in a graph, the graph's `graphName`), else its
implementation and kind (`OpenAIChatModel`, `VectorRetriever`,
`DefaultChatTemplate`). Every observation records the component kind and
implementation as `langfuse.observation.metadata.eino_component` and
`eino_type`.

| Component (`ComponentType`) | Observation type | What is recorded |
|---|---|---|
| Chat model (`chatModel`) | `generation` | Input messages (a streamed input's chunks joined), output message (a stream's chunks joined leniently, so a stream whose chunks do not quite agree is still shown), `langfuse.observation.model.name`, `model.parameters` (`max_tokens`, `stop`, `temperature`, `top_p`), the payload's `extra` as metadata, token usage, and `completion_start_time` (first chunk) for a stream |
| Agentic model (`agenticModel`, beta) | `generation` | The same, with the `AgenticMessage`s written by `AgenticMessage.toJson` and the chunks joined with `concatAgenticMessages` (strictly: chunks that cannot be joined fail the observation, as in eino-ext) |
| Agent (`agent`), agentic agent (`agenticAgent`, beta) | `agent` | Output: the messages and custom outputs of its events (one value as it is, several as a list); retry notifications of its model (`WillRetryException`s) as `eino_retry_event_count` and `eino_retry_events` metadata; the input of a classic agent is written as `Instance of 'AgentCallbackInput'` (known gap; agentic agents' input is written in full) |
| Tool (`tool`) | `tool` | Arguments and result |
| Retriever (`retriever`) | `retriever` | Query, `topK`, filter and score threshold; the documents |
| Embedder (`embedder`) | `embedding` | Texts and model; the number of vectors and their dimensions (not the vectors) and the token usage |
| Chat template (`promptTemplate`, `agenticChatTemplate`) | `chain` | Variables; the messages (the templates are not written) |
| Everything else (graph, chain, workflow, lambda, tools node, loader, indexer, transformer) | `span` | Input and output as JSON |

Token usage is written with OpenTelemetry's GenAI attribute names:
`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`,
`gen_ai.usage.cache_read.input_tokens` and
`gen_ai.usage.reasoning.output_tokens` (cached and reasoning tokens are part
of the input and output counts). The usage comes from the callback payload,
else from the message's `responseMeta`. threepio sends no cost figures.

Inputs and outputs are written as JSON: messages, documents and tool infos
with their `toJson`, the typed callback payloads (`RetrieverCallbackInput`,
`IndexerCallbackOutput`, …) as objects of their fields, any other value with
its own `toJson` when it has one and as its `toString()` otherwise.

For the RAG graph of [RAG.md](RAG.md), run under `startTrace`, the tree is:

```text
answer-question              span        root (startTrace)
└── rag                      span        the graph (graphName)
    ├── VectorRetriever      retriever   query -> documents
    │   └── OpenAIEmbedding  embedding   the query's vector, with token usage
    ├── Lambda               span        documents -> context text
    ├── Lambda               span        question
    ├── DefaultChatTemplate  chain       variables -> messages
    └── OpenAIChatModel      generation  messages -> answer, model, usage
```

**Agents.** An agent deals with the failures of what it calls: a tool or
model that fails inside an agent marks its own observation as failed but not
the root of the trace; only a failure outside any agent, or of the outermost
agent, does. With `collapseAgentInternalSpans`, the spans an agent creates for
its own machinery are left out: the chain of the same name beneath the agent,
its `ReAct` graph, its `Init` lambda and lambdas without a name. The models,
tools and agents it calls then appear directly beneath it.

## Size limits, masking and sampling

* **Values.** An input, output or metadata value longer than
  `maxAttributeValueLength` is cut so that the JSON stays valid. Everything
  the handler writes to one span shares a budget of `maxSpanAttributeLength`;
  what does not fit is cut or left out. Lengths are UTF-16 code units.
* **Masking.** `mask` sees every input, output, metadata value and error
  message (status message and `exception.message`) before it is written. A
  value the function throws on is left out.
* **Sampling.** Decided per trace id (the `TraceIdRatioBased` rule on 52 bits
  of the id), so a trace is exported whole or not at all.

## Batching and export

`SpanExporter` is the seam between the handler and the transport: `add(span)`
takes a finished span and returns at once (`false` when it is discarded),
`flush()` sends what has been taken, `shutdown()` sends what is left and
releases the exporter. None of them throws.

`OtlpHttpTraceExporter` is the implementation for OTLP over HTTP with JSON
bodies, the counterpart of an OpenTelemetry SDK's batch span processor and
OTLP/HTTP exporter:

```text
add(span) ──> SpanQueue (maxQueueSize; full: span dropped, counted)
                 │
                 │ maxExportBatchSize spans waiting  -> send now
                 │ oldest has waited batchTimeout    -> send what is queued
                 v
           export loop (one request at a time, started in a microtask)
                 │  POST <endpoint>, Content-Type: application/json
                 v
           2xx ─────────────> done (partialSuccess.rejectedSpans counted)
           429/502/503/504,
           timeout, transport ─> wait (back-off, or a longer Retry-After)
                                 and retry until the waits would pass
                                 maxElapsedTime; then the batch is dropped
           other status ────> batch dropped, logged at SEVERE
```

`OtlpRetryConfig` defaults are those of the OpenTelemetry exporters: first
wait 5 s, growing by 1.5 up to 30 s, at most 1 minute of waiting per batch;
`OtlpRetryConfig.none` sends once. A `Retry-After` header is honoured when it
asks for a longer wait than the back-off (so `Retry-After: 0` cannot spin). An
idle exporter holds no timer, so it does not keep a Dart process alive.
Spans with an invalid trace or span id are refused in `add` instead of costing
their whole batch a 400.

## Flush and shutdown

| Call | What it does |
|---|---|
| `flush({timeout})` | Waits for the streams the handler is still reading, then has the exporter send everything queued. With a `timeout`, neither the streams nor an unresponsive Langfuse are waited for longer than that, each. |
| `shutdown({timeout})` | Waits for the streams, closes the traces still open, reports losses, then shuts down the exporter it created (which sends what is left and closes the HTTP client it created). With a `timeout`, streams still open are abandoned and delivery is given up after the same time again. What ends afterwards is not exported (`spans_after_shutdown`). |

An exporter passed to the handler is flushed by `shutdown`, not shut down: the
caller owns it. Call `shutdown` before the application exits; spans still
queued are lost otherwise.

## Error handling

Tracing never fails or delays the run it observes:

* **Hooks.** Whatever goes wrong while the handler writes a span is logged
  (`threepio.observability.langfuse`, `WARNING`) and the observation still
  ends with what was written; the callback chain also logs and swallows a hook
  that throws (coordinator decision 3 after P3).
* **Export.** `add` only queues. A batch that cannot be delivered after the
  retries is dropped and logged; nothing reaches the caller.
* **Losses** are counted, not thrown: `LangfuseHandler.losses` by reason
  (`value_limit_truncations`, `span_attribute_budget_drops_or_truncations`,
  `metadata_serialization_failures`, `payload_serialization_failures`,
  `mask_failures`, `sampled_out_spans`, `exporter_refused_spans`,
  `spans_after_shutdown`) and `OtlpHttpTraceExporter.discarded`
  (`queue_full_spans`, `sampled_out_spans`, `mask_failed_spans`,
  `invalid_spans`, `exporter_stopped_spans`, `export_failed_spans`,
  `rejected_spans`). They are reported in one warning at `flush` and
  `shutdown` (and by the exporter after each export round), not by a periodic
  timer.

A component's own failure is recorded on its observation: status `ERROR`,
`langfuse.observation.level` `ERROR`, the message as
`langfuse.observation.status_message` and an `exception` event. A cancellation
is recorded as `eino_callback_cancelled` with its cause and an interrupt as
`eino_callback_interrupted`; neither marks the observation as failed.

## Other exporters and collectors

The `exporter` parameter replaces the transport; the host and keys of the
configuration are then not used. Any `SpanExporter` works: one that keeps the
spans in memory (tests, a debug screen), or an `OtlpHttpTraceExporter` pointed
at another OTLP/HTTP collector that accepts JSON.

```dart
/// Keeps the spans in memory, for a test or a debug screen.
final class MemorySpanExporter implements SpanExporter {
  final spans = <OtlpSpan>[];

  @override
  bool add(OtlpSpan span) {
    spans.add(span);
    return true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}
```

```dart
final memory = MemorySpanExporter();
final inMemory = LangfuseHandler(const LangfuseConfig(), exporter: memory);

final collector = OtlpHttpTraceExporter(
  OtlpExporterConfig(
    endpoint: Uri.parse('http://localhost:4318/v1/traces'),
    serviceName: 'my-app',
  ),
);
final toCollector = LangfuseHandler(const LangfuseConfig(), exporter: collector);
// ... run ...
await toCollector.shutdown(); // flushes the collector exporter
await collector.shutdown(); // the caller shuts it down
```

## Differences from eino-ext

From the progress log (P3 deviation 8, P6, P13) and the CHANGELOG:

* No OpenTelemetry SDK: spans are plain records, ids come from
  `Random.secure()`, and the batch processor is `OtlpHttpTraceExporter`
  (JSON only, no gzip). Go sends protobuf, gzipped; if Langfuse refused JSON,
  a protobuf encoder behind `encodeOtlpTraces` would change neither API.
* Limits are UTF-16 code units, not bytes (`maxSpanAttributeLength` instead of
  `MaxSpanAttributeBytes`); `0` means zero for the limits (Go: the default).
* Sampling is decided per trace id in the handler.
* `startTrace`'s options are named parameters; `flush` and `shutdown` take a
  `timeout` instead of a context.
* Losses are reported at `flush`/`shutdown`, not by a timer every minute;
  `losses` and `discarded` have the counts.
* The output of a streamed generation is joined leniently.
* The mask also sees the span's status message and the `exception` event's
  message (Go masks the `status_message` attribute but writes those two
  unmasked); a value the mask throws on is left out.
* `onEnd` waits for a streamed input that is still being read before it ends
  the span (Go ends it at once and can lose the input).
* After `shutdown` nothing is exported, also not to an exporter the caller
  owns.
* Agentic models are recorded with their input, output and usage; eino-ext
  reads them with the classic converters and writes `null` and no usage.
* Inputs and outputs are written with threepio's JSON form of messages
  (camelCase fields), not Go's (coordinator decision 3 after P12).
* Not ported: `ExportDiagnostics`, `IncludeProcessResourceAttributes`, a
  caller-owned `TracerProvider` (the `exporter` parameter is the seam),
  `DropLogInterval`.

## Verifying against Langfuse

The check is opt-in and needs a Langfuse project's keys; `LANGFUSE_HOST`
defaults to `https://cloud.langfuse.com`:

```bash
THREEPIO_INTEGRATION=1 LANGFUSE_PUBLIC_KEY=pk-lf-... LANGFUSE_SECRET_KEY=sk-lf-... \
  dart test -j 1 --tags integration test/integration/langfuse_integration_test.dart
```

It sends a trace with a model generation and passes when the export is
accepted: no span lost and nothing logged at `WARNING` or above on
`threepio.observability`. Look for the trace `threepio-integration-<time>` in
the project to see how it is shown. Whether Langfuse reads the
`gen_ai.usage.*` integers, which OTLP/JSON sends as strings, as numbers is
part of that check. Until the test has been run, the handler's documentation
and the CHANGELOG call it unverified.

Without keys, the behaviour is covered offline by
`test/unit/observability/langfuse_handler_test.dart` and the agent and
agentic tests next to it (`langfuse_agent_test.dart`,
`langfuse_agentic_*_test.dart`), `otlp_http_trace_exporter_test.dart`,
`span_queue_test.dart`, `otlp_json_test.dart` and `langfuse_values_test.dart`,
with `MockClient` and `fake_async`.

## The legacy REST client

Before the OTLP handler, threepio had a client for Langfuse's ingestion API
(`POST /api/public/ingestion`, batches of trace, span, generation and event
records), which Langfuse has since deprecated in favour of OpenTelemetry. It
is still in `lib/src/observability/langfuse/`, marked `@Deprecated`, exported
by no public library, and gets no new features:

| Class (`lib/src/observability/langfuse/`) | What it was | Replaced by |
|---|---|---|
| `LangfuseClient` (`langfuse_client.dart`) | Created traces, spans, generations and events and queued them | `LangfuseHandler`, which creates them from callbacks |
| `LangfuseConfig` (`langfuse_config.dart`) | Host, keys, flush settings of the client | `LangfuseConfig` of `langfuse_handler.dart` (same name, different class; the two are never imported together) |
| `LangfuseHttpClient` (`langfuse_http_client.dart`), `LangfuseApiException`, `LangfuseApiMultiStatusException` | `POST /api/public/ingestion` with Basic authentication | `OtlpHttpTraceExporter`, `OtlpExportException` |
| `LangfuseEventQueue` (`langfuse_queue.dart`), `LangfuseConsumer` (`langfuse_consumer.dart`), `LangfuseQueueFullException` | Event queue and the background batch sender | `SpanQueue` and the export loop of `OtlpHttpTraceExporter` |
| `LangfuseTrace`, `LangfuseSpan`, `LangfuseGeneration`, `LangfuseEvent`, `LangfuseUsage`, `LangfuseIngestionEvent` and the batch types (`models/`) | Ingestion API records | `OtlpSpan` with `langfuse.*` and `gen_ai.usage.*` attributes |

The cost tracking the old design planned (a pricing table and a cost
calculator) was not built; token usage is sent, and costs are left to
Langfuse. Code that used the client imported it from `src/`; move it to
`LangfuseHandler`, which needs no calls besides `startTrace`, `endTrace` and
`shutdown`.

## LangSmith

`LangSmithHandler` (port of eino-ext `callbacks/langsmith`, in
`callbacks.dart`) records the same callbacks in
[LangSmith](https://smith.langchain.com) as a tree of runs: `POST /runs` when a
component starts, `PATCH /runs/{id}` when it ends; a chat model is an `llm`
run, a tool a `tool` run, everything else a `chain` run. `LangSmithTrace.set`
names the project, tags and metadata of the runs of a context;
`LangSmithFlowTrace` opens and closes runs by hand and carries a trace
position across processes (`spanToString`, `stringToSpan`).

```dart
final langSmith = LangSmithHandler(LangSmithConfig(apiKey: langSmithKey));
final traced = LangSmithTrace.set(
  RunContext.background().withHandlers([langSmith]),
  sessionName: 'support-bot',
  tags: ['rag'],
  metadata: {
    'metadata': {'tenant': 'acme'},
  },
);
final reply = await rag.invoke(traced, question);
print(reply.content);
await langSmith.shutdown(); // sends what is queued, closes its HTTP client
```

How it differs from Go: requests are queued and sent in the background, in
order (a child's creation after its parent's), never blocking or failing the
run; a failed request is logged and counted (`failedRequests`), not retried;
the queue holds `maxQueueSize` (2048) requests and drops the rest
(`droppedRequests`). Dotted orders carry the real microseconds of the start
time, so sibling runs that start within the same second sort correctly (Go
writes a literal `000000`; coordinator decision 2 after P12). Payloads are
written with threepio's camelCase JSON form of messages (decision 3 after
P12). Like the Langfuse handler, it has not been verified against a live
project; `test/integration/langsmith_integration_test.dart` is that check
(`THREEPIO_INTEGRATION=1` and a key). [CALLBACKS.md](CALLBACKS.md) covers
callback handlers in general.
