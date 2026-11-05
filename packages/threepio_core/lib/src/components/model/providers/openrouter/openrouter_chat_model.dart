import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../callbacks/callback_manager.dart';
import '../../../../callbacks/run_info.dart';
import '../../../../internal/shared_http_client.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../../../streaming/stream_reader.dart';
import '../../../../streaming/stream_utils.dart';
import '../../../../streaming/stream_writer.dart';
import '../../base_chat_model.dart';
import '../../cancel_token.dart';
import '../../chat_model_options.dart';
import '../../model_errors.dart';
import '../openai/openai_converters.dart';
import 'openrouter_config.dart';
import 'openrouter_response_parser.dart';

/// OpenRouter chat model implementation
///
/// OpenRouter (https://openrouter.ai) is a unified API gateway that provides
/// access to multiple LLM providers through a single OpenAI-compatible
/// interface. This implementation supports text generation, streaming,
/// tool calling, reasoning (deltas and `reasoning_details` round trip),
/// image output via `modalities`, provider routing, structured output and
/// usage accounting with cost.
///
/// OpenRouter-specific request fields are expressed with
/// [OpenRouterRequestOptions] (see `openrouter_options.dart`), either as
/// `config.defaultRequestOptions` or per call through
/// `OpenRouterRequestOptions.applyTo(options)`.
///
/// Example usage:
/// ```dart
/// final model = OpenRouterChatModel(
///   config: OpenRouterConfig(apiKey: key, defaultModel: 'z-ai/glm-5.3'),
/// );
/// final reader = await model.stream(
///   [Message.user('Summarise this')],
///   options: const OpenRouterRequestOptions(
///     reasoningEffort: ReasoningEffort.low,
///   ).toOptions(),
/// );
/// ```
class OpenRouterChatModel extends ToolCallingChatModel {
  OpenRouterChatModel({
    required this.config,
    this.httpClient,
    this.tools,
    this.responseParser = const OpenRouterResponseParser(),
  }) : _http = SharedHttpClient(httpClient, owner: 'OpenRouterChatModel');

  /// A copy of [source] with [tools] bound, sharing its HTTP client.
  OpenRouterChatModel._bound(OpenRouterChatModel source, this.tools)
      : config = source.config,
        httpClient = source.httpClient,
        responseParser = source.responseParser,
        _http = source._http;

  /// OpenRouter configuration
  final OpenRouterConfig config;

  /// HTTP client for making requests (tests inject a fake).
  ///
  /// When omitted, the model creates one client on first use, reuses it for
  /// every request and closes it in [dispose].
  final http.Client? httpClient;

  /// Tools bound to this model instance
  final List<ToolInfo>? tools;

  /// Response parser for handling API responses
  final OpenRouterResponseParser responseParser;

  final SharedHttpClient _http;

  http.Client get _client => _http.client;

  /// Releases the HTTP client this model created for itself.
  ///
  /// Call it when the model is no longer needed; using it afterwards throws
  /// a [StateError]. The client is shared with the models returned by
  /// [withTools], so they stop working as well. A client passed as [httpClient] is left open: whoever created it
  /// closes it.
  void dispose() => _http.close();

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final mergedOptions = _mergeOptions(options);
    final callbackManager = mergedOptions.callbackManager as CallbackManager?;

    Future<Message> execute() async {
      final requestBody = _buildRequestBody(input, mergedOptions, stream: false);
      final response = await _makeRequest(requestBody, mergedOptions.cancelToken);
      return responseParser.parseCompletionResponse(response);
    }

    if (callbackManager == null) return execute();

