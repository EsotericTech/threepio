import 'dart:convert';

import 'package:threepio_core/src/schema/tool_info.dart';

import '../invokable_tool.dart';

/// A mock weather tool for testing purposes
///
/// Returns simulated weather data for any location.
/// In a real implementation, this would call a weather API.
///
/// Example usage:
/// ```dart
/// final weather = WeatherTool();
/// final result = await weather.run('{"location": "New York", "units": "celsius"}');
/// print(result); // {"location": "New York", "temperature": 22, ...}
/// ```
class WeatherTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo(
      function: FunctionInfo(
        name: 'get_weather',
        description: 'Get the current weather for a specified location',
        parameters: JSONSchema(
          type: 'object',
          properties: {
            'location': JSONSchemaProperty(
              type: 'string',
              description: 'The city and state, e.g. San Francisco, CA',
            ),
            'units': JSONSchemaProperty(
              type: 'string',
              description: 'Temperature units',
              enumValues: ['celsius', 'fahrenheit'],
            ),
          },
          required: ['location'],
          additionalProperties: false,
        ),
      ),
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;

    final location = args['location'] as String;
    final units = (args['units'] as String?) ?? 'fahrenheit';

    // Simulate API delay
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Generate mock weather data based on location hash
    final locationHash = location.hashCode.abs();
    final temperature = units == 'celsius'
        ? (locationHash % 30) + 10 // 10-40°C
        : (locationHash % 60) + 50; // 50-110°F

    final conditions = ['sunny', 'cloudy', 'partly cloudy', 'rainy', 'stormy'];
    final condition = conditions[locationHash % conditions.length];

    final humidity = (locationHash % 40) + 30; // 30-70%
    final windSpeed = (locationHash % 20) + 5; // 5-25 mph

    return jsonEncode({
      'location': location,
      'temperature': temperature,
      'units': units,
      'condition': condition,
      'humidity': humidity,
      'wind_speed': windSpeed,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
}
