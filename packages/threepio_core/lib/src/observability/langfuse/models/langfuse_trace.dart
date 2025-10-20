/// Langfuse trace data model
///
/// **Framework Source: Eino (CloudWeGo)** - Trace structure and patterns
/// **Framework Source: Langfuse** - Trace API specification
///
/// A trace represents the top-level container for tracking an entire workflow
/// or request. All observations (spans, generations, events) belong to a trace.

import 'langfuse_event.dart';

/// Trace event body
///
/// Example:
/// ```dart
/// final trace = LangfuseTrace(
///   name: 'user-query-workflow',
///   userId: 'user-123',
///   sessionId: 'session-456',
///   tags: ['production', 'feature-x'],
///   input: 'What is the capital of France?',
/// );
/// ```
class LangfuseTrace extends LangfuseBaseEvent {
  /// Timestamp when the trace was created
  final DateTime timestamp;

  /// User identifier for the trace
  final String? userId;

  /// Input to the trace (optional)
  final String? input;

  /// Output from the trace (optional)
  final String? output;

  /// Session identifier for grouping traces
  final String? sessionId;

  /// Release version or identifier
  final String? release;

  /// Tags for categorizing the trace
  final List<String>? tags;

  /// Whether the trace is publicly accessible
  final bool public;

  LangfuseTrace({
    super.id,
    super.name,
    super.metadata,
    super.version,
    DateTime? timestamp,
    this.userId,
    this.input,
    this.output,
    this.sessionId,
    this.release,
    this.tags,
    this.public = false,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'timestamp': timestamp.toIso8601String(),
      if (userId != null) 'userId': userId,
      if (input != null) 'input': input,
      if (output != null) 'output': output,
      if (sessionId != null) 'sessionId': sessionId,
      if (release != null) 'release': release,
      if (tags != null && tags!.isNotEmpty) 'tags': tags,
      'public': public,
    };
  }

  /// Create a copy with updated fields
  LangfuseTrace copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? metadata,
    String? version,
    DateTime? timestamp,
    String? userId,
    String? input,
    String? output,
    String? sessionId,
    String? release,
    List<String>? tags,
    bool? public,
  }) {
    return LangfuseTrace(
      id: id ?? this.id,
      name: name ?? this.name,
      metadata: metadata ?? this.metadata,
      version: version ?? this.version,
      timestamp: timestamp ?? this.timestamp,
      userId: userId ?? this.userId,
      input: input ?? this.input,
      output: output ?? this.output,
      sessionId: sessionId ?? this.sessionId,
      release: release ?? this.release,
      tags: tags ?? this.tags,
      public: public ?? this.public,
    );
  }
}
