// Mirrors the URL loader of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:http/http.dart' as http;
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

Future<void> urlLoader(RunContext ctx) async {
  final web = UrlLoader.fromConfig(
    UrlLoaderConfig(
      parser: HtmlParser.fromConfig(const HtmlParserConfig(selector: 'article')),
      timeout: const Duration(seconds: 20),
      // A request can be sent only once: build a new one for every load.
      requestBuilder: (ctx, source, options) =>
          http.Request('GET', Uri.parse(source.uri))
            ..headers['User-Agent'] = 'my-rag-bot/1.0',
    ),
  );
  final page = await web.load(
    ctx,
    const DocumentSource(uri: 'https://example.com/post'),
  );
  print(page.single.metadata[htmlMetaKeyTitle]);
}
