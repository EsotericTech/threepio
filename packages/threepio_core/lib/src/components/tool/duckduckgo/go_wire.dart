/// What the web search tools need to talk to a server the way Go's standard
/// library does: `url.Values.Encode`, `strings.TrimSpace`, the field lookup
/// and type errors of `encoding/json`, sonic's string escaping, and one
/// `http.Client` exchange with Go's `Client.Timeout` and a cancel token.
///
/// Internal to the `duckduckgo` and `searxng` tools; not exported.
@internal
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../errors.dart';
import '../../../internal/provider_http.dart';
import '../../model/cancel_token.dart';

export '../../../internal/go_json.dart' show goSonicMarshal;

/// Go's `url.QueryEscape`: every byte of the UTF-8 form of [value] except
/// the letters, the digits and `-_.~` is written as `%XX` (upper-case hex),
/// and a space as `+`.
String goQueryEscape(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (_isUnreserved(byte)) {
      out.writeCharCode(byte);
    } else if (byte == 0x20) {
      out.write('+');
    } else {
      out
        ..write('%')
        ..write(_hexDigits[byte >> 4])
        ..write(_hexDigits[byte & 0x0F]);
    }
  }
  return out.toString();
}

const String _hexDigits = '0123456789ABCDEF';

bool _isUnreserved(int byte) =>
    (byte >= 0x61 && byte <= 0x7A) || // a-z
    (byte >= 0x41 && byte <= 0x5A) || // A-Z
    (byte >= 0x30 && byte <= 0x39) || // 0-9
    byte == 0x2D || // -
    byte == 0x5F || // _
    byte == 0x2E || // .
    byte == 0x7E; // ~

/// Go's `url.Values.Encode`: `key=value` pairs joined by `&`, the keys in
/// byte order (Go sorts them), the values of one key in their order, keys
/// and values escaped with [goQueryEscape]. Empty for no values.
String goEncodeValues(Map<String, List<String>> values) {
  final keys = values.keys.toList()..sort(compareGoStrings);
  final out = StringBuffer();
  for (final key in keys) {
    final escapedKey = goQueryEscape(key);
    for (final value in values[key]!) {
      if (out.isNotEmpty) out.write('&');
      out
        ..write(escapedKey)
        ..write('=')
        ..write(goQueryEscape(value));
    }
  }
  return out.toString();
}

/// Orders [a] and [b] as Go orders strings: by the bytes of their UTF-8
/// form, which is the order of their code points.
int compareGoStrings(String a, String b) {
  final left = a.runes.iterator;
  final right = b.runes.iterator;
  while (true) {
    final hasLeft = left.moveNext();
    final hasRight = right.moveNext();
    if (!hasLeft || !hasRight) {
      if (hasLeft == hasRight) return 0;
      return hasLeft ? 1 : -1;
    }
    if (left.current != right.current) {
      return left.current.compareTo(right.current);
    }
  }
}

/// Go's `strings.TrimSpace`: [value] without the white space (Go's
/// `unicode.IsSpace`) at either end. Unlike Dart's `trim`, it keeps a
/// leading or trailing U+FEFF.
String goTrimSpace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isGoSpace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isGoSpace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

bool _isGoSpace(int c) =>
    c == 0x20 ||
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// The value `encoding/json` stores in the struct field whose JSON name is
/// [name], or `null` when [json] has none.
///
/// Go matches keys to fields ignoring case (`bytes.EqualFold`: ASCII
/// letters, plus the Kelvin sign for `k` and the long s for `s`), and a later
/// key overwrites an earlier one; the field names of these tools never fold
/// to one another, so the last key that folds to [name] wins.
Object? goJsonField(Map<String, Object?> json, String name) {
  Object? found;
  for (final entry in json.entries) {
    if (entry.key == name || _equalFold(entry.key, name)) found = entry.value;
  }
  return found;
}

bool _equalFold(String a, String b) {
  final left = a.runes.toList();
  final right = b.runes.toList();
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (_fold(left[i]) != _fold(right[i])) return false;
  }
  return true;
}

