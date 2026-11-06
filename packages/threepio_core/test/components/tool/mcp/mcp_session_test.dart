// Ports eino-ext components/tool/mcp/officialmcp/session:
//   session_test.go    TestConnectSSEAndCloseIdempotent,
//                      TestConnectStreamableHTTPWithHeaders,
//                      TestHTTPClientAndHeadersCompose (through a session:
//                      the injected client sees the config headers),
//                      TestNewTransportStdioConfig (the injected stdio
//                      factory receives the config),
//                      TestNewTransportRejectsEmptyStdioCommand,
//                      TestConnectAndReconnectViaFactory,
//                      TestConnectFactoryError, TestConnectRejectsInvalidURL,
//                      TestConnectUnsupportedTransport.
//   reconnect_test.go  TestSessionImplementsClientSession,
//                      TestSessionReconnectsAfterServerRestart,
//                      TestReconnectFailureIsConnectionError (the unreachable
//                      endpoint is a factory that fails instead of a dial to
//                      127.0.0.1:1), TestReconnectOnlyOncePerStaleSession.
// Not ported: TestConnectFactoryRejectsNilTransport (the Dart factory cannot
// return null) and TestSessionCloseNil (no nil receivers in Dart).
//
// Written for the port: transparent reconnect inside a call, no reconnect
// for protocol errors or failed tools, the prompt and ping calls, startup
// failures of the handshake, a stdio config without a factory, the toolkit
// over a session.
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_session.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_toolkit.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

import '../../../support/fake_mcp_server.dart';

final _ctx = RunContext.background();

FakeTool _add() => FakeTool(
      name: 'add',
      description: 'add two numbers',
      handler: (a, _) => {
        'content': [
          {
            'type': 'text',
            'text': '${(a['x']! as num) + (a['y']! as num)}',
          },
        ],
      },
    );

FakeMcpServer _server() => FakeMcpServer(
      tools: [
        _add(),
        FakeTool(
          name: 'fail',
          handler: (_, __) => {
            'content': [
              {'type': 'text', 'text': 'nope'},
            ],
            'isError': true,
          },
        ),
      ],
      prompts: [
        FakePrompt(
          name: 'p',
          messages: (_) => [
            {
              'role': 'user',
              'content': {'type': 'text', 'text': 'hi'},
            },
          ],
        ),
      ],
    );

String _text(McpCallToolResult result) =>
    (result.content.single as McpTextContent).text;

final class _HeaderCheckingClient extends http.BaseClient {
  _HeaderCheckingClient(this._inner);

  final http.Client _inner;
  final List<String?> seenAuthorization = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    seenAuthorization.add(request.headers['Authorization']);
    request.headers['X-Base-Transport'] = 'base';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// A factory that hands out in-memory transports to [server] and counts
/// its calls; [failFrom] makes the calls from that number on fail.
final class _Factory {
  _Factory(this.server, {this.failFrom});

  final FakeMcpServer server;
  final int? failFrom;
  final List<FakeInMemoryTransport> transports = [];
  int calls = 0;

  McpTransportConfig get config => McpTransportConfig(factory: create);

