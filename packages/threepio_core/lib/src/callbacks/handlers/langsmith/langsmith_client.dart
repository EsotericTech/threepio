/// The LangSmith REST API the LangSmith handler sends its runs to.
///
/// Port of eino-ext `callbacks/langsmith/client.go`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../components/model/cancel_token.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/provider_http.dart';
import '../../../internal/shared_http_client.dart';
import '../../../observability/langfuse/langfuse_values.dart' show toJsonValue;
import 'langsmith_utils.dart';

/// The kind of a LangSmith run, which decides how LangSmith shows it.
///
/// Port of eino-ext `langsmith.RunType`. [value] is the string LangSmith
/// knows it by.
enum LangSmithRunType {
  /// A step that links others together: a graph, a lambda, a retriever, or
  /// any component that is neither a chat model nor a tool.
  chain('chain'),

  /// A call of a chat model.
  llm('llm'),

  /// A call of a tool.
  tool('tool');

  const LangSmithRunType(this.value);

  /// The `run_type` of the run on the wire.
  final String value;
}

/// One run as it is created in LangSmith: what `POST /runs` is sent.
///
/// Port of eino-ext `langsmith.Run`. [toJson] writes the fields Go writes,
/// under the same names and in the same order, and leaves out the ones Go
/// marks `omitempty` when they are empty.
@immutable
final class LangSmithRun {
  /// Creates a run.
  const LangSmithRun({
    required this.id,
    required this.name,
    required this.runType,
    required this.startTime,
    this.endTime,
    this.inputs,
    this.outputs,
    this.error,
    this.parentRunId,
    this.traceId = '',
    this.extra,
    this.sessionName = '',
    this.referenceExampleId,
    this.dottedOrder = '',
    this.tags = const [],
  });

  /// The unique id of the run.
  final String id;

  /// The name the run is shown under.
  final String name;

  /// The kind of run.
  final LangSmithRunType runType;

  /// When the run started.
  final DateTime startTime;

  /// When the run ended, if it has.
  final DateTime? endTime;

  /// What the run was given. Written as `null` when it is `null`, as Go
  /// does.
  final Map<String, Object?>? inputs;

  /// What the run produced.
  final Map<String, Object?>? outputs;

  /// The error the run failed with.
  final String? error;

  /// The id of the run this one is part of.
  final String? parentRunId;

  /// The id of the trace the run is part of: the id of the root run of the
  /// trace. Left out when empty.
  final String traceId;

  /// Anything else about the run. LangSmith shows the entry `metadata` as
  /// the metadata of the run.
  final Map<String, Object?>? extra;

  /// The LangSmith project the run is recorded in. Left out when empty,
  /// which records it in the default project.
  final String sessionName;

  /// The id of the dataset example the run is evaluated against.
  final String? referenceExampleId;

  /// Where the run is in its trace: `<start>Z<id>` of every run from the
  /// root down to this one, joined by dots.
  final String dottedOrder;

  /// The tags of the run.
  final List<String> tags;

  /// The JSON body of `POST /runs`. Values that are not JSON (messages, the
  /// payloads of the components) are written as threepio writes them.
  Map<String, Object?> toJson() {
    final inputs = this.inputs;
    final outputs = this.outputs;
    final extra = this.extra;
    return {
      'id': id,
      'name': name,
      'run_type': runType.value,
      'start_time': langSmithTimeJson(startTime),
      if (endTime case final end?) 'end_time': langSmithTimeJson(end),
      'inputs': inputs == null ? null : toJsonValue(inputs),
      if (outputs != null && outputs.isNotEmpty) 'outputs': toJsonValue(outputs),
      if (error case final error?) 'error': error,
      if (parentRunId case final parent?) 'parent_run_id': parent,
      if (traceId.isNotEmpty) 'trace_id': traceId,
      if (extra != null && extra.isNotEmpty) 'extra': toJsonValue(extra),
      if (sessionName.isNotEmpty) 'session_name': sessionName,
      if (referenceExampleId case final example?)
        'reference_example_id': example,
      if (dottedOrder.isNotEmpty) 'dotted_order': dottedOrder,
      if (tags.isNotEmpty) 'tags': List<String>.of(tags),
    };
  }

  @override
  String toString() => 'LangSmithRun(id: $id, name: $name, '
      'runType: ${runType.value}, traceId: $traceId, '
      'parentRunId: $parentRunId, dottedOrder: $dottedOrder)';
}

/// What a run is updated with when it has ended or failed: what
/// `PATCH /runs/{id}` is sent.
///
/// Port of eino-ext `langsmith.RunPatch`. Every field is left out of
/// [toJson] when it is `null` or empty.
@immutable
final class LangSmithRunPatch {
  /// Creates an update.
  const LangSmithRunPatch({
    this.endTime,
    this.inputs,
    this.outputs,
    this.error,
    this.extra,
  });

  /// When the run ended.
  final DateTime? endTime;

  /// What the run was given.
  final Map<String, Object?>? inputs;

  /// What the run produced.
  final Map<String, Object?>? outputs;

  /// The error the run failed with.
  final String? error;

  /// Anything else about the run; replaces the `extra` of the run.
  final Map<String, Object?>? extra;

  /// The JSON body of `PATCH /runs/{id}`.
  Map<String, Object?> toJson() {
    final inputs = this.inputs;
    final outputs = this.outputs;
    final extra = this.extra;
    return {
      if (endTime case final end?) 'end_time': langSmithTimeJson(end),
      if (inputs != null && inputs.isNotEmpty) 'inputs': toJsonValue(inputs),
      if (outputs != null && outputs.isNotEmpty) 'outputs': toJsonValue(outputs),
      if (error case final error?) 'error': error,
      if (extra != null && extra.isNotEmpty) 'extra': toJsonValue(extra),
    };
  }

