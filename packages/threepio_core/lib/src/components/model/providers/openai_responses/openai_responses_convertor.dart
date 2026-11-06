/// Converting between agentic messages and the JSON of the OpenAI Responses
/// API: input items and tools of a request, output items of a response.
///
/// Port of eino-ext `components/model/agenticopenai/responses_convertor.go`
/// and the tool helpers of `responses_model.go`. Go builds `openai-go`
/// request structs and reads response structs; here the request items are
/// built as JSON maps (with the SDK's rules: a required field is always
/// written, an optional one only when set) and the response is read from
/// its decoded JSON. Not exported.
library;

import 'dart:convert';

import '../../../../schema/agentic_message.dart';
import '../../../../schema/agentic_tool_choice.dart';
import '../../../../schema/extensions/openai.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../chat_model_options.dart';
import '../openai/openai_converters.dart';
import 'openai_responses_block_extra.dart';
import 'openai_responses_config.dart';
import 'openai_responses_consts.dart';
import 'openai_responses_extension.dart';
import 'openai_responses_extension_ops.dart';
import 'openai_responses_utils.dart';

/// A JSON object of the request or the response.
typedef Json = Map<String, Object?>;

// ---------------------------------------------------------------------------
// Request: input items
// ---------------------------------------------------------------------------

/// The input items of a system message. Port of `toSystemRoleInputItems`.
List<Json> toSystemRoleInputItems(AgenticMessage message) => [
      for (final block in message.contentBlocks)
        switch (block.content) {
          final UserInputText text => wrapConversion(
              'failed to convert user input text to input item',
              () => userInputTextToInputItem('system', text),
            ),
          final UserInputImage image => wrapConversion(
              'failed to convert user input image to input item',
              () => userInputImageToInputItem('system', image),
            ),
          _ => throw conversionError(
              'invalid content block type "${block.type.value}" with system '
              'role',
            ),
        },
    ];

/// The input items of an assistant message. Port of
/// `toAssistantRoleInputItems`: blocks of another model are kept only when
/// their type is model-agnostic, and the call and result items of MCP and
/// server tools are paired into one item each.
List<Json> toAssistantRoleInputItems(AgenticMessage message) {
  final selfGenerated = isSelfGeneratedMessage(message);
  final items = <Json>[];
  for (final block in message.contentBlocks) {
    if (!selfGenerated && !isAllowedNonSelfGeneratedBlockType(block.type)) {
      continue;
    }
    items.add(
      switch (block.type) {
        ContentBlockType.assistantGenText => wrapConversion(
            'failed to convert assistant generated text to input item',
            () => assistantGenTextToInputItem(block),
          ),
        ContentBlockType.reasoning => wrapConversion(
            'failed to convert reasoning to input item',
            () => reasoningToInputItem(block),
          ),
        ContentBlockType.functionToolCall => wrapConversion(
            'failed to convert function tool call to input item',
            () => functionToolCallToInputItem(block),
          ),
        ContentBlockType.serverToolCall => wrapConversion(
            'failed to convert server tool call to input item',
            () => serverToolCallToInputItem(block),
          ),
        ContentBlockType.serverToolResult => wrapConversion(
            'failed to convert server tool result to input item',
            () => serverToolResultToInputItem(block),
          ),
        ContentBlockType.mcpToolApprovalRequest => wrapConversion(
            'failed to convert MCP tool approval request to input item',
            () => mcpToolApprovalRequestToInputItem(block),
          ),
        ContentBlockType.mcpListToolsResult => wrapConversion(
            'failed to convert MCP list tools result to input item',
            () => mcpListToolsResultToInputItem(block),
          ),
        ContentBlockType.mcpToolCall => wrapConversion(
            'failed to convert MCP tool call to input item',
            () => mcpToolCallToInputItem(block),
          ),
        ContentBlockType.mcpToolResult => wrapConversion(
            'failed to convert MCP tool result to input item',
            () => mcpToolResultToInputItem(block),
          ),
        _ => throw conversionError(
            'invalid content block type "${block.type.value}" with assistant '
            'role',
          ),
      },
    );
  }
  return pairToolCallItems(items);
}

/// Pairs the call and result items of MCP and server tools. Port of
/// `pairToolCallItems`.
List<Json> pairToolCallItems(List<Json> items) {
  var paired = wrapConversion(
    'failed to pair MCP tool call items',
    () => pairMcpToolCallItems(items),
  );
  paired = wrapConversion(
    'failed to pair web server tool call items',
    () => pairWebSearchServerToolCallItems(paired),
  );
  paired = wrapConversion(
    'failed to pair file search tool call items',
    () => pairFileSearchToolCallItems(paired),
  );
  paired = wrapConversion(
    'failed to pair code interpreter tool call items',
    () => pairCodeInterpreterToolCallItems(paired),
  );
  return wrapConversion(
    'failed to pair image generation tool call items',
    () => pairImageGenerationToolCallItems(paired),
  );
}

/// The value of [key] of [a] unless it is Go's zero value, else that of
/// [b]. A list or map that is present is not zero (Go's `reflect.IsZero`
/// only treats a nil slice as zero), an absent key is.
Object? _coalesceKey(Json a, Json b, String key) {
  final value = a[key];
  final zero = switch (value) {
    null => true,
    final String text => text.isEmpty,
    final num number => number == 0,
    final bool flag => !flag,
    _ => false,
  };
  return zero ? b[key] : value;
}

void _putCoalesced(Json target, Json a, Json b, String key, {bool always = false}) {
  final value = _coalesceKey(a, b, key);
  if (value != null || always) target[key] = value ?? '';
}

/// Pairs the items of [type] by id: each id must have exactly two items
/// (call and result), which [merge] joins into the item that takes the
/// place of the first one.
List<Json> _pairItems(
  List<Json> items, {
  required String type,
  required String Function(int index) emptyIdError,
  required String label,
  required Json Function(Json item, Json pair) merge,
}) {
  final indices = <String, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item['type'] != type) continue;
    final id = jsonString(item, 'id');
    if (id.isEmpty) throw conversionError(emptyIdError(i));
    (indices[id] ??= []).add(i);
  }
  for (final MapEntry(key: id, value: found) in indices.entries) {
    if (found.length != 2) {
      throw conversionError(
        '$label "$id" should have exactly 2 items (call and result), but '
        'found ${found.length}',
      );
    }
  }

  final processed = <int>{};
  final paired = <Json>[];
  for (var i = 0; i < items.length; i++) {
    if (processed.contains(i)) continue;
    final item = items[i];
    if (item['type'] != type) {
      paired.add(item);
      continue;
    }
    final found = indices[jsonString(item, 'id')]!;
    final pairIndex = found[0] == i ? found[1] : found[0];
    paired.add(merge(item, items[pairIndex]));
    processed
      ..add(i)
      ..add(pairIndex);
  }
  return paired;
}

/// Port of `pairMCPToolCallItems`.
List<Json> pairMcpToolCallItems(List<Json> items) => _pairItems(
      items,
      type: 'mcp_call',
      emptyIdError: (_) => 'found MCP tool call item with empty ID',
      label: 'MCP tool call',
      merge: (call, pair) {
        final merged = <String, Object?>{
          'type': 'mcp_call',
          'id': call['id'],
        };
        _putCoalesced(merged, call, pair, 'server_label', always: true);
        _putCoalesced(merged, call, pair, 'approval_request_id');
        merged['name'] = call['name'] ?? '';
        _putCoalesced(merged, call, pair, 'arguments', always: true);
        _putCoalesced(merged, call, pair, 'output');
        _putCoalesced(merged, call, pair, 'error');
        _putCoalesced(merged, call, pair, 'status');
        return merged;
      },
    );

/// Port of `pairWebSearchServerToolCallItems`.
List<Json> pairWebSearchServerToolCallItems(List<Json> items) => _pairItems(
      items,
      type: 'web_search_call',
      emptyIdError: (i) =>
          'found server tool call item with empty ID at index $i',
      label: 'server tool call',
      merge: (call, pair) {
        final merged = <String, Object?>{
          'type': 'web_search_call',
          'id': call['id'],
        };
        final action =
            pairWebSearchAction(jsonObject(call, 'action'), jsonObject(pair, 'action'));
        if (action != null) merged['action'] = action;
        _putCoalesced(merged, call, pair, 'status');
        return merged;
      },
    );

