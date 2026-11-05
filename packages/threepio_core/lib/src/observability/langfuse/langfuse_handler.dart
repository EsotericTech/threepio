/// Traces the components of a run in Langfuse.
///
/// Port of eino-ext `callbacks/langfuse/v2`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../adk/eino/agent_callbacks.dart';
import '../../adk/eino/agent_event.dart';
import '../../adk/eino/model_retry.dart';
import '../../callbacks/callback_timing.dart';
import '../../callbacks/component_callback_handler.dart';
import '../../callbacks/run_info.dart';
import '../../components/model/cancel_token.dart';
import '../../components/model/model_callbacks.dart';
import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/message_concat.dart';
import '../../streaming/stream_reader.dart';
import '../otlp/otlp_http_trace_exporter.dart';
import '../otlp/otlp_json.dart';
import 'langfuse_values.dart';

final _log = Logger('threepio.observability.langfuse');

/// What kind of step an observation is, which decides how Langfuse shows it.
///
/// Port of eino-ext `langfuse.ObservationType`. The name of a value is the
/// string Langfuse knows it by.
enum LangfuseObservationType {
  /// A point in time.
  event,

  /// A piece of work without a more specific kind. The default.
  span,

  /// A call of a model, with its parameters and token usage.
  generation,

  /// A run of an agent.
  agent,

  /// A call of a tool.
  tool,

  /// A step that links others together, such as a prompt template.
  chain,

  /// A retrieval of documents.
  retriever,

  /// An evaluation.
  evaluator,

  /// A call of an embedding model.
  embedding,

  /// A check of input or output.
  guardrail,
}

/// The settings of a [LangfuseHandler].
///
/// Port of eino-ext `langfuse.Config`.
@immutable
final class LangfuseConfig {
  /// Creates the settings. [host], [publicKey] and [secretKey] are needed
  /// unless the handler is given an exporter of its own.
  const LangfuseConfig({
    this.host = '',
    this.publicKey = '',
    this.secretKey = '',
    this.serviceName = 'threepio-langfuse',
    this.environment,
    this.release,
    this.version,
    this.tags = const [],
    this.timeout = const Duration(seconds: 10),
    this.sampleRate = 1,
    this.retry = const OtlpRetryConfig(),
    this.name,
    this.userId,
    this.sessionId,
    this.public = false,
    this.collapseAgentInternalSpans = false,
    this.maxQueueSize = 2048,
    this.maxExportBatchSize,
    this.batchTimeout = const Duration(seconds: 5),
    this.maxAttributeValueLength = 1000000,
    this.maxSpanAttributeLength = 4000000,
    this.mask,
  });

  /// Where Langfuse is: its base URL (`https://cloud.langfuse.com`), a URL
  /// that ends in `/api/public/otel`, or the full trace endpoint
  /// `/api/public/otel/v1/traces`.
  final String host;

  /// The public key of the Langfuse project.
  final String publicKey;

  /// The secret key of the Langfuse project.
  final String secretKey;

  /// The `service.name` the spans are reported under.
  final String serviceName;

  /// The environment of every trace (`production`, `staging`, ...), unless
  /// `startTrace` names another one.
  final String? environment;

  /// The release of the application, for every trace.
  final String? release;

  /// The version of what is traced, for every trace.
  final String? version;

  /// Tags of every trace. `startTrace` adds to them.
  final List<String> tags;

  /// How long one request to Langfuse may take.
  final Duration timeout;

  /// The share of traces that is exported, from `0.0` to `1.0`. A trace is
  /// exported whole or not at all. `0` and `1` both export everything.
  final double sampleRate;

  /// When a request Langfuse did not take is tried again.
  final OtlpRetryConfig retry;

  /// The name of every trace, unless `startTrace` names it.
  final String? name;

  /// The user of every trace, unless `startTrace` names one.
  final String? userId;

  /// The session of every trace, unless `startTrace` names one.
  final String? sessionId;

  /// Whether traces are public (readable through their link).
  final bool public;

  /// Whether the spans an agent creates for its own machinery are left out:
  /// the chain of the same name beneath an agent, its `ReAct` graph, its
  /// `Init` lambda and lambdas without a name of their own. What the agent
  /// calls (models, tools, other agents) is then shown directly beneath it.
  /// Components outside an agent, and lambdas with a name, always get their
  /// span.
  final bool collapseAgentInternalSpans;

  /// How many finished spans may wait to be sent.
  final int maxQueueSize;

  /// The most spans sent in one request. Defaults to 512, or to
  /// [maxQueueSize] if that is less.
  final int? maxExportBatchSize;

  /// How long a finished span waits at most before it is sent.
  final Duration batchTimeout;

  /// The most UTF-16 code units one input, output or metadata value may
  /// have. A longer value is cut in a way that keeps JSON valid. Negative
  /// means no limit.
  final int maxAttributeValueLength;

  /// The most UTF-16 code units the names and values this handler writes to
  /// one span may have together. Negative means no limit.
  final int maxSpanAttributeLength;

  /// Applied to every input, output, metadata value and error message before
  /// it is exported. Use it to take out secrets and personal data. A value
  /// the function throws on is not exported at all.
  final String Function(String value)? mask;

  /// The trace endpoint for [host]. Port of `traceEndpoint`.
  ///
  /// Throws [ArgumentError] when [host] is empty or not an absolute URL.
  static Uri traceEndpoint(String host) {
    var trimmed = host.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty) {
      throw ArgumentError.value(host, 'host', 'the Langfuse host is required');
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw ArgumentError.value(host, 'host', 'not a valid Langfuse host');
    }
    final path = parsed.path;
    if (path.endsWith('/api/public/otel/v1/traces')) return parsed;
    if (path.endsWith('/api/public/otel')) {
      return parsed.replace(path: '$path/v1/traces');
    }
    return parsed.replace(path: '$path/api/public/otel/v1/traces');
  }
}

