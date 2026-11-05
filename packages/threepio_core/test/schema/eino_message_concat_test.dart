// Ports of TestConcatMessage, TestConcatToolCalls, TestConcatToolResults and
// TestConvToolOutputPartToMessageInputPart of eino `schema/message_test.go`
// (v0.9.22).
//
// Where a Go chunk leaves the role empty, the Dart chunk repeats the role: a
// Dart message always has one. The deprecated `MultiContent` cases are not
// ported.
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/streaming.dart';

Message assistant({
  String content = '',
  String? name,
  String? toolCallId,
  List<ToolCall>? toolCalls,
  ResponseMeta? responseMeta,
  List<MessageOutputPart>? parts,
  Map<String, dynamic>? extra,
}) =>
    Message(
      role: RoleType.assistant,
      content: content,
      name: name,
      toolCallId: toolCallId,
      toolCalls: toolCalls,
      responseMeta: responseMeta,
      assistantGenMultiContent: parts,
      extra: extra,
    );

ToolCall call({
  int? index,
  String id = '',
  String type = '',
  String name = '',
  String arguments = '',
}) =>
    ToolCall(
      index: index,
      id: id,
      type: type,
      function: FunctionCall(name: name, arguments: arguments),
    );

/// Go's unexported `concatToolCalls`, reached through a message.
List<ToolCall> concatToolCalls(List<ToolCall> chunks) =>
    concatMessages([assistant(toolCalls: chunks)]).toolCalls!;

MessageOutputPart textPart(
  String text, {
  Map<String, dynamic>? extra,
  int? index,
}) =>
    MessageOutputPart(
      type: ChatMessagePartType.text,
      text: text,
      extra: extra,
      streamingMeta: index == null ? null : MessageStreamingMeta(index: index),
    );

MessageOutputPart reasoningPart(
  String text, {
  String signature = '',
  Map<String, dynamic>? extra,
  int? index,
}) =>
    MessageOutputPart(
      type: ChatMessagePartType.reasoning,
      reasoning: MessageOutputReasoning(text: text, signature: signature),
      extra: extra,
      streamingMeta: index == null ? null : MessageStreamingMeta(index: index),
    );

MessageOutputPart audioPart(
  String base64, {
  String? mimeType,
  Map<String, dynamic>? audioExtra,
  Map<String, dynamic>? extra,
}) =>
    MessageOutputPart(
      type: ChatMessagePartType.audioUrl,
      audio: MessagePartCommon(
        base64Data: base64,
        mimeType: mimeType,
        // ignore: deprecated_member_use_from_same_package
        extra: audioExtra,
      ),
      extra: extra,
    );

MessageOutputPart imagePart(String url) => MessageOutputPart(
      type: ChatMessagePartType.imageUrl,
      image: MessagePartCommon(url: url),
    );

/// The parts of the concatenation of one chunk per given part.
List<MessageOutputPart>? concatParts(List<MessageOutputPart> parts) =>
    concatMessages([
      for (final part in parts) assistant(parts: [part]),
    ]).assistantGenMultiContent;

final throwsConcatError = throwsA(isA<ArgumentError>());

Matcher throwsConcatErrorWith(String text) => throwsA(
      isA<MessageConcatException>().having((e) => e.message, 'message', contains(text)),
    );

