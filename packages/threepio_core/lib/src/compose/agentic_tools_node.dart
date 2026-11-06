/// The tools node of the agentic path.
///
/// Port of eino `compose/agentic_tools_node.go`. **Beta**, as the whole
/// agentic path is upstream.
library;

import 'package:meta/meta.dart';

import '../components/component_type.dart';
import '../core/run_context.dart';
import '../schema/agentic_message.dart';
import '../schema/message.dart';
import '../streaming/stream_reader.dart';
import 'call_options.dart';
import 'runnable.dart';
import 'stream_conversion.dart';
import 'tools_node.dart';
import 'tools_node_options.dart';

/// Runs the function tool calls of an [AgenticMessage] and returns one
/// [AgenticMessage] per call, in the order of the calls.
///
/// Port of eino `compose.AgenticToolsNode`. It wraps a [ToolsNode] with the
/// same [ToolsNodeConfig] and converts on the way in and out:
///
/// * in: the [FunctionToolCall] blocks of the input become the tool calls
///   of an assistant `Message` (other blocks, such as server or MCP tool
///   calls, are left to the model provider and ignored);
/// * out: each tool message becomes a user [AgenticMessage] with one
///   [FunctionToolResult] block (a text result is one [UserInputText] part,
///   a multimodal result one part per input part), or with one
///   [ToolSearchFunctionToolResult] block when the result is exactly one
///   tool search result. The `extra` of a tool message is the `extra` of
///   both the block and the message.
///
/// Everything else (aliases, argument handlers, middlewares, sequential
/// execution, interrupt and resume, the options of a call) is the inner
/// [ToolsNode]'s; see there. The interrupt state a resumed run finds is the
/// inner node's, with the converted assistant message.
///
/// ```dart
/// final tools = await AgenticToolsNode.create(
///   ToolsNodeConfig(tools: [weather, search]),
/// );
/// final results = await tools.invoke(ctx, modelAnswer);
/// ```
///
/// [stream] gives the results as they arrive. Every chunk has one message
/// per tool call, like the chunks of [ToolsNode.stream]. The message of the
/// call the chunk belongs to carries a block with `StreamingMeta(index: i)`,
/// `i` being the position of the call; the others are messages without
/// blocks, where eino has `nil` (a Dart list of messages cannot hold `null`).
/// An empty piece looks like the empty tool messages [ToolsNode.stream]
/// puts in the positions of the other calls, so it gives a message without
/// blocks too; a call whose stream only had empty pieces gets its block,
/// without content, in one more chunk at the end (not after an error),
/// where eino gives it in the chunk of the piece.
///
/// Joined with `concatAgenticMessagesArray`, the chunks give what eino's
/// give: one message per call whose [FunctionToolResult] has the parts of
/// its non-empty pieces in order (where [invoke] has the joined text of a
/// streamed text result as one part), or the tool search result. One
/// difference: eino keeps the `StreamingMeta` of a call that had a single
/// chunk, because it joins nothing there; here such a call is joined with
/// the empty messages of the other chunks (when the stream has more than
/// one chunk), and the joined block has none, as the blocks of [invoke] and
/// of every call with several chunks.
final class AgenticToolsNode
    implements
        Runnable<AgenticMessage, List<AgenticMessage>>,
        TypedComponent {
  /// An agentic tools node with the given configuration. The tools are asked
  /// for their `info()` on the first call; [AgenticToolsNode.create] does it
  /// at once.
  AgenticToolsNode(ToolsNodeConfig config) : this._(ToolsNode(config));

  AgenticToolsNode._(this._inner) {
    _packer =
        RunnablePacker<AgenticMessage, List<AgenticMessage>, CallOption>(
      invoke: (ctx, input, options) async => toolMessageToAgenticMessage(
        await _inner.invoke(
          ctx,
          agenticMessageToToolCallMessage(input),
          options: options,
        ),
      ),
      stream: (ctx, input, options) async => streamToolMessageToAgenticMessage(
        await _inner.stream(
          ctx,
          agenticMessageToToolCallMessage(input),
          options: options,
        ),
      ),
    );
  }

  /// Creates an agentic tools node and checks its configuration, as
  /// [ToolsNode.create] does.
  ///
  /// Port of eino `compose.NewAgenticToolsNode(ctx, config)`.
  static Future<AgenticToolsNode> create(
    ToolsNodeConfig config, {
    RunContext? ctx,
  }) async =>
      AgenticToolsNode._(await ToolsNode.create(config, ctx: ctx));

  final ToolsNode _inner;
  late final RunnablePacker<AgenticMessage, List<AgenticMessage>, CallOption>
      _packer;

  /// Eino reports an agentic tools node without an implementation name
  /// (`AgenticToolsNode.GetType` returns `""`).
  @override
  String get componentTypeName => '';

  @override
  Future<List<AgenticMessage>> invoke(
    RunContext ctx,
    AgenticMessage input, {
    List<CallOption> options = const [],
  }) =>
      _packer.invoke(ctx, input, options);

  @override
  Future<StreamReader<List<AgenticMessage>>> stream(
    RunContext ctx,
    AgenticMessage input, {
    List<CallOption> options = const [],
  }) =>
      _packer.stream(ctx, input, options);

  @override
  Future<List<AgenticMessage>> collect(
    RunContext ctx,
    StreamReader<AgenticMessage> input, {
    List<CallOption> options = const [],
  }) =>
      _packer.collect(ctx, input, options);

  @override
  Future<StreamReader<List<AgenticMessage>>> transform(
    RunContext ctx,
    StreamReader<AgenticMessage> input, {
    List<CallOption> options = const [],
  }) =>
      _packer.transform(ctx, input, options);

  /// Runs the tool calls of [input] and returns their results.
  ///
  /// Port of eino `AgenticToolsNode.Invoke`. The same as [invoke], with the
  /// options of the tools node given directly.
  Future<List<AgenticMessage>> invokeTools(
    RunContext ctx,
    AgenticMessage input, {
    ToolsNodeOptions? options,
  }) async =>
      toolMessageToAgenticMessage(
        await _inner.invokeTools(
          ctx,
          agenticMessageToToolCallMessage(input),
          options: options,
        ),
      );

  /// Runs the tool calls of [input] and returns their results as they
  /// arrive.
  ///
  /// Port of eino `AgenticToolsNode.Stream`. The same as [stream], with the
  /// options of the tools node given directly.
  Future<StreamReader<List<AgenticMessage>>> streamTools(
    RunContext ctx,
    AgenticMessage input, {
    ToolsNodeOptions? options,
  }) async =>
      streamToolMessageToAgenticMessage(
        await _inner.streamTools(
          ctx,
          agenticMessageToToolCallMessage(input),
          options: options,
        ),
      );
}

