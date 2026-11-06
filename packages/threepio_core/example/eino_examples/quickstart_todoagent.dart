// ignore_for_file: avoid_print

/// A todo agent: a chain of a tool-calling chat model and a tools node, with
/// tools made in four different ways, and a global callback handler.
///
/// Port of eino-examples `quickstart/todoagent/main.go`. The comments and the
/// request are translated from Chinese. What it shows:
///
/// * a tool from a `ToolInfo` and a function: `FunctionTool.fromInfo` (Go
///   `utils.NewTool`);
/// * a tool from a typed function: `FunctionTool` (Go `utils.InferTool`).
///   Go infers the parameter schema from the struct tags of the input type;
///   Dart has no reflection, so the tool is given that schema and a
///   `fromJson`;
/// * a hand-written tool: a class that extends `InvokableTool`;
/// * a ready-made tool: `DuckDuckGoSearchTool` (Go eino-ext
///   `duckduckgo.NewTextSearchTool`);
/// * the tools bound to the model (`withTools`, Go `BindTools`), and a
///   compose `Chain` of the model and a `ToolsNode`;
/// * a handler every run reports to: `GlobalCallbacks.append` (Go
///   `callbacks.AppendGlobalHandlers`) with a handler built by
///   `CallbackHandlerBuilder`. Go registers a CozeLoop tracing handler; this
///   example one that prints.
///
/// The chain runs the model once and the tools it asks for once: the output
/// is the list of tool results, not a final answer (for the loop, see
/// `example/graph_react_example.dart`).
///
/// Run it with an OpenRouter or OpenAI key (see `example/README.md`); the
/// search goes to DuckDuckGo:
///
/// ```bash
/// OPENROUTER_API_KEY=... dart run example/eino_examples/quickstart_todoagent.dart
/// ```
library;

import 'package:threepio_core/callbacks.dart'
    show CallbackHandlerBuilder, GlobalCallbacks;
import 'package:threepio_core/compose.dart';

import '../support/example_model.dart';

/// The arguments of `add_todo`. Go: `TodoAddParams`.
final class TodoAddParams {
  /// The arguments.
  const TodoAddParams({required this.content, this.startedAt, this.deadline});

  /// Reads the arguments the model wrote. A missing `content` is empty, as
  /// Go's zero value.
  factory TodoAddParams.fromJson(Map<String, Object?> json) => TodoAddParams(
        content: json['content'] as String? ?? '',
        startedAt: (json['started_at'] as num?)?.toInt(),
        deadline: (json['deadline'] as num?)?.toInt(),
      );

  /// What there is to do.
  final String content;

  /// When it starts, as a unix timestamp.
  final int? startedAt;

  /// When it is due, as a unix timestamp.
  final int? deadline;

  @override
  String toString() => '{Content:$content StartAt:$startedAt '
      'Deadline:$deadline}';
}

/// The arguments of `update_todo`. Go: `TodoUpdateParams`.
final class TodoUpdateParams {
  /// The arguments.
  const TodoUpdateParams({
    required this.id,
    this.content,
    this.startedAt,
    this.deadline,
    this.done,
  });

  /// Reads the arguments the model wrote.
  factory TodoUpdateParams.fromJson(Map<String, Object?> json) =>
      TodoUpdateParams(
        id: json['id'] as String? ?? '',
        content: json['content'] as String?,
        startedAt: (json['started_at'] as num?)?.toInt(),
        deadline: (json['deadline'] as num?)?.toInt(),
        done: json['done'] as bool?,
      );

  /// The id of the todo.
  final String id;

  /// The new content, if it changes.
  final String? content;

  /// The new start time, if it changes.
  final int? startedAt;

  /// The new deadline, if it changes.
  final int? deadline;

  /// The new done status, if it changes.
  final bool? done;

  @override
  String toString() => '{ID:$id Content:$content StartedAt:$startedAt '
      'Deadline:$deadline Done:$done}';
}

/// The tool that adds a todo, made from a [ToolInfo] and a function. Go:
/// `getAddTodoTool`, with `utils.NewTool`.
InvokableTool getAddTodoTool() {
  final info = ToolInfo.fromParams(
    name: 'add_todo',
    desc: 'Add a todo item',
    params: const {
      'content': ParameterInfo(
        desc: 'The content of the todo item',
        type: DataType.string,
        required: true,
      ),
      'started_at': ParameterInfo(
        desc: 'The started time of the todo item, in unix timestamp',
        type: DataType.integer,
      ),
      'deadline': ParameterInfo(
        desc: 'The deadline of the todo item, in unix timestamp',
        type: DataType.integer,
      ),
    },
  );

  return FunctionTool<TodoAddParams, String>.fromInfo(
    info,
    fromJson: TodoAddParams.fromJson,
    invoke: addTodoFunc,
  );
}

