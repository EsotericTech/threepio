// Mirror of doc/MIGRATION.md, "Callbacks": firing callbacks.
// ignore_for_file: avoid_print
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/threepio_core.dart';

/// A component of your own that reports its work to the run's handlers.
Future<String> shout(RunContext callerCtx, String text) async {
  var ctx = ensureRunInfo(callerCtx, 'Shout', ComponentType.lambda);
  ctx = await callbacks.onStart(ctx, text);
  try {
    final output = text.toUpperCase();
    await callbacks.onEnd(ctx, output);
    return output;
  } catch (error, stackTrace) {
    await callbacks.onError(ctx, error, stackTrace);
    rethrow;
  }
}
