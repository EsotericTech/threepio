// Mirrors the PDF parser of doc/RAG.md.
import 'dart:io';
import 'dart:typed_data';

import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

/// Hands the PDF to whatever extracts text in your app.
final class CallbackPdfExtractor implements PdfTextExtractor {
  CallbackPdfExtractor(this._extract);

  final Future<List<String>> Function(Uint8List bytes) _extract;

  @override
  Future<List<String>> extractPageTexts(RunContext ctx, Uint8List pdfBytes) =>
      _extract(pdfBytes);
}

Future<List<Document>> parseReport(
  RunContext ctx,
  Future<List<String>> Function(Uint8List bytes) extract,
) {
  final parser = PdfParser(
    extractor: CallbackPdfExtractor(extract),
    config: const PdfParserConfig(toPages: true), // one document per page
  );
  return parser.parse(
    ctx,
    File('report.pdf').openRead(),
    options: const ParserOptions(extraMeta: {'kind': 'report'}),
  );
}
