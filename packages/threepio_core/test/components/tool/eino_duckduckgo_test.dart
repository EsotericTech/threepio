// Port of eino-ext `components/tool/duckduckgo/v2`:
// * `search_test.go`: Test_buildClient (both cases, through the resolved
//   values of DuckDuckGoSearchClient).
// * `text_search_test.go`: TestClientTextSearch (Go mocks the header and body
//   builders and `doTextHTMLSearch`; here a MockClient serves two result pages
//   with the same hits, and the real builders run) and TestParseSearchResponse
//   ("found results", "no results"), with Go's HTML fixtures copied byte for
//   byte into `eino_duckduckgo_fixtures.dart`.
// Every Go test of the package is ported. The deprecated v1 package
// (`duckduckgo/search_test.go`, `ddgsearch`) is not ported.
//
// Written for the port: the tool info, the request on the wire (URL, form,
// headers), the answer to the model byte for byte, paging and its
// termination, the typed SearchResult mapping, argument decoding, HTTP
// errors, timeouts, cancellation, and client ownership.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/duckduckgo/duckduckgo_search.dart';
import 'package:threepio_core/src/components/tool/duckduckgo/duckduckgo_types.dart';
import 'package:threepio_core/src/components/tool/duckduckgo/go_wire.dart';
import 'package:threepio_core/src/components/tool/search_result.dart';
import 'package:threepio_core/threepio_core.dart';

import 'eino_duckduckgo_fixtures.dart';

/// A result page with [hits] (href, title, snippet) and, when [next] is
/// given, a next-page form with those hidden fields.
String _page(
  List<(String, String, String)> hits, {
  Map<String, String>? next,
}) {
  final out = StringBuffer(
    '<html><body><form action="/html/" method="post">'
    '<input type="hidden" name="first" value="form"/></form>'
    '<div id="links" class="results">',
  );
  for (final (href, title, snippet) in hits) {
    out.write(
      '<div class="result results_links results_links_deep web-result ">'
      '<h2 class="result__title"><a class="result__a" href="$href">$title</a>'
      '</h2><a class="result__snippet" href="$href">$snippet</a></div>',
    );
  }
  if (next != null) {
    out.write(
      '<div class="nav-link"><form action="/html/" method="post">'
      '<input type="submit" value="Next" />',
    );
    next.forEach(
      (name, value) => out.write(
        '<input type="hidden" name="$name" value="$value" />',
      ),
    );
    out.write('</form></div>');
  }
  out.write('</div></body></html>');
  return out.toString();
}

/// A MockClient that answers the requests in turn with [pages] (status 200)
/// and records them.
({MockClient client, List<http.Request> requests}) _serve(
  List<String> pages,
) {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    if (requests.length > pages.length) {
      fail('unexpected request ${requests.length}: ${request.body}');
    }
    return http.Response.bytes(utf8.encode(pages[requests.length - 1]), 200);
  });
  return (client: client, requests: requests);
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

const _expectedUrls = [
  'https://github.com/cloudwego/eino',
  'https://www.cloudwego.io/zh/docs/eino/overview/',
  'https://ai-bot.cn/eino/',
  'https://cloudwego.cn/docs/eino/overview/eino_open_source/',
  'https://stable-learn.com/en/eino-open-source-announcement/',
  'https://juejin.cn/post/7460126710085091367',
  'https://www.cloudwego.io/docs/eino/',
  'https://pkg.go.dev/github.com/cloudwego/eino',
  'https://github.com/cloudwego/eino-ext',
  'https://en.wikipedia.org/wiki/Eino',
];

const _firstTitle =
    'GitHub - cloudwego/eino: The ultimate LLM/AI application development ...';
const _firstSummary =
    'Eino is a framework for building LLM applications in Golang, inspired '
    'by LangChain and LlamaIndex. It provides component abstractions, '
    'orchestration APIs, best practices, tools and examples for LLM '
    'development.';
const _secondTitle = 'Eino: 概述 | CloudWeGo';
const _secondSummary =
    "Eino: 概述 简介. Eino['aino] (近似音: i know，希望框架能达到 \"i know\" 的愿景) "
    '旨在提供基于 Golang 语言的终极大模型应用开发框架。 它从开源社区中的诸多优秀 LLM 应用开发框架，'
    '如 LangChain 和 LlamaIndex 等获取灵感，同时借鉴前沿研究成果与实际应用，'
    '提供了一个强调简洁性、可扩展性、可靠性与 ...';

