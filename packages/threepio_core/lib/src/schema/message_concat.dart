/// Joining the chunks of a streamed [Message] or [ToolResult].
///
/// Port of the concat functions of eino `schema/message.go`.
library;

import '../streaming/stream_reader.dart';
import 'concat.dart';
import 'message.dart';
import 'tool_result.dart';

/// Joins the chunks of a streamed message into one message.
///
/// Port of eino `schema.ConcatMessages`:
///
/// * All chunks must have the same role. Name, tool call id and tool name are
///   taken from the chunks that have one, which must agree.
/// * Content and reasoning content are concatenated.
/// * Tool calls with the same `index` are fragments of one call: their
///   arguments are concatenated, and id, type and name are taken from the
///   fragments that have them, which must agree. Calls without an index are
///   kept as they are and come first; the others follow by index.
/// * Output parts ([Message.assistantGenMultiContent]) that follow each other
///   are joined when they are both text, both reasoning or both base64 audio
///   and carry the same streaming index (or none). Neighbouring text parts of
///   [Message.userInputMultiContent] are joined.
/// * Of the response metadata, the last finish reason and the highest token
///   counts are kept, and the log probabilities are appended.
/// * [Message.extra] maps are merged key by key: strings under the same key
///   are concatenated, of numbers and bools the last one wins, maps are
///   merged recursively. Lists are appended to each other. That last rule is
///   an addition to Eino, where two lists cannot be joined: providers stream
///   list-valued extras (OpenRouter's `reasoning_details`) in pieces.
///
/// Throws [ArgumentError] when [chunks] is empty or the chunks contradict each
/// other.
Message concatMessages(List<Message> chunks) {
  if (chunks.isEmpty) {
    throw ArgumentError('Cannot concatenate empty message list');
  }

  final role = chunks.first.role;
  String? name;
  String? toolCallId;
  String? toolName;
  final content = StringBuffer();
  final reasoning = StringBuffer();
  var hasReasoning = false;
  final toolCalls = <ToolCall>[];
  final outputParts = <MessageOutputPart>[];
  final inputParts = <MessageInputPart>[];
  final extras = <Map<String, dynamic>>[];
  _ResponseMetaBuilder? meta;

  String? agreed(String? known, String? next, String what) {
    if (next == null || next.isEmpty) return known;
    if (known == null || known.isEmpty) return next;
    if (known != next) {
      throw ArgumentError(
        "cannot concat messages with different $what: '$known' '$next'",
      );
    }
    return known;
  }

  for (final chunk in chunks) {
    if (chunk.role != role) {
      throw ArgumentError(
        'cannot concat messages with different roles: '
        "'${role.name}' '${chunk.role.name}'",
      );
    }
    name = agreed(name, chunk.name, 'names');
    toolCallId = agreed(toolCallId, chunk.toolCallId, 'toolCallIDs');
    toolName = agreed(toolName, chunk.toolName, 'toolNames');

    content.write(chunk.content);
    final chunkReasoning = chunk.reasoningContent;
    if (chunkReasoning != null && chunkReasoning.isNotEmpty) {
      hasReasoning = true;
      reasoning.write(chunkReasoning);
    }

    toolCalls.addAll(chunk.toolCalls ?? const []);
    outputParts.addAll(chunk.assistantGenMultiContent ?? const []);
    inputParts.addAll(chunk.userInputMultiContent ?? const []);

    final extra = chunk.extra;
    if (extra != null && extra.isNotEmpty) extras.add(extra);

    final chunkMeta = chunk.responseMeta;
    if (chunkMeta != null) (meta ??= _ResponseMetaBuilder()).add(chunkMeta);
  }

  final extra = extras.isEmpty ? null : _concatExtra(extras);

  return Message(
    role: role,
    content: content.toString(),
    name: name,
    toolCallId: toolCallId,
    toolName: toolName,
    toolCalls: toolCalls.isEmpty ? null : _concatToolCalls(toolCalls),
    reasoningContent: hasReasoning ? reasoning.toString() : null,
    responseMeta: meta?.build(),
    extra: extra == null || extra.isEmpty ? null : extra,
    assistantGenMultiContent:
        outputParts.isEmpty ? null : _concatOutputParts(outputParts),
    userInputMultiContent:
        inputParts.isEmpty ? null : _concatInputParts(inputParts),
  );
}

