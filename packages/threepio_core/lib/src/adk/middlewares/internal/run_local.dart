/// Run-local values the way eino's middlewares use them: outside a
/// `ChatModelAgent` run (a middleware called directly, as in tests) Go's
/// `GetRunLocalValue`/`SetRunLocalValue` return an error that the
/// middlewares ignore.
@internal
library;

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../eino/agent_context.dart';

/// `(found, value)` of the run-local value [key]; `(false, null)` outside a
/// run.
(bool, Object?) tryRunLocalValue(RunContext ctx, String key) {
  try {
    if (!ctx.hasRunLocalValue(key)) return (false, null);
    return (true, ctx.runLocalValue(key));
    // Outside a run the accessors throw StateError, which eino's middlewares
    // ignore (Go returns an error).
    // ignore: avoid_catching_errors
  } on StateError {
    return (false, null);
  }
}

/// Sets the run-local value [key]; returns `false` (and does nothing)
/// outside a run.
bool trySetRunLocalValue(RunContext ctx, String key, Object? value) {
  try {
    ctx.setRunLocalValue(key, value);
    return true;
    // See tryRunLocalValue; a value that cannot be checkpointed is an
    // ArgumentError, an error Go returns and the middlewares ignore as well.
    // ignore: avoid_catching_errors
  } on StateError {
    return false;
    // ignore: avoid_catching_errors
  } on ArgumentError {
    return false;
  }
}
