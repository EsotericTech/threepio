import 'package:test/test.dart';
import 'package:threepio_core/src/components/text_splitter/html_splitter.dart';
import 'package:threepio_core/src/components/text_splitter/markdown_splitter.dart';
import 'package:threepio_core/src/components/text_splitter/text_splitter.dart';
import 'package:threepio_core/src/schema/document.dart';

void main() {
  group('HtmlSplitter', () {
    late HtmlSplitter splitter;

    setUp(() {
      splitter = HtmlSplitter();
    });

    test('returns empty list for empty input', () {
      final chunks = splitter.splitText('');
      expect(chunks, isEmpty);
    });

    test('strips HTML tags by default', () {
      const html = '<p>Hello <b>World</b></p>';
      final chunks = splitter.splitText(html);

      expect(chunks.first, contains('Hello'));
      expect(chunks.first, contains('World'));
      expect(chunks.first, isNot(contains('<p>')));
      expect(chunks.first, isNot(contains('<b>')));
    });

    test('removes scripts and styles', () {
      const html = '''
        <div>
          <script>alert('bad');</script>
          <style>.hidden { display: none; }</style>
          <p>Visible content</p>
        </div>
      ''';
      final chunks = splitter.splitText(html);

      expect(chunks.first, contains('Visible content'));
      expect(chunks.first, isNot(contains('alert')));
      expect(chunks.first, isNot(contains('hidden')));
    });

    test('removes HTML comments', () {
      const html = '<p>Before</p><!-- Comment --><p>After</p>';
      final chunks = splitter.splitText(html);

      expect(chunks.join(), contains('Before'));
      expect(chunks.join(), contains('After'));
      expect(chunks.join(), isNot(contains('Comment')));
    });

    test('preserves links when configured', () {
      final splitterWithLinks = HtmlSplitter(preserveLinks: true, stripTags: true);
      const html = '<p>Visit <a href="https://example.com">our site</a></p>';
      final chunks = splitterWithLinks.splitText(html);

      expect(chunks.first, contains('our site'));
      expect(chunks.first, contains('https://example.com'));
    });

    test('splits long content into chunks', () {
      final longHtml = '<p>${'A' * 500}</p><p>${'B' * 500}</p><p>${'C' * 500}</p>';
      final chunks = splitter.splitText(
        longHtml,
        options: const TextSplitterOptions(chunkSize: 600, chunkOverlap: 50),
      );

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.length <= 700), isTrue); // Allow some flexibility
    });

    test('decodes HTML entities', () {
      const html = '<p>&amp; &lt; &gt; &quot;</p>';
      final chunks = splitter.splitText(html);

      expect(chunks.first, contains('&'));
      expect(chunks.first, contains('<'));
      expect(chunks.first, contains('>'));
      expect(chunks.first, contains('"'));
    });

    test('splits documents preserving metadata', () async {
      final docs = [
        const Document(
          content: '<p>Test content</p>',
          metadata: {'source': 'test'},
        ),
      ];

      final chunks = await splitter.splitDocuments(docs);

      expect(chunks.first.metadata['source'], 'test');
      expect(chunks.first.metadata['content_type'], 'html');
      expect(chunks.first.metadata['chunk_index'], 0);
    });
  });

  group('MarkdownSplitter', () {
    late MarkdownSplitter splitter;

    setUp(() {
      splitter = MarkdownSplitter();
    });

    test('returns empty list for empty input', () {
      final chunks = splitter.splitText('');
      expect(chunks, isEmpty);
    });

    test('splits by headers', () {
      const markdown = '''
# Header 1

Content for header 1.

## Header 2

Content for header 2.

### Header 3

Content for header 3.
''';
      final chunks = splitter.splitText(
        markdown,
        options: const TextSplitterOptions(chunkSize: 100, chunkOverlap: 0),
      );

      expect(chunks.length, greaterThan(1));
      expect(chunks.any((c) => c.contains('Header 1')), isTrue);
      expect(chunks.any((c) => c.contains('Header 2')), isTrue);
    });

    test('preserves code blocks when configured', () {
      final splitterWithCodeBlocks = MarkdownSplitter(preserveCodeBlocks: true);
      const markdown = '''
# Example

```dart
void main() {
  print('Hello');
}
```

More text.
''';
      final chunks = splitterWithCodeBlocks.splitText(
        markdown,
        options: const TextSplitterOptions(chunkSize: 1000, chunkOverlap: 0),
      );

      expect(chunks.any((c) => c.contains('```dart')), isTrue);
      expect(chunks.any((c) => c.contains("print('Hello')")), isTrue);
    });

    test('respects chunk size', () {
      final longMarkdown = '''
# Section 1

${'This is paragraph content. ' * 50}

# Section 2

${'More paragraph content. ' * 50}
''';
      final chunks = splitter.splitText(
        longMarkdown,
        options: const TextSplitterOptions(chunkSize: 500, chunkOverlap: 50),
      );

      expect(chunks.length, greaterThan(1));
    });

    test('handles overlap', () {
      const markdown = '''
# Section 1

First section content here.

# Section 2

Second section content here.
''';
      final chunks = splitter.splitText(
        markdown,
        options: const TextSplitterOptions(chunkSize: 50, chunkOverlap: 10),
      );

      expect(chunks.length, greaterThan(1));
    });

    test('can return each line separately', () {
      final lineSplitter = MarkdownSplitter(returnEachLine: true);
      const markdown = '''
Line 1
Line 2
Line 3
''';
      final chunks = lineSplitter.splitText(markdown);

      expect(chunks.length, 3);
      expect(chunks[0], 'Line 1');
      expect(chunks[1], 'Line 2');
      expect(chunks[2], 'Line 3');
    });

    test('configurable header levels', () {
      final customSplitter = MarkdownSplitter(
        minHeaderLevel: 2,
        maxHeaderLevel: 3,
      );
      const markdown = '''
# H1 Title

Content under H1.

## H2 Section

Content under H2.

### H3 Subsection

Content under H3.

#### H4 Sub-subsection

Content under H4.
''';
      final chunks = customSplitter.splitText(
        markdown,
        options: const TextSplitterOptions(chunkSize: 100, chunkOverlap: 0),
      );

      // Should split on H2 and H3 but not H1 or H4
      expect(chunks.length, greaterThan(1));
    });

    test('extracts header context in metadata', () async {
      const markdown = '''
# Main Title

Some content here.
''';
      final docs = [Document(content: markdown)];
      final chunks = await splitter.splitDocuments(docs);

      expect(chunks.first.metadata['content_type'], 'markdown');
    });
  });

  group('MarkdownRAGSplitter', () {
    late MarkdownRAGSplitter splitter;

    setUp(() {
      splitter = MarkdownRAGSplitter();
    });

    test('includes headers in chunks', () async {
      const markdown = '''
# Main Section

Content for the main section.

## Sub Section

Content for the sub section.
''';
      final docs = [Document(content: markdown)];
      final chunks = await splitter.splitDocuments(
        docs,
        options: const TextSplitterOptions(chunkSize: 1000, chunkOverlap: 0),
      );

      // Chunks should include their header context
      expect(chunks.any((c) => c.content.contains('Main Section')), isTrue);
    });

    test('adds header breadcrumbs to metadata', () async {
      const markdown = '''
# Chapter 1

## Section 1.1

### Subsection 1.1.1

Deep content here.
''';
      final docs = [Document(content: markdown)];
      final chunks = await splitter.splitDocuments(
        docs,
        options: const TextSplitterOptions(chunkSize: 1000, chunkOverlap: 0),
      );

      // Find the chunk with the deep content
      final deepChunk = chunks.firstWhere(
        (c) => c.content.contains('Deep content'),
        orElse: () => chunks.last,
      );

      expect(deepChunk.metadata['header_breadcrumbs'], isA<List>());
    });
  });

  group('TextSplitterOptions', () {
    test('validates positive chunk size', () {
      expect(
        () => const TextSplitterOptions(chunkSize: 0).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validates non-negative overlap', () {
      expect(
        () => const TextSplitterOptions(chunkOverlap: -1).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validates overlap less than chunk size', () {
      expect(
        () => const TextSplitterOptions(chunkSize: 100, chunkOverlap: 100).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('valid options pass validation', () {
      expect(
        () => const TextSplitterOptions(chunkSize: 100, chunkOverlap: 50).validate(),
        returnsNormally,
      );
    });
  });
}