/// The assistant message whose tool calls are the [FunctionToolCall] blocks
/// of [input]; the `extra` of a block is the `extra` of its call.
///
/// Port of eino's internal `agenticMessageToToolCallMessage`. Blocks of
/// other kinds are skipped. Without function tool calls the message has no
/// tool calls (`null`, Go's nil slice).
@visibleForTesting
Message agenticMessageToToolCallMessage(AgenticMessage input) {
  final calls = <ToolCall>[
    for (final block in input.contentBlocks)
      if (block.functionToolCall case final call?)
        ToolCall(
          id: call.callId,
          function: FunctionCall(name: call.name, arguments: call.arguments),
          extra: block.extra,
        ),
  ];
  return Message(
    role: RoleType.assistant,
    toolCalls: calls.isEmpty ? null : calls,
  );
}

/// The tool messages [input] as agentic messages, one per message.
///
/// Port of eino's internal `toolMessageToAgenticMessage`.
@visibleForTesting
List<AgenticMessage> toolMessageToAgenticMessage(List<Message> input) => [
      for (final message in input) _toAgenticMessage(message, null),
    ];

/// The chunks of a tools node stream as chunks of agentic messages.
///
/// Port of eino's internal `streamToolMessageToAgenticMessage`; see
/// [AgenticToolsNode] for how chunks without content are given (eino has
/// `nil` where a call has no piece in a chunk).
@visibleForTesting
StreamReader<List<AgenticMessage>> streamToolMessageToAgenticMessage(
  StreamReader<List<Message>> input,
) {
  // The calls that so far only had empty pieces, by position, with the
  // last such piece (it has the call's id and name), and the calls that had
  // content.
  final emptyOnly = <int, Message>{};
  final withContent = <int>{};
  var width = 0;
  // A stream that failed (an interrupt at its end, for example) gets no
  // chunk after the error.
  var failed = false;
  return input.convert<List<AgenticMessage>>(
    (chunk) {
      width = chunk.length;
      final converted = <AgenticMessage>[];
      for (final (index, message) in chunk.indexed) {
        if (_isEmptyPiece(message)) {
          if (!withContent.contains(index)) emptyOnly[index] = message;
          converted.add(_noBlocks);
        } else {
          withContent.add(index);
          emptyOnly.remove(index);
          converted
              .add(_toAgenticMessage(message, StreamingMeta(index: index)));
        }
      }
      return converted;
    },
    errWrapper: (error) {
      failed = true;
      return error;
    },
    onEof: () => failed || emptyOnly.isEmpty
        ? null
        : [
            for (var index = 0; index < width; index++)
              if (emptyOnly[index] case final message?)
                _toAgenticMessage(message, StreamingMeta(index: index))
              else
                _noBlocks,
          ],
  );
}

