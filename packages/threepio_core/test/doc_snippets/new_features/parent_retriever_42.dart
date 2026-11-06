// Mirror of doc/NEW_FEATURES.md, "4. Advanced Retrieval Patterns > ParentRetriever".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> parentRetriever(Embedder embedder, VectorStore vectorStore, List<Document> documents, TextSplitter splitter) async {
  // Create parent document store
  final parentStore = InMemoryParentDocumentStore();

  // Embeds the chunks and writes them to the vector store
  final indexer = VectorStoreIndexer(vectorStore: vectorStore, embedder: embedder);

  // Index documents with their chunks
  for (final document in documents) {
    // Split into chunks with the ids '<parent id>_chunk_<n>' and record
    // the parent of each chunk
    final chunks = await parentStore.indexDocument(
      document,
      (text) => splitter.splitText(
        text,
        options: const TextSplitterOptions(chunkSize: 400, chunkOverlap: 40),
      ),
    );

    // Add chunks to the vector store (for searching)
    await indexer.store(RunContext.background(), chunks);
  }

  // Create parent retriever
  final parentRetriever = ParentRetriever(
    baseRetriever: VectorRetriever(embedder: embedder, vectorStore: vectorStore),
    parentStore: parentStore,
    returnChunks: false,           // Return parents, not chunks
    includeChunkMetadata: true,    // Add chunk info to parent
    parentScoreStrategy: ParentScoreStrategy.maxChildScore,
  );

  final results = await parentRetriever.retrieve('specific detail');

  // Results contain full parent documents, even though
  // the search matched specific chunks
  for (final doc in results) {
    print('Parent: ${doc.id}');
    print('Matched chunks: ${doc.metadata['matched_chunks_count']}');
  }
}
