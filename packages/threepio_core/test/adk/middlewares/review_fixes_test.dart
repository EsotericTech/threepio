// Regression tests for the findings of the independent review of P8 (each
// names the Go behaviour it pins). The escaping fix of `goEscapeHtml` is
// tested in `p8_types_test.dart`.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/filesystem/filesystem.dart'
    show newStreamingExecuteTool;
import 'package:threepio_core/src/adk/middlewares/internal/go_compat.dart';
import 'package:threepio_core/src/adk/middlewares/internal/run_local.dart';
import 'package:threepio_core/src/adk/middlewares/reduction/reduction.dart'
    show messageInputPartToToolOutputPart;
import 'package:threepio_core/src/adk/middlewares/skill/skill.dart' show messagesFromState;

import '../../support/scripted_chat_model.dart';

final ctx = RunContext.background();

Message _call(String id, String name, String args) => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [ToolCall(id: id, function: FunctionCall(name: name, arguments: args))],
    );

final class _FailingModel extends BaseChatModel {
  _FailingModel({this.onCall});

  final void Function()? onCall;
  int calls = 0;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    calls++;
    onCall?.call();
    throw const ThreepioException('model down');
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError();
}

final class _OkModel extends BaseChatModel {
  int calls = 0;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    calls++;
    return Message.assistant('<summary>s</summary>');
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError();
}

/// Lists the skills of the tenant in the session values.
final class _TenantSkills implements SkillBackend {
  final List<String> seenTenants = [];

  @override
  Future<List<SkillFrontMatter>> list(RunContext ctx) async {
    final tenant = '${ctx.sessionValue('tenant')}';
    seenTenants.add(tenant);
    return [SkillFrontMatter(name: '$tenant-skill', description: 'for $tenant')];
  }

  @override
  Future<Skill> get(RunContext ctx, String name) async =>
      Skill(frontMatter: SkillFrontMatter(name: name), content: 'body');
}

final class _Recorder extends ChatModelAgentMiddleware {
  bool? unencodableSet;

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    unencodableSet = trySetRunLocalValue(ctx, 'not-json', Object());
    return (ctx, state);
  }
}

final class _Shell implements StreamingShell {
  _Shell(this.reader);

  final StreamReader<ExecuteResponse> reader;

  @override
  Future<StreamReader<ExecuteResponse>> executeStreaming(RunContext ctx, ExecuteRequest request) async =>
      reader;
}

