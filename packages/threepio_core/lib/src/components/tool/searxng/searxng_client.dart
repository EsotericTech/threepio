/// A web search tool on a SearXNG instance's JSON API.
///
/// Port of eino-ext `components/tool/searxng` (`NewClient`, `Search`,
/// `BuildSearchInvokeTool`).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/shared_http_client.dart';
import '../../../schema/tool_info.dart';
import '../../component_type.dart';
import '../../model/cancel_token.dart';
import '../duckduckgo/go_wire.dart';
import '../function_tool.dart';
import '../invokable_tool.dart';
import '../search_result.dart';
import '../tool_options.dart';
import 'searxng_types.dart';

/// The configuration of a [SearxngClient] or a [SearxngSearchTool].
///
/// Port of eino-ext `searxng.ClientConfig`. Go treats the zero value of a
/// field as "use the default"; here that is `null` (and, as in Go, a zero
/// timeout or a zero retry count). Go's `ProxyURL` is not ported: Go never
/// reads it.
@immutable
final class SearxngClientConfig {
  /// The configuration of a client of the SearXNG instance at [baseUrl].
  const SearxngClientConfig({
    required this.baseUrl,
    this.headers,
    this.httpClient,
    this.timeout,
    this.maxRetries,
    this.requestConfig,
    this.retryDelay = const Duration(seconds: 1),
  });

  /// The search endpoint of the instance (Go: `BaseUrl`), for example
  /// `https://searx.example.org/search`. The query is appended after a `?`.
  final String baseUrl;

  /// Headers sent with every request (Go: `Headers`), `User-Agent` for
  /// example. Without a `User-Agent` (in any case) the client sends a
  /// desktop Chrome one ([SearxngClient.defaultUserAgent]).
  final Map<String, String>? headers;

  /// The client the requests are sent with (Go: `HttpClient`); tests inject
  /// a fake.
  ///
  /// Whoever passes a client owns it and closes it. Without one, a client is
  /// created on first use and closed by `dispose`.
  final http.Client? httpClient;

  /// The longest one attempt may take, from sending the request to the end
  /// of the response body (Go: `Timeout`). `null` or zero: 30 seconds;
  /// negative: no limit.
  ///
  /// Unlike Go, the limit also applies to an injected [httpClient]: a Dart
  /// `http.Client` has no timeout of its own to defer to.
  final Duration? timeout;

  /// How many times a failed request is tried again (Go: `MaxRetries`):
  /// after a network error or a timeout, a `429 Too Many Requests`, or any
  /// other status but `200`. `null` or zero: 3. A negative count throws an
  /// [ArgumentError] (Go would crash on its first search).
  final int? maxRetries;

  /// The options added to every search (Go: `RequestConfig`); `null` adds
  /// none.
  final SearxngSearchRequestConfig? requestConfig;

  /// The pause before trying again after a network error or a `429`. Go
  /// waits one second, fixed; threepio makes the pause configurable (tests
  /// use milliseconds) and cancellable.
  final Duration retryDelay;

  @override
  String toString() => 'SearxngClientConfig(baseUrl: $baseUrl, '
      'maxRetries: $maxRetries, requestConfig: $requestConfig)';
}

/// A client of a SearXNG instance's JSON API.
///
/// Port of eino-ext `searxng.SearxngClient` and `NewClient` (which does no
/// I/O, so this is a constructor).
///
/// ```dart
/// final client = SearxngClient(
///   const SearxngClientConfig(
///     baseUrl: 'https://searx.example.org/search',
///     requestConfig: SearxngSearchRequestConfig(
///       language: SearxngLanguage.en,
///       engines: [SearxngEngine.google, SearxngEngine.bing],
///     ),
///   ),
/// );
/// final response = await client.search(
///   RunContext.background(),
///   const SearxngSearchRequest(query: 'eino'),
/// );
/// client.dispose();
/// ```
final class SearxngClient {
  /// A client configured by [config].
  ///
  /// Throws an [ArgumentError] when `config.maxRetries` is negative.
  SearxngClient(this.config)
      : timeout = goClientTimeout(config.timeout, defaultTimeout),
        maxRetries = _maxRetriesOf(config.maxRetries),
        headers = Map.unmodifiable(config.headers ?? const <String, String>{}),
        _http = SharedHttpClient(config.httpClient, owner: 'SearxngClient');

