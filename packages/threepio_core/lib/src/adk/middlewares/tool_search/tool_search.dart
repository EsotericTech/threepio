/// A middleware that hides a large set of tools until the model searches
/// for them.
///
/// Port of eino `adk/middlewares/dynamictool/toolsearch` (classic messages;
/// the agentic path is P13).
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/tool/enhanced_tool.dart';
import '../../../components/tool/invokable_tool.dart';
import '../../../components/tool/tool_options.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_info.dart';
import '../../../schema/tool_result.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../internal/go_compat.dart';
import '../internal/run_local.dart';
import 'prompt.dart';

/// The name of the search tool. Port of `toolSearchToolName`.
const String toolSearchToolName = 'tool_search';

const int _defaultMaxResults = 5;

const String _initializedKey = '__toolsearch_initialized__';

/// The `extra` key that marks the reminder message. Port of
/// `toolSearchReminderExtraKey`.
@visibleForTesting
const String toolSearchReminderExtraKey = '__toolsearch_reminder__';

/// Hides [dynamicTools] from the model until it finds them with the
/// `tool_search` tool.
///
/// Port of eino `toolsearch.New`. `beforeAgent` adds `tool_search` and the
/// dynamic tools to the agent (so that they can run), and every model call
/// gets a reminder message listing the dynamic tools' names (inserted after
/// the system messages, once). Then:
///
/// * by default (client-side search) the dynamic tools are left out of the
///   tools the model is told about, until a `tool_search` result in the
///   conversation names them; the query is keywords (`+word` must match; a
///   name part matches best, then the name, then the description) or
///   `select:name1,name2`;
/// * with [useModelToolSearch] the model searches itself: the dynamic tools
///   go to `ChatModelOptions.deferredTools`, `tool_search` is left out of
///   the tools and passed as `ChatModelOptions.toolSearchTool`.
///
/// Changing the tool list between calls defeats a model's prompt cache.
final class ToolSearchMiddleware extends ChatModelAgentMiddleware {
  ToolSearchMiddleware._({
    required this.dynamicTools,
    required this.useModelToolSearch,
    required Map<String, ToolInfo> infos,
    required this.reminder,
  }) : _infos = infos;

  /// A middleware for [dynamicTools].
  ///
  /// Port of eino `toolsearch.New`; asynchronous because a tool's info is.
  /// Throws [ArgumentError] for no tools or two tools with one name, and
  /// [ThreepioException] when a tool's info fails.
  static Future<ToolSearchMiddleware> create({
    required List<BaseTool> dynamicTools,
    bool useModelToolSearch = false,
  }) async {
    if (dynamicTools.isEmpty) throw ArgumentError.value(dynamicTools, 'dynamicTools', 'tools is required');
    final infos = <String, ToolInfo>{};
    for (final tool in dynamicTools) {
      final ToolInfo info;
      try {
        info = await tool.info();
      } on Object catch (error) {
        throw ThreepioException('failed to get dynamic tool info: ${goValueString(error)}', cause: error);
      }
      if (infos.containsKey(info.name)) {
        throw ArgumentError('duplicate dynamic tool name: ${info.name}');
      }
      infos[info.name] = info;
    }
    final reminder = StringBuffer('<available-deferred-tools>');
    for (final name in infos.keys) {
      reminder.write('\n$name');
    }
    reminder.write('\n</available-deferred-tools>');
    return ToolSearchMiddleware._(
      dynamicTools: List.unmodifiable(dynamicTools),
      useModelToolSearch: useModelToolSearch,
      infos: infos,
      reminder: reminder.toString(),
    );
  }

  /// The tools that are searched for.
  final List<BaseTool> dynamicTools;

  /// Whether the model searches itself.
  final bool useModelToolSearch;

  /// The text of the reminder message.
  final String reminder;

  final Map<String, ToolInfo> _infos;

