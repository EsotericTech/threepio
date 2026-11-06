// Tests written for the port: the transport half of eino-ext's
// libs/acl/openai `Client` (`Generate`, `Stream`), which go-openai does in
// Go and `OpenAICompatibleClient` does here. Pinned: the payload, response
// and chunk modifiers (including the end call of the chunk modifier), the
// merging of empty chunks into the next one (Go `lastEmptyMsg`), the request
// id kept once per stream, error chunks mapped to classified exceptions,
// malformed lines skipped, `[DONE]`, the usage-only chunk, HTTP and
// transport failures, the idle timeout, cancellation and the release of the
// call's cancellation when the stream ends.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/openai_compatible/client.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_chat_model.dart'
    show OpenAIExceptionErrors;
import 'package:threepio_core/src/components/model/providers/openai/openai_options.dart';
import 'package:threepio_core/src/internal/call_cancellation.dart';
import 'package:threepio_core/src/internal/shared_http_client.dart';
import 'package:threepio_core/threepio_core.dart';

final _url = Uri.parse('https://api.example.com/v1/chat/completions');

const _headers = {
  'Content-Type': 'application/json',
  'Authorization': 'Bearer test-key',
};

const _requestBody = <String, Object?>{
  'model': 'test-model',
  'messages': [
    {'role': 'user', 'content': 'hi'},
  ],
};

final _input = [Message.user('hi')];

OpenAICompatibleClient _client(
  http.Client http, {
  bool mergeEmptyChunks = true,
  String? requestIdKey = openAIRequestIdKey,
  Duration? idleTimeout,
  Duration timeout = const Duration(seconds: 5),
  SharedHttpClient? shared,
}) =>
    OpenAICompatibleClient(
      http: shared ?? SharedHttpClient(http, owner: 'test'),
      errors: const OpenAIExceptionErrors(),
      timeout: timeout,
      idleTimeout: idleTimeout,
      mergeEmptyChunks: mergeEmptyChunks,
      requestIdKey: requestIdKey,
    );

/// Records the bodies sent; answers with [response].
http.Client _json(List<Map<String, Object?>> sent, Object response, {int status = 200}) =>
    MockClient((request) async {
      sent.add(jsonDecode(request.body) as Map<String, Object?>);
      return http.Response(
        response is String ? response : jsonEncode(response),
        status,
        headers: const {'content-type': 'application/json'},
      );
    });

http.Client _sse(List<String> chunks, {int status = 200, List<Map<String, Object?>>? sent}) =>
    MockClient.streaming((request, bytes) async {
      final text = await bytes.bytesToString();
      sent?.add(jsonDecode(text) as Map<String, Object?>);
      return http.StreamedResponse(
        Stream.fromIterable([for (final c in chunks) utf8.encode(c)]),
        status,
      );
    });

/// A streamed body the test feeds line by line.
final class _LiveBody {
  _LiveBody() {
    controller = StreamController<List<int>>(
      onCancel: () async => cancelled = true,
    );
  }

  late final StreamController<List<int>> controller;
  bool cancelled = false;

  http.Client get client => MockClient.streaming(
        (request, bytes) async => http.StreamedResponse(controller.stream, 200),
      );

  void add(String text) => controller.add(utf8.encode(text));
}

String _data(Object chunk) => 'data: ${jsonEncode(chunk)}\n\n';

const _done = 'data: [DONE]\n\n';

Map<String, Object?> _chunk(
  Map<String, Object?> delta, {
  String? finish,
  String? id = 'chatcmpl-1',
  Map<String, Object?>? usage,
}) =>
    {
      if (id != null) 'id': id,
      'object': 'chat.completion.chunk',
      'created': 1735689600,
      'model': 'test-model',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
      if (usage != null) 'usage': usage,
    };

Map<String, Object?> _completion(String content, {String? id = 'chatcmpl-9'}) => {
      if (id != null) 'id': id,
      'object': 'chat.completion',
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': content},
          'finish_reason': 'stop',
        },
      ],
      'usage': {'prompt_tokens': 3, 'completion_tokens': 1, 'total_tokens': 4},
    };

