/// Callback handlers with typed payloads, one per kind of component.
///
/// Port of eino `utils/callbacks/template.go`.
library;

import 'dart:async';

import '../components/document/document_callbacks.dart';
import '../components/embedding/embedding_callbacks.dart';
import '../components/indexer/indexer_callbacks.dart';
import '../components/model/model_callbacks.dart';
import '../components/prompt/prompt_callbacks.dart';
import '../components/retriever/retriever_callbacks.dart';
import '../components/tool/tool_callbacks.dart';
import '../core/run_context.dart';
import '../schema/message.dart';
import '../streaming/stream_reader.dart';
import 'callback_timing.dart';
import 'component_callback_handler.dart';
import 'handler_builder.dart';
import 'run_info.dart';

/// The signature of a start or end hook with a typed payload.
///
/// The payload is `null` when what the component reported is not of the type
/// the hook is for.
typedef TypedCallbackHook<T> = FutureOr<RunContext> Function(
  RunContext ctx,
  RunInfo info,
  T payload,
);

/// The signature of a stream hook with typed items. The hook has to close
/// [stream].
typedef TypedCallbackStreamHook<T> = FutureOr<RunContext> Function(
  RunContext ctx,
  RunInfo info,
  StreamReader<T> stream,
);

/// The hooks for one kind of component, with the payloads of that kind.
///
/// The base of the handler types [HandlerHelper] takes: [ModelCallbackHandler],
/// [ToolCallbackHandler] and the others. Each is a set of optional functions;
/// the ones left out are never called and cost nothing.
sealed class TypedCallbackHandler {
  const TypedCallbackHandler();

  /// Whether there is a function for [timing].
  bool needed(CallbackTiming timing);

  FutureOr<RunContext> _start(RunContext ctx, RunInfo info, Object? raw);

  FutureOr<RunContext> _end(RunContext ctx, RunInfo info, Object? raw);

  FutureOr<RunContext> _error(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  );

  FutureOr<RunContext> _endWithStream(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> raw,
  );
}

/// What the typed handlers share. It is private so that the hooks are only
/// ever read through a type that says what their payload is: a function that
/// takes a `ModelCallbackInput?` cannot be read as one that takes anything.
abstract base class _TypedHooks<I extends Object, O extends Object>
    extends TypedCallbackHandler {
  const _TypedHooks({this.onStart, this.onEnd, this.onError});

  /// Called before the component runs.
  final TypedCallbackHook<I?>? onStart;

  /// Called after the component has returned.
  final TypedCallbackHook<O?>? onEnd;

  /// Called after the component has failed.
  final CallbackErrorHook? onError;

  TypedCallbackStreamHook<O?>? get _onEndWithStreamOutput => null;

  I? _input(Object? raw);
  O? _output(Object? raw);

  @override
  bool needed(CallbackTiming timing) => switch (timing) {
        CallbackTiming.onStart => onStart != null,
        CallbackTiming.onEnd => onEnd != null,
        CallbackTiming.onError => onError != null,
        CallbackTiming.onStartWithStreamInput => false,
        CallbackTiming.onEndWithStreamOutput => _onEndWithStreamOutput != null,
      };

  @override
  FutureOr<RunContext> _start(RunContext ctx, RunInfo info, Object? raw) =>
      onStart?.call(ctx, info, _input(raw)) ?? ctx;

  @override
  FutureOr<RunContext> _end(RunContext ctx, RunInfo info, Object? raw) =>
      onEnd?.call(ctx, info, _output(raw)) ?? ctx;

  @override
  FutureOr<RunContext> _error(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) =>
      onError?.call(ctx, info, error, stackTrace) ?? ctx;

  @override
  FutureOr<RunContext> _endWithStream(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> raw,
  ) async {
    final hook = _onEndWithStreamOutput;
    if (hook == null) {
      await raw.close();
      return ctx;
    }
    // The conversion takes `raw` over, so from here on closing `raw` does
    // nothing: if the hook fails, its stream has to be closed here.
    final typed = raw.convert<O?>(_output);
    try {
      return await hook(ctx, info, typed);
    } catch (_) {
      await typed.close();
      rethrow;
    }
  }
}

