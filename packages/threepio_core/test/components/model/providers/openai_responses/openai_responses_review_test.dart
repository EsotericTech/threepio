// Tests added by the independent review of the OpenAI Responses agentic
// provider (P13 group O). Each one pins a behaviour of eino-ext's
// `agenticopenai` (through `openai-go`) that the first port got wrong.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/openai_compatible/sse.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_convertor.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_event_convertor.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_utils.dart';
import 'package:threepio_core/threepio_core.dart';

import 'openai_responses_fixtures.dart';

final _input = [AgenticMessage.user('hi')];

void main() {
  group('retries and timeouts (openai-go requestconfig.Execute)', () {
    test('a timed-out attempt is not retried', () {
      // openai-go returns the attempt context's error right after the
      // request (`if ctx.Err() != nil { return ctx.Err() }`), before it
      // looks at retrying.
      fakeAsync((async) {
        final fake = FakeOpenAI(
          (request, attempt) => Completer<http.StreamedResponse>().future,
        );
        Object? error;
        unawaited(
          OpenAIResponsesModel(
            config: const OpenAIResponsesConfig(
              model: 'm',
              timeout: Duration(milliseconds: 20),
            ),
            httpClient: fake,
          ).generate(_input).then<void>((_) {}, onError: (Object e) => error = e),
        );
        async.elapse(const Duration(seconds: 30));
        expect(fake.requests, hasLength(1));
        expect(
          error,
          isA<OpenAIResponsesException>()
              .having(
                (e) => e.message,
                'message',
                'failed to create response: request timed out after '
                    '0:00:00.020000',
              )
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        );
      });
    });

    test('a timed-out stream request is not retried', () {
      fakeAsync((async) {
        final fake = FakeOpenAI(
          (request, attempt) => Completer<http.StreamedResponse>().future,
        );
        Object? error;
        unawaited(
          OpenAIResponsesModel(
            config: const OpenAIResponsesConfig(
              model: 'm',
              timeout: Duration(milliseconds: 20),
            ),
            httpClient: fake,
          ).stream(_input).then<void>((_) {}, onError: (Object e) => error = e),
        );
        async.elapse(const Duration(seconds: 30));
        expect(fake.requests, hasLength(1));
        expect(
          error,
          isA<OpenAIResponsesException>().having(
            (e) => e.message,
            'message',
            startsWith('failed to create streaming response: request timed out'),
          ),
        );
      });
    });

    test('a non-finite retry-after header falls back to the backoff', () {
      for (final headers in [
        {'retry-after-ms': 'NaN'},
        {'retry-after-ms': 'Infinity'},
        {'retry-after': '-Infinity'},
        {'retry-after': '1e400'},
      ]) {
        final delay = OpenAIResponsesModel.retryDelay(headers, 0);
        expect(delay.inMilliseconds, inInclusiveRange(375, 500), reason: '$headers');
      }
    });

    test('a 503 with retry-after-ms NaN is retried after the backoff', () {
      fakeAsync((async) {
        final fake = FakeOpenAI(
          (request, attempt) => attempt == 0
              ? jsonResponse(
                  errorBody('busy'),
                  status: 503,
                  headers: {'retry-after-ms': 'NaN'},
                )
              : jsonResponse({
                  'id': 'r',
                  'status': 'completed',
                  'output': <Object?>[],
                }),
        );
        AgenticMessage? out;
        Object? error;
        unawaited(
          OpenAIResponsesModel(
            config: const OpenAIResponsesConfig(model: 'm'),
            httpClient: fake,
          ).generate(_input).then((m) => out = m, onError: (Object e) => error = e),
        );
        async.elapse(const Duration(seconds: 1));
        expect(error, isNull);
        expect(out, isNotNull);
        expect(fake.requests, hasLength(2));
      });
    });
  });

  group('stream events (openai-go ssestream)', () {
    ResponsesStreamConverter converter() {
      final (_, writer) = pipe<AgenticMessage>();
      return ResponsesStreamConverter(
        writer,
        options: const ChatModelOptions(),
        enableAutoCache: false,
      );
    }

    test('an error member that is null gives an empty text, as gjson does',
        () {
      expect(
        () => OpenAIResponsesModel.handleSseEvent(
          const SseEvent(data: '{"error": null}'),
          converter(),
        ),
        throwsA(
          isA<OpenAIResponsesException>().having(
            (e) => e.message,
            'message',
            'failed to read stream: received error while streaming: ',
          ),
        ),
      );
      expect(
        () => OpenAIResponsesModel.handleSseEvent(
          SseEvent(data: jsonEncode({'error': 'boom'})),
          converter(),
        ),
        throwsA(
          isA<OpenAIResponsesException>().having(
            (e) => e.message,
            'message',
            'failed to read stream: received error while streaming: boom',
          ),
        ),
      );
    });

    test('both shapes of a streamed API error are classified alike', () async {
      Future<OpenAIResponsesException> errorOf(String data) async {
        final reader = await OpenAIResponsesModel(
          config: const OpenAIResponsesConfig(model: 'm'),
          httpClient: FakeOpenAI.sse([data]),
        ).stream(_input);
        try {
          await reader.recv();
          fail('no error');
        } on OpenAIResponsesException catch (error) {
          return error;
        } finally {
          await reader.close();
        }
      }

      final payloadServer = await errorOf(
        'data: {"error": {"type": "server_error", "message": "x"}}\n\n',
      );
      expect(payloadServer.isRetryable, isTrue);
      final payloadInvalid = await errorOf(
        'data: {"error": {"type": "invalid_request_error", '
        '"code": "invalid_prompt", "message": "x"}}\n\n',
      );
      expect(payloadInvalid.isRetryable, isFalse);
      expect(payloadInvalid.errorCode, 'invalid_prompt');

      final eventServer = await errorOf(
        'event: error\ndata: {"type": "error", "code": "server_error", '
        '"message": "x"}\n\n',
      );
      expect(eventServer.message, 'received error event: code=server_error message=x');
      expect(eventServer.isRetryable, isTrue);
      final eventLimit = await errorOf(
        'data: {"type": "error", "code": "rate_limit_exceeded", '
        '"message": "x"}\n\n',
      );
      expect(eventLimit.isRetryable, isTrue);
      final eventInvalid = await errorOf(
        'data: {"type": "error", "code": "invalid_prompt", "message": "x"}\n\n',
      );
      expect(eventInvalid.isRetryable, isFalse);
    });
  });

  group('event dispatch (receivedStreamingResponse)', () {
    /// Feeds [events] to a converter; returns the chunks and errors sent.
    Future<List<Object>> run(List<Map<String, Object?>> events) async {
      final (reader, writer) = pipe<AgenticMessage>();
      final converter = ResponsesStreamConverter(
        writer,
        options: const ChatModelOptions(),
        enableAutoCache: false,
      );
      for (final event in events) {
        converter.onEvent(event);
      }
      await writer.close();
      final out = <Object>[];
      for (;;) {
        try {
          out.add(await reader.recv());
        } on StreamEOFException {
          return out;
        } on Object catch (error) {
          out.add(error);
        }
      }
    }

    ContentBlock block(Object chunk) =>
        (chunk as AgenticMessage).contentBlocks.single;

    test('lifecycle events carry the whole response meta', () async {
      final out = await run([
        {
          'type': 'response.incomplete',
          'response': {
            'id': 'resp_1',
            'status': 'incomplete',
            'created_at': 1741476542.9,
            'service_tier': 'default',
            'previous_response_id': 'resp_0',
            'incomplete_details': {'reason': 'max_output_tokens'},
            'reasoning': {'effort': 'low', 'summary': 'auto'},
            'prompt_cache_retention': '24h',
            'usage': {
              'input_tokens': 10,
              'input_tokens_details': {
                'cached_tokens': 4,
                'cache_write_tokens': 3,
              },
              'output_tokens': 7,
              'output_tokens_details': {'reasoning_tokens': 5},
              'total_tokens': 17,
            },
          },
        },
        {
          'type': 'response.failed',
          'response': {
            'id': 'resp_2',
            'status': 'failed',
            'error': {'code': 'server_error', 'message': 'boom'},
          },
        },
      ]);
      expect(out, hasLength(2));
      final incomplete = (out[0] as AgenticMessage).responseMeta!;
      expect((out[0] as AgenticMessage).contentBlocks, isEmpty);
      final ext = incomplete.openAIExtension!;
      expect(ext.id, 'resp_1');
      expect(ext.status, OpenAIResponseStatus.incomplete);
      expect(ext.createdAt, 1741476542);
      expect(ext.serviceTier, OpenAIServiceTier.defaultTier);
      expect(ext.previousResponseId, 'resp_0');
      expect(ext.incompleteDetails!.reason, 'max_output_tokens');
      expect(ext.reasoning!.effort, OpenAIReasoningEffort.low);
      expect(ext.promptCacheRetention, OpenAIPromptCacheRetention.hours24);
      expect(ext.error, isNull);
      final usage = incomplete.tokenUsage!;
      expect(usage.promptTokens, 10);
      expect(usage.promptTokenDetails!.cachedTokens, 4);
      expect(usage.promptTokenDetails!.cacheWriteTokens, 3);
      expect(usage.completionTokens, 7);
      expect(usage.completionTokenDetails!.reasoningTokens, 5);
      expect(usage.totalTokens, 17);

      final failed = (out[1] as AgenticMessage).responseMeta!.openAIExtension!;
      expect(failed.status, OpenAIResponseStatus.failed);
      expect(failed.error!.code, OpenAIResponseErrorCode.serverError);
      expect(failed.error!.message, 'boom');
    });

    test('the delta events Go handles reach their converters', () async {
      final out = await run([
        {
          'type': 'response.refusal.delta',
          'item_id': 'msg_1',
          'output_index': 0,
          'content_index': 0,
          'delta': 'no',
        },
        {
          'type': 'response.reasoning_text.delta',
          'item_id': 'rs_1',
          'output_index': 1,
          'content_index': 0,
          'delta': 'think',
        },
        {
          'type': 'response.mcp_call_arguments.delta',
          'item_id': 'mcp_1',
          'output_index': 2,
          'delta': '{"a"',
        },
        {
          'type': 'response.code_interpreter_call_code.delta',
          'item_id': 'ci_1',
          'output_index': 3,
          'delta': 'print(1)',
        },
        {
          'type': 'response.image_generation_call.partial_image',
          'item_id': 'ig_1',
          'output_index': 4,
          'partial_image_index': 0,
          'partial_image_b64': 'AAAA',
        },
      ]);
      expect(out, hasLength(5));

      final refusal = block(out[0]);
      expect(refusal.streamingMeta!.index, 0);
      expect(
        refusal.assistantGenText!.openAIExtension!.refusal!.reason,
        'no',
      );
      expect(OpenAIResponsesModel.itemStatus(refusal), isNull);

      final reasoning = block(out[1]);
      expect(reasoning.streamingMeta!.index, 1);
      expect(
        reasoning.reasoning!.openAIExtension!.content.single.text,
        'think',
      );

      final mcp = block(out[2]);
      expect(mcp.streamingMeta!.index, 2);
      expect(mcp.mcpToolCall!.arguments, '{"a"');

      final code = block(out[3]);
      expect(code.streamingMeta!.index, 3);
      expect(code.serverToolResult!.name, 'code_interpreter');
      expect(
        (code.serverToolResult!.content! as OpenAIResponsesServerToolResult)
            .codeInterpreter!
            .code,
        'print(1)',
      );

      final image = block(out[4]);
      expect(image.streamingMeta!.index, 4);
      expect(image.serverToolResult!.name, 'image_generation');
      expect(
        (image.serverToolResult!.content! as OpenAIResponsesServerToolResult)
            .imageGeneration!
            .imageBase64,
        'AAAA',
      );
    });

    test('phase events use the call key (web and file search) or the result '
        'key (code interpreter, image generation), as in Go', () async {
      final out = await run([
        // Output 0: a code interpreter whose call and result blocks come
        // from output_item.added (call index 0, result index 1).
        {
          'type': 'response.output_item.added',
          'output_index': 0,
          'item': {
            'type': 'code_interpreter_call',
            'id': 'ci_1',
            'status': 'in_progress',
            'container_id': 'c',
            'code': '',
            'outputs': null,
          },
        },
        {
          'type': 'response.code_interpreter_call.interpreting',
          'item_id': 'ci_1',
          'output_index': 0,
        },
        // Output 1: a web search; its phase is a call block (index 2).
        {
          'type': 'response.web_search_call.searching',
          'item_id': 'ws_1',
          'output_index': 1,
        },
        // Output 2: an image generation; its phase is a result block
        // (index 3).
        {
          'type': 'response.image_generation_call.generating',
          'item_id': 'ig_1',
          'output_index': 2,
        },
        {
          'type': 'response.file_search_call.completed',
          'item_id': 'fs_1',
          'output_index': 3,
        },
      ]);
      final blocks = [for (final chunk in out) block(chunk)];
      expect(blocks, hasLength(6));
      expect(blocks[0].serverToolCall, isNotNull);
      expect(blocks[0].streamingMeta!.index, 0);
      expect(blocks[1].serverToolResult, isNotNull);
      expect(blocks[1].streamingMeta!.index, 1);

      expect(blocks[2].serverToolResult!.name, 'code_interpreter');
      expect(blocks[2].streamingMeta!.index, 1);
      expect(OpenAIResponsesModel.itemStatus(blocks[2]), 'interpreting');

      expect(blocks[3].serverToolCall!.name, 'web_search');
      expect(blocks[3].streamingMeta!.index, 2);
      expect(OpenAIResponsesModel.itemStatus(blocks[3]), 'searching');

      expect(blocks[4].serverToolResult!.name, 'image_generation');
      expect(blocks[4].streamingMeta!.index, 3);
      expect(OpenAIResponsesModel.itemStatus(blocks[4]), 'generating');

      expect(blocks[5].serverToolCall!.name, 'file_search');
      expect(blocks[5].streamingMeta!.index, 4);
      expect(OpenAIResponsesModel.itemStatus(blocks[5]), 'completed');
    });

    test('an output_item.added that cannot be converted is dropped without '
        'an error and uses no index', () async {
      final out = await run([
        {
          'type': 'response.output_item.added',
          'output_index': 0,
          // A code interpreter output of a type Go does not know.
          'item': {
            'type': 'code_interpreter_call',
            'id': 'ci_1',
            'status': 'in_progress',
            'container_id': 'c',
            'code': '',
            'outputs': [
              {'type': 'video', 'url': 'x'},
            ],
          },
        },
        {
          'type': 'response.output_item.added',
          'output_index': 1,
          'item': {
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_1',
            'name': 'f',
            'arguments': '',
            'status': 'in_progress',
          },
        },
      ]);
      expect(out, hasLength(1));
      final call = block(out.single);
      expect(call.functionToolCall!.callId, 'call_1');
      expect(call.streamingMeta!.index, 0);
    });
  });

  group('request items (responses_convertor.go)', () {
    test("a client tool search call keeps Go's json.Marshal text", () {
      final block = toolSearchToolCallToContentBlock(
        {
          'type': 'tool_search_call',
          'id': 'ts1',
          'call_id': 'c1',
          'status': 'completed',
          'execution': 'client',
          'arguments': {
            'query': 'a<b & c>d',
            'limit': 5,
            'boost': 1.0,
            'a': [true, null, 1e-7],
          },
        },
        ChatModelOptions(
          toolSearchTool: ToolInfo.fromParamsOneOf(name: 'search_tools'),
        ),
      );
      expect(
        block.functionToolCall!.arguments,
        '{"a":[true,null,1e-7],"boost":1,"limit":5,'
        r'"query":"a\u003cb \u0026 c\u003ed"}',
      );
    });

    test('goJsonMarshal writes what Go writes', () {
      expect(goJsonMarshal(null), 'null');
      expect(goJsonMarshal(<String, Object?>{}), '{}');
      expect(goJsonMarshal(<Object?>[]), '[]');
      expect(goJsonMarshal({'b': 1, 'a': 2, 'B': 3}), '{"B":3,"a":2,"b":1}');
      expect(goJsonMarshal(1e21), '1e+21');
      expect(goJsonMarshal(123456789.5), '123456789.5');
      expect(goJsonMarshal(-0.0), '-0');
      // A Go float64 cannot hold 2^53 + 1.
      // ignore: avoid_js_rounded_ints
      expect(goJsonMarshal(9007199254740993), '9007199254740992');
      expect(
        goJsonMarshal('"\\\n\t\b\f\u0001\u2028'),
        r'"\"\\\n\t\b\f\u0001\u2028"',
      );
    });

    test('a web search action always carries the required empty query; '
        'a result action always carries its sources', () {
      final call = getWebSearchToolCallActionParam(
        const OpenAIResponsesWebSearchArguments(
          actionType: OpenAIResponsesWebSearchAction.search,
        ),
      );
      expect(call, {'type': 'search', 'query': ''});
      final result = getWebSearchToolResultActionParam(
        const OpenAIResponsesWebSearchResult(
          actionType: OpenAIResponsesWebSearchAction.search,
        ),
      );
      expect(result, {'type': 'search', 'query': '', 'sources': <Object?>[]});
    });

    test('a file search call always carries its queries (required)', () {
      final arguments = OpenAIResponsesFileSearchArguments();
      final item = fileSearchToolCallToInputItem(
        arguments,
        ContentBlock(
          ServerToolCall(
            name: 'file_search',
            arguments: OpenAIResponsesServerToolCallArguments(
              fileSearch: arguments,
            ),
          ),
        ),
      );
      expect(item['queries'], isEmpty);
      expect(item.containsKey('queries'), isTrue);
    });

    test("an allowed function tool without a name is an error, as Go's "
        'empty AllowedTool', () async {
      final fake = FakeOpenAI.json(const {});
      await expectLater(
        OpenAIResponsesModel(
          config: const OpenAIResponsesConfig(model: 'm'),
          httpClient: fake,
        ).generate(
          _input,
          options: ChatModelOptions(
            agenticToolChoice: AgenticToolChoice(
              type: ToolChoice.allowed,
              allowed: AgenticAllowedToolChoice(
                tools: const [AllowedFunctionTool('')],
              ),
            ),
          ),
        ),
        throwsA(
          isA<OpenAIResponsesException>().having(
            (e) => e.message,
            'message',
            'failed to generate request: failed to populate tool choice: '
                'unknown allowed tool type',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('public API', () {
    test('the types can be registered before any model exists', () {
      OpenAIResponsesModel.ensureTypesRegistered();
      OpenAIResponsesModel.ensureTypesRegistered();
      final message = AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(
            ServerToolResult(
              name: 'image_generation',
              content: OpenAIResponsesServerToolResult(
                imageGeneration: OpenAIResponsesImageGenerationResult(
                  imageBase64: 'AAAA',
                ),
              ),
            ),
          ),
        ],
      );
      final back = AgenticMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, Object?>,
      );
      expect(back, message);
    });

    test('text configs with equal JSON schema formats are equal', () {
      OpenAIResponsesTextConfig config() => OpenAIResponsesTextConfig(
            format: OpenAIResponsesTextFormatJsonSchema(
              name: 'answer',
              // A new map every time, so that equality is deep.
              schema: Map.of({
                'type': 'object',
                'properties': Map.of({
                  'a': Map.of({'type': 'string'}),
                }),
              }),
              strict: true,
            ),
          );
      expect(config(), config());
      expect(config().hashCode, config().hashCode);
      expect(
        config(),
        isNot(
          const OpenAIResponsesTextConfig(
            format: OpenAIResponsesTextFormatJsonSchema(
              name: 'answer',
              schema: {'type': 'object'},
            ),
          ),
        ),
      );
    });
  });
}
