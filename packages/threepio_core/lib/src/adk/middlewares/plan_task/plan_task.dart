/// A middleware that gives an agent a task list it keeps in files:
/// `TaskCreate`, `TaskGet`, `TaskUpdate` and `TaskList`.
///
/// Port of eino `adk/middlewares/plantask` (classic messages; the tools do
/// not depend on the message type).
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/tool/invokable_tool.dart';
import '../../../components/tool/tool_options.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/async_mutex.dart';
import '../../../schema/tool_info.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../filesystem/requests.dart';
import '../internal/go_compat.dart';
import 'prompt.dart';

final RegExp _validTaskId = RegExp(r'^\d+$');

const String _highWatermarkFileName = '.highwatermark';

const String _statusPending = 'pending';
const String _statusCompleted = 'completed';
const String _statusDeleted = 'deleted';

/// Which file to delete. Port of eino `plantask.DeleteRequest`.
@immutable
final class DeleteRequest {
  /// Deletes [filePath].
  const DeleteRequest({required this.filePath});

  /// The file.
  final String filePath;
}

/// Where the task files are kept. Port of eino `plantask.Backend`.
abstract interface class PlanTaskBackend {
  /// The entries directly under [request]'s path.
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request);

  /// The content of a file.
  Future<FileContent> read(RunContext ctx, ReadRequest request);

  /// Creates a file or replaces its content.
  Future<void> write(RunContext ctx, WriteRequest request);

  /// Removes a file.
  Future<void> delete(RunContext ctx, DeleteRequest request);
}

/// Gives the agent a task list, one JSON file per task under [baseDir].
///
/// Port of eino `plantask.New`. `beforeAgent` adds `TaskCreate`, `TaskGet`,
/// `TaskUpdate` and `TaskList`, which take turns (one lock per run). Tasks
/// are numbered from a `.highwatermark` file; they move from `pending` over
/// `in_progress` to `completed` (or are `deleted`), can block each other
/// (`TaskUpdate` refuses a cycle), and are all removed once every task is
/// completed.
final class PlanTaskMiddleware extends ChatModelAgentMiddleware {
  /// A task list in [baseDir] of [backend]. Throws [ArgumentError] for an
  /// empty [baseDir].
  PlanTaskMiddleware({required this.backend, required this.baseDir}) {
    if (baseDir.isEmpty) throw ArgumentError.value(baseDir, 'baseDir', 'baseDir is required');
  }

  /// Name of the create tool. Port of eino `TaskCreateToolName`.
  static const String taskCreateToolName = 'TaskCreate';

  /// Name of the get tool. Port of eino `TaskGetToolName`.
  static const String taskGetToolName = 'TaskGet';

  /// Name of the update tool. Port of eino `TaskUpdateToolName`.
  static const String taskUpdateToolName = 'TaskUpdate';

  /// Name of the list tool. Port of eino `TaskListToolName`.
  static const String taskListToolName = 'TaskList';

  /// Where the task files are kept.
  final PlanTaskBackend backend;

  /// The directory of the task files.
  final String baseDir;

  @override
  FutureOr<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) {
    agent.tools = [...agent.tools, ...planTaskTools(backend, baseDir)];
    return (ctx, agent);
  }
}

/// The four task tools on [backend], sharing one lock.
@visibleForTesting
List<InvokableTool> planTaskTools(PlanTaskBackend backend, String baseDir) {
  final lock = AsyncMutex();
  return [
    TaskCreateTool(backend, baseDir, lock),
    TaskGetTool(backend, baseDir, lock),
    TaskUpdateTool(backend, baseDir, lock),
    TaskListTool(backend, baseDir, lock),
  ];
}

/// One task as stored. Port of eino `task`.
@visibleForTesting
final class PlanTask {
  /// A task.
  PlanTask({
    required this.id,
    this.subject = '',
    this.description = '',
    this.status = '',
    this.blocks,
    this.blockedBy,
    this.activeForm = '',
    this.owner = '',
    this.metadata,
  });

  /// The task in [json] (missing fields take Go's zero values).
  factory PlanTask.fromJson(Map<String, Object?> json) => PlanTask(
        id: _string(json, 'id'),
        subject: _string(json, 'subject'),
        description: _string(json, 'description'),
        status: _string(json, 'status'),
        blocks: _stringList(json, 'blocks'),
        blockedBy: _stringList(json, 'blockedBy'),
        activeForm: _string(json, 'activeForm'),
        owner: _string(json, 'owner'),
        metadata: _map(json, 'metadata'),
      );

