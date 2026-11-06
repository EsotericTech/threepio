// Port of eino-ext components/model/agenticclaude/extension_test.go (both
// tests: TestGetServerToolCallArguments, TestGetServerToolResult) and the
// registrations of register.go, plus JSON round trips of every extension
// type, mapstructure-style decoding errors, value equality and the
// StreamConcat function for the arguments (not in Go).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_consts.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_extension.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_register.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_utils.dart';
import 'package:threepio_core/threepio_core.dart';

Matcher _formatError(Object message) =>
    isA<ThreepioFormatException>().having((e) => e.message, 'message', message);

final _allArguments = [
  const ClaudeServerToolCallArguments(
    webSearch: ClaudeWebSearchArguments(query: 'q'),
  ),
  const ClaudeServerToolCallArguments(
    webFetch: ClaudeWebFetchArguments(url: 'https://example.com'),
  ),
  const ClaudeServerToolCallArguments(
    codeExecution: ClaudeCodeExecutionArguments(code: 'print(1)'),
  ),
  const ClaudeServerToolCallArguments(
    bashCodeExecution: ClaudeBashCodeExecutionArguments(command: 'ls'),
  ),
  const ClaudeServerToolCallArguments(
    textEditorCodeExecution: ClaudeTextEditorCodeExecutionArguments(
      command: 'str_replace',
      path: '/tmp/a.txt',
      fileText: 'x',
      oldStr: 'a',
      newStr: 'b',
    ),
  ),
  const ClaudeServerToolCallArguments(
    toolSearchToolBm25: ClaudeToolSearchToolBm25Arguments(query: 'weather'),
  ),
  const ClaudeServerToolCallArguments(
    toolSearchToolRegex: ClaudeToolSearchToolRegexArguments(query: 'get_.*'),
  ),
];

final _allResults = [
  ClaudeServerToolResult(
    webSearch: ClaudeWebSearchResult(
      type: ClaudeWebSearchResultType.result,
      result: ClaudeWebSearchResultBlock(
        content: const [
          ClaudeWebSearchResultItem(
            title: 'Go',
            url: 'https://go.dev',
            encryptedContent: 'enc',
            pageAge: '2 days',
          ),
        ],
      ),
    ),
  ),
  const ClaudeServerToolResult(
    webSearch: ClaudeWebSearchResult(
      type: ClaudeWebSearchResultType.error,
      error: ClaudeWebSearchResultError(code: 'too_many_requests'),
    ),
  ),
  const ClaudeServerToolResult(
    webFetch: ClaudeWebFetchResult(
      type: ClaudeWebFetchResultType.result,
      result: ClaudeWebFetchResultBlock(
        url: 'https://example.com',
        retrievedAt: '2026-05-19T00:00:00Z',
        content: ClaudeWebFetchDocument(
          title: 'doc',
          citations: ClaudeWebFetchDocumentCitations(enabled: true),
          source: ClaudeWebFetchDocumentSource(
            mimeType: 'text/plain',
            data: 'hello',
          ),
        ),
      ),
    ),
  ),
  const ClaudeServerToolResult(
    webFetch: ClaudeWebFetchResult(
      type: ClaudeWebFetchResultType.error,
      error: ClaudeWebFetchResultError(code: 'url_not_accessible'),
    ),
  ),
  ClaudeServerToolResult(
    codeExecution: ClaudeCodeExecutionResult(
      type: ClaudeCodeExecutionResultType.result,
      result: ClaudeCodeExecutionResultBlock(
        content: const [ClaudeCodeExecutionOutput(fileId: 'f1')],
        stdout: 'out',
        stderr: 'err',
        returnCode: 2,
      ),
    ),
  ),
  ClaudeServerToolResult(
    codeExecution: ClaudeCodeExecutionResult(
      type: ClaudeCodeExecutionResultType.encrypted,
      encryptedResult: ClaudeEncryptedCodeExecutionResultBlock(
        encryptedStdout: 'enc',
        returnCode: 1,
      ),
    ),
  ),
  const ClaudeServerToolResult(
    codeExecution: ClaudeCodeExecutionResult(
      type: ClaudeCodeExecutionResultType.error,
      error: ClaudeCodeExecutionResultError(code: 'unavailable'),
    ),
  ),
  ClaudeServerToolResult(
    bashCodeExecution: ClaudeBashCodeExecutionResult(
      type: ClaudeBashCodeExecutionResultType.result,
      result: ClaudeBashCodeExecutionResultBlock(
        content: const [ClaudeCodeExecutionOutput(fileId: 'f2')],
        stdout: 'ok',
      ),
    ),
  ),
  const ClaudeServerToolResult(
    bashCodeExecution: ClaudeBashCodeExecutionResult(
      type: ClaudeBashCodeExecutionResultType.error,
      error: ClaudeBashCodeExecutionResultError(code: 'output_file_too_large'),
    ),
  ),
  const ClaudeServerToolResult(
    textEditorCodeExecution: ClaudeTextEditorCodeExecutionResult(
      type: ClaudeTextEditorCodeExecutionResultType.view,
      view: ClaudeTextEditorCodeExecutionViewResult(
        fileType: 'text',
        content: 'hello',
        numLines: 1,
        startLine: 1,
        totalLines: 3,
      ),
    ),
  ),
  const ClaudeServerToolResult(
    textEditorCodeExecution: ClaudeTextEditorCodeExecutionResult(
      type: ClaudeTextEditorCodeExecutionResultType.create,
      create: ClaudeTextEditorCodeExecutionCreateResult(isFileUpdate: true),
    ),
  ),
  ClaudeServerToolResult(
    textEditorCodeExecution: ClaudeTextEditorCodeExecutionResult(
      type: ClaudeTextEditorCodeExecutionResultType.strReplace,
      strReplace: ClaudeTextEditorCodeExecutionStrReplaceResult(
        oldStart: 1,
        oldLines: 2,
        newStart: 3,
        newLines: 4,
        lines: const ['a', 'b'],
      ),
    ),
  ),
  const ClaudeServerToolResult(
    textEditorCodeExecution: ClaudeTextEditorCodeExecutionResult(
      type: ClaudeTextEditorCodeExecutionResultType.error,
      error: ClaudeTextEditorCodeExecutionResultError(
        code: 'file_not_found',
        message: 'missing',
      ),
    ),
  ),
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
  const ClaudeServerToolResult(
    toolSearchToolRegex: ClaudeToolSearchToolResult(
      type: ClaudeToolSearchToolResultType.error,
      error: ClaudeToolSearchToolResultError(code: 'bad', message: 'msg'),
    ),
  ),
];

