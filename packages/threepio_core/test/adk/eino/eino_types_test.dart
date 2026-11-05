// Unit tests of the public types of the Eino-shaped ADK (`adk.dart`): inputs,
// events, message variants, actions, run options, the agent context, the
// interrupt infos, the checkpoint envelope, languages and message ids.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/agent_callbacks.dart';
import 'package:threepio_core/src/adk/eino/agent_context.dart';
import 'package:threepio_core/src/adk/eino/agent_event.dart';
import 'package:threepio_core/src/adk/eino/interrupt.dart';
import 'package:threepio_core/src/adk/eino/language.dart';
import 'package:threepio_core/src/adk/eino/message_id.dart';
import 'package:threepio_core/src/adk/eino/message_variant.dart';
import 'package:threepio_core/src/adk/eino/react_graph.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart';
import 'package:threepio_core/src/compose/checkpoint_serializer.dart';
import 'package:threepio_core/src/compose/interrupt.dart' show InterruptState;
import 'package:threepio_core/src/compose/local_state.dart';

Message _assistant(String text) => Message(role: RoleType.assistant, content: text);

void main() {
  group('AgentInput', () {
    test('keeps an unmodifiable copy of the messages and round-trips JSON', () {
      final messages = [Message.user('hi')];
      final input = AgentInput(messages: messages, enableStreaming: true);
      messages.add(Message.user('later'));
      expect(input.messages, hasLength(1));
      expect(() => input.messages.add(Message.user('x')), throwsUnsupportedError);
      final back = AgentInput.fromJson(jsonDecode(jsonEncode(input.toJson())) as Map<String, Object?>);
      expect(back.messages.single.content, 'hi');
      expect(back.enableStreaming, isTrue);
    });
  });

  group('MessageVariant', () {
    test('a complete message', () async {
      final variant = MessageVariant.message(_assistant('a'), role: RoleType.assistant, toolName: '');
      expect(variant.isStreaming, isFalse);
      expect(variant.message!.content, 'a');
      expect(variant.messageStream, isNull);
      expect((await variant.getMessage()).content, 'a');
      expect(identical(variant.copyForSecondReader(), variant), isTrue);
      final back = MessageVariant.fromJson(variant.toJson());
      expect(back.isStreaming, isFalse);
      expect(back.role, RoleType.assistant);
    });

    test('a stream is joined once and then read as its joined message', () async {
      final variant = MessageVariant.stream(
        StreamReader.fromIterable([_assistant('He'), _assistant('llo')]),
        role: RoleType.assistant,
      );
      expect(() => variant.toJson(), throwsStateError, reason: 'not read yet');
      expect((await variant.getMessage()).content, 'Hello');
      expect((await variant.getMessage()).content, 'Hello', reason: 'kept');
      final rest = await variant.messageStream!.collectAll();
      expect(rest.single.content, 'Hello');
      final json = variant.toJson();
      expect(json['is_streaming'], isTrue);
      final back = MessageVariant.fromJson(json);
      expect(back.isStreaming, isTrue);
      expect((await back.getMessage()).content, 'Hello');
    });

    test('a second reader sees every chunk, and so does the first', () async {
      final variant = MessageVariant.stream(
        StreamReader.fromIterable([_assistant('a'), _assistant('b')]),
      );
      final copy = variant.copyForSecondReader();
      expect((await copy.messageStream!.collectAll()).map((m) => m.content), ['a', 'b']);
      expect((await variant.messageStream!.collectAll()).map((m) => m.content), ['a', 'b']);
    });

    test('an error in the stream is rethrown, also later, and the chunks so far stay', () async {
      final (reader, writer) = pipe<Message>();
      writer
        ..send(_assistant('a'))
        ..sendError(const FormatException('cut'));
      await writer.close();
      final variant = MessageVariant.stream(reader);
      await expectLater(variant.getMessage(), throwsFormatException);
      await expectLater(variant.getMessage(), throwsFormatException);
      expect((await variant.messageStream!.collectAll()).single.content, 'a');
    });

    test('an empty stream has no message', () async {
      final variant = MessageVariant.stream(StreamReader<Message>.fromIterable(const []));
      await expectLater(variant.getMessage(), throwsStateError);
    });

    test('a recorded stream can be written to JSON once the recorder has seen its end', () async {
      final recorder = StreamRecorder();
      final variant = recordedStreamVariant(
        StreamReader.fromIterable([_assistant('x')]),
        recorder,
        role: RoleType.tool,
        toolName: 't',
      );
      expect(variant.toJson, throwsStateError);
      recorder
        ..add(_assistant('x'))
        ..add(_assistant('y'))
        ..finish();
      final json = variant.toJson();
      expect((json['message']! as Map)['content'], 'xy');
      expect(json['tool_name'], 't');
    });
  });

  group('AgentEvent', () {
    test('fromMessage, failure and copyWith', () async {
      final event = AgentEvent.fromMessage(_assistant('a'), role: RoleType.assistant);
      expect(event.messageOutput!.isStreaming, isFalse);
      expect((await getMessageFromEvent(event))!.content, 'a');
      final named = event.copyWith(agentName: 'agent');
      expect(named.agentName, 'agent');
      expect(identical(named.output, event.output), isTrue);
      final failure = AgentEvent.failure(StateError('x'));
      expect(failure.error, isA<StateError>());
      expect(await getMessageFromEvent(failure), isNull);
    });

    test('getMessageFromEvent keeps every chunk readable', () async {
      final event = AgentEvent.fromMessage(
        null,
        stream: StreamReader.fromIterable([_assistant('a'), _assistant('b')]),
        role: RoleType.assistant,
      );
      expect((await getMessageFromEvent(event))!.content, 'ab');
      expect((await event.messageOutput!.messageStream!.collectAll()).length, 2);
    });

    test('copyAgentEvent copies streams', () async {
      final event = AgentEvent.fromMessage(
        null,
        stream: StreamReader.fromIterable([_assistant('a'), _assistant('b')]),
      );
      final copy = copyAgentEvent(event);
      expect((await copy.messageOutput!.getMessage()).content, 'ab');
      expect((await event.messageOutput!.getMessage()).content, 'ab');
    });

    test('JSON round trip of output, action and error', () {
      final event = AgentEvent(
        agentName: 'a',
        output: AgentOutput(
          messageOutput: MessageVariant.message(_assistant('hi'), role: RoleType.assistant),
          customizedOutput: {'k': 1},
        ),
        action: const AgentAction(customizedAction: 'go'),
        error: StateError('broken'),
      );
      final back = AgentEvent.fromJson(jsonDecode(jsonEncode(event.toJson())) as Map<String, Object?>);
      expect(back.agentName, 'a');
      expect(back.messageOutput!.message!.content, 'hi');
      expect(back.output!.customizedOutput, {'k': 1});
      expect(back.action!.customizedAction, 'go');
      expect(back.error, isA<ThreepioException>());
      expect('${back.error}', contains('broken'));
    });
  });

  group('AgentAction', () {
    test('an interrupt action keeps its signal; JSON keeps the report only', () {
      final event = interruptEvent(RunContext.background(), 'why');
      final action = event.action!;
      expect(action.interruptSignal, isNotNull);
      expect(action.interrupted!.interruptContexts.single.info, 'why');
      final back = AgentAction.fromJson(jsonDecode(jsonEncode(action.toJson())) as Map<String, Object?>);
      expect(back.interrupted!.interruptContexts.single.info, 'why');
      expect(back.interruptSignal, isNull);
    });

    test('withInterruptData keeps the signal; other actions refuse it', () {
      final action = interruptEvent(RunContext.background(), 'why').action!;
      final withData = action.withInterruptData({'k': 1});
      expect(withData.interrupted!.data, {'k': 1});
      expect(identical(withData.interruptSignal, action.interruptSignal), isTrue);
      expect(withData.interrupted!.interruptContexts, action.interrupted!.interruptContexts);
      expect(() => const AgentAction().withInterruptData(1), throwsStateError);
    });
  });

  group('interrupt events', () {
    test('populate their interrupt contexts at once (TestInterruptFunctionsPopulateInterruptContextsImmediately)', () {
      final ctx = RunContext.background().appendAddressSegment(addressSegmentAgent, 'a');
      final plain = interruptEvent(ctx, 'info');
      final stateful = statefulInterruptEvent(ctx, 'info', {'step': 1});
      for (final event in [plain, stateful]) {
        final context = event.action!.interrupted!.interruptContexts.single;
        expect(context.address.toString(), 'agent:a');
        expect(context.isRootCause, isTrue);
      }
      final sub = interrupt(ctx.appendAddressSegment(addressSegmentTool, 't'), 'inner');
      final composite = compositeInterruptEvent(ctx, 'outer', null, [sub]);
      final contexts = composite.action!.interrupted!.interruptContexts;
      expect(contexts.single.info, 'inner');
      expect(contexts.single.parent!.info, 'outer');
    });

    test('a composite of something that is no interrupt is an error event', () {
      final event = compositeInterruptEvent(
        RunContext.background(),
        'x',
        null,
        [_NotAnInterrupt()],
      );
      expect(event.error, isA<ArgumentError>());
      expect(event.action, isNull);
    });
  });

  group('AgentInterruptInfo and ChatModelAgentInterruptInfo', () {
    test('JSON round trips', () {
      ensureAdkTypesRegistered();
      final info = ChatModelAgentInterruptInfo(
        info: GraphInterruptInfo(interruptContexts: const []),
        data: Uint8List.fromList([1, 2, 3]),
      );
      final report = AgentInterruptInfo(data: info, interruptContexts: [
        InterruptCtx(id: 'i', address: const Address.empty(), info: 'x', isRootCause: true),
      ]);
      final back = AgentInterruptInfo.fromJson(
        jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>,
      );
      final data = back.data! as ChatModelAgentInterruptInfo;
      expect(data.data, [1, 2, 3]);
      expect(back.interruptContexts.single.id, 'i');
    });

    test('ResumeInfo and ResumeParams defaults', () {
      const info = ResumeInfo();
      expect(info.wasInterrupted, isFalse);
      expect(info.isResumeTarget, isFalse);
      expect(info.interruptState, isNull);
      expect(const ResumeParams().targets, isEmpty);
      expect(const ChatModelAgentResumeData().historyModifier, isNull);
    });
  });

  group('AgentRunOption', () {
    test('designateAgent appends names and keeps the payload', () {
      final option = AgentRunOption.checkpointId('x').designateAgent(['a']).designateAgent(['b']);
      expect(option.agentNames, ['a', 'b']);
      expect(CommonAgentOptions.of([option]).checkpointId, 'x');
    });

    test('filterOptions keeps what the agent may see', () {
      final all = AgentRunOption.sessionValues({'k': 1});
      final mine = AgentRunOption.checkpointId('mine').designateAgent(['me']);
      final theirs = AgentRunOption.checkpointId('theirs').designateAgent(['other']);
      expect(filterOptions('me', [all, mine, theirs]), [all, mine]);
    });

    test('common options: last session values win, callbacks add up', () {
      final h1 = CallbackHandlerBuilder().build();
      final h2 = CallbackHandlerBuilder().build();
      final common = CommonAgentOptions.of([
        AgentRunOption.sessionValues({'a': 1}),
        AgentRunOption.sessionValues({'b': 2}),
        AgentRunOption.callbacks([h1]),
        AgentRunOption.callbacks([h2]),
        sharedParentSessionOption(),
      ]);
      expect(common.sessionValues, {'b': 2});
      expect(common.handlers, [h1, h2]);
      expect(common.sharedParentSession, isTrue);
    });

    test('chat model agent options and custom values', () {
      Future<void> hook(RunContext ctx) async {}
      final options = [
        AgentRunOption.chatModelOptions(const ChatModelOptions(temperature: 1)),
        AgentRunOption.toolOptions(const ToolOptions(extensions: ['x'])),
        AgentRunOption.agentToolRunOptions({'t': [AgentRunOption.checkpointId('c')]}),
        AgentRunOption.afterToolCallsHook(hook),
        AgentRunOption.custom<_Custom>(const _Custom(1)),
        AgentRunOption.custom<_Custom>(const _Custom(2)),
      ];
      final parsed = ChatModelAgentRunOptions.of(options);
      expect(parsed.chatModelOptions!.temperature, 1);
      expect(parsed.toolOptions!.extensions, ['x']);
      expect(parsed.agentToolOptions.keys, ['t']);
      expect(parsed.afterToolCallsHook, same(hook));
      expect(AgentRunOption.customValues<_Custom>(options).map((c) => c.n), [1, 2]);
      expect(AgentRunOption.customValues<String>(options), isEmpty);
    });
  });

  group('AgentContext', () {
    test('outside a run: no session values, writes do nothing', () {
      final ctx = RunContext.background();
      ctx.addSessionValue('k', 1);
      expect(ctx.sessionValues, isEmpty);
      expect(ctx.sessionValue('k'), isNull);
      expect(ctx.hasSessionValue('k'), isFalse);
      expect(() => ctx.setRunLocalValue('k', 1), throwsStateError);
      expect(() => ctx.runLocalValue('k'), throwsStateError);
      expect(() => ctx.deleteRunLocalValue('k'), throwsStateError);
      expect(ctx.sendEvent(const AgentEvent()), throwsStateError);
      expect(
        sendToolGenAction(ctx, 't', const AgentAction()),
        throwsA(isA<StateError>()),
      );
    });

    test('session values are shared and copied out', () {
      final ctx = withNewAdkRunContext(RunContext.background(), AgentInput())
        ..addSessionValues({'a': 1});
      ctx.addSessionValue('b', null);
      final copy = ctx.sessionValues;
      copy['c'] = 3;
      expect(ctx.sessionValues, {'a': 1, 'b': null});
      expect(ctx.hasSessionValue('b'), isTrue);
      final nested = withNewAdkRunContext(ctx, AgentInput(), sharedParentSession: true);
      nested.addSessionValue('d', 4);
      expect(ctx.sessionValue('d'), 4);
      final separate = withNewAdkRunContext(ctx, AgentInput());
      expect(separate.sessionValues, isEmpty);
      expect(ctx.clearRunContext().sessionValues, isEmpty);
    });

    test('run-local values live in the agent state and must be encodable', () {
      final state = ReactState();
      final ctx = withInternalState(RunContext.background(), state);
      ctx.setRunLocalValue('n', 1);
      expect(ctx.runLocalValue('n'), 1);
      expect(state.extra, {'n': 1});
      ctx.deleteRunLocalValue('n');
      expect(ctx.runLocalValue('n'), isNull);
      expect(() => ctx.setRunLocalValue('bad', Object()), throwsArgumentError);
    });

    test('initAdkRunContext sets the root input for the first agent only', () {
      final input = AgentInput(messages: [Message.user('q')]);
      final (first, run) = initAdkRunContext(RunContext.background(), 'a', input);
      expect(run.isRoot, isTrue);
      expect(run.rootInput, same(input));
      final (_, nested) = initAdkRunContext(first, 'b', AgentInput());
      expect(nested.isRoot, isFalse);
      expect(nested.rootInput, same(input));
      expect(identical(nested.session, run.session), isTrue);
    });
  });

  group('checkpoint envelope', () {
    test('AdkCheckpoint round-trips through the JSON serializer', () {
      ensureAdkTypesRegistered();
      final checkpoint = AdkCheckpoint(
        sessionValues: {'user': 'Ada', 'n': 2},
        rootInput: AgentInput(messages: [Message.user('q')], enableStreaming: true),
        enableStreaming: true,
        interruptId2Address: {
          'i': Address(const [AddressSegment(type: addressSegmentAgent, id: 'a')]),
        },
        interruptId2State: {'i': const InterruptState(state: 'saved')},
      );
      const serializer = JsonCheckpointSerializer();
      final back = serializer.deserialize(serializer.serialize(checkpoint))! as AdkCheckpoint;
      expect(back.sessionValues, {'user': 'Ada', 'n': 2});
      expect(back.rootInput!.messages.single.content, 'q');
      expect(back.enableStreaming, isTrue);
      expect(back.interruptId2Address['i'].toString(), 'agent:a');
      expect(back.interruptId2State['i']!.state, 'saved');
      ensureAdkTypesRegistered();
    });

    test('BridgeStore keeps copies', () async {
      final data = Uint8List.fromList([1]);
      final store = BridgeStore.resume('k', data);
      data[0] = 9;
      expect(await store.get('k'), [1]);
      await store.set('k', Uint8List.fromList([2]));
      expect(await store.get('k'), [2]);
      expect(await BridgeStore().get('k'), isNull);
    });

    test('ReactState round-trips its fields', () {
      final state = ReactState(agentName: 'a', remainingIterations: 3)
        ..messages = [Message.user('q')]
        ..extra = {'k': 'v'}
        ..returnDirectlyToolCallId = 'c1'
        ..retryAttempt = 2
        ..setToolGenAction('c1', const AgentAction(customizedAction: 'x'))
        ..setToolMsgId('t', 'c1', 'id1');
      final back = ReactState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
      );
      expect(back.agentName, 'a');
      expect(back.remainingIterations, 3);
      expect(back.messages.single.content, 'q');
      expect(back.extra, {'k': 'v'});
      expect(back.hasReturnDirectly, isTrue);
      expect(back.retryAttempt, 2);
      expect(back.popToolGenAction('c1')!.customizedAction, 'x');
      expect(back.popToolMsgId('t', 'c1'), 'id1');
      expect(back.popToolMsgId('t', 'c1'), '');
      expect(back.toolMsgIds, isEmpty);
    });
  });

  group('language', () {
    tearDown(() => setAdkLanguage(AdkLanguage.english));

    test('selects the prompt of the language set', () {
      const prompts = I18nPrompts(english: 'hello', chinese: '你好');
      expect(adkLanguage, AdkLanguage.english);
      expect(selectPrompt(prompts), 'hello');
      setAdkLanguage(AdkLanguage.chinese);
      expect(selectPrompt(prompts), '你好');
    });
  });

  group('message ids', () {
    test('ensureMessageId copies, keeps an existing id, never mutates', () {
      final message = Message.user('q');
      expect(messageIdOf(message), isEmpty);
      final withId = ensureMessageId(message);
      expect(messageIdOf(withId), isNotEmpty);
      expect(message.extra, isNull);
      expect(identical(ensureMessageId(withId), withId), isTrue);
      expect(withId.extra!.keys, [einoMessageIdKey]);
      final other = withMessageId(withId, 'x');
      expect(messageIdOf(other), 'x');
      expect(messageIdOf(withId), isNot('x'));
    });
  });

  group('middleware context types', () {
    test('ChatModelAgentContext and ChatModelAgentState copy what they are given', () {
      final tools = <BaseTool>[];
      final returnDirectly = {'a'};
      final agent = ChatModelAgentContext(instruction: 'i', tools: tools, returnDirectly: returnDirectly);
      agent.returnDirectly.add('b');
      expect(returnDirectly, {'a'});
      final messages = [Message.user('q')];
      final state = ChatModelAgentState(messages: messages);
      state.messages.add(Message.user('x'));
      expect(messages, hasLength(1));
      expect(state.deferredToolInfos, isNull);
    });

    test('ToolContext equality', () {
      expect(const ToolContext(name: 'a', callId: '1'), const ToolContext(name: 'a', callId: '1'));
      expect(const ToolContext(name: 'a', callId: '1') == const ToolContext(name: 'a', callId: '2'), isFalse);
    });

    test('a middleware that overrides nothing changes nothing', () async {
      const middleware = _Nothing();
      final ctx = RunContext.background();
      final state = ChatModelAgentState(messages: const []);
      expect((await middleware.beforeModelRewriteState(ctx, state, const ModelContext())).$2, same(state));
      expect(await middleware.afterAgent(ctx, state), same(ctx));
      Future<String> next(RunContext c, String a, ToolOptions? o) async => a;
      expect(middleware.wrapInvokableToolCall(ctx, next, const ToolContext(name: 'n', callId: 'c')), same(next));
    });
  });

  group('errors', () {
    test('texts and causes', () {
      final exhausted = RetryExhaustedException(lastError: StateError('x'), totalRetries: 2);
      expect(exhausted.message, contains('exceeds max retries: last error: Bad state: x'));
      expect(exhausted.lastError, isA<StateError>());
      expect(exhausted.cause, isNull, reason: 'eino unwraps to ErrExceedMaxRetries, not the last error');
      expect(RetryExhaustedException(totalRetries: 0).message, 'exceeds max retries');
      final willRetry = WillRetryException(errorText: 'boom', retryAttempt: 1, rejectReason: 'r', cause: 'c');
      expect('$willRetry', 'boom');
      expect(willRetry.cause, 'c');
      expect(willRetry.rejectReason, 'r');
      expect(const ExceedMaxIterationsException().message, 'exceeds max iterations');
    });
  });

  group('agent callbacks', () {
    test('typed payloads and conversions', () async {
      final seen = <Object?>[];
      final handler = typedAgentCallbackHandler(
        onStart: (ctx, info, input) {
          seen.add(input);
          return ctx;
        },
        onEnd: (ctx, info, output) {
          seen.add(output);
          return ctx;
        },
      );
      const info = RunInfo(name: 'a', type: '', componentType: ComponentType.agent);
      final helper = HandlerHelper().agent(handler).handler();
      final ctx = RunContext.background();
      final input = AgentCallbackInput(input: AgentInput());
      await helper.onStart(ctx, info, input);
      await helper.onStart(ctx, info, 'not a report');
      final output = AgentCallbackOutput(StreamReader<AgentEvent>.fromIterable(const []));
      await helper.onEnd(ctx, info, output);
      expect(seen, [same(input), null, same(output)]);
      expect(AgentCallbackInput.from(1), isNull);
      expect(AgentCallbackOutput.from(output), same(output));
    });

    test('copyEventStream gives every reader every event', () async {
      final copies = copyEventStream(
        StreamReader.fromIterable([const AgentEvent(agentName: 'a'), const AgentEvent(agentName: 'b')]),
        3,
      );
      for (final copy in copies) {
        expect((await copy.collectAll()).map((e) => e.agentName), ['a', 'b']);
      }
      expect(copyEventStream(StreamReader<AgentEvent>.fromIterable(const []), 0), isEmpty);
    });
  });
}

final class _Custom {
  const _Custom(this.n);

  final int n;
}

final class _Nothing extends ChatModelAgentMiddleware {
  const _Nothing();
}

final class _NotAnInterrupt implements InterruptSignal {}
