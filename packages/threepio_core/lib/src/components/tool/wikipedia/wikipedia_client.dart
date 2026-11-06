/// The client of the MediaWiki API behind the Wikipedia search tool.
///
/// Port of eino-ext `components/tool/wikipedia/internal` (`client.go`,
/// `types.go`, `option.go`). Go keeps it in an `internal` package; so does
/// threepio: nothing here is exported.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../http_request/web_tool_http.dart';
import 'wikipedia_errors.dart';

/// A hit of a search.
///
/// Port of eino-ext `wikipedia/internal.SearchResult`.
@internal
@immutable
final class WikipediaClientSearchResult {
  /// A hit for the page [title].
  const WikipediaClientSearchResult({
    required this.title,
    required this.pageId,
    required this.url,
    required this.snippet,
    required this.wordCount,
    required this.language,
  });

  /// The title of the page.
  final String title;

  /// The ID of the page.
  final int pageId;

  /// The address of the page.
  final String url;

  /// The text around the match, with the basic HTML removed.
  final String snippet;

  /// The number of words of the page.
  final int wordCount;

  /// The language of the wiki.
  final String language;
}

/// A page.
///
/// Port of eino-ext `wikipedia/internal.Page`.
@internal
@immutable
final class WikipediaPage {
  /// The page [title].
  const WikipediaPage({
    required this.title,
    required this.pageId,
    required this.content,
    required this.url,
    this.lastUpdated,
  });

  /// The title of the page.
  final String title;

  /// The ID of the page.
  final int pageId;

  /// The plain-text extract of the page.
  final String content;

  /// The address of the page.
  final String url;

  /// When the page was last changed (in UTC); `null` when the API reports no
  /// revision (Go: the zero time).
  final DateTime? lastUpdated;
}

/// A client for the MediaWiki API of one Wikipedia.
///
/// Port of eino-ext `wikipedia/internal.WikipediaClient` and its options
/// (`WithHTTPClient`, `WithLanguage`, `WithBaseURL`, `WithUserAgent`,
/// `WithTopK`). Go's `http.Client` carries the timeout and the redirect
/// policy; here they are [timeout] and [checkRedirect].
@internal
final class WikipediaClient {
  /// A client for the API at [baseUrl].
  WikipediaClient({
    required this.httpClient,
    required this.baseUrl,
    required this.userAgent,
    required this.language,
    required this.topK,
    this.timeout,
    this.checkRedirect = goDefaultCheckRedirect,
  });

  /// Gives the client that sends the requests (asked for each request).
  final http.Client Function() httpClient;

  /// The address of `api.php`.
  final String baseUrl;

  /// The `User-Agent` of every request.
  final String userAgent;

  /// The language of the wiki, used in the addresses of the pages.
  final String language;

  /// How many hits a search asks for (`srlimit`).
  final int topK;

  /// How long one request may take, redirects and body included (Go:
  /// `http.Client.Timeout`); `null`: no limit.
  final Duration? timeout;

  /// Decides which redirects are followed (Go: `http.Client.CheckRedirect`).
  final GoCheckRedirect checkRedirect;

