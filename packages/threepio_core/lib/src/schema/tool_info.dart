import 'package:collection/collection.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../errors.dart';

part 'tool_info.freezed.dart';
part 'tool_info.g.dart';

/// Controls how the model calls tools (if any)
enum ToolChoice {
  /// Model should not call any tools (OpenAI: "none")
  @JsonValue('forbidden')
  forbidden,

  /// Model can choose to generate a message or call one or more tools (OpenAI: "auto")
  @JsonValue('allowed')
  allowed,

  /// Model must call one or more tools (OpenAI: "required")
  @JsonValue('forced')
  forced,
}

/// JSON Schema property definition
@freezed
abstract class JSONSchemaProperty with _$JSONSchemaProperty {
  const factory JSONSchemaProperty({
    /// Property type (string, number, boolean, object, array, etc.)
    required String type,

    /// Property description
    String? description,

    /// Enum values (if applicable)
    List<dynamic>? enumValues,

    /// Items schema (for array type)
    JSONSchemaProperty? items,

    /// Properties (for object type)
    Map<String, JSONSchemaProperty>? properties,

    /// Required properties (for object type)
    List<String>? required,

    /// Additional properties flag
    bool? additionalProperties,
  }) = _JSONSchemaProperty;

  factory JSONSchemaProperty.fromJson(Map<String, dynamic> json) =>
      _$JSONSchemaPropertyFromJson(json);

  /// Create a string property
  factory JSONSchemaProperty.string({
    String? description,
    List<String>? enumValues,
  }) =>
      JSONSchemaProperty(
        type: 'string',
        description: description,
        enumValues: enumValues,
      );

  /// Create a number property
  factory JSONSchemaProperty.number({String? description}) =>
      JSONSchemaProperty(
        type: 'number',
        description: description,
      );

  /// Create a boolean property
  factory JSONSchemaProperty.boolean({String? description}) =>
      JSONSchemaProperty(
        type: 'boolean',
        description: description,
      );

  /// Create an array property
  factory JSONSchemaProperty.array({
    String? description,
    required JSONSchemaProperty items,
  }) =>
      JSONSchemaProperty(
        type: 'array',
        description: description,
        items: items,
      );

  /// Create an object property
  factory JSONSchemaProperty.object({
    String? description,
    required Map<String, JSONSchemaProperty> properties,
    List<String>? required,
  }) =>
      JSONSchemaProperty(
        type: 'object',
        description: description,
        properties: properties,
        required: required,
      );
}

/// JSON Schema for function parameters
@freezed
abstract class JSONSchema with _$JSONSchema {
  const factory JSONSchema({
    /// Schema type (always "object" for function parameters)
    @Default('object') String type,

    /// Properties of the schema
    @Default({}) Map<String, JSONSchemaProperty> properties,

    /// Required properties
    @Default([]) List<String> required,

    /// Allow additional properties
    @Default(false) bool additionalProperties,
  }) = _JSONSchema;

  factory JSONSchema.fromJson(Map<String, dynamic> json) =>
      _$JSONSchemaFromJson(json);
}

/// Function information for tool calling
@freezed
abstract class FunctionInfo with _$FunctionInfo {
  const factory FunctionInfo({
    /// Name of the function
    required String name,

    /// Description of what the function does
    String? description,

    /// Parameters schema
    JSONSchema? parameters,

    /// Whether the function is strict (OpenAI specific)
    bool? strict,

    /// The parameters as a complete JSON Schema document, exactly as it was
    /// given (Eino: a `ParamsOneOf` made by `NewParamsOneOfByJSONSchema`).
    ///
    /// [parameters] can describe types, descriptions, enums, items,
    /// properties, `required` and `additionalProperties`, nothing else. A
    /// schema that uses more (`anyOf`, `$ref`, `$defs`, `format`, `default`,
    /// `minimum`, …) is kept here unchanged, and [parameters] holds the part
    /// of it that [JSONSchema] can describe, for code that reads
    /// [parameters]. Providers send this map instead of [parameters] when it
    /// is set. Set it with [ToolInfo.fromJsonSchemaMap]; it is `null`
    /// otherwise, and left out of [toJson] then.
    @JsonKey(includeIfNull: false) Map<String, dynamic>? parametersJsonSchema,
  }) = _FunctionInfo;

