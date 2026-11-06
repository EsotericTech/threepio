// Streaming through ClaudeChatModel.stream: tests written for the port (the
// Go stream goroutine of eino-ext components/model/claude/claude.go has no Go
// test of its own beyond TestConvStreamEvent, ported in
// claude_converters_test.dart). The fixtures are recorded-shape server-sent
// events of the Anthropic Messages API (claude_fixtures.dart).
//
// Covered: chunking and the held-back empty chunks; tool use fragments
// joined by concatMessages; thinking and signature round trip; server-side
// tool search; SSE edge cases (lines split across reads, comments, a missing
// trailing blank line, `[DONE]`, events without an `event:` line, unknown
// events, a malformed chunk, an `error` event); cancellation before and
// during the stream; a reader closed early; the idle timeout; HTTP errors.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_config.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_converters.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_message_extras.dart';
import 'package:threepio_core/threepio_core.dart';

import 'claude_fixtures.dart';

ClaudeChatModel _model(http.Client client, {ClaudeConfig config = testConfig}) =>
    ClaudeChatModel(config: config, httpClient: client);

Future<List<Message>> _chunks(List<String> body) async {
  final reader = await _model(FakeAnthropic.sse(body)).stream([Message.user('hi')]);
  try {
    return await reader.collectAll();
  } finally {
    await reader.close();
  }
}

/// Reads [reader] until it fails; returns the chunks and the error.
Future<(List<Message>, Object?)> _readUntilError(
  StreamReader<Message> reader,
) async {
  final chunks = <Message>[];
  try {
    for (;;) {
      final chunk = await reader.nextOrNull();
      if (chunk == null) return (chunks, null);
      chunks.add(chunk);
    }
  } catch (error) {
    return (chunks, error);
  } finally {
    await reader.close();
  }
}

/// A body whose bytes the test sends, and that records being released.
final class _Body {
  _Body() {
    controller = StreamController<List<int>>(onCancel: () => released = true);
  }

  late final StreamController<List<int>> controller;
  bool released = false;

  void add(String text) => controller.add(utf8.encode(text));

  FakeAnthropic get client => FakeAnthropic(
        (request) => http.StreamedResponse(controller.stream, 200),
      );
}

