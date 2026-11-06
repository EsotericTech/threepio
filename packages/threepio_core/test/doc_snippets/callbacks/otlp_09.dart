// Mirrors "OpenTelemetry" of doc/CALLBACKS.md.
import 'package:threepio_core/callbacks.dart';

LangfuseHandler withCollector() {
  // #docregion otlp
  // Spans over OTLP/HTTP (JSON) to any collector.
  final exporter = OtlpHttpTraceExporter(
    OtlpExporterConfig(
      endpoint: Uri.parse('http://localhost:4318/v1/traces'),
      serviceName: 'my-app',
    ),
  );

  // The Langfuse handler can send its spans there instead of to Langfuse;
  // its shutdown then flushes the exporter and leaves closing it to you.
  final handler = LangfuseHandler(const LangfuseConfig(), exporter: exporter);
  // #enddocregion otlp
  return handler;
}
