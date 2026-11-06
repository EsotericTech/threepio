// Mirror of doc/NEW_FEATURES.md, section 1, "### Multimodal Input (Images, Audio, Video)".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:threepio_core/threepio_core.dart';

Future<void> multimodal(
  GeminiChatModel model,
  List<int> imageBytes,
  List<int> audioBytes,
  String uploadedVideoUri,
) async {
  // Image as a data URL (sent inline)
  final response = await model.generate([
    Message(
      role: RoleType.user,
      userInputMultiContent: [
        MessageInputPart.text('What is in this image?'),
        MessageInputPart.imageUrl(
          'data:image/jpeg;base64,${base64Encode(imageBytes)}',
        ),
      ],
    ),
  ]);
  print(response.content);

  // Audio as base64 data
  final audioResponse = await model.generate([
    Message(
      role: RoleType.user,
      userInputMultiContent: [
        MessageInputPart.text('Transcribe this audio'),
        MessageInputPart.audio(
          base64Data: base64Encode(audioBytes),
          mimeType: 'audio/mp3',
        ),
      ],
    ),
  ]);
  print(audioResponse.content);

  // Video uploaded with the Gemini Files API
  final videoResponse = await model.generate([
    Message(
      role: RoleType.user,
      userInputMultiContent: [
        MessageInputPart.text('What happens in this video?'),
        MessageInputPart.video(fileId: uploadedVideoUri, mimeType: 'video/mp4'),
      ],
    ),
  ]);
  print(videoResponse.content);
}
