// The two coordinator decisions after P8, applied in P9:
//
// 1. A missing agents.md follows Go: eino's in-memory backend reports a
//    missing file with a plain error (it does not wrap `os.ErrNotExist`), so
//    the agents.md middleware fails the run instead of skipping the file.
// 2. Tool search in model-native mode with no static tools follows Go: the
//    stripped tool list is nil, and eino's state wrapper fills a nil list with
//    every tool again before the next model call.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/middleware_context.dart'
    show UnsetToolInfos;

import '../../support/scripted_chat_model.dart';

final ctx = RunContext.background();

Message _call(String id, String name, String args) => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [ToolCall(id: id, function: FunctionCall(name: name, arguments: args))],
    );

List<String> _names(List<ToolInfo>? infos) => [for (final info in infos ?? const <ToolInfo>[]) info.name];

final class _Named extends InvokableTool {
  _Named(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: name, desc: '$name tool', params: const {});

  @override
  Future<String> run(String argumentsJson) async => '$name done';
}

ChatModelAgent _agent(BaseChatModel model, List<ChatModelAgentMiddleware> handlers, {List<BaseTool> tools = const []}) =>
    ChatModelAgent(
      ChatModelAgentConfig(
        name: 'agent',
        description: 'test agent',
        model: model,
        handlers: handlers,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      ),
    );

