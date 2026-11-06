// Port of eino-ext components/model/agenticclaude/event_convertor_test.go.
// The Go tests unmarshal anthropic-sdk-go stream events; here the converter
// takes the decoded `data` of the events. All 8 Go tests are ported:
//   TestToMessageStreamingChunk, TestStreamingFunctionToolCallStartBlock,
//   TestStreamingServerToolCallStartBlock, TestToStreamingDeltaBlock,
//   TestStreamingServerToolCallDeltaBlock, TestAdditionalStreamingHelpers,
//   TestStreamingServerToolResultStartBlocks, TestStreamingCitationsDelta.
// Go's per-tool `toStreaming…CallDeltaBlock` helpers are one method here
// (`serverToolCallDelta`), driven by the tool name. Plus tests of the
// deliberate differences: empty server tool deltas give no chunk, result
// blocks keep their caller, tool search results are converted, and the
// chunks of a streamed server tool call can be joined.
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_consts.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_event_convertor.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_extension.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_register.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_utils.dart';
import 'package:threepio_core/threepio_core.dart';

ClaudeServerToolCallArguments _args(ContentBlock? block) =>
    block!.serverToolCall!.arguments! as ClaudeServerToolCallArguments;

Matcher _formatError(Object message) =>
    isA<ThreepioFormatException>().having((e) => e.message, 'message', message);

