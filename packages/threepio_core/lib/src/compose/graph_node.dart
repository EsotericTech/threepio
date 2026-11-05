/// The nodes of a graph and how components become nodes.
///
/// Port of eino `compose/graph_node.go` and
/// `compose/component_to_graph_node.go`.
@internal
library;

import 'package:meta/meta.dart';

import '../callbacks/run_info.dart';
import '../components/component_type.dart';
import '../components/document/loader.dart';
import '../components/document/transformer.dart';
import '../components/embedding/embedder.dart';
import '../components/indexer/indexer.dart';
import '../components/model/base_chat_model.dart';
import '../components/model/chat_model_options.dart';
import '../components/prompt/chat_template.dart';
import '../components/retriever/retriever.dart';
import '../core/run_context.dart';
import '../schema/document.dart';
import '../schema/message.dart';
import 'composable_runnable.dart';
import 'errors.dart';
import 'field_mapping.dart';
import 'graph.dart';
import 'graph_options.dart';
import 'introspect.dart';
import 'lambda.dart';
import 'local_state.dart';
import 'stream_conversion.dart';
import 'tools_node.dart';
import 'tools_node_options.dart';
import 'type_ref.dart';

/// A node of a graph before the graph is compiled.
///
/// Port of eino `graphNode`.
final class GraphNode {
  /// A node that runs [cr] or the nested [graph].
  GraphNode({
    required this.nodeInfo,
    required this.executorMeta,
    required this.options,
    this.cr,
    this.graph,
    this.instance,
    this.preHandler,
    this.postHandler,
  });

  /// What the node runs, unless it is a nested graph that is not compiled
  /// yet.
  ComposableRunnable? cr;

  /// The nested graph the node runs.
  final AnyGraph? graph;

  /// Name, keys and state handlers of the node.
  final NodeInfo nodeInfo;

  /// The kind of component.
  final ExecutorMeta executorMeta;

  /// The component the node was made from.
  final Object? instance;

  /// The options the node was added with.
  final NodeOptions options;

  /// The state handler in front of the node.
  final StateHandler? preHandler;

  /// The state handler behind the node.
  final StateHandler? postHandler;

  /// Whether the node needs the graph to have a state.
  bool get needState => preHandler != null || postHandler != null;

  /// The type-dependent operations of the node as its neighbours see it.
  ///
  /// Port of eino `graphNode.getGenericHelper`.
  GenericHelper? get helper {
    var helper = graph?.engine.helper ?? cr?.helper;
    if (helper == null) return null;
    if (nodeInfo.inputKey.isNotEmpty) helper = helper.forMapInput();
    if (nodeInfo.outputKey.isNotEmpty) helper = helper.forMapOutput();
    return helper;
  }

  /// The input type of the node as its predecessors see it. `null` for a
  /// passthrough node whose type is not known yet.
  TypeRef<Object?>? get inputType {
    if (nodeInfo.inputKey.isNotEmpty) return mapType;
    return graph?.engine.inputType ?? cr?.inputType;
  }

  /// The output type of the node as its successors see it.
  TypeRef<Object?>? get outputType {
    if (nodeInfo.outputKey.isNotEmpty) return mapType;
    return graph?.engine.outputType ?? cr?.outputType;
  }

  /// What the graph runs for this node; a nested graph is compiled here.
  ///
  /// Port of eino `graphNode.compileIfNeeded`.
  Future<ComposableRunnable> compileIfNeeded(
    RunContext ctx,
    GraphCompileOptions compileOptions,
  ) async {
    ComposableRunnable runnable;
    final nested = graph;
    if (nested != null) {
      runnable = await nested.engine.compile(ctx, compileOptions);
      cr = runnable;
    } else if (cr != null) {
      runnable = cr!;
    } else {
      throw const GraphBuildException('no graph or component provided');
    }

    runnable
      ..meta = executorMeta
      ..nodeInfo = nodeInfo;

    if (nodeInfo.outputKey.isNotEmpty) {
      runnable = outputKeyedComposableRunnable(nodeInfo.outputKey, runnable);
    }
    if (nodeInfo.inputKey.isNotEmpty) {
      runnable = inputKeyedComposableRunnable(nodeInfo.inputKey, runnable);
    }
    return runnable;
  }

  /// The description of this node for [GraphInfo].
  GraphNodeInfo describe({
    GraphInfo? graphInfo,
    List<FieldMapping> mappings = const [],
  }) =>
      GraphNodeInfo(
        component: executorMeta.component,
        instance: executorMeta.isPassthrough ? null : instance,
        options: options,
        inputType: cr?.inputType?.type ?? graph?.engine.inputType.type,
        outputType: cr?.outputType?.type ?? graph?.engine.outputType.type,
        name: nodeInfo.name,
        inputKey: nodeInfo.inputKey,
        outputKey: nodeInfo.outputKey,
        graphInfo: graphInfo,
        isPassthrough: executorMeta.isPassthrough,
        mappings: List.unmodifiable(mappings),
      );
}