Future<StreamReader<Message>> _stream(
  OpenAICompatibleClient client, {
  CallCancellation? cancellation,
  RequestPayloadModifier? payloadModifier,
  ResponseChunkMessageModifier? chunkModifier,
  RunContext? runContext,
}) =>
    client.stream(
      _url,
      headers: _headers,
      body: _requestBody,
      input: _input,
      cancellation: cancellation ?? CallCancellation(null, null),
      runContext: runContext,
      payloadModifier: payloadModifier,
      chunkModifier: chunkModifier,
    );

final class _Failure {
  _Failure(this.error);
  final Object error;
}

Future<List<Object>> _drain(StreamReader<Message> reader) async {
  final out = <Object>[];
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

Matcher _openAIError(Object? message, {bool? retryable, bool? unavailable}) =>
    isA<OpenAIException>()
        .having((e) => e.message, 'message', message)
        .having((e) => e.isRetryable, 'isRetryable', retryable ?? anything)
        .having(
          (e) => e.isModelUnavailable,
          'isModelUnavailable',
          unavailable ?? anything,
        );

void main() {
  group('generate', () {
    test('posts the body with the headers and parses the response', () async {
      final sent = <Map<String, Object?>>[];
      late http.Request request;
      final client = _client(MockClient((r) async {
        request = r;
        sent.add(jsonDecode(r.body) as Map<String, Object?>);
        return http.Response(jsonEncode(_completion('hello')), 200);
      }));

      final message = await client.generate(
        _url,
        headers: _headers,
        body: _requestBody,
        input: _input,
      );

      expect(request.url, _url);
      expect(request.headers['Authorization'], 'Bearer test-key');
      expect(sent.single, _requestBody);
      expect(message.content, 'hello');
      expect(message.responseMeta!.usage!.totalTokens, 4);
      expect(message.extra, {openAIRequestIdKey: 'chatcmpl-9'});
    });

    test('without a request id key the id is not kept', () async {
      final client = _client(_json([], _completion('x')), requestIdKey: null);
      final message = await client.generate(
        _url,
        headers: _headers,
        body: _requestBody,
        input: _input,
      );
      expect(message.extra, isNull);
    });

    test('the payload modifier sees the run context, the input and the body; '
        'what it returns is sent', () async {
      final sent = <Map<String, Object?>>[];
      final client = _client(_json(sent, _completion('x')));
      final ctx = RunContext.background();

      await client.generate(
        _url,
        headers: _headers,
        body: _requestBody,
        input: _input,
        runContext: ctx,
        payloadModifier: (c, input, body) {
          expect(c, same(ctx));
          expect(input, same(_input));
          expect(body, _requestBody);
          return {'replaced': true};
        },
      );
      expect(sent.single, {'replaced': true});
    });

    test('the response modifier sees the message and the decoded response',
        () async {
      final client = _client(_json([], _completion('x')));
      Map<String, Object?>? raw;
      final message = await client.generate(
        _url,
        headers: _headers,
        body: _requestBody,
        input: _input,
        responseModifier: (ctx, message, body) {
          raw = body;
          return message.copyWith(content: 'changed');
        },
      );
      expect(message.content, 'changed');
      expect(raw!['id'], 'chatcmpl-9');
    });

    test('a status other than 200 is the provider\'s HTTP error', () async {
      final client = _client(
        _json([], '{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}',
            status: 429),
      );
      await expectLater(
        client.generate(_url, headers: _headers, body: _requestBody, input: _input),
        throwsA(
          isA<OpenAIException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.errorCode, 'errorCode', 'rate_limit_exceeded'),
        ),
      );
    });

    test('a body that is not JSON is a failed request', () async {
      final client = _client(_json([], 'not json'));
      await expectLater(
        client.generate(_url, headers: _headers, body: _requestBody, input: _input),
        throwsA(_openAIError(startsWith('Request failed:'), retryable: true)),
      );
    });

    test('a parser failure keeps Go\'s message', () async {
      final client = _client(_json([], {'choices': <Object?>[]}));
      await expectLater(
        client.generate(_url, headers: _headers, body: _requestBody, input: _input),
        throwsA(
          _openAIError('received empty choices from OpenAI API response',
              retryable: false),
        ),
      );
    });

    test('a parser failure is an OpenAIException that is not retryable',
        () async {
      final client = _client(_json([], {'choices': <Object?>[]}));
      await expectLater(
        client.generate(_url, headers: _headers, body: _requestBody, input: _input),
        throwsA(
          _openAIError(contains('received empty choices from OpenAI API response'),
              retryable: false),
        ),
      );
    });

    test('no response within the timeout is a retryable timeout', () async {
      final client = _client(
        MockClient((request) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 5),
      );
      await expectLater(
        client.generate(_url, headers: _headers, body: _requestBody, input: _input),
        throwsA(_openAIError(startsWith('Request timed out'), retryable: true)),
      );
    });

    test('a transport failure is a retryable failed request', () async {
      final client = _client(
        MockClient((request) async => throw http.ClientException('refused')),
      );
      await expectLater(
        client.generate(_url, headers: _headers, body: _requestBody, input: _input),
        throwsA(
          isA<OpenAIException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.cause, 'cause', isA<http.ClientException>()),
        ),
      );
    });

    test('a cancelled call throws the CancelledException itself', () async {
      final client = _client(_json([], _completion('x')));
      await expectLater(
        client.generate(
          _url,
          headers: _headers,
          body: _requestBody,
          input: _input,
          cancelToken: CancelToken()..cancel('stop'),
        ),
        throwsA(isA<CancelledException>()),
      );
    });

    test('a closed HTTP client is a StateError, not a failed request',
        () async {
      final shared = SharedHttpClient(_json([], _completion('x')), owner: 'Model')
        ..close();
      final client = _client(MockClient((r) async => http.Response('', 200)),
          shared: shared);
      await expectLater(
        client.generate(_url, headers: _headers, body: _requestBody, input: _input),
        throwsStateError,
      );
    });
  });

  group('stream', () {
    test('sends the body and streams the messages until [DONE]', () async {
      final sent = <Map<String, Object?>>[];
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': ''})),
        _data(_chunk({'content': 'Hel'})),
        _data(_chunk({'content': 'lo'})),
        _data(_chunk({}, finish: 'stop')),
        _done,
        _data(_chunk({'content': 'never'})),
      ], sent: sent));

      final messages = await (await _stream(client)).collectAll();

      expect(sent.single, _requestBody);
      expect(concatMessages(messages).content, 'Hello');
      expect(concatMessages(messages).responseMeta!.finishReason, 'stop');
    });

    test('an empty message is held back and merged into the next one',
        () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': ''})),
        _data(_chunk({'content': 'Hel'})),
        _data(_chunk({'content': 'lo'}, finish: 'stop')),
        _done,
      ]));

      final messages = await (await _stream(client)).collectAll();

      expect(messages.map((m) => m.content), ['Hel', 'lo']);
      expect(messages.first.role, RoleType.assistant);
    });

    test('the empty first frame of parallel tool calls is merged', () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': null})),
        _data(_chunk({
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_a',
              'type': 'function',
              'function': {'name': 'a', 'arguments': ''},
            },
          ],
        })),
        _data(_chunk({
          'tool_calls': [
            {'index': 0, 'function': {'arguments': '{"x":'}},
          ],
        })),
        _data(_chunk({
          'tool_calls': [
            {
              'index': 1,
              'id': 'call_b',
              'type': 'function',
              'function': {'name': 'b', 'arguments': '{}'},
            },
          ],
        })),
        _data(_chunk({
          'tool_calls': [
            {'index': 0, 'function': {'arguments': '1}'}},
          ],
        })),
        _data(_chunk({}, finish: 'tool_calls')),
        _done,
      ]));

      final messages = await (await _stream(client)).collectAll();

      expect(messages.first.toolCalls, isNotEmpty,
          reason: 'the first message tells that this is a tool call');
      final message = concatMessages(messages);
      expect(message.toolCalls, [
        const ToolCall(
          index: 0,
          id: 'call_a',
          type: 'function',
          function: FunctionCall(name: 'a', arguments: '{"x":1}'),
        ),
        const ToolCall(
          index: 1,
          id: 'call_b',
          type: 'function',
          function: FunctionCall(name: 'b', arguments: '{}'),
        ),
      ]);
      expect(message.responseMeta!.finishReason, 'tool_calls');
    });

    test('the last held-back message is sent at the end (usage after finish)',
        () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': 'Hi'})),
        _data(_chunk({}, finish: 'stop')),
        _data({
          'id': 'chatcmpl-1',
          'choices': <Object?>[],
          'usage': {'prompt_tokens': 5, 'completion_tokens': 1, 'total_tokens': 6},
        }),
        _done,
      ]));

      final messages = await (await _stream(client)).collectAll();

      expect(messages, hasLength(2));
      expect(messages.last.content, '');
      expect(messages.last.role, RoleType.assistant);
      expect(messages.last.responseMeta!.finishReason, 'stop');
      expect(messages.last.responseMeta!.usage!.totalTokens, 6);
    });

    test('a reasoning chunk is not empty', () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'reasoning_content': 'Let me think'})),
        _data(_chunk({'content': 'Yes'})),
        _done,
      ]));
      final messages = await (await _stream(client)).collectAll();
      expect(messages.first.reasoningContent, 'Let me think');
      expect(messages, hasLength(2));
    });

    test('without merging every chunk is sent as it comes', () async {
      final client = _client(
        _sse([
          _data(_chunk({'role': 'assistant', 'content': ''})),
          _data(_chunk({'content': 'Hi'})),
          _done,
        ]),
        mergeEmptyChunks: false,
      );
      final messages = await (await _stream(client)).collectAll();
      expect(messages.map((m) => m.content), ['', 'Hi']);
    });

    test('the request id is set once, on the first message', () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': 'a'})),
        _data(_chunk({'content': 'b'})),
        _data(_chunk({'content': 'c'})),
        _done,
      ]));
      final messages = await (await _stream(client)).collectAll();
      expect(messages[0].extra, {openAIRequestIdKey: 'chatcmpl-1'});
      expect(messages[1].extra, isNull);
      expect(messages[2].extra, isNull);
      expect(concatMessages(messages).extra![openAIRequestIdKey], 'chatcmpl-1');
    });

    test('a request id that arrives only on a later chunk is still set once',
        () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': 'a'}, id: null)),
        _data(_chunk({'content': 'b'}, id: 'late')),
        _data(_chunk({'content': 'c'}, id: 'late')),
        _done,
      ]));
      final messages = await (await _stream(client)).collectAll();
      expect([for (final m in messages) m.extra?[openAIRequestIdKey]],
          [null, 'late', null]);
    });

    test('without a request id key no id is set', () async {
      final client = _client(
        _sse([_data(_chunk({'role': 'assistant', 'content': 'a'})), _done]),
        requestIdKey: null,
      );
      final messages = await (await _stream(client)).collectAll();
      expect(messages.single.extra, isNull);
    });

    test('the chunk modifier gets every message with its chunk, then the end '
        'call', () async {
      final calls = <(String?, Object?, bool)>[];
      final first = _chunk({'role': 'assistant', 'content': 'a'});
      final client = _client(_sse([
        _data(first),
        _data(_chunk({}, finish: 'stop')),
        _done,
      ]));
      final ctx = RunContext.background();

      final messages = await (await _stream(
        client,
        runContext: ctx,
        chunkModifier: (c, message, raw, {required end}) {
          expect(c, same(ctx));
          calls.add((message?.content, raw?['id'], end));
          return message?.copyWith(content: '${message.content}!');
        },
      ))
          .collectAll();

      expect(calls, [('a', 'chatcmpl-1', false), ('', null, true)]);
      expect(messages.map((m) => m.content), ['a!', '!']);
      expect(messages.last.responseMeta!.finishReason, 'stop');
    });

    test('the end call gets null when nothing was held back; it may add a '
        'message', () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': 'a'})),
        _done,
      ]));
      final messages = await (await _stream(
        client,
        chunkModifier: (c, message, raw, {required end}) {
          if (!end) return message;
          expect(message, isNull);
          return Message.assistant('tail');
        },
      ))
          .collectAll();
      expect(messages.map((m) => m.content), ['a', 'tail']);
    });

    test('a chunk modifier that returns null drops the message', () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': 'a'})),
        _data(_chunk({'content': 'b'})),
        _done,
      ]));
      final messages = await (await _stream(
        client,
        chunkModifier: (c, message, raw, {required end}) =>
            message?.content == 'a' ? null : message,
      ))
          .collectAll();
      expect(messages.map((m) => m.content), ['b']);
    });

    test('the payload modifier changes what is sent', () async {
      final sent = <Map<String, Object?>>[];
      final client = _client(_sse([_done], sent: sent));
      await (await _stream(
        client,
        payloadModifier: (c, input, body) => {...body, 'stream_options': {'include_usage': false}},
      ))
          .collectAll();
      expect(sent.single['stream_options'], {'include_usage': false});
    });

    test('malformed lines, comments, non-object JSON and blank data are skipped',
        () async {
      final client = _client(_sse([
        ': OPENROUTER PROCESSING\n\n',
        'data: {"choices": [\n\n',
        'data: [1, 2]\n\n',
        'data:    \n\n',
        _data(_chunk({'role': 'assistant', 'content': 'ok'})),
        _done,
      ]));
      final messages = await (await _stream(client)).collectAll();
      expect(messages.single.content, 'ok');
    });

    test('a body without [DONE] and without a final blank line still ends '
        'with its last chunk', () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': 'a'})),
        'data: ${jsonEncode(_chunk({'content': 'b'}))}',
      ]));
      final messages = await (await _stream(client)).collectAll();
      expect(messages.map((m) => m.content), ['a', 'b']);
    });

    test('chunks split across reads are put together', () async {
      final line = _data(_chunk({'role': 'assistant', 'content': 'whole'}));
      final client = _client(_sse([
        line.substring(0, 10),
        line.substring(10, 30),
        line.substring(30),
        _done,
      ]));
      final messages = await (await _stream(client)).collectAll();
      expect(messages.single.content, 'whole');
    });

    test('a usage-only chunk is a message that holds the usage', () async {
      final client = _client(_sse([
        _data({
          'id': 'chatcmpl-1',
          'choices': <Object?>[],
          'usage': {
            'prompt_tokens': 9,
            'completion_tokens': 3,
            'total_tokens': 12,
            'prompt_tokens_details': {'cached_tokens': 4},
            'completion_tokens_details': {'reasoning_tokens': 2},
          },
        }),
        _done,
      ]));
      final message = (await (await _stream(client)).collectAll()).single;
      expect(message.role, RoleType.assistant);
      expect(message.responseMeta!.usage!.promptTokens, 9);
      expect(message.responseMeta!.usage!.promptTokenDetails!.cachedTokens, 4);
      expect(
        message.responseMeta!.usage!.completionTokenDetails!.reasoningTokens,
        2,
      );
    });

    test('an error chunk is a classified OpenAIException', () async {
      Future<Object> errorOf(Map<String, Object?> error) async {
        final client = _client(_sse([
          _data(_chunk({'role': 'assistant', 'content': 'a'})),
          _data({'error': error}),
        ]));
        final items = await _drain(await _stream(client));
        expect(items.first, isA<Message>());
        return (items.last as _Failure).error;
      }

      expect(
        await errorOf({'message': 'Rate limit reached', 'code': 429}),
        isA<OpenAIException>()
            .having((e) => e.message, 'message', 'Provider error: Rate limit reached')
            .having((e) => e.errorCode, 'errorCode', 429)
            .having((e) => e.isRetryable, 'isRetryable', isTrue)
            .having((e) => e.isModelUnavailable, 'isModelUnavailable', isFalse),
      );
      expect(
        await errorOf({'message': 'The server had an error', 'type': 'server_error'}),
        isA<OpenAIException>().having((e) => e.isRetryable, 'isRetryable', isTrue),
      );
      expect(
        await errorOf({
          'message': 'The model `gpt-9` does not exist',
          'code': 'model_not_found',
        }),
        isA<OpenAIException>()
            .having((e) => e.isRetryable, 'isRetryable', isFalse)
            .having((e) => e.isModelUnavailable, 'isModelUnavailable', isTrue)
            .having((e) => e.errorCode, 'errorCode', 'model_not_found'),
      );
      expect(
        await errorOf({'message': 'Invalid request', 'code': 400}),
        isA<OpenAIException>()
            .having((e) => e.isRetryable, 'isRetryable', isFalse)
            .having((e) => e.isModelUnavailable, 'isModelUnavailable', isFalse),
      );
    });

    test('a chunk the parser rejects ends the stream with Go\'s wording',
        () async {
      final client = _client(_sse([
        _data(_chunk({'role': 'robot', 'content': 'x'})),
      ]));
      final items = await _drain(await _stream(client));
      expect(
        (items.single as _Failure).error,
        _openAIError(startsWith('failed to build message from stream chunk:'),
            retryable: false),
      );
    });

    test('a status other than 200 is the HTTP error, with the body read',
        () async {
      final client = _client(
        _sse(['{"error":{"message":"Unknown model"}}'], status: 404),
      );
      await expectLater(
        _stream(client),
        throwsA(
          isA<OpenAIException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.isModelUnavailable, 'isModelUnavailable', isTrue)
              .having((e) => e.response, 'response', contains('Unknown model')),
        ),
      );
    });

    test('a body that fails while streamed is a retryable stream failure',
        () async {
      final body = _LiveBody();
      final reader = await _stream(_client(body.client));
      body.add(_data(_chunk({'role': 'assistant', 'content': 'a'})));
      body.controller.addError(http.ClientException('connection reset'));

      final items = await _drain(reader);
      expect((items[0] as Message).content, 'a');
      expect(
        (items[1] as _Failure).error,
        _openAIError(startsWith('Stream processing failed:'), retryable: true),
      );
    });

    test('no chunk within the idle timeout is a retryable idle failure',
        () async {
      final body = _LiveBody();
      // Buffered before the read starts, so that only the silence after it
      // counts.
      body.add(_data(_chunk({'role': 'assistant', 'content': 'a'})));
      final reader = await _stream(
        _client(body.client, idleTimeout: const Duration(milliseconds: 20)),
      );

      final items = await _drain(reader);
      expect((items[0] as Message).content, 'a');
      expect(
        (items[1] as _Failure).error,
        _openAIError(startsWith('Stream idle for'), retryable: true),
      );
      expect(body.cancelled, isTrue);
    });

    test('headers that do not arrive in time are a retryable timeout',
        () async {
      final client = _client(
        MockClient.streaming(
          (request, bytes) => Completer<http.StreamedResponse>().future,
        ),
        timeout: const Duration(milliseconds: 5),
      );
      await expectLater(
        _stream(client),
        throwsA(_openAIError(startsWith('Request timed out'), retryable: true)),
      );
    });

    test('a transport failure is a retryable failed streaming request',
        () async {
      final client = _client(
        MockClient.streaming((request, bytes) async => throw http.ClientException('x')),
      );
      await expectLater(
        _stream(client),
        throwsA(_openAIError(startsWith('Streaming request failed:'), retryable: true)),
      );
    });

    test('a token cancelled before the call throws at once', () async {
      final client = _client(_sse([_done]));
      final token = CancelToken()..cancel('before');
      await expectLater(
        _stream(client, cancellation: CallCancellation(token, null)),
        throwsA(isA<CancelledException>()),
      );
    });

    test('a token cancelled while streaming ends the stream and the body',
        () async {
      final body = _LiveBody();
      final token = CancelToken();
      final reader = await _stream(
        _client(body.client),
        cancellation: CallCancellation(token, null),
      );
      body.add(_data(_chunk({'role': 'assistant', 'content': 'a'})));
      expect((await reader.recv()).content, 'a');

      token.cancel('enough');
      final items = await _drain(reader);
      expect(
        (items.single as _Failure).error,
        isA<CancelledException>().having((e) => e.reason, 'reason', 'enough'),
      );
      expect(body.cancelled, isTrue);
    });

    test('closing the reader early cancels the body', () async {
      final body = _LiveBody();
      final reader = await _stream(_client(body.client));
      body.add(_data(_chunk({'role': 'assistant', 'content': 'a'})));
      expect((await reader.recv()).content, 'a');

      await reader.close();
      body.add(_data(_chunk({'content': 'b'})));
      await pumpEventQueue();
      expect(body.cancelled, isTrue);
    });

    test('the cancellation of the call is released when the stream ends',
        () async {
      final a = CancelToken();
      final b = CancelToken();
      final cancellation = CallCancellation(a, b);
      final client = _client(_sse([
        _data(_chunk({'role': 'assistant', 'content': 'a'})),
        _done,
      ]));

      final reader = await _stream(client, cancellation: cancellation);
      expect(cancellation.token!.isCancelled, isFalse);
      await reader.collectAll();
      await pumpEventQueue();

      expect(cancellation.token!.isCancelled, isTrue);
      expect(a.isCancelled, isFalse);
      expect(b.isCancelled, isFalse);
    });

    test('a closed HTTP client is a StateError', () async {
      final shared = SharedHttpClient(_sse([_done]), owner: 'Model')..close();
      await expectLater(
        _stream(_client(_sse([_done]), shared: shared)),
        throwsStateError,
      );
    });
  });
}
