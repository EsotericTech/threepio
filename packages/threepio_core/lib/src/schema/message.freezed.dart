// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'message.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$FunctionCall {
  /// Name of the function to call
  String get name;

  /// Arguments in JSON format
  String get arguments;

  /// Create a copy of FunctionCall
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $FunctionCallCopyWith<FunctionCall> get copyWith =>
      _$FunctionCallCopyWithImpl<FunctionCall>(
          this as FunctionCall, _$identity);

  /// Serializes this FunctionCall to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is FunctionCall &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.arguments, arguments) ||
                other.arguments == arguments));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, name, arguments);

  @override
  String toString() {
    return 'FunctionCall(name: $name, arguments: $arguments)';
  }
}

/// @nodoc
abstract mixin class $FunctionCallCopyWith<$Res> {
  factory $FunctionCallCopyWith(
          FunctionCall value, $Res Function(FunctionCall) _then) =
      _$FunctionCallCopyWithImpl;
  @useResult
  $Res call({String name, String arguments});
}

/// @nodoc
class _$FunctionCallCopyWithImpl<$Res> implements $FunctionCallCopyWith<$Res> {
  _$FunctionCallCopyWithImpl(this._self, this._then);

  final FunctionCall _self;
  final $Res Function(FunctionCall) _then;

  /// Create a copy of FunctionCall
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? name = null,
    Object? arguments = null,
  }) {
    return _then(_self.copyWith(
      name: null == name
          ? _self.name
          : name // ignore: cast_nullable_to_non_nullable
              as String,
      arguments: null == arguments
          ? _self.arguments
          : arguments // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// Adds pattern-matching-related methods to [FunctionCall].
extension FunctionCallPatterns on FunctionCall {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_FunctionCall value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FunctionCall() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_FunctionCall value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FunctionCall():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_FunctionCall value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FunctionCall() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(String name, String arguments)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _FunctionCall() when $default != null:
        return $default(_that.name, _that.arguments);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(String name, String arguments) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FunctionCall():
        return $default(_that.name, _that.arguments);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(String name, String arguments)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _FunctionCall() when $default != null:
        return $default(_that.name, _that.arguments);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _FunctionCall implements FunctionCall {
  const _FunctionCall({required this.name, required this.arguments});
  factory _FunctionCall.fromJson(Map<String, dynamic> json) =>
      _$FunctionCallFromJson(json);

  /// Name of the function to call
  @override
  final String name;

  /// Arguments in JSON format
  @override
  final String arguments;

  /// Create a copy of FunctionCall
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$FunctionCallCopyWith<_FunctionCall> get copyWith =>
      __$FunctionCallCopyWithImpl<_FunctionCall>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$FunctionCallToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _FunctionCall &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.arguments, arguments) ||
                other.arguments == arguments));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, name, arguments);

  @override
  String toString() {
    return 'FunctionCall(name: $name, arguments: $arguments)';
  }
}

/// @nodoc
abstract mixin class _$FunctionCallCopyWith<$Res>
    implements $FunctionCallCopyWith<$Res> {
  factory _$FunctionCallCopyWith(
          _FunctionCall value, $Res Function(_FunctionCall) _then) =
      __$FunctionCallCopyWithImpl;
  @override
  @useResult
  $Res call({String name, String arguments});
}

