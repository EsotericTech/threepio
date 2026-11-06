// Mirror of doc/NEW_FEATURES.md, section 1, "### Error Handling".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> errorHandling(
  GeminiChatModel model,
  List<Message> messages,
) async {
  try {
    final response = await model.generate(messages);
    print(response.content);
  } on GeminiException catch (e) {
    print('API Error: ${e.message}');
    print('Status Code: ${e.statusCode}');
    print('Error Code: ${e.code}');
    print('Status: ${e.status}');

    // 408, 429, 5xx, RESOURCE_EXHAUSTED, UNAVAILABLE, DEADLINE_EXCEEDED,
    // timeouts and transport failures (not on the Imagen path)
    if (e.isRetryable) {
      print('Worth retrying');
    }
  } on CancelledException {
    print('The call was cancelled');
  } on ThreepioException catch (e) {
    // A prompt the safety filter blocked: "Content blocked: <reason>"
    print('No answer: ${e.message}');
  }

  // Or let RetryingChatModel retry the retryable failures with back-off
  final resilient = RetryingChatModel(model, maxAttempts: 5);
  final reply = await resilient.generate(messages);
  print(reply.content);
}
