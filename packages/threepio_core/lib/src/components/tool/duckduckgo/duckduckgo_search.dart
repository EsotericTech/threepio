/// A web search tool that reads DuckDuckGo's HTML result page.
///
/// Port of eino-ext `components/tool/duckduckgo/v2` (`search.go`,
/// `text_search.go`). The deprecated v1 package (`duckduckgo.NewTool`,
/// `ddgsearch`) is not ported.
library;

import 'dart:convert';
import 'dart:math';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/shared_http_client.dart';
import '../../../schema/tool_info.dart';
import '../../component_type.dart';
import '../../model/cancel_token.dart';
import '../function_tool.dart';
import '../invokable_tool.dart';
import '../search_result.dart';
import '../tool_options.dart';
import 'duckduckgo_types.dart';
import 'go_wire.dart';

/// The configuration of a [DuckDuckGoSearchTool] or a
/// [DuckDuckGoSearchClient].
///
/// Port of eino-ext `duckduckgo.Config`. Go treats the zero value of a field
/// as "use the default"; here that is `null` (and, as in Go, an empty name,
/// a zero timeout and a maximum of zero or less).
@immutable
final class DuckDuckGoConfig {
  /// A configuration; every field has a default.
  const DuckDuckGoConfig({
    this.toolName,
    this.toolDesc,
    this.timeout,
    this.httpClient,
    this.maxResults,
    this.region = DuckDuckGoRegion.wt,
    this.pageDelay = const Duration(seconds: 3),
  });

  /// The name of the tool (Go: `ToolName`). `null` or empty:
  /// `duckduckgo_text_search`.
  final String? toolName;

  /// The description of the tool (Go: `ToolDesc`). `null` or empty: the
  /// description of [DuckDuckGoSearchTool.defaultToolDesc].
  final String? toolDesc;

  /// The longest a request may take, from sending it to the end of the
  /// response body (Go: `Timeout`, the `Timeout` of the `http.Client`).
  /// `null` or zero: 30 seconds; negative: no limit.
  ///
  /// Unlike Go, the limit also applies to an injected [httpClient]: a Dart
  /// `http.Client` has no timeout of its own to defer to.
  final Duration? timeout;

  /// The client the requests are sent with (Go: `HTTPClient`); tests inject
  /// a fake.
  ///
  /// Whoever passes a client owns it and closes it. Without one, a client is
  /// created on first use and closed by `dispose`.
  final http.Client? httpClient;

  /// The most results a search returns (Go: `MaxResults`). `null`, zero or
  /// negative: 10. More than one page of results is fetched when needed.
  final int? maxResults;

  /// The region results are tailored to (Go: `Region`, default `RegionWT`;
  /// an empty code also means [DuckDuckGoRegion.wt], as in Go).
  final DuckDuckGoRegion region;

  /// The pause between two result pages of one search. Go waits three
  /// seconds, fixed ("request too fast may cause 202"); threepio makes the
  /// pause configurable (tests use milliseconds) and cancellable.
  final Duration pageDelay;

  @override
  String toString() => 'DuckDuckGoConfig(toolName: $toolName, '
      'maxResults: $maxResults, region: ${region.wireValue})';
}

/// A DuckDuckGo text search.
///
/// Port of eino-ext `duckduckgo.Search` (the interface `NewSearch`
/// returns). [DuckDuckGoSearchClient] implements it.
// ignore: one_member_abstracts
abstract interface class DuckDuckGoSearch {
  /// Searches the web for `request.query`.
  ///
  /// Port of `Search.TextSearch`.
  Future<DuckDuckGoTextSearchResponse> textSearch(
    RunContext ctx,
    DuckDuckGoTextSearchRequest request,
  );
}

