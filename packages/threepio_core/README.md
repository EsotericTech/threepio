# Threepio

A Flutter/Dart port of the Eino LLM application development framework. Threepio provides a clean, modular architecture for building AI-powered applications with support for multiple LLM providers, tool calling, and the ReAct (Reasoning + Acting) pattern.

## Features

- **Multiple LLM Providers** - Supports OpenAI (GPT-4, GPT-4o-mini) and OpenRouter (Gemini, Claude, Llama, DALL-E, and 100+ models)
- **Runnables & Lambdas** - Core Eino-inspired abstraction for composable components
- **Graph Orchestration** - Complex multi-step workflows with conditional routing, loops, and parallel execution
- **Memory & Persistence** - Conversation history management with multiple strategies (buffer, window, token-limited, LLM-summarization) and pluggable storage backends
- **Structured Output Parsing** - Parse and validate LLM outputs with JSON schema validation, auto-retry, and type-safe transformations (inspired by LangChain, OpenAI, Instructor)
- **Callbacks & Observability** - Comprehensive lifecycle hooks for debugging and monitoring
- **RAG (Retrieval-Augmented Generation)** - Complete RAG pipeline with embedders, vector stores, retrievers, loaders, and splitters
- **Tool Calling** - Define and execute custom tools with automatic schema conversion
- **Agent Framework** - Built-in ReAct pattern for autonomous reasoning and action
- **Streaming Support** - Real-time response streaming for better UX
- **Prompt Templates & Chains** - Composable templates and processing pipelines
- **Modular Design** - Clean separation of concerns with composable components
- **Idiomatic Dart** - Follows Flutter/Dart best practices and patterns

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  threepio_core:
    path: packages/threepio_core
```

## Quick Start

### Basic Chat Completion

```dart
import 'package:threepio_core/src/components/model/providers/openai/openai_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_config.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() async {
  // Configure OpenAI
  final config = OpenAIConfig(
    apiKey: 'your-api-key-here',
    defaultModel: 'gpt-4o-mini',
  );

  // Create chat model
  final model = OpenAIChatModel(config: config);

  // Send a message
  final messages = [
    Message.user('What is the capital of France?'),
  ];

  final response = await model.generate(messages);
  print(response.content); // "The capital of France is Paris."
}
```

### Streaming Responses

```dart
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() async {
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final model = OpenAIChatModel(config: config);

  final messages = [
    Message.user('Write a short poem about coding.'),
  ];

  // Stream the response
  final reader = await model.stream(messages);

  try {
    while (true) {
      final chunk = await reader.recv();
      print(chunk.content); // Print each chunk as it arrives
    }
  } on StreamEOFException {
    // Stream complete
  }

  await reader.close();
}
```

### Multi-Turn Conversations

```dart
void main() async {
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final model = OpenAIChatModel(config: config);

  final conversationHistory = <Message>[
    Message.user('My name is Alice.'),
  ];

  // First exchange
  var response = await model.generate(conversationHistory);
  print('Assistant: ${response.content}');
  conversationHistory.add(response);

  // Continue conversation
  conversationHistory.add(Message.user('What is my name?'));
  response = await model.generate(conversationHistory);
  print('Assistant: ${response.content}'); // "Your name is Alice."
}
```

## Using OpenRouter

OpenRouter provides access to 100+ LLM models through a single API, including Gemini, Claude, Llama, and image generation models. Threepio's OpenRouter provider supports all these models with both text and image generation.

### Why a Separate OpenRouter Provider?

While OpenRouter uses an OpenAI-compatible API, it routes to many different underlying models (Gemini, Claude, Llama, etc.), and **each model can return responses in slightly different formats**. This is especially true for multi-modal responses like image generation.

**Key Differences from OpenAI Provider:**

1. **Multi-Modal Response Handling**: OpenRouter's image generation models (like Gemini 2.5 Flash Image) return images in a structured `images` field, separate from the `content` field. The OpenAI provider expects everything in `content`.

2. **Flexible Response Parsing**: The OpenRouter parser automatically detects and handles:
   - Structured image responses (Gemini format with separate `images` field)
   - Inline base64 image data (raw base64 strings in `content`)
   - Standard text responses (OpenAI-compatible format)

3. **Provider-Specific Headers**: OpenRouter supports optional `siteName` and `siteUrl` headers for tracking and analytics.

**What This Means for You:**

When you use `OpenRouterChatModel` for image generation, the generated images are automatically extracted and placed in the `assistantGenMultiContent` field of the response Message, regardless of which underlying model format was used. You don't need to worry about the parsing details—it just works across all 100+ models.

```dart
// This works seamlessly across different image models:
final response = await model.generate(
  [Message.user('Generate an image')],
  options: const ChatModelOptions(model: 'google/gemini-2.5-flash-image'),
);

// Images are always in the same place:
final imagePart = response.assistantGenMultiContent!.first;
```

### Text Generation with OpenRouter

```dart
import 'package:threepio_core/src/components/model/providers/openrouter/openrouter_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/openrouter/openrouter_config.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() async {
  // Configure OpenRouter
  final config = OpenRouterConfig(
    apiKey: 'your-openrouter-api-key',
    siteName: 'My App', // Optional: for tracking
    siteUrl: 'https://myapp.com', // Optional: for analytics
  );

  final model = OpenRouterChatModel(config: config);

  // Use any model from OpenRouter's catalog
  final messages = [Message.user('Explain quantum computing in one sentence.')];

  // Try Gemini
  var response = await model.generate(
    messages,
    options: const ChatModelOptions(model: 'google/gemini-2.5-flash'),
  );
  print('Gemini: ${response.content}');

  // Or Claude
  response = await model.generate(
    messages,
    options: const ChatModelOptions(model: 'anthropic/claude-3.5-sonnet'),
  );
  print('Claude: ${response.content}');

  // Or Llama
  response = await model.generate(
    messages,
    options: const ChatModelOptions(model: 'meta-llama/llama-3.1-70b-instruct'),
  );
  print('Llama: ${response.content}');
}
```

### Image Generation with OpenRouter

OpenRouter supports image generation models like Gemini 2.5 Flash Image. Generated images are returned in the `assistantGenMultiContent` field as base64-encoded data URLs.

```dart
import 'package:threepio_core/src/components/model/chat_model_options.dart';

void main() async {
  final config = OpenRouterConfig(apiKey: 'your-api-key');
  final model = OpenRouterChatModel(config: config);

  final messages = [
    Message.user('Generate a beautiful sunset over mountains'),
  ];

  // Generate image with Gemini 2.5 Flash Image
  final response = await model.generate(
    messages,
    options: const ChatModelOptions(
      model: 'google/gemini-2.5-flash-image',
      maxTokens: 4096,
    ),
  );

  // Extract image from multi-content response
  if (response.assistantGenMultiContent != null) {
    final imagePart = response.assistantGenMultiContent!.firstWhere(
      (part) => part.type == ChatMessagePartType.imageUrl,
    );

    if (imagePart.image?.url != null) {
      // imagePart.image.url contains the data URL (data:image/png;base64,...)
      final imageDataUrl = imagePart.image!.url!;
      print('Image generated: ${imageDataUrl.length} characters');

      // Display in Flutter:
      // Image.memory(base64Decode(imageDataUrl.split(',')[1]))
    }
  }
}
```

### Streaming with OpenRouter

```dart
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() async {
  final config = OpenRouterConfig(apiKey: 'your-api-key');
  final model = OpenRouterChatModel(config: config);

  final messages = [Message.user('Write a haiku about programming')];

  final reader = await model.stream(
    messages,
    options: const ChatModelOptions(model: 'google/gemini-2.5-flash'),
  );

  try {
    while (true) {
      final chunk = await reader.recv();
      print(chunk.content); // Stream each word as it arrives
    }
  } on StreamEOFException {
    // Stream complete
  } finally {
    await reader.close();
  }
}
```

## Tool Calling

Define custom tools that the model can call:

### Creating a Custom Tool

```dart
import 'dart:convert';
import 'package:threepio_core/src/components/tool/invokable_tool.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

class WeatherTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo(
      function: FunctionInfo(
        name: 'get_weather',
        description: 'Get the current weather for a location',
        parameters: JSONSchema(
          type: 'object',
          properties: {
            'location': JSONSchemaProperty(
              type: 'string',
              description: 'The city name',
            ),
            'units': JSONSchemaProperty(
              type: 'string',
              description: 'Temperature units',
              enumValues: ['celsius', 'fahrenheit'],
            ),
          },
          required: ['location'],
          additionalProperties: false,
        ),
      ),
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final location = args['location'] as String;
    final units = args['units'] as String? ?? 'fahrenheit';

    // Call your weather API here
    final weatherData = await fetchWeather(location, units);

    return jsonEncode({
      'location': location,
      'temperature': weatherData.temperature,
      'condition': weatherData.condition,
    });
  }

  Future<WeatherData> fetchWeather(String location, String units) async {
    // Implement your weather API call
    // ...
  }
}
```

### Using Tools with Chat Model

```dart
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';
import 'package:threepio_core/src/components/tool/examples/weather_tool.dart';

void main() async {
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final model = OpenAIChatModel(config: config);

  // Get tool information
  final calculatorTool = CalculatorTool();
  final weatherTool = WeatherTool();

  final toolInfoList = [
    await calculatorTool.info(),
    await weatherTool.info(),
  ];

  // Bind tools to model
  final modelWithTools = model.withTools(toolInfoList);

  // Ask a question that requires tools
  final messages = [
    Message.user('What is 15 + 27?'),
  ];

  final response = await modelWithTools.generate(messages);

  // Check if model wants to call a tool
  if (response.toolCalls != null && response.toolCalls!.isNotEmpty) {
    print('Model requested tool: ${response.toolCalls!.first.function.name}');
    print('Arguments: ${response.toolCalls!.first.function.arguments}');

    // Execute the tool
    final result = await calculatorTool.run(
      response.toolCalls!.first.function.arguments,
    );

    // Send result back to model
    messages.add(response); // Add assistant's tool call request
    messages.add(Message(
      role: RoleType.tool,
      content: result,
      toolCallId: response.toolCalls!.first.id,
      name: 'calculator',
    ));

    // Get final response
    final finalResponse = await modelWithTools.generate(messages);
    print('Final answer: ${finalResponse.content}');
  }
}
```

## Agent Framework (ReAct Pattern)

For automatic tool execution and multi-step reasoning:

### Basic Agent Usage

```dart
import 'package:threepio_core/src/components/tool/agent.dart';
import 'package:threepio_core/src/components/tool/tool_registry.dart';
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';
import 'package:threepio_core/src/components/tool/examples/weather_tool.dart';