  factory FunctionInfo.fromJson(Map<String, dynamic> json) =>
      _$FunctionInfoFromJson(json);
}

/// Tool information for LLM tool calling
///
/// Port of eino `schema.ToolInfo`. The stored shape is the one of the OpenAI
/// API (`type` plus `function`); [name], [desc] and [paramsOneOf] read it the
/// way Eino names things, and [ToolInfo.fromParams] and
/// [ToolInfo.fromJsonSchema] build it that way.
@freezed
abstract class ToolInfo with _$ToolInfo {
  const factory ToolInfo({
    /// Tool type (typically "function")
    @Default('function') String type,

    /// Function information
    required FunctionInfo function,

    /// Extra information about the tool. It is not part of the definition
    /// the model sees.
    Map<String, dynamic>? extra,
  }) = _ToolInfo;

  const ToolInfo._();

  factory ToolInfo.fromJson(Map<String, dynamic> json) =>
      _$ToolInfoFromJson(json);

  /// Create a tool info whose parameters are described by [ParameterInfo]s.
  ///
  /// Port of a Go `ToolInfo` literal with
  /// `schema.NewParamsOneOfByParams(params)`.
  ///
  /// ```dart
  /// ToolInfo.fromParams(
  ///   name: 'get_weather',
  ///   desc: 'Current weather for a city',
  ///   params: {
  ///     'city': ParameterInfo(type: DataType.string, required: true),
  ///   },
  /// );
  /// ```
  factory ToolInfo.fromParams({
    required String name,
    required Map<String, ParameterInfo> params,
    String? desc,
    Map<String, dynamic>? extra,
  }) =>
      ToolInfo.fromJsonSchema(
        name: name,
        desc: desc,
        schema: ParamsOneOf.params(params).toJsonSchema(),
        extra: extra,
      );

  /// Create a tool info whose parameters are given as a JSON schema.
  ///
  /// Port of a Go `ToolInfo` literal with
  /// `schema.NewParamsOneOfByJSONSchema(schema)`.
  factory ToolInfo.fromJsonSchema({
    required String name,
    required JSONSchema schema,
    String? desc,
    Map<String, dynamic>? extra,
  }) =>
      ToolInfo(
        function: FunctionInfo(
          name: name,
          description: desc,
          parameters: schema,
        ),
        extra: extra,
      );

  /// Create a tool info whose parameters are a JSON Schema document, kept
  /// exactly as given.
  ///
  /// Port of a Go `ToolInfo` literal with
  /// `schema.NewParamsOneOfByJSONSchema(schema)` for a schema that
  /// [JSONSchema] cannot hold: every keyword survives (`anyOf`, `oneOf`,
  /// `$ref`, `$defs`, `format`, `default`, `minimum`, …), and providers send
  /// [schema] as it is (see [FunctionInfo.parametersJsonSchema]). MCP tools
  /// are built this way.
  ///
  /// The map is copied, so later changes to [schema] do not reach the tool
  /// info. [FunctionInfo.parameters] gets the part of [schema] that
  /// [JSONSchema] can describe: the type (`object` when the schema names
  /// none), the properties, `required` and a boolean `additionalProperties`.
  /// A property without a `type` takes the type of its first `anyOf`,
  /// `oneOf` or `allOf` branch that has one, or is inferred from its
  /// keywords (`string` when nothing tells).
  ///
  /// Throws a [ThreepioFormatException] when [schema] or the schema of a
  /// property is not a JSON object (a property may also be `true`/`false`),
  /// or when [schema] holds something that is not JSON (a value other than
  /// `null`, a bool, a finite number, a string, a list or a map with string
  /// keys).
  factory ToolInfo.fromJsonSchemaMap({
    required String name,
    required Map<String, Object?> schema,
    String? desc,
    Map<String, dynamic>? extra,
  }) {
    final copy = _copyJsonObject(schema, r'$');
    return ToolInfo(
      function: FunctionInfo(
        name: name,
        description: desc,
        parameters: _lenientJsonSchema(copy),
        parametersJsonSchema: copy,
      ),
      extra: extra,
    );
  }

