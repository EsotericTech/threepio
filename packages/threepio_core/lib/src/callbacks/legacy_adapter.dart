/// Runs a handler written for the older callback API under the new one.
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
import '../streaming/stream_reader.dart';
import 'callback_handler.dart';
import 'component_callback_handler.dart';
import 'run_info.dart';

/// The map the older handlers pass from hook to hook.
final class _LegacyContext {
  const _LegacyContext(this.map);
  final Map<String, dynamic> map;
}

/// One key for all adapters: like the handlers of a `CallbackManager`, the
/// adapted handlers of a run see what the others put into the map.
final _legacyContextKey = ContextKey<_LegacyContext>('callbacks.legacyContext');

/// Lets a [CallbackHandler] of the older, map-based callback API take part
/// in a run as a [ComponentCallbackHandler].
///
/// ```dart
/// final ctx = RunContext.background().withHandlers([
///   LegacyCallbackHandlerAdapter(JobStatusCallbackHandler(...)),
/// ]);
/// ```
///
/// **The map.** What the older API calls its `context`, a
/// `Map<String, dynamic>` that each hook receives and returns, travels inside
/// the [RunContext]. Every hook is handed a copy of the map of its context
/// and what it returns becomes the map of the context that follows. So the
/// end or error hook of a component sees what its start hook left, a
/// component that runs inside sees it as well, and all adapted handlers of a
/// run share it, as the handlers of one `CallbackManager` do; but what an
/// inner component adds does not reach the component around it, nor one that
/// runs next to it. The first hook of a run gets an empty map unless one was
/// put there with [withLegacyContext]; [legacyContextOf] reads it back.
///
/// **Payloads** arrive as the older API had them: wrapped in [CallbackInput]
/// and [CallbackOutput], and as the plain value. Where a component of the new
/// kind reports a typed payload, `data` is the value inside it (the messages
/// of a `ModelCallbackInput`, the message of a `ModelCallbackOutput`, the
/// query of a `RetrieverCallbackInput`, ...) and the payload itself is in
/// `metadata['payload']`. A component that was called directly has no node
/// name; the handler then gets its implementation and kind as the name
/// (`OpenRouterChatModel`), which is what the providers used to report, and
/// for a model call `RunInfo.metadata['model']`.
///
/// **Streams.** The stream hooks receive a Dart [Stream] of the handler's own
/// copy of the stream. A handler that wants to read it has to listen before
/// its hook returns; a copy nobody listens to by then is closed, which is
/// what the older API's rule "do not consume the stream" comes to. There is
/// no second `onEnd` when a stream is over, which
/// `CallbackManager.runStreamWithCallbacks` adds.
final class LegacyCallbackHandlerAdapter extends ComponentCallbackHandler {
  /// Adapts [legacy].
  const LegacyCallbackHandlerAdapter(this.legacy);

  /// The adapted handler.
  final CallbackHandler legacy;

  /// The map the adapted handlers of [ctx] share, or `null` before the first
  /// of them has run.
  static Map<String, dynamic>? legacyContextOf(RunContext ctx) =>
      ctx.value(_legacyContextKey)?.map;

  /// A copy of [ctx] in which the adapted handlers start from [context].
  static RunContext withLegacyContext(
    RunContext ctx,
    Map<String, dynamic> context,
  ) =>
      ctx.withValue(_legacyContextKey, _LegacyContext(context));

  Future<RunContext> _run(
    RunContext ctx,
    Future<Map<String, dynamic>> Function(Map<String, dynamic> context) hook,
  ) async {
    // A copy: the older handlers change the map in place, and the map of
    // this context is also the one of every component that runs next to
    // this one.
    final before = Map<String, dynamic>.of(legacyContextOf(ctx) ?? const {});
    final after = await hook(before);
    return withLegacyContext(ctx, after);
  }

  @override
  Future<RunContext> onStart(RunContext ctx, RunInfo info, Object? input) =>
      _run(
        ctx,
        (map) => legacy.onStart(
          map,
          _legacyInfo(info, input),
          CallbackInput(_plainInput(input), metadata: _payload(input)),
        ),
      );

