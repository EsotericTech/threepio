/// An MCP connection built from a server config, rebuilt when it breaks.
///
/// Port of eino-ext `components/tool/mcp/officialmcp/session`.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/async_mutex.dart';
import '../../model/cancel_token.dart';
import 'mcp_client.dart';
import 'mcp_toolkit.dart';
import 'transports.dart';

/// The transports a [McpTransportConfig] can name.
///
/// Port of the `session.Transport*` constants.
enum McpTransportType {
  /// The HTTP+SSE transport of revision 2024-11-05 ([SseTransport]).
  sse('sse'),

  /// A subprocess spoken to over stdin/stdout (`StdioTransport`, from
  /// `package:threepio_core/io.dart`).
  stdio('stdio'),

  /// The Streamable HTTP transport ([StreamableHttpTransport]).
  streamableHttp('streamable-http');

  const McpTransportType(this.wireValue);

  /// The Go value.
  final String wireValue;
}

/// Builds the transport of a session; called again on every reconnect.
///
/// Port of `session.TransportConfig.Factory`.
typedef McpTransportFactory = FutureOr<McpTransport> Function(RunContext ctx);

/// Builds the stdio transport of a config. `StdioTransport.fromConfig` (in
/// `package:threepio_core/io.dart`) is the one to pass; it is injected so that
/// this library needs no `dart:io`.
typedef McpStdioTransportFactory = McpTransport Function(
  McpTransportConfig config,
);

/// How to reach an MCP server.
///
/// Port of `session.TransportConfig`.
@immutable
final class McpTransportConfig {
  /// A config; which fields matter depends on [type].
  const McpTransportConfig({
    this.type,
    this.url,
    this.command,
    this.args = const [],
    this.env = const {},
    this.headers = const {},
    this.cwd,
    this.httpClient,
    this.factory,
  });

  /// The kind of transport. Ignored when [factory] is set.
  final McpTransportType? type;

  /// The absolute URL of the server ([McpTransportType.sse],
  /// [McpTransportType.streamableHttp]).
  final String? url;

  /// The program to run ([McpTransportType.stdio]).
  final String? command;

  /// Its arguments.
  final List<String> args;

  /// Variables added to the environment of the program.
  final Map<String, String> env;

  /// Headers sent with every HTTP request. They are set before the request
  /// reaches [httpClient], which sees them and may change them.
  final Map<String, String> headers;

  /// The working directory of the program.
  final String? cwd;

  /// The HTTP client of the URL-based transports (a client that adds fresh
  /// credentials to every request survives reconnects). Never closed by the
  /// session. Ignored for stdio.
  final http.Client? httpClient;

  /// Builds a custom transport; takes precedence over [type] and is called
  /// again on every reconnect.
  final McpTransportFactory? factory;
}

/// One MCP server: its name, how to reach it, and how to introduce the client.
///
/// Port of `session.ServerConfig` (`Client` is [clientInfo]; the options of
/// the go-sdk client and of its `initialize` are [capabilities],
/// [protocolVersion], [requestTimeout] and [onNotification]).
@immutable
final class McpServerConfig {
  /// The server [name], reached through [transport].
  const McpServerConfig({
    required this.name,
    required this.transport,
    this.clientInfo,
    this.capabilities = const {},
    this.protocolVersion = mcpLatestProtocolVersion,
    this.requestTimeout,
    this.onNotification,
  });

  /// A name for the server, used in errors.
  final String name;

  /// How to reach it.
  final McpTransportConfig transport;

  /// Who the client says it is; `eino-officialmcp v0.0.0` when `null`.
  final McpImplementation? clientInfo;

  /// The client capabilities sent with `initialize`.
  final Map<String, Object?> capabilities;

  /// The revision of the specification asked for.
  final String protocolVersion;

  /// How long a request may wait for its response (`null`: no limit).
  final Duration? requestTimeout;

  /// Receives the notifications of the server.
  final McpNotificationHandler? onNotification;
}

/// A session could not be started.
///
/// Port of `session.StartupError`; the failure is the [cause].
final class McpStartupException extends ThreepioException {
  /// The session of [serverName] over [transportType] could not start
  /// because of [cause].
  McpStartupException({
    required this.serverName,
    required this.transportType,
    required Object cause,
  }) : super(
          'failed to start official mcp session, server: $serverName, '
          'transport: $transportType: ${_describe(cause)}',
          cause: cause,
        );

