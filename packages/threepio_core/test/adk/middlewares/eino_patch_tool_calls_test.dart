// Port of eino v0.9.22 adk/middlewares/patchtoolcalls/patchtoolcalls_test.go
// (classic messages only).
//
// Ported: TestPatchToolCallsGeneric (the `Message` sub-tests),
// TestPatchedToolResultGenerator_SetsContentOnlyForPlainText,
// TestPatchedToolResultGenerator_ToolResultPath,
// TestPatchedToolResultGenerator_ContentAndToolResultMutuallyExclusive,
// TestPatchedToolResultGenerator_ErrorPropagation (`Message`),
// TestToolResultToMessage_NilAndEmpty,
// TestToolResultToMessage_PlainTextSetsContentOnly,
// TestToolResultToMessage_MultimodalDoesNotSetContent.
//
// Not ported:
// * agentic messages are P13: TestNewTypedAgenticMessage,
//   TestPatchToolCallsGeneric/AgenticMessage,
//   TestPatchToolCallsAgenticToolSearchResult,
//   TestPatchToolCalls_NilFunctionToolCallInBlock,
//   TestPatchToolCalls_AgenticMessage_NilBlockInUserMessage,
//   TestPatchedToolResultGenerator_ErrorPropagation/AgenticMessage,
//   TestToolResultToAgenticMessage_ToolSearchAndEmpty,
//   TestToolResultToAgenticMessage_MalformedPartsError,
//   TestToolResultToFunctionBlocks_AllModalities,
//   TestToolResultToFunctionBlocks_MalformedPartsError,
//   TestPatchedToolResultGenerator_AgenticNilImagePropagatesError,
//   TestPatchedToolResultGenerator_AgenticMultimodal, TestToolResultFileID
//   (they build `ContentBlock`s / `FunctionToolResultContentBlock`s);
// * the deprecated `Config.PatchedContentGenerator` is not ported:
//   TestPatchedContentGenerator_ErrorPropagation and the
//   TestPatchToolCallsGeneric/Message sub-test "custom content generator";
// * TestDerefString: a Go `*string` helper of the agentic path only; Dart has
//   no pointers (and no counterpart).
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/patch_tool_calls/patch_tool_calls.dart'
    show toolResultToToolMessage;

final _ctx = RunContext.background();

/// Go `testToolCall`.
typedef _Call = ({String id, String name, String arguments});

/// Go `makeUserMsg[*schema.Message]`.
Message _user(String content) => Message.user(content);

/// Go `makeAssistantMsgWithToolCalls[*schema.Message]` (`schema.AssistantMessage`).
Message _assistant(String content, List<_Call>? calls) => Message.assistant(
      content,
      toolCalls: calls == null
          ? null
          : [
              for (final c in calls)
                ToolCall(id: c.id, function: FunctionCall(name: c.name, arguments: c.arguments)),
            ],
    );

/// Go `makeToolResultMsg[*schema.Message]`.
Message _toolResult(String content, String callId, String toolName) =>
    Message.tool(content: content, toolCallId: callId, toolName: toolName);

/// Go `fmt.Sprintf(defaultPatchedToolMessageTemplate, name, id)`.
String _defaultPatched(String name, String id) =>
    'Tool call $name with id $id was canceled - another message came in before it could be completed.';

/// Go `errors.Is(err, target)`: [error] is [target] or wraps it.
bool _isOrWraps(Object? error, Object target) {
  var current = error;
  for (var depth = 0; depth < 64 && current != null; depth++) {
    if (identical(current, target)) return true;
    if (current is! ThreepioException) return false;
    current = current.cause;
  }
  return false;
}

Future<ChatModelAgentState> _rewrite(PatchToolCallsMiddleware mw, List<Message> messages) async {
  final (_, state) =
      await mw.beforeModelRewriteState(_ctx, ChatModelAgentState(messages: messages), const ModelContext());
  return state;
}

