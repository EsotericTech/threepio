// Recorded-shape fixtures of the OpenAI Responses API (the JSON and the
// server-sent events the API sends, as in the API reference and the
// streaming guide) and a fake HTTP client for the OpenAI Responses tests.
// No test touches the network.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One request the fake received.
final class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

/// A fake Responses API: records the requests and answers with [respond]
/// (called with the number of the request, from 0).
final class FakeOpenAI extends http.BaseClient {
  FakeOpenAI(this.respond);

  /// Answers every request with [body] as JSON.
  factory FakeOpenAI.json(
    Map<String, Object?> body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) =>
      FakeOpenAI(
        (request, attempt) => jsonResponse(body, status: status, headers: headers),
      );

  /// Answers every request with a stream whose body arrives in [chunks].
  factory FakeOpenAI.sse(List<String> chunks) => FakeOpenAI(
        (request, attempt) => http.StreamedResponse(
          Stream.fromIterable([for (final chunk in chunks) utf8.encode(chunk)]),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );

  final FutureOr<http.StreamedResponse> Function(
    RecordedRequest request,
    int attempt,
  ) respond;
  final List<RecordedRequest> requests = [];

  /// The body of the only request.
  Map<String, Object?> get body => requests.single.body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final recorded = RecordedRequest(
      request.method,
      request.url,
      request.headers,
      jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
    );
    requests.add(recorded);
    return respond(recorded, requests.length - 1);
  }
}

/// A response with [body] as JSON.
http.StreamedResponse jsonResponse(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const {},
}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
      headers: {'content-type': 'application/json', ...headers},
    );

/// An error body as the API sends it.
Map<String, Object?> errorBody(String message, {String? code}) => {
      'error': {
        'message': message,
        'type': 'invalid_request_error',
        'param': null,
        'code': code,
      },
    };

/// A complete response with reasoning, text with a citation and a function
/// call.
Map<String, Object?> completeResponse() => {
      'id': 'resp_67ccd2bed1ec8190b14f964abc0542670bb6a6b452d3795b',
      'object': 'response',
      'created_at': 1741476542,
      'status': 'completed',
      'error': null,
      'incomplete_details': null,
      'instructions': null,
      'max_output_tokens': null,
      'model': 'gpt-5-2025-08-07',
      'output': [
        {
          'type': 'reasoning',
          'id': 'rs_1',
          'summary': [
            {'type': 'summary_text', 'text': 'Thinking about the weather.'},
          ],
          'encrypted_content': 'gAAAAenc',
        },
        {
          'type': 'message',
          'id': 'msg_67ccd2bf17f0819081ff3bb2cf6508e60bb6a6b452d3795b',
          'status': 'completed',
          'role': 'assistant',
          'content': [
            {
              'type': 'output_text',
              'text': 'It is sunny in Paris.',
              'annotations': [
                {
                  'type': 'url_citation',
                  'start_index': 0,
                  'end_index': 5,
                  'url': 'https://weather.example',
                  'title': 'Weather',
                },
              ],
            },
          ],
        },
        {
          'type': 'function_call',
          'id': 'fc_1',
          'call_id': 'call_1',
          'name': 'get_weather',
          'arguments': '{"city":"Paris"}',
          'status': 'completed',
        },
      ],
      'parallel_tool_calls': true,
      'previous_response_id': null,
      'reasoning': {'effort': 'low', 'summary': 'auto'},
      'service_tier': 'default',
      'store': true,
      'temperature': 1.0,
      'text': {
        'format': {'type': 'text'},
      },
      'tool_choice': 'auto',
      'tools': <Object?>[],
      'top_p': 1.0,
      'truncation': 'disabled',
      'usage': {
        'input_tokens': 36,
        'input_tokens_details': {'cached_tokens': 4},
        'output_tokens': 87,
        'output_tokens_details': {'reasoning_tokens': 12},
        'total_tokens': 123,
      },
      'user': null,
      'metadata': <String, Object?>{},
    };

/// One server-sent event.
String sse(Map<String, Object?> data) =>
    'event: ${data['type']}\ndata: ${jsonEncode(data)}\n\n';

Map<String, Object?> _response(String status, {Map<String, Object?>? usage}) =>
    {
      'id': 'resp_1',
      'object': 'response',
      'created_at': 1741290958,
      'status': status,
      'error': null,
      'incomplete_details': null,
      'model': 'gpt-5-2025-08-07',
      'output': <Object?>[],
      'usage': usage,
    };