void main() async {
  // Setup
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final model = OpenAIChatModel(config: config);

  // Register tools
  final registry = ToolRegistry();
  registry.register(CalculatorTool());
  registry.register(WeatherTool());

  // Create agent
  final agent = Agent(
    model: model,
    toolRegistry: registry,
    config: AgentConfig(
      maxIterations: 10,  // Max reasoning loops
      maxToolCalls: 20,   // Max total tool calls
    ),
  );

  // Run agent - it will automatically use tools as needed
  final messages = [
    Message.user(
      'Calculate 23 + 19, then get the weather in London and tell me both results.',
    ),
  ];

  final response = await agent.run(messages);
  print(response.content);
  // "The result of 23 + 19 is 42. The current weather in London is
  // 70�F, sunny with 30% humidity."
}
```

### Streaming Agent Responses

```dart
void main() async {
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final model = OpenAIChatModel(config: config);

  final registry = ToolRegistry();
  registry.register(CalculatorTool());

  final agent = Agent(
    model: model,
    toolRegistry: registry,
  );

  final messages = [
    Message.user('What is 7 times 8?'),
  ];

  // Stream agent's reasoning and tool execution
  final reader = await agent.stream(messages);

  try {
    while (true) {
      final message = await reader.recv();

      if (message.role == RoleType.assistant) {
        // Model's reasoning
        print('Thinking: ${message.content}');
      } else if (message.role == RoleType.tool) {
        // Tool was executed
        print('Tool executed: ${message.name}');
      }
    }
  } on StreamEOFException {
    // Complete
  }

  await reader.close();
}
```

## Runnables & Lambdas

**Runnables** are the core abstraction in Threepio (following the Eino pattern). A Runnable is any component that can process inputs and produce outputs, with support for 4 execution modes:

- **invoke**: `I → Future<O>` - Basic async execution
- **stream**: `I → Stream<O>` - Streaming output
- **collect**: `Stream<I> → Future<O>` - Collect stream input
- **transform**: `Stream<I> → Stream<O>` - Stream-to-stream transformation

This makes Runnables extremely flexible and composable.

### Creating Custom Runnables with Lambda

Lambda lets you wrap any function into a Runnable:

```dart
import 'package:threepio_core/src/compose/lambda.dart';

// Simple synchronous function
final uppercase = syncLambda<String, String>(
  (input) => input.toUpperCase(),
);

final result = await uppercase.invoke('hello');
print(result); // 'HELLO'
```

### The Four Execution Modes

**1. Invoke Mode (I → Future<O>)**

Basic async execution for single input/output:

```dart
final processText = lambda<String, int>(
  (input) async {
    // Simulate async processing
    await Future.delayed(Duration(milliseconds: 100));
    return input.length;
  },
);

final result = await processText.invoke('Hello World');
print(result); // 11
```

**2. Stream Mode (I → Stream<O>)**

Generate multiple outputs from single input:

```dart
final tokenize = streamingLambda<String, String>(
  (input) async* {
    for (final word in input.split(' ')) {
      await Future.delayed(Duration(milliseconds: 50));
      yield word.toUpperCase();
    }
  },
);

await for (final token in tokenize.stream('hello world')) {
  print(token); // 'HELLO', then 'WORLD'
}
```

**3. Collect Mode (Stream<I> → Future<O>)**

Aggregate streaming inputs into single output:

```dart
final concatenate = Lambda<String, String>(
  collect: (input, options) async {
    final items = await input.toList();
    return items.join(' ');
  },
);

final inputStream = Stream.fromIterable(['Hello', 'from', 'stream']);
final result = await concatenate.collect(inputStream);
print(result); // 'Hello from stream'
```

**4. Transform Mode (Stream<I> → Stream<O>)**

Transform each item in a stream:

```dart
final uppercaseStream = Lambda<String, String>(
  transform: (input, options) {
    return input.map((s) => s.toUpperCase());
  },
);

final inputStream = Stream.fromIterable(['hello', 'world']);
final outputStream = uppercaseStream.transform(inputStream);

await for (final item in outputStream) {
  print(item); // 'HELLO', then 'WORLD'
}
```

### Composing Runnables with pipe()

Chain runnables together to create processing pipelines:

```dart
// Create individual processing steps
final extractWords = syncLambda<String, List<String>>(
  (text) => text.split(' '),
);

final countWords = syncLambda<List<String>, int>(
  (words) => words.length,
);

final formatResult = syncLambda<int, String>(
  (count) => 'Word count: $count',
);

// Compose them into a pipeline
final wordCounter = extractWords
    .pipe(countWords)
    .pipe(formatResult);

final result = await wordCounter.invoke('Hello world from Threepio');
print(result); // 'Word count: 4'
```

### Batch Processing

Process multiple inputs efficiently:

```dart
final doubleNumber = syncLambda<int, int>(
  (n) => n * 2,
);

// Sequential batch
final results = await doubleNumber.batch([1, 2, 3, 4, 5]);
print(results); // [2, 4, 6, 8, 10]

// Parallel batch (faster for async operations)
final parallelResults = await doubleNumber.batchParallel([1, 2, 3, 4, 5]);
print(parallelResults); // [2, 4, 6, 8, 10]
```

### Advanced Lambda Patterns

**Multiple Execution Modes**

Lambda can provide different implementations for each mode:

```dart
final smartProcessor = Lambda<String, String>(
  // For single inputs, process normally
  invoke: (input, options) async {
    return input.toUpperCase();
  },

  // For streaming, emit character by character
  stream: (input, options) async* {
    for (final char in input.split('')) {
      yield char.toUpperCase();
      await Future.delayed(Duration(milliseconds: 10));
    }
  },

  // For stream inputs, concatenate then process
  collect: (input, options) async {
    final items = await input.toList();
    return items.join('').toUpperCase();
  },

  // For stream transform, map each item
  transform: (input, options) {
    return input.map((s) => s.toUpperCase());
  },
);

// Use whichever mode fits your needs
final result1 = await smartProcessor.invoke('hello');
final result2 = await smartProcessor.stream('hello').toList();
final result3 = await smartProcessor.collect(Stream.fromIterable(['a', 'b']));
```

**With Runnable Options**

Pass metadata and callbacks through execution:

```dart
final logger = Lambda<String, String>(
  invoke: (input, options) async {
    print('Processing: $input');
    print('Metadata: ${options?.metadata}');
    return input.toUpperCase();
  },
);

final result = await logger.invoke(
  'hello',
  options: RunnableOptions(
    metadata: {'user_id': '123', 'request_id': 'abc'},
    tags: ['production', 'api_v2'],
  ),
);
```

### Real-World Example: Data Processing Pipeline

Complete example combining multiple runnables:

```dart
void main() async {
  // Step 1: Clean and validate input
  final cleanInput = syncLambda<String, String>(
    (text) => text.trim().toLowerCase(),
  );

  // Step 2: Extract keywords
  final extractKeywords = lambda<String, List<String>>(
    (text) async {
      final words = text.split(' ');
      return words.where((w) => w.length > 3).toList();
    },
  );

  // Step 3: Call LLM to categorize keywords
  final categorize = lambda<List<String>, Map<String, dynamic>>(
    (keywords) async {
      final model = OpenAIChatModel(config: config);
      final prompt = 'Categorize these keywords: ${keywords.join(", ")}';
      final response = await model.generate([Message.user(prompt)]);

      return {
        'keywords': keywords,
        'categories': response.content,
      };
    },
  );

  // Step 4: Format output
  final formatOutput = syncLambda<Map<String, dynamic>, String>(
    (data) {
      final keywords = data['keywords'] as List;
      final categories = data['categories'];
      return 'Found ${keywords.length} keywords: $categories';
    },
  );

  // Compose the entire pipeline
  final pipeline = cleanInput
      .pipe(extractKeywords)
      .pipe(categorize)
      .pipe(formatOutput);

  // Process single input
  final result = await pipeline.invoke(
    '  Machine Learning and Artificial Intelligence in Healthcare  ',
  );
  print(result);

  // Or process batch
  final batch = await pipeline.batch([
    'Natural Language Processing',
    'Computer Vision Applications',
    'Reinforcement Learning Algorithms',
  ]);

  for (final result in batch) {
    print(result);
  }
}
```

### Runnables vs Chains

**Runnables** are the generic, low-level abstraction:
- Work with any input/output types
- 4 execution modes
- Type-safe composition

**Chains** are specialized Runnables for `Map<String, dynamic>`:
- Convenient for named parameters
- Input/output key validation
- Built specifically for prompt/LLM workflows

```dart
// Generic Runnable
final runnable = lambda<String, int>((s) async => s.length);
await runnable.invoke('hello'); // 5

// Chain (specialized Runnable)
final chain = LLMChain(
  template: template,
  model: model,
  outputKey: 'response',
);
await chain.invoke({'query': 'hello'}); // {'response': '...'}
```

Both can be composed together using `pipe()`!

## Graph Orchestration

Build sophisticated multi-step workflows with **StateGraph** - a powerful system for creating complex, conditional, and parallel execution flows. Perfect for agentic workflows, self-correcting systems, and multi-step reasoning.

### Why Use Graphs?

**Use Chains when:**
- Linear, sequential processing
- Simple input/output transformations
- Straightforward data pipelines

**Use Graphs when:**
- Conditional branching based on runtime state
- Loops and retry logic
- Parallel execution of multiple paths
- Complex multi-agent collaboration
- Self-correcting or validation workflows

### Quick Start: Simple Graph

```dart
import 'package:threepio_core/threepio_core.dart';

// Define your state
class MyState implements GraphState {
  const MyState({required this.value, required this.message});

  final int value;
  final String message;

  @override
  MyState copyWith({int? value, String? message}) {
    return MyState(
      value: value ?? this.value,
      message: message ?? this.message,
    );
  }
}

void main() async {
  // Build the graph
  final graph = StateGraph<MyState>()
    ..addNode('fetch', (state) async {
      // Simulate fetching data
      return state.copyWith(value: 42);
    })
    ..addNode('process', (state) async {
      return state.copyWith(value: state.value * 2);
    })
    ..addNode('respond', (state) async {
      return state.copyWith(message: 'Result: ${state.value}');
    })
    ..addEdge('fetch', 'process')
    ..addEdge('process', 'respond')
    ..setEntryPoint('fetch');

  // Execute
  final result = await graph.invoke(MyState(value: 0, message: ''));
  print(result.state.message); // "Result: 84"
  print(result.path); // ['fetch', 'process', 'respond']
}
```

### Conditional Routing

Route to different nodes based on state:

```dart
final graph = StateGraph<MyState>()
  ..addNode('check_value', (state) => state)
  ..addNode('handle_high', (state) {
    return state.copyWith(message: 'Value is high: ${state.value}');
  })
  ..addNode('handle_low', (state) {
    return state.copyWith(message: 'Value is low: ${state.value}');
  })
  ..addConditionalEdge('check_value', (state) {
    return state.value > 50 ? 'handle_high' : 'handle_low';
  })
  ..setEntryPoint('check_value');
```

### Loops and Retry Logic

Create graphs that loop until a condition is met:

```dart
final graph = StateGraph<MyState>()
  ..addNode('attempt', (state) async {
    // Try some operation
    final success = await tryOperation();
    return state.copyWith(
      value: state.value + 1,
      message: success ? 'success' : 'retry',
    );
  })
  ..addConditionalRouter('attempt', {
    END: (state) => state.message == 'success',
    'attempt': (state) => state.message == 'retry' && state.value < 5,
  }, defaultRoute: END)
  ..setEntryPoint('attempt');
```

### Parallel Execution

Execute multiple nodes concurrently:

```dart
final graph = StateGraph<MapState>()
  ..addNode('split', (state) => state.set('initialized', true))
  ..addNode('task1', (state) async {
    await Future.delayed(Duration(seconds: 1));
    return state.set('task1_done', true);
  })
  ..addNode('task2', (state) async {
    await Future.delayed(Duration(seconds: 1));
    return state.set('task2_done', true);
  })
  ..addNode('task3', (state) async {
    await Future.delayed(Duration(seconds: 1));
    return state.set('task3_done', true);
  })
  ..addParallelEdge(
    'split',
    ['task1', 'task2', 'task3'],
    merger: (original, results) {
      // Merge all parallel results
      var merged = original;
      for (final result in results) {
        if (result.get<bool>('task1_done') == true) {
          merged = merged.set('task1_done', true);
        }
        if (result.get<bool>('task2_done') == true) {
          merged = merged.set('task2_done', true);
        }
        if (result.get<bool>('task3_done') == true) {
          merged = merged.set('task3_done', true);
        }
      }
      return merged;
    },
  )
  ..setEntryPoint('split');
