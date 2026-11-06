/// The message strategy the ADK engine is shared through.
///
/// Eino's ADK is generic over `M MessageType` (`*schema.Message |
/// *schema.AgenticMessage`) and settles every message-specific step with a
/// type switch (`concatMessageStream`, `GetMessageID`, `EnsureMessageID`,
/// `extractTextContent`, `newUserMessage`, `agenticMessageHasToolCalls`,
/// `extractToolIdentifiers`, …). Dart has no union bounds, so the agentic
/// agent is a parallel set of public types and those steps live in one
/// strategy object per message type, an [AgentMessageCodec]: the generic
/// pieces of the engine take a codec instead of switching on the type.
library;

import 'package:meta/meta.dart';

import '../../schema/agentic_message.dart';
import '../../schema/agentic_message_concat.dart';
import '../../schema/message.dart';
import '../../schema/message_concat.dart';
import '../../streaming/stream_reader.dart';
import '../eino/message_id.dart';

/// The message-specific steps of the ADK engine for messages of type [M].
///
/// Port of the type switches of eino's generic ADK helpers (see the library
/// comment). [classicMessageCodec] is the classic `Message`, and
/// [agenticMessageCodec] the `AgenticMessage` of the agentic path.
@internal
abstract interface class AgentMessageCodec<M extends Object> {
  /// Joins the chunks of a streamed message. Port of the switch in eino
  /// `concatMessageStream` (`schema.ConcatMessages` /
  /// `schema.ConcatAgenticMessages`).
  M concat(List<M> chunks);

  /// The JSON form of [message], as checkpoints keep it.
  Map<String, Object?> encode(M message);

  /// A message from its JSON form ([encode]).
  M decode(Map<String, Object?> json);

  /// The id the ADK gave [message], or `''`. Port of eino `GetMessageID`.
  String messageIdOf(M message);

  /// [message] with the id [id]. Port of eino `typedSetMessageID` (on a
  /// copy: messages are immutable here).
  M withMessageId(M message, String id);

  /// Whether [message] asks for function tool calls. Port of the branch
  /// test of eino's ReAct graphs (`len(chunk.ToolCalls) > 0` /
  /// `agenticMessageHasToolCalls`).
  bool hasToolCalls(M message);

  /// The function tool calls [message] asks for, by name and call id.
  List<({String name, String callId})> toolCallsOf(M message);

  /// The tool name and call id of the tool result [message]. Port of eino
  /// `extractToolIdentifiers` (and of `ToolName`/`ToolCallID` of a classic
  /// tool message).
  ({String toolName, String callId}) toolResultOf(M message);

  /// A system message with [text]. Port of `schema.SystemMessage` /
  /// `schema.SystemAgenticMessage`.
  M system(String text);

  /// A user message with [text]. Port of eino `newUserMessage`
  /// (`schema.UserMessage` / `schema.UserAgenticMessage`).
  M user(String text);

  /// The text of [message]. Port of eino `extractTextContent`.
  String textContent(M message);
}

/// The codec of the classic [Message].
@internal
const AgentMessageCodec<Message> classicMessageCodec = _MessageCodec();

/// The codec of the agentic path's [AgenticMessage].
@internal
const AgentMessageCodec<AgenticMessage> agenticMessageCodec =
    _AgenticMessageCodec();

final class _MessageCodec implements AgentMessageCodec<Message> {
  const _MessageCodec();

  @override
  Message concat(List<Message> chunks) =>
      chunks.length == 1 ? chunks.single : concatMessages(chunks);

  @override
  Map<String, Object?> encode(Message message) => message.toJson();

  @override
  Message decode(Map<String, Object?> json) =>
      Message.fromJson(json.cast<String, dynamic>());

  @override
  String messageIdOf(Message message) => messageIdIn(message.extra);

  @override
  Message withMessageId(Message message, String id) =>
      message.copyWith(extra: extraWithMessageId(message.extra, id));

  @override
  bool hasToolCalls(Message message) => message.toolCalls?.isNotEmpty ?? false;

  @override
  List<({String name, String callId})> toolCallsOf(Message message) => [
        for (final call in message.toolCalls ?? const <ToolCall>[])
          (name: call.function.name, callId: call.id),
      ];

  @override
  ({String toolName, String callId}) toolResultOf(Message message) =>
      (toolName: message.toolName ?? '', callId: message.toolCallId ?? '');

  @override
  Message system(String text) => Message.system(text);

  @override
  Message user(String text) => Message.user(text);

  @override
  String textContent(Message message) => message.content;
}

final class _AgenticMessageCodec implements AgentMessageCodec<AgenticMessage> {
  const _AgenticMessageCodec();

  @override
  AgenticMessage concat(List<AgenticMessage> chunks) =>
      chunks.length == 1 ? chunks.single : concatAgenticMessages(chunks);

  @override
  Map<String, Object?> encode(AgenticMessage message) =>
      message.toJson();

  @override
  AgenticMessage decode(Map<String, Object?> json) =>
      AgenticMessage.fromJson(json);

  @override
  String messageIdOf(AgenticMessage message) =>
      messageIdIn(message.extra?.cast<String, dynamic>());

  @override
  AgenticMessage withMessageId(AgenticMessage message, String id) =>
      message.copyWith(
        extra: extraWithMessageId(message.extra?.cast<String, dynamic>(), id),
      );

  @override
  bool hasToolCalls(AgenticMessage message) =>
      message.contentBlocks.any((block) => block.functionToolCall != null);

  @override
  List<({String name, String callId})> toolCallsOf(AgenticMessage message) => [
        for (final block in message.contentBlocks)
          if (block.functionToolCall case final call?)
            (name: call.name, callId: call.callId),
      ];

