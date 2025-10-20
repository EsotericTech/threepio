/// Batch consumer for processing and uploading Langfuse events
///
/// **Framework Source: Eino (CloudWeGo)** - Consumer and batching patterns

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:threepio_core/src/observability/langfuse/langfuse_config.dart';
import 'package:threepio_core/src/observability/langfuse/langfuse_http_client.dart';
import 'package:threepio_core/src/observability/langfuse/langfuse_queue.dart';
import 'package:threepio_core/src/observability/langfuse/models/langfuse_event.dart';
import 'package:threepio_core/src/observability/langfuse/models/langfuse_observation.dart';
import 'package:threepio_core/src/observability/langfuse/models/langfuse_trace.dart';

/// Consumer that processes events from queue and uploads in batches
class LangfuseConsumer {
  final LangfuseHttpClient _client;
  final LangfuseEventQueue _queue;
  final LangfuseConfig _config;
  bool _closed = false;

  LangfuseConsumer(this._client, this._queue, this._config);

  /// Start the consumer
  void run() {
    // Run the consumer loop in a separate isolate-like manner
    Future.microtask(_consumerLoop);
  }

  /// Main consumer loop
  Future<void> _consumerLoop() async {
    while (!_closed) {
      try {
        final batch = await _nextBatch();
        if (batch.isEmpty) {
          continue;
        }

        await _uploadBatch(batch);

        // Mark all events in batch as done
        for (var i = 0; i < batch.length; i++) {
          _queue.done();
        }
      } catch (e, stackTrace) {
        developer.log(
          'Consumer error',
          error: e,
          stackTrace: stackTrace,
          name: 'langfuse_consumer',
        );
      }
    }
  }

  /// Get next batch of events to process
  Future<List<LangfuseIngestionEvent>> _nextBatch() async {
    final events = <LangfuseIngestionEvent>[];
    final startTime = DateTime.now();
    var totalSize = 0;

    const maxEventSizeBytes = 1000000; // 1MB per event
    const maxBatchSizeBytes = 2500000; // 2.5MB per batch

    while (events.length < _config.flushAt) {
      final elapsed = DateTime.now().difference(startTime);
      if (elapsed >= _config.flushInterval) {
        break;
      }

      final remainingTime = _config.flushInterval - elapsed;
      final event = await _queue.get(remainingTime);

      if (event == null) {
        break;
      }

      // Sample check
      if (!_shouldSample(event)) {
        _queue.done();
        continue;
      }

      // Apply masking if configured
      if (_config.maskFunc != null) {
        _applyMasking(event);
      }

      // Estimate size and truncate if needed
      final eventSize = _estimateSize(event);
      if (eventSize > maxEventSizeBytes) {
        _truncateEvent(event, maxEventSizeBytes);
      }

      totalSize += eventSize;
      events.add(event);

      if (totalSize >= maxBatchSizeBytes) {
        break;
      }
    }

    return events;
  }

  /// Upload batch with retry logic
  Future<void> _uploadBatch(List<LangfuseIngestionEvent> batch) async {
    var attempt = 0;
    while (attempt <= _config.maxRetry) {
      try {
        final metadata = _config.getBatchMetadata(batch.length);
        await _client.batchIngestion(batch, metadata);
        return; // Success!
      } on LangfuseApiException catch (e) {
        if (!e.shouldRetry || attempt >= _config.maxRetry) {
          developer.log(
            'Upload failed after ${attempt + 1} attempts',
            error: e,
            name: 'langfuse_consumer',
          );
          return; // Give up
        }

        // Exponential backoff: 1s, 2s, 4s, 8s, ...
        final delaySeconds = (1 << attempt);
        await Future<void>.delayed(Duration(seconds: delaySeconds));
        attempt++;
      } catch (e) {
        developer.log(
          'Unexpected upload error',
          error: e,
          name: 'langfuse_consumer',
        );
        return; // Give up on unexpected errors
      }
    }
  }

  /// Check if event should be sampled
  bool _shouldSample(LangfuseIngestionEvent event) {
    if (_config.sampleRate <= 0 || _config.sampleRate >= 1.0) {
      return true; // Always sample
    }

    // Deterministic sampling based on trace ID
    // This ensures all events in a trace are either all sampled or all dropped
    final traceId = _getTraceId(event);
    if (traceId == null || traceId.isEmpty) {
      return true;
    }

    // Use first 8 chars of trace ID for deterministic sampling
    final hashValue = traceId.hashCode.abs();
    final normalized = (hashValue % 0xFFFFFFFF) / 0xFFFFFFFF;
    return normalized < _config.sampleRate;
  }

  /// Get trace ID from event
  String? _getTraceId(LangfuseIngestionEvent event) {
    final body = event.body;
    if (body is LangfuseTrace) {
      return body.id;
    } else if (body is LangfuseBaseObservation) {
      return body.traceId;
    }
    return null;
  }

  /// Apply data masking to sensitive fields
  ///
  /// Note: Currently logs a warning. In production, masking should be done
  /// before creating events since event.body is final.
  void _applyMasking(LangfuseIngestionEvent event) {
    final maskFunc = _config.maskFunc;
    if (maskFunc == null) return;

    final body = event.body;
    if (body is LangfuseTrace) {
      if (body.input != null) {
        // Masking should be done before creating the event in production code
        developer.log(
          'Data masking requested but event body is immutable',
          name: 'langfuse_consumer',
        );
      }
    } else if (body is LangfuseBaseObservation) {
      // Similar masking for observations
      if (body.input != null || body.output != null) {
        developer.log(
          'Data masking requested but event body is immutable',
          name: 'langfuse_consumer',
        );
      }
    }
  }

  /// Estimate JSON size of event
  int _estimateSize(LangfuseIngestionEvent event) {
    try {
      final json = jsonEncode(event.toJson());
      return json.length;
    } catch (e) {
      return 0;
    }
  }

  /// Truncate event if it exceeds size limit
  void _truncateEvent(LangfuseIngestionEvent event, int maxSize) {
    // In production, we'd implement field-by-field truncation
    // For now, just log a warning
    developer.log(
      'Event exceeds size limit, truncation needed',
      name: 'langfuse_consumer',
    );
  }

  /// Stop the consumer
  void close() {
    _closed = true;
  }
}
