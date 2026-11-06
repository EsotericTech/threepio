// Ports eino v0.9.22 `adk/agentic_integration_test.go`:
//   TestAgenticIntegration_ChatModelSingleShot,
//   TestAgenticIntegration_ChatModelToolsPassedViaOptions,
//   TestAgenticIntegration_StreamingWithRunner,
//   TestAgenticIntegration_InterruptEventFormation (simple interrupt,
//   stateful interrupt), TestAgenticIntegration_CheckpointInterruptResume,
//   TestAgenticIntegration_CheckpointWithMCPListToolsResult.
//
//   TestAgenticIntegration_CancelDuringExecution and _CancelWithTimeout (Go
//   cancels the `context.Context`; here the run's `RunContext.cancelToken`
//   is cancelled, and Go's `context.Canceled` / `DeadlineExceeded` is a
//   `CancelledException` with the token's reason; the timeout is a 20 ms
//   timer that cancels the token, and the agent's 10 s wait is a future that
//   never completes).
// TestAgenticIntegration_AgentTool is in agentic_agent_tool_test.dart.
//
// In _CheckpointWithMCPListToolsResult eino's checkpoint carries the MCP
// message in the session's event history (agent transfer state, not ported);
// here the MCP message is also checked to survive the JSON form of an
// agentic event, which is what a checkpoint of a `returnDirectly` event or an
// agentic state writes.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/interrupt.dart' show AdkCheckpoint;

import 'agentic_fakes.dart';

