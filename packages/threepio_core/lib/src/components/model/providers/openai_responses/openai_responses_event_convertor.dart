/// Turning the server-sent events of a streamed Responses API call into
/// agentic message chunks.
///
/// Port of eino-ext `components/model/agenticopenai/
/// responses_event_convertor.go`. Each chunk is an assistant message with
/// one content block (or only a response meta); a block carries a
/// `StreamingMeta` whose index says which block of the joined message it
/// belongs to, so `concatAgenticMessages` reassembles the response. Not
/// exported.
library;

import '../../../../schema/agentic_message.dart';
import '../../../../schema/extensions/openai.dart';
import '../../../../streaming/stream_writer.dart';
import '../../chat_model_options.dart';
import 'openai_responses_block_extra.dart';
import 'openai_responses_consts.dart';
import 'openai_responses_convertor.dart';
import 'openai_responses_exception.dart';
import 'openai_responses_extension.dart';
import 'openai_responses_utils.dart';

/// Converts the events of one stream, keeping the block index of every
/// output item, content part and annotation seen so far. Port of eino-ext's
/// `streamReceiver`.
final class ResponsesStreamReceiver {
  /// A receiver for a call made with [options] (the tool search tool is
  /// read from them).
  ResponsesStreamReceiver(this.options);

  /// The options of the call.
  final ChatModelOptions options;

  /// The block indices of the text parts of each output message still being
  /// streamed, by item id.
  final Map<String, Set<int>> processingAssistantGenTextBlockIndex = {};

  /// The highest block index handed out.
  int maxBlockIndex = -1;

  /// The block index of each index key.
  final Map<String, int> indexMapper = {};

  /// The highest summary index of each reasoning item (by output index).
  final Map<String, int> maxReasoningSummaryIndex = {};

  /// The summary index of each `output:summary` pair.
  final Map<String, int> reasoningSummaryIndexMapper = {};

  /// The highest annotation index of each text part.
  final Map<String, int> maxTextAnnotationIndex = {};

  /// The annotation index of each `output:content:annotation` triple.
  final Map<String, int> textAnnotationIndexMapper = {};

  /// The items of the `output_item.added` events of MCP calls and MCP tool
  /// listings, for the phase events that follow them.
  final Map<String, Json> itemAddedEventCache = {};

  /// The block index of [key], handed out on first use. Port of
  /// `getBlockIndex`.
  int getBlockIndex(String key) =>
      indexMapper.putIfAbsent(key, () => ++maxBlockIndex);

  /// Whether the summary [summaryIdx] of the reasoning item at [outputIdx]
  /// is seen for the first time. Port of `isNewReasoningSummaryIndex`.
  bool isNewReasoningSummaryIndex(int outputIdx, int summaryIdx) {
    final key = '$outputIdx:$summaryIdx';
    if (reasoningSummaryIndexMapper.containsKey(key)) return false;
    final next = (maxReasoningSummaryIndex['$outputIdx'] ?? -1) + 1;
    reasoningSummaryIndexMapper[key] = next;
    maxReasoningSummaryIndex['$outputIdx'] = next;
    return true;
  }

  /// The index of an annotation within its text part. Port of
  /// `getTextAnnotationIndex`.
  int getTextAnnotationIndex(int outputIdx, int contentIdx, int annotationIdx) {
    final maxKey = '$outputIdx:$contentIdx';
    final key = '$outputIdx:$contentIdx:$annotationIdx';
    if (textAnnotationIndexMapper[key] case final index?) return index;
    final next = (maxTextAnnotationIndex[maxKey] ?? -1) + 1;
    textAnnotationIndexMapper[key] = next;
    maxTextAnnotationIndex[maxKey] = next;
    return next;
  }

  ContentBlock _chunk(ContentBlockVariant content, int index) =>
      ContentBlock(content, streamingMeta: StreamingMeta(index: index));

  ContentBlock _at(ContentBlock block, String key) =>
      block.copyWith(streamingMeta: StreamingMeta(index: getBlockIndex(key)));

