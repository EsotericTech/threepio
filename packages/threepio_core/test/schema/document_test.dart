import 'package:test/test.dart';
import 'package:threepio_core/src/schema/document.dart';

void main() {
  group('Document', () {
    test('creates simple document', () {
      final doc = Document.simple('Test content');
      expect(doc.content, 'Test content');
      expect(doc.metadata, isEmpty);
    });

    test('creates document with metadata', () {
      final doc = Document.withMetadata(
        'Content',
        {'author': 'John', 'date': '2024-01-01'},
      );
      expect(doc.content, 'Content');
      expect(doc.metadata['author'], 'John');
      expect(doc.metadata['date'], '2024-01-01');
    });

    test('creates document from source', () {
      final doc = Document.fromSource(
        'Content',
        'https://example.com/doc.pdf',
      );
      expect(doc.content, 'Content');
      expect(doc.source?.uri, 'https://example.com/doc.pdf');
    });

    test('includes embedding vector', () {
      final doc = Document(
        content: 'Content',
        embedding: [0.1, 0.2, 0.3],
      );
      expect(doc.embedding, [0.1, 0.2, 0.3]);
    });

    test('includes relevance score', () {
      final doc = Document(
        content: 'Content',
        score: 0.95,
      );
      expect(doc.score, 0.95);
    });

    test('serializes and deserializes correctly', () {
      final original = Document(
        id: 'doc123',
        content: 'Test content',
        metadata: {'key': 'value'},
        source: DocumentSource(uri: 'https://example.com'),
        embedding: [0.1, 0.2],
        score: 0.9,
      );
      final json = original.toJson();
      final deserialized = Document.fromJson(json);

      expect(deserialized.id, original.id);
      expect(deserialized.content, original.content);
      expect(deserialized.metadata, original.metadata);
      expect(deserialized.source?.uri, original.source?.uri);
      expect(deserialized.embedding, original.embedding);
      expect(deserialized.score, original.score);
    });
  });

  group('DocumentSource', () {
    test('creates document source', () {
      final source = DocumentSource(uri: 'https://example.com/doc.pdf');
      expect(source.uri, 'https://example.com/doc.pdf');
    });

    test('includes metadata', () {
      final source = DocumentSource(
        uri: 'https://example.com/doc.pdf',
        metadata: {'type': 'pdf'},
      );
      expect(source.metadata?['type'], 'pdf');
    });

    test('serializes and deserializes correctly', () {
      final original = DocumentSource(
        uri: 'test.pdf',
        metadata: {'key': 'value'},
      );
      final json = original.toJson();
      final deserialized = DocumentSource.fromJson(json);

      expect(deserialized.uri, original.uri);
      expect(deserialized.metadata, original.metadata);
    });
  });

  group('DocumentChunk', () {
    test('creates chunk', () {
      final chunk = DocumentChunk(
        content: 'Chunk content',
        index: 0,
        parentId: 'doc123',
      );
      expect(chunk.content, 'Chunk content');
      expect(chunk.index, 0);
      expect(chunk.parentId, 'doc123');
    });

    test('includes position information', () {
      final chunk = DocumentChunk(
        content: 'Chunk',
        startPosition: 0,
        endPosition: 100,
      );
      expect(chunk.startPosition, 0);
      expect(chunk.endPosition, 100);
    });

    test('serializes and deserializes correctly', () {
      final original = DocumentChunk(
        content: 'Test',
        metadata: {'key': 'value'},
        index: 1,
        parentId: 'parent123',
        startPosition: 10,
        endPosition: 20,
      );
      final json = original.toJson();
      final deserialized = DocumentChunk.fromJson(json);

      expect(deserialized.content, original.content);
      expect(deserialized.metadata, original.metadata);
      expect(deserialized.index, original.index);
      expect(deserialized.parentId, original.parentId);
      expect(deserialized.startPosition, original.startPosition);
      expect(deserialized.endPosition, original.endPosition);
    });
  });

  group('ChunkedDocument', () {
    test('creates chunked document', () {
      final doc = Document.simple('Full content');
      final chunks = [
        DocumentChunk(content: 'Chunk 1', index: 0),
        DocumentChunk(content: 'Chunk 2', index: 1),
      ];
      final chunkedDoc = ChunkedDocument(
        document: doc,
        chunks: chunks,
      );
      expect(chunkedDoc.document.content, 'Full content');
      expect(chunkedDoc.chunks.length, 2);
      expect(chunkedDoc.chunks[0].content, 'Chunk 1');
      expect(chunkedDoc.chunks[1].content, 'Chunk 2');
    });

    test('serializes and deserializes correctly', () {
      final original = ChunkedDocument(
        document: Document.simple('Content'),
        chunks: [
          DocumentChunk(content: 'Chunk 1', index: 0),
        ],
      );
      final json = original.toJson();
      final deserialized = ChunkedDocument.fromJson(json);

      expect(deserialized.document.content, original.document.content);
      expect(deserialized.chunks.length, original.chunks.length);
      expect(deserialized.chunks[0].content, original.chunks[0].content);
    });
  });
}
