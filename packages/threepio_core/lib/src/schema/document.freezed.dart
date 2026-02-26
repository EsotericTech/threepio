// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'document.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$DocumentSource {
  /// URI of the document source
  String get uri;

  /// Additional metadata
  Map<String, dynamic>? get metadata;

  /// Create a copy of DocumentSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $DocumentSourceCopyWith<DocumentSource> get copyWith =>
      _$DocumentSourceCopyWithImpl<DocumentSource>(
          this as DocumentSource, _$identity);

  /// Serializes this DocumentSource to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is DocumentSource &&
            (identical(other.uri, uri) || other.uri == uri) &&
            const DeepCollectionEquality().equals(other.metadata, metadata));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, uri, const DeepCollectionEquality().hash(metadata));

  @override
  String toString() {
    return 'DocumentSource(uri: $uri, metadata: $metadata)';
  }
}

/// @nodoc
abstract mixin class $DocumentSourceCopyWith<$Res> {
  factory $DocumentSourceCopyWith(
          DocumentSource value, $Res Function(DocumentSource) _then) =
      _$DocumentSourceCopyWithImpl;
  @useResult
  $Res call({String uri, Map<String, dynamic>? metadata});
}

/// @nodoc
class _$DocumentSourceCopyWithImpl<$Res>
    implements $DocumentSourceCopyWith<$Res> {
  _$DocumentSourceCopyWithImpl(this._self, this._then);

  final DocumentSource _self;
  final $Res Function(DocumentSource) _then;

  /// Create a copy of DocumentSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? uri = null,
    Object? metadata = freezed,
  }) {
    return _then(_self.copyWith(
      uri: null == uri
          ? _self.uri
          : uri // ignore: cast_nullable_to_non_nullable
              as String,
      metadata: freezed == metadata
          ? _self.metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// Adds pattern-matching-related methods to [DocumentSource].
extension DocumentSourcePatterns on DocumentSource {
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
    TResult Function(_DocumentSource value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _DocumentSource() when $default != null:
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
    TResult Function(_DocumentSource value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentSource():
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
    TResult? Function(_DocumentSource value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentSource() when $default != null:
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
    TResult Function(String uri, Map<String, dynamic>? metadata)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _DocumentSource() when $default != null:
        return $default(_that.uri, _that.metadata);
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
    TResult Function(String uri, Map<String, dynamic>? metadata) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentSource():
        return $default(_that.uri, _that.metadata);
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
    TResult? Function(String uri, Map<String, dynamic>? metadata)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentSource() when $default != null:
        return $default(_that.uri, _that.metadata);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _DocumentSource implements DocumentSource {
  const _DocumentSource(
      {required this.uri, final Map<String, dynamic>? metadata})
      : _metadata = metadata;
  factory _DocumentSource.fromJson(Map<String, dynamic> json) =>
      _$DocumentSourceFromJson(json);

  /// URI of the document source
  @override
  final String uri;

  /// Additional metadata
  final Map<String, dynamic>? _metadata;

  /// Additional metadata
  @override
  Map<String, dynamic>? get metadata {
    final value = _metadata;
    if (value == null) return null;
    if (_metadata is EqualUnmodifiableMapView) return _metadata;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Create a copy of DocumentSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$DocumentSourceCopyWith<_DocumentSource> get copyWith =>
      __$DocumentSourceCopyWithImpl<_DocumentSource>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$DocumentSourceToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _DocumentSource &&
            (identical(other.uri, uri) || other.uri == uri) &&
            const DeepCollectionEquality().equals(other._metadata, _metadata));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, uri, const DeepCollectionEquality().hash(_metadata));

  @override
  String toString() {
    return 'DocumentSource(uri: $uri, metadata: $metadata)';
  }
}

/// @nodoc
abstract mixin class _$DocumentSourceCopyWith<$Res>
    implements $DocumentSourceCopyWith<$Res> {
  factory _$DocumentSourceCopyWith(
          _DocumentSource value, $Res Function(_DocumentSource) _then) =
      __$DocumentSourceCopyWithImpl;
  @override
  @useResult
  $Res call({String uri, Map<String, dynamic>? metadata});
}

/// @nodoc
class __$DocumentSourceCopyWithImpl<$Res>
    implements _$DocumentSourceCopyWith<$Res> {
  __$DocumentSourceCopyWithImpl(this._self, this._then);

  final _DocumentSource _self;
  final $Res Function(_DocumentSource) _then;

  /// Create a copy of DocumentSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? uri = null,
    Object? metadata = freezed,
  }) {
    return _then(_DocumentSource(
      uri: null == uri
          ? _self.uri
          : uri // ignore: cast_nullable_to_non_nullable
              as String,
      metadata: freezed == metadata
          ? _self._metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// @nodoc
mixin _$Document {
  /// Unique identifier for the document
  String? get id;

  /// Text content of the document
  String get content;

  /// Metadata associated with the document
  Map<String, dynamic> get metadata;

  /// Source information
  DocumentSource? get source;

  /// Embedding vector (if available)
  List<double>? get embedding;

  /// Relevance score (if from retrieval)
  double? get score;

  /// Create a copy of Document
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $DocumentCopyWith<Document> get copyWith =>
      _$DocumentCopyWithImpl<Document>(this as Document, _$identity);

  /// Serializes this Document to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is Document &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.content, content) || other.content == content) &&
            const DeepCollectionEquality().equals(other.metadata, metadata) &&
            (identical(other.source, source) || other.source == source) &&
            const DeepCollectionEquality().equals(other.embedding, embedding) &&
            (identical(other.score, score) || other.score == score));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      id,
      content,
      const DeepCollectionEquality().hash(metadata),
      source,
      const DeepCollectionEquality().hash(embedding),
      score);

  @override
  String toString() {
    return 'Document(id: $id, content: $content, metadata: $metadata, source: $source, embedding: $embedding, score: $score)';
  }
}

/// @nodoc
abstract mixin class $DocumentCopyWith<$Res> {
  factory $DocumentCopyWith(Document value, $Res Function(Document) _then) =
      _$DocumentCopyWithImpl;
  @useResult
  $Res call(
      {String? id,
      String content,
      Map<String, dynamic> metadata,
      DocumentSource? source,
      List<double>? embedding,
      double? score});

  $DocumentSourceCopyWith<$Res>? get source;
}

/// @nodoc
class _$DocumentCopyWithImpl<$Res> implements $DocumentCopyWith<$Res> {
  _$DocumentCopyWithImpl(this._self, this._then);

  final Document _self;
  final $Res Function(Document) _then;

  /// Create a copy of Document
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = freezed,
    Object? content = null,
    Object? metadata = null,
    Object? source = freezed,
    Object? embedding = freezed,
    Object? score = freezed,
  }) {
    return _then(_self.copyWith(
      id: freezed == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String?,
      content: null == content
          ? _self.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      metadata: null == metadata
          ? _self.metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
      source: freezed == source
          ? _self.source
          : source // ignore: cast_nullable_to_non_nullable
              as DocumentSource?,
      embedding: freezed == embedding
          ? _self.embedding
          : embedding // ignore: cast_nullable_to_non_nullable
              as List<double>?,
      score: freezed == score
          ? _self.score
          : score // ignore: cast_nullable_to_non_nullable
              as double?,
    ));
  }

  /// Create a copy of Document
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $DocumentSourceCopyWith<$Res>? get source {
    if (_self.source == null) {
      return null;
    }

    return $DocumentSourceCopyWith<$Res>(_self.source!, (value) {
      return _then(_self.copyWith(source: value));
    });
  }
}

/// Adds pattern-matching-related methods to [Document].
extension DocumentPatterns on Document {
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
    TResult Function(_Document value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _Document() when $default != null:
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
    TResult Function(_Document value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Document():
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
    TResult? Function(_Document value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Document() when $default != null:
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
    TResult Function(String? id, String content, Map<String, dynamic> metadata,
            DocumentSource? source, List<double>? embedding, double? score)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _Document() when $default != null:
        return $default(_that.id, _that.content, _that.metadata, _that.source,
            _that.embedding, _that.score);
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
    TResult Function(String? id, String content, Map<String, dynamic> metadata,
            DocumentSource? source, List<double>? embedding, double? score)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Document():
        return $default(_that.id, _that.content, _that.metadata, _that.source,
            _that.embedding, _that.score);
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
    TResult? Function(String? id, String content, Map<String, dynamic> metadata,
            DocumentSource? source, List<double>? embedding, double? score)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _Document() when $default != null:
        return $default(_that.id, _that.content, _that.metadata, _that.source,
            _that.embedding, _that.score);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _Document extends Document {
  const _Document(
      {this.id,
      required this.content,
      final Map<String, dynamic> metadata = const {},
      this.source,
      final List<double>? embedding,
      this.score})
      : _metadata = metadata,
        _embedding = embedding,
        super._();
  factory _Document.fromJson(Map<String, dynamic> json) =>
      _$DocumentFromJson(json);

  /// Unique identifier for the document
  @override
  final String? id;

  /// Text content of the document
  @override
  final String content;

  /// Metadata associated with the document
  final Map<String, dynamic> _metadata;

  /// Metadata associated with the document
  @override
  @JsonKey()
  Map<String, dynamic> get metadata {
    if (_metadata is EqualUnmodifiableMapView) return _metadata;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_metadata);
  }

  /// Source information
  @override
  final DocumentSource? source;

  /// Embedding vector (if available)
  final List<double>? _embedding;

  /// Embedding vector (if available)
  @override
  List<double>? get embedding {
    final value = _embedding;
    if (value == null) return null;
    if (_embedding is EqualUnmodifiableListView) return _embedding;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Relevance score (if from retrieval)
  @override
  final double? score;

  /// Create a copy of Document
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$DocumentCopyWith<_Document> get copyWith =>
      __$DocumentCopyWithImpl<_Document>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$DocumentToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _Document &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.content, content) || other.content == content) &&
            const DeepCollectionEquality().equals(other._metadata, _metadata) &&
            (identical(other.source, source) || other.source == source) &&
            const DeepCollectionEquality()
                .equals(other._embedding, _embedding) &&
            (identical(other.score, score) || other.score == score));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      id,
      content,
      const DeepCollectionEquality().hash(_metadata),
      source,
      const DeepCollectionEquality().hash(_embedding),
      score);

  @override
  String toString() {
    return 'Document(id: $id, content: $content, metadata: $metadata, source: $source, embedding: $embedding, score: $score)';
  }
}

/// @nodoc
abstract mixin class _$DocumentCopyWith<$Res>
    implements $DocumentCopyWith<$Res> {
  factory _$DocumentCopyWith(_Document value, $Res Function(_Document) _then) =
      __$DocumentCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String? id,
      String content,
      Map<String, dynamic> metadata,
      DocumentSource? source,
      List<double>? embedding,
      double? score});

  @override
  $DocumentSourceCopyWith<$Res>? get source;
}

/// @nodoc
class __$DocumentCopyWithImpl<$Res> implements _$DocumentCopyWith<$Res> {
  __$DocumentCopyWithImpl(this._self, this._then);

  final _Document _self;
  final $Res Function(_Document) _then;

  /// Create a copy of Document
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = freezed,
    Object? content = null,
    Object? metadata = null,
    Object? source = freezed,
    Object? embedding = freezed,
    Object? score = freezed,
  }) {
    return _then(_Document(
      id: freezed == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String?,
      content: null == content
          ? _self.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      metadata: null == metadata
          ? _self._metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
      source: freezed == source
          ? _self.source
          : source // ignore: cast_nullable_to_non_nullable
              as DocumentSource?,
      embedding: freezed == embedding
          ? _self._embedding
          : embedding // ignore: cast_nullable_to_non_nullable
              as List<double>?,
      score: freezed == score
          ? _self.score
          : score // ignore: cast_nullable_to_non_nullable
              as double?,
    ));
  }

  /// Create a copy of Document
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $DocumentSourceCopyWith<$Res>? get source {
    if (_self.source == null) {
      return null;
    }

    return $DocumentSourceCopyWith<$Res>(_self.source!, (value) {
      return _then(_self.copyWith(source: value));
    });
  }
}

