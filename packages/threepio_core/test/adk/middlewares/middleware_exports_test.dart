// Every public P8 middleware (eino adk/middlewares) is reachable from
// `package:threepio_core/adk.dart` alone, is a ChatModelAgentMiddleware, and
// its constructor throws ArgumentError for the invalid configurations its
// dartdoc lists (Go's New returning an error for a bad config).
//
// Not a port of a Go test: it pins the public surface of the Dart port.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

final _ctx = RunContext.background();

final class _Model extends BaseChatModel {
  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async =>
      Message.assistant('summary');

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      StreamReader.fromIterable([Message.assistant('summary')]);
}

final class _TaskBackend implements PlanTaskBackend {
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
  Future<void> write(RunContext ctx, WriteRequest request) async => files[request.filePath] = request.content;

  @override
  Future<void> delete(RunContext ctx, DeleteRequest request) async => files.remove(request.filePath);
}

final class _Shell implements Shell {
  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) async =>
      const ExecuteResponse(output: 'ok', exitCode: 0);
}

final class _StreamingShell implements StreamingShell {
  @override
  Future<StreamReader<ExecuteResponse>> executeStreaming(RunContext ctx, ExecuteRequest request) async =>
      StreamReader.fromIterable(const [ExecuteResponse(output: 'ok', exitCode: 0)]);
}

final class _Tool extends InvokableTool {
  _Tool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: name, desc: 'tool $name', params: const {});

  @override
  Future<String> run(String argumentsJson) async => 'done';
}

final class _BrokenInfoTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => throw StateError('no info');

  @override
  Future<String> run(String argumentsJson) async => 'done';
}

Matcher _throwsArgumentError(String text) =>
    throwsA(isA<ArgumentError>().having((e) => '$e', 'text', contains(text)));

