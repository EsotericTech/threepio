// Ports eino v0.9.22 `adk/agentic_react_test.go`:
//   TestAgenticReact_BasicInvoke, _MultiTurnToolCalling, _Stream,
//   _MaxIterations (within_limit, exceeded), _ReturnDirectly (Invoke,
//   Stream), _DoubleInterruptResume, _NilInitInputReturnsError,
//   _ChatModelAgent_NoTools, _ChatModelAgent_ToolsReceiveArgs,
//   TestCoverage_AgenticReact_Streaming, TestCoverage_ConcatMessageStream_
//   Agentic (Success, ErrorDuringRecv), TestCoverage_AgenticReact_
//   InterruptResume, TestCoverage_AgenticMessageHasToolCalls (NoToolCalls,
//   HasToolCalls), TestCoverage_ChatModelAgent_StreamError,
//   TestCoverage_AgenticReact_GobStateRoundTrip (as a JSON checkpoint round
//   trip, with the checkpoint decoded and checked), and the
//   TestCoverage_GetMessageFromTypedWrappedEvent_Agentic /
//   TestCoverage_ConsumeStream_* cases on the streamed variant (eino's
//   `typedAgentEventWrapper.consumeStream` is the variant's join here).
//
// The cancel cases (TestAgenticReact_CancelAfterChatModel,
// _CancelAfterToolCalls, _ResumeThenCancelAfterChatModelCheckpoint) are in
// agentic_cancel_test.dart.
//
// TestAgenticReact_LateStreamInterruptResume: the two runner variants
// (turn_loop_false/streaming_false and _true); the two TurnLoop variants are
// not ported (a TurnLoop over agentic agents is not built).
//
// Not ported: TestCoverage_AgenticMessageHasToolCalls NilMessage / NilBlock /
// ToolCallBlockNilFunctionToolCall (a null message, a null block and a
// function-call block without its payload cannot be built with the sealed,
// non-nullable Dart types).
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/agentic/agent_message_codec.dart';
import 'package:threepio_core/src/adk/agentic/agentic_react_graph.dart'
    show AgenticReactConfig, AgenticReactState, newAgenticReactGraph;
import 'package:threepio_core/src/adk/eino/interrupt.dart' show AdkCheckpoint;

import 'agentic_fakes.dart';

const _sandboxEscapeRequired = ThreepioException('sandbox escape required');

/// Port of Go `agenticLateErrorTool`: the first call streams a piece and then
/// fails late; the second completes (and counts the side effect).
class _LateErrorTool extends StreamableTool {
  _LateErrorTool(this.name);

  final String name;
  int callCount = 0;
  int sideEffectCount = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: name,
        desc: 'returns a late stream error before completing',
        params: const {},
      );

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    switch (++callCount) {
      case 1:
        final (reader, writer) = pipe<String>(capacity: 2);
        writer
          ..send('partial')
          ..sendError(_sandboxEscapeRequired);
        unawaited(writer.close());
        return reader;
      case 2:
        sideEffectCount++;
        return StreamReader.fromIterable(['completed']);
      default:
        throw const ThreepioException('late error tool called more than twice');
    }
  }
}

