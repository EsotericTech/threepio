// Port of eino `components/embedding/option_test.go` (TestOptions) and
// `callback_extra_test.go` (TestConvEmbedding).
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

void main() {
  group('TestOptions', () {
    test('the model of a call replaces the default model', () {
      final options = const EmbedderOptions(model: 'default_model')
          .merge(const EmbedderOptions(model: 'test_model'));

      expect(options.model, isNotNull);
      expect(options.model, 'test_model');
    });

    test('a call without a model keeps the default', () {
      const base = EmbedderOptions(model: 'default_model');

      expect(base.merge(const EmbedderOptions()).model, 'default_model');
      expect(base.merge(null), same(base));
    });
  });

  group('EmbedderOptions', () {
    test('carries the run context and extensions', () {
      final ctx = RunContext.background();
      const empty = EmbedderOptions();
      expect(empty.runContext, isNull);
      expect(empty.extensions, isEmpty);

      final options = const EmbedderOptions(model: 'm', extra: {'dimensions': 256})
          .copyWith(runContext: ctx, extensions: const ['mine']);
      expect(options.model, 'm');
      expect(options.extra, {'dimensions': 256});
      expect(options.runContext, same(ctx));
      expect(options.extension<String>(), 'mine');

      final merged = options.merge(const EmbedderOptions(extensions: ['theirs']));
      expect(merged.extension<String>(), 'theirs');
      expect(merged.extensions, ['theirs', 'mine']);
      expect(merged.runContext, same(ctx));
      expect(merged.extra, {'dimensions': 256});
    });
  });

  group('TestConvEmbedding', () {
    test('EmbeddingCallbackInput.from', () {
      const input = EmbeddingCallbackInput(texts: []);
      expect(EmbeddingCallbackInput.from(input), same(input));
      expect(EmbeddingCallbackInput.from(<String>[]), isNotNull);
      expect(EmbeddingCallbackInput.from('asd'), isNull);
    });

    test('EmbeddingCallbackOutput.from', () {
      const output = EmbeddingCallbackOutput(embeddings: []);
      expect(EmbeddingCallbackOutput.from(output), same(output));
      expect(EmbeddingCallbackOutput.from(<List<double>>[]), isNotNull);
      expect(EmbeddingCallbackOutput.from('asd'), isNull);
    });

    test('the plain values a graph node reports are wrapped', () {
      final texts = ['a', 'b'];
      final input = EmbeddingCallbackInput.from(texts)!;
      expect(input.texts, same(texts));
      expect(input.config, isNull);

      final vectors = [
        [0.1, 0.2],
        [0.3, 0.4],
      ];
      final output = EmbeddingCallbackOutput.from(vectors)!;
      expect(output.embeddings, same(vectors));
      expect(output.tokenUsage, isNull);
    });

    test('an embedder reports its settings and its usage', () {
      const config =
          EmbeddingCallbackConfig(model: 'text-embedding-3', encodingFormat: 'float');
      const usage = TokenUsage(promptTokens: 8, completionTokens: 0, totalTokens: 8);

      const input = EmbeddingCallbackInput(
        texts: ['a'],
        config: config,
        extra: {'batch': 1},
      );
      const output = EmbeddingCallbackOutput(
        embeddings: [
          [0.1],
        ],
        config: config,
        tokenUsage: usage,
      );

      expect(input.config?.model, 'text-embedding-3');
      expect(input.config?.encodingFormat, 'float');
      expect(input.extra, {'batch': 1});
      expect(output.tokenUsage?.totalTokens, 8);
      expect(output.config, same(config));
      expect(output.toString(), contains('embeddings: 1'));
    });

    test('EmbeddingCallbackConfig.fromOptions reads the options of a call',
        () {
      expect(
        EmbeddingCallbackConfig.fromOptions(
          const EmbedderOptions(model: 'named'),
          defaultModel: 'default',
          encodingFormat: 'float',
        ).model,
        'named',
      );
      final byDefault = EmbeddingCallbackConfig.fromOptions(
        null,
        defaultModel: 'default',
        encodingFormat: 'base64',
      );
      expect(byDefault.model, 'default');
      expect(byDefault.encodingFormat, 'base64');
    });
  });
}
