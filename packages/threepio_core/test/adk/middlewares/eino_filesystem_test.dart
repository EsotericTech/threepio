// Port of eino `adk/middlewares/filesystem/filesystem_test.go` (v0.9.22), the
// tests of the middleware: construction and validation, the tool lists and
// their configs, the multimodal `read_file`, the streaming `execute` and
// `validatePages`. The tests of the individual tools are in
// `eino_filesystem_tools_test.dart`.
//
// Go's `New(ctx, cfg)` and `getFilesystemTools(ctx, cfg)` are both the
// `FilesystemMiddleware(...)` constructor (`.tools` is the list); Go's
// `config.Validate()` errors are `ArgumentError`s it throws.
//
// Ported here: TestGetFilesystemTools, TestNew,
// TestFilesystemMiddleware_BeforeAgent,
// TestFilesystemMiddleware_WrapInvokableToolCall, TestCustomToolNames,
// TestSelectToolName, TestGetOrCreateTool, TestCustomTools, TestToolConfig,
// TestToolConfigEdgeCases, TestGetFilesystemTools_DisableAllTools,
// TestGetFilesystemTools_StreamingShell, TestGetFilesystemTools_PartialDisable,
// TestNewStreamingExecuteTool, TestNew_StreamingShell,
// TestMiddlewareConfig_Validate, TestNewStreamingExecuteTool_MultipleChunks,
// TestNewStreamingExecuteTool_ExitCodeOnlyInLastChunk,
// TestGetFilesystemTools_CustomToolWithShell,
// TestMultiModalReadFileTool_TextOnly, TestMultiModalReadFileTool_Multimodal,
// TestMultiModalReadFileTool_FileType, TestMultiModalReadFileTool_PagesPassThrough,
// TestMultiModalReadFileTool_BackendNotMultiModalReader,
// TestUseMultiModalRead_Routing, TestMultiModalReadFileTool_SchemaContainsAllFields,
// TestMultiModalReadFileTool_CustomDescNoSuffix,
// TestMultiModalReadFileTool_EmptyPartDataError,
// TestMultiModalReadFileTool_NilResult, TestMultiModalReadFileTool_OffsetBeyondEOF,
// TestValidatePages.
//
// Not portable:
// * Deprecated in eino (`Config`, `NewMiddleware`, `Custom*ToolDesc`,
//   `mergeToolConfigWithDesc`): TestNewMiddleware_Validation,
//   TestConfig_Validate, TestMergeToolConfigWithDesc,
//   TestNewMiddleware_WithShell, and the sub-tests TestGetFilesystemTools
//   "custom tool descriptions", TestToolConfig "legacy Desc field still
//   works", TestToolConfigEdgeCases "nil ToolConfig.Desc falls back to
//   legacyDesc".
// * A nil config, backend or agent context is a compile-time error in Dart:
//   TestGetFilesystemTools_NilBackend (all three sub-tests), the "nil config"
//   and "nil backend" sub-tests of TestNew and TestMiddlewareConfig_Validate,
//   TestFilesystemMiddleware_BeforeAgent "nil runCtx returns nil", and
//   TestGetOrCreateTool "returns nil when custom tool is nil and createFunc
//   returns nil" (in Go that is the nil-backend case).
// * TestMultiModalReadFileTool_UnsupportedPartType: Dart's
//   `FileContentPartType` enum has only `image` and `pdf`, so an unknown part
//   type cannot be built.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/filesystem/filesystem.dart';

final ctx = RunContext.background();

/// Port of `setupTestBackend`.
Future<InMemoryBackend> _setupTestBackend() async {
  final backend = InMemoryBackend();
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/file1.txt', content: 'line1\nline2\nline3\nline4\nline5'),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/file2.go', content: 'package main\n\nfunc main() {\n\tprintln("hello")\n}'),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/dir1/file3.txt', content: 'hello world\nfoo bar\nhello again'),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/dir1/file4.py', content: "print('hello')\nprint('world')"),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/dir2/file5.go', content: 'package test\n\nfunc test() {}'),
  );
  return backend;
}

Future<List<String>> _toolNames(List<BaseTool> tools) async => [for (final t in tools) (await t.info()).name];

Future<String?> _descOf(List<BaseTool> tools, String name) async {
  for (final t in tools) {
    final info = await t.info();
    if (info.name == name) return info.desc;
  }
  return null;
}

Matcher _argumentError(String text) =>
    isA<ArgumentError>().having((e) => '${e.message}', 'message', contains(text));

/// Port of `mockShellBackend`: a backend (Go embeds `filesystem.Backend`)
/// that is also a [Shell] returning [resp].
final class _MockShellBackend implements FilesystemBackend, Shell {
  _MockShellBackend({this.backend, this.resp = const ExecuteResponse()});

  final FilesystemBackend? backend;
  final ExecuteResponse resp;

