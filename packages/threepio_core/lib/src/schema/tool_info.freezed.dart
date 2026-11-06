// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'tool_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$JSONSchemaProperty {

/// Property type (string, number, boolean, object, array, etc.)
 String get type;/// Property description
 String? get description;/// Enum values (if applicable)
 List<dynamic>? get enumValues;/// Items schema (for array type)
 JSONSchemaProperty? get items;/// Properties (for object type)
 Map<String, JSONSchemaProperty>? get properties;/// Required properties (for object type)
 List<String>? get required;/// Additional properties flag
 bool? get additionalProperties;
/// Create a copy of JSONSchemaProperty
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$JSONSchemaPropertyCopyWith<JSONSchemaProperty> get copyWith => _$JSONSchemaPropertyCopyWithImpl<JSONSchemaProperty>(this as JSONSchemaProperty, _$identity);

  /// Serializes this JSONSchemaProperty to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is JSONSchemaProperty&&(identical(other.type, type) || other.type == type)&&(identical(other.description, description) || other.description == description)&&const DeepCollectionEquality().equals(other.enumValues, enumValues)&&(identical(other.items, items) || other.items == items)&&const DeepCollectionEquality().equals(other.properties, properties)&&const DeepCollectionEquality().equals(other.required, required)&&(identical(other.additionalProperties, additionalProperties) || other.additionalProperties == additionalProperties));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,description,const DeepCollectionEquality().hash(enumValues),items,const DeepCollectionEquality().hash(properties),const DeepCollectionEquality().hash(required),additionalProperties);

@override
String toString() {
  return 'JSONSchemaProperty(type: $type, description: $description, enumValues: $enumValues, items: $items, properties: $properties, required: $required, additionalProperties: $additionalProperties)';
}


}

/// @nodoc
abstract mixin class $JSONSchemaPropertyCopyWith<$Res>  {
  factory $JSONSchemaPropertyCopyWith(JSONSchemaProperty value, $Res Function(JSONSchemaProperty) _then) = _$JSONSchemaPropertyCopyWithImpl;
@useResult
$Res call({
 String type, String? description, List<dynamic>? enumValues, JSONSchemaProperty? items, Map<String, JSONSchemaProperty>? properties, List<String>? required, bool? additionalProperties
});


$JSONSchemaPropertyCopyWith<$Res>? get items;

}
/// @nodoc
class _$JSONSchemaPropertyCopyWithImpl<$Res>
    implements $JSONSchemaPropertyCopyWith<$Res> {
  _$JSONSchemaPropertyCopyWithImpl(this._self, this._then);

  final JSONSchemaProperty _self;
  final $Res Function(JSONSchemaProperty) _then;

/// Create a copy of JSONSchemaProperty
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? type = null,Object? description = freezed,Object? enumValues = freezed,Object? items = freezed,Object? properties = freezed,Object? required = freezed,Object? additionalProperties = freezed,}) {
  return _then(_self.copyWith(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,enumValues: freezed == enumValues ? _self.enumValues : enumValues // ignore: cast_nullable_to_non_nullable
as List<dynamic>?,items: freezed == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as JSONSchemaProperty?,properties: freezed == properties ? _self.properties : properties // ignore: cast_nullable_to_non_nullable
as Map<String, JSONSchemaProperty>?,required: freezed == required ? _self.required : required // ignore: cast_nullable_to_non_nullable
as List<String>?,additionalProperties: freezed == additionalProperties ? _self.additionalProperties : additionalProperties // ignore: cast_nullable_to_non_nullable
as bool?,
  ));
}
/// Create a copy of JSONSchemaProperty
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$JSONSchemaPropertyCopyWith<$Res>? get items {
    if (_self.items == null) {
    return null;
  }

  return $JSONSchemaPropertyCopyWith<$Res>(_self.items!, (value) {
    return _then(_self.copyWith(items: value));
  });
}
}


