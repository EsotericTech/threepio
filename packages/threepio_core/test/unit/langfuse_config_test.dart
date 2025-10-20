import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/observability/langfuse/langfuse_config.dart';

void main() {
  group('LangfuseConfig', () {
    test('creates config with required fields', () {
      final config = LangfuseConfig(
        host: 'https://cloud.langfuse.com',
        publicKey: 'pk-test-123',
        secretKey: 'sk-test-456',
      );

      expect(config.host, 'https://cloud.langfuse.com');
      expect(config.publicKey, 'pk-test-123');
      expect(config.secretKey, 'sk-test-456');
    });

    test('uses default values for optional fields', () {
      final config = LangfuseConfig(
        host: 'https://cloud.langfuse.com',
        publicKey: 'pk-test',
        secretKey: 'sk-test',
      );

      expect(config.threads, 1);
      expect(config.timeout, const Duration(seconds: 30));
      expect(config.maxTaskQueueSize, 100);
      expect(config.flushAt, 15);
      expect(config.flushInterval, const Duration(milliseconds: 500));
      expect(config.sampleRate, 1.0);
      expect(config.maxRetry, 3);
      expect(config.sdkName, 'Dart');
      expect(config.sdkVersion, '0.1.0');
      expect(config.sdkIntegration, 'threepio');
    });

    test('allows custom values for optional fields', () {
      final config = LangfuseConfig(
        host: 'https://cloud.langfuse.com',
        publicKey: 'pk-test',
        secretKey: 'sk-test',
        threads: 4,
        timeout: const Duration(seconds: 60),
        maxTaskQueueSize: 200,
        flushAt: 30,
        flushInterval: const Duration(seconds: 1),
        sampleRate: 0.5,
        maxRetry: 5,
        defaultTraceName: 'my-trace',
        defaultUserId: 'user-123',
        defaultSessionId: 'session-456',
        defaultRelease: 'v1.0.0',
        defaultTags: ['production', 'api'],
      );

      expect(config.threads, 4);
      expect(config.timeout, const Duration(seconds: 60));
      expect(config.maxTaskQueueSize, 200);
      expect(config.flushAt, 30);
      expect(config.flushInterval, const Duration(seconds: 1));
      expect(config.sampleRate, 0.5);
      expect(config.maxRetry, 5);
      expect(config.defaultTraceName, 'my-trace');
      expect(config.defaultUserId, 'user-123');
      expect(config.defaultSessionId, 'session-456');
      expect(config.defaultRelease, 'v1.0.0');
      expect(config.defaultTags, ['production', 'api']);
    });

    test('generates correct Basic Auth header', () {
      final config = LangfuseConfig(
        host: 'https://cloud.langfuse.com',
        publicKey: 'pk-test',
        secretKey: 'sk-test',
      );

      final expectedCredentials = 'pk-test:sk-test';
      final expectedEncoded = base64Encode(utf8.encode(expectedCredentials));
      final expectedHeader = 'Basic $expectedEncoded';

      expect(config.basicAuthHeader, expectedHeader);
    });

    test('generates batch metadata correctly', () {
      final config = LangfuseConfig(
        host: 'https://cloud.langfuse.com',
        publicKey: 'pk-test',
        secretKey: 'sk-test',
      );

      final metadata = config.getBatchMetadata(10);

      expect(metadata['batch_size'], '10');
      expect(metadata['sdk_integration'], 'threepio');
      expect(metadata['sdk_name'], 'Dart');
      expect(metadata['sdk_version'], '0.1.0');
      expect(metadata['public_key'], 'pk-test');
    });

    test('allows custom maskFunc', () {
      String maskSensitiveData(String data) {
        return data.replaceAll(RegExp(r'\d{16}'), '****');
      }

      final config = LangfuseConfig(
        host: 'https://cloud.langfuse.com',
        publicKey: 'pk-test',
        secretKey: 'sk-test',
        maskFunc: maskSensitiveData,
      );

      expect(config.maskFunc, isNotNull);
      final masked = config.maskFunc!('Card: 1234567890123456');
      expect(masked, 'Card: ****');
    });
  });
}
