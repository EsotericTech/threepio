// Port of eino `schema/openai/extension_test.go` (v0.9.22).
//
// "nil extension and nil content skipped" (TestConcatReasoningExtensions)
// cannot be ported literally: the lists are non-nullable, so there is no nil
// extension or part to skip. The remaining part of that case (a single
// indexed part) is kept.

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

void main() {
  group('TestConcatResponseMetaExtensions', () {
    test('multiple extensions - takes last non-empty values', () {
      const err1 = OpenAIResponseError(
        code: OpenAIResponseErrorCode('err1'),
        message: 'msg1',
      );
      const incomplete = OpenAIIncompleteDetails(reason: 'max_tokens');

      final result = concatOpenAIResponseMetaExtensions(const [
        OpenAIResponseMetaExtension(
          id: 'id_1',
          status: OpenAIResponseStatus('in_progress'),
          error: err1,
        ),
        OpenAIResponseMetaExtension(id: 'id_2'),
        OpenAIResponseMetaExtension(
          status: OpenAIResponseStatus('completed'),
          incompleteDetails: incomplete,
        ),
      ]);
      expect(result.id, 'id_2');
      expect(result.status, const OpenAIResponseStatus('completed'));
      expect(result.error, err1);
      expect(result.incompleteDetails, incomplete);
    });

    test('streaming scenario', () {
      final result = concatOpenAIResponseMetaExtensions(const [
        OpenAIResponseMetaExtension(id: 'chatcmpl_stream'),
        OpenAIResponseMetaExtension(status: OpenAIResponseStatus.inProgress),
        OpenAIResponseMetaExtension(status: OpenAIResponseStatus.completed),
      ]);
      expect(result.id, 'chatcmpl_stream');
      expect(result.status, OpenAIResponseStatus.completed);
    });

    test('every field takes the last value that is set', () {
      final result = concatOpenAIResponseMetaExtensions(const [
        OpenAIResponseMetaExtension(
          previousResponseId: 'p1',
          reasoning: OpenAIReasoning(effort: OpenAIReasoningEffort.low),
          serviceTier: OpenAIServiceTier.auto,
          createdAt: 1,
          promptCacheRetention: OpenAIPromptCacheRetention.inMemory,
        ),
        OpenAIResponseMetaExtension(
          previousResponseId: 'p2',
          serviceTier: OpenAIServiceTier.priority,
          createdAt: 2,
        ),
      ]);
      expect(
        result,
        const OpenAIResponseMetaExtension(
          previousResponseId: 'p2',
          reasoning: OpenAIReasoning(effort: OpenAIReasoningEffort.low),
          serviceTier: OpenAIServiceTier.priority,
          createdAt: 2,
          promptCacheRetention: OpenAIPromptCacheRetention.inMemory,
        ),
      );
    });

    test('a single extension is returned as it is; none is an error', () {
      const only = OpenAIResponseMetaExtension(id: 'x');
      expect(concatOpenAIResponseMetaExtensions(const [only]), same(only));
      expect(() => concatOpenAIResponseMetaExtensions([]), throwsArgumentError);
    });
  });

  group('TestConcatAssistantGenTextExtensions', () {
    test('single extension with annotations', () {
      final ext = OpenAIAssistantGenTextExtension(
        annotations: const [
          OpenAITextAnnotation(
            type: OpenAITextAnnotationType('file_citation'),
            fileCitation: OpenAITextAnnotationFileCitation(
              fileId: 'file_123',
              filename: 'doc.pdf',
            ),
          ),
        ],
      );

      final result = concatOpenAIAssistantGenTextExtensions([ext]);
      expect(result.annotations, hasLength(1));
      expect(result.annotations[0].fileCitation!.fileId, 'file_123');
    });

    test('multiple extensions - merges annotations by index', () {
      final result = concatOpenAIAssistantGenTextExtensions([
        OpenAIAssistantGenTextExtension(
          annotations: const [
            OpenAITextAnnotation(
              type: OpenAITextAnnotationType.fileCitation,
              fileCitation: OpenAITextAnnotationFileCitation(fileId: 'file_1'),
            ),
          ],
        ),
        OpenAIAssistantGenTextExtension(
          annotations: const [
            OpenAITextAnnotation(
              index: 2,
              type: OpenAITextAnnotationType.urlCitation,
              urlCitation: OpenAITextAnnotationUrlCitation(
                url: 'https://example.com',
              ),
            ),
          ],
        ),
        OpenAIAssistantGenTextExtension(
          annotations: const [
            OpenAITextAnnotation(
              index: 1,
              type: OpenAITextAnnotationType.filePath,
              filePath: OpenAITextAnnotationFilePath(fileId: 'file_2'),
            ),
          ],
        ),
      ]);
      expect(result.annotations, hasLength(3));
      expect(result.annotations[0].fileCitation!.fileId, 'file_1');
      expect(result.annotations[1].filePath!.fileId, 'file_2');
      expect(result.annotations[2].urlCitation!.url, 'https://example.com');
      // The streaming index is cleared in the result.
      expect(result.annotations.map((a) => a.index), [0, 0, 0]);
    });

    test('streaming scenario - annotations arrive in chunks', () {
      final result = concatOpenAIAssistantGenTextExtensions([
        OpenAIAssistantGenTextExtension(
          annotations: const [
            OpenAITextAnnotation(
              type: OpenAITextAnnotationType.fileCitation,
              fileCitation: OpenAITextAnnotationFileCitation(fileId: 'f1'),
            ),
          ],
        ),
        OpenAIAssistantGenTextExtension(
          annotations: const [
            OpenAITextAnnotation(
              index: 1,
              type: OpenAITextAnnotationType.urlCitation,
              urlCitation: OpenAITextAnnotationUrlCitation(url: 'url1'),
            ),
          ],
        ),
        OpenAIAssistantGenTextExtension(
          annotations: const [
            OpenAITextAnnotation(
              index: 2,
              type: OpenAITextAnnotationType.filePath,
              filePath: OpenAITextAnnotationFilePath(fileId: 'f2'),
            ),
          ],
        ),
      ]);
      expect(result.annotations, hasLength(3));
      expect(result.annotations[0].fileCitation!.fileId, 'f1');
      expect(result.annotations[1].urlCitation!.url, 'url1');
      expect(result.annotations[2].filePath!.fileId, 'f2');
    });

    test('multiple extensions - concatenates refusal reason', () {
      final result = concatOpenAIAssistantGenTextExtensions([
        OpenAIAssistantGenTextExtension(
          refusal: const OpenAIOutputRefusal(reason: 'A'),
        ),
        OpenAIAssistantGenTextExtension(
          refusal: const OpenAIOutputRefusal(reason: 'B'),
        ),
      ]);
      expect(result.refusal, isNotNull);
      expect(result.refusal!.reason, 'AB');
    });

    test('duplicate index - error occurrence', () {
      expect(
        () => concatOpenAIAssistantGenTextExtensions([
          OpenAIAssistantGenTextExtension(
            annotations: const [
              OpenAITextAnnotation(
                type: OpenAITextAnnotationType.fileCitation,
                fileCitation: OpenAITextAnnotationFileCitation(fileId: 'first'),
              ),
            ],
          ),
          OpenAIAssistantGenTextExtension(
            annotations: const [
              OpenAITextAnnotation(
                type: OpenAITextAnnotationType.urlCitation,
                urlCitation: OpenAITextAnnotationUrlCitation(url: 'second'),
              ),
            ],
          ),
        ]),
        throwsA(
          isA<MessageConcatException>().having(
            (e) => e.message,
            'message',
            'duplicate annotation index 0',
          ),
        ),
      );
    });

    test('no extension is an argument error', () {
      expect(
        () => concatOpenAIAssistantGenTextExtensions([]),
        throwsArgumentError,
      );
    });
  });

  group('TestConcatReasoningExtensions', () {
    test('empty chunks - error', () {
      expect(() => concatOpenAIReasoningExtensions([]), throwsArgumentError);
    });

    test('single extension', () {
      final result = concatOpenAIReasoningExtensions([
        OpenAIReasoningExtension(
          content: const [OpenAIReasoningContent(text: 'hello', index: 0)],
        ),
      ]);
      expect(result.content, hasLength(1));
      expect(result.content[0].text, 'hello');
    });

    test('streaming scenario - same index concatenated, ordered by index', () {
      final result = concatOpenAIReasoningExtensions([
        OpenAIReasoningExtension(
          content: const [OpenAIReasoningContent(text: 'he', index: 0)],
        ),
        OpenAIReasoningExtension(
          content: const [OpenAIReasoningContent(text: 'first', index: 1)],
        ),
        OpenAIReasoningExtension(
          content: const [OpenAIReasoningContent(text: 'llo', index: 0)],
        ),
      ]);
      expect(result.content, hasLength(2));
      expect(result.content[0].index, isNull);
      expect(result.content[0].text, 'hello');
      expect(result.content[1].index, isNull);
      expect(result.content[1].text, 'first');
    });

    test('all unindexed - appended in arrival order', () {
      final result = concatOpenAIReasoningExtensions([
        OpenAIReasoningExtension(
          content: const [OpenAIReasoningContent(text: 'he')],
        ),
        OpenAIReasoningExtension(
          content: const [OpenAIReasoningContent(text: 'llo')],
        ),
      ]);
      expect(result.content, hasLength(2));
      expect(result.content[0].index, isNull);
      expect(result.content[0].text, 'he');
      expect(result.content[1].index, isNull);
      expect(result.content[1].text, 'llo');
    });

    test('mixed indexed and unindexed - error', () {
      expect(
        () => concatOpenAIReasoningExtensions([
          OpenAIReasoningExtension(
            content: const [OpenAIReasoningContent(text: 'indexed', index: 0)],
          ),
          OpenAIReasoningExtension(
            content: const [OpenAIReasoningContent(text: 'no meta')],
          ),
        ]),
        throwsA(isA<MessageConcatException>()),
      );
    });

    test('an extension without content contributes nothing', () {
      final result = concatOpenAIReasoningExtensions([
        OpenAIReasoningExtension(),
        OpenAIReasoningExtension(
          content: const [OpenAIReasoningContent(text: 'ok', index: 0)],
        ),
      ]);
      expect(result.content, hasLength(1));
      expect(result.content[0].text, 'ok');
    });
  });
}
