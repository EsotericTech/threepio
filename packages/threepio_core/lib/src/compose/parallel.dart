/// Nodes of a chain that run side by side.
///
/// Port of eino `compose/chain_parallel.go`.
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
import 'graph_node.dart';
import 'graph_options.dart';
import 'lambda.dart';
import 'tools_node.dart';

/// Several nodes that all get the output of the node in front of them and run
/// side by side. Together they give a `Map<String, Object?>` with the output
/// of each node under its output key.
///
/// Port of eino `compose.Parallel`, appended to a chain with
/// `Chain.appendParallel`:
///
/// ```dart
/// final chain = Chain<String, Map<String, Object?>>()
///   ..appendParallel(
///     Parallel()
///       ..addLambda('upper', upper)
///       ..addLambda('length', length),
///   );
/// ```
///
/// Every `add…` method returns this object, so calls can be chained. A
/// mistake (the same output key twice) is reported when the chain is
/// compiled.
final class Parallel {
  /// An empty group of parallel nodes. Port of eino `compose.NewParallel`.
  Parallel();

  final List<GraphNode> _nodes = [];
  final Set<String> _outputKeys = {};
  GraphBuildException? _error;

  /// The nodes, each with its output key.
  @internal
  List<GraphNode> get nodes => List.unmodifiable(_nodes);

  /// The first mistake made in building this group.
  @internal
  GraphBuildException? get error => _error;

  /// Adds a chat model. Port of eino `Parallel.AddChatModel`.
  Parallel addChatModel(
    String outputKey,
    BaseChatModel model, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toChatModelNode(model, _keyed(outputKey, options)));

  /// Adds a chat template. Port of eino `Parallel.AddChatTemplate`.
  Parallel addChatTemplate(
    String outputKey,
    ChatTemplate template, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toChatTemplateNode(template, _keyed(outputKey, options)));

  /// Adds a tools node. Port of eino `Parallel.AddToolsNode`.
  Parallel addToolsNode(
    String outputKey,
    ToolsNode node, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toToolsNode(node, _keyed(outputKey, options)));

  /// Adds an agentic model. Port of eino `Parallel.AddAgenticModel`.
  /// **Beta.**
  Parallel addAgenticModel(
    String outputKey,
    AgenticModel model, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toAgenticModelNode(model, _keyed(outputKey, options)));

  /// Adds an agentic chat template. Port of eino
  /// `Parallel.AddAgenticChatTemplate`. **Beta.**
  Parallel addAgenticChatTemplate(
    String outputKey,
    AgenticChatTemplate template, {
    NodeOptions? options,
  }) =>
      _add(
        outputKey,
        toAgenticChatTemplateNode(template, _keyed(outputKey, options)),
      );

  /// Adds an agentic tools node. Port of eino
  /// `Parallel.AddAgenticToolsNode`. **Beta.**
  Parallel addAgenticToolsNode(
    String outputKey,
    AgenticToolsNode node, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toAgenticToolsNode(node, _keyed(outputKey, options)));

  /// Adds a lambda. Port of eino `Parallel.AddLambda`.
  ///
  /// The type arguments are those of the lambda, so that one written inline
  /// gets its types from its function.
  Parallel addLambda<A, B>(
    String outputKey,
    Lambda<A, B> lambda, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toLambdaNode(lambda, _keyed(outputKey, options)));

  /// Adds an embedder. Port of eino `Parallel.AddEmbedding`.
  Parallel addEmbedding(
    String outputKey,
    Embedder embedder, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toEmbeddingNode(embedder, _keyed(outputKey, options)));

  /// Adds a retriever. Port of eino `Parallel.AddRetriever`.
  Parallel addRetriever(
    String outputKey,
    Retriever retriever, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toRetrieverNode(retriever, _keyed(outputKey, options)));

  /// Adds a loader. Port of eino `Parallel.AddLoader`.
  Parallel addLoader(
    String outputKey,
    Loader loader, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toLoaderNode(loader, _keyed(outputKey, options)));

  /// Adds an indexer. Port of eino `Parallel.AddIndexer`.
  Parallel addIndexer(
    String outputKey,
    Indexer indexer, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toIndexerNode(indexer, _keyed(outputKey, options)));

  /// Adds a document transformer. Port of eino
  /// `Parallel.AddDocumentTransformer`.
  Parallel addDocumentTransformer(
    String outputKey,
    DocumentTransformer transformer, {
    NodeOptions? options,
  }) =>
      _add(
        outputKey,
        toDocumentTransformerNode(transformer, _keyed(outputKey, options)),
      );

  /// Adds a graph, chain or workflow. Port of eino `Parallel.AddGraph`.
  Parallel addGraph(
    String outputKey,
    AnyGraph graph, {
    NodeOptions? options,
  }) =>
      _add(outputKey, toAnyGraphNode(graph, _keyed(outputKey, options)));

  /// Adds a passthrough, which puts the input of the group itself under
  /// [outputKey]. Port of eino `Parallel.AddPassthrough`.
  Parallel addPassthrough(String outputKey, {NodeOptions? options}) =>
      _add(outputKey, toPassthroughNode(_keyed(outputKey, options)));

  static NodeOptions _keyed(String outputKey, NodeOptions? options) =>
      (options ?? const NodeOptions()).copyWith(outputKey: outputKey);

  Parallel _add(String outputKey, GraphNode node) {
    if (_error != null) return this;
    if (!_outputKeys.add(outputKey)) {
      _error = GraphBuildException(
        'parallel add node err, duplicate output key= $outputKey',
      );
      return this;
    }
    _nodes.add(node);
    return this;
  }
}
