// ignore_for_file: avoid_print
@Tags(['integration'])
library;

// An opt-in live smoke test of the two agentic providers (beta) through
// OpenRouter (coordinator decision 3 after P13):
//
// * `OpenAIResponsesModel` against OpenRouter's Responses endpoint
//   (`POST https://openrouter.ai/api/v1/responses`): `baseUrl` is
//   `https://openrouter.ai/api/v1` (the model appends `/responses`) and the
//   OpenRouter key is the `apiKey`, sent as `Authorization: Bearer …`.
// * `ClaudeAgenticModel` against OpenRouter's Anthropic-compatible Messages
//   endpoint (`POST https://openrouter.ai/api/v1/messages`): `baseUrl` is
//   `https://openrouter.ai/api` (the model appends `/v1/messages`) and the
//   OpenRouter key is the `authToken`, sent as `Authorization: Bearer …`;
//   `apiKey` stays unset, so no `x-api-key` header goes out.
//
// Per provider: a plain `generate`, a `stream` joined with
// `concatAgenticMessages`, and a function-tool round trip through
// `AgenticChatModelAgent` + `AgenticRunner` (without and with streaming).
// Only with OPENROUTER_SERVER_TOOLS=1 (whether OpenRouter passes server
// tools through is not known, so they are opt-in on top of the opt-in),
// one `generate` per server-tool case, each able to return some of the wire
// names P13 could not verify:
//
// * Responses, web search (`web_search`): `web_search_call` items.
// * Responses, shell (`shell`, local environment) plus a deferred function
//   tool (sent with `defer_loading: true` and the hosted `tool_search`):
//   `shell_call` (`shell_call_output` only comes back when the server runs
//   the shell, not with a local environment), `tool_search_call`,
//   `tool_search_output`. A 400 for `defer_loading` or `tool_search` is a
//   finding too.
// * Every Responses call: the usage field
//   `input_tokens_details.cache_write_tokens`, when the API reports it.
// * Claude, web search (`web_search_20260209`): `server_tool_use` and
//   `web_search_tool_result` blocks and their fields.
// * Claude, web fetch (`web_fetch_20260309`, beta header
//   `web-fetch-2026-03-09`): `web_fetch_tool_result` blocks.
// * Claude, code execution (`code_execution_20260120`, in a call of its own,
//   not next to the web tools): `bash_code_execution_tool_result`,
//   `text_editor_code_execution_tool_result`, `code_execution_tool_result`.
//
// Every response body is also read for the item, content part, block, delta
// and stream-event types, the usage fields, and the field names of the
// server-tool items and blocks it carries. They are printed after each test
// (in a tear-down, so also after a failure), the names the provider's
// converter does not know marked, without failing the test: the wire names
// P13 could not check against the SDK sources (the newest Responses item
// types, the 2026 Claude server-tool fields; see "Needs a decision" of P13
// in the progress log) can then be checked by hand. Only the server-tool
// cases can bring those items and blocks back. A complete response the
// converter cannot read fails the call; in a stream the converters drop an
// item, content part or block of an unknown type without an error (as Go
// does; only an unknown Claude delta type fails), so the printed list is
// the only sign of it.
//
// The key is read from the environment only. It is never printed, logged or
// put into a failure message: the recording client keeps response bodies
// only (never the request), and the errors of both providers carry the
// status and the response body, not the request headers.
//
// Runs only when THREEPIO_INTEGRATION=1 and OPENROUTER_API_KEY are set:
//
//   THREEPIO_INTEGRATION=1 OPENROUTER_API_KEY=… \
//     dart test -j 1 --tags integration test/integration/openrouter_agentic_smoke_test.dart
//
// Models: OPENROUTER_RESPONSES_MODEL (default openai/gpt-4o-mini) and
// OPENROUTER_CLAUDE_MODEL (default anthropic/claude-haiku-4.5) for the plain
// calls, the agent and the Responses web search;
// OPENROUTER_RESPONSES_SERVER_TOOL_MODEL (default openai/gpt-5.1; a model
// with the shell and tool search tools) for the Responses shell case, and
// OPENROUTER_CLAUDE_SERVER_TOOL_MODEL (default anthropic/claude-sonnet-4.6;
// the 2026 web tools need a newer model than Haiku 4.5) for the Claude
// server-tool cases. The server-tool cases pass the model per call
// (`ChatModelOptions.model` wins over the config's), and the log names the
// model each call used. A reasoning
// model (openai/gpt-5-mini) also brings reasoning items back, but the agent
// round trip then sends the reasoning item back by its id, which a stateless
// endpoint may refuse; it may need
// `include: [OpenAIResponsesIncludable.reasoningEncryptedContent]` and
// `store: false` in the config (not set here).
//
// Not a port: eino-ext has no live test of its agentic providers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/threepio_core.dart'
    show
        ClaudeAgenticConfig,
        ClaudeAgenticModel,
        ClaudeAgenticOptions,
        ClaudeCodeExecutionTool20260120,
        ClaudeServerToolConfig,
        ClaudeWebFetchTool20260309,
        ClaudeWebSearchTool20260209,
        OpenAIResponsesConfig,
        OpenAIResponsesModel,
        OpenAIResponsesOptions,
        OpenAIResponsesShellTool,
        OpenAIResponsesWebSearchTool;