/// A streamed response: reasoning with two summaries, text with a citation,
/// and a function call.
List<String> streamedResponse() {
  var seq = 0;
  String event(Map<String, Object?> data) =>
      sse({...data, 'sequence_number': seq++});
  return [
    event({'type': 'response.created', 'response': _response('in_progress')}),
    event({
      'type': 'response.in_progress',
      'response': _response('in_progress'),
    }),
    event({
      'type': 'response.output_item.added',
      'output_index': 0,
      'item': {'id': 'rs_1', 'type': 'reasoning', 'summary': <Object?>[]},
    }),
    event({
      'type': 'response.reasoning_summary_text.delta',
      'item_id': 'rs_1',
      'output_index': 0,
      'summary_index': 0,
      'delta': 'Thinking',
    }),
    event({
      'type': 'response.reasoning_summary_text.delta',
      'item_id': 'rs_1',
      'output_index': 0,
      'summary_index': 0,
      'delta': ' hard.',
    }),
    event({
      'type': 'response.reasoning_summary_text.delta',
      'item_id': 'rs_1',
      'output_index': 0,
      'summary_index': 1,
      'delta': 'Done.',
    }),
    event({
      'type': 'response.output_item.done',
      'output_index': 0,
      'item': {
        'id': 'rs_1',
        'type': 'reasoning',
        'status': 'completed',
        'summary': [
          {'type': 'summary_text', 'text': 'Thinking hard.'},
          {'type': 'summary_text', 'text': 'Done.'},
        ],
      },
    }),
    event({
      'type': 'response.output_item.added',
      'output_index': 1,
      'item': {
        'id': 'msg_1',
        'status': 'in_progress',
        'type': 'message',
        'role': 'assistant',
        'content': <Object?>[],
      },
    }),
    event({
      'type': 'response.content_part.added',
      'item_id': 'msg_1',
      'output_index': 1,
      'content_index': 0,
      'part': {'type': 'output_text', 'text': '', 'annotations': <Object?>[]},
    }),
    event({
      'type': 'response.output_text.delta',
      'item_id': 'msg_1',
      'output_index': 1,
      'content_index': 0,
      'delta': 'Hi',
    }),
    event({
      'type': 'response.output_text.delta',
      'item_id': 'msg_1',
      'output_index': 1,
      'content_index': 0,
      'delta': ' there!',
    }),
    event({
      'type': 'response.output_text.annotation.added',
      'item_id': 'msg_1',
      'output_index': 1,
      'content_index': 0,
      'annotation_index': 0,
      'annotation': {
        'type': 'url_citation',
        'start_index': 0,
        'end_index': 2,
        'url': 'https://example.com',
        'title': 'Example',
      },
    }),
    event({
      'type': 'response.output_text.done',
      'item_id': 'msg_1',
      'output_index': 1,
      'content_index': 0,
      'text': 'Hi there!',
    }),
    event({
      'type': 'response.content_part.done',
      'item_id': 'msg_1',
      'output_index': 1,
      'content_index': 0,
      'part': {'type': 'output_text', 'text': 'Hi there!', 'annotations': <Object?>[]},
    }),
    event({
      'type': 'response.output_item.done',
      'output_index': 1,
      'item': {
        'id': 'msg_1',
        'status': 'completed',
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': 'Hi there!', 'annotations': <Object?>[]},
        ],
      },
    }),
    event({
      'type': 'response.output_item.added',
      'output_index': 2,
      'item': {
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'get_weather',
        'arguments': '',
        'status': 'in_progress',
      },
    }),
    event({
      'type': 'response.function_call_arguments.delta',
      'item_id': 'fc_1',
      'output_index': 2,
      'delta': '{"city":',
    }),
    event({
      'type': 'response.function_call_arguments.delta',
      'item_id': 'fc_1',
      'output_index': 2,
      'delta': '"Paris"}',
    }),
    event({
      'type': 'response.function_call_arguments.done',
      'item_id': 'fc_1',
      'output_index': 2,
      'arguments': '{"city":"Paris"}',
    }),
    event({
      'type': 'response.output_item.done',
      'output_index': 2,
      'item': {
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'get_weather',
        'arguments': '{"city":"Paris"}',
        'status': 'completed',
      },
    }),
    event({
      'type': 'response.completed',
      'response': _response(
        'completed',
        usage: {
          'input_tokens': 10,
          'input_tokens_details': {'cached_tokens': 0},
          'output_tokens': 20,
          'output_tokens_details': {'reasoning_tokens': 5},
          'total_tokens': 30,
        },
      ),
    }),
  ];
}
