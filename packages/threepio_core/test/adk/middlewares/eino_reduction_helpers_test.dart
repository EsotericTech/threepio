// Port of eino `adk/middlewares/reduction/reduction_test.go` (v0.9.22), the
// helper-level tests:
//   TestGetJointToolResult, TestDefaultTruncHandlerWithStreamToolResult,
//   TestDefaultClearHandlerWithStreamToolResult, TestDefaultOffloadHandler,
//   TestToolResultFromMessage, TestConvMessageInputPartToToolOutputPart,
//   TestGetSetMsgOffloadedFlag, TestNewErrors, TestGetToolConfig,
//   TestCopyAndFillDefaults, TestDefaultTokenCounter, TestDefaultClearHandler,
//   TestStringifyToolOutputParts, TestClampPrefixToUTF8Boundary,
//   TestClampSuffixToUTF8Boundary, TestGetMsgClearedFlag.
// The middleware-level tests of the same Go file are in
// `eino_reduction_test.dart`.
//
// Not ported:
// * TestCopyMessages: `copyMessages` only exists in Go to copy mutable
//   messages before the clear phase edits them in place; Dart messages are
//   immutable, the library has no such function (and no deprecated
//   `MultiContent` field), so there is nothing to test.
// * TestNewTypedAgenticMessage, TestToolResultMediaSourceRoundTrip
//   (`schema.FunctionToolResult` content blocks): agentic messages are P13.
// * TestNewErrors / "test nil config": a nil config is a compile-time error
//   in Dart (the constructor takes named parameters).
// * TestDefaultTokenCounter / "test with nil messages": a `List<Message>`
//   cannot hold null.
//
// Adapted (intended deviations):
// * Go `ToolDetail` literals without `ToolContext` / `ToolArgument` get empty
//   ones (both are required in Dart).
// * `getJointToolResult`'s `(parts, needProcess, err)` → `jointToolResult`
//   returns `null` for `needProcess == false` and throws for the error.
// * `setMsgClearedFlag` mutates in Go; `withMessageClearedFlag` returns a copy.
// * `copyAndFillDefaults` → the fields of a constructed middleware (the Dart
//   constructor validates at once, so it is given a backend, which the Go
//   test's empty config does not need).
// * Go errors (`errors.New`) are `ThreepioException`s with the same text.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/internal/go_compat.dart';
import 'package:threepio_core/src/adk/middlewares/reduction/consts.dart';
import 'package:threepio_core/src/adk/middlewares/reduction/reduction.dart';

final ctx = RunContext.background();

const _noContext = ToolContext(name: '', callId: '');
const _noArgument = ToolArgument('');

OffloadFilePathGenerator _testTruncOffloadPath(String root) => (ctx, detail) {
      var callId = 'generated';
      if (detail.toolContext.callId.isNotEmpty) callId = detail.toolContext.callId;
      return '$root/trunc/$callId';
    };

OffloadFilePathGenerator _testClearOffloadPath(String root) => (ctx, detail) {
      var callId = 'generated';
      if (detail.toolContext.callId.isNotEmpty) callId = detail.toolContext.callId;
      return '$root/clear/$callId';
    };

ToolResult _text(String text) => ToolResult([ToolOutputPart(type: ToolPartType.text, text: text)]);

Matcher _errorContaining(String text) => predicate<Object>((e) => '$e'.contains(text), 'error containing "$text"');

