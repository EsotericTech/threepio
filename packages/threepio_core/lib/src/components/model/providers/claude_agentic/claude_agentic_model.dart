/// The agentic model of the Anthropic Messages API.
///
/// Port of eino-ext `components/model/agenticclaude/model.go`. **Beta**, as
/// the whole agentic path is upstream.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../../core/interrupt_signal.dart';
import '../../../../errors.dart';
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
import '../claude/claude_chat_model.dart' show ClaudeException;
import 'claude_agentic_config.dart';
import 'claude_agentic_convertor.dart';
import 'claude_agentic_event_convertor.dart';
import 'claude_agentic_register.dart';
import 'claude_agentic_request.dart';
import 'claude_agentic_utils.dart';

/// Claude as an [AgenticModel], through the Anthropic Messages API
/// (`POST {baseUrl}/v1/messages`).
///
/// Port of eino-ext agenticclaude `Model` (`agenticclaude.New`), for the
/// direct Anthropic API; the Bedrock and Vertex transports are not ported.
/// Input and output are [AgenticMessage]s whose content blocks map one to
/// one onto Claude's: text with citations, thinking with its signature,
/// images and PDFs (by URL, base64 or Files API id), function tool calls
/// and results, tool search results, and the calls and results of Claude's
/// server tools (web search, web fetch, code execution, tool search), whose
/// arguments and results are `ClaudeServerToolCallArguments` and
/// `ClaudeServerToolResult`. Redacted thinking is dropped.
///
/// Function tools are passed per call in `ChatModelOptions.tools` (deferred
/// ones in `deferredTools`, a client-side tool search tool in
/// `toolSearchTool`), how they may be called in
/// `ChatModelOptions.agenticToolChoice`; the classic `toolChoice` and
/// `allowedToolNames` are rejected with an [ArgumentError], as in Go.
/// Server tools, custom headers, extra body fields and the timeout of a call
/// are set with a `ClaudeAgenticOptions` in `ChatModelOptions.extensions`.
///
/// ```dart
/// final model = ClaudeAgenticModel(
///   config: ClaudeAgenticConfig(apiKey: apiKey, model: 'claude-opus-5-5', maxTokens: 4096),
/// );
/// final answer = await model.generate(
///   [AgenticMessage.user("What's new in Dart?")],
///   options: const ClaudeAgenticOptions(serverTools: [
///     ClaudeServerToolConfig(webSearch20260209: ClaudeWebSearchTool20260209()),
///   ]).toOptions(),
/// );
/// ```
///
/// Failures are reported as `ClaudeException` (a `ChatModelException`,
/// classified for retry and failover as for the classic `ClaudeChatModel`),
/// a cancelled call as `CancelledException`. Unlike the Go SDK, the model
/// does not retry by itself.
final class ClaudeAgenticModel
    implements AgenticModel, TypedComponent, CallbackAwareComponent {
  /// A model with [config]; [httpClient] replaces the client it would create
  /// for itself.
  ///
  /// Throws an [ArgumentError] when `config.model` is empty ("model is
  /// required") or `config.maxTokens` is not above zero ("max_tokens must be
  /// positive"), as Go's `Config.check`. Registers the server tool types
  /// with `TypeRegistry` and `StreamConcat` (Go: `register.go`).
  ClaudeAgenticModel({required this.config, this.httpClient})
    : _http = SharedHttpClient(httpClient, owner: 'ClaudeAgenticModel') {
    if (config.model.isEmpty) {
      throw ArgumentError.value(
        config.model,
        'config.model',
        'model is required',
      );
    }
    if (config.maxTokens <= 0) {
      throw ArgumentError.value(
        config.maxTokens,
        'config.maxTokens',
        'max_tokens must be positive',
      );
    }
    ensureClaudeAgenticTypesRegistered();
  }

  /// The configuration.
  final ClaudeAgenticConfig config;

  /// The HTTP client requests are sent with (tests inject a fake).
  ///
  /// When omitted, the model creates one client on first use, reuses it for
  /// every request and closes it in [dispose].
  final http.Client? httpClient;

  final SharedHttpClient _http;

  /// Releases the HTTP client this model created for itself; using the
  /// model afterwards throws a [StateError]. A client passed as
  /// [httpClient] is left open.
  void dispose() => _http.close();

  /// Port of eino-ext agenticclaude `Model.GetType`: `AgenticClaude`.
  @override
  String get componentTypeName => claudeAgenticImplType;

  /// The model reports its calls to the callback handlers of
  /// `options.runContext` (and to the global ones) itself (Go:
  /// `IsCallbacksEnabled`).
  @override
  bool get isCallbacksEnabled => true;

  /// Port of eino-ext agenticclaude `Model.Generate`.
  ///
  /// The request is built before the start callback, so options the model
  /// does not take ([ArgumentError]) and input it cannot send
  /// ([ThreepioFormatException]) fail without callbacks, as in Go. As there,
  /// the errors of building the request (but not those of the classic
  /// `toolChoice` and `allowedToolNames`) say "generate request failed".
  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final callOptions = claudeAgenticCallOptions(config, options);
    final request = _request(input, callOptions, stream: false);
    return AgenticModelCallCallbacks.generate(
      callOptions,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      generate: () => _generate(request, callOptions),
    );
  }

  /// Port of eino-ext agenticclaude `Model.Stream`.
  ///
  /// Each chunk carries one content block with a `StreamingMeta` (or the
  /// response meta of `message_start` / `message_delta`); join them with
  /// `concatAgenticMessages`. A request that fails before the stream starts
  /// throws from this method; a failure later ends the stream with the
  /// error.
  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final callOptions = claudeAgenticCallOptions(config, options);
    final request = _request(input, callOptions, stream: true);
    return AgenticModelCallCallbacks.stream(
      callOptions,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      stream: () => _stream(request, callOptions),
    );
  }

  /// The request of a call, its errors worded as Go's: those of `getOptions`
  /// as they are, those of `genParamsAndOptions` after "generate request
  /// failed: ".
  ClaudeAgenticRequest _request(
    List<AgenticMessage> input,
    ChatModelOptions options, {
    required bool stream,
  }) {
    claudeAgenticCheckOptions(options);
    const failure = 'generate request failed';
    try {
      return buildClaudeAgenticRequest(config, input, options, stream: stream);
    } on ThreepioFormatException catch (error) {
      throw ThreepioFormatException(
        '$failure: ${error.message}',
        source: error.source,
        offset: error.offset,
        cause: error,
      );
      // A tool choice that does not fit the tools: the caller's mistake, an
      // ArgumentError as before, with Go's wording.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (error) {
      throw ArgumentError('$failure: ${error.message}');
    }
  }

  Future<AgenticMessage> _generate(
    ClaudeAgenticRequest request,
    ChatModelOptions options,
  ) async {
    // Outside the try: a body that cannot be encoded and a disposed model
    // are programming errors, not failed requests.
    final body = jsonEncode(request.body);
    final client = _http.client;
    final cancellation = CallCancellation.of(options);
    const failure = 'create message failed';
    try {
      final watch = Stopwatch()..start();
      final response = await _send(
        client,
        request,
        body,
        cancellation.token,
        failure,
      );
      final text = await _readBody(
        response,
        cancellation.token,
        request.timeout - watch.elapsed,
        request.timeout,
        failure,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _httpError(failure, response, text);
      }
      return _parseResponse(text);
    } finally {
      cancellation.release();
    }
  }

  static AgenticMessage _parseResponse(String body) {
    const failure = 'convert response to agentic message failed';
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException catch (error) {
      throw ClaudeException(
        '$failure: the response is not JSON: ${error.message}',
        responseBody: body,
        cause: error,
      );
    }
    if (json is! Map) {
      throw ClaudeException(
        '$failure: the response is not a JSON object',
        responseBody: body,
      );
    }
    try {
      return ClaudeAgenticBlockConverter().message(
        json.cast<String, Object?>(),
      );
    } on ThreepioFormatException catch (error) {
      throw ClaudeException(
        '$failure: ${error.message}',
        responseBody: body,
        cause: error,
      );
    }
  }

  Future<StreamReader<AgenticMessage>> _stream(
    ClaudeAgenticRequest request,
    ChatModelOptions options,
  ) async {
    final body = jsonEncode(request.body);
    final client = _http.client;
    final cancellation = CallCancellation.of(options);
    const failure = 'create message stream failed';
    var streaming = false;
    try {
      final watch = Stopwatch()..start();
      final response = await _send(
        client,
        request,
        body,
        cancellation.token,
        failure,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await _readBody(
          response,
          cancellation.token,
          request.timeout - watch.elapsed,
          request.timeout,
          failure,
        );
        throw _httpError(failure, response, text);
      }

      final (reader, writer) = pipe<AgenticMessage>();
      unawaited(
        _pump(
          response.stream,
          writer,
          cancellation.token,
        ).whenComplete(cancellation.release),
      );
      // From here on the stream releases the cancellation when it ends.
      streaming = true;
      return reader;
    } finally {
      if (!streaming) cancellation.release();
    }
  }

  /// Sends [request] and waits for the response headers.
  ///
  /// A header value HTTP cannot carry (an API key read from a file with its
  /// line break) fails the call with the header's name only, as Go's
  /// net/http does: dart:io's own error would quote the value, the key.
  static Future<http.StreamedResponse> _send(
    http.Client client,
    ClaudeAgenticRequest request,
    String body,
    CancelToken? cancelToken,
    String failure,
  ) async {
    for (final MapEntry(:key, :value) in request.headers.entries) {
      if (!_isValidHeaderValue(value)) {
        throw ClaudeException(
          '$failure: invalid header field value for "$key"',
        );
      }
    }
    try {
      return await sendStreamingRequest(
        client,
        request.url,
        headers: request.headers,
        body: body,
        timeout: request.timeout,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      throw ClaudeException(
        '$failure: request timed out after ${request.timeout}',
        isRetryable: true,
      );
    } on CancelledException {
      rethrow;
    } catch (error) {
      if (isInterrupt(error)) rethrow;
      throw ClaudeException(
        '$failure: $error',
        isRetryable: true,
        cause: error,
      );
    }
  }

  /// Whether [value] is a header value dart:io sends: visible ASCII, spaces
  /// and tabs (Go also refuses control characters and DEL).
  static bool _isValidHeaderValue(String value) {
    for (final unit in value.codeUnits) {
      if (unit != 0x09 && (unit < 0x20 || unit >= 0x7f)) return false;
    }
    return true;
  }

  /// Reads the body of [response] within [remaining], as UTF-8.
  ///
  /// When [cancelToken] fires or the time is up, the body subscription is
  /// cancelled, so an injected client stops reading, and the call fails
  /// with a `CancelledException` or a retryable [ClaudeException].
  static Future<String> _readBody(
    http.StreamedResponse response,
    CancelToken? cancelToken,
    Duration remaining,
    Duration timeout,
    String failure,
  ) {
    final completer = Completer<String>();
    final bytes = BytesBuilder(copy: false);
    Timer? timer;
    CallWatch? watch;
    late final StreamSubscription<List<int>> subscription;

    void finish({String? text, Object? error, StackTrace? stackTrace}) {
      if (completer.isCompleted) return;
      timer?.cancel();
      watch?.release();
      if (error != null) {
        unawaited(subscription.cancel());
        completer.completeError(error, stackTrace);
      } else {
        completer.complete(text);
      }
    }

    subscription = response.stream.listen(
      bytes.add,
      onError: (Object error, StackTrace stackTrace) {
        if (isInterrupt(error)) {
          finish(error: error, stackTrace: stackTrace);
          return;
        }
        finish(
          error: ClaudeException(
            '$failure: reading the response failed: $error',
            statusCode: response.statusCode,
            isRetryable: true,
            cause: error,
          ),
          stackTrace: stackTrace,
        );
      },
      onDone: () =>
          finish(text: utf8.decode(bytes.takeBytes(), allowMalformed: true)),
      cancelOnError: true,
    );
    timer = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () => finish(
        error: ClaudeException(
          '$failure: request timed out after $timeout',
          isRetryable: true,
        ),
      ),
    );
    if (cancelToken != null) {
      watch = CallWatch(cancelToken)
        ..onCancel(() => finish(error: CancelledException(cancelToken.reason)));
    }
    return completer.future;
  }

  /// The [ClaudeException] for an error response, its message prefixed
  /// with [failure] as Go wraps the SDK's error.
  static ClaudeException _httpError(
    String failure,
    http.StreamedResponse response,
    String body,
  ) {
    final error = ClaudeException.fromHttp(
      response.statusCode,
      body,
      headers: response.headers,
    );
    return ClaudeException(
      '$failure: ${error.message}',
      statusCode: error.statusCode,
      errorType: error.errorType,
      requestId: error.requestId,
      responseBody: error.responseBody,
      isRetryable: error.isRetryable,
      isModelUnavailable: error.isModelUnavailable,
    );
  }

  /// Reads the server-sent events of a stream into [writer].
  ///
  /// As eino-ext's stream goroutine over anthropic-sdk-go's decoder: an
  /// event ends at a blank line and its `data:` lines are joined with `\n`;
  /// `ping` and unknown events are skipped; an `error` event ends the stream
  /// with a [ClaudeException], as `stream.Err()` does; every chunk is sent
  /// as it comes. An event that cannot be converted ends the stream with
  /// "convert stream event to agentic message failed".
  Future<void> _pump(
    Stream<List<int>> bytes,
    StreamWriter<AgenticMessage> writer,
    CancelToken? cancelToken,
  ) {
    const failure = 'convert stream event to agentic message failed';
    final converter = ClaudeAgenticStreamConverter();
    final idleTimeout = config.idleTimeout;
    return pumpSse<AgenticMessage>(
      bytes: bytes,
      writer: writer,
      cancelToken: cancelToken,
      dispatchEachDataLine: false,
      idleTimeout: idleTimeout,
      idleError: () =>
          ClaudeException('stream idle for $idleTimeout', isRetryable: true),
      cancelledError: (token) => CancelledException(token.reason),
      streamError: (error) => isInterrupt(error)
          ? error
          : ClaudeException(
              'stream failed: $error',
              isRetryable: true,
              cause: error,
            ),
      onEvent: (event) {
        final data = event.data;
        Map<String, Object?>? json;
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map) json = decoded.cast<String, Object?>();
        } on FormatException {
          json = null;
        }
        final name = event.event ?? json?['type'];

        switch (name) {
          case 'ping':
            return PumpAction.next;
          case 'error':
            throw ClaudeException.fromStreamError(data);
          case 'message_start' ||
              'message_delta' ||
              'message_stop' ||
              'content_block_start' ||
              'content_block_delta' ||
              'content_block_stop':
            break;
          default:
            // Events anthropic-sdk-go's stream does not know are skipped.
            return PumpAction.next;
        }

        if (json == null) {
          throw ClaudeException(
            '$failure: the data of a $name event is not a JSON object',
            responseBody: data,
          );
        }
        final AgenticMessage? chunk;
        try {
          chunk = converter.convert(json);
        } on ThreepioFormatException catch (error) {
          throw ClaudeException(
            '$failure: ${error.message}',
            responseBody: data,
            cause: error,
          );
        }
        if (chunk != null) writer.send(chunk);
        return PumpAction.next;
      },
    );
  }
}
