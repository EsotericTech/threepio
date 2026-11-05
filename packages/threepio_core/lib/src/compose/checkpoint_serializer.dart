/// Checkpoints as bytes: the JSON serializer and the types the engine itself
/// writes.
///
/// Port of the role of eino `internal/serialization` for checkpoints. Go
/// writes checkpoints with `gob` and finds types by reflection; here every
/// type that is not plain JSON is registered with [TypeRegistry].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/field_addressable.dart';
import '../internal/type_utils.dart';
import '../schema/type_registry.dart';
import 'checkpoint.dart';
import 'checkpoint_store.dart';
import 'dag.dart';
import 'interrupt.dart';
import 'pregel.dart';
import 'tools_node.dart';

/// Writes checkpoints as UTF-8 JSON, with [TypeRegistry] naming every value
/// that is not plain JSON.
///
/// The serializer a graph uses unless `GraphCompileOptions.serializer` names
/// another. Port of the role of eino's internal serializer.
///
/// A checkpoint holds whatever was on its way through the graph when the run
/// was interrupted: the state of the graph, the inputs of the nodes that run
/// next, the outputs that wait at nodes with several predecessors, the states
/// components saved with `statefulInterrupt`. Messages, documents and the
/// other schema types are registered already. A class of your own that can
/// end up in a checkpoint must be registered before a run is interrupted or
/// resumed, on both sides of a restart:
///
/// ```dart
/// TypeRegistry.registerName<ReviewState>(
///   'review_state',
///   fromJson: ReviewState.fromJson,
///   toJson: (state) => state.toJson(),
/// );
/// ```
///
/// A serializer of your own (compression, encryption, another format)
/// usually wraps this one: [toJson] and [fromJson] give the checkpoint as a
/// JSON value and take it back.
final class JsonCheckpointSerializer implements CheckpointSerializer {
  /// The JSON serializer.
  const JsonCheckpointSerializer();

  /// [value] as a JSON value (maps, lists, strings, numbers, booleans,
  /// `null`).
  ///
  /// Throws [CheckpointEncodeException] or [ArgumentError] when a value in
  /// it is neither JSON nor of a registered type.
  static Object? toJson(Object? value) {
    ensureComposeTypesRegistered();
    return TypeRegistry.encode(value);
  }

  /// The value [toJson] made [json] from.
  ///
  /// Throws [StateError] for a type name that is not registered.
  static Object? fromJson(Object? json) {
    ensureComposeTypesRegistered();
    return TypeRegistry.decode(json);
  }

  @override
  Uint8List serialize(Object? value) =>
      utf8.encode(jsonEncode(toJson(value)));

  @override
  Object? deserialize(Uint8List bytes) => fromJson(jsonDecode(utf8.decode(bytes)));
}

/// Registers the types the engine writes into checkpoints, under the names
/// Eino uses for them. Called wherever such a value is about to be encoded
/// or decoded; it does nothing when they are registered.
@internal
void ensureComposeTypesRegistered() {
  if (TypeRegistry.isRegistered<GraphCheckpoint>()) return;
  TypeRegistry.registerName<GraphCheckpoint>(
    '_eino_checkpoint',
    fromJson: GraphCheckpoint.fromJson,
    toJson: (checkpoint) => checkpoint.toJson(),
  );
  TypeRegistry.registerName<DagChannel>(
    '_eino_dag_channel',
    fromJson: DagChannel.fromJson,
    toJson: (channel) => channel.toJson(),
  );
  TypeRegistry.registerName<PregelChannel>(
    '_eino_pregel_channel',
    fromJson: PregelChannel.fromJson,
    toJson: (channel) => channel.toJson(),
  );
  TypeRegistry.registerName<GraphInterruptInfo>(
    '_eino_compose_interrupt_info',
    fromJson: GraphInterruptInfo.fromJson,
    toJson: (info) => info.toJson(),
  );
  registerToolsNodeTypes();
}

