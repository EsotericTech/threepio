/// Interrupts: pausing a run at a point it can be resumed from.
///
/// Port of eino `compose/interrupt.go` and `internal/core/interrupt.go`.
library;

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../core/interrupt_signal.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../schema/type_registry.dart';
import 'address.dart';
import 'checkpoint.dart';
import 'checkpoint_serializer.dart';
import 'resume.dart';

final _log = Logger('threepio.compose');

const _uuid = Uuid();

/// What a component saved when it interrupted, to find again when the run is
/// resumed.
///
/// Port of eino `core.InterruptState`.
@internal
@immutable
final class InterruptState {
  /// The saved [state], with what the layer that raised the interrupt keeps
  /// for itself.
  const InterruptState({this.state, this.layerSpecificPayload});

  /// A state from its JSON form.
  factory InterruptState.fromJson(Map<String, Object?> json) => InterruptState(
        state: TypeRegistry.decode(json['state']),
        layerSpecificPayload: TypeRegistry.decode(json['layer_payload']),
      );

  /// What the component passed to `statefulInterrupt`.
  final Object? state;

  /// Data of the layer between the component and the engine (the ADK keeps
  /// the kind of agent here).
  final Object? layerSpecificPayload;

  /// The JSON form of the state. Both values must be JSON or of a type
  /// registered with [TypeRegistry].
  Map<String, Object?> toJson() => {
        if (state != null) 'state': TypeRegistry.encode(state),
        if (layerSpecificPayload != null)
          'layer_payload': TypeRegistry.encode(layerSpecificPayload),
      };

  static const _equality = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      other is InterruptState &&
      _equality.equals(other.state, state) &&
      _equality.equals(other.layerSpecificPayload, layerSpecificPayload);

  @override
  int get hashCode =>
      Object.hash(_equality.hash(state), _equality.hash(layerSpecificPayload));

  @override
  String toString() => 'interrupt state: State=$state, '
      'LayerSpecificPayload=$layerSpecificPayload';
}

/// An interrupt on its way up to the graph that turns it into a checkpoint.
///
/// Port of eino `core.InterruptSignal`. It is what [interrupt],
/// [statefulInterrupt] and [compositeInterrupt] return; user code throws it
/// and has no reason to look inside.
@internal
final class AddressedInterruptSignal implements InterruptSignal {
  /// A signal raised at [address].
  AddressedInterruptSignal({
    required this.id,
    required this.address,
    this.info,
    this.isRootCause = false,
    this.state = const InterruptState(),
    List<AddressedInterruptSignal> subs = const [],
  }) : subs = List.of(subs);

  /// The id of the interrupt point. It is what a caller resumes.
  final String id;

  /// Where the signal was raised.
  final Address address;

  /// What the component tells the caller about the interrupt.
  final Object? info;

  /// Whether the component at [address] itself asked for the pause, as
  /// opposed to passing on the interrupts of the components inside it.
  final bool isRootCause;

  /// What the component saved for its resumed run.
  final InterruptState state;

  /// The signals of the components inside the one at [address].
  final List<AddressedInterruptSignal> subs;

  /// The same interrupt as a new point at [address], for a signal that was
  /// raised without one.
  AddressedInterruptSignal readdressed(Address address) =>
      AddressedInterruptSignal(
        id: _uuid.v4(),
        address: address,
        info: info,
        isRootCause: isRootCause,
        state: InterruptState(state: state.state),
      );

  @override
  String toString() => 'interrupt signal: ID=$id, Addr=$address, '
      'Info=interrupt info: Info=$info, IsRootCause=$isRootCause, '
      'State=$state, SubsLen=${subs.length}';
}

/// Creates the signal of an interrupt at the address of [ctx].
///
/// Port of eino `core.Interrupt`. With [subs] the signal stands for a
/// composite component whose parts interrupted; without, it is a root cause.
@internal
AddressedInterruptSignal newInterruptSignal(
  RunContext ctx,
  Object? info,
  Object? state,
  List<AddressedInterruptSignal> subs, {
  Object? layerPayload,
}) =>
    AddressedInterruptSignal(
      id: _uuid.v4(),
      address: ctx.currentAddress,
      info: info,
      isRootCause: subs.isEmpty,
      state: InterruptState(state: state, layerSpecificPayload: layerPayload),
      subs: subs,
    );

