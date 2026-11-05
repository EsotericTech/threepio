// Port of TestMessageJSONParser of eino `schema/message_parser_test.go`
// (v0.9.22).
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

class TestStructForParse {
  TestStructForParse(this.id, this.name);

  factory TestStructForParse.fromJson(Map<String, dynamic> json) =>
      TestStructForParse(json['id'] as int, json['name'] as String);

  final int id;
  final String name;
}

Message toolCallMessage(List<String> arguments) => Message.assistant(
      '',
      toolCalls: [
        for (final (index, argument) in arguments.indexed)
          ToolCall(
            id: 'call_$index',
            function: FunctionCall(name: 'f', arguments: argument),
          ),
      ],
    );

void main() {
  final ctx = RunContext.background();
  const json = '{"id": 1, "name": "test", "xx": {"yy": 2}}';

  test('parse from content', () async {
    final parser = MessageJsonParser<TestStructForParse>.object(
      fromJson: TestStructForParse.fromJson,
    );

    final parsed = await parser.parse(ctx, Message.assistant(json));

    expect(parsed.id, 1);
    expect(parsed.name, 'test');
  });

  group('parse from tool call', () {
    test('only one tool call, default use first tool call', () async {
      final parser = MessageJsonParser<TestStructForParse>.object(
        fromJson: TestStructForParse.fromJson,
        parseFrom: MessageParseFrom.toolCall,
      );

      final parsed = await parser.parse(ctx, toolCallMessage([json]));

      expect(parsed.id, 1);
    });

    test('parse key path', () async {
      final parser = MessageJsonParser<int>.object(
        fromJson: (json) => json['yy'] as int,
        parseFrom: MessageParseFrom.toolCall,
        parseKeyPath: 'xx',
      );

      expect(await parser.parse(ctx, toolCallMessage([json])), 2);
    });

    test('parse key path, deep level', () async {
      final parser = MessageJsonParser<int>.object(
        fromJson: (json) => json['zz'] as int,
        parseFrom: MessageParseFrom.toolCall,
        parseKeyPath: 'xx.yy',
      );

      final parsed = await parser.parse(
        ctx,
        toolCallMessage(['{"id": 1, "name": "test", "xx": {"yy": {"zz": 3}}}']),
      );

      expect(parsed, 3);
    });

    test('parse to a nullable value', () async {
      final parser = MessageJsonParser<int?>.object(
        fromJson: (json) => json['zz'] as int?,
        parseFrom: MessageParseFrom.toolCall,
      );

      expect(await parser.parse(ctx, toolCallMessage(['{"zz": 3}'])), 3);
      expect(await parser.parse(ctx, toolCallMessage(['{}'])), isNull);
    });

    test('no tool call is an error', () async {
      final parser = MessageJsonParser<TestStructForParse>.object(
        fromJson: TestStructForParse.fromJson,
        parseFrom: MessageParseFrom.toolCall,
      );

      await expectLater(
        parser.parse(ctx, Message.assistant(json)),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', 'no tool call found'),
        ),
      );
    });
  });

  group('parse of slice', () {
    final parser = MessageJsonParser<List<Map<String, dynamic>>>(
      fromJson: (json) => (json! as List<dynamic>).cast<Map<String, dynamic>>(),
      parseFrom: MessageParseFrom.toolCall,
    );

    test('valid slice string, not multiple tool calls', () async {
      final parsed = await parser.parse(
        ctx,
        toolCallMessage(['[{"id": 1}, {"id": 2}]']),
      );

      expect(parsed, hasLength(2));
      expect(parsed[1]['id'], 2);
    });

    test('invalid slice string, not multiple tool calls', () async {
      await expectLater(
        parser.parse(ctx, toolCallMessage(['{"id": 1}', '{"id": 2}'])),
        throwsFormatException,
      );
    });
  });

  test('the default source is the content, and empty content is an error',
      () async {
    final parser = MessageJsonParser<TestStructForParse>.object(
      fromJson: TestStructForParse.fromJson,
    );

    expect(parser.parseFrom, MessageParseFrom.content);
    expect(parser.parseKeyPath, isEmpty);
    await expectLater(
      parser.parse(ctx, Message.assistant('')),
      throwsFormatException,
    );
  });

  test('invalid parse key path', () async {
    final parser = MessageJsonParser<TestStructForParse>.object(
      fromJson: TestStructForParse.fromJson,
      parseKeyPath: '...invalid',
    );

    await expectLater(
      parser.parse(ctx, Message.assistant(json)),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('failed to get parse key path'),
        ),
      ),
    );
    await expectLater(
      MessageJsonParser<TestStructForParse>.object(
        fromJson: TestStructForParse.fromJson,
        parseKeyPath: 'xx.missing',
      ).parse(ctx, Message.assistant(json)),
      throwsFormatException,
    );
  });

  test('JSON of the wrong shape is a FormatException', () async {
    final objectParser = MessageJsonParser<TestStructForParse>.object(
      fromJson: TestStructForParse.fromJson,
    );

    // Not an object at all.
    await expectLater(
      objectParser.parse(ctx, Message.assistant('[1, 2]')),
      throwsA(
        isA<FormatException>()
            .having((e) => e.message, 'message', contains('JSON object')),
      ),
    );
    // An object whose fields have the wrong types: fromJson fails to cast.
    await expectLater(
      objectParser.parse(ctx, Message.assistant('{"id": "one", "name": 2}')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('failed to unmarshal content'),
        ),
      ),
    );
    // Not JSON.
    await expectLater(
      objectParser.parse(ctx, Message.assistant('not json')),
      throwsFormatException,
    );
  });

  test('a parser is a MessageParser and can parse scalars', () async {
    final MessageParser<int> parser =
        MessageJsonParser<int>(fromJson: (json) => json! as int);

    expect(await parser.parse(ctx, Message.assistant('42')), 42);
  });
}
