import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';

/// Converters for transforming between Threepio and Gemini API formats
///
/// Handles conversion of:
/// - Messages (including multimodal content)
/// - Tool definitions and function calls
/// - Tool choice settings
class GeminiConverters {
  static const _uuid = Uuid();

  /// Convert Threepio Message to Gemini content format
  ///
  /// Role mapping:
  /// - user -> "user"
  /// - assistant -> "model"
  /// - tool -> "user" with functionResponse part
  /// - system -> handled separately as systemInstruction
  static Map<String, dynamic> messageToGemini(Message message) {
    final role = _roleToGemini(message.role);
    final parts = <Map<String, dynamic>>[];

    // Handle tool response messages
    if (message.role == RoleType.tool && message.toolCallId != null) {
      parts.add({
        'functionResponse': {
          'name': message.toolName ?? 'function',
          'response': {
            'result': message.content,
          },
        },
      });
      return {'role': role, 'parts': parts};
    }

    // Handle multimodal input content
    if (message.userInputMultiContent != null &&
        message.userInputMultiContent!.isNotEmpty) {
      for (final part in message.userInputMultiContent!) {
        parts.add(_inputPartToGemini(part));
      }
    }

    // Handle text content
    if (message.content.isNotEmpty && parts.isEmpty) {
      parts.add({'text': message.content});
    } else if (message.content.isNotEmpty) {
      // Add text if we have multimodal but also text content
      parts.insert(0, {'text': message.content});
    }

    // Handle tool calls from assistant
    if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
      for (final toolCall in message.toolCalls!) {
        // Parse the arguments string to get the map
        Map<String, dynamic> args;
        try {
          args = jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
        } catch (_) {
          args = {};
        }
        parts.add({
          'functionCall': {
            'name': toolCall.function.name,
            'args': args,
          },
        });
      }
    }

    return {'role': role, 'parts': parts};
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

  /// Convert Threepio input part to Gemini part format
  static Map<String, dynamic> _inputPartToGemini(MessageInputPart part) {
    switch (part.type) {
      case ChatMessagePartType.text:
        return {'text': part.text!};

      case ChatMessagePartType.imageUrl:
        final url = part.image?.common.url ?? '';
        return _mediaToGemini(url, 'image');

      case ChatMessagePartType.audioUrl:
        final url = part.audio?.common.url ?? '';
        return _mediaToGemini(url, 'audio');

      case ChatMessagePartType.videoUrl:
        final url = part.video?.common.url ?? '';
        return _mediaToGemini(url, 'video');

      case ChatMessagePartType.fileUrl:
        final url = part.file?.common.url ?? '';
        return _mediaToGemini(url, 'application');
    }
  }

  /// Convert media URL to Gemini format
  ///
  /// Handles both:
  /// - Base64 data URLs (data:mime;base64,...)
  /// - Remote URLs (https://...)
  static Map<String, dynamic> _mediaToGemini(String url, String defaultType) {
    // Check if it's a data URL (base64)
    if (url.startsWith('data:')) {
      final regex = RegExp(r'data:([^;]+);base64,(.+)');
      final match = regex.firstMatch(url);
      if (match != null) {
        final mimeType = match.group(1)!;
        final data = match.group(2)!;
        return {
          'inline_data': {
            'mime_type': mimeType,
            'data': data,
          },
        };
      }
    }

    // Remote URL - use file_data
    final mimeType = _guessMimeType(url, defaultType);
    return {
      'file_data': {
        'mime_type': mimeType,
        'file_uri': url,
      },
    };
  }

