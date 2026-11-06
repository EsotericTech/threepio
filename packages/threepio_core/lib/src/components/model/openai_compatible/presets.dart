/// Chat models for the OpenAI-compatible endpoints of other vendors.
///
/// Port of the eino-ext models built on `libs/acl/openai`: `qwen`
/// (DashScope compatible mode) and the OpenAI-compatible use of `deepseek`,
/// plus the OpenAI-compatible Ark endpoint the plan uses instead of the
/// Volcengine SDK (§2.4). One class, [OpenAICompatibleChatModel], with a
/// config per vendor ([OpenAICompatibleConfig.deepSeek],
/// [OpenAICompatibleConfig.qwen], [OpenAICompatibleConfig.ark]) or a plain
/// [OpenAICompatibleConfig] for any other compatible server.
library;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../internal/call_cancellation.dart';
import '../../../internal/model_call_callbacks.dart';
import '../../../internal/shared_http_client.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_info.dart';
import '../../../streaming/stream_reader.dart';
import '../../component_type.dart';
import '../base_chat_model.dart';
import '../chat_model_options.dart';
import '../providers/openai/openai_chat_model.dart';
import '../providers/openai/openai_options.dart';
import '../providers/openrouter/openrouter_options.dart';
import 'client.dart';

/// The vendors [OpenAICompatibleConfig] has presets for.
enum OpenAICompatiblePreset {
  /// Any OpenAI-compatible server.
  generic('OpenAICompatible'),

  /// DeepSeek (eino-ext `deepseek`).
  deepSeek('DeepSeek'),

  /// Qwen through DashScope's compatible mode (eino-ext `qwen`).
  qwen('Qwen'),

  /// Volcengine Ark's OpenAI-compatible endpoint (eino-ext `ark`, which uses
  /// the Volcengine SDK instead).
  ark('Ark');

  const OpenAICompatiblePreset(this.typeName);

  /// The component type the model reports (Go `GetType()`).
  final String typeName;
}

/// DeepSeek's switch between thinking and non-thinking mode (`thinking`).
///
/// Port of eino-ext `deepseek.ThinkingConfig`.
enum DeepSeekThinking {
  /// Thinking mode.
  enabled,

  /// Non-thinking mode.
  disabled;

  /// The `thinking` request field.
  Map<String, Object?> toJson() => {'type': name};
}

