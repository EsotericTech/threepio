// Unit tests of the P8 additions that no ported Go test covers: the helpers
// that keep Go's byte and text rules (`internal/go_compat.dart`), the new
// filesystem types, the JSON of the summarization events, the Chinese
// prompts, and the export surface of `adk.dart`.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/internal/go_compat.dart';
import 'package:threepio_core/src/adk/middlewares/internal/run_local.dart';

final ctx = RunContext.background();

void main() {
  group('go_compat', () {
    test('utf8Length counts UTF-8 bytes like Go len()', () {
      expect(utf8Length(''), 0);
      expect(utf8Length('abc'), 3);
      expect(utf8Length('é'), 2);
      expect(utf8Length('中文'), 6);
      expect(utf8Length('😀'), 4);
      expect(utf8Length('a中😀'), 8);
    });

    test('utf8Prefix keeps whole characters within the byte budget', () {
      expect(utf8Prefix('abc', 0), '');
      expect(utf8Prefix('abc', -1), '');
      expect(utf8Prefix('abc', 5), 'abc');
      expect(utf8Prefix('中文字', 3), '中');
      expect(utf8Prefix('中文字', 4), '中');
      expect(utf8Prefix('中文字', 5), '中');
      expect(utf8Prefix('中文字', 6), '中文');
      expect(utf8Prefix('a😀b', 4), 'a');
      expect(utf8Prefix('a😀b', 5), 'a😀');
    });

    test('utf8Suffix keeps whole characters within the byte budget', () {
      expect(utf8Suffix('abc', 0), '');
      expect(utf8Suffix('abc', 9), 'abc');
      expect(utf8Suffix('中文字', 3), '字');
      expect(utf8Suffix('中文字', 4), '字');
      expect(utf8Suffix('中文字', 6), '文字');
      expect(utf8Suffix('a😀b', 4), 'b');
      expect(utf8Suffix('a😀b', 5), '😀b');
    });

    test('utf8From is Go s[start:] moved to a character boundary', () {
      expect(utf8From('abc', 0), 'abc');
      expect(utf8From('abc', 1), 'bc');
      expect(utf8From('abc', 3), '');
      expect(utf8From('abc', 7), '');
      expect(utf8From('中文', 3), '文');
      expect(utf8From('中文', 1), '文');
    });

    test('goSprintf handles %s, %d, %v and %%', () {
      expect(goSprintf('a %s b %d c %v', ['x', 3, null]), 'a x b 3 c <nil>');
      expect(goSprintf('100%% %s', ['done']), '100% done');
      expect(goSprintf('%s and %s', ['one']), 'one and %!s(MISSING)');
      expect(goSprintf('%x stays', ['ignored']), '%x stays');
      expect(goSprintf('err: %v', [const ThreepioException('boom')]), 'err: boom');
    });

    test('formatNamed replaces {name}, keeps doubled braces, and rejects unknown names', () {
      expect(formatNamed('{a}-{b}', {'a': 1, 'b': 'x'}), '1-x');
      expect(formatNamed('{{literal}} {a}', {'a': 'v'}), '{literal} v');
      expect(() => formatNamed('{missing}', {}), throwsA(isA<ThreepioFormatException>()));
      expect(() => formatNamed('{open', {}), throwsA(isA<ThreepioFormatException>()));
    });

    test('path helpers follow Go filepath on POSIX paths', () {
      expect(goClean(''), '.');
      expect(goClean('/a/./b/../c/'), '/a/c');
      expect(goJoin(['/tmp', 'trunc', 'id']), '/tmp/trunc/id');
      expect(goJoin(['', 'a', '', 'b']), 'a/b');
      expect(goJoin(['a', '../b']), 'b');
      expect(goJoin(['', '']), '');
      expect(goDir('/a/b/c.md'), '/a/b');
      expect(goDir('c.md'), '.');
      expect(goBase('/a/b/c.json'), 'c.json');
      expect(goBase('/a/b/'), 'b');
      expect(goBase('/'), '/');
      expect(goBase(''), '.');
      expect(goExt('notes.md'), '.md');
      expect(goExt('.highwatermark'), '.highwatermark');
      expect(goExt('a.b/c'), '');
      expect(goExt('archive.tar.gz'), '.gz');
      expect(goIsAbs('/x'), isTrue);
      expect(goIsAbs('x'), isFalse);
      expect(goFields('  a \t b\nc  '), ['a', 'b', 'c']);
      expect(goFields('   '), isEmpty);
    });

    test('goEscapeHtml escapes as encoding/json does', () {
      expect(goEscapeHtml('{"a":"<b>&"}'), r'{"a":"\u003cb\u003e\u0026"}');
      expect(goEscapeHtml('x\u2028y\u2029z'), r'x\u2028y\u2029z');
      expect(goJsonEncode({'k': '<x>'}), r'{"k":"\u003cx\u003e"}');
      expect(goJsonEncode({'k': 'a&b'}).length, 'a&b'.length + 13);
      expect(
        goIndentedToolOutputParts([ToolOutputPart.text('<p>'), ToolOutputPart.text('&')]),
        '[\n\t{\n\t\t"type": "text",\n\t\t"text": "\\u003cp\\u003e"\n\t},'
        '\n\t{\n\t\t"type": "text",\n\t\t"text": "\\u0026"\n\t}\n]',
      );
    });

    test('goIndentedToolOutputParts writes the Go ToolOutputPart shape', () {
      final json = goIndentedToolOutputParts([
        ToolOutputPart.text('hi'),
        const ToolOutputPart(
          type: ToolPartType.image,
          image: ToolOutputImage(
            common: MessagePartCommon(url: 'http://x/a.png', mimeType: 'image/png'),
          ),
        ),
      ]);
      expect(
        json,
        '[\n\t{\n\t\t"type": "text",\n\t\t"text": "hi"\n\t},\n\t{\n\t\t"type": "image",\n\t\t"image": {\n'
        '\t\t\t"url": "http://x/a.png",\n\t\t\t"mime_type": "image/png"\n\t\t}\n\t}\n]',
      );
    });

    test('goToolInfoValueJson measures only the name and description', () {
      final info = ToolInfo.fromParams(
        name: 'n',
        desc: 'd',
        params: const {'p': ParameterInfo(type: DataType.string)},
      );
      expect(goToolInfoValueJson(info), '{"Name":"n","Desc":"d","Extra":null}');
      expect(goParamsOneOfJsonLength(info), 2);
      expect(goParamsOneOfJsonLength(ToolInfo.function(name: 'x')), 4);
    });
  });

  group('run-local helpers outside a run', () {
    test('read nothing and write nothing', () {
      expect(tryRunLocalValue(ctx, 'k'), (false, null));
      expect(trySetRunLocalValue(ctx, 'k', 1), isFalse);
    });
  });

  group('filesystem additions', () {
    test('FileNotFoundException is a ThreepioException with the path', () {
      const error = FileNotFoundException('/x');
      expect(error, isA<ThreepioException>());
      expect(error.path, '/x');
      expect(error.message, 'file not found: /x');
      expect(const FileNotFoundException('/y', message: 'gone').message, 'gone');
      expect(ThreepioException.findCause<FileNotFoundException>(ThreepioException('wrap', cause: error)), error);
    });

    // Coordinator decision 1 after P8: as eino's in-memory backend, a missing
    // file is a plain error (it does not wrap os.ErrNotExist).
    test('InMemoryBackend throws a plain ThreepioException for a missing file', () async {
      final backend = InMemoryBackend();
      final plainNotFound = isA<ThreepioException>()
          .having((e) => e.message, 'message', 'file not found: /nope')
          .having((e) => e is FileNotFoundException, 'is FileNotFoundException', isFalse);
      await expectLater(
        backend.read(ctx, const ReadRequest(filePath: '/nope')),
        throwsA(plainNotFound),
      );
      await expectLater(
        backend.edit(ctx, const EditRequest(filePath: '/nope', oldString: 'a', newString: 'b')),
        throwsA(plainNotFound),
      );
    });

    test('a FilesystemBackend is a FileReadBackend and a FileWriteBackend', () {
      final FilesystemBackend backend = InMemoryBackend();
      expect(backend, isA<FileReadBackend>());
      expect(backend, isA<FileWriteBackend>());
    });
  });

  group('SummarizationAction', () {
    test('JSON round trip of every kind, through the type registry', () {
      final actions = [
        SummarizationAction(
          type: SummarizationActionType.beforeSummarize,
          before: BeforeSummarizeAction(messages: [Message.user('a')]),
        ),
        SummarizationAction(
          type: SummarizationActionType.afterSummarize,
          after: AfterSummarizeAction(messages: [Message.user('summary')]),
        ),
        SummarizationAction(
          type: SummarizationActionType.generateSummary,
          generateSummary: GenerateSummaryAction(
            attempt: 2,
            phase: GenerateSummaryPhase.failover,
            modelResponse: Message.assistant('s'),
            error: const ThreepioException('not written'),
          ),
        ),
      ];
      SummarizationMiddleware(model: _NoModel());
      for (final action in actions) {
        final encoded = TypeRegistry.encode(action);
        expect((encoded! as Map)[r'$type'], SummarizationAction.registeredName);
        final decoded = TypeRegistry.decode(jsonDecode(jsonEncode(encoded))) as SummarizationAction;
        expect(decoded.type, action.type);
        expect(decoded.toJson(), action.toJson());
      }
      final generate = actions.last.toJson();
      expect(generate['type'], 'generate_summary');
      expect(generate['generate_summary'], containsPair('phase', 'failover'));
      expect((generate['generate_summary']! as Map).containsKey('error'), isFalse);
    });

    test('enum names are eino\'s', () {
      expect(SummarizationActionType.values.map((t) => t.einoName),
          ['before_summarize', 'after_summarize', 'generate_summary']);
      expect(GenerateSummaryPhase.values.map((p) => p.einoName), ['primary', 'failover']);
      expect(() => SummarizationActionType.fromEinoName('x'), throwsFormatException);
      expect(() => GenerateSummaryPhase.fromEinoName('x'), throwsFormatException);
    });
  });

  group('Chinese prompts', () {
    tearDown(() => setAdkLanguage(AdkLanguage.english));

    test('the patch text follows setAdkLanguage', () async {
      setAdkLanguage(AdkLanguage.chinese);
      final (_, state) = await const PatchToolCallsMiddleware().beforeModelRewriteState(
        ctx,
        ChatModelAgentState(messages: [
          Message(
            role: RoleType.assistant,
            content: '',
            toolCalls: [ToolCall(id: 'c', function: FunctionCall(name: 't', arguments: '{}'))],
          ),
        ]),
        const ModelContext(),
      );
      expect(state.messages.last.content, '工具调用 t（ID 为 c）已被取消——在其完成之前收到了另一条消息。');
    });

    test('the filesystem tools take the Chinese descriptions', () async {
      setAdkLanguage(AdkLanguage.chinese);
      final tools = FilesystemMiddleware(backend: InMemoryBackend()).tools;
      final ls = await tools.first.info();
      expect(ls.desc, FilesystemToolDescriptions.listFilesChinese);
    });
  });

  test('every middleware is a ChatModelAgentMiddleware exported from adk.dart', () async {
    final backend = InMemoryBackend();
    final middlewares = <ChatModelAgentMiddleware>[
      const PatchToolCallsMiddleware(),
      AgentsMdMiddleware(backend: backend, agentsMdFiles: const ['/AGENTS.md']),
      SummarizationMiddleware(model: _NoModel()),
      ToolReductionMiddleware(backend: backend),
      FilesystemMiddleware(backend: backend),
      SkillMiddleware(backend: FilesystemSkillBackend(backend: backend, baseDir: '/skills')),
      PlanTaskMiddleware(backend: _NoTasks(), baseDir: '/tasks'),
      await ToolSearchMiddleware.create(dynamicTools: [_Tool()]),
    ];
    expect(middlewares, hasLength(8));
  });
}

final class _NoModel extends BaseChatModel {
  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError();

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError();
}

final class _NoTasks implements PlanTaskBackend {
  @override
  Future<void> delete(RunContext ctx, DeleteRequest request) async {}

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) async => const [];

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async => const FileContent();

  @override
  Future<void> write(RunContext ctx, WriteRequest request) async {}
}

final class _Tool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: 'dyn', desc: 'dynamic', params: const {});

  @override
  Future<String> run(String argumentsJson) async => 'ok';
}
