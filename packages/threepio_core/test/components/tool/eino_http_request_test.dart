// Port of eino-ext `components/tool/httprequest`:
// * `httprequest_test.go`: TestNewToolKit_Success, TestNewToolKit_NilConfig;
// * `get/get_test.go`: TestGet_Success, TestGet_InvalidURL,
//   TestGet_RequestError, TestGet_ReadBodyError, TestConfig_Validate_Defaults,
//   TestConfig_Validate_WithValues, TestNewTool_NilConfig, TestNewTool_Config,
//   TestGet_WithHeaders;
// * `post/post_test.go`, `put/put_test.go`, `delete/delete_test.go`: the same
//   tests for their verb (TestPost_*, TestPut_*, TestDelete_*,
//   TestConfig_Validate_*, TestNewTool_Config).
//
// Go swaps the transport of an `http.Client` (`mockTransport`); here the tools
// get a `MockClient`. Go's `validate()` fills in the defaults of a `Config`;
// here the tool resolves them (`name`, `description`, `timeout`). Go's
// TestNewTool_NilConfig (and the NilConfig case of each TestNewTool_Config)
// expects an error for a nil config: a Dart config cannot be null, so the
// port checks that a tool made without one uses the defaults, and ports
// only the WithConfig case of TestNewTool_Config. Everything after the
// ported groups is written for the port.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/http_request/http_request_tool.dart';
import 'package:threepio_core/threepio_core.dart';

/// One verb: how to make its tool and call its typed method.
final class _Verb {
  const _Verb(this.method, this.goName, this.defaultName, this.make, this.call);

  final String method;
  final String goName;
  final String defaultName;
  final HttpRequestTool Function(HttpRequestToolConfig config) make;
  final Future<String> Function(HttpRequestTool tool, String url, String body)
      call;

  bool get hasBody => method == 'POST' || method == 'PUT';
}

final List<_Verb> _verbs = [
  _Verb(
    'GET',
    'Get',
    'request_get',
    HttpGetRequestTool.new,
    (tool, url, _) => (tool as HttpGetRequestTool)
        .get(RunContext.background(), HttpGetRequest(url: url)),
  ),
  _Verb(
    'POST',
    'Post',
    'requests_post',
    HttpPostRequestTool.new,
    (tool, url, body) => (tool as HttpPostRequestTool)
        .post(RunContext.background(), HttpPostRequest(url: url, body: body)),
  ),
  _Verb(
    'PUT',
    'Put',
    'requests_put',
    HttpPutRequestTool.new,
    (tool, url, body) => (tool as HttpPutRequestTool)
        .put(RunContext.background(), HttpPutRequest(url: url, body: body)),
  ),
  _Verb(
    'DELETE',
    'Delete',
    'requests_delete',
    HttpDeleteRequestTool.new,
    (tool, url, _) => (tool as HttpDeleteRequestTool)
        .delete(RunContext.background(), HttpDeleteRequest(url: url)),
  ),
];

/// Go's default descriptions, tabs and trailing spaces included.
const _defaultDescriptions = {
  'GET': 'A portal to the internet. Use this when you need to get specific\n'
      '\t\tcontent from a website. Input should be a URL (i.e. https://www.google.com).\n'
      '\t\tThe output will be the text response of the GET request.',
  'POST': 'Use this when you want to POST to a website.\n'
      '\t\tInput should be a JSON string with two keys: "url" and "body".\n'
      '\t\tThe value of "url" should be a string, and the value of "body" should be a dictionary of \n'
      '\t\tkey-value pairs you want to POST to the URL.\n'
      '\t\tBe careful to always use double quotes for strings in the JSON string.\n'
      '\t\tThe output will be the text response of the POST request.',
  'PUT': 'Use this when you want to PUT to a website.\n'
      '\t\tInput should be a JSON string with two keys: "url" and "body".\n'
      '\t\tThe value of "url" should be a string, and the value of "body" should be a dictionary of \n'
      '\t\tkey-value pairs you want to PUT to the URL.\n'
      '\t\tBe careful to always use double quotes for strings in the JSON string.\n'
      '\t\tThe output will be the text response of the PUT request.',
  'DELETE': 'A portal to the internet.\n'
      '\t\tUse this when you need to make a DELETE request to a URL.\n'
      '\t\tInput should be a specific url, and the output will be the text\n'
      '\t\tresponse of the DELETE request.',
};