  @override
  FutureOr<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) {
    agent.tools = [
      ...agent.tools,
      if (useModelToolSearch) ModelToolSearchTool(_infos) else ToolSearchTool(_infos),
      ...dynamicTools,
    ];
    if (useModelToolSearch) agent.toolSearchTool = toolSearchToolInfo();
    return (ctx, agent);
  }

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    state.messages = ensureReminder(state.messages);

    final (found, initialized) = tryRunLocalValue(ctx, _initializedKey);
    if (!(found && initialized == true)) {
      trySetRunLocalValue(ctx, _initializedKey, true);
      if (useModelToolSearch) {
        final deferred = [
          for (final info in state.toolInfos)
            if (_infos.containsKey(info.name)) info,
        ];
        state
          // Go's extractDynamicTools returns nil when there are none.
          ..deferredToolInfos = deferred.isEmpty ? null : deferred
          ..toolInfos = [
            for (final info in state.toolInfos)
              if (!_infos.containsKey(info.name) && info.name != toolSearchToolName) info,
          ];
      } else {
        state.toolInfos = [
          for (final info in state.toolInfos)
            if (!_infos.containsKey(info.name)) info,
        ];
      }
    }

    if (!useModelToolSearch) {
      final existing = {for (final info in state.toolInfos) info.name};
      final added = <ToolInfo>[];
      for (final message in state.messages) {
        if (message.role != RoleType.tool || message.toolName != toolSearchToolName) continue;
        final List<Object?>? matches;
        try {
          final decoded = jsonDecode(message.content);
          matches = decoded is Map ? decoded['matches'] as List<Object?>? : null;
          // Go skips a result it cannot unmarshal.
          // ignore: avoid_catching_errors
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
        // Go fails the whole unmarshal on a name that is not a string.
        if (matches != null && matches.any((name) => name is! String)) continue;
        for (final name in (matches ?? const <Object?>[]).cast<String>()) {
          if (existing.contains(name)) continue;
          final info = _infos[name];
          if (info != null) {
            added.add(info);
            existing.add(name);
          }
        }
      }
      if (added.isNotEmpty) state.toolInfos = [...state.toolInfos, ...added];
    }
    return (ctx, state);
  }

  /// [messages] with the reminder inserted before the first message that is
  /// not a system message, unless it is there already. Port of
  /// `ensureReminder`.
  @visibleForTesting
  List<Message> ensureReminder(List<Message> messages) {
    for (final message in messages) {
      if (message.extra?[toolSearchReminderExtraKey] == true) return messages;
    }
    final reminderMessage =
        Message.user(reminder).copyWith(extra: {toolSearchReminderExtraKey: true});
    final result = <Message>[];
    var inserted = false;
    for (final message in messages) {
      if (!inserted && message.role != RoleType.system) {
        inserted = true;
        result.add(reminderMessage);
      }
      result.add(message);
    }
    if (!inserted) result.add(reminderMessage);
    return result;
  }
}

/// The info of the `tool_search` tool. Port of `getToolSearchToolInfo`.
ToolInfo toolSearchToolInfo() => ToolInfo.fromParams(
      name: toolSearchToolName,
      desc: toolSearchDescription(),
      params: const {
        'query': ParameterInfo(
          type: DataType.string,
          desc: 'Query to find deferred tools. Use "select:<tool_name>" for direct selection, or keywords to search.',
          required: true,
        ),
        'max_results': ParameterInfo(
          type: DataType.integer,
          desc: 'Maximum number of results to return (default: 5)',
        ),
      },
    );

/// The client-side `tool_search` tool: answers `{"matches": [names]}`.
/// Port of eino `toolSearchTool`.
@visibleForTesting
final class ToolSearchTool extends InvokableTool {
  /// The tool over [tools].
  ToolSearchTool(this.tools);

  /// The searchable tools by name.
  final Map<String, ToolInfo> tools;

  @override
  Future<ToolInfo> info() async => toolSearchToolInfo();

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async {
    final matches = searchTools(argumentsJson, tools);
    return goJsonEncode({'matches': matches.isEmpty ? null : [for (final info in matches) info.name]});
  }

  @override
  Future<String> run(String argumentsJson) => invokableRun(RunContext.background(), argumentsJson);
}

/// The `tool_search` tool for a model with native tool search: answers with
/// a tool-search-result part. Port of eino `modelToolSearchTool`.
@visibleForTesting
final class ModelToolSearchTool implements EnhancedInvokableTool {
  /// The tool over [tools].
  ModelToolSearchTool(this.tools);

  /// The searchable tools by name.
  final Map<String, ToolInfo> tools;

  @override
  Future<ToolInfo> info() async => toolSearchToolInfo();

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      ToolResult([
        ToolOutputPart(
          type: ToolPartType.toolSearchResult,
          toolSearchResult: ToolSearchResult(tools: searchTools(argument.text, tools)),
        ),
      ]);
}