/// The stand-in for eino's `nil` in a chunk: a user message without blocks,
/// which adds nothing when chunks are joined.
final AgenticMessage _noBlocks = AgenticMessage(role: AgenticRoleType.user);

/// Whether [message], a piece of a tools node stream, carries nothing: the
/// tools node fills the positions of the other calls of a chunk with such
/// messages.
bool _isEmptyPiece(Message message) =>
    message.content.isEmpty &&
    (message.userInputMultiContent?.isEmpty ?? true) &&
    (message.extra?.isEmpty ?? true);

AgenticMessage _toAgenticMessage(Message message, StreamingMeta? meta) {
  final toolSearch = _toolSearchResultBlock(message, meta);
  if (toolSearch != null) {
    return AgenticMessage(
      role: AgenticRoleType.user,
      contentBlocks: [toolSearch],
      extra: message.extra,
    );
  }

  final parts = message.userInputMultiContent;
  final List<FunctionToolResultContentBlock> content;
  if (parts != null && parts.isNotEmpty) {
    content = messageInputPartsToFunctionToolBlocks(parts);
  } else if (message.content.isNotEmpty) {
    content = [
      FunctionToolResultContentBlock(UserInputText(text: message.content)),
    ];
  } else {
    content = const [];
  }
  return AgenticMessage(
    role: AgenticRoleType.user,
    contentBlocks: [
      ContentBlock(
        FunctionToolResult(
          callId: message.toolCallId ?? '',
          name: message.toolName ?? '',
          content: content,
        ),
        streamingMeta: meta,
        extra: message.extra,
      ),
    ],
    extra: message.extra,
  );
}

/// The [ToolSearchFunctionToolResult] block of [message] when its only part
/// is a tool search result. Port of eino's internal
/// `toolSearchResultMessageToAgenticMessage`.
ContentBlock? _toolSearchResultBlock(Message message, StreamingMeta? meta) {
  final parts = message.userInputMultiContent;
  if (parts == null || parts.length != 1) return null;
  final part = parts.single;
  final result = part.toolSearchResult;
  if (part.type != ChatMessagePartType.toolSearchResult || result == null) {
    return null;
  }
  return ContentBlock(
    ToolSearchFunctionToolResult(
      callId: message.toolCallId ?? '',
      name: message.toolName ?? '',
      result: result,
    ),
    streamingMeta: meta,
    extra: message.extra,
  );
}

/// The input parts of a tool message as the parts of a
/// [FunctionToolResult]; the `extra` of a part is the `extra` of its block.
///
/// Port of eino's internal `messageInputPartsToFunctionToolBlocks`. A media
/// part without its media, and a part of a kind a tool result cannot hold
/// (reasoning, tool search result), are skipped.
@visibleForTesting
List<FunctionToolResultContentBlock> messageInputPartsToFunctionToolBlocks(
  List<MessageInputPart> parts,
) =>
    [
      for (final part in parts)
        if (_toUserInput(part) case final content?)
          FunctionToolResultContentBlock(content, extra: part.extra),
    ];

UserInputVariant? _toUserInput(MessageInputPart part) => switch (part.type) {
      ChatMessagePartType.text => UserInputText(text: part.text ?? ''),
      ChatMessagePartType.imageUrl => switch (part.image) {
          final image? => UserInputImage(
              url: image.common.url ?? '',
              base64Data: image.common.base64Data ?? '',
              fileId: image.common.fileId ?? '',
              mimeType: image.common.mimeType ?? '',
              detail: image.detail,
            ),
          null => null,
        },
      ChatMessagePartType.audioUrl => switch (part.audio) {
          final audio? => UserInputAudio(
              url: audio.common.url ?? '',
              base64Data: audio.common.base64Data ?? '',
              fileId: audio.common.fileId ?? '',
              mimeType: audio.common.mimeType ?? '',
            ),
          null => null,
        },
      ChatMessagePartType.videoUrl => switch (part.video) {
          final video? => UserInputVideo(
              url: video.common.url ?? '',
              base64Data: video.common.base64Data ?? '',
              fileId: video.common.fileId ?? '',
              mimeType: video.common.mimeType ?? '',
            ),
          null => null,
        },
      ChatMessagePartType.fileUrl => switch (part.file) {
          final file? => UserInputFile(
              url: file.common.url ?? '',
              base64Data: file.common.base64Data ?? '',
              fileId: file.common.fileId ?? '',
              name: file.name ?? '',
              mimeType: file.common.mimeType ?? '',
            ),
          null => null,
        },
      ChatMessagePartType.reasoning ||
      ChatMessagePartType.toolSearchResult =>
        null,
    };
