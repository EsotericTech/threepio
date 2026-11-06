// Tests written for the port (no Go counterpart; Go providers get timeouts
// and cancellation from `http.Client` and `context.Context`): `sendRequest`
// and `sendStreamingRequest` send the request, bound the wait for the
// response (headers) with a timeout and abandon it when the cancel token
// fires, draining a streamed response that still arrives.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/internal/provider_http.dart';
import 'package:threepio_core/threepio_core.dart';

/// A client whose response arrives when the test says so.
final class _PendingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final response = Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return response.future;
  }
}

final _url = Uri.parse('https://api.example.com/v1/chat/completions');

void main() {
  group('sendRequest', () {
    test('sends the method, headers and body and returns the response',
        () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('{"ok":true}', 201);
      });

      final response = await sendRequest(
        client,
        _url,
        headers: {'Authorization': 'Bearer test-key', 'X-A': '1'},
        body: '{"model":"m"}',
        timeout: const Duration(seconds: 5),
      );

      expect(response.statusCode, 201);
      expect(response.body, '{"ok":true}');
      expect(seen.method, 'POST');
      expect(seen.url, _url);
      expect(seen.headers['Authorization'], 'Bearer test-key');
      expect(seen.headers['X-A'], '1');
      expect(seen.body, '{"model":"m"}');
    });

    test('another method without a body', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response('[]', 200);
      });
      await sendRequest(
        client,
        _url,
        method: 'GET',
        headers: const {},
        timeout: const Duration(seconds: 5),
      );
      expect(seen.method, 'GET');
      expect(seen.body, isEmpty);
    });

    test('a response that takes too long is a TimeoutException', () async {
      final client = _PendingClient();
      await expectLater(
        sendRequest(
          client,
          _url,
          headers: const {},
          body: '{}',
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a token cancelled before sends nothing', () async {
      final client = _PendingClient();
      await expectLater(
        sendRequest(
          client,
          _url,
          headers: const {},
          timeout: const Duration(seconds: 5),
          cancelToken: CancelToken()..cancel('before'),
        ),
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'before'),
        ),
      );
      expect(client.requests, isEmpty);
    });

    test('a token cancelled while waiting abandons the wait', () async {
      final client = _PendingClient();
      final token = CancelToken();
      final future = sendRequest(
        client,
        _url,
        headers: const {},
        timeout: const Duration(seconds: 5),
        cancelToken: token,
      );
      await pumpEventQueue();
      expect(client.requests, hasLength(1));

      token.cancel('during');
      await expectLater(
        future,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'during'),
        ),
      );
    });

    test('a failure of the client is rethrown as it is', () async {
      final client = MockClient(
        (request) async => throw http.ClientException('connection refused'),
      );
      await expectLater(
        sendRequest(
          client,
          _url,
          headers: const {},
          timeout: const Duration(seconds: 5),
          cancelToken: CancelToken(),
        ),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('sendStreamingRequest', () {
    test("returns once the headers are there; the body is the caller's",
        () async {
      late http.BaseRequest seen;
      final client = MockClient.streaming((request, body) async {
        seen = request;
        expect(await body.bytesToString(), '{"stream":true}');
        return http.StreamedResponse(
          Stream.fromIterable([utf8.encode('data: 1\n\n')]),
          200,
        );
      });

      final response = await sendStreamingRequest(
        client,
        _url,
        headers: {'Accept': 'text/event-stream'},
        body: '{"stream":true}',
        timeout: const Duration(seconds: 5),
        cancelToken: CancelToken(),
      );

      expect(response.statusCode, 200);
      expect(seen.headers['Accept'], 'text/event-stream');
      expect(await response.stream.bytesToString(), 'data: 1\n\n');
    });

    test('headers that take too long are a TimeoutException', () async {
      await expectLater(
        sendStreamingRequest(
          _PendingClient(),
          _url,
          headers: const {},
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a token cancelled before sends nothing', () async {
      final client = _PendingClient();
      await expectLater(
        sendStreamingRequest(
          client,
          _url,
          headers: const {},
          timeout: const Duration(seconds: 5),
          cancelToken: CancelToken()..cancel(),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(client.requests, isEmpty);
    });

    test('a response that arrives after the cancel is drained', () async {
      final client = _PendingClient();
      final token = CancelToken();
      final future = sendStreamingRequest(
        client,
        _url,
        headers: const {},
        timeout: const Duration(seconds: 5),
        cancelToken: token,
      );
      await pumpEventQueue();

      token.cancel('gone');
      await expectLater(future, throwsA(isA<CancelledException>()));

      var listened = false;
      var cancelled = false;
      final body = StreamController<List<int>>(
        onListen: () => listened = true,
        onCancel: () async => cancelled = true,
      );
      client.response.complete(http.StreamedResponse(body.stream, 200));
      await pumpEventQueue();
      expect(listened, isTrue);
      expect(cancelled, isTrue);
    });

    test('a failure of the client is rethrown as it is', () async {
      final client = MockClient.streaming(
        (request, body) async => throw http.ClientException('reset'),
      );
      await expectLater(
        sendStreamingRequest(
          client,
          _url,
          headers: const {},
          timeout: const Duration(seconds: 5),
          cancelToken: CancelToken(),
        ),
        throwsA(isA<http.ClientException>()),
      );
    });
  });
}
