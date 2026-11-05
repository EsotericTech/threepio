import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';
import 'package:threepio_core/src/components/tool/examples/weather_tool.dart';
import 'package:threepio_core/src/components/tool/invokable_tool.dart';
import 'package:threepio_core/src/components/tool/tool_executor.dart';
import 'package:threepio_core/src/components/tool/tool_registry.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

void main() {
  group('ToolRegistry', () {
    late ToolRegistry registry;

    setUp(() {
      registry = ToolRegistry();
    });

    test('starts empty', () {
      expect(registry.count, equals(0));
      expect(registry.getToolNames(), isEmpty);
      expect(registry.getAllTools(), isEmpty);
    });

    test('registers a tool', () async {
      final tool = CalculatorTool();
      registry.register(tool);

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(registry.count, equals(1));
      expect(registry.hasTool('calculator'), isTrue);
    });

    test('registers multiple tools', () async {
      final calc = CalculatorTool();
      final weather = WeatherTool();

      registry.register(calc);
      registry.register(weather);

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(registry.count, equals(2));
      expect(registry.hasTool('calculator'), isTrue);
      expect(registry.hasTool('get_weather'), isTrue);
    });

    test('registers tools via constructor', () async {
      final newRegistry = ToolRegistry(
        tools: [
          CalculatorTool(),
          WeatherTool(),
        ],
      );

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(newRegistry.count, equals(2));
    });

    test('retrieves tool by name', () async {
      final tool = CalculatorTool();
      registry.register(tool);

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final retrieved = registry.getTool('calculator');
      expect(retrieved, isNotNull);
      expect(retrieved, same(tool));
    });

    test('returns null for unknown tool', () {
      final retrieved = registry.getTool('unknown_tool');
      expect(retrieved, isNull);
    });

    test('gets all tool names', () async {
      registry.register(CalculatorTool());
      registry.register(WeatherTool());

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final names = registry.getToolNames();
      expect(names, hasLength(2));
      expect(names, contains('calculator'));
      expect(names, contains('get_weather'));
    });

    test('gets all tools', () async {
      final calc = CalculatorTool();
      final weather = WeatherTool();

      registry.register(calc);
      registry.register(weather);

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final tools = registry.getAllTools();
      expect(tools, hasLength(2));
      expect(tools, contains(calc));
      expect(tools, contains(weather));
    });

    test('gets tool info list', () async {
      registry.register(CalculatorTool());
      registry.register(WeatherTool());

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final infoList = await registry.getToolInfoList();
      expect(infoList, hasLength(2));
      expect(infoList.map((i) => i.function.name), contains('calculator'));
      expect(infoList.map((i) => i.function.name), contains('get_weather'));
    });

    test('unregisters a tool', () async {
      registry.register(CalculatorTool());

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(registry.hasTool('calculator'), isTrue);

      registry.unregister('calculator');
      expect(registry.hasTool('calculator'), isFalse);
      expect(registry.count, equals(0));
    });

    test('clears all tools', () async {
      registry.register(CalculatorTool());
      registry.register(WeatherTool());

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(registry.count, equals(2));

      registry.clear();
      expect(registry.count, equals(0));
      expect(registry.getToolNames(), isEmpty);
    });

    test('replaces tool with same name', () async {
      final tool1 = CalculatorTool();
      final tool2 = CalculatorTool();

      registry.register(tool1);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(registry.getTool('calculator'), same(tool1));

      registry.register(tool2);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(registry.getTool('calculator'), same(tool2));
      expect(registry.count, equals(1));
    });
  });

  // Before the fix, register() stored the tool from a fire-and-forget
  // `info().then(...)`, so a registry that was used right after registering
  // looked empty.
  group('ToolRegistry registration', () {
    test('a registered tool counts and is listed at once', () {
      final calculator = CalculatorTool();
      final registry = ToolRegistry()..register(calculator);

      expect(registry.count, 1);
      expect(registry.getAllTools(), [calculator]);
    });

    test('getToolInfoList right after register returns every tool', () async {
      final registry = ToolRegistry(tools: [CalculatorTool(), WeatherTool()]);

      final infos = await registry.getToolInfoList();

      expect(infos.map((i) => i.function.name), ['calculator', 'get_weather']);
    });

    test('findTool right after register finds the tool', () async {
      final calculator = CalculatorTool();
      final registry = ToolRegistry()..register(calculator);

      expect(await registry.findTool('calculator'), same(calculator));
      expect(await registry.findTool('missing'), isNull);
    });

    test('getTool finds the tool once ready has completed', () async {
      final slow = _NamedTool('slow', delay: const Duration(milliseconds: 5));
      final registry = ToolRegistry()..register(slow);
      expect(registry.getTool('slow'), isNull);

      await registry.ready;

      expect(registry.getTool('slow'), same(slow));
      expect(registry.hasTool('slow'), isTrue);
      expect(registry.getToolNames(), ['slow']);
    });

    test('ToolExecutor finds a tool registered a moment ago', () async {
      final registry = ToolRegistry()..register(CalculatorTool());
      final executor = ToolExecutor(registry: registry);

      final result = await executor.executeToolCall(
        const ToolCall(
          id: 'call_1',
          function: FunctionCall(
            name: 'calculator',
            arguments: '{"operation": "add", "a": 1, "b": 2}',
          ),
        ),
      );

      expect(result.error, isNull);
      expect(result.output, contains('3'));
    });

    test('the later registration of a name wins, whichever resolves first',
        () async {
      final first = _NamedTool('same', delay: const Duration(milliseconds: 5));
      final second = _NamedTool('same');
      final registry = ToolRegistry()
        ..register(first)
        ..register(second);

      await registry.ready;

      expect(registry.getTool('same'), same(second));
      expect(registry.getAllTools(), [second]);
      expect(registry.count, 1);
    });

    test('unregister also removes a registration that is still pending',
        () async {
      final registry = ToolRegistry()
        ..register(_NamedTool('gone'))
        ..register(_NamedTool('kept'))
        ..unregister('gone');

      await registry.ready;

      expect(registry.getToolNames(), ['kept']);
      expect(registry.count, 1);
    });

    test('clear drops pending registrations', () async {
      final registry = ToolRegistry()
        ..register(_NamedTool('a'))
        ..clear();

      await registry.ready;
      await Future<void>.delayed(Duration.zero);

      expect(registry.count, 0);
      expect(registry.getToolNames(), isEmpty);
      expect(await registry.getToolInfoList(), isEmpty);
    });

    test('a tool whose info() fails is reported by the async accessors',
        () async {
      final registry = ToolRegistry()..register(_BrokenTool());

      await expectLater(registry.ready, throwsStateError);
      await expectLater(registry.getToolInfoList(), throwsStateError);
      await expectLater(registry.findTool('any'), throwsStateError);

      registry.clear();
      await expectLater(registry.ready, completes);
    });
  });
}

class _NamedTool extends BaseTool {
  _NamedTool(this.name, {this.delay = Duration.zero});

  final String name;
  final Duration delay;

  @override
  Future<ToolInfo> info() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return ToolInfo.simple(
      name: name,
      description: 'test tool',
      properties: const {},
    );
  }
}

class _BrokenTool extends BaseTool {
  @override
  Future<ToolInfo> info() => throw StateError('no info');
}
