// Mirrors "Documents and their metadata" of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/schema.dart';

void documentMetadata() {
  final doc = Document(
    id: 'faq-1',
    content: 'Reset your password from the login page.',
  )
      .withSubIndexes(['faq'])
      .withScore(0.92)
      .withDenseVector([0.1, 0.4, 0.2])
      .withExtraInfo('help centre');

  print(doc.subIndexes); // [faq]
  print(doc.effectiveScore); // 0.92: the score field, else the _score entry
  print(doc.denseVector); // [0.1, 0.4, 0.2]
  print(doc.metadata.keys); // (_sub_indexes, _score, _dense_vector, _extra_info)
}
