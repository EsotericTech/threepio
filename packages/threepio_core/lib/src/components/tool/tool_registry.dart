import 'dart:async';

import '../../schema/tool_info.dart';
import 'invokable_tool.dart';

/// Registry for managing and looking up tools
///
/// Provides a central place to register tools and retrieve them by name.
/// Supports both invokable and streamable tools.
///
/// A tool's name comes from [BaseTool.info], which is asynchronous. [register]
/// records the tool at once and asks for its name; the asynchronous accessors
/// ([getToolInfoList], [findTool], [ready]) wait for every pending name, so
/// they are correct immediately after [register]. The synchronous lookups by
/// name ([getTool], [hasTool], [getToolNames]) see a tool as soon as its
/// `info()` has completed.
///
/// Example usage:
/// ```dart
/// final registry = ToolRegistry();
/// registry.register(WeatherTool());
/// registry.register(CalculatorTool());
///
/// final tool = await registry.findTool('get_weather');
/// final result = await tool.run('{"location": "NYC"}');
/// ```
class ToolRegistry {
  ToolRegistry({List<BaseTool>? tools}) {
    if (tools != null) {
      registerAll(tools);
    }
  }

  /// Every registration that is still in effect, in registration order.
  final List<_Registration> _registrations = [];

  /// Register a tool
  ///
  /// Adds the tool to the registry. If a tool with the same name
  /// already exists, it will be replaced.
  ///
  /// The tool is part of [getAllTools], [count] and the asynchronous
  /// accessors right away. If its `info()` fails, [ready] and the other
  /// asynchronous accessors rethrow the error until the registry is cleared.
  void register(BaseTool tool) {
    final registration = _Registration(tool);
    _registrations.add(registration);

    registration.name.then(
      (name) {
        final index = _registrations.indexOf(registration);
        if (index < 0) return;

        if (registration.unregisteredNames.contains(name)) {
          _registrations.removeAt(index);
          return;
        }

        // The later registration of a name wins, in whatever order the two
        // `info()` calls completed.
        final sameName = _registrations.indexWhere(
          (other) => other.resolvedName == name,
        );
        if (sameName > index) {
          _registrations.removeAt(index);
          return;
        }
        if (sameName >= 0) _registrations.removeAt(sameName);
        registration.resolvedName = name;
      },
      // Reported to whoever awaits [ready]; nothing to do here.
      onError: (Object _) {},
    );
  }

  /// Register multiple tools at once
  void registerAll(List<BaseTool> tools) {
    tools.forEach(register);
  }

  /// Completes when every registered tool has reported its name.
  ///
  /// Throws the error of a tool whose `info()` failed.
  Future<void> get ready async {
    for (final registration in List.of(_registrations)) {
      await registration.name;
    }
  }

  /// Get a tool by name
  ///
  /// Returns null if the tool is not found, which includes a tool that was
  /// registered a moment ago and has not reported its name yet. Use
  /// [findTool] to wait for pending registrations.
  BaseTool? getTool(String name) {
    for (final registration in _registrations) {
      if (registration.resolvedName == name) return registration.tool;
    }
    return null;
  }

  /// Get a tool by name, after every pending registration has completed.
  ///
  /// Returns null if no registered tool has that name.
  Future<BaseTool?> findTool(String name) async {
    await ready;
    return getTool(name);
  }

  /// Get the names of the tools that have reported their name
  List<String> getToolNames() {
    return [
      for (final registration in _registrations)
        if (registration.resolvedName case final name?) name,
    ];
  }

  /// Get all registered tools, in registration order
  List<BaseTool> getAllTools() {
    return [for (final registration in _registrations) registration.tool];
  }

  /// Get tool information for all registered tools
  ///
  /// Returns a list of [ToolInfo] objects that can be passed
  /// to the chat model for tool calling.
  Future<List<ToolInfo>> getToolInfoList() async {
    await ready;
    return [for (final tool in getAllTools()) await tool.info()];
  }

  /// Check if a tool with this name is registered and has reported its name
  bool hasTool(String name) {
    return getTool(name) != null;
  }

  /// Unregister a tool
  ///
  /// Also removes a tool of that name whose registration is still pending.
  void unregister(String name) {
    _registrations.removeWhere((r) => r.resolvedName == name);
    for (final registration in _registrations) {
      if (registration.resolvedName == null) {
        registration.unregisteredNames.add(name);
      }
    }
  }

  /// Clear all registered tools
  void clear() {
    _registrations.clear();
  }

  /// Get the number of registered tools
  int get count => _registrations.length;
}

/// One [ToolRegistry.register] call.
class _Registration {
  _Registration(this.tool)
      : name = Future.sync(tool.info).then((info) => info.function.name);

  final BaseTool tool;

  /// The tool's name, once `info()` has returned it.
  final Future<String> name;

  /// [name] after it completed, for the synchronous lookups.
  String? resolvedName;

  /// Names passed to [ToolRegistry.unregister] while [name] was pending.
  final Set<String> unregisteredNames = {};
}
