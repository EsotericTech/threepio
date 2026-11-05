/// Merging the values that arrive at a node with several predecessors.
///
/// Port of eino `compose/values_merge.go` and `internal/merge.go`.
library;

import 'package:meta/meta.dart';

import '../streaming/stream_reader.dart';
import 'errors.dart';
import 'type_ref.dart';

final class _MergeEntry<T extends Object> {
  _MergeEntry(this.merge);

  final T Function(List<T> values) merge;

  bool matches(Object? value) => value is T;

  bool matchesStream(Object? value) => value is StreamReader<T>;

  Object mergeValues(List<Object?> values) => merge(List<T>.from(values));

  StreamReader<Object?> mergeStreams(
    List<Object?> streams,
    List<String>? names,
  ) =>
      _mergeStreams<T>(streams, names);

  String get typeName => '$T';
}

/// The functions that merge the outputs of several nodes into the input of
/// the node they all lead to (fan-in).
///
/// Port of eino `compose.RegisterValuesMergeFunc`. Without a registration,
/// maps are merged: the result has the entries of all of them, and a key that
/// occurs twice is an error. That is what nodes with an output key and the
/// branches of a `Parallel` produce. Any other type that fans in needs a
/// function here.
///
/// A function is found by asking whether the values are of its type, most
/// recent registration first, so a later registration overrides an earlier
/// one and a subtype can be registered after its supertype.
///
/// The default merge gives a `Map<String, Object?>`. A node that takes a
/// narrower map type (`Map<String, int>`) behind a fan-in needs a function
/// registered for that type.
///
/// This is process-wide state; tests that register call [reset].
abstract final class ValuesMerge {
  static final List<_MergeEntry<Object>> _entries = [];

  /// Registers [merge] for values of type [T].
  static void register<T extends Object>(T Function(List<T> values) merge) =>
      _entries.add(_MergeEntry<T>(merge));

  /// Forgets every registration.
  @visibleForTesting
  static void reset() => _entries.clear();

  static _MergeEntry<Object>? _entryFor(Object? value) {
    for (final entry in _entries.reversed) {
      if (entry.matches(value)) return entry;
    }
    return null;
  }

  static _MergeEntry<Object>? _entryForStream(Object? stream) {
    for (final entry in _entries.reversed) {
      if (entry.matchesStream(stream)) return entry;
    }
    return null;
  }
}

/// Merges [values], the outputs of the predecessors of one node.
///
/// Port of eino `mergeValues`. Values are merged with the registered function
/// or as maps. Streams are merged into one stream that delivers the chunks of
/// all of them; that needs a chunk type which could be merged as a value,
/// because whoever joins the chunks later has to merge them. With
/// [streamMergeWithSourceEof] the merged stream reports the end of each
/// source under its name from [names].
///
/// [expected] is the type the receiving node takes. It only makes the error
/// clearer when the default merge of maps cannot produce that type.
///
/// Throws [ComposeTypeException] for values that cannot be merged.
@internal
Object? mergeValues(
  List<Object?> values, {
  bool streamMergeWithSourceEof = false,
  List<String> names = const [],
  TypeRef<Object?>? expected,
}) {
  final first = values.first;

  if (first is StreamReader<Object?>) {
    return _mergeStreamValues(
      values,
      streamMergeWithSourceEof ? names : null,
    );
  }

  final entry = ValuesMerge._entryFor(first);
  if (entry != null) {
    for (final value in values) {
      if (!entry.matches(value)) {
        throw ComposeTypeException(
          "(values merge) field type mismatch. expected: '${entry.typeName}', "
          "got: '${value.runtimeType}'",
        );
      }
    }
    return entry.mergeValues(values);
  }

  if (first is Map<Object?, Object?>) {
    final merged = _mergeMaps(values);
    if (expected != null && !expected.isInstance(merged)) {
      // Said here, where the reason is known, and not by the node that gets
      // a map of the wrong type.
      throw ComposeTypeException(
        '(values merge map) the default merge of maps gives a '
        '${merged.runtimeType}, which is not the ${expected.name} the '
        'receiving node takes; register a merge function for that type with '
        'ValuesMerge.register<${expected.name}>',
      );
    }
    return merged;
  }

  throw ComposeTypeException(
    '(mergeValues) unsupported type: ${first.runtimeType}',
  );
}