  /// Searches the wiki for [query].
  ///
  /// Port of `WikipediaClient.Search`
  /// (https://www.mediawiki.org/wiki/API:Search). Throws a
  /// [WikipediaException] `invalid parameters` for a blank [query], a
  /// [WikipediaApiException] when the API answers with an error, and the
  /// errors of the request (see `_makeRequest`).
  Future<List<WikipediaClientSearchResult>> search(
    RunContext ctx,
    String query,
  ) async {
    if (query.trim().isEmpty) {
      throw WikipediaException(WikipediaErrorKind.invalidParameters);
    }
    final response = await _makeRequest(ctx, {
      'action': 'query',
      'list': 'search',
      'srsearch': query,
      'srlimit': '$topK',
      'srprop': 'wordcount|snippet',
      'format': 'json',
    });

    final List<WikipediaClientSearchResult> results;
    final WikipediaApiException? apiError;
    try {
      final queryPart =
          goJsonObject(response['query'], '', 'query', _searchQueryType);
      final hits = goJsonArray(
        queryPart['search'],
        '',
        'query.search',
        _searchHitsType,
      );
      results = [
        for (final raw in hits)
          () {
            final hit =
                goJsonObject(raw, '', 'query.search', _searchHitType);
            final title = goJsonString(hit['title'], '', 'query.search.title');
            return WikipediaClientSearchResult(
              title: title,
              pageId: goJsonInt(hit['pageid'], '', 'query.search.pageid'),
              snippet: _cleanBasicHtml(
                goJsonString(hit['snippet'], '', 'query.search.snippet'),
              ),
              wordCount:
                  goJsonInt(hit['wordcount'], '', 'query.search.wordcount'),
              url: _buildPageUrl(title),
              language: language,
            );
          }(),
      ];
      apiError = _decodeApiError(response);
    } on ThreepioFormatException catch (error) {
      throw _unmarshalFailed(error);
    }
    if (apiError != null) throw apiError;
    return results;
  }

  /// Gets the page called [title].
  ///
  /// Port of `WikipediaClient.GetPage`. Throws a [WikipediaException]
  /// `page not found` when the page does not exist, and the errors of the
  /// request (see `_makeRequest`). Of several pages in the answer (Go walks
  /// a map, in no fixed order), the first in the order of the answer is
  /// taken.
  Future<WikipediaPage> getPage(RunContext ctx, String title) async {
    final response = await _makeRequest(ctx, {
      'action': 'query',
      'prop': 'extracts|revisions',
      'titles': title,
      'exlimit': '1',
      'explaintext': '1',
      'rvprop': 'timestamp',
      'format': 'json',
    });

    final List<WikipediaPage?> pages;
    try {
      final queryPart =
          goJsonObject(response['query'], '', 'query', _pageQueryType);
      final pageMap =
          goJsonObject(queryPart['pages'], '', 'query.pages', _pagesType);
      pages = [for (final raw in pageMap.values) _decodePage(raw)];
      // Go decodes the error member too, without looking at it.
      _decodeApiError(response);
    } on ThreepioFormatException catch (error) {
      throw _unmarshalFailed(error);
    }

    for (final page in pages) {
      if (page == null) {
        throw WikipediaException(WikipediaErrorKind.pageNotFound);
      }
      return page;
    }
    throw WikipediaException(WikipediaErrorKind.pageNotFound);
  }

  /// A page of the answer; `null` for a page without an ID (one that does
  /// not exist).
  WikipediaPage? _decodePage(Object? raw) {
    final page = goJsonObject(raw, '', 'query.pages', _pageType);
    final pageId = goJsonInt(page['pageid'], '', 'query.pages.pageid');
    final title = goJsonString(page['title'], '', 'query.pages.title');
    final extract = goJsonString(page['extract'], '', 'query.pages.extract');
    final revisions = goJsonArray(
      page['revisions'],
      '',
      'query.pages.revisions',
      _revisionsType,
    );
    final timestamps = [
      for (final revision in revisions)
        _parseGoTime(
          goJsonObject(
            revision,
            '',
            'query.pages.revisions',
            _revisionType,
          )['timestamp'],
        ),
    ];
    if (pageId == 0) return null;
    return WikipediaPage(
      title: title,
      pageId: pageId,
      content: extract,
      url: _buildPageUrl(title),
      lastUpdated: timestamps.isEmpty ? null : timestamps.first,
    );
  }

  /// Go's `buildPageURL`.
  String _buildPageUrl(String title) =>
      'https://$language.wikipedia.org/wiki/${goPathEscape(title)}';

