// Mirror of doc/NEW_FEATURES.md, "7. Advanced Text Splitters > Markdown Splitter".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> markdownSplitter() async {
  final mdSplitter = MarkdownSplitter(
    preserveCodeBlocks: true,   // Keep code blocks intact
    splitOnHeaders: true,       // Split at header boundaries
    minHeaderLevel: 1,          // Start splitting at h1
    maxHeaderLevel: 3,          // Don't split below h3
  );

  const fence = '```'; // the code fence inside the sample text
  const markdownContent = '''
  # Main Title

  Introduction paragraph.

  ## Section 1

  Content for section 1.

  ### Subsection 1.1

  More detailed content.

  ${fence}python
  def example():
      return "This code block stays together"
  $fence

  ## Section 2

  Content for section 2.
  ''';

  final chunks = mdSplitter.splitText(
    markdownContent,
    options: const TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200),
  );
  print('${chunks.length} chunks');
}