  /// Create a tool info whose parameters are [params], in whichever form
  /// they were given; `null` makes a tool without parameters.
  ///
  /// Port of a Go `ToolInfo{Name: name, Desc: desc, ParamsOneOf: params}`
  /// literal. A [ParamsOneOf.jsonSchemaMap] keeps its document (as
  /// [ToolInfo.fromJsonSchemaMap] does, which copies it); the other forms
  /// are stored as [ParamsOneOf.toJsonSchema] gives them (as
  /// [ToolInfo.fromParams] and [ToolInfo.fromJsonSchema] do). Code that takes
  /// a [ParamsOneOf] and builds the tool info from it uses this, so that no
  /// keyword of a JSON Schema document is lost.
  ///
  /// Throws a [ThreepioFormatException] when a JSON Schema document cannot
  /// be read (see [ToolInfo.fromJsonSchemaMap]).
  factory ToolInfo.fromParamsOneOf({
    required String name,
    ParamsOneOf? params,
    String? desc,
    Map<String, dynamic>? extra,
  }) {
    if (params == null) {
      return ToolInfo(
        function: FunctionInfo(name: name, description: desc),
        extra: extra,
      );
    }
    final document = params.jsonSchemaMap;
    if (document != null) {
      return ToolInfo.fromJsonSchemaMap(
        name: name,
        desc: desc,
        schema: document,
        extra: extra,
      );
    }
    return ToolInfo.fromJsonSchema(
      name: name,
      desc: desc,
      schema: params.toJsonSchema(),
      extra: extra,
    );
  }

  /// The unique name of the tool (Eino: `ToolInfo.Name`).
  String get name => function.name;

  /// What the tool does and when to use it (Eino: `ToolInfo.Desc`).
  String? get desc => function.description;

  /// The parameters of the tool, or `null` when it takes none (Eino:
  /// `ToolInfo.ParamsOneOf`).
  ///
  /// A tool info made with [ToolInfo.fromJsonSchemaMap] answers with the
  /// [ParamsOneOf.jsonSchemaMap] form, every other one with the
  /// [ParamsOneOf.jsonSchema] form.
  ParamsOneOf? get paramsOneOf {
    final raw = function.parametersJsonSchema;
    if (raw != null) return ParamsOneOf.jsonSchemaMap(raw);
    final parameters = function.parameters;
    return parameters == null ? null : ParamsOneOf.jsonSchema(parameters);
  }

  /// Create a tool info from function details
  factory ToolInfo.function({
    required String name,
    String? description,
    JSONSchema? parameters,
    bool? strict,
  }) =>
      ToolInfo(
        type: 'function',
        function: FunctionInfo(
          name: name,
          description: description,
          parameters: parameters,
          strict: strict,
        ),
      );

  /// Create a tool info with simple parameters
  factory ToolInfo.simple({
    required String name,
    required String description,
    required Map<String, JSONSchemaProperty> properties,
    List<String>? required,
  }) =>
      ToolInfo(
        function: FunctionInfo(
          name: name,
          description: description,
          parameters: JSONSchema(
            properties: properties,
            required: required ?? [],
          ),
        ),
      );
}

/// Builder for creating tool info with fluent API
class ToolInfoBuilder {
  String? _name;
  String? _description;
  final Map<String, JSONSchemaProperty> _properties = {};
  final List<String> _required = [];

  /// Set the tool name
  ToolInfoBuilder name(String name) {
    _name = name;
    return this;
  }

  /// Set the tool description
  ToolInfoBuilder description(String description) {
    _description = description;
    return this;
  }

  /// Add a string parameter
  ToolInfoBuilder addStringParam(
    String name, {
    required String description,
    bool required = false,
    List<String>? enumValues,
  }) {
    _properties[name] = JSONSchemaProperty.string(
      description: description,
      enumValues: enumValues,
    );
    if (required) _required.add(name);
    return this;
  }

  /// Add a number parameter
  ToolInfoBuilder addNumberParam(
    String name, {
    required String description,
    bool required = false,
  }) {
    _properties[name] = JSONSchemaProperty.number(description: description);
    if (required) _required.add(name);
    return this;
  }