/// Adds pattern-matching-related methods to [JSONSchemaProperty].
extension JSONSchemaPropertyPatterns on JSONSchemaProperty {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _JSONSchemaProperty value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _JSONSchemaProperty() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _JSONSchemaProperty value)  $default,){
final _that = this;
switch (_that) {
case _JSONSchemaProperty():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _JSONSchemaProperty value)?  $default,){
final _that = this;
switch (_that) {
case _JSONSchemaProperty() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String type,  String? description,  List<dynamic>? enumValues,  JSONSchemaProperty? items,  Map<String, JSONSchemaProperty>? properties,  List<String>? required,  bool? additionalProperties)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _JSONSchemaProperty() when $default != null:
return $default(_that.type,_that.description,_that.enumValues,_that.items,_that.properties,_that.required,_that.additionalProperties);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String type,  String? description,  List<dynamic>? enumValues,  JSONSchemaProperty? items,  Map<String, JSONSchemaProperty>? properties,  List<String>? required,  bool? additionalProperties)  $default,) {final _that = this;
switch (_that) {
case _JSONSchemaProperty():
return $default(_that.type,_that.description,_that.enumValues,_that.items,_that.properties,_that.required,_that.additionalProperties);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String type,  String? description,  List<dynamic>? enumValues,  JSONSchemaProperty? items,  Map<String, JSONSchemaProperty>? properties,  List<String>? required,  bool? additionalProperties)?  $default,) {final _that = this;
switch (_that) {
case _JSONSchemaProperty() when $default != null:
return $default(_that.type,_that.description,_that.enumValues,_that.items,_that.properties,_that.required,_that.additionalProperties);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _JSONSchemaProperty implements JSONSchemaProperty {
  const _JSONSchemaProperty({required this.type, this.description, final  List<dynamic>? enumValues, this.items, final  Map<String, JSONSchemaProperty>? properties, final  List<String>? required, this.additionalProperties}): _enumValues = enumValues,_properties = properties,_required = required;
  factory _JSONSchemaProperty.fromJson(Map<String, dynamic> json) => _$JSONSchemaPropertyFromJson(json);

/// Property type (string, number, boolean, object, array, etc.)
@override final  String type;
/// Property description
@override final  String? description;
/// Enum values (if applicable)
 final  List<dynamic>? _enumValues;
/// Enum values (if applicable)
@override List<dynamic>? get enumValues {
  final value = _enumValues;
  if (value == null) return null;
  if (_enumValues is EqualUnmodifiableListView) return _enumValues;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

/// Items schema (for array type)
@override final  JSONSchemaProperty? items;
/// Properties (for object type)
 final  Map<String, JSONSchemaProperty>? _properties;
/// Properties (for object type)
@override Map<String, JSONSchemaProperty>? get properties {
  final value = _properties;
  if (value == null) return null;
  if (_properties is EqualUnmodifiableMapView) return _properties;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}

/// Required properties (for object type)
 final  List<String>? _required;
/// Required properties (for object type)
@override List<String>? get required {
  final value = _required;
  if (value == null) return null;
  if (_required is EqualUnmodifiableListView) return _required;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

/// Additional properties flag
@override final  bool? additionalProperties;

/// Create a copy of JSONSchemaProperty
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$JSONSchemaPropertyCopyWith<_JSONSchemaProperty> get copyWith => __$JSONSchemaPropertyCopyWithImpl<_JSONSchemaProperty>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$JSONSchemaPropertyToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _JSONSchemaProperty&&(identical(other.type, type) || other.type == type)&&(identical(other.description, description) || other.description == description)&&const DeepCollectionEquality().equals(other._enumValues, _enumValues)&&(identical(other.items, items) || other.items == items)&&const DeepCollectionEquality().equals(other._properties, _properties)&&const DeepCollectionEquality().equals(other._required, _required)&&(identical(other.additionalProperties, additionalProperties) || other.additionalProperties == additionalProperties));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,description,const DeepCollectionEquality().hash(_enumValues),items,const DeepCollectionEquality().hash(_properties),const DeepCollectionEquality().hash(_required),additionalProperties);

@override
String toString() {
  return 'JSONSchemaProperty(type: $type, description: $description, enumValues: $enumValues, items: $items, properties: $properties, required: $required, additionalProperties: $additionalProperties)';
}


}

/// @nodoc
abstract mixin class _$JSONSchemaPropertyCopyWith<$Res> implements $JSONSchemaPropertyCopyWith<$Res> {
  factory _$JSONSchemaPropertyCopyWith(_JSONSchemaProperty value, $Res Function(_JSONSchemaProperty) _then) = __$JSONSchemaPropertyCopyWithImpl;
@override @useResult
$Res call({
 String type, String? description, List<dynamic>? enumValues, JSONSchemaProperty? items, Map<String, JSONSchemaProperty>? properties, List<String>? required, bool? additionalProperties
});


@override $JSONSchemaPropertyCopyWith<$Res>? get items;

}
/// @nodoc
class __$JSONSchemaPropertyCopyWithImpl<$Res>
    implements _$JSONSchemaPropertyCopyWith<$Res> {
  __$JSONSchemaPropertyCopyWithImpl(this._self, this._then);

  final _JSONSchemaProperty _self;
  final $Res Function(_JSONSchemaProperty) _then;

/// Create a copy of JSONSchemaProperty
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? description = freezed,Object? enumValues = freezed,Object? items = freezed,Object? properties = freezed,Object? required = freezed,Object? additionalProperties = freezed,}) {
  return _then(_JSONSchemaProperty(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,enumValues: freezed == enumValues ? _self._enumValues : enumValues // ignore: cast_nullable_to_non_nullable
as List<dynamic>?,items: freezed == items ? _self.items : items // ignore: cast_nullable_to_non_nullable
as JSONSchemaProperty?,properties: freezed == properties ? _self._properties : properties // ignore: cast_nullable_to_non_nullable
as Map<String, JSONSchemaProperty>?,required: freezed == required ? _self._required : required // ignore: cast_nullable_to_non_nullable
as List<String>?,additionalProperties: freezed == additionalProperties ? _self.additionalProperties : additionalProperties // ignore: cast_nullable_to_non_nullable
as bool?,
  ));
}

/// Create a copy of JSONSchemaProperty
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$JSONSchemaPropertyCopyWith<$Res>? get items {
    if (_self.items == null) {
    return null;
  }

  return $JSONSchemaPropertyCopyWith<$Res>(_self.items!, (value) {
    return _then(_self.copyWith(items: value));
  });
}
}