/// Joins the actions of a web search call and its result. Port of
/// `pairWebSearchAction`: a find or open-page action of either side is kept,
/// and of two search actions the first one is kept with the queries and
/// sources of the second one, when it has any. Actions of different kinds
/// cannot be joined (Go fails when it marshals the request).
Json? pairWebSearchAction(Json? action, Json? pairAction) {
  bool isType(Json? a, String type) => a != null && a['type'] == type;
  final find = isType(action, 'find')
      ? action
      : isType(pairAction, 'find')
          ? pairAction
          : null;
  final openPage = isType(action, 'open_page')
      ? action
      : isType(pairAction, 'open_page')
          ? pairAction
          : null;
  final search = isType(action, 'search') ? action : null;
  final pairSearch = isType(pairAction, 'search') ? pairAction : null;
  Json? mergedSearch;
  if (search == null) {
    mergedSearch = pairSearch;
  } else if (pairSearch == null) {
    mergedSearch = search;
  } else {
    mergedSearch = {...search};
    if (jsonStringList(pairSearch, 'queries').isNotEmpty) {
      mergedSearch['queries'] = pairSearch['queries'];
    }
    if (jsonObjectList(pairSearch, 'sources').isNotEmpty) {
      mergedSearch['sources'] = pairSearch['sources'];
    }
  }
  final present = [?mergedSearch, ?openPage, ?find];
  if (present.length > 1) {
    // openai-go refuses to marshal a union with several variants set.
    throw conversionError(
      'expected union to have only one present variant, got '
      '${present.length}',
    );
  }
  return present.firstOrNull;
}

/// Port of `pairFileSearchToolCallItems`.
List<Json> pairFileSearchToolCallItems(List<Json> items) => _pairItems(
      items,
      type: 'file_search_call',
      emptyIdError: (i) =>
          'found file search tool call item with empty ID at index $i',
      label: 'file search tool call',
      merge: (call, pair) {
        final merged = <String, Object?>{
          'type': 'file_search_call',
          'id': call['id'],
        };
        _putCoalesced(merged, call, pair, 'status');
        _putCoalesced(merged, call, pair, 'queries');
        _putCoalesced(merged, call, pair, 'results');
        return merged;
      },
    );

/// Port of `pairCodeInterpreterToolCallItems`.
List<Json> pairCodeInterpreterToolCallItems(List<Json> items) => _pairItems(
      items,
      type: 'code_interpreter_call',
      emptyIdError: (i) =>
          'found code interpreter tool call item with empty ID at index $i',
      label: 'code interpreter tool call',
      merge: (call, pair) {
        final merged = <String, Object?>{
          'type': 'code_interpreter_call',
          'id': call['id'],
        };
        _putCoalesced(merged, call, pair, 'container_id', always: true);
        _putCoalesced(merged, call, pair, 'status');
        _putCoalesced(merged, call, pair, 'code');
        _putCoalesced(merged, call, pair, 'outputs');
        return merged;
      },
    );

/// Port of `pairImageGenerationToolCallItems`.
List<Json> pairImageGenerationToolCallItems(List<Json> items) => _pairItems(
      items,
      type: 'image_generation_call',
      emptyIdError: (i) =>
          'found image generation tool call item with empty ID at index $i',
      label: 'image generation tool call',
      merge: (call, pair) {
        final merged = <String, Object?>{
          'type': 'image_generation_call',
          'id': call['id'],
        };
        _putCoalesced(merged, call, pair, 'status');
        _putCoalesced(merged, call, pair, 'result');
        return merged;
      },
    );

/// The input items of a user message. Port of `toUserRoleInputItems`.
List<Json> toUserRoleInputItems(AgenticMessage message) => [
      for (final block in message.contentBlocks)
        switch (block.content) {
          final UserInputText text => wrapConversion(
              'failed to convert user input text to input item',
              () => userInputTextToInputItem('user', text),
            ),
          final UserInputImage image => wrapConversion(
              'failed to convert user input image to input item',
              () => userInputImageToInputItem('user', image),
            ),
          final UserInputFile file => wrapConversion(
              'failed to convert user input file to input item',
              () => userInputFileToInputItem('user', file),
            ),
          final FunctionToolResult result => wrapConversion(
              'failed to convert function tool result to input item',
              () => functionToolResultToInputItem(result),
            ),
          final ToolSearchFunctionToolResult result => wrapConversion(
              'failed to convert tool search function tool result to input '
              'item',
              () => toolSearchToolResultBlockToInputItem(result),
            ),
          final AgenticMcpToolApprovalResponse response => wrapConversion(
              'failed to convert MCP tool approval response to input item',
              () => mcpToolApprovalResponseToInputItem(response),
            ),
          _ => throw conversionError(
              'invalid content block type "${block.type.value}" with user '
              'role',
            ),
        },
    ];

/// Port of `userInputTextToInputItem`.
Json userInputTextToInputItem(String role, UserInputText block) =>
    {'role': role, 'content': block.text};

/// Port of `userInputImageToInputItem`.
Json userInputImageToInputItem(String role, UserInputImage block) {
  final source = resolveInputSource(
    block.url,
    block.base64Data,
    block.mimeType,
    block.fileId,
  );
  final image = <String, Object?>{'type': 'input_image'};
  final detail = toInputItemImageDetail(block.detail);
  if (detail.isNotEmpty) image['detail'] = detail;
  putNonEmpty(image, 'file_id', source.fileId);
  putNonEmpty(image, 'image_url', source.url);
  return {
    'role': role,
    'content': [image],
  };
}

/// The `detail` of an input image, or `''` for none. Port of
/// `toInputItemImageDetail` (an invalid value cannot be expressed here).
String toInputItemImageDetail(ImageURLDetail? detail) => switch (detail) {
      null => '',
      ImageURLDetail.high => 'high',
      ImageURLDetail.low => 'low',
      ImageURLDetail.auto => 'auto',
    };

/// Port of `userInputFileToInputItem`: a URL wins over inline data, inline
/// data over a file id.
Json userInputFileToInputItem(String role, UserInputFile block) {
  final source = resolveInputSource(
    block.url,
    block.base64Data,
    block.mimeType,
    block.fileId,
  );
  final file = <String, Object?>{'type': 'input_file'};
  putNonEmpty(file, 'filename', block.name);
  if (block.url.isNotEmpty) {
    putNonEmpty(file, 'file_url', source.url);
  } else if (block.base64Data.isNotEmpty) {
    putNonEmpty(file, 'file_data', block.base64Data);
  } else if (source.fileId.isNotEmpty) {
    putNonEmpty(file, 'file_id', source.fileId);
  }
  return {
    'role': role,
    'content': [file],
  };
}

/// Port of `toolSearchToolResultBlockToInputItem`.
Json toolSearchToolResultBlockToInputItem(ToolSearchFunctionToolResult block) {
  final result = block.result;
  if (result == null) {
    throw conversionError('tool search result should not be nil');
  }
  return {
    'type': 'tool_search_output',
    'tools': toDeferredFunctionTools(result.tools),
    'call_id': block.callId,
    'status': 'completed',
    'execution': 'client',
  };
}

/// Port of `functionToolResultToInputItem`.
Json functionToolResultToInputItem(FunctionToolResult block) => {
      'type': 'function_call_output',
      'call_id': block.callId,
      'output': functionToolResultContentToOutput(block.content),
    };

