/// The Ollama chat model.
///
/// Port of eino-ext `components/model/ollama/chatmodel.go`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../core/interrupt_signal.dart';
import '../../../../internal/call_cancellation.dart';
import '../../../../internal/model_call_callbacks.dart';
import '../../../../internal/provider_http.dart';
import '../../../../internal/shared_http_client.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../../../streaming/stream_reader.dart';
import '../../../component_type.dart';
import '../../base_chat_model.dart';
import '../../cancel_token.dart';
import '../../chat_model_options.dart';
import '../../model_errors.dart';
import '../../openai_compatible/errors.dart';
import '../../openai_compatible/sse.dart';
import 'ollama_config.dart';
import 'ollama_converters.dart';
import 'ollama_options.dart';

/// A chat model served by Ollama (`POST /api/chat`).
///
/// Port of eino-ext `ollama.ChatModel` (`NewChatModel`, `Generate`,
/// `Stream`, `WithTools`, `GetType`, `IsCallbacksEnabled`). Streams are read
/// as NDJSON, one response object per line. The answer's thinking is the
/// message's `reasoningContent`, tool calls come with their arguments as a
/// JSON string, and the last response's metrics are in its `extra` (see
/// [OllamaMessageMetrics.ollamaMetrics]).
///
/// The `temperature`, `topP`, `stop` and `maxTokens` of a call's
/// [ChatModelOptions] override the [OllamaOptions] of the configuration;
/// [OllamaRequestOptions] in its extensions sets the seed. Ollama has no
/// tool choice: `toolChoice` is ignored, and `allowedToolNames` is rejected
/// as in Go.
///
/// ```dart
/// final model = OllamaChatModel(
///   config: const OllamaConfig(model: 'qwen3:8b'),
/// );
/// final answer = await model.generate([Message.user('Hello')]);
/// model.dispose();
/// ```
class OllamaChatModel extends ToolCallingChatModel
    implements TypedComponent, CallbackAwareComponent {
  /// A model configured by [config].
  ///
  /// [httpClient] replaces the client the model would create for itself
  /// (Go: `ChatModelConfig.HTTPClient`). Throws an [ArgumentError] when
  /// `config.baseUrl` is not a valid URL (Go: "invalid base URL").
  OllamaChatModel({required this.config, this.httpClient, this.tools})
      : _http = SharedHttpClient(httpClient, owner: 'OllamaChatModel'),
        _chatUrl = OllamaConverters.endpoint(config.baseUrl, '/api/chat');

  /// A copy of [source] with [tools] bound, sharing its HTTP client.
  OllamaChatModel._bound(OllamaChatModel source, this.tools)
      : config = source.config,
        httpClient = source.httpClient,
        _http = source._http,
        _chatUrl = source._chatUrl;

  /// The configuration.
  final OllamaConfig config;

  /// The HTTP client the requests are sent with (tests inject a fake).
  ///
  /// When omitted, the model creates one client on first use, reuses it for
  /// every request and closes it in [dispose].
  final http.Client? httpClient;

  /// The tools bound to this model, offered to it on every call that does
  /// not give its own `ChatModelOptions.tools`.
  final List<ToolInfo>? tools;

  final SharedHttpClient _http;
  final Uri _chatUrl;

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/x-ndjson',
  };

  /// Go's zero `Timeout` means no limit. The request helpers need a
  /// duration; 24 days stays below the longest timer every platform runs.
  static const Duration _noTimeout = Duration(days: 24);

  /// Releases the HTTP client this model created for itself.
  ///
  /// Call it when the model is no longer needed; using it afterwards throws
  /// a [StateError]. The client is shared with the models returned by
  /// [withTools], so they stop working as well. A client passed as
  /// [httpClient] is left open: whoever created it closes it.
  void dispose() => _http.close();

  /// `Ollama` (Go: `GetType`).
  @override
  String get componentTypeName => 'Ollama';

  /// The model reports its calls to the callback handlers of
  /// `options.runContext` (and to the global ones) itself (Go:
  /// `IsCallbacksEnabled`).
  @override
  bool get isCallbacksEnabled => true;

  /// Asks for the whole answer at once (`stream: false`).
  ///
  /// Port of `ChatModel.Generate`. A request that cannot be built (content
  /// Ollama cannot take, `allowedToolNames`) fails before the start
  /// callback, as in Go.
  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final merged = _mergeOptions(options);
    final body = _buildRequestBody(input, merged, stream: false);
    return ModelCallCallbacks.generate(
      merged,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      generate: () => _generate(body, merged),
      outputExtra: _metricsExtra,
    );
  }

  /// Streams the answer, one message per NDJSON line.
  ///
  /// Port of `ChatModel.Stream`. A request that cannot be built fails before
  /// the start callback. Unlike Go, which reports every failure through the
  /// stream, a request the server rejects or cannot be sent throws here, so
  /// that `RetryingChatModel` and `FailoverChatModel` can act on it; what
  /// goes wrong once the answer flows ends the stream with that error.
  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final merged = _mergeOptions(options);
    final body = _buildRequestBody(input, merged, stream: true);
    return ModelCallCallbacks.stream(
      merged,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      stream: () => _stream(body, merged),
      outputExtra: _metricsExtra,
    );
  }

  /// The callback output's `extra` for [message]: Ollama's metrics under
  /// [ollamaMetricsExtraKey], as eino-ext reports them
  /// (`model.CallbackOutput.Extra`), when the message carries them.
  static Map<String, Object?>? _metricsExtra(Message message) {
    final metrics = message.extra?[ollamaMetricsExtraKey];
    return metrics == null ? null : {ollamaMetricsExtraKey: metrics};
  }

  /// A copy of this model with [tools] bound, sharing its HTTP client.
  ///
  /// Port of `ChatModel.WithTools`. Go rejects an empty list; here it
  /// gives a copy without tools, as every threepio provider does, because
  /// the legacy agents bind the tools of an empty registry.
  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) =>
      OllamaChatModel._bound(this, tools);

  /// The options of a call on top of the defaults this model has: its
  /// model, its bound tools and the sampling options of the configuration
  /// (Go: the `model.Options` `genRequest` starts from).
  ///
  /// An empty stop list of the call does not replace the configured one:
  /// Go sends the configured stop sequences then (`len(Stop) > 0`) and
  /// reports what it sends, so the callbacks see them as well.
  ChatModelOptions _mergeOptions(ChatModelOptions? options) {
    final configured = config.options;
    final merged = ChatModelOptions(
      model: config.model,
      tools: tools,
      temperature: configured?.temperature,
      topP: configured?.topP,
      stop: configured?.stop,
      maxTokens: configured?.numPredict,
    ).merge(options);
    final callStop = options?.stop;
    if (callStop != null && callStop.isEmpty) {
      return merged.copyWith(stop: configured?.stop);
    }
    return merged;
  }

  /// The body of a `/api/chat` request (Go: `genRequest`).
  Map<String, Object?> _buildRequestBody(
    List<Message> input,
    ChatModelOptions options, {
    required bool stream,
  }) {
    final messages = OllamaConverters.messagesToOllama(input);

    final allowedToolNames = options.allowedToolNames;
    if (allowedToolNames != null && allowedToolNames.isNotEmpty) {
      throw ArgumentError.value(
        allowedToolNames,
        'allowedToolNames',
        'not supported by OllamaChatModel',
      );
    }

    final stop = options.stop;
    final seed = options.extension<OllamaRequestOptions>()?.seed;
    final modelOptions = <String, Object?>{
      ...?config.options?.toJson(),
      if (options.temperature != null) 'temperature': options.temperature,
      if (options.topP != null) 'top_p': options.topP,
      if (stop != null && stop.isNotEmpty) 'stop': [...stop],
      if (options.maxTokens != null) 'num_predict': options.maxTokens,
      if (seed != null) 'seed': seed,
    };

    final tools = options.tools;
    final format = config.format;
    final keepAlive = config.keepAlive;
    final thinking = config.thinking;
    return {
      'model': options.model ?? config.model,
      'messages': messages,
      'stream': stream,
      if (format != null) 'format': format.toJson(),
      if (keepAlive != null)
        'keep_alive': OllamaConverters.keepAliveToJson(keepAlive),
      if (tools != null && tools.isNotEmpty)
        'tools': OllamaConverters.toolsToOllama(tools),
      'options': modelOptions,
      if (thinking != null) 'think': thinking.toJson(),
    };
  }

  Future<Message> _generate(
    Map<String, Object?> body,
    ChatModelOptions options,
  ) async {
    final cancellation = CallCancellation.of(options);
    try {
      final response = await _send(body, cancellation.token);
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode >= 400) {
        throw OllamaException.fromHttp(response.statusCode, text);
      }
      return _parseResponse(text);
    } finally {
      cancellation.release();
    }
  }

  Future<StreamReader<Message>> _stream(
    Map<String, Object?> body,
    ChatModelOptions options,
  ) async {
    final cancellation = CallCancellation.of(options);
    var streaming = false;
    try {
      final response = await _sendStreaming(body, cancellation.token);
      if (response.statusCode >= 400) {
        throw OllamaException.fromHttp(
          response.statusCode,
          await _readBody(response),
        );
      }
      final (reader, writer) = pipe<Message>();
      unawaited(
        pumpLines<Message>(
          bytes: response.stream,
          writer: writer,
          onLine: (line) => _onStreamLine(line, writer),
          streamError: (error) => OllamaException(
            'Stream failed: $error',
            isRetryable: true,
            cause: error,
          ),
          cancelToken: cancellation.token,
          idleTimeout: config.idleTimeout,
          idleError: () => OllamaException(
            'Stream idle for ${config.idleTimeout}',
            isRetryable: true,
          ),
        ).whenComplete(cancellation.release),
      );
      // From here on the pump releases the cancellation, when it ends.
      streaming = true;
      return reader;
    } finally {
      if (!streaming) cancellation.release();
    }
  }

  /// One line of a streamed answer: a chunk, the last chunk (`done`) or an
  /// error.
  static PumpAction _onStreamLine(String line, StreamWriter<Message> writer) {
    // Ollama sends no blank lines; a proxy's keep-alive is skipped.
    if (line.trim().isEmpty) return PumpAction.next;
    final json = _decodeLine(line);
    final error = OllamaConverters.errorOf(json);
    if (error != null) throw OllamaException.fromStreamError(error);
    writer.send(OllamaConverters.responseToMessage(json));
    return json['done'] == true ? PumpAction.stop : PumpAction.next;
  }

  /// The answer of a request made with `stream: false`. The Go client reads
  /// it line by line as well, and the last response wins.
  static Message _parseResponse(String body) {
    Message? message;
    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isEmpty) continue;
      final json = _decodeLine(line);
      final error = OllamaConverters.errorOf(json);
      if (error != null) throw OllamaException.fromStreamError(error);
      message = OllamaConverters.responseToMessage(json);
    }
    if (message == null) {
      // Go returns a nil message without an error here.
      throw OllamaException('Ollama returned an empty response');
    }
    return message;
  }

  static Map<String, Object?> _decodeLine(String line) {
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException catch (error) {
      throw OllamaException(
        'Malformed Ollama response line: ${error.message}',
        cause: error,
      );
    }
    if (json is! Map) {
      throw OllamaException(
        'Malformed Ollama response line: not a JSON object',
      );
    }
    return json.cast<String, Object?>();
  }

  Future<http.Response> _send(
    Map<String, Object?> body,
    CancelToken? cancelToken,
  ) async {
    // Outside the try: using a disposed model is a programming error, not a
    // failed request.
    final client = _http.client;
    final timeout = config.timeout ?? _noTimeout;
    try {
      return await sendRequest(
        client,
        _chatUrl,
        headers: _headers,
        body: jsonEncode(body),
        timeout: timeout,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      throw OllamaException(
        'Request timed out after $timeout',
        isRetryable: true,
      );
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw OllamaException(
        'Request failed: $error',
        isRetryable: true,
        cause: error,
      );
    }
  }

  Future<http.StreamedResponse> _sendStreaming(
    Map<String, Object?> body,
    CancelToken? cancelToken,
  ) async {
    // Outside the try: using a disposed model is a programming error, not a
    // failed request.
    final client = _http.client;
    final timeout = config.timeout ?? _noTimeout;
    try {
      return await sendStreamingRequest(
        client,
        _chatUrl,
        headers: _headers,
        body: jsonEncode(body),
        timeout: timeout,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      throw OllamaException(
        'Request timed out after $timeout',
        isRetryable: true,
      );
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw OllamaException(
        'Streaming request failed: $error',
        isRetryable: true,
        cause: error,
      );
    }
  }

  /// The body of a failed streaming response, as far as it can be read.
  static Future<String> _readBody(http.StreamedResponse response) async {
    try {
      return utf8.decode(await response.stream.toBytes(), allowMalformed: true);
    } on Exception {
      return '';
    }
  }
}

/// A failed request to Ollama.
///
/// Port of the errors of the Ollama API client: `api.StatusError` (an HTTP
/// status with the server's `{"error": "..."}` message), the error line of
/// a stream, and transport failures. A rate limit, a timeout, a 5xx answer
/// and a failed connection are retryable; a 404 or a "model ... not found"
/// message means the model is not available (pull it, or use another one).
class OllamaException implements ChatModelException {
  /// An exception that says [message].
  OllamaException(
    this.message, {
    this.statusCode,
    this.response,
    this.cause,
    this.isRetryable = false,
    this.isModelUnavailable = false,
  });

  /// The exception for an answer with HTTP [statusCode] and [body].
  factory OllamaException.fromHttp(int statusCode, String body) {
    final detail = ProviderErrorDetail.parse(body).message;
    return OllamaException(
      'Ollama request failed with status $statusCode: $detail',
      statusCode: statusCode,
      response: body,
      isRetryable: isRetryableHttpStatus(statusCode),
      isModelUnavailable: _isModelUnavailable(statusCode, detail),
    );
  }

  /// The exception for the `error` a line of a response carried, with a
  /// successful HTTP status (Go: `errors.New(errorResponse.Error)`).
  factory OllamaException.fromStreamError(String error) => OllamaException(
        error,
        isModelUnavailable: _isModelUnavailable(null, error),
      );

  @override
  final String message;

  /// The HTTP status of the answer, when the server sent one.
  final int? statusCode;

  /// The body of the answer, when the server sent one.
  final String? response;

  @override
  final Object? cause;

  @override
  final bool isRetryable;

  @override
  final bool isModelUnavailable;

  static final RegExp _modelNotFound =
      RegExp(r'model\b.*\bnot found', caseSensitive: false);

  static bool _isModelUnavailable(int? statusCode, String message) =>
      looksLikeModelUnavailable(statusCode, message) ||
      _modelNotFound.hasMatch(message);

  @override
  String toString() => 'OllamaException: $message';
}
