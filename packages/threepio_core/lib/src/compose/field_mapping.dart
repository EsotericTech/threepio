/// Field mappings: which part of a node's output becomes which part of
/// another node's input in a workflow.
///
/// Port of eino `compose/field_mapping.go`. Go reads and writes struct fields
/// by reflection; here a mapping reads and writes `Map<String, Object?>` and
/// values that implement [FieldAddressable].
library;

import 'package:meta/meta.dart';

import '../core/field_addressable.dart';
import '../errors.dart';
import '../internal/type_utils.dart';
import '../schema/agentic_message.dart';
import '../schema/document.dart';
import '../schema/message.dart';
import '../streaming/stream_reader.dart';
import 'checkpoint_serializer.dart';
import 'errors.dart';
import 'type_ref.dart';

/// Takes the value a mapping passes on out of the output of the node it maps
/// from. Port of the function `compose.WithCustomExtractor` takes.
typedef FieldExtractor = Object? Function(Object? input);

/// Separates the names of a path inside [FieldMapping]. Port of eino
/// `pathSeparator`: the unit separator, which no field name contains.
const _separator = '\x1F';

List<String> _split(String path) =>
    path.isEmpty ? const [] : List.unmodifiable(path.split(_separator));

String _join(List<String> path) {
  for (final name in path) {
    if (name.contains(_separator)) {
      throw ArgumentError.value(
        path,
        'path',
        'a field name must not contain the unit separator (\\x1F)',
      );
    }
  }
  return path.join(_separator);
}

/// One mapping of a workflow edge: a field of the output of the node it comes
/// from, or the whole output, to a field of the input of the node it goes to,
/// or its whole input.
///
/// Port of eino `compose.FieldMapping`. A field is a key of a
/// `Map<String, Object?>` or a field of a [FieldAddressable]; a path names a
/// field inside a field.
///
/// ```dart
/// workflow.addLambdaNode('search', search)
///   ..addInput(Graph.start, [FieldMapping.mapFields('question', 'query')])
///   ..addInput('planner', [FieldMapping.toField('plan')]);
/// ```
///
/// When the node that receives is run with a stream, every chunk is mapped on
/// its own; a chunk that lacks the key a mapping reads leaves that mapping
/// out.
@immutable
final class FieldMapping {
  const FieldMapping._({
    this.fromNodeKey = '',
    String from = '',
    String to = '',
    this.customExtractor,
  })  : _from = from,
        _to = to;

  /// Maps the field [from] of the output to the whole input. Nothing else can
  /// be mapped to that input. Port of eino `compose.FromField`.
  factory FieldMapping.fromField(String from) =>
      FieldMapping._(from: _join([from]));

  /// Maps the whole output to the field [to] of the input. With
  /// [customExtractor], what that function takes out of the output is mapped
  /// instead. Port of eino `compose.ToField` and
  /// `compose.WithCustomExtractor`.
  factory FieldMapping.toField(String to, {FieldExtractor? customExtractor}) =>
      FieldMapping._(to: _join([to]), customExtractor: customExtractor);

  /// Maps the field [from] of the output to the field [to] of the input. Port
  /// of eino `compose.MapFields`.
  factory FieldMapping.mapFields(String from, String to) =>
      FieldMapping._(from: _join([from]), to: _join([to]));

  /// Maps the field at the end of the path [from] to the whole input. Port of
  /// eino `compose.FromFieldPath`.
  factory FieldMapping.fromFieldPath(List<String> from) =>
      FieldMapping._(from: _join(from));

  /// Maps the whole output (or what [customExtractor] takes out of it) to the
  /// field at the end of the path [to]. Port of eino `compose.ToFieldPath`.
  factory FieldMapping.toFieldPath(
    List<String> to, {
    FieldExtractor? customExtractor,
  }) =>
      FieldMapping._(to: _join(to), customExtractor: customExtractor);

  /// Maps the field at the end of the path [from] to the field at the end of
  /// the path [to]. Port of eino `compose.MapFieldPaths`.
  factory FieldMapping.mapFieldPaths(List<String> from, List<String> to) =>
      FieldMapping._(from: _join(from), to: _join(to));

  /// The key of the node the mapping takes from; empty until the mapping is
  /// given to a workflow node. Port of eino `FieldMapping.FromNodeKey`.
  final String fromNodeKey;

  final String _from;
  final String _to;

  /// Takes the mapped value out of the whole output, in place of a field
  /// path. Its result can only be checked when the workflow runs.
  final FieldExtractor? customExtractor;

