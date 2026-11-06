// Mirror of doc/NEW_FEATURES.md, "7. Advanced Text Splitters > Markdown RAG Splitter".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> markdownRagSplitter(String markdownContent) async {
  final ragSplitter = MarkdownRAGSplitter(
    includeHeadersInChunks: true,   // Prepend the header line to each section
  );

  final chunks = await ragSplitter.splitDocuments(
    [Document(content: markdownContent)],
    options: const TextSplitterOptions(chunkSize: 500, chunkOverlap: 100),
  );

  for (final chunk in chunks) {
    print('Headers: ${chunk.metadata['header_breadcrumbs']}');
    print('Current: ${chunk.metadata['current_header']}');
    print('Content: ${chunk.content}');
    print('');
  }
}