/// A callback handler that sends what the components of a run do to
/// [Langfuse](https://langfuse.com) as a trace.
///
/// Port of eino-ext `callbacks/langfuse/v2` (`langfuse.CallbackHandler`).
/// Every component becomes one observation: a chat model a *generation* with
/// its model, parameters and token usage, an agent an *agent*, a tool a
/// *tool*, a retriever a *retriever*, an embedder an *embedding*, a chat
/// template a *chain*, everything else a *span*. A component that runs
/// inside another is shown beneath it.
///
/// The observations are sent with OpenTelemetry's protocol over HTTP to
/// `/api/public/otel/v1/traces`, one finished span per observation. The
/// ingestion API Langfuse has deprecated (`/api/public/ingestion`) is not
/// used.
///
/// ```dart
/// final langfuse = LangfuseHandler(
///   const LangfuseConfig(
///     host: 'https://cloud.langfuse.com',
///     publicKey: 'pk-lf-...',
///     secretKey: 'sk-lf-...',
///   ),
/// );
/// GlobalCallbacks.append([langfuse]);
///
/// final ctx = langfuse.startTrace(
///   RunContext.background(),
///   name: 'answer-question',
///   userId: 'user-123',
///   sessionId: 'conversation-456',
///   input: question,
/// );
/// final answer = await model.generate(
///   messages,
///   options: ChatModelOptions(runContext: ctx),
/// );
/// langfuse.endTrace(ctx, answer.content);
///
/// await langfuse.shutdown(); // before the application exits
/// ```
///
/// **Traces.** [startTrace] opens the root observation of a trace and returns
/// the context to run the components with; [endTrace] closes it, after the
/// components that are still running have finished. Components that run with
/// a context that has no trace each start a trace of their own.
///
/// **Nothing here fails the run.** Exporting happens in the background and
/// what cannot be exported is dropped, counted in [losses] and reported on
/// the logger `threepio.observability.langfuse`.
///
/// **Privacy.** Inputs, outputs and error messages are exported in full
/// unless [LangfuseConfig.mask] takes something out.
final class LangfuseHandler extends ComponentCallbackHandler
    implements TimingChecker {
  /// Creates a handler that exports to the Langfuse project of [config].
  ///
  /// [httpClient] is used for the requests when given (the caller closes
  /// it). [exporter] replaces the transport altogether: the spans go there
  /// and the host and keys of [config] are not used; [shutdown] flushes such
  /// an exporter and leaves shutting it down to the caller. [random] makes
  /// the trace and span ids and [clock] tells the time; both exist for tests.
  ///
  /// Throws [ArgumentError] when the sample rate is not between 0 and 1 or,
  /// without an [exporter], when the host is not a URL or a key is missing.
  LangfuseHandler(
    this.config, {
    http.Client? httpClient,
    SpanExporter? exporter,
    Random? random,
    DateTime Function()? clock,
  })  : _random = random ?? Random.secure(),
        _clock = clock ?? DateTime.now,
        _ownsExporter = exporter == null,
        _exporter = exporter ?? _httpExporter(config, httpClient) {
    final rate = config.sampleRate;
    if (rate.isNaN || rate < 0 || rate > 1) {
      throw ArgumentError.value(
        rate,
        'sampleRate',
        'the Langfuse sample rate must be between 0 and 1',
      );
    }
    _sampleRate = rate <= 0 ? 1 : rate;
    _prepare = valuePreparer(
      mask: config.mask,
      maxLength: config.maxAttributeValueLength,
      onLimit: () => _lose(valueLimit),
    );
  }

  /// The name of the instrumentation scope of the exported spans.
  static const String instrumentationName = 'threepio_core/langfuse';

  /// The version of the instrumentation scope. It changes when the shape of
  /// the exported spans does.
  static const String instrumentationVersion = '1.0.0';

  /// The reason, in [losses], for values cut to
  /// [LangfuseConfig.maxAttributeValueLength].
  static const String valueLimit = 'value_limit_truncations';

  /// The reason for values dropped or cut because the span had used up
  /// [LangfuseConfig.maxSpanAttributeLength].
  static const String spanAttributeBudget =
      'span_attribute_budget_drops_or_truncations';

  /// The reason for metadata values that could not be written as JSON.
  static const String metadataSerialization = 'metadata_serialization_failures';

  /// The reason for inputs and outputs that could not be written as JSON.
  static const String payloadSerialization = 'payload_serialization_failures';

  /// The reason for values the mask function failed on, which are left out.
  static const String maskFailed = 'mask_failures';

  /// The reason for spans of traces that are not sampled.
  static const String sampledOut = 'sampled_out_spans';

  /// The reason for spans the exporter did not take.
  static const String exporterRefused = 'exporter_refused_spans';

  /// The reason for spans that ended after [shutdown].
  static const String afterShutdown = 'spans_after_shutdown';

  /// The settings of this handler.
  final LangfuseConfig config;

  final Random _random;
  final DateTime Function() _clock;
  final SpanExporter _exporter;
  final bool _ownsExporter;
  late final double _sampleRate;
  late final String Function(String) _prepare;

  final _AsyncGroup _async = _AsyncGroup();
  bool _isShutDown = false;
  final Set<_TraceRun> _activeRuns = {};
  final Map<String, int> _losses = {};
  final Map<String, int> _unreportedLosses = {};

  /// How much telemetry was dropped or cut so far, by reason (the constants
  /// of this class). Losses of the transport are counted by the exporter.
  Map<String, int> get losses => Map.unmodifiable(_losses);

  static SpanExporter _httpExporter(LangfuseConfig config, http.Client? client) {
    final endpoint = LangfuseConfig.traceEndpoint(config.host);
    if (config.publicKey.isEmpty || config.secretKey.isEmpty) {
      throw ArgumentError(
        'the Langfuse public key and secret key are required',
      );
    }
    final credentials = base64Encode(
      utf8.encode('${config.publicKey}:${config.secretKey}'),
    );
    return OtlpHttpTraceExporter(
      OtlpExporterConfig(
        endpoint: endpoint,
        headers: {
          'Authorization': 'Basic $credentials',
          'x-langfuse-ingestion-version': '4',
        },
        serviceName: config.serviceName,
        resourceAttributes: const {
          'telemetry.sdk.name': 'threepio_core',
          'telemetry.sdk.language': 'dart',
        },
        scopeName: instrumentationName,
        scopeVersion: instrumentationVersion,
        timeout: config.timeout,
        maxQueueSize: config.maxQueueSize,
        maxExportBatchSize:
            config.maxExportBatchSize ?? min(512, config.maxQueueSize),
        batchTimeout: config.batchTimeout,
        retry: config.retry,
      ),
      httpClient: client,
    );
  }

  // ---------------------------------------------------------------- traces

  /// Opens a trace and returns the context its components run with.
  ///
  /// Port of `CallbackHandler.StartTrace` and its options. The trace has one
  /// root observation, of [observationType] and called [name], that the
  /// observations of the components are shown beneath. [userId], [sessionId],
  /// [release], [environment], [version], [tags], [public] and [metadata]
  /// describe the trace; where one is left out the value of the
  /// [LangfuseConfig] applies, and [tags] are added to the configured ones.
  /// [input] is shown as the input of the root observation. [id] makes the
  /// trace use that trace id (32 hexadecimal digits) instead of a new one.
  ///
  /// The root is closed by [endTrace]. It is also closed when the cancel
  /// token of [ctx] is cancelled, and by [shutdown]; in every case only after
  /// the components that are still running have ended.
  RunContext startTrace(
    RunContext ctx, {
    String? id,
    String? name,
    String? userId,
    String? input,
    String? sessionId,
    String? release,
    List<String> tags = const [],
    bool? public,
    Map<String, Object?> metadata = const {},
    String? environment,
    String? version,
    LangfuseObservationType observationType = LangfuseObservationType.span,
  }) {
    final traceName = _or(name, config.name) ?? 'threepio-trace';
    final traceAttributes = _traceAttributes(
      name: traceName,
      userId: _or(userId, config.userId),
      sessionId: _or(sessionId, config.sessionId),
      release: _or(release, config.release),
      environment: _or(environment, config.environment),
      version: _or(version, config.version),
      tags: [...config.tags, ...tags],
      public: public ?? config.public,
      metadata: metadata,
    );

    final requested = id?.toLowerCase();
    final traceId = requested != null && isValidTraceId(requested)
        ? requested
        : ctx.value(_parentKey)?.traceId ?? newTraceId(_random);
    final span = _Span(
      traceId: traceId,
      spanId: newSpanId(_random),
      parentSpanId: null,
      name: traceName,
      start: _clock(),
      sampled: isTraceSampled(traceId, _sampleRate),
    );
    _fit(span, {
      'langfuse.observation.type': observationType.name,
      ...traceAttributes,
      if (input != null && input.isNotEmpty)
        'langfuse.observation.input': _prepared(input),
    });

    final run = _TraceRun(this, span, traceAttributes);
    _activeRuns.add(run);
    run.watch(ctx.cancelToken);
    return ctx.withValue(_parentKey, span.context).withValue(_runKey, run);
  }

  /// Closes the trace [ctx] belongs to, with [output] as the output of its
  /// root observation.
  ///
  /// Port of `CallbackHandler.EndTrace`. The root is exported once the
  /// components of the trace that are still running have ended. Without an
  /// [output] the root shows the output of the outermost agent, or else of
  /// the component that ended last. Calling it again, or with a context that
  /// has no trace, does nothing.
  void endTrace(RunContext ctx, [String output = '']) =>
      ctx.value(_runKey)?.requestEnd(output, explicit: true);

  /// Waits for the streams this handler is still reading and sends every
  /// finished observation to Langfuse.
  ///
  /// Port of `CallbackHandler.Flush`. With a [timeout], neither the streams
  /// that have not ended nor a Langfuse that does not answer are waited for
  /// longer than that, each.
  Future<void> flush({Duration? timeout}) async {
    await _async.wait(timeout: timeout);
    _reportLosses();
    await _bounded(_exporter.flush(), timeout, 'flush');
  }

  /// Closes the traces that are still open, sends everything to Langfuse and
  /// releases the transport. What ends afterwards is not exported.
  ///
  /// Port of `CallbackHandler.Shutdown`. Call it before the application
  /// exits. With a [timeout], streams that have not ended by then are not
  /// waited for any longer and their observations are lost, and the delivery
  /// to Langfuse is given up after the same time again.
  Future<void> shutdown({Duration? timeout}) async {
    await _async.wait(timeout: timeout, close: true);
    for (final run in _activeRuns.toList()) {
      run.end();
    }
    _isShutDown = true;
    _reportLosses();
    final exporter = _exporter;
    if (!_ownsExporter) {
      await _bounded(exporter.flush(), timeout, 'flush');
    } else if (exporter is OtlpHttpTraceExporter) {
      // Its own timeout also stops the retries and discards what is left.
      await exporter.shutdown(timeout: timeout);
    } else {
      await _bounded(exporter.shutdown(), timeout, 'shutdown');
    }
  }

  /// Waits for [work] of the exporter, but not longer than [timeout].
  Future<void> _bounded(Future<void> work, Duration? timeout, String what) async {
    try {
      if (timeout == null) {
        await work;
      } else {
        await work.timeout(
          timeout,
          onTimeout: () => _log.warning(
            'langfuse callback stopped waiting for the exporter to $what; '
            'telemetry may not have been exported',
          ),
        );
      }
      // An exporter that fails must not fail the application's shutdown.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning('langfuse exporter failed to $what', error, stackTrace);
    }
  }

  Map<String, Object?> _traceAttributes({
    required String name,
    required String? userId,
    required String? sessionId,
    required String? release,
    required String? environment,
    required String? version,
    required List<String> tags,
    required bool public,
    required Map<String, Object?> metadata,
  }) {
    final attributes = <String, Object?>{
      'langfuse.trace.name': name,
      if (userId != null) 'langfuse.user.id': userId,
      if (sessionId != null) 'langfuse.session.id': sessionId,
      if (release != null) 'langfuse.release': release,
      if (environment != null) 'langfuse.environment': environment,
      if (version != null) 'langfuse.version': version,
      if (tags.isNotEmpty) 'langfuse.trace.tags': List<String>.of(tags),
      if (public) 'langfuse.trace.public': true,
    };
    for (final MapEntry(:key, :value) in metadata.entries) {
      final text = value is String ? value : encodeJson(value);
      if (text == null) {
        _lose(metadataSerialization);
        continue;
      }
      attributes['langfuse.trace.metadata.${metadataKey(key)}'] =
          _prepared(text);
    }
    return attributes;
  }

  // -------------------------------------------------------------- callbacks

  /// Port of `CallbackHandler.Needed`: with
  /// [LangfuseConfig.collapseAgentInternalSpans], the machinery of an agent
  /// gets no observations.
  @override
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing) {
    if (!config.collapseAgentInternalSpans || info.isUnknown) return true;
    final agentName = ctx.value(_activeAgentNameKey);
    if (agentName == null || agentName.isEmpty) return true;

    return switch (info.componentType) {
      ComponentType.chain => info.name != agentName,
      ComponentType.graph => info.name != internalReActGraphName,
      ComponentType.lambda => info.name.isNotEmpty &&
          info.name != ComponentType.lambda.einoName &&
          info.name != internalInitLambdaName,
      _ => true,
    };
  }

  /// The name of the graph an agent runs its model and tools in.
  @visibleForTesting
  static const String internalReActGraphName = 'ReAct';

  /// The name of the lambda an agent prepares its run with.
  @visibleForTesting
  static const String internalInitLambdaName = 'Init';

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    if (info.isUnknown) return ctx;
    // Also after a shutdown: the component still needs a state of its own,
    // or its end callback would end the observation of the one around it.
    final state = _startSpan(ctx, info);
    _guarded(state, () => _setInput(state, info, [input]));
    state.inputDone.complete();
    return _enter(ctx, info, state);
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    final state = ctx.value(_stateKey);
    if (info.isUnknown || state == null) return ctx;
    if (info.componentType == ComponentType.agent) {
      final agentOutput = AgentCallbackOutput.from(output);
      if (agentOutput != null) {
        _endAgentOutput(state, agentOutput.events);
        return ctx;
      }
    }
    void finish() => state.end(
          _guarded(state, () => _setOutput(state, info, [output], null)),
        );
    if (state.inputDone.isCompleted) {
      finish();
    } else {
      // The input was a stream and is still being read; a component has
      // usually read all of it by the time it returns. The span waits for
      // it, or it would end without its input.
      final started = _async.run(() async {
        await state.inputDone.future;
        finish();
      });
      if (!started) finish();
    }
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    final state = ctx.value(_stateKey);
    if (info.isUnknown || state == null) return ctx;
    void finish() => state.end(
          _guarded(state, () {
            final (status, cause) = state.recordError('callback', error);
            final output = switch (status) {
              _Outcome.cancelled => cancelledOutput(cause),
              _Outcome.interrupted => interruptedOutput(cause),
              _Outcome.failed => errorOutput('$error'),
            };
            return state.span.setString('langfuse.observation.output', output);
          }),
        );
    final started = _async.run(() async {
      await state.inputDone.future;
      finish();
    });
    if (!started) finish();
    return ctx;
  }

  @override
  Future<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) async {
    if (info.isUnknown) {
      await input.close();
      return ctx;
    }
    final state = _startSpan(ctx, info);
    final started = _async.run(() async {
      try {
        final (inputs, _, error) = await _receiveAll(input);
        _guarded(state, () {
          if (error != null) {
            state.recordError('stream input', error);
            return '';
          }
          return _setInput(state, info, inputs);
        });
      } finally {
        state.inputDone.complete();
      }
    });
    if (!started) {
      await input.close();
      state.inputDone.complete();
    }
    return _enter(ctx, info, state);
  }

  @override
  Future<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) async {
    final state = ctx.value(_stateKey);
    if (info.isUnknown || state == null) {
      await output.close();
      return ctx;
    }
    final started = _async.run(() async {
      final (outputs, firstAt, error) = await _receiveAll(output);
      await state.inputDone.future;
      state.end(
        _guarded(state, () {
          if (error != null) state.recordError('stream output', error);
          return _setOutput(state, info, outputs, firstAt);
        }),
      );
    });
    if (!started) {
      await output.close();
      state.end(state.span.output);
    }
    return ctx;
  }

  /// Reads the events of an agent and ends its observation with its
  /// messages and custom outputs. Port of `endAgentOutput` and
  /// `collectAgentMessages`.
  void _endAgentOutput(_SpanState state, StreamReader<AgentEvent> events) {
    final started = _async.run(() async {
      final messages = <Message>[];
      final customized = <Object?>[];
      try {
        for (var event = await events.nextOrNull();
            event != null;
            event = await events.nextOrNull()) {
          final error = event.error;
          if (error != null) {
            _guarded(state, () {
              state.recordAgentError('agent output', error);
              return '';
            });
          }
          final output = event.output;
          if (output == null) continue;
          final variant = output.messageOutput;
          if (variant != null) {
            try {
              messages.add(await variant.getMessage());
            } on Object catch (error) {
              _guarded(state, () {
                state.recordAgentError('agent message', error);
                return '';
              });
            }
          }
          final custom = output.customizedOutput;
          if (custom != null) customized.add(custom);
        }
      } on Object catch (error) {
        _guarded(state, () {
          state.recordAgentError('agent output', error);
          return '';
        });
      }
      await state.inputDone.future;
      state.end(_guarded(state, () => _setAgentOutput(state, messages, customized)));
    });
    if (!started) {
      unawaited(events.close());
      state.end(state.span.output);
    }
  }

  /// Port of `setAgentOutput`: one value is written as it is, several as a
  /// list; the retry notifications of the agent's model go into metadata.
  String _setAgentOutput(
    _SpanState state,
    List<Message> messages,
    List<Object?> customized,
  ) {
    Object? collapsed(List<Object?> values) =>
        values.length == 1 ? values.single : values;
    final output = <String, Object?>{
      if (messages.isNotEmpty) 'messages': collapsed(messages),
      if (customized.isNotEmpty) 'customized': collapsed(customized),
    };
    final serialized = output.isEmpty
        ? ''
        : _setJson(state, 'langfuse.observation.output', output);
    if (state.retryEvents.isNotEmpty) {
      state.span.setInt(
        'langfuse.observation.metadata.eino_retry_event_count',
        state.retryEvents.length,
      );
      _setJson(
        state,
        'langfuse.observation.metadata.eino_retry_events',
        state.retryEvents,
      );
    }
    return serialized;
  }

  /// Runs [write], which puts something on the span of [state] and returns
  /// the output it wrote. Whatever goes wrong in it is logged, and what was
  /// written before stays: the observation still has to end, or its trace
  /// would wait for it for ever. Port of `recoverCallbackPanic`.
  String _guarded(_SpanState state, String Function() write) {
    try {
      return write();
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning('langfuse callback failed', error, stackTrace);
      return state.span.output;
    }
  }

  /// The context a component runs with after its start callback: its span is
  /// the parent of what runs inside.
  RunContext _enter(RunContext ctx, RunInfo info, _SpanState state) {
    var next = ctx
        .withValue(_stateKey, state)
        .withValue(_parentKey, state.span.context);
    if (info.componentType == ComponentType.agent) {
      next = next.withValue(_agentScopeKey, state);
      if (config.collapseAgentInternalSpans && info.name.isNotEmpty) {
        next = next.withValue(_activeAgentNameKey, info.name);
      }
    }
    return next;
  }

  _SpanState _startSpan(RunContext ctx, RunInfo info) {
    var run = ctx.value(_runKey);
    final attributes = <String, Object?>{};
    if (run != null && run.childStarted()) {
      attributes.addAll(run.traceAttributes);
    } else {
      run = null;
    }
    attributes.addAll({
      'langfuse.observation.type': _observationType(info).name,
      'langfuse.observation.metadata.eino_component':
          info.componentType.einoName,
      'langfuse.observation.metadata.eino_type': info.type,
    });

    var enclosingAgent = ctx.value(_agentScopeKey);
    if (enclosingAgent != null && !identical(enclosingAgent.run, run)) {
      // A trace started inside an agent of another trace is on its own: the
      // outer agent does not answer for its errors.
      enclosingAgent = null;
    }

    final parent = ctx.value(_parentKey);
    final traceId = parent?.traceId ?? newTraceId(_random);
    final span = _Span(
      traceId: traceId,
      spanId: newSpanId(_random),
      parentSpanId: parent?.spanId,
      name: _observationName(info),
      start: _clock(),
      sampled: parent?.sampled ?? isTraceSampled(traceId, _sampleRate),
    );
    _fit(span, attributes);

    return _SpanState(
      handler: this,
      span: span,
      run: run,
      enclosingAgent: enclosingAgent,
      outermostAgent:
          enclosingAgent == null && info.componentType == ComponentType.agent,
    );
  }

  /// Puts the first attributes on [span] and sets what is left of the
  /// budget. Port of `fitAttributes`.
  void _fit(_Span span, Map<String, Object?> attributes) {
    span
      ..owner = this
      ..remaining = config.maxSpanAttributeLength < 0
          ? -1
          : config.maxSpanAttributeLength;
    for (final MapEntry(:key, :value) in attributes.entries) {
      if (value == null || (value is String && value.isEmpty)) continue;
      if (span.remaining < 0) {
        span.attributes[key] = value;
        continue;
      }
      final size = key.length + _sizeOf(value);
      if (size <= span.remaining) {
        span.attributes[key] = value;
        span.remaining -= size;
        continue;
      }
      _lose(spanAttributeBudget);
      if (value is! String || span.remaining <= key.length) continue;
      final cut = fitValue(value, span.remaining - key.length);
      if (cut.isEmpty) continue;
      span.attributes[key] = cut;
      span.remaining -= key.length + cut.length;
    }
  }

  static int _sizeOf(Object value) => switch (value) {
        final String text => text.length,
        final List<Object?> items =>
          items.fold(0, (sum, item) => sum + '$item'.length),
        _ => '$value'.length,
      };

  String _setInput(_SpanState state, RunInfo info, List<Object?> inputs) {
    if (info.componentType != ComponentType.chatModel) {
      return _setJson(state, 'langfuse.observation.input', collapseValues(inputs));
    }

    ModelCallbackConfig? modelConfig;
    Map<String, Object?>? extra;
    final messageLists = <List<Message>>[];
    for (final input in inputs) {
      final converted = ModelCallbackInput.from(input);
      if (converted == null) continue;
      modelConfig = converted.config ?? modelConfig;
      extra = converted.extra ?? extra;
      if (converted.messages.isNotEmpty) messageLists.add(converted.messages);
    }

    final String serialized;
    if (messageLists.isEmpty) {
      // Not the input of a chat model as this library reports it; shown as
      // it is rather than not at all.
      serialized =
          _setJson(state, 'langfuse.observation.input', collapseValues(inputs));
    } else {
      final List<Message> messages;
      try {
        messages = concatMessageArray(messageLists);
      } on Object catch (error) {
        state.recordError('model input', error);
        return '';
      }
      serialized = _setJson(state, 'langfuse.observation.input', messages);
    }
    _setModelConfig(state, modelConfig);
    _setMetadata(state, extra);
    return serialized;
  }

  String _setOutput(
    _SpanState state,
    RunInfo info,
    List<Object?> outputs,
    DateTime? completionStart,
  ) {
    if (info.componentType != ComponentType.chatModel) {
      return _setJson(
        state,
        'langfuse.observation.output',
        collapseValues(outputs),
      );
    }

    ModelCallbackConfig? modelConfig;
    TokenUsage? usage;
    Map<String, Object?>? extra;
    final chunks = <Message>[];
    for (final output in outputs) {
      final converted = ModelCallbackOutput.from(output);
      if (converted == null) continue;
      final message = converted.message;
      if (message != null) chunks.add(message);
      modelConfig = converted.config ?? modelConfig;
      usage = converted.tokenUsage ?? usage;
      extra = converted.extra ?? extra;
    }

    Message? message;
    if (chunks.isNotEmpty) {
      try {
        // Telemetry takes what it gets: a stream whose chunks do not quite
        // agree is still shown.
        message = concatMessagesLeniently(chunks);
      } on Object catch (error) {
        state.recordError('model output', error);
        return '';
      }
    }

    final String serialized;
    if (message != null) {
      serialized = _setJson(state, 'langfuse.observation.output', message);
    } else if (outputs.isNotEmpty && chunks.isEmpty) {
      serialized = _setJson(
        state,
        'langfuse.observation.output',
        collapseValues(outputs),
      );
    } else {
      serialized = '';
    }
    _setModelConfig(state, modelConfig);
    _setMetadata(state, extra);
    _setUsage(state, usage ?? message?.responseMeta?.usage);
    if (completionStart != null) {
      state.span.setString(
        'langfuse.observation.completion_start_time',
        completionStart.toUtc().toIso8601String(),
      );
    }
    return serialized;
  }

  String _setJson(_SpanState state, String key, Object? value) {
    final encoded = encodeJson(value);
    if (encoded == null) {
      _lose(payloadSerialization);
      state.recordError(
        'serialize $key',
        ThreepioFormatException('${value.runtimeType} cannot be written as JSON'),
      );
      return '';
    }
    return state.span.setString(key, encoded);
  }

  /// Port of `setModelConfig`.
  void _setModelConfig(_SpanState state, ModelCallbackConfig? modelConfig) {
    if (modelConfig == null) return;
    final model = modelConfig.model;
    if (model != null && model.isNotEmpty) {
      state.span.setString('langfuse.observation.model.name', model);
    }
    final stop = modelConfig.stop;
    final parameters = {
      if ((modelConfig.maxTokens ?? 0) != 0)
        'max_tokens': modelConfig.maxTokens,
      if (stop != null && stop.isNotEmpty) 'stop': stop,
      if ((modelConfig.temperature ?? 0) != 0)
        'temperature': modelConfig.temperature,
      if ((modelConfig.topP ?? 0) != 0) 'top_p': modelConfig.topP,
    };
    if (parameters.isEmpty) return;
    final encoded = encodeJson(parameters);
    if (encoded != null) {
      state.span.setString('langfuse.observation.model.parameters', encoded);
    }
  }

  /// Port of `setMetadata`.
  void _setMetadata(_SpanState state, Map<String, Object?>? metadata) {
    if (metadata == null) return;
    for (final MapEntry(:key, :value) in metadata.entries) {
      final text = value is String ? value : encodeJson(value);
      if (text == null) {
        _lose(metadataSerialization);
        continue;
      }
      state.span.setString(
        'langfuse.observation.metadata.${metadataKey(key)}',
        text,
      );
    }
  }

  /// Port of `setUsage` and `inclusiveTokenUsage`: the counters of
  /// OpenTelemetry's GenAI conventions, where the cached and the reasoning
  /// tokens are part of the input and the output tokens.
  void _setUsage(_SpanState state, TokenUsage? usage) {
    if (usage == null) return;
    final input = max(usage.promptTokens, 0);
    final output = max(usage.completionTokens, 0);
    final cached = usage.promptTokenDetails?.cachedTokens ?? 0;
    final reasoning = usage.completionTokenDetails?.reasoningTokens ?? 0;
    state.span
      ..setInt('gen_ai.usage.input_tokens', input)
      ..setInt('gen_ai.usage.output_tokens', output)
      ..setInt('gen_ai.usage.cache_read.input_tokens', cached.clamp(0, input))
      ..setInt(
        'gen_ai.usage.reasoning.output_tokens',
        reasoning.clamp(0, output),
      );
  }

  /// Reads [reader] to its end and closes it. Returns the items, the time
  /// the first one arrived, and the error that ended the reading early.
  Future<(List<Object?>, DateTime?, Object?)> _receiveAll(
    StreamReader<Object?> reader,
  ) async {
    final values = <Object?>[];
    DateTime? first;
    try {
      while (true) {
        try {
          final value = await reader.recv();
          first ??= _clock();
          values.add(value);
        } on SourceEOFException {
          // One source of a merged stream ended; the others go on.
        }
      }
    } on StreamEOFException {
      return (values, first, null);
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      return (values, first, error);
    } finally {
      await reader.close();
    }
  }

  void _export(_Span span, DateTime end) {
    if (_isShutDown) {
      _lose(afterShutdown);
      return;
    }
    if (!span.sampled) {
      _losses.update(sampledOut, (count) => count + 1, ifAbsent: () => 1);
      return;
    }
    var accepted = false;
    try {
      accepted = _exporter.add(
        OtlpSpan(
          traceId: span.traceId,
          spanId: span.spanId,
          parentSpanId: span.parentSpanId,
          name: span.name,
          startTime: span.start,
          endTime: end,
          attributes: Map.unmodifiable(span.attributes),
          events: List.unmodifiable(span.events),
          status: span.status,
        ),
      );
      // An exporter given to the handler may be anything. Ending a span
      // happens on the path of the run, and of `endTrace`.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning('langfuse exporter failed to take a span', error, stackTrace);
    }
    if (!accepted) _lose(exporterRefused);
  }

  /// [value] masked and cut to size, or `''` when the mask function failed:
  /// a value that could not be masked is not exported.
  String _prepared(String value) {
    try {
      return _prepare(value);
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning('The Langfuse mask function failed', error, stackTrace);
      _lose(maskFailed);
      return '';
    }
  }

  void _lose(String reason) {
    _losses.update(reason, (count) => count + 1, ifAbsent: () => 1);
    _unreportedLosses.update(reason, (count) => count + 1, ifAbsent: () => 1);
  }

  /// One warning for what was lost since the last one.
  void _reportLosses() {
    if (_unreportedLosses.isEmpty) return;
    final parts = [
      for (final reason in _unreportedLosses.keys.toList()..sort())
        '$reason=${_unreportedLosses[reason]}',
    ];
    _unreportedLosses.clear();
    _log.warning(
      'langfuse callback discarded telemetry since the previous report: '
      '${parts.join(' ')}',
    );
  }

  static LangfuseObservationType _observationType(RunInfo info) =>
      switch (info.componentType) {
        ComponentType.agent => LangfuseObservationType.agent,
        ComponentType.chatModel => LangfuseObservationType.generation,
        ComponentType.embedder => LangfuseObservationType.embedding,
        ComponentType.retriever => LangfuseObservationType.retriever,
        ComponentType.tool => LangfuseObservationType.tool,
        ComponentType.promptTemplate => LangfuseObservationType.chain,
        _ => LangfuseObservationType.span,
      };

  /// Port of `callbackName`.
  static String _observationName(RunInfo info) {
    if (info.name.isNotEmpty) return info.name;
    final kind = info.componentType.einoName;
    return info.type.isNotEmpty ? '${info.type}$kind' : kind;
  }

  static String? _or(String? value, String? fallback) {
    if (value != null && value.isNotEmpty) return value;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return null;
  }
}

