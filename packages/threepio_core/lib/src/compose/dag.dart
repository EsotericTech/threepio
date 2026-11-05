/// The channel of a graph that runs as a directed acyclic graph: a node runs
/// when all of its predecessors have finished or were skipped.
///
/// Port of eino `compose/dag.go`.
@internal
library;

import 'package:meta/meta.dart';

import '../streaming/stream_reader.dart';
import 'channel_manager.dart';
import 'graph_options.dart';
import 'type_ref.dart';
import 'values_merge.dart';

/// Builds a [DagChannel]. Port of eino `dagChannelBuilder`.
Channel dagChannelBuilder({
  required List<String> controlDependencies,
  required List<String> dataDependencies,
  required Object? Function() zeroValue,
  required StreamReader<Object?> Function() emptyStream,
  required TypeRef<Object?>? inputType,
}) =>
    DagChannel(
      inputType: inputType,
      controlPredecessors: {
        for (final dependency in controlDependencies)
          dependency: DependencyState.waiting,
      },
      dataPredecessors: {
        for (final dependency in dataDependencies) dependency: false,
      },
      zeroValue: zeroValue,
      emptyStream: emptyStream,
    );

/// What a node knows about a predecessor it waits for. Port of eino
/// `dependencyState`.
enum DependencyState {
  /// The predecessor has not finished.
  waiting,

  /// The predecessor has finished.
  ready,

  /// The predecessor will not run.
  skipped,
}

/// Port of eino `dagChannel`.
final class DagChannel implements Channel {
  /// The channel of a node with the given predecessors.
  DagChannel({
    required this.controlPredecessors,
    required this.dataPredecessors,
    required this.zeroValue,
    required this.emptyStream,
    this.inputType,
  });

  /// The type the node of this channel takes, when it is known.
  final TypeRef<Object?>? inputType;

  /// The input of a node that has no data predecessor.
  final Object? Function() zeroValue;

  /// The stream input of a node that has no data predecessor.
  final StreamReader<Object?> Function() emptyStream;

  /// The state of each predecessor the node waits for.
  Map<String, DependencyState> controlPredecessors;

  /// The values that arrived, by source.
  Map<String, Object?> values = {};

  /// For each predecessor the node gets data from, whether it has arrived (or
  /// will never arrive).
  Map<String, bool> dataPredecessors;

  /// Whether the node will not run.
  bool skipped = false;

  FanInMergeConfig _mergeConfig = const FanInMergeConfig();

  @override
  set mergeConfig(FanInMergeConfig config) => _mergeConfig = config;

  @override
  void reportValues(Map<String, Object?> values) {
    if (skipped) return;
    for (final MapEntry(:key, :value) in values.entries) {
      if (!dataPredecessors.containsKey(key)) continue;
      dataPredecessors[key] = true;
      this.values[key] = value;
    }
  }

  @override
  void reportDependencies(List<String> dependencies) {
    if (skipped) return;
    for (final dependency in dependencies) {
      if (controlPredecessors.containsKey(dependency)) {
        controlPredecessors[dependency] = DependencyState.ready;
      }
    }
  }

  @override
  bool reportSkip(List<String> keys) {
    for (final key in keys) {
      if (controlPredecessors.containsKey(key)) {
        controlPredecessors[key] = DependencyState.skipped;
      }
      if (dataPredecessors.containsKey(key)) dataPredecessors[key] = true;
    }
    return skipped = controlPredecessors.values
        .every((state) => state == DependencyState.skipped);
  }

  @override
  ({Object? value, bool ready}) get({
    required bool isStream,
    required String name,
    required EdgeHandlerManager edgeHandlers,
  }) {
    const notReady = (value: null, ready: false);
    if (skipped) return notReady;
    if (controlPredecessors.isEmpty && dataPredecessors.isEmpty) {
      return notReady;
    }
    if (controlPredecessors.values.contains(DependencyState.waiting)) {
      return notReady;
    }
    if (dataPredecessors.values.contains(false)) return notReady;

    final arrived = values;
    values = {};
    controlPredecessors.updateAll((_, __) => DependencyState.waiting);
    dataPredecessors.updateAll((_, __) => false);

    final names = arrived.keys.toList();
    final resolved = [
      for (final MapEntry(key: from, :value) in arrived.entries)
        edgeHandlers.handle(from, name, value, isStream: isStream),
    ];

    if (resolved.isEmpty) {
      return (value: isStream ? emptyStream() : zeroValue(), ready: true);
    }
    if (resolved.length == 1) return (value: resolved.single, ready: true);

    return (
      value: mergeValues(
        resolved,
        streamMergeWithSourceEof: _mergeConfig.streamMergeWithSourceEof,
        names: names,
        expected: isStream ? null : inputType,
      ),
      ready: true,
    );
  }
}