/// The `output` of a function call output item. Port of
/// `functionToolResultContentToOutput`.
List<Json> functionToolResultContentToOutput(
  List<FunctionToolResultContentBlock> content,
) {
  final items = <Json>[];
  for (final block in content) {
    switch (block.content) {
      case final UserInputText text:
        items.add({'type': 'input_text', 'text': text.text});
      case final UserInputImage image:
        final source = resolveInputSource(
          image.url,
          image.base64Data,
          image.mimeType,
          image.fileId,
        );
        final item = <String, Object?>{'type': 'input_image'};
        putNonEmpty(item, 'image_url', source.url);
        putNonEmpty(item, 'file_id', source.fileId);
        if (image.detail case final detail?) item['detail'] = detail.name;
        items.add(item);
      case final UserInputFile file:
        final source = resolveInputSource(
          file.url,
          file.base64Data,
          file.mimeType,
          file.fileId,
        );
        final item = <String, Object?>{'type': 'input_file'};
        putNonEmpty(item, 'file_url', source.url);
        putNonEmpty(item, 'file_id', source.fileId);
        putNonEmpty(item, 'filename', file.name);
        items.add(item);
      case UserInputAudio() || UserInputVideo():
        throw conversionError(
          'unsupported function tool result content block type: '
          '${block.type.value}',
        );
    }
  }
  if (items.isEmpty) {
    throw conversionError('function tool result content is empty');
  }
  return items;
}

/// Port of `assistantGenTextToInputItem`.
Json assistantGenTextToInputItem(ContentBlock block) {
  final content = block.assistantGenText;
  if (content == null) throw conversionError('assistant generated text is nil');

  final text = <String, Object?>{'type': 'output_text', 'text': content.text};
  if (content.openAIExtension case final extension?) {
    text['annotations'] = [
      for (final annotation in extension.annotations)
        wrapConversion(
          'failed to convert text annotation to output text annotation',
          () => textAnnotationToOutputTextAnnotation(annotation),
        ),
    ];
  }

  final item = <String, Object?>{'type': 'message', 'role': 'assistant'};
  putNonEmpty(item, 'id', itemIdOf(block) ?? '');
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['content'] = [text];
  return item;
}

/// Port of `textAnnotationToOutputTextAnnotation`.
Json textAnnotationToOutputTextAnnotation(OpenAITextAnnotation annotation) {
  switch (annotation.type) {
    case OpenAITextAnnotationType.fileCitation:
      final citation = annotation.fileCitation;
      if (citation == null) throw conversionError('file citation is nil');
      return {
        'type': 'file_citation',
        'file_id': citation.fileId,
        'filename': citation.filename,
        'index': citation.index,
      };
    case OpenAITextAnnotationType.urlCitation:
      final citation = annotation.urlCitation;
      if (citation == null) throw conversionError('url citation is nil');
      return {
        'type': 'url_citation',
        'title': citation.title,
        'url': citation.url,
        'start_index': citation.startIndex,
        'end_index': citation.endIndex,
      };
    case OpenAITextAnnotationType.containerFileCitation:
      final citation = annotation.containerFileCitation;
      if (citation == null) {
        throw conversionError('container file citation is nil');
      }
      return {
        'type': 'container_file_citation',
        'container_id': citation.containerId,
        'start_index': citation.startIndex,
        'end_index': citation.endIndex,
        'file_id': citation.fileId,
        'filename': citation.filename,
      };
    case OpenAITextAnnotationType.filePath:
      final filePath = annotation.filePath;
      if (filePath == null) throw conversionError('file path is nil');
      return {
        'type': 'file_path',
        'file_id': filePath.fileId,
        'index': filePath.index,
      };
    default:
      throw conversionError(
        'invalid text annotation type: ${annotation.type?.value ?? ''}',
      );
  }
}

/// Port of `functionToolCallToInputItem`: a client tool search call goes
/// back as a `tool_search_call` item.
Json functionToolCallToInputItem(ContentBlock block) {
  final content = block.functionToolCall;
  if (content == null) throw conversionError('function tool call is nil');

  final id = itemIdOf(block) ?? '';
  final status = itemStatusOf(block) ?? '';

  if (isToolSearchToolCall(block)) {
    final item = <String, Object?>{'type': 'tool_search_call'};
    final arguments = _rawJson(content.arguments, 'tool search arguments');
    if (arguments.present) item['arguments'] = arguments.value;
    putNonEmpty(item, 'id', id);
    item['call_id'] = content.callId;
    putNonEmpty(item, 'status', status);
    item['execution'] = 'client';
    return item;
  }

  final item = <String, Object?>{'type': 'function_call'};
  putNonEmpty(item, 'id', id);
  putNonEmpty(item, 'status', status);
  item['call_id'] = content.callId;
  item['name'] = content.name;
  item['arguments'] = content.arguments;
  putNonEmpty(item, 'namespace', namespaceOf(block) ?? '');
  return item;
}

/// [text] as raw JSON embedded in a request (Go: `json.RawMessage`); an
/// empty text is left out.
({bool present, Object? value}) _rawJson(String text, String what) {
  if (text.isEmpty) return (present: false, value: null);
  try {
    return (present: true, value: jsonDecode(text));
  } on FormatException catch (error) {
    throw conversionError('invalid JSON in $what: ${error.message}');
  }
}

/// Port of `reasoningToInputItem`.
Json reasoningToInputItem(ContentBlock block) {
  final content = block.reasoning;
  if (content == null) throw conversionError('reasoning is nil');

  final item = <String, Object?>{
    'type': 'reasoning',
    'id': itemIdOf(block) ?? '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['summary'] = [
    {'type': 'summary_text', 'text': content.text},
  ];
  putNonEmpty(item, 'encrypted_content', content.signature);
  final raw = content.openAIExtension?.content ?? const [];
  if (raw.isNotEmpty) {
    item['content'] = [
      for (final c in raw) {'type': 'reasoning_text', 'text': c.text},
    ];
  }
  return item;
}

/// Port of `serverToolCallToInputItem`.
Json serverToolCallToInputItem(ContentBlock block) {
  final content = block.serverToolCall;
  final arguments = serverToolCallArgumentsOf(content);
  if (arguments.webSearch case final args?) {
    return webSearchToolCallToInputItem(args, block);
  }
  if (arguments.fileSearch case final args?) {
    return fileSearchToolCallToInputItem(args, block);
  }
  if (arguments.codeInterpreter case final args?) {
    return codeInterpreterToolCallToInputItem(args, block);
  }
  if (arguments.imageGeneration case final args?) {
    return imageGenerationToolCallToInputItem(args, block);
  }
  if (arguments.shell case final args?) {
    return shellToolCallToInputItem(args, block);
  }
  if (arguments.toolSearch case final args?) {
    return toolSearchToolCallToInputItem(args, content!.callId, block);
  }
  throw conversionError('server tool call arguments are nil');
}

/// Port of `webSearchToolCallToInputItem`.
Json webSearchToolCallToInputItem(
  OpenAIResponsesWebSearchArguments args,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'web_search_call',
    'id': itemIdOf(block) ?? '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['action'] = getWebSearchToolCallActionParam(args);
  return item;
}

/// The `action` of a web search call item. Port of
/// `getWebSearchToolCallActionParam`.
Json getWebSearchToolCallActionParam(OpenAIResponsesWebSearchArguments args) {
  final action = args.actionType;
  if (action == OpenAIResponsesWebSearchAction.search) {
    final queries = args.search?.queries ?? const <String>[];
    // `query` is a required field of the SDK's search action that Go never
    // sets, so it is always sent empty.
    return {
      'type': 'search',
      'query': '',
      if (queries.isNotEmpty) 'queries': queries,
    };
  }
  if (action == OpenAIResponsesWebSearchAction.openPage) {
    final page = <String, Object?>{'type': 'open_page'};
    putNonEmpty(page, 'url', args.openPage?.url ?? '');
    return page;
  }
  if (action == OpenAIResponsesWebSearchAction.find) {
    return {
      'type': 'find',
      'url': args.find?.url ?? '',
      'pattern': args.find?.pattern ?? '',
    };
  }
  throw conversionError(
    'unknown web search action type: ${action?.value ?? ''}',
  );
}