  @override
  Future<RunContext> onEnd(RunContext ctx, RunInfo info, Object? output) =>
      _run(
        ctx,
        (map) => legacy.onEnd(
          map,
          _legacyInfo(info, output),
          CallbackOutput(_plainOutput(output), metadata: _payload(output)),
        ),
      );

  @override
  Future<RunContext> onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) =>
      _run(
        ctx,
        (map) => legacy.onError(map, _legacyInfo(info, null), error, stackTrace),
      );

  @override
  Future<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) =>
      _runWithStream(
        ctx,
        input,
        _plainInput,
        (map, stream) => legacy.onStartWithStreamInput(
          map,
          _legacyInfo(info, null),
          stream,
        ),
      );

  @override
  Future<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) =>
      _runWithStream(
        ctx,
        output,
        _plainOutput,
        (map, stream) => legacy.onEndWithStreamOutput(
          map,
          _legacyInfo(info, null),
          stream,
        ),
      );

  Future<RunContext> _runWithStream(
    RunContext ctx,
    StreamReader<Object?> reader,
    Object? Function(Object? item) plain,
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> context,
      Stream<dynamic> stream,
    ) hook,
  ) async {
    final stream = _ListenAwareStream<dynamic>(reader.asStream().map(plain));
    try {
      return await _run(ctx, (map) => hook(map, stream));
    } finally {
      // A stream that is listened to closes the reader when it is done.
      if (!stream.hasBeenListenedTo) await reader.close();
    }
  }
}

/// The run info as a handler of the older API expects it: a component that
/// was called directly reported itself under its class name there, and a
/// model with the name of the model in the metadata.
RunInfo _legacyInfo(RunInfo info, Object? payload) {
  final model = switch (payload) {
    final ModelCallbackInput input => input.config?.model,
    final ModelCallbackOutput output => output.config?.model,
    _ => null,
  };
  final named = info.name.isNotEmpty || info.type.isEmpty;
  if (named && model == null) return info;
  return info.copyWith(
    name: named ? null : '${info.type}${info.componentType.einoName}',
    metadata: model == null ? null : {...?info.metadata, 'model': model},
  );
}

/// The typed payload itself, for a handler that wants more than the plain
/// value; `null` for a payload that is the plain value.
Map<String, dynamic>? _payload(Object? payload) =>
    identical(_plainInput(payload), payload) &&
            identical(_plainOutput(payload), payload)
        ? null
        : {'payload': payload};

/// The value the older API reported where the new one reports a typed input.
Object? _plainInput(Object? payload) => switch (payload) {
      final ModelCallbackInput input => input.messages,
      final PromptCallbackInput input => input.variables,
      final ToolCallbackInput input => input.argumentsJson,
      final EmbeddingCallbackInput input => input.texts,
      final RetrieverCallbackInput input => input.query,
      final IndexerCallbackInput input => input.docs,
      final LoaderCallbackInput input => input.source,
      final TransformerCallbackInput input => input.input,
      _ => payload,
    };

/// The value the older API reported where the new one reports a typed output.
Object? _plainOutput(Object? payload) => switch (payload) {
      final ModelCallbackOutput output => output.message,
      final PromptCallbackOutput output => output.result,
      final ToolCallbackOutput output => output.response ?? output.toolOutput,
      final EmbeddingCallbackOutput output => output.embeddings,
      final RetrieverCallbackOutput output => output.docs,
      final IndexerCallbackOutput output => output.ids,
      final LoaderCallbackOutput output => output.docs,
      final TransformerCallbackOutput output => output.output,
      _ => payload,
    };

/// A stream that remembers whether anybody listened to it.
final class _ListenAwareStream<T> extends StreamView<T> {
  _ListenAwareStream(super.stream);

  bool hasBeenListenedTo = false;

  // `StreamView` hands this one to the stream it wraps, past `listen` below.
  @override
  Stream<T> asBroadcastStream({
    void Function(StreamSubscription<T> subscription)? onListen,
    void Function(StreamSubscription<T> subscription)? onCancel,
  }) {
    hasBeenListenedTo = true;
    return super.asBroadcastStream(onListen: onListen, onCancel: onCancel);
  }

  @override
  StreamSubscription<T> listen(
    void Function(T value)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    hasBeenListenedTo = true;
    return super.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
