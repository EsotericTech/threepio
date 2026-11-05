// One cancel token per model call (plan §3.2 rule 3): a call can be cancelled
// through `ChatModelOptions.cancelToken`, through the token of
// `ChatModelOptions.runContext`, or through both.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/internal/call_cancellation.dart';
import 'package:threepio_core/threepio_core.dart';

String _sseLine(Map<String, dynamic> delta, {String? finish}) =>
    'data: ${jsonEncode({
          'id': 'gen-1',
          'choices': [
            {
              'index': 0,
              'delta': delta,
              if (finish != null) 'finish_reason': finish,
            },
          ],
        })}\n\n';

const _config = OpenRouterConfig(apiKey: 'k', defaultModel: 'z-ai/glm-5.3');

/// A model whose streamed body the test writes line by line.
({OpenRouterChatModel model, StreamController<List<int>> body, List<String> requests})
    _streamingModel() {
  final body = StreamController<List<int>>();
  final requests = <String>[];
  final client = MockClient.streaming((request, bodyStream) async {
    requests.add(await bodyStream.bytesToString());
    return http.StreamedResponse(body.stream, 200);
  });
  return (
    model: OpenRouterChatModel(config: _config, httpClient: client),
    body: body,
    requests: requests,
  );
}

/// A model that answers every request with [completion].
({OpenRouterChatModel model, List<Map<String, dynamic>> requests})
    _completingModel({String content = 'ok'}) {
  final requests = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    requests.add(jsonDecode(request.body) as Map<String, dynamic>);
    return http.Response(
      jsonEncode({
        'id': 'gen-1',
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': content},
            'finish_reason': 'stop',
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return (
    model: OpenRouterChatModel(config: _config, httpClient: client),
    requests: requests,
  );
}

void main() {
  group('CallCancellation', () {
    test('without a token the call cannot be cancelled', () {
      final cancellation = CallCancellation(null, null);
      expect(cancellation.token, isNull);
      cancellation.release();

      expect(CallCancellation.of(null).token, isNull);
      expect(CallCancellation.of(const ChatModelOptions()).token, isNull);
    });

    test('a single token is used as it is, and release leaves it alone', () {
      final token = CancelToken();

      for (final cancellation in [
        CallCancellation(token, null),
        CallCancellation(null, token),
        CallCancellation(token, token),
        CallCancellation.of(ChatModelOptions(cancelToken: token)),
        CallCancellation.of(
          ChatModelOptions(runContext: RunContext.background(cancelToken: token)),
        ),
      ]) {
        expect(cancellation.token, same(token));
        cancellation.release();
        expect(token.isCancelled, isFalse);
      }
    });

    test('two tokens become one that either of them cancels', () {
      for (final cancelFirst in [true, false]) {
        final fromOptions = CancelToken();
        final fromContext = CancelToken();
        final cancellation = CallCancellation.of(
          ChatModelOptions(
            cancelToken: fromOptions,
            runContext: RunContext.background(cancelToken: fromContext),
          ),
        );
        final token = cancellation.token!;
        expect(token, isNot(same(fromOptions)));
        expect(token, isNot(same(fromContext)));
        expect(token.isCancelled, isFalse);

        (cancelFirst ? fromOptions : fromContext).cancel('stop');

        expect(token.isCancelled, isTrue);
        expect(token.reason, 'stop');
        expect(() => token.throwIfCancelled(), throwsA(isA<CancelledException>()));
      }
    });

    test('release lets go of the combined token without touching the two',
        () {
      final fromOptions = CancelToken();
      final fromContext = CancelToken();
      final cancellation = CallCancellation(fromOptions, fromContext);
      final token = cancellation.token!;

      cancellation.release();

      expect(token.isCancelled, isTrue, reason: 'released by cancelling it');
      expect(fromOptions.isCancelled, isFalse);
      expect(fromContext.isCancelled, isFalse);

      // The released token no longer follows its sources.
      fromOptions.cancel('later');
      expect(token.reason, 'call finished');

      cancellation.release();
    });

    test('a token that is already cancelled cancels the call at once', () {
      final cancelled = CancelToken()..cancel('too late');
      final cancellation = CallCancellation(CancelToken(), cancelled);

      expect(cancellation.token!.isCancelled, isTrue);
      expect(cancellation.token!.reason, 'too late');
      cancellation.release();
      expect(cancelled.reason, 'too late');
    });
  });

  group('OpenRouterChatModel listens to the token of the run context', () {
    test('generate does not send a request under a cancelled context',
        () async {
      final setup = _completingModel();
      final token = CancelToken()..cancel('stopped before the call');

      await expectLater(
        setup.model.generate(
          [Message.user('hi')],
          options: ChatModelOptions(
            runContext: RunContext.background(cancelToken: token),
          ),
        ),
        throwsA(
          isA<CancelledException>()
              .having((e) => e.reason, 'reason', 'stopped before the call'),
        ),
      );
      expect(setup.requests, isEmpty);
    });

    test('cancelling the context ends a stream with CancelledException',
        () async {
      final setup = _streamingModel();
      final token = CancelToken();
      final reader = await setup.model.stream(
        [Message.user('hi')],
        options: ChatModelOptions(
          runContext: RunContext.background(cancelToken: token),
        ),
      );

      setup.body.add(utf8.encode(_sseLine({'content': 'a'})));
      expect((await reader.recv()).content, 'a');

      token.cancel('user pressed stop');

      await expectLater(
        reader.recv(),
        throwsA(
          isA<CancelledException>()
              .having((e) => e.reason, 'reason', 'user pressed stop'),
        ),
      );
      await reader.close();
      await setup.body.close();
    });

    test('with a token in the options and one in the context, either stops '
        'the stream', () async {
      for (final cancelOptionsToken in [true, false]) {
        final setup = _streamingModel();
        final fromOptions = CancelToken();
        final fromContext = CancelToken();
        final reader = await setup.model.stream(
          [Message.user('hi')],
          options: ChatModelOptions(
            cancelToken: fromOptions,
            runContext: RunContext.background(cancelToken: fromContext),
          ),
        );

        setup.body.add(utf8.encode(_sseLine({'content': 'a'})));
        expect((await reader.recv()).content, 'a');

        (cancelOptionsToken ? fromOptions : fromContext).cancel('stop');

        await expectLater(reader.recv(), throwsA(isA<CancelledException>()));
        // Only the token that was cancelled is cancelled.
        expect(fromOptions.isCancelled, cancelOptionsToken);
        expect(fromContext.isCancelled, !cancelOptionsToken);
        await reader.close();
        await setup.body.close();
      }
    });

    test('a call that finishes leaves the tokens of the caller untouched',
        () async {
      final fromOptions = CancelToken();
      final fromContext = CancelToken();
      final options = ChatModelOptions(
        cancelToken: fromOptions,
        runContext: RunContext.background(cancelToken: fromContext),
      );

      final completing = _completingModel();
      expect(
        (await completing.model.generate([Message.user('hi')], options: options))
            .content,
        'ok',
      );

      final streaming = _streamingModel();
      final reader =
          await streaming.model.stream([Message.user('hi')], options: options);
      streaming.body
        ..add(utf8.encode(_sseLine({'content': 'a'}, finish: 'stop')))
        ..add(utf8.encode('data: [DONE]\n\n'));
      expect((await reader.collectAll()).map((m) => m.content), ['a']);
      await streaming.body.close();

      expect(fromOptions.isCancelled, isFalse);
      expect(fromContext.isCancelled, isFalse);

      // And they still work for the next call.
      fromContext.cancel('now');
      await expectLater(
        completing.model.generate([Message.user('again')], options: options),
        throwsA(isA<CancelledException>()),
      );
    });

    test('a request that fails leaves the tokens of the caller untouched',
        () async {
      final fromOptions = CancelToken();
      final fromContext = CancelToken();
      final failing = OpenRouterChatModel(
        config: _config,
        httpClient: MockClient((_) async => http.Response('{"error": {}}', 500)),
      );
      final options = ChatModelOptions(
        cancelToken: fromOptions,
        runContext: RunContext.background(cancelToken: fromContext),
      );

      await expectLater(
        failing.generate([Message.user('hi')], options: options),
        throwsA(isA<OpenRouterException>()),
      );
      await expectLater(
        failing.stream([Message.user('hi')], options: options),
        throwsA(isA<OpenRouterException>()),
      );

      expect(fromOptions.isCancelled, isFalse);
      expect(fromContext.isCancelled, isFalse);
    });
  });

  group('RetryingChatModel', () {
    test('a context cancelled during the back-off ends the retries', () async {
      final token = CancelToken();
      var attempts = 0;
      final retrying = RetryingChatModel(
        _FailingModel(() {
          attempts++;
          return OpenRouterException('busy', statusCode: 429, isRetryable: true);
        }),
        maxAttempts: 5,
        // Never waited for: the token is cancelled before the wait starts.
        baseDelay: const Duration(milliseconds: 30),
        maxDelay: const Duration(milliseconds: 30),
        onRetry: (_, __, ___) => token.cancel('gave up'),
      );

      await expectLater(
        retrying.generate(
          [Message.user('x')],
          options: ChatModelOptions(
            runContext: RunContext.background(cancelToken: token),
          ),
        ),
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'gave up'),
        ),
      );
      expect(attempts, 1);
    });

    test('with two tokens, the back-off ends when either is cancelled',
        () async {
      for (final cancelOptionsToken in [true, false]) {
        final fromOptions = CancelToken();
        final fromContext = CancelToken();
        var attempts = 0;
        final retrying = RetryingChatModel(
          _FailingModel(() {
            attempts++;
            return OpenRouterException('busy', statusCode: 429, isRetryable: true);
          }),
          baseDelay: const Duration(milliseconds: 30),
          maxDelay: const Duration(milliseconds: 30),
          onRetry: (_, __, ___) =>
              (cancelOptionsToken ? fromOptions : fromContext).cancel('stop'),
        );

        await expectLater(
          retrying.generate(
            [Message.user('x')],
            options: ChatModelOptions(
              cancelToken: fromOptions,
              runContext: RunContext.background(cancelToken: fromContext),
            ),
          ),
          throwsA(isA<CancelledException>()),
        );
        expect(attempts, 1);
        expect(fromOptions.isCancelled, cancelOptionsToken);
        expect(fromContext.isCancelled, !cancelOptionsToken);
      }
    });

    test('retries that succeed leave the tokens of the caller untouched',
        () async {
      final fromOptions = CancelToken();
      final fromContext = CancelToken();
      var attempts = 0;
      final retrying = RetryingChatModel(
        _FlakyModel(() {
          attempts++;
          if (attempts < 3) {
            throw OpenRouterException('busy', statusCode: 429, isRetryable: true);
          }
          return Message.assistant('ok');
        }),
        baseDelay: const Duration(milliseconds: 1),
      );

      final answer = await retrying.generate(
        [Message.user('x')],
        options: ChatModelOptions(
          cancelToken: fromOptions,
          runContext: RunContext.background(cancelToken: fromContext),
        ),
      );

      expect(answer.content, 'ok');
      expect(attempts, 3);
      expect(fromOptions.isCancelled, isFalse);
      expect(fromContext.isCancelled, isFalse);
    });
  });

  group('OpenRouterRequestOptions as an extension', () {
    test('toOptions puts itself into the extensions', () {
      const requestOptions =
          OpenRouterRequestOptions(reasoningEffort: ReasoningEffort.low);

      final options = requestOptions.toOptions(model: 'm', temperature: 0.2);

      expect(options.extension<OpenRouterRequestOptions>(), same(requestOptions));
      expect(options.model, 'm');
      expect(options.temperature, 0.2);
      // As before, the fields are also in `extra`.
      expect(options.extra, {
        'reasoning': {'effort': 'low'},
        'usage': {'include': true},
      });
    });

    test('applyTo adds itself ahead of the extensions that are there', () {
      const earlier = OpenRouterRequestOptions(parallelToolCalls: false);
      const later = OpenRouterRequestOptions(parallelToolCalls: true);

      final options = later.applyTo(earlier.toOptions(model: 'm'));

      expect(options.extension<OpenRouterRequestOptions>(), same(later));
      expect(options.extensions, [later, earlier]);
      expect(options.extra?['parallel_tool_calls'], isTrue);
      expect(options.model, 'm');
    });

    test('the model sends the fields of an extension given directly',
        () async {
      final setup = _completingModel();

      await setup.model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(
          temperature: 0.3,
          extensions: [
            OpenRouterRequestOptions(
              reasoningEffort: ReasoningEffort.high,
              modalities: [OutputModality.text],
              includeUsage: false,
            ),
          ],
        ),
      );

      final body = setup.requests.single;
      expect(body['temperature'], 0.3);
      expect(body['reasoning'], {'effort': 'high'});
      expect(body['modalities'], ['text']);
    });

    test('per-call extra still wins over the extension', () async {
      final setup = _completingModel();

      await setup.model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(
          extra: {
            'reasoning': {'effort': 'none'},
          },
          extensions: [
            OpenRouterRequestOptions(reasoningEffort: ReasoningEffort.high),
          ],
        ),
      );

      expect(setup.requests.single['reasoning'], {'effort': 'none'});
    });

    test('options built with toOptions send the same request as before',
        () async {
      final setup = _completingModel();

      await setup.model.generate(
        [Message.user('hi')],
        options: const OpenRouterRequestOptions(
          reasoningEffort: ReasoningEffort.medium,
        ).toOptions(model: 'z-ai/glm-5.3'),
      );

      final body = setup.requests.single;
      expect(body['model'], 'z-ai/glm-5.3');
      expect(body['reasoning'], {'effort': 'medium'});
      expect(body['usage'], {'include': true});
    });

    test('an extension of another provider is ignored', () async {
      final setup = _completingModel();

      await setup.model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(extensions: ['not for OpenRouter', 42]),
      );

      expect(setup.requests.single.containsKey('reasoning'), isFalse);
    });
  });
}

/// A model whose every call fails with the error [next] returns.
class _FailingModel extends ToolCallingChatModel {
  _FailingModel(this.next);

  final Object Function() next;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async =>
      throw next();

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      throw next();

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// A model that answers with what [respond] returns or throws.
class _FlakyModel extends ToolCallingChatModel {
  _FlakyModel(this.respond);

  final Message Function() respond;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async =>
      respond();

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([respond()]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}
