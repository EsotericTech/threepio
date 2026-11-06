/// The values the SearXNG search tool works with.
///
/// Port of the types of eino-ext `components/tool/searxng/searxng.go`.
library;

import 'package:meta/meta.dart';

import '../duckduckgo/go_wire.dart';
import '../search_result.dart';
import 'searxng_validation.dart';

/// How recent the results must be.
///
/// Port of eino-ext `searxng.TimeRange` and its constants; [wireValue] is
/// the value of SearXNG's `time_range` parameter.
enum SearxngTimeRange {
  /// The past day (Go: `TimeRangeDay`).
  day('day'),

  /// The past month (Go: `TimeRangeMonth`).
  month('month'),

  /// The past year (Go: `TimeRangeYear`).
  year('year');

  const SearxngTimeRange(this.wireValue);

  /// The value of the `time_range` parameter.
  final String wireValue;
}

/// The language of the results.
///
/// Port of eino-ext `searxng.Language` and its constants; [wireValue] is the
/// value of SearXNG's `language` parameter.
enum SearxngLanguage {
  /// Every language (Go: `LanguageAll`).
  all('all'),

  /// English (Go: `LanguageEn`).
  en('en'),

  /// Chinese (Go: `LanguageZh`).
  zh('zh'),

  /// Chinese as written in China (Go: `LanguageZhCN`).
  zhCN('zh-CN'),

  /// Chinese as written in Taiwan (Go: `LanguageZhTW`).
  zhTW('zh-TW'),

  /// French (Go: `LanguageFr`).
  fr('fr'),

  /// German (Go: `LanguageDe`).
  de('de'),

  /// Spanish (Go: `LanguageEs`).
  es('es'),

  /// Japanese (Go: `LanguageJa`).
  ja('ja'),

  /// Korean (Go: `LanguageKo`).
  ko('ko'),

  /// Russian (Go: `LanguageRu`).
  ru('ru'),

  /// Arabic (Go: `LanguageAr`).
  ar('ar'),

  /// Portuguese (Go: `LanguagePt`).
  pt('pt'),

  /// Italian (Go: `LanguageIt`).
  it('it'),

  /// Dutch (Go: `LanguageNl`).
  nl('nl'),

  /// Polish (Go: `LanguagePl`).
  pl('pl'),

  /// Turkish (Go: `LanguageTr`).
  tr('tr');

  const SearxngLanguage(this.wireValue);

  /// The value of the `language` parameter.
  final String wireValue;
}

/// How strictly SearXNG filters adult content.
///
/// Port of eino-ext `searxng.SafeSearchLevel` and its constants;
/// [wireValue] is the value of SearXNG's `safesearch` parameter.
enum SearxngSafeSearch {
  /// No filter (Go: `SafeSearchNone`, 0; the zero value, never sent).
  none(0),

  /// A moderate filter (Go: `SafeSearchModerate`, 1).
  moderate(1),

  /// A strict filter (Go: `SafeSearchStrict`, 2).
  strict(2);

  const SearxngSafeSearch(this.wireValue);

  /// The value of the `safesearch` parameter.
  final int wireValue;
}

/// A search engine SearXNG asks.
///
/// Port of eino-ext `searxng.Engine` and its constants; [wireValue] is the
/// name in SearXNG's `engines` parameter. SearXNG knows many more engines;
/// Go accepts these only.
enum SearxngEngine {
  /// Google (Go: `EngineGoogle`).
  google('google'),

  /// DuckDuckGo (Go: `EngineDuckDuckGo`).
  duckDuckGo('duckduckgo'),

  /// Baidu (Go: `EngineBaidu`).
  baidu('baidu'),

  /// Bing (Go: `EngineBing`).
  bing('bing'),

  /// 360 Search (Go: `Engine360Search`, `360search`).
  search360('360search'),

  /// Yahoo (Go: `EngineYahoo`).
  yahoo('yahoo'),

  /// Quark (Go: `EngineQuark`).
  quark('quark');

  const SearxngEngine(this.wireValue);

  /// The engine's name in the `engines` parameter.
  final String wireValue;
}

