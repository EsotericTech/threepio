// Port of eino `adk/middlewares/reduction/reduction_test.go` (v0.9.22), the
// middleware-level tests:
//   TestReductionMiddlewareTrunc, TestReductionMiddlewareClear,
//   TestStreamTruncationHelpers, TestReductionMiddlewareEnhancedTrunc,
//   TestClearRewriteMessagesHandler.
// The helper-level tests of the same Go file are in
// `eino_reduction_helpers_test.dart`.
//
// Not ported (sub-tests):
// * TestReductionMiddlewareTrunc / "test default streamable truncation
//   terminal cases" / "missing backend error is rendered in truncation
//   notice", and the same sub-test of "test default enhanced streamable
//   truncation terminal cases": Go calls the private
//   `wrapDefault(Enhanced)StreamableTruncation` with a hand-made
//   `ToolReductionConfig` that has no backend. The Dart counterparts are
//   private, and through the public wrappers the default streaming path only
//   runs with the middleware's default config, which always carries the
//   backend (the constructor requires one when truncation is on; so does
//   Go's `New`), so that branch is unreachable.
// * TestClearRewriteMessagesHandler / "test applyClearRewrite with default
//   role": the Dart `RoleType` is an enum without an unknown role (and the
//   message lies outside the cleared range anyway, so the Go test only checks
//   that nothing fails).
//
// Adapted (intended deviations):
// * The other "terminal cases" call the private Go wrappers directly; here
//   they go through `wrapStreamableToolCall` / `wrapEnhancedStreamableToolCall`
//   of a middleware whose default config is used (same path, same
//   `MaxLengthForTrunc`, `GenTruncOffloadFilePath` and backend).
// * `writeTruncOffload` is private in Dart; its three cases are exercised
//   through `wrapEnhancedInvokableToolCall` with a per-tool truncation handler.
// * Go's `adk.ModelContext{Tools: ...}` is deprecated and not ported; the Go
//   middleware counts `state.ToolInfos` (empty in these tests), as Dart does.
// * Messages are immutable: where Go checks the input slice that the clear
//   phase mutated in place ("test skip handled ones"), Dart checks the
//   returned state and feeds it to the second round.
// * Goroutines with channels and `time.After` become `Completer`s and
//   `pumpEventQueue` (no real timers).
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/internal/go_compat.dart';
import 'package:threepio_core/src/adk/middlewares/reduction/consts.dart';
import 'package:threepio_core/src/adk/middlewares/reduction/reduction.dart';

final ctx = RunContext.background();

final _s3 = '${'hello world' * 10}\n${'hello world' * 8}';

const _expOrigContent = 'hello worldhello worldhello worldhello worldhello worldhello worldhello '
    'worldhello worldhello worldhello world\n'
    'hello worldhello worldhello worldhello worldhello worldhello worldhello worldhello world';

OffloadFilePathGenerator _testTruncOffloadPath(String root) => (ctx, detail) {
      var callId = 'generated';
      if (detail.toolContext.callId.isNotEmpty) callId = detail.toolContext.callId;
      return '$root/trunc/$callId';
    };

OffloadFilePathGenerator _testClearOffloadPath(String root) => (ctx, detail) {
      var callId = 'generated';
      if (detail.toolContext.callId.isNotEmpty) callId = detail.toolContext.callId;
      return '$root/clear/$callId';
    };

StreamReader<String> _stringStream(List<String> chunks) {
  final (sr, sw) = pipe<String>(capacity: chunks.length);
  for (final chunk in chunks) {
    sw.send(chunk);
  }
  unawaited(sw.close());
  return sr;
}

StreamReader<String> _stringStreamWithError(List<String> chunks, Object error) {
  final (sr, sw) = pipe<String>(capacity: chunks.length + 1);
  for (final chunk in chunks) {
    sw.send(chunk);
  }
  sw.sendError(error);
  unawaited(sw.close());
  return sr;
}

StreamReader<ToolResult> _toolResultStream(List<ToolResult> chunks) {
  final (sr, sw) = pipe<ToolResult>(capacity: chunks.length);
  for (final chunk in chunks) {
    sw.send(chunk);
  }
  unawaited(sw.close());
  return sr;
}

StreamReader<ToolResult> _toolResultStreamWithError(List<ToolResult> chunks, Object error) {
  final (sr, sw) = pipe<ToolResult>(capacity: chunks.length + 1);
  for (final chunk in chunks) {
    sw.send(chunk);
  }
  sw.sendError(error);
  unawaited(sw.close());
  return sr;
}

ToolResult _text(String text) => ToolResult([ToolOutputPart(type: ToolPartType.text, text: text)]);

/// Port of the Go test's `splitStrings` (byte offsets; the inputs are ASCII).
List<String> _splitStrings(String s, int n) {
  if (n <= 0) n = 1;
  if (n == 1) return [s];
  if (s.length <= n) {
    final parts = List<String>.filled(n, '');
    for (var i = 0; i < s.length; i++) {
      parts[i] = s[i];
    }
    return parts;
  }
  final baseLen = s.length ~/ n;
  final extra = s.length % n;
  final parts = <String>[];
  var start = 0;
  for (var i = 0; i < n; i++) {
    var end = start + baseLen;
    if (i < extra) end++;
    parts.add(s.substring(start, end));
    start = end;
  }
  return parts;
}

/// Go's `json.Marshal`: map keys sorted.
String _toJson(Object? value) => jsonEncode(_sortKeys(value));

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final key in keys) key: _sortKeys(value[key])};
  }
  if (value is List) return [for (final item in value) _sortKeys(item)];
  return value;
}

/// The Go test's `strings.TrimPrefix(strings.TrimSpace(content), "1\t")`.
String _trimLineNumber(String content) {
  final trimmed = content.trim();
  return trimmed.startsWith('1\t') ? trimmed.substring(2) : trimmed;
}

Future<String> _read(FileReadBackend backend, String path) async =>
    (await backend.read(ctx, ReadRequest(filePath: path))).content;

ToolCall _tc(String id, String name, String arguments) =>
    ToolCall(id: id, type: 'function', function: FunctionCall(name: name, arguments: arguments));

Message _assistant(List<ToolCall> calls) => Message.assistant('', toolCalls: calls);

final _dummy = _assistant([_tc('dummy', 'dummy_tool', '')]);

/// Go's `mockInvokableTool` (`utils.InferTool` over `{value string}`).
final class _MockInvokableTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'mock_invokable_tool',
        desc: 'test desc',
        params: const {'value': ParameterInfo(type: DataType.string, required: true)},
      );

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async {
    jsonDecode(argumentsJson); // InferTool unmarshals the arguments first.
    return _s3;
  }
}

/// Go's `mockStreamableTool` / `mockStreamableToolWithError`.
final class _MockStreamableTool extends StreamableTool {
  _MockStreamableTool({this.withError = false});

  final bool withError;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'mock_streamable_tool',
        desc: 'test desc',
        params: const {'value': ParameterInfo(type: DataType.string, required: true)},
      );

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final (sr, sw) = pipe<String>(capacity: 11);
    for (final part in _splitStrings(_s3, 10)) {
      sw.send(part);
    }
    if (withError) sw.sendError(const ThreepioException('mock error'));
    unawaited(sw.close());
    return sr;
  }
}

/// Go's `writeFailBackend`.
final class _WriteFailBackend implements FileWriteBackend {
  _WriteFailBackend(this.error);

  final Object error;

  @override
  Future<void> write(RunContext ctx, WriteRequest request) async => throw error;
}

Matcher _threepioMessage(String message) =>
    isA<ThreepioException>().having((e) => e.message, 'message', message);

