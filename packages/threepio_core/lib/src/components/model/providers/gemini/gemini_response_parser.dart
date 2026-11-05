import '../../../../errors.dart';
import '../../../../schema/message.dart';
import '../../response_parser.dart';
import 'gemini_converters.dart';

/// Response parser for Google Gemini API responses
///
/// Handles parsing of both complete responses and streaming chunks
/// from Gemini's generateContent API into Threepio Messages.
class GeminiResponseParser implements ResponseParser {
  const GeminiResponseParser();

  @override
  Message parseCompletionResponse(Map<String, dynamic> response) {
    final candidates = response['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      // Check for blocked content
      final promptFeedback = response['promptFeedback'] as Map<String, dynamic>?;
      if (promptFeedback != null) {
        final blockReason = promptFeedback['blockReason'] as String?;
        if (blockReason != null) {
          throw GeminiParseException(
            'Content blocked: $blockReason',
            blockReason: blockReason,
          );
        }
      }
      throw GeminiParseException('No candidates in response');
    }

    final candidate = candidates.first as Map<String, dynamic>;
    final usageMetadata = response['usageMetadata'] as Map<String, dynamic>?;

    return GeminiConverters.geminiToMessage(
      candidate,
      usageMetadata: usageMetadata,
    );
  }

  @override
  Message? parseStreamChunk(Map<String, dynamic> chunk) {
    final candidates = chunk['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      return null;
    }

    final candidate = candidates.first as Map<String, dynamic>;
    final usageMetadata = chunk['usageMetadata'] as Map<String, dynamic>?;

    return parseDelta(
      candidate,
      finishReason: candidate['finishReason'] as String?,
      usageMetadata: usageMetadata,
    );
  }

  @override
  Message? parseDelta(
    Map<String, dynamic> delta, {
    String? finishReason,
    Map<String, dynamic>? usageMetadata,
  }) {
    // In Gemini, the delta is actually the candidate itself
    return GeminiConverters.geminiDeltaToMessage(
      delta,
      usageMetadata: usageMetadata,
    );
  }

  /// Parse error response from Gemini API
  static GeminiParseException parseError(Map<String, dynamic> response) {
    final error = response['error'] as Map<String, dynamic>?;
    if (error != null) {
      final message = error['message'] as String? ?? 'Unknown error';
      final code = error['code'] as int?;
      final status = error['status'] as String?;
      return GeminiParseException(
        message,
        code: code,
        status: status,
      );
    }
    return GeminiParseException('Unknown error response');
  }
}

/// Exception thrown when parsing Gemini responses fails
class GeminiParseException implements ThreepioException {
  GeminiParseException(
    this.message, {
    this.code,
    this.status,
    this.blockReason,
  });

  @override
  final String message;
  final int? code;
  final String? status;
  final String? blockReason;

  @override
  Object? get cause => null;

  @override
  String toString() {
    final parts = ['GeminiParseException: $message'];
    if (code != null) parts.add('code: $code');
    if (status != null) parts.add('status: $status');
    if (blockReason != null) parts.add('blockReason: $blockReason');
    return parts.join(', ');
  }
}
