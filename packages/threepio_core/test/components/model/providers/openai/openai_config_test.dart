import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_config.dart';

void main() {
  group('OpenAIConfig', () {
    test('creates config with required parameters', () {
      final config = OpenAIConfig(apiKey: 'test-key');

      expect(config.apiKey, equals('test-key'));
      expect(config.baseUrl, equals('https://api.openai.com/v1'));
      expect(config.defaultModel, equals('gpt-4o-mini'));
      expect(config.timeout, equals(const Duration(seconds: 60)));
      expect(config.organization, isNull);
    });

    test('creates config with all parameters', () {
      final config = OpenAIConfig(
        apiKey: 'test-key',
        baseUrl: 'https://custom.api.com/v1',
        organization: 'org-123',
        defaultModel: 'gpt-4',
        timeout: const Duration(seconds: 120),
      );

      expect(config.apiKey, equals('test-key'));
      expect(config.baseUrl, equals('https://custom.api.com/v1'));
      expect(config.organization, equals('org-123'));
      expect(config.defaultModel, equals('gpt-4'));
      expect(config.timeout, equals(const Duration(seconds: 120)));
    });

    test('fromEnvironment throws when API key is missing', () {
      expect(
        () => OpenAIConfig.fromEnvironment(apiKey: ''),
        throwsArgumentError,
      );
    });

    test('fromEnvironment creates config with provided values', () {
      final config = OpenAIConfig.fromEnvironment(
        apiKey: 'env-key',
        baseUrl: 'https://env.api.com/v1',
        organization: 'env-org',
        defaultModel: 'gpt-4-turbo',
      );

      expect(config.apiKey, equals('env-key'));
      expect(config.baseUrl, equals('https://env.api.com/v1'));
      expect(config.organization, equals('env-org'));
      expect(config.defaultModel, equals('gpt-4-turbo'));
    });

    test('copyWith creates new config with updated values', () {
      final original = OpenAIConfig(
        apiKey: 'original-key',
        baseUrl: 'https://original.com',
        defaultModel: 'gpt-3.5-turbo',
      );

      final updated = original.copyWith(
        apiKey: 'updated-key',
        defaultModel: 'gpt-4',
      );

      expect(updated.apiKey, equals('updated-key'));
      expect(updated.baseUrl, equals('https://original.com'));
      expect(updated.defaultModel, equals('gpt-4'));
    });

    test('copyWith preserves original when no changes', () {
      final original = OpenAIConfig(
        apiKey: 'test-key',
        organization: 'test-org',
      );

      final copy = original.copyWith();

      expect(copy.apiKey, equals(original.apiKey));
      expect(copy.baseUrl, equals(original.baseUrl));
      expect(copy.organization, equals(original.organization));
      expect(copy.defaultModel, equals(original.defaultModel));
      expect(copy.timeout, equals(original.timeout));
    });
  });
}
