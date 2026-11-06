import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../../errors.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import 'gemini_message_extras.dart';

/// Converters for transforming between Threepio and Gemini API formats
///
/// Handles conversion of:
/// - Messages (including multimodal content, thought parts and thought
///   signatures)
/// - Tool definitions and function calls
/// - Tool choice settings
///
/// Port of the conversions of eino-ext's `gemini` chat model
/// (`convSchemaMessages`, `convSchemaMessage`, `convCandidate`,
/// `convResponse`, `convLogprobs`, `populateToolChoice`), written against
/// the JSON of the Gemini REST API instead of the genai SDK's types.
///
/// A response keeps the layout threepio has always given it: the text of
/// the response is [Message.content] (and the thought signature of that text
/// is in [Message.extra]); [Message.assistantGenMultiContent] holds the
/// generated media and the code execution parts, each with its own thought
/// signature. Go also mirrors the text parts into the output parts.
class GeminiConverters {
  static const _uuid = Uuid();

  /// Convert Threepio Message to Gemini content format
  ///
  /// Role mapping:
  /// - user -> "user"
  /// - assistant -> "model"
  /// - tool -> "user" with functionResponse part
  /// - system -> handled separately as systemInstruction
  ///
  /// Port of eino-ext `convSchemaMessage`: the reasoning content goes first
  /// as a thought part, the text follows (with the message's thought
  /// signature when the message has no tool calls), then the media parts,
  /// then one `functionCall` part per tool call (with its thought
  /// signature). A text tool result is sent as `{"result": content}`; a tool
  /// result with media parts as Go's multimodal function response.
  ///
  /// Throws a [ThreepioFormatException] when a media part has no data or
  /// invalid base64 data, and an [UnsupportedError] for a reasoning or tool
  /// search part in the user input.
  static Map<String, dynamic> messageToGemini(Message message) {
    // Handle tool response messages
    if (message.role == RoleType.tool) return _toolMessageToGemini(message);

    final role = _roleToGemini(message.role);
    final parts = <Map<String, dynamic>>[];

    // Restore reasoning content as a thought part (required for Gemini 3).
    final reasoning = message.reasoningContent;
    if (reasoning != null && reasoning.isNotEmpty) {
      parts.add({'text': reasoning, 'thought': true});
    }

    final toolCalls = message.toolCalls ?? const <ToolCall>[];
    final input = message.userInputMultiContent;
    final output = message.assistantGenMultiContent;

    if (input != null && input.isNotEmpty) {
      // Handle text content, then the multimodal input content
      if (message.content.isNotEmpty) parts.add({'text': message.content});
      for (final part in input) {
        parts.add(_inputPartToGemini(part));
      }
    } else if (output != null && output.any(_isPlainText)) {
      // Output parts that carry the text themselves, as Go builds them: they
      // are the whole message.
      for (final part in output) {
        final converted = _outputPartToGemini(part);
        if (converted != null) parts.add(converted);
      }
    } else {
      if (message.content.isNotEmpty) {
        final textPart = <String, dynamic>{'text': message.content};
        // The signature of a response without function calls belongs on its
        // final text part.
        if (toolCalls.isEmpty) {
          final signature = geminiThoughtSignatureBase64(message.extra);
          if (signature != null) textPart['thoughtSignature'] = signature;
        }
        parts.add(textPart);
      }
      for (final part in output ?? const <MessageOutputPart>[]) {
        final converted = _outputPartToGemini(part);
        if (converted != null) parts.add(converted);
      }
    }

    // Handle tool calls from assistant
    for (final toolCall in toolCalls) {
      // Parse the arguments string to get the map
      Map<String, dynamic> args;
      try {
        args = jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
      } catch (_) {
        args = {};
      }
      final part = <String, dynamic>{
        'functionCall': {
          'name': toolCall.function.name,
          'args': args,
        },
      };
      final signature = geminiThoughtSignatureBase64(toolCall.extra);
      if (signature != null) part['thoughtSignature'] = signature;
      parts.add(part);
    }

    return {'role': role, 'parts': parts};
  }

