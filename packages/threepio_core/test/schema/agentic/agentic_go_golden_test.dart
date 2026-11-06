// Goldens written by eino v0.9.22 itself: `String()` (with its `printAny`
// and `truncateString`) and `encoding/json` output of the agentic schema
// types, produced by a scratch Go program against the eino sources and
// pasted here verbatim (each `String()` golden is the Go string quoted with
// `json.Marshal`, so `jsonDecode` gives it back byte for byte).
//
// Not covered, because Dart cannot represent the Go result: a
// `truncateString` cut through a multi-byte character (Go leaves the invalid
// bytes in the string, Dart writes U+FFFD), and `printAny` of a Go struct
// that is no `fmt.Stringer` (Go writes its JSON, Dart its `toString()`).

import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

const _goldens = <String, String>{
  'printany_floats': r'''"      name: n\n      arguments: {\n  \"big\": 1e+21,\n  \"e19\": 10000000000000000000,\n  \"e20\": 100000000000000000000,\n  \"frac\": 123.456,\n  \"huge\": 1.5e+300,\n  \"neg\": -2.5e-9,\n  \"negzero\": -0,\n  \"p60\": 1152921504606847000,\n  \"small\": 1e-7,\n  \"tenth\": 0.1,\n  \"third\": 0.3333333333333333,\n  \"tiny\": 0.0000012\n}\n"''',
  'printany_strings': r'''"      name: n\n      arguments: [\n  \"tab\\there\",\n  \"nl\\nx\",\n  \"ctl\\u0001\\u001f\",\n  \"uni é ✓ 😀\",\n  \"ls\\u2028ps\\u2029\",\n  \"q\\\"b\\\\\",\n  \"html\\u003ca href='x'\\u003e\\u0026amp;\\u003c/a\\u003e\",\n  \"del\u007f\",\n  \"bf\\b\\f\"\n]\n"''',
  'printany_nested': r'''"      name: n\n      arguments: {\n  \"Z\": 2,\n  \"a\": {},\n  \"aa\": 3,\n  \"b\": [],\n  \"c\": [\n    {\n      \"y\": true,\n      \"z\": null\n    }\n  ],\n  \"é\": 1\n}\n"''',
  'printany_bool': r'''"      name: n\n      arguments: false\n"''',
  'printany_emptylist': r'''"      name: n\n      arguments: []\n"''',
  'printany_int': r'''"      name: n\n      arguments: 42\n"''',
  'trunc_img': r'''"      url: uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu...\n      file_id: fid\n      base64_data: bbbbbbbbbbbbbbbbbbbb...... (25 bytes)\n"''',
  'trunc_unibytes': r'''"      name: n\n      base64_data: éééééééééé...... (22 bytes)\n"''',
  'json_full': r'''{"role":"assistant","content_blocks":[{"type":"reasoning","reasoning":{"text":"t","signature":"s","openai_extension":{"content":[{"index":2,"text":"x"},{"text":"y"}]}}},{"type":"user_input_text","user_input_text":{"text":"hi"},"streaming_meta":{"index":0}},{"type":"user_input_image","user_input_image":{"url":"u","detail":"low"}},{"type":"user_input_audio","user_input_audio":{}},{"type":"user_input_video","user_input_video":{"file_id":"f"}},{"type":"user_input_file","user_input_file":{"name":"a.pdf","mime_type":"application/pdf"}},{"type":"assistant_gen_text","assistant_gen_text":{"text":"g","openai_extension":{"refusal":{"reason":"r"},"annotations":[{"index":1,"type":"url_citation","url_citation":{"title":"T","url":"U","end_index":3}}]},"claude_extension":{"citations":[{"type":"char_location","char_location":{"cited_text":"c","document_index":1,"end_char_index":5}}]},"extension":{"k":"v"}}},{"type":"assistant_gen_image","assistant_gen_image":{"base64_data":"b"}},{"type":"assistant_gen_audio","assistant_gen_audio":{}},{"type":"assistant_gen_video","assistant_gen_video":{"url":"v"}},{"type":"function_tool_call","function_tool_call":{"name":""}},{"type":"function_tool_result","function_tool_result":{"call_id":"c","name":"","content":[{"type":"image","image":{"url":"i"},"extra":{"e":1}},{"type":"text","text":{}}]}},{"type":"server_tool_call","server_tool_call":{"name":"","arguments":[1,"a"]}},{"type":"server_tool_result","server_tool_result":{"name":"s","content":"x"}},{"type":"mcp_tool_call","mcp_tool_call":{"approval_request_id":"a","name":""}},{"type":"mcp_tool_result","mcp_tool_result":{"name":"","error":{"code":7}}},{"type":"mcp_list_tools_result","mcp_list_tools_result":{"tools":[{"name":"t","description":""}]}},{"type":"mcp_tool_approval_request","mcp_tool_approval_request":{"name":""}},{"type":"mcp_tool_approval_response","mcp_tool_approval_response":{"approve":false}}],"response_meta":{"token_usage":{"prompt_tokens":1,"prompt_token_details":{"cached_tokens":4,"cache_write_tokens":0},"completion_tokens":2,"total_tokens":3,"completion_token_details":{"reasoning_tokens":5}},"openai_extension":{"id":"r","status":"completed","error":{"code":"server_error","message":"m"},"incomplete_details":{"reason":"x"},"previous_response_id":"p","reasoning":{"effort":"high","summary":"auto"},"service_tier":"flex","created_at":9,"prompt_cache_retention":"24h"},"gemini_extension":{"id":"g","finish_reason":"STOP","grounding_meta":{"grounding_chunks":[{"web":{"title":"t","uri":"u"}}],"grounding_supports":[{"confidence_scores":[0.5],"grounding_chunk_indices":[0],"segment":{"end_index":4,"text":"s"}}],"search_entry_point":{"rendered_content":"\u003cb\u003e","sdk_blob":"AQL/"},"web_search_queries":["q"]}},"claude_extension":{"id":"c","stop_reason":"end_turn","stop_details":{"category":"x"}},"extension":{"n":1.5}},"extra":{"x":[1,true,null]}}''',
  'json_empty': '{"role":"user"}',
  'json_zerousage': '{"token_usage":{"prompt_tokens":0,"prompt_token_details":{"cached_tokens":0,"cache_write_tokens":0},"completion_tokens":0,"total_tokens":0,"completion_token_details":{}}}',
  'json_toolchoice': '{"Type":"forced","Allowed":null,"Forced":{"Tools":[{"FunctionName":"f","MCPTool":null,"ServerTool":null},{"FunctionName":"","MCPTool":{"ServerLabel":"s","Name":"n"},"ServerTool":null},{"FunctionName":"","MCPTool":null,"ServerTool":{"Name":"w"}}]}}',
  'json_toolchoice2': '{"Type":"allowed","Allowed":{"Tools":null},"Forced":null}',
};