  FilesystemBackend get _backend => backend ?? (throw StateError('no backend'));

  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) async => resp;

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) => _backend.lsInfo(ctx, request);

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) => _backend.read(ctx, request);

  @override
  Future<List<GrepMatch>> grepRaw(RunContext ctx, GrepRequest request) => _backend.grepRaw(ctx, request);

  @override
  Future<List<FileInfo>> globInfo(RunContext ctx, GlobInfoRequest request) => _backend.globInfo(ctx, request);

  @override
  Future<void> write(RunContext ctx, WriteRequest request) => _backend.write(ctx, request);

  @override
  Future<void> edit(RunContext ctx, EditRequest request) => _backend.edit(ctx, request);
}

/// The Go streaming shell mocks: each one sends [chunks] (and [error] after
/// them, if any) and closes.
final class _MockStreamingShell implements StreamingShell {
  _MockStreamingShell(this.chunks, {this.error});

  /// Port of `mockStreamingShell`.
  _MockStreamingShell.ok() : this(const [ExecuteResponse(output: 'streaming output', exitCode: 0)]);

  final List<ExecuteResponse> chunks;
  final Object? error;

  @override
  Future<StreamReader<ExecuteResponse>> executeStreaming(RunContext ctx, ExecuteRequest request) async {
    final (reader, writer) = pipe<ExecuteResponse>(capacity: 10);
    chunks.forEach(writer.send);
    final error = this.error;
    if (error != null) writer.sendError(error);
    await writer.close();
    return reader;
  }
}

/// Port of `mockStreamingShellWithError`.
final class _StreamingShellWithError implements StreamingShell {
  @override
  Future<StreamReader<ExecuteResponse>> executeStreaming(RunContext ctx, ExecuteRequest request) async =>
      throw const ThreepioException('streaming shell error');
}

/// Port of `multiModalBackend`: an [InMemoryBackend] that is also a
/// [MultiModalReader] answering with [multiModalReadFunc].
final class _MultiModalBackend implements FilesystemBackend, MultiModalReader {
  _MultiModalBackend(this.base, this.multiModalReadFunc);

  final InMemoryBackend base;
  final Future<MultiFileContent> Function(RunContext ctx, MultiModalReadRequest request) multiModalReadFunc;

  @override
  Future<MultiFileContent> multiModalRead(RunContext ctx, MultiModalReadRequest request) =>
      multiModalReadFunc(ctx, request);

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) => base.lsInfo(ctx, request);

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) => base.read(ctx, request);

  @override
  Future<List<GrepMatch>> grepRaw(RunContext ctx, GrepRequest request) => base.grepRaw(ctx, request);

  @override
  Future<List<FileInfo>> globInfo(RunContext ctx, GlobInfoRequest request) => base.globInfo(ctx, request);

  @override
  Future<void> write(RunContext ctx, WriteRequest request) => base.write(ctx, request);

  @override
  Future<void> edit(RunContext ctx, EditRequest request) => base.edit(ctx, request);
}

/// A multimodal backend whose read is the plain read of [base].
_MultiModalBackend _textReadingBackend(InMemoryBackend base) =>
    _MultiModalBackend(base, (ctx, request) async => MultiFileContent(fileContent: await base.read(ctx, request)));

Future<ToolResult> _invokeEnhanced(BaseTool tool, String input) =>
    (tool as EnhancedInvokableTool).enhancedInvokableRun(ctx, ToolArgument(input));

/// All chunks of [reader] until the end; an error fails the test (Go:
/// `assert.NoError(t, recvErr)` in the loop).
Future<List<String>> _collect(StreamReader<String> reader) async {
  final chunks = <String>[];
  try {
    while (true) {
      try {
        chunks.add(await reader.recv());
      } on StreamEOFException {
        break;
      }
    }
  } finally {
    await reader.close();
  }
  return chunks;
}

Future<StreamReader<String>> _streamRun(BaseTool tool, String input) =>
    (tool as StreamableTool).streamableRun(ctx, input);