// ------------------------------------------------------------------ internals

final _parentKey = ContextKey<_SpanContext>('langfuse.parentSpan');
final _stateKey = ContextKey<_SpanState>('langfuse.spanState');
final _runKey = ContextKey<_TraceRun>('langfuse.traceRun');
final _agentScopeKey = ContextKey<_SpanState>('langfuse.agentScope');
final _activeAgentNameKey = ContextKey<String>('langfuse.activeAgentName');

/// What a span has to know about the one it is part of.
final class _SpanContext {
  const _SpanContext(this.traceId, this.spanId, {required this.sampled});
  final String traceId;
  final String spanId;
  final bool sampled;
}

/// A span that is still open, and the budget of what may be written to it.
/// Port of `spanAttributeWriter` on top of a plain record of the span.
final class _Span {
  _Span({
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.name,
    required this.start,
    required this.sampled,
  });

  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final String name;
  final DateTime start;
  final bool sampled;

  final Map<String, Object?> attributes = {};
  final List<OtlpSpanEvent> events = [];
  OtlpStatus status = const OtlpStatus();

  late LangfuseHandler owner;

  /// The code units the handler may still write to this span; negative when
  /// there is no limit.
  int remaining = -1;

  /// The value of `langfuse.observation.output` as it was written.
  String output = '';

