// ignore_for_file: avoid_print

/// The tools of an MCP server given to a `ChatModelAgent`.
///
/// The example connects an [McpClient] to a Model Context Protocol server,
/// turns the server's tools into threepio tools with [McpToolkit], gives
/// them to a [ChatModelAgent] and runs it with a [Runner]: the model decides
/// which MCP tool to call, the agent calls it on the server, and the model
/// answers with the result. The client is closed at the end, which stops the
/// server process.
///
/// Eino counterpart: eino-ext `components/tool/mcp/officialmcp` (`GetTools`
/// over the official go-sdk; the older `components/tool/mcp` over
/// mark3labs/mcp-go has a subset of its options), used with
/// `adk.NewChatModelAgent` and `adk.NewRunner`; eino-examples
/// `components/tool/mcptool`.
///
/// Transports:
/// * stdio (the default): the server runs as a subprocess, started by
///   `StdioTransport` from `package:threepio_core/io.dart` (Go:
///   `mcp.CommandTransport`).
/// * streamable HTTP: a server that already runs, reached at a URL with
///   `StreamableHttpTransport` (Go: `mcp.StreamableClientTransport`). Set
///   `MCP_SERVER_URL` to use it.
///
/// Run it:
///
/// ```bash
/// # A model: OPENROUTER_API_KEY (or OPENAI_API_KEY), see support/example_model.dart.
/// # The server command is taken from the arguments, else MCP_SERVER_COMMAND,
/// # else `npx -y @modelcontextprotocol/server-everything` (needs Node.js):
/// dart run example/mcp_tools_example.dart
/// dart run example/mcp_tools_example.dart npx -y @modelcontextprotocol/server-everything
/// # Or a running streamable-HTTP server:
/// MCP_SERVER_URL=http://localhost:3001/mcp dart run example/mcp_tools_example.dart
/// ```
library;

import 'dart:io';

import 'package:threepio_core/adk.dart';
import 'package:threepio_core/io.dart' show StdioTransport;

import 'support/example_model.dart';

/// The server started when neither the arguments nor `MCP_SERVER_COMMAND`
/// name one: the reference server of the MCP project, whose tools include
/// `echo`.
const defaultMcpServerCommand = [
  'npx',
  '-y',
  '@modelcontextprotocol/server-everything',
];

/// What the example asks the agent.
const mcpExampleQuestion =
    'Use the echo tool to echo the text "hello from threepio", '
    'then tell me in one sentence what the tool returned.';

Future<void> main(List<String> arguments) async {
  final model = exampleChatModel();
  if (model == null) return;

  final env = Platform.environment;
  final url = env['MCP_SERVER_URL'];
  final McpTransport transport;
  if (url != null && url.isNotEmpty) {
    print('MCP server: $url (streamable HTTP)');
    transport = StreamableHttpTransport(Uri.parse(url));
  } else {
    final fromEnv = env['MCP_SERVER_COMMAND']?.trim() ?? '';
    final command = arguments.isNotEmpty
        ? arguments
        : fromEnv.isNotEmpty
            ? fromEnv.split(RegExp(r'\s+'))
            : defaultMcpServerCommand;
    print('MCP server: ${command.join(' ')} (stdio)');
    transport = StdioTransport(command: command.first, args: command.sublist(1));
  }

  try {
    final answer = await runMcpToolsExample(
      RunContext.background(),
      model: model,
      transport: transport,
      question: mcpExampleQuestion,
    );
    print('\nAnswer: $answer');
  } finally {
    closeExampleModel(model);
  }
}

/// Connects to the MCP server behind [transport], gives its tools to a
/// [ChatModelAgent] that answers with [model], asks the agent [question] and
/// returns the agent's last answer. The client (and with it the transport) is
/// closed before the function returns.
///
/// [toolNames] keeps only those tools of the server (Go:
/// `Config.ToolNameList`); all of them by default.
Future<String> runMcpToolsExample(
  RunContext ctx, {
  required ToolCallingChatModel model,
  required McpTransport transport,
  required String question,
  List<String>? toolNames,
}) async {
  // 1. Start the transport and perform the MCP handshake (Go:
  //    `mcp.NewClient(...).Connect(ctx, transport, nil)`).
  final client = await McpClient.connect(
    transport,
    clientInfo: const McpImplementation(
      name: 'threepio-mcp-example',
      version: '1.0.0',
    ),
  );
  try {
    final server = client.initializeResult!;
    print('Connected to ${server.serverInfo.name} '
        '(protocol ${server.protocolVersion})');

    // 2. The server's tools as threepio tools (Go: `officialmcp.GetTools`).
    final tools = await McpToolkit(client, serverName: 'mcp-server').getTools(
      ctx,
      toolNameList: toolNames,
    );
    print('MCP tools: ${tools.map((tool) => tool.exposedToolName).join(', ')}');

    // 3. An agent whose tools node runs them (Go: `adk.NewChatModelAgent`).
    final agent = ChatModelAgent(
      ChatModelAgentConfig(
        name: 'mcp_assistant',
        description: 'Answers with the help of the tools of an MCP server.',
        instruction: 'You are a helpful assistant. Use the tools when they '
            'help to answer, and answer briefly.',
        model: model,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      ),
    );

    // 4. Run it and print what happens (Go: `adk.NewRunner(...).Query`).
    print('\nUser: $question');
    final events = Runner(agent: agent).query(ctx, question);
    var answer = '';
    for (var event = await events.nextOrNull();
        event != null;
        event = await events.nextOrNull()) {
      // A failed run ends with an event that carries the error.
      final error = event.error;
      if (error != null) {
        Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
      }
      final message = await getMessageFromEvent(event);
      if (message == null) continue;
      switch (message.role) {
        case RoleType.assistant:
          for (final call in message.toolCalls ?? const <ToolCall>[]) {
            print('Tool call: ${call.function.name}(${call.function.arguments})');
          }
          if (message.content.isNotEmpty) answer = message.content;
        case RoleType.tool:
          print('Tool result (${message.toolName}): ${toolResultText(message)}');
        case RoleType.system || RoleType.user:
          break;
      }
    }
    return answer;
  } finally {
    // 5. Close the session; for stdio this ends the server process.
    await client.close();
  }
}

/// The text of a tool result message.
///
/// The tools node calls an MCP tool in its multimodal form, so the text,
/// images and audio of the result arrive as parts
/// (`Message.userInputMultiContent`) and `content` stays empty; a text tool's
/// result is its `content`.
String toolResultText(Message message) {
  final parts = message.userInputMultiContent;
  if (parts == null || parts.isEmpty) return message.content;
  return [for (final part in parts) part.text ?? '[${part.type.name}]'].join(' ');
}
