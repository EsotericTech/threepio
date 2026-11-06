/// eino-ext's PDF parser, with the text extraction left to an injected
/// extractor.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/parser_utils.dart';
import '../../../schema/document.dart';
import '../../model/cancel_token.dart';
import 'go_text.dart';
import 'parser.dart';

/// Extracts the plain text of the pages of a PDF file.
///
/// There is no pure-Dart PDF text extraction of acceptable quality, so
/// [PdfParser] does not read PDF files itself: it is given an extractor (a
/// plugin around pdfium or PDFKit, a server, a test fake). eino-ext uses
/// `github.com/ledongthuc/pdf` here, page by page with `Page.GetPlainText`.
// ignore: one_member_abstracts
abstract interface class PdfTextExtractor {
  /// The plain text of every page of the PDF file in [pdfBytes], in page
  /// order: one string per page.
  ///
  /// [ctx] is the context of the parse call. Throws when the bytes cannot be
  /// read as a PDF file or a page cannot be extracted.
  Future<List<String>> extractPageTexts(RunContext ctx, Uint8List pdfBytes);
}

/// The configuration of [PdfParser].
///
/// Port of eino-ext `pdf.Config`.
@immutable
final class PdfParserConfig {
  /// A configuration.
  const PdfParserConfig({this.toPages = false});

  /// Whether every page becomes a document of its own (Go: `ToPages`). The
  /// default returns one document for the whole file.
  final bool toPages;
}

/// Options of one [PdfParser.parse] call, given in
/// [ParserOptions.extensions].
///
/// Port of eino-ext `pdf.WithToPages`.
@immutable
final class PdfParserOptions {
  /// Options that override the parser's configuration for one call.
  const PdfParserOptions({this.toPages});

  /// Whether every page becomes a document of its own; `null` keeps
  /// [PdfParserConfig.toPages].
  final bool? toPages;
}

/// Parses a PDF file into its text: one document, or one per page.
///
/// Port of eino-ext `parser/pdf` (`pdf.NewPDFParser`, `PDFParser.Parse`).
/// The text comes from the [PdfTextExtractor] the parser is given:
///
/// ```dart
/// final parser = PdfParser(extractor: myPdfiumExtractor);
/// final docs = await parser.parse(
///   ctx,
///   File('report.pdf').openRead(),
///   options: const ParserOptions(extensions: [PdfParserOptions(toPages: true)]),
/// );
/// ```
///
/// With `toPages` every page is a document whose content is that page's
/// text; otherwise there is one document whose content is the text of every
/// page followed by `\n`. As in Go, the metadata of every document is the
/// [ParserOptions.extraMeta] of the call and nothing else (no source); the
/// documents have no id.
///
/// An extractor that fails makes the call throw a [ThreepioException]
/// `create new pdf reader failed: <error>`, with the extractor's error as
/// `cause` (the extractor reads every page in one call, so Go's separate
/// `read pdf page failed: <error>, page= <n>` has no counterpart); bytes
/// that cannot be read throw `pdf parser read all from reader failed:
/// <error>`. A cancellation or an interrupt gets through as it is.
final class PdfParser implements Parser {
  /// A parser that reads the text of PDF files with [extractor], configured
  /// by [config].
  ///
  /// Port of eino-ext `pdf.NewPDFParser`.
  const PdfParser({
    required this.extractor,
    this.config = const PdfParserConfig(),
  });

  /// Reads the text of the pages.
  final PdfTextExtractor extractor;

  /// The configuration of this parser.
  final PdfParserConfig config;

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    final toPages =
        options?.extension<PdfParserOptions>()?.toPages ?? config.toPages;

    final Uint8List data;
    try {
      data = await readAllBytes(bytes);
    } on Exception catch (error) {
      if (error is CancelledException || isInterrupt(error)) rethrow;
      throw ThreepioException(
        'pdf parser read all from reader failed: ${goErrorText(error)}',
        cause: error,
      );
    }

    final List<String> pages;
    try {
      pages = await extractor.extractPageTexts(ctx, data);
    } on Exception catch (error) {
      if (error is CancelledException || isInterrupt(error)) rethrow;
      throw ThreepioException(
        'create new pdf reader failed: ${goErrorText(error)}',
        cause: error,
      );
    }

    final metadata = <String, Object?>{...?options?.extraMeta};
    if (toPages) {
      return [
        for (final text in pages) Document(content: text, metadata: metadata),
      ];
    }
    final content = StringBuffer();
    for (final text in pages) {
      content
        ..write(text)
        ..write('\n');
    }
    return [Document(content: content.toString(), metadata: metadata)];
  }
}
