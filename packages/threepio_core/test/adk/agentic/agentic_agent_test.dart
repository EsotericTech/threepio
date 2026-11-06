// Ports eino v0.9.22 `adk/agentic_test.go`:
//   TestAgenticChatModelAgentRun_NoTools, _WithTools, _Streaming,
//   TestDefaultAgenticGenModelInput (WithInstruction, WithoutInstruction),
//   TestAgenticRunnerQuery, TestAgenticChatModelAgentRun_WithMiddleware,
//   TestAgenticAfterModel_NoTools_ModifyDoesNotAffectEvent,
//   TestAgenticGetComposeOptions_WithChatModelOptions,
//   TestAgenticChatModelAgent_PrepareExecContextError,
//   TestAgenticRunner_Run_WithStreaming, TestAgenticRunner_Query_WithStreaming,
//   TestAgenticSimpleInterrupt, TestCascadingFrom_NewChatModelAgentFrom,
//   TestCascadingTyped_TypedStatefulInterrupt,
//   TestCascadingTyped_EventFromAgenticMessage,
//   TestCoverage_FlowAgent_ResumeNotResumable, TestCoverage_GenAgenticErrorIter,
//   TestCoverage_TypedGetMessage_AgenticNonStreaming, _AgenticStreaming,
//   _NilOutput, TestCoverage_CopyAgenticEvent,
//   TestCoverage_ChatModelAgent_ModelGenerateError,
//   TestCoverage_NewTypedUserMessages (Message, AgenticMessage),
//   TestCoverage_TypedEndpointModel_NilEndpoints, _WithEndpoints,
//   TestCoverage_SetAutomaticClose, TestConcatMessageStream_AgenticClosesStream.
//
// Not ported: TestAgenticChatModelAgentOutputKey (`OutputKey` is not ported,
// eino does not recommend it), the four TestCoverage_ChatModelAgent_On*
// tests (agent transfer, not ported), TestCoverage_GetMessage_* (classic,
// covered by test/adk/eino), the
// agentic retry/failover tests (retry and failover are not built for
// agentic models). In TestAgenticSimpleInterrupt the assertion on the
// deprecated `ResumeInfo.Data` is left out, as in the classic port.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/agentic/agent_message_codec.dart';
import 'package:threepio_core/src/adk/agentic/agentic_agent.dart'
    show copyAgenticAgentEvent, setAgenticAutomaticClose;
import 'package:threepio_core/src/adk/agentic/agentic_runner.dart'
    show AgenticFlowAgent;
import 'package:threepio_core/src/adk/agentic/agentic_wrappers.dart'
    show AgenticEndpointModel;

import 'agentic_fakes.dart';

/// Port of Go `testAgenticMiddleware`.
class _TestAgenticMiddleware extends AgenticChatModelAgentMiddleware {
  _TestAgenticMiddleware({this.before, this.after});

  final void Function(AgenticChatModelAgentState state)? before;
  final void Function(AgenticChatModelAgentState state)? after;

  @override
  FutureOr<(RunContext, AgenticChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticModelContext model,
  ) {
    before?.call(state);
    return (ctx, state);
  }

  @override
  FutureOr<(RunContext, AgenticChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticModelContext model,
  ) {
    after?.call(state);
    return (ctx, state);
  }
}

