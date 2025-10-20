import '../../schema/document.dart';
import '../../schema/message.dart';
import '../model/base_chat_model.dart';
import '../retriever/retriever.dart';
import 'base_chain.dart';

/// Retrieval-augmented generation (RAG) chain for question answering
///
/// This chain retrieves relevant documents based on a question and uses
/// them as context to generate an answer with a language model.
///
/// The chain performs these steps:
/// 1. Retrieve relevant documents using the retriever
/// 2. Format documents into context
/// 3. Create a prompt with context and question
/// 4. Generate answer using the chat model
/// 5. Return answer with source documents
///
/// Example usage:
/// ```dart
/// // Setup components
/// final embedder = OpenAIEmbedder(config: openAIConfig);
/// final vectorStore = InMemoryVectorStore();
/// final retriever = VectorRetriever(
///   embedder: embedder,
///   vectorStore: vectorStore,
/// );
/// final chatModel = OpenAIChatModel(config: openAIConfig);
///
/// // Create RAG chain
/// final chain = RetrievalQAChain(
///   retriever: retriever,
///   chatModel: chatModel,
/// );
///
/// // Ask a question
/// final result = await chain.invoke({
///   'question': 'What is the capital of France?',
/// });
///
/// print('Answer: ${result['answer']}');
/// print('Sources: ${result['source_documents']}');
/// ```
class RetrievalQAChain extends BaseChain {
  RetrievalQAChain({
    required this.retriever,
    required this.chatModel,
    this.returnSourceDocuments = true,
    this.topK = 4,
    this.promptTemplate,
    this.documentSeparator = '\n\n',
  });

  /// Retriever for finding relevant documents
  final Retriever retriever;

  /// Chat model for generating answers
  final BaseChatModel chatModel;

  /// Whether to return source documents in output
  final bool returnSourceDocuments;

  /// Number of documents to retrieve
  final int topK;

  /// Custom prompt template (uses default if not provided)
  final String? promptTemplate;

  /// Separator between documents in context
  final String documentSeparator;

  @override
  List<String> get inputKeys => ['question'];

  @override
  List<String> get outputKeys {
    final keys = ['answer'];
    if (returnSourceDocuments) {
      keys.add('source_documents');
    }
    return keys;
  }

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
    final question = inputs['question'] as String;

    // 1. Retrieve relevant documents
    final documents = await retriever.retrieve(
      question,
      options: RetrieverOptions(topK: topK),
    );

    if (documents.isEmpty) {
      // No documents found, answer without context
      final answer = await _generateAnswer(
        question: question,
        context: '',
      );

      return {
        'answer': answer,
        if (returnSourceDocuments) 'source_documents': <Document>[],
      };
    }

    // 2. Format documents into context
    final context = _formatDocuments(documents);

    // 3. Generate answer using chat model
    final answer = await _generateAnswer(
      question: question,
      context: context,
    );

    // 4. Return answer with optional source documents
    return {
      'answer': answer,
      if (returnSourceDocuments) 'source_documents': documents,
    };
  }

  /// Format documents into a context string
  String _formatDocuments(List<Document> documents) {
    return documents.map((doc) => doc.content).join(documentSeparator);
  }

  /// Generate answer using the chat model
  Future<String> _generateAnswer({
    required String question,
    required String context,
  }) async {
    final prompt = _buildPrompt(question: question, context: context);

    final messages = [Message.user(prompt)];

    final response = await chatModel.generate(messages);

    return response.content;
  }

  /// Build the prompt with context and question
  String _buildPrompt({
    required String question,
    required String context,
  }) {
    if (promptTemplate != null) {
      // Use custom template
      return promptTemplate!
          .replaceAll('{context}', context)
          .replaceAll('{question}', question);
    }

    // Use default template
    if (context.isEmpty) {
      return '''Answer the following question to the best of your ability:

Question: $question

Answer:''';
    }

    return '''Use the following pieces of context to answer the question at the end. If you don't know the answer, just say that you don't know, don't try to make up an answer.

Context:
$context

Question: $question

Answer:''';
  }
}

