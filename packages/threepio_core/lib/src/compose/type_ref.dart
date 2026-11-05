/// A type argument captured as a value, with the type-dependent operations the
/// graph engine needs.
///
/// Eino does all of this with `reflect`. Dart generics are reified, so an
/// object that was created where the type was known can answer the same
/// questions later, when the engine only holds `Object?`.
@internal
library;

import 'package:meta/meta.dart';

import '../internal/type_utils.dart';
import '../streaming/stream_reader.dart';
import 'checkpoint_serializer.dart';
import 'errors.dart';
import 'field_mapping.dart';
import 'stream_conversion.dart';

/// How a value of one type relates to a place that takes another.
///
/// Port of eino `assignableType`.
enum Assignable {
  /// Never fits. The edge is an error.
  mustNot,

  /// Always fits.
  must,

  /// May fit: the place takes a narrower type than the value is declared
  /// with, so the value has to be looked at when it is there.
  may,
}

/// The type [T], for code that does not know it statically.
final class TypeRef<T> {
  /// Captures [T].
  const TypeRef();

  /// The type itself, for display.
  Type get type => T;

  /// The name of the type, as it appears in error messages.
  String get name => '$T';

  /// Whether [value] is a [T].
  bool isInstance(Object? value) => value is T;

  /// Whether every [T] is a value of the type [other] stands for.
  bool isSubtypeOf(TypeRef<Object?> other) => other._isSupertypeOf<T>();

  bool _isSupertypeOf<S>() => isSubtype<S, T>();

  /// Whether this and [other] stand for the same type.
  bool isSameAs(TypeRef<Object?> other) =>
      isSubtypeOf(other) && other.isSubtypeOf(this);

  /// Whether [T] is `Object?` (or `dynamic`): the type of Go's `any`.
  bool get isTop => isSubtype<Object?, T>();

  /// Calls [body] with [T] as its type argument.
  R open<R>(R Function<X>() body) => body<T>();

  /// [value] as it is when it is a [T].
  ///
  /// Port of eino `defaultValueChecker`. Throws [ComposeTypeException]
  /// otherwise.
  Object? check(Object? value) {
    if (value is T) return value;
    throw ComposeTypeException(
      'runtime type check fail, expected type: $T, '
      'actual type: ${value.runtimeType}',
    );
  }

  /// [stream] as a stream of [T].
  ///
  /// Port of eino `unpackStreamReader` and `defaultStreamConverter`. A stream
  /// that is declared with a wider chunk type is checked chunk by chunk: a
  /// chunk that is not a [T] becomes a [ComposeTypeException] where it is
  /// read.
  StreamReader<T> stream(StreamReader<Object?> stream) {
    if (stream is StreamReader<T>) return stream;
    return stream.convert<T>((chunk) {
      if (chunk is T) return chunk;
      throw ComposeTypeException(
        'runtime type check fail, expected type: $T, '
        'actual type: ${chunk.runtimeType}',
      );
    });
  }

  /// From a stream of maps, the stream of the values under [key].
  ///
  /// Port of eino `defaultStreamMapFilter`: chunks without the key are left
  /// out, a value that is not a [T] is an error in the stream.
  StreamReader<T> streamOfKey(String key, StreamReader<Object?> stream) =>
      stream.convert<T>((chunk) {
        if (chunk is! Map<Object?, Object?>) {
          throw ComposeTypeException(
            'input key "$key" needs a stream of maps, got a chunk of type '
            '${chunk.runtimeType}',
          );
        }
        if (!chunk.containsKey(key)) throw const NoValueException();
        final value = chunk[key];
        if (value is T) return value;
        throw ComposeTypeException(
          "key[$key]'s value type[${value.runtimeType}] isn't expected "
          'type[$T]',
        );
      });

  /// A value to run a node with that has no input of its own.
  ///
  /// Port of eino `zeroValueFromGeneric`. Dart has no zero value for every
  /// type: this is `null` where [T] allows it, and otherwise the empty string,
  /// zero, `false` or an empty collection, whichever is a [T].
  T zeroValue() {
    for (final candidate in _zeroValues) {
      if (candidate is T) return candidate;
    }
    throw ComposeTypeException('the type $T has no empty value');
  }

  /// Whether [zeroValue] has a value to give.
  bool get hasZeroValue => _zeroValues.any((candidate) => candidate is T);

  /// [value] as it has to be for a place of this type, when it was read back
  /// from a checkpoint.
  ///
  /// JSON forgets the type arguments of lists and maps: a `List<String>`
  /// returns as a `List<Object?>`. A value that is no [T] for that reason is
  /// rebuilt with the narrowest list and map types that hold its content;
  /// any other value is returned as it is.
  Object? revive(Object? value) => reviveFor<T>(value);