/// @nodoc
mixin _$DocumentChunk {
  /// Chunk content
  String get content;

  /// Metadata from parent document
  Map<String, dynamic> get metadata;

  /// Chunk index in the parent document
  int? get index;

  /// Parent document ID
  String? get parentId;

  /// Start position in parent
  int? get startPosition;

  /// End position in parent
  int? get endPosition;

  /// Create a copy of DocumentChunk
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $DocumentChunkCopyWith<DocumentChunk> get copyWith =>
      _$DocumentChunkCopyWithImpl<DocumentChunk>(
          this as DocumentChunk, _$identity);

  /// Serializes this DocumentChunk to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is DocumentChunk &&
            (identical(other.content, content) || other.content == content) &&
            const DeepCollectionEquality().equals(other.metadata, metadata) &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.parentId, parentId) ||
                other.parentId == parentId) &&
            (identical(other.startPosition, startPosition) ||
                other.startPosition == startPosition) &&
            (identical(other.endPosition, endPosition) ||
                other.endPosition == endPosition));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      content,
      const DeepCollectionEquality().hash(metadata),
      index,
      parentId,
      startPosition,
      endPosition);

  @override
  String toString() {
    return 'DocumentChunk(content: $content, metadata: $metadata, index: $index, parentId: $parentId, startPosition: $startPosition, endPosition: $endPosition)';
  }
}