  /// The blocks of an `output_item.added` event. Port of
  /// `itemAddedEventToContentBlock`: function calls, reasoning, code
  /// interpreter and shell items give blocks; MCP calls and listings are
  /// kept for their phase events; the rest is ignored.
  List<ContentBlock> itemAddedEventToContentBlock(Json event) {
    final outputIdx = jsonInt(event, 'output_index');
    final item = jsonObject(event, 'item') ?? const <String, Object?>{};
    switch (jsonString(item, 'type')) {
      case 'function_call':
        return [
          _at(
            functionToolCallToContentBlock(item),
            makeFunctionToolCallIndexKey(outputIdx),
          ),
        ];
      case 'reasoning':
        return [
          _at(reasoningToContentBlocks(item), makeReasoningIndexKey(outputIdx)),
        ];
      case 'mcp_call':
        itemAddedEventCache[makeMcpToolCallItemAddedEventCacheKey(
          jsonString(item, 'id'),
          outputIdx,
        )] = item;
        return const [];
      case 'mcp_list_tools':
        itemAddedEventCache[makeMcpListToolsItemAddedEventCacheKey(
          jsonString(item, 'id'),
          outputIdx,
        )] = item;
        return const [];
      case 'code_interpreter_call':
        return _callAndResult(codeInterpreterToContentBlocks(item), outputIdx);
      case 'shell_call':
        return [
          _at(shellCallToContentBlock(item), makeServerToolCallIndexKey(outputIdx)),
        ];
      case 'shell_call_output':
        return [
          _at(
            shellOutputToContentBlock(item),
            makeServerToolResultIndexKey(outputIdx),
          ),
        ];
      default:
        return const [];
    }
  }

  List<ContentBlock> _callAndResult(List<ContentBlock> blocks, int outputIdx) =>
      [
        _at(blocks[0], makeServerToolCallIndexKey(outputIdx)),
        _at(blocks[1], makeServerToolResultIndexKey(outputIdx)),
      ];

  /// The blocks of an `output_item.done` event. Port of
  /// `itemDoneEventToContentBlocks`.
  List<ContentBlock> itemDoneEventToContentBlocks(Json event) {
    final outputIdx = jsonInt(event, 'output_index');
    final item = jsonObject(event, 'item') ?? const <String, Object?>{};
    switch (jsonString(item, 'type')) {
      case 'message':
        return itemDoneEventOutputMessageToContentBlock(item);
      case 'reasoning':
        return [itemDoneEventReasoningToContentBlock(outputIdx, item)];
      case 'function_call':
        return [itemDoneEventFunctionToolCallToContentBlock(outputIdx, item)];
      case 'web_search_call':
        return _callAndResult(webSearchToContentBlocks(item), outputIdx);
      case 'tool_search_call':
        return [itemDoneEventToolSearchCallToContentBlocks(outputIdx, item)];
      case 'tool_search_output':
        return [itemDoneEventToolSearchOutputItemToContentBlocks(outputIdx, item)];
      case 'file_search_call':
        return _callAndResult(fileSearchToContentBlocks(item), outputIdx);
      case 'code_interpreter_call':
        return _callAndResult(codeInterpreterToContentBlocks(item), outputIdx);
      case 'image_generation_call':
        return _callAndResult(imageGenerationToContentBlocks(item), outputIdx);
      case 'mcp_call':
        return [
          for (final block in mcpCallToContentBlocks(item))
            switch (block.type) {
              ContentBlockType.mcpToolCall =>
                _at(block, makeMcpToolCallIndexKey(outputIdx)),
              ContentBlockType.mcpToolResult =>
                _at(block, makeMcpToolResultIndexKey(outputIdx)),
              _ => throw conversionError(
                  'expected MCP tool call or result block, but got '
                  '"${block.type.value}"',
                ),
            },
        ];
      case 'mcp_list_tools':
        return [
          _at(
            mcpListToolsToContentBlock(item),
            makeMcpListToolsResultIndexKey(outputIdx),
          ),
        ];
      case 'mcp_approval_request':
        return [
          _at(
            mcpApprovalRequestToContentBlock(item),
            makeMcpToolApprovalRequestIndexKey(outputIdx),
          ),
        ];
      case 'shell_call':
        return [
          _at(shellCallToContentBlock(item), makeServerToolCallIndexKey(outputIdx)),
        ];
      case 'shell_call_output':
        return [
          _at(
            shellOutputToContentBlock(item),
            makeServerToolResultIndexKey(outputIdx),
          ),
        ];
      default:
        return const [];
    }
  }