/// A copy of [state] that shares nothing with it, made by writing it as a
/// checkpoint would and reading it back.
///
/// Port of eino `deepCopyState`. A state that cannot be encoded (a class
/// that is not registered) is returned as it is: a graph without a checkpoint
/// store can be interrupted with any state, and a graph with one refuses an
/// unregistered state type when it is compiled.
@internal
Object? deepCopyState(Object? state) {
  if (state == null) return null;
  ensureComposeTypesRegistered();
  try {
    // Through text, as a store would: the copy must not share lists or maps.
    return TypeRegistry.decode(jsonDecode(jsonEncode(TypeRegistry.encode(state))));
    // A value that cannot be encoded is reported with an Error, by the
    // registry and by the JSON encoder alike.
    // ignore: avoid_catching_errors
  } on Error {
    return state;
  }
}

/// [value] as a [T], or `null` when it is none.
///
/// A value that was read back from JSON has lost the type arguments of its
/// lists and maps: a `List<String>` returns as a `List<Object?>`. When
/// [value] itself is no [T], this looks at what is really in it and gives
/// its lists and maps the types [T] asks for; see [reviveFor].
@internal
T? reviveAs<T extends Object>(Object? value) {
  final revived = reviveFor<T>(value);
  return revived is T ? revived : null;
}

/// [value] as a place of type [T] takes it, when giving its lists and maps
/// element types makes it a [T]; otherwise [value] itself.
///
/// The element types are the widest ones [T] allows: a place that takes a
/// `List<num>` gets a `List<num>` also when the list holds only integers,
/// and an empty list for a `List<String>` is a `List<String>` that can grow.
/// Where the element type of [T] is a class the engine does not know (not
/// registered with `TypeRegistry`, no registered blank), a list keeps the
/// narrowest type that holds its content; an empty one is then a list that
/// takes no elements.
@internal
Object? reviveFor<T>(Object? value) {
  if (value is T) return value;
  if (value is! List<Object?> && value is! Map<String, Object?>) return value;
  final narrow = _kindOf(value);
  bool fits(_Kind kind) => kind.open(<X>() => isSubtype<X, T>());
  if (!fits(narrow)) return value;
  return _widen(narrow, fits).build(value);
}

/// A list or a map with the narrowest element types that hold its content;
/// any other value as it is.
///
/// For a value that is handed to code which casts it to a typed collection
/// (`value as Map<String, Foo>`): a `Map<String, Object?>` of `Foo`s would
/// fail that cast.
@internal
Object? narrowCollections(Object? value) =>
    value is List<Object?> || value is Map<String, Object?>
        ? _retype(value)
        : value;

Object? _retype(Object? value) => _kindOf(value).build(value);

/// The shape of a value that came back from JSON: what its lists and maps
/// really hold. A kind can name its Dart type ([open]) and rebuild a value
/// with the collection types of that type ([build]).
sealed class _Kind {
  const _Kind();

  /// Calls [body] with the Dart type of this kind.
  R open<R>(R Function<T>() body);

  /// [value] with the collection types of this kind.
  Object? build(Object? value) => value;
}

/// A value that is not a JSON collection: a scalar, or a registered type.
final class _Leaf<T> extends _Kind {
  const _Leaf();

  @override
  R open<R>(R Function<X>() body) => body<T>();

  /// Whether every value of [other] is a value of this kind.
  bool covers(_Leaf<Object?> other) => other is _Leaf<T>;
}

/// The element kind of an empty collection: it fits everything.
final class _Nothing extends _Kind {
  const _Nothing();

  @override
  R open<R>(R Function<X>() body) => body<Never>();
}

final class _Nullable extends _Kind {
  const _Nullable(this.inner);

  /// The kind of the values that are not `null`; [_Nothing] when all are.
  final _Kind inner;

  @override
  R open<R>(R Function<X>() body) => inner.open(<T>() => body<T?>());

  @override
  Object? build(Object? value) => value == null ? null : inner.build(value);
}

final class _ListOf extends _Kind {
  const _ListOf(this.element);

  final _Kind element;

  @override
  R open<R>(R Function<X>() body) => element.open(<E>() => body<List<E>>());

  @override
  Object? build(Object? value) => element.open(
        <E>() => List<E>.from((value! as List<Object?>).map(element.build)),
      );
}

final class _MapOf extends _Kind {
  const _MapOf(this.value);

  final _Kind value;

  @override
  R open<R>(R Function<X>() body) =>
      value.open(<V>() => body<Map<String, V>>());

  @override
  Object? build(Object? value) => this.value.open(
        <V>() => <String, V>{
          for (final MapEntry(:key, value: item)
              in (value! as Map<String, Object?>).entries)
            key: this.value.build(item) as V,
        },
      );
}

