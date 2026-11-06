import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../../callbacks/callback_manager.dart';
import '../../../../callbacks/run_info.dart';
import '../../../../core/interrupt_signal.dart';
import '../../../../errors.dart';
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
import '../../openai_compatible/sse.dart';
import 'gemini_config.dart';
import 'gemini_converters.dart';
import 'gemini_errors.dart';
import 'gemini_message_extras.dart';
import 'gemini_options.dart';
import 'gemini_response_parser.dart';

export 'gemini_errors.dart' show GeminiException;

/// Google Gemini chat model implementation
///
/// Provides integration with Google's Gemini API, supporting
/// both streaming and non-streaming responses, multimodal content,
/// tool/function calling, and Imagen image generation.
///
/// Port of eino-ext `gemini.ChatModel` (`NewChatModel`, `Generate`,
/// `Stream`, `WithTools`, `CreatePrefixCache`) over the Gemini REST API:
/// thinking with thought summaries in `Message.reasoningContent` and thought
/// signatures kept and sent back, server tools (code execution, Google
/// Search, URL context, file search, Google Maps, computer use), cached
/// content, custom headers and extra body fields
/// ([GeminiRequestOptions]), structured output, log probabilities, and
/// cancellation through the options' cancel token or run context.
///
/// Example usage:
/// ```dart
/// final config = GeminiConfig(apiKey: 'your-api-key');
/// final model = GeminiChatModel(config: config);
///
/// final messages = [Message.user('Hello, how are you?')];
/// final response = await model.generate(messages);
/// print(response.content);
/// ```
///
/// Multimodal example:
/// ```dart
/// final response = await model.generate([
///   Message(
///     role: RoleType.user,
///     userInputMultiContent: [
///       MessageInputPart.text('What is in this image?'),
///       MessageInputPart.imageUrl('data:image/jpeg;base64,...'),
///     ],
///   ),
/// ]);
/// ```
///
/// Tool calling example:
/// ```dart
/// final toolModel = model.withTools([
///   ToolInfo.simple(
///     name: 'get_weather',
///     description: 'Get weather for a location',
///     properties: {'location': JSONSchemaProperty.string()},
///     required: ['location'],
///   ),
/// ]);
/// final response = await toolModel.generate([
///   Message.user('What is the weather in Tokyo?'),
/// ]);
/// ```
///
/// Thinking example:
/// ```dart
/// final reply = await model.generate(
///   messages,
///   options: GeminiRequestOptions(
///     thinkingConfig: const GeminiThinkingConfig(includeThoughts: true),
///   ).toOptions(),
/// );
/// print(reply.reasoningContent);
/// ```
///
/// Imagen image generation example:
/// ```dart
/// final imagenModel = GeminiChatModel(
///   config: GeminiConfig(
///     apiKey: 'your-api-key',
///     defaultModel: 'imagen-4.0-generate-001',
///   ),
/// );
///
/// final response = await imagenModel.generate(
///   [Message.user('A serene mountain landscape at sunset')],
///   options: ChatModelOptions(
///     extra: {
///       'numberOfImages': 2,
///       'aspectRatio': '16:9',
///       'personGeneration': 'dont_allow',
///     },
///   ),
/// );
/// // Images are in response.assistantGenMultiContent
/// ```
class GeminiChatModel extends ToolCallingChatModel
    implements TypedComponent, CallbackAwareComponent {
  GeminiChatModel({
    required this.config,
    this.httpClient,
    this.tools,
  }) : _http = SharedHttpClient(httpClient, owner: 'GeminiChatModel');

  /// A copy of [source] with [tools] bound, sharing its HTTP client.
  GeminiChatModel._bound(GeminiChatModel source, this.tools)
      : config = source.config,
        httpClient = source.httpClient,
        _http = source._http;

  /// Gemini configuration
  final GeminiConfig config;

  /// HTTP client for making requests.
  ///
  /// When omitted, the model creates one client on first use, reuses it for
  /// every request and closes it in [dispose].
  final http.Client? httpClient;

  /// Tools bound to this model instance
  final List<ToolInfo>? tools;

  /// Response parser
  final _responseParser = const GeminiResponseParser();

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
  String get componentTypeName => 'Gemini';

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
    final model = mergedOptions.model ?? config.defaultModel;

    // Check if this is an Imagen model
    if (_isImagenModel(model)) {
      return _generateWithImagen(input, mergedOptions, model);
    }

    if (input.isEmpty) {
      throw ArgumentError.value(input, 'input', 'gemini input is empty');
    }

    Future<Message> execute() async {
      final requestBody = _buildRequestBody(input, mergedOptions);
      // One token for the call, whether it was given in the options, in the
      // run context or in both.
      final cancellation = CallCancellation.of(mergedOptions);
      try {
        final response = await _post(
          Uri.parse(
            '${config.baseUrl}/${_modelResource(model)}:generateContent',
          ),
          requestBody,
          headers: mergedOptions.extension<GeminiRequestOptions>()?.customHeaders,
          cancelToken: cancellation.token,
        );
        return _responseParser.parseCompletionResponse(response);
      } finally {
        cancellation.release();
      }
    }

    // Get callback manager if available
    final callbackManager = mergedOptions.callbackManager as CallbackManager?;
    if (callbackManager == null) return execute();

    // Execute with callbacks
    final runInfo = RunInfo(
      name: 'GeminiChatModel',
      type: 'GeminiChatModel',
      componentType: ComponentType.chatModel,
      metadata: {
        'model': model,
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

  /// Opens the stream of one call.
  ///
  /// Every `data:` line of the response is one `GenerateContentResponse`
  /// and becomes one message, as each chunk does in Go's `Stream`. The
  /// stream ends with a [CancelledException] when the call is cancelled,
  /// with a [GeminiException] for an error chunk or a failed body, with a
  /// [GeminiParseException] when the prompt was blocked, and with a
  /// [ThreepioFormatException] for a chunk that is not JSON.
  Future<StreamReader<Message>> _stream(
    List<Message> input,
    ChatModelOptions mergedOptions,
  ) async {
    if (input.isEmpty) {
      throw ArgumentError.value(input, 'input', 'gemini input is empty');
    }
    final model = mergedOptions.model ?? config.defaultModel;
    final body = _buildRequestBody(input, mergedOptions);
    final cancellation = CallCancellation.of(mergedOptions);
    var streaming = false;
    try {
      final response = await _openStream(
        Uri.parse(
          '${config.baseUrl}/${_modelResource(model)}'
          ':streamGenerateContent?alt=sse',
        ),
        body,
        headers: mergedOptions.extension<GeminiRequestOptions>()?.customHeaders,
        cancelToken: cancellation.token,
      );

      final (reader, writer) = pipe<Message>();
      var nextPartIndex = 0;
      String? pendingSignature;
      unawaited(
        pumpSse<Message>(
          bytes: response.stream,
          writer: writer,
          cancelToken: cancellation.token,
          streamError: (error) => GeminiException(
            'Stream processing failed: $error',
            cause: error,
            isRetryable: true,
            isModelUnavailable: false,
          ),
          onEvent: (event) {
            final data = event.data.trim();
            if (data.isEmpty) return PumpAction.next;
            if (data == '[DONE]') return PumpAction.stop;
            var message = _parseStreamChunk(data);
            if (message == null) return PumpAction.next;
            // The thought signature of the text is held back until the chunk
            // that ends the response: `concatMessages` joins the strings of
            // `extra`, and two signatures joined are no signature at all.
            final signature = message.extra?[geminiThoughtSignatureKey];
            if (signature is String) {
              pendingSignature = signature;
              final rest = {...message.extra!}..remove(geminiThoughtSignatureKey);
              message = message.copyWith(extra: rest.isEmpty ? null : rest);
            }
            if (pendingSignature != null &&
                message.responseMeta?.finishReason != null) {
              message = message.copyWith(
                extra: {
                  ...?message.extra,
                  geminiThoughtSignatureKey: pendingSignature,
                },
              );
              pendingSignature = null;
            }
            if (!_isEmptyChunk(message)) {
              writer.send(_indexSpecialParts(message, () => nextPartIndex++));
            }
            return PumpAction.next;
          },
        ).whenComplete(cancellation.release),
      );
      // From here on the stream releases the cancellation, when it ends.
      streaming = true;
      return reader;
    } finally {
      if (!streaming) cancellation.release();
    }
  }

  /// The message of one `data:` line, or `null` when the chunk has none.
  Message? _parseStreamChunk(String data) {
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'malformed Gemini stream chunk: ${error.message}',
        source: data,
        cause: error,
      );
    }
    if (json is! Map<String, dynamic>) {
      throw ThreepioFormatException(
        'malformed Gemini stream chunk: not a JSON object',
        source: data,
      );
    }

    final error = json['error'];
    if (error is Map) {
      final code = error['code'];
      throw GeminiException(
        '${error['message'] ?? 'Unknown error'}',
        code: code is int ? code : int.tryParse('$code'),
        status: error['status'] is String ? error['status'] as String : null,
      );
    }

    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      final feedback = json['promptFeedback'];
      final blockReason = feedback is Map ? feedback['blockReason'] : null;
      if (blockReason is String) {
        throw GeminiParseException(
          'Content blocked: $blockReason',
          blockReason: blockReason,
        );
      }
      final usage = json['usageMetadata'];
      return usage is Map<String, dynamic>
          ? Message(
              role: RoleType.assistant,
              responseMeta:
                  ResponseMeta(usage: GeminiConverters.usageToSchema(usage)),
            )
          : null;
    }
    final candidate = candidates.first;
    if (candidate is! Map<String, dynamic>) return null;
    return GeminiConverters.geminiChunkToMessage(
      candidate,
      usageMetadata: json['usageMetadata'] as Map<String, dynamic>?,
    );
  }

  /// Whether a streamed chunk carries nothing at all.
  static bool _isEmptyChunk(Message message) =>
      message.content.isEmpty &&
      (message.reasoningContent?.isEmpty ?? true) &&
      message.toolCalls == null &&
      message.assistantGenMultiContent == null &&
      message.responseMeta == null &&
      message.extra == null;

  /// Gives each code execution part of a streamed chunk a position of its
  /// own, so that `concatMessages` keeps the parts apart instead of joining
  /// neighbouring text parts.
  static Message _indexSpecialParts(Message message, int Function() next) {
    final parts = message.assistantGenMultiContent;
    if (parts == null ||
        !parts.any((part) => part.extra?[geminiSpecialPartKey] != null)) {
      return message;
    }
    return message.copyWith(
      assistantGenMultiContent: [
        for (final part in parts)
          if (part.extra?[geminiSpecialPartKey] == null)
            part
          else
            part.copyWith(streamingMeta: MessageStreamingMeta(index: next())),
      ],
    );
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    return GeminiChatModel._bound(this, tools);
  }

  /// Creates a prefix cache from [prefixMessages] and the request settings,
  /// to be used by later calls through
  /// `GeminiRequestOptions.cachedContentName`.
  ///
  /// Port of eino-ext `ChatModel.CreatePrefixCache`: the messages are
  /// assembled as `generate` assembles them, and the system instruction, the
  /// tools, the tool config and the contents are written into a cached
  /// content (`POST {baseUrl}/cachedContents`) that lives as
  /// `GeminiConfig.cache` says. Custom headers and extra fields are not
  /// sent, as in Go.
  Future<GeminiCachedContent> createPrefixCache(
    List<Message> prefixMessages, {
    ChatModelOptions? options,
  }) async {
    final mergedOptions = _mergeOptions(options);
    final model = mergedOptions.model ?? config.defaultModel;
    final request =
        _buildRequestBody(prefixMessages, mergedOptions, forCache: true);
    final contents = request['contents'] as List<Object?>;
    final ttl = config.cache?.ttl;
    final expireTime = config.cache?.expireTime;
    final body = <String, dynamic>{
      'model': _modelResource(model),
      if (contents.isNotEmpty) 'contents': contents,
      if (request['systemInstruction'] != null)
        'systemInstruction': request['systemInstruction'],
      if (request['tools'] != null) 'tools': request['tools'],
      if (request['toolConfig'] != null) 'toolConfig': request['toolConfig'],
      if (ttl != null && ttl != Duration.zero)
        'ttl': '${(ttl.inMicroseconds / Duration.microsecondsPerSecond).round()}s',
      if (expireTime != null) 'expireTime': expireTime.toUtc().toIso8601String(),
    };
    final cancellation = CallCancellation.of(mergedOptions);
    try {
      final response = await _post(
        Uri.parse('${config.baseUrl}/cachedContents'),
        body,
        cancelToken: cancellation.token,
      );
      return GeminiCachedContent.fromJson(response);
    } finally {
      cancellation.release();
    }
  }

  /// Merge options with bound tools
  ///
  /// The defaults of [config] (temperature, max tokens, top-p) go first, the
  /// bound tools with [ToolChoice.allowed] (as Go's `WithTools` binds them),
  /// then what the call sets.
  ChatModelOptions _mergeOptions(ChatModelOptions? options) {
    final hasTools = tools != null && tools!.isNotEmpty;
    if (!hasTools &&
        config.temperature == null &&
        config.maxTokens == null &&
        config.topP == null) {
      return options ?? const ChatModelOptions();
    }

    final baseOptions = ChatModelOptions(
      temperature: config.temperature,
      maxTokens: config.maxTokens,
      topP: config.topP,
      tools: hasTools ? tools : null,
      toolChoice: hasTools ? ToolChoice.allowed : null,
    );
    return options == null ? baseOptions : baseOptions.merge(options);
  }

  /// Build request body for API call
  ///
  /// Port of eino-ext `genInputAndConf` (with the REST mapping the genai SDK
  /// applies): the options of the call win over [config]; the
  /// [GeminiRequestOptions] of the call win over the older allow-listed
  /// `extra` keys (`topK`, `candidateCount`, `responseMimeType`,
  /// `responseSchema`, `responseModalities`, `safetySettings`), which win over
  /// [config]. Extra fields are merged last.
  Map<String, dynamic> _buildRequestBody(
    List<Message> messages,
    ChatModelOptions options, {
    bool forCache = false,
  }) {
    final requestOptions = options.extension<GeminiRequestOptions>();
    final extra = options.extra;

    // Extract system instruction and filter messages
    final (systemInstruction, filteredMessages) =
        GeminiConverters.extractSystemInstruction(messages);

    final body = <String, dynamic>{
      'contents': GeminiConverters.messagesToGemini(filteredMessages),
    };

    // Add system instruction if present
    if (systemInstruction != null) {
      body['systemInstruction'] = {
        'parts': [
          {'text': systemInstruction}
        ],
      };
    }

    // Build generation config
    final generationConfig = <String, dynamic>{};
    if (options.temperature != null) {
      generationConfig['temperature'] = options.temperature;
    }
    if (options.maxTokens != null) {
      generationConfig['maxOutputTokens'] = options.maxTokens;
    }
    if (options.topP != null) {
      generationConfig['topP'] = options.topP;
    }
    if (options.stop != null && options.stop!.isNotEmpty) {
      generationConfig['stopSequences'] = options.stop;
    }
    final topK = requestOptions?.topK ?? extra?['topK'] ?? config.topK;
    if (topK != null) generationConfig['topK'] = topK;

    // Handle extra options for Gemini-specific settings
    if (extra != null) {
      if (extra['candidateCount'] != null) {
        generationConfig['candidateCount'] = extra['candidateCount'];
      }
      if (extra['responseMimeType'] != null) {
        generationConfig['responseMimeType'] = extra['responseMimeType'];
      }
      if (extra['responseSchema'] != null) {
        generationConfig['responseSchema'] = extra['responseSchema'];
      }
    }

    final responseJsonSchema =
        requestOptions?.responseJsonSchema ?? config.responseJsonSchema;
    if (responseJsonSchema != null) {
      generationConfig['responseMimeType'] = 'application/json';
      generationConfig['responseJsonSchema'] = responseJsonSchema;
    }

    // Image generation support
    final modalities = requestOptions?.responseModalities;
    if (modalities != null && modalities.isNotEmpty) {
      generationConfig['responseModalities'] =
          modalities.map((m) => m.wireValue).toList();
    } else if (extra?['responseModalities'] != null) {
      generationConfig['responseModalities'] = extra!['responseModalities'];
    } else if (config.responseModalities?.isNotEmpty ?? false) {
      generationConfig['responseModalities'] =
          config.responseModalities!.map((m) => m.wireValue).toList();
    }

    if (config.mediaResolution != null) {
      generationConfig['mediaResolution'] = config.mediaResolution!.wireValue;
    }
    final thinkingConfig =
        requestOptions?.thinkingConfig ?? config.thinkingConfig;
    if (thinkingConfig != null) {
      generationConfig['thinkingConfig'] = thinkingConfig.toJson();
    }
    final imageConfig = requestOptions?.imageConfig ?? config.imageConfig;
    if (imageConfig != null) {
      generationConfig['imageConfig'] = imageConfig.toJson();
    }
    if (requestOptions?.responseLogprobs ?? config.responseLogprobs) {
      generationConfig['responseLogprobs'] = true;
    }
    final logprobs = requestOptions?.logprobs ?? config.logprobs;
    if (logprobs != null) generationConfig['logprobs'] = logprobs;

    if (generationConfig.isNotEmpty) {
      body['generationConfig'] = generationConfig;
    }

    // Function declarations first, then the server tools, in Go's order.
    final tools = <Map<String, dynamic>>[
      if (options.tools != null && options.tools!.isNotEmpty)
        {
          'functionDeclarations':
              options.tools!.map(GeminiConverters.toolInfoToGemini).toList(),
        },
      if (config.enableCodeExecution) {'codeExecution': <String, Object?>{}},
      if (config.enableGoogleSearch != null)
        {'googleSearch': config.enableGoogleSearch!.toJson()},
      if (config.enableGoogleSearchRetrieval != null)
        {'googleSearchRetrieval': config.enableGoogleSearchRetrieval!.toJson()},
      if (config.enableComputerUse != null)
        {'computerUse': config.enableComputerUse!.toJson()},
      if (config.enableUrlContext != null)
        {'urlContext': config.enableUrlContext!.toJson()},
      if (config.enableFileSearch != null)
        {'fileSearch': config.enableFileSearch!.toJson()},
      if (config.enableGoogleMaps != null)
        {'googleMaps': config.enableGoogleMaps!.toJson()},
    ];
    if (tools.isNotEmpty) body['tools'] = tools;

    // Validated as Go's populateToolChoice validates it, but only sent with
    // function declarations: the API rejects a function calling config
    // without them (and threepio never sent one).
    final toolConfig = GeminiConverters.toolConfigToGemini(
      options.toolChoice,
      allowedToolNames: options.allowedToolNames,
      tools: tools,
    );
    if (toolConfig != null && (options.tools?.isNotEmpty ?? false)) {
      body['toolConfig'] = toolConfig;
    }

    // Add safety settings if provided
    final safetySettings = extra?['safetySettings'] ??
        ((config.safetySettings?.isNotEmpty ?? false)
            ? config.safetySettings!.map((s) => s.toJson()).toList()
            : null);
    if (safetySettings != null) body['safetySettings'] = safetySettings;

    final labels = requestOptions?.labels;
    if (labels != null && labels.isNotEmpty) {
      // This model talks to the Gemini API, which rejects labels.
      throw ArgumentError.value(
        labels,
        'labels',
        'labels are only supported on the Vertex AI backend',
      );
    }

    final cachedContentName = requestOptions?.cachedContentName;
    if (cachedContentName != null && cachedContentName.isNotEmpty) {
      body['cachedContent'] = _cachedContentResource(cachedContentName);
      // The system instruction and the tools are part of the cache.
      body
        ..remove('systemInstruction')
        ..remove('tools')
        ..remove('toolConfig');
    }

    final extraFields = requestOptions?.extraFields;
    if (forCache || extraFields == null) return body;
    return _mergeJson(body, extraFields);
  }

  /// The resource name of [model] (`models/…`), as genai's `tModel` writes
  /// it for the Gemini API.
  static String _modelResource(String model) =>
      model.startsWith('models/') || model.startsWith('tunedModels/')
          ? model
          : 'models/$model';

  /// The resource name of a cached content, as genai's
  /// `tCachedContentName` writes it for the Gemini API.
  static String _cachedContentResource(String name) =>
      name.contains('/') ? name : 'cachedContents/$name';

  /// [extra] merged into [base], maps recursively and the values of [extra]
  /// winning: what genai's `recursiveMapMerge` does with `ExtraBody`. Neither
  /// argument is changed.
  static Map<String, dynamic> _mergeJson(
    Map<String, dynamic> base,
    Map<String, Object?> extra,
  ) {
    final result = Map<String, dynamic>.of(base);
    extra.forEach((key, value) {
      final existing = result[key];
      result[key] = existing is Map && value is Map
          ? _mergeJson(
              Map<String, dynamic>.from(existing),
              Map<String, Object?>.from(value),
            )
          : value;
    });
    return result;
  }

  /// Sends [body] to [url] and returns the JSON of the response.
  ///
  /// Throws a [CancelledException] when [cancelToken] fires first, and a
  /// [GeminiException] for an error response, a timeout or a failed
  /// transport (the last two retryable).
  Future<Map<String, dynamic>> _post(
    Uri url,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final encoded = jsonEncode(body);

    // Outside the try: using a disposed model is a programming error,
    // not a failed request.
    final client = _client;

    final http.Response response;
    try {
      response = await sendRequest(
        client,
        url,
        headers: _buildHeaders(headers),
        body: encoded,
        timeout: config.timeout,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      throw GeminiException(
        'Request timed out after ${config.timeout}',
        isRetryable: true,
        isModelUnavailable: false,
      );
    } on CancelledException {
      rethrow;
    } catch (error) {
      if (isInterrupt(error)) rethrow;
      throw GeminiException(
        'Request failed: $error',
        cause: error,
        isRetryable: true,
        isModelUnavailable: false,
      );
    }

    if (response.statusCode != 200) {
      throw GeminiException.fromHttp(response.statusCode, response.body);
    }
    try {
      final json = jsonDecode(response.body);
      if (json is Map<String, dynamic>) return json;
    } on FormatException catch (error) {
      throw GeminiException(
        'Response is not JSON: ${error.message}',
        statusCode: response.statusCode,
        cause: error,
      );
    }
    throw GeminiException(
      'Response is not a JSON object',
      statusCode: response.statusCode,
    );
  }

  /// Sends [body] to [url] and returns the response once its headers are
  /// there; the body is left to the caller. Throws like [_post].
  Future<http.StreamedResponse> _openStream(
    Uri url,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final encoded = jsonEncode(body);

    // Outside the try: using a disposed model is a programming error,
    // not a failed request.
    final client = _client;

    final http.StreamedResponse response;
    try {
      response = await sendStreamingRequest(
        client,
        url,
        headers: _buildHeaders(headers),
        body: encoded,
        timeout: config.timeout,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      throw GeminiException(
        'Request timed out after ${config.timeout}',
        isRetryable: true,
        isModelUnavailable: false,
      );
    } on CancelledException {
      rethrow;
    } catch (error) {
      if (isInterrupt(error)) rethrow;
      throw GeminiException(
        'Streaming request failed: $error',
        cause: error,
        isRetryable: true,
        isModelUnavailable: false,
      );
    }

    if (response.statusCode != 200) {
      final String errorBody;
      try {
        errorBody = await response.stream.bytesToString();
      } catch (error) {
        throw GeminiException(
          'API request failed with status ${response.statusCode}',
          statusCode: response.statusCode,
          cause: error,
        );
      }
      throw GeminiException.fromHttp(response.statusCode, errorBody);
    }
    return response;
  }

  /// Build request headers
  ///
  /// [custom] headers go first; the headers the model manages win over them
  /// (the request's header map ignores case). As in the genai SDK, the API
  /// key header is only sent when there is a key.
  Map<String, String> _buildHeaders([Map<String, String>? custom]) {
    return {
      ...?custom,
      'Content-Type': 'application/json',
      if (config.apiKey.isNotEmpty) 'x-goog-api-key': config.apiKey,
    };
  }

  // ============================================================
  // Imagen Support
  // ============================================================

  /// Known Imagen model prefixes
  static const _imagenModelPrefixes = [
    'imagen-',
  ];

  /// Check if the model is an Imagen model
  bool _isImagenModel(String model) {
    final lowerModel = model.toLowerCase();
    return _imagenModelPrefixes.any((prefix) => lowerModel.startsWith(prefix));
  }

  /// Generate images using Imagen API
  Future<Message> _generateWithImagen(
    List<Message> input,
    ChatModelOptions options,
    String model,
  ) async {
    // Extract prompt from the last user message
    final prompt = _extractImagenPrompt(input);
    if (prompt.isEmpty) {
      throw GeminiException('No prompt found for Imagen generation');
    }

    // Build Imagen request body
    final requestBody = _buildImagenRequestBody(prompt, options);

    // Make request to Imagen endpoint
    final response = await _makeImagenRequest(requestBody, model);

    // Parse Imagen response
    return _parseImagenResponse(response, prompt);
  }

  /// Extract prompt text from messages for Imagen
  String _extractImagenPrompt(List<Message> messages) {
    // Find the last user message
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role == RoleType.user) {
        // Check for multimodal content first
        if (message.userInputMultiContent != null) {
          for (final part in message.userInputMultiContent!) {
            if (part.type == ChatMessagePartType.text && part.text != null) {
              return part.text!;
            }
          }
        }
        // Fall back to content
        if (message.content.isNotEmpty) {
          return message.content;
        }
      }
    }
    return '';
  }

  /// Build Imagen API request body
  ///
  /// Imagen API uses a different format:
  /// ```json
  /// {
  ///   "instances": [{"prompt": "..."}],
  ///   "parameters": {
  ///     "sampleCount": 1-4,
  ///     "aspectRatio": "1:1|3:4|4:3|9:16|16:9",
  ///     "personGeneration": "dont_allow|allow_adult|allow_all",
  ///     "imageSize": "1K|2K"
  ///   }
  /// }
  /// ```
  Map<String, dynamic> _buildImagenRequestBody(
    String prompt,
    ChatModelOptions options,
  ) {
    final body = <String, dynamic>{
      'instances': [
        {'prompt': prompt},
      ],
    };

    // Build parameters from options.extra
    final parameters = <String, dynamic>{};
    final extra = options.extra ?? {};

    // Number of images (1-4, default 1)
    if (extra['numberOfImages'] != null) {
      parameters['sampleCount'] = extra['numberOfImages'];
    } else if (extra['sampleCount'] != null) {
      parameters['sampleCount'] = extra['sampleCount'];
    }

    // Aspect ratio
    if (extra['aspectRatio'] != null) {
      parameters['aspectRatio'] = extra['aspectRatio'];
    }

    // Person generation control
    if (extra['personGeneration'] != null) {
      parameters['personGeneration'] = extra['personGeneration'];
    }

    // Image size (for Standard/Ultra models)
    if (extra['imageSize'] != null) {
      parameters['imageSize'] = extra['imageSize'];
    }

    // Safety filter level
    if (extra['safetyFilterLevel'] != null) {
      parameters['safetyFilterLevel'] = extra['safetyFilterLevel'];
    }

    // Add watermark (default true for Imagen)
    if (extra['addWatermark'] != null) {
      parameters['addWatermark'] = extra['addWatermark'];
    }

    if (parameters.isNotEmpty) {
      body['parameters'] = parameters;
    }

    return body;
  }

  /// Make request to Imagen API endpoint
  Future<Map<String, dynamic>> _makeImagenRequest(
    Map<String, dynamic> requestBody,
    String model,
  ) async {
    // Imagen uses :predict endpoint
    final url = Uri.parse('${config.baseUrl}/models/$model:predict');
    final headers = _buildHeaders();

    // Outside the try: using a disposed model is a programming error,
    // not a failed request.
    final client = _client;

    try {
      final response = await client
          .post(
            url,
            headers: headers,
            body: jsonEncode(requestBody),
          )
          .timeout(config.timeout);

      if (response.statusCode != 200) {
        final errorBody = jsonDecode(response.body) as Map<String, dynamic>;
        throw GeminiException.fromResponse(
          response.statusCode,
          errorBody,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } on TimeoutException {
      throw GeminiException('Imagen request timed out after ${config.timeout}');
    } catch (e) {
      if (e is GeminiException) rethrow;
      throw GeminiException('Imagen request failed: $e');
    }
  }

  /// Parse Imagen API response
  ///
  /// Imagen response format:
  /// ```json
  /// {
  ///   "predictions": [
  ///     {
  ///       "bytesBase64Encoded": "...",
  ///       "mimeType": "image/png"
  ///     }
  ///   ]
  /// }
  /// ```
  Message _parseImagenResponse(
    Map<String, dynamic> response,
    String prompt,
  ) {
    final predictions = response['predictions'] as List<dynamic>?;

    if (predictions == null || predictions.isEmpty) {
      // Check for error in response
      final error = response['error'] as Map<String, dynamic>?;
      if (error != null) {
        throw GeminiException(
          error['message'] as String? ?? 'Imagen generation failed',
          code: error['code'] as int?,
          status: error['status'] as String?,
        );
      }
      throw GeminiException('No images generated by Imagen');
    }

    // Convert predictions to multimodal output parts
    final outputParts = <MessageOutputPart>[];

    for (final prediction in predictions) {
      final predMap = prediction as Map<String, dynamic>;

      // Handle base64 encoded image
      final base64Data = predMap['bytesBase64Encoded'] as String?;
      final mimeType = predMap['mimeType'] as String? ?? 'image/png';

      if (base64Data != null) {
        final dataUrl = 'data:$mimeType;base64,$base64Data';
        outputParts.add(
          MessageOutputPart(
            type: ChatMessagePartType.imageUrl,
            image: MessagePartCommon(url: dataUrl, mimeType: mimeType),
          ),
        );
      }
    }

    // Build response message
    return Message(
      role: RoleType.assistant,
      content: 'Generated ${outputParts.length} image(s) for: "$prompt"',
      assistantGenMultiContent: outputParts.isNotEmpty ? outputParts : null,
    );
  }
}

/// A prefix cache made by [GeminiChatModel.createPrefixCache].
///
/// Port of genai `CachedContent`. Pass [name] as
/// `GeminiRequestOptions.cachedContentName` to use it.
@immutable
final class GeminiCachedContent {
  /// A cached content called [name].
  const GeminiCachedContent({
    required this.name,
    this.displayName,
    this.model,
    this.createTime,
    this.updateTime,
    this.expireTime,
    this.totalTokenCount,
  });

  /// Reads the REST `CachedContent` object.
  factory GeminiCachedContent.fromJson(Map<String, dynamic> json) {
    DateTime? time(String key) {
      final value = json[key];
      return value is String ? DateTime.tryParse(value) : null;
    }

    final usage = json['usageMetadata'];
    return GeminiCachedContent(
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String?,
      model: json['model'] as String?,
      createTime: time('createTime'),
      updateTime: time('updateTime'),
      expireTime: time('expireTime'),
      totalTokenCount:
          usage is Map ? (usage['totalTokenCount'] as num?)?.toInt() : null,
    );
  }

  /// The resource name, `cachedContents/…`.
  final String name;

  /// The display name, if one was given.
  final String? displayName;

  /// The model the cache was made for (`models/…`).
  final String? model;

  /// When the cache was created.
  final DateTime? createTime;

  /// When the cache was last updated.
  final DateTime? updateTime;

  /// When the cache expires.
  final DateTime? expireTime;

  /// How many tokens the cache holds.
  final int? totalTokenCount;

  @override
  String toString() => 'GeminiCachedContent(name: $name, model: $model, '
      'expireTime: $expireTime, totalTokenCount: $totalTokenCount)';
}
