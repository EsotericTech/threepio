/// The wire format of `ClaudeAgenticModel`: the messages and tools of a
/// Messages API request built from agentic messages, and agentic messages
/// built from its responses.
///
/// Port of eino-ext `components/model/agenticclaude/convertor.go` (and the
/// `setStringArgument` of `utils.go`). Go builds anthropic-sdk-go parameter
/// structs; here the JSON is built directly, in the shape the SDK sends.
/// Everything here is internal to threepio.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/agentic_message.dart';
import '../../../../schema/extensions/claude.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import 'claude_agentic_consts.dart';
import 'claude_agentic_extension.dart';
import 'claude_agentic_utils.dart';

ThreepioFormatException _error(String message, {Object? cause}) =>
    ThreepioFormatException(message, cause: cause);

// ---------------------------------------------------------------------------
// Input messages
// ---------------------------------------------------------------------------

/// The `system` blocks and the `messages` of a request for [input].
///
/// Port of eino-ext agenticclaude `toAnthropicMessages`: the system messages
/// before the first other message become the top-level `system` text
/// blocks; a later system message stays in `messages` with the role
/// `system`. Adjacent tool-result messages and adjacent system messages are
/// merged. Throws a [ThreepioFormatException] for an empty input, an input
/// of system messages only, and blocks a role cannot carry.
@internal
({List<Map<String, Object?>> system, List<Map<String, Object?>> messages})
claudeAgenticToAnthropicMessages(List<AgenticMessage> input) {
  if (input.isEmpty) throw _error('input is empty');

  var firstNonSystem = 0;
  for (var i = 0; i < input.length; i++) {
    if (input[i].role != AgenticRoleType.system) {
      firstNonSystem = i;
      break;
    }
    if (i == input.length - 1) {
      throw _error('input contains only system messages');
    }
  }

  final system = <Map<String, Object?>>[
    for (final message in input.take(firstNonSystem))
      ...claudeAgenticSystemBlocks(message),
  ];

  var messages = <Map<String, Object?>>[
    for (final message in input.skip(firstNonSystem))
      switch (message.role) {
        AgenticRoleType.system => {
          'role': 'system',
          'content': claudeAgenticSystemBlocks(message),
        },
        AgenticRoleType.user => claudeAgenticUserMessageParam(message),
        AgenticRoleType.assistant => claudeAgenticAssistantMessageParam(
          message,
        ),
      },
  ];
  messages = claudeAgenticMergeAdjacentToolResults(messages);
  messages = claudeAgenticMergeAdjacentSystemMessages(messages);
  return (system: system, messages: messages);
}

List<Map<String, Object?>> _content(Map<String, Object?> message) =>
    (message['content']! as List).cast<Map<String, Object?>>();

/// Merges adjacent user messages that hold only tool results: the API wants
/// all results of an assistant turn in one message.
///
/// Port of eino-ext agenticclaude `mergeAdjacentToolResults`.
@internal
List<Map<String, Object?>> claudeAgenticMergeAdjacentToolResults(
  List<Map<String, Object?>> messages,
) => _mergeAdjacent(messages, _isToolResultMessage);

/// Merges adjacent system messages, as Claude takes a system message only
/// right before a user or an assistant message.
///
/// Port of eino-ext agenticclaude `mergeAdjacentSystemMessages`.
@internal
List<Map<String, Object?>> claudeAgenticMergeAdjacentSystemMessages(
  List<Map<String, Object?>> messages,
) => _mergeAdjacent(messages, (message) => message['role'] == 'system');

List<Map<String, Object?>> _mergeAdjacent(
  List<Map<String, Object?>> messages,
  bool Function(Map<String, Object?> message) mergeable,
) {
  if (messages.length <= 1) return messages;
  final result = <Map<String, Object?>>[];
  for (final message in messages) {
    if (result.isNotEmpty && mergeable(message) && mergeable(result.last)) {
      result.last = {
        ...result.last,
        'content': [..._content(result.last), ..._content(message)],
      };
    } else {
      result.add(message);
    }
  }
  return result;
}

/// Port of eino-ext agenticclaude `isToolResultMessage`.
bool _isToolResultMessage(Map<String, Object?> message) {
  if (message['role'] != 'user') return false;
  final content = _content(message);
  return content.isNotEmpty &&
      content.every((block) => block['type'] == 'tool_result');
}

/// The text blocks of a system message.
///
/// Port of eino-ext agenticclaude `toSystemBlocks`: only
/// [UserInputText] blocks, each with its manual cache breakpoint.
@internal
List<Map<String, Object?>> claudeAgenticSystemBlocks(AgenticMessage message) =>
    [
      for (final block in message.contentBlocks)
        if (block.content case final UserInputText text)
          _withCacheControl({'type': 'text', 'text': text.text}, block)
        else
          throw _error(
            'system message only supports text blocks, got '
            '"${block.type.value}"',
          ),
    ];

/// A user message of the request.
///
/// Port of eino-ext agenticclaude `toUserMessageParam`: text, images,
/// files, function tool results and tool search results.
@internal
Map<String, Object?> claudeAgenticUserMessageParam(AgenticMessage message) => {
  'role': 'user',
  'content': [
    for (final block in message.contentBlocks)
      _withCacheControl(switch (block.content) {
        final UserInputText text => {'type': 'text', 'text': text.text},
        final UserInputImage image => claudeAgenticImageBlock(image),
        final UserInputFile file => claudeAgenticDocumentBlock(file),
        final FunctionToolResult result => claudeAgenticFunctionToolResultBlock(
          result,
        ),
        final ToolSearchFunctionToolResult result =>
          claudeAgenticToolSearchResultBlock(result),
        _ => throw _error(
          'invalid content block type "${block.type.value}" with '
          'user role',
        ),
      }, block),
  ],
};

/// An assistant message of the request.
///
/// Port of eino-ext agenticclaude `toAssistantMessageParam`: text (with its
/// citations), reasoning, function tool calls, server tool calls and server
/// tool results.
@internal
Map<String, Object?> claudeAgenticAssistantMessageParam(
  AgenticMessage message,
) => {
  'role': 'assistant',
  'content': [
    for (final block in message.contentBlocks)
      _withCacheControl(switch (block.content) {
        final AssistantGenText text => claudeAgenticTextBlock(text),
        final Reasoning reasoning => {
          'type': 'thinking',
          'thinking': reasoning.text,
          'signature': reasoning.signature,
        },
        final FunctionToolCall call => claudeAgenticToolUseBlock(call),
        final ServerToolCall call => claudeAgenticServerToolUseBlock(call),
        ServerToolResult() => claudeAgenticServerToolResultBlock(block),
        _ => throw _error(
          'invalid content block type "${block.type.value}" with '
          'assistant role',
        ),
      }, block),
  ],
};

