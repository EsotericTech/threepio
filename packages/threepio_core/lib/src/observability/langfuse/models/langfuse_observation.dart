/// Langfuse observation data models
///
/// **Framework Source: Eino (CloudWeGo)** - Observation structure and patterns
/// **Framework Source: Langfuse** - Observation API specification
///
/// Observations are the hierarchical building blocks within a trace:
/// - Span: Represents durations of units of work
/// - Generation: Logs LLM generations with prompts, tokens, and costs
/// - Event: Tracks discrete events

import 'package:threepio_core/src/schema/message.dart';

import 'langfuse_event.dart';
import 'langfuse_usage.dart';

/// Base observation event body
///
/// Parent class for Span, Generation, and Event
abstract class LangfuseBaseObservation extends LangfuseBaseEvent {
  /// The trace ID this observation belongs to
  final String traceId;

  /// Parent observation ID for nesting
  final String? parentObservationId;

  /// Input to the observation
  final String? input;

  /// Output from the observation
  final String? output;

  /// Status message
  final String? statusMessage;

  /// Observation level (DEBUG, DEFAULT, WARNING, ERROR)
  final LangfuseLevelType level;

  /// When the observation started
  final DateTime startTime;

  LangfuseBaseObservation({
    super.id,
    super.name,
    super.metadata,
    super.version,
    required this.traceId,
    this.parentObservationId,
    this.input,
    this.output,
    this.statusMessage,
    this.level = LangfuseLevelType.defaultLevel,
    DateTime? startTime,
  }) : startTime = startTime ?? DateTime.now();

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'traceId': traceId,
      if (parentObservationId != null)
        'parentObservationId': parentObservationId,
      if (input != null) 'input': input,
      if (output != null) 'output': output,
      if (statusMessage != null) 'statusMessage': statusMessage,
      if (level != LangfuseLevelType.defaultLevel) 'level': level.toJson(),
      'startTime': startTime.toIso8601String(),
    };
  }
}

/// Span represents a unit of work within a trace
///
/// Example:
/// ```dart
/// final span = LangfuseSpan(
///   name: 'document-retrieval',
///   traceId: 'trace-123',
///   parentObservationId: 'span-parent',
///   input: jsonEncode({'query': 'search term'}),
///   endTime: DateTime.now(),
/// );
/// ```
class LangfuseSpan extends LangfuseBaseObservation {
  /// When the span ended
  final DateTime? endTime;

  LangfuseSpan({
    super.id,
    super.name,
    super.metadata,
    super.version,
    required super.traceId,
    super.parentObservationId,
    super.input,
    super.output,
    super.statusMessage,
    super.level,
    super.startTime,
    this.endTime,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      if (endTime != null) 'endTime': endTime!.toIso8601String(),
    };
  }

  LangfuseSpan copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? metadata,
    String? version,
    String? traceId,
    String? parentObservationId,
    String? input,
    String? output,
    String? statusMessage,
    LangfuseLevelType? level,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return LangfuseSpan(
      id: id ?? this.id,
      name: name ?? this.name,
      metadata: metadata ?? this.metadata,
      version: version ?? this.version,
      traceId: traceId ?? this.traceId,
      parentObservationId: parentObservationId ?? this.parentObservationId,
      input: input ?? this.input,
      output: output ?? this.output,
      statusMessage: statusMessage ?? this.statusMessage,
      level: level ?? this.level,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }
}

/// Generation represents an LLM generation with token usage and costs
///
/// Example:
/// ```dart
/// final generation = LangfuseGeneration(
///   name: 'gpt-4-completion',
///   traceId: 'trace-123',
///   model: 'gpt-4',
///   inMessages: [Message.user('Hello')],
///   outMessage: Message.assistant('Hi there!'),
///   usage: LangfuseUsage(
///     promptTokens: 10,
///     completionTokens: 5,
///     totalTokens: 15,
///   ),
///   endTime: DateTime.now(),
/// );
/// ```
class LangfuseGeneration extends LangfuseBaseObservation {
  /// Input messages (for LLM calls)
  final List<Message>? inMessages;

  /// Output message (for LLM calls)
  final Message? outMessage;

  /// When the generation ended
  final DateTime? endTime;