Object _mergeMaps(List<Object?> values) {
  for (final value in values) {
    if (value is! Map<Object?, Object?>) {
      throw ComposeTypeException(
        "(values merge map) field type mismatch. expected: 'Map', "
        "got: '${value.runtimeType}'",
      );
    }
  }
  final maps = values.cast<Map<Object?, Object?>>();

  void putAll(Map<Object?, Object?> merged) {
    for (final map in maps) {
      for (final MapEntry(:key, :value) in map.entries) {
        if (merged.containsKey(key)) {
          throw ComposeTypeException(
            "(values merge map) duplicated key ('$key') found",
          );
        }
        merged[key] = value;
      }
    }
  }

  if (maps.every((map) => map is Map<String, Object?>)) {
    final merged = <String, Object?>{};
    putAll(merged);
    return merged;
  }

  // Maps of another type have to agree on it: what the others hold must fit
  // the key and value type of the first. The lists carry those types.
  final keysOfFirst = maps.first.keys.toList();
  final valuesOfFirst = maps.first.values.toList();
  for (final map in maps.skip(1)) {
    for (final MapEntry(:key, :value) in map.entries) {
      if (!_fits(keysOfFirst, key) || !_fits(valuesOfFirst, value)) {
        throw ComposeTypeException(
          '(values merge map) field type mismatch. expected: '
          "'${maps.first.runtimeType}', got: '${map.runtimeType}'",
        );
      }
    }
  }
  final merged = <Object?, Object?>{};
  putAll(merged);
  return merged;
}

/// Whether [element] is of the element type of [typed], which this function
/// only knows as a list of anything.
bool _fits(List<Object?> typed, Object? element) {
  try {
    typed
      ..add(element)
      ..removeLast();
    return true;
    // The type error of adding the wrong thing to a typed list is the answer.
    // ignore: avoid_catching_errors
  } on TypeError {
    return false;
  }
}

StreamReader<Object?> _mergeStreamValues(
  List<Object?> values,
  List<String>? names,
) {
  final first = values.first;
  for (final value in values) {
    if (value is! StreamReader<Object?>) {
      throw ComposeTypeException(
        '(mergeStream) unexpected type. expect: ${first.runtimeType}, '
        'got: ${value.runtimeType}',
      );
    }
  }

  final entry = ValuesMerge._entryForStream(first);
  if (entry != null) {
    for (final value in values) {
      if (!entry.matchesStream(value)) {
        throw ComposeTypeException(
          '(mergeStream) chunk type mismatch. expect: ${entry.typeName}, '
          'got: ${value.runtimeType}',
        );
      }
    }
    return entry.mergeStreams(values, names);
  }

  if (first is! StreamReader<Map<Object?, Object?>>) {
    throw ComposeTypeException(
      '(mergeValues | stream type) unsupported chunk type: '
      '${first.runtimeType}',
    );
  }
  for (final value in values) {
    if (value is! StreamReader<Map<Object?, Object?>>) {
      throw ComposeTypeException(
        '(mergeStream) chunk type mismatch. expect: ${first.runtimeType}, '
        'got: ${value.runtimeType}',
      );
    }
  }
  if (values.every((value) => value is StreamReader<Map<String, Object?>>)) {
    return _mergeStreams<Map<String, Object?>>(values, names);
  }
  return _mergeStreams<Map<Object?, Object?>>(values, names);
}

StreamReader<T> _mergeStreams<T>(List<Object?> streams, List<String>? names) {
  final typed = streams.cast<StreamReader<T>>();
  if (names == null) return mergeStreamReaders<T>(typed);
  return mergeNamedStreamReaders<T>({
    for (final (index, stream) in typed.indexed) names[index]: stream,
  });
}
