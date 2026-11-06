/// Joining the chunks of a streamed [AgenticMessage].
///
/// Port of the concat functions of eino `schema/agentic_message.go`
/// (`ConcatAgenticMessages`, `ConcatAgenticMessagesArray` and the
/// per-variant `concat…` functions). **Beta**, as the whole agentic path is
/// upstream.
library;

import '../errors.dart';
import 'agentic_message.dart';
import 'agentic_wire.dart';
import 'concat.dart';
import 'extensions/claude.dart';
import 'extensions/gemini.dart';
import 'extensions/openai.dart';
import 'message.dart';
import 'message_concat.dart';

/// Joins the chunks of a streamed agentic message into one message.
///
/// Port of eino `schema.ConcatAgenticMessages`:
///
/// * A single chunk is returned as it is.
/// * All chunks must have the same role.
/// * The blocks are either all non-streaming (no [ContentBlock.streamingMeta])
///   and then kept in order, or all streaming: then the chunks of each
///   streaming index are joined into one block (which has no streaming meta)
///   and the blocks are ordered by index. Mixing the two throws.
/// * Chunks of one index must be of one [ContentBlockType]. How they are
///   joined depends on it: text, reasoning text, signatures, base64 media
///   data and the arguments of function and MCP tool calls are
///   concatenated; call ids, tool names and server labels are taken from the
///   chunks that have them, which must agree; the parts of function tool
///   results and the tools of MCP tool lists are appended; of MCP tool
///   results the last content and error win; user input, tool search
///   results and MCP approval responses cannot be split over chunks at all.
///   The OpenAI and Claude extensions are joined with their own functions
///   ([concatOpenAIAssistantGenTextExtensions], …).
/// * Values of a type only the producer knows (the `extension` fields, server
///   tool arguments and results) must be of one type. Go compares their
///   `reflect` types; here string-keyed maps count as one type, as do lists
///   and numbers, because Dart literals carry the type arguments they were
///   inferred with. They are joined by the [StreamConcat] registry (Go's
///   `ConcatSliceValue`): strings are concatenated, of numbers and bools the
///   last one wins, a type with a function registered with
///   [StreamConcat.register] is joined by it, and of any other type at most
///   one chunk may carry a value. One difference: string-keyed maps are
///   merged key by key, where Go's `ConcatSliceValue`, which has no rule for
///   maps, fails on two non-empty ones (the registry serves both
///   `ConcatSliceValue` and `ConcatItems`, which merges maps).
/// * The block extras of an index, and the message extras, are merged key by
///   key as Go's `concatMaps` does: strings are concatenated, of numbers and
///   bools the last one wins, maps are merged recursively; two non-empty
///   lists under one key cannot be joined.
/// * Of the response metadata, the highest token counts are kept and the
///   extensions are joined with their own functions.
///
/// Throws [MessageConcatException] when the chunks contradict each other,
/// also when a registered concat function fails (the exception it threw ends
/// the chain of [MessageConcatException.cause]s, as Go wraps the error), and
/// [ArgumentError] when [chunks] is empty (Go returns a message without a
/// role, which a Dart [AgenticMessage] cannot have).
AgenticMessage concatAgenticMessages(List<AgenticMessage> chunks) {
  if (chunks.isEmpty) {
    throw ArgumentError('Cannot concatenate empty agentic message list');
  }
  if (chunks.length == 1) return chunks.single;

  final role = chunks.first.role;
  final blocks = <ContentBlock>[];
  final indices = <int>[];
  final byIndex = <int, List<ContentBlock>>{};
  final metas = <AgenticResponseMeta>[];
  final extras = <Map<String, Object?>>[];

  for (final chunk in chunks) {
    if (chunk.role != role) {
      throw MessageConcatException(
        'cannot concat messages with different roles: '
        "got '${role.value}' and '${chunk.role.value}'",
      );
    }

    for (final block in chunk.contentBlocks) {
      final streamingMeta = block.streamingMeta;
      if (streamingMeta == null) {
        if (indices.isNotEmpty) {
          throw const MessageConcatException(
            'found non-streaming block after streaming blocks',
          );
        }
        blocks.add(block);
      } else {
        if (blocks.isNotEmpty) {
          throw const MessageConcatException(
            'found streaming block after non-streaming blocks',
          );
        }
        final group = byIndex[streamingMeta.index];
        if (group != null) {
          group.add(block);
        } else {
          indices.add(streamingMeta.index);
          byIndex[streamingMeta.index] = [block];
        }
      }
    }

    final meta = chunk.responseMeta;
    if (meta != null) metas.add(meta);
    final extra = chunk.extra;
    if (extra != null) extras.add(extra);
  }

  final AgenticResponseMeta? meta;
  try {
    meta = _concatResponseMeta(metas);
  } on MessageConcatException catch (error, stackTrace) {
    Error.throwWithStackTrace(
      MessageConcatException(
        'failed to concat agentic response meta: ${error.message}',
        cause: error,
      ),
      stackTrace,
    );
  }

  if (indices.isNotEmpty) {
    indices.sort();
    blocks.addAll([
      for (final index in indices) _concatChunksOfSameBlock(byIndex[index]!),
    ]);
  }

  return AgenticMessage(
    role: role,
    responseMeta: meta,
    contentBlocks: blocks,
    extra: extras.isEmpty ? null : _concatExtras(extras),
  );
}