  @override
  ({String toolName, String callId}) toolResultOf(AgenticMessage message) {
    for (final block in message.contentBlocks) {
      if (block.functionToolResult case final result?) {
        return (toolName: result.name, callId: result.callId);
      }
      if (block.toolSearchFunctionToolResult case final result?) {
        return (toolName: result.name, callId: result.callId);
      }
    }
    return (toolName: '', callId: '');
  }

  @override
  AgenticMessage system(String text) => AgenticMessage.system(text);

  @override
  AgenticMessage user(String text) => AgenticMessage.user(text);

  @override
  String textContent(AgenticMessage message) => [
        for (final block in message.contentBlocks)
          if (block.assistantGenText case final text?) text.text,
      ].join('\n');
}

/// [message] with an id, or [message] itself when it has one. Port of eino
/// `EnsureMessageID`.
@internal
M ensureMessageIdWith<M extends Object>(AgentMessageCodec<M> codec, M message) =>
    codec.messageIdOf(message).isNotEmpty
        ? message
        : codec.withMessageId(message, newMessageId());

/// Reads [stream] to its end, closes it and joins its chunks. Port of eino
/// `concatMessageStream`; an empty stream fails as the concat does.
@internal
Future<M> concatMessageStreamWith<M extends Object>(
  AgentMessageCodec<M> codec,
  StreamReader<M> stream,
) async {
  final chunks = <M>[];
  try {
    for (var chunk = await stream.nextOrNull();
        chunk != null;
        chunk = await stream.nextOrNull()) {
      chunks.add(chunk);
    }
  } finally {
    await stream.close();
  }
  if (chunks.isEmpty) {
    throw StateError('no messages to concat');
  }
  return codec.concat(chunks);
}

/// Records the chunks of a stream while it is read elsewhere, so that a
/// streamed message can be written to a checkpoint without reading its own
/// stream (the tool event of a `returnDirectly` tool kept in the state).
/// The generic twin of the classic `StreamRecorder`.
@internal
final class TypedStreamRecorder<M extends Object> {
  /// A recorder that joins with [codec].
  TypedStreamRecorder(this.codec);

  /// How the chunks are joined.
  final AgentMessageCodec<M> codec;

  final List<M> _chunks = [];
  bool _done = false;

  /// Notes one chunk.
  void add(M chunk) => _chunks.add(chunk);

  /// Notes the end of the stream.
  void finish() => _done = true;

  /// The joined message once the stream has ended, else `null`.
  M? get joined {
    if (!_done || _chunks.isEmpty) return null;
    return codec.concat(_chunks);
  }
}

/// A streamed message that is joined at most once: the generic core of a
/// streamed message variant. Port of eino `agentEventWrapper.consumeStream`
/// (the stream is replaced by what was read, so that a later reader sees the
/// same chunks; an error is kept and rethrown).
@internal
final class JoinOnceStream<M extends Object> {
  /// The stream [stream] of messages joined with [codec].
  JoinOnceStream(StreamReader<M> stream, this.codec, {this.recorder})
      : _stream = stream;

  /// A stream that is already joined into [joined].
  JoinOnceStream.joined(M joined, this.codec)
      : _stream = StreamReader<M>.fromIterable([joined]),
        _joined = joined,
        recorder = null;

  /// How the chunks are joined.
  final AgentMessageCodec<M> codec;

  /// Chunks recorded while somebody else reads the stream.
  final TypedStreamRecorder<M>? recorder;

  StreamReader<M> _stream;
  M? _joined;
  Object? _error;
  StackTrace? _errorTrace;
  Future<M>? _reading;

  /// The stream of chunks (after [join], the joined message as one chunk).
  StreamReader<M> get stream => _stream;

  /// The joined message once known: joined here or recorded elsewhere.
  M? get joinedOrRecorded => _joined ?? recorder?.joined;

  /// The joined message; reads the stream the first time.
  Future<M> join() {
    final joined = _joined;
    if (joined != null) return Future.value(joined);
    final error = _error;
    if (error != null) return Future.error(error, _errorTrace);
    return _reading ??= _read();
  }

  Future<M> _read() async {
    final chunks = <M>[];
    final source = _stream;
    try {
      for (var chunk = await source.nextOrNull();
          chunk != null;
          chunk = await source.nextOrNull()) {
        chunks.add(chunk);
      }
    } on Object catch (error, stackTrace) {
      _error = error;
      _errorTrace = stackTrace;
      _stream = StreamReader<M>.fromIterable(chunks);
      rethrow;
    } finally {
      await source.close();
    }
    if (chunks.isEmpty) {
      final error = StateError('no messages in MessageVariant.messageStream');
      _error = error;
      _errorTrace = StackTrace.current;
      _stream = StreamReader<M>.fromIterable(const []);
      throw error;
    }
    final M joined;
    try {
      joined = codec.concat(chunks);
    } on Object catch (error, stackTrace) {
      _error = error;
      _errorTrace = stackTrace;
      _stream = StreamReader<M>.fromIterable(chunks);
      rethrow;
    }
    _joined = joined;
    _stream = StreamReader<M>.fromIterable([joined]);
    return joined;
  }

  /// A second stream over the same message: both this one and the copy get
  /// their own copy of the chunks.
  JoinOnceStream<M> copyForSecondReader() {
    final joined = _joined;
    if (joined != null) return JoinOnceStream<M>.joined(joined, codec);
    final copies = _stream.copy(2);
    _stream = copies[0];
    return JoinOnceStream<M>(copies[1], codec, recorder: recorder);
  }
}
