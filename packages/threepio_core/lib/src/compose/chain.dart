/// Chains: graphs whose nodes follow one another.
///
/// Port of eino `compose/chain.go`.
library;

import 'package:meta/meta.dart';

import '../callbacks/run_info.dart';
import '../components/document/loader.dart';
import '../components/document/transformer.dart';
import '../components/embedding/embedder.dart';
import '../components/indexer/indexer.dart';
import '../components/model/base_chat_model.dart';
import '../components/prompt/chat_template.dart';
import '../components/retriever/retriever.dart';
import '../core/run_context.dart';
import 'chain_branch.dart';
import 'composable_runnable.dart';
import 'errors.dart';
import 'graph.dart';
import 'graph_node.dart';
import 'graph_options.dart';
import 'introspect.dart';
import 'lambda.dart';
import 'local_state.dart';
import 'parallel.dart';
import 'runnable.dart';
import 'tools_node.dart';
import 'type_ref.dart';

/// A sequence of nodes from an [I] to an [O]: each node gets the output of
/// the one before it.
///
/// Port of eino `compose.Chain`. It is a graph with the edges drawn for you;
/// a `Parallel` puts several nodes side by side and a `ChainBranch` lets a
/// condition choose among several.
///
/// ```dart
/// final chain = Chain<Map<String, dynamic>, Message>()
///   ..appendChatTemplate(template)
///   ..appendChatModel(model);
/// final runnable = await chain.compile(ctx);
/// ```
///
/// Every `append…` method returns the chain. A mistake in building it (types
/// that do not fit, a branch with a single node) is remembered and thrown by
/// [compile] as a [GraphBuildException]; the first mistake wins.
///
/// Nodes get the keys `node_0`, `node_1`, … unless [NodeOptions.key] names
/// them; those keys are what `CallOption.designateNode` takes.
final class Chain<I, O> implements AnyGraph {
  /// An empty chain. Port of eino `compose.NewChain`.
  Chain({LocalState? localState})
      : _core = GraphCore(
          helper: GenericHelper.of<I, O>(),
          component: ComponentType.chain,
          localState: localState,
        ) {
    _engine = _ChainEngine(this);
  }

  final GraphCore _core;
  late final _ChainEngine _engine;

  GraphBuildException? _error;
  int _nodeIndex = 0;
  List<String> _preNodeKeys = [];
  bool _hasEnd = false;

  @internal
  @override
  GraphEngine get engine => _engine;

  /// Compiles the chain. Port of eino `Chain.Compile`.
  ///
  /// The chain cannot be changed afterwards. Throws the first
  /// [GraphBuildException] of building it, if there was one.
  Future<Runnable<I, O>> compile(
    RunContext ctx, {
    GraphCompileOptions? options,
  }) =>
      compileAnyGraph<I, O>(ctx, _engine, options);

  /// The structure of the chain as a graph.
  GraphInfo get info => _core.describe();

  /// The chain as a Mermaid flowchart; see [GraphInfo.toMermaid].
  String toMermaid() => info.toMermaid();

  /// Appends a chat model. Port of eino `Chain.AppendChatModel`.
  Chain<I, O> appendChatModel(BaseChatModel model, {NodeOptions? options}) =>
      _append(toChatModelNode(model, options));

  /// Appends a chat template. Port of eino `Chain.AppendChatTemplate`.
  Chain<I, O> appendChatTemplate(
    ChatTemplate template, {
    NodeOptions? options,
  }) =>
      _append(toChatTemplateNode(template, options));

  /// Appends a tools node. Port of eino `Chain.AppendToolsNode`.
  Chain<I, O> appendToolsNode(ToolsNode node, {NodeOptions? options}) =>
      _append(toToolsNode(node, options));

  /// Appends a document transformer. Port of eino
  /// `Chain.AppendDocumentTransformer`.
  Chain<I, O> appendDocumentTransformer(
    DocumentTransformer transformer, {
    NodeOptions? options,
  }) =>
      _append(toDocumentTransformerNode(transformer, options));