/// Joins chunks that are each a list of messages, position by position.
///
/// Port of eino `schema.ConcatMessageArray`: the result has one message per
/// position, the [concatMessages] of the messages the chunks have there.
/// Throws [ArgumentError] when the lists differ in length.
List<Message> concatMessageArray(List<List<Message>> arrays) {
  if (arrays.isEmpty) return [];

  final length = arrays.first.length;
  for (final array in arrays) {
    if (array.length != length) {
      throw ArgumentError(
        'unexpected array length. Got ${array.length}, expected $length',
      );
    }
  }

  if (arrays.length == 1) return arrays.single;

  return [
    for (var i = 0; i < length; i++)
      concatMessages([for (final array in arrays) array[i]]),
  ];
}

/// Reads [stream] to its end, closes it, and joins the chunks.
///
/// Port of eino `schema.ConcatMessageStream`. An error in the stream is
/// rethrown; an empty stream throws [ArgumentError] like [concatMessages].
Future<Message> concatMessageStream(StreamReader<Message> stream) async {
  final chunks = <Message>[];
  try {
    for (var chunk = await stream.nextOrNull();
        chunk != null;
        chunk = await stream.nextOrNull()) {
      chunks.add(chunk);
    }
  } finally {
    await stream.close();
  }
  return concatMessages(chunks);
}

/// Joins the chunks of a streamed tool result.
///
/// Port of eino `schema.ConcatToolResults`. The parts of all chunks are put
/// one after the other and neighbouring text parts are joined into one. A
/// part that is not text is kept as it is, and each such type (image, audio,
/// video, file) may occur in one chunk only: throws [ArgumentError] when the
/// same one comes in two chunks.
ToolResult concatToolResults(List<ToolResult> chunks) {
  final seenIn = <ToolPartType, int>{};
  final parts = <ToolOutputPart>[];

  for (final (index, chunk) in chunks.indexed) {
    for (final part in chunk.parts) {
      if (part.type == ToolPartType.text) continue;
      final previous = seenIn[part.type];
      if (previous != null && previous != index) {
        throw ArgumentError(
          'conflicting ${part.type.name} parts found in chunk $previous and '
          'chunk $index: non-text modality parts cannot appear in multiple '
          'chunks',
        );
      }
      seenIn[part.type] = index;
    }
    parts.addAll(chunk.parts);
  }

  final merged = <ToolOutputPart>[];
  var i = 0;
  while (i < parts.length) {
    var end = i + 1;
    if (parts[i].type == ToolPartType.text) {
      while (end < parts.length && parts[end].type == ToolPartType.text) {
        end++;
      }
    }

    if (end == i + 1) {
      merged.add(parts[i]);
    } else {
      final group = parts.sublist(i, end);
      merged.add(
        ToolOutputPart(
          type: ToolPartType.text,
          text: group.map((part) => part.text ?? '').join(),
          extra: _concatPartExtras(group.map((part) => part.extra)),
        ),
      );
    }
    i = end;
  }

  return ToolResult(merged);
}

/// Merges the extras of chunks; port of eino's `concatExtra`.
Map<String, dynamic> _concatExtra(List<Map<String, dynamic>> extras) {
  if (extras.length == 1) return {...extras.single};
  try {
    return concatMaps(extras, appendLists: true);
    // Values that cannot be joined are reported like every other
    // contradiction between chunks.
    // ignore: avoid_catching_errors
  } on StateError catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ArgumentError('failed to concat extra: ${error.message}'),
      stackTrace,
    );
  }
}