void main() {
  late InMemoryBackend backend;

  setUp(() async {
    backend = await _setupTestBackend();
  });

  group('TestGetFilesystemTools', () {
    test('returns 6 tools for regular Backend', () async {
      final tools = FilesystemMiddleware(backend: backend).tools;
      expect(tools, hasLength(6));
      final toolNames = await _toolNames(tools);
      expect(toolNames, containsAll(['ls', 'read_file', 'write_file', 'edit_file', 'glob', 'grep']));
    });

    test('returns 7 tools for Shell', () async {
      final shellBackend = _MockShellBackend(backend: backend, resp: const ExecuteResponse(output: 'ok'));
      final tools = FilesystemMiddleware(backend: shellBackend, shell: shellBackend).tools;
      expect(tools, hasLength(7));
      expect(await _toolNames(tools), contains('execute'));
    });
  });

  group('TestNew', () {
    test('valid config with default settings', () {
      final m = FilesystemMiddleware(backend: backend);
      expect(m, isA<ChatModelAgentMiddleware>());
      expect(m.tools, hasLength(6));
    });

    test('custom system prompt', () {
      const customPrompt = 'Custom system prompt';
      final m = FilesystemMiddleware(backend: backend, customSystemPrompt: customPrompt);
      // Go: fm.additionalInstruction.
      expect(m.customSystemPrompt, customPrompt);
    });

    test('ShellBackend adds execute tool', () {
      final shellBackend = _MockShellBackend(backend: backend, resp: const ExecuteResponse(output: 'ok'));
      final m = FilesystemMiddleware(backend: shellBackend, shell: shellBackend);
      expect(m.tools, hasLength(7));
    });
  });

  group('TestFilesystemMiddleware_BeforeAgent', () {
    test('adds instruction and tools to context', () async {
      final m = FilesystemMiddleware(backend: backend);
      final runCtx = ChatModelAgentContext(instruction: 'Original instruction', tools: [], returnDirectly: {});
      final (newCtx, newRunCtx) = await m.beforeAgent(ctx, runCtx);
      expect(newCtx, isNotNull);
      expect(newRunCtx, isNotNull);
      expect(newRunCtx.instruction, contains('Original instruction'));
      expect(newRunCtx.tools, hasLength(6));
    });
  });

  group('TestFilesystemMiddleware_WrapInvokableToolCall', () {
    test('small result passes through unchanged', () async {
      final m = FilesystemMiddleware(backend: backend);
      final wrapped = m.wrapInvokableToolCall(
        ctx,
        (ctx, args, options) async => 'small result',
        const ToolContext(name: 'test_tool', callId: 'call-1'),
      );
      expect(await wrapped(ctx, '{}', null), 'small result');
    });
  });

  group('TestCustomToolNames', () {
    test('custom tool names applied to individual tools', () async {
      expect((await newLsTool(backend, 'list_files', '').info()).name, 'list_files');
      expect((await newReadFileTool(backend, 'read', '').info()).name, 'read');
      expect((await newWriteFileTool(backend, 'write', '').info()).name, 'write');
      expect((await newEditFileTool(backend, 'edit', '').info()).name, 'edit');
      expect((await newGlobTool(backend, 'find_files', '').info()).name, 'find_files');
      expect((await newGrepTool(backend, 'search', '').info()).name, 'search');
    });

    test('default tool names when custom names not provided', () async {
      expect((await newLsTool(backend, '', '').info()).name, FilesystemMiddleware.toolNameLs);
      expect((await newReadFileTool(backend, '', '').info()).name, FilesystemMiddleware.toolNameReadFile);
      expect((await newWriteFileTool(backend, '', '').info()).name, FilesystemMiddleware.toolNameWriteFile);
      expect((await newEditFileTool(backend, '', '').info()).name, FilesystemMiddleware.toolNameEditFile);
      expect((await newGlobTool(backend, '', '').info()).name, FilesystemMiddleware.toolNameGlob);
      expect((await newGrepTool(backend, '', '').info()).name, FilesystemMiddleware.toolNameGrep);
    });

    test('custom execute tool name', () async {
      final shellBackend = _MockShellBackend(backend: backend, resp: const ExecuteResponse(output: 'ok'));
      expect((await newExecuteTool(shellBackend, 'run_command', '').info()).name, 'run_command');
    });

    test('custom tool names via ToolConfig in getFilesystemTools', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: const FilesystemToolConfig(name: 'list_files'),
        readFileToolConfig: const FilesystemToolConfig(name: 'read'),
      ).tools;
      expect(await _toolNames(tools), containsAll(['list_files', 'read']));
    });

    // In Dart `New` and `getFilesystemTools` are the same constructor; this
    // repeats the previous test on the middleware's tools.
    test('custom tool names via ToolConfig in middleware', () async {
      final m = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: const FilesystemToolConfig(name: 'list_files'),
        readFileToolConfig: const FilesystemToolConfig(name: 'read'),
      );
      expect(await _toolNames(m.tools), containsAll(['list_files', 'read']));
    });
  });

  // `selectToolName` is private in Dart (`_selectName`): tested through
  // `newLsTool`, whose default name is `ls`.
  group('TestSelectToolName', () {
    test('returns custom name when provided', () async {
      expect((await newLsTool(backend, 'custom_tool', '').info()).name, 'custom_tool');
    });

    test('returns default name when custom name is nil', () async {
      expect((await newLsTool(backend, '', '').info()).name, FilesystemMiddleware.toolNameLs);
    });
  });

  // `getOrCreateTool` is inlined in the Dart constructor: tested through
  // `FilesystemToolConfig.customTool` and the creation of the built-in tool.
  group('TestGetOrCreateTool', () {
    test('returns custom tool when provided', () {
      final customTool = newLsTool(backend, '', '');
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: FilesystemToolConfig(customTool: customTool),
      ).tools;
      expect(tools.first, same(customTool));
    });

    test('calls createFunc when custom tool is nil', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: const FilesystemToolConfig(disable: true),
      ).tools;
      // The built-in read_file tool was created in the first slot left.
      expect((await tools.first.info()).name, FilesystemMiddleware.toolNameReadFile);
    });

    test('propagates error from createFunc', () {
      // The creation of the multimodal read tool fails for a backend that is
      // not a MultiModalReader; the constructor throws that error.
      expect(
        () => FilesystemMiddleware(backend: backend, useMultiModalRead: true),
        throwsA(_argumentError('MultiModalReader')),
      );
    });
  });

  group('TestCustomTools', () {
    // Go leaves the backend nil here, so the custom tool is the only one
    // (`Len 1`); Dart requires a backend, so the built-in tools of the other
    // slots are there too, and the test checks that the custom tool replaces
    // the built-in one of its slot.
    final slots = <({
      String name,
      BaseTool Function(FilesystemBackend b) create,
      FilesystemMiddleware Function(FilesystemBackend b, BaseTool custom) build,
      int index,
    })>[
      (
        name: 'custom ls tool is used via ToolConfig',
        create: (b) => newLsTool(b, '', ''),
        build: (b, c) => FilesystemMiddleware(backend: b, lsToolConfig: FilesystemToolConfig(customTool: c)),
        index: 0,
      ),
      (
        name: 'custom read file tool is used via ToolConfig',
        create: (b) => newReadFileTool(b, '', ''),
        build: (b, c) => FilesystemMiddleware(backend: b, readFileToolConfig: FilesystemToolConfig(customTool: c)),
        index: 1,
      ),
      (
        name: 'custom write file tool is used via ToolConfig',
        create: (b) => newWriteFileTool(b, '', ''),
        build: (b, c) => FilesystemMiddleware(backend: b, writeFileToolConfig: FilesystemToolConfig(customTool: c)),
        index: 2,
      ),
      (
        name: 'custom edit file tool is used via ToolConfig',
        create: (b) => newEditFileTool(b, '', ''),
        build: (b, c) => FilesystemMiddleware(backend: b, editFileToolConfig: FilesystemToolConfig(customTool: c)),
        index: 3,
      ),
      (
        name: 'custom glob tool is used via ToolConfig',
        create: (b) => newGlobTool(b, '', ''),
        build: (b, c) => FilesystemMiddleware(backend: b, globToolConfig: FilesystemToolConfig(customTool: c)),
        index: 4,
      ),
      (
        name: 'custom grep tool is used via ToolConfig',
        create: (b) => newGrepTool(b, '', ''),
        build: (b, c) => FilesystemMiddleware(backend: b, grepToolConfig: FilesystemToolConfig(customTool: c)),
        index: 5,
      ),
    ];
    for (final slot in slots) {
      test(slot.name, () async {
        final custom = slot.create(backend);
        final tools = slot.build(backend, custom).tools;
        expect(tools, hasLength(6));
        expect(tools[slot.index], same(custom));
        final name = (await custom.info()).name;
        expect((await _toolNames(tools)).where((n) => n == name), hasLength(1));
      });
    }

    test('multiple custom tools can be used together', () {
      final customLsTool = newLsTool(backend, '', '');
      final customReadTool = newReadFileTool(backend, '', '');
      final customGlobTool = newGlobTool(backend, '', '');
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: FilesystemToolConfig(customTool: customLsTool),
        readFileToolConfig: FilesystemToolConfig(customTool: customReadTool),
        globToolConfig: FilesystemToolConfig(customTool: customGlobTool),
      ).tools;
      // Go: Len 3 (nil backend); here the three custom tools among the six.
      expect(tools, hasLength(6));
      expect(tools, containsAll([same(customLsTool), same(customReadTool), same(customGlobTool)]));
    });

    test('custom tools take precedence over backend', () {
      final customLsTool = newLsTool(backend, '', '');
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: FilesystemToolConfig(customTool: customLsTool),
      ).tools;
      expect(tools, contains(same(customLsTool)), reason: 'custom ls tool should be in the tools list');
    });

    test('backend tools are created when custom tools not provided', () {
      final tools = FilesystemMiddleware(backend: backend).tools;
      expect(tools, isNotEmpty, reason: 'should create backend tools when custom tools not provided');
    });
  });

  group('TestToolConfig', () {
    test('use new ToolConfig', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: const FilesystemToolConfig(name: 'my_ls'),
      ).tools;
      expect(tools, hasLength(6));
      expect(await _toolNames(tools), contains('my_ls'));
    });

    test('ToolConfig disabled', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: const FilesystemToolConfig(disable: true),
      ).tools;
      expect(tools, hasLength(5));
      expect(await _toolNames(tools), isNot(contains(FilesystemMiddleware.toolNameLs)));
    });

    test('ToolConfig with custom tool', () {
      final customLsTool = newLsTool(backend, '', '');
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: FilesystemToolConfig(customTool: customLsTool),
      ).tools;
      expect(tools, contains(same(customLsTool)));
    });

    // Without the deprecated CustomLsToolDesc (not ported): the
    // ToolConfig.Desc is the description.
    test('ToolConfig Desc takes precedence over legacy Desc', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: const FilesystemToolConfig(desc: 'new description'),
      ).tools;
      expect(await _descOf(tools, FilesystemMiddleware.toolNameLs), 'new description');
    });

    test('multiple ToolConfig', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: const FilesystemToolConfig(name: 'my_ls'),
        readFileToolConfig: const FilesystemToolConfig(name: 'my_read'),
      ).tools;
      expect(await _toolNames(tools), containsAll(['my_ls', 'my_read']));
    });
  });

  group('TestToolConfigEdgeCases', () {
    test('nil ToolConfig.Desc with nil legacyDesc', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        // ignore: avoid_redundant_argument_values
        lsToolConfig: const FilesystemToolConfig(desc: null),
      ).tools;
      expect(await _toolNames(tools), contains(FilesystemMiddleware.toolNameLs),
          reason: 'ls tool should be created even with nil Desc');
    });

    test('CustomTool with Disable flag should not create tool', () async {
      final customLsTool = newLsTool(backend, '', '');
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: FilesystemToolConfig(customTool: customLsTool, disable: true),
      ).tools;
      expect(await _toolNames(tools), isNot(contains(FilesystemMiddleware.toolNameLs)),
          reason: 'disabled tool should not be created even if CustomTool is set');
    });

    // Without the deprecated CustomLsToolDesc (not ported).
    test('multiple ToolConfig with conflicting settings', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        // ignore: avoid_redundant_argument_values
        lsToolConfig: const FilesystemToolConfig(name: 'custom_ls', desc: 'custom desc', disable: false),
        readFileToolConfig: const FilesystemToolConfig(disable: true),
      ).tools;
      final names = await _toolNames(tools);
      expect(names, contains('custom_ls'), reason: 'ls tool should be created');
      expect(await _descOf(tools, 'custom_ls'), 'custom desc');
      expect(names, isNot(contains(FilesystemMiddleware.toolNameReadFile)), reason: 'read_file tool should be disabled');
    });

    // Go's nil LsToolConfig is Dart's default `FilesystemToolConfig()`.
    test('nil ToolConfig with nil legacyDesc creates default tool', () async {
      final tools = FilesystemMiddleware(backend: backend).tools;
      expect(await _toolNames(tools), contains(FilesystemMiddleware.toolNameLs),
          reason: 'tool should be created with backend even when config is nil');
    });

    test('empty Name in ToolConfig uses default name', () async {
      final tools = FilesystemMiddleware(
        backend: backend,
        // ignore: avoid_redundant_argument_values
        lsToolConfig: const FilesystemToolConfig(name: ''),
      ).tools;
      expect(await _toolNames(tools), contains(FilesystemMiddleware.toolNameLs),
          reason: 'tool should use default name when Name is empty');
    });
  });

  test('TestGetFilesystemTools_DisableAllTools', () {
    final tools = FilesystemMiddleware(
      backend: backend,
      lsToolConfig: const FilesystemToolConfig(disable: true),
      readFileToolConfig: const FilesystemToolConfig(disable: true),
      writeFileToolConfig: const FilesystemToolConfig(disable: true),
      editFileToolConfig: const FilesystemToolConfig(disable: true),
      globToolConfig: const FilesystemToolConfig(disable: true),
      grepToolConfig: const FilesystemToolConfig(disable: true),
    ).tools;
    expect(tools, isEmpty);
  });

  group('TestGetFilesystemTools_StreamingShell', () {
    test('returns 7 tools with StreamingShell', () async {
      final tools = FilesystemMiddleware(backend: backend, streamingShell: _MockStreamingShell.ok()).tools;
      expect(tools, hasLength(7));
      expect(await _toolNames(tools), contains(FilesystemMiddleware.toolNameExecute));
    });

    test('StreamingShell takes precedence over Shell', () {
      final shellBackend = _MockShellBackend(backend: backend, resp: const ExecuteResponse(output: 'ok'));
      // When both are set, validation fails.
      expect(
        () => FilesystemMiddleware(backend: backend, shell: shellBackend, streamingShell: _MockStreamingShell.ok()),
        throwsA(_argumentError('shell and streaming shell should not be both set')),
      );
    });
  });

  test('TestGetFilesystemTools_PartialDisable', () async {
    final tools = FilesystemMiddleware(
      backend: backend,
      lsToolConfig: const FilesystemToolConfig(disable: true),
      readFileToolConfig: const FilesystemToolConfig(disable: true),
    ).tools;
    expect(tools, hasLength(4));
    final toolNames = await _toolNames(tools);
    expect(toolNames, isNot(contains(FilesystemMiddleware.toolNameLs)));
    expect(toolNames, isNot(contains(FilesystemMiddleware.toolNameReadFile)));
    expect(
      toolNames,
      containsAll([
        FilesystemMiddleware.toolNameWriteFile,
        FilesystemMiddleware.toolNameEditFile,
        FilesystemMiddleware.toolNameGlob,
        FilesystemMiddleware.toolNameGrep,
      ]),
    );
  });

  group('TestNewStreamingExecuteTool', () {
    test('successful streaming execution', () async {
      final executeTool = newStreamingExecuteTool(_MockStreamingShell.ok(), '', '');
      final chunks = await _collect(await _streamRun(executeTool, '{"command": "echo hello"}'));
      expect(chunks, isNotEmpty);
      expect(chunks.join(), contains('streaming output'));
    });

    test('streaming execution with ExecuteStreaming error', () async {
      final executeTool = newStreamingExecuteTool(_StreamingShellWithError(), '', '');
      await expectLater(
        _streamRun(executeTool, '{"command": "fail"}'),
        throwsA(predicate((e) => '$e'.contains('streaming shell error'))),
      );
    });

    test('streaming execution with recv error', () async {
      // Port of mockStreamingShellWithRecvError.
      final executeTool = newStreamingExecuteTool(
        _MockStreamingShell(const [], error: const ThreepioException('recv error during streaming')),
        '',
        '',
      );
      final sr = await _streamRun(executeTool, '{"command": "echo hello"}');
      var gotError = false;
      try {
        for (var i = 0; i < 100; i++) {
          try {
            await sr.recv();
          } on StreamEOFException {
            break;
            // The error of the shell's stream, whatever its type.
            // ignore: avoid_catches_without_on_clauses
          } catch (recvErr) {
            gotError = true;
            expect('$recvErr', contains('recv error during streaming'));
            break;
          }
        }
      } finally {
        await sr.close();
      }
      expect(gotError, isTrue);
    });

    test('streaming execution with non-zero exit code', () async {
      // Port of mockStreamingShellWithExitCode{exitCode: 1}.
      final executeTool = newStreamingExecuteTool(
        _MockStreamingShell(const [ExecuteResponse(output: 'some output', exitCode: 1)]),
        '',
        '',
      );
      final chunks = await _collect(await _streamRun(executeTool, '{"command": "false"}'));
      expect(chunks.join(), contains('[Command failed with exit code 1]'));
    });

    test('streaming execution with zero exit code and no output', () async {
      // Port of mockStreamingShellNoOutput.
      final executeTool = newStreamingExecuteTool(_MockStreamingShell(const [ExecuteResponse(exitCode: 0)]), '', '');
      final chunks = await _collect(await _streamRun(executeTool, '{"command": "true"}'));
      expect(chunks.join(), contains('[Command executed successfully with no output]'));
    });

    test('streaming execution with truncated output', () async {
      // Port of mockStreamingShellTruncated.
      final executeTool = newStreamingExecuteTool(
        _MockStreamingShell(const [ExecuteResponse(output: 'partial', truncated: true, exitCode: 0)]),
        '',
        '',
      );
      final result = (await _collect(await _streamRun(executeTool, '{"command": "cat largefile"}'))).join();
      expect(result, contains('partial'));
      expect(result, contains('[Output was truncated due to size limits]'));
    });

    test('streaming execution with nil chunk skipped', () async {
      // Port of mockStreamingShellNilChunk. A Dart stream of ExecuteResponse
      // cannot carry a nil chunk; an empty response is the nearest (nothing
      // to send, no exit code).
      final executeTool = newStreamingExecuteTool(
        _MockStreamingShell(const [ExecuteResponse(), ExecuteResponse(output: 'after nil', exitCode: 0)]),
        '',
        '',
      );
      final chunks = await _collect(await _streamRun(executeTool, '{"command": "echo test"}'));
      expect(chunks.join(), contains('after nil'));
    });

    test('streaming execution with custom name and desc', () async {
      final executeTool = newStreamingExecuteTool(_MockStreamingShell.ok(), 'custom_execute', 'custom desc');
      final info = await executeTool.info();
      expect(info.name, 'custom_execute');
      expect(info.desc, 'custom desc');
    });
  });

  group('TestNew_StreamingShell', () {
    test('StreamingShell adds streaming execute tool', () {
      final m = FilesystemMiddleware(backend: backend, streamingShell: _MockStreamingShell.ok());
      expect(m.tools, hasLength(7));
    });

    test('both Shell and StreamingShell returns error', () {
      expect(
        () => FilesystemMiddleware(
          backend: backend,
          shell: _MockShellBackend(backend: backend, resp: const ExecuteResponse(output: 'ok')),
          streamingShell: _MockStreamingShell.ok(),
        ),
        throwsA(_argumentError('shell and streaming shell should not be both set')),
      );
    });
  });

  group('TestMiddlewareConfig_Validate', () {
    test('both shells returns error', () {
      expect(
        () => FilesystemMiddleware(backend: backend, shell: _MockShellBackend(), streamingShell: _MockStreamingShell.ok()),
        throwsA(_argumentError('shell and streaming shell should not be both set')),
      );
    });

    test('valid config passes', () {
      expect(() => FilesystemMiddleware(backend: backend), returnsNormally);
    });
  });

  test('TestNewStreamingExecuteTool_MultipleChunks', () async {
    // Port of mockStreamingShellMultiChunk.
    final executeTool = newStreamingExecuteTool(
      _MockStreamingShell(const [
        ExecuteResponse(output: 'chunk1\n'),
        ExecuteResponse(output: 'chunk2\n'),
        ExecuteResponse(output: 'chunk3\n', exitCode: 0),
      ]),
      '',
      '',
    );
    final chunks = await _collect(await _streamRun(executeTool, '{"command": "long-running"}'));
    // Should have received multiple chunks.
    expect(chunks.length, greaterThanOrEqualTo(3));
    final result = chunks.join();
    expect(result, contains('chunk1'));
    expect(result, contains('chunk2'));
    expect(result, contains('chunk3'));
  });

  test('TestNewStreamingExecuteTool_ExitCodeOnlyInLastChunk', () async {
    // Port of mockStreamingShellExitCodeLast{exitCode: 2}.
    final executeTool = newStreamingExecuteTool(
      _MockStreamingShell(const [ExecuteResponse(output: 'output line'), ExecuteResponse(exitCode: 2)]),
      '',
      '',
    );
    final result = (await _collect(await _streamRun(executeTool, '{"command": "fail-at-end"}'))).join();
    expect(result, contains('output line'));
    expect(result, contains('[Command failed with exit code 2]'));
  });

  group('TestGetFilesystemTools_CustomToolWithShell', () {
    test('custom tool replaces default for all disabled except custom', () async {
      final customLs = newLsTool(backend, 'my_ls', 'my ls desc');
      final tools = FilesystemMiddleware(
        backend: backend,
        lsToolConfig: FilesystemToolConfig(customTool: customLs),
      ).tools;
      expect(await _toolNames(tools), contains('my_ls'));
    });
  });

  test('TestMultiModalReadFileTool_TextOnly', () async {
    final mmTool = newMultiModalReadFileTool(_textReadingBackend(backend), '', '');
    final result = await _invokeEnhanced(mmTool, '{"file_path": "/file1.txt", "offset": 0, "limit": 100}');
    expect(result.parts, hasLength(1));
    expect(result.parts[0].type, ToolPartType.text);
    expect(result.parts[0].text, contains('line1'));
    expect(result.parts[0].text, contains('line5'));
  });

  test('TestMultiModalReadFileTool_Multimodal', () async {
    final imgData = utf8.encode('rawimagedata');
    final eb = _MultiModalBackend(
      backend,
      (ctx, request) async => MultiFileContent(
        parts: [FileContentPart(type: FileContentPartType.image, mimeType: 'image/png', data: imgData)],
      ),
    );
    final mmTool = newMultiModalReadFileTool(eb, '', '');
    final result = await _invokeEnhanced(mmTool, '{"file_path": "/image.png", "offset": 0, "limit": 100}');
    expect(result.parts, hasLength(1));
    expect(result.parts[0].type, ToolPartType.image);

    // The Base64 encoding is right.
    final image = result.parts[0].image;
    expect(image, isNotNull);
    expect(image!.common.mimeType, 'image/png');
    expect(image.common.base64Data, base64Encode(imgData));
  });

  test('TestMultiModalReadFileTool_FileType', () async {
    final pdfData = utf8.encode('fakepdfcontent');
    final eb = _MultiModalBackend(
      backend,
      (ctx, request) async => MultiFileContent(
        parts: [FileContentPart(type: FileContentPartType.pdf, mimeType: 'application/pdf', data: pdfData)],
      ),
    );
    final mmTool = newMultiModalReadFileTool(eb, '', '');
    final result = await _invokeEnhanced(mmTool, '{"file_path": "/doc.pdf", "offset": 0, "limit": 100}');
    expect(result.parts, hasLength(1));
    expect(result.parts[0].type, ToolPartType.file);
    final file = result.parts[0].file;
    expect(file, isNotNull);
    expect(file!.common.mimeType, 'application/pdf');
    expect(file.common.base64Data, base64Encode(pdfData));
  });

  test('TestMultiModalReadFileTool_PagesPassThrough', () async {
    String? capturedPages;
    final eb = _MultiModalBackend(backend, (ctx, request) async {
      capturedPages = request.pages;
      return const MultiFileContent(fileContent: FileContent('page content'));
    });
    final mmTool = newMultiModalReadFileTool(eb, '', '');
    await _invokeEnhanced(mmTool, '{"file_path": "/doc.pdf", "pages": "1-5"}');
    expect(capturedPages, '1-5');
  });

  test('TestMultiModalReadFileTool_BackendNotMultiModalReader', () {
    expect(() => newMultiModalReadFileTool(backend, '', ''), throwsA(_argumentError('MultiModalReader')));
  });

  test('TestUseMultiModalRead_Routing', () async {
    final eb = _textReadingBackend(backend);

    // useMultiModalRead false: the standard tool.
    final tools = FilesystemMiddleware(backend: backend).tools;
    for (final tl in tools) {
      if ((await tl.info()).name == FilesystemMiddleware.toolNameReadFile) {
        expect(tl, isNot(isA<EnhancedInvokableTool>()),
            reason: 'should be standard InvokableTool when UseMultiModalRead=false');
      }
    }

    // useMultiModalRead true with a multimodal backend: the enhanced tool.
    final tools2 = FilesystemMiddleware(backend: eb, useMultiModalRead: true).tools;
    for (final tl in tools2) {
      if ((await tl.info()).name == FilesystemMiddleware.toolNameReadFile) {
        expect(tl, isA<EnhancedInvokableTool>(), reason: 'should be EnhancedInvokableTool when UseMultiModalRead=true');
      }
    }
  });

  test('TestMultiModalReadFileTool_SchemaContainsAllFields', () async {
    final mmTool = newMultiModalReadFileTool(_textReadingBackend(backend), '', '');
    final info = await mmTool.info();
    final js = info.paramsOneOf!.toJsonSchema();
    expect(js.properties, isNotEmpty, reason: 'schema should have properties');
    for (final field in ['file_path', 'offset', 'limit', 'pages']) {
      expect(js.properties.containsKey(field), isTrue, reason: 'expected JSON schema to contain field "$field"');
    }
  });

  test('TestMultiModalReadFileTool_CustomDescNoSuffix', () async {
    final eb = _textReadingBackend(backend);
    const customDesc = 'my custom read tool description';
    final mmTool = newMultiModalReadFileTool(eb, '', customDesc);
    expect((await mmTool.info()).desc, customDesc, reason: 'custom desc should not be augmented with multimodal suffix');

    // With an empty desc (the default one), the suffix is appended.
    final defaultTool = newMultiModalReadFileTool(eb, '', '');
    expect((await defaultTool.info()).desc, contains('multimodal'),
        reason: 'default desc should include multimodal suffix');
  });

  test('TestMultiModalReadFileTool_EmptyPartDataError', () async {
    final eb = _MultiModalBackend(
      backend,
      (ctx, request) async => MultiFileContent(
        // Go: Data nil.
        parts: [FileContentPart(type: FileContentPartType.image, mimeType: 'image/png', data: Uint8List(0))],
      ),
    );
    final mmTool = newMultiModalReadFileTool(eb, '', '');
    await expectLater(
      _invokeEnhanced(mmTool, '{"file_path": "/x"}'),
      throwsA(predicate((e) => '$e'.contains('empty'))),
    );
  });

  test('TestMultiModalReadFileTool_NilResult', () async {
    // Go's MultiModalRead returns nil; Dart's returns a non-nullable
    // MultiFileContent, so the nearest is one with no content and no parts.
    final eb = _MultiModalBackend(backend, (ctx, request) async => const MultiFileContent());
    final mmTool = newMultiModalReadFileTool(eb, '', '');
    final result = await _invokeEnhanced(mmTool, '{"file_path": "/missing.txt"}');
    expect(result.parts, hasLength(1));
    expect(result.parts[0].type, ToolPartType.text);
    expect(result.parts[0].text, contains('No content found at path'));
    expect(result.parts[0].text, contains('/missing.txt'));
  });

  test('TestMultiModalReadFileTool_OffsetBeyondEOF', () async {
    final mmTool = newMultiModalReadFileTool(_textReadingBackend(backend), '', '');
    final result = await _invokeEnhanced(mmTool, '{"file_path": "/file1.txt", "offset": 300, "limit": 100}');
    expect(result.parts, hasLength(1));
    expect(result.parts[0].text, isNot('   300\t'));
    expect(result.parts[0].text, contains('offset 300'));
  });

  group('TestValidatePages', () {
    final cases = <({String name, String pages, String wantErr})>[
      (name: 'single page', pages: '3', wantErr: ''),
      (name: 'valid range', pages: '1-10', wantErr: ''),
      (name: 'same start end', pages: '1-1', wantErr: ''),
      (name: 'max 20 pages', pages: '1-20', wantErr: ''),
      (name: 'trailing dash', pages: '1-', wantErr: 'expected format'),
      (name: 'leading dash', pages: '-5', wantErr: 'expected format'),
      (name: 'non-numeric', pages: 'abc', wantErr: 'expected format'),
      (name: 'non-numeric end', pages: '1-abc', wantErr: 'expected format'),
      (name: 'zero start', pages: '0-5', wantErr: 'expected format'),
      (name: 'zero end', pages: '1-0', wantErr: 'expected format'),
      (name: 'end less than start', pages: '10-5', wantErr: 'end page must be >= start page'),
      (name: 'exceeds max pages', pages: '1-21', wantErr: 'range exceeds maximum of 20'),
      (name: 'large range', pages: '1-30', wantErr: 'range exceeds maximum of 20'),
    ];
    for (final tt in cases) {
      test(tt.name, () {
        if (tt.wantErr.isEmpty) {
          expect(() => validatePages(tt.pages), returnsNormally);
        } else {
          expect(
            () => validatePages(tt.pages),
            throwsA(isA<ThreepioException>().having((e) => e.message, 'message', contains(tt.wantErr))),
          );
        }
      });
    }
  });
}
