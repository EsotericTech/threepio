// Mirror of doc/NEW_FEATURES.md, "5. Document Processing Pipeline > Ingestion Pipeline".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> ingestionPipeline(Embedder embedder, VectorStore vectorStore) async {
  // Create pipeline components
  final loader = DirectoryLoader(
    dirPath: '/path/to/documents',
    glob: '**/*.md', // understood: '*.txt', '*.md' and '*.*' patterns
    recursive: true,
  );

  final splitter = RecursiveCharacterTextSplitter();

  // Create pipeline: load, transform, split, embed, store
  final pipeline = IngestionPipeline(
    loader: loader,
    splitter: splitter,
    embedder: embedder,
    vectorStore: vectorStore,
    transformers: [
      // Clean content
      ContentCleanerTransformer(
        trimWhitespace: true,
        normalizeNewlines: true,
        removeEmptyLines: true,
      ),
      // Add metadata
      MetadataTransformer(metadata: {
        'ingested_at': DateTime.now().toIso8601String(),
        'source_kind': 'documentation',
      }),
      // Filter documents
      FilterTransformer(
        predicate: (doc) => doc.content.length > 50,
      ),
    ],
  );

  // Run ingestion
  final result = await pipeline.ingest(
    options: const IngestionOptions(
      batchSize: 100,
      splitterOptions: TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200),
      continueOnError: true,
      deduplicateByContent: true,
      maxDocuments: 1000,
    ),
  );

  print('Processed: ${result.documentsProcessed} documents');
  print('Created: ${result.chunksCreated} chunks');
  print('Stored: ${result.chunksStored} chunks');
  print('Duration: ${result.duration}');

  if (result.errors.isNotEmpty) {
    for (final error in result.errors) {
      print('Error in ${error.stage.name}: ${error.message}');
    }
  }
}
