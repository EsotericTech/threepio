@Tags(['integration'])
library;

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/threepio_core.dart';

import '../support/integration.dart';

/// A live check that a Langfuse project accepts what [LangfuseHandler]
/// exports (OTLP/HTTP with JSON bodies), the open question of P3 (coordinator
/// decision 1 after P3).
///
/// It runs only when `THREEPIO_INTEGRATION=1`, `LANGFUSE_PUBLIC_KEY` and
/// `LANGFUSE_SECRET_KEY` are set; `LANGFUSE_HOST` defaults to
/// `https://cloud.langfuse.com`:
///
/// ```sh
/// THREEPIO_INTEGRATION=1 LANGFUSE_PUBLIC_KEY=pk-lf-… LANGFUSE_SECRET_KEY=sk-lf-… \
///   dart test -j 1 --tags integration test/integration/langfuse_integration_test.dart
/// ```
///
/// The test passes when the export is accepted: no span is lost and nothing
/// is logged at `WARNING` or above on `threepio.observability` (a refused
/// batch is `SEVERE`, spans refused in a partial success and every other
/// loss are `WARNING`s of the handler or the exporter). Look for the trace
/// named `threepio-integration-<time>` in the project afterwards to check how
/// it is shown.
void main() {
  final publicKey = integrationApiKey(
    'LANGFUSE_PUBLIC_KEY',
    suite: 'Langfuse Integration Tests',
  );
  if (publicKey == null) return;
  final secretKey = Platform.environment['LANGFUSE_SECRET_KEY'] ?? '';
  if (secretKey.isEmpty) {
    test('Langfuse Integration Tests', () {},
        skip: 'LANGFUSE_SECRET_KEY is not set');
    return;
  }
  final host =
      Platform.environment['LANGFUSE_HOST'] ?? 'https://cloud.langfuse.com';

  group('Langfuse Integration Tests', () {
    test('a trace with a model generation is accepted', () async {
      final problems = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen((record) {
        if (record.level >= Level.WARNING &&
            record.loggerName.startsWith('threepio.observability')) {
          problems.add(record);
        }
      });
      addTearDown(subscription.cancel);

      final handler = LangfuseHandler(
        LangfuseConfig(
          host: host,
          publicKey: publicKey,
          secretKey: secretKey,
          environment: 'threepio-integration',
        ),
      );
      final name =
          'threepio-integration-${DateTime.now().toUtc().toIso8601String()}';
      final root = handler.startTrace(
        RunContext.background().withHandlers([handler]),
        name: name,
        input: 'What is 2 + 2?',
        tags: const ['threepio', 'integration'],
      );

      var ctx = ensureRunInfo(root, 'Fake', ComponentType.chatModel);
      ctx = await onStart(
        ctx,
        ModelCallbackInput(
          messages: [Message.user('What is 2 + 2?')],
          config: const ModelCallbackConfig(model: 'fake-model'),
        ),
      );
      await onEnd(
        ctx,
        ModelCallbackOutput(
          message: Message.assistant('4'),
          tokenUsage: const TokenUsage(
            promptTokens: 7,
            completionTokens: 1,
            totalTokens: 8,
          ),
        ),
      );
      handler.endTrace(root, '4');
      await handler.shutdown(timeout: const Duration(seconds: 20));

      expect(handler.losses, isEmpty, reason: 'spans were dropped');
      expect(
        problems.map((r) => '${r.loggerName}: ${r.message}'),
        isEmpty,
        reason: 'the export was refused',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
