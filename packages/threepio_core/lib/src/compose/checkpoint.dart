/// Checkpoints: what an interrupted run keeps in order to go on later.
///
/// Port of eino `compose/checkpoint.go`. The store and serializer contracts
/// are in `checkpoint_store.dart`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/interrupt_signal.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../schema/message.dart';
import '../schema/type_registry.dart';
import '../streaming/stream_reader.dart';
import 'address.dart';
import 'call_options.dart';
import 'channel_manager.dart';
import 'checkpoint_serializer.dart';
import 'checkpoint_store.dart';
import 'errors.dart';
import 'interrupt.dart';
import 'resume.dart';
import 'type_ref.dart';

/// The saved state of one interrupted run of one graph.
///
/// Port of eino `checkpoint`. It is not the `Checkpoint` of the older state
/// graph, which is unrelated.
@internal
final class GraphCheckpoint {
  /// A checkpoint with the given parts.
  GraphCheckpoint({
    Map<String, Channel>? channels,
    Map<String, Object?>? inputs,
    this.state,
    Map<String, bool>? skipPreHandler,
    List<String>? rerunNodes,
    Map<String, GraphCheckpoint>? subGraphs,
    Map<String, Address>? interruptId2Address,
    Map<String, InterruptState>? interruptId2State,
  })  : channels = channels ?? {},
        inputs = inputs ?? {},
        skipPreHandler = skipPreHandler ?? {},
        rerunNodes = rerunNodes ?? [],
        subGraphs = subGraphs ?? {},
        interruptId2Address = interruptId2Address ?? {},
        interruptId2State = interruptId2State ?? {};

  /// A checkpoint from its JSON form.
  factory GraphCheckpoint.fromJson(Map<String, Object?> json) {
    Map<String, Object?> map(String key) =>
        json[key] as Map<String, Object?>? ?? const {};
    return GraphCheckpoint(
      channels: {
        for (final MapEntry(:key, :value) in map('channels').entries)
          key: TypeRegistry.decode(value)! as Channel,
      },
      inputs: {
        for (final MapEntry(:key, :value) in map('inputs').entries)
          key: TypeRegistry.decode(value),
      },
      state: TypeRegistry.decode(json['state']),
      skipPreHandler: map('skip_pre_handler').cast<String, bool>(),
      rerunNodes:
          (json['rerun_nodes'] as List<Object?>? ?? const []).cast<String>(),
      subGraphs: {
        for (final MapEntry(:key, :value) in map('sub_graphs').entries)
          key: GraphCheckpoint.fromJson(value! as Map<String, Object?>),
      },
      interruptId2Address: {
        for (final MapEntry(:key, :value) in map('interrupt_id2addr').entries)
          key: Address.fromJson(value! as List<Object?>),
      },
      interruptId2State: {
        for (final MapEntry(:key, :value) in map('interrupt_id2state').entries)
          key: InterruptState.fromJson(value! as Map<String, Object?>),
      },
    );
  }

  /// The channels of the run with what had arrived in them, by node key.
  Map<String, Channel> channels;

  /// The inputs of the nodes that run first when the run goes on, by node
  /// key.
  Map<String, Object?> inputs;

  /// The state of the graph.
  Object? state;

  /// The nodes whose state handler in front of them has run already.
  Map<String, bool> skipPreHandler;

  /// The nodes that run again.
  List<String> rerunNodes;

  /// The checkpoints of the nested graphs that were interrupted, by node key.
  Map<String, GraphCheckpoint> subGraphs;

  /// Where each interrupt was raised, by interrupt id.
  Map<String, Address> interruptId2Address;

  /// What each interrupt saved, by interrupt id.
  Map<String, InterruptState> interruptId2State;

  /// The JSON form of the checkpoint. Every value in it (inputs, what waits
  /// in channels, states) must be JSON or of a registered type.
  Map<String, Object?> toJson() => {
        'channels': {
          for (final MapEntry(:key, :value) in channels.entries)
            key: TypeRegistry.encode(value),
        },
        'inputs': {
          for (final MapEntry(:key, :value) in inputs.entries)
            key: _encode(value, 'the input of node[$key]'),
        },
        if (state != null) 'state': _encode(state, 'the state of the graph'),
        'skip_pre_handler': skipPreHandler,
        'rerun_nodes': rerunNodes,
        'sub_graphs': {
          for (final MapEntry(:key, :value) in subGraphs.entries)
            key: value.toJson(),
        },
        'interrupt_id2addr': {
          for (final MapEntry(:key, :value) in interruptId2Address.entries)
            key: value.toJson(),
        },
        'interrupt_id2state': {
          for (final MapEntry(:key, :value) in interruptId2State.entries)
            key: value.toJson(),
        },
      };
}