    final runInfo = RunInfo(
      name: 'OpenRouterChatModel',
      type: 'OpenRouterChatModel',
      componentType: ComponentType.chatModel,
      metadata: {
        'model': mergedOptions.model ?? config.defaultModel,
        ...?mergedOptions.metadata,
      },
    );
    return callbackManager.runWithCallbacks(
      mergedOptions.getOrCreateContext(),
      runInfo,
      input,
      execute,
    );
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final mergedOptions = _mergeOptions(options);
    final requestBody = _buildRequestBody(input, mergedOptions, stream: true);
    return _makeStreamingRequest(requestBody, mergedOptions.cancelToken);
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    return OpenRouterChatModel._bound(this, tools);
  }

  /// Merge options with bound tools
  ChatModelOptions _mergeOptions(ChatModelOptions? options) {
    if (tools == null || tools!.isEmpty) {
      return options ?? const ChatModelOptions();
    }
    final baseOptions = ChatModelOptions(tools: tools);
    return options == null ? baseOptions : baseOptions.merge(options);
  }

  /// Build request body for API call
  Map<String, dynamic> _buildRequestBody(
    List<Message> messages,
    ChatModelOptions options, {
    required bool stream,
  }) {
    final body = <String, dynamic>{
      'model': options.model ?? config.defaultModel,
      'messages': messages.map(OpenAIConverters.messageToOpenAI).toList(),
      'stream': stream,
    };

    if (options.temperature != null) body['temperature'] = options.temperature;
    if (options.maxTokens != null) body['max_tokens'] = options.maxTokens;
    if (options.topP != null) body['top_p'] = options.topP;
    if (options.stop != null && options.stop!.isNotEmpty) {
      body['stop'] = options.stop;
    }

    if (options.tools != null && options.tools!.isNotEmpty) {
      body['tools'] =
          options.tools!.map(OpenAIConverters.toolInfoToOpenAI).toList();
      if (options.toolChoice != null) {
        body['tool_choice'] =
            OpenAIConverters.toolChoiceToOpenAI(options.toolChoice!);
      }
    }

    if (config.transforms != null) body['transforms'] = config.transforms;

    // Config-level OpenRouter fields first, per-call `extra` wins.
    body.addAll(config.defaultRequestOptions.toRequestFields());
    if (options.extra != null) body.addAll(options.extra!);

    return body;
  }

  /// Make a non-streaming API request
  Future<Map<String, dynamic>> _makeRequest(
    Map<String, dynamic> requestBody,
    CancelToken? cancelToken,
  ) async {
    cancelToken?.throwIfCancelled();
    final url = Uri.parse('${config.baseUrl}/chat/completions');

    // Outside the try: using a disposed model is a programming error,
    // not a failed request.
    final client = _client;

    try {
      final request = client.post(
        url,
        headers: _buildHeaders(),
        body: jsonEncode(requestBody),
      );
      final response = cancelToken == null
          ? await request.timeout(config.timeout)
          : await Future.any<http.Response>([
              request.timeout(config.timeout),
              cancelToken.whenCancelled.then(
                (_) => throw CancelledException(cancelToken.reason),
              ),
            ]);

      if (response.statusCode != 200) {
        throw OpenRouterException.fromHttp(response.statusCode, response.body);
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on TimeoutException {
      throw OpenRouterException(
        'Request timed out after ${config.timeout}',
        isRetryable: true,
      );
    } on CancelledException {
      rethrow;
    } on OpenRouterException {
      rethrow;
    } catch (e) {
      throw OpenRouterException('Request failed: $e', isRetryable: true);
    }
  }

  /// Make a streaming API request
  Future<StreamReader<Message>> _makeStreamingRequest(
    Map<String, dynamic> requestBody,
    CancelToken? cancelToken,
  ) async {
    cancelToken?.throwIfCancelled();
    final url = Uri.parse('${config.baseUrl}/chat/completions');

    // Outside the try: using a disposed model is a programming error,
    // not a failed request.
    final client = _client;

    try {
      final request = http.Request('POST', url)
        ..headers.addAll(_buildHeaders())
        ..body = jsonEncode(requestBody);

      final response = await client.send(request).timeout(config.timeout);

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw OpenRouterException.fromHttp(response.statusCode, body);
      }

      final (reader, writer) = pipe<Message>();
      unawaited(_processStream(response.stream, writer, cancelToken));
      return reader;
    } on TimeoutException {
      throw OpenRouterException(
        'Request timed out after ${config.timeout}',
        isRetryable: true,
      );
    } on OpenRouterException {
      rethrow;
    } catch (e) {
      throw OpenRouterException(
        'Streaming request failed: $e',
        isRetryable: true,
      );
    }
  }

  /// Process the SSE stream into message deltas.
  ///
  /// Stops on `[DONE]`, on a provider error chunk, when [cancelToken] fires,
  /// or when no chunk arrives within `config.idleTimeout`.
  Future<void> _processStream(
    Stream<List<int>> byteStream,
    StreamWriter<Message> writer,
    CancelToken? cancelToken,
  ) async {
    StreamSubscription<String>? subscription;
    final done = Completer<void>();
    Timer? idleTimer;

    void finish([Object? error]) {
      if (done.isCompleted) return;
      idleTimer?.cancel();
      if (error != null) writer.sendError(error);
      done.complete();
    }

    void armIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(config.idleTimeout, () {
        finish(
          OpenRouterException(
            'Stream idle for ${config.idleTimeout}',
            isRetryable: true,
          ),
        );
      });
    }

    final lines = byteStream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    subscription = lines.listen(
      (line) {
        armIdleTimer();
        if (!line.startsWith('data:')) return;
        final data = line.substring(5).trim();
        if (data.isEmpty) return;
        if (data == '[DONE]') {
          finish();
          return;
        }
        Map<String, dynamic> json;
        try {
          json = jsonDecode(data) as Map<String, dynamic>;
        } on FormatException {
          return; // partial/malformed line, skip
        }
        try {
          final message = responseParser.parseStreamChunk(json);
          if (message != null) writer.send(message);
        } on OpenRouterParseException catch (e) {
          finish(
            OpenRouterException(
              e.message,
              errorCode: e.code,
              isRetryable: _isRetryableCode(e.code),
              isModelUnavailable: _isModelUnavailable(e.code, e.message),
            ),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) => finish(
        OpenRouterException('Stream failed: $error', isRetryable: true),
      ),
      onDone: finish,
      cancelOnError: true,
    );
    armIdleTimer();

    final cancelFuture = cancelToken?.whenCancelled.then(
      (_) => finish(CancelledException(cancelToken.reason)),
    );

    await done.future;
    await subscription.cancel();
    cancelFuture?.ignore();
    await writer.close();
  }

  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${config.apiKey}',
    };
    if (config.siteUrl != null) headers['HTTP-Referer'] = config.siteUrl!;
    if (config.siteName != null) headers['X-Title'] = config.siteName!;
    return headers;
  }

  static bool _isRetryableCode(Object? code) {
    final c = code is int ? code : int.tryParse('$code');
    return c == 408 || c == 429 || (c != null && c >= 500);
  }

  static bool _isModelUnavailable(Object? code, String message) {
    final c = code is int ? code : int.tryParse('$code');
    final lower = message.toLowerCase();
    return c == 404 ||
        lower.contains('not a valid model') ||
        lower.contains('no endpoints found') ||
        lower.contains('model not found') ||
        lower.contains('not available');
  }
}

