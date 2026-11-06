import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';

/// Key under `Message.extra` holding the provider's raw `reasoning_details`
/// blocks so they can be echoed back on the next request.
const String reasoningDetailsKey = 'reasoning_details';

/// Key under `MessageOutputPart.extra` of a generated audio part holding the
/// audio's id, which is sent back to refer to it (eino-ext
/// `openai-audio-id`).
const String openAIGeneratedAudioIdKey = 'openai-audio-id';

/// Converters between Threepio schema and OpenAI API format
class OpenAIConverters {
  /// Convert Message to OpenAI message format
  ///
  /// With [goCompatible] (the OpenAI and OpenAI-compatible models; OpenRouter
  /// keeps the older form) an assistant message also carries what eino-ext's
  /// `libs/acl/openai` sends: its `reasoning_content`, the text parts of
  /// `assistantGenMultiContent` as content parts when it has no plain
  /// content, and the id of a generated audio (`audio.id`) in place of its
  /// content. Parts eino-ext rejects there are skipped instead.
  static Map<String, dynamic> messageToOpenAI(
    Message message, {
    bool goCompatible = false,
  }) {
    final result = <String, dynamic>{
      'role': _roleToOpenAI(message.role),
    };

    // Add content based on role and content type
    if (message.userInputMultiContent != null &&
        message.userInputMultiContent!.isNotEmpty) {
      // Multi-modal content
      result['content'] =
          message.userInputMultiContent!.map(_inputPartToOpenAI).toList();
    } else if (message.content.isNotEmpty) {
      // Simple text content
      result['content'] = message.content;
    } else if (message.role == RoleType.assistant) {
      // An assistant turn that only carried tool calls: content is null,
      // not absent — some providers reject a missing key.
      result['content'] = null;
    } else if (message.role == RoleType.tool) {
      result['content'] = '';
    }

    // Echo provider reasoning blocks back verbatim (interleaved thinking).
    final reasoningDetails = message.extra?[reasoningDetailsKey];
    if (message.role == RoleType.assistant &&
        reasoningDetails is List &&
        reasoningDetails.isNotEmpty) {
      result['reasoning_details'] = reasoningDetails;
    }

    // Add name if present
    if (message.name != null) {
      result['name'] = message.name;
    }

    // Add tool calls for assistant messages
    if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
      result['tool_calls'] = message.toolCalls!.map(_toolCallToOpenAI).toList();
    }

    // Add tool call ID for tool messages
    if (message.toolCallId != null) {
      result['tool_call_id'] = message.toolCallId;
    }

    if (goCompatible && message.role == RoleType.assistant) {
      _addGeneratedContent(message, result);
    }

