// The flow of the eino example `compose/graph/react_with_interrupt`
// (main.go): a model → tools loop that stops in front of the tools node, lets
// the caller look at (and change) the tool call in the state, and goes on.
// The model is scripted; the "user" of the example is the test.
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../support/scripted_chat_model.dart';

/// The state of the example: the conversation so far.
final class _MyState {
  _MyState([List<Message>? history]) : history = history ?? [];

  factory _MyState.fromJson(Map<String, Object?> json) => _MyState([
        for (final message in json['history']! as List<Object?>)
          Message.fromJson(message! as Map<String, dynamic>),
      ]);

  List<Message> history;

  Map<String, Object?> toJson() => {
        'history': [for (final message in history) message.toJson()],
      };
}

final class _BookTicket extends InvokableTool {
  final List<String> arguments = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.function(
        name: 'BookTicket',
        description: 'this tool can book ticket of the specific location',
      );

  @override
  Future<String> run(String argumentsJson) async {
    arguments.add(argumentsJson);
    return 'success';
  }
}

const _originalArguments =
    '{"location":"Beijing","passenger_name":"Megumin","passenger_phone_number":"000-0000-0000"}';

ScriptedChatModel _model() => ScriptedChatModel([
      [
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(
              index: 0,
              id: 'call-1',
              function: FunctionCall(
                name: 'BookTicket',
                arguments: _originalArguments,
              ),
            ),
          ],
        ),
      ],
      [Message.assistant('Your ticket to Beijing is booked.')],
    ]);

