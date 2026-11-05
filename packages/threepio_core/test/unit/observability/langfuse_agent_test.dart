// LangfuseHandler and the Eino-shaped ADK: the observation of an agent ends
// with what its events carried (port of eino-ext langfuse v2
// `endAgentOutput`, `collectAgentMessages`, `recordAgentError`).
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/callbacks.dart' show LangfuseConfig, LangfuseHandler, OtlpSpan, SpanExporter, CallbackContext;

import '../../support/scripted_chat_model.dart';

final class _MemoryExporter implements SpanExporter {
  final List<OtlpSpan> spans = [];

  @override
  bool add(OtlpSpan span) {
    spans.add(span);
    return true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}

  /// The agent's observation (its chain has the same name, as in eino).
  OtlpSpan agent(String name) => spans.singleWhere(
        (span) =>
            span.name == name &&
            span.attributes['langfuse.observation.type'] == 'agent',
      );
}

Object? _json(OtlpSpan span, String key) => jsonDecode(span.attributes[key]! as String);

void main() {
  test('the agent observation ends with the messages of its events', () async {
    final exporter = _MemoryExporter();
    final handler = LangfuseHandler(const LangfuseConfig(), exporter: exporter, random: Random(1));
    final model = ScriptedChatModel([
      [text('Hello'), finish('stop')],
    ]);
    final agent = ChatModelAgent(ChatModelAgentConfig(name: 'assistant', model: model));
    final ctx = handler.startTrace(RunContext.background().withHandlers([handler]), name: 'run');
    final events = await Runner(agent: agent, enableStreaming: true).query(ctx, 'hi').collectAll();
    for (final event in events) {
      await getMessageFromEvent(event);
    }
    handler.endTrace(ctx);
    await handler.flush();

    final span = exporter.agent('assistant');
    expect(span.attributes['langfuse.observation.type'], 'agent');
    final output = _json(span, 'langfuse.observation.output')! as Map<String, Object?>;
    expect((output['messages']! as Map)['content'], 'Hello');
    expect(span.attributes.containsKey('langfuse.observation.metadata.eino_retry_event_count'), isFalse);
  });

  test('a retried model stream is a retry notification, not a failure', () async {
    final exporter = _MemoryExporter();
    final handler = LangfuseHandler(const LangfuseConfig(), exporter: exporter, random: Random(1));
    final model = ScriptedChatModel.turns([
      ScriptedTurn([text('Hel')], error: const FormatException('reset')),
      ScriptedTurn([text('Hello'), finish('stop')]),
    ]);
    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'assistant',
      model: model,
      modelRetryConfig: ModelRetryConfig(maxRetries: 1, backoff: (_, __) => Duration.zero),
    ));
    final ctx = handler.startTrace(RunContext.background().withHandlers([handler]), name: 'run');
    final events = await Runner(agent: agent, enableStreaming: true).query(ctx, 'hi').collectAll();
    expect(events.map((e) => e.error), everyElement(isNull));
    handler.endTrace(ctx);
    await handler.flush();

    final span = exporter.agent('assistant');
    expect(span.attributes['langfuse.observation.metadata.eino_retry_event_count'], 1);
    final retries = _json(span, 'langfuse.observation.metadata.eino_retry_events')! as List<Object?>;
    final retry = retries.single! as Map<String, Object?>;
    expect(retry['operation'], 'agent message');
    expect(retry['attempt'], 0);
    expect(retry['error'], contains('reset'));
    expect(span.attributes['langfuse.observation.level'], isNull, reason: 'not an error');
    final output = _json(span, 'langfuse.observation.output')! as Map<String, Object?>;
    expect((output['messages']! as Map)['content'], 'Hello');
  });
}
