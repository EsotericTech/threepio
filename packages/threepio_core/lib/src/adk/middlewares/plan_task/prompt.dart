/// The tool descriptions of the plan-task middleware, copied verbatim from
/// eino `adk/middlewares/plantask/task_{create,get,list,update}.go`.
@internal
library;

import 'package:meta/meta.dart';

import '../../eino/language.dart';

String _pick(String english, String chinese) =>
    selectPrompt(I18nPrompts(english: english, chinese: chinese));

/// The description of `TaskCreate`.
String taskCreateDescription() => _pick(_taskCreateDesc, _taskCreateDescChinese);

/// The description of `TaskGet`.
String taskGetDescription() => _pick(_taskGetDesc, _taskGetDescChinese);

/// The description of `TaskList`.
String taskListDescription() => _pick(_taskListDesc, _taskListDescChinese);

/// The description of `TaskUpdate`.
String taskUpdateDescription() => _pick(_taskUpdateDesc, _taskUpdateDescChinese);

const _taskCreateDesc = r'''
Use this tool to create a structured task list for your current coding session. This helps you track progress, organize complex tasks, and demonstrate thoroughness to the user.
It also helps the user understand the progress of the task and overall progress of their requests.

## When to Use This Tool

Use this tool proactively in these scenarios:

- Complex multi-step tasks - When a task requires 3 or more distinct steps or actions
- Non-trivial and complex tasks - Tasks that require careful planning or multiple operations
- Plan mode - When using plan mode, create a task list to track the work
- User explicitly requests todo list - When the user directly asks you to use the todo list
- User provides multiple tasks - When users provide a list of things to be done (numbered or comma-separated)
- After receiving new instructions - Immediately capture user requirements as tasks
- When you start working on a task - Mark it as in_progress BEFORE beginning work
- After completing a task - Mark it as completed and add any new follow-up tasks discovered during implementation

## When NOT to Use This Tool

Skip using this tool when:
- There is only a single, straightforward task
- The task is trivial and tracking it provides no organizational benefit
- The task can be completed in less than 3 trivial steps
- The task is purely conversational or informational

NOTE that you should not use this tool if there is only one trivial task to do. In this case you are better off just doing the task directly.

## Task Fields

- **subject**: A brief, actionable title in imperative form (e.g., "Fix authentication bug in login flow")
- **description**: Detailed description of what needs to be done, including context and acceptance criteria
- **activeForm**: Present continuous form shown in spinner when task is in_progress (e.g., "Fixing authentication bug"). This is displayed to the user while you work on the task.

**IMPORTANT**: Always provide activeForm when creating tasks. The subject should be imperative ("Run tests") while activeForm should be present continuous ("Running tests"). All tasks are created with status "pending".

## Tips

- Create tasks with clear, specific subjects that describe the outcome
- Include enough detail in the description for another agent to understand and complete the task
- After creating tasks, use TaskUpdate to set up dependencies (blocks/blockedBy) if needed
- Check TaskList first to avoid creating duplicate tasks
''';

const _taskCreateDescChinese = r'''
使用此工具为当前编码会话创建结构化的任务列表。这有助于跟踪进度、组织复杂任务，并向用户展示工作的完整性。
它还帮助用户了解任务的进度和请求的整体进展。

## 何时使用此工具

在以下场景中主动使用此工具：

- 复杂的多步骤任务 - 当任务需要 3 个或更多不同的步骤或操作时
- 非简单的复杂任务 - 需要仔细规划或多个操作的任务
- 计划模式 - 使用计划模式时，创建任务列表来跟踪工作
- 用户明确要求待办列表 - 当用户直接要求使用待办列表时
- 用户提供多个任务 - 当用户提供待办事项列表时（编号或逗号分隔）
- 收到新指令后 - 立即将用户需求记录为任务
- 开始处理任务时 - 在开始工作之前将其标记为 in_progress
- 完成任务后 - 将其标记为已完成，并添加实施过程中发现的任何后续任务

## 何时不使用此工具

在以下情况下跳过使用此工具：
- 只有一个简单直接的任务
- 任务很简单，跟踪它没有组织上的好处
- 任务可以在少于 3 个简单步骤内完成
- 任务纯粹是对话性或信息性的

注意：如果只有一个简单任务要做，不应该使用此工具。在这种情况下，直接完成任务更好。

## 任务字段

- **subject**：简短的、可操作的标题，使用祈使句形式（例如，"修复登录流程中的认证错误"）
- **description**：需要完成的工作的详细描述，包括上下文和验收标准
- **activeForm**：任务处于 in_progress 状态时在加载动画中显示的现在进行时形式（例如，"正在修复认证错误"）。这会在你处理任务时显示给用户。

**重要**：创建任务时始终提供 activeForm。subject 应该是祈使句（"运行测试"），而 activeForm 应该是现在进行时（"正在运行测试"）。所有任务创建时状态为 "pending"。

## 提示

- 创建具有清晰、具体主题的任务，描述预期结果
- 在描述中包含足够的细节，以便其他代理能够理解并完成任务
- 创建任务后，如果需要，使用 TaskUpdate 设置依赖关系（blocks/blockedBy）
- 先检查 TaskList 以避免创建重复任务
''';