  /// Sends one request to the API and decodes the answer.
  ///
  /// Port of `WikipediaClient.makeRequest`. Throws [ThreepioException]s with
  /// Go's texts: `create request failed: …`, `request failed: Get "…": …`
  /// (too many redirects: the cause is a [WikipediaException]),
  /// `unexpected status code: N` (anything but 200),
  /// `read response body failed: …`, and a [ThreepioFormatException]
  /// `json unmarshal failed: …`; a `CancelledException` when
  /// `ctx.cancelToken` is cancelled.
  Future<Map<String, Object?>> _makeRequest(
    RunContext ctx,
    Map<String, String> params,
  ) async {
    final client = httpClient();
    final urlText = '$baseUrl?${goEncodeQuery(params)}';
    final Uri url;
    try {
      url = Uri.parse(urlText);
    } on FormatException catch (error) {
      throw ThreepioException(
        'create request failed: parse ${goQuote(urlText)}: ${error.message}',
        cause: error,
      );
    }

    final call = GoHttpCall(ctx, timeout: timeout);
    try {
      final http.StreamedResponse response;
      try {
        response = await call.send(
          client,
          method: 'GET',
          url: url,
          headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
          checkRedirect: checkRedirect,
        );
      } on GoHttpDoException catch (error) {
        throw ThreepioException(
          'request failed: ${error.message}',
          cause: error.cause,
        );
      }
      if (response.statusCode != 200) {
        call.discard(response);
        throw ThreepioException(
          'unexpected status code: ${response.statusCode}',
        );
      }
      final List<int> body;
      try {
        body = await call.readAll(response);
      } on GoHttpReadException catch (error) {
        throw ThreepioException(
          'read response body failed: ${error.reason}',
          cause: error.cause,
        );
      }
      try {
        return goJsonDecodeObject(body, 'struct');
      } on ThreepioFormatException catch (error) {
        throw _unmarshalFailed(error);
      }
    } finally {
      call.close();
    }
  }
}

const _searchQueryType = 'struct { Search []struct }';
const _searchHitsType = '[]struct';
const _searchHitType = 'struct';
const _pageQueryType = 'struct { Pages map[string]struct }';
const _pagesType = 'map[string]struct';
const _pageType = 'struct';
const _revisionsType = '[]struct';
const _revisionType = 'struct';

ThreepioFormatException _unmarshalFailed(ThreepioFormatException error) =>
    ThreepioFormatException('json unmarshal failed: ${error.message}',
        cause: error);

/// The `error` member of an answer (Go: `Error *APIError`), or `null`.
WikipediaApiException? _decodeApiError(Map<String, Object?> response) {
  final raw = response['error'];
  if (raw == null) return null;
  final error = goJsonObject(raw, '', 'error', 'internal.APIError');
  return WikipediaApiException(
    code: goJsonString(error['code'], 'APIError', 'error.code'),
    info: goJsonString(error['info'], 'APIError', 'error.info'),
    docRef: goJsonString(error['docref'], 'APIError', 'error.docref'),
  );
}

final _rfc3339 = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
);

/// Go's `time.Time.UnmarshalJSON`: `null` is the zero time, a string must be
/// an RFC 3339 time.
DateTime? _parseGoTime(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const ThreepioFormatException(
      'Time.UnmarshalJSON: input is not a JSON string',
    );
  }
  final parsed = _rfc3339.hasMatch(value) ? DateTime.tryParse(value) : null;
  if (parsed == null) {
    throw ThreepioFormatException(
      'parsing time ${goQuote(value)} as "2006-01-02T15:04:05Z07:00": '
      'cannot parse',
    );
  }
  return parsed.toUtc();
}

const _snippetReplacements = [
  ('<span class="searchmatch">', ''),
  ('</span>', ''),
  ('&nbsp;', ' '),
];

/// Go's `cleanBasicHTML`: one pass of a `strings.Replacer` that removes the
/// search-match spans and turns `&nbsp;` into a space.
String _cleanBasicHtml(String snippet) {
  final out = StringBuffer();
  var index = 0;
  outer:
  while (index < snippet.length) {
    for (final (old, replacement) in _snippetReplacements) {
      if (snippet.startsWith(old, index)) {
        out.write(replacement);
        index += old.length;
        continue outer;
      }
    }
    out.writeCharCode(snippet.codeUnitAt(index));
    index++;
  }
  return out.toString();
}
