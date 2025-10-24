import '../../../../schema/message.dart';
import '../../response_parser.dart';
import '../openai/openai_converters.dart';

/// Response parser for OpenRouter API responses
///
/// OpenRouter provides an OpenAI-compatible API but routes to many different
/// LLM providers. Some providers (especially image generation models like Gemini)
/// may return responses in formats that differ from standard OpenAI responses.
///
/// This parser handles:
/// - Standard OpenAI-compatible text responses
/// - Image generation responses with base64 or URL content
/// - Multi-modal assistant responses (text + images)
/// - Streaming responses with various content types
class OpenRouterResponseParser implements ResponseParser {
  const OpenRouterResponseParser();

  @override
  Message parseCompletionResponse(Map<String, dynamic> response) {
    final choices = response['choices'] as List<dynamic>;
    if (choices.isEmpty) {
      throw OpenRouterParseException('No choices in response');
    }

    final choice = choices.first as Map<String, dynamic>;
    final messageData = choice['message'] as Map<String, dynamic>;
    final usage = response['usage'] as Map<String, dynamic>?;

    // Check if message has separate image field (Gemini image models)
    if (messageData.containsKey('images')) {
      return _parseMessageWithImagesField(
        messageData,
        finishReason: choice['finish_reason'] as String?,
        usage: usage,
      );
    }

    // Check if content looks like image data before standard parsing
    final content = messageData['content'] as String? ?? '';
    if (_looksLikeImageContent(content)) {
      return _parseMultiModalMessage(
        messageData,
        finishReason: choice['finish_reason'] as String?,
        usage: usage,
      );
    }

    // Try standard OpenAI parsing
    return OpenAIConverters.openAIToMessage(
      messageData,
      finishReason: choice['finish_reason'] as String?,
      usage: usage,
    );
  }

  @override
  Message? parseStreamChunk(Map<String, dynamic> chunk) {
    final choices = chunk['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return null;
    }

    final choice = choices.first as Map<String, dynamic>;
    final delta = choice['delta'] as Map<String, dynamic>?;
    if (delta == null || delta.isEmpty) {
      return null;
    }

    return parseDelta(
      delta,
      finishReason: choice['finish_reason'] as String?,
    );
  }

  @override
  Message? parseDelta(
    Map<String, dynamic> delta, {
    String? finishReason,
  }) {
    if (delta.isEmpty) {
      return null;
    }

    // Extract role
    final role = delta['role'] != null
        ? _roleFromString(delta['role'] as String)
        : RoleType.assistant;

    // Check for text content
    final textContent = delta['content'] as String?;

    // Check for multi-modal content
    List<MessageOutputPart>? multiContent;

    // Image generation models might return content as a long base64 string
    // or in structured format. Check if this looks like image data.
    if (textContent != null && _looksLikeImageContent(textContent)) {
      multiContent = [_parseImageContent(textContent)];
    } else if (delta.containsKey('image') ||
        delta.containsKey('image_url') ||
        delta.containsKey('images')) {
      // Handle structured image responses
      multiContent = _parseStructuredMultiModal(delta);
    }

    // Parse tool calls if present
    List<ToolCall>? toolCalls;
    final toolCallsData = delta['tool_calls'] as List<dynamic>?;
    if (toolCallsData != null) {
      toolCalls = toolCallsData
          .map((tc) => _toolCallFromOpenAIDelta(tc as Map<String, dynamic>))
          .toList();
    }

    // Build response metadata
    ResponseMeta? responseMeta;
    if (finishReason != null) {
      responseMeta = ResponseMeta(finishReason: finishReason);
    }

    return Message(
      role: role,
      content: textContent != null && !_looksLikeImageContent(textContent)
          ? textContent
          : '',
      assistantGenMultiContent: multiContent,
      toolCalls: toolCalls,
      responseMeta: responseMeta,
    );
  }

  /// Parse a message with separate images field (Gemini format)
  Message _parseMessageWithImagesField(
    Map<String, dynamic> messageData, {
    String? finishReason,
    Map<String, dynamic>? usage,
  }) {
    final role = _roleFromString(messageData['role'] as String);
    final content = messageData['content'] as String? ?? '';
    final images = messageData['images'] as List<dynamic>?;

    // Parse images into MessageOutputPart list
    List<MessageOutputPart>? multiContent;
    if (images != null && images.isNotEmpty) {
      multiContent = [];
      for (final image in images) {
        if (image is String) {
          multiContent.add(_parseImageContent(image));
        } else if (image is Map<String, dynamic>) {
          multiContent.add(_parseImageObject(image));
        }
      }
    }

    // Build response metadata
    ResponseMeta? responseMeta;
    if (finishReason != null || usage != null) {
      responseMeta = ResponseMeta(
        finishReason: finishReason,
        usage: usage != null ? _usageFromMap(usage) : null,
      );
    }

    return Message(
      role: role,
      content: content,
      assistantGenMultiContent: multiContent,
      responseMeta: responseMeta,
    );
  }

  /// Parse a message that contains multi-modal content
  Message _parseMultiModalMessage(
    Map<String, dynamic> messageData, {
    String? finishReason,
    Map<String, dynamic>? usage,
  }) {
    final role = _roleFromString(messageData['role'] as String);
    final content = messageData['content'] as String? ?? '';

    // Check if content looks like image data
    List<MessageOutputPart>? multiContent;
    if (_looksLikeImageContent(content)) {
      multiContent = [_parseImageContent(content)];
    }

    // Build response metadata
    ResponseMeta? responseMeta;
    if (finishReason != null || usage != null) {
      responseMeta = ResponseMeta(
        finishReason: finishReason,
        usage: usage != null ? _usageFromMap(usage) : null,
      );
    }

    return Message(
      role: role,
      content: multiContent != null ? '' : content,
      assistantGenMultiContent: multiContent,
      responseMeta: responseMeta,
    );
  }

