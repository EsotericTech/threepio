// Mirrors the legacy chains of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/legacy_chains.dart';
import 'package:threepio_core/threepio_core.dart';

Future<List<Object>> legacyChains(
  Retriever retriever,
  BaseChatModel chatModel,
) async {
  final qa = RetrievalQAChain(retriever: retriever, chatModel: chatModel);
  final result = await qa.invoke({'question': 'What is threepio?'});
  print(result['answer']);
  final sources = result['source_documents'] as List<Document>;

  final cited = CustomRetrievalQAChain(
    retriever: retriever,
    chatModel: chatModel,
    documentFormatter: (doc) => '[${doc.id}] ${doc.content}',
  );

  final conversation = ConversationalRetrievalChain(
    retriever: retriever,
    chatModel: chatModel,
  );
  var turn = await conversation.invoke({
    'question': 'What is Eino?',
    'chat_history': <Message>[],
  });
  turn = await conversation.invoke({
    'question': 'And its Dart port?',
    'chat_history': turn['chat_history'] as List<Message>,
  });
  return [sources, cited, turn];
}
