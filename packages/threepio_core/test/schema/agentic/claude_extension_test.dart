// Port of eino `schema/claude/extension_test.go` (v0.9.22), all cases.

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

void main() {
  group('TestConcatAssistantGenTextExtensions', () {
    test('multiple extensions - concatenates all citations', () {
      final result = concatClaudeAssistantGenTextExtensions([
        ClaudeAssistantGenTextExtension(
          citations: const [
            ClaudeTextCitation(
              type: ClaudeTextCitationType('char_location'),
              charLocation: ClaudeCitationCharLocation(citedText: 'citation 1'),
            ),
          ],
        ),
        ClaudeAssistantGenTextExtension(
          citations: const [
            ClaudeTextCitation(
              type: ClaudeTextCitationType('page_location'),
              pageLocation: ClaudeCitationPageLocation(
                citedText: 'citation 2',
                startPageNumber: 1,
                endPageNumber: 2,
              ),
            ),
            ClaudeTextCitation(
              type: ClaudeTextCitationType('web_search_result_location'),
              webSearchResultLocation: ClaudeCitationWebSearchResultLocation(
                citedText: 'citation 3',
                url: 'https://example.com',
              ),
            ),
          ],
        ),
        ClaudeAssistantGenTextExtension(
          citations: const [
            ClaudeTextCitation(
              type: ClaudeTextCitationType('content_block_location'),
              contentBlockLocation: ClaudeCitationContentBlockLocation(
                citedText: 'citation 4',
                endBlockIndex: 5,
              ),
            ),
          ],
        ),
      ]);
      expect(result.citations, hasLength(4));
      expect(result.citations[0].charLocation!.citedText, 'citation 1');
      expect(result.citations[1].pageLocation!.citedText, 'citation 2');
      expect(
        result.citations[2].webSearchResultLocation!.citedText,
        'citation 3',
      );
      expect(result.citations[3].contentBlockLocation!.citedText, 'citation 4');
    });

    test('mixed empty and non-empty citations', () {
      final result = concatClaudeAssistantGenTextExtensions([
        ClaudeAssistantGenTextExtension(),
        ClaudeAssistantGenTextExtension(
          citations: const [
            ClaudeTextCitation(
              type: ClaudeTextCitationType.charLocation,
              charLocation: ClaudeCitationCharLocation(citedText: 'text1'),
            ),
          ],
        ),
        ClaudeAssistantGenTextExtension(citations: const []),
        ClaudeAssistantGenTextExtension(
          citations: const [
            ClaudeTextCitation(
              type: ClaudeTextCitationType.pageLocation,
              pageLocation: ClaudeCitationPageLocation(citedText: 'text2'),
            ),
          ],
        ),
      ]);
      expect(result.citations, hasLength(2));
      expect(result.citations[0].charLocation!.citedText, 'text1');
      expect(result.citations[1].pageLocation!.citedText, 'text2');
    });

    test('streaming scenario - citations arrive in chunks', () {
      final result = concatClaudeAssistantGenTextExtensions([
        for (final text in ['chunk1', 'chunk2', 'chunk3'])
          ClaudeAssistantGenTextExtension(
            citations: [
              ClaudeTextCitation(
                type: ClaudeTextCitationType.charLocation,
                charLocation: ClaudeCitationCharLocation(citedText: text),
              ),
            ],
          ),
      ]);
      expect(result.citations, hasLength(3));
      expect(result.citations[0].charLocation!.citedText, 'chunk1');
      expect(result.citations[1].charLocation!.citedText, 'chunk2');
      expect(result.citations[2].charLocation!.citedText, 'chunk3');
    });

    test('a single extension is returned as it is; none is an error', () {
      final only = ClaudeAssistantGenTextExtension();
      expect(concatClaudeAssistantGenTextExtensions([only]), same(only));
      expect(
        () => concatClaudeAssistantGenTextExtensions([]),
        throwsArgumentError,
      );
    });
  });

  group('TestConcatResponseMetaExtensions', () {
    test('multiple extensions - takes last non-empty values', () {
      final result = concatClaudeResponseMetaExtensions(const [
        ClaudeResponseMetaExtension(id: 'msg_1', stopReason: 'stop_1'),
        ClaudeResponseMetaExtension(id: 'msg_2'),
        ClaudeResponseMetaExtension(stopReason: 'stop_3'),
      ]);
      expect(result.id, 'msg_2');
      expect(result.stopReason, 'stop_3');
    });

    test('all empty fields', () {
      final result = concatClaudeResponseMetaExtensions(const [
        ClaudeResponseMetaExtension(),
        ClaudeResponseMetaExtension(),
      ]);
      expect(result.id, '');
      expect(result.stopReason, '');
    });

    test('streaming scenario - ID in first chunk, StopReason in last', () {
      final result = concatClaudeResponseMetaExtensions(const [
        ClaudeResponseMetaExtension(id: 'msg_stream_123'),
        ClaudeResponseMetaExtension(),
        ClaudeResponseMetaExtension(stopReason: 'end_turn'),
      ]);
      expect(result.id, 'msg_stream_123');
      expect(result.stopReason, 'end_turn');
    });

    test('stop sequence and stop details', () {
      const details = ClaudeStopDetails(category: 'c', explanation: 'e');
      final result = concatClaudeResponseMetaExtensions(const [
        ClaudeResponseMetaExtension(stopSequence: 'END', stopDetails: details),
        ClaudeResponseMetaExtension(id: 'x'),
      ]);
      expect(
        result,
        const ClaudeResponseMetaExtension(
          id: 'x',
          stopSequence: 'END',
          stopDetails: details,
        ),
      );
      expect(() => concatClaudeResponseMetaExtensions([]), throwsArgumentError);
    });
  });
}