/// Advanced RAG chain with custom document formatting
///
/// Provides more control over how documents are formatted and presented
/// to the language model. Useful when you need custom formatting or
/// want to include document metadata.
///
/// Example usage:
/// ```dart
/// final chain = CustomRetrievalQAChain(
///   retriever: retriever,
///   chatModel: chatModel,
///   documentFormatter: (doc) {
///     return '''
/// Source: ${doc.source?.uri ?? 'unknown'}
/// Content: ${doc.content}
/// Relevance: ${doc.score ?? 'N/A'}
/// ''';
///   },
/// );
/// ```
class CustomRetrievalQAChain extends RetrievalQAChain {
  CustomRetrievalQAChain({
    required super.retriever,
    required super.chatModel,
    required this.documentFormatter,
    super.returnSourceDocuments,
    super.topK,
    super.promptTemplate,
    super.documentSeparator,
  });

  /// Custom function to format each document
  final String Function(Document) documentFormatter;

  @override
  String _formatDocuments(List<Document> documents) {
    return documents.map(documentFormatter).join(documentSeparator);
  }
}

/// Conversational RAG chain that maintains chat history
///
/// Extends RetrievalQAChain to support multi-turn conversations by
/// incorporating chat history into the retrieval and generation process.
///
/// Example usage:
/// ```dart
/// final chain = ConversationalRetrievalChain(
///   retriever: retriever,
///   chatModel: chatModel,
/// );
///
/// // First question
/// var result = await chain.invoke({
///   'question': 'What is machine learning?',
///   'chat_history': <Message>[],
/// });
///
/// var chatHistory = result['chat_history'] as List<Message>;
/// print('Answer: ${result['answer']}');
///
/// // Follow-up question
/// result = await chain.invoke({
///   'question': 'What are its applications?',
///   'chat_history': chatHistory,
/// });
///
/// print('Answer: ${result['answer']}');
/// ```
class ConversationalRetrievalChain extends BaseChain {
  ConversationalRetrievalChain({
    required this.retriever,
    required this.chatModel,
    this.returnSourceDocuments = true,
    this.topK = 4,
    this.documentSeparator = '\n\n',
  });

  /// Retriever for finding relevant documents
  final Retriever retriever;

  /// Chat model for generating answers
  final BaseChatModel chatModel;

  /// Whether to return source documents in output
  final bool returnSourceDocuments;

  /// Number of documents to retrieve
  final int topK;

  /// Separator between documents in context
  final String documentSeparator;

  @override
  List<String> get inputKeys => ['question', 'chat_history'];

  @override
  List<String> get outputKeys {
    final keys = ['answer', 'chat_history'];
    if (returnSourceDocuments) {
      keys.add('source_documents');
    }
    return keys;
  }

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
    final question = inputs['question'] as String;
    final chatHistory = inputs['chat_history'] as List<Message>;

    // 1. Condense question with history if needed
    final standaloneQuestion = chatHistory.isEmpty
        ? question
        : await _condenseQuestion(question, chatHistory);

    // 2. Retrieve relevant documents
    final documents = await retriever.retrieve(
      standaloneQuestion,
      options: RetrieverOptions(topK: topK),
    );

    // 3. Format documents into context
    final context = documents.isEmpty
        ? ''
        : documents.map((doc) => doc.content).join(documentSeparator);

    // 4. Build messages with history and context
    final messages = <Message>[
      ...chatHistory,
      if (context.isNotEmpty)
        Message.system(
          'Use the following context to answer the user\'s question:\n\n$context',
        ),
      Message.user(question),
    ];

    // 5. Generate answer
    final response = await chatModel.generate(messages);

    // 6. Update chat history
    final updatedHistory = [
      ...chatHistory,
      Message.user(question),
      response,
    ];

    // 7. Return result
    return {
      'answer': response.content,
      'chat_history': updatedHistory,
      if (returnSourceDocuments) 'source_documents': documents,
    };
  }

  /// Condense the current question with chat history into a standalone question
  Future<String> _condenseQuestion(
    String question,
    List<Message> chatHistory,
  ) async {
    final prompt =
        '''Given the following conversation and a follow up question, rephrase the follow up question to be a standalone question that captures all necessary context.

Chat History:
${_formatChatHistory(chatHistory)}

Follow Up Question: $question

Standalone Question:''';

    final messages = [Message.user(prompt)];
    final response = await chatModel.generate(messages);

    return response.content.trim();
  }

  /// Format chat history for the prompt
  String _formatChatHistory(List<Message> history) {
    return history.map((msg) {
      final role = msg.role == RoleType.user ? 'Human' : 'Assistant';
      return '$role: ${msg.content}';
    }).join('\n');
  }
}