/// @nodoc
class __$FunctionCallCopyWithImpl<$Res>
    implements _$FunctionCallCopyWith<$Res> {
  __$FunctionCallCopyWithImpl(this._self, this._then);

  final _FunctionCall _self;
  final $Res Function(_FunctionCall) _then;

  /// Create a copy of FunctionCall
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? name = null,
    Object? arguments = null,
  }) {
    return _then(_FunctionCall(
      name: null == name
          ? _self.name
          : name // ignore: cast_nullable_to_non_nullable
              as String,
      arguments: null == arguments
          ? _self.arguments
          : arguments // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc
mixin _$ToolCall {
  /// Index for multiple tool calls
  int? get index;

  /// ID of the tool call
  String get id;

  /// Type of tool call (typically "function")
  String get type;

  /// Function call details
  FunctionCall get function;

  /// Extra information
  Map<String, dynamic>? get extra;

  /// Create a copy of ToolCall
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ToolCallCopyWith<ToolCall> get copyWith =>
      _$ToolCallCopyWithImpl<ToolCall>(this as ToolCall, _$identity);

  /// Serializes this ToolCall to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ToolCall &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.function, function) ||
                other.function == function) &&
            const DeepCollectionEquality().equals(other.extra, extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, index, id, type, function,
      const DeepCollectionEquality().hash(extra));

  @override
  String toString() {
    return 'ToolCall(index: $index, id: $id, type: $type, function: $function, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class $ToolCallCopyWith<$Res> {
  factory $ToolCallCopyWith(ToolCall value, $Res Function(ToolCall) _then) =
      _$ToolCallCopyWithImpl;
  @useResult
  $Res call(
      {int? index,
      String id,
      String type,
      FunctionCall function,
      Map<String, dynamic>? extra});

  $FunctionCallCopyWith<$Res> get function;
}

/// @nodoc
class _$ToolCallCopyWithImpl<$Res> implements $ToolCallCopyWith<$Res> {
  _$ToolCallCopyWithImpl(this._self, this._then);

  final ToolCall _self;
  final $Res Function(ToolCall) _then;

  /// Create a copy of ToolCall
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? index = freezed,
    Object? id = null,
    Object? type = null,
    Object? function = null,
    Object? extra = freezed,
  }) {
    return _then(_self.copyWith(
      index: freezed == index
          ? _self.index
          : index // ignore: cast_nullable_to_non_nullable
              as int?,
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      type: null == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as String,
      function: null == function
          ? _self.function
          : function // ignore: cast_nullable_to_non_nullable
              as FunctionCall,
      extra: freezed == extra
          ? _self.extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }

  /// Create a copy of ToolCall
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $FunctionCallCopyWith<$Res> get function {
    return $FunctionCallCopyWith<$Res>(_self.function, (value) {
      return _then(_self.copyWith(function: value));
    });
  }
}

/// Adds pattern-matching-related methods to [ToolCall].
extension ToolCallPatterns on ToolCall {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_ToolCall value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ToolCall() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_ToolCall value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ToolCall():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_ToolCall value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ToolCall() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(int? index, String id, String type, FunctionCall function,
            Map<String, dynamic>? extra)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ToolCall() when $default != null:
        return $default(
            _that.index, _that.id, _that.type, _that.function, _that.extra);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(int? index, String id, String type, FunctionCall function,
            Map<String, dynamic>? extra)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ToolCall():
        return $default(
            _that.index, _that.id, _that.type, _that.function, _that.extra);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(int? index, String id, String type, FunctionCall function,
            Map<String, dynamic>? extra)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ToolCall() when $default != null:
        return $default(
            _that.index, _that.id, _that.type, _that.function, _that.extra);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _ToolCall implements ToolCall {
  const _ToolCall(
      {this.index,
      required this.id,
      this.type = 'function',
      required this.function,
      final Map<String, dynamic>? extra})
      : _extra = extra;
  factory _ToolCall.fromJson(Map<String, dynamic> json) =>
      _$ToolCallFromJson(json);

  /// Index for multiple tool calls
  @override
  final int? index;

  /// ID of the tool call
  @override
  final String id;

  /// Type of tool call (typically "function")
  @override
  @JsonKey()
  final String type;

  /// Function call details
  @override
  final FunctionCall function;

  /// Extra information
  final Map<String, dynamic>? _extra;

  /// Extra information
  @override
  Map<String, dynamic>? get extra {
    final value = _extra;
    if (value == null) return null;
    if (_extra is EqualUnmodifiableMapView) return _extra;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Create a copy of ToolCall
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ToolCallCopyWith<_ToolCall> get copyWith =>
      __$ToolCallCopyWithImpl<_ToolCall>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$ToolCallToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ToolCall &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.function, function) ||
                other.function == function) &&
            const DeepCollectionEquality().equals(other._extra, _extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, index, id, type, function,
      const DeepCollectionEquality().hash(_extra));

  @override
  String toString() {
    return 'ToolCall(index: $index, id: $id, type: $type, function: $function, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class _$ToolCallCopyWith<$Res>
    implements $ToolCallCopyWith<$Res> {
  factory _$ToolCallCopyWith(_ToolCall value, $Res Function(_ToolCall) _then) =
      __$ToolCallCopyWithImpl;
  @override
  @useResult
  $Res call(
      {int? index,
      String id,
      String type,
      FunctionCall function,
      Map<String, dynamic>? extra});

  @override
  $FunctionCallCopyWith<$Res> get function;
}

/// @nodoc
class __$ToolCallCopyWithImpl<$Res> implements _$ToolCallCopyWith<$Res> {
  __$ToolCallCopyWithImpl(this._self, this._then);

  final _ToolCall _self;
  final $Res Function(_ToolCall) _then;

  /// Create a copy of ToolCall
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? index = freezed,
    Object? id = null,
    Object? type = null,
    Object? function = null,
    Object? extra = freezed,
  }) {
    return _then(_ToolCall(
      index: freezed == index
          ? _self.index
          : index // ignore: cast_nullable_to_non_nullable
              as int?,
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      type: null == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as String,
      function: null == function
          ? _self.function
          : function // ignore: cast_nullable_to_non_nullable
              as FunctionCall,
      extra: freezed == extra
          ? _self._extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }

  /// Create a copy of ToolCall
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $FunctionCallCopyWith<$Res> get function {
    return $FunctionCallCopyWith<$Res>(_self.function, (value) {
      return _then(_self.copyWith(function: value));
    });
  }
}

/// @nodoc
mixin _$MessagePartCommon {
  /// URL (traditional or RFC-2397 data URI)
  String? get url;

  /// Base64 encoded data
  String? get base64Data;

  /// MIME type (e.g., "image/png", "audio/wav")
  String? get mimeType;

  /// Extra information
  Map<String, dynamic>? get extra;

  /// Create a copy of MessagePartCommon
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<MessagePartCommon> get copyWith =>
      _$MessagePartCommonCopyWithImpl<MessagePartCommon>(
          this as MessagePartCommon, _$identity);

  /// Serializes this MessagePartCommon to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MessagePartCommon &&
            (identical(other.url, url) || other.url == url) &&
            (identical(other.base64Data, base64Data) ||
                other.base64Data == base64Data) &&
            (identical(other.mimeType, mimeType) ||
                other.mimeType == mimeType) &&
            const DeepCollectionEquality().equals(other.extra, extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, url, base64Data, mimeType,
      const DeepCollectionEquality().hash(extra));

  @override
  String toString() {
    return 'MessagePartCommon(url: $url, base64Data: $base64Data, mimeType: $mimeType, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class $MessagePartCommonCopyWith<$Res> {
  factory $MessagePartCommonCopyWith(
          MessagePartCommon value, $Res Function(MessagePartCommon) _then) =
      _$MessagePartCommonCopyWithImpl;
  @useResult
  $Res call(
      {String? url,
      String? base64Data,
      String? mimeType,
      Map<String, dynamic>? extra});
}

/// @nodoc
class _$MessagePartCommonCopyWithImpl<$Res>
    implements $MessagePartCommonCopyWith<$Res> {
  _$MessagePartCommonCopyWithImpl(this._self, this._then);

  final MessagePartCommon _self;
  final $Res Function(MessagePartCommon) _then;

  /// Create a copy of MessagePartCommon
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? url = freezed,
    Object? base64Data = freezed,
    Object? mimeType = freezed,
    Object? extra = freezed,
  }) {
    return _then(_self.copyWith(
      url: freezed == url
          ? _self.url
          : url // ignore: cast_nullable_to_non_nullable
              as String?,
      base64Data: freezed == base64Data
          ? _self.base64Data
          : base64Data // ignore: cast_nullable_to_non_nullable
              as String?,
      mimeType: freezed == mimeType
          ? _self.mimeType
          : mimeType // ignore: cast_nullable_to_non_nullable
              as String?,
      extra: freezed == extra
          ? _self.extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// Adds pattern-matching-related methods to [MessagePartCommon].
extension MessagePartCommonPatterns on MessagePartCommon {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_MessagePartCommon value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessagePartCommon() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_MessagePartCommon value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessagePartCommon():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_MessagePartCommon value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessagePartCommon() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(String? url, String? base64Data, String? mimeType,
            Map<String, dynamic>? extra)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessagePartCommon() when $default != null:
        return $default(
            _that.url, _that.base64Data, _that.mimeType, _that.extra);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(String? url, String? base64Data, String? mimeType,
            Map<String, dynamic>? extra)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessagePartCommon():
        return $default(
            _that.url, _that.base64Data, _that.mimeType, _that.extra);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(String? url, String? base64Data, String? mimeType,
            Map<String, dynamic>? extra)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessagePartCommon() when $default != null:
        return $default(
            _that.url, _that.base64Data, _that.mimeType, _that.extra);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _MessagePartCommon implements MessagePartCommon {
  const _MessagePartCommon(
      {this.url,
      this.base64Data,
      this.mimeType,
      final Map<String, dynamic>? extra})
      : _extra = extra;
  factory _MessagePartCommon.fromJson(Map<String, dynamic> json) =>
      _$MessagePartCommonFromJson(json);

  /// URL (traditional or RFC-2397 data URI)
  @override
  final String? url;

  /// Base64 encoded data
  @override
  final String? base64Data;

  /// MIME type (e.g., "image/png", "audio/wav")
  @override
  final String? mimeType;

  /// Extra information
  final Map<String, dynamic>? _extra;

  /// Extra information
  @override
  Map<String, dynamic>? get extra {
    final value = _extra;
    if (value == null) return null;
    if (_extra is EqualUnmodifiableMapView) return _extra;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Create a copy of MessagePartCommon
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessagePartCommonCopyWith<_MessagePartCommon> get copyWith =>
      __$MessagePartCommonCopyWithImpl<_MessagePartCommon>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessagePartCommonToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _MessagePartCommon &&
            (identical(other.url, url) || other.url == url) &&
            (identical(other.base64Data, base64Data) ||
                other.base64Data == base64Data) &&
            (identical(other.mimeType, mimeType) ||
                other.mimeType == mimeType) &&
            const DeepCollectionEquality().equals(other._extra, _extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, url, base64Data, mimeType,
      const DeepCollectionEquality().hash(_extra));

  @override
  String toString() {
    return 'MessagePartCommon(url: $url, base64Data: $base64Data, mimeType: $mimeType, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class _$MessagePartCommonCopyWith<$Res>
    implements $MessagePartCommonCopyWith<$Res> {
  factory _$MessagePartCommonCopyWith(
          _MessagePartCommon value, $Res Function(_MessagePartCommon) _then) =
      __$MessagePartCommonCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String? url,
      String? base64Data,
      String? mimeType,
      Map<String, dynamic>? extra});
}

/// @nodoc
class __$MessagePartCommonCopyWithImpl<$Res>
    implements _$MessagePartCommonCopyWith<$Res> {
  __$MessagePartCommonCopyWithImpl(this._self, this._then);

  final _MessagePartCommon _self;
  final $Res Function(_MessagePartCommon) _then;

  /// Create a copy of MessagePartCommon
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? url = freezed,
    Object? base64Data = freezed,
    Object? mimeType = freezed,
    Object? extra = freezed,
  }) {
    return _then(_MessagePartCommon(
      url: freezed == url
          ? _self.url
          : url // ignore: cast_nullable_to_non_nullable
              as String?,
      base64Data: freezed == base64Data
          ? _self.base64Data
          : base64Data // ignore: cast_nullable_to_non_nullable
              as String?,
      mimeType: freezed == mimeType
          ? _self.mimeType
          : mimeType // ignore: cast_nullable_to_non_nullable
              as String?,
      extra: freezed == extra
          ? _self._extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// @nodoc
mixin _$MessageInputImage {
  /// Common fields
  MessagePartCommon get common;

  /// Image quality detail
  ImageURLDetail? get detail;

  /// Create a copy of MessageInputImage
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessageInputImageCopyWith<MessageInputImage> get copyWith =>
      _$MessageInputImageCopyWithImpl<MessageInputImage>(
          this as MessageInputImage, _$identity);

  /// Serializes this MessageInputImage to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MessageInputImage &&
            (identical(other.common, common) || other.common == common) &&
            (identical(other.detail, detail) || other.detail == detail));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common, detail);

  @override
  String toString() {
    return 'MessageInputImage(common: $common, detail: $detail)';
  }
}

/// @nodoc
abstract mixin class $MessageInputImageCopyWith<$Res> {
  factory $MessageInputImageCopyWith(
          MessageInputImage value, $Res Function(MessageInputImage) _then) =
      _$MessageInputImageCopyWithImpl;
  @useResult
  $Res call({MessagePartCommon common, ImageURLDetail? detail});

  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class _$MessageInputImageCopyWithImpl<$Res>
    implements $MessageInputImageCopyWith<$Res> {
  _$MessageInputImageCopyWithImpl(this._self, this._then);

  final MessageInputImage _self;
  final $Res Function(MessageInputImage) _then;

  /// Create a copy of MessageInputImage
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? common = null,
    Object? detail = freezed,
  }) {
    return _then(_self.copyWith(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
      detail: freezed == detail
          ? _self.detail
          : detail // ignore: cast_nullable_to_non_nullable
              as ImageURLDetail?,
    ));
  }

  /// Create a copy of MessageInputImage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// Adds pattern-matching-related methods to [MessageInputImage].
extension MessageInputImagePatterns on MessageInputImage {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_MessageInputImage value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputImage() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_MessageInputImage value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputImage():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_MessageInputImage value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputImage() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(MessagePartCommon common, ImageURLDetail? detail)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputImage() when $default != null:
        return $default(_that.common, _that.detail);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(MessagePartCommon common, ImageURLDetail? detail) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputImage():
        return $default(_that.common, _that.detail);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(MessagePartCommon common, ImageURLDetail? detail)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputImage() when $default != null:
        return $default(_that.common, _that.detail);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _MessageInputImage implements MessageInputImage {
  const _MessageInputImage({required this.common, this.detail});
  factory _MessageInputImage.fromJson(Map<String, dynamic> json) =>
      _$MessageInputImageFromJson(json);

  /// Common fields
  @override
  final MessagePartCommon common;

  /// Image quality detail
  @override
  final ImageURLDetail? detail;

  /// Create a copy of MessageInputImage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessageInputImageCopyWith<_MessageInputImage> get copyWith =>
      __$MessageInputImageCopyWithImpl<_MessageInputImage>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessageInputImageToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _MessageInputImage &&
            (identical(other.common, common) || other.common == common) &&
            (identical(other.detail, detail) || other.detail == detail));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common, detail);

  @override
  String toString() {
    return 'MessageInputImage(common: $common, detail: $detail)';
  }
}

/// @nodoc
abstract mixin class _$MessageInputImageCopyWith<$Res>
    implements $MessageInputImageCopyWith<$Res> {
  factory _$MessageInputImageCopyWith(
          _MessageInputImage value, $Res Function(_MessageInputImage) _then) =
      __$MessageInputImageCopyWithImpl;
  @override
  @useResult
  $Res call({MessagePartCommon common, ImageURLDetail? detail});

  @override
  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class __$MessageInputImageCopyWithImpl<$Res>
    implements _$MessageInputImageCopyWith<$Res> {
  __$MessageInputImageCopyWithImpl(this._self, this._then);

  final _MessageInputImage _self;
  final $Res Function(_MessageInputImage) _then;

  /// Create a copy of MessageInputImage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? common = null,
    Object? detail = freezed,
  }) {
    return _then(_MessageInputImage(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
      detail: freezed == detail
          ? _self.detail
          : detail // ignore: cast_nullable_to_non_nullable
              as ImageURLDetail?,
    ));
  }

  /// Create a copy of MessageInputImage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// @nodoc
mixin _$MessageInputAudio {
  /// Common fields
  MessagePartCommon get common;

  /// Create a copy of MessageInputAudio
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessageInputAudioCopyWith<MessageInputAudio> get copyWith =>
      _$MessageInputAudioCopyWithImpl<MessageInputAudio>(
          this as MessageInputAudio, _$identity);

  /// Serializes this MessageInputAudio to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MessageInputAudio &&
            (identical(other.common, common) || other.common == common));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common);

  @override
  String toString() {
    return 'MessageInputAudio(common: $common)';
  }
}

/// @nodoc
abstract mixin class $MessageInputAudioCopyWith<$Res> {
  factory $MessageInputAudioCopyWith(
          MessageInputAudio value, $Res Function(MessageInputAudio) _then) =
      _$MessageInputAudioCopyWithImpl;
  @useResult
  $Res call({MessagePartCommon common});

  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class _$MessageInputAudioCopyWithImpl<$Res>
    implements $MessageInputAudioCopyWith<$Res> {
  _$MessageInputAudioCopyWithImpl(this._self, this._then);

  final MessageInputAudio _self;
  final $Res Function(MessageInputAudio) _then;

  /// Create a copy of MessageInputAudio
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? common = null,
  }) {
    return _then(_self.copyWith(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
    ));
  }

  /// Create a copy of MessageInputAudio
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// Adds pattern-matching-related methods to [MessageInputAudio].
extension MessageInputAudioPatterns on MessageInputAudio {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_MessageInputAudio value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputAudio() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_MessageInputAudio value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputAudio():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_MessageInputAudio value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputAudio() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(MessagePartCommon common)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputAudio() when $default != null:
        return $default(_that.common);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(MessagePartCommon common) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputAudio():
        return $default(_that.common);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(MessagePartCommon common)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputAudio() when $default != null:
        return $default(_that.common);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _MessageInputAudio implements MessageInputAudio {
  const _MessageInputAudio({required this.common});
  factory _MessageInputAudio.fromJson(Map<String, dynamic> json) =>
      _$MessageInputAudioFromJson(json);

  /// Common fields
  @override
  final MessagePartCommon common;

  /// Create a copy of MessageInputAudio
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessageInputAudioCopyWith<_MessageInputAudio> get copyWith =>
      __$MessageInputAudioCopyWithImpl<_MessageInputAudio>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessageInputAudioToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _MessageInputAudio &&
            (identical(other.common, common) || other.common == common));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common);

  @override
  String toString() {
    return 'MessageInputAudio(common: $common)';
  }
}

/// @nodoc
abstract mixin class _$MessageInputAudioCopyWith<$Res>
    implements $MessageInputAudioCopyWith<$Res> {
  factory _$MessageInputAudioCopyWith(
          _MessageInputAudio value, $Res Function(_MessageInputAudio) _then) =
      __$MessageInputAudioCopyWithImpl;
  @override
  @useResult
  $Res call({MessagePartCommon common});

  @override
  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class __$MessageInputAudioCopyWithImpl<$Res>
    implements _$MessageInputAudioCopyWith<$Res> {
  __$MessageInputAudioCopyWithImpl(this._self, this._then);

  final _MessageInputAudio _self;
  final $Res Function(_MessageInputAudio) _then;

  /// Create a copy of MessageInputAudio
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? common = null,
  }) {
    return _then(_MessageInputAudio(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
    ));
  }

  /// Create a copy of MessageInputAudio
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// @nodoc
mixin _$MessageInputVideo {
  /// Common fields
  MessagePartCommon get common;

  /// Create a copy of MessageInputVideo
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessageInputVideoCopyWith<MessageInputVideo> get copyWith =>
      _$MessageInputVideoCopyWithImpl<MessageInputVideo>(
          this as MessageInputVideo, _$identity);

  /// Serializes this MessageInputVideo to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MessageInputVideo &&
            (identical(other.common, common) || other.common == common));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common);

  @override
  String toString() {
    return 'MessageInputVideo(common: $common)';
  }
}

/// @nodoc
abstract mixin class $MessageInputVideoCopyWith<$Res> {
  factory $MessageInputVideoCopyWith(
          MessageInputVideo value, $Res Function(MessageInputVideo) _then) =
      _$MessageInputVideoCopyWithImpl;
  @useResult
  $Res call({MessagePartCommon common});

  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class _$MessageInputVideoCopyWithImpl<$Res>
    implements $MessageInputVideoCopyWith<$Res> {
  _$MessageInputVideoCopyWithImpl(this._self, this._then);

  final MessageInputVideo _self;
  final $Res Function(MessageInputVideo) _then;

  /// Create a copy of MessageInputVideo
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? common = null,
  }) {
    return _then(_self.copyWith(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
    ));
  }

  /// Create a copy of MessageInputVideo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// Adds pattern-matching-related methods to [MessageInputVideo].
extension MessageInputVideoPatterns on MessageInputVideo {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_MessageInputVideo value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputVideo() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_MessageInputVideo value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputVideo():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_MessageInputVideo value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputVideo() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(MessagePartCommon common)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputVideo() when $default != null:
        return $default(_that.common);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(MessagePartCommon common) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputVideo():
        return $default(_that.common);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(MessagePartCommon common)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputVideo() when $default != null:
        return $default(_that.common);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _MessageInputVideo implements MessageInputVideo {
  const _MessageInputVideo({required this.common});
  factory _MessageInputVideo.fromJson(Map<String, dynamic> json) =>
      _$MessageInputVideoFromJson(json);

  /// Common fields
  @override
  final MessagePartCommon common;

  /// Create a copy of MessageInputVideo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessageInputVideoCopyWith<_MessageInputVideo> get copyWith =>
      __$MessageInputVideoCopyWithImpl<_MessageInputVideo>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessageInputVideoToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _MessageInputVideo &&
            (identical(other.common, common) || other.common == common));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common);

  @override
  String toString() {
    return 'MessageInputVideo(common: $common)';
  }
}

/// @nodoc
abstract mixin class _$MessageInputVideoCopyWith<$Res>
    implements $MessageInputVideoCopyWith<$Res> {
  factory _$MessageInputVideoCopyWith(
          _MessageInputVideo value, $Res Function(_MessageInputVideo) _then) =
      __$MessageInputVideoCopyWithImpl;
  @override
  @useResult
  $Res call({MessagePartCommon common});

  @override
  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class __$MessageInputVideoCopyWithImpl<$Res>
    implements _$MessageInputVideoCopyWith<$Res> {
  __$MessageInputVideoCopyWithImpl(this._self, this._then);

  final _MessageInputVideo _self;
  final $Res Function(_MessageInputVideo) _then;

  /// Create a copy of MessageInputVideo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? common = null,
  }) {
    return _then(_MessageInputVideo(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
    ));
  }

  /// Create a copy of MessageInputVideo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// @nodoc
mixin _$MessageInputFile {
  /// Common fields
  MessagePartCommon get common;

  /// Create a copy of MessageInputFile
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessageInputFileCopyWith<MessageInputFile> get copyWith =>
      _$MessageInputFileCopyWithImpl<MessageInputFile>(
          this as MessageInputFile, _$identity);

  /// Serializes this MessageInputFile to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MessageInputFile &&
            (identical(other.common, common) || other.common == common));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common);

  @override
  String toString() {
    return 'MessageInputFile(common: $common)';
  }
}

/// @nodoc
abstract mixin class $MessageInputFileCopyWith<$Res> {
  factory $MessageInputFileCopyWith(
          MessageInputFile value, $Res Function(MessageInputFile) _then) =
      _$MessageInputFileCopyWithImpl;
  @useResult
  $Res call({MessagePartCommon common});

  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class _$MessageInputFileCopyWithImpl<$Res>
    implements $MessageInputFileCopyWith<$Res> {
  _$MessageInputFileCopyWithImpl(this._self, this._then);

  final MessageInputFile _self;
  final $Res Function(MessageInputFile) _then;

  /// Create a copy of MessageInputFile
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? common = null,
  }) {
    return _then(_self.copyWith(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
    ));
  }

  /// Create a copy of MessageInputFile
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// Adds pattern-matching-related methods to [MessageInputFile].
extension MessageInputFilePatterns on MessageInputFile {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_MessageInputFile value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputFile() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_MessageInputFile value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputFile():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_MessageInputFile value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputFile() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(MessagePartCommon common)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputFile() when $default != null:
        return $default(_that.common);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(MessagePartCommon common) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputFile():
        return $default(_that.common);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(MessagePartCommon common)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputFile() when $default != null:
        return $default(_that.common);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _MessageInputFile implements MessageInputFile {
  const _MessageInputFile({required this.common});
  factory _MessageInputFile.fromJson(Map<String, dynamic> json) =>
      _$MessageInputFileFromJson(json);

  /// Common fields
  @override
  final MessagePartCommon common;

  /// Create a copy of MessageInputFile
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessageInputFileCopyWith<_MessageInputFile> get copyWith =>
      __$MessageInputFileCopyWithImpl<_MessageInputFile>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessageInputFileToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _MessageInputFile &&
            (identical(other.common, common) || other.common == common));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, common);

  @override
  String toString() {
    return 'MessageInputFile(common: $common)';
  }
}