  /// The path of the field the mapping reads; empty for the whole output.
  /// Port of eino `FieldMapping.FromPath`.
  List<String> get fromPath => _split(_from);

  /// The path of the field the mapping writes; empty for the whole input.
  /// Port of eino `FieldMapping.ToPath`.
  List<String> get toPath => _split(_to);

  /// The target path as one string, the key of the mapping in the map a
  /// mapped edge delivers.
  @internal
  String get targetKey => _to;

  /// This mapping for an edge that starts at the node [key].
  @internal
  FieldMapping from(String key) => FieldMapping._(
        fromNodeKey: key,
        from: _from,
        to: _to,
        customExtractor: customExtractor,
      );

  /// Whether the mapping reads the whole output.
  @internal
  bool get isFromAll => _from.isEmpty && customExtractor == null;

  /// Whether the mapping reads a field (and not through an extractor).
  @internal
  bool get isFromField => _from.isNotEmpty && customExtractor == null;

  /// Whether the mapping writes the whole input.
  @internal
  bool get isToAll => _to.isEmpty;

  /// Two mappings are equal when they read and write the same paths of the
  /// same node and neither has a custom extractor. Port of eino
  /// `FieldMapping.Equals`.
  @override
  bool operator ==(Object other) =>
      other is FieldMapping &&
      customExtractor == null &&
      other.customExtractor == null &&
      other._from == _from &&
      other._to == _to &&
      other.fromNodeKey == fromNodeKey;

  @override
  int get hashCode => Object.hash(_from, _to, fromNodeKey);

  /// Port of eino `FieldMapping.String`.
  @override
  String toString() {
    final buffer = StringBuffer('[from ');
    if (_from.isNotEmpty) buffer.write('${fromPath.join('.')}(field) of ');
    buffer.write(fromNodeKey);
    if (_to.isNotEmpty) buffer.write(' to ${toPath.join('.')}(field)');
    buffer.write(']');
    return buffer.toString();
  }
}

/// A field mapping could not be applied to the values of a run: a key that is
/// not there, a value on the way that has no fields, a value that does not
/// fit the field it is mapped to.
class FieldMappingException extends ThreepioException {
  /// A failed mapping described by [message].
  const FieldMappingException(super.message, {super.cause});

  @override
  String toString() => 'FieldMappingException: $message';
}

/// Signals that a chunk of a stream lacks the key a mapping reads.
final class _KeyNotFound implements Exception {
  const _KeyNotFound(this.key);
  final String key;
}

Object? _takeOne(Object? source, String name, List<String> pathSoFar) {
  if (source == null) {
    throw FieldMappingException(
      'intermediate source value on path=$pathSoFar is nil',
    );
  }
  if (source is Map<Object?, Object?>) {
    if (!source.containsKey(name)) throw _KeyNotFound(name);
    return source[name];
  }
  if (source is FieldAddressable) {
    try {
      return source.getField(name);
      // What an implementation throws for an unknown field.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (error) {
      throw FieldMappingException(
        'field mapping from a field, but field not found. field=$name, '
        'inputType=${source.runtimeType}',
        cause: error,
      );
    }
  }
  throw FieldMappingException(
    'field mapping from a value that is neither a map nor a '
    'FieldAddressable. path=$pathSoFar, actual type=${source.runtimeType}',
  );
}

/// What the mapped edge delivers for [input]: by target path, the values
/// [mappings] take out of it.
///
/// Port of eino `fieldMap`. With [allowKeyNotFound] (stream chunks) a mapping
/// whose key is missing is left out; otherwise that is an error.
@internal
Map<String, Object?> applyFieldMappings(
  List<FieldMapping> mappings,
  Object? input, {
  required bool allowKeyNotFound,
}) {
  final result = <String, Object?>{};
  mapping:
  for (final mapping in mappings) {
    final extractor = mapping.customExtractor;
    if (extractor != null) {
      result[mapping.targetKey] = extractor(input);
      continue;
    }
    final path = mapping.fromPath;
    var taken = input;
    for (var i = 0; i < path.length; i++) {
      try {
        taken = _takeOne(taken, path[i], path.sublist(0, i + 1));
      } on _KeyNotFound catch (missing) {
        if (allowKeyNotFound) continue mapping;
        throw FieldMappingException(
          'field mapping from a map key, but key not found in input. '
          'key=${missing.key}',
        );
      }
    }
    result[mapping.targetKey] = taken;
  }
  return result;
}