  /// Add a boolean parameter
  ToolInfoBuilder addBooleanParam(
    String name, {
    required String description,
    bool required = false,
  }) {
    _properties[name] = JSONSchemaProperty.boolean(description: description);
    if (required) _required.add(name);
    return this;
  }

  /// Add an array parameter
  ToolInfoBuilder addArrayParam(
    String name, {
    required String description,
    required JSONSchemaProperty items,
    bool required = false,
  }) {
    _properties[name] = JSONSchemaProperty.array(
      description: description,
      items: items,
    );
    if (required) _required.add(name);
    return this;
  }

  /// Add an object parameter
  ToolInfoBuilder addObjectParam(
    String name, {
    required String description,
    required Map<String, JSONSchemaProperty> properties,
    List<String>? requiredFields,
    bool required = false,
  }) {
    _properties[name] = JSONSchemaProperty.object(
      description: description,
      properties: properties,
      required: requiredFields,
    );
    if (required) _required.add(name);
    return this;
  }

  /// Build the ToolInfo
  ToolInfo build() {
    if (_name == null) {
      throw StateError('Tool name is required');
    }

    return ToolInfo.simple(
      name: _name!,
      description: _description ?? '',
      properties: _properties,
      required: _required,
    );
  }
}

/// The type of a tool parameter, as in JSON Schema.
///
/// Port of eino `schema.DataType`.
enum DataType {
  object('object'),
  number('number'),
  integer('integer'),
  string('string'),
  array('array'),

  /// The JSON Schema type `null`.
  nullValue('null'),
  boolean('boolean');

  const DataType(this.value);

  /// The name of the type in JSON Schema.
  final String value;

  /// The data type JSON Schema calls [value].
  static DataType parse(String value) => values.firstWhere(
        (type) => type.value == value,
        orElse: () =>
            throw ThreepioFormatException('Unknown data type "$value"'),
      );
}

/// Describes one parameter of a tool.
///
/// Port of eino `schema.ParameterInfo`: the light-weight way to describe
/// parameters, turned into a JSON schema by [ParamsOneOf.toJsonSchema].
@immutable
final class ParameterInfo {
  const ParameterInfo({
    required this.type,
    this.elemInfo,
    this.subParams,
    this.desc,
    this.enumValues,
    this.required = false,
  });

  /// Reads the map written by [toJson].
  factory ParameterInfo.fromJson(Map<String, Object?> json) => ParameterInfo(
        type: DataType.parse(json['type']! as String),
        elemInfo: switch (json['elemInfo']) {
          final Map<String, Object?> elem => ParameterInfo.fromJson(elem),
          _ => null,
        },
        subParams: switch (json['subParams']) {
          final Map<String, Object?> sub => {
              for (final MapEntry(:key, :value) in sub.entries)
                key: ParameterInfo.fromJson(value! as Map<String, Object?>),
            },
          _ => null,
        },
        desc: json['desc'] as String?,
        enumValues: (json['enum'] as List<Object?>?)?.cast<String>(),
        required: json['required'] as bool? ?? false,
      );

  /// The type of the parameter.
  final DataType type;

  /// The type of the elements; only for [DataType.array].
  final ParameterInfo? elemInfo;

  /// The fields of the parameter; only for [DataType.object].
  final Map<String, ParameterInfo>? subParams;

  /// What the parameter means.
  final String? desc;

  /// The values the parameter may take; only for [DataType.string].
  final List<String>? enumValues;

  /// Whether the model has to give the parameter.
  final bool required;

  /// The JSON schema of this parameter. Fields come out sorted by name, so
  /// the same description always gives the same schema.
  JSONSchemaProperty toJsonSchemaProperty() {
    final subParams = this.subParams;
    final enumValues = this.enumValues;
    final hasFields = subParams != null && subParams.isNotEmpty;
    return JSONSchemaProperty(
      type: type.value,
      description: desc,
      enumValues:
          enumValues == null || enumValues.isEmpty ? null : [...enumValues],
      items: elemInfo?.toJsonSchemaProperty(),
      properties: hasFields ? _propertiesOf(subParams) : null,
      required: hasFields ? _requiredOf(subParams) : null,
    );
  }