/// @nodoc
abstract mixin class _$MessageInputFileCopyWith<$Res>
    implements $MessageInputFileCopyWith<$Res> {
  factory _$MessageInputFileCopyWith(
          _MessageInputFile value, $Res Function(_MessageInputFile) _then) =
      __$MessageInputFileCopyWithImpl;
  @override
  @useResult
  $Res call({MessagePartCommon common});

  @override
  $MessagePartCommonCopyWith<$Res> get common;
}

/// @nodoc
class __$MessageInputFileCopyWithImpl<$Res>
    implements _$MessageInputFileCopyWith<$Res> {
  __$MessageInputFileCopyWithImpl(this._self, this._then);

  final _MessageInputFile _self;
  final $Res Function(_MessageInputFile) _then;

  /// Create a copy of MessageInputFile
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? common = null,
  }) {
    return _then(_MessageInputFile(
      common: null == common
          ? _self.common
          : common // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon,
    ));
  }

  /// Create a copy of MessageInputFile
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res> get common {
    return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
      return _then(_self.copyWith(common: value));
    });
  }
}

/// @nodoc
mixin _$MessageInputPart {
  /// Type of the part
  ChatMessagePartType get type;

  /// Text content (when type is text)
  String? get text;

  /// Image input (when type is imageUrl)
  MessageInputImage? get image;

  /// Audio input (when type is audioUrl)
  MessageInputAudio? get audio;

  /// Video input (when type is videoUrl)
  MessageInputVideo? get video;

  /// File input (when type is fileUrl)
  MessageInputFile? get file;

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessageInputPartCopyWith<MessageInputPart> get copyWith =>
      _$MessageInputPartCopyWithImpl<MessageInputPart>(
          this as MessageInputPart, _$identity);

  /// Serializes this MessageInputPart to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MessageInputPart &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.image, image) || other.image == image) &&
            (identical(other.audio, audio) || other.audio == audio) &&
            (identical(other.video, video) || other.video == video) &&
            (identical(other.file, file) || other.file == file));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, type, text, image, audio, video, file);

  @override
  String toString() {
    return 'MessageInputPart(type: $type, text: $text, image: $image, audio: $audio, video: $video, file: $file)';
  }
}

/// @nodoc
abstract mixin class $MessageInputPartCopyWith<$Res> {
  factory $MessageInputPartCopyWith(
          MessageInputPart value, $Res Function(MessageInputPart) _then) =
      _$MessageInputPartCopyWithImpl;
  @useResult
  $Res call(
      {ChatMessagePartType type,
      String? text,
      MessageInputImage? image,
      MessageInputAudio? audio,
      MessageInputVideo? video,
      MessageInputFile? file});

  $MessageInputImageCopyWith<$Res>? get image;
  $MessageInputAudioCopyWith<$Res>? get audio;
  $MessageInputVideoCopyWith<$Res>? get video;
  $MessageInputFileCopyWith<$Res>? get file;
}

/// @nodoc
class _$MessageInputPartCopyWithImpl<$Res>
    implements $MessageInputPartCopyWith<$Res> {
  _$MessageInputPartCopyWithImpl(this._self, this._then);

  final MessageInputPart _self;
  final $Res Function(MessageInputPart) _then;

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? type = null,
    Object? text = freezed,
    Object? image = freezed,
    Object? audio = freezed,
    Object? video = freezed,
    Object? file = freezed,
  }) {
    return _then(_self.copyWith(
      type: null == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as ChatMessagePartType,
      text: freezed == text
          ? _self.text
          : text // ignore: cast_nullable_to_non_nullable
              as String?,
      image: freezed == image
          ? _self.image
          : image // ignore: cast_nullable_to_non_nullable
              as MessageInputImage?,
      audio: freezed == audio
          ? _self.audio
          : audio // ignore: cast_nullable_to_non_nullable
              as MessageInputAudio?,
      video: freezed == video
          ? _self.video
          : video // ignore: cast_nullable_to_non_nullable
              as MessageInputVideo?,
      file: freezed == file
          ? _self.file
          : file // ignore: cast_nullable_to_non_nullable
              as MessageInputFile?,
    ));
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputImageCopyWith<$Res>? get image {
    if (_self.image == null) {
      return null;
    }

    return $MessageInputImageCopyWith<$Res>(_self.image!, (value) {
      return _then(_self.copyWith(image: value));
    });
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputAudioCopyWith<$Res>? get audio {
    if (_self.audio == null) {
      return null;
    }

    return $MessageInputAudioCopyWith<$Res>(_self.audio!, (value) {
      return _then(_self.copyWith(audio: value));
    });
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputVideoCopyWith<$Res>? get video {
    if (_self.video == null) {
      return null;
    }

    return $MessageInputVideoCopyWith<$Res>(_self.video!, (value) {
      return _then(_self.copyWith(video: value));
    });
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputFileCopyWith<$Res>? get file {
    if (_self.file == null) {
      return null;
    }

    return $MessageInputFileCopyWith<$Res>(_self.file!, (value) {
      return _then(_self.copyWith(file: value));
    });
  }
}

/// Adds pattern-matching-related methods to [MessageInputPart].
extension MessageInputPartPatterns on MessageInputPart {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_MessageInputPart value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputPart() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_MessageInputPart value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputPart():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_MessageInputPart value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputPart() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
            ChatMessagePartType type,
            String? text,
            MessageInputImage? image,
            MessageInputAudio? audio,
            MessageInputVideo? video,
            MessageInputFile? file)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageInputPart() when $default != null:
        return $default(_that.type, _that.text, _that.image, _that.audio,
            _that.video, _that.file);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
            ChatMessagePartType type,
            String? text,
            MessageInputImage? image,
            MessageInputAudio? audio,
            MessageInputVideo? video,
            MessageInputFile? file)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputPart():
        return $default(_that.type, _that.text, _that.image, _that.audio,
            _that.video, _that.file);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
            ChatMessagePartType type,
            String? text,
            MessageInputImage? image,
            MessageInputAudio? audio,
            MessageInputVideo? video,
            MessageInputFile? file)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageInputPart() when $default != null:
        return $default(_that.type, _that.text, _that.image, _that.audio,
            _that.video, _that.file);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _MessageInputPart implements MessageInputPart {
  const _MessageInputPart(
      {required this.type,
      this.text,
      this.image,
      this.audio,
      this.video,
      this.file});
  factory _MessageInputPart.fromJson(Map<String, dynamic> json) =>
      _$MessageInputPartFromJson(json);

  /// Type of the part
  @override
  final ChatMessagePartType type;

  /// Text content (when type is text)
  @override
  final String? text;

  /// Image input (when type is imageUrl)
  @override
  final MessageInputImage? image;

  /// Audio input (when type is audioUrl)
  @override
  final MessageInputAudio? audio;

  /// Video input (when type is videoUrl)
  @override
  final MessageInputVideo? video;

  /// File input (when type is fileUrl)
  @override
  final MessageInputFile? file;

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessageInputPartCopyWith<_MessageInputPart> get copyWith =>
      __$MessageInputPartCopyWithImpl<_MessageInputPart>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessageInputPartToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _MessageInputPart &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.image, image) || other.image == image) &&
            (identical(other.audio, audio) || other.audio == audio) &&
            (identical(other.video, video) || other.video == video) &&
            (identical(other.file, file) || other.file == file));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, type, text, image, audio, video, file);

  @override
  String toString() {
    return 'MessageInputPart(type: $type, text: $text, image: $image, audio: $audio, video: $video, file: $file)';
  }
}

/// @nodoc
abstract mixin class _$MessageInputPartCopyWith<$Res>
    implements $MessageInputPartCopyWith<$Res> {
  factory _$MessageInputPartCopyWith(
          _MessageInputPart value, $Res Function(_MessageInputPart) _then) =
      __$MessageInputPartCopyWithImpl;
  @override
  @useResult
  $Res call(
      {ChatMessagePartType type,
      String? text,
      MessageInputImage? image,
      MessageInputAudio? audio,
      MessageInputVideo? video,
      MessageInputFile? file});

  @override
  $MessageInputImageCopyWith<$Res>? get image;
  @override
  $MessageInputAudioCopyWith<$Res>? get audio;
  @override
  $MessageInputVideoCopyWith<$Res>? get video;
  @override
  $MessageInputFileCopyWith<$Res>? get file;
}

/// @nodoc
class __$MessageInputPartCopyWithImpl<$Res>
    implements _$MessageInputPartCopyWith<$Res> {
  __$MessageInputPartCopyWithImpl(this._self, this._then);

  final _MessageInputPart _self;
  final $Res Function(_MessageInputPart) _then;

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? type = null,
    Object? text = freezed,
    Object? image = freezed,
    Object? audio = freezed,
    Object? video = freezed,
    Object? file = freezed,
  }) {
    return _then(_MessageInputPart(
      type: null == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as ChatMessagePartType,
      text: freezed == text
          ? _self.text
          : text // ignore: cast_nullable_to_non_nullable
              as String?,
      image: freezed == image
          ? _self.image
          : image // ignore: cast_nullable_to_non_nullable
              as MessageInputImage?,
      audio: freezed == audio
          ? _self.audio
          : audio // ignore: cast_nullable_to_non_nullable
              as MessageInputAudio?,
      video: freezed == video
          ? _self.video
          : video // ignore: cast_nullable_to_non_nullable
              as MessageInputVideo?,
      file: freezed == file
          ? _self.file
          : file // ignore: cast_nullable_to_non_nullable
              as MessageInputFile?,
    ));
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputImageCopyWith<$Res>? get image {
    if (_self.image == null) {
      return null;
    }

    return $MessageInputImageCopyWith<$Res>(_self.image!, (value) {
      return _then(_self.copyWith(image: value));
    });
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputAudioCopyWith<$Res>? get audio {
    if (_self.audio == null) {
      return null;
    }

    return $MessageInputAudioCopyWith<$Res>(_self.audio!, (value) {
      return _then(_self.copyWith(audio: value));
    });
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputVideoCopyWith<$Res>? get video {
    if (_self.video == null) {
      return null;
    }

    return $MessageInputVideoCopyWith<$Res>(_self.video!, (value) {
      return _then(_self.copyWith(video: value));
    });
  }

  /// Create a copy of MessageInputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessageInputFileCopyWith<$Res>? get file {
    if (_self.file == null) {
      return null;
    }

    return $MessageInputFileCopyWith<$Res>(_self.file!, (value) {
      return _then(_self.copyWith(file: value));
    });
  }
}

/// @nodoc
mixin _$MessageOutputPart {
  /// Type of the part
  ChatMessagePartType get type;

  /// Text content
  String? get text;

  /// Image output
  MessagePartCommon? get image;

  /// Audio output
  MessagePartCommon? get audio;

  /// Video output
  MessagePartCommon? get video;

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessageOutputPartCopyWith<MessageOutputPart> get copyWith =>
      _$MessageOutputPartCopyWithImpl<MessageOutputPart>(
          this as MessageOutputPart, _$identity);

  /// Serializes this MessageOutputPart to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MessageOutputPart &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.image, image) || other.image == image) &&
            (identical(other.audio, audio) || other.audio == audio) &&
            (identical(other.video, video) || other.video == video));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, type, text, image, audio, video);

  @override
  String toString() {
    return 'MessageOutputPart(type: $type, text: $text, image: $image, audio: $audio, video: $video)';
  }
}

