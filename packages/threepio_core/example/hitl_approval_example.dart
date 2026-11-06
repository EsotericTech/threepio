// ignore_for_file: avoid_print

/// Agents with `package:threepio_core/adk.dart`: the smallest agent, then
/// human in the loop — a tool that asks before it does something
/// irreversible, and a run that is paused, saved and resumed with the
/// user's answer.
///
/// Port of the quick start of Eino's guide
/// `eino-ext/skills/eino-agent/reference/human-in-the-loop.md`, preceded by
/// the minimal agent of `chat-model-agent.md`, and of the flow of
/// eino-examples `adk/human-in-the-loop/1_approval`. It is written with the
/// core primitives instead of a ready-made wrapper
/// (`eino_examples/adk_hitl_approval.dart` uses the wrapper,
/// `ApprovableTool`):
///
/// 1. [quickStart]: a `ChatModelAgent` run by a `Runner` (Go
///    `adk.NewChatModelAgent`, `adk.NewRunner`, `Runner.Query`).
/// 2. [RefundTool]: on its first call the tool throws `statefulInterrupt`
///    with a [RefundApproval] for the user to see and the request as its
///    saved state (Go `compose.StatefulInterrupt`). The agent's run stops,
///    the runner saves a checkpoint under the checkpoint id, and the last
///    event carries the interrupt (`event.action.interrupted`).
/// 3. [runWithApproval]: the caller asks the user and resumes with
///    `Runner.resumeWithParams`, giving each interrupt id its answer (Go
///    `Runner.ResumeWithParams`).
/// 4. The tool runs again: `getInterruptState` gives back the saved request,
///    `getResumeContext` the answer (Go `compose.GetInterruptState`,
///    `compose.GetResumeContext`); it pays, or tells the model that the
///    user said no.
/// 5. [resumeInAnotherProcess]: what a fresh process does to finish the run
///    when the store outlives the process (a `FileCheckpointStore`): the
///    same agent, the checkpoint id and the interrupt id. `main` does not
///    call it.
///
/// Run it with `OPENROUTER_API_KEY` or `OPENAI_API_KEY` set (see
/// `example/support/example_model.dart`) and answer `y` or `n`:
///
/// ```bash
/// dart run example/hitl_approval_example.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/adk.dart';
import 'package:threepio_core/io.dart';

import 'support/example_model.dart';

Future<void> main() async {
  final model = exampleChatModel();
  if (model == null) return;
  try {
    await quickStart(model, 'What does a checkpoint store do, in one sentence?');

    final runner = refundRunner(
      model,
      tool: RefundTool(refund: _pretendToPay),
      store: InMemoryCheckpointStore(),
    );
    await runWithApproval(
      runner,
      'Order A-1001 arrived broken. Please refund the 42.50 I paid.',
      ask: (question) async {
        stdout.write('$question ');
        return stdin.readLineSync() ?? '';
      },
    );
  } finally {
    closeExampleModel(model);
  }
}

// ---------------------------------------------------------------------------
// 1. The smallest agent.
// ---------------------------------------------------------------------------

/// Asks a `ChatModelAgent` [question] through a `Runner` and prints what it
/// answers.
Future<void> quickStart(ToolCallingChatModel model, String question) async {
  final ctx = RunContext.background();
  final agent = ChatModelAgent(ChatModelAgentConfig(
    name: 'assistant',
    description: 'Answers questions',
    instruction: 'You are a helpful assistant.',
    model: model,
  ));
  final runner = Runner(agent: agent);
  await for (final event in runner.query(ctx, question).asStream()) {
    final message = await getMessageFromEvent(event);
    print(message?.content ?? event.error);
  }
}

// ---------------------------------------------------------------------------
// 2. A tool that asks first.
// ---------------------------------------------------------------------------

/// What the user is asked to approve. It is the info of the interrupt
/// point (`InterruptCtx.info`), which the caller shows as it likes; it is
/// not written to the checkpoint, so any object will do (Go's runner
/// checkpoint still gob-encodes it in the deprecated `Info` field, which is
/// why eino-examples registers `ApprovalInfo`; the Dart checkpoint keeps
/// only the address and saved state of each interrupt point).
final class RefundApproval {
  /// The refund of [amount] for the order [orderId].
  const RefundApproval({required this.orderId, required this.amount});

  /// The refund the model asked for (the tool's arguments).
  factory RefundApproval.fromJson(Map<String, Object?> json) => RefundApproval(
        orderId: json['order_id']! as String,
        amount: json['amount']! as num,
      );

  final String orderId;
  final num amount;

  @override
  String toString() => 'Refund $amount for order $orderId? [y/n]';
}

/// Refunds an order, but only once the user said yes.
///
/// The tools node calls the tool again, with the same arguments, when the
/// run is resumed. What the tool saves with `statefulInterrupt` is what it
/// needs then: here the request the user was shown, so that exactly that is
/// paid. The state must be JSON (or of a type registered with
/// `TypeRegistry`), because it is written to the checkpoint.
final class RefundTool extends InvokableTool {
  /// The tool; [refund] moves the money and says what happened.
  RefundTool({required this.refund});