/// The hooks for chat templates. Port of eino `PromptCallbackHandler`.
final class PromptCallbackHandler
    extends _TypedHooks<PromptCallbackInput, PromptCallbackOutput> {
  /// Creates the handler from the functions it has.
  const PromptCallbackHandler({super.onStart, super.onEnd, super.onError});

  @override
  PromptCallbackInput? _input(Object? raw) => PromptCallbackInput.from(raw);

  @override
  PromptCallbackOutput? _output(Object? raw) => PromptCallbackOutput.from(raw);
}

/// The hooks for chat models. Port of eino `ModelCallbackHandler`.
final class ModelCallbackHandler
    extends _TypedHooks<ModelCallbackInput, ModelCallbackOutput> {
  /// Creates the handler from the functions it has.
  const ModelCallbackHandler({
    super.onStart,
    super.onEnd,
    this.onEndWithStreamOutput,
    super.onError,
  });

  /// Called after the model has started to stream its answer. Every item is
  /// one chunk of it. The function has to close the stream.
  final TypedCallbackStreamHook<ModelCallbackOutput?>? onEndWithStreamOutput;

  @override
  TypedCallbackStreamHook<ModelCallbackOutput?>? get _onEndWithStreamOutput =>
      onEndWithStreamOutput;

  @override
  ModelCallbackInput? _input(Object? raw) => ModelCallbackInput.from(raw);

  @override
  ModelCallbackOutput? _output(Object? raw) => ModelCallbackOutput.from(raw);
}

/// The hooks for embedders. Port of eino `EmbeddingCallbackHandler`.
final class EmbeddingCallbackHandler
    extends _TypedHooks<EmbeddingCallbackInput, EmbeddingCallbackOutput> {
  /// Creates the handler from the functions it has.
  const EmbeddingCallbackHandler({super.onStart, super.onEnd, super.onError});

  @override
  EmbeddingCallbackInput? _input(Object? raw) =>
      EmbeddingCallbackInput.from(raw);

  @override
  EmbeddingCallbackOutput? _output(Object? raw) =>
      EmbeddingCallbackOutput.from(raw);
}

/// The hooks for indexers. Port of eino `IndexerCallbackHandler`.
final class IndexerCallbackHandler
    extends _TypedHooks<IndexerCallbackInput, IndexerCallbackOutput> {
  /// Creates the handler from the functions it has.
  const IndexerCallbackHandler({super.onStart, super.onEnd, super.onError});

  @override
  IndexerCallbackInput? _input(Object? raw) => IndexerCallbackInput.from(raw);

  @override
  IndexerCallbackOutput? _output(Object? raw) =>
      IndexerCallbackOutput.from(raw);
}

/// The hooks for retrievers. Port of eino `RetrieverCallbackHandler`.
final class RetrieverCallbackHandler
    extends _TypedHooks<RetrieverCallbackInput, RetrieverCallbackOutput> {
  /// Creates the handler from the functions it has.
  const RetrieverCallbackHandler({super.onStart, super.onEnd, super.onError});

  @override
  RetrieverCallbackInput? _input(Object? raw) =>
      RetrieverCallbackInput.from(raw);

  @override
  RetrieverCallbackOutput? _output(Object? raw) =>
      RetrieverCallbackOutput.from(raw);
}

/// The hooks for document loaders. Port of eino `LoaderCallbackHandler`.
final class LoaderCallbackHandler
    extends _TypedHooks<LoaderCallbackInput, LoaderCallbackOutput> {
  /// Creates the handler from the functions it has.
  const LoaderCallbackHandler({super.onStart, super.onEnd, super.onError});

  @override
  LoaderCallbackInput? _input(Object? raw) => LoaderCallbackInput.from(raw);

  @override
  LoaderCallbackOutput? _output(Object? raw) => LoaderCallbackOutput.from(raw);
}

/// The hooks for document transformers. Port of eino
/// `TransformerCallbackHandler`.
final class TransformerCallbackHandler
    extends _TypedHooks<TransformerCallbackInput, TransformerCallbackOutput> {
  /// Creates the handler from the functions it has.
  const TransformerCallbackHandler({super.onStart, super.onEnd, super.onError});

  @override
  TransformerCallbackInput? _input(Object? raw) =>
      TransformerCallbackInput.from(raw);

  @override
  TransformerCallbackOutput? _output(Object? raw) =>
      TransformerCallbackOutput.from(raw);
}