  /// The closing chunks of the text parts of a finished output message.
  /// Port of `itemDoneEventOutputMessageToContentBlock`.
  List<ContentBlock> itemDoneEventOutputMessageToContentBlock(Json item) {
    final id = jsonString(item, 'id');
    final indices = processingAssistantGenTextBlockIndex[id];
    if (indices == null) {
      throw conversionError('item $id not found in processing queue');
    }
    final status = jsonString(item, 'status');
    return [
      for (final index in indices)
        _withStatus(withItemId(_chunk(const AssistantGenText(), index), id), status),
    ];
  }

  ContentBlock _withStatus(ContentBlock block, String status) =>
      status.isEmpty ? block : withItemStatus(block, status);

  /// Port of `itemDoneEventReasoningToContentBlock`.
  ContentBlock itemDoneEventReasoningToContentBlock(int outputIdx, Json item) =>
      _withStatus(
        withItemId(
          _chunk(const Reasoning(), getBlockIndex(makeReasoningIndexKey(outputIdx))),
          jsonString(item, 'id'),
        ),
        jsonString(item, 'status'),
      );

  /// Port of `itemDoneEventFunctionToolCallToContentBlock`: the call id and
  /// name, without the arguments (the deltas carried them).
  ContentBlock itemDoneEventFunctionToolCallToContentBlock(
    int outputIdx,
    Json item,
  ) =>
      _withStatus(
        withItemId(
          _chunk(
            FunctionToolCall(
              callId: jsonString(item, 'call_id'),
              name: jsonString(item, 'name'),
            ),
            getBlockIndex(makeFunctionToolCallIndexKey(outputIdx)),
          ),
          jsonString(item, 'id'),
        ),
        jsonString(item, 'status'),
      );

  /// Port of `itemDoneEventToolSearchCallToContentBlocks`.
  ContentBlock itemDoneEventToolSearchCallToContentBlocks(
    int outputIdx,
    Json item,
  ) =>
      _at(
        toolSearchToolCallToContentBlock(item, options),
        makeServerToolCallIndexKey(outputIdx),
      );

  /// Port of `itemDoneEventToolSearchOutputItemToContentBlocks`.
  ContentBlock itemDoneEventToolSearchOutputItemToContentBlocks(
    int outputIdx,
    Json item,
  ) =>
      _at(
        toolSearchToolResultToContentBlock(item),
        makeServerToolResultIndexKey(outputIdx),
      );

  /// The opening chunk of a content part. Port of
  /// `contentPartAddedEventToContentBlock`; unknown part types give `null`.
  ContentBlock? contentPartAddedEventToContentBlock(Json event) {
    final outputIdx = jsonInt(event, 'output_index');
    final contentIdx = jsonInt(event, 'content_index');
    final itemId = jsonString(event, 'item_id');
    final part = jsonObject(event, 'part');
    final ContentBlock block;
    switch (jsonString(part, 'type')) {
      case 'output_text' || 'refusal':
        final index =
            getBlockIndex(makeAssistantGenTextIndexKey(outputIdx, contentIdx));
        (processingAssistantGenTextBlockIndex[itemId] ??= <int>{}).add(index);
        block = _chunk(const AssistantGenText(), index);
      case 'reasoning_text':
        block = _chunk(
          Reasoning(
            openAIExtension: OpenAIReasoningExtension(
              content: [
                OpenAIReasoningContent(
                  text: jsonString(part, 'text'),
                  index: contentIdx,
                ),
              ],
            ),
          ),
          getBlockIndex(makeReasoningIndexKey(outputIdx)),
        );
      default:
        return null;
    }
    return withItemId(withItemStatus(block, 'in_progress'), itemId);
  }