```

### Fluent Builder API

Create graphs with a more expressive syntax:

```dart
import 'package:threepio_core/src/graph/graph_builder.dart';

final graph = (GraphBuilder<MyState>()
  ..withNode('start', (state) => state.copyWith(value: 0))
  ..withNode('increment', (state) => state.copyWith(value: state.value + 1))
  ..withNode('finish', (state) => state.copyWith(message: 'done'))
  ..connect('start', 'increment')
  ..routeIf(
    from: 'increment',
    condition: (state) => state.value < 5,
    then: 'increment',  // Loop back
    otherwise: 'finish', // Exit loop
  )
  ..connect('finish', END)
  ..startFrom('start')).build();
```

### Pre-Built Patterns

Use common patterns without building from scratch:

```dart
// Linear pipeline
final linear = GraphPatterns.linear<MyState>([
  MapEntry('step1', (state) => processStep1(state)),
  MapEntry('step2', (state) => processStep2(state)),
  MapEntry('step3', (state) => processStep3(state)),
]);

// Loop with condition
final loop = GraphPatterns.loop<MyState>(
  entryNode: 'process',
  nodes: [
    MapEntry('process', (state) => processData(state)),
    MapEntry('validate', (state) => validateData(state)),
  ],
  shouldContinue: (state) => !state.isValid && state.retries < 3,
);

// Retry with exponential backoff
final retry = GraphPatterns.retry<MyState>(
  tryNode: 'attempt',
  tryFunction: (state) => attemptOperation(state),
  isSuccess: (state) => state.success,
  maxRetries: 3,
);
```

### Integration with Runnables

Graphs are fully compatible with the Runnable interface:

```dart
// Convert graph to runnable
final graph = StateGraph<MyState>()
  ..addNode('process', (state) => state.copyWith(value: state.value * 2))
  ..setEntryPoint('process');

final runnable = graph.toRunnable();

// Use in runnable pipelines
final pipeline = preprocessor
  .pipe(runnable)
  .pipe(postprocessor);

// Use runnable as graph node
final myRunnable = lambda<String, int>((s) async => s.length);

graph.addNode(
  'count_chars',
  myRunnable.asNode<MyState>(
    getInput: (state) => state.message,
    setOutput: (state, result) => state.copyWith(value: result),
  ),
);
```

### Real-World Example: Self-Correcting RAG

Build a RAG system that validates and self-corrects its answers:

```dart
class RAGState implements GraphState {
  const RAGState({
    required this.question,
    this.documents = const [],
    this.answer = '',
    this.isRelevant = false,
    this.retries = 0,
  });

  final String question;
  final List<Document> documents;
  final String answer;
  final bool isRelevant;
  final int retries;

  @override
  RAGState copyWith({
    String? question,
    List<Document>? documents,
    String? answer,
    bool? isRelevant,
    int? retries,
  }) {
    return RAGState(
      question: question ?? this.question,
      documents: documents ?? this.documents,
      answer: answer ?? this.answer,
      isRelevant: isRelevant ?? this.isRelevant,
      retries: retries ?? this.retries,
    );
  }
}

Future<StateGraph<RAGState>> buildSelfCorrectingRAG({
  required VectorRetriever retriever,
  required ChatModel chatModel,
}) async {
  return StateGraph<RAGState>()
    // Retrieve relevant documents
    ..addNode('retrieve', (state) async {
      final docs = await retriever.retrieve(state.question);
      return state.copyWith(documents: docs);
    })

    // Generate answer
    ..addNode('generate', (state) async {
      final context = state.documents.map((d) => d.content).join('\n\n');
      final prompt = '''
Context: $context

Question: ${state.question}

Answer the question based on the context above.
''';

      final response = await chatModel.generate([Message.user(prompt)]);
      return state.copyWith(answer: response.content);
    })

    // Check if answer is relevant
    ..addNode('check_relevance', (state) async {
      final checkPrompt = '''
Question: ${state.question}
Answer: ${state.answer}

Is this answer relevant and accurate? Respond with only "yes" or "no".
''';

      final response = await chatModel.generate([Message.user(checkPrompt)]);
      final isRelevant = response.content.toLowerCase().contains('yes');

      return state.copyWith(
        isRelevant: isRelevant,
        retries: state.retries + 1,
      );
    })

    // Transform query if not relevant
    ..addNode('transform_query', (state) async {
      final transformPrompt = '''
The original question "${state.question}" didn't get a good answer.
Rephrase this question to get better search results.
Respond with only the rephrased question.
''';

      final response = await chatModel.generate([Message.user(transformPrompt)]);
      return state.copyWith(
        question: response.content,
        documents: [], // Clear old documents
      );
    })

    // Wire it together
    ..addEdge('retrieve', 'generate')
    ..addEdge('generate', 'check_relevance')
    ..addConditionalRouter('check_relevance', {
      END: (state) => state.isRelevant,
      'transform_query': (state) => !state.isRelevant && state.retries < 3,
    }, defaultRoute: END)
    ..addEdge('transform_query', 'retrieve')
    ..setEntryPoint('retrieve');
}

// Usage
void main() async {
  final graph = await buildSelfCorrectingRAG(
    retriever: retriever,
    chatModel: chatModel,
  );

  final result = await graph.invoke(RAGState(
    question: 'What is machine learning?',
  ));

  print('Answer: ${result.state.answer}');
  print('Retries: ${result.state.retries}');
  print('Path taken: ${result.path}');
}
```

### Checkpointing and Resume

Save and resume long-running workflows:

```dart
import 'package:threepio_core/src/graph/graph_checkpoint.dart';

void main() async {
  final store = InMemoryCheckpointStore<MyState>();

  final graph = StateGraph<MyState>()
    ..addNode('step1', (state) => longRunningStep1(state))
    ..addNode('step2', (state) => longRunningStep2(state))
    ..addEdge('step1', 'step2')
    ..setEntryPoint('step1');

  // Execute and save checkpoints
  try {
    final result = await graph.invoke(MyState(value: 0, message: ''));
    await store.save('workflow_123', Checkpoint.now(
      state: result.state,
      currentNode: END,
      path: result.path,
      iteration: result.metadata['iterations'] as int,
    ));
  } catch (e) {
    // Save checkpoint on error for resume
    await store.save('workflow_123', Checkpoint.now(
      state: currentState,
      currentNode: currentNode,
      path: executionPath,
      iteration: iterations,
    ));
  }

  // Resume from checkpoint
  final checkpoint = await store.load('workflow_123');
  if (checkpoint != null) {
    // Resume execution from saved state
  }
}
```

### Visualization

Generate Mermaid diagrams of your graphs:

```dart
final graph = StateGraph<MyState>()
  ..addNode('start', (state) => state, description: 'Initialize')
  ..addNode('process', (state) => state, description: 'Process data')
  ..addNode('finish', (state) => state, description: 'Finalize')
  ..addEdge('start', 'process')
  ..addConditionalEdge('process', (state) => state.value > 10 ? 'finish' : 'process')
  ..setEntryPoint('start');

print(graph.toMermaid());
// Outputs Mermaid diagram you can render in docs
```

### Best Practices

1. **Keep Nodes Focused** - Each node should do one thing well
2. **Use Immutable State** - Always use `copyWith()` to update state
3. **Type-Safe State** - Define custom state classes instead of using `MapState` for production
4. **Handle Errors** - Wrap node logic in try-catch for graceful failures
5. **Test Nodes Independently** - Each node is just a function, easy to test
6. **Set Max Iterations** - Prevent infinite loops with `maxIterations` parameter
7. **Use Descriptive Names** - Name nodes and edges clearly for debugging

### Learn More

For comprehensive graph documentation including advanced patterns and examples:
- **[Complete Graph Guide](packages/threepio_core/docs/GRAPHS.md)** - Detailed documentation with examples
- **[Graph Tests](packages/threepio_core/test/graph/)** - 177 test cases showing all features

## Memory & Persistence

Manage conversation history with powerful, flexible memory systems. Threepio provides multiple memory strategies to balance context retention with resource usage, from simple buffers to LLM-powered summarization.

### Why Memory Matters

Without memory, your AI can't maintain context across messages. With Threepio's memory system:

- **Maintain conversation context** - Remember previous exchanges
- **Manage token budgets** - Control costs and API limits
- **Support multiple users** - Isolate conversations by session
- **Persist across sessions** - Save to files or databases
- **Scale intelligently** - Auto-summarize long conversations

### Quick Start: Basic Memory

```dart
import 'package:threepio_core/threepio_core.dart';

void main() async {
  // Create memory for a user session
  final memory = ConversationBufferMemory(
    sessionId: 'user-123',
  );

  // Simulate a conversation
  await memory.saveContext(
    inputMessage: Message.user('What is Flutter?'),
    outputMessage: Message.assistant('Flutter is Google\'s UI toolkit...'),
  );

  await memory.saveContext(
    inputMessage: Message.user('What are its main features?'),
    outputMessage: Message.assistant('Flutter\'s main features include...'),
  );

  // Load conversation history
  final messages = await memory.loadMemoryMessages();
  print('Conversation has ${messages.length} messages');

  // Get as formatted string
  final conversationText = await memory.loadMemoryString();
  print(conversationText);
  // Output:
  // Human: What is Flutter?
  // AI: Flutter is Google's UI toolkit...
  // Human: What are its main features?
  // AI: Flutter's main features include...
}
```

### Memory Types

Choose the memory strategy that fits your use case:

#### 1. ConversationBufferMemory - Keep Everything

Stores all messages. Simple and provides complete history.

**Best for:** Short conversations, chat logs, when you need full context

```dart
final memory = ConversationBufferMemory(
  sessionId: 'user-123',
);

// Add messages
await memory.saveContext(
  inputMessage: Message.user('Hello!'),
  outputMessage: Message.assistant('Hi there! How can I help?'),
);

// Load all messages
final allMessages = await memory.loadMemoryMessages();
```

**Features:**
- ✅ Complete conversation history
- ✅ Simple to use and understand
- ⚠️ Can grow unbounded
- ⚠️ May exceed token limits for long conversations

#### 2. ConversationBufferWindowMemory - Sliding Window

Keeps only the last K messages. Maintains recent context while limiting memory growth.

**Best for:** Ongoing conversations, chat interfaces, resource-constrained environments

```dart
final memory = ConversationBufferWindowMemory(
  sessionId: 'user-123',
  k: 10, // Keep last 10 messages (5 exchanges)
);

// After 20 messages, only the last 10 are retained
for (var i = 0; i < 20; i++) {
  await memory.saveContext(
    inputMessage: Message.user('Message $i'),
    outputMessage: Message.assistant('Response $i'),
  );
}

final messages = await memory.loadMemoryMessages();
print(messages.length); // 10 (last 10 messages)

// You can still see the total count if needed
final totalCount = await memory.messageCount;
print(totalCount); // 10 (old messages were deleted)
```

**Features:**
- ✅ Predictable memory usage
- ✅ Maintains recent context
- ✅ Automatic cleanup
- ⚠️ Loses older context

**Choosing K:**
- Short-term tasks: k = 6-10 (3-5 exchanges)
- Medium conversations: k = 20 (10 exchanges)
- Long sessions: k = 40+ (20+ exchanges)

#### 3. ConversationTokenBufferMemory - Token-Limited

Keeps messages within a token budget. Useful for managing API costs and model context limits.

**Best for:** Production apps, cost management, working with token-limited models

```dart
final memory = ConversationTokenBufferMemory(
  sessionId: 'user-123',
  maxTokenLimit: 2000,      // Max tokens to keep
  tokensPerMessage: 100,    // Rough estimate per message
);

