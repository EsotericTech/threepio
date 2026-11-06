// Mirrors the DOCX and XLSX parsers of doc/RAG.md.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:threepio_core/components.dart';

Future<void> officeParsers(RunContext ctx) async {
  const docx = DocxParser(
    DocxParserConfig(toSections: true, includeTables: true),
  );
  final sections = await docx.parse(ctx, File('handbook.docx').openRead());
  print(sections.map(DocxParser.sectionTypeOf)); // (main, tables) here

  const xlsx = XlsxParser(XlsxParserConfig(sheetName: 'Prices', idPrefix: 'p'));
  final rows = await xlsx.parse(ctx, File('prices.xlsx').openRead());
  print(rows.first.id); // p1: the first row under the header
  print(rows.first.metadata[xlsxMetaKeyRow]); // {Item: Tea, Price: 3.5}
}