  /// The closing chunk of a content part. Port of
  /// `contentPartDoneEventToContentBlock`; unknown part types give `null`.
  ContentBlock? contentPartDoneEventToContentBlock(Json event) {
    final outputIdx = jsonInt(event, 'output_index');
    final contentIdx = jsonInt(event, 'content_index');
    final itemId = jsonString(event, 'item_id');
    final part = jsonObject(event, 'part');
    final ContentBlock block;
    switch (jsonString(part, 'type')) {
      case 'output_text' || 'refusal':
        final index =
            getBlockIndex(makeAssistantGenTextIndexKey(outputIdx, contentIdx));
        final indices = processingAssistantGenTextBlockIndex[itemId];
        if (indices == null) {
          throw conversionError(
            'item "$itemId" has no processing assistant gen text block index',
          );
        }
        indices.remove(index);
        block = _chunk(const AssistantGenText(), index);
      case 'reasoning_text':
        block = _chunk(
          const Reasoning(),
          getBlockIndex(makeReasoningIndexKey(outputIdx)),
        );
      default:
        return null;
    }
    return withItemId(withItemStatus(block, 'completed'), itemId);
  }

  /// Port of `refusalDeltaEventToContentBlock`.
  ContentBlock refusalDeltaEventToContentBlock(Json event) => withItemId(
        _chunk(
          AssistantGenText(
            openAIExtension: OpenAIAssistantGenTextExtension(
              refusal: OpenAIOutputRefusal(reason: jsonString(event, 'delta')),
            ),
          ),
          getBlockIndex(
            makeAssistantGenTextIndexKey(
              jsonInt(event, 'output_index'),
              jsonInt(event, 'content_index'),
            ),
          ),
        ),
        jsonString(event, 'item_id'),
      );

  /// Port of `outputTextDeltaEventToContentBlock`.
  ContentBlock outputTextDeltaEventToContentBlock(Json event) => withItemId(
        _chunk(
          AssistantGenText(text: jsonString(event, 'delta')),
          getBlockIndex(
            makeAssistantGenTextIndexKey(
              jsonInt(event, 'output_index'),
              jsonInt(event, 'content_index'),
            ),
          ),
        ),
        jsonString(event, 'item_id'),
      );

  /// Port of `annotationAddedEventToContentBlock`: the annotation carries its
  /// index within the text part.
  ContentBlock annotationAddedEventToContentBlock(Json event) {
    final outputIdx = jsonInt(event, 'output_index');
    final contentIdx = jsonInt(event, 'content_index');
    final parsed = wrapConversion(
      'failed to convert annotation',
      () => outputTextAnnotationToTextAnnotation(
        jsonObject(event, 'annotation') ?? const {},
      ),
    );
    final annotation = OpenAITextAnnotation(
      index: getTextAnnotationIndex(
        outputIdx,
        contentIdx,
        jsonInt(event, 'annotation_index'),
      ),
      type: parsed.type,
      fileCitation: parsed.fileCitation,
      urlCitation: parsed.urlCitation,
      containerFileCitation: parsed.containerFileCitation,
      filePath: parsed.filePath,
    );
    return withItemId(
      _chunk(
        AssistantGenText(
          openAIExtension:
              OpenAIAssistantGenTextExtension(annotations: [annotation]),
        ),
        getBlockIndex(makeAssistantGenTextIndexKey(outputIdx, contentIdx)),
      ),
      jsonString(event, 'item_id'),
    );
  }

  /// Port of `reasoningSummaryTextDeltaEventToContentBlock`: the first delta
  /// of every summary after the first starts with a line break.
  ContentBlock reasoningSummaryTextDeltaEventToContentBlock(Json event) {
    final outputIdx = jsonInt(event, 'output_index');
    final summaryIdx = jsonInt(event, 'summary_index');
    var text = jsonString(event, 'delta');
    if (isNewReasoningSummaryIndex(outputIdx, summaryIdx) && summaryIdx != 0) {
      text = '\n$text';
    }
    return withItemId(
      _chunk(
        Reasoning(text: text),
        getBlockIndex(makeReasoningIndexKey(outputIdx)),
      ),
      jsonString(event, 'item_id'),
    );
  }

