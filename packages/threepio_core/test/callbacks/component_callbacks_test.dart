// The callback chain of a run context: who is called, in which order, with
// which context and which copy of a stream.
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/streaming.dart';

import '../support/log_capture.dart';

const _info = RunInfo(
  name: 'node',
  type: 'Fake',
  componentType: ComponentType.lambda,
);

final _tagKey = ContextKey<String>('test.tag');

/// Writes `<name>:<timing>` to [log] and, on start, appends its name to the
/// tag the context carries.
final class _Named extends ComponentCallbackHandler {
  _Named(this.name, this.log);

  final String name;
  final List<String> log;

  RunContext _tagged(RunContext ctx) =>
      ctx.withValue(_tagKey, '${ctx.value(_tagKey) ?? ''}$name');

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    log.add('$name:start(${ctx.value(_tagKey) ?? ''})');
    return _tagged(ctx);
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    log.add('$name:end(${ctx.value(_tagKey) ?? ''})');
    return _tagged(ctx);
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    log.add('$name:error($error)');
    return _tagged(ctx);
  }
}

/// Reads its copy of a stream to the end, in the background or before it
/// returns.
final class _StreamCollector extends ComponentCallbackHandler {
  _StreamCollector({this.inBackground = true});

  final bool inBackground;
  final List<Object?> inputs = [];
  final List<Object?> outputs = [];
  final Completer<void> done = Completer<void>();

  Future<void> _drain(StreamReader<Object?> stream, List<Object?> into) async {
    into.addAll(await stream.collectAll());
    await stream.close();
    if (!done.isCompleted) done.complete();
  }

  @override
  Future<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) async {
    final work = _drain(input, inputs);
    if (inBackground) {
      unawaited(work);
    } else {
      await work;
    }
    return ctx;
  }

  @override
  Future<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) async {
    final work = _drain(output, outputs);
    if (inBackground) {
      unawaited(work);
    } else {
      await work;
    }
    return ctx;
  }
}

/// Answers `false` for the timings in [unwanted] and records what it was
/// asked.
final class _Picky extends ComponentCallbackHandler implements TimingChecker {
  _Picky(this.unwanted);

  final Set<CallbackTiming> unwanted;
  final List<(RunInfo, CallbackTiming)> asked = [];
  final List<String> called = [];

  @override
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing) {
    asked.add((info, timing));
    return !unwanted.contains(timing);
  }

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    called.add('start');
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    called.add('end');
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    called.add('error');
    return ctx;
  }

  @override
  Future<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) async {
    called.add('startStream');
    await input.close();
    return ctx;
  }

  @override
  Future<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) async {
    called.add('endStream');
    await output.close();
    return ctx;
  }
}

final class _Throwing extends ComponentCallbackHandler {
  StreamReader<Object?>? copy;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) =>
      throw StateError('start broke');

  @override
  Future<RunContext> onEnd(RunContext ctx, RunInfo info, Object? output) async =>
      throw StateError('end broke');

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    copy = output;
    throw StateError('stream broke');
  }
}

final class _BrokenChecker extends ComponentCallbackHandler
    implements TimingChecker {
  @override
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing) =>
      throw StateError('checker bug');

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) =>
      fail('must not be called');
}

