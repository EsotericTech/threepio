// Tests written for the port (no Go counterpart): eino-ext leaves server-sent
// events to each provider's SDK (go-openai's stream reader, anthropic-sdk-go's
// `ssestream`, genai's SSE reader). threepio has one decoder
// (`SseLineDecoder`, WHATWG rules) and one pump (`pumpLines` / `pumpSse`)
// for every provider; these tests pin the decoder rules and what ends a pump:
// a stop, the end of the body, a cancel token (before and during the read),
// the idle timeout, a failing body, a throwing handler and a reader that was
// closed early (the body subscription is cancelled), plus `onComplete`.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/openai_compatible/sse.dart';
import 'package:threepio_core/threepio_core.dart';

/// An error the drained reader delivered.
final class _Failure {
  _Failure(this.error);
  final Object error;
  @override
  String toString() => 'Failure($error)';
}

/// Every item and error of [reader] until it ends.
Future<List<Object?>> _drain<T>(StreamReader<T> reader) async {
  final out = <Object?>[];
  while (true) {
    try {
      out.add(await reader.recv());
    } on StreamEOFException {
      return out;
    } on Object catch (error) {
      out.add(_Failure(error));
    }
  }
}

Matcher _failure(Matcher error) =>
    isA<_Failure>().having((f) => f.error, 'error', error);

/// A body that records whether it was listened to and cancelled.
final class _Body {
  _Body() {
    controller = StreamController<List<int>>(
      onListen: () => listened = true,
      // A future of the current zone: under fake_async, awaiting the
      // root-zone future a plain callback leads to would never resume.
      onCancel: () async => cancelled = true,
    );
  }

  late final StreamController<List<int>> controller;
  bool listened = false;
  bool cancelled = false;

  Stream<List<int>> get stream => controller.stream;

  void add(String text) => controller.add(utf8.encode(text));
}

Stream<List<int>> _bytes(List<String> chunks) =>
    Stream.fromIterable([for (final c in chunks) utf8.encode(c)]);

