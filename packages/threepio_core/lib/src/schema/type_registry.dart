/// Names for the types that are written to checkpoints: the [TypeRegistry].
///
/// Port of eino `schema/serialization.go` and of the tagged encoding of
/// `internal/serialization`.
library;

import 'package:meta/meta.dart';

import '../internal/type_utils.dart';
import 'agentic_message.dart';
import 'document.dart';
import 'message.dart';

/// One registered type: its name and how it is written and read.
final class _TypeEntry<T extends Object> {
  _TypeEntry(this.name, this.fromJson, this.toJson);

  final String name;
  final T Function(Map<String, Object?> json) fromJson;
  final Map<String, Object?> Function(T value) toJson;

  bool matches(Object? value) => value is T;

  bool accepts<S>() => isSubtype<S, T>();

  bool isExactly<S>() => isSameType<S, T>();

  Map<String, Object?> encode(Object value) => toJson(value as T);

  R open<R>(R Function<X>() body) => body<T>();

  bool isSubtypeOf<S>() => isSubtype<T, S>();

  String get typeName => '$T';
}

/// The registry of types that can be saved in a checkpoint and restored from
/// it.
///
/// A checkpoint holds values whose static type is not known when it is read
/// back: the state of a graph, the payload of an interrupt, whatever a node
/// passed on. [encode] therefore writes each such value together with a name,
/// and [decode] uses the name to find the function that rebuilds it. Go does
/// this with `gob` and reflection; here a type brings its two functions along
/// when it is registered.
///
/// ```dart
/// TypeRegistry.registerName<ReviewState>(
///   'review_state',
///   fromJson: ReviewState.fromJson,
///   toJson: (state) => state.toJson(),
/// );
/// ```
///
/// JSON values need no registration: `null`, `bool`, `num`, `String`, and
/// lists and string-keyed maps of anything encodable. The schema types of
/// this package ([Message], `List<Message>`, [AgenticMessage],
/// `List<AgenticMessage>`, [Document], [ToolCall] and the others Eino
/// registers) are registered already, under Eino's names.
///
/// A value is matched with `is`, never by its `runtimeType`, so a registration
/// for `Message` covers the private class the value really has, and one for
/// `List<Message>` covers every list implementation. When several registered
/// types fit a value, the one registered last is used.
///
/// The registry is global to the isolate.
abstract final class TypeRegistry {
  /// Marks a registered value in the encoded form.
  static const _typeKey = r'$type';
  static const _valueKey = r'$value';

  /// The name under which a plain map is wrapped when one of its own keys
  /// would be mistaken for [_typeKey].
  static const _plainMapName = r'$map';

  static final List<_TypeEntry<Object>> _entries = [];
  static final Map<String, _TypeEntry<Object>> _byName = {};
  static bool _builtInsRegistered = false;

  /// Registers `T` under [name].
  ///
  /// Port of eino `schema.RegisterName`. [toJson] must return a JSON map
  /// (values that are themselves registered types have to be turned into JSON
  /// by it) and [fromJson] must rebuild an equal value from that map.
  ///
  /// The name is what a stored checkpoint refers to: keep it stable across
  /// releases, also when the class is renamed.
  ///
  /// Throws [StateError] when the name is taken or `T` is registered already.
  static void registerName<T extends Object>(
    String name, {
    required T Function(Map<String, Object?> json) fromJson,
    required Map<String, Object?> Function(T value) toJson,
  }) {
    _ensureBuiltIns();
    _add(_TypeEntry<T>(name, fromJson, toJson));
  }

  /// Whether a value declared as `T` can be encoded: `T` or a supertype of it
  /// is registered.
  ///
  /// See [canEncode] for the question a checkpointing graph asks about its
  /// state type.
  static bool isRegistered<T extends Object>() {
    _ensureBuiltIns();
    return _entries.any((entry) => entry.accepts<T>());
  }

  /// Whether a value declared as `T` survives [encode] and [decode] as a `T`.
  ///
  /// True for a registered type and for the JSON types: `bool`, `num`, `int`,
  /// `double`, `String`, and the list and map types [decode] returns
  /// (`List<Object?>`, `Map<String, Object?>` and their `dynamic` forms). A
  /// narrower collection type such as `List<int>` can be encoded but comes
  /// back as a `List<Object?>`, so it has to be registered under a name.
  static bool canEncode<T extends Object>() =>
      isSubtype<T, bool>() ||
      isSubtype<T, num>() ||
      isSubtype<T, String>() ||
      isSubtype<List<Object?>, T>() ||
      isSubtype<Map<String, Object?>, T>() ||
      isRegistered<T>();

