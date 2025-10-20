import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';

/// Converters between Threepio schema and OpenAI API format
class OpenAIConverters {
  /// Convert Message to OpenAI message format
  static Map<String, dynamic> messageToOpenAI(Message message) {
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

    return result;
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
  static Map<String, dynamic> toolInfoToOpenAI(ToolInfo tool) {
    return {
      'type': 'function',
      'function': {
        'name': tool.function.name,
        if (tool.function.description != null)
          'description': tool.function.description,
        if (tool.function.parameters != null)
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
        return {
          'type': 'image_url',
          'image_url': {
            'url': part.image!.common.url,
            if (part.image!.detail != null) 'detail': part.image!.detail!.name,
          },
        };
      case ChatMessagePartType.audioUrl:
      case ChatMessagePartType.videoUrl:
      case ChatMessagePartType.fileUrl:
        throw UnimplementedError(
            'OpenAI does not support ${part.type} in standard API');
    }
  }

  /// Convert ToolCall to OpenAI format
  static Map<String, dynamic> _toolCallToOpenAI(ToolCall toolCall) {
    return {
      'id': toolCall.id,
      'type': toolCall.type,
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