/// The configuration of an [OpenAICompatibleChatModel].
///
/// The request settings mean what they mean in [OpenAIConfig]: defaults of
/// every call, overridden by the call's `ChatModelOptions` and
/// [OpenAIRequestOptions]. Requests go to `{baseUrl}{path}` with a bearer
/// token.
@immutable
class OpenAICompatibleConfig {
  /// A config for any OpenAI-compatible server at [baseUrl].
  const OpenAICompatibleConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.preset = OpenAICompatiblePreset.generic,
    this.path = '/chat/completions',
    this.timeout = const Duration(seconds: 60),
    this.idleTimeout,
    this.temperature,
    this.topP,
    this.stop,
    this.maxCompletionTokens,
    this.presencePenalty,
    this.frequencyPenalty,
    this.responseFormat,
    this.seed,
    this.logitBias,
    this.user,
    this.logProbs = false,
    this.topLogProbs,
    this.reasoningEffort,
    this.extraFields,
    this.customHeaders,
    this.modalities,
    this.audio,
  });

  /// DeepSeek (`https://api.deepseek.com`).
  ///
  /// Port of eino-ext `deepseek.NewChatModel`'s settings: [thinking] is Go's
  /// `ThinkingConfig`; the reasoning of thinking mode arrives in
  /// `Message.reasoningContent`. For chat prefix completion mark the last
  /// assistant message with `withDeepSeekPrefix()` and use the beta base URL
  /// `https://api.deepseek.com/beta`.
  factory OpenAICompatibleConfig.deepSeek({
    required String apiKey,
    String model = 'deepseek-chat',
    String baseUrl = 'https://api.deepseek.com',
    String path = '/chat/completions',
    DeepSeekThinking? thinking,
    Duration timeout = const Duration(seconds: 60),
    Duration? idleTimeout,
    double? temperature,
    double? topP,
    List<String>? stop,
    double? presencePenalty,
    double? frequencyPenalty,
    ResponseFormat? responseFormat,
    bool logProbs = false,
    int? topLogProbs,
    Map<String, Object?>? extraFields,
    Map<String, String>? customHeaders,
  }) =>
      OpenAICompatibleConfig(
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model,
        preset: OpenAICompatiblePreset.deepSeek,
        path: path,
        timeout: timeout,
        idleTimeout: idleTimeout,
        temperature: temperature,
        topP: topP,
        stop: stop,
        presencePenalty: presencePenalty,
        frequencyPenalty: frequencyPenalty,
        responseFormat: responseFormat,
        logProbs: logProbs,
        topLogProbs: topLogProbs,
        extraFields: {
          if (thinking != null) 'thinking': thinking.toJson(),
          ...?extraFields,
        },
        customHeaders: customHeaders,
      );

  /// Qwen through DashScope's compatible mode
  /// (`https://dashscope.aliyuncs.com/compatible-mode/v1`).
  ///
  /// Port of eino-ext `qwen.NewChatModel`'s settings. [enableThinking] is
  /// sent both as `chat_template_kwargs.enable_thinking` (Bailian) and as
  /// `enable_thinking` (vLLM), as Go does; [modalities] and [audio] are for
  /// the Qwen-Omni models.
  factory OpenAICompatibleConfig.qwen({
    required String apiKey,
    required String model,
    String baseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    bool? enableThinking,
    Duration timeout = const Duration(seconds: 60),
    Duration? idleTimeout,
    double? temperature,
    double? topP,
    List<String>? stop,
    int? maxCompletionTokens,
    double? presencePenalty,
    double? frequencyPenalty,
    ResponseFormat? responseFormat,
    int? seed,
    Map<String, int>? logitBias,
    String? user,
    List<OpenAIModality>? modalities,
    OpenAIAudioConfig? audio,
    Map<String, Object?>? extraFields,
    Map<String, String>? customHeaders,
  }) =>
      OpenAICompatibleConfig(
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model,
        preset: OpenAICompatiblePreset.qwen,
        timeout: timeout,
        idleTimeout: idleTimeout,
        temperature: temperature,
        topP: topP,
        stop: stop,
        maxCompletionTokens: maxCompletionTokens,
        presencePenalty: presencePenalty,
        frequencyPenalty: frequencyPenalty,
        responseFormat: responseFormat,
        seed: seed,
        logitBias: logitBias,
        user: user,
        modalities: modalities,
        audio: audio,
        extraFields: {
          if (enableThinking != null) ...qwenThinkingFields(enableThinking),
          ...?extraFields,
        },
        customHeaders: customHeaders,
      );

  /// Volcengine Ark's OpenAI-compatible endpoint
  /// (`https://ark.cn-beijing.volces.com/api/v3`) with an API key; [model]
  /// is the endpoint or model id.
  factory OpenAICompatibleConfig.ark({
    required String apiKey,
    required String model,
    String baseUrl = 'https://ark.cn-beijing.volces.com/api/v3',
    Duration timeout = const Duration(seconds: 60),
    Duration? idleTimeout,
    double? temperature,
    double? topP,
    List<String>? stop,
    int? maxCompletionTokens,
    double? presencePenalty,
    double? frequencyPenalty,
    ResponseFormat? responseFormat,
    ReasoningEffort? reasoningEffort,
    Map<String, Object?>? extraFields,
    Map<String, String>? customHeaders,
  }) =>
      OpenAICompatibleConfig(
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model,
        preset: OpenAICompatiblePreset.ark,
        timeout: timeout,
        idleTimeout: idleTimeout,
        temperature: temperature,
        topP: topP,
        stop: stop,
        maxCompletionTokens: maxCompletionTokens,
        presencePenalty: presencePenalty,
        frequencyPenalty: frequencyPenalty,
        responseFormat: responseFormat,
        reasoningEffort: reasoningEffort,
        extraFields: extraFields,
        customHeaders: customHeaders,
      );

  /// The request fields that switch Qwen's thinking mode, for a config or
  /// for one call (`OpenAIRequestOptions(extraFields: …)`; Go
  /// `qwen.WithEnableThinking`).
  static Map<String, Object?> qwenThinkingFields(bool enableThinking) => {
        'chat_template_kwargs': {'enable_thinking': enableThinking},
        'enable_thinking': enableThinking,
      };

  /// The API key, sent as a bearer token.
  final String apiKey;

  /// The base URL of the API.
  final String baseUrl;

  /// The model used when a call names none.
  final String model;

  /// The vendor; decides the component type name.
  final OpenAICompatiblePreset preset;

  /// The path of the chat completions endpoint below [baseUrl].
  final String path;

  /// The longest wait for the response headers (complete responses: for the
  /// whole response).
  final Duration timeout;

  /// The longest silence between two streamed chunks.
  final Duration? idleTimeout;

  /// Default sampling temperature.
  final double? temperature;

  /// Default nucleus-sampling probability mass.
  final double? topP;

  /// Default stop sequences.
  final List<String>? stop;

  /// Upper bound of generated tokens including reasoning tokens.
  final int? maxCompletionTokens;

  /// Penalty for tokens already present.
  final double? presencePenalty;

  /// Penalty proportional to token frequency.
  final double? frequencyPenalty;

  /// Structured output.
  final ResponseFormat? responseFormat;

  /// Seed for deterministic sampling.
  final int? seed;

  /// Token id → bias.
  final Map<String, int>? logitBias;

  /// An id for the end user.
  final String? user;

  /// Whether to return log probabilities.
  final bool logProbs;

  /// How many most likely tokens to return per position.
  final int? topLogProbs;

  /// How much reasoning models reason.
  final ReasoningEffort? reasoningEffort;

  /// Request fields added to every body.
  final Map<String, Object?>? extraFields;

  /// HTTP headers added to every request.
  final Map<String, String>? customHeaders;

  /// Output modalities.
  final List<OpenAIModality>? modalities;

  /// Audio output settings.
  final OpenAIAudioConfig? audio;
}

