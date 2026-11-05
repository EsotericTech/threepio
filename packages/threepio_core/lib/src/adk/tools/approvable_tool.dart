/// A tool that asks the user before it runs.
///
/// Port of eino-examples `adk/common/tool/approval_wrapper.go`.
library;

import 'package:meta/meta.dart';

import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/resume.dart';
import '../../core/run_context.dart';
import '../../schema/tool_info.dart';
import '../../schema/type_registry.dart';

/// What an [ApprovableTool] reports when it asks for approval.
///
/// Port of eino-examples `ApprovalInfo`. It is the info of the interrupt
/// point (`InterruptCtx.info`) and is registered with [TypeRegistry].
@immutable
final class ApprovalInfo {
  /// The request to approve the call of [toolName] with [argumentsJson].
  const ApprovalInfo({required this.toolName, required this.argumentsJson});

  /// A request from its JSON form.
  factory ApprovalInfo.fromJson(Map<String, Object?> json) => ApprovalInfo(
        toolName: json['tool_name']! as String,
        argumentsJson: json['arguments_json']! as String,
      );

  final String toolName;
  final String argumentsJson;

  /// The JSON form.
  Map<String, Object?> toJson() =>
      {'tool_name': toolName, 'arguments_json': argumentsJson};

  @override
  bool operator ==(Object other) =>
      other is ApprovalInfo &&
      other.toolName == toolName &&
      other.argumentsJson == argumentsJson;

  @override
  int get hashCode => Object.hash(toolName, argumentsJson);

  @override
  String toString() => "tool '$toolName' interrupted with arguments "
      "'$argumentsJson', waiting for your approval, please answer with Y/N";
}

/// The answer to an [ApprovalInfo], sent as resume data to the interrupt
/// point. Port of eino-examples `ApprovalResult`.
@immutable
final class ApprovalResult {
  /// An answer.
  const ApprovalResult({required this.approved, this.disapproveReason});

  final bool approved;

  /// Why the call was refused, shown to the model.
  final String? disapproveReason;
}

/// [tool] behind an approval step, with the three-state protocol of the
/// eino examples:
///
/// 1. first call: interrupt with an [ApprovalInfo] and keep the arguments;
/// 2. resumed but not targeted (`Runner.resume`, or another point was
///    targeted): interrupt again with the same request;
/// 3. resumed as the target with an [ApprovalResult]: run the tool with the
///    kept arguments, or answer that it was refused.
///
/// Port of eino-examples `InvokableApprovableTool`.
final class ApprovableTool extends InvokableTool {
  /// [tool] with approval.
  ApprovableTool(this.tool) {
    registerApprovalTypes();
  }

  /// The tool that runs once approved.
  final InvokableTool tool;

  @override
  Future<ToolInfo> info() => tool.info();

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final name = (await info()).function.name;
    final saved = getInterruptState<String>(ctx);
    if (!saved.wasInterrupted) {
      throw statefulInterrupt(
        ctx,
        ApprovalInfo(toolName: name, argumentsJson: argumentsJson),
        argumentsJson,
      );
    }
    final arguments = saved.state ?? argumentsJson;
    final answer = getResumeContext<ApprovalResult>(ctx);
    if (answer.isResumeTarget && answer.hasData) {
      final result = answer.data!;
      if (result.approved) {
        return tool.invokableRun(ctx, arguments, options: options);
      }
      final reason = result.disapproveReason;
      return reason != null
          ? "tool '$name' disapproved, reason: $reason"
          : "tool '$name' disapproved";
    }
    if (!getResumeContext<Object>(ctx).isResumeTarget) {
      throw statefulInterrupt(
        ctx,
        ApprovalInfo(toolName: name, argumentsJson: arguments),
        arguments,
      );
    }
    return tool.invokableRun(ctx, arguments, options: options);
  }
}

/// Registers [ApprovalInfo] with [TypeRegistry]. Idempotent.
@internal
void registerApprovalTypes() {
  if (TypeRegistry.isRegistered<ApprovalInfo>()) return;
  TypeRegistry.registerName<ApprovalInfo>(
    'eino_examples_approval_info',
    fromJson: ApprovalInfo.fromJson,
    toJson: (info) => info.toJson(),
  );
}