/// [param] with the manual cache breakpoint of [block], if it has one.
///
/// As Go's `*blockParam.GetCacheControl() = …`. A `thinking` block has no
/// `cache_control` (Go would dereference a nil pointer); it is left as it
/// is.
Map<String, Object?> _withCacheControl(
  Map<String, Object?> param,
  ContentBlock block,
) {
  if (!claudeHasCacheControlOnContentBlock(block)) return param;
  if (param['type'] == 'thinking') return param;
  final control = claudeContentBlockCacheControl(block);
  if (control == null) return param;
  return {...param, 'cache_control': control};
}

/// A `text` block for generated text. Port of eino-ext agenticclaude
/// `assistantGenTextToBlockParam`.
@internal
Map<String, Object?> claudeAgenticTextBlock(AssistantGenText text) {
  final citations = claudeAgenticTextCitationParams(
    text.claudeExtension?.citations,
  );
  return {
    'type': 'text',
    'text': text.text,
    if (citations.isNotEmpty) 'citations': citations,
  };
}

/// A `tool_use` block. Port of eino-ext agenticclaude
/// `functionToolCallToBlockParam`: empty arguments are `{}`. Go embeds the
/// arguments as raw JSON; here they are decoded and encoded again, so
/// arguments that are not JSON are a [ThreepioFormatException] now rather
/// than a marshalling error when the request is sent.
@internal
Map<String, Object?> claudeAgenticToolUseBlock(FunctionToolCall call) {
  Object? input = const <String, Object?>{};
  if (call.arguments.isNotEmpty) {
    try {
      input = jsonDecode(call.arguments);
    } on FormatException catch (error) {
      throw _error(
        'invalid arguments of function tool call "${call.name}": '
        '${error.message}',
        cause: error,
      );
    }
  }
  return {
    'type': 'tool_use',
    'id': call.callId,
    'name': call.name,
    'input': input,
  };
}

/// A `server_tool_use` block. Port of eino-ext agenticclaude
/// `serverToolCallToBlockParam`: the name follows from the arguments that
/// are set.
@internal
Map<String, Object?> claudeAgenticServerToolUseBlock(ServerToolCall call) {
  final args = claudeServerToolCallArguments(call);
  final (name, input) = switch (args) {
    ClaudeServerToolCallArguments(webSearch: final a?) => (
      ClaudeServerToolName.webSearch,
      a.toJson(),
    ),
    ClaudeServerToolCallArguments(webFetch: final a?) => (
      ClaudeServerToolName.webFetch,
      a.toJson(),
    ),
    ClaudeServerToolCallArguments(codeExecution: final a?) => (
      ClaudeServerToolName.codeExecution,
      a.toJson(),
    ),
    ClaudeServerToolCallArguments(bashCodeExecution: final a?) => (
      ClaudeServerToolName.bashCodeExecution,
      a.toJson(),
    ),
    ClaudeServerToolCallArguments(textEditorCodeExecution: final a?) => (
      ClaudeServerToolName.textEditorCodeExecution,
      a.toJson(),
    ),
    ClaudeServerToolCallArguments(toolSearchToolBm25: final a?) => (
      ClaudeServerToolName.toolSearchToolBm25,
      a.toJson(),
    ),
    ClaudeServerToolCallArguments(toolSearchToolRegex: final a?) => (
      ClaudeServerToolName.toolSearchToolRegex,
      a.toJson(),
    ),
    _ => throw _error('server tool call arguments are nil'),
  };
  return {
    'type': 'server_tool_use',
    'id': call.callId,
    'name': name.value,
    'input': input,
  };
}

/// The result block of a server tool, from the [ServerToolResult] in
/// [block] (whose `extra` may hold the result's caller).
///
/// Port of eino-ext agenticclaude `serverToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticServerToolResultBlock(ContentBlock block) {
  final result = block.serverToolResult!;
  final content = claudeServerToolResultOf(result);
  final callId = result.callId;
  return switch (content) {
    ClaudeServerToolResult(webSearch: final r?) =>
      claudeAgenticWebSearchResultBlock(r, callId, block),
    ClaudeServerToolResult(webFetch: final r?) =>
      claudeAgenticWebFetchResultBlock(r, callId, block),
    ClaudeServerToolResult(codeExecution: final r?) =>
      claudeAgenticCodeExecutionResultBlock(r, callId),
    ClaudeServerToolResult(bashCodeExecution: final r?) =>
      claudeAgenticBashCodeExecutionResultBlock(r, callId),
    ClaudeServerToolResult(textEditorCodeExecution: final r?) =>
      claudeAgenticTextEditorCodeExecutionResultBlock(r, callId),
    ClaudeServerToolResult(toolSearchToolBm25: final r?) =>
      claudeAgenticToolSearchToolResultBlock(r, callId),
    ClaudeServerToolResult(toolSearchToolRegex: final r?) =>
      claudeAgenticToolSearchToolResultBlock(r, callId),
    _ => throw _error('server tool result content is nil'),
  };
}

/// A `web_search_tool_result` block. Port of eino-ext agenticclaude
/// `webSearchToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticWebSearchResultBlock(
  ClaudeWebSearchResult result,
  String callId,
  ContentBlock block,
) {
  final caller = claudeWebSearchResultCallerParam(block);
  final Object content;
  if (result.type == ClaudeWebSearchResultType.error) {
    final error = result.error ?? (throw _error('web search error is nil'));
    content = {
      'type': 'web_search_tool_result_error',
      'error_code': error.code,
    };
  } else if (result.type == ClaudeWebSearchResultType.result) {
    final items = result.result ?? (throw _error('web search result is nil'));
    content = [
      for (final item in items.content)
        {
          'type': 'web_search_result',
          'title': item.title,
          'url': item.url,
          'encrypted_content': item.encryptedContent,
          'page_age': item.pageAge,
        },
    ];
  } else {
    throw _error(
      'invalid web search result type "${result.type?.value ?? ''}"',
    );
  }
  return {
    'type': 'web_search_tool_result',
    'tool_use_id': callId,
    'content': content,
    if (caller != null) 'caller': caller,
  };
}

/// A `web_fetch_tool_result` block. Port of eino-ext agenticclaude
/// `webFetchToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticWebFetchResultBlock(
  ClaudeWebFetchResult result,
  String callId,
  ContentBlock block,
) {
  final caller = claudeWebFetchResultCallerParam(block);
  final Map<String, Object?> content;
  if (result.type == ClaudeWebFetchResultType.error) {
    final error = result.error ?? (throw _error('web fetch error is nil'));
    content = {'type': 'web_fetch_tool_result_error', 'error_code': error.code};
  } else if (result.type == ClaudeWebFetchResultType.result) {
    final fetched = result.result ?? (throw _error('web fetch result is nil'));
    content = {
      'type': 'web_fetch_result',
      'url': fetched.url,
      'retrieved_at': fetched.retrievedAt,
      'content': claudeAgenticWebFetchDocumentParam(fetched.content),
    };
  } else {
    throw _error('invalid web fetch result type "${result.type?.value ?? ''}"');
  }
  return {
    'type': 'web_fetch_tool_result',
    'tool_use_id': callId,
    'content': content,
    if (caller != null) 'caller': caller,
  };
}