/// Port of `fileSearchToolCallToInputItem`. `queries` is always sent: the
/// API requires it, and Go sends the list a response carried even when it
/// is empty (only a list that was never set is left out there).
Json fileSearchToolCallToInputItem(
  OpenAIResponsesFileSearchArguments args,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'file_search_call',
    'id': itemIdOf(block) ?? '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['queries'] = args.queries;
  return item;
}

/// Port of `codeInterpreterToolCallToInputItem`.
Json codeInterpreterToolCallToInputItem(
  OpenAIResponsesCodeInterpreterArguments args,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'code_interpreter_call',
    'id': itemIdOf(block) ?? '',
    'container_id': '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  return item;
}

/// Port of `imageGenerationToolCallToInputItem`.
Json imageGenerationToolCallToInputItem(
  OpenAIResponsesImageGenerationArguments args,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'image_generation_call',
    'id': itemIdOf(block) ?? '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  return item;
}

/// Port of `shellToolCallToInputItem`. Go dereferences the action and the
/// local environment without a check, so it panics on a call the API
/// returned without commands or with a local environment (whose `Local`
/// part Go's reader never fills); here the first is an error and the second
/// is sent with the skills it has (none, from a response).
Json shellToolCallToInputItem(
  OpenAIResponsesShellArguments args,
  ContentBlock block,
) {
  final callId = block.serverToolCall?.callId ?? '';
  final action = args.action;
  if (action == null) throw conversionError('shell action is nil');

  final actionJson = <String, Object?>{'commands': action.commands};
  if (action.timeoutMs > 0) actionJson['timeout_ms'] = action.timeoutMs;
  if (action.maxOutputLength > 0) {
    actionJson['max_output_length'] = action.maxOutputLength;
  }

  Json? environment;
  if (args.environment case final env?) {
    if (env.type == OpenAIResponsesShellEnvironmentType.local) {
      environment = {
        'type': 'local',
        'skills': [
          for (final skill in env.local?.skills ??
              const <OpenAIResponsesShellEnvironmentLocalSkill>[])
            {
              'name': skill.name,
              'description': skill.description,
              'path': skill.path,
            },
        ],
      };
    } else if (env.type ==
        OpenAIResponsesShellEnvironmentType.containerReference) {
      environment = {
        'type': 'container_reference',
        'container_id': env.containerReference?.containerId ?? '',
      };
    } else {
      throw conversionError(
        'unknown shell environment type: ${env.type?.value ?? ''}',
      );
    }
  }

  final item = <String, Object?>{'type': 'shell_call'};
  putNonEmpty(item, 'id', itemIdOf(block) ?? '');
  item['call_id'] = callId;
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['action'] = actionJson;
  if (environment != null) item['environment'] = environment;
  return item;
}

/// Port of `serverToolResultToInputItem`.
Json serverToolResultToInputItem(ContentBlock block) {
  final content = block.serverToolResult;
  final result = serverToolResultOf(content);
  if (result.webSearch case final r?) {
    return webSearchToolResultToInputItem(r, block);
  }
  if (result.fileSearch case final r?) {
    return fileSearchToolResultToInputItem(r, block);
  }
  if (result.codeInterpreter case final r?) {
    return codeInterpreterToolResultToInputItem(r, block);
  }
  if (result.imageGeneration case final r?) {
    return imageGenerationToolResultToInputItem(r, block);
  }
  if (result.shell case final r?) {
    return shellToolResultToInputItem(r, block);
  }
  if (result.toolSearch case final r?) {
    return toolSearchToolResultToInputItem(r, content!.callId, block);
  }
  throw conversionError('server tool result is nil');
}

/// The server-side tool search call item of [args]. Port of
/// `getToolSearchCallActionParam` and `toolSearchToolCallToInputItem`.
Json toolSearchToolCallToInputItem(
  OpenAIResponsesToolSearchArguments args,
  String callId,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'tool_search_call',
    if (args.arguments != null) 'arguments': args.arguments,
    'execution': 'server',
  };
  putNonEmpty(item, 'call_id', callId);
  putNonEmpty(item, 'id', itemIdOf(block) ?? '');
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  return item;
}

/// The server-side tool search output item of [result] (without ids). Port
/// of `getToolSearchResultActionParam`.
Json getToolSearchResultActionParam(OpenAIResponsesToolSearchResult result) => {
      'type': 'tool_search_output',
      'tools': toDeferredFunctionTools(result.tools),
      'execution': 'server',
    };

/// Port of `toolSearchToolResultToInputItem`.
Json toolSearchToolResultToInputItem(
  OpenAIResponsesToolSearchResult result,
  String callId,
  ContentBlock block,
) {
  final item = getToolSearchResultActionParam(result);
  putNonEmpty(item, 'call_id', callId);
  putNonEmpty(item, 'id', itemIdOf(block) ?? '');
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  return item;
}

/// Port of `webSearchToolResultToInputItem`.
Json webSearchToolResultToInputItem(
  OpenAIResponsesWebSearchResult result,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'web_search_call',
    'id': itemIdOf(block) ?? '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['action'] = getWebSearchToolResultActionParam(result);
  return item;
}

/// The `action` of the web search call item of a result. Port of
/// `getWebSearchToolResultActionParam`.
Json getWebSearchToolResultActionParam(OpenAIResponsesWebSearchResult result) {
  if (result.actionType == OpenAIResponsesWebSearchAction.search) {
    final sources = result.search?.sources ??
        const <OpenAIResponsesWebSearchQuerySource>[];
    // Go always sends `sources` (a slice it makes) and the empty required
    // `query`.
    return {
      'type': 'search',
      'query': '',
      'sources': [
        for (final source in sources) {'type': 'url', 'url': source.url},
      ],
    };
  }
  throw conversionError(
    'unknown web search result action type: '
    '${result.actionType?.value ?? ''}',
  );
}

/// Port of `fileSearchToolResultToInputItem`.
Json fileSearchToolResultToInputItem(
  OpenAIResponsesFileSearchResult result,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'file_search_call',
    'id': itemIdOf(block) ?? '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['results'] = [
    for (final r in result.results)
      <String, Object?>{
        if (r.fileId.isNotEmpty) 'file_id': r.fileId,
        if (r.fileName.isNotEmpty) 'filename': r.fileName,
        'score': r.score,
        if (r.text.isNotEmpty) 'text': r.text,
        'attributes': {
          for (final MapEntry(:key, :value) in r.attributes.entries)
            key: value.ofString ?? value.ofFloat ?? value.ofBool,
        },
      },
  ];
  return item;
}

