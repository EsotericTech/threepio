/// An agentic model over OpenAI's Responses API.
///
/// Port of eino-ext `components/model/agenticopenai/responses_model.go`.
/// **Beta**, as the whole agentic path is upstream.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../../internal/agentic_model_call_callbacks.dart';
import '../../../../internal/call_cancellation.dart';
import '../../../../internal/provider_http.dart';
import '../../../../internal/shared_http_client.dart';
import '../../../../schema/agentic_message.dart';
import '../../../../streaming/stream_reader.dart';
import '../../../component_type.dart';
import '../../agentic_model.dart';
import '../../cancel_token.dart';
import '../../chat_model_options.dart';
import '../../openai_compatible/sse.dart';
import 'openai_responses_block_extra.dart' as extra;
import 'openai_responses_config.dart';
import 'openai_responses_convertor.dart';
import 'openai_responses_event_convertor.dart';
import 'openai_responses_exception.dart';
import 'openai_responses_options.dart';
import 'openai_responses_register.dart';
import 'openai_responses_request.dart';
import 'openai_responses_utils.dart';

/// The component type name of [OpenAIResponsesModel] (Go
/// `responsesImplType`).
const openAIResponsesImplType = 'AgenticOpenAI/Responses';

/// An [AgenticModel] over OpenAI's (and Azure OpenAI's) Responses API.
///
/// Port of eino-ext `agenticopenai.ResponsesModel` (`NewResponsesModel`):
/// complete and streamed responses with reasoning (summaries, raw reasoning
/// text, encrypted content), refusals and annotations, function tools
/// (also deferred ones behind hosted or client tool search), the hosted
/// tools of [OpenAIResponsesServerTool] (web search, file search, code
/// interpreter, shell; image generation results are read), remote MCP
/// servers ([OpenAIResponsesMcpTool]) with approval requests, tool choice
/// from `ChatModelOptions.agenticToolChoice`, prompt caching, and
/// conversation continuation through `previous_response_id`
/// ([OpenAIResponsesOptions.headPreviousResponseId], or automatically with
/// [OpenAIResponsesConfig.enableAutoCache]).
///
/// The request settings are in [config]; a call overrides them with
/// `ChatModelOptions` (`model`, `temperature`, `topP`, `maxTokens`,
/// `tools`, `deferredTools`, `toolSearchTool`, `agenticToolChoice`) and
/// [OpenAIResponsesOptions] in its `extensions`. `stop` and the classic
/// `toolChoice` are rejected, as in Go.
///
/// Go uses the `openai-go` SDK; here the JSON is built and the server-sent
/// events are read directly. The SDK's retries are kept
/// ([OpenAIResponsesConfig.maxRetries], 2 by default, honouring
/// `retry-after-ms`, `retry-after` in seconds and `x-should-retry`; a
/// timed-out attempt is not retried), and so is its timeout of an attempt
/// ([OpenAIResponsesConfig.timeout]), except that it does not cut a stream
/// once the headers are there.
/// Failures are [OpenAIResponsesException]s; a cancelled call (through
/// `ChatModelOptions.cancelToken` or the run context's token) throws or
/// ends its stream with a `CancelledException`.
///
/// Every call is reported to the callback handlers of
/// `ChatModelOptions.runContext` (and the global ones) with
/// `ComponentType.agenticModel` and the type name `AgenticOpenAI/Responses`.
/// A request that cannot be built fails before the start callback, as in
/// Go.
class OpenAIResponsesModel
    implements AgenticModel, TypedComponent, CallbackAwareComponent {
  /// A model with [config]. Without [httpClient] the model creates one
  /// client on first use and closes it in [dispose]; an injected client is
  /// left open.
  OpenAIResponsesModel({
    this.config = const OpenAIResponsesConfig(),
    this.httpClient,
  }) : _http = SharedHttpClient(httpClient, owner: 'OpenAIResponsesModel') {
    ensureOpenAIResponsesTypesRegistered();
  }

  /// The configuration.
  final OpenAIResponsesConfig config;

  /// The HTTP client requests are sent with, when one was injected.
  final http.Client? httpClient;

  final SharedHttpClient _http;

  static final _random = math.Random();

  /// The item status the Responses API reported for [block]
  /// (`in_progress`, `completed`, …), or `null`. Port of eino-ext
  /// `agenticopenai.GetItemStatus`.
  static String? itemStatus(ContentBlock block) => extra.itemStatusOf(block);

  /// Whether [block] is a client-side tool search call (a function call of
  /// the tool search tool). Port of eino-ext
  /// `agenticopenai.GetToolSearchToolCall`.
  static bool isToolSearchToolCall(ContentBlock block) =>
      extra.isToolSearchToolCall(block);

  /// Copies of [messages] whose auto-cache marker is removed, so that the
  /// auto cache does not continue from them. Call it when a message was
  /// changed or the model is switched (OpenAI invalidates the cache of that
  /// message and all later ones). Port of eino-ext
  /// `agenticopenai.InvalidateMessageCaches`, which edits the messages in
  /// place.
  static List<AgenticMessage> invalidateMessageCaches(
    List<AgenticMessage> messages,
  ) =>
      extra.invalidateMessageCaches(messages);

  /// Registers the types this model puts into messages (the item id and
  /// status of a block, the server tool payloads) with `TypeRegistry`, for
  /// checkpoints, and with `StreamConcat`, for joining stream chunks. Port
  /// of the `init` function of eino-ext's `register.go`, which runs when the
  /// Go package is imported. The constructor calls it; call it before
  /// decoding a checkpoint that holds such messages when no model has been
  /// created yet (decoding fails on an unregistered type). Idempotent.
  static void ensureTypesRegistered() => ensureOpenAIResponsesTypesRegistered();

  /// Releases the HTTP client this model created for itself. Using the
  /// model afterwards throws a [StateError].
  void dispose() => _http.close();

  @override
  String get componentTypeName => openAIResponsesImplType;

  /// The model reports its calls to the callback handlers itself.
  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final (common, specific) = resolveOptions(options);
    final request = buildRequest(input, common, specific, stream: false);
    return AgenticModelCallCallbacks.generate(
      common,
      typeName: componentTypeName,
      input: input,
      defaultModel: config.model.isEmpty ? null : config.model,
      generate: () => _generate(request, common),
    );
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final (common, specific) = resolveOptions(options);
    final request = buildRequest(input, common, specific, stream: true);
    return AgenticModelCallCallbacks.stream(
      common,
      typeName: componentTypeName,
      input: input,
      defaultModel: config.model.isEmpty ? null : config.model,
      stream: () => _stream(request, common),
    );
  }

  /// The common options of a call (the config's defaults with [options]
  /// applied) and its provider options. Port of `getOptions` and
  /// `checkOptions`.
  @internal
  (ChatModelOptions, ResolvedResponsesOptions) resolveOptions(
    ChatModelOptions? options,
  ) {
    final common = ChatModelOptions(
      temperature: config.temperature,
      model: config.model.isEmpty ? null : config.model,
      topP: config.topP,
      maxTokens: config.maxTokens,
    ).merge(options);
    final specific = ResolvedResponsesOptions.resolve(config, options);
    if (common.stop != null) {
      throw conversionError("'Stop' option is not supported");
    }
    if (common.toolChoice != null) {
      throw conversionError("'ToolChoice' option is not supported");
    }
    return (common, specific);
  }

  /// The request of a call. Port of `genRequestAndOptions`.
  @internal
  ResponsesRequest buildRequest(
    List<AgenticMessage> input,
    ChatModelOptions options,
    ResolvedResponsesOptions specific, {
    required bool stream,
  }) =>
      wrapConversion('failed to generate request', () {
        final body = <String, Object?>{};
        _prePopulateConfig(body, options, specific);
        final rest = wrapConversion(
          'failed to populate cache',
          () => _populateCache(input, body, specific),
        );
        wrapConversion(
          'failed to populate input',
          () => _populateInput(rest, body),
        );
        wrapConversion(
          'failed to populate tools',
          () => _populateTools(body, options, specific),
        );
        final choice = wrapConversion(
          'failed to populate tool choice',
          () => toToolChoice(options.agenticToolChoice),
        );
        if (choice != null) body['tool_choice'] = choice;
        if (stream) body['stream'] = true;

        final headers = <String, String>{
          'Content-Type': 'application/json',
          'Accept': stream ? 'text/event-stream' : 'application/json',
          if (config.apiKey.isNotEmpty)
            if (config.byAzure)
              'api-key': config.apiKey
            else
              'Authorization': 'Bearer ${config.apiKey}',
          ...?specific.customHeaders,
        };
        body.addAll(specific.extraFields ?? const {});
        return ResponsesRequest(url: _url, headers: headers, body: body);
      });

  Uri get _url {
    final base =
        config.baseUrl.isEmpty ? openAIResponsesDefaultBaseUrl : config.baseUrl;
    return Uri.parse('${base.endsWith('/') ? base : '$base/'}responses');
  }

  void _prePopulateConfig(
    Map<String, Object?> body,
    ChatModelOptions options,
    ResolvedResponsesOptions specific,
  ) {
    if (config.serviceTier case final v?) body['service_tier'] = v.value;
    if (config.include case final v?) {
      body['include'] = [for (final i in v) i.value];
    }
    if (config.promptCacheRetention case final v?) {
      body['prompt_cache_retention'] = v.value;
    }
    if (options.topP case final v?) body['top_p'] = v;
    if (options.temperature case final v?) body['temperature'] = v;
    if (options.model case final v? when v.isNotEmpty) body['model'] = v;
    if (options.maxTokens case final v?) body['max_output_tokens'] = v;
    if (specific.reasoning case final v?) body['reasoning'] = v.toJson();
    if (specific.text case final v?) body['text'] = v.toJson();
    if (specific.maxToolCalls case final v?) body['max_tool_calls'] = v;
    if (specific.parallelToolCalls case final v?) {
      body['parallel_tool_calls'] = v;
    }
    if (specific.promptCacheKey case final v?) body['prompt_cache_key'] = v;
    if (specific.store case final v?) body['store'] = v;
    if (specific.truncation case final v?) body['truncation'] = v.value;
  }

  /// Port of `populateCache`: the last auto-cached response in [input] (with
  /// auto cache on) is continued from, else the head response id of the
  /// options; only the messages after it are sent.
  List<AgenticMessage> _populateCache(
    List<AgenticMessage> input,
    Map<String, Object?> body,
    ResolvedResponsesOptions specific,
  ) {
    String? previousId;
    var index = 0;
    if (config.enableAutoCache) {
      for (var i = input.length - 1; i >= 0; i--) {
        final message = input[i];
        if (!extra.isAutoCached(message)) continue;
        final id = message.responseMeta?.openAIExtension?.id ?? '';
        if (id.isEmpty) continue;
        index = i;
        previousId = id;
        break;
      }
    }

    var rest = input;
    if (previousId != null) {
      if (index + 1 >= input.length) {
        throw conversionError('incremental input not found after response ID');
      }
      rest = input.sublist(index + 1);
    }
    if (previousId == null || previousId.isEmpty) {
      previousId = specific.headPreviousResponseId;
    }
    if (previousId != null && previousId.isNotEmpty) {
      body['previous_response_id'] = previousId;
    }
    if (config.enableAutoCache && specific.store == null) body['store'] = true;
    return rest;
  }

  void _populateInput(List<AgenticMessage> input, Map<String, Object?> body) {
    if (input.isEmpty) return;
    body['input'] = [
      for (final message in input)
        ...switch (message.role) {
          AgenticRoleType.user => toUserRoleInputItems(message),
          AgenticRoleType.assistant => toAssistantRoleInputItems(message),
          AgenticRoleType.system => toSystemRoleInputItems(message),
        },
    ];
  }

  void _populateTools(
    Map<String, Object?> body,
    ChatModelOptions options,
    ResolvedResponsesOptions specific,
  ) {
    final tools = <Map<String, Object?>>[
      ...toFunctionTools(options.tools ?? const []),
    ];
    final deferred = options.deferredTools ?? const [];
    if (deferred.isNotEmpty) {
      tools.addAll(toDeferredFunctionTools(deferred));
      // Hosted tool search is added when deferred tools are set without a
      // client tool search tool.
      if (options.toolSearchTool == null) tools.add({'type': 'tool_search'});
    }
    if (options.toolSearchTool case final searchTool?) {
      final function = wrapConversion(
        'failed to convert tool search tool',
        () => toFunctionTool(searchTool),
      );
      tools.add({
        'type': 'tool_search',
        if (function['description'] case final v?) 'description': v,
        if (function['parameters'] case final v?) 'parameters': v,
        'execution': 'client',
      });
    }
    tools
      ..addAll(toServerTools(specific.serverTools ?? const []))
      ..addAll([
        for (final tool
            in specific.mcpTools ?? const <OpenAIResponsesMcpTool>[])
          tool.toJson(),
      ]);
    if (tools.isNotEmpty) body['tools'] = tools;
  }

  Future<AgenticMessage> _generate(
    ResponsesRequest request,
    ChatModelOptions options,
  ) async {
    final cancellation = CallCancellation.of(options);
    try {
      const prefix = 'failed to create response';
      final (response, attempt) =
          await _send(request, cancellation.token, prefix: prefix);
      final String text;
      try {
        text = await _readBody(response, cancellation.token, attempt);
      } on CancelledException {
        rethrow;
      } on TimeoutException {
        throw _timeoutError().wrap(prefix);
      } catch (error) {
        throw _transportError(error).wrap(prefix);
      }
      final Object? json;
      try {
        json = jsonDecode(text);
      } on FormatException catch (error) {
        throw OpenAIResponsesException(
          '$prefix: invalid JSON response: ${error.message}',
          cause: error,
        );
      }
      final object = asJsonObject(json);
      if (object == null) {
        throw OpenAIResponsesException('$prefix: response is not an object');
      }
      var message = wrapConversion(
        'failed to convert output to message',
        () => toOutputMessage(object, options),
      );
      if (config.enableAutoCache) message = extra.withAutoCached(message);
      return message;
    } finally {
      cancellation.release();
    }
  }

  Future<StreamReader<AgenticMessage>> _stream(
    ResponsesRequest request,
    ChatModelOptions options,
  ) async {
    final cancellation = CallCancellation.of(options);
    var streaming = false;
    try {
      final (response, _) = await _send(
        request,
        cancellation.token,
        prefix: 'failed to create streaming response',
      );
      final (reader, writer) = pipe<AgenticMessage>();
      final converter = ResponsesStreamConverter(
        writer,
        options: options,
        enableAutoCache: config.enableAutoCache,
      );
      final idleTimeout = config.idleTimeout;
      unawaited(
        pumpSse<AgenticMessage>(
          bytes: response.stream,
          writer: writer,
          cancelToken: cancellation.token,
          idleTimeout: idleTimeout,
          idleError: () => OpenAIResponsesException(
            'failed to read stream: stream idle for $idleTimeout',
            isRetryable: true,
          ),
          streamError: (error) => OpenAIResponsesException(
            'failed to read stream: $error',
            isRetryable: true,
            cause: error,
          ),
          dispatchEachDataLine: false,
          onEvent: (event) => handleSseEvent(event, converter),
        ).whenComplete(cancellation.release),
      );
      streaming = true;
      return reader;
    } finally {
      if (!streaming) cancellation.release();
    }
  }

  /// Hands one server-sent event to [converter], as `openai-go`'s stream
  /// reads it: `[DONE]` ends the stream, a payload with an `error` member
  /// or one that is not JSON fails it.
  @internal
  static PumpAction handleSseEvent(
    SseEvent event,
    ResponsesStreamConverter converter,
  ) {
    final data = event.data;
    if (data.startsWith('[DONE]')) return PumpAction.stop;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException catch (error) {
      throw OpenAIResponsesException(
        'failed to read stream: ${error.message}',
        cause: error,
      );
    }
    final object = asJsonObject(decoded);
    if (object == null) {
      throw OpenAIResponsesException(
        'failed to read stream: event is not an object: $data',
      );
    }
    if (object.containsKey('error')) {
      final error = asJsonObject(object['error']);
      final code = error?['code'];
      throw OpenAIResponsesException(
        'failed to read stream: received error while streaming: '
        '${_errorText(object['error'])}',
        errorCode: code,
        isRetryable: isRetryableStreamError(
          code: code is String ? code : null,
          type: error?['type'] is String ? error!['type']! as String : null,
        ),
      );
    }
    converter.onEvent(object);
    return PumpAction.next;
  }

  /// The text of an `error` member as gjson's `Result.String` gives it: a
  /// string as it is, `null` as nothing, anything else as JSON.
  static String _errorText(Object? error) => switch (error) {
        null => '',
        final String text => text,
        _ => jsonEncode(error),
      };

  Duration get _timeout => config.timeout ?? const Duration(days: 3650);

  OpenAIResponsesException _timeoutError() => OpenAIResponsesException(
        'request timed out after ${config.timeout}',
        isRetryable: true,
      );

  OpenAIResponsesException _transportError(Object error) =>
      OpenAIResponsesException(
        'request failed: $error',
        isRetryable: true,
        cause: error,
      );

  /// Sends [request] until a response with a 2xx status arrives, retrying
  /// as `openai-go` does: a transport failure and a 408, 409, 429 or 5xx
  /// response (or as `x-should-retry` says) are retried, a timed-out attempt
  /// and a cancelled call are not. Failures are prefixed with [prefix].
  /// Returns the response and the time its attempt has taken so far (the
  /// timeout covers the whole attempt).
  Future<(http.StreamedResponse, Stopwatch)> _send(
    ResponsesRequest request,
    CancelToken? token, {
    required String prefix,
  }) async {
    // Outside the try: a disposed model is a programming error.
    final client = _http.client;
    final body = jsonEncode(request.body);
    final maxRetries = config.maxRetries ?? 2;
    for (var attempt = 0;; attempt++) {
      final elapsed = Stopwatch()..start();
      http.StreamedResponse? response;
      OpenAIResponsesException? failure;
      try {
        response = await sendStreamingRequest(
          client,
          request.url,
          headers: request.headers,
          body: body,
          timeout: _timeout,
          cancelToken: token,
        );
      } on CancelledException {
        rethrow;
      } on TimeoutException {
        // openai-go returns the attempt's context error at once: a timed-out
        // attempt is not retried.
        throw _timeoutError().wrap(prefix);
      } catch (error) {
        failure = _transportError(error);
      }

      if (response != null &&
          response.statusCode >= 200 &&
          response.statusCode < 300) {
        return (response, elapsed);
      }
      final retry =
          attempt < maxRetries && (response == null || _shouldRetry(response));
      if (!retry) {
        if (response == null) throw failure!.wrap(prefix);
        final String text;
        try {
          text = await _readBody(response, token, elapsed);
        } on CancelledException {
          rethrow;
        } catch (_) {
          throw OpenAIResponsesException.fromHttp(
            response.statusCode,
            '',
            prefix: '$prefix: ',
          );
        }
        throw OpenAIResponsesException.fromHttp(
          response.statusCode,
          text,
          prefix: '$prefix: ',
        );
      }
      if (response != null) unawaited(response.stream.listen(null).cancel());
      await _sleep(retryDelay(response?.headers, attempt), token);
    }
  }

  static bool _shouldRetry(http.StreamedResponse response) {
    final should = response.headers['x-should-retry'];
    if (should == 'true') return true;
    if (should == 'false') return false;
    final status = response.statusCode;
    return status == 408 || status == 409 || status == 429 || status >= 500;
  }

  /// How long to wait before retry number [attempt] + 1, as `openai-go`
  /// computes it: the server's `retry-after-ms` or `retry-after` (seconds)
  /// when it is under a minute, else 0.5 s doubling per attempt up to 8 s,
  /// minus up to a quarter of jitter.
  @internal
  static Duration retryDelay(Map<String, String>? headers, int attempt) {
    Duration? asked;
    final millis = double.tryParse(headers?['retry-after-ms'] ?? '');
    if (millis != null) {
      asked = _microseconds(millis * 1000);
    } else {
      final seconds = double.tryParse(headers?['retry-after'] ?? '');
      if (seconds != null) asked = _microseconds(seconds * 1000000);
    }
    if (asked != null &&
        !asked.isNegative &&
        asked < const Duration(minutes: 1)) {
      return asked;
    }
    final base = math.min(500 * math.pow(2, attempt), 8000).toInt();
    final jitter = base ~/ 4 == 0 ? 0 : _random.nextInt(base ~/ 4);
    return Duration(milliseconds: base - jitter);
  }

  /// [micros] as a duration, or `null` when it is not a finite number (a
  /// `NaN` or `Infinity` header is ignored, as Go's conversion of it gives
  /// no usable delay either).
  static Duration? _microseconds(double micros) =>
      micros.isFinite ? Duration(microseconds: micros.round()) : null;

  static Future<void> _sleep(Duration delay, CancelToken? token) async {
    if (delay <= Duration.zero) {
      token?.throwIfCancelled();
      return;
    }
    final done = Completer<void>();
    final timer = Timer(delay, done.complete);
    if (token == null) return done.future;
    final watch = CallWatch(token);
    try {
      await Future.any([done.future, watch.cancelled]);
    } finally {
      timer.cancel();
      watch.release();
    }
  }

  /// Reads the body of [response] within what is left of the configured
  /// timeout after [elapsed]; on a cancel or a timeout the body subscription
  /// is cancelled.
  Future<String> _readBody(
    http.StreamedResponse response,
    CancelToken? token,
    Stopwatch elapsed,
  ) {
    final completer = Completer<String>();
    final bytes = <int>[];
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    CallWatch? watch;

    void finish([Object? error]) {
      if (completer.isCompleted) return;
      timer?.cancel();
      watch?.release();
      if (error == null) {
        completer.complete(utf8.decode(bytes, allowMalformed: true));
      } else {
        unawaited(subscription?.cancel());
        completer.completeError(error);
      }
    }

    subscription = response.stream.listen(
      bytes.addAll,
      onError: finish,
      onDone: finish,
      cancelOnError: true,
    );
    final timeout = config.timeout;
    if (timeout != null) {
      final left = timeout - elapsed.elapsed;
      timer = Timer(
        left.isNegative ? Duration.zero : left,
        () => finish(TimeoutException('response body timed out', timeout)),
      );
    }
    if (token != null) {
      watch = CallWatch(token)
        ..onCancel(() => finish(CancelledException(token.reason)));
    }
    return completer.future;
  }
}
