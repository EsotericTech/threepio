/// The transport and wire format shared by every chat model that speaks the
/// OpenAI Chat Completions API: OpenAI and Azure OpenAI, OpenRouter, and the
/// compatible endpoints of DeepSeek, Qwen (DashScope), Ark and others.
///
/// Port of eino-ext `libs/acl/openai` (`Client`, `genRequest`,
/// `buildGenerateResponse`, `streamMessageBuilder`, `populateToolChoice`),
/// without go-openai: the request is built as JSON here and sent with
/// `package:http`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/call_cancellation.dart';
import '../../../internal/provider_http.dart';
import '../../../internal/shared_http_client.dart';
import '../../../schema/message.dart';
import '../../../schema/message_concat.dart';
import '../../../schema/tool_info.dart';
import '../../../streaming/stream_reader.dart';
import '../../../streaming/stream_utils.dart';
import '../cancel_token.dart';
import '../chat_model_options.dart';
import '../providers/openai/openai_converters.dart';
import '../providers/openai/openai_options.dart';
import '../providers/openrouter/openrouter_options.dart';
import '../response_parser.dart';
import 'errors.dart';
import 'sse.dart';

/// Key under `Message.extra` holding the id of the response a message came
/// from (eino-ext `openai.GetRequestID`).
const String openAIRequestIdKey = 'openai-request-id';

/// Key under `MessageOutputPart.extra` (audio parts) holding the transcript
/// of a generated audio.
const String openAIAudioTranscriptKey = 'openai_audio-transcript';

/// How a provider turns the failures of an OpenAI-compatible call into its
/// own exception type.
@internal
abstract interface class OpenAICompatibleErrors {
  /// A response with a status other than 200.
  Object httpError(int statusCode, String body);

  /// No response within [timeout].
  Object timeout(Duration timeout);

  /// The request failed before a response arrived, or its body was not JSON.
  Object requestFailed(Object error, {required bool streaming});

  /// No chunk within [idleTimeout].
  Object streamIdle(Duration idleTimeout);

  /// The response body failed while it was streamed.
  Object streamFailed(Object error);

  /// The parser threw for a streamed chunk.
  Object chunkFailed(Object error);

  /// The parser threw for a complete response.
  Object responseFailed(Object error);
}

/// Thrown by [OpenAICompatibleResponseParser] for an error object inside a
/// stream; providers turn it into their exception type.
@internal
final class OpenAICompatibleChunkError extends ThreepioException {
  /// An error chunk carrying [detail].
  OpenAICompatibleChunkError(this.detail)
      : super('Provider error: ${detail.message}');

  /// The error the chunk described.
  final ProviderErrorDetail detail;
}

