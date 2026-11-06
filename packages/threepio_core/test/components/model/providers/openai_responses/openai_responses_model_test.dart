// Port of eino-ext components/model/agenticopenai/responses_model_test.go
// (TestNew, TestModelGenerate, TestModelStream, TestModelGetType,
// TestModelIsCallbacksEnabled, TestResponsesGetOptionsReplacesExtraFields,
// TestPopulateToolsWithDeferredTools) as fixture tests: Go mocks the SDK's
// `ResponseService.New`/`NewStreaming` and `toOutputMessage` with mockey;
// here a fake HTTP client answers with recorded JSON and server-sent events
// (openai_responses_fixtures.dart).
//
// Adapted: Go's "genRequest error" uses the role "invalid", which
// `AgenticRoleType` cannot hold; a block the role does not allow (reasoning
// in a user message) fails the request instead. "toOutputMessage error"
// answers with an output item of an unknown type.
//
// Added for the port: the request body and headers, the prompt cache
// (`previous_response_id`, auto cache), the SDK's retries, cancellation and
// timeouts (with the body subscription released), stream edge cases (error
// events, an `error` payload, invalid JSON, `[DONE]`, the idle timeout),
// streamed chunks joined by concatAgenticMessages, and the callbacks.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_block_extra.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_config.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_exception.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_model.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_options.dart';
import 'package:threepio_core/threepio_core.dart';

import 'openai_responses_fixtures.dart';

const _config = OpenAIResponsesConfig(apiKey: 'test', model: 'gpt-5');

OpenAIResponsesModel _model(
  http.Client client, {
  OpenAIResponsesConfig config = _config,
}) =>
    OpenAIResponsesModel(config: config, httpClient: client);

final _input = [AgenticMessage.user('hi')];

Matcher _throwsWith(String text) => throwsA(
      isA<OpenAIResponsesException>()
          .having((e) => e.message, 'message', contains(text)),
    );

Map<String, Object?> _textResponse(String text, {String id = 'resp_1'}) => {
      'id': id,
      'status': 'completed',
      'output': [
        {
          'type': 'message',
          'id': 'msg_1',
          'status': 'completed',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
          ],
        },
      ],
      'usage': {'input_tokens': 1, 'output_tokens': 2, 'total_tokens': 3},
    };

/// Reads [reader] to its end; returns the chunks and the errors in order.
Future<List<Object>> _drain(StreamReader<AgenticMessage> reader) async {
  final out = <Object>[];
  try {
    for (;;) {
      try {
        out.add(await reader.recv());
      } on StreamEOFException {
        return out;
      } catch (error) {
        out.add(error);
      }
    }
  } finally {
    await reader.close();
  }
}

/// A response body the test feeds, that records being released.
final class _Body {
  _Body() {
    controller = StreamController<List<int>>(onCancel: () => released = true);
  }

  late final StreamController<List<int>> controller;
  bool released = false;

  void add(String text) => controller.add(utf8.encode(text));

  http.StreamedResponse response({int status = 200}) =>
      http.StreamedResponse(controller.stream, status);
}

/// Records every callback with its payload.
final class _Recorder extends ComponentCallbackHandler {
  final List<String> timings = [];
  final List<RunInfo> infos = [];
  AgenticModelCallbackInput? input;
  AgenticModelCallbackOutput? output;
  Object? error;
  final List<AgenticModelCallbackOutput?> chunks = [];
  final Completer<void> streamDone = Completer<void>();

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    timings.add('start');
    infos.add(info);
    this.input = AgenticModelCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    timings.add('end');
    this.output = AgenticModelCallbackOutput.from(output);
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    timings.add('error');
    this.error = error;
    return ctx;
  }

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    timings.add('endStream');
    unawaited(() async {
      try {
        for (final chunk in await output.collectAll()) {
          chunks.add(AgenticModelCallbackOutput.from(chunk));
        }
      } on Object catch (error) {
        this.error = error;
      } finally {
        await output.close();
        streamDone.complete();
      }
    }());
    return ctx;
  }
}