  /// The number of the task.
  String id;

  /// Its title.
  String subject;

  /// What has to be done.
  String description;

  /// `pending`, `in_progress` or `completed`.
  String status;

  /// The tasks this one blocks (`null` as Go's nil slice).
  List<String>? blocks;

  /// The tasks that block this one.
  List<String>? blockedBy;

  /// What is shown while the task is in progress.
  String activeForm;

  /// Who works on it.
  String owner;

  /// Anything else.
  Map<String, Object?>? metadata;

  /// The JSON eino writes (field order and `omitempty` as in Go).
  Map<String, Object?> toJson() => {
        'id': id,
        'subject': subject,
        'description': description,
        'status': status,
        'blocks': blocks,
        'blockedBy': blockedBy,
        if (activeForm.isNotEmpty) 'activeForm': activeForm,
        if (owner.isNotEmpty) 'owner': owner,
        if (metadata != null && metadata!.isNotEmpty) 'metadata': metadata,
      };

  /// The compact JSON text.
  String encode() => jsonEncode(toJson());
}

String _string(Map<String, Object?> json, String key) => switch (json[key]) {
      null => '',
      final String value => value,
      final value => throw ThreepioFormatException(
          'cannot unmarshal ${value.runtimeType} into field "$key" of type string',
        ),
    };

List<String>? _stringList(Map<String, Object?> json, String key) => switch (json[key]) {
      null => null,
      final List<Object?> values => [
          for (final value in values)
            if (value is String)
              value
            else
              throw ThreepioFormatException('cannot unmarshal ${value.runtimeType} into "$key"'),
        ],
      final value => throw ThreepioFormatException(
          'cannot unmarshal ${value.runtimeType} into field "$key" of type []string',
        ),
    };

Map<String, Object?>? _map(Map<String, Object?> json, String key) => switch (json[key]) {
      null => null,
      final Map<String, Object?> value => Map.of(value),
      final value => throw ThreepioFormatException(
          'cannot unmarshal ${value.runtimeType} into field "$key" of type map',
        ),
    };

Map<String, Object?> _decodeObject(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw ThreepioFormatException(error.message, source: text, cause: error);
  }
  if (decoded == null) return const {};
  if (decoded is! Map<String, Object?>) {
    throw ThreepioFormatException('cannot unmarshal ${decoded.runtimeType} into an object', source: text);
  }
  return decoded;
}

String _result(String text) => jsonEncode({'result': text});

/// Whether [taskId] is a task number. Port of `isValidTaskID`.
@visibleForTesting
bool isValidTaskId(String taskId) => _validTaskId.hasMatch(taskId);

/// [list] with [items] that are not in it yet added. Port of `appendUnique`.
@visibleForTesting
List<String> appendUnique(List<String>? list, Iterable<String> items) {
  final result = List<String>.of(list ?? const []);
  final seen = result.toSet();
  for (final item in items) {
    if (seen.add(item)) result.add(item);
  }
  return result;
}

/// Whether "[blockerId] blocks [blockedId]" would close a cycle. Port of
/// `hasCyclicDependency`.
@visibleForTesting
bool hasCyclicDependency(Map<String, PlanTask> tasks, String blockerId, String blockedId) {
  if (blockerId == blockedId) return true;
  return _canReach(tasks, blockedId, blockerId, <String>{});
}

bool _canReach(Map<String, PlanTask> tasks, String fromId, String toId, Set<String> visited) {
  if (fromId == toId) return true;
  if (!visited.add(fromId)) return false;
  final from = tasks[fromId];
  if (from == null) return false;
  for (final blocked in from.blocks ?? const <String>[]) {
    if (_canReach(tasks, blocked, toId, visited)) return true;
  }
  return false;
}