import '../support/integration.dart';

/// Where OpenRouter's APIs live.
const _openRouterApi = 'https://openrouter.ai/api';

/// The optional OpenRouter attribution header: names the app in OpenRouter's
/// activity log.
const _attribution = {'X-Title': 'threepio agentic smoke test'};

/// The prompt of the plain calls and the word the answer must contain.
const _pingPrompt = 'Reply with exactly the word "pong" and nothing else.';
const _pingWord = 'pong';

const _weatherQuestion = 'What is the weather in Paris right now?';
const _searchPrompt = 'Search the web: what is the latest stable version of '
    'the Dart SDK? Answer in one sentence.';
const _shellPrompt = 'First run the command `echo hello` with the shell '
    'tool. Then find a tool that tells the weather, and use it for Paris.';
const _fetchPrompt = 'Fetch https://dart.dev and tell me in one sentence what '
    'the page is about.';
const _codePrompt = 'Use code execution to compute the sum of the squares of '
    'the numbers 1 to 10 in Python, then give the number.';

/// The models of the server-tool cases (passed per call).
final _responsesServerToolModel =
    _env('OPENROUTER_RESPONSES_SERVER_TOOL_MODEL', 'openai/gpt-5.1');
final _claudeServerToolModel =
    _env('OPENROUTER_CLAUDE_SERVER_TOOL_MODEL', 'anthropic/claude-sonnet-4.6');

/// Whether the server-tool case runs (OPENROUTER_SERVER_TOOLS=1).
final _serverTools = Platform.environment['OPENROUTER_SERVER_TOOLS'] == '1';
const _weatherAnswer = 'Sunny, 18 degrees Celsius.';

String _env(String name, String fallback) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? fallback : value;
}

// ---------------------------------------------------------------------------
// Recording the wire
// ---------------------------------------------------------------------------

/// One response the API sent: its status and its body.
final class _Recorded {
  _Recorded(this.status, this.contentType);

  final int status;
  final String contentType;
  final List<int> bytes = [];

  String get body => utf8.decode(bytes, allowMalformed: true);

  /// The JSON objects of the body: every `data:` line of an event stream, or
  /// the body itself. What is not JSON is skipped.
  List<Map<String, Object?>> get jsonObjects {
    final text = body;
    final isStream = contentType.contains('text/event-stream') ||
        text.startsWith('event:') ||
        text.startsWith('data:') ||
        text.startsWith(':');
    final candidates = isStream
        ? [
            for (final line in const LineSplitter().convert(text))
              if (line.startsWith('data:')) line.substring(5).trim(),
          ]
        : [text];
    return [
      for (final candidate in candidates)
        if (_decodeObject(candidate) case final object?) object,
    ];
  }