  @override
  String toString() => 'LangSmithRunPatch(endTime: $endTime, '
      'outputs: ${outputs?.keys.toList()}, error: $error)';
}

/// Something runs can be created and updated in: the LangSmith API, or a
/// stand-in for it.
///
/// Port of eino-ext `langsmith.Langsmith`. [LangSmithClient] is the
/// implementation that calls LangSmith over HTTP; give `LangSmithHandler`
/// and `LangSmithFlowTrace` another one to send the runs elsewhere (or to
/// record them in a test).
abstract interface class LangSmithApi {
  /// Creates [run]. Throws when it could not be created.
  Future<void> createRun(RunContext ctx, LangSmithRun run);

  /// Updates the run [runId] with [patch]. Throws when it could not be
  /// updated.
  Future<void> updateRun(RunContext ctx, String runId, LangSmithRunPatch patch);
}

/// A request to LangSmith failed: it could not be sent, or LangSmith did not
/// take it.
///
/// Carries the messages of eino-ext's `langsmithClient`.
class LangSmithException extends ThreepioException {
  /// A failure described by [message].
  const LangSmithException(super.message, {super.cause, this.statusCode});

  /// The HTTP status LangSmith answered with, when it answered.
  final int? statusCode;

  @override
  String toString() => 'LangSmithException: $message';
}

/// Creates and updates runs through the LangSmith REST API.
///
/// Port of eino-ext `langsmith.NewLangsmith` and its `langsmithClient`:
/// `POST {apiUrl}/runs` and `PATCH {apiUrl}/runs/{id}` with the API key in
/// the header `x-api-key`. LangSmith has to answer `200` or `202`.
///
/// ```dart
/// final client = LangSmithClient(apiKey: 'lsv2_...');
/// await client.createRun(ctx, run);
/// client.close();
/// ```
final class LangSmithClient implements LangSmithApi {
  /// A client for the LangSmith API at [apiUrl] (an empty one means
  /// [defaultApiUrl]) with [apiKey].
  ///
  /// [httpClient] is used for the requests when given, and the caller closes
  /// it; otherwise one is created on first use and closed by [close]. One
  /// request may take [timeout] at most (Go: the `Timeout` of its
  /// `http.Client`).
  LangSmithClient({
    required this.apiKey,
    String apiUrl = '',
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 10),
  })  : apiUrl = apiUrl.isEmpty ? defaultApiUrl : apiUrl,
        _http = SharedHttpClient(httpClient, owner: 'LangSmithClient');

  /// The LangSmith API of LangChain's cloud. Port of
  /// `DefaultLangsmithAPIURL`.
  static const String defaultApiUrl = 'https://api.smith.langchain.com';

  /// The key the requests are authorised with.
  final String apiKey;

  /// The base URL of the API; the paths are appended to it as they are.
  final String apiUrl;

  /// How long one request may take.
  final Duration timeout;

  final SharedHttpClient _http;

  /// Port of `langsmithClient.CreateRun`.
  ///
  /// Throws a [LangSmithException] with Go's message when the request cannot
  /// be sent or LangSmith answers anything but `200` or `202`, and a
  /// [CancelledException] when the cancel token of [ctx] fires first.
  ///
  /// Unlike Go, the body of a successful answer is not read. Go decodes it
  /// into the run (`sonic.Unmarshal(body, run)`), so a body that is not JSON
  /// fails a creation LangSmith has accepted; and the handler, which sends
  /// after its hook has returned, could not use what the answer says anyway.
  @override
  Future<void> createRun(RunContext ctx, LangSmithRun run) async {
    final String body;
    try {
      body = jsonEncode(run.toJson());
    } on Object catch (error) {
      throw LangSmithException(
        'failed to marshal run data: $error',
        cause: error,
      );
    }
    final response = await _send(ctx, 'POST', '$apiUrl/runs', body);
    _check(response, 'failed to create run');
  }

  /// Port of `langsmithClient.UpdateRun`. Throws like [createRun].
  @override
  Future<void> updateRun(
    RunContext ctx,
    String runId,
    LangSmithRunPatch patch,
  ) async {
    final String body;
    try {
      body = jsonEncode(patch.toJson());
    } on Object catch (error) {
      throw LangSmithException(
        'failed to marshal patch data: $error',
        cause: error,
      );
    }
    final response = await _send(ctx, 'PATCH', '$apiUrl/runs/$runId', body);
    _check(response, 'failed to update run');
  }

  /// Closes the HTTP client this object created, if any. Safe to call more
  /// than once; the client cannot be used afterwards.
  void close() => _http.close();

  Future<http.Response> _send(
    RunContext ctx,
    String method,
    String url,
    String body,
  ) async {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (error) {
      throw LangSmithException('failed to create request: $error', cause: error);
    }
    try {
      return await sendRequest(
        _http.client,
        uri,
        method: method,
        headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
        body: body,
        timeout: timeout,
        cancelToken: ctx.cancelToken,
      );
    } on CancelledException {
      rethrow;
    } on Object catch (error) {
      throw LangSmithException(
        'failed to execute request: $error',
        cause: error,
      );
    }
  }

  static void _check(http.Response response, String what) {
    final code = response.statusCode;
    if (code == 200 || code == 202) return;
    final reason = response.reasonPhrase;
    final status = reason == null || reason.isEmpty ? '$code' : '$code $reason';
    throw LangSmithException(
      '$what, status: $status, body: ${response.body}',
      statusCode: code,
    );
  }
}