  /// The name [value] is encoded under, or `null` when its type is not
  /// registered.
  static String? nameOf(Object value) => _entryOf(value)?.name;

  /// [value] as JSON from which [decode] can rebuild it.
  ///
  /// A value of a registered type becomes
  /// `{r'$type': name, r'$value': toJson(value)}`. JSON values stay as they
  /// are, and lists and string-keyed maps are encoded element by element.
  ///
  /// Throws [ArgumentError] for a value that is neither JSON nor of a
  /// registered type.
  static Object? encode(Object? value) {
    _ensureBuiltIns();
    return _encode(value);
  }

  /// Rebuilds the value [encode] made [json] from.
  ///
  /// Lists come back as `List<Object?>` and maps as `Map<String, Object?>`,
  /// except those that were registered under a name of their own.
  ///
  /// Throws [StateError] for a name that is not registered (any more).
  static Object? decode(Object? json) {
    _ensureBuiltIns();
    return _decode(json);
  }

  /// Whether some registered type is a `T`: a value declared as `T` (an
  /// interface, say) may then be one that can be encoded.
  @internal
  static bool hasSubtypeOf<T extends Object>() {
    _ensureBuiltIns();
    return _entries.any((entry) => entry.isSubtypeOf<T>());
  }

  /// Calls [body] with the registered type [value] is encoded as, or returns
  /// `null` when no registered type fits it.
  ///
  /// For code that has to rebuild a typed collection of registered values
  /// (a `List<Message>` from the messages in a `List<Object?>`).
  @internal
  static R? withTypeOf<R>(Object value, R Function<T>() body) =>
      _entryOf(value)?.open(body);

  /// The first result that is not `null` of calling [body] with each
  /// registered type, the most recently registered first.
  @internal
  static R? firstTypeWhere<R>(R? Function<T>() body) {
    _ensureBuiltIns();
    for (final entry in _entries.reversed) {
      final R? result = entry.open<R?>(body);
      if (result != null) return result;
    }
    return null;
  }

  /// Forgets every registration except the built-in ones.
  @visibleForTesting
  static void reset() {
    _entries.clear();
    _byName.clear();
    _builtInsRegistered = false;
  }

  static void _add<T extends Object>(_TypeEntry<T> entry) {
    final taken = _byName[entry.name];
    if (taken != null) {
      throw StateError(
        'key[${entry.name}] already registered to ${taken.typeName}',
      );
    }
    for (final other in _entries) {
      if (other.isExactly<T>()) {
        throw StateError(
          'type[${entry.typeName}] already registered to ${other.name}',
        );
      }
    }
    _entries.add(entry);
    _byName[entry.name] = entry;
  }

  static _TypeEntry<Object>? _entryOf(Object value) {
    _ensureBuiltIns();
    for (final entry in _entries.reversed) {
      if (entry.matches(value)) return entry;
    }
    return null;
  }

  static Object? _encode(Object? value) {
    if (value == null || value is bool || value is num || value is String) {
      return value;
    }

    final entry = _entryOf(value);
    if (entry != null) {
      return {_typeKey: entry.name, _valueKey: entry.encode(value)};
    }

    if (value is List<Object?>) return [for (final item in value) _encode(item)];

    if (value is Map<String, Object?>) {
      final encoded = {
        for (final MapEntry(:key, value: item) in value.entries)
          key: _encode(item),
      };
      return value.containsKey(_typeKey)
          ? {_typeKey: _plainMapName, _valueKey: encoded}
          : encoded;
    }

    throw ArgumentError.value(
      value,
      'value',
      'cannot be encoded: ${value.runtimeType} is not a JSON value and no '
          'registered type fits it. Register it with TypeRegistry.registerName',
    );
  }