/// The request settings of an OpenAI-compatible model's config, the
/// defaults of every call (Go `openai.Config`).
@internal
@immutable
final class OpenAIChatSettings {
  /// Settings; all optional.
  const OpenAIChatSettings({
    required this.model,
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

  final String model;
  final double? temperature;
  final double? topP;
  final List<String>? stop;
  final int? maxCompletionTokens;
  final double? presencePenalty;
  final double? frequencyPenalty;
  final ResponseFormat? responseFormat;
  final int? seed;
  final Map<String, int>? logitBias;
  final String? user;
  final bool logProbs;
  final int? topLogProbs;
  final ReasoningEffort? reasoningEffort;
  final Map<String, Object?>? extraFields;
  final Map<String, String>? customHeaders;
  final List<OpenAIModality>? modalities;
  final OpenAIAudioConfig? audio;
}

/// The request body of one Chat Completions call. Port of eino-ext
/// `Client.genRequest`.
///
/// Settings come from [settings] (the config), then [options] (the call),
/// then [requestOptions] (the call's provider options, which replace the
/// config's extra fields, reasoning effort and completion-token limit, as in
/// Go). `options.extra` is merged last, as threepio always did.
///
/// Throws [ArgumentError] for a contradictory tool choice or audio setup,
/// with Go's message. Without [withToolChoice] no `tool_choice` is set (a
/// preset with its own rules sets it). Extra fields override every field,
/// `stream_options` included, as go-openai's extra fields do.
@internal
Map<String, Object?> buildChatCompletionBody({
  required List<Message> input,
  required ChatModelOptions options,
  required OpenAIChatSettings settings,
  required bool stream,
  OpenAIRequestOptions? requestOptions,
  bool withToolChoice = true,
}) {
  for (final message in input) {
    if ((message.userInputMultiContent?.isNotEmpty ?? false) &&
        (message.assistantGenMultiContent?.isNotEmpty ?? false)) {
      throw ArgumentError(
        'a message cannot contain both UserInputMultiContent and '
        'AssistantGenMultiContent',
      );
    }
  }
  final body = <String, Object?>{
    'model': options.model ?? settings.model,
    'messages': [
      for (final message in input)
        OpenAIConverters.messageToOpenAI(message, goCompatible: true),
    ],
    'stream': stream,
  };

  final maxTokens = options.maxTokens;
  if (maxTokens != null && maxTokens != 0) body['max_tokens'] = maxTokens;
  final maxCompletionTokens =
      requestOptions?.maxCompletionTokens ?? settings.maxCompletionTokens;
  if (maxCompletionTokens != null && maxCompletionTokens != 0) {
    body['max_completion_tokens'] = maxCompletionTokens;
  }
  final temperature = options.temperature ?? settings.temperature;
  if (temperature != null) body['temperature'] = temperature;
  final topP = options.topP ?? settings.topP;
  if (topP != null && topP != 0) body['top_p'] = topP;
  final stop = options.stop ?? settings.stop;
  if (stop != null && stop.isNotEmpty) body['stop'] = stop;
  if (settings.presencePenalty case final p? when p != 0) {
    body['presence_penalty'] = p;
  }
  if (settings.seed case final seed?) body['seed'] = seed;
  if (settings.frequencyPenalty case final p? when p != 0) {
    body['frequency_penalty'] = p;
  }
  if (settings.logitBias case final bias? when bias.isNotEmpty) {
    body['logit_bias'] = bias;
  }
  if (settings.user case final user? when user.isNotEmpty) {
    body['user'] = user;
  }
  if (settings.logProbs) body['logprobs'] = true;
  if (settings.topLogProbs case final n? when n != 0) {
    body['top_logprobs'] = n;
  }
  final effort = requestOptions?.reasoningEffort ?? settings.reasoningEffort;
  if (effort != null) body['reasoning_effort'] = effort.name;

  final tools = options.tools;
  if (tools != null && tools.isNotEmpty) {
    body['tools'] = [for (final t in tools) OpenAIConverters.toolInfoToOpenAI(t)];
  }
  final toolChoice = options.toolChoice;
  if (toolChoice != null && withToolChoice) {
    body['tool_choice'] = openAIToolChoice(
      toolChoice,
      allowedToolNames: options.allowedToolNames ?? const [],
      toolNames: [for (final t in tools ?? const <ToolInfo>[]) t.function.name],
    );
  }

  if (settings.responseFormat case final format?) {
    body['response_format'] = format.toJson();
  }

  if (stream) body['stream_options'] = {'include_usage': true};

  final extraFields = <String, Object?>{
    ...?(requestOptions?.extraFields ?? settings.extraFields),
  };
  final modalities = settings.modalities;
  if (modalities != null && modalities.isNotEmpty) {
    extraFields['modalities'] = [for (final m in modalities) m.wireName];
    if (modalities.contains(OpenAIModality.audio) && settings.audio == null) {
      throw ArgumentError(
        "audio configuration is mandatory when 'audio' modality is specified",
      );
    }
    if (settings.audio case final audio?) extraFields['audio'] = audio.toJson();
  }
  body.addAll(extraFields);
  if (options.extra case final extra?) body.addAll(extra);
  return body;
}

/// The `tool_choice` field for [choice]. Port of eino-ext
/// `populateToolChoice`.
///
/// [toolNames] are the tools of the request and [allowedToolNames] the names
/// the choice is restricted to. Throws [ArgumentError] with Go's message for
/// a forced choice without tools or an allowed name that is not a tool.
@internal
Object openAIToolChoice(
  ToolChoice choice, {
  required List<String> allowedToolNames,
  required List<String> toolNames,
}) {
  void validate() {
    for (final name in allowedToolNames) {
      if (!toolNames.contains(name)) {
        throw ArgumentError('allowed tool $name not found in request tools');
      }
    }
  }

  List<Map<String, Object?>> choices() => [
        for (final name in allowedToolNames)
          {
            'type': 'function',
            'function': {'name': name},
          },
      ];

  switch (choice) {
    case ToolChoice.forbidden:
      return 'none';
    case ToolChoice.allowed:
      if (allowedToolNames.isEmpty) return 'auto';
      validate();
      return {
        'type': 'allowed_tools',
        'allowed_tools': {'mode': 'auto', 'tools': choices()},
      };
    case ToolChoice.forced:
      if (toolNames.isEmpty) {
        throw ArgumentError('tool_choice is forced but no tools are provided');
      }
      validate();
      final only = allowedToolNames.length == 1
          ? allowedToolNames.single
          : toolNames.length == 1
              ? toolNames.single
              : null;
      if (only != null) {
        return {
          'type': 'function',
          'function': {'name': only},
        };
      }
      if (allowedToolNames.length > 1) {
        return {
          'type': 'allowed_tools',
          'allowed_tools': {'mode': 'required', 'tools': choices()},
        };
      }
      return 'required';
  }
}

/// The URL and auth header scheme of an OpenAI or Azure OpenAI endpoint, as
/// go-openai builds them.
@internal
@immutable
final class OpenAIEndpoint {
  /// An endpoint at [baseUrl]; see the fields.
  const OpenAIEndpoint({
    required this.baseUrl,
    this.byAzure = false,
    this.apiVersion,
    this.azureModelMapper,
  });

  /// The base URL (OpenAI: including `/v1`; Azure: the resource endpoint).
  final String baseUrl;

  /// Whether this is Azure OpenAI.
  final bool byAzure;

  /// The Azure API version (default `2023-05-15`).
  final String? apiVersion;

  /// Model → Azure deployment name (default: `.` and `:` removed).
  final String Function(String model)? azureModelMapper;

  /// The Azure API version used when none is configured (go-openai's).
  static const defaultAzureApiVersion = '2023-05-15';

  /// The URL of [path] (`/chat/completions`, `/embeddings`) for [model].
  Uri url(String path, String model) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (!byAzure) return Uri.parse('$base$path');
    final deployment = (azureModelMapper ??
        (m) => m.replaceAll(RegExp('[.:]'), ''))(model);
    final version = apiVersion ?? defaultAzureApiVersion;
    return Uri.parse(
      '$base/openai/deployments/$deployment$path?api-version=$version',
    );
  }

  /// The auth header for [apiKey]: `api-key` on Azure, a bearer token
  /// elsewhere.
  Map<String, String> authHeaders(String apiKey) =>
      byAzure ? {'api-key': apiKey} : {'Authorization': 'Bearer $apiKey'};
}

/// Parses Chat Completions responses and chunks the way eino-ext's
/// `libs/acl/openai` does (`buildGenerateResponse`,
/// `streamMessageBuilder.build`).
///
/// Takes the choice with index 0, maps `reasoning_content` (or `reasoning`)
/// to [Message.reasoningContent], log probabilities, usage with cached,
/// cache-write and reasoning tokens, and generated audio (with [audioFormat]
/// for its MIME type). A usage-only chunk becomes a message that only holds
/// the usage. An `error` object inside a stream throws an
/// [OpenAICompatibleChunkError].
@internal
final class OpenAICompatibleResponseParser implements ResponseParser {
  /// A parser; [audioFormat] is the configured audio output format.
  const OpenAICompatibleResponseParser({this.audioFormat});

