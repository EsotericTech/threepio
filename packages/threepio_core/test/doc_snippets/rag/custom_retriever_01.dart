// Mirrors "Contracts and call options" of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

/// An option only [KeywordRetriever] understands.
final class KeywordOptions {
  const KeywordOptions({this.caseSensitive = false});

  final bool caseSensitive;
}

/// Returns the documents that contain the query.
final class KeywordRetriever implements Retriever, TypedComponent {
  KeywordRetriever(this.documents);

  final List<Document> documents;

  /// Shows in traces as `KeywordRetriever`.
  @override
  String get componentTypeName => 'Keyword';

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    options?.runContext?.cancelToken.throwIfCancelled();
    final caseSensitive =
        options?.extension<KeywordOptions>()?.caseSensitive ?? false;
    bool matches(Document doc) => caseSensitive
        ? doc.content.contains(query)
        : doc.content.toLowerCase().contains(query.toLowerCase());
    return documents.where(matches).take(options?.topK ?? 4).toList();
  }
}

Future<void> keywordExample(RunContext ctx) async {
  final keyword = KeywordRetriever([
    Document(id: 'eino', content: 'Eino is an LLM framework written in Go.'),
    Document(id: 'threepio', content: 'threepio is the Dart port of Eino.'),
  ]);
  final hits = await keyword.retrieve(
    'dart',
    options: RetrieverOptions(
      topK: 1,
      runContext: ctx,
      extensions: const [KeywordOptions(caseSensitive: true)],
    ),
  );
  print(hits); // [] - "Dart" is capitalised in the document
}
