// Port of eino-ext `components/tool/searxng/searxng_test.go`.
//
// Ported (Go's httptest servers become loopback HttpServers with the same
// handlers and bodies; Go's one-second retry sleep becomes a retryDelay of a
// millisecond; Go's 100-200 ms server sleeps become handlers that wait on a
// gate):
// TestSearchRequest_validate, TestSearchRequestConfig_validate,
// TestSearchRequest_build, TestValidateInSlice, TestValidateEngines,
// TestNewClient (minus "nil config"), TestParseSearchResponse,
// TestSearxngClient_Search (minus "nil params"), TestBuildSearchInvokeTool,
// TestSendRequestWithRetry_ContextCancelled,
// TestSearxngClient_Search_NoDefaultUserAgent,
// TestSearxngClient_sendRequestWithRetry_FailedRequest,
// TestSearxngClient_sendRequestWithRetry_BadResponseBody,
// TestSearchRequest_validate_valid, TestValidateInSlice_ErrorFormatting,
// TestValidateEngines_ErrorFormatting, TestSearchRequest_build_no_optionals,
// TestNewClient_DefaultValues, TestSearxngClient_Search_ContextCancelled,
// TestSearxngClient_Search_RequestCreationError,
// TestSearxngClient_sendRequestWithRetry_RateLimitSuccess,
// TestParseSearchResponse_EmptyResults, TestValidateEngines_EmptyString,
// TestSearxngClient_Search_DefaultUserAgent,
// TestSearxngClient_sendRequestWithRetry_ParseError, Test_validateInSlice,
// TestSearchRequest_validate_params, Test_parseSearchResponse,
// TestSearxngClient_Search_WithHeader,
// TestSearxngClient_sendRequestWithRetry_RetrySuccess,
// Test_BuildSearchInvokeTool, TestSearchRequest_validate_pageno,
// TestSearchRequest_validate_time_range, TestSearchRequest_validate_language,
// TestSearchRequest_validate_safesearch, TestSearchRequest_validate_engines,
// TestSearchRequest_build_all_params, TestSearxngClient_Search_EmptyResponse,
// Test_validateInSlice_Comparable, Test_validateEngines_WithValid,
// Test_validateEngines_WithInvalid, Test_parseSearchResponse_WithEmptyResults,
// Test_parseSearchResponse_WithNilResults,
// Test_SearxngClient_Search_WithEmptyBaseUrl,
// Test_SearxngClient_Search_WithInvalidUrl,
// Test_SearxngClient_sendRequestWithRetry_WithInvalidUrl,
// Test_SearxngClient_sendRequestWithRetry_WithTimeout,
// Test_SearxngClient_sendRequestWithRetry_WithRateLimit,
// Test_SearxngClient_sendRequestWithRetry_WithNoResults,
// Test_SearxngClient_sendRequestWithRetry_WithBadJson,
// Test_SearxngClient_sendRequestWithRetry_WithBadBody.
//
// Go tests of `sendRequestWithRetry` run here through `SearxngClient.search`
// (which builds the request to the server's address). Go's invalid enumerated
// values (`TimeRange("invalid")`, `SafeSearchLevel(99)`) cannot be built with
// Dart enums; those cases go through `SearxngSearchRequestConfig.fromJson`,
// which runs Go's validation with Go's messages.
// Rewritten without network: FailedRequest (Go connects to localhost:12345)
// and the two WithInvalidUrl tests (Go resolves `invalid-url`) use a
// MockClient that fails like the connection would.
//
// Not ported: TestNewClient "nil config", TestSearxngClient_Search "nil
// params", TestBuildSearchInvokeTool_Error,
// Test_BuildSearchInvokeTool_WithNilConfig,
// Test_SearxngClient_sendRequestWithRetry_WithNilContext,
// Test_SearxngClient_sendRequestWithRetry_WithNilRequest and
// Test_SearxngClient_Search_WithNilContext (nil config, params, context and
// request cannot be passed in Dart); TestNewClient_Proxy (Go's `ProxyURL` is
// never read and is not ported); Test_strPtr, Test_intPtr and Test_enginePtr
// (they test helpers of the Go test file).
//
// Written for the port: the tool info, the answer to the model byte for
// byte, URL encoding, argument decoding, Go's JSON type errors, the typed
// SearchResult mapping, the retry rules, cancellation during a retry pause,
// timeout and retry defaults, and client ownership.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/duckduckgo/go_wire.dart';
import 'package:threepio_core/src/components/tool/search_result.dart';
import 'package:threepio_core/src/components/tool/searxng/searxng_client.dart';
import 'package:threepio_core/src/components/tool/searxng/searxng_types.dart';
import 'package:threepio_core/src/components/tool/searxng/searxng_validation.dart';
import 'package:threepio_core/threepio_core.dart';

const _validBody =
    '{"query": "test", "number_of_results": 1, "results": [{"title": "title", '
    '"content": "content", "url": "url", "engine": "engine"}]}';

/// A loopback HTTP server whose requests are answered by [handler]; closed
/// when the test ends.
Future<({String url, List<HttpRequest> requests})> _server(
  FutureOr<void> Function(HttpRequest request, int index) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final requests = <HttpRequest>[];
  server.listen((request) async {
    requests.add(request);
    await handler(request, requests.length - 1);
  });
  return (url: 'http://127.0.0.1:${server.port}', requests: requests);
}

/// Go's `fmt.Fprintln(w, body)`: status 200 and the body with a newline.
Future<void> _println(HttpRequest request, String body) async {
  request.response.write('$body\n');
  await request.response.close();
}

/// Go's `w.WriteHeader(status)` without a body.
Future<void> _status(HttpRequest request, int status) async {
  request.response.statusCode = status;
  await request.response.close();
}

/// Go's handler that sets `Content-Length: 1` and sends no body.
Future<void> _promiseOneByteSendNone(HttpRequest request) async {
  final socket = await request.response.detachSocket(writeHeaders: false);
  socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n');
  await socket.flush();
  socket.destroy();
}

/// A MockClient answering [body] with 200, recording the requests.
({MockClient client, List<http.Request> requests}) _mock([
  String body = _validBody,
  int status = 200,
]) {
  final requests = <http.Request>[];
  return (
    client: MockClient((request) async {
      requests.add(request);
      return http.Response.bytes(utf8.encode(body), status);
    }),
    requests: requests,
  );
}