/// What kind of executor [executor] is.
///
/// Port of eino `parseExecutorInfoFromComponent`. A component that does not
/// name its implementation is reported under its class name without type
/// arguments.
ExecutorMeta parseExecutorInfo(ComponentType component, Object executor) =>
    ExecutorMeta(
      component: component,
      isComponentCallbackEnabled: isCallbacksEnabled(executor),
      componentImplType: componentTypeNameOf(executor) ?? _className(executor),
    );

String _className(Object value) {
  final name = value.runtimeType.toString();
  final generic = name.indexOf('<');
  final plain = generic < 0 ? name : name.substring(0, generic);
  return plain.startsWith('_') ? plain.substring(1) : plain;
}

/// The node made of [runnable] and what [options] say about it.
GraphNode toNode({
  required NodeOptions? options,
  required ExecutorMeta meta,
  ComposableRunnable? runnable,
  AnyGraph? graph,
  Object? instance,
}) {
  final nodeOptions = options ?? const NodeOptions();
  final pre = _handler(
    nodeOptions.statePreHandler,
    nodeOptions.streamStatePreHandler,
    isPre: true,
  );
  final post = _handler(
    nodeOptions.statePostHandler,
    nodeOptions.streamStatePostHandler,
    isPre: false,
  );
  return GraphNode(
    nodeInfo: NodeInfo(
      name: nodeOptions.name ?? '',
      inputKey: nodeOptions.inputKey ?? '',
      outputKey: nodeOptions.outputKey ?? '',
      preProcessor: pre?.runnable,
      postProcessor: post?.runnable,
      compileOptions: nodeOptions.compileOptions,
    ),
    executorMeta: meta,
    options: nodeOptions,
    cr: runnable,
    graph: graph,
    instance: instance,
    preHandler: pre,
    postHandler: post,
  );
}

StateHandler? _handler(
  StateHandler? value,
  StateHandler? stream, {
  required bool isPre,
}) {
  final side = isPre ? 'pre' : 'post';
  if (value != null && stream != null) {
    throw ArgumentError(
      'a node has one state $side handler: give the value form or the stream '
      'form, not both',
    );
  }
  final handler = value ?? stream;
  if (handler == null) return null;
  if (handler.isPre != isPre) {
    throw ArgumentError(
      '$handler was given as a state $side handler',
    );
  }
  if (handler.isStream != (stream != null)) {
    throw ArgumentError(
      '$handler was given as a ${stream != null ? 'stream' : 'value'} state '
      '$side handler',
    );
  }
  return handler;
}

/// The node of a component with the four ways to run it that it implements.
///
/// Port of eino `toComponentNode`.
GraphNode toComponentNode<I, O, TOption>(
  Object component,
  ComponentType type,
  NodeOptions? options, {
  InvokeFn<I, O, TOption>? invoke,
  StreamFn<I, O, TOption>? stream,
  CollectFn<I, O, TOption>? collect,
  TransformFn<I, O, TOption>? transform,
}) {
  final meta = parseExecutorInfo(type, component);
  return toNode(
    options: options,
    meta: meta,
    instance: component,
    runnable: RunnablePacker<I, O, TOption>(
      invoke: invoke,
      stream: stream,
      collect: collect,
      transform: transform,
      enableCallbacks: !meta.isComponentCallbackEnabled,
    ).toComposableRunnable(),
  );
}

/// Port of eino `toChatModelNode`.
GraphNode toChatModelNode(BaseChatModel model, NodeOptions? options) =>
    toComponentNode<List<Message>, Message, ChatModelOptions>(
      model,
      ComponentType.chatModel,
      options,
      invoke: (ctx, input, callOptions) =>
          model.generate(input, options: _chatModelOptions(ctx, callOptions)),
      stream: (ctx, input, callOptions) =>
          model.stream(input, options: _chatModelOptions(ctx, callOptions)),
    );

ChatModelOptions _chatModelOptions(
  RunContext ctx,
  List<ChatModelOptions> options,
) =>
    options
        .fold(const ChatModelOptions(), (merged, next) => merged.merge(next))
        .copyWith(runContext: ctx);

/// Port of eino `toChatTemplateNode`.
GraphNode toChatTemplateNode(ChatTemplate template, NodeOptions? options) =>
    toComponentNode<Map<String, dynamic>, List<Message>, ChatTemplateOptions>(
      template,
      ComponentType.promptTemplate,
      options,
      invoke: (ctx, input, callOptions) => template.format(
        input,
        options: callOptions
            .fold(
              const ChatTemplateOptions(),
              (merged, next) => merged.merge(next),
            )
            .copyWith(runContext: ctx),
      ),
    );