/// The merged extras of the parts of a group, or `null` when none has any.
Map<String, dynamic>? _concatPartExtras(
  Iterable<Map<String, dynamic>?> extras,
) {
  final present = [
    for (final extra in extras)
      if (extra != null && extra.isNotEmpty) extra,
  ];
  return present.isEmpty ? null : _concatExtra(present);
}

/// Port of eino's `concatToolCalls`.
List<ToolCall> _concatToolCalls(List<ToolCall> chunks) {
  final merged = <ToolCall>[];
  final byIndex = <int, List<ToolCall>>{};
  for (final chunk in chunks) {
    final index = chunk.index;
    if (index == null) {
      merged.add(chunk);
    } else {
      (byIndex[index] ??= []).add(chunk);
    }
  }

  String agreed(String known, String next, String what) {
    if (next.isEmpty) return known;
    if (known.isEmpty) return next;
    if (known != next) {
      throw ArgumentError(
        "cannot concat ToolCalls with different $what: '$known' '$next'",
      );
    }
    return known;
  }

  for (final index in byIndex.keys.toList()..sort()) {
    final fragments = byIndex[index]!;
    var id = '';
    var type = '';
    var name = '';
    final arguments = StringBuffer();

    // These three arrive whole, in any one fragment or in several.
    for (final fragment in fragments) {
      id = agreed(id, fragment.id, 'tool id');
      type = agreed(type, fragment.type, 'tool type');
      name = agreed(name, fragment.function.name, 'tool name');
      arguments.write(fragment.function.arguments);
    }

    merged.add(
      fragments.first.copyWith(
        id: id,
        type: type,
        function: FunctionCall(name: name, arguments: arguments.toString()),
      ),
    );
  }

  return merged;
}

/// Port of eino's `concatAssistantMultiContent`.
List<MessageOutputPart> _concatOutputParts(List<MessageOutputPart> parts) {
  final merged = <MessageOutputPart>[];
  var i = 0;
  while (i < parts.length) {
    var end = i + 1;
    while (end < parts.length && _canMerge(parts[i], parts[end])) {
      end++;
    }
    merged.add(end == i + 1 ? parts[i] : _mergeGroup(parts.sublist(i, end)));
    i = end;
  }
  return merged;
}

bool _isBase64Audio(MessageOutputPart part) =>
    part.type == ChatMessagePartType.audioUrl &&
    part.audio?.base64Data != null &&
    part.audio?.url == null;

bool _canMerge(MessageOutputPart current, MessageOutputPart next) {
  if (current.type != next.type) return false;

  final mergeable = switch (current.type) {
    ChatMessagePartType.text || ChatMessagePartType.reasoning => true,
    ChatMessagePartType.audioUrl => _isBase64Audio(current),
    _ => false,
  };
  if (!mergeable) return false;

  // Both without a streaming position, or both at the same one.
  return current.streamingMeta?.index == next.streamingMeta?.index &&
      (current.streamingMeta == null) == (next.streamingMeta == null);
}

MessageOutputPart _mergeGroup(List<MessageOutputPart> group) {
  final first = group.first;
  final extra = _concatPartExtras(group.map((part) => part.extra));

  switch (first.type) {
    case ChatMessagePartType.text:
      return MessageOutputPart(
        type: ChatMessagePartType.text,
        text: group.map((part) => part.text ?? '').join(),
        extra: extra,
        streamingMeta: first.streamingMeta,
      );

    case ChatMessagePartType.reasoning:
      var signature = '';
      for (final part in group) {
        final next = part.reasoning?.signature ?? '';
        if (next.isNotEmpty) signature = next;
      }
      return MessageOutputPart(
        type: ChatMessagePartType.reasoning,
        reasoning: MessageOutputReasoning(
          text: group.map((part) => part.reasoning?.text ?? '').join(),
          signature: signature,
        ),
        extra: extra,
        streamingMeta: first.streamingMeta,
      );

    case ChatMessagePartType.audioUrl:
      final audios = [for (final part in group) part.audio];
      return MessageOutputPart(
        type: ChatMessagePartType.audioUrl,
        audio: MessagePartCommon(
          base64Data: audios.map((audio) => audio?.base64Data ?? '').join(),
          mimeType: audios
              .map((audio) => audio?.mimeType)
              .firstWhere((type) => type != null && type.isNotEmpty,
                  orElse: () => null),
          // ignore: deprecated_member_use_from_same_package
          extra: _concatPartExtras(audios.map((audio) => audio?.extra)),
        ),
        extra: extra,
        streamingMeta: first.streamingMeta,
      );

    case ChatMessagePartType.imageUrl:
    case ChatMessagePartType.videoUrl:
    case ChatMessagePartType.fileUrl:
    case ChatMessagePartType.toolSearchResult:
      return first;
  }
}

