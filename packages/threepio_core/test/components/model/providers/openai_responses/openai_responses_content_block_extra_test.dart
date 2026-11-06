// Port of eino-ext components/model/agenticopenai/
// responses_content_block_extra_test.go (TestSetItemID, TestGetItemID,
// TestSetItemStatus, TestGetItemStatus, TestSetBlockExtraValue,
// TestGetBlockExtraValue, TestConcatFirstNonZero, TestConcatLast), plus the
// message extras of responses_message_extra.go, which have no Go test.
//
// Not ported: the "nil block should not panic" cases of TestSetItemID,
// TestSetItemStatus, TestSetBlockExtraValue and TestGetBlockExtraValue —
// a ContentBlock is never null here (the setters return a copy of a
// non-null block). Go's setters mutate the block; here they return a copy.
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_block_extra.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_model.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_register.dart';

ContentBlock _text([Map<String, Object?>? extra]) =>
    ContentBlock(const AssistantGenText(text: 't'), extra: extra);

void main() {
  group('TestSetItemID', () {
    test('set value into Extra', () {
      final block = withItemId(_text(), 'id-1');
      expect(block.extra![itemIdKey], const OpenAIResponsesItemId('id-1'));
    });
  });

  group('TestGetItemID', () {
    test('found', () {
      final block = _text({itemIdKey: const OpenAIResponsesItemId('id-2')});
      expect(itemIdOf(block), 'id-2');
    });

    test('found as a plain string (after a JSON round trip)', () {
      expect(itemIdOf(_text({itemIdKey: 'id-3'})), 'id-3');
    });

    test('not found', () {
      expect(itemIdOf(_text({})), isNull);
      expect(itemIdOf(_text()), isNull);
    });
  });

  group('TestSetItemStatus', () {
    test('set value into Extra', () {
      final block = withItemStatus(_text(), 'in_progress');
      expect(
        block.extra![itemStatusKey],
        const OpenAIResponsesItemStatus('in_progress'),
      );
    });
  });

  group('TestGetItemStatus', () {
    test('found', () {
      final block =
          _text({itemStatusKey: const OpenAIResponsesItemStatus('completed')});
      expect(itemStatusOf(block), 'completed');
      expect(OpenAIResponsesModel.itemStatus(block), 'completed');
    });

    test('not found', () {
      expect(itemStatusOf(_text({})), isNull);
      expect(OpenAIResponsesModel.itemStatus(_text()), isNull);
    });
  });

  group('TestSetBlockExtraValue', () {
    test('init Extra map when nil', () {
      final block = withBlockExtraValue(_text(), 'k', 123);
      expect(block.extra!['k'], 123);
    });

    test('keeps the other entries', () {
      final block = withBlockExtraValue(_text({'a': 1}), 'k', 2);
      expect(block.extra, {'a': 1, 'k': 2});
    });
  });

  group('TestGetBlockExtraValue', () {
    test('missing extra', () {
      expect(blockExtraValue<int>(null, 'k'), isNull);
      expect(blockExtraValue<int>(_text(), 'k'), isNull);
    });

    test('type mismatch', () {
      expect(blockExtraValue<int>(_text({'k': 'v'}), 'k'), isNull);
    });
  });

  group('TestConcatFirstNonZero', () {
    test('pick first non-zero', () {
      expect(
        concatItemIds(const [OpenAIResponsesItemId(''), OpenAIResponsesItemId('id')]),
        const OpenAIResponsesItemId('id'),
      );
    });

    test('all zero', () {
      expect(
        concatItemIds(const [OpenAIResponsesItemId(''), OpenAIResponsesItemId('')]),
        const OpenAIResponsesItemId(''),
      );
    });
  });

  group('TestConcatLast', () {
    test('non-empty', () {
      expect(
        concatItemStatuses(
          const [OpenAIResponsesItemStatus('a'), OpenAIResponsesItemStatus('b')],
        ),
        const OpenAIResponsesItemStatus('b'),
      );
    });

    test('empty', () {
      expect(concatItemStatuses(const []), const OpenAIResponsesItemStatus(''));
    });
  });

  group('namespace and tool search marker', () {
    test('round trip', () {
      var block = withNamespace(_text(), 'ns');
      expect(namespaceOf(block), 'ns');
      expect(isToolSearchToolCall(block), isFalse);
      block = withToolSearchToolCall(block);
      expect(isToolSearchToolCall(block), isTrue);
      expect(OpenAIResponsesModel.isToolSearchToolCall(block), isTrue);
    });
  });

  group('registered concat of block extras', () {
    setUp(ensureOpenAIResponsesTypesRegistered);

    test('item ids join to the first non-empty one, statuses to the last',
        () {
      final chunks = [
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            withItemStatus(
              withItemId(
                ContentBlock(
                  const AssistantGenText(text: 'Hel'),
                  streamingMeta: const StreamingMeta(index: 0),
                ),
                'msg_1',
              ),
              'in_progress',
            ),
          ],
        ),
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            withItemStatus(
              withItemId(
                ContentBlock(
                  const AssistantGenText(text: 'lo'),
                  streamingMeta: const StreamingMeta(index: 0),
                ),
                'msg_1',
              ),
              'completed',
            ),
          ],
        ),
      ];
      final joined = concatAgenticMessages(chunks);
      final block = joined.contentBlocks.single;
      expect(block.assistantGenText!.text, 'Hello');
      expect(itemIdOf(block), 'msg_1');
      expect(itemStatusOf(block), 'completed');
    });

    test('the wrapper types survive a JSON round trip of the message', () {
      final message = AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          withItemStatus(withItemId(_text(), 'msg_1'), 'completed'),
        ],
      );
      final back = AgenticMessage.fromJson(message.toJson());
      expect(back.contentBlocks.single.extra![itemIdKey],
          const OpenAIResponsesItemId('msg_1'));
      expect(itemStatusOf(back.contentBlocks.single), 'completed');
    });
  });

  group('message extras (responses_message_extra.go)', () {
    test('whitelist of blocks of other models', () {
      expect(
        isAllowedNonSelfGeneratedBlockType(ContentBlockType.functionToolCall),
        isTrue,
      );
      expect(
        isAllowedNonSelfGeneratedBlockType(ContentBlockType.reasoning),
        isFalse,
      );
      expect(
        isAllowedNonSelfGeneratedBlockType(ContentBlockType.serverToolCall),
        isFalse,
      );
    });

    test('isSelfGeneratedMessage', () {
      expect(isSelfGeneratedMessage(null), isFalse);
      expect(
        isSelfGeneratedMessage(AgenticMessage(role: AgenticRoleType.assistant)),
        isFalse,
      );
      expect(
        isSelfGeneratedMessage(
          AgenticMessage(
            role: AgenticRoleType.assistant,
            responseMeta: const AgenticResponseMeta(
              openAIExtension: OpenAIResponseMetaExtension(),
            ),
          ),
        ),
        isTrue,
      );
    });

    test('auto-cache marker and InvalidateMessageCaches', () {
      final marked = withAutoCached(
        AgenticMessage(role: AgenticRoleType.assistant, extra: const {'k': 1}),
      );
      expect(isAutoCached(marked), isTrue);
      expect(marked.extra, {'k': 1, autoCachedKey: true});

      final plain = AgenticMessage.user('hi');
      final invalidated =
          OpenAIResponsesModel.invalidateMessageCaches([marked, plain]);
      expect(isAutoCached(invalidated[0]), isFalse);
      expect(invalidated[0].extra, {'k': 1});
      expect(identical(invalidated[1], plain), isTrue);
      // The input is not changed.
      expect(isAutoCached(marked), isTrue);
    });
  });
}