void main() {
  final mockInvokable = _MockInvokableTool();
  final mockStreamable = _MockStreamableTool();
  Future<String> it(RunContext ctx, String args, ToolOptions? options) =>
      mockInvokable.invokableRun(ctx, args, options: options);
  Future<StreamReader<String>> st(RunContext ctx, String args, ToolOptions? options) =>
      mockStreamable.streamableRun(ctx, args, options: options);

  group('TestReductionMiddlewareTrunc', () {
    test('test invokable max length trunc', () async {
      const tCtx = ToolContext(name: 'mock_invokable_tool', callId: '12345');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'mock_invokable_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: defaultTruncHandler(_testTruncOffloadPath('/tmp'), 70, 'read_file'),
          ),
        },
      );
      const exp = '<persisted-output>\nOutput too large (199). Full output saved to: /tmp/trunc/12345\n'
          'Preview (first 35):\nhello worldhello worldhello worldhe\n\n'
          'Preview (last 35):\nldhello worldhello worldhello world\n\n'
          'Use read_file to view\n</persisted-output>';

      final edp = mw.wrapInvokableToolCall(ctx, it, tCtx);
      final resp = await edp(ctx, '{"value":"asd"}', null);
      expect(resp, exp);
      expect(await _read(backend, '/tmp/trunc/12345'), _expOrigContent);
    });

    test('test default truncation notice includes configured read tool name', () async {
      const tCtx = ToolContext(name: 'mock_invokable_tool', callId: '12345');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        maxLengthForTrunc: 70,
        readFileToolName: 'cat_file',
      );

      final edp = mw.wrapInvokableToolCall(ctx, it, tCtx);
      final resp = await edp(ctx, '{"value":"asd"}', null);
      expect(resp, contains('Use cat_file to view'));
    });

    test('test streamable line and max length trunc', () async {
      const tCtx = ToolContext(name: 'mock_streamable_tool', callId: '54321');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        toolConfig: {
          'mock_streamable_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: defaultTruncHandler(_testTruncOffloadPath('/tmp'), 70, 'read_file'),
          ),
        },
      );
      const exp = '<persisted-output>\nOutput too large (199). Full output saved to: /tmp/trunc/54321\n'
          'Preview (first 35):\nhello worldhello worldhello worldhe\n\n'
          'Preview (last 35):\nldhello worldhello worldhello world\n\n'
          'Use read_file to view\n</persisted-output>';

      final edp = mw.wrapStreamableToolCall(ctx, st, tCtx);
      final resp = await edp(ctx, '{"value":"asd"}', null);
      final s = await resp.recv();
      await resp.close();
      expect(s, exp);
      expect(await _read(backend, '/tmp/trunc/54321'), _expOrigContent);
    });

    test('test streamable default truncation is nonblocking before source EOF', () async {
      const tCtx = ToolContext(name: 'mock_streamable_tool', callId: 'stream_nonblocking');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(backend: backend, maxLengthForTrunc: 30);

      final releaseOverflow = Completer<void>();
      final releaseEof = Completer<void>();
      Future<StreamReader<String>> endpoint(RunContext ctx, String args, ToolOptions? options) async {
        final (sr, sw) = pipe<String>();
        unawaited(() async {
          sw.send('first chunk');
          await releaseOverflow.future;
          sw.send('x' * 80);
          await releaseEof.future;
          await sw.close();
        }());
        return sr;
      }

      final edp = mw.wrapStreamableToolCall(ctx, endpoint, tCtx);

      StreamReader<String>? resp;
      Object? runError;
      unawaited(() async {
        try {
          resp = await edp(ctx, '{"value":"asd"}', null);
        } on Object catch (e) {
          runError = e;
        }
      }());
      await pumpEventQueue();
      if (runError != null) {
        releaseEof.complete();
        fail('unexpected error: $runError');
      }
      if (resp == null) {
        releaseEof.complete();
        fail('streamable truncation wrapper blocked until source EOF');
      }
      final reader = resp!;
      addTearDown(reader.close);

      expect(await reader.recv(), 'first chunk');

      releaseOverflow.complete();
      String? notice;
      Object? noticeError;
      unawaited(() async {
        try {
          notice = await reader.recv();
        } on Object catch (e) {
          noticeError = e;
        }
      }());
      await pumpEventQueue();
      if (notice != null) {
        releaseEof.complete();
        fail('streamable truncation notice returned before source EOF: got "$notice"');
      }
      if (noticeError != null) {
        releaseEof.complete();
        fail('unexpected error: $noticeError');
      }

      releaseEof.complete();
      await pumpEventQueue(times: 50);
      expect(noticeError, isNull);
      expect(notice, isNotNull, reason: 'streamable truncation notice blocked after source EOF');
      final remaining = notice!;
      expect(remaining, contains('Output truncated after'));
      expect(remaining, isNot(contains('Preview (first')));
      expect(remaining, isNot(contains('Preview (last')));
      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));

      expect(await _read(backend, '/tmp/trunc/stream_nonblocking'), 'first chunk${'x' * 80}');
    });

    test('test enhanced streamable default truncation is nonblocking before source EOF', () async {
      const tCtx = ToolContext(name: 'mock_enhanced_streamable_tool', callId: 'enhanced_stream_nonblocking');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(backend: backend, maxLengthForTrunc: 30);

      final releaseOverflow = Completer<void>();
      final releaseEof = Completer<void>();
      Future<StreamReader<ToolResult>> endpoint(
        RunContext ctx,
        ToolArgument argument,
        ToolOptions? options,
      ) async {
        final (sr, sw) = pipe<ToolResult>();
        unawaited(() async {
          sw.send(_text('first chunk'));
          await releaseOverflow.future;
          sw.send(_text('x' * 80));
          await releaseEof.future;
          await sw.close();
        }());
        return sr;
      }

      final edp = mw.wrapEnhancedStreamableToolCall(ctx, endpoint, tCtx);

      StreamReader<ToolResult>? resp;
      Object? runError;
      unawaited(() async {
        try {
          resp = await edp(ctx, const ToolArgument('{"value":"asd"}'), null);
        } on Object catch (e) {
          runError = e;
        }
      }());
      await pumpEventQueue();
      if (runError != null) {
        releaseEof.complete();
        fail('unexpected error: $runError');
      }
      if (resp == null) {
        releaseEof.complete();
        fail('enhanced streamable truncation wrapper blocked until source EOF');
      }
      final reader = resp!;
      addTearDown(reader.close);

      final first = await reader.recv();
      expect(first.parts[0].text, 'first chunk');

      releaseOverflow.complete();
      String? notice;
      Object? noticeError;
      unawaited(() async {
        try {
          final chunk = await reader.recv();
          notice = stringifyToolOutputParts(chunk.parts);
        } on Object catch (e) {
          noticeError = e;
        }
      }());
      await pumpEventQueue();
      if (notice != null) {
        releaseEof.complete();
        fail('enhanced streamable truncation notice returned before source EOF: got "$notice"');
      }
      if (noticeError != null) {
        releaseEof.complete();
        fail('unexpected error: $noticeError');
      }

      releaseEof.complete();
      await pumpEventQueue(times: 50);
      expect(noticeError, isNull);
      expect(notice, isNotNull, reason: 'enhanced streamable truncation notice blocked after source EOF');
      final remaining = notice!;
      expect(remaining, contains('Output truncated after'));
      expect(remaining, isNot(contains('Preview (first')));
      expect(remaining, isNot(contains('Preview (last')));
      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));

      final content = await _read(backend, '/tmp/trunc/enhanced_stream_nonblocking');
      expect(content, contains('"text": "first chunk"'));
      expect(content, contains('"text": "${'x' * 80}"'));
    });

    group('test default streamable truncation terminal cases', () {
      // Go calls the private wrapDefaultStreamableTruncation with a
      // hand-made cfg; here it is reached through wrapStreamableToolCall of a
      // middleware whose default config is used (see the file comment).
      const tCtx = ToolContext(name: 'mock_streamable_tool', callId: 'stream_branches');
      late InMemoryBackend backend;
      setUp(() => backend = InMemoryBackend());

      Future<StreamReader<String>> run(
        StreamReader<String> source, {
        FileWriteBackend? withBackend,
        OffloadFilePathGenerator? gen,
        String readFileToolName = '',
      }) {
        final mw = ToolReductionMiddleware(
          backend: withBackend ?? backend,
          maxLengthForTrunc: 10,
          genTruncOffloadFilePath: gen ?? _testTruncOffloadPath('/tmp'),
          readFileToolName: readFileToolName,
        );
        final edp = mw.wrapStreamableToolCall(ctx, (ctx, args, options) async => source, tCtx);
        return edp(ctx, '{}', null);
      }

      test('short output forwards and does not truncate', () async {
        final resp = await run(_stringStream(['short']));
        addTearDown(resp.close);

        expect(await resp.recv(), 'short');
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('source error is forwarded', () async {
        const wantErr = ThreepioException('source stream error');
        final resp = await run(_stringStreamWithError(['ok'], wantErr));
        addTearDown(resp.close);

        expect(await resp.recv(), 'ok');
        await expectLater(resp.recv(), throwsA(same(wantErr)));
      });

      test('path generation error is rendered in truncation notice', () async {
        const wantErr = ThreepioException('path generation error');
        final resp = await run(
          _stringStream(['x' * 20]),
          gen: (ctx, detail) => throw wantErr,
        );
        addTearDown(resp.close);

        final got = await resp.recv();
        expect(got, contains('x' * 10));
        expect(got, contains('Output truncated after 10 bytes were streamed'));
        expect(got, contains('Failed to save full output: path generation error.'));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      // "missing backend error is rendered in truncation notice": not
      // portable (see the file comment).

      test('truncates on source EOF and writes full output', () async {
        final resp = await run(_stringStream(['x' * 20, 'tail']));
        addTearDown(resp.close);

        final got = await resp.recv();
        expect(got, contains('x' * 10));
        expect(got, contains('Output truncated after 10 bytes were streamed'));
        expect(got, contains('Full output saved to: /tmp/trunc/stream_branches.'));
        expect(got, isNot(contains('Preview (first')));
        expect(got, isNot(contains('Preview (last')));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));

        expect(await _read(backend, '/tmp/trunc/stream_branches'), '${'x' * 20}tail');
      });

      test('truncation notice includes configured read tool name', () async {
        final resp = await run(_stringStream(['x' * 20]), readFileToolName: 'cat_file');
        addTearDown(resp.close);

        expect(await resp.recv(), contains('Use cat_file to view'));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('write error is rendered in truncation notice after source EOF', () async {
        const wantErr = ThreepioException('stream write error');
        final resp = await run(_stringStream(['x' * 20]), withBackend: _WriteFailBackend(wantErr));
        addTearDown(resp.close);

        final got = await resp.recv();
        expect(got, contains('x' * 10));
        expect(got, contains('Output truncated after 10 bytes were streamed'));
        expect(got, contains('Failed to save full output: stream write error.'));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('source error after truncation replays swallowed chunks before error', () async {
        const wantErr = ThreepioException('stream source error after truncation');
        final resp = await run(_stringStreamWithError(['abc', 'defghijklmnop', 'tail'], wantErr));
        addTearDown(resp.close);

        expect(await resp.recv(), 'abc');
        expect(await resp.recv(), 'defghijklmnoptail');
        await expectLater(resp.recv(), throwsA(same(wantErr)));
      });
    });

    group('test default enhanced streamable truncation terminal cases', () {
      // Through wrapEnhancedStreamableToolCall (see the file comment).
      const tCtx = ToolContext(name: 'mock_enhanced_streamable_tool', callId: 'enhanced_stream_branches');
      const toolArg = ToolArgument('{}');
      late InMemoryBackend backend;
      setUp(() => backend = InMemoryBackend());
      final longResult = _text('x' * 20);
      const audioA = 'YXVkaW8x';
      const audioB = 'YXVkaW8y';
      ToolOutputPart audio(String data) => ToolOutputPart(
            type: ToolPartType.audio,
            audio: ToolOutputAudio(common: MessagePartCommon(base64Data: data)),
          );

      Future<StreamReader<ToolResult>> run(
        StreamReader<ToolResult> source, {
        FileWriteBackend? withBackend,
        OffloadFilePathGenerator? gen,
        String readFileToolName = '',
      }) {
        final mw = ToolReductionMiddleware(
          backend: withBackend ?? backend,
          maxLengthForTrunc: 10,
          genTruncOffloadFilePath: gen ?? _testTruncOffloadPath('/tmp'),
          readFileToolName: readFileToolName,
        );
        final edp = mw.wrapEnhancedStreamableToolCall(ctx, (ctx, arg, options) async => source, tCtx);
        return edp(ctx, toolArg, null);
      }

      test('short output forwards and does not truncate', () async {
        final resp = await run(_toolResultStream([_text('short')]));
        addTearDown(resp.close);

        expect((await resp.recv()).parts[0].text, 'short');
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('source error is forwarded', () async {
        const wantErr = ThreepioException('enhanced source stream error');
        final resp = await run(_toolResultStreamWithError([_text('ok')], wantErr));
        addTearDown(resp.close);

        expect((await resp.recv()).parts[0].text, 'ok');
        await expectLater(resp.recv(), throwsA(same(wantErr)));
      });

      test('conflicting media parts do not prevent truncation notice', () async {
        final resp = await run(_toolResultStream([
          ToolResult([ToolOutputPart(type: ToolPartType.text, text: 'x' * 20), audio(audioA)]),
          ToolResult([audio(audioB)]),
        ]));
        addTearDown(resp.close);

        final got = await resp.recv();
        expect(got.parts[0].text, 'x' * 10);
        expect(stringifyToolOutputParts(got.parts), contains('Output truncated after 10 bytes were streamed'));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('conflicting media parts after forwarded chunk do not prevent truncation notice', () async {
        final resp = await run(_toolResultStream([
          ToolResult([ToolOutputPart(type: ToolPartType.text, text: 'ok'), audio(audioA)]),
          ToolResult([ToolOutputPart(type: ToolPartType.text, text: 'x' * 20), audio(audioB)]),
        ]));
        addTearDown(resp.close);

        expect((await resp.recv()).parts[0].text, 'ok');
        final notice = await resp.recv();
        expect(notice.parts[0].text, 'x' * 8);
        expect(stringifyToolOutputParts(notice.parts), contains('Output truncated after 10 bytes were streamed'));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('path generation error is rendered in truncation notice', () async {
        const wantErr = ThreepioException('enhanced path generation error');
        final resp = await run(_toolResultStream([longResult]), gen: (ctx, detail) => throw wantErr);
        addTearDown(resp.close);

        final got = await resp.recv();
        expect(got.parts[0].text, 'x' * 10);
        expect(stringifyToolOutputParts(got.parts), contains('Output truncated after 10 bytes were streamed'));
        expect(
          stringifyToolOutputParts(got.parts),
          contains('Failed to save full output: enhanced path generation error.'),
        );
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      // "missing backend error is rendered in truncation notice": not
      // portable (see the file comment).

      test('truncates on source EOF and writes full output', () async {
        final resp = await run(_toolResultStream([longResult, _text('tail')]));
        addTearDown(resp.close);

        final got = await resp.recv();
        expect(got.parts[0].text, 'x' * 10);
        final gotText = stringifyToolOutputParts(got.parts);
        expect(gotText, contains('Output truncated after 10 bytes were streamed'));
        expect(gotText, contains('Full output saved to: /tmp/trunc/enhanced_stream_branches.'));
        expect(gotText, isNot(contains('Preview (first')));
        expect(gotText, isNot(contains('Preview (last')));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));

        final content = await _read(backend, '/tmp/trunc/enhanced_stream_branches');
        expect(content, contains('"text": "${'x' * 20}"'));
        expect(content, contains('"text": "tail"'));
      });

      test('truncation notice includes configured read tool name', () async {
        final resp = await run(_toolResultStream([longResult]), readFileToolName: 'cat_file');
        addTearDown(resp.close);

        expect(stringifyToolOutputParts((await resp.recv()).parts), contains('Use cat_file to view'));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('write error is rendered in truncation notice after source EOF', () async {
        const wantErr = ThreepioException('enhanced write error');
        final resp = await run(_toolResultStream([longResult]), withBackend: _WriteFailBackend(wantErr));
        addTearDown(resp.close);

        final got = await resp.recv();
        expect(got.parts[0].text, 'x' * 10);
        expect(stringifyToolOutputParts(got.parts), contains('Output truncated after 10 bytes were streamed'));
        expect(stringifyToolOutputParts(got.parts), contains('Failed to save full output: enhanced write error.'));
        await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));
      });

      test('source error after truncation replays swallowed chunks before error', () async {
        const wantErr = ThreepioException('enhanced source stream error after truncation');
        final resp = await run(_toolResultStreamWithError(
          [_text('abc'), _text('defghijklmnop'), _text('tail')],
          wantErr,
        ));
        addTearDown(resp.close);

        expect((await resp.recv()).parts[0].text, 'abc');
        final replayed = await resp.recv();
        expect(replayed.parts[0].text, 'defghijklmnop');
        expect(replayed.parts[1].text, 'tail');
        await expectLater(resp.recv(), throwsA(same(wantErr)));
      });
    });

    test('test streamable line and bypass error', () async {
      final stWithErr = _MockStreamableTool(withError: true);
      const tCtx = ToolContext(name: 'mock_streamable_tool', callId: '54321');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        toolConfig: {
          'mock_streamable_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: defaultTruncHandler(_testTruncOffloadPath('/tmp'), 70, 'read_file'),
          ),
        },
      );
      final edp = mw.wrapStreamableToolCall(
        ctx,
        (ctx, args, options) => stWithErr.streamableRun(ctx, args, options: options),
        tCtx,
      );
      final resp = await edp(ctx, '{"value":"asd"}', null);
      addTearDown(resp.close);
      var cnt = 0;
      var gotError = false;
      for (var guard = 0; guard < 100; guard++) {
        try {
          await resp.recv();
        } on StreamEOFException {
          break;
        } on Object catch (e) {
          expect(e, _threepioMessage('mock error'));
          gotError = true;
          break;
        }
        cnt++;
      }
      expect(gotError, isTrue);
      expect(cnt, 10);
    });

    test('test TruncExcludeTools with invokable tool', () async {
      const tCtx = ToolContext(name: 'important_tool', callId: '12345');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        truncExcludeTools: ['important_tool'],
        maxLengthForTrunc: 70,
      );

      final edp = mw.wrapInvokableToolCall(ctx, it, tCtx);
      final resp = await edp(ctx, '{"value":"asd"}', null);
      expect(resp, _expOrigContent);

      await expectLater(_read(backend, '/tmp/trunc/12345'), throwsA(isA<ThreepioException>()));
    });

    test('test TruncExcludeTools with streamable tool', () async {
      const tCtx = ToolContext(name: 'important_stream_tool', callId: '54321');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        truncExcludeTools: ['important_stream_tool'],
        maxLengthForTrunc: 70,
      );

      final edp = mw.wrapStreamableToolCall(ctx, st, tCtx);
      final resp = await edp(ctx, '{"value":"asd"}', null);
      final fullOutput = StringBuffer();
      for (var guard = 0; guard < 100; guard++) {
        try {
          fullOutput.write(await resp.recv());
        } on StreamEOFException {
          break;
        }
      }
      await resp.close();

      expect(fullOutput.toString(), _expOrigContent);
      await expectLater(_read(backend, '/tmp/trunc/54321'), throwsA(isA<ThreepioException>()));
    });

    test('test mixed tools with TruncExcludeTools', () async {
      const excludedToolCtx = ToolContext(name: 'excluded_tool', callId: 'excluded_123');
      const normalToolCtx = ToolContext(name: 'normal_tool', callId: 'normal_456');
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        truncExcludeTools: ['excluded_tool'],
        maxLengthForTrunc: 70,
      );

      final excludedEdp = mw.wrapInvokableToolCall(ctx, it, excludedToolCtx);
      final excludedResp = await excludedEdp(ctx, '{"value":"asd"}', null);
      expect(excludedResp, _expOrigContent);

      final normalEdp = mw.wrapInvokableToolCall(ctx, it, normalToolCtx);
      final normalResp = await normalEdp(ctx, '{"value":"asd"}', null);
      expect(normalResp, isNot(_expOrigContent));
      expect(normalResp, contains('persisted-output'));

      expect(await _read(backend, '/tmp/trunc/normal_456'), _expOrigContent);
    });

    test('test GenTruncOffloadFilePath used by default trunc handler', () async {
      const tCtx = ToolContext(name: 'mock_invokable_tool', callId: 'custom_123');
      final backend = InMemoryBackend();
      final seenCallIds = <String>[];
      final mw = ToolReductionMiddleware(
        backend: backend,
        maxLengthForTrunc: 70,
        rootDir: '/tmp/ignored',
        genTruncOffloadFilePath: (ctx, detail) {
          seenCallIds.add(detail.toolContext.callId);
          return '/custom/trunc/custom_123';
        },
      );

      final edp = mw.wrapInvokableToolCall(ctx, it, tCtx);
      final resp = await edp(ctx, '{"value":"asd"}', null);
      expect(resp, contains('/custom/trunc/custom_123'));
      expect(seenCallIds, everyElement('custom_123'));
      expect(seenCallIds, isNotEmpty);

      await _read(backend, '/custom/trunc/custom_123');
    });
  });

  group('TestReductionMiddlewareClear', () {
    // Go passes `&adk.ModelContext{Tools: toolsInfo}`: deprecated, not
    // ported, and not what the middleware counts (it counts
    // state.ToolInfos, empty here).
    const weatherArgs = '{"location": "London, UK", "unit": "c"}';
    const userText = "If it's warmer than 20°C in London, set the thermostat to 20°C, otherwise set it to 18°C.";

    List<Message> twoWeatherRounds() => [
          Message.system('you are a helpful assistant'),
          Message.user(userText),
          _assistant([_tc('call_987654321', 'get_weather', weatherArgs)]),
          Message.tool(content: 'Sunny', toolCallId: 'call_987654321'),
          _assistant([_tc('call_123456789', 'get_weather', weatherArgs)]),
          Message.tool(content: 'Sunny', toolCallId: 'call_123456789'),
        ];

    test('test default clear', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: defaultReductionTokenCount,
        maxTokensForClear: 20,
        clearRetentionSuffixLimit: 0,
        toolConfig: {
          'get_weather': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
        },
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: twoWeatherRounds()),
        const ModelContext(),
      );
      expect(s.messages[2].toolCalls, [_tc('call_987654321', 'get_weather', weatherArgs)]);
      expect(s.messages[4].toolCalls, [_tc('call_123456789', 'get_weather', weatherArgs)]);
      expect(
        s.messages[3].content,
        '<persisted-output>Tool result saved to: /tmp/clear/call_987654321\nUse read_file to view</persisted-output>',
      );
      expect(_trimLineNumber(await _read(backend, '/tmp/clear/call_987654321')), 'Sunny');
    });

    test('test GenClearOffloadFilePath used by default clear handler', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        skipTruncation: true,
        tokenCounter: (ctx, messages, tools) => 100,
        maxTokensForClear: 20,
        clearRetentionSuffixLimit: 1,
        rootDir: '/tmp/ignored',
        genClearOffloadFilePath: (ctx, detail) => '/custom/clear/${detail.toolContext.callId}',
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('trigger clear'),
          _assistant([_tc('call_a', 'get_weather', '{}')]),
          Message.tool(content: 'Sunny', toolCallId: 'call_a'),
          _assistant([_tc('call_b', 'get_weather', '{}')]),
          Message.tool(content: 'Sunny', toolCallId: 'call_b'),
        ]),
        const ModelContext(),
      );

      expect(
        s.messages[3].content,
        '<persisted-output>Tool result saved to: /custom/clear/call_a\nUse read_file to view</persisted-output>',
      );
      expect(_trimLineNumber(await _read(backend, '/custom/clear/call_a')), 'Sunny');
    });

    test('test default clear without offloading', () async {
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: defaultReductionTokenCount,
        maxTokensForClear: 20,
        clearRetentionSuffixLimit: 0,
        toolConfig: {
          'get_weather': ToolReductionConfig(
            clearHandler: defaultClearHandler(_testClearOffloadPath(''), false, ''),
          ),
        },
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: twoWeatherRounds()),
        const ModelContext(),
      );
      expect(s.messages[2].toolCalls, [_tc('call_987654321', 'get_weather', weatherArgs)]);
      expect(s.messages[4].toolCalls, [_tc('call_123456789', 'get_weather', weatherArgs)]);
      expect(s.messages[3].content, '[Old tool result content cleared]');
    });

    test('test clear with reordered tool results', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: defaultReductionTokenCount,
        maxTokensForClear: 20,
        clearRetentionSuffixLimit: 0,
        toolConfig: {
          'get_weather': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
        },
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('get weather for two cities'),
          // Assistant message with two tool calls
          _assistant([
            _tc('two_call_one', 'get_weather', '{"location": "London"}'),
            _tc('two_call_two', 'get_weather', '{"location": "Paris"}'),
          ]),
          // Intentionally put tool result two BEFORE tool result one
          Message.tool(content: 'Cloudy in Paris', toolCallId: 'two_call_two'),
          Message.tool(content: 'Sunny in London', toolCallId: 'two_call_one'),
          _dummy,
        ]),
        const ModelContext(),
      );

      // Verify tool call arguments are preserved (not offloaded since offload is true)
      expect(s.messages[2].toolCalls![0].function.arguments, '{"location": "London"}');
      expect(s.messages[2].toolCalls![1].function.arguments, '{"location": "Paris"}');

      // Verify tool result two is correctly matched and offloaded (it's at index 3)
      expect(
        s.messages[3].content,
        '<persisted-output>Tool result saved to: /tmp/clear/two_call_two\nUse read_file to view</persisted-output>',
      );
      expect(_trimLineNumber(await _read(backend, '/tmp/clear/two_call_two')), 'Cloudy in Paris');

      // Verify tool result one is correctly matched and offloaded (it's at index 4)
      expect(
        s.messages[4].content,
        '<persisted-output>Tool result saved to: /tmp/clear/two_call_one\nUse read_file to view</persisted-output>',
      );
      expect(_trimLineNumber(await _read(backend, '/tmp/clear/two_call_one')), 'Sunny in London');
    });

    test('test clear', () async {
      final backend = InMemoryBackend();
      Future<ClearResult> handler(RunContext ctx, ToolDetail detail) async {
        final arguments =
            (jsonDecode(detail.toolArgument.text) as Map<String, dynamic>).cast<String, String>();
        final offloadContent = {'arguments': arguments, 'result': detail.toolResult!.parts[0].text};
        final filePath = '/tmp/${detail.toolContext.callId}';
        final replacedArguments = {for (final k in arguments.keys) k: 'argument offloaded'};
        return ClearResult(
          toolArgument: ToolArgument(_toJson(replacedArguments)),
          toolResult: ToolResult([
            ToolOutputPart(type: ToolPartType.text, text: 'result offloaded, retrieve it from $filePath'),
          ]),
          needClear: true,
          needOffload: true,
          offloadFilePath: filePath,
          offloadContent: _toJson(offloadContent),
        );
      }

      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: defaultReductionTokenCount,
        maxTokensForClear: 20,
        clearRetentionSuffixLimit: 1,
        toolConfig: {
          'get_weather': ToolReductionConfig(backend: backend, clearHandler: handler),
        },
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: twoWeatherRounds()),
        const ModelContext(),
      );
      expect(s.messages[2].toolCalls, [
        _tc('call_987654321', 'get_weather', '{"location":"argument offloaded","unit":"argument offloaded"}'),
      ]);
      expect(s.messages[4].toolCalls, [_tc('call_123456789', 'get_weather', weatherArgs)]);
      expect(s.messages[3].content, 'result offloaded, retrieve it from /tmp/call_987654321');
      final fileContentStr = _trimLineNumber(await _read(backend, '/tmp/call_987654321'));
      expect(jsonDecode(fileContentStr), {
        'arguments': {'location': 'London, UK', 'unit': 'c'},
        'result': 'Sunny',
      });
    });

    test('test skip handled ones', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: defaultReductionTokenCount,
        maxTokensForClear: 20,
        clearRetentionSuffixLimit: 0,
        toolConfig: {
          'get_weather': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
        },
      );
      var msgs = twoWeatherRounds();
      var (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: msgs),
        const ModelContext(),
      );
      expect(s.messages[2].toolCalls, [_tc('call_987654321', 'get_weather', weatherArgs)]);
      // Go checks the input message, which the clear mutated in place; Dart
      // messages are immutable, so the returned one carries the flag and is
      // what the next round starts from.
      expect(s.messages[2].extra?[msgClearedFlag], isNotNull);
      expect(s.messages[4].toolCalls, [_tc('call_123456789', 'get_weather', weatherArgs)]);
      expect(
        s.messages[3].content,
        '<persisted-output>Tool result saved to: /tmp/clear/call_987654321\nUse read_file to view</persisted-output>',
      );
      expect(_trimLineNumber(await _read(backend, '/tmp/clear/call_987654321')), 'Sunny');

      msgs = [
        ...s.messages,
        _assistant([_tc('call_8877665544', 'get_weather', weatherArgs)]),
        Message.tool(content: 'Sunny', toolCallId: 'call_8877665544'),
      ];
      (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: msgs),
        const ModelContext(),
      );
      expect(s.messages[2].toolCalls, [_tc('call_987654321', 'get_weather', weatherArgs)]);
      expect(s.messages[2].extra?[msgClearedFlag], isNotNull);
      expect(s.messages[4].toolCalls, [_tc('call_123456789', 'get_weather', weatherArgs)]);
      expect(s.messages[4].extra?[msgClearedFlag], isNotNull);
      expect(
        s.messages[3].content,
        '<persisted-output>Tool result saved to: /tmp/clear/call_987654321\nUse read_file to view</persisted-output>',
      );
      expect(
        s.messages[5].content,
        '<persisted-output>Tool result saved to: /tmp/clear/call_123456789\nUse read_file to view</persisted-output>',
      );
    });

    test('test ClearExcludeTools', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: defaultReductionTokenCount,
        maxTokensForClear: 20,
        clearRetentionSuffixLimit: 0,
        clearExcludeTools: ['get_important_data'],
        toolConfig: {
          'get_weather': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
          'get_important_data': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
        },
      );
      final msgs = [
        Message.system('you are a helpful assistant'),
        Message.user(userText),
        _assistant([_tc('call_987654321', 'get_weather', weatherArgs)]),
        Message.tool(content: 'Sunny', toolCallId: 'call_987654321'),
        _assistant([_tc('call_123456789', 'get_important_data', '{"id": "123"}')]),
        Message.tool(content: 'Important Data Content', toolCallId: 'call_123456789'),
        _assistant([_tc('call_999', 'get_weather', weatherArgs)]),
        Message.tool(content: 'Sunny', toolCallId: 'call_999'),
      ];
      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: msgs),
        const ModelContext(),
      );
      expect(
        s.messages[3].content,
        '<persisted-output>Tool result saved to: /tmp/clear/call_987654321\nUse read_file to view</persisted-output>',
      );
      expect(s.messages[5].content, 'Important Data Content');
      expect(await _read(backend, '/tmp/clear/call_987654321'), 'Sunny');
      await expectLater(
        _read(backend, '/tmp/clear/call_123456789'),
        throwsA(_threepioMessage('file not found: /tmp/clear/call_123456789')),
      );
    });

    int sizeCounter(RunContext ctx, List<Message> msgs, List<ToolInfo> tools) {
      var size = 0;
      for (final msg in msgs) {
        size += utf8Length(msg.content);
        for (final tc in msg.toolCalls ?? const <ToolCall>[]) {
          size += utf8Length(tc.function.name);
          size += utf8Length(tc.function.arguments);
        }
      }
      return size;
    }

    const sunny13 = 'Sunny Sunny Sunny Sunny Sunny Sunny Sunny Sunny Sunny Sunny Sunny Sunny Sunny';
    const important = 'Important Data Content, qweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqwe'
        'qweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqweqwe';

    test('test ClearAtLeastTokens - not enough tokens cleared', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: sizeCounter,
        maxTokensForClear: 50,
        clearRetentionSuffixLimit: 1,
        clearAtLeastTokens: 100,
        toolConfig: {
          'get_weather': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
          'get_important_data': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
        },
      );
      final msgs = [
        Message.system('you are a helpful assistant'),
        Message.user(userText),
        _assistant([_tc('call_987654321', 'get_weather', weatherArgs)]),
        Message.tool(content: sunny13, toolCallId: 'call_123456789'),
        _assistant([_tc('call_123456789', 'get_important_data', '{"id": "123"}')]),
        Message.tool(content: important, toolCallId: 'call_123456789'),
        _assistant([_tc('call_999', 'get_weather', weatherArgs)]),
        Message.tool(content: 'Sunny', toolCallId: 'call_999'),
      ];
      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: msgs),
        const ModelContext(),
      );
      expect(s.messages[3].content, sunny13);
      expect(s.messages[5].content, important);
      await expectLater(_read(backend, '/tmp/clear/call_987654321'), throwsA(isA<ThreepioException>()));
    });

    test('test ClearAtLeastTokens - enough tokens cleared', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: sizeCounter,
        maxTokensForClear: 50,
        clearRetentionSuffixLimit: 1,
        clearAtLeastTokens: 10,
        toolConfig: {
          'get_weather': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
          'get_important_data': ToolReductionConfig(
            backend: backend,
            clearHandler: defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file'),
          ),
        },
      );
      final msgs = [
        Message.system('you are a helpful assistant'),
        Message.user(userText),
        _assistant([_tc('call_987654321', 'get_weather', weatherArgs)]),
        Message.tool(content: sunny13, toolCallId: 'call_987654321'),
        _assistant([_tc('call_123456789', 'get_important_data', '{"id": "123"}')]),
        Message.tool(content: important, toolCallId: 'call_123456789'),
        _assistant([_tc('call_999', 'get_weather', weatherArgs)]),
        Message.tool(content: 'Sunny', toolCallId: 'call_999'),
      ];
      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: msgs),
        const ModelContext(),
      );
      expect(
        s.messages[3].content,
        '<persisted-output>Tool result saved to: /tmp/clear/call_987654321\nUse read_file to view</persisted-output>',
      );
      await _read(backend, '/tmp/clear/call_987654321');
      expect(
        s.messages[5].content,
        '<persisted-output>Tool result saved to: /tmp/clear/call_123456789\nUse read_file to view</persisted-output>',
      );
      // Go reads /tmp/clear/call_987654321 a second time here (kept as is).
      await _read(backend, '/tmp/clear/call_987654321');
    });
  });

  group('TestStreamTruncationHelpers', () {
    test('toolResultTextPrefix trims text and preserves leading non-text parts', () {
      expect(toolResultTextPrefix(null, 10), isNull);
      expect(toolResultTextPrefix(const ToolResult(), 10), isNull);
      expect(toolResultTextPrefix(_text('abc'), 0), isNull);

      var got = toolResultTextPrefix(
        ToolResult([
          const ToolOutputPart(type: ToolPartType.image),
          const ToolOutputPart(type: ToolPartType.text, text: 'abc'),
          const ToolOutputPart(type: ToolPartType.text, text: 'def'),
        ]),
        5,
      );
      expect(got, isNotNull);
      expect(got!.parts, [
        const ToolOutputPart(type: ToolPartType.image),
        const ToolOutputPart(type: ToolPartType.text, text: 'abc'),
        const ToolOutputPart(type: ToolPartType.text, text: 'de'),
      ]);

      got = toolResultTextPrefix(
        ToolResult([
          const ToolOutputPart(type: ToolPartType.text, text: 'abc'),
          const ToolOutputPart(type: ToolPartType.text, text: 'def'),
        ]),
        3,
      );
      expect(got, isNotNull);
      expect(got!.parts, [const ToolOutputPart(type: ToolPartType.text, text: 'abc')]);
    });

    test('toolResultTextLength handles nil result', () {
      expect(toolResultTextLength(null), 0);
    });

    test('writeTruncOffload handles disabled missing and successful offload', () async {
      // writeTruncOffload is private in Dart: each case runs through
      // wrapEnhancedInvokableToolCall with a per-tool handler returning the
      // TruncResult (with needTrunc and a result, so that the wrapper gets to
      // the offload step).
      Future<void> writeTruncOffload(FileWriteBackend? backend, TruncResult truncResult) async {
        final mw = ToolReductionMiddleware(
          skipTruncation: true,
          toolConfig: {
            'helper_tool': ToolReductionConfig(backend: backend, truncHandler: (ctx, detail) => truncResult),
          },
        );
        final edp = mw.wrapEnhancedInvokableToolCall(
          ctx,
          (ctx, argument, options) async => _text('orig'),
          const ToolContext(name: 'helper_tool', callId: 'helper'),
        );
        await edp(ctx, const ToolArgument('{}'), null);
      }

      await writeTruncOffload(null, TruncResult(needTrunc: true, toolResult: _text('t')));

      await expectLater(
        writeTruncOffload(null, TruncResult(needTrunc: true, needOffload: true, toolResult: _text('t'))),
        throwsA(_threepioMessage('truncation: no backend for offload')),
      );

      final backend = InMemoryBackend();
      await writeTruncOffload(
        backend,
        TruncResult(
          needTrunc: true,
          toolResult: _text('t'),
          needOffload: true,
          offloadFilePath: '/tmp/trunc/helper',
          offloadContent: 'full output',
        ),
      );
      expect(await _read(backend, '/tmp/trunc/helper'), 'full output');
    });
  });

  group('TestReductionMiddlewareEnhancedTrunc', () {
    const tCtx = ToolContext(name: 'enh_tool', callId: 'cid');
    const toolArg = ToolArgument('{"k":"v"}');

    test('enhanced invokable - passthrough when truncation skipped', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(backend: backend, skipTruncation: true);

      var called = 0;
      final seenSame = <bool>[];
      Future<ToolResult> endpoint(RunContext ctx, ToolArgument ta, ToolOptions? options) async {
        called++;
        seenSame.add(identical(ta, toolArg));
        return _text('ok');
      }

      final wrapped = mw.wrapEnhancedInvokableToolCall(ctx, endpoint, tCtx);
      final got = await wrapped(ctx, toolArg, null);
      expect(called, 1);
      expect(seenSame, [true]);
      expect(got.parts[0].text, 'ok');
    });

    test('enhanced invokable - excluded tool bypasses truncation', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        truncExcludeTools: ['enh_tool'],
        toolConfig: {
          'enh_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: (ctx, detail) => fail('trunc handler should not be called when tool is excluded'),
          ),
        },
      );

      final wrapped = mw.wrapEnhancedInvokableToolCall(ctx, (ctx, ta, options) async => _text('orig'), tCtx);
      final got = await wrapped(ctx, toolArg, null);
      expect(got.parts[0].text, 'orig');
    });

    test('enhanced invokable - endpoint error returned', () async {
      final backend = InMemoryBackend();
      const wantErr = ThreepioException('endpoint error');
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: (ctx, detail) => fail('trunc handler should not be called on endpoint error'),
          ),
        },
      );

      final wrapped = mw.wrapEnhancedInvokableToolCall(ctx, (ctx, ta, options) async => throw wantErr, tCtx);
      await expectLater(wrapped(ctx, toolArg, null), throwsA(same(wantErr)));
    });

    test('enhanced invokable - trunc handler error returned', () async {
      final backend = InMemoryBackend();
      const wantErr = ThreepioException('handler error');
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_tool': ToolReductionConfig(backend: backend, truncHandler: (ctx, detail) => throw wantErr),
        },
      );

      final wrapped = mw.wrapEnhancedInvokableToolCall(ctx, (ctx, ta, options) async => _text('orig'), tCtx);
      await expectLater(wrapped(ctx, toolArg, null), throwsA(same(wantErr)));
    });

    test('enhanced invokable - no trunc returns original result', () async {
      final backend = InMemoryBackend();
      final seen = <String?>[];
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: (ctx, detail) {
              seen.add(detail.toolResult?.parts[0].text);
              return const TruncResult(needTrunc: false);
            },
          ),
        },
      );

      final wrapped = mw.wrapEnhancedInvokableToolCall(ctx, (ctx, ta, options) async => _text('orig'), tCtx);
      final got = await wrapped(ctx, toolArg, null);
      expect(seen, ['orig']);
      expect(got.parts[0].text, 'orig');
    });

    test('enhanced invokable - offload without backend returns error', () async {
      // config.Backend must be non-nil to pass New(), but the per-tool cfg.Backend is nil.
      final configBackend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: configBackend,
        toolConfig: {
          'enh_tool': ToolReductionConfig(
            truncHandler: (ctx, detail) => TruncResult(
              needTrunc: true,
              needOffload: true,
              offloadFilePath: '/tmp/trunc/cid',
              offloadContent: 'big',
              toolResult: _text('trunc'),
            ),
          ),
        },
      );

      final wrapped = mw.wrapEnhancedInvokableToolCall(ctx, (ctx, ta, options) async => _text('orig'), tCtx);
      await expectLater(
        wrapped(ctx, toolArg, null),
        throwsA(_threepioMessage('truncation: no backend for offload')),
      );
    });

    test('enhanced invokable - trunc + offload writes and returns trunc result', () async {
      final backend = InMemoryBackend();
      final seenResults = <ToolResult?>[];
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: (ctx, detail) {
              seenResults.add(detail.toolResult);
              return TruncResult(
                needTrunc: true,
                needOffload: true,
                offloadFilePath: '/tmp/trunc/cid',
                offloadContent: 'full content',
                toolResult: _text('truncated'),
              );
            },
          ),
        },
      );

      final seenSame = <bool>[];
      final wrapped = mw.wrapEnhancedInvokableToolCall(
        ctx,
        (ctx, ta, options) async {
          seenSame.add(identical(ta, toolArg));
          return _text('orig');
        },
        tCtx,
      );
      final got = await wrapped(ctx, toolArg, null);
      expect(seenSame, [true]);
      expect(seenResults, hasLength(1));
      expect(seenResults.single, isNotNull);
      expect(got.parts[0].text, 'truncated');

      expect(await _read(backend, '/tmp/trunc/cid'), 'full content');
    });

    const sCtx = ToolContext(name: 'enh_stream_tool', callId: 'scid');

    test('enhanced streamable - no trunc returns original stream (Copy semantics)', () async {
      final backend = InMemoryBackend();
      final seenParts = <List<ToolOutputPart>?>[];
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_stream_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: (ctx, detail) async {
              // Consume the "analysis" copy; the returned reader should still have the full stream.
              seenParts.add(await jointToolResult(detail));
              return const TruncResult(needTrunc: false);
            },
          ),
        },
      );

      Future<StreamReader<ToolResult>> endpoint(RunContext ctx, ToolArgument ta, ToolOptions? options) async {
        final (sr, sw) = pipe<ToolResult>(capacity: 4);
        unawaited(() async {
          sw
            ..send(_text('hello '))
            ..send(_text('world'));
          await sw.close();
        }());
        return sr;
      }

      final wrapped = mw.wrapEnhancedStreamableToolCall(ctx, endpoint, sCtx);
      final resp = await wrapped(ctx, toolArg, null);
      addTearDown(resp.close);

      expect(seenParts, hasLength(1));
      expect(seenParts.single, isNotNull);
      expect(seenParts.single, hasLength(1));
      expect(seenParts.single![0].text, 'hello world');

      final chunks = <ToolResult>[];
      for (var guard = 0; guard < 100; guard++) {
        try {
          chunks.add(await resp.recv());
        } on StreamEOFException {
          break;
        }
      }
      final joined = concatToolResults(chunks);
      expect(joined.parts[0].text, 'hello world');
    });

    test('enhanced streamable - trunc + offload writes and returns trunc stream', () async {
      final backend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_stream_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: (ctx, detail) {
              final (sr, sw) = pipe<ToolResult>(capacity: 1);
              sw.send(_text('truncated'));
              unawaited(sw.close());
              return TruncResult(
                needTrunc: true,
                needOffload: true,
                offloadFilePath: '/tmp/trunc/scid',
                offloadContent: 'full content',
                streamToolResult: sr,
              );
            },
          ),
        },
      );

      Future<StreamReader<ToolResult>> endpoint(RunContext ctx, ToolArgument ta, ToolOptions? options) async {
        final (sr, sw) = pipe<ToolResult>(capacity: 2);
        sw.send(_text('orig'));
        unawaited(sw.close());
        return sr;
      }

      final wrapped = mw.wrapEnhancedStreamableToolCall(ctx, endpoint, sCtx);
      final resp = await wrapped(ctx, toolArg, null);
      addTearDown(resp.close);

      expect((await resp.recv()).parts[0].text, 'truncated');
      await expectLater(resp.recv(), throwsA(isA<StreamEOFException>()));

      expect(await _read(backend, '/tmp/trunc/scid'), 'full content');
    });

    test('enhanced streamable - endpoint error returned', () async {
      final backend = InMemoryBackend();
      const wantErr = ThreepioException('endpoint error');
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_stream_tool': ToolReductionConfig(
            backend: backend,
            truncHandler: (ctx, detail) => fail('trunc handler should not be called on endpoint error'),
          ),
        },
      );

      final wrapped = mw.wrapEnhancedStreamableToolCall(ctx, (ctx, ta, options) async => throw wantErr, sCtx);
      await expectLater(wrapped(ctx, toolArg, null), throwsA(same(wantErr)));
    });

    test('enhanced streamable - trunc handler error returned', () async {
      final backend = InMemoryBackend();
      const wantErr = ThreepioException('handler error');
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {
          'enh_stream_tool': ToolReductionConfig(backend: backend, truncHandler: (ctx, detail) => throw wantErr),
        },
      );

      Future<StreamReader<ToolResult>> endpoint(RunContext ctx, ToolArgument ta, ToolOptions? options) async {
        final (sr, sw) = pipe<ToolResult>(capacity: 1);
        sw.send(_text('orig'));
        unawaited(sw.close());
        return sr;
      }

      final wrapped = mw.wrapEnhancedStreamableToolCall(ctx, endpoint, sCtx);
      await expectLater(wrapped(ctx, toolArg, null), throwsA(same(wantErr)));
    });

    test('enhanced streamable - offload without backend returns error', () async {
      // config.Backend must be non-nil to pass New(), but the per-tool cfg.Backend is nil.
      final configBackend = InMemoryBackend();
      final mw = ToolReductionMiddleware(
        backend: configBackend,
        toolConfig: {
          'enh_stream_tool': ToolReductionConfig(
            truncHandler: (ctx, detail) {
              final (sr, sw) = pipe<ToolResult>(capacity: 1);
              sw.send(_text('truncated'));
              unawaited(sw.close());
              return TruncResult(
                needTrunc: true,
                needOffload: true,
                offloadFilePath: '/tmp/trunc/scid',
                offloadContent: 'full content',
                streamToolResult: sr,
              );
            },
          ),
        },
      );

      Future<StreamReader<ToolResult>> endpoint(RunContext ctx, ToolArgument ta, ToolOptions? options) async {
        final (sr, sw) = pipe<ToolResult>(capacity: 1);
        sw.send(_text('orig'));
        unawaited(sw.close());
        return sr;
      }

      final wrapped = mw.wrapEnhancedStreamableToolCall(ctx, endpoint, sCtx);
      await expectLater(
        wrapped(ctx, toolArg, null),
        throwsA(_threepioMessage('truncation: no backend for offload')),
      );
    });
  });

  group('TestClearRewriteMessagesHandler', () {
    // Go passes `&adk.ModelContext{Tools: toolsInfo}` (deprecated, not ported).
    int tokenCounter(RunContext ctx, List<Message> msgs, List<ToolInfo> tools) => 1000;

    test('test all tools hit - rewrite to system reminder', () async {
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: tokenCounter,
        maxTokensForClear: 10,
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) => [
          Message.user('<system-reminder>write_file and edit_file executed successfully</system-reminder>'),
        ],
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('user request'),
          _assistant([
            _tc('call_1', 'write_file', '{"file": "test.txt", "content": "hello"}'),
            _tc('call_2', 'edit_file', '{"file": "test.txt", "changes": "add"}'),
          ]),
          Message.tool(content: 'write success', toolCallId: 'call_1'),
          Message.tool(content: 'edit success', toolCallId: 'call_2'),
          Message.assistant('done'),
          _dummy,
        ]),
        const ModelContext(),
      );
      expect(s.messages, hasLength(5));
      expect(s.messages[2].role, RoleType.user);
      expect(
        s.messages[2].content,
        '<system-reminder>write_file and edit_file executed successfully</system-reminder>',
      );
      expect(s.messages[3].role, RoleType.assistant);
      expect(s.messages[3].content, 'done');
    });

    test('test remove tool call and tool responses', () async {
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: tokenCounter,
        maxTokensForClear: 10,
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) => <Message>[],
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('user request'),
          _assistant([
            _tc('call_1', 'write_file', '{"file": "test.txt", "content": "hello"}'),
            _tc('call_2', 'edit_file', '{"file": "test.txt", "changes": "add"}'),
          ]),
          Message.tool(content: 'write success', toolCallId: 'call_1'),
          Message.tool(content: 'edit success', toolCallId: 'call_2'),
          _dummy,
          Message.tool(content: 'dummy dummy', toolCallId: 'dummy'),
          Message.assistant('done'),
        ]),
        const ModelContext(),
      );
      expect(s.messages, hasLength(5));
      expect(s.messages[2].role, RoleType.assistant);
      expect(s.messages[3].role, RoleType.tool);
      expect(s.messages[3].content, 'dummy dummy');
      expect(s.messages[4].role, RoleType.assistant);
      expect(s.messages[4].content, 'done');
    });

    test('test partial tools hit - keep unhit tools and rewrite hit ones', () async {
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: tokenCounter,
        maxTokensForClear: 10,
        clearExcludeTools: ['get_weather'],
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) {
          const hitToolIds = {'call_1': true};

          final newToolCalls = <ToolCall>[];
          final newToolResponses = <Message>[];

          final calls = assistantMessage.toolCalls ?? const <ToolCall>[];
          for (var i = 0; i < calls.length; i++) {
            final tc = calls[i];
            if (!(hitToolIds[tc.id] ?? false)) {
              newToolCalls.add(tc);
              if (i < (toolResponses?.length ?? 0)) newToolResponses.add(toolResponses![i]);
            }
          }

          final result = [
            Message.user('<system-reminder>write_file executed successfully</system-reminder>'),
          ];
          if (newToolCalls.isNotEmpty) {
            result
              ..add(Message.assistant('', toolCalls: newToolCalls))
              ..addAll(newToolResponses);
          }
          return result;
        },
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('user request'),
          _assistant([
            _tc('call_1', 'write_file', '{"file": "test.txt", "content": "hello"}'),
            _tc('call_2', 'get_weather', '{"location": "London"}'),
          ]),
          Message.tool(content: 'write success', toolCallId: 'call_1'),
          Message.tool(content: 'sunny', toolCallId: 'call_2'),
          _dummy,
        ]),
        const ModelContext(),
      );
      expect(s.messages, hasLength(6));
      expect(s.messages[2].role, RoleType.user);
      expect(s.messages[2].content, '<system-reminder>write_file executed successfully</system-reminder>');
      expect(s.messages[3].role, RoleType.assistant);
      expect(s.messages[3].toolCalls, hasLength(1));
      expect(s.messages[3].toolCalls![0].id, 'call_2');
      expect(s.messages[4].role, RoleType.tool);
      expect(s.messages[4].content, 'sunny');
    });

    // Go has two sub-tests with this name; t.Run names the second "#01".
    for (final name in [
      'test mixed messages with system/user before',
      'test mixed messages with system/user before#01',
    ]) {
      test(name, () async {
        final mw = ToolReductionMiddleware(
          skipTruncation: true,
          tokenCounter: tokenCounter,
          maxTokensForClear: 10,
          clearMessageRewriter: (ctx, assistantMessage, toolResponses) => [
            Message.user('<system-reminder>tool executed</system-reminder>'),
          ],
        );

        final (_, s) = await mw.beforeModelRewriteState(
          ctx,
          ChatModelAgentState(messages: [
            Message.system('you are a helpful assistant'),
            Message.user('first request'),
            _assistant([_tc('call_1', 'write_file', '{"file": "test.txt"}')]),
            Message.tool(content: 'success', toolCallId: 'call_1'),
            Message.user('second request'),
            _dummy,
          ]),
          const ModelContext(),
        );
        expect(s.messages, hasLength(5));
        expect(s.messages[0].role, RoleType.system);
        expect(s.messages[1].role, RoleType.user);
        expect(s.messages[2].role, RoleType.user);
        expect(s.messages[2].content, '<system-reminder>tool executed</system-reminder>');
        expect(s.messages[3].role, RoleType.user);
      });
    }

    test('test assistant message without tool calls - keep as is', () async {
      var handlerCalled = false;
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: tokenCounter,
        maxTokensForClear: 10,
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) {
          handlerCalled = true;
          return null;
        },
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('user request'),
          Message.assistant('regular response without tools'),
          _dummy,
        ]),
        const ModelContext(),
      );
      expect(handlerCalled, isFalse);
      expect(s.messages, hasLength(4));
      expect(s.messages[2].role, RoleType.assistant);
      expect(s.messages[2].content, 'regular response without tools');
    });

    test('test clear not meeting threshold - should keep original messages', () async {
      const originalTokenCount = 1000;
      const rewrittenTokenCount = 999;
      var callCount = 0;

      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: (ctx, msgs, tools) {
          callCount++;
          if (callCount == 1) return originalTokenCount;
          return rewrittenTokenCount;
        },
        maxTokensForClear: 10,
        clearAtLeastTokens: 10,
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) => [
          Message.user('<system-reminder>tool executed</system-reminder>'),
        ],
      );

      final originalMessages = [
        Message.system('you are a helpful assistant'),
        Message.user('user request'),
        _assistant([_tc('call_1', 'write_file', '{"file": "test.txt"}')]),
        Message.tool(content: 'success', toolCallId: 'call_1'),
        _dummy,
      ];

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: originalMessages),
        const ModelContext(),
      );
      expect(s.messages, hasLength(originalMessages.length));
      for (var i = 0; i < originalMessages.length; i++) {
        expect(s.messages[i].role, originalMessages[i].role);
        expect(s.messages[i].content, originalMessages[i].content);
      }
    });

    // "test applyClearRewrite with default role": not portable (see the file
    // comment).

    test('test applyClearRewrite with rewrite error', () async {
      const expectedErr = ThreepioException('rewrite error');
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: tokenCounter,
        maxTokensForClear: 10,
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) => throw expectedErr,
      );

      await expectLater(
        mw.beforeModelRewriteState(
          ctx,
          ChatModelAgentState(messages: [
            Message.system('you are a helpful assistant'),
            Message.user('user request'),
            _assistant([_tc('call_1', 'write_file', '{"file": "test.txt"}')]),
            Message.tool(content: 'success', toolCallId: 'call_1'),
            _dummy,
          ]),
          const ModelContext(),
        ),
        throwsA(same(expectedErr)),
      );
    });

    test('test applyClearRewrite with missing tool responses', () async {
      final seenResponses = <List<Message>?>[];
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: tokenCounter,
        maxTokensForClear: 10,
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) {
          seenResponses.add(toolResponses);
          return [Message.user('<system-reminder>tool executed</system-reminder>')];
        },
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('user request'),
          _assistant([_tc('call_1', 'write_file', '{"file": "test.txt"}')]),
          _dummy,
        ]),
        const ModelContext(),
      );
      expect(seenResponses, everyElement(isNull));
      expect(s, isNotNull);
    });

    test('test applyClearRewrite with clearAtLeastTokens > 0', () async {
      final mw = ToolReductionMiddleware(
        skipTruncation: true,
        tokenCounter: tokenCounter,
        maxTokensForClear: 10,
        clearAtLeastTokens: 10,
        clearMessageRewriter: (ctx, assistantMessage, toolResponses) => [
          Message.user('<system-reminder>tool executed</system-reminder>'),
        ],
      );

      final (_, s) = await mw.beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message.system('you are a helpful assistant'),
          Message.user('user request'),
          _assistant([_tc('call_1', 'write_file', '{"file": "test.txt"}')]),
          Message.tool(content: 'success', toolCallId: 'call_1'),
          _dummy,
        ]),
        const ModelContext(),
      );
      expect(s, isNotNull);
    });
  });
}
