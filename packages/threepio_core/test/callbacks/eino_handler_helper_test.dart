// Port of eino `utils/callbacks/template_test.go` (v0.9.22):
// TestNewComponentTemplate, TestAgentCallbackHandler,
// TestHandlerHelperWithAgent and TestHandlerTemplateWithAgentComponent. The
// agentic components are not part of this port, and the payload types of an
// agent come with the ADK.
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/streaming.dart';

import '../support/log_capture.dart';

RunInfo _of(ComponentType type) =>
    RunInfo(name: '', type: '', componentType: type);

(StreamReader<Object?>, StreamWriter<Object?>) _closedPipe() {
  final (reader, writer) = pipe<Object?>(capacity: 1);
  writer.close();
  return (reader, writer);
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('TestNewComponentTemplate', () {
    test('TestNewComponentTemplate', () async {
      var count = 0;
      RunContext counted(RunContext ctx) {
        count++;
        return ctx;
      }

      final helper = HandlerHelper()
          .chatModel(
            ModelCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onEndWithStreamOutput: (ctx, info, output) async {
                await output.close();
                return counted(ctx);
              },
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .embedding(
            EmbeddingCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .prompt(
            PromptCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .retriever(
            RetrieverCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .tool(
            ToolCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onEndWithStreamOutput: (ctx, info, output) async {
                await output.close();
                return counted(ctx);
              },
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .lambda(
            CallbackHandlerBuilder()
                .onStart((ctx, info, input) => counted(ctx))
                .onStartWithStreamInput((ctx, info, input) async {
                  await input.close();
                  return counted(ctx);
                })
                .onEnd((ctx, info, output) => counted(ctx))
                .onEndWithStreamOutput((ctx, info, output) async {
                  await output.close();
                  return counted(ctx);
                })
                .onError((ctx, info, error, stackTrace) => counted(ctx))
                .build(),
          );

      const types = [
        ComponentType.promptTemplate,
        ComponentType.chatModel,
        ComponentType.embedder,
        ComponentType.retriever,
        ComponentType.tool,
        ComponentType.lambda,
      ];

      var handler = helper.handler();
      var ctx = RunContext.background();
      for (final type in types) {
        await handler.onStart(ctx, _of(type), null);
        await handler.onEnd(ctx, _of(type), null);
        await handler.onError(ctx, _of(type), Exception('mock err'), StackTrace.empty);
        await handler.onStartWithStreamInput(ctx, _of(type), _closedPipe().$1);
        await handler.onEndWithStreamOutput(ctx, _of(type), _closedPipe().$1);
      }
      // prompt 3, chat model 4, embedding 3, retriever 3, tool 4, lambda 5
      expect(count, 22);

      ctx = initCallbacks(
        RunContext.background(),
        _of(ComponentType.documentTransformer),
        [handler],
      );
      await onStart(ctx, null);
      expect(count, 22);

      ctx = reuseHandlers(ctx, _of(ComponentType.promptTemplate));
      ctx = await onStart(ctx, null);
      expect(count, 23);

      ctx = reuseHandlers(ctx, _of(ComponentType.indexer));
      await onEnd(ctx, null);
      expect(count, 23);

      ctx = reuseHandlers(ctx, _of(ComponentType.embedder));
      await onError(ctx, Exception('x'), StackTrace.empty);
      expect(count, 24);

      ctx = reuseHandlers(ctx, _of(ComponentType.loader));
      await onStart(ctx, null);
      expect(count, 24);

      helper
          .transformer(
            TransformerCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .indexer(
            IndexerCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .loader(
            LoaderCallbackHandler(
              onStart: (ctx, info, input) => counted(ctx),
              onEnd: (ctx, info, output) => counted(ctx),
              onError: (ctx, info, error, stackTrace) => counted(ctx),
            ),
          )
          .toolsNode(
            ToolsNodeCallbackHandlers(
              onStart: (ctx, info, input) => counted(ctx),
              onEndWithStreamOutput: (ctx, info, output) async {
                count++;
                await output.collectAll();
                await output.close();
                return ctx;
              },
            ),
          );

      handler = helper.handler();
      ctx = initCallbacks(
        RunContext.background(),
        _of(ComponentType.documentTransformer),
        [handler],
      );

      ctx = await onStart(ctx, null);
      expect(count, 25);

      await onEnd(ctx, null);
      expect(count, 26);

      ctx = reuseHandlers(ctx, _of(ComponentType.loader));
      await onEnd(ctx, null);
      expect(count, 27);

      ctx = reuseHandlers(ctx, _of(ComponentType.toolsNode));
      await onStart(ctx, null);
      expect(count, 28);

      final (untyped, _) = _closedPipe();
      final (_, rest) = await onEndWithStreamOutput<Object?>(ctx, untyped);
      await rest.close();
      expect(count, 29);

      final (typed, typedWriter) = pipe<List<Message>>(capacity: 1);
      typedWriter.send([Message.tool(content: 'x', toolCallId: 'c')]);
      await typedWriter.close();
      final (_, typedRest) = await onEndWithStreamOutput(ctx, typed);
      await typedRest.close();
      expect(count, 30);

      ctx = reuseHandlers(ctx, null);
      await onStart(ctx, null);
      expect(count, 30);
    });

    test('EdgeCases', () async {
      final ctx = RunContext.background();
      var count = 0;

      // 1. Graph and chain setters and execution
      final helper = HandlerHelper()
          .graph(
            CallbackHandlerBuilder().onStart((ctx, info, input) {
              count++;
              return ctx;
            }).build(),
          )
          .chain(
            CallbackHandlerBuilder().onEnd((ctx, info, output) {
              count++;
              return ctx;
            }).build(),
          );
      final handler = helper.handler();

      await handler.onStart(ctx, _of(ComponentType.graph), null);
      expect(count, 1);
      await handler.onEnd(ctx, _of(ComponentType.chain), null);
      expect(count, 2);

      // 2. needed for graph and chain, present and absent
      final checker = handler as TimingChecker;
      expect(
        checker.needed(ctx, _of(ComponentType.graph), CallbackTiming.onStart),
        isTrue,
      );
      expect(
        checker.needed(ctx, _of(ComponentType.chain), CallbackTiming.onStart),
        isFalse,
        reason: 'the chain handler only has an end function',
      );
      expect(
        checker.needed(ctx, _of(ComponentType.lambda), CallbackTiming.onStart),
        isFalse,
      );

      // 3. Conversion fallbacks: a payload of the wrong type arrives as null
      final helper2 = HandlerHelper().toolsNode(
        ToolsNodeCallbackHandlers(
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
      final handler2 = helper2.handler();

      await handler2.onStart(ctx, _of(ComponentType.toolsNode), 'wrong-input-type');
      expect(count, 3);
      await handler2.onEnd(ctx, _of(ComponentType.toolsNode), 'wrong-output-type');
      expect(count, 4);

      // 4. needed for handlers that are set, unset, and set later
      final checker2 = handler2 as TimingChecker;
      expect(
        checker2.needed(ctx, _of(ComponentType.toolsNode), CallbackTiming.onStart),
        isTrue,
      );
      expect(
        checker2.needed(ctx, _of(ComponentType.chatModel), CallbackTiming.onStart),
        isFalse,
      );
      helper2.chatModel(
        ModelCallbackHandler(onStart: (ctx, info, input) => ctx),
      );
      expect(
        checker2.needed(ctx, _of(ComponentType.chatModel), CallbackTiming.onStart),
        isTrue,
        reason: 'the handler is a live view of its helper',
      );
      expect(
        checker2.needed(ctx, _of(ComponentType.custom), CallbackTiming.onStart),
        isFalse,
      );
      expect(
        checker2.needed(ctx, RunInfo.unknown, CallbackTiming.onStart),
        isFalse,
      );

      // 5. needed for transformer, loader, indexer, retriever, embedding, tool
      const kinds = [
        ComponentType.documentTransformer,
        ComponentType.loader,
        ComponentType.indexer,
        ComponentType.retriever,
        ComponentType.embedder,
        ComponentType.tool,
      ];
      final checker3 = HandlerHelper()
          .transformer(
            TransformerCallbackHandler(onStart: (ctx, info, input) => ctx),
          )
          .loader(LoaderCallbackHandler(onStart: (ctx, info, input) => ctx))
          .indexer(IndexerCallbackHandler(onStart: (ctx, info, input) => ctx))
          .retriever(
            RetrieverCallbackHandler(onStart: (ctx, info, input) => ctx),
          )
          .embedding(
            EmbeddingCallbackHandler(onStart: (ctx, info, input) => ctx),
          )
          .tool(ToolCallbackHandler(onStart: (ctx, info, input) => ctx))
          .handler() as TimingChecker;
      final empty = HandlerHelper().handler() as TimingChecker;
      for (final kind in kinds) {
        expect(checker3.needed(ctx, _of(kind), CallbackTiming.onStart), isTrue);
        expect(checker3.needed(ctx, _of(kind), CallbackTiming.onEnd), isFalse);
        expect(empty.needed(ctx, _of(kind), CallbackTiming.onStart), isFalse);
      }

      // 6. needed for chat model and prompt
      final checker4 = HandlerHelper()
          .chatModel(ModelCallbackHandler(onStart: (ctx, info, input) => ctx))
          .prompt(PromptCallbackHandler(onStart: (ctx, info, input) => ctx))
          .handler() as TimingChecker;
      expect(
        checker4.needed(ctx, _of(ComponentType.chatModel), CallbackTiming.onStart),
        isTrue,
      );
      expect(
        checker4.needed(
          ctx,
          _of(ComponentType.promptTemplate),
          CallbackTiming.onStart,
        ),
        isTrue,
      );
    });
  });

  group('TestAgentCallbackHandler', () {
    test('needed returns correct values', () {
      final handler = AgentCallbackHandler(onStart: (ctx, info, input) => ctx);
      expect(handler.needed(CallbackTiming.onStart), isTrue);
      expect(handler.needed(CallbackTiming.onEnd), isFalse);
    });

    test('needed with onEnd set', () {
      final handler = AgentCallbackHandler(onEnd: (ctx, info, output) => ctx);
      expect(handler.needed(CallbackTiming.onStart), isFalse);
      expect(handler.needed(CallbackTiming.onEnd), isTrue);
    });

    test('needed with no functions', () {
      const handler = AgentCallbackHandler();
      for (final timing in CallbackTiming.values) {
        expect(handler.needed(timing), isFalse);
      }
    });

    test('the helper passes what the agent reports on as it is', () async {
      final seen = <Object?>[];
      final handler = HandlerHelper()
          .agent(
            AgentCallbackHandler(
              onStart: (ctx, info, input) {
                seen.add(input);
                return ctx;
              },
              onEnd: (ctx, info, output) {
                seen.add(output);
                return ctx;
              },
            ),
          )
          .handler();
      final ctx = RunContext.background();

      await handler.onStart(ctx, _of(ComponentType.agent), 'input');
      await handler.onEnd(ctx, _of(ComponentType.agent), 42);
      expect(
        await handler.onError(ctx, _of(ComponentType.agent), 'e', StackTrace.empty),
        same(ctx),
        reason: 'an agent handler has no error function',
      );
      expect(seen, ['input', 42]);
      expect(
        (handler as TimingChecker)
            .needed(ctx, _of(ComponentType.agent), CallbackTiming.onError),
        isFalse,
      );
    });
  });

  // The payload types of an agent (`adk.AgentCallbackInput` and `Output`)
  // come with the ADK; until then the payload is passed on as it is.
  test('TestHandlerHelperWithAgent: the agent handler is called in a run',
      () async {
    var count = 0;
    final handler = HandlerHelper()
        .agent(
          AgentCallbackHandler(
            onStart: (ctx, info, input) {
              count++;
              return ctx;
            },
            onEnd: (ctx, info, output) {
              count++;
              return ctx;
            },
          ),
        )
        .handler();

    var ctx = initCallbacks(
      RunContext.background(),
      _of(ComponentType.agent),
      [handler],
    );
    ctx = await onStart(ctx, null);
    expect(count, 1);
    await onEnd(ctx, null);
    expect(count, 2);
  });

  group('TestHandlerTemplateWithAgentComponent', () {
    const info = RunInfo(
      name: 'TestAgent',
      type: '',
      componentType: ComponentType.agent,
    );
    final ctx = RunContext.background();

    test('onStart routes to the agent handler', () async {
      var called = false;
      final handler = HandlerHelper()
          .agent(
            AgentCallbackHandler(
              onStart: (ctx, info, input) {
                called = true;
                return ctx;
              },
            ),
          )
          .handler();

      await handler.onStart(ctx, info, 'agent input');
      expect(called, isTrue);
      expect(await handler.onEnd(ctx, info, 'no end function'), same(ctx));
    });

    test('onEnd routes to the agent handler', () async {
      var called = false;
      final handler = HandlerHelper()
          .agent(
            AgentCallbackHandler(
              onEnd: (ctx, info, output) {
                called = true;
                return ctx;
              },
            ),
          )
          .handler();

      await handler.onEnd(ctx, info, 'agent output');
      expect(called, isTrue);
    });

    test('needed returns true for the agent component', () {
      final handler = HandlerHelper()
          .agent(AgentCallbackHandler(onStart: (ctx, info, input) => ctx))
          .handler();

      expect(handler, isA<TimingChecker>());
      expect(
        (handler as TimingChecker)
            .needed(ctx, _of(ComponentType.agent), CallbackTiming.onStart),
        isTrue,
      );
      expect(
        (handler as TimingChecker)
            .needed(ctx, _of(ComponentType.agent), CallbackTiming.onEnd),
        isFalse,
      );
    });
  });

  group('typed payloads', () {
    final ctx = RunContext.background();

    test('a chat model handler gets the payload a model reports', () async {
      ModelCallbackInput? input;
      ModelCallbackOutput? output;
      final handler = HandlerHelper()
          .chatModel(
            ModelCallbackHandler(
              onStart: (ctx, info, payload) {
                input = payload;
                return ctx;
              },
              onEnd: (ctx, info, payload) {
                output = payload;
                return ctx;
              },
            ),
          )
          .handler();
      final reported = ModelCallbackInput(
        messages: [Message.user('hi')],
        config: const ModelCallbackConfig(model: 'm'),
      );

      await handler.onStart(ctx, _of(ComponentType.chatModel), reported);
      expect(input, same(reported));

      // What a graph reports for a node: the plain input and output.
      await handler.onStart(ctx, _of(ComponentType.chatModel), [Message.user('a')]);
      expect(input!.messages.single.content, 'a');
      await handler.onEnd(ctx, _of(ComponentType.chatModel), Message.assistant('b'));
      expect(output!.message!.content, 'b');

      await handler.onEnd(ctx, _of(ComponentType.chatModel), 17);
      expect(output, isNull);
    });

    test('a chat model stream is converted chunk by chunk', () async {
      final chunks = <String?>[];
      final handler = HandlerHelper()
          .chatModel(
            ModelCallbackHandler(
              onEndWithStreamOutput: (ctx, info, output) async {
                for (final chunk in await output.collectAll()) {
                  chunks.add(chunk?.message?.content);
                }
                await output.close();
                return ctx;
              },
            ),
          )
          .handler();

      await handler.onEndWithStreamOutput(
        ctx,
        _of(ComponentType.chatModel),
        StreamReader<Object?>.fromIterable([
          Message.assistant('a'),
          ModelCallbackOutput(message: Message.assistant('b')),
          'not a chunk',
        ]),
      );
      expect(chunks, ['a', 'b', null]);
    });

    test('the stream of a typed hook that throws is closed for it', () async {
      final handler = HandlerHelper()
          .chatModel(
            ModelCallbackHandler(
              onEndWithStreamOutput: (ctx, info, output) =>
                  throw StateError('hook bug'),
            ),
          )
          .handler();
      final (source, writer) = pipe<Object?>();

      // Called directly, the error comes out; in a run the chain logs it.
      await expectLater(
        Future.sync(
          () => handler.onEndWithStreamOutput(
            ctx,
            _of(ComponentType.chatModel),
            source,
          ),
        ),
        throwsStateError,
      );
      expect(writer.send(1), isTrue, reason: 'nothing holds the stream open');
    });

    test('a stream nobody has a function for is closed', () async {
      final handler = HandlerHelper()
          .chatModel(ModelCallbackHandler(onEnd: (ctx, info, output) => ctx))
          .handler();

      for (final type in [ComponentType.chatModel, ComponentType.retriever]) {
        final (output, writer) = pipe<Object?>();
        expect(
          await handler.onEndWithStreamOutput(ctx, _of(type), output),
          same(ctx),
        );
        expect(writer.send(1), isTrue, reason: '$type: the copy was closed');

        final (input, inputWriter) = pipe<Object?>();
        expect(
          await handler.onStartWithStreamInput(ctx, _of(type), input),
          same(ctx),
        );
        expect(inputWriter.send(1), isTrue);
      }
    });

    test('tool, retriever, embedding, prompt, indexer and document payloads',
        () async {
      final seen = <String, Object?>{};
      TypedCallbackHook<T> record<T>(String key) => (ctx, info, payload) {
            seen[key] = payload;
            return ctx;
          };
      final handler = HandlerHelper()
          .tool(
            ToolCallbackHandler(
              onStart: record('tool.in'),
              onEnd: record('tool.out'),
            ),
          )
          .retriever(
            RetrieverCallbackHandler(
              onStart: record('retriever.in'),
              onEnd: record('retriever.out'),
            ),
          )
          .embedding(
            EmbeddingCallbackHandler(
              onStart: record('embedding.in'),
              onEnd: record('embedding.out'),
            ),
          )
          .prompt(
            PromptCallbackHandler(
              onStart: record('prompt.in'),
              onEnd: record('prompt.out'),
            ),
          )
          .indexer(
            IndexerCallbackHandler(
              onStart: record('indexer.in'),
              onEnd: record('indexer.out'),
            ),
          )
          .transformer(
            TransformerCallbackHandler(
              onStart: record('transformer.in'),
              onEnd: record('transformer.out'),
            ),
          )
          .handler();
      const doc = Document(id: 'd', content: 'text');

      await handler.onStart(ctx, _of(ComponentType.tool), '{"q":1}');
      await handler.onEnd(ctx, _of(ComponentType.tool), 'result');
      await handler.onStart(ctx, _of(ComponentType.retriever), 'query');
      await handler.onEnd(ctx, _of(ComponentType.retriever), [doc]);
      await handler.onStart(ctx, _of(ComponentType.embedder), ['a', 'b']);
      await handler.onEnd(ctx, _of(ComponentType.embedder), [
        [0.5, 1.0],
      ]);
      await handler.onStart(ctx, _of(ComponentType.promptTemplate), {'k': 'v'});
      await handler.onEnd(ctx, _of(ComponentType.promptTemplate), [Message.user('m')]);
      await handler.onStart(ctx, _of(ComponentType.indexer), [doc]);
      await handler.onEnd(ctx, _of(ComponentType.indexer), ['id-1']);
      await handler.onStart(ctx, _of(ComponentType.documentTransformer), [doc]);
      await handler.onEnd(ctx, _of(ComponentType.documentTransformer), [doc]);

      expect((seen['tool.in']! as ToolCallbackInput).argumentsJson, '{"q":1}');
      expect((seen['tool.out']! as ToolCallbackOutput).response, 'result');
      expect((seen['retriever.in']! as RetrieverCallbackInput).query, 'query');
      expect((seen['retriever.out']! as RetrieverCallbackOutput).docs, [doc]);
      expect((seen['embedding.in']! as EmbeddingCallbackInput).texts, ['a', 'b']);
      expect(
        (seen['embedding.out']! as EmbeddingCallbackOutput).embeddings.single,
        [0.5, 1.0],
      );
      expect((seen['prompt.in']! as PromptCallbackInput).variables, {'k': 'v'});
      expect(
        (seen['prompt.out']! as PromptCallbackOutput).result.single.content,
        'm',
      );
      expect((seen['indexer.in']! as IndexerCallbackInput).docs, [doc]);
      expect((seen['indexer.out']! as IndexerCallbackOutput).ids, ['id-1']);
      expect((seen['transformer.in']! as TransformerCallbackInput).input, [doc]);
      expect(
        (seen['transformer.out']! as TransformerCallbackOutput).output,
        [doc],
      );
    });

    test('a tools node reports a message in and a list of messages out',
        () async {
      Message? input;
      final outputs = <List<Message?>?>[];
      final handler = HandlerHelper()
          .toolsNode(
            ToolsNodeCallbackHandlers(
              onStart: (ctx, info, payload) {
                input = payload;
                return ctx;
              },
              onEnd: (ctx, info, payload) {
                outputs.add(payload);
                return ctx;
              },
              onEndWithStreamOutput: (ctx, info, stream) async {
                outputs.addAll(await stream.collectAll());
                await stream.close();
                return ctx;
              },
            ),
          )
          .handler();
      final call = Message.assistant('calling');
      final result = Message.tool(content: 'r', toolCallId: 'c1');
      final info = _of(ComponentType.toolsNode);

      await handler.onStart(ctx, info, call);
      expect(input, same(call));

      await handler.onEnd(ctx, info, [result]);
      await handler.onEnd(ctx, info, <Object?>[null, result]);
      await handler.onEnd(ctx, info, <Object?>['no message']);
      await handler.onEndWithStreamOutput(
        ctx,
        info,
        StreamReader<Object?>.fromIterable([
          <Message?>[result, null],
          'not a chunk',
        ]),
      );

      expect(outputs, [
        [result],
        [null, result],
        null,
        [result, null],
        null,
      ]);
    });

    test('errors are passed with their stack trace', () async {
      Object? seenError;
      StackTrace? seenTrace;
      final handler = HandlerHelper()
          .tool(
            ToolCallbackHandler(
              onError: (ctx, info, error, stackTrace) {
                seenError = error;
                seenTrace = stackTrace;
                return ctx;
              },
            ),
          )
          .handler();
      final trace = StackTrace.current;

      await handler.onError(ctx, _of(ComponentType.tool), 'failed', trace);
      expect(seenError, 'failed');
      expect(seenTrace, same(trace));
    });
  });

  test('a helper handler in a run only hears the kinds it has a handler for',
      () async {
    final log = <String>[];
    final handler = HandlerHelper()
        .prompt(
          PromptCallbackHandler(
            onStart: (ctx, info, input) {
              log.add('prompt.start ${input!.variables}');
              return ctx;
            },
            onEnd: (ctx, info, output) {
              log.add('prompt.end ${output!.result.single.content}');
              return ctx;
            },
          ),
        )
        .handler();
    final template = ChatTemplate.fromMessages(
      FormatType.fString,
      [Message.user('Hello {name}')],
    );

    await template.format(
      {'name': 'Ada'},
      options: ChatTemplateOptions(
        runContext: RunContext.background().withHandlers([handler]),
      ),
    );

    expect(log, ['prompt.start {name: Ada}', 'prompt.end Hello Ada']);
  });
}
