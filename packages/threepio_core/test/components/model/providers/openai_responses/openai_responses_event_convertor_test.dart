// Port of eino-ext components/model/agenticopenai/
// responses_event_convertor_test.go (every test function).
//
// Go mocks the `AsAny` of the SDK's event unions with mockey; here every
// event is its recorded JSON, whose `type` (and the item's `type`) select
// the variant. The callback sender sends messages to a pipe here (the
// callback outputs are made by AgenticModelCallCallbacks), so
// TestNewCallbackSender checks the writer and the auto-cache flag instead of
// Go's callback config.
import 'package:test/test.dart';
import 'package:threepio_core/components.dart' show ChatModelOptions;
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_block_extra.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_consts.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_event_convertor.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_exception.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_extension.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_register.dart';
import 'package:threepio_core/streaming.dart';

ResponsesStreamReceiver _receiver() =>
    ResponsesStreamReceiver(const ChatModelOptions());

Map<String, Object?> _added(int outputIndex, Map<String, Object?> item) => {
      'type': 'response.output_item.added',
      'output_index': outputIndex,
      'item': item,
    };

Map<String, Object?> _done(int outputIndex, Map<String, Object?> item) => {
      'type': 'response.output_item.done',
      'output_index': outputIndex,
      'item': item,
    };

final _throws = throwsA(isA<OpenAIResponsesException>());

