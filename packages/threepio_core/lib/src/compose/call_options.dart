/// The options of one run of a graph.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../callbacks/component_callback_handler.dart';
import '../components/document/loader.dart';
import '../components/document/transformer.dart';
import '../components/embedding/embedder.dart';
import '../components/indexer/indexer.dart';
import '../components/model/chat_model_options.dart';
import '../components/prompt/chat_template.dart';
import '../components/retriever/retriever.dart';
import '../components/tool/tool_options.dart';
import '../core/run_context.dart';
import 'interrupt.dart';
import 'node_path.dart';
import 'type_ref.dart';
import 'tools_node_options.dart';

/// Changes the state a run is resumed with.
///
/// Port of eino `compose.StateModifier`. It is called once for the graph that
/// is resumed and once for every nested graph that goes on from the
/// checkpoint, each time with the state that was saved for that graph, before
/// the graph continues. [path] leads to the graph whose [state] it is; it is
/// empty for the graph that was called. The state is changed in place.
typedef StateModifier = FutureOr<void> Function(
  RunContext ctx,
  NodePath path,
  Object state,
);

/// One option of a run: callbacks, options for the components inside the
/// graph, limits.
///
/// Port of eino `compose.Option`. An option applies to every node it fits (a
/// [CallOption.chatModel] option to every chat model node) unless it is aimed
/// with [designateNode] or [designateNodeWithPath]:
///
/// ```dart
/// await runnable.invoke(ctx, input, options: [
///   CallOption.chatModel(const ChatModelOptions(temperature: 0)),
///   CallOption.chatModel(const ChatModelOptions(model: 'small'))
///       .designateNode(['summarize']),
///   CallOption.callbacks([logger]),
/// ]);
/// ```
sealed class CallOption {
  CallOption._(Iterable<NodePath> paths) : paths = List.unmodifiable(paths);

  /// Callback handlers for this run. Port of eino `compose.WithCallbacks`.
  ///
  /// Without a designation they hear the graph and everything in it; aimed at
  /// a node they hear only that node.
  factory CallOption.callbacks(List<ComponentCallbackHandler> handlers) =
      _CallbacksOption;

  /// Options for chat model nodes. Port of eino `compose.WithChatModelOption`.
  factory CallOption.chatModel(ChatModelOptions options) =>
      _ComponentOption<ChatModelOptions>([options]);

  /// Options for chat template nodes. Port of eino
  /// `compose.WithChatTemplateOption`.
  factory CallOption.chatTemplate(ChatTemplateOptions options) =>
      _ComponentOption<ChatTemplateOptions>([options]);

  /// Options for tools nodes. Port of eino `compose.WithToolsNodeOption`.
  factory CallOption.toolsNode(ToolsNodeOptions options) =>
      _ComponentOption<ToolsNodeOptions>([options]);

  /// Options for the tools that tools nodes run. Short for
  /// `CallOption.toolsNode(ToolsNodeOptions(toolOptions: options))`, eino's
  /// `compose.WithToolsNodeOption(compose.WithToolOption(...))`.
  factory CallOption.tool(ToolOptions options) =>
      CallOption.toolsNode(ToolsNodeOptions(toolOptions: options));

  /// Options for embedding nodes. Port of eino `compose.WithEmbeddingOption`.
  factory CallOption.embedding(EmbedderOptions options) =>
      _ComponentOption<EmbedderOptions>([options]);

  /// Options for retriever nodes. Port of eino `compose.WithRetrieverOption`.
  factory CallOption.retriever(RetrieverOptions options) =>
      _ComponentOption<RetrieverOptions>([options]);

  /// Options for loader nodes. Port of eino `compose.WithLoaderOption`.
  factory CallOption.loader(LoaderOptions options) =>
      _ComponentOption<LoaderOptions>([options]);

  /// Options for document transformer nodes. Port of eino
  /// `compose.WithDocumentTransformerOption`.
  factory CallOption.documentTransformer(TransformerOptions options) =>
      _ComponentOption<TransformerOptions>([options]);

  /// Options for indexer nodes. Port of eino `compose.WithIndexerOption`.
  factory CallOption.indexer(IndexerOptions options) =>
      _ComponentOption<IndexerOptions>([options]);

