import '../callback_handler.dart';
import '../run_info.dart';

/// Execution metrics collected by the handler
class ExecutionMetrics {
  ExecutionMetrics({
    required this.componentName,
    required this.componentType,
    required this.startTime,
    this.endTime,
    this.error,
    this.metadata,
  });

  final String componentName;
  final String componentType;
  final DateTime startTime;
  DateTime? endTime;
  Object? error;
  Map<String, dynamic>? metadata;

  /// Duration of execution (only available after completion)
  Duration? get duration {
    if (endTime == null) return null;
    return endTime!.difference(startTime);
  }

  /// Whether execution completed successfully
  bool get isSuccess => error == null && endTime != null;

  /// Whether execution failed
  bool get isFailed => error != null;

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.writeln('ExecutionMetrics:');
    buffer.writeln('  Component: $componentName ($componentType)');
    buffer.writeln('  Start: $startTime');
    if (endTime != null) {
      buffer.writeln('  End: $endTime');
      buffer.writeln('  Duration: ${duration?.inMilliseconds}ms');
    }
    if (error != null) {
      buffer.writeln('  Error: $error');
    }
    buffer.writeln('  Success: $isSuccess');
    return buffer.toString();
  }
}

/// Callback handler for collecting execution metrics
///
/// Tracks timing, success/failure, and other performance metrics
/// for component execution. Useful for monitoring and optimization.
///
/// Example:
/// ```dart
/// final handler = MetricsHandler();
///
/// final manager = CallbackManager([handler]);
/// final options = RunnableOptions(callbackManager: manager);
///
/// await runnable.invoke(input, options: options);
///
/// // Access collected metrics
/// for (final metric in handler.metrics) {
///   print('${metric.componentName}: ${metric.duration?.inMilliseconds}ms');
/// }
///
/// // Get summary
/// handler.printSummary();
/// ```
class MetricsHandler extends BaseCallbackHandler {
  MetricsHandler({this.autoLog = false});

  /// Whether to automatically log metrics on completion
  final bool autoLog;

  /// Context key for storing start time
  static const _startTimeKey = '_metrics_start_time';

  /// All collected metrics
  final List<ExecutionMetrics> metrics = [];

  /// Clear all collected metrics
  void clear() {
    metrics.clear();
  }

  /// Get metrics for a specific component
  List<ExecutionMetrics> getMetricsFor(String componentName) {
    return metrics.where((m) => m.componentName == componentName).toList();
  }

  /// Get average duration for a component
  Duration? getAverageDuration(String componentName) {
    final componentMetrics = getMetricsFor(componentName);
    if (componentMetrics.isEmpty) return null;

    final durations = componentMetrics
        .where((m) => m.duration != null)
        .map((m) => m.duration!)
        .toList();

    if (durations.isEmpty) return null;

    final totalMs = durations.fold<int>(
      0,
      (sum, duration) => sum + duration.inMilliseconds,
    );

    return Duration(milliseconds: totalMs ~/ durations.length);
  }

  /// Print summary of all metrics
  void printSummary() {
    print('=== Execution Metrics Summary ===');
    print('Total executions: ${metrics.length}');

    final successful = metrics.where((m) => m.isSuccess).length;
    final failed = metrics.where((m) => m.isFailed).length;

    print('Successful: $successful');
    print('Failed: $failed');

    if (metrics.isNotEmpty) {
      final avgDuration = Duration(
        milliseconds: metrics
                .where((m) => m.duration != null)
                .map((m) => m.duration!.inMilliseconds)
                .fold<int>(0, (sum, ms) => sum + ms) ~/
            metrics.length,
      );

      print('Average duration: ${avgDuration.inMilliseconds}ms');

      // Group by component
      final byComponent = <String, List<ExecutionMetrics>>{};
      for (final metric in metrics) {
        byComponent.putIfAbsent(metric.componentName, () => []).add(metric);
      }

      print('\nBy component:');
      for (final entry in byComponent.entries) {
        final componentMetrics = entry.value;
        final avgComponentDuration = getAverageDuration(entry.key);
        print(
          '  ${entry.key}: ${componentMetrics.length} calls, '
          'avg ${avgComponentDuration?.inMilliseconds ?? 0}ms',
        );
      }
    }

    print('================================');
  }

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    final startTime = DateTime.now();

    // Store start time in context
    final updatedContext = Map<String, dynamic>.from(context);
    updatedContext[_startTimeKey] = startTime;

    // Create initial metrics entry
    final metric = ExecutionMetrics(
      componentName: info.name,
      componentType: info.type,
      startTime: startTime,
      metadata: info.metadata,
    );

    // Store metric in context so we can update it later
    updatedContext['_current_metric'] = metric;

    return updatedContext;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    final endTime = DateTime.now();

    // Get the metric we created in onStart
    final metric = context['_current_metric'] as ExecutionMetrics?;

    if (metric != null) {
      metric.endTime = endTime;
      metrics.add(metric);

      if (autoLog) {
        print(
          '[Metrics] ${metric.componentName}: '
          '${metric.duration?.inMilliseconds}ms',
        );
      }
    }

    return context;
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    final endTime = DateTime.now();

    // Get the metric we created in onStart
    final metric = context['_current_metric'] as ExecutionMetrics?;

    if (metric != null) {
      metric.endTime = endTime;
      metric.error = error;
      metrics.add(metric);

      if (autoLog) {
        print(
          '[Metrics] ${metric.componentName} FAILED: '
          '${metric.duration?.inMilliseconds}ms - $error',
        );
      }
    }

    return context;
  }
}
