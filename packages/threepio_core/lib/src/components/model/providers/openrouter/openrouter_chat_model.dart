import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../callbacks/callback_manager.dart';
import '../../../../callbacks/run_info.dart';
import '../../../../internal/call_cancellation.dart';
import '../../../../internal/model_call_callbacks.dart';
import '../../../../internal/shared_http_client.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../../../streaming/stream_reader.dart';
import '../../../component_type.dart';
import '../../base_chat_model.dart';
import '../../chat_model_options.dart';
import '../../model_errors.dart';
import '../../openai_compatible/client.dart';
import '../openai/openai_converters.dart';
import 'openrouter_cache_control.dart';
import 'openrouter_config.dart';
import 'openrouter_options.dart';
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
class OpenRouterChatModel extends ToolCallingChatModel
    implements TypedComponent, CallbackAwareComponent {
  OpenRouterChatModel({
    required this.config,
    this.httpClient,
    this.tools,
    this.responseParser = const OpenRouterResponseParser(),
  }) : _http = SharedHttpClient(httpClient, owner: 'OpenRouterChatModel') {
    _client = OpenAICompatibleClient(
      http: _http,
      errors: const _OpenRouterErrors(),
      timeout: config.timeout,
      idleTimeout: config.idleTimeout,
      parser: responseParser,
      // OpenRouter streams its chunks as they come, as it always has.
      mergeEmptyChunks: false,
    );
  }

  /// A copy of [source] with [tools] bound, sharing its HTTP client.
  OpenRouterChatModel._bound(OpenRouterChatModel source, this.tools)
      : config = source.config,
        httpClient = source.httpClient,
        responseParser = source.responseParser,
        _http = source._http,
        _client = source._client;

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

  late final OpenAICompatibleClient _client;

  /// Releases the HTTP client this model created for itself.
  ///
  /// Call it when the model is no longer needed; using it afterwards throws
  /// a [StateError]. The client is shared with the models returned by
  /// [withTools], so they stop working as well. A client passed as [httpClient] is left open: whoever created it
  /// closes it.
  void dispose() => _http.close();

  @override
  String get componentTypeName => 'OpenRouter';

  /// The model reports its calls to the callback handlers of
  /// `options.runContext` (and to the global ones) itself, with the model
  /// configuration and the token usage.
  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) {
    final mergedOptions = _mergeOptions(options);
    return ModelCallCallbacks.generate(
      mergedOptions,
      typeName: componentTypeName,
      defaultModel: config.defaultModel,
      input: input,
      generate: () => _generate(input, mergedOptions),
    );
  }

  /// One completion, reported to the `CallbackManager` of the older callback
  /// API when the options carry one.
  Future<Message> _generate(
    List<Message> input,
    ChatModelOptions mergedOptions,
  ) async {
    final callbackManager = mergedOptions.callbackManager as CallbackManager?;

    Future<Message> execute() async {
      final requestBody = _buildRequestBody(input, mergedOptions, stream: false);
      // One token for the call, whether it was given in the options, in the
      // run context or in both.
      final cancellation = CallCancellation.of(mergedOptions);
      try {
        return await _client.generate(
          _url,
          headers: _buildHeaders(),
          body: requestBody,
          input: input,
          cancelToken: cancellation.token,
          runContext: mergedOptions.runContext,
        );
      } finally {
        cancellation.release();
      }
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
  }) {
    final mergedOptions = _mergeOptions(options);
    return ModelCallCallbacks.stream(
      mergedOptions,
      typeName: componentTypeName,
      defaultModel: config.defaultModel,
      input: input,
      stream: () => _stream(input, mergedOptions),
    );
  }

  Future<StreamReader<Message>> _stream(
    List<Message> input,
    ChatModelOptions mergedOptions,
  ) async {
    final requestBody = _buildRequestBody(input, mergedOptions, stream: true);
    final cancellation = CallCancellation.of(mergedOptions);
    var streaming = false;
    try {
      final reader = await _client.stream(
        _url,
        headers: _buildHeaders(),
        body: requestBody,
        input: input,
        cancellation: cancellation,
        runContext: mergedOptions.runContext,
      );
      // From here on the stream releases the cancellation, when it ends.
      streaming = true;
      return reader;
    } finally {
      if (!streaming) cancellation.release();
    }
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
      'messages': [
        for (final message in messages)
          _withCacheControl(message, OpenAIConverters.messageToOpenAI(message)),
      ],
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
        final allowed = options.allowedToolNames ?? const <String>[];
        // Restricted to some tools: eino-ext's `allowed_tools` form.
        body['tool_choice'] = allowed.isEmpty
            ? OpenAIConverters.toolChoiceToOpenAI(options.toolChoice!)
            : openAIToolChoice(
                options.toolChoice!,
                allowedToolNames: allowed,
                toolNames: [for (final t in options.tools!) t.function.name],
              );
      }
    }

    if (config.transforms != null) body['transforms'] = config.transforms;

    // Config-level OpenRouter fields first, then the options of this call
    // given as an extension; per-call `extra` wins.
    body.addAll(config.defaultRequestOptions.toRequestFields());
    final requestOptions = options.extension<OpenRouterRequestOptions>();
    if (requestOptions != null) body.addAll(requestOptions.toRequestFields());
    if (options.extra != null) body.addAll(options.extra!);

    return body;
  }

  Uri get _url => Uri.parse('${config.baseUrl}/chat/completions');

  /// [wire] (the converted [message]) with the cache breakpoints of
  /// [message] and its parts, as eino-ext's OpenRouter payload modifier puts
  /// them: on content parts when there are parts, else on the message when it
  /// has plain content.
  static Map<String, dynamic> _withCacheControl(
    Message message,
    Map<String, dynamic> wire,
  ) {
    final userParts = message.userInputMultiContent ?? const [];
    final assistantParts = message.assistantGenMultiContent ?? const [];
    if (userParts.isNotEmpty) {
      final content = wire['content'];
      if (content is! List) return wire;
      for (var i = 0; i < userParts.length && i < content.length; i++) {
        final control = userParts[i].openRouterCacheControl;
        if (control != null) {
          content[i] = <String, dynamic>{
            ...content[i] as Map<String, dynamic>,
            'cache_control': control.toJson(),
          };
        }
      }
    } else if (assistantParts.isNotEmpty) {
      // OpenRouter sends an assistant message's plain content. Only when one
      // of its parts is a breakpoint are the parts sent, as eino-ext sends
      // them, so that the breakpoint has a place.
      if (!assistantParts.any((p) => p.openRouterCacheControl != null)) {
        return wire;
      }
      final parts = <Map<String, dynamic>>[
        if (message.content.isNotEmpty &&
            !assistantParts.any((p) => p.type == ChatMessagePartType.text))
          {'type': 'text', 'text': message.content},
        for (final part in assistantParts)
          if (_outputPartToWire(part) case final wirePart?)
            {
              ...wirePart,
              if (part.openRouterCacheControl case final control?)
                'cache_control': control.toJson(),
            },
      ];
      if (parts.isNotEmpty) wire['content'] = parts;
    } else if (message.content.isNotEmpty) {
      final control = message.openRouterCacheControl;
      if (control != null) wire['cache_control'] = control.toJson();
    }
    return wire;
  }

  /// An assistant output part as a content part, or `null` for kinds a
  /// content part cannot carry.
  static Map<String, dynamic>? _outputPartToWire(MessageOutputPart part) {
    switch (part.type) {
      case ChatMessagePartType.text:
        return {'type': 'text', 'text': part.text ?? ''};
      case ChatMessagePartType.imageUrl:
        final image = part.image;
        final url = image?.url ??
            (image?.base64Data != null && image?.mimeType != null
                ? 'data:${image!.mimeType};base64,${image.base64Data}'
                : null);
        if (url == null) return null;
        return {
          'type': 'image_url',
          'image_url': {'url': url},
        };
      default:
        return null;
    }
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

}

