// Tests of the fixes made by the independent review of the agentic Claude
// provider (P13, group K). Each fails without its fix:
//   * the API key in a header value HTTP cannot carry (a key read from a file
//     with its line break) never appears in the error: dart:io quotes the
//     value, Go's net/http names the header only;
//   * the errors of building a request say "generate request failed", as Go
//     wraps genParamsAndOptions (the classic toolChoice/allowedToolNames
//     checks of getOptions are not wrapped);
//   * `stream: true` is set before the extra fields, which can override it
//     (anthropic-sdk-go puts its `WithJSONSet("stream", true)` first);
//   * every `anthropic-beta` key of the custom headers is kept, whatever its
//     case;
//   * a `tool_use` without `input` has empty arguments (Go: `string(nil)`);
//   * a JSON number is `float64` in type errors, as Go decodes it;
//   * a streamed tool search result whose call is not in the stream is
//     dropped, as Go drops every streamed tool search result, instead of
//     failing the stream.
// The real-client test talks to a loopback HttpServer only.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_config.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_convertor.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_event_convertor.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_model.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_options.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_request.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_utils.dart';
import 'package:threepio_core/threepio_core.dart';

import 'claude_agentic_fixtures.dart';

const _secret = 'sk-ant-review-secret-0123456789';

/// Records the start and error callbacks of a call.
final class _Callbacks extends ComponentCallbackHandler {
  final List<String> timings = [];

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    timings.add('start');
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
    return ctx;
  }
}

Matcher _withoutSecret() => isA<ClaudeException>()
    .having((e) => e.message, 'message', isNot(contains(_secret)))
    .having((e) => e.toString(), 'toString', isNot(contains(_secret)))
    .having((e) => '${e.cause}', 'cause', isNot(contains(_secret)));

