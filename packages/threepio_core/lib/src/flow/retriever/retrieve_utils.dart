/// Running several retrievals side by side, each reported to the callback
/// handlers of the run.
///
/// Port of eino `flow/retriever/utils`.
library;

import 'package:meta/meta.dart';

import '../../callbacks/callback_context.dart';
import '../../callbacks/component_callbacks.dart';
import '../../callbacks/run_info.dart';
import '../../components/component_type.dart';
import '../../components/retriever/retriever.dart';
import '../../core/run_context.dart';
import '../../schema/document.dart';

/// One retrieval for [concurrentRetrieve]: a [query] for a [retriever] and,
/// once it has run, its [result] or its [error].
///
/// Port of eino `utils.RetrieveTask`. Go's task is a struct whose `Result`
/// and `Err` fields the function fills in; here they are read-only and only
/// [concurrentRetrieve] sets them. Running a task again replaces what the run
/// before left.
final class RetrieveTask {
  /// A task that retrieves [query] from [retriever] with [options].
  RetrieveTask({
    required this.retriever,
    required this.query,
    this.name = '',
    this.options,
  });

  /// A name for the task, for whoever reads the results; the router of
  /// `RouterRetriever.fromConfig` puts the retriever's route here.
  final String name;

  /// The retriever to ask.
  final Retriever retriever;

  /// What to search for.
  final String query;

  /// The options of the retrieval. Their `runContext` is replaced by the
  /// context of the run the task is part of.
  final RetrieverOptions? options;

  List<Document>? _result;
  Object? _error;
  StackTrace? _stackTrace;

  /// The documents the retrieval found, or `null` before the task has run
  /// and when it failed.
  List<Document>? get result => _result;

  /// What the retrieval threw, or `null` when it has not run or succeeded.
  Object? get error => _error;

  /// The stack trace of [error].
  StackTrace? get stackTrace => _stackTrace;

  /// Whether the task has run and failed.
  bool get failed => _error != null;

  @override
  String toString() => 'RetrieveTask(${name.isEmpty ? '' : '$name, '}'
      '"$query"${failed ? ', failed: $_error' : _result == null ? '' : ', '
          '${_result!.length} documents'})';
}

/// Runs [tasks] side by side and waits for all of them, reporting each
/// retrieval to the callback handlers of [ctx].
///
/// Port of eino `utils.ConcurrentRetrieveWithCallback`. Each task's retriever
/// is called with the task's options, whose `runContext` is a context in
/// which the retrieval has reported itself as a retriever named after its
/// implementation (`componentTypeNameOf` plus `Retriever`, so a retriever
/// that says it is `'Vector'` shows up as `VectorRetriever`). The start
/// callback gets the query, the end callback the documents; a failure goes
/// to the error callback.
///
/// The function never throws: what a retrieval throws is recorded in its
/// task ([RetrieveTask.error]) as it is, and the caller decides what to do
/// with it. (Go also recovers a panic of the retriever and records it as
/// `retrieve panic, query: …`; a Dart `Error` is recorded unwrapped, like
/// any exception.)
/// When it returns, every task has either a [RetrieveTask.result] or an
/// [RetrieveTask.error].
///
/// As in Eino, the callbacks are fired around every retrieval, whether its
/// retriever reports itself or not; one that does is reported twice.
Future<void> concurrentRetrieve(
  RunContext ctx,
  List<RetrieveTask> tasks,
) async {
  await Future.wait([for (final task in tasks) _run(ctx, task)]);
}

Future<void> _run(RunContext ctx, RetrieveTask task) async {
  task
    .._result = null
    .._error = null
    .._stackTrace = null;
  var taskCtx = ctx;
  try {
    taskCtx = await onStart(withRetrieverRunInfo(ctx, task.retriever), task.query);
    final docs = await task.retriever.retrieve(
      task.query,
      options:
          (task.options ?? const RetrieverOptions()).copyWith(runContext: taskCtx),
    );
    await onEnd(taskCtx, docs);
    task._result = docs;
    // Whatever the retrieval throws is the task's error, as Go keeps `Err`.
    // ignore: avoid_catches_without_on_clauses
  } catch (error, stackTrace) {
    task
      .._error = error
      .._stackTrace = stackTrace;
    await onError(taskCtx, error, stackTrace);
  }
}

/// [ctx] with the run info of [retriever] for the callbacks of a retrieval:
/// kind retriever, type its implementation name, name the two joined.
///
/// Port of eino's unexported `ctxWithRetrieverRunInfo`.
@internal
RunContext withRetrieverRunInfo(RunContext ctx, Retriever retriever) {
  final type = componentTypeNameOf(retriever) ?? '';
  return reuseHandlers(
    ctx,
    RunInfo(
      name: '$type${ComponentType.retriever.einoName}',
      type: type,
      componentType: ComponentType.retriever,
    ),
  );
}

/// [ctx] with the run info of a step a flow retriever reports as a lambda:
/// type [type], name [type] plus `Lambda` (`RouterLambda`,
/// `FusionFuncLambda`).
///
/// Port of eino's unexported `ctxWithRouterRunInfo` and
/// `ctxWithFusionRunInfo`.
@internal
RunContext withLambdaRunInfo(RunContext ctx, String type) => reuseHandlers(
      ctx,
      RunInfo(
        name: '$type${ComponentType.lambda.einoName}',
        type: type,
        componentType: ComponentType.lambda,
      ),
    );

/// Runs [step] between the start and the end or error callback of [ctx],
/// which a `with…RunInfo` function has prepared. What [step] throws is
/// reported and rethrown.
@internal
Future<O> runReported<I, O>(
  RunContext ctx,
  I input,
  Future<O> Function(RunContext ctx, I input) step,
) async {
  final started = await onStart(ctx, input);
  final O output;
  try {
    output = await step(started, input);
  } catch (error, stackTrace) {
    await onError(started, error, stackTrace);
    rethrow;
  }
  await onEnd(started, output);
  return output;
}

/// Throws the error of the first task in [tasks] that failed, with its stack
/// trace, as the Go flow retrievers return the first task's `Err`.
@internal
void throwFirstFailure(List<RetrieveTask> tasks) {
  for (final task in tasks) {
    final error = task.error;
    if (error != null) Error.throwWithStackTrace(error, task.stackTrace!);
  }
}
