import 'package:threepio_core/src/schema/tool_info.dart';

import 'invokable_tool.dart';

/// Registry for managing and looking up tools
///
/// Provides a central place to register tools and retrieve them by name.
/// Supports both invokable and streamable tools.
///
/// Example usage:
/// ```dart
/// final registry = ToolRegistry();
/// registry.register(WeatherTool());
/// registry.register(CalculatorTool());
///
/// final tool = registry.getTool('get_weather');
/// final result = await tool.run('{"location": "NYC"}');
/// ```
class ToolRegistry {
  ToolRegistry({List<BaseTool>? tools}) {
    if (tools != null) {
      for (final tool in tools) {
        register(tool);
      }
    }
  }

  final Map<String, BaseTool> _tools = {};

  /// Register a tool
  ///
  /// Adds the tool to the registry. If a tool with the same name
  /// already exists, it will be replaced.
  void register(BaseTool tool) {
    _getToolNameSync(tool).then((name) {
      _tools[name] = tool;
    });
  }

  /// Register multiple tools at once
  void registerAll(List<BaseTool> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  /// Get a tool by name
  ///
  /// Returns null if the tool is not found.
  BaseTool? getTool(String name) {
    return _tools[name];
  }

  /// Get all registered tool names
  List<String> getToolNames() {
    return _tools.keys.toList();
  }

  /// Get all registered tools
  List<BaseTool> getAllTools() {
    return _tools.values.toList();
  }

  /// Get tool information for all registered tools
  ///
  /// Returns a list of [ToolInfo] objects that can be passed
  /// to the chat model for tool calling.
  Future<List<ToolInfo>> getToolInfoList() async {
    final infos = <ToolInfo>[];
    for (final tool in _tools.values) {
      infos.add(await tool.info());
    }
    return infos;
  }

  /// Check if a tool is registered
  bool hasTool(String name) {
    return _tools.containsKey(name);
  }

  /// Unregister a tool
  void unregister(String name) {
    _tools.remove(name);
  }

  /// Clear all registered tools
  void clear() {
    _tools.clear();
  }

  /// Get the number of registered tools
  int get count => _tools.length;

  /// Helper to get tool name synchronously
  Future<String> _getToolNameSync(BaseTool tool) async {
    final info = await tool.info();
    return info.function.name;
  }
}
