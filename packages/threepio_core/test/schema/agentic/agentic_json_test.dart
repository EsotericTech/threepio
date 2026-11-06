// JSON round trips and Go's JSON shape for every agentic schema type
// (`schema/agentic_message.go`, `schema/{openai,claude,gemini}/extension.go`,
// the AgenticToolChoice part of `schema/tool.go`), plus value equality.
//
// Go has no JSON test for these types; the expected shapes follow the
// struct tags of eino v0.9.22 (snake_case keys, `omitempty`).

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

/// Round-trips [message] through text JSON, as a checkpoint would.
AgenticMessage _roundTrip(AgenticMessage message) => AgenticMessage.fromJson(
      jsonDecode(jsonEncode(message.toJson())) as Map<String, Object?>,
    );

@immutable
final class _Ext {
  const _Ext(this.value);

  factory _Ext.fromJson(Map<String, Object?> json) =>
      _Ext(json['value']! as String);

  final String value;

  Map<String, Object?> toJson() => {'value': value};

  @override
  bool operator ==(Object other) => other is _Ext && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

void main() {
  final openAIText = OpenAIAssistantGenTextExtension(
    refusal: const OpenAIOutputRefusal(reason: 'no'),
    annotations: const [
      OpenAITextAnnotation(
        index: 1,
        type: OpenAITextAnnotationType.fileCitation,
        fileCitation: OpenAITextAnnotationFileCitation(
          fileId: 'f1',
          filename: 'a.pdf',
          index: 2,
        ),
      ),
      OpenAITextAnnotation(
        type: OpenAITextAnnotationType.urlCitation,
        urlCitation: OpenAITextAnnotationUrlCitation(
          title: 't',
          url: 'https://x',
          startIndex: 1,
          endIndex: 5,
        ),
      ),
      OpenAITextAnnotation(
        type: OpenAITextAnnotationType.containerFileCitation,
        containerFileCitation: OpenAITextAnnotationContainerFileCitation(
          containerId: 'c',
          fileId: 'f',
          filename: 'n',
          startIndex: 3,
          endIndex: 4,
        ),
      ),
      OpenAITextAnnotation(
        type: OpenAITextAnnotationType.filePath,
        filePath: OpenAITextAnnotationFilePath(fileId: 'p', index: 7),
      ),
    ],
  );

  final claudeText = ClaudeAssistantGenTextExtension(
    citations: const [
      ClaudeTextCitation(
        type: ClaudeTextCitationType.charLocation,
        charLocation: ClaudeCitationCharLocation(
          citedText: 'c',
          documentTitle: 'd',
          documentIndex: 1,
          startCharIndex: 2,
          endCharIndex: 3,
        ),
      ),
      ClaudeTextCitation(
        type: ClaudeTextCitationType.pageLocation,
        pageLocation: ClaudeCitationPageLocation(
          citedText: 'p',
          startPageNumber: 1,
          endPageNumber: 2,
        ),
      ),
      ClaudeTextCitation(
        type: ClaudeTextCitationType.contentBlockLocation,
        contentBlockLocation: ClaudeCitationContentBlockLocation(
          citedText: 'b',
          startBlockIndex: 0,
          endBlockIndex: 5,
        ),
      ),
      ClaudeTextCitation(
        type: ClaudeTextCitationType.webSearchResultLocation,
        webSearchResultLocation: ClaudeCitationWebSearchResultLocation(
          citedText: 'w',
          title: 'T',
          url: 'https://w',
          encryptedIndex: 'e',
        ),
      ),
    ],
  );

  final everyBlock = AgenticMessage(
    role: AgenticRoleType.assistant,
    contentBlocks: [
      ContentBlock(
        Reasoning(
          text: 'think',
          signature: 'sig',
          openAIExtension: OpenAIReasoningExtension(
            content: const [
              OpenAIReasoningContent(index: 0, text: 'a'),
              OpenAIReasoningContent(text: 'b'),
            ],
          ),
        ),
      ),
      ContentBlock(const UserInputText(text: 'hi')),
      ContentBlock(
        const UserInputImage(
          url: 'u',
          base64Data: 'b',
          fileId: 'f',
          mimeType: 'image/png',
          detail: ImageURLDetail.high,
        ),
      ),
      ContentBlock(
        const UserInputAudio(
          url: 'u',
          base64Data: 'b',
          fileId: 'f',
          mimeType: 'audio/wav',
        ),
      ),
      ContentBlock(
        const UserInputVideo(
          url: 'u',
          base64Data: 'b',
          fileId: 'f',
          mimeType: 'video/mp4',
        ),
      ),
      ContentBlock(
        const UserInputFile(
          url: 'u',
          name: 'n',
          base64Data: 'b',
          fileId: 'f',
          mimeType: 'text/plain',
        ),
      ),
      ContentBlock(
        ToolSearchFunctionToolResult(
          callId: 'ts',
          name: 'search',
          result: ToolSearchResult(
            tools: [
              ToolInfo.fromParams(
                name: 'get_weather',
                desc: 'weather',
                params: {
                  'city': const ParameterInfo(
                    type: DataType.string,
                    required: true,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
      ContentBlock(
        AssistantGenText(
          text: 'answer',
          openAIExtension: openAIText,
          extension: const {'k': 'v'},
        ),
      ),
      ContentBlock(AssistantGenText(text: 'cited', claudeExtension: claudeText)),
      ContentBlock(
        const AssistantGenImage(url: 'u', base64Data: 'b', mimeType: 'm'),
      ),
      ContentBlock(
        const AssistantGenAudio(url: 'u', base64Data: 'b', mimeType: 'm'),
      ),
      ContentBlock(
        const AssistantGenVideo(url: 'u', base64Data: 'b', mimeType: 'm'),
      ),
      ContentBlock(
        const FunctionToolCall(callId: 'c1', name: 'f', arguments: '{}'),
        streamingMeta: const StreamingMeta(index: 0),
        extra: const {'n': 1, 'nested': {'x': true}},
      ),
      ContentBlock(
        FunctionToolResult(
          callId: 'c1',
          name: 'f',
          content: [
            FunctionToolResultContentBlock(const UserInputText(text: 't')),
            FunctionToolResultContentBlock(
              const UserInputImage(url: 'i'),
              extra: const {'e': 1},
            ),
            FunctionToolResultContentBlock(const UserInputAudio(url: 'a')),
            FunctionToolResultContentBlock(const UserInputVideo(url: 'v')),
            FunctionToolResultContentBlock(
              const UserInputFile(name: 'f.txt', base64Data: 'QQ=='),
            ),
          ],
        ),
      ),
      ContentBlock(
        const ServerToolCall(
          name: 'web_search',
          callId: 's1',
          arguments: {
            'query': 'q',
            'n': [1, 2],
          },
        ),
      ),
      ContentBlock(
        const ServerToolResult(name: 'web_search', callId: 's1', content: 'ok'),
      ),
      ContentBlock(
        const AgenticMcpToolCall(
          serverLabel: 'srv',
          approvalRequestId: 'ap',
          callId: 'm1',
          name: 'tool',
          arguments: '{"a":1}',
        ),
      ),
      ContentBlock(
        const AgenticMcpToolResult(
          serverLabel: 'srv',
          callId: 'm1',
          name: 'tool',
          content: '{}',
          error: AgenticMcpToolCallError(code: 500, message: 'boom'),
        ),
      ),
      ContentBlock(
        AgenticMcpListToolsResult(
          serverLabel: 'srv',
          tools: [
            AgenticMcpListToolsItem(
              name: 'tool',
              description: 'd',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'a': {'type': 'integer'},
                },
              },
            ),
          ],
          error: 'partial',
        ),
      ),
      ContentBlock(
        const AgenticMcpToolApprovalRequest(
          id: 'ap',
          name: 'tool',
          arguments: '{}',
          serverLabel: 'srv',
        ),
      ),
      ContentBlock(
        const AgenticMcpToolApprovalResponse(
          approvalRequestId: 'ap',
          approve: true,
          reason: 'fine',
        ),
      ),
    ],
    responseMeta: AgenticResponseMeta(
      tokenUsage: const TokenUsage(
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
        promptTokenDetails:
            PromptTokenDetails(cachedTokens: 3, cacheWriteTokens: 2),
        completionTokenDetails: CompletionTokenDetails(
          reasoningTokens: 1,
          imageTokens: 4,
        ),
        cost: 0.25,
      ),
      openAIExtension: const OpenAIResponseMetaExtension(
        id: 'resp',
        status: OpenAIResponseStatus.completed,
        error: OpenAIResponseError(
          code: OpenAIResponseErrorCode.serverError,
          message: 'm',
        ),
        incompleteDetails: OpenAIIncompleteDetails(reason: 'max_tokens'),
        previousResponseId: 'prev',
        reasoning: OpenAIReasoning(
          effort: OpenAIReasoningEffort.high,
          summary: OpenAIReasoningSummary.auto,
        ),
        serviceTier: OpenAIServiceTier.flex,
        createdAt: 1700000000,
        promptCacheRetention: OpenAIPromptCacheRetention.hours24,
      ),
      claudeExtension: const ClaudeResponseMetaExtension(
        id: 'msg',
        stopReason: 'end_turn',
        stopSequence: 'STOP',
        stopDetails: ClaudeStopDetails(category: 'c', explanation: 'e'),
      ),
      geminiExtension: GeminiResponseMetaExtension(
        id: 'g',
        finishReason: 'STOP',
        groundingMeta: GeminiGroundingMetadata(
          groundingChunks: const [
            GeminiGroundingChunk(
              web: GeminiGroundingChunkWeb(
                domain: 'd',
                title: 't',
                uri: 'https://g',
              ),
            ),
          ],
          groundingSupports: [
            GeminiGroundingSupport(
              confidenceScores: const [0.5, 0.25],
              groundingChunkIndices: const [0, 2],
              segment: const GeminiSegment(
                endIndex: 4,
                partIndex: 1,
                startIndex: 2,
                text: 'seg',
              ),
            ),
          ],
          searchEntryPoint: GeminiSearchEntryPoint(
            renderedContent: '<div/>',
            sdkBlob: const [1, 2, 3],
          ),
          webSearchQueries: const ['q1', 'q2'],
        ),
      ),
      extension: 'other',
    ),
    extra: const {
      'trace': 'abc',
      'list': [1, 'two'],
    },
  );

  group('round trip', () {
    test('a message with every block type and every extension', () {
      final back = _roundTrip(everyBlock);
      expect(back, everyBlock);
      expect(back.hashCode, everyBlock.hashCode);
      expect(back.toJson(), everyBlock.toJson());
    });

    test('each block on its own', () {
      for (final block in everyBlock.contentBlocks) {
        final json =
            jsonDecode(jsonEncode(block.toJson())) as Map<String, Object?>;
        expect(ContentBlock.fromJson(json), block, reason: '${block.type}');
      }
    });

    test('zero-valued payloads', () {
      final message = AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [
          ContentBlock(const Reasoning()),
          ContentBlock(const UserInputText()),
          ContentBlock(const UserInputImage()),
          ContentBlock(const UserInputAudio()),
          ContentBlock(const UserInputVideo()),
          ContentBlock(const UserInputFile()),
          ContentBlock(const ToolSearchFunctionToolResult()),
          ContentBlock(const AssistantGenText()),
          ContentBlock(const AssistantGenImage()),
          ContentBlock(const AssistantGenAudio()),
          ContentBlock(const AssistantGenVideo()),
          ContentBlock(const FunctionToolCall()),
          ContentBlock(FunctionToolResult()),
          ContentBlock(const ServerToolCall()),
          ContentBlock(const ServerToolResult()),
          ContentBlock(const AgenticMcpToolCall()),
          ContentBlock(const AgenticMcpToolResult()),
          ContentBlock(AgenticMcpListToolsResult()),
          ContentBlock(const AgenticMcpToolApprovalRequest()),
          ContentBlock(const AgenticMcpToolApprovalResponse()),
        ],
      );
      expect(_roundTrip(message), message);
    });

    test('a value of a registered type in an extension field', () {
      TypeRegistry.registerName<_Ext>(
        'agentic_json_test_ext',
        fromJson: _Ext.fromJson,
        toJson: (value) => value.toJson(),
      );
      addTearDown(TypeRegistry.reset);

      final message = AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(const AssistantGenText(text: 'x', extension: _Ext('a'))),
          ContentBlock(const ServerToolCall(name: 's', arguments: _Ext('b'))),
          ContentBlock(const ServerToolResult(name: 's', content: _Ext('c'))),
        ],
        responseMeta: const AgenticResponseMeta(extension: _Ext('d')),
        extra: const {'ext': _Ext('e')},
      );
      final back = _roundTrip(message);
      expect(back, message);
      expect(back.contentBlocks[0].assistantGenText!.extension, isA<_Ext>());
      expect(back.extra!['ext'], const _Ext('e'));
    });

    test('in memory, without text JSON in between', () {
      expect(TypeRegistry.decode(TypeRegistry.encode(everyBlock)), everyBlock);
      final withDollarKey = AgenticMessage(
        role: AgenticRoleType.user,
        extra: const {
          'meta': {r'$type': 'not a registered name'},
        },
      );
      expect(
        TypeRegistry.decode(TypeRegistry.encode(withDollarKey)),
        withDollarKey,
      );
    });

    test('a value of an unregistered type cannot be written', () {
      final message = AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(const AssistantGenText(extension: _Ext('a'))),
        ],
      );
      expect(message.toJson, throwsArgumentError);
    });

    test('TypeRegistry built-ins: _eino_agentic_message(_slice)', () {
      final encoded = TypeRegistry.encode(everyBlock)! as Map<String, Object?>;
      expect(encoded[r'$type'], '_eino_agentic_message');
      expect(
        TypeRegistry.decode(jsonDecode(jsonEncode(encoded))),
        everyBlock,
      );

      final list = [AgenticMessage.user('a'), everyBlock];
      final encodedList = TypeRegistry.encode(list)! as Map<String, Object?>;
      expect(encodedList[r'$type'], '_eino_agentic_message_slice');
      final decoded = TypeRegistry.decode(jsonDecode(jsonEncode(encodedList)));
      expect(decoded, isA<List<AgenticMessage>>());
      expect(decoded, list);
      expect(TypeRegistry.isRegistered<AgenticMessage>(), isTrue);
      expect(TypeRegistry.isRegistered<List<AgenticMessage>>(), isTrue);
    });
  });

  group("Go's JSON shape", () {
    test('a block nests its payload under its type', () {
      final block = ContentBlock(
        const FunctionToolCall(callId: 'c', name: 'f', arguments: '{}'),
        streamingMeta: const StreamingMeta(index: 0),
        extra: const {'k': 'v'},
      );
      expect(block.toJson(), {
        'type': 'function_tool_call',
        'function_tool_call': {'call_id': 'c', 'name': 'f', 'arguments': '{}'},
        'streaming_meta': {'index': 0},
        'extra': {'k': 'v'},
      });
      expect(jsonEncode(block.toJson()), startsWith('{"type":'));
    });

    test('omitempty: empty fields are left out, names and flags are not', () {
      expect(ContentBlock(const FunctionToolCall()).toJson(), {
        'type': 'function_tool_call',
        'function_tool_call': {'name': ''},
      });
      expect(ContentBlock(const AgenticMcpToolApprovalResponse()).toJson(), {
        'type': 'mcp_tool_approval_response',
        'mcp_tool_approval_response': {'approve': false},
      });
      expect(ContentBlock(const UserInputText()).toJson(), {
        'type': 'user_input_text',
        'user_input_text': <String, Object?>{},
      });
      expect(AgenticMcpListToolsItem().toJson(), {
        'name': '',
        'description': '',
      });
      expect(AgenticMessage(role: AgenticRoleType.user).toJson(), {
        'role': 'user',
      });
    });

    test('the tool search payload key', () {
      final json = ContentBlock(const ToolSearchFunctionToolResult(name: 's'))
          .toJson();
      expect(json['type'], 'tool_search_result');
      expect(json.containsKey('tool_search_function_tool_result'), isTrue);
    });

    test('function tool result content blocks', () {
      expect(
        FunctionToolResultContentBlock(const UserInputImage(url: 'u')).toJson(),
        {
          'type': 'image',
          'image': {'url': 'u'},
        },
      );
    });

    test('token usage has Go keys', () {
      const meta = AgenticResponseMeta(
        tokenUsage: TokenUsage(
          promptTokens: 1,
          completionTokens: 2,
          totalTokens: 3,
        ),
      );
      expect(meta.toJson(), {
        'token_usage': {
          'prompt_tokens': 1,
          'prompt_token_details': {'cached_tokens': 0, 'cache_write_tokens': 0},
          'completion_tokens': 2,
          'total_tokens': 3,
          'completion_token_details': <String, Object?>{},
        },
      });
      expect(AgenticResponseMeta.fromJson(meta.toJson()), meta);
    });

    test('the OpenAI response meta extension', () {
      expect(
        const OpenAIResponseMetaExtension(
          id: 'r',
          status: OpenAIResponseStatus.inProgress,
          createdAt: 5,
        ).toJson(),
        {'id': 'r', 'status': 'in_progress', 'created_at': 5},
      );
      expect(
        const OpenAIReasoningContent(index: 0).toJson(),
        {'index': 0},
      );
    });

    test('the Gemini sdk blob is base64', () {
      final json = GeminiSearchEntryPoint(sdkBlob: const [1, 2, 3]).toJson();
      expect(json, {'sdk_blob': 'AQID'});
    });

    test('reads JSON a Go program wrote', () {
      const goJson = '{"role":"assistant","content_blocks":[{"type":'
          '"assistant_gen_text","assistant_gen_text":{"text":"hi",'
          '"openai_extension":{"annotations":[{"type":"url_citation",'
          '"url_citation":{"url":"https://a","start_index":1}}]}},'
          '"streaming_meta":{"index":0}}],"response_meta":{"token_usage":'
          '{"prompt_tokens":1,"prompt_token_details":{"cached_tokens":0,'
          '"cache_write_tokens":0},"completion_tokens":2,"total_tokens":3,'
          '"completion_token_details":{}}}}';
      final message = AgenticMessage.fromJson(
        jsonDecode(goJson) as Map<String, Object?>,
      );
      expect(
        message,
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(
              AssistantGenText(
                text: 'hi',
                openAIExtension: OpenAIAssistantGenTextExtension(
                  annotations: const [
                    OpenAITextAnnotation(
                      type: OpenAITextAnnotationType.urlCitation,
                      urlCitation: OpenAITextAnnotationUrlCitation(
                        url: 'https://a',
                        startIndex: 1,
                      ),
                    ),
                  ],
                ),
              ),
              streamingMeta: const StreamingMeta(index: 0),
            ),
          ],
          responseMeta: const AgenticResponseMeta(
            tokenUsage: TokenUsage(
              promptTokens: 1,
              completionTokens: 2,
              totalTokens: 3,
            ),
          ),
        ),
      );
      expect(jsonEncode(message.toJson()), goJson);
    });

    test('a block without its payload reads as the zero payload', () {
      expect(
        ContentBlock.fromJson(const {'type': 'reasoning'}),
        ContentBlock(const Reasoning()),
      );
    });

    test('unknown roles and block types are format errors', () {
      expect(
        () => AgenticMessage.fromJson(const {'role': 'tool'}),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(
        () => ContentBlock.fromJson(const {'type': 'weird'}),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(
        () => FunctionToolResultContentBlock.fromJson(const {'type': ''}),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'unknown block type: <empty>',
          ),
        ),
      );
    });
  });

  group('AgenticToolChoice', () {
    final choice = AgenticToolChoice(
      type: ToolChoice.forced,
      allowed: AgenticAllowedToolChoice(
        tools: const [AllowedFunctionTool('f')],
      ),
      forced: AgenticForcedToolChoice(
        tools: const [
          AllowedMcpTool(serverLabel: 'srv', name: 'm'),
          AllowedServerTool('web_search'),
        ],
      ),
    );

    test("Go's untagged JSON form", () {
      expect(choice.toJson(), {
        'Type': 'forced',
        'Allowed': {
          'Tools': [
            {'FunctionName': 'f', 'MCPTool': null, 'ServerTool': null},
          ],
        },
        'Forced': {
          'Tools': [
            {
              'FunctionName': '',
              'MCPTool': {'ServerLabel': 'srv', 'Name': 'm'},
              'ServerTool': null,
            },
            {
              'FunctionName': '',
              'MCPTool': null,
              'ServerTool': {'Name': 'web_search'},
            },
          ],
        },
      });
      expect(
        const AgenticToolChoice(type: ToolChoice.allowed).toJson(),
        {'Type': 'allowed', 'Allowed': null, 'Forced': null},
      );
    });

    test('round trip and equality', () {
      final back = AgenticToolChoice.fromJson(
        jsonDecode(jsonEncode(choice.toJson())) as Map<String, Object?>,
      );
      expect(back, choice);
      expect(back.hashCode, choice.hashCode);
      expect(
        back,
        isNot(AgenticToolChoice(type: ToolChoice.forced, allowed: back.allowed)),
      );
    });
  });

  group('equality', () {
    test('is by value and deep', () {
      ContentBlock block() => ContentBlock(
            const ServerToolCall(
              name: 's',
              arguments: {
                'a': [1, 2],
              },
            ),
            extra: const {
              'x': {'y': 1},
            },
          );
      expect(block(), block());
      expect(block().hashCode, block().hashCode);
      expect(
        block(),
        isNot(
          ContentBlock(
            const ServerToolCall(
              name: 's',
              arguments: {
                'a': [1, 3],
              },
            ),
            extra: const {
              'x': {'y': 1},
            },
          ),
        ),
      );
      expect(
        AgenticMessage.user('a'),
        isNot(AgenticMessage.system('a')),
      );
      expect(
        ContentBlock(const UserInputText(text: 'a')),
        isNot(
          ContentBlock(
            const UserInputText(text: 'a'),
            streamingMeta: const StreamingMeta(index: 0),
          ),
        ),
      );
    });
  });
}
