// Recorded-shape fixtures of the Anthropic Messages API (the JSON and the
// server-sent events the API sends, as in the Anthropic API reference and
// streaming docs) and fake HTTP clients for the ClaudeAgenticModel tests.
// No test touches the network.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_config.dart';

/// The model of the test configs.
const testModel = 'claude-test-model';

/// A config with a test key.
const testConfig = ClaudeAgenticConfig(
  apiKey: 'test-key',
  model: testModel,
  maxTokens: 1024,
);

/// One request a fake received.
final class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

/// Records the requests of a [MockClient].
final class Recorder {
  final List<RecordedRequest> requests = [];

  /// The body of the only request.
  Map<String, Object?> get body => requests.single.body;

  /// The headers of the only request.
  Map<String, String> get headers => requests.single.headers;

  void record(http.BaseRequest request, String body) {
    requests.add(
      RecordedRequest(
        request.method,
        request.url,
        Map.of(request.headers),
        (jsonDecode(body) as Map).cast<String, Object?>(),
      ),
    );
  }

  /// A client that answers every request with [body] as JSON.
  MockClient json(
    Map<String, Object?> body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) => MockClient((request) async {
    record(request, request.body);
    return http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...headers},
    );
  });

  /// A client that answers every request with [status] and the raw [body].
  MockClient raw(
    String body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) => MockClient((request) async {
    record(request, request.body);
    return http.Response(body, status, headers: headers);
  });

  /// A client whose response body arrives in [chunks].
  MockClient sse(List<String> chunks, {int status = 200}) =>
      MockClient.streaming((request, bodyStream) async {
        record(request, await bodyStream.bytesToString());
        return http.StreamedResponse(
          Stream.fromIterable([for (final chunk in chunks) utf8.encode(chunk)]),
          status,
          headers: {'content-type': 'text/event-stream'},
        );
      });

  /// A client whose response body is [body], a stream the test controls.
  MockClient streaming(
    Stream<List<int>> Function() body, {
    int status = 200,
    Map<String, String> headers = const {'content-type': 'text/event-stream'},
  }) => MockClient.streaming((request, bodyStream) async {
    record(request, await bodyStream.bytesToString());
    return http.StreamedResponse(body(), status, headers: headers);
  });

  /// A client whose response headers arrive when [respond] completes.
  MockClient delayed(Future<http.StreamedResponse> Function() respond) =>
      MockClient.streaming((request, bodyStream) async {
        record(request, await bodyStream.bytesToString());
        return respond();
      });
}

/// One server-sent event as the API sends it.
String sseEvent(String event, Map<String, Object?> data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

/// A complete (non-streaming) response.
Map<String, Object?> messageResponse(
  List<Map<String, Object?>> content, {
  String? stopReason = 'end_turn',
  Map<String, Object?> usage = const {'input_tokens': 10, 'output_tokens': 5},
}) => {
  'id': 'msg_01XFDUDYJgAACzvnptvVoYEL',
  'type': 'message',
  'role': 'assistant',
  'model': testModel,
  'content': content,
  'stop_reason': stopReason,
  'stop_sequence': null,
  'usage': usage,
};

/// The events of a stream that answers with [first] and [second] as two
/// text deltas.
List<String> textStream(String first, String second) => [
  sseEvent('message_start', {
    'type': 'message_start',
    'message': {
      'id': 'msg_stream',
      'type': 'message',
      'role': 'assistant',
      'model': testModel,
      'content': <Object?>[],
      'stop_reason': null,
      'stop_sequence': null,
      'usage': {'input_tokens': 25, 'output_tokens': 1},
    },
  }),
  sseEvent('content_block_start', {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': ''},
  }),
  sseEvent('ping', {'type': 'ping'}),
  sseEvent('content_block_delta', {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': first},
  }),
  sseEvent('content_block_delta', {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': second},
  }),
  sseEvent('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
  sseEvent('message_delta', {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
    'usage': {'output_tokens': 15},
  }),
  sseEvent('message_stop', {'type': 'message_stop'}),
];