// Automatically manages token budget
await memory.saveContext(
  inputMessage: Message.user('Long question...'),
  outputMessage: Message.assistant('Detailed answer...'),
);

// Check current usage
final estimatedTokens = await memory.estimateTokenCount();
print('Using approximately $estimatedTokens tokens');

// Only messages within token limit are returned
final messages = await memory.loadMemoryMessages();
```

**Features:**
- ✅ Control costs and API usage
- ✅ Respect model context limits
- ✅ Automatic message trimming
- ⚠️ Token estimation is approximate

**Token Limits by Model:**
- GPT-4o-mini: 128K context (use ~4000-8000 for memory)
- GPT-4: 8K-32K context (use ~2000-8000 for memory)
- Custom models: Check documentation

#### 4. ConversationSummaryMemory - LLM-Powered Summarization

Automatically summarizes old messages using an LLM. Maintains long-term context while keeping recent messages intact.

**Best for:** Long conversations, customer support, knowledge retention, complex reasoning

```dart
import 'package:threepio_openai/threepio_openai.dart';

void main() async {
  final config = OpenAIConfig(apiKey: 'your-key');
  final model = OpenAIChatModel(config: config);

  final memory = ConversationSummaryMemory(
    sessionId: 'support-ticket-456',
    chatModel: model,
    maxMessagesBeforeSummary: 20,  // Summarize after 20 messages
  );

  // After 20 messages, old ones are automatically summarized
  for (var i = 0; i < 30; i++) {
    await memory.saveContext(
      inputMessage: Message.user('Question $i'),
      outputMessage: Message.assistant('Answer $i'),
    );
  }

  // Get the summary
  final summary = await memory.getSummary();
  print('Summary: $summary');

  // Messages returned include:
  // 1. System message with summary
  // 2. Last 20 messages in full
  final messages = await memory.loadMemoryMessages();
  print('Total messages in memory: ${messages.length}');
  // Output: 21 (1 summary + 20 recent messages)

  // Manually trigger summarization if needed
  await memory.summarize();
}
```

**Features:**
- ✅ Unlimited conversation length
- ✅ Maintains long-term context
- ✅ Keeps recent messages in full
- ✅ Progressive summarization
- ⚠️ Requires LLM calls (costs tokens)

**Custom Summarization Prompt:**
```dart
final memory = ConversationSummaryMemory(
  sessionId: 'user-123',
  chatModel: model,
  maxMessagesBeforeSummary: 20,
  summaryPrompt: '''
Create a concise summary of this customer support conversation.
Focus on:
- Customer's main issue
- Solutions provided
- Current status

Conversation:
{conversation}

Summary:
''',
);
```

### Storage Backends - Pluggable Persistence

Memory types are decoupled from storage, allowing you to choose where messages are persisted.

#### In-Memory Storage (Default)

Fast but volatile. Data is lost when the app terminates.

**Best for:** Development, testing, temporary sessions

```dart
final memory = ConversationBufferMemory(
  sessionId: 'user-123',
  store: InMemoryMessageStore(), // Default if not specified
);
```

**Features:**
- ✅ Fast (no I/O)
- ✅ Simple setup
- ⚠️ Data lost on restart
- ⚠️ Not suitable for production

#### File Storage - Production Persistence

Saves messages to JSON files on disk. Each session gets its own file.

**Best for:** Production apps, local persistence, desktop/mobile apps

```dart
import 'dart:io';

void main() async {
  // Create file store
  final fileStore = FileMessageStore(
    baseDirectory: Directory('conversations'),
  );

  // Use with any memory type
  final memory = ConversationBufferMemory(
    sessionId: 'user-123',
    store: fileStore,
  );

  // Messages are automatically saved to:
  // conversations/user-123.json

  // Add messages
  await memory.saveContext(
    inputMessage: Message.user('Hello'),
    outputMessage: Message.assistant('Hi!'),
  );

  // Messages persist across app restarts
  // Later...
  final memory2 = ConversationBufferMemory(
    sessionId: 'user-123',
    store: fileStore,
  );

  final messages = await memory2.loadMemoryMessages();
  print('Loaded ${messages.length} messages from disk');
}
```

**Features:**
- ✅ Production-ready
- ✅ Survives restarts
- ✅ Human-readable JSON
- ✅ One file per session
- ✅ Automatic directory creation
- ⚠️ Not suitable for high-concurrency

**File Structure:**
```json
[
  {
    "role": "user",
    "content": "Hello"
  },
  {
    "role": "assistant",
    "content": "Hi there!"
  }
]
```

#### Custom Storage Backends

Implement `MessageStore` interface for databases:

```dart
class DatabaseMessageStore implements MessageStore {
  DatabaseMessageStore(this.database);

  final Database database;