/// Joins chunks that are each a list of agentic messages, position by
/// position.
///
/// Port of eino `schema.ConcatAgenticMessagesArray`: the result has one
/// message per position, the [concatAgenticMessages] of the messages the
/// chunks have there. Throws [MessageConcatException] when the lists differ
/// in length.
List<AgenticMessage> concatAgenticMessagesArray(
  List<List<AgenticMessage>> arrays,
) {
  if (arrays.isEmpty) return [];

  final length = arrays.first.length;
  for (final array in arrays) {
    if (array.length != length) {
      throw MessageConcatException(
        'unexpected array length. Got ${array.length}, expected $length',
      );
    }
  }

  if (arrays.length == 1) return arrays.single;

  return [
    for (var i = 0; i < length; i++)
      concatAgenticMessages([for (final array in arrays) array[i]]),
  ];
}

/// Port of eino's `concatExtra`: one map is copied, several are merged.
Map<String, Object?> _concatExtras(List<Map<String, Object?>> extras) {
  if (extras.length == 1) return {...extras.single};
  return _joined(() => concatMaps(extras, appendLists: false));
}

/// The result of [join], which joins chunks with the [StreamConcat]
/// registry; a failure to join becomes a [MessageConcatException] whose
/// message starts with [context] when there is one (Go wraps the error with
/// `%w`).
///
/// A failure is a [StateError] of the registry (values that cannot be
/// joined) or an exception a registered concat function throws; an
/// [Error] other than a [StateError] is a programming error and is not
/// caught. A [MessageConcatException] without a [context] stays as it is.
T _joined<T>(T Function() join, [String? context]) {
  try {
    return join();
  } on MessageConcatException catch (error, stackTrace) {
    if (context == null) rethrow;
    _throwConcatFailure(error.message, error, stackTrace, context);
  } on ThreepioException catch (error, stackTrace) {
    _throwConcatFailure(error.message, error, stackTrace, context);
    // The registry reports values that cannot be joined as a StateError.
    // ignore: avoid_catching_errors
  } on StateError catch (error, stackTrace) {
    _throwConcatFailure(error.message, error, stackTrace, context);
  } on Exception catch (error, stackTrace) {
    _throwConcatFailure('$error', error, stackTrace, context);
  }
}

Never _throwConcatFailure(
  String message,
  Object cause,
  StackTrace stackTrace,
  String? context,
) =>
    Error.throwWithStackTrace(
      MessageConcatException(
        context == null ? message : '$context: $message',
        cause: cause,
      ),
      stackTrace,
    );

