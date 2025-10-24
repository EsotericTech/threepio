import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openrouter/openrouter_config.dart';

void main() {
  group('OpenRouterConfig', () {
    test('creates config with required parameters', () {
      final config = OpenRouterConfig(
        apiKey: 'test-key',
      );

      expect(config.apiKey, equals('test-key'));
      expect(config.baseUrl, equals('https://openrouter.ai/api/v1'));
      expect(config.defaultModel, equals('google/gemini-2.5-flash'));
      expect(config.timeout, equals(const Duration(seconds: 60)));
      expect(config.includeRawResponse, isFalse);
    });

    test('creates config with all parameters', () {
      final config = OpenRouterConfig(
        apiKey: 'test-key',
        baseUrl: 'https://custom.openrouter.ai/api/v1',
        defaultModel: 'openai/gpt-4',
        siteName: 'My App',
        siteUrl: 'https://myapp.com',
        timeout: const Duration(seconds: 120),
        includeRawResponse: true,
        transforms: {'key': 'value'},
      );

      expect(config.apiKey, equals('test-key'));
      expect(config.baseUrl, equals('https://custom.openrouter.ai/api/v1'));
      expect(config.defaultModel, equals('openai/gpt-4'));
      expect(config.siteName, equals('My App'));
      expect(config.siteUrl, equals('https://myapp.com'));
      expect(config.timeout, equals(const Duration(seconds: 120)));
      expect(config.includeRawResponse, isTrue);
      expect(config.transforms, equals({'key': 'value'}));
    });

    test('copyWith creates modified copy', () {
      final config = OpenRouterConfig(
        apiKey: 'test-key',
        defaultModel: 'openai/gpt-4',
      );

      final modified = config.copyWith(
        defaultModel: 'google/gemini-2.5-flash',
        siteName: 'New App',
      );

      expect(modified.apiKey, equals('test-key'));
      expect(modified.defaultModel, equals('google/gemini-2.5-flash'));
      expect(modified.siteName, equals('New App'));
      expect(modified.baseUrl, equals(config.baseUrl));
    });

    test('copyWith preserves original when no changes', () {
      final config = OpenRouterConfig(
        apiKey: 'test-key',
        siteName: 'My App',
      );

      final copy = config.copyWith();

      expect(copy.apiKey, equals(config.apiKey));
      expect(copy.siteName, equals(config.siteName));
      expect(copy.defaultModel, equals(config.defaultModel));
    });
  });
}
