/// The Wikipedia search tool.
///
/// Port of eino-ext `components/tool/wikipedia`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../internal/naming.dart';
import '../../../internal/shared_http_client.dart';
import '../../../schema/tool_info.dart';
import '../../component_type.dart';
import '../function_tool.dart';
import '../http_request/web_tool_http.dart';
import '../invokable_tool.dart';
import '../search_result.dart';
import '../tool_options.dart';
import 'wikipedia_client.dart';
import 'wikipedia_errors.dart';

/// The configuration of [WikipediaTool].
///
/// Port of eino-ext `wikipedia.Config`. Every field is optional; a `null`
/// (or empty, or not positive) value takes Go's default.
@immutable
final class WikipediaConfig {
  /// A configuration; every field is optional.
  const WikipediaConfig({
    this.baseUrl,
    this.userAgent,
    this.docMaxChars,
    this.timeout,
    this.topK,
    this.maxRedirect,
    this.language,
    this.toolName,
    this.toolDesc,
    this.httpClient,
  });

  /// The address of the MediaWiki API, `https://<language>.wikipedia.org/w/api.php`.
  /// Default: that address for [language].
  final String? baseUrl;

  /// The `User-Agent` of the requests. Default: [defaultUserAgent]. Set one
  /// that names your project, as the Wikimedia User-Agent policy asks
  /// (https://foundation.wikimedia.org/wiki/Policy:Wikimedia_Foundation_User-Agent_Policy).
  final String? userAgent;

  /// The longest extract of a page the tool reports, in UTF-8 bytes as Go
  /// counts it (a character cut in two becomes U+FFFD). Default:
  /// [defaultDocMaxChars] (Go's comment says "15s"; its code says 2000).
  final int? docMaxChars;

  /// How long one request to the API may take, redirects and body included
  /// (Go: `http.Client.Timeout`). Default: [defaultTimeout].
  final Duration? timeout;

  /// How many hits a search returns. Default: [defaultTopK].
  final int? topK;

  /// The redirect at which the tool gives up: with 3, two redirects are
  /// followed and the third fails with `too many redirects` (Go:
  /// `len(via) >= MaxRedirect`). Default: [defaultMaxRedirect].
  final int? maxRedirect;

  /// The language of the wiki, used for the default [baseUrl] and in the
  /// addresses of the pages. Default: [defaultLanguage].
  final String? language;

  /// The name of the tool. Default: `wikipedia_search`.
  final String? toolName;

  /// What the tool tells the model. Default: `this tool provides quick and
  /// efficient access to information from the Wikipedia`.
  final String? toolDesc;

  /// The client that sends the requests. The caller owns it and closes it.
  /// `null`: the tool creates one on first use and closes it in
  /// `WikipediaTool.dispose` (threepio-only: Go always uses a client of its
  /// own; [timeout] and [maxRedirect] apply to either).
  final http.Client? httpClient;

  /// Go's default user agent.
  static const defaultUserAgent = 'eino (https://github.com/cloudwego/eino)';

  /// Go's default for [docMaxChars].
  static const defaultDocMaxChars = 2000;

  /// Go's default for [timeout].
  static const defaultTimeout = Duration(seconds: 15);

  /// Go's default for [topK].
  static const defaultTopK = 3;

  /// Go's default for [maxRedirect].
  static const defaultMaxRedirect = 3;

  /// Go's default for [language].
  static const defaultLanguage = 'en';
}

/// The arguments of the Wikipedia search tool.
///
/// Port of eino-ext `wikipedia.SearchRequest`.
@immutable
final class WikipediaSearchRequest {
  /// A search for [query].
  const WikipediaSearchRequest({required this.query});

  /// Reads the arguments the model wrote; a missing `query` is empty, as in
  /// Go.
  factory WikipediaSearchRequest.fromJson(Map<String, Object?> json) =>
      WikipediaSearchRequest(
        query: goJsonString(json['query'], 'SearchRequest', 'query'),
      );

  /// The query to search the web for.
  final String query;

  /// The arguments as JSON (Go's field names).
  Map<String, Object?> toJson() => {'query': query};

  @override
  bool operator ==(Object other) =>
      other is WikipediaSearchRequest && other.query == query;

  @override
  int get hashCode => query.hashCode;