Object? _encode(Object? value, String what) {
  try {
    return TypeRegistry.encode(value);
    // The registry reports a value it cannot encode as an ArgumentError; said
    // again here with the place of the value.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (error) {
    throw CheckpointEncodeException(
      '$what cannot be written to a checkpoint: ${error.message}',
    );
  }
}

/// The checkpoint a graph was handed for this run, if any.
///
/// A holder, because "no checkpoint for you" has to be said as well: a node
/// of a resumed graph must not find the checkpoint of the graph around it.
final class _CheckpointSlot {
  const _CheckpointSlot(this.checkpoint);
  final GraphCheckpoint? checkpoint;
}

final _checkpointKey = ContextKey<_CheckpointSlot>('compose.checkpoint');
/// The state modifier of a resumed run. A holder, because "none" replaces
/// the modifier of a run around this one.
final class _StateModifierSlot {
  const _StateModifierSlot(this.modifier);
  final StateModifier? modifier;
}

final _stateModifierKey =
    ContextKey<_StateModifierSlot>('compose.stateModifier');

/// The state modifier of the resumed run. Port of eino `getStateModifier`.
@internal
StateModifier? stateModifierOf(RunContext ctx) =>
    ctx.value(_stateModifierKey)?.modifier;

/// [ctx] for a run that is resumed with [modifier], or with none: the
/// modifier of a run around it (a graph that a node of a resumed graph runs)
/// does not reach in.
///
/// Port of eino `setStateModifier`.
@internal
RunContext withStateModifier(RunContext ctx, StateModifier? modifier) =>
    ctx.withValue(_stateModifierKey, _StateModifierSlot(modifier));

/// [ctx] for the run that goes on from [checkpoint].
///
/// Port of eino `setCheckPointToCtx`.
@internal
RunContext withCheckpoint(RunContext ctx, GraphCheckpoint checkpoint) =>
    populateInterruptState(
      ctx,
      checkpoint.interruptId2Address,
      checkpoint.interruptId2State,
    ).withValue(_checkpointKey, _CheckpointSlot(checkpoint));

/// The checkpoint the graph that runs under [ctx] goes on from.
///
/// Port of eino `getCheckPointFromCtx`.
@internal
GraphCheckpoint? checkpointOf(RunContext ctx) =>
    ctx.value(_checkpointKey)?.checkpoint;

/// [ctx] for the node [nodeKey] of a resumed graph: it carries the checkpoint
/// of that node when the node is a nested graph that was interrupted, and no
/// checkpoint otherwise.
///
/// Port of eino `forwardCheckPoint`.
@internal
RunContext forwardCheckpoint(RunContext ctx, String nodeKey) {
  final checkpoint = checkpointOf(ctx);
  if (checkpoint == null) return ctx;
  // Handed on once: a node that runs again later starts anew.
  final nested = checkpoint.subGraphs.remove(nodeKey);
  return ctx.withValue(_checkpointKey, _CheckpointSlot(nested));
}

/// What to do about an error found in a stream while a checkpoint reads the
/// stream to its end.
///
/// Port of eino `streamErrorAction`.
@internal
typedef StreamErrorAction = ({bool ignore, bool dropValue});

/// Decides about an error in the stream that waits under [key].
@internal
typedef StreamErrorHandler = StreamErrorAction Function(String key, Object error);

/// Reads and writes the checkpoints of one compiled graph.
///
/// Port of eino `checkPointer` and `streamConverter`.
@internal
final class CheckPointer {
  /// The checkpointer of a graph whose nodes take [inputTypes] and give
  /// [outputTypes], by node key.
  CheckPointer({
    required this.inputTypes,
    required this.outputTypes,
    this.store,
    CheckpointSerializer? serializer,
  }) : serializer = serializer ?? const JsonCheckpointSerializer();

  /// By node key (and for the end of the graph), the type the node takes.
  final Map<String, TypeRef<Object?>?> inputTypes;

  /// By node key (and for the start of the graph), the type the node gives.
  final Map<String, TypeRef<Object?>?> outputTypes;

  /// Where checkpoints are kept.
  final CheckpointStore? store;

  /// How a checkpoint becomes bytes.
  final CheckpointSerializer serializer;

