// The agentic node adders of graphs, chains, branches, parallels and
// workflows: ports of eino `Graph.AddAgenticModelNode`,
// `AddAgenticChatTemplateNode`, `AddAgenticToolsNode`, `Chain.AppendAgentic…`,
// `ChainBranch.AddAgentic…`, `Parallel.AddAgentic…` and
// `Workflow.AddAgentic…` (compose/{graph,chain,chain_branch,chain_parallel,
// workflow}.go, v0.9.22) and of the node converters in
// compose/component_to_graph_node.go.
//
// Eino v0.9.22 has no test of these adders (no `compose/*_test.go` calls
// them); these tests pin what the Go code does: the component type of each
// node, the options and context a model or template gets, and that the
// nodes connect and run.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart' show CallbackHandlerBuilder;
import 'package:threepio_core/compose.dart';

/// An agentic model that answers with [answers] in turn and records what it
/// was called with.
final class _ScriptedModel implements AgenticModel {
  _ScriptedModel(this.answers);

  final List<AgenticMessage> answers;
  final List<List<AgenticMessage>> inputs = [];
  final List<ChatModelOptions?> options = [];
  var _next = 0;

  AgenticMessage _answer(List<AgenticMessage> input, ChatModelOptions? o) {
    inputs.add(input);
    options.add(o);
    return answers[_next++ % answers.length];
  }

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      _answer(input, options);

  /// Every block of the answer is a chunk of its own.
  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    final answer = _answer(input, options);
    return StreamReader.fromIterable([
      for (final (i, block) in answer.contentBlocks.indexed)
        AgenticMessage(
          role: answer.role,
          contentBlocks: [block.copyWith(streamingMeta: StreamingMeta(index: i))],
        ),
    ]);
  }
}

/// An agentic template that renders `{q}` into one user message and records
/// the options and the context it got.
final class _Template implements AgenticChatTemplate {
  final List<ChatTemplateOptions?> options = [];
  final List<RunContext> contexts = [];

  @override
  Future<List<AgenticMessage>> format(
    RunContext ctx,
    Map<String, Object?> variables, {
    ChatTemplateOptions? options,
  }) async {
    contexts.add(ctx);
    this.options.add(options);
    return [
      AgenticMessage.system('be brief'),
      AgenticMessage.user('${variables['q']}'),
    ];
  }
}

final class _Echo extends InvokableTool {
  _Echo(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      '$name($argumentsJson)';
}

AgenticMessage _text(String text) => AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [ContentBlock(AssistantGenText(text: text))],
    );

AgenticMessage _toolCall(String id, String name, String arguments) =>
    AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(
          FunctionToolCall(callId: id, name: name, arguments: arguments),
        ),
      ],
    );

String _textOf(AgenticMessage message) => message.contentBlocks
    .map((b) => b.assistantGenText?.text ?? b.userInputText?.text ?? '')
    .join();

bool _hasToolCalls(AgenticMessage message) =>
    message.contentBlocks.any((b) => b.functionToolCall != null);

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

/// Records the component type and payloads of every start and end.
final class _Recorder {
  final List<(String, ComponentType, String, Object?)> events = [];

  ComponentCallbackHandler get handler => CallbackHandlerBuilder()
      .onStart((ctx, info, input) {
        events.add(('start', info.componentType, info.name, input));
        return ctx;
      })
      .onEnd((ctx, info, output) {
        events.add(('end', info.componentType, info.name, output));
        return ctx;
      })
      .build();

  List<(String, ComponentType, String, Object?)> of(ComponentType type) =>
      events.where((e) => e.$2 == type).toList();
}

