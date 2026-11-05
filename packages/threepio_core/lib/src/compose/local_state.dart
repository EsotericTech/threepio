/// The state a graph keeps for one run, and the handlers that read and write
/// it around a node.
///
/// Port of eino `compose/state.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../core/run_context.dart';
import '../internal/async_mutex.dart';
import '../streaming/stream_reader.dart';
import 'composable_runnable.dart';
import 'stream_conversion.dart';
import 'type_ref.dart';

/// Runs before a node: sees its input and the state, returns the input the
/// node gets. Port of eino `compose.StatePreHandler`.
typedef StatePreHandler<I, S> = FutureOr<I> Function(
  RunContext ctx,
  I input,
  S state,
);

/// Runs after a node: sees its output and the state, returns the output the
/// graph goes on with. Port of eino `compose.StatePostHandler`.
typedef StatePostHandler<O, S> = FutureOr<O> Function(
  RunContext ctx,
  O output,
  S state,
);

/// A [StatePreHandler] that gets the input as a stream when the graph is run
/// with one, instead of the joined chunks. Port of eino
/// `compose.StreamStatePreHandler`.
typedef StreamStatePreHandler<I, S> = FutureOr<StreamReader<I>> Function(
  RunContext ctx,
  StreamReader<I> input,
  S state,
);

/// A [StatePostHandler] that gets the output as a stream. Port of eino
/// `compose.StreamStatePostHandler`.
typedef StreamStatePostHandler<O, S> = FutureOr<StreamReader<O>> Function(
  RunContext ctx,
  StreamReader<O> output,
  S state,
);

/// Makes a graph keep a state object for each run.
///
/// Port of eino `compose.WithGenLocalState`. [LocalState.of] takes the
/// function that creates the state when a run starts:
///
/// ```dart
/// final graph = Graph<String, String>(
///   localState: LocalState.of<Counter>((ctx) => Counter()),
/// );
/// ```
///
/// Nodes reach the state through their state handlers (`NodeOptions`) and
/// with [processState]. The state lives as long as the run and is mutable;
/// both ways to reach it take turns, so nodes that run side by side can share
/// it.
final class LocalState {
  LocalState._(this._type, this._create);

  /// The state of type [S] that [create] makes for every run.
  ///
  /// A static method and not a constructor because it captures [S]: handlers
  /// and [processState] find the state by that type.
  static LocalState of<S extends Object>(S Function(RunContext ctx) create) =>
      LocalState._(TypeRef<S>(), create);

  final TypeRef<Object> _type;
  final Object Function(RunContext ctx) _create;

  /// The type of the state.
  @internal
  TypeRef<Object> get stateType => _type;

  /// A new state for a run.
  @internal
  Object create(RunContext ctx) => _create(ctx);

  @override
  String toString() => 'LocalState<${_type.name}>';
}

/// A state handler of a node, made by one of the four static methods.
///
/// The methods capture the value type and the state type of the function they
/// are given, which the graph checks against the node and against its own
/// state when the node is added:
///
/// ```dart
/// graph.addLambdaNode(
///   'count',
///   lambda,
///   options: NodeOptions(
///     statePreHandler: StateHandler.pre<String, Counter>((ctx, input, state) {
///       state.calls++;
///       return input;
///     }),
///   ),
/// );
/// ```
final class StateHandler {
  StateHandler._({
    required this.valueType,
    required this.stateType,
    required this.runnable,
    required this.isStream,
    required this.isPre,
  });

  /// A handler that runs before a node. Port of eino
  /// `compose.WithStatePreHandler`.
  ///
  /// [I] must be the input type of the node and [S] the state type of the
  /// graph. When the graph is run with a stream, the handler gets the joined
  /// chunks, so the node no longer sees its input arrive piece by piece; use
  /// [streamPre] to keep that.
  static StateHandler pre<I, S extends Object>(StatePreHandler<I, S> handler) =>
      StateHandler._(
        valueType: TypeRef<I>(),
        stateType: TypeRef<S>(),
        isStream: false,
        isPre: true,
        runnable: RunnablePacker<I, I, Object?>(
          invoke: (ctx, input, _) =>
              _withState<S, I>(ctx, (state) => handler(ctx, input, state)),
        ).toComposableRunnable(),
      );

  /// A handler that runs after a node. Port of eino
  /// `compose.WithStatePostHandler`.
  ///
  /// [O] must be the output type of the node and [S] the state type of the
  /// graph. When the graph is run with a stream, the handler gets the joined
  /// chunks of the node's output; use [streamPost] to keep the stream.
  static StateHandler post<O, S extends Object>(
    StatePostHandler<O, S> handler,
  ) =>
      StateHandler._(
        valueType: TypeRef<O>(),
        stateType: TypeRef<S>(),
        isStream: false,
        isPre: false,
        runnable: RunnablePacker<O, O, Object?>(
          invoke: (ctx, output, _) =>
              _withState<S, O>(ctx, (state) => handler(ctx, output, state)),
        ).toComposableRunnable(),
      );

