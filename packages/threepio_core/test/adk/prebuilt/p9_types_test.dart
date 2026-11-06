// Unit tests of the P9 types: plans and their JSON, the session value types
// and their checkpoint registration, the tool infos (against the JSON schemas
// eino v0.9.22 builds), the configurations, the deep agent's pieces, the
// planner's and replanner's error paths and streaming events, and the
// executor's replacement of `OutputKey`.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/prebuilt/deep/deep_agent.dart';
import 'package:threepio_core/src/adk/prebuilt/deep/prompt.dart';
import 'package:threepio_core/src/adk/prebuilt/deep/task_tool.dart';
import 'package:threepio_core/src/adk/prebuilt/deep/write_todos.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/executor.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/loop_runner.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/plan.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/planner.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/replanner.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/sequential_runner.dart';

import '../../support/scripted_chat_model.dart';

final ctx = RunContext.background();

Message _call(String id, String name, String args) => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [ToolCall(id: id, function: FunctionCall(name: name, arguments: args))],
    );

Map<String, Object?> _schema(ToolInfo info) =>
    jsonDecode(jsonEncode(info.function.parameters!.toJson())) as Map<String, Object?>;

final class _CustomPlan implements Plan {
  _CustomPlan(this.todo);

  final List<String> todo;

  @override
  String firstStep() => todo.isEmpty ? 'nothing' : todo.first;

  @override
  Map<String, Object?> toJson() => {'todo': todo};
}

/// An agent that sets the session values the executor and replanner read.
final class _Seed implements Agent {
  _Seed(this.values);

  final Map<String, Object?> values;

  @override
  String get name => 'seed';

  @override
  String get description => 'seeds the session';

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) {
    ctx.addSessionValues(values);
    return StreamReader.fromIterable(const []);
  }
}

final class _Echo extends InvokableTool {
  _Echo(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: name, desc: name, params: const {});

  @override
  Future<String> run(String argumentsJson) async => '$name result';
}

