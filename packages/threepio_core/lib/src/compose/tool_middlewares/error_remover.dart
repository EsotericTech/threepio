part of '../tool_middleware.dart';

/// Writes the text a model reads in place of the result of a failed tool
/// call.
typedef ToolErrorTextBuilder = String Function(
  RunContext ctx,
  ToolCallInput input,
  Object error,
);

/// A tool middleware that turns a failed tool call into a result that says
/// what went wrong, so that the model can react instead of the run failing.
///
/// Port of the `errorremover` middleware of the eino examples. The default
/// text is `Failed to call tool '<name>', error message: '<error>'`.
///
/// Two things are thrown on untouched: an interrupt, because a tool that
/// pauses the run must reach the graph, and whatever is thrown once the run
/// was cancelled.
///
/// For a streaming tool only a failure to start the stream is caught; an
/// error inside the stream reaches whoever reads it.
final class ErrorRemoverMiddleware extends ToolMiddleware {
  /// The middleware, with [describe] in place of the default text.
  ErrorRemoverMiddleware({ToolErrorTextBuilder? describe})
      : super(
          invokable: (next) => (ctx, input) async {
            try {
              return await next(ctx, input);
              // Any failure of the tool becomes its result.
              // ignore: avoid_catches_without_on_clauses
            } catch (error) {
              if (_mustPass(ctx, error)) rethrow;
              return ToolCallOutput(_describe(describe, ctx, input, error));
            }
          },
          streamable: (next) => (ctx, input) async {
            try {
              return await next(ctx, input);
              // ignore: avoid_catches_without_on_clauses
            } catch (error) {
              if (_mustPass(ctx, error)) rethrow;
              return StreamToolCallOutput(
                StreamReader<String>.fromIterable(
                  [_describe(describe, ctx, input, error)],
                ),
              );
            }
          },
          enhancedInvokable: (next) => (ctx, input) async {
            try {
              return await next(ctx, input);
              // ignore: avoid_catches_without_on_clauses
            } catch (error) {
              if (_mustPass(ctx, error)) rethrow;
              return EnhancedToolCallOutput(
                ToolResult.text(_describe(describe, ctx, input, error)),
              );
            }
          },
          enhancedStreamable: (next) => (ctx, input) async {
            try {
              return await next(ctx, input);
              // ignore: avoid_catches_without_on_clauses
            } catch (error) {
              if (_mustPass(ctx, error)) rethrow;
              return EnhancedStreamToolCallOutput(
                StreamReader<ToolResult>.fromIterable([
                  ToolResult.text(_describe(describe, ctx, input, error)),
                ]),
              );
            }
          },
        );

  static bool _mustPass(RunContext ctx, Object error) =>
      isInterrupt(error) || ctx.cancelToken.isCancelled;

  static String _describe(
    ToolErrorTextBuilder? describe,
    RunContext ctx,
    ToolCallInput input,
    Object error,
  ) =>
      describe != null
          ? describe(ctx, input, error)
          : "Failed to call tool '${input.name}', error message: "
              "'${error is ThreepioException ? error.message : error}'";
}
