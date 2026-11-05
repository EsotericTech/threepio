// Chunks that contradict each other are a problem of the data, reported as a
// `MessageConcatException`; calling a concat function wrongly stays an
// `ArgumentError`.
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

Message _delta({
  String content = '',
  List<ToolCall>? toolCalls,
  Map<String, dynamic>? extra,
}) =>
    Message(
      role: RoleType.assistant,
      content: content,
      toolCalls: toolCalls,
      extra: extra,
    );

ToolCall _call(int index, {String id = '', String name = '', String type = 'function'}) =>
    ToolCall(
      id: id,
      index: index,
      type: type,
      function: FunctionCall(name: name, arguments: ''),
    );

ToolOutputPart _image(String url) => ToolOutputPart(
      type: ToolPartType.image,
      image: ToolOutputImage(common: MessagePartCommon(url: url)),
    );

final _throwsConflict = throwsA(
  allOf(
    isA<MessageConcatException>(),
    isA<ThreepioException>(),
    isA<Exception>(),
    isNot(isA<ArgumentError>()),
    isNot(isA<Error>()),
  ),
);

void main() {
  group('MessageConcatException', () {
    test('is a ThreepioException with a message and an optional cause', () {
      final cause = StateError('inner');
      final exception = MessageConcatException('roles differ', cause: cause);

      expect(exception, isA<ThreepioException>());
      expect(exception.message, 'roles differ');
      expect(exception.cause, same(cause));
      expect('$exception', 'MessageConcatException: roles differ');
      expect(const MessageConcatException('x').cause, isNull);
      expect(
        ThreepioException.findCause<StateError>(exception),
        same(cause),
      );
    });

    test('is caught with everything else the framework reports', () {
      Object? caught;
      try {
        concatMessages([Message.user('a'), Message.assistant('b')]);
      } on ThreepioException catch (error) {
        caught = error;
      }
      expect(
        caught,
        isA<MessageConcatException>().having(
          (e) => e.message,
          'message',
          "cannot concat messages with different roles: 'user' 'assistant'",
        ),
      );
    });
  });

  group('concatMessages reports contradictions as MessageConcatException', () {
    test('different roles', () {
      expect(
        () => concatMessages([Message.user('a'), Message.assistant('b')]),
        _throwsConflict,
      );
    });

    test('different names', () {
      expect(
        () => concatMessages(const [
          Message(role: RoleType.assistant, name: 'one'),
          Message(role: RoleType.assistant, name: 'two'),
        ]),
        _throwsConflict,
      );
    });

    test('different tool call ids and tool names of a tool message', () {
      expect(
        () => concatMessages([
          Message.tool(content: 'a', toolCallId: 'c1'),
          Message.tool(content: 'b', toolCallId: 'c2'),
        ]),
        _throwsConflict,
      );
      expect(
        () => concatMessages([
          Message.tool(content: 'a', toolCallId: 'c1', toolName: 'x'),
          Message.tool(content: 'b', toolCallId: 'c1', toolName: 'y'),
        ]),
        _throwsConflict,
      );
    });

    test('fragments of one tool call that disagree', () {
      for (final fragments in [
        [_call(0, id: 'a'), _call(0, id: 'b')],
        [_call(0, name: 'a'), _call(0, name: 'b')],
        [_call(0, type: 'function'), _call(0, type: 'custom')],
      ]) {
        expect(
          () => concatMessages([
            for (final fragment in fragments) _delta(toolCalls: [fragment]),
          ]),
          _throwsConflict,
        );
      }
    });

    test('extra values that cannot be joined, with the reason as the cause',
        () {
      expect(
        () => concatMessages([
          _delta(extra: {'k': 'text'}),
          _delta(extra: {'k': 7}),
        ]),
        throwsA(
          isA<MessageConcatException>()
              .having((e) => e.message, 'message', startsWith('failed to concat extra'))
              .having((e) => e.cause, 'cause', isStateError),
        ),
      );
    });

    test('through a stream', () async {
      await expectLater(
        concatMessageStream(
          StreamReader.fromIterable([Message.user('a'), Message.assistant('b')]),
        ),
        _throwsConflict,
      );
    });

    test('through the stream concat registry', () {
      expect(
        () => StreamConcat.concatItems<Message>([
          Message.user('a'),
          Message.assistant('b'),
        ]),
        _throwsConflict,
      );
    });
  });

  test('concatMessageArray reports lists of different lengths', () {
    expect(
      () => concatMessageArray([
        [Message.user('a')],
        [Message.user('b'), Message.user('c')],
      ]),
      throwsA(
        isA<MessageConcatException>().having(
          (e) => e.message,
          'message',
          'unexpected array length. Got 2, expected 1',
        ),
      ),
    );
  });

  test('concatToolResults reports a part type that comes in two chunks', () {
    expect(
      () => concatToolResults([
        ToolResult([_image('https://x.dev/1.png')]),
        ToolResult([_image('https://x.dev/2.png')]),
      ]),
      throwsA(
        isA<MessageConcatException>().having(
          (e) => e.message,
          'message',
          contains('conflicting image parts found in chunk 0 and chunk 1'),
        ),
      ),
    );
  });

  group('what stays an ArgumentError', () {
    test('calling a concat function without any chunk', () async {
      expect(() => concatMessages([]), throwsArgumentError);
      expect(() => MessageConcatenator.concat([]), throwsArgumentError);
      await expectLater(
        concatMessageStream(StreamReader.fromIterable(const <Message>[])),
        throwsArgumentError,
      );
    });

    test('everything MessageConcatenator.concat rejects, as it always did', () {
      for (final chunks in [
        [Message.user('a'), Message.assistant('b')],
        const [
          Message(role: RoleType.assistant, name: 'one'),
          Message(role: RoleType.assistant, name: 'two'),
        ],
        [
          Message.tool(content: 'a', toolCallId: 'c1'),
          Message.tool(content: 'b', toolCallId: 'c2'),
        ],
      ]) {
        expect(
          () => MessageConcatenator.concat(chunks),
          throwsA(
            allOf(isA<ArgumentError>(), isNot(isA<MessageConcatException>())),
          ),
        );
      }
    });
  });
}