  /// Port of `reasoningTextDeltaEventToContentBlock`: raw reasoning text
  /// goes to the OpenAI extension, at its content index.
  ContentBlock reasoningTextDeltaEventToContentBlock(Json event) => withItemId(
        _chunk(
          Reasoning(
            openAIExtension: OpenAIReasoningExtension(
              content: [
                OpenAIReasoningContent(
                  text: jsonString(event, 'delta'),
                  index: jsonInt(event, 'content_index'),
                ),
              ],
            ),
          ),
          getBlockIndex(makeReasoningIndexKey(jsonInt(event, 'output_index'))),
        ),
        jsonString(event, 'item_id'),
      );

  /// Port of `functionCallArgumentsDeltaEventToContentBlock`.
  ContentBlock functionCallArgumentsDeltaEventToContentBlock(Json event) =>
      withItemId(
        _chunk(
          FunctionToolCall(arguments: jsonString(event, 'delta')),
          getBlockIndex(
            makeFunctionToolCallIndexKey(jsonInt(event, 'output_index')),
          ),
        ),
        jsonString(event, 'item_id'),
      );

  /// Port of `mcpListToolsPhaseToContentBlock`.
  ContentBlock mcpListToolsPhaseToContentBlock(
    String itemId,
    int outputIdx,
    String status,
  ) {
    final cached = itemAddedEventCache[
        makeMcpListToolsItemAddedEventCacheKey(itemId, outputIdx)];
    final content = cached == null
        ? AgenticMcpListToolsResult()
        : AgenticMcpListToolsResult(
            serverLabel: jsonString(cached, 'server_label'),
          );
    return _withStatus(
      withItemId(
        _chunk(content, getBlockIndex(makeMcpListToolsResultIndexKey(outputIdx))),
        itemId,
      ),
      status,
    );
  }

  /// Port of `mcpCallArgumentsDeltaEventToContentBlock`.
  ContentBlock mcpCallArgumentsDeltaEventToContentBlock(Json event) =>
      withItemId(
        _chunk(
          AgenticMcpToolCall(arguments: jsonString(event, 'delta')),
          getBlockIndex(makeMcpToolCallIndexKey(jsonInt(event, 'output_index'))),
        ),
        jsonString(event, 'item_id'),
      );

  /// Port of `mcpCallPhaseToContentBlock`.
  ContentBlock mcpCallPhaseToContentBlock(
    String itemId,
    int outputIdx,
    String status,
  ) {
    final cached =
        itemAddedEventCache[makeMcpToolCallItemAddedEventCacheKey(itemId, outputIdx)];
    final content = cached == null
        ? const AgenticMcpToolCall()
        : AgenticMcpToolCall(
            serverLabel: jsonString(cached, 'server_label'),
            approvalRequestId: jsonString(cached, 'approval_request_id'),
            name: jsonString(cached, 'name'),
          );
    return _withStatus(
      withItemId(
        _chunk(content, getBlockIndex(makeMcpToolCallIndexKey(outputIdx))),
        itemId,
      ),
      status,
    );
  }

  ContentBlock _phase(
    ContentBlockVariant content,
    String key,
    String itemId,
    String status,
  ) =>
      _withStatus(withItemId(_chunk(content, getBlockIndex(key)), itemId), status);

  /// Port of `webSearchPhaseToContentBlock`.
  ContentBlock webSearchPhaseToContentBlock(
    String itemId,
    int outputIdx,
    String status,
  ) =>
      _phase(
        ServerToolCall(name: OpenAIResponsesServerToolName.webSearch.value),
        makeServerToolCallIndexKey(outputIdx),
        itemId,
        status,
      );

  /// Port of `fileSearchPhaseToContentBlock`.
  ContentBlock fileSearchPhaseToContentBlock(
    String itemId,
    int outputIdx,
    String status,
  ) =>
      _phase(
        ServerToolCall(name: OpenAIResponsesServerToolName.fileSearch.value),
        makeServerToolCallIndexKey(outputIdx),
        itemId,
        status,
      );

