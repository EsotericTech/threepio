/// The ways an [McpClient] reaches a server over HTTP, and the contract every
/// transport fulfils.
///
/// Port of the client transports of the official go-sdk
/// (`mcp.StreamableClientTransport`, `mcp.SSEClientTransport`) and of
/// mark3labs/mcp-go's `transport.StreamableHTTP` / `transport.SSE`. The stdio
/// transport needs `dart:io` and lives in `stdio_transport.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../../streaming/stream_reader.dart';
import '../../model/cancel_token.dart';
import '../../model/openai_compatible/sse.dart';
import 'mcp_client.dart';

final _log = Logger('threepio.mcp.transport');

/// Receives one JSON-RPC message from the server.
typedef McpMessageHandler = void Function(Map<String, Object?> message);

/// Learns that the connection ended: with `null` when it was closed on
/// purpose, with the failure otherwise.
typedef McpCloseHandler = void Function(Object? error);

/// Moves the JSON-RPC messages of one [McpClient] to a server and back.
///
/// Port of go-sdk `mcp.Transport` / `mcp.Connection`. The client calls
/// [start] once, then [send] for every message, and [close] at the end:
///
/// * [start] opens the connection (starts the process, opens the event
///   stream) and keeps the two handlers: every message of the server goes to
///   `onMessage` (a JSON array is a batch and arrives one message at a
///   time), and `onClose` is called once when the connection ends.
/// * [send] delivers one message. It throws when the message cannot be
///   delivered: the client then treats the connection as broken. When
///   `cancelToken` fires, the transport stops working on the message (it
///   abandons the HTTP response, for example) and the future completes with
///   a `CancelledException`.
/// * [setProtocolVersion] tells the transport the revision agreed on in the
///   handshake (the HTTP transport sends it as `MCP-Protocol-Version`).
abstract interface class McpTransport {
  /// Opens the connection.
  Future<void> start({
    required McpMessageHandler onMessage,
    required McpCloseHandler onClose,
  });

  /// Delivers [message]. [headers] are added to the HTTP request that carries
  /// it (transports without HTTP ignore them).
  Future<void> send(
    Map<String, Object?> message, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  });

  /// Sets the revision of the specification agreed on in the handshake.
  void setProtocolVersion(String version);

  /// Closes the connection. Safe to call more than once.
  Future<void> close();
}

/// The JSON-RPC messages in [text]: one object, or every object of a batch.
///
/// Text that is not JSON, and values that are not objects, are logged and
/// dropped: a server that writes a log line to its output does not break the
/// connection.
@internal
List<Map<String, Object?>> decodeMcpMessages(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    _log.warning('Ignoring MCP input that is not JSON ($error): $text');
    return const [];
  }
  final values = decoded is List<Object?> ? decoded : [decoded];
  final messages = <Map<String, Object?>>[];
  for (final value in values) {
    if (value is Map<String, Object?>) {
      messages.add(value);
    } else {
      _log.warning('Ignoring an MCP message that is not an object: $value');
    }
  }
  return messages;
}

/// Sends [request] through [client] and waits for the response headers, or
/// until [token] fires (then a response that still arrives is released).
Future<http.StreamedResponse> _send(
  http.Client client,
  http.BaseRequest request,
  CancelToken token,
) {
  token.throwIfCancelled();
  final response = client.send(request);
  var abandoned = false;
  unawaited(
    response.then(
      (r) {
        if (abandoned) unawaited(r.stream.listen(null).cancel());
      },
      onError: (Object _) {},
    ),
  );
  return Future.any<http.StreamedResponse>([
    response,
    token.whenCancelled.then((_) {
      abandoned = true;
      throw CancelledException(token.reason);
    }),
  ]);
}

/// Reads a whole body as UTF-8, or stops when [token] fires.
Future<String> _readBody(Stream<List<int>> body, CancelToken token) {
  final completer = Completer<String>();
  final bytes = BytesBuilder(copy: false);
  final subscription = body.listen(
    bytes.add,
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.complete(utf8.decode(bytes.takeBytes(), allowMalformed: true));
      }
    },
    cancelOnError: true,
  );
  unawaited(
    token.whenCancelled.then((_) {
      if (completer.isCompleted) return;
      unawaited(subscription.cancel());
      completer.completeError(CancelledException(token.reason));
    }),
  );
  return completer.future;
}

