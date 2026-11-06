// Port of eino `compose/agentic_tools_node_test.go` (v0.9.22).
//
// All Go tests are ported: TestAgenticMessageToToolCallMessage,
// TestToolMessageToAgenticMessage (4 subtests),
// TestStreamToolMessageToAgenticMessage (3 subtests) and
// TestToolResultFileID. Where Go's stream input has `nil` for the calls a
// chunk does not belong to, the Dart input has the empty tool messages the
// Dart `ToolsNode` puts there (a `List<Message>` cannot hold `null`); see
// `AgenticToolsNode` for how they come out.
//
// The groups named `AgenticToolsNode: …` are not Go tests. They pin the
// node itself (eino's file has no test of it).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/agentic_tools_node.dart'
    show
        agenticMessageToToolCallMessage,
        messageInputPartsToFunctionToolBlocks,
        streamToolMessageToAgenticMessage,
        toolMessageToAgenticMessage;
import 'package:threepio_core/threepio_core.dart';

final class _Invokable extends InvokableTool {
  _Invokable(this.name, this._run);

  final String name;
  final FutureOr<String> Function(RunContext ctx, String arguments) _run;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      _run(ctx, argumentsJson);
}

final class _Streamable extends StreamableTool {
  _Streamable(this.name, this._chunks);

  final String name;
  final List<String> Function(String arguments) _chunks;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable(_chunks(argumentsJson));
}

final class _EnhancedInvokable implements EnhancedInvokableTool {
  _EnhancedInvokable(this.name, this._result);

  final String name;
  final ToolResult _result;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      _result;
}

final class _EnhancedStreamable implements EnhancedStreamableTool {
  _EnhancedStreamable(this.name, this._results);

  final String name;
  final List<ToolResult> _results;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable(_results);
}

final class _BrokenInfo extends InvokableTool {
  @override
  Future<ToolInfo> info() async => throw StateError('no info');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      '';
}

ContentBlock _call(String id, String name, String arguments) => ContentBlock(
      FunctionToolCall(callId: id, name: name, arguments: arguments),
    );

Message _tool(String content, String id, String name) =>
    Message.tool(content: content, toolCallId: id, toolName: name);

Future<List<T>> _drain<T>(StreamReader<T> reader) async {
  final items = <T>[];
  while (true) {
    final T item;
    try {
      item = await reader.recv();
    } on StreamEOFException {
      break;
    }
    items.add(item);
  }
  return items;
}

