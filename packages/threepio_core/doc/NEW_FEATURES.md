# Threepio Core: features added before 0.9

> **Before the Eino port.** This page describes features threepio gained
> before the 0.9 port of Eino: the Gemini provider, the older ADK agents,
> checkpoint and resume of `StateGraph`, the advanced retrievers, the
> ingestion pipeline, the rerankers and the text splitters. They still exist,
> and every code block on this page compiles against 0.9. For new code, start
> with the Eino-shaped replacements: the agents of
> `package:threepio_core/adk.dart`, the checkpoints of a compose `Graph`
> ([GRAPHS.md](GRAPHS.md)), the retrieval flows of `flow.dart` and the
> splitters built from eino-ext configurations ([RAG.md](RAG.md)). [MIGRATION.md](MIGRATION.md)
> shows how to move; each section below names its Eino-shaped equivalent.

## Table of Contents

1. [Gemini Chat Model Provider](#1-gemini-chat-model-provider)
2. [Agent Development Kit (ADK)](#2-agent-development-kit-adk)
3. [Checkpoint & Resume System](#3-checkpoint--resume-system)
4. [Advanced Retrieval Patterns](#4-advanced-retrieval-patterns)
5. [Document Processing Pipeline](#5-document-processing-pipeline)
6. [Reranking System](#6-reranking-system)
7. [Advanced Text Splitters](#7-advanced-text-splitters)
8. [Complete RAG Application Example](#complete-rag-application-example)
9. [Migration Guide](#migration-guide)
10. [Best Practices](#best-practices)

---

## 1. Gemini Chat Model Provider

The Gemini provider talks to Google's Gemini REST API: text generation, multimodal input and output, streaming, tool calling, thinking, server tools (code execution, Google Search, URL context, file search, Google Maps, computer use), prefix caches and Imagen image generation.

> **Eino-shaped equivalent:** `GeminiChatModel` is itself the port of eino-ext `components/model/gemini` (`GeminiRequestOptions` holds Go's `With…` options). As a `ToolCallingChatModel` it works in `adk.ChatModelAgent`, in a compose `Graph` (`addChatModelNode`) or `Chain` (`appendChatModel`), and in `RetryingChatModel`/`FailoverChatModel`; the legacy `Agent` near the end of this section is replaced by the ADK agent ([MIGRATION.md](MIGRATION.md)).

### Configuration

```dart
import 'package:threepio_core/threepio_core.dart';

// Basic configuration
const config = GeminiConfig(
  apiKey: 'your-api-key',
  defaultModel: 'gemini-2.5-pro', // default: gemini-2.5-flash
  timeout: Duration(seconds: 60), // default: 120 seconds
);

// Or from the environment: GEMINI_API_KEY or GOOGLE_API_KEY (required),
// GEMINI_BASE_URL and GEMINI_MODEL (optional). Throws a
// GeminiConfigException when neither key is set.
final configFromEnv = GeminiConfig.fromEnvironment();

// Create the chat model
final model = GeminiChatModel(config: config);
```

`GeminiConfig` also holds the defaults of every call (`maxTokens`, `temperature`, `topP`, `topK`, `responseJsonSchema`, `thinkingConfig`, `imageConfig`, `responseModalities`, `mediaResolution`, `safetySettings`, `responseLogprobs`, `logprobs`) and the server tools the model may use (`enableCodeExecution`, `enableGoogleSearch`, `enableUrlContext`, `enableFileSearch`, `enableGoogleMaps`, `enableComputerUse`). A model created without an `httpClient` creates one client and keeps it; call `model.dispose()` when you no longer need the model (its `withTools` copies share the client).

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

The common settings are fields of `ChatModelOptions`; the Gemini-specific ones are a `GeminiRequestOptions` (Go: `gemini.WithTopK`, `WithThinkingConfig`, …), which `toOptions` puts into `ChatModelOptions.extensions`. Defaults for every call, and the safety filter, go into `GeminiConfig`.

```dart
final response = await model.generate(
  messages,
  options: GeminiRequestOptions(
    topK: 40, // Top-K sampling
  ).toOptions(
    model: 'gemini-2.5-pro', // Override the default model
    temperature: 0.7, // Creativity (0.0 - 2.0)
    maxTokens: 1024, // Maximum output tokens
    topP: 0.95, // Nucleus sampling
    stop: ['END'], // Stop sequences
  ),
);

// Token usage
final usage = response.responseMeta?.usage;
print('Prompt tokens: ${usage?.promptTokens}');
print('Completion tokens: ${usage?.completionTokens}');

// Defaults of every call, the safety filter and thinking
const tunedConfig = GeminiConfig(
  apiKey: 'your-api-key',
  temperature: 0.2,
  topK: 40,
  safetySettings: [
    GeminiSafetySetting(
      category: GeminiHarmCategory.harassment,
      threshold: GeminiHarmBlockThreshold.blockMediumAndAbove,
    ),
  ],
  // The thought summaries come back in Message.reasoningContent
  thinkingConfig: GeminiThinkingConfig(includeThoughts: true),
);
```

`GeminiRequestOptions` also carries `responseJsonSchema`, `thinkingConfig`, `responseModalities`, `imageConfig`, `cachedContentName`, `extraFields`, `customHeaders`, `responseLogprobs` and `logprobs`. The older `ChatModelOptions.extra` keys (`topK`, `candidateCount`, `responseMimeType`, `responseSchema`, `responseModalities`, `safetySettings`) are still read: `GeminiRequestOptions` wins over them, and they win over `GeminiConfig` (except `responseMimeType`, which `GeminiConfig.responseJsonSchema` sets to `application/json`).

### Streaming Responses

```dart
import 'dart:io';

final reader = await model.stream([
  Message.user('Write a short story about a robot.'),
]);

// asStream() hands the chunks to `await for` and closes the reader at the end
await for (final chunk in reader.asStream()) {
  stdout.write(chunk.content);
}

// Or pull the chunks one by one, as Go's Recv loop does
final reader2 = await model.stream([Message.user('Count to five.')]);
try {
  for (var chunk = await reader2.nextOrNull();
      chunk != null;
      chunk = await reader2.nextOrNull()) {
    stdout.write(chunk.content);
  }
} finally {
  await reader2.close();
}
```

`recv()` is the other way to pull: it throws `StreamEOFException` after the last chunk. Close a reader you stop reading early.

### Multimodal Input (Images, Audio, Video)

Base64 data, data URLs included, is sent inline (`inline_data`). Any other URL, and a file id, is sent as `file_data`, so it must be a URI the Gemini API accepts there, such as a file uploaded with its Files API; the MIME type is guessed from the URL unless you give one.

```dart
import 'dart:convert';

// Image as a data URL (sent inline)
final response = await model.generate([
  Message(
    role: RoleType.user,
    userInputMultiContent: [
      MessageInputPart.text('What is in this image?'),
      MessageInputPart.imageUrl(
        'data:image/jpeg;base64,${base64Encode(imageBytes)}',
      ),
    ],
  ),
]);
print(response.content);

// Audio as base64 data
final audioResponse = await model.generate([
  Message(
    role: RoleType.user,
    userInputMultiContent: [
      MessageInputPart.text('Transcribe this audio'),
      MessageInputPart.audio(
        base64Data: base64Encode(audioBytes),
        mimeType: 'audio/mp3',
      ),
    ],
  ),
]);
print(audioResponse.content);

// Video uploaded with the Gemini Files API
final videoResponse = await model.generate([
  Message(
    role: RoleType.user,
    userInputMultiContent: [
      MessageInputPart.text('What happens in this video?'),
      MessageInputPart.video(fileId: uploadedVideoUri, mimeType: 'video/mp4'),
    ],
  ),
]);
print(videoResponse.content);
```

`MessageInputPart.file(...)` sends other documents (a PDF, for example) the same way.

### Image Generation

```dart
import 'dart:convert';
import 'dart:io';

// Use an image generation model
final imageModel = GeminiChatModel(
  config: GeminiConfig(
    apiKey: apiKey,
    defaultModel: 'gemini-2.5-flash-image',
  ),
);

final response = await imageModel.generate(
  [Message.user('Generate an image of a red circle on white background')],
  options: GeminiRequestOptions(
    responseModalities: const [
      GeminiResponseModality.text,
      GeminiResponseModality.image, // Enable image output
    ],
    imageConfig: const GeminiImageConfig(aspectRatio: '1:1'),
  ).toOptions(),
);

// Generated images are output parts holding a data:image/png;base64 URL
for (final part in response.assistantGenMultiContent ?? <MessageOutputPart>[]) {
  if (part.type == ChatMessagePartType.imageUrl) {
    final dataUrl = part.image!.url!;
    final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
    await File('output.png').writeAsBytes(bytes);
  }
}
```

### Imagen Image Generation

For dedicated image generation, use Google's Imagen models. A model name starting with `imagen-` sends the text of the last user message to the `:predict` endpoint. Its settings are read from `ChatModelOptions.extra` (`GeminiRequestOptions` and the sampling settings do not apply), and only `generate` supports it.

```dart
import 'dart:convert';
import 'dart:io';

// Available Imagen models:
// - imagen-4.0-generate-001 (Standard)
// - imagen-4.0-ultra-generate-001 (Ultra - higher quality)
// - imagen-4.0-fast-generate-001 (Fast - lower latency)

final imagenModel = GeminiChatModel(
  config: GeminiConfig(
    apiKey: apiKey,
    defaultModel: 'imagen-4.0-generate-001',
  ),
);

// Basic image generation
final response = await imagenModel.generate([
  Message.user('A serene mountain landscape at sunset with snow-capped peaks'),
]);
print(response.content); // Generated <n> image(s) for: "<prompt>"

// With options
final response2 = await imagenModel.generate(
  [Message.user('A cute robot playing with a kitten')],
  options: const ChatModelOptions(
    extra: {
      'numberOfImages': 2, // 1-4 images (sent as sampleCount)
      'aspectRatio': '16:9', // '1:1', '3:4', '4:3', '9:16', '16:9'
      'personGeneration': 'dont_allow', // 'dont_allow', 'allow_adult', 'allow_all'
      'imageSize': '2K', // '1K', '2K' (Standard/Ultra only)
    },
  ),
);

// Generated images are output parts holding a data:image/png;base64 URL
var index = 0;
for (final part in response2.assistantGenMultiContent ?? <MessageOutputPart>[]) {
  if (part.type == ChatMessagePartType.imageUrl) {
    final dataUrl = part.image!.url!;
    final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
    await File('generated_image_${index++}.png').writeAsBytes(bytes);
  }
}
```

The Imagen path also passes on `safetyFilterLevel` and `addWatermark` from `extra`.

**Imagen vs Gemini Image Generation:**

| Feature | Gemini (`gemini-*-image`) | Imagen (`imagen-*`) |
|---------|---------------------------|---------------------|
| API endpoint | `:generateContent` (and `:streamGenerateContent`) | `:predict`, `generate` only |
| Conversation | Yes (chat context) | No (the last user message is the prompt) |
| Settings | `GeminiRequestOptions` / `GeminiConfig` (`responseModalities`, `imageConfig`) | `ChatModelOptions.extra` |
| Images per call | As the model answers | `numberOfImages`, 1-4 |
| Aspect ratios | `GeminiImageConfig.aspectRatio`: `1:1`, `2:3`, `3:2`, `3:4`, `4:3`, `9:16`, `16:9`, `21:9` | `1:1`, `3:4`, `4:3`, `9:16`, `16:9` |
| Person generation | No control | `personGeneration` |

### Tool/Function Calling

```dart
import 'dart:convert';

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

// Bind tools to model (the tool choice becomes ToolChoice.allowed)
final modelWithTools = model.withTools([weatherTool]);

// Generate - model may request tool calls
final question = Message.user('What is the weather in Tokyo?');
final response = await modelWithTools.generate([question]);

// Check if model wants to call tools
final toolCalls = response.toolCalls ?? <ToolCall>[];
if (toolCalls.isNotEmpty) {
  final toolResults = <Message>[];
  for (final toolCall in toolCalls) {
    print('Tool: ${toolCall.function.name}');
    print('Arguments: ${toolCall.function.arguments}');

    // Execute the tool (call your weather service here)
    final args =
        jsonDecode(toolCall.function.arguments) as Map<String, Object?>;
    final result = {'location': args['location'], 'temperature': 18};

    toolResults.add(
      Message.tool(
        content: jsonEncode(result),
        toolCallId: toolCall.id,
        toolName: toolCall.function.name, // Gemini matches results by name
      ),
    );
  }

  // Continue the conversation with one result per tool call
  final finalResponse = await modelWithTools.generate([
    question,
    response, // Assistant message with tool calls
    ...toolResults,
  ]);

  print(finalResponse.content);
}
```

To run the tools automatically, give them to a `ToolsNode` (compose) or to the ADK `ChatModelAgent`.

### Tool Choice Control

`ToolChoice` has three values: `forbidden` (Gemini `NONE`), `allowed` (`AUTO`) and `forced` (`ANY`). `allowedToolNames` narrows the tools the model may call (with `allowed` the mode becomes `VALIDATED`; with `forced` it stays `ANY`).

```dart
// Force tool use
final response = await modelWithTools.generate(
  messages,
  options: const ChatModelOptions(
    toolChoice: ToolChoice.forced, // ANY - must use a tool
  ),
);

// Force one particular tool
final response2 = await modelWithTools.generate(
  messages,
  options: const ChatModelOptions(
    toolChoice: ToolChoice.forced,
    allowedToolNames: ['get_weather'], // must be a bound tool
  ),
);

// Allow but don't require tools (the default with bound tools)
final response3 = await modelWithTools.generate(
  messages,
  options: const ChatModelOptions(
    toolChoice: ToolChoice.allowed, // AUTO - model decides
  ),
);

// Disable tools
final response4 = await modelWithTools.generate(
  messages,
  options: const ChatModelOptions(
    toolChoice: ToolChoice.forbidden, // NONE - no tool use
  ),
);
```

### Using with the legacy `Agent` (ReAct loop)

`Agent` and `AgentConfig` of the umbrella library are the ReAct loop threepio had before the Eino port; they still work. Its Eino-shaped replacement is `ChatModelAgent` with `Runner` from `package:threepio_core/adk.dart` (see [MIGRATION.md](MIGRATION.md)), which takes the same tools.

```dart
import 'dart:convert';

import 'package:threepio_core/threepio_core.dart';

// A tool the model can call
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
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final args = jsonDecode(argumentsJson) as Map<String, Object?>;
    final expression = args['expression']! as String;
    // Two operands and one operator are enough for this example
    final match = RegExp(r'^\s*(-?[\d.]+)\s*([-+*/])\s*(-?[\d.]+)\s*$')
        .firstMatch(expression);
    if (match == null) return 'Cannot evaluate "$expression"';
    final a = double.parse(match.group(1)!);
    final b = double.parse(match.group(3)!);
    final result = switch (match.group(2)) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      _ => a / b,
    };
    return result.toString();
  }
}

Future<void> runCalculatorAgent(ToolCallingChatModel model) async {
  // register takes effect at once (await registry.findTool(name) to look
  // a tool up by name)
  final registry = ToolRegistry();
  registry.register(CalculatorTool());

  final agent = Agent(
    model: model,
    toolRegistry: registry,
    config: const AgentConfig(
      maxIterations: 5, // model calls (default 10)
      maxToolCalls: 10, // tool calls in all (default 20)
    ),
  );

  // Run agent
  final response = await agent.run([
    Message.system('You are a helpful assistant with a calculator.'),
    Message.user('What is 25 * 4?'),
  ]);

  print(response.content); // "25 multiplied by 4 is 100."
}
```

### Error Handling

```dart
try {
  final response = await model.generate(messages);
  print(response.content);
} on GeminiException catch (e) {
  print('API Error: ${e.message}');
  print('Status Code: ${e.statusCode}');
  print('Error Code: ${e.code}');
  print('Status: ${e.status}');

  // 408, 429, 5xx, RESOURCE_EXHAUSTED, UNAVAILABLE, DEADLINE_EXCEEDED,
  // timeouts and transport failures (not on the Imagen path)
  if (e.isRetryable) {
    print('Worth retrying');
  }
} on CancelledException {
  print('The call was cancelled');
} on ThreepioException catch (e) {
  // A prompt the safety filter blocked: "Content blocked: <reason>"
  print('No answer: ${e.message}');
}

// Or let RetryingChatModel retry the retryable failures with back-off
final resilient = RetryingChatModel(model, maxAttempts: 5);
final reply = await resilient.generate(messages);
print(reply.content);
```

`GeminiException` implements `ChatModelException` (`isRetryable`, `isModelUnavailable`), which `RetryingChatModel` reads: it retries `isRetryable` errors unless they are `isModelUnavailable`. `FailoverChatModel` switches to its fallback on any error except a cancellation, unless you pass a `shouldFailover`. A stream throws HTTP and transport failures from `stream()` itself; an error chunk, a blocked prompt or a malformed chunk ends the reader with the exception.

---

## 2. Agent Development Kit (ADK)

This section describes the umbrella library's older agents: the event-streaming ReAct agent `LegacyChatModelAgent`, `PlanExecuteAgent`, `SupervisorAgent` and `WorkflowAgent`. They implement `BaseAgent`: `run` returns a `StreamReader<AgentEvent>` at once and runs the agent in the background, `invoke` waits for the final message. They still work in 0.9; new code should not start with them.

> **Eino-shaped equivalent:** `package:threepio_core/adk.dart`, imported `as adk` next to the umbrella: `adk.ChatModelAgent` with `adk.Runner` for the ReAct agent, `adk.PlanExecute` for plan-execute-replan, `adk.DeepAgent` (which delegates to sub-agents) in place of the supervisor, `adk.AgentTool` for an agent used as a tool. Eino's workflow agents are not ported (Eino marks them not recommended), so `WorkflowAgent` has no direct replacement: run agents from the nodes of a compose `Graph` or `Workflow`, or keep it. See [MIGRATION.md](MIGRATION.md).

The ReAct agent that earlier versions of this page called `ChatModelAgent` is `LegacyChatModelAgent`, configured with `LegacyChatModelAgentConfig`: in the umbrella library, `ChatModelAgent` and `ChatModelAgentConfig` are the Kortney runtime, which runs through its `Runner`.

### LegacyChatModelAgent (ReAct Pattern)

The simplest agent type: it calls the model, runs the tools the model asks for, and repeats until the model answers without tool calls.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

// A tool the agent can call.
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
    return performSearch(query); // your search backend
  }
}

Future<void> runResearchAgent(ToolCallingChatModel geminiModel) async {
  final registry = ToolRegistry();
  registry.register(SearchTool());

  final agent = LegacyChatModelAgent(
    name: 'research-agent',
    description: 'An agent that researches topics',
    model: geminiModel,
    toolRegistry: registry,
    systemPrompt: 'You are a helpful research assistant.',
    // Defaults: 10 iterations, 50 tool calls, partial outputs on
    config: const LegacyChatModelAgentConfig(
      maxIterations: 5,
      maxToolCalls: 20,
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
        case AgentActionEvent(action: ToolCallAction(:final toolName)):
          print('Calling tool: $toolName');
        case ToolResultEvent(:final result):
          print('Tool result: $result');
        case AgentOutputEvent(:final message, isPartial: true):
          stdout.write(message.content); // partial output
        case AgentOutputEvent(:final message):
          print('Final answer: ${message.content}');
        case AgentErrorEvent(:final error):
          print('Error: $error');
        case AgentRunEndEvent():
          print('Agent completed');
        case _:
          break;
      }
    }
  } on StreamEOFException {
    // Stream complete
  } finally {
    await reader.close();
  }

  // Or get the final result directly
  final result = await agent.invoke([
    Message.user('What is 2 + 2?'),
  ]);
  print(result.content);
}
```

`AgentEvent` is a sealed class with more subclasses than the agent emits, so a `switch` over it needs the `case _` line.

### PlanExecuteAgent

Asks a planner model for a plan, then runs each step with the executor agent the step names, and replans when a step fails. A step fails only when its executor's `invoke` throws (no executor found, a cancellation, an agent of your own); the agents on this page never throw from `invoke` (see [Error Handling](#error-handling-1)), so their failures come back as an empty step result, not as a replan.

```dart
final planAgent = PlanExecuteAgent(
  name: 'plan-execute-agent',
  description: 'Plans a task, then runs each step with an executor',
  plannerModel: geminiModel, // any BaseChatModel
  executors: {
    'search': searchAgent,
    'analyze': analyzeAgent,
    'summarize': summaryAgent,
  },
  // Replans after a failed step by default (replanOnError)
  config: const PlanExecuteConfig(
    maxReplanAttempts: 2,
    maxStepsPerPlan: 5,
  ),
);

final reader = await planAgent.run([
  Message.user('Research and summarize the top 3 AI trends of 2024'),
]);

await for (final event in reader.asStream()) {
  switch (event) {
    case AgentStateUpdateEvent(:final stateName, :final newValue):
      print('$stateName: $newValue'); // phase: planning, current_step: step_1, …
    case AgentActionEvent(action: ThinkAction(:final thought)):
      print(thought); // "Created plan with 3 steps: …"
    case AgentOutputEvent(:final message):
      print('Step result: ${message.content}');
    case AgentRunEndEvent(:final outputMessage):
      print('Result: ${outputMessage.content}');
    case _:
      break;
  }
}
```

Without `plannerSystemPrompt`, the planner is told the executor names and asked for a JSON plan whose steps name their executor (`"agent"`). A custom `plannerSystemPrompt` replaces that text, so to route steps to executors it has to ask for the same JSON (any other reply becomes steps from its numbered lines, or one step of the whole reply, all sent to `defaultExecutor`); a step that names no known executor goes to `defaultExecutor`, and fails (which makes the agent replan) when there is none. `maxStepsPerPlan` is only stated in the default prompt, not enforced, and `replanOnFeedback` is not read in 0.9.

### SupervisorAgent

Delegates tasks to worker agents. The supervisor's model gets one tool per worker and a tool to finish; `maxDelegations` bounds the number of worker calls (checked before each model call); reaching it ends the run with an `AgentErrorEvent`.

```dart
// Create tool registries for workers
final researchRegistry = ToolRegistry();
researchRegistry.register(SearchTool());

final emptyRegistry = ToolRegistry(); // For agents without tools

// Create worker agents
final researchWorker = LegacyChatModelAgent(
  name: 'researcher',
  description: 'A research specialist',
  model: geminiModel,
  toolRegistry: researchRegistry,
  systemPrompt: 'You are a research specialist.',
);

final writerWorker = LegacyChatModelAgent(
  name: 'writer',
  description: 'A professional writer',
  model: geminiModel,
  toolRegistry: emptyRegistry,
  systemPrompt: 'You are a professional writer.',
);

// Create supervisor
final supervisor = SupervisorAgent(
  name: 'project-manager',
  description: 'Coordinates research and writing',
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
  // allowDirectResponse and trackHistory are on by default
  config: const SupervisorConfig(
    maxDelegations: 5,
  ),
);

final result = await supervisor.invoke([
  Message.user('Create a blog post about renewable energy'),
]);
print(result.content);
```

### WorkflowAgent

Runs a fixed sequence of agents.

```dart
final workflow = WorkflowAgent(
  name: 'content-pipeline',
  description: 'Research, outline, write and review an article',
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
      // Skipped when the outline step produced no text
      condition: (messages) => messages.last.content.isNotEmpty,
    ),
    WorkflowStep(
      name: 'review',
      agent: reviewAgent,
    ),
  ],
  // WorkflowConfig(mode: WorkflowMode.sequential) is the default
);

// Execute workflow
final result = await workflow.invoke([
  Message.user('Write an article about climate change'),
]);
print(result.content);
```

Each step gets the messages so far (the input followed by the earlier steps' outputs), or what its `inputTransform` makes of them; `condition` sees the same list. `outputTransform` replaces that list with what it returns. The workflow's result is the last step's output.

### Parallel Workflow

```dart
final parallelWorkflow = WorkflowAgent(
  name: 'parallel-research',
  description: 'Searches three sources at once',
  steps: [
    WorkflowStep(name: 'search-web', agent: webSearchAgent),
    WorkflowStep(name: 'search-papers', agent: paperSearchAgent),
    WorkflowStep(name: 'search-news', agent: newsSearchAgent),
  ],
  config: const WorkflowConfig(
    mode: WorkflowMode.parallel,
  ),
);

final combined = await parallelWorkflow.invoke([
  Message.user('Recent results on solid-state batteries'),
]);
print(combined.content); // "## search-web\n…\n\n## search-papers\n…"
```

Every step gets the workflow's input; the result is one assistant message with a `## <step name>` section per step. In 0.9 `WorkflowConfig.parallelLimit` does not limit how many steps run at once (all start together), and `stopOnFirstError` has no effect: a failing step fails the run either way, once the steps running with it have ended. A step fails only when its agent's `invoke` throws, which the agents on this page do not do: their failures come back as an empty section.

### Loop Workflow

```dart
final iterativeWorkflow = WorkflowAgent(
  name: 'refinement-loop',
  description: 'Generates, evaluates and refines a draft',
  steps: [
    WorkflowStep(name: 'generate', agent: generatorAgent),
    WorkflowStep(name: 'evaluate', agent: evaluatorAgent),
    WorkflowStep(name: 'refine', agent: refinerAgent),
  ],
  config: WorkflowConfig(
    mode: WorkflowMode.loop,
    maxLoopIterations: 5,
    // Called after each pass with the last step's output; true runs another pass.
    loopCondition: (result, iteration) =>
        !result.content.contains('APPROVED'),
  ),
);
```

Without a `loopCondition` the steps run once.

### Wrapping Agents as Tools

```dart
// Create a specialized agent
final factChecker = LegacyChatModelAgent(
  name: 'fact-checker',
  description: 'Verifies statements',
  model: geminiModel,
  toolRegistry: ToolRegistry(),
  systemPrompt: 'You verify facts and return true/false with explanation.',
);

// Wrap as a tool
final factCheckTool = factChecker.asTool(
  toolName: 'verify_fact',
  toolDescription: 'Verify if a statement is factually correct',
  inputParameter: 'statement',
);

// Use in another agent
final mainAgent = LegacyChatModelAgent(
  name: 'assistant',
  description: 'A general assistant',
  model: geminiModel,
  toolRegistry: ToolRegistry(tools: [factCheckTool, searchTool]),
);

final answer = await mainAgent.invoke([
  Message.user('Is the Great Wall of China visible from space?'),
]);
print(answer.content);
```

`asTool` returns the umbrella's `AgentTool` (`AgentTool(agent: factChecker, toolName: …, toolDescription: …)` does the same). The tool's one argument is `inputParameter` (default `query`); the agent receives it as a user message, and the tool returns the agent's final text.

### Agent Run Context

```dart
final context = AgentRunContext(
  runId: 'run-123',
  metadata: {'user_id': 'user-456'},
  onEvent: (event) {
    // LegacyChatModelAgent reports its start and end events here
    print('Event: ${event.eventType}');
  },
  shouldCancel: () {
    // Polled between steps; when and how often depends on the agent
    return userCancelledRequest;
  },
);

final result = await agent.invoke(messages, context: context);
print(result.content);
```

Steps of a workflow, plan or supervisor get a child of the context (`context.child(...)`) with the same `shouldCancel`. `AgentRunContext` also has `maxIterations` and `timeout`; no agent reads them in 0.9, so set limits in the agent's own configuration.

### Error Handling

These agents do not throw what goes wrong during a run. They send an `AgentErrorEvent` and end the stream; `invoke` then returns the last complete output, or an empty assistant message. Read the events to find out:

```dart
final reader = await agent.run(messages);

await for (final event in reader.asStream()) {
  if (event is AgentErrorEvent) {
    // isRecoverable: the agent goes on (a plan-execute agent replans)
    final outcome = event.isRecoverable ? 'Recovered' : 'Failed';
    print('$outcome: ${event.error}');
  }
}
```

`error` is the text of the exception, for example `PlanningException: No executor found for agent: default (agent: …) [run: …]`; a cancellation through `shouldCancel` reads `AgentCancelledException: …`. The exception classes (`ToolExecutionException`, `PlanningException`, `WorkflowException`, `AgentCancelledException`, …) are exported, but no agent rethrows them out of `run` or `invoke`.

---

## 3. Checkpoint & Resume System

This section is about the state graph that predates the 0.9 port (`StateGraph`, `GraphState`, `CheckpointConfig`). It still works.

> **Eino-shaped equivalent:** a compose `Graph` compiled with a `CheckpointStore` (`compose.dart`; `FileCheckpointStore` is in `io.dart`): a node stops the run with `interrupt` or `statefulInterrupt`, the run ends with a `GraphInterruptedException`, and invoking the graph again with the same checkpoint id resumes it. See [GRAPHS.md](GRAPHS.md) and [MIGRATION.md](MIGRATION.md).

Since 0.9 the umbrella library no longer exports the five checkpoint classes of the state graph whose names the compose port uses: `CheckpointStore`, `CheckpointSerializer`, `JsonCheckpointSerializer`, `InMemoryCheckpointStore` and `FileCheckpointStore`. Import them from `package:threepio_core/legacy_graph.dart`, with a prefix when the umbrella is imported too. Everything else used below (`StateGraph`, `GraphState`, `CheckpointConfig`, `CheckpointStoreConfig`, `Checkpoint`, `GraphInterruptException`, `HumanInputNode`, `HumanInputRequired`, `END`) is in the umbrella as before.

### Defining the State

The examples of this section share this state.

```dart
import 'package:threepio_core/threepio_core.dart';

class WorkflowState extends GraphState {
  WorkflowState({
    this.document,
    this.analysis,
    this.review,
    this.approved = false,
  });

  factory WorkflowState.fromMap(Map<String, dynamic> map) => WorkflowState(
        document: map['document'] as String?,
        analysis: map['analysis'] as String?,
        review: map['review'] as String?,
        approved: map['approved'] as bool? ?? false,
      );

  final String? document;
  final String? analysis;
  final String? review;
  final bool approved;

  @override
  WorkflowState copyWith({
    String? document,
    String? analysis,
    String? review,
    bool? approved,
  }) =>
      WorkflowState(
        document: document ?? this.document,
        analysis: analysis ?? this.analysis,
        review: review ?? this.review,
        approved: approved ?? this.approved,
      );

  Map<String, dynamic> toMap() => {
        'document': document,
        'analysis': analysis,
        'review': review,
        'approved': approved,
      };
}
```

### Basic Checkpoint Configuration

```dart
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

// Configure checkpointing
const checkpointConfig = CheckpointConfig(
  interruptAfter: ['analyze'], // Pause after these nodes
  checkpointEveryNode: true,   // Save after each step
  autoSave: true,              // Save interrupt checkpoints to the store
  // checkpointOnError (save when a node throws) is on by default
);

// Create checkpoint store
final store = legacy.InMemoryCheckpointStore<WorkflowState>();

// Or use file-based persistence
final fileStore = legacy.FileCheckpointStore<WorkflowState>(
  directory: '/path/to/checkpoints',
  serializer: legacy.JsonCheckpointSerializer<WorkflowState>(
    stateToJson: (state) => state.toMap(),
    stateFromJson: WorkflowState.fromMap,
  ),
  config: const CheckpointStoreConfig(
    maxCheckpointsPerThread: 50, // oldest are dropped; default 100
    compressData: true, // gzip; FileCheckpointStore only
  ),
);
```

`CheckpointConfig` also takes `interruptBefore`. In 0.9 a checkpoint taken by `interruptBefore` cannot be resumed with `invoke(checkpointId: …)`: the resumed run stops before the same node again. Pause with `interruptAfter` on the node before it, or use a human input node (below). `CheckpointStoreConfig.ttl` is not applied by either store.

### Creating a Checkpointable Graph

```dart
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

StateGraph<WorkflowState> buildReviewGraph(
  legacy.CheckpointStore<WorkflowState> store,
) {
  final graph = StateGraph<WorkflowState>(
    checkpointConfig: const CheckpointConfig(
      interruptAfter: ['analyze'], // pause once the analysis is ready
      autoSave: true,
    ),
    checkpointStore: store,
  );

  graph.addNode('generate', (state) async {
    final doc = await generateDocument();
    return state.copyWith(document: doc);
  });

  graph.addNode('analyze', (state) async {
    final analysis = await analyzeDocument(state.document!);
    return state.copyWith(analysis: analysis);
  });

  // Stops the run until someone approves or rejects (see below)
  graph.addHumanInputNode(
    HumanInputNode<WorkflowState, bool>(
      name: 'human_review',
      prompt: (state) => 'Approve this analysis? ${state.analysis}',
      processInput: (state, approved) => state.copyWith(approved: approved),
    ),
  );

  graph.addNode('finalize', (state) async {
    return state.copyWith(review: 'Approved and finalized');
  });

  graph.addEdge('generate', 'analyze');
  graph.addEdge('analyze', 'human_review');
  graph.addConditionalEdge(
    'human_review',
    (state) => state.approved ? 'finalize' : 'generate',
  );
  graph.addEdge('finalize', END); // Use END constant

  graph.setEntryPoint('generate');
  return graph;
}
```

### Executing with Checkpoints

```dart
final store = legacy.InMemoryCheckpointStore<WorkflowState>();
final graph = buildReviewGraph(store);
const threadId = 'user-123-workflow-1';

try {
  await graph.invoke(WorkflowState(), threadId: threadId);
} on GraphInterruptException<WorkflowState> catch (e) {
  // Execution paused after 'analyze'; the checkpoint is in the store
  print('Paused at: ${e.checkpoint.currentNode}');
  print('Checkpoint ID: ${e.checkpoint.id}');
  print('Reason: ${e.reason}');
}
```

### Resuming from Checkpoint

```dart
// Later: load the thread's latest checkpoint and go on from there
final checkpoint = await store.loadLatest(threadId: threadId);

if (checkpoint != null) {
  try {
    final result = await graph.invoke(
      WorkflowState(), // ignored: the state comes from the checkpoint
      threadId: threadId,
      checkpointId: checkpoint.id,
    );
    print('Workflow completed: ${result.state.review}');
  } on HumanInputRequired<WorkflowState, Object?> catch (e) {
    // The run reached 'human_review' and waits for a decision
    print(e.prompt);
    await notifyUserForApproval(threadId, e.checkpoint.id!);
  }
}
```

A run resumed from a checkpoint taken after a node (`interruptAfter`, or `autoSave` between nodes) goes on with the next node. A checkpoint taken before a node (`interruptBefore`) cannot be resumed at present: the resumed run stops in front of the same node again (a known bug of the legacy graph), so interrupt after the previous node instead. `invoke(checkpointId:)` throws `CheckpointIncompatibleException` for a human-input checkpoint (use `resumeWithHumanInput`), and a checkpoint saved because a node threw resumes after that node, with the state from before it, so the failed node does not run again. Catch `HumanInputRequired` with `Object?` (or `dynamic`) as its second type argument: the graph rethrows it as `HumanInputRequired<S, dynamic>`, which `on HumanInputRequired<WorkflowState, bool>` does not match. For the same reason a human input node with a `validator` makes the run fail with a `TypeError` instead of `HumanInputRequired` (a known bug of the legacy graph): validate the answer before `resumeWithHumanInput` instead.

### Human-in-the-Loop Pattern

A human input node stops the run with `HumanInputRequired` and saves a checkpoint (with `autoSave`). `resumeWithHumanInput` hands the answer to the node's `processInput` and runs the rest of the graph:

```dart
Future<void> handleUserApproval(
  StateGraph<WorkflowState> graph,
  String checkpointId,
  String threadId, {
  required bool approved,
}) async {
  final result = await graph.resumeWithHumanInput<bool>(
    checkpointId,
    input: approved,
    threadId: threadId,
  );
  print('Review: ${result.state.review}');
}
```

A rejection (`approved: false`) leads back to `generate` through the conditional edge, so `resumeWithHumanInput` ends with a `GraphInterruptException` after `analyze` again; catch it as in [Executing with Checkpoints](#executing-with-checkpoints).

### Checkpoint History and Management

```dart
// List all checkpoints for a thread
final checkpoints = await store.list(threadId: 'user-123');
for (final metadata in checkpoints) {
  print('${metadata.id}: ${metadata.currentNode} at ${metadata.timestamp}');
}

// Get checkpoint history (newest first)
final history = await store.getHistory(
  threadId: 'user-123',
  limit: 10,
  after: DateTime.now().subtract(const Duration(hours: 1)),
);
for (final checkpoint in history) {
  print('${checkpoint.currentNode} (step ${checkpoint.iteration})');
}

// Delete old checkpoints
await store.delete(oldCheckpointId, threadId: 'user-123');

// Clear all checkpoints for a thread
await store.clear(threadId: 'user-123');

// Count checkpoints
final count = await store.count(threadId: 'user-123');
print('Checkpoints left: $count');
```

### Custom State Serialization

`FileCheckpointStore` writes checkpoints through a `legacy.CheckpointSerializer`. `legacy.JsonCheckpointSerializer` writes the checkpoint as JSON and needs the two state conversions:

```dart
final serializer = legacy.JsonCheckpointSerializer<WorkflowState>(
  stateToJson: (state) => state.toMap(),
  stateFromJson: WorkflowState.fromMap,
);

final bytes = await serializer.serialize(checkpoint);
final restored = await serializer.deserialize(bytes);
print(restored.state.document);
```

For another format, implement `legacy.CheckpointSerializer<S>` (`serialize`, `deserialize` and `contentType`). Earlier versions of this page declared a class of that name of their own; it would now hide the real one.

---

## 4. Advanced Retrieval Patterns

> **Eino-shaped equivalent:** Eino's `flow` retrievers are static `fromConfig` methods of the same classes, each returning a plain `Retriever` (`MultiQueryRetriever.fromConfig`, asynchronous; `ParentRetriever.fromConfig`; `RouterRetriever.fromConfig`), with `ParentIndexer` and `concurrentRetrieve` (`flow.dart`). `HybridRetriever` and the fusion and deduplication strategies have no Eino counterpart. See [RAG.md](RAG.md).

The classes of this section are threepio's own retrievers, exported by the umbrella library.

### HybridRetriever

Combines semantic (vector) and keyword (BM25) search. The two result lists are fused (by default with `WeightedScoreFusion`) and deduplicated by document id, so both sides must know a document by the same id.

```dart
import 'package:threepio_core/threepio_core.dart';

// Vector side: `vectorStore` already holds `documents` with their embeddings
final vectorRetriever = VectorRetriever(
  embedder: openAIEmbedder,
  vectorStore: vectorStore,
);

// Keyword side: BM25 over the same documents
final keywordSearcher = InMemoryBM25Searcher(
  k1: 1.5,  // Term frequency saturation
  b: 0.75,  // Length normalization
);
await keywordSearcher.addDocuments(documents);

// Create hybrid retriever
final hybridRetriever = HybridRetriever(
  vectorRetriever: vectorRetriever,
  keywordSearcher: keywordSearcher,
  vectorWeight: 0.7,    // 70% semantic
  keywordWeight: 0.3,   // 30% keyword
  normalizeScores: true,
  deduplicationStrategy: const IdDeduplication(),
);

// Retrieve
final results = await hybridRetriever.retrieve(
  'machine learning algorithms',
  options: const RetrieverOptions(topK: 10),
);
print('${results.length} documents');

// With the fused scores
final scoredResults = await hybridRetriever.retrieveWithScores(
  'machine learning algorithms',
);

for (final result in scoredResults) {
  print(result.document.content);
  print('  Found by: ${result.metadata['sources']}'); // e.g. [vector, keyword]
  print('  Combined score: ${result.score}');
}
```

A fused result's `ScoredDocument.metadata` holds `fusion_method`, `source_count` and `sources`; there are no separate vector and keyword scores.

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
  options: const RetrieverOptions(topK: 10),
);
print('${results.length} documents');

// With the fusion details: how many of the queries found each document
final scored = await multiQueryRetriever.retrieveWithScores(
  'What are the benefits of renewable energy?',
);
for (final result in scored) {
  print('${result.document.id}: found by ${result.metadata['source_count']} queries');
}
```

The generated queries themselves are not returned; no retriever writes a `generated_queries` entry.

### ParentRetriever

Searches chunks but returns full parent documents.

```dart
// Create parent document store
final parentStore = InMemoryParentDocumentStore();

// Embeds the chunks and writes them to the vector store
final indexer = VectorStoreIndexer(vectorStore: vectorStore, embedder: embedder);

// Index documents with their chunks
for (final document in documents) {
  // Split into chunks with the ids '<parent id>_chunk_<n>' and record
  // the parent of each chunk
  final chunks = await parentStore.indexDocument(
    document,
    (text) => splitter.splitText(
      text,
      options: const TextSplitterOptions(chunkSize: 400, chunkOverlap: 40),
    ),
  );

  // Add chunks to the vector store (for searching)
  await indexer.store(RunContext.background(), chunks);
}

// Create parent retriever
final parentRetriever = ParentRetriever(
  baseRetriever: VectorRetriever(embedder: embedder, vectorStore: vectorStore),
  parentStore: parentStore,
  returnChunks: false,           // Return parents, not chunks
  includeChunkMetadata: true,    // Add chunk info to parent
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

The parent store finds a chunk's parent by the chunk's id, so chunks need their ids before they reach the vector store: `indexDocument` (an extension on `ParentDocumentStore`) gives them ids and records the relation. A chunk stored without an id gets a new one (from `VectorStoreIndexer` or the store) and then comes back as itself instead of its parent. Each parent is returned once (the `deduplicateParents` setting has no effect).

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

// Route by keywords
final keywordRoutingStrategy = KeywordRoutingStrategy(
  routeKeywords: {
    'technical': ['code', 'api', 'programming', 'bug', 'feature'],
    'hr': ['vacation', 'salary', 'benefits', 'leave', 'policy'],
    'legal': ['contract', 'agreement', 'liability', 'compliance'],
  },
  matchThreshold: 1,
);

// Or let the LLM route
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
  routingStrategy: llmRoutingStrategy, // or keywordRoutingStrategy
  fallbackRetriever: generalRetriever, // when no route is selected
  allowMultipleRoutes: true,
  maxRoutes: 2,
);

final results = await routerRetriever.retrieve(
  'What is the vacation policy for engineering contractors?',
);

// Query routed to 'hr' and possibly 'legal'; results of several routes
// are fused with Reciprocal Rank Fusion
print('${results.length} documents');
```

### Result Fusion Strategies

```dart
// Reciprocal Rank Fusion (default of the multi-query and router retrievers)
const rrfFusion = ReciprocalRankFusion(k: 60.0);

// Weighted Score Fusion (default of the hybrid retriever)
const weightedFusion = WeightedScoreFusion(
  weights: [0.6, 0.4],  // Weights for each result set
  normalizeScores: true,
);

// Union Fusion (combine all unique documents)
const unionFusion = UnionFusion(
  keepHighestScore: true,
);

// Use with hybrid retriever
final retriever = HybridRetriever(
  vectorRetriever: vectorRetriever,
  keywordSearcher: keywordSearcher,
  fusionStrategy: rrfFusion,
);

// Or fuse result sets of your own
final fused = unionFusion.fuse([firstResults, secondResults]);
```

### Deduplication Strategies

```dart
// By document ID
const idDedup = IdDeduplication(
  useContentHashAsFallback: true,
);

// By content
const contentDedup = ContentDeduplication(
  normalizeWhitespace: true,
  caseSensitive: false,
);

// By custom key (the extractor gets the scored document)
final keyDedup = KeyDeduplication<String>(
  keyExtractor: (scored) => scored.document.metadata['source'] as String?,
);

// Composite (apply multiple strategies)
const compositeDedup = CompositeDeduplication([
  IdDeduplication(),
  ContentDeduplication(),
]);

// Use one with a retriever, or on scored documents directly
final retriever = HybridRetriever(
  vectorRetriever: vectorRetriever,
  keywordSearcher: keywordSearcher,
  deduplicationStrategy: compositeDedup,
);
final unique = await keyDedup.deduplicate(scoredResults);
```

`SemanticDeduplication(embedder: embedder, similarityThreshold: 0.95)` also drops near-duplicates by embedding similarity.

---

## 5. Document Processing Pipeline

> **Eino-shaped equivalent:** the Eino document contracts of `components.dart`: `Loader` (`UrlContentLoader`; `FileLoader` in `io.dart`), `Parser` (`TextParser`, `ExtParser`, `HtmlContentParser`, `PdfParser`, `DocxParser`, `XlsxParser`), `DocumentTransformer` and `Indexer` (`VectorStoreIndexer`, `QdrantIndexer`), composed in a `Graph` or `Chain`; `LoaderAdapter` and `DocumentParser.asParser()` adapt the loaders and parsers of this section. See [RAG.md](RAG.md).

### Ingestion Pipeline

End-to-end document processing from loading to vector storage: `ingest` loads (unless you pass `documents:`), applies the transformers in order, splits, embeds in batches and stores.

```dart
import 'package:threepio_core/threepio_core.dart';

// Create pipeline components
final loader = DirectoryLoader(
  dirPath: '/path/to/documents',
  glob: '**/*.md', // understood: '*.txt', '*.md' and '*.*' patterns
  recursive: true,
);

final splitter = RecursiveCharacterTextSplitter();

// Create pipeline: load, transform, split, embed, store
final pipeline = IngestionPipeline(
  loader: loader,
  splitter: splitter,
  embedder: embedder,
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
      'source_kind': 'documentation',
    }),
    // Filter documents
    FilterTransformer(
      predicate: (doc) => doc.content.length > 50,
    ),
  ],
);

// Run ingestion
final result = await pipeline.ingest(
  options: const IngestionOptions(
    batchSize: 100,
    splitterOptions: TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200),
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
    print('Error in ${error.stage.name}: ${error.message}');
  }
}
```

Things to know:

* The pipeline does not parse. `IngestionPipeline` accepts a `parser`, but neither `ingest` nor `ingestStream` calls it. Parse first (see [Document Parsers](#document-parsers)) and pass the result with `pipeline.ingest(documents: parsedDocuments)`.
* `DirectoryLoader` understands only the patterns `*.txt`, `*.md` and `*.*` in its `glob`; anything else loads `.txt` files.
* `MetadataTransformer`, `ContentCleanerTransformer` and `IngestionOptions.metadata` rebuild each document without its `id` and embedding. Give documents their ids after those steps.

### Streaming Ingestion with Progress

```dart
final progressStream = pipeline.ingestStream(
  options: const IngestionOptions(batchSize: 50),
);

await for (final progress in progressStream) {
  print('${progress.stage.name}: ${progress.current}/${progress.total}');
  print('  ${progress.message}');
  print('  Progress: ${progress.percentage.toStringAsFixed(1)}%');

  if (progress.stage == IngestionStage.complete) {
    print('Ingestion complete!');
  }
}
```

The progress events carry no `IngestionResult`; call `ingest` when you need the counts and the errors. `ingestStream` ignores `continueOnError`: the first failure ends the stream with its exception, so wrap the `await for` in a `try`.

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
print('Title: ${htmlResult.document.metadata['title']}');
print('Content: ${htmlResult.document.content}');

// With table extraction (an option of the call)
final result = await htmlParser.parseString(
  htmlWithTables,
  options: const DocumentParserOptions(extractTables: true),
);
for (final table in result.extractedTables ?? const <ExtractedTable>[]) {
  print('Table: ${table.caption}');
  print(table.toMarkdown());
}

// Markdown Parser
final mdParser = MarkdownParser(
  parseFrontmatter: true,
  removeFrontmatter: true,
  extractCodeBlocks: true,
);

const fence = '```'; // the code fence inside the sample text
const mdContent = '''
---
title: My Document
author: John Doe
tags: [dart, flutter]
---

# Introduction

This is the content.

${fence}dart
void main() {
  print('Hello');
}
$fence
''';

final mdResult = await mdParser.parseString(mdContent);
print('Title: ${mdResult.document.metadata['title']}');
print('Author: ${mdResult.document.metadata['author']}');
print('Code blocks: ${mdResult.metadata?['code_block_count']}');
```

The title and the front matter are in the metadata of the parsed document (`result.document.metadata`); `ParseResult.metadata` holds the parser's own figures (`original_length`, `parsed_length`, `code_block_count`). Table extraction is an option of the call (`DocumentParserOptions.extractTables`), not of the constructor. `extractCodeBlocks` counts the fenced code blocks but does not return them. (The `fence` constant keeps the sample's code fence from ending this page's code block.)

### Custom Document Transformer

Since 0.9, `transform` takes `{TransformerOptions? options}`, which carry the run context of the call; an implementation must declare the parameter even when it does not use it.

```dart
import 'package:threepio_core/threepio_core.dart';

class SummarizationTransformer extends DocumentTransformer {
  const SummarizationTransformer({required this.model});

  final BaseChatModel model;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options, // required since 0.9
  }) async {
    final transformed = <Document>[];

    for (final doc in documents) {
      // Generate a summary; the model gets the run context of the call
      // (cancellation, callbacks)
      final response = await model.generate(
        [
          Message.system('Summarize the following text in 2-3 sentences.'),
          Message.user(doc.content),
        ],
        options: ChatModelOptions(runContext: options?.runContext),
      );

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

// Use in a pipeline
IngestionPipeline summarizingPipeline(BaseChatModel model, TextSplitter splitter) =>
    IngestionPipeline(
      splitter: splitter,
      transformers: [SummarizationTransformer(model: model)],
    );
```

---

## 6. Reranking System

> **Eino-shaped equivalent:** Eino has no reranker contract; a reranker there is a `document.Transformer`. `RerankerTransformer(reranker, query: …)` turns any reranker of this section into one, and `ScoreReorderTransformer` ports eino-ext's score reranker (best documents at both ends, nothing dropped).

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
  options: const RerankerOptions(topK: 5),
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

    var matches = 0;
    for (final term in queryTerms) {
      if (docTerms.contains(term)) matches++;
    }

    return matches / queryTerms.length;
  },
);

final results = await functionReranker.rerank(query, documents);
print(results.map((r) => r.score).toList());
```

### MMR Reranking (Diversity)

Maximal Marginal Relevance balances relevance and diversity.

```dart
final mmrReranker = MMRReranker(
  embedder: embedder,
  lambda: 0.7,  // 0.0 = max diversity, 1.0 = max relevance
);

// Picks documents that are relevant and diverse; the result is sorted by
// score, and metadata['mmr_rank'] keeps the MMR order
final diverseResults = await mmrReranker.rerank(
  query,
  documents,
  options: const RerankerOptions(topK: 10),
);
print('${diverseResults.length} documents');

// With pre-computed embeddings (no embedding calls for the documents).
// Both MMR rerankers read a document's vector from metadata['embedding'],
// not from Document.embedding.
final queryEmbedding = (await embedder.embedStrings([query])).first;
final precomputedReranker = PrecomputedMMRReranker(
  queryEmbedding: queryEmbedding,
  lambda: 0.7,
);
final withVectors = [
  for (final doc in documents)
    doc.copyWith(metadata: {...doc.metadata, 'embedding': doc.embedding}),
];
final fastResults = await precomputedReranker.rerank(query, withVectors);
print('${fastResults.length} documents');
```

`MMRReranker` uses `metadata['embedding']` when a document has it and otherwise embeds the documents one call at a time; `PrecomputedMMRReranker` throws for a document without it.

### Composite Reranking

Combine multiple reranking strategies.

```dart
final compositeReranker = CompositeReranker(
  rerankers: [
    ScoreReranker(normalize: true),      // Use retrieval scores
    functionReranker,                     // Custom scoring
    MMRReranker(embedder: embedder),     // Diversity
  ],
  weights: [0.4, 0.3, 0.3],  // One per reranker; each scales its scores
);

final results = await compositeReranker.rerank(
  query,
  documents,
  options: const RerankerOptions(
    topK: 10,
    threshold: 0.5,  // Minimum score
  ),
);
print('${results.length} documents');
```

### Cross-Encoder Reranking (with LLM)

Extend `BaseReranker` for its helpers: `applyFilters` applies the threshold, sorts by score and keeps the top k.

```dart
import 'package:threepio_core/threepio_core.dart';

class LLMReranker extends BaseReranker {
  LLMReranker({required this.model});

  final BaseChatModel model;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    final results = <RerankResult>[];

    for (var i = 0; i < documents.length; i++) {
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

    // Threshold, sort by score, top-k
    return applyFilters(results, options);
  }
}
```

---

## 7. Advanced Text Splitters

> **Eino-shaped equivalent:** the eino-ext splitters, built from their configurations: `RecursiveCharacterTextSplitter.fromConfig(RecursiveSplitterConfig(…))`, `MarkdownSplitter.fromHeaderConfig(MarkdownHeaderSplitterConfig(…))`, `HtmlSplitter.fromHeaderConfig(HtmlHeaderSplitterConfig(…))` and `SemanticSplitter(SemanticSplitterConfig(…))`, each a `DocumentTransformer` that splits as Eino does (the recursive and semantic splitters measure lengths in UTF-8 bytes). See [RAG.md](RAG.md).

The splitters of this section take the chunk size and overlap with each call, as `TextSplitterOptions` (defaults 1000 and 200), not in their constructors. `splitText` is synchronous, `splitDocuments` asynchronous. Every splitter is also a `DocumentTransformer`: `transform`, or `withOptions(TextSplitterOptions(…))` to fix the options once.

### HTML Splitter

Preserves HTML document structure when splitting.

```dart
import 'package:threepio_core/threepio_core.dart';

final htmlSplitter = HtmlSplitter(
  stripTags: true,          // Remove HTML tags from output
  preserveLinks: true,      // Keep URLs
  splitByHeaders: true,     // Not read in 0.9: headerTags always mark sections
  headerTags: ['h1', 'h2', 'h3'],  // Header levels to split on
);

// Chunk size and overlap are options of each call
const options = TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200);

const htmlContent = '''
<html>
<head><title>Documentation</title></head>
<body>
  <h1>Introduction</h1>
  <p>This is the introduction section with lots of content.</p>

  <h2>Getting Started</h2>
  <p>Here's how to get started.</p>

  <h2>Advanced Usage</h2>
  <p>For advanced users.</p>
</body>
</html>
''';

final chunks = htmlSplitter.splitText(htmlContent, options: options);

for (final chunk in chunks) {
  print('--- Chunk ---');
  print(chunk);
  print('');
}

// Split documents with metadata preservation
final documents = [
  const Document(content: htmlContent, metadata: {'source': 'docs.html'}),
];

final splitDocs = await htmlSplitter.splitDocuments(documents, options: options);
for (final doc in splitDocs) {
  print('Source: ${doc.metadata['source']}');
  print('Chunk index: ${doc.metadata['chunk_index']}');
}
```

### Markdown Splitter

Preserves Markdown structure and handles code blocks.

```dart
final mdSplitter = MarkdownSplitter(
  preserveCodeBlocks: true,   // Keep code blocks intact
  splitOnHeaders: true,       // Split at header boundaries
  minHeaderLevel: 1,          // Start splitting at h1
  maxHeaderLevel: 3,          // Don't split below h3
);

const fence = '```'; // the code fence inside the sample text
const markdownContent = '''
# Main Title

Introduction paragraph.

## Section 1

Content for section 1.

### Subsection 1.1

More detailed content.

${fence}python
def example():
    return "This code block stays together"
$fence

## Section 2

Content for section 2.
''';

final chunks = mdSplitter.splitText(
  markdownContent,
  options: const TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200),
);
print('${chunks.length} chunks');
```

### Markdown RAG Splitter

Optimized for RAG: each chunk records the headers above it.

```dart
final ragSplitter = MarkdownRAGSplitter(
  includeHeadersInChunks: true,   // Prepend the header line to each section
);

final chunks = await ragSplitter.splitDocuments(
  [Document(content: markdownContent)],
  options: const TextSplitterOptions(chunkSize: 500, chunkOverlap: 100),
);

for (final chunk in chunks) {
  print('Headers: ${chunk.metadata['header_breadcrumbs']}');
  print('Current: ${chunk.metadata['current_header']}');
  print('Content: ${chunk.content}');
  print('');
}
```

Each chunk's metadata has `header_breadcrumbs`, the titles of the enclosing headers (`[Main Title, Section 1, Subsection 1.1]` for the chunk under "Subsection 1.1"), and `current_header`, the header line itself (`### Subsection 1.1`); with `includeHeadersInChunks` the first chunk of each section starts with that line (a section longer than `chunkSize` is split further, and the later pieces do not). Text before the first header has neither key. The breadcrumbs are always recorded (the `addHeaderBreadcrumbs` setting has no effect).

### Combining Splitters with Pipeline

```dart
import 'package:threepio_core/threepio_core.dart';

// Pick a splitter by file type (`source` is set by the file loaders)
TextSplitter splitterFor(Document doc) {
  final source = doc.metadata['source'] as String? ?? '';
  if (source.endsWith('.html') || source.endsWith('.htm')) {
    return HtmlSplitter();
  } else if (source.endsWith('.md')) {
    return MarkdownRAGSplitter();
  }
  return RecursiveCharacterTextSplitter();
}

Future<List<Document>> splitByType(List<Document> documents) async {
  const options = TextSplitterOptions(chunkSize: 1000, chunkOverlap: 200);
  return [
    for (final doc in documents)
      ...await splitterFor(doc).splitDocuments([doc], options: options),
  ];
}

// In a pipeline: the splitter, and its options in the ingestion options
Future<IngestionResult> ingestMarkdown(
  List<Document> documents,
  Embedder embedder,
  VectorStore vectorStore,
) {
  final pipeline = IngestionPipeline(
    splitter: MarkdownRAGSplitter(includeHeadersInChunks: true),
    embedder: embedder,
    vectorStore: vectorStore,
  );
  return pipeline.ingest(
    documents: documents,
    options: const IngestionOptions(
      splitterOptions: TextSplitterOptions(chunkSize: 500, chunkOverlap: 50),
    ),
  );
}
```

---

## Complete RAG Application Example

Loads Markdown files, indexes the chunks for hybrid search, and answers questions with an Eino-shaped agent (`adk.ChatModelAgent` run by `adk.Runner`) that searches the knowledge base through a tool. It reads `GEMINI_API_KEY` (chat model) and `OPENAI_API_KEY` (embedder).

```dart
import 'dart:io';

import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// The input of the search tool, decoded from the JSON arguments the model
/// writes.
final class SearchQuery {
  const SearchQuery(this.query);

  factory SearchQuery.fromJson(Map<String, Object?> json) =>
      SearchQuery(json['query']! as String);

  final String query;
}

Future<void> main() async {
  // 1. Configure providers
  final env = Platform.environment;
  final model = GeminiChatModel(
    config: GeminiConfig(apiKey: env['GEMINI_API_KEY']!),
  );
  final embedder = OpenAIEmbedder(
    config: OpenAIConfig(apiKey: env['OPENAI_API_KEY']!),
  );
  final vectorStore = InMemoryVectorStore();

  try {
    // 2. Load, clean and split the documents
    final loaded = await DirectoryLoader(dirPath: './docs', glob: '**/*.md').load();
    final cleaned = await ContentCleanerTransformer().transform(loaded);
    final split = await MarkdownRAGSplitter(includeHeadersInChunks: true).splitDocuments(
      cleaned,
      options: const TextSplitterOptions(chunkSize: 500, chunkOverlap: 50),
    );
    // Both indexes must know a chunk by the same id
    final chunks = [
      for (var i = 0; i < split.length; i++) split[i].copyWith(id: 'chunk_$i'),
    ];

    // 3. Index the chunks for vector search (embed and store) and for
    //    keyword search
    print('Ingesting documents...');
    await VectorStoreIndexer(vectorStore: vectorStore, embedder: embedder)
        .store(RunContext.background(), chunks);
    final keywordSearcher = InMemoryBM25Searcher();
    await keywordSearcher.addDocuments(chunks);
    print('Indexed ${chunks.length} chunks');

    // 4. Hybrid retrieval, reranked for diversity
    final hybridRetriever = HybridRetriever(
      vectorRetriever: VectorRetriever(embedder: embedder, vectorStore: vectorStore),
      keywordSearcher: keywordSearcher,
      vectorWeight: 0.7,
      keywordWeight: 0.3,
    );
    final reranker = MMRReranker(embedder: embedder, lambda: 0.8);

    // 5. The search tool (Eino `utils.InferTool`)
    final searchTool = FunctionTool<SearchQuery, String>(
      name: 'search_knowledge',
      description: 'Search the knowledge base for relevant information',
      params: const ParamsOneOf.params({
        'query': ParameterInfo(type: DataType.string, desc: 'Search query', required: true),
      }),
      fromJson: SearchQuery.fromJson,
      invoke: (ctx, input, options) async {
        final docs = await hybridRetriever.retrieve(
          input.query,
          options: RetrieverOptions(topK: 10, runContext: ctx),
        );
        final reranked = await reranker.rerank(
          input.query,
          docs,
          options: const RerankerOptions(topK: 5),
        );
        return reranked
            .map((r) => '${r.document.metadata['current_header'] ?? 'Document'}:\n'
                '${r.document.content}')
            .join('\n\n---\n\n');
      },
    );

    // 6. The agent (Eino `adk.NewChatModelAgent`) and its runner
    final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
      name: 'rag-assistant',
      description: 'Answers questions from the knowledge base',
      instruction: '''
You are a helpful assistant with access to a knowledge base.
Use the search_knowledge tool to find relevant information before answering questions.
Always cite your sources.
''',
      model: model,
      toolsConfig: adk.ToolsConfig(
        toolsNode: adk.ToolsNodeConfig(tools: [searchTool]),
      ),
    ));
    final runner = adk.Runner(agent: agent);

    // 7. Run a conversation; the questions and answers are kept as history
    print('\nRAG Assistant ready. Type your questions:');
    final history = <Message>[];
    while (true) {
      stdout.write('\nYou: ');
      final input = stdin.readLineSync();
      if (input == null || input.isEmpty) break;
      history.add(Message.user(input));

      final events = runner.run(RunContext.background(), [...history]);
      for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
        if (e.error != null) {
          print('Error: ${e.error}');
          continue;
        }
        final message = await adk.getMessageFromEvent(e);
        if (message == null || message.role != RoleType.assistant) continue;
        if (message.toolCalls?.isNotEmpty ?? false) continue;
        print('\nAssistant: ${message.content}');
        history.add(message);
      }
    }
  } finally {
    model.dispose();
    embedder.dispose();
  }
}
```

The earlier version of this example used a `ChatModelAgent(name:, model:, tools:, systemPrompt:)` constructor, `InvokableTool.fromFunction` and `vectorStore.getAllDocuments()`, none of which exist; `FunctionTool` and the agent of `adk.dart` replace the first two, and the chunks are kept in a list instead of being read back from the store.

---

## Migration Guide

[MIGRATION.md](MIGRATION.md) covers everything that changed in 0.9. For the
features on this page, three of its intentional breaks matter:

1. **Checkpoint classes** of `StateGraph` (`InMemoryCheckpointStore<S>`,
   `FileCheckpointStore<S>`, `JsonCheckpointSerializer<S>`, …) come from
   `package:threepio_core/legacy_graph.dart`, imported `as legacy` next to the
   umbrella (section 3).
2. **A custom `DocumentTransformer`** declares the optional
   `{TransformerOptions? options}` parameter of `transform` (section 5).
3. **`ToolRegistry.register`** takes effect at once; look tools up with
   `await registry.findTool(name)` (sections 1 and 2).

The ReAct agent of section 2 is `LegacyChatModelAgent`: in the umbrella,
`ChatModelAgent` is the Kortney runtime. Earlier versions of this page used
names and parameters that do not exist (`ChatModelAgent(toolRegistry:)`,
`InvokableTool.fromFunction`, `MessageInputPart.audioUrl`, …); the examples
now use what exists.

---

## Best Practices

1. **Use streaming** for long-running operations to give users feedback.
2. **Start new code with the Eino-shaped APIs** (`adk.dart`, `compose.dart`,
   `flow.dart`); the features on this page stay for existing code.
3. **Configure checkpoints** for any workflow that may need a human decision.
4. **Combine retrieval strategies** (hybrid search and reranking) for better
   results.
5. **Use the splitter that fits the content** (HTML, Markdown, plain text).
6. **Monitor token usage** to keep costs down.
7. **Handle errors**: providers throw `ChatModelException`s that say whether
   a retry can help (`isRetryable`); `RetryingChatModel` acts on them, and
   `FailoverChatModel` switches to its fallback on any error except a
   cancellation unless given a `shouldFailover`.
8. **Call `dispose()`** on models and embedders you created without an
   `httpClient` once you no longer need them.
