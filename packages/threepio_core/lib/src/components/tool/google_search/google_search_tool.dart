/// The Google search tool: Google's Custom Search JSON API for a model.
///
/// Port of eino-ext `components/tool/googlesearch`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/naming.dart';
import '../../../internal/shared_http_client.dart';
import '../../../schema/tool_info.dart';
import '../../component_type.dart';
import '../function_tool.dart';
import '../http_request/web_tool_http.dart';
import '../invokable_tool.dart';
import '../search_result.dart';
import '../tool_options.dart';

/// The `User-Agent` the Go client of the API sends
/// (`googleapi.UserAgent`, `google-api-go-client/` + `googleapi.Version`).
const _userAgent = 'google-api-go-client/0.5';

/// The configuration of [GoogleSearchTool].
///
/// Port of eino-ext `googlesearch.Config`. [apiKey] and [searchEngineId]
/// are required: create them in the Google Cloud console and the
/// Programmable Search Engine control panel.
@immutable
final class GoogleSearchConfig {
  /// A configuration with the credentials of the API.
  const GoogleSearchConfig({
    required this.apiKey,
    required this.searchEngineId,
    this.baseUrl,
    this.num,
    this.lang,
    this.toolName,
    this.toolDesc,
    this.httpClient,
    this.timeout,
  });

  /// The API key (Go: `APIKey`), sent as the `key` query parameter, as the
  /// Go client sends it. It never appears in errors (deviation: Go's
  /// `url.Error` texts quote the address with the key).
  final String apiKey;

  /// The ID of the Programmable Search Engine (Go: `SearchEngineID`), the
  /// `cx` parameter.
  final String searchEngineId;

  /// The endpoint of the API. `null` or empty: [defaultBaseUrl]. A value
  /// without `://` is a `host[:port]` that replaces the host of the default
  /// (Go: `option.WithEndpoint`).
  final String? baseUrl;

  /// How many results to ask for when the model does not say (1 to 10).
  /// `null` or not positive: the API's default (10).
  final int? num;

  /// The language to search in when the model does not say, a 2 to 4 letter
  /// ISO 639-1 code such as `en`, `ja` or `zh-CN`, sent as the `gl`
  /// parameter (as Go sends it). `null` or empty: none.
  final String? lang;

  /// The name of the tool. `null` or empty: `google_search`.
  final String? toolName;

  /// What the tool tells the model. `null` or empty:
  /// `custom search json api of google search engine`.
  final String? toolDesc;

  /// The client that sends the requests. The caller owns it and closes it.
  /// `null`: the tool creates one on first use and closes it in
  /// `GoogleSearchTool.dispose` (threepio-only: Go always uses a client of
  /// its own).
  final http.Client? httpClient;

  /// How long one search may take (threepio-only). `null`, zero or
  /// negative: no limit, as in Go.
  final Duration? timeout;

  /// The endpoint of the Custom Search JSON API.
  static const defaultBaseUrl = 'https://customsearch.googleapis.com';
}

/// The arguments of the Google search tool.
///
/// Port of eino-ext `googlesearch.SearchRequest`.
@immutable
final class GoogleSearchRequest {
  /// A search for [query].
  const GoogleSearchRequest({
    required this.query,
    this.num = 0,
    this.offset = 0,
    this.lang = '',
  });

  /// Reads the arguments the model wrote; missing fields take Go's zero
  /// values. Throws a [FormatException] for a field of the wrong type.
  factory GoogleSearchRequest.fromJson(Map<String, Object?> json) =>
      GoogleSearchRequest(
        query: goJsonString(json['query'], 'SearchRequest', 'query'),
        num: goJsonInt(json['num'], 'SearchRequest', 'num'),
        offset: goJsonInt(json['offset'], 'SearchRequest', 'offset'),
        lang: goJsonString(json['lang'], 'SearchRequest', 'lang'),
      );

  /// The text to search for.
  final String query;

  /// How many results to return, 1 to 10; 0 or less:
  /// [GoogleSearchConfig.num].
  final int num;

  /// The index of the first result to return (the `start` parameter);
  /// 0 or less: the first.
  final int offset;

  /// The language, as [GoogleSearchConfig.lang]; empty:
  /// [GoogleSearchConfig.lang].
  final String lang;