/// The `document` of a web fetch result. Port of eino-ext agenticclaude
/// `toWebFetchDocumentBlockParam`: plain text (`text/plain` or no type) and
/// PDF (`application/pdf`).
@internal
Map<String, Object?> claudeAgenticWebFetchDocumentParam(
  ClaudeWebFetchDocument? document,
) {
  if (document == null) throw _error('web fetch content is nil');
  final source = document.source;
  if (source == null) throw _error('web fetch content source is nil');
  final sourceParam = switch (source.mimeType) {
    '' || 'text/plain' => {
      'type': 'text',
      'media_type': 'text/plain',
      'data': source.data,
    },
    'application/pdf' => {
      'type': 'base64',
      'media_type': 'application/pdf',
      'data': source.data,
    },
    final other => throw _error('invalid web fetch content mime type "$other"'),
  };
  return {
    'type': 'document',
    'source': sourceParam,
    'title': document.title,
    if (document.citations != null)
      'citations': {'enabled': document.citations!.enabled},
  };
}

/// A `code_execution_tool_result` block. Port of eino-ext agenticclaude
/// `codeExecutionToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticCodeExecutionResultBlock(
  ClaudeCodeExecutionResult result,
  String callId,
) {
  final Map<String, Object?> content;
  if (result.type == ClaudeCodeExecutionResultType.error) {
    final error = result.error ?? (throw _error('code execution error is nil'));
    content = {
      'type': 'code_execution_tool_result_error',
      'error_code': error.code,
    };
  } else if (result.type == ClaudeCodeExecutionResultType.encrypted) {
    final encrypted =
        result.encryptedResult ??
        (throw _error('code execution encrypted result is nil'));
    content = {
      'type': 'encrypted_code_execution_result',
      'content': _outputs(encrypted.content, 'code_execution_output'),
      'encrypted_stdout': encrypted.encryptedStdout,
      'stderr': encrypted.stderr,
      'return_code': encrypted.returnCode,
    };
  } else if (result.type == ClaudeCodeExecutionResultType.result) {
    final output =
        result.result ?? (throw _error('code execution result is nil'));
    content = {
      'type': 'code_execution_result',
      'content': _outputs(output.content, 'code_execution_output'),
      'stdout': output.stdout,
      'stderr': output.stderr,
      'return_code': output.returnCode,
    };
  } else {
    throw _error(
      'invalid code execution result type "${result.type?.value ?? ''}"',
    );
  }
  return {
    'type': 'code_execution_tool_result',
    'tool_use_id': callId,
    'content': content,
  };
}

/// A `bash_code_execution_tool_result` block. Port of eino-ext
/// agenticclaude `bashCodeExecutionToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticBashCodeExecutionResultBlock(
  ClaudeBashCodeExecutionResult result,
  String callId,
) {
  final Map<String, Object?> content;
  if (result.type == ClaudeBashCodeExecutionResultType.error) {
    final error =
        result.error ?? (throw _error('bash code execution error is nil'));
    content = {
      'type': 'bash_code_execution_tool_result_error',
      'error_code': error.code,
    };
  } else if (result.type == ClaudeBashCodeExecutionResultType.result) {
    final output =
        result.result ?? (throw _error('bash code execution result is nil'));
    content = {
      'type': 'bash_code_execution_result',
      'content': _outputs(output.content, 'bash_code_execution_output'),
      'stdout': output.stdout,
      'stderr': output.stderr,
      'return_code': output.returnCode,
    };
  } else {
    throw _error(
      'invalid bash code execution result type "${result.type?.value ?? ''}"',
    );
  }
  return {
    'type': 'bash_code_execution_tool_result',
    'tool_use_id': callId,
    'content': content,
  };
}

/// A `text_editor_code_execution_tool_result` block. Port of eino-ext
/// agenticclaude `textEditorCodeExecutionToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticTextEditorCodeExecutionResultBlock(
  ClaudeTextEditorCodeExecutionResult result,
  String callId,
) {
  final type = result.type;
  final Map<String, Object?> content;
  if (type == ClaudeTextEditorCodeExecutionResultType.error) {
    final error =
        result.error ??
        (throw _error('text editor code execution error is nil'));
    content = {
      'type': 'text_editor_code_execution_tool_result_error',
      'error_code': error.code,
      'error_message': error.message,
    };
  } else if (type == ClaudeTextEditorCodeExecutionResultType.create) {
    final create =
        result.create ??
        (throw _error('text editor code execution create result is nil'));
    content = {
      'type': 'text_editor_code_execution_create_result',
      'is_file_update': create.isFileUpdate,
    };
  } else if (type == ClaudeTextEditorCodeExecutionResultType.strReplace) {
    final replace =
        result.strReplace ??
        (throw _error('text editor code execution str replace result is nil'));
    content = {
      'type': 'text_editor_code_execution_str_replace_result',
      'old_start': replace.oldStart,
      'old_lines': replace.oldLines,
      'new_start': replace.newStart,
      'new_lines': replace.newLines,
      if (replace.lines.isNotEmpty) 'lines': replace.lines,
    };
  } else if (type == ClaudeTextEditorCodeExecutionResultType.view) {
    final view =
        result.view ??
        (throw _error('text editor code execution view result is nil'));
    content = {
      'type': 'text_editor_code_execution_view_result',
      'file_type': view.fileType,
      'content': view.content,
      'num_lines': view.numLines,
      'start_line': view.startLine,
      'total_lines': view.totalLines,
    };
  } else {
    throw _error(
      'invalid text editor code execution result type '
      '"${type?.value ?? ''}"',
    );
  }
  return {
    'type': 'text_editor_code_execution_tool_result',
    'tool_use_id': callId,
    'content': content,
  };
}

/// A `tool_search_tool_result` block. Port of eino-ext agenticclaude
/// `toolSearchToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticToolSearchToolResultBlock(
  ClaudeToolSearchToolResult result,
  String callId,
) {
  final Map<String, Object?> content;
  if (result.type == ClaudeToolSearchToolResultType.error) {
    final error = result.error ?? (throw _error('tool search error is nil'));
    content = {
      'type': 'tool_search_tool_result_error',
      'error_code': error.code,
    };
  } else if (result.type == ClaudeToolSearchToolResultType.searchResult) {
    final found =
        result.searchResult ?? (throw _error('tool search result is nil'));
    content = {
      'type': 'tool_search_tool_search_result',
      'tool_references': [
        for (final reference in found.toolReferences)
          {'type': 'tool_reference', 'tool_name': reference.toolName},
      ],
    };
  } else {
    throw _error(
      'invalid tool search tool result type "${result.type?.value ?? ''}"',
    );
  }
  return {
    'type': 'tool_search_tool_result',
    'tool_use_id': callId,
    'content': content,
  };
}

