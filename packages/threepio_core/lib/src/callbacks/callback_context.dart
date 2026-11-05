/// The callback handlers a run context carries.
library;

import 'package:meta/meta.dart';

import '../core/run_context.dart';
import 'component_callback_handler.dart';
import 'global_callbacks.dart';
import 'run_info.dart';

/// The handlers of a run and the run info of the component that is about to
/// start: what eino keeps in its callback `manager`.
///
/// Immutable. The lists are never modified after construction.
@internal
final class HandlerChain {
  /// Creates a chain.
  const HandlerChain({
    required this.globalHandlers,
    required this.handlers,
    this.runInfo,
  });

  /// The global handlers as they were when the chain was set up.
  final List<ComponentCallbackHandler> globalHandlers;

  /// The handlers given to the run.
  final List<ComponentCallbackHandler> handlers;

  /// The run info of the component that has not fired its start callback
  /// yet, or `null` when there is none.
  final RunInfo? runInfo;

  /// The handlers in the order of an end callback: the run's own, then the
  /// global ones.
  Iterable<ComponentCallbackHandler> get all =>
      handlers.followedBy(globalHandlers);

  /// The same handlers with another pending [runInfo].
  HandlerChain withRunInfo(RunInfo? runInfo) => HandlerChain(
        globalHandlers: globalHandlers,
        handlers: handlers,
        runInfo: runInfo,
      );
}

/// A context value may not be `null`, so "no chain" is a slot without one.
final class _ChainSlot {
  const _ChainSlot(this.chain);
  final HandlerChain? chain;
}

final class _RunInfoSlot {
  const _RunInfoSlot(this.runInfo);
  final RunInfo? runInfo;
}

final _chainKey = ContextKey<_ChainSlot>('callbacks.handlers');
final _startedKey = ContextKey<_RunInfoSlot>('callbacks.startedRunInfo');

/// The handler chain of [ctx], or `null` when it has none.
@internal
HandlerChain? handlerChainOf(RunContext ctx) => ctx.value(_chainKey)?.chain;

/// [ctx] with [chain] as its handler chain; `null` takes the chain away.
@internal
RunContext withHandlerChain(RunContext ctx, HandlerChain? chain) {
  if (chain == null && ctx.value(_chainKey)?.chain == null) return ctx;
  return ctx.withValue(_chainKey, _ChainSlot(chain));
}

/// The run info of the component whose start callback produced [ctx].
@internal
RunInfo? startedRunInfoOf(RunContext ctx) => ctx.value(_startedKey)?.runInfo;

/// [ctx] as the context of the started component described by [runInfo].
@internal
RunContext withStartedRunInfo(RunContext ctx, RunInfo? runInfo) =>
    ctx.withValue(_startedKey, _RunInfoSlot(runInfo));

/// The callback side of a [RunContext].
///
/// A context carries the callback handlers of the run it belongs to. Give a
/// run its handlers with [withHandlers] and pass the context on; every
/// component that is called with it reports to them:
///
/// ```dart
/// final ctx = RunContext.background().withHandlers([myHandler]);
/// await model.generate(messages, options: ChatModelOptions(runContext: ctx));
/// ```
extension CallbackContext on RunContext {
  /// A copy of this context whose components also report to [handlers].
  ///
  /// The handlers the context already has are kept and called first when a
  /// component ends (last when it starts). The handlers of `GlobalCallbacks`
  /// are part of every context that has callbacks at all and need not be
  /// passed here.
  RunContext withHandlers(Iterable<ComponentCallbackHandler> handlers) =>
      appendHandlers(this, handlerChainOf(this)?.runInfo, handlers);

  /// What is known about the component this context belongs to: the one that
  /// is about to fire its start callback or, after that, the one that fired
  /// it. `null` when no component has reported itself.
  RunInfo? get runInfo =>
      handlerChainOf(this)?.runInfo ?? startedRunInfoOf(this);

  /// Whether a component called with this context has any handler to report
  /// to.
  bool get hasCallbacks => handlerChainOf(this) != null;

  /// The handlers a component called with this context reports to: the ones
  /// given to the run, then the global ones.
  List<ComponentCallbackHandler> get callbackHandlers =>
      List.unmodifiable(handlerChainOf(this)?.all ?? const []);
}

/// Sets up the callbacks of [ctx] from scratch: [handlers] and the global
/// handlers, with [info] as the run info of the component about to start.
///
/// Port of eino `callbacks.InitCallbacks`. Handlers the context had before
/// are dropped. Use it to run a component on its own, outside a graph:
///
/// ```dart
/// final ctx = initCallbacks(
///   RunContext.background(),
///   const RunInfo(name: 'summarise', type: 'OpenAI',
///       componentType: ComponentType.chatModel),
///   [myHandler],
/// );
/// ```
///
/// When there is no handler at all (none given, none global) the returned
/// context has no callbacks, and firing them costs nothing.
RunContext initCallbacks(
  RunContext ctx,
  RunInfo? info, [
  Iterable<ComponentCallbackHandler> handlers = const [],
]) {
  final own = List<ComponentCallbackHandler>.unmodifiable(handlers);
  final global = GlobalCallbacks.handlers;
  if (own.isEmpty && global.isEmpty) return withHandlerChain(ctx, null);
  return withHandlerChain(
    ctx,
    HandlerChain(globalHandlers: global, handlers: own, runInfo: info),
  );
}

/// Keeps the handlers of [ctx] and makes [info] the run info of the component
/// about to start.
///
/// Port of eino `callbacks.ReuseHandlers`. This is what code calls before it
/// runs an inner component with the callbacks of the outer one. On a context
/// without callbacks it sets them up with the global handlers.
RunContext reuseHandlers(RunContext ctx, RunInfo? info) {
  final chain = handlerChainOf(ctx);
  if (chain == null) return initCallbacks(ctx, info);
  return withHandlerChain(ctx, chain.withRunInfo(info));
}

/// Adds [handlers] to the ones [ctx] has and makes [info] the run info of the
/// component about to start.
///
/// Port of eino's internal `callbacks.AppendHandlers`, which graphs and
/// agents use to add the handlers of one call. The global handlers are taken
/// afresh and never doubled.
RunContext appendHandlers(
  RunContext ctx,
  RunInfo? info, [
  Iterable<ComponentCallbackHandler> handlers = const [],
]) {
  final chain = handlerChainOf(ctx);
  if (chain == null) return initCallbacks(ctx, info, handlers);
  return initCallbacks(ctx, info, [...chain.handlers, ...handlers]);
}

/// Makes sure the callbacks of [ctx] know what component is about to start.
///
/// Port of eino `callbacks.EnsureRunInfo`. A component that fires its own
/// callbacks calls this first, with its implementation name as [type] (see
/// `TypedComponent`) and its kind as [component]. Inside a graph the node has
/// already said what it is and the context is returned as it is; called
/// directly, the component gets a run info with an empty name, and the global
/// handlers if the context had no callbacks.
RunContext ensureRunInfo(RunContext ctx, String type, ComponentType component) {
  final chain = handlerChainOf(ctx);
  if (chain != null && chain.runInfo != null) return ctx;
  final info = RunInfo(name: '', type: type, componentType: component);
  return chain == null ? initCallbacks(ctx, info) : reuseHandlers(ctx, info);
}
