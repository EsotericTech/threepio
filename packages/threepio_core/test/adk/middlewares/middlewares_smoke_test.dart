// Smoke tests of the P8 middlewares (eino `adk/middlewares`), each on a
// `ChatModelAgent` with the scripted model and `InMemoryBackend`, and all of
// them together in the recommended order. The ports of eino's tests are in
// the other files of this directory.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

import '../../support/scripted_chat_model.dart';

final ctx = RunContext.background();

Future<List<AgentEvent>> _run(Agent agent, List<Message> history, {bool streaming = false}) =>
    Runner(agent: agent, enableStreaming: streaming).run(ctx, history).collectAll();

ChatModelAgent _agent(
  BaseChatModel model,
  List<ChatModelAgentMiddleware> handlers, {
  List<BaseTool> tools = const [],
  String instruction = '',
}) =>
    ChatModelAgent(
      ChatModelAgentConfig(
        name: 'agent',
        description: 'test agent',
        instruction: instruction,
        model: model,
        handlers: handlers,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      ),
    );

Message _call(String id, String name, String args) => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [ToolCall(id: id, function: FunctionCall(name: name, arguments: args))],
    );

List<Message> _toolMessages(List<Message> messages) =>
    [for (final message in messages) if (message.role == RoleType.tool) message];

Set<String> _toolNames(ScriptedCall call) => {
      for (final info in call.options?.tools ?? const <ToolInfo>[]) info.name,
    };

final class _Echo extends InvokableTool {
  _Echo([this.output = 'echoed']);

  final String output;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'echo',
        desc: 'echoes its input',
        params: const {'text': ParameterInfo(type: DataType.string)},
      );

  @override
  Future<String> run(String argumentsJson) async => output;
}

final class _Named extends InvokableTool {
  _Named(this.name, this.desc);

  final String name;
  final String desc;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: name, desc: desc, params: const {});

  @override
  Future<String> run(String argumentsJson) async => '$name done';
}

/// Reads through [inner] and reports a missing file the way Go's agents.md
/// tests do (an error wrapping `os.ErrNotExist`), so that it is skipped.
/// `InMemoryBackend` itself reports a plain error, as eino's does.
final class _SkipMissingBackend implements FileReadBackend {
  _SkipMissingBackend(this.inner);

  final InMemoryBackend inner;

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async {
    try {
      return await inner.read(ctx, request);
    } on ThreepioException catch (error) {
      if (!error.message.startsWith('file not found')) rethrow;
      throw FileNotFoundException(request.filePath, cause: error);
    }
  }
}

final class _MapTaskBackend implements PlanTaskBackend {
  final Map<String, String> files = {};

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) async => [
        for (final path in files.keys)
          if (path.startsWith('${request.path}/')) FileInfo(path: path),
      ];

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async {
    final content = files[request.filePath];
    if (content == null) throw FileNotFoundException(request.filePath);
    return FileContent(content);
  }

  @override
  Future<void> write(RunContext ctx, WriteRequest request) async =>
      files[request.filePath] = request.content;

  @override
  Future<void> delete(RunContext ctx, DeleteRequest request) async => files.remove(request.filePath);
}

