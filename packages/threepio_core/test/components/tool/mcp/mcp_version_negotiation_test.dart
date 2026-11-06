// Coordinator decision 1 after P11: MCP protocol version negotiation.
//
// The client asks for 2025-11-25 and, as the specification's lifecycle
// requires ("If the server supports the requested protocol version, it MUST
// respond with the same version. Otherwise, the server MUST respond with
// another protocol version it supports"; the client disconnects when it
// does not support the answer), accepts every revision it implements:
// 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05. Each revision is
// answered by a fake server, in memory and over the Streamable HTTP
// transport, and then used for real requests. Written for the port (the Go
// SDKs' negotiation tests are not part of eino-ext).
import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_session.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_toolkit.dart';
import 'package:threepio_core/src/components/tool/mcp/transports.dart';
import 'package:threepio_core/src/core/run_context.dart';

import '../../../support/fake_mcp_server.dart';

FakeMcpServer _server(String answer) => FakeMcpServer(
      tools: [
        FakeTool.text(
          'greet',
          (arguments) => 'Hi ${arguments['name']}',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
            'required': ['name'],
          },
        ),
      ],
    )..answerVersion = answer;

void main() {
  test('the client implements the revisions the coordinator named', () {
    expect(mcpLatestProtocolVersion, '2025-11-25');
    expect(
      mcpSupportedProtocolVersions,
      containsAll(['2025-11-25', '2025-06-18', '2025-03-26']),
    );
    expect(mcpSupportedProtocolVersions.first, mcpLatestProtocolVersion);
  });

  for (final version in mcpSupportedProtocolVersions) {
    group('a server answering $version', () {
      test('in memory: accepted, recorded on the transport, and used', () async {
        final server = _server(version);
        final transport = FakeInMemoryTransport(server);
        final client = await McpClient.connect(transport);
        addTearDown(client.close);

        // The client still asks for the newest revision it speaks.
        expect(
          server.receivedOf('initialize').single.params['protocolVersion'],
          mcpLatestProtocolVersion,
        );
        expect(client.initializeResult!.protocolVersion, version);
        expect(transport.protocolVersion, version);
        expect(server.receivedOf('notifications/initialized'), hasLength(1));

        final tools = await client.listTools();
        expect(tools.tools.map((t) => t.name), ['greet']);
        final result = await client.callTool('greet', arguments: {'name': 'v'});
        expect(result.content, [const McpTextContent('Hi v')]);
      });

      test('over Streamable HTTP: later requests carry the negotiated '
          'MCP-Protocol-Version', () async {
        final http = await FakeMcpHttpServer.start(_server(version));
        addTearDown(http.close);
        final client = await McpClient.connect(StreamableHttpTransport(http.mcpUrl));

        expect(client.initializeResult!.protocolVersion, version);
        final result = await client.callTool('greet', arguments: {'name': 'h'});
        expect(result.content, [const McpTextContent('Hi h')]);
        await client.close();

        final posts = http.requestsOf('POST', '/mcp');
        expect(
          posts.map((r) => r.json!['method']).toList(),
          ['initialize', 'notifications/initialized', 'tools/call'],
        );
        expect(posts.first.headers.containsKey('mcp-protocol-version'), isFalse);
        for (final post in posts.skip(1)) {
          expect(post.headers['mcp-protocol-version'], version);
        }
        final delete = http.requestsOf('DELETE').single;
        expect(delete.headers['mcp-protocol-version'], version);
      });

      test('the toolkit lists and calls tools on that server', () async {
        final client =
            await McpClient.connect(FakeInMemoryTransport(_server(version)));
        addTearDown(client.close);
        final tools = await McpToolkit(client).getTools(RunContext.background());
        expect(tools, hasLength(1));
        expect(
          await tools.single.invokableRun(
            RunContext.background(),
            '{"name":"kit"}',
          ),
          // The text form is the result as JSON, as in Go.
          '{"content":[{"type":"text","text":"Hi kit"}]}',
        );
      });
    });
  }

  group('revisions the client does not implement', () {
    for (final version in ['2024-10-07', '2025-01-01', '2026-06-30', '']) {
      test('"$version" fails the handshake and closes the connection',
          () async {
        final server = _server(version);
        final transport = FakeInMemoryTransport(server);
        await expectLater(
          McpClient.connect(transport),
          throwsA(
            isA<McpException>().having(
              (e) => e.message,
              'message',
              'unsupported protocol version: "$version"',
            ),
          ),
        );
        expect(transport.closed, isTrue);
        expect(transport.protocolVersion, isNull);
        expect(server.receivedOf('notifications/initialized'), isEmpty);
        expect(server.receivedOf('tools/list'), isEmpty);
      });
    }
  });

  test('a client asking for an older revision gets it from a server that '
      'supports it', () async {
    final server = FakeMcpServer(); // answers the asked revision when known
    final transport = FakeInMemoryTransport(server);
    final client = await McpClient.connect(
      transport,
      protocolVersion: '2025-03-26',
    );
    addTearDown(client.close);
    expect(
      server.receivedOf('initialize').single.params['protocolVersion'],
      '2025-03-26',
    );
    expect(client.initializeResult!.protocolVersion, '2025-03-26');
    expect(transport.protocolVersion, '2025-03-26');
  });

  test('a session over Streamable HTTP works with a server answering '
      '2025-03-26, and over the legacy SSE transport with 2024-11-05',
      () async {
    final streamable = await FakeMcpHttpServer.start(_server('2025-03-26'));
    addTearDown(streamable.close);
    final session = await McpSession.connect(
      RunContext.background(),
      McpServerConfig(
        name: 'streamable',
        transport: McpTransportConfig(
          type: McpTransportType.streamableHttp,
          url: streamable.mcpUrl.toString(),
        ),
      ),
    );
    final result = await session.callTool('greet', arguments: {'name': 's'});
    expect(result.content, [const McpTextContent('Hi s')]);
    await session.close();
    expect(
      streamable.requestsOf('POST', '/mcp').last.headers['mcp-protocol-version'],
      '2025-03-26',
    );

    final legacy = await FakeMcpHttpServer.start(_server('2024-11-05'));
    addTearDown(legacy.close);
    final sseSession = await McpSession.connect(
      RunContext.background(),
      McpServerConfig(
        name: 'legacy',
        transport: McpTransportConfig(
          type: McpTransportType.sse,
          url: legacy.sseUrl.toString(),
        ),
      ),
    );
    final legacyResult =
        await sseSession.callTool('greet', arguments: {'name': 'l'});
    expect(legacyResult.content, [const McpTextContent('Hi l')]);
    await sseSession.close();
  });
}