/// Port of eino's `concatChunksOfSameContentBlock` and
/// `concatContentBlockHelper`.
ContentBlock _concatChunksOfSameBlock(List<ContentBlock> blocks) {
  final type = blocks.first.type;
  for (final block in blocks) {
    if (block.type != type) {
      throw MessageConcatException(
        "content block type mismatch: expected '${type.value}', "
        "but got '${block.type.value}'",
      );
    }
  }

  List<T> all<T>() => [for (final block in blocks) block.content as T];

  final ContentBlockVariant content;
  try {
    content = switch (blocks.first.content) {
      Reasoning() => _concatReasoning(all<Reasoning>()),
      UserInputText() => _onlyOne(all<UserInputText>(), 'user input texts'),
      UserInputImage() =>
        _onlyOne(all<UserInputImage>(), 'user input images'),
      UserInputAudio() =>
        _onlyOne(all<UserInputAudio>(), 'user input audios'),
      UserInputVideo() =>
        _onlyOne(all<UserInputVideo>(), 'user input videos'),
      UserInputFile() => _onlyOne(all<UserInputFile>(), 'user input files'),
      ToolSearchFunctionToolResult() => _onlyOne(
          all<ToolSearchFunctionToolResult>(),
          'tool search results',
        ),
      AssistantGenText() => _concatAssistantGenTexts(all<AssistantGenText>()),
      AssistantGenImage() => _concatAssistantGenImages(all<AssistantGenImage>()),
      AssistantGenAudio() => _concatAssistantGenAudios(all<AssistantGenAudio>()),
      AssistantGenVideo() => _concatAssistantGenVideos(all<AssistantGenVideo>()),
      FunctionToolCall() => _concatFunctionToolCalls(all<FunctionToolCall>()),
      FunctionToolResult() =>
        _concatFunctionToolResults(all<FunctionToolResult>()),
      ServerToolCall() => _concatServerToolCalls(all<ServerToolCall>()),
      ServerToolResult() => _concatServerToolResults(all<ServerToolResult>()),
      AgenticMcpToolCall() => _concatMcpToolCalls(all<AgenticMcpToolCall>()),
      AgenticMcpToolResult() =>
        _concatMcpToolResults(all<AgenticMcpToolResult>()),
      AgenticMcpListToolsResult() =>
        _concatMcpListToolsResults(all<AgenticMcpListToolsResult>()),
      AgenticMcpToolApprovalRequest() => _concatMcpToolApprovalRequests(
          all<AgenticMcpToolApprovalRequest>(),
        ),
      AgenticMcpToolApprovalResponse() => _onlyOne(
          all<AgenticMcpToolApprovalResponse>(),
          'mcp tool approval responses',
        ),
    };
  } on MessageConcatException catch (error, stackTrace) {
    Error.throwWithStackTrace(
      MessageConcatException(
        "failed to concat '${type.value}' content blocks: ${error.message}",
        cause: error,
      ),
      stackTrace,
    );
  }

  final extras = [
    for (final block in blocks)
      if (block.extra case final extra? when extra.isNotEmpty) extra,
  ];

  return ContentBlock(
    content,
    extra: extras.isEmpty
        ? null
        : _joined(
            () => concatMaps(extras, appendLists: false),
            'failed to concat content block extras',
          ),
  );
}

/// The one item of [items]; several cannot be joined.
T _onlyOne<T>(List<T> items, String plural) {
  if (items.length == 1) return items.single;
  throw MessageConcatException('cannot concat multiple $plural');
}

/// [known], or [next] when [known] is empty; two different non-empty values
/// throw with [message].
String _agreed(
  String known,
  String next,
  String Function(String known, String next) message,
) {
  if (known.isEmpty) return next;
  if (next.isNotEmpty && next != known) {
    throw MessageConcatException(message(known, next));
  }
  return known;
}

/// Checks that values of a type only their producer knows, which Go keeps
/// in `any` fields, are all of one type ([sameValueType]).
final class _OneType {
  _OneType(this.describe);

  /// The error message for a value of type `actual` after `expected`.
  final String Function(Type expected, Type actual) describe;

  Object? _first;

  void check(Object value) {
    final first = _first;
    if (first == null) {
      _first = value;
    } else if (!sameValueType(first, value)) {
      throw MessageConcatException(
        describe(first.runtimeType, value.runtimeType),
      );
    }
  }
}