void main() {
  group('summarization: a cancel is seen before a zero backoff (Go select on ctx.Done)', () {
    test('retry stops after the attempt during which the run was cancelled', () async {
      final token = CancelToken();
      final cancelled = RunContext.background(cancelToken: token);
      final model = _FailingModel(onCall: () => token.cancel('stop'));
      final mw = SummarizationMiddleware(model: model);
      final result = await mw.generateWithRetry(
        cancelled,
        model,
        [Message.user('x')],
        SummarizationRetryConfig(maxRetries: 3, backoff: (ctx, attempt, resp, err) => Duration.zero),
      );
      expect(model.calls, 1);
      expect(result.error, isA<CancelledException>());
    });

    test('failover stops with the cancel', () async {
      final token = CancelToken();
      final cancelled = RunContext.background(cancelToken: token);
      final model = _FailingModel(onCall: () => token.cancel('stop'));
      final mw = SummarizationMiddleware(
        model: model,
        failover: SummarizationFailoverConfig(
          maxRetries: 5,
          backoff: (ctx, attempt, resp, err) => Duration.zero,
        ),
      );
      await expectLater(
        mw.runFailover(cancelled, [Message.user('x')], [Message.user('x')], null, Exception('first')),
        throwsA(isA<CancelledException>()),
      );
      expect(model.calls, 1);
    });

    test('a nil last error under %w reads as Go prints it', () async {
      final model = _OkModel();
      final mw = SummarizationMiddleware(model: model);
      final result = await mw.generateWithRetry(
        ctx,
        model,
        [Message.user('x')],
        SummarizationRetryConfig(
          maxRetries: 1,
          shouldRetry: (ctx, resp, err) => true,
          backoff: (ctx, attempt, resp, err) => Duration.zero,
        ),
      );
      expect(model.calls, 2);
      expect('${(result.error! as ThreepioException).message}', 'exceeds max retries: %!w(<nil>)');
    });

    test('a trigger with only contextMessages fires on any token count above 0 (as in Go)', () async {
      final mw = SummarizationMiddleware(
        model: _OkModel(),
        trigger: const SummarizationTrigger(contextMessages: 100),
      );
      expect(await mw.shouldSummarize(ctx, TokenCounterInput(messages: [Message.user('four')])), isTrue);
      expect(await mw.shouldSummarize(ctx, TokenCounterInput(messages: [Message.user('abc')])), isFalse);
    });
  });

  group('skill front matter keeps the text of scalars (yaml.v3 into string fields)', () {
    test('numbers, booleans and quoted values', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/skills/a/SKILL.md',
          content: '---\nname: 007\ndescription: "4.10"\nagent: TRUE\nmodel: 4.10\ncontext: fork\n---\nbody',
        ),
      );
      final skill = await FilesystemSkillBackend(backend: backend, baseDir: '/skills').get(ctx, '007');
      expect(skill.name, '007');
      expect(skill.description, '4.10');
      expect(skill.agent, 'TRUE');
      expect(skill.model, '4.10');
      expect(skill.context, SkillContextMode.fork);
    });

    test('a null value is empty, a nested value is an error', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/skills/a/SKILL.md', content: '---\nname: a\nmodel: ~\n---\nbody'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/skills/b/SKILL.md', content: '---\nname: [x]\n---\nbody'),
      );
      final skills = FilesystemSkillBackend(backend: backend, baseDir: '/skills');
      await expectLater(skills.list(ctx), throwsA(predicate((e) => '$e'.contains('is not a scalar'))));
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/skills/b/SKILL.md', content: '---\nname: b\n---\nbody'),
      );
      expect((await skills.get(ctx, 'a')).model, '');
    });
  });

  test('the skill tool lists the skills with the run context (Go passes ctx to Info)', () async {
    final backend = _TenantSkills();
    final recorder = _Recorder();
    final model = ScriptedChatModel([
      [text('done')],
    ]);
    final agent = ChatModelAgent(
      ChatModelAgentConfig(
        name: 'a',
        description: 'd',
        model: model,
        handlers: [SkillMiddleware(backend: backend), recorder],
      ),
    );
    final events = await Runner(agent: agent).run(
      ctx,
      [Message.user('hi')],
      options: [AgentRunOption.sessionValues({'tenant': 'acme'})],
    ).collectAll();
    expect(events.map((e) => e.error), everyElement(isNull));
    expect(backend.seenTenants, contains('acme'));
    final info = model.calls.single.options!.tools!.singleWhere((t) => t.name == 'skill');
    expect(info.desc, contains('acme-skill'));
    // Go ignores the error of SetRunLocalValue for a value gob cannot encode.
    expect(recorder.unencodableSet, isFalse);
  });

  test('customToolParams returning null keeps its edits of the defaults (Go uses that map)', () async {
    final mw = SkillMiddleware(
      backend: _TenantSkills(),
      customToolParams: (ctx, defaults) {
        defaults['extra'] = const ParameterInfo(type: DataType.string, desc: 'added');
        return null;
      },
    );
    final params = await mw.tool.buildParams(ctx);
    expect(params.keys, containsAll(['skill', 'extra']));
    expect(params['skill']!.required, isTrue);
  });

  test('messagesFromState outside a run fails with Go\'s extra layer', () async {
    await expectLater(
      messagesFromState(ctx),
      throwsA(isA<ThreepioException>().having((e) => e.message, 'message', startsWith('failed to process state: '))),
    );
  });

  test('patch: a tool message without an id answers a call with an empty id (Go compares "")', () async {
    final (_, state) = await const PatchToolCallsMiddleware().beforeModelRewriteState(
      ctx,
      ChatModelAgentState(messages: [
        _call('', 't', '{}'),
        const Message(role: RoleType.tool, content: 'r'),
      ]),
      const ModelContext(),
    );
    expect(state.messages, hasLength(2));
  });

  group('reduction', () {
    ChatModelAgentState history() => ChatModelAgentState(messages: [
          Message.user('q'),
          _call('c1', 'big', '{}'),
          Message.tool(content: 'x' * 100, toolCallId: 'c1', toolName: 'big'),
          _call('c2', 'big', '{}'),
          Message.tool(content: 'y', toolCallId: 'c2', toolName: 'big'),
        ]);

    test('a clear handler that clears without a new result fails (Go dereferences it)', () async {
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        maxTokensForClear: 1,
        toolConfig: {
          'big': ToolReductionConfig(
            skipTruncation: true,
            clearHandler: (ctx, detail) => const ClearResult(needClear: true),
          ),
        },
      );
      await expectLater(
        mw.beforeModelRewriteState(ctx, history(), const ModelContext()),
        throwsA(predicate((e) => '$e'.contains('ToolArgument and ToolResult are required'))),
      );
    });

    test('a tool result without an id is found for a call with an empty id', () async {
      final mw = ToolReductionMiddleware(skipTruncation: true, maxTokensForClear: 1);
      final state = ChatModelAgentState(messages: [
        Message.user('q'),
        _call('', 'big', '{}'),
        const Message(role: RoleType.tool, content: 'old result'),
        _call('c2', 'big', '{}'),
        Message.tool(content: 'y', toolCallId: 'c2', toolName: 'big'),
      ]);
      final (_, after) = await mw.beforeModelRewriteState(ctx, state, const ModelContext());
      expect(after.messages[2].content, '[Old tool result content cleared]');
    });

    test('an unknown part type is named as Go names it', () {
      expect(
        () => messageInputPartToToolOutputPart(
          const MessageInputPart(type: ChatMessagePartType.toolSearchResult),
        ),
        throwsA(isA<ThreepioException>()
            .having((e) => e.message, 'message', 'unknown msg part type: tool_search_result')),
      );
    });
  });

  test('plan task: a high watermark that starts with a newline is not read (Go Sscanf %d)', () async {
    final files = <String, String>{'/t/.highwatermark': '\n7'};
    final tools = PlanTaskMiddleware(backend: _MapBackend(files), baseDir: '/t');
    final agentContext = ChatModelAgentContext(instruction: '', tools: const [], returnDirectly: const {});
    final (_, withTools) = await tools.beforeAgent(ctx, agentContext);
    final create = withTools.tools.first as InvokableTool;
    expect(await create.invokableRun(ctx, '{"subject":"s","description":"d"}'),
        '{"result":"Task #1 created successfully: s"}');
    files['/t/.highwatermark'] = '  41';
    expect(await create.invokableRun(ctx, '{"subject":"s","description":"d"}'),
        '{"result":"Task #42 created successfully: s"}');
  });

  test('tool search, model mode: no dynamic tool in the infos means no deferred tools (Go nil)', () async {
    final mw = await ToolSearchMiddleware.create(dynamicTools: [_Dyn()], useModelToolSearch: true);
    final (_, state) = await mw.beforeModelRewriteState(
      ctx,
      ChatModelAgentState(messages: [Message.user('q')], toolInfos: [ToolInfo.function(name: 'static')]),
      const ModelContext(),
    );
    expect(state.deferredToolInfos, isNull);
    expect(state.toolInfos.map((t) => t.name), ['static']);
  });

  test('goDir follows filepath.Dir for a trailing slash', () {
    expect(goDir('a/b/'), 'a/b');
    expect(goDir('/a/b'), '/a');
    expect(goDir('/'), '/');
    expect(goDir('a'), '.');
  });

  test('streaming execute: a consumer that closes early releases the command stream', () async {
    final (source, writer) = pipe<ExecuteResponse>();
    writer.send(const ExecuteResponse(output: 'line 1'));
    final tool = newStreamingExecuteTool(_Shell(source), '', '') as StreamableTool;
    final output = await tool.streamableRun(ctx, '{"command":"tail -f log"}');
    expect(await output.recv(), 'line 1');
    await output.close();
    await source.done.timeout(const Duration(seconds: 2));
    expect(writer.send(const ExecuteResponse(output: 'late')), isTrue, reason: 'the reader side is gone');
  });
}

final class _MapBackend implements PlanTaskBackend {
  _MapBackend(this.files);

  final Map<String, String> files;

  @override
  Future<void> delete(RunContext ctx, DeleteRequest request) async => files.remove(request.filePath);

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) async => [
        for (final path in files.keys)
          if (goDir(path) == request.path) FileInfo(path: path),
      ];

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async =>
      FileContent(files[request.filePath] ?? (throw FileNotFoundException(request.filePath)));

  @override
  Future<void> write(RunContext ctx, WriteRequest request) async => files[request.filePath] = request.content;
}

final class _Dyn extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: 'dyn', desc: 'dynamic', params: const {});

  @override
  Future<String> run(String argumentsJson) async => 'ok';
}
