# Langfuse Integration Design for Threepio

**Framework Sources:**
- **Eino (CloudWeGo)**: Callback handler patterns, data models, batching mechanism
- **Langfuse**: Official API specification and data structures
- **LangChain**: Cost tracking and token usage patterns

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Threepio Application                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ ChatModel    │  │  Graph       │  │   Agent      │     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
│         │                  │                  │              │
│         └──────────────────┴──────────────────┘              │
│                             │                                │
│                             ▼                                │
│         ┌────────────────────────────────────┐              │
│         │  Threepio Callback Manager         │              │
│         └─────────────────┬──────────────────┘              │
│                           │                                  │
│                           ▼                                  │
│         ┌────────────────────────────────────┐              │
│         │  LangfuseCallbackHandler           │              │
│         │  - OnStart                         │              │
│         │  - OnEnd                           │              │
│         │  - OnError                         │              │
│         │  - Stream support                  │              │
│         └─────────────────┬──────────────────┘              │
│                           │                                  │
└───────────────────────────┼──────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│             Langfuse Client Library                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Event Queue & Batch Manager                         │  │
│  │  - Configurable flush interval                       │  │
│  │  - Configurable batch size                           │  │
│  │  - Background worker pool                            │  │
│  │  - Retry with exponential backoff                    │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│                         ▼                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  HTTP Client (dio)                                    │  │
│  │  - Basic Authentication                              │  │
│  │  - Batch ingestion endpoint                          │  │
│  │  - Request/response interceptors                     │  │
│  └──────────────────────┬───────────────────────────────┘  │
└────────────────────────┼────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Langfuse Cloud API  │
              │  /api/public/        │
              │  ingestion          │
              └──────────────────────┘
```

## Core Components

### 1. Data Models

**Based on Eino's event.go and Langfuse API spec**

```dart
/// Base event body for all Langfuse events
class LangfuseBaseEvent {
  final String? id;
  final String? name;
  final Map<String, dynamic>? metadata;
  final String? version;
}

/// Trace represents a complete workflow or request
class LangfuseTrace extends LangfuseBaseEvent {
  final DateTime timestamp;
  final String? userId;
  final String? sessionId;
  final String? release;
  final List<String>? tags;
  final bool public;
  final String? input;
  final String? output;
}

/// Base observation (parent of Span, Generation, Event)
class LangfuseBaseObservation extends LangfuseBaseEvent {
  final String traceId;
  final String? parentObservationId;
  final String? input;
  final String? output;
  final String? statusMessage;
  final LangfuseLevelType level;
  final DateTime startTime;
}

/// Span represents a unit of work within a trace
class LangfuseSpan extends LangfuseBaseObservation {
  final DateTime? endTime;
}

/// Generation represents an LLM generation
class LangfuseGeneration extends LangfuseBaseObservation {
  final List<Message>? inMessages;
  final Message? outMessage;
  final DateTime? endTime;
  final DateTime? completionStartTime;
  final String? model;
  final String? promptName;
  final int? promptVersion;
  final Map<String, dynamic>? modelParameters;
  final LangfuseUsage? usage;
}

/// Token usage tracking
class LangfuseUsage {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// Calculate cost based on provider pricing
  double calculateCost(ProviderPricing pricing);
}

/// Event represents discrete observations
class LangfuseEvent extends LangfuseBaseObservation {
  // Minimal structure for logging events
}

/// Event wrapper for batch ingestion
class LangfuseIngestionEvent {
  final String id;
  final LangfuseEventType type;
  final DateTime timestamp;
  final Map<String, String>? metadata;
  final dynamic body; // Trace, Span, Generation, or Event
}
```

### 2. Langfuse Client

**Based on Eino's langfuse.go**

```dart
/// Main Langfuse client interface
abstract class Langfuse {
  /// Create a new trace
  Future<String> createTrace(LangfuseTrace trace);

  /// Create a span within a trace
  Future<String> createSpan(LangfuseSpan span);

  /// End/update a span
  Future<void> endSpan(LangfuseSpan span);

  /// Create a generation observation
  Future<String> createGeneration(LangfuseGeneration generation);

  /// End/update a generation
  Future<void> endGeneration(LangfuseGeneration generation);

