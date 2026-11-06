/// A chat template whose messages come from a prompt of an MCP server.
///
/// Port of eino-ext `components/prompt/mcp`.
library;

import 'dart:convert';

import '../../core/interrupt_signal.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../component_type.dart';
import '../model/cancel_token.dart';
import '../tool/mcp/mcp_client.dart';
import 'chat_template.dart';

/// A [ChatTemplate] that renders the MCP prompt [name] on the server behind
/// [client] (`prompts/get`).
///
/// Port of eino-ext `prompt/mcp.NewPromptTemplate` (`Config.Cli` is
/// [client], `Config.Name` is [name]). [format] turns every variable into a
/// string (`fmt.Sprint` in Go: strings as they are, `null` as `<nil>`;
/// lists and maps as JSON) and passes them as the prompt arguments. The
/// messages of the result become [Message]s:
///
/// * the role `user` or `assistant` (any other role fails);
/// * text becomes the content;
/// * an image becomes an image part (base64 data and MIME type);
/// * an embedded resource becomes, by its MIME type, an audio, image or video
///   part pointing at its URI, or for `text/*` the URI as the content; other
///   MIME types fail.
///
/// Multimodal parts go to `userInputMultiContent` for user messages and to
/// `assistantGenMultiContent` for assistant messages (Go fills the
/// deprecated `MultiContent`). Content of other kinds (audio, resource links)
/// fails, as in Go.
///
/// The template fires no callbacks of its own (`isCallbacksEnabled` is false
/// in Go too): a graph reports it like any other component.
final class McpPromptTemplate extends ChatTemplate implements TypedComponent {
  /// A template for the prompt [name] of [client].
  const McpPromptTemplate({required this.client, required this.name});

  /// The connection to the server: an initialized [McpClient] or an
  /// `McpSession`.
  final McpPromptClient client;

  /// The name of the prompt on the server.
  final String name;

  @override
  String get componentTypeName => 'MCP';

  /// Renders the prompt with [variables] as its arguments.
  ///
  /// Throws a [ThreepioException] when the server cannot render it ("get mcp
  /// prompt fail") and a [ThreepioFormatException] for a message that cannot
  /// be converted ("convert mcp message fail"). The cancel token of
  /// `options.runContext` cancels the request with a `CancelledException`.
  @override
  Future<List<Message>> format(
    Map<String, dynamic> variables, {
    ChatTemplateOptions? options,
  }) async {
    final arguments = {
      for (final MapEntry(:key, :value) in variables.entries)
        key: _sprint(value),
    };

    final McpGetPromptResult result;
    try {
      result = await client.getPrompt(
        name,
        arguments: arguments,
        cancelToken: options?.runContext?.cancelToken,
      );
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw ThreepioException('get mcp prompt fail: $error', cause: error);
    }

    return [
      for (final message in result.messages) _convertMessage(message),
    ];
  }
}

/// A variable as a prompt argument: the counterpart of Go's `fmt.Sprint`
/// for the values a template sees.
String _sprint(Object? value) => switch (value) {
      null => '<nil>',
      final String text => text,
      final double number => _goFloat(number),
      final Map<Object?, Object?> map => _jsonOr(map),
      final Iterable<Object?> list => _jsonOr(list.toList()),
      _ => value.toString(),
    };

/// A double as Go's `%v` writes it (`strconv.FormatFloat(f, 'g', -1, 64)`):
/// the shortest digits, in exponent form (`1e+06`, `1.5e-07`) when the
/// decimal exponent is below -4 or at least 6, plain otherwise (`100000`,
/// `0.0001`, `1.5`).
String _goFloat(double number) {
  if (number.isNaN) return 'NaN';
  if (number.isInfinite) return number > 0 ? '+Inf' : '-Inf';
  if (number == 0) return number.isNegative ? '-0' : '0';
  // Dart's shortest exponential form: "1.5e+6", "-2.5e-7".
  final exponential = number.toStringAsExponential();
  final split = exponential.indexOf('e');
  final mantissa = exponential.substring(0, split);
  final exponent = int.parse(exponential.substring(split + 1));
  if (exponent < -4 || exponent >= 6) {
    final sign = exponent < 0 ? '-' : '+';
    final digits = exponent.abs().toString().padLeft(2, '0');
    return '${mantissa}e$sign$digits';
  }
  final plain = number.toString();
  return plain.endsWith('.0') ? plain.substring(0, plain.length - 2) : plain;
}

String _jsonOr(Object value) {
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return value.toString();
  }
}

Never _convertFail(String reason, Object? source) => throw ThreepioFormatException(
      'convert mcp message fail: $reason',
      source: source,
    );

Message _convertMessage(McpPromptMessage message) {
  final RoleType role;
  if (message.role == McpRole.user.wireValue) {
    role = RoleType.user;
  } else if (message.role == McpRole.assistant.wireValue) {
    role = RoleType.assistant;
  } else {
    _convertFail('unknown mcp role ${message.role}', message.role);
  }

  Message withPart(ChatMessagePartType type, MessagePartCommon common) =>
      role == RoleType.user
          ? Message(
              role: role,
              userInputMultiContent: [
                switch (type) {
                  ChatMessagePartType.audioUrl => MessageInputPart(
                      type: type,
                      audio: MessageInputAudio(common: common),
                    ),
                  ChatMessagePartType.videoUrl => MessageInputPart(
                      type: type,
                      video: MessageInputVideo(common: common),
                    ),
                  _ => MessageInputPart(
                      type: type,
                      image: MessageInputImage(common: common),
                    ),
                },
              ],
            )
          : Message(
              role: role,
              assistantGenMultiContent: [
                switch (type) {
                  ChatMessagePartType.audioUrl =>
                    MessageOutputPart(type: type, audio: common),
                  ChatMessagePartType.videoUrl =>
                    MessageOutputPart(type: type, video: common),
                  _ => MessageOutputPart(type: type, image: common),
                },
              ],
            );

  switch (message.content) {
    case McpTextContent(:final text):
      return Message(role: role, content: text);
    case McpImageContent(:final data, :final mimeType):
      return withPart(
        ChatMessagePartType.imageUrl,
        MessagePartCommon(base64Data: data, mimeType: mimeType),
      );
    case McpEmbeddedResource(:final resource):
      final uri = resource.uri;
      final mimeType = resource.mimeType ?? '';
      if (mimeType.startsWith('audio')) {
        return withPart(
          ChatMessagePartType.audioUrl,
          MessagePartCommon(url: uri, mimeType: mimeType),
        );
      }
      if (mimeType.startsWith('image')) {
        return withPart(
          ChatMessagePartType.imageUrl,
          MessagePartCommon(url: uri, mimeType: mimeType),
        );
      }
      if (mimeType.startsWith('video')) {
        return withPart(
          ChatMessagePartType.videoUrl,
          MessagePartCommon(url: uri, mimeType: mimeType),
        );
      }
      if (mimeType.startsWith('text')) {
        return Message(role: role, content: uri);
      }
      _convertFail('unsupported mcp resource mime type $mimeType', resource.toJson());
    case McpAudioContent() || McpResourceLink():
      _convertFail(
        'unknown mcp prompt content type: ${message.content.type}',
        message.content.toJson(),
      );
  }
}