/// @nodoc
abstract mixin class $DocumentChunkCopyWith<$Res> {
  factory $DocumentChunkCopyWith(
          DocumentChunk value, $Res Function(DocumentChunk) _then) =
      _$DocumentChunkCopyWithImpl;
  @useResult
  $Res call(
      {String content,
      Map<String, dynamic> metadata,
      int? index,
      String? parentId,
      int? startPosition,
      int? endPosition});
}

/// @nodoc
class _$DocumentChunkCopyWithImpl<$Res>
    implements $DocumentChunkCopyWith<$Res> {
  _$DocumentChunkCopyWithImpl(this._self, this._then);

  final DocumentChunk _self;
  final $Res Function(DocumentChunk) _then;

  /// Create a copy of DocumentChunk
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? content = null,
    Object? metadata = null,
    Object? index = freezed,
    Object? parentId = freezed,
    Object? startPosition = freezed,
    Object? endPosition = freezed,
  }) {
    return _then(_self.copyWith(
      content: null == content
          ? _self.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      metadata: null == metadata
          ? _self.metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
      index: freezed == index
          ? _self.index
          : index // ignore: cast_nullable_to_non_nullable
              as int?,
      parentId: freezed == parentId
          ? _self.parentId
          : parentId // ignore: cast_nullable_to_non_nullable
              as String?,
      startPosition: freezed == startPosition
          ? _self.startPosition
          : startPosition // ignore: cast_nullable_to_non_nullable
              as int?,
      endPosition: freezed == endPosition
          ? _self.endPosition
          : endPosition // ignore: cast_nullable_to_non_nullable
              as int?,
    ));
  }
}