void main() {
  group('TestGetServerToolCallArguments', () {
    test('success', () {
      const args = ClaudeServerToolCallArguments(
        webSearch: ClaudeWebSearchArguments(query: 'q'),
      );
      final got = claudeServerToolCallArguments(
        ServerToolCall(
          name: ClaudeServerToolName.webSearch.value,
          arguments: args,
        ),
      );
      expect(identical(got, args), isTrue);
    });

    test('map[string]any success', () {
      final got = claudeServerToolCallArguments(
        ServerToolCall(
          name: ClaudeServerToolName.webSearch.value,
          arguments: const {
            'web_search': {'query': 'test query'},
          },
        ),
      );
      expect(got.webSearch?.query, 'test query');
    });

    test('unexpected type', () {
      expect(
        () => claudeServerToolCallArguments(
          ServerToolCall(
            name: ClaudeServerToolName.webSearch.value,
            arguments: 'invalid',
          ),
        ),
        throwsA(
          _formatError(
            contains('unexpected type string for server tool call arguments'),
          ),
        ),
      );
    });

    test('nil arguments and undecodable maps', () {
      expect(
        () => claudeServerToolCallArguments(const ServerToolCall()),
        throwsA(_formatError('server tool call arguments are nil')),
      );
      expect(
        () => claudeServerToolCallArguments(
          const ServerToolCall(
            arguments: {
              'web_search': {'query': 7},
            },
          ),
        ),
        throwsA(
          _formatError(
            "failed to decode server tool call arguments: 'web_search.query' "
            "expected type 'string', got unconvertible type 'float64'",
          ),
        ),
      );
    });
  });

  group('TestGetServerToolResult', () {
    test('success', () {
      const result = ClaudeServerToolResult(
        webFetch: ClaudeWebFetchResult(type: ClaudeWebFetchResultType.result),
      );
      final got = claudeServerToolResultOf(
        ServerToolResult(
          name: ClaudeServerToolName.webFetch.value,
          content: result,
        ),
      );
      expect(identical(got, result), isTrue);
    });

    test('map[string]any success', () {
      final got = claudeServerToolResultOf(
        ServerToolResult(
          name: ClaudeServerToolName.webFetch.value,
          content: const {
            'web_fetch': {
              'type': 'web_fetch_result',
              'result': {'url': 'https://example.com'},
            },
          },
        ),
      );
      expect(got.webFetch?.type, ClaudeWebFetchResultType.result);
      expect(got.webFetch?.result?.url, 'https://example.com');
    });

    test('unexpected type', () {
      expect(
        () => claudeServerToolResultOf(
          ServerToolResult(
            name: ClaudeServerToolName.webFetch.value,
            content: 'invalid',
          ),
        ),
        throwsA(
          _formatError(
            contains('unexpected type string for server tool result'),
          ),
        ),
      );
      expect(
        () => claudeServerToolResultOf(const ServerToolResult()),
        throwsA(_formatError('server tool result is nil')),
      );
    });
  });

  group('JSON', () {
    test('arguments in Go shape', () {
      expect(_allArguments[4].toJson(), {
        'text_editor_code_execution': {
          'command': 'str_replace',
          'path': '/tmp/a.txt',
          'file_text': 'x',
          'old_str': 'a',
          'new_str': 'b',
        },
      });
      expect(
        const ClaudeServerToolCallArguments(
          webSearch: ClaudeWebSearchArguments(),
        ).toJson(),
        {'web_search': <String, Object?>{}},
      );
    });

    test('results in Go shape (omitempty, camelCase line counts)', () {
      expect(_allResults[9].toJson(), {
        'text_editor_code_execution': {
          'type': 'text_editor_code_execution_view_result',
          'view': {
            'file_type': 'text',
            'content': 'hello',
            'numLines': 1,
            'startLine': 1,
            'totalLines': 3,
          },
        },
      });
      expect(_allResults[5].toJson(), {
        'code_execution': {
          'type': 'encrypted_code_execution_result',
          'encrypted_result': {'encrypted_stdout': 'enc', 'return_code': 1},
        },
      });
      expect(_allResults[2].toJson()['web_fetch'], {
        'type': 'web_fetch_result',
        'result': {
          'url': 'https://example.com',
          'retrieved_at': '2026-05-19T00:00:00Z',
          'content': {
            'source': {'media_type': 'text/plain', 'data': 'hello'},
            'title': 'doc',
            'citations': {'enabled': true},
          },
        },
      });
    });

    test('every arguments value survives a JSON round trip', () {
      for (final args in _allArguments) {
        final json = jsonDecode(jsonEncode(args)) as Map<String, Object?>;
        expect(ClaudeServerToolCallArguments.fromJson(json), args);
      }
    });

    test('every result survives a JSON round trip', () {
      for (final result in _allResults) {
        final json = jsonDecode(jsonEncode(result)) as Map<String, Object?>;
        expect(ClaudeServerToolResult.fromJson(json), result);
      }
    });

    test(
      'decoding follows mapstructure: numbers truncate, types must match',
      () {
        final block = ClaudeCodeExecutionResultBlock.fromJson(const {
          'return_code': 2.9,
          'content': [
            null,
            {'file_id': 'f'},
          ],
        });
        expect(block.returnCode, 2);
        expect(block.content, const [ClaudeCodeExecutionOutput(fileId: 'f')]);
        expect(
          () =>
              ClaudeWebFetchDocumentCitations.fromJson(const {'enabled': 'y'}),
          throwsA(
            _formatError(
              "'enabled' expected type 'bool', got unconvertible type 'string'",
            ),
          ),
        );
        expect(
          () => ClaudeServerToolResult.fromJson(const {'web_search': 'x'}),
          throwsA(_formatError("'web_search' expected a map, got 'string'")),
        );
        expect(
          () => ClaudeTextEditorCodeExecutionStrReplaceResult.fromJson(const {
            'lines': ['a', 1],
          }),
          throwsA(isA<ThreepioFormatException>()),
        );
        expect(
          () => ClaudeWebSearchResultBlock.fromJson(const {'content': 'x'}),
          throwsA(isA<ThreepioFormatException>()),
        );
        expect(
          () => ClaudeCodeExecutionResultBlock.fromJson(const {'stdout': true}),
          throwsA(isA<ThreepioFormatException>()),
        );
        expect(
          () => ClaudeCodeExecutionResultBlock.fromJson(const {
            'return_code': '1',
          }),
          throwsA(isA<ThreepioFormatException>()),
        );
      },
    );
  });

  group('value equality', () {
    test('equal values, different values, different classes', () {
      expect(
        const ClaudeWebSearchArguments(query: 'a'),
        const ClaudeWebSearchArguments(query: 'a'),
      );
      expect(
        const ClaudeWebSearchArguments(query: 'a').hashCode,
        const ClaudeWebSearchArguments(query: 'a').hashCode,
      );
      expect(
        const ClaudeWebSearchArguments(query: 'a'),
        isNot(const ClaudeWebSearchArguments(query: 'b')),
      );
      expect(
        const ClaudeToolSearchToolBm25Arguments(query: 'a'),
        isNot(const ClaudeToolSearchToolRegexArguments(query: 'a')),
      );
      expect(
        ClaudeWebSearchResultBlock(),
        ClaudeWebSearchResultBlock(content: const []),
      );
      expect(
        const ClaudeWebFetchResultBlock(),
        isNot(
          const ClaudeWebFetchResultBlock(content: ClaudeWebFetchDocument()),
        ),
      );
      expect(
        const ClaudeWebSearchArguments(query: 'a').toString(),
        contains('query: a'),
      );
    });

    test('the open value types', () {
      expect(
        const ClaudeServerToolName('web_search'),
        ClaudeServerToolName.webSearch,
      );
      expect(ClaudeServerToolName.webSearch.toString(), 'web_search');
      expect(
        const ClaudeTextEditorCodeExecutionResultType('x'),
        isNot(ClaudeTextEditorCodeExecutionResultType.view),
      );
      expect(
        ClaudeCodeExecutionResultType.encrypted.value,
        'encrypted_code_execution_result',
      );
      expect(
        ClaudeToolSearchToolResultType.searchResult.hashCode,
        const ClaudeToolSearchToolResultType(
          'tool_search_tool_search_result',
        ).hashCode,
      );
    });
  });

  group('register.go', () {
    setUp(ensureClaudeAgenticTypesRegistered);

    test('registers the names of Go and is idempotent', () {
      ensureClaudeAgenticTypesRegistered();
      expect(
        TypeRegistry.nameOf(const ClaudeServerToolCallArguments()),
        '_eino_ext_claude_server_tool_call_arguments',
      );
      expect(
        TypeRegistry.nameOf(const ClaudeServerToolResult()),
        '_eino_ext_claude_server_tool_result',
      );
    });

    test('a checkpoint round trip keeps the typed values', () {
      final encoded = jsonDecode(
        jsonEncode(TypeRegistry.encode([_allArguments[0], _allResults[4]])),
      );
      final decoded = TypeRegistry.decode(encoded)! as List<Object?>;
      expect(decoded[0], _allArguments[0]);
      expect(decoded[1], _allResults[4]);
    });

    test('an agentic message with server tool blocks round trips', () {
      final message = AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(
            ServerToolCall(
              callId: 'srvtoolu_1',
              name: 'web_search',
              arguments: _allArguments[0],
            ),
          ),
          ContentBlock(
            ServerToolResult(
              callId: 'srvtoolu_1',
              name: 'web_search',
              content: _allResults[0],
            ),
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(message.toJson()));
      final back = AgenticMessage.fromJson(json as Map<String, Object?>);
      expect(back, message);
    });

    test('StreamConcat joins streamed arguments, last non-empty wins', () {
      final joined = StreamConcat.concatItems<Object>(const [
        ClaudeServerToolCallArguments(
          textEditorCodeExecution: ClaudeTextEditorCodeExecutionArguments(),
        ),
        ClaudeServerToolCallArguments(
          textEditorCodeExecution: ClaudeTextEditorCodeExecutionArguments(
            command: 'create',
            path: '/a',
          ),
        ),
        ClaudeServerToolCallArguments(
          textEditorCodeExecution: ClaudeTextEditorCodeExecutionArguments(
            fileText: 'body',
          ),
        ),
      ]);
      expect(
        joined,
        const ClaudeServerToolCallArguments(
          textEditorCodeExecution: ClaudeTextEditorCodeExecutionArguments(
            command: 'create',
            path: '/a',
            fileText: 'body',
          ),
        ),
      );
      expect(
        concatClaudeServerToolCallArguments(const [
          ClaudeServerToolCallArguments(webSearch: ClaudeWebSearchArguments()),
          ClaudeServerToolCallArguments(
            webSearch: ClaudeWebSearchArguments(query: 'q'),
          ),
        ]),
        const ClaudeServerToolCallArguments(
          webSearch: ClaudeWebSearchArguments(query: 'q'),
        ),
      );
    });
  });
}