  /// The `audio.format` of the config, needed for generated audio.
  final String? audioFormat;

  static const _audioMimeTypes = {
    'wav': 'audio/wav',
    'mp3': 'audio/mpeg',
    'flac': 'audio/flac',
    'opus': 'audio/opus',
    'pcm16': 'audio/pcm',
  };

  @override
  Message parseCompletionResponse(Map<String, dynamic> response) {
    final choice = _choiceZero(response['choices']);
    if (choice == null) {
      final choices = response['choices'];
      throw ThreepioFormatException(
        choices is List && choices.isNotEmpty
            ? 'invalid response format: choice with index 0 not found'
            : 'received empty choices from OpenAI API response',
      );
    }
    final message = _map(choice['message']);
    final usage = _usage(response['usage']);
    var out = Message(
      role: _role(message['role']),
      content: _string(message['content']),
      name: message['name'] as String?,
      toolCallId: message['tool_call_id'] as String?,
      toolCalls: _toolCalls(message['tool_calls']),
      reasoningContent: _reasoning(message),
      responseMeta: ResponseMeta(
        finishReason: choice['finish_reason'] as String?,
        usage: usage,
        logProbs: _logProbs(choice['logprobs']),
      ),
      extra: response['id'] is String && (response['id'] as String).isNotEmpty
          ? {openAIRequestIdKey: response['id']}
          : null,
    );
    final audio = message['audio'];
    if (audio is Map &&
        ((audio['data'] as String? ?? '').isNotEmpty ||
            (audio['transcript'] as String? ?? '').isNotEmpty)) {
      final id = audio['id'] as String? ?? '';
      if (id.isEmpty) {
        throw const ThreepioFormatException(
          'failed to generate chat completion: message audio was returned '
          'but is missing audio ID',
        );
      }
      out = out.copyWith(
        assistantGenMultiContent: [_audioPart(audio, id)],
      );
    }
    return out;
  }