  /// Create an event
  Future<String> createEvent(LangfuseEvent event);

  /// Flush all pending events
  Future<void> flush();

  /// Dispose and cleanup resources
  Future<void> dispose();
}

/// Configuration for Langfuse client
class LangfuseConfig {
  /// Langfuse server URL (required)
  final String host;

  /// Public API key (required)
  final String publicKey;

  /// Secret API key (required)
  final String secretKey;

  /// Number of concurrent workers
  final int threads;

  /// HTTP request timeout
  final Duration? timeout;

  /// Maximum events to buffer
  final int maxTaskQueueSize;

  /// Number of events to batch before sending
  final int flushAt;

  /// How often to flush automatically
  final Duration flushInterval;

  /// Sampling rate (0.0 to 1.0)
  final double sampleRate;

  /// Maximum retry attempts
  final int maxRetry;

  /// Function to mask sensitive data
  final String Function(String)? maskFunc;

  /// Default trace configuration
  final String? defaultTraceName;
  final String? defaultUserId;
  final String? defaultSessionId;
  final String? defaultRelease;
  final List<String>? defaultTags;
}
```

### 3. Callback Handler

**Based on Eino's langfuse callback handler**

```dart
/// Langfuse callback handler for Threepio
class LangfuseCallbackHandler extends CallbackHandler {
  final Langfuse _client;
  final LangfuseConfig _config;

  @override
  Future<void> onStart(
    CallbackContext context,
    RunInfo info,
    CallbackInput input,
  ) async {
    // Get or initialize trace state from context
    final state = _getOrInitState(context, info);

    // For chat models, create Generation
    if (info.component == ComponentType.chatModel) {
      final modelInput = input as ChatModelInput;
      final generationId = await _client.createGeneration(
        LangfuseGeneration(
          name: info.name ?? info.component.name,
          traceId: state.traceId,
          parentObservationId: state.observationId,
          startTime: DateTime.now(),
          inMessages: modelInput.messages,
          model: modelInput.config?.model,
          modelParameters: modelInput.config?.toJson(),
          metadata: modelInput.extra,
        ),
      );

      // Update context with new observation ID
      context.setState(LangfuseState(
        traceId: state.traceId,
        observationId: generationId,
      ));
    } else {
      // For other components, create Span
      final spanId = await _client.createSpan(
        LangfuseSpan(
          name: info.name ?? info.component.name,
          traceId: state.traceId,
          parentObservationId: state.observationId,
          startTime: DateTime.now(),
          input: jsonEncode(input.toJson()),
        ),
      );

      context.setState(LangfuseState(
        traceId: state.traceId,
        observationId: spanId,
      ));
    }
  }

  @override
  Future<void> onEnd(
    CallbackContext context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    final state = context.getState<LangfuseState>();
    if (state == null) return;

    if (info.component == ComponentType.chatModel) {
      final modelOutput = output as ChatModelOutput;
      await _client.endGeneration(
        LangfuseGeneration(
          id: state.observationId,
          outMessage: modelOutput.message,
          endTime: DateTime.now(),
          completionStartTime: DateTime.now(),
          usage: modelOutput.tokenUsage != null
              ? LangfuseUsage(
                  promptTokens: modelOutput.tokenUsage!.promptTokens,
                  completionTokens: modelOutput.tokenUsage!.completionTokens,
                  totalTokens: modelOutput.tokenUsage!.totalTokens,
                )
              : null,
        ),
      );
    } else {
      await _client.endSpan(
        LangfuseSpan(
          id: state.observationId,
          output: jsonEncode(output.toJson()),
          endTime: DateTime.now(),
        ),
      );
    }
  }

  @override
  Future<void> onError(
    CallbackContext context,
    RunInfo info,
    Object error,
    StackTrace? stackTrace,
  ) async {
    final state = context.getState<LangfuseState>();
    if (state == null) return;

    if (info.component == ComponentType.chatModel) {
      await _client.endGeneration(
        LangfuseGeneration(
          id: state.observationId,
          level: LangfuseLevelType.error,
          outMessage: Message.assistant(error.toString()),
          endTime: DateTime.now(),
          completionStartTime: DateTime.now(),
        ),
      );
    } else {
      await _client.endSpan(
        LangfuseSpan(
          id: state.observationId,
          level: LangfuseLevelType.error,
          output: error.toString(),
          endTime: DateTime.now(),
        ),
      );
    }
  }
}

