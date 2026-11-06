/// Loads agents.md files with `@import` resolution and byte budgets.
///
/// Port of eino `adk/middlewares/agentsmd/loader.go`.
@internal
library;

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../eino/language.dart';
import '../../filesystem/backend.dart';
import '../../filesystem/requests.dart';
import '../internal/go_compat.dart';

final Logger _log = Logger('threepio.adk.agentsmd');

/// `@path/to/file` anywhere in a text. Port of `importRegex`.
final RegExp _importRegex = RegExp(r'@([a-zA-Z0-9_.~/][a-zA-Z0-9_.~/\-]*)');

/// The extensions an `@import` without a `/` must have, so that mentions
/// and e-mail addresses are not taken for imports. Port of
/// `allowedImportExts`.
const Set<String> _allowedImportExts = {
  '.md',
  '.txt',
  '.mdx',
  '.yaml',
  '.yml',
  '.json',
  '.toml',
};

/// How deep `@import`s nest. Port of `maxImportDepth`.
const int agentsMdMaxImportDepth = 5;

/// Once something is loaded, a later file that would get fewer bytes than
/// this is dropped whole instead of cut. Port of `minTruncatableBytes`.
const int _minTruncatableBytes = 500;

/// Called for a problem that does not stop the loading: a missing file, a
/// circular `@import`, the depth limit, a file dropped for the budget.
/// Port of eino `agentsmd.Config.OnLoadWarning`.
typedef AgentsMdWarningCallback = void Function(String filePath, Object error);

const _formatHeaderEn = r'''
<system-reminder>
As you answer the user's questions, you can use the following context:
Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.
''';

const _formatHeaderCn = r'''
<system-reminder>
在回答用户问题时，你可以使用以下上下文：
代码库和用户指令如下。请务必遵守这些指令。重要提示：这些指令会覆盖任何默认行为，你必须严格按照要求执行。
''';

const _formatFileHeaderEn = '\nContents of ';

const _formatFileHeaderCn = '\n文件内容：';

const _formatFileLabelEn = r'''
 (instructions):

''';

const _formatFileLabelCn = r'''
（指令）：

''';

const _formatFooterEn = 'IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.\n</system-reminder>';

const _formatFooterCn = '重要提示：此上下文可能与你的任务相关，也可能不相关。除非此上下文与你的任务高度相关，否则不要响应此上下文。\n</system-reminder>';

/// The immutable settings of the loader; every [load] has state of its own.
/// Port of eino `loaderConfig`.
final class AgentsMdLoader {
  /// Loads [files] in order through [backend]. [maxBytes] is the budget of
  /// all files together, [perFileBytes] the cap of one file (0: none).
  AgentsMdLoader({
    required this.backend,
    required this.files,
    this.maxBytes = 0,
    this.perFileBytes = 0,
    AgentsMdWarningCallback? onWarning,
  }) : onWarning = onWarning ??
            ((filePath, error) =>
                _log.warning('[agentsmd] warning: $filePath: ${goValueString(error)}'));

  /// Reads the files.
  final FileReadBackend backend;

  /// The top-level files, in order.
  final List<String> files;

  /// The budget of all files together, imports included; 0 is no limit.
  final int maxBytes;

  /// The cap of one file; 0 is no limit.
  final int perFileBytes;

  /// Called for problems that do not stop the loading.
  final AgentsMdWarningCallback onWarning;

  /// Every file and its imports, formatted as one text; `''` when nothing
  /// was loaded. Port of `loaderConfig.load`.
  Future<String> load(RunContext ctx) async {
    final run = _LoadRun(this);
    final parts = <AgentsMdLoadedFile>[];
    final omitted = <String>[];
    final seen = <String>{};
    for (var i = 0; i < files.length; i++) {
      final filePath = files[i];
      if (run.stopped) {
        for (final rest in files.sublist(i)) {
          omitted.add(goClean(rest));
        }
        break;
      }
      final before = parts.length;
      final List<AgentsMdLoadedFile> loaded;
      try {
        loaded = await run.loadFile(ctx, filePath, 0, <String>{}, seen);
      } on Object catch (error) {
        throw ThreepioException(
          'failed to load "$filePath": ${goValueString(error)}',
          cause: error,
        );
      }
      parts.addAll(loaded);
      if (run.stopped && parts.length == before) omitted.add(goClean(filePath));
    }
    return formatAgentsMdContent(parts, omitted);
  }
}

/// One loaded file and its (possibly truncated) content.
@visibleForTesting
final class AgentsMdLoadedFile {
  /// [content] loaded from [path].
  const AgentsMdLoadedFile(this.path, this.content);

  /// The cleaned path.
  final String path;

  /// The content, with a truncation notice if it was cut.
  final String content;
}

/// The mutable state of one load. Port of eino `loader`.
final class _LoadRun {
  _LoadRun(this.config);

  final AgentsMdLoader config;
  int totalBytes = 0;
  bool stopped = false;

