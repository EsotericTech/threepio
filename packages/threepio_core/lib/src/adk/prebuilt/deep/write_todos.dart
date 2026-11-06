/// The `write_todos` tool of the deep agent.
///
/// Port of `TODO`, `writeTodosArguments` and `typedNewWriteTodos` of eino
/// `adk/prebuilt/deep/deep.go`.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/tool/function_tool.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/tool_info.dart';
import '../../../schema/type_registry.dart';
import '../../eino/agent_context.dart';
import 'deep_agent.dart';
import 'prompt.dart';

/// One entry of the deep agent's todo list.
///
/// Port of eino `deep.TODO`. The `write_todos` tool replaces the whole list
/// and keeps it in the session value [DeepAgent.sessionKeyTodos]
/// (`List<Todo>`).
@immutable
final class Todo {
  /// A todo.
  const Todo({
    required this.content,
    required this.activeForm,
    required this.status,
  });

  /// A todo from its JSON form, as the model writes it. Missing fields are
  /// empty (Go's zero values); a field that is not a string is a
  /// [ThreepioFormatException].
  factory Todo.fromJson(Map<String, Object?> json) => Todo(
        content: _string(json, 'content'),
        activeForm: _string(json, 'activeForm'),
        status: _string(json, 'status'),
      );

  /// What is to be done.
  final String content;

  /// The present-continuous form shown while it is in progress.
  final String activeForm;

  /// `pending`, `in_progress` or `completed`.
  final String status;

  /// The JSON form (eino's field names and order).
  Map<String, Object?> toJson() => {
        'content': content,
        'activeForm': activeForm,
        'status': status,
      };

  @override
  bool operator ==(Object other) =>
      other is Todo &&
      other.content == content &&
      other.activeForm == activeForm &&
      other.status == status;

  @override
  int get hashCode => Object.hash(content, activeForm, status);

  @override
  String toString() => 'Todo($content, $activeForm, $status)';
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return '';
  if (value is! String) {
    throw ThreepioFormatException(
      'mismatched type with value: "$key" must be a string, got '
      '${jsonEncode(value)}',
    );
  }
  return value;
}

/// The name of the todo tool.
const writeTodosToolName = 'write_todos';

/// The parameters of the `write_todos` tool, as Go's `utils.InferTool`
/// derives them from `writeTodosArguments` (every field required, no other
/// properties, the status as an enum).
final JSONSchema _writeTodosParams = JSONSchema(
  properties: {
    'todos': JSONSchemaProperty(
      type: 'array',
      items: JSONSchemaProperty(
        type: 'object',
        properties: {
          'content': const JSONSchemaProperty(type: 'string'),
          'activeForm': const JSONSchemaProperty(type: 'string'),
          'status': JSONSchemaProperty.string(
            enumValues: const ['pending', 'in_progress', 'completed'],
          ),
        },
        required: const ['content', 'activeForm', 'status'],
        additionalProperties: false,
      ),
    ),
  },
  required: const ['todos'],
);

/// The todos of the tool's arguments; `null` is Go's nil slice.
List<Todo>? _todosOf(Map<String, Object?> json) {
  final todos = json['todos'];
  if (todos == null) return null;
  if (todos is! List) {
    throw ThreepioFormatException(
      'mismatched type with value: "todos" must be a list, got '
      '${jsonEncode(todos)}',
    );
  }
  return [
    for (final todo in todos)
      switch (todo) {
        null => const Todo(content: '', activeForm: '', status: ''),
        final Map<String, Object?> map => Todo.fromJson(map),
        _ => throw ThreepioFormatException(
            'mismatched type with value: a todo must be an object, got '
            '${jsonEncode(todo)}',
          ),
      },
  ];
}

/// The `write_todos` tool: stores the list it is given as the session value
/// [DeepAgent.sessionKeyTodos] and answers `Updated todo list to <json>`.
/// Port of the tool `typedNewWriteTodos` builds with `utils.InferTool`.
@internal
FunctionTool<List<Todo>?, String> newWriteTodosTool() {
  ensureDeepTypesRegistered();
  final result = deepWriteTodosResult();
  return FunctionTool<List<Todo>?, String>(
    name: writeTodosToolName,
    description: deepWriteTodosToolDescription(),
    params: ParamsOneOf.jsonSchema(_writeTodosParams),
    fromJson: _todosOf,
    invoke: (RunContext ctx, List<Todo>? todos, _) {
      ctx.addSessionValue(DeepAgent.sessionKeyTodos, todos);
      final json = todos == null
          ? 'null'
          : jsonEncode([for (final todo in todos) todo.toJson()]);
      return result.replaceFirst('%s', json);
    },
  );
}

/// Registers the todo types under eino's names. Idempotent; survives
/// `TypeRegistry.reset()` when called again. Port of the `init` of eino
/// `deep`.
@internal
void ensureDeepTypesRegistered() {
  if (!TypeRegistry.isRegistered<Todo>()) {
    TypeRegistry.registerName<Todo>(
      '_eino_adk_prebuilt_deep_todo',
      fromJson: Todo.fromJson,
      toJson: (todo) => todo.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<List<Todo>>()) {
    TypeRegistry.registerName<List<Todo>>(
      '_eino_adk_prebuilt_deep_todo_slice',
      fromJson: (json) => [
        for (final item in json['items']! as List<Object?>)
          Todo.fromJson(item! as Map<String, Object?>),
      ],
      toJson: (todos) => {
        'items': [for (final todo in todos) todo.toJson()],
      },
    );
  }
}