  /// The checkpoint stored under [id], or `null`.
  Future<GraphCheckpoint?> get(String id) async {
    final bytes = await store!.get(id);
    if (bytes == null) return null;
    final checkpoint = serializer.deserialize(bytes);
    if (checkpoint is! GraphCheckpoint) {
      throw GraphRunException(
        'the checkpoint serializer returned a ${checkpoint.runtimeType} '
        'instead of the checkpoint it was given',
      );
    }
    return checkpoint;
  }

  /// Stores [checkpoint] under [id].
  Future<void> set(String id, GraphCheckpoint checkpoint) async =>
      store!.set(id, serializer.serialize(checkpoint));

  /// Gives the values of a checkpoint that was rebuilt from bytes the types
  /// the graph expects, where a list or a map came back wider than it was
  /// (a `List<String>` as a `List<Object?>`).
  ///
  /// Every graph does this for its own checkpoint when it goes on from it:
  /// the checkpoint of a nested graph is read with the one around it, by a
  /// graph that does not know the types of the nested nodes.
  void revive(GraphCheckpoint checkpoint) {
    for (final channel in checkpoint.channels.values) {
      final values = channel.values;
      for (final key in values.keys.toList()) {
        final type = outputTypes[key];
        if (type != null) values[key] = type.revive(values[key]);
      }
    }
    final inputs = checkpoint.inputs;
    for (final key in inputs.keys.toList()) {
      final type = inputTypes[key];
      if (type != null) inputs[key] = type.revive(inputs[key]);
    }
  }

  /// Turns the streams of [checkpoint] into values, so that it can be
  /// stored.
  ///
  /// Port of eino `checkPointer.convertCheckPoint`. In a streaming run the
  /// inputs of the next nodes and what waits in channels are streams; each is
  /// read to its end and its chunks are joined.
  Future<void> convertCheckpoint(
    GraphCheckpoint checkpoint,
    AddressedInterruptSignal? interrupt, {
    required bool isStream,
  }) async {
    if (!isStream) return;
    final toolRerunInputs = <String, Message>{};
    StreamErrorAction handle(String key, Object error) {
      final toolStream =
          ThreepioException.findCause<ToolStreamCheckpointSignal>(error);
      if (toolStream != null) {
        _applyToolStreamCheckpoint(checkpoint, key, interrupt, toolStream);
        final nodeKey = toolStream.nodeKey;
        if (nodeKey.isNotEmpty) toolRerunInputs[nodeKey] = toolStream.input;
        return (ignore: true, dropValue: true);
      }
      // The checkpoint already lists this interrupt. A copy of the stream it
      // travelled in may show it again while it is read here.
      return (ignore: _containsInterrupt(checkpoint, error), dropValue: false);
    }

    for (final channel in checkpoint.channels.values) {
      await _convert(channel.values, outputTypes, handle);
    }
    await _convert(checkpoint.inputs, inputTypes, handle);
    checkpoint.inputs.addAll(toolRerunInputs);
  }

  /// Turns the values of [checkpoint] into streams again, for a streaming
  /// run that goes on from it.
  ///
  /// Port of eino `checkPointer.restoreCheckPoint`.
  void restoreCheckpoint(GraphCheckpoint checkpoint, {required bool isStream}) {
    if (!isStream) return;
    for (final channel in checkpoint.channels.values) {
      _restore(channel.values, outputTypes);
    }
    _restore(checkpoint.inputs, inputTypes);
  }

  static Future<void> _convert(
    Map<String, Object?> values,
    Map<String, TypeRef<Object?>?> types,
    StreamErrorHandler handleError,
  ) async {
    for (final key in values.keys.toList()) {
      if (!types.containsKey(key)) {
        throw GraphRunException(
          'checkpoint conv stream fail, node[$key] have not been registered',
        );
      }
      final type = types[key];
      if (type == null) {
        throw GraphRunException(
          'checkpoint conv stream fail, node[$key] has no stream converter',
        );
      }
      final value = values[key];
      if (value is! StreamReader<Object?>) {
        throw GraphRunException(
          "checkpoint conv stream fail, value of [$key] isn't stream",
        );
      }
      var action = (ignore: false, dropValue: false);
      final joined = await type.concatStream(value, (error) {
        action = handleError(key, error);
        return action.ignore;
      });
      if (action.dropValue) {
        values.remove(key);
      } else {
        values[key] = joined;
      }
    }
  }

  static void _restore(
    Map<String, Object?> values,
    Map<String, TypeRef<Object?>?> types,
  ) {
    for (final key in values.keys.toList()) {
      if (!types.containsKey(key)) {
        throw GraphRunException(
          'checkpoint restore stream fail, node[$key] have not been '
          'registered',
        );
      }
      final type = types[key];
      if (type == null) {
        throw GraphRunException(
          'checkpoint restore stream fail, node[$key] has no stream converter',
        );
      }
      values[key] = type.restoreStream(values[key]);
    }
  }

