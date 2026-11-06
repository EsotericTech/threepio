/// The common shape of a web search hit.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// One hit of a web search, the same for every search tool.
///
/// The search tools of eino-ext (`googlesearch`, `duckduckgo/v2`, `searxng`,
/// `wikipedia`) each answer the model with their own JSON, and threepio's
/// ports keep those answers byte for byte. Code that calls a search tool
/// directly gets the hits in this one shape instead, whichever engine found
/// them:
///
/// * [title] and [url] are the title and the address of the page;
/// * [snippet] is the short text the engine shows with the hit: Google's
///   `snippet`, DuckDuckGo's `summary`, SearXNG's `content`, Wikipedia's
///   `snippet`;
/// * [extra] holds what one engine reports beyond those, under the key that
///   engine's tool uses in its answer (Google's `desc`, SearXNG's `engine`,
///   Wikipedia's `extract`).
///
/// threepio-only: Eino has no common type for this.
@immutable
final class SearchResult {
  /// A hit for the page [url] titled [title].
  const SearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
    this.extra = const {},
  });

  /// Reads the map written by [toJson]. A missing field, or one that is not
  /// of its type, is empty.
  factory SearchResult.fromJson(Map<String, Object?> json) => SearchResult(
        title: _string(json['title']),
        url: _string(json['url']),
        snippet: _string(json['snippet']),
        extra: switch (json['extra']) {
          final Map<String, Object?> extra => Map.unmodifiable(extra),
          _ => const {},
        },
      );

  /// The title of the page.
  final String title;

  /// The address of the page.
  final String url;

  /// The text the engine shows with the hit; empty when it shows none.
  final String snippet;

  /// What the engine reports beyond [title], [url] and [snippet], as
  /// JSON-compatible values.
  final Map<String, Object?> extra;

  /// A JSON-compatible map; [SearchResult.fromJson] reads it back.
  Map<String, Object?> toJson() => {
        'title': title,
        'url': url,
        if (snippet.isNotEmpty) 'snippet': snippet,
        if (extra.isNotEmpty) 'extra': extra,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchResult &&
          other.title == title &&
          other.url == url &&
          other.snippet == snippet &&
          const DeepCollectionEquality().equals(other.extra, extra);

  @override
  int get hashCode => Object.hash(
        title,
        url,
        snippet,
        const DeepCollectionEquality().hash(extra),
      );

  @override
  String toString() => 'SearchResult(title: $title, url: $url)';

  static String _string(Object? value) => value is String ? value : '';
}