/// Pauses the run at the component that throws the returned signal.
///
/// Port of eino `compose.Interrupt`. The graph the component runs in stops,
/// writes a checkpoint when it has a store and a checkpoint id, and fails
/// with a [GraphInterruptedException]. [info] is for the caller: it arrives
/// as [InterruptCtx.info] and is not saved.
///
/// ```dart
/// Lambda<String, String>.invokable((ctx, input) {
///   final resumed = getResumeContext<String>(ctx);
///   if (!resumed.isResumeTarget) throw interrupt(ctx, 'Approve "$input"?');
///   return resumed.data ?? input;
/// });
/// ```
///
/// When the run is resumed the component runs again from its beginning, with
/// the input it had only if it saved it (see [statefulInterrupt]).
InterruptSignal interrupt(RunContext ctx, Object? info) =>
    newInterruptSignal(ctx, info, null, const []);

/// Like [interrupt], and saves [state] in the checkpoint for the component to
/// find again with `getInterruptState` when the run is resumed.
///
/// Port of eino `compose.StatefulInterrupt`. [state] must be JSON (maps,
/// lists, strings, numbers, booleans) or of a type registered with
/// `TypeRegistry.registerName`; otherwise the checkpoint cannot be written.
InterruptSignal statefulInterrupt(RunContext ctx, Object? info, Object? state) =>
    newInterruptSignal(ctx, info, state, const []);

/// The interrupt of a component that runs interruptible parts of its own and
/// passes their interrupts on.
///
/// Port of eino `compose.CompositeInterrupt`. A tools node raises one for the
/// tool calls that interrupted; a lambda or a tool that runs a compiled graph
/// raises one for the [GraphInterruptedException] of that graph:
///
/// ```dart
/// try {
///   return await inner.invoke(ctx, input, options: [CallOption.checkpointId(id)]);
/// } on GraphInterruptedException catch (interrupted) {
///   throw compositeInterrupt(ctx, null, null, [interrupted]);
/// }
/// ```
///
/// [subErrors] are what the parts threw: signals made by [interrupt],
/// [statefulInterrupt] or this function, and [GraphInterruptedException]s,
/// each also when wrapped as the cause of another exception. [state] is saved
/// for this component, as with [statefulInterrupt]; [info] is reported for
/// it. Without sub errors this is [statefulInterrupt].
///
/// Throws [ArgumentError] when one of [subErrors] is not an interrupt.
InterruptSignal compositeInterrupt(
  RunContext ctx,
  Object? info,
  Object? state,
  List<Object> subErrors,
) {
  if (subErrors.isEmpty) return statefulInterrupt(ctx, info, state);

  final subs = <AddressedInterruptSignal>[];
  for (final error in subErrors) {
    final signal = ThreepioException.findCause<AddressedInterruptSignal>(error);
    if (signal != null) {
      subs.add(signal);
      continue;
    }
    final interrupted =
        ThreepioException.findCause<GraphInterruptedException>(error);
    if (interrupted != null) {
      final rebuilt = fromInterruptContexts(interrupted.info.interruptContexts);
      if (rebuilt != null) subs.add(rebuilt);
      continue;
    }
    throw ArgumentError.value(
      error,
      'subErrors',
      'composite interrupt but one of the sub error is not an interrupt',
    );
  }
  return newInterruptSignal(ctx, info, state, subs);
}

/// One point at which a run was interrupted, as the caller sees it.
///
/// Port of eino `compose.InterruptCtx`. [id] is what the caller passes to
/// `ctx.resume` or `ctx.resumeWithData` to continue this point.
@immutable
final class InterruptCtx {
  /// The interrupt point [id] at [address].
  const InterruptCtx({
    required this.id,
    required this.address,
    this.info,
    this.isRootCause = false,
    this.parent,
  });

  /// An interrupt point from its JSON form.
  factory InterruptCtx.fromJson(Map<String, Object?> json) => InterruptCtx(
        id: json['id']! as String,
        address: Address.fromJson(json['address']! as List<Object?>),
        info: TypeRegistry.decode(json['info']),
        isRootCause: json['is_root_cause'] as bool? ?? false,
        parent: json['parent'] == null
            ? null
            : InterruptCtx.fromJson(json['parent']! as Map<String, Object?>),
      );

  /// Identifies the point for `ctx.resume` and `ctx.resumeWithData`.
  final String id;

  /// Where the run was interrupted.
  final Address address;

  /// What the component that interrupted tells the caller.
  final Object? info;