  @override
  String toString() => 'WikipediaSearchRequest(query: $query)';
}

/// One page the Wikipedia search tool found.
///
/// Port of eino-ext `wikipedia.Result`.
@immutable
final class WikipediaResult {
  /// The page [title] at [url].
  const WikipediaResult({
    required this.title,
    required this.url,
    this.extract = '',
    this.snippet = '',
  });

  /// The title of the page.
  final String title;

  /// The address of the page.
  final String url;

  /// The beginning of the plain text of the page, at most
  /// [WikipediaConfig.docMaxChars] bytes.
  final String extract;

  /// The text around the match, with the basic HTML removed.
  final String snippet;

  /// The result as Go encodes it, fields in Go's order.
  Map<String, Object?> toJson() => {
        'title': title,
        'url': url,
        'extract': extract,
        'snippet': snippet,
      };

  /// The page in the shape every search tool shares; a non-empty [extract]
  /// is `extra['extract']`.
  SearchResult toSearchResult() => SearchResult(
        title: title,
        url: url,
        snippet: snippet,
        extra: extract.isEmpty ? const {} : {'extract': extract},
      );

  @override
  bool operator ==(Object other) =>
      other is WikipediaResult &&
      other.title == title &&
      other.url == url &&
      other.extract == extract &&
      other.snippet == snippet;

  @override
  int get hashCode => Object.hash(title, url, extract, snippet);

  @override
  String toString() => 'WikipediaResult(title: $title, url: $url)';
}

/// What the Wikipedia search tool reports to the model.
///
/// Port of eino-ext `wikipedia.SearchResponse`.
@immutable
final class WikipediaSearchResponse {
  /// A response with [results].
  const WikipediaSearchResponse({this.results = const []});

  /// The pages found, in the order of the search.
  final List<WikipediaResult> results;

