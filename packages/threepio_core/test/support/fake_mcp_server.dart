// An in-process MCP server for the MCP client, transport, toolkit, session
// and prompt template tests.
//
// [FakeMcpServer] answers JSON-RPC like a real server (initialize, ping,
// tools/list with pagination, tools/call, prompts/list, prompts/get) and is
// reached three ways: [FakeInMemoryTransport] (in memory), and
// [FakeMcpHttpServer], a loopback HttpServer that serves the streamable HTTP
// transport (JSON or event-stream responses, session ids, the standalone GET
// stream, DELETE) and the legacy HTTP+SSE transport. [ScriptedMcpTransport]
// lets a test play the server by hand.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/components/tool/mcp/transports.dart';

/// A JSON-RPC error a fake handler throws.
final class FakeRpcError implements Exception {
  FakeRpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  Map<String, Object?> toJson() => {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };
}

/// What a handler of the fake server knows about the request it serves.
final class FakeCallContext {
  FakeCallContext({
    required this.params,
    required this.headers,
    required this.sendToClient,
  });

  /// The `params` of the request.
  final Map<String, Object?> params;

  /// The HTTP headers of the request (lower-case names); empty in memory.
  final Map<String, String> headers;

  /// Sends a message to the client on the channel of this request (before
  /// the response, on an event stream).
  final void Function(Map<String, Object?> message) sendToClient;

  void notify(String method, [Map<String, Object?>? params]) => sendToClient({
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
      });
}

typedef FakeToolHandler = FutureOr<Map<String, Object?>> Function(
  Map<String, Object?> arguments,
  FakeCallContext ctx,
);

/// A tool of the fake server.
final class FakeTool {
  FakeTool({
    required this.name,
    required this.handler,
    this.description,
    this.inputSchema,
    this.annotations,
    this.title,
  });

  /// A tool that answers with one text block made by [text].
  factory FakeTool.text(
    String name,
    String Function(Map<String, Object?> arguments) text, {
    String? description,
    Map<String, Object?>? inputSchema,
    Map<String, Object?>? annotations,
  }) =>
      FakeTool(
        name: name,
        description: description,
        inputSchema: inputSchema,
        annotations: annotations,
        handler: (arguments, _) => {
          'content': [
            {'type': 'text', 'text': text(arguments)},
          ],
        },
      );

  final String name;
  final String? description;
  final Map<String, Object?>? inputSchema;
  final Map<String, Object?>? annotations;
  final String? title;
  final FakeToolHandler handler;

  Map<String, Object?> toJson() => {
        'name': name,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        'inputSchema': inputSchema ??
            const {'type': 'object', 'properties': <String, Object?>{}},
        if (annotations != null) 'annotations': annotations,
      };
}

/// A prompt of the fake server.
final class FakePrompt {
  FakePrompt({
    required this.name,
    required this.messages,
    this.description,
    this.arguments = const [],
  });

  final String name;
  final String? description;
  final List<Map<String, Object?>> arguments;

  /// The messages of the rendered prompt, given its arguments.
  final List<Map<String, Object?>> Function(Map<String, Object?> arguments)
      messages;
}

/// A record of one message the server received.
final class FakeReceived {
  FakeReceived(this.message, this.headers);

  final Map<String, Object?> message;
  final Map<String, String> headers;

  String? get method => message['method'] as String?;
  Map<String, Object?> get params =>
      (message['params'] as Map<String, Object?>?) ?? const {};
}

/// The JSON-RPC side of a fake MCP server.
final class FakeMcpServer {
  FakeMcpServer({
    List<FakeTool>? tools,
    List<FakePrompt>? prompts,
    this.pageSize,
    this.answerVersion,
  })  : tools = tools ?? [],
        prompts = prompts ?? [];

  /// The tools, in listing order.
  final List<FakeTool> tools;

  /// The prompts, in listing order.
  final List<FakePrompt> prompts;

  /// Tools per page of tools/list; `null` lists them all at once.
  int? pageSize;

  /// The protocol version answered to initialize; by default the client's
  /// own when known, '2025-06-18' otherwise.
  String? answerVersion;

  /// Replaces the answer to tools/list, given the cursor.
  Map<String, Object?> Function(String? cursor)? toolsListOverride;

  /// Every message received, in order.
  final List<FakeReceived> received = [];

  List<FakeReceived> receivedOf(String method) =>
      [for (final r in received) if (r.method == method) r];

  static const _known = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