/// Adds pattern-matching-related methods to [DocumentChunk].
extension DocumentChunkPatterns on DocumentChunk {
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
    TResult Function(_DocumentChunk value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _DocumentChunk() when $default != null:
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
    TResult Function(_DocumentChunk value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentChunk():
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
    TResult? Function(_DocumentChunk value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentChunk() when $default != null:
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
    TResult Function(String content, Map<String, dynamic> metadata, int? index,
            String? parentId, int? startPosition, int? endPosition)?
        $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _DocumentChunk() when $default != null:
        return $default(_that.content, _that.metadata, _that.index,
            _that.parentId, _that.startPosition, _that.endPosition);
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
    TResult Function(String content, Map<String, dynamic> metadata, int? index,
            String? parentId, int? startPosition, int? endPosition)
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentChunk():
        return $default(_that.content, _that.metadata, _that.index,
            _that.parentId, _that.startPosition, _that.endPosition);
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
    TResult? Function(String content, Map<String, dynamic> metadata, int? index,
            String? parentId, int? startPosition, int? endPosition)?
        $default,
  ) {
    final _that = this;
    switch (_that) {
      case _DocumentChunk() when $default != null:
        return $default(_that.content, _that.metadata, _that.index,
            _that.parentId, _that.startPosition, _that.endPosition);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _DocumentChunk implements DocumentChunk {
  const _DocumentChunk(
      {required this.content,
      final Map<String, dynamic> metadata = const {},
      this.index,
      this.parentId,
      this.startPosition,
      this.endPosition})
      : _metadata = metadata;
  factory _DocumentChunk.fromJson(Map<String, dynamic> json) =>
      _$DocumentChunkFromJson(json);

  /// Chunk content
  @override
  final String content;

  /// Metadata from parent document
  final Map<String, dynamic> _metadata;

  /// Metadata from parent document
  @override
  @JsonKey()
  Map<String, dynamic> get metadata {
    if (_metadata is EqualUnmodifiableMapView) return _metadata;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_metadata);
  }

  /// Chunk index in the parent document
  @override
  final int? index;

  /// Parent document ID
  @override
  final String? parentId;

  /// Start position in parent
  @override
  final int? startPosition;

  /// End position in parent
  @override
  final int? endPosition;

  /// Create a copy of DocumentChunk
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$DocumentChunkCopyWith<_DocumentChunk> get copyWith =>
      __$DocumentChunkCopyWithImpl<_DocumentChunk>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$DocumentChunkToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _DocumentChunk &&
            (identical(other.content, content) || other.content == content) &&
            const DeepCollectionEquality().equals(other._metadata, _metadata) &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.parentId, parentId) ||
                other.parentId == parentId) &&
            (identical(other.startPosition, startPosition) ||
                other.startPosition == startPosition) &&
            (identical(other.endPosition, endPosition) ||
                other.endPosition == endPosition));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      content,
      const DeepCollectionEquality().hash(_metadata),
      index,
      parentId,
      startPosition,
      endPosition);

