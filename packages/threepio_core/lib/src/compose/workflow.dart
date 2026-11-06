/// Workflows: graphs whose nodes declare what they take from which node.
///
/// Port of eino `compose/workflow.go`.
library;

import 'package:meta/meta.dart';

import '../callbacks/run_info.dart';
import '../components/document/loader.dart';
import '../components/document/transformer.dart';
import '../components/embedding/embedder.dart';
import '../components/indexer/indexer.dart';
import '../components/model/agentic_model.dart';
import '../components/model/base_chat_model.dart';
import '../components/prompt/agentic_chat_template.dart';
import '../components/prompt/chat_template.dart';
import '../components/retriever/retriever.dart';
import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'agentic_tools_node.dart';
import 'composable_runnable.dart';
import 'errors.dart';
import 'graph.dart';
import 'graph_branch.dart';
import 'graph_node.dart';
import 'graph_options.dart';
import 'introspect.dart';
import 'lambda.dart';
import 'local_state.dart';
import 'runnable.dart';
import 'tools_node.dart';
import 'type_ref.dart';
import 'values_merge.dart';
import 'workflow_node.dart';

export 'workflow_node.dart';

/// A graph in which every node says which nodes it waits for and which parts
/// of their outputs make up its input.
///
/// Port of eino `compose.Workflow`. Where a `Graph` has edges that carry the
/// whole output of one node to the next, a workflow has dependencies with
/// field mappings: a node can take one field from the input of the workflow,
/// another from a node that ran long before it, and a constant for a third.
///
/// ```dart
/// final workflow = Workflow<Map<String, Object?>, String>();
/// workflow.addLambdaNode('search', search)
///   ..addInput(Graph.start, [FieldMapping.mapFields('question', 'query')]);
/// workflow.addLambdaNode('answer', answer)
///   ..addInput('search', [FieldMapping.toField('documents')])
///   ..addInput(Graph.start, [FieldMapping.mapFields('question', 'question')]);
/// workflow.end().addInput('answer');
/// final runnable = await workflow.compile(ctx);
/// ```
///
/// Fields are keys of a `Map<String, Object?>` or fields of a
/// `FieldAddressable`. A node whose input is assembled from fields takes a
/// map, or a `FieldAddressable` class that has registered its empty value.
///
/// A workflow always runs as a directed acyclic graph: a node runs when all
/// the nodes it depends on have finished, and cycles are an error. Every
/// `add…Node` method returns the [WorkflowNode] to declare the inputs on;
/// [end] is the node that stands for the output. Mistakes are reported by
/// [compile].
final class Workflow<I, O> implements AnyGraph {
  /// An empty workflow. With [localState] it keeps a state object per run,
  /// like a graph. Port of eino `compose.NewWorkflow`.
  Workflow({LocalState? localState})
      : _core = GraphCore(
          helper: GenericHelper.of<I, O>(),
          component: ComponentType.workflow,
          localState: localState,
        ) {
    _engine = _WorkflowEngine(this);
  }

  final GraphCore _core;
  late final _WorkflowEngine _engine;
  final Map<String, WorkflowNode> _nodes = {};
  final List<WorkflowBranch> _branches = [];
  bool _prepared = false;

  @internal
  @override
  GraphEngine get engine => _engine;

  /// Compiles the workflow. Port of eino `Workflow.Compile`.
  ///
  /// The workflow cannot be changed afterwards. Throws [GraphBuildException]
  /// for the first mistake of building it.
  Future<Runnable<I, O>> compile(
    RunContext ctx, {
    GraphCompileOptions? options,
  }) =>
      compileAnyGraph<I, O>(ctx, _engine, options);

  /// The structure of the workflow as a graph. Dependencies and mappings
  /// become edges when the workflow is compiled.
  GraphInfo get info => _core.describe();

  /// The workflow as a Mermaid flowchart; see [GraphInfo.toMermaid].
  String toMermaid() => info.toMermaid();