  /// Check if content looks like image data (base64 or data URL)
  bool _looksLikeImageContent(String content) {
    if (content.isEmpty) return false;

    // Check for data URL format
    if (content.startsWith('data:image/')) {
      return true;
    }

    // Check for PNG signature in base64
    if (content.startsWith('iVBORw0KGgo')) {
      return true;
    }

    // Check for JPEG signature in base64
    if (content.startsWith('/9j/')) {
      return true;
    }

    // Check if it's a reasonably long string that looks like base64
    // (more than 50 chars and contains only base64 characters)
    if (content.length > 50) {
      final base64Pattern = RegExp(r'^[A-Za-z0-9+/=]+$');
      // Sample first 100 chars (or full string if shorter) to check pattern
      final sampleLength = content.length > 100 ? 100 : content.length;
      final sample = content.substring(0, sampleLength);
      if (base64Pattern.hasMatch(sample)) {
        return true;
      }
    }

    return false;
  }

  /// Parse image content from string
  MessageOutputPart _parseImageContent(String content) {
    String? url;
    String? base64Data;
    String? mimeType;

    if (content.startsWith('data:')) {
      // Data URL format: data:image/png;base64,iVBORw0KGgo...
      url = content;

      // Extract mime type
      final match = RegExp(r'data:([^;]+);').firstMatch(content);
      if (match != null) {
        mimeType = match.group(1);
      }

      // Extract base64 part
      final base64Match = RegExp(r'base64,(.+)').firstMatch(content);
      if (base64Match != null) {
        base64Data = base64Match.group(1);
      }
    } else {
      // Assume it's raw base64
      base64Data = content;
      mimeType = 'image/png'; // Default mime type
    }

    return MessageOutputPart(
      type: ChatMessagePartType.imageUrl,
      image: MessagePartCommon(
        url: url,
        base64Data: base64Data,
        mimeType: mimeType,
      ),
    );
  }

  /// Parse structured multi-modal content from delta
  List<MessageOutputPart> _parseStructuredMultiModal(
      Map<String, dynamic> delta) {
    final parts = <MessageOutputPart>[];

    // Handle 'image' field
    if (delta.containsKey('image')) {
      final imageData = delta['image'];
      if (imageData is String) {
        parts.add(_parseImageContent(imageData));
      } else if (imageData is Map<String, dynamic>) {
        parts.add(_parseImageObject(imageData));
      }
    }

    // Handle 'image_url' field
    if (delta.containsKey('image_url')) {
      final imageUrl = delta['image_url'];
      if (imageUrl is String) {
        parts.add(MessageOutputPart(
          type: ChatMessagePartType.imageUrl,
          image: MessagePartCommon(url: imageUrl),
        ));
      } else if (imageUrl is Map<String, dynamic>) {
        parts.add(_parseImageObject(imageUrl));
      }
    }

    // Handle 'images' array
    if (delta.containsKey('images')) {
      final images = delta['images'] as List<dynamic>?;
      if (images != null) {
        for (final image in images) {
          if (image is String) {
            parts.add(_parseImageContent(image));
          } else if (image is Map<String, dynamic>) {
            parts.add(_parseImageObject(image));
          }
        }
      }
    }

    return parts;
  }

  /// Parse an image object into MessageOutputPart
  MessageOutputPart _parseImageObject(Map<String, dynamic> imageObj) {
    // Handle OpenAI-style image_url object
    if (imageObj.containsKey('image_url')) {
      final imageUrl = imageObj['image_url'];
      if (imageUrl is Map<String, dynamic>) {
        return MessageOutputPart(
          type: ChatMessagePartType.imageUrl,
          image: MessagePartCommon(
            url: imageUrl['url'] as String?,
            base64Data: imageUrl['base64'] as String?,
            mimeType: imageUrl['mime_type'] as String? ??
                imageUrl['mimeType'] as String?,
          ),
        );
      } else if (imageUrl is String) {
        return MessageOutputPart(
          type: ChatMessagePartType.imageUrl,
          image: MessagePartCommon(url: imageUrl),
        );
      }
    }

    // Handle direct url/base64 fields
    return MessageOutputPart(
      type: ChatMessagePartType.imageUrl,
      image: MessagePartCommon(
        url: imageObj['url'] as String?,
        base64Data: imageObj['base64'] as String?,
        mimeType: imageObj['mime_type'] as String? ??
            imageObj['mimeType'] as String?,
      ),
    );
  }

  /// Convert role string to RoleType
  RoleType _roleFromString(String role) {
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

  /// Convert OpenAI tool call delta to ToolCall
  ToolCall _toolCallFromOpenAIDelta(Map<String, dynamic> delta) {
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

  /// Convert usage map to TokenUsage
  TokenUsage _usageFromMap(Map<String, dynamic> usage) {
    return TokenUsage(
      promptTokens: usage['prompt_tokens'] as int? ?? 0,
      completionTokens: usage['completion_tokens'] as int? ?? 0,
      totalTokens: usage['total_tokens'] as int? ?? 0,
      promptTokenDetails: usage['prompt_tokens_details'] != null
          ? PromptTokenDetails(
              cachedTokens:
                  usage['prompt_tokens_details']['cached_tokens'] as int? ?? 0,
            )
          : null,
    );
  }
}

/// Exception thrown when parsing OpenRouter responses fails
class OpenRouterParseException implements Exception {
  OpenRouterParseException(this.message);

  final String message;

  @override
  String toString() => 'OpenRouterParseException: $message';
}