void main() {
  final ctx = RunContext.background();

  group('Graph', () {
    test('template, model and tools run as a tool-calling loop', () async {
      final model = _ScriptedModel([
        _toolCall('c1', 'echo', '{"x":1}'),
        _text('done'),
      ]);
      final template = _Template();
      final tools = await AgenticToolsNode.create(
        ToolsNodeConfig(tools: [_Echo('echo')]),
      );

      final graph = Graph<Map<String, Object?>, AgenticMessage>()
        ..addAgenticChatTemplateNode('prompt', template)
        ..addAgenticModelNode('model', model)
        ..addAgenticToolsNode('tools', tools)
        ..addEdge(Graph.start, 'prompt')
        ..addEdge('prompt', 'model')
        ..addBranch(
          'model',
          GraphBranch.single<AgenticMessage>(
            (ctx, message) => _hasToolCalls(message) ? 'tools' : Graph.end,
            {'tools', Graph.end},
          ),
        )
        ..addEdge('tools', 'model');
      final runnable = await graph.compile(ctx);

      final answer = await runnable.invoke(ctx, {'q': 'hello'});
      expect(_textOf(answer), 'done');

      expect(model.inputs, hasLength(2));
      expect(model.inputs[0].map(_textOf), ['be brief', 'hello']);
      final toolResult =
          model.inputs[1].single.contentBlocks.single.functionToolResult!;
      expect(toolResult.callId, 'c1');
      expect(toolResult.name, 'echo');
      expect(
        (toolResult.content.single.content as UserInputText).text,
        'echo({"x":1})',
      );
    });

    test('the model gets the merged call options and the run context',
        () async {
      final model = _ScriptedModel([_text('ok')]);
      final graph = Graph<List<AgenticMessage>, AgenticMessage>()
        ..addAgenticModelNode('model', model)
        ..addEdge(Graph.start, 'model')
        ..addEdge('model', Graph.end);
      final runnable = await graph.compile(ctx);

      await runnable.invoke(
        ctx,
        [AgenticMessage.user('hi')],
        options: [
          CallOption.chatModel(const ChatModelOptions(temperature: 0.5)),
          CallOption.chatModel(const ChatModelOptions(maxTokens: 9)),
        ],
      );
      final options = model.options.single!;
      expect(options.temperature, 0.5);
      expect(options.maxTokens, 9);
      expect(options.runContext, isNotNull);
    });

    test('the template gets its call options and the context', () async {
      final template = _Template();
      final graph = Graph<Map<String, Object?>, List<AgenticMessage>>()
        ..addAgenticChatTemplateNode('prompt', template)
        ..addEdge(Graph.start, 'prompt')
        ..addEdge('prompt', Graph.end);
      final runnable = await graph.compile(ctx);

      final messages = await runnable.invoke(
        ctx,
        {'q': 'x'},
        options: [
          CallOption.chatTemplate(
            const ChatTemplateOptions(extra: {'a': 1}),
          ),
        ],
      );
      expect(messages.map(_textOf), ['be brief', 'x']);
      expect(template.options.single!.extra, {'a': 1});
      expect(template.options.single!.runContext, isNotNull);
      expect(template.contexts, hasLength(1));
    });

    test('the nodes report their agentic component types', () async {
      final model = _ScriptedModel([_toolCall('c1', 'echo', '{}'), _text('ok')]);
      final tools = AgenticToolsNode(ToolsNodeConfig(tools: [_Echo('echo')]));
      final graph = Graph<Map<String, Object?>, AgenticMessage>()
        ..addAgenticChatTemplateNode(
          'prompt',
          _Template(),
          options: const NodeOptions(name: 'the-prompt'),
        )
        ..addAgenticModelNode(
          'model',
          model,
          options: const NodeOptions(name: 'the-model'),
        )
        ..addAgenticToolsNode(
          'tools',
          tools,
          options: const NodeOptions(name: 'the-tools'),
        )
        ..addEdge(Graph.start, 'prompt')
        ..addEdge('prompt', 'model')
        ..addBranch(
          'model',
          GraphBranch.single<AgenticMessage>(
            (ctx, message) => _hasToolCalls(message) ? 'tools' : Graph.end,
            {'tools', Graph.end},
          ),
        )
        ..addEdge('tools', 'model');

      final info = graph.info;
      expect(info.nodes['prompt']!.component, ComponentType.agenticChatTemplate);
      expect(info.nodes['model']!.component, ComponentType.agenticModel);
      expect(info.nodes['tools']!.component, ComponentType.agenticToolsNode);

      final recorder = _Recorder();
      final runnable = await graph.compile(ctx);
      await runnable.invoke(
        ctx,
        {'q': 'hello'},
        options: [CallOption.callbacks([recorder.handler])],
      );

      final prompt = recorder.of(ComponentType.agenticChatTemplate);
      expect(prompt.map((e) => e.$1), ['start', 'end']);
      expect(prompt.first.$3, 'the-prompt');
      expect(prompt.first.$4, {'q': 'hello'});
      expect(prompt.last.$4, isA<List<AgenticMessage>>());

      final models = recorder.of(ComponentType.agenticModel);
      expect(models.map((e) => e.$1), ['start', 'end', 'start', 'end']);
      expect(models.first.$3, 'the-model');
      expect(models.first.$4, isA<List<AgenticMessage>>());
      expect(models[1].$4, isA<AgenticMessage>());

      final toolsEvents = recorder.of(ComponentType.agenticToolsNode);
      expect(toolsEvents.map((e) => e.$1), ['start', 'end']);
      expect(toolsEvents.first.$3, 'the-tools');
      expect(toolsEvents.first.$4, isA<AgenticMessage>());
      expect(toolsEvents.last.$4, isA<List<AgenticMessage>>());

      // The tool inside the tools node reports itself as well.
      expect(recorder.of(ComponentType.tool).map((e) => e.$1), [
        'start',
        'end',
      ]);
    });

    test('a streamed run gives the chunks of the model', () async {
      final model = _ScriptedModel([
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(const Reasoning(text: 'hmm')),
            ContentBlock(const AssistantGenText(text: 'answer')),
          ],
        ),
      ]);
      final graph = Graph<Map<String, Object?>, AgenticMessage>()
        ..addAgenticChatTemplateNode('prompt', _Template())
        ..addAgenticModelNode('model', model)
        ..addEdge(Graph.start, 'prompt')
        ..addEdge('prompt', 'model')
        ..addEdge('model', Graph.end);
      final runnable = await graph.compile(ctx);

      final reader = await runnable.stream(ctx, {'q': 'x'});
      final chunks = <AgenticMessage>[];
      await for (final chunk in reader.asStream()) {
        chunks.add(chunk);
      }
      expect(chunks, hasLength(2));
      expect(chunks[0].contentBlocks.single.reasoning?.text, 'hmm');
      expect(chunks[0].contentBlocks.single.streamingMeta?.index, 0);
      expect(chunks[1].contentBlocks.single.assistantGenText?.text, 'answer');
      expect(chunks[1].contentBlocks.single.streamingMeta?.index, 1);
      expect(model.options.single!.runContext, isNotNull);
    });

    test('a streamed tool-calling loop joins the chunks for the branch',
        () async {
      final model = _ScriptedModel([
        _toolCall('c1', 'echo', '{"y":2}'),
        _text('streamed done'),
      ]);
      final graph = Graph<List<AgenticMessage>, AgenticMessage>()
        ..addAgenticModelNode('model', model)
        ..addAgenticToolsNode(
          'tools',
          AgenticToolsNode(ToolsNodeConfig(tools: [_Echo('echo')])),
        )
        ..addEdge(Graph.start, 'model')
        ..addBranch(
          'model',
          GraphBranch.single<AgenticMessage>(
            (ctx, message) => _hasToolCalls(message) ? 'tools' : Graph.end,
            {'tools', Graph.end},
          ),
        )
        ..addEdge('tools', 'model');
      final runnable = await graph.compile(ctx);

      final reader = await runnable.stream(ctx, [AgenticMessage.user('go')]);
      final answer = concatAgenticMessages(await reader.collectAll());
      expect(_textOf(answer), 'streamed done');
      final toolResult =
          model.inputs[1].single.contentBlocks.single.functionToolResult!;
      expect(
        (toolResult.content.single.content as UserInputText).text,
        'echo({"y":2})',
      );
    });

    test('a tool interrupt is checkpointed and resumed', () async {
      final approval = _Approval();
      final model = _ScriptedModel([
        _toolCall('c1', 'approve', '"deploy"'),
        _text('deployed'),
      ]);
      final graph = Graph<List<AgenticMessage>, AgenticMessage>()
        ..addAgenticModelNode('model', model)
        ..addAgenticToolsNode(
          'tools',
          AgenticToolsNode(ToolsNodeConfig(tools: [approval])),
        )
        ..addEdge(Graph.start, 'model')
        ..addBranch(
          'model',
          GraphBranch.single<AgenticMessage>(
            (ctx, message) => _hasToolCalls(message) ? 'tools' : Graph.end,
            {'tools', Graph.end},
          ),
        )
        ..addEdge('tools', 'model');
      final runnable = await graph.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: InMemoryCheckpointStore(),
          graphName: 'agentic',
        ),
      );

      const checkpointId = 'agentic-1';
      final info = await _interruptOf(
        () => runnable.invoke(
          ctx,
          [AgenticMessage.user('deploy it')],
          options: [CallOption.checkpointId(checkpointId)],
        ),
      );
      final contexts = info.interruptContexts;
      expect(contexts, hasLength(1));
      expect(contexts.single.info, 'approve "deploy"?');
      expect(
        contexts.single.address.toString(),
        'runnable:agentic;node:tools;tool:approve:c1',
      );

      final answer = await runnable.invoke(
        ctx.resumeWithData(contexts.single.id, 'the operator'),
        const [],
        options: [CallOption.checkpointId(checkpointId)],
      );
      expect(_textOf(answer), 'deployed');
      expect(approval.calls, 2);
      expect(model.inputs, hasLength(2));
      final result =
          model.inputs[1].single.contentBlocks.single.functionToolResult!;
      expect(result.callId, 'c1');
      expect(
        (result.content.single.content as UserInputText).text,
        'approved by the operator',
      );
    });

    test('an edge of the wrong type is refused', () {
      final graph = Graph<String, AgenticMessage>()
        ..addAgenticModelNode('model', _ScriptedModel([_text('x')]));
      expect(
        () => graph.addEdge(Graph.start, 'model'),
        throwsA(isA<GraphBuildException>()),
      );
    });
  });

  group('Chain', () {
    test('appendAgenticChatTemplate and appendAgenticModel', () async {
      final model = _ScriptedModel([_text('chained')]);
      final chain = Chain<Map<String, Object?>, AgenticMessage>()
        ..appendAgenticChatTemplate(_Template())
        ..appendAgenticModel(model);
      final runnable = await chain.compile(ctx);
      final answer = await runnable.invoke(ctx, {'q': 'hi'});
      expect(_textOf(answer), 'chained');
      expect(model.inputs.single.map(_textOf), ['be brief', 'hi']);
    });

    test('appendAgenticToolsNode', () async {
      final chain = Chain<AgenticMessage, List<AgenticMessage>>()
        ..appendAgenticToolsNode(
          AgenticToolsNode(ToolsNodeConfig(tools: [_Echo('echo')])),
        );
      final runnable = await chain.compile(ctx);
      final results = await runnable.invoke(ctx, _toolCall('c', 'echo', '1'));
      expect(
        (results.single.contentBlocks.single.functionToolResult!.content
                .single.content as UserInputText)
            .text,
        'echo(1)',
      );
    });

    test('a branch with agentic nodes', () async {
      final tools = AgenticToolsNode(ToolsNodeConfig(tools: [_Echo('echo')]));
      final model = _ScriptedModel([_toolCall('c', 'echo', '2')]);
      final chain = Chain<List<AgenticMessage>, List<AgenticMessage>>()
        ..appendAgenticModel(model)
        ..appendBranch(
          ChainBranch.single<AgenticMessage>(
            (ctx, message) => _hasToolCalls(message) ? 'tools' : 'direct',
          )
            ..addAgenticToolsNode('tools', tools)
            ..addLambda(
              'direct',
              Lambda.invokable(
                (RunContext ctx, AgenticMessage message) async => [message],
              ),
            ),
        );
      final runnable = await chain.compile(ctx);
      final results = await runnable.invoke(ctx, [AgenticMessage.user('go')]);
      expect(
        results.single.contentBlocks.single.functionToolResult!.callId,
        'c',
      );
    });

    test('a branch between agentic models', () async {
      final first = _ScriptedModel([_text('first')]);
      final second = _ScriptedModel([_text('second')]);
      final chain = Chain<Map<String, Object?>, AgenticMessage>()
        ..appendAgenticChatTemplate(_Template())
        ..appendBranch(
          ChainBranch.single<List<AgenticMessage>>(
            (ctx, messages) => messages.length > 1 ? 'second' : 'first',
          )
            ..addAgenticModel('first', first)
            ..addAgenticModel('second', second),
        );
      final runnable = await chain.compile(ctx);
      final answer = await runnable.invoke(ctx, {'q': 'which'});
      expect(_textOf(answer), 'second');
      expect(first.inputs, isEmpty);
      expect(second.options.single!.runContext, isNotNull);
    });

    test('a branch with an agentic template', () async {
      final chain = Chain<Map<String, Object?>, List<AgenticMessage>>()
        ..appendBranch(
          ChainBranch.single<Map<String, Object?>>((ctx, input) => 'prompt')
            ..addAgenticChatTemplate('prompt', _Template())
            ..addLambda(
              'other',
              Lambda.invokable(
                (RunContext ctx, Map<String, Object?> input) async =>
                    <AgenticMessage>[],
              ),
            ),
        );
      final runnable = await chain.compile(ctx);
      final messages = await runnable.invoke(ctx, {'q': 'branch'});
      expect(messages.map(_textOf), ['be brief', 'branch']);
    });

    test('a parallel of agentic nodes', () async {
      final chain = Chain<List<AgenticMessage>, Map<String, Object?>>()
        ..appendParallel(
          Parallel()
            ..addAgenticModel('a', _ScriptedModel([_text('A')]))
            ..addAgenticModel('b', _ScriptedModel([_text('B')])),
        );
      final runnable = await chain.compile(ctx);
      final output = await runnable.invoke(ctx, [AgenticMessage.user('x')]);
      expect(_textOf(output['a']! as AgenticMessage), 'A');
      expect(_textOf(output['b']! as AgenticMessage), 'B');
    });

    test('a parallel of agentic templates and tools nodes', () async {
      final templates = Chain<Map<String, Object?>, Map<String, Object?>>()
        ..appendParallel(
          Parallel()
            ..addAgenticChatTemplate('one', _Template())
            ..addAgenticChatTemplate('two', _Template()),
        );
      final output =
          await (await templates.compile(ctx)).invoke(ctx, {'q': 'p'});
      expect((output['one']! as List<AgenticMessage>).map(_textOf), [
        'be brief',
        'p',
      ]);
      expect(output['two'], isA<List<AgenticMessage>>());

      final tools = Chain<AgenticMessage, Map<String, Object?>>()
        ..appendParallel(
          Parallel()
            ..addAgenticToolsNode(
              'left',
              AgenticToolsNode(ToolsNodeConfig(tools: [_Echo('echo')])),
            )
            ..addAgenticToolsNode(
              'right',
              AgenticToolsNode(ToolsNodeConfig(tools: [_Echo('echo')])),
            ),
        );
      final results =
          await (await tools.compile(ctx)).invoke(ctx, _toolCall('c', 'echo', '3'));
      expect(results.keys, unorderedEquals(['left', 'right']));
      expect(results['left'], isA<List<AgenticMessage>>());
    });
  });

  group('Workflow', () {
    test('agentic template, model and tools nodes', () async {
      final model = _ScriptedModel([_toolCall('c', 'echo', '4')]);
      final workflow = Workflow<Map<String, Object?>, List<AgenticMessage>>();
      workflow.addAgenticChatTemplateNode('prompt', _Template()).addInput(
            Graph.start,
          );
      workflow.addAgenticModelNode('model', model).addInput('prompt');
      workflow
          .addAgenticToolsNode(
            'tools',
            AgenticToolsNode(ToolsNodeConfig(tools: [_Echo('echo')])),
          )
          .addInput('model');
      workflow.end().addInput('tools');

      final info = workflow.info;
      expect(info.nodes['prompt']!.component, ComponentType.agenticChatTemplate);
      expect(info.nodes['model']!.component, ComponentType.agenticModel);
      expect(info.nodes['tools']!.component, ComponentType.agenticToolsNode);

      final runnable = await workflow.compile(ctx);
      final results = await runnable.invoke(ctx, {'q': 'wf'});
      expect(model.inputs.single.map(_textOf), ['be brief', 'wf']);
      expect(
        (results.single.contentBlocks.single.functionToolResult!.content
                .single.content as UserInputText)
            .text,
        'echo(4)',
      );
    });
  });
}