/// Releases a response whose body is of no interest: drained when the
/// status says it is short, dropped otherwise.
void _release(http.StreamedResponse response, {bool drain = true}) {
  if (drain) {
    unawaited(response.stream.drain<void>().catchError((Object _) {}));
  } else {
    unawaited(response.stream.listen(null).cancel());
  }
}

/// Reads at most a few hundred characters of an error body, for messages.
Future<String> _errorBody(http.StreamedResponse response) async {
  final token = CancelToken();
  try {
    final text = await _readBody(response.stream, token)
        .timeout(const Duration(seconds: 2));
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    return ': ${trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed}';
  } on Object {
    return '';
  } finally {
    token.cancel('done');
  }
}

String _mediaType(http.BaseResponse response) =>
    (response.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();

/// Whether [message] is the response to the request [id] (ids compared by
/// value, so `"1"` answers `1`).
bool _isResponseTo(Map<String, Object?> message, Object id) =>
    message['method'] == null &&
    (message.containsKey('result') || message.containsKey('error')) &&
    '${message['id']}' == '$id';

/// What a reader of event streams remembers across the streams of one
/// exchange: the last event id (for `Last-Event-ID`), the reconnection delay
/// the server asked for, and how many events arrived.
final class _StreamState {
  String? lastEventId;
  Duration? retry;
  int events = 0;
}

/// Waits [delay], or until [token] fires (then throws `CancelledException`).
Future<void> _wait(Duration delay, CancelToken token) {
  token.throwIfCancelled();
  final completer = Completer<void>();
  final timer = Timer(delay, () {
    if (!completer.isCompleted) completer.complete();
  });
  unawaited(
    token.whenCancelled.then((_) {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.completeError(CancelledException(token.reason));
      }
    }),
  );
  return completer.future;
}

/// Reads the server-sent events of [body] and hands every JSON-RPC message
/// to [deliver], until the body ends, [token] fires, or the response to
/// [expectedId] arrived (the go-sdk stops reading there too).
///
/// Returns whether the response to [expectedId] was among the messages.
/// [state] collects the event ids and the `retry` of the server. Throws an
/// [McpConnectionException] when the body fails and `CancelledException`
/// when [token] fires.
Future<bool> _readEvents(
  Stream<List<int>> body,
  CancelToken token,
  void Function(Map<String, Object?> message) deliver, {
  Object? expectedId,
  _StreamState? state,
  bool Function(SseEvent event)? onEvent,
}) async {
  final (reader, writer) = pipe<Map<String, Object?>>();
  final pumping = pumpSse<Map<String, Object?>>(
    bytes: body,
    writer: writer,
    dispatchEachDataLine: false,
    cancelToken: token,
    streamError: (error) => McpConnectionException(
      'the MCP event stream failed: $error',
      cause: error,
    ),
    onEvent: (event) {
      if (state != null) {
        state.events++;
        final id = event.id;
        if (id != null && id.isNotEmpty) state.lastEventId = id;
        final retry = event.retry;
        if (retry != null) state.retry = retry;
      }
      if (onEvent != null && !onEvent(event)) return PumpAction.next;
      if (event.data.trim().isEmpty) return PumpAction.next;
      var answered = false;
      for (final message in decodeMcpMessages(event.data)) {
        writer.send(message);
        if (expectedId != null && _isResponseTo(message, expectedId)) {
          answered = true;
        }
      }
      return answered ? PumpAction.stop : PumpAction.next;
    },
  );
  var sawResponse = false;
  try {
    while (true) {
      final Map<String, Object?> message;
      try {
        message = await reader.recv();
      } on StreamEOFException {
        break;
      }
      if (expectedId != null && _isResponseTo(message, expectedId)) {
        sawResponse = true;
      }
      deliver(message);
    }
  } finally {
    await reader.close();
    await pumping;
  }
  return sawResponse;
}