/// The kind that holds the values of both [a] and [b].
_Kind _join(_Kind a, _Kind b) {
  if (a is _Nothing) return b;
  if (b is _Nothing) return a;
  if (a is _Nullable || b is _Nullable) {
    return _Nullable(
      _join(
        a is _Nullable ? a.inner : a,
        b is _Nullable ? b.inner : b,
      ),
    );
  }
  if (a is _ListOf && b is _ListOf) return _ListOf(_join(a.element, b.element));
  if (a is _MapOf && b is _MapOf) return _MapOf(_join(a.value, b.value));
  if (a is _Leaf<Object?> && b is _Leaf<Object?>) {
    if (a.covers(b)) return a;
    if (b.covers(a)) return b;
    const numbers = _Leaf<num>();
    if (numbers.covers(a) && numbers.covers(b)) return numbers;
  }
  return const _Leaf<Object>();
}

/// The types a place may be declared with, widest first.
const List<_Leaf<Object?>> _wideLeaves = [
  _Leaf<Object?>(),
  _Leaf<Object>(),
  _Leaf<num?>(),
  _Leaf<num>(),
  _Leaf<String?>(),
  _Leaf<String>(),
  _Leaf<bool?>(),
  _Leaf<bool>(),
  _Leaf<int?>(),
  _Leaf<int>(),
  _Leaf<double?>(),
  _Leaf<double>(),
  _Leaf<Map<String, Object?>>(),
  _Leaf<List<Object?>>(),
];

/// [kind] with every part made as wide as [fits] allows. [fits] says whether
/// a kind may stand where [kind] stands.
_Kind _widen(_Kind kind, bool Function(_Kind candidate) fits) {
  // A place that takes anything keeps the value as JSON gave it.
  for (final top in const [_Leaf<Object?>(), _Leaf<Object>()]) {
    if (_covers(top, kind) && fits(top)) return top;
  }
  switch (kind) {
    case _ListOf(:final element):
      return _ListOf(_widen(element, (inner) => fits(_ListOf(inner))));
    case _MapOf(:final value):
      return _MapOf(_widen(value, (inner) => fits(_MapOf(inner))));
    case _Nullable(:final inner):
      return _Nullable(_widen(inner, (wider) => fits(_Nullable(wider))));
    case _Leaf<Object?>():
      for (final candidate in _wideLeaves) {
        if (candidate.covers(kind) && fits(candidate)) return candidate;
      }
      return kind;
    case _Nothing():
      // An empty collection: any element type the place allows.
      for (final candidate in _wideLeaves) {
        if (fits(candidate)) return candidate;
      }
      return TypeRegistry.firstTypeWhere<_Kind>(
            <T>() => fits(_Leaf<T>()) ? _Leaf<T>() : null,
          ) ??
          FieldAddressable.firstBlankTypeWhere<_Kind>(
            <T>() => fits(_Leaf<T>()) ? _Leaf<T>() : null,
          ) ??
          kind;
  }
}

/// Whether [top] (`Object?` or `Object`) holds every value of [kind]: `null`
/// is not an `Object`.
bool _covers(_Leaf<Object?> top, _Kind kind) =>
    kind is! _Nullable || top.open(<T>() => null is T);

_Kind _kindOf(Object? value) {
  if (value == null) return const _Nullable(_Nothing());
  if (value is bool) return const _Leaf<bool>();
  if (value is int) return const _Leaf<int>();
  if (value is double) return const _Leaf<double>();
  if (value is String) return const _Leaf<String>();

  // A value of a registered type is what it is, also when that is a list
  // (`List<Message>`).
  final registered =
      TypeRegistry.withTypeOf<_Kind>(value, <T>() => _Leaf<T>()) ??
          // A class that field mappings fill in is known by its blank.
          FieldAddressable.withBlankTypeOf<_Kind>(value, <T>() => _Leaf<T>());
  if (registered != null) return registered;

  if (value is List<Object?>) {
    return _ListOf(value.map(_kindOf).fold(const _Nothing(), _join));
  }
  if (value is Map<String, Object?>) {
    return _MapOf(value.values.map(_kindOf).fold(const _Nothing(), _join));
  }
  return const _Leaf<Object>();
}