/// Port of eino `toRetrieverNode`.
GraphNode toRetrieverNode(Retriever retriever, NodeOptions? options) =>
    toComponentNode<String, List<Document>, RetrieverOptions>(
      retriever,
      ComponentType.retriever,
      options,
      invoke: (ctx, input, callOptions) => retriever.retrieve(
        input,
        // Reduced, not folded onto a plain RetrieverOptions: the options of a
        // retriever may be a subclass with fields of its own.
        options: (callOptions.isEmpty
                ? const RetrieverOptions()
                : callOptions.reduce((merged, next) => merged.merge(next)))
            .copyWith(runContext: ctx),
      ),
    );

/// Port of eino `toEmbeddingNode`.
GraphNode toEmbeddingNode(Embedder embedder, NodeOptions? options) =>
    toComponentNode<List<String>, List<List<double>>, EmbedderOptions>(
      embedder,
      ComponentType.embedder,
      options,
      invoke: (ctx, input, callOptions) => embedder.embedStrings(
        input,
        options: callOptions
            .fold(const EmbedderOptions(), (merged, next) => merged.merge(next))
            .copyWith(runContext: ctx),
      ),
    );

/// Port of eino `toIndexerNode`.
GraphNode toIndexerNode(Indexer indexer, NodeOptions? options) =>
    toComponentNode<List<Document>, List<String>, IndexerOptions>(
      indexer,
      ComponentType.indexer,
      options,
      invoke: (ctx, input, callOptions) => indexer.store(
        ctx,
        input,
        options: callOptions.fold<IndexerOptions>(
          const IndexerOptions(),
          (merged, next) => merged.merge(next),
        ),
      ),
    );

/// Port of eino `toLoaderNode`.
GraphNode toLoaderNode(Loader loader, NodeOptions? options) =>
    toComponentNode<DocumentSource, List<Document>, LoaderOptions>(
      loader,
      ComponentType.loader,
      options,
      invoke: (ctx, input, callOptions) => loader.load(
        ctx,
        input,
        options: callOptions.fold<LoaderOptions>(
          const LoaderOptions(),
          (merged, next) => merged.merge(next),
        ),
      ),
    );

/// Port of eino `toDocumentTransformerNode`.
GraphNode toDocumentTransformerNode(
  DocumentTransformer transformer,
  NodeOptions? options,
) =>
    toComponentNode<List<Document>, List<Document>, TransformerOptions>(
      transformer,
      ComponentType.documentTransformer,
      options,
      invoke: (ctx, input, callOptions) => transformer.transform(
        input,
        options: callOptions
            .fold(
              const TransformerOptions(),
              (merged, next) => merged.merge(next),
            )
            .copyWith(runContext: ctx),
      ),
    );

/// Port of eino `toToolsNode`.
GraphNode toToolsNode(ToolsNode node, NodeOptions? options) =>
    toComponentNode<Message, List<Message>, ToolsNodeOptions>(
      node,
      ComponentType.toolsNode,
      options,
      invoke: (ctx, input, callOptions) =>
          node.invokeTools(ctx, input, options: _toolsNodeOptions(callOptions)),
      stream: (ctx, input, callOptions) =>
          node.streamTools(ctx, input, options: _toolsNodeOptions(callOptions)),
    );

ToolsNodeOptions _toolsNodeOptions(List<ToolsNodeOptions> options) =>
    options.fold(const ToolsNodeOptions(), (merged, next) => merged.merge(next));

/// Port of eino `toLambdaNode`.
GraphNode toLambdaNode(Lambda<Object?, Object?> lambda, NodeOptions? options) {
  // A copy: the graph gives the runnable a node of its own, and the same
  // lambda may be a node of several graphs.
  final executor = lambda.executor.copy();
  return toNode(
    options: options,
    meta: executor.meta!,
    runnable: executor,
    instance: lambda,
  );
}

/// Port of eino `toAnyGraphNode`.
GraphNode toAnyGraphNode(AnyGraph graph, NodeOptions? options) => toNode(
      options: options,
      meta: ExecutorMeta(
        component: graph.engine.component,
        isComponentCallbackEnabled: true,
      ),
      graph: graph,
      instance: graph,
    );

/// Port of eino `toPassthroughNode`.
GraphNode toPassthroughNode(NodeOptions? options) {
  final passthrough = composablePassthrough();
  return toNode(
    options: options,
    meta: passthrough.meta!,
    runnable: passthrough,
    instance: passthrough,
  );
}
