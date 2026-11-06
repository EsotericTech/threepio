/// Server-sent events and line streams, as the HTTP providers and the MCP
/// transports read them.
///
/// Eino leaves this to each provider's Go SDK (go-openai's stream reader,
/// anthropic-sdk-go's `ssestream`, genai's SSE reader). Here one decoder and
/// one pump serve every provider, so cancellation, the idle timeout and the
/// handling of a reader that was closed early behave the same everywhere.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../internal/provider_http.dart';
import '../../../streaming/stream_writer.dart';
import '../cancel_token.dart';

/// One server-sent event.
///
/// [event] is the value of the last `event:` field (`null` when the event had
/// none), [data] the `data:` fields joined with `\n`, [id] the last event id
/// seen so far and [retry] the reconnection time the server asked for.
@immutable
final class SseEvent {
  /// An event with [data].
  const SseEvent({required this.data, this.event, this.id, this.retry});

  /// The event type, or `null` for the default type (`message`).
  final String? event;

  /// The data of the event.
  final String data;

  /// The last event id, which a client sends back as `Last-Event-ID` when it
  /// reconnects.
  final String? id;

  /// The reconnection delay the server asked for, if any.
  final Duration? retry;

  @override
  bool operator ==(Object other) =>
      other is SseEvent &&
      other.event == event &&
      other.data == data &&
      other.id == id &&
      other.retry == retry;

  @override
  int get hashCode => Object.hash(event, data, id, retry);

  @override
  String toString() => 'SseEvent(event: $event, data: $data, id: $id)';
}

/// Decodes server-sent events from the lines of a response body.
///
/// Feed it every line (without its line terminator) with [addLine]; it
/// returns an event when one is complete. Call [close] at the end of the
/// body.
///
/// The decoder follows the WHATWG rules: `:` starts a comment, a field name
/// is followed by an optional `: `, `data` lines are joined with `\n`, a
/// blank line ends an event, an event without data is not dispatched, the
/// last `id` is remembered across events and an `id` containing NUL is
/// ignored.
///
/// With [dispatchEachDataLine] every `data:` line is an event of its own, as
/// go-openai and the genai SDK read OpenAI-compatible and Gemini streams.
/// Servers that put a JSON document on each `data:` line without a blank
/// line in between are read correctly this way, and `event:` lines still name
/// the event that follows them.
final class SseLineDecoder {
  /// A decoder; see [dispatchEachDataLine].
  SseLineDecoder({this.dispatchEachDataLine = false});

  /// Whether each `data:` line is dispatched at once instead of at the next
  /// blank line.
  final bool dispatchEachDataLine;

  String? _event;
  final List<String> _data = [];
  String? _lastId;
  Duration? _retry;

  /// The last event id seen, for `Last-Event-ID` on a reconnect.
  String? get lastEventId => _lastId;

  /// Takes one line of the body. Returns the event the line completes, if
  /// any.
  SseEvent? addLine(String line) {
    if (line.isEmpty) return _dispatch();
    if (line.startsWith(':')) return null;

    final colon = line.indexOf(':');
    final String field;
    var value = '';
    if (colon < 0) {
      field = line;
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
    }

    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _data.add(value);
        if (dispatchEachDataLine) return _dispatch();
      case 'id':
        if (!value.contains('\u0000')) _lastId = value;
      case 'retry':
        final millis = int.tryParse(value);
        if (millis != null && millis >= 0) {
          _retry = Duration(milliseconds: millis);
        }
    }
    return null;
  }

  /// Ends the body. Returns the event that was still being collected, if it
  /// has data: servers often omit the blank line after their last event.
  SseEvent? close() => _dispatch();

  SseEvent? _dispatch() {
    if (_data.isEmpty) {
      _event = null;
      return null;
    }
    final event = SseEvent(
      event: _event,
      data: _data.join('\n'),
      id: _lastId,
      retry: _retry,
    );
    _event = null;
    _data.clear();
    return event;
  }
}

/// What a line or event handler of [pumpLines] / [pumpSse] tells the pump.
enum PumpAction {
  /// Keep reading.
  next,

  /// The stream is complete; stop reading and close the writer.
  stop,
}

