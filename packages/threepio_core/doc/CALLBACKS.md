# Callbacks & Observability

Threepio provides a sophisticated callback system (following the Eino pattern) that enables observability, debugging, and cross-cutting concerns across your LLM application.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
- [Built-in Handlers](#built-in-handlers)
- [Creating Custom Handlers](#creating-custom-handlers)
- [Real-World Examples](#real-world-examples)
- [Best Practices](#best-practices)

## Overview

The callback system provides hooks into component execution lifecycle:

- **OnStart** - Called when a component begins execution
- **OnEnd** - Called when execution completes successfully
- **OnError** - Called when an error occurs
- **OnStartWithStreamInput** - Called for streaming input components
- **OnEndWithStreamOutput** - Called for streaming output components

### Why Use Callbacks?

1. **Debugging** - Track execution flow and intermediate states
2. **Logging** - Record what's happening in production
3. **Metrics** - Collect performance data and timing
4. **Tracing** - Understand complex chain executions
5. **Monitoring** - Track errors and failures

## Quick Start

### Basic Logging

```dart
import 'package:threepio_core/src/callbacks/callback_manager.dart';
import 'package:threepio_core/src/callbacks/handlers/logging_handler.dart';

void main() async {
  // Create a logging handler
  final loggingHandler = LoggingHandler(verbose: true);

  // Create callback manager
  final callbackManager = CallbackManager([loggingHandler]);

  // Use with chains
  final options = RunnableOptions(callbackManager: callbackManager);

  final result = await chain.invoke(input, options: options);
  // Console output:
  // [Threepio] START: MyChain
  // [Threepio] END: MyChain
}
```

### Performance Metrics

```dart
import 'package:threepio_core/src/callbacks/handlers/metrics_handler.dart';

void main() async {
  final metricsHandler = MetricsHandler(autoLog: true);
  final callbackManager = CallbackManager([metricsHandler]);

  final options = RunnableOptions(callbackManager: callbackManager);

  // Run your chain
  await chain.invoke(input, options: options);

  // View metrics
  metricsHandler.printSummary();
  // === Execution Metrics Summary ===
  // Total executions: 1
  // Successful: 1
  // Failed: 0
  // Average duration: 245ms
  // ================================
}
```

### Execution Tracing

```dart
import 'package:threepio_core/src/callbacks/handlers/tracing_handler.dart';

void main() async {
  final tracingHandler = TracingHandler(captureData: true);
  final callbackManager = CallbackManager([tracingHandler]);

  final options = RunnableOptions(callbackManager: callbackManager);

  await chain.invoke(input, options: options);

  // View execution trace
  tracingHandler.printTrace();
  // === Execution Trace ===
  // [START] 2025-10-10T20:00:00 - SequentialChain (BaseChain)
  //   [START] 2025-10-10T20:00:01 - LLMChain (BaseChain)
  //   [END]   2025-10-10T20:00:03 - LLMChain
  // [END]   2025-10-10T20:00:03 - SequentialChain
  // =======================
}
```

## Core Concepts

### RunInfo - Component Metadata

Every callback receives `RunInfo` with 3-level component identification:

```dart
final runInfo = RunInfo(
  name: 'my_custom_chain',      // User-defined name
  type: 'LLMChain',              // Implementation type
  componentType: ComponentType.chain,  // Abstract category
  metadata: {
    'model': 'gpt-4',
    'temperature': 0.7,
  },
);
```

**Component Types:**
- `ComponentType.chatModel` - LLM/chat models
- `ComponentType.chain` - Processing chains
- `ComponentType.tool` - Tools and functions
- `ComponentType.retriever` - Document retrievers
- `ComponentType.embedder` - Text embedders
- `ComponentType.agent` - Autonomous agents
- `ComponentType.runnable` - Generic runnables

### CallbackHandler Interface

```dart
abstract class CallbackHandler {
  /// Called when component starts
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  );

  /// Called when component completes
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  );

  /// Called on error
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  );
}
```

**Context Threading:**

The `context` map is threaded through all callbacks, allowing handlers to store and retrieve request-level information:

```dart
@override
Future<Map<String, dynamic>> onStart(
  Map<String, dynamic> context,
  RunInfo info,
  CallbackInput input,
) async {
  // Store start time in context
  final updatedContext = Map<String, dynamic>.from(context);
  updatedContext['start_time'] = DateTime.now();
  updatedContext['request_id'] = uuid.v4();
  return updatedContext;
}

@override
Future<Map<String, dynamic>> onEnd(
  Map<String, dynamic> context,
  RunInfo info,
  CallbackOutput output,
) async {
  // Retrieve start time from context
  final startTime = context['start_time'] as DateTime;
  final duration = DateTime.now().difference(startTime);
  print('Request ${context['request_id']} took ${duration.inMilliseconds}ms');
  return context;
}
```

### CallbackManager

Orchestrates multiple handlers and provides convenience methods:

```dart
final manager = CallbackManager([
  LoggingHandler(),
  MetricsHandler(),
  TracingHandler(),
]);

// Add more handlers
manager.addHandler(CustomHandler());

// Global handlers (apply to all managers)
CallbackManager.addGlobalHandler(DebugHandler());

// Convenience wrapper for automatic callback handling
final result = await manager.runWithCallbacks(
  context,
  runInfo,
  input,
  () async {
    // Your component logic
    return await doSomething(input);
  },
);
```

## Built-in Handlers

### LoggingHandler

Simple console logging with configurable verbosity.

```dart
final handler = LoggingHandler(
  verbose: true,         // Log detailed information
  logInputs: true,       // Log input data
  logOutputs: true,      // Log output data
  prefix: '[MyApp]',     // Custom prefix
);
```

**Example Output:**
```
[MyApp] [2025-10-10T20:00:00] START: question_answerer (LLMChain)
  Component Type: ComponentType.chain
  Metadata: {model: gpt-4, temperature: 0.7}
  Input: {question: What is the capital of France?}
[MyApp] [2025-10-10T20:00:02] END: question_answerer
  Output: {answer: The capital of France is Paris.}
```

### MetricsHandler

Collects timing and performance metrics.

```dart
final handler = MetricsHandler(autoLog: true);

// After execution
handler.printSummary();
// === Execution Metrics Summary ===
// Total executions: 5
// Successful: 4
// Failed: 1
// Average duration: 342ms
//
// By component:
//   question_answerer: 2 calls, avg 450ms
//   summarizer: 2 calls, avg 300ms
//   router: 1 calls, avg 120ms
// ================================

// Get specific metrics
final metrics = handler.getMetricsFor('question_answerer');
for (final metric in metrics) {
  print('Duration: ${metric.duration?.inMilliseconds}ms');
  print('Success: ${metric.isSuccess}');
}

// Get average duration
final avgDuration = handler.getAverageDuration('question_answerer');
print('Average: ${avgDuration?.inMilliseconds}ms');
```

### TracingHandler

Detailed execution flow tracing with nesting depth tracking.

```dart
final handler = TracingHandler(
  captureData: true,    // Capture input/output data
  maxDepth: 10,         // Maximum nesting depth to track
);

// After execution
handler.printTrace();
// === Execution Trace ===
// [START] 2025-10-10T20:00:00 - content_analyzer (SequentialChain)
//   [START] 2025-10-10T20:00:00 - extract_keywords (LLMChain)
//   [END]   2025-10-10T20:00:02 - extract_keywords
//   [START] 2025-10-10T20:00:02 - categorize (LLMChain)
//   [END]   2025-10-10T20:00:04 - categorize
// [END]   2025-10-10T20:00:04 - content_analyzer
// =======================

// Get timeline
final timeline = handler.getTimeline();
for (final entry in timeline.entries) {
  print('${entry.key}: ${entry.value.inMilliseconds}ms');
}

// Print timeline
handler.printTimeline();
// === Execution Timeline ===
// content_analyzer: 4000ms
// extract_keywords: 2000ms
// categorize: 2000ms
// ==========================
```

## Creating Custom Handlers

### Simple Custom Handler

Extend `BaseCallbackHandler` and override only the methods you need:

```dart
import 'package:threepio_core/src/callbacks/callback_handler.dart';
import 'package:threepio_core/src/callbacks/run_info.dart';

class SimpleLogger extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    print('Starting ${info.name}...');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    print('Finished ${info.name}!');
    return context;
  }
}
```

### Advanced Custom Handler

Store metrics and expose query methods:

```dart
class CustomMetricsHandler extends BaseCallbackHandler {
  final List<ExecutionRecord> records = [];

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    final updatedContext = Map<String, dynamic>.from(context);
    updatedContext['_record_id'] = uuid.v4();
    updatedContext['_start_time'] = DateTime.now();

    return updatedContext;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    final recordId = context['_record_id'] as String;
    final startTime = context['_start_time'] as DateTime;
    final duration = DateTime.now().difference(startTime);

    records.add(ExecutionRecord(
      id: recordId,
      componentName: info.name,
      componentType: info.componentType,
      duration: duration,
      success: true,
      timestamp: startTime,
    ));

    return context;
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    final recordId = context['_record_id'] as String?;
    final startTime = context['_start_time'] as DateTime?;

    if (recordId != null && startTime != null) {
      records.add(ExecutionRecord(
        id: recordId,
        componentName: info.name,
        componentType: info.componentType,
        duration: DateTime.now().difference(startTime),
        success: false,
        error: error.toString(),
        timestamp: startTime,
      ));
    }

    return context;
  }

  // Query methods
  List<ExecutionRecord> getSlowExecutions(Duration threshold) {
    return records.where((r) => r.duration > threshold).toList();
  }

  Map<String, int> getErrorCounts() {
    final errorCounts = <String, int>{};
    for (final record in records.where((r) => !r.success)) {
      errorCounts[record.componentName] =
        (errorCounts[record.componentName] ?? 0) + 1;
    }
    return errorCounts;
  }
}
```

### Handler with External Service Integration

Send metrics to external monitoring service:

```dart
class DatadogHandler extends BaseCallbackHandler {
  final DatadogClient client;

  DatadogHandler(this.client);

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    // Send metric to Datadog
    await client.sendMetric(
      'threepio.component.execution',
      value: 1.0,
      tags: [
        'component:${info.name}',
        'type:${info.componentType}',
      ],
    );

    return context;
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    // Send error event
    await client.sendEvent(
      title: 'Threepio Component Error',
      text: 'Error in ${info.name}: $error',
      alertType: 'error',
      tags: [
        'component:${info.name}',
        'type:${info.componentType}',
      ],
    );

    return context;
  }
}
```

## Real-World Examples

### Example 1: Multi-Handler Setup

Combine multiple handlers for comprehensive observability:

```dart
void main() async {
  // Setup handlers
  final loggingHandler = LoggingHandler(verbose: false);
  final metricsHandler = MetricsHandler();
  final tracingHandler = TracingHandler();
  final datadogHandler = DatadogHandler(datadogClient);

  final callbackManager = CallbackManager([
    loggingHandler,
    metricsHandler,
    tracingHandler,
    datadogHandler,
  ]);

  // Use with chains
  final options = RunnableOptions(
    callbackManager: callbackManager,
    metadata: {
      'user_id': currentUser.id,
      'session_id': session.id,
    },
  );

  try {
    final result = await questionAnswerChain.invoke(
      {'question': userQuestion},
      options: options,
    );

    // Print metrics
    metricsHandler.printSummary();

    return result;
  } catch (e) {
    // Errors are already logged via callbacks
    rethrow;
  }
}
```

### Example 2: ChatModel with Callbacks

Track LLM API calls:

```dart
void main() async {
  final callbackManager = CallbackManager([
    MetricsHandler(autoLog: true),
    LoggingHandler(verbose: true),
  ]);

  final chatOptions = ChatModelOptions(
    model: 'gpt-4',
    temperature: 0.7,
    callbackManager: callbackManager,
    metadata: {
      'request_type': 'question_answering',
    },
  );

  final model = OpenAIChatModel(config: config);

  final response = await model.generate(
    [Message.user('What is the capital of France?')],
    options: chatOptions,
  );

  // Callbacks automatically logged:
  // [Threepio] START: OpenAIChatModel
  // [Metrics] OpenAIChatModel: 1.2s
  // [Threepio] END: OpenAIChatModel
}
```

### Example 3: Sequential Chain with Detailed Tracing

Track complex pipeline execution:

```dart
void main() async {
  final tracingHandler = TracingHandler(
    captureData: true,
    maxDepth: 10,
  );

  final callbackManager = CallbackManager([tracingHandler]);

  final pipeline = SequentialChain(
    chains: [
      extractKeywords,
      categorizeTopics,
      generateSummary,
    ],
  );

  final options = RunnableOptions(callbackManager: callbackManager);

  await pipeline.invoke({'article': longArticle}, options: options);

  // View detailed trace
  tracingHandler.printTrace();
  // Shows nested execution:
  // [START] SequentialChain
  //   [START] extractKeywords
  //   [END]   extractKeywords (1.2s)
  //   [START] categorizeTopics
  //   [END]   categorizeTopics (0.8s)
  //   [START] generateSummary
  //   [END]   generateSummary (1.5s)
  // [END]   SequentialChain (3.5s)

  // Get timeline
  tracingHandler.printTimeline();
}
```

### Example 4: Global Handlers for Application-Wide Monitoring

Set up global handlers once:

```dart
// app_initialization.dart
void initializeApp() {
  // Add global handlers
  CallbackManager.addGlobalHandler(
    LoggingHandler(verbose: false),
  );

  CallbackManager.addGlobalHandler(
    MetricsHandler(autoLog: true),
  );

  CallbackManager.addGlobalHandler(
    DatadogHandler(datadogClient),
  );

  // Now all CallbackManagers will include these handlers
}

// any_file.dart
void someFunction() async {
  // These handlers automatically included
  final callbackManager = CallbackManager([]);  // Empty, but has globals

  final options = RunnableOptions(callbackManager: callbackManager);
  await chain.invoke(input, options: options);
  // Global handlers will trigger
}
```

## Best Practices

### 1. Use Multiple Handlers

Combine handlers for different purposes:

```dart
// Good: Multiple handlers for different concerns
final callbackManager = CallbackManager([
  LoggingHandler(),      // For debugging
  MetricsHandler(),      // For performance
  DatadogHandler(),      // For monitoring
]);

// Bad: Trying to do everything in one handler
final callbackManager = CallbackManager([
  GodModeHandler(),  // Does logging, metrics, monitoring, everything
]);
```

### 2. Keep Handlers Lightweight

Callbacks shouldn't slow down execution:

```dart
// Good: Quick, non-blocking
class LightweightHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onEnd(...) async {
    // Log to queue for async processing
    eventQueue.add(event);
    return context;
  }
}

// Bad: Slow, blocking operations
class HeavyHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onEnd(...) async {
    // DON'T DO THIS - blocks execution
    await uploadToS3(largeData);
    await sendEmail(report);
    await updateDatabase(metrics);
    return context;
  }
}
```

### 3. Handle Errors Gracefully

Callback failures shouldn't break your application:

```dart
class RobustHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onEnd(...) async {
    try {
      await sendMetric(data);
    } catch (e) {
      // Log error but don't throw
      print('Metric sending failed: $e');
    }
    return context;
  }
}
```

### 4. Use Context for Request-Level Data

Thread request information through callbacks:

```dart
// Set context at start of request
final options = RunnableOptions(
  callbackManager: callbackManager,
  context: {
    'request_id': uuid.v4(),
    'user_id': currentUser.id,
    'timestamp': DateTime.now(),
  },
);

// Access in handlers
class RequestTracker extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onEnd(...) async {
    final requestId = context['request_id'];
    final userId = context['user_id'];
    print('Request $requestId by user $userId completed');
    return context;
  }
}
```

### 5. Clean Up Resources

If handlers hold resources, provide cleanup methods:

```dart
class ResourcefulHandler extends BaseCallbackHandler {
  final StreamController _controller;
  final Timer _flushTimer;

  ResourcefulHandler()
    : _controller = StreamController(),
      _flushTimer = Timer.periodic(Duration(seconds: 10), (_) => _flush());

  void dispose() {
    _controller.close();
    _flushTimer.cancel();
  }

  Future<void> _flush() async {
    // Flush buffered events
  }
}

// In your app
final handler = ResourcefulHandler();
try {
  // Use handler
  await runApplication();
} finally {
  handler.dispose();
}
```

### 6. Use Metadata for Component Configuration

Pass component-specific information via metadata:

```dart
final options = ChatModelOptions(
  callbackManager: callbackManager,
  metadata: {
    'model': 'gpt-4',
    'temperature': 0.7,
    'user_prompt_type': 'question',
    'expected_response_type': 'short_answer',
  },
);

// Access in handlers for filtering or routing
class SmartHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onEnd(...) async {
    final promptType = info.metadata?['user_prompt_type'];
    if (promptType == 'question') {
      // Handle questions differently
    }
    return context;
  }
}
```

### 7. Test Your Handlers

Write tests for custom handlers:

```dart
test('CustomHandler records executions', () async {
  final handler = CustomMetricsHandler();
  final manager = CallbackManager([handler]);

  final runInfo = RunInfo(
    name: 'test',
    type: 'Test',
    componentType: ComponentType.chain,
  );

  await manager.runWithCallbacks(
    {},
    runInfo,
    'input',
    () async => 'output',
  );

  expect(handler.records, hasLength(1));
  expect(handler.records.first.componentName, equals('test'));
  expect(handler.records.first.success, isTrue);
});
```

## Summary

The Threepio callback system provides:

- ✅ **Comprehensive lifecycle hooks** for all component executions
- ✅ **Multiple built-in handlers** for common use cases
- ✅ **Easy extensibility** with custom handlers
- ✅ **Context threading** for request-level data flow
- ✅ **Global handlers** for application-wide monitoring
- ✅ **Stream-aware** callbacks for streaming operations
- ✅ **Minimal performance impact** when handlers are lightweight

Use callbacks to gain deep visibility into your LLM application's behavior, debug complex chains, collect metrics, and integrate with monitoring services.
