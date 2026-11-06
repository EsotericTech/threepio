// Mirror of doc/NEW_FEATURES.md, section 1, "### Using with the legacy `Agent` (ReAct loop)".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:threepio_core/threepio_core.dart';

// A tool the model can call
class CalculatorTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.simple(
        name: 'calculate',
        description: 'Perform arithmetic calculations',
        properties: {
          'expression': JSONSchemaProperty.string(
            description: 'Math expression like "5 + 3"',
          ),
        },
        required: ['expression'],
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final args = jsonDecode(argumentsJson) as Map<String, Object?>;
    final expression = args['expression']! as String;
    // Two operands and one operator are enough for this example
    final match = RegExp(r'^\s*(-?[\d.]+)\s*([-+*/])\s*(-?[\d.]+)\s*$')
        .firstMatch(expression);
    if (match == null) return 'Cannot evaluate "$expression"';
    final a = double.parse(match.group(1)!);
    final b = double.parse(match.group(3)!);
    final result = switch (match.group(2)) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      _ => a / b,
    };
    return result.toString();
  }
}

Future<void> runCalculatorAgent(ToolCallingChatModel model) async {
  // register takes effect at once (await registry.findTool(name) to look
  // a tool up by name)
  final registry = ToolRegistry();
  registry.register(CalculatorTool());

  final agent = Agent(
    model: model,
    toolRegistry: registry,
    config: const AgentConfig(
      maxIterations: 5, // model calls (default 10)
      maxToolCalls: 10, // tool calls in all (default 20)
    ),
  );

  // Run agent
  final response = await agent.run([
    Message.system('You are a helpful assistant with a calculator.'),
    Message.user('What is 25 * 4?'),
  ]);

  print(response.content); // "25 multiplied by 4 is 100."
}
