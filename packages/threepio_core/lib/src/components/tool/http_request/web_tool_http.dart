/// HTTP and JSON the way Go does them, for the web tools (`httprequest`,
/// `googlesearch`, `wikipedia`).
///
/// The Go tools send their requests with `net/http`, encode queries with
/// `net/url`, decode answers with `encoding/json` and encode what they hand
/// to the model with sonic. These helpers reproduce what the ports need of
/// that behaviour: the redirect policy and error texts of `http.Client.Do`,
/// a client timeout that covers the whole exchange, `url.QueryEscape`,
/// `url.PathEscape`, `url.Values.Encode`, sonic's string escaping and the
/// type checks of `encoding/json`.
///
/// Everything here is internal to the web tools.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/go_json.dart';
import '../../../internal/provider_http.dart' show CallWatch;
import '../../model/cancel_token.dart';

// ---------------------------------------------------------------------------
// net/url
// ---------------------------------------------------------------------------

const _hexDigits = '0123456789ABCDEF';

bool _isUnreserved(int c) =>
    (c >= 0x61 && c <= 0x7a) || // a-z
    (c >= 0x41 && c <= 0x5a) || // A-Z
    (c >= 0x30 && c <= 0x39) || // 0-9
    c == 0x2d || // -
    c == 0x5f || // _
    c == 0x2e || // .
    c == 0x7e; // ~

/// The reserved characters `url.PathEscape` leaves alone: `$ & + : = @`.
bool _keptInPathSegment(int c) =>
    c == 0x24 || c == 0x26 || c == 0x2b || c == 0x3a || c == 0x3d || c == 0x40;

String _goEscape(String s, {required bool query}) {
  final out = StringBuffer();
  for (final byte in utf8.encode(s)) {
    if (_isUnreserved(byte) || (!query && _keptInPathSegment(byte))) {
      out.writeCharCode(byte);
    } else if (query && byte == 0x20) {
      out.write('+');
    } else {
      out
        ..write('%')
        ..write(_hexDigits[byte >> 4])
        ..write(_hexDigits[byte & 0x0f]);
    }
  }
  return out.toString();
}

/// Go's `url.QueryEscape`: every byte of the UTF-8 form except
/// `A-Z a-z 0-9 - _ . ~` is percent-encoded (upper-case hex), a space
/// becomes `+`.
@internal
String goQueryEscape(String s) => _goEscape(s, query: true);

/// Go's `url.PathEscape`: like [goQueryEscape], except that `$ & + : = @`
/// stay as they are and a space becomes `%20`.
@internal
String goPathEscape(String s) => _goEscape(s, query: false);

/// Go's `url.Values.Encode` for single values: `key=value` pairs sorted by
/// key, both sides escaped with [goQueryEscape], joined by `&`.
@internal
String goEncodeQuery(Map<String, String> values) {
  final keys = values.keys.toList()..sort();
  return [
    for (final key in keys)
      '${goQueryEscape(key)}=${goQueryEscape(values[key]!)}',
  ].join('&');
}

/// Go's `%q` for the strings the web tools quote (URLs, headers): the text
/// in double quotes with `\` and `"` escaped.
@internal
String goQuote(String s) {
  final backslash = String.fromCharCode(0x5c);
  return '"${s.replaceAll(backslash, '$backslash$backslash').replaceAll('"', '$backslash"')}"';
}

/// Go's `urlErrorOp`: `GET` becomes `Get`, the verb `*url.Error` names.
@internal
String goUrlErrorOp(String method) => method.isEmpty
    ? 'Get'
    : method.substring(0, 1) + method.substring(1).toLowerCase();

// ---------------------------------------------------------------------------
// sonic
// ---------------------------------------------------------------------------

/// The JSON text `sonic.MarshalString` writes for [value]: the shared
/// `goSonicMarshal` (see there), under the name the web tools use.
@internal
String sonicMarshal(Object? value) => goSonicMarshal(value);

// ---------------------------------------------------------------------------
// encoding/json
// ---------------------------------------------------------------------------

String _jsonKind(Object? value) => switch (value) {
      String() => 'string',
      bool() => 'bool',
      num() => 'number',
      List<Object?>() => 'array',
      _ => 'object',
    };

