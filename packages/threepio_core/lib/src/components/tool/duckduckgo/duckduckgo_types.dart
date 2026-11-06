/// The values the DuckDuckGo text search tool works with.
///
/// Port of eino-ext `components/tool/duckduckgo/v2/model.go`.
library;

import 'package:meta/meta.dart';

import '../search_result.dart';
import 'go_wire.dart';

/// The region DuckDuckGo tailors its results to.
///
/// Port of eino-ext `duckduckgo.Region` and its constants. Go's `Region` is
/// an open string type: the static constants are the regions the Go package
/// names, and any other code DuckDuckGo understands (listed at
/// https://duckduckgo.com/duckduckgo-help-pages/settings/params/) can be
/// given with the constructor, as Go's `Region("es-es")` does:
///
/// ```dart
/// const spain = DuckDuckGoRegion('es-es');
/// ```
///
/// Two regions are equal when their [wireValue]s are.
@immutable
final class DuckDuckGoRegion {
  /// The region whose DuckDuckGo code is [wireValue] (`es-es`, for example).
  const DuckDuckGoRegion(this.wireValue);

  /// Every region, no local preference (Go: `RegionWT`, the default).
  static const DuckDuckGoRegion wt = DuckDuckGoRegion('wt-wt');

  /// The United States (Go: `RegionUS`).
  static const DuckDuckGoRegion us = DuckDuckGoRegion('us-en');

  /// The United Kingdom (Go: `RegionUK`).
  static const DuckDuckGoRegion uk = DuckDuckGoRegion('uk-en');

  /// Germany (Go: `RegionDE`).
  static const DuckDuckGoRegion de = DuckDuckGoRegion('de-de');

  /// France (Go: `RegionFR`).
  static const DuckDuckGoRegion fr = DuckDuckGoRegion('fr-fr');

  /// Japan (Go: `RegionJP`).
  static const DuckDuckGoRegion jp = DuckDuckGoRegion('jp-jp');

  /// China (Go: `RegionCN`).
  static const DuckDuckGoRegion cn = DuckDuckGoRegion('cn-zh');

  /// Russia (Go: `RegionRU`).
  static const DuckDuckGoRegion ru = DuckDuckGoRegion('ru-ru');

  /// The regions the Go package names, in its order.
  static const List<DuckDuckGoRegion> values = [wt, us, uk, de, fr, jp, cn, ru];

  /// The region code DuckDuckGo understands, `us-en` for example (the `kl`
  /// parameter of a search).
  final String wireValue;

  @override
  bool operator ==(Object other) =>
      other is DuckDuckGoRegion && other.wireValue == wireValue;

  @override
  int get hashCode => wireValue.hashCode;

  @override
  String toString() => 'DuckDuckGoRegion($wireValue)';
}

/// How recent the results must be.
///
/// Port of eino-ext `duckduckgo.TimeRange` and its constants. [wireValue] is
/// what the model writes in the tool's `time_range` argument and what
/// DuckDuckGo's `df` parameter takes.
enum DuckDuckGoTimeRange {
  /// The past day (Go: `TimeRangeDay`, `d`).
  day('d'),

  /// The past week (Go: `TimeRangeWeek`, `w`).
  week('w'),

  /// The past month (Go: `TimeRangeMonth`, `m`).
  month('m'),

  /// The past year (Go: `TimeRangeYear`, `y`).
  year('y'),

  /// Any time (Go: `TimeRangeAny`, the empty string; the default).
  any('');

  const DuckDuckGoTimeRange(this.wireValue);

  /// The value of the `time_range` argument and of the `df` parameter.
  final String wireValue;

  /// The time range whose [wireValue] is [value]; [any] for every other
  /// value, which is what Go's search does with a time range it does not
  /// know (it sends no time filter).
  static DuckDuckGoTimeRange fromWire(String value) {
    for (final range in values) {
      if (range.wireValue == value) return range;
    }
    return any;
  }
}

/// What the model asks the DuckDuckGo tool for: the arguments of a call.
///
/// Port of eino-ext `duckduckgo.TextSearchRequest` (JSON `query`,
/// `time_range`).
@immutable
final class DuckDuckGoTextSearchRequest {
  /// A search for [query] among results from [timeRange].
  const DuckDuckGoTextSearchRequest({
    required this.query,
    this.timeRange = DuckDuckGoTimeRange.any,
  });

  /// Reads the arguments the model wrote, as Go decodes them into a
  /// `TextSearchRequest`: keys match ignoring case, a missing or `null`
  /// value is empty, and an unknown time range counts as
  /// [DuckDuckGoTimeRange.any]. Throws a `ThreepioFormatException` with
  /// `encoding/json`'s text when a value is not a string (Go's tool decodes
  /// its arguments with sonic, whose messages differ; the failure is the
  /// same).
  factory DuckDuckGoTextSearchRequest.fromJson(Map<String, Object?> json) {
    final fields = GoJsonStruct(json, structName: 'TextSearchRequest');
    final query = fields.string('query');
    final timeRange =
        fields.string('time_range', goType: 'duckduckgo.TimeRange');
    return DuckDuckGoTextSearchRequest(
      query: query,
      timeRange: DuckDuckGoTimeRange.fromWire(timeRange),
    );
  }