/// Every task under [baseDir], by id (compared as text, as in eino). Port of
/// `listTasks`.
@visibleForTesting
Future<List<PlanTask>> listPlanTasks(RunContext ctx, PlanTaskBackend backend, String baseDir) async {
  const name = PlanTaskMiddleware.taskListToolName;
  final List<FileInfo> files;
  try {
    files = await backend.lsInfo(ctx, LsInfoRequest(path: baseDir));
  } on Object catch (error) {
    throw ThreepioException(
      '$name list files in $baseDir failed, err: ${goValueString(error)}',
      cause: error,
    );
  }
  final tasks = <PlanTask>[];
  for (final file in files) {
    final fileName = goBase(file.path);
    if (!fileName.endsWith('.json')) continue;
    final taskId = fileName.substring(0, fileName.length - '.json'.length);
    if (!isValidTaskId(taskId)) continue;
    final FileContent content;
    try {
      content = await backend.read(ctx, ReadRequest(filePath: file.path));
    } on Object catch (error) {
      throw ThreepioException(
        '$name read task file ${file.path} failed, err: ${goValueString(error)}',
        cause: error,
      );
    }
    try {
      tasks.add(PlanTask.fromJson(_decodeObject(content.content)));
    } on ThreepioException catch (error) {
      throw ThreepioException(
        '$name parse task file ${file.path} failed, err: ${error.message}',
        cause: error,
      );
    }
  }
  tasks.sort((a, b) => a.id.compareTo(b.id));
  return tasks;
}

/// The base of the four tools. Port of the shared fields of eino's task
/// tools.
abstract base class _TaskTool extends InvokableTool {
  _TaskTool(this.backend, this.baseDir, this.lock);

  final PlanTaskBackend backend;
  final String baseDir;
  final AsyncMutex lock;

  Future<String> _invoke(RunContext ctx, String argumentsJson);

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) =>
      lock.protect(() => _invoke(ctx, argumentsJson));

  @override
  Future<String> run(String argumentsJson) => invokableRun(RunContext.background(), argumentsJson);

  String _taskPath(String taskId) => goJoin([baseDir, '$taskId.json']);
}

/// Go's `fmt.Sscanf(s, "%d")`: spaces before the number, no newlines.
final RegExp _leadingInt = RegExp(r'^[ \t]*([+-]?\d+)');

/// `TaskCreate`. Port of eino `taskCreateTool`.
@visibleForTesting
final class TaskCreateTool extends _TaskTool {
  /// The tool on [backend].
  TaskCreateTool(super.backend, super.baseDir, super.lock);

  static const _name = PlanTaskMiddleware.taskCreateToolName;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: _name,
        desc: taskCreateDescription(),
        params: const {
          'subject': ParameterInfo(
            type: DataType.string,
            desc: 'A brief title for the task',
            required: true,
          ),
          'description': ParameterInfo(
            type: DataType.string,
            desc: 'A detailed description of what needs to be done',
            required: true,
          ),
          'activeForm': ParameterInfo(
            type: DataType.string,
            desc: 'Present continuous form shown in spinner when in_progress (e.g., "Running tests")',
          ),
          'metadata': ParameterInfo(
            type: DataType.object,
            desc: 'Arbitrary metadata to attach to the task',
            subParams: {'propertyNames': ParameterInfo(type: DataType.string)},
          ),
        },
      );

  @override
  Future<String> _invoke(RunContext ctx, String argumentsJson) async {
    final args = _decodeObject(argumentsJson);
    final subject = _string(args, 'subject');
    final description = _string(args, 'description');
    final activeForm = _string(args, 'activeForm');
    final metadata = _map(args, 'metadata');

    final List<FileInfo> files;
    try {
      files = await backend.lsInfo(ctx, LsInfoRequest(path: baseDir));
    } on Object catch (error) {
      throw ThreepioException(
        '$_name list files in $baseDir failed, err: ${goValueString(error)}',
        cause: error,
      );
    }
    var highWatermark = 0;
    for (final file in files) {
      if (goBase(file.path) != _highWatermarkFileName) continue;
      final FileContent content;
      try {
        content = await backend.read(ctx, ReadRequest(filePath: file.path));
      } on Object catch (error) {
        throw ThreepioException(
          '$_name read highwatermark file ${file.path} failed, err: ${goValueString(error)}',
          cause: error,
        );
      }
      final match = _leadingInt.firstMatch(content.content);
      final value = match == null ? null : int.tryParse(match.group(1)!);
      if (value != null) highWatermark = value;
      break;
    }

    final taskId = highWatermark + 1;
    final taskFileName = '$taskId.json';
    for (final file in files) {
      if (goBase(file.path) == taskFileName) {
        throw ThreepioException('task #$taskId already exists');
      }
    }
    final task = PlanTask(
      id: '$taskId',
      subject: subject,
      description: description,
      status: _statusPending,
      blocks: [],
      blockedBy: [],
      activeForm: activeForm,
      metadata: metadata,
    );

    final watermarkPath = goJoin([baseDir, _highWatermarkFileName]);
    try {
      await backend.write(ctx, WriteRequest(filePath: watermarkPath, content: '$taskId'));
    } on Object catch (error) {
      throw ThreepioException(
        '$_name update highwatermark file $watermarkPath failed, err: ${goValueString(error)}',
        cause: error,
      );
    }
    try {
      await backend.write(ctx, WriteRequest(filePath: _taskPath('$taskId'), content: task.encode()));
    } on Object catch (error) {
      throw ThreepioException(
        '$_name create Task #$taskId failed, err: ${goValueString(error)}',
        cause: error,
      );
    }
    return _result('Task #$taskId created successfully: $subject');
  }
}