  /// The most steps this run may take, in place of the limit the graph was
  /// compiled with. Port of eino `compose.WithRuntimeMaxSteps`.
  ///
  /// Only a graph that runs in Pregel mode has a step limit.
  factory CallOption.runtimeMaxSteps(int maxSteps) = _MaxStepsOption;

  /// The checkpoint to resume from, and to write to when the run is
  /// interrupted. Port of eino `compose.WithCheckPointID`.
  factory CallOption.checkpointId(String id) = _CheckpointIdOption;

  /// The checkpoint to write to, when that is not the one that is read. Port
  /// of eino `compose.WithWriteToCheckPointID`.
  factory CallOption.writeToCheckpointId(String id) =
      _WriteToCheckpointIdOption;

  /// Starts a new run even though [CallOption.checkpointId] names a
  /// checkpoint that exists. Port of eino `compose.WithForceNewRun`.
  factory CallOption.forceNewRun() = _ForceNewRunOption;

  /// Changes the state the run is resumed with. Port of eino
  /// `compose.WithStateModifier`.
  factory CallOption.stateModifier(StateModifier modifier) =
      _StateModifierOption;

  /// Lets a nested graph hand its checkpoint to the graph around it as soon
  /// as it has one. Port of the internal option eino adds with
  /// `withSubGraphCheckpointPublisher`; it reaches the nested graph and no
  /// graph inside that.
  @internal
  factory CallOption.subGraphCheckpointPublisher(
    void Function(SubGraphInterrupt interrupt) publish,
  ) = _SubGraphPublisherOption;

  /// Options for lambda nodes that take options of the type [TOption] (see
  /// `Lambda.invokableWithOption`). Port of eino `compose.WithLambdaOption`.
  ///
  /// The options reach the lambdas that were declared with exactly this
  /// option type: a lambda declared with a supertype of [TOption] does not
  /// get them. This is a deliberate difference from Eino, which looks at the
  /// dynamic type of each option value; with Dart's subtyping that would hand
  /// a lambda declared with `Object` the options of every other lambda.
  static CallOption lambda<TOption>(List<TOption> options) =>
      _ComponentOption<TOption>(options);

  /// The nodes this option is aimed at. Empty: every node it fits.
  final List<NodePath> paths;

  /// This option aimed at the nodes with the given keys of the graph that is
  /// run. Port of eino `Option.DesignateNode`.
  CallOption designateNode(List<String> keys) =>
      designateNodeWithPath([for (final key in keys) NodePath([key])]);

  /// This option aimed at the nodes the given paths lead to, which may lie in
  /// nested graphs. Port of eino `Option.DesignateNodeWithPath`.
  CallOption designateNodeWithPath(List<NodePath> paths) =>
      withPaths([...this.paths, ...paths]);

  /// This option with [paths] in place of its own.
  @internal
  CallOption withPaths(Iterable<NodePath> paths);

  /// The component options this carries.
  @internal
  List<Object?> get componentOptions => const [];

  /// Whether the component options this carries are meant for a node that
  /// takes options of [optionType].
  ///
  /// Eino compares the type of the option value with the option type of the
  /// node; here the type the option was created for is compared, so that a
  /// node with a wide option type does not collect the options of every other
  /// kind of node.
  @internal
  bool isFor(TypeRef<Object?> optionType) => false;

  /// The name of the type the component options were created for.
  @internal
  String get optionTypeName => '';

  /// The callback handlers this carries.
  @internal
  List<ComponentCallbackHandler> get handlers => const [];

  /// The step limit this carries, or 0.
  @internal
  int get maxRunSteps => 0;

  /// The checkpoint to read, if this option names one.
  @internal
  String? get checkpointId => null;

  /// The checkpoint to write, if this option names one.
  @internal
  String? get writeToCheckpointId => null;

  /// Whether this option asks for a new run.
  @internal
  bool get forceNewRun => false;

  /// The state modifier this carries.
  @internal
  StateModifier? get stateModifier => null;

  /// The function a nested graph hands its checkpoint to.
  @internal
  void Function(SubGraphInterrupt interrupt)? get subGraphCheckpointPublisher =>
      null;

