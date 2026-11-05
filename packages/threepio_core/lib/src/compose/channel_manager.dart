/// The channels values travel through between the nodes of a running graph.
///
/// Port of the channel half of eino `compose/graph_manager.go`.
@internal
library;

import 'package:meta/meta.dart';

import '../core/interrupt_signal.dart';
import '../errors.dart';
import '../schema/type_registry.dart';
import '../streaming/stream_reader.dart';
import 'errors.dart';
import 'graph.dart';
import 'graph_options.dart';
import 'type_ref.dart';

/// Collects what the predecessors of one node give and says when the node can
/// run.
///
/// Port of eino `channel`.
abstract interface class Channel {
  /// What has arrived and waits for the node to run, by source node. A
  /// checkpoint reads and replaces these values (eino `convertValues`).
  Map<String, Object?> get values;

  /// Takes over what [saved], a channel read back from a checkpoint, holds.
  ///
  /// Port of eino `channel.load`. Throws [GraphRunException] when [saved] is
  /// a channel of another kind.
  void load(Channel saved);

  /// Takes the outputs of predecessors, by their node keys.
  void reportValues(Map<String, Object?> values);

  /// Notes that the given predecessors have finished.
  void reportDependencies(List<String> dependencies);

  /// Notes that the given predecessors will not run. Returns whether the node
  /// of this channel is thereby skipped as well.
  bool reportSkip(List<String> keys);

  /// The input for the node [name] when it is ready to run, after which the
  /// channel is empty again.
  ({Object? value, bool ready}) get({
    required bool isStream,
    required String name,
    required EdgeHandlerManager edgeHandlers,
  });

  /// How several incoming values are merged.
  // A channel is configured after it is built, like in Eino.
  // ignore: avoid_setters_without_getters
  set mergeConfig(FanInMergeConfig config);
}

/// The values that wait in a channel, in their checkpoint form.
Map<String, Object?> encodeChannelValues(Map<String, Object?> values) => {
      for (final MapEntry(:key, :value) in values.entries)
        key: _encodeValue(key, value),
    };

Object? _encodeValue(String from, Object? value) {
  try {
    return TypeRegistry.encode(value);
    // The registry reports a value it cannot encode as an ArgumentError; said
    // again here with where the value came from.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (error) {
    throw CheckpointEncodeException(
      'the output of node[$from] cannot be written to a checkpoint: '
      '${error.message}',
    );
  }
}

/// Builds the channel of a node from its predecessors.
///
/// Port of eino `chanBuilder`.
typedef ChannelBuilder = Channel Function({
  required List<String> controlDependencies,
  required List<String> dataDependencies,
  required Object? Function() zeroValue,
  required StreamReader<Object?> Function() emptyStream,
  required TypeRef<Object?>? inputType,
});

Object? _apply(List<HandlerPair>? handlers, Object? value, bool isStream) {
  if (handlers == null) return value;
  var current = value;
  for (final handler in handlers) {
    current = isStream
        ? handler.transform(current! as StreamReader<Object?>)
        : handler.invoke(current);
  }
  return current;
}

/// The conversions that run on edges.
///
/// Port of eino `edgeHandlerManager`.
final class EdgeHandlerManager {
  /// The manager of [handlers], by start node and end node.
  const EdgeHandlerManager(this.handlers);

  /// The handlers of each edge.
  final Map<String, Map<String, List<HandlerPair>>> handlers;

  /// [value] as the edge from [from] to [to] delivers it.
  Object? handle(String from, String to, Object? value, {required bool isStream}) =>
      _apply(handlers[from]?[to], value, isStream);
}

/// The conversions that run in front of a node, on its merged input.
///
/// Port of eino `preNodeHandlerManager`.
final class PreNodeHandlerManager {
  /// The manager of [handlers], by node.
  const PreNodeHandlerManager(this.handlers);

  /// The handlers of each node.
  final Map<String, List<HandlerPair>> handlers;

  /// [value] as the node [nodeKey] gets it.
  Object? handle(String nodeKey, Object? value, {required bool isStream}) =>
      _apply(handlers[nodeKey], value, isStream);
}

/// The conversions that run in front of the branches of a node.
///
/// Port of eino `preBranchHandlerManager`.
final class PreBranchHandlerManager {
  /// The manager of [handlers], by start node and branch index.
  const PreBranchHandlerManager(this.handlers);

  /// The handlers of each branch.
  final Map<String, List<List<HandlerPair>>> handlers;

  /// [value] as the branch number [index] of [nodeKey] gets it.
  Object? handle(
    String nodeKey,
    int index,
    Object? value, {
    required bool isStream,
  }) {
    final ofNode = handlers[nodeKey];
    if (ofNode == null) return value;
    return _apply(ofNode[index], value, isStream);
  }
}