/// The conversion a mapped edge applies to what travels over it.
///
/// Port of eino `fieldMap` and `streamFieldMap` as one handler pair.
@internal
HandlerPair fieldMappingHandler(List<FieldMapping> mappings) => HandlerPair(
      invoke: (value) =>
          applyFieldMappings(mappings, value, allowKeyNotFound: false),
      transform: (stream) => stream.convert<Map<String, Object?>>(
        (chunk) => applyFieldMappings(mappings, chunk, allowKeyNotFound: true),
      ),
    );

bool _isMapType(TypeRef<Object?> type) =>
    type.isSubtypeOf(const TypeRef<Map<Object?, Object?>?>());

bool _isAddressableType(TypeRef<Object?> type) =>
    type.isSubtypeOf(const TypeRef<FieldAddressable?>());

/// Checks [mappings] of an edge from a node that gives [predecessor] to a
/// node that takes [successor], as far as the types tell.
///
/// Port of eino `validateFieldMapping`. Go also follows the paths through
/// the struct types and compares the field types; without reflection that
/// part happens when the workflow runs ([assembleFromFields]).
///
/// Throws [GraphBuildException].
@internal
void validateFieldMappings(
  TypeRef<Object?> predecessor,
  TypeRef<Object?> successor,
  List<FieldMapping> mappings,
) {
  final toAll = mappings.any((mapping) => mapping.isToAll);
  if (mappings.any((mapping) => mapping.isFromAll) && toAll) {
    throw const GraphBuildException(
      'invalid field mappings: from all fields to all, use common edge '
      'instead',
    );
  }
  if (!toAll) {
    _checkStringKeys(successor);
    if (!(_isMapType(successor) ||
        _isAddressableType(successor) ||
        _canHoldFields(successor))) {
      throw GraphBuildException(
        'static check fail: successor input type should be struct or map, '
        'actual: ${successor.name}',
      );
    }
    if (_isAddressableType(successor) &&
        successor.open(<T>() => blankOf<T>()) == null) {
      throw GraphBuildException(
        'static check fail: no empty value is registered for the successor '
        'input type ${successor.name}; register one with '
        'FieldAddressable.registerBlank',
      );
    }
  }
  if (mappings.any((mapping) => mapping.isFromField)) {
    _checkStringKeys(predecessor);
  }
  if (mappings.every((mapping) => mapping.isFromField) &&
      !(_isMapType(predecessor) ||
          _isAddressableType(predecessor) ||
          _canHoldFields(predecessor))) {
    throw GraphBuildException(
      'static check fail: predecessor output type should be struct or map, '
      'actual: ${predecessor.name}',
    );
  }
}

/// A map that fields are read from or written to is keyed by strings.
void _checkStringKeys(TypeRef<Object?> type) {
  if (_isMapType(type) &&
      !type.isSubtypeOf(const TypeRef<Map<String, Object?>?>())) {
    throw GraphBuildException(
      'static check failed: type[${type.name}] is not a map with string or '
      'string alias key',
    );
  }
}

/// Whether a place of [type] may hold a map although [type] is not a map
/// type: `Object`, `Object?`, `dynamic`. Whether it does is seen when the
/// value is there.
bool _canHoldFields(TypeRef<Object?> type) =>
    const TypeRef<Map<String, Object?>>().isSubtypeOf(type);

/// The empty value field mappings fill in for a place of type [T]: the one
/// registered with [FieldAddressable.registerBlank], or the built-in one of
/// [Message] (a user message without content), [Document] (without
/// content) and [AgenticMessage] (a user message without blocks). `null`
/// when [T] is no [FieldAddressable] type or has no blank.
@internal
FieldAddressable? blankOf<T>() {
  if (!isSubtype<T, FieldAddressable?>()) return null;
  final registered = FieldAddressable.blankFor<T>();
  if (registered != null) return registered;
  if (isSubtype<Message, T>()) return const Message(role: RoleType.user);
  if (isSubtype<Document, T>()) return const Document(content: '');
  if (isSubtype<AgenticMessage, T>()) return _blankAgenticMessage;
  return null;
}

/// The blank of [AgenticMessage] (its constructor copies its lists, so it
/// cannot be `const`).
final AgenticMessage _blankAgenticMessage =
    AgenticMessage(role: AgenticRoleType.user);

/// Why a value could not be assigned: the reason of the first way that was
/// tried, which is the plain one (the others are guesses at what could stand
/// in an empty place).
final class _Refusal {
  String? _reason;

  String? get reason => _reason;

  set reason(String? value) => _reason ??= value;
}