const _taskGetDesc = r'''
Use this tool to retrieve a task by its ID from the task list.

## When to Use This Tool

- When you need the full description and context before starting work on a task
- To understand task dependencies (what it blocks, what blocks it)
- After being assigned a task, to get complete requirements

## Output

Returns full task details:
- **subject**: Task title
- **description**: Detailed requirements and context
- **status**: 'pending', 'in_progress', or 'completed'
- **blocks**: Tasks waiting on this one to complete
- **blockedBy**: Tasks that must complete before this one can start

## Tips

- After fetching a task, verify its blockedBy list is empty before beginning work.
- Use TaskList to see all tasks in summary form.
''';

const _taskGetDescChinese = r'''
使用此工具通过任务 ID 从任务列表中获取任务。

## 何时使用此工具

- 当你需要在开始处理任务之前获取完整的描述和上下文时
- 了解任务依赖关系（它阻塞什么，什么阻塞它）
- 被分配任务后，获取完整的需求

## 输出

返回完整的任务详情：
- **subject**：任务标题
- **description**：详细的需求和上下文
- **status**：'pending'、'in_progress' 或 'completed'
- **blocks**：等待此任务完成的任务
- **blockedBy**：必须在此任务开始之前完成的任务

## 提示

- 获取任务后，在开始工作之前验证其 blockedBy 列表是否为空。
- 使用 TaskList 查看所有任务的摘要形式。
''';

const _taskListDesc = r'''
Use this tool to list all tasks in the task list.

## When to Use This Tool

- To see what tasks are available to work on (status: 'pending', no owner, not blocked)
- To check overall progress on the project
- To find tasks that are blocked and need dependencies resolved
- After completing a task, to check for newly unblocked work or claim the next available task
- **Prefer working on tasks in ID order** (lowest ID first) when multiple tasks are available, as earlier tasks often set up context for later ones

## Output

Returns a summary of each task:
- **id**: Task identifier (use with TaskGet, TaskUpdate)
- **subject**: Brief description of the task
- **status**: 'pending', 'in_progress', or 'completed'
- **owner**: Agent ID if assigned, empty if available
- **blockedBy**: List of open task IDs that must be resolved first (tasks with blockedBy cannot be claimed until dependencies resolve)

Use TaskGet with a specific task ID to view full details including description and comments.
''';

const _taskListDescChinese = r'''
使用此工具列出任务列表中的所有任务。

## 何时使用此工具

- 查看可以处理的任务（状态：'pending'，无所有者，未被阻塞）
- 检查项目的整体进度
- 查找被阻塞且需要解决依赖关系的任务
- 完成任务后，检查新解除阻塞的工作或认领下一个可用任务
- **优先按 ID 顺序处理任务**（最小 ID 优先），当有多个任务可用时，因为较早的任务通常为后续任务建立上下文

## 输出

返回每个任务的摘要：
- **id**：任务标识符（与 TaskGet、TaskUpdate 一起使用）
- **subject**：任务的简要描述
- **status**：'pending'、'in_progress' 或 'completed'
- **owner**：如果已分配则为代理 ID，如果可用则为空
- **blockedBy**：必须首先解决的开放任务 ID 列表（具有 blockedBy 的任务在依赖关系解决之前无法被认领）

使用 TaskGet 配合特定任务 ID 查看完整详情，包括描述和评论。
''';

