// What the P12 port (eino-ext wave 2) exports, and from which library. The
// file compiles only while every name used below is exported where it says;
// the unprefixed imports at the end prove that the umbrella, `io.dart` and
// `callbacks.dart` can be imported together without a name clash.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/components.dart' as components;
import 'package:threepio_core/io.dart' as io;
import 'package:threepio_core/threepio_core.dart' as umbrella;

import 'p12_exports_unprefixed.dart' as unprefixed;

void main() {
  test('components.dart exports the platform-neutral wave 2 components', () {
    final types = <Type>[
      // Documents.
      components.UrlContentLoader,
      components.UrlLoaderConfig,
      components.HtmlContentParser,
      components.HtmlParserConfig,
      components.PdfParser,
      components.PdfParserConfig,
      components.PdfParserOptions,
      components.PdfTextExtractor,
      components.DocxParser,
      components.DocxParserConfig,
      components.XlsxParser,
      components.XlsxParserConfig,
      // Transformers.
      components.RecursiveSplitterConfig,
      components.SplitterKeepType,
      components.MarkdownHeaderSplitterConfig,
      components.HtmlHeaderSplitterConfig,
      components.SemanticSplitter,
      components.SemanticSplitterConfig,
      components.ScoreReorderTransformer,
      // Qdrant.
      components.QdrantClient,
      components.QdrantDistance,
      components.QdrantPoint,
      components.QdrantScoredPoint,
      components.QdrantUpdateResult,
      components.QdrantUpdateStatus,
      components.QdrantException,
      components.QdrantIndexer,
      components.QdrantIndexerConfig,
      components.QdrantRetriever,
      components.QdrantRetrieverConfig,
      components.QdrantRetrieverOptions,
      // Tools.
      components.SearchResult,
      components.HttpRequestToolkit,
      components.HttpRequestToolkitConfig,
      components.HttpRequestToolConfig,
      components.HttpGetRequestTool,
      components.HttpPostRequestTool,
      components.HttpPutRequestTool,
      components.HttpDeleteRequestTool,
      components.GoogleSearchTool,
      components.GoogleSearchConfig,
      components.GoogleApiException,
      components.WikipediaTool,
      components.WikipediaConfig,
      components.WikipediaException,
      components.DuckDuckGoSearchTool,
      components.DuckDuckGoSearchClient,
      components.DuckDuckGoConfig,
      components.DuckDuckGoRegion,
      components.DuckDuckGoTimeRange,
      components.SearxngSearchTool,
      components.SearxngClient,
      components.SearxngClientConfig,
      components.SearxngSearchRequestConfig,
      components.SearxngTimeRange,
      components.SearxngLanguage,
      components.SearxngSafeSearch,
      components.SearxngEngine,
      components.SequentialThinkingTool,
      components.CommandLineOperator,
      components.CommandLineOutput,
      components.PyExecutorTool,
      components.StrReplaceEditorTool,
      components.StrReplaceEditorCommand,
    ];
    expect(types.toSet(), hasLength(types.length));
    expect(components.htmlBodySelector, 'body');
    expect(io.fileLoaderMetaKeyFileName, '_file_name');
  });

  test('the legacy classes have the Eino-shaped entry points', () {
    expect(components.UrlLoader.fromConfig(), isA<components.Loader>());
    expect(components.HtmlParser.fromConfig(), isA<components.Parser>());
    expect(
      components.RecursiveCharacterTextSplitter.fromConfig(
        const components.RecursiveSplitterConfig(chunkSize: 10),
      ),
      isA<components.DocumentTransformer>(),
    );
  });

  test('io.dart exports the parts that need dart:io', () {
    expect(<Type>[io.FileLoader, io.FileLoaderConfig, io.LocalOperator],
        hasLength(3));
  });

  test('callbacks.dart and the umbrella export the LangSmith handler', () {
    expect(
      <Type>[
        callbacks.LangSmithHandler,
        callbacks.LangSmithConfig,
        callbacks.LangSmithTrace,
        callbacks.LangSmithTraceOptions,
        callbacks.LangSmithFlowTrace,
        callbacks.LangSmithClient,
        callbacks.LangSmithRunType,
        umbrella.LangSmithHandler,
      ],
      hasLength(8),
    );
  });

  test('the umbrella exports the wave 2 components with components.dart', () {
    expect(umbrella.QdrantRetriever, components.QdrantRetriever);
    expect(umbrella.SearchResult, components.SearchResult);
    expect(umbrella.ToolInfo.fromParamsOneOf, isA<Function>());
  });

  test('everything imports together without a clash', () {
    expect(unprefixed.namesResolve(), isTrue);
  });
}
