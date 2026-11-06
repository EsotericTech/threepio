// Unit tests of the public types P7 adds that the ports of eino's tests do
// not pin: the cancel types (JSON, equality, texts, registration), the turn
// buffer, the TurnLoop option and result types, the in-memory backend's
// directory times and inline regex flags, the request types' equality, and
// the export surface of `adk.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/cancel.dart'
    show
        CancelContext,
        cancelImmediateGracePeriod,
        describeCancelMode,
        wrapEventsWithCancelContext,
        wrapStreamWithCancelMonitoring;
import 'package:threepio_core/src/adk/eino/interrupt.dart'
    show BridgeStore, ensureAdkTypesRegistered;
import 'package:threepio_core/src/adk/eino/turn_buffer.dart';
import 'package:threepio_core/src/adk/eino/turn_loop.dart'
    show CancelRequestState, PreemptController, PreemptTurnPhase;
import 'package:threepio_core/src/adk/filesystem/in_memory_backend.dart'
    show compileGrepPattern, globSyntaxOf;
import 'package:threepio_core/threepio_core.dart' as umbrella;

void main() {
  final ctx = RunContext.background();

  group('AgentCancelInfo', () {
    test('defaults, isImmediate, equality ignores set order', () {
      const immediate = AgentCancelInfo();
      expect(immediate.isImmediate, isTrue);
      expect(immediate.escalated, isFalse);
      const both = AgentCancelInfo(
        safePoints: {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls},
      );
      const reversed = AgentCancelInfo(
        safePoints: {CancelSafePoint.afterToolCalls, CancelSafePoint.afterChatModel},
      );
      expect(both, reversed);
      expect(both.hashCode, reversed.hashCode);
      expect(both.isImmediate, isFalse);
      expect(both, isNot(immediate));
    });

    test('JSON round trip', () {
      const info = AgentCancelInfo(
        safePoints: {CancelSafePoint.afterToolCalls},
        escalated: true,
        timeout: true,
      );
      expect(AgentCancelInfo.fromJson(info.toJson()), info);
      expect(info.toJson(), {
        'safe_points': ['afterToolCalls'],
        'escalated': true,
        'timeout': true,
      });
    });

    test('describeCancelMode follows eino names', () {
      expect(describeCancelMode(const {}), 'immediate');
      expect(
        describeCancelMode(const {CancelSafePoint.afterToolCalls, CancelSafePoint.afterChatModel}),
        'afterChatModel|afterToolCalls',
      );
    });
  });

  group('AgentRunCancelledException', () {
    test('message, ThreepioException, toString', () {
      final error = AgentRunCancelledException(
        const AgentCancelInfo(safePoints: {CancelSafePoint.afterChatModel}, escalated: true),
      );
      expect(error, isA<ThreepioException>());
      expect(error.message, 'agent canceled: mode=afterChatModel, escalated=true');
      expect('$error', contains('agent canceled'));
      expect(error.interruptContexts, isEmpty);
      expect(error.interruptSignal, isNull);
      expect(isInterrupt(error), isFalse);
    });

    test('JSON round trip keeps the interrupt contexts', () {
      final context = InterruptCtx(
        id: 'id-1',
        address: Address([const AddressSegment(type: AddressSegmentType('agent'), id: 'a')]),
        info: 'why',
        isRootCause: true,
      );
      final error = AgentRunCancelledException(
        const AgentCancelInfo(),
        interruptContexts: [context],
      );
      final back = AgentRunCancelledException.fromJson(
        jsonDecode(jsonEncode(error.toJson())) as Map<String, Object?>,
      );
      expect(back.info, error.info);
      expect(back.interruptContexts.single.id, 'id-1');
      expect(back.interruptContexts.single.address.toString(), 'agent:a');
    });

    test('is registered under eino names', () {
      ensureAdkTypesRegistered();
      expect(TypeRegistry.nameOf(const AgentCancelInfo()), '_eino_adk_agent_cancel_info');
      final encoded = TypeRegistry.encode(AgentRunCancelledException(const AgentCancelInfo()));
      expect((encoded! as Map)[r'$type'], '_eino_adk_cancel_error');
      expect(TypeRegistry.decode(encoded), isA<AgentRunCancelledException>());
    });
  });

  group('CancelHandle and CancelContext', () {
    test('a second cancel call contributes; immediate wins over safe points', () {
      final context = CancelContext.root();
      final first = context.cancel(safePoints: {CancelSafePoint.afterToolCalls});
      expect(first.contributed, isTrue);
      expect(context.mode, {CancelSafePoint.afterToolCalls});
      final second = context.cancel(safePoints: {CancelSafePoint.afterChatModel});
      expect(second.contributed, isTrue);
      expect(context.mode, {CancelSafePoint.afterToolCalls, CancelSafePoint.afterChatModel});
      context.cancel();
      expect(context.mode, isEmpty);
      expect(context.isImmediateCancelled, isTrue);
      final error = context.createCancelError();
      expect(error.info.escalated, isTrue);
    });

    test('wait reports executionEnded after markDone and cancelled after markCancelHandled',
        () async {
      final ended = CancelContext.root();
      final handle = ended.cancel(safePoints: {CancelSafePoint.afterChatModel});
      ended.markDone();
      expect(await handle.wait(), CancelOutcome.executionEnded);
      expect(ended.cancel().contributed, isFalse);

      final handled = CancelContext.root();
      final handle2 = handled.cancel();
      expect(handled.markCancelHandled(), isTrue);
      expect(handled.markCancelHandled(), isFalse);
      expect(await handle2.wait(), CancelOutcome.cancelled);
    });

    test('the timeout timer escalates under fake time and stops when done', () {
      fakeAsync((async) {
        final context = CancelContext.root();
        final handle = context.cancel(
          safePoints: {CancelSafePoint.afterToolCalls},
          timeout: const Duration(seconds: 10),
        );
        // A later, shorter deadline wins.
        async.elapse(const Duration(seconds: 2));
        context.cancel(
          safePoints: {CancelSafePoint.afterToolCalls},
          timeout: const Duration(seconds: 3),
        );
        async.elapse(const Duration(seconds: 2));
        expect(context.isImmediateCancelled, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(context.isImmediateCancelled, isTrue);
        CancelOutcome? outcome;
        handle.wait().then((value) => outcome = value);
        context.markCancelHandled();
        async.flushMicrotasks();
        expect(outcome, CancelOutcome.timedOut);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the grace period of a recursive immediate cancel ends when the run is done', () {
      fakeAsync((async) {
        final saved = cancelImmediateGracePeriod;
        addTearDown(() => cancelImmediateGracePeriod = saved);
        cancelImmediateGracePeriod = const Duration(seconds: 1);
        final root = CancelContext.root()..markCheckpointAwareDescendant();
        final (graphCtx, interrupter) = ctx.withGraphInterrupt();
        expect(graphCtx, isNotNull);
        root
          ..addGraphInterrupter(interrupter)
          ..cancel(recursive: true);
        expect(root.isImmediateCancelled, isTrue);
        expect(interrupter.isInterrupted, isFalse);
        async.elapse(const Duration(milliseconds: 500));
        root.markCancelHandled();
        async.elapse(const Duration(seconds: 1));
        expect(interrupter.isInterrupted, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('TurnBuffer', () {
    test('send, receive, pushFront, takeAll, close', () async {
      final buffer = TurnBuffer<int>()
        ..send(1)
        ..send(2)
        ..pushFront([0]);
      expect(await buffer.receive(), (true, 0));
      expect(buffer.takeAll(), [1, 2]);
      final waiting = buffer.receive();
      buffer.send(3);
      expect(await waiting, (true, 3));
      buffer.close();
      expect(buffer.isClosed, isTrue);
      expect(buffer.trySend(4), isFalse);
      expect(() => buffer.send(4), throwsStateError);
      expect(await buffer.receive(), (false, null));
    });

    test('wakeup ends a wait without an item; clearWakeup forgets it', () async {
      final buffer = TurnBuffer<String>();
      final waiting = buffer.receive();
      buffer.wakeup();
      expect(await waiting, (false, null));
      buffer
        ..wakeup()
        ..clearWakeup()
        ..send('x');
      expect(await buffer.receive(), (true, 'x'));
    });
  });

  group('TurnLoop types', () {
    test('CancelRequestState joins safe points and keeps the earliest deadline', () {
      final now = DateTime.utc(2026);
      final state = CancelRequestState(
        (
          safePoints: {CancelSafePoint.afterToolCalls},
          timeout: const Duration(seconds: 10),
          recursive: false,
        ),
        now,
      )..merge(
          (
            safePoints: {CancelSafePoint.afterChatModel},
            timeout: const Duration(seconds: 4),
            recursive: true,
          ),
          now,
        );
      final args = state.cancelArgs(now.add(const Duration(seconds: 1)));
      expect(args.safePoints, {CancelSafePoint.afterToolCalls, CancelSafePoint.afterChatModel});
      expect(args.timeout, const Duration(seconds: 3));
      expect(args.recursive, isTrue);
      expect(state.cancelArgs(now.add(const Duration(seconds: 5))).safePoints, isEmpty);
    });

    test('PreemptController phases', () {
      final controller = PreemptController();
      expect(controller.phase, PreemptTurnPhase.idle);
      expect(controller.abortPlanningTurn, throwsStateError);
      controller.beginPlanningTurn();
      expect(controller.turnId, 1);
      expect(controller.endActiveTurn, throwsStateError);
      expect(controller.endPush, throwsStateError);
    });

    test('GenInputResult, GenResumeResult and TurnLoopInterruptedException', () {
      final input = AgentInput(messages: [Message.user('x')]);
      final result = GenInputResult<int>(input: input, consumed: const [1]);
      expect(result.remaining, isEmpty);
      expect(result.runOptions, isEmpty);
      expect(result.runContext, isNull);
      const resume = GenResumeResult<int>();
      expect(resume.resumeParams, isNull);
      final error = TurnLoopInterruptedException(const []);
      expect(error.message, 'agent interrupted: 0 context(s)');
      expect(error, isA<ThreepioException>());
    });
  });

  group('BridgeStore.lastCheckpoint', () {
    test('only what was written counts', () async {
      final resumed = BridgeStore.resume('k', Uint8List.fromList([1]));
      expect(resumed.lastCheckpoint, isNull);
      await resumed.set('k', Uint8List.fromList([2]));
      expect(resumed.lastCheckpoint, [2]);
    });
  });

  group('InMemoryBackend', () {
    test("a directory's time is its latest file's", () {
      fakeAsync((async) {
        final backend = InMemoryBackend();
        backend.write(ctx, const WriteRequest(filePath: '/d/a.txt', content: 'a'));
        async.elapse(const Duration(seconds: 5));
        backend.write(ctx, const WriteRequest(filePath: '/d/b.txt', content: 'b'));
        async.elapse(const Duration(seconds: 5));
        backend.write(ctx, const WriteRequest(filePath: '/top.txt', content: 'top'));
        List<FileInfo>? listing;
        backend.lsInfo(ctx, const LsInfoRequest(path: '/')).then((l) => listing = l);
        async.flushMicrotasks();
        final dir = listing!.firstWhere((info) => info.isDir);
        final b = DateTime.parse(listing!.firstWhere((i) => i.path == 'top.txt').modifiedAt);
        expect(dir.path, 'd');
        expect(DateTime.parse(dir.modifiedAt), b.subtract(const Duration(seconds: 5)));
      });
    });

    test('a leading inline flag group is understood; others are rejected', () async {
      expect(compileGrepPattern('(?i)error').hasMatch('ERROR'), isTrue);
      expect(compileGrepPattern('(?s)a.b').hasMatch('a\nb'), isTrue);
      expect(() => compileGrepPattern('a(?i)b'), throwsA(isA<ThreepioException>()));
      final backend = InMemoryBackend();
      await backend.write(ctx, const WriteRequest(filePath: '/x', content: 'Hello'));
      final matches = await backend.grepRaw(ctx, const GrepRequest(pattern: '(?i)hello'));
      expect(matches.single, const GrepMatch(path: '/x', line: 1, content: 'Hello'));
    });

    test('an invalid glob is a ThreepioException once a file is matched', () async {
      final backend = InMemoryBackend();
      // Like doublestar, nothing to match means no error.
      expect(await backend.globInfo(ctx, const GlobInfoRequest(pattern: '[')), isEmpty);
      expect(
        await backend.grepRaw(ctx, const GrepRequest(pattern: 'x', glob: '[')),
        isEmpty,
      );
      await backend.write(ctx, const WriteRequest(filePath: '/a.txt', content: 'x'));
      await expectLater(
        backend.globInfo(ctx, const GlobInfoRequest(pattern: '[')),
        throwsA(isA<ThreepioException>()),
      );
    });

    test('doublestar syntax: parentheses, stray brackets, one-option braces', () async {
      expect(globSyntaxOf('report (1).txt'), r'report \(1\).txt');
      expect(globSyntaxOf('a]b}c'), r'a\]b\}c');
      expect(globSyntaxOf('{x}.go'), 'x.go');
      expect(globSyntaxOf('{a,{b}}'), '{a,b}');
      expect(globSyntaxOf('[ab].go'), '[ab].go');
      expect(globSyntaxOf('**.go'), '*.go');
      expect(globSyntaxOf('a**b/**/c/**'), 'a*b/**/c/**');
      final backend = InMemoryBackend();
      for (final path in ['/report (1).txt', '/main.go', '/pkg/util.go', '/x.go']) {
        await backend.write(ctx, WriteRequest(filePath: path, content: 'c'));
      }
      Future<List<String>> glob(String pattern, [String path = '']) async => [
            for (final info
                in await backend.globInfo(ctx, GlobInfoRequest(pattern: pattern, path: path)))
              info.path,
          ];
      expect(await glob('report (1).txt'), ['report (1).txt']);
      // `**` that is not a whole segment does not cross directories.
      expect(await glob('**.go'), ['main.go', 'x.go']);
      expect(await glob('**/*.go'), ['main.go', 'pkg/util.go', 'x.go']);
      expect(await glob('{x}.go'), ['x.go']);
      expect(await glob(''), isEmpty);
      // A relative pattern does not match the absolute path of a file named
      // by `path` (doublestar's `*` does not match the leading `/`).
      expect(await glob('*.go', '/main.go'), isEmpty);
    });

    test('doublestar corners: empty brace options, ** at the root, absolute patterns, a/**',
        () async {
      final backend = InMemoryBackend();
      for (final path in ['/main.go', '/src/a.dart', '/b.dart', '/a', '/a/x.txt']) {
        await backend.write(ctx, WriteRequest(filePath: path, content: 'hit'));
      }
      Future<List<String>> glob(String pattern, [String path = '']) async => [
            for (final info
                in await backend.globInfo(ctx, GlobInfoRequest(pattern: pattern, path: path)))
              info.path,
          ];
      Future<List<String>> grep(String globPattern, {String path = ''}) async => [
            for (final match in await backend.grepRaw(
              ctx,
              GrepRequest(pattern: 'hit', path: path, glob: globPattern),
            ))
              match.path,
          ];
      // package:glob alone throws on a leading group with an empty option.
      expect(await glob('{,src/}*.dart'), ['b.dart', 'src/a.dart']);
      expect(await glob('{src/,}*.dart'), ['b.dart', 'src/a.dart']);
      // The absolute path of a file named by `path` is matched as it is (a
      // glob without `/` or `**` looks at the base name, as in eino): a
      // relative pattern matches it through its empty first segment, with a
      // leading `**` or `*` segment, and not otherwise.
      expect(await grep('*.go', path: '/main.go'), ['/main.go']);
      expect(await grep('**/*.go', path: '/main.go'), ['/main.go']);
      expect(await grep('*/main.go', path: '/main.go'), ['/main.go']);
      expect(await grep('src/*.go', path: '/main.go'), isEmpty);
      expect(await glob('**', '/a/x.txt'), ['/a/x.txt']);
      expect(await glob('*/x.txt', '/a/x.txt'), isEmpty);
      expect(await glob('*.go', '/main.go'), isEmpty);
      // An absolute pattern never matches the relative path grep compares.
      expect(await grep('/src/*.dart'), isEmpty);
      expect(await glob('/src/*.dart'), ['/src/a.dart']);
      // `a/**` also matches `a` itself.
      expect(await glob('a/**'), ['a', 'a/x.txt']);
      // The whole pattern `{}` matches only the empty path.
      expect(await glob('{}'), isEmpty);
    });

    test('a dot matches anything but a line break, also in multiline mode', () async {
      final backend = InMemoryBackend();
      await backend.write(ctx, const WriteRequest(filePath: '/r.txt', content: 'a\rb\nc'));
      final multiline = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'a.b', enableMultiline: true),
      );
      expect(multiline.single.line, 1);
      final acrossLines = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'b.c', enableMultiline: true),
      );
      expect(acrossLines, isEmpty);
      expect(compileGrepPattern('[]a]').hasMatch(']'), isTrue);
      expect(compileGrepPattern(r'\.').hasMatch('x'), isFalse);
    });

    test("a dot file's extension is the part after its dot (Go filepath.Ext)", () async {
      final backend = InMemoryBackend();
      await backend.write(ctx, const WriteRequest(filePath: '/app/.env', content: 'KEY=1'));
      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: 'KEY', fileType: 'env'));
      expect(matches.single.path, '/app/.env');
    });

    test('in single-line mode `.` matches a carriage return, as in RE2', () async {
      final backend = InMemoryBackend();
      await backend.write(ctx, const WriteRequest(filePath: '/crlf.txt', content: 'ab\r\ncd'));
      final matches = await backend.grepRaw(ctx, const GrepRequest(pattern: r'b.$'));
      expect(matches.single.line, 1);
    });

    test('multiline mode drops an empty match right after a match, as RE2 does', () async {
      final backend = InMemoryBackend();
      await backend.write(ctx, const WriteRequest(filePath: '/m.txt', content: 'x\ny'));
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'x*', enableMultiline: true),
      );
      expect([for (final match in matches) match.line], [1, 2, 2]);
    });
  });

  group('review fixes', () {
    test('a source whose close throws still ends the run and marks it done', () async {
      final context = CancelContext.root();
      final wrapped = wrapEventsWithCancelContext(
        _ThrowingCloseReader([AgentEvent(agentName: 'a')]),
        context,
      );
      expect(await wrapped.collectAll(), hasLength(1));
      await context.done;
      expect(context.isDone, isTrue);
    });

    test('a monitored stream of many chunks passes through, then ends when torn down', () async {
      final context = CancelContext.root();
      final (source, writer) = pipe<int>();
      final monitored = wrapStreamWithCancelMonitoring(source, context);
      for (var i = 0; i < 500; i++) {
        writer.send(i);
      }
      for (var i = 0; i < 500; i++) {
        expect(await monitored.recv(), i);
      }
      context.cancel();
      await expectLater(monitored.recv(), throwsA(isA<StreamCanceledException>()));
      await writer.close();
    });

    test('onCancel hears a safe-point cancel', () {
      final context = CancelContext.root();
      var heard = 0;
      final remove = context.onCancel(() => heard++);
      context.cancel(safePoints: {CancelSafePoint.afterToolCalls});
      expect(heard, 1);
      remove();
      context.onCancel(() => heard++);
      expect(heard, 2);
    });

    test('without a store the cancel error still carries its interrupt contexts', () async {
      final started = Completer<void>();
      final model = _BlockingModel(started);
      final agent = ChatModelAgent(
        ChatModelAgentConfig(name: 'agent', description: 'd', model: model),
      );
      final (option, cancel) = withCancel();
      final collected = Runner(agent: agent)
          .query(ctx, 'go', options: [option, AgentRunOption.checkpointId('cp')])
          .collectAll();
      await started.future;
      expect(await cancel().wait(), CancelOutcome.cancelled);
      final error = (await collected).last.error;
      expect(error, isA<AgentRunCancelledException>());
      expect((error! as AgentRunCancelledException).interruptContexts, isNotEmpty);
    });

    test('a push while the exiting loop writes its checkpoint is late', () async {
      final gate = Completer<void>();
      final store = _GatedStore(gate.future);
      final ask = FunctionTool<Map<String, Object?>, String>(
        name: 'ask',
        description: 'asks',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        invoke: (ctx, input, options) => throw interrupt(ctx, 'need input'),
      );
      final model = _ScriptModel([
        Message(
          role: RoleType.assistant,
          content: '',
          toolCalls: [ToolCall(id: 'c1', function: FunctionCall(name: 'ask', arguments: '{}'))],
        ),
      ]);
      final agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'agent',
          description: 'd',
          model: model,
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [ask])),
        ),
      );
      final loop = TurnLoop<String>(
        TurnLoopConfig(
          genInput: (ctx, loop, items) async => GenInputResult(
            input: AgentInput(messages: [Message.user(items.first)]),
            consumed: items,
          ),
          prepareAgent: (ctx, loop, consumed) async => agent,
          store: store,
          checkpointId: 'loop',
        ),
      )
        ..push('question')
        ..run(ctx);
      await store.setStarted.future;
      expect(loop.push('during cleanup').accepted, isFalse);
      gate.complete();
      final exit = await loop.wait();
      expect(exit.exitReason, isA<TurnLoopInterruptedException>());
      expect(exit.takeLateItems(), ['during cleanup']);
    });

    test('a checkpoint id among the graph tool options changes nothing', () async {
      final graph = Graph<Map<String, Object?>, String>()
        ..addLambdaNode(
          'ask',
          Lambda.invokable((RunContext ctx, Map<String, Object?> input) async {
            if (!getInterruptState<Object>(ctx).wasInterrupted) {
              throw interrupt(ctx, 'inner');
            }
            return 'resumed';
          }),
        )
        ..addEdge(Graph.start, 'ask')
        ..addEdge('ask', Graph.end);
      final tool = GraphTool.invokable<Map<String, Object?>, String>(
        name: 'g',
        description: 'graph',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        graph: graph,
      );
      await expectLater(
        tool.invokableRun(
          ctx,
          '{}',
          options: ToolOptions(extensions: [
            GraphToolOptions([CallOption.checkpointId('mine')]),
          ]),
        ),
        throwsA(predicate((Object? e) => isInterrupt(e) && '$e'.contains('graph tool interrupt'))),
      );
    });
  });

  group('filesystem request and result types', () {
    test('defaults and value equality', () {
      const read = ReadRequest(filePath: '/a');
      expect(read.offset, 1);
      expect(read.limit, 0);
      const multi = MultiModalReadRequest(filePath: '/a.pdf', pages: '1-2');
      expect(multi, isA<ReadRequest>());
      expect(const FileInfo(path: 'a', size: 1), const FileInfo(path: 'a', size: 1));
      expect(const FileInfo(path: 'a'), isNot(const FileInfo(path: 'a', isDir: true)));
      expect(const FileContent('x'), const FileContent('x'));
      expect(const ExecuteResponse(output: 'o', exitCode: 0), const ExecuteResponse(output: 'o', exitCode: 0));
      expect(
        FileContentPart(type: FileContentPartType.image, mimeType: 'image/png', data: Uint8List.fromList([1])),
        FileContentPart(type: FileContentPartType.image, mimeType: 'image/png', data: Uint8List.fromList([1])),
      );
      expect(FileContentPartType.pdf.value, 'pdf');
      expect(const ExecuteRequest(command: 'ls').runInBackground, isFalse);
      expect(const MultiFileContent().parts, isEmpty);
      expect(const GrepRequest(pattern: 'p').afterLines, 0);
    });
  });

  group('export surface', () {
    test('adk.dart exports the P7 names; the umbrella does not export them', () {
      // Compile-time: these resolve through adk.dart.
      expect(withCancel, isA<Function>());
      expect(GraphTool.invokable, isA<Function>());
      expect(const GraphToolOptions([]).callOptions, isEmpty);
      expect(InMemoryBackend(), isA<FilesystemBackend>());
      expect(const StopOption.immediate(), isA<StopOption>());
      // The umbrella still exports its own, older names.
      expect(umbrella.Runner, isNot(Runner));
    });
  });
}