/// The error of `encoding/json` for a [value] that does not fit the Go field
/// [field] (the dotted path of JSON keys) of struct [struct], whose type is
/// [goType].
@internal
ThreepioFormatException goJsonTypeError(
  Object? value,
  String struct,
  String field,
  String goType,
) {
  // Go names the number itself only when it does not fit an integer field.
  final kind = value is double && goType == 'int'
      ? 'number $value'
      : _jsonKind(value);
  return ThreepioFormatException(
    'json: cannot unmarshal $kind into Go struct field $struct.$field of '
    'type $goType',
  );
}

/// A Go `string` field: `null` (or a missing key) is the empty string.
@internal
String goJsonString(Object? value, String struct, String field) => switch (
        value) {
      null => '',
      final String text => text,
      _ => throw goJsonTypeError(value, struct, field, 'string'),
    };

/// A Go `int` field: `null` is 0; a number with a fraction or an exponent
/// does not fit.
@internal
int goJsonInt(Object? value, String struct, String field) => switch (value) {
      null => 0,
      final int number => number,
      _ => throw goJsonTypeError(value, struct, field, 'int'),
    };

/// A Go struct (or map) field: `null` is the zero value, an empty map.
@internal
Map<String, Object?> goJsonObject(
  Object? value,
  String struct,
  String field,
  String goType,
) =>
    switch (value) {
      null => const {},
      final Map<String, Object?> map => map,
      _ => throw goJsonTypeError(value, struct, field, goType),
    };

/// A Go slice field: `null` is an empty slice.
@internal
List<Object?> goJsonArray(
  Object? value,
  String struct,
  String field,
  String goType,
) =>
    switch (value) {
      null => const [],
      final List<Object?> list => list,
      _ => throw goJsonTypeError(value, struct, field, goType),
    };

/// Decodes [body] as `encoding/json` does into a Go struct of type
/// [goType]: the bytes are read as UTF-8 (a malformed sequence becomes
/// U+FFFD, as in Go), `null` is the zero value (an empty map), and a value
/// that is not an object does not fit.
@internal
Map<String, Object?> goJsonDecodeObject(List<int> body, String goType) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
  } on FormatException catch (error) {
    throw ThreepioFormatException(
      error.message,
      source: error.source,
      offset: error.offset,
      cause: error,
    );
  }
  return switch (decoded) {
    null => const {},
    final Map<String, Object?> map => map,
    _ => throw ThreepioFormatException(
        'json: cannot unmarshal ${_jsonKind(decoded)} into Go value of type '
        '$goType',
      ),
  };
}

// ---------------------------------------------------------------------------
// net/http
// ---------------------------------------------------------------------------

/// Decides whether a redirect to [next] is followed, as Go's
/// `http.Client.CheckRedirect`: [via] holds the requests made so far, the
/// first one included. Returns the error that stops the redirect, or `null`
/// to follow it.
@internal
typedef GoCheckRedirect = Object? Function(Uri next, List<Uri> via);

/// Go's `defaultCheckRedirect`: at most ten requests.
@internal
Object? goDefaultCheckRedirect(Uri next, List<Uri> via) =>
    via.length >= 10 ? 'stopped after 10 redirects' : null;

/// A failure of `http.Client.Do`: the text of Go's `*url.Error`,
/// `Get "https://…": reason`.
@internal
final class GoHttpDoException implements Exception {
  /// A failure of a request [op] (`Get`, `Post`, …) to [url].
  GoHttpDoException(this.op, this.url, this.reason, {this.cause});

  /// The verb, as [goUrlErrorOp] writes it.
  final String op;

  /// The address of the request that failed.
  final String url;

  /// What went wrong.
  final String reason;

  /// The error behind [reason], if there is one.
  final Object? cause;

  /// `Op "url": reason`, as Go's `url.Error.Error()`.
  String get message => '$op ${goQuote(url)}: $reason';

  @override
  String toString() => message;
}

/// A failure while the body of a response is read (Go: the error of
/// `io.ReadAll(resp.Body)`).
@internal
final class GoHttpReadException implements Exception {
  /// A read that failed because of [reason].
  GoHttpReadException(this.reason, {this.cause});

  /// What went wrong.
  final String reason;

  /// The error behind [reason], if there is one.
  final Object? cause;

  @override
  String toString() => reason;
}

const _timeoutAwaitingHeaders =
    'context deadline exceeded (Client.Timeout exceeded while awaiting '
    'headers)';
const _timeoutReadingBody =
    'context deadline exceeded (Client.Timeout or context cancellation while '
    'reading body)';

