// Mirrors "Agents" of doc/CALLBACKS.md.
// #docregion agent
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:threepio_core/adk.dart';

final log = Logger('app.agents');

/// Logs every agent run and the errors among its events.
ComponentCallbackHandler agentLogger() {
  final agents = typedAgentCallbackHandler(
    onStart: (ctx, info, input) {
      log.info('${info.name} starts with ${input?.input?.messages.length} '
          'messages (resumed: ${input?.resumeInfo != null})');
      return ctx;
    },
    onEnd: (ctx, info, output) {
      final events = output?.events;
      // The events arrive while the agent runs: read them in the background.
      if (events != null) unawaited(_logErrors(info.name, events));
      return ctx;
    },
  );
  return HandlerHelper().agent(agents).handler();
}

Future<void> _logErrors(String agent, StreamReader<AgentEvent> events) async {
  try {
    for (var event = await events.nextOrNull();
        event != null;
        event = await events.nextOrNull()) {
      if (event.error != null) log.warning('$agent: ${event.error}');
    }
  } finally {
    await events.close();
  }
}
// #enddocregion agent
