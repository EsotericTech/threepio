// Tests of the HTTP transports of MCP (lib/src/components/tool/mcp/
// transports.dart), written for the port against a loopback fake server
// (test/support/fake_mcp_server.dart). eino-ext uses the transports of the Go
// SDKs (go-sdk `StreamableClientTransport`, `SSEClientTransport`), which it
// exercises only through officialmcp/session/session_test.go; those session
// tests are ported in mcp_session_test.dart.
//
// Covered: streamable HTTP with JSON and event-stream responses, the session
// id, the MCP-Protocol-Version header, custom headers, DELETE on close, 404
// (session missing), other HTTP errors, unsupported content types, a stream
// that ends before the response, resumption with Last-Event-ID (2025-11-25
// polling) and its retry limit, a response stream left open, the standalone
// GET stream (405, reopening), cancellation; the legacy HTTP+SSE transport (endpoint event, POSTs, pushed
// messages, the stream ending); the message decoder (batches, malformed
// input).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/components/tool/mcp/transports.dart';

import '../../../support/fake_mcp_server.dart';

FakeMcpServer _server() => FakeMcpServer(
      tools: [
        FakeTool.text('greet', (a) => 'Hi ${a['name']}'),
        FakeTool(
          name: 'chatty',
          handler: (arguments, ctx) {
            ctx.notify('notifications/message', {'data': 'working'});
            return {
              'content': [
                {'type': 'text', 'text': 'done'},
              ],
            };
          },
        ),
      ],
    );

/// Waits (at most about a second, in 5 ms steps) until [condition] holds.
Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