/// The search options a SearXNG client adds to every search.
///
/// Port of eino-ext `searxng.SearchRequestConfig` (JSON `time_range`,
/// `language`, `safesearch`, `engines`, each left out when unset). Go
/// validates the values in `NewClient`; here the types admit valid values
/// only, and [SearxngSearchRequestConfig.fromJson] runs Go's checks.
@immutable
final class SearxngSearchRequestConfig {
  /// Options; an unset one is not sent.
  const SearxngSearchRequestConfig({
    this.timeRange,
    this.language,
    this.safeSearch = SearxngSafeSearch.none,
    this.engines = const [],
  });

  /// Reads the JSON form of the options, as Go decodes a
  /// `SearchRequestConfig`, then validates it as Go's `NewClient` does.
  ///
  /// Throws a `ThreepioFormatException` with Go's text when a value has the
  /// wrong JSON type, and an [ArgumentError] with Go's message for a value
  /// Go does not accept, checked in Go's order: `time_range must be one of:
  /// [day month year]`, `language must be one of: […]`, `safesearch must be
  /// one of: [0 1 2]`, `engine 'x' is not supported. Valid engines are:
  /// […]`. Empty strings, `0` and an empty list mean unset.
  factory SearxngSearchRequestConfig.fromJson(Map<String, Object?> json) {
    final fields = GoJsonStruct(json, structName: 'SearchRequestConfig');
    final timeRange = fields.string('time_range', goType: 'searxng.TimeRange');
    final language = fields.string('language', goType: 'searxng.Language');
    final safeSearch =
        fields.integer('safesearch', goType: 'searxng.SafeSearchLevel');
    final engines = [
      for (final engine
          in fields.list('engines', goType: '[]searxng.Engine') ?? const [])
        switch (engine) {
          final String name => name,
          // Go leaves a `null` element at the zero value, the empty name.
          null => '',
          _ => throw fields.typeError(
              goJsonKind(engine),
              'engines',
              'searxng.Engine',
            ),
        },
    ];

    final validTimeRanges = [
      for (final range in SearxngTimeRange.values) range.wireValue,
    ];
    final validLanguages = [
      for (final language in SearxngLanguage.values) language.wireValue,
    ];
    final validSafeSearch = [
      for (final level in SearxngSafeSearch.values) level.wireValue,
    ];
    if (timeRange.isNotEmpty) {
      searxngValidateInSlice(timeRange, validTimeRanges, 'time_range');
    }
    if (language.isNotEmpty) {
      searxngValidateInSlice(language, validLanguages, 'language');
    }
    if (safeSearch != 0) {
      searxngValidateInSlice(safeSearch, validSafeSearch, 'safesearch');
    }
    if (engines.isNotEmpty) searxngValidateEngines(engines);

    return SearxngSearchRequestConfig(
      timeRange: timeRange.isEmpty
          ? null
          : SearxngTimeRange.values[validTimeRanges.indexOf(timeRange)],
      language: language.isEmpty
          ? null
          : SearxngLanguage.values[validLanguages.indexOf(language)],
      safeSearch: SearxngSafeSearch.values[validSafeSearch.indexOf(safeSearch)],
      engines: List.unmodifiable([
        for (final engine in engines)
          SearxngEngine.values[searxngValidEngines.indexOf(engine)],
      ]),
    );
  }

  /// How recent the results must be (Go: `TimeRange`); `null` sends none.
  final SearxngTimeRange? timeRange;

  /// The language of the results (Go: `Language`); `null` sends none.
  final SearxngLanguage? language;

  /// The adult content filter (Go: `SafeSearch`); [SearxngSafeSearch.none],
  /// Go's zero value, is not sent.
  final SearxngSafeSearch safeSearch;

  /// The engines to ask (Go: `Engines`), sent joined by commas; none sends
  /// no `engines` parameter and SearXNG uses its own defaults.
  final List<SearxngEngine> engines;