/// Joins values of a type only their producer knows with the [StreamConcat]
/// registry (Go's `internal.ConcatSliceValue`); see [concatAgenticMessages]
/// for the rules.
Object _concatAny(List<Object> values) =>
    _joined(() => StreamConcat.concatItems<Object>(values));

Reasoning _concatReasoning(List<Reasoning> reasons) {
  final text = StringBuffer();
  final signature = StringBuffer();
  final openAIExtensions = <OpenAIReasoningExtension>[];

  for (final reason in reasons) {
    text.write(reason.text);
    signature.write(reason.signature);
    final extension = reason.openAIExtension;
    if (extension != null) openAIExtensions.add(extension);
  }

  OpenAIReasoningExtension? openAIExtension;
  if (openAIExtensions.isNotEmpty) {
    try {
      openAIExtension = concatOpenAIReasoningExtensions(openAIExtensions);
    } on MessageConcatException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        MessageConcatException(
          'failed to concat openai reasoning extensions: ${error.message}',
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  return Reasoning(
    text: text.toString(),
    signature: signature.toString(),
    openAIExtension: openAIExtension,
  );
}

/// Port of eino's `concatAssistantGenTexts`.
///
/// Where Go stores the `reflect.Value` of the joined [AssistantGenText.extension]
/// (a bug: the field then holds a reflection handle, not the value), the
/// joined value itself is stored here.
AssistantGenText _concatAssistantGenTexts(List<AssistantGenText> texts) {
  if (texts.length == 1) return texts.single;

  final text = StringBuffer();
  final extensions = <Object>[];
  final openAIExtensions = <OpenAIAssistantGenTextExtension>[];
  final claudeExtensions = <ClaudeAssistantGenTextExtension>[];
  final types = _OneType(
    (expected, actual) => 'inconsistent extension types in assistant '
        "generated text chunks: '$expected' vs '$actual'",
  );

  for (final chunk in texts) {
    text.write(chunk.text);

    final extension = chunk.extension;
    if (extension != null) {
      types.check(extension);
      extensions.add(extension);
    }
    final openAI = chunk.openAIExtension;
    if (openAI != null) {
      types.check(openAI);
      openAIExtensions.add(openAI);
    }
    final claude = chunk.claudeExtension;
    if (claude != null) {
      types.check(claude);
      claudeExtensions.add(claude);
    }
  }

  return AssistantGenText(
    text: text.toString(),
    extension: extensions.isEmpty ? null : _concatAny(extensions),
    openAIExtension: openAIExtensions.isEmpty
        ? null
        : concatOpenAIAssistantGenTextExtensions(openAIExtensions),
    claudeExtension: claudeExtensions.isEmpty
        ? null
        : concatClaudeAssistantGenTextExtensions(claudeExtensions),
  );
}

/// The joined base64 data, URL and MIME type of generated media chunks
/// (Go's `concatAssistantGenImages`/`Audios`/`Videos`, which differ only in
/// the word in their messages).
({String url, String base64Data, String mimeType}) _concatMedia(
  Iterable<({String url, String base64Data, String mimeType})> chunks,
  String kind,
) {
  final data = StringBuffer();
  var url = '';
  var mimeType = '';
  for (final chunk in chunks) {
    data.write(chunk.base64Data);
    url = _agreed(
      url,
      chunk.url,
      (known, next) => 'inconsistent URLs in assistant generated $kind '
          "chunks: '$known' vs '$next'",
    );
    mimeType = _agreed(
      mimeType,
      chunk.mimeType,
      (known, next) => 'inconsistent MIME types in assistant generated $kind '
          "chunks: '$known' vs '$next'",
    );
  }
  return (url: url, base64Data: data.toString(), mimeType: mimeType);
}

AssistantGenImage _concatAssistantGenImages(List<AssistantGenImage> images) {
  if (images.length == 1) return images.single;
  final media = _concatMedia(
    images.map(
      (i) => (url: i.url, base64Data: i.base64Data, mimeType: i.mimeType),
    ),
    'image',
  );
  return AssistantGenImage(
    url: media.url,
    base64Data: media.base64Data,
    mimeType: media.mimeType,
  );
}

AssistantGenAudio _concatAssistantGenAudios(List<AssistantGenAudio> audios) {
  if (audios.length == 1) return audios.single;
  final media = _concatMedia(
    audios.map(
      (a) => (url: a.url, base64Data: a.base64Data, mimeType: a.mimeType),
    ),
    'audio',
  );
  return AssistantGenAudio(
    url: media.url,
    base64Data: media.base64Data,
    mimeType: media.mimeType,
  );
}

AssistantGenVideo _concatAssistantGenVideos(List<AssistantGenVideo> videos) {
  if (videos.length == 1) return videos.single;
  final media = _concatMedia(
    videos.map(
      (v) => (url: v.url, base64Data: v.base64Data, mimeType: v.mimeType),
    ),
    'video',
  );
  return AssistantGenVideo(
    url: media.url,
    base64Data: media.base64Data,
    mimeType: media.mimeType,
  );
}

FunctionToolCall _concatFunctionToolCalls(List<FunctionToolCall> calls) {
  if (calls.length == 1) return calls.single;

  var callId = '';
  var name = '';
  final arguments = StringBuffer();
  for (final call in calls) {
    callId = _agreed(
      callId,
      call.callId,
      (known, next) =>
          "expected call ID '$known' for function tool call, but got '$next'",
    );
    name = _agreed(
      name,
      call.name,
      (known, next) =>
          "expected tool name '$known' for function tool call, but got '$next'",
    );
    arguments.write(call.arguments);
  }
  return FunctionToolCall(
    callId: callId,
    name: name,
    arguments: arguments.toString(),
  );
}

FunctionToolResult _concatFunctionToolResults(
  List<FunctionToolResult> results,
) {
  if (results.length == 1) return results.single;

  var callId = '';
  var name = '';
  final content = <FunctionToolResultContentBlock>[];
  for (final result in results) {
    callId = _agreed(
      callId,
      result.callId,
      (known, next) =>
          "expected call ID '$known' for function tool result, but got '$next'",
    );
    name = _agreed(
      name,
      result.name,
      (known, next) => "expected tool name '$known' for function tool "
          "result, but got '$next'",
    );
    content.addAll(result.content);
  }
  return FunctionToolResult(callId: callId, name: name, content: content);
}

ServerToolCall _concatServerToolCalls(List<ServerToolCall> calls) {
  if (calls.length == 1) return calls.single;

  var callId = '';
  var name = '';
  final arguments = <Object>[];
  final types = _OneType(
    (expected, actual) => "expected type '$expected' for server tool call "
        "arguments, but got '$actual'",
  );
  for (final call in calls) {
    callId = _agreed(
      callId,
      call.callId,
      (known, next) =>
          "expected call ID '$known' for server tool call, but got '$next'",
    );
    name = _agreed(
      name,
      call.name,
      (known, next) =>
          "expected tool name '$known' for server tool call, but got '$next'",
    );
    final argument = call.arguments;
    if (argument != null) {
      types.check(argument);
      arguments.add(argument);
    }
  }
  return ServerToolCall(
    callId: callId,
    name: name,
    arguments: arguments.isEmpty ? null : _concatAny(arguments),
  );
}

ServerToolResult _concatServerToolResults(List<ServerToolResult> results) {
  if (results.length == 1) return results.single;

  var callId = '';
  var name = '';
  final contents = <Object>[];
  final types = _OneType(
    (expected, actual) =>
        "expected type '$expected' for server tool result, but got '$actual'",
  );
  for (final result in results) {
    callId = _agreed(
      callId,
      result.callId,
      (known, next) =>
          "expected call ID '$known' for server tool result, but got '$next'",
    );
    name = _agreed(
      name,
      result.name,
      (known, next) =>
          "expected tool name '$known' for server tool result, but got '$next'",
    );
    final content = result.content;
    if (content != null) {
      types.check(content);
      contents.add(content);
    }
  }

  Object? content;
  if (contents.isNotEmpty) {
    try {
      content = _concatAny(contents);
    } on MessageConcatException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        MessageConcatException(
          'failed to concat server tool result: ${error.message}',
          cause: error,
        ),
        stackTrace,
      );
    }
  }
  return ServerToolResult(callId: callId, name: name, content: content);
}