  bool _ended = false;

  _SpanContext get context => _SpanContext(traceId, spanId, sampled: sampled);

  /// Writes a string attribute, masked and cut to what the span may still
  /// take. Returns what was written, or `''` when nothing was.
  String setString(String key, String value) {
    if (value.isEmpty || _ended) return '';
    var prepared = owner._prepared(value);
    if (prepared.isEmpty) return '';
    if (remaining >= 0) {
      final available = remaining - key.length;
      if (available <= 0) {
        owner._lose(LangfuseHandler.spanAttributeBudget);
        return '';
      }
      if (prepared.length > available) {
        owner._lose(LangfuseHandler.spanAttributeBudget);
        prepared = fitValue(prepared, available);
      }
      remaining -= key.length + prepared.length;
    }
    if (prepared.isEmpty) return '';
    attributes[key] = prepared;
    if (key == 'langfuse.observation.output') output = prepared;
    return prepared;
  }

  /// Writes an integer attribute if [value] is positive.
  void setInt(String key, int value) {
    if (value <= 0 || _ended) return;
    if (remaining >= 0) {
      final size = key.length + '$value'.length;
      if (size > remaining) {
        owner._lose(LangfuseHandler.spanAttributeBudget);
        return;
      }
      remaining -= size;
    }
    attributes[key] = value;
  }

