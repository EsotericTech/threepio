/// Values whose fields can be read and replaced by name.
library;

import 'package:meta/meta.dart';

import '../internal/type_utils.dart';

/// A value with named fields that a workflow can map from and to.
///
/// Go reads and writes struct fields by reflection; Dart has none, so a class
/// that takes part in the field mappings of a `Workflow` says itself how a
/// field is read and how a copy with another value for a field is made:
///
/// ```dart
/// final class Query implements FieldAddressable {
///   const Query({this.text = '', this.limit = 10});
///   final String text;
///   final int limit;
///
///   @override
///   Object? getField(String name) => switch (name) {
///         'text' => text,
///         'limit' => limit,
///         _ => throw ArgumentError.value(name, 'name', 'Query has no such field'),
///       };
///
///   @override
///   Query withField(String name, Object? value) => switch (name) {
///         'text' => Query(text: value! as String, limit: limit),
///         'limit' => Query(text: text, limit: value! as int),
///         _ => throw ArgumentError.value(name, 'name', 'Query has no such field'),
///       };
/// }
/// ```
///
/// Reading is enough for a value that field mappings only take from. A type
/// that mappings also write to (the input of a node that is assembled from
/// fields, or a field of such an input that a mapping reaches into)
/// additionally registers how an empty value of it is made:
/// `FieldAddressable.registerBlank<Query>(() => const Query())`.
///
/// Go creates a struct it needs on the way to a field (`a.b.c` when `a.b` is
/// nil) from the type of the field. Here the registered blanks are tried:
/// the first one the surrounding value accepts for the field is used.
///
/// `Map<String, Object?>` needs none of this, and `Message` and `Document`
/// implement the interface.
abstract interface class FieldAddressable {
  /// The value of the field [name].
  ///
  /// Throws [ArgumentError] when there is no field of that name.
  Object? getField(String name);

  /// A copy of this value in which the field [name] is [value].
  ///
  /// Throws [ArgumentError] when there is no field of that name, and whatever
  /// a cast throws when [value] does not fit the field.
  Object withField(String name, Object? value);

  static final List<_Blank<FieldAddressable>> _blanks = [];

  /// Tells workflows how to make the value of type [T] that field mappings
  /// then fill in, field by field.
  ///
  /// Go creates the zero value of a struct; here [create] does. Registered
  /// once per type, typically next to the class. A later registration for the
  /// same or a narrower type wins.
  static void registerBlank<T extends FieldAddressable>(T Function() create) =>
      _blanks.add(_Blank<T>(create));

  /// An empty value for a place of type [T], or `null` when no registered
  /// type fits there.
  @internal
  static FieldAddressable? blankFor<T>() {
    for (final blank in _blanks.reversed) {
      if (blank.fits<T>()) return blank.create();
    }
    return null;
  }

  /// A fresh empty value of every registered type, the most recently
  /// registered first.
  @internal
  static Iterable<FieldAddressable> blanks() sync* {
    for (final blank in _blanks.reversed) {
      yield blank.create();
    }
  }

  /// Calls [body] with the registered type [value] is an instance of, or
  /// returns `null` when it is of none.
  @internal
  static R? withBlankTypeOf<R>(Object? value, R Function<T>() body) {
    for (final blank in _blanks.reversed) {
      if (blank.matches(value)) return blank.open(body);
    }
    return null;
  }

  /// The first result that is not `null` of calling [body] with each type
  /// that has a blank, the most recently registered first.
  @internal
  static R? firstBlankTypeWhere<R>(R? Function<T>() body) {
    for (final blank in _blanks.reversed) {
      final R? result = blank.open<R?>(body);
      if (result != null) return result;
    }
    return null;
  }

  /// Forgets the registered blanks.
  @visibleForTesting
  static void resetBlanks() => _blanks.clear();
}

final class _Blank<B extends FieldAddressable> {
  _Blank(this.create);

  final B Function() create;

  /// Whether a [B] can stand where a [T] is expected.
  bool fits<T>() => isSubtype<B, T>();

  bool matches(Object? value) => value is B;

  R open<R>(R Function<T>() body) => body<B>();
}
