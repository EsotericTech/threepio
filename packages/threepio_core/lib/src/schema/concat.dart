/// Joining the chunks of a stream into one value: the [StreamConcat]
/// registry.
///
/// Port of eino `internal/concat.go`, which Go exposes as
/// `compose.RegisterStreamChunkConcatFunc`.
library;

import 'package:meta/meta.dart';

import '../internal/type_utils.dart';
import '../streaming/stream_reader.dart';
import 'agentic_message.dart';
import 'agentic_message_concat.dart';
import 'message.dart';
import 'message_concat.dart';
import 'tool_result.dart';

/// One registered concat function, with the type it was registered for.
///
/// The type lives in the closures of this object, never in a map key: the
/// runtime type of a value is usually a private class (`_Message`,
/// `_GrowableList`) that no registration could name.
final class _ConcatEntry<T extends Object> {
  _ConcatEntry(this.concat);

  final T Function(List<T> chunks) concat;

  /// Whether chunks declared as `S` can be given to [concat].
  bool accepts<S>() => isSubtype<S, T>();

  /// Whether every one of [values] can be given to [concat].
  bool matchesAll(List<Object?> values) => values.every((value) => value is T);

  Object concatValues(List<Object?> values) => concat(List<T>.from(values));

  String get typeName => '$T';
}

/// How the chunks of a stream become one value.
///
/// When a streaming component feeds one that takes a whole value, the chunks
/// have to be joined. This registry knows how, per type:
///
/// * `String`: the chunks are concatenated.
/// * `num`, `bool`, `DateTime`, `Duration`: the last chunk wins.
/// * `Map<String, Object?>`: merged key by key; the values of a key that
///   occurs in several chunks are concatenated in turn by these rules. The
///   result is a `Map<String, Object?>`, so a stream declared with a narrower
///   map type (`Map<String, String>`) needs a function of its own.
/// * [Message], `List<Message>` and [ToolResult]: [concatMessages],
///   [concatMessageArray] and [concatToolResults].
/// * [AgenticMessage] and `List<AgenticMessage>`: [concatAgenticMessages]
///   and [concatAgenticMessagesArray].
///
/// Anything else is added with [register]. For a type without a function,
/// chunks can only be joined when at most one of them carries a value (is not
/// `null`, empty, zero or `false`).
///
/// The registry is global to the isolate. A later registration is preferred
/// to an earlier one, so a function registered by an application replaces a
/// built-in one, and one for a subtype can follow one for its supertype.
abstract final class StreamConcat {
  static final List<_ConcatEntry<Object>> _entries = [];
  static bool _builtInsRegistered = false;

  /// Registers [concat] as the way to join chunks of type `T`.
  ///
  /// Port of eino `compose.RegisterStreamChunkConcatFunc`. [concat] is called
  /// with two or more chunks, in the order they were received.
  ///
  /// ```dart
  /// StreamConcat.register<Tally>(
  ///   (chunks) => Tally(chunks.fold(0, (sum, chunk) => sum + chunk.count)),
  /// );
  /// ```
  static void register<T extends Object>(T Function(List<T> chunks) concat) {
    _ensureBuiltIns();
    _entries.add(_ConcatEntry<T>(concat));
  }

  /// The function that joins chunks declared as `T`, or `null` when none was
  /// registered for `T` or a supertype of it.
  ///
  /// This is the lookup for a place that knows the chunk type statically, such
  /// as a graph node with a declared output type, and wants to resolve the
  /// function once. [concatItems] additionally looks at the values.
  static T Function(List<T> chunks)? resolve<T extends Object>() {
    final entry = _entryFor<T>();
    if (entry == null) return null;
    return (chunks) => _checked<T>(entry.concatValues(chunks), entry);
  }