  /// The arguments as Go encodes them (`num`, `offset` and `lang` are
  /// `omitempty`).
  Map<String, Object?> toJson() => {
        'query': query,
        if (num != 0) 'num': num,
        if (offset != 0) 'offset': offset,
        if (lang.isNotEmpty) 'lang': lang,
      };

  @override
  bool operator ==(Object other) =>
      other is GoogleSearchRequest &&
      other.query == query &&
      other.num == num &&
      other.offset == offset &&
      other.lang == lang;

  @override
  int get hashCode => Object.hash(query, num, offset, lang);

  @override
  String toString() => 'GoogleSearchRequest(${toJson()})';
}

/// One hit of a Google search, as the tool reports it to the model.
///
/// Port of eino-ext `googlesearch.SimplifiedSearchItem`.
@immutable
final class GoogleSimplifiedSearchItem {
  /// A hit for the page [link].
  const GoogleSimplifiedSearchItem({
    required this.link,
    this.title = '',
    this.snippet = '',
    this.desc = '',
  });

  /// The address of the page.
  final String link;

  /// The title of the page.
  final String title;

  /// The text Google shows with the hit.
  final String snippet;

  /// The `description` (else `og:description`) meta tags of the page, one
  /// per line; empty when it has none.
  final String desc;

  /// The hit as Go encodes it, fields in Go's order (`title`, `snippet` and
  /// `desc` are `omitempty`).
  Map<String, Object?> toJson() => {
        'link': link,
        if (title.isNotEmpty) 'title': title,
        if (snippet.isNotEmpty) 'snippet': snippet,
        if (desc.isNotEmpty) 'desc': desc,
      };

  /// The hit in the shape every search tool shares: `link` is the
  /// [SearchResult.url], and a [desc] is `extra['desc']`.
  SearchResult toSearchResult() => SearchResult(
        title: title,
        url: link,
        snippet: snippet,
        extra: desc.isEmpty ? const {} : {'desc': desc},
      );

  @override
  bool operator ==(Object other) =>
      other is GoogleSimplifiedSearchItem &&
      other.link == link &&
      other.title == title &&
      other.snippet == snippet &&
      other.desc == desc;

  @override
  int get hashCode => Object.hash(link, title, snippet, desc);

  @override
  String toString() => 'GoogleSimplifiedSearchItem(link: $link)';
}

/// What the Google search tool reports to the model.
///
/// Port of eino-ext `googlesearch.SearchResult` (renamed: threepio's
/// [SearchResult] is the hit every search tool shares).
@immutable
final class GoogleSearchResult {
  /// The [items] found for [query].
  const GoogleSearchResult({this.query = '', this.items = const []});

  /// The search terms of the request, as the API reports them.
  final String query;

  /// The hits, in Google's order.
  final List<GoogleSimplifiedSearchItem> items;