/// @nodoc
abstract mixin class $MessageOutputPartCopyWith<$Res> {
  factory $MessageOutputPartCopyWith(
          MessageOutputPart value, $Res Function(MessageOutputPart) _then) =
      _$MessageOutputPartCopyWithImpl;
  @useResult
  $Res call(
      {ChatMessagePartType type,
      String? text,
      MessagePartCommon? image,
      MessagePartCommon? audio,
      MessagePartCommon? video});

  $MessagePartCommonCopyWith<$Res>? get image;
  $MessagePartCommonCopyWith<$Res>? get audio;
  $MessagePartCommonCopyWith<$Res>? get video;
}

/// @nodoc
class _$MessageOutputPartCopyWithImpl<$Res>
    implements $MessageOutputPartCopyWith<$Res> {
  _$MessageOutputPartCopyWithImpl(this._self, this._then);

  final MessageOutputPart _self;
  final $Res Function(MessageOutputPart) _then;

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? type = null,
    Object? text = freezed,
    Object? image = freezed,
    Object? audio = freezed,
    Object? video = freezed,
  }) {
    return _then(_self.copyWith(
      type: null == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as ChatMessagePartType,
      text: freezed == text
          ? _self.text
          : text // ignore: cast_nullable_to_non_nullable
              as String?,
      image: freezed == image
          ? _self.image
          : image // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon?,
      audio: freezed == audio
          ? _self.audio
          : audio // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon?,
      video: freezed == video
          ? _self.video
          : video // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon?,
    ));
  }

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res>? get image {
    if (_self.image == null) {
      return null;
    }

    return $MessagePartCommonCopyWith<$Res>(_self.image!, (value) {
      return _then(_self.copyWith(image: value));
    });
  }

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res>? get audio {
    if (_self.audio == null) {
      return null;
    }

    return $MessagePartCommonCopyWith<$Res>(_self.audio!, (value) {
      return _then(_self.copyWith(audio: value));
    });
  }

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res>? get video {
    if (_self.video == null) {
      return null;
    }

    return $MessagePartCommonCopyWith<$Res>(_self.video!, (value) {
      return _then(_self.copyWith(video: value));
    });
  }
}

/// Adds pattern-matching-related methods to [MessageOutputPart].
extension MessageOutputPartPatterns on MessageOutputPart {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_MessageOutputPart value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageOutputPart() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_MessageOutputPart value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageOutputPart():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_MessageOutputPart value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageOutputPart() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
            ChatMessagePartType type,
            String? text,
            MessagePartCommon? image,
            MessagePartCommon? audio,
            MessagePartCommon? video)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _MessageOutputPart() when $default != null:
        return $default(
            _that.type, _that.text, _that.image, _that.audio, _that.video);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
            ChatMessagePartType type,
            String? text,
            MessagePartCommon? image,
            MessagePartCommon? audio,
            MessagePartCommon? video)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageOutputPart():
        return $default(
            _that.type, _that.text, _that.image, _that.audio, _that.video);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
            ChatMessagePartType type,
            String? text,
            MessagePartCommon? image,
            MessagePartCommon? audio,
            MessagePartCommon? video)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _MessageOutputPart() when $default != null:
        return $default(
            _that.type, _that.text, _that.image, _that.audio, _that.video);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _MessageOutputPart implements MessageOutputPart {
  const _MessageOutputPart(
      {required this.type, this.text, this.image, this.audio, this.video});
  factory _MessageOutputPart.fromJson(Map<String, dynamic> json) =>
      _$MessageOutputPartFromJson(json);

  /// Type of the part
  @override
  final ChatMessagePartType type;

  /// Text content
  @override
  final String? text;

  /// Image output
  @override
  final MessagePartCommon? image;

  /// Audio output
  @override
  final MessagePartCommon? audio;

  /// Video output
  @override
  final MessagePartCommon? video;

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessageOutputPartCopyWith<_MessageOutputPart> get copyWith =>
      __$MessageOutputPartCopyWithImpl<_MessageOutputPart>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessageOutputPartToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _MessageOutputPart &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.text, text) || other.text == text) &&
            (identical(other.image, image) || other.image == image) &&
            (identical(other.audio, audio) || other.audio == audio) &&
            (identical(other.video, video) || other.video == video));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, type, text, image, audio, video);

  @override
  String toString() {
    return 'MessageOutputPart(type: $type, text: $text, image: $image, audio: $audio, video: $video)';
  }
}

/// @nodoc
abstract mixin class _$MessageOutputPartCopyWith<$Res>
    implements $MessageOutputPartCopyWith<$Res> {
  factory _$MessageOutputPartCopyWith(
          _MessageOutputPart value, $Res Function(_MessageOutputPart) _then) =
      __$MessageOutputPartCopyWithImpl;
  @override
  @useResult
  $Res call(
      {ChatMessagePartType type,
      String? text,
      MessagePartCommon? image,
      MessagePartCommon? audio,
      MessagePartCommon? video});

  @override
  $MessagePartCommonCopyWith<$Res>? get image;
  @override
  $MessagePartCommonCopyWith<$Res>? get audio;
  @override
  $MessagePartCommonCopyWith<$Res>? get video;
}

/// @nodoc
class __$MessageOutputPartCopyWithImpl<$Res>
    implements _$MessageOutputPartCopyWith<$Res> {
  __$MessageOutputPartCopyWithImpl(this._self, this._then);

  final _MessageOutputPart _self;
  final $Res Function(_MessageOutputPart) _then;

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? type = null,
    Object? text = freezed,
    Object? image = freezed,
    Object? audio = freezed,
    Object? video = freezed,
  }) {
    return _then(_MessageOutputPart(
      type: null == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as ChatMessagePartType,
      text: freezed == text
          ? _self.text
          : text // ignore: cast_nullable_to_non_nullable
              as String?,
      image: freezed == image
          ? _self.image
          : image // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon?,
      audio: freezed == audio
          ? _self.audio
          : audio // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon?,
      video: freezed == video
          ? _self.video
          : video // ignore: cast_nullable_to_non_nullable
              as MessagePartCommon?,
    ));
  }

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res>? get image {
    if (_self.image == null) {
      return null;
    }

    return $MessagePartCommonCopyWith<$Res>(_self.image!, (value) {
      return _then(_self.copyWith(image: value));
    });
  }

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res>? get audio {
    if (_self.audio == null) {
      return null;
    }

    return $MessagePartCommonCopyWith<$Res>(_self.audio!, (value) {
      return _then(_self.copyWith(audio: value));
    });
  }

  /// Create a copy of MessageOutputPart
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $MessagePartCommonCopyWith<$Res>? get video {
    if (_self.video == null) {
      return null;
    }

    return $MessagePartCommonCopyWith<$Res>(_self.video!, (value) {
      return _then(_self.copyWith(video: value));
    });
  }
}

/// @nodoc
mixin _$TokenUsage {
  /// Number of prompt tokens
  int get promptTokens;

  /// Number of completion tokens
  int get completionTokens;

  /// Total number of tokens
  int get totalTokens;

  /// Breakdown of prompt token details
  PromptTokenDetails? get promptTokenDetails;

  /// Breakdown of completion token details (reasoning, image, audio)
  CompletionTokenDetails? get completionTokenDetails;

  /// Cost in USD as reported by the provider (OpenRouter `usage.cost`)
  double? get cost;

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $TokenUsageCopyWith<TokenUsage> get copyWith =>
      _$TokenUsageCopyWithImpl<TokenUsage>(this as TokenUsage, _$identity);

  /// Serializes this TokenUsage to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is TokenUsage &&
            (identical(other.promptTokens, promptTokens) ||
                other.promptTokens == promptTokens) &&
            (identical(other.completionTokens, completionTokens) ||
                other.completionTokens == completionTokens) &&
            (identical(other.totalTokens, totalTokens) ||
                other.totalTokens == totalTokens) &&
            (identical(other.promptTokenDetails, promptTokenDetails) ||
                other.promptTokenDetails == promptTokenDetails) &&
            (identical(other.completionTokenDetails, completionTokenDetails) ||
                other.completionTokenDetails == completionTokenDetails) &&
            (identical(other.cost, cost) || other.cost == cost));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, promptTokens, completionTokens,
      totalTokens, promptTokenDetails, completionTokenDetails, cost);

  @override
  String toString() {
    return 'TokenUsage(promptTokens: $promptTokens, completionTokens: $completionTokens, totalTokens: $totalTokens, promptTokenDetails: $promptTokenDetails, completionTokenDetails: $completionTokenDetails, cost: $cost)';
  }
}

/// @nodoc
abstract mixin class $TokenUsageCopyWith<$Res> {
  factory $TokenUsageCopyWith(
          TokenUsage value, $Res Function(TokenUsage) _then) =
      _$TokenUsageCopyWithImpl;
  @useResult
  $Res call(
      {int promptTokens,
      int completionTokens,
      int totalTokens,
      PromptTokenDetails? promptTokenDetails,
      CompletionTokenDetails? completionTokenDetails,
      double? cost});

  $PromptTokenDetailsCopyWith<$Res>? get promptTokenDetails;
  $CompletionTokenDetailsCopyWith<$Res>? get completionTokenDetails;
}

/// @nodoc
class _$TokenUsageCopyWithImpl<$Res> implements $TokenUsageCopyWith<$Res> {
  _$TokenUsageCopyWithImpl(this._self, this._then);

  final TokenUsage _self;
  final $Res Function(TokenUsage) _then;

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? promptTokens = null,
    Object? completionTokens = null,
    Object? totalTokens = null,
    Object? promptTokenDetails = freezed,
    Object? completionTokenDetails = freezed,
    Object? cost = freezed,
  }) {
    return _then(_self.copyWith(
      promptTokens: null == promptTokens
          ? _self.promptTokens
          : promptTokens // ignore: cast_nullable_to_non_nullable
              as int,
      completionTokens: null == completionTokens
          ? _self.completionTokens
          : completionTokens // ignore: cast_nullable_to_non_nullable
              as int,
      totalTokens: null == totalTokens
          ? _self.totalTokens
          : totalTokens // ignore: cast_nullable_to_non_nullable
              as int,
      promptTokenDetails: freezed == promptTokenDetails
          ? _self.promptTokenDetails
          : promptTokenDetails // ignore: cast_nullable_to_non_nullable
              as PromptTokenDetails?,
      completionTokenDetails: freezed == completionTokenDetails
          ? _self.completionTokenDetails
          : completionTokenDetails // ignore: cast_nullable_to_non_nullable
              as CompletionTokenDetails?,
      cost: freezed == cost
          ? _self.cost
          : cost // ignore: cast_nullable_to_non_nullable
              as double?,
    ));
  }

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $PromptTokenDetailsCopyWith<$Res>? get promptTokenDetails {
    if (_self.promptTokenDetails == null) {
      return null;
    }

    return $PromptTokenDetailsCopyWith<$Res>(_self.promptTokenDetails!,
        (value) {
      return _then(_self.copyWith(promptTokenDetails: value));
    });
  }

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $CompletionTokenDetailsCopyWith<$Res>? get completionTokenDetails {
    if (_self.completionTokenDetails == null) {
      return null;
    }

    return $CompletionTokenDetailsCopyWith<$Res>(_self.completionTokenDetails!,
        (value) {
      return _then(_self.copyWith(completionTokenDetails: value));
    });
  }
}

