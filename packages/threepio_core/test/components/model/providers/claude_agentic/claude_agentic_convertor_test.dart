// Port of eino-ext components/model/agenticclaude/convertor_test.go. The Go
// tests build anthropic-sdk-go structs (or unmarshal their JSON); here the
// converters take and give the JSON maps directly, and the Go `mustJSON`
// substring checks read the maps. All 28 Go tests are ported:
//   TestToFunctionToolsPreservesFullJSONSchema,
//   TestToFunctionToolsRejectsUnserializableFullJSONSchema,
//   TestToolSearchResultToBlockParam, TestServerToolResultToBlockParam,
//   TestServerToolUseToContentBlock, TestToDeltaResponseMeta,
//   TestToAnthropicTextCitations, TestToWebFetchDocumentBlockParam,
//   TestToAnthropicMessages, TestToAnthropicMessagesErrors,
//   TestToAgenticMessage, TestToAgenticContentBlock,
//   TestToolMediaAndResultConversionHelpers,
//   TestWebSearchToolResultToContentBlock,
//   TestWebFetchToolResultToContentBlock,
//   TestCodeExecutionToolResultToContentBlock,
//   TestBashCodeExecutionToolResultToContentBlock,
//   TestTextEditorCodeExecutionToolResultToContentBlock,
//   TestToClaudeTextCitationFieldsCoverage, TestToAssistantTextExtension,
//   TestToAnthropicTextCitationsAdditional, TestServerToolCallToBlockParam,
//   TestTextEditorCodeExecutionToolResultToBlockParamCoverage,
//   TestCodeExecutionToolResultToBlockParamCoverage,
//   TestBashCodeExecutionToolResultToBlockParamCoverage,
//   TestToAgenticContentBlockServerToolResults,
//   TestAssistantGenTextToBlockParamWithCitations,
//   TestToAnthropicMessagesMergeToolOnly.
// Adapted: the `nil` entries of Go's `[]*CodeExecutionOutput` (Dart lists
// hold no nulls), and "invalid type" of TestToAgenticContentBlock (Go
// passes an `int`; here a block of an unknown `type`). Plus tests for the
// tool search results the Go output side does not convert.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_consts.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_convertor.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_extension.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_utils.dart';
import 'package:threepio_core/threepio_core.dart';

String _json(Object? value) => jsonEncode(value);

Matcher _formatError(Object message) =>
    isA<ThreepioFormatException>().having((e) => e.message, 'message', message);

ToolInfo _toolInfo(String name) => ToolInfo.fromJsonSchemaMap(
  name: name,
  desc: '$name desc',
  schema: const {'type': 'object'},
);

ClaudeServerToolResult _content(ContentBlock block) =>
    block.serverToolResult!.content! as ClaudeServerToolResult;

ContentBlock _resultBlock(Map<String, Object?> json) =>
    ClaudeAgenticBlockConverter().contentBlock(json)!;