/// @nodoc
mixin _$JSONSchema {

/// Schema type (always "object" for function parameters)
 String get type;/// Properties of the schema
 Map<String, JSONSchemaProperty> get properties;/// Required properties
 List<String> get required;/// Allow additional properties
 bool get additionalProperties;
/// Create a copy of JSONSchema
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$JSONSchemaCopyWith<JSONSchema> get copyWith => _$JSONSchemaCopyWithImpl<JSONSchema>(this as JSONSchema, _$identity);

  /// Serializes this JSONSchema to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is JSONSchema&&(identical(other.type, type) || other.type == type)&&const DeepCollectionEquality().equals(other.properties, properties)&&const DeepCollectionEquality().equals(other.required, required)&&(identical(other.additionalProperties, additionalProperties) || other.additionalProperties == additionalProperties));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,const DeepCollectionEquality().hash(properties),const DeepCollectionEquality().hash(required),additionalProperties);

@override
String toString() {
  return 'JSONSchema(type: $type, properties: $properties, required: $required, additionalProperties: $additionalProperties)';
}


}

/// @nodoc
abstract mixin class $JSONSchemaCopyWith<$Res>  {
  factory $JSONSchemaCopyWith(JSONSchema value, $Res Function(JSONSchema) _then) = _$JSONSchemaCopyWithImpl;
@useResult
$Res call({
 String type, Map<String, JSONSchemaProperty> properties, List<String> required, bool additionalProperties
});




}
/// @nodoc
class _$JSONSchemaCopyWithImpl<$Res>
    implements $JSONSchemaCopyWith<$Res> {
  _$JSONSchemaCopyWithImpl(this._self, this._then);

  final JSONSchema _self;
  final $Res Function(JSONSchema) _then;

/// Create a copy of JSONSchema
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? type = null,Object? properties = null,Object? required = null,Object? additionalProperties = null,}) {
  return _then(_self.copyWith(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,properties: null == properties ? _self.properties : properties // ignore: cast_nullable_to_non_nullable
as Map<String, JSONSchemaProperty>,required: null == required ? _self.required : required // ignore: cast_nullable_to_non_nullable
as List<String>,additionalProperties: null == additionalProperties ? _self.additionalProperties : additionalProperties // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [JSONSchema].
extension JSONSchemaPatterns on JSONSchema {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _JSONSchema value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _JSONSchema() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _JSONSchema value)  $default,){
final _that = this;
switch (_that) {
case _JSONSchema():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _JSONSchema value)?  $default,){
final _that = this;
switch (_that) {
case _JSONSchema() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String type,  Map<String, JSONSchemaProperty> properties,  List<String> required,  bool additionalProperties)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _JSONSchema() when $default != null:
return $default(_that.type,_that.properties,_that.required,_that.additionalProperties);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String type,  Map<String, JSONSchemaProperty> properties,  List<String> required,  bool additionalProperties)  $default,) {final _that = this;
switch (_that) {
case _JSONSchema():
return $default(_that.type,_that.properties,_that.required,_that.additionalProperties);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String type,  Map<String, JSONSchemaProperty> properties,  List<String> required,  bool additionalProperties)?  $default,) {final _that = this;
switch (_that) {
case _JSONSchema() when $default != null:
return $default(_that.type,_that.properties,_that.required,_that.additionalProperties);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _JSONSchema implements JSONSchema {
  const _JSONSchema({this.type = 'object', final  Map<String, JSONSchemaProperty> properties = const {}, final  List<String> required = const [], this.additionalProperties = false}): _properties = properties,_required = required;
  factory _JSONSchema.fromJson(Map<String, dynamic> json) => _$JSONSchemaFromJson(json);

/// Schema type (always "object" for function parameters)
@override@JsonKey() final  String type;
/// Properties of the schema
 final  Map<String, JSONSchemaProperty> _properties;
/// Properties of the schema
@override@JsonKey() Map<String, JSONSchemaProperty> get properties {
  if (_properties is EqualUnmodifiableMapView) return _properties;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_properties);
}

/// Required properties
 final  List<String> _required;
/// Required properties
@override@JsonKey() List<String> get required {
  if (_required is EqualUnmodifiableListView) return _required;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_required);
}

/// Allow additional properties
@override@JsonKey() final  bool additionalProperties;

/// Create a copy of JSONSchema
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$JSONSchemaCopyWith<_JSONSchema> get copyWith => __$JSONSchemaCopyWithImpl<_JSONSchema>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$JSONSchemaToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _JSONSchema&&(identical(other.type, type) || other.type == type)&&const DeepCollectionEquality().equals(other._properties, _properties)&&const DeepCollectionEquality().equals(other._required, _required)&&(identical(other.additionalProperties, additionalProperties) || other.additionalProperties == additionalProperties));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,const DeepCollectionEquality().hash(_properties),const DeepCollectionEquality().hash(_required),additionalProperties);

