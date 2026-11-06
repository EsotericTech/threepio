// Tests of the stdio transport of MCP (lib/src/components/tool/mcp/
// stdio_transport.dart), written for the port. eino-ext uses go-sdk's
// `CommandTransport`; its only stdio test, officialmcp/session's
// TestNewTransportStdioConfig, is ported in mcp_session_test.dart.
//
// The transport is tested through its streams constructor against the fake
// server, and with /bin/sh and cat as the subprocess (never dart): cat echoes
// the client's own messages back, which exercises the line framing, the
// answer to server requests and the response path in one go.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_session.dart';
import 'package:threepio_core/src/components/tool/mcp/stdio_transport.dart';

import '../../../support/fake_mcp_server.dart';

/// Connects [server] to a [StdioTransport.fromStreams]: what the client
/// writes is decoded line by line and answered on the client's input.
({StdioTransport transport, StreamController<List<int>> serverOut, List<String> lines})
    _wire(FakeMcpServer server) {
  final serverOut = StreamController<List<int>>();
  final clientOut = StreamController<List<int>>();
  final lines = <String>[];
  void write(Map<String, Object?> message) {
    if (!serverOut.isClosed) {
      serverOut.add(utf8.encode('${jsonEncode(message)}\n'));
    }
  }

  clientOut.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) async {
    lines.add(line);
    final message = jsonDecode(line) as Map<String, Object?>;
    final reply = await server.handle(message, sendToClient: write);
    if (reply != null) write(reply);
  });
  return (
    transport: StdioTransport.fromStreams(
      input: serverOut.stream,
      output: clientOut.sink,
    ),
    serverOut: serverOut,
    lines: lines,
  );
}

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

