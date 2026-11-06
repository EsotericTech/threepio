// The agentic entries of the TypeRegistry and StreamConcat built-ins (Go
// registers `_eino_agentic_message(_slice)` in schema/serialization.go and
// ConcatAgenticMessages(Array) in schema/message.go init): how they resolve
// next to the classic Message entries, empty lists included, and how
// concatAgenticMessages reports a registered concat function that fails
// (Go wraps the error with %w).

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

@immutable
final class _Part {
  const _Part(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is _Part && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class _ProviderException extends ThreepioException {
  const _ProviderException(super.message);
}

ContentBlock _chunk(ContentBlockVariant content, {Map<String, Object?>? extra}) =>
    ContentBlock(
      content,
      streamingMeta: const StreamingMeta(index: 0),
      extra: extra,
    );

AgenticMessage _assistant(
  List<ContentBlock> blocks, {
  Map<String, Object?>? extra,
}) =>
    AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: blocks,
      extra: extra,
    );

/// The last cause in the chain of [error] (Go: `errors.Unwrap` to the end).
Object? _rootCause(ThreepioException error) {
  Object? cause = error;
  while (cause is ThreepioException && cause.cause != null) {
    cause = cause.cause;
  }
  return cause;
}

/// Encodes [value] and decodes it again through text JSON.
Object? _roundTrip(Object value) =>
    TypeRegistry.decode(jsonDecode(jsonEncode(TypeRegistry.encode(value))));

void main() {
  group('TypeRegistry: agentic and classic entries side by side', () {
    test('an empty List<AgenticMessage> is an agentic slice', () {
      final encoded =
          TypeRegistry.encode(<AgenticMessage>[])! as Map<String, Object?>;
      expect(encoded[r'$type'], '_eino_agentic_message_slice');
      expect(TypeRegistry.nameOf(<AgenticMessage>[]),
          '_eino_agentic_message_slice');
      final back = _roundTrip(<AgenticMessage>[]);
      expect(back, isA<List<AgenticMessage>>());
      expect(back, isEmpty);
    });

    test('classic lists resolve as before, an empty List<Never> included', () {
      expect(TypeRegistry.nameOf(<Message>[]), '_eino_message_slice');
      expect(TypeRegistry.nameOf([Message.user('a')]), '_eino_message_slice');
      // A List<Never> fits both slice entries; it keeps its classic name.
      expect(TypeRegistry.nameOf(<Never>[]), '_eino_message_slice');
      expect(TypeRegistry.nameOf(Message.user('a')), '_eino_message');
      // A plain list stays JSON.
      expect(TypeRegistry.nameOf(<Object?>[]), isNull);
      expect(TypeRegistry.encode(<Object?>[]), <Object?>[]);
    });

    test('agentic values have their own names and round trip', () {
      final message = AgenticMessage.user('x');
      expect(TypeRegistry.nameOf(message), '_eino_agentic_message');
      expect(_roundTrip(message), message);
      final list = [message, AgenticMessage.system('s')];
      expect(TypeRegistry.nameOf(list), '_eino_agentic_message_slice');
      expect(_roundTrip(list), list);
      expect(TypeRegistry.canEncode<AgenticMessage>(), isTrue);
      expect(TypeRegistry.canEncode<List<AgenticMessage>>(), isTrue);
    });
  });

  group('StreamConcat: agentic and classic entries side by side', () {
    test('resolves by static type', () {
      expect(StreamConcat.resolve<AgenticMessage>(), isNotNull);
      expect(StreamConcat.resolve<List<AgenticMessage>>(), isNotNull);
      final classic = StreamConcat.resolve<List<Message>>()!;
      expect(
        classic([
          [Message.assistant('a')],
          [Message.assistant('b')],
        ]).single.content,
        'ab',
      );
    });

    test('empty lists by value: agentic stay agentic, List<Never> classic',
        () {
      final agentic = StreamConcat.concatItems<Object>([
        <AgenticMessage>[],
        <AgenticMessage>[],
      ]);
      expect(agentic, isA<List<AgenticMessage>>());

      final never = StreamConcat.concatItems<Object>([
        <Never>[],
        <Never>[],
      ]);
      expect(never, isA<List<Message>>());
      expect(never, isNot(isA<List<AgenticMessage>>()));
    });

    test('messages by value', () {
      final classic = StreamConcat.concatItems<Object>([
        Message.assistant('a'),
        Message.assistant('b'),
      ]);
      expect((classic as Message).content, 'ab');

      final agentic = StreamConcat.concatItems<Object>([
        _assistant([_chunk(const AssistantGenText(text: 'a'))]),
        _assistant([_chunk(const AssistantGenText(text: 'b'))]),
      ]);
      expect(
        (agentic as AgenticMessage).contentBlocks.single.assistantGenText!.text,
        'ab',
      );
    });
  });

  group('a registered concat function that fails', () {
    setUp(() {
      StreamConcat.register<_Part>((parts) {
        if (parts.any((part) => part.value == 'bug')) {
          throw ArgumentError('a bug in the concat function');
        }
        throw const _ProviderException('cannot join these parts');
      });
    });
    tearDown(StreamConcat.reset);

    test('in a block payload: wrapped with the block type, cause kept', () {
      expect(
        () => concatAgenticMessages([
          _assistant([_chunk(const ServerToolCall(arguments: _Part('a')))]),
          _assistant([_chunk(const ServerToolCall(arguments: _Part('b')))]),
        ]),
        throwsA(
          isA<MessageConcatException>()
              .having(
                (e) => e.message,
                'message',
                "failed to concat 'server_tool_call' content blocks: "
                    'cannot join these parts',
              )
              .having(_rootCause, 'root cause', isA<_ProviderException>()),
        ),
      );
    });

    test('in the response meta extension: wrapped twice, as in Go', () {
      expect(
        () => concatAgenticMessages([
          AgenticMessage(
            role: AgenticRoleType.assistant,
            responseMeta: const AgenticResponseMeta(extension: _Part('a')),
          ),
          AgenticMessage(
            role: AgenticRoleType.assistant,
            responseMeta: const AgenticResponseMeta(extension: _Part('b')),
          ),
        ]),
        throwsA(
          isA<MessageConcatException>().having(
            (e) => e.message,
            'message',
            'failed to concat agentic response meta: failed to concat '
                'extensions: cannot join these parts',
          ),
        ),
      );
    });

    test('in block extras: wrapped as Go does', () {
      expect(
        () => concatAgenticMessages([
          _assistant([
            _chunk(
              const AssistantGenText(text: 'a'),
              extra: const {'p': _Part('a')},
            ),
          ]),
          _assistant([
            _chunk(
              const AssistantGenText(text: 'b'),
              extra: const {'p': _Part('b')},
            ),
          ]),
        ]),
        throwsA(
          isA<MessageConcatException>()
              .having(
                (e) => e.message,
                'message',
                'failed to concat content block extras: '
                    'cannot join these parts',
              )
              .having((e) => e.cause, 'cause', isA<_ProviderException>()),
        ),
      );
    });

    test('in message extras: the error as it is (Go does not wrap it)', () {
      expect(
        () => concatAgenticMessages([
          _assistant([], extra: const {'p': _Part('a')}),
          _assistant([], extra: const {'p': _Part('b')}),
        ]),
        throwsA(
          isA<MessageConcatException>()
              .having((e) => e.message, 'message', 'cannot join these parts')
              .having((e) => e.cause, 'cause', isA<_ProviderException>()),
        ),
      );
    });

    test('a programming error (an Error) is not wrapped', () {
      expect(
        () => concatAgenticMessages([
          _assistant([_chunk(const ServerToolResult(content: _Part('bug')))]),
          _assistant([_chunk(const ServerToolResult(content: _Part('x')))]),
        ]),
        throwsArgumentError,
      );
    });
  });
}
