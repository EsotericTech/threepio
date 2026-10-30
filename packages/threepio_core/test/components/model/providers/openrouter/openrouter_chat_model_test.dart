import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// SSE body from a list of JSON chunk maps (as OpenRouter sends them).
String sse(List<Map<String, dynamic>> chunks, {bool done = true}) =>
    [for (final c in chunks) 'data: ${jsonEncode(c)}', if (done) 'data: [DONE]', ''].join('\n\n');

Map<String, dynamic> delta(Map<String, dynamic> d, {String? finish, Map<String, dynamic>? usage}) => {
      'id': 'gen-1',
      'choices': [
        {'index': 0, 'delta': d, if (finish != null) 'finish_reason': finish, if (finish != null) 'native_finish_reason': finish},
      ],
      if (usage != null) 'usage': usage,
    };

const usageJson = {
  'prompt_tokens': 198,
  'completion_tokens': 22,
  'total_tokens': 220,
  'cost': 0.00009504,
  'prompt_tokens_details': {'cached_tokens': 3},
  'completion_tokens_details': {'reasoning_tokens': 1, 'image_tokens': 0},
};

/// Recorded shape: GLM 5.3 parallel tool calls, complete arguments per call.
final glmToolCalls = sse([
  delta({'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'call_a', 'type': 'function', 'function': {'name': 'get_clip', 'arguments': ''}}]}),
  delta({'tool_calls': [{'index': 0, 'function': {'arguments': '{"position": 1}'}}]}),
  delta({'tool_calls': [{'index': 1, 'id': 'call_b', 'type': 'function', 'function': {'name': 'get_clip', 'arguments': ''}}]}),
  delta({'tool_calls': [{'index': 1, 'function': {'arguments': '{"position": 2}'}}]}),
  delta({}, finish: 'tool_calls'),
  delta({}, finish: 'tool_calls', usage: usageJson),
]);

/// Recorded shape: Kimi K3 reasoning deltas, non-standard ids, fragmented args.
final kimiReasoningAndTools = sse([
  delta({'reasoning': 'The user', 'reasoning_details': [{'type': 'reasoning.text', 'text': 'The user', 'format': 'unknown', 'index': 0}]}),
  delta({'reasoning': ' asks.', 'reasoning_details': [{'type': 'reasoning.text', 'text': ' asks.', 'format': 'unknown', 'index': 0}]}),
  delta({'tool_calls': [{'index': 0, 'id': 'get_clip:0', 'type': 'function', 'function': {'name': 'get_clip', 'arguments': ''}}]}),
  delta({'tool_calls': [{'index': 0, 'function': {'arguments': '{'}}]}),
  delta({'tool_calls': [{'index': 0, 'function': {'arguments': '"position": 1}'}}]}),
  delta({}, finish: 'tool_calls'),
  {'id': 'gen-1', 'choices': <dynamic>[], 'usage': usageJson},
]);

void main() {
  late List<http.Request> requests;

  OpenRouterChatModel model({
    required String body,
    int status = 200,
    OpenRouterConfig? config,
    Duration delayBetweenLines = Duration.zero,
    bool hangAfterFirstLine = false,
  }) {
    requests = [];
    final client = MockClient.streaming((request, bodyStream) async {
      requests.add(http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = await bodyStream.bytesToString());
      Stream<List<int>> stream() async* {
        final lines = body.split('\n');
        for (var i = 0; i < lines.length; i++) {
          yield utf8.encode('${lines[i]}\n');
          if (hangAfterFirstLine && i == 0) {
            await Future<void>.delayed(const Duration(seconds: 10));
          } else if (delayBetweenLines > Duration.zero) {
            await Future<void>.delayed(delayBetweenLines);
          }
        }
      }

      return http.StreamedResponse(stream(), status);
    });
    return OpenRouterChatModel(
      config: config ?? const OpenRouterConfig(apiKey: 'k', defaultModel: 'z-ai/glm-5.3'),
      httpClient: client,
    );
  }

  Map<String, dynamic> sentBody() => jsonDecode(requests.single.body) as Map<String, dynamic>;

  group('OpenRouterChatModel streaming', () {
    test('assembles parallel tool calls and carries usage with cost', () async {
      final reader = await model(body: glmToolCalls).stream([Message.user('hi')]);
      final chunks = await reader.collectAll();
      final merged = MessageConcatenator.concat(chunks);
      expect(merged.toolCalls!.map((c) => c.id), ['call_a', 'call_b']);
      expect(merged.toolCalls!.map((c) => c.function.arguments), ['{"position": 1}', '{"position": 2}']);
      expect(merged.responseMeta?.finishReason, 'tool_calls');
      final usage = merged.responseMeta!.usage!;
      expect(usage.cost, closeTo(0.00009504, 1e-12));
      expect(usage.promptTokenDetails?.cachedTokens, 3);
      expect(usage.completionTokenDetails?.reasoningTokens, 1);
    });

    test('streams reasoning deltas, keeps reasoning_details, merges fragmented args', () async {
      final reader = await model(body: kimiReasoningAndTools).stream([Message.user('hi')]);
      final chunks = await reader.collectAll();
      expect(chunks.where((c) => c.reasoningContent != null).map((c) => c.reasoningContent), ['The user', ' asks.']);
      final merged = MessageConcatenator.concat(chunks);
      expect(merged.reasoningContent, 'The user asks.');
      final details = merged.extra?[reasoningDetailsKey] as List<dynamic>;
      expect(details.length, 2, reason: 'raw blocks appended, not overwritten');
      expect(merged.toolCalls!.single.id, 'get_clip:0');
      expect(merged.toolCalls!.single.function.arguments, '{"position": 1}');
      expect(merged.responseMeta?.usage?.cost, isNotNull, reason: 'usage-only final chunk parsed');
    });

    test('request carries usage.include, reasoning, modalities and provider routing', () async {
      final options = const OpenRouterRequestOptions(
        reasoningEffort: ReasoningEffort.low,
        modalities: [OutputModality.image, OutputModality.text],
        provider: ProviderRouting(order: ['Google'], allowFallbacks: false),
        responseFormat: null,
        parallelToolCalls: true,
      ).toOptions(model: 'google/gemini-3.1-flash-image', temperature: 0.2);
      final reader = await model(body: sse([delta({'content': 'ok'}, finish: 'stop')])).stream([Message.user('hi')], options: options);
      await reader.collectAll();
      final body = sentBody();
      expect(body['model'], 'google/gemini-3.1-flash-image');
      expect(body['usage'], {'include': true});
      expect(body['reasoning'], {'effort': 'low'});
      expect(body['modalities'], ['image', 'text']);
      expect(body['provider'], {'order': ['Google'], 'allow_fallbacks': false});
      expect(body['parallel_tool_calls'], isTrue);
      expect(body['temperature'], 0.2);
      expect(body['stream'], isTrue);
      expect(requests.single.headers['Authorization'], 'Bearer k');
    });

    test('echoes reasoning_details and sends tool results and file parts in wire form', () async {
      final history = [
        Message.user('go'),
        Message(
          role: RoleType.assistant,
          toolCalls: [ToolCall(id: 'c1', function: const FunctionCall(name: 't', arguments: '{}'))],
          extra: const {reasoningDetailsKey: [{'type': 'reasoning.text', 'text': 'why', 'index': 0}]},
        ),
        Message.tool(content: 'result', toolCallId: 'c1', toolName: 't'),
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            const MessageInputPart(type: ChatMessagePartType.text, text: 'read this'),
            MessageInputPart(
              type: ChatMessagePartType.fileUrl,
              file: MessageInputFile(
                common: MessagePartCommon(url: 'data:application/pdf;base64,AAAA', mimeType: 'application/pdf', extra: {'filename': 'plan.pdf'}),
              ),
            ),
          ],
        ),
      ];
      final reader = await model(body: sse([delta({'content': 'ok'}, finish: 'stop')])).stream(history);
      await reader.collectAll();
      final messages = sentBody()['messages'] as List<dynamic>;
      final assistant = messages[1] as Map<String, dynamic>;
      expect(assistant['content'], isNull);
      expect(assistant['reasoning_details'], isA<List<dynamic>>());
      expect(assistant['tool_calls'], isNotEmpty);
      final tool = messages[2] as Map<String, dynamic>;
      expect(tool['role'], 'tool');
      expect(tool['tool_call_id'], 'c1');
      final user = messages[3] as Map<String, dynamic>;
      final parts = user['content'] as List<dynamic>;
      expect((parts[1] as Map)['type'], 'file');
      expect(((parts[1] as Map)['file'] as Map)['filename'], 'plan.pdf');
    });

    test('a provider error chunk surfaces as a classified OpenRouterException', () async {
      final body = sse([
        delta({'content': 'par'}),
        {'error': {'message': 'Provider returned error', 'code': 502}},
      ], done: false);
      final reader = await model(body: body).stream([Message.user('hi')]);
      final first = await reader.recv();
      expect(first.content, 'par');
      await expectLater(reader.recv(), throwsA(isA<OpenRouterException>().having((e) => e.isRetryable, 'retryable', isTrue)));
    });

    test('HTTP 429 and unknown-model 400 are classified', () async {
      await expectLater(
        model(body: '{"error":{"message":"Rate limit exceeded","code":429}}', status: 429).stream([Message.user('x')]),
        throwsA(isA<OpenRouterException>().having((e) => e.isRetryable, 'retryable', isTrue).having((e) => e.isRateLimited, 'rate limited', isTrue)),
      );
      await expectLater(
        model(body: '{"error":{"message":"z-ai/nope is not a valid model ID","code":400}}', status: 400).generate([Message.user('x')]),
        throwsA(isA<OpenRouterException>().having((e) => e.isModelUnavailable, 'unavailable', isTrue).having((e) => e.isRetryable, 'retryable', isFalse)),
      );
    });

    test('idle timeout fails the stream', () async {
      final body = sse([delta({'content': 'a'}), delta({'content': 'b'}, finish: 'stop')]);
      final m = model(
        body: body,
        hangAfterFirstLine: true,
        config: const OpenRouterConfig(apiKey: 'k', idleTimeout: Duration(milliseconds: 100)),
      );
      final reader = await m.stream([Message.user('x')]);
      await expectLater(reader.collectAll(), throwsA(isA<OpenRouterException>().having((e) => e.message, 'message', contains('idle'))));
    });

    test('cancel token stops the stream with CancelledException', () async {
      final body = sse([delta({'content': 'a'}), delta({'content': 'b'}), delta({'content': 'c'}, finish: 'stop')]);
      final token = CancelToken();
      final reader = await model(body: body, delayBetweenLines: const Duration(milliseconds: 40)).stream(
        [Message.user('x')],
        options: ChatModelOptions(cancelToken: token),
      );
      Future<void>.delayed(const Duration(milliseconds: 60), () => token.cancel('bye'));
      await expectLater(reader.collectAll(), throwsA(isA<CancelledException>()));
    });
  });

  group('OpenRouterChatModel generate', () {
    test('parses a completion with reasoning, images and cost', () async {
      final body = jsonEncode({
        'id': 'gen',
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {
              'role': 'assistant',
              'content': null,
              'reasoning': 'thought',
              'reasoning_details': [{'type': 'reasoning.text', 'text': 'thought'}],
              'images': [
                {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,iVBORw0KGgo='}},
              ],
            },
          },
        ],
        'usage': {'prompt_tokens': 16, 'completion_tokens': 1120, 'total_tokens': 1136, 'cost': 0.067208, 'completion_tokens_details': {'image_tokens': 1120}},
      });
      final message = await model(body: body).generate([Message.user('draw')]);
      expect(message.assistantGenMultiContent!.single.image!.url, startsWith('data:image/png'));
      expect(message.responseMeta?.usage?.cost, closeTo(0.067208, 1e-9));
      expect(message.responseMeta?.usage?.completionTokenDetails?.imageTokens, 1120);
    });
  });

  group('Resilient decorators', () {
    test('RetryingChatModel retries retryable errors then succeeds', () async {
      var attempts = 0;
      final inner = _FlakyModel(() {
        attempts++;
        if (attempts < 3) throw OpenRouterException('busy', statusCode: 429, isRetryable: true);
        return Message.assistant('ok');
      });
      final retrying = RetryingChatModel(inner, baseDelay: const Duration(milliseconds: 1));
      expect((await retrying.generate([Message.user('x')])).content, 'ok');
      expect(attempts, 3);
    });

    test('RetryingChatModel does not retry model-unavailable or cancellation', () async {
      var attempts = 0;
      final inner = _FlakyModel(() {
        attempts++;
        throw OpenRouterException('gone', statusCode: 404, isModelUnavailable: true);
      });
      await expectLater(RetryingChatModel(inner, baseDelay: const Duration(milliseconds: 1)).generate([Message.user('x')]), throwsA(isA<OpenRouterException>()));
      expect(attempts, 1);
    });

    test('FailoverChatModel switches to the fallback', () async {
      final primary = _FlakyModel(() => throw OpenRouterException('gone', statusCode: 404, isModelUnavailable: true));
      final fallback = _FlakyModel(() => Message.assistant('from fallback'));
      Object? seen;
      final failover = FailoverChatModel(primary: primary, fallback: fallback, onFailover: (e) => seen = e);
      expect((await failover.generate([Message.user('x')])).content, 'from fallback');
      expect(seen, isA<OpenRouterException>());
      await expectLater(
        FailoverChatModel(primary: _FlakyModel(() => throw const CancelledException()), fallback: fallback).generate([Message.user('x')]),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('OpenRouterRequestOptions', () {
    test('json_schema response format and applyTo merge', () {
      final format = ResponseFormat.jsonSchema(name: 'intent', schema: {'type': 'object'});
      final fields = OpenRouterRequestOptions(responseFormat: format, includeUsage: false, extra: {'seed': 7}).toRequestFields();
      expect(fields['response_format'], {'type': 'json_schema', 'json_schema': {'name': 'intent', 'strict': true, 'schema': {'type': 'object'}}});
      expect(fields.containsKey('usage'), isFalse);
      expect(fields['seed'], 7);
      final merged = const OpenRouterRequestOptions(reasoningEffort: ReasoningEffort.high).applyTo(const ChatModelOptions(model: 'm', extra: {'top_k': 5}));
      expect(merged.extra, {'top_k': 5, 'reasoning': {'effort': 'high'}, 'usage': {'include': true}});
      expect(merged.model, 'm');
    });
  });
}

class _FlakyModel extends ToolCallingChatModel {
  _FlakyModel(this.respond);

  final Message Function() respond;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async => respond();

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async => StreamReader.fromIterable([respond()]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}
