// Ports eino-ext components/tool/mcp:
//   mcp_test.go          TestTool (with the subtest "call tools without
//                        arguments"); the check of the private
//                        toolHelper.customHeaders field becomes a check that
//                        the headers reach the server.
//   option_test.go       TestWithCustomHeaders.
// and components/tool/mcp/officialmcp/mcp_test.go:
//   TestTool, TestToolNameMapperMetadataAndRawInvocation,
//   TestToolNameMapperRejectsDuplicateAndReservedExtra,
//   TestMetadataFullAndAnnotations, TestToolCallResultHandlers,
//   TestResultAndDescriptionPolicies,
//   TestResultPolicyCanReturnServerErrorAsResult, TestListToolsPagination,
//   TestListToolsPaginationMaxPages, TestValidateConfigAndErrorHelpers (the
//   negative MaxToolPages and the Error helpers),
//   TestResultPolicyIncludesStructuredContentAndMeta and
//   TestAttack_ResultPolicyRejectsImpossibleMaxChars (through a tool instead
//   of the private marshalToolResult), TestAttack_ResultHandlerNilResultDoesNotPanic,
//   TestInvokableRunClassifiesConnectionError,
//   TestInvokableRunClassifiesProtocolErrorAsCallTool, TestIsConnectionError.
// Not ported: TestGetToolsRejectsNilClient and the nil-config / unknown
// MetadataMode / unknown ListToolsMode cases of TestValidateConfigAndErrorHelpers
// (a non-nullable client and enums make them impossible in Dart), and the
// nil-receiver cases of (*Error).Error / Unwrap (no nil receivers in Dart).
//
// Written for the port: the multimodal form (EnhancedInvokableTool), the
// _meta and header options, interrupts and cancellation passing through,
// invalid arguments, a repeated cursor, listing errors, schema conversion.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/enhanced_tool.dart';
import 'package:threepio_core/src/components/tool/invokable_tool.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_toolkit.dart';
import 'package:threepio_core/src/components/tool/tool_options.dart';
import 'package:threepio_core/src/core/interrupt_signal.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';
import 'package:threepio_core/src/schema/tool_info.dart';
import 'package:threepio_core/src/schema/tool_result.dart';

import '../../../support/fake_mcp_server.dart';

final _ctx = RunContext.background();

String _sayHi(Map<String, Object?> a) => 'Hi ${a['name']}';
String _sayHello(Map<String, Object?> a) => 'Hello ${a['name']}';

/// Port of newTestClientSession: a client connected in memory to a server
/// with the tools greet and hello, plus [extra].
Future<(McpClient, FakeMcpServer)> _session({
  List<FakeTool> extra = const [],
  int? pageSize,
}) async {
  final server = FakeMcpServer(
    tools: [
      FakeTool.text('greet', _sayHi, description: 'say hi'),
      FakeTool.text('hello', _sayHello, description: 'say hello'),
      ...extra,
    ],
    pageSize: pageSize,
  );
  final client = await McpClient.connect(
    FakeInMemoryTransport(server),
    clientInfo: const McpImplementation(name: 'test', version: 'v1.0.0'),
  );
  addTearDown(client.close);
  return (client, server);
}

Map<String, Object?> _jsonRoundTrip(ToolInfo info) =>
    jsonDecode(jsonEncode(info.toJson())) as Map<String, Object?>;

final class _Interrupt implements InterruptSignal {
  const _Interrupt();
}

/// Port of stubSession: canned listing, canned call error or result.
final class _StubSession implements McpClientSession {
  _StubSession({this.callError, this.callResult, this.listError});

  final Object? callError;
  final McpCallToolResult? callResult;
  final Object? listError;

