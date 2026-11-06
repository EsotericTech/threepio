// Port of eino v0.9.22 adk/middlewares/agentsmd/agentsmd_test.go (classic
// messages only).
//
// Ported (57 of 58): TestNew_Validation (in part, see below),
// TestMiddleware_BasicInjection, TestMiddleware_MultipleFiles,
// TestMiddleware_ImportResolution, TestMiddleware_RecursiveImport,
// TestMiddleware_MaxImportDepth, TestMiddleware_CircularImport,
// TestMiddleware_MaxBytesLimit, TestMiddleware_InjectedInState,
// TestMiddleware_AbsoluteImportPath, TestMiddleware_ImportAsSeparateSection,
// TestLoader_NoImportsPassthrough, TestLoader_ImportAsSeparateSection,
// TestLoader_MultipleImportsSameLine, TestLoader_SameFileTwiceOnSameLine,
// TestLoader_ImportFileNotFound, TestLoader_RelativePathResolution,
// TestLoader_RelativeTopLevelPath, TestLoader_RelativeTopLevelWithDotDotImport,
// TestLoader_RelativeTopLevelDedup, TestLoader_AbsoluteTopLevelWithRelativeImport,
// TestLoader_AbsoluteTopLevelWithDotDotImport, TestLoader_RelativeImportDedup,
// TestLoader_NestedRelativeImport, TestLoader_TransitiveImport,
// TestLoader_EmptyFile, TestLoader_MaxBytesFirstFileTruncated,
// TestLoader_MaxBytesBelowThresholdStillCaps, TestLoader_MaxBytesLaterFileDropped,
// TestLoader_CircularImportInline, TestLoader_MaxDepthInline,
// TestLoader_DiamondDependency, TestLoader_AtSignInNormalText,
// TestLoader_MaxBytesWithImports, TestNew_Validation_EmptyAgentFiles,
// TestMiddleware_GenerateError, TestLoader_DuplicateTopLevelFiles,
// TestLoader_LoadFileError, TestLoader_MaxBytesStopsImports,
// TestLoader_PerFileMaxBytesTruncates, TestLoader_PerFileTruncatedSkipsImports,
// TestLoader_OmittedNoticeListsFiles, TestTruncateBytes_RuneBoundary,
// TestFormatContent_Empty, TestMiddleware_AllFilesEmpty, TestLoader_ExactOutput,
// TestLoader_MissingFileSkipped, TestLoader_AllMissingFilesSkipped,
// TestLoader_CircularImportSkipped, TestLoader_DepthExceededSkipped,
// TestLoader_OnLoadWarningCallback, TestMiddleware_MissingFile,
// TestMiddleware_InsertBeforeFirstUserMessage, TestMiddleware_InsertWithNoUserMessage,
// TestLoader_ImportIOError, TestMiddleware_Idempotency,
// TestMiddleware_ReinsertAfterRemoval.
//
// Not ported: TestNewTypedAgenticMessage (agentic messages are P13; so is all
// of agentsmd_generic_test.go). In TestNew_Validation the nil config, the
// empty config (its first failure is the nil backend) and the nil backend are
// compile-time errors in Dart (required parameters).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/agents_md/loader.dart'
    show AgentsMdLoadedFile, AgentsMdLoader, formatAgentsMdContent;
import 'package:threepio_core/src/adk/middlewares/internal/go_compat.dart'
    show goValueString, utf8Prefix;

final _ctx = RunContext.background();

// --- test helpers ---

/// Go `memBackend`: a missing file is a [FileNotFoundException] (Go: an error
/// wrapping `os.ErrNotExist`).
final class _MemBackend implements FileReadBackend {
  final Map<String, String> files = {};

  void set(String path, String content) => files[path] = content;

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async {
    final content = files[request.filePath];
    if (content == null) throw FileNotFoundException(request.filePath);
    return FileContent(content);
  }
}

/// Go `errBackend`: every read fails with an error that is not "not found".
final class _ErrBackend implements FileReadBackend {
  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async =>
      throw ThreepioException('permission denied: ${request.filePath}');
}

/// Go `partialErrBackend`: known files load, others fail with an I/O error.
final class _PartialErrBackend implements FileReadBackend {
  _PartialErrBackend(this.files);

  final Map<String, String> files;

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async {
    final content = files[request.filePath];
    if (content == null) throw ThreepioException('I/O error reading ${request.filePath}');
    return FileContent(content);
  }
}

/// Go `newLoaderConfig(b, files, maxBytes, perFileBytes, onWarning).load(ctx)`.
Future<String> _load(
  FileReadBackend backend,
  List<String> files, {
  int maxBytes = 0,
  int perFileBytes = 0,
  AgentsMdWarningCallback? onWarning,
}) =>
    AgentsMdLoader(
      backend: backend,
      files: files,
      maxBytes: maxBytes,
      perFileBytes: perFileBytes,
      onWarning: onWarning,
    ).load(_ctx);

