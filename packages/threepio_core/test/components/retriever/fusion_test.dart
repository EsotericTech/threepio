import 'package:test/test.dart';
import 'package:threepio_core/src/components/retriever/fusion/deduplication.dart';
import 'package:threepio_core/src/components/retriever/fusion/result_fusion.dart';
import 'package:threepio_core/src/components/retriever/fusion/scored_document.dart';
import 'package:threepio_core/src/schema/document.dart';

void main() {
  group('ScoredDocument', () {
    test('creates with required fields', () {
      final doc = Document.simple('test content');
      final scored = ScoredDocument(document: doc, score: 0.9);

      expect(scored.document, doc);
      expect(scored.score, 0.9);
    });

    test('creates from document with score', () {
      final doc = Document(
        content: 'test',
        score: 0.85,
        metadata: {'key': 'value'},
      );
      final scored = ScoredDocument.fromDocument(doc, sourceId: 'source1');

      expect(scored.score, 0.85);
      expect(scored.sourceId, 'source1');
    });

    test('copyWith updates fields', () {
      final scored = ScoredDocument(
        document: Document.simple('test'),
        score: 0.5,
        sourceId: 'a',
      );

      final updated = scored.copyWith(score: 0.9, sourceId: 'b');

      expect(updated.score, 0.9);
      expect(updated.sourceId, 'b');
      expect(updated.document.content, 'test');
    });
  });

  group('ReciprocalRankFusion', () {
    late ReciprocalRankFusion rrf;

    setUp(() {
      rrf = const ReciprocalRankFusion(k: 60.0);
    });

    test('returns empty list for empty input', () {
      final result = rrf.fuse([]);
      expect(result, isEmpty);
    });

    test('returns same list for single result set', () {
      final docs = [
        ScoredDocument(
          document: Document(id: '1', content: 'doc1'),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(id: '2', content: 'doc2'),
          score: 0.8,
        ),
      ];

      final result = rrf.fuse([docs]);

      expect(result.length, 2);
    });

    test('fuses results from multiple sources', () {
      final set1 = [
        ScoredDocument(
          document: Document(id: 'a', content: 'doc a'),
          score: 0.9,
          sourceId: 'source1',
        ),
        ScoredDocument(
          document: Document(id: 'b', content: 'doc b'),
          score: 0.7,
          sourceId: 'source1',
        ),
      ];

      final set2 = [
        ScoredDocument(
          document: Document(id: 'b', content: 'doc b'),
          score: 0.95,
          sourceId: 'source2',
        ),
        ScoredDocument(
          document: Document(id: 'c', content: 'doc c'),
          score: 0.6,
          sourceId: 'source2',
        ),
      ];

      final result = rrf.fuse([set1, set2]);

      // Doc 'b' appears in both, should have higher RRF score
      expect(result.isNotEmpty, true);
      expect(result.any((r) => r.document.id == 'b'), true);

      final docB = result.firstWhere((r) => r.document.id == 'b');
      expect(docB.metadata['source_count'], 2);
    });

    test('preserves fusion metadata', () {
      // Need multiple sources to trigger actual fusion
      final set1 = [
        ScoredDocument(
          document: Document(id: '1', content: 'test'),
          score: 0.9,
          sourceId: 'src1',
        ),
      ];
      final set2 = [
        ScoredDocument(
          document: Document(id: '2', content: 'other'),
          score: 0.8,
          sourceId: 'src2',
        ),
      ];

      final result = rrf.fuse([set1, set2]);

      expect(result.first.metadata['fusion_method'], 'rrf');
      expect(result.first.metadata['sources'], isA<List>());
    });
  });

  group('WeightedScoreFusion', () {
    test('applies equal weights by default', () {
      final fusion = const WeightedScoreFusion();

      final set1 = [
        ScoredDocument(
          document: Document(id: 'a', content: 'doc a'),
          score: 1.0,
        ),
      ];

      final set2 = [
        ScoredDocument(
          document: Document(id: 'a', content: 'doc a'),
          score: 0.5,
        ),
      ];

      final result = fusion.fuse([set1, set2]);

      expect(result.length, 1);
      // With normalization, scores are adjusted
    });

    test('applies custom weights', () {
      final fusion = const WeightedScoreFusion(
        weights: [0.7, 0.3],
        normalizeScores: false,
      );

      final set1 = [
        ScoredDocument(
          document: Document(id: 'a', content: 'doc a'),
          score: 1.0,
        ),
      ];

      final set2 = [
        ScoredDocument(
          document: Document(id: 'b', content: 'doc b'),
          score: 1.0,
        ),
      ];

      final result = fusion.fuse([set1, set2]);

      expect(result.length, 2);
      // Doc from set1 should have higher weighted score
      expect(result.first.document.id, 'a');
    });

    test('throws on weight count mismatch', () {
      final fusion = const WeightedScoreFusion(weights: [0.5]);

      expect(
        () => fusion.fuse([[], []]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('UnionFusion', () {
    test('combines all unique documents', () {
      final fusion = const UnionFusion();

      final set1 = [
        ScoredDocument(
          document: Document(id: 'a', content: 'doc a'),
          score: 0.9,
        ),
      ];

      final set2 = [
        ScoredDocument(
          document: Document(id: 'b', content: 'doc b'),
          score: 0.8,
        ),
      ];

      final result = fusion.fuse([set1, set2]);

      expect(result.length, 2);
      expect(result.map((r) => r.document.id), containsAll(['a', 'b']));
    });

    test('keeps highest score for duplicates', () {
      final fusion = const UnionFusion(keepHighestScore: true);

      final set1 = [
        ScoredDocument(
          document: Document(id: 'a', content: 'doc a'),
          score: 0.5,
        ),
      ];

      final set2 = [
        ScoredDocument(
          document: Document(id: 'a', content: 'doc a'),
          score: 0.9,
        ),
      ];

      final result = fusion.fuse([set1, set2]);

      expect(result.length, 1);
      expect(result.first.score, 0.9);
    });
  });

  group('IdDeduplication', () {
    test('removes documents with same ID', () async {
      final dedup = const IdDeduplication();

      final docs = [
        ScoredDocument(
          document: Document(id: 'dup', content: 'first'),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(id: 'unique', content: 'unique'),
          score: 0.8,
        ),
        ScoredDocument(
          document: Document(id: 'dup', content: 'second'),
          score: 0.7,
        ),
      ];

      final result = await dedup.deduplicate(docs);

      expect(result.length, 2);
      expect(result.map((r) => r.document.id), containsAll(['dup', 'unique']));

      // Should keep highest scored version
      final dupDoc = result.firstWhere((r) => r.document.id == 'dup');
      expect(dupDoc.score, 0.9);
    });

    test('uses content hash as fallback', () async {
      final dedup = const IdDeduplication(useContentHashAsFallback: true);

      final docs = [
        ScoredDocument(
          document: Document(content: 'same content'),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(content: 'same content'),
          score: 0.7,
        ),
      ];

      final result = await dedup.deduplicate(docs);

      expect(result.length, 1);
    });
  });

  group('ContentDeduplication', () {
    test('removes documents with identical content', () async {
      final dedup = const ContentDeduplication();

      final docs = [
        ScoredDocument(
          document: Document(id: '1', content: 'Hello World'),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(id: '2', content: 'Hello World'),
          score: 0.7,
        ),
        ScoredDocument(
          document: Document(id: '3', content: 'Different'),
          score: 0.5,
        ),
      ];

      final result = await dedup.deduplicate(docs);

      expect(result.length, 2);
    });

    test('normalizes whitespace when configured', () async {
      final dedup = const ContentDeduplication(normalizeWhitespace: true);

      final docs = [
        ScoredDocument(
          document: Document(content: 'Hello   World'),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(content: 'Hello World'),
          score: 0.7,
        ),
      ];

      final result = await dedup.deduplicate(docs);

      expect(result.length, 1);
    });

    test('respects case sensitivity', () async {
      final caseSensitive = const ContentDeduplication(caseSensitive: true);
      final caseInsensitive = const ContentDeduplication(caseSensitive: false);

      final docs = [
        ScoredDocument(
          document: Document(content: 'Hello'),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(content: 'hello'),
          score: 0.7,
        ),
      ];

      final sensitiveResult = await caseSensitive.deduplicate(docs);
      final insensitiveResult = await caseInsensitive.deduplicate(docs);

      expect(sensitiveResult.length, 2);
      expect(insensitiveResult.length, 1);
    });
  });

  group('CompositeDeduplication', () {
    test('applies strategies in order', () async {
      final composite = CompositeDeduplication([
        const IdDeduplication(),
        const ContentDeduplication(),
      ]);

      final docs = [
        ScoredDocument(
          document: Document(id: '1', content: 'content'),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(id: '1', content: 'content'),
          score: 0.8,
        ),
        ScoredDocument(
          document: Document(id: '2', content: 'content'),
          score: 0.7,
        ),
      ];

      final result = await composite.deduplicate(docs);

      // ID dedup removes one, content dedup removes another
      expect(result.length, 1);
    });
  });

  group('KeyDeduplication', () {
    test('deduplicates by custom key', () async {
      final dedup = KeyDeduplication<String>(
        keyExtractor: (doc) => doc.document.metadata['source'] as String?,
      );

      final docs = [
        ScoredDocument(
          document: Document(
            content: 'from source A - first',
            metadata: {'source': 'A'},
          ),
          score: 0.9,
        ),
        ScoredDocument(
          document: Document(
            content: 'from source A - second',
            metadata: {'source': 'A'},
          ),
          score: 0.7,
        ),
        ScoredDocument(
          document: Document(
            content: 'from source B',
            metadata: {'source': 'B'},
          ),
          score: 0.5,
        ),
      ];

      final result = await dedup.deduplicate(docs);

      expect(result.length, 2);
      expect(
        result.map((r) => r.document.metadata['source']),
        containsAll(['A', 'B']),
      );
    });
  });

  group('Document deduplication extensions', () {
    test('deduplicateById removes duplicates', () {
      final docs = [
        const Document(id: '1', content: 'first'),
        const Document(id: '1', content: 'duplicate'),
        const Document(id: '2', content: 'second'),
      ];

      final result = docs.deduplicateById();

      expect(result.length, 2);
    });

    test('deduplicateByContent removes duplicates', () {
      final docs = [
        const Document(content: 'same'),
        const Document(content: 'same'),
        const Document(content: 'different'),
      ];

      final result = docs.deduplicateByContent();

      expect(result.length, 2);
    });
  });
}
