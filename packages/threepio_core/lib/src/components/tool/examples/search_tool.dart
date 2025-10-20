import 'dart:convert';

import 'package:threepio_core/src/schema/tool_info.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

import '../invokable_tool.dart';

/// A mock search tool for testing purposes
///
/// Returns simulated search results for any query.
/// In a real implementation, this would call a search API.
///
/// Example usage:
/// ```dart
/// final search = SearchTool();
/// final result = await search.run('{"query": "Dart programming"}');
/// print(result); // {"results": [...]}
/// ```
class SearchTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo(
      function: FunctionInfo(
        name: 'search',
        description: 'Search for information on the internet',
        parameters: JSONSchema(
          type: 'object',
          properties: {
            'query': JSONSchemaProperty(
              type: 'string',
              description: 'The search query',
            ),
            'max_results': JSONSchemaProperty(
              type: 'integer',
              description: 'Maximum number of results to return (default: 5)',
            ),
          },
          required: ['query'],
          additionalProperties: false,
        ),
      ),
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;

    final query = args['query'] as String;
    final maxResults = (args['max_results'] as int?) ?? 5;

    // Simulate API delay
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Generate mock search results
    final results = List.generate(
      maxResults,
      (index) => {
        'title': 'Result ${index + 1} for "$query"',
        'url': 'https://example.com/result${index + 1}',
        'snippet':
            'This is a mock search result about $query. It contains relevant information that would help answer questions about the topic.',
        'rank': index + 1,
      },
    );

    return jsonEncode({
      'query': query,
      'results': results,
      'total_results': maxResults,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
}

/// A streaming version of the search tool
///
/// Demonstrates how to implement a tool that streams results.
class StreamingSearchTool extends StreamableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo(
      function: FunctionInfo(
        name: 'streaming_search',
        description: 'Search for information with streaming results',
        parameters: JSONSchema(
          type: 'object',
          properties: {
            'query': JSONSchemaProperty(
              type: 'string',
              description: 'The search query',
            ),
            'max_results': JSONSchemaProperty(
              type: 'integer',
              description: 'Maximum number of results to return (default: 5)',
            ),
          },
          required: ['query'],
          additionalProperties: false,
        ),
      ),
    );
  }

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;

    final query = args['query'] as String;
    final maxResults = (args['max_results'] as int?) ?? 5;

    // Create a stream that emits results one by one
    final stream = Stream<String>.periodic(
      const Duration(milliseconds: 100),
      (index) {
        if (index >= maxResults) {
          throw StateError('Stream complete');
        }

        final result = {
          'title': 'Result ${index + 1} for "$query"',
          'url': 'https://example.com/result${index + 1}',
          'snippet':
              'This is a mock search result about $query. It contains relevant information.',
          'rank': index + 1,
        };

        return jsonEncode({'result': result, 'index': index});
      },
    ).take(maxResults);

    return StreamReader.fromStream(stream);
  }
}
