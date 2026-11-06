// Port of eino `schema/agentic_message_test.go` (v0.9.22), plus tests of
// the Dart-only parts (concat edge cases, registrations).
//
// Go tests that cannot be ported literally:
// * TestConcatAgenticMessages/"nil message in stream": a `List<AgenticMessage>`
//   cannot hold null, so there is no nil message to report.
// * TestAgenticMessageString/"nil/empty fields" keeps every case but the nil
//   block in the slice (impossible, as above); "nil content struct in block"
//   (a block whose payload pointer is nil) is impossible with the sealed
//   payload type and is replaced by blocks with zero-valued payloads.
// * TestNewContentBlock iterates over the fields of Go's ContentBlock with
//   reflection; here it iterates over one payload of every variant and checks
//   the typed getter and the type, which is what the Go test checks.
// * TestNewContentBlockChunk_NilMeta: `ContentBlock(x)` without a streaming
//   meta is the nil-meta chunk.
// * TestConcatAssistantGenTexts_ExtensionOverwrite calls the unexported Go
//   function; here the same chunks go through concatAgenticMessages. Go's
//   ConcatSliceValue cannot join two `*testExtension` values (the Go test
//   skips then); neither can StreamConcat without a registered function, and
//   with one the joined value is stored (Go stores a reflect.Value, the bug
//   the Go test logs).
// * TestFunctionToolResultBlockString: "empty type" and "unknown type value"
//   are impossible (the type follows from the sealed content); "known type
//   but empty payload" becomes a zero-valued payload. The unknown-type texts
//   are checked as fromJson format errors in agentic_json_test.dart.
// * TestConcatFunctionToolResults calls the unexported Go function; the same
//   chunks go through concatAgenticMessages.

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

const _assistant = AgenticRoleType.assistant;
const _user = AgenticRoleType.user;

AgenticMessage _msg(AgenticRoleType role, List<ContentBlock> blocks) =>
    AgenticMessage(role: role, contentBlocks: blocks);

ContentBlock _chunk(ContentBlockVariant content, [int index = 0]) =>
    ContentBlock(content, streamingMeta: StreamingMeta(index: index));

Matcher _concatError(String text) => throwsA(
      isA<MessageConcatException>()
          .having((e) => e.message, 'message', contains(text)),
    );