/// The Streamable HTTP transport of MCP (revision 2025-03-26 and later).
///
/// Port of go-sdk `mcp.StreamableClientTransport` (and mark3labs
/// `transport.StreamableHTTP`):
///
/// * Every message is POSTed to [url] with `Accept: application/json,
///   text/event-stream`. The server answers a request with one JSON object
///   or with an event stream that carries the response (and any messages it
///   sends before it); notifications and responses get `202 Accepted`.
/// * The `Mcp-Session-Id` the server assigns in the response to
///   `initialize` is sent with every later request, and so is the
///   negotiated `MCP-Protocol-Version`. [headers] (and the headers of each
///   call) go out with every request.
/// * An event stream that ends before the response, after the server gave
///   its events ids, is resumed with a GET that carries `Last-Event-ID` (the
///   polling of revision 2025-11-25), at most [maxRetries] times, waiting the
///   `retry` the server asked for or else [reconnectDelay] growing by 1.5
///   per attempt (at most 30 s), as the go-sdk does.
/// * HTTP 404 means the server no longer knows the session: the send fails
///   with an [McpConnectionException] whose `sessionMissing` is set, as with
///   go-sdk's `ErrSessionMissing`. Any other status outside 2xx, or a
///   network failure, is an [McpConnectionException] too.
/// * After `notifications/initialized` the transport opens the optional GET
///   stream for messages the server sends on its own, when
///   [openStandaloneStream] is set; a server that answers 405 (or 404) has
///   none. When that stream ends it is reopened; after more than
///   [maxRetries] failed attempts in a row the connection is over.
/// * [close] stops every stream and sends `DELETE` with the session id
///   (unless the session is already gone).
///
/// An injected `httpClient` is used as is and never closed; without one a
/// client is created and closed by [close].
final class StreamableHttpTransport implements McpTransport {
  /// A transport that POSTs to [url].
  StreamableHttpTransport(
    this.url, {
    http.Client? httpClient,
    this.headers = const {},
    this.openStandaloneStream = true,
    this.maxRetries = 5,
    this.reconnectDelay = const Duration(seconds: 1),
    this.closeTimeout = const Duration(seconds: 5),
  })  : assert(maxRetries >= 0, 'maxRetries must not be negative'),
        _injected = httpClient;

  /// The MCP endpoint of the server.
  final Uri url;

  /// Headers sent with every request (authorization, for example).
  final Map<String, String> headers;

  /// Whether to open the GET stream for messages the server sends on its own.
  final bool openStandaloneStream;

  /// How often an interrupted event stream is reopened before giving up
  /// (go-sdk `StreamableClientTransport.MaxRetries`, default 5); `0` never
  /// resumes.
  final int maxRetries;

  /// The wait before the first reopening of an event stream when the server
  /// asked for none; each further attempt waits 1.5 times longer.
  final Duration reconnectDelay;

  /// How long [close] waits for the answer to its `DELETE`.
  final Duration closeTimeout;

  final http.Client? _injected;
  http.Client? _created;
  final CancelToken _closeToken = CancelToken();
  McpMessageHandler? _onMessage;
  McpCloseHandler? _onClose;
  String? _sessionId;
  String? _protocolVersion;
  bool _sessionMissing = false;
  bool _standaloneOpened = false;
  bool _closed = false;
  bool _failed = false;

  /// The session id the server assigned, once it did.
  String? get sessionId => _sessionId;

  http.Client get _client => _injected ?? (_created ??= http.Client());

  @override
  Future<void> start({
    required McpMessageHandler onMessage,
    required McpCloseHandler onClose,
  }) async {
    if (_closed) throw const McpConnectionException('the transport is closed');
    _onMessage = onMessage;
    _onClose = onClose;
  }

  @override
  void setProtocolVersion(String version) => _protocolVersion = version;

  Map<String, String> _headersFor({
    required String accept,
    Map<String, String>? extra,
    bool json = false,
    String? lastEventId,
  }) =>
      {
        ...headers,
        ...?extra,
        'Accept': accept,
        if (json) 'Content-Type': 'application/json',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
        if (_protocolVersion != null) 'MCP-Protocol-Version': _protocolVersion!,
        if (lastEventId != null) 'Last-Event-ID': lastEventId,
      };