void main() {
  group('every middleware is reachable from adk.dart and is a ChatModelAgentMiddleware', () {
    test('PatchToolCallsMiddleware', () {
      const ChatModelAgentMiddleware mw = PatchToolCallsMiddleware();
      expect(mw, isA<PatchToolCallsMiddleware>());
      expect(
        PatchToolCallsMiddleware(generator: (ctx, toolName, toolCallId, arg) async => null),
        isA<ChatModelAgentMiddleware>(),
      );
    });

    test('AgentsMdMiddleware', () {
      final mw = AgentsMdMiddleware(backend: InMemoryBackend(), agentsMdFiles: const ['/AGENTS.md']);
      expect(mw, isA<ChatModelAgentMiddleware>());
    });

    test('SummarizationMiddleware', () {
      final mw = SummarizationMiddleware(model: _Model());
      expect(mw, isA<ChatModelAgentMiddleware>());
    });

    test('ToolReductionMiddleware', () {
      expect(ToolReductionMiddleware(backend: InMemoryBackend()), isA<ChatModelAgentMiddleware>());
      expect(ToolReductionMiddleware(skipTruncation: true), isA<ChatModelAgentMiddleware>());
    });

    test('FilesystemMiddleware', () {
      final mw = FilesystemMiddleware(backend: InMemoryBackend());
      expect(mw, isA<ChatModelAgentMiddleware>());
    });

    test('SkillMiddleware with FilesystemSkillBackend', () {
      final backend = FilesystemSkillBackend(backend: InMemoryBackend(), baseDir: '/skills');
      expect(backend, isA<SkillBackend>());
      final mw = SkillMiddleware(backend: backend);
      expect(mw, isA<ChatModelAgentMiddleware>());
    });

    test('PlanTaskMiddleware', () {
      final mw = PlanTaskMiddleware(backend: _TaskBackend(), baseDir: '/tasks');
      expect(mw, isA<ChatModelAgentMiddleware>());
    });

    test('ToolSearchMiddleware.create', () async {
      final mw = await ToolSearchMiddleware.create(dynamicTools: [_Tool('a')]);
      expect(mw, isA<ChatModelAgentMiddleware>());
    });
  });

  group('constructors throw ArgumentError for the invalid configurations of their dartdoc', () {
    test('AgentsMdMiddleware: no files, negative limits', () {
      final backend = InMemoryBackend();
      expect(
        () => AgentsMdMiddleware(backend: backend, agentsMdFiles: const []),
        _throwsArgumentError('at least one agent file path is required'),
      );
      expect(
        () => AgentsMdMiddleware(backend: backend, agentsMdFiles: const ['/AGENTS.md'], allAgentsMdMaxBytes: -1),
        _throwsArgumentError('AllAgentsMDMaxBytes must be non-negative'),
      );
      expect(
        () => AgentsMdMiddleware(backend: backend, agentsMdFiles: const ['/AGENTS.md'], perAgentsMdMaxBytes: -1),
        _throwsArgumentError('PerAgentsMDMaxBytes must be non-negative'),
      );
    });

    test('SummarizationMiddleware: invalid trigger, negative maxRetries', () {
      final model = _Model();
      expect(
        () => SummarizationMiddleware(model: model, trigger: const SummarizationTrigger(contextTokens: -1)),
        _throwsArgumentError('contextTokens must be non-negative'),
      );
      expect(
        () => SummarizationMiddleware(
          model: model,
          trigger: const SummarizationTrigger(contextMessages: -1),
        ),
        _throwsArgumentError('contextMessages must be non-negative'),
      );
      expect(
        () => SummarizationMiddleware(model: model, trigger: const SummarizationTrigger()),
        _throwsArgumentError('at least one of contextTokens or contextMessages'),
      );
      expect(
        () => SummarizationMiddleware(model: model, retry: const SummarizationRetryConfig(maxRetries: -1)),
        _throwsArgumentError('retry.MaxRetries must be non-negative'),
      );
      expect(
        () => SummarizationMiddleware(model: model, failover: const SummarizationFailoverConfig(maxRetries: -1)),
        _throwsArgumentError('failover.MaxRetries must be non-negative'),
      );
      // A valid trigger and zero retries are accepted.
      expect(
        SummarizationMiddleware(
          model: model,
          trigger: const SummarizationTrigger(contextMessages: 10),
          retry: const SummarizationRetryConfig(maxRetries: 0),
          failover: const SummarizationFailoverConfig(maxRetries: 0),
        ),
        isA<ChatModelAgentMiddleware>(),
      );
    });

    test('ToolReductionMiddleware: no backend unless skipTruncation', () {
      expect(
        ToolReductionMiddleware.new,
        _throwsArgumentError('backend must be set when not skipping truncation'),
      );
    });

    test('FilesystemMiddleware: shell and streaming shell, multimodal read without a MultiModalReader', () {
      final backend = InMemoryBackend();
      expect(
        () => FilesystemMiddleware(backend: backend, shell: _Shell(), streamingShell: _StreamingShell()),
        _throwsArgumentError('shell and streaming shell should not be both set'),
      );
      expect(backend, isNot(isA<MultiModalReader>()));
      expect(
        () => FilesystemMiddleware(backend: backend, useMultiModalRead: true),
        _throwsArgumentError('does not implement filesystem.MultiModalReader interface'),
      );
      // One shell alone is fine.
      expect(FilesystemMiddleware(backend: backend, shell: _Shell()), isA<ChatModelAgentMiddleware>());
      expect(
        FilesystemMiddleware(backend: backend, streamingShell: _StreamingShell()),
        isA<ChatModelAgentMiddleware>(),
      );
    });

    test('FilesystemSkillBackend: empty baseDir', () {
      expect(
        () => FilesystemSkillBackend(backend: InMemoryBackend(), baseDir: ''),
        _throwsArgumentError('baseDir is required'),
      );
    });

    test('PlanTaskMiddleware: empty baseDir', () {
      expect(
        () => PlanTaskMiddleware(backend: _TaskBackend(), baseDir: ''),
        _throwsArgumentError('baseDir is required'),
      );
    });

    test('ToolSearchMiddleware.create: no tools, duplicate name (and a failing info)', () async {
      await expectLater(
        ToolSearchMiddleware.create(dynamicTools: const []),
        _throwsArgumentError('tools is required'),
      );
      await expectLater(
        ToolSearchMiddleware.create(dynamicTools: [_Tool('a'), _Tool('a')]),
        _throwsArgumentError('duplicate dynamic tool name: a'),
      );
      // The dartdoc: a failing info is a ThreepioException, not an ArgumentError.
      await expectLater(
        ToolSearchMiddleware.create(dynamicTools: [_BrokenInfoTool()]),
        throwsA(
          isA<ThreepioException>().having((e) => e.message, 'message', contains('failed to get dynamic tool info')),
        ),
      );
    });
  });

  test('the constructed middlewares run hooks from adk.dart types', () async {
    // A light sanity check that the exported hook types line up: one hook of
    // one middleware called outside a run.
    final (_, state) = await const PatchToolCallsMiddleware().beforeModelRewriteState(
      _ctx,
      ChatModelAgentState(messages: [Message.user('hi')]),
      const ModelContext(),
    );
    expect(state.messages.single.content, 'hi');
  });
}