  @override
  String toString() {
    return 'DocumentChunk(content: $content, metadata: $metadata, index: $index, parentId: $parentId, startPosition: $startPosition, endPosition: $endPosition)';
  }
}

/// @nodoc
abstract mixin class _$DocumentChunkCopyWith<$Res>
    implements $DocumentChunkCopyWith<$Res> {
  factory _$DocumentChunkCopyWith(
          _DocumentChunk value, $Res Function(_DocumentChunk) _then) =
      __$DocumentChunkCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String content,
      Map<String, dynamic> metadata,
      int? index,
      String? parentId,
      int? startPosition,
      int? endPosition});
}

/// @nodoc
class __$DocumentChunkCopyWithImpl<$Res>
    implements _$DocumentChunkCopyWith<$Res> {
  __$DocumentChunkCopyWithImpl(this._self, this._then);

  final _DocumentChunk _self;
  final $Res Function(_DocumentChunk) _then;

  /// Create a copy of DocumentChunk
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? content = null,
    Object? metadata = null,
    Object? index = freezed,
    Object? parentId = freezed,
    Object? startPosition = freezed,
    Object? endPosition = freezed,
  }) {
    return _then(_DocumentChunk(
      content: null == content
          ? _self.content
          : content // ignore: cast_nullable_to_non_nullable
              as String,
      metadata: null == metadata
          ? _self._metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
      index: freezed == index
          ? _self.index
          : index // ignore: cast_nullable_to_non_nullable
              as int?,
      parentId: freezed == parentId
          ? _self.parentId
          : parentId // ignore: cast_nullable_to_non_nullable
              as String?,
      startPosition: freezed == startPosition
          ? _self.startPosition
          : startPosition // ignore: cast_nullable_to_non_nullable
              as int?,
      endPosition: freezed == endPosition
          ? _self.endPosition
          : endPosition // ignore: cast_nullable_to_non_nullable
              as int?,
    ));
  }
}

/// @nodoc
mixin _$ChunkedDocument {
  /// Original document
  Document get document;

  /// Document chunks
  List<DocumentChunk> get chunks;

  /// Create a copy of ChunkedDocument
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ChunkedDocumentCopyWith<ChunkedDocument> get copyWith =>
      _$ChunkedDocumentCopyWithImpl<ChunkedDocument>(
          this as ChunkedDocument, _$identity);

  /// Serializes this ChunkedDocument to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ChunkedDocument &&
            (identical(other.document, document) ||
                other.document == document) &&
            const DeepCollectionEquality().equals(other.chunks, chunks));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, document, const DeepCollectionEquality().hash(chunks));

  @override
  String toString() {
    return 'ChunkedDocument(document: $document, chunks: $chunks)';
  }
}

/// @nodoc
abstract mixin class $ChunkedDocumentCopyWith<$Res> {
  factory $ChunkedDocumentCopyWith(
          ChunkedDocument value, $Res Function(ChunkedDocument) _then) =
      _$ChunkedDocumentCopyWithImpl;
  @useResult
  $Res call({Document document, List<DocumentChunk> chunks});

  $DocumentCopyWith<$Res> get document;
}

