// Port of TestDocument of eino `schema/document_test.go` (v0.9.22), plus how
// the metadata accessors live together with the `score` and `embedding`
// fields of the Dart `Document`.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

void main() {
  // TestDocument
  test('the metadata accessors return what was set', () {
    const subIndexes = ['hello', 'bye'];
    const score = 1.1;
    const extraInfo = 'asd';
    const dslInfo = {'hello': true};
    const vector = [1.1, 2.2];

    const document = Document(id: 'asd', content: 'qwe');
    final enriched = document
        .withSubIndexes(subIndexes)
        .withDenseVector(vector)
        .withScore(score)
        .withExtraInfo(extraInfo)
        .withDslInfo(dslInfo);

    expect(enriched.subIndexes, subIndexes);
    expect(enriched.effectiveScore, score);
    expect(enriched.extraInfo, extraInfo);
    expect(enriched.dslInfo, dslInfo);
    expect(enriched.denseVector, vector);

    expect(enriched.id, 'asd');
    expect(enriched.content, 'qwe');
    expect(document.metadata, isEmpty, reason: 'the original is unchanged');
  });

  test('the accessors use the metadata keys of Eino', () {
    final document = Document.simple('text')
        .withSubIndexes(['a'])
        .withScore(0.5)
        .withExtraInfo('info')
        .withDslInfo({'term': 'x'})
        .withDenseVector([1, 2])
        .withSparseVector({3: 0.25});

    expect(document.metadata.keys, [
      '_sub_indexes',
      '_score',
      '_extra_info',
      '_dsl',
      '_dense_vector',
      '_sparse_vector',
    ]);
  });

  test('a document without the entries returns null', () {
    final document = Document.simple('text');

    expect(document.subIndexes, isNull);
    expect(document.effectiveScore, isNull);
    expect(document.extraInfo, isNull);
    expect(document.dslInfo, isNull);
    expect(document.denseVector, isNull);
    expect(document.sparseVector, isNull);
  });

  test('entries of the wrong type are ignored', () {
    const document = Document(
      content: 'text',
      metadata: {
        '_sub_indexes': 'not a list',
        '_score': 'high',
        '_extra_info': 1,
        '_dsl': 'query',
        '_dense_vector': ['a'],
        '_sparse_vector': {'x': 1.0},
      },
    );

    expect(document.subIndexes, isNull);
    expect(document.effectiveScore, isNull);
    expect(document.extraInfo, isNull);
    expect(document.dslInfo, isNull);
    expect(document.denseVector, isNull);
    expect(document.sparseVector, isNull);
  });

  test('other metadata is kept', () {
    final document =
        Document.withMetadata('text', {'source': 'wiki'}).withScore(0.9);

    expect(document.metadata, {'source': 'wiki', '_score': 0.9});
  });

  group('score', () {
    test('withScore sets the field and the metadata entry', () {
      final document = Document.simple('text').withScore(0.7);

      expect(document.score, 0.7);
      expect(document.metadata['_score'], 0.7);
    });

    test('the field wins over the metadata entry', () {
      const document = Document(
        content: 'text',
        score: 0.9,
        metadata: {'_score': 0.1},
      );

      expect(document.effectiveScore, 0.9);
    });

    test('the metadata entry is used when the field is not set', () {
      const document = Document(content: 'text', metadata: {'_score': 2});

      expect(document.score, isNull);
      expect(document.effectiveScore, 2.0);
    });
  });

  group('dense vector', () {
    test('withDenseVector sets the embedding and the metadata entry', () {
      final document = Document.simple('text').withDenseVector([0.1, 0.2]);

      expect(document.embedding, [0.1, 0.2]);
      expect(document.metadata['_dense_vector'], [0.1, 0.2]);
    });

    test('the embedding wins over the metadata entry', () {
      const document = Document(
        content: 'text',
        embedding: [1, 2],
        metadata: {
          '_dense_vector': [9.0],
        },
      );

      expect(document.denseVector, [1.0, 2.0]);
    });
  });

  test('sparse vectors keep their integer dimensions', () {
    final document =
        Document.simple('text').withSparseVector({7: 0.5, 1024: 0.25});

    expect(document.sparseVector, {7: 0.5, 1024: 0.25});
  });

  test('everything survives JSON', () {
    final document = Document.simple('text')
        .withSubIndexes(['a', 'b'])
        .withScore(0.5)
        .withExtraInfo('info')
        .withDslInfo({
          'term': {'k': 1},
        })
        .withDenseVector([1.5, 2])
        .withSparseVector({3: 0.25});

    final restored = Document.fromJson(
      jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>,
    );
    // A document written by Eino has the entries but not the Dart fields.
    final fromEino = restored.copyWith(score: null, embedding: null);

    for (final decoded in [restored, fromEino]) {
      expect(decoded.subIndexes, ['a', 'b']);
      expect(decoded.effectiveScore, 0.5);
      expect(decoded.extraInfo, 'info');
      expect(decoded.dslInfo, {
        'term': {'k': 1},
      });
      expect(decoded.denseVector, [1.5, 2.0]);
      expect(decoded.sparseVector, {3: 0.25});
    }
  });
}
