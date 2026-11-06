// Ports of eino-ext components/model/claude tests that go through the model
// (claude_test.go, message_extra_test.go). The Go tests mock the SDK with
// mockey; here a fake HTTP client answers with recorded-shape JSON.
//   TestDirectAnthropicAuthSelection ("config auth exists", "missing auth
//   still allows creation"), TestClaude ("basic chat", "function calling",
//   "image processing"), TestWithTools, TestGetCallbackOutputNoExtra.
// Not ported:
//   * TestDirectAnthropicAuthSelection "env auth exists": nothing is read
//     from the environment.
//   * TestClaude "image processing" used the deprecated MultiContent with a
//     data URL; ported with UserInputMultiContent and raw base64.
// Plus tests written for the port: HTTP error classification, timeouts,
// transport failures, cancellation, callbacks, withTools sharing the client,
// dispose, per-call headers and timeout.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_config.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_message_extras.dart';
import 'package:threepio_core/src/components/model/providers/claude/claude_options.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../../../support/log_capture.dart';
import 'claude_fixtures.dart';

final _weatherTool = ToolInfo.fromJsonSchema(
  name: 'get_weather',
  desc: 'Get weather information',
  schema: const JSONSchema(
    properties: {'city': JSONSchemaProperty(type: 'string')},
  ),
);

/// Records every callback with its payload.
final class _Recorder extends ComponentCallbackHandler {
  final List<String> timings = [];
  final List<RunInfo> infos = [];
  ModelCallbackInput? input;
  ModelCallbackOutput? output;
  Object? error;
  final List<ModelCallbackOutput?> chunks = [];
  final Completer<void> streamDone = Completer<void>();

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    timings.add('start');
    infos.add(info);
    this.input = ModelCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    timings.add('end');
    this.output = ModelCallbackOutput.from(output);
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    timings.add('error');
    this.error = error;
    return ctx;
  }

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    timings.add('endStream');
    unawaited(() async {
      try {
        for (final chunk in await output.collectAll()) {
          chunks.add(ModelCallbackOutput.from(chunk));
        }
      } on Object catch (error) {
        this.error = error;
      } finally {
        await output.close();
        streamDone.complete();
      }
    }());
    return ctx;
  }
}

ChatModelOptions _with(ComponentCallbackHandler handler) => ChatModelOptions(
      runContext: RunContext.background().withHandlers([handler]),
    );

Matcher _claudeError({
  int? status,
  bool retryable = false,
  bool unavailable = false,
  String? type,
}) =>
    isA<ClaudeException>()
        .having((e) => e.statusCode, 'statusCode', status)
        .having((e) => e.isRetryable, 'isRetryable', retryable)
        .having((e) => e.isModelUnavailable, 'isModelUnavailable', unavailable)
        .having((e) => e.errorType, 'errorType', type);

