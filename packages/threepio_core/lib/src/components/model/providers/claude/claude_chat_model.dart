/// The chat model of the Anthropic Messages API.
///
/// Port of eino-ext `components/model/claude` (`claude.go`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../core/interrupt_signal.dart';
import '../../../../errors.dart';
import '../../../../internal/call_cancellation.dart';
import '../../../../internal/model_call_callbacks.dart';
import '../../../../internal/provider_http.dart';
import '../../../../internal/shared_http_client.dart';
import '../../../../schema/message.dart';
import '../../../../schema/message_concat.dart';
import '../../../../schema/tool_info.dart';
import '../../../../streaming/stream_reader.dart';
import '../../../component_type.dart';
import '../../base_chat_model.dart';
import '../../cancel_token.dart';
import '../../chat_model_options.dart';
import '../../model_errors.dart';
import '../../openai_compatible/errors.dart';
import '../../openai_compatible/sse.dart';
import 'claude_config.dart';
import 'claude_converters.dart';

/// Claude, through the Anthropic Messages API (`POST {baseUrl}/v1/messages`).
///
/// Port of eino-ext `claude.ChatModel` (`claude.NewChatModel`), for the
/// direct Anthropic API; the Bedrock and Vertex transports are not ported.
/// It supports system messages, tool use (tool results with images and
/// files included), thinking with its signature sent back on the next turn,
/// cache breakpoints (per message, per tool and automatic), structured
/// output, server-side tool search for deferred tools, images and files
/// referenced by Files API id, and streaming.
///
/// Claude-specific settings are in the [ClaudeConfig] and, per call, in a
/// `ClaudeRequestOptions` passed in `ChatModelOptions.extensions`. The
/// thinking of a response is in `reasoningContent` and in
/// `message.claudeThinking`; see `ClaudeMessageExtras`.
///
/// ```dart
/// final model = ClaudeChatModel(
///   config: ClaudeConfig(apiKey: apiKey, model: 'claude-opus-5-5', maxTokens: 16000),
/// );
/// final answer = await model.generate([
///   Message.system('You are terse.'),
///   Message.user('Hello'),
/// ]);
/// ```
///
/// Failures are reported as [ClaudeException] (a `ChatModelException`), a
/// cancelled call as `CancelledException`. Unlike the Go SDK, the model does
/// not retry by itself: wrap it in a `RetryingChatModel`.
class ClaudeChatModel extends ToolCallingChatModel
    implements TypedComponent, CallbackAwareComponent {
  /// A model with [config]; [httpClient] replaces the client it would create
  /// for itself, [tools] are bound as by [withTools].
  ///
  /// Throws an [ArgumentError] when `config.model` is empty (Go:
  /// `NewChatModel`'s "no model specified").
  ClaudeChatModel({required this.config, this.httpClient, this.tools})
      : _http = SharedHttpClient(httpClient, owner: 'ClaudeChatModel') {
    if (config.model.isEmpty) {
      throw ArgumentError.value(
        config.model,
        'config.model',
        'no model specified',
      );
    }
  }

  /// A copy of [source] with [tools] bound, sharing its HTTP client.
  ClaudeChatModel._bound(ClaudeChatModel source, this.tools)
      : config = source.config,
        httpClient = source.httpClient,
        _http = source._http;

  /// The configuration.
  final ClaudeConfig config;

  /// The HTTP client requests are sent with (tests inject a fake).
  ///
  /// When omitted, the model creates one client on first use, reuses it for
  /// every request and closes it in [dispose].
  final http.Client? httpClient;

  /// The tools bound to this model, offered with the tool choice `allowed`
  /// unless a call chooses otherwise (Go: `WithTools`).
  final List<ToolInfo>? tools;

  final SharedHttpClient _http;

  /// Releases the HTTP client this model created for itself.
  ///
  /// Call it when the model is no longer needed; using it afterwards throws
  /// a [StateError]. The client is shared with the models returned by
  /// [withTools], so they stop working as well. A client passed as
  /// [httpClient] is left open: whoever created it closes it.
  void dispose() => _http.close();

  /// Port of eino-ext `ChatModel.GetType`.
  @override
  String get componentTypeName => 'Claude';

  /// The model reports its calls to the callback handlers of
  /// `options.runContext` (and to the global ones) itself, with the model
  /// configuration and the token usage (Go: `IsCallbacksEnabled`).
  @override
  bool get isCallbacksEnabled => true;

  /// A copy of this model with [tools] bound, sharing its HTTP client.
  ///
  /// Port of eino-ext `ChatModel.WithTools`: the tools are offered with the
  /// tool choice `allowed` (`auto`) unless a call chooses otherwise. Throws
  /// an [ArgumentError] for an empty list ("no tools to bind").
  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    if (tools.isEmpty) {
      throw ArgumentError.value(tools, 'tools', 'no tools to bind');
    }
    return ClaudeChatModel._bound(this, List.unmodifiable(tools));
  }

  /// Port of eino-ext `ChatModel.Generate`.
  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) {
    final callOptions = claudeCallOptions(config, tools, options);
    return ModelCallCallbacks.generate(
      callOptions,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      generate: () => _generate(input, callOptions),
    );
  }

  /// Port of eino-ext `ChatModel.Stream`.
  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) {
    final callOptions = claudeCallOptions(config, tools, options);
    return ModelCallCallbacks.stream(
      callOptions,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      stream: () => _stream(input, callOptions),
    );
  }

  Future<Message> _generate(
    List<Message> input,
    ChatModelOptions options,
  ) async {
    final request = buildClaudeRequest(config, input, options, stream: false);
    // Outside the try: a body that cannot be encoded and a disposed model
    // are programming errors, not failed requests.
    final body = jsonEncode(request.body);
    final client = _http.client;
    final cancellation = CallCancellation.of(options);
    try {
      final http.Response response;
      try {
        response = await sendRequest(
          client,
          request.url,
          headers: request.headers,
          body: body,
          timeout: request.timeout,
          cancelToken: cancellation.token,
        );
      } on TimeoutException {
        throw ClaudeException(
          'request timed out after ${request.timeout}',
          isRetryable: true,
        );
      } on CancelledException {
        rethrow;
      } catch (error) {
        if (isInterrupt(error)) rethrow;
        throw ClaudeException(
          'create new message fail: $error',
          isRetryable: true,
          cause: error,
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ClaudeException.fromHttp(
          response.statusCode,
          response.body,
          headers: response.headers,
        );
      }
      return _parseResponse(response.body);
    } finally {
      cancellation.release();
    }
  }

  static Message _parseResponse(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException catch (error) {
      throw ClaudeException(
        'convert response to schema message fail: the response is not '
        'JSON: ${error.message}',
        responseBody: body,
        cause: error,
      );
    }
    if (json is! Map) {
      throw ClaudeException(
        'convert response to schema message fail: the response is not a '
        'JSON object',
        responseBody: body,
      );
    }
    try {
      return claudeOutputMessage(json.cast<String, Object?>());
    } on ThreepioFormatException catch (error) {
      throw ClaudeException(
        'convert response to schema message fail: ${error.message}',
        responseBody: body,
        cause: error,
      );
    }
  }

  Future<StreamReader<Message>> _stream(
    List<Message> input,
    ChatModelOptions options,
  ) async {
    final request = buildClaudeRequest(config, input, options, stream: true);
    final body = jsonEncode(request.body);
    final client = _http.client;
    final cancellation = CallCancellation.of(options);
    var streaming = false;
    try {
      final http.StreamedResponse response;
      try {
        response = await sendStreamingRequest(
          client,
          request.url,
          headers: request.headers,
          body: body,
          timeout: request.timeout,
          cancelToken: cancellation.token,
        );
      } on TimeoutException {
        throw ClaudeException(
          'request timed out after ${request.timeout}',
          isRetryable: true,
        );
      } on CancelledException {
        rethrow;
      } catch (error) {
        if (isInterrupt(error)) rethrow;
        throw ClaudeException(
          'create new streaming message fail: $error',
          isRetryable: true,
          cause: error,
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String text;
        try {
          text = await response.stream.bytesToString();
        } catch (error) {
          if (isInterrupt(error)) rethrow;
          throw ClaudeException(
            'create new streaming message fail: status '
            '${response.statusCode}, body unreadable: $error',
            statusCode: response.statusCode,
            isRetryable: true,
            cause: error,
          );
        }
        throw ClaudeException.fromHttp(
          response.statusCode,
          text,
          headers: response.headers,
        );
      }

      final (reader, writer) = pipe<Message>();
      unawaited(
        _pump(response.stream, writer, cancellation.token)
            .whenComplete(cancellation.release),
      );
      // From here on the stream releases the cancellation when it ends.
      streaming = true;
      return reader;
    } finally {
      if (!streaming) cancellation.release();
    }
  }

  /// Reads the server-sent events of a stream into [writer].
  ///
  /// As eino-ext's stream goroutine over anthropic-sdk-go's decoder: an event
  /// ends at a blank line and its `data:` lines are joined with `\n`; chunks
  /// that carry nothing visible are held back and joined with the next one
  /// (or sent at the end); `ping` and unknown events are skipped. When the
  /// stream fails (an `error` event, data that is not JSON, a broken or idle
  /// body) or is cancelled, the held-back chunks are sent before the error,
  /// as Go sends its wait list before `stream.Err()`; when an event cannot be
  /// converted, they are dropped, as Go returns at once.
  Future<void> _pump(
    Stream<List<int>> bytes,
    StreamWriter<Message> writer,
    CancelToken? cancelToken,
  ) {
    final converter = ClaudeStreamConverter();
    final waiting = <Message>[];

    Message joined(List<Message> chunks) {
      if (chunks.length == 1) return chunks.single;
      try {
        return concatMessages(chunks);
      } on MessageConcatException catch (error) {
        throw ClaudeException(
          'concat empty message fail: ${error.message}',
          cause: error,
        );
      }
    }

    void flush() {
      if (waiting.isEmpty || writer.isClosed) {
        waiting.clear();
        return;
      }
      final chunks = [...waiting];
      waiting.clear();
      writer.send(joined(chunks));
    }

    // The held-back chunks, then [error]; when they cannot be joined, that
    // failure is the error instead, as in Go.
    Exception flushThen(Exception error) {
      try {
        flush();
      } on ClaudeException catch (concatError) {
        return concatError;
      }
      return error;
    }

    final idleTimeout = config.idleTimeout;
    return pumpSse<Message>(
      bytes: bytes,
      writer: writer,
      cancelToken: cancelToken,
      dispatchEachDataLine: false,
      idleTimeout: idleTimeout,
      idleError: () => flushThen(
        ClaudeException('stream idle for $idleTimeout', isRetryable: true),
      ),
      cancelledError: (token) => flushThen(CancelledException(token.reason)),
      streamError: (error) => flushThen(
        ClaudeException(
          'stream failed: $error',
          isRetryable: true,
          cause: error,
        ),
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
            throw flushThen(ClaudeException.fromStreamError(data));
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
          throw flushThen(
            ClaudeException(
              'convert response chunk to schema message fail: the data of '
              'a $name event is not a JSON object',
              responseBody: data,
            ),
          );
        }

        Message? message;
        try {
          message = converter.convert(json);
        } on ThreepioFormatException catch (error) {
          waiting.clear();
          throw ClaudeException(
            'convert response chunk to schema message fail: '
            '${error.message}',
            responseBody: data,
            cause: error,
          );
        }
        if (message == null) return PumpAction.next;
        if (isClaudeMessageEmpty(message)) {
          waiting.add(message);
          return PumpAction.next;
        }
        if (waiting.isNotEmpty) {
          final chunks = [...waiting, message];
          waiting.clear();
          message = joined(chunks);
        }
        writer.send(message);
        return PumpAction.next;
      },
      onComplete: flush,
    );
  }
}

