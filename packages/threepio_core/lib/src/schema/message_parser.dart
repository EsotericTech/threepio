/// Parsers that turn a [Message] into a typed value.
///
/// Port of eino `schema/message_parser.go`.
library;

import 'dart:convert';

import '../core/run_context.dart';
import 'message.dart';

/// Parses a [Message] into a `T`.
///
/// Port of eino `schema.MessageParser`.
// ignore: one_member_abstracts
abstract interface class MessageParser<T> {
  /// The value [message] stands for. Throws [FormatException] when the
  /// message cannot be read as a `T`.
  Future<T> parse(RunContext ctx, Message message);
}

/// Where a [MessageJsonParser] finds the JSON.
///
/// Port of eino `schema.MessageParseFrom`.
enum MessageParseFrom {
  /// [Message.content].
  content,

  /// The arguments of the first tool call of the message.
  toolCall,
}

/// Reads JSON out of a message and builds a `T` from it.
///
/// Port of eino `schema.MessageJSONParser`; the fields of Go's
/// `MessageJSONParseConfig` are the named parameters of the constructor. Where
/// Go fills a struct by reflection, [fromJson] builds the value.
///
/// ```dart
/// final parser = MessageJsonParser<User>.object(
///   fromJson: User.fromJson,
///   parseFrom: MessageParseFrom.toolCall,
///   parseKeyPath: 'result.user',
/// );
/// final user = await parser.parse(ctx, message);
/// ```
final class MessageJsonParser<T> implements MessageParser<T> {
  /// A parser that gives the decoded JSON, whatever its shape, to [fromJson].
  const MessageJsonParser({
    required this.fromJson,
    this.parseFrom = MessageParseFrom.content,
    this.parseKeyPath = '',
  });

  /// A parser for JSON objects: [fromJson] has the shape of the `fromJson`
  /// constructors of generated model classes.
  factory MessageJsonParser.object({
    required T Function(Map<String, dynamic> json) fromJson,
    MessageParseFrom parseFrom = MessageParseFrom.content,
    String parseKeyPath = '',
  }) =>
      MessageJsonParser<T>(
        fromJson: (json) => json is Map<String, dynamic>
            ? fromJson(json)
            : throw FormatException(
                'expected a JSON object, got ${json.runtimeType}',
              ),
        parseFrom: parseFrom,
        parseKeyPath: parseKeyPath,
      );

  /// Builds the result from the decoded JSON: a `Map<String, dynamic>`, a
  /// `List<dynamic>`, a string, a number, a bool or `null`.
  final T Function(Object? json) fromJson;

  /// Where the JSON is taken from.
  final MessageParseFrom parseFrom;

  /// Dot-separated keys of the object to parse within the JSON, for example
  /// `field.sub_field`. Empty for the whole JSON.
  final String parseKeyPath;

  @override
  Future<T> parse(RunContext ctx, Message message) async {
    final String source;
    switch (parseFrom) {
      case MessageParseFrom.content:
        source = message.content;
      case MessageParseFrom.toolCall:
        final toolCalls = message.toolCalls;
        if (toolCalls == null || toolCalls.isEmpty) {
          throw const FormatException('no tool call found');
        }
        source = toolCalls.first.function.arguments;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException(
        'failed to unmarshal content: ${error.message}',
        source,
        error.offset,
      );
    }

    final data = _extract(decoded, source);
    try {
      return fromJson(data);
    } on FormatException {
      rethrow;
    } catch (error, stackTrace) {
      // A fromJson that meets JSON of the wrong shape fails with a cast
      // error; to the caller that is unparsable input like any other.
      Error.throwWithStackTrace(
        FormatException('failed to unmarshal content: $error', source),
        stackTrace,
      );
    }
  }

  Object? _extract(Object? decoded, String source) {
    if (parseKeyPath.isEmpty) return decoded;

    var node = decoded;
    for (final key in parseKeyPath.split('.')) {
      if (node is! Map<String, dynamic> || !node.containsKey(key)) {
        throw FormatException(
          'failed to get parse key path "$parseKeyPath": no "$key"',
          source,
        );
      }
      node = node[key];
    }
    return node;
  }
}
