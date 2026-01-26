import 'dart:convert';

import '../../components/tool/invokable_tool.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../core/base_agent.dart';

/// Wraps an agent as a tool for use in other agents.
///
/// This enables composable agent hierarchies where agents can
/// call other agents as if they were tools.
///
/// Example:
/// ```dart
/// final researchTool = AgentTool(
///   agent: researchAgent,
///   toolName: 'deep_research',
///   toolDescription: 'Perform in-depth research on a topic',
/// );
///
/// // Register with another agent's tool registry
/// supervisorAgent.toolRegistry.register(researchTool);
/// ```
class AgentTool extends InvokableTool {
  /// Creates an agent tool.
  AgentTool({
    required BaseAgent agent,
    String? toolName,
    String? toolDescription,
    this.inputParameter = 'query',
    this.inputDescription = 'The input query or request for the agent',
    this.contextParameter,
    this.contextDescription,
  })  : _agent = agent,
        _toolName = toolName ?? _sanitizeName(agent.name),
        _toolDescription = toolDescription ?? agent.description;

  final BaseAgent _agent;
  final String _toolName;
  final String _toolDescription;

  /// Name of the primary input parameter.
  final String inputParameter;

  /// Description of the input parameter.
  final String inputDescription;

  /// Optional name of a context parameter.
  final String? contextParameter;

  /// Description of the context parameter.
  final String? contextDescription;

  /// The wrapped agent.
  BaseAgent get agent => _agent;

  @override
  Future<ToolInfo> info() async {
    final properties = <String, JSONSchemaProperty>{
      inputParameter: JSONSchemaProperty.string(
        description: inputDescription,
      ),
    };

    if (contextParameter != null) {
      properties[contextParameter!] = JSONSchemaProperty.string(
        description: contextDescription ?? 'Additional context for the agent',
      );
    }

    return ToolInfo.simple(
      name: _toolName,
      description: _toolDescription,
      properties: properties,
      required: [inputParameter],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final input = args[inputParameter] as String? ?? '';
    final context = contextParameter != null
        ? args[contextParameter] as String?
        : null;

    // Build messages for the agent
    final messages = <Message>[
      Message.user(input),
    ];

    if (context != null) {
      messages.insert(0, Message.system('Context: $context'));
    }

    // Invoke agent
    final result = await _agent.invoke(messages);

    return result.content;
  }

  static String _sanitizeName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }
}

/// Extension to easily convert agents to tools.
extension AgentToTool on BaseAgent {
  /// Convert this agent to a tool.
  ///
  /// Example:
  /// ```dart
  /// final tool = myAgent.asTool(
  ///   toolName: 'my_tool',
  ///   toolDescription: 'A helpful tool',
  /// );
  /// ```
  AgentTool asTool({
    String? toolName,
    String? toolDescription,
    String inputParameter = 'query',
    String inputDescription = 'The input query or request',
  }) {
    return AgentTool(
      agent: this,
      toolName: toolName,
      toolDescription: toolDescription,
      inputParameter: inputParameter,
      inputDescription: inputDescription,
    );
  }
}
