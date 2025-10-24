import '../../../../schema/message.dart';
import '../../response_parser.dart';
import 'openai_converters.dart';

/// Response parser for OpenAI API responses
///
/// Handles parsing of both complete responses and streaming chunks
/// from OpenAI's chat completions API into Threepio Messages.
class OpenAIResponseParser implements ResponseParser {
  const OpenAIResponseParser();

  @override
  Message parseCompletionResponse(Map<String, dynamic> response) {
    final choices = response['choices'] as List<dynamic>;
    if (choices.isEmpty) {
      throw OpenAIParseException('No choices in response');
    }

    final choice = choices.first as Map<String, dynamic>;
    final messageData = choice['message'] as Map<String, dynamic>;
    final usage = response['usage'] as Map<String, dynamic>?;

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

    return OpenAIConverters.openAIDeltaToMessage(
      delta,
      finishReason: finishReason,
    );
  }
}

/// Exception thrown when parsing OpenAI responses fails
class OpenAIParseException implements Exception {
  OpenAIParseException(this.message);

  final String message;

  @override
  String toString() => 'OpenAIParseException: $message';
}