  /// A JSON-compatible map; [ParameterInfo.fromJson] reads it back.
  Map<String, Object?> toJson() => {
        'type': type.value,
        if (elemInfo != null) 'elemInfo': elemInfo!.toJson(),
        if (subParams != null)
          'subParams': {
            for (final MapEntry(:key, :value) in subParams!.entries)
              key: value.toJson(),
          },
        if (desc != null) 'desc': desc,
        if (enumValues != null) 'enum': enumValues,
        if (required) 'required': true,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParameterInfo &&
          other.type == type &&
          other.elemInfo == elemInfo &&
          const MapEquality<String, ParameterInfo>()
              .equals(other.subParams, subParams) &&
          other.desc == desc &&
          const ListEquality<String>().equals(other.enumValues, enumValues) &&
          other.required == required;

  @override
  int get hashCode => Object.hash(
        type,
        elemInfo,
        const MapEquality<String, ParameterInfo>().hash(subParams),
        desc,
        const ListEquality<String>().hash(enumValues),
        required,
      );

  @override
  String toString() => 'ParameterInfo(${toJson()})';
}

Map<String, JSONSchemaProperty> _propertiesOf(
  Map<String, ParameterInfo> params,
) =>
    {
      for (final name in params.keys.toList()..sort())
        name: params[name]!.toJsonSchemaProperty(),
    };

List<String> _requiredOf(Map<String, ParameterInfo> params) => [
      for (final name in params.keys.toList()..sort())
        if (params[name]!.required) name,
    ];

/// The parameters of a tool, described in exactly one of two ways.
///
/// Port of eino `schema.ParamsOneOf`:
///
/// * [ParamsOneOf.params] (Go: `NewParamsOneOfByParams`): a map of
///   [ParameterInfo]s. Enough for scalars, arrays, nested objects, enums and
///   required flags.
/// * [ParamsOneOf.jsonSchema] (Go: `NewParamsOneOfByJSONSchema`): a complete
///   [JSONSchema].
/// * [ParamsOneOf.jsonSchemaMap] (Go: `NewParamsOneOfByJSONSchema` as well):
///   a JSON Schema document as a map, kept exactly as given, for schemas
///   that use keywords [JSONSchema] has no field for.
///
/// A tool without parameters has no `ParamsOneOf` at all.
@immutable
sealed class ParamsOneOf {
  const ParamsOneOf._();

  /// Parameters described one by one.
  const factory ParamsOneOf.params(Map<String, ParameterInfo> params) =
      _ParamsByInfo;

  /// Parameters given as a JSON schema.
  const factory ParamsOneOf.jsonSchema(JSONSchema schema) = _ParamsBySchema;

  /// Parameters given as a JSON Schema document, kept exactly as given.
  ///
  /// Port of `schema.NewParamsOneOfByJSONSchema` for any schema: `anyOf`,
  /// `$ref`, `$defs`, `format`, `default` and every other keyword survive.
  /// [ToolInfo.fromJsonSchemaMap] makes a tool info with such parameters;
  /// [toJsonSchema] gives the part of the document [JSONSchema] can
  /// describe.
  ///
  /// The map is used as it is; [ToolInfo.fromJsonSchemaMap] copies it.
  const factory ParamsOneOf.jsonSchemaMap(Map<String, Object?> schema) =
      _ParamsByJsonSchemaMap;

  /// Reads the map written by [toJson].
  factory ParamsOneOf.fromJson(Map<String, Object?> json) {
    final map = json['jsonSchemaMap'];
    if (map is Map<String, Object?>) {
      return ParamsOneOf.jsonSchemaMap(map);
    }
    final schema = json['jsonSchema'];
    if (schema is Map<String, Object?>) {
      return ParamsOneOf.jsonSchema(JSONSchema.fromJson(schema));
    }
    // An empty description is still a description: no key at all means the
    // params form with no parameters.
    final params = json['params'] as Map<String, Object?>? ?? const {};
    return ParamsOneOf.params({
      for (final MapEntry(:key, :value) in params.entries)
        key: ParameterInfo.fromJson(value! as Map<String, Object?>),
    });
  }