  @override
  Message? parseStreamChunk(Map<String, dynamic> chunk) {
    final error = chunk['error'];
    if (error != null) {
      throw OpenAICompatibleChunkError(
        ProviderErrorDetail.parse(jsonEncode({'error': error})),
      );
    }
    final usage = _usage(chunk['usage']);
    final choice = _choiceZero(chunk['choices']);
    if (choice == null) {
      if (usage == null) return null;
      return Message(
        role: RoleType.assistant,
        responseMeta: ResponseMeta(usage: usage),
      );
    }
    final delta = _map(choice['delta']);
    final finishReason = choice['finish_reason'] as String?;
    final logProbs = _logProbs(choice['logprobs']);
    final audio = delta['audio'];
    return Message(
      role: _role(delta['role']),
      content: _string(delta['content']),
      toolCalls: _toolCalls(delta['tool_calls'], streaming: true),
      reasoningContent: _reasoning(delta),
      assistantGenMultiContent: audio is Map &&
              ((audio['data'] as String? ?? '').isNotEmpty ||
                  (audio['transcript'] as String? ?? '').isNotEmpty)
          ? [_audioPart(audio, audio['id'] as String? ?? '')]
          : null,
      responseMeta: finishReason != null || usage != null || logProbs != null
          ? ResponseMeta(
              finishReason: finishReason,
              usage: usage,
              logProbs: logProbs,
            )
          : null,
    );
  }

  @override
  Message? parseDelta(Map<String, dynamic> delta, {String? finishReason}) =>
      parseStreamChunk({
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': finishReason},
        ],
      });