/// A failed call of a [ClaudeChatModel].
///
/// Classified for `RetryingChatModel` and `FailoverChatModel`: as
/// anthropic-sdk-go decides whether to retry, 408, 409, 429 and 5xx (529
/// `overloaded_error` included) are retryable unless the response's
/// `x-should-retry` header says otherwise; timeouts, transport failures and
/// broken streams are retryable too. A 404 or a `not_found_error` (the API's
/// answer for an unknown model or one the account cannot use) means the
/// model is unavailable.
class ClaudeException implements ChatModelException {
  /// A failure described by [message].
  ClaudeException(
    this.message, {
    this.statusCode,
    this.errorType,
    this.requestId,
    this.responseBody,
    this.cause,
    this.isRetryable = false,
    this.isModelUnavailable = false,
  });

  /// The exception for a response with HTTP [statusCode] and [body].
  factory ClaudeException.fromHttp(
    int statusCode,
    String body, {
    Map<String, String> headers = const {},
  }) {
    final detail = ProviderErrorDetail.parse(body);
    final shouldRetry = _header(headers, 'x-should-retry');
    final retryable = switch (shouldRetry) {
      'true' => true,
      'false' => false,
      _ => isRetryableHttpStatus(statusCode) ||
          statusCode == 409 ||
          _isRetryableType(detail.type),
    };
    return ClaudeException(
      'API request failed with status $statusCode'
      '${detail.type == null ? '' : ' (${detail.type})'}: ${detail.message}',
      statusCode: statusCode,
      errorType: detail.type,
      requestId: _header(headers, 'request-id') ?? _requestId(body),
      responseBody: body,
      isRetryable: retryable,
      isModelUnavailable:
          statusCode == 404 || detail.type == 'not_found_error',
    );
  }

