// Mirror of doc/MIGRATION.md, legacy: ComponentCallbackHandler (after).
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

const _started = ContextKey<DateTime>('timing.started');

/// Prints how long each component takes.
class TimingHandler extends ComponentCallbackHandler {
  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) =>
      ctx.withValue(_started, DateTime.now());

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    final started = ctx.value(_started);
    if (started != null) {
      print('${info.name} took ${DateTime.now().difference(started)}');
    }
    return ctx;
  }
}

Future<Message> ask(BaseChatModel model) => model.generate(
      [Message.user('Hello')],
      options: ChatModelOptions(
        runContext: RunContext.background().withHandlers([TimingHandler()]),
      ),
    );
