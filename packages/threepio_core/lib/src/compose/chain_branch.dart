/// A branch of a chain.
///
/// Port of eino `compose/chain_branch.go`.
library;

import 'package:meta/meta.dart';

import '../components/document/loader.dart';
import '../components/document/transformer.dart';
import '../components/embedding/embedder.dart';
import '../components/indexer/indexer.dart';
import '../components/model/agentic_model.dart';
import '../components/model/base_chat_model.dart';
import '../components/prompt/agentic_chat_template.dart';
import '../components/prompt/chat_template.dart';
import '../components/retriever/retriever.dart';
import 'agentic_tools_node.dart';
import 'errors.dart';
import 'graph.dart';
import 'graph_branch.dart';
import 'graph_node.dart';
import 'graph_options.dart';
import 'lambda.dart';
import 'stream_conversion.dart';
import 'tools_node.dart';

/// A place in a chain where a condition chooses which of several nodes runs
/// next. The nodes are added to the branch under the keys the condition
/// returns.
///
/// Port of eino `compose.ChainBranch`, appended to a chain with
/// `Chain.appendBranch`. The four static methods are the ports of
/// `NewChainBranch`, `NewChainMultiBranch`, `NewStreamChainBranch` and
/// `NewStreamChainMultiBranch`:
///
/// ```dart
/// final chain = Chain<String, String>()
///   ..appendBranch(
///     ChainBranch.single<String>((ctx, input) => input.isEmpty ? 'a' : 'b')
///       ..addLambda('a', whenEmpty)
///       ..addLambda('b', otherwise),
///   );
/// ```
///
/// All nodes of a branch must give the same type, or lead to nodes that
/// accept all of them; what follows the branch in the chain gets the output
/// of the node that ran. Every `add…` method returns this object. A mistake
/// (the same key twice) is reported when the chain is compiled.
final class ChainBranch {
  ChainBranch._(this._branch);

  /// A branch that goes on with the one node whose key [condition] returns.
  /// Port of eino `compose.NewChainBranch`.
  static ChainBranch single<T>(GraphBranchCondition<T> condition) =>
      multi<T>((ctx, input) async => {await condition(ctx, input)});

  /// A branch that goes on with all the nodes whose keys [condition] returns.
  /// Port of eino `compose.NewChainMultiBranch`.
  static ChainBranch multi<T>(GraphMultiBranchCondition<T> condition) =>
      ChainBranch._(
        newGraphBranch<T>(
          RunnablePacker<T, List<String>, Object?>(
            invoke: (ctx, input, _) async =>
                (await condition(ctx, input)).toList(),
          ),
          const {},
        ),
      );

  /// A branch whose [condition] reads the stream. Port of eino
  /// `compose.NewStreamChainBranch`.
  static ChainBranch stream<T>(StreamGraphBranchCondition<T> condition) =>
      streamMulti<T>((ctx, input) async => {await condition(ctx, input)});

  /// A branch whose [condition] reads the stream and may return several
  /// keys. Port of eino `compose.NewStreamChainMultiBranch`.
  static ChainBranch streamMulti<T>(
    StreamGraphMultiBranchCondition<T> condition,
  ) =>
      ChainBranch._(
        newGraphBranch<T>(
          RunnablePacker<T, List<String>, Object?>(
            collect: (ctx, input, _) async =>
                (await condition(ctx, input)).toList(),
          ),
          const {},
        ),
      );

  final GraphBranch _branch;
  final Map<String, GraphNode> _nodes = {};
  GraphBuildException? _error;

  /// The condition, which returns the keys the nodes were added under.
  @internal
  GraphBranch get internalBranch => _branch;

  /// The nodes by the key the condition names them with.
  @internal
  Map<String, GraphNode> get nodes => Map.unmodifiable(_nodes);

  /// The first mistake made in building this branch.
  @internal
  GraphBuildException? get error => _error;

  /// Adds a chat model. Port of eino `ChainBranch.AddChatModel`.
  ChainBranch addChatModel(
    String key,
    BaseChatModel model, {
    NodeOptions? options,
  }) =>
      _add(key, toChatModelNode(model, options));