  /// The response as Go encodes it. The tool hands the model this JSON.
  Map<String, Object?> toJson() => {
        'results': [for (final result in results) result.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is WikipediaSearchResponse &&
      const ListEquality<WikipediaResult>().equals(other.results, results);

  @override
  int get hashCode => const ListEquality<WikipediaResult>().hash(results);

  @override
  String toString() => 'WikipediaSearchResponse(${results.length} results)';
}

/// The Wikipedia search tool.
///
/// Port of eino-ext `wikipedia.NewTool`: a `utils.InferTool` that searches
/// a Wikipedia through the MediaWiki API (`list=search`) and then gets each
/// page found (`prop=extracts|revisions`), one after the other. The model
/// gets [WikipediaSearchResponse] as JSON, byte for byte what Go writes:
///
/// ```json
/// {"results":[{"title":"…","url":"…","extract":"…","snippet":"…"}]}
/// ```
///
/// Dart callers can call [search] for the typed response, or
/// [searchResults] for the pages as the [SearchResult]s every search tool
/// shares.
///
/// Errors (thrown as they are; Go's `InferTool` adds a
/// `[LocalFunc] failed to invoke tool` wrapper that threepio's
/// [FunctionTool] does not): [WikipediaException] `invalid parameters` for a
/// blank query, `page not found` when the search finds nothing or a page is
/// missing; [WikipediaApiException] when the API answers with an error; a
/// `ThreepioException` with Go's text when a request fails
/// (`request failed: Get "…": …`, `unexpected status code: N`, …); a
/// `CancelledException` when `ctx.cancelToken` is cancelled.
///
/// Call [dispose] when done with a tool that created its own client.
final class WikipediaTool extends InvokableTool implements TypedComponent {
  /// A search tool configured by [config].
  WikipediaTool([this.config = const WikipediaConfig()])
      : name = _orDefault(config.toolName, 'wikipedia_search'),
        description = _orDefault(
          config.toolDesc,
          'this tool provides quick and efficient access to information from '
          'the Wikipedia',
        ),
        _docMaxChars = _positiveOr(
          config.docMaxChars,
          WikipediaConfig.defaultDocMaxChars,
        ),
        _http = SharedHttpClient(config.httpClient, owner: 'WikipediaTool');

  /// The configuration the tool was made with.
  final WikipediaConfig config;

  /// The name of the tool: [WikipediaConfig.toolName] or `wikipedia_search`.
  final String name;

  /// What the tool tells the model.
  final String description;

  final int _docMaxChars;
  final SharedHttpClient _http;

  late final WikipediaClient _client = () {
    final language = _orDefault(config.language, WikipediaConfig.defaultLanguage);
    final maxRedirect =
        _positiveOr(config.maxRedirect, WikipediaConfig.defaultMaxRedirect);
    return WikipediaClient(
      httpClient: () => _http.client,
      baseUrl: _orDefault(
        config.baseUrl,
        'https://$language.wikipedia.org/w/api.php',
      ),
      userAgent: _orDefault(config.userAgent, WikipediaConfig.defaultUserAgent),
      language: language,
      topK: _positiveOr(config.topK, WikipediaConfig.defaultTopK),
      timeout: config.timeout == null || config.timeout! <= Duration.zero
          ? WikipediaConfig.defaultTimeout
          : config.timeout,
      checkRedirect: (next, via) => via.length >= maxRedirect
          ? WikipediaException(WikipediaErrorKind.tooManyRedirects)
          : null,
    );
  }();

  late final InvokableTool _tool =
      FunctionTool<WikipediaSearchRequest, WikipediaSearchResponse>(
    name: name,
    description: description,
    params: ParamsOneOf.jsonSchema(
      JSONSchema(
        properties: {
          'query': JSONSchemaProperty.string(
            description: 'The query to search the web for',
          ),
        },
        required: const ['query'],
      ),
    ),
    fromJson: WikipediaSearchRequest.fromJson,
    invoke: (ctx, request, _) => search(ctx, request),
    toJson: (response) => sonicMarshal(response.toJson()),
  );

  @override
  String get componentTypeName => snakeToUpperCamel(name);

  @override
  Future<ToolInfo> info() => _tool.info();

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _tool.invokableRun(ctx, argumentsJson, options: options);

  /// The same as [invokableRun] with a context that is never cancelled, for
  /// code that still calls the tool the old way.
  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  /// Searches the wiki for `request.query` and returns the pages found.
  ///
  /// Port of eino-ext `wikipedia.Search`. One request searches, one more per
  /// hit gets the page; the first failure ends the search.
  Future<WikipediaSearchResponse> search(
    RunContext ctx,
    WikipediaSearchRequest request,
  ) async {
    final hits = await _client.search(ctx, request.query);
    if (hits.isEmpty) {
      throw WikipediaException(WikipediaErrorKind.pageNotFound);
    }
    final results = <WikipediaResult>[];
    for (final hit in hits) {
      final page = await _client.getPage(ctx, hit.title);
      results.add(
        WikipediaResult(
          title: page.title,
          url: page.url,
          extract: _truncateUtf8(page.content, _docMaxChars),
          snippet: hit.snippet,
        ),
      );
    }
    return WikipediaSearchResponse(results: List.unmodifiable(results));
  }

  /// Searches the wiki for `request.query` and returns the pages as
  /// [SearchResult]s: the page's title, address and snippet, and its extract
  /// as `extra['extract']`. Throws like [search].
  ///
  /// threepio-only: the typed counterpart of what the model gets.
  Future<List<SearchResult>> searchResults(
    RunContext ctx,
    WikipediaSearchRequest request,
  ) async {
    final response = await search(ctx, request);
    return List.unmodifiable([
      for (final result in response.results) result.toSearchResult(),
    ]);
  }

  /// Closes the client the tool created, if it created one; an injected
  /// client is left open. The tool must not be called afterwards. Safe to
  /// call repeatedly.
  void dispose() => _http.close();
}

String _orDefault(String? value, String fallback) =>
    value == null || value.isEmpty ? fallback : value;

int _positiveOr(int? value, int fallback) =>
    value == null || value <= 0 ? fallback : value;

/// Go's `content[:max]` on a string: the first [max] bytes of the UTF-8
/// form; a character cut in two becomes U+FFFD.
String _truncateUtf8(String text, int max) {
  // Every UTF-16 code unit takes at most three bytes.
  if (text.length * 3 <= max) return text;
  final bytes = utf8.encode(text);
  if (bytes.length <= max) return text;
  return utf8.decode(bytes.sublist(0, max), allowMalformed: true);
}