List<Map<String, Object?>> _outputs(
  List<ClaudeCodeExecutionOutput> outputs,
  String type,
) => [
  for (final output in outputs) {'type': type, 'file_id': output.fileId},
];

/// A `tool_result` block for a function tool result. Port of eino-ext
/// agenticclaude `functionToolResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticFunctionToolResultBlock(
  FunctionToolResult result,
) => {
  'type': 'tool_result',
  'tool_use_id': result.callId,
  'content': [
    for (final part in result.content)
      claudeAgenticFunctionToolResultContent(part),
  ],
};

/// A `tool_result` block that answers a client-side tool search with
/// references to the tools it found. Port of eino-ext agenticclaude
/// `toolSearchResultToBlockParam`.
@internal
Map<String, Object?> claudeAgenticToolSearchResultBlock(
  ToolSearchFunctionToolResult result,
) {
  final found = result.result ?? (throw _error('tool search result is nil'));
  return {
    'type': 'tool_result',
    'tool_use_id': result.callId,
    'content': [
      for (final tool in found.tools)
        {'type': 'tool_reference', 'tool_name': tool.name},
    ],
  };
}

/// One part of a function tool result: text, an image or a document. Port
/// of eino-ext agenticclaude `functionToolResultContentToBlockParam`.
@internal
Map<String, Object?> claudeAgenticFunctionToolResultContent(
  FunctionToolResultContentBlock part,
) => switch (part.content) {
  final UserInputText text => {'type': 'text', 'text': text.text},
  final UserInputImage image => claudeAgenticImageBlock(image),
  final UserInputFile file => claudeAgenticDocumentBlock(file),
  _ => throw _error(
    'invalid function tool result content block type '
    '"${part.type.value}"',
  ),
};

/// An `image` block: from the URL, else the base64 data, else the Files API
/// id. Port of eino-ext agenticclaude `imageToBlockParam`.
@internal
Map<String, Object?> claudeAgenticImageBlock(UserInputImage image) {
  final Map<String, Object?> source;
  if (image.url.isNotEmpty) {
    source = {'type': 'url', 'url': image.url};
  } else if (image.base64Data.isNotEmpty) {
    source = {
      'type': 'base64',
      'media_type': claudeAgenticImageMediaType(image.mimeType),
      'data': image.base64Data,
    };
  } else if (image.fileId.isNotEmpty) {
    source = {'type': 'file', 'file_id': image.fileId};
  } else {
    throw _error('image input requires URL, Base64Data or FileID');
  }
  return {'type': 'image', 'source': source};
}

/// A `document` block (a PDF): from the URL, else the base64 data, else the
/// Files API id. Port of eino-ext agenticclaude `documentToBlockParam`.
@internal
Map<String, Object?> claudeAgenticDocumentBlock(UserInputFile file) {
  final Map<String, Object?> source;
  if (file.url.isNotEmpty) {
    source = {'type': 'url', 'url': file.url};
  } else if (file.base64Data.isNotEmpty) {
    source = {
      'type': 'base64',
      'media_type': 'application/pdf',
      'data': file.base64Data,
    };
  } else if (file.fileId.isNotEmpty) {
    source = {'type': 'file', 'file_id': file.fileId};
  } else {
    throw _error('file input requires URL, Base64Data or FileID');
  }
  return {'type': 'document', 'source': source};
}

/// The `media_type` of a base64 image. Port of eino-ext agenticclaude
/// `toAnthropicImageMediaType`.
@internal
String claudeAgenticImageMediaType(String mimeType) => switch (mimeType) {
  'image/jpeg' || 'image/jpg' => 'image/jpeg',
  'image/png' => 'image/png',
  'image/gif' => 'image/gif',
  'image/webp' => 'image/webp',
  _ => throw _error('invalid image mime type "$mimeType"'),
};

