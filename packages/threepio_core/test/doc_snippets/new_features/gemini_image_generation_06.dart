// Mirror of doc/NEW_FEATURES.md, section 1, "### Image Generation".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> imageGeneration(String apiKey) async {
  // Use an image generation model
  final imageModel = GeminiChatModel(
    config: GeminiConfig(
      apiKey: apiKey,
      defaultModel: 'gemini-2.5-flash-image',
    ),
  );

  final response = await imageModel.generate(
    [Message.user('Generate an image of a red circle on white background')],
    options: GeminiRequestOptions(
      responseModalities: const [
        GeminiResponseModality.text,
        GeminiResponseModality.image, // Enable image output
      ],
      imageConfig: const GeminiImageConfig(aspectRatio: '1:1'),
    ).toOptions(),
  );

  // Generated images are output parts holding a data:image/png;base64 URL
  for (final part in response.assistantGenMultiContent ?? <MessageOutputPart>[]) {
    if (part.type == ChatMessagePartType.imageUrl) {
      final dataUrl = part.image!.url!;
      final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
      await File('output.png').writeAsBytes(bytes);
    }
  }
  imageModel.dispose();
}
