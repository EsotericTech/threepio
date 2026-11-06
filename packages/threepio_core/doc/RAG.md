# Retrieval-augmented generation (RAG)

Retrieval-augmented generation answers a question with documents found for
it: documents are loaded, cut into chunks, embedded and stored (indexing); at
question time the closest chunks are retrieved and handed to a chat model
together with the question (querying).

threepio builds this from the component contracts of Eino
(`components/embedding`, `components/indexer`, `components/retriever`,
`components/document`), the implementations of eino-ext, and the retrieval
flows of Eino's `flow` package. This guide covers all three, an end-to-end
pipeline as a compose graph, and the older RAG API that still exists.

## Contents

- [Libraries](#libraries)
- [How the pieces fit](#how-the-pieces-fit)
- [Contracts and call options](#contracts-and-call-options)
- [Documents and their metadata](#documents-and-their-metadata)
- [Embedders](#embedders)
- [Indexers](#indexers)
- [Retrievers](#retrievers)
- [Loaders and parsers](#loaders-and-parsers)
- [Transformers](#transformers)
- [Retrieval flows](#retrieval-flows)
- [An end-to-end pipeline](#an-end-to-end-pipeline)
- [Differences from Eino](#differences-from-eino)
- [Legacy API (before 0.9)](#legacy-api-before-09)
- [See also](#see-also)

## Libraries

| Library | What it has for RAG |
|---|---|
| `package:threepio_core/schema.dart` | `Document`, `DocumentSource` and the metadata accessors (`DocumentMetaX`), `Message`. |
| `package:threepio_core/components.dart` | The contracts and their options, the in-memory vector store, `VectorStoreIndexer`, `VectorRetriever`, Qdrant (`QdrantClient`, `QdrantIndexer`, `QdrantRetriever`), `UrlLoader.fromConfig`, the parsers, the splitters, `ScoreReorderTransformer`, `CachingEmbedder` and `InMemoryEmbeddingCache`. Runs on every platform. |
| `package:threepio_core/flow.dart` | `MultiQueryRetriever.fromConfig`, `ParentRetriever.fromConfig`, `RouterRetriever.fromConfig`, `ParentIndexer`, `concurrentRetrieve`. Re-exports `components.dart` and `schema.dart`. |
| `package:threepio_core/io.dart` | What needs `dart:io`: `FileLoader` and `FileEmbeddingCache`. |
| `package:threepio_core/threepio_core.dart` | The umbrella. Adds the embedding providers (`OpenAIEmbedder`, `GeminiEmbedder`, `OllamaEmbedder`) and the older file loaders (`TextLoader`, `DirectoryLoader`). |
| `package:threepio_core/compose.dart` | `Graph`, `Chain`, `Lambda`, `CallOption`, for the pipeline. |
| `package:threepio_core/callbacks.dart` | `HandlerHelper` and the typed handlers (`RetrieverCallbackHandler`, …), `LangfuseHandler`, `LangSmithHandler`. |
| `package:threepio_core/legacy_chains.dart` | `RetrievalQAChain` and the other LangChain-style chains. |

The snippets assume `ctx` is a `RunContext` (`RunContext.background()` when
you have none), `embedder` an `Embedder` and `chatModel` a `BaseChatModel`;
other names a snippet uses without declaring (`apiKey`, `documents`,
`docsRetriever`, `markdownDocs`, …) are what their names say. Each snippet
compiles on its own with those in scope; they are not meant to be pasted into
one function.

## How the pieces fit

```text
 indexing                                        querying

 DocumentSource                                  question (String)
      |                                               |
      v                                               v
   Loader ----> Parser (bytes -> documents)      Retriever <---- Embedder
      |                                               |    (embeds the query)
      v                                               v
 DocumentTransformer (split, reorder)         List<Document>
      |                                               |
      v                                               v
   Indexer <---- Embedder                        ChatTemplate (question + context)
      |    (embeds the chunks)                        |
      v                                               v
 vector store  =======================>          BaseChatModel ----> answer
 (in memory, Qdrant)
```

A parser is not a graph node of its own: a loader hands the bytes it reads to
its parser. The other boxes are components that can be called directly or
placed in a `Graph` or `Chain` (`addLoaderNode`, `addDocumentTransformerNode`,
`addIndexerNode`, `addEmbeddingNode`, `addRetrieverNode`).

## Contracts and call options

| Eino interface | Dart contract | Method |
|---|---|---|
| `embedding.Embedder` | `Embedder` | `embedStrings(List<String> texts, {EmbedderOptions? options})` |
| `indexer.Indexer` | `Indexer` | `store(RunContext ctx, List<Document> docs, {IndexerOptions? options})` |
| `retriever.Retriever` | `Retriever` | `retrieve(String query, {RetrieverOptions? options})` |
| `document.Loader` | `Loader` | `load(RunContext ctx, DocumentSource source, {LoaderOptions? options})` |
| `parser.Parser` | `Parser` | `parse(RunContext ctx, Stream<List<int>> bytes, {ParserOptions? options})` |
| `document.Transformer` | `DocumentTransformer` | `transform(List<Document> documents, {TransformerOptions? options})` |

Where Go takes `ctx context.Context` first, three of the contracts take a
`RunContext` first. `Embedder`, `Retriever` and `DocumentTransformer` existed
in threepio before `RunContext` did and kept their signatures: their context
travels in the options (`EmbedderOptions.runContext`,
`RetrieverOptions.runContext`, `TransformerOptions.runContext`). A graph sets
it for its nodes; when you call such a component yourself, pass it, or the
component runs without your callback handlers and cancel token.

Go passes a list of option functions (`retriever.WithTopK(3)`); Dart passes one
immutable object. `merge` takes the place of applying options one after the
other, and `extensions` carries options that only one implementation knows
(Go's `WrapImplSpecificOptFn`), read back with `extension<T>()` (Go's
`GetImplSpecificOptions`).

| Options | Fields (Go option) |
|---|---|
| `EmbedderOptions` | `model` (`WithModel`), `runContext`, `extensions`, `extra` |
| `IndexerOptions` | `index` (`WithIndex`), `subIndexes` (`WithSubIndexes`), `embedding` (`WithEmbedding`), `extensions` |
| `RetrieverOptions` | `topK` (`WithTopK`), `scoreThreshold` (`WithScoreThreshold`), `index` (`WithIndex`), `subIndex` (`WithSubIndex`), `embedding` (`WithEmbedding`), `dslInfo` (`WithDSLInfo`), `runContext`, `extensions`, plus threepio's `extra` and `metadata` |
| `LoaderOptions` | `parserOptions` (`WithParserOptions`), `extensions` |
| `ParserOptions` | `uri` (`WithURI`), `extraMeta` (`WithExtraMeta`), `extensions` |
| `TransformerOptions` | `runContext`, `extensions` (Eino has no common transformer options) |

A component ignores the settings it has no use for: a store with one index
ignores `index`. `RetrieverOptions.callbackManager` and `.context` belong to
the older callback API and are deprecated; use `runContext`.

A retriever of your own implements the contract and, optionally,
`TypedComponent` (Go `components.Typer`), whose name shows in traces:

```dart
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

/// An option only [KeywordRetriever] understands.
final class KeywordOptions {
  const KeywordOptions({this.caseSensitive = false});

  final bool caseSensitive;
}

/// Returns the documents that contain the query.
final class KeywordRetriever implements Retriever, TypedComponent {
  KeywordRetriever(this.documents);

  final List<Document> documents;

  /// Shows in traces as `KeywordRetriever`.
  @override
  String get componentTypeName => 'Keyword';

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    options?.runContext?.cancelToken.throwIfCancelled();
    final caseSensitive =
        options?.extension<KeywordOptions>()?.caseSensitive ?? false;
    bool matches(Document doc) => caseSensitive
        ? doc.content.contains(query)
        : doc.content.toLowerCase().contains(query.toLowerCase());
    return documents.where(matches).take(options?.topK ?? 4).toList();
  }
}
```

```dart
final keyword = KeywordRetriever([
  Document(id: 'eino', content: 'Eino is an LLM framework written in Go.'),
  Document(id: 'threepio', content: 'threepio is the Dart port of Eino.'),
]);
final hits = await keyword.retrieve(
  'dart',
  options: RetrieverOptions(
    topK: 1,
    runContext: ctx,
    extensions: const [KeywordOptions(caseSensitive: true)],
  ),
);
print(hits); // [] - "Dart" is capitalised in the document
```

`KeywordRetriever` does not fire callbacks itself, so it is reported only
where something reports it: as a graph node (the graph fires the start and
end callbacks around a component that is not a `CallbackAwareComponent`, Go
`components.Checker`) or under the multi-query and router retrievers.
The shipped embedders, `VectorRetriever`, the Qdrant indexer and retriever,
`FileLoader`, the URL loader and `DefaultChatTemplate` fire their own, with
the typed payloads (`EmbeddingCallbackInput`, `RetrieverCallbackInput`,
`IndexerCallbackInput`, `LoaderCallbackInput`, …), also when called directly
with a `runContext`.

## Documents and their metadata

`Document` (Go `schema.Document`) has an optional `id`, the `content`, a
`metadata` map, and three fields Go's `schema.Document` does not have:
`source` (`DocumentSource`), `embedding` and `score` (Go keeps the vector and
the score in the metadata). The extension `DocumentMetaX`
ports Go's `With…` methods and getters, with Go's metadata keys, so documents
stay readable on both sides. A document is immutable: every `with…` returns a
copy.

| Dart | Go | Metadata key |
|---|---|---|
| `withSubIndexes(list)`, `subIndexes` | `WithSubIndexes`, `SubIndexes` | `_sub_indexes` |
| `withScore(double)`, `effectiveScore` | `WithScore`, `Score` | `_score` (and the `score` field) |
| `withExtraInfo(text)`, `extraInfo` | `WithExtraInfo`, `ExtraInfo` | `_extra_info` |
| `withDslInfo(map)`, `dslInfo` | `WithDSLInfo`, `DSLInfo` | `_dsl` |
| `withDenseVector(list)`, `denseVector` | `WithDenseVector`, `DenseVector` | `_dense_vector` (and the `embedding` field) |
| `withSparseVector(map)`, `sparseVector` | `WithSparseVector`, `SparseVector` | `_sparse_vector` |

```dart
final doc = Document(
  id: 'faq-1',
  content: 'Reset your password from the login page.',
)
    .withSubIndexes(['faq'])
    .withScore(0.92)
    .withDenseVector([0.1, 0.4, 0.2])
    .withExtraInfo('help centre');

print(doc.subIndexes); // [faq]
print(doc.effectiveScore); // 0.92: the score field, else the _score entry
print(doc.denseVector); // [0.1, 0.4, 0.2]
print(doc.metadata.keys); // (_sub_indexes, _score, _dense_vector, _extra_info)
```

`effectiveScore` and the other getters return `null` where Go returns a zero
value (`Score()` gives 0 for a document without a score). They also accept
what comes back from JSON: a `List<dynamic>` of numbers, a map with string
keys.

## Embedders

Every embedder implements `Embedder`; the provider embedders also report each
call to the callback handlers of `options.runContext` (and the global ones)
with an `EmbeddingCallbackInput` and an `EmbeddingCallbackOutput` that carries
the token usage, and can be cancelled through that context. Each creates its
HTTP client on first use; call `dispose()` when you are done, or pass an
`httpClient` you close yourself.

| Embedder | eino-ext | Notes |
|---|---|---|
| `OpenAIEmbedder` | `embedding/openai` | `defaultModel` (`text-embedding-3-small`), `dimensions`, `encodingFormat` (`float`, or `base64`, decoded for you), `user`; Azure through `OpenAIConfig(byAzure: true, apiVersion: …)` |
| `OpenAIEmbedder.dashScope` | `embedding/dashscope` | DashScope's OpenAI-compatible mode; `dimensions` defaults to 1024 |
| `GeminiEmbedder` | `embedding/gemini` | `GeminiEmbeddingConfig`: `model`, `taskType` (`GeminiEmbeddingTaskType`), `title`, `outputDimensionality` |
| `OllamaEmbedder` | `embedding/ollama` | `OllamaEmbedderConfig`: `model`, `baseUrl` (`http://localhost:11434`), `truncate`, `keepAlive`, `options` |
| `CachingEmbedder` | `embedding/cache` | Wraps another embedder; see below |

```dart
import 'package:threepio_core/threepio_core.dart';

final openAI = OpenAIEmbedder(
  config: OpenAIConfig(apiKey: apiKey),
  defaultModel: 'text-embedding-3-large',
  dimensions: 1024, // shorter vectors, for the models that support it
);
try {
  final vectors = await openAI.embedStrings(
    ['What is Eino?', 'How do I split a PDF?'],
    options: EmbedderOptions(runContext: ctx),
  );
  print('${vectors.length} vectors of ${vectors.first.length} dimensions');
} finally {
  openAI.dispose();
}
```

```dart
final dashScope = OpenAIEmbedder.dashScope(
  apiKey: dashScopeKey,
  model: 'text-embedding-v3',
);

final gemini = GeminiEmbedder(
  config: GeminiEmbeddingConfig(
    apiKey: geminiKey,
    model: 'gemini-embedding-001',
    taskType: GeminiEmbeddingTaskType.retrievalDocument,
    outputDimensionality: 768,
  ),
);

final ollama = OllamaEmbedder(
  config: const OllamaEmbedderConfig(model: 'nomic-embed-text'),
);
```

Use the same model for indexing and querying; vectors of different models
cannot be compared.

`CachingEmbedder` (Go `cache.NewEmbedder`) looks every text up in an
`EmbeddingCache` under the key a `CacheKeyGenerator` makes from the text and
the model of the call, embeds the misses in one call to the wrapped embedder,
and stores the new vectors for `expiration` (two hours by default; zero or
less keeps them without a limit). A store that fails is logged and ignored.

| Part | Implementations |
|---|---|
| `EmbeddingCache` (Go `Cacher`) | `InMemoryEmbeddingCache({maxEntries})` (LRU when bounded); `FileEmbeddingCache(directory, {hash})` in `io.dart`, in place of Go's Redis backend |
| `CacheKeyGenerator` (Go `Generator`) | `SimpleCacheKeyGenerator()` (`'<text>-<model>'`); `HashCacheKeyGenerator(hash)` with a hash function you pass, for example `(bytes) => sha256.convert(bytes).bytes` from `package:crypto` |

```dart
import 'dart:io';

import 'package:threepio_core/io.dart';
import 'package:threepio_core/threepio_core.dart';

final inner = OpenAIEmbedder(config: OpenAIConfig(apiKey: apiKey));
final cached = CachingEmbedder(
  inner,
  cache: FileEmbeddingCache(Directory('.embedding_cache')),
  keyGenerator: const SimpleCacheKeyGenerator(),
  expiration: const Duration(days: 7),
); // inner.dispose() when done
```

`CachingEmbedder` fires no callbacks of its own, as in Go; the wrapped
embedder reports its calls, for the cache misses only.

## Indexers

`VectorStoreIndexer` is the `Indexer` over threepio's `VectorStore` interface
(the in-memory store, or one of yours); `VectorRetriever` is the reading half.
For every call it gives each document without an id a random UUID, embeds the
documents that have no vector (with `IndexerOptions.embedding`, else its own
embedder), records `IndexerOptions.subIndexes` with `withSubIndexes`, and adds
the documents to the store in one call.

```dart
final store = InMemoryVectorStore(); // cosine similarity by default
final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);

final ids = await indexer.store(
  ctx,
  [
    Document(id: 'eino', content: 'Eino is an LLM framework written in Go.'),
    Document(content: 'threepio is the Dart port of Eino.'), // gets a UUID
  ],
  options: const IndexerOptions(subIndexes: ['intro']),
);
print(ids); // [eino, 0b6f…]
```

`QdrantIndexer` (eino-ext `indexer/qdrant`) stores each document as a point of
a Qdrant collection: the document id is the point id (it must be a UUID;
documents without one get one), the vector comes from the embedder, and the
payload holds `content` and `metadata`. Documents are embedded and upserted
`batchSize` (10) at a time. `QdrantIndexer.create` is asynchronous because it
creates the collection when the server does not have it, with `vectorDim`
and `distance`.

```dart
final qdrant = QdrantClient(
  apiKey: qdrantKey, // sent as the api-key header when set
); // http://localhost:6333 unless baseUrl says otherwise
final qdrantIndexer = await QdrantIndexer.create(
  ctx,
  QdrantIndexerConfig(
    client: qdrant,
    collection: 'docs',
    vectorDim: 1536, // only used to create the collection
    distance: QdrantDistance.cosine,
    embedding: embedder,
  ),
);
await qdrantIndexer.store(ctx, documents);
```

`QdrantClient` talks to Qdrant's REST API (port 6333) instead of gRPC, so it
needs nothing but `package:http` and runs on every platform. Close it with
`close()`; the indexer and retriever do not.

## Retrievers

`VectorRetriever` embeds the query (with `RetrieverOptions.embedding`, else its
own embedder) and asks its vector store for the `topK` closest documents
(`defaultTopK`, 4, when the call sets none). With a `scoreThreshold` it asks
for every document at or above it and keeps the best `topK`. The documents
come back with their similarity in `score`.

```dart
final retriever = VectorRetriever(embedder: embedder, vectorStore: store);
final found = await retriever.retrieve(
  'What is threepio?',
  options: RetrieverOptions(topK: 2, scoreThreshold: 0.3, runContext: ctx),
);
for (final doc in found) {
  print('${doc.score?.toStringAsFixed(2)}  ${doc.content}');
}
```

`QdrantRetriever` (eino-ext `retriever/qdrant`) embeds the query and sends it
to `POST /collections/{collection}/points/query`, which needs **Qdrant 1.10 or
later**. Each point becomes a document with the point id, the payload's
`content`, the payload's `metadata` under the metadata key `metadata`, and the
score (`withScore`). The call's `topK` and `scoreThreshold` override the
configuration (`topK` 5 by default); a payload filter goes in the
implementation-specific `QdrantRetrieverOptions`, in Qdrant's REST form.

```dart
final qdrantRetriever = QdrantRetriever(
  QdrantRetrieverConfig(
    client: qdrant,
    collection: 'docs',
    embedding: embedder,
    topK: 5,
  ),
);
final inFrance = await qdrantRetriever.retrieve(
  'tourist attraction',
  options: RetrieverOptions(
    runContext: ctx,
    scoreThreshold: 0.5,
    extensions: const [
      QdrantRetrieverOptions(filter: {
        'must': [
          {'key': 'metadata.country', 'match': {'value': 'France'}},
        ],
      }),
    ],
  ),
);
```

Unlike Go, the per-call `scoreThreshold` is sent to Qdrant; Go sends only the
configured one.

## Loaders and parsers

A `Loader` reads a `DocumentSource` (a file path, a URL) and hands the bytes to
a `Parser`, which returns documents. `ExtParser` picks a parser by the file
extension of `ParserOptions.uri` and falls back to `TextParser`.

| Component | eino-ext | Library | Notes |
|---|---|---|---|
| `FileLoader(FileLoaderConfig)` | `loader/file` | `io.dart` | `useNameAsId`; the default parser is an `ExtParser` with only the text fallback. Metadata: `_file_name` (`fileLoaderMetaKeyFileName`), `_extension` (`fileLoaderMetaKeyExtension`), `_source` (`metaKeySource`) |
| `UrlLoader.fromConfig(UrlLoaderConfig)` | `loader/url` | `components.dart` | `parser` (default: the HTML parser on `<body>`), `httpClient`, `requestBuilder`, `timeout`. The status code is not checked, as in Go |
| `TextParser()` | `parser.TextParser` | `components.dart` | UTF-8; invalid bytes become U+FFFD |
| `ExtParser({parsers, fallbackParser})` | `parser.ExtParser` | `components.dart` | Keys are extensions with their dot: `'.html'` |
| `HtmlParser.fromConfig(HtmlParserConfig)` | `parser/html` | `components.dart` | `selector` (CSS; `null` takes the whole page); text sanitized and HTML-escaped as bluemonday does; title, description, language, charset in `_title`, `_description`, `_language`, `_charset` |
| `PdfParser(extractor:, config:)` | `parser/pdf` | `components.dart` | Text from a `PdfTextExtractor` you provide; `toPages` |
| `DocxParser(DocxParserConfig)` | `parser/docx` | `components.dart` | Markdown by section (headers, main, tables, footers); `toSections`, `includeHeaders`, `includeFooters`, `includeTables` |
| `XlsxParser(XlsxParserConfig)` | `parser/xlsx` | `components.dart` | One document per row; `sheetName`, `noHeader`, `idPrefix`; values by header under `_row` |

`HtmlParser.fromConfig` and `UrlLoader.fromConfig` are static methods of the
older `HtmlParser` and `UrlLoader` classes, which keep their own behaviour;
they return the eino-ext implementations (`HtmlContentParser`,
`UrlContentLoader`), typed as `Parser` and `Loader`.

```dart
import 'package:threepio_core/components.dart';
import 'package:threepio_core/io.dart';
import 'package:threepio_core/schema.dart';

final loader = FileLoader(
  FileLoaderConfig(
    useNameAsId: true,
    parser: ExtParser(
      parsers: {
        '.html': HtmlParser.fromConfig(),
        '.docx': const DocxParser(),
        '.xlsx': const XlsxParser(),
      },
    ), // anything else is read as UTF-8 text
  ),
);
final docs = await loader.load(
  ctx,
  const DocumentSource(uri: 'notes/guide.html'),
);
print(docs.single.id); // guide.html
print(docs.single.metadata[fileLoaderMetaKeyFileName]); // guide.html
```

The loader hands its parser the file name, extension and path as
`ParserOptions.extraMeta`. Parser options given in the call
(`LoaderOptions.parserOptions`) are applied after them and replace them field
by field, as in Go: a call with an `extraMeta` of its own loses the file name
and extension entries.

```dart
import 'package:http/http.dart' as http;
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

final web = UrlLoader.fromConfig(
  UrlLoaderConfig(
    parser: HtmlParser.fromConfig(const HtmlParserConfig(selector: 'article')),
    timeout: const Duration(seconds: 20),
    // A request can be sent only once: build a new one for every load.
    requestBuilder: (ctx, source, options) =>
        http.Request('GET', Uri.parse(source.uri))
          ..headers['User-Agent'] = 'my-rag-bot/1.0',
  ),
);
final page = await web.load(
  ctx,
  const DocumentSource(uri: 'https://example.com/post'),
);
print(page.single.metadata[htmlMetaKeyTitle]);
```

There is no pure-Dart PDF text extraction of acceptable quality, so
`PdfParser` takes the text from a `PdfTextExtractor`: a plugin around pdfium
or PDFKit, a server, a fake in tests.

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

/// Hands the PDF to whatever extracts text in your app.
final class CallbackPdfExtractor implements PdfTextExtractor {
  CallbackPdfExtractor(this._extract);

  final Future<List<String>> Function(Uint8List bytes) _extract;

  @override
  Future<List<String>> extractPageTexts(RunContext ctx, Uint8List pdfBytes) =>
      _extract(pdfBytes);
}

Future<List<Document>> parseReport(
  RunContext ctx,
  Future<List<String>> Function(Uint8List bytes) extract,
) {
  final parser = PdfParser(
    extractor: CallbackPdfExtractor(extract),
    config: const PdfParserConfig(toPages: true), // one document per page
  );
  return parser.parse(
    ctx,
    File('report.pdf').openRead(),
    options: const ParserOptions(extraMeta: {'kind': 'report'}),
  );
}
```

```dart
const docx = DocxParser(
  DocxParserConfig(toSections: true, includeTables: true),
);
final sections = await docx.parse(ctx, File('handbook.docx').openRead());
print(sections.map(DocxParser.sectionTypeOf)); // (main, tables) here

const xlsx = XlsxParser(XlsxParserConfig(sheetName: 'Prices', idPrefix: 'p'));
final rows = await xlsx.parse(ctx, File('prices.xlsx').openRead());
print(rows.first.id); // p1: the first row under the header
print(rows.first.metadata[xlsxMetaKeyRow]); // {Item: Tea, Price: 3.5}
```

`XlsxParser` applies the General number format only (coordinator decision 1
after P12): dates, percentages, thousands separators and custom formats keep
the number as stored, and cells of type `d` keep their ISO 8601 text.

## Transformers

Every splitter, and the score reorder, is a `DocumentTransformer` (threepio's
older rerankers become one through `RerankerTransformer`). The eino-ext splitters
are created by static methods of threepio's older splitter classes, which
return a plain `DocumentTransformer` with Eino's algorithm:

| Transformer | eino-ext | Configuration |
|---|---|---|
| `RecursiveCharacterTextSplitter.fromConfig` | `splitter/recursive` | `RecursiveSplitterConfig`: `chunkSize`, `overlapSize`, `separators` (`['\n', '.', '?', '!']`), `lenFunc`, `keepType` (`SplitterKeepType`), `idGenerator` |
| `MarkdownSplitter.fromHeaderConfig` | `splitter/markdown` | `MarkdownHeaderSplitterConfig`: `headers` (`{'#': 'title'}`), `trimHeaders`, `idGenerator` |
| `HtmlSplitter.fromHeaderConfig` | `splitter/html` | `HtmlHeaderSplitterConfig`: `headers` (`{'h1': 'chapter'}`), `idGenerator` |
| `SemanticSplitter(SemanticSplitterConfig)` | `splitter/semantic` | `embedding`, `bufferSize`, `minChunkSize`, `separators`, `lenFunc`, `percentile` (0.9) |
| `ScoreReorderTransformer({scoreFieldKey})` | `reranker/score` | Best documents at both ends ("lost in the middle"); nothing is dropped |

Things to know:

* **Lengths are UTF-8 bytes** by default, as Go's `len`: `chunkSize: 1000`
  means 1000 bytes, and `'héllo'` has length 6. Pass
  `lenFunc: (text) => text.length` to count UTF-16 code units.
* A chunk keeps its document's id, a copy of its metadata (with the header
  texts for the header splitters) and its `source`, but not `embedding` or
  `score`. Give the chunks ids of their own with a `SplitIdGenerator`
  (`(ctx, originalId, splitIndex) => …`); `originalId` is `null` for a
  document without an id.
* A configuration mistake is an `ArgumentError` with Go's message; the
  semantic splitter throws where Go panics.

```dart
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
```

```dart
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
```

`ScoreReorderTransformer` reads `effectiveScore` (or the metadata entry
`scoreFieldKey`), sorts stably and ranks NaN lowest. threepio's older
`ScoreReranker` is different: it keeps the top documents in score order.

## Retrieval flows

`flow.dart` ports Eino's `flow/retriever` and `flow/indexer`. Each retriever
is built by a static `fromConfig` method of the older class of the same name
and returned as a plain `Retriever` (coordinator decision 1 after P10): it has
none of that class's settings, and works on its own or as a graph or chain
node.

| Dart | Go |
|---|---|
| `MultiQueryRetriever.fromConfig(ctx, MultiQueryRetrieverConfig(…))` | `multiquery.NewRetriever` |
| `ParentRetriever.fromConfig(retriever:, parentIdKey:, origDocGetter:)` | `parent.NewRetriever` |
| `RouterRetriever.fromConfig(retrievers:, router:, fusion:)` | `router.NewRetriever` |
| `ParentIndexer(indexer:, transformer:, parentIdKey:, subIdGenerator:)` | `parent.NewIndexer` |
| `concurrentRetrieve(ctx, tasks)`, `RetrieveTask` | `utils.ConcurrentRetrieveWithCallback`, `utils.RetrieveTask` |

The functions in the configurations take the `RunContext` first and may return
a value or a `Future`.

### Multi-query

A chat model (with Eino's prompt for three rewrites, unless you give a
`rewriteTemplate` and its `queryVar`) or a `rewriteHandler` of yours writes
several queries; at most `maxQueries` (5) of them are retrieved from
`origRetriever` at the same time, and `fusion` joins the results (by default
each document id once, first come first kept). `fromConfig` is asynchronous
because it compiles the rewrite chain.

```dart
import 'package:threepio_core/flow.dart';

final multiQuery = await MultiQueryRetriever.fromConfig(
  ctx,
  MultiQueryRetrieverConfig(
    origRetriever: retriever,
    rewriteModel: chatModel,
    maxQueries: 4,
  ),
);
final docs = await multiQuery.retrieve(
  'how do I build an agent with eino',
  // Passed on to every inner retrieval (Go passes none).
  options: RetrieverOptions(topK: 3, runContext: ctx),
);

final expanded = await MultiQueryRetriever.fromConfig(
  ctx,
  MultiQueryRetrieverConfig(
    origRetriever: retriever,
    rewriteHandler: (ctx, query) => [query, '$query tutorial'],
    fusion: (ctx, results) => results.expand((found) => found).toList(),
  ),
);
```

The multi-query retriever passes the call's options to the inner retriever;
Go drops them, which reads as an oversight, so the difference is deliberate
(coordinator decision 2 after P10).

### Parent documents

`ParentIndexer` cuts documents with a transformer that keeps the parent's id on
every piece (the eino-ext splitters do, unless given an `idGenerator`), writes
that id into each piece's metadata under `parentIdKey`, gives the pieces ids
from `subIdGenerator`, and stores them. `ParentRetriever.fromConfig` finds
pieces, reads their parent ids (in order, each once) and fetches the parents
with `origDocGetter`.

```dart
final originals = {for (final doc in documents) doc.id!: doc};

final parentIndexer = ParentIndexer(
  indexer: VectorStoreIndexer(vectorStore: store, embedder: embedder),
  transformer: RecursiveCharacterTextSplitter.fromConfig(
    const RecursiveSplitterConfig(chunkSize: 300),
  ),
  parentIdKey: 'parent_id',
  subIdGenerator: (ctx, parentId, count) => [
    for (var i = 0; i < count; i++) '${parentId}_chunk_$i',
  ],
);
await parentIndexer.store(ctx, documents);

final parentRetriever = ParentRetriever.fromConfig(
  retriever: VectorRetriever(embedder: embedder, vectorStore: store),
  parentIdKey: 'parent_id',
  origDocGetter: (ctx, ids) => ids.map((id) => originals[id]).nonNulls.toList(),
);
final whole = await parentRetriever.retrieve(
  'refund policy',
  options: RetrieverOptions(runContext: ctx),
);
```

### Router

A router picks the retrievers to ask (every one, in map order, when no router
is given), the query is retrieved from each at the same time, and `fusion`
joins the results by retriever name (reciprocal rank fusion by default). A
router that picks nothing, or a name that is not in `retrievers`, fails the
call with a `ThreepioException`.

```dart
final routed = RouterRetriever.fromConfig(
  retrievers: {'docs': docsRetriever, 'faq': faqRetriever},
  router: (ctx, query) => query.endsWith('?') ? ['faq', 'docs'] : ['docs'],
);
final answers = await routed.retrieve(
  'How do I reset my password?',
  options: RetrieverOptions(runContext: ctx),
);
```

### Concurrent retrieval

```dart
final tasks = [
  RetrieveTask(name: 'docs', retriever: docsRetriever, query: 'pricing'),
  RetrieveTask(
    name: 'faq',
    retriever: faqRetriever,
    query: 'pricing',
    options: const RetrieverOptions(topK: 2),
  ),
];
await concurrentRetrieve(ctx, tasks); // never throws
for (final task in tasks) {
  if (task.failed) {
    print('${task.name} failed: ${task.error}');
  } else {
    print('${task.name}: ${task.result!.length} documents');
  }
}
```

### Callbacks of the flows

The multi-query and router retrievers report their inner steps to the
handlers of `options.runContext`: the multi-query rewrite as the chain
`QueryRewrite`, the router and the fusion as the lambdas `RouterLambda` and
`FusionFuncLambda`, every retrieval as a retriever named after its
implementation (`VectorRetriever`, `KeywordRetriever`). `concurrentRetrieve`
fires the retriever callbacks around every retrieval whether the retriever
reports itself or not, so a callback-aware retriever such as
`VectorRetriever` under the multi-query or router retriever is **reported
twice**, as in Go (coordinator decision 3 after P10). The parent retriever
calls its retriever directly, which reports itself once.

## An end-to-end pipeline

Indexing as a chain: loader → splitter → indexer. The input is the
`DocumentSource`, the output the ids the indexer returns.

```dart
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/io.dart';

Future<List<String>> indexFile(
  RunContext ctx,
  Indexer indexer,
  String path,
) async {
  final indexing = Chain<DocumentSource, List<String>>()
    ..appendLoader(FileLoader())
    ..appendDocumentTransformer(
      RecursiveCharacterTextSplitter.fromConfig(
        const RecursiveSplitterConfig(chunkSize: 800, overlapSize: 80),
      ),
    )
    ..appendIndexer(indexer);
  final runnable = await indexing.compile(ctx);
  return runnable.invoke(ctx, DocumentSource(uri: path));
}
```

Querying as a graph: the question goes to the retriever and, unchanged, to the
template; a lambda turns the documents into the context text. The two lambdas
put their output into a map under their `outputKey`, and the template node
gets the two maps merged. With `NodeTriggerMode.allPredecessor` the template
waits for both.

```dart
Future<Runnable<String, Message>> buildRag(
  RunContext ctx,
  Retriever retriever,
  BaseChatModel model,
) {
  final template = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system(
      'Answer from the context below. Say so when it does not help.\n\n'
      '{context}',
    ),
    Message.user('{question}'),
  ]);

  final graph = Graph<String, Message>()
    ..addRetrieverNode('retrieve', retriever)
    ..addLambdaNode(
      'context',
      Lambda<List<Document>, String>.invokable(
        (ctx, docs) => docs.map((doc) => doc.content).join('\n\n'),
      ),
      options: const NodeOptions(outputKey: 'context'),
    )
    ..addLambdaNode(
      'question',
      Lambda<String, String>.invokable((ctx, question) => question),
      options: const NodeOptions(outputKey: 'question'),
    )
    ..addChatTemplateNode('prompt', template)
    ..addChatModelNode('model', model)
    ..addEdge(Graph.start, 'retrieve')
    ..addEdge('retrieve', 'context')
    ..addEdge(Graph.start, 'question')
    ..addEdge('context', 'prompt')
    ..addEdge('question', 'prompt')
    ..addEdge('prompt', 'model')
    ..addEdge('model', Graph.end);

  return graph.compile(
    ctx,
    options: const GraphCompileOptions(
      graphName: 'rag',
      nodeTriggerMode: NodeTriggerMode.allPredecessor,
    ),
  );
}
```

Running it with callbacks and per-call options. `CallOption.retriever`
reaches every retriever node; `HandlerHelper` builds one handler from typed
hooks per kind of component.

```dart
import 'package:threepio_core/callbacks.dart';

final rag = await buildRag(ctx, retriever, chatModel);

final trace = HandlerHelper()
    .retriever(RetrieverCallbackHandler(
      onEnd: (ctx, info, output) {
        print('retrieved ${output?.docs.length} documents');
        return ctx;
      },
    ))
    .chatModel(ModelCallbackHandler(
      onEnd: (ctx, info, output) {
        print('tokens: ${output?.tokenUsage?.totalTokens}');
        return ctx;
      },
    ))
    .handler();

final answer = await rag.invoke(
  ctx,
  'What is threepio?',
  options: [
    CallOption.callbacks([trace]),
    CallOption.retriever(const RetrieverOptions(topK: 3)),
  ],
);
print(answer.content);

// The same graph streams the answer.
final reader = await rag.stream(ctx, 'And what is Eino?');
await for (final chunk in reader.asStream()) {
  print(chunk.content);
}
```

To trace the pipeline in Langfuse or LangSmith, pass a `LangfuseHandler` or a
`LangSmithHandler` instead of (or next to) the handler above; see
[LANGFUSE_DESIGN.md](LANGFUSE_DESIGN.md) and [CALLBACKS.md](CALLBACKS.md).
[GRAPHS.md](GRAPHS.md) explains graphs, chains, branches and fan-in.

## Differences from Eino

From the CHANGELOG ("Differences from Eino in the flow port", "… ext
providers (wave 1)", "… ext components (wave 2)"), the ones a RAG user can
trip over:

* **Signatures.** `Embedder`, `Retriever` and `DocumentTransformer` carry the
  context in their options (`runContext`), not as a first argument. Options
  are one immutable object per call; implementation-specific options go in
  `extensions`.
* **Ids.** A `Document` id is optional. The default fusions of the flows count
  a document without an id as one with the empty id (Go's zero value), so all
  such documents collapse into one; `ParentIndexer` gives their pieces the
  parent id `''`. Indexers give a document without an id a UUID (Go sends the
  empty id to Qdrant, which refuses it).
* **Flows.** `fromConfig` is a static method returning `Retriever`;
  `MultiQueryRetriever.fromConfig` is asynchronous. Multi-query passes the
  call's options on (Go drops them). A router retriever without a router asks
  every retriever (Go v0.9.22 fails at the first call). `maxQueries` of zero or
  less means 5. Equal reciprocal-rank scores keep first-seen order (Go: map
  order). `ParentIndexer` stores copies with the new ids and leaves your
  documents alone (Go changes them in place). A callback-aware retriever under
  the multi-query or router retriever is reported twice, as in Go.
* **Embedders.** `HashCacheKeyGenerator` hashes the key text (Go's
  `HashGenerator` hashes nothing, so its keys differ); an inner embedder that
  returns too few vectors is a `ThreepioException` (Go panics).
  The Ollama embedder sends the call's model (Go sends the configured one).
* **Qdrant.** REST instead of gRPC (`/points/query`, Qdrant 1.10 or later); the
  per-call score threshold is applied; retrieved metadata is a plain JSON map;
  every request has a 60 s default timeout (`QdrantClient.defaultTimeout`).
* **Loaders and parsers.** The URL loader reads the whole body before parsing,
  creates and closes a client per load when none is given, and has a
  `timeout`. The HTML parser evaluates selectors with `package:html`
  (cascadia's extensions such as `:contains` match nothing). `PdfParser` has
  no text extraction of its own. `DocxParser` returns sections in a fixed
  order (Go walks a map). `XlsxParser` applies the General number format only.
* **Splitters.** Lengths default to UTF-8 bytes; a `SplitIdGenerator` returns
  `null` for Go's `""`; orders Go takes from a map are fixed. The HTML header
  splitter works on `package:html`'s tree, which differs from `x/net/html`'s
  around `<main>`, `<dialog>` or `<search>` inside an open `<p>`, `<isindex>`
  and `<template>`.
* **Not ported.** eino-ext's Redis embedding cache (`FileEmbeddingCache`
  stands in); the Elasticsearch (7, 8, 9), OpenSearch (2, 3), Milvus (v1, v2),
  Redis and VikingDB indexers and retrievers and the Dify and Volcengine
  Knowledge retrievers (Qdrant is the one external store); the S3 loader (a
  pre-signed URL through `UrlLoader.fromConfig` covers it); the Ark, Qianfan
  and Tencent Cloud embedders (Ark's and Qianfan's OpenAI-compatible
  endpoints work with `OpenAIEmbedder` and a `baseUrl`); and Eino's
  `flow/agent` packages (use the ADK, `package:threepio_core/adk.dart`).

## Legacy API (before 0.9)

threepio had its own RAG API before the Eino port. It still exists, is not
deprecated, and is used by two apps. New code should use the components and
flows above.

| Older API | What replaces it |
|---|---|
| `RetrievalQAChain`, `CustomRetrievalQAChain`, `ConversationalRetrievalChain` (`legacy_chains.dart`) | A compose `Graph` or `Chain`: retriever node → template → chat model ([An end-to-end pipeline](#an-end-to-end-pipeline)) |
| `DocumentLoader` (`TextLoader`, `DirectoryLoader`, `UrlLoader(url:)`), bound to one source | `Loader` (`FileLoader`, `UrlLoader.fromConfig`), told the source with every call; `LoaderAdapter` wraps an older loader |
| `DocumentParser` (`HtmlParser()`, `MarkdownParser()`, `PlainTextParser()`, `ParserRegistry`) | `Parser` (`TextParser`, `HtmlParser.fromConfig`, `ExtParser`, …); `asParser()` wraps an older parser |
| `TextSplitter` (`RecursiveCharacterTextSplitter()`, `CharacterTextSplitter`, `MarkdownSplitter`, `HtmlSplitter`) with `splitText`/`splitDocuments` | The same classes' `fromConfig`/`fromHeaderConfig` splitters. Every `TextSplitter` is also a `DocumentTransformer` (`withOptions` fixes its options) |
| Embedding and `VectorStore.addDocuments` by hand | `VectorStoreIndexer` |
| `MultiQueryRetriever(…)`, `ParentRetriever(…)` with a `ParentDocumentStore`, `RouterRetriever(…)` with a `RoutingStrategy` | `MultiQueryRetriever.fromConfig`, `ParentIndexer` + `ParentRetriever.fromConfig`, `RouterRetriever.fromConfig` |
| `HybridRetriever` with `InMemoryBM25Searcher`, the rerankers (`ScoreReranker`, `MMRReranker`, `RerankerTransformer`), `IngestionPipeline`, the fusion and deduplication strategies | No Eino counterpart; they stay as they are. Dense plus keyword search can also be a `RouterRetriever.fromConfig` over two retrievers (one a keyword retriever such as `KeywordRetriever` above), fused by reciprocal rank |

The LangChain-style chains take and return `Map<String, dynamic>`:

```dart
import 'package:threepio_core/legacy_chains.dart';
import 'package:threepio_core/threepio_core.dart';

final qa = RetrievalQAChain(retriever: retriever, chatModel: chatModel);
final result = await qa.invoke({'question': 'What is threepio?'});
print(result['answer']);
final sources = result['source_documents'] as List<Document>;

final cited = CustomRetrievalQAChain(
  retriever: retriever,
  chatModel: chatModel,
  documentFormatter: (doc) => '[${doc.id}] ${doc.content}',
);

final conversation = ConversationalRetrievalChain(
  retriever: retriever,
  chatModel: chatModel,
);
var turn = await conversation.invoke({
  'question': 'What is Eino?',
  'chat_history': <Message>[],
});
turn = await conversation.invoke({
  'question': 'And its Dart port?',
  'chat_history': turn['chat_history'] as List<Message>,
});
```

The older loaders and splitters, and storing by hand:

```dart
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
```

Bridges from the older contracts to the Eino-shaped ones:

```dart
final textFiles = LoaderAdapter((source) => TextLoader(filePath: source.uri));
final legacyParsers = ExtParser(parsers: {
  '.md': MarkdownParser().asParser(),
  '.html': HtmlParser().asParser(),
});
final markdownDocs = await textFiles.load(
  ctx,
  const DocumentSource(uri: 'notes.md'),
);
```

The older retriever classes and threepio's extras:

```dart
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
```

## See also

* [`../example/advanced_rag_example.dart`](../example/advanced_rag_example.dart):
  threepio's older retrieval API: document ingestion (Markdown-aware
  splitting, embedding, storing), hybrid retrieval, MMR reranking, the older
  multi-query retriever, fusion and deduplication.
* [GRAPHS.md](GRAPHS.md): graphs, chains, lambdas, fan-in, call options.
* [CALLBACKS.md](CALLBACKS.md): callback handlers and the typed payloads.
* [LANGFUSE_DESIGN.md](LANGFUSE_DESIGN.md): tracing a pipeline in Langfuse.