  /// Records [error] as an `exception` event, as OpenTelemetry does.
  void recordException(Object error) {
    if (_ended) return;
    events.add(
      OtlpSpanEvent(
        name: 'exception',
        time: owner._clock(),
        attributes: {
          'exception.type': '${error.runtimeType}',
          'exception.message': owner._prepared('$error'),
        },
      ),
    );
  }

  void setError(String message) {
    if (_ended) return;
    status = OtlpStatus(
      code: OtlpStatusCode.error,
      message: owner._prepared(message),
    );
  }

  /// Ends the span and hands it to the exporter. Only the first call counts.
  void end() {
    if (_ended) return;
    _ended = true;
    owner._export(this, owner._clock());
  }
}

enum _Outcome { failed, cancelled, interrupted }

/// The observation of one component between its start and its end callback.
/// Port of `spanState`.
final class _SpanState {
  _SpanState({
    required this.handler,
    required this.span,
    required this.run,
    required this.enclosingAgent,
    required this.outermostAgent,
  });

  final LangfuseHandler handler;
  final _Span span;

  /// The trace this observation counts as a child of, if it has one.
  final _TraceRun? run;

  /// The agent this component runs in. An agent deals with the failures of
  /// what it calls, so only an outermost agent, or a component outside any
  /// agent, makes the root of the trace fail.
  final _SpanState? enclosingAgent;
  final bool outermostAgent;