void main() {
  test('TestToFunctionToolsPreservesFullJSONSchema', () {
    final tools = claudeAgenticFunctionTools([
      ToolInfo.fromJsonSchemaMap(
        name: 'manage_resource',
        schema: const {
          'type': 'object',
          'properties': {
            'action': {'type': 'string'},
          },
          'required': ['action'],
          'additionalProperties': false,
          'oneOf': [
            {
              'type': 'object',
              'required': ['action', 'name'],
            },
          ],
        },
      ),
    ]);
    final inputSchema = tools[0]['input_schema']! as Map<String, Object?>;
    expect(inputSchema['oneOf'], isNotNull);
    expect(inputSchema['additionalProperties'], isFalse);
    expect(inputSchema['type'], 'object');
    expect(inputSchema['required'], ['action']);
    expect(inputSchema['properties'], {
      'action': {'type': 'string'},
    });
  });

  test('TestToFunctionToolsRejectsUnserializableFullJSONSchema', () {
    final tool = ToolInfo(
      function: FunctionInfo(
        name: 'invalid_schema',
        parametersJsonSchema: {'type': 'object', 'x-invalid': Object()},
      ),
    );
    expect(
      () => claudeAgenticFunctionTools([tool]),
      throwsA(_formatError(contains('marshal full JSON schema'))),
    );
  });

  test('TestToolSearchResultToBlockParam', () {
    final block = claudeAgenticToolSearchResultBlock(
      ToolSearchFunctionToolResult(
        callId: 'call_1',
        result: ToolSearchResult(
          tools: [
            ToolInfo.function(name: 'tool_a'),
            ToolInfo.function(name: 'tool_b'),
          ],
        ),
      ),
    );
    expect(block, {
      'type': 'tool_result',
      'tool_use_id': 'call_1',
      'content': [
        {'type': 'tool_reference', 'tool_name': 'tool_a'},
        {'type': 'tool_reference', 'tool_name': 'tool_b'},
      ],
    });
  });

  group('TestServerToolResultToBlockParam', () {
    test('tool search search result', () {
      final block = claudeAgenticServerToolResultBlock(
        ContentBlock(
          ServerToolResult(
            callId: 'call_1',
            name: ClaudeServerToolName.toolSearchToolBm25.value,
            content: ClaudeServerToolResult(
              toolSearchToolBm25: ClaudeToolSearchToolResult(
                type: ClaudeToolSearchToolResultType.searchResult,
                searchResult: ClaudeToolSearchToolSearchResult(
                  toolReferences: const [
                    ClaudeToolSearchToolReference(toolName: 'tool_a'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(block, {
        'type': 'tool_search_tool_result',
        'tool_use_id': 'call_1',
        'content': {
          'type': 'tool_search_tool_search_result',
          'tool_references': [
            {'type': 'tool_reference', 'tool_name': 'tool_a'},
          ],
        },
      });
    });

    test('tool search error', () {
      final block = claudeAgenticServerToolResultBlock(
        ContentBlock(
          ServerToolResult(
            callId: 'call_2',
            name: ClaudeServerToolName.toolSearchToolRegex.value,
            content: const ClaudeServerToolResult(
              toolSearchToolRegex: ClaudeToolSearchToolResult(
                type: ClaudeToolSearchToolResultType.error,
                error: ClaudeToolSearchToolResultError(code: 'invalid_query'),
              ),
            ),
          ),
        ),
      );
      final json = _json(block);
      expect(json, contains('"type":"tool_search_tool_result"'));
      expect(json, contains('"type":"tool_search_tool_result_error"'));
      expect(json, contains('"error_code":"invalid_query"'));
    });
  });

  group('TestServerToolUseToContentBlock', () {
    test('tool search bm25 input', () {
      final block = ClaudeAgenticBlockConverter().serverToolUse({
        'type': 'server_tool_use',
        'id': 'call_1',
        'name': 'tool_search_tool_bm25',
        'input': {'query': 'find tools'},
      });
      final args =
          block.serverToolCall!.arguments! as ClaudeServerToolCallArguments;
      expect(args.toolSearchToolBm25?.query, 'find tools');
    });

    test('web fetch nil input keeps empty args', () {
      final block = ClaudeAgenticBlockConverter().serverToolUse({
        'type': 'server_tool_use',
        'id': 'call_2',
        'name': 'web_fetch',
      });
      final args =
          block.serverToolCall!.arguments! as ClaudeServerToolCallArguments;
      expect(args.webFetch, isNotNull);
      expect(args.webFetch!.url, '');
    });

    test('a field that is not a string fails', () {
      expect(
        () => ClaudeAgenticBlockConverter().serverToolUse({
          'id': 'call_3',
          'name': 'web_search',
          'input': {'query': 5},
        }),
        throwsA(
          _formatError(
            'invalid web search query: failed to set "query" argument: '
            'expected string, got float64',
          ),
        ),
      );
    });

    test('an input that is not an object fails', () {
      expect(
        () => ClaudeAgenticBlockConverter().serverToolUse({
          'id': 'call_4',
          'name': 'code_execution',
          'input': 'print(1)',
        }),
        throwsA(
          _formatError('unexpected type string for code execution input'),
        ),
      );
    });

    test('an unknown tool fails', () {
      expect(
        () => ClaudeAgenticBlockConverter().serverToolUse({
          'id': 'x',
          'name': 'mystery',
        }),
        throwsA(_formatError('invalid server tool "mystery"')),
      );
    });
  });

  test('TestToDeltaResponseMeta', () {
    final meta = claudeAgenticDeltaResponseMeta({
      'type': 'message_delta',
      'usage': {
        'input_tokens': 10,
        'cache_read_input_tokens': 3,
        'cache_creation_input_tokens': 2,
        'output_tokens': 7,
      },
      'delta': {
        'stop_reason': 'end_turn',
        'stop_sequence': 'done',
        'stop_details': {
          'type': 'refusal',
          'category': 'bio',
          'explanation': 'blocked',
        },
      },
    });
    expect(meta.tokenUsage!.promptTokens, 15);
    expect(meta.tokenUsage!.completionTokens, 7);
    expect(meta.tokenUsage!.totalTokens, 22);
    expect(meta.tokenUsage!.promptTokenDetails!.cachedTokens, 3);
    expect(meta.tokenUsage!.promptTokenDetails!.cacheWriteTokens, 2);
    expect(meta.claudeExtension!.stopReason, 'end_turn');
    expect(meta.claudeExtension!.stopSequence, 'done');
    expect(meta.claudeExtension!.stopDetails!.explanation, 'blocked');
    expect(meta.claudeExtension!.stopDetails!.category, 'bio');
  });

  test('TestToAnthropicTextCitations', () {
    final citations = claudeAgenticTextCitationParams(const [
      ClaudeTextCitation(
        type: ClaudeTextCitationType.webSearchResultLocation,
        webSearchResultLocation: ClaudeCitationWebSearchResultLocation(
          citedText: 'snippet',
          title: 'result title',
          url: 'https://example.com',
          encryptedIndex: 'enc_1',
        ),
      ),
    ]);
    expect(citations, [
      {
        'type': 'web_search_result_location',
        'cited_text': 'snippet',
        'title': 'result title',
        'url': 'https://example.com',
        'encrypted_index': 'enc_1',
      },
    ]);
  });

  group('TestToWebFetchDocumentBlockParam', () {
    test('invalid mime type', () {
      expect(
        () => claudeAgenticWebFetchDocumentParam(
          const ClaudeWebFetchDocument(
            source: ClaudeWebFetchDocumentSource(
              mimeType: 'application/json',
              data: '{}',
            ),
          ),
        ),
        throwsA(
          _formatError(
            contains('invalid web fetch content mime type "application/json"'),
          ),
        ),
      );
    });

    test('plain text document', () {
      final param = claudeAgenticWebFetchDocumentParam(
        const ClaudeWebFetchDocument(
          title: 'doc',
          citations: ClaudeWebFetchDocumentCitations(enabled: true),
          source: ClaudeWebFetchDocumentSource(
            mimeType: 'text/plain',
            data: 'hello',
          ),
        ),
      );
      expect(param, {
        'type': 'document',
        'source': {'type': 'text', 'media_type': 'text/plain', 'data': 'hello'},
        'title': 'doc',
        'citations': {'enabled': true},
      });
    });

    test('pdf document, nil document and nil source', () {
      final param = claudeAgenticWebFetchDocumentParam(
        const ClaudeWebFetchDocument(
          source: ClaudeWebFetchDocumentSource(
            mimeType: 'application/pdf',
            data: 'JVBERi0=',
          ),
        ),
      );
      expect(param['source'], {
        'type': 'base64',
        'media_type': 'application/pdf',
        'data': 'JVBERi0=',
      });
      expect(
        () => claudeAgenticWebFetchDocumentParam(null),
        throwsA(_formatError('web fetch content is nil')),
      );
      expect(
        () =>
            claudeAgenticWebFetchDocumentParam(const ClaudeWebFetchDocument()),
        throwsA(_formatError('web fetch content source is nil')),
      );
    });
  });

  test('TestToAnthropicMessages', () {
    final input = [
      AgenticMessage.system('follow system'),
      AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [
          ContentBlock(const UserInputText(text: 'hello')),
          ContentBlock(
            const UserInputImage(url: 'https://example.com/image.png'),
          ),
          ContentBlock(const UserInputFile(url: 'https://example.com/doc.pdf')),
          ContentBlock(
            FunctionToolResult(
              callId: 'call_fn',
              name: 'get_weather',
              content: [
                FunctionToolResultContentBlock(
                  const UserInputText(text: 'sunny'),
                ),
              ],
            ),
          ),
          ContentBlock(
            ToolSearchFunctionToolResult(
              callId: 'call_search',
              result: ToolSearchResult(
                tools: [ToolInfo.function(name: 'tool_a')],
              ),
            ),
          ),
        ],
      ),
      AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(const AssistantGenText(text: 'answer')),
          ContentBlock(const Reasoning(text: 'thinking', signature: 'sig_1')),
          ContentBlock(
            const FunctionToolCall(
              callId: 'call_tool',
              name: 'get_weather',
              arguments: '{"city":"beijing"}',
            ),
          ),
          ContentBlock(
            ServerToolCall(
              callId: 'call_server',
              name: ClaudeServerToolName.webSearch.value,
              arguments: const ClaudeServerToolCallArguments(
                webSearch: ClaudeWebSearchArguments(query: 'golang'),
              ),
            ),
          ),
        ],
      ),
    ];

    final (:system, :messages) = claudeAgenticToAnthropicMessages(input);
    expect(system, [
      {'type': 'text', 'text': 'follow system'},
    ]);
    expect(messages, hasLength(2));
    expect(messages[0]['role'], 'user');
    expect(messages[1]['role'], 'assistant');

    final json = _json(messages);
    for (final want in [
      '"text":"hello"',
      '"type":"image"',
      '"type":"document"',
      '"tool_use_id":"call_fn"',
      '"tool_use_id":"call_search"',
      '"tool_name":"tool_a"',
      '"thinking":"thinking"',
      '"signature":"sig_1"',
      '"type":"tool_use"',
      '"name":"web_search"',
    ]) {
      expect(json, contains(want));
    }
    final toolUse = (messages[1]['content']! as List)[2] as Map;
    expect(toolUse['input'], {'city': 'beijing'});
    final serverToolUse = (messages[1]['content']! as List)[3] as Map;
    expect(serverToolUse, {
      'type': 'server_tool_use',
      'id': 'call_server',
      'name': 'web_search',
      'input': {'query': 'golang'},
    });
  });

  group('TestToAnthropicMessagesErrors', () {
    test('empty input', () {
      expect(
        () => claudeAgenticToAnthropicMessages(const []),
        throwsA(_formatError('input is empty')),
      );
    });

    test('system after user is allowed inline', () {
      final (:system, :messages) = claudeAgenticToAnthropicMessages([
        AgenticMessage.user('hello'),
        AgenticMessage.system('late system'),
      ]);
      expect(system, isEmpty);
      expect(messages, hasLength(2));
      expect(messages[1]['role'], 'system');
    });

    test('only system messages', () {
      expect(
        () => claudeAgenticToAnthropicMessages([AgenticMessage.system('s')]),
        throwsA(_formatError('input contains only system messages')),
      );
    });

    test('blocks a role cannot carry', () {
      expect(
        () => claudeAgenticToAnthropicMessages([
          AgenticMessage(
            role: AgenticRoleType.user,
            contentBlocks: [ContentBlock(const UserInputAudio(url: 'a'))],
          ),
        ]),
        throwsA(
          _formatError(
            'invalid content block type "user_input_audio" with user role',
          ),
        ),
      );
      expect(
        () => claudeAgenticToAnthropicMessages([
          AgenticMessage.user('hi'),
          AgenticMessage(
            role: AgenticRoleType.assistant,
            contentBlocks: [ContentBlock(const UserInputText(text: 'x'))],
          ),
        ]),
        throwsA(
          _formatError(
            'invalid content block type "user_input_text" with assistant role',
          ),
        ),
      );
      expect(
        () => claudeAgenticToAnthropicMessages([
          AgenticMessage(
            role: AgenticRoleType.system,
            contentBlocks: [ContentBlock(const Reasoning(text: 'x'))],
          ),
          AgenticMessage.user('hi'),
        ]),
        throwsA(
          _formatError(
            'system message only supports text blocks, got '
            '"reasoning"',
          ),
        ),
      );
    });

    test('function tool call arguments that are not JSON', () {
      expect(
        () => claudeAgenticToolUseBlock(
          const FunctionToolCall(callId: 'c', name: 'f', arguments: '{"a":'),
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(
        claudeAgenticToolUseBlock(const FunctionToolCall(callId: 'c')),
        containsPair('input', <String, Object?>{}),
      );
    });
  });

  test('TestToAgenticMessage', () {
    final msg = ClaudeAgenticBlockConverter().message(
      (jsonDecode('''{
        "id":"msg_1",
        "type":"message",
        "role":"assistant",
        "model":"claude-sonnet-4-20250514",
        "content":[
          {"type":"text","text":"hello"},
          {"type":"thinking","thinking":"reasoning","signature":"sig_1"},
          {"type":"tool_use","id":"call_1","name":"get_weather","input":{"city":"beijing"}},
          {"type":"redacted_thinking","data":"secret"}
        ],
        "stop_reason":"end_turn",
        "usage":{"input_tokens":3,"output_tokens":5}
      }''')
              as Map)
          .cast<String, Object?>(),
    );
    expect(msg.role, AgenticRoleType.assistant);
    expect(msg.contentBlocks, hasLength(3));
    expect(msg.contentBlocks[0].assistantGenText?.text, 'hello');
    expect(msg.contentBlocks[1].reasoning?.signature, 'sig_1');
    expect(msg.contentBlocks[1].reasoning?.text, 'reasoning');
    expect(
      msg.contentBlocks[2].functionToolCall?.arguments,
      '{"city":"beijing"}',
    );
    expect(msg.contentBlocks[2].functionToolCall?.callId, 'call_1');
    expect(msg.responseMeta?.claudeExtension?.id, 'msg_1');
    expect(msg.responseMeta?.claudeExtension?.stopReason, 'end_turn');
    expect(msg.responseMeta?.tokenUsage?.totalTokens, 8);
    expect(msg.extra, isNull);
  });

  group('TestToAgenticContentBlock', () {
    test('server tool use', () {
      final block = ClaudeAgenticBlockConverter().contentBlock({
        'type': 'server_tool_use',
        'id': 'call_1',
        'name': 'web_fetch',
        'input': {'url': 'https://example.com'},
      });
      expect(block?.serverToolCall?.name, ClaudeServerToolName.webFetch.value);
      expect(block?.serverToolCall?.callId, 'call_1');
    });

    test('redacted thinking dropped', () {
      expect(
        ClaudeAgenticBlockConverter().contentBlock({
          'type': 'redacted_thinking',
          'data': 'x',
        }),
        isNull,
      );
    });

    test('invalid type', () {
      expect(
        () => ClaudeAgenticBlockConverter().contentBlock({
          'type': 'container_upload',
        }),
        throwsA(_formatError('invalid output block type "container_upload"')),
      );
    });
  });

  group('TestToolMediaAndResultConversionHelpers', () {
    test('image and file block params', () {
      final image = claudeAgenticImageBlock(
        const UserInputImage(base64Data: 'aGVsbG8=', mimeType: 'image/png'),
      );
      final file = claudeAgenticDocumentBlock(
        const UserInputFile(base64Data: 'aGVsbG8='),
      );
      expect(image, {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'aGVsbG8=',
        },
      });
      expect(file, {
        'type': 'document',
        'source': {
          'type': 'base64',
          'media_type': 'application/pdf',
          'data': 'aGVsbG8=',
        },
      });
    });

    test('image media types and missing sources', () {
      expect(claudeAgenticImageMediaType('image/jpg'), 'image/jpeg');
      expect(claudeAgenticImageMediaType('image/webp'), 'image/webp');
      expect(claudeAgenticImageMediaType('image/gif'), 'image/gif');
      expect(
        () => claudeAgenticImageMediaType('image/bmp'),
        throwsA(_formatError('invalid image mime type "image/bmp"')),
      );
      expect(
        () => claudeAgenticImageBlock(const UserInputImage()),
        throwsA(_formatError('image input requires URL, Base64Data or FileID')),
      );
      expect(
        () => claudeAgenticDocumentBlock(const UserInputFile()),
        throwsA(_formatError('file input requires URL, Base64Data or FileID')),
      );
    });

    test('function tool result content image and file', () {
      final image = claudeAgenticFunctionToolResultContent(
        FunctionToolResultContentBlock(
          const UserInputImage(url: 'https://example.com/image.png'),
        ),
      );
      final file = claudeAgenticFunctionToolResultContent(
        FunctionToolResultContentBlock(
          const UserInputFile(url: 'https://example.com/doc.pdf'),
        ),
      );
      expect(image['type'], 'image');
      expect(image['source'], {
        'type': 'url',
        'url': 'https://example.com/image.png',
      });
      expect(file['type'], 'document');
      expect(
        () => claudeAgenticFunctionToolResultContent(
          FunctionToolResultContentBlock(const UserInputVideo(url: 'v')),
        ),
        throwsA(
          _formatError(
            'invalid function tool result content block type '
            '"video"',
          ),
        ),
      );
    });

    test('web search and web fetch result block params', () {
      final searchBlock = claudeWithWebSearchResultCaller(
        ContentBlock(const ServerToolResult()),
        {'type': 'direct'},
      );
      final search = claudeAgenticWebSearchResultBlock(
        ClaudeWebSearchResult(
          type: ClaudeWebSearchResultType.result,
          result: ClaudeWebSearchResultBlock(
            content: const [
              ClaudeWebSearchResultItem(
                title: 'doc',
                url: 'https://example.com',
                encryptedContent: 'enc_1',
                pageAge: '1 day',
              ),
            ],
          ),
        ),
        'call_search',
        searchBlock,
      );
      final fetchBlock = claudeWithWebFetchResultCaller(
        ContentBlock(const ServerToolResult()),
        {'type': 'direct'},
      );
      final fetch = claudeAgenticWebFetchResultBlock(
        const ClaudeWebFetchResult(
          type: ClaudeWebFetchResultType.result,
          result: ClaudeWebFetchResultBlock(
            url: 'https://example.com',
            retrievedAt: '2026-05-19T00:00:00Z',
            content: ClaudeWebFetchDocument(
              title: 'doc',
              source: ClaudeWebFetchDocumentSource(
                mimeType: 'text/plain',
                data: 'hello',
              ),
            ),
          ),
        ),
        'call_fetch',
        fetchBlock,
      );
      final json = _json([search, fetch]);
      for (final want in [
        '"type":"web_search_tool_result"',
        '"encrypted_content":"enc_1"',
        '"type":"web_fetch_tool_result"',
        '"retrieved_at":"2026-05-19T00:00:00Z"',
        '"caller":{"type":"direct"}',
      ]) {
        expect(json, contains(want));
      }
      expect(search['content'], [
        {
          'type': 'web_search_result',
          'title': 'doc',
          'url': 'https://example.com',
          'encrypted_content': 'enc_1',
          'page_age': '1 day',
        },
      ]);
      expect(fetch['caller'], {'type': 'direct'});
    });

    test('web search and web fetch errors; no caller', () {
      final search = claudeAgenticWebSearchResultBlock(
        const ClaudeWebSearchResult(
          type: ClaudeWebSearchResultType.error,
          error: ClaudeWebSearchResultError(code: 'max_uses_exceeded'),
        ),
        'call',
        ContentBlock(const ServerToolResult()),
      );
      expect(search, {
        'type': 'web_search_tool_result',
        'tool_use_id': 'call',
        'content': {
          'type': 'web_search_tool_result_error',
          'error_code': 'max_uses_exceeded',
        },
      });
      final fetch = claudeAgenticWebFetchResultBlock(
        const ClaudeWebFetchResult(
          type: ClaudeWebFetchResultType.error,
          error: ClaudeWebFetchResultError(code: 'url_not_accessible'),
        ),
        'call',
        ContentBlock(const ServerToolResult()),
      );
      expect(fetch['content'], {
        'type': 'web_fetch_tool_result_error',
        'error_code': 'url_not_accessible',
      });
      expect(
        () => claudeAgenticWebSearchResultBlock(
          const ClaudeWebSearchResult(),
          'call',
          ContentBlock(const ServerToolResult()),
        ),
        throwsA(_formatError('invalid web search result type ""')),
      );
      expect(
        () => claudeAgenticWebFetchResultBlock(
          const ClaudeWebFetchResult(type: ClaudeWebFetchResultType('x')),
          'call',
          ContentBlock(const ServerToolResult()),
        ),
        throwsA(_formatError('invalid web fetch result type "x"')),
      );
    });

    test('execution result block params and output helpers', () {
      final code = claudeAgenticCodeExecutionResultBlock(
        ClaudeCodeExecutionResult(
          type: ClaudeCodeExecutionResultType.result,
          result: ClaudeCodeExecutionResultBlock(
            content: const [ClaudeCodeExecutionOutput(fileId: 'file_1')],
            stdout: 'stdout',
          ),
        ),
        'call_code',
      );
      final bash = claudeAgenticBashCodeExecutionResultBlock(
        ClaudeBashCodeExecutionResult(
          type: ClaudeBashCodeExecutionResultType.result,
          result: ClaudeBashCodeExecutionResultBlock(
            content: const [ClaudeCodeExecutionOutput(fileId: 'file_2')],
            stdout: 'ok',
          ),
        ),
        'call_bash',
      );
      final editor = claudeAgenticTextEditorCodeExecutionResultBlock(
        const ClaudeTextEditorCodeExecutionResult(
          type: ClaudeTextEditorCodeExecutionResultType.view,
          view: ClaudeTextEditorCodeExecutionViewResult(
            fileType: 'text',
            content: 'hello',
            numLines: 1,
            startLine: 1,
            totalLines: 1,
          ),
        ),
        'call_editor',
      );
      final json = _json([code, bash, editor]);
      for (final want in [
        '"type":"code_execution_tool_result"',
        '"type":"bash_code_execution_tool_result"',
        '"type":"text_editor_code_execution_tool_result"',
        '"file_id":"file_1"',
        '"file_id":"file_2"',
      ]) {
        expect(json, contains(want));
      }
      expect(code['content'], {
        'type': 'code_execution_result',
        'content': [
          {'type': 'code_execution_output', 'file_id': 'file_1'},
        ],
        'stdout': 'stdout',
        'stderr': '',
        'return_code': 0,
      });
      expect((bash['content']! as Map)['content'], [
        {'type': 'bash_code_execution_output', 'file_id': 'file_2'},
      ]);
      expect(editor['content'], {
        'type': 'text_editor_code_execution_view_result',
        'file_type': 'text',
        'content': 'hello',
        'num_lines': 1,
        'start_line': 1,
        'total_lines': 1,
      });

      // Go's toCodeExecutionOutputs / toBashCodeExecutionOutputs.
      final output = ClaudeAgenticBlockConverter().contentBlock({
        'type': 'code_execution_tool_result',
        'tool_use_id': 'c',
        'content': {
          'type': 'code_execution_result',
          'content': [
            {'type': 'code_execution_output', 'file_id': 'file_1'},
          ],
        },
      })!;
      expect(
        _content(output).codeExecution!.result!.content.single.fileId,
        'file_1',
      );
    });

    test('server tool use helpers', () {
      final cases = <Map<String, Object?>>[
        {
          'id': 'call_search',
          'name': 'web_search',
          'input': {'query': 'golang'},
        },
        {
          'id': 'call_code',
          'name': 'code_execution',
          'input': {'code': 'print(1)'},
        },
        {
          'id': 'call_bash',
          'name': 'bash_code_execution',
          'input': {'command': 'ls'},
        },
        {
          'id': 'call_editor',
          'name': 'text_editor_code_execution',
          'input': {'command': 'view', 'path': '/tmp/a.txt'},
        },
        {
          'id': 'call_regex',
          'name': 'tool_search_tool_regex',
          'input': {'query': 'find.*'},
        },
      ];
      for (final c in cases) {
        final block = ClaudeAgenticBlockConverter().serverToolUse(c);
        expect(block.serverToolCall!.name, c['name']);
      }
      final editor = ClaudeAgenticBlockConverter().serverToolUse(cases[3]);
      final args =
          editor.serverToolCall!.arguments! as ClaudeServerToolCallArguments;
      expect(
        args.textEditorCodeExecution,
        const ClaudeTextEditorCodeExecutionArguments(
          command: 'view',
          path: '/tmp/a.txt',
        ),
      );
    });
  });

  group('TestWebSearchToolResultToContentBlock', () {
    test('result type', () {
      final block = _resultBlock({
        'type': 'web_search_tool_result',
        'tool_use_id': 'call_1',
        'content': [
          {
            'type': 'web_search_result',
            'title': 'Go',
            'url': 'https://go.dev',
            'encrypted_content': 'enc',
            'page_age': '2 days',
          },
        ],
      });
      final result = _content(block).webSearch!;
      expect(result.type, ClaudeWebSearchResultType.result);
      expect(result.result!.content.single.title, 'Go');
      expect(block.serverToolResult!.callId, 'call_1');
      expect(block.serverToolResult!.name, 'web_search');
      // As Go stores caller.RawJSON(): empty without a caller.
      expect(block.extra, {claudeAgenticKeyOfWebSearchToolResultCaller: ''});
    });

    test('error type', () {
      final block = _resultBlock({
        'type': 'web_search_tool_result',
        'tool_use_id': 'call_2',
        'content': {
          'type': 'web_search_tool_result_error',
          'error_code': 'rate_limited',
        },
      });
      final result = _content(block).webSearch!;
      expect(result.type, ClaudeWebSearchResultType.error);
      expect(result.error!.code, 'rate_limited');
    });

    test('invalid type', () {
      expect(
        () => _resultBlock({
          'type': 'web_search_tool_result',
          'tool_use_id': 'call_3',
          'content': {'type': 'unknown_type'},
        }),
        throwsA(_formatError(contains('invalid web search result type'))),
      );
    });
  });

  group('TestWebFetchToolResultToContentBlock', () {
    test('result type', () {
      final block = _resultBlock({
        'type': 'web_fetch_tool_result',
        'tool_use_id': 'call_1',
        'content': {
          'type': 'web_fetch_result',
          'url': 'https://example.com',
          'retrieved_at': '2026-05-19T00:00:00Z',
          'content': {
            'type': 'document',
            'title': 'doc',
            'source': {
              'type': 'text',
              'media_type': 'text/plain',
              'data': 'hello',
            },
            'citations': {'enabled': true},
          },
        },
        'caller': {'type': 'direct'},
      });
      final result = _content(block).webFetch!;
      expect(result.type, ClaudeWebFetchResultType.result);
      expect(result.result!.url, 'https://example.com');
      expect(
        result.result!.content,
        const ClaudeWebFetchDocument(
          title: 'doc',
          citations: ClaudeWebFetchDocumentCitations(enabled: true),
          source: ClaudeWebFetchDocumentSource(
            mimeType: 'text/plain',
            data: 'hello',
          ),
        ),
      );
      expect(block.extra, {
        claudeAgenticKeyOfWebFetchToolResultCaller: '{"type":"direct"}',
      });
    });

    test('error type', () {
      final block = _resultBlock({
        'type': 'web_fetch_tool_result',
        'tool_use_id': 'call_2',
        'content': {
          'type': 'web_fetch_tool_result_error',
          'error_code': 'fetch_failed',
        },
      });
      expect(_content(block).webFetch!.type, ClaudeWebFetchResultType.error);
    });

    test('invalid type', () {
      expect(
        () => _resultBlock({
          'type': 'web_fetch_tool_result',
          'tool_use_id': 'call_3',
          'content': {'type': 'invalid'},
        }),
        throwsA(_formatError(contains('invalid web fetch result type'))),
      );
    });

    test('invalid source', () {
      expect(
        () => _resultBlock({
          'type': 'web_fetch_tool_result',
          'tool_use_id': 'call_4',
          'content': {
            'type': 'web_fetch_result',
            'content': {
              'type': 'document',
              'source': {'type': 'url', 'url': 'https://x'},
            },
          },
        }),
        throwsA(_formatError('invalid web fetch content source "url"')),
      );
    });
  });

  group('TestCodeExecutionToolResultToContentBlock', () {
    test('result type', () {
      final block = _resultBlock({
        'type': 'code_execution_tool_result',
        'tool_use_id': 'call_1',
        'content': {
          'type': 'code_execution_result',
          'stdout': 'hello',
          'stderr': '',
          'return_code': 0,
          'content': [
            {'type': 'code_execution_output', 'file_id': 'f1'},
          ],
        },
      });
      final result = _content(block).codeExecution!;
      expect(result.type, ClaudeCodeExecutionResultType.result);
      expect(result.result!.stdout, 'hello');
      expect(block.serverToolResult!.name, 'code_execution');
    });

    test('error type', () {
      final block = _resultBlock({
        'type': 'code_execution_tool_result',
        'tool_use_id': 'call_2',
        'content': {
          'type': 'code_execution_tool_result_error',
          'error_code': 'timeout',
        },
      });
      expect(
        _content(block).codeExecution!.type,
        ClaudeCodeExecutionResultType.error,
      );
    });

    test('encrypted type', () {
      final block = _resultBlock({
        'type': 'code_execution_tool_result',
        'tool_use_id': 'call_3',
        'content': {
          'type': 'encrypted_code_execution_result',
          'encrypted_stdout': 'enc_data',
          'stderr': 'err',
          'return_code': 1,
          'content': [
            {'type': 'code_execution_output', 'file_id': 'f2'},
          ],
        },
      });
      final result = _content(block).codeExecution!;
      expect(result.type, ClaudeCodeExecutionResultType.encrypted);
      expect(result.encryptedResult!.encryptedStdout, 'enc_data');
      expect(result.encryptedResult!.returnCode, 1);
    });
  });

  group('TestBashCodeExecutionToolResultToContentBlock', () {
    test('result type', () {
      final block = _resultBlock({
        'type': 'bash_code_execution_tool_result',
        'tool_use_id': 'call_1',
        'content': {
          'type': 'bash_code_execution_result',
          'stdout': 'ok',
          'stderr': '',
          'return_code': 0,
          'content': <Object?>[],
        },
      });
      expect(
        _content(block).bashCodeExecution!.type,
        ClaudeBashCodeExecutionResultType.result,
      );
    });

    test('error type', () {
      final block = _resultBlock({
        'type': 'bash_code_execution_tool_result',
        'tool_use_id': 'call_2',
        'content': {
          'type': 'bash_code_execution_tool_result_error',
          'error_code': 'sandbox_error',
        },
      });
      expect(
        _content(block).bashCodeExecution!.type,
        ClaudeBashCodeExecutionResultType.error,
      );
    });
  });

  group('TestTextEditorCodeExecutionToolResultToContentBlock', () {
    ClaudeTextEditorCodeExecutionResult convert(Map<String, Object?> c) =>
        _content(
          _resultBlock({
            'type': 'text_editor_code_execution_tool_result',
            'tool_use_id': 'call',
            'content': c,
          }),
        ).textEditorCodeExecution!;

    test('view result', () {
      final result = convert({
        'type': 'text_editor_code_execution_view_result',
        'file_type': 'python',
        'content': 'print(1)',
        'num_lines': 1,
        'start_line': 1,
        'total_lines': 1,
      });
      expect(result.type, ClaudeTextEditorCodeExecutionResultType.view);
      expect(result.view!.fileType, 'python');
    });

    test('create result', () {
      final result = convert({
        'type': 'text_editor_code_execution_create_result',
        'is_file_update': true,
      });
      expect(result.type, ClaudeTextEditorCodeExecutionResultType.create);
      expect(result.create!.isFileUpdate, isTrue);
    });

    test('str replace result', () {
      final result = convert({
        'type': 'text_editor_code_execution_str_replace_result',
        'old_start': 1,
        'old_lines': 2,
        'new_start': 1,
        'new_lines': 3,
        'lines': ['a', 'b'],
      });
      expect(result.type, ClaudeTextEditorCodeExecutionResultType.strReplace);
      expect(result.strReplace!.lines, ['a', 'b']);
      expect(result.strReplace!.newLines, 3);
    });

    test('error result', () {
      final result = convert({
        'type': 'text_editor_code_execution_tool_result_error',
        'error_code': 'file_not_found',
        'error_message': 'not found',
      });
      expect(result.type, ClaudeTextEditorCodeExecutionResultType.error);
      expect(result.error!.message, 'not found');
    });
  });

  group('TestToClaudeTextCitationFieldsCoverage', () {
    test('char location', () {
      final result = claudeAgenticTextCitation({
        'type': 'char_location',
        'cited_text': 'hello',
        'document_title': 'doc',
        'document_index': 1,
        'start_char_index': 10,
        'end_char_index': 15,
      });
      expect(result?.charLocation?.startCharIndex, 10);
      expect(result?.charLocation?.documentTitle, 'doc');
    });

    test('page location', () {
      final result = claudeAgenticTextCitation({
        'type': 'page_location',
        'cited_text': 'page',
        'document_index': 2,
        'start_page_number': 5,
        'end_page_number': 6,
      });
      expect(result?.pageLocation?.startPageNumber, 5);
    });

    test('content block location', () {
      final result = claudeAgenticTextCitation({
        'type': 'content_block_location',
        'cited_text': 'block',
        'document_index': 3,
        'start_block_index': 0,
        'end_block_index': 2,
      });
      expect(result?.contentBlockLocation?.endBlockIndex, 2);
    });

    test('web search result location', () {
      final result = claudeAgenticTextCitation({
        'type': 'web_search_result_location',
        'cited_text': 'web',
        'title': 'page title',
        'url': 'https://example.com',
        'encrypted_index': 'enc_idx',
      });
      expect(result?.webSearchResultLocation?.url, 'https://example.com');
    });

    test('unknown returns nil', () {
      expect(claudeAgenticTextCitation({'type': 'unknown'}), isNull);
    });
  });

  group('TestToAssistantTextExtension', () {
    test('nil citations', () {
      expect(claudeAgenticTextExtension(null), isNull);
    });

    test('with citation', () {
      final ext = claudeAgenticTextExtension([
        {
          'type': 'char_location',
          'cited_text': 'hello',
          'document_index': 1,
          'start_char_index': 0,
          'end_char_index': 5,
        },
      ]);
      expect(ext?.citations, hasLength(1));
    });

    test('all unknown returns nil', () {
      expect(
        claudeAgenticTextExtension([
          {'type': 'unknown'},
        ]),
        isNull,
      );
    });
  });

  group('TestToAnthropicTextCitationsAdditional', () {
    test('page location', () {
      final citations = claudeAgenticTextCitationParams(const [
        ClaudeTextCitation(
          type: ClaudeTextCitationType.pageLocation,
          pageLocation: ClaudeCitationPageLocation(
            citedText: 'page',
            documentIndex: 1,
            startPageNumber: 3,
            endPageNumber: 4,
          ),
        ),
      ]);
      expect(citations.single, {
        'type': 'page_location',
        'cited_text': 'page',
        'document_index': 1,
        'start_page_number': 3,
        'end_page_number': 4,
      });
    });

    test('content block location', () {
      final citations = claudeAgenticTextCitationParams(const [
        ClaudeTextCitation(
          type: ClaudeTextCitationType.contentBlockLocation,
          contentBlockLocation: ClaudeCitationContentBlockLocation(
            citedText: 'block',
            documentIndex: 2,
            endBlockIndex: 1,
          ),
        ),
      ]);
      expect(citations.single['type'], 'content_block_location');
      expect(citations.single['end_block_index'], 1);
    });

    test('invalid type', () {
      expect(
        () => claudeAgenticTextCitationParams(const [
          ClaudeTextCitation(type: ClaudeTextCitationType('invalid')),
        ]),
        throwsA(_formatError(contains('invalid text citation type'))),
      );
    });
  });

  group('TestServerToolCallToBlockParam', () {
    Map<String, Object?> convert(ClaudeServerToolCallArguments args) =>
        claudeAgenticServerToolUseBlock(
          ServerToolCall(callId: 'call', arguments: args),
        );

    test('web search', () {
      expect(
        _json(
          convert(
            const ClaudeServerToolCallArguments(
              webSearch: ClaudeWebSearchArguments(query: 'golang'),
            ),
          ),
        ),
        contains('"name":"web_search"'),
      );
    });

    test('code execution', () {
      expect(
        convert(
          const ClaudeServerToolCallArguments(
            codeExecution: ClaudeCodeExecutionArguments(code: 'print(1)'),
          ),
        ),
        {
          'type': 'server_tool_use',
          'id': 'call',
          'name': 'code_execution',
          'input': {'code': 'print(1)'},
        },
      );
    });

    test('bash code execution', () {
      expect(
        convert(
          const ClaudeServerToolCallArguments(
            bashCodeExecution: ClaudeBashCodeExecutionArguments(command: 'ls'),
          ),
        )['name'],
        'bash_code_execution',
      );
    });

    test('text editor', () {
      expect(
        convert(
          const ClaudeServerToolCallArguments(
            textEditorCodeExecution: ClaudeTextEditorCodeExecutionArguments(
              command: 'view',
              path: '/tmp/a.txt',
            ),
          ),
        )['name'],
        'text_editor_code_execution',
      );
    });

    test('nil arguments', () {
      expect(
        () => convert(const ClaudeServerToolCallArguments()),
        throwsA(_formatError(contains('nil'))),
      );
    });

    test('arguments from a JSON round trip', () {
      final block = claudeAgenticServerToolUseBlock(
        const ServerToolCall(
          callId: 'call',
          arguments: {
            'tool_search_tool_regex': {'query': 'get_.*'},
          },
        ),
      );
      expect(block['name'], 'tool_search_tool_regex');
      expect(block['input'], {'query': 'get_.*'});
    });
  });

  group('TestTextEditorCodeExecutionToolResultToBlockParamCoverage', () {
    test('error', () {
      final block = claudeAgenticTextEditorCodeExecutionResultBlock(
        const ClaudeTextEditorCodeExecutionResult(
          type: ClaudeTextEditorCodeExecutionResultType.error,
          error: ClaudeTextEditorCodeExecutionResultError(
            code: 'err',
            message: 'msg',
          ),
        ),
        'call_1',
      );
      expect(block['content'], {
        'type': 'text_editor_code_execution_tool_result_error',
        'error_code': 'err',
        'error_message': 'msg',
      });
    });

    test('create', () {
      final block = claudeAgenticTextEditorCodeExecutionResultBlock(
        const ClaudeTextEditorCodeExecutionResult(
          type: ClaudeTextEditorCodeExecutionResultType.create,
          create: ClaudeTextEditorCodeExecutionCreateResult(isFileUpdate: true),
        ),
        'call_2',
      );
      expect(block['content'], {
        'type': 'text_editor_code_execution_create_result',
        'is_file_update': true,
      });
    });

    test('str replace', () {
      final block = claudeAgenticTextEditorCodeExecutionResultBlock(
        ClaudeTextEditorCodeExecutionResult(
          type: ClaudeTextEditorCodeExecutionResultType.strReplace,
          strReplace: ClaudeTextEditorCodeExecutionStrReplaceResult(
            oldStart: 1,
            oldLines: 2,
            newStart: 1,
            newLines: 3,
            lines: const ['a'],
          ),
        ),
        'call_3',
      );
      expect(block['content'], {
        'type': 'text_editor_code_execution_str_replace_result',
        'old_start': 1,
        'old_lines': 2,
        'new_start': 1,
        'new_lines': 3,
        'lines': ['a'],
      });
    });

    test('invalid', () {
      expect(
        () => claudeAgenticTextEditorCodeExecutionResultBlock(
          const ClaudeTextEditorCodeExecutionResult(
            type: ClaudeTextEditorCodeExecutionResultType('bad'),
          ),
          'call_4',
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(
        () => claudeAgenticTextEditorCodeExecutionResultBlock(
          const ClaudeTextEditorCodeExecutionResult(
            type: ClaudeTextEditorCodeExecutionResultType.create,
          ),
          'call_5',
        ),
        throwsA(
          _formatError('text editor code execution create result is nil'),
        ),
      );
    });
  });

  group('TestCodeExecutionToolResultToBlockParamCoverage', () {
    test('error', () {
      final block = claudeAgenticCodeExecutionResultBlock(
        const ClaudeCodeExecutionResult(
          type: ClaudeCodeExecutionResultType.error,
          error: ClaudeCodeExecutionResultError(code: 'timeout'),
        ),
        'call_1',
      );
      expect(block['content'], {
        'type': 'code_execution_tool_result_error',
        'error_code': 'timeout',
      });
    });

    test('encrypted', () {
      final block = claudeAgenticCodeExecutionResultBlock(
        ClaudeCodeExecutionResult(
          type: ClaudeCodeExecutionResultType.encrypted,
          encryptedResult: ClaudeEncryptedCodeExecutionResultBlock(
            content: const [ClaudeCodeExecutionOutput(fileId: 'f1')],
            encryptedStdout: 'enc',
            stderr: 'err',
            returnCode: 1,
          ),
        ),
        'call_2',
      );
      expect(block['content'], {
        'type': 'encrypted_code_execution_result',
        'content': [
          {'type': 'code_execution_output', 'file_id': 'f1'},
        ],
        'encrypted_stdout': 'enc',
        'stderr': 'err',
        'return_code': 1,
      });
    });

    test('invalid', () {
      expect(
        () => claudeAgenticCodeExecutionResultBlock(
          const ClaudeCodeExecutionResult(
            type: ClaudeCodeExecutionResultType('bad'),
          ),
          'call_3',
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });

  group('TestBashCodeExecutionToolResultToBlockParamCoverage', () {
    test('error', () {
      final block = claudeAgenticBashCodeExecutionResultBlock(
        const ClaudeBashCodeExecutionResult(
          type: ClaudeBashCodeExecutionResultType.error,
          error: ClaudeBashCodeExecutionResultError(code: 'sandbox'),
        ),
        'call_1',
      );
      expect(block['content'], {
        'type': 'bash_code_execution_tool_result_error',
        'error_code': 'sandbox',
      });
    });

    test('invalid', () {
      expect(
        () => claudeAgenticBashCodeExecutionResultBlock(
          const ClaudeBashCodeExecutionResult(
            type: ClaudeBashCodeExecutionResultType('bad'),
          ),
          'call_2',
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });

  group('TestToAgenticContentBlockServerToolResults', () {
    final cases = <String, Map<String, Object?>>{
      'web search result block': {
        'type': 'web_search_tool_result',
        'tool_use_id': 'call_1',
        'content': [
          {
            'type': 'web_search_result',
            'title': 'Go',
            'url': 'https://go.dev',
            'encrypted_content': 'e',
            'page_age': '1d',
          },
        ],
      },
      'code execution result block': {
        'type': 'code_execution_tool_result',
        'tool_use_id': 'call_2',
        'content': {
          'type': 'code_execution_result',
          'stdout': 'hi',
          'stderr': '',
          'return_code': 0,
          'content': <Object?>[],
        },
      },
      'bash code execution result block': {
        'type': 'bash_code_execution_tool_result',
        'tool_use_id': 'call_3',
        'content': {
          'type': 'bash_code_execution_result',
          'stdout': 'ok',
          'stderr': '',
          'return_code': 0,
          'content': <Object?>[],
        },
      },
      'text editor result block': {
        'type': 'text_editor_code_execution_tool_result',
        'tool_use_id': 'call_4',
        'content': {
          'type': 'text_editor_code_execution_view_result',
          'file_type': 'go',
          'content': 'pkg',
          'num_lines': 1,
          'start_line': 1,
          'total_lines': 1,
        },
      },
      'web fetch result block': {
        'type': 'web_fetch_tool_result',
        'tool_use_id': 'call_5',
        'content': {
          'type': 'web_fetch_tool_result_error',
          'error_code': 'fetch_failed',
        },
      },
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      test(key, () {
        final block = ClaudeAgenticBlockConverter().contentBlock(value);
        expect(block?.serverToolResult, isNotNull);
      });
    }
  });

  test('TestAssistantGenTextToBlockParamWithCitations', () {
    final block = claudeAgenticTextBlock(
      AssistantGenText(
        text: 'answer',
        claudeExtension: ClaudeAssistantGenTextExtension(
          citations: const [
            ClaudeTextCitation(
              type: ClaudeTextCitationType.charLocation,
              charLocation: ClaudeCitationCharLocation(
                citedText: 'cite',
                endCharIndex: 4,
              ),
            ),
          ],
        ),
      ),
    );
    expect(_json(block), contains('"cited_text":"cite"'));
    expect(block['citations'], [
      {
        'type': 'char_location',
        'cited_text': 'cite',
        'document_index': 0,
        'start_char_index': 0,
        'end_char_index': 4,
      },
    ]);
  });

  group('TestToAnthropicMessagesMergeToolOnly', () {
    AgenticMessage toolMsg(String callId) => AgenticMessage(
      role: AgenticRoleType.user,
      contentBlocks: [
        ContentBlock(
          FunctionToolResult(
            callId: callId,
            name: 'get_weather',
            content: [
              FunctionToolResultContentBlock(const UserInputText(text: 'ok')),
            ],
          ),
        ),
      ],
    );

    List<Object?> content(Map<String, Object?> message) =>
        message['content']! as List<Object?>;

    test('two consecutive tool-only messages merged', () {
      final (system: _, :messages) = claudeAgenticToAnthropicMessages([
        AgenticMessage.user('hello'),
        toolMsg('call_1'),
        toolMsg('call_2'),
      ]);
      expect(messages, hasLength(2));
      expect(content(messages[1]), hasLength(2));
    });

    test('three consecutive tool-only messages merged', () {
      final (system: _, :messages) = claudeAgenticToAnthropicMessages([
        toolMsg('call_1'),
        toolMsg('call_2'),
        toolMsg('call_3'),
      ]);
      expect(messages, hasLength(1));
      expect(content(messages[0]), hasLength(3));
    });

    test('tool messages separated by assistant not merged', () {
      final (system: _, :messages) = claudeAgenticToAnthropicMessages([
        toolMsg('call_1'),
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [ContentBlock(const AssistantGenText(text: 'ok'))],
        ),
        toolMsg('call_2'),
      ]);
      expect(messages, hasLength(3));
    });

    test('user message with text not merged with tool message', () {
      final (system: _, :messages) = claudeAgenticToAnthropicMessages([
        toolMsg('call_1'),
        AgenticMessage.user('more'),
      ]);
      expect(messages, hasLength(2));
    });

    test('adjacent inline system messages merged', () {
      final (system: _, :messages) = claudeAgenticToAnthropicMessages([
        AgenticMessage.user('hello'),
        AgenticMessage.system('one'),
        AgenticMessage.system('two'),
      ]);
      expect(messages, hasLength(2));
      expect(content(messages[1]), [
        {'type': 'text', 'text': 'one'},
        {'type': 'text', 'text': 'two'},
      ]);
    });
  });

  group('function tools', () {
    test('custom type, description, deferred', () {
      final tools = claudeAgenticFunctionTools([
        _toolInfo('fn'),
      ], deferLoading: true);
      expect(tools.single, {
        'type': 'custom',
        'name': 'fn',
        'description': 'fn desc',
        'input_schema': {'type': 'object'},
        'defer_loading': true,
      });
    });

    test('a JSONSchema tool keeps properties and required', () {
      final tools = claudeAgenticFunctionTools([
        ToolInfo.fromJsonSchema(
          name: 'get_weather',
          schema: const JSONSchema(
            properties: {
              'city': JSONSchemaProperty(type: 'string', description: 'City'),
            },
            required: ['city'],
          ),
        ),
      ]);
      expect(tools.single['input_schema'], {
        'type': 'object',
        'properties': {
          'city': {'type': 'string', 'description': 'City'},
        },
        'required': ['city'],
      });
      expect(tools.single.containsKey('description'), isFalse);
    });
  });

  group('tool search results (not in Go: Go fails on them)', () {
    test('a BM25 search result follows its server tool use', () {
      final message = ClaudeAgenticBlockConverter().message({
        'id': 'msg',
        'content': [
          {
            'type': 'server_tool_use',
            'id': 'srvtoolu_1',
            'name': 'tool_search_tool_bm25',
            'input': {'query': 'weather'},
          },
          {
            'type': 'tool_search_tool_result',
            'tool_use_id': 'srvtoolu_1',
            'content': {
              'type': 'tool_search_tool_search_result',
              'tool_references': [
                {'type': 'tool_reference', 'tool_name': 'get_weather'},
              ],
            },
          },
        ],
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      });
      final result = message.contentBlocks[1].serverToolResult!;
      expect(result.name, 'tool_search_tool_bm25');
      expect(
        result.content,
        ClaudeServerToolResult(
          toolSearchToolBm25: ClaudeToolSearchToolResult(
            type: ClaudeToolSearchToolResultType.searchResult,
            searchResult: ClaudeToolSearchToolSearchResult(
              toolReferences: const [
                ClaudeToolSearchToolReference(toolName: 'get_weather'),
              ],
            ),
          ),
        ),
      );
      // And it goes back as it came.
      expect(claudeAgenticServerToolResultBlock(message.contentBlocks[1]), {
        'type': 'tool_search_tool_result',
        'tool_use_id': 'srvtoolu_1',
        'content': {
          'type': 'tool_search_tool_search_result',
          'tool_references': [
            {'type': 'tool_reference', 'tool_name': 'get_weather'},
          ],
        },
      });
    });

    test('a regex search error', () {
      final converter = ClaudeAgenticBlockConverter()
        ..serverToolUse({
          'id': 'srvtoolu_2',
          'name': 'tool_search_tool_regex',
          'input': {'query': '('},
        });
      final block = converter.contentBlock({
        'type': 'tool_search_tool_result',
        'tool_use_id': 'srvtoolu_2',
        'content': {
          'type': 'tool_search_tool_result_error',
          'error_code': 'invalid_pattern',
          'error_message': 'bad regex',
        },
      })!;
      expect(
        _content(block).toolSearchToolRegex!.error,
        const ClaudeToolSearchToolResultError(
          code: 'invalid_pattern',
          message: 'bad regex',
        ),
      );
    });

    test('a result for an unknown call fails', () {
      expect(
        () => ClaudeAgenticBlockConverter().contentBlock({
          'type': 'tool_search_tool_result',
          'tool_use_id': 'nope',
          'content': <String, Object?>{},
        }),
        throwsA(_formatError('tool search result for unknown call "nope"')),
      );
    });
  });

  test('cache creation tokens and stop details of a response', () {
    final message = ClaudeAgenticBlockConverter().message({
      'id': 'msg_1',
      'content': <Object?>[],
      'stop_reason': 'refusal',
      'stop_details': {'type': 'refusal', 'category': 'cyber'},
      'usage': {
        'input_tokens': 100,
        'output_tokens': 50,
        'cache_creation_input_tokens': 500,
        'cache_read_input_tokens': 20,
      },
    });
    expect(message.extra, {claudeAgenticKeyOfCacheCreationInputTokens: 500});
    expect(message.responseMeta!.tokenUsage!.promptTokens, 620);
    expect(message.responseMeta!.tokenUsage!.totalTokens, 670);
    expect(
      message.responseMeta!.claudeExtension!.stopDetails!.category,
      'cyber',
    );
  });
}