/// Searches DuckDuckGo by posting to its HTML endpoint and reading the result
/// page.
///
/// Port of eino-ext `duckduckgo` `client` and `NewSearch`.
///
/// **Not for production.** As the Go package's README says, DuckDuckGo has
/// no official API for this: the tool reads the HTML page meant for
/// browsers, whose markup and limits may change at any time, so the search
/// can stop working without notice.
///
/// ```dart
/// final search = DuckDuckGoSearchClient(const DuckDuckGoConfig());
/// final response = await search.textSearch(
///   RunContext.background(),
///   const DuckDuckGoTextSearchRequest(query: 'eino'),
/// );
/// search.dispose();
/// ```
final class DuckDuckGoSearchClient implements DuckDuckGoSearch {
  /// A client configured by [config] (Go: `NewSearch`, which does no I/O).
  DuckDuckGoSearchClient([this.config = const DuckDuckGoConfig()])
      : region = config.region.wireValue.isEmpty
            ? DuckDuckGoRegion.wt
            : config.region,
        maxResults = _maxResultsOf(config.maxResults),
        timeout = goClientTimeout(config.timeout, defaultTimeout),
        _http = SharedHttpClient(
          config.httpClient,
          owner: 'DuckDuckGoSearchClient',
        );

  /// Go's default `Timeout`: 30 seconds.
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// Go's default `MaxResults`: 10.
  static const int defaultMaxResults = 10;

  /// The address the search form is posted to (Go: `searchHTMLURL`).
  static final Uri searchHtmlUrl = Uri.parse('https://html.duckduckgo.com/html/');

  /// The configuration as given.
  final DuckDuckGoConfig config;

  /// The region in effect.
  final DuckDuckGoRegion region;

  /// The maximum number of results in effect.
  final int maxResults;

  /// The request timeout in effect; 24 days stands for Go's "no limit".
  final Duration timeout;

  final SharedHttpClient _http;

  final Random _random = Random();

