// Mirrors "Transformers" of doc/RAG.md.
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

Future<List<Document>> splitters(
  RunContext ctx,
  List<Document> markdownDocs,
  List<Document> htmlDocs,
) async {
  final sections = MarkdownSplitter.fromHeaderConfig(
    const MarkdownHeaderSplitterConfig(headers: {'#': 'title', '##': 'section'}),
  );
  final chunker = RecursiveCharacterTextSplitter.fromConfig(
    RecursiveSplitterConfig(
      chunkSize: 1000, // UTF-8 bytes
      overlapSize: 100,
      separators: const ['\n\n', '\n', '. '],
      keepType: SplitterKeepType.end,
      idGenerator: (ctx, originalId, splitIndex) =>
          '${originalId ?? 'doc'}_$splitIndex',
    ),
  );
  final options = TransformerOptions(runContext: ctx);
  final chunks = await chunker.transform(
    await sections.transform(markdownDocs, options: options),
    options: options,
  );

  final htmlSections = await HtmlSplitter.fromHeaderConfig(
    const HtmlHeaderSplitterConfig(headers: {'h1': 'chapter', 'h2': 'section'}),
  ).transform(htmlDocs, options: options);
  return [...chunks, ...htmlSections];
}

Future<List<Document>> semanticAndReorder(
  RunContext ctx,
  Embedder embedder,
  List<Document> docs,
  List<Document> retrieved,
) async {
  final semantic = SemanticSplitter(
    SemanticSplitterConfig(
      embedding: embedder,
      bufferSize: 1, // embed each sentence with one neighbour on each side
      minChunkSize: 200,
      percentile: 0.9, // cut at the 10 % largest jumps in meaning
    ),
  );
  final semanticChunks = await semantic.transform(
    docs,
    options: TransformerOptions(runContext: ctx),
  );

  const reorder = ScoreReorderTransformer();
  // Scores 0.9, 0.8, 0.7, 0.6, 0.5 come out as 0.9, 0.7, 0.5, 0.6, 0.8.
  final ordered = await reorder.transform(retrieved);
  return [...semanticChunks, ...ordered];
}