  @override
  Future<void> addMessage(String sessionId, Message message) async {
    await database.insert('messages', {
      'session_id': sessionId,
      'role': message.role.toString(),
      'content': message.content,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  @override
  Future<List<Message>> getMessages(String sessionId) async {
    final results = await database.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );

    return results.map((row) => Message(
      role: RoleType.values.firstWhere(
        (r) => r.toString() == row['role'],
      ),
      content: row['content'] as String,
    )).toList();
  }

  // Implement other methods...
}

// Use custom store
final memory = ConversationBufferMemory(
  sessionId: 'user-123',
  store: DatabaseMessageStore(myDatabase),
);
```

**Popular Backends:**
- SQLite (via sqflite package)
- PostgreSQL (via postgres package)
- Firebase Firestore
- Hive (local NoSQL)
- SharedPreferences (simple key-value)

### Session Management - Multi-User Support

Each memory instance is scoped to a `sessionId`, enabling multi-user support:

```dart
// Different users, same app
final user1Memory = ConversationBufferMemory(
  sessionId: 'user-alice',
  store: fileStore,
);

final user2Memory = ConversationBufferMemory(
  sessionId: 'user-bob',
  store: fileStore,
);

// Conversations are completely isolated
await user1Memory.saveContext(
  inputMessage: Message.user('My favorite color is blue'),
  outputMessage: Message.assistant('I\'ll remember that!'),
);

await user2Memory.saveContext(
  inputMessage: Message.user('My favorite color is red'),
  outputMessage: Message.assistant('I\'ll remember that!'),
);

// Each user's context is separate
final alice = await user1Memory.loadMemoryMessages();
final bob = await user2Memory.loadMemoryMessages();
```

**Session ID Strategies:**

```dart
// User-based
final sessionId = 'user-${userId}';

// Conversation-based
final sessionId = 'conversation-${conversationId}';

// Tenant-based (multi-tenancy)
final sessionId = 'tenant-${tenantId}-user-${userId}';

// Temporary sessions
final sessionId = 'temp-${uuid.v4()}';
```

**Managing Sessions:**

```dart
final store = FileMessageStore(
  baseDirectory: Directory('conversations'),
);

// List all sessions
final sessionIds = await store.getAllSessionIds();
print('Active sessions: $sessionIds');

// Delete old sessions
for (final sessionId in sessionIds) {
  final count = await store.getMessageCount(sessionId);
  if (count == 0) {
    await store.deleteMessages(sessionId);
  }
}

// Clear all data
await store.clear();
```

### Flexible Formatting - Type-Safe Output

Memory can return messages as strongly-typed objects or formatted strings:

```dart
final memory = ConversationBufferMemory(
  sessionId: 'user-123',
  options: MemoryOptions(
    returnMessages: true,  // Default
    humanPrefix: 'User',
    aiPrefix: 'Assistant',
  ),
);

await memory.saveContext(
  inputMessage: Message.user('Hello'),
  outputMessage: Message.assistant('Hi there!'),
);

// 1. As List<Message> (type-safe)
final messages = await memory.loadMemoryMessages();
for (final msg in messages) {
  print('${msg.role}: ${msg.content}');
}

// 2. As formatted string
final text = await memory.loadMemoryString();
print(text);
// Output:
// User: Hello
// Assistant: Hi there!

// 3. Custom formatting
final custom = await memory.loadMemoryString(
  separator: '\n---\n',
  humanPrefix: '🧑',
  aiPrefix: '🤖',
);
print(custom);
// Output:
// 🧑: Hello
// ---
// 🤖: Hi there!

// 4. As dictionary for chains
final variables = await memory.loadMemoryVariables();
print(variables['history']); // List<Message> or String
```

**Options:**

```dart
final options = MemoryOptions(
  returnMessages: true,      // true = List<Message>, false = String
  inputKey: 'input',         // Key for input in chains
  outputKey: 'output',       // Key for output in chains
  memoryKey: 'history',      // Key for memory in chains
  humanPrefix: 'Human',      // Prefix for user messages
  aiPrefix: 'AI',            // Prefix for assistant messages
);
```

### Integration Examples

#### With Chat Models

```dart
import 'package:threepio_openai/threepio_openai.dart';

void main() async {
  final config = OpenAIConfig(apiKey: 'your-key');
  final model = OpenAIChatModel(config: config);
  final memory = ConversationBufferMemory(sessionId: 'user-123');

  // Multi-turn conversation with memory
  Future<String> chat(String userInput) async {
    // Load history
    final history = await memory.loadMemoryMessages();

    // Add new message
    final messages = [...history, Message.user(userInput)];

    // Get response
    final response = await model.generate(messages);

    // Save to memory
    await memory.saveContext(
      inputMessage: Message.user(userInput),
      outputMessage: response,
    );

    return response.content;
  }

  // Use it
  print(await chat('My name is Alice'));
  print(await chat('What is my name?')); // "Your name is Alice"
}
```

#### With Agents

```dart
void main() async {
  final memory = ConversationBufferWindowMemory(
    sessionId: 'agent-session',
    k: 20,
  );

  final agent = Agent(
    model: model,
    toolRegistry: registry,
  );

  Future<String> agentChat(String input) async {
    // Load conversation history
    final history = await memory.loadMemoryMessages();

    // Add user input
    final messages = [...history, Message.user(input)];

    // Run agent
    final response = await agent.run(messages);

    // Save exchange
    await memory.saveContext(
      inputMessage: Message.user(input),
      outputMessage: response,
    );

    return response.content;
  }

  // Agent remembers context across calls
  await agentChat('Calculate 15 + 27');
  await agentChat('Now multiply that by 2'); // Agent remembers 42
}
```

#### With RAG Systems

```dart
void main() async {
  final memory = ConversationSummaryMemory(
    sessionId: 'rag-session',
    chatModel: model,
    maxMessagesBeforeSummary: 10,
  );

  Future<String> ragQuery(String question) async {
    // Retrieve relevant documents
    final docs = await retriever.retrieve(question);

    // Load conversation history
    final history = await memory.loadMemoryMessages();

    // Build context
    final context = docs.map((d) => d.content).join('\n\n');

    // Create messages with history + new query
    final messages = [
      ...history,
      Message.user('''
Context: $context

Question: $question

Answer based on the context above:
'''),
    ];

    final response = await model.generate(messages);

    // Save to memory
    await memory.saveContext(
      inputMessage: Message.user(question),
      outputMessage: response,
    );

    return response.content;
  }

  // Follow-up questions work because of memory
  await ragQuery('What is machine learning?');
  await ragQuery('Can you give me an example?'); // Knows we're talking about ML
}
```

### Async-First Design

All memory operations are asynchronous, supporting natural Dart patterns:

```dart
// Sequential
final memory = ConversationBufferMemory(sessionId: 'user-123');
await memory.addMessage(Message.user('Hello'));
await memory.addMessage(Message.assistant('Hi!'));
final messages = await memory.loadMemoryMessages();

// Parallel operations on different sessions
await Future.wait([
  memory1.saveContext(
    inputMessage: Message.user('A'),
    outputMessage: Message.assistant('B'),
  ),
  memory2.saveContext(
    inputMessage: Message.user('C'),
    outputMessage: Message.assistant('D'),
  ),
]);

// Stream integration
Stream<String> chatStream(Stream<String> inputs) async* {
  final memory = ConversationBufferMemory(sessionId: 'stream-session');

  await for (final input in inputs) {
    final history = await memory.loadMemoryMessages();
    final messages = [...history, Message.user(input)];
    final response = await model.generate(messages);

    await memory.saveContext(
      inputMessage: Message.user(input),
      outputMessage: response,
    );

    yield response.content;
  }
}
```

### Best Practices

**1. Choose the Right Memory Type**

```dart
// Short conversations (< 10 exchanges)
final memory = ConversationBufferMemory(sessionId: id);

// Medium conversations (10-50 exchanges)
final memory = ConversationBufferWindowMemory(sessionId: id, k: 20);

// Long conversations or cost-sensitive
final memory = ConversationTokenBufferMemory(
  sessionId: id,
  maxTokenLimit: 4000,
);

// Very long conversations (100+ exchanges)
final memory = ConversationSummaryMemory(
  sessionId: id,
  chatModel: model,
  maxMessagesBeforeSummary: 30,
);
```

**2. Use File Storage in Production**

```dart
// Development
final devMemory = ConversationBufferMemory(
  sessionId: 'test',
  // Uses InMemoryMessageStore by default
);

// Production
final prodMemory = ConversationBufferMemory(
  sessionId: userId,
  store: FileMessageStore(
    baseDirectory: Directory('user_conversations'),
  ),
);
```

**3. Implement Session Cleanup**

```dart
// Regular cleanup of old sessions
Future<void> cleanupOldSessions(FileMessageStore store) async {
  final sessionIds = await store.getAllSessionIds();

  for (final sessionId in sessionIds) {
    final count = await store.getMessageCount(sessionId);

    // Delete empty or very old sessions
    if (count == 0) {
      await store.deleteMessages(sessionId);
    }
  }
}

// Run periodically
Timer.periodic(Duration(hours: 24), (_) {
  cleanupOldSessions(fileStore);
});
```

**4. Handle Errors Gracefully**

```dart
try {
  await memory.saveContext(
    inputMessage: userMessage,
    outputMessage: assistantMessage,
  );
} on FileSystemException catch (e) {
  print('Failed to save to disk: $e');
  // Fallback to in-memory
} catch (e) {
  print('Unexpected error: $e');
}
```

**5. Monitor Memory Usage**

```dart
// Check message counts
final count = await memory.messageCount;
if (count > 100) {
  print('Warning: Large conversation history');
}

// For token buffer memory
final tokenMemory = memory as ConversationTokenBufferMemory;
final tokens = await tokenMemory.estimateTokenCount();
print('Using ~$tokens tokens');

// For summary memory
if (memory is ConversationSummaryMemory) {
  final summary = await memory.getSummary();
  if (summary != null) {
    print('Conversation summarized: $summary');
  }
}
```

**6. Type Safety with Custom State**

```dart
// Instead of generic Message, use domain-specific types
class CustomerSupportMessage extends Message {
  CustomerSupportMessage({
    required super.role,
    required super.content,
    this.ticketId,
    this.priority,
  });

  final String? ticketId;
  final String? priority;
}

// Memory still works with inheritance
await memory.addMessage(CustomerSupportMessage(
  role: RoleType.user,
  content: 'I need help',
  ticketId: 'TICKET-123',
  priority: 'high',
));
```

### Common Patterns

**Pattern 1: Conversation Branching**

```dart
// Save conversation at decision point
final mainMemory = ConversationBufferMemory(sessionId: 'main');
await mainMemory.loadMemoryMessages(); // [msg1, msg2, msg3]

// Create branch
final branchMemory = ConversationBufferMemory(sessionId: 'branch-1');
for (final msg in await mainMemory.loadMemoryMessages()) {
  await branchMemory.addMessage(msg);
}

// Branch conversation continues independently
await branchMemory.saveContext(
  inputMessage: Message.user('What if we try X?'),
  outputMessage: Message.assistant('If we try X...'),
);
```

**Pattern 2: Memory Replay**

```dart
// Replay conversation for debugging or analysis
final messages = await memory.loadMemoryMessages();

for (final message in messages) {
  print('${message.role}: ${message.content}');
  if (message.role == RoleType.assistant) {
    // Re-run model to compare outputs
    final newResponse = await model.generate([message]);
    print('Original: ${message.content}');
    print('New: ${newResponse.content}');
  }
}
```

**Pattern 3: Export/Import**

```dart
// Export conversation
Future<Map<String, dynamic>> exportConversation(
  ConversationBufferMemory memory,
) async {
  final messages = await memory.loadMemoryMessages();
  return {
    'session_id': memory.sessionId,
    'message_count': messages.length,
    'messages': messages.map((m) => {
      'role': m.role.toString(),
      'content': m.content,
    }).toList(),
    'exported_at': DateTime.now().toIso8601String(),
  };
}

// Import conversation
Future<void> importConversation(
  ConversationBufferMemory memory,
  Map<String, dynamic> data,
) async {
  await memory.clear();

  for (final msgData in data['messages']) {
    await memory.addMessage(Message(
      role: RoleType.values.firstWhere(
        (r) => r.toString() == msgData['role'],
      ),
      content: msgData['content'],
    ));
  }
}
```

## Structured Output Parsing

Parse and validate LLM outputs into type-safe, structured data. Threepio provides comprehensive output parsing inspired by LangChain's output parsers, OpenAI's function calling patterns, and JSON schema validation.

**Framework Sources:**
- **LangChain**: OutputParser abstractions, retry patterns
- **OpenAI**: JSON mode and structured outputs
- **Instructor**: Structured extraction patterns
- **JSON Schema**: Validation and schema generation

### Why Structured Output?

LLMs naturally produce unstructured text, but applications need structured data. Structured output parsing:

- **Type Safety** - Convert text to validated Dart objects
- **Reliability** - Catch formatting errors early
- **Auto-Retry** - Let the LLM fix its own mistakes
- **Validation** - Enforce schemas and constraints
- **Flexibility** - Support multiple output formats

### Quick Start: Basic Parsing

```dart
import 'package:threepio_core/threepio_core.dart';

void main() async {
  // Simple JSON parsing
  final parser = JsonOutputParser();
  final result = await parser.parse('{"name": "John", "age": 30}');
  print(result['name']); // "John"

  // With schema validation
  final schema = JSONSchema(
    properties: {
      'name': JSONSchemaProperty.string(description: 'Person name'),
      'age': JSONSchemaProperty.number(description: 'Person age'),
    },
    required: ['name', 'age'],
  );

  final validatingParser = JsonOutputParser(schema: schema);
  final validated = await validatingParser.parse(llmOutput);
}
```

### Core Parsers

#### 1. JsonOutputParser - Parse and Validate JSON

Extracts JSON from LLM output (even if wrapped in markdown) and validates against schemas:

```dart
// Basic JSON parsing
final parser = JsonOutputParser();
final data = await parser.parse('{"temperature": 72, "condition": "sunny"}');

// With schema validation
final weatherSchema = JSONSchema(
  properties: {
    'temperature': JSONSchemaProperty.number(
      description: 'Temperature in Fahrenheit',
    ),
    'condition': JSONSchemaProperty.string(
      description: 'Weather condition',
      enumValues: ['sunny', 'cloudy', 'rainy', 'snowy'],
    ),
  },
  required: ['temperature', 'condition'],
);

final validatingParser = JsonOutputParser(schema: weatherSchema);

// Get format instructions to include in your prompt
final instructions = validatingParser.getFormatInstructions();
print(instructions);
// Includes JSON example and field descriptions

// Parse and validate
try {
  final result = await validatingParser.parse(llmOutput);
  print('Temperature: ${result['temperature']}');
} on OutputParserException catch (e) {
  print('Parsing failed: ${e.message}');
  if (e.sendToLLM) {
    // This error can be sent back to LLM to fix
    print(e.toLLMMessage());
  }
}
```

**Features:**
- ✅ Automatic markdown code block extraction
- ✅ JSON schema validation
- ✅ Helpful error messages for LLM
- ✅ Format instructions generation

#### 2. AutoFixingJsonOutputParser - Self-Healing JSON

Automatically fixes common JSON formatting issues:

```dart
final parser = AutoFixingJsonOutputParser(schema: mySchema);

// Handles malformed JSON:
// - Trailing commas: {name: "John",}
// - Single quotes: {'name': 'John'}
// - Truncated output: {name: "John", age: 30
// - Missing closing braces

final result = await parser.parse(malformedJson);
```

**Fixes:**
- Trailing commas
- Single vs double quotes
- Truncated JSON
- Missing closing braces/brackets

#### 3. EnumOutputParser - Parse Enum Values

Extract and normalize enum values from LLM output:

```dart
enum Sentiment { positive, negative, neutral }

final parser = EnumOutputParser<Sentiment>(
  enumValues: Sentiment.values,
  enumName: 'Sentiment',
  caseSensitive: false,
);

// Handles various formats:
await parser.parse('positive');           // Sentiment.positive
await parser.parse('POSITIVE');           // Sentiment.positive
await parser.parse('Sentiment.positive'); // Sentiment.positive
```

#### 4. BooleanOutputParser - Flexible Boolean Parsing

Parse various representations of boolean values:

```dart
final parser = BooleanOutputParser(
  trueValues: ['true', 'yes', 'y', '1', 'correct'],
  falseValues: ['false', 'no', 'n', '0', 'incorrect'],
);

await parser.parse('yes');    // true
await parser.parse('NO');     // false
await parser.parse('1');      // true
```

#### 5. NumberOutputParser - Numeric Parsing with Bounds

Parse numbers with optional validation:

```dart
final parser = NumberOutputParser(
  min: 0,
  max: 100,
  allowDecimals: false,
);

await parser.parse('42');     // 42
await parser.parse('150');    // Throws: above maximum
await parser.parse('3.14');   // Throws: decimals not allowed
```

#### 6. ListOutputParser - Split Text into Lists

Parse delimited lists:

```dart
final parser = ListOutputParser(
  itemSeparator: '\n',
  trimItems: true,
  removeEmpty: true,
);

final items = await parser.parse('''
- Item 1
- Item 2
- Item 3
''');
// ['- Item 1', '- Item 2', '- Item 3']

// CSV-style parsing
final csvParser = CommaSeparatedListOutputParser();
await csvParser.parse('apple, banana, orange');
// ['apple', 'banana', 'orange']
```

### Type-Safe Parsing with Pydantic-Style

The `PydanticOutputParser` combines JSON parsing, schema validation, and type transformation:

```dart
// Define your Dart class
class Person {
  Person({required this.name, required this.age, this.email});

  final String name;
  final int age;
  final String? email;

  factory Person.fromJson(Map<String, dynamic> json) {
    return Person(
      name: json['name'] as String,
      age: json['age'] as int,
      email: json['email'] as String?,
    );
  }
}

// Define schema
final schema = JSONSchema(
  properties: {
    'name': JSONSchemaProperty.string(description: 'Full name'),
    'age': JSONSchemaProperty.number(description: 'Age in years'),
    'email': JSONSchemaProperty.string(description: 'Email address'),
  },
  required: ['name', 'age'],
);

// Create parser
final parser = PydanticOutputParser<Person>(
  schema: schema,
  fromJson: Person.fromJson,
);

// Use in prompt
final prompt = '''
Extract person information from this text and return as JSON.

${parser.getFormatInstructions()}

Text: "John Doe is 30 years old and his email is john@example.com"
''';

// Parse LLM response into type-safe object
final person = await parser.parse(llmOutput);
print(person.name);  // Type-safe access
print(person.age);   // No casting needed
```

### Robust Parsing with Auto-Retry

The `RetryOutputParser` automatically asks the LLM to fix errors:

```dart
final baseParser = JsonOutputParser(schema: mySchema);

// Wrap with retry logic
final retryParser = RetryOutputParser(
  parser: baseParser,
  llm: chatModel,
  maxRetries: 3,
  verbose: true,
);

// Will automatically retry if parsing fails
final result = await retryParser.parse(llmOutput);
// If initial parse fails, sends error back to LLM
// LLM sees the error and tries to fix its output
// Retries up to 3 times
```

**How it works:**
1. Try to parse output
2. If fails, show LLM the error message
3. LLM generates corrected output
4. Retry parsing
5. Repeat up to `maxRetries` times

### Advanced Parsing Patterns

#### Fallback Parsing

Try multiple parsing strategies:

```dart
final parser = FallbackOutputParser([
  JsonOutputParser(),           // Try strict JSON first
  AutoFixingJsonOutputParser(), // Then try with auto-fixing
  StringOutputParser(),         // Finally, just return string
]);

final result = await parser.parse(llmOutput);
// Uses first parser that succeeds
```

#### Chained Parsing

Apply multiple parsers in sequence:

```dart
final parser = ChainedOutputParser([
  MarkdownCodeBlockParser('json'),  // Extract from markdown
  JsonOutputParser(schema: schema), // Parse and validate JSON
]);

final result = await parser.parse('''
Here's the data:
```json
{"name": "Alice", "age": 25}
```
''');
```

#### Validating Parser

Add custom validation logic:

```dart
final parser = ValidatingOutputParser(
  parser: NumberOutputParser(),
  validator: (value) {
    if (value < 0) {
      throw OutputParserException(
        'Number must be positive',
        sendToLLM: true,
      );
    }
  },
);
```

#### Transforming Parser

Transform parsed output:

```dart
final parser = TransformingOutputParser(
  parser: StringOutputParser(),
  transform: (value) => value.toUpperCase(),
);

await parser.parse('hello'); // 'HELLO'
```

### Integration with Existing Schemas

Structured output parsers integrate seamlessly with Threepio's existing JSON Schema system:

```dart
// Use existing tool schema for parsing
final tool = WeatherTool();
final toolInfo = await tool.info();

// Create parser from tool's parameter schema
final parser = JsonOutputParser(
  schema: toolInfo.function.parameters,
);

// Or build schema with fluent API
final schema = ToolInfoBuilder()
  .name('get_weather')
  .addStringParam('location', description: 'City name', required: true)
  .addStringParam('units',
    description: 'Temperature units',
    enumValues: ['celsius', 'fahrenheit'],
  )
  .build();

final schemaParser = JsonOutputParser(schema: schema.function.parameters);
```

### Complete Example: Structured Data Extraction

```dart
void main() async {
  final config = OpenAIConfig(apiKey: 'your-key');
  final model = OpenAIChatModel(config: config);

  // Define what we want to extract
  final schema = JSONSchema(
    properties: {
      'title': JSONSchemaProperty.string(description: 'Article title'),
      'author': JSONSchemaProperty.string(description: 'Author name'),
      'summary': JSONSchemaProperty.string(description: 'Brief summary'),
      'topics': JSONSchemaProperty.array(
        description: 'Main topics',
        items: JSONSchemaProperty.string(),
      ),
      'sentiment': JSONSchemaProperty.string(
        description: 'Overall sentiment',
        enumValues: ['positive', 'negative', 'neutral'],
      ),
    },
    required: ['title', 'summary'],
  );

  // Create parser with auto-retry
  final parser = RetryOutputParser(
    parser: JsonOutputParser(schema: schema),
    llm: model,
    maxRetries: 2,
  );

  // Build prompt with format instructions
  final prompt = '''
Analyze this article and extract key information.

${parser.getFormatInstructions()}

Article:
"Flutter 4.0 Released - Major Performance Improvements

By Jane Smith

The Flutter team announced Flutter 4.0 today, bringing significant
performance improvements and new features. Early benchmarks show
2x faster rendering on mobile devices..."
''';

  // Get structured output
  try {
    final result = await model.generate([Message.user(prompt)]);
    final data = await parser.parse(result.content);

    print('Title: ${data['title']}');
    print('Author: ${data['author']}');
    print('Summary: ${data['summary']}');
    print('Topics: ${data['topics']}');
    print('Sentiment: ${data['sentiment']}');
  } on OutputParserException catch (e) {
    print('Failed to extract data: ${e.message}');
  }
}
```

### Multi-Choice Parsing

Force selection from predefined options:

```dart
final parser = MultiChoiceOutputParser(
  choices: ['Option A', 'Option B', 'Option C'],
  caseSensitive: false,
);

final choice = await parser.parse('I choose option b');
// Returns: 'Option B'
```

### Regex-Based Parsing

Extract structured data using regular expressions:

```dart
final parser = RegexOutputParser(
  pattern: r'Answer: (.+)',
  outputKeys: ['answer'],
);

final result = await parser.parse('Answer: 42');
print(result['answer']); // '42'
```

### Best Practices

**1. Always Include Format Instructions**

```dart
final parser = JsonOutputParser(schema: mySchema);
final instructions = parser.getFormatInstructions();

final prompt = '''
Your task here...

$instructions
''';
```

**2. Use Retry Parsing in Production**

```dart
// Development: See errors immediately
final devParser = JsonOutputParser(schema: schema);

// Production: Auto-retry for reliability
final prodParser = RetryOutputParser(
  parser: JsonOutputParser(schema: schema),
  llm: model,
  maxRetries: 2,
);
```

**3. Validate Critical Data**

```dart
final parser = ValidatingOutputParser(
  parser: PydanticOutputParser<Transaction>(
    schema: transactionSchema,
    fromJson: Transaction.fromJson,
  ),
  validator: (transaction) {
    if (transaction.amount < 0) {
      throw OutputParserException('Amount cannot be negative');
    }
    if (transaction.currency != 'USD') {
      throw OutputParserException('Only USD supported');
    }
  },
);
```

**4. Use Fallback for Graceful Degradation**

```dart
final parser = FallbackOutputParser([
  PydanticOutputParser<WeatherData>(
    schema: weatherSchema,
    fromJson: WeatherData.fromJson,
  ),
  JsonOutputParser(schema: weatherSchema),
  StringOutputParser(), // Fallback to raw string if all else fails
]);
```

**5. Leverage Existing Schemas**

```dart
// Reuse tool schemas
final toolSchema = weatherTool.info().function.parameters;
final parser = JsonOutputParser(schema: toolSchema);

// Share schemas between tools and parsers
final schema = ToolInfoBuilder()
  .name('analyze')
  .addStringParam('sentiment', enumValues: ['positive', 'negative'])
  .addNumberParam('confidence', required: true)
  .build();

final toolInfo = schema;
final parser = JsonOutputParser(schema: schema.function.parameters);
```

**6. Handle Errors Gracefully**

```dart
try {
  final result = await parser.parse(llmOutput);
  // Process result
} on OutputParserException catch (e) {
  print('Parsing error: ${e.message}');

  if (e.sendToLLM) {
    // This error can be fixed by the LLM
    // Consider using RetryOutputParser
    print('LLM can fix this: ${e.toLLMMessage()}');
  } else {
    // Structural error, cannot be fixed
    // Log and use fallback
    print('Structural error, using fallback');
    return defaultValue;
  }
}
```

### Common Patterns

**Pattern 1: Extract Structured Data from Text**

```dart
class Product {
  const Product({required this.name, required this.price, this.description});
  final String name;
  final double price;
  final String? description;

  factory Product.fromJson(Map<String, dynamic> json) => Product(
    name: json['name'],
    price: (json['price'] as num).toDouble(),
    description: json['description'],
  );
}

final parser = RetryOutputParser(
  parser: PydanticOutputParser<Product>(
    schema: productSchema,
    fromJson: Product.fromJson,
  ),
  llm: model,
);

final product = await parser.parse(llmExtraction);
```

**Pattern 2: Classification with Enums**

```dart
enum Category { technology, business, sports, entertainment }

final parser = EnumOutputParser<Category>(
  enumValues: Category.values,
  enumName: 'Category',
);

final category = await parser.parse(llmClassification);
```

**Pattern 3: Multi-Step Parsing**

```dart
final pipeline = ChainedOutputParser([
  MarkdownCodeBlockParser('json'),
  AutoFixingJsonOutputParser(schema: schema),
]);

final result = await pipeline.parse(llmMarkdownOutput);
```

## Prompt Templates & Chains

Build reusable, composable prompt templates and processing pipelines.

### Basic Prompt Templates

Simple string templates with variable substitution:

```dart
import 'package:threepio_core/src/components/prompt/prompt_template.dart';

void main() {
  // Create a template
  final template = PromptTemplate.fromTemplate(
    'Write a {length} {style} story about {topic}.',
  );

  // Format with variables
  final prompt = template.format({
    'length': 'short',
    'style': 'funny',
    'topic': 'a robot learning to dance',
  });

  print(prompt);
  // Output: "Write a short funny story about a robot learning to dance."
}
```

### Chat Prompt Templates

Create conversation templates with multiple roles:

```dart
import 'package:threepio_core/src/components/prompt/chat_prompt_template.dart';

void main() async {
  // Define a chat template
  final template = ChatPromptTemplate.fromMessages([
    MessageTemplate.system('You are a {role} who answers in a {style} way.'),
    MessageTemplate.user('Question: {question}'),
  ]);

  // Format into messages
  final messages = await template.format({
    'role': 'teacher',
    'style': 'simple and clear',
    'question': 'What is photosynthesis?',
  });

  // Use with model
  final response = await model.generate(messages);
  print(response.content);
}
```

### Partial Templates

Preset some variables for reuse:

```dart
void main() {
  final baseTemplate = PromptTemplate.fromTemplate(
    'You are a {role}. {instruction}',
  );

  // Create a partial with role preset
  final teacherTemplate = baseTemplate.partial({'role': 'teacher'});

  // Only need to provide instruction now
  final prompt = teacherTemplate.format({
    'instruction': 'Explain this concept simply.',
  });
}
```

### Few-Shot Learning Templates

Include examples for better results:

```dart
import 'package:threepio_core/src/components/prompt/few_shot_prompt_template.dart';

void main() async {
  // Create a few-shot template
  final template = FewShotChatPromptTemplate(
    systemTemplate: 'You translate English to French.',
    examples: [
      Example({'input': 'Hello', 'output': 'Bonjour'}),
      Example({'input': 'Goodbye', 'output': 'Au revoir'}),
      Example({'input': 'Thank you', 'output': 'Merci'}),
    ],
    inputVariables: ['input'],
  );

  // Format with new input
  final messages = await template.format({
    'input': 'Good morning',
  });

  // The messages will include all examples plus the new input
  final response = await model.generate(messages);
  print(response.content); // "Bonjour" or similar
}
```

### LLM Chain - Combine Templates with Models

Chains make it easy to combine templates with models:

```dart
import 'package:threepio_core/src/components/chain/llm_chain.dart';

void main() async {
  // Create a template
  final template = ChatPromptTemplate.fromTemplate(
    systemTemplate: 'You are a {role}.',
    userTemplate: '{input}',
  );

  // Create a chain
  final chain = LLMChain(
    template: template,
    model: OpenAIChatModel(config: config),
    outputKey: 'response',
  );

  // Run the chain - template formatting happens automatically
  final result = await chain.run({
    'role': 'helpful assistant',
    'input': 'What is the weather like today?',
  });

  print(result['response']); // Model's answer
}
```

### Sequential Chains - Multi-Step Processing

Chain multiple operations together:

```dart
import 'package:threepio_core/src/components/chain/base_chain.dart';

void main() async {
  // First chain: Generate a story
  final storyChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Write a short story about {topic}.',
    ),
    model: model,
    outputKey: 'story',
  );