/// State stored in callback context
class LangfuseState {
  final String traceId;
  final String observationId;

  const LangfuseState({
    required this.traceId,
    required this.observationId,
  });
}
```

### 4. Cost Tracking

**Based on LangChain patterns and current pricing**

```dart
/// Provider-specific pricing information
class ProviderPricing {
  final String provider;
  final String model;
  final double inputCostPer1kTokens;
  final double outputCostPer1kTokens;

  /// Calculate total cost for given token usage
  double calculateCost({
    required int inputTokens,
    required int outputTokens,
  }) {
    final inputCost = (inputTokens / 1000) * inputCostPer1kTokens;
    final outputCost = (outputTokens / 1000) * outputCostPer1kTokens;
    return inputCost + outputCost;
  }
}

/// Pricing database for different providers
class ProviderPricingDatabase {
  static final Map<String, Map<String, ProviderPricing>> _pricing = {
    'openai': {
      'gpt-4': ProviderPricing(
        provider: 'openai',
        model: 'gpt-4',
        inputCostPer1kTokens: 0.03,
        outputCostPer1kTokens: 0.06,
      ),
      'gpt-4-turbo': ProviderPricing(
        provider: 'openai',
        model: 'gpt-4-turbo',
        inputCostPer1kTokens: 0.01,
        outputCostPer1kTokens: 0.03,
      ),
      'gpt-3.5-turbo': ProviderPricing(
        provider: 'openai',
        model: 'gpt-3.5-turbo',
        inputCostPer1kTokens: 0.0015,
        outputCostPer1kTokens: 0.002,
        ),
    },
    // Add more providers...
  };

  static ProviderPricing? get(String provider, String model) {
    return _pricing[provider]?[model];
  }
}

/// Usage analytics and reporting
class UsageAnalytics {
  int totalRequests = 0;
  int totalPromptTokens = 0;
  int totalCompletionTokens = 0;
  double totalCost = 0.0;

  final Map<String, int> requestsByModel = {};
  final Map<String, double> costByModel = {};

  void record({
    required String model,
    required int promptTokens,
    required int completionTokens,
    required double cost,
  }) {
    totalRequests++;
    totalPromptTokens += promptTokens;
    totalCompletionTokens += completionTokens;
    totalCost += cost;

    requestsByModel[model] = (requestsByModel[model] ?? 0) + 1;
    costByModel[model] = (costByModel[model] ?? 0.0) + cost;
  }

  Map<String, dynamic> toJson() => {
    'total_requests': totalRequests,
    'total_prompt_tokens': totalPromptTokens,
    'total_completion_tokens': totalCompletionTokens,
    'total_cost': totalCost,
    'requests_by_model': requestsByModel,
    'cost_by_model': costByModel,
  };
}
```

## Implementation Phases

### Phase 1: Data Models ✅ (Next)
- Create Langfuse event data models
- Implement JSON serialization
- Add validation

### Phase 2: HTTP Client
- Implement dio-based HTTP client
- Add Basic Authentication
- Implement batch ingestion endpoint

### Phase 3: Event Queue & Batching
- Create event queue
- Implement batch manager
- Add flush mechanism
- Implement retry logic

### Phase 4: Callback Handler
- Create LangfuseCallbackHandler
- Integrate with Threepio callbacks
- Implement context state management
- Add stream support

### Phase 5: Cost Tracking
- Create pricing database
- Implement cost calculator
- Add usage analytics

### Phase 6: Testing & Documentation
- Integration tests with real Langfuse API
- Unit tests for all components
- Update README
- Add examples

## Key Design Decisions

1. **Framework Sources**: Clearly labeled as Eino (callback patterns), Langfuse (API), LangChain (cost tracking)
2. **Async-First**: All operations use Dart's async/await
3. **Type-Safe**: Leverages Dart's type system
4. **Modular**: Each component can be used independently
5. **Production-Ready**: Includes retry, batching, and error handling
6. **Privacy**: Optional data masking function
7. **Performance**: Background batching and configurable flush intervals
