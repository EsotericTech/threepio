// Tests of SearchResult (lib/src/components/tool/search_result.dart), the
// common shape of a web search hit that every P12 search tool also returns.
// threepio-only (Eino has no such type).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/search_result.dart';

void main() {
  group('SearchResult', () {
    test('defaults', () {
      const hit = SearchResult(title: 't', url: 'https://example.com');
      expect(hit.snippet, '');
      expect(hit.extra, isEmpty);
      expect(hit.toJson(), {'title': 't', 'url': 'https://example.com'});
      expect(hit.toString(), 'SearchResult(title: t, url: https://example.com)');
    });

    test('JSON round trip with snippet and extra', () {
      const hit = SearchResult(
        title: 'Eino',
        url: 'https://github.com/cloudwego/eino',
        snippet: 'The LLM application framework',
        extra: {
          'engine': 'google',
          'nested': {
            'n': 1,
            'list': [true, null, 'x'],
          },
        },
      );
      final json = jsonDecode(jsonEncode(hit.toJson())) as Map<String, Object?>;
      expect(json.keys, ['title', 'url', 'snippet', 'extra']);
      final back = SearchResult.fromJson(json);
      expect(back, hit);
      expect(back.hashCode, hit.hashCode);
      expect(() => back.extra['x'] = 1, throwsUnsupportedError);
    });

    test('fromJson tolerates missing and mistyped fields', () {
      final hit = SearchResult.fromJson(const {'title': 3, 'extra': 'no'});
      expect(hit, const SearchResult(title: '', url: ''));
    });

    test('equality looks into extra', () {
      const a = SearchResult(title: 't', url: 'u', extra: {'k': [1, 2]});
      const b = SearchResult(title: 't', url: 'u', extra: {'k': [1, 2]});
      const c = SearchResult(title: 't', url: 'u', extra: {'k': [2, 1]});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(const SearchResult(title: 't', url: 'u', snippet: 's')));
      expect(a, isNot(const SearchResult(title: 'T', url: 'u')));
      expect(a, isNot(const SearchResult(title: 't', url: 'U')));
    });
  });
}