  // Second chain: Summarize the story
  final summaryChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Summarize this story in one sentence: {story}',
    ),
    model: model,
    outputKey: 'summary',
  );

  // Combine into a sequential chain
  final sequential = SequentialChain(
    chains: [storyChain, summaryChain],
  );

  // Run both chains - output of first becomes input to second
  final result = await sequential.run({
    'topic': 'a time-traveling cat',
  });

  print('Story: ${result['story']}');
  print('Summary: ${result['summary']}');
}
```

### Parallel Chains - Run Multiple Chains Concurrently

Execute chains in parallel for better performance:

```dart
import 'package:threepio_core/src/components/chain/base_chain.dart';

void main() async {
  // Create multiple chains for different analyses
  final sentimentChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Analyze the sentiment (positive/negative/neutral): {text}',
    ),
    model: model,
    outputKey: 'sentiment',
  );

  final topicsChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Extract main topics from: {text}',
    ),
    model: model,
    outputKey: 'topics',
  );

  final summaryChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Summarize: {text}',
    ),
    model: model,
    outputKey: 'summary',
  );

  // Run all chains in parallel
  final parallel = ParallelChain(
    chains: [sentimentChain, topicsChain, summaryChain],
  );

  final result = await parallel.run({
    'text': 'Your long text here...',
  });

  // All results available at once
  print('Sentiment: ${result['sentiment']}');
  print('Topics: ${result['topics']}');
  print('Summary: ${result['summary']}');
}
```

### Transform Chains - Process Text

Apply transformations in your pipeline:

```dart
import 'package:threepio_core/src/components/chain/llm_chain.dart';