void main() {
  group('Plan and DefaultPlan', () {
    test('DefaultPlan: first step, JSON, equality', () {
      final plan = DefaultPlan(['a', 'b']);
      expect(plan.firstStep(), 'a');
      expect(jsonEncode(plan.toJson()), '{"steps":["a","b"]}');
      expect(plan, DefaultPlan(['a', 'b']));
      expect(plan.hashCode, DefaultPlan(['a', 'b']).hashCode);
      expect(plan, isNot(DefaultPlan(['a'])));
      expect(DefaultPlan(const []).firstStep(), '');
      expect(DefaultPlan(null).firstStep(), '');
      expect(jsonEncode(DefaultPlan(null).toJson()), '{"steps":null}', reason: "Go's nil slice");
      expect(() => plan.steps!.add('c'), throwsUnsupportedError);
    });

    test('DefaultPlan.decode reads what sonic reads', () {
      expect(DefaultPlan.decode(ctx, '{"steps":["x","y"],"extra":1}').steps, ['x', 'y']);
      expect(DefaultPlan.decode(ctx, '{}').steps, isNull);
      expect(DefaultPlan.decode(ctx, '{"steps":null}').steps, isNull);
      expect(DefaultPlan.decode(ctx, 'null').steps, isNull);
      expect(() => DefaultPlan.decode(ctx, '{"steps":"x"}'), throwsA(isA<ThreepioFormatException>()));
      expect(() => DefaultPlan.decode(ctx, '{"steps":[1]}'), throwsA(isA<ThreepioFormatException>()));
      expect(() => DefaultPlan.decode(ctx, '[]'), throwsA(isA<ThreepioFormatException>()));
      expect(() => DefaultPlan.decode(ctx, 'not json'), throwsA(isA<ThreepioFormatException>()));
    });

    test('a custom Plan works through the planner and the executor prompt', () async {
      final model = ScriptedChatModel([
        [text('{"todo":["first","second"]}')],
      ]);
      final planner = await PlanExecute.planner(
        ctx,
        PlannerConfig(
          chatModelWithFormattedOutput: model,
          planDecoder: (ctx, json) => _CustomPlan(
            ((jsonDecode(json) as Map)['todo'] as List).cast<String>(),
          ),
        ),
      );
      Plan? stored;
      final events = await Runner(agent: SequentialRunner(name: 's', subAgents: [planner, _Probe((ctx) {
        stored = ctx.sessionValue(PlanExecute.planSessionKey) as Plan?;
      })])).query(ctx, 'go').collectAll();
      expect(events.map((e) => e.error), everyElement(isNull));
      expect(stored, isA<_CustomPlan>());
      expect(stored!.firstStep(), 'first');
      final messages = await defaultGenExecutorInput(
        ctx,
        ExecutionContext(userInput: [Message.user('u')], plan: stored!),
      );
      expect(messages.last.content, contains('{"todo":["first","second"]}'));
      expect(messages.last.content, endsWith('which is: \nfirst'));
    });
  });

  group('session value types', () {
    test('ExecutedStep, ExecutionContext, PlanExecuteResponse', () {
      const step = ExecutedStep(step: 's', result: 'r');
      expect(step.toJson(), {'step': 's', 'result': 'r'});
      expect(ExecutedStep.fromJson(step.toJson()), step);
      expect(step.hashCode, const ExecutedStep(step: 's', result: 'r').hashCode);
      final context = ExecutionContext(userInput: [Message.user('u')], plan: DefaultPlan(['a']), executedSteps: [step]);
      expect(() => context.userInput.add(Message.user('x')), throwsUnsupportedError);
      expect(() => context.executedSteps.add(step), throwsUnsupportedError);
      expect(ExecutionContext(userInput: const [], plan: DefaultPlan(null)).executedSteps, isEmpty);
      const response = PlanExecuteResponse('done');
      expect(jsonEncode(response.toJson()), '{"response":"done"}');
      expect(PlanExecuteResponse.fromJson(const {'response': 'done'}), response);
    });

    test('the session values and runner states go through the TypeRegistry under eino\'s names', () {
      ensurePlanExecuteTypesRegistered();
      ensureDeepTypesRegistered();
      ensureRunnerTypesRegistered();
      final values = <Object>[
        DefaultPlan(['a']),
        const ExecutedStep(step: 's', result: 'r'),
        [const ExecutedStep(step: 's', result: 'r')],
        const Todo(content: 'c', activeForm: 'a', status: 'pending'),
        [const Todo(content: 'c', activeForm: 'a', status: 'pending')],
        const SequentialRunnerState(interruptIndex: 1, subAgentInterrupted: true),
        const LoopRunnerState(loopIterations: 2, subAgentIndex: 1, subAgentInterrupted: true),
      ];
      final names = [
        '_eino_adk_plan_execute_default_plan',
        '_eino_adk_plan_execute_executed_step',
        '_eino_adk_plan_execute_executed_steps',
        '_eino_adk_prebuilt_deep_todo',
        '_eino_adk_prebuilt_deep_todo_slice',
        'eino_adk_sequential_workflow_state',
        'eino_adk_loop_workflow_state',
      ];
      for (final (index, value) in values.indexed) {
        expect(TypeRegistry.nameOf(value), names[index]);
        final decoded = TypeRegistry.decode(jsonDecode(jsonEncode(TypeRegistry.encode(value))));
        expect(decoded, value);
        expect(decoded.runtimeType.toString(), contains(value is List ? 'List' : value.runtimeType.toString()));
      }
      final steps = TypeRegistry.decode(jsonDecode(jsonEncode(TypeRegistry.encode([const ExecutedStep(step: 'a', result: 'b')]))));
      expect(steps, isA<List<ExecutedStep>>());
      final todos = TypeRegistry.decode(jsonDecode(jsonEncode(TypeRegistry.encode([const Todo(content: 'c', activeForm: '', status: '')]))));
      expect(todos, isA<List<Todo>>());
    });

    test('runner states: JSON and equality', () {
      const seq = SequentialRunnerState(interruptIndex: 3);
      expect(SequentialRunnerState.fromJson(seq.toJson()), seq);
      expect(seq.subAgentInterrupted, isFalse);
      const loop = LoopRunnerState(loopIterations: 1, subAgentIndex: 0);
      expect(LoopRunnerState.fromJson(loop.toJson()), loop);
      expect(loop.hashCode, const LoopRunnerState(loopIterations: 1, subAgentIndex: 0).hashCode);
      expect(const LoopBreak('r'), const LoopBreak('r'));
      expect(const LoopBreak('r').from, 'r');
    });
  });

  group('PlanExecute statics and configurations', () {
    test('session keys are eino\'s', () {
      expect(PlanExecute.userInputSessionKey, 'UserInput');
      expect(PlanExecute.planSessionKey, 'Plan');
      expect(PlanExecute.executedStepSessionKey, 'ExecutedStep');
      expect(PlanExecute.executedStepsSessionKey, 'ExecutedSteps');
    });

    test('the plan and respond tools have eino\'s schemas', () {
      expect(PlanExecute.planToolInfo.name, 'plan');
      expect(PlanExecute.respondToolInfo.name, 'respond');
      // Go: {"properties":{"steps":{"items":{"type":"string"},"description":"different steps to follow, should be in sorted order","type":"array"}},"required":["steps"],"type":"object"}
      final plan = _schema(PlanExecute.planToolInfo);
      expect(plan['type'], 'object');
      expect(plan['required'], ['steps']);
      final steps = (plan['properties']! as Map)['steps'] as Map;
      expect(steps['type'], 'array');
      expect((steps['items'] as Map)['type'], 'string');
      expect(steps['description'], 'different steps to follow, should be in sorted order');
      // Go: {"properties":{"response":{"description":"The complete response to provide to the user","type":"string"}},"required":["response"],"type":"object"}
      final respond = _schema(PlanExecute.respondToolInfo);
      expect(respond['required'], ['response']);
      expect(((respond['properties']! as Map)['response'] as Map)['description'], 'The complete response to provide to the user');
      expect(PlanExecute.planToolInfo.desc, startsWith('Plan with a list of steps to execute in order.'));
      expect(PlanExecute.respondToolInfo.desc, startsWith('Generate a direct response to the user.'));
    });

    test('the prompts format as eino\'s', () async {
      final planner = await PlanExecute.plannerPrompt.format({
        'input': [Message.user('objective')],
      });
      expect(planner.map((m) => m.role), [RoleType.system, RoleType.user]);
      expect(planner.first.content, startsWith('You are an expert planning agent.'));
      final executor = await defaultGenExecutorInput(
        ctx,
        ExecutionContext(
          userInput: [Message.user('one'), Message.user('two')],
          plan: DefaultPlan(['s1', 's2']),
          executedSteps: const [ExecutedStep(step: 's0', result: 'r0')],
        ),
      );
      expect(
        executor.last.content,
        '## OBJECTIVE\none\ntwo\n\n## Given the following plan:\n{"steps":["s1","s2"]}\n'
        '## COMPLETED STEPS & RESULTS\nStep: s0\nResult: r0\n\n\n'
        '## Your task is to execute the first step, which is: \ns1',
      );
      final replanner = await defaultGenReplannerInput('P', 'R')(
        ctx,
        ExecutionContext(userInput: [Message.user('o')], plan: DefaultPlan(['s'])),
      );
      expect(replanner.first.content, contains("Call 'R' with:"));
      expect(replanner.first.content, contains("Call 'P' with a revised plan"));
      expect(formatInput([Message.user('a'), Message.assistant('b')]), 'a\nb\n');
      expect(formatExecutedSteps(const [ExecutedStep(step: 'x', result: 'y')]), 'Step: x\nResult: y\n\n');
    });

    test('PlanExecuteLoopConfig and the part configurations default as eino', () {
      final agent = _Seed(const {});
      final config = PlanExecuteLoopConfig(planner: agent, executor: agent, replanner: agent);
      expect(config.maxIterations, 10);
      final executor = ExecutorConfig(model: ScriptedChatModel(const []));
      expect(executor.maxIterations, 20);
      expect(executor.genInput, isNull);
      const planner = PlannerConfig();
      expect((planner.toolInfo, planner.genInput, planner.planDecoder), (null, null, null));
    });

    test('create: the runners, their names and a non-positive maxIterations', () async {
      final agent = _Seed(const {});
      final created = await PlanExecute.create(
        ctx,
        PlanExecuteLoopConfig(planner: agent, executor: agent, replanner: agent, maxIterations: 0),
      );
      expect(created.name, 'plan_execute_replan');
      expect(created.description, '');
    });

    test('planner: a model is required; withTools is called once with the plan tool', () async {
      expect(() => PlanExecute.planner(ctx, const PlannerConfig()), throwsArgumentError);
      final model = ScriptedChatModel(const []);
      final custom = ToolInfo.fromParams(name: 'my_plan', params: const {});
      final planner = await PlanExecute.planner(ctx, PlannerConfig(toolCallingChatModel: model, toolInfo: custom)) as PlannerAgent;
      expect(planner.toolCall, isTrue);
      expect((planner.chatModel as ScriptedChatModel).tools!.map((t) => t.name), ['my_plan']);
      expect((planner.name, planner.description), ('planner', 'a planner agent'));
      final formatted = await PlanExecute.planner(ctx, PlannerConfig(chatModelWithFormattedOutput: model)) as PlannerAgent;
      expect(formatted.toolCall, isFalse);
      expect(formatted.chatModel, same(model));
    });

    test('replanner: both tools are bound; custom names reach the prompt', () async {
      final model = ScriptedChatModel(const []);
      final replanner = await PlanExecute.replanner(
        ctx,
        ReplannerConfig(
          chatModel: model,
          planTool: ToolInfo.fromParams(name: 'Plan', params: const {}),
          respondTool: ToolInfo.fromParams(name: 'Respond', params: const {}),
        ),
      ) as ReplannerAgent;
      expect((replanner.chatModel as ScriptedChatModel).tools!.map((t) => t.name), ['Plan', 'Respond']);
      expect((replanner.name, replanner.description), ('replanner', 'a replanner agent'));
    });
  });

  group('planner and replanner runs', () {
    test('planner, tool mode, streaming: the event streams the arguments; the plan is stored', () async {
      final model = ScriptedChatModel([
        [
          Message(role: RoleType.assistant, content: '', toolCalls: [
            ToolCall(index: 0, id: 'c', function: FunctionCall(name: 'plan', arguments: '{"steps":')),
          ]),
          Message(role: RoleType.assistant, content: '', toolCalls: [
            ToolCall(index: 0, id: '', function: FunctionCall(name: '', arguments: '["x"]}')),
          ]),
        ],
      ]);
      final planner = await PlanExecute.planner(ctx, PlannerConfig(toolCallingChatModel: model));
      Plan? stored;
      final events = await Runner(
        agent: SequentialRunner(name: 's', subAgents: [planner, _Probe((ctx) => stored = ctx.sessionValue(PlanExecute.planSessionKey) as Plan?)]),
        enableStreaming: true,
      ).query(ctx, 'go').collectAll();
      expect(events, hasLength(1));
      final variant = events.single.output!.messageOutput!;
      expect(variant, isA<MessageVariant>());
      expect((await variant.getMessage()).content, '{"steps":["x"]}');
      expect(stored, DefaultPlan(['x']));
      expect(model.calls.single.options?.toolChoice, ToolChoice.forced);
    });

    test('planner: no tool call and a bad plan are errors as in eino', () async {
      final noCall = await PlanExecute.planner(
        ctx,
        PlannerConfig(toolCallingChatModel: ScriptedChatModel([
          [text('no tools')],
        ])),
      );
      final first = await Runner(agent: noCall).query(ctx, 'go').collectAll();
      expect('${first.last.error}', contains('no tool call'));
      final bad = await PlanExecute.planner(
        ctx,
        PlannerConfig(chatModelWithFormattedOutput: ScriptedChatModel([
          [text('not a plan')],
        ])),
      );
      final second = await Runner(agent: bad).query(ctx, 'go').collectAll();
      expect('${second.last.error}', contains('unmarshal plan error:'));
    });

    test('replanner: records the executed step; respond sends a LoopBreak when run directly', () async {
      final model = ScriptedChatModel([
        [_call('r', 'respond', '{"response":"bye"}')],
      ]);
      final replanner = await PlanExecute.replanner(ctx, ReplannerConfig(chatModel: model));
      List<ExecutedStep>? steps;
      final events = await Runner(
        agent: SequentialRunner(name: 's', subAgents: [
          _Seed({
            PlanExecute.planSessionKey: DefaultPlan(['step 1']),
            PlanExecute.executedStepSessionKey: 'done 1',
            PlanExecute.userInputSessionKey: [Message.user('u')],
          }),
          replanner,
          _Probe((ctx) => steps = (ctx.sessionValue(PlanExecute.executedStepsSessionKey) as List?)?.cast<ExecutedStep>()),
        ]),
      ).query(ctx, 'go').collectAll();
      expect(events.map((e) => e.error), everyElement(isNull));
      expect((await getMessageFromEvent(events.first))!.content, '{"response":"bye"}');
      expect(events.last.action?.customizedAction, const LoopBreak('replanner'));
      expect(steps, const [ExecutedStep(step: 'step 1', result: 'done 1')]);
      expect(model.calls.single.options?.toolChoice, ToolChoice.forced);
    });

    test('replanner: missing session values, no tool call and an unknown tool are errors as in eino', () async {
      Future<String> errorOf(ScriptedChatModel model, Map<String, Object?> values) async {
        final replanner = await PlanExecute.replanner(ctx, ReplannerConfig(chatModel: model));
        final events = await Runner(agent: SequentialRunner(name: 's', subAgents: [_Seed(values), replanner]))
            .query(ctx, 'go')
            .collectAll();
        return '${events.last.error}';
      }

      final full = {
        PlanExecute.planSessionKey: DefaultPlan(['a']),
        PlanExecute.executedStepSessionKey: 'r',
        PlanExecute.userInputSessionKey: [Message.user('u')],
      };
      expect(await errorOf(ScriptedChatModel(const []), const {}), contains('impossible: execute result not found'));
      expect(
        await errorOf(ScriptedChatModel([
          [text('just text')],
        ]), full),
        contains('no tool call'),
      );
      expect(
        await errorOf(ScriptedChatModel([
          [_call('x', 'other', '{}')],
        ]), full),
        contains('unexpected tool call: other'),
      );
      expect(
        await errorOf(ScriptedChatModel([
          [_call('x', 'plan', '{"steps":3}')],
        ]), full),
        contains('unmarshal plan error:'),
      );
    });
  });

  group('executor', () {
    test('a missing plan is eino\'s impossible panic', () async {
      final executor = await PlanExecute.executor(ctx, ExecutorConfig(model: ScriptedChatModel(const [])));
      final events = await Runner(agent: executor).query(ctx, 'go').collectAll();
      expect('${events.last.error}', contains('impossible: plan not found'));
    });

    test('the final answer is stored as ExecutedStep, also for a returnDirectly tool', () async {
      Future<Object?> executedStep(ScriptedChatModel model, {ToolsConfig tools = const ToolsConfig()}) async {
        final executor = await PlanExecute.executor(ctx, ExecutorConfig(model: model, toolsConfig: tools));
        Object? stored;
        final events = await Runner(
          agent: SequentialRunner(name: 's', subAgents: [
            _Seed({
              PlanExecute.planSessionKey: DefaultPlan(['a']),
              PlanExecute.userInputSessionKey: [Message.user('u')],
            }),
            executor,
            _Probe((ctx) => stored = ctx.sessionValue(PlanExecute.executedStepSessionKey)),
          ]),
        ).query(ctx, 'go').collectAll();
        expect(events.map((e) => e.error), everyElement(isNull));
        return stored;
      }

      expect(
        await executedStep(ScriptedChatModel([
          [text('answer')],
        ])),
        'answer',
      );
      expect(
        await executedStep(
          ScriptedChatModel([
            [
              Message(role: RoleType.assistant, content: '', toolCalls: [
                ToolCall(id: '1', function: FunctionCall(name: 'direct', arguments: '{}')),
                ToolCall(id: '2', function: FunctionCall(name: 'other', arguments: '{}')),
              ]),
            ],
          ]),
          tools: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [_Echo('direct'), _Echo('other')]),
            returnDirectly: const {'direct'},
          ),
        ),
        'direct result',
      );
    });
  });

  group('deep agent pieces', () {
    test('DeepAgentConfig defaults', () {
      final config = DeepAgentConfig(chatModel: ScriptedChatModel(const []));
      expect(config.maxIteration, 20);
      expect((config.withoutWriteTodos, config.withoutGeneralSubAgent), (false, false));
      expect((config.backend, config.shell, config.streamingShell), (null, null, null));
      expect(config.subAgents, isEmpty);
      expect(config.handlers, isEmpty);
    });

    test('Todo: JSON in eino\'s field order, equality, type errors', () {
      const todo = Todo(content: 'c', activeForm: 'doing c', status: 'in_progress');
      expect(jsonEncode(todo.toJson()), '{"content":"c","activeForm":"doing c","status":"in_progress"}');
      expect(Todo.fromJson(todo.toJson()), todo);
      expect(Todo.fromJson(const {}), const Todo(content: '', activeForm: '', status: ''));
      expect(() => Todo.fromJson(const {'content': 1}), throwsA(isA<ThreepioFormatException>()));
    });

    test('write_todos has the schema Go\'s InferTool derives', () async {
      final info = await newWriteTodosTool().info();
      expect(info.name, 'write_todos');
      // Go: {"properties":{"todos":{"items":{"properties":{"content":{"type":"string"},"activeForm":{"type":"string"},"status":{"enum":["pending","in_progress","completed"],"type":"string"}},"additionalProperties":false,"required":["content","activeForm","status"],"type":"object"},"type":"array"}},"additionalProperties":false,"required":["todos"],"type":"object"}
      final schema = _schema(info);
      expect(schema['required'], ['todos']);
      expect(schema['additionalProperties'], false);
      final todos = (schema['properties']! as Map)['todos'] as Map;
      expect(todos['type'], 'array');
      final item = todos['items'] as Map;
      expect(item['type'], 'object');
      expect(item['required'], ['content', 'activeForm', 'status']);
      expect(item['additionalProperties'], false);
      expect((item['properties'] as Map).keys, ['content', 'activeForm', 'status']);
    });

    test('write_todos with null todos answers "null", as Go marshals a nil slice', () async {
      final tool = newWriteTodosTool();
      expect(await tool.invokableRun(ctx, '{"todos":null}'), 'Updated todo list to null');
      expect(await tool.invokableRun(ctx, '{"todos":[]}'), 'Updated todo list to []');
      expect(() => tool.invokableRun(ctx, '{"todos":"x"}'), throwsA(isA<ThreepioException>()));
    });

    test('the task tool\'s parameters and default description', () async {
      final tool = newTaskTool(subAgents: [_Seed(const {})], withoutGeneralSubAgent: true);
      final info = await tool.info();
      expect(info.name, 'task');
      // Go: {"properties":{"description":{"type":"string"},"subagent_type":{"type":"string"}},"type":"object"}
      final schema = _schema(info);
      expect((schema['properties']! as Map).keys.toSet(), {'subagent_type', 'description'});
      expect(schema['required'], isEmpty);
      expect(info.desc, contains('- seed: seeds the session\n'));
      expect(info.desc, contains('function isPrime(n) {\n'), reason: 'pyfmt turns {{ into {');
      expect(defaultTaskToolDescription(ctx, const []), isNot(contains('{other_agents}')));
      expect(() => newTaskTool(subAgents: const [], withoutGeneralSubAgent: false), throwsArgumentError);
    });

    test('deepGenModelInput does not format the instruction', () {
      final input = AgentInput(messages: [Message.user('hi')]);
      final messages = deepGenModelInput(ctx, 'use {braces}', input);
      expect(messages.map((m) => (m.role, m.content)), [(RoleType.system, 'use {braces}'), (RoleType.user, 'hi')]);
      expect(deepGenModelInput(ctx, '', input).single.content, 'hi');
    });

    test('AppendPromptToolMiddleware appends its prompt and tool', () async {
      final tool = _Echo('t');
      final agent = ChatModelAgentContext(instruction: 'base', tools: [_Echo('x')], returnDirectly: const {});
      final (_, changed) = await AppendPromptToolMiddleware(prompt: '+more', tool: tool).beforeAgent(ctx, agent);
      expect(changed.instruction, 'base+more');
      expect(changed.tools.last, same(tool));
      final (_, unchanged) = await const AppendPromptToolMiddleware().beforeAgent(ctx, changed);
      expect(unchanged.tools, hasLength(2));
    });

    test('buildBuiltinMiddlewares: write_todos, then the file tools; shell rules', () {
      final model = ScriptedChatModel(const []);
      final both = buildBuiltinMiddlewares(DeepAgentConfig(chatModel: model, backend: InMemoryBackend()));
      expect(both, hasLength(2));
      expect(both.first, isA<AppendPromptToolMiddleware>());
      expect(both.last, isA<FilesystemMiddleware>());
      expect(buildBuiltinMiddlewares(DeepAgentConfig(chatModel: model, withoutWriteTodos: true)), isEmpty);
      expect(
        () => buildBuiltinMiddlewares(DeepAgentConfig(chatModel: model, shell: _Shell())),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'backend should not be nil')),
      );
    });

    test('Chinese prompts follow setAdkLanguage', () async {
      addTearDown(() => setAdkLanguage(AdkLanguage.english));
      setAdkLanguage(AdkLanguage.chinese);
      expect(deepBaseAgentInstruction(), contains('你'));
      expect(deepTaskPrompt(), contains('task'));
      expect(deepGeneralAgentDescription(), startsWith('通用代理'));
      expect(await newWriteTodosTool().invokableRun(ctx, '{"todos":[]}'), '已更新待办列表为 []');
      setAdkLanguage(AdkLanguage.english);
      expect(deepBaseAgentInstruction(), startsWith('\nYou are a helpful assistant.'));
    });
  });
}

/// An agent that calls [probe] with its context and sends nothing.
final class _Probe implements Agent {
  _Probe(this.probe);

  final void Function(RunContext ctx) probe;

  @override
  String get name => 'probe';

  @override
  String get description => 'reads the session';

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) {
    probe(ctx);
    return StreamReader.fromIterable(const []);
  }
}

final class _Shell implements Shell {
  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) async => const ExecuteResponse(output: '');
}
