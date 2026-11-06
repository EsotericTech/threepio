// Tests written for the port (no Go counterpart of their own): the agentic
// middlewares' agent hooks, wrappers and tool hooks, run-local values and
// sendAgenticEvent in an agentic run, message ids, the agentic tool result
// events (text, streamed, multimodal, tool search), the JSON forms, the
// message codecs and the classic checkpoint envelope that the agentic root
// input was added to.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/agentic/agent_message_codec.dart';
import 'package:threepio_core/src/adk/agentic/agentic_wrappers.dart'
    show toolResultAgenticMessage;
import 'package:threepio_core/src/adk/eino/agent_context.dart'
    show
        AdkRunContext,
        RunSession,
        adkRunContextOf,
        initAdkRunContext,
        withAdkRunContext;
import 'package:threepio_core/src/adk/eino/interrupt.dart' show AdkCheckpoint;
import 'package:threepio_core/src/adk/eino/run_options.dart'
    show sharedParentSessionOption;

import 'agentic_fakes.dart';

/// A middleware made of functions.
class _Middleware extends AgenticChatModelAgentMiddleware {
  _Middleware({
    this.onBeforeAgent,
    this.onAfterAgent,
    this.onBeforeModel,
    this.onWrapModel,
    this.onWrapTool,
  });

  final FutureOr<void> Function(RunContext ctx, ChatModelAgentContext agent)?
      onBeforeAgent;
  final FutureOr<void> Function(RunContext ctx, AgenticChatModelAgentState state)?
      onAfterAgent;
  final FutureOr<void> Function(RunContext ctx, AgenticChatModelAgentState state)?
      onBeforeModel;
  final AgenticModel Function(AgenticModel model)? onWrapModel;
  final InvokableToolCallEndpoint Function(
    InvokableToolCallEndpoint next,
    ToolContext tool,
  )? onWrapTool;

  @override
  Future<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) async {
    await onBeforeAgent?.call(ctx, agent);
    return (ctx, agent);
  }

  @override
  Future<RunContext> afterAgent(
    RunContext ctx,
    AgenticChatModelAgentState state,
  ) async {
    await onAfterAgent?.call(ctx, state);
    return ctx;
  }

  @override
  Future<(RunContext, AgenticChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticModelContext model,
  ) async {
    await onBeforeModel?.call(ctx, state);
    return (ctx, state);
  }

  @override
  AgenticModel wrapModel(
    RunContext ctx,
    AgenticModel model,
    AgenticModelContext context,
  ) =>
      onWrapModel?.call(model) ?? model;

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      onWrapTool?.call(next, tool) ?? next;
}

/// A model that prefixes the text of what [inner] says.
class _PrefixModel implements AgenticModel {
  _PrefixModel(this.inner, this.prefix);

  final AgenticModel inner;
  final String prefix;

  AgenticMessage _prefixed(AgenticMessage m) =>
      agenticMsg('$prefix${agenticTextContent(m)}').copyWith(extra: m.extra);

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      _prefixed(await inner.generate(input, options: options));

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      (await inner.stream(input, options: options)).convert(_prefixed);
}

class _StreamTool extends StreamableTool {
  @override
  Future<ToolInfo> info() async =>
      ToolInfo.fromParams(name: 'streamer', desc: 'streams', params: const {});

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable(['a', 'b', 'c']);
}

class _ImageTool implements EnhancedInvokableTool {
  @override
  Future<ToolInfo> info() async =>
      ToolInfo.fromParams(name: 'imager', desc: 'images', params: const {});

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      const ToolResult([
        ToolOutputPart(type: ToolPartType.text, text: 'see'),
        ToolOutputPart(
          type: ToolPartType.image,
          image: ToolOutputImage(
            common: MessagePartCommon(url: 'https://x/y.png', mimeType: 'image/png'),
          ),
        ),
      ]);
}

