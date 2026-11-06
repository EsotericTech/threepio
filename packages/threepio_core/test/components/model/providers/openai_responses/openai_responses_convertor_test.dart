// Port of eino-ext components/model/agenticopenai/responses_convertor_test.go.
//
// Go checks the openai-go request structs (`item.OfMessage.Role`, `Opt`
// validity); the request items are JSON maps here, so the checks read the
// map (an unset optional field is an absent key). Go mocks `AsAny` with
// mockey to choose the variant of a response union; here the variant comes
// from the `type` of the recorded JSON item.
//
// Ported: every test function of the Go file (the ones of the URL helpers,
// TestResolveURL and TestEnsureDataURL, are in openai_responses_utils_test).
// Adapted, because the sealed Dart types cannot express the Go input:
// * "nil_content" of TestAssistantGenTextToInputItem and
//   TestFunctionToolCallToInputItem: a block with another payload stands for
//   Go's block whose payload pointer is nil;
// * "invalid" of TestToInputItemImageDetail: `ImageURLDetail` is an enum,
//   so only the empty and the valid details are tested;
// * TestTextAnnotationToOutputTextAnnotation "invalid" uses an annotation
//   type the converter does not know (the open value class allows it).
import 'package:test/test.dart';
import 'package:threepio_core/components.dart' show ChatModelOptions;
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_block_extra.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_consts.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_convertor.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_exception.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_extension.dart';

final _throws = throwsA(isA<OpenAIResponsesException>());

Matcher _throwsWith(String text) => throwsA(
      isA<OpenAIResponsesException>()
          .having((e) => e.message, 'message', contains(text)),
    );

ContentBlock _tag(ContentBlock block, String id, [String? status]) {
  final withId = withItemId(block, id);
  return status == null ? withId : withItemStatus(withId, status);
}

Json _first(Object? list) => (list! as List<Object?>).first! as Json;

ToolInfo _objectTool(String name, String desc) => ToolInfo.fromJsonSchemaMap(
      name: name,
      desc: desc,
      schema: const {'type': 'object'},
    );