/// Port of eino's `concatUserMultiContent`: neighbouring text parts become
/// one.
List<MessageInputPart> _concatInputParts(List<MessageInputPart> parts) {
  final merged = <MessageInputPart>[];
  var i = 0;
  while (i < parts.length) {
    var end = i + 1;
    if (parts[i].type == ChatMessagePartType.text) {
      while (
          end < parts.length && parts[end].type == ChatMessagePartType.text) {
        end++;
      }
    }

    merged.add(
      end == i + 1
          ? parts[i]
          : MessageInputPart(
              type: ChatMessagePartType.text,
              text: parts.sublist(i, end).map((p) => p.text ?? '').join(),
            ),
    );
    i = end;
  }
  return merged;
}

/// Collects the response metadata of the chunks; see [concatMessages].
final class _ResponseMetaBuilder {
  String? _finishReason;
  bool _hasUsage = false;
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _totalTokens = 0;
  double? _cost;
  PromptTokenDetails? _promptDetails;
  CompletionTokenDetails? _completionDetails;
  List<LogProb>? _logProbs;

  static int _max(int a, int b) => a > b ? a : b;

  void add(ResponseMeta meta) {
    final finishReason = meta.finishReason;
    if (finishReason != null && finishReason.isNotEmpty) {
      _finishReason = finishReason;
    }

    final usage = meta.usage;
    if (usage != null) {
      _hasUsage = true;
      _promptTokens = _max(_promptTokens, usage.promptTokens);
      _completionTokens = _max(_completionTokens, usage.completionTokens);
      _totalTokens = _max(_totalTokens, usage.totalTokens);

      final cost = usage.cost;
      if (cost != null && (_cost == null || cost > _cost!)) _cost = cost;

      final prompt = usage.promptTokenDetails;
      if (prompt != null) {
        final known = _promptDetails ?? const PromptTokenDetails();
        _promptDetails = PromptTokenDetails(
          cachedTokens: _max(known.cachedTokens, prompt.cachedTokens),
          cacheWriteTokens:
              _max(known.cacheWriteTokens, prompt.cacheWriteTokens),
        );
      }

      final completion = usage.completionTokenDetails;
      if (completion != null) {
        final known = _completionDetails ?? const CompletionTokenDetails();
        _completionDetails = CompletionTokenDetails(
          reasoningTokens:
              _max(known.reasoningTokens, completion.reasoningTokens),
          imageTokens: _max(known.imageTokens, completion.imageTokens),
          audioTokens: _max(known.audioTokens, completion.audioTokens),
        );
      }
    }

    final logProbs = meta.logProbs;
    if (logProbs != null) (_logProbs ??= []).addAll(logProbs.content);
  }

  ResponseMeta build() => ResponseMeta(
        finishReason: _finishReason,
        usage: _hasUsage
            ? TokenUsage(
                promptTokens: _promptTokens,
                completionTokens: _completionTokens,
                totalTokens: _totalTokens,
                promptTokenDetails: _promptDetails,
                completionTokenDetails: _completionDetails,
                cost: _cost,
              )
            : null,
        logProbs: _logProbs == null ? null : LogProbs(content: _logProbs!),
      );
}