  /// Guess MIME type from URL
  static String _guessMimeType(String url, String defaultType) {
    final lower = url.toLowerCase();
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
  static Message geminiToMessage(
    Map<String, dynamic> candidate, {
    Map<String, dynamic>? usageMetadata,
  }) {
    final content = candidate['content'] as Map<String, dynamic>?;
    final finishReason = candidate['finishReason'] as String?;

    if (content == null) {
      return Message.assistant('');
    }

    final parts = content['parts'] as List<dynamic>? ?? [];

    String textContent = '';
    List<ToolCall>? toolCalls;
    List<MessageOutputPart>? multiContent;

    for (final part in parts) {
      final partMap = part as Map<String, dynamic>;

      // Handle text
      if (partMap.containsKey('text')) {
        textContent += partMap['text'] as String;
      }

      // Handle function calls
      if (partMap.containsKey('functionCall')) {
        toolCalls ??= [];
        final functionCall = partMap['functionCall'] as Map<String, dynamic>;
        final args = functionCall['args'] as Map<String, dynamic>? ?? {};
        toolCalls.add(ToolCall(
          id: _uuid.v4(),
          type: 'function',
          function: FunctionCall(
            name: functionCall['name'] as String,
            arguments: jsonEncode(args),
          ),
        ));
      }

      // Handle inline data (multimodal output)
      // Note: Gemini API uses camelCase (inlineData, mimeType) in responses
      final inlineDataKey = partMap.containsKey('inlineData')
          ? 'inlineData'
          : (partMap.containsKey('inline_data') ? 'inline_data' : null);
      if (inlineDataKey != null) {
        multiContent ??= [];
        final inlineData = partMap[inlineDataKey] as Map<String, dynamic>;
        // Support both camelCase (mimeType) and snake_case (mime_type)
        final mimeType = (inlineData['mimeType'] ?? inlineData['mime_type']) as String;
        final data = inlineData['data'] as String;
        final dataUrl = 'data:$mimeType;base64,$data';

        if (mimeType.startsWith('image/')) {
          multiContent.add(MessageOutputPart(
            type: ChatMessagePartType.imageUrl,
            image: MessagePartCommon(url: dataUrl, mimeType: mimeType),
          ));
        } else if (mimeType.startsWith('audio/')) {
          multiContent.add(MessageOutputPart(
            type: ChatMessagePartType.audioUrl,
            audio: MessagePartCommon(url: dataUrl, mimeType: mimeType),
          ));
        } else if (mimeType.startsWith('video/')) {
          multiContent.add(MessageOutputPart(
            type: ChatMessagePartType.videoUrl,
            video: MessagePartCommon(url: dataUrl, mimeType: mimeType),
          ));
        }
      }
    }

    // Build response metadata
    ResponseMeta? responseMeta;
    if (usageMetadata != null || finishReason != null) {
      TokenUsage? usage;
      if (usageMetadata != null) {
        final promptTokens = usageMetadata['promptTokenCount'] as int? ?? 0;
        final completionTokens = usageMetadata['candidatesTokenCount'] as int? ?? 0;
        usage = TokenUsage(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: usageMetadata['totalTokenCount'] as int? ?? (promptTokens + completionTokens),
        );
      }
      responseMeta = ResponseMeta(
        usage: usage,
        finishReason: _mapFinishReason(finishReason),
      );
    }

    return Message(
      role: RoleType.assistant,
      content: textContent,
      toolCalls: toolCalls,
      assistantGenMultiContent: multiContent,
      responseMeta: responseMeta,
    );
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

  /// Convert Gemini streaming chunk to Message
  static Message? geminiDeltaToMessage(
    Map<String, dynamic> candidate, {
    Map<String, dynamic>? usageMetadata,
  }) {
    final content = candidate['content'] as Map<String, dynamic>?;
    if (content == null) return null;

    final parts = content['parts'] as List<dynamic>? ?? [];
    if (parts.isEmpty) return null;

    String textContent = '';
    List<ToolCall>? toolCalls;

    for (final part in parts) {
      final partMap = part as Map<String, dynamic>;

      if (partMap.containsKey('text')) {
        textContent += partMap['text'] as String;
      }

      if (partMap.containsKey('functionCall')) {
        toolCalls ??= [];
        final functionCall = partMap['functionCall'] as Map<String, dynamic>;
        final args = functionCall['args'] as Map<String, dynamic>? ?? {};
        toolCalls.add(ToolCall(
          id: _uuid.v4(),
          type: 'function',
          function: FunctionCall(
            name: functionCall['name'] as String,
            arguments: jsonEncode(args),
          ),
        ));
      }
    }

    if (textContent.isEmpty && toolCalls == null) {
      return null;
    }

    final finishReason = candidate['finishReason'] as String?;

    TokenUsage? usage;
    if (usageMetadata != null) {
      final promptTokens = usageMetadata['promptTokenCount'] as int? ?? 0;
      final completionTokens = usageMetadata['candidatesTokenCount'] as int? ?? 0;
      usage = TokenUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: usageMetadata['totalTokenCount'] as int? ?? (promptTokens + completionTokens),
      );
    }

    return Message(
      role: RoleType.assistant,
      content: textContent,
      toolCalls: toolCalls,
      responseMeta: finishReason != null || usage != null
          ? ResponseMeta(
              finishReason: _mapFinishReason(finishReason),
              usage: usage,
            )
          : null,
    );
  }

  /// Convert ToolInfo to Gemini function declaration
  static Map<String, dynamic> toolInfoToGemini(ToolInfo tool) {
    final declaration = <String, dynamic>{
      'name': tool.function.name,
    };

    if (tool.function.description != null) {
      declaration['description'] = tool.function.description;
    }

    if (tool.function.parameters != null) {
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
