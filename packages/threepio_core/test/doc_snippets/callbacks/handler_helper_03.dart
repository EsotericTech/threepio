// Mirrors "Typed payloads: HandlerHelper" of doc/CALLBACKS.md.
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:threepio_core/callbacks.dart';

final log = Logger('app.callbacks');

ComponentCallbackHandler typed() {
  // #docregion helper
  // Go: utils/callbacks.NewHandlerHelper().ChatModel(...).Tool(...).Handler().
  final handler = HandlerHelper()
      .chatModel(
        ModelCallbackHandler(
          onEnd: (ctx, info, output) {
            log.info('tokens: ${output?.tokenUsage?.totalTokens}');
            return ctx;
          },
          // A streamed answer. Read it in the background and return; the
          // stream is this handler's own copy and is closed by asStream.
          onEndWithStreamOutput: (ctx, info, chunks) {
            unawaited(
              chunks.asStream().fold<int>(0, (count, _) => count + 1).then(
                    (count) => log.info('${info.name}: $count chunks'),
                    onError: (Object error) => log.warning('$error'),
                  ),
            );
            return ctx;
          },
        ),
      )
      .tool(
        ToolCallbackHandler(
          onStart: (ctx, info, input) {
            log.info('${info.name}(${input?.argumentsJson})');
            return ctx;
          },
        ),
      )
      .retriever(
        RetrieverCallbackHandler(
          onEnd: (ctx, info, output) {
            log.info('${output?.docs.length} documents');
            return ctx;
          },
        ),
      )
      // Graphs, chains and lambdas have no payload type of their own.
      .graph(
        CallbackHandlerBuilder().onEnd((ctx, info, output) {
          log.info('graph ${info.name} done');
          return ctx;
        }).build(),
      )
      .handler();
  // #enddocregion helper
  return handler;
}
