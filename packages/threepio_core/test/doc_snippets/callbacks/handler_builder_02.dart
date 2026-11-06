// Mirrors "Handlers from functions" of doc/CALLBACKS.md.
import 'package:logging/logging.dart';
import 'package:threepio_core/callbacks.dart';

final log = Logger('app.callbacks');

ComponentCallbackHandler built() {
  // #docregion builder
  // Go: callbacks.NewHandlerBuilder().OnStartFn(...).OnErrorFn(...).Build().
  final handler = CallbackHandlerBuilder()
      .onStart((ctx, info, input) {
        log.info('${info.name} starts');
        return ctx;
      })
      .onError((ctx, info, error, stackTrace) {
        log.warning('${info.name} failed', error, stackTrace);
        return ctx;
      })
      .build();
  // #enddocregion builder
  return handler;
}
