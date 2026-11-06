/// Spans of a LangSmith trace that the application opens and closes itself,
/// and the text form of a trace position that carries it to another process.
///
/// Port of eino-ext `callbacks/langsmith/flow_trace.go`.
library;

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../../components/model/cancel_token.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import 'langsmith_client.dart';
import 'langsmith_handler.dart';
import 'langsmith_trace.dart';
import 'langsmith_utils.dart';

final _log = Logger('threepio.observability.langsmith');

/// Opens and closes runs of a LangSmith trace by hand, so that several
/// sessions, requests or processes are recorded in one trace.
///
/// Port of eino-ext `langsmith.FlowTrace` (`langsmith.NewFlowTrace`).
///
/// ```dart
/// final flow = LangSmithFlowTrace(config);
/// final (ctx, spanId) = await flow.startSpan(
///   LangSmithTrace.set(RunContext.background(), sessionName: 'support-bot'),
///   'conversation',
/// );
/// try {
///   await runnable.invoke(ctx, question); // recorded beneath the span
///   final carried = flow.spanToString(ctx); // e.g. into a message header
/// } finally {
///   await flow.finishSpan(ctx, spanId);
/// }
///
/// // In the other process:
/// final state = flow.stringToSpan(carried);
/// final (next, nextId) =
///     await flow.startSpan(RunContext.background(), 'step', state: state);
/// ```
///
/// Unlike `LangSmithHandler`, the requests are sent right away and awaited,
/// as in Go: [startSpan] fails when LangSmith does not create the run.
final class LangSmithFlowTrace {
  /// A flow trace that sends to the LangSmith API of [config].
  ///
  /// [client] replaces the transport, as for `LangSmithHandler`; [close]
  /// does not close it. Of [config], [LangSmithConfig.maxQueueSize] is not
  /// used.
  LangSmithFlowTrace(this.config, {LangSmithApi? client})
      : _ownClient = client == null
            ? LangSmithClient(
                apiKey: config.apiKey,
                apiUrl: config.apiUrl,
                httpClient: config.httpClient,
                timeout: config.timeout,
              )
            : null,
        _client = client;

  /// The settings of this flow trace.
  final LangSmithConfig config;

  final LangSmithClient? _ownClient;
  final LangSmithApi? _client;

  LangSmithApi get _api => _client ?? _ownClient!;

  /// Creates a `chain` run called [name] and returns the context whose
  /// components are recorded beneath it, and the run's id (to give to
  /// [finishSpan]).
  ///
  /// Port of `FlowTrace.StartSpan`. The run is part of the run [state]
  /// describes (from [stringToSpan], or [LangSmithTrace.stateOf]); without a
  /// [state] it starts a trace of its own, also when [ctx] is part of one,
  /// as in Go. The project, tags, metadata and reference example come from
  /// the options of [ctx] ([LangSmithTrace.set]).
  ///
  /// The request is sent at once, not through the queue of a
  /// `LangSmithHandler`: when [state] is the state of a run that handler
  /// opened, call its `flush` first, so that the parent exists in LangSmith
  /// before the span.
  ///
  /// Throws a [LangSmithException] when the run could not be created, and a
  /// [CancelledException] when the cancel token of [ctx] fires first.
  Future<(RunContext, String)> startSpan(
    RunContext ctx,
    String name, {
    LangSmithState? state,
  }) async {
    final options =
        LangSmithTrace.optionsOf(ctx) ?? const LangSmithTraceOptions();
    final parent = state ?? const LangSmithState();
    final extra = langSmithCopyMetadata(options.metadata);
    final runId = (config.runIdGen ?? _randomId)(ctx);
    final start = clock.now().toUtc();
    final traceId = parent.traceId.isEmpty ? runId : parent.traceId;
    final dottedOrder =
        langSmithDottedOrder(parent.parentDottedOrder, start, runId);
    final run = LangSmithRun(
      id: runId,
      traceId: traceId,
      name: name,
      runType: LangSmithRunType.chain,
      startTime: start,
      sessionName: options.sessionName,
      extra: extra,
      tags: options.tags,
      referenceExampleId: options.referenceExampleId.isEmpty
          ? null
          : options.referenceExampleId,
      parentRunId: parent.parentRunId.isEmpty ? null : parent.parentRunId,
      dottedOrder: dottedOrder,
    );
    await _api.createRun(ctx, run);
    final next = LangSmithState(
      traceId: traceId,
      parentRunId: runId,
      parentDottedOrder: dottedOrder,
    );
    return (LangSmithTrace.withState(ctx, next), runId);
  }

  /// Ends the run [runId].
  ///
  /// Port of `FlowTrace.FinishSpan`. A failure is logged (logger
  /// `threepio.observability.langsmith`) and not thrown, as in Go, except a
  /// [CancelledException] when the cancel token of [ctx] has fired.
  Future<void> finishSpan(RunContext ctx, String runId) async {
    final patch = LangSmithRunPatch(endTime: clock.now().toUtc());
    try {
      await _api.updateRun(ctx, runId, patch);
    } on CancelledException {
      rethrow;
      // Ending a span is reported, never fatal (Go logs it).
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      _log.warning('[langsmith] failed to FinishSpan: ${langSmithErrorText(error)}');
    }
  }

  /// The state of the run [ctx] belongs to as text, or `''` when it belongs
  /// to none.
  ///
  /// Port of `FlowTrace.SpanToString`: the JSON of
  /// [LangSmithState.toJson], which Go's `StringToSpan` reads as well.
  /// Throws a [LangSmithException] when the metadata cannot be written as
  /// JSON.
  String spanToString(RunContext ctx) {
    final state = LangSmithTrace.stateOf(ctx);
    if (state == null) return '';
    try {
      return jsonEncode(state.toJson());
    } on Object catch (error) {
      throw LangSmithException(
        'failed to marshal LangSmith state: $error',
        cause: error,
      );
    }
  }

  /// The state [spanToString] wrote, or `null` for `''`.
  ///
  /// Port of `FlowTrace.StringToSpan`. Throws a [ThreepioFormatException]
  /// when [value] is not such a state.
  LangSmithState? stringToSpan(String value) {
    if (value.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'LangSmith state is not JSON: ${error.message}',
        source: value,
        cause: error,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ThreepioFormatException(
        'LangSmith state is not a JSON object',
        source: value,
      );
    }
    return LangSmithState.fromJson(decoded);
  }

  /// Closes the HTTP client this flow trace created, if any.
  void close() => _ownClient?.close();

  static String _randomId(RunContext _) => const Uuid().v4();
}
