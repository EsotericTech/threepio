// Port of eino-ext `components/tool/wikipedia`:
// * `wikipedia_test.go`: TestNewTool, TestWikipedia_Search (normal1,
//   normal2, InvalidParameters);
// * `internal/client_test.go`: TestNewClient, TestSearchAndGetPage.
//
// The Go tests call the real Wikipedia. Here the same tests run against a
// fake MediaWiki API (a `MockClient`, and a loopback `HttpServer` for the
// redirect tests) that answers with recorded-shape fixtures: the JSON of
// `api.php?format=json` (formatversion 1) as en.wikipedia.org sends it,
// non-ASCII as backslash-u escapes (written `@u` here, `@q` for an escaped
// quote) and the `warnings` of `prop=revisions`. Page IDs, word counts and
// texts are illustrative; the shape is the real API's. Go only checks that
// these calls succeed; the port also checks what they return (values derived
// from the Go code). Go's TestSearchAndGetPage overwrites its search results
// with those of the empty query before its GetPage loop, so the loop never
// runs; the port gets the pages of the first search, as the test means to.
// Go's InvalidParameters case expects InferTool's
// `[LocalFunc] failed to invoke tool` wrapper; threepio's FunctionTool throws
// the tool's error unwrapped.
//
// Everything after the ported groups is written for the port.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/search_result.dart';
import 'package:threepio_core/src/components/tool/wikipedia/wikipedia_client.dart';
import 'package:threepio_core/src/components/tool/wikipedia/wikipedia_errors.dart';
import 'package:threepio_core/src/components/tool/wikipedia/wikipedia_tool.dart';
import 'package:threepio_core/threepio_core.dart';

final _backslash = String.fromCharCode(92);

/// Restores the escapes of a fixture: `@u` is a backslash and `u`, `@q` an
/// escaped double quote.
String _wire(String fixture) => fixture
    .replaceAll('@u', '${_backslash}u')
    .replaceAll('@q', '$_backslash"');

final _searchFixtures = {
  'bytedance': _wire(
    '{"batchcomplete":"","continue":{"sroffset":3,"continue":"-||"},'
    '"query":{"searchinfo":{"totalhits":2817},"search":['
    '{"ns":0,"title":"ByteDance","pageid":56596452,"wordcount":10822,'
    '"snippet":"<span class=@qsearchmatch@q>ByteDance</span> Ltd. is a '
    'Chinese internet technology company headquartered in Haidian, Beijing"},'
    '{"ns":0,"title":"TikTok","pageid":53382522,"wordcount":25106,'
    '"snippet":"TikTok, known in mainland China as Douyin (Chinese: '
    '@u6296@u97f3; pinyin: D@u01d2uy&#299;n), is owned by '
    '<span class=@qsearchmatch@q>ByteDance</span>"},'
    '{"ns":0,"title":"Zhang Yiming","pageid":56650011,"wordcount":2984,'
    '"snippet":"He founded <span class=@qsearchmatch@q>ByteDance</span>'
    '&nbsp;in 2012"}]}}',
  ),
  'Go programming language': _wire(
    '{"batchcomplete":"","continue":{"sroffset":2,"continue":"-||"},'
    '"query":{"searchinfo":{"totalhits":40211,"suggestion":"go programming '
    'languages","suggestionsnippet":"go programming languages"},"search":['
    '{"ns":0,"title":"Go (programming language)","pageid":25039021,'
    '"wordcount":5733,"snippet":"<span class=@qsearchmatch@q>Go</span> is a '
    'high-level general purpose <span class=@qsearchmatch@q>programming</span> '
    '<span class=@qsearchmatch@q>language</span>"},'
    '{"ns":0,"title":"Go!","pageid":5402181,"wordcount":1146,'
    '"snippet":"<span class=@qsearchmatch@q>Go</span>! is an agent-based '
    '<span class=@qsearchmatch@q>programming</span> '
    '<span class=@qsearchmatch@q>language</span>"}]}}',
  ),
};

const _warnings = '"warnings":{"main":{"*":"Subscribe to the '
    'mediawiki-api-announce mailing list at <https://lists.wikimedia.org/'
    'postorius/lists/mediawiki-api-announce.lists.wikimedia.org/> for notice '
    'of API deprecations and breaking changes."},"revisions":{"*":"Because '
    '@qrvslots@q was not specified, a legacy format has been used for the '
    'output. This format is deprecated, and in the future the new format '
    'will always be used."}}';