@override
String toString() {
  return 'JSONSchema(type: $type, properties: $properties, required: $required, additionalProperties: $additionalProperties)';
}


}

/// @nodoc
abstract mixin class _$JSONSchemaCopyWith<$Res> implements $JSONSchemaCopyWith<$Res> {
  factory _$JSONSchemaCopyWith(_JSONSchema value, $Res Function(_JSONSchema) _then) = __$JSONSchemaCopyWithImpl;
@override @useResult
$Res call({
 String type, Map<String, JSONSchemaProperty> properties, List<String> required, bool additionalProperties
});




}
/// @nodoc
class __$JSONSchemaCopyWithImpl<$Res>
    implements _$JSONSchemaCopyWith<$Res> {
  __$JSONSchemaCopyWithImpl(this._self, this._then);

  final _JSONSchema _self;
  final $Res Function(_JSONSchema) _then;

/// Create a copy of JSONSchema
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? properties = null,Object? required = null,Object? additionalProperties = null,}) {
  return _then(_JSONSchema(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,properties: null == properties ? _self._properties : properties // ignore: cast_nullable_to_non_nullable
as Map<String, JSONSchemaProperty>,required: null == required ? _self._required : required // ignore: cast_nullable_to_non_nullable
as List<String>,additionalProperties: null == additionalProperties ? _self.additionalProperties : additionalProperties // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$FunctionInfo {

/// Name of the function
 String get name;/// Description of what the function does
 String? get description;/// Parameters schema
 JSONSchema? get parameters;/// Whether the function is strict (OpenAI specific)
 bool? get strict;/// The parameters as a complete JSON Schema document, exactly as it was
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
@JsonKey(includeIfNull: false) Map<String, dynamic>? get parametersJsonSchema;
/// Create a copy of FunctionInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FunctionInfoCopyWith<FunctionInfo> get copyWith => _$FunctionInfoCopyWithImpl<FunctionInfo>(this as FunctionInfo, _$identity);

  /// Serializes this FunctionInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FunctionInfo&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.parameters, parameters) || other.parameters == parameters)&&(identical(other.strict, strict) || other.strict == strict)&&const DeepCollectionEquality().equals(other.parametersJsonSchema, parametersJsonSchema));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,description,parameters,strict,const DeepCollectionEquality().hash(parametersJsonSchema));

@override
String toString() {
  return 'FunctionInfo(name: $name, description: $description, parameters: $parameters, strict: $strict, parametersJsonSchema: $parametersJsonSchema)';
}


}

/// @nodoc
abstract mixin class $FunctionInfoCopyWith<$Res>  {
  factory $FunctionInfoCopyWith(FunctionInfo value, $Res Function(FunctionInfo) _then) = _$FunctionInfoCopyWithImpl;
@useResult
$Res call({
 String name, String? description, JSONSchema? parameters, bool? strict,@JsonKey(includeIfNull: false) Map<String, dynamic>? parametersJsonSchema
});


$JSONSchemaCopyWith<$Res>? get parameters;

}
/// @nodoc
class _$FunctionInfoCopyWithImpl<$Res>
    implements $FunctionInfoCopyWith<$Res> {
  _$FunctionInfoCopyWithImpl(this._self, this._then);

  final FunctionInfo _self;
  final $Res Function(FunctionInfo) _then;

/// Create a copy of FunctionInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? description = freezed,Object? parameters = freezed,Object? strict = freezed,Object? parametersJsonSchema = freezed,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,parameters: freezed == parameters ? _self.parameters : parameters // ignore: cast_nullable_to_non_nullable
as JSONSchema?,strict: freezed == strict ? _self.strict : strict // ignore: cast_nullable_to_non_nullable
as bool?,parametersJsonSchema: freezed == parametersJsonSchema ? _self.parametersJsonSchema : parametersJsonSchema // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}
/// Create a copy of FunctionInfo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$JSONSchemaCopyWith<$Res>? get parameters {
    if (_self.parameters == null) {
    return null;
  }

  return $JSONSchemaCopyWith<$Res>(_self.parameters!, (value) {
    return _then(_self.copyWith(parameters: value));
  });
}
}


/// Adds pattern-matching-related methods to [FunctionInfo].
extension FunctionInfoPatterns on FunctionInfo {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FunctionInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FunctionInfo() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FunctionInfo value)  $default,){
final _that = this;
switch (_that) {
case _FunctionInfo():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FunctionInfo value)?  $default,){
final _that = this;
switch (_that) {
case _FunctionInfo() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String? description,  JSONSchema? parameters,  bool? strict, @JsonKey(includeIfNull: false)  Map<String, dynamic>? parametersJsonSchema)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FunctionInfo() when $default != null:
return $default(_that.name,_that.description,_that.parameters,_that.strict,_that.parametersJsonSchema);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String? description,  JSONSchema? parameters,  bool? strict, @JsonKey(includeIfNull: false)  Map<String, dynamic>? parametersJsonSchema)  $default,) {final _that = this;
switch (_that) {
case _FunctionInfo():
return $default(_that.name,_that.description,_that.parameters,_that.strict,_that.parametersJsonSchema);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String? description,  JSONSchema? parameters,  bool? strict, @JsonKey(includeIfNull: false)  Map<String, dynamic>? parametersJsonSchema)?  $default,) {final _that = this;
switch (_that) {
case _FunctionInfo() when $default != null:
return $default(_that.name,_that.description,_that.parameters,_that.strict,_that.parametersJsonSchema);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _FunctionInfo implements FunctionInfo {
  const _FunctionInfo({required this.name, this.description, this.parameters, this.strict, @JsonKey(includeIfNull: false) final  Map<String, dynamic>? parametersJsonSchema}): _parametersJsonSchema = parametersJsonSchema;
  factory _FunctionInfo.fromJson(Map<String, dynamic> json) => _$FunctionInfoFromJson(json);

/// Name of the function
@override final  String name;
/// Description of what the function does
@override final  String? description;
/// Parameters schema
@override final  JSONSchema? parameters;
/// Whether the function is strict (OpenAI specific)
@override final  bool? strict;
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
 final  Map<String, dynamic>? _parametersJsonSchema;
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
@override@JsonKey(includeIfNull: false) Map<String, dynamic>? get parametersJsonSchema {
  final value = _parametersJsonSchema;
  if (value == null) return null;
  if (_parametersJsonSchema is EqualUnmodifiableMapView) return _parametersJsonSchema;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}


/// Create a copy of FunctionInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FunctionInfoCopyWith<_FunctionInfo> get copyWith => __$FunctionInfoCopyWithImpl<_FunctionInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FunctionInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FunctionInfo&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.parameters, parameters) || other.parameters == parameters)&&(identical(other.strict, strict) || other.strict == strict)&&const DeepCollectionEquality().equals(other._parametersJsonSchema, _parametersJsonSchema));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,description,parameters,strict,const DeepCollectionEquality().hash(_parametersJsonSchema));

@override
String toString() {
  return 'FunctionInfo(name: $name, description: $description, parameters: $parameters, strict: $strict, parametersJsonSchema: $parametersJsonSchema)';
}


}

/// @nodoc
abstract mixin class _$FunctionInfoCopyWith<$Res> implements $FunctionInfoCopyWith<$Res> {
  factory _$FunctionInfoCopyWith(_FunctionInfo value, $Res Function(_FunctionInfo) _then) = __$FunctionInfoCopyWithImpl;
@override @useResult
$Res call({
 String name, String? description, JSONSchema? parameters, bool? strict,@JsonKey(includeIfNull: false) Map<String, dynamic>? parametersJsonSchema
});


@override $JSONSchemaCopyWith<$Res>? get parameters;

}
/// @nodoc
class __$FunctionInfoCopyWithImpl<$Res>
    implements _$FunctionInfoCopyWith<$Res> {
  __$FunctionInfoCopyWithImpl(this._self, this._then);

  final _FunctionInfo _self;
  final $Res Function(_FunctionInfo) _then;

/// Create a copy of FunctionInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? description = freezed,Object? parameters = freezed,Object? strict = freezed,Object? parametersJsonSchema = freezed,}) {
  return _then(_FunctionInfo(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,parameters: freezed == parameters ? _self.parameters : parameters // ignore: cast_nullable_to_non_nullable
as JSONSchema?,strict: freezed == strict ? _self.strict : strict // ignore: cast_nullable_to_non_nullable
as bool?,parametersJsonSchema: freezed == parametersJsonSchema ? _self._parametersJsonSchema : parametersJsonSchema // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}

/// Create a copy of FunctionInfo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$JSONSchemaCopyWith<$Res>? get parameters {
    if (_self.parameters == null) {
    return null;
  }

  return $JSONSchemaCopyWith<$Res>(_self.parameters!, (value) {
    return _then(_self.copyWith(parameters: value));
  });
}
}


/// @nodoc
mixin _$ToolInfo {

/// Tool type (typically "function")
 String get type;/// Function information
 FunctionInfo get function;/// Extra information about the tool. It is not part of the definition
/// the model sees.
 Map<String, dynamic>? get extra;
/// Create a copy of ToolInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolInfoCopyWith<ToolInfo> get copyWith => _$ToolInfoCopyWithImpl<ToolInfo>(this as ToolInfo, _$identity);

  /// Serializes this ToolInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolInfo&&(identical(other.type, type) || other.type == type)&&(identical(other.function, function) || other.function == function)&&const DeepCollectionEquality().equals(other.extra, extra));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,function,const DeepCollectionEquality().hash(extra));

@override
String toString() {
  return 'ToolInfo(type: $type, function: $function, extra: $extra)';
}


}

/// @nodoc
abstract mixin class $ToolInfoCopyWith<$Res>  {
  factory $ToolInfoCopyWith(ToolInfo value, $Res Function(ToolInfo) _then) = _$ToolInfoCopyWithImpl;
@useResult
$Res call({
 String type, FunctionInfo function, Map<String, dynamic>? extra
});


$FunctionInfoCopyWith<$Res> get function;

}
/// @nodoc
class _$ToolInfoCopyWithImpl<$Res>
    implements $ToolInfoCopyWith<$Res> {
  _$ToolInfoCopyWithImpl(this._self, this._then);

  final ToolInfo _self;
  final $Res Function(ToolInfo) _then;

/// Create a copy of ToolInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? type = null,Object? function = null,Object? extra = freezed,}) {
  return _then(_self.copyWith(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,function: null == function ? _self.function : function // ignore: cast_nullable_to_non_nullable
as FunctionInfo,extra: freezed == extra ? _self.extra : extra // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}
/// Create a copy of ToolInfo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$FunctionInfoCopyWith<$Res> get function {
  
  return $FunctionInfoCopyWith<$Res>(_self.function, (value) {
    return _then(_self.copyWith(function: value));
  });
}
}


/// Adds pattern-matching-related methods to [ToolInfo].
extension ToolInfoPatterns on ToolInfo {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolInfo() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolInfo value)  $default,){
final _that = this;
switch (_that) {
case _ToolInfo():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolInfo value)?  $default,){
final _that = this;
switch (_that) {
case _ToolInfo() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String type,  FunctionInfo function,  Map<String, dynamic>? extra)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolInfo() when $default != null:
return $default(_that.type,_that.function,_that.extra);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String type,  FunctionInfo function,  Map<String, dynamic>? extra)  $default,) {final _that = this;
switch (_that) {
case _ToolInfo():
return $default(_that.type,_that.function,_that.extra);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String type,  FunctionInfo function,  Map<String, dynamic>? extra)?  $default,) {final _that = this;
switch (_that) {
case _ToolInfo() when $default != null:
return $default(_that.type,_that.function,_that.extra);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolInfo extends ToolInfo {
  const _ToolInfo({this.type = 'function', required this.function, final  Map<String, dynamic>? extra}): _extra = extra,super._();
  factory _ToolInfo.fromJson(Map<String, dynamic> json) => _$ToolInfoFromJson(json);

/// Tool type (typically "function")
@override@JsonKey() final  String type;
/// Function information
@override final  FunctionInfo function;
/// Extra information about the tool. It is not part of the definition
/// the model sees.
 final  Map<String, dynamic>? _extra;
/// Extra information about the tool. It is not part of the definition
/// the model sees.
@override Map<String, dynamic>? get extra {
  final value = _extra;
  if (value == null) return null;
  if (_extra is EqualUnmodifiableMapView) return _extra;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}


/// Create a copy of ToolInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolInfoCopyWith<_ToolInfo> get copyWith => __$ToolInfoCopyWithImpl<_ToolInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolInfo&&(identical(other.type, type) || other.type == type)&&(identical(other.function, function) || other.function == function)&&const DeepCollectionEquality().equals(other._extra, _extra));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,function,const DeepCollectionEquality().hash(_extra));

@override
String toString() {
  return 'ToolInfo(type: $type, function: $function, extra: $extra)';
}


}

/// @nodoc
abstract mixin class _$ToolInfoCopyWith<$Res> implements $ToolInfoCopyWith<$Res> {
  factory _$ToolInfoCopyWith(_ToolInfo value, $Res Function(_ToolInfo) _then) = __$ToolInfoCopyWithImpl;
@override @useResult
$Res call({
 String type, FunctionInfo function, Map<String, dynamic>? extra
});


@override $FunctionInfoCopyWith<$Res> get function;

}
/// @nodoc
class __$ToolInfoCopyWithImpl<$Res>
    implements _$ToolInfoCopyWith<$Res> {
  __$ToolInfoCopyWithImpl(this._self, this._then);

  final _ToolInfo _self;
  final $Res Function(_ToolInfo) _then;

/// Create a copy of ToolInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? function = null,Object? extra = freezed,}) {
  return _then(_ToolInfo(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String,function: null == function ? _self.function : function // ignore: cast_nullable_to_non_nullable
as FunctionInfo,extra: freezed == extra ? _self._extra : extra // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}

/// Create a copy of ToolInfo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$FunctionInfoCopyWith<$Res> get function {
  
  return $FunctionInfoCopyWith<$Res>(_self.function, (value) {
    return _then(_self.copyWith(function: value));
  });
}
}


/// @nodoc
mixin _$ToolSearchResult {

/// Definitions of the tools that were found
 List<ToolInfo> get tools;
/// Create a copy of ToolSearchResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolSearchResultCopyWith<ToolSearchResult> get copyWith => _$ToolSearchResultCopyWithImpl<ToolSearchResult>(this as ToolSearchResult, _$identity);

  /// Serializes this ToolSearchResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolSearchResult&&const DeepCollectionEquality().equals(other.tools, tools));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(tools));

@override
String toString() {
  return 'ToolSearchResult(tools: $tools)';
}


}

/// @nodoc
abstract mixin class $ToolSearchResultCopyWith<$Res>  {
  factory $ToolSearchResultCopyWith(ToolSearchResult value, $Res Function(ToolSearchResult) _then) = _$ToolSearchResultCopyWithImpl;
@useResult
$Res call({
 List<ToolInfo> tools
});




}
/// @nodoc
class _$ToolSearchResultCopyWithImpl<$Res>
    implements $ToolSearchResultCopyWith<$Res> {
  _$ToolSearchResultCopyWithImpl(this._self, this._then);

  final ToolSearchResult _self;
  final $Res Function(ToolSearchResult) _then;

/// Create a copy of ToolSearchResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? tools = null,}) {
  return _then(_self.copyWith(
tools: null == tools ? _self.tools : tools // ignore: cast_nullable_to_non_nullable
as List<ToolInfo>,
  ));
}

}


/// Adds pattern-matching-related methods to [ToolSearchResult].
extension ToolSearchResultPatterns on ToolSearchResult {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolSearchResult value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolSearchResult() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolSearchResult value)  $default,){
final _that = this;
switch (_that) {
case _ToolSearchResult():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolSearchResult value)?  $default,){
final _that = this;
switch (_that) {
case _ToolSearchResult() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<ToolInfo> tools)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolSearchResult() when $default != null:
return $default(_that.tools);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<ToolInfo> tools)  $default,) {final _that = this;
switch (_that) {
case _ToolSearchResult():
return $default(_that.tools);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<ToolInfo> tools)?  $default,) {final _that = this;
switch (_that) {
case _ToolSearchResult() when $default != null:
return $default(_that.tools);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolSearchResult implements ToolSearchResult {
  const _ToolSearchResult({final  List<ToolInfo> tools = const []}): _tools = tools;
  factory _ToolSearchResult.fromJson(Map<String, dynamic> json) => _$ToolSearchResultFromJson(json);

/// Definitions of the tools that were found
 final  List<ToolInfo> _tools;
/// Definitions of the tools that were found
@override@JsonKey() List<ToolInfo> get tools {
  if (_tools is EqualUnmodifiableListView) return _tools;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tools);
}


/// Create a copy of ToolSearchResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolSearchResultCopyWith<_ToolSearchResult> get copyWith => __$ToolSearchResultCopyWithImpl<_ToolSearchResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolSearchResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolSearchResult&&const DeepCollectionEquality().equals(other._tools, _tools));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_tools));

@override
String toString() {
  return 'ToolSearchResult(tools: $tools)';
}


}

/// @nodoc
abstract mixin class _$ToolSearchResultCopyWith<$Res> implements $ToolSearchResultCopyWith<$Res> {
  factory _$ToolSearchResultCopyWith(_ToolSearchResult value, $Res Function(_ToolSearchResult) _then) = __$ToolSearchResultCopyWithImpl;
@override @useResult
$Res call({
 List<ToolInfo> tools
});




}
/// @nodoc
class __$ToolSearchResultCopyWithImpl<$Res>
    implements _$ToolSearchResultCopyWith<$Res> {
  __$ToolSearchResultCopyWithImpl(this._self, this._then);

  final _ToolSearchResult _self;
  final $Res Function(_ToolSearchResult) _then;

/// Create a copy of ToolSearchResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? tools = null,}) {
  return _then(_ToolSearchResult(
tools: null == tools ? _self._tools : tools // ignore: cast_nullable_to_non_nullable
as List<ToolInfo>,
  ));
}


}

// dart format on