void main() async {
  // Chain to clean/normalize text
  final cleanChain = TransformChain.sync(
    inputKey: 'raw_text',
    outputKey: 'clean_text',
    transform: (text) => text.trim().toLowerCase(),
  );

  // Chain to process cleaned text
  final processChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Analyze: {clean_text}',
    ),
    model: model,
    outputKey: 'analysis',
  );

  // Combine
  final pipeline = SequentialChain(
    chains: [cleanChain, processChain],
  );

  final result = await pipeline.run({
    'raw_text': '  MESSY INPUT TEXT  ',
  });
}
```

### Router Chain - Conditional Routing

Route to different chains based on input:

```dart
import 'package:threepio_core/src/components/chain/llm_chain.dart';

void main() async {
  // Different chains for different question types
  final mathChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Solve this math problem: {question}',
    ),
    model: model,
    outputKey: 'answer',
  );

  final scienceChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      systemTemplate: 'You are a science expert.',
      userTemplate: '{question}',
    ),
    model: model,
    outputKey: 'answer',
  );

  final generalChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: '{question}',
    ),
    model: model,
    outputKey: 'answer',
  );

  // Create router
  final router = RouterChain(
    routes: {
      'math': mathChain,
      'science': scienceChain,
    },
    routeKey: 'category',
    defaultChain: generalChain,
  );

  // Route based on input
  final result = await router.run({
    'category': 'math',
    'question': 'What is 15 * 23?',
  });
}
```

### Streaming Chains

Stream responses in real-time:

```dart
import 'package:threepio_core/src/components/chain/llm_chain.dart';

void main() async {
  final template = ChatPromptTemplate.fromTemplate(
    userTemplate: 'Write a story about {topic}.',
  );

  final streamingChain = StreamingLLMChain(
    template: template,
    model: model,
  );

  // Stream the response
  await for (final chunk in streamingChain.stream({'topic': 'dragons'})) {
    print(chunk); // Print each token as it arrives
  }
}
```

### Real-World Example: Content Analysis Pipeline

Complete example combining multiple chains:

```dart
void main() async {
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final model = OpenAIChatModel(config: config);

  // Step 1: Extract key information
  final extractChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      systemTemplate: 'Extract the main points from the following text.',
      userTemplate: '{article}',
    ),
    model: model,
    outputKey: 'key_points',
  );

  // Step 2: Analyze sentiment
  final sentimentChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: 'Analyze sentiment of these points: {key_points}',
    ),
    model: model,
    outputKey: 'sentiment',
  );

  // Step 3: Generate summary
  final summaryChain = LLMChain(
    template: ChatPromptTemplate.fromTemplate(
      userTemplate: '''Based on these key points: {key_points}
And this sentiment: {sentiment}
Write a brief summary.''',
    ),
    model: model,
    outputKey: 'summary',
  );

  // Combine all steps
  final pipeline = SequentialChain(
    chains: [extractChain, sentimentChain, summaryChain],
    returnAll: true, // Return outputs from all chains
  );

  // Run the pipeline
  final result = await pipeline.run({
    'article': '''
      Your long article text here...
      This could be news, blog post, research paper, etc.
    ''',
  });

  print('Key Points: ${result['key_points']}');
  print('Sentiment: ${result['sentiment']}');
  print('Summary: ${result['summary']}');
}
```

### Best Practices

**1. Use Templates for Reusability**
```dart
// Bad: Hardcoded prompt
final prompt = 'You are a teacher. Explain quantum physics.';

// Good: Reusable template
final template = ChatPromptTemplate.fromTemplate(
  systemTemplate: 'You are a {role}.',
  userTemplate: 'Explain {topic}.',
);
```

**2. Chain for Complex Workflows**
```dart
// Bad: Manual chaining with lots of code
final step1 = await model.generate([...]);
final step2 = await model.generate([Message.user(step1.content)]);

// Good: Declarative chain
final pipeline = SequentialChain(chains: [chain1, chain2]);
final result = await pipeline.run({...});
```

**3. Use Parallel for Independent Operations**
```dart
// Bad: Sequential when operations are independent
final sentiment = await sentimentChain.run(input);
final topics = await topicsChain.run(input);

// Good: Parallel execution
final parallel = ParallelChain(chains: [sentimentChain, topicsChain]);
final result = await parallel.run(input);
```

**4. Partial Templates for Common Patterns**
```dart
// Create specialized templates from base template
final baseTemplate = ChatPromptTemplate.fromTemplate(
  systemTemplate: 'You are a {role}. {instruction}',
  userTemplate: '{input}',
);

final teacherTemplate = baseTemplate.partial({
  'role': 'teacher',
  'instruction': 'Explain concepts clearly and simply.',
});

final writerTemplate = baseTemplate.partial({
  'role': 'creative writer',
  'instruction': 'Write engaging and imaginative content.',
});
```

## Retrieval-Augmented Generation (RAG)

Build powerful question-answering systems by combining document retrieval with language models. RAG allows models to answer questions using information from your documents.

### Quick Start: Complete RAG Pipeline

```dart
import 'package:threepio_core/threepio_core.dart';
import 'package:threepio_openai/threepio_openai.dart';

void main() async {
  // 1. Setup components
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final embedder = OpenAIEmbedder(config: config);
  final vectorStore = InMemoryVectorStore();
  final chatModel = OpenAIChatModel(config: config);

  // 2. Load documents
  final loader = TextLoader(filePath: 'knowledge_base.txt');
  final documents = await loader.load();

  // 3. Split into chunks
  final splitter = RecursiveCharacterTextSplitter();
  final chunks = await splitter.splitDocuments(
    documents,
    options: TextSplitterOptions(
      chunkSize: 1000,
      chunkOverlap: 200,
    ),
  );

  // 4. Embed and index
  for (final chunk in chunks) {
    final embeddings = await embedder.embedStrings([chunk.content]);
    await vectorStore.addDocuments([
      chunk.copyWith(embedding: embeddings.first),
    ]);
  }

  // 5. Create RAG chain
  final retriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
  );

  final ragChain = RetrievalQAChain(
    retriever: retriever,
    chatModel: chatModel,
  );

  // 6. Ask questions!
  final result = await ragChain.invoke({
    'question': 'What is the main topic of the document?',
  });

  print('Answer: ${result['answer']}');

  // View sources
  final sources = result['source_documents'] as List<Document>;
  for (final doc in sources) {
    print('Source: ${doc.source?.uri}');
    print('Relevance: ${doc.score}');
  }
}
```

### RAG Components

#### 1. Embedders - Convert Text to Vectors

```dart
// OpenAI Embedder
final embedder = OpenAIEmbedder(
  config: config,
  defaultModel: 'text-embedding-3-small', // 1536 dimensions
);

// Embed single text
final vectors = await embedder.embedStrings(['Hello world']);

// Batch embed with automatic chunking
final manyTexts = List.generate(500, (i) => 'Document $i');
final allVectors = await embedder.embedStringsChunked(manyTexts);
```

**Available Models:**
- `text-embedding-3-small` - 1536 dimensions, fast & efficient
- `text-embedding-3-large` - 3072 dimensions, higher quality
- `text-embedding-ada-002` - 1536 dimensions, legacy

#### 2. Vector Stores - Store and Search Embeddings

```dart
// Create in-memory vector store
final store = InMemoryVectorStore(
  similarityMetric: SimilarityMetric.cosine, // default
);

// Add documents with embeddings
await store.addDocuments([
  Document(
    id: '1',
    content: 'Paris is the capital of France',
    embedding: [0.1, 0.2, 0.3, ...],
  ),
]);

// Search by similarity
final results = await store.similaritySearch(
  queryEmbedding: queryVector,
  k: 5,
);

// Search with score threshold
final filtered = await store.similaritySearchWithThreshold(
  queryEmbedding: queryVector,
  scoreThreshold: 0.8,
);
```

#### 3. Retrievers - Query Documents by Meaning

```dart
// Vector retriever combines embedder + vector store
final retriever = VectorRetriever(
  embedder: embedder,
  vectorStore: vectorStore,
  defaultTopK: 4,
);

// Retrieve relevant documents
final docs = await retriever.retrieve(
  'What is machine learning?',
  options: RetrieverOptions(
    topK: 5,
    scoreThreshold: 0.7,
  ),
);

// Get results with similarity scores
final withScores = await retriever.retrieveWithScores(
  'What is machine learning?',
);

for (final result in withScores) {
  print('${result.score.toStringAsFixed(3)}: ${result.document.content}');
}
```

#### 4. Document Loaders - Load from Files

```dart
// Load single file
final textLoader = TextLoader(filePath: 'document.txt');
final docs = await textLoader.load();

// Load entire directory
final dirLoader = DirectoryLoader(
  dirPath: 'documents/',
  glob: '**/*.txt',
  recursive: true,
);

final allDocs = await dirLoader.load();
print('Loaded ${allDocs.length} documents');

