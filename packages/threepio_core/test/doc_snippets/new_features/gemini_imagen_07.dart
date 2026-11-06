// Mirror of doc/NEW_FEATURES.md, section 1, "### Imagen Image Generation".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> imagen(String apiKey) async {
  // Available Imagen models:
  // - imagen-4.0-generate-001 (Standard)
  // - imagen-4.0-ultra-generate-001 (Ultra - higher quality)
  // - imagen-4.0-fast-generate-001 (Fast - lower latency)

  final imagenModel = GeminiChatModel(
    config: GeminiConfig(
      apiKey: apiKey,
      defaultModel: 'imagen-4.0-generate-001',
    ),
  );

  // Basic image generation
  final response = await imagenModel.generate([
    Message.user('A serene mountain landscape at sunset with snow-capped peaks'),
  ]);
  print(response.content); // Generated <n> image(s) for: "<prompt>"

  // With options
  final response2 = await imagenModel.generate(
    [Message.user('A cute robot playing with a kitten')],
    options: const ChatModelOptions(
      extra: {
        'numberOfImages': 2, // 1-4 images (sent as sampleCount)
        'aspectRatio': '16:9', // '1:1', '3:4', '4:3', '9:16', '16:9'
        'personGeneration': 'dont_allow', // 'dont_allow', 'allow_adult', 'allow_all'
        'imageSize': '2K', // '1K', '2K' (Standard/Ultra only)
      },
    ),
  );

  // Generated images are output parts holding a data:image/png;base64 URL
  var index = 0;
  for (final part in response2.assistantGenMultiContent ?? <MessageOutputPart>[]) {
    if (part.type == ChatMessagePartType.imageUrl) {
      final dataUrl = part.image!.url!;
      final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
      await File('generated_image_${index++}.png').writeAsBytes(bytes);
    }
  }
  imagenModel.dispose();
}
