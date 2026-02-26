// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'stream_item.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$StreamItem<T> {
  /// The chunk of data (null for error-only items)
  T? get chunk;

  /// Optional error associated with this chunk
  Object? get error;

  /// Optional stack trace for the error
  StackTrace? get stackTrace;

  /// Create a copy of StreamItem
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $StreamItemCopyWith<T, StreamItem<T>> get copyWith =>
      _$StreamItemCopyWithImpl<T, StreamItem<T>>(
          this as StreamItem<T>, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is StreamItem<T> &&
            const DeepCollectionEquality().equals(other.chunk, chunk) &&
            const DeepCollectionEquality().equals(other.error, error) &&
            (identical(other.stackTrace, stackTrace) ||
                other.stackTrace == stackTrace));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(chunk),
      const DeepCollectionEquality().hash(error),
      stackTrace);

  @override
  String toString() {
    return 'StreamItem<$T>(chunk: $chunk, error: $error, stackTrace: $stackTrace)';
  }
}

/// @nodoc
abstract mixin class $StreamItemCopyWith<T, $Res> {
  factory $StreamItemCopyWith(
          StreamItem<T> value, $Res Function(StreamItem<T>) _then) =
      _$StreamItemCopyWithImpl;
  @useResult
  $Res call({T? chunk, Object? error, StackTrace? stackTrace});
}

/// @nodoc
class _$StreamItemCopyWithImpl<T, $Res>
    implements $StreamItemCopyWith<T, $Res> {
  _$StreamItemCopyWithImpl(this._self, this._then);

  final StreamItem<T> _self;
  final $Res Function(StreamItem<T>) _then;

  /// Create a copy of StreamItem
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? chunk = freezed,
    Object? error = freezed,
    Object? stackTrace = freezed,
  }) {
    return _then(_self.copyWith(
      chunk: freezed == chunk
          ? _self.chunk
          : chunk // ignore: cast_nullable_to_non_nullable
              as T?,
      error: freezed == error ? _self.error : error,
      stackTrace: freezed == stackTrace
          ? _self.stackTrace
          : stackTrace // ignore: cast_nullable_to_non_nullable
              as StackTrace?,
    ));
  }
}

/// Adds pattern-matching-related methods to [StreamItem].
extension StreamItemPatterns<T> on StreamItem<T> {
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
    TResult Function(_StreamItem<T> value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _StreamItem() when $default != null:
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
    TResult Function(_StreamItem<T> value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _StreamItem():
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
    TResult? Function(_StreamItem<T> value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _StreamItem() when $default != null:
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
    TResult Function(T? chunk, Object? error, StackTrace? stackTrace)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _StreamItem() when $default != null:
        return $default(_that.chunk, _that.error, _that.stackTrace);
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
    TResult Function(T? chunk, Object? error, StackTrace? stackTrace) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _StreamItem():
        return $default(_that.chunk, _that.error, _that.stackTrace);
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
    TResult? Function(T? chunk, Object? error, StackTrace? stackTrace)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _StreamItem() when $default != null:
        return $default(_that.chunk, _that.error, _that.stackTrace);
      case _:
        return null;
    }
  }
}

/// @nodoc

class _StreamItem<T> extends StreamItem<T> {
  const _StreamItem({this.chunk, this.error, this.stackTrace}) : super._();

  /// The chunk of data (null for error-only items)
  @override
  final T? chunk;

  /// Optional error associated with this chunk
  @override
  final Object? error;

  /// Optional stack trace for the error
  @override
  final StackTrace? stackTrace;

  /// Create a copy of StreamItem
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$StreamItemCopyWith<T, _StreamItem<T>> get copyWith =>
      __$StreamItemCopyWithImpl<T, _StreamItem<T>>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _StreamItem<T> &&
            const DeepCollectionEquality().equals(other.chunk, chunk) &&
            const DeepCollectionEquality().equals(other.error, error) &&
            (identical(other.stackTrace, stackTrace) ||
                other.stackTrace == stackTrace));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(chunk),
      const DeepCollectionEquality().hash(error),
      stackTrace);

  @override
  String toString() {
    return 'StreamItem<$T>(chunk: $chunk, error: $error, stackTrace: $stackTrace)';
  }
}

/// @nodoc
abstract mixin class _$StreamItemCopyWith<T, $Res>
    implements $StreamItemCopyWith<T, $Res> {
  factory _$StreamItemCopyWith(
          _StreamItem<T> value, $Res Function(_StreamItem<T>) _then) =
      __$StreamItemCopyWithImpl;
  @override
  @useResult
  $Res call({T? chunk, Object? error, StackTrace? stackTrace});
}

/// @nodoc
class __$StreamItemCopyWithImpl<T, $Res>
    implements _$StreamItemCopyWith<T, $Res> {
  __$StreamItemCopyWithImpl(this._self, this._then);

  final _StreamItem<T> _self;
  final $Res Function(_StreamItem<T>) _then;

  /// Create a copy of StreamItem
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? chunk = freezed,
    Object? error = freezed,
    Object? stackTrace = freezed,
  }) {
    return _then(_StreamItem<T>(
      chunk: freezed == chunk
          ? _self.chunk
          : chunk // ignore: cast_nullable_to_non_nullable
              as T?,
      error: freezed == error ? _self.error : error,
      stackTrace: freezed == stackTrace
          ? _self.stackTrace
          : stackTrace // ignore: cast_nullable_to_non_nullable
              as StackTrace?,
    ));
  }
}

// dart format on