    return result;
  }

  /// The parts of an assistant message eino-ext's `libs/acl/openai` sends
  /// back (`buildMessageFromAssistantGenMultiContent`).
  static void _addGeneratedContent(
    Message message,
    Map<String, dynamic> result,
  ) {
    var reasoning = message.reasoningContent ?? '';
    final parts = message.assistantGenMultiContent ?? const [];
    final textParts = <Map<String, dynamic>>[];
    String? audioId;
    for (final part in parts) {
      switch (part.type) {
        case ChatMessagePartType.text:
          textParts.add({'type': 'text', 'text': part.text ?? ''});
        case ChatMessagePartType.reasoning:
          final text = part.reasoning?.text ?? '';
          if (text.isNotEmpty) reasoning = text;
        case ChatMessagePartType.audioUrl:
          final id = part.extra?[openAIGeneratedAudioIdKey];
          if (id is String && id.isNotEmpty) audioId ??= id;
        default:
          break;
      }
    }
    if (reasoning.isNotEmpty) result['reasoning_content'] = reasoning;
    if (audioId != null) {
      result.remove('content');
      result['audio'] = {'id': audioId};
    } else if (message.content.isEmpty && textParts.isNotEmpty) {
      result['content'] = textParts;
    }
  }

  /// Convert OpenAI message to Message
  static Message openAIToMessage(
    Map<String, dynamic> openAIMessage, {
    String? finishReason,
    Map<String, dynamic>? usage,
  }) {
    final role = _roleFromOpenAI(openAIMessage['role'] as String);
    final content = openAIMessage['content'] as String? ?? '';

    // Parse tool calls if present
    List<ToolCall>? toolCalls;
    final toolCallsData = openAIMessage['tool_calls'] as List<dynamic>?;
    if (toolCallsData != null) {
      toolCalls = toolCallsData
          .map((tc) => _toolCallFromOpenAI(tc as Map<String, dynamic>))
          .toList();
    }

    // Build response metadata
    ResponseMeta? responseMeta;
    if (finishReason != null || usage != null) {
      responseMeta = ResponseMeta(
        finishReason: finishReason,
        usage: usage != null ? _usageFromOpenAI(usage) : null,
      );
    }

    return Message(
      role: role,
      content: content,
      name: openAIMessage['name'] as String?,
      toolCalls: toolCalls,
      toolCallId: openAIMessage['tool_call_id'] as String?,
      responseMeta: responseMeta,
    );
  }

  /// Convert OpenAI delta (streaming chunk) to Message
  static Message openAIDeltaToMessage(
    Map<String, dynamic> delta, {
    String? finishReason,
  }) {
    final role = delta['role'] != null
        ? _roleFromOpenAI(delta['role'] as String)
        : RoleType.assistant;

    final content = delta['content'] as String? ?? '';

    // Parse tool calls from delta
    List<ToolCall>? toolCalls;
    final toolCallsData = delta['tool_calls'] as List<dynamic>?;
    if (toolCallsData != null) {
      toolCalls = toolCallsData
          .map((tc) => _toolCallFromOpenAIDelta(tc as Map<String, dynamic>))
          .toList();
    }

    ResponseMeta? responseMeta;
    if (finishReason != null) {
      responseMeta = ResponseMeta(finishReason: finishReason);
    }

    return Message(
      role: role,
      content: content,
      toolCalls: toolCalls,
      responseMeta: responseMeta,
    );
  }

  /// Convert ToolInfo to OpenAI tool format
  ///
  /// A tool info made with `ToolInfo.fromJsonSchemaMap` sends its JSON Schema
  /// document as it was given (`FunctionInfo.parametersJsonSchema`). Unlike
  /// eino-ext acl/openai's `toTools`, whose `sortArrayFields` sorts the
  /// `required` names of every object schema, nothing is reordered: threepio
  /// sends schemas as given (coordinator decision 2 after P11; the sort was
  /// left out at P11 already).
  static Map<String, dynamic> toolInfoToOpenAI(ToolInfo tool) {
    final rawSchema = tool.function.parametersJsonSchema;
    return {
      'type': 'function',
      'function': {
        'name': tool.function.name,
        if (tool.function.description != null)
          'description': tool.function.description,
        if (rawSchema != null)
          'parameters': rawSchema
        else if (tool.function.parameters != null)
          'parameters': _jsonSchemaToOpenAI(tool.function.parameters!),
        if (tool.function.strict != null) 'strict': tool.function.strict,
      },
    };
  }

  /// Convert ToolChoice to OpenAI format
  static dynamic toolChoiceToOpenAI(ToolChoice choice) {
    switch (choice) {
      case ToolChoice.forbidden:
        return 'none';
      case ToolChoice.allowed:
        return 'auto';
      case ToolChoice.forced:
        return 'required';
    }
  }

  /// Convert role to OpenAI format
  static String _roleToOpenAI(RoleType role) {
    switch (role) {
      case RoleType.user:
        return 'user';
      case RoleType.assistant:
        return 'assistant';
      case RoleType.system:
        return 'system';
      case RoleType.tool:
        return 'tool';
    }
  }

  /// Convert role from OpenAI format
  static RoleType _roleFromOpenAI(String role) {
    switch (role) {
      case 'user':
        return RoleType.user;
      case 'assistant':
        return RoleType.assistant;
      case 'system':
        return RoleType.system;
      case 'tool':
        return RoleType.tool;
      default:
        throw ArgumentError('Unknown role: $role');
    }
  }

  /// Convert MessageInputPart to OpenAI content format
  static Map<String, dynamic> _inputPartToOpenAI(MessageInputPart part) {
    switch (part.type) {
      case ChatMessagePartType.text:
        return {
          'type': 'text',
          'text': part.text,
        };
      case ChatMessagePartType.imageUrl:
        final image = part.image;
        if (image == null) {
          throw ArgumentError(
            "the 'image' field is required for parts of type 'image_url'",
          );
        }
        return {
          'type': 'image_url',
          'image_url': {
            'url': _urlOrDataUrl(image.common, 'image'),
            if (image.detail != null) 'detail': image.detail!.name,
          },
        };
      case ChatMessagePartType.fileUrl:
        // OpenRouter / OpenAI file input: inline data URL plus a file name.
        final common = part.file?.common;
        return {
          'type': 'file',
          'file': {
            'filename': part.file?.name ??
                (part.extra?['filename'] as String?) ??
                // Where the name was kept before MessageInputFile.name.
                // ignore: deprecated_member_use_from_same_package
                (common?.extra?['filename'] as String?) ??
                'document',
            'file_data': common?.url ??
                'data:${common?.mimeType ?? 'application/octet-stream'};base64,${common?.base64Data ?? ''}',
          },
        };
      case ChatMessagePartType.audioUrl:
        final audio = part.audio?.common;
        if (audio == null) {
          throw ArgumentError(
            "the 'audio' field is required for parts of type 'audio_url'",
          );
        }
        if (audio.base64Data != null) {
          final format = _audioFormats[audio.mimeType];
          if (format == null) {
            throw ArgumentError(
              "the 'format' field is required when type is audio_url: "
              'unsupported audio MIME type ${audio.mimeType}',
            );
          }
          return {
            'type': 'input_audio',
            'input_audio': {'data': audio.base64Data, 'format': format},
          };
        }
        if (audio.url != null) {
          throw ArgumentError(
            'for user role, audio message part does not accept URL, only '
            'base64 data is supported',
          );
        }
        throw ArgumentError('audio message part must have url or base64 data');
      case ChatMessagePartType.videoUrl:
        final video = part.video?.common;
        if (video == null) {
          throw ArgumentError(
            "the 'video' field is required for parts of type 'video_url'",
          );
        }
        return {
          'type': 'video_url',
          'video_url': {'url': _urlOrDataUrl(video, 'video')},
        };
      case ChatMessagePartType.reasoning:
      case ChatMessagePartType.toolSearchResult:
        throw UnsupportedError(
          'OpenAI does not accept ${part.type.name} parts as input',
        );
    }
  }

  /// The URL of a media part, or a data URL made of its base64 data and MIME
  /// type (eino-ext requires the MIME type with base64 data).
  static String _urlOrDataUrl(MessagePartCommon common, String kind) {
    if (common.url != null) return common.url!;
    final data = common.base64Data;
    if (data == null) {
      throw ArgumentError('$kind message part must have url or base64 data');
    }
    final mimeType = common.mimeType;
    if (mimeType == null || mimeType.isEmpty) {
      throw ArgumentError('mimetype is required when using base64data');
    }
    return 'data:$mimeType;base64,$data';
  }

  /// Audio MIME types → the `input_audio` formats OpenAI accepts. eino-ext's
  /// table maps `audio/mpeg` to `wav` and `audio/x-wav` to `mp3`, which is
  /// swapped; this one is not.
  static const _audioFormats = {
    'audio/wav': 'wav',
    'audio/vnd.wav': 'wav',
    'audio/vnd.wave': 'wav',
    'audio/wave': 'wav',
    'audio/x-pn-wav': 'wav',
    'audio/x-wav': 'wav',
    'audio/mpeg': 'mp3',
    'audio/mpeg3': 'mp3',
    'audio/x-mpeg-3': 'mp3',
    'audio/mp3': 'mp3',
  };

  /// Convert ToolCall to OpenAI format
  static Map<String, dynamic> _toolCallToOpenAI(ToolCall toolCall) {
    return {
      'id': toolCall.id,
      // A call assembled from stream fragments may carry no type; the API
      // only knows function calls (eino-ext always sends `function`).
      'type': toolCall.type.isEmpty ? 'function' : toolCall.type,
      'function': {
        'name': toolCall.function.name,
        'arguments': toolCall.function.arguments,
      },
      if (toolCall.index != null) 'index': toolCall.index,
    };
  }

  /// Convert OpenAI tool call to ToolCall
  static ToolCall _toolCallFromOpenAI(Map<String, dynamic> openAIToolCall) {
    final function = openAIToolCall['function'] as Map<String, dynamic>;
    return ToolCall(
      id: openAIToolCall['id'] as String,
      type: openAIToolCall['type'] as String? ?? 'function',
      function: FunctionCall(
        name: function['name'] as String,
        arguments: function['arguments'] as String,
      ),
      index: openAIToolCall['index'] as int?,
    );
  }

  /// Convert OpenAI tool call delta to ToolCall
  static ToolCall _toolCallFromOpenAIDelta(Map<String, dynamic> delta) {
    final function = delta['function'] as Map<String, dynamic>? ?? {};
    return ToolCall(
      id: delta['id'] as String? ?? '',
      type: delta['type'] as String? ?? 'function',
      function: FunctionCall(
        name: function['name'] as String? ?? '',
        arguments: function['arguments'] as String? ?? '',
      ),
      index: delta['index'] as int?,
    );
  }

  /// Convert JSONSchema to OpenAI parameters format
  static Map<String, dynamic> _jsonSchemaToOpenAI(JSONSchema schema) {
    return {
      'type': schema.type,
      'properties': schema.properties.map(
        (key, value) => MapEntry(key, _jsonSchemaPropertyToOpenAI(value)),
      ),
      if (schema.required.isNotEmpty) 'required': schema.required,
      'additionalProperties': schema.additionalProperties,
    };
  }

  /// Convert JSONSchemaProperty to OpenAI format
  static Map<String, dynamic> _jsonSchemaPropertyToOpenAI(
    JSONSchemaProperty property,
  ) {
    final result = <String, dynamic>{
      'type': property.type,
    };

    if (property.description != null) {
      result['description'] = property.description;
    }

    if (property.enumValues != null) {
      result['enum'] = property.enumValues;
    }

    if (property.items != null) {
      result['items'] = _jsonSchemaPropertyToOpenAI(property.items!);
    }

    if (property.properties != null) {
      result['properties'] = property.properties!.map(
        (key, value) => MapEntry(key, _jsonSchemaPropertyToOpenAI(value)),
      );
    }

    if (property.required != null && property.required!.isNotEmpty) {
      result['required'] = property.required;
    }

    if (property.additionalProperties != null) {
      result['additionalProperties'] = property.additionalProperties;
    }

    return result;
  }

  /// Convert OpenAI usage to TokenUsage
  static TokenUsage _usageFromOpenAI(Map<String, dynamic> usage) {
    return TokenUsage(
      promptTokens: usage['prompt_tokens'] as int,
      completionTokens: usage['completion_tokens'] as int,
      totalTokens: usage['total_tokens'] as int,
      promptTokenDetails: usage['prompt_tokens_details'] != null
          ? PromptTokenDetails(
              cachedTokens:
                  usage['prompt_tokens_details']['cached_tokens'] as int? ?? 0,
            )
          : null,
    );
  }
}