  /// Port of `codeInterpreterPhaseToContentBlock`.
  ContentBlock codeInterpreterPhaseToContentBlock(
    String itemId,
    int outputIdx,
    String status,
  ) =>
      _phase(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.codeInterpreter.value,
        ),
        makeServerToolResultIndexKey(outputIdx),
        itemId,
        status,
      );

  /// Port of `codeInterpreterCodeDeltaEventToContentBlock`.
  ContentBlock codeInterpreterCodeDeltaEventToContentBlock(Json event) =>
      withItemId(
        _chunk(
          ServerToolResult(
            name: OpenAIResponsesServerToolName.codeInterpreter.value,
            content: OpenAIResponsesServerToolResult(
              codeInterpreter: OpenAIResponsesCodeInterpreterResult(
                code: jsonString(event, 'delta'),
              ),
            ),
          ),
          getBlockIndex(
            makeServerToolResultIndexKey(jsonInt(event, 'output_index')),
          ),
        ),
        jsonString(event, 'item_id'),
      );

  /// Port of `imageGenerationPhaseToContentBlock`.
  ContentBlock imageGenerationPhaseToContentBlock(
    String itemId,
    int outputIdx,
    String status,
  ) =>
      _phase(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.imageGeneration.value,
        ),
        makeServerToolResultIndexKey(outputIdx),
        itemId,
        status,
      );

  /// Port of `imageGenerationPartialImageEventToContentBlock`.
  ContentBlock imageGenerationPartialImageEventToContentBlock(Json event) =>
      withItemId(
        _chunk(
          ServerToolResult(
            name: OpenAIResponsesServerToolName.imageGeneration.value,
            content: OpenAIResponsesServerToolResult(
              imageGeneration: OpenAIResponsesImageGenerationResult(
                imageBase64: jsonString(event, 'partial_image_b64'),
              ),
            ),
          ),
          getBlockIndex(
            makeServerToolResultIndexKey(jsonInt(event, 'output_index')),
          ),
        ),
        jsonString(event, 'item_id'),
      );
}

/// Sends the chunks of a stream to its writer. Port of eino-ext's
/// `callbackSender` (the callback outputs are made by
/// `AgenticModelCallCallbacks` here, so it sends messages).
final class ResponsesChunkSender {
  /// A sender writing to [writer]; with [enableAutoCache] every chunk is
  /// marked for the auto cache.
  ResponsesChunkSender(this.writer, {required this.enableAutoCache});

  final StreamWriter<AgenticMessage> writer;
  final bool enableAutoCache;

  /// The prefix of the errors sent for the current event.
  String errHeader = '';

  /// Sends a chunk with [meta], or [error]. Port of `sendMeta`.
  void sendMeta(AgenticResponseMeta? meta, [Object? error]) =>
      _send(meta, null, error);

  /// Sends a chunk with [block], or [error]; nothing when both are `null`.
  /// Port of `sendBlock`.
  void sendBlock(ContentBlock? block, [Object? error]) {
    if (block != null || error != null) _send(null, block, error);
  }

  void _send(AgenticResponseMeta? meta, ContentBlock? block, Object? error) {
    if (error != null) {
      writer.sendError(
        error is OpenAIResponsesException
            ? error.wrap(errHeader)
            : OpenAIResponsesException('$errHeader: $error', cause: error),
      );
      return;
    }
    var message = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [?block],
      responseMeta: meta,
    );
    if (enableAutoCache) message = withAutoCached(message);
    writer.send(message);
  }
}

/// Handles the events of one stream. Port of the loop of eino-ext's
/// `receivedStreamingResponse`.
final class ResponsesStreamConverter {
  /// A converter for a call made with [options], writing to [writer].
  ResponsesStreamConverter(
    StreamWriter<AgenticMessage> writer, {
    required ChatModelOptions options,
    required bool enableAutoCache,
  })  : receiver = ResponsesStreamReceiver(options),
        sender = ResponsesChunkSender(writer, enableAutoCache: enableAutoCache);

  final ResponsesStreamReceiver receiver;
  final ResponsesChunkSender sender;