  /// The parameter descriptions, when this was made with
  /// [ParamsOneOf.params].
  Map<String, ParameterInfo>? get params;

  /// The schema, when this was made with [ParamsOneOf.jsonSchema].
  JSONSchema? get jsonSchema;

  /// The JSON Schema document, when this was made with
  /// [ParamsOneOf.jsonSchemaMap].
  Map<String, Object?>? get jsonSchemaMap;

  /// The schema to give to a model.
  ///
  /// Port of eino `ParamsOneOf.ToJSONSchema`: a schema that was given is
  /// returned as it is; parameter descriptions become an object schema whose
  /// properties are sorted by name. For a [ParamsOneOf.jsonSchemaMap] it is
  /// the part of the document that [JSONSchema] can describe (see
  /// [ToolInfo.fromJsonSchemaMap]); the document itself is [jsonSchemaMap].
  /// Throws a [ThreepioFormatException] when that document cannot be read
  /// as a schema.
  JSONSchema toJsonSchema();

  /// A JSON-compatible map; [ParamsOneOf.fromJson] reads it back.
  Map<String, Object?> toJson();
}

final class _ParamsByInfo extends ParamsOneOf {
  const _ParamsByInfo(this.params) : super._();

  @override
  final Map<String, ParameterInfo> params;

  @override
  JSONSchema? get jsonSchema => null;

  @override
  Map<String, Object?>? get jsonSchemaMap => null;

  @override
  JSONSchema toJsonSchema() => JSONSchema(
        properties: _propertiesOf(params),
        required: _requiredOf(params),
      );

  @override
  Map<String, Object?> toJson() => {
        'params': {
          for (final MapEntry(:key, :value) in params.entries)
            key: value.toJson(),
        },
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ParamsByInfo &&
          const MapEquality<String, ParameterInfo>()
              .equals(other.params, params);

  @override
  int get hashCode => const MapEquality<String, ParameterInfo>().hash(params);

  @override
  String toString() => 'ParamsOneOf.params($params)';
}

final class _ParamsBySchema extends ParamsOneOf {
  const _ParamsBySchema(this.jsonSchema) : super._();

  @override
  final JSONSchema jsonSchema;

  @override
  Map<String, ParameterInfo>? get params => null;

  @override
  Map<String, Object?>? get jsonSchemaMap => null;

  @override
  JSONSchema toJsonSchema() => jsonSchema;

  @override
  Map<String, Object?> toJson() => {'jsonSchema': jsonSchema.toJson()};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ParamsBySchema && other.jsonSchema == jsonSchema;

  @override
  int get hashCode => jsonSchema.hashCode;

  @override
  String toString() => 'ParamsOneOf.jsonSchema($jsonSchema)';
}

final class _ParamsByJsonSchemaMap extends ParamsOneOf {
  const _ParamsByJsonSchemaMap(this.jsonSchemaMap) : super._();

  @override
  final Map<String, Object?> jsonSchemaMap;

  @override
  Map<String, ParameterInfo>? get params => null;

  @override
  JSONSchema? get jsonSchema => null;

  @override
  JSONSchema toJsonSchema() => _lenientJsonSchema(jsonSchemaMap);

  @override
  Map<String, Object?> toJson() => {'jsonSchemaMap': jsonSchemaMap};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ParamsByJsonSchemaMap &&
          const DeepCollectionEquality()
              .equals(other.jsonSchemaMap, jsonSchemaMap);

  @override
  int get hashCode => const DeepCollectionEquality().hash(jsonSchemaMap);

