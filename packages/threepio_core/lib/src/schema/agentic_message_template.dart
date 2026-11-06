/// Templates that render to agentic messages: [AgenticMessagesTemplate] and
/// its two implementations in this package ([AgenticMessage] itself and
/// [AgenticMessagesPlaceholder]).
///
/// Port of the template part of eino `schema/agentic_message.go`, the
/// agentic twin of `message_template.dart`. **Beta**, as the whole agentic
/// path is upstream.
library;

import 'package:meta/meta.dart';

import '../core/run_context.dart';
import '../errors.dart';
import 'agentic_message.dart';
import 'message_template.dart';

/// Something that renders to a list of agentic messages.
///
/// Port of eino `schema.AgenticMessagesTemplate`. An agentic chat template
/// is a list of these: each [AgenticMessage] renders to itself with the
/// placeholders of its user input filled, each [AgenticMessagesPlaceholder]
/// to the messages found under its key.
// ignore: one_member_abstracts
abstract interface class AgenticMessagesTemplate {
  /// The messages this template gives for [vars], read as [type].
  ///
  /// Throws [FormatException] when the template is malformed or [vars] lacks
  /// what it needs. The templates of this library throw a
  /// [ThreepioFormatException], which is one.
  Future<List<AgenticMessage>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  );
}

/// A place in an agentic chat template for a list of agentic messages taken
/// from the variables, typically the conversation so far.
///
/// Port of eino `schema.AgenticMessagesPlaceholder`.
///
/// ```dart
/// const history = AgenticMessagesPlaceholder('history', optional: true);
/// final messages = await history.format(
///   RunContext.background(),
///   {'history': [AgenticMessage.user('what is eino?')]},
///   FormatType.fString,
/// );
/// ```
@immutable
final class AgenticMessagesPlaceholder implements AgenticMessagesTemplate {
  /// A placeholder for the messages under [key]. Unless it is [optional], the
  /// key has to be there.
  const AgenticMessagesPlaceholder(this.key, {this.optional = false});

  /// The variable that holds the messages.
  final String key;

  /// Whether a missing variable renders to no messages instead of failing.
  final bool optional;

  /// The messages under [key]: a `List<AgenticMessage>`, or any list whose
  /// items are all agentic messages.
  ///
  /// Throws [ThreepioFormatException] when the key is missing (and the
  /// placeholder is not [optional]) or holds something else.
  @override
  Future<List<AgenticMessage>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  ) async {
    if (!vars.containsKey(key)) {
      if (optional) return [];
      throw ThreepioFormatException(
        'message placeholder format: $key not found',
      );
    }

    final value = vars[key];
    if (value is List<AgenticMessage>) return value;
    if (value is List<Object?> && value.every((item) => item is AgenticMessage)) {
      return value.cast<AgenticMessage>();
    }
    throw ThreepioFormatException(
      'only agentic messages can be used to format message placeholder, '
      'key: $key, actual type: ${value.runtimeType}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgenticMessagesPlaceholder &&
      other.key == key &&
      other.optional == optional;

  @override
  int get hashCode => Object.hash(key, optional);

  @override
  String toString() =>
      'AgenticMessagesPlaceholder($key, optional: $optional)';
}