int _fold(int rune) {
  if (rune >= 0x61 && rune <= 0x7A) return rune - 0x20; // a-z → A-Z
  if (rune == 0x212A) return 0x4B; // KELVIN SIGN → K
  if (rune == 0x017F) return 0x53; // LATIN SMALL LETTER LONG S → S
  return rune;
}

/// How `encoding/json` names the kind of [value] in a type error:
/// `string`, `number`, `bool`, `array`, `object` (or `null`).
String goJsonKind(Object? value) => switch (value) {
      null => 'null',
      String() => 'string',
      num() => 'number',
      bool() => 'bool',
      List<Object?>() => 'array',
      _ => 'object',
    };

/// Reads the fields of one Go struct from a decoded JSON object, with the
/// rules of `encoding/json`: keys match ignoring case ([goJsonField]), a
/// missing key or `null` leaves the zero value, and a value of the wrong
/// kind fails with Go's `UnmarshalTypeError` text in a
/// [ThreepioFormatException].
final class GoJsonStruct {
  /// Reads [json] as the Go struct [structName] found at the dotted JSON
  /// [path] (empty at the top level).
  GoJsonStruct(this._json, {required this.structName, this.path = ''});

  /// Reads [value] as the Go struct [structName] of Go type [goType]
  /// (`searxng.SearchResponse`) at the top level: a JSON object, or `null`
  /// for the zero value. Anything else fails as `encoding/json` does.
  static GoJsonStruct? top(
    Object? value, {
    required String structName,
    required String goType,
  }) =>
      switch (value) {
        null => null,
        final Map<String, Object?> json =>
          GoJsonStruct(json, structName: structName),
        _ => throw ThreepioFormatException(
            'json: cannot unmarshal ${goJsonKind(value)} into Go value of '
            'type $goType',
          ),
      };

  final Map<String, Object?> _json;

  /// The Go name of the struct, for the error text.
  final String structName;

  /// The dotted JSON path of the struct, for the error text.
  final String path;

  /// The value of the field [name], `null` when absent.
  Object? raw(String name) => goJsonField(_json, name);

  /// A Go `string` field: `''` when absent or `null`.
  String string(String name, {String goType = 'string'}) {
    final value = raw(name);
    return switch (value) {
      null => '',
      final String text => text,
      _ => throw typeError(goJsonKind(value), name, goType),
    };
  }

  /// A Go `int` field (or a named integer type [goType]): `0` when absent
  /// or `null`.
  int integer(String name, {String goType = 'int'}) =>
      optionalInteger(name, goType: goType) ?? 0;

  /// A Go `*int` field: `null` when absent or `null`.
  int? optionalInteger(String name, {String goType = 'int'}) {
    final value = raw(name);
    return switch (value) {
      null => null,
      final int number => number,
      // Go's `int` takes integer literals only; the text shows the number.
      final double number => throw typeError('number $number', name, goType),
      _ => throw typeError(goJsonKind(value), name, goType),
    };
  }

  /// A Go slice field of Go type [goType]: `null` when absent or `null`.
  List<Object?>? list(String name, {required String goType}) {
    final value = raw(name);
    return switch (value) {
      null => null,
      final List<Object?> items => items,
      _ => throw typeError(goJsonKind(value), name, goType),
    };
  }

  /// The struct element of the slice field [field] at [element]: `null` for
  /// a JSON `null`, a reader for an object, Go's type error otherwise.
  GoJsonStruct? element(
    Object? element, {
    required String field,
    required String structName,
    required String goType,
  }) =>
      switch (element) {
        null => null,
        final Map<String, Object?> json =>
          GoJsonStruct(json, structName: structName, path: _pathOf(field)),
        _ => throw typeError(goJsonKind(element), field, goType),
      };

  /// Go's `UnmarshalTypeError` text for a JSON [kind] found in [field]
  /// where Go wanted [goType].
  ThreepioFormatException typeError(String kind, String field, String goType) =>
      ThreepioFormatException(
        'json: cannot unmarshal $kind into Go struct field '
        '$structName.${_pathOf(field)} of type $goType',
      );

  String _pathOf(String field) => path.isEmpty ? field : '$path.$field';
}

