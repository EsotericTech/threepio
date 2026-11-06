// Tests written for the port (P13 review findings on the shared provider
// HTTP helpers): a header value dart:io refuses must not put the value (an
// API key) into the error text, and a streamed response that arrives after
// the header timeout must be drained so that its connection is let go.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/internal/provider_http.dart';
import 'package:threepio_core/threepio_core.dart';

/// A client whose response arrives after [delay], with a body whose
/// listening and cancelling the test can see.
final class _LateClient extends http.BaseClient {
  _LateClient(this.delay);

  final Duration delay;
  final body = StreamController<List<int>>();
  var listened = false;
  var cancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    body
      ..onListen = () {
        listened = true;
      }
      ..onCancel = () {
        cancelled = true;
      };
    await Future<void>.delayed(delay);
    return http.StreamedResponse(body.stream, 200);
  }
}

/// A client whose response (or failure) arrives when the test says so.
final class _PendingClient extends http.BaseClient {
  final response = Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      response.future;
}

void main() {
  group('a header value dart:io refuses', () {
    late HttpServer server;
    late Uri url;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 200;
        await request.response.close();
      });
      url = Uri.parse('http://127.0.0.1:${server.port}/v1/messages');
    });

    tearDown(() => server.close(force: true));

    const secret = 'sk-test-0123456789\n';

    for (final streaming in [false, true]) {
      test(
          '${streaming ? 'sendStreamingRequest' : 'sendRequest'} names the '
          'header, not the value', () async {
        final client = http.Client();
        addTearDown(client.close);
        Object? caught;
        try {
          final headers = {'x-api-key': secret, 'content-type': 'text/plain'};
          if (streaming) {
            await sendStreamingRequest(
              client,
              url,
              headers: headers,
              body: '{}',
              timeout: const Duration(seconds: 5),
            );
          } else {
            await sendRequest(
              client,
              url,
              headers: headers,
              body: '{}',
              timeout: const Duration(seconds: 5),
            );
          }
        } on Object catch (error) {
          caught = error;
        }
        expect(caught, isA<ThreepioFormatException>());
        final text = caught.toString();
        expect(text, contains('invalid header field value for "x-api-key"'));
        expect(text, isNot(contains('sk-test')));
        expect((caught! as ThreepioFormatException).source, isNull);
        expect((caught as ThreepioFormatException).cause, isNull);
      });
    }

    test('a header name dart:io refuses keeps its own error', () async {
      final client = http.Client();
      addTearDown(client.close);
      await expectLater(
        sendRequest(
          client,
          url,
          headers: {'bad name': 'v'},
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            startsWith('Invalid HTTP header field name'),
          ),
        ),
      );
    });
  });

  group('sendStreamingRequest after the header timeout', () {
    for (final withToken in [false, true]) {
      test(
          'drains a response that still arrives '
          '(${withToken ? 'with' : 'without'} a cancel token)', () async {
        final client = _LateClient(const Duration(milliseconds: 30));
        await expectLater(
          sendStreamingRequest(
            client,
            Uri.parse('https://api.example.com/v1/responses'),
            headers: const {},
            timeout: const Duration(milliseconds: 5),
            cancelToken: withToken ? CancelToken() : null,
          ),
          throwsA(isA<TimeoutException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 45));
        expect(client.listened, isTrue);
        expect(client.cancelled, isTrue);
      });
    }

    test('a response in time is left to the caller', () async {
      final client = _LateClient(Duration.zero);
      final response = await sendStreamingRequest(
        client,
        Uri.parse('https://api.example.com/v1/responses'),
        headers: const {},
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.listened, isFalse);
      expect(response.statusCode, 200);
      await response.stream.listen(null).cancel();
    });
  });

  group('the helpers keep what Future.timeout and the cancel token throw', () {
    for (final streaming in [false, true]) {
      final name = streaming ? 'sendStreamingRequest' : 'sendRequest';
      Future<Object?> send(
        http.Client client, {
        Duration timeout = const Duration(milliseconds: 5),
        CancelToken? cancelToken,
      }) =>
          streaming
              ? sendStreamingRequest(
                  client,
                  Uri.parse('https://api.example.com/v1/responses'),
                  headers: const {},
                  timeout: timeout,
                  cancelToken: cancelToken,
                )
              : sendRequest(
                  client,
                  Uri.parse('https://api.example.com/v1/responses'),
                  headers: const {},
                  timeout: timeout,
                  cancelToken: cancelToken,
                );

      for (final withToken in [false, true]) {
        test(
            "$name: the timeout is Future.timeout's TimeoutException, and a "
            'failure that arrives later is not unhandled '
            '(${withToken ? 'with' : 'without'} a cancel token)', () async {
          final client = _PendingClient();
          const timeout = Duration(milliseconds: 5); // send's default
          await expectLater(
            send(client, cancelToken: withToken ? CancelToken() : null),
            throwsA(
              isA<TimeoutException>()
                  .having((e) => e.message, 'message', 'Future not completed')
                  .having((e) => e.duration, 'duration', timeout),
            ),
          );
          // An uncaught error here would fail the test.
          client.response.completeError(http.ClientException('reset'));
          await pumpEventQueue();
        });
      }

      test(
          '$name: a cancel is a CancelledException with the reason, and a '
          'failure that arrives later is not unhandled', () async {
        final client = _PendingClient();
        final token = CancelToken();
        final future = send(
          client,
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        );
        await pumpEventQueue();
        token.cancel('gone');
        await expectLater(
          future,
          throwsA(
            isA<CancelledException>().having((e) => e.reason, 'reason', 'gone'),
          ),
        );
        client.response.completeError(http.ClientException('reset'));
        await pumpEventQueue();
      });
    }
  });
}
