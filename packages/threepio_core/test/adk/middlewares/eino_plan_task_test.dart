// Port of eino `adk/middlewares/plantask` tests (v0.9.22): plantask_test.go,
// task_create_test.go, task_get_test.go, task_list_test.go,
// task_update_test.go; backend_test.go (the test backend) is
// [_InMemoryBackend] below.
//
// Ported: TestNew, TestMiddlewareBeforeAgent, TestIntegration,
// TestTaskCreateTool, TestTaskCreateToolWithMetadata, TestTaskGetTool,
// TestTaskGetToolInvalidTaskID, TestTaskListTool, TestTaskUpdateTool,
// TestTaskUpdateToolOwnerAndMetadata, TestTaskUpdateToolBlocks,
// TestTaskUpdateToolDelete, TestTaskUpdateToolInvalidTaskID,
// TestTaskUpdateToolBlocksDeduplication, TestTaskUpdateToolBidirectionalBlocks,
// TestTaskUpdateToolBidirectionalBlockedBy,
// TestTaskUpdateToolBidirectionalWithNonExistentTask,
// TestTaskUpdateToolCyclicDependencyDetection,
// TestTaskUpdateToolDeleteCleansDependencies,
// TestTaskUpdateToolAutoDeleteAllTasksWhenAllCompleted,
// TestTaskUpdateToolNoDeleteWhenNotAllCompleted.
//
// Not ported:
// * TestNew: the nil-config and nil-backend cases (compile-time errors in
//   Dart: required parameter).
// * TestMiddlewareBeforeAgent: the nil `runCtx` case (the parameter is not
//   nullable in Dart).
// * TestNewTypedAgenticMessage: agentic messages are P13.
//
// Go's `sync.Mutex` → `AsyncMutex`; `sonic.MarshalString(task)` →
// `PlanTask(...).encode()`; `sonic.UnmarshalString` → `PlanTask.fromJson`;
// Go's private status constants are written out (`'pending'`, …).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/internal/go_compat.dart' show goDir, goJoin;
import 'package:threepio_core/src/adk/middlewares/plan_task/plan_task.dart'
    show PlanTask, TaskCreateTool, TaskGetTool, TaskListTool, TaskUpdateTool;
import 'package:threepio_core/src/adk/middlewares/plan_task/prompt.dart'
    show taskCreateDescription, taskGetDescription, taskListDescription, taskUpdateDescription;
import 'package:threepio_core/src/internal/async_mutex.dart';

final ctx = RunContext.background();

const _baseDir = '/tmp/tasks';
const _highWatermarkFileName = '.highwatermark';

const _statusPending = 'pending';
const _statusInProgress = 'in_progress';
const _statusCompleted = 'completed';

/// Go's test backend (`backend_test.go`): files in a map; `LsInfo` lists
/// the files directly in the directory.
final class _InMemoryBackend implements PlanTaskBackend {
  final Map<String, String> files = {};

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) async {
    var reqPath = request.path;
    if (reqPath.endsWith('/')) reqPath = reqPath.substring(0, reqPath.length - 1);
    return [
      for (final path in files.keys)
        if (goDir(path) == reqPath) FileInfo(path: path),
    ];
  }

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async {
    final content = files[request.filePath];
    if (content == null) throw FileNotFoundException(request.filePath);
    return FileContent(content);
  }

  @override
  Future<void> write(RunContext ctx, WriteRequest request) async {
    files[request.filePath] = request.content;
  }

  @override
  Future<void> delete(RunContext ctx, DeleteRequest request) async {
    files.remove(request.filePath);
  }
}

String _taskPath(String id) => goJoin([_baseDir, '$id.json']);

Future<void> _writeTask(_InMemoryBackend backend, PlanTask task) =>
    backend.write(ctx, WriteRequest(filePath: _taskPath(task.id), content: task.encode()));

Future<PlanTask> _readTask(_InMemoryBackend backend, String id) async {
  final content = await backend.read(ctx, ReadRequest(filePath: _taskPath(id)));
  return PlanTask.fromJson(jsonDecode(content.content) as Map<String, Object?>);
}

/// A task with the fields every Go test sets.
PlanTask _task(
  String id,
  String subject, {
  String description = 'Test description',
  String status = _statusPending,
  List<String>? blocks = const [],
  List<String>? blockedBy = const [],
}) =>
    PlanTask(
      id: id,
      subject: subject,
      description: description,
      status: status,
      blocks: blocks == null ? null : List.of(blocks),
      blockedBy: blockedBy == null ? null : List.of(blockedBy),
    );