  /// Converts [messages] (without system messages) to the `contents` of a
  /// request.
  ///
  /// Port of eino-ext `convSchemaMessages`: each message goes through
  /// [messageToGemini], and tool results that follow each other are merged
  /// into one content, as Gemini wants the answers to parallel function calls
  /// together (Go `mergeAdjacentToolContents`).
  static List<Map<String, dynamic>> messagesToGemini(List<Message> messages) {
    final contents = <Map<String, dynamic>>[];
    for (final message in messages) {
      final content = messageToGemini(message);
      if (contents.isNotEmpty &&
          _isToolResponseContent(content) &&
          _isToolResponseContent(contents.last)) {
        contents.last = {
          ...contents.last,
          'parts': [
            ...contents.last['parts'] as List<Map<String, dynamic>>,
            ...content['parts'] as List<Map<String, dynamic>>,
          ],
        };
      } else {
        contents.add(content);
      }
    }
    return contents;
  }

  /// Port of eino-ext `isToolResponseContent`.
  static bool _isToolResponseContent(Map<String, dynamic> content) {
    final parts = content['parts'] as List<Map<String, dynamic>>;
    return parts.isNotEmpty &&
        parts.every((part) => part.containsKey('functionResponse'));
  }

  /// Port of eino-ext `convToolMessageToPart`.
  static Map<String, dynamic> _toolMessageToGemini(Message message) {
    // Gemini has no tool call ids: the response is matched by name, and the
    // id stands in when the name is missing (as in Go).
    final toolName = message.toolName;
    final name = toolName != null && toolName.isNotEmpty
        ? toolName
        : message.toolCallId ?? 'function';
    final input = message.userInputMultiContent;
    final functionResponse = input != null && input.isNotEmpty
        ? _multiModalToolResult(name, input)
        : {
            'name': name,
            'response': {
              'result': message.content,
            },
          };
    return {
      'role': 'user',
      'parts': <Map<String, dynamic>>[
        {'functionResponse': functionResponse},
      ],
    };
  }

  /// Port of eino-ext `convMultiModalToolMessageToPart`.
  static Map<String, dynamic> _multiModalToolResult(
    String name,
    List<MessageInputPart> inputs,
  ) {
    String? text;
    final parts = <Map<String, dynamic>>[];
    for (final input in inputs) {
      final displayName = input.geminiToolResultDisplayName ?? '';
      if (input.type == ChatMessagePartType.text) {
        text = (text ?? '') + (input.text ?? '');
        continue;
      }
      final common = _inputCommon(input, 'tool message');
      _validateFileId(common);
      parts.add(
        _functionResponsePart(
          base64Data: common.base64Data,
          url: common.url ?? common.fileId,
          mimeType: common.mimeType,
          type: input.type,
          displayName: displayName,
        ),
      );
    }
    var response = <String, dynamic>{};
    if (text != null) {
      try {
        final decoded = jsonDecode(text);
        response = decoded is Map<String, dynamic> ? decoded : {'output': text};
      } on FormatException {
        response = {'output': text};
      }
    }
    return {
      'name': name,
      'response': response,
      if (parts.isNotEmpty) 'parts': parts,
    };
  }

  /// Port of eino-ext `toFunctionResponsePart`.
  static Map<String, dynamic> _functionResponsePart({
    required String? base64Data,
    required String? url,
    required String? mimeType,
    required ChatMessagePartType type,
    required String displayName,
  }) {
    Map<String, dynamic> withName(Map<String, dynamic> data) => {
          ...data,
          if (displayName.isNotEmpty) 'displayName': displayName,
        };
    if (base64Data != null) {
      return {
        'inlineData': withName({
          if (mimeType != null) 'mimeType': mimeType,
          'data': _normalizeBase64(base64Data, type),
        }),
      };
    }
    if (url != null) {
      final inline = _parseDataUrl(url);
      if (inline != null) {
        return {
          'inlineData': withName({
            'mimeType': inline.mimeType,
            'data': inline.data,
          }),
        };
      }
      return {
        'fileData': withName({
          if (mimeType != null) 'mimeType': mimeType,
          'fileUri': url,
        }),
      };
    }
    throw ThreepioFormatException('[${type.name}] is empty');
  }

