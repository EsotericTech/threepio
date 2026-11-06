import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

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
import '../../openai_compatible/errors.dart';
import 'openai_config.dart';
import 'openai_options.dart';

/// OpenAI chat model implementation
///
/// Port of eino-ext `openai.NewChatModel` (over `libs/acl/openai`): OpenAI's
/// and Azure OpenAI's Chat Completions API, complete and streamed, with tool
/// calling (including `allowedToolNames`), structured output, reasoning
/// effort, log probabilities, audio output, usage in streams, cancellation,
/// and the payload and response modifiers of [OpenAIRequestOptions]. The
/// request settings are in [OpenAIConfig]; failures are [OpenAIException]s.
///
/// Example usage:
/// ```dart
/// final config = OpenAIConfig(apiKey: 'your-api-key');
/// final model = OpenAIChatModel(config: config);
///
/// final messages = [Message.user('Hello, how are you?')];
/// final response = await model.generate(messages);
/// print(response.content);
/// ```
class OpenAIChatModel extends ToolCallingChatModel
    implements TypedComponent, CallbackAwareComponent {
  OpenAIChatModel({
    required this.config,
    this.httpClient,
    this.tools,
  }) : _http = SharedHttpClient(httpClient, owner: 'OpenAIChatModel') {
    _client = _newClient();
  }

  /// A copy of [source] with [tools] bound, sharing its HTTP client.
  OpenAIChatModel._bound(OpenAIChatModel source, this.tools)
      : config = source.config,
        httpClient = source.httpClient,
        _http = source._http,
        _client = source._client;

  OpenAICompatibleClient _newClient() => OpenAICompatibleClient(
        http: _http,
        errors: const OpenAIExceptionErrors(),
        timeout: config.timeout,
        idleTimeout: config.idleTimeout,
        parser: OpenAICompatibleResponseParser(audioFormat: config.audio?.format),
        requestIdKey: openAIRequestIdKey,
      );

  /// OpenAI configuration
  final OpenAIConfig config;

  /// HTTP client for making requests.
  ///
  /// When omitted, the model creates one client on first use, reuses it for
  /// every request and closes it in [dispose].
  final http.Client? httpClient;

  /// Tools bound to this model instance
  final List<ToolInfo>? tools;

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
  String get componentTypeName => 'OpenAI';

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
    // Merge options with tools if bound
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
    // Get callback manager if available
    final callbackManager = mergedOptions.callbackManager as CallbackManager?;

    Future<Message> execute() async {
      final requestOptions = mergedOptions.extension<OpenAIRequestOptions>();
      final body = _buildRequestBody(
        input,
        mergedOptions,
        requestOptions,
        stream: false,
      );
      // One token for the call, whether it was given in the options, in the
      // run context or in both.
      final cancellation = CallCancellation.of(mergedOptions);
      try {
        return await _client.generate(
          _url(body),
          headers: _buildHeaders(requestOptions),
          body: body,
          input: input,
          cancelToken: cancellation.token,
          runContext: mergedOptions.runContext,
          payloadModifier: requestOptions?.requestPayloadModifier,
          responseModifier: requestOptions?.responseMessageModifier,
        );
      } finally {
        cancellation.release();
      }
    }

    if (callbackManager == null) return execute();

    final runInfo = RunInfo(
      name: 'OpenAIChatModel',
      type: 'OpenAIChatModel',
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
    // Merge options with tools if bound
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
    final requestOptions = mergedOptions.extension<OpenAIRequestOptions>();
    final body = _buildRequestBody(
      input,
      mergedOptions,
      requestOptions,
      stream: true,
    );
    final cancellation = CallCancellation.of(mergedOptions);
    var streaming = false;
    try {
      final reader = await _client.stream(
        _url(body),
        headers: _buildHeaders(requestOptions),
        body: body,
        input: input,
        cancellation: cancellation,
        runContext: mergedOptions.runContext,
        payloadModifier: requestOptions?.requestPayloadModifier,
        chunkModifier: requestOptions?.responseChunkMessageModifier,
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
    return OpenAIChatModel._bound(this, tools);
  }

  /// Merge options with bound tools
  ///
  /// The config's temperature, top-p and stop sequences are the defaults, so
  /// that the callbacks report the settings the request is made with (Go's
  /// `cbInput.Config`).
  ChatModelOptions _mergeOptions(ChatModelOptions? options) {
    final bound = tools;
    final base = ChatModelOptions(
      temperature: config.temperature,
      topP: config.topP,
      stop: config.stop,
      tools: bound == null || bound.isEmpty ? null : bound,
    );
    return base.merge(options);
  }

  OpenAIEndpoint get _endpoint => OpenAIEndpoint(
        baseUrl: config.baseUrl,
        byAzure: config.byAzure,
        apiVersion: config.apiVersion,
        azureModelMapper: config.azureModelMapper,
      );

  Uri _url(Map<String, Object?> body) =>
      _endpoint.url('/chat/completions', body['model']! as String);

  /// Build request body for API call
  Map<String, Object?> _buildRequestBody(
    List<Message> messages,
    ChatModelOptions options,
    OpenAIRequestOptions? requestOptions, {
    required bool stream,
  }) =>
      buildChatCompletionBody(
        input: messages,
        options: options,
        settings: OpenAIChatSettings(
          model: config.defaultModel,
          temperature: config.temperature,
          topP: config.topP,
          stop: config.stop,
          maxCompletionTokens: config.maxCompletionTokens,
          presencePenalty: config.presencePenalty,
          frequencyPenalty: config.frequencyPenalty,
          responseFormat: config.responseFormat,
          seed: config.seed,
          logitBias: config.logitBias,
          user: config.user,
          logProbs: config.logProbs,
          topLogProbs: config.topLogProbs,
          reasoningEffort: config.reasoningEffort,
          extraFields: config.extraFields,
          modalities: config.modalities,
          audio: config.audio,
        ),
        stream: stream,
        requestOptions: requestOptions,
      );

  /// Build request headers
  Map<String, String> _buildHeaders(OpenAIRequestOptions? requestOptions) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ..._endpoint.authHeaders(config.apiKey),
    };

    if (config.organization != null) {
      headers['OpenAI-Organization'] = config.organization!;
    }

    headers.addAll(requestOptions?.extraHeaders ?? config.customHeaders ?? {});
    return headers;
  }
}

