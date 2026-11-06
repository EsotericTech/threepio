// Port of eino-ext components/model/agenticclaude/content_block_extra_test.go
// (all 3 tests: TestContentBlockExtraValueHelpers, TestResultCallerRoundTrip,
// TestResultCallerDecodeError). Go's caller unions are the raw JSON of the
// response's `caller`; here the decoded map. The cache control helpers of
// content_block_extra.go are tested in claude_agentic_model_test.dart, with
// model_test.go's TestSetContentBlockCacheControl and
// TestSetToolInfoCacheControl.
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_utils.dart';
import 'package:threepio_core/threepio_core.dart';

void main() {
  test('TestContentBlockExtraValueHelpers', () {
    final block = claudeContentBlockWithExtra(
      ContentBlock(const ServerToolResult()),
      'trace_id',
      'trace-1',
    );
    expect(claudeContentBlockExtraValue<String>(block, 'trace_id'), 'trace-1');
    expect(claudeContentBlockExtraValue<int>(block, 'trace_id'), isNull);
    expect(claudeContentBlockExtraValue<String>(null, 'trace_id'), isNull);
    expect(
      claudeContentBlockExtraValue<String>(
        ContentBlock(const ServerToolResult()),
        'trace_id',
      ),
      isNull,
    );
  });

  group('TestResultCallerRoundTrip', () {
    test('web search', () {
      final block = claudeWithWebSearchResultCaller(
        ContentBlock(const ServerToolResult()),
        {'type': 'direct'},
      );
      expect(claudeWebSearchResultCallerParam(block)?['type'], 'direct');
    });

    test('web fetch', () {
      final block = claudeWithWebFetchResultCaller(
        ContentBlock(const ServerToolResult()),
        {'type': 'code_execution_20250825', 'tool_id': 'srvtoolu_1'},
      );
      expect(claudeWebFetchResultCallerParam(block), {
        'type': 'code_execution_20250825',
        'tool_id': 'srvtoolu_1',
      });
    });

    test('no caller', () {
      final block = claudeWithWebSearchResultCaller(
        ContentBlock(const ServerToolResult()),
        null,
      );
      expect(block.extra, {claudeAgenticKeyOfWebSearchToolResultCaller: ''});
      expect(claudeWebSearchResultCallerParam(block), isNull);
      expect(
        claudeWebFetchResultCallerParam(ContentBlock(const ServerToolResult())),
        isNull,
      );
    });
  });

  test('TestResultCallerDecodeError', () {
    final block = ContentBlock(
      const ServerToolResult(),
      extra: const {claudeAgenticKeyOfWebSearchToolResultCaller: '{'},
    );
    expect(
      () => claudeWebSearchResultCallerParam(block),
      throwsA(isA<ThreepioFormatException>()),
    );
    final notObject = ContentBlock(
      const ServerToolResult(),
      extra: const {claudeAgenticKeyOfWebFetchToolResultCaller: '"direct"'},
    );
    expect(
      () => claudeWebFetchResultCallerParam(notObject),
      throwsA(isA<ThreepioFormatException>()),
    );
  });
}