  /// Completes when the input has been written, which for a stream is when
  /// it has ended.
  final Completer<void> inputDone = Completer<void>();

  bool _ended = false;
  bool _failed = false;

  /// The retry notifications of an agent's model (`WillRetryException`s in
  /// its event stream), in order. Port of `spanState.retryEvents`.
  final List<Map<String, Object?>> retryEvents = [];

  /// Notes an error in an agent's events: a retry notification goes into
  /// [retryEvents], anything else is recorded as an error. Port of
  /// `spanState.recordAgentError`.
  void recordAgentError(String operation, Object error) {
    final retry = ThreepioException.findCause<WillRetryException>(error);
    if (retry == null) {
      recordError(operation, error);
      return;
    }
    var reason = retry.rejectReason;
    if (reason is Exception || reason is Error) reason = '$reason';
    if (reason != null && encodeJson(reason) == null) reason = '$reason';
    retryEvents.add({
      'operation': operation,
      'attempt': retry.retryAttempt,
      'error': retry.errorText,
      if (reason != null) 'reject_reason': reason,
    });
  }

  /// Port of `spanState.recordError`. Returns what kind of end this is and,
  /// for a cancellation or an interrupt, its cause.
  (_Outcome, String) recordError(String operation, Object error) {
    final cancelled = ThreepioException.findCause<CancelledException>(error);
    if (cancelled != null) {
      final reason = cancelled.reason;
      final cause = reason == null || reason.isEmpty ? 'cancelled' : reason;
      final message = reason == null || reason.isEmpty
          ? '$operation: cancelled'
          : '$operation: cancelled: $reason';
      if (!_failed) {
        span.setString('langfuse.observation.status_message', message);
      }
      span
        ..setString(
          'langfuse.observation.metadata.eino_callback_cancelled',
          'true',
        )
        ..setString(
          'langfuse.observation.metadata.eino_cancellation_cause',
          cause,
        );
      run?.recordCancellation(message, cause);
      return (_Outcome.cancelled, cause);
    }

    if (isInterrupt(error)) {
      final cause = '$error';
      final message = '$operation: interrupted';
      if (!_failed) {
        span.setString('langfuse.observation.status_message', message);
      }
      span
        ..setString(
          'langfuse.observation.metadata.eino_callback_interrupted',
          'true',
        )
        ..setString('langfuse.observation.metadata.eino_interrupt_cause', cause);
      run?.recordInterruption(message, cause);
      return (_Outcome.interrupted, cause);
    }

    _failed = true;
    final message = '$operation: $error';
    span
      ..recordException(error)
      ..setError(message)
      ..setString('langfuse.observation.level', 'ERROR')
      ..setString('langfuse.observation.status_message', message)
      ..setString('langfuse.observation.metadata.eino_callback_error', message);
    if (enclosingAgent == null) run?.recordError(message, error);
    return (_Outcome.failed, '');
  }

