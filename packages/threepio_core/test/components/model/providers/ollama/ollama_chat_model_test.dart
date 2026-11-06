// Ports eino-ext components/model/ollama/chatmodel_test.go:
// * Test_Generate (3 cases), Test_Stream (2 cases), TestBindTools (as
//   withTools: BindTools is deprecated in Eino), TestWithTools. The Go tests
//   mock `api.Client.Chat` with mockey; here the same behaviour runs against a
//   fake HTTP client answering with recorded-shape Ollama responses (the JSON
//   of `/api/chat`, NDJSON when streaming).
// * Not ported: TestPanicErr (Go recovers a panic of the stream goroutine;
//   Dart has no panics, and an error of the pump ends the stream, tested
//   below). Test_toOllamaMessage is in ollama_converters_test.dart.
//
// Plus tests written for the port: the request body built from the
// configuration, the call options and the messages; response parsing; NDJSON
// edge cases (split lines, blank lines, malformed line, error line mid-stream,
// stop at `done`, idle timeout, body failure); cancellation before and during a
// call; HTTP error classification; callbacks; withTools sharing the client;
// dispose.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_config.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_options.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../../../support/log_capture.dart';

const _config = OllamaConfig(model: 'llama3.2');
const _createdAt = '2024-07-22T20:33:28.123648Z';

/// A streamed chunk of `/api/chat`, as Ollama sends it.
Map<String, Object?> _chunk(
  String content, {
  String? thinking,
  List<Object?>? toolCalls,
}) =>
    {
      'model': 'llama3.2',
      'created_at': _createdAt,
      'message': {
        'role': 'assistant',
        'content': content,
        if (thinking != null) 'thinking': thinking,
        if (toolCalls != null) 'tool_calls': toolCalls,
      },
      'done': false,
    };

/// The last response of `/api/chat` (also the whole answer of a request made
/// with `stream: false`), as Ollama sends it.
Map<String, Object?> _done({
  String content = '',
  String? thinking,
  List<Object?>? toolCalls,
  String reason = 'stop',
}) =>
    {
      'model': 'llama3.2',
      'created_at': _createdAt,
      'message': {
        'role': 'assistant',
        'content': content,
        if (thinking != null) 'thinking': thinking,
        if (toolCalls != null) 'tool_calls': toolCalls,
      },
      'done_reason': reason,
      'done': true,
      'total_duration': 4883583458,
      'load_duration': 1334875,
      'prompt_eval_count': 26,
      'prompt_eval_duration': 342546000,
      'eval_count': 282,
      'eval_duration': 4535599000,
    };

Map<String, Object?> _toolCall(String name, Map<String, Object?> arguments) => {
      'function': {'name': name, 'arguments': arguments},
    };

String _line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

/// Text with a two-byte and a four-byte UTF-8 character.
final String _happy =
    'caf${String.fromCharCode(0xE9)} ${String.fromCharCodes([0xD83D, 0xDE00])}';

/// One request the fake server received.
typedef _Request = ({
  Uri url,
  Map<String, String> headers,
  Map<String, Object?> body,
});

_Request _record(http.BaseRequest request, String body) => (
      url: request.url,
      headers: request.headers,
      body: jsonDecode(body) as Map<String, Object?>,
    );