/// Adds pattern-matching-related methods to [TokenUsage].
extension TokenUsagePatterns on TokenUsage {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_TokenUsage value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _TokenUsage() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_TokenUsage value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TokenUsage():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_TokenUsage value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TokenUsage() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
            int promptTokens,
            int completionTokens,
            int totalTokens,
            PromptTokenDetails? promptTokenDetails,
            CompletionTokenDetails? completionTokenDetails,
            double? cost)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _TokenUsage() when $default != null:
        return $default(
            _that.promptTokens,
            _that.completionTokens,
            _that.totalTokens,
            _that.promptTokenDetails,
            _that.completionTokenDetails,
            _that.cost);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
            int promptTokens,
            int completionTokens,
            int totalTokens,
            PromptTokenDetails? promptTokenDetails,
            CompletionTokenDetails? completionTokenDetails,
            double? cost)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TokenUsage():
        return $default(
            _that.promptTokens,
            _that.completionTokens,
            _that.totalTokens,
            _that.promptTokenDetails,
            _that.completionTokenDetails,
            _that.cost);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
            int promptTokens,
            int completionTokens,
            int totalTokens,
            PromptTokenDetails? promptTokenDetails,
            CompletionTokenDetails? completionTokenDetails,
            double? cost)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TokenUsage() when $default != null:
        return $default(
            _that.promptTokens,
            _that.completionTokens,
            _that.totalTokens,
            _that.promptTokenDetails,
            _that.completionTokenDetails,
            _that.cost);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _TokenUsage extends TokenUsage {
  const _TokenUsage(
      {required this.promptTokens,
      required this.completionTokens,
      required this.totalTokens,
      this.promptTokenDetails,
      this.completionTokenDetails,
      this.cost})
      : super._();
  factory _TokenUsage.fromJson(Map<String, dynamic> json) =>
      _$TokenUsageFromJson(json);

  /// Number of prompt tokens
  @override
  final int promptTokens;

  /// Number of completion tokens
  @override
  final int completionTokens;

  /// Total number of tokens
  @override
  final int totalTokens;

  /// Breakdown of prompt token details
  @override
  final PromptTokenDetails? promptTokenDetails;

  /// Breakdown of completion token details (reasoning, image, audio)
  @override
  final CompletionTokenDetails? completionTokenDetails;

  /// Cost in USD as reported by the provider (OpenRouter `usage.cost`)
  @override
  final double? cost;

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$TokenUsageCopyWith<_TokenUsage> get copyWith =>
      __$TokenUsageCopyWithImpl<_TokenUsage>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$TokenUsageToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _TokenUsage &&
            (identical(other.promptTokens, promptTokens) ||
                other.promptTokens == promptTokens) &&
            (identical(other.completionTokens, completionTokens) ||
                other.completionTokens == completionTokens) &&
            (identical(other.totalTokens, totalTokens) ||
                other.totalTokens == totalTokens) &&
            (identical(other.promptTokenDetails, promptTokenDetails) ||
                other.promptTokenDetails == promptTokenDetails) &&
            (identical(other.completionTokenDetails, completionTokenDetails) ||
                other.completionTokenDetails == completionTokenDetails) &&
            (identical(other.cost, cost) || other.cost == cost));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, promptTokens, completionTokens,
      totalTokens, promptTokenDetails, completionTokenDetails, cost);

  @override
  String toString() {
    return 'TokenUsage(promptTokens: $promptTokens, completionTokens: $completionTokens, totalTokens: $totalTokens, promptTokenDetails: $promptTokenDetails, completionTokenDetails: $completionTokenDetails, cost: $cost)';
  }
}

/// @nodoc
abstract mixin class _$TokenUsageCopyWith<$Res>
    implements $TokenUsageCopyWith<$Res> {
  factory _$TokenUsageCopyWith(
          _TokenUsage value, $Res Function(_TokenUsage) _then) =
      __$TokenUsageCopyWithImpl;
  @override
  @useResult
  $Res call(
      {int promptTokens,
      int completionTokens,
      int totalTokens,
      PromptTokenDetails? promptTokenDetails,
      CompletionTokenDetails? completionTokenDetails,
      double? cost});

  @override
  $PromptTokenDetailsCopyWith<$Res>? get promptTokenDetails;
  @override
  $CompletionTokenDetailsCopyWith<$Res>? get completionTokenDetails;
}

/// @nodoc
class __$TokenUsageCopyWithImpl<$Res> implements _$TokenUsageCopyWith<$Res> {
  __$TokenUsageCopyWithImpl(this._self, this._then);

  final _TokenUsage _self;
  final $Res Function(_TokenUsage) _then;

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? promptTokens = null,
    Object? completionTokens = null,
    Object? totalTokens = null,
    Object? promptTokenDetails = freezed,
    Object? completionTokenDetails = freezed,
    Object? cost = freezed,
  }) {
    return _then(_TokenUsage(
      promptTokens: null == promptTokens
          ? _self.promptTokens
          : promptTokens // ignore: cast_nullable_to_non_nullable
              as int,
      completionTokens: null == completionTokens
          ? _self.completionTokens
          : completionTokens // ignore: cast_nullable_to_non_nullable
              as int,
      totalTokens: null == totalTokens
          ? _self.totalTokens
          : totalTokens // ignore: cast_nullable_to_non_nullable
              as int,
      promptTokenDetails: freezed == promptTokenDetails
          ? _self.promptTokenDetails
          : promptTokenDetails // ignore: cast_nullable_to_non_nullable
              as PromptTokenDetails?,
      completionTokenDetails: freezed == completionTokenDetails
          ? _self.completionTokenDetails
          : completionTokenDetails // ignore: cast_nullable_to_non_nullable
              as CompletionTokenDetails?,
      cost: freezed == cost
          ? _self.cost
          : cost // ignore: cast_nullable_to_non_nullable
              as double?,
    ));
  }

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $PromptTokenDetailsCopyWith<$Res>? get promptTokenDetails {
    if (_self.promptTokenDetails == null) {
      return null;
    }

    return $PromptTokenDetailsCopyWith<$Res>(_self.promptTokenDetails!,
        (value) {
      return _then(_self.copyWith(promptTokenDetails: value));
    });
  }

  /// Create a copy of TokenUsage
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $CompletionTokenDetailsCopyWith<$Res>? get completionTokenDetails {
    if (_self.completionTokenDetails == null) {
      return null;
    }

    return $CompletionTokenDetailsCopyWith<$Res>(_self.completionTokenDetails!,
        (value) {
      return _then(_self.copyWith(completionTokenDetails: value));
    });
  }
}

/// @nodoc
mixin _$CompletionTokenDetails {
  /// Tokens spent on reasoning / thinking
  int get reasoningTokens;

  /// Tokens spent producing images
  int get imageTokens;

  /// Tokens spent producing audio
  int get audioTokens;

  /// Create a copy of CompletionTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $CompletionTokenDetailsCopyWith<CompletionTokenDetails> get copyWith =>
      _$CompletionTokenDetailsCopyWithImpl<CompletionTokenDetails>(
          this as CompletionTokenDetails, _$identity);

  /// Serializes this CompletionTokenDetails to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is CompletionTokenDetails &&
            (identical(other.reasoningTokens, reasoningTokens) ||
                other.reasoningTokens == reasoningTokens) &&
            (identical(other.imageTokens, imageTokens) ||
                other.imageTokens == imageTokens) &&
            (identical(other.audioTokens, audioTokens) ||
                other.audioTokens == audioTokens));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, reasoningTokens, imageTokens, audioTokens);

  @override
  String toString() {
    return 'CompletionTokenDetails(reasoningTokens: $reasoningTokens, imageTokens: $imageTokens, audioTokens: $audioTokens)';
  }
}

/// @nodoc
abstract mixin class $CompletionTokenDetailsCopyWith<$Res> {
  factory $CompletionTokenDetailsCopyWith(CompletionTokenDetails value,
          $Res Function(CompletionTokenDetails) _then) =
      _$CompletionTokenDetailsCopyWithImpl;
  @useResult
  $Res call({int reasoningTokens, int imageTokens, int audioTokens});
}