/// The `String()` golden [name], decoded.
String _string(String name) => jsonDecode(_goldens[name]!) as String;

/// The JSON golden [name], decoded.
Object? _json(String name) => jsonDecode(_goldens[name]!);

String _serverCall(Object? arguments) =>
    ServerToolCall(name: 'n', arguments: arguments).toString();

final AgenticMessage _full = AgenticMessage(
  role: AgenticRoleType.assistant,
  contentBlocks: [
    ContentBlock(
      Reasoning(
        text: 't',
        signature: 's',
        openAIExtension: OpenAIReasoningExtension(
          content: const [
            OpenAIReasoningContent(index: 2, text: 'x'),
            OpenAIReasoningContent(text: 'y'),
          ],
        ),
      ),
    ),
    ContentBlock(
      const UserInputText(text: 'hi'),
      streamingMeta: const StreamingMeta(index: 0),
    ),
    ContentBlock(const UserInputImage(url: 'u', detail: ImageURLDetail.low)),
    ContentBlock(const UserInputAudio()),
    ContentBlock(const UserInputVideo(fileId: 'f')),
    ContentBlock(
      const UserInputFile(name: 'a.pdf', mimeType: 'application/pdf'),
    ),
    ContentBlock(
      AssistantGenText(
        text: 'g',
        openAIExtension: OpenAIAssistantGenTextExtension(
          refusal: const OpenAIOutputRefusal(reason: 'r'),
          annotations: const [
            OpenAITextAnnotation(
              index: 1,
              type: OpenAITextAnnotationType.urlCitation,
              urlCitation: OpenAITextAnnotationUrlCitation(
                title: 'T',
                url: 'U',
                endIndex: 3,
              ),
            ),
          ],
        ),
        claudeExtension: ClaudeAssistantGenTextExtension(
          citations: const [
            ClaudeTextCitation(
              type: ClaudeTextCitationType.charLocation,
              charLocation: ClaudeCitationCharLocation(
                citedText: 'c',
                documentIndex: 1,
                endCharIndex: 5,
              ),
            ),
          ],
        ),
        extension: const {'k': 'v'},
      ),
    ),
    ContentBlock(const AssistantGenImage(base64Data: 'b')),
    ContentBlock(const AssistantGenAudio()),
    ContentBlock(const AssistantGenVideo(url: 'v')),
    ContentBlock(const FunctionToolCall()),
    ContentBlock(
      FunctionToolResult(
        callId: 'c',
        content: [
          FunctionToolResultContentBlock(
            const UserInputImage(url: 'i'),
            extra: const {'e': 1},
          ),
          FunctionToolResultContentBlock(const UserInputText()),
        ],
      ),
    ),
    ContentBlock(const ServerToolCall(arguments: [1, 'a'])),
    ContentBlock(const ServerToolResult(name: 's', content: 'x')),
    ContentBlock(const AgenticMcpToolCall(approvalRequestId: 'a')),
    ContentBlock(
      const AgenticMcpToolResult(error: AgenticMcpToolCallError(code: 7)),
    ),
    ContentBlock(
      AgenticMcpListToolsResult(tools: [AgenticMcpListToolsItem(name: 't')]),
    ),
    ContentBlock(const AgenticMcpToolApprovalRequest()),
    ContentBlock(const AgenticMcpToolApprovalResponse()),
  ],
  responseMeta: AgenticResponseMeta(
    tokenUsage: const TokenUsage(
      promptTokens: 1,
      completionTokens: 2,
      totalTokens: 3,
      promptTokenDetails: PromptTokenDetails(cachedTokens: 4),
      completionTokenDetails: CompletionTokenDetails(reasoningTokens: 5),
    ),
    openAIExtension: const OpenAIResponseMetaExtension(
      id: 'r',
      status: OpenAIResponseStatus.completed,
      error: OpenAIResponseError(
        code: OpenAIResponseErrorCode.serverError,
        message: 'm',
      ),
      incompleteDetails: OpenAIIncompleteDetails(reason: 'x'),
      previousResponseId: 'p',
      reasoning: OpenAIReasoning(
        effort: OpenAIReasoningEffort.high,
        summary: OpenAIReasoningSummary.auto,
      ),
      serviceTier: OpenAIServiceTier.flex,
      createdAt: 9,
      promptCacheRetention: OpenAIPromptCacheRetention.hours24,
    ),
    geminiExtension: GeminiResponseMetaExtension(
      id: 'g',
      finishReason: 'STOP',
      groundingMeta: GeminiGroundingMetadata(
        groundingChunks: const [
          GeminiGroundingChunk(
            web: GeminiGroundingChunkWeb(title: 't', uri: 'u'),
          ),
        ],
        groundingSupports: [
          GeminiGroundingSupport(
            confidenceScores: const [0.5],
            groundingChunkIndices: const [0],
            segment: const GeminiSegment(endIndex: 4, text: 's'),
          ),
        ],
        searchEntryPoint: GeminiSearchEntryPoint(
          renderedContent: '<b>',
          sdkBlob: const [1, 2, 255],
        ),
        webSearchQueries: const ['q'],
      ),
    ),
    claudeExtension: const ClaudeResponseMetaExtension(
      id: 'c',
      stopReason: 'end_turn',
      stopDetails: ClaudeStopDetails(category: 'x'),
    ),
    extension: const {'n': 1.5},
  ),
  extra: const {
    'x': [1, true, null],
  },
);