void main() {
  group('TestNew', () {
    test('success', () {
      final model = OpenAIResponsesModel(
        config: const OpenAIResponsesConfig(apiKey: 'test'),
      );
      expect(model.componentTypeName, openAIResponsesImplType);
      model.dispose();
    });

    test('config nil', () {
      final model = OpenAIResponsesModel();
      expect(model.config.apiKey, '');
      model.dispose();
    });
  });

  group('TestModelGenerate', () {
    test('success', () async {
      final fake = FakeOpenAI.json(_textResponse('hello'));
      final out = await _model(fake).generate(_input);
      expect(out.role, AgenticRoleType.assistant);
      expect(out.contentBlocks.first.assistantGenText!.text, 'hello');

      final request = fake.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.openai.com/v1/responses');
      expect(request.headers['Authorization'], 'Bearer test');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(request.body, {
        'model': 'gpt-5',
        'input': [
          {'role': 'user', 'content': 'hi'},
        ],
      });
    });

    test('genRequest error', () async {
      final fake = FakeOpenAI.json(_textResponse('never'));
      final invalid = [
        AgenticMessage(
          role: AgenticRoleType.user,
          contentBlocks: [ContentBlock(const Reasoning(text: 'x'))],
        ),
      ];
      await expectLater(
        _model(fake).generate(invalid),
        _throwsWith(
          'failed to generate request: failed to populate input: invalid '
          'content block type "reasoning" with user role',
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('cli.New error', () async {
      final fake = FakeOpenAI.json(
        errorBody('api error', code: 'invalid_value'),
        status: 400,
      );
      await expectLater(
        _model(fake).generate(_input),
        throwsA(
          isA<OpenAIResponsesException>()
              .having((e) => e.message, 'message',
                  startsWith('failed to create response: '))
              .having((e) => e.message, 'message', contains('api error'))
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.errorCode, 'errorCode', 'invalid_value')
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
    });

    test('toOutputMessage error', () async {
      final fake = FakeOpenAI.json({
        'id': 'r',
        'output': [
          {'type': 'computer_call', 'id': 'c'},
        ],
      });
      await expectLater(
        _model(fake).generate(_input),
        _throwsWith(
          'failed to convert output to message: unknown output item type: '
          'computer_call',
        ),
      );
    });

    test('a complete response with reasoning, citations and a tool call',
        () async {
      final out =
          await _model(FakeOpenAI.json(completeResponse())).generate(_input);
      expect(out.contentBlocks.map((b) => b.type), [
        ContentBlockType.reasoning,
        ContentBlockType.assistantGenText,
        ContentBlockType.functionToolCall,
      ]);
      final reasoning = out.contentBlocks[0];
      expect(reasoning.reasoning!.text, 'Thinking about the weather.');
      expect(reasoning.reasoning!.signature, 'gAAAAenc');
      expect(itemIdOf(reasoning), 'rs_1');
      final text = out.contentBlocks[1].assistantGenText!;
      expect(text.text, 'It is sunny in Paris.');
      expect(
        text.openAIExtension!.annotations.single.urlCitation!.url,
        'https://weather.example',
      );
      expect(OpenAIResponsesModel.itemStatus(out.contentBlocks[1]), 'completed');
      final call = out.contentBlocks[2].functionToolCall!;
      expect(call.callId, 'call_1');
      expect(call.arguments, '{"city":"Paris"}');

      final meta = out.responseMeta!;
      expect(meta.tokenUsage!.promptTokens, 36);
      expect(meta.tokenUsage!.promptTokenDetails!.cachedTokens, 4);
      expect(meta.tokenUsage!.completionTokenDetails!.reasoningTokens, 12);
      expect(meta.tokenUsage!.totalTokens, 123);
      final ext = meta.openAIExtension!;
      expect(ext.id, 'resp_67ccd2bed1ec8190b14f964abc0542670bb6a6b452d3795b');
      expect(ext.status, OpenAIResponseStatus.completed);
      expect(ext.createdAt, 1741476542);
      expect(ext.reasoning!.effort, OpenAIReasoningEffort.low);
      expect(ext.serviceTier, OpenAIServiceTier.defaultTier);
      expect(ext.error, isNull);
      expect(isAutoCached(out), isFalse);
    });

    test('a body that is not JSON fails', () async {
      final fake = FakeOpenAI(
        (request, attempt) =>
            http.StreamedResponse(Stream.value(utf8.encode('<html>')), 200),
      );
      await expectLater(
        _model(fake).generate(_input),
        _throwsWith('failed to create response: invalid JSON response'),
      );
    });
  });

  group('TestModelStream', () {
    test('success', () async {
      final fake = FakeOpenAI.sse(streamedResponse());
      final reader = await _model(fake).stream(_input);
      final chunks = (await _drain(reader)).cast<AgenticMessage>();

      expect(fake.body['stream'], isTrue);
      expect(fake.requests.single.headers['Accept'], 'text/event-stream');
      expect(chunks.first.responseMeta!.openAIExtension!.id, 'resp_1');
      expect(chunks.last.responseMeta!.tokenUsage!.totalTokens, 30);

      final message = concatAgenticMessages(chunks);
      expect(message.contentBlocks.map((b) => b.type), [
        ContentBlockType.reasoning,
        ContentBlockType.assistantGenText,
        ContentBlockType.functionToolCall,
      ]);
      final reasoning = message.contentBlocks[0];
      expect(reasoning.reasoning!.text, 'Thinking hard.\nDone.');
      expect(itemIdOf(reasoning), 'rs_1');
      expect(itemStatusOf(reasoning), 'completed');

      final text = message.contentBlocks[1];
      expect(text.assistantGenText!.text, 'Hi there!');
      expect(itemIdOf(text), 'msg_1');
      expect(itemStatusOf(text), 'completed');
      final annotation =
          text.assistantGenText!.openAIExtension!.annotations.single;
      expect(annotation.urlCitation!.url, 'https://example.com');
      expect(annotation.index, 0);

      final call = message.contentBlocks[2];
      expect(call.functionToolCall!.callId, 'call_1');
      expect(call.functionToolCall!.name, 'get_weather');
      expect(call.functionToolCall!.arguments, '{"city":"Paris"}');
      expect(itemIdOf(call), 'fc_1');
      expect(itemStatusOf(call), 'completed');

      expect(message.responseMeta!.openAIExtension!.id, 'resp_1');
      expect(message.responseMeta!.tokenUsage!.totalTokens, 30);
    });

    test('genRequest error', () async {
      final fake = FakeOpenAI.sse(streamedResponse());
      final invalid = [
        AgenticMessage(
          role: AgenticRoleType.system,
          contentBlocks: [ContentBlock(const AssistantGenText(text: 'x'))],
        ),
      ];
      await expectLater(
        _model(fake).stream(invalid),
        _throwsWith('failed to generate request'),
      );
      expect(fake.requests, isEmpty);
    });

    test('an HTTP error fails stream() itself', () async {
      final fake = FakeOpenAI.json(errorBody('nope'), status: 401);
      await expectLater(
        _model(fake).stream(_input),
        throwsA(
          isA<OpenAIResponsesException>()
              .having(
                (e) => e.message,
                'message',
                startsWith('failed to create streaming response: '),
              )
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('with auto cache every chunk is marked', () async {
      final reader = await _model(
        FakeOpenAI.sse(streamedResponse()),
        config: const OpenAIResponsesConfig(
          apiKey: 'k',
          model: 'm',
          enableAutoCache: true,
        ),
      ).stream(_input);
      final chunks = (await _drain(reader)).cast<AgenticMessage>();
      expect(chunks, isNotEmpty);
      expect(chunks.every(isAutoCached), isTrue);
    });

    test('an error event is delivered and the stream goes on', () async {
      final reader = await _model(
        FakeOpenAI.sse([
          sse({'type': 'error', 'code': 'server_error', 'message': 'oops'}),
          sse({
            'type': 'response.output_text.delta',
            'item_id': 'm',
            'output_index': 0,
            'content_index': 0,
            'delta': 'after',
          }),
        ]),
      ).stream(_input);
      final out = await _drain(reader);
      expect(out, hasLength(2));
      expect(
        (out[0] as OpenAIResponsesException).message,
        'received error event: code=server_error message=oops',
      );
      expect(out[1], isA<AgenticMessage>());
    });

    test('a payload with an error member ends the stream with an error',
        () async {
      final reader = await _model(
        FakeOpenAI.sse([
          'data: {"error": {"message": "overloaded"}}\n\n',
          sse({'type': 'response.created', 'response': <String, Object?>{}}),
        ]),
      ).stream(_input);
      final out = await _drain(reader);
      expect(out, hasLength(1));
      expect(
        (out.single as OpenAIResponsesException).message,
        'failed to read stream: received error while streaming: '
        '{"message":"overloaded"}',
      );
    });

    test('a payload that is not JSON ends the stream with an error', () async {
      final reader = await _model(
        FakeOpenAI.sse(['data: {not json\n\n']),
      ).stream(_input);
      final out = await _drain(reader);
      expect(
        (out.single as OpenAIResponsesException).message,
        startsWith('failed to read stream: '),
      );
    });

    test('[DONE] ends the stream; comments and unknown events are skipped',
        () async {
      final reader = await _model(
        FakeOpenAI.sse([
          ': keep-alive\n\n',
          sse({'type': 'response.queued'}),
          sse({'type': 'response.created', 'response': {'id': 'r'}}),
          'data: [DONE]\n\n',
          sse({'type': 'response.completed', 'response': {'id': 'late'}}),
        ]),
      ).stream(_input);
      final out = (await _drain(reader)).cast<AgenticMessage>();
      expect(out.map((m) => m.responseMeta!.openAIExtension!.id), ['r']);
    });

    test('an event split across reads and without a trailing blank line',
        () async {
      final text = jsonEncode({
        'type': 'response.output_text.delta',
        'item_id': 'm',
        'output_index': 0,
        'content_index': 0,
        'delta': 'joined',
      });
      final reader = await _model(
        FakeOpenAI.sse([
          'event: response.output_text.delta\nda',
          'ta: ${text.substring(0, 10)}',
          text.substring(10),
        ]),
      ).stream(_input);
      final out = (await _drain(reader)).cast<AgenticMessage>();
      expect(out.single.contentBlocks.single.assistantGenText!.text, 'joined');
    });

    test('the idle timeout ends a silent stream', () async {
      final body = _Body();
      final reader = await _model(
        FakeOpenAI((request, attempt) => body.response()),
        config: const OpenAIResponsesConfig(
          apiKey: 'k',
          model: 'm',
          idleTimeout: Duration(milliseconds: 20),
        ),
      ).stream(_input);
      final out = await _drain(reader);
      expect(
        (out.single as OpenAIResponsesException).message,
        contains('stream idle'),
      );
      expect(body.released, isTrue);
      await body.controller.close();
    });

    test('a reader closed early releases the body', () async {
      final body = _Body();
      final reader = await _model(
        FakeOpenAI((request, attempt) => body.response()),
      ).stream(_input);
      body.add(sse({'type': 'response.created', 'response': {'id': 'r'}}));
      await reader.recv();
      await reader.close();
      body.add(sse({'type': 'response.created', 'response': {'id': 'r'}}));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(body.released, isTrue);
      await body.controller.close();
    });
  });

  test('TestModelGetType', () {
    expect(_model(FakeOpenAI.json(const {})).componentTypeName,
        'AgenticOpenAI/Responses');
  });

  test('TestModelIsCallbacksEnabled', () {
    expect(_model(FakeOpenAI.json(const {})).isCallbacksEnabled, isTrue);
  });

  test('TestResponsesGetOptionsReplacesExtraFields', () {
    const defaults = {'default': 'value', 'override': 'default'};
    final model = _model(
      FakeOpenAI.json(const {}),
      config: const OpenAIResponsesConfig(extraFields: defaults),
    );
    final (_, first) = model.resolveOptions(
      const OpenAIResponsesOptions(
        extraFields: {'request': 'value', 'override': 'request'},
      ).toOptions(),
    );
    expect(first.extraFields, {'request': 'value', 'override': 'request'});
    expect(defaults, {'default': 'value', 'override': 'default'});

    final (_, empty) = model.resolveOptions(
      const OpenAIResponsesOptions(extraFields: {}).toOptions(),
    );
    expect(empty.extraFields, isNotNull);
    expect(empty.extraFields, isEmpty);

    final (_, second) = model.resolveOptions(null);
    expect(second.extraFields, defaults);
  });

  group('TestPopulateToolsWithDeferredTools', () {
    final model = _model(FakeOpenAI.json(const {}));
    final deferred = ToolInfo.fromJsonSchemaMap(
      name: 'deferred1',
      desc: 'd',
      schema: const {'type': 'object'},
    );
    final searchTool = ToolInfo.fromJsonSchemaMap(
      name: 'my_search',
      desc: 'search tools',
      schema: const {'type': 'object'},
    );

    List<Map<String, Object?>> tools(ChatModelOptions options) {
      final (common, specific) = model.resolveOptions(options);
      final request =
          model.buildRequest(const [], common, specific, stream: false);
      return (request.body['tools']! as List<Object?>)
          .cast<Map<String, Object?>>();
    }

    test('adds_hosted_tool_search_when_deferred_tools_set', () {
      final got = tools(ChatModelOptions(deferredTools: [deferred]));
      expect(got, [
        {
          'type': 'function',
          'name': 'deferred1',
          'description': 'd',
          'parameters': {'type': 'object'},
          'defer_loading': true,
        },
        {'type': 'tool_search'},
      ]);
    });

    test('adds_client_tool_search_when_tool_search_tool_set', () {
      final got = tools(ChatModelOptions(toolSearchTool: searchTool));
      expect(got, [
        {
          'type': 'tool_search',
          'description': 'search tools',
          'parameters': {'type': 'object'},
          'execution': 'client',
        },
      ]);
    });

    test('uses_client_tool_search_when_deferred_tools_and_tool_search_tool_are_set',
        () {
      final got = tools(
        ChatModelOptions(deferredTools: [deferred], toolSearchTool: searchTool),
      );
      expect(got.where((t) => t['name'] == 'deferred1'), hasLength(1));
      final searches = got.where((t) => t['type'] == 'tool_search').toList();
      expect(searches, hasLength(1));
      expect(searches.single['execution'], 'client');
    });
  });

  group('request', () {
    test('every setting of the config and the options', () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      final model = _model(
        fake,
        config: const OpenAIResponsesConfig(
          apiKey: 'test',
          baseUrl: 'https://proxy.example/v1/',
          model: 'gpt-5',
          maxTokens: 100,
          temperature: 0.2,
          topP: 0.9,
          serviceTier: OpenAIServiceTier.flex,
          include: [OpenAIResponsesIncludable.reasoningEncryptedContent],
          promptCacheRetention: OpenAIPromptCacheRetention.hours24,
          reasoning: OpenAIResponsesReasoning(
            effort: OpenAIReasoningEffort.high,
            summary: OpenAIReasoningSummary.auto,
          ),
          text: OpenAIResponsesTextConfig(
            format: OpenAIResponsesTextFormatJsonSchema(
              name: 'answer',
              schema: {'type': 'object'},
              strict: true,
            ),
            verbosity: OpenAIResponsesTextVerbosity.low,
          ),
          store: false,
          maxToolCalls: 4,
          parallelToolCalls: false,
          truncation: OpenAIResponsesTruncation.auto,
          customHeaders: {'X-Config': 'c'},
          extraFields: {'metadata': {'k': 'v'}},
        ),
      );
      await model.generate(
        _input,
        options: ChatModelOptions(
          model: 'gpt-5-mini',
          temperature: 0.5,
          tools: [
            ToolInfo.fromJsonSchemaMap(
              name: 'get_weather',
              desc: 'Weather',
              schema: const {
                'type': 'object',
                'properties': {
                  'city': {'type': 'string'},
                },
              },
            ),
          ],
          agenticToolChoice: AgenticToolChoice(
            type: ToolChoice.forced,
            forced: AgenticForcedToolChoice(
              tools: const [AllowedFunctionTool('get_weather')],
            ),
          ),
          extensions: const [
            OpenAIResponsesOptions(
              promptCacheKey: 'cache-key',
              customHeaders: {'X-Call': 'x'},
              serverTools: [
                OpenAIResponsesWebSearchTool(
                  searchContextSize: 'low',
                  userLocation:
                      OpenAIResponsesWebSearchUserLocation(country: 'FR'),
                ),
                OpenAIResponsesFileSearchTool(vectorStoreIds: ['vs_1']),
                OpenAIResponsesCodeInterpreterTool(fileIds: ['file_1']),
                OpenAIResponsesShellTool(environment: {'type': 'local'}),
              ],
              mcpTools: [
                OpenAIResponsesMcpTool(
                  serverLabel: 'deepwiki',
                  serverUrl: 'https://mcp.deepwiki.com/mcp',
                  allowedTools: ['ask_question'],
                  requireApproval: OpenAIResponsesMcpRequireApproval.never(),
                ),
              ],
            ),
          ],
        ),
      );

      final request = fake.requests.single;
      expect(request.url.toString(), 'https://proxy.example/v1/responses');
      // The call's headers replace the config's.
      expect(request.headers['X-Call'], 'x');
      expect(request.headers.containsKey('X-Config'), isFalse);
      expect(request.body, {
        'service_tier': 'flex',
        'include': ['reasoning.encrypted_content'],
        'prompt_cache_retention': '24h',
        'top_p': 0.9,
        'temperature': 0.5,
        'model': 'gpt-5-mini',
        'max_output_tokens': 100,
        'reasoning': {'effort': 'high', 'summary': 'auto'},
        'text': {
          'format': {
            'type': 'json_schema',
            'name': 'answer',
            'schema': {'type': 'object'},
            'strict': true,
          },
          'verbosity': 'low',
        },
        'max_tool_calls': 4,
        'parallel_tool_calls': false,
        'prompt_cache_key': 'cache-key',
        'store': false,
        'truncation': 'auto',
        'input': [
          {'role': 'user', 'content': 'hi'},
        ],
        'tools': [
          {
            'type': 'function',
            'name': 'get_weather',
            'description': 'Weather',
            'parameters': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
            },
          },
          {
            'type': 'web_search',
            'search_context_size': 'low',
            'user_location': {'type': 'approximate', 'country': 'FR'},
          },
          {
            'type': 'file_search',
            'vector_store_ids': ['vs_1'],
          },
          {
            'type': 'code_interpreter',
            'container': {
              'type': 'auto',
              'file_ids': ['file_1'],
            },
          },
          {
            'type': 'shell',
            'environment': {'type': 'local'},
          },
          {
            'type': 'mcp',
            'server_label': 'deepwiki',
            'server_url': 'https://mcp.deepwiki.com/mcp',
            'allowed_tools': ['ask_question'],
            'require_approval': 'never',
          },
        ],
        'tool_choice': {
          'type': 'allowed_tools',
          'mode': 'required',
          'tools': [
            {'type': 'function', 'name': 'get_weather'},
          ],
        },
        'metadata': {'k': 'v'},
      });
    });

    test('extra fields override the fields of the body', () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      await _model(fake).generate(
        _input,
        options: const OpenAIResponsesOptions(
          extraFields: {'model': 'overridden', 'reasoning_effort': 'high'},
        ).toOptions(),
      );
      expect(fake.body['model'], 'overridden');
      expect(fake.body['reasoning_effort'], 'high');
    });

    test('Azure sends the key as api-key', () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      await _model(
        fake,
        config: const OpenAIResponsesConfig(
          apiKey: 'azure-key',
          byAzure: true,
          baseUrl: 'https://res.openai.azure.com/openai/v1',
          model: 'deploy',
        ),
      ).generate(_input);
      final request = fake.requests.single;
      expect(
        request.url.toString(),
        'https://res.openai.azure.com/openai/v1/responses',
      );
      expect(request.headers['api-key'], 'azure-key');
      expect(request.headers.containsKey('Authorization'), isFalse);
    });

    test("'Stop' and the classic 'ToolChoice' are not supported", () async {
      final model = _model(FakeOpenAI.json(_textResponse('ok')));
      await expectLater(
        model.generate(_input, options: const ChatModelOptions(stop: ['x'])),
        _throwsWith("'Stop' option is not supported"),
      );
      await expectLater(
        model.stream(
          _input,
          options: const ChatModelOptions(toolChoice: ToolChoice.allowed),
        ),
        _throwsWith("'ToolChoice' option is not supported"),
      );
    });

    test('an input without messages sends no input', () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      await _model(fake).generate(const []);
      expect(fake.body.containsKey('input'), isFalse);
    });

    test('a conversation with every role and tool results', () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      final previous = await _model(FakeOpenAI.json(completeResponse()))
          .generate(_input);
      await _model(fake).generate([
        AgenticMessage.system('be brief'),
        AgenticMessage.user('weather?'),
        previous,
        AgenticMessage(
          role: AgenticRoleType.user,
          contentBlocks: [
            ContentBlock(
              FunctionToolResult(
                callId: 'call_1',
                name: 'get_weather',
                content: [
                  FunctionToolResultContentBlock(
                    const UserInputText(text: 'sunny'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ]);
      expect(fake.body['input'], [
        {'role': 'system', 'content': 'be brief'},
        {'role': 'user', 'content': 'weather?'},
        {
          'type': 'reasoning',
          'id': 'rs_1',
          'summary': [
            {'type': 'summary_text', 'text': 'Thinking about the weather.'},
          ],
          'encrypted_content': 'gAAAAenc',
        },
        {
          'type': 'message',
          'role': 'assistant',
          'id': 'msg_67ccd2bf17f0819081ff3bb2cf6508e60bb6a6b452d3795b',
          'status': 'completed',
          'content': [
            {
              'type': 'output_text',
              'text': 'It is sunny in Paris.',
              'annotations': [
                {
                  'type': 'url_citation',
                  'title': 'Weather',
                  'url': 'https://weather.example',
                  'start_index': 0,
                  'end_index': 5,
                },
              ],
            },
          ],
        },
        {
          'type': 'function_call',
          'id': 'fc_1',
          'status': 'completed',
          'call_id': 'call_1',
          'name': 'get_weather',
          'arguments': '{"city":"Paris"}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': [
            {'type': 'input_text', 'text': 'sunny'},
          ],
        },
      ]);
    });
  });

  group('prompt cache (populateCache)', () {
    const autoCache = OpenAIResponsesConfig(
      apiKey: 'k',
      model: 'm',
      enableAutoCache: true,
    );

    test('a generated response is marked and continued from', () async {
      final first = await _model(
        FakeOpenAI.json(_textResponse('one', id: 'resp_A')),
        config: autoCache,
      ).generate(_input);
      expect(isAutoCached(first), isTrue);

      final fake = FakeOpenAI.json(_textResponse('two'));
      await _model(fake, config: autoCache)
          .generate([..._input, first, AgenticMessage.user('more')]);
      expect(fake.body['previous_response_id'], 'resp_A');
      expect(fake.body['store'], isTrue);
      // Only the messages after the cached response are sent.
      expect(fake.body['input'], [
        {'role': 'user', 'content': 'more'},
      ]);
    });

    test('no input after the cached response is an error', () async {
      final first = await _model(
        FakeOpenAI.json(_textResponse('one', id: 'resp_A')),
        config: autoCache,
      ).generate(_input);
      final fake = FakeOpenAI.json(_textResponse('two'));
      await expectLater(
        _model(fake, config: autoCache).generate([..._input, first]),
        _throwsWith(
          'failed to populate cache: incremental input not found after '
          'response ID',
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('an invalidated message is not continued from', () async {
      final first = await _model(
        FakeOpenAI.json(_textResponse('one', id: 'resp_A')),
        config: autoCache,
      ).generate(_input);
      final fake = FakeOpenAI.json(_textResponse('two'));
      final messages = OpenAIResponsesModel.invalidateMessageCaches(
        [..._input, first, AgenticMessage.user('more')],
      );
      await _model(fake, config: autoCache).generate(messages);
      expect(fake.body.containsKey('previous_response_id'), isFalse);
      expect(fake.body['input'], hasLength(3));
    });

    test('the head previous response id applies when nothing is cached; '
        'an explicit store wins', () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      await _model(fake, config: autoCache).generate(
        _input,
        options: const OpenAIResponsesOptions(
          headPreviousResponseId: 'resp_head',
          store: false,
        ).toOptions(),
      );
      expect(fake.body['previous_response_id'], 'resp_head');
      expect(fake.body['store'], isFalse);
    });

    test('a cached response id wins over the head previous response id',
        () async {
      final first = await _model(
        FakeOpenAI.json(_textResponse('one', id: 'resp_A')),
        config: autoCache,
      ).generate(_input);
      final fake = FakeOpenAI.json(_textResponse('two'));
      await _model(fake, config: autoCache).generate(
        [first, AgenticMessage.user('more')],
        options: const OpenAIResponsesOptions(
          headPreviousResponseId: 'resp_head',
        ).toOptions(),
      );
      expect(fake.body['previous_response_id'], 'resp_A');
    });

    test('without auto cache only the head previous response id is used',
        () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      await _model(fake).generate(
        _input,
        options: const OpenAIResponsesOptions(headPreviousResponseId: 'resp_h')
            .toOptions(),
      );
      expect(fake.body['previous_response_id'], 'resp_h');
      expect(fake.body.containsKey('store'), isFalse);
    });
  });

  group('retries (openai-go)', () {
    test('a 500 is retried', () async {
      final fake = FakeOpenAI(
        (request, attempt) => attempt == 0
            ? jsonResponse(
                errorBody('busy'),
                status: 500,
                headers: {'retry-after-ms': '1'},
              )
            : jsonResponse(_textResponse('ok')),
      );
      final out = await _model(fake).generate(_input);
      expect(out.contentBlocks.single.assistantGenText!.text, 'ok');
      expect(fake.requests, hasLength(2));
    });

    test('429 is retried up to maxRetries', () async {
      final fake = FakeOpenAI(
        (request, attempt) => jsonResponse(
          errorBody('slow down'),
          status: 429,
          headers: {'retry-after': '0.001'},
        ),
      );
      await expectLater(
        _model(fake).generate(_input),
        throwsA(
          isA<OpenAIResponsesException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
      expect(fake.requests, hasLength(3));
    });

    test('a transport failure is retried after the default backoff', () {
      fakeAsync((async) {
        final fake = FakeOpenAI((request, attempt) {
          if (attempt == 0) throw http.ClientException('connection reset');
          return jsonResponse(_textResponse('ok'));
        });
        AgenticMessage? out;
        unawaited(_model(fake).generate(_input).then((m) => out = m));
        async.elapse(const Duration(milliseconds: 300));
        // The first backoff is 375 to 500 ms.
        expect(fake.requests, hasLength(1));
        async.elapse(const Duration(milliseconds: 300));
        expect(fake.requests, hasLength(2));
        expect(out!.contentBlocks.single.assistantGenText!.text, 'ok');
      });
    });

    test('cancelling during the backoff stops the retries', () {
      fakeAsync((async) {
        final fake = FakeOpenAI(
          (request, attempt) => throw http.ClientException('down'),
        );
        final token = CancelToken();
        Object? error;
        unawaited(
          _model(fake)
              .generate(_input, options: ChatModelOptions(cancelToken: token))
              .then<void>((_) {}, onError: (Object e) => error = e),
        );
        async.elapse(const Duration(milliseconds: 100));
        token.cancel('bye');
        async.elapse(const Duration(seconds: 2));
        expect(error, isA<CancelledException>());
        expect(fake.requests, hasLength(1));
      });
    });

    test('a transport failure after the last retry is retryable', () {
      fakeAsync((async) {
        final fake = FakeOpenAI(
          (request, attempt) => throw http.ClientException('down'),
        );
        Object? error;
        unawaited(
          _model(fake, config: const OpenAIResponsesConfig(maxRetries: 1))
              .generate(_input)
              .then<void>((_) {}, onError: (Object e) => error = e),
        );
        async.elapse(const Duration(seconds: 1));
        expect(fake.requests, hasLength(2));
        expect(
          error,
          isA<OpenAIResponsesException>()
              .having(
                (e) => e.message,
                'message',
                'failed to create response: request failed: '
                    'ClientException: down',
              )
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        );
      });
    });

    test('maxRetries 0 and x-should-retry false do not retry', () async {
      final fake = FakeOpenAI(
        (request, attempt) => jsonResponse(errorBody('busy'), status: 503),
      );
      await expectLater(
        _model(
          fake,
          config: const OpenAIResponsesConfig(model: 'm', maxRetries: 0),
        ).generate(_input),
        _throwsWith('API request failed with status 503'),
      );
      expect(fake.requests, hasLength(1));

      final refused = FakeOpenAI(
        (request, attempt) => jsonResponse(
          errorBody('busy'),
          status: 503,
          headers: {'x-should-retry': 'false'},
        ),
      );
      await expectLater(_model(refused).generate(_input), throwsA(anything));
      expect(refused.requests, hasLength(1));
    });

    test('a 4xx other than 408, 409 and 429 is not retried; 404 means the '
        'model is unavailable', () async {
      final fake = FakeOpenAI(
        (request, attempt) => jsonResponse(
          errorBody('The model `x` does not exist', code: 'model_not_found'),
          status: 404,
        ),
      );
      await expectLater(
        _model(fake).generate(_input),
        throwsA(
          isA<OpenAIResponsesException>()
              .having((e) => e.isModelUnavailable, 'unavailable', isTrue)
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
      expect(fake.requests, hasLength(1));
    });

    test('the stream request is retried too', () async {
      final fake = FakeOpenAI(
        (request, attempt) => attempt == 0
            ? jsonResponse(
                errorBody('busy'),
                status: 502,
                headers: {'retry-after-ms': '0'},
              )
            : http.StreamedResponse(
                Stream.value(
                  utf8.encode(
                    sse({'type': 'response.created', 'response': {'id': 'r'}}),
                  ),
                ),
                200,
              ),
      );
      final out = await _drain(await _model(fake).stream(_input));
      expect(out, hasLength(1));
      expect(fake.requests, hasLength(2));
    });

    test('retryDelay follows openai-go', () {
      expect(
        OpenAIResponsesModel.retryDelay({'retry-after-ms': '250'}, 0),
        const Duration(milliseconds: 250),
      );
      expect(
        OpenAIResponsesModel.retryDelay({'retry-after': '2'}, 0),
        const Duration(seconds: 2),
      );
      // A minute or more is not honoured.
      final long = OpenAIResponsesModel.retryDelay({'retry-after': '120'}, 0);
      expect(long, lessThanOrEqualTo(const Duration(milliseconds: 500)));
      for (var attempt = 0; attempt < 6; attempt++) {
        final delay = OpenAIResponsesModel.retryDelay(null, attempt);
        final base = [500, 1000, 2000, 4000, 8000, 8000][attempt];
        expect(delay.inMilliseconds, lessThanOrEqualTo(base));
        expect(delay.inMilliseconds, greaterThan(base * 3 ~/ 4 - 1));
      }
    });
  });

  group('cancellation and timeouts', () {
    test('a cancelled token fails the call before the request', () async {
      final fake = FakeOpenAI.json(_textResponse('ok'));
      final token = CancelToken()..cancel('stop');
      await expectLater(
        _model(fake).generate(_input, options: ChatModelOptions(cancelToken: token)),
        throwsA(isA<CancelledException>()),
      );
      expect(fake.requests, isEmpty);
    });

    test('cancelling while the headers are awaited', () async {
      final never = Completer<http.StreamedResponse>();
      final fake = FakeOpenAI((request, attempt) => never.future);
      final token = CancelToken();
      final call = _model(fake).generate(
        _input,
        options: ChatModelOptions(
          runContext: RunContext.background(cancelToken: token),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      token.cancel('user');
      await expectLater(
        call,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'user'),
        ),
      );
    });

    test('cancelling while the body is read releases the body', () async {
      final body = _Body();
      final token = CancelToken();
      final call = _model(FakeOpenAI((request, attempt) => body.response()))
          .generate(_input, options: ChatModelOptions(cancelToken: token));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      body.add('{"id": "r", "out');
      token.cancel();
      await expectLater(call, throwsA(isA<CancelledException>()));
      expect(body.released, isTrue);
      await body.controller.close();
    });

    test('cancelling a stream ends it and releases the body', () async {
      final body = _Body();
      final token = CancelToken();
      final reader = await _model(
        FakeOpenAI((request, attempt) => body.response()),
      ).stream(_input, options: ChatModelOptions(cancelToken: token));
      body.add(sse({'type': 'response.created', 'response': {'id': 'r'}}));
      expect((await reader.recv()).responseMeta, isNotNull);
      token.cancel('enough');
      final out = await _drain(reader);
      expect(out.single, isA<CancelledException>());
      expect(body.released, isTrue);
      await body.controller.close();
    });

    test('the timeout covers the headers and the body of a response',
        () async {
      final never = Completer<http.StreamedResponse>();
      const config = OpenAIResponsesConfig(
        model: 'm',
        maxRetries: 0,
        timeout: Duration(milliseconds: 20),
      );
      await expectLater(
        _model(FakeOpenAI((request, attempt) => never.future), config: config)
            .generate(_input),
        throwsA(
          isA<OpenAIResponsesException>()
              .having((e) => e.message, 'message', contains('timed out'))
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );

      final body = _Body();
      await expectLater(
        _model(FakeOpenAI((request, attempt) => body.response()), config: config)
            .generate(_input),
        _throwsWith('failed to create response: request timed out'),
      );
      expect(body.released, isTrue);
      await body.controller.close();
    });
  });

  group('callbacks', () {
    setUp(GlobalCallbacks.clear);
    tearDown(GlobalCallbacks.clear);

    ChatModelOptions withRecorder(_Recorder recorder) => ChatModelOptions(
          runContext: RunContext.background().withHandlers([recorder]),
          tools: [ToolInfo.fromParamsOneOf(name: 'noop')],
        );

    test('generate reports start and end with the config and the usage',
        () async {
      final recorder = _Recorder();
      await _model(FakeOpenAI.json(completeResponse()))
          .generate(_input, options: withRecorder(recorder));
      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'AgenticOpenAI/Responses');
      expect(recorder.infos.single.componentType, ComponentType.agenticModel);
      expect(recorder.input!.messages, _input);
      expect(recorder.input!.tools!.single.name, 'noop');
      expect(recorder.input!.config!.model, 'gpt-5');
      expect(recorder.output!.tokenUsage!.totalTokens, 123);
      expect(recorder.output!.message!.contentBlocks, hasLength(3));
    });

    test('an HTTP error is reported; a request error is not', () async {
      final failing = _Recorder();
      await expectLater(
        _model(FakeOpenAI.json(errorBody('no'), status: 400))
            .generate(_input, options: withRecorder(failing)),
        throwsA(isA<OpenAIResponsesException>()),
      );
      expect(failing.timings, ['start', 'error']);

      final invalid = _Recorder();
      await expectLater(
        _model(FakeOpenAI.json(const {})).generate(
          _input,
          options: withRecorder(invalid).copyWith(stop: ['x']),
        ),
        throwsA(isA<OpenAIResponsesException>()),
      );
      expect(invalid.timings, isEmpty);
    });

    test('stream reports every chunk', () async {
      final recorder = _Recorder();
      final reader = await _model(FakeOpenAI.sse(streamedResponse()))
          .stream(_input, options: withRecorder(recorder));
      final chunks = await _drain(reader);
      await recorder.streamDone.future;
      expect(recorder.timings, ['start', 'endStream']);
      expect(recorder.chunks, hasLength(chunks.length));
      expect(recorder.chunks.last!.tokenUsage!.totalTokens, 30);
    });
  });

  test('dispose closes the created client only', () async {
    final fake = FakeOpenAI.json(_textResponse('ok'));
    final model = _model(fake)..dispose();
    // An injected client stays usable by its owner, the model is not.
    await expectLater(model.generate(_input), throwsA(isA<StateError>()));
  });
}