  /// Appends a lambda. Port of eino `Chain.AppendLambda`.
  ///
  /// The type arguments are those of the lambda, so that one written inline
  /// gets its types from its function.
  Chain<I, O> appendLambda<A, B>(
    Lambda<A, B> lambda, {
    NodeOptions? options,
  }) =>
      _append(toLambdaNode(lambda, options));

  /// Appends an embedder. Port of eino `Chain.AppendEmbedding`.
  Chain<I, O> appendEmbedding(Embedder embedder, {NodeOptions? options}) =>
      _append(toEmbeddingNode(embedder, options));

  /// Appends a retriever. Port of eino `Chain.AppendRetriever`.
  Chain<I, O> appendRetriever(Retriever retriever, {NodeOptions? options}) =>
      _append(toRetrieverNode(retriever, options));

  /// Appends a loader. Port of eino `Chain.AppendLoader`.
  Chain<I, O> appendLoader(Loader loader, {NodeOptions? options}) =>
      _append(toLoaderNode(loader, options));

  /// Appends an indexer. Port of eino `Chain.AppendIndexer`.
  Chain<I, O> appendIndexer(Indexer indexer, {NodeOptions? options}) =>
      _append(toIndexerNode(indexer, options));

  /// Appends a graph, chain or workflow as one node. Port of eino
  /// `Chain.AppendGraph`.
  Chain<I, O> appendGraph(AnyGraph graph, {NodeOptions? options}) =>
      _append(toAnyGraphNode(graph, options));

  /// Appends a node that hands its input on unchanged. Port of eino
  /// `Chain.AppendPassthrough`.
  Chain<I, O> appendPassthrough({NodeOptions? options}) =>
      _append(toPassthroughNode(options));

  /// Appends a branch: its condition chooses which of its nodes runs. What is
  /// appended next follows every node of the branch. Port of eino
  /// `Chain.AppendBranch`.
  Chain<I, O> appendBranch(ChainBranch branch) {
    final branchError = branch.error;
    if (branchError != null) {
      return _report('append branch error: ${branchError.message}');
    }
    final branchNodes = branch.nodes;
    if (branchNodes.isEmpty) {
      return _report('append branch invalid, nodeList is empty');
    }
    if (branchNodes.length == 1) {
      return _report('append branch invalid, nodeList length = 1');
    }
    if (_preNodeKeys.length > 1) {
      return _report(
        'append branch invalid, multiple previous nodes: $_preNodeKeys ',
      );
    }
    final startNode = _preNodeKeys.isEmpty ? Graph.start : _preNodeKeys.single;

    final prefix = _nextNodeKey();
    final keyToNodeKey = <String, String>{};
    for (final MapEntry(:key, value: node) in branchNodes.entries) {
      final own = node.options.key ?? '';
      final nodeKey = own.isNotEmpty ? own : '${prefix}_branch_$key';
      try {
        _core.addNode(nodeKey, node);
      } on GraphBuildException catch (error) {
        return _report(
          'add branch node[$nodeKey] to chain failed: ${error.message}',
        );
      }
      keyToNodeKey[key] = nodeKey;
    }

    // The condition names nodes by the keys of the branch; the graph knows
    // them by their node keys.
    List<String> translate(List<String> ends) => [
          for (final end in ends)
            keyToNodeKey[end] ??
                (throw GraphRunException(
                  'branch invocation returns unintended end node: $end',
                )),
        ];
    final internal = branch.internalBranch;
    final graphBranch = internal.copyWith(
      endNodes: keyToNodeKey.values.toSet(),
      invoke: (ctx, input) async => translate(await internal.invoke(ctx, input)),
      collect: (ctx, input) async =>
          translate(await internal.collect(ctx, input)),
    );

    try {
      _core.addBranch(startNode, graphBranch);
    } on GraphBuildException catch (error) {
      return _report('chain append branch failed: ${error.message}');
    }

    _preNodeKeys = keyToNodeKey.values.toList();
    return this;
  }