/// The `citations` of a text block. Port of eino-ext agenticclaude
/// `toAnthropicTextCitations`.
@internal
List<Map<String, Object?>> claudeAgenticTextCitationParams(
  List<ClaudeTextCitation>? citations,
) {
  if (citations == null || citations.isEmpty) return const [];
  Never missing(String type) => throw _error('text citation "$type" is nil');
  return [
    for (final citation in citations)
      switch (citation.type) {
        ClaudeTextCitationType.charLocation => () {
          final c = citation.charLocation ?? missing('char_location');
          return {
            'type': 'char_location',
            'cited_text': c.citedText,
            if (c.documentTitle.isNotEmpty) 'document_title': c.documentTitle,
            'document_index': c.documentIndex,
            'start_char_index': c.startCharIndex,
            'end_char_index': c.endCharIndex,
          };
        }(),
        ClaudeTextCitationType.pageLocation => () {
          final c = citation.pageLocation ?? missing('page_location');
          return {
            'type': 'page_location',
            'cited_text': c.citedText,
            if (c.documentTitle.isNotEmpty) 'document_title': c.documentTitle,
            'document_index': c.documentIndex,
            'start_page_number': c.startPageNumber,
            'end_page_number': c.endPageNumber,
          };
        }(),
        ClaudeTextCitationType.contentBlockLocation => () {
          final c =
              citation.contentBlockLocation ??
              missing('content_block_location');
          return {
            'type': 'content_block_location',
            'cited_text': c.citedText,
            if (c.documentTitle.isNotEmpty) 'document_title': c.documentTitle,
            'document_index': c.documentIndex,
            'start_block_index': c.startBlockIndex,
            'end_block_index': c.endBlockIndex,
          };
        }(),
        ClaudeTextCitationType.webSearchResultLocation => () {
          final c =
              citation.webSearchResultLocation ??
              missing('web_search_result_location');
          return {
            'type': 'web_search_result_location',
            'cited_text': c.citedText,
            if (c.title.isNotEmpty) 'title': c.title,
            'url': c.url,
            'encrypted_index': c.encryptedIndex,
          };
        }(),
        _ => throw _error(
          'invalid text citation type "${citation.type?.value ?? ''}"',
        ),
      },
  ];
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

/// The definitions of function [tools]; with [deferLoading], the model finds
/// them through tool search only.
///
/// Port of eino-ext agenticclaude `toFunctionTools` and
/// `toDeferredFunctionTools`. The input schema is the tool's full JSON
/// schema: its `properties` and `required`, and every other keyword
/// (`oneOf`, `additionalProperties`, `$defs`, …) unchanged; its `type` is
/// always `object`. A raw schema (`ToolInfo.fromJsonSchemaMap`) is sent as
/// given. Throws a [ThreepioFormatException] when a raw schema cannot be
/// encoded as JSON.
@internal
List<Map<String, Object?>> claudeAgenticFunctionTools(
  List<ToolInfo> tools, {
  bool deferLoading = false,
}) => [
  for (final tool in tools)
    {
      'type': 'custom',
      'name': tool.name,
      if (tool.desc != null && tool.desc!.isNotEmpty) 'description': tool.desc,
      'input_schema': _inputSchema(tool),
      if (claudeHasCacheControlOnToolInfo(tool) &&
          claudeToolInfoCacheControl(tool) != null)
        'cache_control': claudeToolInfoCacheControl(tool),
      if (deferLoading) 'defer_loading': true,
    },
];

Map<String, Object?> _inputSchema(ToolInfo tool) {
  final Map<String, Object?>? full;
  final raw = tool.function.parametersJsonSchema;
  if (raw != null) {
    try {
      jsonEncode(raw);
      // Go's "marshal full JSON schema" error: a schema map with a value
      // that is not JSON is the caller's data, reported like bad input.
      // ignore: avoid_catching_errors
    } on JsonUnsupportedObjectError catch (error) {
      throw _error(
        'failed to preserve tool "${tool.name}" full JSON schema: marshal '
        'full JSON schema: $error',
        cause: error,
      );
    }
    full = raw.cast<String, Object?>();
  } else {
    final parameters = tool.function.parameters;
    full = parameters == null ? null : _schemaDocument(parameters);
  }
  if (full == null) return const {'type': 'object'};
  return {
    'type': 'object',
    if (full['properties'] != null) 'properties': full['properties'],
    if (full['required'] != null) 'required': full['required'],
    for (final entry in full.entries)
      if (entry.key != 'type' &&
          entry.key != 'properties' &&
          entry.key != 'required')
        entry.key: entry.value,
  };
}

/// The JSON schema document of [schema], as eino's `ToJSONSchema` gives it
/// for parameters (`additionalProperties` and an empty `required` left out).
Map<String, Object?> _schemaDocument(JSONSchema schema) => {
  'type': schema.type,
  'properties': {
    for (final entry in schema.properties.entries)
      entry.key: _property(entry.value),
  },
  if (schema.required.isNotEmpty) 'required': [...schema.required],
};

Map<String, Object?> _property(JSONSchemaProperty property) => {
  'type': property.type,
  if (property.description != null) 'description': property.description,
  if (property.enumValues != null) 'enum': property.enumValues,
  if (property.items != null) 'items': _property(property.items!),
  if (property.properties != null)
    'properties': {
      for (final entry in property.properties!.entries)
        entry.key: _property(entry.value),
    },
  if (property.required != null && property.required!.isNotEmpty)
    'required': property.required,
  if (property.additionalProperties != null)
    'additionalProperties': property.additionalProperties,
};

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// Turns the content blocks of responses and stream events into agentic
/// content blocks.
///
/// Holds what one response (or one stream) has seen so far: the server
/// tools its `server_tool_use` blocks called, by call id, so that a
/// `tool_search_tool_result` can be told apart by the tool that produced it.
@internal
final class ClaudeAgenticBlockConverter {
  /// A converter for one response or one stream.
  ClaudeAgenticBlockConverter();

  final Map<String, ClaudeServerToolName> _serverToolCalls = {};

  /// Whether a `server_tool_use` of a tool search tool with [callId] came
  /// before, so that its `tool_search_tool_result` can be converted.
  bool isToolSearchCall(String callId) {
    final name = _serverToolCalls[callId];
    return name == ClaudeServerToolName.toolSearchToolBm25 ||
        name == ClaudeServerToolName.toolSearchToolRegex;
  }

  /// The agentic message of a Messages API response (or of the `message`
  /// of a `message_start` event).
  ///
  /// Port of eino-ext agenticclaude `toAgenticMessage`: the blocks
  /// (redacted thinking dropped), the response meta, and the cache-creation
  /// token count in `extra` when it is above zero. Throws a
  /// [ThreepioFormatException] for a block it does not know.
  AgenticMessage message(Map<String, Object?> response) {
    final blocks = <ContentBlock>[
      for (final item in _list(response['content']))
        if (contentBlock(_map(item) ?? const {}) case final block?) block,
    ];
    final usage = _map(response['usage']);
    final cacheCreation = _int(usage?['cache_creation_input_tokens']);
    return AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: blocks,
      responseMeta: AgenticResponseMeta(
        tokenUsage: claudeAgenticTokenUsage(usage),
        claudeExtension: ClaudeResponseMetaExtension(
          id: _str(response['id']),
          stopReason: _str(response['stop_reason']),
          stopSequence: _str(response['stop_sequence']),
          stopDetails: claudeAgenticStopDetails(_map(response['stop_details'])),
        ),
      ),
      extra: cacheCreation > 0
          ? {claudeAgenticKeyOfCacheCreationInputTokens: cacheCreation}
          : null,
    );
  }

  /// The agentic block of one content block of a response, or `null` for a
  /// block that is dropped (`redacted_thinking`).
  ///
  /// Port of eino-ext agenticclaude `toAgenticContentBlock`. Unlike Go, a
  /// `tool_search_tool_result` becomes a [ServerToolResult] (Go fails with
  /// "invalid output block type"; its input side already sends them back).
  ContentBlock? contentBlock(Map<String, Object?> block) {
    final type = _str(block['type']);
    switch (type) {
      case 'text':
        return ContentBlock(
          AssistantGenText(
            text: _str(block['text']),
            claudeExtension: claudeAgenticTextExtension(block['citations']),
          ),
        );
      case 'thinking':
        return ContentBlock(
          Reasoning(
            text: _str(block['thinking']),
            signature: _str(block['signature']),
          ),
        );
      case 'tool_use':
        // Go keeps the raw JSON of `input` (`string(item.Input)`: empty when
        // the field is missing); here it is encoded again, so the spacing
        // and number format may differ from the response's.
        return ContentBlock(
          FunctionToolCall(
            callId: _str(block['id']),
            name: _str(block['name']),
            arguments: block.containsKey('input')
                ? jsonEncode(block['input'])
                : '',
          ),
        );
      case 'redacted_thinking':
        // Dropped, as in Go.
        return null;
      case 'server_tool_use':
        return serverToolUse(block);
      case 'web_search_tool_result':
        return webSearchToolResult(block);
      case 'web_fetch_tool_result':
        return webFetchToolResult(block);
      case 'code_execution_tool_result':
        return codeExecutionToolResult(block);
      case 'bash_code_execution_tool_result':
        return bashCodeExecutionToolResult(block);
      case 'text_editor_code_execution_tool_result':
        return textEditorCodeExecutionToolResult(block);
      case 'tool_search_tool_result':
        return toolSearchToolResult(block);
      default:
        throw _error('invalid output block type "$type"');
    }
  }

  /// A [ServerToolCall] block for a `server_tool_use` block.
  ///
  /// Port of eino-ext agenticclaude `serverToolUseToContentBlock` and the
  /// `…ToolUseToContentBlock` functions it calls: the input's string fields
  /// become the tool's arguments (empty when there is no input). Throws a
  /// [ThreepioFormatException] for an unknown tool, an input that is not an
  /// object or a field that is not a string.
  ContentBlock serverToolUse(Map<String, Object?> block) {
    final callId = _str(block['id']);
    final name = ClaudeServerToolName(_str(block['name']));
    final input = block['input'];
    final fields = input is Map
        ? input.cast<String, Object?>()
        : const <String, Object?>{};
    String arg(String key, String what) {
      if (input != null && input is! Map) {
        throw _error(
          'unexpected type ${claudeGoTypeName(input)} for $what input',
        );
      }
      try {
        return _stringArgument(fields, key);
      } on ThreepioFormatException catch (error) {
        throw _error('invalid $what $key: ${error.message}');
      }
    }

    final ClaudeServerToolCallArguments arguments;
    if (name == ClaudeServerToolName.webSearch) {
      arguments = ClaudeServerToolCallArguments(
        webSearch: ClaudeWebSearchArguments(query: arg('query', 'web search')),
      );
    } else if (name == ClaudeServerToolName.webFetch) {
      arguments = ClaudeServerToolCallArguments(
        webFetch: ClaudeWebFetchArguments(url: arg('url', 'web fetch')),
      );
    } else if (name == ClaudeServerToolName.codeExecution) {
      arguments = ClaudeServerToolCallArguments(
        codeExecution: ClaudeCodeExecutionArguments(
          code: arg('code', 'code execution'),
        ),
      );
    } else if (name == ClaudeServerToolName.bashCodeExecution) {
      arguments = ClaudeServerToolCallArguments(
        bashCodeExecution: ClaudeBashCodeExecutionArguments(
          command: arg('command', 'bash code execution'),
        ),
      );
    } else if (name == ClaudeServerToolName.textEditorCodeExecution) {
      const what = 'text editor code execution';
      arguments = ClaudeServerToolCallArguments(
        textEditorCodeExecution: ClaudeTextEditorCodeExecutionArguments(
          command: arg('command', what),
          path: arg('path', what),
          fileText: arg('file_text', what),
          oldStr: arg('old_str', what),
          newStr: arg('new_str', what),
        ),
      );
    } else if (name == ClaudeServerToolName.toolSearchToolBm25) {
      arguments = ClaudeServerToolCallArguments(
        toolSearchToolBm25: ClaudeToolSearchToolBm25Arguments(
          query: arg('query', 'tool search bm25'),
        ),
      );
    } else if (name == ClaudeServerToolName.toolSearchToolRegex) {
      arguments = ClaudeServerToolCallArguments(
        toolSearchToolRegex: ClaudeToolSearchToolRegexArguments(
          query: arg('query', 'tool search regex'),
        ),
      );
    } else {
      throw _error('invalid server tool "${name.value}"');
    }
    _serverToolCalls[callId] = name;
    return ContentBlock(
      ServerToolCall(callId: callId, name: name.value, arguments: arguments),
    );
  }

  /// A [ServerToolResult] block for a `web_search_tool_result`, with the
  /// result's caller in its `extra`. Port of eino-ext agenticclaude
  /// `webSearchToolResultToContentBlock`.
  ContentBlock webSearchToolResult(Map<String, Object?> block) {
    final content = block['content'];
    final ClaudeWebSearchResult result;
    if (content is List) {
      result = ClaudeWebSearchResult(
        type: ClaudeWebSearchResultType.result,
        result: ClaudeWebSearchResultBlock(
          content: [
            for (final item in content)
              if (_map(item) case final item?)
                ClaudeWebSearchResultItem(
                  title: _str(item['title']),
                  url: _str(item['url']),
                  encryptedContent: _str(item['encrypted_content']),
                  pageAge: _str(item['page_age']),
                ),
          ],
        ),
      );
    } else {
      final map = _map(content) ?? const {};
      final type = _str(map['type']);
      if (type == ClaudeWebSearchResultType.error.value) {
        result = ClaudeWebSearchResult(
          type: ClaudeWebSearchResultType.error,
          error: ClaudeWebSearchResultError(code: _str(map['error_code'])),
        );
      } else if (type.isEmpty) {
        // The SDK reads a missing content as an empty list of results.
        result = ClaudeWebSearchResult(
          type: ClaudeWebSearchResultType.result,
          result: ClaudeWebSearchResultBlock(),
        );
      } else {
        throw _error('invalid web search result type "$type"');
      }
    }
    return claudeWithWebSearchResultCaller(
      ContentBlock(
        ServerToolResult(
          callId: _str(block['tool_use_id']),
          name: ClaudeServerToolName.webSearch.value,
          content: ClaudeServerToolResult(webSearch: result),
        ),
      ),
      block['caller'],
    );
  }

  /// A [ServerToolResult] block for a `web_fetch_tool_result`, with the
  /// result's caller in its `extra`. Port of eino-ext agenticclaude
  /// `webFetchToolResultToContentBlock`.
  ContentBlock webFetchToolResult(Map<String, Object?> block) {
    final content = _map(block['content']) ?? const {};
    final type = _str(content['type']);
    final ClaudeWebFetchResult result;
    if (type == ClaudeWebFetchResultType.error.value) {
      result = ClaudeWebFetchResult(
        type: ClaudeWebFetchResultType.error,
        error: ClaudeWebFetchResultError(code: _str(content['error_code'])),
      );
    } else if (type == ClaudeWebFetchResultType.result.value) {
      result = ClaudeWebFetchResult(
        type: ClaudeWebFetchResultType.result,
        result: ClaudeWebFetchResultBlock(
          url: _str(content['url']),
          retrievedAt: _str(content['retrieved_at']),
          content: claudeAgenticWebFetchDocument(
            _map(content['content']) ?? const {},
          ),
        ),
      );
    } else {
      throw _error('invalid web fetch result type "$type"');
    }
    return claudeWithWebFetchResultCaller(
      ContentBlock(
        ServerToolResult(
          callId: _str(block['tool_use_id']),
          name: ClaudeServerToolName.webFetch.value,
          content: ClaudeServerToolResult(webFetch: result),
        ),
      ),
      block['caller'],
    );
  }

  /// Port of eino-ext agenticclaude `codeExecutionToolResultToContentBlock`.
  ContentBlock codeExecutionToolResult(Map<String, Object?> block) {
    final content = _map(block['content']) ?? const {};
    final type = _str(content['type']);
    final ClaudeCodeExecutionResult result;
    if (type == ClaudeCodeExecutionResultType.error.value) {
      result = ClaudeCodeExecutionResult(
        type: ClaudeCodeExecutionResultType.error,
        error: ClaudeCodeExecutionResultError(
          code: _str(content['error_code']),
        ),
      );
    } else if (type == ClaudeCodeExecutionResultType.encrypted.value) {
      result = ClaudeCodeExecutionResult(
        type: ClaudeCodeExecutionResultType.encrypted,
        encryptedResult: ClaudeEncryptedCodeExecutionResultBlock(
          content: _codeOutputs(content['content']),
          encryptedStdout: _str(content['encrypted_stdout']),
          stderr: _str(content['stderr']),
          returnCode: _int(content['return_code']),
        ),
      );
    } else if (type == ClaudeCodeExecutionResultType.result.value) {
      result = ClaudeCodeExecutionResult(
        type: ClaudeCodeExecutionResultType.result,
        result: ClaudeCodeExecutionResultBlock(
          content: _codeOutputs(content['content']),
          stdout: _str(content['stdout']),
          stderr: _str(content['stderr']),
          returnCode: _int(content['return_code']),
        ),
      );
    } else {
      throw _error('invalid code execution result type "$type"');
    }
    return ContentBlock(
      ServerToolResult(
        callId: _str(block['tool_use_id']),
        name: ClaudeServerToolName.codeExecution.value,
        content: ClaudeServerToolResult(codeExecution: result),
      ),
    );
  }

  /// Port of eino-ext agenticclaude
  /// `bashCodeExecutionToolResultToContentBlock`.
  ContentBlock bashCodeExecutionToolResult(Map<String, Object?> block) {
    final content = _map(block['content']) ?? const {};
    final type = _str(content['type']);
    final ClaudeBashCodeExecutionResult result;
    if (type == ClaudeBashCodeExecutionResultType.error.value) {
      result = ClaudeBashCodeExecutionResult(
        type: ClaudeBashCodeExecutionResultType.error,
        error: ClaudeBashCodeExecutionResultError(
          code: _str(content['error_code']),
        ),
      );
    } else if (type == ClaudeBashCodeExecutionResultType.result.value) {
      result = ClaudeBashCodeExecutionResult(
        type: ClaudeBashCodeExecutionResultType.result,
        result: ClaudeBashCodeExecutionResultBlock(
          content: _codeOutputs(content['content']),
          stdout: _str(content['stdout']),
          stderr: _str(content['stderr']),
          returnCode: _int(content['return_code']),
        ),
      );
    } else {
      throw _error('invalid bash code execution result type "$type"');
    }
    return ContentBlock(
      ServerToolResult(
        callId: _str(block['tool_use_id']),
        name: ClaudeServerToolName.bashCodeExecution.value,
        content: ClaudeServerToolResult(bashCodeExecution: result),
      ),
    );
  }

  /// Port of eino-ext agenticclaude
  /// `textEditorCodeExecutionToolResultToContentBlock`.
  ContentBlock textEditorCodeExecutionToolResult(Map<String, Object?> block) {
    final content = _map(block['content']) ?? const {};
    final type = _str(content['type']);
    final ClaudeTextEditorCodeExecutionResult result;
    if (type == ClaudeTextEditorCodeExecutionResultType.error.value) {
      result = ClaudeTextEditorCodeExecutionResult(
        type: ClaudeTextEditorCodeExecutionResultType.error,
        error: ClaudeTextEditorCodeExecutionResultError(
          code: _str(content['error_code']),
          message: _str(content['error_message']),
        ),
      );
    } else if (type == ClaudeTextEditorCodeExecutionResultType.create.value) {
      result = ClaudeTextEditorCodeExecutionResult(
        type: ClaudeTextEditorCodeExecutionResultType.create,
        create: ClaudeTextEditorCodeExecutionCreateResult(
          isFileUpdate: content['is_file_update'] == true,
        ),
      );
    } else if (type ==
        ClaudeTextEditorCodeExecutionResultType.strReplace.value) {
      result = ClaudeTextEditorCodeExecutionResult(
        type: ClaudeTextEditorCodeExecutionResultType.strReplace,
        strReplace: ClaudeTextEditorCodeExecutionStrReplaceResult(
          oldStart: _int(content['old_start']),
          oldLines: _int(content['old_lines']),
          newStart: _int(content['new_start']),
          newLines: _int(content['new_lines']),
          lines: [
            for (final line in _list(content['lines']))
              if (line is String) line,
          ],
        ),
      );
    } else if (type == ClaudeTextEditorCodeExecutionResultType.view.value) {
      result = ClaudeTextEditorCodeExecutionResult(
        type: ClaudeTextEditorCodeExecutionResultType.view,
        view: ClaudeTextEditorCodeExecutionViewResult(
          fileType: _str(content['file_type']),
          content: _str(content['content']),
          numLines: _int(content['num_lines']),
          startLine: _int(content['start_line']),
          totalLines: _int(content['total_lines']),
        ),
      );
    } else {
      throw _error('invalid text editor code execution result type "$type"');
    }
    return ContentBlock(
      ServerToolResult(
        callId: _str(block['tool_use_id']),
        name: ClaudeServerToolName.textEditorCodeExecution.value,
        content: ClaudeServerToolResult(textEditorCodeExecution: result),
      ),
    );
  }

  /// A [ServerToolResult] block for a `tool_search_tool_result`.
  ///
  /// Not in Go (see [contentBlock]). The result goes to the field of the
  /// tool search tool whose `server_tool_use` had the same id, which comes
  /// first in a response; a result for an unknown call is a
  /// [ThreepioFormatException].
  ContentBlock toolSearchToolResult(Map<String, Object?> block) {
    final callId = _str(block['tool_use_id']);
    if (!isToolSearchCall(callId)) {
      throw _error('tool search result for unknown call "$callId"');
    }
    final name = _serverToolCalls[callId];
    final content = _map(block['content']) ?? const {};
    final type = _str(content['type']);
    final ClaudeToolSearchToolResult result;
    if (type == ClaudeToolSearchToolResultType.error.value) {
      result = ClaudeToolSearchToolResult(
        type: ClaudeToolSearchToolResultType.error,
        error: ClaudeToolSearchToolResultError(
          code: _str(content['error_code']),
          message: _str(content['error_message']),
        ),
      );
    } else if (type == ClaudeToolSearchToolResultType.searchResult.value) {
      result = ClaudeToolSearchToolResult(
        type: ClaudeToolSearchToolResultType.searchResult,
        searchResult: ClaudeToolSearchToolSearchResult(
          toolReferences: [
            for (final reference in _list(content['tool_references']))
              if (_map(reference) case final reference?)
                ClaudeToolSearchToolReference(
                  toolName: _str(reference['tool_name']),
                ),
          ],
        ),
      );
    } else {
      throw _error('invalid tool search tool result type "$type"');
    }
    return ContentBlock(
      ServerToolResult(
        callId: callId,
        name: name!.value,
        content: name == ClaudeServerToolName.toolSearchToolBm25
            ? ClaudeServerToolResult(toolSearchToolBm25: result)
            : ClaudeServerToolResult(toolSearchToolRegex: result),
      ),
    );
  }
}

