/// Ids the ADK gives the messages it produces.
///
/// Port of eino `adk/internal/message_id.go` and of `GetMessageID` /
/// `EnsureMessageID` in `adk/wrappers.go`.
library;

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../schema/message.dart';

const _uuid = Uuid();

/// The key of the message id in [Message.extra]. Port of eino
/// `internal.EinoMsgIDKey`.
const String einoMessageIdKey = '_eino_msg_id';

/// The id the ADK gave [message], or `''` when it has none.
///
/// Port of eino `adk.GetMessageID`. A `ChatModelAgent` gives an id to every
/// message its model produces (the first chunk of a stream carries it) and to
/// every tool result; the event and the state share the id.
String messageIdOf(Message message) => messageIdIn(message.extra);

/// [message] with an id, or [message] itself when it has one.
///
/// Port of eino `adk.EnsureMessageID`. A middleware that sends events of its
/// own with `AgentContext.sendEvent` uses it so that its messages have ids
/// like the ones the agent sends.
Message ensureMessageId(Message message) => messageIdOf(message).isNotEmpty
    ? message
    : withMessageId(message, _uuid.v4());

/// The id in [extra]. Port of eino `internal.GetMessageID`.
@internal
String messageIdIn(Map<String, dynamic>? extra) {
  final id = extra?[einoMessageIdKey];
  return id is String ? id : '';
}

/// A copy of [extra] with the id [id]. Port of eino `internal.SetMessageID`:
/// the map of the message is never changed in place.
@internal
Map<String, dynamic> extraWithMessageId(Map<String, dynamic>? extra, String id) =>
    {...?extra, einoMessageIdKey: id};

/// [message] with the id [id].
@internal
Message withMessageId(Message message, String id) =>
    message.copyWith(extra: extraWithMessageId(message.extra, id));

/// A new message id.
@internal
String newMessageId() => _uuid.v4();
