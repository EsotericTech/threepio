

# Graph Orchestration

Build complex, stateful workflows with branching logic, loops, and parallel execution using StateGraph.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
- [Building Graphs](#building-graphs)
- [Execution](#execution)
- [Advanced Patterns](#advanced-patterns)
- [Integration](#integration)
- [Best Practices](#best-practices)

## Overview

Graph Orchestration allows you to build sophisticated multi-step workflows where:
- State flows through nodes and gets transformed
- Decisions are made based on current state
- Multiple paths can be executed in parallel
- Loops and cycles are supported
- Execution can be checkpointed and resumed

### When to Use Graphs

**Use Graphs When:**
- You need conditional branching based on runtime state
- Your workflow has loops or cycles
- Multiple operations should run in parallel
- You need to retry or recover from failures
- The workflow is complex with many decision points

**Use Simple Chains When:**
- The workflow is purely linear (A → B → C)
- No conditional logic is needed
- No loops or parallel execution required

## Quick Start

Here's a simple graph that fetches data, processes it, and decides what to do next:

```dart
import 'package:threepio_core/threepio_core.dart';

// 1. Define your state
class DataState implements GraphState {
  const DataState({
    required this.query,
    this.data,
    this.processed = false,
    this.confidence = 0.0,
  });

  final String query;
  final String? data;
  final bool processed;
  final double confidence;

  @override
  DataState copyWith({
    String? query,
    String? data,
    bool? processed,
    double? confidence,
  }) {
    return DataState(
      query: query ?? this.query,
      data: data ?? this.data,
      processed: processed ?? this.processed,
      confidence: confidence ?? this.confidence,
    );
  }
}

// 2. Define node functions
Future<DataState> fetchNode(DataState state) async {
  final data = await fetchData(state.query);
  return state.copyWith(data: data);
}

Future<DataState> processNode(DataState state) async {
  // Process the data
  final confidence = calculateConfidence(state.data);
  return state.copyWith(
    processed: true,
    confidence: confidence,
  );
}

Future<DataState> respondNode(DataState state) async {
  // Generate response
  return state;
}

// 3. Build the graph
void main() async {
  final graph = StateGraph<DataState>()
    ..addNode('fetch', fetchNode)
    ..addNode('process', processNode)
    ..addNode('respond', respondNode)
    // Connect fetch to process
    ..addEdge('fetch', 'process')
    // Conditional: if confidence is low, fetch again
    ..addConditionalEdge('process', (state) {
      return state.confidence > 0.7 ? 'respond' : 'fetch';
    })
    // Set entry point
    ..setEntryPoint('fetch');

  // 4. Execute
  final result = await graph.invoke(
    DataState(query: 'What is Flutter?'),
  );

  print('Final state: ${result.state}');
  print('Path taken: ${result.path}');
}
```

## Core Concepts

### 1. GraphState

State flows through your graph and gets updated at each node. Your state should:
- Implement `GraphState`
- Be immutable
- Have a `copyWith` method

```dart
// Type-safe state with freezed (recommended)
@freezed
class MyState with _$MyState implements GraphState {
  const factory MyState({
    required String input,
    @Default([]) List<String> results,
    @Default(0) int attempts,
  }) = _MyState;
}

// Or implement manually
class MyState implements GraphState {
  const MyState({required this.input, this.results = const []});

  final String input;
  final List<String> results;

  @override
  MyState copyWith({String? input, List<String>? results}) {
    return MyState(
      input: input ?? this.input,
      results: results ?? this.results,
    );
  }
}

// Or use MapState for quick prototyping
final state = MapState({'count': 0, 'items': []});
final updated = state.set('count', 1);
```

### 2. Nodes

Nodes are functions that transform state:

```dart
// Sync node
DataState simpleNode(DataState state) {
  return state.copyWith(processed: true);
}

// Async node
Future<DataState> asyncNode(DataState state) async {
  final result = await someAsyncOperation();
  return state.copyWith(data: result);
}

// Add to graph
graph.addNode('process', asyncNode);
```

### 3. Edges

Edges connect nodes:

**Direct Edge** - Always goes to the same node:
```dart
graph.addEdge('nodeA', 'nodeB');
```

**Conditional Edge** - Routes based on state:
```dart
graph.addConditionalEdge('check', (state) {
  if (state.score > 0.8) return 'success';
  if (state.score > 0.5) return 'retry';
  return 'fail';
});
```

**Conditional Router** - Cleaner syntax for multiple conditions:
```dart
graph.addConditionalRouter(
  'classify',
  {
    'question': (state) => state.type == QueryType.question,
    'command': (state) => state.type == QueryType.command,
    'statement': (state) => state.type == QueryType.statement,
  },
  defaultRoute: 'unknown',
);
```

**Parallel Edge** - Execute multiple nodes concurrently:
```dart
graph.addParallelEdge(
  'fetch',
  ['process_text', 'extract_entities', 'analyze_sentiment'],
  merger: (original, results) {
    // Merge results from all parallel branches
    return original.copyWith(
      text: results[0].text,
      entities: results[1].entities,
      sentiment: results[2].sentiment,
    );
  },
);
```

### 4. Special Nodes

```dart
import 'package:threepio_core/threepio_core.dart';

// END - Terminates graph execution
graph.addEdge('final_node', END);

// START - Entry point (set with setEntryPoint)
graph.setEntryPoint('first_node');
```

## Building Graphs

### Declarative API

```dart
final graph = StateGraph<MyState>()
  ..addNode('step1', step1Func)
  ..addNode('step2', step2Func)
  ..addNode('step3', step3Func)
  ..addEdge('step1', 'step2')
  ..addEdge('step2', 'step3')
  ..addEdge('step3', END)
  ..setEntryPoint('step1');
```

### Fluent Builder API

```dart
final graph = GraphBuilder<MyState>()
  .withNode('start', startFunc)
  .withNode('process', processFunc)
  .withNode('end', endFunc)
  .connect('start', 'process')
  .routeIf(
    from: 'process',
    condition: (state) => state.isComplete,
    then: 'end',
    otherwise: 'start',
  )
  .startFrom('start')
  .build();
```

### Pre-built Patterns

```dart
// Linear graph: A → B → C
final graph = GraphPatterns.linear<MyState>([
  MapEntry('fetch', fetchNode),
  MapEntry('process', processNode),
  MapEntry('respond', respondNode),
]);

// Loop graph with condition
final graph = GraphPatterns.loop<MyState>(
  entryNode: 'fetch',
  nodes: [
    MapEntry('fetch', fetchNode),
    MapEntry('process', processNode),
    MapEntry('check', checkNode),
  ],
  shouldContinue: (state) => state.needsMoreData,
);

// Map-reduce pattern
final graph = GraphPatterns.mapReduce<MyState>(
  splitNode: 'split',
  splitFunction: splitData,
  mappers: [
    MapEntry('map1', mapper1),
    MapEntry('map2', mapper2),
    MapEntry('map3', mapper3),
  ],
  mergeNode: 'merge',
  mergeFunction: mergeResults,
);
```

## Execution

### Basic Execution

```dart
final result = await graph.invoke(initialState);

print('Final state: ${result.state}');
print('Path taken: ${result.path}');
print('Iterations: ${result.metadata['iterations']}');
```

### With Callbacks

```dart
final callbackManager = CallbackManager([
  LoggingHandler(),
  MetricsHandler(),
]);

final result = await graph.invoke(
  initialState,
  callbackManager: callbackManager,
);
```

### Error Handling

```dart
try {
  final result = await graph.invoke(initialState);
} on GraphExecutionException catch (e) {
  print('Graph failed at node: ${e.nodeName}');
  print('Cause: ${e.cause}');
} on StateError catch (e) {
  print('Infinite loop detected: $e');
}
```

### Preventing Infinite Loops

```dart
// Set maximum iterations (default: 100)
final graph = StateGraph<MyState>(maxIterations: 50);
```

## Advanced Patterns

### 1. Self-Correcting RAG

A RAG system that checks answer quality and retries if needed:

```dart
class RAGState implements GraphState {
  const RAGState({
    required this.question,
    this.documents = const [],
    this.answer = '',
    this.attempts = 0,
  });

  final String question;
  final List<Document> documents;
  final String answer;
  final int attempts;

  @override
  RAGState copyWith({
    String? question,
    List<Document>? documents,
    String? answer,
    int? attempts,
  }) {
    return RAGState(
      question: question ?? this.question,
      documents: documents ?? this.documents,
      answer: answer ?? this.answer,
      attempts: attempts ?? this.attempts,
    );
  }
}

Future<RAGState> retrieveNode(RAGState state) async {
  // Retrieve relevant documents
  final docs = await retriever.retrieve(state.question);
  return state.copyWith(
    documents: docs,
    attempts: state.attempts + 1,
  );
}

Future<RAGState> generateNode(RAGState state) async {
  // Generate answer from documents
  final answer = await generateAnswer(state.question, state.documents);
  return state.copyWith(answer: answer);
}

Future<RAGState> gradeNode(RAGState state) async {
  // Grade answer quality
  return state; // Quality checked in routing
}

void main() async {
  final graph = StateGraph<RAGState>(maxIterations: 5)
    ..addNode('retrieve', retrieveNode)
    ..addNode('generate', generateNode)
    ..addNode('grade', gradeNode)
    ..addEdge('retrieve', 'generate')
    ..addEdge('generate', 'grade')
    ..addConditionalRouter(
      'grade',
      {
        END: (state) => isGoodAnswer(state.answer) || state.attempts >= 3,
        'retrieve': (state) => !isGoodAnswer(state.answer) && state.attempts < 3,
      },
    )
    ..setEntryPoint('retrieve');

  final result = await graph.invoke(
    RAGState(question: 'What is Flutter?'),
  );
}
```

### 2. Multi-Agent Collaboration

Multiple agents working together on a task:

```dart
class ResearchState implements GraphState {
  const ResearchState({
    required this.query,
    this.webResults = const [],
    this.analysis = '',
    this.synthesis = '',
  });

  final String query;
  final List<String> webResults;
  final String analysis;
  final String synthesis;

  @override
  ResearchState copyWith({
    String? query,
    List<String>? webResults,
    String? analysis,
    String? synthesis,
  }) {
    return ResearchState(
      query: query ?? this.query,
      webResults: webResults ?? this.webResults,
      analysis: analysis ?? this.analysis,
      synthesis: synthesis ?? this.synthesis,
    );
  }
}

void main() async {
  final graph = StateGraph<ResearchState>()
    ..addNode('web_search', webSearchAgent)
    ..addNode('analyze', analysisAgent)
    ..addNode('synthesize', synthesisAgent)
    ..addEdge('web_search', 'analyze')
    ..addEdge('analyze', 'synthesize')
    ..addConditionalRouter(
      'synthesize',
      {
        END: (state) => state.webResults.length >= 5,
        'web_search': (state) => state.webResults.length < 5,
      },
    )
    ..setEntryPoint('web_search');

  final result = await graph.invoke(
    ResearchState(query: 'Latest AI developments'),
  );
}
```

### 3. Parallel Processing Pipeline

Process different aspects of data simultaneously:

```dart
class AnalysisState implements GraphState {
  const AnalysisState({
    required this.text,
    this.sentiment,
    this.entities,
    this.topics,
    this.summary,
  });

  final String text;
  final String? sentiment;
  final List<String>? entities;
  final List<String>? topics;
  final String? summary;

  @override
  AnalysisState copyWith({
    String? text,
    String? sentiment,
    List<String>? entities,
    List<String>? topics,
    String? summary,
  }) {
    return AnalysisState(
      text: text ?? this.text,
      sentiment: sentiment ?? this.sentiment,
      entities: entities ?? this.entities,
      topics: topics ?? this.topics,
      summary: summary ?? this.summary,
    );
  }
}

void main() async {
  final graph = StateGraph<AnalysisState>()
    ..addNode('sentiment', analyzeSentiment)
    ..addNode('entities', extractEntities)
    ..addNode('topics', extractTopics)
    ..addNode('summarize', summarizeAll)
    // Run sentiment, entities, and topics in parallel
    ..addParallelEdge(
      'START',
      ['sentiment', 'entities', 'topics'],
      merger: (original, results) {
        return original.copyWith(
          sentiment: results[0].sentiment,
          entities: results[1].entities,
          topics: results[2].topics,
        );
      },
    )
    ..addEdge('sentiment', 'summarize')
    ..addEdge('entities', 'summarize')
    ..addEdge('topics', 'summarize')
    ..setEntryPoint('START');

  final result = await graph.invoke(
    AnalysisState(text: 'Your long text here...'),
  );
}
```

### 4. Retry with Backoff

Retry failed operations with increasing delays:

```dart
class RetryState implements GraphState {
  const RetryState({
    required this.url,
    this.data,
    this.attempts = 0,
    this.lastError,
  });

  final String url;
  final String? data;
  final int attempts;
  final String? lastError;

  @override
  RetryState copyWith({
    String? url,
    String? data,
    int? attempts,
    String? lastError,
  }) {
    return RetryState(
      url: url ?? this.url,
      data: data ?? this.data,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
    );
  }
}

Future<RetryState> fetchNode(RetryState state) async {
  try {
    // Exponential backoff
    if (state.attempts > 0) {
      final delay = Duration(seconds: math.pow(2, state.attempts).toInt());
      await Future.delayed(delay);
    }

    final data = await http.get(state.url);
    return state.copyWith(data: data);
  } catch (e) {
    return state.copyWith(
      attempts: state.attempts + 1,
      lastError: e.toString(),
    );
  }
}

void main() async {
  final graph = StateGraph<RetryState>(maxIterations: 5)
    ..addNode('fetch', fetchNode)
    ..addConditionalRouter(
      'fetch',
      {
        END: (state) => state.data != null || state.attempts >= 3,
        'fetch': (state) => state.data == null && state.attempts < 3,
      },
    )
    ..setEntryPoint('fetch');

  final result = await graph.invoke(
    RetryState(url: 'https://api.example.com/data'),
  );
}
```

## Integration

### With Runnables

Convert graphs to Runnables for use in pipelines:

```dart
final graph = StateGraph<MyState>()
  // ... build graph
  ;

// Convert to Runnable
final runnable = graph.toRunnable();

// Use in a pipeline
final pipeline = someRunnable.pipe(runnable).pipe(anotherRunnable);

// Or batch process
final results = await runnable.batchParallel(inputs);
```

### Use Runnables as Nodes

```dart
final textProcessor = lambda<String, int>((text) async => text.length);

graph.addNode(
  'process',
  textProcessor.asNode<MyState>(
    getInput: (state) => state.text,
    setOutput: (state, length) => state.copyWith(length: length),
  ),
);
```

### With RAG Chains

```dart
final ragChain = RetrievalQAChain(
  retriever: retriever,
  chatModel: chatModel,
);

// Use as a node
graph.addNode('answer_question', (state) async {
  final result = await ragChain.invoke({'question': state.question});
  return state.copyWith(answer: result['answer']);
});
```

## Checkpointing

Save and resume graph execution:

```dart
// Create checkpoint store
final checkpoints = InMemoryCheckpointStore<MyState>();

// During execution, save checkpoints
graph.addNode('important_step', (state) async {
  // ... do work ...

  // Save checkpoint
  await checkpoints.save(
    'checkpoint_1',
    Checkpoint.now(
      state: state,
      currentNode: 'important_step',
      path: ['step1', 'step2', 'important_step'],
      iteration: 3,
    ),
  );

  return state;
});

// Later, resume from checkpoint
final checkpoint = await checkpoints.load('checkpoint_1');
if (checkpoint != null) {
  // Resume execution from this point
  // (requires custom logic to restart graph at specific node)
}
```

## Best Practices

### 1. Keep State Immutable

```dart
// Good - immutable state
class MyState implements GraphState {
  const MyState({required this.value});
  final int value;

  @override
  MyState copyWith({int? value}) => MyState(value: value ?? this.value);
}

// Bad - mutable state
class MyState implements GraphState {
  int value = 0; // Mutable!

  void increment() {
    value++; // Direct mutation!
  }
}
```

### 2. Use Typed State

```dart
// Good - type-safe state with compile-time checks
class MyState implements GraphState {
  const MyState({required this.count, required this.items});
  final int count;
  final List<String> items;
  // ... copyWith ...
}

// Acceptable - for prototyping only
final state = MapState({'count': 0, 'items': []});
```

### 3. Keep Nodes Focused

```dart
// Good - single responsibility
Future<MyState> fetchData(MyState state) async {
  final data = await http.get(state.url);
  return state.copyWith(data: data);
}

Future<MyState> processData(MyState state) async {
  final processed = await process(state.data);
  return state.copyWith(processed: processed);
}

// Bad - doing too much
Future<MyState> fetchAndProcess(MyState state) async {
  final data = await http.get(state.url);
  final processed = await process(data);
  final validated = await validate(processed);
  final stored = await store(validated);
  return state.copyWith(result: stored);
}
```

### 4. Handle Errors Gracefully

```dart
Future<MyState> robustNode(MyState state) async {
  try {
    final result = await riskyOperation();
    return state.copyWith(result: result);
  } catch (e) {
    // Store error in state instead of throwing
    return state.copyWith(
      error: e.toString(),
      attempts: state.attempts + 1,
    );
  }
}

// Then handle in routing
graph.addConditionalRouter(
  'robustNode',
  {
    'retry': (state) => state.error != null && state.attempts < 3,
    'fail': (state) => state.error != null && state.attempts >= 3,
    'continue': (state) => state.error == null,
  },
);
```

### 5. Limit Iterations

```dart
// Always set a reasonable max to prevent infinite loops
final graph = StateGraph<MyState>(
  maxIterations: 20, // Adjust based on your workflow
);
```

### 6. Visualize Your Graph

```dart
// Generate Mermaid diagram
final mermaid = graph.toMermaid();
print(mermaid);

// Output:
// graph TD
//     START(( ))
//     START --> fetch
//     fetch[fetch]
//     process[process]
//     respond[respond]
//     fetch --> process
//     process -->|?| ?
//     END(( ))
```

### 7. Test Nodes Independently

```dart
// Test nodes as pure functions
test('fetchNode retrieves data', () async {
  final initialState = MyState(query: 'test');
  final resultState = await fetchNode(initialState);

  expect(resultState.data, isNotNull);
});

// Test routing logic
test('routing sends low confidence to retry', () {
  final state = MyState(confidence: 0.3);
  final nextNode = routingLogic(state);

  expect(nextNode, equals('retry'));
});
```

---

## Summary

Graph Orchestration provides:

✅ **Type-safe state management** with Dart generics
✅ **Flexible routing** with conditional edges
✅ **Parallel execution** for concurrent operations
✅ **Loop support** for iterative workflows
✅ **Checkpointing** for long-running tasks
✅ **Runnable integration** for composability
✅ **Clean, declarative API** that's easy to understand

For more information:
- [Callbacks Documentation](./CALLBACKS.md) - Add observability to graphs
- [RAG Guide](./RAG.md) - Use graphs for advanced RAG patterns
- [Core Concepts](../README.md) - Understanding Runnables and Chains