/// Port of Go `agenticLateInterruptMiddleware`: interrupts before the first
/// call, and turns the tool's late stream error into a second interrupt.
ToolMiddleware _lateInterruptMiddleware() => ToolMiddleware(
      streamable: (next) => (ctx, input) async {
        final saved = getInterruptState<String>(ctx);
        if (!saved.wasInterrupted) {
          throw statefulInterrupt(ctx, 'first approval', 'awaiting_first_approval');
        }
        if (!saved.hasState) {
          throw const ThreepioException(
            'permission middleware: missing interrupt state',
          );
        }
        final resume = getResumeContext<String>(ctx);
        if (!resume.isResumeTarget || !resume.hasData) {
          throw const ThreepioException(
            'permission middleware: missing resume data',
          );
        }
        const expectedResumeData = {
          'awaiting_first_approval': 'approved_1',
          'awaiting_second_approval': 'approved_2',
        };
        final expected = expectedResumeData[saved.state];
        if (expected == null) {
          throw ThreepioException(
            'permission middleware: unexpected interrupt state ${saved.state}',
          );
        }
        if (resume.data != expected) {
          throw ThreepioException(
            'permission middleware: state ${saved.state} received resume data '
            '${resume.data}, want $expected',
          );
        }
        final output = await next(ctx, input);
        return StreamToolCallOutput(
          output.result.convert(
            (chunk) => chunk,
            errWrapper: (error) => identical(error, _sandboxEscapeRequired)
                ? statefulInterrupt(
                    ctx,
                    'second approval',
                    'awaiting_second_approval',
                  )
                : error,
          ),
        );
      },
    );

AgenticRunner _runner(
  String name,
  AgenticModel model,
  List<BaseTool> tools, {
  CheckpointStore? store,
  bool enableStreaming = false,
}) =>
    AgenticRunner(
      agent: AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: name,
        description: 'test agentic agent',
        model: model,
        toolsConfig: tools.isEmpty
            ? const ToolsConfig()
            : ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      )),
      checkpointStore: store,
      enableStreaming: enableStreaming,
    );