  /// The name of the server.
  final String serverName;

  /// The wire value of the transport type of the config (empty when it named
  /// none).
  final String transportType;

  static String _describe(Object cause) =>
      cause is ThreepioException ? cause.message : '$cause';
}

/// The session was closed.
///
/// Port of `session.ErrSessionClosed`.
final class McpSessionClosedException extends ThreepioException {
  /// The session was closed.
  const McpSessionClosedException()
      : super('official mcp session is closed');
}

/// An [McpClientSession] (and [McpPromptClient]) that rebuilds its client
/// when a call fails because the connection broke.
///
/// Port of `session.Session`. An [McpClient] cannot be revived once its
/// connection failed, so the session keeps the [config] and connects again:
///
/// * Only connection failures ([isMcpConnectionError]) trigger a reconnect,
///   after which the call is retried once. A rejected call or a failed tool
///   leaves the client alone, so a model that keeps calling with bad
///   arguments cannot cause reconnect churn.
/// * Concurrent calls that fail on the same client share one reconnect.
/// * A failed reconnect throws an [McpToolkitException] of
///   [McpErrorKind.connection] whose cause is the [McpStartupException].
final class McpSession implements McpClientSession, McpPromptClient {
  McpSession._(this.config, this._client, this._stdioFactory);

  /// Connects to the server of [config].
  ///
  /// Port of `session.Connect`. [stdioFactory] builds the transport of a
  /// [McpTransportType.stdio] config (pass `StdioTransport.fromConfig`).
  /// Throws an [McpStartupException] when the transport cannot be built or
  /// the handshake fails, and `CancelledException` when the cancel token of
  /// [ctx] fires first.
  static Future<McpSession> connect(
    RunContext ctx,
    McpServerConfig config, {
    McpStdioTransportFactory? stdioFactory,
  }) async {
    final client = await _connect(ctx, config, stdioFactory);
    return McpSession._(config, client, stdioFactory);
  }

  /// The config the session (re)connects with.
  final McpServerConfig config;

  final McpStdioTransportFactory? _stdioFactory;
  final AsyncMutex _mutex = AsyncMutex();
  McpClient? _client;
  bool _closed = false;

  /// The name of the server.
  String get name => config.name;

  /// The client in use, or `null` once closed.
  @visibleForTesting
  McpClient? get currentClient => _client;