const _sensitiveHeaders = {
  'authorization',
  'www-authenticate',
  'cookie',
  'cookie2',
  'proxy-authorization',
  'proxy-authenticate',
};

/// One exchange with a server, as Go's `http.Client` with a `Timeout` makes
/// it: the request, the redirects it follows and the reading of the body
/// share one deadline, and the cancel token of the context abandons the
/// exchange at any point with a [CancelledException].
///
/// Call [close] when done, in a `finally`.
@internal
final class GoHttpCall {
  /// An exchange under [ctx]; [timeout] is Go's `http.Client.Timeout`
  /// (`null`, zero or negative: none, as Go's `Client.deadline` reads it).
  GoHttpCall(RunContext ctx, {Duration? timeout})
      : _token = ctx.cancelToken,
        _timeout = timeout != null && timeout > Duration.zero ? timeout : null,
        _watch = CallWatch(ctx.cancelToken),
        _clock = Stopwatch()..start();

  final CancelToken _token;
  final Duration? _timeout;
  final CallWatch _watch;
  final Stopwatch _clock;
  var _hideAddresses = false;

  /// [error] as the cause of a failure: a client error loses its address
  /// when [send] was given an address to show instead, or when the address
  /// holds a password.
  Object _causeOf(Exception error) =>
      _hideAddresses && error is http.ClientException
          ? http.ClientException(error.message)
          : error;