  /// Port of eino `checkpointContainsInterrupt`.
  static bool _containsInterrupt(GraphCheckpoint checkpoint, Object error) {
    final signal = ThreepioException.findCause<AddressedInterruptSignal>(error);
    if (signal != null) {
      return checkpoint.interruptId2Address.containsKey(signal.id);
    }
    final nested = ThreepioException.findCause<SubGraphInterrupt>(error);
    return nested != null &&
        checkpoint.interruptId2Address.containsKey(nested.signal.id);
  }

  /// Port of eino `applyToolStreamCheckpoint`.
  static void _applyToolStreamCheckpoint(
    GraphCheckpoint checkpoint,
    String inputKey,
    AddressedInterruptSignal? interrupt,
    ToolStreamCheckpointSignal streamError,
  ) {
    checkpoint.rerunNodes.removeWhere((key) => key == inputKey);
    final nodeKey = streamError.nodeKey;
    if (nodeKey.isNotEmpty && !checkpoint.rerunNodes.contains(nodeKey)) {
      checkpoint.rerunNodes.add(nodeKey);
    }
    if (interrupt != null) {
      _appendSignalIfMissing(interrupt, streamError.signal);
      final (addresses, states) = signalToPersistenceMaps(interrupt);
      checkpoint
        ..interruptId2Address = addresses
        ..interruptId2State = states;
    }
  }

  static void _appendSignalIfMissing(
    AddressedInterruptSignal root,
    AddressedInterruptSignal signal,
  ) {
    bool contains(AddressedInterruptSignal current) =>
        identical(current, signal) ||
        (signal.id.isNotEmpty && current.id == signal.id) ||
        current.subs.any(contains);
    if (!contains(root)) root.subs.add(signal);
  }
}

/// The interrupt of a tools node whose streamed tool results were cut off
/// before they were complete: it reaches the checkpoint through the stream of
/// the node.
///
/// Port of eino `toolStreamCheckpointError`.
@internal
final class ToolStreamCheckpointSignal extends ThreepioException
    implements InterruptSignal {
  /// The interrupt of the tools node [nodeKey] that was given [input].
  ToolStreamCheckpointSignal({
    required this.nodeKey,
    required this.input,
    required this.signal,
  }) : super(signal.toString(), cause: signal);

  /// The key of the tools node, or the empty string when the node runs
  /// outside a graph.
  final String nodeKey;

  /// The message whose tool calls the node ran.
  final Message input;

  /// The composite interrupt of the node.
  final AddressedInterruptSignal signal;
}

/// Applies [migrate] to the state in the checkpoint [data] and to the states
/// of the checkpoints of nested graphs inside it, and returns the bytes of
/// the result.
///
/// Port of eino `compose.MigrateCheckpointState`. It is a tool for upgrades:
/// when the state type of a graph changed, checkpoints written with the old
/// type are rewritten before they are resumed.
///
/// [migrate] gets each state that is not `null` and returns the new state and
/// whether it changed anything. When no state was changed, [data] itself is
/// returned. What [migrate] throws ends the migration and reaches the caller.
///
/// [serializer] must be the one the graph is compiled with (a
/// [JsonCheckpointSerializer] unless another was given), and the types in the
/// checkpoint must be registered with [TypeRegistry] as for a resume.
Future<Uint8List> migrateCheckpointState(
  Uint8List data,
  CheckpointSerializer serializer,
  FutureOr<({Object? state, bool changed})> Function(Object? state) migrate,
) async {
  final checkpoint = serializer.deserialize(data);
  if (checkpoint is! GraphCheckpoint) {
    throw ArgumentError.value(
      data,
      'data',
      'is not a checkpoint of a graph (the serializer returned a '
          '${checkpoint.runtimeType})',
    );
  }
  final changed = await _migrate(checkpoint, migrate);
  return changed ? serializer.serialize(checkpoint) : data;
}

Future<bool> _migrate(
  GraphCheckpoint checkpoint,
  FutureOr<({Object? state, bool changed})> Function(Object? state) migrate,
) async {
  var anyChanged = false;
  if (checkpoint.state != null) {
    final result = await migrate(checkpoint.state);
    if (result.changed) {
      checkpoint.state = result.state;
      anyChanged = true;
    }
  }
  for (final nested in checkpoint.subGraphs.values) {
    if (await _migrate(nested, migrate)) anyChanged = true;
  }
  return anyChanged;
}