/// @nodoc
class _$CompletionTokenDetailsCopyWithImpl<$Res>
    implements $CompletionTokenDetailsCopyWith<$Res> {
  _$CompletionTokenDetailsCopyWithImpl(this._self, this._then);

  final CompletionTokenDetails _self;
  final $Res Function(CompletionTokenDetails) _then;

  /// Create a copy of CompletionTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? reasoningTokens = null,
    Object? imageTokens = null,
    Object? audioTokens = null,
  }) {
    return _then(_self.copyWith(
      reasoningTokens: null == reasoningTokens
          ? _self.reasoningTokens
          : reasoningTokens // ignore: cast_nullable_to_non_nullable
              as int,
      imageTokens: null == imageTokens
          ? _self.imageTokens
          : imageTokens // ignore: cast_nullable_to_non_nullable
              as int,
      audioTokens: null == audioTokens
          ? _self.audioTokens
          : audioTokens // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// Adds pattern-matching-related methods to [CompletionTokenDetails].
extension CompletionTokenDetailsPatterns on CompletionTokenDetails {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_CompletionTokenDetails value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _CompletionTokenDetails() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_CompletionTokenDetails value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _CompletionTokenDetails():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_CompletionTokenDetails value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _CompletionTokenDetails() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(int reasoningTokens, int imageTokens, int audioTokens)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _CompletionTokenDetails() when $default != null:
        return $default(
            _that.reasoningTokens, _that.imageTokens, _that.audioTokens);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(int reasoningTokens, int imageTokens, int audioTokens)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _CompletionTokenDetails():
        return $default(
            _that.reasoningTokens, _that.imageTokens, _that.audioTokens);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(int reasoningTokens, int imageTokens, int audioTokens)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _CompletionTokenDetails() when $default != null:
        return $default(
            _that.reasoningTokens, _that.imageTokens, _that.audioTokens);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _CompletionTokenDetails implements CompletionTokenDetails {
  const _CompletionTokenDetails(
      {this.reasoningTokens = 0, this.imageTokens = 0, this.audioTokens = 0});
  factory _CompletionTokenDetails.fromJson(Map<String, dynamic> json) =>
      _$CompletionTokenDetailsFromJson(json);

  /// Tokens spent on reasoning / thinking
  @override
  @JsonKey()
  final int reasoningTokens;

  /// Tokens spent producing images
  @override
  @JsonKey()
  final int imageTokens;

  /// Tokens spent producing audio
  @override
  @JsonKey()
  final int audioTokens;

  /// Create a copy of CompletionTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$CompletionTokenDetailsCopyWith<_CompletionTokenDetails> get copyWith =>
      __$CompletionTokenDetailsCopyWithImpl<_CompletionTokenDetails>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$CompletionTokenDetailsToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _CompletionTokenDetails &&
            (identical(other.reasoningTokens, reasoningTokens) ||
                other.reasoningTokens == reasoningTokens) &&
            (identical(other.imageTokens, imageTokens) ||
                other.imageTokens == imageTokens) &&
            (identical(other.audioTokens, audioTokens) ||
                other.audioTokens == audioTokens));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, reasoningTokens, imageTokens, audioTokens);

  @override
  String toString() {
    return 'CompletionTokenDetails(reasoningTokens: $reasoningTokens, imageTokens: $imageTokens, audioTokens: $audioTokens)';
  }
}

/// @nodoc
abstract mixin class _$CompletionTokenDetailsCopyWith<$Res>
    implements $CompletionTokenDetailsCopyWith<$Res> {
  factory _$CompletionTokenDetailsCopyWith(_CompletionTokenDetails value,
          $Res Function(_CompletionTokenDetails) _then) =
      __$CompletionTokenDetailsCopyWithImpl;
  @override
  @useResult
  $Res call({int reasoningTokens, int imageTokens, int audioTokens});
}

/// @nodoc
class __$CompletionTokenDetailsCopyWithImpl<$Res>
    implements _$CompletionTokenDetailsCopyWith<$Res> {
  __$CompletionTokenDetailsCopyWithImpl(this._self, this._then);

  final _CompletionTokenDetails _self;
  final $Res Function(_CompletionTokenDetails) _then;

  /// Create a copy of CompletionTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? reasoningTokens = null,
    Object? imageTokens = null,
    Object? audioTokens = null,
  }) {
    return _then(_CompletionTokenDetails(
      reasoningTokens: null == reasoningTokens
          ? _self.reasoningTokens
          : reasoningTokens // ignore: cast_nullable_to_non_nullable
              as int,
      imageTokens: null == imageTokens
          ? _self.imageTokens
          : imageTokens // ignore: cast_nullable_to_non_nullable
              as int,
      audioTokens: null == audioTokens
          ? _self.audioTokens
          : audioTokens // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc
mixin _$PromptTokenDetails {
  /// Cached tokens in the prompt
  int get cachedTokens;

  /// Create a copy of PromptTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $PromptTokenDetailsCopyWith<PromptTokenDetails> get copyWith =>
      _$PromptTokenDetailsCopyWithImpl<PromptTokenDetails>(
          this as PromptTokenDetails, _$identity);

  /// Serializes this PromptTokenDetails to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is PromptTokenDetails &&
            (identical(other.cachedTokens, cachedTokens) ||
                other.cachedTokens == cachedTokens));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, cachedTokens);

  @override
  String toString() {
    return 'PromptTokenDetails(cachedTokens: $cachedTokens)';
  }
}

/// @nodoc
abstract mixin class $PromptTokenDetailsCopyWith<$Res> {
  factory $PromptTokenDetailsCopyWith(
          PromptTokenDetails value, $Res Function(PromptTokenDetails) _then) =
      _$PromptTokenDetailsCopyWithImpl;
  @useResult
  $Res call({int cachedTokens});
}

/// @nodoc
class _$PromptTokenDetailsCopyWithImpl<$Res>
    implements $PromptTokenDetailsCopyWith<$Res> {
  _$PromptTokenDetailsCopyWithImpl(this._self, this._then);

  final PromptTokenDetails _self;
  final $Res Function(PromptTokenDetails) _then;

  /// Create a copy of PromptTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? cachedTokens = null,
  }) {
    return _then(_self.copyWith(
      cachedTokens: null == cachedTokens
          ? _self.cachedTokens
          : cachedTokens // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// Adds pattern-matching-related methods to [PromptTokenDetails].
extension PromptTokenDetailsPatterns on PromptTokenDetails {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_PromptTokenDetails value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _PromptTokenDetails() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_PromptTokenDetails value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _PromptTokenDetails():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_PromptTokenDetails value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _PromptTokenDetails() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(int cachedTokens)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _PromptTokenDetails() when $default != null:
        return $default(_that.cachedTokens);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(int cachedTokens) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _PromptTokenDetails():
        return $default(_that.cachedTokens);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(int cachedTokens)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _PromptTokenDetails() when $default != null:
        return $default(_that.cachedTokens);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _PromptTokenDetails implements PromptTokenDetails {
  const _PromptTokenDetails({this.cachedTokens = 0});
  factory _PromptTokenDetails.fromJson(Map<String, dynamic> json) =>
      _$PromptTokenDetailsFromJson(json);

  /// Cached tokens in the prompt
  @override
  @JsonKey()
  final int cachedTokens;

  /// Create a copy of PromptTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$PromptTokenDetailsCopyWith<_PromptTokenDetails> get copyWith =>
      __$PromptTokenDetailsCopyWithImpl<_PromptTokenDetails>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$PromptTokenDetailsToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _PromptTokenDetails &&
            (identical(other.cachedTokens, cachedTokens) ||
                other.cachedTokens == cachedTokens));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, cachedTokens);

  @override
  String toString() {
    return 'PromptTokenDetails(cachedTokens: $cachedTokens)';
  }
}

/// @nodoc
abstract mixin class _$PromptTokenDetailsCopyWith<$Res>
    implements $PromptTokenDetailsCopyWith<$Res> {
  factory _$PromptTokenDetailsCopyWith(
          _PromptTokenDetails value, $Res Function(_PromptTokenDetails) _then) =
      __$PromptTokenDetailsCopyWithImpl;
  @override
  @useResult
  $Res call({int cachedTokens});
}

/// @nodoc
class __$PromptTokenDetailsCopyWithImpl<$Res>
    implements _$PromptTokenDetailsCopyWith<$Res> {
  __$PromptTokenDetailsCopyWithImpl(this._self, this._then);

  final _PromptTokenDetails _self;
  final $Res Function(_PromptTokenDetails) _then;

  /// Create a copy of PromptTokenDetails
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? cachedTokens = null,
  }) {
    return _then(_PromptTokenDetails(
      cachedTokens: null == cachedTokens
          ? _self.cachedTokens
          : cachedTokens // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc
mixin _$LogProb {
  /// The token text
  String get token;

  /// Log probability of this token
  double get logProb;

  /// UTF-8 bytes representation
  List<int>? get bytes;

  /// Top log probabilities at this position
  List<TopLogProb> get topLogProbs;

  /// Create a copy of LogProb
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $LogProbCopyWith<LogProb> get copyWith =>
      _$LogProbCopyWithImpl<LogProb>(this as LogProb, _$identity);

  /// Serializes this LogProb to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is LogProb &&
            (identical(other.token, token) || other.token == token) &&
            (identical(other.logProb, logProb) || other.logProb == logProb) &&
            const DeepCollectionEquality().equals(other.bytes, bytes) &&
            const DeepCollectionEquality()
                .equals(other.topLogProbs, topLogProbs));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      token,
      logProb,
      const DeepCollectionEquality().hash(bytes),
      const DeepCollectionEquality().hash(topLogProbs));

  @override
  String toString() {
    return 'LogProb(token: $token, logProb: $logProb, bytes: $bytes, topLogProbs: $topLogProbs)';
  }
}

/// @nodoc
abstract mixin class $LogProbCopyWith<$Res> {
  factory $LogProbCopyWith(LogProb value, $Res Function(LogProb) _then) =
      _$LogProbCopyWithImpl;
  @useResult
  $Res call(
      {String token,
      double logProb,
      List<int>? bytes,
      List<TopLogProb> topLogProbs});
}

/// @nodoc
class _$LogProbCopyWithImpl<$Res> implements $LogProbCopyWith<$Res> {
  _$LogProbCopyWithImpl(this._self, this._then);

  final LogProb _self;
  final $Res Function(LogProb) _then;

  /// Create a copy of LogProb
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? token = null,
    Object? logProb = null,
    Object? bytes = freezed,
    Object? topLogProbs = null,
  }) {
    return _then(_self.copyWith(
      token: null == token
          ? _self.token
          : token // ignore: cast_nullable_to_non_nullable
              as String,
      logProb: null == logProb
          ? _self.logProb
          : logProb // ignore: cast_nullable_to_non_nullable
              as double,
      bytes: freezed == bytes
          ? _self.bytes
          : bytes // ignore: cast_nullable_to_non_nullable
              as List<int>?,
      topLogProbs: null == topLogProbs
          ? _self.topLogProbs
          : topLogProbs // ignore: cast_nullable_to_non_nullable
              as List<TopLogProb>,
    ));
  }
}

/// Adds pattern-matching-related methods to [LogProb].
extension LogProbPatterns on LogProb {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_LogProb value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _LogProb() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_LogProb value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProb():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_LogProb value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProb() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(String token, double logProb, List<int>? bytes,
            List<TopLogProb> topLogProbs)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _LogProb() when $default != null:
        return $default(
            _that.token, _that.logProb, _that.bytes, _that.topLogProbs);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(String token, double logProb, List<int>? bytes,
            List<TopLogProb> topLogProbs)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProb():
        return $default(
            _that.token, _that.logProb, _that.bytes, _that.topLogProbs);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(String token, double logProb, List<int>? bytes,
            List<TopLogProb> topLogProbs)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProb() when $default != null:
        return $default(
            _that.token, _that.logProb, _that.bytes, _that.topLogProbs);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _LogProb implements LogProb {
  const _LogProb(
      {required this.token,
      required this.logProb,
      final List<int>? bytes,
      final List<TopLogProb> topLogProbs = const []})
      : _bytes = bytes,
        _topLogProbs = topLogProbs;
  factory _LogProb.fromJson(Map<String, dynamic> json) =>
      _$LogProbFromJson(json);

  /// The token text
  @override
  final String token;

  /// Log probability of this token
  @override
  final double logProb;

  /// UTF-8 bytes representation
  final List<int>? _bytes;

  /// UTF-8 bytes representation
  @override
  List<int>? get bytes {
    final value = _bytes;
    if (value == null) return null;
    if (_bytes is EqualUnmodifiableListView) return _bytes;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Top log probabilities at this position
  final List<TopLogProb> _topLogProbs;

  /// Top log probabilities at this position
  @override
  @JsonKey()
  List<TopLogProb> get topLogProbs {
    if (_topLogProbs is EqualUnmodifiableListView) return _topLogProbs;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_topLogProbs);
  }

  /// Create a copy of LogProb
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$LogProbCopyWith<_LogProb> get copyWith =>
      __$LogProbCopyWithImpl<_LogProb>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$LogProbToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _LogProb &&
            (identical(other.token, token) || other.token == token) &&
            (identical(other.logProb, logProb) || other.logProb == logProb) &&
            const DeepCollectionEquality().equals(other._bytes, _bytes) &&
            const DeepCollectionEquality()
                .equals(other._topLogProbs, _topLogProbs));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      token,
      logProb,
      const DeepCollectionEquality().hash(_bytes),
      const DeepCollectionEquality().hash(_topLogProbs));

  @override
  String toString() {
    return 'LogProb(token: $token, logProb: $logProb, bytes: $bytes, topLogProbs: $topLogProbs)';
  }
}

/// @nodoc
abstract mixin class _$LogProbCopyWith<$Res> implements $LogProbCopyWith<$Res> {
  factory _$LogProbCopyWith(_LogProb value, $Res Function(_LogProb) _then) =
      __$LogProbCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String token,
      double logProb,
      List<int>? bytes,
      List<TopLogProb> topLogProbs});
}

/// @nodoc
class __$LogProbCopyWithImpl<$Res> implements _$LogProbCopyWith<$Res> {
  __$LogProbCopyWithImpl(this._self, this._then);

  final _LogProb _self;
  final $Res Function(_LogProb) _then;

  /// Create a copy of LogProb
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? token = null,
    Object? logProb = null,
    Object? bytes = freezed,
    Object? topLogProbs = null,
  }) {
    return _then(_LogProb(
      token: null == token
          ? _self.token
          : token // ignore: cast_nullable_to_non_nullable
              as String,
      logProb: null == logProb
          ? _self.logProb
          : logProb // ignore: cast_nullable_to_non_nullable
              as double,
      bytes: freezed == bytes
          ? _self._bytes
          : bytes // ignore: cast_nullable_to_non_nullable
              as List<int>?,
      topLogProbs: null == topLogProbs
          ? _self._topLogProbs
          : topLogProbs // ignore: cast_nullable_to_non_nullable
              as List<TopLogProb>,
    ));
  }
}

/// @nodoc
mixin _$TopLogProb {
  /// The token text
  String get token;

  /// Log probability of this token
  double get logProb;

  /// UTF-8 bytes representation
  List<int>? get bytes;

  /// Create a copy of TopLogProb
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $TopLogProbCopyWith<TopLogProb> get copyWith =>
      _$TopLogProbCopyWithImpl<TopLogProb>(this as TopLogProb, _$identity);

  /// Serializes this TopLogProb to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is TopLogProb &&
            (identical(other.token, token) || other.token == token) &&
            (identical(other.logProb, logProb) || other.logProb == logProb) &&
            const DeepCollectionEquality().equals(other.bytes, bytes));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, token, logProb, const DeepCollectionEquality().hash(bytes));

  @override
  String toString() {
    return 'TopLogProb(token: $token, logProb: $logProb, bytes: $bytes)';
  }
}

/// @nodoc
abstract mixin class $TopLogProbCopyWith<$Res> {
  factory $TopLogProbCopyWith(
          TopLogProb value, $Res Function(TopLogProb) _then) =
      _$TopLogProbCopyWithImpl;
  @useResult
  $Res call({String token, double logProb, List<int>? bytes});
}

/// @nodoc
class _$TopLogProbCopyWithImpl<$Res> implements $TopLogProbCopyWith<$Res> {
  _$TopLogProbCopyWithImpl(this._self, this._then);

  final TopLogProb _self;
  final $Res Function(TopLogProb) _then;

  /// Create a copy of TopLogProb
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? token = null,
    Object? logProb = null,
    Object? bytes = freezed,
  }) {
    return _then(_self.copyWith(
      token: null == token
          ? _self.token
          : token // ignore: cast_nullable_to_non_nullable
              as String,
      logProb: null == logProb
          ? _self.logProb
          : logProb // ignore: cast_nullable_to_non_nullable
              as double,
      bytes: freezed == bytes
          ? _self.bytes
          : bytes // ignore: cast_nullable_to_non_nullable
              as List<int>?,
    ));
  }
}

/// Adds pattern-matching-related methods to [TopLogProb].
extension TopLogProbPatterns on TopLogProb {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_TopLogProb value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _TopLogProb() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_TopLogProb value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TopLogProb():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_TopLogProb value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TopLogProb() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(String token, double logProb, List<int>? bytes)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _TopLogProb() when $default != null:
        return $default(_that.token, _that.logProb, _that.bytes);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(String token, double logProb, List<int>? bytes) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TopLogProb():
        return $default(_that.token, _that.logProb, _that.bytes);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(String token, double logProb, List<int>? bytes)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _TopLogProb() when $default != null:
        return $default(_that.token, _that.logProb, _that.bytes);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _TopLogProb implements TopLogProb {
  const _TopLogProb(
      {required this.token, required this.logProb, final List<int>? bytes})
      : _bytes = bytes;
  factory _TopLogProb.fromJson(Map<String, dynamic> json) =>
      _$TopLogProbFromJson(json);

  /// The token text
  @override
  final String token;

  /// Log probability of this token
  @override
  final double logProb;

  /// UTF-8 bytes representation
  final List<int>? _bytes;

  /// UTF-8 bytes representation
  @override
  List<int>? get bytes {
    final value = _bytes;
    if (value == null) return null;
    if (_bytes is EqualUnmodifiableListView) return _bytes;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Create a copy of TopLogProb
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$TopLogProbCopyWith<_TopLogProb> get copyWith =>
      __$TopLogProbCopyWithImpl<_TopLogProb>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$TopLogProbToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _TopLogProb &&
            (identical(other.token, token) || other.token == token) &&
            (identical(other.logProb, logProb) || other.logProb == logProb) &&
            const DeepCollectionEquality().equals(other._bytes, _bytes));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, token, logProb, const DeepCollectionEquality().hash(_bytes));

  @override
  String toString() {
    return 'TopLogProb(token: $token, logProb: $logProb, bytes: $bytes)';
  }
}

/// @nodoc
abstract mixin class _$TopLogProbCopyWith<$Res>
    implements $TopLogProbCopyWith<$Res> {
  factory _$TopLogProbCopyWith(
          _TopLogProb value, $Res Function(_TopLogProb) _then) =
      __$TopLogProbCopyWithImpl;
  @override
  @useResult
  $Res call({String token, double logProb, List<int>? bytes});
}

