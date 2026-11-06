// Mirror of doc/NEW_FEATURES.md, "5. Document Processing Pipeline > Streaming Ingestion with Progress".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> ingestionProgress(IngestionPipeline pipeline) async {
  final progressStream = pipeline.ingestStream(
    options: const IngestionOptions(batchSize: 50),
  );

  await for (final progress in progressStream) {
    print('${progress.stage.name}: ${progress.current}/${progress.total}');
    print('  ${progress.message}');
    print('  Progress: ${progress.percentage.toStringAsFixed(1)}%');

    if (progress.stage == IngestionStage.complete) {
      print('Ingestion complete!');
    }
  }
}