AgenticMcpToolCall _concatMcpToolCalls(List<AgenticMcpToolCall> calls) {
  if (calls.length == 1) return calls.single;

  final arguments = StringBuffer();
  var serverLabel = '';
  var callId = '';
  var name = '';
  for (final call in calls) {
    arguments.write(call.arguments);
    serverLabel = _agreed(
      serverLabel,
      call.serverLabel,
      (known, next) =>
          "expected server label '$known' for mcp tool call, but got '$next'",
    );
    callId = _agreed(
      callId,
      call.callId,
      (known, next) =>
          "expected call ID '$known' for mcp tool call, but got '$next'",
    );
    name = _agreed(
      name,
      call.name,
      (known, next) =>
          "expected tool name '$known' for mcp tool call, but got '$next'",
    );
  }
  // As in Go, the approval request id of the chunks is not carried over.
  return AgenticMcpToolCall(
    serverLabel: serverLabel,
    callId: callId,
    name: name,
    arguments: arguments.toString(),
  );
}

AgenticMcpToolResult _concatMcpToolResults(List<AgenticMcpToolResult> results) {
  if (results.length == 1) return results.single;

  var content = '';
  var serverLabel = '';
  var callId = '';
  var name = '';
  AgenticMcpToolCallError? error;
  for (final result in results) {
    if (result.content.isNotEmpty) content = result.content;
    serverLabel = _agreed(
      serverLabel,
      result.serverLabel,
      (known, next) =>
          "expected server label '$known' for mcp tool result, but got '$next'",
    );
    callId = _agreed(
      callId,
      result.callId,
      (known, next) =>
          "expected call ID '$known' for mcp tool result, but got '$next'",
    );
    name = _agreed(
      name,
      result.name,
      (known, next) =>
          "expected tool name '$known' for mcp tool result, but got '$next'",
    );
    if (result.error != null) error = result.error;
  }
  return AgenticMcpToolResult(
    serverLabel: serverLabel,
    callId: callId,
    name: name,
    content: content,
    error: error,
  );
}