void main() {
  group('TestToMessageStreamingChunk', () {
    test('message start event', () {
      final chunk = ClaudeAgenticStreamConverter().convert({
        'type': 'message_start',
        'message': {
          'id': 'msg_1',
          'type': 'message',
          'role': 'assistant',
          'model': 'claude-sonnet-4-20250514',
          'content': [
            {'type': 'text', 'text': 'hello'},
          ],
          'usage': {'input_tokens': 3, 'output_tokens': 5},
        },
      });
      expect(chunk!.contentBlocks, hasLength(1));
      expect(chunk.contentBlocks[0].assistantGenText?.text, 'hello');
      expect(chunk.responseMeta?.claudeExtension?.id, 'msg_1');
      expect(chunk.responseMeta?.tokenUsage?.promptTokens, 3);
    });

    test('content block start thinking event', () {
      final c = ClaudeAgenticStreamConverter();
      final chunk = c.convert({
        'type': 'content_block_start',
        'index': 2,
        'content_block': {
          'type': 'thinking',
          'thinking': 'step 1',
          'signature': 'sig_1',
        },
      });
      expect(chunk!.contentBlocks, hasLength(1));
      expect(chunk.contentBlocks[0].reasoning?.text, 'step 1');
      expect(chunk.contentBlocks[0].reasoning?.signature, 'sig_1');
      expect(chunk.contentBlocks[0].streamingMeta?.index, 2);
      expect(c.blockKinds[2], ContentBlockType.reasoning);
    });

    test('content block delta text event', () {
      final chunk = ClaudeAgenticStreamConverter().convert({
        'type': 'content_block_delta',
        'index': 1,
        'delta': {'type': 'text_delta', 'text': 'hello delta'},
      });
      expect(chunk!.contentBlocks, hasLength(1));
      expect(chunk.contentBlocks[0].assistantGenText?.text, 'hello delta');
      expect(chunk.contentBlocks[0].streamingMeta?.index, 1);
    });

    test('message delta event', () {
      final chunk = ClaudeAgenticStreamConverter().convert({
        'type': 'message_delta',
        'usage': {
          'input_tokens': 3,
          'cache_read_input_tokens': 1,
          'output_tokens': 5,
        },
        'delta': {'stop_reason': 'end_turn', 'stop_sequence': 'done'},
      });
      expect(chunk!.responseMeta?.tokenUsage?.totalTokens, 9);
      expect(chunk.responseMeta?.claudeExtension?.stopReason, 'end_turn');
      expect(chunk.contentBlocks, isEmpty);
    });

    test('events that carry nothing', () {
      final c = ClaudeAgenticStreamConverter();
      expect(c.convert({'type': 'message_stop'}), isNull);
      expect(c.convert({'type': 'content_block_stop', 'index': 0}), isNull);
      expect(c.convert({'type': 'ping'}), isNull);
      expect(
        c.convert({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'redacted_thinking', 'data': 'x'},
        }),
        isNull,
      );
    });
  });

  test('TestStreamingFunctionToolCallStartBlock', () {
    final c = ClaudeAgenticStreamConverter();
    final block = c.startBlock(2, {
      'type': 'tool_use',
      'id': 'call_1',
      'name': 'get_weather',
      'input': {'location': 'beijing'},
    });
    expect(block?.functionToolCall?.callId, 'call_1');
    expect(block?.functionToolCall?.name, 'get_weather');
    expect(block?.functionToolCall?.arguments, '');
    expect(c.blockKinds[2], ContentBlockType.functionToolCall);
  });

  test('TestStreamingServerToolCallStartBlock', () {
    final c = ClaudeAgenticStreamConverter();
    final block = c.startBlock(3, {
      'type': 'server_tool_use',
      'id': 'call_1',
      'name': 'web_fetch',
      'input': {'url': 'https://example.com'},
    });
    expect(block?.serverToolCall, isNotNull);
    expect(block?.streamingMeta?.index, 3);
    expect(c.blockKinds[3], ContentBlockType.serverToolCall);
    expect(c.serverToolNames[3], ClaudeServerToolName.webFetch);
    expect(_args(block).webFetch?.url, 'https://example.com');
  });

  group('TestToStreamingDeltaBlock', () {
    test('server tool input json delta', () {
      final c = ClaudeAgenticStreamConverter();
      c.blockKinds[1] = ContentBlockType.serverToolCall;
      c.serverToolNames[1] = ClaudeServerToolName.toolSearchToolBm25;
      final block = c.deltaBlock(1, {
        'type': 'input_json_delta',
        'partial_json': '{"query":"find tools"}',
      });
      expect(_args(block).toolSearchToolBm25?.query, 'find tools');
      expect(block!.streamingMeta?.index, 1);
    });

    test('function tool input json delta', () {
      final c = ClaudeAgenticStreamConverter();
      c.blockKinds[2] = ContentBlockType.functionToolCall;
      final block = c.deltaBlock(2, {
        'type': 'input_json_delta',
        'partial_json': '{"name":"value"}',
      });
      expect(block?.functionToolCall?.arguments, '{"name":"value"}');
    });

    test('invalid server tool name', () {
      final c = ClaudeAgenticStreamConverter();
      c.blockKinds[4] = ContentBlockType.serverToolCall;
      expect(
        () => c.deltaBlock(4, {
          'type': 'input_json_delta',
          'partial_json': '{"query":"value"}',
        }),
        throwsA(_formatError(contains('invalid server tool name ""'))),
      );
    });

    test('thinking and signature deltas', () {
      final c = ClaudeAgenticStreamConverter();
      expect(
        c
            .deltaBlock(0, {'type': 'thinking_delta', 'thinking': 'hmm'})
            ?.reasoning
            ?.text,
        'hmm',
      );
      expect(
        c
            .deltaBlock(0, {'type': 'signature_delta', 'signature': 'sig'})
            ?.reasoning
            ?.signature,
        'sig',
      );
    });

    test('unknown delta type', () {
      expect(
        () => ClaudeAgenticStreamConverter().deltaBlock(0, {
          'type': 'compaction_delta',
        }),
        throwsA(_formatError('invalid stream delta type "compaction_delta"')),
      );
    });
  });

  group('TestStreamingServerToolCallDeltaBlock', () {
    ContentBlock? delta(ClaudeServerToolName name, String json, int index) {
      final c = ClaudeAgenticStreamConverter();
      c.blockKinds[index] = ContentBlockType.serverToolCall;
      c.serverToolNames[index] = name;
      return c.serverToolCallDelta(index, json, StreamingMeta(index: index));
    }

    test('tool search regex', () {
      final block = delta(
        ClaudeServerToolName.toolSearchToolRegex,
        '{"query":"find.*"}',
        5,
      );
      expect(_args(block).toolSearchToolRegex?.query, 'find.*');
      expect(block!.streamingMeta?.index, 5);
    });

    test('invalid json returns stable error', () {
      expect(
        () => delta(ClaudeServerToolName.codeExecution, '{"code":', 6),
        throwsA(
          _formatError(
            contains('failed to decode code_execution server tool arguments'),
          ),
        ),
      );
    });

    test('a field of the wrong type and a document that is not an object', () {
      expect(
        () => delta(ClaudeServerToolName.webSearch, '{"query":1}', 0),
        throwsA(
          _formatError(
            contains('failed to decode web_search server tool arguments'),
          ),
        ),
      );
      expect(
        () => delta(ClaudeServerToolName.webSearch, '[]', 0),
        throwsA(
          _formatError(
            'failed to decode web_search server tool arguments: expected an '
            'object, got []interface {}',
          ),
        ),
      );
      expect(
        _args(delta(ClaudeServerToolName.webSearch, 'null', 0)).webSearch,
        const ClaudeWebSearchArguments(),
      );
    });

    test('an empty delta gives no chunk (Go fails)', () {
      expect(delta(ClaudeServerToolName.webSearch, '', 0), isNull);
      expect(delta(ClaudeServerToolName.webSearch, '  ', 0), isNull);
    });
  });

  group('TestAdditionalStreamingHelpers', () {
    test('text start block', () {
      final c = ClaudeAgenticStreamConverter();
      final block = c.startBlock(0, {'type': 'text', 'text': 'hello'});
      expect(block?.assistantGenText?.text, 'hello');
      expect(c.blockKinds[0], ContentBlockType.assistantGenText);
    });

    ContentBlock? delta(ClaudeServerToolName name, String json, int index) {
      final c = ClaudeAgenticStreamConverter();
      c.blockKinds[index] = ContentBlockType.serverToolCall;
      c.serverToolNames[index] = name;
      return c.deltaBlock(index, {
        'type': 'input_json_delta',
        'partial_json': json,
      });
    }

    test('web search and web fetch delta blocks', () {
      expect(
        _args(
          delta(ClaudeServerToolName.webSearch, '{"query":"golang"}', 1),
        ).webSearch?.query,
        'golang',
      );
      expect(
        _args(
          delta(
            ClaudeServerToolName.webFetch,
            '{"url":"https://example.com"}',
            2,
          ),
        ).webFetch?.url,
        'https://example.com',
      );
    });

    test('bash and text editor delta blocks', () {
      expect(
        _args(
          delta(ClaudeServerToolName.bashCodeExecution, '{"command":"ls"}', 3),
        ).bashCodeExecution?.command,
        'ls',
      );
      expect(
        _args(
          delta(
            ClaudeServerToolName.textEditorCodeExecution,
            '{"command":"view","path":"/tmp/a.txt"}',
            4,
          ),
        ).textEditorCodeExecution,
        const ClaudeTextEditorCodeExecutionArguments(
          command: 'view',
          path: '/tmp/a.txt',
        ),
      );
    });
  });

  group('TestStreamingServerToolResultStartBlocks', () {
    ContentBlock? start(int index, Map<String, Object?> block) {
      final c = ClaudeAgenticStreamConverter();
      final result = c.startBlock(index, block);
      expect(c.blockKinds[index], ContentBlockType.serverToolResult);
      return result;
    }

    test('web search result start', () {
      final block = start(0, {
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
        'caller': {'type': 'direct'},
      });
      expect(block?.serverToolResult, isNotNull);
      expect(block?.streamingMeta?.index, 0);
      // Unlike Go, the caller stays with the block.
      expect(block?.extra, {
        claudeAgenticKeyOfWebSearchToolResultCaller: '{"type":"direct"}',
      });
    });

    test('web fetch result start', () {
      final block = start(1, {
        'type': 'web_fetch_tool_result',
        'tool_use_id': 'call_2',
        'content': {
          'type': 'web_fetch_tool_result_error',
          'error_code': 'fetch_failed',
        },
      });
      expect(block?.serverToolResult, isNotNull);
    });

    test('code execution result start', () {
      final block = start(2, {
        'type': 'code_execution_tool_result',
        'tool_use_id': 'call_3',
        'content': {
          'type': 'code_execution_result',
          'stdout': 'hi',
          'stderr': '',
          'return_code': 0,
          'content': <Object?>[],
        },
      });
      expect(block?.serverToolResult?.name, 'code_execution');
    });

    test('bash code execution result start', () {
      final block = start(3, {
        'type': 'bash_code_execution_tool_result',
        'tool_use_id': 'call_4',
        'content': {
          'type': 'bash_code_execution_result',
          'stdout': 'ok',
          'stderr': '',
          'return_code': 0,
          'content': <Object?>[],
        },
      });
      expect(block?.serverToolResult?.name, 'bash_code_execution');
    });

    test('text editor result start', () {
      final block = start(4, {
        'type': 'text_editor_code_execution_tool_result',
        'tool_use_id': 'call_5',
        'content': {
          'type': 'text_editor_code_execution_view_result',
          'file_type': 'go',
          'content': 'pkg',
          'num_lines': 1,
          'start_line': 1,
          'total_lines': 1,
        },
      });
      expect(block?.serverToolResult?.name, 'text_editor_code_execution');
      expect(block?.streamingMeta?.index, 4);
    });

    test('tool search result start (Go drops it)', () {
      final c = ClaudeAgenticStreamConverter()
        ..startBlock(0, {
          'type': 'server_tool_use',
          'id': 'srvtoolu_1',
          'name': 'tool_search_tool_bm25',
          'input': <String, Object?>{},
        });
      final block = c.startBlock(1, {
        'type': 'tool_search_tool_result',
        'tool_use_id': 'srvtoolu_1',
        'content': {
          'type': 'tool_search_tool_search_result',
          'tool_references': [
            {'type': 'tool_reference', 'tool_name': 'get_weather'},
          ],
        },
      });
      expect(block?.serverToolResult?.name, 'tool_search_tool_bm25');
      expect(block?.streamingMeta?.index, 1);
    });
  });

  test('TestStreamingCitationsDelta', () {
    final chunk = ClaudeAgenticStreamConverter().convert({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {
        'type': 'citations_delta',
        'citation': {
          'type': 'char_location',
          'cited_text': 'hello',
          'document_title': 'doc',
          'document_index': 0,
          'start_char_index': 0,
          'end_char_index': 5,
        },
      },
    });
    expect(chunk!.contentBlocks, hasLength(1));
    final ext = chunk.contentBlocks[0].assistantGenText?.claudeExtension;
    expect(ext?.citations.single.charLocation?.citedText, 'hello');
    expect(chunk.contentBlocks[0].assistantGenText?.text, '');

    expect(
      ClaudeAgenticStreamConverter().convert({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {
          'type': 'citations_delta',
          'citation': {'type': 'search_result_location'},
        },
      }),
      isNull,
    );
  });

  test('the chunks of a streamed server tool call join (Go fails)', () {
    ensureClaudeAgenticTypesRegistered();
    final c = ClaudeAgenticStreamConverter();
    final chunks = [
      c.convert({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'server_tool_use',
          'id': 'srvtoolu_1',
          'name': 'web_search',
          'input': <String, Object?>{},
        },
      })!,
      c.convert({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': ''},
      }),
      c.convert({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {
          'type': 'input_json_delta',
          'partial_json': '{"query":"dart 3.9"}',
        },
      })!,
    ].whereType<AgenticMessage>().toList();
    expect(chunks, hasLength(2));
    final joined = concatAgenticMessages(chunks);
    final call = joined.contentBlocks.single.serverToolCall!;
    expect(call.callId, 'srvtoolu_1');
    expect(call.name, 'web_search');
    expect(
      call.arguments,
      const ClaudeServerToolCallArguments(
        webSearch: ClaudeWebSearchArguments(query: 'dart 3.9'),
      ),
    );
  });
}