/// Key under `Message.extra` marking an assistant message as the prefix
/// DeepSeek continues (eino-ext `_eino_deepseek_prefix`).
const String deepSeekPrefixKey = '_eino_deepseek_prefix';

/// DeepSeek's chat prefix completion on [Message].
///
/// Port of eino-ext `deepseek.SetPrefix` and `deepseek.HasPrefix`.
extension DeepSeekMessagePrefix on Message {
  /// A copy of this assistant message that DeepSeek continues instead of
  /// answering (sent with `prefix: true`).
  Message withDeepSeekPrefix() =>
      copyWith(extra: {...?extra, deepSeekPrefixKey: true});

  /// Whether [withDeepSeekPrefix] marked this message.
  bool get hasDeepSeekPrefix => extra?[deepSeekPrefixKey] is bool;
}

/// A chat model for any server that speaks the OpenAI Chat Completions API.
///
/// Built on the same client as [OpenAIChatModel]: tools (with
/// `allowedToolNames`), structured output, `reasoning_content` (DeepSeek,
/// Qwen and most compatible servers send the reasoning there), usage in
/// streams, cancellation, the payload and response modifiers of
/// [OpenAIRequestOptions]. Failures are [OpenAIException]s.
///
/// ```dart
/// final model = OpenAICompatibleChatModel(
///   config: OpenAICompatibleConfig.deepSeek(
///     apiKey: key,
///     thinking: DeepSeekThinking.enabled,
///   ),
/// );
/// ```
class OpenAICompatibleChatModel extends ToolCallingChatModel
    implements TypedComponent, CallbackAwareComponent {
  /// A model for [config]; [httpClient] as in the other providers.
  OpenAICompatibleChatModel({
    required this.config,
    this.httpClient,
    this.tools,
  }) : _http = SharedHttpClient(httpClient, owner: 'OpenAICompatibleChatModel') {
    _client = OpenAICompatibleClient(
      http: _http,
      errors: const OpenAIExceptionErrors(),
      timeout: config.timeout,
      idleTimeout: config.idleTimeout,
      parser: OpenAICompatibleResponseParser(audioFormat: config.audio?.format),
      requestIdKey: openAIRequestIdKey,
    );
  }

  OpenAICompatibleChatModel._bound(OpenAICompatibleChatModel source, this.tools)
      : config = source.config,
        httpClient = source.httpClient,
        _http = source._http,
        _client = source._client;

  /// The configuration.
  final OpenAICompatibleConfig config;

  /// The HTTP client to send requests with. When omitted, the model creates
  /// one on first use and closes it in [dispose].
  final http.Client? httpClient;

  /// The tools bound with [withTools].
  final List<ToolInfo>? tools;

  final SharedHttpClient _http;

  late final OpenAICompatibleClient _client;

  /// Releases the HTTP client this model created for itself (shared with
  /// the copies made by [withTools]). Using the model afterwards throws a
  /// [StateError].
  void dispose() => _http.close();

  @override
  String get componentTypeName => config.preset.typeName;

  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) {
    final merged = _mergeOptions(options);
    return ModelCallCallbacks.generate(
      merged,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      generate: () async {
        final requestOptions = merged.extension<OpenAIRequestOptions>();
        final body = _body(input, merged, requestOptions, stream: false);
        final cancellation = CallCancellation.of(merged);
        try {
          return await _client.generate(
            _url,
            headers: _headers(requestOptions),
            body: body,
            input: input,
            cancelToken: cancellation.token,
            runContext: merged.runContext,
            payloadModifier: requestOptions?.requestPayloadModifier,
            responseModifier: requestOptions?.responseMessageModifier,
          );
        } finally {
          cancellation.release();
        }
      },
    );
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) {
    final merged = _mergeOptions(options);
    return ModelCallCallbacks.stream(
      merged,
      typeName: componentTypeName,
      defaultModel: config.model,
      input: input,
      stream: () async {
        final requestOptions = merged.extension<OpenAIRequestOptions>();
        final body = _body(input, merged, requestOptions, stream: true);
        final cancellation = CallCancellation.of(merged);
        var streaming = false;
        try {
          var reader = await _client.stream(
            _url,
            headers: _headers(requestOptions),
            body: body,
            input: input,
            cancellation: cancellation,
            runContext: merged.runContext,
            payloadModifier: requestOptions?.requestPayloadModifier,
            chunkModifier: requestOptions?.responseChunkMessageModifier,
          );
          streaming = true;
          if (config.preset == OpenAICompatiblePreset.qwen) {
            reader = _fixQwenToolCallIndex(reader);
          }
          return reader;
        } finally {
          if (!streaming) cancellation.release();
        }
      },
    );
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) =>
      OpenAICompatibleChatModel._bound(this, tools);

  /// The call's options over the config's defaults and the bound tools, so
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

  /// Port of eino-ext Qwen's stream fix (eino-examples issue 23): a chunk
  /// that carries the finish reason sometimes has a tool call without an
  /// index; it gets the index of the last tool call seen, so that the chunks
  /// concatenate. Only the first tool call of a chunk is fixed, as in Go.
  static StreamReader<Message> _fixQwenToolCallIndex(
    StreamReader<Message> reader,
  ) {
    int? lastIndex;
    return reader.convert((message) async {
      final calls = message.toolCalls;
      if (calls == null || calls.isEmpty) return message;
      final first = calls.first;
      final finish = message.responseMeta?.finishReason ?? '';
      if (finish.isEmpty) {
        lastIndex = first.index;
        return message;
      }
      if (first.index != null) return message;
      return message.copyWith(
        toolCalls: [first.copyWith(index: lastIndex), ...calls.skip(1)],
      );
    });
  }

  /// Port of eino-ext `qwen.validateToolOptions`: DashScope has no
  /// `allowed_tools` tool choice.
  static void _validateQwenToolOptions(ChatModelOptions options) {
    final names = options.allowedToolNames ?? const <String>[];
    switch (options.toolChoice) {
      case ToolChoice.allowed when names.isNotEmpty:
        throw ArgumentError(
          "tool_choice 'allowed' is not supported when allowed tool names "
          'are present',
        );
      case ToolChoice.forced when names.length > 1:
        throw ArgumentError(
          "only one allowed tool name can be configured for tool_choice "
          "'forced'",
        );
      default:
        break;
    }
  }

  /// Port of eino-ext `deepseek.populateToolChoice`: DeepSeek has no
  /// `allowed_tools` tool choice, so an allowed choice is plain `auto` and a
  /// forced one names at most one tool.
  static Object _deepSeekToolChoice(ChatModelOptions options) {
    final tools = [for (final t in options.tools ?? const <ToolInfo>[]) t.function.name];
    final names = options.allowedToolNames ?? const <String>[];
    switch (options.toolChoice!) {
      case ToolChoice.forbidden:
        return 'none';
      case ToolChoice.allowed:
        return 'auto';
      case ToolChoice.forced:
        if (tools.isEmpty) {
          throw ArgumentError('tool choice is forced but tool is not provided');
        }
        String? only;
        if (names.isNotEmpty) {
          if (names.length > 1) {
            throw ArgumentError('only one allowed tool name can be configured');
          }
          if (!tools.contains(names.single)) {
            throw ArgumentError(
              "allowed tool name '${names.single}' not found in tools list",
            );
          }
          only = names.single;
        } else if (tools.length == 1) {
          only = tools.single;
        }
        return only == null
            ? 'required'
            : {
                'type': 'function',
                'function': {'name': only},
              };
    }
  }

  Uri get _url {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    final path = config.path.startsWith('/') ? config.path : '/${config.path}';
    return Uri.parse('$base$path');
  }

  Map<String, String> _headers(OpenAIRequestOptions? requestOptions) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
        ...?(requestOptions?.extraHeaders ?? config.customHeaders),
      };

  Map<String, Object?> _body(
    List<Message> input,
    ChatModelOptions options,
    OpenAIRequestOptions? requestOptions, {
    required bool stream,
  }) {
    if (config.preset == OpenAICompatiblePreset.qwen) {
      _validateQwenToolOptions(options);
    }
    if (config.preset == OpenAICompatiblePreset.deepSeek &&
        options.toolChoice != null) {
      _deepSeekToolChoice(options); // fails first, with DeepSeek's messages
    }
    final body = buildChatCompletionBody(
      input: input,
      options: options,
      settings: OpenAIChatSettings(
        model: config.model,
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
      withToolChoice: config.preset != OpenAICompatiblePreset.deepSeek,
    );
    if (config.preset == OpenAICompatiblePreset.deepSeek &&
        options.toolChoice != null) {
      body['tool_choice'] = _deepSeekToolChoice(options);
    }
    final messages = body['messages']! as List<Map<String, dynamic>>;
    for (var i = 0; i < input.length; i++) {
      if (!input[i].hasDeepSeekPrefix) continue;
      if (input[i].role != RoleType.assistant) {
        throw ArgumentError('prefix only supported for assistant message');
      }
      messages[i]['prefix'] = true;
    }
    return body;
  }
}
