// Mirror of doc/NEW_FEATURES.md, "7. Advanced Text Splitters > Combining Splitters with Pipeline".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

// Pick a splitter by file type (`source` is set by the file loaders)
TextSplitter splitterFor(Document doc) {
  final source = doc.metadata['source'] as String? ?? '';
  if (source.endsWith('.html') || source.endsWith('.htm')) {
    return HtmlSplitter();
  } else if (source.endsWith('.md')) {
    return MarkdownRAGSplitter();
  }
  return RecursiveCharacterTextSplitter();
}

Future<List<Document>> splitByType(List<Document> documents) async {
  const options = TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200);
  return [
    for (final doc in documents)
      ...await splitterFor(doc).splitDocuments([doc], options: options),
  ];
}

// In a pipeline: the splitter, and its options in the ingestion options
Future<IngestionResult> ingestMarkdown(
  List<Document> documents,
  Embedder embedder,
  VectorStore vectorStore,
) {
  final pipeline = IngestionPipeline(
    splitter: MarkdownRAGSplitter(includeHeadersInChunks: true),
    embedder: embedder,
    vectorStore: vectorStore,
  );
  return pipeline.ingest(
    documents: documents,
    options: const IngestionOptions(
      splitterOptions: TextSplitterOptions(chunkSize: 500, chunkOverlap: 50),
    ),
  );
}