/// `composeGraph` of the example.
Future<Runnable<Map<String, dynamic>, Message>> _composeGraph(
  RunContext ctx,
  BaseChatModel model,
  _BookTicket tool,
  CheckpointStore store,
) async {
  const template = ChatTemplate.fromMessages(FormatType.fString, [
    Message(
      role: RoleType.system,
      content: 'You are a helpful assistant. When the user asks to book a '
          'ticket, you MUST call the "BookTicket" tool immediately.',
    ),
    Message(
      role: RoleType.user,
      content: "I'm {name}. Help me book a ticket to {location}",
    ),
  ]);

  final graph = Graph<Map<String, dynamic>, Message>(
    localState: LocalState.of<_MyState>((ctx) => _MyState()),
  )
    ..addChatTemplateNode('ChatTemplate', template)
    ..addChatModelNode(
      'ChatModel',
      model,
      options: NodeOptions(
        statePreHandler: StateHandler.pre<List<Message>, _MyState>(
          (ctx, input, state) => state.history = [...state.history, ...input],
        ),
        statePostHandler: StateHandler.post<Message, _MyState>((ctx, output, state) {
          state.history = [...state.history, output];
          return output;
        }),
      ),
    )
    ..addToolsNode(
      'ToolsNode',
      ToolsNode(ToolsNodeConfig(tools: [tool])),
      options: NodeOptions(
        statePreHandler: StateHandler.pre<Message, _MyState>(
          (ctx, input, state) => state.history.last,
        ),
      ),
    )
    ..addEdge(Graph.start, 'ChatTemplate')
    ..addEdge('ChatTemplate', 'ChatModel')
    ..addEdge('ToolsNode', 'ChatModel')
    ..addBranch(
      'ChatModel',
      GraphBranch.single<Message>(
        (ctx, message) =>
            message.toolCalls?.isNotEmpty ?? false ? 'ToolsNode' : Graph.end,
        {'ToolsNode', Graph.end},
      ),
    );

  return graph.compile(
    ctx,
    options: GraphCompileOptions(
      checkpointStore: store,
      interruptBeforeNodes: const ['ToolsNode'],
    ),
  );
}

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_MyState>(
      'react_with_interrupt.state',
      fromJson: _MyState.fromJson,
      toJson: (state) => state.toJson(),
    );
  });

  final ctx = RunContext.background();
  const input = {'name': 'Megumin', 'location': 'Beijing'};

  for (final streaming in [false, true]) {
    final mode = streaming ? 'stream' : 'invoke';

    Future<Message> run(
      Runnable<Map<String, dynamic>, Message> runner,
      List<CallOption> options,
    ) async {
      if (!streaming) return runner.invoke(ctx, input, options: options);
      final stream = await runner.stream(ctx, input, options: options);
      return concatMessages(await stream.collectAll());
    }

    group('eino example react_with_interrupt ($mode)', () {
      test('the run stops in front of the tools node and goes on when the '
          'arguments are accepted', () async {
        final tool = _BookTicket();
        final model = _model();
        final runner =
            await _composeGraph(ctx, model, tool, InMemoryCheckpointStore());

        GraphInterruptInfo? info;
        try {
          await run(runner, [CallOption.checkpointId('1')]);
          fail('expected an interrupt');
        } on GraphInterruptedException catch (interrupted) {
          info = interrupted.info;
        }
        expect(info.beforeNodes, ['ToolsNode']);
        expect(info.rerunNodes, isEmpty);
        expect(tool.arguments, isEmpty);

        // The state shows the tool call the model asked for.
        final history = (info.state! as _MyState).history;
        expect([for (final m in history) m.role], [
          RoleType.system,
          RoleType.user,
          RoleType.assistant,
        ]);
        expect(history[1].content, "I'm Megumin. Help me book a ticket to Beijing");
        expect(
          history.last.toolCalls!.single.function.arguments,
          _originalArguments,
        );

        // "Are the arguments as expected? y"
        final result = await run(runner, [
          CallOption.checkpointId('1'),
          CallOption.stateModifier((ctx, path, state) {
            expect(path.path, isEmpty);
            (state as _MyState).history = history;
          }),
        ]);
        expect(result.content, 'Your ticket to Beijing is booked.');
        expect(tool.arguments, [_originalArguments]);

        // The second model call saw the whole conversation, tool result
        // included.
        expect(model.calls, hasLength(2));
        expect([for (final m in model.calls.last.messages) m.role], [
          RoleType.system,
          RoleType.user,
          RoleType.assistant,
          RoleType.tool,
        ]);
        expect(model.calls.last.messages.last.content, 'success');
      });

      test('the caller changes the arguments of the tool call before the run '
          'goes on', () async {
        final tool = _BookTicket();
        final runner =
            await _composeGraph(ctx, _model(), tool, InMemoryCheckpointStore());

        GraphInterruptInfo? info;
        try {
          await run(runner, [CallOption.checkpointId('1')]);
          fail('expected an interrupt');
        } on GraphInterruptedException catch (interrupted) {
          info = interrupted.info;
        }

        // "Are the arguments as expected? n", then the new arguments.
        const edited = '{"location":"Shanghai","passenger_name":"Megumin"}';
        final history = (info.state! as _MyState).history;
        final last = history.last;
        history[history.length - 1] = last.copyWith(
          toolCalls: [
            last.toolCalls!.single.copyWith(
              function: last.toolCalls!.single.function.copyWith(arguments: edited),
            ),
          ],
        );

        final result = await run(runner, [
          CallOption.checkpointId('1'),
          CallOption.stateModifier(
            (ctx, path, state) => (state as _MyState).history = history,
          ),
        ]);
        expect(result.content, 'Your ticket to Beijing is booked.');
        expect(tool.arguments, [edited]);
      });

      test('without a checkpoint id nothing is stored, and the next call '
          'starts over', () async {
        final tool = _BookTicket();
        final model = _model();
        final store = InMemoryCheckpointStore();
        final runner = await _composeGraph(ctx, model, tool, store);
        await expectLater(
          run(runner, const []),
          throwsA(isA<GraphInterruptedException>()),
        );
        expect(store.keys, isEmpty);
        expect(model.calls, hasLength(1));
      });
    });
  }
}
