// The hand-built ReAct graph of eino-ext
// `skills/eino-compose/reference/graph.md` ("Complete Example: ReAct Agent
// Graph"), run with a scripted model in all four modes.
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../support/scripted_chat_model.dart';

/// Records the bookings it is asked for.
final class _BookTicket extends InvokableTool {
  final List<String> bookings = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.function(
        name: 'book_ticket',
        description: 'Books a ticket',
      );

  @override
  Future<String> run(String argumentsJson) async {
    bookings.add(argumentsJson);
    return 'booked #${bookings.length}';
  }
}

const _toolCall = ToolCall(
  index: 0,
  id: 'call-1',
  function: FunctionCall(
    name: 'book_ticket',
    arguments: '{"destination":"Paris"}',
  ),
);

/// model → branch (tool calls?) → tools → model, as in the reference.
Future<Runnable<Map<String, dynamic>, Message>> _buildReActGraph(
  RunContext ctx,
  BaseChatModel model,
  _BookTicket tool,
) async {
  const template = ChatTemplate.fromMessages(FormatType.fString, [
    Message(role: RoleType.system, content: 'You are a helpful assistant.'),
    Message(role: RoleType.user, content: 'help me to book a ticket to {city}.'),
  ]);
  final tools = await ToolsNode.create(ToolsNodeConfig(tools: [tool]));

  final graph = Graph<Map<String, dynamic>, Message>()
    ..addChatTemplateNode('ChatTemplate', template)
    ..addChatModelNode('ChatModel', model)
    ..addToolsNode('ToolsNode', tools)
    ..addEdge(Graph.start, 'ChatTemplate')
    ..addEdge('ChatTemplate', 'ChatModel')
    // The loop.
    ..addEdge('ToolsNode', 'ChatModel')
    // A stream branch: tool calls may appear in any chunk, so it reads until
    // it sees one or the stream ends.
    ..addBranch(
      'ChatModel',
      GraphBranch.stream<Message>(
        (ctx, stream) async {
          try {
            for (var chunk = await stream.nextOrNull();
                chunk != null;
                chunk = await stream.nextOrNull()) {
              if (chunk.toolCalls?.isNotEmpty ?? false) return 'ToolsNode';
            }
            return Graph.end;
          } finally {
            await stream.close();
          }
        },
        {'ToolsNode', Graph.end},
      ),
    );

  return graph.compile(
    ctx,
    options: const GraphCompileOptions(graphName: 'ReAct', maxRunSteps: 10),
  );
}

ScriptedChatModel _model() => ScriptedChatModel([
      // First turn: a tool call that arrives in the second chunk.
      [
        Message.assistant('Let me '),
        Message.assistant('book it.', toolCalls: const [_toolCall]),
      ],
      // Second turn: the answer, streamed in two chunks.
      [Message.assistant('Your ticket '), Message.assistant('is booked.')],
    ]);

void _expectRun(ScriptedChatModel model, _BookTicket tool) {
  expect(tool.bookings, ['{"destination":"Paris"}']);
  expect(model.calls, hasLength(2));

  final first = model.calls[0].messages;
  expect(first.map((m) => m.role), [RoleType.system, RoleType.user]);
  expect(first.last.content, 'help me to book a ticket to Paris.');

  // The reference graph feeds the tool messages straight back to the model.
  final second = model.calls[1].messages;
  expect(second, hasLength(1));
  expect(second.single.role, RoleType.tool);
  expect(second.single.content, 'booked #1');
  expect(second.single.toolCallId, 'call-1');
  expect(second.single.toolName, 'book_ticket');
}

void main() {
  final ctx = RunContext.background();
  const input = <String, dynamic>{'city': 'Paris'};

  test('invoke: the model calls the tool and then answers', () async {
    final model = _model();
    final tool = _BookTicket();
    final runnable = await _buildReActGraph(ctx, model, tool);

    final answer = await runnable.invoke(ctx, input);

    expect(answer.role, RoleType.assistant);
    expect(answer.content, 'Your ticket is booked.');
    _expectRun(model, tool);
  });

  test('stream: the answer arrives chunk by chunk', () async {
    final model = _model();
    final tool = _BookTicket();
    final runnable = await _buildReActGraph(ctx, model, tool);

    final chunks = await (await runnable.stream(ctx, input)).collectAll();

    expect(chunks.map((m) => m.content), ['Your ticket ', 'is booked.']);
    _expectRun(model, tool);
  });

  test('collect: the input arrives as a stream', () async {
    final model = _model();
    final tool = _BookTicket();
    final runnable = await _buildReActGraph(ctx, model, tool);

    final answer = await runnable.collect(
      ctx,
      StreamReader.fromIterable([input]),
    );

    expect(answer.content, 'Your ticket is booked.');
    _expectRun(model, tool);
  });

  test('transform: stream in, stream out', () async {
    final model = _model();
    final tool = _BookTicket();
    final runnable = await _buildReActGraph(ctx, model, tool);

    final output = await runnable.transform(
      ctx,
      StreamReader.fromIterable([input]),
    );

    expect(
      concatMessages(await output.collectAll()).content,
      'Your ticket is booked.',
    );
    _expectRun(model, tool);
  });

  test('a model that never stops calling tools hits the step limit', () async {
    final model = ScriptedChatModel([
      for (var i = 0; i < 20; i++)
        [
          Message.assistant('again', toolCalls: const [_toolCall]),
        ],
    ]);
    final tool = _BookTicket();
    final runnable = await _buildReActGraph(ctx, model, tool);

    await expectLater(
      runnable.invoke(ctx, input),
      throwsA(
        isA<GraphRunException>().having(
          (e) => ThreepioException.findCause<ExceedMaxStepsException>(e),
          'step limit',
          isNotNull,
        ),
      ),
    );
    // Ten steps: the template, then model and tools in turn.
    expect(model.calls.length, lessThanOrEqualTo(6));
  });

  test('call options reach the model and the tools by node key', () async {
    final model = _model();
    final tool = _BookTicket();
    final runnable = await _buildReActGraph(ctx, model, tool);

    await runnable.invoke(
      ctx,
      input,
      options: [
        CallOption.chatModel(const ChatModelOptions(temperature: 0.5)),
        CallOption.chatModel(const ChatModelOptions(model: 'small'))
            .designateNode(['ChatModel']),
      ],
    );

    for (final call in model.calls) {
      expect(call.options?.temperature, 0.5);
      expect(call.options?.model, 'small');
      expect(call.options?.runContext, isNotNull);
    }
  });

  test('the graph describes itself', () async {
    final graph = Graph<List<Message>, Message>()
      ..addChatModelNode('ChatModel', _model())
      ..addEdge(Graph.start, 'ChatModel')
      ..addEdge('ChatModel', Graph.end);
    final mermaid = graph.toMermaid();
    expect(mermaid, startsWith('graph TD\n'));
    expect(mermaid, contains('ChatModel["ChatModel<br/>(ChatModel)"]'));
    expect(mermaid, contains('start_node --> ChatModel'));
    expect(mermaid, contains('ChatModel --> end_node'));
  });
}
