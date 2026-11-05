// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'tool_result.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ToolOutputImage {

/// Where the image is: exactly one of URL, base64 data and file id
 MessagePartCommon get common;
/// Create a copy of ToolOutputImage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolOutputImageCopyWith<ToolOutputImage> get copyWith => _$ToolOutputImageCopyWithImpl<ToolOutputImage>(this as ToolOutputImage, _$identity);

  /// Serializes this ToolOutputImage to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolOutputImage&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputImage(common: $common)';
}


}

/// @nodoc
abstract mixin class $ToolOutputImageCopyWith<$Res>  {
  factory $ToolOutputImageCopyWith(ToolOutputImage value, $Res Function(ToolOutputImage) _then) = _$ToolOutputImageCopyWithImpl;
@useResult
$Res call({
 MessagePartCommon common
});


$MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class _$ToolOutputImageCopyWithImpl<$Res>
    implements $ToolOutputImageCopyWith<$Res> {
  _$ToolOutputImageCopyWithImpl(this._self, this._then);

  final ToolOutputImage _self;
  final $Res Function(ToolOutputImage) _then;

/// Create a copy of ToolOutputImage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? common = null,}) {
  return _then(_self.copyWith(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}
/// Create a copy of ToolOutputImage
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MessagePartCommonCopyWith<$Res> get common {
  
  return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
    return _then(_self.copyWith(common: value));
  });
}
}