/// Reads the lines of [bytes] (UTF-8) into [writer] until the body ends.
///
/// [onLine] gets each line and may send items to [writer]; it returns
/// [PumpAction.stop] when the stream is complete (OpenAI's `[DONE]`). What it
/// throws ends the stream with that error. The pump also ends:
///
/// * when [cancelToken] is cancelled, with a `CancelledException` (or
///   [cancelledError]);
/// * when no line arrives within [idleTimeout], with [idleError];
/// * when the body fails, with [streamError] applied to the failure;
/// * when the reader of [writer] was closed, silently.
///
/// When the stream completes normally (a stop or the end of the body),
/// [onComplete] runs before the writer is closed and may send the last
/// items; what it throws is sent as an error. The idle timer restarts with
/// every line, comments and blank lines included (servers send them as
/// keep-alives). [writer] is closed in every case, and the returned future
/// completes once it is, never with an error.
@internal
Future<void> pumpLines<T>({
  required Stream<List<int>> bytes,
  required StreamWriter<T> writer,
  required PumpAction Function(String line) onLine,
  required Object Function(Object error) streamError,
  CancelToken? cancelToken,
  Duration? idleTimeout,
  Object Function()? idleError,
  Object Function(CancelToken token)? cancelledError,
  void Function()? onDone,
  void Function()? onComplete,
}) async {
  StreamSubscription<String>? subscription;
  final done = Completer<void>();
  Timer? idleTimer;
  var completed = false;

  void finish([Object? error, StackTrace? stackTrace]) {
    if (done.isCompleted) return;
    idleTimer?.cancel();
    if (error != null) writer.sendError(error, stackTrace);
    done.complete();
  }

  void armIdleTimer() {
    final timeout = idleTimeout;
    if (timeout == null) return;
    idleTimer?.cancel();
    idleTimer = Timer(timeout, () {
      finish(
        idleError?.call() ??
            TimeoutException('Stream idle for $timeout', timeout),
      );
    });
  }

  if (cancelToken != null && cancelToken.isCancelled) {
    // Release the response body unread.
    unawaited(bytes.listen(null).cancel());
    finish(
      cancelledError?.call(cancelToken) ??
          CancelledException(cancelToken.reason),
    );
  } else {
    final lines =
        bytes.transform(utf8.decoder).transform(const LineSplitter());
    subscription = lines.listen(
      (line) {
        if (done.isCompleted) return;
        if (writer.isClosed) {
          finish();
          return;
        }
        armIdleTimer();
        final PumpAction action;
        try {
          action = onLine(line);
        } catch (error, stackTrace) {
          finish(error, stackTrace);
          return;
        }
        if (action == PumpAction.stop) {
          completed = true;
          finish();
        } else if (writer.isClosed) {
          finish();
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          finish(streamError(error), stackTrace),
      onDone: () {
        if (done.isCompleted) return;
        onDone?.call();
        completed = true;
        finish();
      },
      cancelOnError: true,
    );
    armIdleTimer();
  }

  final watch = cancelToken == null ? null : CallWatch(cancelToken);
  watch?.onCancel(
    () => finish(
      cancelledError?.call(cancelToken!) ??
          CancelledException(cancelToken!.reason),
    ),
  );

  await done.future;
  watch?.release();
  await subscription?.cancel();
  if (completed && onComplete != null && !writer.isClosed) {
    try {
      onComplete();
    } catch (error, stackTrace) {
      writer.sendError(error, stackTrace);
    }
  }
  await writer.close();
}

/// Reads the server-sent events of [bytes] into [writer] until the body
/// ends: [pumpLines] with an [SseLineDecoder] in between.
///
/// [onEvent] gets each event; what it returns and throws means what it means
/// for [pumpLines], and so does [onComplete]. An event still being collected
/// when the body ends is handed to [onEvent] as well.
@internal
Future<void> pumpSse<T>({
  required Stream<List<int>> bytes,
  required StreamWriter<T> writer,
  required PumpAction Function(SseEvent event) onEvent,
  required Object Function(Object error) streamError,
  CancelToken? cancelToken,
  Duration? idleTimeout,
  Object Function()? idleError,
  Object Function(CancelToken token)? cancelledError,
  bool dispatchEachDataLine = true,
  void Function()? onComplete,
}) {
  final decoder = SseLineDecoder(dispatchEachDataLine: dispatchEachDataLine);
  var failed = false;
  return pumpLines<T>(
    bytes: bytes,
    writer: writer,
    streamError: streamError,
    cancelToken: cancelToken,
    idleTimeout: idleTimeout,
    idleError: idleError,
    cancelledError: cancelledError,
    onLine: (line) {
      final event = decoder.addLine(line);
      if (event == null) return PumpAction.next;
      return onEvent(event);
    },
    onDone: () {
      final last = decoder.close();
      if (last == null) return;
      try {
        onEvent(last);
      } catch (error, stackTrace) {
        failed = true;
        writer.sendError(error, stackTrace);
      }
    },
    onComplete: onComplete == null
        ? null
        : () {
            if (!failed) onComplete();
          },
  );
}