String _errorBody(String type, String message) => jsonEncode({
      'type': 'error',
      'error': {'type': type, 'message': message},
      'request_id': 'req_011CSHoEeqs5C35K2UUqR7Fy',
    });

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('TestDirectAnthropicAuthSelection', () {
    test('config auth exists', () async {
      for (final (config, key, token) in [
        (const ClaudeConfig(apiKey: 'api-key', model: testModel, maxTokens: 1),
            'api-key', null),
        (const ClaudeConfig(authToken: 'auth-token', model: testModel, maxTokens: 1),
            null, 'Bearer auth-token'),
        (
          const ClaudeConfig(
            apiKey: 'api-key',
            authToken: 'auth-token',
            model: testModel,
            maxTokens: 1,
          ),
          'api-key',
          'Bearer auth-token',
        ),
      ]) {
        final fake = FakeAnthropic.json(messageResponse([textBlock('ok')]));
        await ClaudeChatModel(config: config, httpClient: fake)
            .generate([Message.user('hi')]);
        final headers = fake.requests.single.headers;
        expect(headers['x-api-key'], key);
        expect(headers['authorization'], token);
        expect(headers['anthropic-version'], '2023-06-01');
        expect(headers['content-type'], 'application/json');
      }
    });

    test('missing auth still allows creation', () async {
      final fake = FakeAnthropic.json(messageResponse([textBlock('ok')]));
      final model = ClaudeChatModel(
        config: const ClaudeConfig(model: testModel, maxTokens: 1),
        httpClient: fake,
      );
      await model.generate([Message.user('hi')]);
      expect(fake.requests.single.headers.containsKey('x-api-key'), isFalse);
      expect(fake.requests.single.headers.containsKey('authorization'), isFalse);
    });

    test('a model is required', () {
      expect(
        () => ClaudeChatModel(
          config: const ClaudeConfig(model: '', maxTokens: 1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('TestClaude', () {
    test('basic chat', () async {
      final fake = FakeAnthropic.json(
        messageResponse(
          [textBlock("Hello, I'm Claude!")],
          usage: {
            'input_tokens': 10,
            'output_tokens': 5,
            'output_tokens_details': {'thinking_tokens': 3},
          },
        ),
      );
      final model = ClaudeChatModel(config: testConfig, httpClient: fake);

      final response = await model.generate(
        [Message.user('Hi, who are you?')],
        options: const ClaudeRequestOptions(topK: 5).toOptions(),
      );

      expect(response.content, "Hello, I'm Claude!");
      expect(response.role, RoleType.assistant);
      expect(response.responseMeta!.finishReason, 'end_turn');
      expect(response.responseMeta!.usage!.promptTokens, 10);
      expect(response.responseMeta!.usage!.completionTokens, 5);
      expect(
        response.responseMeta!.usage!.completionTokenDetails!.reasoningTokens,
        3,
      );
      expect(fake.requests.single.method, 'POST');
      expect(
        fake.requests.single.url,
        Uri.parse('https://api.anthropic.com/v1/messages'),
      );
      expect(fake.body['top_k'], 5);
      expect(fake.body['model'], testModel);
      expect(fake.body['max_tokens'], 1024);
    });

    test('function calling', () async {
      final fake = FakeAnthropic.json(
        messageResponse(
          [toolUseBlock('call_1', 'get_weather', {'city': 'Paris'})],
          stopReason: 'tool_use',
        ),
      );
      final model = ClaudeChatModel(config: testConfig, httpClient: fake)
          .withTools([_weatherTool]);

      final response =
          await model.generate([Message.user("What's the weather in Paris?")]);

      expect(response.toolCalls, hasLength(1));
      expect(response.toolCalls![0].id, 'call_1');
      expect(response.toolCalls![0].function.name, 'get_weather');
      expect(response.toolCalls![0].function.arguments, '{"city":"Paris"}');
      expect(response.responseMeta!.finishReason, 'tool_use');
      expect((fake.body['tools']! as List).single, {
        'name': 'get_weather',
        'description': 'Get weather information',
        'input_schema': {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
        },
      });
      expect(fake.body['tool_choice'], {'type': 'auto'});
    });

    test('image processing', () async {
      final fake =
          FakeAnthropic.json(messageResponse([textBlock('I see a beautiful sunset image')]));
      final model = ClaudeChatModel(config: testConfig, httpClient: fake);

      final response = await model.generate([
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.text("What's in this image?"),
            const MessageInputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessageInputImage(
                common: MessagePartCommon(
                  base64Data: '/9j/4AAQSkZ',
                  mimeType: 'image/jpeg',
                ),
              ),
            ),
          ],
        ),
      ]);

      expect(response.content, 'I see a beautiful sunset image');
      final content =
          ((fake.body['messages']! as List).single as Map)['content'] as List;
      expect(content[1], {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/jpeg',
          'data': '/9j/4AAQSkZ',
        },
      });
    });
  });

  group('TestWithTools', () {
    test('a copy with the tools bound', () {
      final model = ClaudeChatModel(
        config: const ClaudeConfig(model: 'test model', maxTokens: 1),
      );
      final bound = model.withTools([
        ToolInfo.function(name: 'test tool name'),
      ]) as ClaudeChatModel;
      expect(bound.config.model, 'test model');
      expect(bound.tools!.single.name, 'test tool name');
      expect(model.tools, isNull);
      expect(bound.componentTypeName, 'Claude');
      expect(bound.isCallbacksEnabled, isTrue);
    });

    test('no tools to bind', () {
      final model = ClaudeChatModel(config: testConfig);
      expect(() => model.withTools(const []), throwsArgumentError);
    });

    test('withTools shares the client; dispose closes only its own', () async {
      final fake = FakeAnthropic.json(messageResponse([textBlock('ok')]));
      final model = ClaudeChatModel(config: testConfig, httpClient: fake);
      final bound = model.withTools([_weatherTool]);
      await bound.generate([Message.user('hi')]);
      await model.generate([Message.user('hi')]);
      expect(fake.requests, hasLength(2));

      model.dispose();
      expect(fake.isClosed, isFalse, reason: "an injected client is the caller's");
      await expectLater(
        bound.generate([Message.user('hi')]),
        throwsStateError,
      );
      await expectLater(
        model.stream([Message.user('hi')]),
        throwsStateError,
      );
      expect(fake.requests, hasLength(2));
      model.dispose(); // repeatable
    });

    test('a model without an injected client can be disposed unused', () {
      final model = ClaudeChatModel(config: testConfig);
      final bound = model.withTools([_weatherTool]) as ClaudeChatModel;
      model.dispose();
      expect(
        bound.generate([Message.user('hi')]),
        throwsStateError,
      );
    });
  });

  group('HTTP errors (port)', () {
    Future<Object> failure(
      int status,
      String body, {
      Map<String, String> headers = const {},
    }) async {
      final model = ClaudeChatModel(
        config: testConfig,
        httpClient: FakeAnthropic.raw(body, status: status, headers: headers),
      );
      try {
        await model.generate([Message.user('hi')]);
      } catch (error) {
        return error;
      }
      fail('no error');
    }

    test('429 rate_limit_error is retryable', () async {
      final error = await failure(
        429,
        _errorBody('rate_limit_error', 'Number of requests has exceeded your rate limit'),
        headers: {'request-id': 'req_1'},
      );
      expect(
        error,
        _claudeError(status: 429, retryable: true, type: 'rate_limit_error'),
      );
      final claude = error as ClaudeException;
      expect(claude.isRateLimited, isTrue);
      expect(claude.requestId, 'req_1');
      expect(claude.message, contains('rate limit'));
      expect(claude, isA<ChatModelException>());
      expect(claude.toString(), contains('(status: 429)'));
    });

    test('529 overloaded_error is retryable', () async {
      final error =
          await failure(529, _errorBody('overloaded_error', 'Overloaded'));
      expect(
        error,
        _claudeError(status: 529, retryable: true, type: 'overloaded_error'),
      );
      expect((error as ClaudeException).isOverloaded, isTrue);
      expect(error.requestId, 'req_011CSHoEeqs5C35K2UUqR7Fy');
    });

    test('500 api_error and 409 are retryable', () async {
      expect(
        await failure(500, _errorBody('api_error', 'Internal server error')),
        _claudeError(status: 500, retryable: true, type: 'api_error'),
      );
      expect(
        await failure(409, 'conflict'),
        _claudeError(status: 409, retryable: true),
      );
    });

    test('404 not_found_error means the model is unavailable', () async {
      expect(
        await failure(
          404,
          _errorBody('not_found_error', 'model: claude-nonexistent'),
        ),
        _claudeError(status: 404, unavailable: true, type: 'not_found_error'),
      );
    });

    test('only 404 or not_found_error means unavailable', () async {
      expect(
        await failure(
          400,
          _errorBody('invalid_request_error', 'tool foo does not exist'),
        ),
        _claudeError(status: 400, type: 'invalid_request_error'),
      );
      expect(
        ClaudeException.fromStreamError(
          _errorBody('invalid_request_error', 'model not found'),
        ).isModelUnavailable,
        isFalse,
      );
      expect(
        ClaudeException.fromStreamError(
          _errorBody('not_found_error', 'model: x'),
        ).isModelUnavailable,
        isTrue,
      );
      expect(await failure(404, 'gone'), _claudeError(status: 404, unavailable: true));
    });

    test('400 invalid_request_error is neither', () async {
      final error = await failure(
        400,
        _errorBody('invalid_request_error', 'max_tokens: Field required'),
      );
      expect(
        error,
        _claudeError(status: 400, type: 'invalid_request_error'),
      );
      expect((error as ClaudeException).responseBody, contains('max_tokens'));
    });

    test('x-should-retry overrides the status, as in the Go SDK', () async {
      expect(
        await failure(
          400,
          _errorBody('invalid_request_error', 'x'),
          headers: {'x-should-retry': 'true'},
        ),
        _claudeError(status: 400, retryable: true, type: 'invalid_request_error'),
      );
      expect(
        await failure(
          503,
          'unavailable',
          headers: {'x-should-retry': 'false'},
        ),
        _claudeError(status: 503),
      );
    });

    test('a 200 response that is not a message is not retryable', () async {
      expect(await failure(200, 'not json'), _claudeError());
      expect(
        await failure(200, jsonEncode(messageResponse([{'type': 'hologram'}]))),
        isA<ClaudeException>().having(
          (e) => e.message,
          'message',
          contains('unknown anthropic content block type: hologram'),
        ),
      );
    });

    test('a transport failure is retryable', () async {
      final model = ClaudeChatModel(
        config: testConfig,
        httpClient: FakeAnthropic(
          (request) => throw http.ClientException('connection reset'),
        ),
      );
      await expectLater(
        model.generate([Message.user('hi')]),
        throwsA(
          isA<ClaudeException>()
              .having((e) => e.isRetryable, 'isRetryable', true)
              .having((e) => e.cause, 'cause', isA<http.ClientException>()),
        ),
      );
    });

    test('a timeout is retryable; a call can shorten it', () async {
      final never = Completer<http.StreamedResponse>();
      final model = ClaudeChatModel(
        config: testConfig,
        httpClient: FakeAnthropic((request) => never.future),
      );
      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: const ClaudeRequestOptions(
            requestTimeout: Duration(milliseconds: 10),
          ).toOptions(),
        ),
        throwsA(
          isA<ClaudeException>()
              .having((e) => e.isRetryable, 'isRetryable', true)
              .having((e) => e.message, 'message', contains('timed out')),
        ),
      );
    });

    test('invalid input fails before any request', () async {
      final fake = FakeAnthropic.json(messageResponse([textBlock('ok')]));
      final model = ClaudeChatModel(config: testConfig, httpClient: fake);
      await expectLater(
        model.generate([Message.system('only system')]),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: const ChatModelOptions(toolChoice: ToolChoice.forced),
        ),
        throwsArgumentError,
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('cancellation (port)', () {
    test('a cancelled token stops the call before it is sent', () async {
      final fake = FakeAnthropic.json(messageResponse([textBlock('never')]));
      final model = ClaudeChatModel(config: testConfig, httpClient: fake);
      final token = CancelToken()..cancel('stop');
      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: ChatModelOptions(cancelToken: token),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(fake.requests, isEmpty);
    });

    test('cancelling while waiting for the response', () async {
      final answered = Completer<http.StreamedResponse>();
      final sent = Completer<void>();
      final model = ClaudeChatModel(
        config: testConfig,
        httpClient: FakeAnthropic((request) {
          sent.complete();
          return answered.future;
        }),
      );
      final ctx = RunContext.background();
      final call = model.generate(
        [Message.user('hi')],
        options: ChatModelOptions(runContext: ctx),
      );
      await sent.future;
      ctx.cancelToken.cancel('user');
      await expectLater(
        call,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'user'),
        ),
      );
    });
  });

  group('callbacks (port)', () {
    test('generate reports start and end with the typed payloads', () async {
      final recorder = _Recorder();
      final fake = FakeAnthropic.json(
        messageResponse(
          [textBlock('hello')],
          usage: {
            'input_tokens': 7,
            'cache_creation_input_tokens': 2048,
            'output_tokens': 3,
          },
        ),
      );
      final model = ClaudeChatModel(
        config: const ClaudeConfig(
          apiKey: 'test-key',
          model: testModel,
          maxTokens: 64,
          temperature: 0.2,
        ),
        httpClient: fake,
      ).withTools([_weatherTool]);
      final messages = [Message.user('hi')];

      final answer = await model.generate(messages, options: _with(recorder));

      expect(recorder.timings, ['start', 'end']);
      expect(
        recorder.infos.single,
        const RunInfo(
          name: '',
          type: 'Claude',
          componentType: ComponentType.chatModel,
        ),
      );
      final input = recorder.input!;
      expect(input.messages, same(messages));
      expect(input.tools!.single.name, 'get_weather');
      expect(input.toolChoice, ToolChoice.allowed);
      expect(input.config!.model, testModel);
      expect(input.config!.maxTokens, 64);
      expect(input.config!.temperature, 0.2);

      final output = recorder.output!;
      expect(output.message, same(answer));
      expect(output.tokenUsage!.promptTokens, 7 + 2048);
      expect(output.tokenUsage!.completionTokens, 3);
      expect(output.tokenUsage!.promptTokenDetails!.cacheWriteTokens, 2048);
    });

    // Port of TestGetCallbackOutputNoExtra: the callback output has no extra,
    // the cache-creation count travels on the message.
    test('TestGetCallbackOutputNoExtra', () async {
      final recorder = _Recorder();
      final model = ClaudeChatModel(
        config: testConfig,
        httpClient: FakeAnthropic.json(
          messageResponse(
            [textBlock('hello')],
            usage: {
              'input_tokens': 100,
              'cache_creation_input_tokens': 2048,
              'output_tokens': 50,
            },
          ),
        ),
      );
      await model.generate([Message.user('hi')], options: _with(recorder));
      expect(recorder.output!.extra, isNull);
      expect(recorder.output!.message!.claudeCacheCreationInputTokens, 2048);
    });

    test('a failed call is reported to the error callback', () async {
      final recorder = _Recorder();
      final model = ClaudeChatModel(
        config: testConfig,
        httpClient: FakeAnthropic.raw(
          _errorBody('overloaded_error', 'Overloaded'),
          status: 529,
        ),
      );
      await expectLater(
        model.generate([Message.user('hi')], options: _with(recorder)),
        throwsA(isA<ClaudeException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<ClaudeException>());
    });

    test('stream reports the chunks to the handler', () async {
      final recorder = _Recorder();
      final model = ClaudeChatModel(
        config: testConfig,
        httpClient: FakeAnthropic.sse(textStream()),
      );
      final reader =
          await model.stream([Message.user('hi')], options: _with(recorder));
      final message = await concatMessageStream(reader);
      await recorder.streamDone.future;

      expect(message.content, 'Hello!');
      expect(recorder.timings, ['start', 'endStream']);
      expect(recorder.infos.single.type, 'Claude');
      expect(recorder.error, isNull);
      expect(
        recorder.chunks.map((c) => c!.message!.content).join(),
        'Hello!',
      );
      expect(
        recorder.chunks.last!.message!.responseMeta!.finishReason,
        'end_turn',
      );
    });
  });

  test('per-call custom headers are added to the config ones (port)', () async {
    final fake = FakeAnthropic.json(messageResponse([textBlock('ok')]));
    final model = ClaudeChatModel(
      config: const ClaudeConfig(
        apiKey: 'test-key',
        model: testModel,
        maxTokens: 1,
        additionalHeaderFields: {'anthropic-beta': 'a'},
      ),
      httpClient: fake,
    );
    await model.generate(
      [Message.user('hi')],
      options: const ClaudeRequestOptions(
        customHeaders: {'anthropic-beta': 'b'},
      ).applyTo(const ChatModelOptions(temperature: 0.3)),
    );
    expect(fake.requests.single.headers['anthropic-beta'], 'a, b');
    expect(fake.body['temperature'], 0.3);
  });
}