/// The hooks for tools. Port of eino `ToolCallbackHandler`.
final class ToolCallbackHandler
    extends _TypedHooks<ToolCallbackInput, ToolCallbackOutput> {
  /// Creates the handler from the functions it has.
  const ToolCallbackHandler({
    super.onStart,
    super.onEnd,
    this.onEndWithStreamOutput,
    super.onError,
  });

  /// Called after a streaming tool has started to return its result. The
  /// function has to close the stream.
  final TypedCallbackStreamHook<ToolCallbackOutput?>? onEndWithStreamOutput;

  @override
  TypedCallbackStreamHook<ToolCallbackOutput?>? get _onEndWithStreamOutput =>
      onEndWithStreamOutput;

  @override
  ToolCallbackInput? _input(Object? raw) => ToolCallbackInput.from(raw);

  @override
  ToolCallbackOutput? _output(Object? raw) => ToolCallbackOutput.from(raw);
}

/// The hooks for the node that executes the tool calls of a message. Port of
/// eino `ToolsNodeCallbackHandlers`.
///
/// The input is the assistant message with the tool calls; the output is the
/// list of tool messages, in which a streamed chunk has an entry for every
/// call and `null` for the ones the chunk says nothing about.
final class ToolsNodeCallbackHandlers
    extends _TypedHooks<Message, List<Message?>> {
  /// Creates the handler from the functions it has.
  const ToolsNodeCallbackHandlers({
    super.onStart,
    super.onEnd,
    this.onEndWithStreamOutput,
    super.onError,
  });

  /// Called after the node has started to stream the tool results. The
  /// function has to close the stream.
  final TypedCallbackStreamHook<List<Message?>?>? onEndWithStreamOutput;

  @override
  TypedCallbackStreamHook<List<Message?>?>? get _onEndWithStreamOutput =>
      onEndWithStreamOutput;

  @override
  Message? _input(Object? raw) => raw is Message ? raw : null;

  @override
  List<Message?>? _output(Object? raw) => switch (raw) {
        final List<Message?> messages => messages,
        // A list that was not created as a list of messages but holds
        // nothing else.
        final List<Object?> items
            when items.isNotEmpty &&
                items.every((item) => item == null || item is Message) =>
          items.cast<Message?>(),
        _ => null,
      };
}

/// The hooks for agents. Port of eino `AgentCallbackHandler`.
///
/// An agent reports its input when it starts and, when it ends, an output
/// that holds the stream of its events. The payloads are passed on as they
/// are reported.
final class AgentCallbackHandler extends _TypedHooks<Object, Object> {
  /// Creates the handler from the functions it has.
  const AgentCallbackHandler({super.onStart, super.onEnd});

  @override
  Object? _input(Object? raw) => raw;

  @override
  Object? _output(Object? raw) => raw;
}

/// Puts one callback handler together from handlers for single kinds of
/// components, each with the payload types of its kind.
///
/// Port of eino `utils/callbacks.HandlerHelper`.
///
/// ```dart
/// final handler = HandlerHelper()
///     .chatModel(ModelCallbackHandler(
///       onEnd: (ctx, info, output) {
///         log.info('tokens: ${output?.tokenUsage?.totalTokens}');
///         return ctx;
///       },
///     ))
///     .tool(ToolCallbackHandler(
///       onStart: (ctx, info, input) {
///         log.info('${info.name}(${input?.argumentsJson})');
///         return ctx;
///       },
///     ))
///     .handler();
/// ```
///
/// The handler only asks for the callbacks of the kinds it was given a
/// handler for, and of those only for the ones that handler has a function
/// for. Graphs, chains and lambdas have no payload type of their own and take
/// a plain [ComponentCallbackHandler].
final class HandlerHelper {
  final Map<ComponentType, TypedCallbackHandler> _typed = {};
  final Map<ComponentType, ComponentCallbackHandler> _compose = {};

  /// The handler that dispatches to everything set on this helper, also to
  /// what is set after this call.
  ComponentCallbackHandler handler() => _HelperHandler(this);

  /// Sets the handler for chat templates.
  HandlerHelper prompt(PromptCallbackHandler handler) =>
      _set(ComponentType.promptTemplate, handler);

