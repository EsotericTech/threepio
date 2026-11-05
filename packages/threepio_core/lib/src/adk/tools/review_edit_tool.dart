/// A tool whose arguments the user reviews, and may edit, before it runs.
///
/// Port of eino-examples `adk/common/tool/review_edit_wrapper.go`.
library;

import 'package:meta/meta.dart';

import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/resume.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/tool_info.dart';
import '../../schema/type_registry.dart';

/// The user's review of a tool call. Port of eino-examples
/// `ReviewEditResult`.
@immutable
final class ReviewEditResult {
  /// A review: edited arguments, "no need to edit", or a refusal.
  const ReviewEditResult({
    this.editedArgumentsJson,
    this.noNeedToEdit = false,
    this.disapproved = false,
    this.disapproveReason,
  });

  final String? editedArgumentsJson;
  final bool noNeedToEdit;
  final bool disapproved;
  final String? disapproveReason;
}

/// What a [ReviewEditTool] reports when it asks for a review; the caller
/// resumes it with the same object and [reviewResult] filled in.
///
/// Port of eino-examples `ReviewEditInfo`. It is the info of the interrupt
/// point and is registered with [TypeRegistry] (without [reviewResult],
/// which only travels as resume data).
@immutable
final class ReviewEditInfo {
  /// The request to review the call of [toolName] with [argumentsJson].
  const ReviewEditInfo({
    required this.toolName,
    required this.argumentsJson,
    this.reviewResult,
  });

  /// A request from its JSON form.
  factory ReviewEditInfo.fromJson(Map<String, Object?> json) => ReviewEditInfo(
        toolName: json['tool_name']! as String,
        argumentsJson: json['arguments_json']! as String,
      );

  final String toolName;
  final String argumentsJson;
  final ReviewEditResult? reviewResult;

  /// This request with the user's [result].
  ReviewEditInfo withResult(ReviewEditResult result) => ReviewEditInfo(
        toolName: toolName,
        argumentsJson: argumentsJson,
        reviewResult: result,
      );

  /// The JSON form.
  Map<String, Object?> toJson() =>
      {'tool_name': toolName, 'arguments_json': argumentsJson};

  @override
  bool operator ==(Object other) =>
      other is ReviewEditInfo &&
      other.toolName == toolName &&
      other.argumentsJson == argumentsJson;

  @override
  int get hashCode => Object.hash(toolName, argumentsJson);

  @override
  String toString() =>
      "Tool '$toolName' is about to be called with the following arguments:\n"
      '`\n$argumentsJson\n`\n\n'
      'Please review and either provide edited arguments in JSON format, '
      "reply with 'no need to edit', or reply with 'N' to disapprove the tool "
      'call.';
}

/// [tool] behind a review-and-edit step, with the three-state protocol of
/// the eino examples (see `ApprovableTool`): the resume data is a
/// [ReviewEditInfo] with a [ReviewEditResult]. Edited arguments run the tool
/// with them and tell the model so.
///
/// Port of eino-examples `InvokableReviewEditTool`.
final class ReviewEditTool extends InvokableTool {
  /// [tool] with a review step.
  ReviewEditTool(this.tool) {
    registerReviewEditTypes();
  }

  /// The tool that runs after the review.
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
        ReviewEditInfo(toolName: name, argumentsJson: argumentsJson),
        argumentsJson,
      );
    }
    final arguments = saved.state ?? argumentsJson;
    final review = getResumeContext<ReviewEditInfo>(ctx);
    if (!review.isResumeTarget) {
      throw statefulInterrupt(
        ctx,
        ReviewEditInfo(toolName: name, argumentsJson: arguments),
        arguments,
      );
    }
    final result = review.data?.reviewResult;
    if (!review.hasData || result == null) {
      throw ThreepioException("tool '$name' resumed with no review data");
    }
    if (result.disapproved) {
      final reason = result.disapproveReason;
      return reason != null
          ? "tool '$name' disapproved, reason: $reason"
          : "tool '$name' disapproved";
    }
    if (result.noNeedToEdit) {
      return tool.invokableRun(ctx, arguments, options: options);
    }
    final edited = result.editedArgumentsJson;
    if (edited != null) {
      final output = await tool.invokableRun(ctx, edited, options: options);
      return 'after presenting the tool call info to the user, the user '
          'explilcitly changed tool call arguments to $edited. Tool called, '
          'final result: $output';
    }
    throw ThreepioException("invalid review result for tool '$name'");
  }
}

/// Registers [ReviewEditInfo] with [TypeRegistry]. Idempotent.
@internal
void registerReviewEditTypes() {
  if (TypeRegistry.isRegistered<ReviewEditInfo>()) return;
  TypeRegistry.registerName<ReviewEditInfo>(
    'eino_examples_review_edit_info',
    fromJson: ReviewEditInfo.fromJson,
    toJson: (info) => info.toJson(),
  );
}