void main() {
  group('decodeMcpMessages', () {
    test('one object, a batch, and malformed input', () {
      expect(decodeMcpMessages('{"jsonrpc":"2.0","method":"a"}'), [
        {'jsonrpc': '2.0', 'method': 'a'},
      ]);
      expect(
        decodeMcpMessages('[{"id":1,"result":{}},{"id":2,"result":{}}, 3]'),
        [
          {'id': 1, 'result': <String, Object?>{}},
          {'id': 2, 'result': <String, Object?>{}},
        ],
      );
      expect(decodeMcpMessages('server started on port 3000'), isEmpty);
      expect(decodeMcpMessages('"just a string"'), isEmpty);
    });
  });

  group('StreamableHttpTransport', () {
    late FakeMcpHttpServer http;

    tearDown(() => http.close());

    test('JSON responses, session id, protocol version and custom headers',
        () async {
      http = await FakeMcpHttpServer.start(_server());
      final transport = StreamableHttpTransport(
        http.mcpUrl,
        headers: const {'Authorization': 'Bearer test-key'},
      );
      final client = await McpClient.connect(transport);
      expect(transport.sessionId, 'session-1');

      final result = await client.callTool(
        'greet',
        arguments: {'name': 'eino'},
        headers: {'X-Call': 'c1'},
      );
      expect(result.content, [const McpTextContent('Hi eino')]);

      final posts = http.requestsOf('POST', '/mcp');
      expect(posts.map((r) => r.json!['method']).toList(),
          ['initialize', 'notifications/initialized', 'tools/call']);
      for (final post in posts) {
        expect(post.headers['authorization'], 'Bearer test-key');
        expect(post.headers['accept'], 'application/json, text/event-stream');
        expect(post.headers['content-type'], startsWith('application/json'));
      }
      expect(posts[0].headers.containsKey('mcp-session-id'), isFalse);
      expect(posts[0].headers.containsKey('mcp-protocol-version'), isFalse);
      expect(posts[1].headers['mcp-session-id'], 'session-1');
      expect(posts[1].headers['mcp-protocol-version'], mcpLatestProtocolVersion);
      expect(posts[2].headers['mcp-session-id'], 'session-1');
      expect(posts[2].headers['x-call'], 'c1');
      expect(posts[1].headers.containsKey('x-call'), isFalse);

      await client.close();
      final delete = http.requestsOf('DELETE').single;
      expect(delete.headers['mcp-session-id'], 'session-1');
      expect(delete.headers['authorization'], 'Bearer test-key');
      expect(http.liveSessions, isEmpty);
    });

    test('event-stream responses deliver messages sent before the response',
        () async {
      http = await FakeMcpHttpServer.start(_server(), mode: FakeResponseMode.sse);
      final notifications = <String>[];
      final client = await McpClient.connect(
        StreamableHttpTransport(http.mcpUrl),
        onNotification: (method, params) =>
            notifications.add('$method ${params?['data']}'),
      );
      final result = await client.callTool('chatty');
      expect(result.content, [const McpTextContent('done')]);
      expect(notifications, ['notifications/message working']);
      final tools = await client.listTools();
      expect(tools.tools.map((t) => t.name), ['greet', 'chatty']);
      await client.close();
    });

    test('HTTP 404 means the session is gone: McpConnectionException with '
        'sessionMissing, and no DELETE on close', () async {
      http = await FakeMcpHttpServer.start(_server());
      final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));
      http.dropSessions();
      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpConnectionException>()
              .having((e) => e.sessionMissing, 'sessionMissing', isTrue),
        ),
      );
      expect(client.isClosed, isTrue);
      await client.close();
      expect(http.requestsOf('DELETE'), isEmpty);
    });

    test('another HTTP error breaks the connection with the status and body',
        () async {
      http = await FakeMcpHttpServer.start(_server());
      final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));
      http.postStatus = 500;
      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpConnectionException>()
              .having((e) => e.message, 'message', contains('HTTP 500: boom'))
              .having((e) => e.sessionMissing, 'sessionMissing', isFalse),
        ),
      );
      expect(client.isClosed, isTrue);
      await client.close();
    });

    test('an unsupported content type breaks the connection', () async {
      http = await FakeMcpHttpServer.start(_server());
      final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));
      http.postContentType = 'text/html';
      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpConnectionException>().having(
            (e) => e.message,
            'message',
            contains('unsupported content type "text/html"'),
          ),
        ),
      );
      await client.close();
    });

    test('a JSON body without the answer breaks the connection', () async {
      http = await FakeMcpHttpServer.start(_server());
      final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));
      http.postContentType = 'application/json';
      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpConnectionException>().having(
            (e) => e.message,
            'message',
            contains('carried no answer'),
          ),
        ),
      );
      await client.close();
    });

    test('an event stream that ends before the response breaks the connection',
        () async {
      http = await FakeMcpHttpServer.start(_server(), mode: FakeResponseMode.sse);
      final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));
      http.dropSseResponse = true;
      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpConnectionException>().having(
            (e) => e.message,
            'message',
            contains('ended before the response'),
          ),
        ),
      );
      await client.close();
    });

    test('a stream closed after its priming event is resumed with '
        'Last-Event-ID (2025-11-25 polling)', () async {
      http = await FakeMcpHttpServer.start(_server(), mode: FakeResponseMode.sse)
        ..polling = true;
      final client = await McpClient.connect(
        StreamableHttpTransport(
          http.mcpUrl,
          openStandaloneStream: false,
          reconnectDelay: const Duration(milliseconds: 1),
        ),
      );
      final result = await client.callTool('greet', arguments: {'name': 'poll'});
      expect(result.content, [const McpTextContent('Hi poll')]);
      final resumes = http
          .requestsOf('GET', '/mcp')
          .where((r) => r.headers.containsKey('last-event-id'))
          .toList();
      expect(resumes, hasLength(2), reason: 'initialize and tools/call');
      expect(resumes.last.headers['last-event-id'], startsWith('ev-'));
      expect(resumes.last.headers['mcp-session-id'], 'session-1');
      expect(resumes.last.headers['accept'], 'text/event-stream');
      await client.close();
    });

    test('a resumption that never brings the response gives up after '
        'maxRetries', () async {
      http = await FakeMcpHttpServer.start(_server(), mode: FakeResponseMode.sse);
      final client = await McpClient.connect(
        StreamableHttpTransport(
          http.mcpUrl,
          openStandaloneStream: false,
          maxRetries: 2,
          reconnectDelay: const Duration(milliseconds: 1),
        ),
      );
      http
        ..polling = true
        ..pollingDropReplies = true;
      await expectLater(
        client.listTools(),
        throwsA(
          isA<McpConnectionException>().having(
            (e) => e.message,
            'message',
            contains('ended before the response'),
          ),
        ),
      );
      expect(
        http
            .requestsOf('GET', '/mcp')
            .where((r) => r.headers.containsKey('last-event-id')),
        hasLength(2),
      );
      await client.close();
    });

    test('a response stream the server keeps open does not hold send',
        () async {
      http = await FakeMcpHttpServer.start(_server(), mode: FakeResponseMode.sse)
        ..keepSseOpen = true;
      final transport =
          StreamableHttpTransport(http.mcpUrl, openStandaloneStream: false);
      final received = <Map<String, Object?>>[];
      await transport.start(onMessage: received.add, onClose: (_) {});
      await transport.send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18'},
      });
      expect(received.single['id'], 1);
      expect(received.single.containsKey('result'), isTrue);
      await transport.close();
    });

    test('the standalone stream is reopened when the server ends it',
        () async {
      http = await FakeMcpHttpServer.start(_server(), standaloneGet: true);
      final notifications = <String>[];
      final client = await McpClient.connect(
        StreamableHttpTransport(
          http.mcpUrl,
          reconnectDelay: const Duration(milliseconds: 1),
        ),
        onNotification: (method, _) => notifications.add(method),
      );
      await _eventually(() => http.openStandaloneStreams == 1);
      await http.endStandaloneStreams();
      await _eventually(
        () =>
            http.requestsOf('GET', '/mcp').length == 2 &&
            http.openStandaloneStreams == 1,
      );
      await http.pushStandalone({'jsonrpc': '2.0', 'method': 'after/reopen'});
      await _eventually(() => notifications.isNotEmpty);
      expect(notifications, ['after/reopen']);
      expect(client.isClosed, isFalse);
      await client.close();
    });

    test('the standalone GET stream delivers messages the server sends on its '
        'own', () async {
      http = await FakeMcpHttpServer.start(_server(), standaloneGet: true);
      final notifications = <String>[];
      final client = await McpClient.connect(
        StreamableHttpTransport(http.mcpUrl),
        onNotification: (method, _) => notifications.add(method),
      );
      await _eventually(() => http.openStandaloneStreams == 1);
      final get = http.requestsOf('GET', '/mcp').single;
      expect(get.headers['accept'], 'text/event-stream');
      expect(get.headers['mcp-session-id'], 'session-1');

      await http.pushStandalone({
        'jsonrpc': '2.0',
        'method': 'notifications/tools/list_changed',
      });
      await _eventually(() => notifications.isNotEmpty);
      expect(notifications, ['notifications/tools/list_changed']);
      await client.close();
    });

    test('a server without the standalone stream (405) is fine', () async {
      http = await FakeMcpHttpServer.start(_server());
      final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));
      await _eventually(() => http.requestsOf('GET', '/mcp').isNotEmpty);
      expect((await client.listTools()).tools, hasLength(2));
      await client.close();
    });

    test('no standalone stream when it is turned off; no session, no DELETE',
        () async {
      http = await FakeMcpHttpServer.start(_server(), sessions: false);
      final transport =
          StreamableHttpTransport(http.mcpUrl, openStandaloneStream: false);
      final client = await McpClient.connect(transport);
      await client.ping();
      expect(transport.sessionId, isNull);
      expect(http.requestsOf('POST').every(
          (r) => !r.headers.containsKey('mcp-session-id')), isTrue);
      await client.close();
      expect(http.requestsOf('GET'), isEmpty);
      expect(http.requestsOf('DELETE'), isEmpty);
    });

    test('cancelling a call abandons its response and tells the server',
        () async {
      final release = Completer<void>();
      final server = _server()
        ..tools.add(
          FakeTool(
            name: 'slow',
            handler: (_, __) async {
              await release.future;
              return {'content': <Object?>[]};
            },
          ),
        );
      http = await FakeMcpHttpServer.start(server, mode: FakeResponseMode.sse);
      final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));
      final token = CancelToken();
      final call = client.callTool('slow', cancelToken: token);
      await _eventually(() => server.receivedOf('tools/call').isNotEmpty);
      token.cancel('stop');
      await expectLater(call, throwsA(isA<CancelledException>()));
      await _eventually(
        () => server.receivedOf('notifications/cancelled').isNotEmpty,
      );
      release.complete();
      expect((await client.callTool('greet', arguments: {'name': 'x'})).content,
          [const McpTextContent('Hi x')]);
      await client.close();
    });

    test('send after close fails with McpConnectionException', () async {
      http = await FakeMcpHttpServer.start(_server());
      final transport = StreamableHttpTransport(http.mcpUrl);
      await transport.start(onMessage: (_) {}, onClose: (_) {});
      await transport.close();
      await transport.close();
      await expectLater(
        transport.send({'jsonrpc': '2.0', 'method': 'x'}),
        throwsA(isA<McpConnectionException>()),
      );
    });
  });

  group('SseTransport', () {
    late FakeMcpHttpServer http;

    tearDown(() => http.close());

    test('waits for the endpoint event and POSTs to it', () async {
      http = await FakeMcpHttpServer.start(_server());
      final transport = SseTransport(
        http.sseUrl,
        headers: const {'Authorization': 'token'},
      );
      final notifications = <String>[];
      final client = await McpClient.connect(
        transport,
        onNotification: (method, _) => notifications.add(method),
      );
      expect(transport.endpoint, http.sseUrl.resolve('/messages?sessionId=legacy-1'));

      final result = await client.callTool('chatty');
      expect(result.content, [const McpTextContent('done')]);
      expect(notifications, ['notifications/message']);

      final get = http.requestsOf('GET', '/sse').single;
      expect(get.headers['accept'], 'text/event-stream');
      expect(get.headers['authorization'], 'token');
      final posts = http.requestsOf('POST', '/messages');
      expect(posts.map((r) => r.json!['method']).toList(),
          ['initialize', 'notifications/initialized', 'tools/call']);
      expect(posts.every((r) => r.headers['authorization'] == 'token'), isTrue);

      await http.pushLegacy({'jsonrpc': '2.0', 'method': 'notifications/ping-ish'});
      await _eventually(() => notifications.length == 2);
      await client.close();
    });

    test('a first event other than endpoint fails the start', () async {
      http = await FakeMcpHttpServer.start(_server())
        ..legacyFirstEvent = 'event: message\ndata: {}\n\n';
      await expectLater(
        McpClient.connect(SseTransport(http.sseUrl)),
        throwsA(
          isA<McpConnectionException>().having(
            (e) => e.message,
            'message',
            contains('missing endpoint'),
          ),
        ),
      );
    });

    test('an event stream that cannot be opened fails the start', () async {
      http = await FakeMcpHttpServer.start(_server());
      await expectLater(
        McpClient.connect(SseTransport(http.sseUrl.resolve('/nowhere'))),
        throwsA(
          isA<McpConnectionException>()
              .having((e) => e.message, 'message', contains('HTTP 404')),
        ),
      );
    });

    test('when the event stream ends, the client is finished', () async {
      http = await FakeMcpHttpServer.start(_server());
      final client = await McpClient.connect(SseTransport(http.sseUrl));
      await http.endLegacyStreams();
      await _eventually(() => client.isClosed);
      expect(client.isClosed, isTrue);
      await expectLater(client.listTools(), throwsA(isA<McpConnectionException>()));
      await client.close();
    });
  });
}