/// `TaskGet`. Port of eino `taskGetTool`.
@visibleForTesting
final class TaskGetTool extends _TaskTool {
  /// The tool on [backend].
  TaskGetTool(super.backend, super.baseDir, super.lock);

  static const _name = PlanTaskMiddleware.taskGetToolName;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: _name,
        desc: taskGetDescription(),
        params: const {
          'taskId': ParameterInfo(
            type: DataType.string,
            desc: 'The ID of the task to retrieve',
            required: true,
          ),
        },
      );

  @override
  Future<String> _invoke(RunContext ctx, String argumentsJson) async {
    final taskId = _string(_decodeObject(argumentsJson), 'taskId');
    if (!isValidTaskId(taskId)) {
      throw ThreepioException('$_name validate task ID failed, err: invalid format: $taskId');
    }
    final PlanTask task;
    try {
      final content = await backend.read(ctx, ReadRequest(filePath: _taskPath(taskId)));
      task = PlanTask.fromJson(_decodeObject(content.content));
    } on Object catch (error) {
      throw ThreepioException(
        '$_name get Task #$taskId failed, err: ${goValueString(error)}',
        cause: error,
      );
    }
    final out = StringBuffer()
      ..write('Task #${task.id}: ${task.subject}\n')
      ..write('Status: ${task.status}\n')
      ..write('Description: ${task.description}\n');
    final blockedBy = task.blockedBy ?? const <String>[];
    if (blockedBy.isNotEmpty) out.write('Blocked by: ${blockedBy.map((id) => '#$id').join(', ')}\n');
    final blocks = task.blocks ?? const <String>[];
    if (blocks.isNotEmpty) out.write('Blocks: ${blocks.map((id) => '#$id').join(', ')}\n');
    if (task.owner.isNotEmpty) out.write('Owner: ${task.owner}\n');
    return _result(out.toString());
  }
}

/// `TaskList`. Port of eino `taskListTool`.
@visibleForTesting
final class TaskListTool extends _TaskTool {
  /// The tool on [backend].
  TaskListTool(super.backend, super.baseDir, super.lock);

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: PlanTaskMiddleware.taskListToolName,
        desc: taskListDescription(),
        params: const {},
      );

  @override
  Future<String> _invoke(RunContext ctx, String argumentsJson) async {
    final tasks = await listPlanTasks(ctx, backend, baseDir);
    if (tasks.isEmpty) return _result('No tasks found.');
    final lines = <String>[];
    for (final task in tasks) {
      final line = StringBuffer('#${task.id} [${task.status}] ${task.subject}');
      if (task.owner.isNotEmpty) line.write(' [owner: ${task.owner}]');
      final blockedBy = task.blockedBy ?? const <String>[];
      if (blockedBy.isNotEmpty) {
        line.write(' [blocked by ${blockedBy.map((id) => '#$id').join(', ')}]');
      }
      lines.add(line.toString());
    }
    return _result(lines.join('\n'));
  }
}

/// `TaskUpdate`. Port of eino `taskUpdateTool`.
@visibleForTesting
final class TaskUpdateTool extends _TaskTool {
  /// The tool on [backend].
  TaskUpdateTool(super.backend, super.baseDir, super.lock);

  static const _name = PlanTaskMiddleware.taskUpdateToolName;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: _name,
        desc: taskUpdateDescription(),
        params: const {
          'taskId': ParameterInfo(
            type: DataType.string,
            desc: 'The ID of the task to update',
            required: true,
          ),
          'subject': ParameterInfo(type: DataType.string, desc: 'New subject for the task'),
          'description': ParameterInfo(type: DataType.string, desc: 'New description for the task'),
          'activeForm': ParameterInfo(
            type: DataType.string,
            desc: 'Present continuous form shown in spinner when in_progress (e.g., "Running tests")',
          ),
          'status': ParameterInfo(
            type: DataType.string,
            desc: "New status for the task: 'pending', 'in_progress', 'completed', or 'deleted'",
            enumValues: ['pending', 'in_progress', 'completed', 'deleted'],
          ),
          'addBlocks': ParameterInfo(
            type: DataType.array,
            desc: 'Task IDs that this task blocks',
            elemInfo: ParameterInfo(type: DataType.string),
          ),
          'addBlockedBy': ParameterInfo(
            type: DataType.array,
            desc: 'Task IDs that block this task',
            elemInfo: ParameterInfo(type: DataType.string),
          ),
          'owner': ParameterInfo(type: DataType.string, desc: 'New owner for the task'),
          'metadata': ParameterInfo(
            type: DataType.object,
            desc: 'Metadata keys to merge into the task. Set a key to null to delete it.',
            subParams: {'propertyNames': ParameterInfo(type: DataType.string)},
          ),
        },
      );

  @override
  Future<String> _invoke(RunContext ctx, String argumentsJson) async {
    final args = _decodeObject(argumentsJson);
    final taskId = _string(args, 'taskId');
    final subject = _string(args, 'subject');
    final description = _string(args, 'description');
    final activeForm = _string(args, 'activeForm');
    final status = _string(args, 'status');
    final addBlocks = _stringList(args, 'addBlocks') ?? const <String>[];
    final addBlockedBy = _stringList(args, 'addBlockedBy') ?? const <String>[];
    final owner = _string(args, 'owner');
    final metadata = _map(args, 'metadata');

    if (!isValidTaskId(taskId)) {
      throw ThreepioException('$_name validate task ID failed, err: invalid format: $taskId');
    }
    final taskPath = _taskPath(taskId);

    if (status == _statusDeleted) {
      try {
        await _removeFromDependencies(ctx, taskId);
      } on Object catch (error) {
        throw ThreepioException(
          '$_name remove Task #$taskId from dependencies failed, err: ${goValueString(error)}',
          cause: error,
        );
      }
      try {
        await backend.delete(ctx, DeleteRequest(filePath: taskPath));
      } on Object catch (error) {
        throw ThreepioException(
          '$_name delete Task #$taskId failed, err: ${goValueString(error)}',
          cause: error,
        );
      }
      return _result('Updated task #$taskId deleted');
    }

    final FileContent content;
    try {
      content = await backend.read(ctx, ReadRequest(filePath: taskPath));
    } on Object catch (error) {
      throw ThreepioException(
        '$_name read Task #$taskId failed, err: ${goValueString(error)}',
        cause: error,
      );
    }
    final PlanTask task;
    try {
      task = PlanTask.fromJson(_decodeObject(content.content));
    } on ThreepioException catch (error) {
      throw ThreepioException('$_name parse Task #$taskId failed, err: ${error.message}', cause: error);
    }

    final updated = <String>[];
    if (subject.isNotEmpty) {
      task.subject = subject;
      updated.add('subject');
    }
    if (description.isNotEmpty) {
      task.description = description;
      updated.add('description');
    }
    if (activeForm.isNotEmpty) {
      task.activeForm = activeForm;
      updated.add('activeForm');
    }
    if (status.isNotEmpty) {
      task.status = status;
      updated.add('status');
    }
    if (addBlocks.isNotEmpty || addBlockedBy.isNotEmpty) {
      final List<PlanTask> tasks;
      try {
        tasks = await listPlanTasks(ctx, backend, baseDir);
      } on Object catch (error) {
        throw ThreepioException(
          '$_name list tasks failed, err: ${goValueString(error)}',
          cause: error,
        );
      }
      final byId = {for (final other in tasks) other.id: other};
      if (addBlocks.isNotEmpty) {
        for (final blocked in addBlocks) {
          if (!isValidTaskId(blocked)) {
            throw ThreepioException(
              '$_name validate blocked task ID failed, err: invalid format: $blocked',
            );
          }
          if (hasCyclicDependency(byId, taskId, blocked)) {
            throw ThreepioException(
              '$_name adding Task #$blocked to blocks of Task #$taskId would create a cyclic dependency',
            );
          }
        }
        for (final blocked in addBlocks) {
          try {
            await _updateOther(ctx, blocked, blockedBy: taskId);
          } on Object catch (error) {
            throw ThreepioException(
              '$_name update Task #$taskId blocks failed, err: ${goValueString(error)}',
              cause: error,
            );
          }
        }
        task.blocks = appendUnique(task.blocks, addBlocks);
        updated.add('blocks');
      }
      if (addBlockedBy.isNotEmpty) {
        for (final blocking in addBlockedBy) {
          if (!isValidTaskId(blocking)) {
            throw ThreepioException(
              '$_name validate blocking task ID failed, err: invalid format: $blocking',
            );
          }
          if (hasCyclicDependency(byId, blocking, taskId)) {
            throw ThreepioException(
              '$_name adding Task #$blocking to blockedBy of Task #$taskId would create a cyclic dependency',
            );
          }
        }
        for (final blocking in addBlockedBy) {
          try {
            await _updateOther(ctx, blocking, blocks: taskId);
          } on Object catch (error) {
            throw ThreepioException(
              '$_name update Task #$taskId blockedBy failed, err: ${goValueString(error)}',
              cause: error,
            );
          }
        }
        task.blockedBy = appendUnique(task.blockedBy, addBlockedBy);
        updated.add('blockedBy');
      }
    }
    if (owner.isNotEmpty) {
      task.owner = owner;
      updated.add('owner');
    }
    if (metadata != null) {
      final merged = task.metadata ?? <String, Object?>{};
      for (final MapEntry(:key, :value) in metadata.entries) {
        if (value == null) {
          merged.remove(key);
        } else {
          merged[key] = value;
        }
      }
      task.metadata = merged;
      updated.add('metadata');
    }

    try {
      await backend.write(ctx, WriteRequest(filePath: taskPath, content: task.encode()));
    } on Object catch (error) {
      throw ThreepioException(
        '$_name write Task #$taskId failed, err: ${goValueString(error)}',
        cause: error,
      );
    }
    if (status == _statusCompleted) {
      try {
        await _deleteAllIfCompleted(ctx);
      } on Object catch (error) {
        throw ThreepioException(
          '$_name check and delete all tasks failed, err: ${goValueString(error)}',
          cause: error,
        );
      }
    }
    return _result('Updated task #$taskId ${updated.join(', ')}');
  }

  Future<void> _removeFromDependencies(RunContext ctx, String deletedId) async {
    for (final task in await listPlanTasks(ctx, backend, baseDir)) {
      if (task.id == deletedId) continue;
      final blocks = task.blocks ?? const <String>[];
      final blockedBy = task.blockedBy ?? const <String>[];
      final modified = blocks.contains(deletedId) || blockedBy.contains(deletedId);
      if (!modified) continue;
      task
        ..blocks = [for (final id in blocks) if (id != deletedId) id]
        ..blockedBy = [for (final id in blockedBy) if (id != deletedId) id];
      try {
        await backend.write(ctx, WriteRequest(filePath: _taskPath(task.id), content: task.encode()));
      } on Object catch (error) {
        throw ThreepioException(
          'failed to write task #${task.id}: ${goValueString(error)}',
          cause: error,
        );
      }
    }
  }

  /// Adds [blockedBy] to the blockers, or [blocks] to the blocked tasks, of
  /// task [targetId]. Port of `addBlockedByToTask` / `addBlocksToTask`.
  Future<void> _updateOther(RunContext ctx, String targetId, {String? blockedBy, String? blocks}) async {
    final path = _taskPath(targetId);
    final what = blockedBy != null ? 'blockedBy' : 'blocks';
    final FileContent content;
    try {
      content = await backend.read(ctx, ReadRequest(filePath: path));
    } on Object catch (error) {
      throw ThreepioException(
        'failed to read task #$targetId for updating $what: ${goValueString(error)}',
        cause: error,
      );
    }
    final PlanTask target;
    try {
      target = PlanTask.fromJson(_decodeObject(content.content));
    } on ThreepioException catch (error) {
      throw ThreepioException('failed to parse task #$targetId: ${error.message}', cause: error);
    }
    if (blockedBy != null) target.blockedBy = appendUnique(target.blockedBy, [blockedBy]);
    if (blocks != null) target.blocks = appendUnique(target.blocks, [blocks]);
    try {
      await backend.write(ctx, WriteRequest(filePath: path, content: target.encode()));
    } on Object catch (error) {
      throw ThreepioException(
        'failed to write task #$targetId: ${goValueString(error)}',
        cause: error,
      );
    }
  }

  /// Deletes every task once all are completed. Port of
  /// `checkIfNeedDeleteAllTasks`.
  Future<void> _deleteAllIfCompleted(RunContext ctx) async {
    final tasks = await listPlanTasks(ctx, backend, baseDir);
    if (tasks.any((task) => task.status != _statusCompleted)) return;
    for (final task in tasks) {
      await backend.delete(ctx, DeleteRequest(filePath: goJoin([baseDir, '${task.id}.json'])));
    }
  }
}