/// Port of `codeInterpreterToolResultToInputItem`.
Json codeInterpreterToolResultToInputItem(
  OpenAIResponsesCodeInterpreterResult result,
  ContentBlock block,
) {
  final outputs = <Json>[];
  for (final output in result.outputs) {
    if (output.type == OpenAIResponsesCodeInterpreterOutputType.logs) {
      if (output.logs case final logs?) {
        outputs.add({'type': 'logs', 'logs': logs.logs});
      }
    } else if (output.type == OpenAIResponsesCodeInterpreterOutputType.image) {
      if (output.image case final image?) {
        outputs.add({'type': 'image', 'url': image.url});
      }
    } else {
      throw conversionError(
        'unknown code interpreter output type: ${output.type?.value ?? ''}',
      );
    }
  }

  final item = <String, Object?>{
    'type': 'code_interpreter_call',
    'id': itemIdOf(block) ?? '',
    'container_id': result.containerId,
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  putNonEmpty(item, 'code', result.code);
  item['outputs'] = outputs;
  return item;
}

/// Port of `imageGenerationToolResultToInputItem`.
Json imageGenerationToolResultToInputItem(
  OpenAIResponsesImageGenerationResult result,
  ContentBlock block,
) {
  final item = <String, Object?>{
    'type': 'image_generation_call',
    'id': itemIdOf(block) ?? '',
  };
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  putNonEmpty(item, 'result', result.imageBase64);
  return item;
}

/// Port of `shellToolResultToInputItem`.
Json shellToolResultToInputItem(
  OpenAIResponsesShellResult result,
  ContentBlock block,
) {
  final callId = block.serverToolResult?.callId ?? '';
  final output = <Json>[];
  for (final o in result.outputs) {
    Json? outcome;
    if (o.outcome case final oc?) {
      if (oc.type == OpenAIResponsesShellOutputOutcomeType.timeout) {
        outcome = {'type': 'timeout'};
      } else if (oc.type == OpenAIResponsesShellOutputOutcomeType.exit) {
        if (oc.exit case final exit?) {
          outcome = {'type': 'exit', 'exit_code': exit.exitCode};
        }
      } else {
        throw conversionError(
          'unknown shell output outcome type: ${oc.type?.value ?? ''}',
        );
      }
    }
    output.add({
      'stdout': o.stdout,
      'stderr': o.stderr,
      if (outcome != null) 'outcome': outcome,
    });
  }

  final item = <String, Object?>{'type': 'shell_call_output'};
  putNonEmpty(item, 'id', itemIdOf(block) ?? '');
  item['call_id'] = callId;
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  item['output'] = output;
  if (result.maxOutputLength > 0) {
    item['max_output_length'] = result.maxOutputLength;
  }
  return item;
}

/// Port of `mcpToolApprovalRequestToInputItem`.
Json mcpToolApprovalRequestToInputItem(ContentBlock block) {
  final content = block.mcpToolApprovalRequest;
  if (content == null) {
    throw conversionError('mcp tool approval request is nil');
  }
  return {
    'type': 'mcp_approval_request',
    'id': itemIdOf(block) ?? '',
    'server_label': content.serverLabel,
    'name': content.name,
    'arguments': content.arguments,
  };
}

/// Port of `mcpToolApprovalResponseToInputItem`.
Json mcpToolApprovalResponseToInputItem(
  AgenticMcpToolApprovalResponse block,
) {
  final item = <String, Object?>{
    'type': 'mcp_approval_response',
    'approval_request_id': block.approvalRequestId,
    'approve': block.approve,
  };
  putNonEmpty(item, 'reason', block.reason);
  return item;
}

/// Port of `mcpListToolsResultToInputItem`.
Json mcpListToolsResultToInputItem(ContentBlock block) {
  final content = block.mcpListToolsResult;
  if (content == null) throw conversionError('mcp list tools result is nil');
  final item = <String, Object?>{
    'type': 'mcp_list_tools',
    'id': itemIdOf(block) ?? '',
    'server_label': content.serverLabel,
    'tools': [
      for (final tool in content.tools)
        <String, Object?>{
          'name': tool.name,
          if (tool.description.isNotEmpty) 'description': tool.description,
          if (tool.inputSchema case final schema?) 'input_schema': schema,
        },
    ],
  };
  putNonEmpty(item, 'error', content.error);
  return item;
}

/// Port of `mcpToolCallToInputItem`.
Json mcpToolCallToInputItem(ContentBlock block) {
  final content = block.mcpToolCall;
  if (content == null) throw conversionError('mcp tool call is nil');
  final item = <String, Object?>{
    'type': 'mcp_call',
    'id': itemIdOf(block) ?? '',
    'server_label': content.serverLabel,
    'name': content.name,
    'arguments': content.arguments,
  };
  putNonEmpty(item, 'approval_request_id', content.approvalRequestId);
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  return item;
}

/// Port of `mcpToolResultToInputItem`.
Json mcpToolResultToInputItem(ContentBlock block) {
  final content = block.mcpToolResult;
  if (content == null) throw conversionError('MCP tool result is nil');
  final item = <String, Object?>{
    'type': 'mcp_call',
    'id': itemIdOf(block) ?? '',
    'server_label': content.serverLabel,
    'name': content.name,
    'arguments': '',
  };
  putNonEmpty(item, 'error', content.error?.message ?? '');
  putNonEmpty(item, 'output', content.content);
  putNonEmpty(item, 'status', itemStatusOf(block) ?? '');
  return item;
}

// ---------------------------------------------------------------------------
// Request: tools and tool choice
// ---------------------------------------------------------------------------

/// The parameters JSON Schema of [tool], or `null` for a tool without
/// parameters: the raw document when there is one (P12), else the
/// converted [JSONSchema].
Json? _toolParameters(ToolInfo tool) {
  if (tool.function.parametersJsonSchema case final raw?) return raw;
  if (tool.function.parameters == null) return null;
  final function =
      OpenAIConverters.toolInfoToOpenAI(tool)['function'] as Map<String, dynamic>;
  return asJsonObject(function['parameters']);
}

/// The `tools[]` entry of a function tool. Port of `toFunctionTool`.
Json toFunctionTool(ToolInfo tool) {
  final item = <String, Object?>{'type': 'function', 'name': tool.name};
  putNonEmpty(item, 'description', tool.desc ?? '');
  if (_toolParameters(tool) case final parameters?) {
    item['parameters'] = parameters;
  }
  return item;
}

/// Port of `toFunctionTools`.
List<Json> toFunctionTools(List<ToolInfo> tools) =>
    [for (final tool in tools) toFunctionTool(tool)];

/// Function tools the model sees only through tool search
/// (`defer_loading: true`). Port of `toDeferredFunctionTools`.
List<Json> toDeferredFunctionTools(List<ToolInfo> tools) => [
      for (final tool in tools) {...toFunctionTool(tool), 'defer_loading': true},
    ];

/// The function tools of a tool search output. Port of `fromFunctionTools`:
/// entries of other types are skipped.
List<ToolInfo> fromFunctionTools(List<Json> tools) => [
      for (final tool in tools)
        if (tool['type'] == 'function')
          wrapConversion(
            'failed to unmarshal JSON schema from function tool',
            () {
              final name = jsonString(tool, 'name');
              final desc = tool['description'] is String
                  ? tool['description']! as String
                  : null;
              final parameters = jsonObject(tool, 'parameters');
              return parameters == null
                  ? ToolInfo.fromParamsOneOf(name: name, desc: desc)
                  : ToolInfo.fromJsonSchemaMap(
                      name: name,
                      desc: desc,
                      schema: parameters,
                    );
            },
          ),
    ];

/// Port of `toServerTools`.
List<Json> toServerTools(List<OpenAIResponsesServerTool> tools) =>
    [for (final tool in tools) tool.toJson()];

/// The `tools` of a `tool_choice` restriction. Port of `toAllowedTools`: a
/// function tool without a name is Go's empty `AllowedTool`, an error.
List<Json> toAllowedTools(List<AllowedTool> tools) => [
      for (final tool in tools)
        switch (tool) {
          AllowedFunctionTool(:final name) when name.isEmpty =>
            throw conversionError('unknown allowed tool type'),
          AllowedFunctionTool(:final name) => {'type': 'function', 'name': name},
          AllowedMcpTool(:final serverLabel, :final name) => {
              'type': 'mcp',
              'server_label': serverLabel,
              if (name.isNotEmpty) 'name': name,
            },
          AllowedServerTool(:final name) => {'type': name},
        },
    ];

/// The `tool_choice` field for [choice], or `null` for none. Port of
/// `populateToolChoice`. An empty tool list stands for Go's nil list.
Object? toToolChoice(AgenticToolChoice? choice) {
  if (choice == null) return null;
  switch (choice.type) {
    case ToolChoice.forbidden:
      return 'none';
    case ToolChoice.allowed:
      final tools = choice.allowed?.tools ?? const <AllowedTool>[];
      if (tools.isEmpty) return 'auto';
      return {
        'type': 'allowed_tools',
        'mode': 'auto',
        'tools': toAllowedTools(tools),
      };
    case ToolChoice.forced:
      final tools = choice.forced?.tools ?? const <AllowedTool>[];
      if (tools.isEmpty) return 'required';
      return {
        'type': 'allowed_tools',
        'mode': 'required',
        'tools': toAllowedTools(tools),
      };
  }
}

// ---------------------------------------------------------------------------
// Response: output items
// ---------------------------------------------------------------------------

/// The assistant message of a complete response. Port of `toOutputMessage`.
AgenticMessage toOutputMessage(Json response, ChatModelOptions options) {
  final blocks = <ContentBlock>[];
  for (final item in jsonObjectList(response, 'output')) {
    final type = jsonString(item, 'type');
    blocks.addAll(
      switch (type) {
        'reasoning' => [
            wrapConversion(
              'failed to convert reasoning to content block',
              () => reasoningToContentBlocks(item),
            ),
          ],
        'message' => wrapConversion(
            'failed to convert output message to content blocks',
            () => outputMessageToContentBlocks(item),
          ),
        'function_call' => [
            wrapConversion(
              'failed to convert function tool call to content block',
              () => functionToolCallToContentBlock(item),
            ),
          ],
        'mcp_list_tools' => [
            wrapConversion(
              'failed to convert MCP list tools to content block',
              () => mcpListToolsToContentBlock(item),
            ),
          ],
        'mcp_call' => wrapConversion(
            'failed to convert MCP call to content block',
            () => mcpCallToContentBlocks(item),
          ),
        'mcp_approval_request' => [
            wrapConversion(
              'failed to convert MCP approval request to content block',
              () => mcpApprovalRequestToContentBlock(item),
            ),
          ],
        'web_search_call' => wrapConversion(
            'failed to convert web search to content block',
            () => webSearchToContentBlocks(item),
          ),
        'file_search_call' => wrapConversion(
            'failed to convert file search to content block',
            () => fileSearchToContentBlocks(item),
          ),
        'code_interpreter_call' => wrapConversion(
            'failed to convert code interpreter to content block',
            () => codeInterpreterToContentBlocks(item),
          ),
        'image_generation_call' => wrapConversion(
            'failed to convert image generation to content block',
            () => imageGenerationToContentBlocks(item),
          ),
        'shell_call' => [
            wrapConversion(
              'failed to convert function shell call to content block',
              () => shellCallToContentBlock(item),
            ),
          ],
        'shell_call_output' => [
            wrapConversion(
              'failed to convert function shell output to content block',
              () => shellOutputToContentBlock(item),
            ),
          ],
        'tool_search_call' => [
            wrapConversion(
              'failed to convert tool search call to content block',
              () => toolSearchToolCallToContentBlock(item, options),
            ),
          ],
        'tool_search_output' => [
            wrapConversion(
              'failed to convert tool search output item to content block',
              () => toolSearchToolResultToContentBlock(item),
            ),
          ],
        _ => throw conversionError('unknown output item type: $type'),
      },
    );
  }
  return AgenticMessage(
    role: AgenticRoleType.assistant,
    contentBlocks: blocks,
    responseMeta: responseObjectToResponseMeta(response),
  );
}

ContentBlock _withIdAndStatus(ContentBlock block, Json item) {
  var out = withItemId(block, jsonString(item, 'id'));
  final status = jsonString(item, 'status');
  if (status.isNotEmpty) out = withItemStatus(out, status);
  return out;
}

/// Port of `outputMessageToContentBlocks`.
List<ContentBlock> outputMessageToContentBlocks(Json item) => [
      for (final content in jsonObjectList(item, 'content'))
        _withIdAndStatus(
          switch (jsonString(content, 'type')) {
            'output_text' => wrapConversion(
                'failed to convert output text to content block',
                () => outputContentTextToContentBlock(content),
              ),
            'refusal' => ContentBlock(
                AssistantGenText(
                  openAIExtension: OpenAIAssistantGenTextExtension(
                    refusal: OpenAIOutputRefusal(
                      reason: jsonString(content, 'refusal'),
                    ),
                  ),
                ),
              ),
            final type => throw conversionError(
                'unknown output message content type: $type',
              ),
          },
          item,
        ),
    ];

/// Port of `outputContentTextToContentBlock`.
ContentBlock outputContentTextToContentBlock(Json text) => ContentBlock(
      AssistantGenText(
        text: jsonString(text, 'text'),
        openAIExtension: OpenAIAssistantGenTextExtension(
          annotations: [
            for (final annotation in jsonObjectList(text, 'annotations'))
              wrapConversion(
                'failed to convert text annotation',
                () => outputTextAnnotationToTextAnnotation(annotation),
              ),
          ],
        ),
      ),
    );

/// Port of `outputTextAnnotationToTextAnnotation`.
OpenAITextAnnotation outputTextAnnotationToTextAnnotation(Json annotation) {
  final type = jsonString(annotation, 'type');
  return switch (type) {
    'file_citation' => OpenAITextAnnotation(
        type: OpenAITextAnnotationType.fileCitation,
        fileCitation: OpenAITextAnnotationFileCitation(
          index: jsonInt(annotation, 'index'),
          fileId: jsonString(annotation, 'file_id'),
          filename: jsonString(annotation, 'filename'),
        ),
      ),
    'url_citation' => OpenAITextAnnotation(
        type: OpenAITextAnnotationType.urlCitation,
        urlCitation: OpenAITextAnnotationUrlCitation(
          title: jsonString(annotation, 'title'),
          url: jsonString(annotation, 'url'),
          startIndex: jsonInt(annotation, 'start_index'),
          endIndex: jsonInt(annotation, 'end_index'),
        ),
      ),
    'container_file_citation' => OpenAITextAnnotation(
        type: OpenAITextAnnotationType.containerFileCitation,
        containerFileCitation: OpenAITextAnnotationContainerFileCitation(
          containerId: jsonString(annotation, 'container_id'),
          fileId: jsonString(annotation, 'file_id'),
          filename: jsonString(annotation, 'filename'),
          startIndex: jsonInt(annotation, 'start_index'),
          endIndex: jsonInt(annotation, 'end_index'),
        ),
      ),
    'file_path' => OpenAITextAnnotation(
        type: OpenAITextAnnotationType.filePath,
        filePath: OpenAITextAnnotationFilePath(
          fileId: jsonString(annotation, 'file_id'),
          index: jsonInt(annotation, 'index'),
        ),
      ),
    _ => throw conversionError('unknown annotation type: $type'),
  };
}

/// Port of `functionToolCallToContentBlock`.
ContentBlock functionToolCallToContentBlock(Json item) {
  var block = _withIdAndStatus(
    ContentBlock(
      FunctionToolCall(
        callId: jsonString(item, 'call_id'),
        name: jsonString(item, 'name'),
        arguments: jsonString(item, 'arguments'),
      ),
    ),
    item,
  );
  final namespace = jsonString(item, 'namespace');
  if (namespace.isNotEmpty) block = withNamespace(block, namespace);
  return block;
}

/// The call and result blocks of a server tool item.
List<ContentBlock> _serverToolBlocks(
  OpenAIResponsesServerToolName name,
  OpenAIResponsesServerToolCallArguments arguments,
  OpenAIResponsesServerToolResult? result,
  Json item,
) =>
    [
      _withIdAndStatus(
        ContentBlock(ServerToolCall(name: name.value, arguments: arguments)),
        item,
      ),
      _withIdAndStatus(
        ContentBlock(ServerToolResult(name: name.value, content: result)),
        item,
      ),
    ];

/// Port of `webSearchToContentBlocks`: a search action has a result (its
/// sources), an open-page or find action has none.
List<ContentBlock> webSearchToContentBlocks(Json item) {
  final action = jsonObject(item, 'action');
  final OpenAIResponsesServerToolCallArguments arguments;
  OpenAIResponsesServerToolResult? result;
  switch (jsonString(action, 'type')) {
    case 'search':
      arguments = OpenAIResponsesServerToolCallArguments(
        webSearch: OpenAIResponsesWebSearchArguments(
          actionType: OpenAIResponsesWebSearchAction.search,
          search: OpenAIResponsesWebSearchQuery(
            queries: jsonStringList(action, 'queries'),
          ),
        ),
      );
      result = OpenAIResponsesServerToolResult(
        webSearch: OpenAIResponsesWebSearchResult(
          actionType: OpenAIResponsesWebSearchAction.search,
          search: OpenAIResponsesWebSearchQueryResult(
            sources: [
              for (final source in jsonObjectList(action, 'sources'))
                OpenAIResponsesWebSearchQuerySource(
                  url: jsonString(source, 'url'),
                ),
            ],
          ),
        ),
      );
    case 'open_page':
      arguments = OpenAIResponsesServerToolCallArguments(
        webSearch: OpenAIResponsesWebSearchArguments(
          actionType: OpenAIResponsesWebSearchAction.openPage,
          openPage: OpenAIResponsesWebSearchOpenPage(
            url: jsonString(action, 'url'),
          ),
        ),
      );
    case 'find':
      arguments = OpenAIResponsesServerToolCallArguments(
        webSearch: OpenAIResponsesWebSearchArguments(
          actionType: OpenAIResponsesWebSearchAction.find,
          find: OpenAIResponsesWebSearchFind(
            url: jsonString(action, 'url'),
            pattern: jsonString(action, 'pattern'),
          ),
        ),
      );
    default:
      throw conversionError(
        'unknown web search variant type: ${jsonString(item, 'type')}',
      );
  }
  return _serverToolBlocks(
    OpenAIResponsesServerToolName.webSearch,
    arguments,
    result,
    item,
  );
}

/// Port of `toolSearchToolCallToContentBlock`: a client-side search becomes
/// a call of the tool search tool of [options], a server-side one a server
/// tool call.
ContentBlock toolSearchToolCallToContentBlock(
  Json item,
  ChatModelOptions options,
) {
  final callId = jsonString(item, 'call_id');
  final status = jsonString(item, 'status');
  switch (jsonString(item, 'execution')) {
    case 'client':
      final tool = options.toolSearchTool;
      if (tool == null) {
        throw conversionError(
          "haven't set client tool search tool, but get a client tool search "
          'tool call',
        );
      }
      var block = ContentBlock(
        FunctionToolCall(
          callId: callId,
          name: tool.name,
          // Go: `json.Marshal(item.Arguments)` (sorted keys, HTML escaped).
          arguments: goJsonMarshal(item['arguments']),
        ),
      );
      block = withItemId(block, jsonString(item, 'id'));
      block = withItemStatus(block, status);
      return withToolSearchToolCall(block);
    case 'server':
      final block = ContentBlock(
        ServerToolCall(
          callId: callId,
          arguments: OpenAIResponsesServerToolCallArguments(
            toolSearch: OpenAIResponsesToolSearchArguments(
              arguments: item['arguments'],
            ),
          ),
        ),
      );
      return withItemStatus(withItemId(block, jsonString(item, 'id')), status);
    case final execution:
      throw conversionError('invalid tool search execution type: $execution');
  }
}

/// Port of `toolSearchToolResultToContentBlock`.
ContentBlock toolSearchToolResultToContentBlock(Json item) {
  final tools = fromFunctionTools(jsonObjectList(item, 'tools'));
  final block = ContentBlock(
    ServerToolResult(
      callId: jsonString(item, 'call_id'),
      content: OpenAIResponsesServerToolResult(
        toolSearch: OpenAIResponsesToolSearchResult(tools: tools),
      ),
    ),
  );
  return withItemStatus(
    withItemId(block, jsonString(item, 'id')),
    jsonString(item, 'status'),
  );
}

/// Port of `fileSearchToContentBlocks`.
List<ContentBlock> fileSearchToContentBlocks(Json item) {
  final results = <OpenAIResponsesFileSearchResultItem>[];
  for (final r in jsonObjectList(item, 'results')) {
    final attributes = <String, OpenAIResponsesFileSearchAttribute>{};
    for (final MapEntry(:key, :value)
        in (jsonObject(r, 'attributes') ?? const <String, Object?>{}).entries) {
      switch (value) {
        case final String s:
          attributes[key] = OpenAIResponsesFileSearchAttribute(ofString: s);
        case final num n:
          attributes[key] =
              OpenAIResponsesFileSearchAttribute(ofFloat: n.toDouble());
        case final bool b:
          attributes[key] = OpenAIResponsesFileSearchAttribute(ofBool: b);
      }
    }
    results.add(
      OpenAIResponsesFileSearchResultItem(
        fileId: jsonString(r, 'file_id'),
        fileName: jsonString(r, 'filename'),
        score: jsonDouble(r, 'score'),
        text: jsonString(r, 'text'),
        attributes: attributes,
      ),
    );
  }
  return _serverToolBlocks(
    OpenAIResponsesServerToolName.fileSearch,
    OpenAIResponsesServerToolCallArguments(
      fileSearch: OpenAIResponsesFileSearchArguments(
        queries: jsonStringList(item, 'queries'),
      ),
    ),
    OpenAIResponsesServerToolResult(
      fileSearch: OpenAIResponsesFileSearchResult(results: results),
    ),
    item,
  );
}

/// Port of `codeInterpreterToContentBlocks`: an output without a type (the
/// partial items of a stream) is skipped.
List<ContentBlock> codeInterpreterToContentBlocks(Json item) {
  final outputs = <OpenAIResponsesCodeInterpreterOutput>[];
  for (final output in jsonObjectList(item, 'outputs')) {
    switch (jsonString(output, 'type')) {
      case '':
        break;
      case 'logs':
        outputs.add(
          OpenAIResponsesCodeInterpreterOutput(
            type: OpenAIResponsesCodeInterpreterOutputType.logs,
            logs: OpenAIResponsesCodeInterpreterOutputLogs(
              logs: jsonString(output, 'logs'),
            ),
          ),
        );
      case 'image':
        outputs.add(
          OpenAIResponsesCodeInterpreterOutput(
            type: OpenAIResponsesCodeInterpreterOutputType.image,
            image: OpenAIResponsesCodeInterpreterOutputImage(
              url: jsonString(output, 'url'),
            ),
          ),
        );
      case final type:
        throw conversionError('unknown code interpreter output type: $type');
    }
  }
  return _serverToolBlocks(
    OpenAIResponsesServerToolName.codeInterpreter,
    const OpenAIResponsesServerToolCallArguments(
      codeInterpreter: OpenAIResponsesCodeInterpreterArguments(),
    ),
    OpenAIResponsesServerToolResult(
      codeInterpreter: OpenAIResponsesCodeInterpreterResult(
        code: jsonString(item, 'code'),
        containerId: jsonString(item, 'container_id'),
        outputs: outputs,
      ),
    ),
    item,
  );
}

/// Port of `imageGenerationToContentBlocks`.
List<ContentBlock> imageGenerationToContentBlocks(Json item) =>
    _serverToolBlocks(
      OpenAIResponsesServerToolName.imageGeneration,
      const OpenAIResponsesServerToolCallArguments(
        imageGeneration: OpenAIResponsesImageGenerationArguments(),
      ),
      OpenAIResponsesServerToolResult(
        imageGeneration: OpenAIResponsesImageGenerationResult(
          imageBase64: jsonString(item, 'result'),
        ),
      ),
      item,
    );

/// Port of `shellCallToContentBlock`: an environment without a type (the
/// partial items of a stream) is left out.
ContentBlock shellCallToContentBlock(Json item) {
  final environment = jsonObject(item, 'environment');
  final OpenAIResponsesShellEnvironment? env;
  switch (jsonString(environment, 'type')) {
    case '':
      env = null;
    case 'local':
      env = const OpenAIResponsesShellEnvironment(
        type: OpenAIResponsesShellEnvironmentType.local,
      );
    case 'container_reference':
      env = OpenAIResponsesShellEnvironment(
        type: OpenAIResponsesShellEnvironmentType.containerReference,
        containerReference: OpenAIResponsesShellEnvironmentContainerReference(
          containerId: jsonString(environment, 'container_id'),
        ),
      );
    case final type:
      throw conversionError('unknown shell environment type: $type');
  }

  final action = jsonObject(item, 'action');
  final commands = jsonStringList(action, 'commands');
  return _withIdAndStatus(
    ContentBlock(
      ServerToolCall(
        name: OpenAIResponsesServerToolName.shell.value,
        callId: jsonString(item, 'call_id'),
        arguments: OpenAIResponsesServerToolCallArguments(
          shell: OpenAIResponsesShellArguments(
            action: commands.isEmpty
                ? null
                : OpenAIResponsesShellAction(
                    commands: commands,
                    timeoutMs: jsonInt(action, 'timeout_ms'),
                    maxOutputLength: jsonInt(action, 'max_output_length'),
                  ),
            environment: env,
            createdBy: jsonString(item, 'created_by'),
          ),
        ),
      ),
    ),
    item,
  );
}

/// Port of `shellOutputToContentBlock`.
ContentBlock shellOutputToContentBlock(Json item) {
  final outputs = <OpenAIResponsesShellOutputItem>[];
  for (final o in jsonObjectList(item, 'output')) {
    final outcome = jsonObject(o, 'outcome');
    final OpenAIResponsesShellOutputOutcome? oc;
    switch (jsonString(outcome, 'type')) {
      case '':
        oc = null;
      case 'timeout':
        oc = const OpenAIResponsesShellOutputOutcome(
          type: OpenAIResponsesShellOutputOutcomeType.timeout,
        );
      case 'exit':
        oc = OpenAIResponsesShellOutputOutcome(
          type: OpenAIResponsesShellOutputOutcomeType.exit,
          exit: OpenAIResponsesShellOutputOutcomeExit(
            exitCode: jsonInt(outcome, 'exit_code'),
          ),
        );
      case final type:
        throw conversionError('unknown shell output outcome type: $type');
    }
    outputs.add(
      OpenAIResponsesShellOutputItem(
        stdout: jsonString(o, 'stdout'),
        stderr: jsonString(o, 'stderr'),
        outcome: oc,
        createdBy: jsonString(o, 'created_by'),
      ),
    );
  }
  return _withIdAndStatus(
    ContentBlock(
      ServerToolResult(
        name: OpenAIResponsesServerToolName.shell.value,
        callId: jsonString(item, 'call_id'),
        content: OpenAIResponsesServerToolResult(
          shell: OpenAIResponsesShellResult(
            maxOutputLength: jsonInt(item, 'max_output_length'),
            outputs: outputs,
            createdBy: jsonString(item, 'created_by'),
          ),
        ),
      ),
    ),
    item,
  );
}

/// Port of `reasoningToContentBlocks`: the summary parts are joined with
/// line breaks; the raw reasoning text goes to the OpenAI extension.
ContentBlock reasoningToContentBlocks(Json item) {
  final summary = [
    for (final s in jsonObjectList(item, 'summary')) jsonString(s, 'text'),
  ].join('\n');
  final content = jsonObjectList(item, 'content');
  return _withIdAndStatus(
    ContentBlock(
      Reasoning(
        text: summary,
        signature: jsonString(item, 'encrypted_content'),
        openAIExtension: content.isEmpty
            ? null
            : OpenAIReasoningExtension(
                content: [
                  for (final c in content)
                    OpenAIReasoningContent(text: jsonString(c, 'text')),
                ],
              ),
      ),
    ),
    item,
  );
}

/// Port of `mcpCallToContentBlocks`: an MCP call item is a call block and a
/// result block.
List<ContentBlock> mcpCallToContentBlocks(Json item) {
  final id = jsonString(item, 'id');
  final error = jsonString(item, 'error');
  return [
    withItemId(
      ContentBlock(
        AgenticMcpToolCall(
          serverLabel: jsonString(item, 'server_label'),
          approvalRequestId: jsonString(item, 'approval_request_id'),
          name: jsonString(item, 'name'),
          arguments: jsonString(item, 'arguments'),
        ),
      ),
      id,
    ),
    withItemId(
      ContentBlock(
        AgenticMcpToolResult(
          serverLabel: jsonString(item, 'server_label'),
          name: jsonString(item, 'name'),
          content: jsonString(item, 'output'),
          error: error.isEmpty ? null : AgenticMcpToolCallError(message: error),
        ),
      ),
      id,
    ),
  ];
}

/// Port of `mcpListToolsToContentBlock`.
ContentBlock mcpListToolsToContentBlock(Json item) {
  final tools = <AgenticMcpListToolsItem>[];
  for (final tool in jsonObjectList(item, 'tools')) {
    final schema = tool['input_schema'];
    if (schema != null && asJsonObject(schema) == null) {
      throw conversionError(
        'failed to unmarshal tool input schema: not a JSON object',
      );
    }
    tools.add(
      AgenticMcpListToolsItem(
        name: jsonString(tool, 'name'),
        description: jsonString(tool, 'description'),
        inputSchema: asJsonObject(schema) ?? const {},
      ),
    );
  }
  return withItemId(
    ContentBlock(
      AgenticMcpListToolsResult(
        serverLabel: jsonString(item, 'server_label'),
        tools: tools,
        error: jsonString(item, 'error'),
      ),
    ),
    jsonString(item, 'id'),
  );
}

/// Port of `mcpApprovalRequestToContentBlock`.
ContentBlock mcpApprovalRequestToContentBlock(Json item) => withItemId(
      ContentBlock(
        AgenticMcpToolApprovalRequest(
          id: jsonString(item, 'id'),
          serverLabel: jsonString(item, 'server_label'),
          name: jsonString(item, 'name'),
          arguments: jsonString(item, 'arguments'),
        ),
      ),
      jsonString(item, 'id'),
    );

/// The response meta of a response object. Port of
/// `responseObjectToResponseMeta`.
AgenticResponseMeta responseObjectToResponseMeta(Json response) =>
    AgenticResponseMeta(
      tokenUsage: toTokenUsage(response),
      openAIExtension: toResponseMetaExtension(response),
    );

/// The token usage of a response object (zeros when it has none). Port of
/// `toTokenUsage`.
TokenUsage toTokenUsage(Json response) {
  final usage = jsonObject(response, 'usage');
  final input = jsonObject(usage, 'input_tokens_details');
  final output = jsonObject(usage, 'output_tokens_details');
  return TokenUsage(
    promptTokens: jsonInt(usage, 'input_tokens'),
    promptTokenDetails: PromptTokenDetails(
      cachedTokens: jsonInt(input, 'cached_tokens'),
      cacheWriteTokens: jsonInt(input, 'cache_write_tokens'),
    ),
    completionTokens: jsonInt(usage, 'output_tokens'),
    completionTokenDetails: CompletionTokenDetails(
      reasoningTokens: jsonInt(output, 'reasoning_tokens'),
    ),
    totalTokens: jsonInt(usage, 'total_tokens'),
  );
}

/// The OpenAI response meta extension of a response object. Port of
/// `toResponseMetaExtension`.
OpenAIResponseMetaExtension toResponseMetaExtension(Json response) {
  final incomplete = jsonObject(response, 'incomplete_details');
  final reason = jsonString(incomplete, 'reason');
  final error = jsonObject(response, 'error');
  final code = jsonString(error, 'code');
  final message = jsonString(error, 'message');
  final reasoning = jsonObject(response, 'reasoning');
  final effort = jsonString(reasoning, 'effort');
  final summary = jsonString(reasoning, 'summary');
  final status = jsonString(response, 'status');
  final serviceTier = jsonString(response, 'service_tier');
  final retention = jsonString(response, 'prompt_cache_retention');
  return OpenAIResponseMetaExtension(
    id: jsonString(response, 'id'),
    status: status.isEmpty ? null : OpenAIResponseStatus(status),
    error: code.isEmpty && message.isEmpty
        ? null
        : OpenAIResponseError(
            code: code.isEmpty ? null : OpenAIResponseErrorCode(code),
            message: message,
          ),
    incompleteDetails:
        reason.isEmpty ? null : OpenAIIncompleteDetails(reason: reason),
    previousResponseId: jsonString(response, 'previous_response_id'),
    reasoning: OpenAIReasoning(
      effort: effort.isEmpty ? null : OpenAIReasoningEffort(effort),
      summary: summary.isEmpty ? null : OpenAIReasoningSummary(summary),
    ),
    serviceTier: serviceTier.isEmpty ? null : OpenAIServiceTier(serviceTier),
    createdAt: jsonInt(response, 'created_at'),
    promptCacheRetention:
        retention.isEmpty ? null : OpenAIPromptCacheRetention(retention),
  );
}