void main() {
  final ctx = RunContext.background();

  group('middleware agent hooks', () {
    test('beforeAgent adds a tool and changes the instruction; afterAgent '
        'sees the final state', () async {
      final seenInputs = <List<AgenticMessage>>[];
      List<AgenticMessage>? finalMessages;
      final mdl = MockAgenticModel();
      var call = 0;
      mdl.onGenerate = (input, options) async {
        seenInputs.add(input);
        return ++call == 1
            ? agenticToolCallMsg('echo', 'c1', '"x"')
            : agenticMsg('done');
      };
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'hooks',
        instruction: 'base',
        model: mdl,
        handlers: [
          _Middleware(
            onBeforeAgent: (ctx, agent) {
              agent
                ..instruction = '${agent.instruction} + more'
                ..tools = [...agent.tools, AgenticEchoTool('echo')];
            },
            onAfterAgent: (ctx, state) => finalMessages = state.messages,
          ),
        ],
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'hi'),
      );
      expect(firstAgenticEventError(events), isNull);
      // The graph was rebuilt with tools: model, tool, model.
      expect(events, hasLength(3));
      final system = seenInputs.first.first;
      expect(system.role, AgenticRoleType.system);
      expect(
        (system.contentBlocks.single.content as UserInputText).text,
        'base + more',
      );
      // system, user, tool call, tool result, answer.
      expect(finalMessages, hasLength(5));
      expect(agenticTextContent(finalMessages!.last), 'done');
    });

    test('a failing beforeAgent fails the run', () async {
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'failing',
        model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('x')),
        handlers: [
          _Middleware(
            onBeforeAgent: (_, __) => throw const ThreepioException('nope'),
          ),
        ],
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'hi'),
      );
      expect(
        '${firstAgenticEventError(events)}',
        allOf(contains('ChatModelAgent getRunFunc error'), contains('nope')),
      );
    });

    test('wrapModel wraps the model inside the event sender', () async {
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'wrap',
        model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('raw')),
        handlers: [
          _Middleware(onWrapModel: (model) => _PrefixModel(model, 'wrapped: ')),
        ],
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'hi'),
      );
      expect(
        agenticTextContent(events.single.output!.messageOutput!.message),
        'wrapped: raw',
      );
    });

    test('tool hooks wrap the tool calls (inside the tool event sender)',
        () async {
      final mdl = SequentialAgenticModel([
        agenticToolCallMsg('echo', 'c1', '"x"'),
        agenticMsg('done'),
      ]);
      final seen = <ToolContext>[];
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'tools',
        model: mdl,
        toolsConfig: ToolsConfig(
          toolsNode: ToolsNodeConfig(tools: [AgenticEchoTool('echo')]),
        ),
        handlers: [
          _Middleware(
            onWrapTool: (next, tool) => (ctx, args, options) async {
              seen.add(tool);
              return 'hooked(${await next(ctx, args, options)})';
            },
          ),
        ],
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'hi'),
      );
      expect(seen, [const ToolContext(name: 'echo', callId: 'c1')]);
      final result = events[1].output!.messageOutput!.message!.contentBlocks
          .single.functionToolResult!;
      expect(
        (result.content.single.content as UserInputText).text,
        'hooked(echo:"x")',
      );
    });

    test('run-local values and sendAgenticEvent work inside an agentic run',
        () async {
      Object? readBack;
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'local',
        model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('x')),
        handlers: [
          _Middleware(
            onBeforeModel: (ctx, state) async {
              ctx.setRunLocalValue('k', 42);
              readBack = ctx.runLocalValue('k');
              await ctx.sendAgenticEvent(
                AgenticAgentEvent.fromMessage(
                  ensureAgenticMessageId(agenticMsg('custom')),
                  agenticRole: AgenticRoleType.assistant,
                ),
              );
            },
          ),
        ],
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'hi'),
      );
      expect(readBack, 42);
      expect(events, hasLength(2));
      final custom = events.first.output!.messageOutput!.message!;
      expect(agenticTextContent(custom), 'custom');
      expect(agenticMessageIdOf(custom), isNotEmpty);
      // Named by the runner like the agent's own events.
      expect(events.first.agentName, 'local');
    });

    test('sendAgenticEvent outside an agentic run fails', () async {
      await expectLater(
        ctx.sendAgenticEvent(const AgenticAgentEvent()),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('tool result events', () {
    test('a streamed tool result streams user chunks with StreamingMeta',
        () async {
      final mdl = SequentialAgenticModel([
        agenticToolCallMsg('streamer', 's1', '{}'),
        agenticMsg('done'),
      ]);
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'stream-tool',
        model: mdl,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_StreamTool()])),
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent, enableStreaming: true).query(ctx, 'go'),
      );
      expect(firstAgenticEventError(events), isNull);
      final toolVariant = events[1].output!.messageOutput!;
      expect(toolVariant.isStreaming, isTrue);
      expect(toolVariant.agenticRole, AgenticRoleType.user);
      final chunks = <AgenticMessage>[];
      final stream = toolVariant.messageStream!;
      for (var c = await stream.nextOrNull(); c != null; c = await stream.nextOrNull()) {
        chunks.add(c);
      }
      expect(chunks, hasLength(3));
      expect(chunks.first.contentBlocks.single.streamingMeta!.index, 0);
      expect(agenticMessageIdOf(chunks.first), isNotEmpty);
      expect(agenticMessageIdOf(chunks[1]), isEmpty);
    });

    test('an enhanced tool keeps its media parts', () async {
      final mdl = SequentialAgenticModel([
        agenticToolCallMsg('imager', 'i1', '{}'),
        agenticMsg('done'),
      ]);
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'image-tool',
        model: mdl,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_ImageTool()])),
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'go'),
      );
      final result = events[1].output!.messageOutput!.message!.contentBlocks
          .single.functionToolResult!;
      expect(result.content, hasLength(2));
      expect((result.content[0].content as UserInputText).text, 'see');
      final image = result.content[1].content as UserInputImage;
      expect(image.url, 'https://x/y.png');
      expect(image.mimeType, 'image/png');
    });

    test('a tool search result becomes a ToolSearchFunctionToolResult', () {
      const found = ToolSearchResult(tools: []);
      final message = toolResultAgenticMessage(
        'c',
        'search',
        const ToolResult([
          ToolOutputPart(
            type: ToolPartType.toolSearchResult,
            toolSearchResult: found,
          ),
        ]),
      );
      final block = message.contentBlocks.single.toolSearchFunctionToolResult!;
      expect(block.callId, 'c');
      expect(block.name, 'search');
      expect(block.result, found);
      expect(message.role, AgenticRoleType.user);
    });
  });

  group('message ids', () {
    test('the model output event and the state share the message id',
        () async {
      List<AgenticMessage>? stateMessages;
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'ids',
        model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('x')),
        handlers: [
          _Middleware(onAfterAgent: (ctx, state) => stateMessages = state.messages),
        ],
      ));
      final events = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(ctx, 'hi'),
      );
      final eventId = agenticMessageIdOf(events.single.output!.messageOutput!.message!);
      expect(eventId, isNotEmpty);
      expect(agenticMessageIdOf(stateMessages!.last), eventId);
    });

    test('ensureAgenticMessageId keeps an existing id', () {
      final withId = ensureAgenticMessageId(agenticMsg('x'));
      expect(ensureAgenticMessageId(withId), same(withId));
      expect(withId.extra![einoMessageIdKey], agenticMessageIdOf(withId));
    });
  });

  group('JSON forms', () {
    test('input, events and variants round-trip', () async {
      final input = AgenticAgentInput(
        messages: [AgenticMessage.user('hi')],
        enableStreaming: true,
      );
      final inputCopy = AgenticAgentInput.fromJson(
        jsonDecode(jsonEncode(input.toJson())) as Map<String, Object?>,
      );
      expect(inputCopy.messages, input.messages);
      expect(inputCopy.enableStreaming, isTrue);

      final streamed = AgenticMessageVariant.stream(
        StreamReader.fromIterable([agenticMsg('a'), agenticMsg('b')]),
        agenticRole: AgenticRoleType.assistant,
      );
      expect(streamed.toJson, throwsStateError);
      final joined = await streamed.getMessage();
      final event = AgenticAgentEvent(
        agentName: 'n',
        output: AgenticAgentOutput(messageOutput: streamed, customizedOutput: 'c'),
        action: const AgentAction(customizedAction: 'act'),
        error: const ThreepioException('boom'),
      );
      final copy = AgenticAgentEvent.fromJson(
        jsonDecode(jsonEncode(event.toJson())) as Map<String, Object?>,
      );
      expect(copy.agentName, 'n');
      expect(copy.output!.messageOutput!.isStreaming, isTrue);
      expect(copy.output!.messageOutput!.agenticRole, AgenticRoleType.assistant);
      expect(await copy.output!.messageOutput!.getMessage(), joined);
      expect(copy.output!.customizedOutput, 'c');
      expect(copy.action!.customizedAction, 'act');
      expect('${copy.error}', contains('boom'));
    });

    test('the agentic types are registered under eino names', () {
      // A ChatModelAgent registers them when it is built.
      AgenticChatModelAgent(
        AgenticChatModelAgentConfig(model: MockAgenticModel()),
      );
      final input = AgenticAgentInput(messages: [AgenticMessage.user('x')]);
      expect(TypeRegistry.nameOf(input), '_eino_adk_agentic_agent_input');
      expect(
        TypeRegistry.nameOf(const AgenticAgentEvent()),
        '_eino_adk_agentic_event',
      );
      final decoded = TypeRegistry.decode(
        jsonDecode(jsonEncode(TypeRegistry.encode(input))),
      )! as AgenticAgentInput;
      expect(decoded.messages, input.messages);
    });

    test('a custom agent interrupts with a checkpoint on a fresh registry',
        () async {
      TypeRegistry.reset();
      final agent = MyAgenticAgent(
        runFn: (ctx, input, options) => StreamReader.fromIterable([
          agenticInterruptEvent(ctx, 'wait'),
        ]),
        resumeFn: (ctx, info, options) => StreamReader.fromIterable([
          AgenticAgentEvent.fromMessage(
            agenticMsg('resumed'),
            agenticRole: AgenticRoleType.assistant,
          ),
        ]),
      );
      final runner =
          AgenticRunner(agent: agent, checkpointStore: InMemoryCheckpointStore());
      final events = await drainAgenticEvents(
        runner.query(ctx, 'hi', options: [AgentRunOption.checkpointId('cp')]),
      );
      expect(firstAgenticEventError(events), isNull);
      TypeRegistry.reset();
      final resumed = await drainAgenticEvents(await runner.resume(ctx, 'cp'));
      expect(firstAgenticEventError(resumed), isNull);
      expect(
        agenticTextContent(resumed.single.output!.messageOutput!.message),
        'resumed',
      );
    });

    test('a classic checkpoint has no agentic root input (unchanged shape)',
        () {
      final checkpoint = AdkCheckpoint(
        sessionValues: const {'a': 1},
        enableStreaming: false,
        interruptId2Address: const {},
        interruptId2State: const {},
        rootInput: AgentInput(messages: [Message.user('x')]),
      );
      final json = checkpoint.toJson();
      expect(json.containsKey('agentic_root_input'), isFalse);
      expect(AdkCheckpoint.fromJson(json).agenticRootInput, isNull);
    });
  });

  group('run context', () {
    test('an agentic agent entering a run becomes the agentic root input', () {
      final input = AgenticAgentInput(messages: [AgenticMessage.user('x')]);
      final (entered, run) = initAdkRunContext(ctx, 'a', null, agenticInput: input);
      expect(run.agenticRootInput, same(input));
      expect(run.rootInput, isNull);
      expect(run.isRoot, isTrue);
      final (_, nested) = initAdkRunContext(
        entered,
        'b',
        null,
        agenticInput: AgenticAgentInput(),
      );
      expect(nested.agenticRootInput, same(input));
      expect(nested.depth, 2);
      expect(adkRunContextOf(entered), same(run));
    });

    test('session values reach the agentic agent', () async {
      Object? seen;
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'session',
        model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('x')),
        genModelInput: (ctx, instruction, input) {
          seen = ctx.sessionValue('user');
          return input.messages;
        },
      ));
      await drainAgenticEvents(
        AgenticRunner(agent: agent).query(
          ctx,
          'hi',
          options: [AgentRunOption.sessionValues(const {'user': 'ann'})],
        ),
      );
      expect(seen, 'ann');
    });

    test('a shared parent session is used by a nested runner', () async {
      final session = RunSession({'shared': true});
      final parent = withAdkRunContext(ctx, AdkRunContext(session: session));
      Object? seen;
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'nested',
        model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('x')),
        genModelInput: (ctx, instruction, input) {
          seen = ctx.sessionValue('shared');
          ctx.addSessionValue('back', 1);
          return input.messages;
        },
      ));
      await drainAgenticEvents(
        AgenticRunner(agent: agent).query(
          parent,
          'hi',
          options: [sharedParentSessionOption()],
        ),
      );
      expect(seen, isTrue);
      expect(session.values['back'], 1);
    });
  });

  group('codecs', () {
    test('the classic codec matches the classic helpers', () {
      final m = Message.assistant('x');
      expect(classicMessageCodec.textContent(m), 'x');
      final withId = ensureMessageIdWith(classicMessageCodec, m);
      expect(messageIdOf(withId), classicMessageCodec.messageIdOf(withId));
      expect(classicMessageCodec.hasToolCalls(m), isFalse);
      expect(
        classicMessageCodec.decode(classicMessageCodec.encode(withId)),
        withId,
      );
      expect(
        classicMessageCodec.toolResultOf(
          Message.tool(content: 'r', toolCallId: 'c', toolName: 't'),
        ),
        (toolName: 't', callId: 'c'),
      );
    });

    test('the agentic codec reads tool calls, tool results and text', () {
      final call = agenticToolCallMsg('t', 'c', '{}');
      expect(agenticMessageCodec.toolCallsOf(call), [(name: 't', callId: 'c')]);
      final result = AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [
          ContentBlock(FunctionToolResult(callId: 'c', name: 't')),
        ],
      );
      expect(agenticMessageCodec.toolResultOf(result), (toolName: 't', callId: 'c'));
      final twoTexts = AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(const AssistantGenText(text: 'a')),
          ContentBlock(const Reasoning(text: 'hidden')),
          ContentBlock(const AssistantGenText(text: 'b')),
        ],
      );
      expect(agenticMessageCodec.textContent(twoTexts), 'a\nb');
      expect(agenticMessageCodec.system('s').role, AgenticRoleType.system);
    });
  });
}
