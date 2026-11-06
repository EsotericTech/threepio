// Port of eino-ext `components/document/parser/pdf/pdf_parser_test.go`
// (TestLoader_Load) through a fake PdfTextExtractor: Dart has no PDF text
// extraction, so the parser is given one (the Go test reads a 54 KB PDF with
// ledongthuc/pdf; the fake returns the text of two pages instead). Tests
// written for the port: Go's output shape (pages, or one document with
// "\n" after every page; metadata = the call's extra metadata only, no ids),
// toPages from the config and from PdfParserOptions, the errors with Go's
// messages (`pdf_parser.go`), and cancellations and interrupts passing
// through.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/parser/pdf_parser.dart';
import 'package:threepio_core/threepio_core.dart';

/// Returns [pages] or throws [error]; records what it gets.
final class _FakeExtractor implements PdfTextExtractor {
  _FakeExtractor({this.pages = const ['page one', 'page two'], this.error});

  final List<String> pages;
  final Object? error;
  final List<RunContext> contexts = [];
  final List<Uint8List> inputs = [];

  @override
  Future<List<String>> extractPageTexts(RunContext ctx, Uint8List pdfBytes) async {
    contexts.add(ctx);
    inputs.add(pdfBytes);
    final error = this.error;
    if (error != null) throw error;
    return pages;
  }
}

final class _Interrupt implements InterruptSignal {
  const _Interrupt();
}

Stream<List<int>> _pdf() => Stream.value('%PDF-1.4 fake'.codeUnits);

void main() {
  final ctx = RunContext.background();

  group('TestLoader_Load', () {
    test('TestLoader_Load', () async {
      final p = PdfParser(extractor: _FakeExtractor());

      final docs = await p.parse(
        ctx,
        _pdf(),
        options: const ParserOptions(
          extraMeta: {'test': 'test'},
          extensions: [PdfParserOptions(toPages: true)],
        ),
      );

      expect(docs, hasLength(2));
      expect(docs[0].content, isNotEmpty);
      expect(docs[0].metadata, {'test': 'test'});
      expect(docs[1].content, isNotEmpty);
      expect(docs[1].metadata, {'test': 'test'});
    });
  });

  group('the output', () {
    test('a document per page, with the page text as it is', () async {
      final docs = await PdfParser(
        extractor: _FakeExtractor(pages: const ['  one  ', '', 'three']),
        config: const PdfParserConfig(toPages: true),
      ).parse(ctx, _pdf());

      expect(docs.map((d) => d.content), ['  one  ', '', 'three']);
      for (final doc in docs) {
        expect(doc.id, isNull);
        expect(doc.metadata, isEmpty);
      }
    });

    test('by default one document: every page followed by a newline',
        () async {
      final docs = await PdfParser(extractor: _FakeExtractor()).parse(
        ctx,
        _pdf(),
        options: const ParserOptions(uri: 'report.pdf', extraMeta: {'k': 1}),
      );

      expect(docs.single.content, 'page one\npage two\n');
      // Only the extra metadata: no source, as in Go.
      expect(docs.single.metadata, {'k': 1});
      expect(docs.single.id, isNull);
    });

    test('a file without pages', () async {
      final none = _FakeExtractor(pages: const []);

      expect(
        await PdfParser(extractor: none, config: const PdfParserConfig(toPages: true))
            .parse(ctx, _pdf()),
        isEmpty,
      );
      expect(
        (await PdfParser(extractor: none).parse(ctx, _pdf())).single.content,
        '',
      );
    });

    test('the option of the call overrides the configuration', () async {
      final parser = PdfParser(
        extractor: _FakeExtractor(),
        config: const PdfParserConfig(toPages: true),
      );

      final whole = await parser.parse(
        ctx,
        _pdf(),
        options: const ParserOptions(extensions: [PdfParserOptions(toPages: false)]),
      );
      final pages = await parser.parse(
        ctx,
        _pdf(),
        options: const ParserOptions(extensions: [PdfParserOptions()]),
      );

      expect(whole, hasLength(1));
      expect(pages, hasLength(2));
    });

    test('the extractor gets all the bytes and the context', () async {
      final extractor = _FakeExtractor();

      await PdfParser(extractor: extractor).parse(
        ctx,
        Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      );

      expect(extractor.inputs.single, [1, 2, 3]);
      expect(extractor.contexts.single, same(ctx));
    });

    test('works under ExtParser', () async {
      final parser = ExtParser(parsers: {'.pdf': PdfParser(extractor: _FakeExtractor())});

      final docs = await parser.parse(
        ctx,
        _pdf(),
        options: const ParserOptions(uri: 'a/b.pdf', extraMeta: {'k': 'v'}),
      );

      expect(docs.single.content, 'page one\npage two\n');
      expect(docs.single.metadata, {'k': 'v'});
    });

    test('is a plain Parser, without a type name (Go has no GetType)', () {
      final parser = PdfParser(extractor: _FakeExtractor());
      expect(parser, isA<Parser>());
      expect(parser, isNot(isA<TypedComponent>()));
    });
  });

  group('errors, with Go\'s messages', () {
    test('an extractor that cannot read the file', () async {
      const error = ThreepioException('malformed PDF');

      await expectLater(
        PdfParser(extractor: _FakeExtractor(error: error)).parse(ctx, _pdf()),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'create new pdf reader failed: malformed PDF')
              .having((e) => e.cause, 'cause', same(error)),
        ),
      );
      await expectLater(
        PdfParser(extractor: _FakeExtractor(error: const FormatException('no xref')))
            .parse(ctx, _pdf()),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'create new pdf reader failed: no xref'),
        ),
      );
    });

    test('a byte stream that fails', () async {
      const error = ThreepioException('disk gone');

      await expectLater(
        PdfParser(extractor: _FakeExtractor()).parse(ctx, Stream.error(error)),
        throwsA(
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                'pdf parser read all from reader failed: disk gone',
              )
              .having((e) => e.cause, 'cause', same(error)),
        ),
      );
    });

    test('cancellations and interrupts get through', () async {
      for (final error in [const CancelledException('stop'), const _Interrupt()]) {
        await expectLater(
          PdfParser(extractor: _FakeExtractor(error: error)).parse(ctx, _pdf()),
          throwsA(same(error)),
        );
        await expectLater(
          PdfParser(extractor: _FakeExtractor()).parse(ctx, Stream.error(error)),
          throwsA(same(error)),
        );
      }
    });
  });
}