  FutureOr<FakeInMemoryTransport> create(RunContext ctx) {
    calls++;
    final failFrom = this.failFrom;
    if (failFrom != null && calls >= failFrom) {
      throw Exception('connection refused');
    }
    final transport = FakeInMemoryTransport(server);
    transports.add(transport);
    return transport;
  }
}

void main() {
  group('session_test.go', () {
    late FakeMcpHttpServer httpServer;

    tearDown(() => httpServer.close());

    test('TestConnectSSEAndCloseIdempotent', () async {
      httpServer = await FakeMcpHttpServer.start(_server());
      final managed = await McpSession.connect(
        _ctx,
        McpServerConfig(
          name: 'test',
          transport: McpTransportConfig(
            type: McpTransportType.sse,
            url: httpServer.sseUrl.toString(),
          ),
        ),
      );
      expect(managed.name, 'test');
      final result =
          await managed.callTool('add', arguments: {'x': 1, 'y': 2});
      expect(_text(result), '3');
      await managed.close();
      await expectLater(
        managed.callTool('add', arguments: {'x': 1, 'y': 2}),
        throwsA(isA<McpSessionClosedException>()),
      );
      await managed.close();
    });

    test('TestConnectStreamableHTTPWithHeaders', () async {
      httpServer = await FakeMcpHttpServer.start(_server());
      final managed = await McpSession.connect(
        _ctx,
        McpServerConfig(
          name: 'test',
          transport: McpTransportConfig(
            type: McpTransportType.streamableHttp,
            url: httpServer.mcpUrl.toString(),
            headers: const {'Authorization': 'token'},
          ),
        ),
      );
      final result =
          await managed.callTool('add', arguments: {'x': 2, 'y': 3});
      expect(_text(result), '5');
      await managed.close();
      expect(httpServer.requests, isNotEmpty);
      for (final request in httpServer.requests) {
        expect(request.headers['authorization'], 'token',
            reason: '${request.method} ${request.path}');
      }
    });

    test('TestHTTPClientAndHeadersCompose', () async {
      httpServer = await FakeMcpHttpServer.start(_server());
      final client = _HeaderCheckingClient(http.Client());
      addTearDown(client.close);
      final managed = await McpSession.connect(
        _ctx,
        McpServerConfig(
          name: 'test',
          transport: McpTransportConfig(
            type: McpTransportType.streamableHttp,
            url: httpServer.mcpUrl.toString(),
            headers: const {'Authorization': 'token'},
            httpClient: client,
          ),
        ),
      );
      await managed.ping();
      await managed.close();
      expect(client.seenAuthorization, isNotEmpty);
      expect(client.seenAuthorization.toSet(), {'token'});
      for (final request in httpServer.requests) {
        expect(request.headers['authorization'], 'token');
        expect(request.headers['x-base-transport'], 'base');
      }
    });
  });

  test('TestNewTransportStdioConfig', () async {
    McpTransportConfig? seen;
    final managed = await McpSession.connect(
      _ctx,
      const McpServerConfig(
        name: 'local',
        transport: McpTransportConfig(
          type: McpTransportType.stdio,
          command: 'echo',
          args: ['hello'],
          env: {'MCP_TEST_ENV': 'value'},
          cwd: '/tmp',
        ),
      ),
      stdioFactory: (config) {
        seen = config;
        return FakeInMemoryTransport(_server());
      },
    );
    expect(seen!.command, 'echo');
    expect(seen!.args, ['hello']);
    expect(seen!.cwd, '/tmp');
    expect(seen!.env, containsPair('MCP_TEST_ENV', 'value'));
    await managed.close();
  });

  test('TestNewTransportRejectsEmptyStdioCommand', () async {
    await expectLater(
      McpSession.connect(
        _ctx,
        const McpServerConfig(
          name: 'local',
          transport: McpTransportConfig(type: McpTransportType.stdio),
        ),
        stdioFactory: (_) => throw StateError('not reached'),
      ),
      throwsA(
        isA<McpStartupException>()
            .having((e) => e.message, 'message', contains('stdio command is empty'))
            .having((e) => e.transportType, 'transportType', 'stdio'),
      ),
    );
  });

  test('a stdio config without a factory names the one to pass', () async {
    await expectLater(
      McpSession.connect(
        _ctx,
        const McpServerConfig(
          name: 'local',
          transport: McpTransportConfig(
            type: McpTransportType.stdio,
            command: 'server',
          ),
        ),
      ),
      throwsA(
        isA<McpStartupException>().having(
          (e) => e.message,
          'message',
          contains('StdioTransport.fromConfig'),
        ),
      ),
    );
  });

  test('TestConnectAndReconnectViaFactory', () async {
    const key = ContextKey<String>('test');
    final ctx = RunContext.background().withValue(key, 'factory-context');
    final server = _server();
    var calls = 0;
    final managed = await McpSession.connect(
      ctx,
      McpServerConfig(
        name: 'test',
        transport: McpTransportConfig(
          type: McpTransportType.sse,
          factory: (factoryCtx) {
            expect(factoryCtx.value(key), 'factory-context');
            calls++;
            return FakeInMemoryTransport(server);
          },
        ),
      ),
    );
    addTearDown(managed.close);
    expect(calls, 1);

    final stale = managed.currentClient!;
    final fresh = await managed.reconnect(ctx, stale);
    expect(fresh, isNot(same(stale)));
    expect(calls, 2);
    expect(stale.isClosed, isTrue, reason: 'the stale client is closed');
    expect(managed.currentClient, same(fresh));
  });

  test('TestConnectFactoryError', () async {
    final factoryError = Exception('factory failed');
    await expectLater(
      McpSession.connect(
        _ctx,
        McpServerConfig(
          name: 'bad',
          transport: McpTransportConfig(factory: (_) => throw factoryError),
        ),
      ),
      throwsA(
        isA<McpStartupException>()
            .having((e) => e.cause, 'cause', same(factoryError))
            .having((e) => e.serverName, 'serverName', 'bad'),
      ),
    );
  });

  test('TestConnectRejectsInvalidURL', () async {
    await expectLater(
      McpSession.connect(
        _ctx,
        const McpServerConfig(
          name: 'bad',
          transport: McpTransportConfig(
            type: McpTransportType.sse,
            url: '/relative',
          ),
        ),
      ),
      throwsA(
        isA<McpStartupException>().having(
          (e) => e.message,
          'message',
          contains('transport URL must be absolute'),
        ),
      ),
    );
    await expectLater(
      McpSession.connect(
        _ctx,
        const McpServerConfig(
          name: 'bad',
          transport: McpTransportConfig(type: McpTransportType.streamableHttp),
        ),
      ),
      throwsA(
        isA<McpStartupException>()
            .having((e) => e.message, 'message', contains('transport URL is empty')),
      ),
    );
  });

  test('TestConnectUnsupportedTransport', () async {
    Object? error;
    try {
      await McpSession.connect(
        _ctx,
        const McpServerConfig(name: 'bad', transport: McpTransportConfig()),
      );
    } on Object catch (e) {
      error = e;
    }
    expect(error, isA<McpStartupException>());
    expect(
      McpToolkitException.isKind(
        (error! as McpStartupException).cause,
        McpErrorKind.unsupportedTransport,
      ),
      isTrue,
    );
  });

  test('a handshake that fails is a startup error', () async {
    final server = _server()..answerVersion = '1999-01-01';
    await expectLater(
      McpSession.connect(
        _ctx,
        McpServerConfig(name: 'old', transport: _Factory(server).config),
      ),
      throwsA(
        isA<McpStartupException>()
            .having((e) => e.cause, 'cause', isA<McpException>())
            .having((e) => e.message, 'message',
                contains('unsupported protocol version')),
      ),
    );
  });

  test('the client introduces itself as configured', () async {
    final server = _server();
    final managed = await McpSession.connect(
      _ctx,
      McpServerConfig(
        name: 's',
        transport: _Factory(server).config,
        clientInfo: const McpImplementation(name: 'app', version: '2'),
      ),
    );
    await managed.close();
    final other = await McpSession.connect(
      _ctx,
      McpServerConfig(name: 's', transport: _Factory(server).config),
    );
    await other.close();
    expect(
      server.receivedOf('initialize').map((r) => r.params['clientInfo']),
      [
        {'name': 'app', 'version': '2'},
        {'name': 'eino-officialmcp', 'version': 'v0.0.0'},
      ],
    );
  });

  group('reconnect_test.go', () {
    test('TestSessionImplementsClientSession', () async {
      final managed = await McpSession.connect(
        _ctx,
        McpServerConfig(name: 's', transport: _Factory(_server()).config),
      );
      final McpClientSession asToolSession = managed;
      final McpPromptClient asPromptClient = managed;
      expect(asToolSession, same(asPromptClient));
      await managed.close();
    });

    test('TestSessionReconnectsAfterServerRestart', () async {
      final httpServer = await FakeMcpHttpServer.start(_server());
      addTearDown(httpServer.close);
      final rs = await McpSession.connect(
        _ctx,
        McpServerConfig(
          name: 'test',
          transport: McpTransportConfig(
            type: McpTransportType.streamableHttp,
            url: httpServer.mcpUrl.toString(),
          ),
        ),
      );
      addTearDown(rs.close);

      expect(_text(await rs.callTool('add', arguments: {'x': 1, 'y': 2})), '3');
      final sessionBefore = rs.currentClient;

      // The server forgets the session, as a restarted one would.
      httpServer.dropSessions();

      expect(_text(await rs.callTool('add', arguments: {'x': 4, 'y': 5})), '9');
      final sessionAfter = rs.currentClient;
      expect(sessionAfter, isNot(same(sessionBefore)),
          reason: 'expected a new underlying client after reconnect');
      expect(httpServer.requestsOf('POST', '/mcp').where(
            (r) => r.json!['method'] == 'initialize',
          ), hasLength(2));
    });

    test('TestReconnectFailureIsConnectionError', () async {
      final factory = _Factory(_server(), failFrom: 2);
      final s = await McpSession.connect(
        _ctx,
        McpServerConfig(name: 'test', transport: factory.config),
      );
      addTearDown(s.close);
      final sentinel = s.currentClient;

      Object? error;
      try {
        await s.reconnect(_ctx, sentinel);
      } on Object catch (e) {
        error = e;
      }
      expect(isMcpConnectionError(error), isTrue,
          reason: 'reconnect failure should be a connection error');
      expect(ThreepioException.findCause<McpStartupException>(error), isNotNull,
          reason: 'StartupError should be preserved as the cause');
      expect(s.currentClient, same(sentinel),
          reason: 'a failed reconnect leaves the stale client in place');
    });

    test('TestReconnectOnlyOncePerStaleSession', () async {
      final factory = _Factory(_server());
      final rs = await McpSession.connect(
        _ctx,
        McpServerConfig(name: 'test', transport: factory.config),
      );
      addTearDown(rs.close);
      final stale = rs.currentClient;

      final results = await Future.wait([
        for (var i = 0; i < 8; i++) rs.reconnect(_ctx, stale),
      ]);
      final first = results.first;
      expect(results.where((c) => !identical(c, first)), isEmpty,
          reason: 'all concurrent reconnects should yield the same client');
      expect(first, isNot(same(stale)));
      expect(factory.calls, 2);
    });
  });

  group('calls', () {
    test('a close during the reconnect closes the fresh client', () async {
      final factory = _Factory(_server());
      final session = await McpSession.connect(
        _ctx,
        McpServerConfig(name: 'test', transport: factory.config),
      );
      final gate = Completer<void>();
      factory.transports.single.closeGate = gate.future;
      final stale = session.currentClient;
      final reconnecting = session.reconnect(_ctx, stale);
      await _eventuallyTrue(() => factory.transports.length == 2);
      await pumpEventQueue();
      final closing = session.close();
      gate.complete();
      await closing;
      await expectLater(
        reconnecting,
        throwsA(isA<McpSessionClosedException>()),
      );
      expect(factory.transports.last.closed, isTrue,
          reason: 'the fresh client does not outlive the session');
    });

    test('a cancelled connect throws CancelledException', () async {
      final token = CancelToken()..cancel('stop');
      await expectLater(
        McpSession.connect(
          RunContext.background(cancelToken: token),
          McpServerConfig(name: 'test', transport: _Factory(_server()).config),
        ),
        throwsA(isA<CancelledException>()),
      );
    });

    test('a broken connection is rebuilt inside the call', () async {
      final factory = _Factory(_server());
      final session = await McpSession.connect(
        _ctx,
        McpServerConfig(name: 'test', transport: factory.config),
      );
      addTearDown(session.close);
      factory.transports.single.breakConnection();
      await pumpEventQueue();

      expect(_text(await session.callTool('add', arguments: {'x': 1, 'y': 1})), '2');
      expect(factory.calls, 2);

      factory.transports.last.breakConnection();
      await pumpEventQueue();
      expect((await session.listTools()).tools, hasLength(2));
      factory.transports.last.breakConnection();
      await pumpEventQueue();
      expect((await session.getPrompt('p')).messages, hasLength(1));
      factory.transports.last.breakConnection();
      await pumpEventQueue();
      expect((await session.listPrompts()).prompts.single.name, 'p');
      factory.transports.last.breakConnection();
      await pumpEventQueue();
      await session.ping();
      expect(factory.calls, 6);
    });

    test('a rejected call or a failed tool does not reconnect', () async {
      final factory = _Factory(_server());
      final session = await McpSession.connect(
        _ctx,
        McpServerConfig(name: 'test', transport: factory.config),
      );
      addTearDown(session.close);
      await expectLater(
        session.callTool('missing'),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
      final failed = await session.callTool('fail');
      expect(failed.isError, isTrue);
      expect(factory.calls, 1);
    });

    test('the toolkit works over a session across a restart', () async {
      final httpServer =
          await FakeMcpHttpServer.start(_server(), mode: FakeResponseMode.sse);
      addTearDown(httpServer.close);
      final session = await McpSession.connect(
        _ctx,
        McpServerConfig(
          name: 'calc',
          transport: McpTransportConfig(
            type: McpTransportType.streamableHttp,
            url: httpServer.mcpUrl.toString(),
          ),
        ),
      );
      addTearDown(session.close);
      final tools = await McpToolkit(session, serverName: 'calc')
          .getTools(_ctx, toolNameList: ['add']);
      httpServer.dropSessions();
      expect(
        await tools.single.invokableRun(_ctx, '{"x": 20, "y": 22}'),
        '{"content":[{"type":"text","text":"42"}]}',
      );
    });
  });
}

Future<void> _eventuallyTrue(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}
