// Mirrors "Other exporters and collectors" of doc/LANGFUSE_DESIGN.md.
import 'package:threepio_core/callbacks.dart';

/// Keeps the spans in memory, for a test or a debug screen.
final class MemorySpanExporter implements SpanExporter {
  final spans = <OtlpSpan>[];

  @override
  bool add(OtlpSpan span) {
    spans.add(span);
    return true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}

Future<LangfuseHandler> exporters() async {
  final memory = MemorySpanExporter();
  final inMemory = LangfuseHandler(const LangfuseConfig(), exporter: memory);

  final collector = OtlpHttpTraceExporter(
    OtlpExporterConfig(
      endpoint: Uri.parse('http://localhost:4318/v1/traces'),
      serviceName: 'my-app',
    ),
  );
  final toCollector = LangfuseHandler(const LangfuseConfig(), exporter: collector);
  // ... run ...
  await toCollector.shutdown(); // flushes the collector exporter
  await collector.shutdown(); // the caller shuts it down
  return inMemory;
}