  /// Go's default `Timeout`: 30 seconds.
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// Go's default `MaxRetries`: 3.
  static const int defaultMaxRetries = 3;

  /// The `User-Agent` sent when [headers] has none (Go's default).
  static const String defaultUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36';

  /// The configuration as given.
  final SearxngClientConfig config;

  /// The timeout of one attempt in effect; 24 days stands for Go's "no
  /// limit".
  final Duration timeout;

  /// The number of retries in effect.
  final int maxRetries;

  /// The headers in effect (Go fills in an empty map).
  final Map<String, String> headers;

  final SharedHttpClient _http;

  static int _maxRetriesOf(int? configured) {
    if (configured == null || configured == 0) return defaultMaxRetries;
    if (configured < 0) {
      throw ArgumentError.value(
        configured,
        'maxRetries',
        'must not be negative',
      );
    }
    return configured;
  }

  /// Closes the HTTP client this client created for itself; a client passed
  /// as `SearxngClientConfig.httpClient` is left open. Using the client
  /// afterwards throws a [StateError].
  void dispose() => _http.close();

  /// Searches the instance for `request.query`.
  ///
  /// Port of `SearxngClient.Search`. Sends `GET <baseUrl>?<query>` with the
  /// parameters `q`, `pageno` (when set), `format=json` and those of
  /// `config.requestConfig`, encoded as Go's `url.Values.Encode` does (keys
  /// sorted), and tries again as `config.maxRetries` allows.
  ///
  /// Throws, with Go's texts:
  /// * a [ThreepioFormatException] saying `query is required` or `pageno
  ///   must be greater than 0` for an invalid request;
  /// * a [ThreepioException] saying `failed to create request: …` for a base
  ///   URL that does not parse, `failed to send request after retries: …`
  ///   when the last attempt fails to get a response, `rate limit reached`
  ///   when the last attempt gets a `429`, `failed to read response body:
  ///   …`, `failed to parse search results: …` for a body that is not
  ///   SearXNG's JSON (also the empty body of an error status after the
  ///   last attempt), and `no search results found`;
  /// * a [CancelledException] as soon as `ctx.cancelToken` fires.
  Future<SearxngSearchResponse> search(
    RunContext ctx,
    SearxngSearchRequest request,
  ) async {
    final response = await _searchResponse(ctx, request);
    if (response.results.isEmpty) {
      throw const ThreepioException('no search results found');
    }
    return response;
  }

  /// The parsed answer, also when it has no results.
  Future<SearxngSearchResponse> _searchResponse(
    RunContext ctx,
    SearxngSearchRequest request,
  ) async {
    _validate(request);
    // Outside any try: using a disposed client is a programming error.
    final client = _http.client;

    final query = goEncodeValues(buildQuery(request, config.requestConfig));
    final Uri url;
    try {
      url = Uri.parse('${config.baseUrl}?$query');
    } on FormatException catch (error) {
      throw ThreepioException(
        'failed to create request: ${error.message}',
        cause: error,
      );
    }

    final requestHeaders = <String, String>{...headers};
    final hasUserAgent = requestHeaders.keys
        .any((name) => name.toLowerCase() == 'user-agent');
    if (!hasUserAgent) requestHeaders['User-Agent'] = defaultUserAgent;

    return _sendRequestWithRetry(ctx, client, url, requestHeaders);
  }

  static void _validate(SearxngSearchRequest request) {
    if (request.query.isEmpty) {
      throw const ThreepioFormatException('query is required');
    }
    final pageNo = request.pageNo;
    if (pageNo != null && pageNo <= 0) {
      throw const ThreepioFormatException('pageno must be greater than 0');
    }
  }

