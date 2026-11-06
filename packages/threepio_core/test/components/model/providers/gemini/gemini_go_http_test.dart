// Ports of eino-ext components/model/gemini/extra_fields_test.go,
// http_headers_test.go and gemini_context_test.go.
//
// Go runs the real adapter and genai SDK against an httptest server; here the
// model runs against a fake HTTP client that checks the request (headers and
// JSON body) and answers with Gemini REST JSON or an SSE stream.
//
// Ported: TestWithExtraFields and TestWithCustomHeaders (generate, stream,
// twelve concurrent calls, calls without the option), TestStreamContextErrors
// (cancel without / with a partial event, cancel with a custom cause, a
// malformed event, a partial event at the end of the body, a transport error,
// cancel before the request, cancel after content, normal completion; the
// caller and the callback handler's copy of the stream both see the error).
//
// Not ported: the Vertex AI backend runs of TestWithExtraFields and
// TestWithCustomHeaders (this model talks to the Gemini API only); the
// client-level headers of TestWithCustomHeaders (`ClientConfig.HTTPOptions`
// has no counterpart in `GeminiConfig`); the deadline cases of
// TestStreamContextErrors (`RunContext` has no deadline; a cancel token is
// the one way to stop a call).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/model/chat_model_options.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_config.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_options.dart';
import 'package:threepio_core/src/errors.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/threepio_core.dart'
    show
        ComponentCallbackHandler,
        RunContext,
        RunInfo,
        StreamReader,
        CallbackContext;

const _config = GeminiConfig(apiKey: 'local-test-key', defaultModel: 'gemini-test');

const _okResponse =
    '{"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}]}';

/// A client that runs [check] on every request (its headers and decoded
/// body) and answers `ok`, as JSON or as one SSE event.
http.Client _checkingClient(
  void Function(http.BaseRequest request, Map<String, dynamic> body) check,
) =>
    MockClient.streaming((request, bodyStream) async {
      final body =
          jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
      check(request, body);
      if (request.url.path.endsWith(':streamGenerateContent')) {
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: $_okResponse\n\n')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode(_okResponse)),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

Future<String> _call(
  GeminiChatModel model,
  String projectId, {
  required bool stream,
  ChatModelOptions? options,
}) async {
  final messages = [Message.user(projectId)];
  if (!stream) return (await model.generate(messages, options: options)).content;
  final reader = await model.stream(messages, options: options);
  try {
    return (await reader.collectAll()).map((m) => m.content).join();
  } finally {
    await reader.close();
  }
}

/// Records the error that reaches the handler's copy of the stream, or the
/// error callback.
final class _StreamErrorRecorder extends ComponentCallbackHandler {
  final Completer<Object?> outcome = Completer<Object?>();
  final List<String> contents = [];

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!outcome.isCompleted) outcome.complete(error);
    return ctx;
  }

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    unawaited(() async {
      try {
        while (true) {
          final chunk = await output.nextOrNull();
          if (chunk == null) break;
          contents.add('$chunk');
        }
        if (!outcome.isCompleted) outcome.complete(null);
      } on Object catch (error) {
        if (!outcome.isCompleted) outcome.complete(error);
      } finally {
        await output.close();
      }
    }());
    return ctx;
  }
}