  /// Convert Threepio role to Gemini role string
  static String _roleToGemini(RoleType role) {
    switch (role) {
      case RoleType.user:
        return 'user';
      case RoleType.assistant:
        return 'model';
      case RoleType.system:
        // System messages are handled separately as systemInstruction
        return 'user';
      case RoleType.tool:
        return 'user';
    }
  }

  /// The media source of a non-text input part; throws when it is missing.
  static MessagePartCommon _inputCommon(MessageInputPart part, String where) {
    final common = switch (part.type) {
      ChatMessagePartType.imageUrl => part.image?.common,
      ChatMessagePartType.audioUrl => part.audio?.common,
      ChatMessagePartType.videoUrl => part.video?.common,
      ChatMessagePartType.fileUrl => part.file?.common,
      _ => throw ThreepioFormatException(
          'unknown part type: ${part.type.name}',
        ),
    };
    if (common == null) {
      final field = switch (part.type) {
        ChatMessagePartType.imageUrl => 'image',
        ChatMessagePartType.audioUrl => 'audio',
        ChatMessagePartType.videoUrl => 'video',
        _ => 'file',
      };
      throw ThreepioFormatException(
        '$field field must not be null when type is ${part.type.name} in '
        '$where',
      );
    }
    return common;
  }

  /// Port of eino-ext `validateMediaFileID`.
  static void _validateFileId(MessagePartCommon common) {
    if (common.base64Data != null ||
        common.url != null ||
        common.fileId == null) {
      return;
    }
    if (common.fileId!.isEmpty) {
      throw const ThreepioFormatException('FileID must not be empty');
    }
  }

  /// Convert Threepio input part to Gemini part format
  ///
  /// Port of eino-ext `convInputMedia`: base64 data becomes `inline_data`,
  /// a URL (a data URL included) or a provider file id `file_data`, and a
  /// video part carries its `videoMetadata`.
  static Map<String, dynamic> _inputPartToGemini(MessageInputPart part) {
    switch (part.type) {
      case ChatMessagePartType.text:
        return {'text': part.text ?? ''};

      case ChatMessagePartType.imageUrl:
      case ChatMessagePartType.audioUrl:
      case ChatMessagePartType.videoUrl:
      case ChatMessagePartType.fileUrl:
        final common = _inputCommon(part, 'user message');
        _validateFileId(common);
        final result = _dataPart(
          base64Data: common.base64Data,
          url: common.url,
          fileId: common.fileId,
          mimeType: common.mimeType,
          type: part.type,
        );
        if (part.type == ChatMessagePartType.videoUrl) {
          final metadata = part.geminiInputVideoMetadata;
          if (metadata != null) result['videoMetadata'] = metadata.toJson();
        }
        return result;

      case ChatMessagePartType.reasoning:
      case ChatMessagePartType.toolSearchResult:
        throw UnsupportedError(
          'Gemini does not accept ${part.type.name} parts as input',
        );
    }
  }

  /// Port of eino-ext `convOutputMedia` for one part; `null` for the part
  /// types Gemini has no counterpart for.
  static Map<String, dynamic>? _outputPartToGemini(MessageOutputPart part) {
    final Map<String, dynamic> result;
    switch (part.type) {
      case ChatMessagePartType.text:
        result = _restoreSpecialPart(part) ?? {'text': part.text ?? ''};
      case ChatMessagePartType.imageUrl:
      case ChatMessagePartType.audioUrl:
      case ChatMessagePartType.videoUrl:
        final common = switch (part.type) {
          ChatMessagePartType.imageUrl => part.image,
          ChatMessagePartType.audioUrl => part.audio,
          _ => part.video,
        };
        if (common == null) {
          throw ThreepioFormatException(
            'media field must not be null when type is ${part.type.name} in '
            'assistant message',
          );
        }
        result = _dataPart(
          base64Data: common.base64Data,
          url: common.url,
          mimeType: common.mimeType,
          type: part.type,
        );
      case ChatMessagePartType.fileUrl:
      case ChatMessagePartType.reasoning:
      case ChatMessagePartType.toolSearchResult:
        return null;
    }
    final signature = geminiThoughtSignatureBase64(part.extra);
    if (signature != null) result['thoughtSignature'] = signature;
    return result;
  }