// Lazy loading for large directories
await for (final doc in dirLoader.loadLazy()) {
  print('Processing: ${doc.source?.uri}');
  // Process each document as it loads
}
```

#### 5. Text Splitters - Chunk Documents

```dart
// Recursive splitter (recommended)
final splitter = RecursiveCharacterTextSplitter(
  separators: ['\n\n', '\n', '. ', ' ', ''], // default
);

final chunks = splitter.splitText(
  longText,
  options: TextSplitterOptions(
    chunkSize: 1000,
    chunkOverlap: 200,
  ),
);

// Split documents while preserving metadata
final splitDocs = await splitter.splitDocuments(documents);

// Each chunk includes parent metadata
for (final chunk in splitDocs) {
  print('Chunk ${chunk.metadata['chunk_index']} of ${chunk.metadata['total_chunks']}');
}
```

#### 6. RAG Chains - Orchestrate RAG Workflows

**Basic Question Answering:**

```dart
final chain = RetrievalQAChain(
  retriever: retriever,
  chatModel: chatModel,
  topK: 4,
  returnSourceDocuments: true,
);

final result = await chain.invoke({
  'question': 'How do I install Flutter?',
});

print(result['answer']);
print(result['source_documents']);
```

**Conversational RAG with History:**

```dart
final chain = ConversationalRetrievalChain(
  retriever: retriever,
  chatModel: chatModel,
);

// First question
var result = await chain.invoke({
  'question': 'What is machine learning?',
  'chat_history': <Message>[],
});

var chatHistory = result['chat_history'] as List<Message>;

// Follow-up question (understands context)
result = await chain.invoke({
  'question': 'What are its applications?', // "its" = machine learning
  'chat_history': chatHistory,
});
```

**Custom Document Formatting:**

```dart
final chain = CustomRetrievalQAChain(
  retriever: retriever,
  chatModel: chatModel,
  documentFormatter: (doc) {
    return '''
[Source: ${doc.source?.uri}]
[Score: ${doc.score?.toStringAsFixed(2)}]
${doc.content}
---
''';
  },
);
```

### Complete RAG Example: Documentation Q&A

```dart
Future<void> buildDocumentationQA() async {
  // Setup
  final config = OpenAIConfig(apiKey: 'your-api-key');
  final embedder = OpenAIEmbedder(config: config);
  final vectorStore = InMemoryVectorStore();
  final chatModel = OpenAIChatModel(config: config);

  // Load documentation files
  final loader = DirectoryLoader(
    dirPath: 'docs/',
    glob: '**/*.md',
    recursive: true,
  );

  final docs = await loader.load();
  print('Loaded ${docs.length} documentation files');

  // Split into chunks
  final splitter = RecursiveCharacterTextSplitter();
  final chunks = await splitter.splitDocuments(
    docs,
    options: TextSplitterOptions(
      chunkSize: 1000,
      chunkOverlap: 200,
    ),
  );

  // Embed and index
  print('Indexing ${chunks.length} chunks...');
  for (var i = 0; i < chunks.length; i++) {
    final chunk = chunks[i];
    final embeddings = await embedder.embedStrings([chunk.content]);

    await vectorStore.addDocuments([
      chunk.copyWith(
        id: 'chunk_$i',
        embedding: embeddings.first,
      ),
    ]);

    if ((i + 1) % 10 == 0) {
      print('Indexed ${i + 1}/${chunks.length}');
    }
  }

  // Create RAG chain
  final retriever = VectorRetriever(
    embedder: embedder,
    vectorStore: vectorStore,
    defaultTopK: 5,
  );

  final ragChain = RetrievalQAChain(
    retriever: retriever,
    chatModel: chatModel,
    returnSourceDocuments: true,
  );

  // Ask questions
  final questions = [
    'How do I get started?',
    'What are the main features?',
    'How do I configure authentication?',
  ];

  for (final question in questions) {
    print('\nQ: $question');

    final result = await ragChain.invoke({'question': question});

    print('A: ${result['answer']}');

    // Show sources
    if (result.containsKey('source_documents')) {
      final sources = result['source_documents'] as List<Document>;
      print('\nSources:');
      for (final doc in sources) {
        final filename = (doc.metadata['source'] as String).split('/').last;
        print('  - $filename (score: ${doc.score?.toStringAsFixed(2)})');
      }
    }
  }
}
```

### RAG Best Practices

1. **Choose appropriate chunk sizes:**
   - General text: 1000 characters, 200 overlap
   - Code: 500 characters, 50 overlap
   - Structured data: Split on natural boundaries

2. **Select the right embedding model:**
   - `text-embedding-3-small` for most cases
   - `text-embedding-3-large` when accuracy is critical

3. **Tune retrieval parameters:**
   - Start with `topK: 4-5`
   - Use `scoreThreshold` to filter low-quality results
   - Experiment to find optimal balance

4. **Preserve metadata:**
   - Include source information, timestamps, authors
   - Use metadata for filtering and display

5. **Handle edge cases:**
   - What if no relevant documents are found?
   - How to handle very long documents?
   - Consider caching embeddings

### Learn More

For comprehensive RAG documentation including advanced patterns (hybrid search, re-ranking, multi-query), see:
- **[Complete RAG Guide](packages/threepio_core/docs/RAG.md)** - Detailed documentation with examples
- **[Callbacks Guide](packages/threepio_core/docs/CALLBACKS.md)** - Add observability to RAG pipelines

## Configuration

### Environment Variables

Create a `.env` file in your project root:

```env
OPENAI_API_KEY=sk-your-api-key-here
```

Load it in your code:

```dart
import 'package:dotenv/dotenv.dart';

void main() {
  final env = DotEnv()..load(['.env']);
  final apiKey = env['OPENAI_API_KEY']!;

  final config = OpenAIConfig(apiKey: apiKey);
  // ...
}
```

### Model Configuration

```dart
final config = OpenAIConfig(
  apiKey: 'your-api-key',
  baseUrl: 'https://api.openai.com/v1',  // Custom endpoint if needed
  organization: 'org-123',                // Optional organization ID
  defaultModel: 'gpt-4o-mini',           // Default model to use
  timeout: Duration(seconds: 60),         // Request timeout
);
```

### Chat Options

```dart
final options = ChatModelOptions(
  model: 'gpt-4',                  // Override default model
  temperature: 0.7,                 // Creativity (0-2)
  maxTokens: 1000,                  // Max response length
  topP: 0.9,                        // Nucleus sampling
  stop: ['END'],                    // Stop sequences
  tools: toolInfoList,              // Available tools
  toolChoice: ToolChoice.auto,      // Tool usage policy
);

final response = await model.generate(messages, options: options);
```

## Built-in Tools

Threepio includes example tools:

### Calculator Tool

```dart
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';

final calc = CalculatorTool();
final result = await calc.run('{"operation": "multiply", "a": 6, "b": 7}');
print(result); // {"result": 42}
```

### Weather Tool (Mock)

```dart
import 'package:threepio_core/src/components/tool/examples/weather_tool.dart';

final weather = WeatherTool();
final result = await weather.run('{"location": "Paris", "units": "celsius"}');
print(result); // {"location": "Paris", "temperature": 22, ...}
```

### Search Tool

```dart
import 'package:threepio_core/src/components/tool/examples/search_tool.dart';

final search = SearchTool();
final result = await search.run('{"query": "Dart programming", "max_results": 5}');
print(result); // {"query": "Dart programming", "results": [...]}
```

## Advanced Usage

### Custom Message Types

```dart
// System message
final systemMsg = Message(
  role: RoleType.system,
  content: 'You are a helpful coding assistant.',
);

// User message
final userMsg = Message.user('How do I use async/await?');

// Assistant message
final assistantMsg = Message(
  role: RoleType.assistant,
  content: 'To use async/await in Dart...',
);

// Tool result message
final toolMsg = Message(
  role: RoleType.tool,
  content: '{"result": 42}',
  toolCallId: 'call_123',
  name: 'calculator',
);
```

### Multi-Modal Input (Images)

```dart
final message = Message(
  role: RoleType.user,
  content: '',
  userInputMultiContent: [
    MessageInputPart.text('What is in this image?'),
    MessageInputPart.imageUrl(
      'https://example.com/image.png',
      detail: ImageURLDetail.high,
    ),
  ],
);

final response = await model.generate([message]);
```

### Error Handling

```dart
try {
  final response = await model.generate(messages);
  print(response.content);
} on OpenAIException catch (e) {
  print('OpenAI API error: $e');
  if (e.statusCode == 401) {
    print('Invalid API key');
  } else if (e.statusCode == 429) {
    print('Rate limit exceeded');
  }
} on TimeoutException {
  print('Request timed out');
} catch (e) {
  print('Unexpected error: $e');
}
```

### Token Usage Tracking

```dart
final response = await model.generate(messages);

if (response.responseMeta?.usage != null) {
  final usage = response.responseMeta!.usage!;
  print('Prompt tokens: ${usage.promptTokens}');
  print('Completion tokens: ${usage.completionTokens}');
  print('Total tokens: ${usage.totalTokens}');

  if (usage.promptTokenDetails?.cachedTokens != null) {
    print('Cached tokens: ${usage.promptTokenDetails!.cachedTokens}');
  }
}
```

## Testing

### Unit Tests

```bash
# Run all unit tests
flutter test

# Run specific test file
flutter test test/components/tool/calculator_tool_test.dart

# Run with coverage
flutter test --coverage
```

### Integration Tests

Integration tests require a valid OpenAI API key in `.env`:

```bash
# Run integration tests (makes real API calls)
flutter test test/integration/openai_integration_test.dart
```

## Architecture

```
threepio_core/
   lib/src/
      schema/              # Core data structures
         message.dart     # Message types and content
         tool_info.dart   # Tool definitions and schemas
         document.dart    # Document types for RAG
   
      streaming/           # Stream infrastructure
         stream_reader.dart
         stream_writer.dart
         stream_item.dart
         stream_utils.dart
   
      components/
         model/          # Chat model implementations
            base_chat_model.dart
            chat_model_options.dart
            providers/
                openai/
                    openai_chat_model.dart
                    openai_config.dart
                    openai_converters.dart
      
         tool/           # Tool execution and agents
             invokable_tool.dart
             tool_registry.dart
             tool_executor.dart
             agent.dart
             examples/
                 calculator_tool.dart
                 weather_tool.dart
                 search_tool.dart
   
      ...
   test/                   # Comprehensive test suite
```

## Design Principles

1. **Idiomatic Dart/Flutter** - Follows platform conventions and best practices
2. **Type Safety** - Leverages Dart's strong typing with freezed for immutability
3. **Streaming First** - Built-in support for real-time responses
4. **Testability** - Dependency injection and mocking support throughout
5. **Modularity** - Composable components that can be used independently
6. **Clean Architecture** - Clear separation between schema, components, and providers

## Roadmap

- [ ] Additional LLM providers (Anthropic Claude, Google Gemini, Ollama)
- [x] RAG (Retrieval Augmented Generation) support
- [x] Vector store (in-memory) implementation
- [ ] Additional vector store backends (Pinecone, Weaviate, Chroma)
- [x] Prompt templates and chains
- [x] Graph orchestration with conditional routing and parallel execution
- [x] Memory/conversation persistence (buffer, window, token-limited, summarization)
- [x] Structured output parsing with validation, auto-retry, and type-safe transformations
- [ ] Cost tracking and optimization
- [ ] Caching strategies

## Contributing

Contributions are welcome! Please read the contributing guidelines before submitting PRs.

## License

[Your License Here]

## Acknowledgments

Inspired by the [Eino](https://github.com/cloudwego/eino) LLM framework from CloudWeGo.

---

Built with d using Flutter and Dart