List<ClaudeCodeExecutionOutput> _codeOutputs(Object? outputs) => [
  for (final output in _list(outputs))
    if (_map(output) case final output?)
      ClaudeCodeExecutionOutput(fileId: _str(output['file_id'])),
];

/// The document of a web fetch result. Port of eino-ext agenticclaude
/// `toWebFetchDocument`: plain text and base64 PDF sources.
@internal
ClaudeWebFetchDocument claudeAgenticWebFetchDocument(
  Map<String, Object?> content,
) {
  final citations = _map(content['citations']);
  final enabled = citations?['enabled'] == true;
  final source = _map(content['source']) ?? const {};
  final sourceType = _str(source['type']);
  if (sourceType != 'text' && sourceType != 'base64') {
    throw _error('invalid web fetch content source "$sourceType"');
  }
  return ClaudeWebFetchDocument(
    title: _str(content['title']),
    citations: enabled
        ? const ClaudeWebFetchDocumentCitations(enabled: true)
        : null,
    source: ClaudeWebFetchDocumentSource(
      mimeType: _str(source['media_type']),
      data: _str(source['data']),
    ),
  );
}

/// The token usage of a `usage` object (of a response, a `message_start` or
/// a `message_delta`).
///
/// Port of eino-ext agenticclaude `toTokenUsage` (and the usage part of
/// `toDeltaResponseMeta`): the prompt tokens are the input tokens plus
/// those read from and written to the cache.
@internal
TokenUsage claudeAgenticTokenUsage(Map<String, Object?>? usage) {
  final input = _int(usage?['input_tokens']);
  final cacheRead = _int(usage?['cache_read_input_tokens']);
  final cacheCreation = _int(usage?['cache_creation_input_tokens']);
  final output = _int(usage?['output_tokens']);
  final prompt = input + cacheRead + cacheCreation;
  return TokenUsage(
    promptTokens: prompt,
    completionTokens: output,
    totalTokens: prompt + output,
    promptTokenDetails: PromptTokenDetails(
      cachedTokens: cacheRead,
      cacheWriteTokens: cacheCreation,
    ),
  );
}