void main() {
  group('TestPatchToolCallsGeneric', () {
    group('Message', () {
      final cases = <({
        String name,
        PatchedToolResultGenerator? generator,
        List<Message> messages,
        int wantLen,
        int checkPatchedAt,
        String wantCallId,
        String wantToolName,
        String wantContent,
      })>[
        (
          name: 'empty messages',
          generator: null,
          messages: const [],
          wantLen: 0,
          checkPatchedAt: -1,
          wantCallId: '',
          wantToolName: '',
          wantContent: '',
        ),
        (
          name: 'no tool calls to patch',
          generator: null,
          messages: [_user('hello'), _assistant('hi there', null)],
          wantLen: 2,
          checkPatchedAt: -1,
          wantCallId: '',
          wantToolName: '',
          wantContent: '',
        ),
        (
          name: 'missing tool result',
          generator: null,
          messages: [
            _user('hello'),
            _assistant('', [
              (id: 'call_1', name: 'tool_a', arguments: '{}'),
              (id: 'call_2', name: 'tool_b', arguments: '{}'),
            ]),
            _toolResult('result_a', 'call_1', 'tool_a'),
          ],
          wantLen: 4,
          checkPatchedAt: 2,
          wantCallId: 'call_2',
          wantToolName: 'tool_b',
          wantContent: _defaultPatched('tool_b', 'call_2'),
        ),
        // "custom content generator" is not ported (deprecated
        // PatchedContentGenerator).
        (
          name: 'custom tool result generator',
          generator: (ctx, toolName, toolCallId, toolArgument) =>
              PatchedToolResult(content: 'result $toolName $toolCallId ${toolArgument.text}'),
          messages: [
            _user('hello'),
            _assistant('', [
              (id: 'call_1', name: 'tool_a', arguments: '{}'),
              (id: 'call_2', name: 'tool_b', arguments: '{"x":1}'),
            ]),
            _toolResult('result_a', 'call_1', 'tool_a'),
          ],
          wantLen: 4,
          checkPatchedAt: 2,
          wantCallId: 'call_2',
          wantToolName: 'tool_b',
          wantContent: 'result tool_b call_2 {"x":1}',
        ),
        // The deprecated PatchedContentGenerator ("legacy") is not ported, so
        // only the PatchedToolResultGenerator is configured here.
        (
          name: 'tool result generator takes precedence over content generator',
          generator: (ctx, toolName, toolCallId, toolArgument) =>
              const PatchedToolResult(content: 'enhanced'),
          messages: [
            _user('hello'),
            _assistant('', [(id: 'call_1', name: 'tool_a', arguments: '{}')]),
          ],
          wantLen: 3,
          checkPatchedAt: 2,
          wantCallId: 'call_1',
          wantToolName: 'tool_a',
          wantContent: 'enhanced',
        ),
        (
          name: 'two consecutive assistant messages with tool calls',
          generator: null,
          messages: [
            _user('hello'),
            _assistant('', [(id: 'call_1', name: 'tool_a', arguments: '{}')]),
            _assistant('continued...', null),
          ],
          wantLen: 4,
          checkPatchedAt: 2,
          wantCallId: 'call_1',
          wantToolName: 'tool_a',
          wantContent: _defaultPatched('tool_a', 'call_1'),
        ),
        (
          name: 'assistant message followed by user message without tool result',
          generator: null,
          messages: [
            _user('hello'),
            _assistant('', [(id: 'call_1', name: 'tool_a', arguments: '{}')]),
            _user('continued...'),
          ],
          wantLen: 4,
          checkPatchedAt: 2,
          wantCallId: 'call_1',
          wantToolName: 'tool_a',
          wantContent: _defaultPatched('tool_a', 'call_1'),
        ),
      ];

      for (final tt in cases) {
        test(tt.name, () async {
          final mw = PatchToolCallsMiddleware(generator: tt.generator);
          final newState = await _rewrite(mw, tt.messages);
          expect(newState.messages, hasLength(tt.wantLen));

          if (tt.checkPatchedAt >= 0 && tt.checkPatchedAt < newState.messages.length) {
            final patched = newState.messages[tt.checkPatchedAt];
            expect(patched.toolCallId, tt.wantCallId);
            expect(patched.toolName, tt.wantToolName);
            expect(patched.content, tt.wantContent);
          }
        });
      }
    });
  });

  test('TestPatchedToolResultGenerator_SetsContentOnlyForPlainText', () async {
    final seen = <(String, String, String)>[];
    final mw = PatchToolCallsMiddleware(
      generator: (ctx, toolName, toolCallId, toolArgument) {
        seen.add((toolName, toolCallId, toolArgument.text));
        return const PatchedToolResult(content: 'patched text');
      },
    );

    final newState = await _rewrite(mw, [
      Message.user('hello'),
      Message.assistant('', toolCalls: [
        const ToolCall(id: 'call_1', function: FunctionCall(name: 'tool_a', arguments: '{"q":"hi"}')),
      ]),
    ]);
    expect(seen, [('tool_a', 'call_1', '{"q":"hi"}')]);
    expect(newState.messages, hasLength(3));

    final patched = newState.messages[2];
    expect(patched.role, RoleType.tool);
    expect(patched.toolCallId, 'call_1');
    expect(patched.toolName, 'tool_a');
    expect(patched.content, 'patched text');
    expect(
      patched.userInputMultiContent ?? const <MessageInputPart>[],
      isEmpty,
      reason: 'plain-text tool results must not set UserInputMultiContent '
          '(OpenAI Content/MultiContent exclusivity)',
    );
  });

  test('TestPatchedToolResultGenerator_ToolResultPath', () async {
    final mw = PatchToolCallsMiddleware(
      generator: (ctx, toolName, toolCallId, toolArgument) => const PatchedToolResult(
        toolResult: ToolResult([ToolOutputPart(type: ToolPartType.text, text: 'via tool result')]),
      ),
    );

    final newState = await _rewrite(mw, [
      Message.assistant('', toolCalls: [
        const ToolCall(id: 'call_1', function: FunctionCall(name: 'tool_a', arguments: '{}')),
      ]),
    ]);
    expect(newState.messages, hasLength(2));
    expect(newState.messages[1].content, 'via tool result');
    expect(newState.messages[1].userInputMultiContent ?? const <MessageInputPart>[], isEmpty);
  });

  test('TestPatchedToolResultGenerator_ContentAndToolResultMutuallyExclusive', () async {
    final mw = PatchToolCallsMiddleware(
      generator: (ctx, toolName, toolCallId, toolArgument) => const PatchedToolResult(
        content: 'plain',
        toolResult: ToolResult([ToolOutputPart(type: ToolPartType.text, text: 'also')]),
      ),
    );

    await expectLater(
      _rewrite(mw, [
        Message.assistant('', toolCalls: [
          const ToolCall(id: 'call_1', function: FunctionCall(name: 'tool_a', arguments: '{}')),
        ]),
      ]),
      throwsA(predicate((Object e) => '$e'.contains('mutually exclusive'))),
    );
  });

  group('TestPatchedToolResultGenerator_ErrorPropagation', () {
    final wantErr = Exception('boom');

    test('Message', () async {
      final mw = PatchToolCallsMiddleware(
        generator: (ctx, toolName, toolCallId, toolArgument) => throw wantErr,
      );
      await expectLater(
        _rewrite(mw, [
          Message.assistant('', toolCalls: [
            const ToolCall(id: 'call_1', function: FunctionCall(name: 'tool_a', arguments: '{}')),
          ]),
        ]),
        throwsA(predicate((Object e) => _isOrWraps(e, wantErr))),
      );
    });
    // AgenticMessage: not ported (P13).
  });

  test('TestToolResultToMessage_NilAndEmpty', () {
    var msg = toolResultToToolMessage('tool_a', 'call_1', null);
    expect(msg.toolCallId, 'call_1');
    expect(msg.toolName, 'tool_a');
    expect(msg.content, isEmpty);
    expect(msg.userInputMultiContent ?? const <MessageInputPart>[], isEmpty);

    msg = toolResultToToolMessage('tool_a', 'call_1', const ToolResult());
    expect(msg.content, isEmpty);
    expect(msg.userInputMultiContent ?? const <MessageInputPart>[], isEmpty);
  });

  test('TestToolResultToMessage_PlainTextSetsContentOnly', () {
    final msg = toolResultToToolMessage(
      'tool_a',
      'call_1',
      const ToolResult([ToolOutputPart(type: ToolPartType.text, text: 'hello')]),
    );
    expect(msg.content, 'hello');
    expect(msg.userInputMultiContent ?? const <MessageInputPart>[], isEmpty);
  });

  test('TestToolResultToMessage_MultimodalDoesNotSetContent', () {
    const url = 'https://example.com/a.png';
    const result = ToolResult([
      ToolOutputPart(type: ToolPartType.text, text: 'caption'),
      ToolOutputPart(
        type: ToolPartType.image,
        image: ToolOutputImage(common: MessagePartCommon(url: url, mimeType: 'image/png')),
      ),
    ]);
    final msg = toolResultToToolMessage('vision', 'call_1', result);
    expect(msg.content, isEmpty, reason: 'multi-part results should not set Content');
    expect(msg.userInputMultiContent, hasLength(2));
  });
}
