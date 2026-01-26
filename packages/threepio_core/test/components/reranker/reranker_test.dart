import 'package:test/test.dart';
import 'package:threepio_core/src/components/reranker/reranker.dart';
import 'package:threepio_core/src/components/reranker/score_reranker.dart';
import 'package:threepio_core/src/schema/document.dart';

void main() {
  group('ScoreReranker', () {
    late ScoreReranker reranker;

    setUp(() {
      reranker = ScoreReranker();
    });

    test('returns empty list for empty documents', () async {
      final results = await reranker.rerank('query', []);
      expect(results, isEmpty);
    });

    test('uses document score field', () async {
      final docs = [
        const Document(content: 'Doc A', score: 0.9),
        const Document(content: 'Doc B', score: 0.5),
        const Document(content: 'Doc C', score: 0.7),
      ];

      final results = await reranker.rerank('query', docs);

      // Should be sorted by score descending
      expect(results[0].document.content, 'Doc A');
      expect(results[1].document.content, 'Doc C');
      expect(results[2].document.content, 'Doc B');
    });

    test('uses metadata score when document score is null', () async {
      final docs = [
        const Document(content: 'Doc A', metadata: {'score': 0.3}),
        const Document(content: 'Doc B', score: 0.5),
        const Document(content: 'Doc C', metadata: {'score': 0.7}),
      ];

      final results = await reranker.rerank('query', docs);

      expect(results[0].document.content, 'Doc C');
      expect(results[1].document.content, 'Doc B');
      expect(results[2].document.content, 'Doc A');
    });

    test('uses custom score key from metadata', () async {
      final customReranker = ScoreReranker(scoreKey: 'relevance');
      final docs = [
        const Document(content: 'Doc A', metadata: {'relevance': 0.9}),
        const Document(content: 'Doc B', metadata: {'relevance': 0.3}),
      ];

      final results = await customReranker.rerank('query', docs);

      expect(results[0].document.content, 'Doc A');
    });

    test('uses default score for documents without scores', () async {
      final rerankerWithDefault = ScoreReranker(defaultScore: 0.1);
      final docs = [
        const Document(content: 'Doc A'), // No score, uses default 0.1
        const Document(content: 'Doc B', score: 0.5),
      ];

      final results = await rerankerWithDefault.rerank('query', docs);

      expect(results[0].document.content, 'Doc B');
      expect(results[1].document.content, 'Doc A');
      expect(results[1].score, 0.1);
    });

    test('applies topK filter', () async {
      final docs = [
        const Document(content: 'Doc A', score: 0.9),
        const Document(content: 'Doc B', score: 0.8),
        const Document(content: 'Doc C', score: 0.7),
        const Document(content: 'Doc D', score: 0.6),
      ];

      final results = await reranker.rerank(
        'query',
        docs,
        options: const RerankerOptions(topK: 2),
      );

      expect(results.length, 2);
      expect(results[0].document.content, 'Doc A');
      expect(results[1].document.content, 'Doc B');
    });

    test('applies threshold filter', () async {
      final docs = [
        const Document(content: 'Doc A', score: 0.9),
        const Document(content: 'Doc B', score: 0.5),
        const Document(content: 'Doc C', score: 0.3),
      ];

      final results = await reranker.rerank(
        'query',
        docs,
        options: const RerankerOptions(threshold: 0.5),
      );

      expect(results.length, 2);
      expect(results.every((r) => r.score >= 0.5), isTrue);
    });

    test('normalizes scores when enabled', () async {
      final normalizingReranker = ScoreReranker(normalize: true);
      final docs = [
        const Document(content: 'Doc A', score: 10.0),
        const Document(content: 'Doc B', score: 5.0),
        const Document(content: 'Doc C', score: 0.0),
      ];

      final results = await normalizingReranker.rerank('query', docs);

      // Scores should be normalized to 0-1 range
      expect(results[0].score, closeTo(1.0, 0.01)); // Max score -> 1.0
      expect(results[1].score, closeTo(0.5, 0.01)); // Middle score
      expect(results[2].score, closeTo(0.0, 0.01)); // Min score -> 0.0
    });

    test('handles all same scores with normalization', () async {
      final normalizingReranker = ScoreReranker(normalize: true);
      final docs = [
        const Document(content: 'Doc A', score: 5.0),
        const Document(content: 'Doc B', score: 5.0),
      ];

      final results = await normalizingReranker.rerank('query', docs);

      // All scores same -> normalized to 1.0
      expect(results.every((r) => r.score == 1.0), isTrue);
    });

    test('preserves original index', () async {
      final docs = [
        const Document(content: 'Doc A', score: 0.3),
        const Document(content: 'Doc B', score: 0.9),
        const Document(content: 'Doc C', score: 0.6),
      ];

      final results = await reranker.rerank('query', docs);

      // Doc B was at index 1 originally
      expect(results[0].originalIndex, 1);
      // Doc C was at index 2 originally
      expect(results[1].originalIndex, 2);
      // Doc A was at index 0 originally
      expect(results[2].originalIndex, 0);
    });
  });

  group('FunctionReranker', () {
    test('uses custom scoring function', () async {
      final reranker = FunctionReranker(
        scorer: (query, doc) async {
          // Simple scorer: length match
          return 1.0 - (query.length - doc.content.length).abs() / 100;
        },
      );

      final docs = [
        const Document(content: 'Short'),
        const Document(content: 'A very long document content'),
        const Document(content: 'Medium length'),
      ];

      final results = await reranker.rerank('query', docs);

      // All documents should have scores based on the function
      expect(results.every((r) => r.score > 0 && r.score <= 1), isTrue);
    });

    test('handles async scoring function', () async {
      final reranker = FunctionReranker(
        scorer: (query, doc) async {
          await Future.delayed(const Duration(milliseconds: 1));
          return doc.content.contains(query) ? 1.0 : 0.5;
        },
      );

      final docs = [
        const Document(content: 'Hello world'),
        const Document(content: 'test document'),
      ];

      final results = await reranker.rerank('test', docs);

      expect(results[0].document.content, 'test document');
      expect(results[0].score, 1.0);
    });
  });

  group('CompositeReranker', () {
    test('combines multiple rerankers with equal weights', () async {
      final reranker1 = ScoreReranker();
      final reranker2 = FunctionReranker(
        scorer: (query, doc) async => doc.content.length / 100,
      );

      final composite = CompositeReranker(
        rerankers: [reranker1, reranker2],
      );

      final docs = [
        const Document(content: 'A', score: 1.0),
        const Document(content: 'Medium length text here', score: 0.5),
      ];

      final results = await composite.rerank('query', docs);

      // Results should combine both scores
      expect(results.length, 2);
    });

    test('applies custom weights', () async {
      final reranker1 = ScoreReranker();
      final reranker2 = FunctionReranker(
        scorer: (query, doc) async => 0.0, // Always returns 0
      );

      final composite = CompositeReranker(
        rerankers: [reranker1, reranker2],
        weights: [0.9, 0.1], // Heavily favor reranker1
      );

      final docs = [
        const Document(content: 'Doc A', score: 1.0),
        const Document(content: 'Doc B', score: 0.5),
      ];

      final results = await composite.rerank('query', docs);

      // Doc A should still be first due to high weight on score reranker
      expect(results[0].document.content, 'Doc A');
    });

    test('returns empty for empty rerankers list', () async {
      final composite = CompositeReranker(rerankers: []);

      final results = await composite.rerank(
        'query',
        [const Document(content: 'Test')],
      );

      expect(results, isEmpty);
    });

    test('returns empty for empty documents', () async {
      final composite = CompositeReranker(
        rerankers: [ScoreReranker()],
      );

      final results = await composite.rerank('query', []);
      expect(results, isEmpty);
    });
  });

  group('RerankResult', () {
    test('withScore creates copy with new score', () {
      const original = RerankResult(
        document: Document(content: 'Test'),
        score: 0.5,
        originalIndex: 0,
        metadata: {'key': 'value'},
      );

      final updated = original.withScore(0.9);

      expect(updated.score, 0.9);
      expect(updated.document.content, 'Test');
      expect(updated.originalIndex, 0);
      expect(updated.metadata, {'key': 'value'});
    });
  });

  group('BaseReranker helpers', () {
    late ScoreReranker reranker;

    setUp(() {
      reranker = ScoreReranker();
    });

    test('applyTopK returns original if topK is null', () async {
      final docs = [
        const Document(content: 'A', score: 0.9),
        const Document(content: 'B', score: 0.8),
      ];

      final results = await reranker.rerank('query', docs);
      expect(results.length, 2);
    });

    test('applyTopK returns original if topK exceeds length', () async {
      final docs = [
        const Document(content: 'A', score: 0.9),
        const Document(content: 'B', score: 0.8),
      ];

      final results = await reranker.rerank(
        'query',
        docs,
        options: const RerankerOptions(topK: 10),
      );
      expect(results.length, 2);
    });

    test('threshold and topK work together', () async {
      final docs = [
        const Document(content: 'A', score: 0.9),
        const Document(content: 'B', score: 0.8),
        const Document(content: 'C', score: 0.3),
        const Document(content: 'D', score: 0.2),
      ];

      final results = await reranker.rerank(
        'query',
        docs,
        options: const RerankerOptions(threshold: 0.5, topK: 1),
      );

      // First filter by threshold (A, B), then topK (A)
      expect(results.length, 1);
      expect(results[0].document.content, 'A');
    });
  });
}