  /// Joins [items] into one value.
  ///
  /// Port of eino `internal.ConcatItems`. A single item is returned as it is.
  /// Throws [ArgumentError] for an empty list and [StateError] when the items
  /// cannot be joined.
  static T concatItems<T extends Object>(List<T> items) {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'nothing to concat');
    }
    if (items.length == 1) return items.single;

    final entry = _entryFor<T>() ?? _entryForValues(items);
    if (entry != null) return _checked<T>(entry.concatValues(items), entry);

    final value = _onlyValue(items, '$T');
    return (value ?? items.first) as T;
  }

  /// Reads [stream] to its end, closes it, and joins what it delivered.
  ///
  /// Port of eino's `concatStreamReader`. An error in the stream is rethrown.
  /// Throws [StateError] when the stream had no items, or when its items
  /// cannot be joined.
  static Future<T> concat<T extends Object>(StreamReader<T> stream) async {
    final items = <T>[];
    try {
      for (var item = await stream.nextOrNull();
          item != null;
          item = await stream.nextOrNull()) {
        items.add(item);
      }
    } finally {
      await stream.close();
    }

    if (items.isEmpty) {
      throw StateError('stream reader is empty, concat failed');
    }
    return concatItems<T>(items);
  }

  /// Forgets every registration except the built-in ones.
  @visibleForTesting
  static void reset() {
    _entries.clear();
    _builtInsRegistered = false;
  }

  static void _ensureBuiltIns() {
    if (_builtInsRegistered) return;
    _builtInsRegistered = true;
    _entries.addAll([
      _ConcatEntry<bool>((chunks) => chunks.last),
      _ConcatEntry<num>((chunks) => chunks.last),
      _ConcatEntry<DateTime>((chunks) => chunks.last),
      _ConcatEntry<Duration>((chunks) => chunks.last),
      _ConcatEntry<String>((chunks) => chunks.join()),
      _ConcatEntry<Map<String, Object?>>(
        (chunks) => concatMaps(chunks, appendLists: false),
      ),
      // Before the classic messages, so that a value both fit (an empty
      // `List<Never>`) keeps resolving to the classic function.
      _ConcatEntry<AgenticMessage>(concatAgenticMessages),
      _ConcatEntry<List<AgenticMessage>>(concatAgenticMessagesArray),
      _ConcatEntry<Message>(concatMessages),
      _ConcatEntry<List<Message>>(concatMessageArray),
      _ConcatEntry<ToolResult>(concatToolResults),
    ]);
  }

  static _ConcatEntry<Object>? _entryFor<T>() {
    _ensureBuiltIns();
    for (final entry in _entries.reversed) {
      if (entry.accepts<T>()) return entry;
    }
    return null;
  }

  static _ConcatEntry<Object>? _entryForValues(List<Object?> values) {
    _ensureBuiltIns();
    for (final entry in _entries.reversed) {
      if (entry.matchesAll(values)) return entry;
    }
    return null;
  }

  static T _checked<T extends Object>(
    Object result,
    _ConcatEntry<Object> entry,
  ) {
    if (result is T) return result;
    throw StateError(
      'The concat function registered for ${entry.typeName} returned a '
      '${result.runtimeType}, which is not a $T. Register a function for $T '
      'with StreamConcat.register.',
    );
  }

  /// Joins values whose type is only known at run time: the values of one key
  /// of the maps given to [concatMaps].
  static Object? _concatValues(
    List<Object?> values, {
    required bool appendLists,
    required bool lastWinsOnConflict,
  }) {
    final present = [
      for (final value in values)
        if (value != null) value,
    ];
    if (present.isEmpty) return null;
    if (present.length == 1) return present.single;

    if (present.every((value) => value is Map<String, Object?>)) {
      return concatMaps(
        present.cast<Map<String, Object?>>(),
        appendLists: appendLists,
        lastWinsOnConflict: lastWinsOnConflict,
      );
    }
    if (appendLists && present.every((value) => value is List<Object?>)) {
      return [for (final list in present.cast<List<Object?>>()) ...list];
    }

    final entry = _entryForValues(present);
    if (entry != null) return entry.concatValues(present);

    return _onlyValue(present, '${present.first.runtimeType}') ?? present.first;
  }

  /// The rule for a type without a concat function, as in Eino: when all
  /// chunks are empty the result is empty (`null` here, for the caller to
  /// replace), when exactly one has a value that is the result, and more than
  /// one cannot be joined.
  static Object? _onlyValue(List<Object?> values, String typeName) {
    Object? only;
    for (final value in values) {
      if (_isZero(value)) continue;
      if (only != null) {
        throw StateError(
          'cannot concat multiple non-zero value of type $typeName; register '
          'a function for the type with StreamConcat.register',
        );
      }
      only = value;
    }
    return only;
  }

  static bool _isZero(Object? value) => switch (value) {
        null => true,
        final String text => text.isEmpty,
        final num number => number == 0,
        final bool flag => !flag,
        final Iterable<Object?> items => items.isEmpty,
        final Map<Object?, Object?> map => map.isEmpty,
        _ => false,
      };
}

/// Merges [maps] key by key.
///
/// Port of eino's `concatMaps`. A key that occurs once keeps its value. The
/// values of a key that occurs several times are joined: maps by this
/// function again, everything else by the [StreamConcat] registry (strings
/// are concatenated, of numbers and bools the last one wins). `null` values
/// are ignored next to others.
///
/// Lists have no concat function in Eino, so two non-empty lists under one
/// key throw [StateError], unless [appendLists] is set: then they are appended
/// to each other. Message extras are merged that way.
///
/// Values under one key that cannot be joined (a string and a number, two
/// objects of a type without a concat function) throw [StateError] as well.
/// With [lastWinsOnConflict] the last of them is kept instead and nothing is
/// thrown; the lenient message concat uses that.
@internal
Map<String, Object?> concatMaps(
  List<Map<String, Object?>> maps, {
  required bool appendLists,
  bool lastWinsOnConflict = false,
}) {
  final collected = <String, List<Object?>>{};
  for (final map in maps) {
    for (final MapEntry(:key, :value) in map.entries) {
      (collected[key] ??= []).add(value);
    }
  }

  Object? join(List<Object?> values) {
    if (values.length == 1) return values.single;
    try {
      return StreamConcat._concatValues(
        values,
        appendLists: appendLists,
        lastWinsOnConflict: lastWinsOnConflict,
      );
      // A conflict between chunks is reported as a StateError; the lenient
      // caller asked for a winner instead.
      // ignore: avoid_catching_errors
    } on StateError {
      if (!lastWinsOnConflict) rethrow;
      return values.lastWhere((value) => value != null, orElse: () => null);
    }
  }

  return {
    for (final MapEntry(:key, value: values) in collected.entries)
      key: join(values),
  };
}
