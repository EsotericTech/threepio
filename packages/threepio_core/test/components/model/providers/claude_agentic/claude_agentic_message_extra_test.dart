// Port of eino-ext components/model/agenticclaude/message_extra_test.go (all
// 4 tests: TestGetCacheCreationInputTokens,
// TestCacheCreationInputTokens_SetInConvOutputMessage,
// TestCacheCreationInputTokens_SetInStreamDelta,
// TestCacheCreationInputTokens_PreservedAfterConcat). Go's "nil message"
// case is impossible: the getter is an extension on a non-nullable
// AgenticMessage.
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_convertor.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_event_convertor.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_message_extra.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_utils.dart';
import 'package:threepio_core/threepio_core.dart';

void main() {
  group('TestGetCacheCreationInputTokens', () {
    test('nil Extra', () {
      expect(
        AgenticMessage(
          role: AgenticRoleType.assistant,
        ).claudeCacheCreationInputTokens,
        isNull,
      );
    });

    test('key not present', () {
      expect(
        AgenticMessage(
          role: AgenticRoleType.assistant,
          extra: {'other': 42},
        ).claudeCacheCreationInputTokens,
        isNull,
      );
    });

    test('key present with value', () {
      expect(
        AgenticMessage(
          role: AgenticRoleType.assistant,
          extra: {claudeAgenticKeyOfCacheCreationInputTokens: 1234},
        ).claudeCacheCreationInputTokens,
        1234,
      );
    });

    test('a value that is not an int', () {
      expect(
        AgenticMessage(
          role: AgenticRoleType.assistant,
          extra: {claudeAgenticKeyOfCacheCreationInputTokens: '1234'},
        ).claudeCacheCreationInputTokens,
        isNull,
      );
    });
  });

  group('TestCacheCreationInputTokens_SetInConvOutputMessage', () {
    Map<String, Object?> response(int cacheCreation) => {
      'id': 'msg_1',
      'type': 'message',
      'role': 'assistant',
      'content': <Object?>[],
      'usage': {
        'input_tokens': 100,
        'output_tokens': 50,
        'cache_creation_input_tokens': cacheCreation,
      },
    };

    test('zero cache creation does not set Extra', () {
      final msg = ClaudeAgenticBlockConverter().message(response(0));
      expect(msg.extra, isNull);
    });

    test('nonzero cache creation sets Extra', () {
      final msg = ClaudeAgenticBlockConverter().message(response(500));
      expect(msg.claudeCacheCreationInputTokens, 500);
    });
  });

  group('TestCacheCreationInputTokens_SetInStreamDelta', () {
    final sc = ClaudeAgenticStreamConverter();
    Map<String, Object?> delta(int cacheCreation) => {
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
      'usage': {
        'output_tokens': 42,
        'cache_creation_input_tokens': cacheCreation,
      },
    };

    test('delta with zero cache creation', () {
      expect(sc.convert(delta(0))!.extra, isNull);
    });

    test('delta with nonzero cache creation', () {
      expect(sc.convert(delta(300))!.claudeCacheCreationInputTokens, 300);
    });
  });

  test('TestCacheCreationInputTokens_PreservedAfterConcat', () {
    final usageChunk = ClaudeAgenticStreamConverter().convert({
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
      'usage': {'output_tokens': 42, 'cache_creation_input_tokens': 300},
    })!;
    final textChunk = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [ContentBlock(const AssistantGenText(text: 'hello'))],
    );
    final msg = concatAgenticMessages([usageChunk, textChunk]);
    expect(msg.claudeCacheCreationInputTokens, 300);
  });
}