/// Overrides nothing.
final class _Silent extends ComponentCallbackHandler {
  const _Silent();
}

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  group('order and context', () {
    test('start runs last to first, end and error first to last', () async {
      final log = <String>[];
      final a = _Named('a', log);
      final b = _Named('b', log);
      GlobalCallbacks.append([_Named('g1', log), _Named('g2', log)]);

      var ctx = initCallbacks(RunContext.background(), _info, [a, b]);
      ctx = await onStart(ctx, 'in');
      expect(log, ['g2:start()', 'g1:start(g2)', 'b:start(g2g1)', 'a:start(g2g1b)']);
      expect(ctx.value(_tagKey), 'g2g1ba');

      log.clear();
      final ended = await onEnd(ctx, 'out');
      expect(log, [
        'a:end(g2g1ba)',
        'b:end(g2g1baa)',
        'g1:end(g2g1baab)',
        'g2:end(g2g1baabg1)',
      ]);
      expect(ended.value(_tagKey), 'g2g1baabg1g2');

      log.clear();
      await onError(ctx, 'boom', StackTrace.current);
      expect(log, ['a:error(boom)', 'b:error(boom)', 'g1:error(boom)', 'g2:error(boom)']);
    });

    test('what a start hook stores is there for the end hook', () async {
      final started = ContextKey<int>('started');
      int? seenAtEnd;
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) => ctx.withValue(started, 42))
          .onEnd((ctx, info, output) {
            seenAtEnd = ctx.value(started);
            return ctx;
          })
          .build();

      final base = RunContext.background().withHandlers([handler]);
      final ctx = await onStart(reuseHandlers(base, _info), null);
      expect(base.value(started), isNull, reason: 'a context is immutable');
      await onEnd(ctx, null);
      expect(seenAtEnd, 42);
    });

    test('an asynchronous hook is awaited before the next one runs', () async {
      final log = <String>[];
      final slow = CallbackHandlerBuilder().onEnd((ctx, info, output) async {
        await Future<void>.delayed(Duration.zero);
        log.add('slow');
        return ctx;
      }).build();
      final fast = CallbackHandlerBuilder().onEnd((ctx, info, output) {
        log.add('fast');
        return ctx;
      }).build();

      final ctx = initCallbacks(RunContext.background(), _info, [slow, fast]);
      await onEnd(ctx, null);
      expect(log, ['slow', 'fast']);
    });

    test('the payload reaches the handlers untouched', () async {
      final payload = Object();
      final seen = <Object?>[];
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            seen.add(input);
            return ctx;
          })
          .onEnd((ctx, info, output) {
            seen.add(output);
            return ctx;
          })
          .build();
      final ctx = initCallbacks(RunContext.background(), _info, [handler]);

      await onEnd(await onStart(ctx, payload), null);
      expect(seen, [same(payload), isNull]);
    });

    test('the error and its stack trace reach the handlers', () async {
      final trace = StackTrace.current;
      Object? seenError;
      StackTrace? seenTrace;
      final handler =
          CallbackHandlerBuilder().onError((ctx, info, error, stackTrace) {
        seenError = error;
        seenTrace = stackTrace;
        return ctx;
      }).build();
      final error = StateError('x');

      await onError(
        initCallbacks(RunContext.background(), _info, [handler]),
        error,
        trace,
      );
      expect(seenError, same(error));
      expect(seenTrace, same(trace));
    });
  });

  group('TimingChecker', () {
    test('a handler is asked before every callback and left out on false',
        () async {
      final picky = _Picky({CallbackTiming.onEnd, CallbackTiming.onError});
      var ctx = initCallbacks(RunContext.background(), _info, [picky]);

      ctx = await onStart(ctx, 1);
      await onEnd(ctx, 2);
      await onError(ctx, 'e', StackTrace.current);

      expect(picky.called, ['start']);
      expect(picky.asked, [
        (_info, CallbackTiming.onStart),
        (_info, CallbackTiming.onEnd),
        (_info, CallbackTiming.onError),
      ]);
    });

    test('a handler that does not want a stream costs no copy', () async {
      final picky = _Picky({
        CallbackTiming.onStartWithStreamInput,
        CallbackTiming.onEndWithStreamOutput,
      });
      final ctx = initCallbacks(RunContext.background(), _info, [picky]);

      final input = StreamReader.fromIterable([1, 2]);
      final (started, sameInput) = await onStartWithStreamInput(ctx, input);
      expect(sameInput, same(input));

      final output = StreamReader.fromIterable([3]);
      final (_, sameOutput) = await onEndWithStreamOutput(started, output);
      expect(sameOutput, same(output));
      expect(picky.called, isEmpty);
      expect(started.runInfo, _info, reason: 'the start still happened');
    });

    test('without a run info the checker is asked about RunInfo.unknown',
        () async {
      final picky = _Picky({});
      await onStart(initCallbacks(RunContext.background(), null, [picky]), 1);
      expect(picky.asked.single.$1, RunInfo.unknown);
    });
  });

  group('streams', () {
    test('every handler and the caller see every item', () async {
      final first = _StreamCollector();
      final second = _StreamCollector(inBackground: false);
      final picky = _Picky({CallbackTiming.onEndWithStreamOutput});
      final ctx =
          initCallbacks(RunContext.background(), _info, [first, picky, second]);

      final (source, writer) = pipe<String>(capacity: 8);
      writer
        ..send('a')
        ..send('b')
        ..send('c');
      await writer.close();

      final (_, forCaller) = await onEndWithStreamOutput<String>(ctx, source);
      expect(forCaller, isNot(same(source)));
      expect(await forCaller.collectAll(), ['a', 'b', 'c']);
      await forCaller.close();
      await first.done.future;

      expect(first.outputs, ['a', 'b', 'c']);
      expect(second.outputs, ['a', 'b', 'c']);
      expect(picky.called, isEmpty);
    });

    test('input streams are copied the same way, handlers last to first',
        () async {
      final order = <String>[];
      CallbackStreamHook reader(String name) => (ctx, info, input) async {
            order.add(name);
            expect(await input.collectAll(), [1, 2, 3]);
            await input.close();
            return ctx;
          };
      final a = CallbackHandlerBuilder().onStartWithStreamInput(reader('a')).build();
      final b = CallbackHandlerBuilder().onStartWithStreamInput(reader('b')).build();
      failOnLoggedWarnings('threepio.callbacks');

      final ctx = initCallbacks(RunContext.background(), _info, [a, b]);
      final (started, input) =
          await onStartWithStreamInput(ctx, StreamReader.fromIterable([1, 2, 3]));

      expect(order, ['b', 'a']);
      expect(await input.collectAll(), [1, 2, 3]);
      expect(started.runInfo, _info);
    });

    test('a handler that does not override the stream hooks closes its copy',
        () async {
      final ctx =
          initCallbacks(RunContext.background(), _info, const [_Silent()]);
      final (source, writer) = pipe<int>();

      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      expect(writer.send(1), isFalse, reason: 'the caller still reads');
      await forCaller.close();
      expect(writer.send(2), isTrue, reason: 'all copies closed: source released');
    });

    test('a slow handler does not hold the caller back', () async {
      final collector = _StreamCollector();
      final ctx = initCallbacks(RunContext.background(), _info, [collector]);
      final (source, writer) = pipe<int>(capacity: 4);

      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      writer.send(1);
      expect(await forCaller.recv(), 1);
      writer.send(2);
      await writer.close();
      expect(await forCaller.collectAll(), [2]);
      await collector.done.future;
      expect(collector.outputs, [1, 2]);
    });

    test('an error in the stream reaches the handlers and the caller', () async {
      final seen = <Object>[];
      final handler =
          CallbackHandlerBuilder().onEndWithStreamOutput((ctx, info, output) {
        unawaited(() async {
          try {
            await output.collectAll();
          } on FormatException catch (error) {
            seen.add(error);
          } finally {
            await output.close();
          }
        }());
        return ctx;
      }).build();
      final ctx = initCallbacks(RunContext.background(), _info, [handler]);
      final (source, writer) = pipe<int>(capacity: 4);
      writer
        ..send(1)
        ..sendError(const FormatException('bad chunk'));
      await writer.close();

      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      expect(await forCaller.recv(), 1);
      await expectLater(forCaller.recv(), throwsFormatException);
      await forCaller.close();
      await pumpEventQueue();
      expect(seen, hasLength(1));
    });
  });

  group('a handler that throws', () {
    test('is logged and skipped; the others and the run go on', () async {
      final logs = captureLogs('threepio.callbacks');
      final log = <String>[];
      final before = _Named('before', log);
      final after = _Named('after', log);
      final throwing = _Throwing();

      var ctx =
          initCallbacks(RunContext.background(), _info, [before, throwing, after]);
      ctx = await onStart(ctx, 1);
      expect(log, ['after:start()', 'before:start(after)']);
      expect(ctx.value(_tagKey), 'afterbefore');

      log.clear();
      await onEnd(ctx, 2);
      expect(log, hasLength(2));

      expect(logs.map((r) => r.level).toSet(), {Level.WARNING});
      expect(logs.map((r) => r.message), [
        'Callback handler _Throwing failed in onStart',
        'Callback handler _Throwing failed in onEnd',
      ]);
      expect(logs.first.error, isStateError);
      expect(logs.first.stackTrace, isNotNull);
    });

    test('in a typed stream hook of a HandlerHelper leaks no copy', () async {
      final logs = captureLogs('threepio.callbacks');
      final handler = HandlerHelper()
          .tool(
            ToolCallbackHandler(
              onEndWithStreamOutput: (ctx, info, output) =>
                  throw StateError('hook bug'),
            ),
          )
          .handler();
      final (source, writer) = pipe<String>();
      final run = initCallbacks(
        RunContext.background(),
        const RunInfo(name: 't', type: 'T', componentType: ComponentType.tool),
        [handler],
      );

      final (_, forCaller) = await onEndWithStreamOutput(run, source);
      expect(writer.send('a'), isFalse, reason: 'the caller still reads');
      await forCaller.close();
      expect(writer.send('b'), isTrue, reason: 'the source was released');
      expect(logs.single.message, contains('failed in onEndWithStreamOutput'));
    });

    test('in a stream hook has its copy closed for it', () async {
      final logs = captureLogs('threepio.callbacks');
      final throwing = _Throwing();
      final collector = _StreamCollector();
      final ctx =
          initCallbacks(RunContext.background(), _info, [throwing, collector]);
      final (source, writer) = pipe<int>(capacity: 4);
      writer.send(7);
      await writer.close();

      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      expect(await forCaller.collectAll(), [7]);
      await forCaller.close();
      await collector.done.future;

      expect(collector.outputs, [7]);
      expect(logs.single.message,
          'Callback handler _Throwing failed in onEndWithStreamOutput');
      await expectLater(
        throwing.copy!.recv(),
        throwsA(isA<StreamClosedException>()),
      );
    });
  });

  test('a TimingChecker that throws is logged and left out', () async {
    final logs = captureLogs('threepio.callbacks');
    final log = <String>[];
    final ctx = initCallbacks(
      RunContext.background(),
      _info,
      [_BrokenChecker(), _Named('ok', log)],
    );

    await onEnd(await onStart(ctx, 1), 2);

    expect(log, ['ok:start()', 'ok:end(ok)']);
    expect(logs.map((r) => r.message), [
      'Callback handler _BrokenChecker failed in needed (onStart)',
      'Callback handler _BrokenChecker failed in needed (onEnd)',
    ]);
  });

  group('the callbacks of a context', () {
    test('a plain context has none and firing costs nothing', () async {
      final ctx = RunContext.background();
      expect(ctx.hasCallbacks, isFalse);
      expect(ctx.callbackHandlers, isEmpty);
      expect(ctx.runInfo, isNull);
      expect(await onStart(ctx, 1), same(ctx));
      expect(await onEnd(ctx, 1), same(ctx));
      expect(await onError(ctx, 'e', StackTrace.empty), same(ctx));
    });

    test('withHandlers adds to what is there and keeps the original', () {
      const a = _Silent();
      final b = _Named('b', []);
      final base = RunContext.background();

      final one = base.withHandlers(const [a]);
      final two = one.withHandlers([b]);

      expect(base.hasCallbacks, isFalse);
      expect(one.callbackHandlers, [a]);
      expect(two.callbackHandlers, [a, b]);
    });

    test('withHandlers keeps the run info that is pending', () {
      final ctx = initCallbacks(RunContext.background(), _info, const [_Silent()])
          .withHandlers([_Named('x', [])]);
      expect(ctx.runInfo, _info);
      expect(ctx.callbackHandlers, hasLength(2));
    });

    test('withHandlers of nothing on a plain context changes nothing', () {
      final ctx = RunContext.background();
      expect(ctx.withHandlers(const []), same(ctx));
    });

    test('global handlers are part of every context that has callbacks', () {
      const global = _Silent();
      final own = _Named('own', []);
      GlobalCallbacks.append(const [global]);

      expect(
        RunContext.background().withHandlers([own]).callbackHandlers,
        [own, global],
      );
      expect(
        initCallbacks(RunContext.background(), null).callbackHandlers,
        [global],
      );
    });

    test('a context keeps the global handlers it was set up with', () async {
      final log = <String>[];
      GlobalCallbacks.append([_Named('early', log)]);
      final ctx = initCallbacks(RunContext.background(), _info);
      GlobalCallbacks.append([_Named('late', log)]);

      await onStart(ctx, null);
      expect(log, ['early:start()']);

      log.clear();
      await onStart(initCallbacks(RunContext.background(), _info), null);
      expect(log, ['late:start()', 'early:start(late)']);
    });

    test('initCallbacks drops the handlers the context had', () {
      final old = _Named('old', []);
      final fresh = _Named('fresh', []);
      final ctx = RunContext.background().withHandlers([old]);

      expect(initCallbacks(ctx, _info, [fresh]).callbackHandlers, [fresh]);
      expect(initCallbacks(ctx, _info).hasCallbacks, isFalse);
      expect(ctx.callbackHandlers, [old]);
    });

    test('reuseHandlers keeps the handlers and replaces the run info', () {
      final handler = _Named('h', []);
      const other = RunInfo(
        name: 'other',
        type: 'T',
        componentType: ComponentType.tool,
      );
      final ctx = initCallbacks(RunContext.background(), _info, [handler]);

      final reused = reuseHandlers(ctx, other);
      expect(reused.callbackHandlers, [handler]);
      expect(reused.runInfo, other);
      expect(ctx.runInfo, _info);
      expect(reuseHandlers(ctx, null).runInfo, isNull);
    });

    test('reuseHandlers on a plain context without global handlers adds none',
        () {
      expect(reuseHandlers(RunContext.background(), _info).hasCallbacks, isFalse);
    });

    test('runInfo is the pending one before the start and the started one after',
        () async {
      final ctx =
          initCallbacks(RunContext.background(), _info, const [_Silent()]);
      expect(ctx.runInfo, _info);

      final started = await onStart(ctx, null);
      expect(started.runInfo, _info);

      const inner = RunInfo(
        name: 'inner',
        type: 'T',
        componentType: ComponentType.tool,
      );
      final nested = reuseHandlers(started, inner);
      expect(nested.runInfo, inner);
      expect((await onStart(nested, null)).runInfo, inner);
      expect(started.runInfo, _info);
    });

    test('ensureRunInfo names the component only when nobody did', () {
      const handler = _Silent();
      final plain = RunContext.background().withHandlers(const [handler]);
      expect(plain.runInfo, isNull);

      final ensured = ensureRunInfo(plain, 'OpenAI', ComponentType.chatModel);
      expect(
        ensured.runInfo,
        const RunInfo(
          name: '',
          type: 'OpenAI',
          componentType: ComponentType.chatModel,
        ),
      );
      expect(ensured.callbackHandlers, [handler]);
      expect(ensureRunInfo(ensured, 'Other', ComponentType.tool), same(ensured));
      expect(
        ensureRunInfo(RunContext.background(), 'X', ComponentType.tool)
            .hasCallbacks,
        isFalse,
      );
    });
  });

  group('onEndWithCopies', () {
    test('gives every handler a copy of its own, made once', () async {
      final seen = <String, Object?>{};
      ComponentCallbackHandler named(String name) =>
          CallbackHandlerBuilder().onEnd((ctx, info, output) {
            seen[name] = output;
            return ctx;
          }).build();
      var copyCalls = 0;

      final ctx =
          initCallbacks(RunContext.background(), _info, [named('a'), named('b')]);
      await onEndWithCopies<String>(ctx, 'out', (output, count) {
        copyCalls++;
        return [for (var i = 0; i < count; i++) '$output#$i'];
      });

      expect(copyCalls, 1);
      expect(seen, {'a': 'out#0', 'b': 'out#1'});
    });

    test('copies nothing when nobody wants the end callback', () async {
      final startOnly =
          CallbackHandlerBuilder().onStart((ctx, info, input) => ctx).build();
      final ctx = initCallbacks(RunContext.background(), _info, [startOnly]);
      final plain = RunContext.background();

      List<int> never(int output, int count) => fail('must not copy');
      expect(await onEndWithCopies<int>(plain, 1, never), same(plain));
      await onEndWithCopies<int>(ctx, 1, never);
    });
  });

  group('CallbackHandlerBuilder', () {
    test('the handler asks for exactly the callbacks it has a function for', () {
      final ctx = RunContext.background();
      final none = CallbackHandlerBuilder().build() as TimingChecker;
      for (final timing in CallbackTiming.values) {
        expect(none.needed(ctx, _info, timing), isFalse);
      }

      final all = CallbackHandlerBuilder()
          .onStart((ctx, info, input) => ctx)
          .onEnd((ctx, info, output) => ctx)
          .onError((ctx, info, error, stackTrace) => ctx)
          .onStartWithStreamInput((ctx, info, input) => ctx)
          .onEndWithStreamOutput((ctx, info, output) => ctx)
          .build() as TimingChecker;
      for (final timing in CallbackTiming.values) {
        expect(all.needed(ctx, _info, timing), isTrue);
      }

      final endOnly = CallbackHandlerBuilder()
          .onEnd((ctx, info, output) => ctx)
          .build() as TimingChecker;
      expect(endOnly.needed(ctx, _info, CallbackTiming.onEnd), isTrue);
      expect(endOnly.needed(ctx, _info, CallbackTiming.onStart), isFalse);
    });

    test('hooks without a function do nothing when called directly', () async {
      final handler = CallbackHandlerBuilder().build();
      final ctx = RunContext.background();

      expect(await handler.onStart(ctx, _info, 1), same(ctx));
      expect(await handler.onEnd(ctx, _info, 1), same(ctx));
      expect(await handler.onError(ctx, _info, 'e', StackTrace.empty), same(ctx));

      final (input, inputWriter) = pipe<Object?>();
      expect(await handler.onStartWithStreamInput(ctx, _info, input), same(ctx));
      expect(inputWriter.send(1), isTrue, reason: 'the copy was closed');

      final (output, outputWriter) = pipe<Object?>();
      expect(await handler.onEndWithStreamOutput(ctx, _info, output), same(ctx));
      expect(outputWriter.send(1), isTrue);
    });

    test('a built handler is not changed by the builder afterwards', () async {
      var calls = 0;
      final builder = CallbackHandlerBuilder();
      final handler = builder.build();
      builder.onStart((ctx, info, input) {
        calls++;
        return ctx;
      });

      await handler.onStart(RunContext.background(), _info, null);
      expect(calls, 0);
      await builder.build().onStart(RunContext.background(), _info, null);
      expect(calls, 1);
    });
  });

  group('ComponentCallbackHandler defaults', () {
    test('return the context and close the streams', () async {
      const handler = _Silent();
      final ctx = RunContext.background();

      expect(handler.onStart(ctx, _info, 1), same(ctx));
      expect(handler.onEnd(ctx, _info, 1), same(ctx));
      expect(handler.onError(ctx, _info, 'e', StackTrace.empty), same(ctx));

      final (input, inputWriter) = pipe<int>();
      expect(await handler.onStartWithStreamInput(ctx, _info, input), same(ctx));
      expect(inputWriter.send(1), isTrue);

      final (output, outputWriter) = pipe<int>();
      expect(await handler.onEndWithStreamOutput(ctx, _info, output), same(ctx));
      expect(outputWriter.send(1), isTrue);
    });
  });

  group('GlobalCallbacks', () {
    test('append, remove and clear', () {
      const a = _Silent();
      final b = _Named('b', []);
      expect(GlobalCallbacks.isEmpty, isTrue);

      GlobalCallbacks.append([a, b]);
      expect(GlobalCallbacks.isEmpty, isFalse);
      expect(GlobalCallbacks.handlers, [a, b]);

      expect(GlobalCallbacks.remove(a), isTrue);
      expect(GlobalCallbacks.remove(a), isFalse);
      expect(GlobalCallbacks.handlers, [b]);

      GlobalCallbacks.clear();
      expect(GlobalCallbacks.handlers, isEmpty);
    });

    test('the list it hands out cannot be modified', () {
      GlobalCallbacks.append(const [_Silent()]);
      expect(
        () => GlobalCallbacks.handlers.add(const _Silent()),
        throwsUnsupportedError,
      );
    });
  });

  group('RunInfo.unknown', () {
    test('is empty and recognises itself', () {
      expect(RunInfo.unknown.name, isEmpty);
      expect(RunInfo.unknown.type, isEmpty);
      expect(RunInfo.unknown.componentType, ComponentType.custom);
      expect(RunInfo.unknown.isUnknown, isTrue);
      expect(_info.isUnknown, isFalse);
      expect(
        const RunInfo(name: '', type: 'T', componentType: ComponentType.custom)
            .isUnknown,
        isFalse,
      );
    });
  });
}
