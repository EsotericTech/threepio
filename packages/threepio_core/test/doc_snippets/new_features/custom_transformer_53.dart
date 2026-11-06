// Mirror of doc/NEW_FEATURES.md, "5. Document Processing Pipeline > Custom Document Transformer".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

class SummarizationTransformer extends DocumentTransformer {
  const SummarizationTransformer({required this.model});

  final BaseChatModel model;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options, // required since 0.9
  }) async {
    final transformed = <Document>[];

    for (final doc in documents) {
      // Generate a summary; the model gets the run context of the call
      // (cancellation, callbacks)
      final response = await model.generate(
        [
          Message.system('Summarize the following text in 2-3 sentences.'),
          Message.user(doc.content),
        ],
        options: ChatModelOptions(runContext: options?.runContext),
      );

      transformed.add(doc.copyWith(
        metadata: {
          ...doc.metadata,
          'summary': response.content,
        },
      ));
    }

    return transformed;
  }
}

// Use in a pipeline
IngestionPipeline summarizingPipeline(BaseChatModel model, TextSplitter splitter) =>
    IngestionPipeline(
      splitter: splitter,
      transformers: [SummarizationTransformer(model: model)],
    );
