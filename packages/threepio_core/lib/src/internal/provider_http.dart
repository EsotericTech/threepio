/// Sending the requests of the HTTP providers: a timeout for the response
/// headers and a cancel token that abandons the wait.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../components/model/cancel_token.dart';

/// Sends a request with a body and waits for the whole response.
///
/// Throws [CancelledException] when [cancelToken] is (or becomes) cancelled
/// before the response is there, and [TimeoutException] when it takes longer
/// than [timeout]. Other failures of [client] are rethrown as they are; the
/// caller wraps them in its own exception type.
Future<http.Response> sendRequest(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  String? body,
  String method = 'POST',
  required Duration timeout,
  CancelToken? cancelToken,
}) async {
  cancelToken?.throwIfCancelled();
  final request = http.Request(method, url)..headers.addAll(headers);
  if (body != null) request.body = body;
  final response = client
      .send(request)
      .then(http.Response.fromStream)
      .timeout(timeout);
  if (cancelToken == null) return response;
  final watch = CallWatch(cancelToken);
  try {
    return await Future.any<http.Response>([response, watch.cancelled]);
  } finally {
    watch.release();
  }
}

/// A listener on a caller's cancel token for the length of one call.
///
/// Listening on the caller's token directly would leave one listener behind
/// for every call made with a token that lives as long as the application.
/// The watch listens on a token of its own that the caller's token holds
/// only until [release] (see `CancelToken.any`).
final class CallWatch {
  /// Watches [token].
  CallWatch(this.token)
      : _own = CancelToken.any([token, CancelToken()])!;

  /// The caller's token.
  final CancelToken token;

  final CancelToken _own;
  var _released = false;

  /// Fails with a [CancelledException] carrying the caller's reason when
  /// [token] is cancelled before [release]; never completes otherwise.
  Future<Never> get cancelled => _own.whenCancelled.then((_) {
        if (_released) return Completer<Never>().future;
        throw CancelledException(token.reason);
      });

  /// Runs [onCancel] when [token] is cancelled before [release].
  void onCancel(void Function() onCancel) {
    unawaited(
      _own.whenCancelled.then((_) {
        if (!_released) onCancel();
      }),
    );
  }

  /// Ends the watch; the caller's token lets go of it.
  void release() {
    if (_released) return;
    _released = true;
    _own.cancel('call finished');
  }
}

/// Sends a request whose response body is read as a stream.
///
/// Waits for the response headers only, at most [timeout]; the body is left
/// to the caller. Throws like [sendRequest]. When [cancelToken] fires while
/// the headers are awaited, a response that still arrives is drained.
Future<http.StreamedResponse> sendStreamingRequest(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  String? body,
  String method = 'POST',
  required Duration timeout,
  CancelToken? cancelToken,
}) async {
  cancelToken?.throwIfCancelled();
  final request = http.Request(method, url)..headers.addAll(headers);
  if (body != null) request.body = body;
  final response = client.send(request).timeout(timeout);
  if (cancelToken == null) return response;
  var abandoned = false;
  unawaited(
    response.then(
      (r) {
        if (abandoned) unawaited(r.stream.listen(null).cancel());
      },
      onError: (Object _) {},
    ),
  );
  final watch = CallWatch(cancelToken)..onCancel(() => abandoned = true);
  try {
    return await Future.any<http.StreamedResponse>([response, watch.cancelled]);
  } finally {
    watch.release();
  }
}