void main() {
  group('StdioTransport.fromStreams', () {
    test('newline-delimited JSON both ways', () async {
      final server = FakeMcpServer(
        tools: [FakeTool.text('greet', (a) => 'Hi ${a['name']}')],
      );
      final wire = _wire(server);
      final client = await McpClient.connect(wire.transport);
      final result = await client.callTool('greet', arguments: {'name': 'eino'});
      expect(result.content, [const McpTextContent('Hi eino')]);
      expect(wire.lines, hasLength(3));
      for (final line in wire.lines) {
        expect(line.contains('\n'), isFalse);
        expect(jsonDecode(line), isA<Map<String, Object?>>());
      }
      await client.close();
    });

    test('lines that are not JSON are skipped; a batch line is split',
        () async {
      final serverOut = StreamController<List<int>>();
      final clientOut = StreamController<List<int>>();
      final received = <Map<String, Object?>>[];
      final transport =
          StdioTransport.fromStreams(input: serverOut.stream, output: clientOut.sink);
      await transport.start(onMessage: received.add, onClose: (_) {});
      serverOut
        ..add(utf8.encode('server starting...\n'))
        ..add(utf8.encode('[{"jsonrpc":"2.0","method":"a"},'))
        ..add(utf8.encode('{"jsonrpc":"2.0","method":"b"}]\n\n'));
      await _eventually(() => received.length == 2);
      expect(received.map((m) => m['method']), ['a', 'b']);
      await transport.close();
      await serverOut.close();
    });

    test('the end of the input ends the connection', () async {
      final wire = _wire(FakeMcpServer());
      final client = await McpClient.connect(wire.transport);
      await wire.serverOut.close();
      await _eventually(() => client.isClosed);
      await expectLater(client.ping(), throwsA(isA<McpConnectionException>()));
      await client.close();
    });

    test('stderr is logged', () async {
      final serverOut = StreamController<List<int>>();
      final stderr = StreamController<List<int>>();
      final records = <LogRecord>[];
      final logger = Logger('threepio.mcp.stdio');
      final previous = logger.level;
      hierarchicalLoggingEnabled = true;
      logger.level = Level.ALL;
      final subscription = logger.onRecord.listen(records.add);
      final transport = StdioTransport.fromStreams(
        input: serverOut.stream,
        output: StreamController<List<int>>().sink,
        stderr: stderr.stream,
      );
      await transport.start(onMessage: (_) {}, onClose: (_) {});
      stderr.add(utf8.encode('warming up\n'));
      await _eventually(() => records.isNotEmpty);
      expect(records.single.message, '[stdio] warming up');
      await transport.close();
      await subscription.cancel();
      logger.level = previous;
      await serverOut.close();
      await stderr.close();
    });

    test('send after close fails', () async {
      final transport = StdioTransport.fromStreams(
        input: const Stream.empty(),
        output: StreamController<List<int>>().sink,
      );
      await transport.start(onMessage: (_) {}, onClose: (_) {});
      await transport.close();
      await expectLater(
        transport.send({'jsonrpc': '2.0', 'method': 'x'}),
        throwsA(isA<McpConnectionException>()),
      );
    });
  });

  group('StdioTransport with a process', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('threepio_p11_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('cat echoes the request back: the client answers its own "server '
        'request" with method not found, which ends initialize', () async {
      final transport = StdioTransport(command: 'cat');
      final client = McpClient(transport);
      await expectLater(
        client.initialize(),
        throwsA(
          isA<McpException>()
              .having((e) => e.code, 'code', McpException.methodNotFound),
        ),
      );
      expect(client.isClosed, isTrue);
      final process = transport.process!;
      expect(await process.exitCode, isNotNull);
    });

    test('environment and working directory reach the process', () async {
      final notifications = <Map<String, Object?>?>[];
      final transport = StdioTransport(
        command: '/bin/sh',
        args: [
          '-c',
          r'printf "{\"jsonrpc\":\"2.0\",\"method\":\"env\",\"params\":'
              r'{\"value\":\"%s\",\"cwd\":\"%s\"}}\n" "$MCP_TEST_ENV" "$(pwd -P)"; cat',
        ],
        environment: const {'MCP_TEST_ENV': 'value'},
        workingDirectory: temp.path,
        terminateTimeout: const Duration(milliseconds: 20),
      );
      await transport.start(
        onMessage: (m) => notifications.add(m['params'] as Map<String, Object?>?),
        onClose: (_) {},
      );
      await _eventually(() => notifications.isNotEmpty);
      expect(notifications.single!['value'], 'value');
      expect(
        notifications.single!['cwd'],
        temp.resolveSymbolicLinksSync(),
      );
      await transport.close();
    });

    test('stderr of the process is logged and its exit ends the connection',
        () async {
      final records = <LogRecord>[];
      final logger = Logger('threepio.mcp.stdio');
      hierarchicalLoggingEnabled = true;
      final previous = logger.level;
      logger.level = Level.ALL;
      final subscription = logger.onRecord.listen(records.add);
      Object? closedWith;
      final transport = StdioTransport(
        command: '/bin/sh',
        args: ['-c', 'echo oops >&2; exit 3'],
      );
      await transport.start(onMessage: (_) {}, onClose: (e) => closedWith = e);
      await _eventually(() => closedWith != null);
      expect(closedWith, isA<McpConnectionException>());
      await _eventually(() => records.isNotEmpty);
      expect(records.first.message, '[/bin/sh] oops');
      await transport.close();
      await subscription.cancel();
      logger.level = previous;
    });

    test('close terminates a process that ignores its closed stdin', () async {
      final transport = StdioTransport(
        command: '/bin/sh',
        args: ['-c', 'exec sleep 30'],
        terminateTimeout: const Duration(milliseconds: 20),
      );
      await transport.start(onMessage: (_) {}, onClose: (_) {});
      final watch = Stopwatch()..start();
      await transport.close();
      final code = await transport.process!.exitCode;
      expect(code, isNot(0));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('close while the process starts kills it', () async {
      final transport = StdioTransport(command: 'cat');
      final starting = transport.start(onMessage: (_) {}, onClose: (_) {});
      await transport.close();
      await expectLater(starting, throwsA(isA<McpConnectionException>()));
      final process = transport.process;
      if (process != null) expect(await process.exitCode, isNot(0));
    });

    test('a command that does not exist fails to start', () async {
      final transport = StdioTransport(
        command: '${temp.path}/no-such-server',
      );
      await expectLater(
        transport.start(onMessage: (_) {}, onClose: (_) {}),
        throwsA(isA<McpConnectionException>()),
      );
    });

    test('fromConfig maps the session config', () {
      final transport = StdioTransport.fromConfig(
        const McpTransportConfig(
          type: McpTransportType.stdio,
          command: 'echo',
          args: ['hello'],
          env: {'MCP_TEST_ENV': 'value'},
          cwd: '/tmp',
        ),
      ) as StdioTransport;
      expect(transport.command, 'echo');
      expect(transport.args, ['hello']);
      expect(transport.environment, {'MCP_TEST_ENV': 'value'});
      expect(transport.workingDirectory, '/tmp');
    });
  });
}