/// @nodoc
class _$ChunkedDocumentCopyWithImpl<$Res>
    implements $ChunkedDocumentCopyWith<$Res> {
  _$ChunkedDocumentCopyWithImpl(this._self, this._then);

  final ChunkedDocument _self;
  final $Res Function(ChunkedDocument) _then;

  /// Create a copy of ChunkedDocument
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? document = null,
    Object? chunks = null,
  }) {
    return _then(_self.copyWith(
      document: null == document
          ? _self.document
          : document // ignore: cast_nullable_to_non_nullable
              as Document,
      chunks: null == chunks
          ? _self.chunks
          : chunks // ignore: cast_nullable_to_non_nullable
              as List<DocumentChunk>,
    ));
  }

  /// Create a copy of ChunkedDocument
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $DocumentCopyWith<$Res> get document {
    return $DocumentCopyWith<$Res>(_self.document, (value) {
      return _then(_self.copyWith(document: value));
    });
  }
}

/// Adds pattern-matching-related methods to [ChunkedDocument].
extension ChunkedDocumentPatterns on ChunkedDocument {
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
    TResult Function(_ChunkedDocument value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ChunkedDocument() when $default != null:
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
    TResult Function(_ChunkedDocument value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChunkedDocument():
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
    TResult? Function(_ChunkedDocument value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChunkedDocument() when $default != null:
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
    TResult Function(Document document, List<DocumentChunk> chunks)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ChunkedDocument() when $default != null:
        return $default(_that.document, _that.chunks);
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
    TResult Function(Document document, List<DocumentChunk> chunks) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChunkedDocument():
        return $default(_that.document, _that.chunks);
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
    TResult? Function(Document document, List<DocumentChunk> chunks)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChunkedDocument() when $default != null:
        return $default(_that.document, _that.chunks);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _ChunkedDocument implements ChunkedDocument {
  const _ChunkedDocument(
      {required this.document, required final List<DocumentChunk> chunks})
      : _chunks = chunks;
  factory _ChunkedDocument.fromJson(Map<String, dynamic> json) =>
      _$ChunkedDocumentFromJson(json);

  /// Original document
  @override
  final Document document;

  /// Document chunks
  final List<DocumentChunk> _chunks;

  /// Document chunks
  @override
  List<DocumentChunk> get chunks {
    if (_chunks is EqualUnmodifiableListView) return _chunks;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_chunks);
  }

  /// Create a copy of ChunkedDocument
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ChunkedDocumentCopyWith<_ChunkedDocument> get copyWith =>
      __$ChunkedDocumentCopyWithImpl<_ChunkedDocument>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$ChunkedDocumentToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ChunkedDocument &&
            (identical(other.document, document) ||
                other.document == document) &&
            const DeepCollectionEquality().equals(other._chunks, _chunks));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, document, const DeepCollectionEquality().hash(_chunks));

  @override
  String toString() {
    return 'ChunkedDocument(document: $document, chunks: $chunks)';
  }
}

/// @nodoc
abstract mixin class _$ChunkedDocumentCopyWith<$Res>
    implements $ChunkedDocumentCopyWith<$Res> {
  factory _$ChunkedDocumentCopyWith(
          _ChunkedDocument value, $Res Function(_ChunkedDocument) _then) =
      __$ChunkedDocumentCopyWithImpl;
  @override
  @useResult
  $Res call({Document document, List<DocumentChunk> chunks});

  @override
  $DocumentCopyWith<$Res> get document;
}

/// @nodoc
class __$ChunkedDocumentCopyWithImpl<$Res>
    implements _$ChunkedDocumentCopyWith<$Res> {
  __$ChunkedDocumentCopyWithImpl(this._self, this._then);

  final _ChunkedDocument _self;
  final $Res Function(_ChunkedDocument) _then;

  /// Create a copy of ChunkedDocument
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? document = null,
    Object? chunks = null,
  }) {
    return _then(_ChunkedDocument(
      document: null == document
          ? _self.document
          : document // ignore: cast_nullable_to_non_nullable
              as Document,
      chunks: null == chunks
          ? _self._chunks
          : chunks // ignore: cast_nullable_to_non_nullable
              as List<DocumentChunk>,
    ));
  }

  /// Create a copy of ChunkedDocument
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $DocumentCopyWith<$Res> get document {
    return $DocumentCopyWith<$Res>(_self.document, (value) {
      return _then(_self.copyWith(document: value));
    });
  }
}

// dart format on
