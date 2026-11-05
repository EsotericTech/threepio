// Port of eino `components/tool/utils/error_handler_test.go`
// (TestErrorWrapper), with the cases the Go test leaves out: a handler must
// not swallow an interrupt (eino #583) or a cancelled run.
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

final _info = ToolInfo.fromParams(name: 'test_error_tool', params: const {});

/// `testErrorTool` of the Go test: invokable and streamable, both failing.
final class _ErrorTool extends InvokableTool implements StreamableTool {
  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      throw Exception('test error');

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      throw Exception('test stream error');

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) =>
      streamableRun(RunContext.background(), argumentsJson);
}

/// An invokable tool that does what [body] does.
final class _Invokable extends InvokableTool {
  _Invokable(this.body);

  final Future<String> Function(RunContext ctx, String args, ToolOptions? options)
      body;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      body(ctx, argumentsJson, options);
}

/// A streaming tool that does what [body] does.
final class _Streamable extends StreamableTool {
  _Streamable(this.body);

  final Future<StreamReader<String>> Function(
    RunContext ctx,
    String args,
    ToolOptions? options,
  ) body;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      body(ctx, argumentsJson, options);
}

/// A tool the model can see but nothing can execute.
final class _InfoOnly extends BaseTool {
  @override
  Future<ToolInfo> info() async => _info;
}

/// A tool written before `invokableRun` existed.
final class _LegacyFailing extends InvokableTool {
  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> run(String argumentsJson) async =>
      throw StateError('legacy failure');
}

final class _Interrupted implements InterruptSignal {
  const _Interrupted();
}

String _message(RunContext ctx, Object error) => switch (error) {
      final StateError e => e.message,
      _ => error.toString().replaceFirst('Exception: ', ''),
    };