  /// Adds a chat model as the node [key]. Port of eino
  /// `Workflow.AddChatModelNode`.
  WorkflowNode addChatModelNode(
    String key,
    BaseChatModel model, {
    NodeOptions? options,
  }) =>
      _add(key, () => toChatModelNode(model, options));

  /// Adds a chat template as the node [key]. Port of eino
  /// `Workflow.AddChatTemplateNode`.
  WorkflowNode addChatTemplateNode(
    String key,
    ChatTemplate template, {
    NodeOptions? options,
  }) =>
      _add(key, () => toChatTemplateNode(template, options));

  /// Adds a tools node as the node [key]. Port of eino
  /// `Workflow.AddToolsNode`.
  WorkflowNode addToolsNode(
    String key,
    ToolsNode node, {
    NodeOptions? options,
  }) =>
      _add(key, () => toToolsNode(node, options));

  /// Adds an agentic model as the node [key]. Port of eino
  /// `Workflow.AddAgenticModelNode`. **Beta.**
  WorkflowNode addAgenticModelNode(
    String key,
    AgenticModel model, {
    NodeOptions? options,
  }) =>
      _add(key, () => toAgenticModelNode(model, options));

  /// Adds an agentic chat template as the node [key]. Port of eino
  /// `Workflow.AddAgenticChatTemplateNode`. **Beta.**
  WorkflowNode addAgenticChatTemplateNode(
    String key,
    AgenticChatTemplate template, {
    NodeOptions? options,
  }) =>
      _add(key, () => toAgenticChatTemplateNode(template, options));

  /// Adds an agentic tools node as the node [key]. Port of eino
  /// `Workflow.AddAgenticToolsNode`. **Beta.**
  WorkflowNode addAgenticToolsNode(
    String key,
    AgenticToolsNode node, {
    NodeOptions? options,
  }) =>
      _add(key, () => toAgenticToolsNode(node, options));

  /// Adds a retriever as the node [key]. Port of eino
  /// `Workflow.AddRetrieverNode`.
  WorkflowNode addRetrieverNode(
    String key,
    Retriever retriever, {
    NodeOptions? options,
  }) =>
      _add(key, () => toRetrieverNode(retriever, options));

  /// Adds an embedder as the node [key]. Port of eino
  /// `Workflow.AddEmbeddingNode`.
  WorkflowNode addEmbeddingNode(
    String key,
    Embedder embedder, {
    NodeOptions? options,
  }) =>
      _add(key, () => toEmbeddingNode(embedder, options));

  /// Adds an indexer as the node [key]. Port of eino
  /// `Workflow.AddIndexerNode`.
  WorkflowNode addIndexerNode(
    String key,
    Indexer indexer, {
    NodeOptions? options,
  }) =>
      _add(key, () => toIndexerNode(indexer, options));

  /// Adds a loader as the node [key]. Port of eino `Workflow.AddLoaderNode`.
  WorkflowNode addLoaderNode(
    String key,
    Loader loader, {
    NodeOptions? options,
  }) =>
      _add(key, () => toLoaderNode(loader, options));

  /// Adds a document transformer as the node [key]. Port of eino
  /// `Workflow.AddDocumentTransformerNode`.
  WorkflowNode addDocumentTransformerNode(
    String key,
    DocumentTransformer transformer, {
    NodeOptions? options,
  }) =>
      _add(key, () => toDocumentTransformerNode(transformer, options));

  /// Adds a lambda as the node [key]. Port of eino `Workflow.AddLambdaNode`.
  ///
  /// The type arguments are those of the lambda, so that one written inline
  /// gets its types from its function.
  WorkflowNode addLambdaNode<A, B>(
    String key,
    Lambda<A, B> lambda, {
    NodeOptions? options,
  }) =>
      _add(key, () => toLambdaNode(lambda, options));

  /// Adds a graph, chain or workflow as the node [key]. Port of eino
  /// `Workflow.AddGraphNode`.
  WorkflowNode addGraphNode(
    String key,
    AnyGraph graph, {
    NodeOptions? options,
  }) =>
      _add(key, () => toAnyGraphNode(graph, options));