void main() {
  final ctx = RunContext.background();

  test('TestAgenticChatModelAgentRun_NoTools', () async {
    final response = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(const AssistantGenText(text: 'Hello from agentic model')),
      ],
    );
    final m = MockAgenticModel(onGenerate: (_, __) async => response);
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'AgenticTestAgent',
      description: 'Agentic test agent',
      instruction: 'You are helpful.',
      model: m,
    ));

    final iter = agent.run(
      ctx,
      AgenticAgentInput(messages: [AgenticMessage.user('Hi')]),
    );
    final event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    final msg = event.output!.messageOutput!.message!;
    expect(msg.role, AgenticRoleType.assistant);
    expect(msg.contentBlocks, hasLength(1));
    expect(
      msg.contentBlocks[0].assistantGenText!.text,
      'Hello from agentic model',
    );
    expect(await iter.nextOrNull(), isNull);
  });

  test('TestAgenticChatModelAgentRun_WithTools', () async {
    final response = agenticMsg('Used tool and got result');
    List<ToolInfo>? receivedToolInfos;
    final m = MockAgenticModel(
      onGenerate: (_, options) async {
        receivedToolInfos = options?.tools;
        return response;
      },
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'AgenticToolAgent',
      description: 'Agentic agent with tools',
      instruction: 'You are helpful.',
      model: m,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [SlowTool('dummy_tool', 'ok')]),
      ),
    ));

    final iter = agent.run(
      ctx,
      AgenticAgentInput(messages: [AgenticMessage.user('Call a tool')]),
    );
    final event = await iter.nextOrNull();
    expect(event!.error, isNull);
    expect(event.output, isNotNull);
    expect(await iter.nextOrNull(), isNull);

    expect(receivedToolInfos, hasLength(1));
    expect(receivedToolInfos![0].name, 'dummy_tool');
  });

  test('TestAgenticChatModelAgentRun_Streaming', () async {
    final chunk1 = agenticMsg('Hello ');
    final chunk2 = agenticMsg('world');
    final m = MockAgenticModel(
      onStream: (_, __) async => StreamReader.fromIterable([chunk1, chunk2]),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'AgenticStreamAgent',
      description: 'Agentic streaming agent',
      instruction: 'You are helpful.',
      model: m,
    ));

    final iter = agent.run(
      ctx,
      AgenticAgentInput(
        messages: [AgenticMessage.user('Hi')],
        enableStreaming: true,
      ),
    );
    final event = await iter.nextOrNull();
    expect(event!.error, isNull);
    final stream = event.output!.messageOutput!.messageStream;
    expect(stream, isNotNull);
    await stream!.close();
    expect(await iter.nextOrNull(), isNull);
  });

  group('TestDefaultAgenticGenModelInput', () {
    test('WithInstruction', () {
      final msgs = defaultAgenticGenModelInput(
        ctx,
        'Be helpful',
        AgenticAgentInput(messages: [AgenticMessage.user('Hello')]),
      );
      expect(msgs, hasLength(2));
      expect(msgs[0].role, AgenticRoleType.system);
      expect(msgs[1].role, AgenticRoleType.user);
    });

    test('WithoutInstruction', () {
      final msgs = defaultAgenticGenModelInput(
        ctx,
        '',
        AgenticAgentInput(messages: [AgenticMessage.user('Hello')]),
      );
      expect(msgs, hasLength(1));
      expect(msgs[0].role, AgenticRoleType.user);
    });
  });

  test('TestAgenticRunnerQuery', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('query response'),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'QueryAgent',
      description: 'Query test agent',
      instruction: 'Be helpful.',
      model: m,
    ));
    final iter = AgenticRunner(agent: agent).query(ctx, "What's up?");
    final event = await iter.nextOrNull();
    expect(event!.error, isNull);
    expect(await iter.nextOrNull(), isNull);
  });

  test('TestAgenticChatModelAgentRun_WithMiddleware', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('Hello from agentic agent'),
    );
    var afterModelExecuted = false;
    var afterLength = 0;
    final mw = _TestAgenticMiddleware(
      before: (state) =>
          state.messages = [...state.messages, AgenticMessage.user('extra')],
      after: (state) {
        afterLength = state.messages.length;
        afterModelExecuted = true;
      },
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'AgenticMiddlewareAgent',
      description: 'Agentic agent with middleware',
      instruction: 'You are helpful.',
      model: m,
      handlers: [mw],
    ));

    final iter = agent.run(
      ctx,
      AgenticAgentInput(messages: [AgenticMessage.user('Hi')]),
    );
    final event = await iter.nextOrNull();
    expect(event!.error, isNull);
    expect(
      event.output!.messageOutput!.message!.role,
      AgenticRoleType.assistant,
    );
    expect(await iter.nextOrNull(), isNull);
    expect(afterModelExecuted, isTrue);
    // system + user + "extra" + the model's answer.
    expect(afterLength, 4);
  });

  test('TestAgenticAfterModel_NoTools_ModifyDoesNotAffectEvent', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('original content'),
    );
    var captured = <AgenticMessage>[];
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'AgenticAfterModelAgent',
      description: 'Test AfterModelRewriteState',
      instruction: 'You are helpful.',
      model: m,
      handlers: [
        _TestAgenticMiddleware(
          after: (state) {
            captured = List.of(state.messages);
            state.messages = [
              ...state.messages,
              agenticMsg('appended content'),
            ];
          },
        ),
      ],
    ));

    final iter = agent.run(
      ctx,
      AgenticAgentInput(messages: [AgenticMessage.user('Hello')]),
    );
    final event = await iter.nextOrNull();
    expect(event!.error, isNull);
    final msg = event.output!.messageOutput!.message!;
    expect(msg.contentBlocks[0].assistantGenText!.text, 'original content');
    expect(await iter.nextOrNull(), isNull);
    expect(captured, hasLength(3));
  });

  test('TestAgenticGetComposeOptions_WithChatModelOptions', () async {
    double? capturedTemperature;
    final m = MockAgenticModel(
      onGenerate: (_, options) async {
        capturedTemperature = options?.temperature;
        return agenticMsg('response');
      },
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'AgenticOptionsAgent',
      description: 'Test agent',
      model: m,
    ));
    await drainAgenticEvents(
      agent.run(
        ctx,
        AgenticAgentInput(messages: [AgenticMessage.user('test')]),
        options: [
          AgentRunOption.chatModelOptions(
            const ChatModelOptions(temperature: 0.7),
          ),
        ],
      ),
    );
    expect(capturedTemperature, 0.7);
  });

  test('TestAgenticChatModelAgent_PrepareExecContextError', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('response'),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'AgenticErrToolAgent',
      description: 'Test agent',
      model: m,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(
          tools: [ErrorTool(const ThreepioException('tool info error'))],
        ),
      ),
    ));

    final iter = agent.run(
      ctx,
      AgenticAgentInput(messages: [AgenticMessage.user('test')]),
    );
    final event = await iter.nextOrNull();
    expect(event!.error, isNotNull);
    expect(event.error.toString(), contains('tool info error'));
    expect(await iter.nextOrNull(), isNull);
  });

  test('TestAgenticRunner_Run_WithStreaming', () async {
    final agent = MockAgenticRunnerAgent(
      name: 'AgenticStreamRunnerAgent',
      description: 'Test agent for agentic runner streaming',
      responses: [
        AgenticAgentEvent(
          agentName: 'AgenticStreamRunnerAgent',
          output: AgenticAgentOutput(
            messageOutput: AgenticMessageVariant.stream(
              StreamReader.fromIterable([agenticMsg('Streaming response')]),
            ),
          ),
        ),
      ],
    );
    final runner = AgenticRunner(agent: agent, enableStreaming: true);
    final msgs = [AgenticMessage.user('Hello, agent!')];
    final iter = runner.run(ctx, msgs);

    // The agent was started synchronously, as in eino.
    expect(agent.callCount, 1);
    expect(agent.lastInput!.messages, msgs);
    expect(agent.enableStreaming, isTrue);

    final event = await iter.nextOrNull();
    expect(event!.agentName, 'AgenticStreamRunnerAgent');
    expect(event.output!.messageOutput!.isStreaming, isTrue);
    expect(await iter.nextOrNull(), isNull);
  });

  test('TestAgenticRunner_Query_WithStreaming', () async {
    final agent = MockAgenticRunnerAgent(
      name: 'AgenticStreamQueryAgent',
      description: 'Test agent for agentic runner query streaming',
      responses: [
        AgenticAgentEvent(
          agentName: 'AgenticStreamQueryAgent',
          output: AgenticAgentOutput(
            messageOutput: AgenticMessageVariant.stream(
              StreamReader.fromIterable([agenticMsg('Streaming query response')]),
            ),
          ),
        ),
      ],
    );
    final runner = AgenticRunner(agent: agent, enableStreaming: true);
    final iter = runner.query(ctx, 'Test query');

    expect(agent.callCount, 1);
    expect(agent.lastInput!.messages, hasLength(1));
    expect(agent.enableStreaming, isTrue);

    final event = await iter.nextOrNull();
    expect(event!.agentName, 'AgenticStreamQueryAgent');
    expect(event.output!.messageOutput!.isStreaming, isTrue);
    expect(await iter.nextOrNull(), isNull);
  });

  test('TestAgenticSimpleInterrupt', () async {
    const data = 'hello world';
    var resumeCalled = false;
    final agent = MyAgenticAgent(
      runFn: (ctx, input, options) => eventsOf((writer) {
        writer.send(
          AgenticAgentEvent(
            output: AgenticAgentOutput(
              messageOutput: AgenticMessageVariant.stream(
                StreamReader.fromIterable([
                  AgenticMessage.user('hello '),
                  AgenticMessage.user('world'),
                ]),
              ),
            ),
          ),
        );
        final event = agenticInterruptEvent(ctx, data);
        writer.send(
          event.copyWith(action: event.action!.withInterruptData(data)),
        );
      }),
      resumeFn: (ctx, info, options) {
        resumeCalled = true;
        expect(info.wasInterrupted, isTrue);
        expect(info.interruptState, isNull);
        expect(info.enableStreaming, isTrue);
        expect(info.isResumeTarget, isTrue);
        return StreamReader.fromIterable(const []);
      },
    );
    final store = InMemoryCheckpointStore();
    final runner = AgenticRunner(
      agent: agent,
      enableStreaming: true,
      checkpointStore: store,
    );
    final events = await drainAgenticEvents(
      runner.query(
        ctx,
        'hello world',
        options: [AgentRunOption.checkpointId('1')],
      ),
    );
    final interruptEvent = findInterruptEvent(events);
    expect(interruptEvent, isNotNull);
    final interrupted = interruptEvent!.action!.interrupted!;
    expect(interrupted.data, data);
    expect(interrupted.interruptContexts[0].id, isNotEmpty);
    expect(interrupted.interruptContexts[0].isRootCause, isTrue);
    expect(interrupted.interruptContexts[0].info, data);
    expect(
      interrupted.interruptContexts[0].address,
      Address([
        const AddressSegment(type: addressSegmentAgent, id: 'myAgenticAgent'),
      ]),
    );

    // Go stops here; resuming the interrupt point by id completes the
    // resumeFn assertions above.
    final resumed = await runner.resumeWithParams(
      ctx,
      '1',
      ResumeParams(targets: {interrupted.interruptContexts[0].id: null}),
    );
    await drainAgenticEvents(resumed);
    expect(resumeCalled, isTrue);
  });

  test('TestCascadingFrom_NewChatModelAgentFrom', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('from response'),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'FromAgent',
      description: 'Test cascading constructor',
      instruction: 'Be helpful.',
      model: m,
    ));
    expect(agent.name, 'FromAgent');
    final iter = AgenticRunner(agent: agent)
        .run(ctx, [AgenticMessage.user('Hello')]);
    final event = await iter.nextOrNull();
    expect(event!.error, isNull);
    expect(event.output, isNotNull);
    expect(await iter.nextOrNull(), isNull);
  });

  test('TestCascadingTyped_TypedStatefulInterrupt', () {
    final c = ctx.appendAddressSegment(addressSegmentAgent, 'test-agent');
    final event = agenticStatefulInterruptEvent(c, 'please confirm', {'Count': 42});
    expect(event.action, isNotNull);
    expect(event.action!.interrupted, isNotNull);
  });

  test('TestCascadingTyped_EventFromAgenticMessage', () {
    final msg = agenticMsg('hello');
    final event = AgenticAgentEvent.fromMessage(
      msg,
      agenticRole: AgenticRoleType.assistant,
    );
    final variant = event.output!.messageOutput!;
    expect(variant.message, same(msg));
    expect(variant.isStreaming, isFalse);
    expect(variant.agenticRole, AgenticRoleType.assistant);
    // Go's Role/ToolName are empty for agentic variants; they are not
    // ported, so there is nothing else to check.
  });

  test('TestCoverage_FlowAgent_ResumeNotResumable', () async {
    final agent = MockAgenticRunnerAgent(
      name: 'non-resumable',
      description: 'cannot resume',
      responses: [
        AgenticAgentEvent(
          output: AgenticAgentOutput(
            messageOutput: AgenticMessageVariant.message(agenticMsg('done')),
          ),
        ),
      ],
    );
    final events = await drainAgenticEvents(
      AgenticFlowAgent(agent).resume(
        ctx,
        const ResumeInfo(wasInterrupted: true),
        const [],
      ),
    );
    expect(firstAgenticEventError(events), isNotNull);
  });

  test('TestCoverage_GenAgenticErrorIter', () async {
    const testErr = ThreepioException('test agentic error');
    final iter = StreamReader.fromIterable([AgenticAgentEvent.failure(testErr)]);
    final event = await iter.nextOrNull();
    expect(event!.error, same(testErr));
    expect(await iter.nextOrNull(), isNull);
  });

  test('TestCoverage_TypedGetMessage_AgenticNonStreaming', () async {
    final msg = agenticMsg('hello');
    final event = AgenticAgentEvent(
      output: AgenticAgentOutput(
        messageOutput: AgenticMessageVariant.message(msg),
      ),
    );
    expect(await getAgenticMessageFromEvent(event), same(msg));
  });

  test('TestCoverage_TypedGetMessage_AgenticStreaming', () async {
    final event = AgenticAgentEvent(
      output: AgenticAgentOutput(
        messageOutput: AgenticMessageVariant.stream(
          StreamReader.fromIterable([agenticMsg('Hello '), agenticMsg('world')]),
        ),
      ),
    );
    final result = await getAgenticMessageFromEvent(event);
    expect(result, isNotNull);
    // The event stays readable.
    final stream = event.output!.messageOutput!.messageStream!;
    final chunks = <AgenticMessage>[];
    for (var c = await stream.nextOrNull(); c != null; c = await stream.nextOrNull()) {
      chunks.add(c);
    }
    expect(chunks, hasLength(2));
  });

  test('TestCoverage_TypedGetMessage_NilOutput', () async {
    expect(await getAgenticMessageFromEvent(const AgenticAgentEvent()), isNull);
  });

  test('TestCoverage_CopyAgenticEvent', () async {
    const action = AgentAction(customizedAction: 'transfer');
    final original = AgenticAgentEvent(
      agentName: 'agent1',
      output: AgenticAgentOutput(
        messageOutput: AgenticMessageVariant.message(
          agenticMsg('hello'),
          agenticRole: AgenticRoleType.assistant,
        ),
      ),
      action: action,
    );
    final copied = copyAgenticAgentEvent(original);
    expect(copied.agentName, original.agentName);
    expect(copied.action, same(original.action));
    expect(copied.output!.messageOutput!.agenticRole, AgenticRoleType.assistant);
  });

  test('TestCoverage_ChatModelAgent_ModelGenerateError', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async =>
          throw const ThreepioException('model generate failed'),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'error-model-agent',
      description: 'tests model generate error',
      model: m,
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: agent).query(ctx, 'trigger error'),
    );
    expect(firstAgenticEventError(events), isNotNull);
  });

  group('TestCoverage_NewTypedUserMessages', () {
    test('Message', () {
      final msg = classicMessageCodec.user('hello');
      expect(msg.role, RoleType.user);
      expect(msg.content, 'hello');
    });

    test('AgenticMessage', () {
      final msg = agenticMessageCodec.user('hello');
      expect(msg.role, AgenticRoleType.user);
    });
  });

  test('TestCoverage_TypedEndpointModel_NilEndpoints', () async {
    final m = AgenticEndpointModel();
    await expectLater(
      m.generate(const []),
      throwsA(predicate((e) => '$e'.contains('generate endpoint not set'))),
    );
    await expectLater(
      m.stream(const []),
      throwsA(predicate((e) => '$e'.contains('stream endpoint not set'))),
    );
  });

  test('TestCoverage_TypedEndpointModel_WithEndpoints', () async {
    final expected = agenticMsg('generated');
    final m = AgenticEndpointModel(
      onGenerate: (_, __) async => expected,
      onStream: (_, __) async => StreamReader.fromIterable([expected]),
    );
    expect(await m.generate(const []), same(expected));
    final stream = await m.stream(const []);
    expect(await stream.recv(), same(expected));
    await expectLater(stream.recv(), throwsA(isA<StreamEOFException>()));
  });

  test('TestCoverage_SetAutomaticClose', () {
    final event = AgenticAgentEvent(
      output: AgenticAgentOutput(
        messageOutput: AgenticMessageVariant.stream(
          StreamReader.fromIterable([agenticMsg('data')]),
        ),
      ),
    );
    setAgenticAutomaticClose(event);
  });

  test('TestConcatMessageStream_AgenticClosesStream', () async {
    final (reader, writer) = pipe<AgenticMessage>(capacity: 2);
    writer
      ..send(agenticMsg('a'))
      ..send(agenticMsg('b'));
    unawaited(writer.close());
    final result = await concatMessageStreamWith(agenticMessageCodec, reader);
    expect(result, isNotNull);
    await expectLater(reader.recv(), throwsA(anything));
  });
}