/// The channels of one run.
///
/// Port of eino `channelManager`.
final class ChannelManager {
  /// The manager of [channels].
  ChannelManager({
    required this.isStream,
    required this.channels,
    required this.successors,
    required this.dataPredecessors,
    required this.controlPredecessors,
    required this.edgeHandlers,
    required this.preNodeHandlers,
  });

  /// Whether the run passes streams.
  final bool isStream;

  /// The channel of each node and of the end.
  final Map<String, Channel> channels;

  /// The nodes that follow each node.
  final Map<String, List<String>> successors;

  /// For each node, the nodes whose output it gets.
  final Map<String, Set<String>> dataPredecessors;

  /// For each node, the nodes it waits for.
  final Map<String, Set<String>> controlPredecessors;

  /// The conversions on edges.
  final EdgeHandlerManager edgeHandlers;

  /// The conversions in front of nodes.
  final PreNodeHandlerManager preNodeHandlers;

  /// Hands [values] (by target, then by source) to the channels of their
  /// targets. A value on an edge that carries no data is dropped.
  Future<void> updateValues(Map<String, Map<String, Object?>> values) async {
    for (final MapEntry(key: target, value: fromMap) in values.entries) {
      final channel = channels[target];
      if (channel == null) {
        throw GraphRunException("target channel doesn't existed: $target");
      }
      final predecessors = dataPredecessors[target] ?? const <String>{};
      final accepted = <String, Object?>{};
      for (final MapEntry(key: from, :value) in fromMap.entries) {
        if (predecessors.contains(from)) {
          accepted[from] = value;
        } else if (value is StreamReader<Object?>) {
          await value.close();
        }
      }
      channel.reportValues(accepted);
    }
  }

  /// Tells the channels of the targets in [dependencies] which of their
  /// predecessors have finished.
  void updateDependencies(Map<String, List<String>> dependencies) {
    for (final MapEntry(key: target, value: finished) in dependencies.entries) {
      final channel = channels[target];
      if (channel == null) {
        throw GraphRunException("target channel doesn't existed: $target");
      }
      final predecessors = controlPredecessors[target] ?? const <String>{};
      channel.reportDependencies(
        [
          for (final from in finished)
            if (predecessors.contains(from)) from,
        ],
      );
    }
  }

  /// Makes the channels take over what the channels of a checkpoint hold.
  ///
  /// Port of eino `channelManager.loadChannels`.
  void loadChannels(Map<String, Channel> saved) {
    for (final MapEntry(:key, value: channel) in channels.entries) {
      final savedChannel = saved[key];
      if (savedChannel == null) continue;
      try {
        channel.load(savedChannel);
      } on GraphRunException catch (error) {
        throw GraphRunException(
          'load channel[$key] fail: ${error.message}',
          cause: error,
        );
      }
    }
  }

  /// The inputs of the nodes that can run now, by node key.
  Map<String, Object?> getFromReadyChannels() {
    final result = <String, Object?>{};
    for (final MapEntry(key: target, value: channel) in channels.entries) {
      final ({Object? value, bool ready}) got;
      try {
        got = channel.get(
          isStream: isStream,
          name: target,
          edgeHandlers: edgeHandlers,
        );
        // Whatever a conversion or a merge function throws fails the run.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (isInterrupt(error)) rethrow;
        Error.throwWithStackTrace(
          GraphRunException(
            'get value from ready channel[$target] fail: '
            '${error is ThreepioException ? error.message : error}',
            cause: error,
          ),
          stackTrace,
        );
      }
      if (!got.ready) continue;
      result[target] =
          preNodeHandlers.handle(target, got.value, isStream: isStream);
    }
    return result;
  }

  /// [updateValues], [updateDependencies] and [getFromReadyChannels] in one.
  Future<Map<String, Object?>> updateAndGet(
    Map<String, Map<String, Object?>> values,
    Map<String, List<String>> dependencies,
  ) async {
    await updateValues(values);
    updateDependencies(dependencies);
    return getFromReadyChannels();
  }

  /// Notes that the branches of [from] did not choose [skippedNodes], and
  /// passes the skip on to the nodes that can no longer run because of it.
  void reportBranch(String from, List<String> skippedNodes) {
    final skipped = <String>[
      for (final node in skippedNodes)
        if (channels[node]!.reportSkip([from])) node,
    ];

    for (var i = 0; i < skipped.length; i++) {
      final key = skipped[i];
      if (key == Graph.end) continue;
      final next = successors[key];
      if (next == null) throw GraphRunException('unknown node: $key');
      for (final successor in next) {
        if (channels[successor]!.reportSkip([key]) &&
            !skipped.contains(successor)) {
          skipped.add(successor);
        }
      }
    }
  }
}