  /// Ends the observation; [output] is what the root of the trace may show
  /// as its own output. Only the first call counts.
  void end(String output) {
    if (_ended) return;
    _ended = true;
    span.end();
    run?.childEnded(output, outermostAgent: outermostAgent);
  }
}

/// A trace between `startTrace` and the end of its root observation. Port of
/// `traceRun`.
final class _TraceRun {
  _TraceRun(this._handler, this._span, this.traceAttributes);

  final LangfuseHandler _handler;
  final _Span _span;

  /// The attributes every observation of the trace repeats, which is how
  /// Langfuse finds the user, the session and the tags of an observation.
  final Map<String, Object?> traceAttributes;

  int _active = 0;
  bool _endRequested = false;
  bool _ended = false;
  bool _failed = false;
  String _explicitOutput = '';
  String _terminalOutput = '';
  String _agentOutput = '';
  bool _hasAgentOutput = false;
  String _lastOutput = '';

  /// Cancelled when the trace ends, which lets go of the caller's token.
  CancelToken? _watch;

  /// Whether a component may still join the trace; counts it when it may.
  bool childStarted() {
    if (_ended || _endRequested) return false;
    _active++;
    return true;
  }

  void childEnded(String output, {required bool outermostAgent}) {
    if (_ended) return;
    if (outermostAgent) {
      _agentOutput = output;
      _hasAgentOutput = true;
    } else if (output.isNotEmpty) {
      _lastOutput = output;
    }
    if (_active > 0) _active--;
    if (_active == 0 && _endRequested) end();
  }