final _extracts = {
  'ByteDance': 'ByteDance Ltd. is a Chinese internet technology company '
      'headquartered in Haidian, Beijing.\n\n\n== History ==\n'
      '${'ByteDance was founded in 2012. ' * 80}',
  'TikTok': 'TikTok, known in mainland China as Douyin (抖音), is a social '
      'media and short-form online video platform.',
  'Zhang Yiming': 'Zhang Yiming (张一鸣; born 1 April 1983) is a Chinese '
      'internet entrepreneur.',
  'Go (programming language)': 'Go is a high-level general purpose '
      'programming language that is statically typed and compiled.',
  'Go!': 'Go! is an agent-based programming language in the tradition of '
      'logic-based programming languages like Prolog.',
};

const _pageIds = {
  'ByteDance': 56596452,
  'TikTok': 53382522,
  'Zhang Yiming': 56650011,
  'Go (programming language)': 25039021,
  'Go!': 5402181,
};

/// The answer of `prop=extracts|revisions` for [title].
String _pageFixture(String title) {
  final id = _pageIds[title];
  if (id == null) {
    final normalized = title.isEmpty
        ? title
        : title[0].toUpperCase() + title.substring(1);
    return '{"batchcomplete":"","query":{"normalized":[{"from":'
        '${jsonEncode(title)},"to":${jsonEncode(normalized)}}],"pages":{"-1":'
        '{"ns":0,"title":${jsonEncode(normalized)},"missing":""}}}}';
  }
  return _wire(
    '{"batchcomplete":"",$_warnings,"query":{"pages":{"$id":{"pageid":$id,'
    '"ns":0,"title":${jsonEncode(title)},"extract":'
    '${jsonEncode(_extracts[title])},"revisions":[{"timestamp":'
    '"2025-10-29T08:15:42Z"}]}}}}',
  );
}

const _emptySearch =
    '{"batchcomplete":"","query":{"searchinfo":{"totalhits":0},"search":[]}}';

final _apiError = _wire(
  '{"error":{"code":"nosrsearch","info":"The @qsrsearch@q parameter must be '
  'set.","*":"See https://en.wikipedia.org/w/api.php for API usage."},'
  '"servedby":"mw-api-ext.eqiad.main-7c9f6d8b5-x2x4k"}',
);