AgenticMcpListToolsResult _concatMcpListToolsResults(
  List<AgenticMcpListToolsResult> results,
) {
  if (results.length == 1) return results.single;

  final tools = <AgenticMcpListToolsItem>[];
  var error = '';
  var serverLabel = '';
  for (final result in results) {
    tools.addAll(result.tools);
    if (result.error.isNotEmpty) error = result.error;
    serverLabel = _agreed(
      serverLabel,
      result.serverLabel,
      (known, next) => "expected server label '$known' for mcp list tools "
          "result, but got '$next'",
    );
  }
  return AgenticMcpListToolsResult(
    serverLabel: serverLabel,
    tools: tools,
    error: error,
  );
}

AgenticMcpToolApprovalRequest _concatMcpToolApprovalRequests(
  List<AgenticMcpToolApprovalRequest> requests,
) {
  if (requests.length == 1) return requests.single;

  final arguments = StringBuffer();
  var id = '';
  var name = '';
  var serverLabel = '';
  for (final request in requests) {
    arguments.write(request.arguments);
    id = _agreed(
      id,
      request.id,
      (known, next) => "expected request ID '$known' for mcp tool approval "
          "request, but got '$next'",
    );
    name = _agreed(
      name,
      request.name,
      (known, next) => "expected tool name '$known' for mcp tool approval "
          "request, but got '$next'",
    );
    serverLabel = _agreed(
      serverLabel,
      request.serverLabel,
      (known, next) => "expected server label '$known' for mcp tool approval "
          "request, but got '$next'",
    );
  }
  return AgenticMcpToolApprovalRequest(
    id: id,
    name: name,
    arguments: arguments.toString(),
    serverLabel: serverLabel,
  );
}

