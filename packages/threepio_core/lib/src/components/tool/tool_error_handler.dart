/// Tools that report their failures to the model instead of ending the run.
///
/// Port of eino `components/tool/utils/error_handler.go`.
library;

import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import 'invokable_tool.dart';
import 'tool_options.dart';

/// Turns what a tool threw into the result the model gets to see.
///
/// Port of eino `utils.ErrorHandler`. `error` is whatever the tool threw, an
/// `Exception` or an `Error`.
typedef ToolErrorHandler = String Function(RunContext ctx, Object error);

/// Wraps [tool] so that a failed call returns the text [handler] makes of the
/// error instead of throwing.
///
/// Port of eino `utils.WrapToolWithErrorHandler`. A model can usually recover
/// from a failed tool call when it is told what went wrong; without this, the
/// error ends the run.
///
/// ```dart
/// final safe = wrapToolWithErrorHandler(
///   searchTool,
///   (ctx, error) => 'The search failed: $error. Try other keywords.',
/// );
/// ```
///
/// The result is an [InvokableTool] when [tool] is one, a [StreamableTool]
/// when it is one, and both when it is both. A tool that is neither is
/// returned as it is. The wrapper is known by these two contracts only: as in
/// Eino, whatever else [tool] is (an enhanced tool, a subclass with methods
/// of its own) is not carried over.
///
/// Two things are never handed to [handler] but thrown on:
///
/// * an [InterruptSignal], also one wrapped in another exception (see
///   [isInterrupt]). It pauses the run for a resume; turned into a result,
///   the run would go on and the checkpoint would never be written.
/// * anything thrown after the context of the call was cancelled. A cancelled
///   run stops; it does not tell the model about it. (Called through `run` or
///   `streamRun`, a tool has no run context, and a `CancelledException` it
///   throws is a failure like any other.)
BaseTool wrapToolWithErrorHandler(BaseTool tool, ToolErrorHandler handler) {
  final invokable = tool is InvokableTool ? tool : null;
  final streamable = tool is StreamableTool ? tool : null;

  if (invokable != null && streamable != null) {
    return _CombinedErrorTool(invokable, streamable, handler);
  }
  if (invokable != null) return _InvokableErrorTool(invokable, handler);
  if (streamable != null) return _StreamableErrorTool(streamable, handler);
  return tool;
}

/// Wraps an invokable [tool] so that a failed call returns the text [handler]
/// makes of the error.
///
/// Port of eino `utils.WrapInvokableToolWithErrorHandler`. See
/// [wrapToolWithErrorHandler] for what is not handled.
InvokableTool wrapInvokableToolWithErrorHandler(
  InvokableTool tool,
  ToolErrorHandler handler,
) =>
    _InvokableErrorTool(tool, handler);

/// Wraps a streaming [tool] so that a call that fails to start returns a
/// stream with one item, the text [handler] makes of the error.
///
/// Port of eino `utils.WrapStreamableToolWithErrorHandler`. As in Eino, only
/// the start of the stream is covered: an error that arrives while the stream
/// is read is passed on to the reader. See [wrapToolWithErrorHandler] for
/// what is not handled.
StreamableTool wrapStreamableToolWithErrorHandler(
  StreamableTool tool,
  ToolErrorHandler handler,
) =>
    _StreamableErrorTool(tool, handler);

/// Whether [error], thrown under [ctx], has to reach the caller untouched.
bool _mustPropagate(RunContext ctx, Object error) =>
    isInterrupt(error) || ctx.cancelToken.isCancelled;

Future<String> _invokeHandled(
  InvokableTool tool,
  ToolErrorHandler handler,
  RunContext ctx,
  String argumentsJson,
  ToolOptions? options,
) async {
  try {
    return await tool.invokableRun(ctx, argumentsJson, options: options);
    // Whatever the tool threw is what the handler is there for.
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    if (_mustPropagate(ctx, error)) rethrow;
    return handler(ctx, error);
  }
}

Future<StreamReader<String>> _streamHandled(
  StreamableTool tool,
  ToolErrorHandler handler,
  RunContext ctx,
  String argumentsJson,
  ToolOptions? options,
) async {
  try {
    return await tool.streamableRun(ctx, argumentsJson, options: options);
    // Whatever the tool threw is what the handler is there for.
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    if (_mustPropagate(ctx, error)) rethrow;
    return StreamReader.fromIterable([handler(ctx, error)]);
  }
}

final class _InvokableErrorTool extends InvokableTool {
  _InvokableErrorTool(this._tool, this._handler);

  final InvokableTool _tool;
  final ToolErrorHandler _handler;

  @override
  Future<ToolInfo> info() => _tool.info();

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _invokeHandled(_tool, _handler, ctx, argumentsJson, options);

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);
}

final class _StreamableErrorTool extends StreamableTool {
  _StreamableErrorTool(this._tool, this._handler);

  final StreamableTool _tool;
  final ToolErrorHandler _handler;

  @override
  Future<ToolInfo> info() => _tool.info();

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _streamHandled(_tool, _handler, ctx, argumentsJson, options);

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) =>
      streamableRun(RunContext.background(), argumentsJson);
}

final class _CombinedErrorTool extends InvokableTool implements StreamableTool {
  _CombinedErrorTool(this._invokable, this._streamable, this._handler);

  final InvokableTool _invokable;
  final StreamableTool _streamable;
  final ToolErrorHandler _handler;

  @override
  Future<ToolInfo> info() => _invokable.info();

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _invokeHandled(_invokable, _handler, ctx, argumentsJson, options);

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _streamHandled(_streamable, _handler, ctx, argumentsJson, options);

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) =>
      streamableRun(RunContext.background(), argumentsJson);
}
