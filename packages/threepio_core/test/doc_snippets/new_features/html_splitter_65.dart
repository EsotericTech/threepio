// Mirror of doc/NEW_FEATURES.md, "7. Advanced Text Splitters > HTML Splitter".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> htmlSplitter() async {
  final htmlSplitter = HtmlSplitter(
    stripTags: true,          // Remove HTML tags from output
    preserveLinks: true,      // Keep URLs
    splitByHeaders: true,     // Not read in 0.9: headerTags always mark sections
    headerTags: ['h1', 'h2', 'h3'],  // Header levels to split on
  );

  // Chunk size and overlap are options of each call
  const options = TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200);

  const htmlContent = '''
  <html>
  <head><title>Documentation</title></head>
  <body>
    <h1>Introduction</h1>
    <p>This is the introduction section with lots of content.</p>

    <h2>Getting Started</h2>
    <p>Here's how to get started.</p>

    <h2>Advanced Usage</h2>
    <p>For advanced users.</p>
  </body>
  </html>
  ''';

  final chunks = htmlSplitter.splitText(htmlContent, options: options);

  for (final chunk in chunks) {
    print('--- Chunk ---');
    print(chunk);
    print('');
  }

  // Split documents with metadata preservation
  final documents = [
    const Document(content: htmlContent, metadata: {'source': 'docs.html'}),
  ];

  final splitDocs = await htmlSplitter.splitDocuments(documents, options: options);
  for (final doc in splitDocs) {
    print('Source: ${doc.metadata['source']}');
    print('Chunk index: ${doc.metadata['chunk_index']}');
  }
}
