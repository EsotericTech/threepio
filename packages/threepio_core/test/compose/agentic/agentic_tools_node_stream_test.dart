// What the stream of an `AgenticToolsNode` joins to, how it ends on an
// error, and a streamed interrupt and resume through it in a graph.
//
// Not ports of Go tests: eino v0.9.22 tests only the stream converter
// (`TestStreamToolMessageToAgenticMessage`, ported in
// agentic_tools_node_test.dart), with hand-written input. These tests run
// the node itself, whose inner tools node fills the positions of the other
// calls of a chunk with empty tool messages, and pin that the joined chunks
// are what eino's join to (one message per call, one result part per piece)
// apart from the documented `StreamingMeta` difference.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';

final class _Streamable extends StreamableTool {
  _Streamable(this.name, this._chunks);

  final String name;
  final List<String> _chunks;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable(_chunks);
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

/// A tool whose stream gives `a` and then fails.
final class _Breaking extends StreamableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'breaking');

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final controller = StreamController<String>()
      ..add('a')
      ..addError(StateError('tool broke'));
    unawaited(controller.close());
    return StreamReader.fromStream(controller.stream);
  }
}

/// A tool that interrupts on its first call and answers on the second.
final class _Approval extends InvokableTool {
  int calls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'approve');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls++;
    final resumed = getResumeContext<String>(ctx);
    if (!resumed.isResumeTarget) {
      throw interrupt(ctx, 'approve $argumentsJson?');
    }
    return 'approved by ${resumed.data}';
  }
}

/// An agentic model that answers with [answers] in turn, streaming every
/// answer as one chunk per block.
final class _ScriptedModel implements AgenticModel {
  _ScriptedModel(this.answers);

  final List<AgenticMessage> answers;
  final List<List<AgenticMessage>> inputs = [];
  var _next = 0;

  AgenticMessage _answer(List<AgenticMessage> input) {
    inputs.add(input);
    return answers[_next++ % answers.length];
  }

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      _answer(input);

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final answer = _answer(input);
    return StreamReader.fromIterable([
      for (final (i, block) in answer.contentBlocks.indexed)
        AgenticMessage(
          role: answer.role,
          contentBlocks: [
            block.copyWith(streamingMeta: StreamingMeta(index: i)),
          ],
        ),
    ]);
  }
}

ContentBlock _call(String id, String name, String arguments) => ContentBlock(
      FunctionToolCall(callId: id, name: name, arguments: arguments),
    );

AgenticMessage _calls(List<ContentBlock> blocks) =>
    AgenticMessage(role: AgenticRoleType.assistant, contentBlocks: blocks);

AgenticMessage _text(String text) => AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [ContentBlock(AssistantGenText(text: text))],
    );

/// The user message with one function tool result of [texts], one part per
/// text, without streaming meta.
AgenticMessage _result(String id, String name, List<String> texts) =>
    AgenticMessage(
      role: AgenticRoleType.user,
      contentBlocks: [
        ContentBlock(
          FunctionToolResult(
            callId: id,
            name: name,
            content: [
              for (final text in texts)
                FunctionToolResultContentBlock(UserInputText(text: text)),
            ],
          ),
        ),
      ],
    );

Future<List<T>> _drain<T>(StreamReader<T> reader) async {
  final items = <T>[];
  try {
    while (true) {
      try {
        items.add(await reader.recv());
      } on StreamEOFException {
        break;
      }
    }
  } finally {
    await reader.close();
  }
  return items;
}

Future<GraphInterruptInfo> _interruptOf(Future<Object?> Function() run) async {
  try {
    await run();
  } on Object catch (error) {
    final info = extractInterruptInfo(error);
    if (info == null) rethrow;
    return info;
  }
  fail('expected the run to be interrupted');
}