/// @nodoc
class __$TopLogProbCopyWithImpl<$Res> implements _$TopLogProbCopyWith<$Res> {
  __$TopLogProbCopyWithImpl(this._self, this._then);

  final _TopLogProb _self;
  final $Res Function(_TopLogProb) _then;

  /// Create a copy of TopLogProb
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? token = null,
    Object? logProb = null,
    Object? bytes = freezed,
  }) {
    return _then(_TopLogProb(
      token: null == token
          ? _self.token
          : token // ignore: cast_nullable_to_non_nullable
              as String,
      logProb: null == logProb
          ? _self.logProb
          : logProb // ignore: cast_nullable_to_non_nullable
              as double,
      bytes: freezed == bytes
          ? _self._bytes
          : bytes // ignore: cast_nullable_to_non_nullable
              as List<int>?,
    ));
  }
}

/// @nodoc
mixin _$LogProbs {
  /// Content with log probability information
  List<LogProb> get content;

  /// Create a copy of LogProbs
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $LogProbsCopyWith<LogProbs> get copyWith =>
      _$LogProbsCopyWithImpl<LogProbs>(this as LogProbs, _$identity);

  /// Serializes this LogProbs to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is LogProbs &&
            const DeepCollectionEquality().equals(other.content, content));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(content));

  @override
  String toString() {
    return 'LogProbs(content: $content)';
  }
}

/// @nodoc
abstract mixin class $LogProbsCopyWith<$Res> {
  factory $LogProbsCopyWith(LogProbs value, $Res Function(LogProbs) _then) =
      _$LogProbsCopyWithImpl;
  @useResult
  $Res call({List<LogProb> content});
}

/// @nodoc
class _$LogProbsCopyWithImpl<$Res> implements $LogProbsCopyWith<$Res> {
  _$LogProbsCopyWithImpl(this._self, this._then);

  final LogProbs _self;
  final $Res Function(LogProbs) _then;

  /// Create a copy of LogProbs
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? content = null,
  }) {
    return _then(_self.copyWith(
      content: null == content
          ? _self.content
          : content // ignore: cast_nullable_to_non_nullable
              as List<LogProb>,
    ));
  }
}

/// Adds pattern-matching-related methods to [LogProbs].
extension LogProbsPatterns on LogProbs {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_LogProbs value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _LogProbs() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_LogProbs value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProbs():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_LogProbs value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProbs() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(List<LogProb> content)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _LogProbs() when $default != null:
        return $default(_that.content);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(List<LogProb> content) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProbs():
        return $default(_that.content);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(List<LogProb> content)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _LogProbs() when $default != null:
        return $default(_that.content);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _LogProbs implements LogProbs {
  const _LogProbs({final List<LogProb> content = const []})
      : _content = content;
  factory _LogProbs.fromJson(Map<String, dynamic> json) =>
      _$LogProbsFromJson(json);

  /// Content with log probability information
  final List<LogProb> _content;

  /// Content with log probability information
  @override
  @JsonKey()
  List<LogProb> get content {
    if (_content is EqualUnmodifiableListView) return _content;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_content);
  }

  /// Create a copy of LogProbs
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$LogProbsCopyWith<_LogProbs> get copyWith =>
      __$LogProbsCopyWithImpl<_LogProbs>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$LogProbsToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _LogProbs &&
            const DeepCollectionEquality().equals(other._content, _content));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(_content));

  @override
  String toString() {
    return 'LogProbs(content: $content)';
  }
}

/// @nodoc
abstract mixin class _$LogProbsCopyWith<$Res>
    implements $LogProbsCopyWith<$Res> {
  factory _$LogProbsCopyWith(_LogProbs value, $Res Function(_LogProbs) _then) =
      __$LogProbsCopyWithImpl;
  @override
  @useResult
  $Res call({List<LogProb> content});
}

/// @nodoc
class __$LogProbsCopyWithImpl<$Res> implements _$LogProbsCopyWith<$Res> {
  __$LogProbsCopyWithImpl(this._self, this._then);

  final _LogProbs _self;
  final $Res Function(_LogProbs) _then;

  /// Create a copy of LogProbs
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? content = null,
  }) {
    return _then(_LogProbs(
      content: null == content
          ? _self._content
          : content // ignore: cast_nullable_to_non_nullable
              as List<LogProb>,
    ));
  }
}

/// @nodoc
mixin _$ResponseMeta {
  /// Reason for finishing (e.g., "stop", "length", "tool_calls")
  String? get finishReason;

  /// Token usage information
  TokenUsage? get usage;

  /// Log probability information
  LogProbs? get logProbs;

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ResponseMetaCopyWith<ResponseMeta> get copyWith =>
      _$ResponseMetaCopyWithImpl<ResponseMeta>(
          this as ResponseMeta, _$identity);

  /// Serializes this ResponseMeta to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ResponseMeta &&
            (identical(other.finishReason, finishReason) ||
                other.finishReason == finishReason) &&
            (identical(other.usage, usage) || other.usage == usage) &&
            (identical(other.logProbs, logProbs) ||
                other.logProbs == logProbs));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, finishReason, usage, logProbs);

  @override
  String toString() {
    return 'ResponseMeta(finishReason: $finishReason, usage: $usage, logProbs: $logProbs)';
  }
}

/// @nodoc
abstract mixin class $ResponseMetaCopyWith<$Res> {
  factory $ResponseMetaCopyWith(
          ResponseMeta value, $Res Function(ResponseMeta) _then) =
      _$ResponseMetaCopyWithImpl;
  @useResult
  $Res call({String? finishReason, TokenUsage? usage, LogProbs? logProbs});

  $TokenUsageCopyWith<$Res>? get usage;
  $LogProbsCopyWith<$Res>? get logProbs;
}

/// @nodoc
class _$ResponseMetaCopyWithImpl<$Res> implements $ResponseMetaCopyWith<$Res> {
  _$ResponseMetaCopyWithImpl(this._self, this._then);

  final ResponseMeta _self;
  final $Res Function(ResponseMeta) _then;

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? finishReason = freezed,
    Object? usage = freezed,
    Object? logProbs = freezed,
  }) {
    return _then(_self.copyWith(
      finishReason: freezed == finishReason
          ? _self.finishReason
          : finishReason // ignore: cast_nullable_to_non_nullable
              as String?,
      usage: freezed == usage
          ? _self.usage
          : usage // ignore: cast_nullable_to_non_nullable
              as TokenUsage?,
      logProbs: freezed == logProbs
          ? _self.logProbs
          : logProbs // ignore: cast_nullable_to_non_nullable
              as LogProbs?,
    ));
  }

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $TokenUsageCopyWith<$Res>? get usage {
    if (_self.usage == null) {
      return null;
    }

    return $TokenUsageCopyWith<$Res>(_self.usage!, (value) {
      return _then(_self.copyWith(usage: value));
    });
  }

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $LogProbsCopyWith<$Res>? get logProbs {
    if (_self.logProbs == null) {
      return null;
    }

    return $LogProbsCopyWith<$Res>(_self.logProbs!, (value) {
      return _then(_self.copyWith(logProbs: value));
    });
  }
}

/// Adds pattern-matching-related methods to [ResponseMeta].
extension ResponseMetaPatterns on ResponseMeta {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_ResponseMeta value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ResponseMeta() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_ResponseMeta value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ResponseMeta():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_ResponseMeta value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ResponseMeta() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
            String? finishReason, TokenUsage? usage, LogProbs? logProbs)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ResponseMeta() when $default != null:
        return $default(_that.finishReason, _that.usage, _that.logProbs);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
            String? finishReason, TokenUsage? usage, LogProbs? logProbs)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ResponseMeta():
        return $default(_that.finishReason, _that.usage, _that.logProbs);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
            String? finishReason, TokenUsage? usage, LogProbs? logProbs)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ResponseMeta() when $default != null:
        return $default(_that.finishReason, _that.usage, _that.logProbs);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _ResponseMeta implements ResponseMeta {
  const _ResponseMeta({this.finishReason, this.usage, this.logProbs});
  factory _ResponseMeta.fromJson(Map<String, dynamic> json) =>
      _$ResponseMetaFromJson(json);

  /// Reason for finishing (e.g., "stop", "length", "tool_calls")
  @override
  final String? finishReason;

  /// Token usage information
  @override
  final TokenUsage? usage;

  /// Log probability information
  @override
  final LogProbs? logProbs;

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ResponseMetaCopyWith<_ResponseMeta> get copyWith =>
      __$ResponseMetaCopyWithImpl<_ResponseMeta>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$ResponseMetaToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ResponseMeta &&
            (identical(other.finishReason, finishReason) ||
                other.finishReason == finishReason) &&
            (identical(other.usage, usage) || other.usage == usage) &&
            (identical(other.logProbs, logProbs) ||
                other.logProbs == logProbs));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, finishReason, usage, logProbs);

  @override
  String toString() {
    return 'ResponseMeta(finishReason: $finishReason, usage: $usage, logProbs: $logProbs)';
  }
}

/// @nodoc
abstract mixin class _$ResponseMetaCopyWith<$Res>
    implements $ResponseMetaCopyWith<$Res> {
  factory _$ResponseMetaCopyWith(
          _ResponseMeta value, $Res Function(_ResponseMeta) _then) =
      __$ResponseMetaCopyWithImpl;
  @override
  @useResult
  $Res call({String? finishReason, TokenUsage? usage, LogProbs? logProbs});

  @override
  $TokenUsageCopyWith<$Res>? get usage;
  @override
  $LogProbsCopyWith<$Res>? get logProbs;
}

/// @nodoc
class __$ResponseMetaCopyWithImpl<$Res>
    implements _$ResponseMetaCopyWith<$Res> {
  __$ResponseMetaCopyWithImpl(this._self, this._then);

  final _ResponseMeta _self;
  final $Res Function(_ResponseMeta) _then;

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? finishReason = freezed,
    Object? usage = freezed,
    Object? logProbs = freezed,
  }) {
    return _then(_ResponseMeta(
      finishReason: freezed == finishReason
          ? _self.finishReason
          : finishReason // ignore: cast_nullable_to_non_nullable
              as String?,
      usage: freezed == usage
          ? _self.usage
          : usage // ignore: cast_nullable_to_non_nullable
              as TokenUsage?,
      logProbs: freezed == logProbs
          ? _self.logProbs
          : logProbs // ignore: cast_nullable_to_non_nullable
              as LogProbs?,
    ));
  }

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $TokenUsageCopyWith<$Res>? get usage {
    if (_self.usage == null) {
      return null;
    }

    return $TokenUsageCopyWith<$Res>(_self.usage!, (value) {
      return _then(_self.copyWith(usage: value));
    });
  }

  /// Create a copy of ResponseMeta
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $LogProbsCopyWith<$Res>? get logProbs {
    if (_self.logProbs == null) {
      return null;
    }

    return $LogProbsCopyWith<$Res>(_self.logProbs!, (value) {
      return _then(_self.copyWith(logProbs: value));
    });
  }
}