const _nextForm =
    'api=d.js&dc=11&kl=wt-wt&nextParams=&o=json&q=eino&s=10&v=l&'
    'vqd=4-167208798460794982980732831674372650598';

void main() {
  group('Test_buildClient', () {
    test('nil config', () {
      final client = DuckDuckGoSearchClient();
      expect(client.region, DuckDuckGoRegion.wt);
      expect(client.maxResults, 10);
      expect(client.timeout, const Duration(seconds: 30));
    });

    test('custom config', () {
      final client = DuckDuckGoSearchClient(
        const DuckDuckGoConfig(
          timeout: Duration(seconds: 15),
          maxResults: 20,
          region: DuckDuckGoRegion.us,
        ),
      );
      expect(client.region, DuckDuckGoRegion.us);
      expect(client.maxResults, 20);
      expect(client.timeout, const Duration(seconds: 15));
    });

    test('zero and negative values take Go defaults', () {
      expect(
        DuckDuckGoSearchClient(const DuckDuckGoConfig(maxResults: -3))
            .maxResults,
        10,
      );
      expect(
        DuckDuckGoSearchClient(const DuckDuckGoConfig(timeout: Duration.zero))
            .timeout,
        const Duration(seconds: 30),
      );
      // A negative Client.Timeout means no limit in Go.
      expect(
        DuckDuckGoSearchClient(
          const DuckDuckGoConfig(timeout: Duration(seconds: -1)),
        ).timeout,
        goNoTimeout,
      );
    });
  });

  group('TestClientTextSearch', () {
    test('stops at MaxResults across pages', () async {
      final served = _serve([
        _page([('1', '', ''), ('2', '', '')], next: {'s': '1'}),
        _page([('3', '', ''), ('4', '', '')]),
      ]);
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(
          maxResults: 3,
          httpClient: served.client,
          pageDelay: const Duration(milliseconds: 1),
        ),
      );

      final response = await client.textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );

      expect(response.results, const [
        DuckDuckGoTextSearchResult(url: '1'),
        DuckDuckGoTextSearchResult(url: '2'),
        DuckDuckGoTextSearchResult(url: '3'),
      ]);
      expect(response.message, 'Found 3 results successfully.');
      expect(served.requests, hasLength(2));
      expect(served.requests[1].body, 's=1');
    });
  });

  group('TestParseSearchResponse', () {
    test('found results', () {
      final page = DuckDuckGoSearchClient.parseTextHtmlSearchResponse(
        duckDuckGoFoundResultsPage,
      );
      expect(page.results, hasLength(10));
      expect(page.nextBody!['vqd'], isNotEmpty);

      // Derived from the fixture: the hits in page order, Go's cleaning.
      expect([for (final r in page.results) r.url], _expectedUrls);
      expect(
        page.results[0],
        const DuckDuckGoTextSearchResult(
          title: _firstTitle,
          url: 'https://github.com/cloudwego/eino',
          summary: _firstSummary,
        ),
      );
      expect(page.results[1].title, _secondTitle);
      expect(page.results[1].summary, _secondSummary);
      expect(page.results[9].title, 'Eino - Wikipedia');
      expect(page.nextBody, {
        'q': ['eino'],
        's': ['10'],
        'nextParams': [''],
        'v': ['l'],
        'o': ['json'],
        'dc': ['11'],
        'api': ['d.js'],
        'vqd': ['4-167208798460794982980732831674372650598'],
        'kl': ['wt-wt'],
      });
      expect(goEncodeValues(page.nextBody!), _nextForm);
    });

    test('no results', () {
      final eof =
          DuckDuckGoSearchClient.parseTextHtmlSearchResponse(duckDuckGoEofPage);
      expect(eof.results, isEmpty);
      expect(eof.nextBody, isNull);

      final none = DuckDuckGoSearchClient.parseTextHtmlSearchResponse(
        duckDuckGoNoResultsPage,
      );
      expect(none.results, isEmpty);
      expect(none.nextBody, isNull);
    });
  });

  group('parseTextHtmlSearchResponse', () {
    test('skips repeated, Google fallback and ad links', () {
      final page = DuckDuckGoSearchClient.parseTextHtmlSearchResponse(
        _page([
          ('https://a.example/', 'A', 'a'),
          ('https://a.example/', 'A again', 'a again'),
          ('http://www.google.com/search?q=x', 'G', 'g'),
          ('https://duckduckgo.com/y.js?ad_domain=x', 'Ad', 'ad'),
          ('https://b.example/', 'B', 'b'),
        ]),
      );
      expect(page.results, const [
        DuckDuckGoTextSearchResult(
          title: 'A',
          url: 'https://a.example/',
          summary: 'a',
        ),
        DuckDuckGoTextSearchResult(
          title: 'B',
          url: 'https://b.example/',
          summary: 'b',
        ),
      ]);
    });

    test('skips hits without a title link, an href or a snippet', () {
      const html = '<div id="links">'
          // No link in the title.
          '<div class="web-result"><h2 class="result__title">T</h2>'
          '<a class="result__snippet">s</a></div>'
          // The link is not a child of the h2.
          '<div class="web-result"><h2 class="result__title"><span>'
          '<a href="https://x.example/">T</a></span></h2>'
          '<a class="result__snippet">s</a></div>'
          // Empty href.
          '<div class="web-result"><h2 class="result__title"><a href="">T</a>'
          '</h2><a class="result__snippet">s</a></div>'
          // No snippet.
          '<div class="web-result"><h2 class="result__title">'
          '<a href="https://y.example/">T</a></h2></div>'
          // Not inside div#links.
          '</div><div class="web-result"><h2 class="result__title">'
          '<a href="https://z.example/">T</a></h2>'
          '<a class="result__snippet">s</a></div>';
      final page = DuckDuckGoSearchClient.parseTextHtmlSearchResponse(html);
      expect(page.results, isEmpty);
      expect(page.nextBody, isNull);
    });

    test("trims Go's white space, keeps U+FEFF, decodes entities", () {
      final nbsp = String.fromCharCode(0xA0);
      final ideographic = String.fromCharCode(0x3000);
      final bom = String.fromCharCode(0xFEFF);
      final page = DuckDuckGoSearchClient.parseTextHtmlSearchResponse(
        _page([
          (
            'https://a.example/?a=1&amp;b=2',
            '$nbsp\n  <b>Bold</b> &amp; plain\t$ideographic',
            '${bom}snippet ',
          ),
        ]),
      );
      expect(page.results.single.url, 'https://a.example/?a=1&b=2');
      expect(page.results.single.title, 'Bold & plain');
      expect(page.results.single.summary, '${bom}snippet');
    });

    test('the next form comes from the last form; empty without inputs', () {
      final withInputs = DuckDuckGoSearchClient.parseTextHtmlSearchResponse(
        _page([('https://a.example/', 'A', 'a')], next: {'s': '30'}),
      );
      expect(withInputs.nextBody, {
        's': ['30'],
      });

      const noInputs = '<div id="links"><div class="web-result">'
          '<h2 class="result__title"><a href="https://a.example/">A</a></h2>'
          '<a class="result__snippet">a</a></div>'
          '<div class="nav-link"><form><input type="hidden" value="no name"/>'
          '<input type="hidden" name="no value"/>'
          '<input type="text" name="t" value="not hidden"/></form></div></div>';
      expect(
        DuckDuckGoSearchClient.parseTextHtmlSearchResponse(noInputs).nextBody,
        isEmpty,
      );
    });

    test('malformed HTML yields no hits instead of an error', () {
      for (final body in ['', '<<<>>>', '<div id="links"><div class="web', 'x']) {
        final page = DuckDuckGoSearchClient.parseTextHtmlSearchResponse(body);
        expect(page.results, isEmpty, reason: body);
        expect(page.nextBody, isNull, reason: body);
      }
    });
  });

  group('the request', () {
    test("posts Go's form and headers to the HTML endpoint", () async {
      final served = _serve([_page([])]);
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(httpClient: served.client),
      );
      await client.textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );

      final request = served.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://html.duckduckgo.com/html/');
      expect(request.body, 'b=&df=&kl=&q=eino');
      expect(request.headers['Referer'], 'https://html.duckduckgo.com/');
      expect(request.headers['Sec-Fetch-Site'], 'same-origin');
      expect(request.headers['Sec-Fetch-Dest'], 'document');
      expect(request.headers['Sec-Fetch-Mode'], 'navigate');
      expect(request.headers['Sec-Fetch-User'], '?1');
      expect(
        request.headers['Content-Type'],
        'application/x-www-form-urlencoded',
      );
      expect(
        DuckDuckGoSearchClient.userAgents,
        contains(request.headers['User-Agent']),
      );
    });

    test('region, time range and escaping', () async {
      final served = _serve([_page([])]);
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(
          httpClient: served.client,
          region: DuckDuckGoRegion.jp,
        ),
      );
      await client.textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(
          query: 'eino & go/ü~!',
          timeRange: DuckDuckGoTimeRange.week,
        ),
      );
      expect(
        served.requests.single.body,
        'b=&df=w&kl=jp-jp&q=eino+%26+go%2F%C3%BC~%21',
      );
    });

    test('the next page posts the next form with the same user agent',
        () async {
      final served = _serve([duckDuckGoFoundResultsPage, _page([])]);
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(
          httpClient: served.client,
          maxResults: 15,
          pageDelay: const Duration(milliseconds: 1),
        ),
      );
      final response = await client.textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      expect(response.results, hasLength(10));
      expect(served.requests, hasLength(2));
      expect(served.requests[1].body, _nextForm);
      expect(
        served.requests[1].headers['User-Agent'],
        served.requests[0].headers['User-Agent'],
      );
    });

    test('headers pick a user agent of the list at random', () {
      final headers =
          DuckDuckGoSearchClient.buildTextHtmlRequestHeaders(Random(1));
      expect(DuckDuckGoSearchClient.userAgents, contains(headers['User-Agent']));
      expect(headers, hasLength(7));
    });

    test('the first form for every time range', () {
      for (final range in DuckDuckGoTimeRange.values) {
        final body = DuckDuckGoSearchClient.buildTextHtmlRequestBody(
          DuckDuckGoTextSearchRequest(query: 'q', timeRange: range),
          DuckDuckGoRegion.wt,
        );
        expect(body, {
          'q': ['q'],
          'b': [''],
          'kl': [''],
          'df': [range.wireValue],
        });
      }
    });

    test('a region the Go package does not name, as Go Region("es-es")', () {
      const spain = DuckDuckGoRegion('es-es');
      expect(spain, isNot(DuckDuckGoRegion.wt));
      // Built at run time, so not the canonical constants: equality and
      // the hash code go by the code.
      final us = DuckDuckGoRegion(['us', 'en'].join('-'));
      final world = DuckDuckGoRegion(['wt', 'wt'].join('-'));
      expect(identical(us, DuckDuckGoRegion.us), isFalse);
      expect(us, DuckDuckGoRegion.us);
      expect(us.hashCode, DuckDuckGoRegion.us.hashCode);
      expect(identical(world, DuckDuckGoRegion.wt), isFalse);
      expect(world, DuckDuckGoRegion.wt);
      final body = DuckDuckGoSearchClient.buildTextHtmlRequestBody(
        const DuckDuckGoTextSearchRequest(query: 'q'),
        spain,
      );
      expect(body['kl'], ['es-es']);
      // The world region by its code is the world region: no `kl`.
      expect(
        DuckDuckGoSearchClient.buildTextHtmlRequestBody(
          const DuckDuckGoTextSearchRequest(query: 'q'),
          world,
        )['kl'],
        [''],
      );
    });

    test('an empty region code is the world region, as Go buildClient', () {
      final client = DuckDuckGoSearchClient(
        const DuckDuckGoConfig(region: DuckDuckGoRegion('')),
      );
      addTearDown(client.dispose);
      expect(identical(client.region, DuckDuckGoRegion.wt), isTrue);
      final custom = DuckDuckGoSearchClient(
        const DuckDuckGoConfig(region: DuckDuckGoRegion('es-es')),
      );
      addTearDown(custom.dispose);
      expect(custom.region.wireValue, 'es-es');
    });
  });

  group('paging', () {
    test('a page within MaxResults is cut, the next is not fetched', () async {
      final served = _serve([duckDuckGoFoundResultsPage]);
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(httpClient: served.client, maxResults: 3),
      );
      final response = await client.textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      expect([for (final r in response.results) r.url], _expectedUrls.take(3));
      expect(served.requests, hasLength(1));
    });

    test('ends after MaxResults pages when every page has one hit', () async {
      var requests = 0;
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(
          maxResults: 4,
          pageDelay: Duration.zero,
          httpClient: MockClient((request) async {
            requests++;
            if (requests > 4) fail('the paging loop did not stop');
            return http.Response(
              _page([('https://same.example/', 'S', 's')], next: {'s': '$requests'}),
              200,
            );
          }),
        ),
      );
      final response = await client.textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      // Duplicates are only skipped within one page, as in Go.
      expect(response.results, hasLength(4));
      expect(requests, 4);
    });

    test('ends at a page without hits', () async {
      final served = _serve([
        _page([('https://a.example/', 'A', 'a')], next: {'s': '1'}),
        _page([], next: {'s': '2'}),
      ]);
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(httpClient: served.client, pageDelay: Duration.zero),
      );
      final response = await client.textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      expect(response.results, hasLength(1));
      expect(served.requests, hasLength(2));
    });

    test('ends without a next page or with an empty next form', () async {
      final noNav = _serve([_page([('https://a.example/', 'A', 'a')])]);
      final first = await DuckDuckGoSearchClient(
        DuckDuckGoConfig(httpClient: noNav.client),
      ).textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      expect(first.results, hasLength(1));
      expect(noNav.requests, hasLength(1));

      final emptyNext = _serve([
        _page([('https://a.example/', 'A', 'a')], next: {}),
      ]);
      final second = await DuckDuckGoSearchClient(
        DuckDuckGoConfig(httpClient: emptyNext.client),
      ).textSearch(
        RunContext.background(),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      expect(second.results, hasLength(1));
      expect(emptyNext.requests, hasLength(1));
    });
  });

  group('DuckDuckGoSearchTool', () {
    test('tool info', () async {
      final tool = DuckDuckGoSearchTool();
      final info = await tool.info();
      expect(info.name, 'duckduckgo_text_search');
      expect(
        info.desc,
        'This is a duckduckgo plain text information search tool. \n'
        'It can be useful to help you get information within a certain time '
        'range.',
      );
      expect(tool.componentTypeName, 'DuckduckgoTextSearch');
      expect(tool.name, 'duckduckgo_text_search');
      expect(
        jsonEncode(info.paramsOneOf!.jsonSchemaMap),
        '{"properties":{"query":{"description":"The user\'s search query. '
        'The query is required.","type":"string"},"time_range":{"oneOf":['
        '{"enum":["d"],"description":"Search information from the past day",'
        '"type":"string"},{"enum":["w"],"description":"Search information '
        'from the past week","type":"string"},{"enum":["m"],"description":'
        '"Search information from the past month","type":"string"},{"enum":'
        '["y"],"description":"Search information from the past year","type":'
        '"string"},{"enum":[""],"description":"Search information at any '
        'time","type":"string"}],"description":"The time range of search '
        'results","default":"","type":"string"}},"required":["query"],'
        '"type":"object"}',
      );
      expect(info.function.parameters!.required, ['query']);
      expect(
        info.function.parameters!.properties.keys,
        ['query', 'time_range'],
      );
    });

    test('custom name and description', () async {
      final tool = DuckDuckGoSearchTool(
        const DuckDuckGoConfig(toolName: 'web_lookup', toolDesc: 'Looks up'),
      );
      final info = await tool.info();
      expect(info.name, 'web_lookup');
      expect(info.desc, 'Looks up');
      expect(tool.componentTypeName, 'WebLookup');

      final empty = DuckDuckGoSearchTool(
        const DuckDuckGoConfig(toolName: '', toolDesc: ''),
      );
      expect((await empty.info()).name, DuckDuckGoSearchTool.defaultToolName);
      expect((await empty.info()).desc, DuckDuckGoSearchTool.defaultToolDesc);
    });

    test("answers with Go's JSON byte for byte", () async {
      final served = _serve([duckDuckGoFoundResultsPage]);
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: served.client, maxResults: 2),
      );
      final answer = await tool.invokableRun(
        RunContext.background(),
        '{"query":"eino"}',
      );
      expect(
        answer,
        '{"message":"Found 2 results successfully.","results":[{"title":'
        '"$_firstTitle","url":"https://github.com/cloudwego/eino","summary":'
        '"$_firstSummary"},{"title":"$_secondTitle","url":'
        '"https://www.cloudwego.io/zh/docs/eino/overview/","summary":'
        '${jsonEncode(_secondSummary)}}]}',
      );
      expect(answer, contains(r'\"i know\"'));
    });

    test('backspace and form feed are escaped as sonic writes them', () async {
      final backslash = String.fromCharCode(0x5c);
      final backspace = String.fromCharCode(0x08);
      final formFeed = String.fromCharCode(0x0c);
      final served = _serve([
        _page([
          ('https://a.example/', 'A${formFeed}B', 'x$backspace${formFeed}y'),
        ]),
      ]);
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: served.client),
      );
      expect(
        await tool.run('{"query":"eino"}'),
        '{"message":"Found 1 results successfully.","results":[{"title":'
        '"A${backslash}u000cB","url":"https://a.example/","summary":'
        '"x${backslash}u0008${backslash}u000cy"}]}',
      );
    });

    test('without hits the answer has no results key', () async {
      final served = _serve([duckDuckGoNoResultsPage]);
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: served.client),
      );
      expect(
        await tool.run('{"query":"testtesttest","time_range":"w"}'),
        '{"message":"No good results were found."}',
      );
      expect(served.requests.single.body, 'b=&df=w&kl=&q=testtesttest');
    });

    test('argument decoding: case-insensitive keys, unknown time range',
        () async {
      final served = _serve([_page([]), _page([])]);
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: served.client),
      );
      await tool.run('{"QUERY":"a","Time_Range":"y"}');
      await tool.run('{"query":"b","time_range":"decade"}');
      expect(served.requests[0].body, 'b=&df=y&kl=&q=a');
      expect(served.requests[1].body, 'b=&df=&kl=&q=b');
    });

    test('an empty or missing query fails before any request', () async {
      final served = _serve([]);
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: served.client),
      );
      for (final arguments in ['{"query":""}', '{}', '', '{"query":null}']) {
        await expectLater(
          tool.run(arguments),
          throwsA(
            isA<ThreepioFormatException>().having(
              (e) => e.message,
              'message',
              'search query is required',
            ),
          ),
          reason: arguments,
        );
      }
      expect(served.requests, isEmpty);
    });

    test('arguments of the wrong type fail with Go-style text', () async {
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: _serve([]).client),
      );
      await expectLater(
        tool.run('{"query":1}'),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            contains(
              'json: cannot unmarshal number into Go struct field '
              'TextSearchRequest.query of type string',
            ),
          ),
        ),
      );
      await expectLater(
        tool.run('{"query":"q","time_range":["d"]}'),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            contains(
              'json: cannot unmarshal array into Go struct field '
              'TextSearchRequest.time_range of type duckduckgo.TimeRange',
            ),
          ),
        ),
      );
      await expectLater(tool.run('[1]'), throwsA(isA<ThreepioFormatException>()));
    });

    test("search returns Go's answer, searchResults the SearchResults",
        () async {
      final served = _serve(
        [duckDuckGoFoundResultsPage, duckDuckGoFoundResultsPage],
      );
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: served.client, maxResults: 2),
      );
      const request = DuckDuckGoTextSearchRequest(
        query: 'eino',
        timeRange: DuckDuckGoTimeRange.month,
      );
      final response = await tool.search(RunContext.background(), request);
      expect(response.message, 'Found 2 results successfully.');
      expect(response.results[1].summary, _secondSummary);

      final hits = await tool.searchResults(RunContext.background(), request);
      expect(hits, const [
        SearchResult(
          title: _firstTitle,
          url: 'https://github.com/cloudwego/eino',
          snippet: _firstSummary,
        ),
        SearchResult(
          title: _secondTitle,
          url: 'https://www.cloudwego.io/zh/docs/eino/overview/',
          snippet: _secondSummary,
        ),
      ]);
      expect(served.requests, hasLength(2));
      expect(served.requests[1].body, 'b=&df=m&kl=&q=eino');

      final none = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: _serve([_page([])]).client),
      );
      expect(
        await none.searchResults(
          RunContext.background(),
          const DuckDuckGoTextSearchRequest(query: 'nothing'),
        ),
        isEmpty,
      );
    });
  });

  group('HTTP errors', () {
    Future<Object> failureOf(http.Client client) async {
      final search = DuckDuckGoSearchClient(
        DuckDuckGoConfig(
          httpClient: client,
          timeout: const Duration(milliseconds: 20),
        ),
      );
      try {
        await search.textSearch(
          RunContext.background(),
          const DuckDuckGoTextSearchRequest(query: 'eino'),
        );
      } on Object catch (error) {
        return error;
      }
      fail('the search succeeded');
    }

    test('a status other than 200', () async {
      for (final status in [202, 403, 500]) {
        final error = await failureOf(
          MockClient((_) async => http.Response('', status)),
        );
        expect(
          error,
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'unexpected status code: $status'),
        );
      }
    });

    test('a request that cannot be sent', () async {
      final error = await failureOf(
        MockClient((_) async => throw http.ClientException('refused')),
      );
      expect(
        error,
        isA<ThreepioException>()
            .having((e) => e.message, 'message', startsWith('failed to send request: '))
            .having((e) => e.cause, 'cause', isA<http.ClientException>()),
      );
    });

    test('a body that cannot be read', () async {
      final error = await failureOf(
        MockClient.streaming(
          (_, __) async => http.StreamedResponse(
            Stream<List<int>>.error(http.ClientException('reset')),
            200,
          ),
        ),
      );
      expect(
        error,
        isA<ThreepioException>()
            .having(
              (e) => e.message,
              'message',
              startsWith('failed to read response body: '),
            )
            .having((e) => e.cause, 'cause', isA<http.ClientException>()),
      );
    });

    test('headers that do not arrive in time', () async {
      final never = Completer<http.StreamedResponse>();
      final error = await failureOf(
        MockClient.streaming((_, __) => never.future),
      );
      expect(
        error,
        isA<ThreepioException>()
            .having((e) => e.message, 'message', startsWith('failed to send request: '))
            .having((e) => e.cause, 'cause', isA<TimeoutException>()),
      );
    });

    test('a body that does not end in time', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final error = await failureOf(
        MockClient.streaming(
          (_, __) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      expect(
        error,
        isA<ThreepioException>()
            .having(
              (e) => e.message,
              'message',
              startsWith('failed to read response body: '),
            )
            .having((e) => e.cause, 'cause', isA<TimeoutException>()),
      );
      expect(body.hasListener, isFalse, reason: 'the body is let go');
    });
  });

  group('cancellation', () {
    test('a cancelled context sends nothing', () async {
      final served = _serve([]);
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(httpClient: served.client),
      );
      final token = CancelToken()..cancel('stop');
      await expectLater(
        client.textSearch(
          RunContext.background(cancelToken: token),
          const DuckDuckGoTextSearchRequest(query: 'eino'),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(served.requests, isEmpty);
    });

    test('cancelling during the request abandons it', () async {
      final arrived = Completer<void>();
      final never = Completer<http.StreamedResponse>();
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(
          httpClient: MockClient.streaming((_, __) {
            arrived.complete();
            return never.future;
          }),
        ),
      );
      final token = CancelToken();
      final search = client.textSearch(
        RunContext.background(cancelToken: token),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      await arrived.future;
      token.cancel('user');
      await expectLater(
        search,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'user'),
        ),
      );
    });

    test('a body not read yet is let go when the token has fired', () async {
      var listened = false;
      final body = StreamController<List<int>>(onListen: () => listened = true);
      addTearDown(() => unawaited(body.close()));
      final exchange = GoHttpExchange(
        const Duration(seconds: 5),
        CancelToken()..cancel('late'),
      );
      expect(
        () => exchange.readBody(http.StreamedResponse(body.stream, 200)),
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'late'),
        ),
      );
      await pumpEventQueue();
      expect(listened, isTrue, reason: 'the body is drained');
      expect(body.hasListener, isFalse, reason: 'and let go');
    });

    test('cancelling during the pause between pages', () async {
      final firstServed = Completer<void>();
      var requests = 0;
      final client = DuckDuckGoSearchClient(
        DuckDuckGoConfig(
          pageDelay: const Duration(minutes: 1),
          httpClient: MockClient((_) async {
            requests++;
            if (!firstServed.isCompleted) firstServed.complete();
            return http.Response(
              _page([('https://a.example/', 'A', 'a')], next: {'s': '1'}),
              200,
            );
          }),
        ),
      );
      final token = CancelToken();
      final search = client.textSearch(
        RunContext.background(cancelToken: token),
        const DuckDuckGoTextSearchRequest(query: 'eino'),
      );
      await firstServed.future;
      await pumpEventQueue();
      token.cancel();
      await expectLater(search, throwsA(isA<CancelledException>()));
      expect(requests, 1);
    });
  });

  group('ownership', () {
    test('dispose leaves an injected client open', () async {
      final recording = _RecordingClient(_serve([]).client);
      final tool = DuckDuckGoSearchTool(
        DuckDuckGoConfig(httpClient: recording),
      )..dispose();
      expect(recording.closed, isFalse);
      expect(
        () => tool.searchResults(
          RunContext.background(),
          const DuckDuckGoTextSearchRequest(query: 'eino'),
        ),
        throwsStateError,
      );
    });

    test('a disposed tool without an injected client throws', () async {
      final tool = DuckDuckGoSearchTool()
        ..dispose()
        ..dispose();
      await expectLater(tool.run('{"query":"eino"}'), throwsStateError);
    });
  });

  group('values', () {
    test('wire values', () {
      expect([for (final r in DuckDuckGoRegion.values) r.wireValue], [
        'wt-wt',
        'us-en',
        'uk-en',
        'de-de',
        'fr-fr',
        'jp-jp',
        'cn-zh',
        'ru-ru',
      ]);
      expect(
        [for (final r in DuckDuckGoTimeRange.values) r.wireValue],
        ['d', 'w', 'm', 'y', ''],
      );
      expect(DuckDuckGoTimeRange.fromWire('m'), DuckDuckGoTimeRange.month);
      expect(DuckDuckGoTimeRange.fromWire('M'), DuckDuckGoTimeRange.any);
    });

    test('JSON of the request, result and response', () {
      const request = DuckDuckGoTextSearchRequest(
        query: 'eino',
        timeRange: DuckDuckGoTimeRange.day,
      );
      expect(request.toJson(), {'query': 'eino', 'time_range': 'd'});
      expect(DuckDuckGoTextSearchRequest.fromJson(request.toJson()), request);

      const response = DuckDuckGoTextSearchResponse(
        message: 'Found 1 results successfully.',
        results: [DuckDuckGoTextSearchResult(title: 't', url: 'u', summary: 's')],
      );
      expect(
        jsonEncode(response),
        '{"message":"Found 1 results successfully.","results":'
        '[{"title":"t","url":"u","summary":"s"}]}',
      );
      expect(
        DuckDuckGoTextSearchResponse.fromJson(
          jsonDecode(jsonEncode(response)) as Map<String, Object?>,
        ),
        response,
      );
      expect(
        DuckDuckGoTextSearchResponse.fromJson(const {
          'message': 'm',
          'results': [null],
        }).results,
        const [DuckDuckGoTextSearchResult()],
      );
      expect(
        const DuckDuckGoTextSearchResponse(message: 'none').toJson(),
        {'message': 'none'},
      );
      expect(
        () => DuckDuckGoTextSearchResult.fromJson(const {'url': 3}),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'json: cannot unmarshal number into Go struct field '
                'TextSearchResult.url of type string',
          ),
        ),
      );
      expect(
        () => DuckDuckGoTextSearchResponse.fromJson(const {
          'results': ['x'],
        }),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'json: cannot unmarshal string into Go struct field '
                'TextSearchResponse.results of type duckduckgo.TextSearchResult',
          ),
        ),
      );
    });
  });

  group('Go wire helpers', () {
    test("url.QueryEscape and url.Values.Encode", () {
      expect(goQueryEscape('a b&c=d/é~-_.*()!'), 'a+b%26c%3Dd%2F%C3%A9~-_.%2A%28%29%21');
      expect(
        goEncodeValues({
          'b': ['2', '1'],
          'B': ['x'],
          'a': [''],
        }),
        'B=x&a=&b=2&b=1',
      );
      expect(goEncodeValues({}), '');
    });

    test('sonic.MarshalString', () {
      final backslash = String.fromCharCode(0x5c);
      final controls = [0x08, 0x0c, 0x09, 0x0a, 0x0d, 0x01, 0x22]
          .map(String.fromCharCode)
          .join();
      final text = '$controls${backslash}b<&>é';
      expect(
        goSonicMarshal({
          'k': [text, 1, true, null],
        }),
        '{"k":["${backslash}u0008${backslash}u000c${backslash}t${backslash}n'
        '${backslash}r${backslash}u0001$backslash"$backslash${backslash}b'
        '<&>é",1,true,null]}',
      );
    });

    test('strings.TrimSpace', () {
      final bom = String.fromCharCode(0xFEFF);
      final nel = String.fromCharCode(0x85);
      final emSpace = String.fromCharCode(0x2003);
      expect(goTrimSpace(' \t\n\v\f\r$nel${emSpace}x y$emSpace '), 'x y');
      expect(goTrimSpace('${bom}x$bom'), '${bom}x$bom');
      expect(goTrimSpace('   '), '');
    });

    test('encoding/json field lookup ignores case, the last key wins', () {
      final kelvin = String.fromCharCode(0x212A);
      expect(goJsonField(const {'Query': 'a', 'query': 'b'}, 'query'), 'b');
      expect(goJsonField(const {'query': 'b', 'QUERY': 'c'}, 'query'), 'c');
      expect(goJsonField({'${kelvin}ey': 'k'}, 'key'), 'k');
      expect(goJsonField(const {'other': 1}, 'query'), isNull);
    });
  });
}