  @override
  String toString() => 'ParamsOneOf.jsonSchemaMap($jsonSchemaMap)';
}

// ---------------------------------------------------------------------------
// JSON Schema documents
// ---------------------------------------------------------------------------

/// A deep copy of the JSON object [value], with unmodifiable maps and lists.
Map<String, Object?> _copyJsonObject(Map<String, Object?> value, String path) =>
    Map.unmodifiable({
      for (final MapEntry(:key, value: entry) in value.entries)
        key: _copyJson(entry, '$path.$key'),
    });

Object? _copyJson(Object? value, String path) => switch (value) {
      // NaN and the infinities have no JSON form.
      final double number when !number.isFinite => throw ThreepioFormatException(
          'the JSON schema holds a number that is not JSON at $path: $number',
        ),
      null || bool() || num() || String() => value,
      final Map<String, Object?> map => _copyJsonObject(map, path),
      final Map<Object?, Object?> map when map.keys.every((k) => k is String) =>
        _copyJsonObject(map.cast<String, Object?>(), path),
      final List<Object?> list => List<Object?>.unmodifiable([
          for (var i = 0; i < list.length; i++) _copyJson(list[i], '$path[$i]'),
        ]),
      _ => throw ThreepioFormatException(
          'the JSON schema holds a value that is not JSON at $path: '
          '${value.runtimeType}',
        ),
    };

/// The part of the JSON Schema document [raw] that [JSONSchema] can hold.
JSONSchema _lenientJsonSchema(Map<String, Object?> raw) {
  final properties = raw['properties'];
  final additional = raw['additionalProperties'];
  return JSONSchema(
    type: _schemaType(raw) ?? 'object',
    properties: properties is Map<String, Object?>
        ? {
            for (final MapEntry(:key, :value) in properties.entries)
              key: _lenientProperty(value, key),
          }
        : const {},
    required: _stringList(raw['required']),
    additionalProperties: additional is bool && additional,
  );
}

JSONSchemaProperty _lenientProperty(Object? raw, String name) {
  if (raw is bool) return const JSONSchemaProperty(type: 'string');
  if (raw is! Map<String, Object?>) {
    throw ThreepioFormatException(
      'the schema of property "$name" is not an object',
    );
  }
  final properties = raw['properties'];
  final items = raw['items'];
  final enumValues = raw['enum'];
  final additional = raw['additionalProperties'];
  final description = raw['description'];
  final required = raw['required'];
  return JSONSchemaProperty(
    type: _schemaType(raw) ?? 'string',
    description: description is String ? description : null,
    enumValues: enumValues is List<Object?> ? [...enumValues] : null,
    items: items is Map<String, Object?>
        ? _lenientProperty(items, '$name[]')
        : null,
    properties: properties is Map<String, Object?>
        ? {
            for (final MapEntry(:key, :value) in properties.entries)
              key: _lenientProperty(value, '$name.$key'),
          }
        : null,
    required: required is List<Object?> ? _stringList(required) : null,
    additionalProperties: additional is bool ? additional : null,
  );
}

/// The type a schema names, the first non-null type of a type list, the type
/// of its first `anyOf`/`oneOf`/`allOf` branch that has one, or what its
/// keywords imply; `null` when nothing tells.
String? _schemaType(Map<String, Object?> schema) {
  final type = schema['type'];
  if (type is String) return type;
  if (type is List<Object?>) {
    for (final entry in type) {
      if (entry is String && entry != 'null') return entry;
    }
  }
  for (final key in const ['anyOf', 'oneOf', 'allOf']) {
    final branches = schema[key];
    if (branches is List<Object?>) {
      for (final branch in branches) {
        if (branch is Map<String, Object?>) {
          final branchType = _schemaType(branch);
          if (branchType != null && branchType != 'null') return branchType;
        }
      }
    }
  }
  if (schema['properties'] is Map) return 'object';
  if (schema['items'] != null) return 'array';
  return null;
}

List<String> _stringList(Object? raw) =>
    raw is List<Object?> ? [for (final e in raw) if (e is String) e] : const [];

/// The tools a tool search found.
///
/// Port of eino `schema.ToolSearchResult`. When a model asks to search for
/// tools, the answer carries the full definitions of the matching tools that
/// were not bound yet, so that the model can call them.
@freezed
abstract class ToolSearchResult with _$ToolSearchResult {
  const factory ToolSearchResult({
    /// Definitions of the tools that were found
    @Default([]) List<ToolInfo> tools,
  }) = _ToolSearchResult;

  factory ToolSearchResult.fromJson(Map<String, dynamic> json) =>
      _$ToolSearchResultFromJson(json);
}