void main() {
  group('TestWithExtraFields', () {
    void check(http.BaseRequest request, Map<String, dynamic> body) {
      final contents = body['contents'] as List;
      expect(contents, hasLength(1));
      final parts = (contents.single as Map)['parts'] as List;
      expect(parts, hasLength(1));
      final projectId = (parts.single as Map)['text'] as String;
      if (projectId == 'without-option') {
        expect(body.containsKey('prompt_cache_key'), isFalse,
            reason: 'request without option inherited a cache key');
      } else {
        expect(body['prompt_cache_key'], '$projectId:creation');
        final generationConfig = body['generationConfig'] as Map;
        expect(generationConfig['maxOutputTokens'], 128);
        expect(generationConfig['candidateCount'], 1);
      }
      expect(body.containsKey('labels'), isFalse,
          reason: 'custom key should be top-level');
    }

    late GeminiChatModel chat;
    setUp(() {
      chat = GeminiChatModel(config: _config, httpClient: _checkingClient(check));
    });

    ChatModelOptions optionsFor(String projectId) => GeminiRequestOptions(
          extraFields: {
            'prompt_cache_key': '$projectId:creation',
            'generationConfig': {'candidateCount': 1},
          },
        ).toOptions(maxTokens: 128);

    test('project-generate', () async {
      expect(
        await _call(chat, 'project-generate',
            stream: false, options: optionsFor('project-generate')),
        'ok',
      );
    });

    test('project-stream', () async {
      expect(
        await _call(chat, 'project-stream',
            stream: true, options: optionsFor('project-stream')),
        'ok',
      );
    });

    test('concurrent-projects', () async {
      final results = await Future.wait([
        for (var i = 0; i < 12; i++)
          _call(chat, 'project-$i',
              stream: i.isEven, options: optionsFor('project-$i')),
      ]);
      expect(results, everyElement('ok'));
    });

    test('without-option', () async {
      expect(await _call(chat, 'without-option', stream: false), 'ok');
      expect(await _call(chat, 'without-option', stream: true), 'ok');
    });

    test('the extra fields map is not changed by the merge', () async {
      final generationConfig = <String, Object?>{'candidateCount': 1};
      final extra = <String, Object?>{
        'prompt_cache_key': 'p:creation',
        'generationConfig': generationConfig,
      };
      await _call(
        chat,
        'p',
        stream: false,
        options:
            GeminiRequestOptions(extraFields: extra).toOptions(maxTokens: 128),
      );
      expect(generationConfig, {'candidateCount': 1});
    });
  });

  group('TestWithCustomHeaders', () {
    void check(http.BaseRequest request, Map<String, dynamic> body) {
      final projectId = ((body['contents'] as List).single as Map)['parts'][0]
          ['text'] as String;
      final withOption = projectId != 'without-option';
      expect(
        request.headers['x-request-key'],
        withOption ? '$projectId:creation' : isNull,
      );
      expect(request.headers['x-override'], withOption ? 'request-value' : isNull);
      // The headers the model manages win over custom ones.
      expect(request.headers['x-goog-api-key'], 'local-test-key');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(body['gateway_flag'], withOption ? isTrue : isNull,
          reason: 'header and extra body options did not coexist correctly');
      expect(body.containsKey('prompt_cache_key'), isFalse,
          reason: 'cache key must not be sent in the JSON body');
      expect(body.containsKey('labels'), isFalse);
    }

    late GeminiChatModel chat;
    setUp(() {
      chat = GeminiChatModel(config: _config, httpClient: _checkingClient(check));
    });

    ChatModelOptions optionsFor(String projectId) {
      final headers = {
        'X-Request-Key': '$projectId:creation',
        'x-override': 'request-value',
        'X-Goog-Api-Key': 'not-the-key',
        'content-type': 'text/plain',
      };
      final options = GeminiRequestOptions(
        customHeaders: headers,
        extraFields: {'gateway_flag': true},
      ).toOptions();
      // The options must snapshot the headers.
      headers['X-Request-Key'] = 'mutated-after-option';
      headers['x-override'] = 'mutated-after-option';
      return options;
    }

    test('project-generate', () async {
      expect(
        await _call(chat, 'project-generate',
            stream: false, options: optionsFor('project-generate')),
        'ok',
      );
    });

    test('project-stream', () async {
      expect(
        await _call(chat, 'project-stream',
            stream: true, options: optionsFor('project-stream')),
        'ok',
      );
    });

    test('concurrent-projects', () async {
      final results = await Future.wait([
        for (var i = 0; i < 12; i++)
          _call(chat, 'project-$i',
              stream: i.isEven, options: optionsFor('project-$i')),
      ]);
      expect(results, everyElement('ok'));
    });

    test('without-option', () async {
      expect(await _call(chat, 'without-option', stream: false), 'ok');
      expect(await _call(chat, 'without-option', stream: true), 'ok');
    });
  });

  group('TestStreamContextErrors', () {
    const partial = 'data: {"candidates": [{"content": {"role": "model","p';
    const validEvent =
        'data: {"candidates":[{"content":{"role":"model","parts":[{"text":"hello"}]},"finishReason":"STOP"}]}\n\n';

    /// Runs one case: the body sends [data], then [finish] decides how it
    /// ends. Returns what the caller and the callback handler saw.
    Future<
        ({
          String content,
          Object? callerError,
          Object? callbackError,
          bool bodyReleased,
        })> run({
      String data = '',
      required Future<void> Function(
        StreamController<List<int>> body,
        CancelToken token,
      ) finish,
      bool preCanceled = false,
    }) async {
      final token = CancelToken();
      var bodyReleased = false;
      final body = StreamController<List<int>>(
        onCancel: () => bodyReleased = true,
      );
      var requests = 0;
      final client = MockClient.streaming((request, bodyStream) async {
        requests++;
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          body.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final model = GeminiChatModel(config: _config, httpClient: client);
      final recorder = _StreamErrorRecorder();
      final options = ChatModelOptions(
        runContext:
            RunContext.background(cancelToken: token).withHandlers([recorder]),
      );
      if (preCanceled) token.cancel();

      final content = StringBuffer();
      Object? callerError;
      try {
        final reader = await model.stream([Message.user('test')], options: options);
        if (data.isNotEmpty) body.add(utf8.encode(data));
        unawaited(finish(body, token));
        try {
          while (true) {
            final message = await reader.nextOrNull();
            if (message == null) break;
            content.write(message.content);
          }
        } finally {
          await reader.close();
        }
      } on Object catch (error) {
        callerError = error;
      }
      final callbackError =
          await recorder.outcome.future.timeout(const Duration(seconds: 5));
      if (preCanceled) expect(requests, 0, reason: 'nothing is sent');
      unawaited(body.close());
      return (
        content: content.toString(),
        callerError: callerError,
        callbackError: callbackError,
        bodyReleased: bodyReleased,
      );
    }

    Future<void> cancel(StreamController<List<int>> body, CancelToken token) async {
      await pumpEventQueue();
      token.cancel();
    }

    Future<void> endBody(StreamController<List<int>> body, CancelToken token) async {
      await pumpEventQueue();
      unawaited(body.close());
    }

    test('cancel_without_partial_event', () async {
      final r = await run(finish: cancel);
      expect(r.content, '');
      expect(r.callerError, isA<CancelledException>());
      expect(r.callbackError, isA<CancelledException>());
      expect(r.bodyReleased, isTrue);
    });

    test('cancel_with_partial_event', () async {
      final r = await run(data: partial, finish: cancel);
      expect(r.callerError, isA<CancelledException>());
      expect(r.callbackError, isA<CancelledException>());
      expect(r.bodyReleased, isTrue);
    });

    test('cancel_with_custom_cause', () async {
      final r = await run(
        data: partial,
        finish: (body, token) async {
          await pumpEventQueue();
          token.cancel('test domain cause');
        },
      );
      expect(
        r.callerError,
        isA<CancelledException>()
            .having((e) => e.reason, 'reason', 'test domain cause'),
      );
      expect(r.callbackError, isA<CancelledException>());
    });

    test('malformed_event_without_cancel', () async {
      final r = await run(data: 'data: {invalid}\n\n', finish: endBody);
      expect(r.callerError, isA<ThreepioFormatException>());
      expect(r.callbackError, isA<ThreepioFormatException>());
    });

    test('partial_event_without_cancel', () async {
      final r = await run(data: partial, finish: endBody);
      expect(r.callerError, isA<ThreepioFormatException>());
      expect(r.callbackError, isA<ThreepioFormatException>());
    });

    test('transport_error_without_cancel', () async {
      final failure = http.ClientException('test transport read failed');
      final r = await run(
        finish: (body, token) async {
          await pumpEventQueue();
          body.addError(failure);
        },
      );
      expect(
        r.callerError,
        isA<GeminiException>()
            .having((e) => e.cause, 'cause', same(failure))
            .having((e) => e.isRetryable, 'isRetryable', isTrue),
      );
      expect(r.callbackError, isA<GeminiException>());
    });

    test('cancel_before_request', () async {
      final r = await run(finish: endBody, preCanceled: true);
      expect(r.callerError, isA<CancelledException>());
      expect(r.callbackError, isA<CancelledException>());
    });

    test('cancel_after_content', () async {
      final r = await run(data: validEvent + partial, finish: cancel);
      expect(r.content, 'hello');
      expect(r.callerError, isA<CancelledException>());
      expect(r.callbackError, isA<CancelledException>());
      expect(r.bodyReleased, isTrue);
    });

    test('normal_completion', () async {
      final r = await run(data: validEvent, finish: endBody);
      expect(r.content, 'hello');
      expect(r.callerError, isNull);
      expect(r.callbackError, isNull);
    });
  });
}