void main() {
  group('printAny (ServerToolCall.String) as Go writes it', () {
    test('floats: shortest digits, exponents from 1e21 and below 1e-6', () {
      expect(
        _serverCall({
          'big': 1e21,
          'small': 1e-7,
          'tenth': 0.1,
          'e20': 1e20,
          'negzero': -0.0,
          'third': 1 / 3,
          'tiny': 1.2e-6,
          'huge': 1.5e300,
          'neg': -2.5e-9,
          'p60': 1152921504606846976.0,
          'e19': 1e19,
          'frac': 123.456,
        }),
        _string('printany_floats'),
      );
    });

    test('strings: escapes, HTML characters, U+2028/9, DEL kept', () {
      expect(
        _serverCall([
          'tab\there',
          'nl\nx',
          'ctl\u0001\u001f',
          'uni é ✓ 😀',
          'ls${String.fromCharCode(0x2028)}ps${String.fromCharCode(0x2029)}',
          r'q"b\',
          "html<a href='x'>&amp;</a>",
          'del\u007f',
          'bf\b\f',
        ]),
        _string('printany_strings'),
      );
    });

    test('nested maps and lists, keys sorted by their bytes', () {
      expect(
        _serverCall({
          'b': <Object?>[],
          'a': <String, Object?>{},
          'c': [
            {'z': null, 'y': true},
          ],
          'é': 1,
          'Z': 2,
          'aa': 3,
        }),
        _string('printany_nested'),
      );
    });

    test('scalars and an empty list', () {
      expect(_serverCall(false), _string('printany_bool'));
      expect(_serverCall(<Object?>[]), _string('printany_emptylist'));
      expect(_serverCall(42), _string('printany_int'));
    });
  });

  group('truncateString and formatMediaString as Go writes them', () {
    test('a long URL and base64 data', () {
      expect(
        UserInputImage(
          url: 'u' * 120,
          base64Data: 'b' * 25,
          fileId: 'fid',
        ).toString(),
        _string('trunc_img'),
      );
    });

    test('lengths and cuts count bytes of UTF-8', () {
      expect(
        UserInputFile(name: 'n', base64Data: 'é' * 11).toString(),
        _string('trunc_unibytes'),
      );
    });
  });

  group('encoding/json output', () {
    test('a message with every block type and every extension', () {
      final goJson = _goldens['json_full']!;
      // Same keys, same order, same omissions: byte for byte once both are
      // written by dart:convert (Go escapes `<`, `>` and `&`, Dart does not).
      expect(jsonEncode(_full.toJson()), jsonEncode(jsonDecode(goJson)));
      expect(
        AgenticMessage.fromJson(jsonDecode(goJson) as Map<String, Object?>),
        _full,
      );
    });

    test('an empty message and a zero token usage', () {
      expect(
        jsonEncode(AgenticMessage(role: AgenticRoleType.user).toJson()),
        _goldens['json_empty'],
      );
      expect(
        const AgenticResponseMeta(tokenUsage: TokenUsage.zero).toJson(),
        _json('json_zerousage'),
      );
    });

    test('AgenticToolChoice (untagged Go structs)', () {
      final forced = AgenticToolChoice(
        type: ToolChoice.forced,
        forced: AgenticForcedToolChoice(
          tools: const [
            AllowedFunctionTool('f'),
            AllowedMcpTool(serverLabel: 's', name: 'n'),
            AllowedServerTool('w'),
          ],
        ),
      );
      expect(jsonEncode(forced.toJson()), _goldens['json_toolchoice']);
      expect(
        AgenticToolChoice.fromJson(
          _json('json_toolchoice')! as Map<String, Object?>,
        ),
        forced,
      );
      final allowed = AgenticToolChoice(
        type: ToolChoice.allowed,
        allowed: AgenticAllowedToolChoice(),
      );
      expect(jsonEncode(allowed.toJson()), _goldens['json_toolchoice2']);
    });
  });
}
