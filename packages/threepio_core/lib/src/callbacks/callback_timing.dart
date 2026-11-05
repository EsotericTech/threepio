/// The moments at which a component calls its callback handlers.
library;

import '../core/run_context.dart';
import 'run_info.dart';

/// One of the five moments at which a component calls its callback handlers.
///
/// Port of eino `callbacks.CallbackTiming`.
enum CallbackTiming {
  /// Before the component runs, with its whole input.
  onStart,

  /// After the component has returned its whole output.
  onEnd,

  /// After the component has failed.
  onError,

  /// Before the component runs, when its input is a stream.
  onStartWithStreamInput,

  /// After the component has returned, when its output is a stream.
  onEndWithStreamOutput,
}

/// A callback handler that says which callbacks it wants.
///
/// Port of eino `callbacks.TimingChecker`. A handler that implements it is
/// asked before every callback and left out when it answers `false`. That
/// matters most for streams: every handler that is called gets its own copy of
/// the stream, so a handler that does not look at streams saves the copy by
/// saying so.
///
/// Handlers made with `CallbackHandlerBuilder` and `HandlerHelper` implement
/// it on their own.
// ignore: one_member_abstracts
abstract interface class TimingChecker {
  /// Whether the handler wants to be called at [timing] for the component
  /// described by [info].
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing);
}
