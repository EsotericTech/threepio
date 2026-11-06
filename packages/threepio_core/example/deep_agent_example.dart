// ignore_for_file: avoid_print

/// A deep agent: a todo list, file tools over an in-memory file system, and
/// a sub-agent it hands a task to.
///
/// Port of the quick start of Eino's deep-agents guide
/// (`eino-ext/skills/eino-agent/reference/deep-agents.md`, Go package
/// `adk/prebuilt/deep`), in the spirit of eino-examples
/// `adk/multiagent/deep` without its Excel tools. What it shows:
///
/// * `DeepAgent.create` (Go `deep.New`) with an `InMemoryBackend` (Go
///   `filesystem.NewInMemoryBackend`): the agent gets `ls`, `read_file`,
///   `write_file`, `edit_file`, `glob` and `grep` over it.
/// * The todo list: the agent plans with `write_todos`, which keeps the list
///   in the session value `DeepAgent.sessionKeyTodos` (a `List<Todo>`); the
///   caller reads it after each round of tool calls with
///   `AgentRunOption.afterToolCallsHook` (Go `adk.WithAfterToolCallsHook`).
/// * A sub-agent: the `summarizer` is reached through the `task` tool and
///   starts with a fresh context (only the task's description). With
///   `ToolsConfig(emitInternalEvents: true)` its events reach the caller
///   too, named after it.
///
/// Run it with `OPENROUTER_API_KEY` or `OPENAI_API_KEY` set (see
/// `example/support/example_model.dart`):
///
/// ```bash
/// dart run example/deep_agent_example.dart
/// ```
library;

import 'package:threepio_core/adk.dart';

import 'support/example_model.dart';

Future<void> main() async {
  final model = exampleChatModel();
  if (model == null) return;
  try {
    final files = await notesWorkspace();
    final agent = await buildNotesAgent(model, files: files);
    await runDeepAgent(
      agent,
      'Summarize /notes/standup.md with the summarizer and write the summary '
      'to /notes/summary.md.',
    );
    await printWorkspace(files);
  } finally {
    closeExampleModel(model);
  }
}

/// An in-memory file system with the notes of a stand-up meeting.
Future<InMemoryBackend> notesWorkspace() async {
  final files = InMemoryBackend();
  await files.write(
    RunContext.background(),
    const WriteRequest(
      filePath: '/notes/standup.md',
      content: '# Stand-up, 5 November\n'
          '- Ada: the release branch is cut; the changelog still needs a pass.\n'
          '- Grace: the flaky checkpoint test is fixed.\n'
          '- Linus: blocked on the signing key until Friday.',
    ),
  );
  return files;
}

/// The deep agent over [files], with a `summarizer` sub-agent. The
/// sub-agent uses [summarizerModel], or [model] when it is `null`.
Future<Agent> buildNotesAgent(
  ToolCallingChatModel model, {
  required InMemoryBackend files,
  ToolCallingChatModel? summarizerModel,
}) async {
  // A plain ChatModelAgent; the deep agent starts it through its `task`
  // tool, by name, with the task's description as its only message.
  final summarizer = ChatModelAgent(ChatModelAgentConfig(
    name: 'summarizer',
    description: 'Summarizes a text in at most three bullet points. Give it '
        'the whole text in the task description.',
    instruction: 'Summarize the text you are given in at most three short '
        'bullet points. Answer with the bullet points only.',
    model: summarizerModel ?? model,
  ));
  // No instruction: the deep agent then uses Eino's built-in one. The
  // general-purpose sub-agent (a copy of this agent without `task`) is
  // added too, unless `withoutGeneralSubAgent` is set.
  return DeepAgent.create(
    RunContext.background(),
    DeepAgentConfig(
      name: 'notes-assistant',
      description: 'Works on the notes in the workspace',
      chatModel: model,
      backend: files,
      subAgents: [summarizer],
      toolsConfig: const ToolsConfig(emitInternalEvents: true),
    ),
  );
}

/// Runs [agent] on [task], printing its events, and returns its last
/// answer and the todo list as the agent left it.
Future<({String? answer, List<Todo> todos})> runDeepAgent(
  Agent agent,
  String task,
) async {
  var todos = const <Todo>[];
  final events = Runner(agent: agent).query(
    RunContext.background(),
    task,
    options: [
      // Called after every round of tool calls, with the run's context.
      AgentRunOption.afterToolCallsHook((ctx) {
        final current = ctx.sessionValue(DeepAgent.sessionKeyTodos);
        if (current is List<Todo>) todos = current;
      }),
    ],
  );
  String? answer;
  await for (final event in events.asStream()) {
    if (event.error case final error?) {
      Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
    }
    final message = await getMessageFromEvent(event);
    if (message == null) continue;
    final who = '[${event.agentName}]';
    for (final call in message.toolCalls ?? const <ToolCall>[]) {
      print('$who calls ${call.function.name} ${call.function.arguments}');
    }
    if (message.role == RoleType.tool) {
      print('$who ${event.messageOutput?.toolName} -> '
          '${_firstLine(message.content)}');
    } else if (message.content.isNotEmpty) {
      print('$who ${_firstLine(message.content)}');
      if (event.agentName == agent.name) answer = message.content;
    }
  }
  print('Todo list:');
  for (final todo in todos) {
    print('  [${todo.status}] ${todo.content}');
  }
  return (answer: answer, todos: todos);
}

/// Prints the entries of `/notes` and the summary the agent wrote.
Future<void> printWorkspace(InMemoryBackend files) async {
  final ctx = RunContext.background();
  print('Files:');
  for (final file in await files.lsInfo(ctx, const LsInfoRequest(path: '/notes'))) {
    print('  ${file.path} (${file.size} bytes)');
  }
  try {
    final summary = await files.read(
      ctx,
      const ReadRequest(filePath: '/notes/summary.md'),
    );
    print('/notes/summary.md:\n${summary.content}');
  } on ThreepioException {
    // The in-memory backend's "file not found": the model did not write it.
    print('/notes/summary.md was not written.');
  }
}

/// The first line of [text], marked when there is more.
String _firstLine(String text) {
  final end = text.indexOf('\n');
  return end < 0 ? text : '${text.substring(0, end)} …';
}