void main() {
  final ctx = RunContext.background();

  group('AgenticToolsNode: the joined stream', () {
    test('one message per call, one result part per piece', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _Streamable('s1', ['a', 'b', 'c']),
            _Streamable('s2', ['x']),
          ],
        ),
      );
      final chunks = await _drain(
        await node.stream(
          ctx,
          _calls([_call('c1', 's1', '{}'), _call('c2', 's2', '{}')]),
        ),
      );
      // Eino joins the same, except that the result of `c2`, whose only
      // chunk is not joined with anything there, keeps
      // `StreamingMeta(index: 1)`.
      expect(concatAgenticMessagesArray(chunks), [
        _result('c1', 's1', ['a', 'b', 'c']),
        _result('c2', 's2', ['x']),
      ]);
    });

    test('invoke has a streamed text as one part, the stream one per piece',
        () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(tools: [_Streamable('s', ['a', 'b'])]),
      );
      final message = _calls([_call('c', 's', '{}')]);
      expect(await node.invoke(ctx, message), [
        _result('c', 's', ['ab']),
      ]);
      final joined = concatAgenticMessagesArray(
        await _drain(await node.stream(ctx, message)),
      );
      expect(joined, [
        _result('c', 's', ['a', 'b']),
      ]);
    });

    test('a single call with a single piece keeps its streaming meta, as in '
        'eino', () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(tools: [_Streamable('s', ['only'])]),
      );
      final chunks = await _drain(
        await node.stream(ctx, _calls([_call('c', 's', '{}')])),
      );
      final joined = concatAgenticMessagesArray(chunks);
      final block = joined.single.contentBlocks.single;
      expect(block.streamingMeta, const StreamingMeta(index: 0));
      expect(
        AgenticMessage(
          role: AgenticRoleType.user,
          contentBlocks: [block.copyWith(clearStreamingMeta: true)],
        ),
        _result('c', 's', ['only']),
      );
    });

    test('a call with only empty pieces joins to a result without content',
        () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _Streamable('quiet', ['']),
            _Streamable('s', ['a', 'b']),
          ],
        ),
      );
      final chunks = await _drain(
        await node.stream(
          ctx,
          _calls([_call('c1', 'quiet', '{}'), _call('c2', 's', '{}')]),
        ),
      );
      // Three pieces and the chunk that gives the quiet call its block.
      expect(chunks, hasLength(4));
      expect(chunks.last[0].contentBlocks.single.streamingMeta?.index, 0);
      expect(chunks.last[1].contentBlocks, isEmpty);
      expect(concatAgenticMessagesArray(chunks), [
        _result('c1', 'quiet', []),
        _result('c2', 's', ['a', 'b']),
      ]);
    });

    test('a tool that streams nothing joins to a result without content',
        () async {
      // Eino fails the stream here; the Dart tools node gives the call the
      // empty result (see `ToolsNode.streamTools`).
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _Streamable('none', []),
            _Streamable('s', ['x']),
          ],
        ),
      );
      final chunks = await _drain(
        await node.stream(
          ctx,
          _calls([_call('c1', 'none', '{}'), _call('c2', 's', '{}')]),
        ),
      );
      expect(concatAgenticMessagesArray(chunks), [
        _result('c1', 'none', []),
        _result('c2', 's', ['x']),
      ]);
    });

    test('a streamed tool search result joins next to a text result',
        () async {
      final search = ToolSearchResult(
        tools: [ToolInfo.function(name: 'found')],
      );
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _EnhancedStreamable('tool_search', [
              ToolResult([
                ToolOutputPart(
                  type: ToolPartType.toolSearchResult,
                  toolSearchResult: search,
                ),
              ]),
            ]),
            _Streamable('s', ['a', 'b']),
          ],
        ),
      );
      final chunks = await _drain(
        await node.stream(
          ctx,
          _calls([_call('c1', 'tool_search', '{}'), _call('c2', 's', '{}')]),
        ),
      );
      expect(concatAgenticMessagesArray(chunks), [
        AgenticMessage(
          role: AgenticRoleType.user,
          contentBlocks: [
            ContentBlock(
              ToolSearchFunctionToolResult(
                callId: 'c1',
                name: 'tool_search',
                result: search,
              ),
            ),
          ],
        ),
        _result('c2', 's', ['a', 'b']),
      ]);
    });

    test('the parts of a streamed multimodal result are appended', () async {
      const image = ToolOutputImage(
        common: MessagePartCommon(url: 'https://x/y.png', mimeType: 'image/png'),
      );
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _EnhancedStreamable('pic', const [
              ToolResult([
                ToolOutputPart(type: ToolPartType.text, text: 'caption'),
              ]),
              ToolResult([
                ToolOutputPart(type: ToolPartType.image, image: image),
              ]),
            ]),
          ],
        ),
      );
      final message = _calls([_call('c', 'pic', '{}')]);
      final joined = concatAgenticMessagesArray(
        await _drain(await node.stream(ctx, message)),
      );
      final content =
          joined.single.contentBlocks.single.functionToolResult!.content;
      expect(content.map((part) => part.type), [
        FunctionToolResultContentBlockType.text,
        FunctionToolResultContentBlockType.image,
      ]);
      expect((content[0].content as UserInputText).text, 'caption');
      final picture = content[1].content as UserInputImage;
      expect(picture.url, 'https://x/y.png');
      expect(picture.mimeType, 'image/png');
    });
  });

  group('AgenticToolsNode: a failing stream', () {
    test('the error reaches the reader and no chunk with a block follows',
        () async {
      final node = AgenticToolsNode(
        ToolsNodeConfig(
          tools: [
            _Breaking(),
            // Only empty pieces: without the error it would get its block in
            // a chunk at the end.
            _Streamable('quiet', ['']),
          ],
        ),
      );
      final reader = await node.stream(
        ctx,
        _calls([_call('c1', 'breaking', '{}'), _call('c2', 'quiet', '{}')]),
      );
      final before = <List<AgenticMessage>>[];
      final after = <List<AgenticMessage>>[];
      Object? failure;
      try {
        while (true) {
          try {
            final chunk = await reader.recv();
            (failure == null ? before : after).add(chunk);
          } on StreamEOFException {
            break;
          } on Object catch (error) {
            failure = error;
          }
        }
      } finally {
        await reader.close();
      }

      expect(failure, isA<StateError>());
      expect((failure! as StateError).message, 'tool broke');
      final pieces = [
        for (final chunk in before)
          for (final message in chunk) ...message.contentBlocks,
      ];
      expect(pieces, hasLength(1));
      expect(pieces.single.streamingMeta?.index, 0);
      expect(
        after.expand((chunk) => chunk).every((m) => m.contentBlocks.isEmpty),
        isTrue,
      );
    });
  });

  group('AgenticToolsNode in a streamed graph', () {
    Graph<List<AgenticMessage>, AgenticMessage> loop(
      AgenticModel model,
      AgenticToolsNode tools,
    ) =>
        Graph<List<AgenticMessage>, AgenticMessage>()
          ..addAgenticModelNode('model', model)
          ..addAgenticToolsNode('tools', tools)
          ..addEdge(Graph.start, 'model')
          ..addBranch(
            'model',
            GraphBranch.single<AgenticMessage>(
              (ctx, message) =>
                  message.contentBlocks.any((b) => b.functionToolCall != null)
                      ? 'tools'
                      : Graph.end,
              {'tools', Graph.end},
            ),
          )
          ..addEdge('tools', 'model');

    test('the model gets the joined results of two streamed calls', () async {
      final model = _ScriptedModel([
        _calls([_call('c1', 's', '{}'), _call('c2', 'quiet', '{}')]),
        _text('done'),
      ]);
      final graph = loop(
        model,
        AgenticToolsNode(
          ToolsNodeConfig(
            tools: [
              _Streamable('s', ['a', 'b']),
              _Streamable('quiet', ['']),
            ],
          ),
        ),
      );
      final runnable = await graph.compile(ctx);
      final chunks = await _drain(
        await runnable.stream(ctx, [AgenticMessage.user('go')]),
      );
      final answer = concatAgenticMessages(chunks);
      expect(answer.contentBlocks.single.assistantGenText?.text, 'done');
      expect(model.inputs, hasLength(2));
      expect(model.inputs[1], [
        _result('c1', 's', ['a', 'b']),
        _result('c2', 'quiet', []),
      ]);
    });

    test('a tool interrupt in a streamed run is checkpointed and resumed',
        () async {
      final approval = _Approval();
      final model = _ScriptedModel([
        _calls([_call('c1', 'approve', '"deploy"')]),
        _text('deployed'),
      ]);
      final runnable = await loop(
        model,
        AgenticToolsNode(ToolsNodeConfig(tools: [approval])),
      ).compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: InMemoryCheckpointStore(),
          graphName: 'agentic-stream',
        ),
      );

      const checkpointId = 'agentic-stream-1';
      final info = await _interruptOf(
        () async => _drain(
          await runnable.stream(
            ctx,
            [AgenticMessage.user('deploy it')],
            options: [CallOption.checkpointId(checkpointId)],
          ),
        ),
      );
      final interrupted = info.interruptContexts.single;
      expect(interrupted.info, 'approve "deploy"?');
      expect(
        interrupted.address.toString(),
        'runnable:agentic-stream;node:tools;tool:approve:c1',
      );

      final chunks = await _drain(
        await runnable.stream(
          ctx.resumeWithData(interrupted.id, 'the operator'),
          const [],
          options: [CallOption.checkpointId(checkpointId)],
        ),
      );
      expect(
        concatAgenticMessages(chunks).contentBlocks.single.assistantGenText
            ?.text,
        'deployed',
      );
      expect(approval.calls, 2);
      expect(model.inputs, hasLength(2));
      // One call with one piece: a single chunk, which joins to itself and
      // keeps its streaming meta, as in eino.
      final block = model.inputs[1].single.contentBlocks.single;
      expect(block.streamingMeta, const StreamingMeta(index: 0));
      expect(
        AgenticMessage(
          role: AgenticRoleType.user,
          contentBlocks: [block.copyWith(clearStreamingMeta: true)],
        ),
        _result('c1', 'approve', ['approved by the operator']),
      );
    });
  });
}