  /// The query parameters of [request] (Go: `SearchRequest.build`): `q`,
  /// `pageno` when set, `format=json`, then the options of [config] that
  /// are set, the engines joined by commas.
  @internal
  static Map<String, List<String>> buildQuery(
    SearxngSearchRequest request,
    SearxngSearchRequestConfig? config,
  ) {
    final timeRange = config?.timeRange;
    final language = config?.language;
    final safeSearch = config?.safeSearch ?? SearxngSafeSearch.none;
    final engines = config?.engines ?? const <SearxngEngine>[];
    final pageNo = request.pageNo;
    return {
      'q': [request.query],
      if (pageNo != null) 'pageno': ['$pageNo'],
      'format': ['json'],
      if (timeRange != null) 'time_range': [timeRange.wireValue],
      if (language != null) 'language': [language.wireValue],
      if (safeSearch != SearxngSafeSearch.none)
        'safesearch': ['${safeSearch.wireValue}'],
      if (engines.isNotEmpty)
        'engines': [engines.map((engine) => engine.wireValue).join(',')],
    };
  }

  /// Port of `sendRequestWithRetry`.
  ///
  /// As in Go, an attempt that gets neither `200` nor `429` is tried again
  /// at once, and when it was the last one, its body is parsed anyway.
  Future<SearxngSearchResponse> _sendRequestWithRetry(
    RunContext ctx,
    http.Client client,
    Uri url,
    Map<String, String> requestHeaders,
  ) async {
    final cancelToken = ctx.cancelToken;
    http.StreamedResponse? response;
    GoHttpExchange? exchange;

    // At most maxRetries + 1 attempts.
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      cancelToken.throwIfCancelled();

      exchange = GoHttpExchange(timeout, cancelToken);
      try {
        response = await exchange.send(client, _request(url, requestHeaders));
      } on CancelledException {
        rethrow;
      } on Exception catch (error) {
        if (isInterrupt(error)) rethrow;
        if (attempt == maxRetries) {
          throw ThreepioException(
            'failed to send request after retries: $error',
            cause: error,
          );
        }
        await goPause(config.retryDelay, cancelToken);
        continue;
      }

      if (response.statusCode == 200) break;

      if (response.statusCode == 429) {
        GoHttpExchange.discard(response);
        if (attempt == maxRetries) {
          throw const ThreepioException('rate limit reached');
        }
        await goPause(config.retryDelay, cancelToken);
        continue;
      }

      // Go leaves the body of a response it does not use unread; threepio
      // lets go of it, except after the last attempt, whose body is parsed.
      if (attempt < maxRetries) GoHttpExchange.discard(response);
    }

    final List<int> body;
    try {
      body = await exchange!.readBody(response!);
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw ThreepioException(
        'failed to read response body: $error',
        cause: error,
      );
    }

    try {
      return parseSearchResponse(utf8.decode(body, allowMalformed: true));
    } on FormatException catch (error) {
      throw ThreepioException(
        'failed to parse search results: ${error.message}',
        cause: error,
      );
    }
  }

  /// The request of one attempt. Go's transport fails a URL that is not
  /// `http` or `https`, or has no host, before sending anything; the
  /// request then fails the same way here (and is tried again, as in Go).
  static http.BaseRequest _request(Uri url, Map<String, String> headers) {
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw http.ClientException(
        'unsupported protocol scheme "${url.scheme}"',
        url,
      );
    }
    if (url.host.isEmpty) {
      throw http.ClientException('http: no Host in request URL', url);
    }
    return http.Request('GET', url)..headers.addAll(headers);
  }

  /// Reads a SearXNG answer (Go: `parseSearchResponse`): Go's JSON decoding
  /// of a `SearchResponse`, then the number of results counted when
  /// SearXNG reports zero.
  ///
  /// Throws a [FormatException]: Dart's for text that is not JSON, a
  /// `ThreepioFormatException` with Go's text for JSON of the wrong shape.
  @internal
  static SearxngSearchResponse parseSearchResponse(String body) {
    final response = SearxngSearchResponse.fromDecoded(jsonDecode(body));
    if (response.numberOfResults == 0) {
      return response.copyWith(numberOfResults: response.results.length);
    }
    return response;
  }
}

