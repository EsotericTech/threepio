// Mirrors the file loader of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/components.dart';
import 'package:threepio_core/io.dart';
import 'package:threepio_core/schema.dart';

Future<void> fileLoader(RunContext ctx) async {
  final loader = FileLoader(
    FileLoaderConfig(
      useNameAsId: true,
      parser: ExtParser(
        parsers: {
          '.html': HtmlParser.fromConfig(),
          '.docx': const DocxParser(),
          '.xlsx': const XlsxParser(),
        },
      ), // anything else is read as UTF-8 text
    ),
  );
  final docs = await loader.load(
    ctx,
    const DocumentSource(uri: 'notes/guide.html'),
  );
  print(docs.single.id); // guide.html
  print(docs.single.metadata[fileLoaderMetaKeyFileName]); // guide.html
}
