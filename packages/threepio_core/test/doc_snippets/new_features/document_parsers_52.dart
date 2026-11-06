// Mirror of doc/NEW_FEATURES.md, "5. Document Processing Pipeline > Document Parsers".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> documentParsers(String htmlContent, String htmlWithTables) async {
  // HTML Parser
  final htmlParser = HtmlParser(
    removeScripts: true,
    removeStyles: true,
    removeComments: true,
    preserveLinks: true,
    preserveLineBreaks: true,
  );

  final htmlResult = await htmlParser.parseString(htmlContent);
  print('Title: ${htmlResult.document.metadata['title']}');
  print('Content: ${htmlResult.document.content}');

  // With table extraction (an option of the call)
  final result = await htmlParser.parseString(
    htmlWithTables,
    options: const DocumentParserOptions(extractTables: true),
  );
  for (final table in result.extractedTables ?? const <ExtractedTable>[]) {
    print('Table: ${table.caption}');
    print(table.toMarkdown());
  }

  // Markdown Parser
  final mdParser = MarkdownParser(
    parseFrontmatter: true,
    removeFrontmatter: true,
    extractCodeBlocks: true,
  );

  const fence = '```'; // the code fence inside the sample text
  const mdContent = '''
  ---
  title: My Document
  author: John Doe
  tags: [dart, flutter]
  ---

  # Introduction

  This is the content.

  ${fence}dart
  void main() {
    print('Hello');
  }
  $fence
  ''';

  final mdResult = await mdParser.parseString(mdContent);
  print('Title: ${mdResult.document.metadata['title']}');
  print('Author: ${mdResult.document.metadata['author']}');
  print('Code blocks: ${mdResult.metadata?['code_block_count']}');
}