  /// The exception for an `error` event in a stream, whose data is [data]
  /// (`{"type": "error", "error": {"type": …, "message": …}}`).
  factory ClaudeException.fromStreamError(String data) {
    final detail = ProviderErrorDetail.parse(data);
    return ClaudeException(
      'received error while streaming'
      '${detail.type == null ? '' : ' (${detail.type})'}: ${detail.message}',
      errorType: detail.type,
      requestId: _requestId(data),
      responseBody: data,
      isRetryable: _isRetryableType(detail.type),
      isModelUnavailable: detail.type == 'not_found_error',
    );
  }

  @override
  final String message;

  /// The HTTP status of the response, when there was one.
  final int? statusCode;

  /// The Anthropic error type (`invalid_request_error`, `rate_limit_error`,
  /// `overloaded_error`, …), when the API named one.
  final String? errorType;

  /// The id of the request (the `request-id` header), for Anthropic support.
  final String? requestId;

  /// The body of the failed response or the data of the error event.
  final String? responseBody;

  @override
  final Object? cause;

  @override
  final bool isRetryable;

  @override
  final bool isModelUnavailable;

  /// Rate limited (HTTP 429, `rate_limit_error`).
  bool get isRateLimited =>
      statusCode == 429 || errorType == 'rate_limit_error';

  /// The API is overloaded (HTTP 529, `overloaded_error`).
  bool get isOverloaded =>
      statusCode == 529 || errorType == 'overloaded_error';

  static bool _isRetryableType(String? type) =>
      type == 'rate_limit_error' ||
      type == 'api_error' ||
      type == 'overloaded_error' ||
      type == 'timeout_error';

  static String? _header(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  static String? _requestId(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['request_id'] is String) {
        return json['request_id'] as String;
      }
    } on FormatException {
      // Not JSON.
    }
    return null;
  }

  @override
  String toString() => 'ClaudeException: $message'
      '${statusCode != null ? ' (status: $statusCode)' : ''}';
}
