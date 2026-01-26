import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_config.dart';

void main() {
  group('GeminiConfig', () {
    test('creates with required apiKey', () {
      final config = GeminiConfig(apiKey: 'test-api-key');

      expect(config.apiKey, equals('test-api-key'));
      expect(
        config.baseUrl,
        equals('https://generativelanguage.googleapis.com/v1beta'),
      );
      expect(config.defaultModel, equals('gemini-2.5-flash'));
      expect(config.timeout, equals(const Duration(seconds: 120)));
    });

    test('creates with all parameters', () {
      final config = GeminiConfig(
        apiKey: 'test-api-key',
        baseUrl: 'https://custom.api.com',
        defaultModel: 'gemini-2.5-pro',
        timeout: const Duration(seconds: 60),
      );

      expect(config.apiKey, equals('test-api-key'));
      expect(config.baseUrl, equals('https://custom.api.com'));
      expect(config.defaultModel, equals('gemini-2.5-pro'));
      expect(config.timeout, equals(const Duration(seconds: 60)));
    });

    test('copyWith creates new config with updated values', () {
      final original = GeminiConfig(apiKey: 'original-key');
      final updated = original.copyWith(
        apiKey: 'new-key',
        defaultModel: 'gemini-3-flash-preview',
      );

      expect(updated.apiKey, equals('new-key'));
      expect(updated.defaultModel, equals('gemini-3-flash-preview'));
      expect(updated.baseUrl, equals(original.baseUrl));
      expect(updated.timeout, equals(original.timeout));
    });

    test('copyWith preserves original values when not specified', () {
      final original = GeminiConfig(
        apiKey: 'test-key',
        baseUrl: 'https://custom.api.com',
        defaultModel: 'gemini-2.5-pro',
        timeout: const Duration(seconds: 90),
      );

      final updated = original.copyWith();

      expect(updated.apiKey, equals(original.apiKey));
      expect(updated.baseUrl, equals(original.baseUrl));
      expect(updated.defaultModel, equals(original.defaultModel));
      expect(updated.timeout, equals(original.timeout));
    });

    test('toString provides meaningful representation', () {
      final config = GeminiConfig(
        apiKey: 'test-key',
        defaultModel: 'gemini-2.5-pro',
      );

      final str = config.toString();

      expect(str, contains('GeminiConfig'));
      expect(str, contains('gemini-2.5-pro'));
      expect(str, isNot(contains('test-key'))); // API key should not be exposed
    });
  });

  group('GeminiConfigException', () {
    test('creates with message', () {
      final exception = GeminiConfigException('Test error');

      expect(exception.message, equals('Test error'));
    });

    test('toString includes message', () {
      final exception = GeminiConfigException('Configuration error');

      expect(
        exception.toString(),
        equals('GeminiConfigException: Configuration error'),
      );
    });
  });
}
