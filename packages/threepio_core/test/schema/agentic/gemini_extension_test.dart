// Port of eino `schema/gemini/extension_test.go` (v0.9.22), all cases.

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

void main() {
  group('TestConcatResponseMetaExtensions', () {
    test('multiple extensions - takes last non-empty values', () {
      final meta1 = GeminiGroundingMetadata(webSearchQueries: const ['query1']);
      final meta2 = GeminiGroundingMetadata(webSearchQueries: const ['query2']);

      final result = concatGeminiResponseMetaExtensions([
        GeminiResponseMetaExtension(
          id: 'resp_1',
          finishReason: 'STOP',
          groundingMeta: meta1,
        ),
        const GeminiResponseMetaExtension(id: 'resp_2'),
        GeminiResponseMetaExtension(
          finishReason: 'MAX_TOKENS',
          groundingMeta: meta2,
        ),
      ]);
      expect(result.id, 'resp_2');
      expect(result.finishReason, 'MAX_TOKENS');
      expect(result.groundingMeta, meta2);
    });

    test('streaming scenario', () {
      final meta = GeminiGroundingMetadata(
        groundingChunks: const [
          GeminiGroundingChunk(
            web: GeminiGroundingChunkWeb(
              title: 'Example',
              uri: 'https://example.com',
            ),
          ),
        ],
      );

      final result = concatGeminiResponseMetaExtensions([
        const GeminiResponseMetaExtension(id: 'stream_123'),
        const GeminiResponseMetaExtension(),
        GeminiResponseMetaExtension(finishReason: 'STOP', groundingMeta: meta),
      ]);
      expect(result.id, 'stream_123');
      expect(result.finishReason, 'STOP');
      expect(result.groundingMeta, meta);
    });

    test('a single extension is returned as it is; none is an error', () {
      const only = GeminiResponseMetaExtension(id: 'x');
      expect(concatGeminiResponseMetaExtensions(const [only]), same(only));
      expect(() => concatGeminiResponseMetaExtensions([]), throwsArgumentError);
    });
  });
}
