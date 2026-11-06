// Tests of the JSON-RPC client of MCP (lib/src/components/tool/mcp/
// mcp_client.dart), written for the port: eino-ext leaves the client to the
// Go SDKs (mark3labs/mcp-go, modelcontextprotocol/go-sdk), whose own tests
// are not part of eino-ext. Covered: the initialize handshake, request ids,
// out-of-order responses, JSON-RPC errors, timeouts and cancellation (with
// notifications/cancelled), server requests (ping, method not found),
// notifications, malformed and batched input, connection failures, the
// tool and prompt requests, and the protocol value types.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/errors.dart';

import '../../../support/fake_mcp_server.dart';

Future<(McpClient, ScriptedMcpTransport)> _scripted({
  Duration? requestTimeout,
  McpNotificationHandler? onNotification,
}) async {
  final transport = ScriptedMcpTransport();
  final client = await McpClient.connect(
    transport,
    requestTimeout: requestTimeout,
    onNotification: onNotification,
  );
  return (client, transport);
}

void main() {
  group('initialize', () {
    test('sends clientInfo, capabilities and the protocol version, then '
        'notifications/initialized', () async {
      final server = FakeMcpServer();
      final transport = FakeInMemoryTransport(server);
      final client = await McpClient.connect(
        transport,
        clientInfo: const McpImplementation(name: 'test', version: 'v1.0.0'),
        capabilities: const {'roots': <String, Object?>{}},
      );

      final init = server.receivedOf('initialize').single.params;
      expect(init['protocolVersion'], mcpLatestProtocolVersion);
      expect(init['clientInfo'], {'name': 'test', 'version': 'v1.0.0'});
      expect(init['capabilities'], {'roots': <String, Object?>{}});
      expect(server.receivedOf('notifications/initialized'), hasLength(1));
      expect(
        server.received.map((r) => r.method).toList(),
        ['initialize', 'notifications/initialized'],
      );
      expect(transport.sent.first['id'], 1);
      expect(transport.sent.first['jsonrpc'], '2.0');
      expect(transport.sent[1].containsKey('id'), isFalse);

      final result = client.initializeResult!;
      expect(result.protocolVersion, mcpLatestProtocolVersion);
      expect(result.serverInfo, const McpImplementation(name: 'fake', version: 'v1.0.0'));
      expect(result.capabilities, contains('tools'));
      expect(transport.protocolVersion, mcpLatestProtocolVersion);
      await client.close();
    });

    test('the default client info is the one of eino-ext officialmcp', () async {
      final server = FakeMcpServer();
      final client = await McpClient.connect(FakeInMemoryTransport(server));
      expect(
        server.receivedOf('initialize').single.params['clientInfo'],
        {'name': 'eino-officialmcp', 'version': 'v0.0.0'},
      );
      await client.close();
    });

    test('accepts an older revision the server answers with', () async {
      final server = FakeMcpServer()..answerVersion = '2024-11-05';
      final transport = FakeInMemoryTransport(server);
      final client = await McpClient.connect(transport);
      expect(client.initializeResult!.protocolVersion, '2024-11-05');
      expect(transport.protocolVersion, '2024-11-05');
      await client.close();
    });

    test('rejects an unsupported revision and closes the transport', () async {
      final server = FakeMcpServer()..answerVersion = '1999-01-01';
      final transport = FakeInMemoryTransport(server);
      await expectLater(
        McpClient.connect(transport),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            contains('unsupported protocol version'),
          ),
        ),
      );
      expect(transport.closed, isTrue);
      expect(server.receivedOf('notifications/initialized'), isEmpty);
    });

    test('an error answer fails the handshake with the JSON-RPC error', () async {
      final transport = ScriptedMcpTransport(autoInitialize: false)
        ..onSend = (m) {};
      final client = McpClient(transport);
      final future = client.initialize();
      final request = await transport.nextSent('initialize');
      transport.respondError(request['id'], -32603, 'nope');
      await expectLater(
        future,
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32603)),
      );
      expect(client.isClosed, isTrue);
      expect(transport.closed, isTrue);
    });

    test('a transport that cannot start fails with McpConnectionException',
        () async {
      final transport = _FailingStartTransport();
      await expectLater(
        McpClient.connect(transport),
        throwsA(isA<McpConnectionException>()),
      );
    });

    test('a transport start that never ends is bounded by requestTimeout and '
        'the cancel token', () async {
      final hanging = _HangingStartTransport();
      await expectLater(
        McpClient.connect(
          hanging,
          requestTimeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<McpTimeoutException>()),
      );
      expect(hanging.closed, isTrue);

      final other = _HangingStartTransport();
      final token = CancelToken();
      final connecting = McpClient.connect(other, cancelToken: token);
      await pumpEventQueue();
      token.cancel('give up');
      await expectLater(connecting, throwsA(isA<CancelledException>()));
      expect(other.closed, isTrue);
    });

    test('initialize twice is a StateError; requests before it too', () async {
      final transport = ScriptedMcpTransport();
      final client = McpClient(transport);
      expect(() => client.listTools(), throwsStateError);
      await client.initialize();
      expect(client.initialize, throwsStateError);
      await client.close();
    });
  });

  group('requests', () {
    test('ids count up from 1 and responses may come in any order', () async {
      final (client, transport) = await _scripted();
      final first = client.request('a/one');
      final second = client.request('a/two');
      final third = client.request('a/three');
      await pumpEventQueue();
      final ids = [
        for (final m in transport.sent.where((m) => m['id'] != null)) m['id'],
      ];
      expect(ids, [1, 2, 3, 4]);

      transport
        ..respond(4, {'n': 'three'})
        ..respond(2, {'n': 'one'})
        ..respond(3, {'n': 'two'});
      expect(await first, {'n': 'one'});
      expect(await second, {'n': 'two'});
      expect(await third, {'n': 'three'});
      await client.close();
    });

    test('a string id that names a number matches the request', () async {
      final (client, transport) = await _scripted();
      final future = client.request('x');
      await pumpEventQueue();
      transport.respond('2', {'ok': true});
      expect(await future, {'ok': true});
      await client.close();
    });

    test('a JSON-RPC error becomes an McpException with code, message, data',
        () async {
      final (client, transport) = await _scripted();
      final future = client.request('tools/call', params: {'name': 'x'});
      await pumpEventQueue();
      transport.respondError(2, -32602, 'invalid params', {'field': 'name'});
      await expectLater(
        future,
        throwsA(
          isA<McpException>()
              .having((e) => e.code, 'code', McpException.invalidParams)
              .having((e) => e.message, 'message', 'invalid params')
              .having((e) => e.data, 'data', {'field': 'name'}),
        ),
      );
      expect(client.isClosed, isFalse, reason: 'an error answer is no failure');
      await client.close();
    });

    test('a null result is an empty object; a non-object result is a format '
        'error', () async {
      final (client, transport) = await _scripted();
      final empty = client.request('a');
      final bad = client.request('b');
      await pumpEventQueue();
      transport
        ..push({'jsonrpc': '2.0', 'id': 2, 'result': null})
        ..push({'jsonrpc': '2.0', 'id': 3, 'result': 'text'});
      expect(await empty, isEmpty);
      await expectLater(bad, throwsA(isA<ThreepioFormatException>()));
      await client.close();
    });

    test('a request times out after requestTimeout and the server is told',
        () async {
      final (client, transport) =
          await _scripted(requestTimeout: const Duration(milliseconds: 5));
      await expectLater(
        client.request('slow/thing'),
        throwsA(
          isA<McpTimeoutException>()
              .having((e) => e.method, 'method', 'slow/thing')
              .having((e) => e.timeout, 'timeout', const Duration(milliseconds: 5)),
        ),
      );
      await pumpEventQueue();
      final cancelled = transport.sentOf('notifications/cancelled').single;
      expect((cancelled['params']! as Map)['requestId'], 2);
      final slowIndex =
          transport.sent.indexWhere((m) => m['method'] == 'slow/thing');
      expect(transport.sentTokens[slowIndex]!.isCancelled, isTrue,
          reason: 'the transport stops working on the request');
      // A late answer is ignored and the client stays usable.
      transport.respond(2, {'late': true});
      final next = client.request('next');
      await pumpEventQueue();
      transport.respond(3, {'ok': true});
      expect(await next, {'ok': true});
      await client.close();
    });

    test('a per-request timeout overrides the client one', () async {
      final (client, _) = await _scripted();
      await expectLater(
        client.request('slow', timeout: const Duration(milliseconds: 2)),
        throwsA(isA<McpTimeoutException>()),
      );
      await client.close();
    });

    test('cancellation fails the request with CancelledException and tells '
        'the server', () async {
      final (client, transport) = await _scripted();
      final token = CancelToken();
      final future = client.request('long', cancelToken: token);
      await pumpEventQueue();
      token.cancel('user stop');
      await expectLater(
        future,
        throwsA(isA<CancelledException>().having((e) => e.reason, 'reason', 'user stop')),
      );
      await pumpEventQueue();
      final cancelled = transport.sentOf('notifications/cancelled').single;
      expect(cancelled['params'], {'requestId': 2, 'reason': 'user stop'});
      expect(client.isClosed, isFalse);
      await client.close();
    });

    test('a token cancelled before the call fails at once, nothing is sent',
        () async {
      final (client, transport) = await _scripted();
      final sentBefore = transport.sent.length;
      final token = CancelToken()..cancel();
      await expectLater(
        client.request('x', cancelToken: token),
        throwsA(isA<CancelledException>()),
      );
      expect(transport.sent, hasLength(sentBefore));
      await client.close();
    });

    test('parameters that are not JSON fail without breaking the client',
        () async {
      final (client, transport) = await _scripted();
      await expectLater(
        client.request('x', params: {'value': Object()}),
        throwsA(isA<ThreepioFormatException>()),
      );
      final next = client.request('y');
      await pumpEventQueue();
      transport.respond(3, {});
      expect(await next, isEmpty);
      await client.close();
    });

    test('a send that fails breaks the client: pending and later requests '
        'fail with McpConnectionException', () async {
      final (client, transport) = await _scripted();
      final pending = expectLater(
        client.request('pending'),
        throwsA(isA<McpConnectionException>()),
      );
      await pumpEventQueue();
      transport.sendError = Exception('network down');
      await expectLater(
        client.request('broken'),
        throwsA(isA<McpConnectionException>()),
      );
      await pending;
      expect(client.isClosed, isTrue);
      await expectLater(client.request('later'), throwsA(isA<McpConnectionException>()));
    });

    test('a transport that closes fails every pending request', () async {
      final (client, transport) = await _scripted();
      final a = expectLater(
        client.request('a'),
        throwsA(isA<McpConnectionException>()),
      );
      final b = expectLater(
        client.request('b'),
        throwsA(
          isA<McpConnectionException>()
              .having((e) => e.cause, 'cause', isA<Exception>()),
        ),
      );
      await pumpEventQueue();
      transport.breakConnection(Exception('process exited'));
      await a;
      await b;
      await client.done;
    });

    test('close fails pending requests, closes the transport, is idempotent',
        () async {
      final (client, transport) = await _scripted();
      final pending = expectLater(
        client.request('a'),
        throwsA(isA<McpConnectionException>()),
      );
      await pumpEventQueue();
      await client.close();
      await client.close();
      await pending;
      expect(transport.closed, isTrue);
      expect(client.isClosed, isTrue);
      await expectLater(client.ping(), throwsA(isA<McpConnectionException>()));
    });

    test('a send that throws synchronously fails the request, not the caller',
        () async {
      final transport = _SyncThrowingTransport();
      final client = await McpClient.connect(transport);
      transport.throwNow = true;
      await expectLater(
        client.request('x'),
        throwsA(isA<McpConnectionException>()),
      );
      expect(client.isClosed, isTrue);
    });

    test('the transport token of a request is released once it is answered',
        () async {
      final (client, transport) = await _scripted();
      final future = client.request('x');
      await pumpEventQueue();
      final index = transport.sent.indexWhere((m) => m['method'] == 'x');
      expect(transport.sentTokens[index]!.isCancelled, isFalse);
      transport.respond(2, {});
      await future;
      expect(transport.sentTokens[index]!.isCancelled, isTrue);
      await client.close();
    });

    test('notify sends a message without id', () async {
      final (client, transport) = await _scripted();
      await client.notify('notifications/progress', params: {'p': 1});
      expect(transport.sent.last, {
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': {'p': 1},
      });
      await client.close();
    });
  });

  group('messages of the server', () {
    test('ping is answered with an empty result', () async {
      final (client, transport) = await _scripted();
      transport.push({'jsonrpc': '2.0', 'id': 'srv-1', 'method': 'ping'});
      await pumpEventQueue();
      expect(transport.sent.last, {
        'jsonrpc': '2.0',
        'id': 'srv-1',
        'result': <String, Object?>{},
      });
      await client.close();
    });

    test('any other request gets method not found', () async {
      final (client, transport) = await _scripted();
      transport.push({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'sampling/createMessage',
        'params': <String, Object?>{},
      });
      await pumpEventQueue();
      final answer = transport.sent.last;
      expect(answer['id'], 7);
      expect((answer['error']! as Map)['code'], McpException.methodNotFound);
      expect(client.isClosed, isFalse);
      await client.close();
    });

    test('notifications reach onNotification; a failing handler is '
        'tolerated', () async {
      final seen = <(String, Map<String, Object?>?)>[];
      final (client, transport) = await _scripted(
        onNotification: (method, params) {
          seen.add((method, params));
          if (method == 'boom') throw StateError('handler bug');
        },
      );
      transport
        ..push({
          'jsonrpc': '2.0',
          'method': 'notifications/tools/list_changed',
        })
        ..push({
          'jsonrpc': '2.0',
          'method': 'notifications/message',
          'params': {'level': 'info', 'data': 'hello'},
        })
        ..push({'jsonrpc': '2.0', 'method': 'boom'})
        ..push({
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': 1},
        });
      expect(seen.map((s) => s.$1), [
        'notifications/tools/list_changed',
        'notifications/message',
        'boom',
      ]);
      expect(seen[1].$2, {'level': 'info', 'data': 'hello'});
      final next = client.request('still/works');
      await pumpEventQueue();
      transport.respond(2, {});
      await next;
      await client.close();
    });

    test('responses to unknown ids and malformed messages are ignored',
        () async {
      final (client, transport) = await _scripted();
      final future = client.request('x');
      await pumpEventQueue();
      transport
        ..respond(99, {'stray': true})
        ..push({'jsonrpc': '2.0'})
        ..push({'jsonrpc': '2.0', 'id': 2, 'error': 'not an object'});
      await expectLater(future, throwsA(isA<McpException>()));
      expect(client.isClosed, isFalse);
      await client.close();
    });
  });

  group('tools and prompts', () {
    late FakeMcpServer server;
    late FakeInMemoryTransport transport;
    late McpClient client;

    setUp(() async {
      server = FakeMcpServer(
        tools: [
          FakeTool.text('greet', (a) => 'Hi ${a['name']}', description: 'say hi'),
          FakeTool.text('hello', (a) => 'Hello ${a['name']}'),
          FakeTool.text('bye', (a) => 'Bye'),
        ],
        prompts: [
          FakePrompt(
            name: 'intro',
            description: 'an intro',
            arguments: const [
              {'name': 'who', 'required': true},
            ],
            messages: (a) => [
              {
                'role': 'user',
                'content': {'type': 'text', 'text': 'I am ${a['who']}'},
              },
            ],
          ),
        ],
      );
      transport = FakeInMemoryTransport(server);
      client = await McpClient.connect(transport);
    });

    tearDown(() => client.close());

    test('listTools follows cursors', () async {
      server.pageSize = 2;
      final first = await client.listTools();
      expect(first.tools.map((t) => t.name), ['greet', 'hello']);
      expect(first.tools.first.description, 'say hi');
      expect(first.nextCursor, '2');
      final second = await client.listTools(cursor: first.nextCursor);
      expect(second.tools.map((t) => t.name), ['bye']);
      expect(second.nextCursor, isNull);
      expect(server.receivedOf('tools/list').last.params, {'cursor': '2'});
    });

    test('callTool sends name, arguments, _meta and headers', () async {
      final result = await client.callTool(
        'greet',
        arguments: {'name': 'eino'},
        meta: {'progressToken': 'p1'},
        headers: {'X-Trace': 't1'},
      );
      expect(result.content, [const McpTextContent('Hi eino')]);
      expect(result.isError, isFalse);
      final params = server.receivedOf('tools/call').single.params;
      expect(params, {
        '_meta': {'progressToken': 'p1'},
        'name': 'greet',
        'arguments': {'name': 'eino'},
      });
      expect(transport.sentHeaders.last, {'X-Trace': 't1'});
    });

    test('an unknown tool is a JSON-RPC error', () async {
      await expectLater(
        client.callTool('nope'),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
    });

    test('listPrompts and getPrompt', () async {
      final prompts = await client.listPrompts();
      expect(prompts.prompts.single.name, 'intro');
      expect(prompts.prompts.single.arguments.single.required, isTrue);
      final rendered =
          await client.getPrompt('intro', arguments: {'who': 'Ada'});
      expect(rendered.description, 'an intro');
      expect(rendered.messages.single.role, 'user');
      expect(rendered.messages.single.content, const McpTextContent('I am Ada'));
      expect(server.receivedOf('prompts/get').single.params, {
        'name': 'intro',
        'arguments': {'who': 'Ada'},
      });
    });

    test('ping', () async {
      await client.ping();
      expect(server.receivedOf('ping'), hasLength(1));
    });
  });

  group('protocol types', () {
    test('every content kind reads and writes the go-sdk shape', () {
      final blocks = <Map<String, Object?>>[
        {'type': 'text', 'text': 'hi'},
        {
          'type': 'image',
          'mimeType': 'image/png',
          'data': 'aGk=',
          'annotations': {'priority': 1},
        },
        {'type': 'audio', 'mimeType': 'audio/wav', 'data': 'AAA='},
        {
          'type': 'resource_link',
          'mimeType': 'text/plain',
          'uri': 'file:///a.txt',
          'name': 'a.txt',
          'title': 'A',
          'description': 'a file',
          'size': 3,
        },
        {
          'type': 'resource',
          'resource': {'uri': 'mem://t', 'mimeType': 'text/plain', 'text': 'x'},
        },
        {
          'type': 'resource',
          'resource': {'uri': 'mem://b', 'mimeType': 'image/png', 'blob': 'aGk='},
          '_meta': {'k': 'v'},
        },
      ];
      final decoded = [for (final b in blocks) McpContent.fromJson(b)];
      expect(decoded.map((c) => c.runtimeType), [
        McpTextContent,
        McpImageContent,
        McpAudioContent,
        McpResourceLink,
        McpEmbeddedResource,
        McpEmbeddedResource,
      ]);
      expect((decoded[4] as McpEmbeddedResource).resource,
          isA<McpTextResourceContents>());
      expect((decoded[5] as McpEmbeddedResource).resource,
          isA<McpBlobResourceContents>());
      for (var i = 0; i < blocks.length; i++) {
        expect(jsonEncode(decoded[i].toJson()), jsonEncode(blocks[i]),
            reason: blocks[i]['type'].toString());
      }
    });

    test('an unknown content type fails to decode', () {
      expect(
        () => McpContent.fromJson({'type': 'hologram'}),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(
        () => McpCallToolResult.fromJson({
          'content': [
            {'type': 'hologram'},
          ],
        }),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('CallToolResult writes _meta, content, structuredContent, isError in '
        'go-sdk order with omissions', () {
      const plain = McpCallToolResult(content: [McpTextContent('hello')]);
      expect(jsonEncode(plain.toJson()),
          '{"content":[{"type":"text","text":"hello"}]}');
      final full = McpCallToolResult.fromJson({
        'isError': true,
        'structuredContent': {'answer': 42},
        'content': [
          {'type': 'text', 'text': 'x'},
        ],
        '_meta': {'trace_id': 'abc'},
      });
      expect(
        jsonEncode(full.toJson()),
        '{"_meta":{"trace_id":"abc"},"content":[{"type":"text","text":"x"}],'
        '"structuredContent":{"answer":42},"isError":true}',
      );
    });

    test('tools decode with annotations and write the go-sdk order', () {
      final tool = McpTool.fromJson({
        'name': 'annotated',
        'description': 'annotated tool',
        'inputSchema': {'type': 'object'},
        'annotations': {
          'readOnlyHint': true,
          'openWorldHint': true,
          'idempotentHint': false,
          'title': 'Annotated',
        },
      });
      expect(tool.annotations!.readOnlyHint, isTrue);
      expect(tool.annotations!.idempotentHint, isFalse);
      expect(tool.annotations!.destructiveHint, isNull);
      expect(jsonEncode(tool.toJson()),
          '{"annotations":{"openWorldHint":true,"readOnlyHint":true,'
          '"title":"Annotated"},"description":"annotated tool",'
          '"inputSchema":{"type":"object"},"name":"annotated"}');
    });

    test('malformed shapes are format errors', () {
      expect(() => McpTool.fromJson({'description': 'no name'}),
          throwsA(isA<ThreepioFormatException>()));
      expect(() => McpListToolsResult.fromJson({'tools': 'nope'}),
          throwsA(isA<ThreepioFormatException>()));
      expect(() => McpInitializeResult.fromJson({}),
          throwsA(isA<ThreepioFormatException>()));
    });

    test('McpException carries the JSON-RPC fields', () {
      const error = McpException('bad', code: -32602, data: {'x': 1});
      expect(error, isA<ThreepioException>());
      expect(error.toString(), contains('code -32602'));
      const connection = McpConnectionException('gone', sessionMissing: true);
      expect(connection, isA<McpException>());
      expect(connection.sessionMissing, isTrue);
      expect(connection.code, isNull);
    });
  });
}

final class _FailingStartTransport extends ScriptedMcpTransport {
  @override
  Future<void> start({
    required void Function(Map<String, Object?>) onMessage,
    required void Function(Object?) onClose,
  }) async =>
      throw Exception('cannot start');
}

final class _HangingStartTransport extends ScriptedMcpTransport {
  @override
  Future<void> start({
    required void Function(Map<String, Object?>) onMessage,
    required void Function(Object?) onClose,
  }) =>
      Completer<void>().future;
}

final class _SyncThrowingTransport extends ScriptedMcpTransport {
  bool throwNow = false;

  @override
  Future<void> send(
    Map<String, Object?> message, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) {
    if (throwNow) throw StateError('sync failure');
    return super.send(message, headers: headers, cancelToken: cancelToken);
  }
}
