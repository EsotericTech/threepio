/// Tools whose results can be more than text.
library;

import '../../core/run_context.dart';
import '../../schema/tool_result.dart';
import '../../streaming/stream_reader.dart';
import 'invokable_tool.dart';
import 'tool_options.dart';

/// A tool that returns a structured, multimodal result.
///
/// Port of eino `tool.EnhancedInvokableTool`. Where an [InvokableTool] takes
/// a JSON string and returns a string, an enhanced tool takes a
/// [ToolArgument] and returns a [ToolResult], which can carry text, images,
/// audio, video and files.
///
/// The method has a name of its own, [enhancedInvokableRun], because Dart has
/// no overloading: one class can then offer both forms.
///
/// ```dart
/// final class Screenshot extends InvokableTool implements EnhancedInvokableTool {
///   @override
///   Future<ToolInfo> info() async => _info;
///
///   // For callers that only understand text.
///   @override
///   Future<String> invokableRun(RunContext ctx, String argumentsJson,
///           {ToolOptions? options}) async =>
///       'A screenshot was taken.';
///
///   @override
///   Future<ToolResult> enhancedInvokableRun(RunContext ctx, ToolArgument argument,
///           {ToolOptions? options}) async =>
///       ToolResult([
///         ToolOutputPart(type: ToolPartType.image, image: await _capture()),
///       ]);
/// }
/// ```
///
/// When a tool implements both, a tools node calls the enhanced form.
// ignore: one_member_abstracts
abstract interface class EnhancedInvokableTool implements BaseTool {
  /// Runs the tool with [argument] and returns its result.
  ///
  /// [ctx] is the context of the call and [options] are the options of this
  /// one call.
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  });
}

/// A tool that streams a structured, multimodal result.
///
/// Port of eino `tool.EnhancedStreamableTool`, the streaming form of
/// [EnhancedInvokableTool]: the chunks are [ToolResult]s that
/// `concatToolResults` joins into one.
// ignore: one_member_abstracts
abstract interface class EnhancedStreamableTool implements BaseTool {
  /// Runs the tool with [argument] and returns the stream of its result.
  ///
  /// The caller closes the returned reader.
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  });
}