/// Go `assert.Error` + `assert.Contains(err.Error(), …)`.
Matcher _throwsContaining(String part) => throwsA(
      predicate<Object?>((error) => '$error'.contains(part), 'an error containing "$part"'),
    );

/// Go `assert.Empty` on a slice: nil or empty.
Matcher get _emptyList => anyOf(isNull, isEmpty);

void main() {
  test('TestNew', () {
    // The nil-config and nil-backend cases are compile-time errors in Dart.
    expect(
      () => PlanTaskMiddleware(backend: _InMemoryBackend(), baseDir: ''),
      throwsA(isA<ArgumentError>().having((e) => '$e', 'text', contains('baseDir is required'))),
    );

    final m = PlanTaskMiddleware(backend: _InMemoryBackend(), baseDir: '/tmp/tasks');
    expect(m, isNotNull);
  });

  test('TestMiddlewareBeforeAgent', () async {
    final backend = _InMemoryBackend();
    final mw = PlanTaskMiddleware(backend: backend, baseDir: _baseDir);

    // Go's `BeforeAgent(ctx, nil)` case: not portable (non-nullable).

    final runCtx = ChatModelAgentContext(instruction: '', tools: const [], returnDirectly: const {});
    final (_, newRunCtx) = await mw.beforeAgent(ctx, runCtx);
    expect(newRunCtx, isNotNull);
    expect(newRunCtx.tools, hasLength(4));

    final toolNames = <String>[];
    for (final t in newRunCtx.tools) {
      final info = await t.info();
      toolNames.add(info.name);
    }
    expect(toolNames, contains('TaskCreate'));
    expect(toolNames, contains('TaskGet'));
    expect(toolNames, contains('TaskUpdate'));
    expect(toolNames, contains('TaskList'));
  });

  test('TestIntegration', () async {
    final backend = _InMemoryBackend();
    final lock = AsyncMutex();

    final createTool = TaskCreateTool(backend, _baseDir, lock);
    final getTool = TaskGetTool(backend, _baseDir, lock);
    final updateTool = TaskUpdateTool(backend, _baseDir, lock);
    final listTool = TaskListTool(backend, _baseDir, lock);

    var result = await createTool.invokableRun(ctx, '{"subject": "Task 1", "description": "First task"}');
    expect(result, contains('Task #1'));

    result = await createTool.invokableRun(ctx, '{"subject": "Task 2", "description": "Second task"}');
    expect(result, contains('Task #2'));

    await updateTool.invokableRun(ctx, '{"taskId": "2", "addBlockedBy": ["1"]}');

    result = await listTool.invokableRun(ctx, '{}');
    expect(result, contains('#1 [pending] Task 1'));
    expect(result, contains('#2 [pending] Task 2'));
    expect(result, contains('[blocked by #1]'));

    await updateTool.invokableRun(ctx, '{"taskId": "1", "status": "in_progress"}');

    result = await getTool.invokableRun(ctx, '{"taskId": "1"}');
    expect(result, contains('Status: in_progress'));

    await updateTool.invokableRun(ctx, '{"taskId": "1", "status": "completed"}');

    result = await listTool.invokableRun(ctx, '{}');
    expect(result, contains('#1 [completed] Task 1'));
  });

  test('TestTaskCreateTool', () async {
    final backend = _InMemoryBackend();
    final tool = TaskCreateTool(backend, _baseDir, AsyncMutex());

    final info = await tool.info();
    expect(info.name, PlanTaskMiddleware.taskCreateToolName);
    expect(info.desc, taskCreateDescription());

    var result = await tool.invokableRun(
      ctx,
      '{"subject": "Test Task", "description": "Test description", "activeForm": "Testing"}',
    );
    expect(result, '{"result":"Task #1 created successfully: Test Task"}');

    final taskData = await _readTask(backend, '1');
    expect(taskData.id, '1');
    expect(taskData.subject, 'Test Task');
    expect(taskData.description, 'Test description');
    expect(taskData.status, _statusPending);
    expect(taskData.activeForm, 'Testing');

    var hwContent = await backend.read(ctx, ReadRequest(filePath: goJoin([_baseDir, _highWatermarkFileName])));
    expect(hwContent.content, '1');

    result = await tool.invokableRun(ctx, '{"subject": "Second Task", "description": "Second description"}');
    expect(result, '{"result":"Task #2 created successfully: Second Task"}');

    hwContent = await backend.read(ctx, ReadRequest(filePath: goJoin([_baseDir, _highWatermarkFileName])));
    expect(hwContent.content, '2');
  });

  test('TestTaskCreateToolWithMetadata', () async {
    final backend = _InMemoryBackend();
    final tool = TaskCreateTool(backend, _baseDir, AsyncMutex());

    final result = await tool.invokableRun(
      ctx,
      '{"subject": "Task with metadata", "description": "Has metadata", "metadata": {"key1": "value1", "key2": "value2"}}',
    );
    expect(result, contains('Task #1 created successfully'));

    final taskData = await _readTask(backend, '1');
    expect(taskData.metadata?['key1'], 'value1');
    expect(taskData.metadata?['key2'], 'value2');
  });

  test('TestTaskGetTool', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Test Task', blocks: ['2', '3'], blockedBy: ['4']));

    final tool = TaskGetTool(backend, _baseDir, AsyncMutex());

    final info = await tool.info();
    expect(info.name, PlanTaskMiddleware.taskGetToolName);
    expect(info.desc, taskGetDescription());

    final result = await tool.invokableRun(ctx, '{"taskId": "1"}');
    expect(result, contains('Task #1: Test Task'));
    expect(result, contains('Status: $_statusPending'));
    expect(result, contains('Description: Test description'));
    expect(result, contains('Blocked by: #4'));
    expect(result, contains('Blocks: #2, #3'));

    await expectLater(tool.invokableRun(ctx, '{"taskId": "999"}'), throwsA(anything));
  });

  test('TestTaskGetToolInvalidTaskID', () async {
    final tool = TaskGetTool(_InMemoryBackend(), _baseDir, AsyncMutex());

    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "../../../etc/passwd"}'),
      _throwsContaining('validate task ID failed'),
    );
    await expectLater(tool.invokableRun(ctx, '{"taskId": "abc"}'), _throwsContaining('validate task ID failed'));
  });

  test('TestTaskListTool', () async {
    final backend = _InMemoryBackend();
    final tool = TaskListTool(backend, _baseDir, AsyncMutex());

    final info = await tool.info();
    expect(info.name, PlanTaskMiddleware.taskListToolName);
    expect(info.desc, taskListDescription());

    var result = await tool.invokableRun(ctx, '{}');
    expect(result, '{"result":"No tasks found."}');

    await _writeTask(backend, PlanTask(id: '1', subject: 'Task 1', status: _statusPending, blockedBy: ['2']));
    await _writeTask(
      backend,
      PlanTask(id: '2', subject: 'Task 2', status: _statusInProgress, owner: 'agent1'),
    );

    result = await tool.invokableRun(ctx, '{}');
    expect(result, contains('#1 [$_statusPending] Task 1'));
    expect(result, contains('[blocked by #2]'));
    expect(result, contains('#2 [$_statusInProgress] Task 2'));
    expect(result, contains('[owner: agent1]'));
  });

  test('TestTaskUpdateTool', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Original Subject', description: 'Original description'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    final info = await tool.info();
    expect(info.name, PlanTaskMiddleware.taskUpdateToolName);
    expect(info.desc, taskUpdateDescription());

    var result = await tool.invokableRun(ctx, '{"taskId": "1", "status": "in_progress"}');
    expect(result, contains('Updated task #1'));
    expect(result, contains('status'));

    var updated = await _readTask(backend, '1');
    expect(updated.status, _statusInProgress);

    result = await tool.invokableRun(
      ctx,
      '{"taskId": "1", "subject": "New Subject", "description": "New description"}',
    );
    expect(result, contains('subject'));
    expect(result, contains('description'));

    updated = await _readTask(backend, '1');
    expect(updated.subject, 'New Subject');
    expect(updated.description, 'New description');
  });

  test('TestTaskUpdateToolOwnerAndMetadata', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Test Task'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    var result = await tool.invokableRun(ctx, '{"taskId": "1", "owner": "agent1"}');
    expect(result, contains('owner'));

    var updated = await _readTask(backend, '1');
    expect(updated.owner, 'agent1');

    result = await tool.invokableRun(ctx, '{"taskId": "1", "metadata": {"key1": "value1", "key2": "value2"}}');
    expect(result, contains('metadata'));

    updated = await _readTask(backend, '1');
    expect(updated.metadata?['key1'], 'value1');
    expect(updated.metadata?['key2'], 'value2');

    await tool.invokableRun(ctx, '{"taskId": "1", "metadata": {"key1": null, "key3": "value3"}}');

    final updated2 = await _readTask(backend, '1');
    expect(updated2.metadata?.containsKey('key1') ?? false, isFalse);
    expect(updated2.metadata?['key2'], 'value2');
    expect(updated2.metadata?['key3'], 'value3');
  });

  test('TestTaskUpdateToolBlocks', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Test Task'));
    await _writeTask(backend, _task('2', 'Task 2'));
    await _writeTask(backend, _task('3', 'Task 3'));
    await _writeTask(backend, _task('4', 'Task 4'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    var result = await tool.invokableRun(ctx, '{"taskId": "1", "addBlocks": ["2", "3"]}');
    expect(result, contains('blocks'));

    var updated = await _readTask(backend, '1');
    expect(updated.blocks, ['2', '3']);

    result = await tool.invokableRun(ctx, '{"taskId": "1", "addBlockedBy": ["4"]}');
    expect(result, contains('blockedBy'));

    updated = await _readTask(backend, '1');
    expect(updated.blockedBy, ['4']);
  });

  test('TestTaskUpdateToolDelete', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Test Task', blocks: null, blockedBy: null));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    final result = await tool.invokableRun(ctx, '{"taskId": "1", "status": "deleted"}');
    expect(result, contains('deleted'));

    await expectLater(backend.read(ctx, ReadRequest(filePath: _taskPath('1'))), throwsA(anything));
  });

  test('TestTaskUpdateToolInvalidTaskID', () async {
    final backend = _InMemoryBackend();
    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "../../../etc/passwd", "status": "in_progress"}'),
      _throwsContaining('validate task ID failed'),
    );
    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "abc", "status": "in_progress"}'),
      _throwsContaining('validate task ID failed'),
    );
    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1.5", "status": "in_progress"}'),
      _throwsContaining('validate task ID failed'),
    );

    await _writeTask(backend, _task('1', 'Task 1'));

    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlocks": ["invalid"]}'),
      _throwsContaining('validate blocked task ID failed'),
    );
    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlockedBy": ["invalid"]}'),
      _throwsContaining('validate blocking task ID failed'),
    );
  });

  test('TestTaskUpdateToolBlocksDeduplication', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1'));
    await _writeTask(backend, _task('2', 'Task 2', blockedBy: ['1']));
    await _writeTask(backend, _task('3', 'Task 3', blocks: ['1']));
    await _writeTask(backend, _task('4', 'Task 4'));
    await _writeTask(backend, _task('5', 'Task 5'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await tool.invokableRun(ctx, '{"taskId": "1", "addBlocks": ["2", "4", "4"]}');

    var updated = await _readTask(backend, '1');
    expect(updated.blocks, ['2', '4']);

    await tool.invokableRun(ctx, '{"taskId": "1", "addBlockedBy": ["3", "5", "5"]}');

    updated = await _readTask(backend, '1');
    expect(updated.blockedBy, ['3', '5']);
  });

  test('TestTaskUpdateToolBidirectionalBlocks', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1', description: 'First task'));
    await _writeTask(backend, _task('2', 'Task 2', description: 'Second task'));
    await _writeTask(backend, _task('3', 'Task 3', description: 'Third task'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await tool.invokableRun(ctx, '{"taskId": "1", "addBlocks": ["2", "3"]}');

    final updatedTask1 = await _readTask(backend, '1');
    expect(updatedTask1.blocks, ['2', '3']);
    expect(updatedTask1.blockedBy, _emptyList);

    final updatedTask2 = await _readTask(backend, '2');
    expect(updatedTask2.blocks, _emptyList);
    expect(updatedTask2.blockedBy, ['1']);

    final updatedTask3 = await _readTask(backend, '3');
    expect(updatedTask3.blocks, _emptyList);
    expect(updatedTask3.blockedBy, ['1']);
  });

  test('TestTaskUpdateToolBidirectionalBlockedBy', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1', description: 'First task'));
    await _writeTask(backend, _task('2', 'Task 2', description: 'Second task'));
    await _writeTask(backend, _task('3', 'Task 3', description: 'Third task'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await tool.invokableRun(ctx, '{"taskId": "3", "addBlockedBy": ["1", "2"]}');

    final updatedTask3 = await _readTask(backend, '3');
    expect(updatedTask3.blocks, _emptyList);
    expect(updatedTask3.blockedBy, ['1', '2']);

    final updatedTask1 = await _readTask(backend, '1');
    expect(updatedTask1.blocks, ['3']);
    expect(updatedTask1.blockedBy, _emptyList);

    final updatedTask2 = await _readTask(backend, '2');
    expect(updatedTask2.blocks, ['3']);
    expect(updatedTask2.blockedBy, _emptyList);
  });

  test('TestTaskUpdateToolBidirectionalWithNonExistentTask', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1', description: 'First task'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlocks": ["999"]}'),
      _throwsContaining('update Task #1 blocks failed'),
    );
    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlockedBy": ["999"]}'),
      _throwsContaining('update Task #1 blockedBy failed'),
    );
  });

  test('TestTaskUpdateToolCyclicDependencyDetection', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1', description: 'First task'));
    await _writeTask(backend, _task('2', 'Task 2', description: 'Second task'));
    await _writeTask(backend, _task('3', 'Task 3', description: 'Third task'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlocks": ["1"]}'),
      _throwsContaining('cyclic dependency'),
    );
    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlockedBy": ["1"]}'),
      _throwsContaining('cyclic dependency'),
    );

    await tool.invokableRun(ctx, '{"taskId": "1", "addBlocks": ["2"]}');

    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "2", "addBlocks": ["1"]}'),
      _throwsContaining('cyclic dependency'),
    );
    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlockedBy": ["2"]}'),
      _throwsContaining('cyclic dependency'),
    );

    await tool.invokableRun(ctx, '{"taskId": "2", "addBlocks": ["3"]}');

    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "3", "addBlocks": ["1"]}'),
      _throwsContaining('cyclic dependency'),
    );
    await expectLater(
      tool.invokableRun(ctx, '{"taskId": "1", "addBlockedBy": ["3"]}'),
      _throwsContaining('cyclic dependency'),
    );

    final updatedTask1 = await _readTask(backend, '1');
    expect(updatedTask1.blocks, ['2']);
    expect(updatedTask1.blockedBy, _emptyList);

    final updatedTask2 = await _readTask(backend, '2');
    expect(updatedTask2.blocks, ['3']);
    expect(updatedTask2.blockedBy, ['1']);

    final updatedTask3 = await _readTask(backend, '3');
    expect(updatedTask3.blocks, _emptyList);
    expect(updatedTask3.blockedBy, ['2']);
  });

  test('TestTaskUpdateToolDeleteCleansDependencies', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1', description: 'First task', blocks: ['2', '3']));
    await _writeTask(
      backend,
      _task('2', 'Task 2', description: 'Second task', blocks: ['3'], blockedBy: ['1']),
    );
    await _writeTask(backend, _task('3', 'Task 3', description: 'Third task', blockedBy: ['1', '2']));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    final result = await tool.invokableRun(ctx, '{"taskId": "1", "status": "deleted"}');
    expect(result, contains('deleted'));

    await expectLater(backend.read(ctx, ReadRequest(filePath: _taskPath('1'))), throwsA(anything));

    final updatedTask2 = await _readTask(backend, '2');
    expect(updatedTask2.blocks, ['3']);
    expect(updatedTask2.blockedBy, _emptyList);

    final updatedTask3 = await _readTask(backend, '3');
    expect(updatedTask3.blocks, _emptyList);
    expect(updatedTask3.blockedBy, ['2']);
  });

  test('TestTaskUpdateToolAutoDeleteAllTasksWhenAllCompleted', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1', description: 'First task', status: _statusCompleted));
    await _writeTask(backend, _task('2', 'Task 2', description: 'Second task', status: _statusCompleted));
    await _writeTask(backend, _task('3', 'Task 3', description: 'Third task'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await tool.invokableRun(ctx, '{"taskId": "3", "status": "completed"}');

    await expectLater(backend.read(ctx, ReadRequest(filePath: _taskPath('1'))), throwsA(anything));
    await expectLater(backend.read(ctx, ReadRequest(filePath: _taskPath('2'))), throwsA(anything));
    await expectLater(backend.read(ctx, ReadRequest(filePath: _taskPath('3'))), throwsA(anything));
  });

  test('TestTaskUpdateToolNoDeleteWhenNotAllCompleted', () async {
    final backend = _InMemoryBackend();
    await _writeTask(backend, _task('1', 'Task 1', description: 'First task'));
    await _writeTask(backend, _task('2', 'Task 2', description: 'Second task'));

    final tool = TaskUpdateTool(backend, _baseDir, AsyncMutex());

    await tool.invokableRun(ctx, '{"taskId": "1", "status": "completed"}');

    await backend.read(ctx, ReadRequest(filePath: _taskPath('1')));
    await backend.read(ctx, ReadRequest(filePath: _taskPath('2')));

    final updatedTask1 = await _readTask(backend, '1');
    expect(updatedTask1.status, _statusCompleted);
  });
}