  /// The user agents a search picks one from at random.
  ///
  /// Go uses `uarand.GetRandom()`, a random pick among the 1280 user agents
  /// of `github.com/corpix/uarand` v0.2.0, crawlers and feature phones
  /// included. threepio keeps desktop browsers only, copied verbatim from
  /// that list.
  @internal
  static const List<String> userAgents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.75 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.64 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.3 Safari/605.1.15',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36',
    'Mozilla/5.0 (X11; Linux x86_64; rv:91.0) Gecko/20100101 Firefox/91.0',
  ];

  static int _maxResultsOf(int? configured) =>
      configured == null || configured <= 0 ? defaultMaxResults : configured;

  /// Closes the HTTP client this search created for itself; a client passed
  /// as `DuckDuckGoConfig.httpClient` is left open. Using the search
  /// afterwards throws a [StateError].
  void dispose() => _http.close();

  /// Searches the web for `request.query`.
  ///
  /// Port of `client.TextSearch`. Posts the search form, reads the hits of
  /// the result page and, while there are fewer than [maxResults] hits and a
  /// next page, posts the form of the next page after
  /// `DuckDuckGoConfig.pageDelay`. Stops at the first page without hits.
  /// The answer says `Found N results successfully.` with the hits, or `No
  /// good results were found.` without any.
  ///
  /// Throws a [ThreepioFormatException] saying `search query is required`
  /// for an empty query, a [ThreepioException] with Go's text (`failed to
  /// send request: …`, `unexpected status code: 202`, `failed to read
  /// response body: …`) when a page cannot be fetched, and a
  /// [CancelledException] as soon as `ctx.cancelToken` fires.
  @override
  Future<DuckDuckGoTextSearchResponse> textSearch(
    RunContext ctx,
    DuckDuckGoTextSearchRequest request,
  ) async {
    if (request.query.isEmpty) {
      throw const ThreepioFormatException('search query is required');
    }
    // Outside any try: using a disposed client is a programming error.
    final client = _http.client;
    final results = <DuckDuckGoTextSearchResult>[];
    final headers = buildTextHtmlRequestHeaders(_random);
    var body = buildTextHtmlRequestBody(request, region);

    // Every round adds at least one hit or ends the loop, so it runs at most
    // [maxResults] times.
    while (true) {
      final page = await _doTextHtmlSearch(ctx, client, headers, body);
      if (page.results.isEmpty) break;

      results.addAll(page.results);
      if (results.length >= maxResults) {
        results.length = maxResults;
        break;
      }

      final next = page.nextBody;
      if (next == null || next.isEmpty) break;
      body = next;

      await goPause(config.pageDelay, ctx.cancelToken);
    }

    if (results.isEmpty) {
      return const DuckDuckGoTextSearchResponse(
        message: 'No good results were found.',
      );
    }
    return DuckDuckGoTextSearchResponse(
      message: 'Found ${results.length} results successfully.',
      results: List.unmodifiable(results),
    );
  }

  Future<
      ({
        List<DuckDuckGoTextSearchResult> results,
        Map<String, List<String>>? nextBody,
      })> _doTextHtmlSearch(
    RunContext ctx,
    http.Client client,
    Map<String, String> headers,
    Map<String, List<String>> body,
  ) async {
    final request = http.Request('POST', searchHtmlUrl)
      ..headers.addAll(headers)
      // bodyBytes, not body: setting body would add "; charset=utf-8" to the
      // Content-Type Go sends as it is.
      ..bodyBytes = utf8.encode(goEncodeValues(body));
    final exchange = GoHttpExchange(timeout, ctx.cancelToken);

    final http.StreamedResponse response;
    try {
      response = await exchange.send(client, request);
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw ThreepioException('failed to send request: $error', cause: error);
    }

    if (response.statusCode != 200) {
      GoHttpExchange.discard(response);
      throw ThreepioException('unexpected status code: ${response.statusCode}');
    }

    final List<int> bytes;
    try {
      bytes = await exchange.readBody(response);
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw ThreepioException(
        'failed to read response body: $error',
        cause: error,
      );
    }

    return parseTextHtmlSearchResponse(
      utf8.decode(bytes, allowMalformed: true),
    );
  }

  /// The headers of every request of one search (Go:
  /// `buildTextHTMLRequestHeader`); the user agent is picked at random from
  /// [userAgents] with [random] (Go: `uarand.GetRandom()`).
  @internal
  static Map<String, String> buildTextHtmlRequestHeaders(Random random) => {
        'Referer': 'https://html.duckduckgo.com/',
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-User': '?1',
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent':
            userAgents[random.nextInt(userAgents.length)],
      };

  /// The form of the first page (Go: `TextSearchRequest.
  /// buildTextHTMLRequestBody`): `q`, `b` (empty), `kl` (the region, empty
  /// for [DuckDuckGoRegion.wt]) and `df` (the time range, empty for any).
  @internal
  static Map<String, List<String>> buildTextHtmlRequestBody(
    DuckDuckGoTextSearchRequest request,
    DuckDuckGoRegion region,
  ) =>
      {
        'q': [request.query],
        'b': [''],
        'kl': [if (region == DuckDuckGoRegion.wt) '' else region.wireValue],
        'df': [request.timeRange.wireValue],
      };

  /// The hits of one result page and the form of the next page.
  ///
  /// Port of `parseTextHTMLSearchResponse`, with `package:html` in place of
  /// goquery and the same selectors: a hit is a `div.web-result` inside
  /// `div#links` with a title link (`h2.result__title > a`) that has an
  /// `href` and a snippet (`a.result__snippet`); a link seen before on the
  /// page, a Google fallback link and an ad are skipped. Title and snippet
  /// are their text with Go's `strings.TrimSpace`. When the page has a
  /// `div.nav-link`, the next form is the hidden inputs (with a name and a
  /// value) of the last `form`; otherwise there is no next page (`null`).
  /// (Go also collects the rows of the last table, then never uses them;
  /// that step is left out.)
  ///
  /// `nextBody` holds the fields of the next page's form, as Go's
  /// `url.Values`.
  @internal
  static ({
    List<DuckDuckGoTextSearchResult> results,
    Map<String, List<String>>? nextBody,
  }) parseTextHtmlSearchResponse(String body) {
    final dom.Document document;
    try {
      document = html_parser.parse(body);
      // package:html recovers from any markup; this only guards against a
      // failure of the parser itself.
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      throw ThreepioException('failed to parse response: $error', cause: error);
    }

    final seen = <String>{};
    final results = <DuckDuckGoTextSearchResult>[];
    for (final hit in document.querySelectorAll('div#links div.web-result')) {
      final title = hit.querySelector('h2.result__title > a');
      if (title == null) continue;

      final href = title.attributes['href'] ?? '';
      if (href.isEmpty) continue;
      if (seen.contains(href) ||
          href.startsWith('http://www.google.com/search?q=') ||
          href.startsWith('https://duckduckgo.com/y.js?ad_domain')) {
        continue;
      }

      final summary = hit.querySelector('a.result__snippet');
      if (summary == null) continue;

      seen.add(href);
      results.add(
        DuckDuckGoTextSearchResult(
          title: goTrimSpace(title.text),
          url: href,
          summary: goTrimSpace(summary.text),
        ),
      );
    }

    if (document.querySelectorAll('div.nav-link').isEmpty) {
      return (results: results, nextBody: null);
    }

    final nextBody = <String, List<String>>{};
    final forms = document.querySelectorAll('form');
    if (forms.isNotEmpty) {
      for (final input in forms.last.querySelectorAll('input[type=hidden]')) {
        final name = input.attributes['name'];
        final value = input.attributes['value'];
        if (name != null && value != null) nextBody[name] = [value];
      }
    }
    return (results: results, nextBody: nextBody);
  }
}