/// OpenRouter API exception
class OpenRouterException implements ChatModelException {
  OpenRouterException(
    this.message, {
    this.statusCode,
    this.response,
    this.errorCode,
    this.isRetryable = false,
    this.isModelUnavailable = false,
  });

  /// Builds an exception from a non-200 HTTP response, classifying it.
  factory OpenRouterException.fromHttp(int statusCode, String body) {
    String detail = body;
    Object? code;
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is Map) {
        final error = json['error'] as Map;
        detail = '${error['message'] ?? body}';
        code = error['code'];
      }
    } on FormatException {
      // keep raw body
    }
    final lower = detail.toLowerCase();
    return OpenRouterException(
      'API request failed with status $statusCode: $detail',
      statusCode: statusCode,
      response: body,
      errorCode: code,
      isRetryable: statusCode == 408 || statusCode == 429 || statusCode >= 500,
      isModelUnavailable: statusCode == 404 ||
          lower.contains('not a valid model') ||
          lower.contains('no endpoints found') ||
          lower.contains('model not found'),
    );
  }

  @override
  final String message;
  final int? statusCode;
  final String? response;

  /// Provider/OpenRouter error code when present.
  final Object? errorCode;

  /// Worth retrying with backoff (rate limit, upstream failure, timeout).
  @override
  final bool isRetryable;

  /// The requested model cannot be served (unknown id, no endpoints,
  /// region block); callers should fail over to another model.
  @override
  final bool isModelUnavailable;

  /// Rate limited by OpenRouter or the upstream provider.
  bool get isRateLimited => statusCode == 429 || errorCode == 429;

  /// The account has no credits.
  bool get isPaymentRequired => statusCode == 402 || errorCode == 402;

  @override
  String toString() =>
      'OpenRouterException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}
