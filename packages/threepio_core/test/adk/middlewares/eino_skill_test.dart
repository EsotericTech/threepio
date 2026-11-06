// Port of eino `adk/middlewares/skill/skill_test.go` (v0.9.22).
//
// Ported: TestTool, TestSkillToolName, TestBuildParamsOneOf_CustomParams,
// TestBuildParamsOneOf_CustomParamsNilFallsBackToDefault, TestNewMiddleware,
// TestBeforeAgent, TestWrapModel_SwitchesModelWhenRunLocalIsSet,
// TestWrapModel_OutsideAgentContextReturnsError,
// TestWrapModel_IgnoresNonStringRunLocalValue, TestWrapModel_ModelHubGetError,
// TestWrapModel_ModelHubNilKeepsBase, TestWrapModel_RunLocalNotFoundKeepsBase,
// TestWrapModel_IgnoresEmptyStringRunLocalValue,
// TestGetMessagesFromState_InAgentContext, TestSkillToolInfo,
// TestInvokableRun_InlineMode, TestInvokableRun_AgentMode.
//
// Adapted: TestTool and TestSkillToolName build the middleware with the
// deprecated `skill.New`, which is not ported; they use `SkillMiddleware`
// (Go `NewMiddleware`), whose tool and instruction are the same
// (`AdditionalTools[0]` → `mw.tool`, `AdditionalInstruction` →
// `mw.instruction`).
//
// Not ported:
// * TestNewMiddleware/"nil config returns error" and "nil backend returns
//   error": a nil config or backend is a compile-time error in Dart
//   (required parameter).
// * TestNewTypedAgenticMessage and skill_generic_test.go: agentic messages
//   are P13.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/skill/prompt.dart'
    show skillToolDescriptionBase;
import 'package:threepio_core/src/adk/middlewares/skill/skill.dart'
    show SkillTool, messagesFromState, skillActiveModelKey;

final ctx = RunContext.background();

// ---------------------------------------------------------------------------
// Fakes (Go: inMemoryBackend, errorBackend, mockModel, mockModelHub,
// fakeToolCallingModel, runLocalSetterHandler, stateMessagesCaptureHandler,
// mockAgent, mockAgentHub).
// ---------------------------------------------------------------------------

/// Go `inMemoryBackend`.
final class _InMemorySkillBackend implements SkillBackend {
  _InMemorySkillBackend(this.skills);

  final List<Skill> skills;

  @override
  Future<List<SkillFrontMatter>> list(RunContext ctx) async =>
      [for (final skill in skills) skill.frontMatter];

  @override
  Future<Skill> get(RunContext ctx, String name) async {
    for (final skill in skills) {
      if (skill.name == name) return skill;
    }
    throw const ThreepioException('skill not found');
  }
}

/// Go `errorBackend` (only its `listErr` is used by the tests).
final class _ErrorBackend implements SkillBackend {
  _ErrorBackend({required this.listError});

  final Exception listError;

  @override
  Future<List<SkillFrontMatter>> list(RunContext ctx) async => throw listError;

  @override
  Future<Skill> get(RunContext ctx, String name) async => throw UnimplementedError('_ErrorBackend.get');
}

/// Go `mockModel`: a model that is only passed around.
final class _NamedModel extends BaseChatModel {
  _NamedModel(this.name);

  final String name;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError('_NamedModel.generate');

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError('_NamedModel.stream');
}

/// Go `mockModelHub`.
final class _ModelHub implements ModelHub {
  _ModelHub(this.models);

  final Map<String, BaseChatModel> models;

  @override
  Future<BaseChatModel> get(RunContext ctx, String name) async {
    final model = models[name];
    if (model == null) throw ThreepioException('model not found: $name');
    return model;
  }
}

/// Go `fakeToolCallingModel`: answers its [id]; counts `Generate` calls.
final class _FakeToolCallingModel extends ToolCallingChatModel {
  _FakeToolCallingModel(this.id);

  final String id;
  int calls = 0;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    calls++;
    return Message.assistant(id);
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) =>
      throw const ThreepioException('EOF');

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Go `runLocalSetterHandler`.
final class _RunLocalSetter extends ChatModelAgentMiddleware {
  _RunLocalSetter(this.key, this.value);

  final String key;
  final Object? value;

  @override
  FutureOr<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) {
    ctx.setRunLocalValue(key, value);
    return (ctx, state);
  }
}