  /// A handler that runs before a node and takes the input as a stream. Port
  /// of eino `compose.WithStreamStatePreHandler`.
  static StateHandler streamPre<I, S extends Object>(
    StreamStatePreHandler<I, S> handler,
  ) =>
      StateHandler._(
        valueType: TypeRef<I>(),
        stateType: TypeRef<S>(),
        isStream: true,
        isPre: true,
        runnable: RunnablePacker<I, I, Object?>(
          transform: (ctx, input, _) => _withState<S, StreamReader<I>>(
            ctx,
            (state) => handler(ctx, input, state),
          ),
        ).toComposableRunnable(),
      );

  /// A handler that runs after a node and takes the output as a stream. Port
  /// of eino `compose.WithStreamStatePostHandler`.
  static StateHandler streamPost<O, S extends Object>(
    StreamStatePostHandler<O, S> handler,
  ) =>
      StateHandler._(
        valueType: TypeRef<O>(),
        stateType: TypeRef<S>(),
        isStream: true,
        isPre: false,
        runnable: RunnablePacker<O, O, Object?>(
          transform: (ctx, output, _) => _withState<S, StreamReader<O>>(
            ctx,
            (state) => handler(ctx, output, state),
          ),
        ).toComposableRunnable(),
      );

  /// The type of the value the handler takes and returns.
  @internal
  final TypeRef<Object?> valueType;

  /// The type of the state the handler takes.
  @internal
  final TypeRef<Object?> stateType;

  /// The handler as something the graph can run.
  @internal
  final ComposableRunnable runnable;

  /// Whether the handler takes a stream.
  @internal
  final bool isStream;

  /// Whether the handler runs before its node.
  @internal
  final bool isPre;

  @override
  String toString() => 'StateHandler.${isStream ? 'stream' : ''}'
      '${isPre ? (isStream ? 'Pre' : 'pre') : (isStream ? 'Post' : 'post')}'
      '<${valueType.name}, ${stateType.name}>';
}

/// Reads or changes the state of the running graph.
///
/// Port of eino `compose.ProcessState`. [fn] gets the state of type [S] of the
/// graph the caller runs in, or of the nearest graph around it that has a
/// state of that type. Calls take turns per state object: while [fn] runs, no
/// state handler and no other [processState] call sees the same state. Do not
/// call [processState] for the same state from inside [fn].
///
/// Throws [StateError] when no graph around the caller has a state of type
/// [S].
Future<void> processState<S extends Object>(
  RunContext ctx,
  FutureOr<void> Function(RunContext ctx, S state) fn,
) =>
    _withState<S, void>(ctx, (state) => fn(ctx, state));

// Asynchronous, so that a missing state fails the returned future instead of
// throwing at the call.
Future<R> _withState<S extends Object, R>(
  RunContext ctx,
  FutureOr<R> Function(S state) body,
) async {
  final holder = _find<S>(ctx);
  return holder.mutex.protect(() => body(holder.state as S));
}

InternalState _find<S extends Object>(RunContext ctx) {
  final innermost = internalStateOf(ctx);
  if (innermost == null) {
    throw StateError('get state from context fail: have not set state');
  }
  for (InternalState? holder = innermost; holder != null; holder = holder.parent) {
    if (holder.state is S) return holder;
  }
  throw StateError(
    'get state from context fail: cannot find state with type: $S in states '
    'chain, current state type: ${innermost.state.runtimeType}',
  );
}

/// The state of one run of one graph, with the states of the graphs around it.
///
/// Port of eino `internalState`.
@internal
final class InternalState {
  /// The holder of [state] inside [parent].
  InternalState(this.state, {this.parent});

  /// The state object. Replaced when a run is resumed from a checkpoint.
  Object state;

  /// Makes the users of [state] take turns.
  final AsyncMutex mutex = AsyncMutex();

  /// The state of the graph around this one.
  final InternalState? parent;
}

final _stateKey = ContextKey<InternalState>('compose.localState');

/// The state of the innermost graph [ctx] runs in.
@internal
InternalState? internalStateOf(RunContext ctx) => ctx.value(_stateKey);

/// [ctx] for a run of a graph whose state is [state]. The state the context
/// had becomes its parent.
@internal
RunContext withInternalState(RunContext ctx, Object state) => ctx.withValue(
      _stateKey,
      InternalState(state, parent: internalStateOf(ctx)),
    );
