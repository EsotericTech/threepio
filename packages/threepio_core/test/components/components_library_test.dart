// `package:threepio_core/components.dart` on its own: the contracts, their
// options and callback payloads, the tool utilities and the adapters are all
// reachable without the umbrella library. The file compiles only while every
// name below is exported.
import 'package:test/test.dart';
import 'package:threepio_core/components.dart';

void main() {
  test('the contracts are exported', () {
    expect(
      <Type>[
        BaseChatModel,
        ToolCallingChatModel,
        BaseTool,
        InvokableTool,
        StreamableTool,
        EnhancedInvokableTool,
        EnhancedStreamableTool,
        ChatTemplate,
        Embedder,
        Retriever,
        Indexer,
        Loader,
        Parser,
        DocumentTransformer,
        TypedComponent,
        CallbackAwareComponent,
        InterruptSignal,
      ],
      hasLength(17),
    );
  });

  test('the options are exported', () {
    expect(
      <Object>[
        const ChatModelOptions(),
        const ToolOptions(),
        const ChatTemplateOptions(),
        const EmbedderOptions(),
        const RetrieverOptions(),
        const IndexerOptions(),
        const LoaderOptions(),
        const ParserOptions(),
        const TransformerOptions(),
      ],
      hasLength(9),
    );
  });

  test('the callback payloads are exported', () {
    expect(
      <Type>[
        ModelCallbackConfig,
        ModelCallbackInput,
        ModelCallbackOutput,
        ToolCallbackInput,
        ToolCallbackOutput,
        PromptCallbackInput,
        PromptCallbackOutput,
        EmbeddingCallbackConfig,
        EmbeddingCallbackInput,
        EmbeddingCallbackOutput,
        RetrieverCallbackInput,
        RetrieverCallbackOutput,
        IndexerCallbackInput,
        IndexerCallbackOutput,
        LoaderCallbackInput,
        LoaderCallbackOutput,
        TransformerCallbackInput,
        TransformerCallbackOutput,
      ],
      hasLength(18),
    );
  });

  test('the tool utilities and implementations are exported', () {
    expect(
      <Type>[
        FunctionTool<Object, Object>,
        StreamFunctionTool<Object, Object>,
        EnhancedFunctionTool<Object>,
        EnhancedStreamFunctionTool<Object>,
        DefaultChatTemplate,
        TextParser,
        ExtParser,
        VectorStoreIndexer,
        LoaderAdapter,
        DocumentParserAdapter,
        RerankerTransformer,
        RerankQuery,
        RetryingChatModel,
        FailoverChatModel,
        InMemoryVectorStore,
        VectorRetriever,
        RecursiveCharacterTextSplitter,
        HtmlParser,
        IngestionPipeline,
      ],
      hasLength(19),
    );
    expect(wrapToolWithErrorHandler, isA<Function>());
    expect(wrapInvokableToolWithErrorHandler, isA<Function>());
    expect(wrapStreamableToolWithErrorHandler, isA<Function>());
    expect(componentTypeNameOf, isA<Function>());
    expect(isCallbacksEnabled, isA<Function>());
    expect(metaKeySource, '_source');
  });

  test('what a component call needs from the core is exported', () {
    final ctx = RunContext.background(cancelToken: CancelToken());
    expect(ctx.cancelToken.isCancelled, isFalse);
    expect(ComponentType.indexer.einoName, 'Indexer');
    expect(const ThreepioException('x'), isA<Exception>());
    expect(const ThreepioFormatException('x'), isA<FormatException>());
    expect(const CancelledException(), isA<ThreepioException>());
  });
}
