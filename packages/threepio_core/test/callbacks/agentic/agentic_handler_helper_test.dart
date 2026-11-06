// Port of the agentic cases of eino `utils/callbacks/template_test.go`
// (v0.9.22): the agentic handlers of TestNewComponentTemplate (its first
// count, the agentic stream checks and the "EdgeCases" subtest's conversion
// fallbacks and `Needed` checks), TestAgenticAgentCallbackHandler (3
// subtests), TestHandlerHelperWithAgenticAgent and
// TestHandlerTemplateWithAgenticAgentComponent (3 subtests). The classic
// cases are in `test/callbacks/eino_handler_helper_test.dart`.
//
// One deliberate difference: Go's `AgenticPromptCallbackHandler` hooks take
// the classic prompt payloads, which an agentic template never reports; here
// they take `AgenticPromptCallbackInput`/`Output` (see the handler's
// dartdoc). The group `AgenticPromptCallbackHandler: beyond Go` pins that.
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/streaming.dart';

RunInfo _of(ComponentType type, {String name = ''}) =>
    RunInfo(name: name, type: '', componentType: type);

StreamReader<Object?> _closedStream() {
  final (reader, writer) = pipe<Object?>(capacity: 1);
  writer.close();
  return reader;
}

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  group('TestNewComponentTemplate (agentic handlers)', () {
    test('every agentic hook is called for its own component', () async {
      var count = 0;
      RunContext counted(RunContext ctx) {
        count++;
        return ctx;
      }

      final helper = HandlerHelper()
          .agenticModel(
            AgenticModelCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onEndWithStreamOutput: (ctx, info, output) async {
                await output.close();
                return counted(ctx);
              },
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .agenticPrompt(
            AgenticPromptCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .agenticToolsNode(
            AgenticToolsNodeCallbackHandlers(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onEndWithStreamOutput: (ctx, info, output) async {
                await output.close();
                return counted(ctx);
              },
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          );

      const types = [
        ComponentType.agenticModel,
        ComponentType.agenticChatTemplate,
        ComponentType.agenticToolsNode,
      ];

      final handler = helper.handler();
      final ctx = RunContext.background();
      for (final type in types) {
        await handler.onStart(ctx, _of(type), null);
        await handler.onEnd(ctx, _of(type), null);
        await handler.onError(
          ctx,
          _of(type),
          Exception('mock err'),
          StackTrace.empty,
        );
        await handler.onStartWithStreamInput(ctx, _of(type), _closedStream());
        await handler.onEndWithStreamOutput(ctx, _of(type), _closedStream());
      }
      // agentic model 4, agentic prompt 3, agentic tools node 4 (Go counts
      // these 11 together with the 22 of the classic handlers: 33).
      expect(count, 11);

      // "Check AgenticModel stream" and "Check AgenticToolsNode stream".
      await handler.onEndWithStreamOutput(
        ctx,
        _of(ComponentType.agenticModel),
        _closedStream(),
      );
      expect(count, 12);
      await handler.onEndWithStreamOutput(
        ctx,
        _of(ComponentType.agenticToolsNode),
        _closedStream(),
      );
      expect(count, 13);
    });

    test('EdgeCases: conversion fallbacks of the agentic tools node', () async {
      var count = 0;
      final helper = HandlerHelper().agenticToolsNode(
        AgenticToolsNodeCallbackHandlers(
          onStart: (ctx, info, input) {
            if (input == null) count++;
            return ctx;
          },
          onEnd: (ctx, info, output) {
            if (output == null) count++;
            return ctx;
          },
        ),
      );
      final handler = helper.handler();
      final ctx = RunContext.background();

      await handler.onStart(
        ctx,
        _of(ComponentType.agenticToolsNode),
        'wrong-input-type',
      );
      expect(count, 1);
      await handler.onEnd(
        ctx,
        _of(ComponentType.agenticToolsNode),
        'wrong-output-type',
      );
      expect(count, 2);
    });

    test('EdgeCases: Needed for agentic components', () {
      final helper = HandlerHelper().agenticToolsNode(
        AgenticToolsNodeCallbackHandlers(onStart: (ctx, info, input) => ctx),
      );
      final checker = helper.handler() as TimingChecker;
      final ctx = RunContext.background();

      expect(
        checker.needed(
          ctx,
          _of(ComponentType.agenticToolsNode),
          CallbackTiming.onStart,
        ),
        isTrue,
      );
      expect(
        checker.needed(
          ctx,
          _of(ComponentType.agenticModel),
          CallbackTiming.onStart,
        ),
        isFalse,
      );

      // Set it now: the handler is a live view of its helper.
      helper.agenticModel(
        AgenticModelCallbackHandler(onStart: (ctx, info, input) => ctx),
      );
      expect(
        checker.needed(
          ctx,
          _of(ComponentType.agenticModel),
          CallbackTiming.onStart,
        ),
        isTrue,
      );

      final prompt = HandlerHelper()
          .agenticPrompt(
            AgenticPromptCallbackHandler(onStart: (ctx, info, input) => ctx),
          )
          .handler() as TimingChecker;
      expect(
        prompt.needed(
          ctx,
          _of(ComponentType.agenticChatTemplate),
          CallbackTiming.onStart,
        ),
        isTrue,
      );
    });
  });

  group('TestAgenticAgentCallbackHandler', () {
    test('Needed returns correct values', () {
      final handler = AgenticAgentCallbackHandler(
        onStart: (ctx, info, input) => ctx,
      );
      expect(handler.needed(CallbackTiming.onStart), isTrue);
      expect(handler.needed(CallbackTiming.onEnd), isFalse);
    });

    test('Needed with OnEnd set', () {
      final handler = AgenticAgentCallbackHandler(
        onEnd: (ctx, info, output) => ctx,
      );
      expect(handler.needed(CallbackTiming.onStart), isFalse);
      expect(handler.needed(CallbackTiming.onEnd), isTrue);
    });

    test('Needed with nil handlers', () {
      const handler = AgenticAgentCallbackHandler();
      expect(handler.needed(CallbackTiming.onStart), isFalse);
      expect(handler.needed(CallbackTiming.onEnd), isFalse);
      expect(handler.needed(CallbackTiming.onError), isFalse);
    });
  });

  test('TestHandlerHelperWithAgenticAgent', () async {
    var count = 0;
    final helper = HandlerHelper().agenticAgent(
      AgenticAgentCallbackHandler(
        onStart: (ctx, info, input) {
          count++;
          return ctx;
        },
        onEnd: (ctx, info, output) {
          count++;
          return ctx;
        },
      ),
    );

    var ctx = initCallbacks(
      RunContext.background(),
      _of(ComponentType.agenticAgent),
      [helper.handler()],
    );
    ctx = await onStart(ctx, null);
    expect(count, 1);
    await onEnd(ctx, null);
    expect(count, 2);
  });

  group('TestHandlerTemplateWithAgenticAgentComponent', () {
    test('OnStart routes to agentic agent handler', () async {
      Object? seen;
      final handler = HandlerHelper()
          .agenticAgent(
            AgenticAgentCallbackHandler(
              onStart: (ctx, info, input) {
                seen = input;
                return ctx;
              },
            ),
          )
          .handler();
      final input = Object();
      await handler.onStart(
        RunContext.background(),
        _of(ComponentType.agenticAgent, name: 'TestAgenticAgent'),
        input,
      );
      expect(seen, same(input));
    });

    test('OnEnd routes to agentic agent handler', () async {
      Object? seen;
      final handler = HandlerHelper()
          .agenticAgent(
            AgenticAgentCallbackHandler(
              onEnd: (ctx, info, output) {
                seen = output;
                return ctx;
              },
            ),
          )
          .handler();
      final output = Object();
      await handler.onEnd(
        RunContext.background(),
        _of(ComponentType.agenticAgent, name: 'TestAgenticAgent'),
        output,
      );
      expect(seen, same(output));
    });

    test('Needed returns true for agentic agent component', () {
      final handler = HandlerHelper()
          .agenticAgent(
            AgenticAgentCallbackHandler(onStart: (ctx, info, input) => ctx),
          )
          .handler();
      expect(handler, isA<TimingChecker>());
      expect(
        (handler as TimingChecker).needed(
          RunContext.background(),
          _of(ComponentType.agenticAgent),
          CallbackTiming.onStart,
        ),
        isTrue,
      );
    });
  });

  group('agentic handlers: beyond Go', () {
    test('the agentic model hooks get typed payloads', () async {
      AgenticModelCallbackInput? start;
      AgenticModelCallbackOutput? end;
      final handler = HandlerHelper()
          .agenticModel(
            AgenticModelCallbackHandler(
              onStart: (ctx, info, input) {
                start = input;
                return ctx;
              },
              onEnd: (ctx, info, output) {
                end = output;
                return ctx;
              },
            ),
          )
          .handler();
      final ctx = RunContext.background();
      final info = _of(ComponentType.agenticModel);
      final messages = [AgenticMessage.user('hi')];
      // What a graph node reports: the plain input and output.
      await handler.onStart(ctx, info, messages);
      final answer = AgenticMessage(role: AgenticRoleType.assistant);
      await handler.onEnd(ctx, info, answer);
      expect(start!.messages, same(messages));
      expect(end!.message, same(answer));
    });

    test('the agentic model stream hook gets typed chunks', () async {
      final chunks = <AgenticModelCallbackOutput?>[];
      final handler = HandlerHelper()
          .agenticModel(
            AgenticModelCallbackHandler(
              onEndWithStreamOutput: (ctx, info, output) async {
                chunks.addAll(await output.collectAll());
                await output.close();
                return ctx;
              },
            ),
          )
          .handler();
      final answer = AgenticMessage(role: AgenticRoleType.assistant);
      await handler.onEndWithStreamOutput(
        RunContext.background(),
        _of(ComponentType.agenticModel),
        StreamReader<Object?>.fromIterable([answer, 'not an output']),
      );
      expect(chunks, hasLength(2));
      expect(chunks[0]!.message, same(answer));
      expect(chunks[1], isNull);
    });

    test('the agentic tools node hooks get typed payloads', () async {
      AgenticMessage? start;
      List<AgenticMessage>? end;
      final streamed = <List<AgenticMessage>?>[];
      final handler = HandlerHelper()
          .agenticToolsNode(
            AgenticToolsNodeCallbackHandlers(
              onStart: (ctx, info, input) {
                start = input;
                return ctx;
              },
              onEnd: (ctx, info, output) {
                end = output;
                return ctx;
              },
              onEndWithStreamOutput: (ctx, info, output) async {
                streamed.addAll(await output.collectAll());
                await output.close();
                return ctx;
              },
            ),
          )
          .handler();
      final ctx = RunContext.background();
      final info = _of(ComponentType.agenticToolsNode);
      final call = AgenticMessage(role: AgenticRoleType.assistant);
      final results = [AgenticMessage.user('r')];
      await handler.onStart(ctx, info, call);
      await handler.onEnd(ctx, info, results);
      await handler.onEndWithStreamOutput(
        ctx,
        info,
        StreamReader<Object?>.fromIterable([
          results,
          <Object?>[AgenticMessage.user('loose')],
          <Object?>[1],
        ]),
      );
      expect(start, same(call));
      expect(end, same(results));
      expect(streamed, hasLength(3));
      expect(streamed[0], same(results));
      expect(streamed[1], hasLength(1));
      expect(streamed[2], isNull);
    });

    test('an agentic handler leaves the classic components alone', () async {
      var count = 0;
      final handler = HandlerHelper()
          .agenticModel(
            AgenticModelCallbackHandler(
              onStart: (ctx, info, input) {
                count++;
                return ctx;
              },
            ),
          )
          .handler();
      final checker = handler as TimingChecker;
      final ctx = RunContext.background();
      await handler.onStart(ctx, _of(ComponentType.chatModel), null);
      expect(count, 0);
      expect(
        checker.needed(ctx, _of(ComponentType.chatModel), CallbackTiming.onStart),
        isFalse,
      );
    });
  });

  group('AgenticPromptCallbackHandler: beyond Go', () {
    test('the hooks get what an agentic template reports', () async {
      AgenticPromptCallbackInput? start;
      AgenticPromptCallbackOutput? end;
      final helper = HandlerHelper().agenticPrompt(
        AgenticPromptCallbackHandler(
          onStart: (ctx, info, input) {
            start = input;
            return ctx;
          },
          onEnd: (ctx, info, output) {
            end = output;
            return ctx;
          },
        ),
      );
      final template = AgenticChatTemplate.fromAgenticMessages(
        FormatType.fString,
        [AgenticMessage.user('hello {who}')],
      );
      await template.format(
        RunContext.background().withHandlers([helper.handler()]),
        {'who': 'world'},
      );
      expect(start!.variables, {'who': 'world'});
      expect(start!.templates, hasLength(1));
      expect(
        end!.result.single.contentBlocks.single.userInputText!.text,
        'hello world',
      );
    });

    test('the plain payloads of a graph node are read too', () async {
      AgenticPromptCallbackInput? start;
      AgenticPromptCallbackOutput? end;
      final handler = HandlerHelper()
          .agenticPrompt(
            AgenticPromptCallbackHandler(
              onStart: (ctx, info, input) {
                start = input;
                return ctx;
              },
              onEnd: (ctx, info, output) {
                end = output;
                return ctx;
              },
            ),
          )
          .handler();
      final ctx = RunContext.background();
      final info = _of(ComponentType.agenticChatTemplate);
      await handler.onStart(ctx, info, <String, Object?>{'a': 1});
      await handler.onEnd(ctx, info, [AgenticMessage.user('x')]);
      expect(start!.variables, {'a': 1});
      expect(end!.result, hasLength(1));
    });
  });
}