  /// The search query (Go: `Query`); the search fails when it is empty.
  final String query;

  /// How recent the results must be (Go: `TimeRange`).
  final DuckDuckGoTimeRange timeRange;

  /// The arguments as the model writes them: `{"query": …, "time_range":
  /// …}`.
  Map<String, Object?> toJson() => {
        'query': query,
        'time_range': timeRange.wireValue,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DuckDuckGoTextSearchRequest &&
          other.query == query &&
          other.timeRange == timeRange;

  @override
  int get hashCode => Object.hash(query, timeRange);

  @override
  String toString() =>
      'DuckDuckGoTextSearchRequest(query: $query, timeRange: ${timeRange.name})';
}

/// One hit of a DuckDuckGo text search.
///
/// Port of eino-ext `duckduckgo.TextSearchResult` (JSON `title`, `url`,
/// `summary`, in that order).
@immutable
final class DuckDuckGoTextSearchResult {
  /// The hit [url] titled [title], with DuckDuckGo's [summary].
  const DuckDuckGoTextSearchResult({
    this.title = '',
    this.url = '',
    this.summary = '',
  });

  /// Reads the map written by [toJson], as Go decodes a `TextSearchResult`.
  /// Throws a `ThreepioFormatException` with Go's text when a value is not
  /// a string.
  factory DuckDuckGoTextSearchResult.fromJson(Map<String, Object?> json) =>
      DuckDuckGoTextSearchResult._read(
        GoJsonStruct(json, structName: 'TextSearchResult'),
      );

  factory DuckDuckGoTextSearchResult._read(GoJsonStruct fields) =>
      DuckDuckGoTextSearchResult(
        title: fields.string('title'),
        url: fields.string('url'),
        summary: fields.string('summary'),
      );

  /// The title of the page (Go: `Title`).
  final String title;

  /// The address of the page (Go: `URL`).
  final String url;

  /// The text DuckDuckGo shows with the hit (Go: `Summary`).
  final String summary;

  /// The hit in the shape every search tool shares: [summary] is the
  /// snippet.
  SearchResult toSearchResult() =>
      SearchResult(title: title, url: url, snippet: summary);

  /// `{"title": …, "url": …, "summary": …}`, as Go writes it.
  Map<String, Object?> toJson() => {
        'title': title,
        'url': url,
        'summary': summary,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DuckDuckGoTextSearchResult &&
          other.title == title &&
          other.url == url &&
          other.summary == summary;

  @override
  int get hashCode => Object.hash(title, url, summary);

  @override
  String toString() => 'DuckDuckGoTextSearchResult(title: $title, url: $url)';
}

/// The answer of a DuckDuckGo text search: a status message for the model
/// and the hits.
///
/// Port of eino-ext `duckduckgo.TextSearchResponse` (JSON `message`, and
/// `results` only when there are any: Go's `omitempty`).
@immutable
final class DuckDuckGoTextSearchResponse {
  /// An answer saying [message] with [results].
  const DuckDuckGoTextSearchResponse({
    required this.message,
    this.results = const [],
  });

  /// Reads the map written by [toJson] (the tool's answer, decoded), as Go
  /// decodes a `TextSearchResponse`; a `null` hit counts as an empty one.
  /// Throws a `ThreepioFormatException` with Go's text when a value has the
  /// wrong type.
  factory DuckDuckGoTextSearchResponse.fromJson(Map<String, Object?> json) {
    final fields = GoJsonStruct(json, structName: 'TextSearchResponse');
    final message = fields.string('message');
    final items =
        fields.list('results', goType: '[]*duckduckgo.TextSearchResult');
    return DuckDuckGoTextSearchResponse(
      message: message,
      results: [
        for (final item in items ?? const <Object?>[])
          switch (fields.element(
            item,
            field: 'results',
            structName: 'TextSearchResult',
            goType: 'duckduckgo.TextSearchResult',
          )) {
            null => const DuckDuckGoTextSearchResult(),
            final GoJsonStruct result =>
              DuckDuckGoTextSearchResult._read(result),
          },
      ],
    );
  }

  /// The status for the model (Go: `Message`): `Found 3 results
  /// successfully.` or `No good results were found.`
  final String message;

  /// The hits, at most `DuckDuckGoConfig.maxResults` of them (Go:
  /// `Results`).
  final List<DuckDuckGoTextSearchResult> results;

  /// The hits in the shape every search tool shares.
  List<SearchResult> toSearchResults() =>
      [for (final result in results) result.toSearchResult()];

  /// `{"message": …, "results": […]}`, as Go writes it; without `results`
  /// when there are none.
  Map<String, Object?> toJson() => {
        'message': message,
        if (results.isNotEmpty)
          'results': [for (final result in results) result.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DuckDuckGoTextSearchResponse &&
          other.message == message &&
          _listEquals(other.results, results);

  @override
  int get hashCode => Object.hash(message, Object.hashAll(results));

  @override
  String toString() =>
      'DuckDuckGoTextSearchResponse(message: $message, results: $results)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