  void _deliver(Map<String, Object?> message) {
    if (!_closed) _onMessage?.call(message);
  }

  /// The wait before reopening attempt [attempt] (from 1).
  Duration _delay(int attempt, Duration? asked) {
    if (asked != null) return asked;
    var micros = reconnectDelay.inMicroseconds.toDouble();
    for (var i = 1; i < attempt; i++) {
      micros *= 1.5;
    }
    const maxDelay = Duration(seconds: 30);
    return micros >= maxDelay.inMicroseconds
        ? maxDelay
        : Duration(microseconds: micros.round());
  }

  @override
  Future<void> send(
    Map<String, Object?> message, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    if (_closed || _failed) {
      throw const McpConnectionException('the transport is closed');
    }
    if (_sessionMissing) {
      throw const McpConnectionException(
        'the MCP session is gone',
        sessionMissing: true,
      );
    }
    // A token of this send alone, released at the end so that nothing of it
    // stays attached to the long-lived tokens.
    final token = CancelToken.any([_closeToken, cancelToken, CancelToken()])!;
    try {
      await _post(message, headers, token);
    } finally {
      token.cancel('done');
    }
  }

  Future<void> _post(
    Map<String, Object?> message,
    Map<String, String>? headers,
    CancelToken token,
  ) async {
    final method = message['method'];
    final id = message['id'];
    final isCall = method is String && id != null;
    final summary =
        method is String ? 'sending "$method"' : 'sending response #$id';

    final request = http.Request('POST', url)
      ..headers.addAll(
        _headersFor(
          accept: 'application/json, text/event-stream',
          extra: headers,
          json: true,
        ),
      )
      ..body = jsonEncode(message);

    final http.StreamedResponse response;
    try {
      response = await _send(_client, request, token);
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      throw McpConnectionException('$summary: $error', cause: error);
    }

    final status = response.statusCode;
    if (status == 404) {
      _release(response, drain: false);
      _sessionMissing = true;
      throw McpConnectionException(
        '$summary: failed to send: session not found',
        sessionMissing: true,
      );
    }
    if (status < 200 || status >= 300) {
      final body = await _errorBody(response);
      throw McpConnectionException('$summary: broken session: HTTP $status$body');
    }

    final sessionId = response.headers['mcp-session-id'];
    if (sessionId != null && sessionId.isNotEmpty) {
      final had = _sessionId;
      if (had == null) {
        _sessionId = sessionId;
      } else if (had != sessionId) {
        _release(response, drain: false);
        throw McpConnectionException(
          '$summary: mismatching session IDs "$had" and "$sessionId"',
        );
      }
    }

    if (status == 202 || status == 204 || !isCall) {
      _release(response);
      if (method == 'notifications/initialized') _openStandaloneStream();
      return;
    }

    switch (_mediaType(response)) {
      case 'application/json':
        final String body;
        try {
          body = await _readBody(response.stream, token);
        } on CancelledException {
          rethrow;
        } on Exception catch (error) {
          throw McpConnectionException(
            '$summary: reading the response failed: $error',
            cause: error,
          );
        }
        final messages = decodeMcpMessages(body);
        messages.forEach(_deliver);
        if (!messages.any((m) => _isResponseTo(m, id))) {
          throw McpConnectionException(
            '$summary: the JSON response carried no answer to the request',
          );
        }
      case 'text/event-stream':
        final state = _StreamState();
        var answered = await _readEvents(
          response.stream,
          token,
          _deliver,
          expectedId: id,
          state: state,
        );
        for (var attempt = 1;
            !answered && state.lastEventId != null && attempt <= maxRetries;
            attempt++) {
          await _wait(_delay(attempt, state.retry), token);
          final resumed = await _resume(summary, state.lastEventId!, token);
          if (resumed == null) continue;
          answered = await _readEvents(
            resumed.stream,
            token,
            _deliver,
            expectedId: id,
            state: state,
          );
        }
        if (!answered) {
          throw McpConnectionException(
            '$summary: the event stream ended before the response',
          );
        }
      case final other:
        _release(response, drain: false);
        throw McpConnectionException(
          '$summary: unsupported content type "$other"',
        );
    }
  }