/// Port of eino's `concatAgenticResponseMeta`.
AgenticResponseMeta? _concatResponseMeta(List<AgenticResponseMeta> metas) {
  if (metas.isEmpty) return null;

  final usages = <TokenUsage>[];
  final extensions = <Object>[];
  final openAIExtensions = <OpenAIResponseMetaExtension>[];
  final claudeExtensions = <ClaudeResponseMetaExtension>[];
  final geminiExtensions = <GeminiResponseMetaExtension>[];
  final types = _OneType(
    (expected, actual) => 'inconsistent extension types in response meta '
        "chunks: '$expected' vs '$actual'",
  );

  for (final meta in metas) {
    final usage = meta.tokenUsage;
    if (usage != null) usages.add(usage);

    final extension = meta.extension;
    if (extension != null) {
      types.check(extension);
      extensions.add(extension);
    }
    final openAI = meta.openAIExtension;
    if (openAI != null) {
      types.check(openAI);
      openAIExtensions.add(openAI);
    }
    final claude = meta.claudeExtension;
    if (claude != null) {
      types.check(claude);
      claudeExtensions.add(claude);
    }
    final gemini = meta.geminiExtension;
    if (gemini != null) {
      types.check(gemini);
      geminiExtensions.add(gemini);
    }
  }

  T joined<T>(T Function() join, String what) {
    try {
      return join();
    } on MessageConcatException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        MessageConcatException(
          'failed to concat $what: ${error.message}',
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  return AgenticResponseMeta(
    tokenUsage: _concatTokenUsage(usages),
    extension: extensions.isEmpty
        ? null
        : joined(() => _concatAny(extensions), 'extensions'),
    openAIExtension: openAIExtensions.isEmpty
        ? null
        : joined(
            () => concatOpenAIResponseMetaExtensions(openAIExtensions),
            'openai extensions',
          ),
    claudeExtension: claudeExtensions.isEmpty
        ? null
        : joined(
            () => concatClaudeResponseMetaExtensions(claudeExtensions),
            'claude extensions',
          ),
    geminiExtension: geminiExtensions.isEmpty
        ? null
        : joined(
            () => concatGeminiResponseMetaExtensions(geminiExtensions),
            'gemini extensions',
          ),
  );
}

/// Port of eino's `concatTokenUsage`: the highest of each counter.
///
/// The detail objects are set when a chunk had one (Go's are struct values,
/// always there). threepio's fields beyond Go's (the image and audio tokens
/// of the completion details, the cost) are joined the same way.
TokenUsage? _concatTokenUsage(List<TokenUsage> usages) {
  if (usages.isEmpty) return null;

  int max(int a, int b) => a > b ? a : b;

  var promptTokens = 0;
  var completionTokens = 0;
  var totalTokens = 0;
  PromptTokenDetails? prompt;
  CompletionTokenDetails? completion;
  double? cost;

  for (final usage in usages) {
    promptTokens = max(promptTokens, usage.promptTokens);
    completionTokens = max(completionTokens, usage.completionTokens);
    totalTokens = max(totalTokens, usage.totalTokens);

    final promptDetails = usage.promptTokenDetails;
    if (promptDetails != null) {
      final known = prompt ?? const PromptTokenDetails();
      prompt = PromptTokenDetails(
        cachedTokens: max(known.cachedTokens, promptDetails.cachedTokens),
        cacheWriteTokens:
            max(known.cacheWriteTokens, promptDetails.cacheWriteTokens),
      );
    }

    final completionDetails = usage.completionTokenDetails;
    if (completionDetails != null) {
      final known = completion ?? const CompletionTokenDetails();
      completion = CompletionTokenDetails(
        reasoningTokens:
            max(known.reasoningTokens, completionDetails.reasoningTokens),
        imageTokens: max(known.imageTokens, completionDetails.imageTokens),
        audioTokens: max(known.audioTokens, completionDetails.audioTokens),
      );
    }

    final usageCost = usage.cost;
    if (usageCost != null && (cost == null || usageCost > cost)) {
      cost = usageCost;
    }
  }

  return TokenUsage(
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    totalTokens: totalTokens,
    promptTokenDetails: prompt,
    completionTokenDetails: completion,
    cost: cost,
  );
}