/// @nodoc
mixin _$Message {
  /// Role of the message sender
  RoleType get role;

  /// Text content of the message
  String get content;

  /// Multi-modal input content (user messages)
  List<MessageInputPart>? get userInputMultiContent;

  /// Multi-modal output content (assistant messages)
  List<MessageOutputPart>? get assistantGenMultiContent;

  /// Name of the sender
  String? get name;

  /// Tool calls (for assistant messages)
  List<ToolCall>? get toolCalls;

  /// Tool call ID (for tool messages)
  String? get toolCallId;

  /// Tool name (for tool messages)
  String? get toolName;

  /// Response metadata
  ResponseMeta? get responseMeta;

  /// Reasoning content (thinking process)
  String? get reasoningContent;

  /// Extra custom information
  Map<String, dynamic>? get extra;

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MessageCopyWith<Message> get copyWith =>
      _$MessageCopyWithImpl<Message>(this as Message, _$identity);

  /// Serializes this Message to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is Message &&
            (identical(other.role, role) || other.role == role) &&
            (identical(other.content, content) || other.content == content) &&
            const DeepCollectionEquality()
                .equals(other.userInputMultiContent, userInputMultiContent) &&
            const DeepCollectionEquality().equals(
                other.assistantGenMultiContent, assistantGenMultiContent) &&
            (identical(other.name, name) || other.name == name) &&
            const DeepCollectionEquality().equals(other.toolCalls, toolCalls) &&
            (identical(other.toolCallId, toolCallId) ||
                other.toolCallId == toolCallId) &&
            (identical(other.toolName, toolName) ||
                other.toolName == toolName) &&
            (identical(other.responseMeta, responseMeta) ||
                other.responseMeta == responseMeta) &&
            (identical(other.reasoningContent, reasoningContent) ||
                other.reasoningContent == reasoningContent) &&
            const DeepCollectionEquality().equals(other.extra, extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      role,
      content,
      const DeepCollectionEquality().hash(userInputMultiContent),
      const DeepCollectionEquality().hash(assistantGenMultiContent),
      name,
      const DeepCollectionEquality().hash(toolCalls),
      toolCallId,
      toolName,
      responseMeta,
      reasoningContent,
      const DeepCollectionEquality().hash(extra));

  @override
  String toString() {
    return 'Message(role: $role, content: $content, userInputMultiContent: $userInputMultiContent, assistantGenMultiContent: $assistantGenMultiContent, name: $name, toolCalls: $toolCalls, toolCallId: $toolCallId, toolName: $toolName, responseMeta: $responseMeta, reasoningContent: $reasoningContent, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class $MessageCopyWith<$Res> {
  factory $MessageCopyWith(Message value, $Res Function(Message) _then) =
      _$MessageCopyWithImpl;
  @useResult
  $Res call(
      {RoleType role,
      String content,
      List<MessageInputPart>? userInputMultiContent,
      List<MessageOutputPart>? assistantGenMultiContent,
      String? name,
      List<ToolCall>? toolCalls,
      String? toolCallId,
      String? toolName,
      ResponseMeta? responseMeta,
      String? reasoningContent,
      Map<String, dynamic>? extra});

  $ResponseMetaCopyWith<$Res>? get responseMeta;
}

/// @nodoc
class _$MessageCopyWithImpl<$Res> implements $MessageCopyWith<$Res> {
  _$MessageCopyWithImpl(this._self, this._then);

  final Message _self;
  final $Res Function(Message) _then;

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? role = null,
    Object? content = null,
    Object? userInputMultiContent = freezed,
    Object? assistantGenMultiContent = freezed,
    Object? name = freezed,
    Object? toolCalls = freezed,
    Object? toolCallId = freezed,
    Object? toolName = freezed,
    Object? responseMeta = freezed,
    Object? reasoningContent = freezed,
    Object? extra = freezed,
  }) {
    return _then(_self.copyWith(
      role: null == role
          ? _self.role
          : role // ignore: cast_nullable_to_non_nullable
              as RoleType,
      content: null == content
          ? _self.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      userInputMultiContent: freezed == userInputMultiContent
          ? _self.userInputMultiContent
          : userInputMultiContent // ignore: cast_nullable_to_non_nullable
              as List<MessageInputPart>?,
      assistantGenMultiContent: freezed == assistantGenMultiContent
          ? _self.assistantGenMultiContent
          : assistantGenMultiContent // ignore: cast_nullable_to_non_nullable
              as List<MessageOutputPart>?,
      name: freezed == name
          ? _self.name
          : name // ignore: cast_nullable_to_non_nullable
              as String?,
      toolCalls: freezed == toolCalls
          ? _self.toolCalls
          : toolCalls // ignore: cast_nullable_to_non_nullable
              as List<ToolCall>?,
      toolCallId: freezed == toolCallId
          ? _self.toolCallId
          : toolCallId // ignore: cast_nullable_to_non_nullable
              as String?,
      toolName: freezed == toolName
          ? _self.toolName
          : toolName // ignore: cast_nullable_to_non_nullable
              as String?,
      responseMeta: freezed == responseMeta
          ? _self.responseMeta
          : responseMeta // ignore: cast_nullable_to_non_nullable
              as ResponseMeta?,
      reasoningContent: freezed == reasoningContent
          ? _self.reasoningContent
          : reasoningContent // ignore: cast_nullable_to_non_nullable
              as String?,
      extra: freezed == extra
          ? _self.extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $ResponseMetaCopyWith<$Res>? get responseMeta {
    if (_self.responseMeta == null) {
      return null;
    }

    return $ResponseMetaCopyWith<$Res>(_self.responseMeta!, (value) {
      return _then(_self.copyWith(responseMeta: value));
    });
  }
}

/// Adds pattern-matching-related methods to [Message].
extension MessagePatterns on Message {
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

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_Message value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _Message() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_Message value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Message():
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_Message value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Message() when $default != null:
        return $default(_that);
      case _:
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

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
            RoleType role,
            String content,
            List<MessageInputPart>? userInputMultiContent,
            List<MessageOutputPart>? assistantGenMultiContent,
            String? name,
            List<ToolCall>? toolCalls,
            String? toolCallId,
            String? toolName,
            ResponseMeta? responseMeta,
            String? reasoningContent,
            Map<String, dynamic>? extra)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _Message() when $default != null:
        return $default(
            _that.role,
            _that.content,
            _that.userInputMultiContent,
            _that.assistantGenMultiContent,
            _that.name,
            _that.toolCalls,
            _that.toolCallId,
            _that.toolName,
            _that.responseMeta,
            _that.reasoningContent,
            _that.extra);
      case _:
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

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
            RoleType role,
            String content,
            List<MessageInputPart>? userInputMultiContent,
            List<MessageOutputPart>? assistantGenMultiContent,
            String? name,
            List<ToolCall>? toolCalls,
            String? toolCallId,
            String? toolName,
            ResponseMeta? responseMeta,
            String? reasoningContent,
            Map<String, dynamic>? extra)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Message():
        return $default(
            _that.role,
            _that.content,
            _that.userInputMultiContent,
            _that.assistantGenMultiContent,
            _that.name,
            _that.toolCalls,
            _that.toolCallId,
            _that.toolName,
            _that.responseMeta,
            _that.reasoningContent,
            _that.extra);
      case _:
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

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
            RoleType role,
            String content,
            List<MessageInputPart>? userInputMultiContent,
            List<MessageOutputPart>? assistantGenMultiContent,
            String? name,
            List<ToolCall>? toolCalls,
            String? toolCallId,
            String? toolName,
            ResponseMeta? responseMeta,
            String? reasoningContent,
            Map<String, dynamic>? extra)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Message() when $default != null:
        return $default(
            _that.role,
            _that.content,
            _that.userInputMultiContent,
            _that.assistantGenMultiContent,
            _that.name,
            _that.toolCalls,
            _that.toolCallId,
            _that.toolName,
            _that.responseMeta,
            _that.reasoningContent,
            _that.extra);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _Message extends Message {
  const _Message(
      {required this.role,
      this.content = '',
      final List<MessageInputPart>? userInputMultiContent,
      final List<MessageOutputPart>? assistantGenMultiContent,
      this.name,
      final List<ToolCall>? toolCalls,
      this.toolCallId,
      this.toolName,
      this.responseMeta,
      this.reasoningContent,
      final Map<String, dynamic>? extra})
      : _userInputMultiContent = userInputMultiContent,
        _assistantGenMultiContent = assistantGenMultiContent,
        _toolCalls = toolCalls,
        _extra = extra,
        super._();
  factory _Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);

  /// Role of the message sender
  @override
  final RoleType role;

  /// Text content of the message
  @override
  @JsonKey()
  final String content;

  /// Multi-modal input content (user messages)
  final List<MessageInputPart>? _userInputMultiContent;

  /// Multi-modal input content (user messages)
  @override
  List<MessageInputPart>? get userInputMultiContent {
    final value = _userInputMultiContent;
    if (value == null) return null;
    if (_userInputMultiContent is EqualUnmodifiableListView)
      return _userInputMultiContent;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Multi-modal output content (assistant messages)
  final List<MessageOutputPart>? _assistantGenMultiContent;

  /// Multi-modal output content (assistant messages)
  @override
  List<MessageOutputPart>? get assistantGenMultiContent {
    final value = _assistantGenMultiContent;
    if (value == null) return null;
    if (_assistantGenMultiContent is EqualUnmodifiableListView)
      return _assistantGenMultiContent;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Name of the sender
  @override
  final String? name;

  /// Tool calls (for assistant messages)
  final List<ToolCall>? _toolCalls;

  /// Tool calls (for assistant messages)
  @override
  List<ToolCall>? get toolCalls {
    final value = _toolCalls;
    if (value == null) return null;
    if (_toolCalls is EqualUnmodifiableListView) return _toolCalls;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Tool call ID (for tool messages)
  @override
  final String? toolCallId;

  /// Tool name (for tool messages)
  @override
  final String? toolName;

  /// Response metadata
  @override
  final ResponseMeta? responseMeta;

  /// Reasoning content (thinking process)
  @override
  final String? reasoningContent;

  /// Extra custom information
  final Map<String, dynamic>? _extra;

  /// Extra custom information
  @override
  Map<String, dynamic>? get extra {
    final value = _extra;
    if (value == null) return null;
    if (_extra is EqualUnmodifiableMapView) return _extra;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$MessageCopyWith<_Message> get copyWith =>
      __$MessageCopyWithImpl<_Message>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$MessageToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _Message &&
            (identical(other.role, role) || other.role == role) &&
            (identical(other.content, content) || other.content == content) &&
            const DeepCollectionEquality()
                .equals(other._userInputMultiContent, _userInputMultiContent) &&
            const DeepCollectionEquality().equals(
                other._assistantGenMultiContent, _assistantGenMultiContent) &&
            (identical(other.name, name) || other.name == name) &&
            const DeepCollectionEquality()
                .equals(other._toolCalls, _toolCalls) &&
            (identical(other.toolCallId, toolCallId) ||
                other.toolCallId == toolCallId) &&
            (identical(other.toolName, toolName) ||
                other.toolName == toolName) &&
            (identical(other.responseMeta, responseMeta) ||
                other.responseMeta == responseMeta) &&
            (identical(other.reasoningContent, reasoningContent) ||
                other.reasoningContent == reasoningContent) &&
            const DeepCollectionEquality().equals(other._extra, _extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      role,
      content,
      const DeepCollectionEquality().hash(_userInputMultiContent),
      const DeepCollectionEquality().hash(_assistantGenMultiContent),
      name,
      const DeepCollectionEquality().hash(_toolCalls),
      toolCallId,
      toolName,
      responseMeta,
      reasoningContent,
      const DeepCollectionEquality().hash(_extra));

  @override
  String toString() {
    return 'Message(role: $role, content: $content, userInputMultiContent: $userInputMultiContent, assistantGenMultiContent: $assistantGenMultiContent, name: $name, toolCalls: $toolCalls, toolCallId: $toolCallId, toolName: $toolName, responseMeta: $responseMeta, reasoningContent: $reasoningContent, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class _$MessageCopyWith<$Res> implements $MessageCopyWith<$Res> {
  factory _$MessageCopyWith(_Message value, $Res Function(_Message) _then) =
      __$MessageCopyWithImpl;
  @override
  @useResult
  $Res call(
      {RoleType role,
      String content,
      List<MessageInputPart>? userInputMultiContent,
      List<MessageOutputPart>? assistantGenMultiContent,
      String? name,
      List<ToolCall>? toolCalls,
      String? toolCallId,
      String? toolName,
      ResponseMeta? responseMeta,
      String? reasoningContent,
      Map<String, dynamic>? extra});

  @override
  $ResponseMetaCopyWith<$Res>? get responseMeta;
}

/// @nodoc
class __$MessageCopyWithImpl<$Res> implements _$MessageCopyWith<$Res> {
  __$MessageCopyWithImpl(this._self, this._then);

  final _Message _self;
  final $Res Function(_Message) _then;

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? role = null,
    Object? content = null,
    Object? userInputMultiContent = freezed,
    Object? assistantGenMultiContent = freezed,
    Object? name = freezed,
    Object? toolCalls = freezed,
    Object? toolCallId = freezed,
    Object? toolName = freezed,
    Object? responseMeta = freezed,
    Object? reasoningContent = freezed,
    Object? extra = freezed,
  }) {
    return _then(_Message(
      role: null == role
          ? _self.role
          : role // ignore: cast_nullable_to_non_nullable
              as RoleType,
      content: null == content
          ? _self.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      userInputMultiContent: freezed == userInputMultiContent
          ? _self._userInputMultiContent
          : userInputMultiContent // ignore: cast_nullable_to_non_nullable
              as List<MessageInputPart>?,
      assistantGenMultiContent: freezed == assistantGenMultiContent
          ? _self._assistantGenMultiContent
          : assistantGenMultiContent // ignore: cast_nullable_to_non_nullable
              as List<MessageOutputPart>?,
      name: freezed == name
          ? _self.name
          : name // ignore: cast_nullable_to_non_nullable
              as String?,
      toolCalls: freezed == toolCalls
          ? _self._toolCalls
          : toolCalls // ignore: cast_nullable_to_non_nullable
              as List<ToolCall>?,
      toolCallId: freezed == toolCallId
          ? _self.toolCallId
          : toolCallId // ignore: cast_nullable_to_non_nullable
              as String?,
      toolName: freezed == toolName
          ? _self.toolName
          : toolName // ignore: cast_nullable_to_non_nullable
              as String?,
      responseMeta: freezed == responseMeta
          ? _self.responseMeta
          : responseMeta // ignore: cast_nullable_to_non_nullable
              as ResponseMeta?,
      reasoningContent: freezed == reasoningContent
          ? _self.reasoningContent
          : reasoningContent // ignore: cast_nullable_to_non_nullable
              as String?,
      extra: freezed == extra
          ? _self._extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }

  /// Create a copy of Message
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $ResponseMetaCopyWith<$Res>? get responseMeta {
    if (_self.responseMeta == null) {
      return null;
    }

    return $ResponseMetaCopyWith<$Res>(_self.responseMeta!, (value) {
      return _then(_self.copyWith(responseMeta: value));
    });
  }
}

// dart format on
