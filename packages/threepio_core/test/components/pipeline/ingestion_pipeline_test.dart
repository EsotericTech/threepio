import 'package:test/test.dart';
import 'package:threepio_core/src/components/pipeline/ingestion_pipeline.dart';
import 'package:threepio_core/src/components/text_splitter/recursive_character_text_splitter.dart';
import 'package:threepio_core/src/components/text_splitter/text_splitter.dart';
import 'package:threepio_core/src/schema/document.dart';

void main() {
  group('IngestionPipeline', () {
    test('processes documents without loader', () async {
      final pipeline = IngestionPipeline(
        splitter: RecursiveCharacterTextSplitter(),
      );

      final docs = [
        Document(content: 'Document 1 content here.'),
        Document(content: 'Document 2 content here.'),
      ];

      final result = await pipeline.ingest(documents: docs);

      expect(result.documentsProcessed, 2);
      expect(result.chunksCreated, greaterThanOrEqualTo(2));
      expect(result.errors, isEmpty);
    });

    test('applies splitter options', () async {
      final pipeline = IngestionPipeline(
        splitter: RecursiveCharacterTextSplitter(),
      );

      // Create a document that will be split
      final longContent = 'A' * 200 + ' ' + 'B' * 200 + ' ' + 'C' * 200;
      final docs = [Document(content: longContent)];

      final result = await pipeline.ingest(
        documents: docs,
        options: const IngestionOptions(
          splitterOptions: TextSplitterOptions(
            chunkSize: 100,
            chunkOverlap: 20,
          ),
        ),
      );

      expect(result.documentsProcessed, 1);
      expect(result.chunksCreated, greaterThan(1));
    });

    test('adds metadata to documents', () async {
      final pipeline = IngestionPipeline(
        splitter: RecursiveCharacterTextSplitter(),
      );

      final docs = [Document(content: 'Test content')];

      final result = await pipeline.ingest(
        documents: docs,
        options: const IngestionOptions(
          metadata: {'source': 'test', 'version': '1.0'},
        ),
      );

      expect(result.chunksCreated, 1);
      expect(result.metadata?['deduplicated'], isFalse);
    });

    test('limits documents when maxDocuments is set', () async {
      final pipeline = IngestionPipeline();

      final docs = List.generate(
        10,
        (i) => Document(content: 'Document $i'),
      );

      final result = await pipeline.ingest(
        documents: docs,
        options: const IngestionOptions(maxDocuments: 3),
      );

      expect(result.documentsProcessed, 3);
    });

    test('deduplicates by content when enabled', () async {
      final pipeline = IngestionPipeline();

      final docs = [
        const Document(content: 'Same content'),
        const Document(content: 'Same content'),
        const Document(content: 'Different content'),
      ];

      final result = await pipeline.ingest(
        documents: docs,
        options: const IngestionOptions(deduplicateByContent: true),
      );

      expect(result.chunksCreated, 2); // Duplicates removed
    });

    test('returns duration in result', () async {
      final pipeline = IngestionPipeline();

      final docs = [const Document(content: 'Test')];

      final result = await pipeline.ingest(documents: docs);

      expect(result.duration, isNotNull);
      expect(result.duration!.inMilliseconds, greaterThanOrEqualTo(0));
    });
  });

  group('IngestionProgress', () {
    test('calculates percentage correctly', () {
      const progress = IngestionProgress(
        stage: IngestionStage.splitting,
        current: 50,
        total: 100,
      );

      expect(progress.percentage, 50.0);
    });

    test('handles zero total', () {
      const progress = IngestionProgress(
        stage: IngestionStage.splitting,
        current: 0,
        total: 0,
      );

      expect(progress.percentage, 0.0);
    });
  });

  group('IngestionResult', () {
    test('toString provides summary', () {
      const result = IngestionResult(
        documentsProcessed: 10,
        chunksCreated: 50,
        chunksStored: 45,
        errors: [],
      );

      final str = result.toString();
      expect(str, contains('10'));
      expect(str, contains('50'));
      expect(str, contains('45'));
    });
  });

  group('IngestionError', () {
    test('toString includes stage and message', () {
      const error = IngestionError(
        stage: IngestionStage.embedding,
        message: 'API error',
        documentId: 'doc-123',
      );

      final str = error.toString();
      expect(str, contains('embedding'));
      expect(str, contains('API error'));
      expect(str, contains('doc-123'));
    });
  });

  group('DocumentTransformers', () {
    group('MetadataTransformer', () {
      test('adds metadata to all documents', () async {
        final transformer = MetadataTransformer(
          metadata: {'added': true, 'source': 'transformer'},
        );

        final docs = [
          const Document(content: 'Doc 1'),
          const Document(content: 'Doc 2'),
        ];

        final result = await transformer.transform(docs);

        expect(result.every((d) => d.metadata['added'] == true), isTrue);
        expect(result.every((d) => d.metadata['source'] == 'transformer'), isTrue);
      });

      test('preserves existing metadata without overwrite', () async {
        final transformer = MetadataTransformer(
          metadata: {'key': 'new'},
          overwrite: false,
        );

        final docs = [
          const Document(content: 'Doc', metadata: {'key': 'original'}),
        ];

        final result = await transformer.transform(docs);

        expect(result.first.metadata['key'], 'original');
      });

      test('overwrites existing metadata when configured', () async {
        final transformer = MetadataTransformer(
          metadata: {'key': 'new'},
          overwrite: true,
        );

        final docs = [
          const Document(content: 'Doc', metadata: {'key': 'original'}),
        ];

        final result = await transformer.transform(docs);

        expect(result.first.metadata['key'], 'new');
      });
    });

    group('FilterTransformer', () {
      test('filters documents by predicate', () async {
        final transformer = FilterTransformer(
          predicate: (doc) => doc.content.length > 10,
        );

        final docs = [
          const Document(content: 'Short'),
          const Document(content: 'This is a longer document'),
          const Document(content: 'Tiny'),
        ];

        final result = await transformer.transform(docs);

        expect(result.length, 1);
        expect(result.first.content, 'This is a longer document');
      });

      test('filters by metadata', () async {
        final transformer = FilterTransformer(
          predicate: (doc) => doc.metadata['include'] == true,
        );

        final docs = [
          const Document(content: 'A', metadata: {'include': true}),
          const Document(content: 'B', metadata: {'include': false}),
          const Document(content: 'C', metadata: {'include': true}),
        ];

        final result = await transformer.transform(docs);

        expect(result.length, 2);
      });
    });

    group('ContentCleanerTransformer', () {
      test('trims whitespace by default', () async {
        final transformer = ContentCleanerTransformer();

        final docs = [
          const Document(content: '  content with spaces  '),
        ];

        final result = await transformer.transform(docs);

        expect(result.first.content, 'content with spaces');
      });

      test('normalizes newlines', () async {
        final transformer = ContentCleanerTransformer(normalizeNewlines: true);

        final docs = [
          const Document(content: 'Line 1\r\nLine 2\rLine 3'),
        ];

        final result = await transformer.transform(docs);

        expect(result.first.content, 'Line 1\nLine 2\nLine 3');
      });

      test('removes empty lines when configured', () async {
        final transformer = ContentCleanerTransformer(removeEmptyLines: true);

        final docs = [
          const Document(content: 'Line 1\n\nLine 2\n\n\nLine 3'),
        ];

        final result = await transformer.transform(docs);

        expect(result.first.content, 'Line 1\nLine 2\nLine 3');
      });

      test('limits consecutive newlines', () async {
        final transformer = ContentCleanerTransformer(maxConsecutiveNewlines: 2);

        final docs = [
          const Document(content: 'A\n\n\n\n\nB'),
        ];

        final result = await transformer.transform(docs);

        expect(result.first.content, 'A\n\nB');
      });
    });
  });

  group('Pipeline with transformers', () {
    test('applies transformers in order', () async {
      final pipeline = IngestionPipeline(
        transformers: [
          MetadataTransformer(metadata: {'step': 1}),
          FilterTransformer(predicate: (doc) => doc.content.length > 5),
          MetadataTransformer(metadata: {'step': 2}, overwrite: true),
        ],
      );

      final docs = [
        const Document(content: 'Short'),
        const Document(content: 'This is long enough'),
      ];

      final result = await pipeline.ingest(documents: docs);

      expect(result.documentsProcessed, 2);
      expect(result.chunksCreated, 1); // Filter removed 'Short'
    });
  });
}