  /// Closes the client in use. Calls made afterwards throw
  /// [McpSessionClosedException]. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final client = _client;
    _client = null;
    await client?.close();
  }

  McpClient _current() {
    final client = _client;
    if (_closed || client == null) throw const McpSessionClosedException();
    return client;
  }

  /// Replaces [stale] with a new client, unless another call already did.
  ///
  /// Port of `Session.reconnect`: if the client in use is no longer [stale],
  /// it is returned as it is; otherwise the session connects again and only
  /// then closes [stale], so a failed reconnect leaves [stale] in place for
  /// the next attempt.
  @visibleForTesting
  Future<McpClient> reconnect(RunContext ctx, McpClient? stale) =>
      _mutex.protect(() async {
        if (_closed) throw const McpSessionClosedException();
        final current = _client;
        if (current != null && !identical(current, stale)) return current;
        final McpClient fresh;
        try {
          fresh = await _connect(ctx, config, _stdioFactory);
        } on McpStartupException catch (error) {
          throw McpToolkitException(
            error.message,
            kind: McpErrorKind.connection,
            serverName: config.name,
            cause: error,
          );
        }
        if (_closed) {
          await fresh.close();
          throw const McpSessionClosedException();
        }
        // Installed before the stale client is closed: a close() of the
        // session while that takes time then closes the fresh one.
        _client = fresh;
        await stale?.close();
        if (_closed) throw const McpSessionClosedException();
        return fresh;
      });

  Future<T> _withReconnect<T>(
    CancelToken? cancelToken,
    Future<T> Function(McpClient client) call,
  ) async {
    final stale = _current();
    try {
      return await call(stale);
    } on Exception catch (error) {
      if (!isMcpConnectionError(error)) rethrow;
    }
    final fresh =
        await reconnect(RunContext.background(cancelToken: cancelToken), stale);
    return call(fresh);
  }

  @override
  Future<McpListToolsResult> listTools({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) =>
      _withReconnect(
        cancelToken,
        (client) => client.listTools(
          cursor: cursor,
          headers: headers,
          cancelToken: cancelToken,
        ),
      );

  @override
  Future<McpCallToolResult> callTool(
    String name, {
    Object? arguments,
    Map<String, Object?>? meta,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) =>
      _withReconnect(
        cancelToken,
        (client) => client.callTool(
          name,
          arguments: arguments,
          meta: meta,
          headers: headers,
          cancelToken: cancelToken,
        ),
      );

  /// Pings the server, reconnecting once on a connection failure.
  ///
  /// Port of `Session.Ping`.
  Future<void> ping({CancelToken? cancelToken}) => _withReconnect(
        cancelToken,
        (client) => client.ping(cancelToken: cancelToken),
      );

  @override
  Future<McpListPromptsResult> listPrompts({
    String? cursor,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) =>
      _withReconnect(
        cancelToken,
        (client) => client.listPrompts(
          cursor: cursor,
          headers: headers,
          cancelToken: cancelToken,
        ),
      );

  @override
  Future<McpGetPromptResult> getPrompt(
    String name, {
    Map<String, String>? arguments,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) =>
      _withReconnect(
        cancelToken,
        (client) => client.getPrompt(
          name,
          arguments: arguments,
          headers: headers,
          cancelToken: cancelToken,
        ),
      );
}

Future<McpClient> _connect(
  RunContext ctx,
  McpServerConfig config,
  McpStdioTransportFactory? stdioFactory,
) async {
  final transportType = config.transport.type?.wireValue ?? '';
  final McpTransport transport;
  try {
    transport = await _newTransport(ctx, config.transport, stdioFactory);
  } on CancelledException {
    rethrow;
  } on Exception catch (error) {
    if (isInterrupt(error)) rethrow;
    throw McpStartupException(
      serverName: config.name,
      transportType: transportType,
      cause: error,
    );
  }
  final client = McpClient(
    transport,
    clientInfo: config.clientInfo ?? McpImplementation.defaultClient,
    capabilities: config.capabilities,
    protocolVersion: config.protocolVersion,
    requestTimeout: config.requestTimeout,
    onNotification: config.onNotification,
  );
  try {
    await client.initialize(cancelToken: ctx.cancelToken);
  } on CancelledException {
    rethrow;
  } on Exception catch (error) {
    if (isInterrupt(error)) rethrow;
    throw McpStartupException(
      serverName: config.name,
      transportType: transportType,
      cause: error,
    );
  }
  return client;
}

Future<McpTransport> _newTransport(
  RunContext ctx,
  McpTransportConfig config,
  McpStdioTransportFactory? stdioFactory,
) async {
  final factory = config.factory;
  if (factory != null) return factory(ctx);
  switch (config.type) {
    case McpTransportType.sse:
      return SseTransport(
        _absoluteUrl(config.url),
        httpClient: config.httpClient,
        headers: config.headers,
      );
    case McpTransportType.streamableHttp:
      return StreamableHttpTransport(
        _absoluteUrl(config.url),
        httpClient: config.httpClient,
        headers: config.headers,
      );
    case McpTransportType.stdio:
      final command = config.command;
      if (command == null || command.isEmpty) {
        throw const ThreepioException('stdio command is empty');
      }
      if (stdioFactory == null) {
        throw const ThreepioException(
          'the stdio transport needs a stdioFactory: pass '
          'StdioTransport.fromConfig from package:threepio_core/io.dart',
        );
      }
      return stdioFactory(config);
    case null:
      throw const McpToolkitException(
        'unsupported official mcp transport: ',
        kind: McpErrorKind.unsupportedTransport,
      );
  }
}

Uri _absoluteUrl(String? raw) {
  if (raw == null || raw.isEmpty) {
    throw const ThreepioException('transport URL is empty');
  }
  final uri = Uri.tryParse(raw);
  if (uri == null) {
    throw ThreepioFormatException('transport URL is invalid: $raw');
  }
  if (!uri.isAbsolute || uri.host.isEmpty) {
    throw ThreepioException('transport URL must be absolute: $raw');
  }
  return uri;
}
