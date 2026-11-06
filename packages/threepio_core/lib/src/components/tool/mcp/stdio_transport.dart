/// The stdio transport of MCP: a server run as a subprocess.
///
/// Exported from `package:threepio_core/io.dart` only, because it needs
/// `dart:io`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../../model/cancel_token.dart';
import 'mcp_client.dart';
import 'mcp_session.dart';
import 'transports.dart';

final _log = Logger('threepio.mcp.stdio');

/// Talks to an MCP server over its standard input and output.
///
/// Port of go-sdk `mcp.CommandTransport` (and mark3labs `transport.Stdio`):
/// [start] runs [command] with [args] in [workingDirectory], with
/// [environment] added to the environment of this process. Each message is
/// one line of JSON on the server's stdin; each line the server writes to
/// stdout is a message (lines that are not JSON are logged and skipped). What
/// the server writes to stderr is logged (`threepio.mcp.stdio`, level INFO).
/// When the server's stdout ends (it exited), the connection is over.
///
/// [close] closes the server's stdin and waits [terminateTimeout] for it to
/// exit, then sends SIGTERM, waits again, and finally SIGKILL, as the go-sdk
/// does.
///
/// [StdioTransport.fromStreams] runs over given streams instead of a process
/// (for tests, or a server reached some other way).
final class StdioTransport implements McpTransport {
  /// A transport that starts [command] when the client starts it.
  StdioTransport({
    required String command,
    List<String> args = const [],
    Map<String, String>? environment,
    String? workingDirectory,
    this.terminateTimeout = const Duration(seconds: 5),
  })  : _command = command,
        _args = args,
        _environment = environment,
        _workingDirectory = workingDirectory,
        _input = null,
        _output = null,
        _stderr = null;

  /// A transport over streams: [input] carries what the server writes (its
  /// stdout), [output] takes what the server reads (its stdin), and [stderr],
  /// if given, is logged. When [input] ends, the connection is over; [close]
  /// closes [output].
  StdioTransport.fromStreams({
    required Stream<List<int>> input,
    required StreamSink<List<int>> output,
    Stream<List<int>>? stderr,
  })  : _command = null,
        _args = const [],
        _environment = null,
        _workingDirectory = null,
        _input = input,
        _output = output,
        _stderr = stderr,
        terminateTimeout = Duration.zero;

  /// The stdio transport an `McpSession` uses for an
  /// [McpTransportType.stdio] config: pass it as `stdioFactory` to
  /// `McpSession.connect`.
  static McpTransport fromConfig(McpTransportConfig config) => StdioTransport(
        command: config.command ?? '',
        args: config.args,
        environment: config.env.isEmpty ? null : config.env,
        workingDirectory:
            config.cwd == null || config.cwd!.isEmpty ? null : config.cwd,
      );

  /// How long [close] waits for the process at each step.
  final Duration terminateTimeout;

  final String? _command;
  final List<String> _args;
  final Map<String, String>? _environment;
  final String? _workingDirectory;
  Stream<List<int>>? _input;
  StreamSink<List<int>>? _output;
  Stream<List<int>>? _stderr;

  Process? _process;
  StreamSubscription<String>? _inputSubscription;
  StreamSubscription<String>? _stderrSubscription;
  McpMessageHandler? _onMessage;
  McpCloseHandler? _onClose;
  bool _started = false;
  bool _closed = false;
  bool _ended = false;
  int? _exitCode;

  /// The command this transport runs, or `null` for one over streams.
  String? get command => _command;

  /// The arguments of [command].
  List<String> get args => _args;

  /// The variables added to the environment of the process.
  Map<String, String>? get environment => _environment;

  /// The working directory of the process.
  String? get workingDirectory => _workingDirectory;

  /// The process, once started.
  Process? get process => _process;

  @override
  Future<void> start({
    required McpMessageHandler onMessage,
    required McpCloseHandler onClose,
  }) async {
    if (_started) throw StateError('StdioTransport.start was already called');
    if (_closed) throw const McpConnectionException('the transport is closed');
    _started = true;
    _onMessage = onMessage;
    _onClose = onClose;

    final command = _command;
    if (command != null) {
      final Process process;
      try {
        process = await Process.start(
          command,
          _args,
          environment: _environment,
          workingDirectory: _workingDirectory,
        );
      } on ProcessException catch (error) {
        throw McpConnectionException(
          'failed to start the MCP server "$command": ${error.message}',
          cause: error,
        );
      }
      _process = process;
      if (_closed) {
        // close() ran while the process was starting.
        process.kill(ProcessSignal.sigkill);
        throw const McpConnectionException('the transport is closed');
      }
      _input = process.stdout;
      _output = process.stdin;
      _stderr = process.stderr;
      unawaited(process.exitCode.then((code) => _exitCode = code));
    }

    final name = command ?? 'stdio';
    _stderrSubscription = _stderr
        ?.transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _log.info('[$name] $line'),
          onError: (Object _) {},
        );
    _inputSubscription = _input!
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (_closed || line.trim().isEmpty) return;
            for (final message in decodeMcpMessages(line)) {
              if (_closed) return;
              _onMessage?.call(message);
            }
          },
          onError: (Object error) => _end(
            McpConnectionException(
              'reading from the MCP server failed: $error',
              cause: error,
            ),
          ),
          // The end of the output, not the exit of the process, ends the
          // connection: the last messages are read first.
          onDone: () => _end(
            McpConnectionException(
              _exitCode == null
                  ? 'the MCP server closed its output'
                  : 'the MCP server "$name" exited with code $_exitCode',
            ),
          ),
        );
    unawaited(
      _output!.done.then<void>(
        (_) {},
        onError: (Object error) => _end(
          McpConnectionException(
            'writing to the MCP server failed: $error',
            cause: error,
          ),
        ),
      ),
    );
  }

  void _end(McpConnectionException failure) {
    if (_closed || _ended) return;
    _ended = true;
    _onClose?.call(failure);
  }

  @override
  void setProtocolVersion(String version) {}

  @override
  Future<void> send(
    Map<String, Object?> message, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final output = _output;
    if (_closed || _ended || output == null) {
      throw const McpConnectionException('the transport is closed');
    }
    cancelToken?.throwIfCancelled();
    try {
      output.add(utf8.encode('${jsonEncode(message)}\n'));
    } on Object catch (error) {
      throw McpConnectionException(
        'writing to the MCP server failed: $error',
        cause: error,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Not awaited: a server that does not read its input would hold close()
    // up forever.
    final output = _output;
    if (output != null) {
      unawaited(
        Future<void>.sync(output.close).then<void>(
          (_) {},
          onError: (Object error) =>
              _log.fine('Closing the input of the MCP server failed: $error'),
        ),
      );
    }
    final process = _process;
    if (process != null) await _terminate(process);
    await _inputSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _onClose?.call(null);
  }

  Future<void> _terminate(Process process) async {
    Future<bool> exited() => process.exitCode
        .then((_) => true)
        .timeout(terminateTimeout, onTimeout: () => false);

    if (await exited()) return;
    process.kill();
    if (await exited()) return;
    process.kill(ProcessSignal.sigkill);
    await exited();
  }
}