  /// Handles [message]; returns the response for a request, `null` for a
  /// notification or a response.
  Future<Map<String, Object?>?> handle(
    Map<String, Object?> message, {
    Map<String, String> headers = const {},
    void Function(Map<String, Object?> message)? sendToClient,
  }) async {
    received.add(FakeReceived(message, headers));
    final method = message['method'];
    final id = message['id'];
    if (method is! String || id == null) return null;
    final params = (message['params'] as Map<String, Object?>?) ?? const {};
    final ctx = FakeCallContext(
      params: params,
      headers: headers,
      sendToClient: sendToClient ?? (_) {},
    );
    try {
      final result = await _dispatch(method, params, ctx);
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on FakeRpcError catch (error) {
      return {'jsonrpc': '2.0', 'id': id, 'error': error.toJson()};
    }
  }

  Future<Map<String, Object?>> _dispatch(
    String method,
    Map<String, Object?> params,
    FakeCallContext ctx,
  ) async {
    switch (method) {
      case 'initialize':
        final asked = params['protocolVersion'] as String?;
        return {
          'protocolVersion': answerVersion ??
              (_known.contains(asked) ? asked : '2025-06-18'),
          'capabilities': {
            'tools': {'listChanged': true},
            'prompts': <String, Object?>{},
          },
          'serverInfo': {'name': 'fake', 'version': 'v1.0.0'},
        };
      case 'ping':
        return {};
      case 'tools/list':
        final cursor = params['cursor'] as String?;
        final override = toolsListOverride;
        if (override != null) return override(cursor);
        final start = cursor == null ? 0 : int.tryParse(cursor);
        if (start == null || start < 0 || start > tools.length) {
          throw FakeRpcError(McpException.invalidParams, 'bad cursor');
        }
        final size = pageSize ?? tools.length;
        final end =
            start + size > tools.length ? tools.length : start + size;
        return {
          'tools': [for (final t in tools.sublist(start, end)) t.toJson()],
          if (end < tools.length) 'nextCursor': '$end',
        };
      case 'tools/call':
        final name = params['name'] as String?;
        final tool = tools.where((t) => t.name == name).firstOrNull;
        if (tool == null) {
          throw FakeRpcError(McpException.invalidParams, 'unknown tool "$name"');
        }
        final arguments =
            (params['arguments'] as Map<String, Object?>?) ?? const {};
        return tool.handler(arguments, ctx);
      case 'prompts/list':
        return {
          'prompts': [
            for (final p in prompts)
              {
                'name': p.name,
                if (p.description != null) 'description': p.description,
                'arguments': p.arguments,
              },
          ],
        };
      case 'prompts/get':
        final name = params['name'] as String?;
        final prompt = prompts.where((p) => p.name == name).firstOrNull;
        if (prompt == null) {
          throw FakeRpcError(
            McpException.invalidParams,
            'unknown prompt "$name"',
          );
        }
        final arguments =
            (params['arguments'] as Map<String, Object?>?) ?? const {};
        return {
          if (prompt.description != null) 'description': prompt.description,
          'messages': prompt.messages(arguments),
        };
      default:
        throw FakeRpcError(McpException.methodNotFound, 'method not found');
    }
  }
}

/// A client transport connected to a [FakeMcpServer] in memory.
final class FakeInMemoryTransport implements McpTransport {
  FakeInMemoryTransport(this.server);

  final FakeMcpServer server;
  final List<Map<String, Object?>> sent = [];
  final List<Map<String, String>?> sentHeaders = [];
  String? protocolVersion;
  bool started = false;
  bool closed = false;
  int closeCalls = 0;

  /// When set, close() waits for it first (a slow transport).
  Future<void>? closeGate;
  McpMessageHandler? _onMessage;
  McpCloseHandler? _onClose;

  @override
  Future<void> start({
    required McpMessageHandler onMessage,
    required McpCloseHandler onClose,
  }) async {
    started = true;
    _onMessage = onMessage;
    _onClose = onClose;
  }

  /// Delivers [message] to the client, as if the server had sent it.
  void push(Map<String, Object?> message) {
    scheduleMicrotask(() {
      if (!closed) _onMessage?.call(message);
    });
  }

  /// Breaks the connection, as if the server had gone away.
  void breakConnection([Object? error]) {
    if (closed) return;
    closed = true;
    _onClose?.call(error ?? const McpConnectionException('broken'));
  }