void main() {
  group('SseLineDecoder', () {
    test('a blank line dispatches the data collected so far', () {
      final decoder = SseLineDecoder();
      expect(decoder.addLine('data: hello'), isNull);
      expect(decoder.addLine(''), const SseEvent(data: 'hello'));
    });

    test('lines starting with a colon are comments', () {
      final decoder = SseLineDecoder();
      expect(decoder.addLine(': keep-alive'), isNull);
      expect(decoder.addLine(':'), isNull);
      expect(decoder.addLine('data: x'), isNull);
      expect(decoder.addLine(': between'), isNull);
      expect(decoder.addLine(''), const SseEvent(data: 'x'));
    });

    test('only one space after the colon is removed', () {
      final decoder = SseLineDecoder();
      decoder.addLine('data:no-space');
      expect(decoder.addLine('')!.data, 'no-space');
      decoder.addLine('data:  two spaces');
      expect(decoder.addLine('')!.data, ' two spaces');
      decoder.addLine('data: a: b');
      expect(decoder.addLine('')!.data, 'a: b');
    });

    test('several data lines are joined with a newline', () {
      final decoder = SseLineDecoder();
      decoder
        ..addLine('data: {"a":')
        ..addLine('data: 1}');
      expect(decoder.addLine(''), const SseEvent(data: '{"a":\n1}'));
    });

    test('a field without a colon has an empty value', () {
      final decoder = SseLineDecoder();
      expect(decoder.addLine('data'), isNull);
      expect(decoder.addLine(''), const SseEvent(data: ''));
    });

    test('the event field names the event and is reset after it', () {
      final decoder = SseLineDecoder();
      decoder
        ..addLine('event: message_start')
        ..addLine('data: {}');
      expect(
        decoder.addLine(''),
        const SseEvent(event: 'message_start', data: '{}'),
      );
      decoder.addLine('data: next');
      expect(decoder.addLine('')!.event, isNull);
    });

    test('an event without data is not dispatched and its name is dropped',
        () {
      final decoder = SseLineDecoder();
      decoder.addLine('event: ping');
      expect(decoder.addLine(''), isNull);
      decoder.addLine('data: x');
      expect(decoder.addLine(''), const SseEvent(data: 'x'));
      expect(decoder.addLine(''), isNull, reason: 'nothing collected');
    });

    test('the last id is remembered across events', () {
      final decoder = SseLineDecoder();
      decoder
        ..addLine('id: 7')
        ..addLine('data: a');
      expect(decoder.addLine('')!.id, '7');
      decoder.addLine('data: b');
      expect(decoder.addLine('')!.id, '7');
      expect(decoder.lastEventId, '7');
    });

    test('an id that contains NUL is ignored', () {
      final decoder = SseLineDecoder();
      decoder.addLine('id: 1');
      decoder.addLine('id: a${String.fromCharCode(0)}b');
      decoder.addLine('data: x');
      expect(decoder.addLine('')!.id, '1');
    });

    test('retry is read as milliseconds; anything else is ignored', () {
      final decoder = SseLineDecoder();
      decoder
        ..addLine('retry: 1500')
        ..addLine('data: x');
      expect(decoder.addLine('')!.retry, const Duration(milliseconds: 1500));
      decoder
        ..addLine('retry: soon')
        ..addLine('retry: -1')
        ..addLine('data: y');
      expect(decoder.addLine('')!.retry, const Duration(milliseconds: 1500));
    });

    test('unknown fields are ignored', () {
      final decoder = SseLineDecoder();
      decoder
        ..addLine('foo: bar')
        ..addLine('data: x');
      expect(decoder.addLine(''), const SseEvent(data: 'x'));
    });

    test('close hands over an event that misses its blank line', () {
      final decoder = SseLineDecoder();
      decoder.addLine('data: last');
      expect(decoder.close(), const SseEvent(data: 'last'));
      expect(decoder.close(), isNull);
    });

    test('close without collected data returns nothing', () {
      final decoder = SseLineDecoder();
      decoder.addLine('event: done');
      expect(decoder.close(), isNull);
    });

    test('with dispatchEachDataLine every data line is an event', () {
      final decoder = SseLineDecoder(dispatchEachDataLine: true);
      expect(decoder.addLine('data: {"a":1}'), const SseEvent(data: '{"a":1}'));
      expect(decoder.addLine('data: {"b":2}'), const SseEvent(data: '{"b":2}'));
      expect(decoder.addLine(''), isNull);
    });

    test('with dispatchEachDataLine an event line names the next data line',
        () {
      final decoder = SseLineDecoder(dispatchEachDataLine: true);
      expect(decoder.addLine('event: error'), isNull);
      expect(
        decoder.addLine('data: {"error":{}}'),
        const SseEvent(event: 'error', data: '{"error":{}}'),
      );
      expect(decoder.addLine('data: x')!.event, isNull);
    });

    test('SseEvent equality and hashCode cover every field', () {
      const a = SseEvent(data: 'd', event: 'e', id: '1', retry: Duration(seconds: 1));
      const b = SseEvent(data: 'd', event: 'e', id: '1', retry: Duration(seconds: 1));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const SseEvent(data: 'd', event: 'e', id: '2'), isFalse);
      expect(a.toString(), contains('data: d'));
    });
  });

  group('pumpLines', () {
    test('hands over whole lines, also when a line or a character is split',
        () async {
      final (reader, writer) = pipe<String>();
      final e = String.fromCharCode(0xE9);
      final split = utf8.encode('h$e');
      final body = Stream<List<int>>.fromIterable([
        utf8.encode('first li'),
        [...utf8.encode('ne\n'), ...split.sublist(0, 2)],
        [...split.sublist(2), ...utf8.encode('llo\r\nthird\n')],
      ]);

      final done = pumpLines<String>(
        bytes: body,
        writer: writer,
        onLine: (line) {
          writer.send(line);
          return PumpAction.next;
        },
        streamError: (error) => error,
      );

      expect(await _drain(reader), ['first line', 'h${e}llo', 'third']);
      await done;
    });

    test('a stop closes the writer and cancels the body', () async {
      final body = _Body();
      final (reader, writer) = pipe<String>();
      var completed = 0;

      final done = pumpLines<String>(
        bytes: body.stream,
        writer: writer,
        onLine: (line) {
          if (line == 'STOP') return PumpAction.stop;
          writer.send(line);
          return PumpAction.next;
        },
        streamError: (error) => error,
        onComplete: () {
          completed++;
          writer.send('complete');
        },
      );
      body
        ..add('a\n')
        ..add('STOP\n')
        ..add('after\n');

      expect(await _drain(reader), ['a', 'complete']);
      await done;
      expect(body.cancelled, isTrue);
      expect(completed, 1);
    });

    test('the end of the body completes the stream; onDone runs before it',
        () async {
      final (reader, writer) = pipe<String>();
      final calls = <String>[];

      final done = pumpLines<String>(
        bytes: _bytes(['a\nb']),
        writer: writer,
        onLine: (line) {
          calls.add('line $line');
          writer.send(line);
          return PumpAction.next;
        },
        streamError: (error) => error,
        onDone: () => calls.add('done'),
        onComplete: () => calls.add('complete'),
      );

      expect(await _drain(reader), ['a', 'b']);
      await done;
      expect(calls, ['line a', 'line b', 'done', 'complete']);
    });

    test('a token cancelled before the read releases the body unread',
        () async {
      final body = _Body();
      final (reader, writer) = pipe<String>();
      final token = CancelToken()..cancel('too late');
      var lines = 0;
      var completed = false;

      final done = pumpLines<String>(
        bytes: body.stream,
        writer: writer,
        cancelToken: token,
        onLine: (_) {
          lines++;
          return PumpAction.next;
        },
        streamError: (error) => error,
        onComplete: () => completed = true,
      );

      expect(await _drain(reader), [
        _failure(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'too late'),
        ),
      ]);
      await done;
      expect(body.listened, isTrue);
      expect(body.cancelled, isTrue);
      expect(lines, 0);
      expect(completed, isFalse);
    });

    test('cancelledError replaces the CancelledException', () async {
      final (reader, writer) = pipe<String>();
      final done = pumpLines<String>(
        bytes: _Body().stream,
        writer: writer,
        cancelToken: CancelToken()..cancel(),
        cancelledError: (token) => StateError('mine'),
        onLine: (_) => PumpAction.next,
        streamError: (error) => error,
      );
      expect(await _drain(reader), [_failure(isA<StateError>())]);
      await done;
    });

    test('a token cancelled during the read ends the stream and the body',
        () async {
      final body = _Body();
      final (reader, writer) = pipe<String>();
      final token = CancelToken();
      var completed = false;

      final done = pumpLines<String>(
        bytes: body.stream,
        writer: writer,
        cancelToken: token,
        onLine: (line) {
          writer.send(line);
          return PumpAction.next;
        },
        streamError: (error) => error,
        onComplete: () => completed = true,
      );
      body.add('one\n');
      expect(await reader.recv(), 'one');

      token.cancel('stop');
      expect(await _drain(reader), [_failure(isA<CancelledException>())]);
      await done;
      expect(body.cancelled, isTrue);
      expect(completed, isFalse);
    });

    test('no line within the idle timeout fails the stream', () {
      fakeAsync((async) {
        final body = _Body();
        final (reader, writer) = pipe<String>();
        List<Object?>? items;
        var finished = false;

        pumpLines<String>(
          bytes: body.stream,
          writer: writer,
          idleTimeout: const Duration(milliseconds: 30),
          onLine: (line) {
            writer.send(line);
            return PumpAction.next;
          },
          streamError: (error) => error,
        ).then((_) => finished = true);
        _drain(reader).then((value) => items = value);

        async.elapse(const Duration(milliseconds: 29));
        expect(items, isNull);
        async.elapse(const Duration(milliseconds: 2));
        expect(items, [_failure(isA<TimeoutException>())]);
        expect(finished, isTrue);
        expect(body.cancelled, isTrue);
      });
    });

    test('every line restarts the idle timer, comments and blank lines too',
        () {
      fakeAsync((async) {
        final body = _Body();
        final (reader, writer) = pipe<String>();
        List<Object?>? items;

        pumpLines<String>(
          bytes: body.stream,
          writer: writer,
          idleTimeout: const Duration(milliseconds: 30),
          idleError: () => StateError('idle'),
          onLine: (line) {
            if (line.startsWith('data')) writer.send(line);
            return PumpAction.next;
          },
          streamError: (error) => error,
        );
        _drain(reader).then((value) => items = value);

        for (final line in ['data: 1', ': keep-alive', '', 'data: 2']) {
          async.elapse(const Duration(milliseconds: 20));
          body.add('$line\n');
        }
        async.elapse(const Duration(milliseconds: 20));
        expect(items, isNull, reason: 'never 30 ms without a line');
        async.elapse(const Duration(milliseconds: 11));
        expect(items, ['data: 1', 'data: 2', _failure(isA<StateError>())]);
      });
    });

    test('a failing body ends the stream with streamError of the failure',
        () async {
      final body = _Body();
      final (reader, writer) = pipe<String>();
      var completed = false;

      final done = pumpLines<String>(
        bytes: body.stream,
        writer: writer,
        onLine: (line) {
          writer.send(line);
          return PumpAction.next;
        },
        streamError: (error) => StateError('wrapped: $error'),
        onComplete: () => completed = true,
      );
      body.add('ok\n');
      body.controller.addError(const FormatException('broken'));

      expect(await _drain(reader), [
        'ok',
        _failure(
          isA<StateError>().having((e) => e.message, 'message', contains('broken')),
        ),
      ]);
      await done;
      expect(completed, isFalse);
    });

    test('what onLine throws ends the stream with that error', () async {
      final body = _Body();
      final (reader, writer) = pipe<String>();

      final done = pumpLines<String>(
        bytes: body.stream,
        writer: writer,
        onLine: (line) => throw ArgumentError(line),
        streamError: (error) => error,
      );
      body.add('bad\n');

      expect(await _drain(reader), [_failure(isA<ArgumentError>())]);
      await done;
      expect(body.cancelled, isTrue);
    });

    test('a reader closed early ends the pump silently and cancels the body',
        () async {
      final body = _Body();
      final (reader, writer) = pipe<String>();
      var completed = false;

      final done = pumpLines<String>(
        bytes: body.stream,
        writer: writer,
        onLine: (line) {
          writer.send(line);
          return PumpAction.next;
        },
        streamError: (error) => error,
        onComplete: () => completed = true,
      );
      body.add('one\n');
      expect(await reader.recv(), 'one');
      await reader.close();
      body.add('two\n');

      await done;
      expect(body.cancelled, isTrue);
      expect(completed, isFalse);
    });

    test('what onComplete throws is sent as an error', () async {
      final (reader, writer) = pipe<String>();
      final done = pumpLines<String>(
        bytes: _bytes(['a\n']),
        writer: writer,
        onLine: (line) {
          writer.send(line);
          return PumpAction.next;
        },
        streamError: (error) => error,
        onComplete: () => throw StateError('end'),
      );
      expect(await _drain(reader), ['a', _failure(isA<StateError>())]);
      await done;
    });

    test('the returned future never completes with an error', () async {
      final (reader, writer) = pipe<String>();
      final body = Stream<List<int>>.error(StateError('no body'));
      await expectLater(
        pumpLines<String>(
          bytes: body,
          writer: writer,
          onLine: (_) => PumpAction.next,
          streamError: (error) => error,
        ),
        completes,
      );
      expect(await _drain(reader), [_failure(isA<StateError>())]);
    });
  });

  group('pumpSse', () {
    test('reads one event per data line and stops at the handler', () async {
      final (reader, writer) = pipe<String>();
      final done = pumpSse<String>(
        bytes: _bytes([
          ': hello\n',
          'data: {"a":1}\n',
          'data: {"a":2}\n\n',
          'data: [DONE]\n\n',
          'data: never\n\n',
        ]),
        writer: writer,
        onEvent: (event) {
          if (event.data == '[DONE]') return PumpAction.stop;
          writer.send(event.data);
          return PumpAction.next;
        },
        streamError: (error) => error,
      );
      expect(await _drain(reader), ['{"a":1}', '{"a":2}']);
      await done;
    });

    test('without dispatchEachDataLine data lines are joined until a blank line',
        () async {
      final (reader, writer) = pipe<String>();
      final done = pumpSse<String>(
        bytes: _bytes(['event: x\ndata: 1\ndata: 2\n\n']),
        writer: writer,
        dispatchEachDataLine: false,
        onEvent: (event) {
          writer.send('${event.event}:${event.data}');
          return PumpAction.next;
        },
        streamError: (error) => error,
      );
      expect(await _drain(reader), ['x:1\n2']);
      await done;
    });

    test('an event still collected at the end of the body is handled, then '
        'onComplete runs', () async {
      final (reader, writer) = pipe<String>();
      final done = pumpSse<String>(
        bytes: _bytes(['data: a\n\n', 'data: last']),
        writer: writer,
        dispatchEachDataLine: false,
        onEvent: (event) {
          writer.send(event.data);
          return PumpAction.next;
        },
        streamError: (error) => error,
        onComplete: () => writer.send('complete'),
      );
      expect(await _drain(reader), ['a', 'last', 'complete']);
      await done;
    });

    test('when the last event fails, onComplete does not run', () async {
      final (reader, writer) = pipe<String>();
      var completed = false;
      final done = pumpSse<String>(
        bytes: _bytes(['data: last']),
        writer: writer,
        dispatchEachDataLine: false,
        onEvent: (event) => throw StateError(event.data),
        streamError: (error) => error,
        onComplete: () => completed = true,
      );
      expect(await _drain(reader), [_failure(isA<StateError>())]);
      await done;
      expect(completed, isFalse);
    });

    test('CRLF line endings are read like LF', () async {
      final (reader, writer) = pipe<String>();
      final done = pumpSse<String>(
        bytes: _bytes(['data: a\r\n\r\ndata: b\r\n\r\n']),
        writer: writer,
        onEvent: (event) {
          writer.send(event.data);
          return PumpAction.next;
        },
        streamError: (error) => error,
      );
      expect(await _drain(reader), ['a', 'b']);
      await done;
    });

    test('cancellation and the idle timeout are those of pumpLines', () {
      fakeAsync((async) {
        final (reader, writer) = pipe<String>();
        List<Object?>? items;
        pumpSse<String>(
          bytes: _Body().stream,
          writer: writer,
          idleTimeout: const Duration(milliseconds: 10),
          idleError: () => StateError('idle'),
          onEvent: (_) => PumpAction.next,
          streamError: (error) => error,
        );
        _drain(reader).then((value) => items = value);
        async.elapse(const Duration(milliseconds: 11));
        expect(items, [_failure(isA<StateError>())]);
      });
    });
  });
}