void main() {
  group('TestToSystemRoleInputItems', () {
    test('user_input_text', () {
      final items = toSystemRoleInputItems(AgenticMessage.system('hi'));
      expect(items, hasLength(1));
      expect(items.single['role'], 'system');
      expect(items.single['content'], 'hi');
    });

    test('invalid_block_type', () {
      final message = AgenticMessage(
        role: AgenticRoleType.system,
        contentBlocks: [ContentBlock(const AssistantGenText(text: 'x'))],
      );
      expect(() => toSystemRoleInputItems(message), _throws);
    });
  });

  group('TestShellCallToContentBlock', () {
    test('with_commands', () {
      final block = shellCallToContentBlock({
        'type': 'shell_call',
        'id': 'shell1',
        'call_id': 'call_shell1',
        'status': 'completed',
        'action': {
          'commands': ['ls -la', 'pwd'],
          'timeout_ms': 30000,
          'max_output_length': 1024,
        },
        'environment': {'type': 'local'},
        'created_by': 'user123',
      });
      expect(itemIdOf(block), 'shell1');
      final call = block.serverToolCall!;
      expect(call.name, OpenAIResponsesServerToolName.shell.value);
      expect(call.callId, 'call_shell1');
      final args = call.arguments! as OpenAIResponsesServerToolCallArguments;
      expect(args.shell!.action!.commands, ['ls -la', 'pwd']);
      expect(args.shell!.action!.timeoutMs, 30000);
      expect(args.shell!.action!.maxOutputLength, 1024);
      expect(
        args.shell!.environment!.type,
        OpenAIResponsesShellEnvironmentType.local,
      );
      expect(args.shell!.createdBy, 'user123');
    });

    test('with_container_environment', () {
      final block = shellCallToContentBlock({
        'type': 'shell_call',
        'id': 'shell2',
        'call_id': 'call_shell2',
        'status': 'completed',
        'action': {
          'commands': ['echo hello'],
        },
        'environment': {
          'type': 'container_reference',
          'container_id': 'container123',
        },
      });
      final args = block.serverToolCall!.arguments!
          as OpenAIResponsesServerToolCallArguments;
      expect(
        args.shell!.environment!.type,
        OpenAIResponsesShellEnvironmentType.containerReference,
      );
      expect(
        args.shell!.environment!.containerReference!.containerId,
        'container123',
      );
    });

    test('unknown environment type', () {
      expect(
        () => shellCallToContentBlock({
          'environment': {'type': 'mystery'},
        }),
        _throwsWith('unknown shell environment type: mystery'),
      );
    });
  });

  group('TestShellOutputToContentBlock', () {
    test('with_exit_outcome', () {
      final block = shellOutputToContentBlock({
        'type': 'shell_call_output',
        'id': 'shell_out1',
        'status': 'completed',
        'output': [
          {
            'stdout': 'file1.txt\nfile2.txt',
            'stderr': '',
            'outcome': {'type': 'exit', 'exit_code': 0},
          },
        ],
      });
      expect(itemIdOf(block), 'shell_out1');
      expect(
        block.serverToolResult!.name,
        OpenAIResponsesServerToolName.shell.value,
      );
      final result = block.serverToolResult!.content!
          as OpenAIResponsesServerToolResult;
      expect(result.shell!.outputs, hasLength(1));
      expect(result.shell!.outputs.single.stdout, 'file1.txt\nfile2.txt');
      expect(result.shell!.outputs.single.outcome!.exit!.exitCode, 0);
    });

    test('with_timeout_outcome', () {
      final block = shellOutputToContentBlock({
        'id': 'shell_out2',
        'status': 'completed',
        'output': [
          {
            'stdout': '',
            'stderr': 'timeout',
            'outcome': {'type': 'timeout'},
          },
        ],
      });
      final result = block.serverToolResult!.content!
          as OpenAIResponsesServerToolResult;
      expect(result.shell!.outputs.single.outcome!.exit, isNull);
    });
  });

  test('TestToAssistantRoleInputItems', () {
    final message = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        _tag(ContentBlock(const AssistantGenText(text: 'ok')), 'msg1', 'completed'),
        _tag(ContentBlock(const Reasoning(text: 'r')), 'r1', 'completed'),
        _tag(
          ContentBlock(
            const FunctionToolCall(callId: 'c1', name: 'f', arguments: '{}'),
          ),
          'f1',
          'completed',
        ),
        _tag(
          ContentBlock(
            ServerToolCall(
              name: OpenAIResponsesServerToolName.webSearch.value,
              arguments: OpenAIResponsesServerToolCallArguments(
                webSearch: OpenAIResponsesWebSearchArguments(
                  actionType: OpenAIResponsesWebSearchAction.search,
                  search: OpenAIResponsesWebSearchQuery(queries: const ['q']),
                ),
              ),
            ),
          ),
          'ws1',
          'in_progress',
        ),
        _tag(
          ContentBlock(
            ServerToolResult(
              name: OpenAIResponsesServerToolName.webSearch.value,
              content: OpenAIResponsesServerToolResult(
                webSearch: OpenAIResponsesWebSearchResult(
                  actionType: OpenAIResponsesWebSearchAction.search,
                  search: OpenAIResponsesWebSearchQueryResult(
                    sources: const [
                      OpenAIResponsesWebSearchQuerySource(url: 'u'),
                    ],
                  ),
                ),
              ),
            ),
          ),
          'ws1',
          'completed',
        ),
        _tag(
          ContentBlock(
            const AgenticMcpToolCall(
              serverLabel: 'srv',
              name: 'tool',
              arguments: '{"a":1}',
            ),
          ),
          'm1',
          'calling',
        ),
        _tag(
          ContentBlock(
            const AgenticMcpToolResult(
              serverLabel: 'srv',
              name: 'tool',
              content: 'out',
            ),
          ),
          'm1',
          'completed',
        ),
      ],
      responseMeta: const AgenticResponseMeta(
        openAIExtension: OpenAIResponseMetaExtension(),
      ),
    );

    final items = toAssistantRoleInputItems(message);
    expect(items, hasLength(5));

    final mcp = items.singleWhere((i) => i['type'] == 'mcp_call');
    expect(mcp['id'], 'm1');
    expect(mcp['server_label'], 'srv');
    expect(mcp['name'], 'tool');
    expect(mcp['arguments'], '{"a":1}');
    expect(mcp['output'], 'out');

    final ws = items.singleWhere((i) => i['type'] == 'web_search_call');
    expect(ws['id'], 'ws1');
    final action = ws['action']! as Json;
    expect(action['type'], 'search');
    expect(action['queries'], ['q']);
    expect(action['sources'], hasLength(1));
    expect(_first(action['sources'])['url'], 'u');
  });

  test('assistant blocks of another model keep the model-agnostic types only',
      () {
    final message = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(const Reasoning(text: 'other model')),
        ContentBlock(const AssistantGenText(text: 'hi')),
        ContentBlock(
          const FunctionToolCall(callId: 'c', name: 'f', arguments: '{}'),
        ),
      ],
    );
    final items = toAssistantRoleInputItems(message);
    expect(items.map((i) => i['type']), ['message', 'function_call']);
  });

  group('TestPairMCPToolCallItems', () {
    test('merge_call_and_result', () {
      final items = pairMcpToolCallItems([
        {
          'type': 'mcp_call',
          'id': 'm1',
          'server_label': 's',
          'name': 'n',
          'arguments': '{}',
        },
        {
          'type': 'mcp_call',
          'id': 'm1',
          'server_label': 's',
          'name': 'n',
          'arguments': '',
          'output': 'out',
        },
      ]);
      expect(items, hasLength(1));
      expect(items.single['arguments'], '{}');
      expect(items.single['output'], 'out');
    });

    test('missing_pair', () {
      expect(
        () => pairMcpToolCallItems([
          {'type': 'mcp_call', 'id': 'm1', 'server_label': 's', 'name': 'n'},
        ]),
        _throwsWith('should have exactly 2 items'),
      );
    });

    test('empty id', () {
      expect(
        () => pairMcpToolCallItems([
          {'type': 'mcp_call', 'id': ''},
        ]),
        _throwsWith('found MCP tool call item with empty ID'),
      );
    });
  });

  group('TestPairWebServerToolCallItems', () {
    test('merge_call_and_result', () {
      final items = pairWebSearchServerToolCallItems([
        {
          'type': 'web_search_call',
          'id': 'ws1',
          'action': {
            'type': 'search',
            'queries': ['q'],
          },
        },
        {
          'type': 'web_search_call',
          'id': 'ws1',
          'action': {
            'type': 'search',
            'sources': [
              {'type': 'url', 'url': 'u'},
            ],
          },
        },
      ]);
      expect(items, hasLength(1));
      final action = items.single['action']! as Json;
      expect(action['queries'], ['q']);
      expect(action['sources'], hasLength(1));
      expect(_first(action['sources'])['url'], 'u');
    });

    test('missing_pair', () {
      expect(
        () => pairWebSearchServerToolCallItems([
          {'type': 'web_search_call', 'id': 'ws1'},
        ]),
        _throws,
      );
    });
  });

  test('TestPairWebSearchAction', () {
    final merged = pairWebSearchAction(
      {
        'type': 'search',
        'queries': ['q'],
      },
      {
        'type': 'search',
        'queries': ['q2'],
        'sources': [
          {'type': 'url', 'url': 'u'},
        ],
      },
    )!;
    expect(merged['type'], 'search');
    expect(merged['queries'], ['q2']);
    expect(merged['sources'], hasLength(1));
    expect(_first(merged['sources'])['url'], 'u');
  });

  test('web search actions of different kinds cannot be paired', () {
    expect(
      () => pairWebSearchAction(
        {'type': 'find', 'url': 'u', 'pattern': 'p'},
        {
          'type': 'search',
          'queries': ['q'],
        },
      ),
      _throwsWith('expected union to have only one present variant, got 2'),
    );
    expect(
      pairWebSearchAction(null, {'type': 'open_page', 'url': 'u'}),
      {'type': 'open_page', 'url': 'u'},
    );
    expect(pairWebSearchAction(null, null), isNull);
  });

  group('TestToUserRoleInputItems', () {
    test('mix_user_inputs', () {
      final message = AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [
          ContentBlock(const UserInputText(text: 'hi')),
          ContentBlock(
            FunctionToolResult(
              callId: 'c',
              content: [
                FunctionToolResultContentBlock(const UserInputText(text: 'r')),
              ],
            ),
          ),
          ContentBlock(
            const AgenticMcpToolApprovalResponse(
              approvalRequestId: 'a',
              approve: true,
              reason: 'ok',
            ),
          ),
        ],
      );
      final items = toUserRoleInputItems(message);
      expect(items, hasLength(3));
      expect(items[2], {
        'type': 'mcp_approval_response',
        'approval_request_id': 'a',
        'approve': true,
        'reason': 'ok',
      });
    });

    test('invalid_block_type', () {
      final message = AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [ContentBlock(const Reasoning())],
      );
      expect(() => toUserRoleInputItems(message), _throws);
    });
  });

  test('TestUserInputTextToInputItem', () {
    expect(
      userInputTextToInputItem('user', const UserInputText(text: 'hi')),
      {'role': 'user', 'content': 'hi'},
    );
  });

  group('TestUserInputImageToInputItem', () {
    test('url', () {
      final item = userInputImageToInputItem(
        'user',
        const UserInputImage(url: 'http://x', detail: ImageURLDetail.auto),
      );
      final image = _first(item['content']);
      expect(image['type'], 'input_image');
      expect(image['image_url'], 'http://x');
      expect(image['detail'], 'auto');
      expect(image.containsKey('file_id'), isFalse);
    });

    test('base64_missing_mime', () {
      expect(
        () => userInputImageToInputItem(
          'user',
          const UserInputImage(base64Data: 'abc'),
        ),
        _throws,
      );
    });
  });

  group('TestToInputItemImageDetail', () {
    test('empty', () {
      expect(toInputItemImageDetail(null), '');
    });
    test('valid', () {
      expect(toInputItemImageDetail(ImageURLDetail.high), 'high');
      expect(toInputItemImageDetail(ImageURLDetail.low), 'low');
    });
  });

  group('TestUserInputFileToInputItem', () {
    test('url', () {
      final item = userInputFileToInputItem(
        'user',
        const UserInputFile(url: 'http://f', name: 'a.txt'),
      );
      final file = _first(item['content']);
      expect(file['file_url'], 'http://f');
      expect(file['filename'], 'a.txt');
    });

    test('base64', () {
      final item = userInputFileToInputItem(
        'user',
        const UserInputFile(
          base64Data: 'abc',
          mimeType: 'text/plain',
          name: 'a.txt',
        ),
      );
      final file = _first(item['content']);
      expect(file['file_data'], 'abc');
      expect(file.containsKey('file_url'), isFalse);
    });
  });

  test('TestFunctionToolResultToInputItem', () {
    final item = functionToolResultToInputItem(
      FunctionToolResult(
        callId: 'c',
        content: [
          FunctionToolResultContentBlock(const UserInputText(text: 'r')),
        ],
      ),
    );
    expect(item['type'], 'function_call_output');
    expect(item['call_id'], 'c');
    expect(item['output'], [
      {'type': 'input_text', 'text': 'r'},
    ]);
  });

  test('function tool result: empty and unsupported content', () {
    expect(
      () => functionToolResultContentToOutput(const []),
      _throwsWith('function tool result content is empty'),
    );
    expect(
      () => functionToolResultContentToOutput([
        FunctionToolResultContentBlock(const UserInputAudio(url: 'a')),
      ]),
      _throwsWith('unsupported function tool result content block type: audio'),
    );
  });

  group('TestAssistantGenTextToInputItem', () {
    test('nil_content', () {
      expect(
        () => assistantGenTextToInputItem(ContentBlock(const Reasoning())),
        _throwsWith('assistant generated text is nil'),
      );
    });

    test('with_annotations', () {
      final block = _tag(
        ContentBlock(
          AssistantGenText(
            text: 't',
            openAIExtension: OpenAIAssistantGenTextExtension(
              annotations: const [
                OpenAITextAnnotation(
                  type: OpenAITextAnnotationType.urlCitation,
                  urlCitation: OpenAITextAnnotationUrlCitation(
                    title: 'tt',
                    url: 'u',
                    startIndex: 1,
                    endIndex: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
        'msg1',
        'completed',
      );
      final item = assistantGenTextToInputItem(block);
      expect(item['type'], 'message');
      expect(item['role'], 'assistant');
      expect(item['id'], 'msg1');
      expect(item['status'], 'completed');
      final text = _first(item['content']);
      expect(text['type'], 'output_text');
      expect(text['text'], 't');
      expect(text['annotations'], [
        {
          'type': 'url_citation',
          'title': 'tt',
          'url': 'u',
          'start_index': 1,
          'end_index': 2,
        },
      ]);
    });
  });

  group('TestTextAnnotationToOutputTextAnnotation', () {
    test('file_citation', () {
      final param = textAnnotationToOutputTextAnnotation(
        const OpenAITextAnnotation(
          type: OpenAITextAnnotationType.fileCitation,
          fileCitation: OpenAITextAnnotationFileCitation(
            fileId: 'f',
            filename: 'n',
            index: 3,
          ),
        ),
      );
      expect(param, {
        'type': 'file_citation',
        'file_id': 'f',
        'filename': 'n',
        'index': 3,
      });
    });

    test('invalid', () {
      expect(
        () => textAnnotationToOutputTextAnnotation(
          const OpenAITextAnnotation(type: OpenAITextAnnotationType('bad')),
        ),
        _throwsWith('invalid text annotation type: bad'),
      );
    });

    test('missing payload', () {
      expect(
        () => textAnnotationToOutputTextAnnotation(
          const OpenAITextAnnotation(type: OpenAITextAnnotationType.filePath),
        ),
        _throwsWith('file path is nil'),
      );
    });
  });

  group('TestFunctionToolCallToInputItem', () {
    test('nil_content', () {
      expect(
        () => functionToolCallToInputItem(ContentBlock(const Reasoning())),
        _throwsWith('function tool call is nil'),
      );
    });

    test('normal', () {
      final block = _tag(
        ContentBlock(
          const FunctionToolCall(callId: 'c', name: 'n', arguments: '{}'),
        ),
        'id',
        'completed',
      );
      expect(functionToolCallToInputItem(block), {
        'type': 'function_call',
        'id': 'id',
        'status': 'completed',
        'call_id': 'c',
        'name': 'n',
        'arguments': '{}',
      });
    });

    test('namespace', () {
      final block = withNamespace(
        ContentBlock(const FunctionToolCall(callId: 'c', name: 'n')),
        'ns',
      );
      expect(functionToolCallToInputItem(block)['namespace'], 'ns');
    });

    test('client tool search call', () {
      final block = withToolSearchToolCall(
        _tag(
          ContentBlock(
            const FunctionToolCall(
              callId: 'call1',
              name: 'my_search',
              arguments: '{"query":"x"}',
            ),
          ),
          'ts1',
          'completed',
        ),
      );
      expect(functionToolCallToInputItem(block), {
        'type': 'tool_search_call',
        'arguments': {'query': 'x'},
        'id': 'ts1',
        'call_id': 'call1',
        'status': 'completed',
        'execution': 'client',
      });
    });
  });

  group('TestReasoningToInputItem', () {
    test('reasoningToInputItem', () {
      final block = _tag(
        ContentBlock(const Reasoning(text: 's', signature: 'e')),
        'r',
        'completed',
      );
      final item = reasoningToInputItem(block);
      expect(item['id'], 'r');
      expect(item['encrypted_content'], 'e');
      expect(item['summary'], [
        {'type': 'summary_text', 'text': 's'},
      ]);
      expect(item.containsKey('content'), isFalse);
    });

    test('reasoningToInputItem with content', () {
      final block = withItemId(
        ContentBlock(
          Reasoning(
            text: 's',
            openAIExtension: OpenAIReasoningExtension(
              content: const [
                OpenAIReasoningContent(text: 'raw0', index: 0),
                OpenAIReasoningContent(text: 'raw1', index: 1),
              ],
            ),
          ),
        ),
        'r',
      );
      final item = reasoningToInputItem(block);
      expect(item['content'], [
        {'type': 'reasoning_text', 'text': 'raw0'},
        {'type': 'reasoning_text', 'text': 'raw1'},
      ]);
    });
  });

  test('TestServerToolCallToInputItem', () {
    final block = _tag(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.webSearch.value,
          arguments: OpenAIResponsesServerToolCallArguments(
            webSearch: OpenAIResponsesWebSearchArguments(
              actionType: OpenAIResponsesWebSearchAction.search,
              search: OpenAIResponsesWebSearchQuery(queries: const ['q']),
            ),
          ),
        ),
      ),
      'ws1',
      'searching',
    );
    final item = serverToolCallToInputItem(block);
    expect(item['type'], 'web_search_call');
    expect(item['id'], 'ws1');
    // `query` is the SDK's required search field, always empty (review).
    expect(item['action'], {
      'type': 'search',
      'query': '',
      'queries': ['q'],
    });
  });

  test('server tool call arguments read back from JSON', () {
    final block = withItemId(
      ContentBlock(
        const ServerToolCall(
          name: 'web_search',
          arguments: {
            'web_search': {
              'action_type': 'open_page',
              'open_page': {'url': 'https://x'},
            },
          },
        ),
      ),
      'ws1',
    );
    expect(serverToolCallToInputItem(block)['action'], {
      'type': 'open_page',
      'url': 'https://x',
    });
  });

  test('TestGetWebSearchToolCallActionParam', () {
    final action = getWebSearchToolCallActionParam(
      const OpenAIResponsesWebSearchArguments(
        actionType: OpenAIResponsesWebSearchAction.find,
        find: OpenAIResponsesWebSearchFind(url: 'u', pattern: 'p'),
      ),
    );
    expect(action, {'type': 'find', 'url': 'u', 'pattern': 'p'});
    expect(
      () => getWebSearchToolCallActionParam(
        const OpenAIResponsesWebSearchArguments(
          actionType: OpenAIResponsesWebSearchAction('bad'),
        ),
      ),
      _throws,
    );
  });

  test('TestServerToolResultToInputItem', () {
    final block = _tag(
      ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.webSearch.value,
          content: OpenAIResponsesServerToolResult(
            webSearch: OpenAIResponsesWebSearchResult(
              actionType: OpenAIResponsesWebSearchAction.search,
              search: OpenAIResponsesWebSearchQueryResult(
                sources: const [OpenAIResponsesWebSearchQuerySource(url: 'u')],
              ),
            ),
          ),
        ),
      ),
      'ws1',
      'completed',
    );
    final action = serverToolResultToInputItem(block)['action']! as Json;
    expect(action['sources'], hasLength(1));
    expect(_first(action['sources'])['url'], 'u');
  });

  test('TestGetWebSearchToolResultActionParam', () {
    final action = getWebSearchToolResultActionParam(
      OpenAIResponsesWebSearchResult(
        actionType: OpenAIResponsesWebSearchAction.search,
        search: OpenAIResponsesWebSearchQueryResult(
          sources: const [OpenAIResponsesWebSearchQuerySource(url: 'u')],
        ),
      ),
    );
    // `query` is the SDK's required search field, always empty (review).
    expect(action, {
      'type': 'search',
      'query': '',
      'sources': [
        {'type': 'url', 'url': 'u'},
      ],
    });
    expect(
      () => getWebSearchToolResultActionParam(
        const OpenAIResponsesWebSearchResult(
          actionType: OpenAIResponsesWebSearchAction('bad'),
        ),
      ),
      _throws,
    );
  });

  test('TestMcpToolApprovalRequestToInputItem', () {
    final block = withItemId(
      ContentBlock(
        const AgenticMcpToolApprovalRequest(
          id: 'a',
          name: 'n',
          arguments: '{}',
          serverLabel: 's',
        ),
      ),
      'a',
    );
    expect(mcpToolApprovalRequestToInputItem(block), {
      'type': 'mcp_approval_request',
      'id': 'a',
      'server_label': 's',
      'name': 'n',
      'arguments': '{}',
    });
  });

  group('TestMcpToolApprovalResponseToInputItem', () {
    test('empty_reason', () {
      final item = mcpToolApprovalResponseToInputItem(
        const AgenticMcpToolApprovalResponse(
          approvalRequestId: 'a',
          approve: true,
        ),
      );
      expect(item.containsKey('reason'), isFalse);
    });

    test('with_reason', () {
      final item = mcpToolApprovalResponseToInputItem(
        const AgenticMcpToolApprovalResponse(
          approvalRequestId: 'a',
          reason: 'r',
        ),
      );
      expect(item['reason'], 'r');
      expect(item['approve'], isFalse);
    });
  });

  test('TestMcpListToolsResultToInputItem', () {
    final block = withItemId(
      ContentBlock(
        AgenticMcpListToolsResult(
          serverLabel: 's',
          tools: [AgenticMcpListToolsItem(name: 't', inputSchema: const {})],
        ),
      ),
      'id',
    );
    final item = mcpListToolsResultToInputItem(block);
    expect(item['id'], 'id');
    final tool = _first(item['tools']);
    expect(tool.containsKey('description'), isFalse);
    expect(tool['input_schema'], <String, Object?>{});
  });

  test('TestMcpToolCallToInputItem', () {
    final block = _tag(
      ContentBlock(
        const AgenticMcpToolCall(serverLabel: 's', name: 'n', arguments: '{}'),
      ),
      'id',
      'calling',
    );
    final item = mcpToolCallToInputItem(block);
    expect(item['type'], 'mcp_call');
    expect(item['id'], 'id');
    expect(item['arguments'], '{}');
    expect(item['status'], 'calling');
  });

  test('TestMcpToolResultToInputItem', () {
    final block = _tag(
      ContentBlock(
        const AgenticMcpToolResult(serverLabel: 's', name: 'n', content: 'out'),
      ),
      'id',
      'completed',
    );
    final item = mcpToolResultToInputItem(block);
    expect(item['output'], 'out');
    expect(item.containsKey('error'), isFalse);
  });

  test('TestToOutputMessage', () {
    final message = toOutputMessage(
      {
        'output': [
          {
            'type': 'message',
            'id': 'm1',
            'status': 'completed',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'hi', 'annotations': <Object?>[]},
            ],
          },
          {
            'type': 'reasoning',
            'id': 'r1',
            'status': 'completed',
            'summary': [
              {'type': 'summary_text', 'text': 's'},
            ],
          },
        ],
        'usage': {
          'input_tokens': 1,
          'input_tokens_details': {'cached_tokens': 2},
          'output_tokens': 3,
          'output_tokens_details': {'reasoning_tokens': 4},
          'total_tokens': 5,
        },
      },
      const ChatModelOptions(),
    );
    expect(message.role, AgenticRoleType.assistant);
    expect(message.contentBlocks, hasLength(2));
    expect(message.responseMeta, isNotNull);
    expect(message.responseMeta!.tokenUsage!.totalTokens, 5);
  });

  test('toOutputMessage: an unknown output item type fails', () {
    expect(
      () => toOutputMessage(
        {
          'output': [
            {'type': 'computer_call', 'id': 'c'},
          ],
        },
        const ChatModelOptions(),
      ),
      _throwsWith('unknown output item type: computer_call'),
    );
  });

  test('TestOutputMessageToContentBlocks', () {
    final blocks = outputMessageToContentBlocks({
      'id': 'm1',
      'status': 'completed',
      'content': [
        {'type': 'output_text', 'text': 'hi', 'annotations': <Object?>[]},
        {'type': 'refusal', 'refusal': 'no'},
      ],
    });
    expect(blocks, hasLength(2));
    for (final block in blocks) {
      expect(itemIdOf(block), 'm1');
      expect(itemStatusOf(block), 'completed');
    }
    expect(
      blocks[1].assistantGenText!.openAIExtension!.refusal!.reason,
      'no',
    );
  });

  test('TestOutputContentTextToContentBlock', () {
    final block = outputContentTextToContentBlock({
      'text': 'hi',
      'annotations': [
        {
          'type': 'url_citation',
          'title': 't',
          'url': 'u',
          'start_index': 1,
          'end_index': 2,
        },
      ],
    });
    expect(block.assistantGenText!.text, 'hi');
    expect(block.assistantGenText!.openAIExtension!.annotations, hasLength(1));
  });

  group('TestOutputTextAnnotationToTextAnnotation', () {
    test('file_citation_index_should_preserve', () {
      final annotation = outputTextAnnotationToTextAnnotation({
        'type': 'file_citation',
        'file_id': 'f',
        'filename': 'n',
        'index': 5,
      });
      expect(annotation.fileCitation!.index, 5);
    });

    test('every type', () {
      expect(
        outputTextAnnotationToTextAnnotation({
          'type': 'container_file_citation',
          'container_id': 'c',
          'file_id': 'f',
          'filename': 'n',
          'start_index': 1,
          'end_index': 2,
        }).containerFileCitation!.containerId,
        'c',
      );
      expect(
        outputTextAnnotationToTextAnnotation({
          'type': 'file_path',
          'file_id': 'f',
          'index': 7,
        }).filePath!.index,
        7,
      );
      expect(
        () => outputTextAnnotationToTextAnnotation({'type': 'x'}),
        _throwsWith('unknown annotation type: x'),
      );
    });
  });

  test('TestFunctionToolCallToContentBlock', () {
    final block = functionToolCallToContentBlock({
      'id': 'id',
      'status': 'completed',
      'call_id': 'c',
      'name': 'n',
      'arguments': '{}',
      'namespace': 'ns',
    });
    expect(block.functionToolCall!.callId, 'c');
    expect(itemIdOf(block), 'id');
    expect(namespaceOf(block), 'ns');
  });

  test('TestWebSearchToContentBlocks', () {
    final blocks = webSearchToContentBlocks({
      'type': 'web_search_call',
      'id': 'ws1',
      'status': 'completed',
      'action': {
        'type': 'search',
        'query': 'q',
        'sources': [
          {'type': 'url', 'url': 'u'},
        ],
      },
    });
    expect(blocks, hasLength(2));
    for (final block in blocks) {
      expect(itemIdOf(block), 'ws1');
    }
    final result =
        blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
    expect(result.webSearch!.search!.sources.single.url, 'u');
  });

  test('web search open_page and find have no result content', () {
    final open = webSearchToContentBlocks({
      'id': 'w',
      'action': {'type': 'open_page', 'url': 'u'},
    });
    expect(open[1].serverToolResult!.content, isNull);
    final find = webSearchToContentBlocks({
      'id': 'w',
      'action': {'type': 'find', 'url': 'u', 'pattern': 'p'},
    });
    final args = find[0].serverToolCall!.arguments!
        as OpenAIResponsesServerToolCallArguments;
    expect(args.webSearch!.find!.pattern, 'p');
    expect(
      () => webSearchToContentBlocks({'type': 'web_search_call', 'id': 'w'}),
      _throwsWith('unknown web search variant type: web_search_call'),
    );
  });

  group('TestToolSearchToolCallToContentBlock', () {
    test('client_execution', () {
      final block = toolSearchToolCallToContentBlock(
        {
          'id': 'ts1',
          'call_id': 'call1',
          'status': 'completed',
          'execution': 'client',
          'arguments': {'query': 'find tools'},
        },
        ChatModelOptions(
          toolSearchTool: ToolInfo.fromParamsOneOf(name: 'my_tool_search'),
        ),
      );
      expect(block.type, ContentBlockType.functionToolCall);
      expect(block.functionToolCall!.callId, 'call1');
      expect(block.functionToolCall!.name, 'my_tool_search');
      expect(block.functionToolCall!.arguments, '{"query":"find tools"}');
      expect(itemIdOf(block), 'ts1');
      expect(isToolSearchToolCall(block), isTrue);
    });

    test('client_execution_without_tool_search_tool', () {
      expect(
        () => toolSearchToolCallToContentBlock(
          {
            'id': 'ts1',
            'call_id': 'call1',
            'execution': 'client',
            'arguments': {'query': 'find tools'},
          },
          const ChatModelOptions(),
        ),
        _throwsWith("haven't set client tool search tool"),
      );
    });

    test('server_execution', () {
      final block = toolSearchToolCallToContentBlock(
        {
          'id': 'ts2',
          'call_id': 'call2',
          'status': 'completed',
          'execution': 'server',
          'arguments': {'query': 'find tools'},
        },
        const ChatModelOptions(),
      );
      expect(block.type, ContentBlockType.serverToolCall);
      expect(block.serverToolCall!.callId, 'call2');
      expect(itemIdOf(block), 'ts2');
      final args = block.serverToolCall!.arguments!
          as OpenAIResponsesServerToolCallArguments;
      expect(args.toolSearch!.arguments, {'query': 'find tools'});
    });

    test('invalid_execution', () {
      expect(
        () => toolSearchToolCallToContentBlock(
          {'id': 'ts3', 'execution': 'invalid', 'arguments': <String, Object?>{}},
          const ChatModelOptions(),
        ),
        _throwsWith('invalid tool search execution type'),
      );
    });
  });

  test('TestToolSearchToolResultToContentBlock', () {
    final block = toolSearchToolResultToContentBlock({
      'id': 'tsr1',
      'call_id': 'call1',
      'status': 'completed',
      'tools': [
        {
          'type': 'function',
          'name': 'tool1',
          'description': 'desc1',
          'parameters': {'type': 'object'},
        },
        {'type': 'web_search'},
      ],
    });
    expect(block.type, ContentBlockType.serverToolResult);
    expect(block.serverToolResult!.callId, 'call1');
    final result =
        block.serverToolResult!.content! as OpenAIResponsesServerToolResult;
    expect(result.toolSearch!.tools, hasLength(1));
    expect(result.toolSearch!.tools.single.name, 'tool1');
    expect(result.toolSearch!.tools.single.desc, 'desc1');
    expect(itemIdOf(block), 'tsr1');
  });

  group('TestToolSearchToolResultToInputItem', () {
    test('success', () {
      final item = toolSearchToolResultBlockToInputItem(
        ToolSearchFunctionToolResult(
          callId: 'call1',
          result: ToolSearchResult(tools: [_objectTool('tool1', 'desc1')]),
        ),
      );
      expect(item['type'], 'tool_search_output');
      expect(item['call_id'], 'call1');
      expect(item['status'], 'completed');
      expect(item['execution'], 'client');
      expect(item['tools'], [
        {
          'type': 'function',
          'name': 'tool1',
          'description': 'desc1',
          'parameters': {'type': 'object'},
          'defer_loading': true,
        },
      ]);
    });

    test('nil_result', () {
      expect(
        () => toolSearchToolResultBlockToInputItem(
          const ToolSearchFunctionToolResult(callId: 'call1'),
        ),
        _throwsWith('tool search result should not be nil'),
      );
    });
  });

  test('TestToolSearchInUserRoleInputItems', () {
    final items = toUserRoleInputItems(
      AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [
          ContentBlock(const UserInputText(text: 'hi')),
          ContentBlock(
            ToolSearchFunctionToolResult(
              callId: 'call1',
              result: ToolSearchResult(tools: [_objectTool('tool1', 'desc1')]),
            ),
          ),
        ],
      ),
    );
    expect(items, hasLength(2));
    expect(items[0]['role'], 'user');
    expect(items[1]['type'], 'tool_search_output');
  });

  test('TestGetToolSearchResultActionParam', () {
    final result = getToolSearchResultActionParam(
      OpenAIResponsesToolSearchResult(tools: [_objectTool('tool1', 'desc1')]),
    );
    expect(result['execution'], 'server');
    expect(result['tools'], hasLength(1));
  });

  test('TestServerToolResultToInputItemWithToolSearch', () {
    final block = _tag(
      ContentBlock(
        ServerToolResult(
          callId: 'call1',
          name: 'tool_search',
          content: OpenAIResponsesServerToolResult(
            toolSearch: OpenAIResponsesToolSearchResult(
              tools: [_objectTool('tool1', 'desc1')],
            ),
          ),
        ),
      ),
      'ts1',
      'completed',
    );
    final item = serverToolResultToInputItem(block);
    expect(item['type'], 'tool_search_output');
    expect(item['call_id'], 'call1');
    expect(item['id'], 'ts1');
  });

  test('server tool search call goes back as a tool_search_call item', () {
    final block = _tag(
      ContentBlock(
        const ServerToolCall(
          callId: 'call1',
          arguments: OpenAIResponsesServerToolCallArguments(
            toolSearch: OpenAIResponsesToolSearchArguments(
              arguments: {'query': 'q'},
            ),
          ),
        ),
      ),
      'ts1',
      'completed',
    );
    expect(serverToolCallToInputItem(block), {
      'type': 'tool_search_call',
      'arguments': {'query': 'q'},
      'execution': 'server',
      'call_id': 'call1',
      'id': 'ts1',
      'status': 'completed',
    });
  });

  group('TestReasoningToContentBlocks', () {
    test('reasoningToContentBlocks', () {
      final block = reasoningToContentBlocks({
        'id': 'r1',
        'status': 'completed',
        'summary': [
          {'type': 'summary_text', 'text': 's'},
        ],
      });
      expect(itemIdOf(block), 'r1');
      expect(block.reasoning!.text, 's');
      // No raw reasoning content => no OpenAI extension.
      expect(block.reasoning!.openAIExtension, isNull);
    });

    test('reasoningToContentBlocks with content', () {
      final block = reasoningToContentBlocks({
        'id': 'r1',
        'status': 'completed',
        'summary': [
          {'text': 's'},
          {'text': 't'},
        ],
        'content': [
          {'type': 'reasoning_text', 'text': 'raw0'},
          {'type': 'reasoning_text', 'text': 'raw1'},
        ],
        'encrypted_content': 'enc',
      });
      expect(block.reasoning!.text, 's\nt');
      expect(block.reasoning!.signature, 'enc');
      final content = block.reasoning!.openAIExtension!.content;
      expect(content.map((c) => c.text), ['raw0', 'raw1']);
      expect(content.map((c) => c.index), [null, null]);
    });
  });

  test('TestMcpCallToContentBlocks', () {
    final blocks = mcpCallToContentBlocks({
      'id': 'm1',
      'server_label': 's',
      'name': 'n',
      'arguments': '{}',
      'output': 'out',
      'error': 'boom',
    });
    expect(blocks, hasLength(2));
    for (final block in blocks) {
      expect(itemIdOf(block), 'm1');
    }
    expect(blocks[1].mcpToolResult!.error!.message, 'boom');
  });

  test('TestMcpListToolsToContentBlock', () {
    final block = mcpListToolsToContentBlock({
      'id': 'l1',
      'server_label': 's',
      'tools': [
        {
          'name': 't',
          'description': 'd',
          'input_schema': {'type': 'object'},
        },
      ],
    });
    expect(itemIdOf(block), 'l1');
    expect(block.mcpListToolsResult!.tools, hasLength(1));
    expect(block.mcpListToolsResult!.tools.single.inputSchema, {
      'type': 'object',
    });
    expect(
      () => mcpListToolsToContentBlock({
        'tools': [
          {'name': 't', 'input_schema': 'not an object'},
        ],
      }),
      _throwsWith('failed to unmarshal tool input schema'),
    );
  });

  test('TestMcpApprovalRequestToContentBlock', () {
    final block = mcpApprovalRequestToContentBlock({
      'id': 'a1',
      'server_label': 's',
      'name': 'n',
      'arguments': '{}',
    });
    expect(itemIdOf(block), 'a1');
    expect(block.mcpToolApprovalRequest!.id, 'a1');
  });

  test('TestResponseObjectToResponseMeta', () {
    final meta = responseObjectToResponseMeta(const {});
    expect(meta.tokenUsage, isNotNull);
    expect(meta.openAIExtension, isNotNull);
  });

  test('TestToTokenUsage', () {
    final usage = toTokenUsage({
      'usage': {
        'input_tokens': 1,
        'input_tokens_details': {'cached_tokens': 2},
        'output_tokens': 3,
        'output_tokens_details': {'reasoning_tokens': 4},
        'total_tokens': 5,
      },
    });
    expect(usage.promptTokens, 1);
    expect(usage.promptTokenDetails!.cachedTokens, 2);
    expect(usage.completionTokens, 3);
    expect(usage.completionTokenDetails!.reasoningTokens, 4);
    expect(usage.totalTokens, 5);
  });

  test('TestToResponseMetaExtension', () {
    final ext = toResponseMetaExtension({
      'id': 'r',
      'status': 'completed',
      'error': {'code': 'c', 'message': 'm'},
      'incomplete_details': {'reason': 'x'},
      'reasoning': {'effort': 'low', 'summary': 'sum'},
      'service_tier': 'auto',
      'created_at': 123,
      'previous_response_id': 'p',
      'prompt_cache_retention': '24h',
    });
    expect(ext.id, 'r');
    expect(ext.status, OpenAIResponseStatus.completed);
    expect(ext.error!.code, const OpenAIResponseErrorCode('c'));
    expect(ext.error!.message, 'm');
    expect(ext.incompleteDetails!.reason, 'x');
    expect(ext.reasoning!.effort, OpenAIReasoningEffort.low);
    expect(ext.reasoning!.summary, const OpenAIReasoningSummary('sum'));
    expect(ext.serviceTier, OpenAIServiceTier.auto);
    expect(ext.createdAt, 123);
    expect(ext.previousResponseId, 'p');
    expect(ext.promptCacheRetention, OpenAIPromptCacheRetention.hours24);

    final empty = toResponseMetaExtension(const {});
    expect(empty.error, isNull);
    expect(empty.incompleteDetails, isNull);
    expect(empty.reasoning, isNotNull);
  });

  test('TestFileSearchToolCallToInputItem', () {
    final block = _tag(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.fileSearch.value,
          arguments: OpenAIResponsesServerToolCallArguments(
            fileSearch: OpenAIResponsesFileSearchArguments(
              queries: const ['query1', 'query2'],
            ),
          ),
        ),
      ),
      'fs1',
      'searching',
    );
    final item = fileSearchToolCallToInputItem(
      OpenAIResponsesFileSearchArguments(queries: const ['query1', 'query2']),
      block,
    );
    expect(item, {
      'type': 'file_search_call',
      'id': 'fs1',
      'status': 'searching',
      'queries': ['query1', 'query2'],
    });
  });

  group('TestFileSearchToolResultToInputItem', () {
    test('with_results_and_attributes', () {
      final result = OpenAIResponsesFileSearchResult(
        results: [
          OpenAIResponsesFileSearchResultItem(
            fileId: 'file1',
            fileName: 'test.txt',
            score: 0.85,
            text: 'matching text',
            attributes: const {
              'str_attr': OpenAIResponsesFileSearchAttribute(
                ofString: 'test_string',
              ),
              'float_attr': OpenAIResponsesFileSearchAttribute(ofFloat: 0.95),
              'bool_attr': OpenAIResponsesFileSearchAttribute(ofBool: true),
            },
          ),
        ],
      );
      final block = _tag(
        ContentBlock(
          ServerToolResult(
            name: OpenAIResponsesServerToolName.fileSearch.value,
            content: OpenAIResponsesServerToolResult(fileSearch: result),
          ),
        ),
        'fs1',
        'completed',
      );
      final item = fileSearchToolResultToInputItem(result, block);
      expect(item['id'], 'fs1');
      expect(item['status'], 'completed');
      expect(item['results'], [
        {
          'file_id': 'file1',
          'filename': 'test.txt',
          'score': 0.85,
          'text': 'matching text',
          'attributes': {
            'str_attr': 'test_string',
            'float_attr': 0.95,
            'bool_attr': true,
          },
        },
      ]);
    });

    test('empty_results', () {
      final result = OpenAIResponsesFileSearchResult();
      final block = _tag(
        ContentBlock(
          ServerToolResult(
            name: OpenAIResponsesServerToolName.fileSearch.value,
            content: OpenAIResponsesServerToolResult(fileSearch: result),
          ),
        ),
        'fs2',
        'completed',
      );
      expect(fileSearchToolResultToInputItem(result, block)['results'], isEmpty);
    });
  });

  test('TestServerToolCallToInputItemFileSearch', () {
    final block = _tag(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.fileSearch.value,
          arguments: OpenAIResponsesServerToolCallArguments(
            fileSearch: OpenAIResponsesFileSearchArguments(
              queries: const ['search query'],
            ),
          ),
        ),
      ),
      'fs1',
      'in_progress',
    );
    final item = serverToolCallToInputItem(block);
    expect(item['type'], 'file_search_call');
    expect(item['id'], 'fs1');
    expect(item['queries'], ['search query']);
  });

  test('TestServerToolResultToInputItemFileSearch', () {
    final block = _tag(
      ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.fileSearch.value,
          content: OpenAIResponsesServerToolResult(
            fileSearch: OpenAIResponsesFileSearchResult(
              results: [
                OpenAIResponsesFileSearchResultItem(
                  fileId: 'f1',
                  fileName: 'doc.pdf',
                  score: 0.9,
                  text: 'content',
                ),
              ],
            ),
          ),
        ),
      ),
      'fs1',
      'completed',
    );
    final item = serverToolResultToInputItem(block);
    expect(item['id'], 'fs1');
    expect(_first(item['results'])['file_id'], 'f1');
  });

  group('TestFileSearchToContentBlocks', () {
    test('with_results', () {
      final blocks = fileSearchToContentBlocks({
        'id': 'fs1',
        'status': 'completed',
        'queries': ['query1'],
        'results': [
          {
            'file_id': 'file1',
            'filename': 'test.txt',
            'score': 0.85,
            'text': 'matched text',
            'attributes': {'attr1': 'val1'},
          },
        ],
      });
      expect(blocks, hasLength(2));
      expect(itemIdOf(blocks[0]), 'fs1');
      expect(
        blocks[0].serverToolCall!.name,
        OpenAIResponsesServerToolName.fileSearch.value,
      );
      expect(itemIdOf(blocks[1]), 'fs1');
      expect(
        blocks[1].serverToolResult!.name,
        OpenAIResponsesServerToolName.fileSearch.value,
      );
      final result =
          blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
      final item = result.fileSearch!.results.single;
      expect(item.fileName, 'test.txt');
      expect(item.attributes['attr1']!.ofString, 'val1');
    });

    test('empty_results', () {
      final blocks = fileSearchToContentBlocks({
        'id': 'fs2',
        'status': 'completed',
        'queries': ['query2'],
        'results': <Object?>[],
      });
      expect(blocks, hasLength(2));
    });

    test('with_float_attribute', () {
      final blocks = fileSearchToContentBlocks({
        'id': 'fs3',
        'results': [
          {
            'file_id': 'f1',
            'attributes': {'score_attr': 0.95},
          },
        ],
      });
      final result =
          blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
      expect(
        result.fileSearch!.results.single.attributes['score_attr']!.ofFloat,
        0.95,
      );
    });

    test('with_bool_attribute', () {
      final blocks = fileSearchToContentBlocks({
        'id': 'fs4',
        'results': [
          {
            'file_id': 'f1',
            'attributes': {'is_valid': true},
          },
        ],
      });
      final result =
          blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
      expect(
        result.fileSearch!.results.single.attributes['is_valid']!.ofBool,
        isTrue,
      );
    });
  });

  group('TestCodeInterpreterToContentBlocks', () {
    test('with_logs_output', () {
      final blocks = codeInterpreterToContentBlocks({
        'id': 'ci1',
        'status': 'completed',
        'code': "print('hello world')",
        'container_id': 'container123',
        'outputs': [
          {'type': 'logs', 'logs': "print('hello world')"},
        ],
      });
      expect(blocks, hasLength(2));
      expect(itemIdOf(blocks[0]), 'ci1');
      expect(
        blocks[0].serverToolCall!.name,
        OpenAIResponsesServerToolName.codeInterpreter.value,
      );
      expect(itemIdOf(blocks[1]), 'ci1');
      expect(
        blocks[1].serverToolResult!.name,
        OpenAIResponsesServerToolName.codeInterpreter.value,
      );
    });

    test('with_image_output', () {
      final blocks = codeInterpreterToContentBlocks({
        'id': 'ci2',
        'status': 'completed',
        'code': 'plot()',
        'container_id': 'container456',
        'outputs': [
          {'type': 'image', 'url': 'https://example.com/image.png'},
        ],
      });
      final result =
          blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
      expect(
        result.codeInterpreter!.outputs.single.image!.url,
        'https://example.com/image.png',
      );
    });

    test('empty_outputs', () {
      final blocks = codeInterpreterToContentBlocks({
        'id': 'ci3',
        'status': 'completed',
        'code': 'x = 1 + 1',
        'container_id': 'container789',
        'outputs': <Object?>[],
      });
      final result =
          blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
      expect(result.codeInterpreter!.code, 'x = 1 + 1');
      expect(result.codeInterpreter!.containerId, 'container789');
      expect(result.codeInterpreter!.outputs, isEmpty);
    });

    test('unknown output type and untyped (streamed) outputs', () {
      expect(
        () => codeInterpreterToContentBlocks({
          'outputs': [
            {'type': 'video'},
          ],
        }),
        _throwsWith('unknown code interpreter output type: video'),
      );
      final blocks = codeInterpreterToContentBlocks({
        'outputs': [<String, Object?>{}],
      });
      final result =
          blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
      expect(result.codeInterpreter!.outputs, isEmpty);
    });
  });

  group('TestImageGenerationToContentBlocks', () {
    test('with_result', () {
      final blocks = imageGenerationToContentBlocks({
        'id': 'ig1',
        'status': 'completed',
        'result': 'base64_image_data_here',
      });
      expect(blocks, hasLength(2));
      expect(itemIdOf(blocks[0]), 'ig1');
      expect(
        blocks[0].serverToolCall!.name,
        OpenAIResponsesServerToolName.imageGeneration.value,
      );
      expect(itemIdOf(blocks[1]), 'ig1');
      final result =
          blocks[1].serverToolResult!.content! as OpenAIResponsesServerToolResult;
      expect(result.imageGeneration!.imageBase64, 'base64_image_data_here');
    });

    test('in_progress_status', () {
      final blocks = imageGenerationToContentBlocks({
        'id': 'ig2',
        'status': 'in_progress',
        'result': '',
      });
      expect(itemStatusOf(blocks[0]), 'in_progress');
    });
  });

  test('TestCodeInterpreterToolCallToInputItem', () {
    final block = _tag(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.codeInterpreter.value,
          arguments: const OpenAIResponsesServerToolCallArguments(
            codeInterpreter: OpenAIResponsesCodeInterpreterArguments(),
          ),
        ),
      ),
      'ci1',
      'completed',
    );
    final item = codeInterpreterToolCallToInputItem(
      const OpenAIResponsesCodeInterpreterArguments(),
      block,
    );
    expect(item['type'], 'code_interpreter_call');
    expect(item['id'], 'ci1');
    expect(item['status'], 'completed');
  });

  group('TestCodeInterpreterToolResultToInputItem', () {
    test('with_logs_and_image_outputs', () {
      final result = OpenAIResponsesCodeInterpreterResult(
        code: "print('hello')",
        containerId: 'ctr1',
        outputs: const [
          OpenAIResponsesCodeInterpreterOutput(
            type: OpenAIResponsesCodeInterpreterOutputType.logs,
            logs: OpenAIResponsesCodeInterpreterOutputLogs(logs: 'hello'),
          ),
          OpenAIResponsesCodeInterpreterOutput(
            type: OpenAIResponsesCodeInterpreterOutputType.image,
            image: OpenAIResponsesCodeInterpreterOutputImage(
              url: 'https://example.com/img.png',
            ),
          ),
        ],
      );
      final block = _tag(
        ContentBlock(
          ServerToolResult(
            name: OpenAIResponsesServerToolName.codeInterpreter.value,
            content: OpenAIResponsesServerToolResult(codeInterpreter: result),
          ),
        ),
        'ci1',
        'completed',
      );
      final item = codeInterpreterToolResultToInputItem(result, block);
      expect(item['id'], 'ci1');
      expect(item['container_id'], 'ctr1');
      expect(item['code'], "print('hello')");
      expect(item['outputs'], [
        {'type': 'logs', 'logs': 'hello'},
        {'type': 'image', 'url': 'https://example.com/img.png'},
      ]);
    });

    test('unknown_output_type', () {
      final result = OpenAIResponsesCodeInterpreterResult(
        outputs: const [
          OpenAIResponsesCodeInterpreterOutput(
            type: OpenAIResponsesCodeInterpreterOutputType('unknown_type'),
          ),
        ],
      );
      final block = ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.codeInterpreter.value,
          content: OpenAIResponsesServerToolResult(codeInterpreter: result),
        ),
      );
      expect(() => codeInterpreterToolResultToInputItem(result, block), _throws);
    });
  });

  test('TestImageGenerationToolCallToInputItem', () {
    final block = _tag(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.imageGeneration.value,
          arguments: const OpenAIResponsesServerToolCallArguments(
            imageGeneration: OpenAIResponsesImageGenerationArguments(),
          ),
        ),
      ),
      'ig1',
      'in_progress',
    );
    expect(
      imageGenerationToolCallToInputItem(
        const OpenAIResponsesImageGenerationArguments(),
        block,
      ),
      {'type': 'image_generation_call', 'id': 'ig1', 'status': 'in_progress'},
    );
  });

  test('TestImageGenerationToolResultToInputItem', () {
    const result = OpenAIResponsesImageGenerationResult(
      imageBase64: 'abc123base64',
    );
    final block = _tag(
      ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.imageGeneration.value,
          content: const OpenAIResponsesServerToolResult(
            imageGeneration: result,
          ),
        ),
      ),
      'ig1',
      'completed',
    );
    expect(imageGenerationToolResultToInputItem(result, block), {
      'type': 'image_generation_call',
      'id': 'ig1',
      'status': 'completed',
      'result': 'abc123base64',
    });
  });

  group('TestShellToolCallToInputItem', () {
    test('local_environment_with_skills', () {
      final args = OpenAIResponsesShellArguments(
        action: OpenAIResponsesShellAction(
          commands: const ['ls -la', 'pwd'],
          timeoutMs: 30000,
          maxOutputLength: 1024,
        ),
        environment: OpenAIResponsesShellEnvironment(
          type: OpenAIResponsesShellEnvironmentType.local,
          local: OpenAIResponsesShellEnvironmentLocal(
            skills: const [
              OpenAIResponsesShellEnvironmentLocalSkill(
                name: 'go',
                description: 'Go language',
                path: '/usr/local/go',
              ),
            ],
          ),
        ),
        createdBy: 'user1',
      );
      final block = _tag(
        ContentBlock(
          ServerToolCall(
            name: OpenAIResponsesServerToolName.shell.value,
            callId: 'call_1',
            arguments: OpenAIResponsesServerToolCallArguments(shell: args),
          ),
        ),
        'sh1',
        'completed',
      );
      final item = shellToolCallToInputItem(args, block);
      expect(item, {
        'type': 'shell_call',
        'id': 'sh1',
        'call_id': 'call_1',
        'status': 'completed',
        'action': {
          'commands': ['ls -la', 'pwd'],
          'timeout_ms': 30000,
          'max_output_length': 1024,
        },
        'environment': {
          'type': 'local',
          'skills': [
            {
              'name': 'go',
              'description': 'Go language',
              'path': '/usr/local/go',
            },
          ],
        },
      });
    });

    test('container_environment', () {
      final args = OpenAIResponsesShellArguments(
        action: OpenAIResponsesShellAction(commands: const ['echo hello']),
        environment: const OpenAIResponsesShellEnvironment(
          type: OpenAIResponsesShellEnvironmentType.containerReference,
          containerReference: OpenAIResponsesShellEnvironmentContainerReference(
            containerId: 'ctr123',
          ),
        ),
      );
      final block = withItemId(
        ContentBlock(
          ServerToolCall(
            name: OpenAIResponsesServerToolName.shell.value,
            callId: 'call_2',
            arguments: OpenAIResponsesServerToolCallArguments(shell: args),
          ),
        ),
        'sh2',
      );
      expect(shellToolCallToInputItem(args, block)['environment'], {
        'type': 'container_reference',
        'container_id': 'ctr123',
      });
    });

    test('unknown_environment_type', () {
      final args = OpenAIResponsesShellArguments(
        action: OpenAIResponsesShellAction(commands: const ['echo']),
        environment: const OpenAIResponsesShellEnvironment(
          type: OpenAIResponsesShellEnvironmentType('unknown'),
        ),
      );
      final block = ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.shell.value,
          callId: 'call_3',
          arguments: OpenAIResponsesServerToolCallArguments(shell: args),
        ),
      );
      expect(() => shellToolCallToInputItem(args, block), _throws);
    });
  });

  group('TestShellToolResultToInputItem', () {
    test('with_exit_outcome', () {
      final result = OpenAIResponsesShellResult(
        maxOutputLength: 2048,
        createdBy: 'user1',
        outputs: const [
          OpenAIResponsesShellOutputItem(
            stdout: 'file.txt',
            outcome: OpenAIResponsesShellOutputOutcome(
              type: OpenAIResponsesShellOutputOutcomeType.exit,
              exit: OpenAIResponsesShellOutputOutcomeExit(),
            ),
          ),
        ],
      );
      final block = _tag(
        ContentBlock(
          ServerToolResult(
            name: OpenAIResponsesServerToolName.shell.value,
            callId: 'call_1',
            content: OpenAIResponsesServerToolResult(shell: result),
          ),
        ),
        'sh1',
        'completed',
      );
      expect(shellToolResultToInputItem(result, block), {
        'type': 'shell_call_output',
        'id': 'sh1',
        'call_id': 'call_1',
        'status': 'completed',
        'output': [
          {
            'stdout': 'file.txt',
            'stderr': '',
            'outcome': {'type': 'exit', 'exit_code': 0},
          },
        ],
        'max_output_length': 2048,
      });
    });

    test('with_timeout_outcome', () {
      final result = OpenAIResponsesShellResult(
        outputs: const [
          OpenAIResponsesShellOutputItem(
            stdout: 'partial',
            stderr: 'timed out',
            outcome: OpenAIResponsesShellOutputOutcome(
              type: OpenAIResponsesShellOutputOutcomeType.timeout,
            ),
          ),
        ],
      );
      final block = withItemId(
        ContentBlock(
          ServerToolResult(
            name: OpenAIResponsesServerToolName.shell.value,
            callId: 'call_2',
            content: OpenAIResponsesServerToolResult(shell: result),
          ),
        ),
        'sh2',
      );
      final item = shellToolResultToInputItem(result, block);
      expect(_first(item['output'])['outcome'], {'type': 'timeout'});
    });

    test('unknown_outcome_type', () {
      final result = OpenAIResponsesShellResult(
        outputs: const [
          OpenAIResponsesShellOutputItem(
            outcome: OpenAIResponsesShellOutputOutcome(
              type: OpenAIResponsesShellOutputOutcomeType('unknown'),
            ),
          ),
        ],
      );
      final block = ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.shell.value,
          callId: 'call_3',
          content: OpenAIResponsesServerToolResult(shell: result),
        ),
      );
      expect(() => shellToolResultToInputItem(result, block), _throws);
    });
  });

  test('TestServerToolCallToInputItem_CodeInterpreter', () {
    final block = withItemId(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.codeInterpreter.value,
          arguments: const OpenAIResponsesServerToolCallArguments(
            codeInterpreter: OpenAIResponsesCodeInterpreterArguments(),
          ),
        ),
      ),
      'ci1',
    );
    final item = serverToolCallToInputItem(block);
    expect(item['type'], 'code_interpreter_call');
    expect(item['id'], 'ci1');
  });

  test('TestServerToolCallToInputItem_ImageGeneration', () {
    final block = withItemId(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.imageGeneration.value,
          arguments: const OpenAIResponsesServerToolCallArguments(
            imageGeneration: OpenAIResponsesImageGenerationArguments(),
          ),
        ),
      ),
      'ig1',
    );
    final item = serverToolCallToInputItem(block);
    expect(item['type'], 'image_generation_call');
    expect(item['id'], 'ig1');
  });

  test('TestServerToolCallToInputItem_Shell', () {
    final block = withItemId(
      ContentBlock(
        ServerToolCall(
          name: OpenAIResponsesServerToolName.shell.value,
          callId: 'call_sh',
          arguments: OpenAIResponsesServerToolCallArguments(
            shell: OpenAIResponsesShellArguments(
              action: OpenAIResponsesShellAction(commands: const ['ls']),
            ),
          ),
        ),
      ),
      'sh1',
    );
    final item = serverToolCallToInputItem(block);
    expect(item['type'], 'shell_call');
    expect(item['call_id'], 'call_sh');
  });

  test('TestServerToolCallToInputItem_Nil', () {
    final block = ContentBlock(
      ServerToolCall(
        name: OpenAIResponsesServerToolName.codeInterpreter.value,
        arguments: const OpenAIResponsesServerToolCallArguments(),
      ),
    );
    expect(() => serverToolCallToInputItem(block), _throws);
  });

  test('TestServerToolResultToInputItem_CodeInterpreter', () {
    final block = _tag(
      ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.codeInterpreter.value,
          content: OpenAIResponsesServerToolResult(
            codeInterpreter: OpenAIResponsesCodeInterpreterResult(
              code: 'x = 1',
              containerId: 'ctr1',
            ),
          ),
        ),
      ),
      'ci1',
      'completed',
    );
    final item = serverToolResultToInputItem(block);
    expect(item['id'], 'ci1');
    expect(item['container_id'], 'ctr1');
  });

  test('TestServerToolResultToInputItem_ImageGeneration', () {
    final block = withItemId(
      ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.imageGeneration.value,
          content: const OpenAIResponsesServerToolResult(
            imageGeneration: OpenAIResponsesImageGenerationResult(
              imageBase64: 'abc',
            ),
          ),
        ),
      ),
      'ig1',
    );
    expect(serverToolResultToInputItem(block)['result'], 'abc');
  });

  test('TestServerToolResultToInputItem_Shell', () {
    final block = withItemId(
      ContentBlock(
        ServerToolResult(
          name: OpenAIResponsesServerToolName.shell.value,
          callId: 'call_sh',
          content: OpenAIResponsesServerToolResult(
            shell: OpenAIResponsesShellResult(
              outputs: const [OpenAIResponsesShellOutputItem(stdout: 'ok')],
            ),
          ),
        ),
      ),
      'sh1',
    );
    final item = serverToolResultToInputItem(block);
    expect(item['call_id'], 'call_sh');
    expect(_first(item['output'])['stdout'], 'ok');
  });

  test('TestServerToolResultToInputItem_Nil', () {
    final block = ContentBlock(
      ServerToolResult(
        name: OpenAIResponsesServerToolName.codeInterpreter.value,
        content: const OpenAIResponsesServerToolResult(),
      ),
    );
    expect(() => serverToolResultToInputItem(block), _throws);
  });

  group('TestPairFileSearchToolCallItems', () {
    test('merge_call_and_result', () {
      final items = pairFileSearchToolCallItems([
        {
          'type': 'file_search_call',
          'id': 'fs1',
          'status': 'searching',
          'queries': ['query1'],
        },
        {'type': 'web_search_call', 'id': 'ws1'},
        {
          'type': 'file_search_call',
          'id': 'fs1',
          'status': 'completed',
          'results': [
            {'filename': 'file.txt', 'score': 0.9, 'text': 'content'},
          ],
        },
      ]);
      expect(items, hasLength(2));
      expect(items[0]['id'], 'fs1');
      expect(items[0]['queries'], ['query1']);
      expect(items[0]['results'], hasLength(1));
      // The status of the first item wins (Go's coalesce).
      expect(items[0]['status'], 'searching');
      expect(items[1]['type'], 'web_search_call');
    });

    test('unpaired_error', () {
      expect(
        () => pairFileSearchToolCallItems([
          {'type': 'file_search_call', 'id': 'fs1'},
        ]),
        _throws,
      );
    });
  });

  group('TestPairCodeInterpreterToolCallItems', () {
    test('merge_call_and_result', () {
      final items = pairCodeInterpreterToolCallItems([
        {'type': 'code_interpreter_call', 'id': 'ci1', 'container_id': ''},
        {'type': 'web_search_call', 'id': 'ws1'},
        {
          'type': 'code_interpreter_call',
          'id': 'ci1',
          'status': 'completed',
          'container_id': 'ctr1',
          'code': "print('hi')",
          'outputs': [
            {'type': 'logs', 'logs': 'hi'},
          ],
        },
      ]);
      expect(items, hasLength(2));
      expect(items[0]['id'], 'ci1');
      expect(items[0]['container_id'], 'ctr1');
      expect(items[0]['code'], "print('hi')");
      expect(items[0]['outputs'], hasLength(1));
      expect(items[0]['status'], 'completed');
      expect(items[1]['type'], 'web_search_call');
    });

    test('unpaired_error', () {
      expect(
        () => pairCodeInterpreterToolCallItems([
          {'type': 'code_interpreter_call', 'id': 'ci1'},
        ]),
        _throws,
      );
    });
  });

  group('TestPairImageGenerationToolCallItems', () {
    test('merge_call_and_result', () {
      final items = pairImageGenerationToolCallItems([
        {'type': 'image_generation_call', 'id': 'ig1'},
        {'type': 'web_search_call', 'id': 'ws1'},
        {
          'type': 'image_generation_call',
          'id': 'ig1',
          'status': 'completed',
          'result': 'base64data',
        },
      ]);
      expect(items, hasLength(2));
      expect(items[0], {
        'type': 'image_generation_call',
        'id': 'ig1',
        'status': 'completed',
        'result': 'base64data',
      });
      expect(items[1]['type'], 'web_search_call');
    });

    test('unpaired_error', () {
      expect(
        () => pairImageGenerationToolCallItems([
          {'type': 'image_generation_call', 'id': 'ig1'},
        ]),
        _throws,
      );
    });
  });

  group('tools and tool choice (responses_model.go helpers)', () {
    test('a raw JSON schema is sent as it is', () {
      final tool = ToolInfo.fromJsonSchemaMap(
        name: 'f',
        desc: 'd',
        schema: const {
          'type': 'object',
          'properties': {
            'x': {
              'anyOf': [
                {'type': 'string'},
                {'type': 'number'},
              ],
            },
          },
        },
      );
      expect(toFunctionTool(tool), {
        'type': 'function',
        'name': 'f',
        'description': 'd',
        'parameters': {
          'type': 'object',
          'properties': {
            'x': {
              'anyOf': [
                {'type': 'string'},
                {'type': 'number'},
              ],
            },
          },
        },
      });
    });

    test('a typed schema is converted; a tool without parameters has none',
        () {
      final typed = ToolInfo.fromParams(
        name: 'g',
        params: {
          'city': ParameterInfo(type: DataType.string, required: true),
        },
      );
      final json = toFunctionTool(typed);
      expect((json['parameters']! as Json)['type'], 'object');
      expect(
        ((json['parameters']! as Json)['properties']! as Json).keys,
        ['city'],
      );
      expect(
        toFunctionTool(ToolInfo.fromParamsOneOf(name: 'h')),
        {'type': 'function', 'name': 'h'},
      );
    });

    test('fromFunctionTools reads function entries only', () {
      final tools = fromFunctionTools([
        {
          'type': 'function',
          'name': 'a',
          'parameters': {'type': 'object'},
        },
        {'type': 'mcp'},
        {'type': 'function', 'name': 'b'},
      ]);
      expect(tools.map((t) => t.name), ['a', 'b']);
      expect(tools[0].function.parametersJsonSchema, {'type': 'object'});
      expect(tools[1].paramsOneOf, isNull);
    });

    test('toAllowedTools and toToolChoice', () {
      expect(toToolChoice(null), isNull);
      expect(
        toToolChoice(const AgenticToolChoice(type: ToolChoice.forbidden)),
        'none',
      );
      expect(
        toToolChoice(const AgenticToolChoice(type: ToolChoice.allowed)),
        'auto',
      );
      expect(
        toToolChoice(const AgenticToolChoice(type: ToolChoice.forced)),
        'required',
      );
      expect(
        toToolChoice(
          AgenticToolChoice(
            type: ToolChoice.allowed,
            allowed: AgenticAllowedToolChoice(
              tools: const [
                AllowedFunctionTool('f'),
                AllowedMcpTool(serverLabel: 's', name: ''),
                AllowedMcpTool(serverLabel: 's', name: 'n'),
                AllowedServerTool('web_search'),
              ],
            ),
          ),
        ),
        {
          'type': 'allowed_tools',
          'mode': 'auto',
          'tools': [
            {'type': 'function', 'name': 'f'},
            {'type': 'mcp', 'server_label': 's'},
            {'type': 'mcp', 'server_label': 's', 'name': 'n'},
            {'type': 'web_search'},
          ],
        },
      );
      expect(
        toToolChoice(
          AgenticToolChoice(
            type: ToolChoice.forced,
            forced: AgenticForcedToolChoice(
              tools: const [AllowedFunctionTool('f')],
            ),
          ),
        ),
        {
          'type': 'allowed_tools',
          'mode': 'required',
          'tools': [
            {'type': 'function', 'name': 'f'},
          ],
        },
      );
    });
  });
}