  static Map<String, Object?>? _decodeObject(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}

/// An HTTP client that keeps a copy of every response body. It never looks
/// at the request, whose headers carry the key.
final class _RecordingClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final List<_Recorded> responses = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    final record = _Recorded(
      response.statusCode,
      response.headers['content-type'] ?? '',
    );
    responses.add(record);
    final body = response.stream.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (chunk, sink) {
          record.bytes.addAll(chunk);
          sink.add(chunk);
        },
      ),
    );
    return http.StreamedResponse(
      body,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

/// The type names found on the wire, by category ("item", "block", …).
typedef _WireTypes = Map<String, Set<String>>;

void _add(_WireTypes types, String category, Object? name) {
  if (name is String && name.isNotEmpty) {
    types.putIfAbsent(category, () => <String>{}).add(name);
  }
}

Map<String, Object?>? _object(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

List<Map<String, Object?>> _objects(Object? value) => [
      if (value is List)
        for (final element in value)
          if (_object(element) case final object?) object,
    ];

/// Adds the field names of a usage object and of its nested objects.
void _addUsage(_WireTypes types, Object? usage) {
  final object = _object(usage);
  if (object == null) return;
  for (final MapEntry(:key, :value) in object.entries) {
    _add(types, 'usage field', key);
    if (value is Map) _addUsage(types, value);
  }
}

// ---------------------------------------------------------------------------
// The providers
// ---------------------------------------------------------------------------

/// What differs between the two providers.
final class _Provider {
  const _Provider({
    required this.name,
    required this.modelId,
    required this.create,
    required this.scan,
    required this.known,
    required this.serverToolCases,
  });

  final String name;
  final String modelId;
  final AgenticModel Function(String apiKey, http.Client client) create;

  /// The opt-in server-tool calls.
  final List<_ServerToolCase> serverToolCases;

  /// Reads the type names of one JSON object of a response.
  final void Function(Map<String, Object?> json, _WireTypes types) scan;

  /// The type names the provider's converter handles, by category. A
  /// category that is not listed is printed but not checked.
  final _WireTypes known;
}

/// One opt-in server-tool call: [prompt] with the [options] [buildOptions]
/// returns, on [modelId] (the provider's model when `null`).
final class _ServerToolCase {
  const _ServerToolCase({
    required this.label,
    required this.prompt,
    required this.buildOptions,
    this.modelId,
  });

  final String label;
  final String prompt;
  final Future<ChatModelOptions> Function() buildOptions;
  final String? modelId;
}

/// The function tool of the agent runs (and the deferred tool of the
/// Responses shell case): the weather of a city, recorded in [cities].
FunctionTool<Map<String, Object?>, String> _weatherTool(List<String> cities) =>
    FunctionTool<Map<String, Object?>, String>(
      name: 'get_weather',
      description: 'The current weather in a city.',
      params: const ParamsOneOf.params({
        'city': ParameterInfo(
          type: DataType.string,
          desc: 'The name of the city, e.g. "Paris".',
          required: true,
        ),
      }),
      fromJson: (json) => json,
      invoke: (ctx, input, options) {
        cities.add('${input['city']}');
        return _weatherAnswer;
      },
    );

// The Responses API: an object with `output` items (complete response) or
// server-sent events whose `type` is the event name.
void _scanResponses(Map<String, Object?> json, _WireTypes types) {
  void outputItem(Map<String, Object?> item) {
    final type = item['type'];
    _add(types, 'item', type);
    if (type == 'message') {
      for (final content in _objects(item['content'])) {
        _add(types, 'message content', content['type']);
      }
    } else if (type is String &&
        !const {'reasoning', 'function_call'}.contains(type)) {
      // A server-side or MCP tool item: its field names, to compare with
      // what the converter reads.
      for (final key in item.keys) {
        _add(types, 'server-tool item field', '$type.$key');
      }
    }
  }

  void response(Map<String, Object?>? object) {
    if (object == null) return;
    for (final item in _objects(object['output'])) {
      outputItem(item);
    }
    _addUsage(types, object['usage']);
  }

  final type = json['type'];
  if (json['object'] == 'response' || json.containsKey('output')) {
    response(json);
    return;
  }
  _add(types, 'stream event', type);
  switch (type) {
    case 'response.output_item.added' || 'response.output_item.done':
      final item = _object(json['item']);
      if (item != null) outputItem(item);
    case 'response.content_part.added' || 'response.content_part.done':
      _add(types, 'content part', _object(json['part'])?['type']);
    case 'response.created' ||
          'response.in_progress' ||
          'response.completed' ||
          'response.incomplete' ||
          'response.failed':
      response(_object(json['response']));
  }
}

void _scanClaude(Map<String, Object?> json, _WireTypes types) {
  void block(Map<String, Object?>? object) {
    if (object == null) return;
    final type = object['type'];
    _add(types, 'block', type);
    if (type is String &&
        !const {'text', 'thinking', 'redacted_thinking', 'tool_use'}
            .contains(type)) {
      // A server tool call or result: its field names, to compare with what
      // the converter reads.
      for (final key in object.keys) {
        _add(types, 'server-tool block field', '$type.$key');
      }
    }
  }

  void message(Map<String, Object?>? object) {
    if (object == null) return;
    for (final content in _objects(object['content'])) {
      block(content);
    }
    _addUsage(types, object['usage']);
  }

  final type = json['type'];
  if (type == 'message') {
    message(json);
    return;
  }
  _add(types, 'stream event', type);
  switch (type) {
    case 'message_start':
      message(_object(json['message']));
    case 'message_delta':
      _addUsage(types, json['usage']);
    case 'content_block_start':
      block(_object(json['content_block']));
    case 'content_block_delta':
      _add(types, 'delta', _object(json['delta'])?['type']);
  }
}

// The names below are those the converters switch on:
// lib/src/components/model/providers/openai_responses/
//   openai_responses_convertor.dart (toOutputMessage,
//   outputMessageToContentBlocks, toTokenUsage) and
//   openai_responses_event_convertor.dart (ResponsesStreamConverter.onEvent);
// lib/src/components/model/providers/claude_agentic/
//   claude_agentic_convertor.dart (contentBlock, the usage of a message) and
//   claude_agentic_event_convertor.dart (convert, startBlock, deltaBlock).
const _responsesKnown = <String, Set<String>>{
  'item': {
    'reasoning',
    'message',
    'function_call',
    'mcp_list_tools',
    'mcp_call',
    'mcp_approval_request',
    'web_search_call',
    'file_search_call',
    'code_interpreter_call',
    'image_generation_call',
    'shell_call',
    'shell_call_output',
    'tool_search_call',
    'tool_search_output',
  },
  'message content': {'output_text', 'refusal'},
  'content part': {'output_text', 'refusal', 'reasoning_text'},
  'stream event': {
    'error',
    'response.created',
    'response.in_progress',
    'response.completed',
    'response.incomplete',
    'response.failed',
    'response.output_item.added',
    'response.output_item.done',
    'response.content_part.added',
    'response.content_part.done',
    'response.refusal.delta',
    'response.output_text.delta',
    'response.output_text.annotation.added',
    'response.reasoning_text.delta',
    'response.reasoning_summary_text.delta',
    'response.function_call_arguments.delta',
    'response.mcp_list_tools.in_progress',
    'response.mcp_list_tools.failed',
    'response.mcp_list_tools.completed',
    'response.mcp_call_arguments.delta',
    'response.mcp_call.in_progress',
    'response.mcp_call.completed',
    'response.mcp_call.failed',
    'response.web_search_call.in_progress',
    'response.web_search_call.searching',
    'response.web_search_call.completed',
    'response.file_search_call.in_progress',
    'response.file_search_call.searching',
    'response.file_search_call.completed',
    'response.code_interpreter_call.in_progress',
    'response.code_interpreter_call.interpreting',
    'response.code_interpreter_call_code.delta',
    'response.code_interpreter_call.completed',
    'response.image_generation_call.in_progress',
    'response.image_generation_call.generating',
    'response.image_generation_call.partial_image',
    'response.image_generation_call.completed',
  },
  'usage field': {
    'input_tokens',
    'input_tokens_details',
    'cached_tokens',
    'cache_write_tokens',
    'output_tokens',
    'output_tokens_details',
    'reasoning_tokens',
    'total_tokens',
  },
};

const _claudeKnown = <String, Set<String>>{
  'block': {
    'text',
    'thinking',
    'redacted_thinking',
    'tool_use',
    'server_tool_use',
    'web_search_tool_result',
    'web_fetch_tool_result',
    'code_execution_tool_result',
    'bash_code_execution_tool_result',
    'text_editor_code_execution_tool_result',
    'tool_search_tool_result',
  },
  'delta': {
    'text_delta',
    'citations_delta',
    'thinking_delta',
    'signature_delta',
    'input_json_delta',
  },
  // `content_block_stop`, `message_stop` and `ping` carry nothing the
  // converter needs; it skips them (as Go does). `error` ends the stream.
  'stream event': {
    'message_start',
    'message_delta',
    'message_stop',
    'content_block_start',
    'content_block_delta',
    'content_block_stop',
    'ping',
    'error',
  },
  'usage field': {
    'input_tokens',
    'cache_read_input_tokens',
    'cache_creation_input_tokens',
    'output_tokens',
  },
};

final _providers = [
  _Provider(
    name: 'OpenAIResponsesModel via OpenRouter /api/v1/responses',
    modelId: _env('OPENROUTER_RESPONSES_MODEL', 'openai/gpt-4o-mini'),
    create: (apiKey, client) => OpenAIResponsesModel(
      config: OpenAIResponsesConfig(
        baseUrl: '$_openRouterApi/v1',
        apiKey: apiKey,
        model: _env('OPENROUTER_RESPONSES_MODEL', 'openai/gpt-4o-mini'),
        customHeaders: _attribution,
      ),
      httpClient: client,
    ),
    scan: _scanResponses,
    known: _responsesKnown,
    serverToolCases: [
      _ServerToolCase(
        label: 'web search',
        prompt: _searchPrompt,
        buildOptions: () async => const OpenAIResponsesOptions(
          serverTools: [OpenAIResponsesWebSearchTool()],
        ).toOptions(),
      ),
      _ServerToolCase(
        label: 'shell and deferred tool search',
        prompt: _shellPrompt,
        modelId: _responsesServerToolModel,
        buildOptions: () async => const OpenAIResponsesOptions(
          serverTools: [
            OpenAIResponsesShellTool(environment: {'type': 'local'}),
          ],
        ).toOptions().merge(
              ChatModelOptions(
                // Per call; wins over the config's model.
                model: _responsesServerToolModel,
                deferredTools: [await _weatherTool([]).info()],
              ),
            ),
      ),
    ],
  ),
  _Provider(
    name: 'ClaudeAgenticModel via OpenRouter /api/v1/messages',
    modelId: _env('OPENROUTER_CLAUDE_MODEL', 'anthropic/claude-haiku-4.5'),
    create: (apiKey, client) => ClaudeAgenticModel(
      config: ClaudeAgenticConfig(
        baseUrl: _openRouterApi,
        authToken: apiKey,
        model: _env('OPENROUTER_CLAUDE_MODEL', 'anthropic/claude-haiku-4.5'),
        maxTokens: 1024,
        customHeaders: _attribution,
      ),
      httpClient: client,
    ),
    scan: _scanClaude,
    known: _claudeKnown,
    // The 2026 web tools and code execution need a newer model than the
    // default Haiku: each case passes the server-tool model per call
    // (`ChatModelOptions.model` wins over `ClaudeAgenticConfig.model`).
    serverToolCases: [
      _ServerToolCase(
        label: 'web search',
        prompt: _searchPrompt,
        modelId: _claudeServerToolModel,
        buildOptions: () async => const ClaudeAgenticOptions(
          serverTools: [
            ClaudeServerToolConfig(
              webSearch20260209: ClaudeWebSearchTool20260209(maxUses: 1),
            ),
          ],
        ).toOptions().merge(ChatModelOptions(model: _claudeServerToolModel)),
      ),
      _ServerToolCase(
        label: 'web fetch',
        prompt: _fetchPrompt,
        modelId: _claudeServerToolModel,
        buildOptions: () async => const ClaudeAgenticOptions(
          serverTools: [
            ClaudeServerToolConfig(
              webFetch20260309: ClaudeWebFetchTool20260309(maxUses: 1),
            ),
          ],
        ).toOptions().merge(ChatModelOptions(model: _claudeServerToolModel)),
      ),
      _ServerToolCase(
        label: 'code execution',
        prompt: _codePrompt,
        modelId: _claudeServerToolModel,
        buildOptions: () async => const ClaudeAgenticOptions(
          serverTools: [
            ClaudeServerToolConfig(
              codeExecution20260120: ClaudeCodeExecutionTool20260120(),
            ),
          ],
        ).toOptions().merge(ChatModelOptions(model: _claudeServerToolModel)),
      ),
    ],
  ),
];

/// Prints the wire types of every response [client] received for [label],
/// marking those the converter does not know. Never fails.
void _logWireTypes(
  _Provider provider,
  _RecordingClient client,
  String label, {
  String? modelId,
}) {
  final types = <String, Set<String>>{};
  for (final response in client.responses) {
    for (final json in response.jsonObjects) {
      provider.scan(json, types);
    }
  }
  final statuses = client.responses.map((r) => r.status).join(', ');
  print('[agentic smoke] ${provider.name} (${modelId ?? provider.modelId}), '
      '$label: '
      '${client.responses.length} response(s), status $statuses');
  for (final MapEntry(key: category, value: names) in types.entries) {
    final known = provider.known[category];
    final unknown = known == null
        ? const <String>[]
        : [for (final name in names) if (!known.contains(name)) name];
    print('  $category: ${(names.toList()..sort()).join(', ')}');
    if (unknown.isNotEmpty) {
      final what = category == 'stream event'
          ? 'ignored by the converter'
          : category == 'usage field'
              ? 'not read by the converter'
              : 'UNKNOWN to the converter';
      print('  $category $what: ${(unknown..sort()).join(', ')}');
    }
  }
}

/// The text of the assistant text blocks of [message].
String _text(AgenticMessage message) => [
      for (final block in message.contentBlocks)
        if (block.assistantGenText case final text?) text.text,
    ].join();

/// The block types of [message], for the log.
String _blockTypes(AgenticMessage message) =>
    message.contentBlocks.map((block) => block.type.value).join(', ');

void main() {
  final apiKey = integrationApiKey(
    'OPENROUTER_API_KEY',
    suite: 'OpenRouter agentic providers (live)',
  );
  if (apiKey == null) return;

  final ctx = RunContext.background();
  const timeout = Timeout(Duration(seconds: 120));

  for (final provider in _providers) {
    group(provider.name, () {
      late _RecordingClient client;
      late AgenticModel model;

      // The types are printed in a tear-down, so also after a failure.
      void watch(String label, {String? modelId}) => addTearDown(
            () => _logWireTypes(provider, client, label, modelId: modelId),
          );

      setUp(() {
        client = _RecordingClient();
        model = provider.create(apiKey, client);
      });

      tearDown(() {
        // The injected client is not closed by dispose; it is closed here.
        final created = model;
        if (created is OpenAIResponsesModel) created.dispose();
        if (created is ClaudeAgenticModel) created.dispose();
        client.close();
      });

      test('generate answers', () async {
        watch('generate');
        final message = await model.generate([AgenticMessage.user(_pingPrompt)]);

        print('  blocks: ${_blockTypes(message)}');
        expect(message.role, AgenticRoleType.assistant);
        expect(_text(message).toLowerCase(), contains(_pingWord));
        expect(client.responses.last.status, 200);
      }, timeout: timeout);

      test('stream answers in chunks that concatenate', () async {
        watch('stream');
        final reader = await model.stream([AgenticMessage.user(_pingPrompt)]);
        final chunks = await reader.collectAll();
        expect(chunks, isNotEmpty);
        final message = concatAgenticMessages(chunks);

        print('  ${chunks.length} chunk(s); blocks: ${_blockTypes(message)}');
        expect(message.role, AgenticRoleType.assistant);
        expect(_text(message).toLowerCase(), contains(_pingWord));
      }, timeout: timeout);

      for (final serverTool in provider.serverToolCases) {
        test('server tool: ${serverTool.label}', () async {
          final modelId = serverTool.modelId ?? provider.modelId;
          watch('server tool: ${serverTool.label}', modelId: modelId);
          print('  model: $modelId');
          final message = await model.generate(
            [AgenticMessage.user(serverTool.prompt)],
            options: await serverTool.buildOptions(),
          );

          print('  blocks: ${_blockTypes(message)}');
          for (final block in message.contentBlocks) {
            if (block.serverToolCall case final call?) {
              print('  server tool call: ${call.name}');
            }
          }
          // With server tools a response may end without text (Claude's
          // `pause_turn`, or a Responses `shell_call` the client is to run).
          expect(message.role, AgenticRoleType.assistant);
          expect(message.contentBlocks, isNotEmpty);
          expect(client.responses.last.status, 200);
        },
            timeout: timeout,
            skip: _serverTools
                ? null
                : 'set OPENROUTER_SERVER_TOOLS=1 to offer server tools');
      }

      for (final streaming in [false, true]) {
        final mode = streaming ? 'streaming' : 'generate';

        test('a function tool round trip through AgenticChatModelAgent '
            '($mode)', () async {
          watch('agent ($mode)');
          final cities = <String>[];
          final weather = _weatherTool(cities);
          final agent = AgenticChatModelAgent(
            AgenticChatModelAgentConfig(
              name: 'weather_agent',
              description: 'Answers questions about the weather.',
              instruction: 'Always call get_weather before you answer a '
                  'question about the weather, then answer in one sentence.',
              model: model,
              toolsConfig: ToolsConfig(
                toolsNode: ToolsNodeConfig(tools: [weather]),
              ),
            ),
          );

          final events = AgenticRunner(agent: agent, enableStreaming: streaming)
              .query(ctx, _weatherQuestion);
          addTearDown(events.close);
          final messages = <AgenticMessage>[];
          for (var event = await events.nextOrNull();
              event != null;
              event = await events.nextOrNull()) {
            expect(event.error, isNull);
            final message = await getAgenticMessageFromEvent(event);
            if (message == null) continue;
            print('  ${message.role.value}: ${_blockTypes(message)}');
            messages.add(message);
          }

          // The tool ran, for Paris.
          expect(cities, isNotEmpty, reason: 'the model called get_weather');
          expect(cities.first.toLowerCase(), contains('paris'));

          // The model's call, the tool's result for that call, the answer.
          final calls = [
            for (final message in messages)
              if (message.role == AgenticRoleType.assistant)
                for (final block in message.contentBlocks)
                  if (block.functionToolCall case final call?) call,
          ];
          final results = [
            for (final message in messages)
              if (message.role == AgenticRoleType.user)
                for (final block in message.contentBlocks)
                  if (block.functionToolResult case final result?) result,
          ];
          expect(calls.map((call) => call.name), contains('get_weather'));
          expect(calls.first.callId, isNotEmpty);
          expect(results.map((result) => result.callId), contains(calls.first.callId));
          expect(messages.last.role, AgenticRoleType.assistant);
          expect(_text(messages.last), isNotEmpty);
        }, timeout: timeout);
      }
    });
  }
}