void main() {
  group('chunks', () {
    test('a text stream: held-back chunks join the next one', () async {
      final fake = FakeAnthropic.sse(textStream());
      final reader = await _model(fake).stream([Message.user('hi')]);
      final chunks = await reader.collectAll();

      expect(fake.body['stream'], isTrue);
      expect(fake.requests.single.headers['accept'], 'text/event-stream');

      // message_start and the empty text block wait for "Hello"; the
      // message_delta waits for the end.
      expect(chunks.map((c) => c.content), ['Hello', '!', '']);
      expect(chunks[0].responseMeta!.usage!.promptTokens, 25);
      expect(chunks[2].responseMeta!.finishReason, 'end_turn');
      expect(chunks[2].responseMeta!.usage!.completionTokens, 15);

      final message = concatMessages(chunks);
      expect(message.role, RoleType.assistant);
      expect(message.content, 'Hello!');
      expect(message.responseMeta!.finishReason, 'end_turn');
      expect(message.responseMeta!.usage!.promptTokens, 25);
      expect(message.responseMeta!.usage!.completionTokens, 15);
    });

    test('tool use fragments are joined by concatMessages', () async {
      final chunks = await _chunks(toolUseStream());
      final toolChunks =
          chunks.where((c) => c.toolCalls?.isNotEmpty ?? false).toList();
      expect(toolChunks.first.toolCalls!.single.type, 'function');
      expect(toolChunks.first.toolCalls!.single.id, 'toolu_01T1x1fJ34qAmk2tNTrN7Up6');
      for (final chunk in toolChunks.skip(1)) {
        final call = chunk.toolCalls!.single;
        expect(call.type, '');
        expect(call.id, '');
        expect(call.index, 0);
      }

      final message = concatMessages(chunks);
      expect(message.content, 'Okay, let me check.');
      expect(message.toolCalls, [
        const ToolCall(
          index: 0,
          id: 'toolu_01T1x1fJ34qAmk2tNTrN7Up6',
          function: FunctionCall(
            name: 'get_weather',
            arguments: '{"location": "San Francisco, CA"}',
          ),
        ),
      ]);
      expect(message.responseMeta!.finishReason, 'tool_use');
      expect(message.responseMeta!.usage!.completionTokens, 89);

      // The joined message goes back as a tool_use block.
      expect(
        (claudeMessageParam(message)['content']! as List).last,
        {
          'type': 'tool_use',
          'id': 'toolu_01T1x1fJ34qAmk2tNTrN7Up6',
          'input': {'location': 'San Francisco, CA'},
          'name': 'get_weather',
        },
      );
    });

    test('two tool calls get indexes 0 and 1', () async {
      final message = concatMessages(
        await _chunks([
          messageStart(),
          blockStart(0, toolUseBlock('t1', 'a', {})),
          jsonDelta(0, '{"x":1}'),
          blockStop(0),
          blockStart(1, toolUseBlock('t2', 'b', {})),
          blockStop(1),
          messageDelta('tool_use'),
          messageStop,
        ]),
      );
      expect(message.toolCalls!.map((c) => (c.index, c.id, c.function.arguments)), [
        (0, 't1', '{"x":1}'),
        (1, 't2', ''),
      ]);
    });

    test('thinking and its signature round trip', () async {
      final message = concatMessages(await _chunks(thinkingStream()));
      expect(message.claudeThinking, 'Let me solve this.');
      expect(message.reasoningContent, 'Let me solve this.');
      expect(claudeThinkingSignatureOf(message.extra), 'EqQBCgIYAhIM1gbcDa9GJwZA');
      expect(message.content, 'The answer is 4.');

      expect(claudeMessageParam(message), {
        'role': 'assistant',
        'content': [
          {
            'type': 'thinking',
            'signature': 'EqQBCgIYAhIM1gbcDa9GJwZA',
            'thinking': 'Let me solve this.',
          },
          {'type': 'text', 'text': 'The answer is 4.'},
        ],
      });
    });

    test('a server-side tool search becomes events, not tool calls', () async {
      final message = concatMessages(
        await _chunks([
          messageStart(),
          blockStart(0, {
            'type': 'server_tool_use',
            'id': 'srvtoolu_01',
            'name': 'tool_search_tool_bm25',
            'input': <String, Object?>{},
          }),
          jsonDelta(0, '{"query": "wea'),
          jsonDelta(0, 'ther"}'),
          blockStop(0),
          blockStart(1, {
            'type': 'tool_search_tool_result',
            'tool_use_id': 'srvtoolu_01',
            'content': {
              'type': 'tool_search_tool_search_result',
              'tool_references': [
                {'type': 'tool_reference', 'tool_name': 'get_weather'},
              ],
            },
          }),
          blockStop(1),
          blockStart(2, toolUseBlock('toolu_02', 'get_weather', {})),
          jsonDelta(2, '{"city": "Paris"}'),
          blockStop(2),
          messageDelta('tool_use'),
          messageStop,
        ]),
      );
      final events = message.claudeToolSearchEvents;
      expect(events, hasLength(2));
      expect(events[0].type, ClaudeToolSearchEventType.serverToolUse);
      expect(events[0].input, {'query': 'weather'});
      expect(events[1].content!.toolReferences.single.toolName, 'get_weather');
      expect(message.toolCalls!.single.index, 0);
      expect(message.toolCalls!.single.function.arguments, '{"city": "Paris"}');

      final blocks = claudeMessageParam(message)['content']! as List;
      expect((blocks[0] as Map)['type'], 'server_tool_use');
      expect((blocks[0] as Map)['input'], {'query': 'weather'});
      expect((blocks[1] as Map)['type'], 'tool_search_tool_result');
      expect((blocks[2] as Map)['type'], 'tool_use');
    });

    test('cache creation tokens of message_start reach the joined message',
        () async {
      final message = concatMessages(
        await _chunks([
          messageStart(inputTokens: 3, cacheCreation: 2048, cacheRead: 100),
          blockStart(0, {'type': 'text', 'text': ''}),
          textDelta(0, 'ok'),
          blockStop(0),
          messageDelta('end_turn'),
          messageStop,
        ]),
      );
      expect(message.claudeCacheCreationInputTokens, 2048);
      expect(message.responseMeta!.usage!.promptTokens, 3 + 2048 + 100);
      expect(message.responseMeta!.usage!.promptTokenDetails!.cachedTokens, 100);
    });
  });

  group('SSE edge cases', () {
    test('lines and UTF-8 characters split across reads', () async {
      final text = [
        messageStart(),
        blockStart(0, {'type': 'text', 'text': ''}),
        textDelta(0, 'Grüße, café'),
        blockStop(0),
        messageDelta('end_turn'),
        messageStop,
      ].join();
      final bytes = utf8.encode(text);
      final fake = FakeAnthropic(
        (request) => http.StreamedResponse(
          Stream.fromIterable([
            for (var i = 0; i < bytes.length; i += 5)
              bytes.sublist(i, i + 5 > bytes.length ? bytes.length : i + 5),
          ]),
          200,
        ),
      );
      final reader = await _model(fake).stream([Message.user('hi')]);
      final message = await concatMessageStream(reader);
      expect(message.content, 'Grüße, café');
      expect(message.responseMeta!.finishReason, 'end_turn');
    });

    test('comments, CRLF and a missing trailing blank line', () async {
      final events = [
        ': keep-alive\n\n',
        messageStart(),
        blockStart(0, {'type': 'text', 'text': ''}).replaceAll('\n', '\r\n'),
        ': another comment\n',
        textDelta(0, 'Hi'),
        // The last event without the blank line that should end it.
        sseEvent('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': ' there'},
        }).trimRight(),
      ];
      final message = concatMessages(await _chunks(events));
      expect(message.content, 'Hi there');
    });

    test('the data lines of one event are joined, as the Go SDK does', () async {
      const twoDataLines = 'event: content_block_delta\n'
          'data: {"type": "content_block_delta", "index": 0,\n'
          'data: "delta": {"type": "text_delta", "text": "joined"}}\n'
          '\n';
      final message = concatMessages(
        await _chunks([
          messageStart(),
          blockStart(0, {'type': 'text', 'text': ''}),
          twoDataLines,
          messageDelta('end_turn'),
          messageStop,
        ]),
      );
      expect(message.content, 'joined');
      expect(message.responseMeta!.finishReason, 'end_turn');
    });

    test('[DONE], pings, unknown events and events without a name', () async {
      final message = concatMessages(
        await _chunks([
          messageStart(),
          ping,
          sseEvent('future_event', {'type': 'future_event', 'x': 1}),
          blockStart(0, {'type': 'text', 'text': ''}),
          // No event line: the JSON type names it.
          'data: ${jsonEncode({
                'type': 'content_block_delta',
                'index': 0,
                'delta': {'type': 'text_delta', 'text': 'A'},
              })}\n\n',
          blockDelta(0, {'type': 'citations_delta', 'citation': <String, Object?>{}}),
          textDelta(0, 'B'),
          'data: [DONE]\n\n',
          messageDelta('end_turn'),
          messageStop,
        ]),
      );
      expect(message.content, 'AB');
      expect(message.responseMeta!.finishReason, 'end_turn');
    });

    test('a malformed chunk ends the stream with a ClaudeException', () async {
      final reader = await _model(
        FakeAnthropic.sse([
          messageStart(),
          blockStart(0, {'type': 'text', 'text': ''}),
          textDelta(0, 'before'),
          messageDelta('end_turn'),
          'event: content_block_delta\ndata: {"type": "content_block_delta", \n\n',
          textDelta(0, 'never'),
        ]),
      ).stream([Message.user('hi')]);
      final (chunks, error) = await _readUntilError(reader);
      // As the Go SDK's decode error: the held-back chunk comes first.
      expect(chunks.map((c) => c.content), ['before', '']);
      expect(chunks.last.responseMeta!.finishReason, 'end_turn');
      expect(
        error,
        isA<ClaudeException>()
            .having((e) => e.isRetryable, 'isRetryable', false)
            .having((e) => e.message, 'message', contains('not a JSON object')),
      );
    });

    test('an error event ends the stream; held chunks come first', () async {
      final reader = await _model(
        FakeAnthropic.sse([
          messageStart(),
          blockStart(0, {'type': 'text', 'text': ''}),
          textDelta(0, 'partial'),
          messageDelta('end_turn'),
          sseEvent('error', {
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }),
          textDelta(0, 'never'),
        ]),
      ).stream([Message.user('hi')]);
      final (chunks, error) = await _readUntilError(reader);
      expect(chunks.map((c) => c.content), ['partial', '']);
      expect(chunks.last.responseMeta!.finishReason, 'end_turn');
      expect(
        error,
        isA<ClaudeException>()
            .having((e) => e.isRetryable, 'isRetryable', true)
            .having((e) => e.isOverloaded, 'isOverloaded', true)
            .having((e) => e.errorType, 'errorType', 'overloaded_error')
            .having((e) => e.message, 'message', contains('Overloaded')),
      );
    });

    test('an invalid_request_error event is not retryable', () async {
      final reader = await _model(
        FakeAnthropic.sse([
          sseEvent('error', {
            'type': 'error',
            'error': {'type': 'invalid_request_error', 'message': 'bad'},
          }),
        ]),
      ).stream([Message.user('hi')]);
      final (chunks, error) = await _readUntilError(reader);
      expect(chunks, isEmpty);
      expect(
        error,
        isA<ClaudeException>()
            .having((e) => e.isRetryable, 'isRetryable', false)
            .having((e) => e.isModelUnavailable, 'isModelUnavailable', false),
      );
    });

    test('an unknown content block ends the stream, as in Go', () async {
      final reader = await _model(
        FakeAnthropic.sse([
          messageStart(),
          blockStart(0, {'type': 'hologram'}),
        ]),
      ).stream([Message.user('hi')]);
      final (chunks, error) = await _readUntilError(reader);
      // Go returns at once: the held-back message_start is not sent.
      expect(chunks, isEmpty);
      expect(
        error,
        isA<ClaudeException>().having(
          (e) => e.message,
          'message',
          contains('unknown anthropic content block type: hologram'),
        ),
      );
    });

    test('a body that fails mid-stream is a retryable ClaudeException',
        () async {
      final body = _Body();
      final reader = await _model(body.client).stream([Message.user('hi')]);
      body
        ..add(messageStart())
        ..add(blockStart(0, {'type': 'text', 'text': ''}))
        ..add(textDelta(0, 'a'));
      expect((await reader.recv()).content, 'a');
      body.add(messageDelta('end_turn'));
      await pumpEventQueue();
      body.controller.addError(http.ClientException('connection reset'));
      final (chunks, error) = await _readUntilError(reader);
      // The held-back message_delta is sent before the error, as in Go.
      expect(chunks.single.responseMeta!.finishReason, 'end_turn');
      expect(
        error,
        isA<ClaudeException>()
            .having((e) => e.isRetryable, 'isRetryable', true)
            .having((e) => e.cause, 'cause', isA<http.ClientException>()),
      );
      await body.controller.close();
    });
  });

  group('cancellation and lifecycle', () {
    test('a cancelled token stops the stream before the request', () async {
      final fake = FakeAnthropic.sse(textStream());
      final token = CancelToken()..cancel('stop');
      await expectLater(
        _model(fake).stream(
          [Message.user('hi')],
          options: ChatModelOptions(cancelToken: token),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(fake.requests, isEmpty);
    });

    test('cancelling mid-stream ends it and releases the body', () async {
      final body = _Body();
      final ctx = RunContext.background();
      final other = CancelToken();
      final reader = await _model(body.client).stream(
        [Message.user('hi')],
        // Two tokens: the call listens to a combined one.
        options: ChatModelOptions(runContext: ctx, cancelToken: other),
      );
      body
        ..add(messageStart())
        ..add(blockStart(0, {'type': 'text', 'text': ''}))
        ..add(textDelta(0, 'first'));
      expect((await reader.recv()).content, 'first');

      ctx.cancelToken.cancel('user stop');
      final (chunks, error) = await _readUntilError(reader);
      expect(chunks, isEmpty);
      expect(
        error,
        isA<CancelledException>().having((e) => e.reason, 'reason', 'user stop'),
      );
      await pumpEventQueue();
      expect(body.released, isTrue);
      expect(other.isCancelled, isFalse);
      await body.controller.close();
    });

    test('cancelling sends the held-back chunks first, as in Go', () async {
      final body = _Body();
      final token = CancelToken();
      final reader = await _model(body.client).stream(
        [Message.user('hi')],
        options: ChatModelOptions(cancelToken: token),
      );
      body
        ..add(messageStart())
        ..add(blockStart(0, {'type': 'text', 'text': ''}))
        ..add(textDelta(0, 'first'))
        ..add(blockStop(0))
        ..add(messageDelta('max_tokens'));
      expect((await reader.recv()).content, 'first');
      await pumpEventQueue();

      token.cancel('stop');
      final (chunks, error) = await _readUntilError(reader);
      expect(chunks.single.responseMeta!.finishReason, 'max_tokens');
      expect(error, isA<CancelledException>());
      await pumpEventQueue();
      expect(body.released, isTrue);
      await body.controller.close();
    });

    test('without an idle timeout a slow stream is fine', () async {
      final body = _Body();
      final reader = await _model(
        body.client,
        config: const ClaudeConfig(
          apiKey: 'test-key',
          model: testModel,
          maxTokens: 1,
          idleTimeout: null,
        ),
      ).stream([Message.user('hi')]);
      body.add(messageStart());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      for (final event in [
        blockStart(0, {'type': 'text', 'text': ''}),
        textDelta(0, 'late'),
        messageDelta('end_turn'),
        messageStop,
      ]) {
        body.add(event);
      }
      await body.controller.close();
      final message = await concatMessageStream(reader);
      expect(message.content, 'late');
    });

    test('a reader closed early releases the body', () async {
      final body = _Body();
      final reader = await _model(body.client).stream([Message.user('hi')]);
      body
        ..add(messageStart())
        ..add(blockStart(0, {'type': 'text', 'text': ''}))
        ..add(textDelta(0, 'first'));
      expect((await reader.recv()).content, 'first');
      await reader.close();
      body.add(textDelta(0, 'ignored'));
      await pumpEventQueue();
      expect(body.released, isTrue);
      await body.controller.close();
    });

    test('a silent stream fails after the idle timeout', () async {
      final body = _Body();
      final reader = await _model(
        body.client,
        config: const ClaudeConfig(
          apiKey: 'test-key',
          model: testModel,
          maxTokens: 1,
          idleTimeout: Duration(milliseconds: 20),
        ),
      ).stream([Message.user('hi')]);
      body.add(messageStart());
      final (chunks, error) = await _readUntilError(reader);
      // The held-back message_start comes before the error.
      expect(chunks.single.responseMeta!.usage!.promptTokens, 25);
      expect(
        error,
        isA<ClaudeException>()
            .having((e) => e.isRetryable, 'isRetryable', true)
            .having((e) => e.message, 'message', contains('idle')),
      );
      await pumpEventQueue();
      expect(body.released, isTrue);
      await body.controller.close();
    });

    test('an HTTP error is thrown by stream() itself', () async {
      final model = _model(
        FakeAnthropic.raw(
          jsonEncode({
            'type': 'error',
            'error': {'type': 'rate_limit_error', 'message': 'slow down'},
          }),
          status: 429,
          headers: {'retry-after': '1'},
        ),
      );
      await expectLater(
        model.stream([Message.user('hi')]),
        throwsA(
          isA<ClaudeException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.isRateLimited, 'isRateLimited', true)
              .having((e) => e.isRetryable, 'isRetryable', true),
        ),
      );
    });

    test('a transport failure is thrown by stream() itself', () async {
      final model = _model(
        FakeAnthropic((request) => throw http.ClientException('refused')),
      );
      await expectLater(
        model.stream([Message.user('hi')]),
        throwsA(
          isA<ClaudeException>().having((e) => e.isRetryable, 'isRetryable', true),
        ),
      );
    });
  });
}