  @override
  Future<void> send(
    Map<String, Object?> message, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    if (closed) throw const McpConnectionException('the transport is closed');
    sent.add(message);
    sentHeaders.add(headers);
    await Future<void>.delayed(Duration.zero);
    final response = await server.handle(
      message,
      headers: headers ?? const {},
      sendToClient: push,
    );
    if (response != null) push(response);
  }

  @override
  void setProtocolVersion(String version) => protocolVersion = version;

  @override
  Future<void> close() async {
    closeCalls++;
    final gate = closeGate;
    if (gate != null) await gate;
    if (closed) return;
    closed = true;
    _onClose?.call(null);
  }
}

/// A transport whose server is the test: it records what the client sends
/// and delivers what the test pushes.
class ScriptedMcpTransport implements McpTransport {
  ScriptedMcpTransport({this.autoInitialize = true});

  /// Whether `initialize` is answered automatically (with
  /// [initializeVersion]).
  final bool autoInitialize;
  String initializeVersion = '2025-06-18';

  /// Makes [send] fail with this error (once set, for every message).
  Object? sendError;

  /// Called for every sent message, after it was recorded.
  void Function(Map<String, Object?> message)? onSend;

  final List<Map<String, Object?>> sent = [];
  final List<CancelToken?> sentTokens = [];
  String? protocolVersion;
  bool closed = false;
  McpMessageHandler? _onMessage;
  McpCloseHandler? _onClose;
  final _sentController = StreamController<Map<String, Object?>>.broadcast();

  /// The messages sent from now on.
  Stream<Map<String, Object?>> get onSent => _sentController.stream;

  /// The first message sent with [method] from now on (or already sent).
  Future<Map<String, Object?>> nextSent(String method) {
    for (final m in sent) {
      if (m['method'] == method) return Future.value(m);
    }
    return onSent.firstWhere((m) => m['method'] == method);
  }

  List<Map<String, Object?>> sentOf(String method) =>
      [for (final m in sent) if (m['method'] == method) m];

  @override
  Future<void> start({
    required McpMessageHandler onMessage,
    required McpCloseHandler onClose,
  }) async {
    _onMessage = onMessage;
    _onClose = onClose;
  }

  /// Delivers [message] to the client.
  void push(Map<String, Object?> message) => _onMessage?.call(message);

  void respond(Object? id, Map<String, Object?> result) =>
      push({'jsonrpc': '2.0', 'id': id, 'result': result});

  void respondError(Object? id, int code, String message, [Object? data]) =>
      push({
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': code,
          'message': message,
          if (data != null) 'data': data,
        },
      });

  void breakConnection([Object? error]) {
    closed = true;
    _onClose?.call(error ?? const McpConnectionException('broken'));
  }

  @override
  Future<void> send(
    Map<String, Object?> message, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final error = sendError;
    if (error != null) throw error;
    sent.add(message);
    sentTokens.add(cancelToken);
    _sentController.add(message);
    onSend?.call(message);
    if (autoInitialize && message['method'] == 'initialize') {
      scheduleMicrotask(
        () => respond(message['id'], {
          'protocolVersion': initializeVersion,
          'capabilities': <String, Object?>{},
          'serverInfo': {'name': 'scripted', 'version': '1'},
        }),
      );
    }
  }

  @override
  void setProtocolVersion(String version) => protocolVersion = version;

  @override
  Future<void> close() async {
    closed = true;
    await _sentController.close();
    _onClose?.call(null);
  }
}

/// How the fake HTTP server answers a POSTed request.
enum FakeResponseMode { json, sse }

/// One HTTP request the fake HTTP server received.
final class FakeHttpRecord {
  FakeHttpRecord(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;

  /// Header values by lower-case name.
  final Map<String, String> headers;
  final String body;

  Map<String, Object?>? get json {
    if (body.isEmpty) return null;
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  }
}

/// Writes events to one open event-stream response, one write at a time.
final class _EventSink {
  _EventSink(this.response);

  final HttpResponse response;
  Future<void> _last = Future<void>.value();
  bool closed = false;

  Future<void> write(String text) => _last = _last.then((_) async {
        if (closed) return;
        try {
          response.write(text);
          await response.flush();
        } on Object {
          closed = true;
        }
      });

  Future<void> event(Map<String, Object?> message, {String? event}) => write(
        '${event == null ? '' : 'event: $event\n'}data: ${jsonEncode(message)}\n\n',
      );