@immutable
final class _TestExtension {
  const _TestExtension(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is _TestExtension && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

void main() {
  group('TestConcatAgenticMessages', () {
    test('single message', () {
      final msg = _msg(_assistant, [
        ContentBlock(const AssistantGenText(text: 'Hello')),
      ]);
      final result = concatAgenticMessages([msg]);
      expect(result, same(msg));
    });

    test('different roles', () {
      expect(
        () => concatAgenticMessages([
          AgenticMessage(role: _user),
          AgenticMessage(role: _assistant),
        ]),
        _concatError('cannot concat messages with different roles'),
      );
    });

    test('concat text blocks', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'Hello '))]),
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'World!'))]),
      ]);
      expect(result.role, _assistant);
      expect(result.contentBlocks, hasLength(1));
      expect(result.contentBlocks[0].assistantGenText!.text, 'Hello World!');
    });

    test('concat reasoning with nil index', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [_chunk(const Reasoning(text: 'First '))]),
        _msg(_assistant, [_chunk(const Reasoning(text: 'Second'))]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(result.contentBlocks[0].reasoning!.text, 'First Second');
    });

    test('concat reasoning with index', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [_chunk(const Reasoning(text: 'Part1-'))]),
        _msg(_assistant, [_chunk(const Reasoning(text: 'Part3'))]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(result.contentBlocks[0].reasoning!.text, 'Part1-Part3');
    });

    test('concat user input text', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'Hello '))]),
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'World!'))]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(result.contentBlocks[0].assistantGenText!.text, 'Hello World!');
    });

    test('concat assistant gen image', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [_chunk(const AssistantGenImage(base64Data: '1'))]),
        _msg(_assistant, [_chunk(const AssistantGenImage(base64Data: '2'))]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(result.contentBlocks[0].assistantGenImage!.base64Data, '12');
    });

    test('concat user input audio - should error', () {
      expect(
        () => concatAgenticMessages([
          _msg(_user, [
            _chunk(const UserInputAudio(url: 'https://example.com/audio1.mp3')),
          ]),
          _msg(_user, [
            _chunk(const UserInputAudio(url: 'https://example.com/audio2.mp3')),
          ]),
        ]),
        _concatError('cannot concat multiple user input audios'),
      );
    });

    test('concat user input video - should error', () {
      expect(
        () => concatAgenticMessages([
          _msg(_user, [
            _chunk(const UserInputVideo(url: 'https://example.com/video1.mp4')),
          ]),
          _msg(_user, [
            _chunk(const UserInputVideo(url: 'https://example.com/video2.mp4')),
          ]),
        ]),
        _concatError('cannot concat multiple user input videos'),
      );
    });

    test('concat assistant gen text', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'Generated '))]),
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'Text'))]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(result.contentBlocks[0].assistantGenText!.text, 'Generated Text');
    });

    test('concat assistant gen image (parts)', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const AssistantGenImage(base64Data: 'part1')),
        ]),
        _msg(_assistant, [
          _chunk(const AssistantGenImage(base64Data: 'part2')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(
        result.contentBlocks[0].assistantGenImage!.base64Data,
        'part1part2',
      );
    });

    test('concat assistant gen audio', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const AssistantGenAudio(base64Data: 'audio1')),
        ]),
        _msg(_assistant, [
          _chunk(const AssistantGenAudio(base64Data: 'audio2')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(
        result.contentBlocks[0].assistantGenAudio!.base64Data,
        'audio1audio2',
      );
    });

    test('concat assistant gen video', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const AssistantGenVideo(base64Data: 'video1')),
        ]),
        _msg(_assistant, [
          _chunk(const AssistantGenVideo(base64Data: 'video2')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      expect(
        result.contentBlocks[0].assistantGenVideo!.base64Data,
        'video1video2',
      );
    });

    test('concat function tool call', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            const FunctionToolCall(
              callId: 'call_123',
              name: 'get_weather',
              arguments: '{"location',
            ),
          ),
        ]),
        _msg(_assistant, [
          _chunk(const FunctionToolCall(arguments: '":"NYC"}')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final call = result.contentBlocks[0].functionToolCall!;
      expect(call.callId, 'call_123');
      expect(call.name, 'get_weather');
      expect(call.arguments, '{"location":"NYC"}');
    });

    test('concat function tool result', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            FunctionToolResult(
              callId: 'call_123',
              name: 'get_weather',
              content: [
                FunctionToolResultContentBlock(
                  const UserInputText(text: '{"temp'),
                ),
              ],
            ),
          ),
        ]),
        _msg(_assistant, [
          _chunk(
            FunctionToolResult(
              content: [
                FunctionToolResultContentBlock(
                  const UserInputText(text: '":72}'),
                ),
              ],
            ),
          ),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final toolResult = result.contentBlocks[0].functionToolResult!;
      expect(toolResult.callId, 'call_123');
      expect(toolResult.name, 'get_weather');
      expect(toolResult.content, hasLength(2));
      expect((toolResult.content[0].content as UserInputText).text, '{"temp');
      expect((toolResult.content[1].content as UserInputText).text, '":72}');
    });

    test('concat server tool call', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            const ServerToolCall(callId: 'server_call_1', name: 'server_func'),
          ),
        ]),
        _msg(_assistant, [
          _chunk(const ServerToolCall(arguments: {'key': 'value'})),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final call = result.contentBlocks[0].serverToolCall!;
      expect(call.callId, 'server_call_1');
      expect(call.name, 'server_func');
      expect(call.arguments, isNotNull);
      expect(call.arguments, {'key': 'value'});
    });

    test('concat server tool result', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            const ServerToolResult(
              callId: 'server_call_1',
              name: 'server_func',
              content: 'result1',
            ),
          ),
        ]),
        _msg(_assistant, [_chunk(const ServerToolResult())]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final toolResult = result.contentBlocks[0].serverToolResult!;
      expect(toolResult.callId, 'server_call_1');
      expect(toolResult.name, 'server_func');
      expect(toolResult.content, 'result1');
    });

    test('concat mcp tool call', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            const AgenticMcpToolCall(
              serverLabel: 'mcp-server',
              callId: 'mcp_call_1',
              name: 'mcp_func',
              arguments: '{"arg',
            ),
          ),
        ]),
        _msg(_assistant, [
          _chunk(const AgenticMcpToolCall(arguments: '":123}')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final call = result.contentBlocks[0].mcpToolCall!;
      expect(call.serverLabel, 'mcp-server');
      expect(call.callId, 'mcp_call_1');
      expect(call.name, 'mcp_func');
      expect(call.arguments, '{"arg":123}');
    });

    test('concat mcp tool result', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            const AgenticMcpToolResult(
              serverLabel: 'mcp-server',
              callId: 'mcp_call_1',
              name: 'mcp_func',
              content: 'First',
            ),
          ),
        ]),
        _msg(_assistant, [
          _chunk(const AgenticMcpToolResult(content: 'Second')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final toolResult = result.contentBlocks[0].mcpToolResult!;
      expect(toolResult.serverLabel, 'mcp-server');
      expect(toolResult.callId, 'mcp_call_1');
      expect(toolResult.name, 'mcp_func');
      expect(toolResult.content, 'Second');
    });

    test('concat mcp list tools', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            AgenticMcpListToolsResult(
              serverLabel: 'mcp-server',
              tools: [AgenticMcpListToolsItem(name: 'tool1')],
            ),
          ),
        ]),
        _msg(_assistant, [
          _chunk(
            AgenticMcpListToolsResult(
              tools: [AgenticMcpListToolsItem(name: 'tool2')],
            ),
          ),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final list = result.contentBlocks[0].mcpListToolsResult!;
      expect(list.serverLabel, 'mcp-server');
      expect(list.tools, hasLength(2));
    });

    test('concat mcp tool approval request', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            const AgenticMcpToolApprovalRequest(
              id: 'approval_1',
              name: 'approval_func',
              serverLabel: 'mcp-server',
              arguments: '{"request',
            ),
          ),
        ]),
        _msg(_assistant, [
          _chunk(const AgenticMcpToolApprovalRequest(arguments: '":1}')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final request = result.contentBlocks[0].mcpToolApprovalRequest!;
      expect(request.id, 'approval_1');
      expect(request.name, 'approval_func');
      expect(request.serverLabel, 'mcp-server');
      expect(request.arguments, '{"request":1}');
    });

    test('concat mcp tool approval response - should error', () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [
            _chunk(
              const AgenticMcpToolApprovalResponse(
                approvalRequestId: 'approval_1',
              ),
            ),
          ]),
          _msg(_assistant, [
            _chunk(
              const AgenticMcpToolApprovalResponse(
                approvalRequestId: 'approval_1',
                approve: true,
              ),
            ),
          ]),
        ]),
        _concatError('cannot concat multiple mcp tool approval responses'),
      );
    });

    test('concat response meta', () {
      final result = concatAgenticMessages([
        AgenticMessage(
          role: _assistant,
          responseMeta: const AgenticResponseMeta(
            tokenUsage: TokenUsage(
              promptTokens: 10,
              completionTokens: 5,
              promptTokenDetails: PromptTokenDetails(
                cachedTokens: 3,
                cacheWriteTokens: 7,
              ),
              completionTokenDetails: CompletionTokenDetails(
                reasoningTokens: 2,
              ),
              totalTokens: 15,
            ),
          ),
        ),
        AgenticMessage(
          role: _assistant,
          responseMeta: const AgenticResponseMeta(
            tokenUsage: TokenUsage(
              promptTokens: 8,
              completionTokens: 15,
              promptTokenDetails: PromptTokenDetails(
                cachedTokens: 5,
                cacheWriteTokens: 4,
              ),
              completionTokenDetails: CompletionTokenDetails(
                reasoningTokens: 4,
              ),
              totalTokens: 23,
            ),
          ),
        ),
      ]);
      final usage = result.responseMeta!.tokenUsage!;
      expect(usage.completionTokens, 15);
      expect(usage.promptTokens, 10);
      expect(usage.totalTokens, 23);
      expect(usage.promptTokenDetails!.cachedTokens, 5);
      expect(usage.promptTokenDetails!.cacheWriteTokens, 7);
      expect(usage.completionTokenDetails!.reasoningTokens, 4);
    });

    test('mixed streaming and non-streaming blocks error', () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [_chunk(const AssistantGenText(text: 'Hello'))]),
          _msg(_assistant, [ContentBlock(const AssistantGenText(text: 'World'))]),
        ]),
        _concatError('found non-streaming block after streaming blocks'),
      );
    });

    test('concat MCP tool call', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            const AgenticMcpToolCall(
              serverLabel: 'mcp-server',
              callId: 'call_456',
              name: 'list_files',
              arguments: '{"path',
            ),
          ),
        ]),
        _msg(_assistant, [
          _chunk(const AgenticMcpToolCall(arguments: '":"/tmp"}')),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(1));
      final call = result.contentBlocks[0].mcpToolCall!;
      expect(call.serverLabel, 'mcp-server');
      expect(call.callId, 'call_456');
      expect(call.arguments, '{"path":"/tmp"}');
    });

    test('concat user input text - should error', () {
      expect(
        () => concatAgenticMessages([
          _msg(_user, [_chunk(const UserInputText(text: 'What is '))]),
          _msg(_user, [_chunk(const UserInputText(text: 'the weather?'))]),
        ]),
        _concatError('cannot concat multiple user input texts'),
      );
    });

    test('multiple stream indexes - sparse indexes', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const AssistantGenText(text: 'Index0-')),
          _chunk(const AssistantGenText(text: 'Index2-'), 2),
        ]),
        _msg(_assistant, [
          _chunk(const AssistantGenText(text: 'Part2')),
          _chunk(const AssistantGenText(text: 'Part2'), 2),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(2));
      expect(result.contentBlocks[0].assistantGenText!.text, 'Index0-Part2');
      expect(result.contentBlocks[1].assistantGenText!.text, 'Index2-Part2');
    });

    test('multiple stream indexes - mixed content types', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const AssistantGenText(text: 'Text ')),
          _chunk(
            const FunctionToolCall(
              callId: 'call_1',
              name: 'func1',
              arguments: '{"a',
            ),
            1,
          ),
        ]),
        _msg(_assistant, [
          _chunk(const AssistantGenText(text: 'Content')),
          _chunk(const FunctionToolCall(arguments: '":1}'), 1),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(2));
      expect(result.contentBlocks[0].assistantGenText!.text, 'Text Content');
      final call = result.contentBlocks[1].functionToolCall!;
      expect(call.callId, 'call_1');
      expect(call.name, 'func1');
      expect(call.arguments, '{"a":1}');
    });

    test('multiple stream indexes - three indexes', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const AssistantGenText(text: 'A')),
          _chunk(const AssistantGenText(text: 'B'), 1),
          _chunk(const AssistantGenText(text: 'C'), 2),
        ]),
        _msg(_assistant, [
          _chunk(const AssistantGenText(text: '1')),
          _chunk(const AssistantGenText(text: '2'), 1),
          _chunk(const AssistantGenText(text: '3'), 2),
        ]),
      ]);
      expect(result.contentBlocks, hasLength(3));
      expect(result.contentBlocks[0].assistantGenText!.text, 'A1');
      expect(result.contentBlocks[1].assistantGenText!.text, 'B2');
      expect(result.contentBlocks[2].assistantGenText!.text, 'C3');
    });
  });

  group('concatAgenticMessages beyond the Go tests', () {
    test('an empty list is an argument error', () {
      expect(() => concatAgenticMessages([]), throwsArgumentError);
    });

    test('non-streaming blocks are kept in order, without joining', () {
      final a = ContentBlock(const AssistantGenText(text: 'a'));
      final b = ContentBlock(const AssistantGenText(text: 'b'));
      final c = ContentBlock(const Reasoning(text: 'c'));
      final result = concatAgenticMessages([
        _msg(_assistant, [a, b]),
        _msg(_assistant, [c]),
      ]);
      expect(result.contentBlocks, [a, b, c]);
    });

    test('a streaming block after non-streaming ones throws', () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [ContentBlock(const AssistantGenText(text: 'a'))]),
          _msg(_assistant, [_chunk(const AssistantGenText(text: 'b'))]),
        ]),
        _concatError('found streaming block after non-streaming blocks'),
      );
    });

    test('joined blocks lose their streaming meta, out-of-order indexes sort',
        () {
      final result = concatAgenticMessages([
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'x'), 5)]),
        _msg(_assistant, [_chunk(const Reasoning(text: 'r'), 1)]),
      ]);
      expect(result.contentBlocks, [
        ContentBlock(const Reasoning(text: 'r')),
        ContentBlock(const AssistantGenText(text: 'x')),
      ]);
    });

    test('chunks of one index must have one type', () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [_chunk(const AssistantGenText(text: 'a'))]),
          _msg(_assistant, [_chunk(const Reasoning(text: 'b'))]),
        ]),
        _concatError(
          "content block type mismatch: expected 'assistant_gen_text', "
          "but got 'reasoning'",
        ),
      );
    });

    test('conflicting call ids name the block type', () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [_chunk(const FunctionToolCall(callId: 'a'))]),
          _msg(_assistant, [_chunk(const FunctionToolCall(callId: 'b'))]),
        ]),
        _concatError(
          "failed to concat 'function_tool_call' content blocks: expected "
          "call ID 'a' for function tool call, but got 'b'",
        ),
      );
    });

    test('generated media URLs and MIME types must agree', () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [_chunk(const AssistantGenImage(url: 'a'))]),
          _msg(_assistant, [_chunk(const AssistantGenImage(url: 'b'))]),
        ]),
        _concatError('inconsistent URLs in assistant generated image chunks'),
      );
      final ok = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const AssistantGenAudio(mimeType: 'audio/wav')),
        ]),
        _msg(_assistant, [
          _chunk(const AssistantGenAudio(base64Data: 'x', url: 'u')),
        ]),
      ]);
      expect(
        ok.contentBlocks.single.assistantGenAudio,
        const AssistantGenAudio(url: 'u', base64Data: 'x', mimeType: 'audio/wav'),
      );
    });

    test('block extras and message extras are merged', () {
      final result = concatAgenticMessages([
        AgenticMessage(
          role: _assistant,
          contentBlocks: [
            ContentBlock(
              const AssistantGenText(text: 'a'),
              streamingMeta: const StreamingMeta(index: 0),
              extra: const {'s': 'x', 'n': 1},
            ),
          ],
          extra: const {'id': 'r', 'nested': {'a': 'b'}},
        ),
        AgenticMessage(
          role: _assistant,
          contentBlocks: [
            ContentBlock(
              const AssistantGenText(text: 'b'),
              streamingMeta: const StreamingMeta(index: 0),
              extra: const {'s': 'y', 'n': 2},
            ),
          ],
          extra: const {'id': '1', 'nested': {'a': 'c'}},
        ),
      ]);
      expect(result.contentBlocks.single.extra, {'s': 'xy', 'n': 2});
      expect(result.extra, {
        'id': 'r1',
        'nested': {'a': 'bc'},
      });
    });

    test('two non-empty lists under one extra key cannot be joined (Go)', () {
      expect(
        () => concatAgenticMessages([
          AgenticMessage(role: _assistant, extra: const {'l': [1]}),
          AgenticMessage(role: _assistant, extra: const {'l': [2]}),
        ]),
        throwsA(isA<MessageConcatException>()),
      );
    });

    test('an empty extra map is kept (Go keeps a non-nil map)', () {
      final result = concatAgenticMessages([
        AgenticMessage(role: _assistant, extra: const {}),
        AgenticMessage(role: _assistant),
      ]);
      expect(result.extra, isEmpty);
    });

    test('extensions of different providers in one block are inconsistent',
        () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [
            _chunk(
              AssistantGenText(
                openAIExtension: OpenAIAssistantGenTextExtension(),
              ),
            ),
          ]),
          _msg(_assistant, [
            _chunk(
              AssistantGenText(
                claudeExtension: ClaudeAssistantGenTextExtension(),
              ),
            ),
          ]),
        ]),
        _concatError('inconsistent extension types in assistant generated'),
      );
    });

    test('OpenAI and Claude text extensions are joined', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            AssistantGenText(
              text: 'a',
              openAIExtension: OpenAIAssistantGenTextExtension(
                annotations: const [
                  OpenAITextAnnotation(
                    index: 1,
                    type: OpenAITextAnnotationType.filePath,
                  ),
                ],
              ),
            ),
          ),
          _chunk(
            AssistantGenText(
              claudeExtension: ClaudeAssistantGenTextExtension(
                citations: const [
                  ClaudeTextCitation(
                    type: ClaudeTextCitationType.charLocation,
                  ),
                ],
              ),
            ),
            1,
          ),
        ]),
        _msg(_assistant, [
          _chunk(
            AssistantGenText(
              text: 'b',
              openAIExtension: OpenAIAssistantGenTextExtension(
                annotations: const [
                  OpenAITextAnnotation(
                    type: OpenAITextAnnotationType.urlCitation,
                  ),
                ],
              ),
            ),
          ),
          _chunk(
            AssistantGenText(
              claudeExtension: ClaudeAssistantGenTextExtension(
                citations: const [
                  ClaudeTextCitation(
                    type: ClaudeTextCitationType.pageLocation,
                  ),
                ],
              ),
            ),
            1,
          ),
        ]),
      ]);
      final openAI = result.contentBlocks[0].assistantGenText!;
      expect(openAI.text, 'ab');
      expect(
        openAI.openAIExtension!.annotations.map((a) => a.type),
        [OpenAITextAnnotationType.urlCitation, OpenAITextAnnotationType.filePath],
      );
      expect(openAI.openAIExtension!.annotations.map((a) => a.index), [0, 0]);
      expect(
        result.contentBlocks[1].assistantGenText!.claudeExtension!.citations
            .map((c) => c.type),
        [ClaudeTextCitationType.charLocation, ClaudeTextCitationType.pageLocation],
      );
    });

    test('a single reasoning chunk is rebuilt (indexes cleared), as in Go',
        () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(
            Reasoning(
              text: 't',
              signature: 's',
              openAIExtension: OpenAIReasoningExtension(
                content: const [OpenAIReasoningContent(index: 3, text: 'x')],
              ),
            ),
          ),
        ]),
        AgenticMessage(role: _assistant),
      ]);
      expect(
        result.contentBlocks.single.reasoning,
        Reasoning(
          text: 't',
          signature: 's',
          openAIExtension: OpenAIReasoningExtension(
            content: const [OpenAIReasoningContent(text: 'x')],
          ),
        ),
      );
    });

    test('server tool arguments of different types are inconsistent', () {
      expect(
        () => concatAgenticMessages([
          _msg(_assistant, [_chunk(const ServerToolCall(arguments: 'a'))]),
          _msg(_assistant, [_chunk(const ServerToolCall(arguments: 1))]),
        ]),
        _concatError('for server tool call arguments'),
      );
    });

    test('server tool arguments are joined by StreamConcat', () {
      final result = concatAgenticMessages([
        _msg(_assistant, [
          _chunk(const ServerToolCall(name: 'search', arguments: '{"q":')),
        ]),
        _msg(_assistant, [_chunk(const ServerToolCall(arguments: '"x"}'))]),
        _msg(_assistant, [
          _chunk(const ServerToolResult(content: {'a': 'b'}), 1),
        ]),
        _msg(_assistant, [
          _chunk(const ServerToolResult(content: <String, Object?>{'c': 1}), 1),
        ]),
      ]);
      expect(result.contentBlocks[0].serverToolCall!.arguments, '{"q":"x"}');
      expect(result.contentBlocks[1].serverToolResult!.content, {
        'a': 'b',
        'c': 1,
      });
    });

    test('response meta extensions and other extensions', () {
      final result = concatAgenticMessages([
        AgenticMessage(
          role: _assistant,
          responseMeta: const AgenticResponseMeta(
            openAIExtension: OpenAIResponseMetaExtension(id: 'resp'),
          ),
        ),
        AgenticMessage(
          role: _assistant,
          responseMeta: const AgenticResponseMeta(
            openAIExtension: OpenAIResponseMetaExtension(
              status: OpenAIResponseStatus.completed,
            ),
          ),
        ),
      ]);
      expect(
        result.responseMeta,
        const AgenticResponseMeta(
          openAIExtension: OpenAIResponseMetaExtension(
            id: 'resp',
            status: OpenAIResponseStatus.completed,
          ),
        ),
      );

      expect(
        () => concatAgenticMessages([
          AgenticMessage(
            role: _assistant,
            responseMeta: const AgenticResponseMeta(
              claudeExtension: ClaudeResponseMetaExtension(id: 'a'),
            ),
          ),
          AgenticMessage(
            role: _assistant,
            responseMeta: const AgenticResponseMeta(
              geminiExtension: GeminiResponseMetaExtension(id: 'b'),
            ),
          ),
        ]),
        _concatError(
          'failed to concat agentic response meta: inconsistent extension '
          'types in response meta chunks',
        ),
      );

      final other = concatAgenticMessages([
        AgenticMessage(
          role: _assistant,
          responseMeta: const AgenticResponseMeta(extension: 'ab'),
        ),
        AgenticMessage(
          role: _assistant,
          responseMeta: const AgenticResponseMeta(extension: 'cd'),
        ),
      ]);
      expect(other.responseMeta!.extension, 'abcd');
    });

    test('concatAgenticMessagesArray joins position by position', () {
      final result = concatAgenticMessagesArray([
        [
          _msg(_assistant, [_chunk(const AssistantGenText(text: 'a'))]),
          _msg(_user, [ContentBlock(const UserInputText(text: 'u'))]),
        ],
        [
          _msg(_assistant, [_chunk(const AssistantGenText(text: 'b'))]),
          AgenticMessage(role: _user),
        ],
      ]);
      expect(result, hasLength(2));
      expect(result[0].contentBlocks.single.assistantGenText!.text, 'ab');
      expect(result[1].contentBlocks.single.userInputText!.text, 'u');
      expect(concatAgenticMessagesArray([]), isEmpty);
      expect(
        () => concatAgenticMessagesArray([
          [AgenticMessage.user('a')],
          <AgenticMessage>[],
        ]),
        _concatError('unexpected array length. Got 0, expected 1'),
      );
    });

    test('StreamConcat built-ins for AgenticMessage and its list', () {
      final chunks = [
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'x'))]),
        _msg(_assistant, [_chunk(const AssistantGenText(text: 'y'))]),
      ];
      expect(
        StreamConcat.concatItems<AgenticMessage>(chunks)
            .contentBlocks
            .single
            .assistantGenText!
            .text,
        'xy',
      );
      expect(StreamConcat.resolve<AgenticMessage>(), isNotNull);
      final lists = StreamConcat.concatItems<List<AgenticMessage>>([
        [chunks[0]],
        [chunks[1]],
      ]);
      expect(lists.single.contentBlocks.single.assistantGenText!.text, 'xy');
      expect(StreamConcat.resolve<List<AgenticMessage>>(), isNotNull);
      // Found by value too, for channels declared as Object.
      final Object joined = StreamConcat.concatItems<Object>(chunks);
      expect(joined, isA<AgenticMessage>());
    });
  });

  group('TestAgenticMessageFormat', () {
    test('formats the user input fields', () async {
      final m = AgenticMessage(
        role: _user,
        contentBlocks: [
          ContentBlock(const UserInputText(text: '{a}')),
          ContentBlock(const UserInputImage(url: '{b}', base64Data: '{c}')),
          ContentBlock(const UserInputAudio(url: '{d}', base64Data: '{e}')),
          ContentBlock(const UserInputVideo(url: '{f}', base64Data: '{g}')),
          ContentBlock(const UserInputFile(url: '{h}', base64Data: '{i}')),
        ],
      );

      final result = await m.format(
        RunContext.background(),
        {
          'a': '1',
          'b': '2',
          'c': '3',
          'd': '4',
          'e': '5',
          'f': '6',
          'g': '7',
          'h': '8',
          'i': '9',
        },
        FormatType.fString,
      );
      expect(result, [
        AgenticMessage(
          role: _user,
          contentBlocks: [
            ContentBlock(const UserInputText(text: '1')),
            ContentBlock(const UserInputImage(url: '2', base64Data: '3')),
            ContentBlock(const UserInputAudio(url: '4', base64Data: '5')),
            ContentBlock(const UserInputVideo(url: '6', base64Data: '7')),
            ContentBlock(const UserInputFile(url: '8', base64Data: '9')),
          ],
        ),
      ]);
    });

    test('file ids and names are formatted; other blocks, meta and extra '
        'are kept', () async {
      final m = AgenticMessage(
        role: _user,
        contentBlocks: [
          ContentBlock(
            const UserInputFile(
              name: '{n}.txt',
              fileId: 'file-{id}',
              mimeType: '{keep}',
            ),
            streamingMeta: const StreamingMeta(index: 2),
            extra: const {'k': '{keep}'},
          ),
          ContentBlock(const UserInputImage(fileId: '{id}')),
          ContentBlock(const AssistantGenText(text: '{keep}')),
          ContentBlock(const FunctionToolCall(arguments: '{keep}')),
        ],
        responseMeta: const AgenticResponseMeta(extension: '{keep}'),
        extra: const {'x': '{keep}'},
      );
      final result = await m.format(
        RunContext.background(),
        {'n': 'notes', 'id': '42'},
        FormatType.fString,
      );
      expect(result.single.contentBlocks, [
        ContentBlock(
          const UserInputFile(
            name: 'notes.txt',
            fileId: 'file-42',
            mimeType: '{keep}',
          ),
          streamingMeta: const StreamingMeta(index: 2),
          extra: const {'k': '{keep}'},
        ),
        ContentBlock(const UserInputImage(fileId: '42')),
        ContentBlock(const AssistantGenText(text: '{keep}')),
        ContentBlock(const FunctionToolCall(arguments: '{keep}')),
      ]);
      expect(result.single.responseMeta, m.responseMeta);
      expect(result.single.extra, m.extra);
    });

    test('jinja2, missing variables and Go templates', () async {
      final m = AgenticMessage.user('hi {{ name }}');
      final jinja = await m.format(
        RunContext.background(),
        {'name': 'eino'},
        FormatType.jinja2,
      );
      expect(jinja.single.contentBlocks.single.userInputText!.text, 'hi eino');

      await expectLater(
        AgenticMessage.user('{missing}').format(
          RunContext.background(),
          {},
          FormatType.fString,
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        m.format(RunContext.background(), {}, FormatType.goTemplate),
        throwsUnsupportedError,
      );
    });
  });

  group('TestAgenticPlaceholderFormat', () {
    test('renders the messages under its key', () async {
      final ctx = RunContext.background();
      var ph = const AgenticMessagesPlaceholder('a');

      var result = await ph.format(
        ctx,
        {
          'a': [AgenticMessage(role: _user), AgenticMessage(role: _user)],
        },
        FormatType.fString,
      );
      expect(result, hasLength(2));

      ph = const AgenticMessagesPlaceholder('a', optional: true);
      result = await ph.format(ctx, {}, FormatType.fString);
      expect(result, isEmpty);
    });

    test('a missing required key or a wrong value is a format error', () async {
      final ctx = RunContext.background();
      await expectLater(
        const AgenticMessagesPlaceholder('a').format(ctx, {}, FormatType.fString),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'message placeholder format: a not found',
          ),
        ),
      );
      await expectLater(
        const AgenticMessagesPlaceholder('a').format(
          ctx,
          {
            'a': [Message.user('classic')],
          },
          FormatType.fString,
        ),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            startsWith(
              'only agentic messages can be used to format message '
              'placeholder, key: a',
            ),
          ),
        ),
      );
      final untyped = await const AgenticMessagesPlaceholder('a').format(
        ctx,
        {
          'a': <Object?>[AgenticMessage.user('x')],
        },
        FormatType.fString,
      );
      expect(untyped, [AgenticMessage.user('x')]);
    });

    test('value equality', () {
      expect(
        const AgenticMessagesPlaceholder('a', optional: true),
        const AgenticMessagesPlaceholder('a', optional: true),
      );
      expect(
        const AgenticMessagesPlaceholder('a'),
        isNot(const AgenticMessagesPlaceholder('a', optional: true)),
      );
    });
  });

  group('TestAgenticMessageString', () {
    test('every block type', () {
      const longBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE'
          'QVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

      final msg = AgenticMessage(
        role: _assistant,
        contentBlocks: [
          ContentBlock(
            const UserInputText(
              text: "What's the weather like in New York City today?",
            ),
          ),
          ContentBlock(
            const UserInputImage(
              url: 'https://example.com/weather-map.jpg',
              base64Data: longBase64,
              mimeType: 'image/jpeg',
              detail: ImageURLDetail.high,
            ),
          ),
          ContentBlock(
            const UserInputAudio(
              url: 'http://audio.com',
              base64Data: 'audio_data',
              mimeType: 'audio/mp3',
            ),
          ),
          ContentBlock(
            const UserInputVideo(
              url: 'http://video.com',
              base64Data: 'video_data',
              mimeType: 'video/mp4',
            ),
          ),
          ContentBlock(
            const UserInputFile(
              url: 'http://file.com',
              name: 'file.txt',
              base64Data: 'file_data',
              mimeType: 'text/plain',
            ),
          ),
          ContentBlock(
            const AssistantGenText(
              text: "I'll check the current weather in New York City for you.",
            ),
          ),
          ContentBlock(
            const AssistantGenImage(
              url: 'http://gen_image.com',
              base64Data: 'gen_image_data',
              mimeType: 'image/png',
            ),
          ),
          ContentBlock(
            const AssistantGenAudio(
              url: 'http://gen_audio.com',
              base64Data: 'gen_audio_data',
              mimeType: 'audio/wav',
            ),
          ),
          ContentBlock(
            const AssistantGenVideo(
              url: 'http://gen_video.com',
              base64Data: 'gen_video_data',
              mimeType: 'video/mp4',
            ),
          ),
          ContentBlock(
            const Reasoning(
              text: "First, I need to identify the location (New York City) "
                  "from the user's query.\n"
                  'Then, I should call the weather API to get current '
                  'conditions.\n'
                  "Finally, I'll format the response in a user-friendly way "
                  'with temperature and conditions.',
              signature: 'encrypted_reasoning_content_that_is_very_long_and_'
                  'will_be_truncated_for_display',
            ),
          ),
          ContentBlock(
            const FunctionToolCall(
              callId: 'call_weather_123',
              name: 'get_current_weather',
              arguments: '{"location":"New York City","unit":"fahrenheit"}',
            ),
            streamingMeta: const StreamingMeta(index: 0),
          ),
          ContentBlock(
            FunctionToolResult(
              callId: 'call_weather_123',
              name: 'get_current_weather',
              content: [
                FunctionToolResultContentBlock(
                  const UserInputText(
                    text: '{"temperature":72,"condition":"sunny",'
                        '"humidity":45,"wind_speed":8}',
                  ),
                ),
              ],
            ),
          ),
          ContentBlock(
            const ServerToolCall(
              name: 'server_tool',
              callId: 'call_1',
              arguments: {'a': 1},
            ),
          ),
          ContentBlock(
            const ServerToolResult(
              name: 'server_tool',
              callId: 'call_1',
              content: {'success': true},
            ),
          ),
          ContentBlock(
            const AgenticMcpToolApprovalRequest(
              id: 'req_1',
              name: 'mcp_tool',
              serverLabel: 'mcp_server',
              arguments: '{}',
            ),
          ),
          ContentBlock(
            const AgenticMcpToolApprovalResponse(
              approvalRequestId: 'req_1',
              approve: true,
              reason: 'looks good',
            ),
          ),
          ContentBlock(
            const AgenticMcpToolCall(
              serverLabel: 'weather-mcp-server',
              callId: 'mcp_forecast_456',
              name: 'get_7day_forecast',
              arguments: '{"city":"New York","days":7}',
            ),
          ),
          ContentBlock(
            const AgenticMcpToolResult(
              callId: 'mcp_forecast_456',
              name: 'get_7day_forecast',
              content: '{"status":"partial","days_available":3}',
              error: AgenticMcpToolCallError(
                code: 503,
                message:
                    'Service temporarily unavailable for full 7-day forecast',
              ),
            ),
          ),
          ContentBlock(
            AgenticMcpListToolsResult(
              serverLabel: 'weather-mcp-server',
              tools: [
                AgenticMcpListToolsItem(
                  name: 'get_current_weather',
                  description: 'Get current weather conditions for a location',
                ),
                AgenticMcpListToolsItem(
                  name: 'get_7day_forecast',
                  description: 'Get 7-day weather forecast',
                ),
                AgenticMcpListToolsItem(
                  name: 'get_weather_alerts',
                  description: 'Get active weather alerts and warnings',
                ),
              ],
            ),
          ),
        ],
        responseMeta: const AgenticResponseMeta(
          tokenUsage: TokenUsage(
            promptTokens: 250,
            completionTokens: 180,
            totalTokens: 430,
          ),
        ),
      );

      expect(msg.toString(), r'''role: assistant
content_blocks:
  [0] type: user_input_text
      text: What's the weather like in New York City today?
  [1] type: user_input_image
      url: https://example.com/weather-map.jpg
      base64_data: iVBORw0KGgoAAAANSUhE...... (96 bytes)
      mime_type: image/jpeg
      detail: high
  [2] type: user_input_audio
      url: http://audio.com
      base64_data: audio_data... (10 bytes)
      mime_type: audio/mp3
  [3] type: user_input_video
      url: http://video.com
      base64_data: video_data... (10 bytes)
      mime_type: video/mp4
  [4] type: user_input_file
      name: file.txt
      url: http://file.com
      base64_data: file_data... (9 bytes)
      mime_type: text/plain
  [5] type: assistant_gen_text
      text: I'll check the current weather in New York City for you.
  [6] type: assistant_gen_image
      url: http://gen_image.com
      base64_data: gen_image_data... (14 bytes)
      mime_type: image/png
  [7] type: assistant_gen_audio
      url: http://gen_audio.com
      base64_data: gen_audio_data... (14 bytes)
      mime_type: audio/wav
  [8] type: assistant_gen_video
      url: http://gen_video.com
      base64_data: gen_video_data... (14 bytes)
      mime_type: video/mp4
  [9] type: reasoning
      text: First, I need to identify the location (New York City) from the user's query.
Then, I should call the weather API to get current conditions.
Finally, I'll format the response in a user-friendly way with temperature and conditions.
      signature: encrypted_reasoning_content_that_is_very_long_and_...
  [10] type: function_tool_call
      call_id: call_weather_123
      name: get_current_weather
      arguments: {"location":"New York City","unit":"fahrenheit"}
      stream_index: 0
  [11] type: function_tool_result
      call_id: call_weather_123
      name: get_current_weather
      content: (1 blocks)
        [0]       text: {"temperature":72,"condition":"sunny","humidity":45,"wind_speed":8}
  [12] type: server_tool_call
      name: server_tool
      call_id: call_1
      arguments: {
  "a": 1
}
  [13] type: server_tool_result
      name: server_tool
      call_id: call_1
      content: {
  "success": true
}
  [14] type: mcp_tool_approval_request
      server_label: mcp_server
      id: req_1
      name: mcp_tool
      arguments: {}
  [15] type: mcp_tool_approval_response
      approval_request_id: req_1
      approve: true
      reason: looks good
  [16] type: mcp_tool_call
      server_label: weather-mcp-server
      call_id: mcp_forecast_456
      name: get_7day_forecast
      arguments: {"city":"New York","days":7}
  [17] type: mcp_tool_result
      call_id: mcp_forecast_456
      name: get_7day_forecast
      content: {"status":"partial","days_available":3}
      error: [503] Service temporarily unavailable for full 7-day forecast
  [18] type: mcp_list_tools_result
      server_label: weather-mcp-server
      tools: 3 items
        - get_current_weather: Get current weather conditions for a location
        - get_7day_forecast: Get 7-day weather forecast
        - get_weather_alerts: Get active weather alerts and warnings
response_meta:
  token_usage: prompt=250, completion=180, total=430
''');
    });

    test('nil/empty fields', () {
      final msg = AgenticMessage(
        role: _user,
        contentBlocks: [
          ContentBlock(const UserInputAudio()),
          ContentBlock(const UserInputVideo()),
          ContentBlock(const UserInputFile()),
          ContentBlock(const AssistantGenImage()),
          ContentBlock(const AssistantGenAudio()),
          ContentBlock(const AssistantGenVideo()),
          ContentBlock(const ServerToolCall(name: 't')),
          ContentBlock(const ServerToolResult(name: 't')),
          ContentBlock(const AgenticMcpToolResult(name: 't')),
          ContentBlock(AgenticMcpListToolsResult()),
          ContentBlock(const AgenticMcpToolApprovalResponse()),
        ],
      );

      final s = msg.toString();
      expect(s, contains('type: user_input_audio'));
      expect(s, isNot(contains('mime_type:')));
      expect(s, contains('type: server_tool_call'));
      expect(s, contains('      arguments: null\n'));
      expect(s, contains('      content: null\n'));
      expect(s, contains('      approve: false\n'));
      expect(s, isNot(contains('reason:')));
      expect(s, isNot(contains('call_id: \n      arguments')));
    });

    test('zero-valued payloads print their type', () {
      final msg = AgenticMessage(
        role: _assistant,
        contentBlocks: [
          for (final content in <ContentBlockVariant>[
            const Reasoning(),
            const UserInputText(),
            const UserInputImage(),
            const ToolSearchFunctionToolResult(),
            const AssistantGenText(),
            const FunctionToolCall(),
            FunctionToolResult(),
            const AgenticMcpToolCall(),
            const AgenticMcpToolApprovalRequest(),
          ])
            ContentBlock(content),
        ],
      );
      final s = msg.toString();
      expect(s, contains('type: reasoning\n      text: \n'));
      expect(s, contains('  [3] type: tool_search_result\n  [4]'));
    });

    test('tool search results print the tool names', () {
      final block = ContentBlock(
        ToolSearchFunctionToolResult(
          result: ToolSearchResult(
            tools: [
              ToolInfo.fromParams(name: 'a', desc: '', params: const {}),
              ToolInfo.fromParams(name: 'b', desc: '', params: const {}),
            ],
          ),
        ),
        streamingMeta: const StreamingMeta(index: 1),
      );
      expect(
        block.toString(),
        'type: tool_search_result\nToolSearchResult[a,b,]'
        '      stream_index: 1\n',
      );
    });

    test('server tool values: strings as they are, maps as Go JSON', () {
      expect(
        const ServerToolCall(name: 'n', arguments: 'raw').toString(),
        '      name: n\n      arguments: raw\n',
      );
      expect(
        const ServerToolResult(
          name: 'n',
          content: {
            'z': [1, 2.5, 3.0],
            'a': '<&>',
            'm': <String, Object?>{},
          },
        ).toString(),
        '      name: n\n      content: {\n'
        '  "a": "\\u003c\\u0026\\u003e",\n'
        '  "m": {},\n'
        '  "z": [\n'
        '    1,\n'
        '    2.5,\n'
        '    3\n'
        '  ]\n'
        '}\n',
      );
    });

    test('an MCP error without a code', () {
      expect(
        const AgenticMcpToolResult(
          name: 't',
          error: AgenticMcpToolCallError(message: 'm'),
        ).toString(),
        '      call_id: \n      name: t\n      content: \n      error: m\n',
      );
    });

    test('a message without blocks or metadata', () {
      expect(AgenticMessage(role: _user).toString(), 'role: user\n');
      expect(
        AgenticMessage(
          role: _user,
          responseMeta: const AgenticResponseMeta(),
        ).toString(),
        'role: user\nresponse_meta:\n',
      );
    });
  });

  group('FieldAddressable', () {
    final message = AgenticMessage(
      role: _assistant,
      contentBlocks: [ContentBlock(const AssistantGenText(text: 'a'))],
      responseMeta: const AgenticResponseMeta(extension: 'x'),
      extra: const {'k': 'v'},
    );

    test('reads the fields by their Dart and their Go names', () {
      expect(message, isA<FieldAddressable>());
      for (final (dart, go, value) in [
        ('role', 'Role', message.role),
        ('contentBlocks', 'ContentBlocks', message.contentBlocks),
        ('responseMeta', 'ResponseMeta', message.responseMeta),
        ('extra', 'Extra', message.extra),
      ]) {
        expect(message.getField(dart), value);
        expect(message.getField(go), value);
      }
      expect(() => message.getField('content'), throwsArgumentError);
    });

    test('replaces a field in a copy', () {
      final blocks = <Object?>[ContentBlock(const Reasoning(text: 'r'))];
      final changed = message
          .withField('Role', _user)
          .withField('contentBlocks', blocks)
          .withField('responseMeta', null)
          .withField('Extra', <String, Object?>{'n': 1});
      expect(
        changed,
        AgenticMessage(
          role: _user,
          contentBlocks: [ContentBlock(const Reasoning(text: 'r'))],
          extra: const {'n': 1},
        ),
      );
      expect(message.role, _assistant);
      expect(message.withField('extra', null).extra, isNull);
      expect(message.withField('ContentBlocks', null).contentBlocks, isEmpty);
      expect(() => message.withField('nope', 1), throwsArgumentError);
      expect(
        () => message.withField('role', 'user'),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('TestSystemAgenticMessage', () {
    test('basic', () {
      final msg = AgenticMessage.system('system');
      expect(msg.role, AgenticRoleType.system);
      expect(msg.contentBlocks, hasLength(1));
      expect(msg.contentBlocks[0].userInputText!.text, 'system');
    });
  });

  group('TestUserAgenticMessage', () {
    test('basic', () {
      final msg = AgenticMessage.user('user');
      expect(msg.role, AgenticRoleType.user);
      expect(msg.contentBlocks, hasLength(1));
      expect(msg.contentBlocks[0].userInputText!.text, 'user');
    });
  });

  group('TestNewContentBlock', () {
    final payloads = <ContentBlockVariant>[
      const Reasoning(),
      const UserInputText(),
      const UserInputImage(),
      const UserInputAudio(),
      const UserInputVideo(),
      const UserInputFile(),
      const ToolSearchFunctionToolResult(),
      const AssistantGenText(),
      const AssistantGenImage(),
      const AssistantGenAudio(),
      const AssistantGenVideo(),
      const FunctionToolCall(),
      FunctionToolResult(),
      const ServerToolCall(),
      const ServerToolResult(),
      const AgenticMcpToolCall(),
      const AgenticMcpToolResult(),
      AgenticMcpListToolsResult(),
      const AgenticMcpToolApprovalRequest(),
      const AgenticMcpToolApprovalResponse(),
    ];

    test('covers every block type', () {
      expect(
        payloads.map((p) => p.blockType).toSet(),
        ContentBlockType.values.toSet(),
      );
    });

    for (final input in payloads) {
      test('${input.runtimeType}', () {
        final block = ContentBlock(input);
        final Object? field = switch (input.blockType) {
          ContentBlockType.reasoning => block.reasoning,
          ContentBlockType.userInputText => block.userInputText,
          ContentBlockType.userInputImage => block.userInputImage,
          ContentBlockType.userInputAudio => block.userInputAudio,
          ContentBlockType.userInputVideo => block.userInputVideo,
          ContentBlockType.userInputFile => block.userInputFile,
          ContentBlockType.toolSearchResult =>
            block.toolSearchFunctionToolResult,
          ContentBlockType.assistantGenText => block.assistantGenText,
          ContentBlockType.assistantGenImage => block.assistantGenImage,
          ContentBlockType.assistantGenAudio => block.assistantGenAudio,
          ContentBlockType.assistantGenVideo => block.assistantGenVideo,
          ContentBlockType.functionToolCall => block.functionToolCall,
          ContentBlockType.functionToolResult => block.functionToolResult,
          ContentBlockType.serverToolCall => block.serverToolCall,
          ContentBlockType.serverToolResult => block.serverToolResult,
          ContentBlockType.mcpToolCall => block.mcpToolCall,
          ContentBlockType.mcpToolResult => block.mcpToolResult,
          ContentBlockType.mcpListToolsResult => block.mcpListToolsResult,
          ContentBlockType.mcpToolApprovalRequest =>
            block.mcpToolApprovalRequest,
          ContentBlockType.mcpToolApprovalResponse =>
            block.mcpToolApprovalResponse,
        };
        expect(field, same(input));
        expect(block.type, input.blockType);
        expect(block.type.value, isNotEmpty);
        expect(ContentBlockType.fromValue(block.type.value), block.type);
      });
    }
  });

  group('TestNewContentBlockChunk_NilMeta', () {
    test('a chunk without streaming meta', () {
      final block = ContentBlock(const AssistantGenText(text: 'test'));
      expect(block.streamingMeta, isNull);
      expect(
        block.copyWith(streamingMeta: const StreamingMeta(index: 1))
            .copyWith(clearStreamingMeta: true)
            .streamingMeta,
        isNull,
      );
    });
  });

  group('TestConcatAssistantGenTexts_ExtensionOverwrite', () {
    List<AgenticMessage> chunks() => [
          _msg(_assistant, [
            _chunk(
              const AssistantGenText(
                text: 'Hello ',
                extension: _TestExtension('ext1'),
              ),
            ),
          ]),
          _msg(_assistant, [
            _chunk(
              const AssistantGenText(
                text: 'world',
                extension: _TestExtension('ext2'),
              ),
            ),
          ]),
        ];

    test('two values of an unregistered type cannot be joined', () {
      expect(
        () => concatAgenticMessages(chunks()),
        _concatError('cannot concat multiple non-zero value'),
      );
    });

    test('with a registered function the joined value is stored', () {
      StreamConcat.register<_TestExtension>(
        (items) => _TestExtension(items.map((e) => e.value).join('+')),
      );
      addTearDown(StreamConcat.reset);

      final result = concatAgenticMessages(chunks());
      final text = result.contentBlocks.single.assistantGenText!;
      expect(text.text, 'Hello world');
      expect(text.extension, const _TestExtension('ext1+ext2'));
    });
  });

  group('TestFunctionToolResultBlockString', () {
    test('known type with an empty payload', () {
      expect(
        FunctionToolResultContentBlock(const UserInputText()).toString(),
        '      text: \n',
      );
    });

    test('each type prints its payload', () {
      expect(
        FunctionToolResultContentBlock(const UserInputText(text: 'x'))
            .toString(),
        '      text: x\n',
      );
      expect(
        FunctionToolResultContentBlock(
          const UserInputImage(url: 'u', detail: ImageURLDetail.low),
        ).toString(),
        '      url: u\n      detail: low\n',
      );
      expect(
        FunctionToolResultContentBlock(const UserInputFile(name: 'n'))
            .toString(),
        '      name: n\n',
      );
      expect(
        FunctionToolResultContentBlock(const UserInputVideo(fileId: 'f'))
            .type,
        FunctionToolResultContentBlockType.video,
      );
    });
  });

  group('TestConcatFunctionToolResults', () {
    test('direct append', () {
      final result = concatAgenticMessages([
        _msg(_user, [
          _chunk(
            FunctionToolResult(
              callId: 'c1',
              name: 'tool1',
              content: [
                FunctionToolResultContentBlock(
                  const UserInputText(text: 'hello'),
                ),
              ],
            ),
          ),
        ]),
        _msg(_user, [
          _chunk(
            FunctionToolResult(
              callId: 'c1',
              name: 'tool1',
              content: [
                FunctionToolResultContentBlock(
                  const UserInputImage(url: 'http://img.png'),
                ),
              ],
            ),
          ),
        ]),
      ]);
      final got = result.contentBlocks.single.functionToolResult!;
      expect(got.content, hasLength(2));
      expect((got.content[0].content as UserInputText).text, 'hello');
      expect((got.content[1].content as UserInputImage).url, 'http://img.png');
    });
  });
}
