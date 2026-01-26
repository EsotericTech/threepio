import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document_parser/document_parser.dart';
import 'package:threepio_core/src/components/document_parser/html_parser.dart';
import 'package:threepio_core/src/components/document_parser/markdown_parser.dart';
import 'package:threepio_core/src/components/document_parser/parser_registry.dart';

void main() {
  group('HtmlParser', () {
    late HtmlParser parser;

    setUp(() {
      parser = HtmlParser();
    });

    test('parses basic HTML', () async {
      const html = '<html><body><p>Hello World</p></body></html>';
      final result = await parser.parseString(html);

      expect(result.documents.length, 1);
      expect(result.documents.first.content, contains('Hello World'));
    });

    test('extracts title from HTML', () async {
      const html = '''
        <html>
          <head><title>Test Page</title></head>
          <body><p>Content here</p></body>
        </html>
      ''';
      final result = await parser.parseString(html);

      expect(result.documents.first.metadata['title'], 'Test Page');
    });

    test('removes scripts and styles by default', () async {
      const html = '''
        <html>
          <body>
            <script>alert('test');</script>
            <style>.test { color: red; }</style>
            <p>Visible content</p>
          </body>
        </html>
      ''';
      final result = await parser.parseString(html);

      expect(result.documents.first.content, contains('Visible content'));
      expect(result.documents.first.content, isNot(contains('alert')));
      expect(result.documents.first.content, isNot(contains('color')));
    });

    test('removes HTML comments', () async {
      const html = '''
        <html>
          <body>
            <!-- This is a comment -->
            <p>Visible content</p>
          </body>
        </html>
      ''';
      final result = await parser.parseString(html);

      expect(result.documents.first.content, contains('Visible content'));
      expect(result.documents.first.content, isNot(contains('comment')));
    });

    test('preserves links when configured', () async {
      final parserWithLinks = HtmlParser(preserveLinks: true);
      const html = '<p>Visit <a href="https://example.com">our site</a></p>';
      final result = await parserWithLinks.parseString(html);

      expect(result.documents.first.content, contains('our site'));
      expect(result.documents.first.content, contains('https://example.com'));
    });

    test('decodes HTML entities', () async {
      const html = '<p>&amp; &lt; &gt; &quot; &nbsp;</p>';
      final result = await parser.parseString(html);

      expect(result.documents.first.content, contains('&'));
      expect(result.documents.first.content, contains('<'));
      expect(result.documents.first.content, contains('>'));
    });

    test('supports extensions', () {
      expect(parser.supportsExtension('html'), isTrue);
      expect(parser.supportsExtension('htm'), isTrue);
      expect(parser.supportsExtension('xhtml'), isTrue);
      expect(parser.supportsExtension('txt'), isFalse);
    });

    test('supports MIME types', () {
      expect(parser.supportsMimeType('text/html'), isTrue);
      expect(parser.supportsMimeType('application/xhtml+xml'), isTrue);
      expect(parser.supportsMimeType('text/plain'), isFalse);
    });

    test('parses bytes', () async {
      const html = '<p>Test content</p>';
      final bytes = Uint8List.fromList(utf8.encode(html));
      final result = await parser.parse(bytes);

      expect(result.documents.first.content, contains('Test content'));
    });

    test('extracts tables when configured', () async {
      const html = '''
        <table>
          <caption>Test Table</caption>
          <tr><th>Name</th><th>Age</th></tr>
          <tr><td>Alice</td><td>30</td></tr>
          <tr><td>Bob</td><td>25</td></tr>
        </table>
      ''';
      final result = await parser.parseString(
        html,
        options: const DocumentParserOptions(extractTables: true),
      );

      expect(result.extractedTables, isNotNull);
      expect(result.extractedTables!.length, 1);
      expect(result.extractedTables!.first.caption, 'Test Table');
      expect(result.extractedTables!.first.headers, ['Name', 'Age']);
      expect(result.extractedTables!.first.rows.length, 2);
    });
  });

  group('MarkdownParser', () {
    late MarkdownParser parser;

    setUp(() {
      parser = MarkdownParser();
    });

    test('parses basic markdown', () async {
      const markdown = '# Hello\n\nThis is content.';
      final result = await parser.parseString(markdown);

      expect(result.documents.length, 1);
      expect(result.documents.first.content, contains('Hello'));
      expect(result.documents.first.content, contains('This is content'));
    });

    test('extracts YAML frontmatter', () async {
      const markdown = '''---
title: Test Document
author: John Doe
---

# Content

Body text here.
''';
      final result = await parser.parseString(markdown);

      expect(result.documents.first.metadata['title'], 'Test Document');
      expect(result.documents.first.metadata['author'], 'John Doe');
    });

    test('removes frontmatter from content by default', () async {
      const markdown = '''---
title: Test
---

# Content
''';
      final result = await parser.parseString(markdown);

      expect(result.documents.first.content, isNot(contains('---')));
      expect(result.documents.first.content, isNot(contains('title: Test')));
    });

    test('parses boolean values in frontmatter', () async {
      const markdown = '''---
published: true
draft: false
---

Content
''';
      final result = await parser.parseString(markdown);

      expect(result.documents.first.metadata['published'], isTrue);
      expect(result.documents.first.metadata['draft'], isFalse);
    });

    test('parses numeric values in frontmatter', () async {
      const markdown = '''---
count: 42
price: 19.99
---

Content
''';
      final result = await parser.parseString(markdown);

      expect(result.documents.first.metadata['count'], 42);
      expect(result.documents.first.metadata['price'], 19.99);
    });

    test('extracts code blocks when configured', () async {
      final parserWithCodeBlocks = MarkdownParser(extractCodeBlocks: true);
      const markdown = '''
# Example

Here's some code:

```dart
void main() {
  print('Hello');
}
```

And more text.
''';
      final result = await parserWithCodeBlocks.parseString(markdown);

      expect(result.metadata?['code_block_count'], 1);
    });

    test('strips formatting when configured', () async {
      final parserNoFormatting = MarkdownParser(preserveFormatting: false);
      const markdown = '''
# Title

**Bold** and *italic* text.

[Link](https://example.com)
''';
      final result = await parserNoFormatting.parseString(markdown);

      expect(result.documents.first.content, isNot(contains('#')));
      expect(result.documents.first.content, isNot(contains('**')));
      expect(result.documents.first.content, isNot(contains('*')));
    });

    test('supports extensions', () {
      expect(parser.supportsExtension('md'), isTrue);
      expect(parser.supportsExtension('markdown'), isTrue);
      expect(parser.supportsExtension('txt'), isFalse);
    });
  });

  group('PlainTextParser', () {
    late PlainTextParser parser;

    setUp(() {
      parser = PlainTextParser();
    });

    test('parses plain text', () async {
      const text = 'Hello, World!\n\nThis is plain text.';
      final result = await parser.parseString(text);

      expect(result.documents.length, 1);
      expect(result.documents.first.content, text);
    });

    test('adds parser metadata', () async {
      final result = await parser.parseString('Test');

      expect(result.documents.first.metadata['parser'], 'plain_text');
    });
  });

  group('ParserRegistry', () {
    late ParserRegistry registry;

    setUp(() {
      registry = ParserRegistry()
        ..register(HtmlParser())
        ..register(MarkdownParser())
        ..register(PlainTextParser());
    });

    test('finds parser by extension', () {
      expect(registry.getParserForExtension('html'), isA<HtmlParser>());
      expect(registry.getParserForExtension('md'), isA<MarkdownParser>());
      expect(registry.getParserForExtension('txt'), isA<PlainTextParser>());
      expect(registry.getParserForExtension('unknown'), isNull);
    });

    test('finds parser by MIME type', () {
      expect(registry.getParserForMimeType('text/html'), isA<HtmlParser>());
      expect(registry.getParserForMimeType('text/markdown'), isA<MarkdownParser>());
      expect(registry.getParserForMimeType('text/plain'), isA<PlainTextParser>());
    });

    test('finds parser by path', () {
      expect(registry.getParserForPath('/path/to/file.html'), isA<HtmlParser>());
      expect(registry.getParserForPath('/path/to/file.md'), isA<MarkdownParser>());
      expect(registry.getParserForPath('https://example.com/page.html?query=1'), isA<HtmlParser>());
    });

    test('parses file by path', () async {
      const html = '<p>Test content</p>';
      final bytes = Uint8List.fromList(utf8.encode(html));

      final result = await registry.parseFile('document.html', bytes);

      expect(result.documents.first.content, contains('Test content'));
    });

    test('parses by MIME type', () async {
      const markdown = '# Title\n\nContent';
      final bytes = Uint8List.fromList(utf8.encode(markdown));

      final result = await registry.parseByMimeType('text/markdown', bytes);

      expect(result.documents.first.content, contains('Title'));
    });

    test('throws on unsupported extension', () {
      final bytes = Uint8List.fromList([0, 1, 2]);

      expect(
        () => registry.parseFile('document.xyz', bytes),
        throwsA(isA<NoParserFoundException>()),
      );
    });

    test('lists supported extensions', () {
      final extensions = registry.supportedExtensions;

      expect(extensions, contains('html'));
      expect(extensions, contains('md'));
      expect(extensions, contains('txt'));
    });

    test('unregisters parser', () {
      final htmlParser = HtmlParser();
      registry.unregister(htmlParser);

      // Note: This won't work because we registered a different instance
      // Let's test with a fresh registry
      final freshRegistry = ParserRegistry();
      final parser = HtmlParser();
      freshRegistry.register(parser);
      expect(freshRegistry.getParserForExtension('html'), isNotNull);

      freshRegistry.unregister(parser);
      expect(freshRegistry.getParserForExtension('html'), isNull);
    });

    test('checks support for extension', () {
      expect(registry.supportsExtension('html'), isTrue);
      expect(registry.supportsExtension('xyz'), isFalse);
    });

    test('checks support for MIME type', () {
      expect(registry.supportsMimeType('text/html'), isTrue);
      expect(registry.supportsMimeType('application/octet-stream'), isFalse);
    });
  });
}