void main() {
  final ctx = RunContext.background();

  test('TestAgenticIntegration_ChatModelSingleShot', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async =>
          agenticMsg('Handled internally with tool result: 42'),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'ToolCallAgent',
      description: 'Agent with tools for agentic model',
      instruction: 'You are a calculator.',
      model: m,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [SlowTool('calculator', '42')]),
      ),
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: agent).query(ctx, 'What is 6*7?'),
    );
    expect(events, hasLength(1));
    expect(agenticEventRoleProblems(events), isEmpty);
    final last = events.last;
    expect(last.error, isNull);
    expect(
      agenticTextContent(last.output!.messageOutput!.message),
      'Handled internally with tool result: 42',
    );
  });

  test('TestAgenticIntegration_ChatModelToolsPassedViaOptions', () async {
    List<ToolInfo>? receivedTools;
    final m = MockAgenticModel(
      onGenerate: (_, options) async {
        receivedTools = options?.tools;
        return agenticMsg('done');
      },
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'ToolOptAgent',
      description: 'Agent verifying tools are passed via options',
      model: m,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [SlowTool('my_tool', 'result')]),
      ),
    ));
    await drainAgenticEvents(AgenticRunner(agent: agent).query(ctx, 'test tools'));
    expect(receivedTools, isNotNull, reason: 'tools should be passed via options');
    expect(receivedTools, hasLength(1));
    expect(receivedTools![0].name, 'my_tool');
  });

  test('TestAgenticIntegration_StreamingWithRunner', () async {
    final m = MockAgenticModel(
      onStream: (_, __) async => StreamReader.fromIterable([
        agenticMsg('Hello '),
        agenticMsg('world'),
      ]),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'StreamRunner',
      description: 'Streaming runner agent',
      model: m,
    ));
    final iter =
        AgenticRunner(agent: agent, enableStreaming: true).query(ctx, 'stream me');
    final event = await iter.nextOrNull();
    expect(event!.error, isNull);
    final variant = event.output!.messageOutput!;
    expect(variant.isStreaming, isTrue);
    final chunks = <AgenticMessage>[];
    final stream = variant.messageStream!;
    for (var c = await stream.nextOrNull(); c != null; c = await stream.nextOrNull()) {
      chunks.add(c);
    }
    expect(chunks, hasLength(2));
    // The first chunk carries the message id the agent gave the output.
    expect(agenticMessageIdOf(chunks.first), isNotEmpty);
    expect(await iter.nextOrNull(), isNull);
  });

  group('TestAgenticIntegration_InterruptEventFormation', () {
    test('simple interrupt', () async {
      final agent = MyAgenticAgent(
        name: 'int-agent',
        runFn: (ctx, input, options) => eventsOf((writer) {
          final event = agenticInterruptEvent(ctx, 'approval needed');
          writer.send(
            event.copyWith(
              action: event.action!.withInterruptData('approval data'),
            ),
          );
        }),
      );
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'interrupt test'),
      );
      final interrupted = findInterruptEvent(events)!.action!.interrupted!;
      expect(interrupted.data, 'approval data');
      expect(interrupted.interruptContexts, isNotEmpty);
      expect(interrupted.interruptContexts[0].id, isNotEmpty);
      expect(interrupted.interruptContexts[0].info, 'approval needed');
      expect(interrupted.interruptContexts[0].isRootCause, isTrue);
    });

    test('stateful interrupt', () async {
      final agent = MyAgenticAgent(
        name: 'st-agent',
        runFn: (ctx, input, options) => eventsOf((writer) {
          final event =
              agenticStatefulInterruptEvent(ctx, 'state interrupt', 'my-state');
          writer.send(
            event.copyWith(
              action: event.action!.withInterruptData('stateful data'),
            ),
          );
        }),
      );
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'stateful test'),
      );
      final interrupted = findInterruptEvent(events)!.action!.interrupted!;
      expect(interrupted.data, 'stateful data');
      expect(interrupted.interruptContexts, isNotEmpty);
      expect(interrupted.interruptContexts[0].info, 'state interrupt');
    });
  });

  test('TestAgenticIntegration_CancelDuringExecution', () async {
    final modelStarted = Completer<void>();
    final m = MockAgenticModel(
      onGenerate: (_, options) async {
        if (!modelStarted.isCompleted) modelStarted.complete();
        final token = options!.runContext!.cancelToken;
        await token.whenCancelled;
        token.throwIfCancelled();
        return agenticMsg('should not reach');
      },
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'CancelAgent',
      description: 'cancel test',
      model: m,
    ));
    final token = CancelToken();
    final iter = AgenticRunner(agent: agent).run(
      ctx.withCancelToken(token),
      [AgenticMessage.user('Hi')],
    );
    await modelStarted.future;
    token.cancel('context canceled');
    final error = firstAgenticEventError(await drainAgenticEvents(iter));
    expect(error, isNotNull, reason: 'should propagate cancel error');
    expect(ThreepioException.findCause<CancelledException>(error), isNotNull);
  });

  test('TestAgenticIntegration_CancelWithTimeout', () async {
    final agent = MyAgenticAgent(
      name: 'slow-agent',
      runFn: (ctx, input, options) => eventsOf((writer) async {
        final token = ctx.cancelToken;
        await Future.any([Completer<void>().future, token.whenCancelled]);
        writer.send(
          AgenticAgentEvent(error: CancelledException(token.reason)),
        );
      }),
    );
    final token = CancelToken();
    final timer = Timer(
      const Duration(milliseconds: 20),
      () => token.cancel('context deadline exceeded'),
    );
    addTearDown(timer.cancel);
    final error = firstAgenticEventError(
      await drainAgenticEvents(
        AgenticRunner(agent: agent).run(
          ctx.withCancelToken(token),
          [AgenticMessage.user('slow request')],
        ),
      ),
    );
    expect(error, isNotNull, reason: 'should get timeout/cancel error');
    final cancelled = ThreepioException.findCause<CancelledException>(error);
    expect(cancelled?.reason, 'context deadline exceeded');
  });

  test('TestAgenticIntegration_CheckpointInterruptResume', () async {
    var resumeCalled = 0;
    ResumeInfo? resumedWith;
    final agent = MyAgenticAgent(
      name: 'ckpt-agent',
      runFn: (ctx, input, options) => eventsOf((writer) {
        writer.send(
          AgenticAgentEvent(
            agentName: 'ckpt-agent',
            output: AgenticAgentOutput(
              messageOutput:
                  AgenticMessageVariant.message(agenticMsg('before interrupt')),
            ),
          ),
        );
        final event = agenticInterruptEvent(ctx, 'need approval');
        writer.send(
          event.copyWith(action: event.action!.withInterruptData('approval data')),
        );
      }),
      resumeFn: (ctx, info, options) {
        resumeCalled++;
        resumedWith = info;
        return eventsOf((writer) {
          writer.send(
            AgenticAgentEvent(
              agentName: 'ckpt-agent',
              output: AgenticAgentOutput(
                messageOutput:
                    AgenticMessageVariant.message(agenticMsg('after resume')),
              ),
            ),
          );
        });
      },
    );
    final store = InMemoryCheckpointStore();
    final runner = AgenticRunner(agent: agent, checkpointStore: store);

    final events = await drainAgenticEvents(
      runner.query(
        ctx,
        'checkpoint test',
        options: [AgentRunOption.checkpointId('ckpt-1')],
      ),
    );
    for (final event in events) {
      expect(event.error, isNull);
    }
    final interruptEvent = findInterruptEvent(events);
    expect(interruptEvent, isNotNull, reason: 'should receive interrupt event');
    final preInterruptOutputs = [
      for (final e in events)
        if (e.output?.messageOutput?.message case final m?) agenticTextContent(m),
    ];
    expect(preInterruptOutputs, contains('before interrupt'));
    final contexts = interruptEvent!.action!.interrupted!.interruptContexts;
    expect(contexts, isNotEmpty);
    final interruptId = contexts[0].id;
    expect(interruptId, isNotEmpty);

    // The checkpoint is the classic envelope with the agentic root input.
    final saved = await store.get('ckpt-1');
    final checkpoint =
        const JsonCheckpointSerializer().deserialize(saved!)! as AdkCheckpoint;
    expect(checkpoint.rootInput, isNull);
    expect(
      (checkpoint.agenticRootInput! as AgenticAgentInput).messages.single,
      AgenticMessage.user('checkpoint test'),
    );

    final resumeIter = await runner.resumeWithParams(
      ctx,
      'ckpt-1',
      ResumeParams(targets: {interruptId: null}),
    );
    final postResume = await drainAgenticEvents(resumeIter);
    for (final event in postResume) {
      expect(event.error, isNull, reason: 'unexpected error during resume');
    }
    final postResumeOutputs = [
      for (final e in postResume)
        if (e.output?.messageOutput?.message case final m?) agenticTextContent(m),
    ];
    expect(resumeCalled, 1, reason: 'resume function should have been called');
    expect(postResumeOutputs, contains('after resume'));
    expect(resumedWith!.wasInterrupted, isTrue);
    expect(resumedWith!.isResumeTarget, isTrue);
    expect(postResume.single.agentName, 'ckpt-agent');
  });

  test('TestAgenticIntegration_CheckpointWithMCPListToolsResult', () async {
    final inputSchema = jsonDecode('''
      {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "search query"},
          "limit": {"type": "integer", "description": "max results"}
        },
        "required": ["query"]
      }''') as Map<String, Object?>;
    final mcpMsg = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(
          AgenticMcpListToolsResult(
            serverLabel: 'test-server',
            tools: [
              AgenticMcpListToolsItem(
                name: 'search',
                description: 'search the web',
                inputSchema: inputSchema,
              ),
            ],
          ),
        ),
        ContentBlock(const AssistantGenText(text: 'here are tools')),
      ],
    );

    var resumeCalled = 0;
    final agent = MyAgenticAgent(
      name: 'mcp-agent',
      runFn: (ctx, input, options) => eventsOf((writer) {
        writer
          ..send(
            AgenticAgentEvent(
              agentName: 'mcp-agent',
              output: AgenticAgentOutput(
                messageOutput: AgenticMessageVariant.message(mcpMsg),
              ),
            ),
          )
          ..send(agenticInterruptEvent(ctx, 'approve tools'));
      }),
      resumeFn: (ctx, info, options) {
        resumeCalled++;
        return eventsOf((writer) {
          writer.send(
            AgenticAgentEvent(
              agentName: 'mcp-agent',
              output: AgenticAgentOutput(
                messageOutput:
                    AgenticMessageVariant.message(agenticMsg('tools approved')),
              ),
            ),
          );
        });
      },
    );
    final store = InMemoryCheckpointStore();
    final runner = AgenticRunner(agent: agent, checkpointStore: store);

    final events = await drainAgenticEvents(
      runner.query(ctx, 'list tools', options: [AgentRunOption.checkpointId('mcp-1')]),
    );
    for (final event in events) {
      expect(event.error, isNull);
    }
    final interruptEvent = findInterruptEvent(events)!;
    final interruptId = interruptEvent.action!.interrupted!.interruptContexts[0].id;

    // The MCP block survives the checkpoint form of an agentic event.
    final mcpEvent = events.first;
    final revived = AgenticAgentEvent.fromJson(
      jsonDecode(jsonEncode(mcpEvent.toJson())) as Map<String, Object?>,
    );
    expect(revived.output!.messageOutput!.message, mcpMsg);
    final listed = revived.output!.messageOutput!.message!.contentBlocks[0]
        .mcpListToolsResult!;
    expect(listed.serverLabel, 'test-server');
    expect(listed.tools.single.inputSchema, inputSchema);

    final outputs = <String>[];
    for (final event in await drainAgenticEvents(
      await runner.resumeWithParams(
        ctx,
        'mcp-1',
        ResumeParams(targets: {interruptId: null}),
      ),
    )) {
      expect(event.error, isNull);
      if (event.output?.messageOutput?.message case final m?) {
        outputs.add(agenticTextContent(m));
      }
    }
    expect(resumeCalled, 1);
    expect(outputs, contains('tools approved'));
  });
}