  /// Port of eino-ext `tryRestoreSpecialPart`.
  static Map<String, dynamic>? _restoreSpecialPart(MessageOutputPart part) {
    final special = part.extra?[geminiSpecialPartKey];
    if (special is! Map) return null;
    for (final key in const ['executableCode', 'codeExecutionResult']) {
      final value = special[key];
      if (value is Map) return {key: Map<String, dynamic>.from(value)};
    }
    return null;
  }

  static bool _isPlainText(MessageOutputPart part) =>
      part.type == ChatMessagePartType.text &&
      part.extra?[geminiSpecialPartKey] == null;

  /// Port of eino-ext `toGenAIDataPart`: base64 data first, then the URL,
  /// then the provider file id (Go `mediaFileURI`).
  static Map<String, dynamic> _dataPart({
    required String? base64Data,
    required String? url,
    required String? mimeType,
    required ChatMessagePartType type,
    String? fileId,
  }) {
    if (base64Data != null) {
      return {
        'inline_data': {
          if (mimeType != null) 'mime_type': mimeType,
          'data': _normalizeBase64(base64Data, type),
        },
      };
    }
    if (url != null) {
      return _mediaToGemini(url, _defaultMimeType(type), mimeType: mimeType);
    }
    if (fileId != null) {
      // No wildcard type for a file id: the API knows the file's type.
      final guessed = _guessMimeType(fileId, _defaultMimeType(type));
      final fileMimeType =
          mimeType ?? (guessed.endsWith('/*') ? null : guessed);
      return {
        'file_data': {
          if (fileMimeType != null) 'mime_type': fileMimeType,
          'file_uri': fileId,
        },
      };
    }
    throw ThreepioFormatException('[${type.name}] is empty');
  }

  static String _defaultMimeType(ChatMessagePartType type) => switch (type) {
        ChatMessagePartType.imageUrl => 'image',
        ChatMessagePartType.audioUrl => 'audio',
        ChatMessagePartType.videoUrl => 'video',
        _ => 'application',
      };

