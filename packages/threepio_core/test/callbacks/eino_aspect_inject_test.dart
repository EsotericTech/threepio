// Ports of eino `callbacks/aspect_inject_test.go` and
// `callbacks/interface_test.go` (v0.9.22).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/streaming.dart';

import '../support/log_capture.dart';

/// A pipe of capacity 2 that a producer fills with 0..9, as the goroutines of
/// the Go test do.
StreamReader<int> _tenInts() {
  final (reader, writer) = pipe<int>(capacity: 2);
  unawaited(() async {
    for (var i = 0; i < 10; i++) {
      if (await writer.sendAsync(i)) break;
    }
    await writer.close();
  }());
  return reader;
}

const _empty = RunInfo(name: '', type: '', componentType: ComponentType.custom);

RunInfo _named(String name) =>
    RunInfo(name: name, type: '', componentType: ComponentType.custom);

/// What `myCallback` of the Go test saw. The Go handler asserts inside its
/// hooks; a failing `expect` inside a hook would only be logged here, so the
/// calls are recorded and checked by the test.
final class _Recorder extends ComponentCallbackHandler {
  final List<(String timing, RunInfo info, Object? payload)> calls = [];

  int get times => calls.length;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    calls.add(('start', info, input));
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    calls.add(('end', info, output));
    return ctx;
  }
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('TestAspectInject', () {
    test('ctx without manager', () async {
      var ctx = RunContext.background();
      ctx = await onStart(ctx, 1);
      ctx = await onEnd(ctx, 2);
      ctx = await onError(ctx, Exception('3'), StackTrace.current);

      final input = _tenInts();
      final (afterStart, newInput) = await onStartWithStreamInput(ctx, input);
      expect(newInput, same(input), reason: 'nobody listens, nothing is copied');
      expect(await newInput.collectAll(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      await newInput.close();

      final output = _tenInts();
      final (afterEnd, newOutput) =
          await onEndWithStreamOutput(afterStart, output);
      expect(newOutput, same(output));
      expect(await newOutput.collectAll(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      await newOutput.close();

      expect(afterEnd.hasCallbacks, isFalse);
      expect(afterEnd.runInfo, isNull);
    });

    test('ctx with manager', () async {
      var count = 0;

      Future<RunContext> sum(RunContext ctx, StreamReader<Object?> stream) async {
        for (var item = await stream.nextOrNull();
            item != null;
            item = await stream.nextOrNull()) {
          count += item as int;
        }
        await stream.close();
        return ctx;
      }

      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            count += input! as int;
            return ctx;
          })
          .onEnd((ctx, info, output) {
            count += output! as int;
            return ctx;
          })
          .onError((ctx, info, error, stackTrace) {
            count += int.parse('$error');
            return ctx;
          })
          .onStartWithStreamInput((ctx, info, input) => sum(ctx, input))
          .onEndWithStreamOutput((ctx, info, output) => sum(ctx, output))
          .build();

      var ctx = initCallbacks(RunContext.background(), null, [handler]);

      ctx = await onStart(ctx, 1);
      ctx = await onEnd(ctx, 2);
      ctx = await onError(ctx, '3', StackTrace.current);
      expect(count, 6);

      ctx = reuseHandlers(ctx, _empty);
      final (afterStart, input) = await onStartWithStreamInput(ctx, _tenInts());
      var expected = 0;
      for (var item = await input.nextOrNull();
          item != null;
          item = await input.nextOrNull()) {
        expect(item, expected);
        expected++;
        count += item;
      }
      await input.close();
      expect(expected, 10);

      final (_, output) = await onEndWithStreamOutput(afterStart, _tenInts());
      expected = 0;
      for (var item = await output.nextOrNull();
          item != null;
          item = await output.nextOrNull()) {
        expect(item, expected);
        expected++;
        count += item;
      }
      await output.close();
      expect(expected, 10);

      // 1 + 2 + 3, and four times 0 + 1 + ... + 9: the handler and the
      // caller each read both streams in full.
      expect(count, 186);
    });
  });

  test('TestGlobalCallbacksRepeated', () async {
    var times = 0;
    GlobalCallbacks.append([
      CallbackHandlerBuilder().onStart((ctx, info, input) {
        times++;
        return ctx;
      }).build(),
    ]);

    var ctx = RunContext.background();
    ctx = appendHandlers(ctx, _empty);
    ctx = appendHandlers(ctx, _empty);

    await onStart(ctx, 'test');
    expect(times, 1, reason: 'the global handlers are taken once, not per append');
  });

  test('TestEnsureRunInfo', () async {
    String? name;
    String? type;
    ComponentType? component;

    var ctx = initCallbacks(
      RunContext.background(),
      const RunInfo(
        name: 'name',
        type: 'type',
        componentType: ComponentType.chain,
      ),
      [
        CallbackHandlerBuilder().onStart((ctx, info, input) {
          name = info.name;
          type = info.type;
          component = info.componentType;
          return ctx;
        }).build(),
      ],
    );

    ctx = await onStart(ctx, '');
    expect(name, 'name');
    expect(type, 'type');
    expect(component, ComponentType.chain);

    // The run info was used up by the start callback, so the next component
    // reports itself.
    final ctx2 = ensureRunInfo(ctx, 'type2', ComponentType.tool);
    await onStart(ctx2, '');
    expect(name, '');
    expect(type, 'type2');
    expect(component, ComponentType.tool);

    // EnsureRunInfo on an empty context
    GlobalCallbacks.append([
      CallbackHandlerBuilder().onStart((ctx, info, input) {
        type = info.type;
        component = info.componentType;
        return ctx;
      }).build(),
    ]);
    final ctx3 =
        ensureRunInfo(RunContext.background(), 'type3', ComponentType.retriever);
    await onStart(ctx3, 0);
    expect(type, 'type3');
    expect(component, ComponentType.retriever);
  });

  test('ensureRunInfo leaves a pending run info alone', () async {
    final seen = <RunInfo>[];
    final handler = CallbackHandlerBuilder().onStart((ctx, info, input) {
      seen.add(info);
      return ctx;
    }).build();
    final node = _named('node');

    var ctx = initCallbacks(RunContext.background(), node, [handler]);
    ctx = ensureRunInfo(ctx, 'OpenAI', ComponentType.chatModel);
    expect(ctx.runInfo, node);

    await onStart(ctx, null);
    expect(seen, [node]);
  });

  test('TestNesting', () async {
    final callback = _Recorder();
    final test = _named('test');
    final ctx = initCallbacks(RunContext.background(), test, [callback]);

    // jumped: a second start without a run info of its own
    var ctx1 = await onStart(ctx, 0);
    final ctx2 = await onStart(ctx1, 1);
    await onEnd(ctx2, 1);
    await onEnd(ctx1, 0);
    expect(callback.calls, [
      ('start', test, 0),
      ('start', RunInfo.unknown, 1),
      ('end', RunInfo.unknown, 1),
      ('end', test, 0),
    ]);
    expect(callback.calls[1].$2.isUnknown, isTrue);

    // reused: the inner component reports itself first
    callback.calls.clear();
    final test2 = _named('test2');
    ctx1 = await onStart(ctx, 0);
    final reused = reuseHandlers(ctx1, test2);
    final ctx3 = await onStart(reused, 1);
    await onEnd(ctx3, 1);
    await onEnd(ctx1, 0);
    expect(callback.calls, [
      ('start', test, 0),
      ('start', test2, 1),
      ('end', test2, 1),
      ('end', test, 0),
    ]);
    expect(callback.times, 4);
  });

  test('TestReuseHandlersOnEmptyCtx', () async {
    final callback = _Recorder();
    GlobalCallbacks.append([callback]);

    final ctx = reuseHandlers(RunContext.background(), _named('test'));
    await onStart(ctx, 0);

    expect(callback.times, 1);
    expect(callback.calls.single, ('start', _named('test'), 0));
  });

  test('TestAppendHandlersTwiceOnSameCtx', () async {
    final callback = _Recorder();
    final callback1 = _Recorder();
    final callback2 = _Recorder();
    final info = _named('test');

    final ctx = initCallbacks(RunContext.background(), info, [callback]);
    final ctx1 = appendHandlers(ctx, info, [callback1]);
    final ctx2 = appendHandlers(ctx, info, [callback2]);
    await onStart(ctx1, 0);
    await onStart(ctx2, 0);

    expect(callback.times, 2);
    expect(callback1.times, 1);
    expect(callback2.times, 1);
  });

  test('TestAppendGlobalHandlers', () {
    final handler1 =
        CallbackHandlerBuilder().onStart((ctx, info, input) => ctx).build();
    final handler2 =
        CallbackHandlerBuilder().onEnd((ctx, info, output) => ctx).build();

    GlobalCallbacks.append([handler1]);
    expect(GlobalCallbacks.handlers, [handler1]);

    GlobalCallbacks.append([handler2]);
    expect(GlobalCallbacks.handlers, [handler1, handler2]);

    GlobalCallbacks.append(const []);
    expect(GlobalCallbacks.handlers, hasLength(2));
  });
}
