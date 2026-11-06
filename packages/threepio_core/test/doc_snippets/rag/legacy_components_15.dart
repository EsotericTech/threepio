// Mirrors the older loaders, splitters, parsers and retrievers of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

Future<List<String>> legacyLoadersAndSplitters(
  Embedder embedder,
  VectorStore store,
) async {
  // Bound to one source when created.
  final notes = await TextLoader(filePath: 'notes.txt').load();
  // The glob only looks at the extension: *.txt, *.md or *.*.
  final guides = await DirectoryLoader(dirPath: 'guides', glob: '**/*.md').load();

  // Character counts; options per call, or fixed with withOptions.
  final splitter = RecursiveCharacterTextSplitter().withOptions(
    const TextSplitterOptions(chunkSize: 500, chunkOverlap: 50),
  );
  final chunks = await splitter.transform([...notes, ...guides]);
  final sentences = CharacterTextSplitter(separator: '. ').splitText(
    'First sentence. Second sentence.',
    options: const TextSplitterOptions(chunkSize: 20, chunkOverlap: 0),
  );

  final vectors = await embedder.embedStrings([
    for (final chunk in chunks) chunk.content,
  ]);
  await store.addDocuments([
    for (final (i, chunk) in chunks.indexed) chunk.copyWith(embedding: vectors[i]),
  ]);
  return sentences;
}

Future<List<Object>> legacyBridges(RunContext ctx) async {
  final textFiles = LoaderAdapter((source) => TextLoader(filePath: source.uri));
  final legacyParsers = ExtParser(parsers: {
    '.md': MarkdownParser().asParser(),
    '.html': HtmlParser().asParser(),
  });
  final markdownDocs = await textFiles.load(
    ctx,
    const DocumentSource(uri: 'notes.md'),
  );
  return [legacyParsers, markdownDocs];
}

Future<List<Object>> legacyRetrievers(
  Retriever retriever,
  BaseChatModel chatModel,
  Embedder embedder,
  VectorStore store,
) async {
  final legacyMultiQuery = MultiQueryRetriever(
    baseRetriever: retriever,
    chatModel: chatModel,
    numQueries: 5,
);
  final hybrid = HybridRetriever(
    vectorRetriever: retriever,
    keywordSearcher: InMemoryBM25Searcher(),
  );
  final diverse = RerankerTransformer(
    MMRReranker(embedder: embedder, lambda: 0.7),
    query: 'refund policy',
  );
  final pipeline = IngestionPipeline(
    loader: DirectoryLoader(dirPath: 'guides'),
    splitter: RecursiveCharacterTextSplitter(),
    embedder: embedder,
    vectorStore: store,
  );
  final ingested = await pipeline.ingest();
  print('${ingested.chunksStored} chunks stored');
  return [legacyMultiQuery, hybrid, diverse];
}
