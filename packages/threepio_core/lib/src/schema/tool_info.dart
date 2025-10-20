import 'package:freezed_annotation/freezed_annotation.dart';

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
class JSONSchemaProperty with _$JSONSchemaProperty {
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
class JSONSchema with _$JSONSchema {
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
class FunctionInfo with _$FunctionInfo {
  const factory FunctionInfo({
    /// Name of the function
    required String name,

    /// Description of what the function does
    String? description,

    /// Parameters schema
    JSONSchema? parameters,

    /// Whether the function is strict (OpenAI specific)
    bool? strict,
  }) = _FunctionInfo;

  factory FunctionInfo.fromJson(Map<String, dynamic> json) =>
      _$FunctionInfoFromJson(json);
}

/// Tool information for LLM tool calling
@freezed
class ToolInfo with _$ToolInfo {
  const factory ToolInfo({
    /// Tool type (typically "function")
    @Default('function') String type,

    /// Function information
    required FunctionInfo function,
  }) = _ToolInfo;

  const ToolInfo._();

  factory ToolInfo.fromJson(Map<String, dynamic> json) =>
      _$ToolInfoFromJson(json);

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
