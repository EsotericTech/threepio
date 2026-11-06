// Mirrors "Using handlers" of doc/CALLBACKS.md.
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';

Future<void> useHandlers(
  BaseChatModel model,
  Runnable<String, Message> runnable,
  ComponentCallbackHandler handler,
) async {
  // #docregion run
  // Every component called with this context reports to the handler.
  final ctx = RunContext.background().withHandlers([handler]);

  // A component called on its own gets the context through its options.
  await model.generate(
    [Message.user('Hello')],
    options: ChatModelOptions(runContext: ctx),
  );

  // A compiled graph takes it as the context of the run...
  await runnable.invoke(ctx, 'Hello');

  // ...or takes handlers as a call option, which can be aimed at a node.
  await runnable.invoke(
    RunContext.background(),
    'Hello',
    options: [
      CallOption.callbacks([handler]).designateNode(['model']),
    ],
  );
  // #enddocregion run
}

void global(ComponentCallbackHandler tracing) {
  // #docregion global
  // Go: callbacks.AppendGlobalHandlers. Once, when the application starts.
  GlobalCallbacks.append([tracing]);

  // Global state: take it out again where that matters (tests).
  GlobalCallbacks.remove(tracing);
  // #enddocregion global
}