void main() {
  group('concatMessages (TestConcatMessage)', () {
    test('tool_call_normal_append', () {
      final message = concatMessages([
        assistant(toolCalls: [call(index: 0)]),
        assistant(
          toolCalls: [
            call(
              index: 0,
              id: 'i_am_a_too_call_id',
              type: 'function',
              name: 'i_am_a_tool_name',
            ),
          ],
        ),
        assistant(toolCalls: [call(index: 0, arguments: '{}')]),
      ]);

      expect(
        message,
        assistant(
          toolCalls: [
            call(
              index: 0,
              id: 'i_am_a_too_call_id',
              type: 'function',
              name: 'i_am_a_tool_name',
              arguments: '{}',
            ),
          ],
        ),
      );
    });

    test('response_meta', () {
      final chunks = [
        assistant(),
        assistant(
          responseMeta: const ResponseMeta(
            finishReason: '',
            usage: TokenUsage(
              completionTokens: 10,
              promptTokens: 20,
              totalTokens: 30,
              promptTokenDetails:
                  PromptTokenDetails(cachedTokens: 10, cacheWriteTokens: 12),
              completionTokenDetails:
                  CompletionTokenDetails(reasoningTokens: 5),
            ),
          ),
        ),
        assistant(responseMeta: const ResponseMeta(finishReason: 'stop')),
        assistant(
          responseMeta: const ResponseMeta(
            usage: TokenUsage(
              completionTokens: 15,
              promptTokens: 30,
              totalTokens: 45,
              promptTokenDetails:
                  PromptTokenDetails(cachedTokens: 15, cacheWriteTokens: 8),
              completionTokenDetails:
                  CompletionTokenDetails(reasoningTokens: 8),
            ),
          ),
        ),
      ];
      const usage = TokenUsage(
        completionTokens: 15,
        promptTokens: 30,
        totalTokens: 45,
        promptTokenDetails:
            PromptTokenDetails(cachedTokens: 15, cacheWriteTokens: 12),
        completionTokenDetails: CompletionTokenDetails(reasoningTokens: 8),
      );

      expect(
        concatMessages(chunks),
        assistant(
          responseMeta: const ResponseMeta(finishReason: 'stop', usage: usage),
        ),
      );

      chunks.add(
        assistant(responseMeta: const ResponseMeta(finishReason: 'tool_calls')),
      );
      expect(
        concatMessages(chunks),
        assistant(
          responseMeta:
              const ResponseMeta(finishReason: 'tool_calls', usage: usage),
        ),
      );
    });

    test('err: different roles', () {
      expect(
        () => concatMessages([Message.user(''), Message.assistant('')]),
        throwsConcatErrorWith('cannot concat messages with different roles'),
      );
    });

    test('err: different name', () {
      expect(
        () => concatMessages([
          assistant(name: 'n', content: '1'),
          assistant(name: 'a', content: '2'),
        ]),
        throwsConcatErrorWith('cannot concat messages with different names'),
      );
    });

    test('err: different tool name', () {
      expect(
        () => concatMessages([
          assistant(toolCallId: '123', toolCalls: [call(index: 0, id: 'abc')]),
          assistant(
            toolCallId: '321',
            toolCalls: [
              call(
                index: 0,
                id: 'abc',
                type: 'function',
                name: 'i_am_a_tool_name',
              ),
            ],
          ),
        ]),
        throwsConcatErrorWith(
          'cannot concat messages with different toolCallIDs',
        ),
      );
    });

    test('err: different tool names of tool messages', () {
      expect(
        () => concatMessages([
          Message.tool(content: 'a', toolCallId: '1', toolName: 'search'),
          Message.tool(content: 'b', toolCallId: '1', toolName: 'fetch'),
        ]),
        throwsConcatErrorWith('cannot concat messages with different toolNames'),
      );
    });

    test('first response meta usage is nil', () {
      final message = concatMessages([
        assistant(responseMeta: const ResponseMeta(finishReason: '')),
        assistant(responseMeta: const ResponseMeta(finishReason: 'stop')),
        assistant(
          responseMeta: const ResponseMeta(
            usage: TokenUsage(
              completionTokens: 15,
              promptTokens: 30,
              totalTokens: 45,
            ),
          ),
        ),
      ]);

      expect(
        message,
        assistant(
          responseMeta: const ResponseMeta(
            finishReason: 'stop',
            usage: TokenUsage(
              completionTokens: 15,
              promptTokens: 30,
              totalTokens: 45,
            ),
          ),
        ),
      );
    });

    test('concat of one-character chunks, repeatedly', () {
      const content = 'i_am_a_good_concat_message';
      final chunks = [
        for (final char in content.split('')) assistant(content: char),
      ];

      for (var i = 0; i < 100; i++) {
        expect(concatMessages(chunks), assistant(content: content));
      }
    });

    test('concat logprobs', () {
      const rocket = [
        LogProb(
          token: r'\xf0\x9f\x9a',
          logProb: -0.0000073458323,
          bytes: [240, 159, 154],
        ),
        LogProb(token: r'\x80', logProb: 0, bytes: [128]),
      ];
      const heart = [
        LogProb(
          token: '❤️',
          logProb: -0.0011431955,
          bytes: [226, 157, 164, 239, 184, 143],
        ),
      ];

      final message = concatMessages([
        assistant(
          content: '🚀',
          responseMeta: const ResponseMeta(logProbs: LogProbs(content: rocket)),
        ),
        assistant(
          content: '❤️',
          responseMeta: const ResponseMeta(logProbs: LogProbs(content: heart)),
        ),
        assistant(
          responseMeta: const ResponseMeta(
            finishReason: 'stop',
            usage: TokenUsage(
              promptTokens: 7,
              completionTokens: 3,
              totalTokens: 10,
            ),
          ),
        ),
      ]);

      expect(message.content, '🚀❤️');
      expect(message.responseMeta!.logProbs!.content, [...rocket, ...heart]);
    });

    test('the chunks are left as they were', () {
      final chunks = [
        assistant(content: '🚀'),
        assistant(content: '❤️', responseMeta: const ResponseMeta()),
        assistant(
          responseMeta: const ResponseMeta(
            finishReason: 'stop',
            usage: TokenUsage(
              promptTokens: 7,
              completionTokens: 3,
              totalTokens: 10,
            ),
          ),
        ),
      ];

      final message = concatMessages(chunks);

      expect(message.responseMeta, chunks[2].responseMeta);
      expect(chunks[0].responseMeta, isNull);
    });

    test('concat assistant multi content', () {
      const audio1 = 'dGVzdF9hdWRpb18x';
      const audio2 = 'dGVzdF9hdWRpb18y';

      expect(
        concatParts([
          textPart('Hello, '),
          textPart('world!'),
          audioPart(audio1),
          audioPart(audio2, mimeType: 'audio/wav'),
          imagePart('https://example.com/image1.png'),
          imagePart('https://example.com/image2.png'),
        ]),
        [
          textPart('Hello, world!'),
          audioPart('$audio1$audio2', mimeType: 'audio/wav'),
          imagePart('https://example.com/image1.png'),
          imagePart('https://example.com/image2.png'),
        ],
      );
    });

    test('concat assistant multi content with extra', () {
      expect(
        concatParts([
          audioPart('dGVzdF9hdWRpb18x', audioExtra: {'key1': 'val1'}),
          audioPart('dGVzdF9hdWRpb18y', audioExtra: {'key2': 'val2'}),
        ]),
        [
          audioPart(
            'dGVzdF9hdWRpb18xdGVzdF9hdWRpb18y',
            audioExtra: {'key1': 'val1', 'key2': 'val2'},
          ),
        ],
      );
    });

    test('concat assistant multi content with single extra', () {
      expect(
        concatParts([
          audioPart('dGVzdF9hdWRpb18x', audioExtra: {'key1': 'val1'}),
          audioPart('dGVzdF9hdWRpb18y'),
        ]),
        [
          audioPart(
            'dGVzdF9hdWRpb18xdGVzdF9hdWRpb18y',
            audioExtra: {'key1': 'val1'},
          ),
        ],
      );
    });

    test('concat text parts with extra', () {
      expect(
        concatParts([
          textPart('Hello ', extra: {'key1': 'val1'}),
          textPart('World', extra: {'key2': 'val2'}),
        ]),
        [
          textPart('Hello World', extra: {'key1': 'val1', 'key2': 'val2'}),
        ],
      );
    });

    test('concat text parts with single extra', () {
      expect(
        concatParts([
          textPart('Hello ', extra: {'key1': 'val1'}),
          textPart('World'),
        ]),
        [
          textPart('Hello World', extra: {'key1': 'val1'}),
        ],
      );
    });

    test('concat reasoning parts with extra', () {
      expect(
        concatParts([
          reasoningPart('First, ', extra: {'key1': 'val1'}),
          reasoningPart('I need to think.', extra: {'key2': 'val2'}),
        ]),
        [
          reasoningPart(
            'First, I need to think.',
            extra: {'key1': 'val1', 'key2': 'val2'},
          ),
        ],
      );
    });

    test('concat audio parts with outer extra', () {
      expect(
        concatParts([
          audioPart('dGVzdF9hdWRpb18x', extra: {'outer1': 'val1'}),
          audioPart('dGVzdF9hdWRpb18y', extra: {'outer2': 'val2'}),
        ]),
        [
          audioPart(
            'dGVzdF9hdWRpb18xdGVzdF9hdWRpb18y',
            extra: {'outer1': 'val1', 'outer2': 'val2'},
          ),
        ],
      );
    });

    test('concat reasoning parts', () {
      expect(
        concatParts([
          reasoningPart('First, '),
          reasoningPart('I need to think.'),
          textPart('Here is my answer.'),
        ]),
        [
          reasoningPart('First, I need to think.'),
          textPart('Here is my answer.'),
        ],
      );
    });

    test('concat reasoning parts with signature', () {
      expect(
        concatParts([
          reasoningPart('Step 1: '),
          reasoningPart('analyze.', signature: 'sig_abc'),
          reasoningPart(' Step 2: ', signature: 'sig_xyz'),
          reasoningPart('conclude.'),
        ]),
        [
          reasoningPart(
            'Step 1: analyze. Step 2: conclude.',
            signature: 'sig_xyz',
          ),
        ],
      );
    });

    test('concat with streaming meta index grouping', () {
      expect(
        concatParts([
          reasoningPart('Think ', index: 0),
          reasoningPart('more.', index: 0),
          textPart('Hello ', index: 1),
          textPart('world!', index: 1),
        ]),
        [
          reasoningPart('Think more.', index: 0),
          textPart('Hello world!', index: 1),
        ],
      );
    });

    test('concat with different streaming meta index should not merge', () {
      final parts = [
        textPart('First block ', index: 0),
        textPart('Second block ', index: 1),
        textPart('continues.', index: 0),
      ];

      expect(concatParts(parts), parts);
    });

    test('concat empty parts', () {
      expect(
        concatMessages([assistant(parts: const [])]).assistantGenMultiContent,
        anyOf(isNull, isEmpty),
      );
    });

    test('concat single part no merge needed', () {
      expect(concatParts([textPart('Single')]), [textPart('Single')]);
    });

    test('concat multiple consecutive text parts', () {
      expect(
        concatParts([
          textPart('One '),
          textPart('Two '),
          textPart('Three '),
          textPart('Four'),
        ]),
        [textPart('One Two Three Four')],
      );
    });

    test(
        'concat without streaming meta should not merge with streaming meta '
        'parts', () {
      final parts = [textPart('No meta '), textPart('With meta', index: 0)];

      expect(concatParts(parts), parts);
    });
  });

  group('concatMessages, beyond the Go tests', () {
    test('rejects an empty list', () {
      expect(() => concatMessages([]), throwsConcatError);
    });

    test('joins content and reasoning content', () {
      final message = concatMessages([
        const Message(role: RoleType.assistant, reasoningContent: 'Let me '),
        const Message(role: RoleType.assistant, reasoningContent: 'think.'),
        assistant(content: 'Hel'),
        assistant(content: 'lo'),
      ]);

      expect(message.reasoningContent, 'Let me think.');
      expect(message.content, 'Hello');
    });

    test('leaves absent fields absent', () {
      final message = concatMessages([assistant(content: 'a'), assistant()]);

      expect(message.reasoningContent, isNull);
      expect(message.toolCalls, isNull);
      expect(message.extra, isNull);
      expect(message.responseMeta, isNull);
      expect(message.assistantGenMultiContent, isNull);
      expect(message.userInputMultiContent, isNull);
    });

    test('keeps the highest cost and token details of the usage', () {
      final message = concatMessages([
        assistant(
          responseMeta: const ResponseMeta(
            usage: TokenUsage(
              promptTokens: 1,
              completionTokens: 1,
              totalTokens: 2,
              cost: 0.5,
              completionTokenDetails:
                  CompletionTokenDetails(imageTokens: 4, audioTokens: 1),
            ),
          ),
        ),
        assistant(
          responseMeta: const ResponseMeta(
            usage: TokenUsage(
              promptTokens: 1,
              completionTokens: 1,
              totalTokens: 2,
              cost: 0.25,
              completionTokenDetails:
                  CompletionTokenDetails(imageTokens: 2, audioTokens: 3),
            ),
          ),
        ),
      ]);

      final usage = message.responseMeta!.usage!;
      expect(usage.cost, 0.5);
      expect(usage.completionTokenDetails!.imageTokens, 4);
      expect(usage.completionTokenDetails!.audioTokens, 3);
      expect(usage.promptTokenDetails, isNull);
    });

    test('merges extras: strings join, numbers take the last, maps merge',
        () {
      final message = concatMessages([
        assistant(
          extra: {
            'text': 'ab',
            'count': 1,
            'flag': false,
            'nested': {'a': 1, 'text': 'x'},
            'once': 'only here',
          },
        ),
        assistant(
          extra: {
            'text': 'cd',
            'count': 2,
            'flag': true,
            'nested': {'b': 2, 'text': 'y'},
          },
        ),
      ]);

      expect(message.extra, {
        'text': 'abcd',
        'count': 2,
        'flag': true,
        'nested': {'a': 1, 'b': 2, 'text': 'xy'},
        'once': 'only here',
      });
    });

    test('appends list-valued extras (an addition to Eino)', () {
      final message = concatMessages([
        assistant(
          extra: {
            'reasoning_details': [
              {'type': 'reasoning.text', 'text': 'a'},
            ],
          },
        ),
        assistant(
          extra: {
            'reasoning_details': [
              {'type': 'reasoning.text', 'text': 'b'},
            ],
            'nested': {
              'items': [1],
            },
          },
        ),
        assistant(
          extra: {
            'nested': {
              'items': [2, 3],
            },
          },
        ),
      ]);

      expect(message.extra, {
        'reasoning_details': [
          {'type': 'reasoning.text', 'text': 'a'},
          {'type': 'reasoning.text', 'text': 'b'},
        ],
        'nested': {
          'items': [1, 2, 3],
        },
      });
    });

    test('ignores null next to a value in extras', () {
      final message = concatMessages([
        assistant(extra: {'a': null, 'b': 'x'}),
        assistant(extra: {'a': 'value', 'b': null}),
      ]);

      expect(message.extra, {'a': 'value', 'b': 'x'});
    });

    test('does not change the extras of the chunks', () {
      final first = {
        'items': [1],
      };
      final chunks = [assistant(extra: first), assistant(extra: first)];

      final message = concatMessages(chunks);

      expect(message.extra, {
        'items': [1, 1],
      });
      expect(first, {
        'items': [1],
      });
    });

    test('rejects extras that cannot be joined', () {
      final a = Object();
      final b = Object();

      expect(
        () => concatMessages([
          assistant(extra: {'handle': a}),
          assistant(extra: {'handle': b}),
        ]),
        throwsConcatErrorWith('failed to concat extra'),
      );
    });

    test('joins neighbouring text parts of user input', () {
      final message = concatMessages([
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.text('Look '),
            MessageInputPart.text('at '),
          ],
        ),
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.text('this:'),
            MessageInputPart.imageUrl('https://example.com/a.png'),
            MessageInputPart.text('and this:'),
          ],
        ),
      ]);

      expect(message.userInputMultiContent, [
        MessageInputPart.text('Look at this:'),
        MessageInputPart.imageUrl('https://example.com/a.png'),
        MessageInputPart.text('and this:'),
      ]);
    });

    test('audio given by URL is not joined', () {
      const urlAudio = MessageOutputPart(
        type: ChatMessagePartType.audioUrl,
        audio: MessagePartCommon(url: 'https://example.com/a.wav'),
      );

      expect(concatParts([urlAudio, urlAudio]), [urlAudio, urlAudio]);
    });

    test('MessageConcatenator.concat is concatMessages', () {
      final chunks = [
        assistant(content: 'a', toolCalls: [call(index: 1, id: 'x')]),
        assistant(content: 'b', toolCalls: [call(index: 0, id: 'y')]),
      ];

      expect(MessageConcatenator.concat(chunks), concatMessages(chunks));
      expect(
        MessageConcatenator.concat(chunks).toolCalls!.map((c) => c.id),
        ['y', 'x'],
      );
    });
  });

  group('tool calls (TestConcatToolCalls)', () {
    final expected = call(
      index: 0,
      id: 'tool_call_id',
      type: 'function',
      name: 'tool_name',
      arguments: 'call me please',
    );

    test('atomic_field_in_first_chunk', () {
      expect(
        concatToolCalls([
          call(index: 0, id: 'tool_call_id', type: 'function', name: 'tool_name'),
          call(index: 0, arguments: 'call me please'),
        ]),
        [expected],
      );
    });

    test('atomic_field_in_every_chunk', () {
      expect(
        concatToolCalls([
          call(index: 0, id: 'tool_call_id', type: 'function', name: 'tool_name'),
          call(
            index: 0,
            id: 'tool_call_id',
            type: 'function',
            name: 'tool_name',
            arguments: 'call me please',
          ),
        ]),
        [expected],
      );
    });

    test('atomic_field_in_interval', () {
      expect(
        concatToolCalls([
          call(index: 0, id: 'tool_call_id'),
          call(index: 0, type: 'function', arguments: 'call me please'),
          call(index: 0, id: 'tool_call_id'),
        ]),
        [
          call(
            index: 0,
            id: 'tool_call_id',
            type: 'function',
            arguments: 'call me please',
          ),
        ],
      );
    });

    test('different_tool_id', () {
      expect(
        () => concatToolCalls([
          call(index: 0, id: 'tool_call_id', type: 'function', name: 'tool_name'),
          call(
            index: 0,
            id: 'tool_call_id_1',
            type: 'function',
            name: 'tool_name',
            arguments: 'call me please',
          ),
        ]),
        throwsConcatErrorWith('cannot concat ToolCalls with different tool id'),
      );
    });

    test('different_tool_type', () {
      expect(
        () => concatToolCalls([
          call(index: 0, id: 'tool_call_id', type: 'function', name: 'tool_name'),
          call(
            index: 0,
            id: 'tool_call_id',
            type: 'function_1',
            name: 'tool_name',
            arguments: 'call me please',
          ),
        ]),
        throwsConcatErrorWith(
          'cannot concat ToolCalls with different tool type',
        ),
      );
    });

    test('different_tool_name', () {
      expect(
        () => concatToolCalls([
          call(index: 0, id: 'tool_call_id', type: 'function', name: 'tool_name'),
          call(
            index: 0,
            id: 'tool_call_id',
            type: 'function',
            name: 'tool_name_1',
            arguments: 'call me please',
          ),
        ]),
        throwsConcatErrorWith(
          'cannot concat ToolCalls with different tool name',
        ),
      );
    });

    test('multi_tool_call', () {
      expect(
        concatToolCalls([
          call(index: 0, id: 'tool_call_id'),
          call(index: 0, type: 'function', arguments: 'call me please'),
          call(index: 0, id: 'tool_call_id'),
          call(index: 1, id: 'tool_call_id'),
          call(index: 1, type: 'function', arguments: 'call me please'),
          call(index: 1, id: 'tool_call_id'),
          call(id: '22'),
          call(id: '44'),
        ]),
        [
          call(id: '22'),
          call(id: '44'),
          call(
            index: 0,
            id: 'tool_call_id',
            type: 'function',
            arguments: 'call me please',
          ),
          call(
            index: 1,
            id: 'tool_call_id',
            type: 'function',
            arguments: 'call me please',
          ),
        ],
      );
    });

    test('calls come out by index, whatever order they arrived in', () {
      expect(
        concatToolCalls([
          call(index: 2, id: 'c'),
          call(index: 0, id: 'a'),
          call(index: 1, id: 'b'),
          call(index: 0, arguments: '{}'),
        ]).map((c) => '${c.index}:${c.id}:${c.function.arguments}'),
        ['0:a:{}', '1:b:', '2:c:'],
      );
    });

    test('the extra of the first fragment is kept', () {
      final merged = concatToolCalls([
        const ToolCall(
          index: 0,
          id: 'a',
          function: FunctionCall(name: 'f', arguments: ''),
          extra: {'thought_signature': 'abc'},
        ),
        const ToolCall(
          index: 0,
          id: '',
          function: FunctionCall(name: '', arguments: '{}'),
        ),
      ]);

      expect(merged.single.extra, {'thought_signature': 'abc'});
      expect(merged.single.function.arguments, '{}');
    });
  });

  group('concatMessageArray', () {
    test('joins the messages at each position', () {
      final result = concatMessageArray([
        [assistant(content: 'a'), Message.user('1')],
        [assistant(content: 'b'), Message.user('2')],
        [assistant(content: 'c'), Message.user('3')],
      ]);

      expect(result, [assistant(content: 'abc'), Message.user('123')]);
    });

    test('returns a single array as it is', () {
      final only = [assistant(content: 'a')];

      expect(concatMessageArray([only]), only);
    });

    test('rejects arrays of different lengths', () {
      expect(
        () => concatMessageArray([
          [assistant(content: 'a')],
          [assistant(content: 'b'), assistant(content: 'c')],
        ]),
        throwsConcatErrorWith('unexpected array length'),
      );
    });

    test('gives no messages for no arrays', () {
      expect(concatMessageArray([]), isEmpty);
    });
  });

  group('concatMessageStream', () {
    test('reads the stream to its end, joins and closes', () async {
      final (reader, writer) = pipe<Message>();
      writer
        ..send(assistant(content: 'Hel'))
        ..send(assistant(content: 'lo'));
      await writer.close();

      expect(await concatMessageStream(reader), assistant(content: 'Hello'));
      await expectLater(reader.done, completes);
    });

    test('rethrows an error of the stream and closes', () async {
      final (reader, writer) = pipe<Message>();
      writer
        ..send(assistant(content: 'Hel'))
        ..sendError(const FormatException('broken'));

      await expectLater(concatMessageStream(reader), throwsFormatException);
      expect(writer.isClosed, isTrue);
    });
  });

  group('concatToolResults (TestConcatToolResults)', () {
    ToolOutputPart text(String text, {Map<String, dynamic>? extra}) =>
        ToolOutputPart.text(text, extra: extra);

    ToolOutputPart audio({String? url, String? base64}) => ToolOutputPart(
          type: ToolPartType.audio,
          audio: ToolOutputAudio(
            common: MessagePartCommon(
              url: url,
              base64Data: base64,
              mimeType: 'audio/wav',
            ),
          ),
        );

    ToolOutputPart image(String url) => ToolOutputPart(
          type: ToolPartType.image,
          image: ToolOutputImage(common: MessagePartCommon(url: url)),
        );

    ToolOutputPart video(String url) => ToolOutputPart(
          type: ToolPartType.video,
          video: ToolOutputVideo(common: MessagePartCommon(url: url)),
        );

    ToolOutputPart file(String url) => ToolOutputPart(
          type: ToolPartType.file,
          file: ToolOutputFile(common: MessagePartCommon(url: url)),
        );

    Matcher throwsConflict(String type) => throwsA(
          isA<MessageConcatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('conflicting'), contains(type)),
          ),
        );

    test('empty_chunks', () {
      expect(concatToolResults([]).parts, isEmpty);
    });

    test('chunks without parts', () {
      expect(
        concatToolResults([const ToolResult(), const ToolResult()]).parts,
        isEmpty,
      );
    });

    test('single_text_part', () {
      expect(
        concatToolResults([ToolResult.text('Hello World')]).parts,
        [text('Hello World')],
      );
    });

    test('multiple_text_parts_merge', () {
      expect(
        concatToolResults([
          ToolResult.text('Hello '),
          ToolResult.text('World'),
          ToolResult.text('!'),
        ]).parts,
        [text('Hello World!')],
      );
    });

    test('multiple_text_parts_merge_with_extra', () {
      final result = concatToolResults([
        ToolResult([
          text('Hello ', extra: {'k1': 'v1'}),
          text('World', extra: {'k2': 'v2'}),
        ]),
      ]);

      expect(result.parts, [
        text('Hello World', extra: {'k1': 'v1', 'k2': 'v2'}),
      ]);
    });

    test('multiple_text_parts_merge_with_single_extra', () {
      final result = concatToolResults([
        ToolResult([
          text('Hello ', extra: {'k1': 'v1'}),
          text('World'),
        ]),
      ]);

      expect(result.parts, [
        text('Hello World', extra: {'k1': 'v1'}),
      ]);
    });

    test('cross_chunk_audio_conflict_error', () {
      expect(
        () => concatToolResults([
          ToolResult([audio(base64: 'YXVkaW8x')]),
          ToolResult([audio(base64: 'YXVkaW8y')]),
        ]),
        throwsConflict('audio'),
      );
    });

    test('mixed_types_no_merge', () {
      final result = concatToolResults([
        ToolResult([
          text('Text part'),
          image('https://example.com/image.png'),
        ]),
        ToolResult([video('https://example.com/video.mp4')]),
      ]);

      expect(
        result.parts.map((part) => part.type),
        [ToolPartType.text, ToolPartType.image, ToolPartType.video],
      );
    });

    test('mixed_text_and_single_audio', () {
      final result = concatToolResults([
        ToolResult([text('Part 1 '), text('Part 2')]),
        ToolResult([audio(base64: 'YXVkaW8x')]),
        ToolResult([text(' Part 3')]),
      ]);

      expect(result.parts, [
        text('Part 1 Part 2'),
        audio(base64: 'YXVkaW8x'),
        text(' Part 3'),
      ]);
    });

    test('cross_chunk_audio_url_and_base64_conflict_error', () {
      expect(
        () => concatToolResults([
          ToolResult([audio(url: 'https://example.com/audio.wav')]),
          ToolResult([audio(base64: 'YXVkaW8x')]),
        ]),
        throwsConflict('audio'),
      );
    });

    test('single_audio_with_extra_fields', () {
      const part = ToolOutputPart(
        type: ToolPartType.audio,
        audio: ToolOutputAudio(
          common: MessagePartCommon(
            base64Data: 'YXVkaW8x',
            mimeType: 'audio/wav',
            // ignore: deprecated_member_use_from_same_package
            extra: {'key1': 'value1'},
          ),
        ),
      );

      expect(concatToolResults([const ToolResult([part])]).parts, [part]);
    });

    test('cross_chunk_image_conflict_error', () {
      expect(
        () => concatToolResults([
          ToolResult([image('https://example.com/image1.png')]),
          ToolResult([image('https://example.com/image2.png')]),
        ]),
        throwsConflict('image'),
      );
    });

    test('cross_chunk_video_conflict_error', () {
      expect(
        () => concatToolResults([
          ToolResult([video('https://example.com/video1.mp4')]),
          ToolResult([video('https://example.com/video2.mp4')]),
        ]),
        throwsConflict('video'),
      );
    });

    test('cross_chunk_file_conflict_error', () {
      expect(
        () => concatToolResults([
          ToolResult([file('https://example.com/file1.pdf')]),
          ToolResult([file('https://example.com/file2.pdf')]),
        ]),
        throwsConflict('file'),
      );
    });

    test('same_chunk_text_merged', () {
      expect(
        concatToolResults([
          ToolResult([text('Hello '), text('World')]),
        ]).parts,
        [text('Hello World')],
      );
    });

    test('different_non_text_types_across_chunks_allowed', () {
      final result = concatToolResults([
        ToolResult([image('https://example.com/image.png')]),
        ToolResult([video('https://example.com/video.mp4')]),
        ToolResult([audio(base64: 'YXVkaW8x')]),
      ]);

      expect(
        result.parts.map((part) => part.type),
        [ToolPartType.image, ToolPartType.video, ToolPartType.audio],
      );
    });

    test('several parts of one kind may come in the same chunk', () {
      final result = concatToolResults([
        ToolResult([
          image('https://example.com/1.png'),
          image('https://example.com/2.png'),
        ]),
        ToolResult.text('two images'),
      ]);

      expect(result.parts, hasLength(3));
    });
  });

  group('ToolResult.toMessageInputParts '
      '(TestConvToolOutputPartToMessageInputPart)', () {
    MessageInputPart convert(ToolOutputPart part) =>
        ToolResult([part]).toMessageInputParts().single;

    Matcher throwsNil(String what) => throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains(what)),
        );

    test('text part', () {
      final result = convert(
        ToolOutputPart.text('test text', extra: {'key': 'value'}),
      );

      expect(result.type, ChatMessagePartType.text);
      expect(result.text, 'test text');
      expect(result.extra, {'key': 'value'});
    });

    test('image part', () {
      const common = MessagePartCommon(
        url: 'https://example.com/image.png',
        mimeType: 'image/png',
      );
      final result = convert(
        const ToolOutputPart(
          type: ToolPartType.image,
          image: ToolOutputImage(common: common),
          extra: {'img_key': 'img_value'},
        ),
      );

      expect(result.type, ChatMessagePartType.imageUrl);
      expect(result.image!.common, common);
      expect(result.extra, {'img_key': 'img_value'});
    });

    test('image part nil content', () {
      expect(
        () => convert(const ToolOutputPart(type: ToolPartType.image)),
        throwsNil('image content is nil'),
      );
    });

    test('audio part', () {
      const common = MessagePartCommon(
        base64Data: 'dGVzdF9hdWRpbw==',
        mimeType: 'audio/wav',
      );
      final result = convert(
        const ToolOutputPart(
          type: ToolPartType.audio,
          audio: ToolOutputAudio(common: common),
        ),
      );

      expect(result.type, ChatMessagePartType.audioUrl);
      expect(result.audio!.common, common);
    });

    test('audio part nil content', () {
      expect(
        () => convert(const ToolOutputPart(type: ToolPartType.audio)),
        throwsNil('audio content is nil'),
      );
    });

    test('video part', () {
      const common = MessagePartCommon(
        url: 'https://example.com/video.mp4',
        mimeType: 'video/mp4',
      );
      final result = convert(
        const ToolOutputPart(
          type: ToolPartType.video,
          video: ToolOutputVideo(common: common),
        ),
      );

      expect(result.type, ChatMessagePartType.videoUrl);
      expect(result.video!.common, common);
    });

    test('video part nil content', () {
      expect(
        () => convert(const ToolOutputPart(type: ToolPartType.video)),
        throwsNil('video content is nil'),
      );
    });

    test('file part', () {
      const common = MessagePartCommon(
        url: 'https://example.com/file.pdf',
        mimeType: 'application/pdf',
      );
      final result = convert(
        const ToolOutputPart(
          type: ToolPartType.file,
          file: ToolOutputFile(common: common),
          extra: {'file_key': 'file_value'},
        ),
      );

      expect(result.type, ChatMessagePartType.fileUrl);
      expect(result.file!.common, common);
      expect(result.extra, {'file_key': 'file_value'});
    });

    test('file part nil content', () {
      expect(
        () => convert(const ToolOutputPart(type: ToolPartType.file)),
        throwsNil('file content is nil'),
      );
    });

    test('tool search result part', () {
      final found = ToolSearchResult(
        tools: [ToolInfo.function(name: 'search')],
      );
      final result = convert(
        ToolOutputPart(
          type: ToolPartType.toolSearchResult,
          toolSearchResult: found,
        ),
      );

      expect(result.type, ChatMessagePartType.toolSearchResult);
      expect(result.toolSearchResult, found);
      expect(
        () => convert(
          const ToolOutputPart(type: ToolPartType.toolSearchResult),
        ),
        throwsNil('tool search result is nil'),
      );
    });

    test('an empty result has no parts', () {
      expect(const ToolResult().toMessageInputParts(), isEmpty);
    });

    // TestToolResultFileID
    test('file ids survive JSON and the conversion', () {
      const common = MessagePartCommon(fileId: 'provider-file-123');
      const result = ToolResult([
        ToolOutputPart(
          type: ToolPartType.image,
          image: ToolOutputImage(common: common),
        ),
        ToolOutputPart(
          type: ToolPartType.audio,
          audio: ToolOutputAudio(common: common),
        ),
        ToolOutputPart(
          type: ToolPartType.video,
          video: ToolOutputVideo(common: common),
        ),
        ToolOutputPart(
          type: ToolPartType.file,
          file: ToolOutputFile(common: common),
        ),
      ]);

      final restored = ToolResult.fromJson(result.toJson());
      final parts = restored.toMessageInputParts();

      expect(restored, result);
      expect(
        [
          parts[0].image!.common.fileId,
          parts[1].audio!.common.fileId,
          parts[2].video!.common.fileId,
          parts[3].file!.common.fileId,
        ],
        everyElement('provider-file-123'),
      );
    });
  });
}