  /// Pays `amount` back for `orderId`; the irreversible part.
  final Future<String> Function(String orderId, num amount) refund;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'issue_refund',
        desc: 'Refunds an order. The user is asked to approve it first.',
        params: const {
          'order_id': ParameterInfo(type: DataType.string, required: true),
          'amount': ParameterInfo(type: DataType.number, required: true),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final saved = getInterruptState<Map<String, Object?>>(ctx);
    if (!saved.wasInterrupted) {
      // First call: pay nothing yet. Pause the run, show the request, keep
      // it for the resumed call.
      final request = jsonDecode(argumentsJson) as Map<String, Object?>;
      throw statefulInterrupt(ctx, RefundApproval.fromJson(request), request);
    }
    // Resumed: the request saved above and the user's answer to it.
    final request = saved.state!;
    final answer = getResumeContext<bool>(ctx);
    if (!answer.hasData) {
      // Resumed without a yes/no for this call (`Runner.resume`, another
      // point answered, or this point given `null` or a non-bool): ask
      // again. eino-examples' `InvokableApprovableTool` runs the tool in the
      // last case; a payment waits for an explicit answer.
      throw statefulInterrupt(ctx, RefundApproval.fromJson(request), request);
    }
    final approval = RefundApproval.fromJson(request);
    if (answer.data != true) {
      return 'The user rejected the refund for order ${approval.orderId}; '
          'nothing was paid.';
    }
    return refund(approval.orderId, approval.amount);
  }
}

/// A support agent with [tool], run by a `Runner` that streams and saves
/// paused runs in [store].
///
/// An `InMemoryCheckpointStore` keeps them for this process; with a store
/// that outlives it, another process can finish the run (see
/// [resumeInAnotherProcess]).
Runner refundRunner(
  ToolCallingChatModel model, {
  required RefundTool tool,
  required CheckpointStore store,
}) {
  final agent = ChatModelAgent(ChatModelAgentConfig(
    name: 'support',
    description: 'Customer support for orders',
    instruction: 'You are a customer support agent. Refund orders with the '
        'issue_refund tool. Answer in one or two sentences.',
    model: model,
    toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
  ));
  return Runner(agent: agent, enableStreaming: true, checkpointStore: store);
}

// ---------------------------------------------------------------------------
// 3. Interrupt, ask, resume.
// ---------------------------------------------------------------------------

/// Runs [request] to its end. Whenever the run pauses, asks the user about
/// each interrupt point with [ask] and resumes the saved run with the
/// answers. Returns the agent's last answer.
Future<String?> runWithApproval(
  Runner runner,
  String request, {
  required Future<String> Function(String question) ask,
  String checkpointId = 'refund-1',
}) async {
  final ctx = RunContext.background();
  var events = runner.query(
    ctx,
    request,
    options: [AgentRunOption.checkpointId(checkpointId)],
  );
  while (true) {
    final (answer, interrupted) = await printEvents(events);
    if (interrupted == null) return answer;
    // One point per tool call that asked; each is answered by its id.
    final targets = <String, Object?>{};
    for (final point in interrupted.interruptContexts) {
      final reply = await ask('${point.info}');
      targets[point.id] = reply.trim().toLowerCase() == 'y';
    }
    events = await runner.resumeWithParams(
      ctx,
      checkpointId,
      ResumeParams(targets: targets),
    );
  }
}

/// What another process does to finish a run that this one paused.
///
/// It builds the same agent and runner over a store that outlives the
/// process — here a `FileCheckpointStore` (`package:threepio_core/io.dart`)
/// over the directory the first runner wrote to; a store over a database
/// works the same way — and resumes with the checkpoint id and the
/// interrupt id, which the first process kept with its question (in a
/// database, for example). Returns the agent's last answer.
Future<String?> resumeInAnotherProcess(
  ToolCallingChatModel model, {
  required RefundTool tool,
  required Directory checkpoints,
  required String checkpointId,
  required String interruptId,
  required bool approved,
}) async {
  final runner = refundRunner(
    model,
    tool: tool,
    store: FileCheckpointStore(checkpoints),
  );
  final events = await runner.resumeWithParams(
    RunContext.background(),
    checkpointId,
    ResumeParams(targets: {interruptId: approved}),
  );
  final (answer, _) = await printEvents(events);
  return answer;
}

/// Prints the events of one run (tool calls, tool results, answers) and
/// returns the last answer and, when the run paused, the interrupt (the
/// last event of the run).
Future<(String?, AgentInterruptInfo?)> printEvents(
  StreamReader<AgentEvent> events,
) async {
  String? answer;
  AgentInterruptInfo? interrupted;
  await for (final event in events.asStream()) {
    if (event.error case final error?) {
      Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
    }
    interrupted = event.action?.interrupted ?? interrupted;
    // A streamed message is joined; the event stays readable.
    final message = await getMessageFromEvent(event);
    if (message == null) continue;
    for (final call in message.toolCalls ?? const <ToolCall>[]) {
      print('[${event.agentName}] calls ${call.function.name} '
          '${call.function.arguments}');
    }
    if (message.role == RoleType.tool) {
      print('[${event.agentName}] ${event.messageOutput?.toolName} -> '
          '${message.content}');
    } else if (message.content.isNotEmpty) {
      answer = message.content;
      print('[${event.agentName}] $answer');
    }
  }
  return (answer, interrupted);
}

Future<String> _pretendToPay(String orderId, num amount) async =>
    'Refunded $amount for order $orderId.';
