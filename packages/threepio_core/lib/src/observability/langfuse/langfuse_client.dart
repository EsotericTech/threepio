/// Main Langfuse client for observability and cost tracking
///
/// **Framework Source: Eino (CloudWeGo)** - Client architecture and patterns
/// **Framework Source: Langfuse** - API integration
///
/// Example:
/// ```dart
/// final client = LangfuseClient(config);
///
/// // Create a trace
/// final traceId = await client.createTrace(
///   LangfuseTrace(name: 'user-query'),
/// );
///
/// // Create a generation
/// final generationId = await client.createGeneration(
///   LangfuseGeneration(
///     traceId: traceId,
///     model: 'gpt-4',
///     usage: LangfuseUsage(promptTokens: 100, completionTokens: 50),
///   ),
/// );
///
/// // Flush and cleanup
/// await client.flush();
/// await client.dispose();
/// ```

import 'package:uuid/uuid.dart';

import 'langfuse_config.dart';
import 'langfuse_consumer.dart';
import 'langfuse_http_client.dart';
import 'langfuse_queue.dart';
import 'models/langfuse_event.dart';
import 'models/langfuse_observation.dart';
import 'models/langfuse_trace.dart';

/// Main Langfuse client interface
class LangfuseClient {
  final LangfuseConfig _config;
  final LangfuseHttpClient _httpClient;
  final LangfuseEventQueue _queue;
  final List<LangfuseConsumer> _consumers = [];
  final _uuid = const Uuid();

  LangfuseClient(this._config)
      : _httpClient = LangfuseHttpClient(_config),
        _queue = LangfuseEventQueue(_config.maxTaskQueueSize) {
    // Start consumer threads
    for (var i = 0; i < _config.threads; i++) {
      final consumer = LangfuseConsumer(_httpClient, _queue, _config);
      consumer.run();
      _consumers.add(consumer);
    }
  }

  /// Create a new trace
  ///
  /// Returns the trace ID (generated if not provided)
  Future<String> createTrace(LangfuseTrace trace) async {
    final traceId = trace.id ?? _uuid.v4();
    final traceWithId = trace.copyWith(id: traceId);

    final event = LangfuseIngestionEvent(
      type: LangfuseEventType.traceCreate,
      body: traceWithId,
    );

    final success = _queue.put(event);
    if (!success) {
      throw LangfuseQueueFullException('Event queue is full');
    }

    return traceId;
  }

  /// Create a new span
  ///
  /// Returns the span ID (generated if not provided)
  Future<String> createSpan(LangfuseSpan span) async {
    final spanId = span.id ?? _uuid.v4();
    final spanWithId = span.copyWith(id: spanId);

    final event = LangfuseIngestionEvent(
      type: LangfuseEventType.spanCreate,
      body: spanWithId,
    );

    final success = _queue.put(event);
    if (!success) {
      throw LangfuseQueueFullException('Event queue is full');
    }

    return spanId;
  }

  /// End/update a span
  Future<void> endSpan(LangfuseSpan span) async {
    final event = LangfuseIngestionEvent(
      type: LangfuseEventType.spanUpdate,
      body: span,
    );

    final success = _queue.put(event);
    if (!success) {
      throw LangfuseQueueFullException('Event queue is full');
    }
  }

  /// Create a new generation
  ///
  /// Returns the generation ID (generated if not provided)
  Future<String> createGeneration(LangfuseGeneration generation) async {
    final generationId = generation.id ?? _uuid.v4();
    final generationWithId = generation.copyWith(id: generationId);

    final event = LangfuseIngestionEvent(
      type: LangfuseEventType.generationCreate,
      body: generationWithId,
    );

    final success = _queue.put(event);
    if (!success) {
      throw LangfuseQueueFullException('Event queue is full');
    }

    return generationId;
  }

  /// End/update a generation
  Future<void> endGeneration(LangfuseGeneration generation) async {
    final event = LangfuseIngestionEvent(
      type: LangfuseEventType.generationUpdate,
      body: generation,
    );

    final success = _queue.put(event);
    if (!success) {
      throw LangfuseQueueFullException('Event queue is full');
    }
  }

  /// Create a new event
  ///
  /// Returns the event ID (generated if not provided)
  Future<String> createEvent(LangfuseEvent langfuseEvent) async {
    final eventId = langfuseEvent.id ?? _uuid.v4();
    final eventWithId = langfuseEvent.copyWith(id: eventId);

    final event = LangfuseIngestionEvent(
      type: LangfuseEventType.eventCreate,
      body: eventWithId,
    );

    final success = _queue.put(event);
    if (!success) {
      throw LangfuseQueueFullException('Event queue is full');
    }

    return eventId;
  }

  /// Flush all pending events
  ///
  /// Waits for all events in the queue to be processed and uploaded
  Future<void> flush() async {
    await _queue.join();
  }

  /// Dispose and cleanup resources
  ///
  /// Flushes pending events and closes all connections
  Future<void> dispose() async {
    // Stop consumers
    for (final consumer in _consumers) {
      consumer.close();
    }

    // Flush remaining events
    await flush();

    // Close HTTP client
    _httpClient.close();

    // Dispose queue
    await _queue.dispose();
  }

  /// Get current queue length
  int get queueLength => _queue.length;

  /// Get number of unfinished tasks
  int get unfinishedTasks => _queue.unfinished;
}

/// Exception thrown when event queue is full
class LangfuseQueueFullException implements Exception {
  final String message;

  const LangfuseQueueFullException(this.message);

  @override
  String toString() => 'LangfuseQueueFullException: $message';
}