  /// Whether this option only means something to the graph it is given to:
  /// the checkpoint options. Eino drops them from an option it passes on into
  /// a nested graph (`Option.deepCopy`).
  @internal
  bool get isRunOnly => false;
}

final class _ComponentOption<T> extends CallOption {
  _ComponentOption(List<T> options, [super.paths = const []])
      : _options = List.unmodifiable(options),
        super._();

  final List<T> _options;

  @override
  List<Object?> get componentOptions => _options;

  @override
  bool isFor(TypeRef<Object?> optionType) => TypeRef<T>().isSameAs(optionType);

  @override
  String get optionTypeName => '$T';

  @override
  CallOption withPaths(Iterable<NodePath> paths) =>
      _ComponentOption<T>(_options, paths);

  @override
  String toString() => 'CallOption<$T>($_options, paths: $paths)';
}

final class _CallbacksOption extends CallOption {
  _CallbacksOption(
    List<ComponentCallbackHandler> handlers, [
    super.paths = const [],
  ])  : handlers = List.unmodifiable(handlers),
        super._();

  @override
  final List<ComponentCallbackHandler> handlers;

  @override
  CallOption withPaths(Iterable<NodePath> paths) =>
      _CallbacksOption(handlers, paths);

  @override
  String toString() => 'CallOption.callbacks(${handlers.length}, paths: $paths)';
}

final class _MaxStepsOption extends CallOption {
  _MaxStepsOption(this.maxRunSteps, [super.paths = const []]) : super._();

  @override
  final int maxRunSteps;

  @override
  CallOption withPaths(Iterable<NodePath> paths) =>
      _MaxStepsOption(maxRunSteps, paths);

  @override
  String toString() => 'CallOption.runtimeMaxSteps($maxRunSteps)';
}

final class _CheckpointIdOption extends CallOption {
  _CheckpointIdOption(String id, [super.paths = const []])
      : checkpointId = id,
        super._();

  @override
  final String checkpointId;

  @override
  CallOption withPaths(Iterable<NodePath> paths) =>
      _CheckpointIdOption(checkpointId, paths);

  @override
  bool get isRunOnly => true;

  @override
  String toString() => 'CallOption.checkpointId($checkpointId)';
}

final class _WriteToCheckpointIdOption extends CallOption {
  _WriteToCheckpointIdOption(String id, [super.paths = const []])
      : writeToCheckpointId = id,
        super._();

  @override
  final String writeToCheckpointId;

  @override
  CallOption withPaths(Iterable<NodePath> paths) =>
      _WriteToCheckpointIdOption(writeToCheckpointId, paths);

  @override
  bool get isRunOnly => true;

  @override
  String toString() => 'CallOption.writeToCheckpointId($writeToCheckpointId)';
}

final class _ForceNewRunOption extends CallOption {
  _ForceNewRunOption([super.paths = const []]) : super._();

  @override
  bool get forceNewRun => true;

  @override
  CallOption withPaths(Iterable<NodePath> paths) => _ForceNewRunOption(paths);

  @override
  bool get isRunOnly => true;

  @override
  String toString() => 'CallOption.forceNewRun()';
}

final class _StateModifierOption extends CallOption {
  _StateModifierOption(
    StateModifier modifier, [
    super.paths = const [],
  ])  : stateModifier = modifier,
        super._();

  @override
  final StateModifier stateModifier;

  @override
  CallOption withPaths(Iterable<NodePath> paths) =>
      _StateModifierOption(stateModifier, paths);

  @override
  bool get isRunOnly => true;

  @override
  String toString() => 'CallOption.stateModifier()';
}

final class _SubGraphPublisherOption extends CallOption {
  _SubGraphPublisherOption(this.subGraphCheckpointPublisher) : super._(const []);

  @override
  final void Function(SubGraphInterrupt interrupt) subGraphCheckpointPublisher;

  @override
  bool get isRunOnly => true;

  @override
  CallOption withPaths(Iterable<NodePath> paths) => this;

  @override
  String toString() => 'CallOption.subGraphCheckpointPublisher()';
}