  /// Converts [event] and sends what it gives. Events of unknown types are
  /// ignored.
  ///
  /// As in Go, a conversion failure of an `output_item.added` or
  /// `output_item.done` event drops the event without an error (Go loops
  /// over the nil blocks it gets with the error); the failures of the other
  /// events are sent as errors and the stream goes on.
  void onEvent(Json event) {
    final type = jsonString(event, 'type');
    sender.errHeader = "failed to convert event '$type'";
    final r = receiver;
    final s = sender;
    String itemId() => jsonString(event, 'item_id');
    int outputIdx() => jsonInt(event, 'output_index');

    switch (type) {
      case 'error':
        s.writer.sendError(
          OpenAIResponsesException(
            'received error event: code=${jsonString(event, 'code')} '
            'message=${jsonString(event, 'message')}',
            errorCode: event['code'],
            isRetryable: isRetryableStreamError(code: jsonString(event, 'code')),
          ),
        );
      case 'response.created' ||
            'response.in_progress' ||
            'response.completed' ||
            'response.incomplete' ||
            'response.failed':
        s.sendMeta(
          responseObjectToResponseMeta(
            jsonObject(event, 'response') ?? const {},
          ),
        );
      case 'response.output_item.added':
        _blocks(() => r.itemAddedEventToContentBlock(event));
      case 'response.output_item.done':
        _blocks(() => r.itemDoneEventToContentBlocks(event));
      case 'response.content_part.added':
        _block(() => r.contentPartAddedEventToContentBlock(event));
      case 'response.content_part.done':
        _block(() => r.contentPartDoneEventToContentBlock(event));
      case 'response.refusal.delta':
        s.sendBlock(r.refusalDeltaEventToContentBlock(event));
      case 'response.output_text.delta':
        s.sendBlock(r.outputTextDeltaEventToContentBlock(event));
      case 'response.output_text.annotation.added':
        _block(() => r.annotationAddedEventToContentBlock(event));
      case 'response.reasoning_text.delta':
        s.sendBlock(r.reasoningTextDeltaEventToContentBlock(event));
      case 'response.reasoning_summary_text.delta':
        s.sendBlock(r.reasoningSummaryTextDeltaEventToContentBlock(event));
      case 'response.function_call_arguments.delta':
        s.sendBlock(r.functionCallArgumentsDeltaEventToContentBlock(event));
      case 'response.mcp_list_tools.in_progress':
        s.sendBlock(
          r.mcpListToolsPhaseToContentBlock(itemId(), outputIdx(), 'in_progress'),
        );
      case 'response.mcp_list_tools.failed':
        s.sendBlock(
          r.mcpListToolsPhaseToContentBlock(itemId(), outputIdx(), 'failed'),
        );
      case 'response.mcp_list_tools.completed':
        s.sendBlock(
          r.mcpListToolsPhaseToContentBlock(itemId(), outputIdx(), 'completed'),
        );
      case 'response.mcp_call_arguments.delta':
        s.sendBlock(r.mcpCallArgumentsDeltaEventToContentBlock(event));
      case 'response.mcp_call.in_progress':
        s.sendBlock(
          r.mcpCallPhaseToContentBlock(itemId(), outputIdx(), 'in_progress'),
        );
      case 'response.mcp_call.completed':
        s.sendBlock(
          r.mcpCallPhaseToContentBlock(itemId(), outputIdx(), 'completed'),
        );
      case 'response.mcp_call.failed':
        s.sendBlock(r.mcpCallPhaseToContentBlock(itemId(), outputIdx(), 'failed'));
      case 'response.web_search_call.in_progress':
        s.sendBlock(
          r.webSearchPhaseToContentBlock(itemId(), outputIdx(), 'in_progress'),
        );
      case 'response.web_search_call.searching':
        s.sendBlock(
          r.webSearchPhaseToContentBlock(itemId(), outputIdx(), 'searching'),
        );
      case 'response.web_search_call.completed':
        s.sendBlock(
          r.webSearchPhaseToContentBlock(itemId(), outputIdx(), 'completed'),
        );
      case 'response.file_search_call.in_progress':
        s.sendBlock(
          r.fileSearchPhaseToContentBlock(itemId(), outputIdx(), 'in_progress'),
        );
      case 'response.file_search_call.searching':
        s.sendBlock(
          r.fileSearchPhaseToContentBlock(itemId(), outputIdx(), 'searching'),
        );
      case 'response.file_search_call.completed':
        s.sendBlock(
          r.fileSearchPhaseToContentBlock(itemId(), outputIdx(), 'completed'),
        );
      case 'response.code_interpreter_call.in_progress':
        s.sendBlock(
          r.codeInterpreterPhaseToContentBlock(
            itemId(),
            outputIdx(),
            'in_progress',
          ),
        );
      case 'response.code_interpreter_call.interpreting':
        s.sendBlock(
          r.codeInterpreterPhaseToContentBlock(
            itemId(),
            outputIdx(),
            'interpreting',
          ),
        );
      case 'response.code_interpreter_call_code.delta':
        s.sendBlock(r.codeInterpreterCodeDeltaEventToContentBlock(event));
      case 'response.code_interpreter_call.completed':
        s.sendBlock(
          r.codeInterpreterPhaseToContentBlock(
            itemId(),
            outputIdx(),
            'completed',
          ),
        );
      case 'response.image_generation_call.in_progress':
        s.sendBlock(
          r.imageGenerationPhaseToContentBlock(
            itemId(),
            outputIdx(),
            'in_progress',
          ),
        );
      case 'response.image_generation_call.generating':
        s.sendBlock(
          r.imageGenerationPhaseToContentBlock(
            itemId(),
            outputIdx(),
            'generating',
          ),
        );
      case 'response.image_generation_call.partial_image':
        s.sendBlock(r.imageGenerationPartialImageEventToContentBlock(event));
      case 'response.image_generation_call.completed':
        s.sendBlock(
          r.imageGenerationPhaseToContentBlock(
            itemId(),
            outputIdx(),
            'completed',
          ),
        );
      default:
        // Unhandled event types are ignored rather than failing the stream.
        break;
    }
  }