  Future<void> close() => _last = _last.then((_) async {
        if (closed) return;
        closed = true;
        try {
          await response.close();
        } on Object {
          // Gone already.
        }
      });
}

/// A loopback HTTP server that serves a [FakeMcpServer] over the streamable
/// HTTP transport (`/mcp`) and the legacy HTTP+SSE transport (`/sse`, POSTs
/// to `/messages?sessionId=…`).
final class FakeMcpHttpServer {
  FakeMcpHttpServer._(
    this.mcp,
    this._server, {
    required this.mode,
    required this.sessions,
    required this.standaloneGet,
  }) {
    _server.listen(_serve);
  }

  static Future<FakeMcpHttpServer> start(
    FakeMcpServer mcp, {
    FakeResponseMode mode = FakeResponseMode.json,
    bool sessions = true,
    bool standaloneGet = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return FakeMcpHttpServer._(
      mcp,
      server,
      mode: mode,
      sessions: sessions,
      standaloneGet: standaloneGet,
    );
  }

  final FakeMcpServer mcp;
  final HttpServer _server;

  /// How requests are answered (may be changed between requests).
  FakeResponseMode mode;

  /// Whether the server assigns and checks `Mcp-Session-Id`.
  final bool sessions;

  /// Whether GET /mcp opens a standalone event stream (405 otherwise).
  final bool standaloneGet;

  /// Answers every POST to /mcp with this status (and the body `boom`).
  int? postStatus;

  /// Answers every POST request to /mcp with this content type instead.
  String? postContentType;

  /// Ends an event-stream response before writing the response.
  bool dropSseResponse = false;

  /// The first event of the legacy stream (default: the endpoint event).
  String? legacyFirstEvent;

  /// SSE mode: answer a request with a priming event (an id, `retry: 1`, no
  /// data) and close the stream; the response is served to the GET that
  /// carries that id as `Last-Event-ID` (the polling of revision 2025-11-25).
  bool polling = false;

  /// With [polling]: never serve the response, only prime again.
  bool pollingDropReplies = false;

  /// SSE mode: keep the stream open after the response.
  bool keepSseOpen = false;

  final List<FakeHttpRecord> requests = [];
  final Set<String> liveSessions = {};
  final List<_EventSink> _standalone = [];
  final List<_EventSink> _kept = [];
  final Map<String, _EventSink> _legacy = {};
  final Map<String, Map<String, Object?>> _resumable = {};
  int _sessionCounter = 0;
  int _eventCounter = 0;

  Uri get mcpUrl => Uri.parse('http://127.0.0.1:${_server.port}/mcp');
  Uri get sseUrl => Uri.parse('http://127.0.0.1:${_server.port}/sse');

  List<FakeHttpRecord> requestsOf(String method, [String? path]) => [
        for (final r in requests)
          if (r.method == method && (path == null || r.path == path)) r,
      ];

  /// Forgets every session, as a restarted server would.
  void dropSessions() => liveSessions.clear();

  int get openStandaloneStreams =>
      _standalone.where((s) => !s.closed).length;

  /// Sends [message] on every open standalone stream.
  Future<void> pushStandalone(Map<String, Object?> message) async {
    for (final sink in _standalone) {
      await sink.event(message, event: 'message');
    }
  }

  /// Ends every standalone stream, as a server or proxy that drops it.
  Future<void> endStandaloneStreams() async {
    final sinks = [..._standalone];
    _standalone.clear();
    for (final sink in sinks) {
      await sink.close();
    }
  }

  /// Sends [message] on every legacy event stream.
  Future<void> pushLegacy(Map<String, Object?> message) async {
    for (final sink in _legacy.values) {
      await sink.event(message, event: 'message');
    }
  }

  /// Ends every legacy event stream.
  Future<void> endLegacyStreams() async {
    for (final sink in _legacy.values) {
      await sink.close();
    }
  }

  Future<void> close() async {
    for (final sink in [..._standalone, ..._kept, ..._legacy.values]) {
      await sink.close();
    }
    await _server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    final record =
        FakeHttpRecord(request.method, request.uri.path, headers, body);
    requests.add(record);
    final response = request.response;
    try {
      switch ((request.method, request.uri.path)) {
        case ('POST', '/mcp'):
          await _post(record, response);
        case ('GET', '/mcp'):
          await _get(record, response);
        case ('DELETE', '/mcp'):
          liveSessions.remove(headers['mcp-session-id']);
          response.statusCode = HttpStatus.ok;
          await response.close();
        case ('GET', '/sse'):
          await _legacyStream(response);
        case ('POST', '/messages'):
          await _legacyPost(record, request.uri, response);
        default:
          response.statusCode = HttpStatus.notFound;
          await response.close();
      }
    } on Object {
      // The client went away.
    }
  }

  Future<void> _post(FakeHttpRecord record, HttpResponse response) async {
    final status = postStatus;
    if (status != null) {
      response
        ..statusCode = status
        ..write('boom');
      await response.close();
      return;
    }
    final message = record.json;
    if (message == null) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    if (sessions) {
      if (message['method'] == 'initialize') {
        final id = 'session-${++_sessionCounter}';
        liveSessions.add(id);
        response.headers.set('Mcp-Session-Id', id);
      } else {
        final id = record.headers['mcp-session-id'];
        if (id == null) {
          response.statusCode = HttpStatus.badRequest;
          await response.close();
          return;
        }
        if (!liveSessions.contains(id)) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
      }
    }
    final isRequest = message['method'] is String && message['id'] != null;
    if (!isRequest) {
      await mcp.handle(message, headers: record.headers);
      response.statusCode = HttpStatus.accepted;
      await response.close();
      return;
    }
    final contentType = postContentType;
    if (contentType != null) {
      response.headers.set('content-type', contentType);
      response.write('???');
      await response.close();
      return;
    }
    switch (mode) {
      case FakeResponseMode.json:
        final reply = await mcp.handle(
          message,
          headers: record.headers,
          sendToClient: (m) => unawaited(pushStandalone(m)),
        );
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(reply));
        await response.close();
      case FakeResponseMode.sse:
        response.headers.set('content-type', 'text/event-stream');
        response.bufferOutput = false;
        final sink = _EventSink(response);
        if (polling) {
          final eventId = 'ev-${++_eventCounter}';
          final reply = await mcp.handle(message, headers: record.headers);
          if (!pollingDropReplies) _resumable[eventId] = reply!;
          await sink.write('id: $eventId\nretry: 1\ndata: \n\n');
          await sink.close();
          return;
        }
        await sink.write(': stream opened\n\n');
        final reply = await mcp.handle(
          message,
          headers: record.headers,
          sendToClient: (m) => unawaited(sink.event(m, event: 'message')),
        );
        if (!dropSseResponse) await sink.event(reply!, event: 'message');
        if (keepSseOpen) {
          _kept.add(sink);
        } else {
          await sink.close();
        }
    }
  }