  static Object? _decode(Object? json) {
    if (json is List<Object?>) return [for (final item in json) _decode(item)];
    if (json is! Map<String, Object?>) return json;

    final name = json[_typeKey];
    if (name is! String) {
      return <String, Object?>{
        for (final MapEntry(:key, :value) in json.entries) key: _decode(value),
      };
    }

    final value = json[_valueKey];
    if (name == _plainMapName) {
      return <String, Object?>{
        for (final MapEntry(:key, value: item)
            in (value! as Map<String, Object?>).entries)
          key: _decode(item),
      };
    }

    final entry = _byName[name];
    if (entry == null) {
      throw StateError(
        'No type is registered under "$name". Register it with '
        'TypeRegistry.registerName before decoding',
      );
    }
    return entry.fromJson(value! as Map<String, Object?>);
  }

  /// The types Eino registers in `schema/serialization.go`, under the same
  /// names. The deprecated ones are left out.
  static void _ensureBuiltIns() {
    if (_builtInsRegistered) return;
    _builtInsRegistered = true;

    void add<T extends Object>(
      String name,
      T Function(Map<String, dynamic> json) fromJson,
      Map<String, dynamic> Function(T value) toJson,
    ) =>
        _add(_TypeEntry<T>(name, fromJson, toJson));

    /// Enums and lists are no JSON maps; they are wrapped in one.
    void addEnum<T extends Enum>(String name, List<T> values) => add<T>(
          name,
          (json) => values.byName(json['name'] as String),
          (value) => {'name': value.name},
        );

    // The agentic messages come first: a value both a classic and an agentic
    // entry fit (an empty `List<Never>`) keeps resolving to the classic one,
    // as before they were added.
    add<AgenticMessage>(
      '_eino_agentic_message',
      AgenticMessage.fromJson,
      (v) => v.toJson(),
    );
    add<List<AgenticMessage>>(
      '_eino_agentic_message_slice',
      (json) => [
        for (final item in json['items'] as List<Object?>)
          AgenticMessage.fromJson(item! as Map<String, Object?>),
      ],
      (value) => {
        'items': [for (final message in value) message.toJson()],
      },
    );
    add<Message>('_eino_message', Message.fromJson, (v) => v.toJson());
    add<List<Message>>(
      '_eino_message_slice',
      (json) => [
        for (final item in json['items'] as List<Object?>)
          Message.fromJson(item! as Map<String, dynamic>),
      ],
      (value) => {
        'items': [for (final message in value) message.toJson()],
      },
    );
    add<Document>('_eino_document', Document.fromJson, (v) => v.toJson());
    addEnum<RoleType>('_eino_role_type', RoleType.values);
    add<ToolCall>('_eino_tool_call', ToolCall.fromJson, (v) => v.toJson());
    add<FunctionCall>(
      '_eino_function_call',
      FunctionCall.fromJson,
      (v) => v.toJson(),
    );
    add<ResponseMeta>(
      '_eino_response_meta',
      ResponseMeta.fromJson,
      (v) => v.toJson(),
    );
    add<TokenUsage>(
      '_eino_token_usage',
      TokenUsage.fromJson,
      (v) => v.toJson(),
    );
    add<LogProbs>('_eino_log_probs', LogProbs.fromJson, (v) => v.toJson());
    addEnum<ChatMessagePartType>(
      '_eino_chat_message_type',
      ChatMessagePartType.values,
    );
    add<MessageInputPart>(
      '_eino_message_input_part',
      MessageInputPart.fromJson,
      (v) => v.toJson(),
    );
    add<MessageInputImage>(
      '_eino_message_input_image',
      MessageInputImage.fromJson,
      (v) => v.toJson(),
    );
    add<MessageInputAudio>(
      '_eino_message_input_audio',
      MessageInputAudio.fromJson,
      (v) => v.toJson(),
    );
    add<MessageInputVideo>(
      '_eino_message_input_video',
      MessageInputVideo.fromJson,
      (v) => v.toJson(),
    );
    add<MessageInputFile>(
      '_eino_message_input_file',
      MessageInputFile.fromJson,
      (v) => v.toJson(),
    );
    add<MessageOutputPart>(
      '_eino_message_output_part',
      MessageOutputPart.fromJson,
      (v) => v.toJson(),
    );
    add<MessagePartCommon>(
      '_eino_message_part_common',
      MessagePartCommon.fromJson,
      (v) => v.toJson(),
    );
    addEnum<ImageURLDetail>('_eino_image_url_detail', ImageURLDetail.values);
    add<PromptTokenDetails>(
      '_eino_prompt_token_details',
      PromptTokenDetails.fromJson,
      (v) => v.toJson(),
    );
  }
}
