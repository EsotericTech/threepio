// Port of eino `components/document/option_test.go` (TestImplSpecificOpts,
// TestCommonOptions), and tests for the callback payloads of loaders and
// transformers (`callback_extra_loader.go`, `callback_extra_transformer.go`).
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// `implSpecificOptions` of the Go test.
final class _ImplSpecificOptions {
  const _ImplSpecificOptions({this.conf = '', this.index = 0});

  final String conf;
  final int index;
}

void main() {
  group('TestImplSpecificOpts', () {
    test('TestLoaderImplSpecificOpts', () {
      const options = LoaderOptions(
        extensions: [_ImplSpecificOptions(conf: 'test_conf', index: 1)],
      );

      final own = options.extension<_ImplSpecificOptions>();
      expect(own?.conf, 'test_conf');
      expect(own?.index, 1);
      expect(const LoaderOptions().extension<_ImplSpecificOptions>(), isNull);
    });

    test('TestTransformerImplSpecificOpts', () {
      const options = TransformerOptions(
        extensions: [_ImplSpecificOptions(conf: 'test_conf', index: 1)],
      );

      final own = options.extension<_ImplSpecificOptions>();
      expect(own?.conf, 'test_conf');
      expect(own?.index, 1);
      expect(
        const TransformerOptions().extension<_ImplSpecificOptions>(),
        isNull,
      );
    });
  });

  group('TestCommonOptions', () {
    test('parser options stay when the call brings none', () {
      const base = LoaderOptions(parserOptions: ParserOptions(uri: 'a.md'));

      expect(base.merge(null).parserOptions?.uri, 'a.md');
      expect(base.merge(const LoaderOptions()).parserOptions?.uri, 'a.md');
    });

    test('parser options of the call replace the ones of the base', () {
      const base = LoaderOptions(
        parserOptions: ParserOptions(uri: 'a.md', extraMeta: {'k': 1}),
      );

      final merged = base.merge(
        const LoaderOptions(parserOptions: ParserOptions(uri: 'b.md')),
      );

      // Replaced as a whole, as WithParserOptions does.
      expect(merged.parserOptions?.uri, 'b.md');
      expect(merged.parserOptions?.extraMeta, isNull);
    });
  });

  group('LoaderOptions', () {
    test('copyWith and merge', () {
      const options = LoaderOptions(extensions: ['base']);

      final copy =
          options.copyWith(parserOptions: const ParserOptions(uri: 'x.txt'));
      expect(copy.parserOptions?.uri, 'x.txt');
      expect(copy.extensions, ['base']);

      final merged = copy.merge(const LoaderOptions(extensions: ['call']));
      expect(merged.extensions, ['call', 'base']);
      expect(merged.extension<String>(), 'call');
      expect(merged.parserOptions?.uri, 'x.txt');
    });
  });

  group('TransformerOptions', () {
    test('carries the run context', () {
      final ctx = RunContext.background();
      const empty = TransformerOptions();
      expect(empty.runContext, isNull);
      expect(empty.extensions, isEmpty);

      final withContext = empty.copyWith(runContext: ctx);
      expect(withContext.runContext, same(ctx));

      final merged = withContext.merge(
        const TransformerOptions(extensions: [_ImplSpecificOptions(index: 2)]),
      );
      expect(merged.runContext, same(ctx));
      expect(merged.extension<_ImplSpecificOptions>()?.index, 2);
      expect(withContext.merge(null), same(withContext));

      final other = RunContext.background();
      expect(
        withContext.merge(TransformerOptions(runContext: other)).runContext,
        same(other),
      );
    });
  });

  group('loader callback payloads', () {
    const source = DocumentSource(uri: 'https://example.com/a.md');
    final docs = [Document.simple('a')];

    test('LoaderCallbackInput.from', () {
      const input = LoaderCallbackInput(source: source, extra: {'k': 1});
      expect(LoaderCallbackInput.from(input), same(input));
      expect(input.extra, {'k': 1});

      expect(LoaderCallbackInput.from(source)?.source, source);
      expect(LoaderCallbackInput.from('https://example.com'), isNull);
      expect(LoaderCallbackInput.from(null), isNull);
      expect(input.toString(), contains('https://example.com/a.md'));
    });

    test('LoaderCallbackOutput.from', () {
      final output = LoaderCallbackOutput(source: source, docs: docs);
      expect(LoaderCallbackOutput.from(output), same(output));
      expect(output.source, source);

      final fromDocs = LoaderCallbackOutput.from(docs)!;
      expect(fromDocs.docs, same(docs));
      expect(fromDocs.source, isNull);

      expect(LoaderCallbackOutput.from(<Document>[]), isNotNull);
      expect(LoaderCallbackOutput.from('asd'), isNull);
    });
  });

  group('transformer callback payloads', () {
    final docs = [Document.simple('a'), Document.simple('b')];

    test('TransformerCallbackInput.from', () {
      final input = TransformerCallbackInput(input: docs);
      expect(TransformerCallbackInput.from(input), same(input));

      expect(TransformerCallbackInput.from(docs)?.input, same(docs));
      expect(TransformerCallbackInput.from(<Document>[]), isNotNull);
      expect(TransformerCallbackInput.from('asd'), isNull);
      expect(TransformerCallbackInput.from(<String>['a']), isNull);
    });

    test('TransformerCallbackOutput.from', () {
      final output = TransformerCallbackOutput(output: docs, extra: const {'n': 2});
      expect(TransformerCallbackOutput.from(output), same(output));
      expect(output.extra, {'n': 2});

      expect(TransformerCallbackOutput.from(docs)?.output, same(docs));
      expect(TransformerCallbackOutput.from(42), isNull);
    });
  });
}