const _taskUpdateDesc = r'''
Use this tool to update a task in the task list.

## When to Use This Tool

**Mark tasks as resolved:**
- When you have completed the work described in a task
- When a task is no longer needed or has been superseded
- IMPORTANT: Always mark your assigned tasks as resolved when you finish them
- After resolving, call TaskList to find your next task

- ONLY mark a task as completed when you have FULLY accomplished it
- If you encounter errors, blockers, or cannot finish, keep the task as in_progress
- When blocked, create a new task describing what needs to be resolved
- Never mark a task as completed if:
  - Tests are failing
  - Implementation is partial
  - You encountered unresolved errors
  - You couldn't find necessary files or dependencies

**Delete tasks:**
- When a task is no longer relevant or was created in error
- Setting status to `deleted` permanently removes the task

**Update task details:**
- When requirements change or become clearer
- When establishing dependencies between tasks

## Fields You Can Update

- **status**: The task status (see Status Workflow below)
- **subject**: Change the task title (imperative form, e.g., "Run tests")
- **description**: Change the task description
- **activeForm**: Present continuous form shown in spinner when in_progress (e.g., "Running tests")
- **owner**: Change the task owner (agent name)
- **metadata**: Merge metadata keys into the task (set a key to null to delete it)
- **addBlocks**: Mark tasks that cannot start until this one completes
- **addBlockedBy**: Mark tasks that must complete before this one can start

## Status Workflow

Status progresses: `pending` → `in_progress` → `completed`

Use `deleted` to permanently remove a task.

## Staleness

Make sure to read a task's latest state using `TaskGet` before updating it.

## Examples

Mark task as in progress when starting work:
```json
{"taskId": "1", "status": "in_progress"}
```

Mark task as completed after finishing work:
```json
{"taskId": "1", "status": "completed"}
```

Delete a task:
```json
{"taskId": "1", "status": "deleted"}
```

Claim a task by setting owner:
```json
{"taskId": "1", "owner": "my-name"}
```

Set up task dependencies:
```json
{"taskId": "2", "addBlockedBy": ["1"]}
```
''';

const _taskUpdateDescChinese = r'''
使用此工具更新任务列表中的任务。

## 何时使用此工具

**将任务标记为已完成：**
- 当你完成了任务中描述的工作时
- 当任务不再需要或已被取代时
- 重要：完成分配给你的任务后，务必将其标记为已完成
- 完成后，调用 TaskList 查找下一个任务

- 只有在完全完成任务时才将其标记为已完成
- 如果遇到错误、阻塞或无法完成，请保持任务为 in_progress 状态
- 当被阻塞时，创建一个新任务描述需要解决的问题
- 在以下情况下不要将任务标记为已完成：
  - 测试失败
  - 实现不完整
  - 遇到未解决的错误
  - 找不到必要的文件或依赖项

**删除任务：**
- 当任务不再相关或创建错误时
- 将状态设置为 `deleted` 会永久删除任务

**更新任务详情：**
- 当需求变更或变得更清晰时
- 当建立任务之间的依赖关系时

## 可更新的字段

- **status**：任务状态（参见下方状态流程）
- **subject**：更改任务标题（使用祈使句形式，例如"运行测试"）
- **description**：更改任务描述
- **activeForm**：in_progress 状态时在加载动画中显示的现在进行时形式（例如"正在运行测试"）
- **owner**：更改任务所有者（代理名称）
- **metadata**：将元数据键合并到任务中（将键设置为 null 可删除它）
- **addBlocks**：标记在此任务完成之前无法开始的任务
- **addBlockedBy**：标记必须在此任务开始之前完成的任务

## 状态流程

状态进展：`pending` → `in_progress` → `completed`

使用 `deleted` 永久删除任务。

## 过期性

更新任务前，请确保使用 `TaskGet` 读取任务的最新状态。

## 示例

开始工作时将任务标记为进行中：
```json
{"taskId": "1", "status": "in_progress"}
```

完成工作后将任务标记为已完成：
```json
{"taskId": "1", "status": "completed"}
```

删除任务：
```json
{"taskId": "1", "status": "deleted"}
```

通过设置 owner 认领任务：
```json
{"taskId": "1", "owner": "my-name"}
```

设置任务依赖关系：
```json
{"taskId": "2", "addBlockedBy": ["1"]}
```
''';