/// A tool that searches the web with a SearXNG instance.
///
/// Port of eino-ext `searxng.BuildSearchInvokeTool` (an `utils.InferTool`
/// named `web_search` over `SearxngClient.Search`). The model passes `query`
/// and `pageno`; the tool answers with Go's JSON byte for byte, for example
/// `{"query":"eino","number_of_results":1,"results":[{"title":…,"content":…,"url":…,"engine":…}]}`.
/// When SearXNG finds nothing the call fails with `no search results found`,
/// as in Go. Dart code calls [search] for Go's typed answer or
/// [searchResults] for the hits as [SearchResult]s.
///
/// ```dart
/// final tool = SearxngSearchTool(
///   const SearxngClientConfig(baseUrl: 'https://searx.example.org/search'),
/// );
/// final hits = await tool.searchResults(
///   RunContext.background(),
///   const SearxngSearchRequest(query: 'eino'),
/// );
/// tool.dispose();
/// ```
final class SearxngSearchTool extends InvokableTool implements TypedComponent {
  /// A tool on a client configured by [config].
  ///
  /// Throws an [ArgumentError] when `config.maxRetries` is negative.
  SearxngSearchTool(SearxngClientConfig config) : this._(SearxngClient(config));

  SearxngSearchTool._(SearxngClient client)
      : client = client,
        _tool = FunctionTool<SearxngSearchRequest, SearxngSearchResponse>(
          name: toolName,
          description: toolDesc,
          params: const ParamsOneOf.jsonSchema(parameters),
          fromJson: SearxngSearchRequest.fromJson,
          invoke: (ctx, request, _) => client.search(ctx, request),
          // A String goes to the model as it is: sonic's text, not
          // jsonEncode's (they differ on backspace and form feed).
          toJson: (response) => goSonicMarshal(response.toJson()),
        );

  /// The name of the tool (Go: `toolName`).
  static const String toolName = 'web_search';

  /// The description of the tool (Go: `toolDesc`, with its line break and
  /// two tabs).
  static const String toolDesc =
      'Performs a web search using the SearXNG API, ideal for general '
      'queries, news, articles, and online content.\n'
      '\t\tUse this for broad information gathering, recent events, or when '
      'you need diverse web sources.';

  /// The parameters, as Go's `InferTool` derives them from `SearchRequest`:
  /// `query` and `pageno` with their descriptions, both required (neither
  /// field is `omitempty`), no other properties.
  static const JSONSchema parameters = JSONSchema(
    properties: {
      'query': JSONSchemaProperty(
        type: 'string',
        description:
            'The search query. This is the main input for the web search',
      ),
      'pageno': JSONSchemaProperty(
        type: 'integer',
        description: 'The page number of the search results. Default is 1',
      ),
    },
    required: ['query', 'pageno'],
  );

  /// The client the tool searches with; it was created for the tool and is
  /// closed by [dispose].
  final SearxngClient client;

  final FunctionTool<SearxngSearchRequest, SearxngSearchResponse> _tool;

  /// The name of the tool, `web_search`.
  String get name => _tool.name;

  /// `WebSearch` (Go: the `GetType` of an `utils.InferTool` tool).
  @override
  String get componentTypeName => _tool.componentTypeName;

  @override
  Future<ToolInfo> info() => _tool.info();

  /// Runs the search the model asked for and answers with Go's JSON.
  ///
  /// Throws a [ThreepioFormatException] for arguments that are not a JSON
  /// object of the right types, and what [SearxngClient.search] throws.
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
  /// one [invokableRun] encodes for the model (Go: `SearxngClient.Search`).
  /// Throws what [SearxngClient.search] throws, `no search results found`
  /// included.
  Future<SearxngSearchResponse> search(
    RunContext ctx,
    SearxngSearchRequest request,
  ) =>
      client.search(ctx, request);

  /// The hits of the search [request] describes, in the shape every search
  /// tool shares (SearXNG's `content` is the snippet, its `engine` is
  /// `extra['engine']`). threepio-only. Where [search] fails with `no search
  /// results found`, this returns an empty list; otherwise it throws what
  /// [search] throws.
  Future<List<SearchResult>> searchResults(
    RunContext ctx,
    SearxngSearchRequest request,
  ) async {
    final response = await client._searchResponse(ctx, request);
    return List.unmodifiable(response.toSearchResults());
  }

  /// Closes the HTTP client the tool's client created; a client passed as
  /// `SearxngClientConfig.httpClient` is left open. Using the tool
  /// afterwards throws a [StateError].
  void dispose() => client.dispose();
}
