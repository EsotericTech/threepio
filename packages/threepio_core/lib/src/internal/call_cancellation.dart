/// The one cancel token a model call listens to.
library;

import '../components/model/cancel_token.dart';
import '../components/model/chat_model_options.dart';

/// The cancel token of one call, made of the token in the call's options and
/// the token of its run context.
///
/// A call can be given a token in `ChatModelOptions.cancelToken`, another one
/// in `ChatModelOptions.runContext`, both or neither. It listens to [token],
/// which is cancelled as soon as either of them is.
///
/// When there are two different tokens, [token] is a third one that both of
/// them hold on to until it is cancelled (see [CancelToken.any]). A token
/// that lives as long as the application would collect one of these for every
/// call ever made, so whoever creates a [CallCancellation] calls [release]
/// when the call is over, on every path.
final class CallCancellation {
  /// The cancellation of a call that can be cancelled through [first] or
  /// [second]. Either may be `null`.
  factory CallCancellation(CancelToken? first, CancelToken? second) {
    final token = CancelToken.any([first, second]);
    final owned =
        token != null && !identical(token, first) && !identical(token, second);
    return CallCancellation._(token, owned);
  }

  /// The cancellation of a call made with [options].
  factory CallCancellation.of(ChatModelOptions? options) => CallCancellation(
        options?.cancelToken,
        options?.runContext?.cancelToken,
      );

  const CallCancellation._(this.token, this._owned);

  /// The token to listen to, or `null` when the call cannot be cancelled.
  final CancelToken? token;

  /// Whether [token] was created here and therefore has to be released.
  final bool _owned;

  /// Lets go of [token] once the call is over.
  ///
  /// Does nothing when [token] is one of the caller's own tokens. Otherwise
  /// it cancels the combined token, which is how the caller's tokens drop it:
  /// the counterpart of the `defer cancel()` that follows
  /// `context.WithCancel` in Go. As there, whatever still listens to the
  /// token at that point sees a cancellation, so a call must have stopped
  /// reacting to [token] before it releases it.
  void release() {
    if (_owned) token!.cancel('call finished');
  }
}