  /// Whether the component at [address] asked for the pause itself. The
  /// points a [GraphInterruptedException] lists are all root causes; their
  /// [parent]s are the components around them.
  final bool isRootCause;

  /// The point of the component around this one, up to the graph that was
  /// called.
  final InterruptCtx? parent;

  static const _equality = DeepCollectionEquality();

  /// Whether [other] is the same point but for its [id]: same address, same
  /// info, same root-cause flag, and parents that are equal in the same way.
  ///
  /// Port of eino `InterruptCtx.EqualsWithoutID`. The infos are compared
  /// with `==`, lists and maps element by element (Go compares the fields of
  /// any two values by reflection): an info of a class of your own needs an
  /// `==` to be equal to another instance.
  bool equalsWithoutId(InterruptCtx? other) {
    if (other == null) return false;
    if (address != other.address) return false;
    if (isRootCause != other.isRootCause) return false;
    if (!_equality.equals(info, other.info)) return false;
    final ownParent = parent;
    final otherParent = other.parent;
    if (ownParent == null || otherParent == null) {
      return ownParent == null && otherParent == null;
    }
    return ownParent.equalsWithoutId(otherParent);
  }

  /// The JSON form of the point. An [info] that is neither JSON nor of a
  /// registered type is written as its `toString()`.
  Map<String, Object?> toJson() => {
        'id': id,
        'address': address.toJson(),
        if (info != null) 'info': encodeOrDescribe(info, 'InterruptCtx.info'),
        if (isRootCause) 'is_root_cause': true,
        if (parent != null) 'parent': parent!.toJson(),
      };

  @override
  String toString() => 'InterruptCtx(id: $id, address: $address, '
      'info: $info, isRootCause: $isRootCause)';
}

/// [value] in its checkpoint form, or its `toString()` when it has none.
///
/// What a caller is told about an interrupt is for display. A value that
/// cannot be encoded does not fail the checkpoint; it is logged and kept as
/// text.
@internal
Object? encodeOrDescribe(Object? value, String what) {
  try {
    return TypeRegistry.encode(value);
    // An unencodable value is reported by the registry as an ArgumentError.
    // ignore: avoid_catching_errors
  } on ArgumentError {
    _log.warning(
      '$what of type ${value.runtimeType} is not registered with '
      'TypeRegistry; it is stored as text',
    );
    return value.toString();
  }
}

/// What a graph reports when it was interrupted.
///
/// Port of eino `compose.InterruptInfo` (the ADK has an interrupt info of its
/// own, hence the name).
@immutable
final class GraphInterruptInfo {
  /// The description of an interrupted run.
  GraphInterruptInfo({
    this.state,
    List<String> beforeNodes = const [],
    List<String> afterNodes = const [],
    List<String> rerunNodes = const [],
    Map<String, Object?> rerunNodesExtra = const {},
    Map<String, GraphInterruptInfo> subGraphs = const {},
    List<InterruptCtx> interruptContexts = const [],
  })  : beforeNodes = List.unmodifiable(beforeNodes),
        afterNodes = List.unmodifiable(afterNodes),
        rerunNodes = List.unmodifiable(rerunNodes),
        rerunNodesExtra = Map.unmodifiable(rerunNodesExtra),
        subGraphs = Map.unmodifiable(subGraphs),
        interruptContexts = List.unmodifiable(interruptContexts);

  /// An interrupt info from its JSON form.
  factory GraphInterruptInfo.fromJson(Map<String, Object?> json) {
    ensureComposeTypesRegistered();
    List<String> strings(String key) =>
        (json[key] as List<Object?>? ?? const []).cast<String>();
    return GraphInterruptInfo(
      state: TypeRegistry.decode(json['state']),
      beforeNodes: strings('before_nodes'),
      afterNodes: strings('after_nodes'),
      rerunNodes: strings('rerun_nodes'),
      rerunNodesExtra: {
        for (final MapEntry(:key, :value)
            in (json['rerun_nodes_extra'] as Map<String, Object?>? ?? const {})
                .entries)
          key: TypeRegistry.decode(value),
      },
      subGraphs: {
        for (final MapEntry(:key, :value)
            in (json['sub_graphs'] as Map<String, Object?>? ?? const {}).entries)
          key: GraphInterruptInfo.fromJson(value! as Map<String, Object?>),
      },
      interruptContexts: [
        for (final context
            in json['interrupt_contexts'] as List<Object?>? ?? const [])
          InterruptCtx.fromJson(context! as Map<String, Object?>),
      ],
    );
  }