/// How [OpenAIChatModel] and `OpenAICompatibleChatModel` report failures:
/// as [OpenAIException]s.
@internal
final class OpenAIExceptionErrors implements OpenAICompatibleErrors {
  /// The one instance.
  const OpenAIExceptionErrors();

  @override
  Object httpError(int statusCode, String body) =>
      OpenAIException.fromHttp(statusCode, body);

  @override
  Object timeout(Duration timeout) =>
      OpenAIException('Request timed out after $timeout', isRetryable: true);

  @override
  Object requestFailed(Object error, {required bool streaming}) =>
      OpenAIException(
        streaming ? 'Streaming request failed: $error' : 'Request failed: $error',
        isRetryable: true,
        cause: error,
      );

  @override
  Object streamIdle(Duration idleTimeout) =>
      OpenAIException('Stream idle for $idleTimeout', isRetryable: true);

  @override
  Object streamFailed(Object error) => OpenAIException(
        'Stream processing failed: $error',
        isRetryable: true,
        cause: error,
      );

  @override
  Object chunkFailed(Object error) => switch (error) {
        OpenAICompatibleChunkError(:final detail) => OpenAIException(
            error.message,
            errorCode: detail.code,
            isRetryable: _retryableCode(detail.code) ||
                detail.code == 'rate_limit_exceeded' ||
                detail.type == 'server_error' ||
                detail.type == 'rate_limit_error',
            isModelUnavailable: detail.code == 'model_not_found' ||
                looksLikeModelUnavailable(null, detail.message),
            cause: error,
          ),
        OpenAIException() => error,
        _ => OpenAIException(
            'failed to build message from stream chunk: $error',
            cause: error,
          ),
      };

  @override
  Object responseFailed(Object error) => switch (error) {
        OpenAIException() => error,
        FormatException(:final message) =>
          OpenAIException(message, cause: error),
        _ => OpenAIException('$error', cause: error),
      };

  static bool _retryableCode(Object? code) =>
      isRetryableHttpStatus(code is int ? code : int.tryParse('$code'));
}

/// OpenAI API exception
///
/// Classified for `RetryingChatModel` and `FailoverChatModel`: 408, 429 and
/// 5xx responses, timeouts and transport failures are retryable; a 404 or a
/// "model not found" message means the model is unavailable.
class OpenAIException implements ChatModelException {
  OpenAIException(
    this.message, {
    this.statusCode,
    this.response,
    this.errorCode,
    bool? isRetryable,
    bool? isModelUnavailable,
    this.cause,
  })  : isRetryable = isRetryable ?? isRetryableHttpStatus(statusCode),
        isModelUnavailable =
            isModelUnavailable ?? looksLikeModelUnavailable(statusCode, message);

  /// An exception for a response with [statusCode] and [body], classified.
  factory OpenAIException.fromHttp(int statusCode, String body) {
    final detail = ProviderErrorDetail.parse(body);
    return OpenAIException(
      'API request failed with status $statusCode: $body',
      statusCode: statusCode,
      response: body,
      errorCode: detail.code,
      isModelUnavailable: looksLikeModelUnavailable(statusCode, detail.message),
    );
  }

  @override
  final String message;
  final int? statusCode;
  final String? response;

  /// The `error.code` of the response, when the provider sent one.
  final Object? errorCode;

  @override
  final bool isRetryable;

  @override
  final bool isModelUnavailable;

  @override
  final Object? cause;

  @override
  String toString() =>
      'OpenAIException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}
