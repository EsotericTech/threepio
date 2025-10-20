import '../../components/model/base_chat_model.dart';
import '../../schema/message.dart';
import '../prompt/chat_template.dart';
import 'base_chain.dart';

/// Chain that combines a prompt template with an LLM
///
/// Takes input variables, formats them using a template,
/// sends to an LLM, and returns the response.
///
/// Example usage:
/// ```dart
/// final template = ChatPromptTemplate.fromTemplate(
///   systemTemplate: 'You are a helpful {role}.',
///   userTemplate: 'Answer this question: {question}',
/// );
///
/// final chain = LLMChain(
///   template: template,
///   model: OpenAIChatModel(config: config),
///   outputKey: 'answer',
/// );
///
/// final result = await chain.run({
///   'role': 'teacher',
///   'question': 'What is 2+2?',
/// });
///
/// print(result['answer']); // Model's response
/// ```
class LLMChain extends BaseChain {
  LLMChain({
    required this.template,
    required this.model,
    this.outputKey = 'text',
    this.conversationHistory,
  });

  /// Template for formatting prompts
  final ChatTemplate template;

  /// Language model to use
  final BaseChatModel model;

  /// Key name for the output
  final String outputKey;

  /// Optional conversation history to prepend
  final List<Message>? conversationHistory;

  @override
  List<String> get inputKeys {
    // Input keys are determined by the template
    // For now, return empty list and let template validation handle it
    return [];
  }

  @override
  List<String> get outputKeys => [outputKey];

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
    try {
      // Format the template with inputs
      final messages = await template.format(inputs);

      // Prepend conversation history if provided
      final allMessages = [
        ...?conversationHistory,
        ...messages,
      ];

      // Call the model
      final response = await model.generate(allMessages);

      // Return the output
      return {
        outputKey: response.content,
        '_full_response': response, // Include full response for metadata
      };
    } catch (e) {
      throw ChainException(
        'LLM chain execution failed',
        chainName: 'LLMChain',
        cause: e,
      );
    }
  }

  /// Create a chain with conversation history
  LLMChain withHistory(List<Message> history) {
    return LLMChain(
      template: template,
      model: model,
      outputKey: outputKey,
      conversationHistory: [
        ...?conversationHistory,
        ...history,
      ],
    );
  }
}

/// Chain that streams LLM responses
///
/// Similar to LLMChain but streams the response token by token.
///
/// Example usage:
/// ```dart
/// final chain = StreamingLLMChain(
///   template: template,
///   model: model,
/// );
///
/// await for (final chunk in chain.stream({'question': 'What is AI?'})) {
///   print(chunk); // Print each token as it arrives
/// }
/// ```
class StreamingLLMChain {
  StreamingLLMChain({
    required this.template,
    required this.model,
    this.conversationHistory,
  });

  /// Template for formatting prompts
  final ChatTemplate template;

  /// Language model to use (must support streaming)
  final BaseChatModel model;

  /// Optional conversation history to prepend
  final List<Message>? conversationHistory;

  /// Stream responses from the model
  Stream<String> stream(Map<String, dynamic> inputs) async* {
    try {
      // Format the template with inputs
      final messages = await template.format(inputs);

      // Prepend conversation history if provided
      final allMessages = [
        ...?conversationHistory,
        ...messages,
      ];

      // Stream from the model
      final reader = await model.stream(allMessages);

      try {
        while (true) {
          final message = await reader.recv();
          if (message.content.isNotEmpty) {
            yield message.content;
          }
        }
      } catch (e) {
        // Stream EOF or error
        if (e.toString().contains('StreamEOFException')) {
          // Normal end of stream
          return;
        }
        rethrow;
      } finally {
        await reader.close();
      }
    } catch (e) {
      throw ChainException(
        'Streaming LLM chain execution failed',
        chainName: 'StreamingLLMChain',
        cause: e,
      );
    }
  }

  /// Run the chain and collect all chunks into a single string
  Future<String> run(Map<String, dynamic> inputs) async {
    final buffer = StringBuffer();
    await for (final chunk in stream(inputs)) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }
}

/// Chain for transformation operations on text
///
/// Useful for preprocessing or postprocessing text in a chain.
///
/// Example usage:
/// ```dart
/// final chain = TransformChain(
///   inputKey: 'text',
///   outputKey: 'uppercase_text',
///   transformFn: (text) => text.toUpperCase(),
/// );
///
/// final result = await chain.run({'text': 'hello'});
/// print(result['uppercase_text']); // 'HELLO'
/// ```
class TransformChain extends BaseChain {
  /// Create a synchronous transform chain
  factory TransformChain.sync({
    required String inputKey,
    required String outputKey,
    required String Function(String) transformFn,
  }) {
    return TransformChain(
      inputKey: inputKey,
      outputKey: outputKey,
      transformFn: (input) async => transformFn(input),
    );
  }

  TransformChain({
    required this.inputKey,
    required this.outputKey,
    required this.transformFn,
  });

  /// Input key to read from
  final String inputKey;

  /// Output key to write to
  final String outputKey;

  /// Transformation function
  final Future<String> Function(String) transformFn;

  @override
  List<String> get inputKeys => [inputKey];

  @override
  List<String> get outputKeys => [outputKey];

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
    try {
      final input = inputs[inputKey]?.toString() ?? '';
      final output = await transformFn(input);
      return {outputKey: output};
    } catch (e) {
      throw ChainException(
        'Transform chain execution failed',
        chainName: 'TransformChain',
        cause: e,
      );
    }
  }
}

/// Chain for routing to different chains based on input
///
/// Example usage:
/// ```dart
/// final router = RouterChain(
///   routes: {
///     'question': questionChain,
///     'summary': summaryChain,
///   },
///   routeKey: 'type',
///   defaultChain: defaultChain,
/// );
///
/// final result = await router.run({
///   'type': 'question',
///   'text': 'What is AI?',
/// });
/// ```
class RouterChain extends BaseChain {
  RouterChain({
    required this.routes,
    required this.routeKey,
    this.defaultChain,
  });

  /// Map of route names to chains
  final Map<String, BaseChain> routes;

  /// Input key used for routing
  final String routeKey;

  /// Optional default chain if route not found
  final BaseChain? defaultChain;

  @override
  List<String> get inputKeys {
    // Collect all possible input keys from all routes
    final allKeys = <String>{routeKey};
    for (final chain in routes.values) {
      allKeys.addAll(chain.inputKeys);
    }
    if (defaultChain != null) {
      allKeys.addAll(defaultChain!.inputKeys);
    }
    return allKeys.toList();
  }

  @override
  List<String> get outputKeys {
    // Collect all possible output keys from all routes
    final allKeys = <String>{};
    for (final chain in routes.values) {
      allKeys.addAll(chain.outputKeys);
    }
    if (defaultChain != null) {
      allKeys.addAll(defaultChain!.outputKeys);
    }
    return allKeys.toList();
  }

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
    final routeValue = inputs[routeKey]?.toString();

    if (routeValue == null) {
      throw ChainException(
        'Router key "$routeKey" not found in inputs',
        chainName: 'RouterChain',
      );
    }

    final selectedChain = routes[routeValue] ?? defaultChain;

    if (selectedChain == null) {
      throw ChainException(
        'No chain found for route "$routeValue" and no default chain provided',
        chainName: 'RouterChain',
      );
    }

    try {
      return await selectedChain.invoke(inputs);
    } catch (e) {
      throw ChainException(
        'Routed chain execution failed for route "$routeValue"',
        chainName: 'RouterChain',
        cause: e,
      );
    }
  }
}