  /// Adds a chat template. Port of eino `ChainBranch.AddChatTemplate`.
  ChainBranch addChatTemplate(
    String key,
    ChatTemplate template, {
    NodeOptions? options,
  }) =>
      _add(key, toChatTemplateNode(template, options));

  /// Adds a tools node. Port of eino `ChainBranch.AddToolsNode`.
  ChainBranch addToolsNode(
    String key,
    ToolsNode node, {
    NodeOptions? options,
  }) =>
      _add(key, toToolsNode(node, options));

  /// Adds an agentic model. Port of eino `ChainBranch.AddAgenticModel`.
  /// **Beta.**
  ChainBranch addAgenticModel(
    String key,
    AgenticModel model, {
    NodeOptions? options,
  }) =>
      _add(key, toAgenticModelNode(model, options));

  /// Adds an agentic chat template. Port of eino
  /// `ChainBranch.AddAgenticChatTemplate`. **Beta.**
  ChainBranch addAgenticChatTemplate(
    String key,
    AgenticChatTemplate template, {
    NodeOptions? options,
  }) =>
      _add(key, toAgenticChatTemplateNode(template, options));

  /// Adds an agentic tools node. Port of eino
  /// `ChainBranch.AddAgenticToolsNode`. **Beta.**
  ChainBranch addAgenticToolsNode(
    String key,
    AgenticToolsNode node, {
    NodeOptions? options,
  }) =>
      _add(key, toAgenticToolsNode(node, options));

  /// Adds a lambda. Port of eino `ChainBranch.AddLambda`.
  ///
  /// The type arguments are those of the lambda, so that one written inline
  /// gets its types from its function.
  ChainBranch addLambda<A, B>(
    String key,
    Lambda<A, B> lambda, {
    NodeOptions? options,
  }) =>
      _add(key, toLambdaNode(lambda, options));

  /// Adds an embedder. Port of eino `ChainBranch.AddEmbedding`.
  ChainBranch addEmbedding(
    String key,
    Embedder embedder, {
    NodeOptions? options,
  }) =>
      _add(key, toEmbeddingNode(embedder, options));

  /// Adds a retriever. Port of eino `ChainBranch.AddRetriever`.
  ChainBranch addRetriever(
    String key,
    Retriever retriever, {
    NodeOptions? options,
  }) =>
      _add(key, toRetrieverNode(retriever, options));

  /// Adds a loader. Port of eino `ChainBranch.AddLoader`.
  ChainBranch addLoader(
    String key,
    Loader loader, {
    NodeOptions? options,
  }) =>
      _add(key, toLoaderNode(loader, options));

  /// Adds an indexer. Port of eino `ChainBranch.AddIndexer`.
  ChainBranch addIndexer(
    String key,
    Indexer indexer, {
    NodeOptions? options,
  }) =>
      _add(key, toIndexerNode(indexer, options));

  /// Adds a document transformer. Port of eino
  /// `ChainBranch.AddDocumentTransformer`.
  ChainBranch addDocumentTransformer(
    String key,
    DocumentTransformer transformer, {
    NodeOptions? options,
  }) =>
      _add(key, toDocumentTransformerNode(transformer, options));

  /// Adds a graph, chain or workflow. Port of eino `ChainBranch.AddGraph`.
  ChainBranch addGraph(String key, AnyGraph graph, {NodeOptions? options}) =>
      _add(key, toAnyGraphNode(graph, options));

  /// Adds a passthrough. Port of eino `ChainBranch.AddPassthrough`.
  ChainBranch addPassthrough(String key, {NodeOptions? options}) =>
      _add(key, toPassthroughNode(options));

  ChainBranch _add(String key, GraphNode node) {
    if (_error != null) return this;
    if (_nodes.containsKey(key)) {
      _error = GraphBuildException(
        'chain branch add node, duplicate branch node key= $key',
      );
      return this;
    }
    _nodes[key] = node;
    return this;
  }
}