  /// Ends the trace when [token], the cancel token of the context the trace
  /// was started with, is cancelled. Port of `watchContext`.
  void watch(CancelToken token) {
    // A token of our own next to the caller's, so that ending the trace
    // releases what would otherwise hang on to it for as long as the
    // caller's token lives.
    final release = CancelToken();
    final watch = CancelToken.any([token, release])!;
    _watch = release;
    unawaited(
      watch.whenCancelled.then((_) {
        if (_ended || !token.isCancelled) return;
        final reason = token.reason;
        if (reason == null || reason.isEmpty) {
          requestEnd('', explicit: false);
          return;
        }
        recordCancellation('trace context: cancelled: $reason', reason);
        requestEnd(cancelledOutput(reason), explicit: false);
      }),
    );
  }

  void requestEnd(String output, {required bool explicit}) {
    if (_ended) return;
    _endRequested = true;
    if (output.isNotEmpty) {
      if (explicit) {
        _explicitOutput = output;
      } else {
        _terminalOutput = output;
      }
    }
    if (_active == 0) end();
  }

  void recordError(String message, Object error) {
    if (_ended) return;
    _failed = true;
    _span
      ..recordException(error)
      ..setError(message)
      ..setString('langfuse.observation.level', 'ERROR')
      ..setString('langfuse.observation.status_message', message);
  }

  void recordCancellation(String message, String cause) {
    if (_ended) return;
    if (!_failed) {
      _span.setString('langfuse.observation.status_message', message);
    }
    _span
      ..setString('langfuse.observation.metadata.eino_callback_cancelled', 'true')
      ..setString('langfuse.observation.metadata.eino_cancellation_cause', cause);
  }

  void recordInterruption(String message, String cause) {
    if (_ended) return;
    if (!_failed) {
      _span.setString('langfuse.observation.status_message', message);
    }
    _span
      ..setString(
        'langfuse.observation.metadata.eino_callback_interrupted',
        'true',
      )
      ..setString('langfuse.observation.metadata.eino_interrupt_cause', cause);
  }

  /// Ends the root observation now. Its output is, in this order: what
  /// `endTrace` was given, what ended the context, what the outermost agent
  /// returned, what the last component returned.
  void end() {
    if (_ended) return;
    _ended = true;
    final output = _explicitOutput.isNotEmpty
        ? _explicitOutput
        : _terminalOutput.isNotEmpty
            ? _terminalOutput
            : _hasAgentOutput
                ? _agentOutput
                : _lastOutput;
    if (output.isNotEmpty) {
      _span.setString('langfuse.observation.output', output);
    }
    _span.end();
    _handler._activeRuns.remove(this);
    _watch?.cancel('trace ended');
    _watch = null;
  }
}

/// The work the handler does in the background: reading streams. Port of
/// `asyncGroup`.
final class _AsyncGroup {
  int _active = 0;
  bool _closing = false;
  Completer<void>? _idle;

  /// Starts [work] unless the group is closing. Returns whether it started.
  bool run(Future<void> Function() work) {
    if (_closing) return false;
    _active++;
    unawaited(_guarded(work));
    return true;
  }

  Future<void> _guarded(Future<void> Function() work) async {
    try {
      await work();
      // Telemetry must not surface as an unhandled error of the application.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning('langfuse callback failed', error, stackTrace);
    } finally {
      _active--;
      if (_active == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// Completes when no work is running, or after [timeout]. With [close],
  /// no new work is started from now on.
  Future<void> wait({Duration? timeout, bool close = false}) async {
    if (close) _closing = true;
    if (_active == 0) return;
    final idle = (_idle ??= Completer<void>()).future;
    if (timeout == null) return idle;
    await idle.timeout(
      timeout,
      onTimeout: () => _log.warning(
        'langfuse callback stopped waiting for $_active stream(s) that have '
        'not ended; their observations may be lost',
      ),
    );
  }
}
