// Ports of eino-ext components/model/claude tests that check the wire
// conversion (claude_test.go, file_id_test.go):
//   TestClaude (the genParamsAndOptions cases), TestConvStreamEvent,
//   TestWithTools (in claude_chat_model_test.dart), TestPopulateContentBlockBreakPoint,
//   Test_convSchemaMessage_MultiContent, TestPopulateToolChoice, TestCacheTTL,
//   TestToolSearchResultInput, TestDuplicateToolError,
//   TestToolSearchEventsRoundTrip, TestPopulateInputMergeConsecutiveTools,
//   TestInputFileID, TestInputFileIDPrecedence.
// Not ported:
//   * TestClaude "legacy thinking config" and the legacy half of "native
//     thinking config overrides legacy thinking": the deprecated `Thinking`
//     /`WithThinking` are not ported (the override is tested as per-call over
//     config instead).
//   * Test_convSchemaMessage_MultiContent "MultiContent backward
//     compatibility" (both): Dart's Message has no deprecated MultiContent.
//   * TestPopulateToolChoice "unsupported tool choice": ToolChoice is an enum.
//   * TestCacheTTL "SetMessageBreakpoint/SetToolInfoBreakpoint without TTL":
//     deprecated; withClaudeCacheControl() without a control is tested instead.
//   * TestPanicErr: Dart has no panics to recover from.
//   * TestVertexServiceAccountJSON: the Vertex transport is out of scope.
// Plus tests written for the port: the request body built from the config,
// the options and the messages; headers; additional request fields; tools;
// automatic cache breakpoints; structured output; deferred tools.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_config.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_converters.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_message_extras.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_options.dart';
import 'package:threepio_core/threepio_core.dart';

import 'claude_fixtures.dart';

ClaudeRequest _request(
  List<Message> input, {
  ClaudeConfig config = testConfig,
  ChatModelOptions? options,
  List<ToolInfo>? bound,
  bool stream = false,
}) =>
    buildClaudeRequest(
      config,
      input,
      claudeCallOptions(config, bound, options),
      stream: stream,
    );

Map<String, Object?> _body(
  List<Message> input, {
  ClaudeConfig config = testConfig,
  ChatModelOptions? options,
  List<ToolInfo>? bound,
}) =>
    _request(input, config: config, options: options, bound: bound).body;

List<Map<String, Object?>> _messages(Map<String, Object?> body) =>
    (body['messages']! as List).cast<Map<String, Object?>>();

List<Map<String, Object?>> _contentOf(Map<String, Object?> param) =>
    (param['content']! as List).cast<Map<String, Object?>>();

Matcher _formatError(String text) => isA<ThreepioFormatException>()
    .having((e) => e.message, 'message', contains(text));

Matcher _argumentError(String message) =>
    isA<ArgumentError>().having((e) => e.message, 'message', message);

ToolInfo _tool(String name) => ToolInfo.fromJsonSchema(
      name: name,
      desc: 'desc of $name',
      schema: const JSONSchema(
        properties: {'city': JSONSchemaProperty(type: 'string')},
        required: ['city'],
      ),
    );

ChatModelOptions _claude(ClaudeRequestOptions options) => options.toOptions();