/// A client that records whether it was closed.
final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => closed = true;
}

const _fast = Duration(milliseconds: 1);

SearxngClient _client(
  String baseUrl, {
  int? maxRetries,
  Duration? timeout,
  Map<String, String>? headers,
  http.Client? httpClient,
  SearxngSearchRequestConfig? requestConfig,
}) =>
    SearxngClient(
      SearxngClientConfig(
        baseUrl: baseUrl,
        maxRetries: maxRetries,
        timeout: timeout,
        headers: headers,
        httpClient: httpClient,
        requestConfig: requestConfig,
        retryDelay: _fast,
      ),
    );

Future<Object> _failureOf(Future<Object?> future) async {
  try {
    await future;
  } on Object catch (error) {
    return error;
  }
  fail('the call succeeded');
}

Matcher _threepio(Object message) =>
    isA<ThreepioException>().having((e) => e.message, 'message', message);

Matcher _argumentError(String message) =>
    isA<ArgumentError>().having((e) => e.message, 'message', message);

void main() {
  group('TestSearchRequest_validate', () {
    Future<void> check(SearxngSearchRequest request, Object? wantError) async {
      final mock = _mock();
      final client = _client('http://localhost', httpClient: mock.client);
      if (wantError == null) {
        await client.search(RunContext.background(), request);
        expect(mock.requests, hasLength(1));
      } else {
        final error =
            await _failureOf(client.search(RunContext.background(), request));
        expect(
          error,
          isA<ThreepioFormatException>()
              .having((e) => e.message, 'message', wantError),
        );
        expect(mock.requests, isEmpty);
      }
    }

    test('valid request', () async {
      await check(const SearxngSearchRequest(query: 'test', pageNo: 1), null);
    });
    test('missing query', () async {
      await check(
        const SearxngSearchRequest(query: '', pageNo: 1),
        'query is required',
      );
    });
    test('invalid pageno', () async {
      await check(
        const SearxngSearchRequest(query: 'test', pageNo: 0),
        'pageno must be greater than 0',
      );
    });
  });

  group('TestSearchRequestConfig_validate', () {
    test('valid config', () {
      final config = SearxngSearchRequestConfig.fromJson(const {
        'time_range': 'day',
        'language': 'en',
        'safesearch': 0,
        'engines': ['google', 'bing'],
      });
      expect(
        config,
        const SearxngSearchRequestConfig(
          timeRange: SearxngTimeRange.day,
          language: SearxngLanguage.en,
          engines: [SearxngEngine.google, SearxngEngine.bing],
        ),
      );
    });
    test('invalid time_range', () {
      expect(
        () => SearxngSearchRequestConfig.fromJson(const {'time_range': 'invalid'}),
        throwsA(_argumentError('time_range must be one of: [day month year]')),
      );
    });
    test('invalid language', () {
      expect(
        () => SearxngSearchRequestConfig.fromJson(const {'language': 'invalid'}),
        throwsA(
          _argumentError(
            'language must be one of: [all en zh zh-CN zh-TW fr de es ja ko '
            'ru ar pt it nl pl tr]',
          ),
        ),
      );
    });
    test('invalid safesearch', () {
      expect(
        () => SearxngSearchRequestConfig.fromJson(const {'safesearch': 99}),
        throwsA(_argumentError('safesearch must be one of: [0 1 2]')),
      );
    });
    test('invalid engines', () {
      expect(
        () => SearxngSearchRequestConfig.fromJson(const {
          'engines': ['invalid'],
        }),
        throwsA(
          _argumentError(
            "engine 'invalid' is not supported. Valid engines are: [google "
            'duckduckgo baidu bing 360search yahoo quark]',
          ),
        ),
      );
    });
    test('valid engines', () {
      expect(
        SearxngSearchRequestConfig.fromJson(const {
          'engines': ['google', 'bing'],
        }).engines,
        [SearxngEngine.google, SearxngEngine.bing],
      );
    });
  });

  group('TestSearchRequest_build', () {
    test('basic request', () async {
      expect(
        SearxngClient.buildQuery(
          const SearxngSearchRequest(query: 'test', pageNo: 1),
          null,
        ),
        {
          'q': ['test'],
          'pageno': ['1'],
          'format': ['json'],
        },
      );
      // On the wire, as Go's url.Values.Encode writes it.
      final mock = _mock();
      await _client('http://localhost/search', httpClient: mock.client).search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test', pageNo: 1),
      );
      expect(
        mock.requests.single.url.toString(),
        'http://localhost/search?format=json&pageno=1&q=test',
      );
    });

    test('full request', () async {
      const config = SearxngSearchRequestConfig(
        timeRange: SearxngTimeRange.day,
        language: SearxngLanguage.en,
        safeSearch: SearxngSafeSearch.moderate,
        engines: [SearxngEngine.google, SearxngEngine.bing],
      );
      expect(
        SearxngClient.buildQuery(
          const SearxngSearchRequest(query: 'test', pageNo: 2),
          config,
        ),
        {
          'q': ['test'],
          'pageno': ['2'],
          'format': ['json'],
          'time_range': ['day'],
          'language': ['en'],
          'safesearch': ['1'],
          'engines': ['google,bing'],
        },
      );
      final mock = _mock();
      await _client(
        'http://localhost/search',
        httpClient: mock.client,
        requestConfig: config,
      ).search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test', pageNo: 2),
      );
      expect(
        mock.requests.single.url.query,
        'engines=google%2Cbing&format=json&language=en&pageno=2&q=test&'
        'safesearch=1&time_range=day',
      );
    });
  });

  group('TestValidateInSlice', () {
    final cases = <(String, Object, List<Object>, bool)>[
      ('valid string', 'a', ['a', 'b', 'c'], false),
      ('invalid string', 'd', ['a', 'b', 'c'], true),
      ('valid int', 1, [1, 2, 3], false),
      ('invalid int', 4, [1, 2, 3], true),
    ];
    for (final (name, value, valid, wantError) in cases) {
      test(name, () {
        void call() => searxngValidateInSlice(value, valid, 'param');
        if (wantError) {
          expect(call, throwsArgumentError);
        } else {
          call();
        }
      });
    }
  });

  group('TestValidateEngines', () {
    final cases = <(String, List<String>, bool)>[
      ('valid single', ['google'], false),
      ('valid multiple', ['google', 'bing'], false),
      ('invalid single', ['invalid'], true),
      ('invalid in multiple', ['google', 'invalid'], true),
      ('empty', [], false),
    ];
    for (final (name, engines, wantError) in cases) {
      test(name, () {
        void call() => searxngValidateEngines(engines);
        if (wantError) {
          expect(call, throwsArgumentError);
        } else {
          call();
        }
      });
    }
  });

  group('TestNewClient', () {
    test('valid config', () {
      final client = SearxngClient(
        const SearxngClientConfig(baseUrl: 'http://localhost'),
      );
      expect(client.config.baseUrl, 'http://localhost');
      expect(client.timeout, const Duration(seconds: 30));
      expect(client.maxRetries, 3);
      expect(client.headers, isEmpty);
      expect(client.config.requestConfig, isNull);
    });

    test('valid config with custom values', () {
      final client = SearxngClient(
        const SearxngClientConfig(
          baseUrl: 'http://localhost',
          timeout: Duration(seconds: 10),
          maxRetries: 5,
          headers: {'User-Agent': 'test'},
        ),
      );
      expect(client.timeout, const Duration(seconds: 10));
      expect(client.maxRetries, 5);
      expect(client.headers, {'User-Agent': 'test'});
    });

    test('valid config with request config', () {
      final client = SearxngClient(
        const SearxngClientConfig(
          baseUrl: 'http://localhost',
          requestConfig:
              SearxngSearchRequestConfig(language: SearxngLanguage.en),
        ),
      );
      expect(
        client.config.requestConfig,
        const SearxngSearchRequestConfig(language: SearxngLanguage.en),
      );
      expect(client.timeout, const Duration(seconds: 30));
      expect(client.maxRetries, 3);
    });

    test('valid config with custom http client', () async {
      final mock = _mock();
      final client = _client('http://localhost', httpClient: mock.client);
      await client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      );
      expect(mock.requests, hasLength(1));
      expect(client.timeout, const Duration(seconds: 30));
    });
  });

  group('TestParseSearchResponse', () {
    test('valid response', () {
      expect(
        SearxngClient.parseSearchResponse(
          '{"query": "test", "number_of_results": 1, "results": [{"title": '
          '"title", "content": "content", "url": "url", "engine": "engine"}]}',
        ),
        const SearxngSearchResponse(
          query: 'test',
          numberOfResults: 1,
          results: [
            SearxngSearchResult(
              title: 'title',
              content: 'content',
              url: 'url',
              engine: 'engine',
            ),
          ],
        ),
      );
    });
    test('invalid json', () {
      expect(
        () => SearxngClient.parseSearchResponse('invalid json'),
        throwsFormatException,
      );
    });
    test('missing number_of_results', () {
      expect(
        SearxngClient.parseSearchResponse(
          '{"query": "test", "results": [{"title": "title", "content": '
          '"content", "url": "url", "engine": "engine"}]}',
        ),
        const SearxngSearchResponse(
          query: 'test',
          numberOfResults: 1,
          results: [
            SearxngSearchResult(
              title: 'title',
              content: 'content',
              url: 'url',
              engine: 'engine',
            ),
          ],
        ),
      );
    });
  });

  group('TestSearxngClient_Search', () {
    late SearxngClient client;

    setUp(() async {
      final server = await _server((request, _) async {
        switch (request.uri.queryParameters['q']) {
          case 'ratelimit':
            await _status(request, HttpStatus.tooManyRequests);
          case 'noresults':
            await _println(request, '{"results": []}');
          case 'servererror':
            await _status(request, HttpStatus.internalServerError);
          default:
            await _println(request, _validBody);
        }
      });
      client = _client(server.url, maxRetries: 1);
      addTearDown(client.dispose);
    });

    final cases = <(String, SearxngSearchRequest, String?)>[
      ('validation error', const SearxngSearchRequest(query: ''), 'query is required'),
      (
        'successful search',
        const SearxngSearchRequest(query: 'test', pageNo: 1),
        null,
      ),
      (
        'rate limit',
        const SearxngSearchRequest(query: 'ratelimit', pageNo: 1),
        'rate limit reached',
      ),
      (
        'no results',
        const SearxngSearchRequest(query: 'noresults', pageNo: 1),
        'no search results found',
      ),
      (
        'server error',
        const SearxngSearchRequest(query: 'servererror', pageNo: 1),
        'failed to parse search results',
      ),
    ];
    for (final (name, request, errorText) in cases) {
      test(name, () async {
        if (errorText == null) {
          final response = await client.search(RunContext.background(), request);
          expect(response.results, hasLength(1));
        } else {
          final error =
              await _failureOf(client.search(RunContext.background(), request));
          expect(error, _threepio(contains(errorText)));
        }
      });
    }
  });

  group('TestBuildSearchInvokeTool', () {
    test('builds, and an invalid request config fails first', () {
      expect(
        SearxngSearchTool(const SearxngClientConfig(baseUrl: 'http://localhost')),
        isA<SearxngSearchTool>(),
      );
      // Go: BuildSearchInvokeTool with RequestConfig{TimeRange: "invalid"}.
      expect(
        () => SearxngSearchTool(
          SearxngClientConfig(
            baseUrl: 'http://localhost',
            requestConfig: SearxngSearchRequestConfig.fromJson(const {
              'time_range': 'invalid',
            }),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  test('Test_BuildSearchInvokeTool', () {
    expect(
      SearxngSearchTool(const SearxngClientConfig(baseUrl: 'http://localhost'))
          .name,
      'web_search',
    );
  });

  test('TestSendRequestWithRetry_ContextCancelled', () async {
    final server = await _server((request, _) => _println(request, '{}'));
    final client = _client(server.url, maxRetries: 1);
    addTearDown(client.dispose);
    final token = CancelToken()..cancel();
    final error = await _failureOf(
      client.search(
        RunContext.background(cancelToken: token),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, isA<CancelledException>());
    expect(server.requests, isEmpty);
  });

  test('TestSearxngClient_Search_NoDefaultUserAgent', () async {
    String? userAgent;
    final server = await _server((request, _) {
      userAgent = request.headers.value('User-Agent');
      return _println(request, _validBody);
    });
    final client = _client(server.url, headers: {'User-Agent': 'custom-agent'});
    addTearDown(client.dispose);
    await client.search(
      RunContext.background(),
      const SearxngSearchRequest(query: 'test', pageNo: 1),
    );
    expect(userAgent, 'custom-agent');
  });

  test('TestSearxngClient_sendRequestWithRetry_FailedRequest', () async {
    var attempts = 0;
    final client = _client(
      'http://localhost:12345',
      maxRetries: 1,
      httpClient: MockClient((_) async {
        attempts++;
        throw http.ClientException(
          'Connection refused',
          Uri.parse('http://localhost:12345'),
        );
      }),
    );
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, _threepio(contains('failed to send request after retries')));
    expect((error as ThreepioException).cause, isA<http.ClientException>());
    expect(attempts, 2);
  });

  test('TestSearxngClient_sendRequestWithRetry_BadResponseBody', () async {
    final server = await _server((request, _) => _promiseOneByteSendNone(request));
    final client = _client(server.url);
    addTearDown(client.dispose);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, _threepio(contains('failed to read response body')));
  });

  test('TestSearchRequest_validate_valid', () async {
    final config = SearxngSearchRequestConfig.fromJson(const {
      'time_range': 'day',
      'language': 'en',
      'safesearch': 1,
      'engines': ['google'],
    });
    final query = SearxngClient.buildQuery(
      const SearxngSearchRequest(query: 'test', pageNo: 1),
      config,
    );
    expect(query['q'], ['test']);
    expect(query['time_range'], ['day']);
    expect(query['language'], ['en']);
    expect(query['safesearch'], ['1']);
    expect(query['engines'], ['google']);
  });

  test('TestValidateInSlice_ErrorFormatting', () {
    expect(
      () => searxngValidateInSlice('d', ['a', 'b', 'c'], 'test_param'),
      throwsA(_argumentError('test_param must be one of: [a b c]')),
    );
  });

  test('TestValidateEngines_ErrorFormatting', () {
    expect(
      () => searxngValidateEngines(['google', 'invalid_engine']),
      throwsA(
        _argumentError(
          "engine 'invalid_engine' is not supported. Valid engines are: "
          '[google duckduckgo baidu bing 360search yahoo quark]',
        ),
      ),
    );
  });

  test('TestSearchRequest_build_no_optionals', () {
    final query = SearxngClient.buildQuery(
      const SearxngSearchRequest(query: 'test', pageNo: 1),
      null,
    );
    for (final key in ['time_range', 'language', 'safesearch', 'engines']) {
      expect(query.containsKey(key), isFalse, reason: key);
    }
  });

  test('TestNewClient_DefaultValues', () {
    final client =
        SearxngClient(const SearxngClientConfig(baseUrl: 'http://test.com'));
    expect(client.timeout, const Duration(seconds: 30));
    expect(client.maxRetries, 3);
    expect(client.headers, isNotNull);
  });

  test('TestSearxngClient_Search_ContextCancelled', () async {
    final arrived = Completer<void>();
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final server = await _server((request, _) async {
      arrived.complete();
      await gate.future;
      await _println(request, '{}');
    });
    final client = _client(server.url);
    addTearDown(client.dispose);
    final token = CancelToken();
    final search = client.search(
      RunContext.background(cancelToken: token),
      const SearxngSearchRequest(query: 'test', pageNo: 1),
    );
    await arrived.future;
    token.cancel();
    expect(await _failureOf(search), isA<CancelledException>());
  });

  test('TestSearxngClient_Search_RequestCreationError', () async {
    final mock = _mock();
    final client = _client('http://[::1]:namedport', httpClient: mock.client);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test', pageNo: 1),
      ),
    );
    expect(error, _threepio(startsWith('failed to create request: ')));
    expect(mock.requests, isEmpty);
  });

  test('TestSearxngClient_sendRequestWithRetry_RateLimitSuccess', () async {
    final server = await _server((request, index) async {
      if (index == 0) {
        await _status(request, HttpStatus.tooManyRequests);
      } else {
        await _println(request, '{"results": [{"title":"t"}]}');
      }
    });
    final client = _client(
      server.url,
      maxRetries: 1,
      timeout: const Duration(seconds: 5),
    );
    addTearDown(client.dispose);
    final response = await client.search(
      RunContext.background(),
      const SearxngSearchRequest(query: 'test'),
    );
    expect(response.results, hasLength(1));
  });

  test('TestParseSearchResponse_EmptyResults', () {
    expect(
      SearxngClient.parseSearchResponse('{"query": "test", "results": []}')
          .numberOfResults,
      0,
    );
  });

  test('TestValidateEngines_EmptyString', () {
    searxngValidateEngines([]);
  });

  test('TestSearxngClient_Search_DefaultUserAgent', () async {
    String? userAgent;
    final server = await _server((request, _) {
      userAgent = request.headers.value('User-Agent');
      return _println(request, '{"results": [{"title":"t"}]}');
    });
    final client = _client(server.url);
    addTearDown(client.dispose);
    await client.search(
      RunContext.background(),
      const SearxngSearchRequest(query: 'test', pageNo: 1),
    );
    expect(
      userAgent,
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
    );
  });

  test('TestSearxngClient_sendRequestWithRetry_ParseError', () async {
    final server =
        await _server((request, _) => _println(request, 'this is not json'));
    final client = _client(server.url);
    addTearDown(client.dispose);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, _threepio(contains('failed to parse search results')));
  });

  group('Test_validateInSlice', () {
    test('valid string', () => searxngValidateInSlice('a', ['a', 'b', 'c'], 'test'));
    test('invalid string', () {
      expect(
        () => searxngValidateInSlice('d', ['a', 'b', 'c'], 'test'),
        throwsArgumentError,
      );
    });
    test('valid int', () => searxngValidateInSlice(1, [1, 2, 3], 'test'));
    test('invalid int', () {
      expect(
        () => searxngValidateInSlice(4, [1, 2, 3], 'test'),
        throwsArgumentError,
      );
    });
  });

  group('TestSearchRequest_validate_params', () {
    test('empty', () => searxngValidateEngines([]));
    test('valid', () => searxngValidateEngines(['google', 'bing']));
    test('invalid', () {
      expect(() => searxngValidateEngines(['google', 'foo']), throwsArgumentError);
    });
  });

  test('Test_parseSearchResponse no number of results', () {
    expect(
      SearxngClient.parseSearchResponse(
        '{"results": [{"title": "t1"}, {"title": "t2"}]}',
      ).numberOfResults,
      2,
    );
  });

  test('TestSearxngClient_Search_WithHeader', () async {
    String? headerValue;
    final server = await _server((request, _) {
      headerValue = request.headers.value('X-Test');
      return _println(request, '{"results": [{"title":"t"}]}');
    });
    final client = _client(server.url, headers: {'X-Test': 'test-value'});
    addTearDown(client.dispose);
    await client.search(
      RunContext.background(),
      const SearxngSearchRequest(query: 'test', pageNo: 1),
    );
    expect(headerValue, 'test-value');
  });

  test('TestSearxngClient_sendRequestWithRetry_RetrySuccess', () async {
    var retryCount = 0;
    final server = await _server((request, _) async {
      if (retryCount < 1) {
        retryCount++;
        await _status(request, HttpStatus.internalServerError);
        return;
      }
      request.response.write('{"results":[{"title":"t"}]}');
      await request.response.close();
    });
    final client = _client(
      server.url,
      maxRetries: 2,
      timeout: const Duration(seconds: 5),
    );
    addTearDown(client.dispose);
    await client.search(
      RunContext.background(),
      const SearxngSearchRequest(query: 'test'),
    );
    expect(retryCount, 1);
    expect(server.requests, hasLength(2));
  });

  test('TestSearchRequest_validate_pageno', () async {
    final error = await _failureOf(
      _client('http://localhost', httpClient: _mock().client).search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test', pageNo: 0),
      ),
    );
    expect(error, isA<ThreepioFormatException>());
  });

  test('TestSearchRequest_validate_time_range', () {
    expect(
      () => SearxngSearchRequestConfig.fromJson(const {'time_range': 'invalid'}),
      throwsArgumentError,
    );
  });

  test('TestSearchRequest_validate_language', () {
    expect(
      () => SearxngSearchRequestConfig.fromJson(const {'language': 'invalid'}),
      throwsArgumentError,
    );
  });

  test('TestSearchRequest_validate_safesearch', () {
    expect(
      () => SearxngSearchRequestConfig.fromJson(const {'safesearch': 10}),
      throwsArgumentError,
    );
  });

  test('TestSearchRequest_validate_engines', () {
    expect(
      () => SearxngSearchRequestConfig.fromJson(const {
        'engines': ['invalid'],
      }),
      throwsArgumentError,
    );
  });

  test('TestSearchRequest_build_all_params', () {
    final query = SearxngClient.buildQuery(
      const SearxngSearchRequest(query: 'test', pageNo: 2),
      const SearxngSearchRequestConfig(
        timeRange: SearxngTimeRange.year,
        language: SearxngLanguage.zhCN,
        safeSearch: SearxngSafeSearch.strict,
        engines: [SearxngEngine.google, SearxngEngine.bing],
      ),
    );
    expect(query, {
      'q': ['test'],
      'pageno': ['2'],
      'format': ['json'],
      'time_range': ['year'],
      'language': ['zh-CN'],
      'safesearch': ['2'],
      'engines': ['google,bing'],
    });
  });

  test('TestSearxngClient_Search_EmptyResponse', () async {
    final server = await _server((request, _) => _println(request, '{}'));
    final client = _client(server.url);
    addTearDown(client.dispose);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test', pageNo: 1),
      ),
    );
    expect(error, _threepio('no search results found'));
  });

  test('Test_validateInSlice_Comparable', () {
    searxngValidateInSlice(1.0, [1.0, 2.0], 'float');
  });

  test('Test_validateEngines_WithValid', () {
    searxngValidateInSlice('google', ['google', 'bing'], 'engine');
  });

  test('Test_validateEngines_WithInvalid', () {
    expect(
      () => searxngValidateInSlice('yahoo', ['google', 'bing'], 'engine'),
      throwsA(_argumentError('engine must be one of: [google bing]')),
    );
  });

  test('Test_parseSearchResponse_WithEmptyResults', () {
    expect(
      SearxngClient.parseSearchResponse('{"results": []}').numberOfResults,
      0,
    );
  });

  test('Test_parseSearchResponse_WithNilResults', () {
    expect(SearxngClient.parseSearchResponse('{}').numberOfResults, 0);
  });

  test('Test_SearxngClient_Search_WithEmptyBaseUrl', () async {
    final mock = _mock();
    final client = _client('', httpClient: mock.client);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test', pageNo: 1),
      ),
    );
    // Go: `Get "?format=json&pageno=1&q=test": unsupported protocol scheme ""`,
    // after the retries.
    expect(error, _threepio(startsWith('failed to send request after retries: ')));
    expect(error, _threepio(contains('unsupported protocol scheme ""')));
    expect(mock.requests, isEmpty);
  });

  group('invalid URL', () {
    // Go resolves the host `invalid-url`; here the client fails as a failed
    // lookup does.
    MockClient lookupFails(List<int> attempts) => MockClient((request) async {
          attempts.add(1);
          throw http.ClientException(
            "Failed host lookup: 'invalid-url'",
            request.url,
          );
        });

    test('Test_SearxngClient_Search_WithInvalidUrl', () async {
      final attempts = <int>[];
      final error = await _failureOf(
        _client('http://invalid-url', httpClient: lookupFails(attempts)).search(
          RunContext.background(),
          const SearxngSearchRequest(query: 'test', pageNo: 1),
        ),
      );
      expect(error, _threepio(startsWith('failed to send request after retries')));
      expect(attempts, hasLength(4), reason: 'MaxRetries defaults to 3');
    });

    test('Test_SearxngClient_sendRequestWithRetry_WithInvalidUrl', () async {
      final error = await _failureOf(
        _client('http://invalid-url', httpClient: lookupFails([])).search(
          RunContext.background(),
          const SearxngSearchRequest(query: 'test'),
        ),
      );
      expect(error, isA<ThreepioException>());
    });
  });

  test('Test_SearxngClient_sendRequestWithRetry_WithTimeout', () async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    // The client abandons a request without aborting it, so the fourth one
    // may reach the server only after the search has failed: wait for it.
    final fourth = Completer<void>();
    final server = await _server((request, index) async {
      if (index == 3) fourth.complete();
      await gate.future;
      await request.response.close();
    });
    final client = _client(server.url, timeout: const Duration(milliseconds: 5));
    addTearDown(client.dispose);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, _threepio(startsWith('failed to send request after retries')));
    expect((error as ThreepioException).cause, isA<TimeoutException>());
    await fourth.future;
    expect(server.requests, hasLength(4));
  });

  test('Test_SearxngClient_sendRequestWithRetry_WithRateLimit', () async {
    final server = await _server(
      (request, _) => _status(request, HttpStatus.tooManyRequests),
    );
    // MaxRetries 0 means the default, 3.
    final client = _client(server.url, maxRetries: 0);
    addTearDown(client.dispose);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, _threepio('rate limit reached'));
    expect(server.requests, hasLength(4));
  });

  test('Test_SearxngClient_sendRequestWithRetry_WithNoResults', () async {
    final server = await _server((request, _) async {
      request.response.write('{"results":[]}');
      await request.response.close();
    });
    final client = _client(server.url);
    addTearDown(client.dispose);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, _threepio('no search results found'));
  });

  test('Test_SearxngClient_sendRequestWithRetry_WithBadJson', () async {
    final server = await _server((request, _) async {
      request.response.write('{"results":');
      await request.response.close();
    });
    final client = _client(server.url);
    addTearDown(client.dispose);
    final error = await _failureOf(
      client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      ),
    );
    expect(error, _threepio(startsWith('failed to parse search results: ')));
    expect((error as ThreepioException).cause, isA<FormatException>());
  });

  test('Test_SearxngClient_sendRequestWithRetry_WithBadBody', () async {
    final server = await _server((request, _) => _promiseOneByteSendNone(request));
    final client = _client(server.url);
    addTearDown(client.dispose);
    expect(
      await _failureOf(
        client.search(
          RunContext.background(),
          const SearxngSearchRequest(query: 'test'),
        ),
      ),
      isA<ThreepioException>(),
    );
  });

  // ---------------------------------------------------------------------
  // Written for the port.
  // ---------------------------------------------------------------------

  group('SearxngSearchTool', () {
    test('tool info', () async {
      final tool = SearxngSearchTool(
        const SearxngClientConfig(baseUrl: 'http://localhost'),
      );
      final info = await tool.info();
      expect(info.name, 'web_search');
      expect(
        info.desc,
        'Performs a web search using the SearXNG API, ideal for general '
        'queries, news, articles, and online content.\n\t\tUse this for '
        'broad information gathering, recent events, or when you need '
        'diverse web sources.',
      );
      expect(tool.componentTypeName, 'WebSearch');
      final parameters = info.function.parameters!;
      expect(parameters.type, 'object');
      expect(parameters.required, ['query', 'pageno']);
      expect(parameters.additionalProperties, isFalse);
      expect(parameters.properties.keys, ['query', 'pageno']);
      expect(parameters.properties['query']!.type, 'string');
      expect(
        parameters.properties['query']!.description,
        'The search query. This is the main input for the web search',
      );
      expect(parameters.properties['pageno']!.type, 'integer');
      expect(
        parameters.properties['pageno']!.description,
        'The page number of the search results. Default is 1',
      );
    });

    test("answers with Go's JSON byte for byte", () async {
      final mock = _mock();
      final tool = SearxngSearchTool(
        SearxngClientConfig(baseUrl: 'http://localhost', httpClient: mock.client),
      );
      expect(
        await tool.run('{"query":"test","pageno":1}'),
        '{"query":"test","number_of_results":1,"results":[{"title":"title",'
        '"content":"content","url":"url","engine":"engine"}]}',
      );
    });

    test('keeps four fields of a SearXNG answer and counts the results',
        () async {
      // The shape of a real SearXNG /search?format=json answer.
      const body = '{"query": "eino <b>", "number_of_results": 0, "results": '
          '[{"url": "https://github.com/cloudwego/eino", "title": "cloudwego/'
          'eino", "content": "The ultimate LLM & AI framework", "publishedDate"'
          ': null, "thumbnail": "", "engine": "google", "template": '
          '"default.html", "parsed_url": ["https", "github.com", '
          '"/cloudwego/eino", "", "", ""], "img_src": "", "priority": "", '
          '"engines": ["google", "bing"], "positions": [1, 2], "score": 4.0, '
          '"category": "general"}, {"url": "https://www.cloudwego.io/docs/'
          'eino/", "title": "Eino: User Manual", "content": "Eino aims to '
          'provide \\"one\\" framework", "engine": "bing", "engines": '
          '["bing"], "positions": [2], "score": 0.5, "category": "general"}], '
          '"answers": [], "corrections": [], "infoboxes": [], "suggestions": '
          '["eino framework"], "unresponsive_engines": [["brave", '
          '"timeout"]]}';
      final tool = SearxngSearchTool(
        SearxngClientConfig(
          baseUrl: 'http://localhost',
          httpClient: _mock(body).client,
        ),
      );
      expect(
        await tool.run('{"query":"eino"}'),
        '{"query":"eino <b>","number_of_results":2,"results":[{"title":'
        '"cloudwego/eino","content":"The ultimate LLM & AI framework","url":'
        '"https://github.com/cloudwego/eino","engine":"google"},{"title":'
        '"Eino: User Manual","content":"Eino aims to provide \\"one\\" '
        'framework","url":"https://www.cloudwego.io/docs/eino/","engine":'
        '"bing"}]}',
      );
    });

    test('backspace and form feed are escaped as sonic writes them', () async {
      final backslash = String.fromCharCode(0x5c);
      // In the JSON body: a backspace, a form feed, a tab, U+0001 and a
      // backslash followed by "b", all escaped.
      final body = '{"results": [{"title": "t", "content": '
          '"x${backslash}b${backslash}f${backslash}t${backslash}u0001'
          '$backslash${backslash}by", "url": "u", "engine": "e"}]}';
      final tool = SearxngSearchTool(
        SearxngClientConfig(
          baseUrl: 'http://localhost',
          httpClient: _mock(body).client,
        ),
      );
      expect(
        await tool.run('{"query":"q"}'),
        '{"query":"","number_of_results":1,"results":[{"title":"t",'
        '"content":"x${backslash}u0008${backslash}u000c${backslash}t'
        '${backslash}u0001$backslash${backslash}by","url":"u","engine":"e"}]}',
      );
    });

    test('arguments: escaping, case-insensitive keys, null pageno', () async {
      final mock = _mock();
      final tool = SearxngSearchTool(
        SearxngClientConfig(baseUrl: 'http://localhost/s', httpClient: mock.client),
      );
      await tool.run('{"query":"eino & go/ü!","pageno":3}');
      await tool.run('{"QUERY":"a","PageNo":2}');
      await tool.run('{"query":"b","pageno":null}');
      expect(
        [for (final r in mock.requests) r.url.query],
        [
          'format=json&pageno=3&q=eino+%26+go%2F%C3%BC%21',
          'format=json&pageno=2&q=a',
          'format=json&q=b',
        ],
      );
      expect(mock.requests.first.method, 'GET');
    });

    test('arguments of the wrong type fail with Go-style text', () async {
      final tool = SearxngSearchTool(
        SearxngClientConfig(
          baseUrl: 'http://localhost',
          httpClient: _mock().client,
        ),
      );
      for (final (arguments, text) in [
        (
          '{"query":"q","pageno":"2"}',
          'json: cannot unmarshal string into Go struct field '
              'SearchRequest.pageno of type int',
        ),
        (
          '{"query":"q","pageno":2.5}',
          'json: cannot unmarshal number 2.5 into Go struct field '
              'SearchRequest.pageno of type int',
        ),
        (
          '{"query":true}',
          'json: cannot unmarshal bool into Go struct field '
              'SearchRequest.query of type string',
        ),
      ]) {
        await expectLater(
          tool.run(arguments),
          throwsA(
            isA<ThreepioFormatException>()
                .having((e) => e.message, 'message', contains(text)),
          ),
          reason: arguments,
        );
      }
    });

    test('an empty answer fails the tool, the typed search returns []',
        () async {
      final tool = SearxngSearchTool(
        SearxngClientConfig(
          baseUrl: 'http://localhost',
          httpClient: _mock('{"results": []}').client,
        ),
      );
      expect(
        await _failureOf(tool.run('{"query":"none"}')),
        _threepio('no search results found'),
      );
      expect(
        await tool.searchResults(
          RunContext.background(),
          const SearxngSearchRequest(query: 'none'),
        ),
        isEmpty,
      );
      expect(
        await _failureOf(
          tool.search(
            RunContext.background(),
            const SearxngSearchRequest(query: 'none'),
          ),
        ),
        _threepio('no search results found'),
      );
    });

    test("search returns Go's answer, searchResults the SearchResults",
        () async {
      final mock = _mock(
        '{"results": [{"title": "T", "content": "C", "url": "U", '
        '"engine": "bing"}, {"title": "T2", "url": "U2"}]}',
      );
      final tool = SearxngSearchTool(
        SearxngClientConfig(baseUrl: 'http://localhost', httpClient: mock.client),
      );
      expect(
        await tool.searchResults(
          RunContext.background(),
          const SearxngSearchRequest(query: 'q', pageNo: 4),
        ),
        const [
          SearchResult(
            title: 'T',
            url: 'U',
            snippet: 'C',
            extra: {'engine': 'bing'},
          ),
          SearchResult(title: 'T2', url: 'U2', extra: {'engine': ''}),
        ],
      );
      expect(mock.requests.single.url.query, 'format=json&pageno=4&q=q');
      final response = await tool.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'q'),
      );
      expect(response.numberOfResults, 2);
      expect(response.results.first.engine, 'bing');
      await expectLater(
        tool.searchResults(
          RunContext.background(),
          const SearxngSearchRequest(query: ''),
        ),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });

  group('response decoding', () {
    Future<Object> parseFailure(String body) => _failureOf(
          _client('http://localhost', httpClient: _mock(body).client).search(
            RunContext.background(),
            const SearxngSearchRequest(query: 'q'),
          ),
        );

    test("Go's type errors", () async {
      for (final (body, text) in [
        (
          '{"number_of_results": "x", "results": [{}]}',
          'json: cannot unmarshal string into Go struct field '
              'SearchResponse.number_of_results of type int',
        ),
        (
          '{"number_of_results": 1.5}',
          'json: cannot unmarshal number 1.5 into Go struct field '
              'SearchResponse.number_of_results of type int',
        ),
        (
          '{"results": [{"title": 1}]}',
          'json: cannot unmarshal number into Go struct field '
              'SearchResult.results.title of type string',
        ),
        (
          '{"results": {}}',
          'json: cannot unmarshal object into Go struct field '
              'SearchResponse.results of type []*searxng.SearchResult',
        ),
        (
          '{"results": ["x"]}',
          'json: cannot unmarshal string into Go struct field '
              'SearchResponse.results of type searxng.SearchResult',
        ),
        (
          '[]',
          'json: cannot unmarshal array into Go value of type '
              'searxng.SearchResponse',
        ),
      ]) {
        expect(
          await parseFailure(body),
          _threepio('failed to parse search results: $text'),
          reason: body,
        );
      }
    });

    test('null, case-insensitive keys, null hits', () async {
      expect(await parseFailure('null'), _threepio('no search results found'));
      expect(
        SearxngClient.parseSearchResponse(
          '{"QUERY": "q", "Results": [null, {"TITLE": "t"}]}',
        ),
        const SearxngSearchResponse(
          query: 'q',
          numberOfResults: 2,
          results: [SearxngSearchResult(), SearxngSearchResult(title: 't')],
        ),
      );
    });

    test('fromJson does not count, toJson writes the four fields', () {
      final response = SearxngSearchResponse.fromJson(const {
        'results': [
          {'title': 't', 'extra': 'ignored'},
        ],
      });
      expect(response.numberOfResults, 0);
      expect(
        jsonEncode(response),
        '{"query":"","number_of_results":0,"results":[{"title":"t",'
        '"content":"","url":"","engine":""}]}',
      );
    });
  });

  group('retries', () {
    test('an error status on the last attempt is parsed anyway', () async {
      // Go breaks out of the loop only on 200; after the last attempt it
      // reads whatever the response was.
      final server = await _server((request, _) async {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(_validBody);
        await request.response.close();
      });
      final client = _client(server.url, maxRetries: 1);
      addTearDown(client.dispose);
      final response = await client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'test'),
      );
      expect(response.results, hasLength(1));
      expect(server.requests, hasLength(2));
    });

    test('cancelling during the pause after a 429', () async {
      var attempts = 0;
      final client = SearxngClient(
        SearxngClientConfig(
          baseUrl: 'http://localhost',
          retryDelay: const Duration(minutes: 1),
          httpClient: MockClient((_) async {
            attempts++;
            return http.Response('', 429);
          }),
        ),
      );
      final token = CancelToken();
      final search = client.search(
        RunContext.background(cancelToken: token),
        const SearxngSearchRequest(query: 'test'),
      );
      await pumpEventQueue();
      token.cancel('enough');
      expect(
        await _failureOf(search),
        isA<CancelledException>().having((e) => e.reason, 'reason', 'enough'),
      );
      expect(attempts, 1);
    });

    test('negative retries are rejected; timeouts follow Go', () {
      expect(
        () => SearxngClient(
          const SearxngClientConfig(baseUrl: 'http://x', maxRetries: -1),
        ),
        throwsArgumentError,
      );
      expect(
        SearxngClient(
          const SearxngClientConfig(baseUrl: 'http://x', timeout: Duration.zero),
        ).timeout,
        const Duration(seconds: 30),
      );
      expect(
        SearxngClient(
          const SearxngClientConfig(
            baseUrl: 'http://x',
            timeout: Duration(milliseconds: -1),
          ),
        ).timeout,
        goNoTimeout,
      );
    });

    test('a lower-case user-agent header replaces the default', () async {
      final mock = _mock();
      await _client(
        'http://localhost',
        httpClient: mock.client,
        headers: {'user-agent': 'mine'},
      ).search(RunContext.background(), const SearxngSearchRequest(query: 'q'));
      expect(mock.requests.single.headers['User-Agent'], 'mine');
    });
  });

  group('ownership', () {
    test('an owned client works until dispose', () async {
      final server = await _server((request, _) => _println(request, _validBody));
      final client = _client(server.url);
      await client.search(
        RunContext.background(),
        const SearxngSearchRequest(query: 'q'),
      );
      client
        ..dispose()
        ..dispose();
      expect(
        () => client.search(
          RunContext.background(),
          const SearxngSearchRequest(query: 'q'),
        ),
        throwsStateError,
      );
    });

    test('dispose leaves an injected client open', () async {
      final recording = _RecordingClient(_mock().client);
      final tool = SearxngSearchTool(
        SearxngClientConfig(baseUrl: 'http://localhost', httpClient: recording),
      );
      await tool.run('{"query":"q"}');
      tool.dispose();
      expect(recording.closed, isFalse);
      await expectLater(tool.run('{"query":"q"}'), throwsStateError);
    });
  });

  group('values', () {
    test('wire values', () {
      expect(
        [for (final v in SearxngTimeRange.values) v.wireValue],
        ['day', 'month', 'year'],
      );
      expect([for (final v in SearxngLanguage.values) v.wireValue], [
        'all', 'en', 'zh', 'zh-CN', 'zh-TW', 'fr', 'de', 'es', 'ja', 'ko', //
        'ru', 'ar', 'pt', 'it', 'nl', 'pl', 'tr',
      ]);
      expect([for (final v in SearxngSafeSearch.values) v.wireValue], [0, 1, 2]);
      expect([for (final v in SearxngEngine.values) v.wireValue], [
        'google', 'duckduckgo', 'baidu', 'bing', '360search', 'yahoo', //
        'quark',
      ]);
    });

    test('request config JSON', () {
      const config = SearxngSearchRequestConfig(
        timeRange: SearxngTimeRange.month,
        language: SearxngLanguage.zhTW,
        safeSearch: SearxngSafeSearch.moderate,
        engines: [SearxngEngine.search360, SearxngEngine.duckDuckGo],
      );
      expect(config.toJson(), {
        'time_range': 'month',
        'language': 'zh-TW',
        'safesearch': 1,
        'engines': ['360search', 'duckduckgo'],
      });
      expect(SearxngSearchRequestConfig.fromJson(config.toJson()), config);
      expect(const SearxngSearchRequestConfig().toJson(), isEmpty);
      expect(
        SearxngSearchRequestConfig.fromJson(const {
          'time_range': '',
          'safesearch': 0,
          'engines': <Object?>[],
        }),
        const SearxngSearchRequestConfig(),
      );
      expect(
        () => SearxngSearchRequestConfig.fromJson(const {'safesearch': '1'}),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'json: cannot unmarshal string into Go struct field '
                'SearchRequestConfig.safesearch of type searxng.SafeSearchLevel',
          ),
        ),
      );
      expect(
        () => SearxngSearchRequestConfig.fromJson(const {
          'engines': [1],
        }),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('request JSON', () {
      expect(
        const SearxngSearchRequest(query: 'q').toJson(),
        {'query': 'q', 'pageno': null},
      );
      expect(
        SearxngSearchRequest.fromJson(const {'query': 'q', 'pageno': 2}),
        const SearxngSearchRequest(query: 'q', pageNo: 2),
      );
    });

    test("Go's %v for numbers", () {
      expect(goFormatList([1.0, 2.5, -3.25]), '[1 2.5 -3.25]');
      expect(goFormatValue(1e6), '1e+06');
      expect(goFormatValue(123456.0), '123456');
      expect(goFormatValue(1234567.0), '1.234567e+06');
      expect(goFormatValue(0.0001), '0.0001');
      expect(goFormatValue(0.00001), '1e-05');
      expect(goFormatValue(1.5e-7), '1.5e-07');
      expect(goFormatValue(1e21), '1e+21');
      expect(goFormatValue(0.0), '0');
      expect(goFormatValue(7), '7');
      expect(goFormatValue(null), '<nil>');
    });
  });
}
