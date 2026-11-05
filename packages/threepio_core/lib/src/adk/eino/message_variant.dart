/// One message of an agent event, complete or as a stream.
///
/// Port of eino `adk.MessageVariant` (`TypedMessageVariant[*schema.Message]`).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../schema/message.dart';
import '../../schema/message_concat.dart';
import '../../streaming/stream_reader.dart';

/// A message an agent produced: complete ([MessageVariant.message]) or as the
/// stream of its chunks ([MessageVariant.stream]).
///
/// Port of eino `adk.MessageVariant`. A stream has one reader: read it with
/// [messageStream] or join it with [getMessage], not both. After
/// [getMessage] the joined message is kept, and [messageStream] gives it as a
/// one-chunk stream.
sealed class MessageVariant {
  MessageVariant._({this.role, this.toolName = ''});

  /// A complete message.
  factory MessageVariant.message(
    Message message, {
    RoleType? role,
    String toolName,
  }) = _CompleteMessage;

  /// A message that arrives in chunks.
  factory MessageVariant.stream(
    StreamReader<Message> stream, {
    RoleType? role,
    String toolName,
  }) = _StreamingMessage;

  /// A message variant from its JSON form; see [toJson]. A stream comes back
  /// as a stream of its joined message, as in eino.
  factory MessageVariant.fromJson(Map<String, Object?> json) {
    final role = switch (json['role']) {
      final String name => RoleType.values.byName(name),
      _ => null,
    };
    final toolName = json['tool_name'] as String? ?? '';
    final message = Message.fromJson(
      (json['message']! as Map).cast<String, dynamic>(),
    );
    if (json['is_streaming'] == true) {
      return _StreamingMessage(
        StreamReader<Message>.fromIterable([message]),
        role: role,
        toolName: toolName,
      ).._joined = message;
    }
    return _CompleteMessage(message, role: role, toolName: toolName);
  }

  /// Who the message is from: [RoleType.assistant] for model output,
  /// [RoleType.tool] for a tool result.
  final RoleType? role;

  /// The tool whose result this is, or `''`.
  final String toolName;

  /// Whether the message arrives in chunks.
  bool get isStreaming;

  /// The complete message, or `null` for a stream.
  Message? get message;

  /// The stream of chunks, or `null` for a complete message.
  StreamReader<Message>? get messageStream;

  /// The message, joined from its chunks for a stream.
  ///
  /// Port of eino `MessageVariant.GetMessage`. Reads the stream to its end
  /// the first time; the result is kept. An error in the stream is rethrown,
  /// also by later calls.
  Future<Message> getMessage();

  /// The JSON form, as a checkpoint keeps it. A stream is written as its
  /// joined message, so it must have been read with [getMessage] first (or
  /// have been read to its end by the agent that produced it); otherwise
  /// this throws [StateError].
  Map<String, Object?> toJson();

  /// A second variant over the same message, for a second reader. For a
  /// stream, this variant and the copy each get their own copy of the
  /// chunks. Port of the message half of eino `copyTypedAgentEvent`.
  @internal
  MessageVariant copyForSecondReader();

  Map<String, Object?> _json(Message message, bool isStreaming) => {
        'is_streaming': isStreaming,
        'message': message.toJson(),
        if (role != null) 'role': role!.name,
        if (toolName.isNotEmpty) 'tool_name': toolName,
      };
}

final class _CompleteMessage extends MessageVariant {
  _CompleteMessage(this._message, {super.role, super.toolName = ''})
      : super._();

  final Message _message;

  @override
  bool get isStreaming => false;

  @override
  Message get message => _message;

  @override
  StreamReader<Message>? get messageStream => null;

  @override
  Future<Message> getMessage() async => _message;

  @override
  Map<String, Object?> toJson() => _json(_message, false);

  @override
  MessageVariant copyForSecondReader() => this;

  @override
  String toString() => 'MessageVariant.message($_message)';
}

final class _StreamingMessage extends MessageVariant {
  _StreamingMessage(StreamReader<Message> stream,
      {super.role, super.toolName = ''})
      : _stream = stream,
        super._();

  StreamReader<Message> _stream;
  Message? _joined;
  Object? _error;
  StackTrace? _errorTrace;
  Future<Message>? _reading;

  /// Chunks recorded while somebody else reads the stream, for a checkpoint
  /// taken before this variant's own stream is read.
  StreamRecorder? _recorder;

  @override
  bool get isStreaming => true;

  @override
  Message? get message => null;

  @override
  StreamReader<Message> get messageStream => _stream;

  @override
  Future<Message> getMessage() {
    final joined = _joined;
    if (joined != null) return Future.value(joined);
    final error = _error;
    if (error != null) return Future.error(error, _errorTrace);
    return _reading ??= _read();
  }

  // Port of eino `agentEventWrapper.consumeStream`: the stream is replaced by
  // what was read, so that a later reader sees the same chunks.
  Future<Message> _read() async {
    final chunks = <Message>[];
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
      _stream = StreamReader<Message>.fromIterable(chunks);
      rethrow;
    } finally {
      await source.close();
    }
    if (chunks.isEmpty) {
      final error = StateError('no messages in MessageVariant.messageStream');
      _error = error;
      _errorTrace = StackTrace.current;
      _stream = StreamReader<Message>.fromIterable(const []);
      throw error;
    }
    final joined = chunks.length == 1 ? chunks.single : concatMessages(chunks);
    _joined = joined;
    _stream = StreamReader<Message>.fromIterable([joined]);
    return joined;
  }

  @override
  Map<String, Object?> toJson() {
    final joined = _joined ?? _recorder?.joined;
    if (joined == null) {
      throw StateError(
        'a streamed message can only be written to JSON after its stream '
        'has been read (MessageVariant.getMessage)',
      );
    }
    return _json(joined, true);
  }

  @override
  MessageVariant copyForSecondReader() {
    final joined = _joined;
    if (joined != null) {
      return _StreamingMessage(
        StreamReader<Message>.fromIterable([joined]),
        role: role,
        toolName: toolName,
      ).._joined = joined;
    }
    final copies = _stream.copy(2);
    _stream = copies[0];
    return _StreamingMessage(copies[1], role: role, toolName: toolName)
      .._recorder = _recorder;
  }

  @override
  String toString() => 'MessageVariant.stream(role: ${role?.name})';
}

/// Records the chunks of a stream while it is read elsewhere, so that a
/// streamed message can be written to a checkpoint without reading its own
/// stream. The ADK uses it for the tool event a `returnDirectly` tool leaves
/// in the agent's state.
@internal
final class StreamRecorder {
  final List<Message> _chunks = [];
  bool _done = false;

  /// Notes one chunk.
  void add(Message chunk) => _chunks.add(chunk);

  /// Notes the end of the stream.
  void finish() => _done = true;

  /// The joined message once the stream has ended, else `null`.
  Message? get joined {
    if (!_done || _chunks.isEmpty) return null;
    return _chunks.length == 1 ? _chunks.single : concatMessages(_chunks);
  }
}

/// A stream variant whose chunks [recorder] sees while another reader reads
/// them.
@internal
MessageVariant recordedStreamVariant(
  StreamReader<Message> stream,
  StreamRecorder recorder, {
  RoleType? role,
  String toolName = '',
}) =>
    _StreamingMessage(stream, role: role, toolName: toolName)
      .._recorder = recorder;