  /// Reopens an event stream after [lastEventId]. Returns `null` when the
  /// request failed in a way worth retrying (the network).
  Future<http.StreamedResponse?> _resume(
    String summary,
    String lastEventId,
    CancelToken token,
  ) async {
    final request = http.Request('GET', url)
      ..headers.addAll(
        _headersFor(accept: 'text/event-stream', lastEventId: lastEventId),
      );
    final http.StreamedResponse response;
    try {
      response = await _send(_client, request, token);
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      _log.fine('Resuming the MCP event stream failed: $error');
      return null;
    }
    final status = response.statusCode;
    if (status == 404) {
      _release(response, drain: false);
      _sessionMissing = true;
      throw McpConnectionException(
        '$summary: failed to reconnect: session not found',
        sessionMissing: true,
      );
    }
    if (status < 200 ||
        status >= 300 ||
        _mediaType(response) != 'text/event-stream') {
      final body = await _errorBody(response);
      throw McpConnectionException(
        '$summary: failed to reconnect: HTTP $status$body',
      );
    }
    return response;
  }

  void _openStandaloneStream() {
    if (!openStandaloneStream || _standaloneOpened || _closed) return;
    _standaloneOpened = true;
    unawaited(_runStandaloneStream());
  }

  Future<void> _runStandaloneStream() async {
    final state = _StreamState();
    var failures = 0;
    var first = true;
    try {
      while (!_closed && !_failed) {
        if (!first) {
          await _wait(_delay(failures < 1 ? 1 : failures, state.retry), _closeToken);
        }
        first = false;
        final request = http.Request('GET', url)
          ..headers.addAll(
            _headersFor(
              accept: 'text/event-stream',
              lastEventId: state.lastEventId,
            ),
          );
        http.StreamedResponse? response;
        try {
          response = await _send(_client, request, _closeToken);
        } on CancelledException {
          rethrow;
        } on Exception catch (error) {
          _log.fine('Opening the standalone MCP event stream failed: $error');
        }
        if (response != null) {
          final status = response.statusCode;
          if (status == 405 || status == 404) {
            _release(response, drain: false);
            _log.fine('No standalone MCP event stream (HTTP $status)');
            return;
          }
          if (status == 200 && _mediaType(response) == 'text/event-stream') {
            failures = 0;
            try {
              await _readEvents(response.stream, _closeToken, _deliver, state: state);
            } on CancelledException {
              rethrow;
            } on Exception catch (error) {
              _log.fine('The standalone MCP event stream failed: $error');
            }
            continue;
          }
          _release(response, drain: false);
          _log.fine('The standalone MCP event stream got HTTP $status');
        }
        failures++;
        if (failures > maxRetries) {
          _fail(
            const McpConnectionException(
              'the standalone MCP event stream could not be reopened',
            ),
          );
          return;
        }
      }
    } on CancelledException {
      // Closed.
    }
  }

  void _fail(McpConnectionException failure) {
    if (_closed || _failed) return;
    _failed = true;
    _onClose?.call(failure);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeToken.cancel('the MCP transport was closed');
    final sessionId = _sessionId;
    if (sessionId != null && !_sessionMissing) {
      final token = CancelToken();
      try {
        final request = http.Request('DELETE', url)
          ..headers.addAll({
            ...headers,
            'Mcp-Session-Id': sessionId,
            if (_protocolVersion != null)
              'MCP-Protocol-Version': _protocolVersion!,
          });
        final response =
            await _send(_client, request, token).timeout(closeTimeout);
        _release(response);
      } on Object catch (error) {
        _log.fine('Ending the MCP session failed: $error');
      } finally {
        token.cancel('done');
      }
    }
    _created?.close();
    _created = null;
    _onClose?.call(null);
  }
}