  /// Sets the handler for chat models.
  HandlerHelper chatModel(ModelCallbackHandler handler) =>
      _set(ComponentType.chatModel, handler);

  /// Sets the handler for embedders.
  HandlerHelper embedding(EmbeddingCallbackHandler handler) =>
      _set(ComponentType.embedder, handler);

  /// Sets the handler for indexers.
  HandlerHelper indexer(IndexerCallbackHandler handler) =>
      _set(ComponentType.indexer, handler);

  /// Sets the handler for retrievers.
  HandlerHelper retriever(RetrieverCallbackHandler handler) =>
      _set(ComponentType.retriever, handler);

  /// Sets the handler for document loaders.
  HandlerHelper loader(LoaderCallbackHandler handler) =>
      _set(ComponentType.loader, handler);

  /// Sets the handler for document transformers.
  HandlerHelper transformer(TransformerCallbackHandler handler) =>
      _set(ComponentType.documentTransformer, handler);

  /// Sets the handler for tools.
  HandlerHelper tool(ToolCallbackHandler handler) =>
      _set(ComponentType.tool, handler);

  /// Sets the handler for tools nodes.
  HandlerHelper toolsNode(ToolsNodeCallbackHandlers handler) =>
      _set(ComponentType.toolsNode, handler);

  /// Sets the handler for agents.
  HandlerHelper agent(AgentCallbackHandler handler) =>
      _set(ComponentType.agent, handler);

  /// Sets the handler for graphs.
  HandlerHelper graph(ComponentCallbackHandler handler) =>
      _setCompose(ComponentType.graph, handler);

  /// Sets the handler for chains.
  HandlerHelper chain(ComponentCallbackHandler handler) =>
      _setCompose(ComponentType.chain, handler);

  /// Sets the handler for lambdas.
  HandlerHelper lambda(ComponentCallbackHandler handler) =>
      _setCompose(ComponentType.lambda, handler);

  HandlerHelper _set(ComponentType type, TypedCallbackHandler handler) {
    _typed[type] = handler;
    return this;
  }

  HandlerHelper _setCompose(
    ComponentType type,
    ComponentCallbackHandler handler,
  ) {
    _compose[type] = handler;
    return this;
  }
}

/// Port of eino's `handlerTemplate`: a live view of its helper.
final class _HelperHandler extends ComponentCallbackHandler
    implements TimingChecker {
  const _HelperHandler(this._helper);

  final HandlerHelper _helper;

  @override
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing) {
    final typed = _helper._typed[info.componentType];
    if (typed != null) return typed.needed(timing);
    // As an `Object`, so that the test below can promote it.
    final Object? compose = _helper._compose[info.componentType];
    if (compose == null) return false;
    return compose is! TimingChecker || compose.needed(ctx, info, timing);
  }

  @override
  FutureOr<RunContext> onStart(RunContext ctx, RunInfo info, Object? input) {
    final typed = _helper._typed[info.componentType];
    if (typed != null) return typed._start(ctx, info, input);
    return _helper._compose[info.componentType]?.onStart(ctx, info, input) ??
        ctx;
  }

  @override
  FutureOr<RunContext> onEnd(RunContext ctx, RunInfo info, Object? output) {
    final typed = _helper._typed[info.componentType];
    if (typed != null) return typed._end(ctx, info, output);
    return _helper._compose[info.componentType]?.onEnd(ctx, info, output) ??
        ctx;
  }

  @override
  FutureOr<RunContext> onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    final typed = _helper._typed[info.componentType];
    if (typed != null) return typed._error(ctx, info, error, stackTrace);
    return _helper._compose[info.componentType]
            ?.onError(ctx, info, error, stackTrace) ??
        ctx;
  }

  @override
  FutureOr<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) {
    final compose = _helper._compose[info.componentType];
    return compose == null
        ? super.onStartWithStreamInput(ctx, info, input)
        : compose.onStartWithStreamInput(ctx, info, input);
  }

  @override
  FutureOr<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    final typed = _helper._typed[info.componentType];
    if (typed != null) return typed._endWithStream(ctx, info, output);
    final compose = _helper._compose[info.componentType];
    return compose == null
        ? super.onEndWithStreamOutput(ctx, info, output)
        : compose.onEndWithStreamOutput(ctx, info, output);
  }
}