  MessageOutputPart _audioPart(Map<dynamic, dynamic> audio, String id) {
    final data = audio['data'] as String? ?? '';
    String? mimeType;
    if (data.isNotEmpty) {
      final format = audioFormat;
      if (format == null) {
        throw const ThreepioFormatException(
          'audio config must be set when audio data is present',
        );
      }
      mimeType = _audioMimeTypes[format];
      if (mimeType == null) {
        throw ThreepioFormatException(
          'audio mime type not found for config audio format $format',
        );
      }
    }
    return MessageOutputPart(
      type: ChatMessagePartType.audioUrl,
      audio: MessagePartCommon(
        base64Data: data.isEmpty ? null : data,
        mimeType: mimeType,
      ),
      extra: {
        if (id.isNotEmpty) openAIGeneratedAudioIdKey: id,
        openAIAudioTranscriptKey: audio['transcript'] as String? ?? '',
      },
    );
  }

  static Map<String, dynamic>? _choiceZero(Object? choices) {
    if (choices is! List) return null;
    for (final choice in choices) {
      if (choice is Map<String, dynamic> &&
          ((choice['index'] as num?)?.toInt() ?? 0) == 0) {
        return choice;
      }
    }
    return null;
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};

  static String _string(Object? value) => value is String ? value : '';

  static RoleType _role(Object? role) => switch (role) {
        null || '' || 'assistant' => RoleType.assistant,
        'user' => RoleType.user,
        'system' || 'developer' => RoleType.system,
        'tool' => RoleType.tool,
        _ => throw ThreepioFormatException('Unknown role: $role'),
      };

