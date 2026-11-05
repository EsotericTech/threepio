// What `package:threepio_core/callbacks.dart` and the umbrella library
// export, and what they leave out on purpose.
// The older callback API is part of what is checked here.
// ignore_for_file: deprecated_member_use
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/threepio_core.dart';

/// The situation the umbrella has to keep working: a class that inherits
/// `onStart`, `onEnd` and `onError` and calls them without `this.`. An
/// imported top-level function of the same name would take precedence over
/// the inherited member, and these calls would no longer compile (or, worse,
/// call something else).
abstract class _Base {
  final List<String> calls = [];

  void onStart(String what) => calls.add('start $what');
  void onEnd(String what) => calls.add('end $what');
  void onError(Object error) => calls.add('error $error');
}

class _Sub extends _Base {
  void run() {
    onStart('a');
    onEnd('a');
    onError('boom');
  }
}

/// A handler of the older API, written like the ones in the applications.
class _LegacyHandler extends BaseCallbackHandler {
  int starts = 0;

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    starts++;
    return context;
  }
}

void main() {
  test('the umbrella does not shadow inherited onStart, onEnd and onError',
      () {
    final sub = _Sub()..run();
    expect(sub.calls, ['start a', 'end a', 'error boom']);
  });

  test('the umbrella exports the new callback API', () {
    expect(const <ComponentCallbackHandler>[], isEmpty);
    expect(CallbackTiming.values, hasLength(5));
    expect(CallbackHandlerBuilder().build(), isA<TimingChecker>());
    expect(HandlerHelper().handler(), isA<ComponentCallbackHandler>());
    expect(GlobalCallbacks.handlers, isEmpty);
    expect(
      const LegacyCallbackHandlerAdapter(LoggingHandler()),
      isA<ComponentCallbackHandler>(),
    );
    expect(RunContext.background().hasCallbacks, isFalse);
    expect(RunContext.background().withHandlers(const []).runInfo, isNull);
    expect(ensureRunInfo, isA<Function>());
    expect(initCallbacks, isA<Function>());
    expect(reuseHandlers, isA<Function>());
    expect(appendHandlers, isA<Function>());
    expect(const ModelCallbackHandler(), isA<TypedCallbackHandler>());
    expect(const ToolsNodeCallbackHandlers().needed(CallbackTiming.onEnd), isFalse);
  });

  test('the umbrella exports tracing', () {
    expect(const LangfuseConfig().host, isEmpty);
    expect(LangfuseObservationType.generation.name, 'generation');
    expect(LangfuseHandler.instrumentationName, isNotEmpty);
    expect(const OtlpRetryConfig().enabled, isTrue);
    expect(OtlpHttpTraceExporter.queueFull, isNotEmpty);
    expect(SpanQueue().isEmpty, isTrue);
    expect(isTraceSampled('a' * 32, 1), isTrue);
    expect(const OtlpStatus().code, OtlpStatusCode.unset);
    expect(OtlpSpanKind.internal.index, 1);
    expect(const OtlpExportException('x'), isA<ThreepioException>());
  });

  test('the umbrella still exports the older callback API', () async {
    final handler = _LegacyHandler();
    final manager = CallbackManager([handler]);
    const info = RunInfo(
      name: 'n',
      type: 't',
      componentType: ComponentType.chain,
    );

    await manager.triggerStart({}, info, const CallbackInput('x'));
    await manager.triggerEnd({}, info, const CallbackOutput('y'));
    await manager.triggerError({}, info, 'e', StackTrace.empty);
    await manager.runWithCallbacks({}, info, 'in', () async => 'out');

    expect(handler.starts, 2);
    expect(handler, isA<CallbackHandler>());
    expect(const LoggingHandler(), isA<BaseCallbackHandler>());
    expect(MetricsHandler().metrics, isEmpty);
    expect(TracingHandler().events, isEmpty);
    expect(CallbackException('x'), isA<ThreepioException>());
  });

  test('callbacks.dart has the functions a component fires its callbacks with',
      () async {
    final ctx = RunContext.background();
    expect(await callbacks.onStart(ctx, 1), same(ctx));
    expect(await callbacks.onEnd(ctx, 1), same(ctx));
    expect(await callbacks.onError(ctx, 'e', StackTrace.empty), same(ctx));

    final input = StreamReader.fromIterable([1]);
    expect((await callbacks.onStartWithStreamInput(ctx, input)).$2, same(input));
    final output = StreamReader.fromIterable([1]);
    expect((await callbacks.onEndWithStreamOutput(ctx, output)).$2, same(output));
    expect(
      await callbacks.onEndWithCopies<int>(ctx, 1, (value, n) => const []),
      same(ctx),
    );
  });

  test('callbacks.dart exports everything the umbrella does, and RunContext',
      () {
    expect(callbacks.GlobalCallbacks.handlers, isEmpty);
    expect(callbacks.CallbackHandlerBuilder().build(), isNotNull);
    expect(callbacks.RunContext.background(), isA<RunContext>());
    expect(callbacks.RunInfo.unknown.isUnknown, isTrue);
    expect(callbacks.ComponentType.chatModel.einoName, 'ChatModel');
    expect(callbacks.CallbackManager().handlers, isEmpty);
    expect(const callbacks.LangfuseConfig(), isA<LangfuseConfig>());
  });
}