/// The tools a `tool_search` call finds. Port of `search`.
@visibleForTesting
List<ToolInfo> searchTools(String argumentsJson, Map<String, ToolInfo> tools) {
  final String rawQuery;
  int? maxResultsArgument;
  try {
    final decoded = jsonDecode(argumentsJson);
    if (decoded is! Map) throw const FormatException('arguments are not a JSON object');
    final query = decoded['query'];
    if (query != null && query is! String) throw const FormatException('"query" is not a string');
    rawQuery = (query as String?) ?? '';
    final max = decoded['max_results'];
    maxResultsArgument = switch (max) {
      null => null,
      final int value => value,
      final double value when value == value.truncateToDouble() => value.toInt(),
      _ => throw const FormatException('"max_results" is not an integer'),
    };
  } on FormatException catch (error) {
    throw ThreepioException(
      'failed to unmarshal tool search arguments: ${error.message}',
      cause: error,
    );
  }
  final query = rawQuery.trim();
  if (query.isEmpty) throw const ThreepioException('query is required');
  final maxResults =
      maxResultsArgument != null && maxResultsArgument > 0 ? maxResultsArgument : _defaultMaxResults;

  final List<String> matches;
  if (query.startsWith('select:')) {
    matches = [
      for (final raw in query.substring('select:'.length).split(','))
        if (raw.trim().isNotEmpty && tools.containsKey(raw.trim())) raw.trim(),
    ];
  } else {
    matches = keywordSearch(query, maxResults, tools);
  }
  return [
    for (final name in matches)
      if (tools[name] != null) tools[name]!,
  ];
}

/// The names of the [maxResults] best tools for the keywords of [query].
/// Port of `keywordSearch`.
@visibleForTesting
List<String> keywordSearch(String query, int maxResults, Map<String, ToolInfo> tools) {
  final keywords = _parseKeywords(query);
  if (keywords.isEmpty) return const [];
  final scored = <(String, int)>[];
  for (final MapEntry(key: name, value: info) in tools.entries) {
    final nameParts = splitToolName(name);
    final nameLower = name.toLowerCase();
    final descLower = (info.desc ?? '').toLowerCase();
    var total = 0;
    var allRequiredFound = true;
    for (final (word, required) in keywords) {
      final keyword = word.toLowerCase();
      var score = 0;
      for (final part in nameParts) {
        final partLower = part.toLowerCase();
        if (partLower == keyword) {
          score = score > 10 ? score : 10;
        } else if (partLower.contains(keyword)) {
          score = score > 5 ? score : 5;
        }
      }
      if (nameLower.contains(keyword)) score = score > 3 ? score : 3;
      if (descLower.isNotEmpty && descLower.contains(keyword)) score = score > 2 ? score : 2;
      if (required && score == 0) {
        allRequiredFound = false;
        break;
      }
      total += score;
    }
    if (!allRequiredFound) continue;
    if (total > 0) scored.add((name, total));
  }
  scored.sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
  return [for (final (name, _) in scored.take(maxResults)) name];
}

/// The keywords of [query]; `+word` is required. Port of `parseKeywords`.
List<(String, bool)> _parseKeywords(String query) {
  final keywords = <(String, bool)>[];
  for (final part in goFields(query)) {
    if (part.startsWith('+')) {
      if (part.length > 1) keywords.add((part.substring(1), true));
    } else {
      keywords.add((part, false));
    }
  }
  return keywords;
}

/// The parts of a tool name: split at `__`, `_` and camel-case boundaries.
/// Port of `splitToolName`.
@visibleForTesting
List<String> splitToolName(String name) => [
      for (final segment in name.split('__'))
        for (final part in segment.split('_'))
          if (part.isNotEmpty) ...splitCamelCase(part),
    ];

bool _isUpper(String ch) => ch.toUpperCase() == ch && ch.toLowerCase() != ch;

bool _isLower(String ch) => ch.toLowerCase() == ch && ch.toUpperCase() != ch;

/// The words of a camelCase or PascalCase string (`HTTPServer` →
/// `HTTP`, `Server`). Port of `splitCamelCase`.
@visibleForTesting
List<String> splitCamelCase(String s) {
  if (s.isEmpty) return const [];
  final runes = [for (final rune in s.runes) String.fromCharCode(rune)];
  final parts = <String>[];
  var start = 0;
  for (var i = 1; i < runes.length; i++) {
    if (!_isUpper(runes[i])) continue;
    if (_isLower(runes[i - 1])) {
      parts.add(runes.sublist(start, i).join());
      start = i;
    } else if (i + 1 < runes.length && _isLower(runes[i + 1])) {
      parts.add(runes.sublist(start, i).join());
      start = i;
    }
  }
  parts.add(runes.sublist(start).join());
  return parts;
}
