# Retrieval-Augmented Generation (RAG)

Comprehensive guide to building RAG applications with Threepio Core.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Core Components](#core-components)
  - [Embedders](#embedders)
  - [Vector Stores](#vector-stores)
  - [Retrievers](#retrievers)
  - [Document Loaders](#document-loaders)
  - [Text Splitters](#text-splitters)
  - [RAG Chains](#rag-chains)
- [Complete Examples](#complete-examples)
- [Best Practices](#best-practices)
- [Advanced Patterns](#advanced-patterns)

## Overview

Retrieval-Augmented Generation (RAG) enhances language models by providing them with relevant context retrieved from a knowledge base. This allows models to answer questions accurately using information they weren't trained on.

### How RAG Works

1. **Indexing Phase**: Documents are loaded, split into chunks, embedded, and stored in a vector database
2. **Retrieval Phase**: User queries are embedded and used to find similar document chunks
3. **Generation Phase**: Retrieved chunks provide context for the language model to generate accurate answers

### Benefits

- **Up-to-date information**: Query current documents without retraining
- **Source attribution**: Trace answers back to specific documents
- **Reduced hallucinations**: Ground responses in actual data
- **Domain-specific knowledge**: Incorporate proprietary or specialized information

## Quick Start

Here's a minimal RAG pipeline:

```dart
import 'package:threepio_core/threepio_core.dart';
import 'package:threepio_openai/threepio_openai.dart';

void main() async {
  // 1. Setup components
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final embedder = OpenAIEmbedder(config: config);
  final vectorStore = InMemoryVectorStore();
  final chatModel = OpenAIChatModel(config: config);

  // 2. Load and process documents
  final loader = TextLoader(filePath: 'knowledge.txt');
  final docs = await loader.load();

  final splitter = RecursiveCharacterTextSplitter();
  final chunks = await splitter.splitDocuments(docs);

  // 3. Embed and store
  for (final chunk in chunks) {
    final embeddings = await embedder.embedStrings([chunk.content]);
    await vectorStore.addDocuments([
      chunk.copyWith(embedding: embeddings.first),
    ]);
  }

  // 4. Create RAG chain
  final retriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
  );

  final ragChain = RetrievalQAChain(
    retriever: retriever,
    chatModel: chatModel,
  );

  // 5. Ask questions
  final result = await ragChain.invoke({
    'question': 'What is the capital of France?',
  });

  print('Answer: ${result['answer']}');
  print('Sources: ${result['source_documents']}');
}
```

## Core Components

### Embedders

Embedders convert text into dense vector representations that capture semantic meaning.

#### OpenAI Embedder

```dart
final embedder = OpenAIEmbedder(
  config: OpenAIConfig(apiKey: 'your-api-key'),
  defaultModel: 'text-embedding-3-small', // 1536 dimensions
);

// Embed single text
final embeddings = await embedder.embedStrings(['Hello world']);
print('Dimensions: ${embeddings.first.length}'); // 1536

// Embed multiple texts in batch
final texts = ['First text', 'Second text', 'Third text'];
final vectors = await embedder.embedStrings(texts);

// Large batches with automatic chunking
final largeTexts = List.generate(1000, (i) => 'Document $i');
final allEmbeddings = await embedder.embedStringsChunked(
  largeTexts,
  chunkSize: 100, // Process 100 at a time
);
```

**Available Models**:
- `text-embedding-3-small`: 1536 dimensions, fast and efficient
- `text-embedding-3-large`: 3072 dimensions, higher quality
- `text-embedding-ada-002`: 1536 dimensions, legacy model

**Model Dimensions**:
```dart
final dims = OpenAIEmbedder.getDimensionsForModel('text-embedding-3-small');
print(dims); // 1536
```

### Vector Stores

Vector stores persist document embeddings and enable similarity search.

#### In-Memory Vector Store

```dart
final store = InMemoryVectorStore(
  similarityMetric: SimilarityMetric.cosine, // default
);

// Add documents with embeddings
final docs = [
  Document(
    id: '1',
    content: 'Paris is the capital of France',
    embedding: [0.1, 0.2, 0.3, ...],
  ),
  Document(
    id: '2',
    content: 'Berlin is the capital of Germany',
    embedding: [0.2, 0.3, 0.4, ...],
  ),
];

await store.addDocuments(docs);

// Search with k results
final results = await store.similaritySearch(
  queryEmbedding: [0.15, 0.25, 0.35, ...],
  k: 2,
);

for (final result in results) {
  print('Score: ${result.score}');
  print('Content: ${result.document.content}');
}

// Search with score threshold
final filtered = await store.similaritySearchWithThreshold(
  queryEmbedding: [0.15, 0.25, 0.35, ...],
  scoreThreshold: 0.8, // Only results >= 0.8
);

// Management operations
final count = await store.count();
await store.delete(['1', '2']);
await store.clear();
```

**Similarity Metrics**:
- `SimilarityMetric.cosine`: Cosine similarity (range -1 to 1, default)
- `SimilarityMetric.euclidean`: Euclidean distance (smaller is more similar)
- `SimilarityMetric.dotProduct`: Dot product (higher is more similar)

### Retrievers

Retrievers combine embedders and vector stores to retrieve relevant documents from queries.

#### Vector Retriever

```dart
final retriever = VectorRetriever(
  embedder: embedder,
  vectorStore: vectorStore,
  defaultTopK: 4,
);

// Basic retrieval
final docs = await retriever.retrieve('What is machine learning?');

// With options
final topDocs = await retriever.retrieve(
  'What is machine learning?',
  options: RetrieverOptions(
    topK: 5,
    scoreThreshold: 0.7,
  ),
);

// Get results with scores
final resultsWithScores = await retriever.retrieveWithScores(
  'What is machine learning?',
  options: RetrieverOptions(topK: 3),
);

for (final result in resultsWithScores) {
  print('${result.score.toStringAsFixed(3)}: ${result.document.content}');
}
```

### Document Loaders

Document loaders read content from various sources and convert it into Document objects.

#### Text Loader

```dart
// Load single file
final loader = TextLoader(filePath: 'document.txt');
final docs = await loader.load();

// With custom encoding and metadata
final docs = await loader.load(
  options: DocumentLoaderOptions(
    encoding: 'utf-8',
    metadata: {'category': 'technical', 'author': 'John Doe'},
  ),
);

// Lazy loading for large files
await for (final doc in loader.loadLazy()) {
  print('Loaded: ${doc.source?.uri}');
  // Process document...
}
```

#### Directory Loader

```dart
// Load all text files from a directory
final loader = DirectoryLoader(
  dirPath: 'documents/',
  glob: '**/*.txt',
  recursive: true,
);

final docs = await loader.load();
print('Loaded ${docs.length} documents');

// Lazy loading for large directories
await for (final doc in loader.loadLazy()) {
  print('Processing: ${doc.source?.uri}');
  // Process each document as it loads
}
```

### Text Splitters

Text splitters break large documents into smaller chunks suitable for embedding.

#### Recursive Character Text Splitter

The most versatile splitter - tries to preserve semantic boundaries.

```dart
final splitter = RecursiveCharacterTextSplitter(
  separators: ['\n\n', '\n', '. ', ' ', ''], // default
);

// Split text
final text = '''
This is paragraph one.
It has multiple sentences.

This is paragraph two.
It also has content.
''';

final chunks = splitter.splitText(
  text,
  options: TextSplitterOptions(
    chunkSize: 100,
    chunkOverlap: 20,
  ),
);

print('Created ${chunks.length} chunks');

// Split documents
final docs = [
  Document.simple('Long document content...'),
  Document.simple('Another long document...'),
];

final splitDocs = await splitter.splitDocuments(
  docs,
  options: TextSplitterOptions(
    chunkSize: 500,
    chunkOverlap: 50,
  ),
);

// Each chunk preserves parent metadata
for (final doc in splitDocs) {
  print('Chunk ${doc.metadata['chunk_index']} of ${doc.metadata['total_chunks']}');
  print('Parent ID: ${doc.metadata['parent_id']}');
}
```

**How It Works**:
1. Tries to split on paragraphs (double newlines)
2. Falls back to sentences (periods, exclamation marks, question marks)
3. Falls back to words (spaces)
4. Finally splits on characters if needed

#### Character Text Splitter

Simple fixed-size splitting based on character count.

```dart
final splitter = CharacterTextSplitter(
  separator: '\n',
);

final chunks = splitter.splitText(
  longText,
  options: TextSplitterOptions(
    chunkSize: 1000,
    chunkOverlap: 100,
  ),
);
```

### RAG Chains

RAG chains orchestrate the complete retrieval and generation workflow.

#### Basic Retrieval QA Chain

```dart
final chain = RetrievalQAChain(
  retriever: retriever,
  chatModel: chatModel,
  topK: 4,
  returnSourceDocuments: true,
);

final result = await chain.invoke({
  'question': 'What are the main features of Flutter?',
});

print('Answer: ${result['answer']}');

// Access source documents
final sources = result['source_documents'] as List<Document>;
for (final doc in sources) {
  print('Source: ${doc.source?.uri}');
  print('Content: ${doc.content}');
  print('Score: ${doc.score}');
}
```

#### Custom Document Formatting

```dart
final chain = CustomRetrievalQAChain(
  retriever: retriever,
  chatModel: chatModel,
  documentFormatter: (doc) {
    return '''
[Source: ${doc.source?.uri ?? 'unknown'}]
[Relevance: ${(doc.score ?? 0).toStringAsFixed(2)}]
${doc.content}
---
''';
  },
);
```

#### Conversational RAG

Maintains chat history for multi-turn conversations.

```dart
final chain = ConversationalRetrievalChain(
  retriever: retriever,
  chatModel: chatModel,
);

// First question
var result = await chain.invoke({
  'question': 'What is machine learning?',
  'chat_history': <Message>[],
});

var chatHistory = result['chat_history'] as List<Message>;
print('Answer: ${result['answer']}');

// Follow-up question (uses history for context)
result = await chain.invoke({
  'question': 'What are its applications?', // "its" refers to ML
  'chat_history': chatHistory,
});

chatHistory = result['chat_history'] as List<Message>;
print('Answer: ${result['answer']}');

// Continue conversation
result = await chain.invoke({
  'question': 'Which one is most important?',
  'chat_history': chatHistory,
});
```

## Complete Examples

### Example 1: Technical Documentation Q&A

```dart
import 'package:threepio_core/threepio_core.dart';
import 'package:threepio_openai/threepio_openai.dart';

Future<void> documentationQA() async {
  // Setup
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final embedder = OpenAIEmbedder(config: config);
  final vectorStore = InMemoryVectorStore();
  final chatModel = OpenAIChatModel(config: config);

  // Load documentation
  final loader = DirectoryLoader(
    dirPath: 'docs/',
    glob: '**/*.md',
    recursive: true,
  );

  final docs = await loader.load();
  print('Loaded ${docs.length} documentation files');

  // Split into chunks
  final splitter = RecursiveCharacterTextSplitter();
  final chunks = await splitter.splitDocuments(
    docs,
    options: TextSplitterOptions(
      chunkSize: 1000,
      chunkOverlap: 200,
    ),
  );

  print('Created ${chunks.length} chunks');

  // Embed and index
  print('Indexing documents...');
  for (var i = 0; i < chunks.length; i++) {
    final chunk = chunks[i];
    final embeddings = await embedder.embedStrings([chunk.content]);

    await vectorStore.addDocuments([
      chunk.copyWith(
        id: 'chunk_$i',
        embedding: embeddings.first,
      ),
    ]);

    if ((i + 1) % 10 == 0) {
      print('Indexed ${i + 1}/${chunks.length} chunks');
    }
  }

  // Create RAG chain
  final retriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
    defaultTopK: 5,
  );

  final ragChain = CustomRetrievalQAChain(
    retriever: retriever,
    chatModel: chatModel,
    returnSourceDocuments: true,
    documentFormatter: (doc) {
      final source = doc.metadata['source'] as String? ?? 'unknown';
      final filename = source.split('/').last;
      return '--- $filename ---\n${doc.content}\n';
    },
  );

  // Ask questions
  final questions = [
    'How do I install the package?',
    'What are the main features?',
    'How do I configure authentication?',
  ];

  for (final question in questions) {
    print('\nQ: $question');

    final result = await ragChain.invoke({'question': question});

    print('A: ${result['answer']}');

    if (result.containsKey('source_documents')) {
      final sources = result['source_documents'] as List<Document>;
      print('\nSources:');
      for (final doc in sources) {
        final filename = (doc.metadata['source'] as String).split('/').last;
        print('  - $filename (score: ${doc.score?.toStringAsFixed(2)})');
      }
    }

    print('---');
  }
}
```

### Example 2: Multi-Language Customer Support

```dart
Future<void> customerSupportRAG() async {
  // Setup
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final embedder = OpenAIEmbedder(
    config: config,
    defaultModel: 'text-embedding-3-large', // Better for multi-language
  );
  final vectorStore = InMemoryVectorStore();
  final chatModel = OpenAIChatModel(config: config);

  // Load support articles
  final loader = DirectoryLoader(
    dirPath: 'support_articles/',
    glob: '**/*.txt',
    recursive: true,
  );

  final docs = await loader.load();

  // Split and categorize
  final splitter = RecursiveCharacterTextSplitter();
  final chunks = await splitter.splitDocuments(docs);

  // Index with metadata
  for (final chunk in chunks) {
    final embeddings = await embedder.embedStrings([chunk.content]);

    // Extract language from metadata or content
    final language = chunk.metadata['language'] ?? 'en';
    final category = chunk.metadata['category'] ?? 'general';

    await vectorStore.addDocuments([
      chunk.copyWith(
        embedding: embeddings.first,
        metadata: {
          ...chunk.metadata,
          'language': language,
          'category': category,
        },
      ),
    ]);
  }

  // Create conversational RAG
  final retriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
  );

  final chain = ConversationalRetrievalChain(
    retriever: retriever,
    chatModel: chatModel,
    topK: 3,
    returnSourceDocuments: true,
  );

  // Simulate customer conversation
  var chatHistory = <Message>[];

  final conversation = [
    'How do I reset my password?',
    'What if I don\'t receive the email?',
    'Can I use my phone number instead?',
  ];

  for (final question in conversation) {
    print('Customer: $question');

    final result = await chain.invoke({
      'question': question,
      'chat_history': chatHistory,
    });

    final answer = result['answer'];
    chatHistory = result['chat_history'] as List<Message>;

    print('Support: $answer\n');
  }
}
```

### Example 3: Research Paper Analysis

```dart
Future<void> researchPaperAnalysis() async {
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final embedder = OpenAIEmbedder(config: config);
  final vectorStore = InMemoryVectorStore();
  final chatModel = OpenAIChatModel(config: config);

  // Load research papers
  final loader = TextLoader(filePath: 'research_papers.txt');
  final docs = await loader.load();

  // Split with larger chunks for research content
  final splitter = RecursiveCharacterTextSplitter(
    separators: ['\n\n## ', '\n\n', '\n', ' ', ''],
  );

  final chunks = await splitter.splitDocuments(
    docs,
    options: TextSplitterOptions(
      chunkSize: 1500,
      chunkOverlap: 300,
    ),
  );

  // Index chunks
  for (final chunk in chunks) {
    final embeddings = await embedder.embedStrings([chunk.content]);
    await vectorStore.addDocuments([
      chunk.copyWith(embedding: embeddings.first),
    ]);
  }

  // Create RAG chain with custom prompt
  final retriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
    defaultTopK: 6,
  );

  final chain = RetrievalQAChain(
    retriever: retriever,
    chatModel: chatModel,
    promptTemplate: '''You are an expert research assistant analyzing academic papers.

Context from papers:
{context}

Question: {question}

Provide a detailed, academic response with citations where possible:''',
  );

  // Analyze papers
  final analyses = [
    'What are the main findings?',
    'What methodologies were used?',
    'What are the limitations?',
    'How do these findings compare to previous research?',
  ];

  for (final query in analyses) {
    final result = await chain.invoke({'question': query});
    print('Q: $query');
    print('A: ${result['answer']}\n');
  }
}
```

## Best Practices

### 1. Chunk Size Selection

```dart
// For general text
final generalSplitter = RecursiveCharacterTextSplitter();
final chunks = splitter.splitText(
  text,
  options: TextSplitterOptions(
    chunkSize: 1000,   // Good balance
    chunkOverlap: 200, // 20% overlap
  ),
);

// For code
final codeSplitter = CharacterTextSplitter(separator: '\n');
final codeChunks = codeSplitter.splitText(
  code,
  options: TextSplitterOptions(
    chunkSize: 500,    // Smaller for code
    chunkOverlap: 50,
  ),
);

// For structured data
final structuredSplitter = RecursiveCharacterTextSplitter(
  separators: ['\n\n## ', '\n\n# ', '\n\n', '\n'],
);
```

### 2. Embedding Model Selection

```dart
// Fast and efficient (most cases)
final smallEmbedder = OpenAIEmbedder(
  config: config,
  defaultModel: 'text-embedding-3-small',
);

// High quality (when accuracy is critical)
final largeEmbedder = OpenAIEmbedder(
  config: config,
  defaultModel: 'text-embedding-3-large',
);
```

### 3. Retrieval Tuning

```dart
// Adjust topK based on document length and question complexity
final retriever = VectorRetriever(
  embedder: embedder,
  vectorStore: vectorStore,
  defaultTopK: 5, // Experiment: 3-7 usually works well
);

// Use score thresholds to filter low-quality results
final docs = await retriever.retrieve(
  question,
  options: RetrieverOptions(
    topK: 10,
    scoreThreshold: 0.7, // Only keep highly relevant docs
  ),
);
```

### 4. Metadata Management

```dart
// Add rich metadata during loading
final docs = await loader.load(
  options: DocumentLoaderOptions(
    metadata: {
      'timestamp': DateTime.now().toIso8601String(),
      'version': '1.0',
      'author': 'John Doe',
      'category': 'technical',
      'language': 'en',
    },
  ),
);

// Use metadata for filtering and display
for (final result in results) {
  final category = result.document.metadata['category'];
  print('[$category] ${result.document.content}');
}
```

### 5. Error Handling

```dart
try {
  final result = await ragChain.invoke({'question': question});
  print(result['answer']);
} on OpenAIException catch (e) {
  print('API Error: ${e.message}');
  // Fallback or retry logic
} on VectorStoreException catch (e) {
  print('Storage Error: ${e.message}');
} catch (e) {
  print('Unexpected Error: $e');
}
```

### 6. Performance Optimization

```dart
// Batch embeddings
final allTexts = chunks.map((c) => c.content).toList();
final allEmbeddings = await embedder.embedStringsChunked(
  allTexts,
  chunkSize: 100, // Adjust based on API limits
);

// Parallel document loading
final loaders = [
  DirectoryLoader(dirPath: 'docs/'),
  DirectoryLoader(dirPath: 'articles/'),
];

final allDocs = await Future.wait(
  loaders.map((l) => l.load()),
);

final flatDocs = allDocs.expand((d) => d).toList();
```

## Advanced Patterns

### Hybrid Search (Dense + Sparse)

Combine vector similarity with keyword matching:

```dart
class HybridRetriever implements Retriever {
  HybridRetriever({
    required this.vectorRetriever,
    required this.keywordSearcher,
    this.vectorWeight = 0.7,
  });

  final VectorRetriever vectorRetriever;
  final KeywordSearcher keywordSearcher;
  final double vectorWeight;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Get results from both methods
    final vectorResults = await vectorRetriever.retrieveWithScores(
      query,
      options: options,
    );

    final keywordResults = await keywordSearcher.search(query);

    // Merge and re-rank
    final merged = _mergeResults(
      vectorResults,
      keywordResults,
      vectorWeight: vectorWeight,
    );

    return merged.map((r) => r.document).toList();
  }

  List<SimilaritySearchResult> _mergeResults(
    List<SimilaritySearchResult> vector,
    List<KeywordResult> keyword, {
    required double vectorWeight,
  }) {
    // Implement fusion (e.g., reciprocal rank fusion)
    // ...
  }
}
```

### Multi-Query Retrieval

Generate multiple query variations for better recall:

```dart
Future<List<Document>> multiQueryRetrieval(
  String originalQuery,
  VectorRetriever retriever,
  BaseChatModel chatModel,
) async {
  // Generate query variations
  final prompt = '''Generate 3 different versions of this question to improve retrieval:

Original: $originalQuery

Variations:''';

  final response = await chatModel.generate([Message.user(prompt)]);
  final variations = response.content.split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();

  // Retrieve for all variations
  final allResults = await Future.wait([
    retriever.retrieve(originalQuery),
    ...variations.map((v) => retriever.retrieve(v)),
  ]);

  // Deduplicate and merge
  final uniqueDocs = <String, Document>{};
  for (final results in allResults) {
    for (final doc in results) {
      uniqueDocs[doc.id ?? doc.content] = doc;
    }
  }

  return uniqueDocs.values.toList();
}
```

### Re-ranking

Re-score retrieved documents for better precision:

```dart
Future<List<Document>> rerank(
  List<Document> documents,
  String query,
  BaseChatModel chatModel,
) async {
  final scored = <MapEntry<Document, double>>[];

  for (final doc in documents) {
    final prompt = '''Rate the relevance of this document to the query on a scale of 0-10.

Query: $query

Document: ${doc.content}

Relevance (0-10):''';

    final response = await chatModel.generate([Message.user(prompt)]);
    final score = double.tryParse(response.content.trim()) ?? 0.0;

    scored.add(MapEntry(doc, score));
  }

  // Sort by score
  scored.sort((a, b) => b.value.compareTo(a.value));

  return scored.map((e) => e.key).toList();
}
```

### Hierarchical Retrieval

Retrieve documents in two stages:

```dart
Future<List<Document>> hierarchicalRetrieval(
  String query,
  VectorRetriever summaryRetriever,
  VectorRetriever detailRetriever,
) async {
  // Stage 1: Find relevant document summaries
  final summaries = await summaryRetriever.retrieve(
    query,
    options: RetrieverOptions(topK: 5),
  );

  // Stage 2: Retrieve detailed chunks from those documents
  final detailedDocs = <Document>[];

  for (final summary in summaries) {
    final parentId = summary.metadata['document_id'];

    // Retrieve chunks from this parent document
    final chunks = await detailRetriever.retrieve(
      query,
      options: RetrieverOptions(
        topK: 3,
        extra: {'parent_id': parentId}, // Filter by parent
      ),
    );

    detailedDocs.addAll(chunks);
  }

  return detailedDocs;
}
```

---

## Summary

Threepio Core provides all the building blocks for sophisticated RAG applications:

1. **Embedders** - Convert text to vectors (OpenAI)
2. **Vector Stores** - Store and search embeddings (In-Memory)
3. **Retrievers** - Combine embedding and search (Vector Retriever)
4. **Loaders** - Read documents from sources (Text, Directory)
5. **Splitters** - Chunk large documents (Recursive, Character)
6. **Chains** - Orchestrate RAG workflows (QA, Conversational)

For more information:
- [Callbacks Documentation](./CALLBACKS.md)
- [Core Concepts](../README.md)
- [API Reference](https://pub.dev/documentation/threepio_core/latest/)