/// The response meta of a `message_delta` event. Port of eino-ext
/// agenticclaude `toDeltaResponseMeta`.
@internal
AgenticResponseMeta claudeAgenticDeltaResponseMeta(Map<String, Object?> event) {
  final delta = _map(event['delta']);
  return AgenticResponseMeta(
    tokenUsage: claudeAgenticTokenUsage(_map(event['usage'])),
    claudeExtension: ClaudeResponseMetaExtension(
      stopReason: _str(delta?['stop_reason']),
      stopSequence: _str(delta?['stop_sequence']),
      stopDetails: claudeAgenticStopDetails(_map(delta?['stop_details'])),
    ),
  );
}

/// Port of eino-ext agenticclaude `toClaudeStopDetails`: `null` when both
/// the category and the explanation are empty.
@internal
ClaudeStopDetails? claudeAgenticStopDetails(Map<String, Object?>? details) {
  final category = _str(details?['category']);
  final explanation = _str(details?['explanation']);
  if (category.isEmpty && explanation.isEmpty) return null;
  return ClaudeStopDetails(category: category, explanation: explanation);
}

/// The Claude extension of a text block with [citations] (the block's
/// `citations` list), or `null` when none of them is of a known type.
/// Port of eino-ext agenticclaude `toAssistantTextExtension`.
@internal
ClaudeAssistantGenTextExtension? claudeAgenticTextExtension(Object? citations) {
  final items = [
    for (final citation in _list(citations))
      if (claudeAgenticTextCitation(_map(citation) ?? const {})
          case final item?)
        item,
  ];
  if (items.isEmpty) return null;
  return ClaudeAssistantGenTextExtension(citations: items);
}