/// The tool that updates a todo, made from a typed function. Go:
/// `utils.InferTool("update_todo", ..., UpdateTodoFunc)`.
///
/// The schema is the one Go infers from the `json` and
/// `jsonschema_description` tags of `TodoUpdateParams`: the fields without
/// `omitempty` are required.
FunctionTool<TodoUpdateParams, String> newUpdateTodoTool() =>
    FunctionTool<TodoUpdateParams, String>(
      name: 'update_todo',
      description: 'Update a todo item, eg: content,deadline...',
      params: const ParamsOneOf.jsonSchemaMap({
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'id of the todo'},
          'content': {'type': 'string', 'description': 'content of the todo'},
          'started_at': {
            'type': 'integer',
            'description': 'start time in unix timestamp',
          },
          'deadline': {
            'type': 'integer',
            'description': 'deadline of the todo in unix timestamp',
          },
          'done': {'type': 'boolean', 'description': 'done status'},
        },
        'additionalProperties': false,
        'required': ['id'],
      }),
      fromJson: TodoUpdateParams.fromJson,
      invoke: updateTodoFunc,
    );

/// The tool that lists the todos, a class of its own. Go: `ListTodoTool`,
/// which implements the `InvokableTool` interface. The logic behind it is not
/// implemented here.
final class ListTodoTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'list_todo',
        desc: 'List all todo items',
        params: const {
          'finished': ParameterInfo(
            desc: 'filter todo items if finished',
            type: DataType.boolean,
          ),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    print('invoke tool list_todo: $argumentsJson');

    // The tool's logic goes here.

    return '{"todos": [{"id": "1", "content": "Finish preparing the Eino '
        'project presentation before December 10, 2024", "started_at": '
        '1717401600, "deadline": 1717488000, "done": false}]}';
  }
}

/// The function behind `add_todo`. Go: `AddTodoFunc`.
String addTodoFunc(RunContext ctx, TodoAddParams params, ToolOptions? options) {
  print('invoke tool add_todo: $params');

  // The tool's logic goes here.

  return '{"msg": "add todo success"}';
}

/// The function behind `update_todo`. Go: `UpdateTodoFunc`.
String updateTodoFunc(
  RunContext ctx,
  TodoUpdateParams params,
  ToolOptions? options,
) {
  print('invoke tool update_todo: $params');

  // The tool's logic goes here.

  return '{"msg": "update todo success"}';
}

/// A handler that prints when a component starts, ends or fails. It stands
/// in for the CozeLoop handler of the Go example.
///
/// Go: `callbacks.NewHandlerBuilder()`. A handler built from functions asks
/// only for the callbacks it has a function for.
ComponentCallbackHandler newLogHandler() => CallbackHandlerBuilder()
    .onStart((ctx, info, input) {
      print('[callback] start ${info.componentType.einoName} ${info.name}');
      return ctx;
    })
    .onEnd((ctx, info, output) {
      print('[callback] end ${info.componentType.einoName} ${info.name}');
      return ctx;
    })
    .onError((ctx, info, error, stackTrace) {
      print(
        '[callback] error ${info.componentType.einoName} ${info.name}: '
        '$error',
      );
      return ctx;
    })
    .build();

/// Builds the todo agent around [model] with the four tools, [searchTool]
/// among them, runs it once and prints the messages it returns.
///
/// Go: the body of `main` after the search tool and the model are created.
Future<List<Message>> runTodoAgent(
  ToolCallingChatModel model,
  BaseTool searchTool,
) async {
  final ctx = RunContext.background();

  final updateTool = newUpdateTodoTool();

  // Initialize the tools.
  final todoTools = <BaseTool>[
    getAddTodoTool(), // made the NewTool way
    updateTool, // made the InferTool way
    ListTodoTool(), // a class of its own; the logic behind it is not here
    searchTool,
  ];

  // Get the tool infos, to bind them to the chat model.
  final toolInfos = [for (final todoTool in todoTools) await todoTool.info()];

  // Bind the tools to the chat model. Go's BindTools changes the model;
  // withTools returns a copy with the tools bound.
  final chatModel = model.withTools(toolInfos);

  // Create the tools node.
  final todoToolsNode = await ToolsNode.create(
    ToolsNodeConfig(tools: todoTools),
    ctx: ctx,
  );

  // Build the whole chain.
  final chain = Chain<List<Message>, List<Message>>()
    ..appendChatModel(chatModel, options: const NodeOptions(name: 'chat_model'))
    ..appendToolsNode(todoToolsNode, options: const NodeOptions(name: 'tools'));

  // Compile and run the chain.
  final agent = await chain.compile(ctx);

  // Run the example. Go sets the temperature in the model's configuration;
  // here it is a call option, which reaches every chat model of the chain.
  final resp = await agent.invoke(
    ctx,
    [
      Message.user(
        'Add a TODO to learn Eino, and search for the repository address of '
        'cloudwego/eino',
      ),
    ],
    options: [CallOption.chatModel(const ChatModelOptions(temperature: 0.7))],
  );

  // Print the result.
  for (final (idx, msg) in resp.indexed) {
    print('');
    print('message $idx: ${msg.role.name}: ${msg.content}');
  }
  return resp;
}

Future<void> main() async {
  final model = exampleChatModel();
  if (model == null) return;

  // Go: callbacks.AppendGlobalHandlers(handlers...). Every run from now on
  // reports to these handlers, in addition to its own.
  GlobalCallbacks.append([newLogHandler()]);

  // Create the DuckDuckGo tool. Go: duckduckgo.NewTextSearchTool.
  final searchTool = DuckDuckGoSearchTool();
  try {
    await runTodoAgent(model, searchTool);
  } finally {
    searchTool.dispose();
    closeExampleModel(model);
  }
}
