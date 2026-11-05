// `MessageConcatenator.concat` keeps the tolerance it had before the port of
// eino `schema.ConcatMessages`; `concatMessages` is the strict port. Kortney
// assembles provider streams through the former.
import 'package:test/test.dart';
import 'package:threepio_core/src/schema/concat.dart' show concatMaps;
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

ToolCall _call(
  int? index, {
  String id = '',
  String type = 'function',
  String name = '',
  String args = '',
}) =>
    ToolCall(
      id: id,
      type: type,
      function: FunctionCall(name: name, arguments: args),
      index: index,
    );

void main() {
  group('fragments of one tool call that disagree', () {
    final differentIds = [
      _delta(toolCalls: [_call(0, id: 'call_a', name: 'get_clip', args: '{"pos')]),
      _delta(toolCalls: [_call(0, id: 'call_b', args: 'ition": 1}')]),
    ];
    final differentNames = [
      _delta(toolCalls: [_call(0, id: 'call_a', name: 'get_clip', args: '{')]),
      _delta(toolCalls: [_call(0, name: 'get_clips', args: '}')]),
    ];
    final differentTypes = [
      _delta(toolCalls: [_call(0, id: 'call_a', name: 'get_clip', args: '{')]),
      _delta(toolCalls: [_call(0, type: 'custom', args: '}')]),
    ];

    test('the legacy method keeps the first id', () {
      final merged = MessageConcatenator.concat(differentIds);

      final call = merged.toolCalls!.single;
      expect(call.id, 'call_a');
      expect(call.function.name, 'get_clip');
      expect(call.function.arguments, '{"position": 1}');
      expect(call.index, 0);
    });

    test('the legacy method keeps the first name', () {
      final call = MessageConcatenator.concat(differentNames).toolCalls!.single;

      expect(call.function.name, 'get_clip');
      expect(call.function.arguments, '{}');
    });

    test('the legacy method keeps the first type', () {
      final call = MessageConcatenator.concat(differentTypes).toolCalls!.single;

      expect(call.type, 'function');
      expect(call.function.arguments, '{}');
    });

    test('the legacy method takes a value from the first fragment that has '
        'one', () {
      final merged = MessageConcatenator.concat([
        _delta(toolCalls: [_call(0, args: '{"a"')]),
        _delta(toolCalls: [_call(0, id: 'late_id', name: 'late_name', args: ':1')]),
        _delta(toolCalls: [_call(0, id: 'later_id', name: 'later_name', args: '}')]),
      ]);

      final call = merged.toolCalls!.single;
      expect(call.id, 'late_id');
      expect(call.function.name, 'late_name');
      expect(call.function.arguments, '{"a":1}');
    });

    test('the strict function throws for each of them', () {
      expect(
        () => concatMessages(differentIds),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('cannot concat ToolCalls with different tool id'),
          ),
        ),
      );
      expect(
        () => concatMessages(differentNames),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('cannot concat ToolCalls with different tool name'),
          ),
        ),
      );
      expect(
        () => concatMessages(differentTypes),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('cannot concat ToolCalls with different tool type'),
          ),
        ),
      );
    });

    test('several calls are kept apart by their index', () {
      final merged = MessageConcatenator.concat([
        _delta(toolCalls: [_call(0, id: 'a', name: 'first', args: '{')]),
        _delta(toolCalls: [_call(1, id: 'b', name: 'second', args: '[')]),
        _delta(toolCalls: [_call(0, id: 'a2', args: '}')]),
        _delta(toolCalls: [_call(1, id: 'b2', name: 'other', args: ']')]),
      ]);

      expect(merged.toolCalls!.map((c) => c.id), ['a', 'b']);
      expect(merged.toolCalls!.map((c) => c.function.name), ['first', 'second']);
      expect(merged.toolCalls!.map((c) => c.function.arguments), ['{}', '[]']);
    });
  });

  group('extra values that cannot be joined', () {
    final mixedTypes = [
      _delta(content: 'a', extra: {'provider': 'alpha', 'attempt': 1}),
      _delta(content: 'b', extra: {'provider': 7, 'attempt': 2}),
    ];

    test('the legacy method keeps the last one', () {
      final merged = MessageConcatenator.concat(mixedTypes);

      expect(merged.content, 'ab');
      expect(merged.extra, {'provider': 7, 'attempt': 2});
    });

    test('the strict function throws', () {
      expect(
        () => concatMessages(mixedTypes),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('failed to concat extra')),
        ),
      );
    });

    test('the legacy method resolves a conflict inside a nested map there',
        () {
      final merged = MessageConcatenator.concat([
        _delta(
          extra: {
            'meta': {'id': 'x', 'tag': 'one', 'kept': true},
          },
        ),
        _delta(
          extra: {
            'meta': {'id': 5, 'tag': 'two'},
          },
        ),
      ]);

      expect(merged.extra, {
        // `id` cannot be joined: last wins. `tag` can: strings concatenate.
        'meta': {'id': 5, 'tag': 'onetwo', 'kept': true},
      });
    });

    test('a list next to something that is not a list: the last wins', () {
      final merged = MessageConcatenator.concat([
        _delta(
          extra: {
            'details': [1, 2],
          },
        ),
        _delta(extra: {'details': 'text'}),
      ]);

      expect(merged.extra, {'details': 'text'});
    });

    test('values that can be joined are joined by both', () {
      final chunks = [
        _delta(
          extra: {
            'reasoning_details': [
              {'text': 'The user'},
            ],
            'note': 'a',
            'count': 1,
          },
        ),
        _delta(
          extra: {
            'reasoning_details': [
              {'text': ' asks.'},
            ],
            'note': 'b',
            'count': 2,
          },
        ),
      ];
      const expected = {
        'reasoning_details': [
          {'text': 'The user'},
          {'text': ' asks.'},
        ],
        'note': 'ab',
        'count': 2,
      };

      expect(MessageConcatenator.concat(chunks).extra, expected);
      expect(concatMessages(chunks).extra, expected);
    });
  });

  group('consistent chunks', () {
    test('both entry points give the same message', () {
      const usage = TokenUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5);
      final chunks = [
        _delta(content: 'Hel', toolCalls: [_call(0, id: 'c1', name: 'f', args: '{"a"')]),
        const Message(role: RoleType.assistant, reasoningContent: 'thinking'),
        _delta(content: 'lo', toolCalls: [_call(0, args: ':1}')]),
        const Message(
          role: RoleType.assistant,
          responseMeta: ResponseMeta(finishReason: 'tool_calls', usage: usage),
        ),
      ];

      final lenient = MessageConcatenator.concat(chunks);
      expect(lenient, concatMessages(chunks));
      expect(lenient.content, 'Hello');
      expect(lenient.reasoningContent, 'thinking');
      expect(lenient.toolCalls!.single.function.arguments, '{"a":1}');
      expect(lenient.responseMeta?.finishReason, 'tool_calls');
      expect(lenient.responseMeta?.usage, usage);
    });

    test('a single chunk comes back equal', () {
      final chunk = _delta(content: 'only', extra: {'k': 'v'});

      expect(MessageConcatenator.concat([chunk]), chunk);
      expect(concatMessages([chunk]), chunk);
    });
  });

  group('what both still reject', () {
    test('an empty list', () {
      expect(() => MessageConcatenator.concat([]), throwsArgumentError);
      expect(() => concatMessages([]), throwsArgumentError);
    });

    test('chunks with different roles', () {
      final chunks = [Message.user('a'), Message.assistant('b')];

      expect(() => MessageConcatenator.concat(chunks), throwsArgumentError);
      expect(() => concatMessages(chunks), throwsArgumentError);
    });

    test('chunks with different names', () {
      final chunks = [
        const Message(role: RoleType.assistant, name: 'one'),
        const Message(role: RoleType.assistant, name: 'two'),
      ];

      expect(() => MessageConcatenator.concat(chunks), throwsArgumentError);
      expect(() => concatMessages(chunks), throwsArgumentError);
    });

    test('tool messages with different tool call ids or tool names', () {
      final differentIds = [
        Message.tool(content: 'a', toolCallId: 'c1'),
        Message.tool(content: 'b', toolCallId: 'c2'),
      ];
      final differentNames = [
        Message.tool(content: 'a', toolCallId: 'c1', toolName: 'x'),
        Message.tool(content: 'b', toolCallId: 'c1', toolName: 'y'),
      ];

      for (final chunks in [differentIds, differentNames]) {
        expect(() => MessageConcatenator.concat(chunks), throwsArgumentError);
        expect(() => concatMessages(chunks), throwsArgumentError);
      }
    });
  });

  group('concatMaps', () {
    test('throws on values it cannot join unless told to keep the last', () {
      final maps = [
        <String, Object?>{'a': 'text', 'b': 1},
        <String, Object?>{'a': 2, 'b': 2},
      ];

      expect(() => concatMaps(maps, appendLists: true), throwsStateError);
      expect(
        concatMaps(maps, appendLists: true, lastWinsOnConflict: true),
        {'a': 2, 'b': 2},
      );
    });

    test('keeping the last ignores a trailing null', () {
      expect(
        concatMaps(
          [
            <String, Object?>{'a': 'text'},
            <String, Object?>{'a': 2},
            <String, Object?>{'a': null},
          ],
          appendLists: true,
          lastWinsOnConflict: true,
        ),
        {'a': 2},
      );
    });

    test('two lists still conflict when lists are not appended', () {
      final maps = [
        <String, Object?>{
          'l': [1],
        },
        <String, Object?>{
          'l': [2],
        },
      ];

      expect(() => concatMaps(maps, appendLists: false), throwsStateError);
      expect(
        concatMaps(maps, appendLists: false, lastWinsOnConflict: true),
        {
          'l': [2],
        },
      );
    });
  });
}