void main() {
  test('PatchToolCallsMiddleware answers a dangling tool call before the model sees it', () async {
    final model = ScriptedChatModel([
      [text('ok')],
    ]);
    final events = await _run(_agent(model, [const PatchToolCallsMiddleware()]), [
      Message.user('hi'),
      _call('c1', 'echo', '{}'),
      Message.user('again'),
    ]);
    expect(events.map((e) => e.error), everyElement(isNull));
    final sent = model.calls.single.messages;
    expect(sent.map((m) => m.role), [RoleType.user, RoleType.assistant, RoleType.tool, RoleType.user]);
    expect(sent[2].toolCallId, 'c1');
    expect(sent[2].toolName, 'echo');
    expect(
      sent[2].content,
      'Tool call echo with id c1 was canceled - another message came in before it could be completed.',
    );
  });

  test('AgentsMdMiddleware injects the files once, with imports, before the first user message',
      () async {
    final backend = InMemoryBackend();
    await backend.write(ctx, const WriteRequest(filePath: '/AGENTS.md', content: 'Be brief. @docs/style.md'));
    await backend.write(ctx, const WriteRequest(filePath: '/docs/style.md', content: 'Use bullets.'));
    final model = ScriptedChatModel([
      [_call('c1', 'echo', '{}')],
      [text('done')],
    ]);
    final events = await _run(
      _agent(
        model,
        [
          AgentsMdMiddleware(
            backend: _SkipMissingBackend(backend),
            agentsMdFiles: ['/AGENTS.md', '/missing.md'],
            onLoadWarning: (_, __) {},
          ),
        ],
        tools: [_Echo()],
        instruction: 'You help.',
      ),
      [Message.user('hi')],
    );
    expect(events.map((e) => e.error), everyElement(isNull));
    for (final call in model.calls) {
      final injected = call.messages.where((m) => m.content.startsWith('<system-reminder>')).toList();
      expect(injected, hasLength(1));
      expect(injected.single.role, RoleType.user);
      expect(injected.single.content, contains('Contents of /AGENTS.md (instructions):\n\nBe brief. @docs/style.md'));
      expect(injected.single.content, contains('Contents of /docs/style.md (instructions):\n\nUse bullets.'));
      expect(call.messages.indexOf(injected.single), 1, reason: 'after the system message');
    }
  });

  test('SummarizationMiddleware replaces a long history by a summary and reports it', () async {
    final summarizer = ScriptedChatModel([
      [text('<analysis>a</analysis>\n<summary>S <all_user_messages>\nX\n</all_user_messages></summary>')],
    ]);
    final model = ScriptedChatModel([
      [text('continued')],
    ]);
    final events = await _run(
      _agent(model, [
        SummarizationMiddleware(
          model: summarizer,
          trigger: const SummarizationTrigger(contextMessages: 2),
          emitInternalEvents: true,
          transcriptFilePath: '/t.txt',
        ),
      ], instruction: 'sys'),
      [Message.user('first'), Message.assistant('reply'), Message.user('second')],
    );
    expect(events.map((e) => e.error), everyElement(isNull));
    final summaryInput = summarizer.calls.single.messages;
    expect(summaryInput.first.role, RoleType.system);
    expect(summaryInput.first.content, 'You are a helpful AI assistant tasked with summarizing conversations.');
    expect(summaryInput.last.content, startsWith('CRITICAL: Respond with TEXT ONLY.'));
    expect(summaryInput.map((m) => m.content), containsAllInOrder(['first', 'reply', 'second']));

    final sent = model.calls.single.messages;
    expect(sent, hasLength(2));
    expect(sent[0].role, RoleType.system);
    final summary = sent[1];
    expect(summary.role, RoleType.user);
    expect(summary.extra?['_eino_summarization_content_type'], 'summary');
    expect(summary.content, startsWith('This session is being continued from a previous conversation'));
    expect(summary.content, contains('<all_user_messages>\n    - first\n    - second\n</all_user_messages>'));
    expect(summary.content, contains('read the full transcript at: /t.txt'));
    expect(summary.content, endsWith('Pick up the last task as if the break never happened.'));

    final actions = [
      for (final event in events)
        if (event.action?.customizedAction case final SummarizationAction action) action.type,
    ];
    expect(actions, [
      SummarizationActionType.beforeSummarize,
      SummarizationActionType.generateSummary,
      SummarizationActionType.afterSummarize,
    ]);
  });

  for (final streaming in [false, true]) {
    test('ToolReductionMiddleware cuts a large tool result and offloads it (streaming: $streaming)',
        () async {
      final backend = InMemoryBackend();
      final model = ScriptedChatModel([
        [_call('c1', 'echo', '{}')],
        [text('done')],
      ]);
      final events = await _run(
        _agent(
          model,
          [ToolReductionMiddleware(backend: backend, maxLengthForTrunc: 100)],
          tools: [_Echo('x' * 300)],
        ),
        [Message.user('go')],
        streaming: streaming,
      );
      expect(events.map((e) => e.error), everyElement(isNull));
      final toolMessage = _toolMessages(model.calls[1].messages).single;
      expect(toolMessage.content, startsWith('<persisted-output>\nOutput too large (300). Full output saved to: /tmp/trunc/c1'));
      expect(toolMessage.content, contains('Use read_file to view'));
      expect((await backend.read(ctx, const ReadRequest(filePath: '/tmp/trunc/c1'))).content, 'x' * 300);
    });
  }

  test('FilesystemMiddleware lets the agent write and read a file', () async {
    final backend = InMemoryBackend();
    final model = ScriptedChatModel([
      [_call('c1', 'write_file', '{"file_path":"/a.txt","content":"hello\\nworld"}')],
      [_call('c2', 'read_file', '{"file_path":"/a.txt"}')],
      [text('done')],
    ]);
    final events = await _run(
      _agent(model, [FilesystemMiddleware(backend: backend, customSystemPrompt: 'Use the files.')], instruction: 'sys'),
      [Message.user('go')],
    );
    expect(events.map((e) => e.error), everyElement(isNull));
    expect(_toolNames(model.calls.first), containsAll(['ls', 'read_file', 'write_file', 'edit_file', 'glob', 'grep']));
    expect(model.calls.first.messages.first.content, 'sys\nUse the files.');
    final results = _toolMessages(model.calls.last.messages).map((m) => m.content).toList();
    expect(results, ['Updated file /a.txt', '     1\thello\n     2\tworld']);
  });

  test('SkillMiddleware lists the skills and loads one inline', () async {
    final backend = InMemoryBackend();
    await backend.write(
      ctx,
      const WriteRequest(
        filePath: '/skills/pdf/SKILL.md',
        content: '---\nname: pdf\ndescription: Works with PDF files\n---\n\nDo PDF things.\n',
      ),
    );
    final model = ScriptedChatModel([
      [_call('c1', 'skill', '{"skill":"pdf"}')],
      [text('done')],
    ]);
    final events = await _run(
      _agent(model, [SkillMiddleware(backend: FilesystemSkillBackend(backend: backend, baseDir: '/skills'))]),
      [Message.user('make a pdf')],
    );
    expect(events.map((e) => e.error), everyElement(isNull));
    final info = model.calls.first.options!.tools!.singleWhere((t) => t.name == 'skill');
    expect(info.desc, contains('<skill>\n<name>\npdf\n</name>\n<description>\nWorks with PDF files\n</description>\n</skill>'));
    expect(
      _toolMessages(model.calls.last.messages).single.content,
      'Launching skill: pdf\nBase directory for this skill: /skills/pdf\n\nDo PDF things.',
    );
    expect(model.calls.first.messages.first.content, contains('# Skills System'));
  });

  test('PlanTaskMiddleware creates and lists tasks', () async {
    final backend = _MapTaskBackend();
    final model = ScriptedChatModel([
      [_call('c1', 'TaskCreate', '{"subject":"Write tests","description":"All of them","activeForm":"Writing tests"}')],
      [_call('c2', 'TaskList', '{}')],
      [text('done')],
    ]);
    final events = await _run(
      _agent(model, [PlanTaskMiddleware(backend: backend, baseDir: '/tasks')]),
      [Message.user('plan')],
    );
    expect(events.map((e) => e.error), everyElement(isNull));
    final results = _toolMessages(model.calls.last.messages).map((m) => m.content).toList();
    expect(results, [
      '{"result":"Task #1 created successfully: Write tests"}',
      '{"result":"#1 [pending] Write tests"}',
    ]);
    expect(backend.files['/tasks/.highwatermark'], '1');
    expect(
      backend.files['/tasks/1.json'],
      '{"id":"1","subject":"Write tests","description":"All of them","status":"pending",'
      '"blocks":[],"blockedBy":[],"activeForm":"Writing tests"}',
    );
  });

  test('ToolSearchMiddleware hides dynamic tools until the model finds them', () async {
    final weather = _Named('weather_get', 'Get the weather');
    final stock = _Named('stock_quote', 'Get a stock quote');
    final model = ScriptedChatModel([
      [_call('c1', 'tool_search', '{"query":"weather"}')],
      [_call('c2', 'weather_get', '{}')],
      [text('done')],
    ]);
    final events = await _run(
      _agent(model, [await ToolSearchMiddleware.create(dynamicTools: [weather, stock])], tools: [_Echo()]),
      [Message.user('weather?')],
    );
    expect(events.map((e) => e.error), everyElement(isNull));
    expect(_toolNames(model.calls[0]), {'echo', 'tool_search'});
    expect(_toolNames(model.calls[1]), {'echo', 'tool_search', 'weather_get'});
    final reminder = model.calls[0].messages.first;
    expect(reminder.content, '<available-deferred-tools>\nweather_get\nstock_quote\n</available-deferred-tools>');
    final results = _toolMessages(model.calls.last.messages).map((m) => m.content).toList();
    expect(results, ['{"matches":["weather_get"]}', 'weather_get done']);
  });

  test('all middlewares in the recommended order work together', () async {
    final backend = InMemoryBackend();
    await backend.write(ctx, const WriteRequest(filePath: '/AGENTS.md', content: 'Project rules.'));
    await backend.write(
      ctx,
      const WriteRequest(filePath: '/skills/s/SKILL.md', content: '---\nname: s\ndescription: d\n---\nBody'),
    );
    final summarizer = ScriptedChatModel([
      [text('<summary>short</summary>')],
    ]);
    final model = ScriptedChatModel([
      [_call('c2', 'write_file', '{"file_path":"/out.txt","content":"${'y' * 50}"}')],
      [_call('c3', 'read_file', '{"file_path":"/out.txt"}')],
      [_call('c4', 'skill', '{"skill":"s"}')],
      [_call('c5', 'TaskCreate', '{"subject":"s","description":"d"}')],
      [text('all done')],
    ]);
    final taskBackend = _MapTaskBackend();
    var counted = 0;
    final handlers = <ChatModelAgentMiddleware>[
      const PatchToolCallsMiddleware(),
      SummarizationMiddleware(
        model: summarizer,
        trigger: const SummarizationTrigger(contextTokens: 100),
        // Over the trigger on the first model call only.
        tokenCounter: (ctx, input) => counted++ == 0 ? 1000 : 0,
      ),
      AgentsMdMiddleware(backend: backend, agentsMdFiles: ['/AGENTS.md']),
      ToolReductionMiddleware(
        backend: backend,
        maxLengthForTrunc: 40,
        truncExcludeTools: const ['skill', 'TaskCreate'],
      ),
      FilesystemMiddleware(backend: backend),
      SkillMiddleware(backend: FilesystemSkillBackend(backend: backend, baseDir: '/skills')),
      PlanTaskMiddleware(backend: taskBackend, baseDir: '/tasks'),
    ];
    final events = await _run(_agent(model, handlers, instruction: 'sys'), [
      Message.user('one'),
      _call('c1', 'echo', '{}'),
      Message.user('two'),
      Message.assistant('three'),
    ]);
    expect(events.map((e) => e.error), everyElement(isNull));
    expect(summarizer.calls, hasLength(1));
    final first = model.calls.first.messages;
    expect(first.first.role, RoleType.system);
    expect(first[1].content, startsWith('<system-reminder>'));
    expect(first[2].extra?['_eino_summarization_content_type'], 'summary');
    final tools = _toolMessages(model.calls.last.messages);
    expect(tools.map((m) => m.toolCallId), ['c2', 'c3', 'c4', 'c5']);
    expect(tools[1].content, startsWith('<persisted-output>'));
    expect(tools[2].content, startsWith('Launching skill: s'));
    expect(tools[3].content, contains('Task #1 created successfully'));
    expect(taskBackend.files.keys, contains('/tasks/1.json'));
  });
}