  @override
  Future<McpListToolsResult> listTools({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final error = listError;
    if (error != null) throw error;
    return const McpListToolsResult(tools: [McpTool(name: 'greet')]);
  }

  @override
  Future<McpCallToolResult> callTool(
    String name, {
    Object? arguments,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final error = callError;
    if (error != null) throw error;
    return callResult ?? const McpCallToolResult();
  }
}

Future<McpInvokableTool> _stubTool(_StubSession session) async =>
    (await McpToolkit(session).getTools(_ctx)).single;

void main() {
  group('TestTool (tool/mcp)', () {
    test('filters by name, passes custom headers, and calls without '
        'arguments', () async {
      final server = FakeMcpServer(
        tools: [
          FakeTool.text(
            'name',
            (_) => 'hello',
            description: 'description',
            inputSchema: const {
              'type': 'object',
              'properties': {
                'input': {'type': 'string'},
              },
              'required': ['input'],
            },
          ),
          FakeTool.text('name2', (_) => 'hello', description: 'description'),
        ],
      );
      final transport = FakeInMemoryTransport(server);
      final client = await McpClient.connect(transport);
      addTearDown(client.close);
      final toolkit = McpToolkit(client);

      var tools = await toolkit.getTools(_ctx, toolNameList: ['name']);
      expect(tools, hasLength(1));
      final info = await tools.single.info();
      expect(info.name, 'name');
      expect(info.desc, 'description');
      expect(info.function.parameters!.properties.keys, ['input']);
      expect(info.function.parameters!.required, ['input']);

      final result = await tools.single.invokableRun(
        _ctx,
        '{"input": "123"}',
        options: const ToolOptions(
          extensions: [McpToolOptions(customHeaders: {'key': 'value'})],
        ),
      );
      expect(result, '{"content":[{"type":"text","text":"hello"}]}');
      expect(transport.sentHeaders.last, {'key': 'value'});
      expect(server.receivedOf('tools/call').last.params['arguments'],
          {'input': '123'});

      tools = await toolkit.getTools(
        _ctx,
        toolNameList: ['name'],
        customHeaders: {'key': 'value'},
      );
      expect(tools, hasLength(1));
      expect(transport.sentHeaders.last, {'key': 'value'},
          reason: 'the listing carries the custom headers');
      await tools.single.invokableRun(_ctx, '{"input": "1"}');
      expect(transport.sentHeaders.last, {'key': 'value'},
          reason: 'every call carries them');

      // call tools without arguments
      tools = await toolkit.getTools(_ctx, toolNameList: ['name2']);
      expect(tools, hasLength(1));
      expect(
        await tools.single.invokableRun(_ctx, ''),
        '{"content":[{"type":"text","text":"hello"}]}',
      );
      expect(server.receivedOf('tools/call').last.params['arguments'],
          <String, Object?>{});
    });
  });

  test('TestWithCustomHeaders', () {
    const headers = {'Authorization': 'Bearer 123456'};
    const options = ToolOptions(
      extensions: [McpToolOptions(customHeaders: headers)],
    );
    expect(options.extension<McpToolOptions>()!.customHeaders, headers);
  });

  test('TestTool (officialmcp)', () async {
    final (client, _) = await _session();
    final tools =
        await McpToolkit(client).getTools(_ctx, toolNameList: ['greet']);
    expect(tools, hasLength(1));
    expect((await tools.single.info()).name, 'greet');
    expect(
      await tools.single.invokableRun(_ctx, '{"name": "eino"}'),
      '{"content":[{"type":"text","text":"Hi eino"}]}',
    );
  });

  test('TestToolNameMapperMetadataAndRawInvocation', () async {
    final (client, server) = await _session();
    final tools = await McpToolkit(client, serverName: 'docs').getTools(
      _ctx,
      toolNameMapper: (ctx, input) => McpToolNameMapping(
        exposedName: 'mcp__${input.serverName}__${input.tool.name}',
        extra: const {'runtime': 'test'},
      ),
      toolNameList: ['greet'],
    );
    expect(tools, hasLength(1));
    final info = await tools.single.info();
    expect(info.name, 'mcp__docs__greet');
    expect(info.extra![McpToolExtraKeys.serverName], 'docs');
    expect(info.extra![McpToolExtraKeys.rawToolName], 'greet');
    expect(info.extra![McpToolExtraKeys.exposedToolName], 'mcp__docs__greet');
    expect(info.extra!['runtime'], 'test');
    expect(_jsonRoundTrip(info)['extra'], info.extra);

    expect(
      await tools.single.invokableRun(_ctx, '{"name": "eino"}'),
      '{"content":[{"type":"text","text":"Hi eino"}]}',
    );
    expect(server.receivedOf('tools/call').last.params['name'], 'greet',
        reason: 'the raw name goes to the server');
  });

  test('TestToolNameMapperRejectsDuplicateAndReservedExtra', () async {
    final (client, _) = await _session();
    final toolkit = McpToolkit(client);
    await expectLater(
      toolkit.getTools(
        _ctx,
        toolNameMapper: (_, __) =>
            const McpToolNameMapping(exposedName: 'duplicate'),
      ),
      throwsA(
        isA<ThreepioException>().having(
          (e) => e.message,
          'message',
          contains('duplicate official mcp exposed tool name'),
        ),
      ),
    );
    await expectLater(
      toolkit.getTools(
        _ctx,
        toolNameMapper: (_, input) => McpToolNameMapping(
          exposedName: input.tool.name,
          extra: const {McpToolExtraKeys.rawToolName: 'override'},
        ),
      ),
      throwsA(
        isA<ThreepioException>()
            .having((e) => e.message, 'message', contains('reserved key')),
      ),
    );
  });

  test('a mapper that fails or returns an empty name', () async {
    final (client, _) = await _session();
    final toolkit = McpToolkit(client);
    await expectLater(
      toolkit.getTools(
        _ctx,
        toolNameMapper: (_, __) => throw Exception('mapper broke'),
      ),
      throwsA(
        isA<ThreepioException>()
            .having((e) => e.message, 'message', contains('mapper broke'))
            .having((e) => e.cause, 'cause', isA<Exception>()),
      ),
    );
    await expectLater(
      toolkit.getTools(
        _ctx,
        toolNameMapper: (_, __) => const McpToolNameMapping(exposedName: ''),
      ),
      throwsA(
        isA<ThreepioException>().having(
          (e) => e.message,
          'message',
          contains('exposed tool name is empty'),
        ),
      ),
    );
    await expectLater(
      toolkit.getTools(
        _ctx,
        toolNameMapper: (_, __) => throw const _Interrupt(),
      ),
      throwsA(isA<_Interrupt>()),
    );
  });

  test('TestMetadataFullAndAnnotations', () async {
    final (client, _) = await _session(
      extra: [
        FakeTool.text(
          'annotated',
          _sayHi,
          description: 'annotated tool',
          annotations: const {
            'readOnlyHint': true,
            'openWorldHint': true,
            'title': 'Annotated',
          },
        ),
      ],
    );
    final tools = await McpToolkit(client, serverName: 'docs').getTools(
      _ctx,
      toolNameList: ['annotated'],
      metadataMode: McpMetadataMode.full,
    );
    expect(tools, hasLength(1));
    final info = await tools.single.info();
    final annotations =
        info.extra![McpToolExtraKeys.annotations] as Map<String, Object?>;
    expect(annotations['readOnlyHint'], true);
    expect(annotations['openWorldHint'], true);
    expect(annotations['title'], 'Annotated');
    expect(info.extra, contains(McpToolExtraKeys.rawTool));
    expect(
      (info.extra![McpToolExtraKeys.rawTool] as Map<String, Object?>)['name'],
      'annotated',
    );
    expect(_jsonRoundTrip(info)['extra'], info.extra);

    final basic = await McpToolkit(client)
        .getTools(_ctx, toolNameList: ['annotated', 'greet']);
    expect(basic.map((t) => t.rawToolName), ['greet', 'annotated'],
        reason: 'the order of the server');
    final annotatedInfo = await basic.last.info();
    expect(annotatedInfo.extra, isNot(contains(McpToolExtraKeys.rawTool)));
    expect(annotatedInfo.extra, contains(McpToolExtraKeys.annotations));
    expect((await basic.first.info()).extra,
        isNot(contains(McpToolExtraKeys.annotations)),
        reason: 'annotations only when the server gave some');
  });

  test('TestToolCallResultHandlers', () async {
    final (client, _) = await _session();
    final order = <String>[];
    String? legacyName;
    McpToolCallInfo? v2Info;
    final tools = await McpToolkit(client, serverName: 'docs').getTools(
      _ctx,
      toolNameMapper: (_, input) =>
          McpToolNameMapping(exposedName: 'mcp__docs__${input.tool.name}'),
      toolNameList: ['greet'],
      resultHandler: (ctx, name, result) {
        order.add('legacy');
        legacyName = name;
        return result;
      },
      resultHandlerV2: (ctx, info, result) {
        order.add('v2');
        v2Info = info;
        return result;
      },
    );
    await tools.single.invokableRun(_ctx, '{"name": "eino"}');
    expect(order, ['legacy', 'v2']);
    expect(legacyName, 'mcp__docs__greet');
    expect(v2Info!.serverName, 'docs');
    expect(v2Info!.rawToolName, 'greet');
    expect(v2Info!.exposedToolName, 'mcp__docs__greet');
    expect(v2Info!.tool.name, 'greet');
  });

  test('a handler may replace the result; its failure is wrapped, an '
      'interrupt passes through', () async {
    final (client, _) = await _session();
    final toolkit = McpToolkit(client);
    var tools = await toolkit.getTools(
      _ctx,
      toolNameList: ['greet'],
      resultHandler: (_, __, result) =>
          result.copyWith(content: [const McpTextContent('replaced')]),
    );
    expect(await tools.single.invokableRun(_ctx, '{}'),
        '{"content":[{"type":"text","text":"replaced"}]}');

    tools = await toolkit.getTools(
      _ctx,
      toolNameList: ['greet'],
      resultHandler: (_, __, ___) => throw Exception('handler broke'),
    );
    await expectLater(
      tools.single.invokableRun(_ctx, '{}'),
      throwsA(
        isA<ThreepioException>().having(
          (e) => e.message,
          'message',
          contains('failed to execute official mcp tool call result handler'),
        ),
      ),
    );

    tools = await toolkit.getTools(
      _ctx,
      toolNameList: ['greet'],
      resultHandler: (_, __, ___) => throw const CancelledException('stop'),
    );
    await expectLater(
      tools.single.invokableRun(_ctx, '{}'),
      throwsA(isA<CancelledException>()),
    );

    tools = await toolkit.getTools(
      _ctx,
      toolNameList: ['greet'],
      resultHandlerV2: (_, __, ___) => throw const _Interrupt(),
    );
    await expectLater(
      tools.single.invokableRun(_ctx, '{}'),
      throwsA(isA<_Interrupt>()),
    );
    await expectLater(
      tools.single.enhancedInvokableRun(_ctx, const ToolArgument('{}')),
      throwsA(isA<_Interrupt>()),
    );
  });

  test('TestResultAndDescriptionPolicies', () async {
    final description = String.fromCharCode(0x597D) * 8;
    final (client, _) = await _session(
      extra: [
        FakeTool.text('long', (_) => 'x' * 200, description: description),
      ],
    );
    final tools = await McpToolkit(client).getTools(
      _ctx,
      toolNameList: ['long'],
      descriptionPolicy: const McpDescriptionPolicy(maxChars: 5),
      resultPolicy: const McpResultPolicy(maxChars: 180, preserveTailChars: 10),
    );
    final info = await tools.single.info();
    expect(info.desc!.runes.length, lessThanOrEqualTo(5));
    final result = await tools.single.invokableRun(_ctx, '{"name": "eino"}');
    expect(result, contains('"truncated":true'));
    expect(result.runes.length, lessThanOrEqualTo(180));
    final decoded = jsonDecode(result) as Map<String, Object?>;
    final meta = decoded['_meta']! as Map<String, Object?>;
    expect(meta['originalChars'], greaterThan(200));
    final text = ((decoded['content']! as List).single as Map)['text'] as String;
    expect(text, contains('...[truncated original_chars='));
    // The tail kept is the one of the marshaled result, as in Go.
    expect(text, endsWith('xxxxxx"}]}'));
  });

  test('a description longer than the policy keeps head and marker', () async {
    final (client, _) = await _session(
      extra: [FakeTool.text('desc', (_) => '', description: 'a' * 100)],
    );
    final tools = await McpToolkit(client).getTools(
      _ctx,
      toolNameList: ['desc'],
      descriptionPolicy: const McpDescriptionPolicy(maxChars: 60),
    );
    final desc = (await tools.single.info()).desc!;
    expect(desc.length, 60);
    expect(desc, startsWith('aaa'));
    expect(desc, endsWith('...[truncated original_chars=100 returned_chars=60]...'));
  });

  test('TestResultPolicyCanReturnServerErrorAsResult', () async {
    final (client, _) = await _session(
      extra: [
        FakeTool(
          name: 'fail',
          description: 'fail',
          handler: (_, __) => {
            'content': [
              {'type': 'text', 'text': 'server error'},
            ],
            'isError': true,
          },
        ),
      ],
    );
    var tools =
        await McpToolkit(client).getTools(_ctx, toolNameList: ['fail']);
    await expectLater(
      tools.single.invokableRun(_ctx, '{"name": "eino"}'),
      throwsA(
        predicate(
          (e) => McpToolkitException.isKind(e, McpErrorKind.serverToolError),
        ),
      ),
    );
    await expectLater(
      tools.single.enhancedInvokableRun(_ctx, const ToolArgument('{}')),
      throwsA(
        isA<McpToolkitException>()
            .having((e) => e.kind, 'kind', McpErrorKind.serverToolError)
            .having((e) => e.message, 'message', contains('server error')),
      ),
    );

    tools = await McpToolkit(client).getTools(
      _ctx,
      toolNameList: ['fail'],
      resultPolicy: const McpResultPolicy(errorAsError: false),
    );
    expect(await tools.single.invokableRun(_ctx, '{"name": "eino"}'),
        contains('server error'));
    final enhanced =
        await tools.single.enhancedInvokableRun(_ctx, const ToolArgument('{}'));
    expect(enhanced.parts.single.text, 'server error');
  });

  test('TestListToolsPagination', () async {
    final (client, _) = await _session(pageSize: 1);
    final toolkit = McpToolkit(client);
    expect(await toolkit.getTools(_ctx), hasLength(1));
    expect(
      await toolkit.getTools(_ctx, listToolsMode: McpListToolsMode.allPages),
      hasLength(greaterThanOrEqualTo(2)),
    );
    final fromCursor = await toolkit.getTools(_ctx, cursor: '1');
    expect((await fromCursor.single.info()).name, 'hello');
  });

  test('TestListToolsPaginationMaxPages', () async {
    final (client, _) = await _session(pageSize: 1);
    await expectLater(
      McpToolkit(client).getTools(
        _ctx,
        listToolsMode: McpListToolsMode.allPages,
        maxToolPages: 1,
      ),
      throwsA(
        isA<McpToolkitException>()
            .having((e) => e.kind, 'kind', McpErrorKind.listTools)
            .having((e) => e.message, 'message',
                contains('exceeded max tool pages')),
      ),
    );
  });

  test('a cursor the server repeats stops the listing', () async {
    final (client, server) = await _session();
    server.toolsListOverride = (cursor) => {
          'tools': [
            {
              'name': 'tool-${cursor ?? 'first'}',
              'inputSchema': {'type': 'object'},
            },
          ],
          'nextCursor': 'again',
        };
    await expectLater(
      McpToolkit(client)
          .getTools(_ctx, listToolsMode: McpListToolsMode.allPages),
      throwsA(
        isA<McpToolkitException>()
            .having((e) => e.kind, 'kind', McpErrorKind.listTools)
            .having((e) => e.message, 'message', contains('repeated cursor: again')),
      ),
    );
    expect(server.receivedOf('tools/list'), hasLength(2));
  });

  test('listing errors: a rejected listing and a broken connection', () async {
    final (client, server) = await _session();
    server.toolsListOverride = (_) => throw FakeRpcError(-32603, 'list broke');
    await expectLater(
      McpToolkit(client, serverName: 'docs').getTools(_ctx),
      throwsA(
        isA<McpToolkitException>()
            .having((e) => e.kind, 'kind', McpErrorKind.listTools)
            .having((e) => e.serverName, 'serverName', 'docs')
            .having((e) => e.cause, 'cause', isA<McpException>()),
      ),
    );
    final broken = _StubSession(
      listError: const McpConnectionException('connection closed'),
    );
    await expectLater(
      McpToolkit(broken).getTools(_ctx),
      throwsA(
        isA<McpToolkitException>()
            .having((e) => e.kind, 'kind', McpErrorKind.connection),
      ),
    );
  });

  test('TestValidateConfigAndErrorHelpers', () async {
    final (client, _) = await _session();
    await expectLater(
      McpToolkit(client).getTools(_ctx, maxToolPages: -1),
      throwsArgumentError,
    );

    final cause = Exception('assert.AnError');
    final wrapped = McpToolkitException(
      'general error for testing',
      kind: McpErrorKind.callTool,
      cause: cause,
    );
    expect(wrapped.message, 'general error for testing');
    expect(ThreepioException.findCause<Exception>(wrapped), same(wrapped));
    expect(wrapped.cause, same(cause));
    expect(McpToolkitException.isKind(wrapped, McpErrorKind.callTool), isTrue);
    expect(McpToolkitException.isKind(wrapped, McpErrorKind.connection), isFalse);
    expect(McpErrorKind.serverToolError.wireValue, 'server_tool_error');
    expect(McpMetadataMode.full.wireValue, 'full');
    expect(McpListToolsMode.allPages.wireValue, 'all_pages');
  });

  test('TestResultPolicyIncludesStructuredContentAndMeta', () async {
    final (client, _) = await _session(
      extra: [
        FakeTool(
          name: 'structured',
          handler: (_, __) => {
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'structuredContent': {'answer': 42},
            '_meta': {'trace_id': 'abc'},
          },
        ),
      ],
    );
    final toolkit = McpToolkit(client);
    final tools = await toolkit.getTools(
      _ctx,
      toolNameList: ['structured'],
      resultPolicy: const McpResultPolicy(
        includeStructuredContent: true,
        includeMeta: true,
      ),
    );
    final marshaled = await tools.single.invokableRun(_ctx, '{}');
    expect(marshaled, contains('"structuredContent":{"answer":42}'));
    expect(marshaled, contains('"_meta":{"trace_id":"abc"}'));

    final withoutPolicy =
        await toolkit.getTools(_ctx, toolNameList: ['structured']);
    expect(
      await withoutPolicy.single.invokableRun(_ctx, '{}'),
      '{"_meta":{"trace_id":"abc"},"content":[{"type":"text","text":"ok"}],'
      '"structuredContent":{"answer":42}}',
    );
    final plainPolicy = await toolkit.getTools(
      _ctx,
      toolNameList: ['structured'],
      resultPolicy: const McpResultPolicy(),
    );
    expect(await plainPolicy.single.invokableRun(_ctx, '{}'),
        '{"content":[{"type":"text","text":"ok"}]}');
  });

  test('TestAttack_ResultPolicyRejectsImpossibleMaxChars', () async {
    final (client, _) = await _session(
      extra: [FakeTool.text('big', (_) => 'x' * 200)],
    );
    final tools = await McpToolkit(client).getTools(
      _ctx,
      toolNameList: ['big'],
      resultPolicy: const McpResultPolicy(maxChars: 1),
    );
    await expectLater(
      tools.single.invokableRun(_ctx, '{}'),
      throwsA(
        isA<McpToolkitException>()
            .having((e) => e.kind, 'kind', McpErrorKind.resultPolicy)
            .having((e) => e.message, 'message', contains('exceeds max chars')),
      ),
    );
  });

  test('TestAttack_ResultHandlerNilResultDoesNotPanic', () async {
    final (client, _) = await _session();
    var tools = await McpToolkit(client).getTools(
      _ctx,
      toolNameList: ['greet'],
      resultHandler: (_, __, ___) => null,
    );
    await expectLater(
      tools.single.invokableRun(_ctx, '{"name": "eino"}'),
      throwsA(
        predicate(
          (e) => McpToolkitException.isKind(e, McpErrorKind.resultPolicy),
        ),
      ),
    );
    tools = await McpToolkit(client).getTools(
      _ctx,
      toolNameList: ['greet'],
      resultHandlerV2: (_, __, ___) => null,
    );
    await expectLater(
      tools.single.invokableRun(_ctx, '{}'),
      throwsA(
        isA<McpToolkitException>()
            .having((e) => e.message, 'message', contains('v2 returned nil')),
      ),
    );
  });

  test('TestInvokableRunClassifiesConnectionError', () async {
    var tool = await _stubTool(
      _StubSession(
        callError: const McpConnectionException(
          'calling "tools/call": connection closed',
        ),
      ),
    );
    Object? error;
    try {
      await tool.invokableRun(_ctx, '{}');
    } on Object catch (e) {
      error = e;
    }
    expect(McpToolkitException.isKind(error, McpErrorKind.connection), isTrue,
        reason: 'want ErrorKindConnection, got $error');
    expect(isMcpConnectionError(error), isTrue);

    tool = await _stubTool(
      _StubSession(
        callError: ThreepioException(
          'wrap',
          cause: const McpConnectionException('session not found',
              sessionMissing: true),
        ),
      ),
    );
    await expectLater(
      tool.invokableRun(_ctx, '{}'),
      throwsA(predicate(
          (e) => McpToolkitException.isKind(e, McpErrorKind.connection))),
    );
  });

  test('TestInvokableRunClassifiesProtocolErrorAsCallTool', () async {
    final tool = await _stubTool(
      _StubSession(
        callError: const McpException('invalid params', code: -32602),
      ),
    );
    Object? error;
    try {
      await tool.invokableRun(_ctx, '{}');
    } on Object catch (e) {
      error = e;
    }
    expect(McpToolkitException.isKind(error, McpErrorKind.callTool), isTrue);
    expect(McpToolkitException.isKind(error, McpErrorKind.connection), isFalse);
    expect(isMcpConnectionError(error), isFalse);
  });

  test('TestIsConnectionError', () {
    expect(isMcpConnectionError(null), isFalse);
    expect(isMcpConnectionError(Exception('plain')), isFalse);
    expect(
      isMcpConnectionError(
        const ThreepioException('x', cause: McpConnectionException('closed')),
      ),
      isTrue,
    );
    expect(
      isMcpConnectionError(
        const ThreepioException(
          'x',
          cause: McpConnectionException('missing', sessionMissing: true),
        ),
      ),
      isTrue,
    );
    expect(
      isMcpConnectionError(
        const McpToolkitException('', kind: McpErrorKind.connection),
      ),
      isTrue,
    );
    expect(
      isMcpConnectionError(
        const McpToolkitException('', kind: McpErrorKind.callTool),
      ),
      isFalse,
    );
  });

  group('calls', () {
    test('the tool is both an InvokableTool and an EnhancedInvokableTool',
        () async {
      final (client, _) = await _session();
      final tool = (await McpToolkit(client).getTools(_ctx)).first;
      expect(tool, isA<InvokableTool>());
      expect(tool, isA<EnhancedInvokableTool>());
      expect(tool.rawToolName, 'greet');
      expect(tool.exposedToolName, 'greet');
      expect(tool.rawTool.description, 'say hi');
    });

    test('_meta from the toolkit, replaced by the call options', () async {
      final (client, server) = await _session();
      final tool = (await McpToolkit(client).getTools(
        _ctx,
        toolNameList: ['greet'],
        meta: {'progressToken': 'config'},
        customHeaders: {'X-Config': '1'},
      ))
          .single;
      await tool.invokableRun(_ctx, '{}');
      expect(server.receivedOf('tools/call').last.params['_meta'],
          {'progressToken': 'config'});
      await tool.invokableRun(
        _ctx,
        '{}',
        options: const ToolOptions(
          extensions: [
            McpToolOptions(meta: {'progressToken': 'call'}),
          ],
        ),
      );
      expect(server.receivedOf('tools/call').last.params['_meta'],
          {'progressToken': 'call'});
    });

    test('arguments that are not JSON fail as call_tool with a format cause',
        () async {
      final (client, server) = await _session();
      final tool = (await McpToolkit(client).getTools(_ctx)).first;
      await expectLater(
        tool.invokableRun(_ctx, '{not json'),
        throwsA(
          isA<McpToolkitException>()
              .having((e) => e.kind, 'kind', McpErrorKind.callTool)
              .having((e) => e.cause, 'cause', isA<ThreepioFormatException>()),
        ),
      );
      expect(server.receivedOf('tools/call'), isEmpty);
    });

    test('an unknown tool on the server is call_tool', () async {
      final (client, server) = await _session();
      final tool = (await McpToolkit(client).getTools(_ctx)).first;
      server.tools.clear();
      await expectLater(
        tool.invokableRun(_ctx, '{}'),
        throwsA(
          isA<McpToolkitException>()
              .having((e) => e.kind, 'kind', McpErrorKind.callTool)
              .having((e) => e.rawToolName, 'rawToolName', 'greet'),
        ),
      );
    });

    test('cancellation through the RunContext throws CancelledException',
        () async {
      final release = Completer<Map<String, Object?>>();
      final (client, _) = await _session(
        extra: [FakeTool(name: 'slow', handler: (_, __) => release.future)],
      );
      final tool = (await McpToolkit(client)
              .getTools(_ctx, toolNameList: ['slow']))
          .single;
      final token = CancelToken();
      final call = tool.invokableRun(
        RunContext.background(cancelToken: token),
        '{}',
      );
      await pumpEventQueue();
      token.cancel('stop');
      await expectLater(call, throwsA(isA<CancelledException>()));
      release.complete({'content': <Object?>[]});
    });
  });

  group('multimodal results', () {
    test('every content kind becomes a ToolOutputPart', () async {
      final (client, _) = await _session(
        extra: [
          FakeTool(
            name: 'media',
            handler: (_, __) => {
              'content': [
                {'type': 'text', 'text': 'look'},
                {'type': 'image', 'mimeType': 'image/png', 'data': 'aW1n'},
                {'type': 'audio', 'mimeType': 'audio/wav', 'data': 'YXVk'},
                {
                  'type': 'resource_link',
                  'uri': 'file:///a.txt',
                  'name': 'a.txt',
                },
                {
                  'type': 'resource',
                  'resource': {
                    'uri': 'mem://note',
                    'mimeType': 'text/plain',
                    'text': 'a note',
                  },
                },
                {
                  'type': 'resource',
                  'resource': {
                    'uri': 'mem://pic',
                    'mimeType': 'image/jpeg',
                    'blob': 'cGlj',
                  },
                },
                {
                  'type': 'resource',
                  'resource': {
                    'uri': 'mem://clip',
                    'mimeType': 'video/mp4',
                    'blob': 'dmlk',
                  },
                },
                {
                  'type': 'resource',
                  'resource': {
                    'uri': 'mem://doc',
                    'mimeType': 'application/pdf',
                    'blob': 'cGRm',
                  },
                },
              ],
              'structuredContent': {'n': 1},
            },
          ),
        ],
      );
      final tool = (await McpToolkit(client).getTools(
        _ctx,
        toolNameList: ['media'],
        resultPolicy: const McpResultPolicy(includeStructuredContent: true),
      ))
          .single;
      final result =
          await tool.enhancedInvokableRun(_ctx, const ToolArgument('{}'));
      final parts = result.parts;
      expect(parts.map((p) => p.type), [
        ToolPartType.text,
        ToolPartType.image,
        ToolPartType.audio,
        ToolPartType.text,
        ToolPartType.text,
        ToolPartType.image,
        ToolPartType.video,
        ToolPartType.file,
        ToolPartType.text,
      ]);
      expect(parts[0].text, 'look');
      expect(parts[1].image!.common.base64Data, 'aW1n');
      expect(parts[1].image!.common.mimeType, 'image/png');
      expect(parts[2].audio!.common.base64Data, 'YXVk');
      expect(jsonDecode(parts[3].text!), {
        'type': 'resource_link',
        'uri': 'file:///a.txt',
        'name': 'a.txt',
      });
      expect(parts[4].text, 'a note');
      expect(parts[4].extra, {McpToolExtraKeys.resourceUri: 'mem://note'});
      expect(parts[5].image!.common.base64Data, 'cGlj');
      expect(parts[5].extra, {McpToolExtraKeys.resourceUri: 'mem://pic'});
      expect(parts[6].video!.common.mimeType, 'video/mp4');
      expect(parts[7].file!.common.base64Data, 'cGRm');
      expect(parts[8].text, '{"n":1}');

      // The parts convert to message input parts, as a tools node does.
      expect(result.toMessageInputParts(), hasLength(9));
    });

    test('maxChars bounds each text part', () async {
      final (client, _) = await _session(
        extra: [FakeTool.text('long', (_) => 'y' * 100)],
      );
      final tool = (await McpToolkit(client).getTools(
        _ctx,
        toolNameList: ['long'],
        resultPolicy: const McpResultPolicy(maxChars: 70, preserveTailChars: 5),
      ))
          .single;
      final result =
          await tool.enhancedInvokableRun(_ctx, const ToolArgument('{}'));
      final text = result.parts.single.text!;
      expect(text.length, 70);
      expect(text, endsWith('yyyyy'));
      expect(text, contains('...[truncated original_chars=100'));
    });
  });

  group('input schemas', () {
    test('keywords threepio knows are kept, the rest typed leniently',
        () async {
      final (client, _) = await _session(
        extra: [
          FakeTool.text(
            'schema',
            (_) => '',
            inputSchema: const {
              'type': 'object',
              'properties': {
                'mode': {
                  'type': 'string',
                  'enum': ['a', 'b'],
                  'description': 'the mode',
                },
                'count': {
                  'type': ['integer', 'null'],
                },
                'maybe': {
                  'anyOf': [
                    {'type': 'null'},
                    {'type': 'number'},
                  ],
                },
                'tags': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'nested': {
                  'properties': {
                    'x': {'type': 'boolean'},
                  },
                  'required': ['x'],
                },
                'anything': <String, Object?>{},
              },
              'required': ['mode'],
              'additionalProperties': false,
            },
          ),
        ],
      );
      final info = await (await McpToolkit(client)
              .getTools(_ctx, toolNameList: ['schema']))
          .single
          .info();
      final schema = info.function.parameters!;
      expect(schema.required, ['mode']);
      final properties = schema.properties;
      expect(properties['mode']!.enumValues, ['a', 'b']);
      expect(properties['mode']!.description, 'the mode');
      expect(properties['count']!.type, 'integer');
      expect(properties['maybe']!.type, 'number');
      expect(properties['tags']!.type, 'array');
      expect(properties['tags']!.items!.type, 'string');
      expect(properties['nested']!.type, 'object');
      expect(properties['nested']!.properties!['x']!.type, 'boolean');
      expect(properties['nested']!.required, ['x']);
      expect(properties['anything']!.type, 'string');
    });

    test('an input schema that is not an object is schema_convert', () async {
      final session = _SchemaSession();
      await expectLater(
        McpToolkit(session, serverName: 'docs').getTools(_ctx),
        throwsA(
          isA<McpToolkitException>()
              .having((e) => e.kind, 'kind', McpErrorKind.schemaConvert)
              .having((e) => e.rawToolName, 'rawToolName', 'odd'),
        ),
      );
    });

    test('a tool without an input schema takes no parameters', () async {
      final tools = await McpToolkit(_StubSession()).getTools(_ctx);
      final info = await tools.single.info();
      expect(info.function.parameters!.properties, isEmpty);
      expect(info.function.parameters!.type, 'object');
    });
  });
}

final class _SchemaSession extends _StubSession {
  @override
  Future<McpListToolsResult> listTools({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async =>
      const McpListToolsResult(
        tools: [McpTool(name: 'odd', inputSchema: 'not a schema')],
      );
}