  /// The JSON form, as Go writes it: unset options are left out.
  Map<String, Object?> toJson() => {
        if (timeRange != null) 'time_range': timeRange!.wireValue,
        if (language != null) 'language': language!.wireValue,
        if (safeSearch != SearxngSafeSearch.none)
          'safesearch': safeSearch.wireValue,
        if (engines.isNotEmpty)
          'engines': [for (final engine in engines) engine.wireValue],
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearxngSearchRequestConfig &&
          other.timeRange == timeRange &&
          other.language == language &&
          other.safeSearch == safeSearch &&
          _listEquals(other.engines, engines);

  @override
  int get hashCode =>
      Object.hash(timeRange, language, safeSearch, Object.hashAll(engines));

  @override
  String toString() => 'SearxngSearchRequestConfig(${toJson()})';
}

/// What the model asks the SearXNG tool for: the arguments of a call.
///
/// Port of eino-ext `searxng.SearchRequest` (JSON `query`, `pageno`).
@immutable
final class SearxngSearchRequest {
  /// A search for [query], page [pageNo] of the results.
  const SearxngSearchRequest({required this.query, this.pageNo});

  /// Reads the arguments the model wrote, as Go decodes them into a
  /// `SearchRequest`: keys match ignoring case, a missing or `null` value is
  /// unset. Throws a `ThreepioFormatException` with `encoding/json`'s text
  /// for a `query` that is not a string or a `pageno` that is not an integer
  /// (Go's tool decodes its arguments with sonic, whose messages differ; the
  /// failure is the same).
  factory SearxngSearchRequest.fromJson(Map<String, Object?> json) {
    final fields = GoJsonStruct(json, structName: 'SearchRequest');
    return SearxngSearchRequest(
      query: fields.string('query'),
      pageNo: fields.optionalInteger('pageno'),
    );
  }

  /// The search query (Go: `Query`); required.
  final String query;

  /// The page of the results, from 1 (Go: `PageNo`); `null` lets SearXNG
  /// answer with the first page.
  final int? pageNo;

  /// `{"query": …, "pageno": …}`, as Go writes it (`pageno` is `null` when
  /// unset).
  Map<String, Object?> toJson() => {'query': query, 'pageno': pageNo};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearxngSearchRequest &&
          other.query == query &&
          other.pageNo == pageNo;

  @override
  int get hashCode => Object.hash(query, pageNo);

  @override
  String toString() => 'SearxngSearchRequest(query: $query, pageNo: $pageNo)';
}

/// One hit of a SearXNG search.
///
/// Port of eino-ext `searxng.SearchResult` (JSON `title`, `content`, `url`,
/// `engine`, in that order).
@immutable
final class SearxngSearchResult {
  /// The hit [url] titled [title], with its [content], found by [engine].
  const SearxngSearchResult({
    this.title = '',
    this.content = '',
    this.url = '',
    this.engine = '',
  });

  /// Reads one result as Go decodes a `SearchResult`: the four fields,
  /// ignoring every other key SearXNG sends. Throws a
  /// `ThreepioFormatException` with Go's text when one of them is not a
  /// string.
  factory SearxngSearchResult.fromJson(Map<String, Object?> json) =>
      SearxngSearchResult._read(
        GoJsonStruct(json, structName: 'SearchResult'),
      );

  factory SearxngSearchResult._read(GoJsonStruct fields) => SearxngSearchResult(
        title: fields.string('title'),
        content: fields.string('content'),
        url: fields.string('url'),
        engine: fields.string('engine'),
      );

  /// The title of the page (Go: `Title`).
  final String title;

  /// The text SearXNG shows with the hit (Go: `Content`).
  final String content;

  /// The address of the page (Go: `URL`).
  final String url;

  /// The engine that found the hit (Go: `Engine`).
  final String engine;

  /// The hit in the shape every search tool shares: [content] is the
  /// snippet, and `extra` holds [engine] under `engine`.
  SearchResult toSearchResult() => SearchResult(
        title: title,
        url: url,
        snippet: content,
        extra: {'engine': engine},
      );

