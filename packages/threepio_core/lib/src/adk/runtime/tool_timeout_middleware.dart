/// The per-call timeout and failure handling of the Kortney runtime.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/model/cancel_token.dart';
import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../eino/middleware.dart';
import '../eino/middleware_context.dart' show ToolContext;
import 'legacy_run.dart';
import 'tool_call_context.dart';

/// Turns a tool call that takes longer than [timeout], is cancelled, or
/// fails into an error result, as the legacy runtime did.
///
/// It sits inside the approval and outside the legacy handlers, because the
/// legacy runtime timed and guarded the handler chain together with the tool
/// (`chain(...).timeout(toolTimeout)`). The tool is not cancelled on a
/// timeout; its result is ignored. Interrupts pass through.
@internal
final class ToolTimeoutMiddleware extends ChatModelAgentMiddleware {
  const ToolTimeoutMiddleware(this.timeout);

  final Duration timeout;

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argumentsJson, options) async {
        final run = legacyRunOf(ctx)!;
        final name = tool.name;
        ToolOutput output;
        try {
          final content =
              await next(ctx, argumentsJson, options).timeout(timeout);
          output = run.outputFor(tool.callId, content);
        } on TimeoutException {
          output = ToolOutput.error('$name timed out after ${timeout.inSeconds}s');
        } on CancelledException {
          output =
              const ToolOutput.error('Cancelled by the user before it finished.');
          // Any other failure is shown to the model, as the legacy runtime did.
          // ignore: avoid_catches_without_on_clauses
        } catch (error) {
          if (isInterrupt(error)) rethrow;
          output = ToolOutput.error('$name failed: $error');
        }
        run.setOutput(tool.callId, output);
        return legacyToolContent(output);
      };
}