/// A reader of [events] whose close throws (a reader implemented elsewhere).
final class _ThrowingCloseReader implements StreamReader<AgentEvent> {
  _ThrowingCloseReader(List<AgentEvent> events) : _events = List.of(events);

  final List<AgentEvent> _events;

  @override
  Future<AgentEvent> recv() async {
    if (_events.isEmpty) throw const StreamEOFException();
    return _events.removeAt(0);
  }

  @override
  Future<void> close() async => throw StateError('close failed');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A model whose call never ends.
final class _BlockingModel extends BaseChatModel {
  _BlockingModel(this.started);

  final Completer<void> started;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) {
    if (!started.isCompleted) started.complete();
    return Completer<Message>().future;
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

/// A model that answers with [replies] in turn.
final class _ScriptModel extends BaseChatModel {
  _ScriptModel(this.replies);

  final List<Message> replies;
  int _next = 0;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async =>
      replies[_next++];

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

/// A store whose `set` waits for [gate].
final class _GatedStore implements CheckpointStore {
  _GatedStore(this.gate);

  final Future<void> gate;
  final Completer<void> setStarted = Completer<void>();
  final Map<String, Uint8List> _data = {};

  @override
  Future<Uint8List?> get(String key) async => _data[key];

  @override
  Future<void> set(String key, Uint8List value) async {
    if (!setStarted.isCompleted) setStarted.complete();
    await gate;
    _data[key] = value;
  }
}
