// Mirrors "Firing callbacks from your own component" of doc/CALLBACKS.md.
// #docregion firing
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

/// A retriever that reports its own calls, with typed payloads.
final class KeywordRetriever
    implements Retriever, TypedComponent, CallbackAwareComponent {
  KeywordRetriever(this.documents);

  final List<Document> documents;

  /// Shown as `KeywordRetriever` in traces. Go: components.Typer.
  @override
  String get componentTypeName => 'Keyword';

  /// A graph leaves the callbacks of this node to it. Go: components.Checker.
  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Keeps the run info of the graph node it runs as, if any.
    var ctx = callbacks.ensureRunInfo(
      options?.runContext ?? RunContext.background(),
      componentTypeName,
      ComponentType.retriever,
    );
    ctx = await callbacks.onStart(ctx, RetrieverCallbackInput(query: query));
    try {
      final found = [
        for (final document in documents)
          if (document.content.contains(query)) document,
      ];
      await callbacks.onEnd(ctx, RetrieverCallbackOutput(docs: found));
      return found;
    } catch (error, stackTrace) {
      await callbacks.onError(ctx, error, stackTrace);
      rethrow;
    }
  }
}
// #enddocregion firing