  /// A copy of the state of the graph at the moment it was interrupted, when
  /// the graph has one.
  final Object? state;

  /// The nodes the run stopped in front of (see
  /// `GraphCompileOptions.interruptBeforeNodes`).
  final List<String> beforeNodes;

  /// The nodes the run stopped behind (see
  /// `GraphCompileOptions.interruptAfterNodes`).
  final List<String> afterNodes;

  /// The nodes that interrupted themselves, or were still running when the
  /// run was interrupted from outside. They run again when the run is
  /// resumed.
  final List<String> rerunNodes;

  /// By node key, the info a node of [rerunNodes] gave with its interrupt.
  final Map<String, Object?> rerunNodesExtra;

  /// By node key, the interrupt info of the nested graphs that were
  /// interrupted.
  final Map<String, GraphInterruptInfo> subGraphs;

  /// The points at which the run was interrupted: one for every root cause,
  /// each with its chain of [InterruptCtx.parent]s. Their ids are what
  /// `ctx.resume` and `ctx.resumeWithData` take.
  final List<InterruptCtx> interruptContexts;

  /// The JSON form of the info. Values the caller is only shown ([state]
  /// excepted) are written as text when they are not registered.
  Map<String, Object?> toJson() {
    ensureComposeTypesRegistered();
    return {
      if (state != null) 'state': TypeRegistry.encode(state),
      'before_nodes': beforeNodes,
      'after_nodes': afterNodes,
      'rerun_nodes': rerunNodes,
      'rerun_nodes_extra': {
        for (final MapEntry(:key, :value) in rerunNodesExtra.entries)
          key: encodeOrDescribe(value, 'GraphInterruptInfo.rerunNodesExtra'),
      },
      'sub_graphs': {
        for (final MapEntry(:key, :value) in subGraphs.entries)
          key: value.toJson(),
      },
      'interrupt_contexts': [
        for (final context in interruptContexts) context.toJson(),
      ],
    };
  }

  @override
  String toString() => 'GraphInterruptInfo(state: $state, '
      'beforeNodes: $beforeNodes, afterNodes: $afterNodes, '
      'rerunNodes: $rerunNodes, rerunNodesExtra: $rerunNodesExtra, '
      'subGraphs: $subGraphs, interruptContexts: $interruptContexts)';
}

/// A run of a graph was interrupted.
///
/// Port of eino's `interruptError`. It is what `invoke`, `stream`, `collect`
/// and `transform` of a compiled graph throw when a node interrupted
/// ([interrupt]), when the run reached a node of
/// `GraphCompileOptions.interruptBeforeNodes` or `interruptAfterNodes`, or
/// when it was interrupted from outside (`ctx.withGraphInterrupt`).
///
/// This is not a failure. When the run was given a checkpoint id
/// (`CallOption.checkpointId`) and the graph has a checkpoint store, the run
/// can be continued by calling the graph again with the same id, on a context
/// that says which points to resume:
///
/// ```dart
/// try {
///   return await runnable.invoke(ctx, input, options: [CallOption.checkpointId('run-1')]);
/// } on GraphInterruptedException catch (interrupted) {
///   final point = interrupted.info.interruptContexts.first;
///   final answer = await askUser(point.info);
///   return runnable.invoke(
///     ctx.resumeWithData(point.id, answer),
///     input,
///     options: [CallOption.checkpointId('run-1')],
///   );
/// }
/// ```
///
/// It is an [InterruptSignal], so that code which catches errors lets it
/// through (`isInterrupt`). A component that runs a graph and wants the graph
/// around it to checkpoint as well wraps it with [compositeInterrupt].
final class GraphInterruptedException extends ThreepioException
    implements InterruptSignal {
  /// The interrupt described by [info].
  GraphInterruptedException(this.info)
      : super('interrupt happened, info: $info');

  /// Where and why the run stopped.
  final GraphInterruptInfo info;

  /// The points to resume; short for `info.interruptContexts`. Port of eino
  /// `GetInterruptContexts`.
  List<InterruptCtx> get interruptContexts => info.interruptContexts;

  @override
  String toString() => 'GraphInterruptedException: $message';
}

/// The interrupt of a graph that runs as a node of another graph: it carries
/// its checkpoint to the graph around it instead of storing it.
///
/// Port of eino `subGraphInterruptError`.
@internal
final class SubGraphInterrupt implements InterruptSignal {
  /// The interrupt of a nested graph.
  SubGraphInterrupt({
    required this.info,
    required this.checkpoint,
    required this.signal,
  });

