@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_flow_trace.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_handler.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_trace.dart';

import '../support/integration.dart';

/// A smoke test of `LangSmithHandler` and `LangSmithFlowTrace` against the
/// live LangSmith API.
///
/// It runs only when `THREEPIO_INTEGRATION=1` and `LANGSMITH_API_KEY` are set
/// in the environment (`LANGSMITH_ENDPOINT` is not read; the default API URL
/// is used):
///
/// ```sh
/// THREEPIO_INTEGRATION=1 LANGSMITH_API_KEY=… \
///   dart test -j 1 --tags integration test/integration/langsmith_integration_test.dart
/// ```
void main() {
  final apiKey = integrationApiKey(
    'LANGSMITH_API_KEY',
    suite: 'LangSmith Integration Tests',
  );
  if (apiKey == null) return;

  test('a flow span with a graph, a model and a tool beneath it is accepted',
      () async {
    final config = LangSmithConfig(apiKey: apiKey);
    final handler = LangSmithHandler(config);
    final flow = LangSmithFlowTrace(config);
    addTearDown(flow.close);

    final base = LangSmithTrace.set(
      RunContext.background().withHandlers([handler]),
      sessionName: 'threepio-integration',
      tags: ['threepio', 'integration'],
      metadata: {
        'metadata': {'suite': 'langsmith_integration_test'},
      },
    );
    final (spanCtx, spanId) = await flow.startSpan(base, 'threepio smoke test');

    final graph = await onStart(
      reuseHandlers(
        spanCtx,
        const RunInfo(
          name: 'graph',
          type: 'Graph',
          componentType: ComponentType.graph,
        ),
      ),
      'question',
    );
    final tool = await onStart(
      reuseHandlers(
        graph,
        const RunInfo(
          name: 'echo',
          type: 'Echo',
          componentType: ComponentType.tool,
        ),
      ),
      '{"text":"hi"}',
    );
    await onEnd(tool, 'hi');
    await onEnd(graph, 'answer');

    await handler.shutdown(timeout: const Duration(seconds: 30));
    await flow.finishSpan(spanCtx, spanId);

    expect(handler.failedRequests, 0);
    expect(handler.droppedRequests, 0);
  });
}
