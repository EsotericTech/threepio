import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/adk/core/base_agent.dart';
import 'package:threepio_core/src/adk/events/agent_event.dart';
import 'package:threepio_core/src/adk/tools/agent_tool.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() {
  group('AgentTool', () {
    late _MockAgent mockAgent;

    setUp(() {
      mockAgent = _MockAgent();
    });

    test('creates with default name from agent name', () async {
      final tool = AgentTool(agent: mockAgent);

      final info = await tool.info();

      expect(info.function.name, 'mock_agent');
    });

    test('creates with custom name', () async {
      final tool = AgentTool(
        agent: mockAgent,
        toolName: 'custom_tool',
      );

      final info = await tool.info();

      expect(info.function.name, 'custom_tool');
    });

    test('creates with custom description', () async {
      final tool = AgentTool(
        agent: mockAgent,
        toolDescription: 'Custom description',
      );

      final info = await tool.info();

      expect(info.function.description, 'Custom description');
    });

    test('uses agent description by default', () async {
      final tool = AgentTool(agent: mockAgent);

      final info = await tool.info();

      expect(info.function.description, mockAgent.description);
    });

    test('has input parameter', () async {
      final tool = AgentTool(agent: mockAgent);

      final info = await tool.info();
      final params = info.function.parameters!;

      expect(params.properties.containsKey('query'), true);
      expect(params.required, contains('query'));
    });

    test('supports custom input parameter name', () async {
      final tool = AgentTool(
        agent: mockAgent,
        inputParameter: 'task',
        inputDescription: 'The task to perform',
      );

      final info = await tool.info();
      final params = info.function.parameters!;

      expect(params.properties.containsKey('task'), true);
      expect(params.required, contains('task'));
    });

    test('supports context parameter', () async {
      final tool = AgentTool(
        agent: mockAgent,
        contextParameter: 'context',
        contextDescription: 'Additional context',
      );

      final info = await tool.info();
      final params = info.function.parameters!;

      expect(params.properties.containsKey('context'), true);
    });

    test('run invokes agent with input', () async {
      final tool = AgentTool(agent: mockAgent);

      final args = jsonEncode({'query': 'Hello, agent!'});
      final result = await tool.run(args);

      expect(result, 'Mock response to: Hello, agent!');
    });

    test('run includes context as system message', () async {
      final tool = AgentTool(
        agent: mockAgent,
        contextParameter: 'context',
      );

      final args = jsonEncode({
        'query': 'Do something',
        'context': 'Important background',
      });

      await tool.run(args);

      // The mock agent records the messages
      expect(mockAgent.lastMessages.length, 2);
      expect(mockAgent.lastMessages[0].role, RoleType.system);
      expect(mockAgent.lastMessages[0].content, contains('Important background'));
      expect(mockAgent.lastMessages[1].content, 'Do something');
    });

    test('exposes wrapped agent', () {
      final tool = AgentTool(agent: mockAgent);

      expect(tool.agent, mockAgent);
    });

    test('sanitizes name correctly', () async {
      final agentWithBadName = _MockAgent(name: 'My Agent (v2.0)!');
      final tool = AgentTool(agent: agentWithBadName);

      final info = await tool.info();

      expect(info.function.name, 'my_agent_v2_0');
    });
  });

  group('AgentToTool extension', () {
    test('asTool creates AgentTool', () {
      final agent = _MockAgent();
      final tool = agent.asTool();

      expect(tool, isA<AgentTool>());
      expect(tool.agent, agent);
    });

    test('asTool accepts customization', () async {
      final agent = _MockAgent();
      final tool = agent.asTool(
        toolName: 'custom',
        toolDescription: 'Custom desc',
        inputParameter: 'input',
        inputDescription: 'The input',
      );

      final info = await tool.info();

      expect(info.function.name, 'custom');
      expect(info.function.description, 'Custom desc');
      expect(info.function.parameters!.properties.containsKey('input'), true);
    });
  });
}

/// Mock agent for testing
class _MockAgent implements BaseAgent {
  _MockAgent({String? name}) : _name = name;

  final String? _name;
  List<Message> lastMessages = [];

  @override
  String get name => _name ?? 'mock_agent';

  @override
  String get description => 'A mock agent for testing';

  @override
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Message> invoke(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    lastMessages = messages;
    final userMessage = messages.lastWhere((m) => m.role == RoleType.user);
    return Message.assistant('Mock response to: ${userMessage.content}');
  }

  @override
  BaseAgent copyWith({String? name, String? description}) => this;
}
