// Mirror of doc/MIGRATION.md, break 6: deprecations.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

/// A handler written for the older API keeps working …
class PrintingHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    print('start ${info.name}');
    return context;
  }
}

/// … and joins a run of the new kind through the adapter.
RunContext contextWithLegacyHandler() => RunContext.background()
    .withHandlers([LegacyCallbackHandlerAdapter(PrintingHandler())]);
