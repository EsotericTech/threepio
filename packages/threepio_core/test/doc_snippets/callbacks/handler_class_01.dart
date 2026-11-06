// Mirrors "Extend ComponentCallbackHandler" of doc/CALLBACKS.md.
// #docregion class
import 'package:logging/logging.dart';
import 'package:threepio_core/callbacks.dart';

final log = Logger('app.callbacks');

/// Logs how long every component takes.
final class Stopwatches extends ComponentCallbackHandler
    implements TimingChecker {
  static const _started = ContextKey<DateTime>('stopwatches.started');

  // Only the start and end callbacks: no stream copies are made for it.
  @override
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing) =>
      timing == CallbackTiming.onStart || timing == CallbackTiming.onEnd;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) =>
      ctx.withValue(_started, DateTime.now());

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    final started = ctx.value(_started);
    if (started != null) {
      final took = DateTime.now().difference(started);
      log.info('${info.componentType.einoName} ${info.name}: $took');
    }
    return ctx;
  }
}
// #enddocregion class