/// A tool that searches the web with DuckDuckGo.
///
/// Port of eino-ext `duckduckgo.NewTextSearchTool` (an `utils.NewTool` over
/// `client.TextSearch`). The model passes `query` and an optional
/// `time_range` (`d`, `w`, `m`, `y` or empty); the tool answers with Go's
/// JSON byte for byte, for example
/// `{"message":"Found 2 results successfully.","results":[{"title":…,"url":…,"summary":…},…]}`,
/// or `{"message":"No good results were found."}`. Dart code calls [search]
/// for Go's typed answer or [searchResults] for the hits as [SearchResult]s.
///
/// **Not for production.** As the Go package's README says, DuckDuckGo has
/// no official API for this: the tool reads the HTML page meant for
/// browsers, whose markup and limits may change at any time, so the search
/// can stop working without notice.
///
/// ```dart
/// final tool = DuckDuckGoSearchTool(
///   const DuckDuckGoConfig(maxResults: 5, region: DuckDuckGoRegion.us),
/// );
/// final hits = await tool.searchResults(
///   RunContext.background(),
///   const DuckDuckGoTextSearchRequest(query: 'eino'),
/// );
/// tool.dispose();
/// ```
final class DuckDuckGoSearchTool extends InvokableTool
    implements TypedComponent {
  /// A tool configured by [config]. Go's `NewTextSearchTool` does no I/O and
  /// cannot fail with a valid configuration, so this is a constructor.
  DuckDuckGoSearchTool([DuckDuckGoConfig config = const DuckDuckGoConfig()])
      : this._(DuckDuckGoSearchClient(config));

  DuckDuckGoSearchTool._(DuckDuckGoSearchClient client)
      : client = client,
        _tool = FunctionTool<DuckDuckGoTextSearchRequest,
            DuckDuckGoTextSearchResponse>.fromInfo(
          textSearchToolInfo(
            _orDefault(client.config.toolName, defaultToolName),
            _orDefault(client.config.toolDesc, defaultToolDesc),
          ),
          fromJson: DuckDuckGoTextSearchRequest.fromJson,
          invoke: (ctx, request, _) => client.textSearch(ctx, request),
          // A String goes to the model as it is: sonic's text, not
          // jsonEncode's (they differ on backspace and form feed).
          toJson: (response) => goSonicMarshal(response.toJson()),
        );

  /// The default name (Go: `defaultTextSearchToolName`).
  static const String defaultToolName = 'duckduckgo_text_search';

  /// The default description (Go: `defaultTextSearchToolDesc`, with its
  /// space before the line break).
  static const String defaultToolDesc =
      'This is a duckduckgo plain text information search tool. \n'
      'It can be useful to help you get information within a certain time '
      'range.';

  /// The client the tool searches with; it was created for the tool and is
  /// closed by [dispose].
  final DuckDuckGoSearchClient client;

  final FunctionTool<DuckDuckGoTextSearchRequest, DuckDuckGoTextSearchResponse>
      _tool;

  static String _orDefault(String? value, String fallback) =>
      value == null || value.isEmpty ? fallback : value;

  /// The tool info of the search tool named [name] and described by [desc]
  /// (Go: `getTextSearchSchema`): the JSON Schema document Go builds, with
  /// its keys in the order Go writes them.
  static ToolInfo textSearchToolInfo(String name, String desc) =>
      ToolInfo.fromJsonSchemaMap(
        name: name,
        desc: desc,
        schema: {
          'properties': {
            'query': {
              'description': "The user's search query. The query is required.",
              'type': 'string',
            },
            'time_range': {
              'oneOf': [
                _timeRangeOption('d', 'Search information from the past day'),
                _timeRangeOption('w', 'Search information from the past week'),
                _timeRangeOption(
                  'm',
                  'Search information from the past month',
                ),
                _timeRangeOption('y', 'Search information from the past year'),
                _timeRangeOption('', 'Search information at any time'),
              ],
              'description': 'The time range of search results',
              'default': '',
              'type': 'string',
            },
          },
          'required': ['query'],
          'type': 'object',
        },
      );

  static Map<String, Object?> _timeRangeOption(String value, String desc) => {
        'enum': [value],
        'description': desc,
        'type': 'string',
      };

  /// The name of the tool.
  String get name => _tool.name;

  /// The tool's name in UpperCamelCase, `DuckduckgoTextSearch` by default
  /// (Go: the `GetType` of an `utils.NewTool` tool).
  @override
  String get componentTypeName => _tool.componentTypeName;

  @override
  Future<ToolInfo> info() => _tool.info();

  /// Runs the search the model asked for and answers with Go's JSON.
  ///
  /// Throws a [ThreepioFormatException] for arguments that are not a JSON
  /// object with string values, and what
  /// [DuckDuckGoSearchClient.textSearch] throws.
  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _tool.invokableRun(ctx, argumentsJson, options: options);

  /// The same as [invokableRun] with a context that is never cancelled.
  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  /// Runs the search [request] describes and returns Go's typed answer, the
  /// one [invokableRun] encodes for the model (Go: `client.TextSearch`).
  /// Throws what [DuckDuckGoSearchClient.textSearch] throws.
  Future<DuckDuckGoTextSearchResponse> search(
    RunContext ctx,
    DuckDuckGoTextSearchRequest request,
  ) =>
      client.textSearch(ctx, request);

  /// The hits of the search [request] describes, in the shape every search
  /// tool shares (DuckDuckGo's summary is the snippet); empty when
  /// DuckDuckGo found nothing. threepio-only; throws what [search] throws.
  Future<List<SearchResult>> searchResults(
    RunContext ctx,
    DuckDuckGoTextSearchRequest request,
  ) async {
    final response = await search(ctx, request);
    return List.unmodifiable(response.toSearchResults());
  }

  /// Closes the HTTP client the tool created; a client passed as
  /// `DuckDuckGoConfig.httpClient` is left open. Using the tool afterwards
  /// throws a [StateError].
  void dispose() => client.dispose();
}