void main() {
  final ctx = RunContext.background();

  test('TestAgenticMessageToToolCallMessage', () {
    final input = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        _call('1', 'name1', 'arg1'),
        _call('2', 'name2', 'arg2'),
        _call('3', 'name3', 'arg3'),
      ],
    );
    final ret = agenticMessageToToolCallMessage(input);
    expect(ret.role, RoleType.assistant);
    expect(ret.toolCalls, const [
      ToolCall(
        id: '1',
        function: FunctionCall(name: 'name1', arguments: 'arg1'),
      ),
      ToolCall(
        id: '2',
        function: FunctionCall(name: 'name2', arguments: 'arg2'),
      ),
      ToolCall(
        id: '3',
        function: FunctionCall(name: 'name3', arguments: 'arg3'),
      ),
    ]);
  });

  group('agenticMessageToToolCallMessage: beyond Go', () {
    test('skips other blocks and carries the extra of a block', () {
      final ret = agenticMessageToToolCallMessage(
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(const Reasoning(text: 'thinking')),
            ContentBlock(const AssistantGenText(text: 'calling')),
            ContentBlock(
              const FunctionToolCall(callId: 'c', name: 'n', arguments: '{}'),
              extra: const {'k': 'v'},
            ),
            ContentBlock(const ServerToolCall(name: 'web_search')),
            ContentBlock(const AgenticMcpToolCall(name: 'mcp')),
          ],
        ),
      );
      expect(ret.content, '');
      expect(ret.toolCalls, hasLength(1));
      expect(ret.toolCalls!.single.id, 'c');
      expect(ret.toolCalls!.single.extra, {'k': 'v'});
    });

    test('no function tool call gives no tool calls', () {
      final ret = agenticMessageToToolCallMessage(
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [ContentBlock(const AssistantGenText(text: 'hi'))],
        ),
      );
      expect(ret.role, RoleType.assistant);
      expect(ret.toolCalls, isNull);
    });
  });

  group('TestToolMessageToAgenticMessage', () {
    test('text only', () {
      final input = [
        _tool('content1', '1', 'name1'),
        _tool('content2', '2', 'name2'),
        _tool('content3', '3', 'name3'),
      ];
      final ret = toolMessageToAgenticMessage(input);
      expect(ret, hasLength(3));
      for (final (i, msg) in ret.indexed) {
        expect(msg.role, AgenticRoleType.user);
        expect(msg.contentBlocks, hasLength(1));
        expect(msg.contentBlocks[0].type, ContentBlockType.functionToolResult);
        final ftr = msg.contentBlocks[0].functionToolResult!;
        expect(ftr.callId, input[i].toolCallId);
        expect(ftr.name, input[i].toolName);
        expect(ftr.content, hasLength(1));
        expect(
          (ftr.content[0].content as UserInputText).text,
          input[i].content,
        );
      }
    });

    test('with multimodal content', () {
      const imageUrl = 'https://example.com/image.png';
      const audioBase64 = 'YXVkaW9kYXRh';
      const videoUrl = 'https://example.com/video.mp4';
      const fileUrl = 'https://example.com/file.pdf';

      final input = [
        const Message(
          role: RoleType.tool,
          content: 'text result',
          toolCallId: '1',
          toolName: 'tool1',
          userInputMultiContent: [
            MessageInputPart(type: ChatMessagePartType.text, text: 'hello'),
            MessageInputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessageInputImage(
                common: MessagePartCommon(url: imageUrl, mimeType: 'image/png'),
                detail: ImageURLDetail.high,
              ),
            ),
            MessageInputPart(
              type: ChatMessagePartType.audioUrl,
              audio: MessageInputAudio(
                common: MessagePartCommon(
                  base64Data: audioBase64,
                  mimeType: 'audio/wav',
                ),
              ),
            ),
            MessageInputPart(
              type: ChatMessagePartType.videoUrl,
              video: MessageInputVideo(
                common: MessagePartCommon(url: videoUrl, mimeType: 'video/mp4'),
              ),
            ),
            MessageInputPart(
              type: ChatMessagePartType.fileUrl,
              file: MessageInputFile(
                common: MessagePartCommon(
                  url: fileUrl,
                  mimeType: 'application/pdf',
                ),
              ),
            ),
          ],
        ),
        _tool('plain result', '2', 'tool2'),
      ];

      final ret = toolMessageToAgenticMessage(input);
      expect(ret, hasLength(2));

      // first message: multimodal tool result
      expect(ret[0].role, AgenticRoleType.user);
      expect(ret[0].contentBlocks, hasLength(1));
      final ftr1 = ret[0].contentBlocks[0].functionToolResult!;
      expect(ftr1.callId, '1');
      expect(ftr1.content, hasLength(5));

      expect((ftr1.content[0].content as UserInputText).text, 'hello');

      final image = ftr1.content[1].content as UserInputImage;
      expect(image.url, imageUrl);
      expect(image.detail, ImageURLDetail.high);
      expect(image.mimeType, 'image/png');

      expect(
        (ftr1.content[2].content as UserInputAudio).base64Data,
        audioBase64,
      );

      expect((ftr1.content[3].content as UserInputVideo).url, videoUrl);

      expect((ftr1.content[4].content as UserInputFile).url, fileUrl);

      // second message: text-only tool result
      expect(ret[1].role, AgenticRoleType.user);
      expect(ret[1].contentBlocks, hasLength(1));
      final ftr2 = ret[1].contentBlocks[0].functionToolResult!;
      expect(ftr2.callId, '2');
      expect(ftr2.content, hasLength(1));
      expect((ftr2.content[0].content as UserInputText).text, 'plain result');
    });

    test('nil media fields are skipped', () {
      final input = [
        const Message(
          role: RoleType.tool,
          content: 'result',
          toolCallId: '1',
          toolName: 'tool1',
          userInputMultiContent: [
            MessageInputPart(type: ChatMessagePartType.imageUrl),
            MessageInputPart(type: ChatMessagePartType.audioUrl),
            MessageInputPart(type: ChatMessagePartType.videoUrl),
            MessageInputPart(type: ChatMessagePartType.fileUrl),
            MessageInputPart(type: ChatMessagePartType.text, text: 'only text'),
          ],
        ),
      ];
      final ret = toolMessageToAgenticMessage(input);
      expect(ret, hasLength(1));
      final ftr = ret[0].contentBlocks[0].functionToolResult!;
      expect(ftr.content, hasLength(1));
      expect((ftr.content[0].content as UserInputText).text, 'only text');
    });

    test('tool search result', () {
      final input = [
        Message(
          role: RoleType.tool,
          toolCallId: 'call_1',
          toolName: 'tool_search',
          userInputMultiContent: [
            MessageInputPart(
              type: ChatMessagePartType.toolSearchResult,
              toolSearchResult: ToolSearchResult(
                tools: [
                  ToolInfo.function(
                    name: 'dynamic_tool',
                    description: 'dynamic tool',
                  ),
                ],
              ),
            ),
          ],
        ),
      ];

      final ret = toolMessageToAgenticMessage(input);
      expect(ret, hasLength(1));
      expect(ret[0].contentBlocks, hasLength(1));
      final block = ret[0].contentBlocks[0];
      expect(block.type, ContentBlockType.toolSearchResult);
      final result = block.toolSearchFunctionToolResult!;
      expect(result.callId, 'call_1');
      expect(result.name, 'tool_search');
      expect(result.result, isNotNull);
      expect(result.result!.tools, hasLength(1));
      expect(result.result!.tools[0].function.name, 'dynamic_tool');
    });
  });

  group('toolMessageToAgenticMessage: beyond Go', () {
    test('the extra of a tool message is that of its block and message', () {
      final ret = toolMessageToAgenticMessage(const [
        Message(
          role: RoleType.tool,
          content: 'x',
          toolCallId: '1',
          toolName: 't',
          extra: {'k': 1},
        ),
      ]);
      expect(ret.single.extra, {'k': 1});
      expect(ret.single.contentBlocks.single.extra, {'k': 1});
      expect(ret.single.contentBlocks.single.streamingMeta, isNull);
    });

    test('an empty result has a block without content', () {
      final ret = toolMessageToAgenticMessage([_tool('', '1', 't')]);
      final ftr = ret.single.contentBlocks.single.functionToolResult!;
      expect(ftr.callId, '1');
      expect(ftr.name, 't');
      expect(ftr.content, isEmpty);
    });

    test('a tool search part next to other parts is not a search result', () {
      final ret = toolMessageToAgenticMessage([
        const Message(
          role: RoleType.tool,
          toolCallId: '1',
          toolName: 't',
          userInputMultiContent: [
            MessageInputPart(type: ChatMessagePartType.text, text: 'a'),
            MessageInputPart(
              type: ChatMessagePartType.toolSearchResult,
              toolSearchResult: ToolSearchResult(),
            ),
          ],
        ),
      ]);
      final block = ret.single.contentBlocks.single;
      expect(block.type, ContentBlockType.functionToolResult);
      // The search part has no place in a function tool result.
      expect(block.functionToolResult!.content, hasLength(1));
    });

    test('part extras and file names are kept', () {
      final blocks = messageInputPartsToFunctionToolBlocks(const [
        MessageInputPart(
          type: ChatMessagePartType.text,
          text: 't',
          extra: {'a': 1},
        ),
        MessageInputPart(
          type: ChatMessagePartType.fileUrl,
          file: MessageInputFile(
            common: MessagePartCommon(fileId: 'f-1', mimeType: 'text/plain'),
            name: 'notes.txt',
          ),
          extra: {'b': 2},
        ),
        MessageInputPart(type: ChatMessagePartType.reasoning),
      ]);
      expect(blocks, hasLength(2));
      expect(blocks[0].extra, {'a': 1});
      expect(blocks[0].type, FunctionToolResultContentBlockType.text);
      final file = blocks[1].content as UserInputFile;
      expect(file.name, 'notes.txt');
      expect(file.fileId, 'f-1');
      expect(file.url, '');
      expect(file.mimeType, 'text/plain');
      expect(blocks[1].extra, {'b': 2});
      expect(blocks[1].type, FunctionToolResultContentBlockType.file);
    });
  });

  group('TestStreamToolMessageToAgenticMessage', () {
    test('text only', () async {
      // Go has nil where this input has the empty tool messages the Dart
      // tools node puts in the positions of the other calls.
      final input = StreamReader<List<Message>>.fromIterable([
        [
          _tool('content1-1', '1', 'name1'),
          _tool('', '2', 'name2'),
          _tool('', '3', 'name3'),
        ],
        [
          _tool('', '1', 'name1'),
          _tool('content2-1', '2', 'name2'),
          _tool('', '3', 'name3'),
        ],
        [
          _tool('', '1', 'name1'),
          _tool('content2-2', '2', 'name2'),
          _tool('', '3', 'name3'),
        ],
        [
          _tool('', '1', 'name1'),
          _tool('', '2', 'name2'),
          _tool('content3-1', '3', 'name3'),
        ],
        [
          _tool('', '1', 'name1'),
          _tool('', '2', 'name2'),
          _tool('content3-2', '3', 'name3'),
        ],
      ]);
      final chunks = await _drain(streamToolMessageToAgenticMessage(input));
      final result = concatAgenticMessagesArray(chunks);

      FunctionToolResultContentBlock text(String text) =>
          FunctionToolResultContentBlock(UserInputText(text: text));
      AgenticMessage expected(
        String id,
        String name,
        List<String> texts,
      ) =>
          AgenticMessage(
            role: AgenticRoleType.user,
            contentBlocks: [
              ContentBlock(
                FunctionToolResult(
                  callId: id,
                  name: name,
                  content: [for (final t in texts) text(t)],
                ),
              ),
            ],
          );

      // Go keeps `StreamingMeta{Index: 0}` on the first result: its only
      // chunk is not joined with anything there. Here it is joined with the
      // empty messages of the other chunks, and the joined block has none.
      expect(result, [
        expected('1', 'name1', ['content1-1']),
        expected('2', 'name2', ['content2-1', 'content2-2']),
        expected('3', 'name3', ['content3-1', 'content3-2']),
      ]);
      expect(
        result.map((m) => m.toJson()).toList(),
        [
          {
            'role': 'user',
            'content_blocks': [
              {
                'type': 'function_tool_result',
                'function_tool_result': {
                  'call_id': '1',
                  'name': 'name1',
                  'content': [
                    {
                      'type': 'text',
                      'text': {'text': 'content1-1'},
                    },
                  ],
                },
              },
            ],
          },
          {
            'role': 'user',
            'content_blocks': [
              {
                'type': 'function_tool_result',
                'function_tool_result': {
                  'call_id': '2',
                  'name': 'name2',
                  'content': [
                    {
                      'type': 'text',
                      'text': {'text': 'content2-1'},
                    },
                    {
                      'type': 'text',
                      'text': {'text': 'content2-2'},
                    },
                  ],
                },
              },
            ],
          },
          {
            'role': 'user',
            'content_blocks': [
              {
                'type': 'function_tool_result',
                'function_tool_result': {
                  'call_id': '3',
                  'name': 'name3',
                  'content': [
                    {
                      'type': 'text',
                      'text': {'text': 'content3-1'},
                    },
                    {
                      'type': 'text',
                      'text': {'text': 'content3-2'},
                    },
                  ],
                },
              },
            ],
          },
        ],
      );
    });

    test('with multimodal content', () async {
      const imageUrl = 'https://example.com/image.png';
      final input = StreamReader<List<Message>>.fromIterable([
        [
          const Message(
            role: RoleType.tool,
            content: 'result1',
            toolName: 'tool1',
            toolCallId: '1',
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.text,
                text: 'text part',
              ),
              MessageInputPart(
                type: ChatMessagePartType.imageUrl,
                image: MessageInputImage(
                  common: MessagePartCommon(url: imageUrl),
                ),
              ),
            ],
          ),
          _tool('', '2', 'tool2'),
        ],
        [
          _tool('', '1', 'tool1'),
          _tool('result2', '2', 'tool2'),
        ],
      ]);
      final chunks = await _drain(streamToolMessageToAgenticMessage(input));
      final result = concatAgenticMessagesArray(chunks);

      expect(result, hasLength(2));

      // first message: multimodal tool result
      expect(result[0].role, AgenticRoleType.user);
      expect(result[0].contentBlocks, hasLength(1));
      final ftr1 = result[0].contentBlocks[0].functionToolResult!;
      expect(ftr1.callId, '1');
      expect(ftr1.content, hasLength(2));
      expect(ftr1.content[0].content, isA<UserInputText>());
      expect(ftr1.content[1].content, isA<UserInputImage>());
      expect((ftr1.content[1].content as UserInputImage).url, imageUrl);

      // second message: text-only tool result
      expect(result[1].role, AgenticRoleType.user);
      expect(result[1].contentBlocks, hasLength(1));
      final ftr2 = result[1].contentBlocks[0].functionToolResult!;
      expect(ftr2.callId, '2');
      expect(ftr2.content, hasLength(1));
      expect((ftr2.content[0].content as UserInputText).text, 'result2');
    });

    test('tool search result', () async {
      final input = StreamReader<List<Message>>.fromIterable([
        [
          Message(
            role: RoleType.tool,
            toolName: 'tool_search',
            toolCallId: 'call_1',
            userInputMultiContent: [
              MessageInputPart(
                type: ChatMessagePartType.toolSearchResult,
                toolSearchResult: ToolSearchResult(
                  tools: [
                    ToolInfo.function(
                      name: 'dynamic_tool',
                      description: 'dynamic tool',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ]);

      final ret = streamToolMessageToAgenticMessage(input);
      final chunk = await ret.recv();
      expect(chunk, hasLength(1));
      expect(chunk[0].contentBlocks, hasLength(1));
      final block = chunk[0].contentBlocks[0];
      expect(block.type, ContentBlockType.toolSearchResult);
      expect(block.streamingMeta?.index, 0);
      final result = block.toolSearchFunctionToolResult!;
      expect(result.callId, 'call_1');
      expect(result.name, 'tool_search');
      expect(result.result!.tools, hasLength(1));
      expect(result.result!.tools[0].function.name, 'dynamic_tool');
      await ret.close();
    });
  });

  group('streamToolMessageToAgenticMessage: beyond Go', () {
    test('the other calls of a chunk are messages without blocks', () async {
      final chunks = await _drain(
        streamToolMessageToAgenticMessage(
          StreamReader<List<Message>>.fromIterable([
            [_tool('a1', '1', 'n1'), _tool('', '2', 'n2')],
            [_tool('', '1', 'n1'), _tool('b1', '2', 'n2')],
            [_tool('a2', '1', 'n1'), _tool('', '2', 'n2')],
          ]),
        ),
      );
      expect(chunks, hasLength(3));
      for (final (i, chunk) in chunks.indexed) {
        expect(chunk, hasLength(2));
        final full = i.isOdd ? 1 : 0;
        expect(chunk[1 - full].contentBlocks, isEmpty);
        expect(chunk[1 - full].role, AgenticRoleType.user);
        final block = chunk[full].contentBlocks.single;
        expect(block.streamingMeta?.index, full);
      }
      final text = chunks[2][0].contentBlocks.single.functionToolResult!
          .content.single.content as UserInputText;
      expect(text.text, 'a2');
    });

    test('a call with only empty pieces gets its block at the end', () async {
      final chunks = await _drain(
        streamToolMessageToAgenticMessage(
          StreamReader<List<Message>>.fromIterable([
            [_tool('a', '1', 'n1'), _tool('', '2', 'n2')],
            [_tool('', '1', 'n1'), _tool('', '2', 'n2')],
          ]),
        ),
      );
      expect(chunks, hasLength(3));
      final last = chunks.last;
      expect(last[0].contentBlocks, isEmpty);
      final block = last[1].contentBlocks.single;
      expect(block.streamingMeta?.index, 1);
      final ftr = block.functionToolResult!;
      expect(ftr.callId, '2');
      expect(ftr.name, 'n2');
      expect(ftr.content, isEmpty);
    });

    test('no extra chunk when every call had content', () async {
      final chunks = await _drain(
        streamToolMessageToAgenticMessage(
          StreamReader<List<Message>>.fromIterable([
            [_tool('a', '1', 'n1'), _tool('', '2', 'n2')],
            [_tool('', '1', 'n1'), _tool('b', '2', 'n2')],
          ]),
        ),
      );
      expect(chunks, hasLength(2));
    });

    test('no extra chunk after an error of the source', () async {
      final (reader, writer) = pipe<List<Message>>(capacity: 4);
      writer
        ..send([_tool('a', '1', 'n1'), _tool('', '2', 'n2')])
        ..sendError(StateError('cut off'));
      await writer.close();
      final ret = streamToolMessageToAgenticMessage(reader);
      expect(await ret.recv(), hasLength(2));
      await expectLater(ret.recv(), throwsA(isA<StateError>()));
      await expectLater(ret.recv(), throwsA(isA<StreamEOFException>()));
      await ret.close();
    });

    test('errors of the source pass through', () async {
      final source = StreamReader<List<Message>>.fromStream(
        Stream<List<Message>>.error(StateError('boom')),
      );
      final ret = streamToolMessageToAgenticMessage(source);
      await expectLater(ret.recv(), throwsA(isA<StateError>()));
      await ret.close();
    });
  });

  test('TestToolResultFileID', () {
    const fileId = 'provider-file-123';
    const common = MessagePartCommon(fileId: fileId);
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
    final parts = result.toMessageInputParts();
    final converted = toolMessageToAgenticMessage([
      Message(
        role: RoleType.tool,
        toolCallId: 'call-1',
        userInputMultiContent: parts,
      ),
    ]);
    expect(converted, hasLength(1));
    final blocks = converted[0].contentBlocks[0].functionToolResult!.content;

    expect(blocks, hasLength(4));
    expect((blocks[0].content as UserInputImage).fileId, fileId);
    expect((blocks[1].content as UserInputAudio).fileId, fileId);
    expect((blocks[2].content as UserInputVideo).fileId, fileId);
    expect((blocks[3].content as UserInputFile).fileId, fileId);
  });

  group('AgenticToolsNode: running tools', () {
    final weather = _Invokable('weather', (ctx, args) => 'sunny $args');
    final echo = _Invokable('echo', (ctx, args) => args);

    AgenticMessage calls(List<ContentBlock> blocks) =>
        AgenticMessage(role: AgenticRoleType.assistant, contentBlocks: blocks);

    test('invoke runs every function tool call, in order', () async {
      final node = await AgenticToolsNode.create(
        ToolsNodeConfig(tools: [weather, echo]),
      );
      final results = await node.invoke(
        ctx,
        calls([
          ContentBlock(const AssistantGenText(text: 'let me check')),
          _call('c1', 'weather', '{"city":"Paris"}'),
          _call('c2', 'echo', '"hi"'),
        ]),
      );
      expect(results, hasLength(2));
      final first = results[0].contentBlocks.single.functionToolResult!;
      expect(first.callId, 'c1');
      expect(first.name, 'weather');
      expect(
        (first.content.single.content as UserInputText).text,
        'sunny {"city":"Paris"}',
      );
      final second = results[1].contentBlocks.single.functionToolResult!;
      expect(second.callId, 'c2');
      expect((second.content.single.content as UserInputText).text, '"hi"');
      expect(results.every((m) => m.role == AgenticRoleType.user), isTrue);
    });

    test('invokeTools takes the options of the tools node directly', () async {
      final node = AgenticToolsNode(ToolsNodeConfig(tools: [weather]));
      final results = await node.invokeTools(
        ctx,
        calls([_call('c1', 'echo', 'x')]),
        options: ToolsNodeOptions(toolList: [echo]),
      );
      expect(
        (results.single.contentBlocks.single.functionToolResult!.content.single
                .content as UserInputText)
            .text,
        'x',
      );
    });

    test('call options reach the inner tools node', () async {
      final node = AgenticToolsNode(ToolsNodeConfig(tools: [weather]));
      final results = await node.invoke(
        ctx,
        calls([_call('c1', 'echo', 'y')]),
        options: [CallOption.toolsNode(ToolsNodeOptions(toolList: [echo]))],
      );
      expect(results.single.contentBlocks.single.functionToolResult!.name,
          'echo');
    });

    test('stream gives every piece at the position of its call', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _Streamable('s1', (args) => ['a', 'b', 'c']),
            _Streamable('s2', (args) => ['x']),
          ],
        ),
      );
      final chunks = await _drain(
        await node.stream(
          ctx,
          calls([_call('c1', 's1', '{}'), _call('c2', 's2', '{}')]),
        ),
      );
      // One chunk per piece; each has one entry per call.
      expect(chunks, hasLength(4));
      expect(chunks.every((chunk) => chunk.length == 2), isTrue);
      final pieces = <int, List<String>>{};
      for (final chunk in chunks) {
        for (final message in chunk) {
          for (final block in message.contentBlocks) {
            final ftr = block.functionToolResult!;
            pieces.putIfAbsent(block.streamingMeta!.index, () => []).addAll(
                  ftr.content.map((c) => (c.content as UserInputText).text),
                );
          }
        }
      }
      expect(pieces, {
        0: ['a', 'b', 'c'],
        1: ['x'],
      });
    });

    test('collect and transform take the input as a stream', () async {
      final node = AgenticToolsNode(ToolsNodeConfig(tools: [echo]));
      final message = calls([_call('c1', 'echo', '"z"')]);
      final collected = await node.collect(
        ctx,
        StreamReader.fromIterable([message]),
      );
      expect(collected.single.contentBlocks.single.functionToolResult!.callId,
          'c1');
      final transformed = await _drain(
        await node.transform(ctx, StreamReader.fromIterable([message])),
      );
      // One call with one piece: a single chunk, whose block keeps its
      // position.
      expect(transformed, hasLength(1));
      final block = transformed.single.single.contentBlocks.single;
      expect(block.streamingMeta?.index, 0);
      expect(
        block.copyWith(clearStreamingMeta: true),
        toolMessageToAgenticMessage([_tool('"z"', 'c1', 'echo')])
            .single
            .contentBlocks
            .single,
      );
    });

    test('streamTools gives the pieces with the call position', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(tools: [_Streamable('s', (args) => ['p', 'q'])]),
      );
      final chunks = await _drain(
        await node.streamTools(ctx, calls([_call('c1', 's', '{}')])),
      );
      expect(chunks, hasLength(2));
      for (final chunk in chunks) {
        final block = chunk.single.contentBlocks.single;
        expect(block.streamingMeta?.index, 0);
        expect(block.functionToolResult!.callId, 'c1');
      }
    });

    test('enhanced results become multimodal parts', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _EnhancedInvokable(
              'pic',
              const ToolResult([
                ToolOutputPart(type: ToolPartType.text, text: 'caption'),
                ToolOutputPart(
                  type: ToolPartType.image,
                  image: ToolOutputImage(
                    common: MessagePartCommon(
                      url: 'https://x/y.png',
                      mimeType: 'image/png',
                    ),
                  ),
                ),
              ]),
            ),
          ],
        ),
      );
      final results = await node.invoke(ctx, calls([_call('c', 'pic', '{}')]));
      final content = results.single.contentBlocks.single.functionToolResult!
          .content;
      expect(content, hasLength(2));
      expect((content[0].content as UserInputText).text, 'caption');
      final image = content[1].content as UserInputImage;
      expect(image.url, 'https://x/y.png');
      expect(image.mimeType, 'image/png');
    });

    test('a streamed tool search result next to another call', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _EnhancedStreamable('tool_search', [
              ToolResult([
                ToolOutputPart(
                  type: ToolPartType.toolSearchResult,
                  toolSearchResult: ToolSearchResult(
                    tools: [ToolInfo.function(name: 'found')],
                  ),
                ),
              ]),
            ]),
            _Streamable('s', (args) => ['a', 'b']),
          ],
        ),
      );
      final chunks = await _drain(
        await node.stream(
          ctx,
          calls([_call('c1', 'tool_search', '{}'), _call('c2', 's', '{}')]),
        ),
      );
      final kinds = <int, Set<ContentBlockType>>{};
      for (final chunk in chunks) {
        for (final message in chunk) {
          for (final block in message.contentBlocks) {
            kinds
                .putIfAbsent(block.streamingMeta!.index, () => {})
                .add(block.type);
          }
        }
      }
      // A position only ever carries blocks of one kind, so the chunks join.
      expect(kinds, {
        0: {ContentBlockType.toolSearchResult},
        1: {ContentBlockType.functionToolResult},
      });
    });

    test('a failing tool fails the node', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [_Invokable('bad', (ctx, args) => throw StateError('no'))],
        ),
      );
      await expectLater(
        node.invoke(ctx, calls([_call('c', 'bad', '{}')])),
        throwsA(isA<ToolsNodeException>()),
      );
    });

    test('an unknown tool goes to the unknown tools handler', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [weather],
          unknownToolsHandler: (ctx, name, input) => 'no tool $name',
        ),
      );
      final results = await node.invoke(ctx, calls([_call('c', 'nope', '')]));
      expect(
        (results.single.contentBlocks.single.functionToolResult!.content.single
                .content as UserInputText)
            .text,
        'no tool nope',
      );
    });

    test('create reports a misconfiguration', () async {
      await expectLater(
        AgenticToolsNode.create(
          ToolsNodeConfig(tools: [_BrokenInfo()]),
        ),
        throwsA(isA<ToolsNodeException>()),
      );
    });

    test('no function tool call fails, as in the tools node', () async {
      final node = AgenticToolsNode(ToolsNodeConfig(tools: [weather]));
      await expectLater(
        node.invoke(
          ctx,
          calls([ContentBlock(const AssistantGenText(text: 'done'))]),
        ),
        throwsA(isA<ToolsNodeException>()),
      );
    });

    test('is reported without an implementation name', () {
      final node = AgenticToolsNode(ToolsNodeConfig(tools: [weather]));
      expect(node.componentTypeName, '');
      expect(componentTypeNameOf(node), '');
      expect(isCallbacksEnabled(node), isFalse);
    });

    test('the tool call id is in the context of the tool', () async {
      String? seen;
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _Invokable('probe', (ctx, args) {
              seen = toolCallIdOf(ctx);
              return 'ok';
            }),
          ],
        ),
      );
      await node.invoke(ctx, calls([_call('call-9', 'probe', '{}')]));
      expect(seen, 'call-9');
    });
  });
}