  /// `{"title": …, "content": …, "url": …, "engine": …}`, as Go writes it.
  Map<String, Object?> toJson() => {
        'title': title,
        'content': content,
        'url': url,
        'engine': engine,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearxngSearchResult &&
          other.title == title &&
          other.content == content &&
          other.url == url &&
          other.engine == engine;

  @override
  int get hashCode => Object.hash(title, content, url, engine);

  @override
  String toString() => 'SearxngSearchResult(title: $title, url: $url)';
}

/// The answer of a SearXNG search.
///
/// Port of eino-ext `searxng.SearchResponse` (JSON `query`,
/// `number_of_results`, `results`, in that order).
@immutable
final class SearxngSearchResponse {
  /// An answer to [query] with [results].
  const SearxngSearchResponse({
    this.query = '',
    this.numberOfResults = 0,
    this.results = const [],
  });

  /// Reads a SearXNG answer as Go's `json.Unmarshal` decodes it into a
  /// `SearchResponse`: the three fields (every other key is ignored), keys
  /// matching ignoring case, a missing or `null` value at its zero value. A
  /// `null` hit becomes an empty one (Go keeps a nil pointer, which it
  /// writes as `null`). Throws a `ThreepioFormatException` with Go's
  /// `UnmarshalTypeError` text when a value has the wrong type, for example
  /// `json: cannot unmarshal string into Go struct field
  /// SearchResponse.number_of_results of type int`.
  ///
  /// Unlike the client, this does not count the results when
  /// `number_of_results` is missing.
  factory SearxngSearchResponse.fromJson(Map<String, Object?> json) =>
      SearxngSearchResponse._read(
        GoJsonStruct(json, structName: 'SearchResponse'),
      );

  factory SearxngSearchResponse._read(GoJsonStruct fields) {
    final query = fields.string('query');
    final numberOfResults = fields.integer('number_of_results');
    final items = fields.list('results', goType: '[]*searxng.SearchResult');
    return SearxngSearchResponse(
      query: query,
      numberOfResults: numberOfResults,
      results: List.unmodifiable([
        for (final item in items ?? const <Object?>[])
          switch (fields.element(
            item,
            field: 'results',
            structName: 'SearchResult',
            goType: 'searxng.SearchResult',
          )) {
            null => const SearxngSearchResult(),
            final GoJsonStruct result => SearxngSearchResult._read(result),
          },
      ]),
    );
  }

  /// Reads the decoded JSON body [decoded] of a SearXNG answer (Go:
  /// `json.Unmarshal` into a `SearchResponse`): an object, or `null` for an
  /// empty answer; anything else fails with Go's text.
  @internal
  factory SearxngSearchResponse.fromDecoded(Object? decoded) {
    final fields = GoJsonStruct.top(
      decoded,
      structName: 'SearchResponse',
      goType: 'searxng.SearchResponse',
    );
    return fields == null
        ? const SearxngSearchResponse()
        : SearxngSearchResponse._read(fields);
  }

  /// The query SearXNG answered (Go: `Query`).
  final String query;

  /// How many results SearXNG reports (Go: `NumberOfResults`); the client
  /// counts [results] when SearXNG reports none.
  final int numberOfResults;

  /// The hits (Go: `Results`).
  final List<SearxngSearchResult> results;

  /// The hits in the shape every search tool shares.
  List<SearchResult> toSearchResults() =>
      [for (final result in results) result.toSearchResult()];

  /// A copy with [numberOfResults] replaced.
  SearxngSearchResponse copyWith({int? numberOfResults}) =>
      SearxngSearchResponse(
        query: query,
        numberOfResults: numberOfResults ?? this.numberOfResults,
        results: results,
      );

  /// `{"query": …, "number_of_results": …, "results": […]}`, as Go writes
  /// it.
  Map<String, Object?> toJson() => {
        'query': query,
        'number_of_results': numberOfResults,
        'results': [for (final result in results) result.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearxngSearchResponse &&
          other.query == query &&
          other.numberOfResults == numberOfResults &&
          _listEquals(other.results, results);

  @override
  int get hashCode =>
      Object.hash(query, numberOfResults, Object.hashAll(results));

  @override
  String toString() => 'SearxngSearchResponse(query: $query, '
      'numberOfResults: $numberOfResults, results: $results)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