/// What can stand in a place that is empty and has to hold a field: a map,
/// or the empty value of a class. Go knows the type of the place and creates
/// that; here the candidates are tried, and the value around the place
/// decides by accepting one.
Iterable<Object> _emptyHolders() sync* {
  yield <String, Object?>{};
  yield* FieldAddressable.blanks();
  yield const Message(role: RoleType.user);
  yield const Document(content: '');
  yield _blankAgenticMessage;
}

/// The ways to give [destination] the [value] at [path], best first. Each is
/// a new value; [destination] is not changed.
///
/// Port of eino `assignOne`.
Iterable<Object> _assignments(
  Object destination,
  List<String> path,
  Object? value,
  _Refusal refusal,
) sync* {
  final name = path.first;
  final rest = path.sublist(1);

  if (destination is Map<Object?, Object?>) {
    if (rest.isEmpty) {
      yield Map<String, Object?>.from(destination)..[name] = value;
      return;
    }
    final existing = destination[name];
    for (final holder in existing != null ? [existing] : _emptyHolders()) {
      for (final inner in _assignments(holder, rest, value, refusal)) {
        yield Map<String, Object?>.from(destination)..[name] = inner;
      }
    }
    return;
  }

  if (destination is FieldAddressable) {
    if (rest.isEmpty) {
      // Nothing arrived for the field: it keeps the value of the blank.
      if (value == null) {
        yield destination;
        return;
      }
      final Object assigned;
      try {
        assigned = destination.withField(name, narrowCollections(value));
        // A field that does not exist (ArgumentError) or a value that does
        // not fit it (TypeError).
        // ignore: avoid_catching_errors
      } on Error catch (error) {
        refusal.reason = 'field[$name] of ${destination.runtimeType} does '
            'not take a value of type ${value.runtimeType}: $error';
        return;
      }
      yield assigned;
      return;
    }

    final Object? existing;
    try {
      existing = destination.getField(name);
      // ignore: avoid_catching_errors
    } on ArgumentError catch (error) {
      refusal.reason = '${destination.runtimeType} has no field[$name]: '
          '${error.message}';
      return;
    }
    final holders = existing != null
        ? [existing]
        : _acceptedHolders(destination, name, refusal);
    for (final holder in holders) {
      for (final inner in _assignments(holder, rest, value, refusal)) {
        final Object assigned;
        try {
          assigned = destination.withField(name, narrowCollections(inner));
          // What was put together inside does not fit the field after all (a
          // map whose values are of the wrong type): the next way.
          // ignore: avoid_catching_errors
        } on Error catch (error) {
          refusal.reason = 'field[$name] of ${destination.runtimeType} does '
              'not take a ${inner.runtimeType}: $error';
          continue;
        }
        yield assigned;
      }
    }
    return;
  }

  refusal.reason = 'intermediate type[${destination.runtimeType}] on the way '
      'to field[$name] is not valid: neither a map nor a FieldAddressable';
}

/// The empty holders the field [name] of [destination], which is `null`,
/// takes: found by trying each.
Iterable<Object> _acceptedHolders(
  FieldAddressable destination,
  String name,
  _Refusal refusal,
) sync* {
  Object? firstError;
  var accepted = false;
  for (final holder in _emptyHolders()) {
    try {
      destination.withField(name, narrowCollections(holder));
      // ignore: avoid_catching_errors
    } on Error catch (error) {
      firstError ??= error;
      continue;
    }
    accepted = true;
    yield holder;
  }
  if (!accepted) {
    refusal.reason = 'field[$name] of ${destination.runtimeType} is empty '
        'and takes neither a map nor the empty value of a registered class: '
        '$firstError';
  }
}

String _describe(List<FieldMapping> mappings, String target) {
  for (final mapping in mappings) {
    if (mapping.targetKey == target) return '$mapping';
  }
  return target.isEmpty
      ? 'to the whole input'
      : 'to ${_split(target).join('.')}(field)';
}

