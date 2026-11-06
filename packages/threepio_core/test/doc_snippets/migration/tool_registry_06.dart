// Mirror of doc/MIGRATION.md, break 5: ToolRegistry.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

Future<void> registerTool(BaseTool weatherTool) async {
final registry = ToolRegistry()..register(weatherTool);
print(registry.count); // 1, at once

// Before 0.9: await Future<void>.delayed(Duration.zero) and registry.getTool(…)
final tool = await registry.findTool('get_weather');
print(tool != null);
}
