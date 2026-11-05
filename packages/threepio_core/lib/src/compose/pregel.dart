/// The channel of a graph that runs in steps: a node runs as soon as any of
/// its predecessors has given a value.
///
/// Port of eino `compose/pregel.go`.
@internal
library;

import 'package:meta/meta.dart';

import '../schema/type_registry.dart';
import '../streaming/stream_reader.dart';
import 'channel_manager.dart';
import 'errors.dart';
import 'graph_options.dart';
import 'type_ref.dart';
import 'values_merge.dart';

/// Builds a [PregelChannel]. Port of eino `pregelChannelBuilder`.
Channel pregelChannelBuilder({
  required List<String> controlDependencies,
  required List<String> dataDependencies,
  required Object? Function() zeroValue,
  required StreamReader<Object?> Function() emptyStream,
  required TypeRef<Object?>? inputType,
}) =>
    PregelChannel(inputType: inputType);

/// Port of eino `pregelChannel`.
final class PregelChannel implements Channel {
  /// The channel of a node that takes [inputType].
  PregelChannel({this.inputType});

  /// A channel read back from a checkpoint: it only carries what was saved,
  /// for the channel of the running graph to take over ([load]).
  factory PregelChannel.fromJson(Map<String, Object?> json) => PregelChannel()
    ..values = {
      for (final MapEntry(:key, :value)
          in (json['values']! as Map<String, Object?>).entries)
        key: TypeRegistry.decode(value),
    };

  /// The type the node of this channel takes, when it is known.
  final TypeRef<Object?>? inputType;

  /// The values that arrived since the node last ran, by source.
  @override
  Map<String, Object?> values = {};

  @override
  void load(Channel saved) {
    if (saved is! PregelChannel) {
      throw GraphRunException(
        'load pregel channel fail, got ${saved.runtimeType}, want '
        'PregelChannel',
      );
    }
    values = saved.values;
  }

  /// What a checkpoint keeps of the channel. The values that wait must be
  /// JSON or of a registered type.
  Map<String, Object?> toJson() => {'values': encodeChannelValues(values)};

  FanInMergeConfig _mergeConfig = const FanInMergeConfig();

  @override
  set mergeConfig(FanInMergeConfig config) => _mergeConfig = config;

  @override
  void reportValues(Map<String, Object?> values) => this.values.addAll(values);

  @override
  void reportDependencies(List<String> dependencies) {}

  @override
  bool reportSkip(List<String> keys) => false;

  @override
  ({Object? value, bool ready}) get({
    required bool isStream,
    required String name,
    required EdgeHandlerManager edgeHandlers,
  }) {
    if (values.isEmpty) return (value: null, ready: false);
    final arrived = values;
    values = {};

    final names = arrived.keys.toList();
    final resolved = [
      for (final MapEntry(key: from, :value) in arrived.entries)
        edgeHandlers.handle(from, name, value, isStream: isStream),
    ];
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