  /// Port of eino-ext `decodeBase64Data`: accepts raw base64 or a data URL
  /// and returns the canonical base64 of the decoded bytes.
  static String _normalizeBase64(String data, ChatMessagePartType type) {
    if (data.startsWith('http')) {
      throw ThreepioFormatException(
        'failed to decode [${type.name}] base64 data: invalid input: expected '
        "base64 data or data URL, but got a web URL starting with 'http'. "
        'Please fetch the content from the URL first',
      );
    }
    final comma = data.indexOf(',');
    final raw = comma == -1 ? data : data.substring(comma + 1);
    try {
      return base64Encode(base64Decode(raw));
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'failed to decode [${type.name}] base64 data: ${error.message}',
        cause: error,
      );
    }
  }

  static final _dataUrl = RegExp('data:([^;]+);base64,(.+)');

  static ({String mimeType, String data})? _parseDataUrl(String url) {
    if (!url.startsWith('data:')) return null;
    final match = _dataUrl.firstMatch(url);
    if (match == null) return null;
    return (mimeType: match.group(1)!, data: match.group(2)!);
  }

  /// Convert media URL to Gemini format
  ///
  /// Handles both:
  /// - Base64 data URLs (data:mime;base64,...)
  /// - Remote URLs (https://...)
  static Map<String, dynamic> _mediaToGemini(
    String url,
    String defaultType, {
    String? mimeType,
  }) {
    // Check if it's a data URL (base64)
    final inline = _parseDataUrl(url);
    if (inline != null) {
      return {
        'inline_data': {
          'mime_type': inline.mimeType,
          'data': inline.data,
        },
      };
    }

    // Remote URL - use file_data
    return {
      'file_data': {
        'mime_type': mimeType ?? _guessMimeType(url, defaultType),
        'file_uri': url,
      },
    };
  }

  /// Guess MIME type from URL
  static String _guessMimeType(String url, String defaultType) {
    // Strip query parameters and fragments before checking extension
    // Firebase Storage URLs have format: ...uuid.png?alt=media&token=xxx
    final urlWithoutQuery = url.split('?').first.split('#').first;
    final lower = urlWithoutQuery.toLowerCase();

    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp3')) return 'audio/mp3';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return '$defaultType/*';
  }

  /// Convert Gemini response to Threepio Message
  ///
  /// Port of eino-ext `convCandidate` and the usage part of `convResponse`:
  /// text parts make the content, thought parts the reasoning content,
  /// function calls the tool calls (with generated ids, as Gemini gives
  /// none, and their thought signatures), inline media and code execution
  /// parts the output parts; grounding metadata and log probabilities are
  /// kept.
  static Message geminiToMessage(
    Map<String, dynamic> candidate, {
    Map<String, dynamic>? usageMetadata,
  }) =>
      _convertCandidate(candidate, usageMetadata).message;

  /// Convert Gemini streaming chunk to Message
  ///
  /// Returns `null` when the chunk has no text, reasoning, tool call or
  /// output part. [geminiChunkToMessage] also keeps chunks that only carry a
  /// finish reason or the usage.
  static Message? geminiDeltaToMessage(
    Map<String, dynamic> candidate, {
    Map<String, dynamic>? usageMetadata,
  }) {
    final content = candidate['content'] as Map<String, dynamic>?;
    if (content == null) return null;

    final parts = content['parts'] as List<dynamic>? ?? [];
    if (parts.isEmpty) return null;

    final converted = _convertCandidate(candidate, usageMetadata);
    return converted.hasPayload ? converted.message : null;
  }

  /// The message of one chunk of a stream, or `null` when the chunk carries
  /// nothing at all.
  ///
  /// Port of eino-ext `convResponse` as `Stream` applies it to every chunk:
  /// unlike [geminiDeltaToMessage], a chunk with only a finish reason, the
  /// usage, a thought signature or grounding metadata is kept.
  static Message? geminiChunkToMessage(
    Map<String, dynamic> candidate, {
    Map<String, dynamic>? usageMetadata,
  }) {
    final converted = _convertCandidate(candidate, usageMetadata);
    final message = converted.message;
    return converted.hasPayload ||
            message.responseMeta != null ||
            message.extra != null
        ? message
        : null;
  }

  static ({Message message, bool hasPayload}) _convertCandidate(
    Map<String, dynamic> candidate,
    Map<String, dynamic>? usageMetadata,
  ) {
    final content = candidate['content'];
    final rawParts = content is Map ? content['parts'] : null;
    final parts = rawParts is List ? rawParts : const <Object?>[];

    final text = StringBuffer();
    final reasoning = StringBuffer();
    var hasReasoning = false;
    List<ToolCall>? toolCalls;
    List<MessageOutputPart>? multiContent;
    String? messageSignature;

    for (final rawPart in parts) {
      if (rawPart is! Map) continue;
      final part = Map<String, dynamic>.from(rawPart);
      final signature = _signatureOf(part);
      final functionCall = part['functionCall'];
      final executableCode = part['executableCode'];
      final codeResult = part['codeExecutionResult'];
      // Gemini API uses camelCase (inlineData, mimeType) in responses
      final inlineData = part['inlineData'] ?? part['inline_data'];
      final isOutputPart =
          executableCode is Map || codeResult is Map || inlineData is Map;

      // The signature of text (and of a part of its own) belongs to the
      // message; output parts and function calls keep their own.
      if (signature != null && functionCall == null && !isOutputPart) {
        messageSignature = signature;
      }

      final partText = part['text'];
      if (part['thought'] == true) {
        if (partText is String && partText.isNotEmpty) {
          reasoning.write(partText);
          hasReasoning = true;
        }
      } else if (partText is String) {
        // Handle text
        text.write(partText);
      }

      // Handle function calls
      if (functionCall is Map) {
        final args = functionCall['args'];
        (toolCalls ??= []).add(
          ToolCall(
            id: _uuid.v4(),
            function: FunctionCall(
              name: '${functionCall['name'] ?? ''}',
              arguments: jsonEncode(args is Map ? args : const {}),
            ),
            extra: signature == null
                ? null
                : {geminiThoughtSignatureKey: signature},
          ),
        );
      }

      if (codeResult is Map) {
        (multiContent ??= []).add(
          _specialOutputPart(
            'codeExecutionResult',
            codeResult,
            '${codeResult['output'] ?? ''}',
            signature,
          ),
        );
      }
      if (executableCode is Map) {
        (multiContent ??= []).add(
          _specialOutputPart(
            'executableCode',
            executableCode,
            '${executableCode['code'] ?? ''}',
            signature,
          ),
        );
      }

      // Handle inline data (multimodal output)
      if (inlineData is Map) {
        final outPart = _inlineOutputPart(inlineData, signature);
        if (outPart != null) (multiContent ??= []).add(outPart);
      }
    }

    // Build response metadata
    final usage = usageMetadata == null ? null : usageToSchema(usageMetadata);
    final finishReason = _mapFinishReason(candidate['finishReason'] as String?);
    final logprobsResult = candidate['logprobsResult'];
    final logProbs = logprobsResult is Map
        ? logprobsToSchema(Map<String, dynamic>.from(logprobsResult))
        : null;
    final responseMeta =
        usage != null || finishReason != null || logProbs != null
            ? ResponseMeta(
                usage: usage,
                finishReason: finishReason,
                logProbs: logProbs,
              )
            : null;

    final grounding = candidate['groundingMetadata'];
    final extra = <String, dynamic>{
      if (messageSignature != null) geminiThoughtSignatureKey: messageSignature,
      if (grounding is Map)
        geminiGroundMetadataKey: Map<String, dynamic>.from(grounding),
    };

    final textContent = text.toString();
    final message = Message(
      role: RoleType.assistant,
      content: textContent,
      reasoningContent: hasReasoning ? reasoning.toString() : null,
      toolCalls: toolCalls,
      assistantGenMultiContent: multiContent,
      responseMeta: responseMeta,
      extra: extra.isEmpty ? null : extra,
    );
    return (
      message: message,
      hasPayload: textContent.isNotEmpty ||
          hasReasoning ||
          toolCalls != null ||
          multiContent != null,
    );
  }

  static String? _signatureOf(Map<String, dynamic> part) {
    final signature = part['thoughtSignature'] ?? part['thought_signature'];
    return signature is String && signature.isNotEmpty ? signature : null;
  }

  static MessageOutputPart _specialOutputPart(
    String key,
    Map<dynamic, dynamic> value,
    String text,
    String? signature,
  ) =>
      MessageOutputPart(
        type: ChatMessagePartType.text,
        text: text,
        extra: {
          geminiSpecialPartKey: {key: Map<String, dynamic>.from(value)},
          if (signature != null) geminiThoughtSignatureKey: signature,
        },
      );

  static MessageOutputPart? _inlineOutputPart(
    Map<dynamic, dynamic> inlineData,
    String? signature,
  ) {
    // Support both camelCase (mimeType) and snake_case (mime_type)
    final mimeType =
        (inlineData['mimeType'] ?? inlineData['mime_type']) as String? ?? '';
    final data = inlineData['data'] as String?;
    if (data == null) return null;
    final dataUrl = 'data:$mimeType;base64,$data';
    final media = MessagePartCommon(url: dataUrl, mimeType: mimeType);
    final extra =
        signature == null ? null : {geminiThoughtSignatureKey: signature};

    if (mimeType.startsWith('image/')) {
      return MessageOutputPart(
        type: ChatMessagePartType.imageUrl,
        image: media,
        extra: extra,
      );
    } else if (mimeType.startsWith('audio/')) {
      return MessageOutputPart(
        type: ChatMessagePartType.audioUrl,
        audio: media,
        extra: extra,
      );
    } else if (mimeType.startsWith('video/')) {
      return MessageOutputPart(
        type: ChatMessagePartType.videoUrl,
        video: media,
        extra: extra,
      );
    }
    return null;
  }

  /// The token usage of a REST `usageMetadata` object.
  ///
  /// Port of the usage mapping of eino-ext `convResponse`: the completion
  /// tokens include the thinking tokens, which are also the reasoning
  /// tokens; cached content tokens are the cached prompt tokens.
  static TokenUsage usageToSchema(Map<String, dynamic> usageMetadata) {
    int? count(String key) => (usageMetadata[key] as num?)?.toInt();
    final promptTokens = count('promptTokenCount') ?? 0;
    final thoughts = count('thoughtsTokenCount');
    final cached = count('cachedContentTokenCount');
    final completionTokens = (count('candidatesTokenCount') ?? 0) + (thoughts ?? 0);
    return TokenUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens:
          count('totalTokenCount') ?? (promptTokens + completionTokens),
      promptTokenDetails:
          cached == null ? null : PromptTokenDetails(cachedTokens: cached),
      completionTokenDetails: thoughts == null
          ? null
          : CompletionTokenDetails(reasoningTokens: thoughts),
    );
  }

  /// The log probabilities of a REST `logprobsResult` object, or `null` when
  /// it has no chosen candidate.
  ///
  /// Port of eino-ext `convLogprobs`.
  static LogProbs? logprobsToSchema(Map<String, dynamic> logprobsResult) {
    final chosen = logprobsResult['chosenCandidates'];
    if (chosen is! List || chosen.isEmpty) return null;
    final top = logprobsResult['topCandidates'];
    final topList = top is List ? top : const <Object?>[];

    double logProbability(Map<dynamic, dynamic> candidate) =>
        (candidate['logProbability'] as num?)?.toDouble() ?? 0;

    final content = <LogProb>[];
    for (var i = 0; i < chosen.length; i++) {
      final candidate = chosen[i];
      if (candidate is! Map) continue;
      final topLogProbs = <TopLogProb>[];
      final entry = i < topList.length ? topList[i] : null;
      if (entry is Map && entry['candidates'] is List) {
        for (final alternative in entry['candidates'] as List) {
          if (alternative is! Map) continue;
          topLogProbs.add(
            TopLogProb(
              token: '${alternative['token'] ?? ''}',
              logProb: logProbability(alternative),
            ),
          );
        }
      }
      content.add(
        LogProb(
          token: '${candidate['token'] ?? ''}',
          logProb: logProbability(candidate),
          topLogProbs: topLogProbs,
        ),
      );
    }
    return content.isEmpty ? null : LogProbs(content: content);
  }

  /// Map Gemini finish reason to standard format
  static String? _mapFinishReason(String? reason) {
    if (reason == null) return null;
    switch (reason) {
      case 'STOP':
        return 'stop';
      case 'MAX_TOKENS':
        return 'length';
      case 'SAFETY':
        return 'content_filter';
      case 'RECITATION':
        return 'content_filter';
      case 'OTHER':
        return 'other';
      default:
        return reason.toLowerCase();
    }
  }

  /// Convert ToolInfo to Gemini function declaration
  static Map<String, dynamic> toolInfoToGemini(ToolInfo tool) {
    final declaration = <String, dynamic>{
      'name': tool.function.name,
    };

    if (tool.function.description != null) {
      declaration['description'] = tool.function.description;
    }

    final rawSchema = tool.function.parametersJsonSchema;
    if (rawSchema != null) {
      // A JSON Schema document given as it is goes, unchanged, where
      // eino-ext puts every schema: `parametersJsonSchema`.
      declaration['parametersJsonSchema'] = rawSchema;
    } else if (tool.function.parameters != null) {
      declaration['parameters'] = _convertSchema(tool.function.parameters!);
    }

    return declaration;
  }

  /// Convert JSONSchema to Gemini format
  static Map<String, dynamic> _convertSchema(JSONSchema schema) {
    final result = <String, dynamic>{
      'type': schema.type,
    };

    if (schema.properties.isNotEmpty) {
      result['properties'] = schema.properties.map(
        (key, value) => MapEntry(key, _convertProperty(value)),
      );
    }

    if (schema.required.isNotEmpty) {
      result['required'] = schema.required;
    }

    return result;
  }

  /// Convert JSONSchemaProperty to Gemini format
  static Map<String, dynamic> _convertProperty(JSONSchemaProperty prop) {
    final result = <String, dynamic>{
      'type': prop.type,
    };

    if (prop.description != null) {
      result['description'] = prop.description;
    }

    if (prop.enumValues != null && prop.enumValues!.isNotEmpty) {
      result['enum'] = prop.enumValues;
    }

    if (prop.items != null) {
      result['items'] = _convertProperty(prop.items!);
    }

    if (prop.properties != null && prop.properties!.isNotEmpty) {
      result['properties'] = prop.properties!.map(
        (key, value) => MapEntry(key, _convertProperty(value)),
      );
    }

    if (prop.required != null && prop.required!.isNotEmpty) {
      result['required'] = prop.required;
    }

    return result;
  }

  /// Convert ToolChoice to Gemini function calling config mode
  static String toolChoiceToGemini(ToolChoice choice) {
    switch (choice) {
      case ToolChoice.forbidden:
        return 'NONE';
      case ToolChoice.allowed:
        return 'AUTO';
      case ToolChoice.forced:
        return 'ANY';
    }
  }

  /// The `toolConfig` of a request with [tools] for [choice], or `null` when
  /// there is no choice to express.
  ///
  /// Port of eino-ext `populateToolChoice`: [ToolChoice.forbidden] is
  /// `NONE`; [ToolChoice.allowed] is `AUTO`, or `VALIDATED` restricted to
  /// [allowedToolNames]; [ToolChoice.forced] is `ANY`, restricted to
  /// [allowedToolNames] when there are any. Throws an [ArgumentError] when an
  /// allowed name is not among the function declarations of [tools], or when
  /// the choice is forced and [tools] is empty.
  static Map<String, dynamic>? toolConfigToGemini(
    ToolChoice? choice, {
    required List<Map<String, dynamic>> tools,
    List<String>? allowedToolNames,
  }) {
    if (choice == null) return null;
    final allowed = allowedToolNames ?? const <String>[];

    void validateAllowedToolNames() {
      final declared = {
        for (final tool in tools)
          for (final declaration
              in tool['functionDeclarations'] as List<Object?>? ?? const [])
            if (declaration is Map) declaration['name'],
      };
      for (final name in allowed) {
        if (!declared.contains(name)) {
          throw ArgumentError.value(
            allowedToolNames,
            'allowedToolNames',
            'allowed tool $name not found in request tools',
          );
        }
      }
    }

    Map<String, dynamic> config(String mode, [List<String>? names]) => {
          'functionCallingConfig': {
            'mode': mode,
            if (names != null && names.isNotEmpty) 'allowedFunctionNames': names,
          },
        };

    switch (choice) {
      case ToolChoice.forbidden:
        return config('NONE');
      case ToolChoice.allowed:
        if (allowed.isEmpty) return config('AUTO');
        validateAllowedToolNames();
        return config('VALIDATED', allowed);
      case ToolChoice.forced:
        if (tools.isEmpty) {
          throw ArgumentError('tool choice is forced but tool is not provided');
        }
        if (allowed.isNotEmpty) validateAllowedToolNames();
        return config('ANY', allowed);
    }
  }

  /// Extract system instruction from messages
  ///
  /// Returns the system instruction text and the filtered messages
  /// (without system messages).
  static (String?, List<Message>) extractSystemInstruction(
    List<Message> messages,
  ) {
    String? systemInstruction;
    final filteredMessages = <Message>[];

    for (final message in messages) {
      if (message.role == RoleType.system) {
        // Concatenate system messages if multiple
        if (systemInstruction == null) {
          systemInstruction = message.content;
        } else {
          systemInstruction = '$systemInstruction\n${message.content}';
        }
      } else {
        filteredMessages.add(message);
      }
    }

    return (systemInstruction, filteredMessages);
  }
}