  Future<List<AgentsMdLoadedFile>> loadFile(
    RunContext ctx,
    String rawPath,
    int depth,
    Set<String> visited,
    Set<String> seen,
  ) async {
    final filePath = goClean(rawPath);
    if (depth > agentsMdMaxImportDepth) {
      config.onWarning(
        filePath,
        const ThreepioException('@import depth exceeds maximum of $agentsMdMaxImportDepth'),
      );
      return const [];
    }
    if (visited.contains(filePath)) {
      config.onWarning(filePath, const ThreepioException('circular @import detected'));
      return const [];
    }
    if (seen.contains(filePath)) return const [];

    visited.add(filePath);
    try {
      final FileContent fileContent;
      try {
        fileContent = await config.backend.read(ctx, ReadRequest(filePath: filePath));
      } on Object catch (error) {
        if (_isNotFound(error)) {
          config.onWarning(filePath, const ThreepioException('file not found, skipping'));
          return const [];
        }
        rethrow;
      }
      seen.add(filePath);
      var content = fileContent.content;
      if (content.isEmpty) return const [];

      final bool truncated;
      (content, truncated) = _applyBudget(filePath, content);
      if (content.isEmpty) return const [];

      final imports = truncated
          ? const <AgentsMdLoadedFile>[]
          : await _collectImports(ctx, filePath, content, depth, visited, seen);
      return [AgentsMdLoadedFile(filePath, content), ...imports];
    } finally {
      visited.remove(filePath);
    }
  }

  (String, bool) _applyBudget(String filePath, String original) {
    final originalLen = utf8Length(original);
    var content = original;
    var length = originalLen;
    var truncated = false;

    final perFileBytes = config.perFileBytes;
    if (perFileBytes > 0 && length > perFileBytes) {
      content = utf8Prefix(content, perFileBytes);
      length = utf8Length(content);
      truncated = true;
    }

    final maxBytes = config.maxBytes;
    if (maxBytes > 0) {
      final remaining = maxBytes - totalBytes;
      if (length > remaining) {
        if (remaining < _minTruncatableBytes && totalBytes > 0) {
          stopped = true;
          config.onWarning(
            filePath,
            ThreepioException('dropped: remaining budget $remaining below $_minTruncatableBytes'),
          );
          return ('', false);
        }
        content = utf8Prefix(content, remaining);
        length = utf8Length(content);
        truncated = true;
        stopped = true;
      }
    }

    totalBytes += length;
    if (maxBytes > 0 && totalBytes >= maxBytes) stopped = true;

    if (truncated) content += agentsMdTruncationNotice(originalLen - length, originalLen);
    return (content, truncated);
  }

  Future<List<AgentsMdLoadedFile>> _collectImports(
    RunContext ctx,
    String hostPath,
    String content,
    int depth,
    Set<String> visited,
    Set<String> seen,
  ) async {
    final dir = goDir(hostPath);
    final imports = <AgentsMdLoadedFile>[];
    for (final match in _importRegex.allMatches(content)) {
      if (stopped) break;
      final rawPath = match.group(1)!;
      if (!rawPath.contains('/') && !_allowedImportExts.contains(goExt(rawPath))) continue;
      final importPath = goIsAbs(rawPath) ? rawPath : goJoin([dir, rawPath]);
      if (seen.contains(importPath)) continue;
      try {
        imports.addAll(await loadFile(ctx, importPath, depth + 1, visited, seen));
      } on Object catch (error) {
        throw ThreepioException(
          'failed to import "$rawPath" from "$hostPath": ${goValueString(error)}',
          cause: error,
        );
      }
    }
    return imports;
  }
}

bool _isNotFound(Object error) =>
    error is FileNotFoundException ||
    ThreepioException.findCause<FileNotFoundException>(error) != null;

/// The note appended to a file that was cut: how many bytes were removed
/// and the original size. Port of `truncationNotice`.
@visibleForTesting
String agentsMdTruncationNotice(int cut, int total) => selectPrompt(
      I18nPrompts(
        english: '\n\n[…content too large, truncated $cut bytes; original size $total bytes]',
        chinese: '\n\n[…内容过大，已截断 $cut 字节，总大小 $total 字节]',
      ),
    );

/// The line listing the top-level files the budget left out, or `''`.
/// Port of `omittedNotice`.
String _omittedNotice(List<String> paths) {
  if (paths.isEmpty) return '';
  return selectPrompt(
    I18nPrompts(
      english:
          '\n[${paths.length} more file(s) not loaded due to the total byte limit: ${paths.join(', ')}]\n',
      chinese: '\n[还有 ${paths.length} 个文件因超出总字节上限未加载：${paths.join('、')}]\n',
    ),
  );
}

/// The loaded files as one text. Port of `formatContent`.
@visibleForTesting
String formatAgentsMdContent(List<AgentsMdLoadedFile> loaded, List<String> omitted) {
  if (loaded.isEmpty) return '';
  String pick(String english, String chinese) =>
      selectPrompt(I18nPrompts(english: english, chinese: chinese));
  final header = pick(_formatHeaderEn, _formatHeaderCn);
  final fileHeader = pick(_formatFileHeaderEn, _formatFileHeaderCn);
  final fileLabel = pick(_formatFileLabelEn, _formatFileLabelCn);
  final footer = pick(_formatFooterEn, _formatFooterCn);
  final out = StringBuffer(header);
  for (final file in loaded) {
    out
      ..write(fileHeader)
      ..write(file.path)
      ..write(fileLabel)
      ..write(file.content)
      ..write('\n');
  }
  out
    ..write(_omittedNotice(omitted))
    ..write(footer);
  return out.toString();
}
