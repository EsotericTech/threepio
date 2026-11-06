// LangfuseHandler and the agentic ADK: a real `AgenticChatModelAgent` run
// through an `AgenticRunner` is traced as an agent observation that ends
// with the messages of its events, with the generation of its agentic model
// beneath it (port of eino-ext langfuse v2 `endAgentOutput` for
// `ComponentOfAgenticAgent`, `collectAgenticMessages` and the agentic model
// branch of `isGeneration`). The handler reads its own copy of the events:
// the caller still gets every event and every streamed chunk.
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/callbacks.dart'
    show
        CallbackContext,
        GlobalCallbacks,
        LangfuseConfig,
        LangfuseHandler,
        OtlpSpan,
        OtlpStatusCode,
        SpanExporter;

import '../../support/log_capture.dart';

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

  OtlpSpan ofType(String type, String name) => spans.singleWhere(
        (span) =>
            span.name == name &&
            span.attributes['langfuse.observation.type'] == type,
      );

  List<OtlpSpan> generations() => [
        for (final span in spans)
          if (span.attributes['langfuse.observation.type'] == 'generation') span,
      ];
}

/// An agentic model that answers every call with the same chunks; a
/// generation joins them.
final class _ScriptedAgenticModel implements AgenticModel {
  _ScriptedAgenticModel(this.chunks);

  final List<AgenticMessage> chunks;
  final List<List<AgenticMessage>> inputs = [];

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    inputs.add(input);
    return concatAgenticMessages(chunks);
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    inputs.add(input);
    return StreamReader.fromIterable(chunks);
  }
}

AgenticMessage _chunk(String text, {TokenUsage? usage}) => AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(
          AssistantGenText(text: text),
          streamingMeta: const StreamingMeta(index: 0),
        ),
      ],
      responseMeta: usage == null ? null : AgenticResponseMeta(tokenUsage: usage),
    );

Object? _json(OtlpSpan span, String key) => jsonDecode(span.attributes[key]! as String);

String _text(Object? messageJson) {
  final blocks = (messageJson! as Map)['content_blocks']! as List<Object?>;
  return [
    for (final block in blocks)
      ((block! as Map)['assistant_gen_text']! as Map)['text'],
  ].join();
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  for (final streaming in [false, true]) {
    test('an agentic agent run is an agent observation with its generation '
        'beneath it (streaming: $streaming)', () async {
      final exporter = _MemoryExporter();
      final handler = LangfuseHandler(
        const LangfuseConfig(collapseAgentInternalSpans: true),
        exporter: exporter,
        random: Random(1),
      );
      final model = _ScriptedAgenticModel([
        _chunk('Hel'),
        _chunk(
          'lo',
          usage: const TokenUsage(promptTokens: 7, completionTokens: 2, totalTokens: 9),
        ),
      ]);
      final agent = AgenticChatModelAgent(
        AgenticChatModelAgentConfig(name: 'assistant', model: model, instruction: 'Be brief.'),
      );
      final ctx = handler.startTrace(
        RunContext.background().withHandlers([handler]),
        name: 'run',
      );

      final events = await AgenticRunner(agent: agent, enableStreaming: streaming)
          .query(ctx, 'hi')
          .collectAll();
      final answers = [
        for (final event in events)
          if (event.output?.messageOutput case final variant?) await variant.getMessage(),
      ];
      handler.endTrace(ctx);
      await handler.flush();

      expect(events.map((event) => event.error), everyElement(isNull));
      expect(answers, hasLength(1), reason: 'the caller gets the whole answer');
      expect(
        answers.single.contentBlocks.map((block) => block.assistantGenText?.text).join(),
        'Hello',
      );

      final agentSpan = exporter.ofType('agent', 'assistant');
      expect(agentSpan.status.code, OtlpStatusCode.unset);
      expect(agentSpan.attributes['langfuse.observation.metadata.eino_component'], 'AgenticAgent');
      final output = _json(agentSpan, 'langfuse.observation.output')! as Map;
      expect(_text(output['messages']), 'Hello');
      final input = _json(agentSpan, 'langfuse.observation.input')! as Map;
      expect((input['input']! as Map)['enableStreaming'], streaming);

      final generation = exporter.generations().single;
      expect(generation.attributes['langfuse.observation.metadata.eino_component'], 'AgenticModel');
      expect(generation.parentSpanId, agentSpan.spanId, reason: 'the machinery is collapsed');
      expect(_text(_json(generation, 'langfuse.observation.output')), 'Hello');
      final modelInput = _json(generation, 'langfuse.observation.input')! as List<Object?>;
      expect(modelInput.map((message) => (message! as Map)['role']), ['system', 'user']);
      expect(generation.attributes['gen_ai.usage.input_tokens'], 7);
      expect(generation.attributes['gen_ai.usage.output_tokens'], 2);
      expect(
        generation.attributes.containsKey('langfuse.observation.completion_start_time'),
        streaming,
      );

      final root = exporter.ofType('span', 'run');
      expect(root.status.code, OtlpStatusCode.unset);
      expect(_json(root, 'langfuse.observation.output'), output);
    });
  }
}
