/// A middleware that shows the model the contents of agents.md files.
///
/// Port of eino `adk/middlewares/agentsmd` (classic messages; the agentic
/// path is P13).
library;

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../filesystem/backend.dart';
import '../internal/go_compat.dart';
import '../internal/run_local.dart';
import 'loader.dart';

export 'loader.dart' show AgentsMdWarningCallback;

/// The run-local key of the loaded content. Port of `agentsMDCacheKey`.
const String _cacheKey = '__agentsmd_content_cache__';

/// The `extra` key that marks the injected message. Port of
/// `agentsMDExtraKey`.
@visibleForTesting
const String agentsMdExtraKey = '__agentsmd_content__';

/// Puts the contents of agents.md files in front of the conversation, for
/// every model call.
///
/// Port of eino `agentsmd.New`. Before each model call the files are loaded
/// through [backend] (once per run: the text is kept as a run-local value)
/// and inserted as one user message before the first user message, marked
/// in its `extra` so that it is inserted only once. A file may pull in
/// others with `@path/to/file` (relative to the file; a path without `/`
/// must end in `.md`, `.txt`, `.mdx`, `.yaml`, `.yml`, `.json` or `.toml`),
/// at most five levels deep; each file appears once, in the order met.
///
/// A missing file that the backend reports as a [FileNotFoundException]
/// (Go: an error wrapping `os.ErrNotExist`), a circular import and the depth
/// limit are reported to [onLoadWarning] (logged on
/// `threepio.adk.agentsmd` by default) and skipped; any other error of the
/// backend fails the model call. `InMemoryBackend`, like eino's backends,
/// reports a missing file with a plain error, so with it a missing agents.md
/// fails the run, as in eino.
///
/// Put this middleware **after** the summarization middleware, so that the
/// injected text is not summarized.
final class AgentsMdMiddleware extends ChatModelAgentMiddleware {
  /// Loads [agentsMdFiles] (in this order) through [backend].
  ///
  /// [allAgentsMdMaxBytes] caps the UTF-8 bytes of everything loaded, imports
  /// included: the file that crosses it is cut to fit and nothing after it
  /// is loaded (0: no limit). [perAgentsMdMaxBytes] caps every single file
  /// (0: no limit). A cut file gets a notice and is not searched for
  /// imports. Throws [ArgumentError] for no files or a negative limit.
  AgentsMdMiddleware({
    required FileReadBackend backend,
    required List<String> agentsMdFiles,
    int allAgentsMdMaxBytes = 0,
    int perAgentsMdMaxBytes = 0,
    AgentsMdWarningCallback? onLoadWarning,
  }) : _loader = _validated(
          backend,
          agentsMdFiles,
          allAgentsMdMaxBytes,
          perAgentsMdMaxBytes,
          onLoadWarning,
        );

  final AgentsMdLoader _loader;

  static AgentsMdLoader _validated(
    FileReadBackend backend,
    List<String> files,
    int allMaxBytes,
    int perFileMaxBytes,
    AgentsMdWarningCallback? onWarning,
  ) {
    if (files.isEmpty) {
      throw ArgumentError.value(
        files,
        'agentsMdFiles',
        '[agentsmd]: at least one agent file path is required',
      );
    }
    if (allMaxBytes < 0) {
      throw ArgumentError.value(
        allMaxBytes,
        'allAgentsMdMaxBytes',
        '[agentsmd]: AllAgentsMDMaxBytes must be non-negative',
      );
    }
    if (perFileMaxBytes < 0) {
      throw ArgumentError.value(
        perFileMaxBytes,
        'perAgentsMdMaxBytes',
        '[agentsmd]: PerAgentsMDMaxBytes must be non-negative',
      );
    }
    return AgentsMdLoader(
      backend: backend,
      files: List.unmodifiable(files),
      maxBytes: allMaxBytes,
      perFileBytes: perFileMaxBytes,
      onWarning: onWarning,
    );
  }

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    for (final message in state.messages) {
      if (message.extra?.containsKey(agentsMdExtraKey) ?? false) return (ctx, state);
    }
    final content = await _loadContent(ctx);
    if (content.isEmpty) return (ctx, state);
    return (
      ctx,
      ChatModelAgentState(
        messages: _insertBeforeFirstUser(state.messages, content),
        toolInfos: state.toolInfos,
        deferredToolInfos: state.deferredToolInfos,
      ),
    );
  }

  Future<String> _loadContent(RunContext ctx) async {
    final (found, cached) = tryRunLocalValue(ctx, _cacheKey);
    if (found && cached is String) return cached;
    final String content;
    try {
      content = await _loader.load(ctx);
    } on Object catch (error) {
      throw ThreepioException(
        '[agentsmd]: failed to load agent files: ${goValueString(error)}',
        cause: error,
      );
    }
    if (content.isNotEmpty) trySetRunLocalValue(ctx, _cacheKey, content);
    return content;
  }
}

List<Message> _insertBeforeFirstUser(List<Message> messages, String content) {
  final injected = Message.user(content).copyWith(extra: {agentsMdExtraKey: true});
  final result = <Message>[];
  for (var i = 0; i < messages.length; i++) {
    if (messages[i].role == RoleType.user) {
      return result
        ..add(injected)
        ..addAll(messages.sublist(i));
    }
    result.add(messages[i]);
  }
  return result..add(injected);
}
