# Threepio Core - New Features Documentation

This documentation covers the new features added to Threepio Core, providing comprehensive examples and usage patterns for each component.

## Table of Contents

1. [Gemini Chat Model Provider](#1-gemini-chat-model-provider)
2. [Agent Development Kit (ADK)](#2-agent-development-kit-adk)
3. [Checkpoint & Resume System](#3-checkpoint--resume-system)
4. [Advanced Retrieval Patterns](#4-advanced-retrieval-patterns)
5. [Document Processing Pipeline](#5-document-processing-pipeline)
6. [Reranking System](#6-reranking-system)
7. [Advanced Text Splitters](#7-advanced-text-splitters)

---

## 1. Gemini Chat Model Provider

The Gemini provider enables integration with Google's Gemini API, supporting text generation, multimodal input/output, streaming, and tool calling.

### Configuration

```dart
import 'package:threepio_core/threepio_core.dart';

// Basic configuration
final config = GeminiConfig(
  apiKey: 'your-api-key',
  defaultModel: 'gemini-2.5-flash', // Default model
  timeout: const Duration(seconds: 120),
);

// Or load from environment variables (GEMINI_API_KEY or GOOGLE_API_KEY)
final configFromEnv = GeminiConfig.fromEnvironment();

// Create the chat model
final model = GeminiChatModel(config: config);
```

### Available Models

| Model | Best For |
|-------|----------|
| `gemini-2.5-flash` | Default - best price/performance |
| `gemini-2.5-pro` | Complex reasoning, STEM tasks |
| `gemini-3-flash-preview` | Latest speed-optimized |
| `gemini-3-pro-preview` | Latest quality-optimized |
| `gemini-2.5-flash-image` | Image generation |
| `gemini-3-pro-image-preview` | Professional image generation |

### Basic Text Generation

```dart
final model = GeminiChatModel(config: config);

// Simple generation
final messages = [
  Message.user('What is the capital of France?'),
];

final response = await model.generate(messages);
print(response.content); // "The capital of France is Paris."

// With system message
final messagesWithSystem = [
  Message.system('You are a helpful geography expert. Be concise.'),
  Message.user('What is the capital of France?'),
];

final response2 = await model.generate(messagesWithSystem);
print(response2.content); // "Paris"
```

### Generation Options

```dart
final response = await model.generate(
  messages,
  options: ChatModelOptions(
    model: 'gemini-2.5-pro',    // Override default model
    temperature: 0.7,           // Creativity (0.0 - 2.0)
    maxTokens: 1024,            // Maximum output tokens
    topP: 0.95,                 // Nucleus sampling
    stop: ['END'],              // Stop sequences
    extra: {
      'topK': 40,               // Top-K sampling
      'safetySettings': [       // Content filtering
        {
          'category': 'HARM_CATEGORY_HARASSMENT',
          'threshold': 'BLOCK_MEDIUM_AND_ABOVE',
        },
      ],
    },
  ),
);

// Access token usage
print('Prompt tokens: ${response.responseMeta?.usage?.promptTokens}');
print('Completion tokens: ${response.responseMeta?.usage?.completionTokens}');
```

### Streaming Responses

```dart
final reader = await model.stream([
  Message.user('Write a short story about a robot.'),
]);

// Process chunks as they arrive
try {
  while (true) {
    final chunk = await reader.recv();
    stdout.write(chunk.content); // Print each chunk
  }
} on StreamEOFException {
  // Stream complete
}
await reader.close();
```

### Multimodal Input (Images, Audio, Video)

```dart
// Image from base64
final response = await model.generate([
  Message(
    role: RoleType.user,
    userInputMultiContent: [
      MessageInputPart.text('What is in this image?'),
      MessageInputPart.imageUrl(
        'data:image/jpeg;base64,/9j/4AAQSkZJRg...',
      ),
    ],
  ),
]);

// Image from URL
final response2 = await model.generate([
  Message(
    role: RoleType.user,
    userInputMultiContent: [
      MessageInputPart.text('Describe this image'),
      MessageInputPart.imageUrl('https://example.com/image.jpg'),
    ],
  ),
]);

// Audio input
final audioResponse = await model.generate([
  Message(
    role: RoleType.user,
    userInputMultiContent: [
      MessageInputPart.text('Transcribe this audio'),
      MessageInputPart.audioUrl('data:audio/mp3;base64,...'),
    ],
  ),
]);

// Video input
final videoResponse = await model.generate([
  Message(
    role: RoleType.user,
    userInputMultiContent: [
      MessageInputPart.text('What happens in this video?'),
      MessageInputPart.videoUrl('https://example.com/video.mp4'),
    ],
  ),
]);
```

### Image Generation

```dart
// Use an image generation model
final imageModel = GeminiChatModel(
  config: GeminiConfig(
    apiKey: apiKey,
    defaultModel: 'gemini-2.5-flash-image',
  ),
);

final response = await imageModel.generate(
  [Message.user('Generate an image of a red circle on white background')],
  options: const ChatModelOptions(
    extra: {
      'responseModalities': ['TEXT', 'IMAGE'], // Enable image output
    },
  ),
);

// Access generated image
if (response.assistantGenMultiContent != null) {
  for (final part in response.assistantGenMultiContent!) {
    if (part.type == ChatMessagePartType.imageUrl) {
      final dataUrl = part.image?.url; // data:image/png;base64,...
      // Decode and save the image
      final base64Data = dataUrl!.split(',')[1];
      final bytes = base64Decode(base64Data);
      await File('output.png').writeAsBytes(bytes);
    }
  }
}
```

### Tool/Function Calling

```dart
// Define tools
final weatherTool = ToolInfo.simple(
  name: 'get_weather',
  description: 'Get the current weather for a location',
  properties: {
    'location': JSONSchemaProperty.string(
      description: 'City name, e.g., "San Francisco"',
    ),
    'unit': JSONSchemaProperty.string(
      description: 'Temperature unit',
      enumValues: ['celsius', 'fahrenheit'],
    ),
  },
  required: ['location'],
);

// Bind tools to model
final modelWithTools = model.withTools([weatherTool]);

// Generate - model may request tool calls
final response = await modelWithTools.generate([
  Message.user('What is the weather in Tokyo?'),
]);

// Check if model wants to call tools
if (response.toolCalls != null && response.toolCalls!.isNotEmpty) {
  for (final toolCall in response.toolCalls!) {
    print('Tool: ${toolCall.function.name}');
    print('Arguments: ${toolCall.function.arguments}');

    // Execute the tool (your implementation)
    final result = await executeWeatherTool(
      jsonDecode(toolCall.function.arguments),
    );

    // Continue conversation with tool result
    final finalResponse = await modelWithTools.generate([
      Message.user('What is the weather in Tokyo?'),
      response, // Assistant message with tool calls
      Message(
        role: RoleType.tool,
        content: jsonEncode(result),
        toolCallId: toolCall.id,
        toolName: toolCall.function.name,
      ),
    ]);

    print(finalResponse.content);
  }
}
```

### Tool Choice Control

```dart
// Force tool use
final response = await modelWithTools.generate(
  messages,
  options: ChatModelOptions(
    toolChoice: ToolChoice.forced, // Must use a tool
  ),
);

// Allow but don't require tools
final response2 = await modelWithTools.generate(
  messages,
  options: ChatModelOptions(
    toolChoice: ToolChoice.allowed, // AUTO - model decides
  ),
);

// Disable tools
final response3 = await modelWithTools.generate(
  messages,
  options: ChatModelOptions(
    toolChoice: ToolChoice.forbidden, // NONE - no tool use
  ),
);
```

### Using with Agent (ReAct Pattern)

```dart
// Create a tool that can be executed
class CalculatorTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.simple(
    name: 'calculate',
    description: 'Perform arithmetic calculations',
    properties: {
      'expression': JSONSchemaProperty.string(
        description: 'Math expression like "5 + 3"',
      ),
    },
    required: ['expression'],
  );

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final expr = args['expression'] as String;
    // Parse and evaluate expression
    final result = evaluateExpression(expr);
    return result.toString();
  }
}

// Create agent
final registry = ToolRegistry();
registry.register(CalculatorTool());

final agent = Agent(
  model: model,
  toolRegistry: registry,
  config: AgentConfig(
    maxIterations: 10,
    maxToolCalls: 20,
  ),
);

// Run agent
final response = await agent.run([
  Message.system('You are a helpful assistant with a calculator.'),
  Message.user('What is 25 * 4?'),
]);

print(response.content); // "25 multiplied by 4 is 100."
```

### Error Handling

```dart
try {
  final response = await model.generate(messages);
} on GeminiException catch (e) {
  print('API Error: ${e.message}');
  print('Status Code: ${e.statusCode}');
  print('Error Code: ${e.code}');
  print('Status: ${e.status}');

  // Handle rate limiting
  if (e.statusCode == 429) {
    // Wait and retry
  }
} on GeminiParseException catch (e) {
  // Response parsing error
  if (e.blockReason != null) {
    print('Content blocked: ${e.blockReason}');
  }
}
```

---

## 2. Agent Development Kit (ADK)

The ADK provides a framework for building sophisticated AI agents with different architectures: ReAct, Plan-Execute, Supervisor, and Workflow patterns.

### ChatModelAgent (ReAct Pattern)

The simplest agent type that reasons and acts in a loop.

```dart
import 'package:threepio_core/threepio_core.dart';

// Create a tool class
class SearchTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.simple(
    name: 'search',
    description: 'Search the web for information',
    properties: {
      'query': JSONSchemaProperty.string(description: 'Search query'),
    },
    required: ['query'],
  );

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final query = args['query'] as String;
    return await performSearch(query);
  }
}

// Create tool registry and register tools
final registry = ToolRegistry();
registry.register(SearchTool());

// Create agent
final agent = ChatModelAgent(
  name: 'research-agent',
  description: 'An agent that researches topics',
  model: geminiModel,
  toolRegistry: registry,
  systemPrompt: 'You are a helpful research assistant.',
  config: const ChatModelAgentConfig(
    maxIterations: 10,
    maxToolCalls: 50,
    emitPartialOutputs: true,
  ),
);

// Run with event streaming
final reader = await agent.run([
  Message.user('Research the latest developments in quantum computing'),
]);

try {
  while (true) {
    final event = await reader.recv();
    switch (event) {
      case AgentRunStartEvent():
        print('Agent started');
      case AgentActionEvent(action: final action):
        if (action is ToolCallAction) {
          print('Calling tool: ${action.toolName}');
        }
      case ToolResultEvent(result: final result):
        print('Tool result: $result');
      case AgentOutputEvent(message: final message, isPartial: final isPartial):
        if (!isPartial) {
          print('Final answer: ${message.content}');
        } else {
          stdout.write(message.content); // Partial output
        }
      case AgentErrorEvent(error: final error):
        print('Error: $error');
      case AgentRunEndEvent():
        print('Agent completed');
    }
  }
} on StreamEOFException {
  // Stream complete
}
await reader.close();

// Or get final result directly
final result = await agent.invoke([
  Message.user('What is 2 + 2?'),
]);
print(result.content);
```

### PlanExecuteAgent

Creates a plan first, then executes each step.

```dart
final planAgent = PlanExecuteAgent(
  name: 'plan-execute-agent',
  model: geminiModel,
  plannerModel: geminiModel, // Can use a different model for planning
  executors: {
    'search': searchAgent,
    'analyze': analyzeAgent,
    'summarize': summaryAgent,
  },
  plannerSystemPrompt: '''
You are a planning agent. Create step-by-step plans to accomplish tasks.
Available executors: search, analyze, summarize
''',
  config: PlanExecuteConfig(
    maxReplanAttempts: 3,
    replanOnError: true,
    replanOnFeedback: true,
    maxStepsPerPlan: 10,
  ),
);

final events = planAgent.run([
  Message.user('Research and summarize the top 3 AI trends of 2024'),
]);

await for (final event in events) {
  if (event is AgentStateUpdateEvent) {
    final plan = event.state['currentPlan'] as ExecutionPlan?;
    if (plan != null) {
      print('Plan created with ${plan.steps.length} steps:');
      for (final step in plan.steps) {
        print('  - ${step.description} (executor: ${step.executorName})');
      }
    }
  }
}
```

### SupervisorAgent

Delegates tasks to worker agents.

```dart
// Create tool registries for workers
final researchRegistry = ToolRegistry();
researchRegistry.register(SearchTool());

final emptyRegistry = ToolRegistry(); // For agents without tools

// Create worker agents
final researchWorker = ChatModelAgent(
  name: 'researcher',
  description: 'A research specialist',
  model: geminiModel,
  toolRegistry: researchRegistry,
  systemPrompt: 'You are a research specialist.',
);

final writerWorker = ChatModelAgent(
  name: 'writer',
  description: 'A professional writer',
  model: geminiModel,
  toolRegistry: emptyRegistry,
  systemPrompt: 'You are a professional writer.',
);

// Create supervisor
final supervisor = SupervisorAgent(
  name: 'project-manager',
  model: geminiModel,
  workers: {
    'researcher': researchWorker,
    'writer': writerWorker,
  },
  systemPrompt: '''
You are a project manager. Delegate tasks to your team:
- researcher: for finding information
- writer: for creating content
''',
  config: SupervisorConfig(
    maxDelegations: 10,
    allowDirectResponse: true,
    trackHistory: true,
  ),
);

final result = await supervisor.invoke([
  Message.user('Create a blog post about renewable energy'),
]);
```

### WorkflowAgent

Orchestrates a fixed sequence of steps.

```dart
final workflow = WorkflowAgent(
  name: 'content-pipeline',
  steps: [
    WorkflowStep(
      name: 'research',
      agent: researchAgent,
      inputTransform: (input) => [
        Message.user('Research: ${input.last.content}'),
      ],
    ),
    WorkflowStep(
      name: 'outline',
      agent: outlineAgent,
      inputTransform: (input) => [
        Message.user('Create outline from: ${input.last.content}'),
      ],
    ),
    WorkflowStep(
      name: 'write',
      agent: writerAgent,
      condition: (state) => state['outline'] != null,
    ),
    WorkflowStep(
      name: 'review',
      agent: reviewAgent,
    ),
  ],
  config: WorkflowConfig(
    mode: WorkflowMode.sequential,
    stopOnFirstError: false,
  ),
);

// Execute workflow
final events = workflow.run([
  Message.user('Write an article about climate change'),
]);
```

### Parallel Workflow

```dart
final parallelWorkflow = WorkflowAgent(
  name: 'parallel-research',
  steps: [
    WorkflowStep(name: 'search-web', agent: webSearchAgent),
    WorkflowStep(name: 'search-papers', agent: paperSearchAgent),
    WorkflowStep(name: 'search-news', agent: newsSearchAgent),
  ],
  config: WorkflowConfig(
    mode: WorkflowMode.parallel,
    parallelLimit: 3, // Max concurrent executions
  ),
);
```

### Loop Workflow

```dart
final iterativeWorkflow = WorkflowAgent(
  name: 'refinement-loop',
  steps: [
    WorkflowStep(name: 'generate', agent: generatorAgent),
    WorkflowStep(name: 'evaluate', agent: evaluatorAgent),
    WorkflowStep(name: 'refine', agent: refinerAgent),
  ],
  config: WorkflowConfig(
    mode: WorkflowMode.loop,
    maxLoopIterations: 5,
    loopCondition: (state) {
      final score = state['quality_score'] as double?;
      return score == null || score < 0.9; // Continue if score < 90%
    },
  ),
);
```

### Wrapping Agents as Tools

```dart
// Create a specialized agent
final factChecker = ChatModelAgent(
  name: 'fact-checker',
  model: geminiModel,
  systemPrompt: 'You verify facts and return true/false with explanation.',
);

// Wrap as a tool
final factCheckTool = factChecker.asTool(
  name: 'verify_fact',
  description: 'Verify if a statement is factually correct',
  inputParameter: 'statement',
);

// Use in another agent
final mainAgent = ChatModelAgent(
  name: 'assistant',
  model: geminiModel,
  tools: [factCheckTool, searchTool],
);
```

### Agent Run Context

```dart
final context = AgentRunContext(
  runId: 'run-123',
  maxIterations: 20,
  timeout: Duration(minutes: 5),
  metadata: {'user_id': 'user-456'},
  onEvent: (event) {
    // Log all events
    print('Event: ${event.eventType}');
  },
  shouldCancel: () {
    // Check for cancellation
    return userCancelledRequest;
  },
);

final events = agent.run(messages, context: context);
```

### Error Handling

```dart
try {
  final result = await agent.invoke(messages);
} on MaxIterationsExceededException catch (e) {
  print('Agent hit iteration limit: ${e.maxIterations}');
} on ToolExecutionException catch (e) {
  print('Tool "${e.toolName}" failed: ${e.message}');
} on AgentTimeoutException catch (e) {
  print('Agent timed out after ${e.timeout}');
} on AgentCancelledException {
  print('Agent was cancelled');
} on PlanningException catch (e) {
  print('Planning failed: ${e.message}');
}
```

---

## 3. Checkpoint & Resume System

The checkpoint system enables saving and resuming graph execution state, supporting human-in-the-loop workflows and error recovery.

### Basic Checkpoint Configuration

```dart
import 'package:threepio_core/threepio_core.dart';

// Configure checkpointing
final checkpointConfig = CheckpointConfig(
  interruptBefore: ['human_review'],  // Pause before these nodes
  interruptAfter: ['generate_report'], // Pause after these nodes
  checkpointEveryNode: true,          // Save after each step
  checkpointOnError: true,            // Save on errors
  autoSave: true,                     // Auto-save to store
);

// Create checkpoint store
final store = InMemoryCheckpointStore<MyState>();

// Or use file-based persistence
final fileStore = FileCheckpointStore<MyState>(
  directory: '/path/to/checkpoints',
  config: CheckpointStoreConfig(
    maxCheckpointsPerThread: 100,
    ttl: Duration(days: 7),
    compressData: true,
  ),
);
```

### Creating a Checkpointable Graph

```dart
// Define your state
class WorkflowState extends GraphState {
  final String? document;
  final String? analysis;
  final String? review;
  final bool approved;

  WorkflowState({
    this.document,
    this.analysis,
    this.review,
    this.approved = false,
  });

  @override
  WorkflowState copyWith({
    String? document,
    String? analysis,
    String? review,
    bool? approved,
  }) => WorkflowState(
    document: document ?? this.document,
    analysis: analysis ?? this.analysis,
    review: review ?? this.review,
    approved: approved ?? this.approved,
  );

  @override
  Map<String, dynamic> toMap() => {
    'document': document,
    'analysis': analysis,
    'review': review,
    'approved': approved,
  };

  static WorkflowState fromMap(Map<String, dynamic> map) => WorkflowState(
    document: map['document'],
    analysis: map['analysis'],
    review: map['review'],
    approved: map['approved'] ?? false,
  );
}

// Create graph with checkpointing
final graph = StateGraph<WorkflowState>(
  checkpointConfig: CheckpointConfig(
    interruptBefore: ['human_review'],
    autoSave: true,
  ),
  checkpointStore: store,
);

// Add nodes
graph.addNode('generate', (state) async {
  final doc = await generateDocument();
  return state.copyWith(document: doc);
});

graph.addNode('analyze', (state) async {
  final analysis = await analyzeDocument(state.document!);
  return state.copyWith(analysis: analysis);
});

graph.addNode('human_review', (state) async {
  // This node will pause for human input
  return state;
});

graph.addNode('finalize', (state) async {
  if (state.approved) {
    return state.copyWith(review: 'Approved and finalized');
  }
  return state.copyWith(review: 'Rejected');
});

// Add edges
graph.addEdge('generate', 'analyze');
graph.addEdge('analyze', 'human_review');
graph.addConditionalEdge(
  'human_review',
  (state) => state.approved ? 'finalize' : 'generate',
);
graph.addEdge('finalize', END); // Use END constant

graph.setEntryPoint('generate');
```

### Executing with Checkpoints

```dart
// Start execution
final initialState = WorkflowState();
final threadId = 'user-123-workflow-1';

try {
  final result = await graph.invoke(
    initialState,
    threadId: threadId,
  );
} on GraphInterruptException<WorkflowState> catch (e) {
  // Execution paused at checkpoint
  print('Paused at: ${e.checkpoint.currentNode}');
  print('Checkpoint ID: ${e.checkpoint.id}');
  print('Reason: ${e.reason}');

  // Save checkpoint ID for later
  await saveCheckpointForUser(e.checkpoint.id!, threadId);
}
```

### Resuming from Checkpoint

```dart
// Load checkpoint
final checkpoint = await store.loadLatest(threadId: threadId);

if (checkpoint != null) {
  // Resume execution using the checkpoint ID
  // Note: State modification during resume requires using HumanInputNode
  final result = await graph.invoke(
    initialState, // State is loaded from checkpoint
    threadId: threadId,
    checkpointId: checkpoint.id,
  );

  print('Workflow completed: ${result.state.review}');
}
```

### Human-in-the-Loop Pattern

```dart
// Define a human input node
graph.addNode('get_approval', (state) async {
  // This will be interrupted, and the state will be updated
  // with human input when resumed
  return state;
});

// Configure interrupt
final config = CheckpointConfig(
  interruptBefore: ['get_approval'],
);

// In your API handler
Future<void> handleWorkflowStart(String userId) async {
  try {
    await graph.invoke(initialState, threadId: userId);
  } on GraphInterruptException<WorkflowState> catch (e) {
    // Send notification to user for approval
    await notifyUserForApproval(userId, e.checkpoint.id!);
  }
}

Future<void> handleUserApproval(String userId, bool approved) async {
  // For state modification during resume, use the HumanInputNode pattern
  // or manually update the checkpoint state before resuming
  final checkpoint = await store.loadLatest(threadId: userId);

  // Resume from checkpoint
  final result = await graph.invoke(
    initialState,
    threadId: userId,
    checkpointId: checkpoint!.id,
  );
}
```

### Checkpoint History and Management

```dart
// List all checkpoints for a thread
final checkpoints = await store.list(threadId: 'user-123');
for (final metadata in checkpoints) {
  print('${metadata.id}: ${metadata.currentNode} at ${metadata.timestamp}');
}

// Get checkpoint history
final history = await store.getHistory(
  threadId: 'user-123',
  limit: 10,
  after: DateTime.now().subtract(Duration(hours: 1)),
);

// Delete old checkpoints
await store.delete(oldCheckpointId, threadId: 'user-123');

// Clear all checkpoints for a thread
await store.clear(threadId: 'user-123');

// Count checkpoints
final count = await store.count(threadId: 'user-123');
```

### Custom State Serialization

```dart
// For complex states, implement custom serialization
class CheckpointSerializer<S extends GraphState> {
  Map<String, dynamic> serialize(Checkpoint<S> checkpoint) {
    return {
      'id': checkpoint.id,
      'threadId': checkpoint.threadId,
      'state': checkpoint.state.toMap(),
      'currentNode': checkpoint.currentNode,
      'path': checkpoint.path,
      'iteration': checkpoint.iteration,
      'timestamp': checkpoint.timestamp.toIso8601String(),
      'metadata': checkpoint.metadata,
    };
  }

  Checkpoint<S> deserialize(
    Map<String, dynamic> data,
    S Function(Map<String, dynamic>) stateFromMap,
  ) {
    return Checkpoint(
      id: data['id'],
      threadId: data['threadId'],
      state: stateFromMap(data['state']),
      currentNode: data['currentNode'],
      path: List<String>.from(data['path']),
      iteration: data['iteration'],
      timestamp: DateTime.parse(data['timestamp']),
      metadata: Map<String, dynamic>.from(data['metadata'] ?? {}),
    );
  }
}
```

---

## 4. Advanced Retrieval Patterns

### HybridRetriever

Combines semantic (vector) and keyword (BM25) search.

```dart
import 'package:threepio_core/threepio_core.dart';

// Create vector retriever
final vectorRetriever = VectorRetriever(
  embedder: openAIEmbedder,
  vectorStore: vectorStore,
);

// Create keyword searcher
final keywordSearcher = InMemoryBM25Searcher(
  k1: 1.5,  // Term frequency saturation
  b: 0.75,  // Length normalization
);

// Index documents for keyword search
await keywordSearcher.addDocuments(documents);

// Create hybrid retriever
final hybridRetriever = HybridRetriever(
  vectorRetriever: vectorRetriever,
  keywordSearcher: keywordSearcher,
  vectorWeight: 0.7,    // 70% semantic
  keywordWeight: 0.3,   // 30% keyword
  normalizeScores: true,
  deduplicationStrategy: IdDeduplication(),
);

// Retrieve
final results = await hybridRetriever.retrieve(
  'machine learning algorithms',
  options: RetrieverOptions(topK: 10),
);

// With detailed scores
final scoredResults = await hybridRetriever.retrieveWithScores(
  'machine learning algorithms',
);

for (final result in scoredResults) {
  print('${result.document.content}');
  print('  Vector score: ${result.metadata['vector_score']}');
  print('  Keyword score: ${result.metadata['keyword_score']}');
  print('  Combined: ${result.score}');
}
```

### MultiQueryRetriever

Generates query variants for better recall.

```dart
final multiQueryRetriever = MultiQueryRetriever(
  baseRetriever: vectorRetriever,
  chatModel: geminiModel,
  numQueries: 3,
  includeOriginalQuery: true,
  queryGenerationPrompt: '''
Generate {num_queries} different versions of the following question
to help find relevant documents. Return one query per line.

Original question: {question}

Alternative queries:
''',
);

// The retriever will:
// 1. Generate 3 alternative queries using the LLM
// 2. Run all queries (including original) against the base retriever
// 3. Fuse results using Reciprocal Rank Fusion

final results = await multiQueryRetriever.retrieve(
  'What are the benefits of renewable energy?',
  options: RetrieverOptions(topK: 10),
);

// Access generated queries
final metadata = await multiQueryRetriever.retrieveWithScores(query);
print('Generated queries: ${metadata.first.metadata['generated_queries']}');
```

### ParentRetriever

Searches chunks but returns full parent documents.

```dart
// Create parent document store
final parentStore = InMemoryParentDocumentStore();

// Index documents with their chunks
for (final document in documents) {
  // Split into chunks
  final chunks = await splitter.splitDocuments([document]);

  // Store parent-child relationship
  await parentStore.storeWithChildren(document, chunks);

  // Add chunks to vector store (for searching)
  await vectorStore.addDocuments(chunks);
}

// Create parent retriever
final parentRetriever = ParentRetriever(
  baseRetriever: vectorRetriever,
  parentStore: parentStore,
  returnChunks: false,           // Return parents, not chunks
  includeChunkMetadata: true,    // Add chunk info to parent
  deduplicateParents: true,      // Remove duplicate parents
  parentScoreStrategy: ParentScoreStrategy.maxChildScore,
);

final results = await parentRetriever.retrieve('specific detail');

// Results contain full parent documents, even though
// the search matched specific chunks
for (final doc in results) {
  print('Parent: ${doc.id}');
  print('Matched chunks: ${doc.metadata['matched_chunks_count']}');
}
```

### RouterRetriever

Routes queries to specialized retrievers.

```dart
// Create specialized retrievers
final technicalRetriever = VectorRetriever(
  vectorStore: technicalDocsStore,
  embedder: embedder,
);

final hrRetriever = VectorRetriever(
  vectorStore: hrDocsStore,
  embedder: embedder,
);

final legalRetriever = VectorRetriever(
  vectorStore: legalDocsStore,
  embedder: embedder,
);

// Create routing strategy
final routingStrategy = KeywordRoutingStrategy(
  routeKeywords: {
    'technical': ['code', 'api', 'programming', 'bug', 'feature'],
    'hr': ['vacation', 'salary', 'benefits', 'leave', 'policy'],
    'legal': ['contract', 'agreement', 'liability', 'compliance'],
  },
  matchThreshold: 1,
);

// Or use LLM-based routing
final llmRoutingStrategy = LLMRoutingStrategy(
  chatModel: geminiModel,
  routeDescriptions: {
    'technical': 'Technical documentation and API references',
    'hr': 'Human resources policies and employee information',
    'legal': 'Legal documents, contracts, and compliance',
  },
  allowMultiple: true,
);

// Create router retriever
final routerRetriever = RouterRetriever(
  routes: {
    'technical': technicalRetriever,
    'hr': hrRetriever,
    'legal': legalRetriever,
  },
  routingStrategy: llmRoutingStrategy,
  fallbackRetriever: generalRetriever,
  allowMultipleRoutes: true,
  maxRoutes: 2,
);

final results = await routerRetriever.retrieve(
  'What is the vacation policy for engineering contractors?',
);

// Query routed to both 'hr' and potentially 'technical'
```

### Result Fusion Strategies

```dart
// Reciprocal Rank Fusion (default)
final rrfFusion = ReciprocalRankFusion(k: 60.0);

// Weighted Score Fusion
final weightedFusion = WeightedScoreFusion(
  weights: [0.6, 0.4],  // Weights for each result set
  normalizeScores: true,
);

// Union Fusion (combine all unique documents)
final unionFusion = UnionFusion(
  keepHighestScore: true,
);

// Use with hybrid retriever
final retriever = HybridRetriever(
  vectorRetriever: vectorRetriever,
  keywordSearcher: keywordSearcher,
  fusionStrategy: rrfFusion,
);
```

### Deduplication Strategies

```dart
// By document ID
final idDedup = IdDeduplication(
  useContentHashAsFallback: true,
);

// By content
final contentDedup = ContentDeduplication(
  normalizeWhitespace: true,
  caseSensitive: false,
);

// By custom key
final keyDedup = KeyDeduplication<String>(
  keyExtractor: (doc) => doc.metadata['source'] as String?,
);

// Composite (apply multiple strategies)
final compositeDedup = CompositeDeduplication([
  IdDeduplication(),
  ContentDeduplication(),
]);
```

---

## 5. Document Processing Pipeline

### Ingestion Pipeline

End-to-end document processing from loading to vector storage.

```dart
import 'package:threepio_core/threepio_core.dart';

// Create pipeline components
final loader = DirectoryLoader(
  path: '/path/to/documents',
  recursive: true,
  extensions: ['.html', '.md', '.txt'],
);

final htmlParser = HtmlParser(
  removeScripts: true,
  removeStyles: true,
  preserveLinks: true,
);

final markdownParser = MarkdownParser(
  parseFrontmatter: true,
  extractCodeBlocks: true,
);

final splitter = RecursiveCharacterTextSplitter(
  chunkSize: 1000,
  chunkOverlap: 200,
);

// Create pipeline
final pipeline = IngestionPipeline(
  loader: loader,
  parser: htmlParser,  // Or use a parser registry
  splitter: splitter,
  embedder: geminiEmbedder,
  vectorStore: vectorStore,
  transformers: [
    // Clean content
    ContentCleanerTransformer(
      trimWhitespace: true,
      normalizeNewlines: true,
      removeEmptyLines: true,
    ),
    // Add metadata
    MetadataTransformer(metadata: {
      'ingested_at': DateTime.now().toIso8601String(),
      'source': 'documentation',
    }),
    // Filter documents
    FilterTransformer(
      predicate: (doc) => doc.content.length > 50,
    ),
  ],
);

// Run ingestion
final result = await pipeline.ingest(
  options: IngestionOptions(
    batchSize: 100,
    continueOnError: true,
    deduplicateByContent: true,
    maxDocuments: 1000,
  ),
);

print('Processed: ${result.documentsProcessed} documents');
print('Created: ${result.chunksCreated} chunks');
print('Stored: ${result.chunksStored} chunks');
print('Duration: ${result.duration}');

if (result.errors.isNotEmpty) {
  for (final error in result.errors) {
    print('Error in ${error.stage}: ${error.message}');
  }
}
```

### Streaming Ingestion with Progress

```dart
final progressStream = pipeline.ingestStream(
  options: IngestionOptions(batchSize: 50),
);

await for (final progress in progressStream) {
  print('${progress.stage}: ${progress.current}/${progress.total}');
  print('  ${progress.message}');
  print('  Progress: ${progress.percentage.toStringAsFixed(1)}%');

  if (progress.stage == IngestionStage.complete) {
    final result = progress.metadata['result'] as IngestionResult;
    print('Ingestion complete!');
  }
}
```

### Document Parsers

```dart
// HTML Parser
final htmlParser = HtmlParser(
  removeScripts: true,
  removeStyles: true,
  removeComments: true,
  preserveLinks: true,
  preserveLineBreaks: true,
);

final htmlResult = await htmlParser.parseString(htmlContent);
print('Title: ${htmlResult.metadata['title']}');
print('Content: ${htmlResult.document.content}');

// With table extraction
final htmlParserWithTables = HtmlParser(
  extractTables: true,
);
final result = await htmlParserWithTables.parseString(htmlWithTables);
for (final table in result.extractedTables ?? []) {
  print('Table: ${table.caption}');
  print(table.toMarkdown());
}

// Markdown Parser
final mdParser = MarkdownParser(
  parseFrontmatter: true,
  removeFrontmatter: true,
  extractCodeBlocks: true,
);

final mdContent = '''
---
title: My Document
author: John Doe
tags: [dart, flutter]
---

# Introduction

This is the content.

```dart
void main() {
  print('Hello');
}
```
''';

final mdResult = await mdParser.parseString(mdContent);
print('Title: ${mdResult.metadata['title']}');
print('Author: ${mdResult.metadata['author']}');
print('Code blocks: ${mdResult.metadata['code_blocks']}');
```

### Custom Document Transformer

```dart
class SummarizationTransformer implements DocumentTransformer {
  final BaseChatModel model;

  SummarizationTransformer({required this.model});

  @override
  Future<List<Document>> transform(List<Document> documents) async {
    final transformed = <Document>[];

    for (final doc in documents) {
      // Generate summary
      final response = await model.generate([
        Message.system('Summarize the following text in 2-3 sentences.'),
        Message.user(doc.content),
      ]);

      transformed.add(doc.copyWith(
        metadata: {
          ...doc.metadata,
          'summary': response.content,
        },
      ));
    }

    return transformed;
  }
}

// Use in pipeline
final pipeline = IngestionPipeline(
  // ... other components
  transformers: [
    SummarizationTransformer(model: geminiModel),
  ],
);
```

---

## 6. Reranking System

### Basic Reranking

```dart
import 'package:threepio_core/threepio_core.dart';

// Retrieve documents
final documents = await retriever.retrieve(query);

// Rerank by existing scores
final scoreReranker = ScoreReranker(
  normalize: true,
  defaultScore: 0.0,
);

final reranked = await scoreReranker.rerank(
  query,
  documents,
  options: RerankerOptions(topK: 5),
);

for (final result in reranked) {
  print('${result.document.content}: ${result.score}');
}
```

### Custom Scoring Function

```dart
final functionReranker = FunctionReranker(
  scorer: (query, document) async {
    // Custom relevance scoring
    final queryTerms = query.toLowerCase().split(' ');
    final docTerms = document.content.toLowerCase().split(' ');

    int matches = 0;
    for (final term in queryTerms) {
      if (docTerms.contains(term)) matches++;
    }

    return matches / queryTerms.length;
  },
);

final results = await functionReranker.rerank(query, documents);
```

### MMR Reranking (Diversity)

Maximal Marginal Relevance balances relevance and diversity.

```dart
final mmrReranker = MMRReranker(
  embedder: geminiEmbedder,
  lambda: 0.7,  // 0.0 = max diversity, 1.0 = max relevance
);

// Returns documents that are both relevant AND diverse
final diverseResults = await mmrReranker.rerank(
  query,
  documents,
  options: RerankerOptions(topK: 10),
);

// With pre-computed embeddings (faster)
final precomputedReranker = PrecomputedMMRReranker(
  queryEmbedding: await embedder.embedStrings([query]).then((e) => e.first),
  lambda: 0.7,
);
```

### Composite Reranking

Combine multiple reranking strategies.

```dart
final compositeReranker = CompositeReranker(
  rerankers: [
    ScoreReranker(normalize: true),      // Use retrieval scores
    functionReranker,                     // Custom scoring
    MMRReranker(embedder: embedder),     // Diversity
  ],
  weights: [0.4, 0.3, 0.3],  // Must sum to 1.0
);

final results = await compositeReranker.rerank(
  query,
  documents,
  options: RerankerOptions(
    topK: 10,
    threshold: 0.5,  // Minimum score
  ),
);
```

### Cross-Encoder Reranking (with LLM)

```dart
class LLMReranker extends BaseReranker {
  final BaseChatModel model;

  LLMReranker({required this.model});

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    final results = <RerankResult>[];

    for (int i = 0; i < documents.length; i++) {
      final doc = documents[i];

      // Ask LLM to score relevance
      final response = await model.generate([
        Message.system('''
Rate the relevance of the document to the query on a scale of 0-10.
Return only the number.
'''),
        Message.user('''
Query: $query

Document: ${doc.content}
'''),
      ]);

      final score = double.tryParse(response.content.trim()) ?? 0;

      results.add(RerankResult(
        document: doc,
        score: score / 10,  // Normalize to 0-1
        originalIndex: i,
      ));
    }

    return sortByScore(results);
  }
}
```

---

## 7. Advanced Text Splitters

### HTML Splitter

Preserves HTML document structure when splitting.

```dart
import 'package:threepio_core/threepio_core.dart';

final htmlSplitter = HtmlSplitter(
  chunkSize: 1000,
  chunkOverlap: 200,
  stripTags: true,          // Remove HTML tags from output
  preserveLinks: true,      // Keep URLs
  splitByHeaders: true,     // Split at header boundaries
  headerTags: ['h1', 'h2', 'h3'],  // Header levels to split on
);

final htmlContent = '''
<html>
<head><title>Documentation</title></head>
<body>
  <h1>Introduction</h1>
  <p>This is the introduction section with lots of content...</p>

  <h2>Getting Started</h2>
  <p>Here's how to get started...</p>

  <h2>Advanced Usage</h2>
  <p>For advanced users...</p>
</body>
</html>
''';

final chunks = await htmlSplitter.splitText(htmlContent);

for (final chunk in chunks) {
  print('--- Chunk ---');
  print(chunk);
  print('');
}

// Split documents with metadata preservation
final documents = [
  Document(content: htmlContent, metadata: {'source': 'docs.html'}),
];

final splitDocs = await htmlSplitter.splitDocuments(documents);
for (final doc in splitDocs) {
  print('Source: ${doc.metadata['source']}');
  print('Chunk index: ${doc.metadata['chunk_index']}');
}
```

### Markdown Splitter

Preserves Markdown structure and handles code blocks.

```dart
final mdSplitter = MarkdownSplitter(
  chunkSize: 1000,
  chunkOverlap: 200,
  preserveCodeBlocks: true,   // Keep code blocks intact
  splitOnHeaders: true,       // Split at header boundaries
  minHeaderLevel: 1,          // Start splitting at h1
  maxHeaderLevel: 3,          // Don't split below h3
);

final markdownContent = '''
# Main Title

Introduction paragraph.

## Section 1

Content for section 1.

### Subsection 1.1

More detailed content.

```python
def example():
    return "This code block stays together"
```

## Section 2

Content for section 2.
''';

final chunks = await mdSplitter.splitText(markdownContent);
```

### Markdown RAG Splitter

Optimized for RAG with header breadcrumbs.

```dart
final ragSplitter = MarkdownRAGSplitter(
  chunkSize: 500,
  chunkOverlap: 100,
  includeHeadersInChunks: true,   // Prepend headers to chunks
  addHeaderBreadcrumbs: true,     // Track header hierarchy
);

final chunks = await ragSplitter.splitDocuments([
  Document(content: markdownContent),
]);

for (final chunk in chunks) {
  print('Headers: ${chunk.metadata['header_breadcrumbs']}');
  print('Current: ${chunk.metadata['current_header']}');
  print('Content: ${chunk.content}');
  print('');
}

// Output:
// Headers: [Main Title, Section 1, Subsection 1.1]
// Current: Subsection 1.1
// Content: # Main Title > Section 1 > Subsection 1.1
//
// More detailed content...
```

### Combining Splitters with Pipeline

```dart
// Create parser-aware splitting
Document splitByType(Document doc) async {
  final extension = doc.metadata['extension'] as String?;

  TextSplitter splitter;
  if (extension == '.html' || extension == '.htm') {
    splitter = HtmlSplitter(chunkSize: 1000);
  } else if (extension == '.md') {
    splitter = MarkdownRAGSplitter(chunkSize: 1000);
  } else {
    splitter = RecursiveCharacterTextSplitter(chunkSize: 1000);
  }

  return await splitter.splitDocuments([doc]);
}

// In pipeline
final pipeline = IngestionPipeline(
  splitter: MarkdownRAGSplitter(
    chunkSize: 500,
    includeHeadersInChunks: true,
  ),
  // ... other components
);
```

---

## Complete RAG Application Example

```dart
import 'package:threepio_core/threepio_core.dart';

Future<void> main() async {
  // 1. Configure providers
  final geminiConfig = GeminiConfig(
    apiKey: Platform.environment['GEMINI_API_KEY']!,
    defaultModel: 'gemini-2.5-flash',
  );

  final model = GeminiChatModel(config: geminiConfig);
  final embedder = OpenAIEmbedder(config: openAIConfig);
  final vectorStore = InMemoryVectorStore();

  // 2. Create ingestion pipeline
  final pipeline = IngestionPipeline(
    loader: DirectoryLoader(path: './docs', extensions: ['.md']),
    parser: MarkdownParser(parseFrontmatter: true),
    splitter: MarkdownRAGSplitter(
      chunkSize: 500,
      includeHeadersInChunks: true,
    ),
    embedder: embedder,
    vectorStore: vectorStore,
    transformers: [
      ContentCleanerTransformer(),
      MetadataTransformer(metadata: {'indexed_at': DateTime.now().toIso8601String()}),
    ],
  );

  // 3. Ingest documents
  print('Ingesting documents...');
  final ingestResult = await pipeline.ingest();
  print('Indexed ${ingestResult.chunksStored} chunks');

  // 4. Create retriever with reranking
  final baseRetriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
  );

  final keywordSearcher = InMemoryBM25Searcher();
  // Index for keyword search too
  final docs = await vectorStore.getAllDocuments();
  await keywordSearcher.addDocuments(docs);

  final hybridRetriever = HybridRetriever(
    vectorRetriever: baseRetriever,
    keywordSearcher: keywordSearcher,
    vectorWeight: 0.7,
    keywordWeight: 0.3,
  );

  final reranker = MMRReranker(
    embedder: embedder,
    lambda: 0.8,
  );

  // 5. Create RAG agent
  final ragTool = InvokableTool.fromFunction(
    name: 'search_knowledge',
    description: 'Search the knowledge base for relevant information',
    parameters: {
      'query': JSONSchemaProperty.string(description: 'Search query'),
    },
    handler: (args) async {
      final query = args['query'] as String;

      // Retrieve
      final docs = await hybridRetriever.retrieve(
        query,
        options: RetrieverOptions(topK: 10),
      );

      // Rerank
      final reranked = await reranker.rerank(
        query,
        docs,
        options: RerankerOptions(topK: 5),
      );

      // Format results
      final results = reranked.map((r) =>
        '${r.document.metadata['current_header'] ?? 'Document'}:\n${r.document.content}'
      ).join('\n\n---\n\n');

      return results;
    },
  );

  final agent = ChatModelAgent(
    name: 'rag-assistant',
    model: model,
    tools: [ragTool],
    systemPrompt: '''
You are a helpful assistant with access to a knowledge base.
Use the search_knowledge tool to find relevant information before answering questions.
Always cite your sources.
''',
  );

  // 6. Run conversation
  print('\nRAG Assistant ready. Type your questions:');

  while (true) {
    stdout.write('\nYou: ');
    final input = stdin.readLineSync();
    if (input == null || input.isEmpty) break;

    print('\nAssistant: ');
    final events = agent.run([Message.user(input)]);

    await for (final event in events) {
      if (event is AgentOutputEvent && event.isFinal) {
        print(event.output.content);
      }
    }
  }
}
```

---

## Migration Guide

If upgrading from a previous version:

1. **Gemini Provider**: New feature, no migration needed
2. **ADK Agents**: New feature, no migration needed
3. **Checkpoint System**: New feature, no migration needed
4. **Advanced Retrievers**: New feature, no migration needed
5. **Document Pipeline**: New feature, no migration needed
6. **Rerankers**: New feature, no migration needed
7. **Text Splitters**: `HtmlSplitter` and `MarkdownSplitter` extend existing `TextSplitter`

---

## Best Practices

1. **Use streaming** for long-running operations to provide user feedback
2. **Configure checkpoints** for any workflow that may need human intervention
3. **Combine retrieval strategies** (hybrid + reranking) for better results
4. **Use appropriate splitters** for your content type (HTML, Markdown, etc.)
5. **Monitor token usage** to optimize costs
6. **Handle errors gracefully** with try-catch and fallback strategies
7. **Use agents** for complex multi-step tasks that require reasoning