void main() {
  group('decision 1: a missing agents.md fails the run, as in Go', () {
    test('InMemoryBackend: the run fails with eino\'s error', () async {
      final backend = InMemoryBackend();
      final model = ScriptedChatModel([
        [text('never')],
      ]);
      final events = await Runner(
        agent: _agent(model, [AgentsMdMiddleware(backend: backend, agentsMdFiles: const ['/AGENTS.md'])]),
      ).query(ctx, 'hi').collectAll();

      final errors = [for (final event in events) if (event.error != null) event.error!];
      expect(errors, hasLength(1));
      // Go: "[agentsmd]: failed to load agent files: failed to load %q: %w".
      expect(
        '${errors.single}',
        contains('[agentsmd]: failed to load agent files: failed to load "/AGENTS.md": file not found: /AGENTS.md'),
      );
      final cause = ThreepioException.findCause<ThreepioException>(errors.single);
      expect(cause, isNotNull);
      expect(model.calls, isEmpty, reason: 'the model is never called');
    });

    test('a backend that reports FileNotFoundException still skips the file with a warning', () async {
      final backend = InMemoryBackend();
      await backend.write(ctx, const WriteRequest(filePath: '/AGENTS.md', content: 'Rules.'));
      final warnings = <String>[];
      final model = ScriptedChatModel([
        [text('ok')],
      ]);
      final events = await Runner(
        agent: _agent(model, [
          AgentsMdMiddleware(
            backend: _NotExistBackend(backend),
            agentsMdFiles: const ['/AGENTS.md', '/missing.md'],
            onLoadWarning: (path, error) => warnings.add('$path: $error'),
          ),
        ]),
      ).query(ctx, 'hi').collectAll();

      expect(events.map((e) => e.error), everyElement(isNull));
      expect(warnings, hasLength(1));
      expect(warnings.single, startsWith('/missing.md: '));
      expect(model.calls.single.messages.any((m) => m.content.contains('Rules.')), isTrue);
    });
  });

  group('decision 2: tool search, model-native mode without static tools, refills every tool', () {
    test('the first call sees no tools; the next one sees every tool again', () async {
      final mw = await ToolSearchMiddleware.create(
        dynamicTools: [_Named('dyn_a'), _Named('dyn_b')],
        useModelToolSearch: true,
      );
      final model = ScriptedChatModel([
        [_call('c1', 'dyn_a', '{}')],
        [text('done')],
      ]);
      final events = await Runner(agent: _agent(model, [mw])).query(ctx, 'go').collectAll();
      expect(events.map((e) => e.error), everyElement(isNull));
      expect(model.calls, hasLength(2));

      // Call 1: the stripped list is Go's nil (the model gets an empty list);
      // the dynamic tools are deferred.
      expect(_names(model.calls[0].options?.tools), isEmpty);
      expect(_names(model.calls[0].options?.deferredTools), ['dyn_a', 'dyn_b']);
      // Call 2: eino's backfill of the nil list: every tool of the agent, in
      // the agent's order (tool_search first, then the dynamic tools); the
      // deferred tools are kept.
      expect(_names(model.calls[1].options?.tools), ['tool_search', 'dyn_a', 'dyn_b']);
      expect(_names(model.calls[1].options?.deferredTools), ['dyn_a', 'dyn_b']);
    });

    test('with a static tool the list is not refilled', () async {
      final mw = await ToolSearchMiddleware.create(
        dynamicTools: [_Named('dyn_a')],
        useModelToolSearch: true,
      );
      final model = ScriptedChatModel([
        [_call('c1', 'static', '{}')],
        [text('done')],
      ]);
      final events = await Runner(
        agent: _agent(model, [mw], tools: [_Named('static')]),
      ).query(ctx, 'go').collectAll();
      expect(events.map((e) => e.error), everyElement(isNull));
      expect(_names(model.calls[0].options?.tools), ['static']);
      expect(_names(model.calls[1].options?.tools), ['static']);
    });

    test('streaming: the same refill', () async {
      final mw = await ToolSearchMiddleware.create(
        dynamicTools: [_Named('dyn_a'), _Named('dyn_b')],
        useModelToolSearch: true,
      );
      final model = ScriptedChatModel([
        [_call('c1', 'dyn_b', '{}')],
        [text('done')],
      ]);
      final events =
          await Runner(agent: _agent(model, [mw]), enableStreaming: true).query(ctx, 'go').collectAll();
      expect(events.map((e) => e.error), everyElement(isNull));
      expect(_names(model.calls[0].options?.tools), isEmpty);
      expect(model.calls[0].options?.tools, isNot(isA<UnsetToolInfos>()), reason: "the model gets Go's fresh empty list");
      expect(_names(model.calls[1].options?.tools), ['tool_search', 'dyn_a', 'dyn_b']);
    });

    test('a middleware after tool search that rebuilds the state keeps the nil list', () async {
      final mw = await ToolSearchMiddleware.create(dynamicTools: [_Named('dyn_a')], useModelToolSearch: true);
      final model = ScriptedChatModel([
        [_call('c1', 'dyn_a', '{}')],
        [text('done')],
      ]);
      final events = await Runner(agent: _agent(model, [mw, _Rebuild()])).query(ctx, 'go').collectAll();
      expect(events.map((e) => e.error), everyElement(isNull));
      expect(_names(model.calls[0].options?.tools), isEmpty);
      expect(_names(model.calls[1].options?.tools), ['tool_search', 'dyn_a']);
    });

    test('the nil list survives an interrupt and a resume', () async {
      final mw = await ToolSearchMiddleware.create(
        dynamicTools: [_Interrupting('dyn_a'), _Named('dyn_b')],
        useModelToolSearch: true,
      );
      final model = ScriptedChatModel([
        [_call('c1', 'dyn_a', '{}')],
        [text('done')],
      ]);
      final runner = Runner(agent: _agent(model, [mw]), checkpointStore: InMemoryCheckpointStore());
      final first = await runner.query(ctx, 'go', options: [AgentRunOption.checkpointId('cp')]).collectAll();
      expect(first.last.action?.interrupted, isNotNull);
      expect(_names(model.calls[0].options?.tools), isEmpty);
      final resumed = await (await runner.resume(ctx, 'cp')).collectAll();
      expect(resumed.map((e) => e.error), everyElement(isNull));
      expect(_names(model.calls[1].options?.tools), ['tool_search', 'dyn_a', 'dyn_b']);
    });

    test('UnsetToolInfos survives a rebuilt state and stops being nil once filled', () {
      final state = ChatModelAgentState(messages: const [])..unsetToolInfos();
      expect(state.hasUnsetToolInfos, isTrue);
      expect(state.toolInfos, isA<UnsetToolInfos>());
      // A middleware that returns a new state keeps Go's nil list.
      final rebuilt = ChatModelAgentState(messages: state.messages, toolInfos: state.toolInfos);
      expect(rebuilt.hasUnsetToolInfos, isTrue);
      // Appending makes it an ordinary list (Go's append to a nil slice).
      rebuilt.toolInfos.add(ToolInfo.fromParams(name: 'x', params: const {}));
      expect(rebuilt.hasUnsetToolInfos, isFalse);
      // An ordinary empty list is not nil.
      expect(ChatModelAgentState(messages: const []).hasUnsetToolInfos, isFalse);
    });

    test('a rebuilt state has a nil list of its own (Go copies the slice header)', () {
      final state = ChatModelAgentState(messages: const [])..unsetToolInfos();
      final rebuilt = ChatModelAgentState(messages: const [], toolInfos: state.toolInfos);
      expect(rebuilt.toolInfos, isNot(same(state.toolInfos)));
      rebuilt.toolInfos.add(ToolInfo.fromParams(name: 'x', params: const {}));
      expect(rebuilt.hasUnsetToolInfos, isFalse);
      expect(state.hasUnsetToolInfos, isTrue, reason: 'appending to the copy leaves the original nil');
    });
  });
}

/// Returns a new state on every model call, as a middleware that rewrites
/// the messages does.
final class _Rebuild extends ChatModelAgentMiddleware {
  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async =>
      (
        ctx,
        ChatModelAgentState(
          messages: state.messages,
          toolInfos: state.toolInfos,
          deferredToolInfos: state.deferredToolInfos,
        ),
      );
}

/// Interrupts on its first call and answers on resume.
final class _Interrupting extends InvokableTool {
  _Interrupting(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: name, desc: '$name tool', params: const {});

  @override
  Future<String> run(String argumentsJson) => invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async {
    if (!getInterruptState<Object>(ctx).wasInterrupted) throw interrupt(ctx, 'wait');
    return '$name resumed';
  }
}

/// Reports a missing file as Go's agents.md tests do (wrapping
/// `os.ErrNotExist`): a [FileNotFoundException].
final class _NotExistBackend implements FileReadBackend {
  _NotExistBackend(this.inner);

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