  /// When the completion started (for streaming)
  final DateTime? completionStartTime;

  /// Model identifier (e.g., 'gpt-4', 'claude-3-opus')
  final String? model;

  /// Prompt name (if using prompt management)
  final String? promptName;

  /// Prompt version
  final int? promptVersion;

  /// Model parameters (temperature, maxTokens, etc.)
  final Map<String, dynamic>? modelParameters;

  /// Token usage and cost tracking
  final LangfuseUsage? usage;

  LangfuseGeneration({
    super.id,
    super.name,
    super.metadata,
    super.version,
    required super.traceId,
    super.parentObservationId,
    super.input,
    super.output,
    super.statusMessage,
    super.level,
    super.startTime,
    this.inMessages,
    this.outMessage,
    this.endTime,
    this.completionStartTime,
    this.model,
    this.promptName,
    this.promptVersion,
    this.modelParameters,
    this.usage,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      if (endTime != null) 'endTime': endTime!.toIso8601String(),
      if (completionStartTime != null)
        'completionStartTime': completionStartTime!.toIso8601String(),
      if (model != null) 'model': model,
      if (promptName != null) 'promptName': promptName,
      if (promptVersion != null) 'promptVersion': promptVersion,
      if (modelParameters != null) 'modelParameters': modelParameters,
      if (usage != null) 'usage': usage!.toJson(),
      // Note: inMessages and outMessage are handled separately in the client
      // They need to be converted to Langfuse's message format
    };
  }

  LangfuseGeneration copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? metadata,
    String? version,
    String? traceId,
    String? parentObservationId,
    String? input,
    String? output,
    String? statusMessage,
    LangfuseLevelType? level,
    DateTime? startTime,
    List<Message>? inMessages,
    Message? outMessage,
    DateTime? endTime,
    DateTime? completionStartTime,
    String? model,
    String? promptName,
    int? promptVersion,
    Map<String, dynamic>? modelParameters,
    LangfuseUsage? usage,
  }) {
    return LangfuseGeneration(
      id: id ?? this.id,
      name: name ?? this.name,
      metadata: metadata ?? this.metadata,
      version: version ?? this.version,
      traceId: traceId ?? this.traceId,
      parentObservationId: parentObservationId ?? this.parentObservationId,
      input: input ?? this.input,
      output: output ?? this.output,
      statusMessage: statusMessage ?? this.statusMessage,
      level: level ?? this.level,
      startTime: startTime ?? this.startTime,
      inMessages: inMessages ?? this.inMessages,
      outMessage: outMessage ?? this.outMessage,
      endTime: endTime ?? this.endTime,
      completionStartTime: completionStartTime ?? this.completionStartTime,
      model: model ?? this.model,
      promptName: promptName ?? this.promptName,
      promptVersion: promptVersion ?? this.promptVersion,
      modelParameters: modelParameters ?? this.modelParameters,
      usage: usage ?? this.usage,
    );
  }
}

/// Event represents a discrete observation or log entry
///
/// Example:
/// ```dart
/// final event = LangfuseEvent(
///   name: 'user-action',
///   traceId: 'trace-123',
///   input: jsonEncode({'action': 'click', 'button': 'submit'}),
/// );
/// ```
class LangfuseEvent extends LangfuseBaseObservation {
  LangfuseEvent({
    super.id,
    super.name,
    super.metadata,
    super.version,
    required super.traceId,
    super.parentObservationId,
    super.input,
    super.output,
    super.statusMessage,
    super.level,
    super.startTime,
  });

  LangfuseEvent copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? metadata,
    String? version,
    String? traceId,
    String? parentObservationId,
    String? input,
    String? output,
    String? statusMessage,
    LangfuseLevelType? level,
    DateTime? startTime,
  }) {
    return LangfuseEvent(
      id: id ?? this.id,
      name: name ?? this.name,
      metadata: metadata ?? this.metadata,
      version: version ?? this.version,
      traceId: traceId ?? this.traceId,
      parentObservationId: parentObservationId ?? this.parentObservationId,
      input: input ?? this.input,
      output: output ?? this.output,
      statusMessage: statusMessage ?? this.statusMessage,
      level: level ?? this.level,
      startTime: startTime ?? this.startTime,
    );
  }
}
