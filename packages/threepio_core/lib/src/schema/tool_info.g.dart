// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tool_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_JSONSchemaProperty _$JSONSchemaPropertyFromJson(Map<String, dynamic> json) =>
    _JSONSchemaProperty(
      type: json['type'] as String,
      description: json['description'] as String?,
      enumValues: json['enumValues'] as List<dynamic>?,
      items: json['items'] == null
          ? null
          : JSONSchemaProperty.fromJson(json['items'] as Map<String, dynamic>),
      properties: (json['properties'] as Map<String, dynamic>?)?.map(
        (k, e) =>
            MapEntry(k, JSONSchemaProperty.fromJson(e as Map<String, dynamic>)),
      ),
      required: (json['required'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      additionalProperties: json['additionalProperties'] as bool?,
    );

Map<String, dynamic> _$JSONSchemaPropertyToJson(_JSONSchemaProperty instance) =>
    <String, dynamic>{
      'type': instance.type,
      'description': instance.description,
      'enumValues': instance.enumValues,
      'items': instance.items?.toJson(),
      'properties': instance.properties?.map((k, e) => MapEntry(k, e.toJson())),
      'required': instance.required,
      'additionalProperties': instance.additionalProperties,
    };

_JSONSchema _$JSONSchemaFromJson(Map<String, dynamic> json) => _JSONSchema(
      type: json['type'] as String? ?? 'object',
      properties: (json['properties'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(
                k, JSONSchemaProperty.fromJson(e as Map<String, dynamic>)),
          ) ??
          const {},
      required: (json['required'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      additionalProperties: json['additionalProperties'] as bool? ?? false,
    );

Map<String, dynamic> _$JSONSchemaToJson(_JSONSchema instance) =>
    <String, dynamic>{
      'type': instance.type,
      'properties': instance.properties.map((k, e) => MapEntry(k, e.toJson())),
      'required': instance.required,
      'additionalProperties': instance.additionalProperties,
    };

_FunctionInfo _$FunctionInfoFromJson(Map<String, dynamic> json) =>
    _FunctionInfo(
      name: json['name'] as String,
      description: json['description'] as String?,
      parameters: json['parameters'] == null
          ? null
          : JSONSchema.fromJson(json['parameters'] as Map<String, dynamic>),
      strict: json['strict'] as bool?,
    );

Map<String, dynamic> _$FunctionInfoToJson(_FunctionInfo instance) =>
    <String, dynamic>{
      'name': instance.name,
      'description': instance.description,
      'parameters': instance.parameters?.toJson(),
      'strict': instance.strict,
    };

_ToolInfo _$ToolInfoFromJson(Map<String, dynamic> json) => _ToolInfo(
      type: json['type'] as String? ?? 'function',
      function: FunctionInfo.fromJson(json['function'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$ToolInfoToJson(_ToolInfo instance) => <String, dynamic>{
      'type': instance.type,
      'function': instance.function.toJson(),
    };