  /// The result as Go encodes it (`query` is `omitempty`, `items` is always
  /// there). The tool hands the model this JSON.
  Map<String, Object?> toJson() => {
        if (query.isNotEmpty) 'query': query,
        'items': [for (final item in items) item.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is GoogleSearchResult &&
      other.query == query &&
      const ListEquality<GoogleSimplifiedSearchItem>()
          .equals(other.items, items);

  @override
  int get hashCode => Object.hash(
        query,
        const ListEquality<GoogleSimplifiedSearchItem>().hash(items),
      );

  @override
  String toString() =>
      'GoogleSearchResult(query: $query, ${items.length} items)';
}

/// One entry of the `errors` list of an error answer of a Google API.
///
/// Port of `googleapi.ErrorItem`.
@immutable
final class GoogleApiErrorItem {
  /// An entry with [reason] and [message].
  const GoogleApiErrorItem({this.reason = '', this.message = ''});

  /// The typed error code, for example `badRequest`.
  final String reason;

  /// The description of the error.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is GoogleApiErrorItem &&
      other.reason == reason &&
      other.message == message;

  @override
  int get hashCode => Object.hash(reason, message);

  @override
  String toString() => 'GoogleApiErrorItem(reason: $reason)';
}

/// An error answer of a Google API: a status code outside 200–299.
///
/// Port of `googleapi.Error` (as `googleapi.CheckResponse` builds it):
/// [message] is Go's `Error()` text, for example
/// `googleapi: Error 400: API key not valid. Please pass a valid API key.,
/// badRequest`. The search tool throws a [ThreepioException]
/// `search.cse.list failed: …` whose [ThreepioException.cause] is this.
final class GoogleApiException extends ThreepioException {
  GoogleApiException._(
    super.message, {
    required this.code,
    required this.apiMessage,
    required this.details,
    required this.errors,
    required this.body,
  });

  /// The error for an answer with status [code] and [body].
  ///
  /// When [body] is a JSON object whose `error` member is an object of the
  /// expected shape, its `code` (if not 0), `message`, `details` and
  /// `errors` are used; otherwise only [code] and [body].
  factory GoogleApiException.fromResponse(int code, String body) {
    final parsed = _parseErrorReply(body);
    final effectiveCode = parsed == null || parsed.code == 0 ? code : parsed.code;
    final apiMessage = parsed?.message ?? '';
    final details = parsed?.details ?? const <Object?>[];
    final errors = parsed?.errors ?? const <GoogleApiErrorItem>[];
    return GoogleApiException._(
      _errorText(effectiveCode, apiMessage, details, errors, body),
      code: effectiveCode,
      apiMessage: apiMessage,
      details: List.unmodifiable(details),
      errors: List.unmodifiable(errors),
      body: body,
    );
  }

  /// The HTTP status code (Go: `Code`), or the `code` of the error answer
  /// when it names one.
  final int code;

  /// The `message` of the error answer (Go: `Message`); empty when it has
  /// none.
  final String apiMessage;

  /// The `details` of the error answer (Go: `Details`).
  final List<Object?> details;

  /// The `errors` of the error answer (Go: `Errors`).
  final List<GoogleApiErrorItem> errors;

  /// The body of the answer, as it came (Go: `Body`).
  final String body;

  @override
  String toString() => 'GoogleApiException: $message';
}

typedef _ErrorReply = ({
  int code,
  String message,
  List<Object?> details,
  List<GoogleApiErrorItem> errors,
});

/// Go's `json.Unmarshal(body, &errorReply)`: `null` when the body is not
/// JSON, has no `error` object, or holds a value of the wrong type (Go then
/// keeps only the status code and the body).
_ErrorReply? _parseErrorReply(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final error = decoded['error'];
  if (error is! Map<String, Object?>) return null;
  final code = error['code'];
  final message = error['message'];
  final details = error['details'];
  final errors = error['errors'];
  if (code != null && code is! int) return null;
  if (message != null && message is! String) return null;
  if (details != null && details is! List<Object?>) return null;
  if (errors != null && errors is! List<Object?>) return null;
  final items = <GoogleApiErrorItem>[];
  for (final item in (errors as List<Object?>?) ?? const <Object?>[]) {
    if (item == null) {
      items.add(const GoogleApiErrorItem());
      continue;
    }
    if (item is! Map<String, Object?>) return null;
    final reason = item['reason'];
    final itemMessage = item['message'];
    if (reason != null && reason is! String) return null;
    if (itemMessage != null && itemMessage is! String) return null;
    items.add(
      GoogleApiErrorItem(
        reason: reason as String? ?? '',
        message: itemMessage as String? ?? '',
      ),
    );
  }
  return (
    code: code as int? ?? 0,
    message: message as String? ?? '',
    details: (details as List<Object?>?) ?? const [],
    errors: items,
  );
}

/// Go's `googleapi.Error.Error()`.
String _errorText(
  int code,
  String message,
  List<Object?> details,
  List<GoogleApiErrorItem> errors,
  String body,
) {
  if (errors.isEmpty && message.isEmpty) {
    return 'googleapi: got HTTP response code $code with body: $body';
  }
  final text = StringBuffer('googleapi: Error $code: ')..write(message);
  if (details.isNotEmpty) {
    text
      ..write('\nDetails:')
      ..write('\n${_goIndentedJson(details)}');
  }
  if (errors.isEmpty) return text.toString().trim();
  if (errors.length == 1 && errors.first.message == message) {
    text.write(', ${errors.first.reason}');
    return text.toString();
  }
  text.write('\nMore details:\n');
  for (final item in errors) {
    text.write('Reason: ${item.reason}, Message: ${item.message}\n');
  }
  return text.toString();
}

/// What Go's `json.Encoder` with `SetIndent("", "  ")` writes for a decoded
/// JSON value: keys sorted, `<`, `>`, `&`, U+2028 and U+2029 escaped, a
/// whole number without a fraction, a line feed at the end.
String _goIndentedJson(Object? value) {
  final backslash = String.fromCharCode(0x5c);
  final text = const JsonEncoder.withIndent('  ').convert(_goJsonValue(value));
  final out = StringBuffer();
  for (final rune in text.runes) {
    switch (rune) {
      case 0x3c || 0x3e || 0x26 || 0x2028 || 0x2029:
        out
          ..write(backslash)
          ..write('u')
          ..write(rune.toRadixString(16).padLeft(4, '0'));
      default:
        out.writeCharCode(rune);
    }
  }
  return '$out\n';
}

Object? _goJsonValue(Object? value) => switch (value) {
      final Map<String, Object?> map => {
          for (final key in map.keys.toList()..sort())
            key: _goJsonValue(map[key]),
        },
      final List<Object?> list => [for (final item in list) _goJsonValue(item)],
      final double number
          when number == number.truncateToDouble() && number.abs() < 1e21 =>
        number.toInt(),
      _ => value,
    };

/// A hit as the API answers it, before the meta tags are read.
typedef _RawItem = ({
  String link,
  String title,
  String snippet,
  bool hasPagemap,
  Object? pagemap,
});

/// The Google search tool.
///
/// Port of eino-ext `googlesearch.NewTool`: a `utils.InferTool` over a
/// search of the Custom Search JSON API (`GET {baseUrl}/customsearch/v1`
/// with the query parameters `key`, `cx`, `q`, `num`, `gl`, `start`,
/// `alt=json` and `prettyPrint=false`, as Go's `customsearch` client sends
/// them). The model gets [GoogleSearchResult] as JSON, byte for byte what Go
/// writes:
///
/// ```json
/// {"query":"…","items":[{"link":"…","title":"…","snippet":"…","desc":"…"}]}
/// ```
///
/// Dart callers can call [search] for the typed result, or [searchResults]
/// for the hits as the [SearchResult]s every search tool shares.
///
/// Errors: a failed request throws a [ThreepioException]
/// `search.cse.list failed: …` (an error answer of the API has a
/// [GoogleApiException] as [ThreepioException.cause]); a `pagemap` that is
/// not a JSON object throws a [ThreepioFormatException]
/// `json.Unmarshal Pagemap failed: …`. A call whose `ctx.cancelToken` is
/// cancelled throws a `CancelledException`.
///
/// Deviations from Go, on purpose:
///
/// * a hit without a `pagemap` member gets no `desc`. Go's
///   `getDescFromPageMap` unmarshals the empty raw message and fails the
///   whole call, but the API leaves `pagemap` out of many hits (pages
///   without structured data), so Go's tool fails on ordinary searches;
/// * an answer without `queries`, or with a `null` hit, gives an empty query
///   or an empty hit (Go dereferences a nil pointer and panics); a `204`
///   answer is an empty result for the same reason;
/// * the API key never appears in errors (Go's quote the address with it);
/// * no `x-goog-api-client` header (Go's names the Go version);
/// * data after the JSON value of the answer is an error (Go's
///   `json.Decoder` ignores it).
///
/// Call [dispose] when done with a tool that created its own client.
final class GoogleSearchTool extends InvokableTool implements TypedComponent {
  /// A search tool configured by [config].
  ///
  /// Throws an [ArgumentError] `missing api_key or search_engine_id` when
  /// one of the two is empty, and when [GoogleSearchConfig.baseUrl] is not
  /// a URL.
  GoogleSearchTool(this.config)
      : name = _orDefault(config.toolName, 'google_search'),
        description = _orDefault(
          config.toolDesc,
          'custom search json api of google search engine',
        ),
        _endpoint = _validatedEndpoint(config),
        _http = SharedHttpClient(config.httpClient, owner: 'GoogleSearchTool');

  /// The configuration the tool was made with.
  final GoogleSearchConfig config;

  /// The name of the tool: [GoogleSearchConfig.toolName] or `google_search`.
  final String name;

  /// What the tool tells the model.
  final String description;

  final Uri _endpoint;
  final SharedHttpClient _http;

  late final InvokableTool _tool =
      FunctionTool<GoogleSearchRequest, GoogleSearchResult>(
    name: name,
    description: description,
    params: ParamsOneOf.jsonSchema(
      JSONSchema(
        properties: {
          'query': JSONSchemaProperty.string(
            description: 'queried string to the search engine',
          ),
          'num': const JSONSchemaProperty(
            type: 'integer',
            description: 'number of search results to return, valid values '
                'are between 1 and 10, inclusive',
          ),
          'offset': const JSONSchemaProperty(
            type: 'integer',
            description: 'the index of the first result to return.',
          ),
          'lang': JSONSchemaProperty.string(
            description: 'sets the user interface language, default english. '
                'usually represented by a 2-4 letter code in ISO 639-1. e.g. '
                'en, ja, zh-CN',
          ),
        },
        required: const ['query'],
      ),
    ),
    fromJson: GoogleSearchRequest.fromJson,
    invoke: (ctx, request, _) => search(ctx, request),
    toJson: (result) => sonicMarshal(result.toJson()),
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

  /// Searches for `request.query` and returns what the tool reports to the
  /// model.
  ///
  /// Port of eino-ext `googleSearch.search` followed by
  /// `googleSearch.marshalOutput` (without the encoding).
  Future<GoogleSearchResult> search(
    RunContext ctx,
    GoogleSearchRequest request,
  ) async {
    // Outside the try: a disposed tool is a programming error.
    final client = _http.client;
    final count = request.num > 0 ? request.num : (config.num ?? 0);
    final lang = request.lang.isNotEmpty ? request.lang : (config.lang ?? '');
    final params = {
      'alt': 'json',
      'cx': config.searchEngineId,
      'prettyPrint': 'false',
      'q': request.query,
      if (count > 0) 'num': '$count',
      if (lang.isNotEmpty) 'gl': lang,
      if (request.offset > 0) 'start': '${request.offset}',
    };
    final base = _endpoint.resolve('customsearch/v1').toString();
    // Go's `transport.APIKey` adds the key to the `*url.URL` the request
    // shares with `Client.Do`, so Go's errors quote the address with the key.
    // Here errors quote it without the key (a deliberate deviation).
    final urlText = '$base?${goEncodeQuery(params)}';
    final url =
        Uri.parse('$base?${goEncodeQuery({...params, 'key': config.apiKey})}');

    final call = GoHttpCall(ctx, timeout: config.timeout);
    final List<_RawItem> items;
    final String query;
    try {
      final http.StreamedResponse response;
      try {
        response = await call.send(
          client,
          method: 'GET',
          url: url,
          urlText: urlText,
          headers: const {'User-Agent': _userAgent},
        );
      } on GoHttpDoException catch (error) {
        throw ThreepioException(
          'search.cse.list failed: ${error.message}',
          cause: error.cause,
        );
      }

      final status = response.statusCode;
      if (status == 304) {
        call.discard(response);
        throw _failed(GoogleApiException.fromResponse(304, ''));
      }
      if (status < 200 || status > 299) {
        var body = '';
        try {
          body = utf8.decode(await call.readAll(response), allowMalformed: true);
        } on GoHttpReadException {
          // The error is still the status. Go's body would keep the bytes
          // read before the failure; here it is empty.
        }
        throw _failed(GoogleApiException.fromResponse(status, body));
      }
      if (status == 204) {
        call.discard(response);
        return const GoogleSearchResult();
      }

      final List<int> body;
      try {
        body = await call.readAll(response);
      } on GoHttpReadException catch (error) {
        throw ThreepioException(
          'search.cse.list failed: ${error.reason}',
          cause: error.cause,
        );
      }
      try {
        final json = goJsonDecodeObject(body, 'customsearch.Search');
        items = _decodeItems(json);
        query = _decodeQuery(json);
      } on ThreepioFormatException catch (error) {
        throw ThreepioFormatException(
          'search.cse.list failed: ${error.message}',
          cause: error,
        );
      }
    } finally {
      call.close();
    }

    return GoogleSearchResult(
      query: query,
      items: List.unmodifiable([
        for (final item in items)
          GoogleSimplifiedSearchItem(
            link: item.link,
            title: item.title,
            snippet: item.snippet,
            desc: item.hasPagemap ? _descFromPageMap(item.pagemap) : '',
          ),
      ]),
    );
  }

  /// Searches for `request.query` and returns the hits as [SearchResult]s:
  /// Google's `link` is [SearchResult.url], its `snippet` the
  /// [SearchResult.snippet], and a description from the page's meta tags is
  /// `extra['desc']`. Throws like [search].
  ///
  /// threepio-only: the typed counterpart of what the model gets.
  Future<List<SearchResult>> searchResults(
    RunContext ctx,
    GoogleSearchRequest request,
  ) async {
    final result = await search(ctx, request);
    return List.unmodifiable([
      for (final item in result.items) item.toSearchResult(),
    ]);
  }

  /// Closes the client the tool created, if it created one; an injected
  /// client is left open. The tool must not be called afterwards. Safe to
  /// call repeatedly.
  void dispose() => _http.close();
}

ThreepioException _failed(GoogleApiException error) =>
    ThreepioException('search.cse.list failed: ${error.message}', cause: error);

String _orDefault(String? value, String fallback) =>
    value == null || value.isEmpty ? fallback : value;

/// The base of the requests, as the Go client resolves `option.WithEndpoint`,
/// after the check of `googlesearch.NewTool` on the credentials.
Uri _validatedEndpoint(GoogleSearchConfig config) {
  if (config.apiKey.isEmpty || config.searchEngineId.isEmpty) {
    throw ArgumentError('missing api_key or search_engine_id');
  }
  final baseUrl = config.baseUrl;
  final endpoint = switch (baseUrl) {
    null || '' => '${GoogleSearchConfig.defaultBaseUrl}/',
    final url when url.contains('://') => url,
    // A host[:port] replaces the host of the default endpoint.
    final host => 'https://$host/',
  };
  try {
    return Uri.parse(endpoint);
  } on FormatException catch (error) {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'failed to parse ${goQuote(endpoint)}: ${error.message}',
    );
  }
}

/// The hits of a decoded `customsearch.Search`, with the type checks of
/// `encoding/json` for the fields the tool reads.
List<_RawItem> _decodeItems(Map<String, Object?> search) {
  final items =
      goJsonArray(search['items'], 'Search', 'items', '[]*customsearch.Result');
  return [
    for (final raw in items)
      () {
        // Go dereferences a null hit and panics; here it is an empty hit.
        final item =
            goJsonObject(raw, 'Search', 'items', 'customsearch.Result');
        return (
          link: goJsonString(item['link'], 'Result', 'items.link'),
          title: goJsonString(item['title'], 'Result', 'items.title'),
          snippet: goJsonString(item['snippet'], 'Result', 'items.snippet'),
          hasPagemap: item.containsKey('pagemap'),
          pagemap: item['pagemap'],
        );
      }(),
  ];
}

/// Go's `getQuery(gsr.Queries.Request)`: the search terms of the requests
/// the API reports, joined by spaces.
String _decodeQuery(Map<String, Object?> search) {
  // Go dereferences a missing `queries` and panics; here the query is empty.
  final queries = goJsonObject(
    search['queries'],
    'Search',
    'queries',
    'customsearch.SearchQueries',
  );
  final requests = goJsonArray(
    queries['request'],
    'SearchQueries',
    'queries.request',
    '[]*customsearch.SearchQueriesRequest',
  );
  return [
    for (final request in requests)
      goJsonString(
        goJsonObject(
          request,
          'SearchQueries',
          'queries.request',
          'customsearch.SearchQueriesRequest',
        )['searchTerms'],
        'SearchQueriesRequest',
        'queries.request.searchTerms',
      ),
  ].join(' ');
}

/// Go's `getDescFromPageMap`: the `description` (else `og:description`) of
/// each entry of the page's `metatags`, one per line.
String _descFromPageMap(Object? pagemap) {
  if (pagemap == null) return '';
  if (pagemap is! Map<String, Object?>) {
    final kind = switch (pagemap) {
      String() => 'string',
      bool() => 'bool',
      num() => 'number',
      _ => 'array',
    };
    throw ThreepioFormatException(
      'json.Unmarshal Pagemap failed: json: cannot unmarshal $kind into Go '
      'value of type map[string]interface {}',
    );
  }
  final metaTags = pagemap['metatags'];
  if (metaTags is! List<Object?>) return '';
  final descriptions = <String>[];
  for (final entry in metaTags) {
    if (entry is! Map<String, Object?>) continue;
    final description = entry['description'];
    if (description is String) {
      descriptions.add(description);
      continue;
    }
    final ogDescription = entry['og:description'];
    if (ogDescription is String) descriptions.add(ogDescription);
  }
  return descriptions.join('\n');
}