  /// Reads [source] to its end and joins its chunks into one value, for a
  /// checkpoint. `null` when the stream has no chunk.
  ///
  /// Port of the `concatStream` half of eino `defaultStreamConvertPair`. An
  /// error in the stream for which [ignoreError] returns `true` ends the
  /// reading without failing it.
  Future<Object?> concatStream(
    StreamReader<Object?> source,
    bool Function(Object error) ignoreError,
  ) async {
    try {
      return await concatStreamReader<T>(
        stream(source),
        ignoreError: ignoreError,
      );
    } on StreamReadException catch (error) {
      if (error.isEmptyStream) return null;
      rethrow;
    }
  }

  /// The stream a streaming run goes on with for [value], which a checkpoint
  /// kept in place of a stream.
  ///
  /// Port of the `restoreStream` half of eino `defaultStreamConvertPair`:
  /// `null` gives a stream without chunks, a [T] a stream of that one chunk.
  StreamReader<T> restoreStream(Object? value) {
    if (value == null) return StreamReader<T>.fromIterable(const []);
    final revived = revive(value);
    if (revived is T) return StreamReader<T>.fromIterable([revived]);
    throw ComposeTypeException(
      'cannot convert value[${value.runtimeType}] to streamReader[$T]',
    );
  }

  /// A stream with [zeroValue] as its only chunk.
  ///
  /// Port of eino `emptyStreamFromGeneric`.
  StreamReader<T> zeroStream() => StreamReader<T>.fromIterable([zeroValue()]);

  /// A stream of [T] without chunks.
  StreamReader<T> emptyStream() => StreamReader<T>.fromIterable(const []);

  static const List<Object?> _zeroValues = [
    null,
    '',
    0,
    0.0,
    false,
    <Never>[],
    <Never, Never>{},
    <Never>{},
  ];

  @override
  String toString() => 'TypeRef<$T>';
}

/// The relation between a value declared as [source] and a place that takes
/// [target].
///
/// Port of eino `checkAssignable`. Go distinguishes interfaces from concrete
/// types; in Dart every type may have subtypes, so "may" covers any edge from
/// a supertype to one of its subtypes.
Assignable checkAssignable(TypeRef<Object?>? source, TypeRef<Object?>? target) {
  if (source == null || target == null) return Assignable.mustNot;
  if (source.isSubtypeOf(target)) return Assignable.must;
  if (target.isSubtypeOf(source)) return Assignable.may;
  return Assignable.mustNot;
}

/// The type `Map<String, Object?>`, Go's `map[string]any`.
const TypeRef<Map<String, Object?>> mapType = TypeRef<Map<String, Object?>>();

/// A conversion that runs on an edge or in front of a node, in its value and
/// its stream form.
///
/// Port of eino `handlerPair`.
final class HandlerPair {
  /// A pair of [invoke] and [transform].
  const HandlerPair({required this.invoke, required this.transform});

  /// Converts a value; throws when it cannot.
  final Object? Function(Object? value) invoke;

  /// Converts a stream, lazily.
  final StreamReader<Object?> Function(StreamReader<Object?> stream) transform;
}

/// The type-dependent operations for the input and the output of a runnable.
///
/// Port of eino `genericHelper`. The stream convert pairs of the Go struct are
/// methods of [TypeRef] (`concatStream`, `restoreStream`).
final class GenericHelper {
  /// The helper for a runnable from [input] to [output].
  const GenericHelper(this.input, this.output);

  /// The helper for a runnable from [I] to [O].
  static GenericHelper of<I, O>() => GenericHelper(TypeRef<I>(), TypeRef<O>());

  /// The input type.
  final TypeRef<Object?> input;

  /// The output type.
  final TypeRef<Object?> output;

  /// Checks that a value or the chunks of a stream fit the input type.
  HandlerPair get inputConverter =>
      HandlerPair(invoke: input.check, transform: input.stream);

  /// Checks that a value or the chunks of a stream fit the output type.
  HandlerPair get outputConverter =>
      HandlerPair(invoke: output.check, transform: output.stream);

  /// Assembles the input from the fields that mapped edges delivered.
  HandlerPair get inputFieldMappingConverter => fieldMappingConverter(input);

  /// Assembles the output from the fields that mapped edges delivered.
  HandlerPair get outputFieldMappingConverter => fieldMappingConverter(output);

  /// The helper of the same runnable behind an input key: it takes a map.
  GenericHelper forMapInput() => GenericHelper(mapType, output);

  /// The helper of the same runnable behind an output key: it gives a map.
  GenericHelper forMapOutput() => GenericHelper(input, mapType);

  /// The helper of a passthrough node in front of this runnable.
  GenericHelper forPredecessorPassthrough() => GenericHelper(input, input);

  /// The helper of a passthrough node behind this runnable.
  GenericHelper forSuccessorPassthrough() => GenericHelper(output, output);
}