void main() {
  group('a header value HTTP cannot carry', () {
    test('real client: the key is not in the error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 500;
        await request.response.close();
      });
      final model = ClaudeAgenticModel(
        config: ClaudeAgenticConfig(
          apiKey: '$_secret\n',
          model: testModel,
          maxTokens: 16,
          baseUrl: 'http://${server.address.address}:${server.port}',
        ),
      );
      addTearDown(model.dispose);
      await expectLater(
        model.generate([AgenticMessage.user('x')]),
        throwsA(
          allOf(
            _withoutSecret(),
            isA<ClaudeException>()
                .having(
                  (e) => e.message,
                  'message',
                  'create message failed: invalid header field value for '
                      '"x-api-key"',
                )
                .having((e) => e.isRetryable, 'isRetryable', isFalse),
          ),
        ),
      );
    });

    test('a bearer token and a custom header are named, not quoted', () async {
      final recorder = Recorder();
      final callbacks = _Callbacks();
      final model = ClaudeAgenticModel(
        config: const ClaudeAgenticConfig(
          authToken: '$_secret\r\n',
          model: testModel,
          maxTokens: 16,
        ),
        httpClient: recorder.json(messageResponse(const [])),
      );
      await expectLater(
        model.stream(
          [AgenticMessage.user('x')],
          options: ChatModelOptions(
            runContext: RunContext.background().withHandlers([callbacks]),
          ),
        ),
        throwsA(
          allOf(
            _withoutSecret(),
            isA<ClaudeException>().having(
              (e) => e.message,
              'message',
              'create message stream failed: invalid header field value '
                  'for "authorization"',
            ),
          ),
        ),
      );
      // Raised by the request, after the start callback, as in Go.
      expect(callbacks.timings, ['start', 'error']);

      final custom = ClaudeAgenticModel(
        config: testConfig,
        httpClient: recorder.json(messageResponse(const [])),
      );
      await expectLater(
        custom.generate(
          [AgenticMessage.user('x')],
          options: const ClaudeAgenticOptions(
            customHeaders: {'x-secret': '$_secret\u0000'},
          ).toOptions(),
        ),
        throwsA(
          allOf(
            _withoutSecret(),
            isA<ClaudeException>().having(
              (e) => e.message,
              'message',
              contains('"x-secret"'),
            ),
          ),
        ),
      );
      expect(recorder.requests, isEmpty);
    });

    test('tabs and visible ASCII are sent', () async {
      final recorder = Recorder();
      await ClaudeAgenticModel(
        config: testConfig,
        httpClient: recorder.json(messageResponse(const [])),
      ).generate(
        [AgenticMessage.user('x')],
        options: const ClaudeAgenticOptions(
          customHeaders: {'x-ok': 'a\tb ~!'},
        ).toOptions(),
      );
      expect(recorder.headers['x-ok'], 'a\tb ~!');
    });
  });

  group('"generate request failed", as Go wraps genParamsAndOptions', () {
    final model = ClaudeAgenticModel(
      config: testConfig,
      httpClient: Recorder().json(messageResponse(const [])),
    );

    test('a tool choice that does not fit the tools', () async {
      for (final call in [model.generate, model.stream]) {
        await expectLater(
          call(
            [AgenticMessage.user('x')],
            options: const ChatModelOptions(
              agenticToolChoice: AgenticToolChoice(type: ToolChoice.forced),
            ),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'generate request failed: tool choice is forced but no tools '
                  'are provided',
            ),
          ),
        );
      }
    });

    test('input that cannot be sent', () async {
      await expectLater(
        model.stream([AgenticMessage.system('only')]),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'generate request failed: convert input messages failed: input '
                'contains only system messages',
          ),
        ),
      );
    });

    test('the getOptions checks are not wrapped', () async {
      await expectLater(
        model.generate([
          AgenticMessage.user('x'),
        ], options: const ChatModelOptions(toolChoice: ToolChoice.forced)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "'ToolChoice' option is not supported, please use "
                "'AgenticToolChoice'",
          ),
        ),
      );
    });
  });

  test('extra fields can override stream, as in anthropic-sdk-go', () {
    ChatModelOptions options(Map<String, Object?>? extra) =>
        claudeAgenticCallOptions(
          testConfig,
          ClaudeAgenticOptions(extraFields: extra).toOptions(),
        );
    final input = [AgenticMessage.user('x')];
    expect(
      buildClaudeAgenticRequest(
        testConfig,
        input,
        options(null),
        stream: true,
      ).body['stream'],
      isTrue,
    );
    expect(
      buildClaudeAgenticRequest(
        testConfig,
        input,
        options({'stream': false}),
        stream: true,
      ).body['stream'],
      isFalse,
    );
    expect(
      buildClaudeAgenticRequest(
        testConfig,
        input,
        options(null),
        stream: false,
      ).body.containsKey('stream'),
      isFalse,
    );
  });

  test('every anthropic-beta key of the custom headers is kept', () {
    final headers = claudeAgenticHeaders(
      testConfig,
      const ResolvedClaudeAgenticOptions(
        timeout: Duration(seconds: 1),
        customHeaders: {
          'anthropic-beta': 'a, b',
          'Anthropic-Beta': 'b,c',
          'x-other': '1',
        },
        serverTools: [
          ClaudeServerToolConfig(
            webFetch20260309: ClaudeWebFetchTool20260309(),
          ),
        ],
      ),
      stream: false,
    );
    expect(headers['anthropic-beta'], 'a, b, c, web-fetch-2026-03-09');
    expect(headers['x-other'], '1');
  });

  test('a tool_use without input has empty arguments, as in Go', () {
    final converter = ClaudeAgenticBlockConverter();
    expect(
      converter
          .contentBlock({'type': 'tool_use', 'id': 't1', 'name': 'f'})!
          .functionToolCall!
          .arguments,
      '',
    );
    expect(
      converter
          .contentBlock({
            'type': 'tool_use',
            'id': 't2',
            'name': 'f',
            'input': null,
          })!
          .functionToolCall!
          .arguments,
      'null',
    );
    expect(
      converter
          .contentBlock({
            'type': 'tool_use',
            'id': 't3',
            'name': 'f',
            'input': {'a': 1},
          })!
          .functionToolCall!
          .arguments,
      '{"a":1}',
    );
  });

  test('a JSON number is float64 in type errors, as Go decodes it', () {
    expect(claudeGoTypeName(5), 'float64');
    expect(claudeGoTypeName(5.5), 'float64');
    expect(
      () => ClaudeAgenticBlockConverter().serverToolUse({
        'id': 'c',
        'name': 'web_fetch',
        'input': 7,
      }),
      throwsA(
        isA<ThreepioFormatException>().having(
          (e) => e.message,
          'message',
          'unexpected type float64 for web fetch input',
        ),
      ),
    );
  });

  group('a tool search result whose call is not known', () {
    const result = {
      'type': 'tool_search_tool_result',
      'tool_use_id': 'srvtoolu_earlier',
      'content': {
        'type': 'tool_search_tool_search_result',
        'tool_references': [
          {'type': 'tool_reference', 'tool_name': 'get_weather'},
        ],
      },
    };

    test('is dropped from a stream, as Go drops them all', () {
      final converter = ClaudeAgenticStreamConverter();
      expect(
        converter.convert({
          'type': 'content_block_start',
          'index': 0,
          'content_block': result,
        }),
        isNull,
      );
      expect(converter.blockKinds, isEmpty);
    });

    test('fails generate, as Go fails on every tool search result', () {
      expect(
        () => ClaudeAgenticBlockConverter().message(
          messageResponse(const [result]),
        ),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'tool search result for unknown call "srvtoolu_earlier"',
          ),
        ),
      );
    });

    test('a stream with the call still converts it', () async {
      final model = ClaudeAgenticModel(
        config: testConfig,
        httpClient: Recorder().sse([
          sseEvent('content_block_start', {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'server_tool_use',
              'id': 'srvtoolu_earlier',
              'name': 'tool_search_tool_regex',
              'input': <String, Object?>{},
            },
          }),
          sseEvent('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': jsonEncode({'query': 'weather'}),
            },
          }),
          sseEvent('content_block_start', {
            'type': 'content_block_start',
            'index': 1,
            'content_block': result,
          }),
        ]),
      );
      final joined = concatAgenticMessages(
        await (await model.stream([AgenticMessage.user('x')])).collectAll(),
      );
      expect(joined.contentBlocks, hasLength(2));
      expect(
        joined.contentBlocks[1].serverToolResult?.name,
        'tool_search_tool_regex',
      );
    });
  });
}