/// How [OpenRouterChatModel] reports failures: as [OpenRouterException]s,
/// with the texts and classification it always had.
final class _OpenRouterErrors implements OpenAICompatibleErrors {
  const _OpenRouterErrors();

  @override
  Object httpError(int statusCode, String body) =>
      OpenRouterException.fromHttp(statusCode, body);

  @override
  Object timeout(Duration timeout) =>
      OpenRouterException('Request timed out after $timeout', isRetryable: true);

  @override
  Object requestFailed(Object error, {required bool streaming}) =>
      OpenRouterException(
        streaming ? 'Streaming request failed: $error' : 'Request failed: $error',
        isRetryable: true,
        cause: error,
      );

  @override
  Object streamIdle(Duration idleTimeout) =>
      OpenRouterException('Stream idle for $idleTimeout', isRetryable: true);

  @override
  Object streamFailed(Object error) => OpenRouterException(
        'Stream failed: $error',
        isRetryable: true,
        cause: error,
      );

  @override
  Object chunkFailed(Object error) => switch (error) {
        OpenRouterParseException(:final message, :final code) =>
          OpenRouterException(
            message,
            errorCode: code,
            isRetryable: _isRetryableCode(code),
            isModelUnavailable: _isModelUnavailable(code, message),
            cause: error,
          ),
        _ => OpenRouterException('Invalid stream chunk: $error', cause: error),
      };

  /// What the parser throws for a complete response reaches the caller as it
  /// is, as it always did.
  @override
  Object responseFailed(Object error) => error;

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
    this.cause,
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

  /// The failure this exception reports, when there was one.
  @override
  final Object? cause;

  @override
  String toString() =>
      'OpenRouterException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}