void main() {
  final ctx = RunContext.background();

  test('TestAgenticReact_BasicInvoke', () async {
    final mdl = SequentialAgenticModel([
      agenticToolCallMsg('echo', 'call-1', '"hello"'),
      agenticMsg('done: echo result received'),
    ]);
    final events = await drainAgenticEvents(
      _runner('TestAgenticReact_BasicInvoke', mdl, [AgenticEchoTool('echo')])
          .query(ctx, 'test input'),
    );
    final last = lastAgenticEvent(events)!;
    expect(last.error, isNull);
    expect(
      agenticTextContent(last.output!.messageOutput!.message),
      'done: echo result received',
    );
    expect(mdl.callCount, 2);
    // The tool result event is a user message with the result block.
    final toolEvent = events[1].output!.messageOutput!;
    expect(toolEvent.agenticRole, AgenticRoleType.user);
    final result = toolEvent.message!.contentBlocks.single.functionToolResult!;
    expect(result.callId, 'call-1');
    expect(result.name, 'echo');
    expect(
      (result.content.single.content as UserInputText).text,
      'echo:"hello"',
    );
    expect(agenticEventRoleProblems(events), isEmpty);
  });

  test('TestAgenticReact_MultiTurnToolCalling', () async {
    final mdl = SequentialAgenticModel([
      agenticToolCallMsg('echo', 'call-1', '"step1"'),
      agenticToolCallMsg('echo', 'call-2', '"step2"'),
      agenticToolCallMsg('echo', 'call-3', '"step3"'),
      agenticMsg('all done'),
    ]);
    final events = await drainAgenticEvents(
      _runner('multi', mdl, [AgenticEchoTool('echo')])
          .query(ctx, 'do three steps'),
    );
    final last = lastAgenticEvent(events)!;
    expect(last.error, isNull);
    expect(agenticTextContent(last.output!.messageOutput!.message), 'all done');
    expect(mdl.callCount, 4);
  });

  test('TestAgenticReact_Stream', () async {
    final mdl = SequentialAgenticModel([
      agenticToolCallMsg('echo', 'call-1', '"hello"'),
      agenticMsg('stream done'),
    ]);
    final events = await drainAgenticEvents(
      _runner('stream', mdl, [AgenticEchoTool('echo')], enableStreaming: true)
          .query(ctx, 'stream test'),
    );
    var finalText = '';
    for (final event in events) {
      final variant = event.output?.messageOutput;
      if (variant == null) continue;
      try {
        final text = agenticTextContent(await variant.getMessage());
        if (text.isNotEmpty) finalText = text;
        // Go ignores a variant whose message cannot be read.
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {}
    }
    expect(finalText, 'stream done');
  });

  group('TestAgenticReact_MaxIterations', () {
    test('within_limit', () async {
      final mdl = SequentialAgenticModel([
        agenticToolCallMsg('echo', 'c1', '"1"'),
        agenticToolCallMsg('echo', 'c2', '"2"'),
        agenticMsg('done within limit'),
      ]);
      final events = await drainAgenticEvents(
        _runner('within', mdl, [AgenticEchoTool('echo')]).query(ctx, 'go'),
      );
      final last = lastAgenticEvent(events)!;
      expect(last.error, isNull);
      expect(
        agenticTextContent(last.output!.messageOutput!.message),
        'done within limit',
      );
    });

    test('exceeded', () async {
      final mdl = SequentialAgenticModel([
        for (var i = 0; i < 25; i++) agenticToolCallMsg('echo', 'c$i', '"x"'),
      ]);
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'exceed-agent',
        description: 'test max iterations exceeded',
        model: mdl,
        maxIterations: 3,
        toolsConfig: ToolsConfig(
          toolsNode: ToolsNodeConfig(tools: [AgenticEchoTool('echo')]),
        ),
      ));
      final events =
          await drainAgenticEvents(AgenticRunner(agent: agent).query(ctx, 'go'));
      final last = lastAgenticEvent(events)!;
      expect(last.error, isNotNull);
      expect(
        ThreepioException.findCause<ExceedMaxIterationsException>(last.error),
        isNotNull,
      );
    });
  });

  group('TestAgenticReact_ReturnDirectly', () {
    final mdl = SequentialAgenticModel([
      agenticToolCallMsg('direct', 'call-1', '"final answer"'),
    ]);
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'TestAgenticReact_ReturnDirectly',
      description: 'test',
      model: mdl,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [AgenticEchoTool('direct')]),
        returnDirectly: const {'direct'},
      ),
    ));

    test('Invoke', () async {
      mdl.callCount = 0;
      final events =
          await drainAgenticEvents(AgenticRunner(agent: agent).query(ctx, 'test'));
      expect(mdl.callCount, 1);
      final last = lastAgenticEvent(events)!;
      expect(last.error, isNull);
      final msg = last.output!.messageOutput!.message!;
      expect(msg.contentBlocks, isNotEmpty);
      final ftr = msg.contentBlocks[0].functionToolResult;
      expect(ftr, isNotNull, reason: 'expected FunctionToolResult in final output');
      expect(ftr!.callId, 'call-1');
    });

    test('Stream', () async {
      mdl.callCount = 0;
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent, enableStreaming: true).query(ctx, 'test'),
      );
      expect(mdl.callCount, 1);
      final last = lastAgenticEvent(events)!;
      expect(last.error, isNull);
      final variant = last.output!.messageOutput!;
      AgenticMessage? finalMsg;
      if (variant.isStreaming) {
        final stream = variant.messageStream!;
        for (var c = await stream.nextOrNull();
            c != null;
            c = await stream.nextOrNull()) {
          finalMsg = c;
        }
      } else {
        finalMsg = variant.message;
      }
      expect(finalMsg, isNotNull);
      final ftr = finalMsg!.contentBlocks[0].functionToolResult;
      expect(ftr, isNotNull);
      expect(ftr!.callId, 'call-1');
    });
  });

  test('TestAgenticReact_DoubleInterruptResume', () async {
    var modelCallCount = 0;
    final mdl = MockAgenticModel(
      onGenerate: (_, __) async {
        final count = ++modelCallCount;
        return switch (count) {
          1 => agenticToolCallMsg('approval_tool', 'c1', '"first"'),
          2 => agenticToolCallMsg('approval_tool', 'c2', '"second"'),
          3 => agenticMsg('all approved'),
          _ => throw StateError('unexpected call #$count'),
        };
      },
    );
    final store = InMemoryCheckpointStore();
    final runner = _runner(
      'TestAgenticReact_DoubleInterruptResume',
      mdl,
      [AgenticInterruptTool('approval_tool')],
      store: store,
    );

    final events1 = await drainAgenticEvents(
      runner.query(
        ctx,
        'approve twice',
        options: [AgentRunOption.checkpointId('dbl-cp')],
      ),
    );
    expect(firstAgenticEventError(events1), isNull);
    final int1 = findInterruptEvent(events1);
    expect(int1, isNotNull, reason: 'expected first interrupt');
    final int1Id = int1!.action!.interrupted!.interruptContexts[0].id;

    final events2 = await drainAgenticEvents(
      await runner.resumeWithParams(
        ctx,
        'dbl-cp',
        ResumeParams(targets: {int1Id: 'approved_1'}),
      ),
    );
    expect(firstAgenticEventError(events2), isNull);
    final int2 = findInterruptEvent(events2);
    expect(int2, isNotNull, reason: 'expected second interrupt');
    final int2Id = int2!.action!.interrupted!.interruptContexts[0].id;

    final events3 = await drainAgenticEvents(
      await runner.resumeWithParams(
        ctx,
        'dbl-cp',
        ResumeParams(targets: {int2Id: 'approved_2'}),
      ),
    );
    expect(firstAgenticEventError(events3), isNull);
    final last = lastAgenticEvent(events3)!;
    expect(last.error, isNull);
    expect(
      agenticTextContent(last.output!.messageOutput!.message),
      contains('all approved'),
    );
    // The resumed tool saw its data: the second tool event says so.
    final toolResults = [
      for (final e in [...events2, ...events3])
        if (e.output?.messageOutput?.message?.contentBlocks.firstOrNull
                ?.functionToolResult
            case final r?)
          (r.content.single.content as UserInputText).text,
    ];
    expect(toolResults, ['approved:approved_1', 'approved:approved_2']);
  });

  group('TestAgenticReact_LateStreamInterruptResume', () {
    for (final enableStreaming in [false, true]) {
      test('turn_loop_false/streaming_$enableStreaming', () async {
        var modelCallCount = 0;
        final mdl = MockAgenticModel(
          onGenerate: (_, __) async => switch (++modelCallCount) {
            1 => agenticToolCallMsg('approval_tool', 'c1', '"run"'),
            2 => agenticMsg('operation completed'),
            _ => throw const ThreepioException('model called more than twice'),
          },
        );
        final lateErrorTool = _LateErrorTool('approval_tool');
        final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
          name: 'late-stream',
          description: 'late stream interrupt test agent',
          model: mdl,
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(
              tools: [lateErrorTool],
              toolCallMiddlewares: [_lateInterruptMiddleware()],
            ),
          ),
        ));
        final runner = AgenticRunner(
          agent: agent,
          checkpointStore: InMemoryCheckpointStore(),
          enableStreaming: enableStreaming,
        );
        const checkpointId = 'late-stream-runner';

        final events1 = await drainAgenticEvents(
          runner.query(
            ctx,
            'run once',
            options: [AgentRunOption.checkpointId(checkpointId)],
          ),
        );
        expect(firstAgenticEventError(events1), isNull);
        final int1 = findInterruptEvent(events1);
        expect(int1, isNotNull, reason: 'expected first interrupt');
        final int1Id = int1!.action!.interrupted!.interruptContexts[0].id;

        final events2 = await drainAgenticEvents(
          await runner.resumeWithParams(
            ctx,
            checkpointId,
            ResumeParams(targets: {int1Id: 'approved_1'}),
          ),
        );
        expect(firstAgenticEventError(events2), isNull);
        final int2 = findInterruptEvent(events2);
        expect(int2, isNotNull, reason: 'expected second interrupt');
        final int2Id = int2!.action!.interrupted!.interruptContexts[0].id;

        final events3 = await drainAgenticEvents(
          await runner.resumeWithParams(
            ctx,
            checkpointId,
            ResumeParams(targets: {int2Id: 'approved_2'}),
          ),
        );
        expect(firstAgenticEventError(events3), isNull);
        final last = lastAgenticEvent(events3)!;
        final finalMessage = await last.output!.messageOutput!.getMessage();
        expect(agenticTextContent(finalMessage), 'operation completed');
        expect(lateErrorTool.sideEffectCount, 1);
        expect(modelCallCount, 2);
      });
    }
  });

  test('TestAgenticReact_NilInitInputReturnsError', () async {
    final mdl = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('unexpected'),
    );
    final graph = await newAgenticReactGraph(
      ctx,
      AgenticReactConfig(
        model: mdl,
        toolsConfig: const ToolsNodeConfig(tools: []),
      ),
    );
    final runnable = await graph.compile(ctx);
    await expectLater(
      runnable.invoke(ctx, null),
      throwsA(
        predicate((e) => '$e'.contains('agentic react: init input is nil')),
      ),
    );
  });

  test('TestAgenticReact_ChatModelAgent_NoTools', () async {
    final mdl = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('no tools response'),
    );
    final events = await drainAgenticEvents(
      _runner('no-tools', mdl, const []).query(ctx, 'hello'),
    );
    final last = lastAgenticEvent(events)!;
    expect(last.error, isNull);
    expect(
      agenticTextContent(last.output!.messageOutput!.message),
      'no tools response',
    );
  });

  test('TestAgenticReact_ChatModelAgent_ToolsReceiveArgs', () async {
    var receivedArgs = '';
    final capture = AgenticArgCaptureTool('capture', (args) {
      receivedArgs = args;
      return 'captured';
    });
    final mdl = SequentialAgenticModel([
      agenticToolCallMsg('capture', 'c1', '{"foo":"bar"}'),
      agenticMsg('done'),
    ]);
    await drainAgenticEvents(
      _runner('capture', mdl, [capture]).query(ctx, 'call capture'),
    );
    expect(receivedArgs, '{"foo":"bar"}');
  });

  test('TestCoverage_AgenticReact_Streaming', () async {
    final m = MockAgenticModel(
      onStream: (_, __) async =>
          StreamReader.fromIterable([agenticMsg('streamed response')]),
    );
    final iter = _runner(
      'stream-react',
      m,
      [AgenticEchoTool('echo')],
      enableStreaming: true,
    ).query(ctx, 'stream me');
    final events = <AgenticAgentEvent>[];
    for (var event = await iter.nextOrNull();
        event != null;
        event = await iter.nextOrNull()) {
      final variant = event.output?.messageOutput;
      if (variant != null && variant.isStreaming) {
        final stream = variant.messageStream!;
        while (await stream.nextOrNull() != null) {}
      }
      events.add(event);
    }
    expect(events, isNotEmpty);
    expect(agenticEventRoleProblems(events), isEmpty);
  });

  group('TestCoverage_ConcatMessageStream_Agentic', () {
    test('Success', () async {
      final result = await concatMessageStreamWith(
        agenticMessageCodec,
        StreamReader.fromIterable([agenticMsg('Hello '), agenticMsg('world')]),
      );
      expect(result, isNotNull);
    });

    test('ErrorDuringRecv', () async {
      final (reader, writer) = pipe<AgenticMessage>(capacity: 2);
      writer.sendError(const ThreepioException('recv error'));
      await writer.close();
      await expectLater(
        concatMessageStreamWith(agenticMessageCodec, reader),
        throwsA(anything),
      );
    });
  });

  test('TestCoverage_AgenticReact_InterruptResume', () async {
    var callIdx = 0;
    final m = MockAgenticModel(
      onGenerate: (_, __) async => ++callIdx == 1
          ? agenticToolCallMsg('approval', 'call1', '{}')
          : agenticMsg('approved and done'),
    );
    final runner = _runner(
      'interrupt-agent',
      m,
      [AgenticInterruptTool('approval')],
      store: InMemoryCheckpointStore(),
    );
    final events1 = await drainAgenticEvents(
      runner.run(
        ctx,
        [AgenticMessage.user('need approval')],
        options: [AgentRunOption.checkpointId('cp-int')],
      ),
    );
    final interruptEvent = findInterruptEvent(events1);
    expect(interruptEvent, isNotNull, reason: 'should have interrupt event');
    final rootCause = interruptEvent!.action!.interrupted!.interruptContexts
        .firstWhere((c) => c.isRootCause);
    expect(rootCause.id, isNotEmpty);
    // The interrupt reports the agent's graph like a classic agent's.
    expect(
      interruptEvent.action!.interrupted!.data,
      isA<ChatModelAgentInterruptInfo>(),
    );

    final events = await drainAgenticEvents(
      await runner.resumeWithParams(
        ctx,
        'cp-int',
        ResumeParams(targets: {rootCause.id: 'approved'}),
      ),
    );
    expect(events, isNotEmpty);
    expect(
      agenticTextContent(lastAgenticEvent(events)!.output!.messageOutput!.message),
      'approved and done',
    );
  });

  group('TestCoverage_AgenticMessageHasToolCalls', () {
    test('NoToolCalls', () {
      expect(agenticMessageCodec.hasToolCalls(agenticMsg('just text')), isFalse);
    });

    test('HasToolCalls', () {
      expect(
        agenticMessageCodec.hasToolCalls(agenticToolCallMsg('tool1', 'id1', '{}')),
        isTrue,
      );
    });
  });

  test('TestCoverage_ChatModelAgent_StreamError', () async {
    final m = MockAgenticModel(
      onStream: (_, __) async => throw const ThreepioException('stream failed'),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'stream-error-agent',
      description: 'tests stream error',
      model: m,
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: agent, enableStreaming: true)
          .query(ctx, 'trigger stream error'),
    );
    expect(firstAgenticEventError(events), isNotNull);
  });

  test('TestCoverage_AgenticReact_GobStateRoundTrip (JSON)', () async {
    var callIdx = 0;
    final m = MockAgenticModel(
      onGenerate: (_, __) async => ++callIdx == 1
          ? agenticToolCallMsg('interrupt_tool', 'call1', '{}')
          : agenticMsg('completed'),
    );
    final store = InMemoryCheckpointStore();
    final runner = _runner(
      'gob-test',
      m,
      [AgenticInterruptTool('interrupt_tool')],
      store: store,
    );
    final events = await drainAgenticEvents(
      runner.run(
        ctx,
        [AgenticMessage.user('test gob')],
        options: [AgentRunOption.checkpointId('gob-cp')],
      ),
    );
    final interruptEvent = findInterruptEvent(events);
    expect(interruptEvent, isNotNull);

    final saved = await store.get('gob-cp');
    expect(saved, isNotNull, reason: 'checkpoint should be saved');

    // The runner's envelope: the agentic root input, the streaming flag and
    // the agent's interrupt state (its graph's checkpoint, Base64).
    final checkpoint =
        const JsonCheckpointSerializer().deserialize(saved!)! as AdkCheckpoint;
    final rootInput = checkpoint.agenticRootInput! as AgenticAgentInput;
    expect(rootInput.messages.single, AgenticMessage.user('test gob'));
    expect(checkpoint.enableStreaming, isFalse);
    expect(checkpoint.interruptId2State, isNotEmpty);
    final agentState = checkpoint.interruptId2State.values
        .map((s) => s.state)
        .whereType<String>()
        .single;
    // Inside: the graph checkpoint with the agentic state.
    final graphCheckpoint = jsonDecode(utf8.decode(base64Decode(agentState)));
    expect(jsonEncode(graphCheckpoint), contains('_eino_adk_agentic_state'));

    final rootCause = interruptEvent!.action!.interrupted!.interruptContexts
        .firstWhere((c) => c.isRootCause);
    final resumed = await drainAgenticEvents(
      await runner.resumeWithParams(
        ctx,
        'gob-cp',
        ResumeParams(targets: {rootCause.id: 'approved'}),
      ),
    );
    expect(
      resumed.any((e) => e.output?.messageOutput != null),
      isTrue,
      reason: 'should successfully resume from the checkpoint',
    );
  });

  test('the agentic state survives a JSON round trip', () {
    final state = AgenticReactState(agentName: 'a', remainingIterations: 7)
      ..messages = [AgenticMessage.user('hi'), agenticMsg('hello')]
      ..extra = {'k': 'v'}
      ..returnDirectlyToolCallId = 'c1'
      ..returnDirectlyEvent = AgenticAgentEvent.fromMessage(
        agenticMsg('direct'),
        agenticRole: AgenticRoleType.user,
      )
      ..setToolMsgId('t', 'c1', 'id-1')
      ..setToolGenAction('c1', const AgentAction(customizedAction: 'x'));
    final copy = AgenticReactState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
    );
    expect(copy.agentName, 'a');
    expect(copy.remainingIterations, 7);
    expect(copy.messages, state.messages);
    expect(copy.extra, {'k': 'v'});
    expect(copy.returnDirectlyToolCallId, 'c1');
    expect(copy.returnDirectlyEvent!.messageOutput!.message, agenticMsg('direct'));
    expect(
      copy.returnDirectlyEvent!.messageOutput!.agenticRole,
      AgenticRoleType.user,
    );
    expect(copy.popToolMsgId('t', 'c1'), 'id-1');
    expect(copy.popToolGenAction('c1')!.customizedAction, 'x');
  });

  group('TestCoverage_GetMessageFromTypedWrappedEvent_Agentic', () {
    test('NonStreaming', () async {
      final msg = agenticMsg('hello');
      expect(await AgenticMessageVariant.message(msg).getMessage(), same(msg));
    });

    test('StreamingAlreadyConcatenated', () async {
      final variant = AgenticMessageVariant.stream(
        StreamReader.fromIterable([agenticMsg('a'), agenticMsg('b')]),
      );
      final first = await variant.getMessage();
      expect(await variant.getMessage(), same(first));
    });

    test('StreamingWithPriorError', () async {
      final (reader, writer) = pipe<AgenticMessage>(capacity: 2);
      writer
        ..send(agenticMsg('partial'))
        ..sendError(const ThreepioException('stream broke'));
      await writer.close();
      final variant = AgenticMessageVariant.stream(reader);
      await expectLater(variant.getMessage(), throwsA(isA<ThreepioException>()));
      // The error is kept, and what was read before it stays readable.
      await expectLater(variant.getMessage(), throwsA(isA<ThreepioException>()));
      expect(await variant.messageStream!.recv(), agenticMsg('partial'));
    });
  });

  group('TestCoverage_ConsumeStream', () {
    test('EmptyStream', () async {
      final variant = AgenticMessageVariant.stream(StreamReader.fromIterable([]));
      await expectLater(variant.getMessage(), throwsA(isA<StateError>()));
    });

    test('SingleMessage', () async {
      final msg = agenticMsg('only');
      final variant = AgenticMessageVariant.stream(StreamReader.fromIterable([msg]));
      expect(await variant.getMessage(), same(msg));
      expect(variant.toJson()['is_streaming'], isTrue);
    });

    test('MultipleMessages', () async {
      final variant = AgenticMessageVariant.stream(
        StreamReader.fromIterable([agenticMsg('a'), agenticMsg('b')]),
      );
      final joined = await variant.getMessage();
      expect(joined.contentBlocks, hasLength(2));
      // The stream is replaced by the joined message.
      expect(await variant.messageStream!.recv(), joined);
    });

    test('Idempotent', () async {
      final variant = AgenticMessageVariant.stream(
        StreamReader.fromIterable([agenticMsg('a')]),
      );
      final a = await variant.getMessage();
      final b = await variant.getMessage();
      expect(a, same(b));
    });
  });
}