void main() {
  setUpAll(ensureOpenAIResponsesTypesRegistered);

  test('TestNewStreamReceiverInit', () {
    final r = _receiver();
    expect(r.processingAssistantGenTextBlockIndex, isEmpty);
    expect(r.maxBlockIndex, -1);
    expect(r.indexMapper, isEmpty);
    expect(r.maxReasoningSummaryIndex, isEmpty);
    expect(r.reasoningSummaryIndexMapper, isEmpty);
    expect(r.textAnnotationIndexMapper, isEmpty);
    expect(r.maxTextAnnotationIndex, isEmpty);
  });

  test('TestGetBlockIndexAndReuse', () {
    final r = _receiver();
    final a = r.getBlockIndex('k1');
    final b = r.getBlockIndex('k2');
    final c = r.getBlockIndex('k1');
    expect(a, c);
    expect(a, isNot(b));
    expect(r.maxBlockIndex, greaterThanOrEqualTo(1));
  });

  test('TestGetReasoningSummaryIndex', () {
    final r = _receiver();
    expect(r.isNewReasoningSummaryIndex(1, 1), isTrue);
    expect(r.isNewReasoningSummaryIndex(1, 2), isTrue);
    expect(r.isNewReasoningSummaryIndex(2, 1), isTrue);
    expect(r.isNewReasoningSummaryIndex(1, 1), isFalse);
  });

  test('TestGetTextAnnotationIndex', () {
    final r = _receiver();
    final i1 = r.getTextAnnotationIndex(1, 1, 1);
    final i2 = r.getTextAnnotationIndex(1, 1, 2);
    final i3 = r.getTextAnnotationIndex(1, 2, 1);
    final i4 = r.getTextAnnotationIndex(2, 1, 1);
    final i5 = r.getTextAnnotationIndex(1, 1, 1);
    expect([i1, i2, i3, i4], [0, 1, 0, 0]);
    expect(i5, i1);
  });

  test('TestItemAddedEventToContentBlockFunctionToolCall', () {
    final blocks = _receiver().itemAddedEventToContentBlock(
      _added(1, {
        'type': 'function_call',
        'id': 'id1',
        'call_id': 'cid',
        'name': 'name',
      }),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.functionToolCall, isNotNull);
    expect(blocks.single.streamingMeta, isNotNull);
  });

  test('TestItemAddedEventToContentBlockIgnoredTypes', () {
    final r = _receiver();
    for (final type in [
      'message',
      'web_search_call',
      'mcp_list_tools',
      'mcp_approval_request',
      'mcp_call',
    ]) {
      expect(
        r.itemAddedEventToContentBlock(_added(1, {'type': type, 'id': 'x'})),
        isEmpty,
        reason: type,
      );
    }
  });

  test('TestItemDoneEventToContentBlocksOutputMessage', () {
    final r = _receiver();
    r.processingAssistantGenTextBlockIndex['mid'] = {0, 2};
    final blocks = r.itemDoneEventToContentBlocks(
      _done(1, {'type': 'message', 'id': 'mid', 'status': 'completed'}),
    );
    expect(blocks, hasLength(2));
    expect(itemIdOf(blocks[0]), 'mid');
  });

  test('TestItemDoneEventToContentBlocksReasoning', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(3, {'type': 'reasoning', 'id': 'rid', 'status': 'completed'}),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.reasoning, isNotNull);
  });

  test('TestItemDoneEventToContentBlocksFunctionToolCall', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(4, {
        'type': 'function_call',
        'id': 'fid',
        'call_id': 'cid',
        'name': 'nm',
        'arguments': '{"a":1}',
      }),
    );
    expect(blocks, hasLength(1));
    final call = blocks.single.functionToolCall!;
    expect(call.callId, 'cid');
    expect(call.name, 'nm');
    // The deltas carried the arguments already.
    expect(call.arguments, '');
  });

  test('TestItemDoneEventToContentBlocksWebSearch', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(5, {
        'type': 'web_search_call',
        'id': 'wid',
        'status': 'completed',
        'action': {'type': 'search', 'query': 'test'},
      }),
    );
    expect(blocks, hasLength(2));
    expect(blocks[0].serverToolCall, isNotNull);
    expect(blocks[1].serverToolResult, isNotNull);
    expect(blocks[0].streamingMeta!.index, isNot(blocks[1].streamingMeta!.index));
  });

  test('TestItemDoneEventToContentBlocksMCPCall', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(6, {
        'type': 'mcp_call',
        'id': 'mid',
        'server_label': 'server',
        'name': 'tool',
        'arguments': '{}',
        'output': 'result',
      }),
    );
    expect(blocks, hasLength(2));
    expect(blocks[0].mcpToolCall, isNotNull);
    expect(blocks[1].mcpToolResult, isNotNull);
  });

  test('TestItemDoneEventToContentBlocksMCPListTools', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(7, {'type': 'mcp_list_tools', 'id': 'lid', 'server_label': 'server'}),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.mcpListToolsResult, isNotNull);
  });

  test('TestItemDoneEventToContentBlocksMCPApprovalRequest', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(8, {
        'type': 'mcp_approval_request',
        'id': 'aid',
        'server_label': 'server',
        'name': 'tool',
        'arguments': '{}',
      }),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.mcpToolApprovalRequest, isNotNull);
  });

  test('TestItemDoneEventOutputMessageToContentBlockMissingProcessing', () {
    expect(
      () => _receiver().itemDoneEventOutputMessageToContentBlock({
        'id': 'mid',
        'status': 'completed',
      }),
      throwsA(
        isA<OpenAIResponsesException>().having(
          (e) => e.message,
          'message',
          contains('not found in processing queue'),
        ),
      ),
    );
  });

  test('TestItemDoneEventOutputMessageToContentBlockSuccess', () {
    final r = _receiver();
    r.processingAssistantGenTextBlockIndex['mid'] = {0, 2};
    final blocks = r.itemDoneEventOutputMessageToContentBlock({
      'id': 'mid',
      'status': 'completed',
    });
    expect(blocks, hasLength(2));
    expect(blocks.map((b) => b.streamingMeta!.index), [0, 2]);
    for (final block in blocks) {
      expect(itemIdOf(block), 'mid');
      expect(itemStatusOf(block), 'completed');
    }
  });

  test('TestContentPartAddedEventToContentBlockInvalidType', () {
    // Unknown content part types are ignored rather than failing the stream.
    expect(
      _receiver().contentPartAddedEventToContentBlock(
        {'type': 'response.content_part.added'},
      ),
      isNull,
    );
  });

  test('TestContentPartDoneEventToContentBlockInvalidType', () {
    expect(
      _receiver().contentPartDoneEventToContentBlock(
        {'type': 'response.content_part.done'},
      ),
      isNull,
    );
  });

  test('TestContentPartDoneEventToContentBlockNoIndex', () {
    expect(
      () => _receiver().contentPartDoneEventToContentBlock({
        'item_id': 'mid',
        'output_index': 1,
        'content_index': 2,
        'part': {'type': 'output_text', 'text': ''},
      }),
      throwsA(
        isA<OpenAIResponsesException>().having(
          (e) => e.message,
          'message',
          contains('has no processing assistant gen text block index'),
        ),
      ),
    );
  });

  test('TestRefusalDeltaEventToContentBlock', () {
    final block = _receiver().refusalDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 1,
      'content_index': 1,
      'delta': 'refused',
    });
    expect(
      block.assistantGenText!.openAIExtension!.refusal!.reason,
      'refused',
    );
    expect(itemIdOf(block), 'iid');
  });

  test('TestOutputTextDeltaEventToContentBlock', () {
    final block = _receiver().outputTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 1,
      'content_index': 1,
      'delta': 'delta text',
    });
    expect(block.assistantGenText!.text, 'delta text');
    expect(block.streamingMeta, isNotNull);
    expect(itemIdOf(block), 'iid');
  });

  test('TestAnnotationAddedEventToContentBlockFileCitation', () {
    final block = _receiver().annotationAddedEventToContentBlock({
      'item_id': 'iid',
      'output_index': 1,
      'content_index': 1,
      'annotation_index': 0,
      'annotation': {
        'type': 'file_citation',
        'index': 10,
        'file_id': 'fid',
        'filename': 'file.txt',
      },
    });
    final annotations = block.assistantGenText!.openAIExtension!.annotations;
    expect(annotations, hasLength(1));
    expect(annotations.single.index, 0);
    expect(annotations.single.fileCitation!.index, 10);
    expect(annotations.single.fileCitation!.fileId, 'fid');
  });

  test('an annotation of an unknown type fails the event', () {
    expect(
      () => _receiver().annotationAddedEventToContentBlock({
        'annotation': {'type': 'mystery'},
      }),
      _throws,
    );
  });

  test('TestReasoningSummaryTextDeltaEventToContentBlock', () {
    final block = _receiver().reasoningSummaryTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 2,
      'summary_index': 0,
      'delta': 'summary text',
    });
    expect(block.reasoning!.text, 'summary text');
    expect(itemIdOf(block), 'iid');
  });

  test('TestReasoningTextDeltaEventToContentBlock', () {
    final block = _receiver().reasoningTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 2,
      'content_index': 1,
      'delta': 'raw reasoning text',
    });
    // Raw reasoning text goes to the OpenAI extension, not the summary text.
    expect(block.reasoning!.text, '');
    final content = block.reasoning!.openAIExtension!.content;
    expect(content, hasLength(1));
    expect(content.single.text, 'raw reasoning text');
    expect(content.single.index, 1);
    expect(itemIdOf(block), 'iid');
  });

  test('TestReasoningTextDeltaEventContentIndexAndSharedBlockIndex', () {
    final r = _receiver();
    final b0 = r.reasoningTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 2,
      'content_index': 0,
      'delta': 'a',
    });
    final b1 = r.reasoningTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 2,
      'content_index': 1,
      'delta': 'b',
    });
    expect(b0.reasoning!.openAIExtension!.content.single.index, 0);
    expect(b1.reasoning!.openAIExtension!.content.single.index, 1);

    // A summary delta and a text delta of one output index share the block
    // index, so they join into one reasoning block.
    final summary = r.reasoningSummaryTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 2,
      'summary_index': 0,
      'delta': 's',
    });
    final raw0 = r.reasoningTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 2,
      'content_index': 0,
      'delta': 't0',
    });
    final raw1 = r.reasoningTextDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 2,
      'content_index': 1,
      'delta': 't1',
    });
    expect(raw0.streamingMeta!.index, summary.streamingMeta!.index);
    expect(raw1.streamingMeta!.index, summary.streamingMeta!.index);

    final got = concatAgenticMessages([
      for (final block in [summary, raw0, raw1])
        AgenticMessage(role: AgenticRoleType.assistant, contentBlocks: [block]),
    ]);
    expect(got.contentBlocks, hasLength(1));
    final reasoning = got.contentBlocks.single.reasoning!;
    expect(reasoning.text, 's');
    expect(reasoning.openAIExtension!.content.map((c) => c.text), ['t0', 't1']);
    expect(itemIdOf(got.contentBlocks.single), 'iid');
  });

  test('TestContentPartDoneEventToContentBlockRefusal', () {
    final r = _receiver();
    final index = r.getBlockIndex(makeAssistantGenTextIndexKey(1, 2));
    r.processingAssistantGenTextBlockIndex['iid'] = {index};
    final block = r.contentPartDoneEventToContentBlock({
      'item_id': 'iid',
      'output_index': 1,
      'content_index': 2,
      'part': {'type': 'refusal', 'refusal': ''},
    });
    expect(block!.assistantGenText, isNotNull);
    expect(r.processingAssistantGenTextBlockIndex['iid'], isEmpty);
  });

  test('TestContentPartAddedEventToContentBlockReasoningText', () {
    final block = _receiver().contentPartAddedEventToContentBlock({
      'item_id': 'iid',
      'output_index': 1,
      'content_index': 2,
      'part': {'type': 'reasoning_text', 'text': 'raw'},
    })!;
    final content = block.reasoning!.openAIExtension!.content;
    expect(content.single.text, 'raw');
    expect(content.single.index, 2);
    expect(itemIdOf(block), 'iid');
    expect(itemStatusOf(block), 'in_progress');
  });

  test('TestContentPartDoneEventToContentBlockReasoningText', () {
    final block = _receiver().contentPartDoneEventToContentBlock({
      'item_id': 'iid',
      'output_index': 1,
      'content_index': 2,
      'part': {'type': 'reasoning_text', 'text': 'raw'},
    })!;
    // The closing chunk carries no text; the deltas streamed it.
    expect(block.reasoning!.openAIExtension, isNull);
    expect(block.reasoning!.text, '');
    expect(itemStatusOf(block), 'completed');
  });

  test('TestFunctionCallArgumentsDeltaEventToContentBlock', () {
    final block = _receiver().functionCallArgumentsDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 3,
      'delta': '{"arg":"val"}',
    });
    expect(block.functionToolCall!.arguments, '{"arg":"val"}');
    expect(itemIdOf(block), 'iid');
  });

  test('TestMcpListToolsPhaseToContentBlock', () {
    final block =
        _receiver().mcpListToolsPhaseToContentBlock('iid', 4, 'in_progress');
    expect(block.mcpListToolsResult, isNotNull);
    expect(block.streamingMeta, isNotNull);
    expect(itemIdOf(block), 'iid');
    expect(itemStatusOf(block), 'in_progress');
  });

  test('TestMcpListToolsPhaseToContentBlockEmptyStatus', () {
    final block = _receiver().mcpListToolsPhaseToContentBlock('iid', 4, '');
    expect(block.mcpListToolsResult, isNotNull);
    expect(itemStatusOf(block), isNull);
  });

  test('TestMcpCallArgumentsDeltaEventToContentBlock', () {
    final block = _receiver().mcpCallArgumentsDeltaEventToContentBlock({
      'item_id': 'iid',
      'output_index': 6,
      'delta': '{"key":"value"}',
    });
    expect(block.mcpToolCall!.arguments, '{"key":"value"}');
    expect(itemIdOf(block), 'iid');
  });

  test('TestMcpCallPhaseToContentBlock', () {
    final block = _receiver().mcpCallPhaseToContentBlock('iid', 7, 'failed');
    expect(block.mcpToolCall, isNotNull);
    expect(itemStatusOf(block), 'failed');
  });

  test('TestWebSearchPhaseToContentBlock', () {
    final block =
        _receiver().webSearchPhaseToContentBlock('iid', 8, 'completed');
    expect(
      block.serverToolCall!.name,
      OpenAIResponsesServerToolName.webSearch.value,
    );
    expect(itemStatusOf(block), 'completed');
  });

  test('TestFileSearchPhaseToContentBlock', () {
    final block =
        _receiver().fileSearchPhaseToContentBlock('fsid', 9, 'in_progress');
    expect(
      block.serverToolCall!.name,
      OpenAIResponsesServerToolName.fileSearch.value,
    );
    expect(itemIdOf(block), 'fsid');
    expect(itemStatusOf(block), 'in_progress');
  });

  test('TestFileSearchPhaseToContentBlockEmptyStatus', () {
    final block = _receiver().fileSearchPhaseToContentBlock('fsid', 10, '');
    expect(
      block.serverToolCall!.name,
      OpenAIResponsesServerToolName.fileSearch.value,
    );
    expect(itemStatusOf(block), isNull);
  });

  test('TestItemDoneEventToContentBlocksFileSearch', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(11, {
        'type': 'file_search_call',
        'id': 'fsid',
        'status': 'completed',
        'queries': ['test query'],
        'results': [
          {
            'file_id': 'file1',
            'filename': 'doc.txt',
            'score': 0.85,
            'text': 'matched content',
          },
        ],
      }),
    );
    expect(blocks, hasLength(2));
    expect(
      blocks[0].serverToolCall!.name,
      OpenAIResponsesServerToolName.fileSearch.value,
    );
    expect(
      blocks[1].serverToolResult!.name,
      OpenAIResponsesServerToolName.fileSearch.value,
    );
  });

  test('TestItemAddedEventToContentBlockIgnoredFileSearch', () {
    expect(
      _receiver().itemAddedEventToContentBlock(
        _added(1, {'type': 'file_search_call', 'id': 'f'}),
      ),
      isEmpty,
    );
  });

  test('TestMakeIndexKeyFunctions', () {
    expect(makeAssistantGenTextIndexKey(1, 2), 'assistant_gen_text:1:2');
    expect(makeReasoningIndexKey(3), 'reasoning:3');
    expect(makeFunctionToolCallIndexKey(4), 'function_tool_call:4');
    expect(makeServerToolCallIndexKey(5), 'server_tool_call:5');
    expect(makeServerToolResultIndexKey(6), 'server_tool_result:6');
    expect(makeMcpListToolsResultIndexKey(7), 'mcp_list_tools_result:7');
    expect(
      makeMcpToolApprovalRequestIndexKey(8),
      'mcp_tool_approval_request:8',
    );
    expect(makeMcpToolCallIndexKey(9), 'mcp_tool_call:9');
    expect(makeMcpToolResultIndexKey(10), 'mcp_tool_result:10');
  });

  test('TestNewCallbackSender', () {
    final (_, writer) = pipe<AgenticMessage>(capacity: 8);
    final sender = ResponsesChunkSender(writer, enableAutoCache: false);
    expect(identical(sender.writer, writer), isTrue);
    expect(sender.enableAutoCache, isFalse);
  });

  test('TestCallbackSenderSendMeta', () async {
    final (reader, writer) = pipe<AgenticMessage>(capacity: 8);
    ResponsesChunkSender(writer, enableAutoCache: false)
        .sendMeta(const AgenticResponseMeta());
    final out = await reader.recv();
    expect(out.responseMeta, isNotNull);
    expect(out.contentBlocks, isEmpty);
  });

  test('TestCallbackSenderSendBlock', () async {
    final (reader, writer) = pipe<AgenticMessage>(capacity: 8);
    ResponsesChunkSender(writer, enableAutoCache: true)
        .sendBlock(ContentBlock(const AssistantGenText(text: 'test')));
    final out = await reader.recv();
    expect(out.contentBlocks, hasLength(1));
    expect(isAutoCached(out), isTrue);
  });

  test('TestCallbackSenderSendError', () async {
    final (reader, writer) = pipe<AgenticMessage>(capacity: 8);
    final sender = ResponsesChunkSender(writer, enableAutoCache: false)
      ..errHeader = 'test error';
    sender.sendMeta(null, StateError('error'));
    await expectLater(
      reader.recv(),
      throwsA(
        isA<OpenAIResponsesException>()
            .having((e) => e.message, 'message', contains('test error')),
      ),
    );
  });

  test('sendBlock sends nothing for no block and no error', () async {
    final (reader, writer) = pipe<AgenticMessage>(capacity: 8);
    ResponsesChunkSender(writer, enableAutoCache: false).sendBlock(null);
    await writer.close();
    expect(await reader.collectAll(), isEmpty);
  });

  test('TestItemDoneEventToContentBlocksToolSearchCall', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(9, {
        'type': 'tool_search_call',
        'id': 'tsid',
        'call_id': 'call1',
        'status': 'completed',
        'execution': 'server',
        'arguments': {'query': 'find tools'},
      }),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.serverToolCall, isNotNull);
  });

  test('TestItemDoneEventToContentBlocksToolSearchOutputItem', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(10, {
        'type': 'tool_search_output',
        'id': 'tsoid',
        'call_id': 'call1',
        'status': 'completed',
        'tools': [
          {
            'type': 'function',
            'name': 'tool1',
            'description': 'desc1',
            'parameters': {'type': 'object'},
          },
        ],
      }),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.serverToolResult, isNotNull);
  });

  test('TestItemDoneEventToolSearchCallToContentBlocksStreamingMeta', () {
    final block = _receiver().itemDoneEventToolSearchCallToContentBlocks(0, {
      'id': 'tsid',
      'call_id': 'call1',
      'status': 'completed',
      'execution': 'server',
      'arguments': {'query': 'find tools'},
    });
    expect(block.streamingMeta, isNotNull);
  });

  test('TestItemDoneEventToolSearchOutputItemToContentBlocksStreamingMeta', () {
    final block =
        _receiver().itemDoneEventToolSearchOutputItemToContentBlocks(0, {
      'id': 'tsoid',
      'call_id': 'call1',
      'status': 'completed',
      'tools': [
        {
          'type': 'function',
          'name': 'tool1',
          'parameters': {'type': 'object'},
        },
      ],
    });
    expect(block.streamingMeta, isNotNull);
  });

  test('TestMcpListToolsPhaseToContentBlockWithCache', () {
    final r = _receiver();
    r.itemAddedEventCache[makeMcpListToolsItemAddedEventCacheKey('iid', 4)] = {
      'id': 'iid',
      'server_label': 'srv',
    };
    final block = r.mcpListToolsPhaseToContentBlock('iid', 4, 'in_progress');
    expect(block.mcpListToolsResult!.serverLabel, 'srv');
  });

  test('TestMcpCallPhaseToContentBlockWithCache', () {
    final r = _receiver();
    r.itemAddedEventCache[makeMcpToolCallItemAddedEventCacheKey('iid', 7)] = {
      'id': 'iid',
      'server_label': 'srv',
      'name': 'tool_name',
      'approval_request_id': 'ar1',
    };
    final block = r.mcpCallPhaseToContentBlock('iid', 7, 'in_progress');
    expect(block.mcpToolCall!.serverLabel, 'srv');
    expect(block.mcpToolCall!.name, 'tool_name');
    expect(block.mcpToolCall!.approvalRequestId, 'ar1');
  });

  test('TestWebSearchPhaseToContentBlockEmptyStatus', () {
    final block = _receiver().webSearchPhaseToContentBlock('iid', 8, '');
    expect(
      block.serverToolCall!.name,
      OpenAIResponsesServerToolName.webSearch.value,
    );
    expect(itemStatusOf(block), isNull);
  });

  test('TestMcpCallPhaseToContentBlockEmptyStatus', () {
    final block = _receiver().mcpCallPhaseToContentBlock('iid', 7, '');
    expect(block.mcpToolCall, isNotNull);
    expect(itemStatusOf(block), isNull);
  });

  test('TestReasoningSummaryTextDeltaEventNewlinePrepend', () {
    final r = _receiver();
    Map<String, Object?> delta(int summaryIndex, String text) => {
          'item_id': 'iid',
          'output_index': 2,
          'summary_index': summaryIndex,
          'delta': text,
        };
    expect(
      r.reasoningSummaryTextDeltaEventToContentBlock(delta(0, 'first'))
          .reasoning!
          .text,
      'first',
    );
    expect(
      r.reasoningSummaryTextDeltaEventToContentBlock(delta(1, 'second'))
          .reasoning!
          .text,
      '\nsecond',
    );
    expect(
      r.reasoningSummaryTextDeltaEventToContentBlock(delta(1, 'more'))
          .reasoning!
          .text,
      'more',
    );
  });

  test('TestItemAddedEventToContentBlockReasoning', () {
    final blocks = _receiver().itemAddedEventToContentBlock(
      _added(1, {'type': 'reasoning', 'id': 'rid', 'status': 'in_progress'}),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.reasoning, isNotNull);
    expect(blocks.single.streamingMeta, isNotNull);
  });

  test('TestItemAddedEventToContentBlockMcpCallCaching', () {
    final r = _receiver();
    final blocks = r.itemAddedEventToContentBlock(
      _added(2, {
        'type': 'mcp_call',
        'id': 'mcpid',
        'server_label': 'srv',
        'name': 'tool',
      }),
    );
    expect(blocks, isEmpty);
    final cached =
        r.itemAddedEventCache[makeMcpToolCallItemAddedEventCacheKey('mcpid', 2)];
    expect(cached!['server_label'], 'srv');
  });

  test('TestItemAddedEventToContentBlockMcpListToolsCaching', () {
    final r = _receiver();
    final blocks = r.itemAddedEventToContentBlock(
      _added(3, {'type': 'mcp_list_tools', 'id': 'listid', 'server_label': 'srv'}),
    );
    expect(blocks, isEmpty);
    final cached = r.itemAddedEventCache[
        makeMcpListToolsItemAddedEventCacheKey('listid', 3)];
    expect(cached!['server_label'], 'srv');
  });

  test('TestCodeInterpreterPhaseToContentBlock', () {
    final block =
        _receiver().codeInterpreterPhaseToContentBlock('ciid', 9, 'in_progress');
    expect(
      block.serverToolResult!.name,
      OpenAIResponsesServerToolName.codeInterpreter.value,
    );
    expect(itemIdOf(block), 'ciid');
    expect(itemStatusOf(block), 'in_progress');
  });

  test('TestCodeInterpreterPhaseToContentBlockEmptyStatus', () {
    final block = _receiver().codeInterpreterPhaseToContentBlock('ciid', 10, '');
    expect(
      block.serverToolResult!.name,
      OpenAIResponsesServerToolName.codeInterpreter.value,
    );
    expect(itemStatusOf(block), isNull);
  });

  test('TestCodeInterpreterCodeDeltaEventToContentBlock', () {
    final block = _receiver().codeInterpreterCodeDeltaEventToContentBlock({
      'item_id': 'ciid',
      'output_index': 12,
      'delta': "print('hello",
    });
    expect(
      block.serverToolResult!.name,
      OpenAIResponsesServerToolName.codeInterpreter.value,
    );
    final result =
        block.serverToolResult!.content! as OpenAIResponsesServerToolResult;
    expect(result.codeInterpreter!.code, "print('hello");
    expect(itemIdOf(block), 'ciid');
  });

  test('TestItemDoneEventCodeInterpreterToContentBlocks', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(13, {
        'type': 'code_interpreter_call',
        'id': 'ciid',
        'status': 'completed',
        'code': 'x = 1 + 1\nprint(x)',
        'container_id': 'container123',
        'outputs': <Object?>[],
      }),
    );
    expect(blocks, hasLength(2));
    expect(
      blocks[0].serverToolCall!.name,
      OpenAIResponsesServerToolName.codeInterpreter.value,
    );
    expect(
      blocks[1].serverToolResult!.name,
      OpenAIResponsesServerToolName.codeInterpreter.value,
    );
  });

  test('TestItemAddedEventToContentBlockCodeInterpreter', () {
    final blocks = _receiver().itemAddedEventToContentBlock(
      _added(1, {
        'type': 'code_interpreter_call',
        'id': 'ci1',
        'code': "print('hello')",
        'container_id': 'container123',
        'status': 'in_progress',
        'outputs': [
          {'type': 'logs', 'logs': 'hello'},
        ],
      }),
    );
    expect(blocks, hasLength(2));
    expect(blocks[0].serverToolCall, isNotNull);
    expect(blocks[1].serverToolResult, isNotNull);
  });

  test('TestImageGenerationPhaseToContentBlock', () {
    final block =
        _receiver().imageGenerationPhaseToContentBlock('igid', 14, 'in_progress');
    expect(
      block.serverToolResult!.name,
      OpenAIResponsesServerToolName.imageGeneration.value,
    );
    expect(itemIdOf(block), 'igid');
    expect(itemStatusOf(block), 'in_progress');
  });

  test('TestImageGenerationPartialImageEventToContentBlock', () {
    final block = _receiver().imageGenerationPartialImageEventToContentBlock({
      'item_id': 'igid',
      'output_index': 15,
      'partial_image_b64': 'partial_base64_data',
    });
    final result =
        block.serverToolResult!.content! as OpenAIResponsesServerToolResult;
    expect(result.imageGeneration!.imageBase64, 'partial_base64_data');
    expect(itemIdOf(block), 'igid');
  });

  test('TestItemDoneEventImageGenerationToContentBlocks', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(16, {
        'type': 'image_generation_call',
        'id': 'igid',
        'status': 'completed',
        'result': 'full_base64_image',
      }),
    );
    expect(blocks, hasLength(2));
    expect(
      blocks[0].serverToolCall!.name,
      OpenAIResponsesServerToolName.imageGeneration.value,
    );
    expect(
      blocks[1].serverToolResult!.name,
      OpenAIResponsesServerToolName.imageGeneration.value,
    );
  });

  test('TestItemAddedEventToContentBlockIgnoredImageGeneration', () {
    expect(
      _receiver().itemAddedEventToContentBlock(
        _added(1, {'type': 'image_generation_call', 'id': 'i'}),
      ),
      isEmpty,
    );
  });

  test('TestItemDoneEventShellCallToContentBlock', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(20, {
        'type': 'shell_call',
        'id': 'shell1',
        'status': 'completed',
        'action': {
          'commands': ['ls'],
        },
        'environment': {'type': 'local'},
      }),
    );
    expect(blocks, hasLength(1));
    expect(
      blocks.single.serverToolCall!.name,
      OpenAIResponsesServerToolName.shell.value,
    );
  });

  test('TestItemDoneEventShellOutputToContentBlock', () {
    final blocks = _receiver().itemDoneEventToContentBlocks(
      _done(21, {
        'type': 'shell_call_output',
        'id': 'shell_out1',
        'status': 'completed',
        'output': [
          {
            'stdout': 'output',
            'outcome': {'type': 'exit', 'exit_code': 0},
          },
        ],
      }),
    );
    expect(blocks, hasLength(1));
    expect(
      blocks.single.serverToolResult!.name,
      OpenAIResponsesServerToolName.shell.value,
    );
  });

  group('TestItemAddedEventToContentBlockShell', () {
    test('TestItemAddedEventToContentBlockShellCall', () {
      final blocks = _receiver().itemAddedEventToContentBlock(
        _added(1, {
          'type': 'shell_call',
          'id': 'shell1',
          'call_id': 'call_shell1',
          'status': 'in_progress',
          'action': {
            'commands': ['ls -la'],
          },
          'environment': {'type': 'local'},
        }),
      );
      expect(blocks, hasLength(1));
      expect(
        blocks.single.serverToolCall!.name,
        OpenAIResponsesServerToolName.shell.value,
      );
    });

    test('TestItemAddedEventToContentBlockShellOutput', () {
      final blocks = _receiver().itemAddedEventToContentBlock(
        _added(1, {
          'type': 'shell_call_output',
          'id': 'shellout1',
          'call_id': 'call_shell1',
          'status': 'in_progress',
          'output': [
            {
              'stdout': 'output',
              'outcome': {'type': 'exit', 'exit_code': 0},
            },
          ],
        }),
      );
      expect(blocks, hasLength(1));
      expect(
        blocks.single.serverToolResult!.name,
        OpenAIResponsesServerToolName.shell.value,
      );
    });
  });

  group('ResponsesStreamConverter (the loop of receivedStreamingResponse)', () {
    Future<List<Object>> run(List<Map<String, Object?>> events) async {
      final (reader, writer) = pipe<AgenticMessage>(capacity: 100);
      final converter = ResponsesStreamConverter(
        writer,
        options: const ChatModelOptions(),
        enableAutoCache: false,
      );
      events.forEach(converter.onEvent);
      await writer.close();
      final out = <Object>[];
      for (;;) {
        try {
          out.add(await reader.recv());
        } on StreamEOFException {
          return out;
        } catch (error) {
          out.add(error);
        }
      }
    }

    test('an error event is sent as an error and the stream goes on',
        () async {
      final out = await run([
        {'type': 'error', 'code': 'ERR', 'message': 'boom'},
        {
          'type': 'response.output_text.delta',
          'item_id': 'm',
          'output_index': 0,
          'content_index': 0,
          'delta': 'hi',
        },
      ]);
      expect(out, hasLength(2));
      expect(
        (out[0] as OpenAIResponsesException).message,
        'received error event: code=ERR message=boom',
      );
      expect(
        (out[1] as AgenticMessage).contentBlocks.single.assistantGenText!.text,
        'hi',
      );
    });

    test('a failed content part event is sent with the event header',
        () async {
      final out = await run([
        {
          'type': 'response.content_part.done',
          'item_id': 'm',
          'output_index': 0,
          'content_index': 0,
          'part': {'type': 'output_text'},
        },
      ]);
      expect(
        (out.single as OpenAIResponsesException).message,
        startsWith(
          "failed to convert event 'response.content_part.done': item \"m\"",
        ),
      );
    });

    test('a failed output item event is dropped without an error, as in Go',
        () async {
      final out = await run([
        _done(0, {'type': 'message', 'id': 'never_added'}),
        _done(1, {
          'type': 'shell_call',
          'environment': {'type': 'mystery'},
        }),
      ]);
      expect(out, isEmpty);
    });

    test('unknown events are ignored', () async {
      expect(await run([{'type': 'response.queued'}]), isEmpty);
    });

    test('lifecycle events carry the response meta', () async {
      final out = await run([
        for (final type in [
          'response.created',
          'response.in_progress',
          'response.completed',
          'response.incomplete',
          'response.failed',
        ])
          {
            'type': type,
            'response': {'id': 'resp_1', 'status': 'x'},
          },
      ]);
      expect(out, hasLength(5));
      for (final message in out.cast<AgenticMessage>()) {
        expect(message.responseMeta!.openAIExtension!.id, 'resp_1');
      }
    });

    test('phase events of every hosted tool', () async {
      final out = await run([
        for (final type in [
          'response.mcp_list_tools.in_progress',
          'response.mcp_list_tools.failed',
          'response.mcp_list_tools.completed',
          'response.mcp_call.in_progress',
          'response.mcp_call.completed',
          'response.mcp_call.failed',
          'response.web_search_call.in_progress',
          'response.web_search_call.searching',
          'response.web_search_call.completed',
          'response.file_search_call.in_progress',
          'response.file_search_call.searching',
          'response.file_search_call.completed',
          'response.code_interpreter_call.in_progress',
          'response.code_interpreter_call.interpreting',
          'response.code_interpreter_call.completed',
          'response.image_generation_call.in_progress',
          'response.image_generation_call.generating',
          'response.image_generation_call.completed',
        ])
          {'type': type, 'item_id': 'i', 'output_index': 0},
      ]);
      expect(
        out.cast<AgenticMessage>().map(
              (m) => itemStatusOf(m.contentBlocks.single),
            ),
        [
          'in_progress',
          'failed',
          'completed',
          'in_progress',
          'completed',
          'failed',
          'in_progress',
          'searching',
          'completed',
          'in_progress',
          'searching',
          'completed',
          'in_progress',
          'interpreting',
          'completed',
          'in_progress',
          'generating',
          'completed',
        ],
      );
    });
  });
}
