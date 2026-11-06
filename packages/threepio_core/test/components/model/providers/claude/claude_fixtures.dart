// Recorded-shape fixtures of the Anthropic Messages API (the JSON the API
// sends, as in the Anthropic API reference and streaming docs) and a fake
// HTTP client for the Claude tests. No test touches the network.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:threepio_core/src/components/model/providers/claude/claude_config.dart';

/// The model of the test configs.
const testModel = 'claude-test-model';

/// A config with a test key.
const testConfig = ClaudeConfig(
  apiKey: 'test-key',
  model: testModel,
  maxTokens: 1024,
);

/// One request the fake received.
final class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?>? body;
}

/// A fake Anthropic API: records the requests and answers with [respond].
final class FakeAnthropic extends http.BaseClient {
  FakeAnthropic(this.respond);

  /// Answers every request with [body] as JSON.
  factory FakeAnthropic.json(
    Map<String, Object?> body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) =>
      FakeAnthropic(
        (request) => http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(body))),
          status,
          headers: {'content-type': 'application/json', ...headers},
        ),
      );

  /// Answers every request with [status] and the raw [body].
  factory FakeAnthropic.raw(
    String body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) =>
      FakeAnthropic(
        (request) => http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          status,
          headers: headers,
        ),
      );

  /// Answers every request with a stream whose body arrives in [chunks].
  factory FakeAnthropic.sse(List<String> chunks) => FakeAnthropic(
        (request) => http.StreamedResponse(
          Stream.fromIterable([for (final chunk in chunks) utf8.encode(chunk)]),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );

  final FutureOr<http.StreamedResponse> Function(RecordedRequest request)
      respond;
  final List<RecordedRequest> requests = [];
  bool isClosed = false;

  /// The body of the only request.
  Map<String, Object?> get body => requests.single.body!;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final text = request is http.Request
        ? request.body
        : await request.finalize().bytesToString();
    final recorded = RecordedRequest(
      request.method,
      request.url,
      Map.of(request.headers),
      text.isEmpty ? null : (jsonDecode(text) as Map).cast<String, Object?>(),
    );
    requests.add(recorded);
    return respond(recorded);
  }

  @override
  void close() => isClosed = true;
}

/// One server-sent event as the API sends it.
String sseEvent(String event, Map<String, Object?> data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

/// A complete (non-streaming) response.
Map<String, Object?> messageResponse(
  List<Map<String, Object?>> content, {
  String? stopReason = 'end_turn',
  Map<String, Object?> usage = const {'input_tokens': 10, 'output_tokens': 5},
}) =>
    {
      'id': 'msg_01XFDUDYJgAACzvnptvVoYEL',
      'type': 'message',
      'role': 'assistant',
      'model': testModel,
      'content': content,
      'stop_reason': stopReason,
      'stop_sequence': null,
      'usage': usage,
    };

Map<String, Object?> textBlock(String text) => {'type': 'text', 'text': text};

Map<String, Object?> toolUseBlock(
  String id,
  String name,
  Map<String, Object?> input,
) =>
    {'type': 'tool_use', 'id': id, 'name': name, 'input': input};

/// `message_start`, with the usage the API reports at the start.
String messageStart({
  int inputTokens = 25,
  int cacheCreation = 0,
  int cacheRead = 0,
}) =>
    sseEvent('message_start', {
      'type': 'message_start',
      'message': {
        'id': 'msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY',
        'type': 'message',
        'role': 'assistant',
        'model': testModel,
        'content': <Object?>[],
        'stop_reason': null,
        'stop_sequence': null,
        'usage': {
          'input_tokens': inputTokens,
          'cache_creation_input_tokens': cacheCreation,
          'cache_read_input_tokens': cacheRead,
          'output_tokens': 1,
        },
      },
    });

String blockStart(int index, Map<String, Object?> block) =>
    sseEvent('content_block_start', {
      'type': 'content_block_start',
      'index': index,
      'content_block': block,
    });

String blockDelta(int index, Map<String, Object?> delta) =>
    sseEvent('content_block_delta', {
      'type': 'content_block_delta',
      'index': index,
      'delta': delta,
    });

String textDelta(int index, String text) =>
    blockDelta(index, {'type': 'text_delta', 'text': text});

String jsonDelta(int index, String partial) =>
    blockDelta(index, {'type': 'input_json_delta', 'partial_json': partial});

String blockStop(int index) => sseEvent(
      'content_block_stop',
      {'type': 'content_block_stop', 'index': index},
    );

String messageDelta(String stopReason, {int outputTokens = 15}) =>
    sseEvent('message_delta', {
      'type': 'message_delta',
      'delta': {'stop_reason': stopReason, 'stop_sequence': null},
      'usage': {'output_tokens': outputTokens},
    });

final messageStop = sseEvent('message_stop', {'type': 'message_stop'});

final ping = sseEvent('ping', {'type': 'ping'});

/// The text stream of the Anthropic streaming docs: "Hello!".
List<String> textStream() => [
      messageStart(),
      blockStart(0, {'type': 'text', 'text': ''}),
      ping,
      textDelta(0, 'Hello'),
      textDelta(0, '!'),
      blockStop(0),
      messageDelta('end_turn'),
      messageStop,
    ];

/// The tool use stream of the Anthropic streaming docs.
List<String> toolUseStream() => [
      messageStart(inputTokens: 472),
      blockStart(0, {'type': 'text', 'text': ''}),
      textDelta(0, 'Okay, let me check.'),
      blockStop(0),
      blockStart(1, {
        'type': 'tool_use',
        'id': 'toolu_01T1x1fJ34qAmk2tNTrN7Up6',
        'name': 'get_weather',
        'input': <String, Object?>{},
      }),
      jsonDelta(1, ''),
      jsonDelta(1, '{"location":'),
      jsonDelta(1, ' "San Fra'),
      jsonDelta(1, 'ncisco, CA"}'),
      blockStop(1),
      messageDelta('tool_use', outputTokens: 89),
      messageStop,
    ];

/// A stream with thinking and its signature, then text.
List<String> thinkingStream() => [
      messageStart(),
      blockStart(0, {'type': 'thinking', 'thinking': '', 'signature': ''}),
      blockDelta(0, {'type': 'thinking_delta', 'thinking': 'Let me solve '}),
      blockDelta(0, {'type': 'thinking_delta', 'thinking': 'this.'}),
      blockDelta(0, {'type': 'signature_delta', 'signature': 'EqQBCgIYAhIM'}),
      // The signature may come in more than one delta; they are appended.
      blockDelta(0, {'type': 'signature_delta', 'signature': '1gbcDa9GJwZA'}),
      blockStop(0),
      blockStart(1, {'type': 'text', 'text': ''}),
      textDelta(1, 'The answer is 4.'),
      blockStop(1),
      messageDelta('end_turn'),
      messageStop,
    ];