/// One citation of a text block or of a `citations_delta`, or `null` for a
/// type it does not know.
///
/// Port of eino-ext agenticclaude `toClaudeTextCitationFields` (with
/// `toClaudeTextCitation` and `toClaudeTextCitationFromDelta`).
@internal
ClaudeTextCitation? claudeAgenticTextCitation(Map<String, Object?> citation) {
  final type = ClaudeTextCitationType(_str(citation['type']));
  final citedText = _str(citation['cited_text']);
  final documentTitle = _str(citation['document_title']);
  final documentIndex = _int(citation['document_index']);
  if (type == ClaudeTextCitationType.charLocation) {
    return ClaudeTextCitation(
      type: type,
      charLocation: ClaudeCitationCharLocation(
        citedText: citedText,
        documentTitle: documentTitle,
        documentIndex: documentIndex,
        startCharIndex: _int(citation['start_char_index']),
        endCharIndex: _int(citation['end_char_index']),
      ),
    );
  }
  if (type == ClaudeTextCitationType.pageLocation) {
    return ClaudeTextCitation(
      type: type,
      pageLocation: ClaudeCitationPageLocation(
        citedText: citedText,
        documentTitle: documentTitle,
        documentIndex: documentIndex,
        startPageNumber: _int(citation['start_page_number']),
        endPageNumber: _int(citation['end_page_number']),
      ),
    );
  }
  if (type == ClaudeTextCitationType.contentBlockLocation) {
    return ClaudeTextCitation(
      type: type,
      contentBlockLocation: ClaudeCitationContentBlockLocation(
        citedText: citedText,
        documentTitle: documentTitle,
        documentIndex: documentIndex,
        startBlockIndex: _int(citation['start_block_index']),
        endBlockIndex: _int(citation['end_block_index']),
      ),
    );
  }
  if (type == ClaudeTextCitationType.webSearchResultLocation) {
    return ClaudeTextCitation(
      type: type,
      webSearchResultLocation: ClaudeCitationWebSearchResultLocation(
        citedText: citedText,
        title: _str(citation['title']),
        url: _str(citation['url']),
        encryptedIndex: _str(citation['encrypted_index']),
      ),
    );
  }
  return null;
}

/// The string under [key] in [input], `''` when absent. Port of eino-ext
/// agenticclaude `setStringArgument`: a value that is not a string is a
/// [ThreepioFormatException].
String _stringArgument(Map<String, Object?> input, String key) {
  if (!input.containsKey(key)) return '';
  final value = input[key];
  if (value is String) return value;
  throw _error(
    'failed to set "$key" argument: expected string, got '
    '${claudeGoTypeName(value)}',
  );
}

String _str(Object? value) => value is String ? value : '';

int _int(Object? value) => value is num ? value.toInt() : 0;

Map<String, Object?>? _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

List<Object?> _list(Object? value) =>
    value is List ? value.cast<Object?>() : const [];