/// The fake MediaWiki API: a search answers from [_searchFixtures], a page
/// request from [_pageFixture].
http.Response _fakeApi(http.Request request) {
  final params = request.url.queryParameters;
  if (params['list'] == 'search') {
    return http.Response.bytes(
      utf8.encode(_searchFixtures[params['srsearch']] ?? _emptySearch),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  if (params['prop'] == 'extracts|revisions') {
    return http.Response.bytes(
      utf8.encode(_pageFixture(params['titles'] ?? '')),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  return http.Response(_apiError, 200);
}

/// A client of the fake API that records the requests it gets.
MockClient _fakeClient([List<http.Request>? requests]) =>
    MockClient((request) async {
      requests?.add(request);
      return _fakeApi(request);
    });

/// The tool of the Go tests, `NewTool(ctx, &Config{})`, on the fake API.
WikipediaTool _tool({
  List<http.Request>? requests,
  http.Client? client,
  WikipediaConfig config = const WikipediaConfig(),
}) =>
    WikipediaTool(
      WikipediaConfig(
        baseUrl: config.baseUrl,
        userAgent: config.userAgent,
        docMaxChars: config.docMaxChars,
        timeout: config.timeout,
        topK: config.topK,
        maxRedirect: config.maxRedirect,
        language: config.language,
        toolName: config.toolName,
        toolDesc: config.toolDesc,
        httpClient: client ?? _fakeClient(requests),
      ),
    );

/// The client of TestNewClient / TestSearchAndGetPage.
WikipediaClient _client(http.Client client) => WikipediaClient(
      httpClient: () => client,
      baseUrl: 'https://en.wikipedia.org/w/api.php',
      userAgent: 'eino (https://github.com/cloudwego/eino)',
      topK: 3,
      language: 'en',
      timeout: const Duration(seconds: 15),
      checkRedirect: (next, via) =>
          via.length >= 3 ? 'stopped after 3 redirects' : null,
    );

TypeMatcher<ThreepioException> _threepio(String message) =>
    isA<ThreepioException>().having((e) => e.message, 'message', message);

TypeMatcher<ThreepioException> _threepioStarting(String prefix) =>
    isA<ThreepioException>()
        .having((e) => e.message, 'message', startsWith(prefix));

Matcher _wikipediaError(WikipediaErrorKind kind) => isA<WikipediaException>()
    .having((e) => e.kind, 'kind', kind)
    .having((e) => e.message, 'message', kind.message);

/// [value] without the entries whose value is `null`.
Object? _compact(Object? value) => switch (value) {
      final Map<String, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            if (value != null) key: _compact(value),
        },
      final List<Object?> list => [for (final item in list) _compact(item)],
      _ => value,
    };

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

void main() {
  // -------------------------------------------------------------------------
  // wikipedia_test.go
  // -------------------------------------------------------------------------

  group('TestNewTool', () {
    test('one described parameter', () async {
      final tool = WikipediaTool();
      addTearDown(tool.dispose);
      final info = await tool.info();
      final doc = info.paramsOneOf!.toJsonSchema();
      expect(doc.properties, hasLength(1));
      for (final property in doc.properties.values) {
        expect(property.description, isNotNull);
        expect(property.description, isNot(''));
      }
    });
  });

  group('TestWikipedia_Search', () {
    final tool = _tool();

    test('normal1', () async {
      final toolRes = await tool.invokableRun(
        RunContext.background(),
        jsonEncode({'query': 'bytedance'}),
      );
      expect(toolRes, isNotNull);
      final results =
          (jsonDecode(toolRes) as Map<String, Object?>)['results']!
              as List<Object?>;
      expect(results, hasLength(3));
    });

    test('normal2', () async {
      final toolRes = await tool.invokableRun(
        RunContext.background(),
        jsonEncode({'query': 'Go programming language'}),
      );
      final results =
          (jsonDecode(toolRes) as Map<String, Object?>)['results']!
              as List<Object?>;
      expect(results, hasLength(2));
    });

    test('InvalidParameters', () async {
      await expectLater(
        tool.invokableRun(RunContext.background(), jsonEncode({'query': ''})),
        throwsA(_wikipediaError(WikipediaErrorKind.invalidParameters)),
      );
    });
  });

  // -------------------------------------------------------------------------
  // internal/client_test.go
  // -------------------------------------------------------------------------

  group('TestNewClient', () {
    test('a client with every option', () {
      final client = _client(_fakeClient());
      expect(client.baseUrl, 'https://en.wikipedia.org/w/api.php');
      expect(client.userAgent, 'eino (https://github.com/cloudwego/eino)');
      expect(client.topK, 3);
      expect(client.language, 'en');
      expect(client.timeout, const Duration(seconds: 15));
    });
  });

  group('TestSearchAndGetPage', () {
    test('search, invalid query, pages, missing page', () async {
      final c = _client(_fakeClient());
      final ctx = RunContext.background();

      final results = await c.search(ctx, 'bytedance');
      expect(results, isNotEmpty);

      await expectLater(
        c.search(ctx, ''),
        throwsA(_wikipediaError(WikipediaErrorKind.invalidParameters)),
      );

      for (final result in results) {
        final pr = await c.getPage(ctx, result.title);
        expect(pr.title, result.title);
      }

      await expectLater(
        c.getPage(ctx, 'xxxxxxxxx'),
        throwsA(_wikipediaError(WikipediaErrorKind.pageNotFound)),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Written for the port.
  // -------------------------------------------------------------------------

  group('answer to the model', () {
    test('byte for byte: results in Go field order', () async {
      final tool = _tool();
      final out = await tool.invokableRun(
        RunContext.background(),
        '{"query":"Go programming language"}',
      );
      expect(
        out,
        jsonEncode({
          'results': [
            {
              'title': 'Go (programming language)',
              'url': 'https://en.wikipedia.org/wiki/Go%20%28programming%20language%29',
              'extract': _extracts['Go (programming language)'],
              'snippet': 'Go is a high-level general purpose programming '
                  'language',
            },
            {
              'title': 'Go!',
              'url': 'https://en.wikipedia.org/wiki/Go%21',
              'extract': _extracts['Go!'],
              'snippet': 'Go! is an agent-based programming language',
            },
          ],
        }),
      );
    });

    test('snippets lose the match spans and &nbsp;, nothing else', () async {
      final response = await _tool().search(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'bytedance'),
      );
      expect(
        [for (final result in response.results) result.snippet],
        [
          'ByteDance Ltd. is a Chinese internet technology company '
              'headquartered in Haidian, Beijing',
          'TikTok, known in mainland China as Douyin (Chinese: 抖音; pinyin: '
              'Dǒuy&#299;n), is owned by ByteDance',
          'He founded ByteDance in 2012',
        ],
      );
    });

    test('extracts are cut at 2000 UTF-8 bytes by default', () async {
      final response = await _tool().search(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'bytedance'),
      );
      final extract = response.results.first.extract;
      expect(_extracts['ByteDance']!.length, greaterThan(2000));
      expect(extract, _extracts['ByteDance']!.substring(0, 2000));
      expect(response.results[1].extract, _extracts['TikTok']);
    });

    test('a character cut in two becomes U+FFFD', () async {
      final tool = _tool(config: const WikipediaConfig(docMaxChars: 48));
      final response = await tool.search(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'bytedance'),
      );
      // "TikTok, known in mainland China as Douyin (" is 43 bytes; 抖 and 音
      // take three bytes each: 48 bytes end inside 音.
      expect(
        response.results[1].extract,
        'TikTok, known in mainland China as Douyin (抖${String.fromCharCode(0xfffd)}',
      );
    });

    test('nothing found: page not found', () async {
      await expectLater(
        _tool().search(
          RunContext.background(),
          const WikipediaSearchRequest(query: 'no such thing'),
        ),
        throwsA(_wikipediaError(WikipediaErrorKind.pageNotFound)),
      );
    });

    test('the typed results', () async {
      final hits = await _tool().searchResults(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'Go programming language'),
      );
      expect(hits.first, SearchResult(
        title: 'Go (programming language)',
        url: 'https://en.wikipedia.org/wiki/Go%20%28programming%20language%29',
        snippet: 'Go is a high-level general purpose programming language',
        extra: {'extract': _extracts['Go (programming language)']},
      ));
      expect(
        const WikipediaResult(title: 't', url: 'u').toSearchResult().extra,
        isEmpty,
      );
    });
  });

  group('requests', () {
    test('sorted, Go-escaped queries and the default headers', () async {
      final requests = <http.Request>[];
      await _tool(requests: requests).search(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'Go programming language'),
      );
      expect(requests, hasLength(3));
      expect(
        requests[0].url.toString(),
        'https://en.wikipedia.org/w/api.php?action=query&format=json&'
        'list=search&srlimit=3&srprop=wordcount%7Csnippet&'
        'srsearch=Go+programming+language',
      );
      expect(
        requests[1].url.toString(),
        'https://en.wikipedia.org/w/api.php?action=query&exlimit=1&'
        'explaintext=1&format=json&prop=extracts%7Crevisions&'
        'rvprop=timestamp&titles=Go+%28programming+language%29',
      );
      expect(requests[0].method, 'GET');
      expect(
        requests[0].headers['User-Agent'],
        'eino (https://github.com/cloudwego/eino)',
      );
      expect(requests[0].headers['Accept'], 'application/json');
    });

    test('language, base URL, user agent and topK from the config', () async {
      final requests = <http.Request>[];
      final tool = _tool(
        requests: requests,
        config: const WikipediaConfig(
          language: 'de',
          userAgent: 'my-bot/1.0 (bot@example.test)',
          topK: 7,
        ),
      );
      final response = await tool.search(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'bytedance'),
      );
      expect(requests.first.url.origin, 'https://de.wikipedia.org');
      expect(requests.first.url.path, '/w/api.php');
      expect(requests.first.url.queryParameters['srlimit'], '7');
      expect(requests.first.headers['User-Agent'], 'my-bot/1.0 (bot@example.test)');
      expect(response.results.first.url, 'https://de.wikipedia.org/wiki/ByteDance');

      final custom = <http.Request>[];
      await _tool(
        requests: custom,
        config: const WikipediaConfig(baseUrl: 'https://wiki.test/api.php'),
      ).search(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'bytedance'),
      );
      expect(custom.first.url.toString(), startsWith('https://wiki.test/api.php?action=query'));
    });

    test('page addresses as Go url.PathEscape writes them', () async {
      final c = WikipediaClient(
        httpClient: () => MockClient(
          (_) async => http.Response(
            '{"query":{"search":[{"title":"AC/DC: Back & Forth?","pageid":1}]}}',
            200,
          ),
        ),
        baseUrl: 'https://en.wikipedia.org/w/api.php',
        userAgent: 'ua',
        language: 'en',
        topK: 3,
      );
      final results = await c.search(RunContext.background(), 'acdc');
      expect(
        results.single.url,
        'https://en.wikipedia.org/wiki/AC%2FDC:%20Back%20&%20Forth%3F',
      );
      expect(results.single.language, 'en');
      expect(results.single.pageId, 1);
      expect(results.single.wordCount, 0);
    });
  });

  group('errors', () {
    Future<Object> failure(
      FutureOr<http.Response> Function(http.Request request) handler, {
      String query = 'bytedance',
    }) async {
      final tool = _tool(client: MockClient((r) async => handler(r)));
      try {
        await tool.search(
          RunContext.background(),
          WikipediaSearchRequest(query: query),
        );
      } on Object catch (error) {
        return error;
      }
      fail('no error');
    }

    test('a blank query', () async {
      expect(
        await failure(_fakeApi, query: ' \t\n'),
        _wikipediaError(WikipediaErrorKind.invalidParameters),
      );
    });

    test('an error answer of the API', () async {
      final error = await failure((_) => http.Response(_apiError, 200));
      expect(
        error,
        isA<WikipediaApiException>()
            .having(
              (e) => e.message,
              'message',
              'API error: The "srsearch" parameter must be set. (code: '
                  'nosrsearch)',
            )
            .having((e) => e.code, 'code', 'nosrsearch')
            .having((e) => e.docRef, 'docRef', ''),
      );
    });

    test('a page that disappeared between search and get', () async {
      expect(
        await failure((request) {
          if (request.url.queryParameters['list'] == 'search') {
            return _fakeApi(request);
          }
          return http.Response(_pageFixture('Vanished'), 200);
        }),
        _wikipediaError(WikipediaErrorKind.pageNotFound),
      );
    });

    test('any status but 200', () async {
      expect(
        await failure((_) => http.Response('<html>busy</html>', 503)),
        _threepio('unexpected status code: 503'),
      );
      expect(
        await failure((_) => http.Response(_emptySearch, 201)),
        _threepio('unexpected status code: 201'),
      );
    });

    test('JSON that does not parse or does not fit', () async {
      expect(
        await failure((_) => http.Response('{"query":', 200)),
        isA<ThreepioFormatException>().having(
          (e) => e.message,
          'message',
          startsWith('json unmarshal failed: '),
        ),
      );
      expect(
        await failure(
          (_) => http.Response(
            '{"query":{"search":[{"title":"T","pageid":"12"}]}}',
            200,
          ),
        ),
        _threepio(
          'json unmarshal failed: json: cannot unmarshal string into Go '
          'struct field .query.search.pageid of type int',
        ),
      );
      expect(
        await failure((request) {
          if (request.url.queryParameters['list'] == 'search') {
            return _fakeApi(request);
          }
          return http.Response(
            '{"query":{"pages":{"1":{"pageid":1,"title":"T","revisions":'
            '[{"timestamp":"yesterday"}]}}}}',
            200,
          );
        }),
        _threepioStarting('json unmarshal failed: parsing time "yesterday"'),
      );
    });

    test('a request that fails', () async {
      final error = await failure(
        (_) => throw http.ClientException('Connection reset by peer'),
      );
      expect(
        error,
        _threepio(
          'request failed: Get "https://en.wikipedia.org/w/api.php?'
          'action=query&format=json&list=search&srlimit=3&'
          'srprop=wordcount%7Csnippet&srsearch=bytedance": Connection reset '
          'by peer',
        ),
      );
    });

    test('a body that cannot be read', () async {
      final tool = _tool(
        client: MockClient.streaming(
          (_, __) async => http.StreamedResponse(
            Stream<List<int>>.error(const SocketException('reset')),
            200,
          ),
        ),
      );
      await expectLater(
        tool.search(
          RunContext.background(),
          const WikipediaSearchRequest(query: 'bytedance'),
        ),
        throwsA(_threepioStarting('read response body failed: ')),
      );
    });
  });

  group('pages', () {
    test('the first page of the answer; a page without an ID is missing',
        () async {
      Future<WikipediaPage> page(String body) => WikipediaClient(
            httpClient: () => MockClient((_) async => http.Response(body, 200)),
            baseUrl: 'https://en.wikipedia.org/w/api.php',
            userAgent: 'ua',
            language: 'en',
            topK: 3,
          ).getPage(RunContext.background(), 'T');

      final first = await page(
        '{"query":{"pages":{"9":{"pageid":9,"title":"Nine","extract":"n",'
        '"revisions":[{"timestamp":"2024-01-02T03:04:05+02:00"},'
        '{"timestamp":null}]},"3":{"pageid":3,"title":"Three"}}}}',
      );
      expect(first.title, 'Nine');
      expect(first.pageId, 9);
      expect(first.content, 'n');
      expect(first.url, 'https://en.wikipedia.org/wiki/Nine');
      expect(first.lastUpdated, DateTime.utc(2024, 1, 2, 1, 4, 5));

      final noRevision = await page('{"query":{"pages":{"3":{"pageid":3}}}}');
      expect(noRevision.lastUpdated, isNull);

      await expectLater(
        page('{"query":{"pages":{"-1":null}}}'),
        throwsA(_wikipediaError(WikipediaErrorKind.pageNotFound)),
      );
      await expectLater(
        page('{"query":{"pages":{}}}'),
        throwsA(_wikipediaError(WikipediaErrorKind.pageNotFound)),
      );
      // Go does not look at the error member of a page answer.
      await expectLater(
        page(_apiError),
        throwsA(_wikipediaError(WikipediaErrorKind.pageNotFound)),
      );
    });
  });

  group('redirects', () {
    Future<HttpServer> serverWith(int redirects) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final hop = int.tryParse(request.uri.queryParameters['hop'] ?? '0')!;
        if (hop < redirects) {
          final next = request.uri.replace(
            queryParameters: {
              ...request.uri.queryParameters,
              'hop': '${hop + 1}',
            },
          );
          request.response
            ..statusCode = 302
            ..headers.set('location', next.toString());
        } else {
          final params = request.uri.queryParameters;
          final body = params['list'] == 'search'
              ? _searchFixtures['Go programming language']!
              : _pageFixture(params['titles']!);
          request.response
            ..headers.contentType = ContentType.json
            ..add(utf8.encode(body));
        }
        await request.response.close();
      });
      return server;
    }

    test('two redirects are followed (MaxRedirect 3)', () async {
      final server = await serverWith(2);
      addTearDown(() => server.close(force: true));
      final tool = WikipediaTool(
        WikipediaConfig(baseUrl: 'http://127.0.0.1:${server.port}/w/api.php'),
      );
      addTearDown(tool.dispose);
      final response = await tool.search(
        RunContext.background(),
        const WikipediaSearchRequest(query: 'Go programming language'),
      );
      expect(response.results, hasLength(2));
    });

    test('the third redirect is too many', () async {
      final server = await serverWith(3);
      addTearDown(() => server.close(force: true));
      final tool = WikipediaTool(
        WikipediaConfig(baseUrl: 'http://127.0.0.1:${server.port}/w/api.php'),
      );
      addTearDown(tool.dispose);
      final error = await tool
          .search(
            RunContext.background(),
            const WikipediaSearchRequest(query: 'Go programming language'),
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        error,
        // Go quotes the Location header as it came.
        _threepioStarting('request failed: Get "/w/api.php?').having(
          (e) => e.message,
          'message',
          endsWith('hop=3": too many redirects'),
        ),
      );
      expect(
        ThreepioException.findCause<WikipediaException>(error),
        WikipediaException(WikipediaErrorKind.tooManyRedirects),
      );
    });

    test('MaxRedirect 1 refuses the first redirect', () async {
      var requests = 0;
      final tool = _tool(
        client: MockClient((request) async {
          requests++;
          return http.Response('', 301, headers: {'location': '/elsewhere'});
        }),
        config: const WikipediaConfig(maxRedirect: 1),
      );
      await expectLater(
        tool.search(
          RunContext.background(),
          const WikipediaSearchRequest(query: 'bytedance'),
        ),
        throwsA(
          _threepio('request failed: Get "/elsewhere": too many redirects'),
        ),
      );
      expect(requests, 1);
    });
  });

  group('cancellation and timeouts', () {
    test('a cancelled context sends nothing', () async {
      final requests = <http.Request>[];
      await expectLater(
        _tool(requests: requests).search(
          RunContext.background(cancelToken: CancelToken()..cancel()),
          const WikipediaSearchRequest(query: 'bytedance'),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(requests, isEmpty);
    });

    test('cancelling between the search and the pages', () async {
      final token = CancelToken();
      final requests = <String>[];
      final tool = _tool(
        client: MockClient((request) async {
          requests.add(request.url.queryParameters['list'] ?? 'page');
          final response = _fakeApi(request);
          token.cancel('enough');
          return response;
        }),
      );
      await expectLater(
        tool.search(
          RunContext.background(cancelToken: token),
          const WikipediaSearchRequest(query: 'bytedance'),
        ),
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'enough'),
        ),
      );
      expect(requests, ['search']);
    });

    test('an injected timeout', () async {
      final answer = Completer<http.StreamedResponse>();
      final tool = _tool(
        client: MockClient.streaming((_, __) => answer.future),
        config: const WikipediaConfig(timeout: Duration(milliseconds: 20)),
      );
      await expectLater(
        tool.search(
          RunContext.background(),
          const WikipediaSearchRequest(query: 'bytedance'),
        ),
        throwsA(
          _threepioStarting('request failed: Get "https://en.wikipedia.org/')
              .having(
                (e) => e.message,
                'message',
                endsWith(
                  ': context deadline exceeded (Client.Timeout exceeded while '
                  'awaiting headers)',
                ),
              )
              .having((e) => e.cause, 'cause', isA<TimeoutException>()),
        ),
      );
      answer.complete(
        http.StreamedResponse(const Stream<List<int>>.empty(), 200),
      );
    });
  });

  group('tool', () {
    test('name, description, schema and type as Go', () async {
      final tool = WikipediaTool();
      addTearDown(tool.dispose);
      final info = await tool.info();
      expect(info.name, 'wikipedia_search');
      expect(
        info.desc,
        'this tool provides quick and efficient access to information from '
        'the Wikipedia',
      );
      expect(_compact(info.paramsOneOf!.toJsonSchema().toJson()), {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The query to search the web for',
          },
        },
        'required': ['query'],
        'additionalProperties': false,
      });
      expect(tool.componentTypeName, 'WikipediaSearch');

      final custom = WikipediaTool(
        const WikipediaConfig(toolName: 'wiki', toolDesc: 'encyclopedia'),
      );
      addTearDown(custom.dispose);
      expect((await custom.info()).name, 'wiki');
      expect((await custom.info()).desc, 'encyclopedia');
    });

    test('the legacy run entry point and bad arguments', () async {
      final tool = _tool();
      final out = await tool.run('{"query":"Go programming language"}');
      expect(out, startsWith('{"results":[{"title":"Go (programming language)"'));
      await expectLater(
        tool.invokableRun(RunContext.background(), '{"query":1}'),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('values', () {
      expect(
        WikipediaSearchRequest.fromJson(const {'query': 'q'}),
        const WikipediaSearchRequest(query: 'q'),
      );
      expect(const WikipediaSearchRequest(query: 'q').toJson(), {'query': 'q'});
      expect(
        const WikipediaSearchResponse(
          results: [WikipediaResult(title: 't', url: 'u')],
        ).toJson(),
        {
          'results': [
            {'title': 't', 'url': 'u', 'extract': '', 'snippet': ''},
          ],
        },
      );
      expect(
        WikipediaException(WikipediaErrorKind.pageNotFound).toString(),
        'WikipediaException: page not found',
      );
    });

    test('an injected client is never closed; a disposed tool throws',
        () async {
      final client = _TrackingClient(_fakeClient());
      _tool(client: client).dispose();
      expect(client.closed, isFalse);

      final own = WikipediaTool()
        ..dispose()
        ..dispose();
      await expectLater(
        own.search(
          RunContext.background(),
          const WikipediaSearchRequest(query: 'bytedance'),
        ),
        throwsStateError,
      );
    });
  });
}
