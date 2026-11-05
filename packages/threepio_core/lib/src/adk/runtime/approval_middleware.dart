/// Approval of tool calls in the Kortney runtime.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../schema/message.dart';
import '../eino/agent_context.dart';
import '../eino/agent_event.dart' as eino;
import '../eino/middleware.dart';
import '../eino/middleware_context.dart' show ToolContext;
import 'chat_model_agent.dart';
import 'legacy_run.dart';
import 'tool_call_context.dart';

/// The outermost tool middleware of the Kortney runtime.
///
/// Asks for approval where the [ApprovalPolicy] wants it: the request is
/// sent as an event, then the call waits for the in-process answer
/// (`RunHandle.approve`), for the approval timeout of the runner, or for the
/// run's cancel, as the legacy runtime did. Nothing is serialized and the
/// run never interrupts for it. A denied call gets the legacy text `The user
/// declined to run this tool.`. Every call's result is reported to the event
/// mapper here, after all layers, with the time from the start of the call.
@internal
final class ApprovalMiddleware extends ChatModelAgentMiddleware {
  const ApprovalMiddleware(this.policy);

  final ApprovalPolicy policy;

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argumentsJson, options) async {
        final run = legacyRunOf(ctx)!;
        final stopwatch = Stopwatch()..start();
        final call = run.toolCallFor(tool.callId, tool.name, argumentsJson);
        if (await skippedForCancel(ctx, run, call)) {
          return legacyCancelledToolMessage(call).content;
        }
        final reason = policy.approvalReason(call);
        final ToolOutput output;
        if (reason != null && !await _approved(ctx, run, call, reason)) {
          output = const ToolOutput.error('The user declined to run this tool.');
        } else {
          output = run.outputFor(call.id, await next(ctx, argumentsJson, options));
        }
        await reportToolResult(ctx, run, call, output, stopwatch);
        return legacyToolContent(output);
      };

  static Future<bool> _approved(
    RunContext ctx,
    LegacyRun run,
    ToolCall call,
    String reason,
  ) async {
    await ctx.sendEvent(
      eino.AgentEvent(
        output: eino.AgentOutput(
          customizedOutput: FacadeApprovalRequested(call, reason),
        ),
      ),
    );
    final request = run.scope.requestApproval;
    if (request == null) return false;
    final cancel = run.scope.cancelToken;
    final decision = await Future.any<bool>([
      request(call, reason),
      cancel.whenCancelled.then((_) => false),
    ]);
    return decision && !cancel.isCancelled;
  }
}

/// Notes the legacy tool message of [call] and reports [output] to the
/// event mapper.
@internal
Future<void> reportToolResult(
  RunContext ctx,
  LegacyRun run,
  ToolCall call,
  ToolOutput output,
  Stopwatch stopwatch,
) async {
  run.noteToolMessage(call, output);
  await ctx.sendEvent(
    eino.AgentEvent(
      output: eino.AgentOutput(
        customizedOutput:
            FacadeToolResult(call, output, stopwatch.elapsedMilliseconds),
      ),
    ),
  );
}

/// Whether [call] is not started because the run was cancelled: with
/// sequential tool execution the legacy runtime checked the cancel token
/// before each call and left the rest of the turn unstarted. (With parallel
/// execution every call had started; the event mapper stops waiting for them
/// instead.) A skipped call is reported to the event mapper.
@internal
Future<bool> skippedForCancel(
  RunContext ctx,
  LegacyRun run,
  ToolCall call,
) async {
  if (run.config.parallelToolExecution || !run.scope.cancelToken.isCancelled) {
    return false;
  }
  await ctx.sendEvent(
    eino.AgentEvent(
      output: eino.AgentOutput(customizedOutput: FacadeToolSkipped(call)),
    ),
  );
  return true;
}

/// The legacy answer to a call of a tool the agent does not have: the error
/// result `Unknown tool: <name>`, without approval and without the handlers.
@internal
Future<String> legacyUnknownTool(RunContext ctx, String name, String input) async {
  final run = legacyRunOf(ctx)!;
  final stopwatch = Stopwatch()..start();
  final call = run.toolCallFor(toolCallIdOf(ctx) ?? '', name, input);
  if (await skippedForCancel(ctx, run, call)) {
    return legacyCancelledToolMessage(call).content;
  }
  final output = ToolOutput.error('Unknown tool: $name');
  await reportToolResult(ctx, run, call, output, stopwatch);
  return legacyToolContent(output);
}
