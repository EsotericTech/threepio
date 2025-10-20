/// Langfuse event data models
///
/// **Framework Source: Eino (CloudWeGo)** - Event structure and batching patterns
/// **Framework Source: Langfuse** - Official API specification
///
/// These models represent the core data structures used for sending
/// observability data to Langfuse. They support:
/// - Hierarchical trace structure (Trace → Observation)
/// - Token usage and cost tracking
/// - Batch ingestion for performance
/// - Type-safe event creation

import 'package:uuid/uuid.dart';

/// Event type enum matching Langfuse API
enum LangfuseEventType {
  traceCreate('trace-create'),
  spanCreate('span-create'),
  spanUpdate('span-update'),
  generationCreate('generation-create'),
  generationUpdate('generation-update'),
  eventCreate('event-create'),
  scoreCreate('score-create'),
  sdkLog('sdk-log');

  const LangfuseEventType(this.value);
  final String value;

  @override
  String toString() => value;
}

/// Level type for observations
enum LangfuseLevelType {
  debug('DEBUG'),
  defaultLevel('DEFAULT'),
  warning('WARNING'),
  error('ERROR');

  const LangfuseLevelType(this.value);
  final String value;

  String toJson() => value;

  static LangfuseLevelType fromJson(String value) {
    return LangfuseLevelType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => LangfuseLevelType.defaultLevel,
    );
  }
}

/// Wrapper event for batch ingestion
///
/// Example:
/// ```dart
/// final event = LangfuseIngestionEvent(
///   type: LangfuseEventType.traceCreate,
///   body: traceBody,
/// );
/// ```
class LangfuseIngestionEvent {
  /// Unique event ID
  final String id;

  /// Event type (trace-create, span-create, etc.)
  final LangfuseEventType type;

  /// Event timestamp
  final DateTime timestamp;

  /// Optional metadata
  final Map<String, String>? metadata;

  /// Event body (Trace, Span, Generation, or Event)
  final dynamic body;

  LangfuseIngestionEvent({
    String? id,
    required this.type,
    DateTime? timestamp,
    this.metadata,
    required this.body,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.value,
      'timestamp': timestamp.toIso8601String(),
      if (metadata != null) 'metadata': metadata,
      'body': body.toJson(),
    };
  }
}

/// Base class for all Langfuse event bodies
abstract class LangfuseBaseEvent {
  final String? id;
  final String? name;
  final Map<String, dynamic>? metadata;
  final String? version;

  const LangfuseBaseEvent({
    this.id,
    this.name,
    this.metadata,
    this.version,
  });

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (metadata != null) 'metadata': metadata,
      if (version != null) 'version': version,
    };
  }
}

/// Batch ingestion request structure
class LangfuseBatchIngestionRequest {
  final List<LangfuseIngestionEvent> batch;
  final Map<String, String>? metadata;

  const LangfuseBatchIngestionRequest({
    required this.batch,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    return {
      'batch': batch.map((e) => e.toJson()).toList(),
      if (metadata != null) 'metadata': metadata,
    };
  }
}

/// Batch ingestion response structure
class LangfuseBatchIngestionResponse {
  final List<LangfuseBatchSuccess> success;
  final List<LangfuseBatchError> errors;

  const LangfuseBatchIngestionResponse({
    required this.success,
    required this.errors,
  });

  factory LangfuseBatchIngestionResponse.fromJson(Map<String, dynamic> json) {
    return LangfuseBatchIngestionResponse(
      success: (json['success'] as List<dynamic>?)
              ?.map((e) =>
                  LangfuseBatchSuccess.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      errors: (json['errors'] as List<dynamic>?)
              ?.map(
                  (e) => LangfuseBatchError.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  bool get hasErrors => errors.isNotEmpty;
  bool get isSuccessful => errors.isEmpty;
}

/// Successful batch ingestion item
class LangfuseBatchSuccess {
  final String id;
  final int status;

  const LangfuseBatchSuccess({
    required this.id,
    required this.status,
  });

  factory LangfuseBatchSuccess.fromJson(Map<String, dynamic> json) {
    return LangfuseBatchSuccess(
      id: json['id'] as String,
      status: json['status'] as int,
    );
  }
}

/// Failed batch ingestion item
class LangfuseBatchError {
  final String id;
  final int status;
  final String? message;
  final dynamic error;

  const LangfuseBatchError({
    required this.id,
    required this.status,
    this.message,
    this.error,
  });

  factory LangfuseBatchError.fromJson(Map<String, dynamic> json) {
    return LangfuseBatchError(
      id: json['id'] as String,
      status: json['status'] as int,
      message: json['message'] as String?,
      error: json['error'],
    );
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('LangfuseBatchError(id: $id, status: $status');
    if (message != null) buffer.write(', message: $message');
    if (error != null) buffer.write(', error: $error');
    buffer.write(')');
    return buffer.toString();
  }
}