  /// `reasoning_content`, or Go's other reasoning key `reasoning`.
  static String? _reasoning(Map<String, dynamic> message) {
    for (final key in const ['reasoning_content', 'reasoning']) {
      final value = message[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  static List<ToolCall>? _toolCalls(Object? raw, {bool streaming = false}) {
    if (raw is! List || raw.isEmpty) return null;
    return [
      for (final call in raw.whereType<Map<String, dynamic>>())
        ToolCall(
          id: call['id'] as String? ?? '',
          // A continuation fragment carries no type; '' merges with the
          // first fragment's (Go keeps the zero value too).
          type: call['type'] as String? ?? (streaming ? '' : 'function'),
          index: (call['index'] as num?)?.toInt(),
          function: FunctionCall(
            name: _string(_map(call['function'])['name']),
            arguments: _string(_map(call['function'])['arguments']),
          ),
        ),
    ];
  }

  static TokenUsage? _usage(Object? raw) {
    if (raw is! Map) return null;
    int read(Map<dynamic, dynamic>? m, String key) =>
        (m?[key] as num?)?.toInt() ?? 0;
    final prompt = raw['prompt_tokens_details'] as Map<dynamic, dynamic>?;
    final completion =
        raw['completion_tokens_details'] as Map<dynamic, dynamic>?;
    return TokenUsage(
      promptTokens: read(raw, 'prompt_tokens'),
      completionTokens: read(raw, 'completion_tokens'),
      totalTokens: read(raw, 'total_tokens'),
      promptTokenDetails: PromptTokenDetails(
        cachedTokens: read(prompt, 'cached_tokens'),
        cacheWriteTokens: read(prompt, 'cache_write_tokens'),
      ),
      completionTokenDetails: CompletionTokenDetails(
        reasoningTokens: read(completion, 'reasoning_tokens'),
      ),
    );
  }

  static LogProbs? _logProbs(Object? raw) {
    if (raw is! Map) return null;
    final content = raw['content'];
    if (content is! List) return null;
    List<int>? bytes(Object? b) =>
        b is List ? [for (final x in b) (x as num).toInt()] : null;
    return LogProbs(
      content: [
        for (final item in content.whereType<Map<dynamic, dynamic>>())
          LogProb(
            token: _string(item['token']),
            logProb: (item['logprob'] as num?)?.toDouble() ?? 0,
            bytes: bytes(item['bytes']),
            topLogProbs: [
              for (final top in (item['top_logprobs'] as List? ?? const [])
                  .whereType<Map<dynamic, dynamic>>())
                TopLogProb(
                  token: _string(top['token']),
                  logProb: (top['logprob'] as num?)?.toDouble() ?? 0,
                  bytes: bytes(top['bytes']),
                ),
            ],
          ),
      ],
    );
  }
}

/// The log probabilities of a choice (`choice.logprobs`), or `null`.
@internal
LogProbs? parseOpenAILogProbs(Object? raw) =>
    OpenAICompatibleResponseParser._logProbs(raw);

/// Sends Chat Completions requests and reads their responses: the transport
/// half of eino-ext's `libs/acl/openai.Client`, shared by the OpenAI,
/// OpenRouter and OpenAI-compatible models.
///
/// The body is built by the model ([buildChatCompletionBody] or its own
/// builder); this class sends it, applies the payload and response
/// modifiers, parses with [parser], classifies failures with [errors] and
/// streams server-sent events with cancellation and an idle timeout.
@internal
final class OpenAICompatibleClient {
  /// A client; see the fields.
  OpenAICompatibleClient({
    required this.http,
    required this.errors,
    required this.timeout,
    this.idleTimeout,
    this.parser = const OpenAICompatibleResponseParser(),
    this.mergeEmptyChunks = true,
    this.requestIdKey,
  });

  /// The HTTP client of the model and its `withTools` copies.
  final SharedHttpClient http;

  /// Turns failures into the provider's exceptions.
  final OpenAICompatibleErrors errors;

  /// The longest wait for the response headers (complete responses: for the
  /// whole response).
  final Duration timeout;

  /// The longest silence between two streamed lines.
  final Duration? idleTimeout;

  /// Parses responses and chunks.
  final ResponseParser parser;

  /// Whether streamed messages without content, tool calls or reasoning are
  /// held back and merged into the next message, as eino-ext does (the first
  /// frame of parallel tool calls can be empty). The last held-back message
  /// is sent at the end.
  final bool mergeEmptyChunks;

  /// When set, the response id is stored under this `extra` key of the
  /// message (once per stream, on its first message).
  final String? requestIdKey;

  /// Sends [body] to [url] and parses the complete response.
  Future<Message> generate(
    Uri url, {
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required List<Message> input,
    CancelToken? cancelToken,
    RunContext? runContext,
    RequestPayloadModifier? payloadModifier,
    ResponseMessageModifier? responseModifier,
  }) async {
    final payload =
        payloadModifier == null ? body : payloadModifier(runContext, input, body);
    // Outside the try: a disposed model is a programming error.
    final client = http.client;
    final Map<String, dynamic> json;
    try {
      final response = await sendRequest(
        client,
        url,
        headers: headers,
        body: jsonEncode(payload),
        timeout: timeout,
        cancelToken: cancelToken,
      );
      if (response.statusCode != 200) {
        throw _HttpFailure(errors.httpError(response.statusCode, response.body));
      }
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } on _HttpFailure catch (failure) {
      throw failure.error;
    } on TimeoutException {
      throw errors.timeout(timeout);
    } on CancelledException {
      rethrow;
    } catch (error) {
      throw errors.requestFailed(error, streaming: false);
    }

    Message message;
    try {
      message = parser.parseCompletionResponse(json);
    } catch (error) {
      throw errors.responseFailed(error);
    }
    final key = requestIdKey;
    if (key == null) message = _withoutRequestId(message);
    if (responseModifier != null) {
      message = responseModifier(runContext, message, json);
    }
    return message;
  }

  /// Sends [body] to [url] and streams the messages of the response.
  ///
  /// Once the stream is being read, [cancellation] is released when it ends;
  /// when this method throws, releasing it is left to the caller.
  Future<StreamReader<Message>> stream(
    Uri url, {
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required List<Message> input,
    required CallCancellation cancellation,
    RunContext? runContext,
    RequestPayloadModifier? payloadModifier,
    ResponseChunkMessageModifier? chunkModifier,
  }) async {
    final cancelToken = cancellation.token;
    final payload =
        payloadModifier == null ? body : payloadModifier(runContext, input, body);
    // Outside the try: a disposed model is a programming error.
    final client = http.client;
    try {
      final response = await sendStreamingRequest(
        client,
        url,
        headers: headers,
        body: jsonEncode(payload),
        timeout: timeout,
        cancelToken: cancelToken,
      );
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw _HttpFailure(errors.httpError(response.statusCode, text));
      }

      final (reader, writer) = pipe<Message>();
      Message? held;
      var requestId = '';
      var idSent = false;

      Message withId(Message message) {
        final key = requestIdKey;
        if (key == null || idSent || requestId.isEmpty) return message;
        idSent = true;
        return message.copyWith(extra: {...?message.extra, key: requestId});
      }

      void emit(Message message, Map<String, Object?>? raw) {
        var out = withId(message);
        if (chunkModifier != null) {
          final modified = chunkModifier(runContext, out, raw, end: false);
          if (modified == null) return;
          out = modified;
        }
        writer.send(out);
      }

      unawaited(
        pumpSse<Message>(
          bytes: response.stream,
          writer: writer,
          cancelToken: cancelToken,
          idleTimeout: idleTimeout,
          idleError: () => errors.streamIdle(idleTimeout!),
          streamError: errors.streamFailed,
          onEvent: (event) {
            final data = event.data.trim();
            if (data.isEmpty) return PumpAction.next;
            if (data == '[DONE]') return PumpAction.stop;
            final Object? decoded;
            try {
              decoded = jsonDecode(data);
            } on FormatException {
              return PumpAction.next; // a partial or malformed line
            }
            if (decoded is! Map<String, dynamic>) return PumpAction.next;
            if (requestId.isEmpty && decoded['id'] is String) {
              requestId = decoded['id'] as String;
            }
            Message? message;
            try {
              message = parser.parseStreamChunk(decoded);
            } catch (error) {
              throw errors.chunkFailed(error);
            }
            if (message == null) return PumpAction.next;
            if (!mergeEmptyChunks) {
              emit(message, decoded);
              return PumpAction.next;
            }
            if (held != null) {
              message = concatMessages([held!, message]);
              held = null;
            }
            if (_isEmpty(message)) {
              held = message;
              return PumpAction.next;
            }
            emit(message, decoded);
            return PumpAction.next;
          },
          onComplete: () {
            var last = held;
            held = null;
            if (chunkModifier != null) {
              last = chunkModifier(
                runContext,
                last == null ? null : withId(last),
                null,
                end: true,
              );
            } else if (last != null) {
              last = withId(last);
            }
            if (last != null) writer.send(last);
          },
        ).whenComplete(cancellation.release),
      );
      return reader;
    } on _HttpFailure catch (failure) {
      throw failure.error;
    } on TimeoutException {
      throw errors.timeout(timeout);
    } on CancelledException {
      rethrow;
    } catch (error) {
      throw errors.requestFailed(error, streaming: true);
    }
  }

  static bool _isEmpty(Message message) =>
      message.content.isEmpty &&
      (message.toolCalls?.isEmpty ?? true) &&
      (message.reasoningContent?.isEmpty ?? true);

  static Message _withoutRequestId(Message message) {
    final extra = message.extra;
    if (extra == null || !extra.containsKey(openAIRequestIdKey)) {
      return message;
    }
    final rest = {...extra}..remove(openAIRequestIdKey);
    return message.copyWith(extra: rest.isEmpty ? null : rest);
  }
}

/// A provider exception passed through the client's `try`.
final class _HttpFailure {
  _HttpFailure(this.error);
  final Object error;
}