/// Adds pattern-matching-related methods to [ToolOutputImage].
extension ToolOutputImagePatterns on ToolOutputImage {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolOutputImage value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolOutputImage() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolOutputImage value)  $default,){
final _that = this;
switch (_that) {
case _ToolOutputImage():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolOutputImage value)?  $default,){
final _that = this;
switch (_that) {
case _ToolOutputImage() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( MessagePartCommon common)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolOutputImage() when $default != null:
return $default(_that.common);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( MessagePartCommon common)  $default,) {final _that = this;
switch (_that) {
case _ToolOutputImage():
return $default(_that.common);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( MessagePartCommon common)?  $default,) {final _that = this;
switch (_that) {
case _ToolOutputImage() when $default != null:
return $default(_that.common);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolOutputImage implements ToolOutputImage {
  const _ToolOutputImage({required this.common});
  factory _ToolOutputImage.fromJson(Map<String, dynamic> json) => _$ToolOutputImageFromJson(json);

/// Where the image is: exactly one of URL, base64 data and file id
@override final  MessagePartCommon common;

/// Create a copy of ToolOutputImage
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolOutputImageCopyWith<_ToolOutputImage> get copyWith => __$ToolOutputImageCopyWithImpl<_ToolOutputImage>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolOutputImageToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolOutputImage&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputImage(common: $common)';
}


}

/// @nodoc
abstract mixin class _$ToolOutputImageCopyWith<$Res> implements $ToolOutputImageCopyWith<$Res> {
  factory _$ToolOutputImageCopyWith(_ToolOutputImage value, $Res Function(_ToolOutputImage) _then) = __$ToolOutputImageCopyWithImpl;
@override @useResult
$Res call({
 MessagePartCommon common
});


@override $MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class __$ToolOutputImageCopyWithImpl<$Res>
    implements _$ToolOutputImageCopyWith<$Res> {
  __$ToolOutputImageCopyWithImpl(this._self, this._then);

  final _ToolOutputImage _self;
  final $Res Function(_ToolOutputImage) _then;

/// Create a copy of ToolOutputImage
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? common = null,}) {
  return _then(_ToolOutputImage(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}

/// Create a copy of ToolOutputImage
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
mixin _$ToolOutputAudio {

/// Where the audio is: exactly one of URL, base64 data and file id
 MessagePartCommon get common;
/// Create a copy of ToolOutputAudio
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolOutputAudioCopyWith<ToolOutputAudio> get copyWith => _$ToolOutputAudioCopyWithImpl<ToolOutputAudio>(this as ToolOutputAudio, _$identity);

  /// Serializes this ToolOutputAudio to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolOutputAudio&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputAudio(common: $common)';
}


}

/// @nodoc
abstract mixin class $ToolOutputAudioCopyWith<$Res>  {
  factory $ToolOutputAudioCopyWith(ToolOutputAudio value, $Res Function(ToolOutputAudio) _then) = _$ToolOutputAudioCopyWithImpl;
@useResult
$Res call({
 MessagePartCommon common
});


$MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class _$ToolOutputAudioCopyWithImpl<$Res>
    implements $ToolOutputAudioCopyWith<$Res> {
  _$ToolOutputAudioCopyWithImpl(this._self, this._then);

  final ToolOutputAudio _self;
  final $Res Function(ToolOutputAudio) _then;

/// Create a copy of ToolOutputAudio
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? common = null,}) {
  return _then(_self.copyWith(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}
/// Create a copy of ToolOutputAudio
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MessagePartCommonCopyWith<$Res> get common {
  
  return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
    return _then(_self.copyWith(common: value));
  });
}
}


/// Adds pattern-matching-related methods to [ToolOutputAudio].
extension ToolOutputAudioPatterns on ToolOutputAudio {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolOutputAudio value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolOutputAudio() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolOutputAudio value)  $default,){
final _that = this;
switch (_that) {
case _ToolOutputAudio():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolOutputAudio value)?  $default,){
final _that = this;
switch (_that) {
case _ToolOutputAudio() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( MessagePartCommon common)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolOutputAudio() when $default != null:
return $default(_that.common);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( MessagePartCommon common)  $default,) {final _that = this;
switch (_that) {
case _ToolOutputAudio():
return $default(_that.common);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( MessagePartCommon common)?  $default,) {final _that = this;
switch (_that) {
case _ToolOutputAudio() when $default != null:
return $default(_that.common);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolOutputAudio implements ToolOutputAudio {
  const _ToolOutputAudio({required this.common});
  factory _ToolOutputAudio.fromJson(Map<String, dynamic> json) => _$ToolOutputAudioFromJson(json);

/// Where the audio is: exactly one of URL, base64 data and file id
@override final  MessagePartCommon common;

/// Create a copy of ToolOutputAudio
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolOutputAudioCopyWith<_ToolOutputAudio> get copyWith => __$ToolOutputAudioCopyWithImpl<_ToolOutputAudio>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolOutputAudioToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolOutputAudio&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputAudio(common: $common)';
}


}

/// @nodoc
abstract mixin class _$ToolOutputAudioCopyWith<$Res> implements $ToolOutputAudioCopyWith<$Res> {
  factory _$ToolOutputAudioCopyWith(_ToolOutputAudio value, $Res Function(_ToolOutputAudio) _then) = __$ToolOutputAudioCopyWithImpl;
@override @useResult
$Res call({
 MessagePartCommon common
});


@override $MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class __$ToolOutputAudioCopyWithImpl<$Res>
    implements _$ToolOutputAudioCopyWith<$Res> {
  __$ToolOutputAudioCopyWithImpl(this._self, this._then);

  final _ToolOutputAudio _self;
  final $Res Function(_ToolOutputAudio) _then;

/// Create a copy of ToolOutputAudio
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? common = null,}) {
  return _then(_ToolOutputAudio(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}

/// Create a copy of ToolOutputAudio
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
mixin _$ToolOutputVideo {

/// Where the video is: exactly one of URL, base64 data and file id
 MessagePartCommon get common;
/// Create a copy of ToolOutputVideo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolOutputVideoCopyWith<ToolOutputVideo> get copyWith => _$ToolOutputVideoCopyWithImpl<ToolOutputVideo>(this as ToolOutputVideo, _$identity);

  /// Serializes this ToolOutputVideo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolOutputVideo&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputVideo(common: $common)';
}


}

/// @nodoc
abstract mixin class $ToolOutputVideoCopyWith<$Res>  {
  factory $ToolOutputVideoCopyWith(ToolOutputVideo value, $Res Function(ToolOutputVideo) _then) = _$ToolOutputVideoCopyWithImpl;
@useResult
$Res call({
 MessagePartCommon common
});


$MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class _$ToolOutputVideoCopyWithImpl<$Res>
    implements $ToolOutputVideoCopyWith<$Res> {
  _$ToolOutputVideoCopyWithImpl(this._self, this._then);

  final ToolOutputVideo _self;
  final $Res Function(ToolOutputVideo) _then;

/// Create a copy of ToolOutputVideo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? common = null,}) {
  return _then(_self.copyWith(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}
/// Create a copy of ToolOutputVideo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MessagePartCommonCopyWith<$Res> get common {
  
  return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
    return _then(_self.copyWith(common: value));
  });
}
}


/// Adds pattern-matching-related methods to [ToolOutputVideo].
extension ToolOutputVideoPatterns on ToolOutputVideo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolOutputVideo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolOutputVideo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolOutputVideo value)  $default,){
final _that = this;
switch (_that) {
case _ToolOutputVideo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolOutputVideo value)?  $default,){
final _that = this;
switch (_that) {
case _ToolOutputVideo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( MessagePartCommon common)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolOutputVideo() when $default != null:
return $default(_that.common);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( MessagePartCommon common)  $default,) {final _that = this;
switch (_that) {
case _ToolOutputVideo():
return $default(_that.common);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( MessagePartCommon common)?  $default,) {final _that = this;
switch (_that) {
case _ToolOutputVideo() when $default != null:
return $default(_that.common);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolOutputVideo implements ToolOutputVideo {
  const _ToolOutputVideo({required this.common});
  factory _ToolOutputVideo.fromJson(Map<String, dynamic> json) => _$ToolOutputVideoFromJson(json);

/// Where the video is: exactly one of URL, base64 data and file id
@override final  MessagePartCommon common;

/// Create a copy of ToolOutputVideo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolOutputVideoCopyWith<_ToolOutputVideo> get copyWith => __$ToolOutputVideoCopyWithImpl<_ToolOutputVideo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolOutputVideoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolOutputVideo&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputVideo(common: $common)';
}


}

/// @nodoc
abstract mixin class _$ToolOutputVideoCopyWith<$Res> implements $ToolOutputVideoCopyWith<$Res> {
  factory _$ToolOutputVideoCopyWith(_ToolOutputVideo value, $Res Function(_ToolOutputVideo) _then) = __$ToolOutputVideoCopyWithImpl;
@override @useResult
$Res call({
 MessagePartCommon common
});


@override $MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class __$ToolOutputVideoCopyWithImpl<$Res>
    implements _$ToolOutputVideoCopyWith<$Res> {
  __$ToolOutputVideoCopyWithImpl(this._self, this._then);

  final _ToolOutputVideo _self;
  final $Res Function(_ToolOutputVideo) _then;

/// Create a copy of ToolOutputVideo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? common = null,}) {
  return _then(_ToolOutputVideo(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}

/// Create a copy of ToolOutputVideo
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
mixin _$ToolOutputFile {

/// Where the file is: exactly one of URL, base64 data and file id
 MessagePartCommon get common;
/// Create a copy of ToolOutputFile
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolOutputFileCopyWith<ToolOutputFile> get copyWith => _$ToolOutputFileCopyWithImpl<ToolOutputFile>(this as ToolOutputFile, _$identity);

  /// Serializes this ToolOutputFile to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolOutputFile&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputFile(common: $common)';
}


}

/// @nodoc
abstract mixin class $ToolOutputFileCopyWith<$Res>  {
  factory $ToolOutputFileCopyWith(ToolOutputFile value, $Res Function(ToolOutputFile) _then) = _$ToolOutputFileCopyWithImpl;
@useResult
$Res call({
 MessagePartCommon common
});


$MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class _$ToolOutputFileCopyWithImpl<$Res>
    implements $ToolOutputFileCopyWith<$Res> {
  _$ToolOutputFileCopyWithImpl(this._self, this._then);

  final ToolOutputFile _self;
  final $Res Function(ToolOutputFile) _then;

/// Create a copy of ToolOutputFile
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? common = null,}) {
  return _then(_self.copyWith(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}
/// Create a copy of ToolOutputFile
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MessagePartCommonCopyWith<$Res> get common {
  
  return $MessagePartCommonCopyWith<$Res>(_self.common, (value) {
    return _then(_self.copyWith(common: value));
  });
}
}


/// Adds pattern-matching-related methods to [ToolOutputFile].
extension ToolOutputFilePatterns on ToolOutputFile {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolOutputFile value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolOutputFile() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolOutputFile value)  $default,){
final _that = this;
switch (_that) {
case _ToolOutputFile():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolOutputFile value)?  $default,){
final _that = this;
switch (_that) {
case _ToolOutputFile() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( MessagePartCommon common)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolOutputFile() when $default != null:
return $default(_that.common);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( MessagePartCommon common)  $default,) {final _that = this;
switch (_that) {
case _ToolOutputFile():
return $default(_that.common);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( MessagePartCommon common)?  $default,) {final _that = this;
switch (_that) {
case _ToolOutputFile() when $default != null:
return $default(_that.common);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolOutputFile implements ToolOutputFile {
  const _ToolOutputFile({required this.common});
  factory _ToolOutputFile.fromJson(Map<String, dynamic> json) => _$ToolOutputFileFromJson(json);

/// Where the file is: exactly one of URL, base64 data and file id
@override final  MessagePartCommon common;

/// Create a copy of ToolOutputFile
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolOutputFileCopyWith<_ToolOutputFile> get copyWith => __$ToolOutputFileCopyWithImpl<_ToolOutputFile>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolOutputFileToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolOutputFile&&(identical(other.common, common) || other.common == common));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,common);

@override
String toString() {
  return 'ToolOutputFile(common: $common)';
}


}

/// @nodoc
abstract mixin class _$ToolOutputFileCopyWith<$Res> implements $ToolOutputFileCopyWith<$Res> {
  factory _$ToolOutputFileCopyWith(_ToolOutputFile value, $Res Function(_ToolOutputFile) _then) = __$ToolOutputFileCopyWithImpl;
@override @useResult
$Res call({
 MessagePartCommon common
});


@override $MessagePartCommonCopyWith<$Res> get common;

}
/// @nodoc
class __$ToolOutputFileCopyWithImpl<$Res>
    implements _$ToolOutputFileCopyWith<$Res> {
  __$ToolOutputFileCopyWithImpl(this._self, this._then);

  final _ToolOutputFile _self;
  final $Res Function(_ToolOutputFile) _then;

/// Create a copy of ToolOutputFile
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? common = null,}) {
  return _then(_ToolOutputFile(
common: null == common ? _self.common : common // ignore: cast_nullable_to_non_nullable
as MessagePartCommon,
  ));
}

/// Create a copy of ToolOutputFile
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
mixin _$ToolOutputPart {

/// Kind of content
 ToolPartType get type;/// Text (when type is text)
 String? get text;/// Image (when type is image)
 ToolOutputImage? get image;/// Audio (when type is audio)
 ToolOutputAudio? get audio;/// Video (when type is video)
 ToolOutputVideo? get video;/// File (when type is file)
 ToolOutputFile? get file;/// Tools that were found (when type is toolSearchResult)
 ToolSearchResult? get toolSearchResult;/// Extra information
 Map<String, dynamic>? get extra;
/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolOutputPartCopyWith<ToolOutputPart> get copyWith => _$ToolOutputPartCopyWithImpl<ToolOutputPart>(this as ToolOutputPart, _$identity);

  /// Serializes this ToolOutputPart to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolOutputPart&&(identical(other.type, type) || other.type == type)&&(identical(other.text, text) || other.text == text)&&(identical(other.image, image) || other.image == image)&&(identical(other.audio, audio) || other.audio == audio)&&(identical(other.video, video) || other.video == video)&&(identical(other.file, file) || other.file == file)&&(identical(other.toolSearchResult, toolSearchResult) || other.toolSearchResult == toolSearchResult)&&const DeepCollectionEquality().equals(other.extra, extra));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,text,image,audio,video,file,toolSearchResult,const DeepCollectionEquality().hash(extra));

@override
String toString() {
  return 'ToolOutputPart(type: $type, text: $text, image: $image, audio: $audio, video: $video, file: $file, toolSearchResult: $toolSearchResult, extra: $extra)';
}


}

/// @nodoc
abstract mixin class $ToolOutputPartCopyWith<$Res>  {
  factory $ToolOutputPartCopyWith(ToolOutputPart value, $Res Function(ToolOutputPart) _then) = _$ToolOutputPartCopyWithImpl;
@useResult
$Res call({
 ToolPartType type, String? text, ToolOutputImage? image, ToolOutputAudio? audio, ToolOutputVideo? video, ToolOutputFile? file, ToolSearchResult? toolSearchResult, Map<String, dynamic>? extra
});


$ToolOutputImageCopyWith<$Res>? get image;$ToolOutputAudioCopyWith<$Res>? get audio;$ToolOutputVideoCopyWith<$Res>? get video;$ToolOutputFileCopyWith<$Res>? get file;$ToolSearchResultCopyWith<$Res>? get toolSearchResult;

}
/// @nodoc
class _$ToolOutputPartCopyWithImpl<$Res>
    implements $ToolOutputPartCopyWith<$Res> {
  _$ToolOutputPartCopyWithImpl(this._self, this._then);

  final ToolOutputPart _self;
  final $Res Function(ToolOutputPart) _then;

/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? type = null,Object? text = freezed,Object? image = freezed,Object? audio = freezed,Object? video = freezed,Object? file = freezed,Object? toolSearchResult = freezed,Object? extra = freezed,}) {
  return _then(_self.copyWith(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as ToolPartType,text: freezed == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String?,image: freezed == image ? _self.image : image // ignore: cast_nullable_to_non_nullable
as ToolOutputImage?,audio: freezed == audio ? _self.audio : audio // ignore: cast_nullable_to_non_nullable
as ToolOutputAudio?,video: freezed == video ? _self.video : video // ignore: cast_nullable_to_non_nullable
as ToolOutputVideo?,file: freezed == file ? _self.file : file // ignore: cast_nullable_to_non_nullable
as ToolOutputFile?,toolSearchResult: freezed == toolSearchResult ? _self.toolSearchResult : toolSearchResult // ignore: cast_nullable_to_non_nullable
as ToolSearchResult?,extra: freezed == extra ? _self.extra : extra // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}
/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputImageCopyWith<$Res>? get image {
    if (_self.image == null) {
    return null;
  }

  return $ToolOutputImageCopyWith<$Res>(_self.image!, (value) {
    return _then(_self.copyWith(image: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputAudioCopyWith<$Res>? get audio {
    if (_self.audio == null) {
    return null;
  }

  return $ToolOutputAudioCopyWith<$Res>(_self.audio!, (value) {
    return _then(_self.copyWith(audio: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputVideoCopyWith<$Res>? get video {
    if (_self.video == null) {
    return null;
  }

  return $ToolOutputVideoCopyWith<$Res>(_self.video!, (value) {
    return _then(_self.copyWith(video: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputFileCopyWith<$Res>? get file {
    if (_self.file == null) {
    return null;
  }

  return $ToolOutputFileCopyWith<$Res>(_self.file!, (value) {
    return _then(_self.copyWith(file: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolSearchResultCopyWith<$Res>? get toolSearchResult {
    if (_self.toolSearchResult == null) {
    return null;
  }

  return $ToolSearchResultCopyWith<$Res>(_self.toolSearchResult!, (value) {
    return _then(_self.copyWith(toolSearchResult: value));
  });
}
}


/// Adds pattern-matching-related methods to [ToolOutputPart].
extension ToolOutputPartPatterns on ToolOutputPart {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolOutputPart value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolOutputPart() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolOutputPart value)  $default,){
final _that = this;
switch (_that) {
case _ToolOutputPart():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolOutputPart value)?  $default,){
final _that = this;
switch (_that) {
case _ToolOutputPart() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ToolPartType type,  String? text,  ToolOutputImage? image,  ToolOutputAudio? audio,  ToolOutputVideo? video,  ToolOutputFile? file,  ToolSearchResult? toolSearchResult,  Map<String, dynamic>? extra)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolOutputPart() when $default != null:
return $default(_that.type,_that.text,_that.image,_that.audio,_that.video,_that.file,_that.toolSearchResult,_that.extra);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ToolPartType type,  String? text,  ToolOutputImage? image,  ToolOutputAudio? audio,  ToolOutputVideo? video,  ToolOutputFile? file,  ToolSearchResult? toolSearchResult,  Map<String, dynamic>? extra)  $default,) {final _that = this;
switch (_that) {
case _ToolOutputPart():
return $default(_that.type,_that.text,_that.image,_that.audio,_that.video,_that.file,_that.toolSearchResult,_that.extra);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ToolPartType type,  String? text,  ToolOutputImage? image,  ToolOutputAudio? audio,  ToolOutputVideo? video,  ToolOutputFile? file,  ToolSearchResult? toolSearchResult,  Map<String, dynamic>? extra)?  $default,) {final _that = this;
switch (_that) {
case _ToolOutputPart() when $default != null:
return $default(_that.type,_that.text,_that.image,_that.audio,_that.video,_that.file,_that.toolSearchResult,_that.extra);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolOutputPart implements ToolOutputPart {
  const _ToolOutputPart({required this.type, this.text, this.image, this.audio, this.video, this.file, this.toolSearchResult, final  Map<String, dynamic>? extra}): _extra = extra;
  factory _ToolOutputPart.fromJson(Map<String, dynamic> json) => _$ToolOutputPartFromJson(json);

/// Kind of content
@override final  ToolPartType type;
/// Text (when type is text)
@override final  String? text;
/// Image (when type is image)
@override final  ToolOutputImage? image;
/// Audio (when type is audio)
@override final  ToolOutputAudio? audio;
/// Video (when type is video)
@override final  ToolOutputVideo? video;
/// File (when type is file)
@override final  ToolOutputFile? file;
/// Tools that were found (when type is toolSearchResult)
@override final  ToolSearchResult? toolSearchResult;
/// Extra information
 final  Map<String, dynamic>? _extra;
/// Extra information
@override Map<String, dynamic>? get extra {
  final value = _extra;
  if (value == null) return null;
  if (_extra is EqualUnmodifiableMapView) return _extra;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(value);
}


/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolOutputPartCopyWith<_ToolOutputPart> get copyWith => __$ToolOutputPartCopyWithImpl<_ToolOutputPart>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolOutputPartToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolOutputPart&&(identical(other.type, type) || other.type == type)&&(identical(other.text, text) || other.text == text)&&(identical(other.image, image) || other.image == image)&&(identical(other.audio, audio) || other.audio == audio)&&(identical(other.video, video) || other.video == video)&&(identical(other.file, file) || other.file == file)&&(identical(other.toolSearchResult, toolSearchResult) || other.toolSearchResult == toolSearchResult)&&const DeepCollectionEquality().equals(other._extra, _extra));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,text,image,audio,video,file,toolSearchResult,const DeepCollectionEquality().hash(_extra));

@override
String toString() {
  return 'ToolOutputPart(type: $type, text: $text, image: $image, audio: $audio, video: $video, file: $file, toolSearchResult: $toolSearchResult, extra: $extra)';
}


}

/// @nodoc
abstract mixin class _$ToolOutputPartCopyWith<$Res> implements $ToolOutputPartCopyWith<$Res> {
  factory _$ToolOutputPartCopyWith(_ToolOutputPart value, $Res Function(_ToolOutputPart) _then) = __$ToolOutputPartCopyWithImpl;
@override @useResult
$Res call({
 ToolPartType type, String? text, ToolOutputImage? image, ToolOutputAudio? audio, ToolOutputVideo? video, ToolOutputFile? file, ToolSearchResult? toolSearchResult, Map<String, dynamic>? extra
});


@override $ToolOutputImageCopyWith<$Res>? get image;@override $ToolOutputAudioCopyWith<$Res>? get audio;@override $ToolOutputVideoCopyWith<$Res>? get video;@override $ToolOutputFileCopyWith<$Res>? get file;@override $ToolSearchResultCopyWith<$Res>? get toolSearchResult;

}
/// @nodoc
class __$ToolOutputPartCopyWithImpl<$Res>
    implements _$ToolOutputPartCopyWith<$Res> {
  __$ToolOutputPartCopyWithImpl(this._self, this._then);

  final _ToolOutputPart _self;
  final $Res Function(_ToolOutputPart) _then;

/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? text = freezed,Object? image = freezed,Object? audio = freezed,Object? video = freezed,Object? file = freezed,Object? toolSearchResult = freezed,Object? extra = freezed,}) {
  return _then(_ToolOutputPart(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as ToolPartType,text: freezed == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String?,image: freezed == image ? _self.image : image // ignore: cast_nullable_to_non_nullable
as ToolOutputImage?,audio: freezed == audio ? _self.audio : audio // ignore: cast_nullable_to_non_nullable
as ToolOutputAudio?,video: freezed == video ? _self.video : video // ignore: cast_nullable_to_non_nullable
as ToolOutputVideo?,file: freezed == file ? _self.file : file // ignore: cast_nullable_to_non_nullable
as ToolOutputFile?,toolSearchResult: freezed == toolSearchResult ? _self.toolSearchResult : toolSearchResult // ignore: cast_nullable_to_non_nullable
as ToolSearchResult?,extra: freezed == extra ? _self._extra : extra // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>?,
  ));
}

/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputImageCopyWith<$Res>? get image {
    if (_self.image == null) {
    return null;
  }

  return $ToolOutputImageCopyWith<$Res>(_self.image!, (value) {
    return _then(_self.copyWith(image: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputAudioCopyWith<$Res>? get audio {
    if (_self.audio == null) {
    return null;
  }

  return $ToolOutputAudioCopyWith<$Res>(_self.audio!, (value) {
    return _then(_self.copyWith(audio: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputVideoCopyWith<$Res>? get video {
    if (_self.video == null) {
    return null;
  }

  return $ToolOutputVideoCopyWith<$Res>(_self.video!, (value) {
    return _then(_self.copyWith(video: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolOutputFileCopyWith<$Res>? get file {
    if (_self.file == null) {
    return null;
  }

  return $ToolOutputFileCopyWith<$Res>(_self.file!, (value) {
    return _then(_self.copyWith(file: value));
  });
}/// Create a copy of ToolOutputPart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolSearchResultCopyWith<$Res>? get toolSearchResult {
    if (_self.toolSearchResult == null) {
    return null;
  }

  return $ToolSearchResultCopyWith<$Res>(_self.toolSearchResult!, (value) {
    return _then(_self.copyWith(toolSearchResult: value));
  });
}
}


/// @nodoc
mixin _$ToolArgument {

/// The arguments of the call, as JSON text
 String get text;
/// Create a copy of ToolArgument
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolArgumentCopyWith<ToolArgument> get copyWith => _$ToolArgumentCopyWithImpl<ToolArgument>(this as ToolArgument, _$identity);

  /// Serializes this ToolArgument to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolArgument&&(identical(other.text, text) || other.text == text));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'ToolArgument(text: $text)';
}


}

/// @nodoc
abstract mixin class $ToolArgumentCopyWith<$Res>  {
  factory $ToolArgumentCopyWith(ToolArgument value, $Res Function(ToolArgument) _then) = _$ToolArgumentCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$ToolArgumentCopyWithImpl<$Res>
    implements $ToolArgumentCopyWith<$Res> {
  _$ToolArgumentCopyWithImpl(this._self, this._then);

  final ToolArgument _self;
  final $Res Function(ToolArgument) _then;

/// Create a copy of ToolArgument
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? text = null,}) {
  return _then(_self.copyWith(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [ToolArgument].
extension ToolArgumentPatterns on ToolArgument {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolArgument value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolArgument() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolArgument value)  $default,){
final _that = this;
switch (_that) {
case _ToolArgument():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolArgument value)?  $default,){
final _that = this;
switch (_that) {
case _ToolArgument() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String text)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolArgument() when $default != null:
return $default(_that.text);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String text)  $default,) {final _that = this;
switch (_that) {
case _ToolArgument():
return $default(_that.text);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String text)?  $default,) {final _that = this;
switch (_that) {
case _ToolArgument() when $default != null:
return $default(_that.text);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolArgument implements ToolArgument {
  const _ToolArgument(this.text);
  factory _ToolArgument.fromJson(Map<String, dynamic> json) => _$ToolArgumentFromJson(json);

/// The arguments of the call, as JSON text
@override final  String text;

/// Create a copy of ToolArgument
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolArgumentCopyWith<_ToolArgument> get copyWith => __$ToolArgumentCopyWithImpl<_ToolArgument>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolArgumentToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolArgument&&(identical(other.text, text) || other.text == text));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'ToolArgument(text: $text)';
}


}

/// @nodoc
abstract mixin class _$ToolArgumentCopyWith<$Res> implements $ToolArgumentCopyWith<$Res> {
  factory _$ToolArgumentCopyWith(_ToolArgument value, $Res Function(_ToolArgument) _then) = __$ToolArgumentCopyWithImpl;
@override @useResult
$Res call({
 String text
});




}
/// @nodoc
class __$ToolArgumentCopyWithImpl<$Res>
    implements _$ToolArgumentCopyWith<$Res> {
  __$ToolArgumentCopyWithImpl(this._self, this._then);

  final _ToolArgument _self;
  final $Res Function(_ToolArgument) _then;

/// Create a copy of ToolArgument
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(_ToolArgument(
null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$ToolResult {

/// The parts of the output, in order
 List<ToolOutputPart> get parts;
/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolResultCopyWith<ToolResult> get copyWith => _$ToolResultCopyWithImpl<ToolResult>(this as ToolResult, _$identity);

  /// Serializes this ToolResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolResult&&const DeepCollectionEquality().equals(other.parts, parts));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(parts));

@override
String toString() {
  return 'ToolResult(parts: $parts)';
}


}

/// @nodoc
abstract mixin class $ToolResultCopyWith<$Res>  {
  factory $ToolResultCopyWith(ToolResult value, $Res Function(ToolResult) _then) = _$ToolResultCopyWithImpl;
@useResult
$Res call({
 List<ToolOutputPart> parts
});




}
/// @nodoc
class _$ToolResultCopyWithImpl<$Res>
    implements $ToolResultCopyWith<$Res> {
  _$ToolResultCopyWithImpl(this._self, this._then);

  final ToolResult _self;
  final $Res Function(ToolResult) _then;

/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? parts = null,}) {
  return _then(_self.copyWith(
parts: null == parts ? _self.parts : parts // ignore: cast_nullable_to_non_nullable
as List<ToolOutputPart>,
  ));
}

}


/// Adds pattern-matching-related methods to [ToolResult].
extension ToolResultPatterns on ToolResult {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolResult value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolResult value)  $default,){
final _that = this;
switch (_that) {
case _ToolResult():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolResult value)?  $default,){
final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<ToolOutputPart> parts)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
return $default(_that.parts);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<ToolOutputPart> parts)  $default,) {final _that = this;
switch (_that) {
case _ToolResult():
return $default(_that.parts);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<ToolOutputPart> parts)?  $default,) {final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
return $default(_that.parts);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolResult extends ToolResult {
  const _ToolResult([final  List<ToolOutputPart> parts = const <ToolOutputPart>[]]): _parts = parts,super._();
  factory _ToolResult.fromJson(Map<String, dynamic> json) => _$ToolResultFromJson(json);

/// The parts of the output, in order
 final  List<ToolOutputPart> _parts;
/// The parts of the output, in order
@override@JsonKey() List<ToolOutputPart> get parts {
  if (_parts is EqualUnmodifiableListView) return _parts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_parts);
}


/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolResultCopyWith<_ToolResult> get copyWith => __$ToolResultCopyWithImpl<_ToolResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolResult&&const DeepCollectionEquality().equals(other._parts, _parts));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_parts));

@override
String toString() {
  return 'ToolResult(parts: $parts)';
}


}

/// @nodoc
abstract mixin class _$ToolResultCopyWith<$Res> implements $ToolResultCopyWith<$Res> {
  factory _$ToolResultCopyWith(_ToolResult value, $Res Function(_ToolResult) _then) = __$ToolResultCopyWithImpl;
@override @useResult
$Res call({
 List<ToolOutputPart> parts
});




}
/// @nodoc
class __$ToolResultCopyWithImpl<$Res>
    implements _$ToolResultCopyWith<$Res> {
  __$ToolResultCopyWithImpl(this._self, this._then);

  final _ToolResult _self;
  final $Res Function(_ToolResult) _then;

/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? parts = null,}) {
  return _then(_ToolResult(
null == parts ? _self._parts : parts // ignore: cast_nullable_to_non_nullable
as List<ToolOutputPart>,
  ));
}


}

// dart format on