  void _blocks(List<ContentBlock> Function() convert) {
    final List<ContentBlock> blocks;
    try {
      blocks = convert();
    } on OpenAIResponsesException {
      // Go sends nothing: its loop runs over the nil blocks that come with
      // the error.
      return;
    }
    for (final block in blocks) {
      sender.sendBlock(block);
    }
  }

  void _block(ContentBlock? Function() convert) {
    final ContentBlock? block;
    try {
      block = convert();
    } on OpenAIResponsesException catch (error) {
      sender.sendBlock(null, error);
      return;
    }
    sender.sendBlock(block);
  }
}

/// Port of `makeAssistantGenTextIndexKey`.
String makeAssistantGenTextIndexKey(int outputIndex, int contentIndex) =>
    'assistant_gen_text:$outputIndex:$contentIndex';

/// Port of `makeReasoningIndexKey`.
String makeReasoningIndexKey(int outputIndex) => 'reasoning:$outputIndex';

/// Port of `makeFunctionToolCallIndexKey`.
String makeFunctionToolCallIndexKey(int outputIndex) =>
    'function_tool_call:$outputIndex';

/// Port of `makeServerToolCallIndexKey`.
String makeServerToolCallIndexKey(int outputIndex) =>
    'server_tool_call:$outputIndex';

/// Port of `makeServerToolResultIndexKey`.
String makeServerToolResultIndexKey(int outputIndex) =>
    'server_tool_result:$outputIndex';

/// Port of `makeMCPListToolsResultIndexKey`.
String makeMcpListToolsResultIndexKey(int outputIndex) =>
    'mcp_list_tools_result:$outputIndex';

/// Port of `makeMCPToolApprovalRequestIndexKey`.
String makeMcpToolApprovalRequestIndexKey(int outputIndex) =>
    'mcp_tool_approval_request:$outputIndex';

/// Port of `makeMCPToolCallIndexKey`.
String makeMcpToolCallIndexKey(int outputIndex) =>
    'mcp_tool_call:$outputIndex';

/// Port of `makeMCPToolResultIndexKey`.
String makeMcpToolResultIndexKey(int outputIndex) =>
    'mcp_tool_result:$outputIndex';

/// Port of `makeMCPToolCallItemAddedEventCacheKey`.
String makeMcpToolCallItemAddedEventCacheKey(String itemId, int outputIndex) =>
    'mcp_tool_call_item_added_event_cache:$itemId:$outputIndex';

/// Port of `makeMCPListToolsItemAddedEventCacheKey`.
String makeMcpListToolsItemAddedEventCacheKey(String itemId, int outputIndex) =>
    'mcp_list_tools_item_added_event_cache:$itemId:$outputIndex';