/// The input of type [T] made of what mapped edges delivered: [fields] by
/// target path. [mappings] are the mappings of the node; they only name the
/// mapping in an error.
///
/// Port of eino `convertTo`, and of the run-time half of the type checks Go
/// makes on the edge. Throws [FieldMappingException] when the fields do not
/// make a [T].
@internal
T assembleFromFields<T>(
  Map<Object?, Object?> fields, {
  List<FieldMapping> mappings = const [],
}) {
  if (fields.containsKey('')) {
    final whole = reviveFor<T>(fields['']);
    if (whole is T) return whole;
    throw FieldMappingException(
      'runtime check failed for mapping ${_describe(mappings, '')}, '
      'field[${whole.runtimeType}]-[$T] is absolutely not assignable',
    );
  }

  if (fields.isEmpty && !_canAssemble<T>()) {
    // Nothing arrived, and the input is taken whole from one field (a chunk
    // of a stream that lacks the key): Go passes the zero value of the type.
    final type = TypeRef<T>();
    if (type.hasZeroValue) return type.zeroValue();
    throw const NoValueException();
  }

  Object assembled = blankOf<T>() ?? <String, Object?>{};
  for (final MapEntry(:key, :value) in fields.entries) {
    final target = key! as String;
    final refusal = _Refusal();
    Object? chosen;
    for (final candidate
        in _assignments(assembled, _split(target), value, refusal)) {
      // A class has accepted the value, field by field. For a map the type
      // of the input says which of the candidates it is.
      if (assembled is FieldAddressable) {
        chosen = candidate;
        break;
      }
      final typed = reviveFor<T>(candidate);
      if (typed is T) {
        chosen = candidate;
        break;
      }
      refusal.reason = 'the mapped fields make a ${typed.runtimeType}, which '
          'is not the $T the node takes';
    }
    if (chosen == null) {
      throw FieldMappingException(
        'runtime check failed for mapping ${_describe(mappings, target)}, '
        'field[${value.runtimeType}] is absolutely not assignable: '
        '${refusal.reason}. (A class that has to be created on the way to a '
        'field needs FieldAddressable.registerBlank.)',
      );
    }
    assembled = chosen;
  }
  final result = reviveFor<T>(assembled);
  if (result is T) return result;
  throw FieldMappingException(
    'the mapped fields make a ${result.runtimeType}, which is not the $T the '
    'node takes',
  );
}

/// Whether an input of type [T] is put together from fields: a map, or a
/// class with a blank.
bool _canAssemble<T>() =>
    blankOf<T>() != null || isSubtype<Map<String, Object?>, T>();

/// The conversion in front of a node whose input is assembled from mapped
/// fields: from the merged map of fields to the input type [type].
///
/// Port of eino `buildFieldMappingConverter` and
/// `buildStreamFieldMappingConverter`. A chunk of a stream that brings
/// nothing for an input which is taken whole from one field, and whose type
/// has no empty value, is left out.
@internal
HandlerPair fieldMappingConverter(
  TypeRef<Object?> type, [
  List<FieldMapping> mappings = const [],
]) =>
    type.open(
      <T>() => HandlerPair(
        invoke: (value) {
          try {
            return assembleFromFields<T>(_fields(value), mappings: mappings);
          } on NoValueException {
            throw FieldMappingException(
              'nothing was mapped to the input of type $T, and the type has '
              'no empty value',
            );
          }
        },
        // A NoValueException drops the chunk.
        transform: (stream) => stream.convert<T>(
          (chunk) => assembleFromFields<T>(_fields(chunk), mappings: mappings),
        ),
      ),
    );

Map<Object?, Object?> _fields(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  throw ComposeTypeException(
    'unexpected input type. expected: Map<String, Object?>, got: '
    '${value.runtimeType}',
  );
}

/// The paths of a node's input that are mapped already, and the check that a
/// new one does not collide with them.
///
/// Port of eino `WorkflowNode.checkAndAddMappedPath`.
@internal
final class MappedFieldPaths {
  /// The record of the node [nodeKey].
  MappedFieldPaths(this.nodeKey);

  /// The node whose input is mapped.
  final String nodeKey;

  /// Whether the whole input was mapped.
  bool _whole = false;

  /// The tree of mapped paths; a leaf is `true`.
  Map<String, Object>? _tree;

  /// Records [paths] as mapped. An empty list maps the whole input.
  ///
  /// Throws [GraphBuildException] when the whole input is mapped already, or
  /// when a path ends at, or leads through, a field that is mapped as a
  /// whole. (As in Eino, two equal paths are found later, when the workflow
  /// is compiled.)
  void add(List<List<String>> paths) {
    if (_whole) {
      throw GraphBuildException(
        'entire output has already been mapped for node: $nodeKey',
      );
    }
    if (_tree == null) {
      if (paths.isEmpty) {
        _whole = true;
        return;
      }
      _tree = {};
    }

    for (final target in paths) {
      var level = _tree!;
      final traversed = <String>[];
      for (final (index, name) in target.indexed) {
        traversed.add(name);
        if (level[name] == true) {
          throw GraphBuildException(
            'two terminal field paths conflict for node $nodeKey: '
            '$traversed, $target',
          );
        }
        if (index < target.length - 1) {
          final next = <String, Object>{};
          level[name] = next;
          level = next;
        } else {
          level[name] = true;
        }
      }
    }
  }
}