  /// Sends [method] [url] with [headers] and [body] and follows redirects
  /// the way Go's `Client.Do` does:
  ///
  /// * 301, 302 and 303 are followed with `GET` (`HEAD` stays `HEAD`) and
  ///   without a body; 307 and 308 repeat the method and the body;
  /// * a redirect without a `Location` header is the response;
  /// * every hop carries the headers of the first request, without the
  ///   credentials (`Authorization`, `Cookie`, …) once the host is no longer
  ///   the first one or a subdomain of it, plus a `Referer` (none from
  ///   `https` to `http`);
  /// * [checkRedirect] can stop a redirect with an error.
  ///
  /// Errors quote the address of the request that failed with its password
  /// shown as `***` (Go's `stripPassword`). [urlText], when given, is the
  /// address errors quote for the first request instead of [url]; then, and
  /// when [url] holds a password, the errors of the client lose the address
  /// they carry, so that a secret in [url] is never shown. A cancelled token
  /// sends no further hop. Throws [GoHttpDoException], or
  /// [CancelledException].
  Future<http.StreamedResponse> send(
    http.Client client, {
    required String method,
    required Uri url,
    String? urlText,
    Map<String, String> headers = const {},
    List<int>? body,
    GoCheckRedirect checkRedirect = goDefaultCheckRedirect,
  }) async {
    _token.throwIfCancelled();
    _hideAddresses = urlText != null || url.userInfo.contains(':');
    final op = goUrlErrorOp(method);
    final via = <Uri>[];
    var current = url;
    var currentText = urlText ?? _stripPassword(url);
    var currentMethod = method;
    var includeBody = true;
    var stripSensitive = false;
    http.StreamedResponse? response;

    for (;;) {
      final headersOfHop = <String, String>{...headers};
      if (via.isNotEmpty) {
        final previous = response!;
        final location = previous.headers['location'] ?? '';
        if (location.isEmpty) return previous;
        final Uri next;
        try {
          next = current.resolve(location);
        } on FormatException catch (error) {
          discard(previous);
          throw GoHttpDoException(
            op,
            currentText,
            'failed to parse Location header ${goQuote(location)}: '
            '${error.message}',
            cause: error,
          );
        }
        if (!stripSensitive &&
            !_isDomainOrSubdomain(next.host, via.first.host)) {
          stripSensitive = true;
        }
        if (stripSensitive) {
          headersOfHop.removeWhere(
            (name, _) => _sensitiveHeaders.contains(name.toLowerCase()),
          );
        }
        final hasReferer =
            headersOfHop.keys.any((name) => name.toLowerCase() == 'referer');
        if (!hasReferer && !(current.scheme == 'https' && next.scheme == 'http')) {
          headersOfHop['Referer'] = _withoutUserInfo(current).toString();
        }
        final stop = checkRedirect(next, List.unmodifiable(via));
        discard(previous);
        if (stop != null) {
          throw GoHttpDoException(
            op,
            location,
            stop is ThreepioException ? stop.message : '$stop',
            cause: stop,
          );
        }
        current = next;
        currentText = _stripPassword(next);
      }
      via.add(current);

      final scheme = current.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        throw GoHttpDoException(
          op,
          currentText,
          'unsupported protocol scheme ${goQuote(current.scheme)}',
        );
      }
      if (current.host.isEmpty) {
        throw GoHttpDoException(
          op,
          currentText,
          'http: no Host in request URL',
        );
      }

      // Go's transport looks at the context before every hop.
      _token.throwIfCancelled();
      final request = http.Request(currentMethod, current)
        ..followRedirects = false
        ..headers.addAll(headersOfHop);
      if (body != null && includeBody) request.bodyBytes = body;

      final http.StreamedResponse hop;
      try {
        hop = await _guard(client.send(request), onAbandon: discard);
      } on TimeoutException catch (error) {
        throw GoHttpDoException(
          op,
          currentText,
          _timeoutAwaitingHeaders,
          cause: error,
        );
      } on CancelledException {
        rethrow;
      } on Exception catch (error) {
        if (isInterrupt(error)) rethrow;
        throw GoHttpDoException(
          op,
          currentText,
          error is http.ClientException ? error.message : '$error',
          cause: _causeOf(error),
        );
      }

      response = hop;
      switch (hop.statusCode) {
        case 301 || 302 || 303:
          if (currentMethod != 'GET' && currentMethod != 'HEAD') {
            currentMethod = 'GET';
          }
          includeBody = false;
        case 307 || 308:
          break;
        default:
          return hop;
      }
    }
  }

  /// Reads the whole body of [response] (Go: `io.ReadAll(resp.Body)`) in the
  /// time left. Throws [GoHttpReadException], or [CancelledException].
  Future<Uint8List> readAll(http.StreamedResponse response) async {
    final bytes = BytesBuilder(copy: false);
    final done = Completer<Uint8List>();
    final subscription = response.stream.listen(
      bytes.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    try {
      return await _guard(done.future);
    } on TimeoutException catch (error) {
      unawaited(subscription.cancel());
      throw GoHttpReadException(_timeoutReadingBody, cause: error);
    } on CancelledException {
      unawaited(subscription.cancel());
      rethrow;
    } on Exception catch (error) {
      unawaited(subscription.cancel());
      if (isInterrupt(error)) rethrow;
      throw GoHttpReadException(
        error is http.ClientException ? error.message : '$error',
        cause: _causeOf(error),
      );
    }
  }

  /// Throws the unread body of [response] away (Go: `resp.Body.Close()`).
  void discard(http.StreamedResponse response) => unawaited(
        response.stream.listen(null, onError: (Object _) {}).cancel(),
      );

  /// Ends the exchange; the cancel token of the context lets go of it.
  void close() => _watch.release();

  /// [work], abandoned with a [TimeoutException] at the deadline and with a
  /// [CancelledException] when the token fires. A result that arrives after
  /// that is passed to [onAbandon].
  Future<T> _guard<T>(Future<T> work, {void Function(T value)? onAbandon}) {
    var abandoned = false;
    unawaited(
      work.then(
        (value) {
          if (abandoned) onAbandon?.call(value);
        },
        onError: (Object _) {},
      ),
    );
    final timeout = _timeout;
    var raced = work;
    if (timeout != null) {
      final left = timeout - _clock.elapsed;
      if (left <= Duration.zero) {
        abandoned = true;
        return Future.error(TimeoutException('deadline passed', timeout));
      }
      raced = raced.timeout(left);
    }
    return Future.any<T>([raced, _watch.cancelled]).catchError(
      (Object error, StackTrace stackTrace) {
        abandoned = true;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }
}

/// Go's `isDomainOrSubdomain(sub, parent)`.
bool _isDomainOrSubdomain(String sub, String parent) {
  final s = sub.toLowerCase();
  final p = parent.toLowerCase();
  if (s == p) return true;
  if (s.contains(':') || s.contains('%')) return false;
  return s.endsWith(p) && s.length > p.length && s[s.length - p.length - 1] == '.';
}

Uri _withoutUserInfo(Uri uri) =>
    (uri.userInfo.isEmpty ? uri : uri.replace(userInfo: '')).removeFragment();

/// Go's `stripPassword`: the address with a password shown as `***`.
String _stripPassword(Uri uri) {
  final userInfo = uri.userInfo;
  final colon = userInfo.indexOf(':');
  if (colon < 0) return uri.toString();
  return uri.replace(userInfo: '${userInfo.substring(0, colon)}:***').toString();
}