/// The longest wait threepio's timers allow on every platform, standing in
/// for Go's "no timeout" (a zero or negative `Client.Timeout`).
const Duration goNoTimeout = Duration(days: 24);

/// One request and its response, timed like a Go `http.Client` with a
/// `Timeout`: the limit covers sending, the headers and reading the body.
///
/// A cancelled [cancelToken] abandons the exchange at once with a
/// [CancelledException]; a response that still arrives is discarded.
final class GoHttpExchange {
  /// Starts the clock of an exchange limited to [timeout].
  GoHttpExchange(this.timeout, this.cancelToken)
      : _clock = Stopwatch()..start();

  /// The limit of the whole exchange.
  final Duration timeout;

  /// The token that abandons the exchange.
  final CancelToken cancelToken;

  final Stopwatch _clock;

  Duration get _remaining {
    final left = timeout - _clock.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Sends [request] with [client] and waits for the response headers.
  ///
  /// Throws a [TimeoutException] when the time is up, a
  /// [CancelledException] when the token fires, and whatever [client]
  /// throws otherwise.
  Future<http.StreamedResponse> send(
    http.Client client,
    http.BaseRequest request,
  ) {
    cancelToken.throwIfCancelled();
    final completer = Completer<http.StreamedResponse>();
    unawaited(
      Future.sync(() => client.send(request)).then(
        (response) {
          if (completer.isCompleted) {
            discard(response);
          } else {
            completer.complete(response);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );
    return _guard(
      completer,
      'Client.Timeout exceeded while awaiting headers',
      onAbandon: () {},
    );
  }

  /// Reads the body of [response], within what is left of the time.
  ///
  /// Throws like [send]; an error of the body stream is rethrown. When the
  /// token has already fired, the body is let go unread.
  Future<Uint8List> readBody(http.StreamedResponse response) {
    if (cancelToken.isCancelled) {
      discard(response);
      cancelToken.throwIfCancelled();
    }
    final completer = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    final subscription = response.stream.listen(
      bytes.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    return _guard(
      completer,
      'Client.Timeout or context cancellation while reading body',
      onAbandon: () => unawaited(subscription.cancel()),
    );
  }

  /// Lets go of the body of [response] without reading it.
  static void discard(http.StreamedResponse response) {
    unawaited(
      response.stream.listen(null, onError: (Object _) {}).cancel(),
    );
  }

  /// Completes [completer] with a [TimeoutException] saying [what] when the
  /// time is up, or with a [CancelledException] when the token fires, first
  /// calling [onAbandon]; returns its future.
  Future<T> _guard<T>(
    Completer<T> completer,
    String what, {
    required void Function() onAbandon,
  }) {
    final watch = CallWatch(cancelToken);
    void abandon(Object error) {
      if (completer.isCompleted) return;
      onAbandon();
      completer.completeError(error);
    }

    final timer = Timer(
      _remaining,
      () => abandon(TimeoutException(what, timeout)),
    );
    watch.onCancel(() => abandon(CancelledException(cancelToken.reason)));
    return completer.future.whenComplete(() {
      timer.cancel();
      watch.release();
    });
  }
}

/// Waits [delay], or fails with a [CancelledException] as soon as
/// [cancelToken] fires (Go's `time.Sleep`, which threepio makes
/// cancellable).
Future<void> goPause(Duration delay, CancelToken cancelToken) async {
  cancelToken.throwIfCancelled();
  if (delay <= Duration.zero) return;
  final elapsed = Completer<void>();
  final timer = Timer(delay, elapsed.complete);
  final watch = CallWatch(cancelToken);
  try {
    await Future.any<void>([elapsed.future, watch.cancelled]);
  } finally {
    timer.cancel();
    watch.release();
  }
}

/// Go's `Client.Timeout` rule for a configured [timeout]: `null` or zero is
/// [fallback], a negative duration is no limit at all ([goNoTimeout]).
Duration goClientTimeout(Duration? timeout, Duration fallback) {
  if (timeout == null || timeout == Duration.zero) return fallback;
  if (timeout.isNegative) return goNoTimeout;
  return timeout;
}