  /// Adds a node that hands its input on unchanged. Port of eino
  /// `Workflow.AddPassthroughNode`.
  WorkflowNode addPassthroughNode(String key, {NodeOptions? options}) =>
      _add(key, () => toPassthroughNode(options));

  /// The node that stands for the output of the workflow: what is mapped to
  /// it is what the workflow gives. Port of eino `Workflow.End`.
  WorkflowNode end() => _nodes[Graph.end] ??= WorkflowNode(_core, Graph.end);

  /// Adds a branch behind the node [from]: its condition looks at the output
  /// of that node and decides which of its end nodes run. Port of eino
  /// `Workflow.AddBranch`.
  ///
  /// A branch of a workflow carries no data. The nodes it can lead to declare
  /// their inputs like any other node.
  WorkflowBranch addBranch(String from, GraphBranch branch) {
    final added = WorkflowBranch(from, branch);
    _branches.add(added);
    return added;
  }

  /// Port of eino `Workflow.initNode`. A node that cannot be added (a key
  /// that is taken, a reserved key) is reported when the workflow is
  /// compiled, as in Eino.
  WorkflowNode _add(String key, GraphNode Function() node) {
    try {
      _core.addNode(key, node());
    } on GraphBuildException {
      // Kept by the graph and thrown by compile.
    }
    return _nodes[key] = WorkflowNode(_core, key);
  }

  /// Turns branches, dependencies, mappings and static values into the
  /// edges and handlers of the graph.
  ///
  /// Port of the part of eino `Workflow.compile` in front of the compile of
  /// the graph.
  void _prepare() {
    final failed = _core.buildError;
    if (failed != null) throw failed;
    if (_prepared) return;
    _prepared = true;

    try {
      for (final branch in _branches) {
        branch.checkEndNodes(_core.nodes.keys.toSet());
        _core.addBranch(branch.fromNodeKey, branch.branch, skipData: true);
      }
      for (final node in _nodes.values) {
        node.addInputsToGraph();
      }
      for (final node in _nodes.values) {
        final values = <String, Object?>{};
        final mappings = node.takeStaticMappings(values);
        if (mappings.isEmpty) continue;
        (_core.fieldMappingRecords[node.key] ??= []).addAll(mappings);
        _core.handlerPreNode[node.key] = [_staticValues(values)];
      }
    } on GraphBuildException catch (error) {
      _core.buildError ??= error;
      rethrow;
    }
  }

  /// Adds [values], by target path, to the fields that arrive at a node.
  static HandlerPair _staticValues(Map<String, Object?> values) => HandlerPair(
        invoke: (input) => mergeValues([input, values]),
        transform: (input) {
          try {
            return mergeValues([
              input,
              StreamReader<Map<String, Object?>>.fromIterable([values]),
            ])! as StreamReader<Object?>;
            // What cannot be merged is the failure of the stream, as in Eino.
            // ignore: avoid_catches_without_on_clauses
          } catch (error, stackTrace) {
            final (reader, writer) = pipe<Map<String, Object?>>(capacity: 1);
            writer
              ..sendError(error, stackTrace)
              ..close();
            return reader;
          }
        },
      );
}

final class _WorkflowEngine implements GraphEngine {
  const _WorkflowEngine(this._workflow);

  final Workflow<Object?, Object?> _workflow;

  @override
  GenericHelper get helper => _workflow._core.helper;

  @override
  TypeRef<Object?> get inputType => _workflow._core.inputType;

  @override
  TypeRef<Object?> get outputType => _workflow._core.outputType;

  @override
  ComponentType get component => ComponentType.workflow;

  @override
  Future<ComposableRunnable> compile(
    RunContext ctx,
    GraphCompileOptions? options,
  ) async {
    _workflow._prepare();
    return _workflow._core.compile(ctx, options);
  }

  @override
  GraphInfo describe() => _workflow._core.describe();
}