  /// What the nested graph reports.
  final GraphInterruptInfo info;

  /// The checkpoint of the nested graph.
  final GraphCheckpoint checkpoint;

  /// The signal of the nested graph, with the signals of its nodes.
  final AddressedInterruptSignal signal;

  @override
  String toString() => 'interrupt happened, info: $info';
}

/// The interrupt info [error] carries, or `null` when it is not the interrupt
/// of a graph.
///
/// Port of eino `compose.ExtractInterruptInfo`. The interrupt is also found
/// when it is the cause of another exception.
GraphInterruptInfo? extractInterruptInfo(Object? error) {
  final interrupted =
      ThreepioException.findCause<GraphInterruptedException>(error);
  if (interrupted != null) return interrupted.info;
  return ThreepioException.findCause<SubGraphInterrupt>(error)?.info;
}

/// The signal tree that reports the given points.
///
/// Port of eino `core.FromInterruptContexts`. The points share their
/// ancestors; the root of the tree is the outermost parent.
@internal
AddressedInterruptSignal? fromInterruptContexts(List<InterruptCtx> contexts) {
  if (contexts.isEmpty) return null;

  final signals = <String, AddressedInterruptSignal>{};
  AddressedInterruptSignal? root;

  AddressedInterruptSignal? signalOf(InterruptCtx? context) {
    if (context == null) return null;
    final known = signals[context.id];
    if (known != null) return known;

    final signal = AddressedInterruptSignal(
      id: context.id,
      address: context.address,
      info: context.info,
      isRootCause: context.isRootCause,
    );
    signals[context.id] = signal;

    final parent = signalOf(context.parent);
    if (parent != null) {
      parent.subs.add(signal);
    } else {
      root = signal;
    }
    return signal;
  }

  contexts.forEach(signalOf);
  return root;
}

/// The points [signal] reports to a caller: its root causes, each with the
/// chain of its parents.
///
/// Port of eino `core.ToInterruptContexts`. With [allowedSegmentTypes], the
/// chain keeps only the parents whose last segment is of an allowed kind, and
/// every address only its segments of those kinds.
@internal
List<InterruptCtx> toInterruptContexts(
  AddressedInterruptSignal? signal, {
  List<AddressSegmentType> allowedSegmentTypes = const [],
}) {
  if (signal == null) return const [];
  final rootCauses = <InterruptCtx>[];

  void build(AddressedInterruptSignal current, InterruptCtx? parent) {
    final context = InterruptCtx(
      id: current.id,
      address: current.address,
      info: current.info,
      isRootCause: current.isRootCause,
      parent: parent,
    );
    if (context.isRootCause) rootCauses.add(context);
    for (final sub in current.subs) {
      build(sub, context);
    }
  }

  build(signal, null);

  if (allowedSegmentTypes.isEmpty) return rootCauses;

  // Parents are shared between the points below them; each is rebuilt once.
  final allowed = allowedSegmentTypes.toSet();
  final rebuilt = Map<InterruptCtx, InterruptCtx>.identity();
  InterruptCtx filtered(InterruptCtx context) {
    final known = rebuilt[context];
    if (known != null) return known;
    var parent = context.parent;
    while (parent != null &&
        !(parent.address.segments.isNotEmpty &&
            allowed.contains(parent.address.segments.last.type))) {
      parent = parent.parent;
    }
    return rebuilt[context] = InterruptCtx(
      id: context.id,
      address: Address(
        context.address.segments
            .where((segment) => allowed.contains(segment.type)),
      ),
      info: context.info,
      isRootCause: context.isRootCause,
      parent: parent == null ? null : filtered(parent),
    );
  }

  return [for (final context in rootCauses) filtered(context)];
}

/// The addresses and saved states of [signal] and every signal inside it, by
/// interrupt id: what a checkpoint keeps of an interrupt.
///
/// Port of eino `core.SignalToPersistenceMaps`.
@internal
(Map<String, Address>, Map<String, InterruptState>) signalToPersistenceMaps(
  AddressedInterruptSignal? signal,
) {
  final addresses = <String, Address>{};
  final states = <String, InterruptState>{};

  void traverse(AddressedInterruptSignal current) {
    addresses[current.id] = current.address;
    states[current.id] = current.state;
    current.subs.forEach(traverse);
  }

  if (signal != null) traverse(signal);
  return (addresses, states);
}