void main() {
  group('TestGetJointToolResult', () {
    test('test with ToolResult', () async {
      final detail = ToolDetail(toolContext: _noContext, toolArgument: _noArgument, toolResult: _text('hello world'));
      final toolOutputParts = await jointToolResult(detail);
      expect(toolOutputParts, isNotNull, reason: 'needProcess');
      expect(toolOutputParts, hasLength(1));
      expect(toolOutputParts![0].type, ToolPartType.text);
      expect(toolOutputParts[0].text, 'hello world');
    });

    test('test with multiple ToolResult parts', () async {
      final detail = ToolDetail(
        toolContext: _noContext,
        toolArgument: _noArgument,
        toolResult: ToolResult([
          const ToolOutputPart(type: ToolPartType.text, text: 'hello '),
          const ToolOutputPart(type: ToolPartType.text, text: 'world'),
        ]),
      );
      final toolOutputParts = await jointToolResult(detail);
      expect(toolOutputParts, isNotNull, reason: 'needProcess');
      expect(toolOutputParts, hasLength(2));
      expect(toolOutputParts![0].type, ToolPartType.text);
      expect(toolOutputParts[0].text, 'hello ');
      expect(toolOutputParts[1].type, ToolPartType.text);
      expect(toolOutputParts[1].text, 'world');
    });

    test('test with empty ToolResult parts', () async {
      const detail = ToolDetail(toolContext: _noContext, toolArgument: _noArgument, toolResult: ToolResult([]));
      expect(await jointToolResult(detail), isNull, reason: 'needProcess == false, nil parts');
    });

    test('test with ToolResult multimodal', () async {
      final detail = ToolDetail(
        toolContext: _noContext,
        toolArgument: _noArgument,
        toolResult: ToolResult([const ToolOutputPart(type: ToolPartType.image, text: 'https://example.com/image.png')]),
      );
      final toolOutputParts = await jointToolResult(detail);
      expect(toolOutputParts, isNotNull, reason: 'needProcess');
      expect(toolOutputParts, hasLength(1));
      expect(toolOutputParts![0].type, ToolPartType.image);
      expect(toolOutputParts[0].text, 'https://example.com/image.png');
    });

    test('test with StreamToolResult', () async {
      final (sr, sw) = pipe<ToolResult>(capacity: 10);
      sw
        ..send(_text('hello '))
        ..send(_text('world'));
      await sw.close();

      final detail = ToolDetail(toolContext: _noContext, toolArgument: _noArgument, streamToolResult: sr);
      final toolOutputParts = await jointToolResult(detail);
      expect(toolOutputParts, isNotNull, reason: 'needProcess');
      expect(toolOutputParts, hasLength(1));
      expect(toolOutputParts![0].type, ToolPartType.text);
      expect(toolOutputParts[0].text, 'hello world');
    });

    test('test with StreamToolResult error', () async {
      final (sr, sw) = pipe<ToolResult>(capacity: 10);
      sw.sendError(const ThreepioException('stream error'));
      await sw.close();

      final detail = ToolDetail(toolContext: _noContext, toolArgument: _noArgument, streamToolResult: sr);
      expect(await jointToolResult(detail), isNull, reason: 'needProcess == false, nil parts, no error');
    });

    test('test with both ToolResult and StreamToolResult nil (should error)', () async {
      const detail = ToolDetail(toolContext: _noContext, toolArgument: _noArgument);
      await expectLater(jointToolResult(detail), throwsA(isA<ThreepioException>()));
    });
  });

  group('TestDefaultTruncHandlerWithStreamToolResult', () {
    test('test short stream result no trunc', () async {
      final (sr, sw) = pipe<ToolResult>(capacity: 10);
      sw.send(_text('short text'));
      await sw.close();

      final detail = ToolDetail(
        toolContext: const ToolContext(name: 'test', callId: 'call_id'),
        toolArgument: const ToolArgument('{}'),
        streamToolResult: sr,
      );

      final fn = defaultTruncHandler(_testTruncOffloadPath('/tmp'), 100, 'read_file');
      final result = await fn(ctx, detail);
      expect(result.needTrunc, isFalse);
    });

    test('test long stream result need trunc', () async {
      final (sr, sw) = pipe<ToolResult>(capacity: 10);
      sw.send(_text('hello world' * 20));
      await sw.close();

      final detail = ToolDetail(
        toolContext: const ToolContext(name: 'test', callId: 'call_id'),
        toolArgument: const ToolArgument('{}'),
        streamToolResult: sr,
      );

      final fn = defaultTruncHandler(_testTruncOffloadPath('/tmp'), 100, 'read_file');
      final result = await fn(ctx, detail);
      expect(result.needTrunc, isTrue);
    });

    test('test gen offload file path error', () async {
      final detail = ToolDetail(
        toolContext: const ToolContext(name: 'test', callId: 'call_id'),
        toolArgument: const ToolArgument('{}'),
        toolResult: _text('x' * 1000),
      );

      final fn = defaultTruncHandler(
        (ctx, detail) => throw const ThreepioException('gen path error'),
        10,
        'read_file',
      );
      await expectLater(() async => fn(ctx, detail), throwsA(_errorContaining('gen path error')));
    });
  });

  group('TestDefaultClearHandlerWithStreamToolResult', () {
    test('test with stream result need offload', () async {
      final (sr, sw) = pipe<ToolResult>(capacity: 10);
      sw.send(_text('streaming content'));
      await sw.close();

      final detail = ToolDetail(
        toolContext: const ToolContext(name: 'test', callId: 'stream_call_id'),
        toolArgument: const ToolArgument('{}'),
        streamToolResult: sr,
      );

      final fn = defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file');
      final result = await fn(ctx, detail);
      expect(result.needClear, isTrue);
      expect(result.needOffload, isTrue);
      expect(result.offloadContent, 'streaming content');
    });

    test('test gen offload file path error', () async {
      final detail = ToolDetail(
        toolContext: const ToolContext(name: 'test', callId: 'call_id'),
        toolArgument: const ToolArgument('{}'),
        toolResult: _text('content'),
      );
      final fn = defaultClearHandler(
        (ctx, detail) => throw const ThreepioException('gen path error'),
        true,
        'read_file',
      );
      await expectLater(() async => fn(ctx, detail), throwsA(_errorContaining('gen path error')));
    });
  });

  test('TestDefaultOffloadHandler', () async {
    final detail = ToolDetail(
      toolContext: const ToolContext(name: 'mock_name', callId: 'mock_call_id_12345'),
      toolArgument: const ToolArgument('anything'),
      toolResult: _text('hello'),
    );

    final fn = defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file');
    final info = await fn(ctx, detail);
    // Go compares the whole ClearResult; the Dart class has no ==, so field by field.
    expect(info.toolArgument, const ToolArgument('anything'));
    expect(
      info.toolResult,
      ToolResult([
        const ToolOutputPart(
          type: ToolPartType.text,
          text: '<persisted-output>Tool result saved to: /tmp/clear/mock_call_id_12345\nUse read_file to view</persisted-output>',
        ),
      ]),
    );
    expect(info.needClear, isTrue);
    expect(info.needOffload, isTrue);
    expect(info.offloadFilePath, '/tmp/clear/mock_call_id_12345');
    expect(info.offloadContent, 'hello');
  });

  group('TestToolResultFromMessage', () {
    test('test from content', () {
      final msg = Message.tool(content: 'test content', toolCallId: 'call_123');
      final (result, fromContent) = toolResultFromMessage(msg);
      expect(fromContent, isTrue);
      expect(result.parts, hasLength(1));
      expect(result.parts[0].type, ToolPartType.text);
      expect(result.parts[0].text, 'test content');
    });

    test('test from user input multi content', () {
      final msg = Message.tool(content: '', toolCallId: 'call_456').copyWith(
        userInputMultiContent: [const MessageInputPart(type: ChatMessagePartType.text, text: 'test text')],
      );
      final (result, fromContent) = toolResultFromMessage(msg);
      expect(fromContent, isFalse);
      expect(result.parts, hasLength(1));
      expect(result.parts[0].type, ToolPartType.text);
      expect(result.parts[0].text, 'test text');
    });

    test('test invalid role', () {
      final msg = Message.user('test user message');
      expect(() => toolResultFromMessage(msg), throwsA(_errorContaining('message role')));
    });
  });

  group('TestConvMessageInputPartToToolOutputPart', () {
    test('test text type', () {
      const part = MessageInputPart(type: ChatMessagePartType.text, text: 'test text');
      final result = messageInputPartToToolOutputPart(part);
      expect(result.type, ToolPartType.text);
      expect(result.text, 'test text');
    });

    test('test image url type', () {
      const part = MessageInputPart(
        type: ChatMessagePartType.imageUrl,
        image: MessageInputImage(common: MessagePartCommon()),
      );
      final result = messageInputPartToToolOutputPart(part);
      expect(result.type, ToolPartType.image);
      expect(result.image, isNotNull);
    });

    test('test audio url type', () {
      const part = MessageInputPart(
        type: ChatMessagePartType.audioUrl,
        audio: MessageInputAudio(common: MessagePartCommon()),
      );
      final result = messageInputPartToToolOutputPart(part);
      expect(result.type, ToolPartType.audio);
      expect(result.audio, isNotNull);
    });

    test('test video url type', () {
      const part = MessageInputPart(
        type: ChatMessagePartType.videoUrl,
        video: MessageInputVideo(common: MessagePartCommon()),
      );
      final result = messageInputPartToToolOutputPart(part);
      expect(result.type, ToolPartType.video);
      expect(result.video, isNotNull);
    });

    test('test file url type', () {
      const part = MessageInputPart(
        type: ChatMessagePartType.fileUrl,
        file: MessageInputFile(common: MessagePartCommon()),
      );
      final result = messageInputPartToToolOutputPart(part);
      expect(result.type, ToolPartType.file);
      expect(result.file, isNotNull);
    });

    test('test unknown type', () {
      // `ChatMessagePartType` is an enum in Dart, so Go's "unknown_type"
      // becomes a part type the converter does not handle.
      const part = MessageInputPart(type: ChatMessagePartType.reasoning);
      expect(() => messageInputPartToToolOutputPart(part), throwsA(_errorContaining('unknown msg part type')));
    });
  });

  group('TestGetSetMsgOffloadedFlag', () {
    test('test get offloaded flag - not set', () {
      final msg = Message.user('test');
      expect(messageClearedFlag(msg), isFalse);
    });

    test('test get offloaded flag - set', () {
      final msg = withMessageClearedFlag(Message.user('test'));
      expect(messageClearedFlag(msg), isTrue);
    });

    test('test set offloaded flag - nil extra', () {
      final msg = withMessageClearedFlag(Message.user('test'));
      expect(messageClearedFlag(msg), isTrue);
    });

    test('test set offloaded flag - existing extra', () {
      final msg = withMessageClearedFlag(Message.user('test').copyWith(extra: {'existing': 'value'}));
      expect(messageClearedFlag(msg), isTrue);
      expect(msg.extra!['existing'], 'value');
    });
  });

  group('TestNewErrors', () {
    // "test nil config": not portable (see the file comment).

    test('test no backend when not skipping truncation', () {
      expect(
        () => ToolReductionMiddleware(),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('backend must be set'))),
      );
    });
  });

  group('TestGetToolConfig', () {
    final backend = InMemoryBackend();

    test('test no tool config', () {
      final mw = ToolReductionMiddleware(backend: backend, skipTruncation: true, skipClear: true);

      final cfg = mw.toolConfigFor('non_existent_tool', clear: false);
      expect(cfg, isNotNull);
    });

    test('test with tool config', () {
      final mw = ToolReductionMiddleware(
        backend: backend,
        skipTruncation: true,
        skipClear: true,
        toolConfig: {
          'test_tool': const ToolReductionConfig(skipTruncation: true, skipClear: true),
        },
      );

      final cfg = mw.toolConfigFor('test_tool', clear: false);
      expect(cfg, isNotNull);
      expect(cfg.skipTruncation, isTrue);
    });

    test('test with tool config needing default handler', () {
      final mw = ToolReductionMiddleware(
        backend: backend,
        toolConfig: {'test_tool': const ToolReductionConfig()},
      );

      final cfg = mw.toolConfigFor('test_tool', clear: false);
      expect(cfg, isNotNull);
      expect(cfg.truncHandler, isNotNull);
    });
  });

  group('TestCopyAndFillDefaults', () {
    test('test empty config', () async {
      final result = ToolReductionMiddleware(backend: InMemoryBackend());
      expect(result.rootDir, '/tmp');
      expect(result.readFileToolName, 'read_file');
      expect(result.maxLengthForTrunc, 50000);
      expect(result.clearRetentionSuffixLimit, 1);
      expect(result.tokenCounter, isNotNull);
      expect(result.genTruncOffloadFilePath, isNotNull);
      expect(result.genClearOffloadFilePath, isNotNull);

      final truncPath = await result.genTruncOffloadFilePath(
        ctx,
        const ToolDetail(toolContext: ToolContext(name: '', callId: 'call_1'), toolArgument: _noArgument),
      );
      expect(truncPath, '/tmp/trunc/call_1');

      final clearPath = await result.genClearOffloadFilePath(
        ctx,
        const ToolDetail(toolContext: ToolContext(name: '', callId: 'call_1'), toolArgument: _noArgument),
      );
      expect(clearPath, '/tmp/clear/call_1');
    });

    test('test default offload path generators create uuid when CallID is empty', () async {
      final result = ToolReductionMiddleware(backend: InMemoryBackend());

      final truncPath = await result.genTruncOffloadFilePath(
        ctx,
        const ToolDetail(toolContext: _noContext, toolArgument: _noArgument),
      );
      expect(truncPath.startsWith('/tmp/trunc/'), isTrue);
      expect(truncPath, isNot('/tmp/trunc/'));

      final clearPath = await result.genClearOffloadFilePath(
        ctx,
        const ToolDetail(toolContext: _noContext, toolArgument: _noArgument),
      );
      expect(clearPath.startsWith('/tmp/clear/'), isTrue);
      expect(clearPath, isNot('/tmp/clear/'));
    });

    test('test with tool config', () {
      final result = ToolReductionMiddleware(
        backend: InMemoryBackend(),
        toolConfig: {'test_tool': const ToolReductionConfig(skipTruncation: true)},
      );
      expect(result.toolConfig, isNotNull);
      expect(result.toolConfig['test_tool']!.skipTruncation, isTrue);
    });

    test('test custom offload path generators preserved', () async {
      final result = ToolReductionMiddleware(
        backend: InMemoryBackend(),
        rootDir: '/tmp/ignored',
        genTruncOffloadFilePath: (ctx, detail) => '/custom/trunc/${detail.toolContext.callId}',
        genClearOffloadFilePath: (ctx, detail) => '/custom/clear/${detail.toolContext.callId}',
      );

      final filePath = await result.genClearOffloadFilePath(
        ctx,
        const ToolDetail(toolContext: ToolContext(name: '', callId: 'call_custom'), toolArgument: _noArgument),
      );
      expect(filePath, '/custom/clear/call_custom');
    });
  });

  group('TestDefaultTokenCounter', () {
    // "test with nil messages": not portable (see the file comment).

    test('test with tool info', () {
      final toolInfo = ToolInfo.function(name: 'test_tool', description: 'test description');
      final tokens = defaultReductionTokenCount(ctx, const [], [toolInfo]);
      expect(tokens, greaterThanOrEqualTo(0));
    });
  });

  group('TestDefaultClearHandler', () {
    test('test empty parts', () async {
      final handler = defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file');
      const detail = ToolDetail(
        toolContext: ToolContext(name: '', callId: 'test_call'),
        toolArgument: _noArgument,
        toolResult: ToolResult([]),
      );
      final result = await handler(ctx, detail);
      expect(result.needClear, isFalse);
    });

    test('test multimodal content', () async {
      final handler = defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file');
      const detail = ToolDetail(
        toolContext: ToolContext(name: '', callId: 'test_call'),
        toolArgument: _noArgument,
        toolResult: ToolResult([ToolOutputPart(type: ToolPartType.image)]),
      );
      final result = await handler(ctx, detail);
      expect(result.toolResult, detail.toolResult);
    });

    test('test no call id', () async {
      final handler = defaultClearHandler(_testClearOffloadPath('/tmp'), true, 'read_file');
      final detail = ToolDetail(toolContext: _noContext, toolArgument: _noArgument, toolResult: _text('test'));
      final result = await handler(ctx, detail);
      expect(result.needClear, isTrue);
      expect(result.offloadFilePath, '/tmp/clear/generated');
    });
  });

  group('TestStringifyToolOutputParts', () {
    // Go compares with assert.JSONEq; the expected texts are also exactly
    // what Go's json.MarshalIndent(parts, "", "\t") writes, which is what
    // gets offloaded, so the Dart text is compared byte for byte as well.
    test('test empty parts', () {
      expect(stringifyToolOutputParts(const []), '');
    });

    test('test single text part', () {
      final result = stringifyToolOutputParts([const ToolOutputPart(type: ToolPartType.text, text: 'hello world')]);
      expect(result, 'hello world');
    });

    test('test multiple text parts', () {
      final result = stringifyToolOutputParts([
        const ToolOutputPart(type: ToolPartType.text, text: 'hello '),
        const ToolOutputPart(type: ToolPartType.text, text: 'world'),
      ]);
      const expected = '[\n'
          '\t{\n'
          '\t\t"type": "text",\n'
          '\t\t"text": "hello "\n'
          '\t},\n'
          '\t{\n'
          '\t\t"type": "text",\n'
          '\t\t"text": "world"\n'
          '\t}\n'
          ']';
      expect(jsonDecode(result), jsonDecode(expected));
      expect(result, expected);
    });

    test('test with image part', () {
      final result = stringifyToolOutputParts([
        const ToolOutputPart(type: ToolPartType.image, text: 'https://example.com/image.png'),
      ]);
      const expected = '[\n'
          '\t{\n'
          '\t\t"type": "image",\n'
          '\t\t"text": "https://example.com/image.png"\n'
          '\t}\n'
          ']';
      expect(jsonDecode(result), jsonDecode(expected));
      expect(result, expected);
    });

    test('test mixed parts', () {
      final result = stringifyToolOutputParts([
        const ToolOutputPart(type: ToolPartType.text, text: 'hello world'),
        const ToolOutputPart(type: ToolPartType.image, text: 'https://example.com/image.png'),
      ]);
      const expected = '[\n'
          '\t{\n'
          '\t\t"type": "text",\n'
          '\t\t"text": "hello world"\n'
          '\t},\n'
          '\t{\n'
          '\t\t"type": "image",\n'
          '\t\t"text": "https://example.com/image.png"\n'
          '\t}\n'
          ']';
      expect(jsonDecode(result), jsonDecode(expected));
      expect(result, expected);
    });
  });

  // clampPrefixToUTF8Boundary → utf8Prefix (go_compat); n is in UTF-8 bytes.
  group('TestClampPrefixToUTF8Boundary', () {
    test('test n <= 0', () {
      expect(utf8Prefix('hello world', 0), '');
      expect(utf8Prefix('hello world', -5), '');
    });

    test('test n >= len(s)', () {
      expect(utf8Prefix('hello', 10), 'hello');
    });

    test('test ASCII string at rune boundary', () {
      expect(utf8Prefix('hello world', 5), 'hello');
    });

    test('test ASCII string not at rune boundary (should not happen)', () {
      expect(utf8Prefix('world', 3), 'wor');
    });

    test('test multi-byte UTF-8 characters at boundary', () {
      const s = '你好世界';
      expect(utf8Prefix(s, 3), '你');
    });

    test('test multi-byte UTF-8 characters not at boundary', () {
      const s = '你好世界';
      expect(utf8Prefix(s, 2), '');
      expect(utf8Prefix(s, 4), '你');
    });

    test('test mixed ASCII and multi-byte characters', () {
      const s = 'hello你好world';
      expect(utf8Prefix(s, 5 + 3), 'hello你');
      expect(utf8Prefix(s, 5 + 4), 'hello你');
      expect(utf8Prefix(s, 5 + 6), 'hello你好');
    });
  });

  // clampSuffixToUTF8Boundary → utf8Suffix (go_compat); n is in UTF-8 bytes.
  group('TestClampSuffixToUTF8Boundary', () {
    test('test n <= 0', () {
      expect(utf8Suffix('hello world', 0), '');
      expect(utf8Suffix('hello world', -5), '');
    });

    test('test n >= len(s)', () {
      expect(utf8Suffix('hello', 10), 'hello');
    });

    test('test ASCII string at rune boundary', () {
      expect(utf8Suffix('hello world', 5), 'world');
    });

    test('test ASCII string not at rune boundary (should not happen)', () {
      expect(utf8Suffix('hello', 3), 'llo');
    });

    test('test multi-byte UTF-8 characters at boundary', () {
      const s = '你好世界';
      expect(utf8Length(s), 12);
      expect(utf8Suffix(s, 3), '界');
    });

    test('test multi-byte UTF-8 characters not at boundary', () {
      const s = '你好世界';
      expect(utf8Suffix(s, 2), '');
      expect(utf8Suffix(s, 4), '界');
      expect(utf8Suffix(s, 6), '世界');
    });

    test('test mixed ASCII and multi-byte characters', () {
      const s = 'hello你好world';
      expect(utf8Suffix(s, 5 + 3), '好world');
      expect(utf8Suffix(s, 5 + 4), '好world');
      expect(utf8Suffix(s, 5 + 6), '你好world');
    });
  });

  group('TestGetMsgClearedFlag', () {
    test('test non-bool value in extra', () {
      final msg = Message.user('test').copyWith(extra: {msgClearedFlag: 'not a bool'});
      expect(messageClearedFlag(msg), isFalse);
    });
  });
}
