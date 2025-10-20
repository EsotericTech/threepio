import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';
import 'package:threepio_core/src/components/tool/examples/weather_tool.dart';
import 'package:threepio_core/src/components/tool/tool_registry.dart';

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
}