/// Go `stateMessagesCaptureHandler`.
final class _StateMessagesCapture extends ChatModelAgentMiddleware {
  List<Message>? captured;

  @override
  Future<(RunContext, ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    captured = await messagesFromState(ctx);
    return (ctx, state);
  }
}

/// Go `mockAgent`: replays [events]; records its last input.
final class _MockAgent implements Agent {
  _MockAgent(this.events);

  final List<AgentEvent> events;
  AgentInput? lastIn;

  @override
  String get name => 'mock-agent';

  @override
  String get description => 'mock agent for testing';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    lastIn = input;
    return StreamReader.fromIterable(events);
  }
}

/// Go `mockAgentHub`.
final class _AgentHub implements AgentHub {
  _AgentHub({this.agents = const {}, this.defaultAgent});

  final Map<String, Agent> agents;
  final Agent? defaultAgent;
  AgentHubOptions? lastOpts;

  @override
  Future<Agent> get(RunContext ctx, String name, AgentHubOptions options) async {
    lastOpts = options;
    final fallback = defaultAgent;
    if (name.isEmpty && fallback != null) return fallback;
    final agent = agents[name];
    if (agent == null) throw ThreepioException('agent not found: $name');
    return agent;
  }
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Go `assert.Error` + `assert.Contains(err.Error(), …)` for every part.
Matcher _throwsContaining(List<String> parts) => throwsA(
      predicate<Object?>(
        (error) => parts.every('$error'.contains),
        'an error containing $parts',
      ),
    );

AgentEvent _messageEvent(String content) =>
    AgentEvent(output: AgentOutput(messageOutput: MessageVariant.message(Message.assistant(content))));

ChatModelAgent _agent(BaseChatModel model, List<ChatModelAgentMiddleware> handlers) => ChatModelAgent(
      ChatModelAgentConfig(
        name: 't',
        description: 't',
        model: model,
        handlers: handlers,
        maxIterations: 1,
      ),
    );

/// Runs [agent] on "hi" (Go: the `iter.Next()` loop with
/// `require.NoError(t, ev.Err)`); returns the content of the last message.
Future<String> _lastContent(ChatModelAgent agent) async {
  final events = agent.run(ctx, AgentInput(messages: [Message.user('hi')]));
  var last = '';
  for (var event = await events.nextOrNull(); event != null; event = await events.nextOrNull()) {
    expect(event.error, isNull);
    final variant = event.output?.messageOutput;
    if (variant == null) continue;
    last = (await variant.getMessage()).content;
  }
  return last;
}

const _pdfSkill = Skill(
  frontMatter: SkillFrontMatter(name: 'pdf', description: 'PDF processing'),
  content: 'Process PDF files here',
  baseDirectory: '/skills/pdf',
);

const _expectedSkillList = '''

<available_skills>
<skill>
<name>
name1
</name>
<description>
desc1
</description>
</skill>
<skill>
<name>
name2
</name>
<description>
desc2
</description>
</skill>
</available_skills>
''';

void main() {
  test('TestTool', () async {
    addTearDown(() => setAdkLanguage(AdkLanguage.english));
    final backend = _InMemorySkillBackend(const [
      Skill(
        frontMatter: SkillFrontMatter(name: 'name1', description: 'desc1'),
        content: 'content1',
        baseDirectory: 'basedir1',
      ),
      Skill(
        frontMatter: SkillFrontMatter(name: 'name2', description: 'desc2'),
        content: 'content2',
        baseDirectory: 'basedir2',
      ),
    ]);

    var to = SkillMiddleware(backend: backend).tool;
    var info = await to.info();
    expect(info.name, 'skill');
    var base = skillToolDescriptionBase();
    expect(info.desc, startsWith(base));
    expect(info.desc!.substring(base.length), _expectedSkillList);

    var result = await to.invokableRun(ctx, '{"skill": "name1"}');
    expect(result, 'Launching skill: name1\nBase directory for this skill: basedir1\n\ncontent1');

    // chinese
    setAdkLanguage(AdkLanguage.chinese);
    to = SkillMiddleware(backend: backend).tool;
    info = await to.info();
    expect(info.name, 'skill');
    base = skillToolDescriptionBase();
    expect(info.desc, startsWith(base));
    expect(info.desc!.substring(base.length), _expectedSkillList);

    result = await to.invokableRun(ctx, '{"skill": "name1"}');
    expect(result, '正在启动 Skill：name1\n此 Skill 的目录：basedir1\n\ncontent1');
  });

  test('TestSkillToolName', () async {
    // default
    var m = SkillMiddleware(backend: _InMemorySkillBackend(const []));
    expect(m.instruction, contains("'skill'"));
    var info = await m.tool.info();
    expect(info.name, 'skill');

    // customized
    m = SkillMiddleware(backend: _InMemorySkillBackend(const []), skillToolName: 'load_skill');
    expect(m.instruction, contains("'load_skill'"));
    info = await m.tool.info();
    expect(info.name, 'load_skill');
  });

  test('TestBuildParamsOneOf_CustomParams', () async {
    setAdkLanguage(AdkLanguage.english);
    final st = SkillTool(
      backend: _InMemorySkillBackend(const []),
      name: 'skill',
      customToolParams: (_, __) => const {
        'foo': ParameterInfo(type: DataType.string, desc: 'foo desc', required: true),
        'bar': ParameterInfo(type: DataType.integer, desc: 'bar desc'),
        'skill': ParameterInfo(type: DataType.string, desc: 'custom skill desc'),
      },
    );

    final js = ParamsOneOf.params(await st.buildParams(ctx)).toJsonSchema();
    final skillSchema = js.properties['skill'];
    expect(skillSchema, isNotNull);
    expect(skillSchema!.type, DataType.string.value);
    expect(skillSchema.description, 'custom skill desc');

    expect(js.properties.containsKey('foo'), isTrue);
    expect(js.properties.containsKey('bar'), isTrue);

    expect(js.required, ['foo', 'skill']);
  });

  test('TestBuildParamsOneOf_CustomParamsNilFallsBackToDefault', () async {
    final st = SkillTool(
      backend: _InMemorySkillBackend(const []),
      name: 'skill',
      customToolParams: (_, __) => null,
    );

    final js = ParamsOneOf.params(await st.buildParams(ctx)).toJsonSchema();
    expect(js.properties.containsKey('skill'), isTrue);
    expect(js.required, contains('skill'));
  });

  group('TestNewMiddleware', () {
    // "nil config returns error" and "nil backend returns error": not
    // portable (compile-time errors in Dart).

    test('custom tool params error surfaces in Info', () async {
      final handler = SkillMiddleware(
        backend: _InMemorySkillBackend(const []),
        customToolParams: (_, __) => throw const ThreepioException('bad params'),
      );
      await expectLater(
        handler.tool.info(),
        _throwsContaining(['failed to build skill tool params', 'bad params']),
      );
    });

    test('valid config succeeds', () {
      final handler = SkillMiddleware(backend: _InMemorySkillBackend(const []));
      expect(handler, isNotNull);
    });

    test('custom tool name', () {
      final handler = SkillMiddleware(
        backend: _InMemorySkillBackend(const [
          Skill(frontMatter: SkillFrontMatter(name: 's1', description: 'd1'), content: 'c1'),
        ]),
        skillToolName: 'load_skill',
      );
      expect(handler.instruction, contains("'load_skill'"));
      expect(handler.tool.name, 'load_skill');
    });

    test('custom system prompt', () {
      final handler = SkillMiddleware(
        backend: _InMemorySkillBackend(const []),
        customSystemPrompt: (_, toolName) => 'custom prompt for $toolName',
      );
      expect(handler.instruction, 'custom prompt for skill');
    });

    test('custom tool description', () async {
      final handler = SkillMiddleware(
        backend: _InMemorySkillBackend(const [
          Skill(frontMatter: SkillFrontMatter(name: 's1', description: 'd1'), content: 'c1'),
        ]),
        customToolDescription: (_, skills) => 'custom desc with ${skills.length} skills',
      );
      final info = await handler.tool.info();
      expect(info.desc, 'custom desc with 1 skills');
    });
  });

  test('TestBeforeAgent', () async {
    final handler = SkillMiddleware(
      backend: _InMemorySkillBackend(const [
        Skill(frontMatter: SkillFrontMatter(name: 's1', description: 'd1'), content: 'c1'),
      ]),
    );

    final runCtx = ChatModelAgentContext(
      instruction: 'base instruction',
      tools: const [],
      returnDirectly: const {},
    );
    final (_, newRunCtx) = await handler.beforeAgent(ctx, runCtx);
    expect(newRunCtx.instruction, contains('base instruction'));
    expect(newRunCtx.instruction, contains('Skills System'));
    expect(newRunCtx.tools, hasLength(1));

    // verify the added tool is the skill tool
    final info = await newRunCtx.tools[0].info();
    expect(info.name, 'skill');
  });

  test('TestWrapModel_SwitchesModelWhenRunLocalIsSet', () async {
    final base = _FakeToolCallingModel('base');
    final other = _FakeToolCallingModel('other');

    final handler = SkillMiddleware(
      backend: _InMemorySkillBackend(const []),
      modelHub: _ModelHub({'other': other}),
    );

    final agent = _agent(base, [_RunLocalSetter(skillActiveModelKey, 'other'), handler]);

    expect(await _lastContent(agent), 'other');
    expect(base.calls, 0);
    expect(other.calls, 1);
  });

  test('TestWrapModel_OutsideAgentContextReturnsError', () {
    final base = _FakeToolCallingModel('base');
    final other = _FakeToolCallingModel('other');

    final handler = SkillMiddleware(
      backend: _InMemorySkillBackend(const []),
      modelHub: _ModelHub({'other': other}),
    );

    // Dart's wrapModel is synchronous: Go's returned error is thrown.
    expect(
      () => handler.wrapModel(ctx, base, const ModelContext()),
      _throwsContaining(['failed to get active model from run local value']),
    );
  });

  test('TestWrapModel_IgnoresNonStringRunLocalValue', () async {
    final base = _FakeToolCallingModel('base');
    final other = _FakeToolCallingModel('other');

    final handler = SkillMiddleware(
      backend: _InMemorySkillBackend(const []),
      modelHub: _ModelHub({'other': other}),
    );

    final agent = _agent(base, [_RunLocalSetter(skillActiveModelKey, 123), handler]);

    expect(await _lastContent(agent), 'base');
    expect(base.calls, 1);
    expect(other.calls, 0);
  });

  test('TestWrapModel_ModelHubGetError', () async {
    final base = _FakeToolCallingModel('base');

    final handler = SkillMiddleware(
      backend: _InMemorySkillBackend(const []),
      modelHub: _ModelHub({}),
    );

    final agent = _agent(base, [_RunLocalSetter(skillActiveModelKey, 'missing'), handler]);

    final events = agent.run(ctx, AgentInput(messages: [Message.user('hi')]));
    Object? gotErr;
    for (var event = await events.nextOrNull(); event != null; event = await events.nextOrNull()) {
      if (event.error != null) {
        gotErr = event.error;
        break;
      }
    }
    await events.close();
    expect(gotErr, isNotNull);
    expect('$gotErr', contains('failed to get model'));
    expect(base.calls, 0);
  });

  test('TestWrapModel_ModelHubNilKeepsBase', () {
    final base = _FakeToolCallingModel('base');
    final handler = SkillMiddleware(backend: _InMemorySkillBackend(const []));

    final m = handler.wrapModel(ctx, base, const ModelContext());
    expect(m, same(base));
  });

  test('TestWrapModel_RunLocalNotFoundKeepsBase', () async {
    final base = _FakeToolCallingModel('base');
    final other = _FakeToolCallingModel('other');

    final handler = SkillMiddleware(
      backend: _InMemorySkillBackend(const []),
      modelHub: _ModelHub({'other': other}),
    );

    final agent = _agent(base, [handler]);

    expect(await _lastContent(agent), 'base');
    expect(base.calls, 1);
    expect(other.calls, 0);
  });

  test('TestWrapModel_IgnoresEmptyStringRunLocalValue', () async {
    final base = _FakeToolCallingModel('base');
    final other = _FakeToolCallingModel('other');

    final handler = SkillMiddleware(
      backend: _InMemorySkillBackend(const []),
      modelHub: _ModelHub({'other': other}),
    );

    final agent = _agent(base, [_RunLocalSetter(skillActiveModelKey, ''), handler]);

    expect(await _lastContent(agent), 'base');
    expect(base.calls, 1);
    expect(other.calls, 0);
  });

  test('TestGetMessagesFromState_InAgentContext', () async {
    final base = _FakeToolCallingModel('base');
    final capture = _StateMessagesCapture();

    final agent = _agent(base, [capture]);

    final events = agent.run(ctx, AgentInput(messages: [Message.user('hi')]));
    for (var event = await events.nextOrNull(); event != null; event = await events.nextOrNull()) {
      expect(event.error, isNull);
    }

    expect(capture.captured, isNotNull);
    expect(capture.captured, isNotEmpty);
  });

  group('TestSkillToolInfo', () {
    test('list error propagates', () async {
      final st = SkillTool(
        backend: _ErrorBackend(listError: const ThreepioException('list failed')),
        name: 'skill',
      );
      await expectLater(st.info(), _throwsContaining(['list failed']));
    });

    test('description contains all skills', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(frontMatter: SkillFrontMatter(name: 'alpha', description: 'desc-alpha')),
          Skill(frontMatter: SkillFrontMatter(name: 'beta', description: 'desc-beta')),
        ]),
        name: 'skill',
      );
      final info = await st.info();
      expect(info.desc, contains('alpha'));
      expect(info.desc, contains('desc-alpha'));
      expect(info.desc, contains('beta'));
      expect(info.desc, contains('desc-beta'));
    });

    test('custom tool params is used', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(frontMatter: SkillFrontMatter(name: 'alpha', description: 'desc-alpha')),
        ]),
        name: 'skill',
        customToolParams: (_, __) => const {
          'foo': ParameterInfo(type: DataType.string, desc: 'foo-desc', required: true),
          'skill': ParameterInfo(type: DataType.string, desc: 'custom-skill-desc'),
        },
      );
      final info = await st.info();
      final js = info.paramsOneOf!.toJsonSchema();
      expect(js.properties.containsKey('foo'), isTrue);
      final v = js.properties['skill'];
      expect(v, isNotNull);
      expect(v!.description, 'custom-skill-desc');
      expect(js.required, contains('skill'));
      expect(js.required, contains('foo'));
    });
  });

  group('TestInvokableRun_InlineMode', () {
    test('invalid json returns error', () async {
      final st = SkillTool(backend: _InMemorySkillBackend(const []), name: 'skill');
      await expectLater(st.invokableRun(ctx, 'not json'), _throwsContaining(['failed to unmarshal']));
    });

    test('skill not found returns error', () async {
      final st = SkillTool(backend: _InMemorySkillBackend(const []), name: 'skill');
      await expectLater(
        st.invokableRun(ctx, '{"skill": "nonexistent"}'),
        _throwsContaining(['failed to get skill']),
      );
    });

    test('inline mode returns skill content', () async {
      final st = SkillTool(backend: _InMemorySkillBackend(const [_pdfSkill]), name: 'skill');
      final result = await st.invokableRun(ctx, '{"skill": "pdf"}');
      expect(result, contains('pdf'));
      expect(result, contains('/skills/pdf'));
      expect(result, contains('Process PDF files here'));
    });

    test('inline mode with model triggers setActiveModel', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 'pdf', description: 'PDF processing', model: 'm1'),
            content: 'Process PDF files here',
            baseDirectory: '/skills/pdf',
          ),
        ]),
        name: 'skill',
      );
      // Outside a run the run-local value cannot be set; as in Go, that is
      // ignored.
      final result = await st.invokableRun(ctx, '{"skill": "pdf"}');
      expect(result, contains('pdf'));
    });

    test('custom skill content is used', () async {
      final rawArgsSeen = <String>[];
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [_pdfSkill]),
        name: 'skill',
        buildContent: (_, __, rawArgs) {
          rawArgsSeen.add(rawArgs);
          return 'custom-content';
        },
      );
      final result = await st.invokableRun(ctx, '{"skill":"pdf"}');
      expect(result, 'custom-content');
      // Go asserts inside the callback; recorded and asserted here.
      expect(rawArgsSeen, hasLength(1));
      final raw = jsonDecode(rawArgsSeen.single) as Map<String, Object?>;
      expect(raw['skill'], 'pdf');
    });

    test('custom tool params with decoder is used', () async {
      final rawArgsSeen = <String>[];
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [_pdfSkill]),
        name: 'skill',
        customToolParams: (_, __) => const {
          'skill': ParameterInfo(type: DataType.string, desc: 'custom'),
          'task': ParameterInfo(type: DataType.string, desc: 'custom'),
          'x': ParameterInfo(type: DataType.integer, desc: 'custom'),
        },
        buildContent: (_, __, rawArgs) {
          rawArgsSeen.add(rawArgs);
          return 'decoded';
        },
      );
      final result = await st.invokableRun(ctx, '{"skill":"pdf","task":"t","x":1}');
      expect(result, 'decoded');
      expect(rawArgsSeen, hasLength(1));
      final raw = jsonDecode(rawArgsSeen.single) as Map<String, Object?>;
      expect(raw['skill'], 'pdf');
      expect(raw['task'], 't');
      expect(raw['x'], 1);
    });

    test('custom skill content returns error', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [_pdfSkill]),
        name: 'skill',
        buildContent: (_, __, ___) => throw const ThreepioException('boom'),
      );
      await expectLater(
        st.invokableRun(ctx, '{"skill":"pdf"}'),
        _throwsContaining(['failed to build skill result']),
      );
    });
  });

  group('TestInvokableRun_AgentMode', () {
    const forkS1 = Skill(
      frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.fork),
      content: 'c1',
      baseDirectory: '/d',
    );

    test('fork mode without AgentHub returns error', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.fork), content: 'c1'),
        ]),
        name: 'skill',
      );
      await expectLater(
        st.invokableRun(ctx, '{"skill": "s1"}'),
        _throwsContaining(['AgentHub is not configured']),
      );
    });

    test('fork_with_context mode without AgentHub returns error', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.forkWithContext),
            content: 'c1',
          ),
        ]),
        name: 'skill',
      );
      await expectLater(
        st.invokableRun(ctx, '{"skill": "s1"}'),
        _throwsContaining(['AgentHub is not configured']),
      );
    });

    test('fork_with_context mode without state returns error', () async {
      final agent = _MockAgent([_messageEvent('agent response')]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.forkWithContext),
            content: 'c1',
            baseDirectory: '/d',
          ),
        ]),
        name: 'skill',
        agentHub: hub,
      );

      await expectLater(
        st.invokableRun(ctx, '{"skill":"s1"}'),
        _throwsContaining(['failed to get messages from state']),
      );
    });

    test('model specified without ModelHub returns error', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.fork, model: 'gpt-4'),
            content: 'c1',
          ),
        ]),
        name: 'skill',
        agentHub: _AgentHub(),
      );
      await expectLater(
        st.invokableRun(ctx, '{"skill": "s1"}'),
        _throwsContaining(['ModelHub is not configured']),
      );
    });

    test('model not found in ModelHub returns error', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.fork, model: 'gpt-4'),
            content: 'c1',
          ),
        ]),
        name: 'skill',
        agentHub: _AgentHub(),
        modelHub: _ModelHub({}),
      );
      await expectLater(
        st.invokableRun(ctx, '{"skill": "s1"}'),
        _throwsContaining(['failed to get model']),
      );
    });

    test('agent not found in AgentHub returns error', () async {
      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.fork, agent: 'nonexistent'),
            content: 'c1',
          ),
        ]),
        name: 'skill',
        agentHub: _AgentHub(agents: const {}),
      );
      await expectLater(
        st.invokableRun(ctx, '{"skill": "s1"}'),
        _throwsContaining(['failed to get agent']),
      );
    });

    test('fork mode runs agent and returns result', () async {
      final agent = _MockAgent([_messageEvent('agent response')]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 'test-skill', context: SkillContextMode.fork),
            content: 'skill content',
            baseDirectory: '/skills/test',
          ),
        ]),
        name: 'skill',
        agentHub: hub,
      );

      final result = await st.invokableRun(ctx, '{"skill": "test-skill"}');
      expect(result, contains('test-skill'));
      expect(result, contains('agent response'));
      expect(result, contains('completed'));
      // verify no model was passed in opts
      expect(hub.lastOpts, isNotNull);
      expect(hub.lastOpts!.model, isNull);
    });

    test('fork mode with model passes model to AgentHub', () async {
      final m = _NamedModel('test-model');
      final agent = _MockAgent([_messageEvent('response')]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(
        backend: _InMemorySkillBackend(const [
          Skill(
            frontMatter: SkillFrontMatter(name: 's1', context: SkillContextMode.fork, model: 'test-model'),
            content: 'c1',
            baseDirectory: '/skills/s1',
          ),
        ]),
        name: 'skill',
        agentHub: hub,
        modelHub: _ModelHub({'test-model': m}),
      );

      final result = await st.invokableRun(ctx, '{"skill": "s1"}');
      expect(result, contains('s1'));
      // verify model was passed
      expect(hub.lastOpts, isNotNull);
      expect(hub.lastOpts!.model, same(m));
    });

    test('agent returns multiple events', () async {
      final agent = _MockAgent([
        _messageEvent('part1'),
        const AgentEvent(), // nil output should be skipped
        _messageEvent('part2'),
      ]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(backend: _InMemorySkillBackend(const [forkS1]), name: 'skill', agentHub: hub);

      final result = await st.invokableRun(ctx, '{"skill": "s1"}');
      expect(result, contains('part1'));
      expect(result, contains('part2'));
    });

    test('agent returns empty content events', () async {
      final agent = _MockAgent([_messageEvent('')]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(backend: _InMemorySkillBackend(const [forkS1]), name: 'skill', agentHub: hub);

      final result = await st.invokableRun(ctx, '{"skill": "s1"}');
      // result should contain skill name but no extra content
      expect(result, contains('s1'));
    });

    test('agent event error returns error', () async {
      final agent = _MockAgent([const AgentEvent(error: ThreepioException('boom'))]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(backend: _InMemorySkillBackend(const [forkS1]), name: 'skill', agentHub: hub);

      await expectLater(
        st.invokableRun(ctx, '{"skill": "s1"}'),
        _throwsContaining(['failed to run agent event']),
      );
    });

    test('custom fork messages is used', () async {
      final agent = _MockAgent([_messageEvent('ok')]);
      final hub = _AgentHub(defaultAgent: agent);
      final inputs = <SkillSubAgentInput>[];

      final st = SkillTool(
        backend: _InMemorySkillBackend(const [forkS1]),
        name: 'skill',
        agentHub: hub,
        buildForkMessages: (_, input) {
          inputs.add(input);
          return [Message.user('custom')];
        },
      );

      await st.invokableRun(ctx, '{"skill": "s1"}');
      // Go asserts inside the callback; recorded and asserted here.
      expect(inputs, hasLength(1));
      expect(inputs.single.mode, SkillContextMode.fork);
      expect(inputs.single.skill.name, 's1');
      expect(agent.lastIn, isNotNull);
      expect(agent.lastIn!.messages, hasLength(1));
      final msg = agent.lastIn!.messages[0];
      expect(msg.content, 'custom');
    });

    test('custom fork messages returns error', () async {
      final agent = _MockAgent([_messageEvent('ok')]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(
        backend: _InMemorySkillBackend(const [forkS1]),
        name: 'skill',
        agentHub: hub,
        buildForkMessages: (_, __) => throw const ThreepioException('build msg fail'),
      );

      await expectLater(
        st.invokableRun(ctx, '{"skill": "s1"}'),
        _throwsContaining(['failed to build fork messages']),
      );
    });

    test('custom fork result prompts from results is used', () async {
      final agent = _MockAgent([_messageEvent('p1'), _messageEvent('p2')]);
      final hub = _AgentHub(defaultAgent: agent);
      final outputs = <SkillSubAgentOutput>[];

      final st = SkillTool(
        backend: _InMemorySkillBackend(const [forkS1]),
        name: 'skill',
        agentHub: hub,
        formatForkResult: (_, output) {
          outputs.add(output);
          return 'E:${output.results.join(',')}';
        },
      );

      final result = await st.invokableRun(ctx, '{"skill": "s1"}');
      expect(result, 'E:p1,p2');
      // Go asserts inside the callback; recorded and asserted here.
      expect(outputs, hasLength(1));
      expect(outputs.single.mode, SkillContextMode.fork);
      expect(outputs.single.results, ['p1', 'p2']);
    });

    test('custom fork result prompts returns error', () async {
      final agent = _MockAgent([_messageEvent('p1')]);
      final hub = _AgentHub(defaultAgent: agent);

      final st = SkillTool(
        backend: _InMemorySkillBackend(const [forkS1]),
        name: 'skill',
        agentHub: hub,
        formatForkResult: (_, __) => throw const ThreepioException('format fail'),
      );

      await expectLater(
        st.invokableRun(ctx, '{"skill":"s1"}'),
        _throwsContaining(['failed to format fork result', 'format fail']),
      );
    });
  });
}
