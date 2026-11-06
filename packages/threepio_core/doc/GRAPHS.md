# Graphs, chains and workflows

`package:threepio_core/compose.dart` is the port of Eino's `compose` package:
it connects components (chat models, chat templates, retrievers, a tools node)
and plain functions (`Lambda`) into something you can run. The umbrella library
`package:threepio_core/threepio_core.dart` exports it as well.

| You want | Use | Go |
|---|---|---|
| Steps that follow one another, maybe with a parallel step or a branch | `Chain` | `compose.NewChain` |
| Any directed graph: loops, branches, several inputs to one node | `Graph` | `compose.NewGraph` |
| Nodes that take single fields from several earlier nodes | `Workflow` | `compose.NewWorkflow` |

All three are compiled into a `Runnable`. A compiled graph can pause and be
resumed later (interrupt, checkpoint and resume).

Examples: [`graph_react_example.dart`](../example/graph_react_example.dart) (a
ReAct agent as a graph), [`workflow_example.dart`](../example/workflow_example.dart)
(field mappings), [`compose_graph_state.dart`](../example/eino_examples/compose_graph_state.dart)
(local state, a port of the eino-examples program).

## Contents

- [Quick start](#quick-start)
- [Runnable: four ways to run](#runnable-four-ways-to-run)
- [Lambda](#lambda)
- [Chain](#chain)
- [Graph](#graph)
- [Workflow](#workflow)
- [Compiling: options and trigger modes](#compiling-options-and-trigger-modes)
- [Fan-in: several nodes into one](#fan-in-several-nodes-into-one)
- [Local state](#local-state)
- [Call options](#call-options)
- [Compile callbacks](#compile-callbacks)
- [Streaming](#streaming)
- [Interrupt, checkpoint and resume](#interrupt-checkpoint-and-resume)
- [A graph as a tool](#a-graph-as-a-tool)
- [Looking at a graph](#looking-at-a-graph)
- [Errors](#errors)
- [Differences from Eino](#differences-from-eino)
- [Legacy API (before 0.9): StateGraph](#legacy-api-before-09-stategraph)

## Quick start

A chat template that fills in a variable, followed by a chat model:

```dart
import 'package:threepio_core/compose.dart';

Future<Message> explain(
  RunContext ctx,
  BaseChatModel model,
  String topic,
) async {
  final template = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system('You explain programming topics in two sentences.'),
    Message.user('Explain {topic}.'),
  ]);
  final chain = Chain<Map<String, dynamic>, Message>()
    ..appendChatTemplate(template)
    ..appendChatModel(model);
  final runnable = await chain.compile(ctx);
  return runnable.invoke(ctx, {'topic': topic});
}
```

`model` is any `BaseChatModel`, for example an `OpenRouterChatModel` from the
umbrella library. `RunContext.background()` is a context to start from; it
carries callbacks, cancellation and the resume data of a run.

## Runnable: four ways to run

`compile` returns a `Runnable<I, O>` (Go `compose.Runnable`). Its four methods
differ in whether input and output are single values or streams:

| Method | Input | Output | Go |
|---|---|---|---|
| `invoke` | value | value | `Invoke` |
| `stream` | value | `StreamReader<O>` | `Stream` |
| `collect` | `StreamReader<I>` | value | `Collect` |
| `transform` | `StreamReader<I>` | `StreamReader<O>` | `Transform` |

A compiled graph offers all four whatever its nodes implement:

```dart
final graph = Graph<String, String>()
  ..addLambdaNode(
    'shout',
    Lambda<String, String>.invokable((ctx, input) => input.toUpperCase()),
  )
  ..addEdge(Graph.start, 'shout')
  ..addEdge('shout', Graph.end);
final runnable = await graph.compile(ctx);

// Value in, value out (Go: Invoke).
final shouted = await runnable.invoke(ctx, 'hello'); // 'HELLO'

// Value in, stream out (Go: Stream). The node answers with a value, so
// the stream has one chunk.
final chunks = await (await runnable.stream(ctx, 'hello')).collectAll();
// chunks == ['HELLO']

// Stream in, value out (Go: Collect). The chunks are joined first.
final joined = await runnable.collect(
  ctx,
  StreamReader.fromIterable(['hel', 'lo']),
); // 'HELLO'

// Stream in, stream out (Go: Transform).
final output = await runnable.transform(
  ctx,
  StreamReader.fromIterable(['hel', 'lo']),
);
await output.close();
```

Every method takes `options:`, a list of [call options](#call-options). A
returned stream belongs to the caller, who reads it to its end or closes it.

## Lambda

A `Lambda<I, O>` (Go `compose.Lambda`) makes a function a node. It is written
for one of the four modes, or for several:

```dart
// Value in, value out. Go: compose.InvokableLambda.
final upper = Lambda<String, String>.invokable(
  (ctx, input) => input.toUpperCase(),
);

// Value in, stream out. Go: compose.StreamableLambda.
final words = Lambda<String, String>.streamable(
  (ctx, input) => StreamReader.fromIterable(input.split(' ')),
);

// Stream in, value out. Go: compose.CollectableLambda.
final length = Lambda<String, int>.collectable(
  (ctx, input) async => (await input.collectAll()).join().length,
);

// Stream in, stream out. Go: compose.TransformableLambda.
final lower = Lambda<String, String>.transformable(
  (ctx, input) => input.convert((chunk) => chunk.toLowerCase()),
);

// Several at once. Go: compose.AnyLambda.
final trim = Lambda<String, String>.any(
  invoke: (ctx, input) => input.trim(),
  transform: (ctx, input) => input.convert((chunk) => chunk.trim()),
);
```

The graph derives the modes a lambda lacks:

* a missing `invoke` comes from `stream`, then `collect`, then `transform`;
* a missing `stream` from `transform`, then `invoke`, then `collect`;
* a missing `collect` from `transform`, then `invoke`, then `stream`;
* a missing `transform` from `stream`, then `collect`, then `invoke`.

Where a value is needed and there is a stream, the stream is read to its end
and its chunks are joined (see [Streaming](#streaming)); where a stream is
needed and there is a value, it becomes a stream of one chunk.

The type arguments can come from the function:
`graph.addLambdaNode('n', Lambda.invokable((ctx, String s) => s.length))`.

`LambdaOptions` sets the type the lambda reports to callbacks (`type`, Go
`WithLambdaType`) and whether the function fires its own callbacks
(`callbacksEnabled`, Go `WithLambdaCallbackEnable`). `Lambda.toList<T>()`
(Go `compose.ToList`) wraps a value in a list of one; `Lambda.messageParser`
(Go `compose.MessageParser`) parses a `Message` with a `MessageParser`.

**A lambda with call options.** The `…WithOption` variants are static methods,
because they need a third type argument, the type of the options:

```dart
/// The option type of the lambda below.
final class Greeting {
  const Greeting(this.salutation);
  final String salutation;
}

final greet = Lambda.invokableWithOption<String, String, Greeting>(
  (ctx, name, options) {
    final salutation =
        options.isEmpty ? 'Hello' : options.last.salutation;
    return '$salutation, $name';
  },
  options: const LambdaOptions(type: 'Greeter'),
);
```

A run hands it options of that type with `CallOption.lambda<T>`:

```dart
final answer = await runnable.invoke(
  ctx,
  'Ada',
  options: [CallOption.lambda<Greeting>([const Greeting('Welcome')])],
); // 'Welcome, Ada'
```

The options reach the lambdas declared with exactly that option type; see
[Call options](#call-options).

## Chain

A `Chain<I, O>` (Go `compose.Chain`) is a graph whose edges are drawn for you:
each node gets the output of the one before. The `append…` methods mirror
Go's (`appendChatTemplate`, `appendChatModel`, `appendToolsNode`,
`appendRetriever`, `appendEmbedding`, `appendIndexer`, `appendLoader`,
`appendDocumentTransformer`, `appendLambda`, `appendGraph`,
`appendPassthrough`, and the agentic ones, which are beta). The
[quick start](#quick-start) is a chain.

`Parallel` runs several nodes on the same input; the next node gets a
`Map<String, Object?>` with each output under its key. `ChainBranch` lets a
condition choose the node that runs next, out of at least two:

```dart
final chain = Chain<String, String>()
  // Both lambdas get the input; the next node gets a map with each
  // output under its key. Go: compose.NewParallel, AppendParallel.
  ..appendParallel(
    Parallel()
      ..addLambda(
        'upper',
        Lambda<String, String>.invokable((ctx, s) => s.toUpperCase()),
      )
      ..addLambda(
        'length',
        Lambda<String, int>.invokable((ctx, s) => s.length),
      ),
  )
  ..appendLambda(
    Lambda<Map<String, Object?>, String>.invokable(
      (ctx, m) => '${m['upper']}:${m['length']}',
    ),
  )
  // The condition returns the key of the node that runs next.
  // Go: compose.NewChainBranch, AppendBranch.
  ..appendBranch(
    ChainBranch.single<String>(
      (ctx, input) => input.length > 4 ? 'long' : 'short',
    )
      ..addLambda(
        'long',
        Lambda<String, String>.invokable((ctx, s) => 'long($s)'),
      )
      ..addLambda(
        'short',
        Lambda<String, String>.invokable((ctx, s) => 'short($s)'),
      ),
  );
final runnable = await chain.compile(ctx);
final short = await runnable.invoke(ctx, 'ab'); // 'short(AB:2)'
final long = await runnable.invoke(ctx, 'abc'); // 'long(ABC:3)'
```

`ChainBranch.single`, `.multi`, `.stream` and `.streamMulti` are the ports of
`NewChainBranch`, `NewChainMultiBranch`, `NewStreamChainBranch` and
`NewStreamChainMultiBranch`. All nodes of a branch must give the same type, or
lead to a node that accepts all of them.

Nodes of a chain get the keys `node_0`, `node_1`, … in the order they are
appended; the nodes of a `Parallel` appended as `node_N` get
`node_N_parallel_0`, `node_N_parallel_1`, …, and those of a branch
`node_N_branch_<key>`. `NodeOptions(key: …)` names a node instead. These keys
are what `CallOption.designateNode` takes. A mistake in building a chain (types that do
not fit, a branch with one node, a duplicate key in a `Parallel`) is kept and
thrown by `compile` as a `GraphBuildException`; the first mistake wins.

## Graph

A `Graph<I, O>` (Go `compose.Graph`) has nodes under keys, edges between them,
and branches. `Graph.start` and `Graph.end` (Go `START` and `END`; the strings
`'start'` and `'end'`, so those keys are reserved) stand for the input and the
output of the graph.

| Method | Node input → output | Go |
|---|---|---|
| `addChatTemplateNode` | `Map<String, dynamic>` → `List<Message>` | `AddChatTemplateNode` |
| `addChatModelNode` | `List<Message>` → `Message` | `AddChatModelNode` |
| `addToolsNode` | `Message` (with tool calls) → `List<Message>` | `AddToolsNode` |
| `addRetrieverNode` | `String` → `List<Document>` | `AddRetrieverNode` |
| `addEmbeddingNode` | `List<String>` → `List<List<double>>` | `AddEmbeddingNode` |
| `addIndexerNode` | `List<Document>` → `List<String>` | `AddIndexerNode` |
| `addLoaderNode` | `DocumentSource` → `List<Document>` | `AddLoaderNode` |
| `addDocumentTransformerNode` | `List<Document>` → `List<Document>` | `AddDocumentTransformerNode` |
| `addLambdaNode` | the lambda's `I` → `O` | `AddLambdaNode` |
| `addGraphNode` | a graph, chain or workflow, its `I` → `O` | `AddGraphNode` |
| `addPassthroughNode` | the type of its neighbours, unchanged | `AddPassthroughNode` |

`addAgenticModelNode`, `addAgenticChatTemplateNode` and `addAgenticToolsNode`
are the agentic counterparts (beta).

`addEdge(from, to)` (Go `AddEdge`) makes `to` run after `from` and get its
output. Types are checked when the edge is added: an edge between types that
cannot fit throws a `GraphBuildException` at once. An edge from a wider type
to a narrower one is allowed and checked at run time.

A graph of a retriever, a lambda, a chat template and a chat model, where the
template waits for two nodes:

```dart
final template = ChatTemplate.fromMessages(FormatType.fString, [
  Message.system('Answer from these notes:\n{documents}'),
  Message.user('{question}'),
]);

final graph = Graph<String, Message>()
  // String -> List<Document>.
  ..addRetrieverNode('retrieve', retriever)
  // List<Document> -> String, given on as {'documents': text}.
  ..addLambdaNode(
    'notes',
    Lambda<List<Document>, String>.invokable(
      (ctx, documents) => documents.map((d) => d.content).join('\n'),
    ),
    options: const NodeOptions(outputKey: 'documents'),
  )
  // String -> Map<String, Object?>.
  ..addLambdaNode(
    'question',
    Lambda<String, Map<String, Object?>>.invokable(
      (ctx, question) => {'question': question},
    ),
  )
  // Map<String, dynamic> -> List<Message>. It has two predecessors and
  // gets their maps merged into one.
  ..addChatTemplateNode('prompt', template)
  // List<Message> -> Message.
  ..addChatModelNode('model', model)
  ..addEdge(Graph.start, 'retrieve')
  ..addEdge('retrieve', 'notes')
  ..addEdge(Graph.start, 'question')
  ..addEdge('notes', 'prompt')
  ..addEdge('question', 'prompt')
  ..addEdge('prompt', 'model')
  ..addEdge('model', Graph.end);

final runnable = await graph.compile(
  ctx,
  options: const GraphCompileOptions(
    graphName: 'rag',
    nodeTriggerMode: NodeTriggerMode.allPredecessor,
  ),
);
final answer = await runnable.invoke(ctx, 'What is a passthrough node?');
```

`NodeOptions` (Go `GraphAddNodeOpt`) is given with the node:

| Field | Meaning | Go |
|---|---|---|
| `name` | display name the node's callbacks report | `WithNodeName` |
| `inputKey` | the node takes the value under this key of the map it gets | `WithInputKey` |
| `outputKey` | the node gives `{outputKey: output}` | `WithOutputKey` |
| `statePreHandler`, `statePostHandler`, `streamStatePreHandler`, `streamStatePostHandler` | see [Local state](#local-state) | `WithStatePreHandler`, … |
| `compileOptions` | for a sub-graph, the options it is compiled with | `WithGraphCompileOptions` |
| `key` | chains only; a graph gets the key with the node | `WithNodeKey` |

A sub-graph and a passthrough:

```dart
final inner = Chain<String, String>()
  ..appendLambda(
    Lambda<String, String>.invokable((ctx, s) => s.trim()),
  );

final outer = Graph<String, String>()
  // A graph, chain or workflow as one node. It is compiled with the
  // outer graph. Go: AddGraphNode.
  ..addGraphNode('clean', inner, options: const NodeOptions(name: 'Clean'))
  // Hands its input on; it takes the type of its neighbours.
  ..addPassthroughNode('keep')
  ..addEdge(Graph.start, 'clean')
  ..addEdge('clean', 'keep')
  ..addEdge('keep', Graph.end);
final runnable = await outer.compile(ctx);
```

### Branches

`addBranch(from, branch)` (Go `AddBranch`) adds a condition behind a node. It
looks at the node's output and names the node or nodes that run next, out of a
fixed set. The ReAct loop is the classic case: the model either asks for tools
or answers.

```dart
/// The conversation so far, kept per run.
final class Conversation {
  final List<Message> messages = [];
}

Future<Runnable<List<Message>, Message>> buildReAct(
  RunContext ctx,
  ToolCallingChatModel model,
  List<BaseTool> tools,
) async {
  final toolInfos = [for (final tool in tools) await tool.info()];
  final toolsNode = await ToolsNode.create(ToolsNodeConfig(tools: tools));

  final graph = Graph<List<Message>, Message>(
    localState: LocalState.of<Conversation>((ctx) => Conversation()),
  )
    ..addChatModelNode(
      'model',
      model.withTools(toolInfos),
      options: NodeOptions(
        // The model sees the whole conversation, not only the new messages.
        statePreHandler: StateHandler.pre<List<Message>, Conversation>(
          (ctx, input, state) {
            state.messages.addAll(input);
            return List.of(state.messages);
          },
        ),
        statePostHandler: StateHandler.post<Message, Conversation>(
          (ctx, output, state) {
            state.messages.add(output);
            return output;
          },
        ),
      ),
    )
    // Message with tool calls -> List<Message> (one tool message per call).
    ..addToolsNode('tools', toolsNode)
    ..addEdge(Graph.start, 'model')
    // Go: compose.NewGraphBranch.
    ..addBranch(
      'model',
      GraphBranch.single<Message>(
        (ctx, message) =>
            (message.toolCalls?.isNotEmpty ?? false) ? 'tools' : Graph.end,
        {'tools', Graph.end},
      ),
    )
    ..addEdge('tools', 'model');

  return graph.compile(
    ctx,
    options: const GraphCompileOptions(graphName: 'react', maxRunSteps: 20),
  );
}
```

The four constructors are static methods, because they capture the input type
of the condition, which the graph checks against the node in front of it:

| Dart | Go | Condition gets | Returns |
|---|---|---|---|
| `GraphBranch.single<T>` | `NewGraphBranch` | `T` | one key |
| `GraphBranch.multi<T>` | `NewGraphMultiBranch` | `T` | a set of keys |
| `GraphBranch.stream<T>` | `NewStreamGraphBranch` | `StreamReader<T>` | one key |
| `GraphBranch.streamMulti<T>` | `NewStreamGraphMultiBranch` | `StreamReader<T>` | a set of keys |

```dart
// Go: compose.NewGraphMultiBranch. Every node in the returned set runs.
graph.addBranch(
  'classify',
  GraphBranch.multi<String>(
    (ctx, text) => {
      if (text.contains('?')) 'answer',
      if (text.length > 200) 'summarize',
      if (text.length <= 200 && !text.contains('?')) Graph.end,
    },
    {'answer', 'summarize', Graph.end},
  ),
);
```

A condition that takes a value waits for the whole output in a streaming run
(it gets the joined chunks). A stream condition can decide after the first
chunks; it must close the stream it is given:

```dart
// Go: compose.NewStreamGraphBranch. In a streaming run the condition gets
// the model's chunks and may decide on the first one; it closes the stream.
streamingGraph.addBranch(
  'model',
  GraphBranch.stream<Message>(
    (ctx, chunks) async {
      try {
        final first = await chunks.nextOrNull();
        return (first?.toolCalls?.isNotEmpty ?? false) ? 'tools' : Graph.end;
      } finally {
        await chunks.close();
      }
    },
    {'tools', Graph.end},
  ),
);
```

Deciding on the first chunk suits a model that sends its tool calls first;
a provider that streams text before the tool-call deltas needs a condition
that reads further. A condition that returns a key outside its set fails the
run with a `GraphRunException`.

## Workflow

A `Workflow<I, O>` (Go `compose.Workflow`) is a graph in which every node
declares where its input comes from, field by field. A node can take one field
from the workflow's input, another from a node that ran long before it, and a
constant for a third. The `add…Node` methods return a `WorkflowNode` to
declare that on; `end()` is the node that stands for the output.

```dart
final workflow = Workflow<Map<String, Object?>, Map<String, Object?>>();

// Takes the field 'text' of the workflow's input as its whole input.
workflow
    .addLambdaNode(
      'upper',
      Lambda<String, String>.invokable((ctx, s) => s.toUpperCase()),
    )
    .addInput(Graph.start, [FieldMapping.fromField('text')]);

// Assembles its input from three places: the output of 'upper', a field
// of the workflow's input, and a constant.
workflow.addLambdaNode(
  'join',
  Lambda<Map<String, Object?>, String>.invokable(
    (ctx, input) => '${input['a']}-${input['b']}-${input['c']}',
  ),
)
  ..addInput('upper', [FieldMapping.toField('a')])
  ..addInput(Graph.start, [FieldMapping.mapFields('other', 'b')])
  ..setStaticValue(['c'], 'static');

// What is mapped to end() is the output of the workflow.
workflow.end()
  ..addInput('join', [FieldMapping.toField('result')])
  ..addInputWithOptions(
    Graph.start,
    [FieldMapping.mapFieldPaths(const ['nested', 'x'], const ['deep', 'x'])],
    noDirectDependency: true,
  );

final runnable = await workflow.compile(ctx);
final output = await runnable.invoke(ctx, {
  'text': 'hi',
  'other': 'o',
  'nested': {'x': 1},
}); // {'result': 'HI-o-static', 'deep': {'x': 1}}
```

| Mapping | Meaning | Go |
|---|---|---|
| `FieldMapping.fromField('a')` | field `a` of the output → the whole input | `FromField` |
| `FieldMapping.toField('a')` | the whole output → field `a` of the input | `ToField` |
| `FieldMapping.mapFields('a', 'b')` | field `a` → field `b` | `MapFields` |
| `FieldMapping.fromFieldPath([…])`, `toFieldPath`, `mapFieldPaths` | the same with paths into nested fields | `FromFieldPath`, `ToFieldPath`, `MapFieldPaths` |
| `toField('a', customExtractor: fn)` | what `fn` takes out of the output → field `a` | `WithCustomExtractor` |

| `WorkflowNode` method | Meaning | Go |
|---|---|---|
| `addInput(from, [mappings])` | runs after `from` and takes the mapped fields (all of the output without mappings) | `AddInput` |
| `addInputWithOptions(from, mappings, noDirectDependency: true)` | takes data from `from` without waiting for it directly; another path from `from` must exist | `AddInputWithOptions`, `WithNoDirectDependency` |
| `addDependency(from)` | runs after `from`, takes nothing | `AddDependency` |
| `setStaticValue(path, value)` | a constant for a field | `SetStaticValue` |

`workflow.addBranch(from, GraphBranch…)` (Go `Workflow.AddBranch`) decides
which nodes run; it carries no data, and the nodes it leads to declare their
inputs like any other.

A field is a key of a `Map<String, Object?>` or a field of a class that
implements `FieldAddressable` (`Message` and `Document` do). Go maps struct
fields by reflection; Dart has none, so a class says how its fields are read
and replaced, and a class that mappings write to registers its empty value:

```dart
/// A class a workflow can map fields from and to.
final class Query implements FieldAddressable {
  const Query({this.text = '', this.limit = 10});

  final String text;
  final int limit;

  @override
  Object? getField(String name) => switch (name) {
        'text' => text,
        'limit' => limit,
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };

  @override
  Query withField(String name, Object? value) => switch (name) {
        'text' => Query(text: value! as String, limit: limit),
        'limit' => Query(text: text, limit: value! as int),
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };
}

void registerQuery() {
  // Needed for a class that mappings write to: the engine starts from it.
  FieldAddressable.registerBlank<Query>(Query.new);
}
```

A workflow always runs as a DAG (a node runs when all the nodes it depends on
have finished; cycles are an error), and does not take `nodeTriggerMode`.
`add…Node` never throws: mistakes are reported by `compile`. An unknown field
or a value that does not fit a field is found when the workflow runs
(`FieldMappingException`).

## Compiling: options and trigger modes

`compile(ctx, options: GraphCompileOptions(...))` (Go `Compile(ctx, opts...)`)
freezes the graph: a change afterwards throws `GraphCompiledException`.

| Option | Meaning | Go |
|---|---|---|
| `maxRunSteps` | the most steps a run may take (Pregel only); default: number of nodes + 10 | `WithMaxRunSteps` |
| `nodeTriggerMode` | `NodeTriggerMode.anyPredecessor` (default) or `.allPredecessor`; not for chains and workflows | `WithNodeTriggerMode` |
| `graphName` | the name callbacks and addresses report | `WithGraphName` |
| `compileCallbacks` | see [Compile callbacks](#compile-callbacks) | `WithGraphCompileCallbacks` |
| `fanInMergeConfig` | per node: `FanInMergeConfig(streamMergeWithSourceEof: true)` | `WithFanInMergeConfig` |
| `eagerExecutionDisabled` | DAG mode: start successors only when the whole step is done | `WithEagerExecutionDisabled` |
| `checkpointStore`, `serializer` | see [Checkpoints](#checkpoints) | `WithCheckPointStore`, `WithSerializer` |
| `interruptBeforeNodes`, `interruptAfterNodes` | see [Interrupt before or after a node](#interrupt-before-or-after-a-node) | `WithInterruptBeforeNodes`, `WithInterruptAfterNodes` |

**Pregel and DAG.** By default (`NodeTriggerMode.anyPredecessor`) a graph runs
in steps: the nodes that are ready run side by side, then the nodes their
outputs lead to. A node runs as soon as one predecessor has finished, cycles
are allowed, and the step limit ends a run that does not reach the end. With
`NodeTriggerMode.allPredecessor` the graph must be acyclic (a cycle throws
`DagLoopException` at compile), a node runs once all its predecessors have,
and there is no step limit (`maxRunSteps` is then an error). The RAG graph
above needs DAG mode: in Pregel mode the template would run as soon as
`question` had finished, without the notes. A chain runs in Pregel mode, a
workflow in DAG mode.

```dart
// A loop: 'inc' runs again until the branch leads to the end.
final graph = Graph<int, int>()
  ..addLambdaNode('inc', Lambda<int, int>.invokable((ctx, i) => i + 1))
  ..addEdge(Graph.start, 'inc')
  ..addBranch(
    'inc',
    GraphBranch.single<int>(
      (ctx, i) => i < 3 ? 'inc' : Graph.end,
      {'inc', Graph.end},
    ),
  );
final runnable = await graph.compile(
  ctx,
  options: const GraphCompileOptions(maxRunSteps: 5),
);
try {
  return await runnable.invoke(ctx, 0); // 3
} on GraphRunException catch (error) {
  // A run that needs more steps fails; the cause says why.
  if (ThreepioException.findCause<ExceedMaxStepsException>(error) != null) {
    return -1;
  }
  rethrow;
}
```

## Fan-in: several nodes into one

When several nodes lead to one node, their outputs are merged into its input.
Maps are merged by default: the result has the entries of all of them, and a
key that occurs twice is an error. That is what nodes with an `outputKey` and
the nodes of a `Parallel` give. Any other type needs a merge function (Go
`compose.RegisterValuesMergeFunc`):

```dart
/// What two analysers report about a text.
final class Findings {
  const Findings(this.items);
  final List<String> items;
}

Future<Findings> analyse(RunContext ctx, String text) async {
  // Go: compose.RegisterValuesMergeFunc. Without it a fan-in of Findings
  // fails at run time; maps are the only type merged by default.
  ValuesMerge.register<Findings>(
    (values) => Findings([for (final v in values) ...v.items]),
  );

  final graph = Graph<String, Findings>()
    ..addLambdaNode(
      'spelling',
      Lambda<String, Findings>.invokable(
        (ctx, text) => const Findings(['spelling: ok']),
      ),
    )
    ..addLambdaNode(
      'style',
      Lambda<String, Findings>.invokable(
        (ctx, text) => Findings(['style: ${text.length} characters']),
      ),
    )
    ..addEdge(Graph.start, 'spelling')
    ..addEdge(Graph.start, 'style')
    ..addEdge('spelling', Graph.end)
    ..addEdge('style', Graph.end);
  final runnable = await graph.compile(ctx);
  return runnable.invoke(ctx, text);
}
```

The default merge gives a `Map<String, Object?>`. A node that takes a narrower
map type behind a fan-in needs a function for that type:

```dart
// The default merge gives a Map<String, Object?>. A node that takes a
// narrower map behind a fan-in needs a function for that type.
ValuesMerge.register<Map<String, int>>(
  (maps) => {for (final map in maps) ...map},
);
```

The registry is global; a later registration wins, so a subtype can be
registered after its supertype. Streams that fan in are merged into one
stream when their chunks are maps or of a registered type (two `String`
streams cannot fan in). With `FanInMergeConfig(streamMergeWithSourceEof: true)`
the merged stream reports the end of each source with a `SourceEOFException`
that names the node it came from.

## Local state

`Graph(localState: LocalState.of<S>(create))` (Go `compose.WithGenLocalState`)
gives every run a state object of type `S`. Nodes reach it through state
handlers and `processState`:

```dart
/// The state of one run.
final class Notes {
  final List<String> lines = [];
}

Future<String> withState(RunContext ctx) async {
  final graph = Graph<String, String>(
    // Go: compose.WithGenLocalState. A new state for every run.
    localState: LocalState.of<Notes>((ctx) => Notes()),
  )
    ..addLambdaNode(
      'work',
      Lambda<String, String>.invokable((ctx, input) async {
        // Go: compose.ProcessState. Calls on one state take turns.
        await processState<Notes>(ctx, (ctx, notes) => notes.lines.add('work'));
        return '$input!';
      }),
      options: NodeOptions(
        // Go: compose.WithStatePreHandler. Sees and may replace the input.
        statePreHandler: StateHandler.pre<String, Notes>((ctx, input, notes) {
          notes.lines.add('before');
          return input;
        }),
        // Go: compose.WithStatePostHandler. Sees and may replace the output.
        statePostHandler: StateHandler.post<String, Notes>(
          (ctx, output, notes) => '$output ${notes.lines.join(',')}',
        ),
      ),
    )
    ..addEdge(Graph.start, 'work')
    ..addEdge('work', Graph.end);
  final runnable = await graph.compile(ctx);
  return runnable.invoke(ctx, 'go'); // 'go! before,work'
}
```

`StateHandler.pre<I, S>` and `StateHandler.post<O, S>` capture the node's
input or output type and the state type; both are checked when the node is
added. In a streaming run they get the joined chunks. To keep the stream, use
`streamPre` and `streamPost` (a node takes one pre handler and one post
handler):

```dart
// Go: compose.WithStreamStatePreHandler. Keeps the input a stream in a
// streaming run, instead of joining the chunks for the handler.
return NodeOptions(
  streamStatePreHandler: StateHandler.streamPre<String, Notes>(
    (ctx, input, notes) => input.convert((chunk) {
      notes.lines.add(chunk);
      return chunk;
    }),
  ),
);
```

The state lives for one run and is mutable. Handlers and `processState` calls
on the same state take turns, so nodes that run side by side can share it; do
not call `processState` for the same state from inside its function.
`processState<S>` finds the state of the nearest enclosing graph that has a
state of type `S`, and fails with a `StateError` when there is none. A graph
with a checkpoint store writes its state into checkpoints; see
[Checkpoints](#checkpoints).

## Call options

The options of one run (Go `compose.Option`) go to the components inside the
graph. Each applies to every node it fits, unless it is aimed at nodes:

```dart
final answer = await runnable.invoke(
  ctx,
  'Summarize the meeting notes',
  options: [
    // Every chat model node of the graph, nested graphs included.
    CallOption.chatModel(const ChatModelOptions(temperature: 0)),
    // Only the node 'summarize'. Go: WithChatModelOption(...).DesignateNode.
    CallOption.chatModel(const ChatModelOptions(model: 'small-model'))
        .designateNode(['summarize']),
    // The node 'model' of the graph that is the node 'review'.
    CallOption.chatModel(const ChatModelOptions(maxTokens: 200))
        .designateNodeWithPath([
      NodePath(const ['review', 'model']),
    ]),
    // Handlers for this run; aimed at a node, they hear that node and
    // what runs inside it.
    CallOption.callbacks([logger]),
    // A step limit for this run instead of the compiled one.
    CallOption.runtimeMaxSteps(30),
  ],
);
```

| Option | Reaches | Go |
|---|---|---|
| `CallOption.chatModel`, `.chatTemplate`, `.retriever`, `.embedding`, `.indexer`, `.loader`, `.documentTransformer` | nodes of that kind | `WithChatModelOption`, … |
| `CallOption.toolsNode(ToolsNodeOptions)`, `CallOption.tool(ToolOptions)` | tools nodes, and the tools they run | `WithToolsNodeOption` |
| `CallOption.lambda<T>(options)` | lambdas declared with option type `T` | `WithLambdaOption` |
| `CallOption.callbacks(handlers)` | the graph and everything in it, or the designated nodes | `WithCallbacks` |
| `CallOption.runtimeMaxSteps(n)` | this run's step limit (Pregel only; a DAG run fails with it) | `WithRuntimeMaxSteps` |
| `CallOption.checkpointId`, `.writeToCheckpointId`, `.forceNewRun`, `.stateModifier` | see [Checkpoints](#checkpoints) | `WithCheckPointID`, … |

`designateNode(keys)` aims an option at nodes of the graph that is run;
`designateNodeWithPath([NodePath([...])])` at nodes of nested graphs (Go
`DesignateNode`, `DesignateNodeWithPath`).

**Options are matched by their declared type.** An option reaches the nodes
whose option type is exactly the type it was made for (`ChatModelOptions` for
`CallOption.chatModel`, `T` for `CallOption.lambda<T>`). Go compares the
dynamic type of the first option value with the node's option type. In Dart
the runtime type of a value can be a private subclass, and an `is` test would
hand a lambda declared with `Object` the options of every node, so this port
compares the declared type instead. A lambda declared with a supertype of `T`
does not get `CallOption.lambda<T>` options.

## Compile callbacks

A `GraphCompileCallback` (Go `compose.GraphCompileCallback`) hears about every
graph that is compiled with `compile`, with its structure (`GraphInfo`). A
nested graph is not reported on its own; it is part of its parent's
`GraphInfo`.

```dart
import 'package:logging/logging.dart';
import 'package:threepio_core/compose.dart';

final _log = Logger('app.graphs');

/// Logs the nodes of every graph that is compiled.
final class GraphLogger implements GraphCompileCallback {
  @override
  void onFinish(RunContext ctx, GraphInfo info) {
    _log.info('compiled ${info.name}: ${info.nodes.keys.join(', ')}');
  }
}

void registerCompileCallbacks() {
  // Replaces every global compile callback, as Go's
  // compose.InitGraphCompileCallbacks does.
  GraphCompileCallbacks.setGlobal([GraphLogger()]);

  // Adds to them instead; for a library that must not remove the
  // application's callbacks. Not in Eino.
  GraphCompileCallbacks.appendGlobal([GraphLogger()]);
}
```

`GraphCompileCallbacks.setGlobal` replaces the global list, as Go's
`InitGraphCompileCallbacks` does; an empty list removes them all.
`appendGlobal` adds behind the ones registered before, and `clearGlobal`
forgets them (tests that register call it). For one graph, pass them in its
compile options; they run after the global ones:

```dart
await graph.compile(
  ctx,
  options: GraphCompileOptions(
    graphName: 'support',
    compileCallbacks: [GraphLogger()],
  ),
);
```

A compile callback that throws is logged (`threepio.compose`) and does not
fail `compile`.

## Streaming

Each node runs in the mode the run needs, whatever it was written for:

* **`invoke`**: every node gets values. A node that only streams has its
  output read to the end and joined.
* **`stream`, `collect`, `transform`**: nodes pass streams on. A node that only
  takes values gets the joined chunks of its input (so it waits for the whole
  input), and its answer is passed on as a stream of one chunk. State
  handlers and value conditions likewise get joined chunks.

```dart
final chunks = await runnable.stream(ctx, {'topic': 'streams'});
final buffer = StringBuffer();
for (var chunk = await chunks.nextOrNull();
    chunk != null;
    chunk = await chunks.nextOrNull()) {
  buffer.write(chunk.content);
}
await chunks.close();
```

Chunks are joined by `StreamConcat`: strings are concatenated; `Message`, `List<Message>` and
`ToolResult` with the message concat functions; maps key by key (the result
is a `Map<String, Object?>`); for `num`, `bool`, `DateTime` and `Duration` the
last chunk wins. Register a function for any other type (Go
`compose.RegisterStreamChunkConcatFunc`):

```dart
/// A running count that a node streams as it goes.
final class Tally {
  const Tally(this.count);
  final int count;
}

void registerTally() {
  // Go: compose.RegisterStreamChunkConcatFunc. Tells the graph how chunks of
  // a Tally stream become one Tally, for a node that takes a whole value.
  StreamConcat.register<Tally>(
    (chunks) => Tally(chunks.fold(0, (sum, chunk) => sum + chunk.count)),
  );
}
```

For a type without a function, chunks can only be joined when at most one of
them carries a value; otherwise the run fails.

## Interrupt, checkpoint and resume

A run can pause and go on later, also in another process. It stops in one of
three ways:

* a node throws `interrupt`, `statefulInterrupt` or `compositeInterrupt`
  (Go `compose.Interrupt`, `StatefulInterrupt`, `CompositeInterrupt`);
* the graph reaches a node listed in `interruptBeforeNodes` or
  `interruptAfterNodes`;
* the caller interrupts it from outside (`ctx.withGraphInterrupt()`, Go
  `WithGraphInterrupt`).

In each case the run fails with a `GraphInterruptedException` (Go: the error
`ExtractInterruptInfo` accepts). This is not a failure: with a
`CheckpointStore` in the compile options and a checkpoint id in the call
options, the graph writes a checkpoint, and calling it again with the same id
goes on from there.

### Interrupt from inside a node

A node asks for a decision and keeps what it needs in the checkpoint:

```dart
/// Asks for approval before a draft goes out.
final review = Lambda<String, String>.invokable((ctx, draft) {
  final previous = getInterruptState<String>(ctx);
  if (!previous.wasInterrupted) {
    // First run: stop here, and keep the draft in the checkpoint.
    throw statefulInterrupt(ctx, 'Send this draft?', draft);
  }
  // Resumed. The input is now '' (see "The input of a node that runs
  // again"); the draft comes back from the saved state.
  final answer = getResumeContext<String>(ctx).data;
  return answer == 'yes' ? previous.state! : 'not sent';
});

Future<String> sendWithApproval(
  RunContext ctx,
  String draft,
  Future<String> Function(Object? question) ask,
) async {
  final graph = Graph<String, String>()
    ..addLambdaNode('review', review)
    ..addEdge(Graph.start, 'review')
    ..addEdge('review', Graph.end);
  final runnable = await graph.compile(
    ctx,
    options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
  );

  final options = [CallOption.checkpointId('draft-42')];
  try {
    return await runnable.invoke(ctx, draft, options: options);
  } on GraphInterruptedException catch (interrupted) {
    final point = interrupted.interruptContexts.single;
    final answer = await ask(point.info); // 'Send this draft?'
    // The same checkpoint id; the context names the point to resume and
    // the data it gets. The input of a resumed call is not read.
    return runnable.invoke(
      ctx.resumeWithData(point.id, answer),
      '',
      options: options,
    );
  }
}
```

* `interrupt(ctx, info)` returns the signal to throw; `info` is shown to the
  caller (`InterruptCtx.info`) and not saved.
* `statefulInterrupt(ctx, info, state)` also saves `state`, which the node
  finds again with `getInterruptState<T>(ctx)` →
  `(wasInterrupted, hasState, state)` (Go `GetInterruptState`).
* `getResumeContext<T>(ctx)` → `(isResumeTarget, hasData, data)` (Go
  `GetResumeContext`) says whether the caller resumes this node and with what.
* The caller resumes with `ctx.resumeWithData(id, data)`, `ctx.resume(ids)`
  or `ctx.batchResumeWithData({id: data})` (Go `ResumeWithData`, `Resume`,
  `BatchResumeWithData`), where the ids are those of
  `GraphInterruptedException.interruptContexts`.

Every node that interrupted runs again on resume. When interrupt points are
resumed one at a time, a node that is not the resume target must interrupt
again, so that it stays in the checkpoint until its turn:

```dart
final confirm = Lambda<String, String>.invokable((ctx, input) {
  final resumed = getResumeContext<bool>(ctx);
  if (!resumed.isResumeTarget) throw interrupt(ctx, 'Continue?');
  return (resumed.data ?? false) ? 'confirmed' : 'cancelled';
});
```

A tool that runs inside a tools node interrupts the same way; the tools node
then reports the finished calls and the interrupted ones
(`ToolsInterruptAndRerunExtra` in `GraphInterruptInfo.rerunNodesExtra`), and
only the interrupted calls run again.

**The input of a node that runs again.** In Go a node that interrupted from
inside runs again with the zero value of its input type. Dart has no zero
value for most types. A node whose input type has an empty value (`String`,
`num`, `bool`, a nullable type, a `List`, a `Map`) gets that value, as in Go;
a node whose input type has none (a non-nullable class such as `Message`) gets
the input it had, which is kept in the checkpoint. Under
`ctx.withGraphInterrupt()` every node gets its input back, as in Go. To tell a
first run from a resumed one, use `getInterruptState`, never the input.

### Checkpoints

`CheckpointStore` (Go `compose.CheckPointStore`) keeps bytes under a key:
`get(key)` and `set(key, bytes)`. `InMemoryCheckpointStore` is in
`compose.dart`; `FileCheckpointStore(Directory(...))`, which survives a
restart, is in `package:threepio_core/io.dart`. A store that also implements
`CheckpointDeleter` can forget a checkpoint; the graph itself never deletes
one.

| Call option | Meaning | Go |
|---|---|---|
| `CallOption.checkpointId(id)` | resume from `id` if it exists, and write there when interrupted | `WithCheckPointID` |
| `CallOption.writeToCheckpointId(id)` | write to another id than the one read | `WithWriteToCheckPointID` |
| `CallOption.forceNewRun()` | start afresh although `id` exists | `WithForceNewRun` |
| `CallOption.stateModifier(fn)` | change the saved state before the run goes on | `WithStateModifier` |

A checkpoint id without a store fails the run; a store without an id writes
nothing. A resumed call does not read its input. Because the graph never
deletes a checkpoint, a later call with the same id goes on from it again: use
a new id per run, `CallOption.forceNewRun()`, or delete the checkpoint once
the run has finished. A nested graph (added with
`addGraphNode`) never takes checkpoint options: its checkpoint is part of the
checkpoint of the graph around it.

**Types in checkpoints.** Go writes checkpoints with `gob` and finds types by
reflection. Here a checkpoint is JSON, and every value in it that is not JSON
must be registered with `TypeRegistry.registerName` (Go
`schema.RegisterName`): the state of the graph, what a node passes to
`statefulInterrupt`, the inputs and outputs of nodes that can be in flight
when the run stops. The schema types (`Message`, `Document`, …) are
registered.

```dart
/// The state of an order run; written into checkpoints.
final class OrderState {
  OrderState({this.approved = false});

  factory OrderState.fromJson(Map<String, Object?> json) =>
      OrderState(approved: json['approved']! as bool);

  bool approved;

  Map<String, Object?> toJson() => {'approved': approved};
}

void registerOrderState() {
  // Go: schema.RegisterName. Keep the name stable across releases: stored
  // checkpoints refer to it.
  TypeRegistry.registerName<OrderState>(
    'shop.order_state',
    fromJson: OrderState.fromJson,
    toJson: (state) => state.toJson(),
  );
}
```

A graph with a checkpoint store refuses, at `compile`, a state type that is
neither JSON nor registered (`GraphBuildException`); a value that cannot be
written when the run stops fails it (a `GraphRunException` caused by a
`CheckpointEncodeException` that names the value), instead of leaving a
checkpoint that could not be resumed.
Lists and maps lose their element types in JSON; the engine gives node inputs
and outputs, and the states `getInterruptState` returns, back the types the
nodes declare. An empty list whose element type the engine does not know (not
registered, no blank) comes back as a list that takes no elements: a
convenience on top of the rule above, not a reason to skip registering
collection types that can appear in a checkpoint.

A custom `CheckpointSerializer` (Go `compose.Serializer`) wraps the JSON form
(compression, encryption); it gets the checkpoint as an object only
`JsonCheckpointSerializer.toJson` can take apart. `migrateCheckpointState`
rewrites the state inside stored checkpoint bytes.

### Interrupt before or after a node

Compile with `interruptBeforeNodes` or `interruptAfterNodes`; to go on, call
the graph again with the same checkpoint id. Here `graph` keeps an
`OrderState` (registered as above) and has a node `send`:

```dart
final runnable = await graph.compile(
  ctx,
  options: GraphCompileOptions(
    checkpointStore: store,
    // Go: compose.WithInterruptBeforeNodes / WithInterruptAfterNodes.
    interruptBeforeNodes: const ['send'],
  ),
);

final options = [CallOption.checkpointId('order-7')];
try {
  return await runnable.invoke(ctx, 'order 7', options: options);
} on GraphInterruptedException catch (interrupted) {
  final info = interrupted.info;
  assert(info.beforeNodes.contains('send'), 'stopped in front of send');
}

// Later, possibly in another process with a persistent store: the same
// id goes on from the checkpoint. The modifier changes the saved state of
// the graph (path []) before it continues.
return runnable.invoke(
  ctx,
  '',
  options: [
    ...options,
    CallOption.stateModifier((ctx, path, state) {
      if (path.path.isEmpty) (state as OrderState).approved = true;
    }),
  ],
);
```

A run that would stop behind its last node is not interrupted: reaching
`Graph.end` wins, as in Eino.

### Interrupt from outside

```dart
// Go: compose.WithGraphInterrupt.
final (runCtx, interrupter) = ctx.withGraphInterrupt();
final run = runnable.invoke(
  runCtx,
  'long job',
  options: [CallOption.checkpointId('job-1')],
);

// For example when the user presses "stop": wait up to two seconds for
// the running nodes, then save what there is.
interrupter.interrupt(timeout: const Duration(seconds: 2));

try {
  return await run;
} on GraphInterruptedException catch (interrupted) {
  // The nodes that had not finished run again, with their input, when
  // the run is resumed with 'job-1'.
  return 'stopped at ${interrupted.info.rerunNodes}';
}
```

Without a `timeout`, the run waits for the nodes that are running and stops
before it starts the next ones; with one it waits that long at most
(`Duration.zero`: at once) and abandons the nodes that are still running (Go
`WithGraphInterruptTimeout`). A second `interrupt()` throws `StateError`.

### A node that runs a graph of its own

A nested graph added with `addGraphNode` needs nothing special. A lambda or a
tool that runs a compiled graph itself passes the inner interrupt on with
`compositeInterrupt`, so that the outer graph checkpoints as well:

```dart
// A lambda that runs a compiled graph of its own (compiled with a store).
final runsInner = Lambda<String, String>.invokable((ctx, input) async {
  try {
    return await inner.invoke(
      ctx,
      input,
      options: [CallOption.checkpointId('inner')],
    );
  } on GraphInterruptedException catch (interrupted) {
    // Go: compose.CompositeInterrupt. The outer graph then checkpoints
    // too, and its caller sees the inner interrupt points.
    throw compositeInterrupt(ctx, null, null, [interrupted]);
  }
});
```

If it lets the inner `GraphInterruptedException` through instead, the outer
graph passes it on unchanged and writes no checkpoint, as in Eino.

### What an interrupt reports

`GraphInterruptedException.info` is a `GraphInterruptInfo` (Go
`InterruptInfo`): `state` (a copy of the graph's state), `beforeNodes`,
`afterNodes`, `rerunNodes` (nodes that run again on resume), `rerunNodesExtra`
(what they reported), `subGraphs` (nested graphs, by node key) and
`interruptContexts` (one `InterruptCtx` per root cause, each with `id`,
`address`, `info`, `isRootCause` and its `parent`).
`extractInterruptInfo(error)` finds it also when the interrupt is the cause of
another exception:

```dart
// Go: compose.ExtractInterruptInfo. Also finds an interrupt that is the
// cause of another exception.
final info = extractInterruptInfo(error);
if (info == null) return const [];
return [
  // point.id is what ctx.resume and ctx.resumeWithData take; the address
  // says where, e.g. 'runnable:g;node:tools;tool:ask:call_2'.
  for (final point in info.interruptContexts) '${point.address}: ${point.info}',
];
```

`GraphInterruptedException` is an `InterruptSignal`, so code that catches
errors to recover from them (`isInterrupt(error)`) lets it through.

## A graph as a tool

`GraphTool` (from `package:threepio_core/adk.dart`; port of the eino-examples
`graphtool` package) wraps a graph, chain or workflow as a tool of an agent:
the model calls it with JSON arguments, the graph runs on the input they
decode to, and its output, encoded as JSON, is the result.

```dart
import 'package:threepio_core/adk.dart';

ChatModelAgent buildAgent(BaseChatModel model) {
  // Any graph, chain or workflow from String to String.
  final shout = Chain<String, String>()
    ..appendLambda(
      Lambda<String, String>.invokable((ctx, text) => text.toUpperCase()),
    );

  final tool = GraphTool.invokable<String, String>(
    name: 'shout',
    description: 'Repeats a text in capital letters',
    params: const ParamsOneOf.params({
      'text': ParameterInfo(type: DataType.string, required: true),
    }),
    fromJson: (arguments) => arguments['text']! as String,
    graph: shout,
  );

  return ChatModelAgent(
    ChatModelAgentConfig(
      name: 'assistant',
      description: 'Answers questions',
      instruction: 'Use the shout tool when asked to shout.',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
    ),
  );
}
```

`GraphTool.streamable` gives a tool that streams the graph's output. An
interrupt inside the graph interrupts the agent; resuming the agent resumes
the graph where it stopped, with the same arguments. Each call compiles the
graph with a checkpoint store of its own, so a graph with a local state that
is not JSON needs its state type registered. Call options for the graph go in
`ToolOptions(extensions: [GraphToolOptions([...])])`.

## Looking at a graph

```dart
final graph = Graph<String, String>()
  ..addLambdaNode('a', Lambda<String, String>.invokable((ctx, s) => '$s-a'))
  ..addLambdaNode('b', Lambda<String, String>.invokable((ctx, s) => '$s-b'))
  ..addEdge(Graph.start, 'a')
  ..addEdge('a', 'b')
  ..addEdge('b', Graph.end);

// Nodes, edges and branches as they are now.
final info = graph.info;
final keys = info.nodes.keys; // ('a', 'b')

// A Mermaid flowchart ('graph TD ...') for a Markdown viewer.
final chart = graph.toMermaid();
```

`GraphInfo` (Go `compose.GraphInfo`) lists the nodes (`GraphNodeInfo`: kind,
instance, options, types, input and output keys, nested graph), the control
and data edges, the branches, the types and the name. A `GraphCompileCallback`
gets the same value when the graph is compiled. `toMermaid()` labels nodes
with their key and kind, draws lambdas rounded, sub-graphs as subgraphs,
branches as diamonds, and data-only edges (workflows) dotted.

## Errors

**Building.** Where Go returns an error, the Dart methods throw a
`GraphBuildException`: an unknown node, a duplicate key, a reserved key,
types that do not fit, a handler whose types differ from its node. In a graph
the first one sticks: every later change and `compile` throw it again.

```dart
final graph = Graph<String, int>()
  ..addLambdaNode('a', Lambda<String, String>.invokable((ctx, s) => s));
try {
  // 'a' gives a String; the graph must give an int.
  graph.addEdge('a', Graph.end);
} on GraphBuildException catch (error) {
  // The first mistake sticks: every later change, and compile, throw it
  // again.
  return error.message;
}
```

A chain and a workflow keep their first mistake and throw it from `compile`.
Subclasses: `GraphCompiledException` (changed after `compile`),
`ChainCompiledException`, `DagLoopException` (a cycle in DAG mode, with the
cycles in `loops`).

**Running.** A run fails with a `GraphRunException`; when a node failed it is
a `NodeExecutionException`, whose `cause` is what the node threw and whose
`nodePath` leads to it through nested graphs. Too many steps is a
`GraphRunException` caused by `ExceedMaxStepsException`
(`ThreepioException.findCause` finds it). A value of the wrong type at run time
(behind an edge from a wider type) is a `ComposeTypeException`, usually as the
cause of a `GraphRunException`. An interrupt is not wrapped: it arrives as
`GraphInterruptedException`.

## Differences from Eino

The ones a user is likely to notice; the CHANGELOG lists all of them under
"Differences from Eino in the compose port" and "Interrupt, resume and
checkpoints compared with Eino".

* **Errors are thrown.** Building mistakes throw `GraphBuildException` where
  Go returns an error; a chain and a workflow report their first mistake from
  `compile`.
* **Call options match by declared type**, not by the dynamic type of the
  option value (see [Call options](#call-options)). Component options are one
  object per kind (`ChatModelOptions`), not a list of functions.
* **Fan-in of narrower maps.** The default merge gives `Map<String, Object?>`;
  a node that takes `Map<String, int>` behind a fan-in needs
  `ValuesMerge.register<Map<String, int>>`.
* **Edges** may lead from any supertype to a subtype (checked at run time),
  not only from an interface.
* **Checkpoints are JSON.** Every non-JSON value in a checkpoint is registered
  with `TypeRegistry.registerName`; a graph with a store refuses an
  unregistered state type at `compile`.
* **The input of a node that runs again** is its empty value when its type has
  one and its original input otherwise (Go: always the zero value). Detect a
  resume with `getInterruptState`.
* **Field mappings** use `FieldAddressable` instead of reflection, so unknown
  fields and mismatched types are found at run time (`FieldMappingException`);
  a class that mappings write to registers a blank.
* **Compile callbacks**: `GraphCompileCallbacks.setGlobal` replaces like Go's
  `InitGraphCompileCallbacks`; `appendGlobal` is an addition. A compile
  callback that throws is logged and does not fail `compile`.
* `CallOption.forceNewRun()` works anywhere in the option list (Go: only
  last). A tools node's stream carries empty tool messages where Go has `nil`
  entries, and a tool whose stream ends without a chunk has an empty result
  (Go v0.9.22 fails the stream).
* There is no `Passthrough` component kind (`GraphNodeInfo.isPassthrough`
  says it). Nodes of a step start, and map inputs merge, in the order nodes
  and edges were added.
* Not ported (deprecated in Eino): `InterruptAndRerun`,
  `NewInterruptAndRerunErr`, `WrapInterruptAndRerunIfNeeded`,
  `RegisterSerializableType`, `Workflow.AddEnd`. Use `interrupt`,
  `TypeRegistry.registerName` and `Workflow.end()`.

## Legacy API (before 0.9): StateGraph

`StateGraph`, `GraphBuilder` and `GraphState` predate the port of Eino's
`compose` package and are not ported from Eino. They are still supported (an
application uses them) and exported from the umbrella library and from
`package:threepio_core/legacy_graph.dart`. New code uses `Graph` (see below
for what replaces what).

A state graph passes one immutable state object from node to node:

```dart
import 'package:threepio_core/threepio_core.dart';

/// The state flows through the nodes; each node returns a new one.
class CounterState implements GraphState {
  const CounterState({this.count = 0});

  final int count;

  @override
  CounterState copyWith({int? count}) =>
      CounterState(count: count ?? this.count);
}

Future<GraphResult<CounterState>> countToThree() {
  final graph = StateGraph<CounterState>()
    ..addNode('increment', (state) => state.copyWith(count: state.count + 1))
    ..addConditionalEdge(
      'increment',
      (state) => state.count < 3 ? 'increment' : END,
    )
    ..setEntryPoint('increment');
  // result.state.count == 3, result.path == ['increment', 'increment', ...]
  return graph.invoke(const CounterState());
}
```

`START` and `END` are string constants of this API (`'__start__'`,
`'__end__'`), unrelated to `Graph.start` and `Graph.end`. `addConditionalRouter`
and `addParallelEdge` add named routes and parallel branches with a merger;
`invoke` returns a `GraphResult` with the final `state`, the `path` taken and
`metadata`. The same graph with the fluent builder:

```dart
return GraphBuilder<CounterState>()
    .withNode('increment', (state) => state.copyWith(count: state.count + 1))
    .routeIf(
      from: 'increment',
      condition: (state) => state.count < 3,
      then: 'increment',
      otherwise: END,
    )
    .startFrom('increment')
    .build();
```

`toRunnable()` turns a state graph into a `LegacyRunnable` (the runnable over
Dart `Stream`s that came before `Runnable`; its name and `LegacyLambda` are in
`legacy_graph.dart`):

```dart
// A LegacyRunnable over Dart Streams; not a compose Runnable.
final runnable = graph.toRunnable();
final result = await runnable.invoke(const CounterState());
```

**Checkpoints.** The state graph has checkpoint classes of its own. Five of
their names are taken by compose in the umbrella library, so they come from
`legacy_graph.dart`: `CheckpointStore<S>`, `CheckpointSerializer<S>`,
`JsonCheckpointSerializer<S>`, `InMemoryCheckpointStore<S>`,
`FileCheckpointStore<S>`. The rest (`CheckpointConfig`, `Checkpoint`,
`GraphInterruptException`, `HumanInputNode`, …) is in the umbrella.

```dart
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

class ReviewState implements GraphState {
  const ReviewState({this.text = '', this.published = false});

  final String text;
  final bool published;

  @override
  ReviewState copyWith({String? text, bool? published}) => ReviewState(
        text: text ?? this.text,
        published: published ?? this.published,
      );
}

Future<ReviewState> draftThenPublish() async {
  // The five checkpoint names of the state graph come from
  // legacy_graph.dart; the umbrella's CheckpointStore is the compose one.
  final store = legacy.InMemoryCheckpointStore<ReviewState>();
  final graph = StateGraph<ReviewState>(
    checkpointStore: store,
    checkpointConfig: const CheckpointConfig(
      interruptAfter: ['draft'],
      autoSave: true,
    ),
  )
    ..addNode('draft', (state) => state.copyWith(text: 'Draft'))
    ..addNode('publish', (state) => state.copyWith(published: true))
    ..addEdge('draft', 'publish')
    ..addEdge('publish', END)
    ..setEntryPoint('draft');

  try {
    return (await graph.invoke(const ReviewState(), threadId: 'doc-1')).state;
  } on GraphInterruptException<ReviewState> catch (interrupted) {
    // Saved because of autoSave; resumes behind 'draft'.
    final resumed = await graph.invoke(
      const ReviewState(),
      checkpointId: interrupted.checkpoint.id,
      threadId: 'doc-1',
    );
    return resumed.state;
  }
}
```

The checkpoint of an interrupt is only stored with `autoSave: true`. Resume
from a checkpoint of `interruptAfter`: one taken by `interruptBefore` stops in
front of the same node again when it is resumed.

**What to use instead.**

| StateGraph | compose |
|---|---|
| `StateGraph<S>` | `Graph<I, O>(localState: LocalState.of<S>(...))` |
| `addNode(name, fn)` | `addLambdaNode(key, Lambda.invokable(...))` |
| `setEntryPoint(name)` | `addEdge(Graph.start, key)` |
| `addEdge(a, END)` | `addEdge(a, Graph.end)` |
| `addConditionalEdge`, `addConditionalRouter` | `addBranch(from, GraphBranch.single(...))` |
| `addParallelEdge(from, to, merger:)` | several edges from one node; fan-in with `ValuesMerge` |
| `GraphBuilder` | cascades on `Graph` (`..addLambdaNode(...)`) |
| `maxIterations` | `GraphCompileOptions(maxRunSteps:)` |
| `CheckpointConfig(interruptBefore:, interruptAfter:)` | `GraphCompileOptions(interruptBeforeNodes:, interruptAfterNodes:)` |
| `HumanInputNode`, `resumeWithHumanInput` | `interrupt`/`statefulInterrupt` in a node, `ctx.resumeWithData` |
| `invoke(state, callbackManager:)` | `runnable.invoke(ctx, input)` with `ctx.withHandlers([...])` ([CALLBACKS.md](CALLBACKS.md)) |
| `toRunnable()` | `compile(ctx)` |