void main() {
  group('TestClaude', () {
    test('requires at least 1 user msg', () {
      expect(
        () => _body([Message.system('hello')]),
        throwsA(
          _formatError(
            'only system message in input, require at least 1 user message',
          ),
        ),
      );
    });

    test('first non system msg should be user', () {
      expect(
        () => _body([Message.system('hello'), Message.assistant('world')]),
        throwsA(_formatError('first non-system message should be user message')),
      );
    });

    test('multiple system msg', () {
      final body = _body([
        Message.system('hello'),
        Message.system('world'),
        Message.user('again'),
      ]);
      expect(body, {
        'model': testModel,
        'max_tokens': 1024,
        'system': [
          {'type': 'text', 'text': 'hello'},
          {'type': 'text', 'text': 'world'},
        ],
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'again'},
            ],
          },
        ],
      });
    });

    test('native adaptive thinking config', () {
      final body = _body(
        [Message.user('hello')],
        options: _claude(
          const ClaudeRequestOptions(
            thinkingConfig: ClaudeThinkingConfig.adaptive(
              display: ClaudeThinkingDisplay.omitted,
            ),
          ),
        ),
      );
      expect(body['thinking'], {'type': 'adaptive', 'display': 'omitted'});
    });

    test('native thinking config of a call overrides the config', () {
      final body = _body(
        [Message.user('hello')],
        config: const ClaudeConfig(
          model: testModel,
          maxTokens: 2048,
          thinkingConfig: ClaudeThinkingConfig.enabled(budgetTokens: 1024),
        ),
        options: _claude(
          const ClaudeRequestOptions(
            thinkingConfig: ClaudeThinkingConfig.adaptive(),
          ),
        ),
      );
      expect(body['thinking'], {'type': 'adaptive'});
    });

    test('input is empty', () {
      expect(() => _body(const []), throwsA(_formatError('input is empty')));
    });
  });

  group('TestConvStreamEvent', () {
    final converter = ClaudeStreamConverter();
    Map<String, Object?> data(String sse) => (jsonDecode(
          sse.split('\n').firstWhere((l) => l.startsWith('data: ')).substring(6),
        ) as Map)
            .cast<String, Object?>();

    test('message start event', () {
      final message = converter.convert({
        'type': 'message_start',
        'message': messageResponse(
          [textBlock('Initial message')],
          stopReason: null,
          usage: {
            'input_tokens': 5,
            'output_tokens': 2,
            'output_tokens_details': {'thinking_tokens': 1},
          },
        ),
      })!;
      expect(message.content, 'Initial message');
      expect(message.role, RoleType.assistant);
      expect(message.responseMeta!.usage!.promptTokens, 5);
      expect(message.responseMeta!.usage!.completionTokens, 2);
      expect(
        message.responseMeta!.usage!.completionTokenDetails!.reasoningTokens,
        1,
      );
      expect(message.responseMeta!.finishReason, isNull);
    });

    test('content block delta event - text', () {
      final message = converter.convert(data(textDelta(0, ' world')))!;
      expect(message.content, ' world');
    });

    test('content block delta event - tool input', () {
      // Go presets the tool index to 0; here a started tool_use does that.
      converter.convert(
        data(blockStart(1, toolUseBlock('toolu_1', 'weather', {}))),
      );
      final message = converter.convert(data(jsonDelta(1, ',"temp":25')))!;
      expect(message.toolCalls, hasLength(1));
      expect(message.toolCalls![0].index, 0);
      expect(message.toolCalls![0].type, '');
      expect(message.toolCalls![0].function.arguments, ',"temp":25');
    });

    test('message delta event', () {
      final message = converter.convert({
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
        'usage': {
          'input_tokens': 8,
          'cache_read_input_tokens': 3,
          'cache_creation_input_tokens': 2,
          'output_tokens': 10,
          'output_tokens_details': {'thinking_tokens': 4},
        },
      })!;
      final meta = message.responseMeta!;
      expect(meta.finishReason, 'end_turn');
      expect(meta.usage!.promptTokens, 13);
      expect(meta.usage!.promptTokenDetails!.cachedTokens, 3);
      expect(meta.usage!.completionTokens, 10);
      expect(meta.usage!.totalTokens, 23);
      expect(meta.usage!.completionTokenDetails!.reasoningTokens, 4);
      expect(message.claudeCacheCreationInputTokens, 2);
    });

    test('content block start event', () {
      final message = converter.convert(
        data(blockStart(2, toolUseBlock('', 'tool', {'q': 'xxx'}))),
      )!;
      expect(message.toolCalls, hasLength(1));
      expect(message.toolCalls![0].index, 1);
      expect(message.toolCalls![0].type, 'function');
      expect(message.toolCalls![0].function.name, 'tool');
      expect(message.toolCalls![0].function.arguments, '{"q":"xxx"}');
    });

    test('stop events and pings carry nothing; unknown events throw', () {
      expect(converter.convert({'type': 'message_stop'}), isNull);
      expect(
        converter.convert({'type': 'content_block_stop', 'index': 0}),
        isNull,
      );
      expect(
        () => converter.convert({'type': 'mystery'}),
        throwsA(_formatError('unknown stream event type: mystery')),
      );
    });
  });

  group('TestPopulateContentBlockBreakPoint', () {
    test('text, image, tool result and tool use blocks get one', () {
      for (final block in [
        <String, Object?>{'type': 'text', 'text': 'input'},
        <String, Object?>{
          'type': 'image',
          'source': {'type': 'url', 'url': ''},
        },
        <String, Object?>{
          'type': 'tool_result',
          'tool_use_id': 'userID',
          'content': <Object?>[],
        },
        <String, Object?>{
          'type': 'tool_use',
          'id': '123',
          'name': 'test_tool',
          'input': 'input',
        },
      ]) {
        populateClaudeBlockBreakpoint(block, null);
        expect(block['cache_control'], {'type': 'ephemeral'}, reason: '$block');
      }
    });

    test('other blocks are left alone (as in Go)', () {
      final document = <String, Object?>{
        'type': 'document',
        'source': {'type': 'file', 'file_id': 'f'},
      };
      populateClaudeBlockBreakpoint(document, null);
      expect(document.containsKey('cache_control'), isFalse);
    });
  });

  group('Test_convSchemaMessage_MultiContent', () {
    const rawBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    const invalidDataUrl = 'data:image/png;base64,$rawBase64';
    const httpUrl = 'https://example.com/image.png';

    MessageInputPart userImage(MessagePartCommon common) => MessageInputPart(
          type: ChatMessagePartType.imageUrl,
          image: MessageInputImage(common: common),
        );
    MessageOutputPart assistantImage(MessagePartCommon common) =>
        MessageOutputPart(type: ChatMessagePartType.imageUrl, image: common);

    group('UserInputMultiContent', () {
      test('success with base64', () {
        final result = claudeMessageParam(
          Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart.text('hello'),
              userImage(
                const MessagePartCommon(
                  base64Data: rawBase64,
                  mimeType: 'image/png',
                ),
              ),
            ],
          ),
        );
        final content = _contentOf(result);
        expect(content, hasLength(2));
        expect(content[0], {'type': 'text', 'text': 'hello'});
        expect(content[1], {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/png',
            'data': rawBase64,
          },
        });
      });

      test('success with url', () {
        final result = claudeMessageParam(
          Message(
            role: RoleType.user,
            userInputMultiContent: [
              userImage(const MessagePartCommon(url: httpUrl)),
            ],
          ),
        );
        expect(_contentOf(result).single, {
          'type': 'image',
          'source': {'type': 'url', 'url': httpUrl},
        });
      });

      test('error with data url prefix', () {
        expect(
          () => claudeMessageParam(
            Message(
              role: RoleType.user,
              userInputMultiContent: [
                userImage(
                  const MessagePartCommon(
                    base64Data: invalidDataUrl,
                    mimeType: 'image/png',
                  ),
                ),
              ],
            ),
          ),
          throwsA(_formatError('Base64Data should be a raw base64 string')),
        );
      });

      test('error with no mime type for base64', () {
        expect(
          () => claudeMessageParam(
            Message(
              role: RoleType.user,
              userInputMultiContent: [
                userImage(const MessagePartCommon(base64Data: rawBase64)),
              ],
            ),
          ),
          throwsA(
            _formatError('image part must have MIMEType when use Base64Data'),
          ),
        );
      });

      test('error with no url or base64', () {
        expect(
          () => claudeMessageParam(
            Message(
              role: RoleType.user,
              userInputMultiContent: [userImage(const MessagePartCommon())],
            ),
          ),
          throwsA(
            _formatError('image part must have either a URL or Base64Data'),
          ),
        );
      });
    });

    group('AssistantGenMultiContent', () {
      test('success with image', () {
        final result = claudeMessageParam(
          Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [
              assistantImage(
                const MessagePartCommon(
                  base64Data: rawBase64,
                  mimeType: 'image/png',
                ),
              ),
              const MessageOutputPart(
                type: ChatMessagePartType.text,
                text: 'some text',
              ),
            ],
          ),
        );
        final content = _contentOf(result);
        expect(content, hasLength(2));
        expect(
          (content[0]['source']! as Map)['media_type'],
          'image/png',
        );
        expect(content[1], {'type': 'text', 'text': 'some text'});
        expect(result['role'], 'assistant');
      });

      test('success with url', () {
        final result = claudeMessageParam(
          Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [
              assistantImage(const MessagePartCommon(url: httpUrl)),
            ],
          ),
        );
        expect((_contentOf(result).single['source']! as Map)['url'], httpUrl);
      });

      test('error with wrong role', () {
        expect(
          () => claudeMessageParam(
            const Message(
              role: RoleType.user,
              assistantGenMultiContent: [
                MessageOutputPart(
                  type: ChatMessagePartType.text,
                  text: 'some text',
                ),
              ],
            ),
          ),
          throwsA(
            _formatError(
              'assistant gen multi content only support assistant role',
            ),
          ),
        );
      });

      test('error with data url prefix', () {
        expect(
          () => claudeMessageParam(
            Message(
              role: RoleType.assistant,
              assistantGenMultiContent: [
                assistantImage(
                  const MessagePartCommon(
                    base64Data: invalidDataUrl,
                    mimeType: 'image/png',
                  ),
                ),
              ],
            ),
          ),
          throwsA(_formatError('Base64Data should be a raw base64 string')),
        );
      });

      test('error with no mime type for base64', () {
        expect(
          () => claudeMessageParam(
            Message(
              role: RoleType.assistant,
              assistantGenMultiContent: [
                assistantImage(const MessagePartCommon(base64Data: rawBase64)),
              ],
            ),
          ),
          throwsA(
            _formatError('image part must have MIMEType when use Base64Data'),
          ),
        );
      });

      test('error with no url or base64', () {
        expect(
          () => claudeMessageParam(
            Message(
              role: RoleType.assistant,
              assistantGenMultiContent: [
                assistantImage(const MessagePartCommon()),
              ],
            ),
          ),
          throwsA(
            _formatError('image part must have either a URL or Base64Data'),
          ),
        );
      });
    });

    test('error with both UserInputMultiContent and AssistantGenMultiContent',
        () {
      expect(
        () => claudeMessageParam(
          Message(
            role: RoleType.user,
            userInputMultiContent: [MessageInputPart.text('user')],
            assistantGenMultiContent: const [
              MessageOutputPart(
                type: ChatMessagePartType.text,
                text: 'assistant',
              ),
            ],
          ),
        ),
        throwsA(
          _formatError(
            'a message cannot contain both UserInputMultiContent and '
            'AssistantGenMultiContent',
          ),
        ),
      );
    });

    test('error with nil image in UserInputMultiContent', () {
      expect(
        () => claudeMessageParam(
          const Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart(type: ChatMessagePartType.imageUrl),
            ],
          ),
        ),
        throwsA(_formatError('image field must not be nil')),
      );
    });

    test('error with nil image in AssistantGenMultiContent', () {
      expect(
        () => claudeMessageParam(
          const Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [
              MessageOutputPart(type: ChatMessagePartType.imageUrl),
            ],
          ),
        ),
        throwsA(_formatError('image field must not be nil')),
      );
    });

    test('unsupported part types and roles are rejected', () {
      expect(
        () => claudeMessageParam(
          Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart.audio(url: 'https://example.com/a.wav'),
            ],
          ),
        ),
        throwsA(_formatError('anthropic message type not supported: audio_url')),
      );
      expect(
        () => claudeMessageParam(
          Message(
            role: RoleType.assistant,
            userInputMultiContent: [MessageInputPart.text('x')],
          ),
        ),
        throwsA(
          _formatError(
            'user input multi content only support user role, got assistant',
          ),
        ),
      );
    });
  });

  group('TestPopulateToolChoice', () {
    Map<String, Object?> withTools(List<String> names) => {
          'tools': [
            for (final name in names) <String, Object?>{'name': name},
          ],
        };

    test('nil tool choice', () {
      final body = <String, Object?>{};
      populateClaudeToolChoice(body, null, null);
      expect(body.containsKey('tool_choice'), isFalse);
    });

    test('tool choice forbidden', () {
      final body = <String, Object?>{};
      populateClaudeToolChoice(body, ToolChoice.forbidden, null);
      expect(body['tool_choice'], {'type': 'none'});
    });

    test('tool choice allowed', () {
      final body = <String, Object?>{};
      populateClaudeToolChoice(body, ToolChoice.allowed, null);
      expect(body['tool_choice'], {'type': 'auto'});
    });

    test('tool choice allowed with disable parallel tool use', () {
      final body = <String, Object?>{};
      populateClaudeToolChoice(
        body,
        ToolChoice.allowed,
        null,
        disableParallelToolUse: true,
      );
      expect(
        body['tool_choice'],
        {'type': 'auto', 'disable_parallel_tool_use': true},
      );
    });

    test('tool choice forced with no tools', () {
      expect(
        () => populateClaudeToolChoice({}, ToolChoice.forced, null),
        throwsA(_argumentError('tool choice is forced but tool is not provided')),
      );
    });

    test('tool choice forced with one tool', () {
      final body = withTools(['test_tool']);
      populateClaudeToolChoice(body, ToolChoice.forced, null);
      expect(body['tool_choice'], {'type': 'tool', 'name': 'test_tool'});
    });

    test('tool choice forced with multiple tools', () {
      final body = withTools(['test_tool_1', 'test_tool_2']);
      populateClaudeToolChoice(body, ToolChoice.forced, null);
      expect(body['tool_choice'], {'type': 'any'});
    });

    test('tool choice forced with allowed tool name', () {
      final body = withTools(['test_tool_1', 'test_tool_2']);
      populateClaudeToolChoice(body, ToolChoice.forced, ['test_tool_1']);
      expect(body['tool_choice'], {'type': 'tool', 'name': 'test_tool_1'});
    });

    test('tool choice forced with non-existent allowed tool name', () {
      expect(
        () => populateClaudeToolChoice(
          withTools(['test_tool_1']),
          ToolChoice.forced,
          ['non_existent_tool'],
        ),
        throwsA(
          _argumentError(
            "allowed tool name 'non_existent_tool' not found in tools list",
          ),
        ),
      );
    });

    test('tool choice forced with multiple allowed tool names', () {
      expect(
        () => populateClaudeToolChoice(
          withTools(['test_tool_1']),
          ToolChoice.forced,
          ['test_tool_1', 'test_tool_2'],
        ),
        throwsA(_argumentError('only one allowed tool name can be configured')),
      );
    });

    test('allowed tool names with the tool choice allowed', () {
      expect(
        () => populateClaudeToolChoice(
          withTools(['a']),
          ToolChoice.allowed,
          ['a'],
        ),
        throwsA(
          _argumentError(
            "tool_choice 'allowed' is not supported when allowed tool names "
            'are present',
          ),
        ),
      );
    });

    test('forced with several tools and disable parallel tool use', () {
      final body = withTools(['a', 'b']);
      populateClaudeToolChoice(
        body,
        ToolChoice.forced,
        null,
        disableParallelToolUse: false,
      );
      expect(
        body['tool_choice'],
        {'type': 'any', 'disable_parallel_tool_use': false},
      );
    });
  });

  group('TestCacheTTL', () {
    test('withClaudeCacheControl without TTL', () {
      final message = Message.user('hello').withClaudeCacheControl();
      expect(claudeIsBreakpoint(message.extra), isTrue);
      expect(claudeBreakpointCacheControl(message.extra), isNull);
    });

    test('SetMessageCacheControl with TTL', () {
      final message = Message.user('hello').withClaudeCacheControl(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
      );
      expect(claudeIsBreakpoint(message.extra), isTrue);
      expect(
        claudeBreakpointCacheControl(message.extra)!.ttl,
        ClaudeCacheTtl.oneHour,
      );
    });

    test('withClaudeCacheControl on a tool without TTL', () {
      final tool = _tool('test').withClaudeCacheControl();
      expect(claudeIsBreakpoint(tool.extra), isTrue);
      expect(claudeBreakpointCacheControl(tool.extra), isNull);
    });

    test('SetToolInfoCacheControl with TTL', () {
      final tool = _tool('test').withClaudeCacheControl(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.fiveMinutes),
      );
      expect(claudeIsBreakpoint(tool.extra), isTrue);
      expect(
        claudeBreakpointCacheControl(tool.extra)!.ttl,
        ClaudeCacheTtl.fiveMinutes,
      );
    });

    test('newCacheControlParam without TTL', () {
      expect(claudeCacheControlParam(null), {'type': 'ephemeral'});
    });

    test('newCacheControlParam with TTL', () {
      expect(
        claudeCacheControlParam(
          const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
        ),
        {'type': 'ephemeral', 'ttl': '1h'},
      );
    });

    test('newCacheControlParam with invalid TTL passthrough', () {
      expect(
        claudeCacheControlParam(
          const ClaudeCacheControl(ttl: ClaudeCacheTtl('invalid_ttl')),
        ),
        {'type': 'ephemeral', 'ttl': 'invalid_ttl'},
      );
    });

    test('populateContentBlockBreakPoint with TTL', () {
      final block = <String, Object?>{'type': 'text', 'text': 'input'};
      populateClaudeBlockBreakpoint(
        block,
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
      );
      expect(block['cache_control'], {'type': 'ephemeral', 'ttl': '1h'});
    });

    test('manual breakpoint TTL flows to params', () {
      final body = _body([
        Message.system('system').withClaudeCacheControl(
          const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
        ),
        Message.user('hello'),
      ]);
      expect(
        (body['system']! as List).cast<Map<String, Object?>>()[0]
            ['cache_control'],
        {'type': 'ephemeral', 'ttl': '1h'},
      );
    });

    test('WithAutoCacheControl with TTL', () {
      final body = _body(
        [Message.system('system'), Message.user('hello')],
        options: _claude(
          const ClaudeRequestOptions(
            autoCacheControl: ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
          ),
        ),
      );
      expect(
        (body['system']! as List).cast<Map<String, Object?>>()[0]
            ['cache_control'],
        {'type': 'ephemeral', 'ttl': '1h'},
      );
    });
  });

  group('TestToolSearchResultInput', () {
    test('tool search result in tool message', () {
      final result = claudeMessageParam(
        Message(
          role: RoleType.tool,
          toolCallId: 'tool_search_call_1',
          userInputMultiContent: [
            MessageInputPart(
              type: ChatMessagePartType.toolSearchResult,
              toolSearchResult: ToolSearchResult(
                tools: [_tool('found_tool_1'), _tool('found_tool_2')],
              ),
            ),
          ],
        ),
      );
      expect(result['role'], 'user');
      expect(_contentOf(result), [
        {
          'type': 'tool_result',
          'tool_use_id': 'tool_search_call_1',
          'content': [
            {'type': 'tool_reference', 'tool_name': 'found_tool_1'},
            {'type': 'tool_reference', 'tool_name': 'found_tool_2'},
          ],
        },
      ]);
    });

    test('nil ToolSearchResult errors', () {
      expect(
        () => claudeMessageParam(
          const Message(
            role: RoleType.tool,
            toolCallId: 'call_1',
            userInputMultiContent: [
              MessageInputPart(type: ChatMessagePartType.toolSearchResult),
            ],
          ),
        ),
        throwsA(_formatError('ToolSearchResult field must not be nil')),
      );
    });

    test('the found tools are added to the request, deferred', () {
      final body = _body(
        [
          Message.user('find a tool'),
          Message(
            role: RoleType.tool,
            toolCallId: 'call_1',
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.toolSearchResult,
                toolSearchResult: ToolSearchResult(tools: [_tool('found')]),
              ),
            ],
          ),
        ],
        bound: [_tool('existing')],
      );
      final tools = (body['tools']! as List).cast<Map<String, Object?>>();
      expect(tools.map((t) => t['name']), ['existing', 'found']);
      expect(tools[1]['defer_loading'], isTrue);
      expect(tools[0].containsKey('defer_loading'), isFalse);
    });
  });

  test('TestDuplicateToolError', () {
    final body = <String, Object?>{
      'tools': [
        <String, Object?>{'name': 'existing_tool'},
      ],
    };
    expect(
      () => populateClaudeToolSearchResultTools(body, [
        Message(
          role: RoleType.tool,
          toolCallId: 'call_1',
          userInputMultiContent: [
            MessageInputPart(
              type: ChatMessagePartType.toolSearchResult,
              toolSearchResult: ToolSearchResult(
                tools: [_tool('existing_tool')],
              ),
            ),
          ],
        ),
      ]),
      throwsA(
        _formatError(
          "tool 'existing_tool' from ToolSearchResult already exists in tool "
          'list',
        ),
      ),
    );
  });

  group('TestToolSearchEventsRoundTrip', () {
    test('server tool use event round trip', () {
      final extra = <String, dynamic>{};
      claudeAppendToolSearchEvent(
        extra,
        const ClaudeToolSearchEvent(
          type: ClaudeToolSearchEventType.serverToolUse,
          id: 'stu_1',
          name: 'tool_search_tool_bm25',
          input: {'query': 'search query'},
        ),
      );
      claudeAppendToolSearchEvent(
        extra,
        const ClaudeToolSearchEvent(
          type: ClaudeToolSearchEventType.toolSearchToolResult,
          toolUseId: 'stu_1',
          content: ClaudeToolSearchEventContent(
            type: 'tool_search_tool_search_result',
            toolReferences: [ClaudeToolSearchEventToolReference('matched_tool')],
          ),
        ),
      );
      final message = Message(role: RoleType.assistant, extra: extra);
      expect(message.claudeToolSearchEvents, hasLength(2));

      final content = _contentOf(claudeMessageParam(message));
      expect(content, [
        {
          'type': 'server_tool_use',
          'id': 'stu_1',
          'name': 'tool_search_tool_bm25',
          'input': {'query': 'search query'},
        },
        {
          'type': 'tool_search_tool_result',
          'tool_use_id': 'stu_1',
          'content': {
            'type': 'tool_search_tool_search_result',
            'tool_references': [
              {'type': 'tool_reference', 'tool_name': 'matched_tool'},
            ],
          },
        },
      ]);
    });

    test('error event round trip', () {
      final extra = <String, dynamic>{};
      claudeAppendToolSearchEvent(
        extra,
        const ClaudeToolSearchEvent(
          type: ClaudeToolSearchEventType.toolSearchToolResult,
          toolUseId: 'stu_2',
          content: ClaudeToolSearchEventContent(
            type: 'tool_search_tool_result_error',
            errorCode: 'unavailable',
          ),
        ),
      );
      final content =
          _contentOf(claudeMessageParam(Message(role: RoleType.assistant, extra: extra)));
      expect(content.first, {
        'type': 'tool_search_tool_result',
        'tool_use_id': 'stu_2',
        'content': {
          'type': 'tool_search_tool_result_error',
          'error_code': 'unavailable',
        },
      });
    });
  });

  group('TestPopulateInputMergeConsecutiveTools', () {
    Message toolMsg(String id, String name, String content) =>
        Message.tool(content: content, toolCallId: id, toolName: name);

    test('single tool message unchanged', () {
      final messages = _messages(
        _body([Message.user('hello'), toolMsg('call_1', 'tool1', 'result1')]),
      );
      expect(messages, hasLength(2));
      expect(_contentOf(messages[1]).single, {
        'type': 'tool_result',
        'tool_use_id': 'call_1',
        'content': [
          {'type': 'text', 'text': 'result1'},
        ],
        'is_error': false,
      });
    });

    test('two consecutive tool messages merged', () {
      final messages = _messages(
        _body([
          Message.user('hello'),
          toolMsg('call_1', 'tool1', 'result1'),
          toolMsg('call_2', 'tool2', 'result2'),
        ]),
      );
      expect(messages, hasLength(2));
      expect(_contentOf(messages[1]), hasLength(2));
    });

    test('three consecutive tools merged', () {
      final messages = _messages(
        _body([
          Message.user('hello'),
          toolMsg('call_1', 't1', 'r1'),
          toolMsg('call_2', 't2', 'r2'),
          toolMsg('call_3', 't3', 'r3'),
        ]),
      );
      expect(messages, hasLength(2));
      expect(_contentOf(messages[1]), hasLength(3));
    });

    test('tool messages separated by non-tool are not merged', () {
      final messages = _messages(
        _body([
          Message.user('hello'),
          toolMsg('call_1', 't1', 'r1'),
          Message.assistant('ok'),
          toolMsg('call_2', 't2', 'r2'),
        ]),
      );
      expect(messages, hasLength(4));
      expect(_contentOf(messages[1]), hasLength(1));
      expect(_contentOf(messages[3]), hasLength(1));
    });

    test('no tool messages unchanged', () {
      final messages =
          _messages(_body([Message.user('hello'), Message.assistant('hi')]));
      expect(messages, hasLength(2));
    });

    test('real world pattern: user assistant(tool_calls) tool tool', () {
      final messages = _messages(
        _body([
          Message.user("what's the weather in Paris and London?"),
          Message.assistant(
            '',
            toolCalls: const [
              ToolCall(
                id: 'call_1',
                function: FunctionCall(
                  name: 'get_weather',
                  arguments: '{"city":"Paris"}',
                ),
              ),
              ToolCall(
                id: 'call_2',
                function: FunctionCall(
                  name: 'get_weather',
                  arguments: '{"city":"London"}',
                ),
              ),
            ],
          ),
          toolMsg('call_1', 'get_weather', 'Paris: sunny, 22C'),
          toolMsg('call_2', 'get_weather', 'London: cloudy, 15C'),
        ]),
      );
      expect(messages, hasLength(3));
      expect(messages[1]['role'], 'assistant');
      expect(_contentOf(messages[1]), [
        {
          'type': 'tool_use',
          'id': 'call_1',
          'input': {'city': 'Paris'},
          'name': 'get_weather',
        },
        {
          'type': 'tool_use',
          'id': 'call_2',
          'input': {'city': 'London'},
          'name': 'get_weather',
        },
      ]);
      expect(messages[2]['role'], 'user');
      expect(_contentOf(messages[2]), hasLength(2));
    });

    test('consecutive mid-conversation system messages are merged', () {
      final messages = _messages(
        _body([
          Message.user('hello'),
          Message.system('a'),
          Message.system('b'),
        ]),
      );
      expect(messages, hasLength(2));
      expect(messages[1]['role'], 'system');
      expect(_contentOf(messages[1]), [
        {'type': 'text', 'text': 'a'},
        {'type': 'text', 'text': 'b'},
      ]);
    });
  });

  group('TestInputFileID', () {
    const id = 'file-123';
    final parts = [
      MessageInputPart(
        type: ChatMessagePartType.imageUrl,
        image: const MessageInputImage(common: MessagePartCommon(fileId: id)),
      ),
      MessageInputPart.file(fileId: id),
      MessageInputPart(
        type: ChatMessagePartType.imageUrl,
        image: const MessageInputImage(
          common: MessagePartCommon(url: '', base64Data: '', fileId: id),
        ),
      ),
      MessageInputPart.file(url: '', base64Data: '', fileId: id),
    ];

    for (final (index, part) in parts.indexed) {
      for (final role in [RoleType.user, RoleType.tool]) {
        test('part $index as ${role.name}', () {
          final param = claudeMessageParam(
            Message(
              role: role,
              toolCallId: 'call-1',
              userInputMultiContent: [part],
            ),
          );
          final decoded = jsonDecode(jsonEncode(param)) as Map<String, Object?>;
          var block = (decoded['content']! as List).first as Map;
          if (role == RoleType.tool) {
            block = (block['content']! as List).first as Map;
          }
          expect(block['type'], part.type == ChatMessagePartType.imageUrl ? 'image' : 'document');
          expect(block['source'], {'type': 'file', 'file_id': id});
        });
      }
    }

    test('an empty file id is rejected', () {
      expect(
        () => claudeMessageParam(
          Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.imageUrl,
                image: const MessageInputImage(
                  common: MessagePartCommon(fileId: ''),
                ),
              ),
            ],
          ),
        ),
        throwsA(_formatError('FileID must not be empty')),
      );
    });
  });

  group('TestInputFileIDPrecedence', () {
    const id = 'file-123';
    const url = 'https://example.com/media';
    const base64Data = 'YWJj';
    const invalidBase64 = 'data:image/png;base64,YWJj';

    final media = <String, Message Function(MessagePartCommon)>{
      'user_image': (common) => Message(
            role: RoleType.user,
            toolCallId: 'call-1',
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.imageUrl,
                image: MessageInputImage(common: common),
              ),
            ],
          ),
      'tool_image': (common) => Message(
            role: RoleType.tool,
            toolCallId: 'call-1',
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.imageUrl,
                image: MessageInputImage(common: common),
              ),
            ],
          ),
      'user_file': (common) => Message(
            role: RoleType.user,
            toolCallId: 'call-1',
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.fileUrl,
                file: MessageInputFile(common: common),
              ),
            ],
          ),
      'tool_file': (common) => Message(
            role: RoleType.tool,
            toolCallId: 'call-1',
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.fileUrl,
                file: MessageInputFile(common: common),
              ),
            ],
          ),
    };
    const cases = <String, MessagePartCommon>{
      'URL': MessagePartCommon(url: url),
      'Base64Data': MessagePartCommon(
        base64Data: base64Data,
        mimeType: 'image/png',
      ),
      'URL_and_Base64Data': MessagePartCommon(
        url: url,
        base64Data: base64Data,
        mimeType: 'image/png',
      ),
      'invalid_Base64Data': MessagePartCommon(
        base64Data: invalidBase64,
        mimeType: 'image/png',
      ),
      'missing_MIMEType': MessagePartCommon(base64Data: base64Data),
    };

    Object outcome(Message Function(MessagePartCommon) convert,
        MessagePartCommon common) {
      try {
        return jsonEncode(claudeMessageParam(convert(common)));
      } on ThreepioFormatException catch (error) {
        return 'error: ${error.message}';
      }
    }

    for (final MapEntry(key: mediaName, value: convert) in media.entries) {
      group(mediaName, () {
        for (final MapEntry(key: caseName, value: common) in cases.entries) {
          test(caseName, () {
            final want = outcome(convert, common);
            final got = outcome(convert, common.copyWith(fileId: id));
            expect(got, want, reason: 'FileID changed the selected source');
          });
        }
      });
    }
  });

  group('request body (port)', () {
    test('config settings, per-call options and headers', () {
      const config = ClaudeConfig(
        apiKey: 'test-key',
        authToken: 'test-token',
        baseUrl: 'https://proxy.example.com/',
        model: testModel,
        maxTokens: 2048,
        temperature: 0.5,
        topP: 0.9,
        topK: 40,
        stopSequences: ['\n\nHuman:'],
        disableParallelToolUse: true,
        responseFormat: ClaudeResponseFormat(
          schema: {
            'type': 'object',
            'properties': {
              'answer': {'type': 'string'},
            },
          },
        ),
        additionalHeaderFields: {'anthropic-beta': 'files-api-2025-04-14'},
        additionalRequestFields: {
          'metadata': {'user_id': 'u1'},
          'thinking.display': 'summarized',
          r'service\.tier': 'auto',
        },
        thinkingConfig: ClaudeThinkingConfig.enabled(budgetTokens: 1024),
      );
      final request = _request(
        [Message.user('hi')],
        config: config,
        bound: [_tool('get_weather')],
        options: const ChatModelOptions(
          temperature: 0.1,
          extensions: [
            ClaudeRequestOptions(
              topK: 5,
              requestTimeout: Duration(seconds: 3),
              customHeaders: {'Anthropic-Beta': 'other-beta', 'x-trace': '1'},
            ),
          ],
        ),
        stream: true,
      );

      expect(
        request.url,
        Uri.parse('https://proxy.example.com/v1/messages'),
      );
      expect(request.timeout, const Duration(seconds: 3));
      expect(request.headers, {
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        'anthropic-version': '2023-06-01',
        'x-api-key': 'test-key',
        'authorization': 'Bearer test-token',
        'anthropic-beta': 'files-api-2025-04-14, other-beta',
        'x-trace': '1',
      });
      expect(request.body, {
        'model': testModel,
        'max_tokens': 2048,
        'temperature': 0.1,
        'top_p': 0.9,
        'stop_sequences': ['\n\nHuman:'],
        'top_k': 5,
        'thinking': {
          'type': 'enabled',
          'budget_tokens': 1024,
          'display': 'summarized',
        },
        'output_config': {
          'format': {
            'type': 'json_schema',
            'schema': {
              'type': 'object',
              'properties': {
                'answer': {'type': 'string'},
              },
            },
          },
        },
        'tools': [
          {
            'name': 'get_weather',
            'description': 'desc of get_weather',
            'input_schema': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
              'required': ['city'],
            },
          },
        ],
        'tool_choice': {'type': 'auto', 'disable_parallel_tool_use': true},
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        ],
        'metadata': {'user_id': 'u1'},
        'service.tier': 'auto',
        'stream': true,
      });
    });

    test('generate requests send no stream flag and accept JSON', () {
      final request = _request([Message.user('hi')]);
      expect(request.body.containsKey('stream'), isFalse);
      expect(request.headers['accept'], 'application/json');
      expect(request.timeout, ClaudeConfig.defaultTimeout);
      expect(request.headers.containsKey('authorization'), isFalse);
    });

    test('the model and max tokens of a call win', () {
      final body = _body(
        [Message.user('hi')],
        options: const ChatModelOptions(model: 'other-model', maxTokens: 7),
      );
      expect(body['model'], 'other-model');
      expect(body['max_tokens'], 7);
    });

    test('the ClaudeRequestOptions merged last win, field by field', () {
      final options = const ClaudeRequestOptions(topK: 1, disableParallelToolUse: true)
          .toOptions()
          .merge(const ClaudeRequestOptions(topK: 2).toOptions());
      final body = _body(
        [Message.user('hi')],
        bound: [_tool('t')],
        options: options,
      );
      expect(body['top_k'], 2);
      expect(
        body['tool_choice'],
        {'type': 'auto', 'disable_parallel_tool_use': true},
      );
    });

    test('a tool without parameters gets an empty object schema', () {
      final body = _body(
        [Message.user('hi')],
        options: ChatModelOptions(tools: [ToolInfo.function(name: 'now')]),
      );
      expect(body['tools'], [
        {
          'name': 'now',
          'description': '',
          'input_schema': {'type': 'object'},
        },
      ]);
      // Tools given for a call come without a tool choice.
      expect(body.containsKey('tool_choice'), isFalse);
    });

    test('an empty tool list of a call leaves no tools', () {
      final body = _body(
        [Message.user('hi')],
        bound: [_tool('t')],
        options: const ChatModelOptions(tools: []),
      );
      expect(body.containsKey('tools'), isFalse);
      // The bound tools' tool choice stays, as in Go.
      expect(body['tool_choice'], {'type': 'auto'});
    });

    test('a forced call with bound tools names the only tool', () {
      final body = _body(
        [Message.user('hi')],
        bound: [_tool('t')],
        options: const ChatModelOptions(toolChoice: ToolChoice.forced),
      );
      expect(body['tool_choice'], {'type': 'tool', 'name': 't'});
    });

    test('tool breakpoints and nested properties', () {
      final tool = ToolInfo.fromJsonSchema(
        name: 'search',
        schema: const JSONSchema(
          properties: {
            'filters': JSONSchemaProperty(
              type: 'object',
              description: 'Filters',
              properties: {
                'tags': JSONSchemaProperty(
                  type: 'array',
                  items: JSONSchemaProperty(type: 'string', enumValues: ['a']),
                ),
              },
              required: ['tags'],
              additionalProperties: false,
            ),
          },
        ),
      ).withClaudeCacheControl(
        const ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
      );
      final params = claudeToolParams([tool]);
      expect(params.single, {
        'name': 'search',
        'description': '',
        'input_schema': {
          'type': 'object',
          'properties': {
            'filters': {
              'type': 'object',
              'description': 'Filters',
              'properties': {
                'tags': {
                  'type': 'array',
                  'items': {
                    'type': 'string',
                    'enum': ['a'],
                  },
                },
              },
              'required': ['tags'],
              'additionalProperties': false,
            },
          },
        },
        'cache_control': {'type': 'ephemeral', 'ttl': '1h'},
      });
    });

    test('auto cache control: last tool, last system, last message', () {
      final body = _body(
        [
          Message.system('s1'),
          Message.system('s2'),
          Message.user('u1'),
          Message.assistant('a1'),
          Message.user('u2'),
        ],
        config: const ClaudeConfig(
          model: testModel,
          maxTokens: 10,
          autoCacheControl: ClaudeCacheControl(),
        ),
        bound: [_tool('a'), _tool('b')],
      );
      final tools = (body['tools']! as List).cast<Map<String, Object?>>();
      expect(tools[0].containsKey('cache_control'), isFalse);
      expect(tools[1]['cache_control'], {'type': 'ephemeral'});
      final system = (body['system']! as List).cast<Map<String, Object?>>();
      expect(system[0].containsKey('cache_control'), isFalse);
      expect(system[1]['cache_control'], {'type': 'ephemeral'});
      final messages = _messages(body);
      expect(_contentOf(messages.last).last['cache_control'], {'type': 'ephemeral'});
      expect(_contentOf(messages[0]).last.containsKey('cache_control'), isFalse);
    });

    test('auto cache control keeps breakpoints the caller set', () {
      final body = _body(
        [
          Message.system('s1').withClaudeCacheControl(),
          Message.system('s2'),
          Message.user('u1').withClaudeCacheControl(),
          Message.assistant('a1'),
          Message.user('u2'),
        ],
        options: _claude(
          const ClaudeRequestOptions(autoCacheControl: ClaudeCacheControl()),
        ),
        bound: [_tool('a').withClaudeCacheControl(), _tool('b')],
      );
      final tools = (body['tools']! as List).cast<Map<String, Object?>>();
      expect(tools[1].containsKey('cache_control'), isFalse);
      final system = (body['system']! as List).cast<Map<String, Object?>>();
      expect(system[1].containsKey('cache_control'), isFalse);
      final messages = _messages(body);
      expect(_contentOf(messages[0]).last['cache_control'], isNotNull);
      expect(_contentOf(messages.last).last.containsKey('cache_control'), isFalse);
    });

    test('disableAutoCacheControl turns the config off for a call', () {
      final body = _body(
        [Message.system('s'), Message.user('u')],
        config: const ClaudeConfig(
          model: testModel,
          maxTokens: 10,
          autoCacheControl: ClaudeCacheControl(),
        ),
        options: _claude(
          const ClaudeRequestOptions(disableAutoCacheControl: true),
        ),
      );
      expect(
        (body['system']! as List).cast<Map<String, Object?>>()[0]
            .containsKey('cache_control'),
        isFalse,
      );
    });

    test('deferred tools, tool search algorithm and a tool search tool', () {
      final body = _body(
        [Message.user('hi')],
        bound: [_tool('visible')],
        options: ChatModelOptions(
          deferredTools: [_tool('hidden')],
          toolSearchTool: _tool('my_search'),
        ),
      );
      final tools = (body['tools']! as List).cast<Map<String, Object?>>();
      expect(tools.map((t) => t['name']), [
        'visible',
        'hidden',
        'tool_search_tool_bm25',
        'my_search',
      ]);
      expect(tools[1]['defer_loading'], isTrue);
      expect(tools[2], {
        'type': 'tool_search_tool_bm25_20251119',
        'name': 'tool_search_tool_bm25',
      });

      final regex = _body(
        [Message.user('hi')],
        config: const ClaudeConfig(
          model: testModel,
          maxTokens: 10,
          toolSearchAlgorithm: ClaudeToolSearchAlgorithm.regex,
        ),
      );
      expect(regex['tools'], [
        {
          'type': 'tool_search_tool_regex_20251119',
          'name': 'tool_search_tool_regex',
        },
      ]);
    });

    test('thinking with a signature is sent back first; without, dropped', () {
      final extra = <String, dynamic>{};
      claudeSetThinking(extra, 'I thought');
      claudeSetThinkingSignature(extra, 'sig');
      final withSignature = claudeMessageParam(
        Message(
          role: RoleType.assistant,
          content: 'answer',
          extra: extra,
          toolCalls: const [
            ToolCall(id: 't1', function: FunctionCall(name: 'f', arguments: '')),
          ],
        ),
      );
      expect(_contentOf(withSignature), [
        {'type': 'thinking', 'signature': 'sig', 'thinking': 'I thought'},
        {'type': 'text', 'text': 'answer'},
        {
          'type': 'tool_use',
          'id': 't1',
          'input': <String, Object?>{},
          'name': 'f',
        },
      ]);

      final noSignature = <String, dynamic>{};
      claudeSetThinking(noSignature, 'I thought');
      expect(
        _contentOf(
          claudeMessageParam(
            Message(role: RoleType.assistant, content: 'a', extra: noSignature),
          ),
        ),
        [
          {'type': 'text', 'text': 'a'},
        ],
      );
    });

    test('tool call arguments that are not JSON are rejected', () {
      expect(
        () => claudeMessageParam(
          Message.assistant(
            '',
            toolCalls: const [
              ToolCall(
                id: 't1',
                function: FunctionCall(name: 'f', arguments: '{oops'),
              ),
            ],
          ),
        ),
        throwsA(_formatError("arguments of tool call 't1' are not valid JSON")),
      );
    });

    test('a message breakpoint goes on its last block; empty messages get text',
        () {
      final param = claudeMessageParam(
        Message(
          role: RoleType.tool,
          toolCallId: 'c1',
          userInputMultiContent: [
            MessageInputPart.text('result'),
            MessageInputPart.imageUrl('https://example.com/x.png'),
          ],
        ).withClaudeCacheControl(),
      );
      expect(param, {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'c1',
            'content': [
              {'type': 'text', 'text': 'result'},
              {
                'type': 'image',
                'source': {'type': 'url', 'url': 'https://example.com/x.png'},
              },
            ],
            'cache_control': {'type': 'ephemeral'},
          },
        ],
      });
      expect(
        claudeMessageParam(const Message(role: RoleType.user)),
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': ''},
          ],
        },
      );
    });

    test('claudeSetJsonPath indexes lists as sjson does', () {
      final tools = [
        <String, Object?>{'name': 'a'},
        <String, Object?>{'name': 'b'},
      ];
      final body = <String, Object?>{
        'tools': tools,
        'stop_sequences': ['x'],
      };
      claudeSetJsonPath(body, 'tools.0.cache_control', {'type': 'ephemeral'});
      claudeSetJsonPath(body, 'stop_sequences.-1', 'y');
      claudeSetJsonPath(body, 'stop_sequences.4', 'z');
      claudeSetJsonPath(body, 'new_list.1.k', 1);
      claudeSetJsonPath(body, 'appended.-1', true);
      claudeSetJsonPath(body, 'metadata.:42', 'forced key');
      claudeSetJsonPath(body, r'odd\:key', 1);
      expect(body, {
        'tools': [
          {
            'name': 'a',
            'cache_control': {'type': 'ephemeral'},
          },
          {'name': 'b'},
        ],
        'stop_sequences': ['x', 'y', null, null, 'z'],
        'new_list': [
          null,
          {'k': 1},
        ],
        'appended': [true],
        'metadata': {'42': 'forced key'},
        'odd:key': 1,
      });
      // The caller's list and maps are not changed.
      expect(tools[0].containsKey('cache_control'), isFalse);

      expect(
        () => claudeSetJsonPath(body, 'tools.name', 'x'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "cannot set array element for non-numeric key 'name'",
          ),
        ),
      );
    });

    test('additionalRequestFields can reach into the tools', () {
      final body = _body(
        [Message.user('hi')],
        config: const ClaudeConfig(
          model: testModel,
          maxTokens: 10,
          additionalRequestFields: {'tools.0.strict': true},
        ),
        bound: [_tool('t')],
      );
      expect(((body['tools']! as List).single as Map)['strict'], isTrue);
    });

    test('claudeSetJsonPath replaces non-objects and copies objects', () {
      final body = <String, Object?>{'a': 1};
      claudeSetJsonPath(body, 'a.b.c', true);
      expect(body, {
        'a': {
          'b': {'c': true},
        },
      });

      const schema = {'type': 'object'};
      final withSchema = _body(
        [Message.user('hi')],
        config: const ClaudeConfig(
          model: testModel,
          maxTokens: 10,
          thinkingConfig: ClaudeThinkingConfig.disabled(),
          responseFormat: ClaudeResponseFormat(schema: schema),
          additionalRequestFields: {
            'output_config.format.schema.title': 'Answer',
            'thinking.note': 'x',
          },
        ),
      );
      expect(
        ((withSchema['output_config']! as Map)['format']! as Map)['schema'],
        {'type': 'object', 'title': 'Answer'},
      );
      expect(withSchema['thinking'], {'type': 'disabled', 'note': 'x'});
      expect(schema, {'type': 'object'});
    });
  });

  group('responses (port)', () {
    test('a complete response with thinking, text and tool use', () {
      final message = claudeOutputMessage(
        messageResponse(
          [
            {'type': 'thinking', 'thinking': 'Hmm.', 'signature': 'sig1'},
            {'type': 'redacted_thinking', 'data': 'opaque'},
            textBlock('Let me check. '),
            textBlock('One moment.'),
            toolUseBlock('toolu_1', 'get_weather', {'city': 'Paris'}),
            toolUseBlock('toolu_2', 'now', {}),
          ],
          stopReason: 'tool_use',
          usage: {
            'input_tokens': 100,
            'cache_read_input_tokens': 1024,
            'cache_creation_input_tokens': 2048,
            'output_tokens': 50,
          },
        ),
      );
      expect(message.role, RoleType.assistant);
      expect(message.content, 'Let me check. One moment.');
      expect(message.reasoningContent, 'Hmm.');
      expect(message.claudeThinking, 'Hmm.');
      expect(claudeThinkingSignatureOf(message.extra), 'sig1');
      expect(message.toolCalls, [
        const ToolCall(
          index: 0,
          id: 'toolu_1',
          function: FunctionCall(
            name: 'get_weather',
            arguments: '{"city":"Paris"}',
          ),
        ),
        const ToolCall(
          index: 1,
          id: 'toolu_2',
          function: FunctionCall(name: 'now', arguments: ''),
        ),
      ]);
      final meta = message.responseMeta!;
      expect(meta.finishReason, 'tool_use');
      expect(meta.usage!.promptTokens, 100 + 1024 + 2048);
      expect(meta.usage!.totalTokens, 100 + 1024 + 2048 + 50);
      expect(meta.usage!.promptTokenDetails!.cachedTokens, 1024);
      expect(meta.usage!.promptTokenDetails!.cacheWriteTokens, 2048);
      expect(message.claudeCacheCreationInputTokens, 2048);
    });

    test('server tool use and tool search results become events', () {
      final message = claudeOutputMessage(
        messageResponse([
          {
            'type': 'server_tool_use',
            'id': 'srvtoolu_1',
            'name': 'tool_search_tool_regex',
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
        ]),
      );
      final events = message.claudeToolSearchEvents;
      expect(events, hasLength(2));
      expect(events[0].type, ClaudeToolSearchEventType.serverToolUse);
      expect(events[0].input, {'query': 'weather'});
      expect(events[1].content!.toolReferences.single.toolName, 'get_weather');
    });

    test('unsupported blocks throw, as in Go', () {
      expect(
        () => claudeOutputMessage(
          messageResponse([
            {'type': 'web_search_tool_result', 'tool_use_id': 'x'},
          ]),
        ),
        throwsA(_formatError('web_search tool not supported')),
      );
      expect(
        () => claudeOutputMessage(
          messageResponse([
            {
              'type': 'server_tool_use',
              'id': 'x',
              'name': 'web_search',
              'input': <String, Object?>{},
            },
          ]),
        ),
        throwsA(_formatError('server_tool_use not supported: web_search')),
      );
      expect(
        () => claudeOutputMessage(messageResponse([{'type': 'hologram'}])),
        throwsA(_formatError('unknown anthropic content block type: hologram')),
      );
    });

    test('isClaudeMessageEmpty', () {
      expect(isClaudeMessageEmpty(const Message(role: RoleType.assistant)), isTrue);
      final thinking = <String, dynamic>{};
      claudeSetThinking(thinking, '');
      expect(
        isClaudeMessageEmpty(Message(role: RoleType.assistant, extra: thinking)),
        isFalse,
      );
      expect(isClaudeMessageEmpty(Message.assistant('x')), isFalse);
    });
  });
}
