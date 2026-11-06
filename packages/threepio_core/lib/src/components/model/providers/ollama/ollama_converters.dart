/// Conversion between threepio's schema and the wire format of the Ollama
/// API.
///
/// Port of the conversion functions of eino-ext
/// `components/model/ollama/chatmodel.go` (`toOllamaMessage`,
/// `toEinoMessage`, `toOllamaTools`, `schemaToToolProperty`,
/// `parseJSONToObject`) and of the JSON encoding of the Ollama API's
/// `Duration`.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../../../internal/go_duration.dart' as go_duration;
import 'ollama_config.dart';

/// The conversions of the Ollama provider. Public in `src/` for the tests;
/// not part of the package API.
@internal
abstract final class OllamaConverters {
  /// The address of the API endpoint [path] (`/api/chat`) on the server at
  /// [baseUrl], keeping the path of [baseUrl] (Go: `url.JoinPath`).
  ///
  /// An empty [baseUrl] means [OllamaConfig.defaultBaseUrl]. Throws an
  /// [ArgumentError] when [baseUrl] is not an absolute URL with a host (Go:
  /// "invalid base URL").
  static Uri endpoint(String baseUrl, String path) {
    final Uri base;
    try {
      base = Uri.parse(baseUrl.isEmpty ? OllamaConfig.defaultBaseUrl : baseUrl);
    } on FormatException catch (error) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'invalid base URL: ${error.message}',
      );
    }
    if (!base.hasScheme || base.host.isEmpty) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'invalid base URL: it needs a scheme and a host',
      );
    }
    var basePath = base.path;
    while (basePath.endsWith('/')) {
      basePath = basePath.substring(0, basePath.length - 1);
    }
    return base.replace(path: '$basePath$path');
  }

  /// The `messages` of a chat request (Go: `toOllamaMessages`).
  static List<Map<String, Object?>> messagesToOllama(List<Message> messages) =>
      [for (final message in messages) messageToOllama(message)];

  /// One message of a chat request (Go: `toOllamaMessage`).
  ///
  /// Text parts of the multimodal content are joined into `content`, image
  /// parts become `images`; Ollama only takes images as base64 data. Tool
  /// call arguments are sent as JSON objects. Throws a
  /// [ThreepioFormatException], with Go's message, for content Ollama cannot
  /// take.
  static Map<String, Object?> messageToOllama(Message message) {
    final toolCalls = [
      for (final call in message.toolCalls ?? const <ToolCall>[])
        {
          'function': {
            'name': call.function.name,
            'arguments': _argumentsObject(call.function.arguments),
          },
        },
    ];

    final userParts = message.userInputMultiContent ?? const [];
    final assistantParts = message.assistantGenMultiContent ?? const [];
    var content = message.content;
    final images = <String>[];

    if (userParts.isNotEmpty || assistantParts.isNotEmpty) {
      if (userParts.isNotEmpty && assistantParts.isNotEmpty) {
        throw const ThreepioFormatException(
          'a message cannot contain both UserInputMultiContent and '
          'AssistantGenMultiContent',
        );
      }
      final text = StringBuffer();
      if (userParts.isNotEmpty) {
        const field = 'UserInputMultiContent';
        if (message.role != RoleType.user && message.role != RoleType.tool) {
          throw ThreepioFormatException(
            'user input multi content only support user&tool role, '
            'got ${message.role.name}',
          );
        }
        for (final part in userParts) {
          switch (part.type) {
            case ChatMessagePartType.text:
              text.write(part.text ?? '');
            case ChatMessagePartType.imageUrl:
              images.add(_imageData(part.image?.common, field));
            case ChatMessagePartType.audioUrl ||
                  ChatMessagePartType.videoUrl ||
                  ChatMessagePartType.fileUrl ||
                  ChatMessagePartType.reasoning ||
                  ChatMessagePartType.toolSearchResult:
              throw ThreepioFormatException(
                'unsupported content type in $field: '
                '${partTypeWireValue(part.type)}',
              );
          }
        }
      } else {
        const field = 'AssistantGenMultiContent';
        if (message.role != RoleType.assistant) {
          throw ThreepioFormatException(
            'assistant gen multi content only support assistant role, '
            'got ${message.role.name}',
          );
        }
        for (final part in assistantParts) {
          switch (part.type) {
            case ChatMessagePartType.text:
              text.write(part.text ?? '');
            case ChatMessagePartType.imageUrl:
              images.add(_imageData(part.image, field));
            case ChatMessagePartType.audioUrl ||
                  ChatMessagePartType.videoUrl ||
                  ChatMessagePartType.fileUrl ||
                  ChatMessagePartType.reasoning ||
                  ChatMessagePartType.toolSearchResult:
              throw ThreepioFormatException(
                'unsupported content type in $field: '
                '${partTypeWireValue(part.type)}',
              );
          }
        }
      }
      content = text.toString();
    }

    final thinking = message.reasoningContent;
    final toolName = message.toolName;
    return {
      'role': message.role.name,
      'content': content,
      if (thinking != null && thinking.isNotEmpty) 'thinking': thinking,
      if (images.isNotEmpty) 'images': images,
      if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
      if (toolName != null && toolName.isNotEmpty) 'tool_name': toolName,
    };
  }

  /// The wire name of a content part type (`image_url`), for error messages.
  static String partTypeWireValue(ChatMessagePartType type) => switch (type) {
        ChatMessagePartType.text => 'text',
        ChatMessagePartType.imageUrl => 'image_url',
        ChatMessagePartType.audioUrl => 'audio_url',
        ChatMessagePartType.videoUrl => 'video_url',
        ChatMessagePartType.fileUrl => 'file_url',
        ChatMessagePartType.reasoning => 'reasoning',
        ChatMessagePartType.toolSearchResult => 'tool_search_result',
      };

  /// The base64 data of an image part, as Go checks it.
  static String _imageData(MessagePartCommon? image, String field) {
    if (image == null) {
      throw ThreepioFormatException(
        'image is required in $field, but got nil',
      );
    }
    final url = image.url;
    if (url != null) {
      throw ThreepioFormatException(
        'ollama model only supports base64-encoded strings for the raw '
        'binary, but got URL: $url',
      );
    }
    final data = image.base64Data;
    if (data == null) {
      throw ThreepioFormatException(
        'image is required in $field, but got nil Base64Data',
      );
    }
    return data;
  }

  /// Tool call arguments as the JSON object Ollama expects (Go:
  /// `parseJSONToObject`).
  static Map<String, Object?>? _argumentsObject(String arguments) {
    final Object? decoded;
    try {
      decoded = jsonDecode(arguments);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'error parsing JSON to object: ${error.message}',
        source: arguments,
        cause: error,
      );
    }
    if (decoded == null) return null;
    if (decoded is! Map) {
      throw ThreepioFormatException(
        'error parsing JSON to object: the arguments are not a JSON object',
        source: arguments,
      );
    }
    return decoded.cast<String, Object?>();
  }

  /// The `tools` of a chat request (Go: `toOllamaTools`).
  static List<Map<String, Object?>> toolsToOllama(List<ToolInfo> tools) =>
      [for (final tool in tools) toolToOllama(tool)];

  /// One tool of a chat request.
  ///
  /// The parameters are always an object; each property keeps its type,
  /// description, enum values and item type (Go: `schemaToToolProperty`).
  /// Without required parameters `required` is `null`, as Go sends its nil
  /// slice.
  static Map<String, Object?> toolToOllama(ToolInfo tool) {
    final rawSchema = tool.function.parametersJsonSchema;
    if (rawSchema != null) return _rawToolToOllama(tool, rawSchema);
    final parameters = tool.function.parameters;
    final required = parameters?.required ?? const <String>[];
    return {
      'type': 'function',
      'function': {
        'name': tool.name,
        'description': tool.desc ?? '',
        'parameters': {
          'type': 'object',
          'required': required.isEmpty ? null : [...required],
          'properties': {
            for (final MapEntry(:key, :value)
                in (parameters?.properties ?? const {}).entries)
              key: toolPropertyOf(value),
          },
        },
      },
    };
  }

  /// [toolToOllama] for a tool info made with `ToolInfo.fromJsonSchemaMap`,
  /// read the way Go reads every schema (`toOllamaTools` over the
  /// `*jsonschema.Schema` of the tool): `required` is the document's list as
  /// it is (`[]` stays `[]`; `null` without one), and each property keeps
  /// what `schemaToToolProperty` keeps, nothing else (see
  /// [_rawToolPropertyOf]).
  static Map<String, Object?> _rawToolToOllama(
    ToolInfo tool,
    Map<String, dynamic> schema,
  ) {
    final required = schema['required'];
    final properties = schema['properties'];
    return {
      'type': 'function',
      'function': {
        'name': tool.name,
        'description': tool.desc ?? '',
        'parameters': {
          'type': 'object',
          'required': required is List<Object?>
              ? [
                  for (final name in required)
                    if (name is String) name,
                ]
              : null,
          'properties': {
            if (properties is Map<String, Object?>)
              for (final MapEntry(:key, :value) in properties.entries)
                key: _rawToolPropertyOf(value),
          },
        },
      },
    };
  }

  /// One property of a JSON Schema document (Go: `schemaToToolProperty`):
  /// its `anyOf` branches (each read the same way), its type, its items, its
  /// description and its enum values.
  ///
  /// As Go's `api.PropertyType` writes it, a type list of one name is that
  /// name, any other list stays a list (`["string", "null"]`), and no type
  /// is `null`. A schema that is not an object (`true`, `false`) has none of
  /// these.
  static Map<String, Object?> _rawToolPropertyOf(Object? raw) {
    final property = raw is Map<String, Object?> ? raw : const <String, Object?>{};
    final type = switch (property['type']) {
      final String type when type.isNotEmpty => type,
      final List<Object?> types => switch (types.whereType<String>().toList()) {
          [final single] => single,
          final names => names,
        },
      _ => null,
    };
    final anyOf = property['anyOf'];
    final items = property['items'];
    final description = property['description'];
    final enumValues = property['enum'];
    return {
      if (anyOf is List<Object?> && anyOf.isNotEmpty)
        'anyOf': [for (final branch in anyOf) _rawToolPropertyOf(branch)],
      'type': type,
      if (items != null) 'items': _rawToolPropertyOf(items),
      'description': description is String ? description : '',
      if (enumValues is List<Object?> && enumValues.isNotEmpty)
        'enum': [...enumValues],
    };
  }

  /// One property of a tool's parameters (Go: `schemaToToolProperty`).
  ///
  /// As in Go, the fields of a nested object are not sent: Ollama's tool
  /// property has no place for them.
  static Map<String, Object?> toolPropertyOf(JSONSchemaProperty property) {
    final items = property.items;
    final enumValues = property.enumValues;
    return {
      'type': property.type.isEmpty ? null : property.type,
      if (items != null) 'items': toolPropertyOf(items),
      'description': property.description ?? '',
      if (enumValues != null && enumValues.isNotEmpty) 'enum': [...enumValues],
    };
  }

  /// The message of one response of `/api/chat`: the whole answer, or one
  /// chunk of a stream (Go: `toEinoMessage`).
  ///
  /// The usage counts the prompt and generated tokens Ollama reports (zero
  /// until the last chunk) and the finish reason is `done_reason`. The last
  /// response (`done: true`) also carries its [OllamaMetrics] in
  /// [Message.extra] under [ollamaMetricsExtraKey]. Images in the answer
  /// are not read, as in Go.
  static Message responseToMessage(Map<String, Object?> response) {
    final message = _map(response['message']);
    final thinking = _string(message['thinking']);
    final toolCalls = [
      for (final call in _list(message['tool_calls'])) _toolCallOf(call),
    ];
    final promptTokens = _int(response['prompt_eval_count']);
    final completionTokens = _int(response['eval_count']);
    final doneReason = _string(response['done_reason']);
    return Message(
      role: _roleOf(message['role']),
      content: _string(message['content']),
      reasoningContent: thinking.isEmpty ? null : thinking,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      responseMeta: ResponseMeta(
        finishReason: doneReason.isEmpty ? null : doneReason,
        usage: TokenUsage(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: promptTokens + completionTokens,
        ),
      ),
      extra: response['done'] == true
          ? {ollamaMetricsExtraKey: OllamaMetrics.fromJson(response).toJson()}
          : null,
    );
  }

  /// The error a line of an Ollama response reports, or `null` (Go: the
  /// `error` field the client checks on every line).
  static String? errorOf(Map<String, Object?> line) {
    final error = line['error'];
    if (error is String) return error.isEmpty ? null : error;
    if (error is Map) return '${error['message'] ?? error}';
    return null;
  }

  /// The JSON value of a `keep_alive` field (Go: `api.Duration.MarshalJSON`):
  /// `-1` for a negative duration, otherwise the duration as Go writes it.
  static Object keepAliveToJson(Duration keepAlive) =>
      keepAlive.isNegative ? -1 : goDurationString(keepAlive);

  /// [duration] as Go's `time.Duration.String` writes it: `0s`, `250ms`,
  /// `1.5s`, `5m0s`, `1h2m3s`.
  static String goDurationString(Duration duration) =>
      go_duration.goDurationString(duration);

  static ToolCall _toolCallOf(Object? raw) {
    final call = _map(raw);
    final function = _map(call['function']);
    final arguments = function['arguments'];
    return ToolCall(
      // Ollama added tool call ids after the API version Go uses; Go leaves
      // the id empty.
      id: _string(call['id']),
      function: FunctionCall(
        name: _string(function['name']),
        arguments: arguments is String ? arguments : jsonEncode(arguments),
      ),
    );
  }

  /// Ollama's roles, lower-cased as the Go client does; anything else is the
  /// assistant, which is who answers.
  static RoleType _roleOf(Object? raw) =>
      switch (raw is String ? raw.toLowerCase() : '') {
        'user' => RoleType.user,
        'system' => RoleType.system,
        'tool' => RoleType.tool,
        _ => RoleType.assistant,
      };

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};

  static List<Object?> _list(Object? value) =>
      value is List ? value : const [];

  static String _string(Object? value) => value is String ? value : '';

  static int _int(Object? value) => value is num ? value.toInt() : 0;
}
