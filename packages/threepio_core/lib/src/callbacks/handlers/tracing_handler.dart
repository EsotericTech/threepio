import '../callback_handler.dart';
import '../run_info.dart';

/// Trace event types
enum TraceEventType {
  start,
  end,
  error,
  streamStart,
  streamEnd,
}

/// A single trace event in the execution flow
class TraceEvent {
  TraceEvent({
    required this.timestamp,
    required this.eventType,
    required this.componentName,
    required this.componentType,
    this.data,
    this.error,
    this.depth = 0,
  });

  final DateTime timestamp;
  final TraceEventType eventType;
  final String componentName;
  final String componentType;
  final dynamic data;
  final Object? error;
  final int depth;

  @override
  String toString() {
    final indent = '  ' * depth;
    final time = timestamp.toIso8601String();

    switch (eventType) {
      case TraceEventType.start:
        return '$indent[START] $time - $componentName ($componentType)';
      case TraceEventType.end:
        return '$indent[END]   $time - $componentName';
      case TraceEventType.error:
        return '$indent[ERROR] $time - $componentName: $error';
      case TraceEventType.streamStart:
        return '$indent[STREAM START] $time - $componentName';
      case TraceEventType.streamEnd:
        return '$indent[STREAM END]   $time - $componentName';
    }
  }
}

/// Callback handler for detailed execution tracing
///
/// Records a complete trace of component execution including timing,
/// nesting depth, and data flow. Useful for debugging complex chains
/// and understanding execution order.
///
/// Example:
/// ```dart
/// final handler = TracingHandler(captureData: true);
///
/// final manager = CallbackManager([handler]);
/// final options = RunnableOptions(callbackManager: manager);
///
/// await chain.invoke(input, options: options);
///
/// // Print execution trace
/// handler.printTrace();
///
/// // Or access events programmatically
/// for (final event in handler.events) {
///   print(event);
/// }
/// ```
class TracingHandler extends BaseCallbackHandler {
  TracingHandler({
    this.captureData = false,
    this.maxDepth = 10,
  });

  /// Whether to capture input/output data in trace events
  final bool captureData;

  /// Maximum nesting depth to track
  final int maxDepth;

  /// All trace events
  final List<TraceEvent> events = [];

  /// Context key for tracking depth
  static const _depthKey = '_trace_depth';

  /// Clear all trace events
  void clear() {
    events.clear();
  }

  /// Get events for a specific component
  List<TraceEvent> getEventsFor(String componentName) {
    return events.where((e) => e.componentName == componentName).toList();
  }

  /// Print the complete trace
  void printTrace() {
    print('=== Execution Trace ===');
    for (final event in events) {
      print(event);
    }
    print('=======================');
  }

  /// Get current depth from context
  int _getDepth(Map<String, dynamic> context) {
    return (context[_depthKey] as int?) ?? 0;
  }

  /// Update depth in context
  Map<String, dynamic> _updateDepth(
    Map<String, dynamic> context,
    int depth,
  ) {
    final updated = Map<String, dynamic>.from(context);
    updated[_depthKey] = depth;
    return updated;
  }

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    final depth = _getDepth(context);

    if (depth < maxDepth) {
      final event = TraceEvent(
        timestamp: DateTime.now(),
        eventType: TraceEventType.start,
        componentName: info.name,
        componentType: info.type,
        data: captureData ? input.data : null,
        depth: depth,
      );

      events.add(event);
    }

    // Increment depth for nested components
    return _updateDepth(context, depth + 1);
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    // Decrement depth when exiting component
    final depth = _getDepth(context) - 1;

    if (depth < maxDepth) {
      final event = TraceEvent(
        timestamp: DateTime.now(),
        eventType: TraceEventType.end,
        componentName: info.name,
        componentType: info.type,
        data: captureData ? output.data : null,
        depth: depth,
      );

      events.add(event);
    }

    return _updateDepth(context, depth);
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    final depth = _getDepth(context) - 1;

    if (depth < maxDepth) {
      final event = TraceEvent(
        timestamp: DateTime.now(),
        eventType: TraceEventType.error,
        componentName: info.name,
        componentType: info.type,
        error: error,
        depth: depth,
      );

      events.add(event);
    }

    return _updateDepth(context, depth);
  }

  @override
  Future<Map<String, dynamic>> onStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async {
    final depth = _getDepth(context);

    if (depth < maxDepth) {
      final event = TraceEvent(
        timestamp: DateTime.now(),
        eventType: TraceEventType.streamStart,
        componentName: info.name,
        componentType: info.type,
        depth: depth,
      );

      events.add(event);
    }

    return _updateDepth(context, depth + 1);
  }

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    final depth = _getDepth(context) - 1;

    if (depth < maxDepth) {
      final event = TraceEvent(
        timestamp: DateTime.now(),
        eventType: TraceEventType.streamEnd,
        componentName: info.name,
        componentType: info.type,
        depth: depth,
      );

      events.add(event);
    }

    return _updateDepth(context, depth);
  }

  /// Get execution timeline (start to end duration for each component)
  Map<String, Duration> getTimeline() {
    final timeline = <String, Duration>{};
    final startTimes = <String, DateTime>{};

    for (final event in events) {
      if (event.eventType == TraceEventType.start ||
          event.eventType == TraceEventType.streamStart) {
        startTimes[event.componentName] = event.timestamp;
      } else if (event.eventType == TraceEventType.end ||
          event.eventType == TraceEventType.streamEnd) {
        final startTime = startTimes[event.componentName];
        if (startTime != null) {
          timeline[event.componentName] = event.timestamp.difference(startTime);
        }
      }
    }

    return timeline;
  }

  /// Print timeline summary
  void printTimeline() {
    final timeline = getTimeline();

    print('=== Execution Timeline ===');
    for (final entry in timeline.entries) {
      print('${entry.key}: ${entry.value.inMilliseconds}ms');
    }
    print('==========================');
  }
}