/// The HTTP+SSE transport of MCP revision 2024-11-05 (deprecated by the
/// specification, still served by many servers).
///
/// Port of go-sdk `mcp.SSEClientTransport` (and mark3labs `transport.SSE`):
/// [start] opens a GET event stream at [url] and waits for its first event,
/// which must be `endpoint`: its data is the URL (relative to [url]) to POST
/// messages to. Every later event carries a message of the server. When the
/// stream ends the connection is over. [headers] go out with every request.
final class SseTransport implements McpTransport {
  /// A transport whose event stream is at [url].
  SseTransport(
    this.url, {
    http.Client? httpClient,
    this.headers = const {},
  }) : _injected = httpClient;

  /// The URL of the event stream.
  final Uri url;

  /// Headers sent with every request.
  final Map<String, String> headers;

  final http.Client? _injected;
  http.Client? _created;
  final CancelToken _closeToken = CancelToken();
  McpMessageHandler? _onMessage;
  McpCloseHandler? _onClose;
  Uri? _endpoint;
  bool _closed = false;
  bool _ended = false;

  /// The URL messages are POSTed to, once the server named it.
  Uri? get endpoint => _endpoint;

  http.Client get _client => _injected ?? (_created ??= http.Client());

  @override
  Future<void> start({
    required McpMessageHandler onMessage,
    required McpCloseHandler onClose,
  }) async {
    if (_closed) throw const McpConnectionException('the transport is closed');
    _onMessage = onMessage;
    _onClose = onClose;

    final request = http.Request('GET', url)
      ..headers.addAll({...headers, 'Accept': 'text/event-stream'});
    final http.StreamedResponse response;
    try {
      response = await _send(_client, request, _closeToken);
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      throw McpConnectionException(
        'opening the MCP event stream failed: $error',
        cause: error,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _errorBody(response);
      throw McpConnectionException(
        'opening the MCP event stream failed: HTTP ${response.statusCode}$body',
      );
    }

    final endpoint = Completer<Uri>();
    var first = true;
    final reading = CancelToken.any([_closeToken, CancelToken()])!;
    unawaited(
      _readEvents(
        response.stream,
        reading,
        (message) {
          if (!_closed) _onMessage?.call(message);
        },
        onEvent: (event) {
          if (!first) return true;
          first = false;
          if (event.event != 'endpoint') {
            endpoint.completeError(
              McpConnectionException(
                'missing endpoint: first event is "${event.event}", '
                'want "endpoint"',
              ),
            );
            reading.cancel('missing endpoint');
          } else {
            try {
              endpoint.complete(url.resolve(event.data.trim()));
            } on FormatException catch (error) {
              endpoint.completeError(
                McpConnectionException('missing endpoint: $error', cause: error),
              );
              reading.cancel('missing endpoint');
            }
          }
          return false;
        },
      ).then<void>(
        (_) => _streamEnded(endpoint, null),
        onError: (Object error) => _streamEnded(endpoint, error),
      ),
    );
    _endpoint = await endpoint.future;
  }

  void _streamEnded(Completer<Uri> endpoint, Object? error) {
    if (!endpoint.isCompleted) {
      endpoint.completeError(
        McpConnectionException(
          'missing endpoint: the event stream ended',
          cause: error,
        ),
      );
      return;
    }
    if (_closed || _ended || _endpoint == null) return;
    _ended = true;
    _onClose?.call(
      McpConnectionException('the MCP event stream ended', cause: error),
    );
  }

  @override
  void setProtocolVersion(String version) {}

  @override
  Future<void> send(
    Map<String, Object?> message, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final endpoint = _endpoint;
    if (_closed || _ended || endpoint == null) {
      throw const McpConnectionException('the transport is closed');
    }
    final token = CancelToken.any([_closeToken, cancelToken, CancelToken()])!;
    try {
      final request = http.Request('POST', endpoint)
        ..headers.addAll({
          ...this.headers,
          ...?headers,
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(message);
      final http.StreamedResponse response;
      try {
        response = await _send(_client, request, token);
      } on CancelledException {
        rethrow;
      } on Exception catch (error) {
        throw McpConnectionException('failed to write: $error', cause: error);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await _errorBody(response);
        throw McpConnectionException(
          'failed to write: HTTP ${response.statusCode}$body',
        );
      }
      _release(response);
    } finally {
      token.cancel('done');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeToken.cancel('the MCP transport was closed');
    _created?.close();
    _created = null;
    _onClose?.call(null);
  }
}
