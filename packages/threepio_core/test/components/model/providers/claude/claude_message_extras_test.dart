// Ports of eino-ext components/model/claude/message_extra_test.go:
//   TestConcatMessages, TestCacheCreationInputTokens,
//   TestConvOutputMessageCacheCreation, TestSetMessageCacheControl,
//   TestSetToolInfoCacheControl. TestGetCallbackOutputNoExtra is ported in
//   claude_chat_model_test.dart (it needs the callbacks).
// Not ported:
//   * TestSetMessageBreakpointOfClaude, TestSetToolInfoBreakpointOfClaude:
//     the deprecated SetMessageBreakpoint/SetToolInfoBreakpoint are not
//     ported; withClaudeCacheControl() without a control is their
//     replacement and is tested below ("with nil ctrl").
//   * TestCacheCreationInputTokens "nil message returns false": an extension
//     getter has no nil receiver; a message without extra is tested instead.
// Plus tests written for the port: the values survive a JSON round trip, and
// the tool search event types.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_config.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_converters.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_message_extras.dart';
import 'package:threepio_core/threepio_core.dart';

import 'claude_fixtures.dart';

void main() {
  test('TestConcatMessages', () {
    final message = concatMessages([
      const Message(
        role: RoleType.assistant,
        extra: {
          'key_of_string': 'hi!',
          'key_of_int': 10,
          claudeKeyOfThinking: 'how ',
        },
      ),
      const Message(
        role: RoleType.assistant,
        extra: {
          'key_of_string': 'hello!',
          'key_of_int': 50,
          claudeKeyOfThinking: 'are you',
        },
      ),
    ]);
    expect(message.extra!['key_of_string'], 'hi!hello!');
    expect(message.extra!['key_of_int'], 50);
    expect(message.claudeThinking, 'how are you');
  });

  group('TestCacheCreationInputTokens', () {
    test('set and get', () {
      final extra = <String, dynamic>{};
      claudeSetCacheCreationInputTokens(extra, 2048);
      final message = Message(role: RoleType.assistant, extra: extra);
      expect(message.claudeCacheCreationInputTokens, 2048);
    });

    test('zero value is not set', () {
      final extra = <String, dynamic>{};
      claudeSetCacheCreationInputTokens(extra, 0);
      expect(extra, isEmpty);
      expect(
        Message(role: RoleType.assistant, extra: extra)
            .claudeCacheCreationInputTokens,
        isNull,
      );
    });

    test('a message without extra has none', () {
      expect(Message.assistant('x').claudeCacheCreationInputTokens, isNull);
    });

    test('concat uses last value (streaming)', () {
      final message = concatMessages([
        const Message(
          role: RoleType.assistant,
          extra: {claudeKeyOfCacheCreationInputTokens: 2048},
        ),
        Message.assistant('hello'),
        Message.assistant(' world'),
      ]);
      expect(message.claudeCacheCreationInputTokens, 2048);
      expect(message.content, 'hello world');
    });
  });

  group('TestConvOutputMessageCacheCreation', () {
    test('sets cache_creation when present', () {
      final message = claudeOutputMessage(
        messageResponse(
          const [],
          usage: {
            'input_tokens': 100,
            'cache_read_input_tokens': 1024,
            'cache_creation_input_tokens': 2048,
            'output_tokens': 50,
          },
        ),
      );
      expect(message.claudeCacheCreationInputTokens, 2048);
      expect(
        message.responseMeta!.usage!.promptTokenDetails!.cachedTokens,
        1024,
      );
    });

    test('no Extra when no cache activity', () {
      final message = claudeOutputMessage(
        messageResponse(
          const [],
          usage: {'input_tokens': 100, 'output_tokens': 50},
        ),
      );
      expect(message.claudeCacheCreationInputTokens, isNull);
      expect(message.extra, isNull);
    });
  });

  group('TestSetMessageCacheControl', () {
    const message = Message(
      role: RoleType.system,
      content: 'test',
      extra: {'test': 'test'},
    );

    test('with TTL', () {
      final copy = message.withClaudeCacheControl(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
      );
      expect(message.extra, hasLength(1));
      expect(copy.extra, hasLength(3)); // test + breakpoint + ttl
      expect(claudeIsBreakpoint(copy.extra), isTrue);
      expect(
        claudeBreakpointCacheControl(copy.extra)!.ttl,
        ClaudeCacheTtl.oneHour,
      );
      expect(copy.content, 'test');
      expect(copy.role, RoleType.system);
    });

    test('with nil ctrl', () {
      final copy = message.withClaudeCacheControl();
      expect(copy.extra, hasLength(2)); // test + breakpoint
      expect(claudeIsBreakpoint(copy.extra), isTrue);
      expect(claudeBreakpointCacheControl(copy.extra), isNull);
    });

    test('with zero-value ctrl', () {
      final copy = message.withClaudeCacheControl(const ClaudeCacheControl());
      expect(copy.extra, hasLength(2));
      expect(claudeIsBreakpoint(copy.extra), isTrue);
      expect(claudeBreakpointCacheControl(copy.extra), isNull);
    });
  });

  group('TestSetToolInfoCacheControl', () {
    final tool = ToolInfo.function(name: 'test', description: 'test')
        .copyWith(extra: {'test': 'test'});

    test('with TTL', () {
      final copy = tool.withClaudeCacheControl(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.fiveMinutes),
      );
      expect(tool.extra, hasLength(1));
      expect(copy.extra, hasLength(3));
      expect(claudeIsBreakpoint(copy.extra), isTrue);
      expect(
        claudeBreakpointCacheControl(copy.extra)!.ttl,
        ClaudeCacheTtl.fiveMinutes,
      );
      expect(copy.name, 'test');
    });

    test('with nil ctrl', () {
      final copy = tool.withClaudeCacheControl();
      expect(copy.extra, hasLength(2));
      expect(claudeIsBreakpoint(copy.extra), isTrue);
      expect(claudeBreakpointCacheControl(copy.extra), isNull);
    });

    test('with zero-value ctrl', () {
      final copy = tool.withClaudeCacheControl(const ClaudeCacheControl());
      expect(copy.extra, hasLength(2));
      expect(claudeIsBreakpoint(copy.extra), isTrue);
      expect(claudeBreakpointCacheControl(copy.extra), isNull);
    });
  });

  group('JSON round trip (port)', () {
    test('thinking, signature, tokens, events and breakpoints survive', () {
      final message = claudeOutputMessage(
        messageResponse(
          [
            {'type': 'thinking', 'thinking': 'Hmm.', 'signature': 'sig'},
            {
              'type': 'server_tool_use',
              'id': 'srvtoolu_1',
              'name': 'tool_search_tool_bm25',
              'input': {'query': 'q'},
            },
            {
              'type': 'tool_search_tool_result',
              'tool_use_id': 'srvtoolu_1',
              'content': {
                'type': 'tool_search_tool_result_error',
                'error_code': 'too_many_requests',
                'error_message': 'slow down',
              },
            },
            textBlock('done'),
          ],
          usage: {
            'input_tokens': 1,
            'cache_creation_input_tokens': 7,
            'output_tokens': 1,
          },
        ),
      ).withClaudeCacheControl(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
      );

      final restored = Message.fromJson(
        (jsonDecode(jsonEncode(message.toJson())) as Map)
            .cast<String, dynamic>(),
      );

      expect(restored.claudeThinking, 'Hmm.');
      expect(claudeThinkingSignatureOf(restored.extra), 'sig');
      expect(restored.claudeCacheCreationInputTokens, 7);
      expect(claudeIsBreakpoint(restored.extra), isTrue);
      expect(
        claudeBreakpointCacheControl(restored.extra),
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
      );
      final events = restored.claudeToolSearchEvents;
      expect(events, hasLength(2));
      expect(events[0].type, ClaudeToolSearchEventType.serverToolUse);
      expect(events[0].id, 'srvtoolu_1');
      expect(events[0].name, 'tool_search_tool_bm25');
      expect(events[0].input, {'query': 'q'});
      expect(events[1].type, ClaudeToolSearchEventType.toolSearchToolResult);
      expect(events[1].toolUseId, 'srvtoolu_1');
      expect(events[1].content!.type, 'tool_search_tool_result_error');
      expect(events[1].content!.errorCode, 'too_many_requests');
      expect(events[1].content!.errorMessage, 'slow down');

      // And the restored message is sent back exactly like the original.
      expect(claudeMessageParam(restored), claudeMessageParam(message));
    });

    test('a token count that came back as a double is read', () {
      const message = Message(
        role: RoleType.assistant,
        extra: {claudeKeyOfCacheCreationInputTokens: 12.0},
      );
      expect(message.claudeCacheCreationInputTokens, 12);
    });
  });

  group('ClaudeToolSearchEvent (port)', () {
    test('toJson and fromJson are inverse', () {
      const events = [
        ClaudeToolSearchEvent(
          type: ClaudeToolSearchEventType.serverToolUse,
          id: 'a',
          name: 'tool_search_tool_regex',
          input: {'pattern': 'w.*'},
        ),
        ClaudeToolSearchEvent(
          type: ClaudeToolSearchEventType.toolSearchToolResult,
          toolUseId: 'a',
          content: ClaudeToolSearchEventContent(
            type: 'tool_search_tool_search_result',
            toolReferences: [
              ClaudeToolSearchEventToolReference('x'),
              ClaudeToolSearchEventToolReference('y'),
            ],
          ),
        ),
      ];
      for (final event in events) {
        final back = ClaudeToolSearchEvent.fromJson(event.toJson());
        expect(back.toJson(), event.toJson());
      }
      expect(
        events[1].content!.toolReferences,
        const [
          ClaudeToolSearchEventToolReference('x'),
          ClaudeToolSearchEventToolReference('y'),
        ],
      );
    });

    test('an unknown type is a format error, and is skipped by the getter', () {
      expect(
        () => ClaudeToolSearchEvent.fromJson(const {'type': 'nope'}),
        throwsA(isA<ThreepioFormatException>()),
      );
      const message = Message(
        role: RoleType.assistant,
        extra: {
          claudeKeyOfToolSearchEvents: [
            {'type': 'nope'},
            'not a map',
            {'type': 'tool_search_tool_result', 'tool_use_id': 'z'},
          ],
        },
      );
      final events = message.claudeToolSearchEvents;
      expect(events.single.toolUseId, 'z');
      expect(events.single.content, isNull);
    });

    test('value types compare by value', () {
      // The constructor is what is under test here.
      // ignore: use_named_constants
      expect(const ClaudeCacheTtl('1h'), ClaudeCacheTtl.oneHour);
      expect(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
        // ignore: use_named_constants
        const ClaudeCacheControl(ttl: ClaudeCacheTtl('1h')),
      );
      expect(
        const ClaudeThinkingConfig.enabled(budgetTokens: 10),
        const ClaudeThinkingEnabled(budgetTokens: 10),
      );
      expect(
        const ClaudeThinkingConfig.adaptive(),
        isNot(const ClaudeThinkingConfig.disabled()),
      );
      expect(
        const ClaudeThinkingConfig.adaptive(
          display: ClaudeThinkingDisplay.summarized,
        ).toJson(),
        {'type': 'adaptive', 'display': 'summarized'},
      );
      expect(
        const ClaudeThinkingConfig.disabled().toJson(),
        {'type': 'disabled'},
      );
      expect(
        const ClaudeResponseFormat(schema: {'type': 'object'}).toJson(),
        {
          'type': 'json_schema',
          'schema': {'type': 'object'},
        },
      );
      expect(ClaudeToolSearchAlgorithm.bm25.wireValue, 'bm25');
      expect(ClaudeToolSearchAlgorithm.regex.wireValue, 'regex');
    });
  });
}