/// Answers every request with [body] (a JSON value or a raw string).
MockClient _answering(
  List<_Request> log,
  Object body, {
  int status = 200,
}) =>
    MockClient((request) async {
      log.add(_record(request, request.body));
      return http.Response.bytes(
        utf8.encode(body is String ? body : jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

/// Answers every request with a stream of [chunks].
MockClient _streaming(
  List<_Request> log,
  List<List<int>> chunks, {
  int status = 200,
}) =>
    MockClient.streaming((request, body) async {
      log.add(_record(request, await body.bytesToString()));
      return http.StreamedResponse(
        Stream.fromIterable(chunks),
        status,
        headers: {'content-type': 'application/x-ndjson'},
      );
    });

List<List<int>> _lines(List<Map<String, Object?>> responses) =>
    [for (final response in responses) utf8.encode(_line(response))];

/// A response body the test writes to, and whether its reader let go of it.
final class _Body {
  _Body() {
    controller.onCancel = () {
      if (!released.isCompleted) released.complete();
    };
  }

  final StreamController<List<int>> controller = StreamController();
  final Completer<void> released = Completer();

  void send(Map<String, Object?> json) => controller.add(utf8.encode(_line(json)));

  MockClient client(List<_Request> log) =>
      MockClient.streaming((request, body) async {
        log.add(_record(request, await body.bytesToString()));
        return http.StreamedResponse(controller.stream, 200);
      });
}

/// A client that records its requests and whether it was closed.
final class _RecordingClient extends http.BaseClient {
  final List<Uri> requests = [];
  bool isClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(
      Stream.value(utf8.encode(_line(_done(content: 'ok')))),
      200,
    );
  }

  @override
  void close() => isClosed = true;
}

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

final _weatherTool = ToolInfo.fromParams(
  name: 'get_current_weather',
  desc: 'Get the current weather in a given location',
  params: const {
    'location': ParameterInfo(
      type: DataType.string,
      desc: 'The city and state, e.g. San Francisco, CA',
      required: true,
    ),
    'unit': ParameterInfo(
      type: DataType.string,
      enumValues: ['celsius', 'fahrenheit'],
      required: true,
    ),
  },
);

final _stockTool = ToolInfo.fromParams(
  name: 'get_current_stock_price',
  desc: 'Get the current stock price given the name of the stock',
  params: const {
    'name': ParameterInfo(
      type: DataType.string,
      desc: 'The name of the stock',
      required: true,
    ),
  },
);

TypeMatcher<OllamaException> _ollamaError({
  bool? retryable,
  bool? unavailable,
  int? status,
  Object? message,
}) {
  var matcher = isA<OllamaException>();
  if (retryable != null) {
    matcher = matcher.having((e) => e.isRetryable, 'isRetryable', retryable);
  }
  if (unavailable != null) {
    matcher = matcher.having(
      (e) => e.isModelUnavailable,
      'isModelUnavailable',
      unavailable,
    );
  }
  if (status != null) {
    matcher = matcher.having((e) => e.statusCode, 'statusCode', status);
  }
  if (message != null) {
    matcher = matcher.having((e) => e.message, 'message', message);
  }
  return matcher;
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('Test_Generate', () {
    final msgs = [
      const Message(
        role: RoleType.user,
        content: 'test',
        toolCalls: [
          ToolCall(
            index: 1,
            id: 'asd',
            function: FunctionCall(name: 'qwe', arguments: '{}'),
          ),
        ],
      ),
    ];
    const config = OllamaConfig(model: 'asd');

    test('test chat error', () async {
      final model = OllamaChatModel(
        config: config,
        httpClient: MockClient(
          (request) async => throw http.ClientException('test invoke error'),
        ),
      ).withTools([_weatherTool, _stockTool]);

      await expectLater(
        model.generate(msgs),
        throwsA(_ollamaError(retryable: true, message: contains('test invoke error'))),
      );
    });

    test('test resolveChatResponse error', () async {
      // Go mocks the same failing `Chat` call twice; here the server answers
      // with an error status instead.
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: config,
        httpClient: _answering(log, {'error': 'test invoke error'}, status: 500),
      ).withTools([_weatherTool, _stockTool]);

      await expectLater(
        model.generate(msgs),
        throwsA(
          _ollamaError(
            retryable: true,
            status: 500,
            message: contains('test invoke error'),
          ),
        ),
      );
      expect(log, hasLength(1));
    });

    test('test success', () async {
      final log = <_Request>[];
      // As Go's MockChatInvoke: answers with a call of the first tool.
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        log.add(_record(request, request.body));
        final tools = body['tools']! as List;
        final first = (tools.first as Map)['function'] as Map;
        return http.Response(
          jsonEncode(
            _done(
              content: 'test',
              toolCalls: [_toolCall(first['name'] as String, {})],
            ),
          ),
          200,
        );
      });
      final model = OllamaChatModel(config: config, httpClient: client)
          .withTools([_weatherTool, _stockTool]);
      final recorder = _Recorder();

      final outMsg = await model.generate(
        msgs,
        options: _with(recorder).copyWith(
          temperature: 1,
          maxTokens: 321,
          model: 'asd',
          topP: 123,
          extensions: const [OllamaRequestOptions(seed: 111)],
        ),
      );

      expect(outMsg.role, RoleType.assistant);
      expect(outMsg.toolCalls, hasLength(1));
      expect(outMsg.toolCalls!.single.function.name, 'get_current_weather');
      expect(recorder.timings, ['start', 'end']);

      final body = log.single.body;
      expect(body['model'], 'asd');
      expect(body['options'], {
        'temperature': 1.0,
        'top_p': 123.0,
        'num_predict': 321,
        'seed': 111,
      });
      expect(body['tools'], hasLength(2));
      expect(body['messages'], [
        {
          'role': 'user',
          'content': 'test',
          'tool_calls': [
            {
              'function': {'name': 'qwe', 'arguments': <String, Object?>{}},
            },
          ],
        },
      ]);
    });
  });

  group('Test_Stream', () {
    final msgs = [
      const Message(
        role: RoleType.user,
        content: 'test',
        toolCalls: [
          ToolCall(
            index: 1,
            id: 'asd',
            function: FunctionCall(name: 'qwe', arguments: '{"hello":"world"}'),
          ),
        ],
      ),
    ];
    const config = OllamaConfig(model: 'asd');

    test('test chan err', () async {
      // Go reports the failure through the stream; threepio's providers throw
      // it from stream() so that RetryingChatModel can act on it.
      final model = OllamaChatModel(
        config: config,
        httpClient: MockClient.streaming(
          (request, body) async => throw http.ClientException('test stream error'),
        ),
      );

      await expectLater(
        model.stream(msgs),
        throwsA(_ollamaError(retryable: true, message: contains('test stream error'))),
      );
    });

    test('test chan success', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: config,
        httpClient: _streaming(log, [
          for (var i = 0; i < 5; i++)
            utf8.encode(_line(_chunk('test_${'$i'.padLeft(3, '0')}'))),
          utf8.encode(_line(_done())),
        ]),
      );

      final reader = await model.stream(msgs);
      final chunks = await reader.collectAll();
      await reader.close();

      expect(
        [for (final chunk in chunks) chunk.content],
        ['test_000', 'test_001', 'test_002', 'test_003', 'test_004', ''],
      );
      expect(chunks.last.responseMeta!.finishReason, 'stop');
      expect(chunks.last.ollamaMetrics!.promptEvalCount, 26);
      expect(log.single.body['stream'], isTrue);
      expect(
        (log.single.body['messages']! as List).single,
        {
          'role': 'user',
          'content': 'test',
          'tool_calls': [
            {
              'function': {
                'name': 'qwe',
                'arguments': {'hello': 'world'},
              },
            },
          ],
        },
      );
    });
  });

  group('TestBindTools', () {
    test('chat model bind tools', () {
      final chatModel = OllamaChatModel(config: const OllamaConfig(model: 'llama3'));
      final doNothing = ToolInfo.fromParams(
        name: 'do_nothing',
        desc: 'do nothing',
        params: const {
          'test': ParameterInfo(
            type: DataType.string,
            desc: 'no meaning',
            required: true,
          ),
        },
      );
      final bound = chatModel.withTools([doNothing]) as OllamaChatModel;
      expect(bound.tools!.single.name, 'do_nothing');
      expect(chatModel.tools, isNull);
    });
  });

  group('TestWithTools', () {
    test('the copy keeps the configuration and has the tools', () {
      final cm = OllamaChatModel(config: const OllamaConfig(model: 'test model'));
      final ncm = cm.withTools([ToolInfo.function(name: 'test tool name')])
          as OllamaChatModel;
      expect(ncm.config.model, 'test model');
      expect(ncm.tools![0].name, 'test tool name');
    });

    test('an empty list gives a copy without tools (Go rejects it)', () {
      final cm = OllamaChatModel(config: _config);
      final ncm = cm.withTools(const []) as OllamaChatModel;
      expect(ncm.tools, isEmpty);
    });
  });

  group('request body', () {
    test('a minimal request', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering(log, _done(content: 'hi')),
      );

      await model.generate([Message.user('hi')]);

      final request = log.single;
      expect(request.url, Uri.parse('http://localhost:11434/api/chat'));
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(request.headers['Accept'], 'application/x-ndjson');
      expect(request.body, {
        'model': 'llama3.2',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'stream': false,
        'options': <String, Object?>{},
      });
    });

    test('the configuration sets format, keep_alive, options and think',
        () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'qwen3:8b',
          baseUrl: 'http://gpu.local:11434/ollama/',
          format: OllamaFormat.schema({
            'type': 'object',
            'properties': {
              'age': {'type': 'integer'},
            },
          }),
          keepAlive: Duration(minutes: 10),
          options: OllamaOptions(numCtx: 8192, temperature: 0.7, seed: 1),
          thinking: OllamaThinkValue.level(OllamaThinkLevel.high),
        ),
        httpClient: _answering(log, _done()),
      );

      await model.generate([Message.user('hi')]);

      final request = log.single;
      expect(request.url, Uri.parse('http://gpu.local:11434/ollama/api/chat'));
      expect(request.body, {
        'model': 'qwen3:8b',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'stream': false,
        'format': {
          'type': 'object',
          'properties': {
            'age': {'type': 'integer'},
          },
        },
        'keep_alive': '10m0s',
        'options': {'num_ctx': 8192, 'seed': 1, 'temperature': 0.7},
        'think': 'high',
      });
    });

    test('format json, a negative keep_alive and think false', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          format: OllamaFormat.json(),
          keepAlive: Duration(seconds: -1),
          thinking: OllamaThinkValue.disabled,
        ),
        httpClient: _answering(log, _done()),
      );

      await model.generate([Message.user('hi')]);

      expect(log.single.body['format'], 'json');
      expect(log.single.body['keep_alive'], -1);
      expect(log.single.body['think'], false);
    });

    test('the options of a call override the configured ones', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          options: OllamaOptions(
            temperature: 0.7,
            topP: 0.5,
            stop: ['a'],
            numPredict: 10,
            seed: 1,
            topK: 20,
          ),
        ),
        httpClient: _answering(log, _done()),
      );

      await model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(
          model: 'other',
          temperature: 0.1,
          topP: 0.2,
          stop: ['b'],
          maxTokens: 99,
          extensions: [OllamaRequestOptions(seed: 7)],
        ),
      );

      expect(log.single.body['model'], 'other');
      expect(log.single.body['options'], {
        'seed': 7,
        'num_predict': 99,
        'top_k': 20,
        'top_p': 0.2,
        'temperature': 0.1,
        'stop': ['b'],
      });
    });

    test('an empty stop list keeps the configured one, as in Go', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          options: OllamaOptions(stop: ['a']),
        ),
        httpClient: _answering(log, _done()),
      );

      await model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(stop: []),
      );

      expect(log.single.body['options'], {
        'stop': ['a'],
      });
    });

    test('bound tools are sent; the tools of a call replace them', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering(log, _done()),
      ).withTools([_weatherTool]);

      await model.generate([Message.user('hi')]);
      await model.generate(
        [Message.user('hi')],
        options: ChatModelOptions(tools: [_stockTool]),
      );
      await model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(tools: []),
      );

      List<String> toolNames(_Request request) => [
            for (final tool in (request.body['tools'] as List?) ?? const [])
              ((tool as Map)['function'] as Map)['name'] as String,
          ];
      expect(toolNames(log[0]), ['get_current_weather']);
      expect(toolNames(log[1]), ['get_current_stock_price']);
      expect(log[2].body.containsKey('tools'), isFalse);
      expect(
        (log[0].body['tools']! as List).single,
        {
          'type': 'function',
          'function': {
            'name': 'get_current_weather',
            'description': 'Get the current weather in a given location',
            'parameters': {
              'type': 'object',
              'required': ['location', 'unit'],
              'properties': {
                'location': {
                  'type': 'string',
                  'description': 'The city and state, e.g. San Francisco, CA',
                },
                'unit': {
                  'type': 'string',
                  'description': '',
                  'enum': ['celsius', 'fahrenheit'],
                },
              },
            },
          },
        },
      );
    });

    test('Ollama has no tool choice: toolChoice is not sent', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering(log, _done()),
      ).withTools([_weatherTool]);

      await model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(toolChoice: ToolChoice.forced),
      );

      expect(log.single.body.containsKey('tool_choice'), isFalse);
    });

    test('allowedToolNames is rejected before anything is sent or reported',
        () async {
      final log = <_Request>[];
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering(log, _done()),
      ).withTools([_weatherTool]);

      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: _with(recorder).copyWith(
            toolChoice: ToolChoice.forced,
            allowedToolNames: ['get_current_weather'],
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        model.stream(
          [Message.user('hi')],
          options: _with(recorder).copyWith(
            toolChoice: ToolChoice.forced,
            allowedToolNames: ['get_current_weather'],
          ),
        ),
        throwsArgumentError,
      );
      expect(log, isEmpty);
      expect(recorder.timings, isEmpty);
    });

    test('content Ollama cannot take fails before anything is sent or reported',
        () async {
      final log = <_Request>[];
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering(log, _done()),
      );
      final message = Message(
        role: RoleType.user,
        userInputMultiContent: [
          MessageInputPart.imageUrl('https://example.com/cat.png'),
        ],
      );

      await expectLater(
        model.generate([message], options: _with(recorder)),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(log, isEmpty);
      expect(recorder.timings, isEmpty);
    });

    test('an invalid base URL is rejected when the model is made', () {
      expect(
        () => OllamaChatModel(
          config: const OllamaConfig(
            model: 'llama3.2',
            baseUrl: 'http://example.com:port',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('an empty base URL is the local server', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: const OllamaConfig(model: 'llama3.2', baseUrl: ''),
        httpClient: _answering(log, _done()),
      );

      await model.generate([Message.user('hi')]);

      expect(log.single.url, Uri.parse('http://localhost:11434/api/chat'));
    });
  });

  group('generate response', () {
    test('content, finish reason, usage and metrics', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], _done(content: 'Hello! How are you today?')),
      );

      final answer = await model.generate([Message.user('hi')]);

      expect(answer.role, RoleType.assistant);
      expect(answer.content, 'Hello! How are you today?');
      expect(answer.responseMeta!.finishReason, 'stop');
      expect(
        answer.responseMeta!.usage,
        const TokenUsage(promptTokens: 26, completionTokens: 282, totalTokens: 308),
      );
      expect(answer.ollamaMetrics!.evalCount, 282);
      expect(
        answer.ollamaMetrics!.totalDuration,
        const Duration(microseconds: 4883583),
      );
    });

    test('tool calls and thinking', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering(
          [],
          _done(
            thinking: 'The user asks for the weather.',
            toolCalls: [
              _toolCall(
                'get_current_weather',
                {'format': 'celsius', 'location': 'Paris, FR'},
              ),
            ],
          ),
        ),
      );

      final answer = await model.generate([Message.user('weather?')]);

      expect(answer.reasoningContent, 'The user asks for the weather.');
      final call = answer.toolCalls!.single;
      expect(call.type, 'function');
      expect(call.function.name, 'get_current_weather');
      expect(
        jsonDecode(call.function.arguments),
        {'format': 'celsius', 'location': 'Paris, FR'},
      );
    });

    test('UTF-8 content is decoded as UTF-8', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: MockClient(
          (request) async => http.Response.bytes(
            utf8.encode(jsonEncode(_done(content: _happy))),
            200,
          ),
        ),
      );

      final answer = await model.generate([Message.user('hi')]);

      expect(answer.content, _happy);
    });

    test('an error line with a successful status fails', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], {'error': 'something broke'}),
      );

      await expectLater(
        model.generate([Message.user('hi')]),
        throwsA(_ollamaError(retryable: false, message: 'something broke')),
      );
    });

    test('an empty body fails (Go returns a nil message)', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], ''),
      );

      await expectLater(
        model.generate([Message.user('hi')]),
        throwsA(_ollamaError(message: contains('empty response'))),
      );
    });

    test('a body that is not JSON fails', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], '<html>bad gateway</html>'),
      );

      await expectLater(
        model.generate([Message.user('hi')]),
        throwsA(
          _ollamaError(retryable: false, message: startsWith('Malformed')),
        ),
      );
    });
  });

  group('stream (NDJSON)', () {
    test('chunks with thinking and tool calls concatenate into the answer',
        () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], _lines([
          _chunk('', thinking: 'Let me '),
          _chunk('', thinking: 'think.'),
          _chunk('Checking '),
          _chunk('', toolCalls: [_toolCall('get_current_weather', {'location': 'Paris'})]),
          _chunk('', toolCalls: [_toolCall('get_current_stock_price', {'name': 'ACME'})]),
          _done(content: 'now.'),
        ])),
      );

      final reader = await model.stream([Message.user('hi')]);
      final chunks = await reader.collectAll();
      await reader.close();
      final answer = concatMessages(chunks);

      expect(answer.content, 'Checking now.');
      expect(answer.reasoningContent, 'Let me think.');
      expect(
        [for (final call in answer.toolCalls!) call.function.name],
        ['get_current_weather', 'get_current_stock_price'],
      );
      expect(answer.toolCalls![1].function.arguments, '{"name":"ACME"}');
      expect(answer.responseMeta!.finishReason, 'stop');
      expect(answer.responseMeta!.usage!.totalTokens, 308);
      expect(answer.ollamaMetrics!.promptEvalCount, 26);
    });

    test('lines split across network chunks, also inside a character',
        () async {
      final bytes = utf8.encode(
        _line(_chunk('h${String.fromCharCode(0xE9)}llo')) + _line(_done()),
      );
      // Cut inside the two bytes of the accented letter and inside the JSON.
      final cut = bytes.indexOf(0xC3) + 1;
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], [
          bytes.sublist(0, 7),
          bytes.sublist(7, cut),
          bytes.sublist(cut, cut + 3),
          bytes.sublist(cut + 3),
        ]),
      );

      final reader = await model.stream([Message.user('hi')]);
      final chunks = await reader.collectAll();
      await reader.close();

      expect(chunks.first.content, 'h${String.fromCharCode(0xE9)}llo');
      expect(chunks, hasLength(2));
    });

    test('blank lines are skipped; a last line without a newline is read',
        () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], [
          utf8.encode('\n'),
          utf8.encode(_line(_chunk('a'))),
          utf8.encode('  \r\n\n'),
          utf8.encode(jsonEncode(_done(content: 'b'))),
        ]),
      );

      final reader = await model.stream([Message.user('hi')]);
      final chunks = await reader.collectAll();
      await reader.close();

      expect([for (final chunk in chunks) chunk.content], ['a', 'b']);
    });

    test('a malformed line ends the stream with an OllamaException', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], [
          utf8.encode(_line(_chunk('a'))),
          utf8.encode('{"model": "llama3.2", "mess\n'),
          utf8.encode(_line(_done())),
        ]),
      );

      final reader = await model.stream([Message.user('hi')]);
      expect((await reader.recv()).content, 'a');
      await expectLater(
        reader.recv(),
        throwsA(_ollamaError(retryable: false, message: startsWith('Malformed'))),
      );
      await reader.close();
    });

    test('an error line mid-stream ends the stream', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], [
          utf8.encode(_line(_chunk('a'))),
          utf8.encode(_line({
            'error': 'an error was encountered while running the model: '
                'unexpected EOF',
          })),
          utf8.encode(_line(_done())),
        ]),
      );

      final reader = await model.stream([Message.user('hi')]);
      expect((await reader.recv()).content, 'a');
      await expectLater(
        reader.recv(),
        throwsA(
          _ollamaError(
            retryable: false,
            unavailable: false,
            message: startsWith('an error was encountered'),
          ),
        ),
      );
      await reader.close();
    });

    test('a missing model reported mid-stream is model-unavailable', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], [
          utf8.encode(_line({
            'error': 'model "llama9" not found, try pulling it first',
          })),
        ]),
      );

      final reader = await model.stream([Message.user('hi')]);
      await expectLater(
        reader.recv(),
        throwsA(_ollamaError(unavailable: true)),
      );
      await reader.close();
    });

    test('reading stops at done and the body is released', () async {
      final body = _Body();
      final model = OllamaChatModel(config: _config, httpClient: body.client([]));

      final reader = await model.stream([Message.user('hi')]);
      body
        ..send(_chunk('a'))
        ..send(_done(content: 'b'));

      final chunks = await reader.collectAll();
      await reader.close();
      await body.released.future;
      unawaited(body.controller.close());

      expect([for (final chunk in chunks) chunk.content], ['a', 'b']);
    });

    test('a failing body ends the stream with a retryable OllamaException',
        () async {
      final body = _Body();
      final model = OllamaChatModel(config: _config, httpClient: body.client([]));

      final reader = await model.stream([Message.user('hi')]);
      body.send(_chunk('a'));
      expect((await reader.recv()).content, 'a');
      body.controller.addError(http.ClientException('connection reset'));

      await expectLater(
        reader.recv(),
        throwsA(
          _ollamaError(retryable: true, message: contains('connection reset')),
        ),
      );
      await reader.close();
      unawaited(body.controller.close());
    });

    test('a silent stream fails after the idle timeout', () async {
      final body = _Body();
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          idleTimeout: Duration(milliseconds: 20),
        ),
        httpClient: body.client([]),
      );

      final reader = await model.stream([Message.user('hi')]);

      await expectLater(
        reader.recv(),
        throwsA(_ollamaError(retryable: true, message: contains('idle'))),
      );
      await body.released.future;
      await reader.close();
      unawaited(body.controller.close());
    });

    test('a reader closed early releases the body at the next line', () async {
      final body = _Body();
      final model = OllamaChatModel(config: _config, httpClient: body.client([]));

      final reader = await model.stream([Message.user('hi')]);
      body.send(_chunk('a'));
      expect((await reader.recv()).content, 'a');
      await reader.close();
      body.send(_chunk('b'));

      await body.released.future;
      unawaited(body.controller.close());
    });
  });

  group('cancellation', () {
    test('generate with a cancelled token sends nothing', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering(log, _done()),
      );

      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: ChatModelOptions(cancelToken: CancelToken()..cancel('no')),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(log, isEmpty);
    });

    test('generate cancelled while it waits for the answer', () async {
      final sent = Completer<void>();
      final model = OllamaChatModel(
        config: _config,
        httpClient: MockClient((request) {
          sent.complete();
          return Completer<http.Response>().future; // never answers
        }),
      );
      final token = CancelToken();

      final answer = model.generate(
        [Message.user('hi')],
        options: ChatModelOptions(cancelToken: token),
      );
      await sent.future;
      token.cancel('user');

      await expectLater(answer, throwsA(isA<CancelledException>()));
    });

    test('stream with a cancelled run context sends nothing', () async {
      final log = <_Request>[];
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming(log, _lines([_done()])),
      );

      await expectLater(
        model.stream(
          [Message.user('hi')],
          options: ChatModelOptions(
            runContext: RunContext.background(
              cancelToken: CancelToken()..cancel('no'),
            ),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(log, isEmpty);
    });

    test('a stream cancelled mid-way ends with CancelledException and releases '
        'the body', () async {
      final body = _Body();
      final model = OllamaChatModel(config: _config, httpClient: body.client([]));
      final token = CancelToken();

      final reader = await model.stream(
        [Message.user('hi')],
        options: ChatModelOptions(cancelToken: token),
      );
      body.send(_chunk('Hel'));
      expect((await reader.recv()).content, 'Hel');
      token.cancel('user');

      await expectLater(reader.recv(), throwsA(isA<CancelledException>()));
      await body.released.future;
      await reader.close();
      unawaited(body.controller.close());
    });

    test('with both tokens, the run context token cancels', () async {
      final body = _Body();
      final model = OllamaChatModel(config: _config, httpClient: body.client([]));
      final runToken = CancelToken();

      final reader = await model.stream(
        [Message.user('hi')],
        options: ChatModelOptions(
          cancelToken: CancelToken(),
          runContext: RunContext.background(cancelToken: runToken),
        ),
      );
      runToken.cancel('run cancelled');

      await expectLater(
        reader.recv(),
        throwsA(
          isA<CancelledException>()
              .having((e) => e.reason, 'reason', 'run cancelled'),
        ),
      );
      await body.released.future;
      await reader.close();
      unawaited(body.controller.close());
    });

    test('with both tokens, the options token cancels', () async {
      final body = _Body();
      final model = OllamaChatModel(config: _config, httpClient: body.client([]));
      final optionsToken = CancelToken();
      final runToken = CancelToken();

      final reader = await model.stream(
        [Message.user('hi')],
        options: ChatModelOptions(
          cancelToken: optionsToken,
          runContext: RunContext.background(cancelToken: runToken),
        ),
      );
      body.send(_chunk('a'));
      expect((await reader.recv()).content, 'a');
      optionsToken.cancel('options cancelled');

      await expectLater(
        reader.recv(),
        throwsA(
          isA<CancelledException>()
              .having((e) => e.reason, 'reason', 'options cancelled'),
        ),
      );
      await body.released.future;
      await reader.close();
      unawaited(body.controller.close());
      // The combined token was released; the caller's run token is untouched.
      expect(runToken.isCancelled, isFalse);
    });

    test('with both tokens, the options token cancels generate', () async {
      final sent = Completer<void>();
      final model = OllamaChatModel(
        config: _config,
        httpClient: MockClient((request) {
          sent.complete();
          return Completer<http.Response>().future; // never answers
        }),
      );
      final optionsToken = CancelToken();
      final runToken = CancelToken();

      final answer = model.generate(
        [Message.user('hi')],
        options: ChatModelOptions(
          cancelToken: optionsToken,
          runContext: RunContext.background(cancelToken: runToken),
        ),
      );
      await sent.future;
      optionsToken.cancel('options cancelled');

      await expectLater(answer, throwsA(isA<CancelledException>()));
      expect(runToken.isCancelled, isFalse);
    });
  });

  group('errors', () {
    Future<OllamaException> failure(int status, Object body) async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], body, status: status),
      );
      try {
        await model.generate([Message.user('hi')]);
      } on OllamaException catch (error) {
        return error;
      }
      fail('no OllamaException');
    }

    test('429 is retryable', () async {
      final error = await failure(429, {'error': 'too many requests'});
      expect(error.isRetryable, isTrue);
      expect(error.isModelUnavailable, isFalse);
      expect(error.statusCode, 429);
      expect(error.response, '{"error":"too many requests"}');
    });

    test('404 with an unknown model is model-unavailable', () async {
      final error = await failure(404, {
        'error': 'model "llama9" not found, try pulling it first',
      });
      expect(error.isModelUnavailable, isTrue);
      expect(error.isRetryable, isFalse);
      expect(
        error.message,
        'Ollama request failed with status 404: '
        'model "llama9" not found, try pulling it first',
      );
      expect(error.toString(), startsWith('OllamaException: '));
      expect(error, isA<ChatModelException>());
    });

    test('400 is neither retryable nor model-unavailable', () async {
      final error = await failure(400, {
        'error': 'registry.ollama.ai/library/gemma:2b does not support tools',
      });
      expect(error.isRetryable, isFalse);
      expect(error.isModelUnavailable, isFalse);
    });

    test('500 is retryable; a body that is not JSON is kept as the message',
        () async {
      final error = await failure(500, 'llama runner process has terminated');
      expect(error.isRetryable, isTrue);
      expect(error.message, endsWith('llama runner process has terminated'));
    });

    test('a streaming request the server rejects throws from stream()',
        () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming(
          [],
          [utf8.encode('{"error":"model \\"x\\" not found, try pulling it first"}')],
          status: 404,
        ),
      );

      await expectLater(
        model.stream([Message.user('hi')]),
        throwsA(_ollamaError(unavailable: true, status: 404)),
      );
    });

    test('a timeout is retryable', () async {
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          timeout: Duration(milliseconds: 10),
        ),
        httpClient: MockClient(
          (request) => Completer<http.Response>().future,
        ),
      );

      await expectLater(
        model.generate([Message.user('hi')]),
        throwsA(_ollamaError(retryable: true, message: contains('timed out'))),
      );
    });

    test('a failed connection is retryable and keeps its cause', () async {
      final model = OllamaChatModel(
        config: _config,
        httpClient: MockClient(
          (request) async => throw http.ClientException('Connection refused'),
        ),
      );

      await expectLater(
        model.generate([Message.user('hi')]),
        throwsA(
          _ollamaError(retryable: true).having(
            (e) => e.cause,
            'cause',
            isA<http.ClientException>(),
          ),
        ),
      );
    });

    test('RetryingChatModel retries a 503 from Ollama', () async {
      var calls = 0;
      final model = RetryingChatModel(
        OllamaChatModel(
          config: _config,
          httpClient: MockClient((request) async {
            calls++;
            return calls == 1
                ? http.Response('{"error":"server busy"}', 503)
                : http.Response(jsonEncode(_done(content: 'ok')), 200);
          }),
        ),
        maxAttempts: 2,
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 1),
      );

      expect((await model.generate([Message.user('hi')])).content, 'ok');
      expect(calls, 2);
    });

    test('fromStreamError classifies by message', () {
      expect(
        OllamaException.fromStreamError('model "x" not found').isModelUnavailable,
        isTrue,
      );
      final other = OllamaException.fromStreamError('boom');
      expect(other.isModelUnavailable, isFalse);
      expect(other.isRetryable, isFalse);
      expect(other.statusCode, isNull);
      expect(other.message, 'boom');
    });
  });

  group('callbacks', () {
    test('generate reports the call with the configured sampling options',
        () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          options: OllamaOptions(temperature: 0.4, topP: 0.9, stop: ['x']),
        ),
        httpClient: _answering([], _done(content: 'hello')),
      ).withTools([_weatherTool]);
      final messages = [Message.user('hi')];

      final answer = await model.generate(
        messages,
        options: _with(recorder).copyWith(
          maxTokens: 64,
          toolChoice: ToolChoice.allowed,
        ),
      );

      expect(recorder.timings, ['start', 'end']);
      expect(
        recorder.infos.single,
        const RunInfo(
          name: '',
          type: 'Ollama',
          componentType: ComponentType.chatModel,
        ),
      );
      final input = recorder.input!;
      expect(input.messages, same(messages));
      expect(input.tools!.single.name, 'get_current_weather');
      expect(input.toolChoice, ToolChoice.allowed);
      expect(input.config!.model, 'llama3.2');
      // As in Go, the configured options are what the call is made with.
      expect(input.config!.temperature, 0.4);
      expect(input.config!.topP, 0.9);
      expect(input.config!.stop, ['x']);
      expect(input.config!.maxTokens, 64);

      final output = recorder.output!;
      expect(output.message, same(answer));
      expect(output.tokenUsage!.promptTokens, 26);
      expect(output.tokenUsage!.completionTokens, 282);
    });

    test('the model and temperature of the call are the ones reported',
        () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          options: OllamaOptions(temperature: 0.4),
        ),
        httpClient: _answering([], _done()),
      );

      await model.generate(
        [Message.user('hi')],
        options: _with(recorder).copyWith(model: 'qwen3', temperature: 0),
      );

      expect(recorder.input!.config!.model, 'qwen3');
      expect(recorder.input!.config!.temperature, 0);
    });

    test('an empty stop list of a call reports the stop sequences it sends',
        () async {
      final log = <_Request>[];
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: const OllamaConfig(
          model: 'llama3.2',
          options: OllamaOptions(stop: ['User:']),
        ),
        httpClient: _answering(log, _done()),
      );

      await model.generate(
        [Message.user('hi')],
        options: _with(recorder).copyWith(stop: []),
      );

      expect((log.single.body['options']! as Map)['stop'], ['User:']);
      expect(recorder.input!.config!.stop, ['User:']);
    });

    test('generate reports the metrics in the output extra', () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], _done(content: 'hello')),
      );

      await model.generate([Message.user('hi')], options: _with(recorder));

      expect(recorder.output!.extra, {
        ollamaMetricsExtraKey: {
          'total_duration': 4883583458,
          'load_duration': 1334875,
          'prompt_eval_count': 26,
          'prompt_eval_duration': 342546000,
          'eval_count': 282,
          'eval_duration': 4535599000,
        },
      });
    });

    test('stream reports the metrics in the extra of the last chunk only',
        () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], _lines([_chunk('Hel'), _done(content: 'lo')])),
      );

      final reader = await model.stream(
        [Message.user('hi')],
        options: _with(recorder),
      );
      await reader.collectAll();
      await reader.close();
      await recorder.streamDone.future;

      expect(recorder.chunks.first!.extra, isNull);
      expect(
        (recorder.chunks.last!.extra![ollamaMetricsExtraKey]! as Map)['eval_count'],
        282,
      );
    });

    test('a failed call is reported to the error callback and rethrown',
        () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], {'error': 'boom'}, status: 500),
      );

      await expectLater(
        model.generate([Message.user('hi')], options: _with(recorder)),
        throwsA(isA<OllamaException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<OllamaException>());
    });

    test('a cancelled call is reported as the cancellation it is', () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], _done()),
      );

      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: _with(recorder).copyWith(
            cancelToken: CancelToken()..cancel('stop'),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<CancelledException>());
    });

    test('stream: every handler gets the chunks, the caller the messages',
        () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], _lines([_chunk('Hel'), _done(content: 'lo')])),
      );

      final reader = await model.stream(
        [Message.user('hi')],
        options: _with(recorder),
      );
      final chunks = await reader.collectAll();
      await reader.close();
      await recorder.streamDone.future;

      expect([for (final chunk in chunks) chunk.content], ['Hel', 'lo']);
      expect(recorder.timings, ['start', 'endStream']);
      expect(
        [for (final chunk in recorder.chunks) chunk!.message!.content],
        ['Hel', 'lo'],
      );
      expect(recorder.chunks.last!.message!.ollamaMetrics, isNotNull);
      expect(recorder.infos.single.type, 'Ollama');
    });

    test('a stream the server rejects is reported to the error callback',
        () async {
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: _config,
        httpClient: _streaming([], [utf8.encode('{"error":"bad"}')], status: 400),
      );

      await expectLater(
        model.stream([Message.user('hi')], options: _with(recorder)),
        throwsA(isA<OllamaException>()),
      );
      expect(recorder.timings, ['start', 'error']);
    });

    test('global handlers hear a call that has no run context', () async {
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder]);
      final model = OllamaChatModel(
        config: _config,
        httpClient: _answering([], _done()),
      );

      await model.generate([Message.user('hi')]);

      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'Ollama');
    });
  });

  group('component and lifecycle', () {
    test('type name and callback awareness (Go: GetType, IsCallbacksEnabled)',
        () {
      final model = OllamaChatModel(config: _config);
      expect(model.componentTypeName, 'Ollama');
      expect(model.isCallbacksEnabled, isTrue);
      expect(componentTypeNameOf(model), 'Ollama');
      expect(isCallbacksEnabled(model), isTrue);
    });

    test('withTools shares the injected client; dispose leaves it open',
        () async {
      final client = _RecordingClient();
      final model = OllamaChatModel(config: _config, httpClient: client);
      final bound = model.withTools([_weatherTool]);

      await model.generate([Message.user('a')]);
      await bound.generate([Message.user('b')]);
      expect(client.requests, hasLength(2));

      model.dispose();
      expect(client.isClosed, isFalse);
    });

    test('withTools shares the client the model made: dispose stops both',
        () async {
      final model = OllamaChatModel(config: _config);
      final bound = model.withTools([_weatherTool]);

      model.dispose();

      await expectLater(bound.generate([Message.user('a')]), throwsStateError);
      await expectLater(model.stream([Message.user('a')]), throwsStateError);
      model.dispose(); // safe to repeat
    });
  });
}