  /// Appends nodes that run side by side. What is appended next gets a map
  /// with the output of each. Port of eino `Chain.AppendParallel`.
  Chain<I, O> appendParallel(Parallel parallel) {
    final parallelError = parallel.error;
    if (parallelError != null) {
      return _report(
        'append parallel invalid, parallel error: ${parallelError.message}',
      );
    }
    final parallelNodes = parallel.nodes;
    if (parallelNodes.length <= 1) {
      return _report(
        'append parallel invalid, not enough nodes, '
        'count = ${parallelNodes.length}',
      );
    }
    if (_preNodeKeys.length > 1) {
      return _report(
        'append parallel invalid, multiple previous nodes: $_preNodeKeys ',
      );
    }
    final startNode = _preNodeKeys.isEmpty ? Graph.start : _preNodeKeys.single;

    final prefix = _nextNodeKey();
    final nodeKeys = <String>[];
    for (final (index, node) in parallelNodes.indexed) {
      final own = node.options.key ?? '';
      final nodeKey = own.isNotEmpty ? own : '${prefix}_parallel_$index';
      try {
        _core.addNode(nodeKey, node);
      } on GraphBuildException catch (error) {
        return _report(
          'add parallel node to chain failed, key=$nodeKey, '
          'err: ${error.message}',
        );
      }
      try {
        _core.addEdge(startNode, nodeKey);
      } on GraphBuildException catch (error) {
        return _report(
          'add parallel edge failed, from=$startNode, to=$nodeKey, '
          'err: ${error.message}',
        );
      }
      nodeKeys.add(nodeKey);
    }

    _preNodeKeys = nodeKeys;
    return this;
  }

  String _nextNodeKey() => 'node_${_nodeIndex++}';

  Chain<I, O> _report(String message) {
    _error ??= GraphBuildException(message);
    return this;
  }

  /// Port of eino `Chain.addNode`.
  Chain<I, O> _append(GraphNode node) {
    if (_error != null) return this;
    if (_core.compiled) {
      _error = const ChainCompiledException();
      return this;
    }

    final defaultKey = _nextNodeKey();
    final own = node.options.key ?? '';
    final nodeKey = own.isNotEmpty ? own : defaultKey;

    try {
      _core.addNode(nodeKey, node);
      if (_preNodeKeys.isEmpty) _preNodeKeys = [Graph.start];
      for (final preNodeKey in _preNodeKeys) {
        _core.addEdge(preNodeKey, nodeKey);
      }
    } on GraphBuildException catch (error) {
      _error ??= error;
      return this;
    }

    _preNodeKeys = [nodeKey];
    return this;
  }

  /// Port of eino `Chain.addEndIfNeeded`.
  void _addEndIfNeeded() {
    if (_hasEnd) return;
    final failed = _error;
    if (failed != null) throw failed;
    if (_preNodeKeys.isEmpty) {
      throw GraphBuildException(
        'pre node keys not set, number of nodes in chain= '
        '${_core.nodes.length}',
      );
    }
    for (final nodeKey in _preNodeKeys) {
      _core.addEdge(nodeKey, Graph.end);
    }
    _hasEnd = true;
  }
}

final class _ChainEngine implements GraphEngine {
  const _ChainEngine(this._chain);

  final Chain<Object?, Object?> _chain;

  @override
  GenericHelper get helper => _chain._core.helper;

  @override
  TypeRef<Object?> get inputType => _chain._core.inputType;

  @override
  TypeRef<Object?> get outputType => _chain._core.outputType;

  @override
  ComponentType get component => ComponentType.chain;

  @override
  Future<ComposableRunnable> compile(
    RunContext ctx,
    GraphCompileOptions? options,
  ) async {
    _chain._addEndIfNeeded();
    return _chain._core.compile(ctx, options);
  }

  @override
  GraphInfo describe() => _chain._core.describe();
}
