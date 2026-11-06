// Mirrors "Legacy API (before 0.9)" of doc/CALLBACKS.md. The deprecated
// names produce deprecated_member_use infos here; that is expected.
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:threepio_core/callbacks.dart';

final log = Logger('app.callbacks');

// #docregion legacy-handler
/// A handler of the older API: a map for context, wrapped payloads.
class StartLogger extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    log.info('${info.name} <- ${input.data}');
    return {...context, 'started': DateTime.now()};
  }
}
// #enddocregion legacy-handler

Future<String> legacyManager(String text) async {
  // #docregion manager
  final manager = CallbackManager([StartLogger(), LoggingHandler()]);
  final summary = await manager.runWithCallbacks(
    <String, dynamic>{},
    const RunInfo(
      name: 'summarize',
      type: 'Summarizer',
      componentType: ComponentType.custom,
    ),
    text,
    () async => text.substring(0, text.length.clamp(0, 80)),
  );
  // #enddocregion manager
  return summary;
}

RunContext adapted() {
  // #docregion adapter
  // An existing handler in a run of the new kind.
  final ctx = RunContext.background().withHandlers([
    LegacyCallbackHandlerAdapter(StartLogger()),
    LegacyCallbackHandlerAdapter(MetricsHandler()),
  ]);
  // #enddocregion adapter
  return ctx;
}

// #docregion migrated
/// The same handler on the new API.
final class StartLoggerV2 extends ComponentCallbackHandler {
  static const _started = ContextKey<DateTime>('start_logger.started');

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    log.info('${info.name} <- $input');
    return ctx.withValue(_started, DateTime.now());
  }
}
// #enddocregion migrated

void listen() {
  // #docregion logging
  // LoggingHandler, MetricsHandler.printSummary and TracingHandler.printTrace
  // write to package:logging (threepio.callbacks.*), not to the console.
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) => stdout.writeln(record.message));
  // #enddocregion logging
}