/// What `utils.InferTool` derives from the request struct of each verb.
Map<String, Object?> _goSchema(String method) => {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': 'The URL to make the $method request',
        },
        if (method == 'POST' || method == 'PUT')
          'body': {
            'type': 'string',
            'description': 'The body to send in the $method request',
          },
      },
      'required': [
        'url',
        if (method == 'POST' || method == 'PUT') 'body',
      ],
      'additionalProperties': false,
    };

/// [value] without the entries whose value is `null`.
Object? _compact(Object? value) => switch (value) {
      final Map<String, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            if (value != null) key: _compact(value),
        },
      final List<Object?> list => [for (final item in list) _compact(item)],
      _ => value,
    };

TypeMatcher<ThreepioException> _threepio(String message) => isA<ThreepioException>()
    .having((e) => e.message, 'message', message);

TypeMatcher<ThreepioException> _threepioContaining(String part) => isA<ThreepioException>()
    .having((e) => e.message, 'message', contains(part));

/// A client that records whether it was closed.
final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => closed = true;
}

/// A client whose [send] is [onSend].
final class _CallbackClient extends http.BaseClient {
  _CallbackClient(this.onSend);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      onSend;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      onSend(request);
}

void main() {
  // -------------------------------------------------------------------------
  // httprequest_test.go
  // -------------------------------------------------------------------------

  group('TestNewToolKit_Success', () {
    test('four tools with Go names', () async {
      final kit = HttpRequestToolkit(
        HttpRequestToolkitConfig(
          headers: const {'Content-Type': 'application/json'},
          httpClient: MockClient((_) async => http.Response('', 200)),
        ),
      );
      addTearDown(kit.dispose);
      expect(kit.tools, hasLength(4));
      final names = [for (final tool in kit.tools) (await tool.info()).name];
      expect(
        names,
        containsAll(
          ['request_get', 'requests_post', 'requests_put', 'requests_delete'],
        ),
      );
    });
  });

  group('TestNewToolKit_NilConfig', () {
    test('four tools with Go names', () async {
      final kit = HttpRequestToolkit();
      addTearDown(kit.dispose);
      expect(kit.tools, hasLength(4));
      final names = [for (final tool in kit.tools) (await tool.info()).name];
      expect(
        names,
        containsAll(
          ['request_get', 'requests_post', 'requests_put', 'requests_delete'],
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // get_test.go, post_test.go, put_test.go, delete_test.go
  // -------------------------------------------------------------------------

  for (final verb in _verbs) {
    final url = verb.method == 'GET'
        ? 'https://example.com'
        : 'https://example.com/resource';
    const body = '{"key":"value"}';

    group('Test${verb.goName}_Success', () {
      test('returns the body of the response', () async {
        final mockResponse = switch (verb.method) {
          'GET' => '{"message": "Hello, World!"}',
          'POST' => '{"message": "Posted successfully"}',
          'PUT' => '{"message": "Updated successfully"}',
          _ => '{"message": "Deleted successfully"}',
        };
        final client = MockClient((request) async {
          final matches = request.url.toString() == url &&
              request.method == verb.method &&
              (!verb.hasBody || request.body == body);
          if (matches) return http.Response(mockResponse, 200);
          throw http.ClientException('unexpected URL, method, or body');
        });
        final tool = verb.make(HttpRequestToolConfig(httpClient: client));
        expect(await verb.call(tool, url, body), mockResponse);
      });
    });

    group('Test${verb.goName}_InvalidURL', () {
      test('fails to create the request', () async {
        final tool = verb.make(
          HttpRequestToolConfig(
            httpClient: MockClient((_) async => http.Response('', 200)),
          ),
        );
        await expectLater(
          verb.call(tool, 'http://:invalid', body),
          throwsA(_threepioContaining('failed to create request')),
        );
      });
    });

    group('Test${verb.goName}_RequestError', () {
      test('fails to execute the request', () async {
        final client = MockClient(
          (_) async => throw http.ClientException('network error'),
        );
        final tool = verb.make(HttpRequestToolConfig(httpClient: client));
        await expectLater(
          verb.call(tool, url, body),
          throwsA(_threepioContaining('failed to execute request')),
        );
      });
    });

    group('Test${verb.goName}_ReadBodyError', () {
      test('fails to read the body', () async {
        final client = MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            Stream<List<int>>.error(const FormatException('read error')),
            200,
          ),
        );
        final tool = verb.make(HttpRequestToolConfig(httpClient: client));
        await expectLater(
          verb.call(tool, url, body),
          throwsA(_threepioContaining('failed to read response body')),
        );
      });
    });

    group('TestConfig_Validate_Defaults (${verb.goName})', () {
      test('Go defaults', () {
        final tool = verb.make(const HttpRequestToolConfig());
        addTearDown(tool.dispose);
        expect(tool.name, verb.defaultName);
        expect(tool.description, isNotEmpty);
        expect(tool.config.headers, isEmpty);
        // Go: a default client with a 30-second timeout.
        expect(tool.config.httpClient, isNull);
        expect(tool.timeout, const Duration(seconds: 30));
      });
    });

    group('TestConfig_Validate_WithValues (${verb.goName})', () {
      test('keeps the given values', () {
        final customClient =
            MockClient((_) async => http.Response('', 200));
        final tool = verb.make(
          HttpRequestToolConfig(
            toolName: 'custom_${verb.goName.toLowerCase()}',
            toolDesc: 'Custom description',
            headers: const {'Authorization': 'Bearer token'},
            httpClient: customClient,
          ),
        );
        expect(tool.name, 'custom_${verb.goName.toLowerCase()}');
        expect(tool.description, 'Custom description');
        expect(tool.config.headers, {'Authorization': 'Bearer token'});
        expect(tool.config.httpClient, same(customClient));
      });
    });

    if (verb.method == 'GET') {
      group('TestNewTool_NilConfig', () {
        test('a tool without a config uses the defaults', () async {
          final tool = HttpGetRequestTool();
          addTearDown(tool.dispose);
          expect((await tool.info()).name, 'request_get');
        });
      });
    }

    group('TestNewTool_Config (${verb.goName})', () {
      test('WithConfig', () async {
        final tool = verb.make(const HttpRequestToolConfig());
        addTearDown(tool.dispose);
        final info = await tool.info();
        final doc = info.paramsOneOf!.toJsonSchema();
        expect(doc.properties, hasLength(verb.hasBody ? 2 : 1));
        for (final property in doc.properties.values) {
          expect(property.description, isNot(''));
          expect(property.description, isNotNull);
        }
      });
    });

    group('Test${verb.goName}_WithHeaders', () {
      test('sends the configured headers', () async {
        late http.BaseRequest received;
        final client = MockClient((request) async {
          received = request;
          return http.Response('', 200);
        });
        final tool = verb.make(
          HttpRequestToolConfig(
            headers: const {
              'Authorization': 'Bearer token',
              'User-Agent': 'test-agent',
            },
            httpClient: client,
          ),
        );
        await verb.call(tool, url, body);
        expect(received.headers['Authorization'], 'Bearer token');
        expect(received.headers['User-Agent'], 'test-agent');
      });
    });
  }

  // -------------------------------------------------------------------------
  // Written for the port.
  // -------------------------------------------------------------------------

  group('tool infos', () {
    for (final verb in _verbs) {
      test('${verb.method}: name, description and schema as Go', () async {
        final tool = verb.make(const HttpRequestToolConfig());
        addTearDown(tool.dispose);
        final info = await tool.info();
        expect(info.name, verb.defaultName);
        expect(info.desc, _defaultDescriptions[verb.method]);
        expect(
          _compact(info.paramsOneOf!.toJsonSchema().toJson()),
          _goSchema(verb.method),
        );
        // Properties in the order of the Go struct fields.
        expect(
          info.paramsOneOf!.toJsonSchema().properties.keys,
          verb.hasBody ? ['url', 'body'] : ['url'],
        );
      });
    }

    test('the default descriptions keep the tabs and trailing spaces', () {
      expect(_defaultDescriptions['GET'], contains('specific\n\t\tcontent'));
      expect(_defaultDescriptions['POST'], contains('dictionary of \n\t\tkey'));
      expect(_defaultDescriptions['PUT'], contains('dictionary of \n\t\tkey'));
      expect(_defaultDescriptions['DELETE'], endsWith('\t\tresponse of the DELETE request.'));
    });

    test('empty names and descriptions take the defaults', () async {
      final tool = HttpPostRequestTool(
        const HttpRequestToolConfig(toolName: '', toolDesc: ''),
      );
      addTearDown(tool.dispose);
      expect(tool.name, 'requests_post');
      expect(tool.description, _defaultDescriptions['POST']);
    });

    test('component type names as Go snakeToCamel', () {
      final kit = HttpRequestToolkit();
      addTearDown(kit.dispose);
      expect(
        [for (final tool in kit.tools) tool.componentTypeName],
        ['RequestGet', 'RequestsPost', 'RequestsPut', 'RequestsDelete'],
      );
    });

    test('the toolkit lists the tools in Go order', () {
      final kit = HttpRequestToolkit();
      addTearDown(kit.dispose);
      expect(kit.tools, [kit.getTool, kit.postTool, kit.putTool, kit.deleteTool]);
      expect(() => kit.tools.add(kit.getTool), throwsUnsupportedError);
    });
  });

  group('invokableRun', () {
    test('decodes the arguments and returns the raw body', () async {
      late http.Request received;
      final client = MockClient((request) async {
        received = request;
        return http.Response('{"id": 7}', 201);
      });
      final tool = HttpPostRequestTool(HttpRequestToolConfig(httpClient: client));
      final result = await tool.invokableRun(
        RunContext.background(),
        jsonEncode({'url': 'https://api.test/items', 'body': 'a=1'}),
      );
      // A string result goes to the model as it is, not JSON-encoded.
      expect(result, '{"id": 7}');
      expect(received.method, 'POST');
      expect(received.url, Uri.parse('https://api.test/items'));
      expect(received.body, 'a=1');
    });

    test('the legacy run entry point works', () async {
      final client = MockClient((_) async => http.Response('ok', 200));
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      expect(await tool.run('{"url": "https://example.com"}'), 'ok');
    });

    test('arguments of the wrong type are a format error', () async {
      final client = MockClient((_) async => http.Response('ok', 200));
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      await expectLater(
        tool.invokableRun(RunContext.background(), '{"url": 5}'),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('a missing url is empty, as in Go, and has no scheme', () async {
      final client = MockClient((_) async => http.Response('ok', 200));
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      await expectLater(
        tool.invokableRun(RunContext.background(), '{}'),
        throwsA(
          _threepio(
            'failed to execute request: Get "": unsupported protocol scheme ""',
          ),
        ),
      );
    });
  });

  group('requests', () {
    test('GET and DELETE send no body, POST and PUT send it as it is', () async {
      final seen = <String, http.Request>{};
      final client = MockClient((request) async {
        seen[request.method] = request;
        return http.Response('', 200);
      });
      final kit = HttpRequestToolkit(HttpRequestToolkitConfig(httpClient: client));
      final ctx = RunContext.background();
      await kit.getTool.get(ctx, const HttpGetRequest(url: 'https://a.test/'));
      await kit.postTool.post(
        ctx,
        const HttpPostRequest(url: 'https://a.test/', body: 'héllo'),
      );
      await kit.putTool.put(
        ctx,
        const HttpPutRequest(url: 'https://a.test/', body: 'x'),
      );
      await kit.deleteTool.delete(
        ctx,
        const HttpDeleteRequest(url: 'https://a.test/'),
      );
      expect(seen.keys, ['GET', 'POST', 'PUT', 'DELETE']);
      expect(seen['GET']!.bodyBytes, isEmpty);
      expect(seen['DELETE']!.bodyBytes, isEmpty);
      expect(seen['POST']!.bodyBytes, utf8.encode('héllo'));
      expect(seen['PUT']!.body, 'x');
    });

    test('a body gets no Content-Type of its own; a configured one is kept',
        () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return http.Response('', 200);
      });
      final plain = HttpPostRequestTool(HttpRequestToolConfig(httpClient: client));
      final json = HttpPostRequestTool(
        HttpRequestToolConfig(
          httpClient: client,
          headers: const {'Content-Type': 'application/json'},
        ),
      );
      final ctx = RunContext.background();
      await plain.post(ctx, const HttpPostRequest(url: 'https://a.test/', body: '{}'));
      await json.post(ctx, const HttpPostRequest(url: 'https://a.test/', body: '{}'));
      expect(seen[0].headers.containsKey('content-type'), isFalse);
      expect(seen[1].headers['content-type'], 'application/json');
    });

    test('an error status still returns the body', () async {
      final client = MockClient(
        (_) async => http.Response('{"error":"not found"}', 404),
      );
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      expect(
        await tool.get(
          RunContext.background(),
          const HttpGetRequest(url: 'https://a.test/missing'),
        ),
        '{"error":"not found"}',
      );
    });

    test('the body is read as UTF-8; malformed bytes become U+FFFD', () async {
      final client = MockClient(
        (_) async => http.Response.bytes([0x61, 0xff, 0x62], 200),
      );
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      final text = await tool.get(
        RunContext.background(),
        const HttpGetRequest(url: 'https://a.test/'),
      );
      expect(text.codeUnits, [0x61, 0xfffd, 0x62]);
    });

    test('Go error texts', () async {
      final client = MockClient(
        (_) async => throw http.ClientException('network error'),
      );
      final tool = HttpPutRequestTool(HttpRequestToolConfig(httpClient: client));
      final ctx = RunContext.background();
      await expectLater(
        tool.put(ctx, const HttpPutRequest(url: 'https://example.com/r')),
        throwsA(
          _threepio(
            'failed to execute request: Put "https://example.com/r": '
            'network error',
          ).having((e) => e.cause, 'cause', isA<http.ClientException>()),
        ),
      );
      await expectLater(
        tool.put(ctx, const HttpPutRequest(url: 'ftp://example.com/r')),
        throwsA(
          _threepio(
            'failed to execute request: Put "ftp://example.com/r": '
            'unsupported protocol scheme "ftp"',
          ),
        ),
      );
      await expectLater(
        tool.put(ctx, const HttpPutRequest(url: 'http://:invalid')),
        throwsA(
          _threepioContaining('failed to create request: parse "http://:invalid": ')
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });
  });

  group('passwords in addresses', () {
    test('show as *** in errors, as Go stripPassword writes them', () async {
      final client = MockClient(
        (request) async =>
            throw http.ClientException('network error', request.url),
      );
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      final error = await tool
          .get(
            RunContext.background(),
            const HttpGetRequest(url: 'https://user:secret@a.test/x'),
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        error,
        _threepio(
          'failed to execute request: Get "https://user:***@a.test/x": '
          'network error',
        ),
      );
      // Neither the text nor the cause it carries shows the password.
      expect('$error', isNot(contains('secret')));
    });

    test('an address without a password is shown as it is', () async {
      final client = MockClient(
        (request) async =>
            throw http.ClientException('network error', request.url),
      );
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      await expectLater(
        tool.get(
          RunContext.background(),
          const HttpGetRequest(url: 'https://user@a.test/x'),
        ),
        throwsA(
          _threepio(
            'failed to execute request: Get "https://user@a.test/x": '
            'network error',
          ).having(
            (e) => e.cause,
            'cause',
            isA<http.ClientException>().having(
              (e) => e.uri,
              'uri',
              Uri.parse('https://user@a.test/x'),
            ),
          ),
        ),
      );
    });
  });

  group('cancellation', () {
    test('a cancelled context sends nothing', () async {
      var sent = 0;
      final client = MockClient((_) async {
        sent++;
        return http.Response('', 200);
      });
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      final token = CancelToken()..cancel('stop');
      await expectLater(
        tool.get(
          RunContext.background(cancelToken: token),
          const HttpGetRequest(url: 'https://a.test/'),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(sent, 0);
    });

    test('cancelling while the response is awaited abandons it', () async {
      final response = Completer<http.StreamedResponse>();
      final client = MockClient.streaming((_, __) => response.future);
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      final token = CancelToken();
      final call = tool.get(
        RunContext.background(cancelToken: token),
        const HttpGetRequest(url: 'https://a.test/'),
      );
      await pumpEventQueue();
      token.cancel('user');
      await expectLater(
        call,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'user'),
        ),
      );
      // A response that arrives afterwards is drained.
      final drained = Completer<void>();
      final body = StreamController<List<int>>(onCancel: drained.complete);
      response.complete(http.StreamedResponse(body.stream, 200));
      await drained.future;
    });

    test('cancelling while the body is read stops the read', () async {
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(onCancel: cancelled.complete);
      final client = MockClient.streaming(
        (_, __) async => http.StreamedResponse(body.stream, 200),
      );
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      final token = CancelToken();
      final call = tool.get(
        RunContext.background(cancelToken: token),
        const HttpGetRequest(url: 'https://a.test/'),
      );
      body.add(utf8.encode('partial'));
      await pumpEventQueue();
      token.cancel();
      await expectLater(call, throwsA(isA<CancelledException>()));
      await cancelled.future;
    });
  });

  group('timeouts', () {
    test('waiting for the headers', () async {
      final response = Completer<http.StreamedResponse>();
      final client = MockClient.streaming((_, __) => response.future);
      final tool = HttpGetRequestTool(
        HttpRequestToolConfig(
          httpClient: client,
          timeout: const Duration(milliseconds: 20),
        ),
      );
      await expectLater(
        tool.get(
          RunContext.background(),
          const HttpGetRequest(url: 'https://a.test/'),
        ),
        throwsA(
          _threepio(
            'failed to execute request: Get "https://a.test/": context '
            'deadline exceeded (Client.Timeout exceeded while awaiting '
            'headers)',
          ).having((e) => e.cause, 'cause', isA<TimeoutException>()),
        ),
      );
      response.complete(
        http.StreamedResponse(const Stream<List<int>>.empty(), 200),
      );
    });

    test('reading the body', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final client = MockClient.streaming(
        (_, __) async => http.StreamedResponse(body.stream, 200),
      );
      final tool = HttpGetRequestTool(
        HttpRequestToolConfig(
          httpClient: client,
          timeout: const Duration(milliseconds: 20),
        ),
      );
      await expectLater(
        tool.get(
          RunContext.background(),
          const HttpGetRequest(url: 'https://a.test/'),
        ),
        throwsA(
          _threepio(
            'failed to read response body: context deadline exceeded '
            '(Client.Timeout or context cancellation while reading body)',
          ),
        ),
      );
    });

    test('a zero or negative timeout is no limit, as Go http.Client.Timeout',
        () async {
      for (final timeout in const [Duration.zero, Duration(seconds: -1)]) {
        final tool = HttpGetRequestTool(
          HttpRequestToolConfig(
            httpClient: MockClient((_) async => http.Response('ok', 200)),
            timeout: timeout,
          ),
        );
        expect(
          await tool.get(
            RunContext.background(),
            const HttpGetRequest(url: 'https://a.test/'),
          ),
          'ok',
        );
      }
    });

    test('an injected client has no limit unless one is given', () {
      final client = MockClient((_) async => http.Response('', 200));
      expect(
        HttpGetRequestTool(HttpRequestToolConfig(httpClient: client)).timeout,
        isNull,
      );
      expect(
        HttpGetRequestTool(
          HttpRequestToolConfig(
            httpClient: client,
            timeout: const Duration(seconds: 2),
          ),
        ).timeout,
        const Duration(seconds: 2),
      );
    });
  });

  group('redirects', () {
    test('302 after POST is followed with GET and no body; 307 keeps both',
        () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return switch (request.url.path) {
          '/a' => http.Response('', 302, headers: {'location': '/b'}),
          '/b' => http.Response('', 307, headers: {'location': 'https://a.test/c'}),
          _ => http.Response('done', 200),
        };
      });
      final tool = HttpPostRequestTool(
        HttpRequestToolConfig(
          httpClient: client,
          headers: const {'X-Trace': '1'},
        ),
      );
      final text = await tool.post(
        RunContext.background(),
        const HttpPostRequest(url: 'https://a.test/a', body: 'payload'),
      );
      expect(text, 'done');
      expect([for (final r in seen) r.method], ['POST', 'GET', 'GET']);
      expect([for (final r in seen) r.url.path], ['/a', '/b', '/c']);
      expect(seen[0].body, 'payload');
      expect(seen[1].bodyBytes, isEmpty);
      expect(seen[2].bodyBytes, isEmpty);
      expect(seen[1].headers['X-Trace'], '1');
      expect(seen[1].headers['Referer'], 'https://a.test/a');
    });

    test('307 repeats the method and the body', () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return request.url.path == '/a'
            ? http.Response('', 308, headers: {'location': '/b'})
            : http.Response('done', 200);
      });
      final tool = HttpPutRequestTool(HttpRequestToolConfig(httpClient: client));
      await tool.put(
        RunContext.background(),
        const HttpPutRequest(url: 'https://a.test/a', body: 'payload'),
      );
      expect([for (final r in seen) r.method], ['PUT', 'PUT']);
      expect(seen[1].body, 'payload');
    });

    test('credentials stay on the same domain and its subdomains', () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return switch ('${request.url.host}${request.url.path}') {
          'a.test/1' => http.Response(
              '',
              301,
              headers: {'location': 'https://api.a.test/2'},
            ),
          'api.a.test/2' => http.Response(
              '',
              301,
              headers: {'location': 'http://other.test/3'},
            ),
          _ => http.Response('done', 200),
        };
      });
      final tool = HttpGetRequestTool(
        HttpRequestToolConfig(
          httpClient: client,
          headers: const {'Authorization': 'Bearer t', 'Accept': 'text/plain'},
        ),
      );
      await tool.get(
        RunContext.background(),
        const HttpGetRequest(url: 'https://a.test/1'),
      );
      expect(seen[1].headers['Authorization'], 'Bearer t');
      expect(seen[2].headers.containsKey('authorization'), isFalse);
      expect(seen[2].headers['Accept'], 'text/plain');
      // No Referer from https to http.
      expect(seen[2].headers.containsKey('referer'), isFalse);
    });

    test('a redirect without Location is the response', () async {
      final client = MockClient((_) async => http.Response('moved', 302));
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      expect(
        await tool.get(
          RunContext.background(),
          const HttpGetRequest(url: 'https://a.test/'),
        ),
        'moved',
      );
    });

    test('a token cancelled during a hop sends no further hop', () async {
      final token = CancelToken();
      var requests = 0;
      // The redirect is answered before the cancel reaches the listeners of
      // the token, so only a look at the token stops the next hop.
      final client = _CallbackClient((request) {
        requests++;
        final response = Future.value(
          http.StreamedResponse(
            const Stream<List<int>>.empty(),
            302,
            headers: {'location': '/next'},
          ),
        );
        token.cancel('stop');
        return response;
      });
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      await expectLater(
        tool.get(
          RunContext.background(cancelToken: token),
          const HttpGetRequest(url: 'https://a.test/first'),
        ),
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'stop'),
        ),
      );
      expect(requests, 1);
    });

    test('Go stops at the tenth redirect', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 302, headers: {'location': '/r$requests'});
      });
      final tool = HttpGetRequestTool(HttpRequestToolConfig(httpClient: client));
      await expectLater(
        tool.get(
          RunContext.background(),
          const HttpGetRequest(url: 'https://a.test/start'),
        ),
        throwsA(
          _threepio(
            'failed to execute request: Get "/r10": stopped after 10 '
            'redirects',
          ),
        ),
      );
      expect(requests, 10);
    });
  });

  group('client ownership', () {
    test('an injected client is never closed', () async {
      final client = _TrackingClient(
        MockClient((_) async => http.Response('ok', 200)),
      );
      final kit = HttpRequestToolkit(HttpRequestToolkitConfig(httpClient: client));
      await kit.getTool.get(
        RunContext.background(),
        const HttpGetRequest(url: 'https://a.test/'),
      );
      kit.dispose();
      expect(client.closed, isFalse);
    });

    test('a disposed tool must not be called; dispose is idempotent', () async {
      final tool = HttpGetRequestTool()
        ..dispose()
        ..dispose();
      await expectLater(
        tool.get(
          RunContext.background(),
          const HttpGetRequest(url: 'https://a.test/'),
        ),
        throwsStateError,
      );
    });

    test('the client the tool creates talks to a loopback server', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        if (request.uri.path == '/old') {
          request.response
            ..statusCode = 302
            ..headers.set('location', '/new');
        } else {
          request.response.write(await utf8.decodeStream(request));
        }
        await request.response.close();
      });
      final tool = HttpPostRequestTool();
      addTearDown(tool.dispose);
      final text = await tool.post(
        RunContext.background(),
        HttpPostRequest(
          url: 'http://127.0.0.1:${server.port}/old',
          body: 'echo',
        ),
      );
      // The redirect was followed by the tool (as GET, without the body).
      expect(requests, ['POST /old', 'GET /new']);
      expect(text, '');
    });
  });

  group('request values', () {
    test('fromJson, toJson and equality', () {
      expect(
        HttpPostRequest.fromJson(const {'url': 'u', 'body': 'b'}),
        const HttpPostRequest(url: 'u', body: 'b'),
      );
      expect(HttpPutRequest.fromJson(const {'url': 'u'}).body, '');
      expect(HttpGetRequest.fromJson(const {}).url, '');
      expect(const HttpDeleteRequest(url: 'u').toJson(), {'url': 'u'});
      expect(
        const HttpPutRequest(url: 'u', body: 'b').toJson(),
        {'url': 'u', 'body': 'b'},
      );
      expect(
        () => HttpDeleteRequest.fromJson(const {'url': true}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
