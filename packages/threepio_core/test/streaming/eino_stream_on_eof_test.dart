// Ports of the tests in eino `schema/stream_oneof_test.go` (v0.9.22): the
// `onEof` option of `StreamReader.convert` (Go: `schema.WithOnEOF`).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';
import 'package:threepio_core/src/streaming/stream_utils.dart';

/// Lets every already scheduled microtask and zero-delay timer run.
Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);

/// Reads [reader] to its end; Go's `recvAll`.
Future<(List<String>, List<Object>)> recvAll(StreamReader<String> reader) async {
  final values = <String>[];
  final errors = <Object>[];
  while (true) {
    try {
      values.add(await reader.recv());
    } on StreamEOFException {
      return (values, errors);
    } catch (error) {
      errors.add(error);
    }
  }
}

/// An array reader passed through an identity conversion; Go's `makeStream`.
StreamReader<String> makeStream(
  List<String> items, {
  Object? Function(Object error)? errWrapper,
  FutureOr<String?> Function()? onEof,
}) =>
    StreamReader.fromIterable(items)
        .convert<String>((s) => s, errWrapper: errWrapper, onEof: onEof);

void main() {
  const items = ['a', 'b', 'c', 'd'];

  // TestWithOnEOF_PassThroughEOF
  test('onEof returning null ends the stream normally', () async {
    final reader = makeStream(items, onEof: () => null);

    final (values, errors) = await recvAll(reader);
    await reader.close();

    expect(errors, isEmpty);
    expect(values, items);
  });

  test('onEof throwing StreamEOFException ends the stream normally', () async {
    final reader = makeStream(
      items,
      onEof: () => throw const StreamEOFException(),
    );

    final (values, errors) = await recvAll(reader);
    await reader.close();

    expect(errors, isEmpty);
    expect(values, items);
  });

  // TestWithOnEOF_InjectError
  test('an error thrown by onEof is delivered before the end', () async {
    final customError = Exception('validation failed');
    final reader = makeStream(items, onEof: () => throw customError);

    final (values, errors) = await recvAll(reader);
    await reader.close();

    expect(values, items);
    expect(errors, [same(customError)]);
  });

  // TestWithOnEOF_InjectValue
  test('a value returned by onEof is delivered before the end', () async {
    final reader = makeStream(items, onEof: () => 'extra');

    final (values, errors) = await recvAll(reader);
    await reader.close();

    expect(errors, isEmpty);
    expect(values, [...items, 'extra']);
  });

  // TestWithOnEOF_BlockingCallback
  test('recv waits for an asynchronous onEof', () async {
    final (reader, writer) = pipe<String>();
    final unblock = Completer<void>();
    final converted = reader.convert<String>(
      (s) => s,
      onEof: () async {
        await unblock.future;
        return 'after-block';
      },
    );

    writer.send('x');
    await writer.close();

    expect(await converted.recv(), 'x');

    var returned = false;
    final second = converted.recv().whenComplete(() => returned = true);
    await pumpEventQueue();
    expect(returned, isFalse, reason: 'recv returned before onEof finished');

    unblock.complete();

    expect(await second, 'after-block');
    await expectLater(converted.recv(), throwsA(isA<StreamEOFException>()));
    await converted.close();
  });

  // TestWithOnEOF_EmptyStream
  test('onEof runs for a stream without items', () async {
    final customError = Exception('empty stream error');
    final reader = makeStream(const [], onEof: () => throw customError);

    await expectLater(reader.recv(), throwsA(same(customError)));
    await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));
    await reader.close();
  });

  // TestWithOnEOF_WithErrWrapper_ErrorPath
  test('an error of the stream does not trigger onEof', () async {
    final (reader, writer) = pipe<String>();
    final streamError = Exception('stream error');
    var onEofCalled = false;

    final converted = reader.convert<String>(
      (s) => s,
      errWrapper: (error) => error,
      onEof: () {
        onEofCalled = true;
        throw Exception('should not happen');
      },
    );

    writer
      ..send('a')
      ..sendError(streamError);

    expect(await converted.recv(), 'a');
    await expectLater(converted.recv(), throwsA(same(streamError)));
    expect(onEofCalled, isFalse);

    await writer.close();
    await converted.close();
  });

  // TestWithOnEOF_WithErrWrapper_EOFPath
  test('a clean end of the stream does not trigger errWrapper', () async {
    var errWrapperCalled = false;
    final reader = makeStream(
      const ['a', 'b', 'c'],
      errWrapper: (error) {
        errWrapperCalled = true;
        return error;
      },
      onEof: () => 'oneof-val',
    );

    final (values, errors) = await recvAll(reader);
    await reader.close();

    expect(errors, isEmpty);
    expect(values, ['a', 'b', 'c', 'oneof-val']);
    expect(errWrapperCalled, isFalse);
  });

  // TestWithOnEOF_MultipleRecvAfterEOF
  test('onEof runs once; every later recv reports the end', () async {
    final customError = Exception('oneof error');
    var calls = 0;
    final reader = makeStream(
      const ['a'],
      onEof: () {
        calls++;
        throw customError;
      },
    );

    expect(await reader.recv(), 'a');
    await expectLater(reader.recv(), throwsA(same(customError)));
    for (var i = 0; i < 5; i++) {
      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));
    }
    expect(calls, 1);
    await reader.close();
  });
}