void main() {
  final ctx = RunContext.background();

  group('TestErrorWrapper', () {
    test('wrapToolWithErrorHandler turns a failed call into a result', () async {
      final wrapped = wrapToolWithErrorHandler(_ErrorTool(), _message);

      expect(wrapped, isA<InvokableTool>());
      expect(wrapped, isA<StreamableTool>());

      final result = await (wrapped as InvokableTool).invokableRun(ctx, '');
      expect(result, 'test error');

      final stream = await (wrapped as StreamableTool).streamableRun(ctx, '');
      expect(await stream.recv(), 'test stream error');
      await expectLater(stream.recv(), throwsA(isA<StreamEOFException>()));
    });

    test('wrapInvokableToolWithErrorHandler', () async {
      final wrapped = wrapInvokableToolWithErrorHandler(_ErrorTool(), _message);

      expect(await wrapped.invokableRun(ctx, ''), 'test error');
      expect(wrapped, isNot(isA<StreamableTool>()));
    });

    test('wrapStreamableToolWithErrorHandler', () async {
      final wrapped = wrapStreamableToolWithErrorHandler(_ErrorTool(), _message);

      final stream = await wrapped.streamableRun(ctx, '');
      expect(await stream.recv(), 'test stream error');
      await expectLater(stream.recv(), throwsA(isA<StreamEOFException>()));
      expect(wrapped, isNot(isA<InvokableTool>()));
    });
  });

  group('the wrapper keeps the shape of the tool', () {
    test('an invokable tool stays invokable only', () {
      final wrapped = wrapToolWithErrorHandler(
        _Invokable((ctx, args, options) async => 'ok'),
        _message,
      );
      expect(wrapped, isA<InvokableTool>());
      expect(wrapped, isNot(isA<StreamableTool>()));
    });

    test('a streaming tool stays streaming only', () {
      final wrapped = wrapToolWithErrorHandler(
        _Streamable((ctx, args, options) async => StreamReader.fromIterable(['ok'])),
        _message,
      );
      expect(wrapped, isA<StreamableTool>());
      expect(wrapped, isNot(isA<InvokableTool>()));
    });

    test('a tool that cannot be executed is returned as it is', () {
      final tool = _InfoOnly();
      expect(wrapToolWithErrorHandler(tool, _message), same(tool));
    });

    test('an enhanced tool is returned as it is', () {
      final tool = EnhancedFunctionTool<Map<String, Object?>>(
        name: 'enhanced',
        description: 'enhanced only',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        invoke: (ctx, input, options) => ToolResult.text('x'),
      );
      expect(wrapToolWithErrorHandler(tool, _message), same(tool));
    });

    test('info is the info of the wrapped tool', () async {
      for (final wrapped in [
        wrapToolWithErrorHandler(_ErrorTool(), _message),
        wrapInvokableToolWithErrorHandler(_ErrorTool(), _message),
        wrapStreamableToolWithErrorHandler(_ErrorTool(), _message),
      ]) {
        expect(await wrapped.info(), same(_info));
      }
    });
  });

  group('a call that succeeds', () {
    test('returns its result and never asks the handler', () async {
      var handled = 0;
      String counting(RunContext ctx, Object error) {
        handled++;
        return 'handled';
      }

      final invokable = wrapInvokableToolWithErrorHandler(
        _Invokable((ctx, args, options) async => 'result of $args'),
        counting,
      );
      expect(await invokable.invokableRun(ctx, 'a'), 'result of a');

      final streamable = wrapStreamableToolWithErrorHandler(
        _Streamable(
          (ctx, args, options) async => StreamReader.fromIterable(['x', 'y']),
        ),
        counting,
      );
      expect(
        await (await streamable.streamableRun(ctx, 'a')).collectAll(),
        ['x', 'y'],
      );

      expect(handled, 0);
    });

    test('context, arguments and options reach the wrapped tool', () async {
      final seen = <(RunContext, String, ToolOptions?)>[];
      const options = ToolOptions(extensions: ['an option']);
      final callContext = RunContext.background();

      final invokable = wrapInvokableToolWithErrorHandler(
        _Invokable((ctx, args, options) async {
          seen.add((ctx, args, options));
          return 'ok';
        }),
        _message,
      );
      await invokable.invokableRun(callContext, '{"a":1}', options: options);

      final streamable = wrapStreamableToolWithErrorHandler(
        _Streamable((ctx, args, options) async {
          seen.add((ctx, args, options));
          return StreamReader.fromIterable(['ok']);
        }),
        _message,
      );
      await (await streamable.streamableRun(callContext, '{"b":2}', options: options))
          .close();

      expect(seen, [
        (callContext, '{"a":1}', options),
        (callContext, '{"b":2}', options),
      ]);
    });
  });

  group('what the handler receives', () {
    test('the thrown object and the context of the call', () async {
      final error = StateError('precise');
      final callContext = RunContext.background();
      Object? seenError;
      RunContext? seenContext;

      final wrapped = wrapInvokableToolWithErrorHandler(
        _Invokable((ctx, args, options) async => throw error),
        (ctx, error) {
          seenContext = ctx;
          seenError = error;
          return 'handled';
        },
      );

      expect(await wrapped.invokableRun(callContext, ''), 'handled');
      expect(seenError, same(error));
      expect(seenContext, same(callContext));
    });

    test('errors as well as exceptions', () async {
      final wrapped = wrapInvokableToolWithErrorHandler(
        _Invokable((ctx, args, options) async => throw ArgumentError('bad')),
        (ctx, error) => 'handled ${error.runtimeType}',
      );
      expect(await wrapped.invokableRun(ctx, ''), 'handled ArgumentError');
    });

    test('arguments a function tool cannot decode', () async {
      final wrapped = wrapToolWithErrorHandler(
        FunctionTool<Map<String, Object?>, String>(
          name: 'strict',
          description: 'needs JSON',
          params: const ParamsOneOf.params({}),
          fromJson: (json) => json,
          invoke: (ctx, input, options) => 'ok',
        ),
        (ctx, error) =>
            error is ThreepioFormatException ? 'Bad arguments: ${error.message}' : 'other',
      ) as InvokableTool;

      expect(
        await wrapped.invokableRun(ctx, 'not json'),
        startsWith('Bad arguments: The arguments of tool "strict" are not valid JSON'),
      );
      expect(await wrapped.invokableRun(ctx, '{}'), 'ok');
    });

    test('a tool that fails synchronously instead of with a future', () async {
      final wrapped = wrapInvokableToolWithErrorHandler(
        _Invokable((ctx, args, options) => throw StateError('sync')),
        _message,
      );
      expect(await wrapped.invokableRun(ctx, ''), 'sync');
    });
  });

  group('the handler must not swallow an interrupt', () {
    test('an invokable tool that interrupts interrupts', () async {
      var handled = false;
      final wrapped = wrapToolWithErrorHandler(
        _Invokable((ctx, args, options) async => throw const _Interrupted()),
        (ctx, error) {
          handled = true;
          return 'swallowed';
        },
      ) as InvokableTool;

      await expectLater(
        wrapped.invokableRun(ctx, ''),
        throwsA(isA<InterruptSignal>()),
      );
      expect(handled, isFalse);
    });

    test('a streaming tool that interrupts interrupts', () async {
      var handled = false;
      final wrapped = wrapToolWithErrorHandler(
        _Streamable((ctx, args, options) async => throw const _Interrupted()),
        (ctx, error) {
          handled = true;
          return 'swallowed';
        },
      ) as StreamableTool;

      await expectLater(
        wrapped.streamableRun(ctx, ''),
        throwsA(isA<InterruptSignal>()),
      );
      expect(handled, isFalse);
    });

    test('an interrupt wrapped in another exception is not swallowed either',
        () async {
      // What a tool that runs a graph or another agent may throw.
      const wrapped = ThreepioException('inner graph stopped', cause: _Interrupted());
      var handled = false;
      String handler(RunContext ctx, Object error) {
        handled = true;
        return 'swallowed';
      }

      await expectLater(
        wrapInvokableToolWithErrorHandler(
          _Invokable((ctx, args, options) async => throw wrapped),
          handler,
        ).invokableRun(ctx, ''),
        throwsA(same(wrapped)),
      );
      await expectLater(
        wrapStreamableToolWithErrorHandler(
          _Streamable((ctx, args, options) async => throw wrapped),
          handler,
        ).streamableRun(ctx, ''),
        throwsA(same(wrapped)),
      );
      expect(handled, isFalse);
    });

    test('the same signal object arrives at the caller', () async {
      const signal = _Interrupted();
      final wrapped = wrapInvokableToolWithErrorHandler(
        _Invokable((ctx, args, options) async => throw signal),
        _message,
      );

      await expectLater(wrapped.invokableRun(ctx, ''), throwsA(same(signal)));
    });

    test('an interrupt in a stream that is already running is passed on',
        () async {
      final wrapped = wrapStreamableToolWithErrorHandler(
        _Streamable((ctx, args, options) async {
          final (reader, writer) = pipe<String>();
          writer
            ..send('partial')
            ..sendError(const _Interrupted())
            ..close();
          return reader;
        }),
        _message,
      );

      final stream = await wrapped.streamableRun(ctx, '');
      expect(await stream.recv(), 'partial');
      await expectLater(stream.recv(), throwsA(isA<InterruptSignal>()));
      await stream.close();
    });
  });

  group('a cancelled run is not reported to the model', () {
    test('what a tool throws after the context was cancelled is thrown on',
        () async {
      final token = CancelToken();
      final callContext = RunContext.background(cancelToken: token);
      var handled = false;

      final wrapped = wrapInvokableToolWithErrorHandler(
        _Invokable((ctx, args, options) async {
          token.cancel('user pressed stop');
          ctx.cancelToken.throwIfCancelled();
          return 'never';
        }),
        (ctx, error) {
          handled = true;
          return 'swallowed';
        },
      );

      await expectLater(
        wrapped.invokableRun(callContext, ''),
        throwsA(
          isA<CancelledException>()
              .having((e) => e.reason, 'reason', 'user pressed stop'),
        ),
      );
      expect(handled, isFalse);
    });

    test('the same holds for a streaming tool', () async {
      final token = CancelToken()..cancel();
      final wrapped = wrapStreamableToolWithErrorHandler(
        _Streamable((ctx, args, options) async => throw StateError('aborted')),
        _message,
      );

      await expectLater(
        wrapped.streamableRun(RunContext.background(cancelToken: token), ''),
        throwsStateError,
      );
    });

    test('a CancelledException of something else is an ordinary failure',
        () async {
      // The run itself goes on; an inner operation of the tool was cancelled.
      final wrapped = wrapInvokableToolWithErrorHandler(
        _Invokable(
          (ctx, args, options) async => throw const CancelledException('inner'),
        ),
        (ctx, error) => 'the tool gave up',
      );

      expect(await wrapped.invokableRun(ctx, ''), 'the tool gave up');
    });
  });

  group('older entry points', () {
    test('a tool that only overrides run() is wrapped like any other',
        () async {
      final wrapped = wrapToolWithErrorHandler(_LegacyFailing(), _message);

      expect(
        await (wrapped as InvokableTool).invokableRun(ctx, ''),
        'legacy failure',
      );
    });

    test('run() and streamRun() of the wrapper handle errors too', () async {
      final wrapped = wrapToolWithErrorHandler(_ErrorTool(), _message);

      expect(await (wrapped as InvokableTool).run(''), 'test error');
      final stream = await (wrapped as StreamableTool).streamRun('');
      expect(await stream.collectAll(), ['test stream error']);
    });

    test('a wrapped tool works in the tool executor', () async {
      final registry = ToolRegistry()
        ..register(wrapToolWithErrorHandler(_LegacyFailing(), _message));
      final executor = ToolExecutor(registry: registry);

      final result = await executor.executeToolCall(
        const ToolCall(
          id: 'call-1',
          function: FunctionCall(name: 'test_error_tool', arguments: '{}'),
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, 'legacy failure');
    });
  });
}