/// Go `mw.BeforeModelRewriteState(ctx, state, nil)`, returning the new state.
Future<ChatModelAgentState> _rewrite(AgentsMdMiddleware mw, ChatModelAgentState state) async {
  final (_, newState) = await mw.beforeModelRewriteState(_ctx, state, const ModelContext());
  return newState;
}

ChatModelAgentState _state(List<Message> messages) => ChatModelAgentState(messages: messages);

ChatModelAgentState _hi() => _state([Message.user('hi')]);

/// Go `strings.Count` (non-overlapping occurrences of a non-empty [sub]).
int _count(String s, String sub) {
  var n = 0;
  var i = s.indexOf(sub);
  while (i >= 0) {
    n++;
    i = s.indexOf(sub, i + sub.length);
  }
  return n;
}

// --- tests ---

void main() {
  test('TestNew_Validation', () {
    final b = _MemBackend();

    // New(ctx, nil), New(ctx, &Config{}) and a nil Backend: compile-time
    // errors in Dart (required parameters), not portable.

    expect(
      () => AgentsMdMiddleware(backend: b, agentsMdFiles: ['/test.md'], allAgentsMdMaxBytes: -1),
      throwsArgumentError,
      reason: 'expected error for negative max bytes',
    );

    expect(
      () => AgentsMdMiddleware(backend: b, agentsMdFiles: ['/test.md'], perAgentsMdMaxBytes: -1),
      throwsArgumentError,
      reason: 'expected error for negative per-file max bytes',
    );
  });

  test('TestMiddleware_BasicInjection', () async {
    final b = _MemBackend()..set('/agent.md', 'You are a helpful assistant.');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/agent.md']);

    final userMsg = Message.user('hello');
    final state = await _rewrite(mw, _state([userMsg]));

    expect(state.messages, hasLength(2));
    expect(state.messages[0].role, RoleType.user);
    expect(state.messages[0].content, contains('You are a helpful assistant.'));
    expect(state.messages[0].content, contains('<system-reminder>'));
    expect(_count(state.messages[0].content, '<system-reminder>'), 1,
        reason: 'expected exactly one opening system-reminder tag');
    expect(_count(state.messages[0].content, '</system-reminder>'), 1,
        reason: 'expected exactly one closing system-reminder tag');
    expect(state.messages[1].content, 'hello');
  });

  test('TestMiddleware_MultipleFiles', () async {
    final b = _MemBackend()
      ..set('/a.md', 'instruction A')
      ..set('/b.md', 'instruction B');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/a.md', '/b.md']);

    final state = await _rewrite(mw, _hi());

    final content = state.messages[0].content;
    final idxA = content.indexOf('instruction A');
    final idxB = content.indexOf('instruction B');
    expect(idxA >= 0 && idxB >= 0, isTrue, reason: 'both files should be included, content: $content');
    expect(idxA < idxB, isTrue, reason: 'file A should appear before file B');
  });

  test('TestMiddleware_ImportResolution', () async {
    final b = _MemBackend()
      ..set('/project/agent.md', 'main instructions\n@sub/rules.md\nend')
      ..set('/project/sub/rules.md', 'imported rule');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/project/agent.md']);

    final state = await _rewrite(mw, _hi());

    final content = state.messages[0].content;
    // Original text should be preserved with @path intact.
    expect(content, contains('main instructions'));
    expect(content, contains('@sub/rules.md'));
    expect(content, contains('end'));
    // Imported file should appear as a separate section.
    expect(content, contains('Contents of /project/sub/rules.md'));
    expect(content, contains('imported rule'));
  });

  test('TestMiddleware_RecursiveImport', () async {
    final b = _MemBackend()
      ..set('/a.md', 'top\n@/b.md')
      ..set('/b.md', 'middle\n@/c.md')
      ..set('/c.md', 'leaf content');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/a.md']);

    final state = await _rewrite(mw, _hi());

    final content = state.messages[0].content;
    // All three files should appear as separate sections.
    for (final section in ['Contents of /a.md', 'Contents of /b.md', 'Contents of /c.md']) {
      expect(content, contains(section));
    }
    for (final text in ['top', 'middle', 'leaf content']) {
      expect(content, contains(text));
    }
    // Sections should appear in order: a, b, c.
    final idxA = content.indexOf('Contents of /a.md');
    final idxB = content.indexOf('Contents of /b.md');
    final idxC = content.indexOf('Contents of /c.md');
    expect(idxA < idxB && idxB < idxC, isTrue,
        reason: 'sections should appear in order a < b < c, got a=$idxA b=$idxB c=$idxC');
  });

  test('TestMiddleware_MaxImportDepth', () async {
    final b = _MemBackend();
    for (var i = 0; i < 7; i++) {
      final content = i < 6 ? 'level $i\n@/level${i + 1}.md' : 'level $i';
      b.set('/level$i.md', content);
    }
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/level0.md']);

    // Import failure at depth > 5 is logged, not returned as error.
    final state = await _rewrite(mw, _hi());
    // Levels 0-5 should be present as sections; level 6 fails silently.
    final content = state.messages[0].content;
    for (var i = 0; i <= 5; i++) {
      expect(content, contains('Contents of /level$i.md'));
    }
    expect(content, isNot(contains('Contents of /level6.md')),
        reason: 'level6 should not be present (depth exceeded)');
  });

  test('TestMiddleware_CircularImport', () async {
    final b = _MemBackend()
      ..set('/a.md', '@/b.md')
      ..set('/b.md', '@/a.md');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/a.md']);

    // Circular import failure is logged, not returned as error.
    final state = await _rewrite(mw, _hi());
    // /a.md and /b.md should both be present; the circular ref from b->a is skipped.
    final content = state.messages[0].content;
    expect(content, contains('Contents of /a.md'));
    expect(content, contains('Contents of /b.md'));
  });

  test('TestMiddleware_MaxBytesLimit', () async {
    final b = _MemBackend()
      ..set('/a.md', 'A' * 560) // fills the budget exactly
      ..set('/b.md', 'BBBB');
    final mw = AgentsMdMiddleware(
      backend: b,
      agentsMdFiles: ['/a.md', '/b.md'],
      allAgentsMdMaxBytes: 560, // file a fills it, so file b is excluded
    );

    final state = await _rewrite(mw, _hi());

    final content = state.messages[0].content;
    expect(content, contains('A' * 560), reason: 'first file should be included');
    expect(content, isNot(contains('BBBB')), reason: 'second file should be excluded due to max bytes');
  });

  test('TestMiddleware_InjectedInState', () async {
    final b = _MemBackend()..set('/agent.md', 'agent instructions');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/agent.md']);

    final originalMsgs = [Message.user('hello')];
    final newState = await _rewrite(mw, _state(originalMsgs));

    // The original slice should not be modified (new slice is returned).
    expect(originalMsgs, hasLength(1));
    expect(originalMsgs[0].content, 'hello');
    // The returned state should have the injected message.
    expect(newState.messages, hasLength(2));
    expect(newState.messages[0].content, contains('agent instructions'));
    expect(newState.messages[1].content, 'hello');
  });

  test('TestMiddleware_AbsoluteImportPath', () async {
    final b = _MemBackend()
      ..set('/project/main.md', 'start\n@/shared/imported.md\nend')
      ..set('/shared/imported.md', 'absolute import content');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/project/main.md']);

    final state = await _rewrite(mw, _hi());

    final content = state.messages[0].content;
    // @path preserved in original text.
    expect(content, contains('@/shared/imported.md'));
    // Imported content in separate section.
    expect(content, contains('Contents of /shared/imported.md'));
    expect(content, contains('absolute import content'));
  });

  test('TestMiddleware_ImportAsSeparateSection', () async {
    final b = _MemBackend()
      ..set('/project/agent.md', 'Please read @sub/rules.md and also @sub/style.md for guidance.')
      ..set('/project/sub/rules.md', 'RULE_CONTENT')
      ..set('/project/sub/style.md', 'STYLE_CONTENT');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/project/agent.md']);

    final state = await _rewrite(mw, _hi());

    final content = state.messages[0].content;
    // Original text preserved with @paths intact.
    expect(content, contains('Please read @sub/rules.md and also @sub/style.md for guidance.'));
    // Imported files appear as separate sections.
    expect(content, contains('Contents of /project/sub/rules.md'));
    expect(content, contains('RULE_CONTENT'));
    expect(content, contains('Contents of /project/sub/style.md'));
    expect(content, contains('STYLE_CONTENT'));

    // Sections should be ordered: agent.md, rules.md, style.md.
    final idxAgent = content.indexOf('Contents of /project/agent.md');
    final idxRules = content.indexOf('Contents of /project/sub/rules.md');
    final idxStyle = content.indexOf('Contents of /project/sub/style.md');
    expect(idxAgent < idxRules && idxRules < idxStyle, isTrue,
        reason: 'sections should appear in order agent < rules < style, '
            'got agent=$idxAgent rules=$idxRules style=$idxStyle');
  });

  // --- loader-specific tests ---

  test('TestLoader_NoImportsPassthrough', () async {
    // Content without any @path should be returned as-is in its section.
    final b = _MemBackend()..set('/agent.md', 'plain text without imports\nline two');

    final content = await _load(b, ['/agent.md']);
    expect(content, contains('plain text without imports'));
    expect(content, contains('line two'));
  });

  test('TestLoader_ImportAsSeparateSection', () async {
    // @path in the middle of a sentence should be preserved; imported file is a separate section.
    final b = _MemBackend()
      ..set('/doc.md', 'before @/snippet.md after')
      ..set('/snippet.md', 'INJECTED');

    final content = await _load(b, ['/doc.md']);
    // Original text preserved.
    expect(content, contains('before @/snippet.md after'));
    // Imported file in separate section.
    expect(content, contains('Contents of /snippet.md'));
    expect(content, contains('INJECTED'));
  });

  test('TestLoader_MultipleImportsSameLine', () async {
    // Multiple @path on one line should each get a separate section.
    final b = _MemBackend()
      ..set('/doc.md', 'see @/a.txt and @/b.txt here')
      ..set('/a.txt', 'AAA')
      ..set('/b.txt', 'BBB');

    final content = await _load(b, ['/doc.md']);
    // Original text preserved.
    expect(content, contains('see @/a.txt and @/b.txt here'));
    // Each imported file has its own section.
    expect(content, contains('Contents of /a.txt'));
    expect(content, contains('AAA'));
    expect(content, contains('Contents of /b.txt'));
    expect(content, contains('BBB'));
  });

  test('TestLoader_SameFileTwiceOnSameLine', () async {
    // The same file referenced twice should appear only once as a section (deduped).
    final b = _MemBackend()
      ..set('/doc.md', '@/shared.md and @/shared.md again')
      ..set('/shared.md', 'SHARED');

    final content = await _load(b, ['/doc.md']);
    // Original text preserved.
    expect(content, contains('@/shared.md and @/shared.md again'));
    // shared.md content should appear only once (deduped).
    expect(_count(content, 'Contents of /shared.md'), 1,
        reason: 'expected shared.md section to appear once (deduped)');
  });

  test('TestLoader_ImportFileNotFound', () async {
    final b = _MemBackend()..set('/doc.md', 'load @/missing.md please');

    final content = await _load(b, ['/doc.md']);
    // Original text preserved; missing file simply has no section.
    expect(content, contains('load @/missing.md please'));
    expect(content, isNot(contains('Contents of /missing.md')));
  });

  test('TestLoader_RelativePathResolution', () async {
    // Relative path should resolve relative to the host file's directory.
    final b = _MemBackend()
      ..set('/a/b/host.md', 'ref @../c/target.md done')
      ..set('/a/c/target.md', 'TARGET');

    final content = await _load(b, ['/a/b/host.md']);
    // Original text preserved.
    expect(content, contains('ref @../c/target.md done'));
    // Imported file as separate section.
    expect(content, contains('Contents of /a/c/target.md'));
    expect(content, contains('TARGET'));
  });

  test('TestLoader_RelativeTopLevelPath', () async {
    // Top-level file uses relative path; imports with ./ resolve correctly.
    final b = _MemBackend()
      ..set('sub/agents.md', 'start @./other.md end')
      ..set('sub/other.md', 'OTHER CONTENT');

    final content = await _load(b, ['sub/agents.md']);
    expect(content, contains('start @./other.md end'));
    expect(content, contains('OTHER CONTENT'));
  });

  test('TestLoader_RelativeTopLevelWithDotDotImport', () async {
    // Top-level file uses relative path; import with ../ resolves correctly.
    final b = _MemBackend()
      ..set('sub/agents.md', 'see @../shared/x.md here')
      ..set('shared/x.md', 'SHARED X');

    final content = await _load(b, ['sub/agents.md']);
    expect(content, contains('SHARED X'));
    // filepath.Clean should normalize "sub/../shared/x.md" to "shared/x.md"
    expect(content, contains('Contents of shared/x.md'));
  });

  test('TestLoader_RelativeTopLevelDedup', () async {
    // Two top-level relative paths that resolve to the same file via filepath.Clean
    // should be deduped (loaded only once).
    final b = _MemBackend()..set('sub/a.md', 'CONTENT A');

    final content = await _load(b, ['sub/a.md', './sub/a.md']);
    expect(_count(content, 'CONTENT A'), 1, reason: 'expected file loaded once (deduped)');
  });

  test('TestLoader_AbsoluteTopLevelWithRelativeImport', () async {
    // Absolute top-level path with relative @import resolves correctly.
    final b = _MemBackend()
      ..set('/project/agents.md', 'ref @./lib/helper.md done')
      ..set('/project/lib/helper.md', 'HELPER');

    final content = await _load(b, ['/project/agents.md']);
    expect(content, contains('HELPER'));
    expect(content, contains('Contents of /project/lib/helper.md'));
  });

  test('TestLoader_AbsoluteTopLevelWithDotDotImport', () async {
    // Absolute top-level path; @import with ../ resolves and normalizes.
    final b = _MemBackend()
      ..set('/project/sub/agents.md', 'load @../shared/x.md here')
      ..set('/project/shared/x.md', 'SHARED');

    final content = await _load(b, ['/project/sub/agents.md']);
    expect(content, contains('SHARED'));
    // filepath.Clean normalizes "/project/sub/../shared/x.md" to "/project/shared/x.md"
    expect(content, contains('Contents of /project/shared/x.md'));
  });

  test('TestLoader_RelativeImportDedup', () async {
    // Two different relative @import paths that resolve to the same file
    // should be deduped via filepath.Clean.
    final b = _MemBackend()
      ..set('/a/main.md', 'first @/a/b/shared.md second @../a/b/shared.md end')
      ..set('/a/b/shared.md', 'SHARED ONCE');

    final content = await _load(b, ['/a/main.md']);
    expect(_count(content, 'SHARED ONCE'), 1, reason: 'expected shared file loaded once (deduped)');
  });

  test('TestLoader_NestedRelativeImport', () async {
    // File A imports B via relative path, B imports C via relative path.
    // All three should appear as separate sections.
    final b = _MemBackend()
      ..set('/root/main.md', 'start @sub/mid.md end')
      ..set('/root/sub/mid.md', 'mid @deep/leaf.md mid_end')
      ..set('/root/sub/deep/leaf.md', 'LEAF');

    final content = await _load(b, ['/root/main.md']);
    for (final section in [
      'Contents of /root/main.md',
      'Contents of /root/sub/mid.md',
      'Contents of /root/sub/deep/leaf.md',
    ]) {
      expect(content, contains(section));
    }
    expect(content, contains('LEAF'));
  });

  test('TestLoader_TransitiveImport', () async {
    // Imported file itself contains @imports; all should appear as separate sections.
    final b = _MemBackend()
      ..set('/main.md', 'header @/mid.md footer')
      ..set('/mid.md', 'mid-start @/leaf.md mid-end')
      ..set('/leaf.md', 'LEAF_VALUE');

    final content = await _load(b, ['/main.md']);
    for (final section in ['Contents of /main.md', 'Contents of /mid.md', 'Contents of /leaf.md']) {
      expect(content, contains(section));
    }
    expect(content, contains('LEAF_VALUE'));
  });

  test('TestLoader_EmptyFile', () async {
    final b = _MemBackend()..set('/empty.md', '');

    final content = await _load(b, ['/empty.md']);
    // Empty file is treated as non-existent, so output should be empty.
    expect(content, '');
  });

  test('TestLoader_MaxBytesFirstFileTruncated', () async {
    // The budget applies to the first file too: it is truncated to the remaining
    // budget (with a notice) when at least minTruncatableBytes remain.
    final b = _MemBackend()..set('/big.md', 'A' * 1000); // 1000 bytes

    final content = await _load(b, ['/big.md'], maxBytes: 600);
    expect(content, contains('A' * 600), reason: 'first file should retain 600 bytes');
    expect(content, isNot(contains('A' * 601)), reason: 'first file should be truncated to 600 bytes');
    expect(content, contains('truncated 400 bytes'));
  });

  test('TestLoader_MaxBytesBelowThresholdStillCaps', () async {
    // A positive budget below minTruncatableBytes is still a hard cap: the first
    // (and only) file is truncated to fit rather than being dropped or loaded whole.
    // minTruncatableBytes is a tail-only optimization and must have no effect here.
    final b = _MemBackend()..set('/big.md', 'A' * 1000);

    final content = await _load(b, ['/big.md'], maxBytes: 100);
    expect(content, contains('A' * 100), reason: 'first file should be truncated to the 100-byte budget');
    expect(content, isNot(contains('A' * 101)), reason: 'content must not exceed the 100-byte budget');
    expect(content, contains('truncated'));
  });

  test('TestLoader_MaxBytesLaterFileDropped', () async {
    // Once earlier content leaves less than minTruncatableBytes of budget, the next
    // file is dropped whole and listed as omitted.
    final b = _MemBackend()
      ..set('/a.md', 'A' * 550) // consumes most of a 600-byte budget
      ..set('/b.md', 'B' * 200);

    final content = await _load(b, ['/a.md', '/b.md'], maxBytes: 600);
    expect(content, contains('A' * 550), reason: 'a.md should load in full');
    expect(content.contains('B') && content.contains('B' * 2), isFalse,
        reason: 'b.md should be dropped whole (remaining budget below threshold), got $content');
    expect(content, contains('1 more file(s) not loaded due to the total byte limit'));
  });

  test('TestLoader_CircularImportInline', () async {
    // Circular reference via @import should be detected, logged, and skipped.
    final b = _MemBackend()
      ..set('/a.md', 'text @/b.md more')
      ..set('/b.md', 'ref @/a.md back');

    final content = await _load(b, ['/a.md']);
    // Both a and b should have sections; circular back-reference a from b is skipped.
    expect(content, contains('Contents of /a.md'));
    expect(content, contains('Contents of /b.md'));
  });

  test('TestLoader_MaxDepthInline', () async {
    // Deep chain via @import should be logged at depth > 5, not returned as error.
    final b = _MemBackend();
    for (var i = 0; i < 7; i++) {
      final content = i < 6 ? 'level$i @/level${i + 1}.md tail' : 'level$i';
      b.set('/level$i.md', content);
    }

    final content = await _load(b, ['/level0.md']);
    // Levels 0-5 should have sections.
    for (var i = 0; i <= 5; i++) {
      expect(content, contains('Contents of /level$i.md'));
    }
    // Level 6 should not be present.
    expect(content, isNot(contains('Contents of /level6.md')));
  });

  test('TestLoader_DiamondDependency', () async {
    // A imports B and D; B imports C; D also imports C.
    // C should appear only once (deduped across the whole load).
    final b = _MemBackend()
      ..set('/a.md', 'start @/b.md middle @/d.md end')
      ..set('/b.md', 'B(@/c.md)')
      ..set('/d.md', 'D(@/c.md)')
      ..set('/c.md', 'SHARED');

    final content = await _load(b, ['/a.md']);

    // C should appear only once as a section (deduped).
    expect(_count(content, 'Contents of /c.md'), 1, reason: 'expected /c.md section once (deduped)');
    // All files should have sections.
    for (final section in [
      'Contents of /a.md',
      'Contents of /b.md',
      'Contents of /c.md',
      'Contents of /d.md',
    ]) {
      expect(content, contains(section));
    }
  });

  test('TestLoader_AtSignInNormalText', () async {
    // Bare @word without "/" or file extension should not trigger import.
    // Email-like patterns (@example.com) with non-allowed extensions should also be ignored.
    final b = _MemBackend()
      ..set(
        '/agent.md',
        'contact me @ anytime or @  spaces and @someone mentioned and user@example.com and @company.org',
      );

    final content = await _load(b, ['/agent.md']);
    expect(content, contains('contact me @ anytime'));
    expect(content, contains('@someone mentioned'));
    expect(content, contains('@example.com'));
    expect(content, contains('@company.org'));
  });

  test('TestLoader_MaxBytesWithImports', () async {
    // Two top-level files that both import the same shared file.
    // Budget should account for imported file bytes.
    final b = _MemBackend()
      ..set('/a.md', 'A(@/shared.md)')
      ..set('/b.md', 'B(@/shared.md)')
      ..set('/shared.md', 'X' * 600); // 600 bytes

    // /a.md = 14 bytes + /shared.md = 600 bytes => 614 total after /a.md.
    // Budget = 620: only 6 bytes remain, below minTruncatableBytes, so /b.md is dropped.
    final content = await _load(b, ['/a.md', '/b.md'], maxBytes: 620);

    // /a.md and its import should be included.
    expect(content, contains('X' * 100), reason: 'expected /a.md with shared content to be included');

    // /b.md should be excluded because totalBytes exceeded budget after loading /a.md.
    expect(content, isNot(contains('B(')), reason: 'expected /b.md to be excluded due to budget');
  });

  test('TestNew_Validation_EmptyAgentFiles', () {
    final b = _MemBackend();

    expect(
      () => AgentsMdMiddleware(backend: b, agentsMdFiles: const []),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('at least one agent file path is required'),
        ),
      ),
    );
  });

  test('TestMiddleware_GenerateError', () async {
    // Non-ErrNotExist errors (e.g. permission denied) should propagate.
    final mw = AgentsMdMiddleware(backend: _ErrBackend(), agentsMdFiles: ['/file.md']);

    await expectLater(
      _rewrite(mw, _hi()),
      throwsA(predicate((Object e) => '$e'.contains('failed to load agent files'))),
    );
  });

  test('TestLoader_DuplicateTopLevelFiles', () async {
    // Same file listed twice in AgentFiles; second should be deduped via seen map.
    final b = _MemBackend()..set('/agent.md', 'unique content');

    final content = await _load(b, ['/agent.md', '/agent.md']);

    expect(_count(content, 'Contents of /agent.md'), 1, reason: 'expected /agent.md section once (deduped)');
  });

  test('TestLoader_LoadFileError', () async {
    // Missing file (ErrNotExist) is silently skipped.
    final b = _MemBackend();
    final content = await _load(b, ['/missing.md']);
    expect(content, '');
  });

  test('TestLoader_MaxBytesStopsImports', () async {
    // When budget is exhausted, further imports in collectImports should be skipped.
    final b = _MemBackend()
      ..set('/main.md', '@/big.md @/small.md')
      ..set('/big.md', 'B' * 600)
      ..set('/small.md', 'SMALL');

    final content = await _load(b, ['/main.md'], maxBytes: 560);

    // main.md itself is loaded (always), big.md pushes over budget,
    // small.md should be skipped.
    expect(content, contains('Contents of /main.md'), reason: 'main.md should be present');
    expect(content, isNot(contains('SMALL')), reason: 'small.md should be skipped after budget exhausted');
  });

  test('TestLoader_PerFileMaxBytesTruncates', () async {
    // PerAgentsMDMaxBytes caps each file individually; a per-file truncation does
    // not stop the loader, so later files still load.
    final b = _MemBackend()
      ..set('/a.md', 'A' * 1000)
      ..set('/b.md', 'KEEP');

    final content = await _load(b, ['/a.md', '/b.md'], perFileBytes: 100);

    expect(content, contains('A' * 100), reason: 'a.md should retain 100 bytes');
    expect(content, isNot(contains('A' * 101)), reason: 'a.md should be truncated to 100 bytes');
    expect(content, contains('truncated 900 bytes'), reason: 'expected per-file truncation notice');
    expect(content, contains('KEEP'), reason: 'b.md should still load; per-file cap must not stop the loader');
  });

  test('TestLoader_PerFileTruncatedSkipsImports', () async {
    // A file truncated by the per-file cap must not pull in its @imports.
    final b = _MemBackend()
      ..set('/a.md', '@/imp.md ${'A' * 200}')
      ..set('/imp.md', 'IMPORTED');

    final content = await _load(b, ['/a.md'], perFileBytes: 50);
    expect(content, isNot(contains('IMPORTED')), reason: 'imports of a truncated file must be skipped');
  });

  test('TestLoader_OmittedNoticeListsFiles', () async {
    // When the cumulative budget is exhausted, the remaining top-level files are
    // listed in the summary line with cleaned paths.
    final b = _MemBackend()
      ..set('/a.md', 'A' * 1000)
      ..set('/b.md', 'B')
      ..set('/c.md', 'C');

    final content = await _load(b, ['/a.md', '/b/../b.md', '/c.md'], maxBytes: 600);

    expect(content, contains('2 more file(s) not loaded due to the total byte limit'));
    expect(content.contains('/b.md') && content.contains('/c.md'), isTrue,
        reason: 'summary should list cleaned paths /b.md and /c.md, got $content');
    expect(content, isNot(contains('/b/../b.md')), reason: 'summary should use the cleaned path, not the raw one');
  });

  test('TestTruncateBytes_RuneBoundary', () {
    // A cut landing inside a multibyte rune backs up to the rune boundary.
    final got = utf8Prefix('好' * 4, 10); // each 好 is 3 bytes; 10 lands mid-rune
    expect(got, '好' * 3, reason: 'rune boundary');
    // Go utf8.ValidString: the result encodes to UTF-8 and back unchanged.
    expect(utf8.decode(utf8.encode(got)), got, reason: 'truncated result is not valid UTF-8');

    expect(utf8Prefix('abc', 10), 'abc', reason: 'content shorter than max should be unchanged');
    expect(utf8Prefix('abcdef', 3), 'abc', reason: 'ascii cut on boundary should be exact');
  });

  test('TestFormatContent_Empty', () {
    // formatContent with nil/empty slice should return empty string (Dart has
    // no nil slice: both are an empty list).
    expect(formatAgentsMdContent(const [], const []), '');
    expect(formatAgentsMdContent(const <AgentsMdLoadedFile>[], const []), '');
  });

  test('TestMiddleware_AllFilesEmpty', () async {
    // When all agent files have empty content, loader returns "" and
    // BeforeModelRewriteState returns the original state unchanged.
    final b = _MemBackend()..set('/agent.md', '');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/agent.md']);

    final state = await _rewrite(mw, _state([Message.user('hello')]));
    // Empty file produces no agentmd content, so original messages pass through unchanged.
    expect(state.messages, hasLength(1), reason: 'expected 1 message (no agentmd prepended)');
    expect(state.messages[0].content, 'hello');
  });

  test('TestLoader_ExactOutput', () async {
    // Verify the exact output format matches the expected structure:
    // each file (top-level and imported) gets its own "Contents of ..." section,
    // @path references are preserved in the original text.
    final b = _MemBackend()
      ..set('/project/CLAUDE.md', 'this is project claude.md\n\n- git workflow @git/git-instructions.md')
      ..set('/project/git/git-instructions.md', 'this is git-instructions.md');

    final content = await _load(b, ['/project/CLAUDE.md']);

    const expected = '''
<system-reminder>
As you answer the user's questions, you can use the following context:
Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.

Contents of /project/CLAUDE.md (instructions):

this is project claude.md

- git workflow @git/git-instructions.md

Contents of /project/git/git-instructions.md (instructions):

this is git-instructions.md
IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
</system-reminder>''';

    expect(content, expected);
    // Byte for byte, as Go compares strings.
    expect(utf8.encode(content), utf8.encode(expected));
  });

  test('TestLoader_MissingFileSkipped', () async {
    final b = _MemBackend()..set('/good.md', 'GOOD CONTENT');
    // /missing.md is not set

    final content = await _load(b, ['/missing.md', '/good.md']);
    expect(content, contains('GOOD CONTENT'));
  });

  test('TestLoader_AllMissingFilesSkipped', () async {
    final b = _MemBackend();

    final content = await _load(b, ['/missing1.md', '/missing2.md']);
    expect(content, '');
  });

  test('TestLoader_CircularImportSkipped', () async {
    final b = _MemBackend()
      ..set('/a.md', 'A content @/b.md')
      ..set('/b.md', 'B content @/a.md');

    // Circular import in collectImports is logged via onWarning and skipped.
    final content = await _load(b, ['/a.md']);
    expect(content, contains('A content'));
    expect(content, contains('B content'));
  });

  test('TestLoader_DepthExceededSkipped', () async {
    final b = _MemBackend()
      // Create a chain that exceeds maxImportDepth (5)
      ..set('/l0.md', '@/l1.md')
      ..set('/l1.md', '@/l2.md')
      ..set('/l2.md', '@/l3.md')
      ..set('/l3.md', '@/l4.md')
      ..set('/l4.md', '@/l5.md')
      ..set('/l5.md', '@/l6.md')
      ..set('/l6.md', 'DEEP');

    final content = await _load(b, ['/l0.md']);
    // Should have content up to the depth limit, deep file skipped.
    expect(content, contains('/l0.md'));
  });

  test('TestLoader_OnLoadWarningCallback', () async {
    final b = _MemBackend()..set('/good.md', 'GOOD CONTENT');

    // Go: fmt.Errorf("%s: %w", filePath, err).
    final warnings = <String>[];
    void onWarning(String filePath, Object error) => warnings.add('$filePath: ${goValueString(error)}');

    final content = await _load(b, ['/missing.md', '/good.md'], onWarning: onWarning);
    expect(content, contains('GOOD CONTENT'));
    expect(warnings, isNotEmpty, reason: 'expected at least one warning for missing file');
    expect(warnings[0], contains('file not found'));
  });

  test('TestMiddleware_MissingFile', () async {
    final b = _MemBackend();
    // /missing.md not set — will fail to read
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/missing.md']);

    final state = await _rewrite(mw, _state([Message.user('hello')]));
    // No agent.md content, so original messages should be passed through unchanged.
    expect(state.messages, hasLength(1), reason: 'expected 1 message (no agentmd prepended)');
  });

  test('TestMiddleware_InsertBeforeFirstUserMessage', () async {
    final b = _MemBackend()..set('/agent.md', 'agent instructions');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/agent.md']);

    // Input has a System message before the User message.
    final state = await _rewrite(mw, _state([Message.system('system prompt'), Message.user('hello')]));

    expect(state.messages, hasLength(3));
    expect(state.messages[0].role, RoleType.system);
    expect(state.messages[0].content, 'system prompt');
    expect(state.messages[1].role, RoleType.user);
    expect(state.messages[1].content, contains('agent instructions'));
    expect(state.messages[2].role, RoleType.user);
    expect(state.messages[2].content, 'hello');
  });

  test('TestMiddleware_InsertWithNoUserMessage', () async {
    final b = _MemBackend()..set('/agent.md', 'agent instructions');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/agent.md']);

    // Input has no User message at all.
    final state =
        await _rewrite(mw, _state([Message.system('system prompt'), Message.assistant('assistant reply')]));

    expect(state.messages, hasLength(3));
    expect(state.messages[0].role, RoleType.system);
    expect(state.messages[1].role, RoleType.assistant);
    expect(state.messages[2].role, RoleType.user);
    expect(state.messages[2].content, contains('agent instructions'), reason: 'expected agentmd appended at end');
  });

  test('TestLoader_ImportIOError', () async {
    // When an imported file returns a non-ErrNotExist error (e.g. I/O error),
    // the load should propagate the error (covers collectImports and loadFile error paths).
    final b = _PartialErrBackend({
      '/main.md': 'content @/broken.md',
      // /broken.md is NOT in the map, so Read returns I/O error (not ErrNotExist)
    });

    await expectLater(
      _load(b, ['/main.md']),
      throwsA(predicate((Object e) => '$e'.contains('I/O error'))),
    );
  });

  test('TestMiddleware_Idempotency', () async {
    // Calling BeforeModelRewriteState twice should NOT duplicate the agentsmd message.
    // The marker in msg.Extra[agentsMDExtraKey] prevents re-injection.
    final b = _MemBackend()..set('/agent.md', 'agent instructions');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/agent.md']);

    var state = await _rewrite(mw, _state([Message.user('hello')]));
    expect(state.messages, hasLength(2), reason: 'expected 2 messages after first call');

    // Call again with the same state (which now contains the marker message).
    state = await _rewrite(mw, state);
    expect(state.messages, hasLength(2), reason: 'expected 2 messages after second call (idempotent)');
    expect(state.messages[0].content, contains('agent instructions'));
  });

  test('TestMiddleware_ReinsertAfterRemoval', () async {
    // If the marker message is removed from state.Messages, calling
    // BeforeModelRewriteState should re-insert it.
    final b = _MemBackend()..set('/agent.md', 'agent instructions');
    final mw = AgentsMdMiddleware(backend: b, agentsMdFiles: ['/agent.md']);

    var state = await _rewrite(mw, _state([Message.user('hello')]));
    expect(state.messages, hasLength(2), reason: 'expected 2 messages after first call');

    // Simulate removal of the marker message (e.g., by summarization).
    // Keep only the original user message.
    state = await _rewrite(mw, _state([Message.user('hello')]));
    expect(state.messages, hasLength(2), reason: 'expected 2 messages after re-insert');
    expect(state.messages[0].content, contains('agent instructions'));
  });

  // TestNewTypedAgenticMessage: not ported (agentic messages are P13).
}
