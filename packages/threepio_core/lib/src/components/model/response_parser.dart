import '../../schema/message.dart';

/// Abstract interface for parsing LLM API responses into Threepio Messages
///
/// Different LLM providers may return responses in different formats.
/// This abstraction allows each provider to implement custom parsing logic
/// while maintaining a consistent interface.
///
/// Implementations should handle:
/// - Complete responses (non-streaming)
/// - Streaming chunks/deltas
/// - Multi-modal content (text, images, audio, etc.)
/// - Provider-specific response structures
abstract class ResponseParser {
  /// Parse a complete (non-streaming) response into a Message
  ///
  /// Takes the full API response JSON and returns a complete Message.
  /// Should include response metadata like usage, finish_reason, etc.
  ///
  /// Throws an exception if the response format is invalid.
  Message parseCompletionResponse(Map<String, dynamic> response);

  /// Parse a single streaming chunk into a Message
  ///
  /// Takes a chunk from a streaming response and returns a Message with
  /// the incremental content. Returns null if the chunk contains no useful data.
  ///
  /// For text streaming, each Message should contain the delta content.
  /// For multi-modal content, should populate the appropriate fields.
  ///
  /// Throws an exception if the chunk format is invalid.
  Message? parseStreamChunk(Map<String, dynamic> chunk);

  /// Parse a delta object (from streaming) into a Message
  ///
  /// This is a lower-level method that parses the 'delta' portion of a
  /// streaming chunk. Useful when the delta needs to be extracted separately.
  ///
  /// [finishReason] can be provided if available in the chunk.
  ///
  /// Returns a Message with the delta content, or null if delta is empty.
  Message? parseDelta(
    Map<String, dynamic> delta, {
    String? finishReason,
  });
}