  Future<void> _get(FakeHttpRecord record, HttpResponse response) async {
    final lastEventId = record.headers['last-event-id'];
    if (lastEventId != null) {
      if (sessions &&
          !liveSessions.contains(record.headers['mcp-session-id'])) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      response.headers.set('content-type', 'text/event-stream');
      response.bufferOutput = false;
      final sink = _EventSink(response);
      final reply = _resumable.remove(lastEventId);
      if (reply == null) {
        await sink.write('id: $lastEventId\nretry: 1\ndata: \n\n');
      } else {
        await sink.write(
          'id: ev-${++_eventCounter}\nevent: message\n'
          'data: ${jsonEncode(reply)}\n\n',
        );
      }
      await sink.close();
      return;
    }
    if (!standaloneGet) {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    if (sessions && !liveSessions.contains(record.headers['mcp-session-id'])) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response.headers.set('content-type', 'text/event-stream');
    response.bufferOutput = false;
    final sink = _EventSink(response);
    _standalone.add(sink);
    await sink.write(': standalone\n\n');
  }

  Future<void> _legacyStream(HttpResponse response) async {
    final id = 'legacy-${++_sessionCounter}';
    response.headers.set('content-type', 'text/event-stream');
    response.bufferOutput = false;
    final sink = _EventSink(response);
    _legacy[id] = sink;
    await sink.write(
      legacyFirstEvent ?? 'event: endpoint\ndata: /messages?sessionId=$id\n\n',
    );
  }

  Future<void> _legacyPost(
    FakeHttpRecord record,
    Uri uri,
    HttpResponse response,
  ) async {
    final sink = _legacy[uri.queryParameters['sessionId']];
    final message = record.json;
    if (sink == null || message == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response.statusCode = HttpStatus.accepted;
    await response.close();
    final reply = await mcp.handle(
      message,
      headers: record.headers,
      sendToClient: (m) => unawaited(sink.event(m, event: 'message')),
    );
    if (reply != null) await sink.event(reply, event: 'message');
  }
}
