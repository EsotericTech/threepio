// Port of eino v0.9.22 `adk/middlewares/summarization/summarization_test.go`.
//
// Ported (26 Go tests): TestNew, TestMiddlewareBeforeModelRewriteState,
// TestMiddlewareShouldSummarize, TestMiddlewareCountTokens,
// TestGetUserMsgTextContent, TestTruncateTextByChars, TestAppendSection,
// TestAllUserMessagesTagRegex, TestConfigCheck, TestSetGetContentType,
// TestSetGetExtra, TestMiddlewareBuildSummarizationModelInput,
// TestMiddlewareSummarize, TestMiddlewareGenerateWithRetry,
// TestPopulateUserMessagesInternal, TestAllUserMessagesTagRegexMatch,
// TestDefaultTrimUserMessage, TestDefaultTokenCounter,
// TestGetAssistantTotalTokens, TestEstimateMessageTokens,
// TestPostProcessSummary, TestEventHelpers, TestGetFailoverModel,
// TestHelperBranches, TestSummarize, TestGetAssistantTextContent.
//
// Not ported:
// * Agentic messages are P13: TestNewTypedAgenticMessage,
//   TestSummarizationGeneric (both halves are the generic `testSummarization*`
//   helpers), TestEstimateAgenticMessageTokens,
//   TestEmitInternalEvents_AgenticMessage_RequiresExecContext, and the
//   AgenticMessage sub-tests of TestGetUserMsgTextContent (2),
//   TestGetAssistantTotalTokens (1 and the agentic half of "returns zero for
//   nil message"), TestGetAssistantTextContent (3).
// * A nil config / nil model is a compile-time error in Dart (required
//   parameters): TestNew "nil config returns error", "nil model returns
//   error"; TestConfigCheck "nil config", "nil model"; TestGetFailoverModel
//   "requires non nil failover model" (the getter's model is non-nullable);
//   TestGetUserMsgTextContent "Message nil returns empty".
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/summarization/prompt.dart';
import 'package:threepio_core/src/adk/middlewares/summarization/summarization.dart';

final RunContext ctx = RunContext.background();

/// A Go `errors.New` / `fmt.Errorf` error: its text is its message.
class _GoError implements Exception {
  const _GoError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// gomock's `MockBaseChatModel`: answers with [onGenerate] (given the input
/// and the 1-based call number), counts calls and records inputs. Without
/// [onGenerate] any call is unexpected (gomock without `EXPECT`).
class _Model extends BaseChatModel {
  _Model([this.onGenerate]);

  final FutureOr<Message> Function(List<Message> input, int call)? onGenerate;
  int calls = 0;
  final List<List<Message>> inputs = [];

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    calls++;
    inputs.add(List.of(input));
    final answer = onGenerate;
    if (answer == null) throw StateError('unexpected call to Generate');
    return answer(input, calls);
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError('stream is not used by the summarization middleware');
}

_Model _returns(String content) => _Model((_, __) => Message.assistant(content));

_Model _fails(String text) => _Model((_, __) => throw _GoError(text));

Duration _zeroBackoff(RunContext ctx, int attempt, Message? response, Object? error) =>
    Duration.zero;

Matcher _throwsContaining(String text) => throwsA(
      predicate((Object? e) => '$e'.contains(text), 'an error containing "$text"'),
    );

Future<ChatModelAgentState> _rewrite(SummarizationMiddleware mw, ChatModelAgentState state) async {
  final (_, newState) = await mw.beforeModelRewriteState(ctx, state, const ModelContext());
  return newState;
}

final String _a100 = 'a' * 100;
final String _b100 = 'b' * 100;

Message _assistantWithUsage(String content) => Message(
      role: RoleType.assistant,
      content: content,
      responseMeta: const ResponseMeta(
        usage: TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 100),
      ),
    );

void main() {
  group('TestNew', () {
    test('valid config', () {
      final mw = SummarizationMiddleware(model: _Model());
      expect(mw, isNotNull);
    });
  });

  group('TestMiddlewareBeforeModelRewriteState', () {
    test('no summarization when under threshold', () async {
      final cm = _Model();
      final mw = SummarizationMiddleware(
        model: cm,
        trigger: const SummarizationTrigger(contextTokens: 1000),
      );
      final newState = await _rewrite(
        mw,
        ChatModelAgentState(messages: [Message.user('hello'), Message.assistant('hi')]),
      );
      expect(newState.messages, hasLength(2));
      expect(newState.messages[0].content, 'hello');
      expect(cm.calls, 0);
    });

    test('summarization triggered when over threshold', () async {
      final cm = _returns('Summary content');
      final mw = SummarizationMiddleware(
        model: cm,
        trigger: const SummarizationTrigger(contextTokens: 10),
      );
      final newState = await _rewrite(
        mw,
        ChatModelAgentState(messages: [Message.user(_a100), Message.assistant(_b100)]),
      );
      expect(newState.messages, hasLength(1));
      expect(newState.messages[0].role, RoleType.user);
      expect(cm.calls, 1);
    });

    test('preserves system messages after summarization', () async {
      final cm = _returns('Summary content');
      final mw = SummarizationMiddleware(
        model: cm,
        trigger: const SummarizationTrigger(contextTokens: 10),
      );
      final newState = await _rewrite(
        mw,
        ChatModelAgentState(
          messages: [
            Message.system('You are a helpful assistant'),
            Message.user(_a100),
            Message.assistant(_b100),
          ],
        ),
      );
      expect(cm.calls, 1);
      final modelInput = cm.inputs.single;
      for (var i = 0; i < modelInput.length; i++) {
        if (i == 0) {
          expect(modelInput[i].role, RoleType.system);
        } else {
          expect(modelInput[i].role, isNot(RoleType.system));
        }
      }
      expect(newState.messages, hasLength(2));
      expect(newState.messages[0].role, RoleType.system);
      expect(newState.messages[0].content, 'You are a helpful assistant');
      expect(newState.messages[1].role, RoleType.user);
    });

    test('preserves multiple system messages', () async {
      final cm = _returns('Summary');
      final mw = SummarizationMiddleware(
        model: cm,
        trigger: const SummarizationTrigger(contextTokens: 10),
      );
      final newState = await _rewrite(
        mw,
        ChatModelAgentState(
          messages: [Message.system('System 1'), Message.system('System 2'), Message.user(_a100)],
        ),
      );
      expect(newState.messages, hasLength(3));
      expect(newState.messages[0].role, RoleType.system);
      expect(newState.messages[0].content, 'System 1');
      expect(newState.messages[1].role, RoleType.system);
      expect(newState.messages[1].content, 'System 2');
      expect(newState.messages[2].role, RoleType.user);
      expect(cm.calls, 1);
    });

    test('custom finalize function', () async {
      final cm = _returns('Summary');
      final mw = SummarizationMiddleware(
        model: cm,
        trigger: const SummarizationTrigger(contextTokens: 10),
        finalize: (ctx, originalMessages, summary) => [Message.system('system prompt'), summary],
      );
      final newState = await _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)]));
      expect(newState.messages, hasLength(2));
      expect(newState.messages[0].role, RoleType.system);
      expect(newState.messages[0].content, 'system prompt');
      expect(cm.calls, 1);
    });

    test('retry succeeds after transient error', () async {
      final cm = _Model(
        (_, call) => call == 1 ? throw const _GoError('transient error') : Message.assistant('Summary after retry'),
      );
      final mw = SummarizationMiddleware(
        model: cm,
        trigger: const SummarizationTrigger(contextTokens: 10),
        retry: const SummarizationRetryConfig(maxRetries: 2, backoff: _zeroBackoff),
      );
      final newState = await _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)]));
      expect(newState.messages, hasLength(1));
      expect(cm.calls, 2);
    });

    test('retry uses default max retries when MaxRetries is nil', () async {
      final cm = _fails('transient error');
      final mw = SummarizationMiddleware(
        model: cm,
        trigger: const SummarizationTrigger(contextTokens: 10),
        retry: const SummarizationRetryConfig(backoff: _zeroBackoff),
      );
      await expectLater(
        _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)])),
        _throwsContaining('failed to generate summary'),
      );
      expect(cm.calls, 4);
    });

    test('failover succeeds after primary failure', () async {
      final primary = _fails('primary error');
      final failover = _returns('Summary from failover');
      final contexts = <SummarizationFailoverContext>[];
      final mw = SummarizationMiddleware(
        model: primary,
        trigger: const SummarizationTrigger(contextTokens: 10),
        failover: SummarizationFailoverConfig(
          getFailoverModel: (ctx, fc) {
            contexts.add(fc);
            return (failover, [Message.user('failover input')]);
          },
        ),
      );
      final newState = await _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)]));
      expect(newState.messages, hasLength(1));
      expect(newState.messages[0].role, RoleType.user);

      final fc = contexts.single;
      expect(fc.attempt, 1);
      expect(fc.systemInstruction.role, RoleType.system);
      expect(fc.userInstruction.role, RoleType.user);
      expect(fc.originalMessages, hasLength(1));
      expect(fc.lastModelResponse, isNull);
      expect('${fc.lastError}', 'primary error');

      expect(primary.calls, 1);
      expect(failover.calls, 1);
      expect(failover.inputs.single, hasLength(1));
      expect(failover.inputs.single[0].content, 'failover input');
    });

    test('failover context last err is retry exhausted error when retries exhausted', () async {
      final primary = _fails('primary error');
      final failover = _returns('Summary from failover');
      final lastErrors = <Object?>[];
      final mw = SummarizationMiddleware(
        model: primary,
        trigger: const SummarizationTrigger(contextTokens: 10),
        retry: const SummarizationRetryConfig(maxRetries: 1, backoff: _zeroBackoff),
        failover: SummarizationFailoverConfig(
          getFailoverModel: (ctx, fc) {
            lastErrors.add(fc.lastError);
            return (failover, [Message.user('failover input')]);
          },
        ),
      );
      await _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)]));
      expect('${lastErrors.single}', contains('exceeds max retries'));
      expect(primary.calls, 2);
      expect(failover.calls, 1);
    });

    test('returns failover exhausted error when failover model fails', () async {
      final primary = _fails('primary error');
      final failover = _fails('failover error');
      final mw = SummarizationMiddleware(
        model: primary,
        trigger: const SummarizationTrigger(contextTokens: 10),
        failover: SummarizationFailoverConfig(
          maxRetries: 1,
          backoff: _zeroBackoff,
          getFailoverModel: (ctx, fc) => (failover, [Message.user('failover input')]),
        ),
      );
      await expectLater(
        _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)])),
        _throwsContaining('exceeds max failover attempts'),
      );
      expect(primary.calls, 1);
      expect(failover.calls, 1);
    });

    test('failover retries with max retries and succeeds on second attempt', () async {
      final primary = _fails('primary error');
      final failover1 = _fails('failover error 1');
      final failover2 = _returns('Summary from second failover');
      final contexts = <SummarizationFailoverContext>[];
      final mw = SummarizationMiddleware(
        model: primary,
        trigger: const SummarizationTrigger(contextTokens: 10),
        failover: SummarizationFailoverConfig(
          maxRetries: 2,
          backoff: _zeroBackoff,
          getFailoverModel: (ctx, fc) {
            contexts.add(fc);
            if (fc.attempt == 1) return (failover1, [Message.user('failover input 1')]);
            return (failover2, [Message.user('failover input 2')]);
          },
        ),
      );
      final newState = await _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)]));
      expect(newState.messages, hasLength(1));
      expect(contexts, hasLength(2));
      expect('${contexts[0].lastError}', 'primary error');
      expect(contexts[1].attempt, 2);
      expect('${contexts[1].lastError}', 'failover error 1');
      expect(primary.calls, 1);
      expect(failover1.calls, 1);
      expect(failover2.calls, 1);
    });

    // Adapted: a Dart model cannot both return a message and throw (Go's
    // `return msg, err`). The primary returns "partial output" and a
    // ShouldFailover that also fails over on it takes the place of the error.
    test('failover context carries generate resp as last output message', () async {
      final primary = _returns('partial output');
      final failover = _returns('Summary from failover');
      final lastResponses = <Message?>[];
      final mw = SummarizationMiddleware(
        model: primary,
        trigger: const SummarizationTrigger(contextTokens: 10),
        failover: SummarizationFailoverConfig(
          shouldFailover: (ctx, response, error) =>
              error != null || response?.content == 'partial output',
          getFailoverModel: (ctx, fc) {
            lastResponses.add(fc.lastModelResponse);
            return (failover, [Message.user('failover input')]);
          },
        ),
      );
      await _rewrite(mw, ChatModelAgentState(messages: [Message.user(_a100)]));
      expect(lastResponses.single, isNotNull);
      expect(lastResponses.single!.content, 'partial output');
      expect(primary.calls, 1);
      expect(failover.calls, 1);
    });
  });

  group('TestMiddlewareShouldSummarize', () {
    test('returns true when over messages threshold', () async {
      final mw = SummarizationMiddleware(
        model: _Model(),
        trigger: const SummarizationTrigger(contextMessages: 1),
      );
      final triggered = await mw.shouldSummarize(
        ctx,
        TokenCounterInput(messages: [Message.user('msg1'), Message.user('msg2')]),
      );
      expect(triggered, isTrue);
    });

    test('returns false when under messages threshold', () async {
      final mw = SummarizationMiddleware(
        model: _Model(),
        trigger: const SummarizationTrigger(contextMessages: 3, contextTokens: 1000),
      );
      final triggered = await mw.shouldSummarize(
        ctx,
        TokenCounterInput(messages: [Message.user('msg1'), Message.user('msg2')]),
      );
      expect(triggered, isFalse);
    });

    test('returns true when over threshold', () async {
      final mw = SummarizationMiddleware(
        model: _Model(),
        trigger: const SummarizationTrigger(contextTokens: 10),
      );
      final triggered = await mw.shouldSummarize(ctx, TokenCounterInput(messages: [Message.user(_a100)]));
      expect(triggered, isTrue);
    });

    test('returns false when under threshold', () async {
      final mw = SummarizationMiddleware(
        model: _Model(),
        trigger: const SummarizationTrigger(contextTokens: 1000),
      );
      final triggered =
          await mw.shouldSummarize(ctx, TokenCounterInput(messages: [Message.user('short message')]));
      expect(triggered, isFalse);
    });

    test('uses default threshold when trigger is nil', () async {
      final mw = SummarizationMiddleware(model: _Model());
      final triggered =
          await mw.shouldSummarize(ctx, TokenCounterInput(messages: [Message.user('short message')]));
      expect(triggered, isFalse);
    });
  });

  group('TestMiddlewareCountTokens', () {
    test('uses custom token counter', () async {
      final mw = SummarizationMiddleware(model: _Model(), tokenCounter: (ctx, input) => 42);
      final tokens = await mw.countTokens(ctx, TokenCounterInput(messages: [Message.user('test')]));
      expect(tokens, 42);
    });

    test('uses default token counter when nil', () async {
      final mw = SummarizationMiddleware(model: _Model());
      final tokens = await mw.countTokens(ctx, TokenCounterInput(messages: [Message.user('test')]));
      expect(tokens, greaterThan(0));
    });

    test('custom token counter error', () async {
      final mw = SummarizationMiddleware(
        model: _Model(),
        tokenCounter: (ctx, input) => throw const _GoError('token count error'),
      );
      await expectLater(
        mw.countTokens(ctx, TokenCounterInput(messages: [Message.user('test')])),
        throwsA(anything),
      );
    });
  });

  group('TestGetUserMsgTextContent', () {
    test('Message extracts from Content field', () {
      expect(userTextContent(const Message(role: RoleType.user, content: 'hello world')), 'hello world');
    });

    test('Message extracts from UserInputMultiContent', () {
      final msg = Message(
        role: RoleType.user,
        userInputMultiContent: [MessageInputPart.text('part1'), MessageInputPart.text('part2')],
      );
      expect(userTextContent(msg), 'part1\npart2');
    });

    test('Message prefers UserInputMultiContent over Content', () {
      final msg = Message(
        role: RoleType.user,
        content: 'content field',
        userInputMultiContent: [MessageInputPart.text('multi content')],
      );
      expect(userTextContent(msg), 'multi content');
    });
  });

  group('TestTruncateTextByChars', () {
    test('returns empty for empty string', () {
      expect(truncateTextByChars(''), '');
    });

    test('returns original if under limit', () {
      expect(truncateTextByChars('short'), 'short');
    });

    test('truncates long text', () {
      final longText = 'a' * 3000;
      final result = truncateTextByChars(longText);
      expect(utf8.encode(result).length, lessThan(utf8.encode(longText).length));
      expect(result, contains('truncated'));
    });

    test('preserves prefix and suffix', () {
      final longText = 'a' * 1000 + 'b' * 1000 + 'c' * 1000;
      final result = truncateTextByChars(longText);
      expect(result.startsWith('a' * 1000), isTrue);
      expect(result.endsWith('c' * 1000), isTrue);
    });
  });

  group('TestAppendSection', () {
    const cases = [
      (name: 'both empty', base: '', section: '', expected: ''),
      (name: 'base empty', base: '', section: 'section', expected: 'section'),
      (name: 'section empty', base: 'base', section: '', expected: 'base'),
      (name: 'both non-empty', base: 'base', section: 'section', expected: 'base\n\nsection'),
    ];
    for (final tt in cases) {
      test(tt.name, () {
        expect(appendSection(tt.base, tt.section), tt.expected);
      });
    }
  });

  group('TestAllUserMessagesTagRegex', () {
    test('matches tag', () {
      const text = '<all_user_messages>\n    - msg1\n    - msg2\n</all_user_messages>';
      expect(allUserMessagesTagRegex.hasMatch(text), isTrue);
    });

    test('replaces tag content', () {
      const text = 'before\n<all_user_messages>\n    - old msg\n</all_user_messages>\nafter';
      const replacement = '<all_user_messages>\n    - new msg\n</all_user_messages>';
      final result = text.replaceAll(allUserMessagesTagRegex, replacement);
      expect(result, contains('new msg'));
      expect(result, isNot(contains('old msg')));
      expect(result, contains('before'));
      expect(result, contains('after'));
    });
  });

  // Go's `cfg.check()` → the constructor, which validates and throws
  // ArgumentError with Go's text.
  group('TestConfigCheck', () {
    test('valid config', () {
      expect(() => SummarizationMiddleware(model: _Model()), returnsNormally);
    });

    test('invalid trigger max tokens', () {
      expect(
        () => SummarizationMiddleware(
          model: _Model(),
          trigger: const SummarizationTrigger(contextTokens: -1),
        ),
        _throwsContaining('must be non-negative'),
      );
    });

    test('invalid trigger max messages', () {
      expect(
        () => SummarizationMiddleware(
          model: _Model(),
          trigger: const SummarizationTrigger(contextMessages: -1),
        ),
        _throwsContaining('must be non-negative'),
      );
    });

    test('both trigger conditions are zero', () {
      expect(
        () => SummarizationMiddleware(model: _Model(), trigger: const SummarizationTrigger()),
        _throwsContaining('must be non-negative'),
      );
    });

    test('negative retry max retries', () {
      expect(
        () => SummarizationMiddleware(
          model: _Model(),
          retry: const SummarizationRetryConfig(maxRetries: -1),
        ),
        _throwsContaining('retry.MaxRetries must be non-negative'),
      );
    });

    test('failover getFailoverModel is optional', () {
      expect(
        () => SummarizationMiddleware(model: _Model(), failover: const SummarizationFailoverConfig()),
        returnsNormally,
      );
    });

    test('failover max retries accepts int value', () {
      final failover = _Model();
      expect(
        () => SummarizationMiddleware(
          model: _Model(),
          failover: SummarizationFailoverConfig(
            maxRetries: 1,
            getFailoverModel: (ctx, fc) => (failover, [Message.user('failover input')]),
          ),
        ),
        returnsNormally,
      );
    });

    test('failover max retries must be non-negative', () {
      final failover = _Model();
      expect(
        () => SummarizationMiddleware(
          model: _Model(),
          failover: SummarizationFailoverConfig(
            maxRetries: -1,
            getFailoverModel: (ctx, fc) => (failover, [Message.user('failover input')]),
          ),
        ),
        _throwsContaining('failover.MaxRetries must be non-negative'),
      );
    });
  });

  // Messages are immutable: Go's in-place `setMsgExtra` → a copy.
  test('TestSetGetContentType', () {
    final msg = withSummarizationContentType(
      const Message(role: RoleType.user, content: 'test'),
      contentTypeSummary,
    );
    expect(summarizationContentType(msg), contentTypeSummary);
  });

  // Go's generic `setMsgExtra`/`getMsgExtra` are `msg.Extra[key] = v` and
  // `msg.Extra`; Dart messages are immutable, so the set is a `copyWith`.
  group('TestSetGetExtra', () {
    test('set and get', () {
      var msg = const Message(role: RoleType.user, content: 'test');
      msg = msg.copyWith(extra: {...?msg.extra, 'key': 'value'});
      final extra = msg.extra;
      final v = extra?['key'];
      expect(v, isA<String>());
      expect(v, 'value');
    });

    test('get non-existent key', () {
      const msg = Message(role: RoleType.user, content: 'test');
      expect(msg.extra, isNull);
    });
  });

  group('TestMiddlewareBuildSummarizationModelInput', () {
    test('message structure', () async {
      final mw = SummarizationMiddleware(model: _Model());
      final testMsg = [Message.user('test')];
      final input = await mw.buildSummarizationModelInput(ctx, testMsg, testMsg);
      expect(input.length, greaterThanOrEqualTo(3));
      expect(input[0].role, RoleType.system);
      expect(input[input.length - 1].role, RoleType.user);
    });

    test('uses context messages', () async {
      final mw = SummarizationMiddleware(model: _Model());
      final contextMsgs = [Message.user('context message')];
      final input = await mw.buildSummarizationModelInput(ctx, contextMsgs, contextMsgs);
      expect(input.any((msg) => msg.content == 'context message'), isTrue, reason: 'should contain context message');
    });

    test('uses GenModelInput', () async {
      final expectedInput = [Message.user('custom input')];
      final mw = SummarizationMiddleware(
        model: _Model(),
        genModelInput: (ctx, defaultSystemInstruction, userInstruction, originalMsgs) => expectedInput,
      );
      final testMsg = [Message.user('test')];
      final input = await mw.buildSummarizationModelInput(ctx, testMsg, testMsg);
      expect(input, hasLength(1));
      expect(input[0].content, 'custom input');
    });

    test('GenModelInput error', () async {
      final mw = SummarizationMiddleware(
        model: _Model(),
        genModelInput: (ctx, defaultSystemInstruction, userInstruction, originalMsgs) =>
            throw const _GoError('gen input error'),
      );
      final testMsg = [Message.user('test')];
      await expectLater(
        mw.buildSummarizationModelInput(ctx, testMsg, testMsg),
        _throwsContaining('gen input error'),
      );
    });

    test('uses custom instruction', () async {
      final mw = SummarizationMiddleware(model: _Model(), userInstruction: 'custom instruction');
      final testMsg = [Message.user('test')];
      final input = await mw.buildSummarizationModelInput(ctx, testMsg, testMsg);
      final lastMsg = input[input.length - 1];
      expect(lastMsg.role, RoleType.user);
      expect(lastMsg.content, contains('custom instruction'));
    });
  });

  group('TestMiddlewareSummarize', () {
    // Go's `newTypedSummaryMessage(content)` → a user message marked as the
    // summary (`withSummarizationContentType`).
    test('generates summary', () async {
      final cm = _returns('summary');
      final resp = await cm.generate([Message.user('test')]);
      expect(resp, isNotNull);
      final summary = withSummarizationContentType(Message.user(resp.content), contentTypeSummary);
      expect(summary, isNotNull);
      expect(summary.content, 'summary');
      expect(cm.calls, 1);
    });

    test('model generate error', () async {
      final cm = _fails('generate error');
      await expectLater(cm.generate([Message.user('test')]), throwsA(anything));
      expect(cm.calls, 1);
    });
  });

  group('TestMiddlewareGenerateWithRetry', () {
    // Adapted: Go's first call returns "partial output" together with the
    // error; a Dart model throws instead. `&RetryConfig{}` keeps the default
    // backoff (1–1.5 s), driven by fake_async instead of a real wait.
    test('retries until success', () {
      final cm = _Model(
        (_, call) => call == 1 ? throw const _GoError('transient error') : Message.assistant('final summary'),
      );
      final mw = SummarizationMiddleware(model: _Model());
      fakeAsync((async) {
        SummaryAttemptResult? result;
        unawaited(
          mw
              .generateWithRetry(ctx, cm, [Message.user('test')], const SummarizationRetryConfig())
              .then((r) => result = r),
        );
        async.elapse(const Duration(seconds: 2));
        expect(result, isNotNull);
        expect(result!.error, isNull);
        expect(result!.response, isNotNull);
        expect(result!.response!.content, 'final summary');
        expect(cm.calls, 2);
      });
    });

    // Adapted: Go returns "partial output" together with the error; a Dart
    // model can only throw, so the attempt carries the error and no response.
    test('delegates to generateAndEmit without retry config', () async {
      final cm = _fails('generate error');
      final mw = SummarizationMiddleware(model: _Model());
      final result = await mw.generateWithRetry(ctx, cm, [Message.user('test')], null);
      expect('${result.error}', 'generate error');
      expect(result.response, isNull);
      expect(cm.calls, 1);
    });
  });

  group('TestPopulateUserMessagesInternal', () {
    test('replaces user messages section', () {
      final msgs = [Message.user('msg1'), Message.assistant('response1'), Message.user('msg2')];
      const summary = '1. Primary Request:\n'
          '   test\n'
          '\n'
          '6. All user messages:\n'
          '<all_user_messages>\n'
          '    - [old message]\n'
          '</all_user_messages>\n'
          '\n'
          '7. Pending Tasks:\n'
          '   - task1';
      final result = replaceUserMessagesInSummary(msgs, summary);
      expect(result, contains('msg1'));
      expect(result, contains('msg2'));
      expect(result, isNot(contains('old message')));
      expect(result, contains('7. Pending Tasks:'));
    });

    test('returns original if no matching sections', () {
      const summary = 'summary without sections';
      final result = replaceUserMessagesInSummary([Message.user('test')], summary);
      expect(result, summary);
    });

    test('skips summary messages', () {
      final summaryMsg = withSummarizationContentType(
        const Message(role: RoleType.user, content: 'summary'),
        contentTypeSummary,
      );
      final msgs = [summaryMsg, Message.user('regular message')];
      const summary = '6. All user messages:\n'
          '<all_user_messages>\n'
          '    - [old]\n'
          '</all_user_messages>\n'
          '\n'
          '7. Pending Tasks:\n'
          '   - task';
      final result = replaceUserMessagesInSummary(msgs, summary);
      expect(result, contains('regular message'));
      expect(result, isNot(contains('    - summary')));
    });

    test('returns original if empty user messages', () {
      const summary = '6. All user messages:\n'
          '    - [old]\n'
          '\n'
          '7. Pending Tasks:\n'
          '   - task';
      final result = replaceUserMessagesInSummary([Message.assistant('response')], summary);
      expect(result, summary);
    });
  });

  group('TestAllUserMessagesTagRegexMatch', () {
    test('matches xml tag', () {
      expect(allUserMessagesTagRegex.hasMatch('<all_user_messages>\n    - msg\n</all_user_messages>'), isTrue);
    });

    test('does not match without tag', () {
      expect(allUserMessagesTagRegex.hasMatch('6. All user messages:\n    - msg'), isFalse);
    });
  });

  group('TestDefaultTrimUserMessage', () {
    test('returns nil for zero remaining tokens', () {
      expect(defaultTrimUserMessage(Message.user('test'), 0), isNull);
    });

    test('returns nil for empty content', () {
      expect(defaultTrimUserMessage(Message.user(''), 100), isNull);
    });

    test('trims long message', () {
      final longText = 'a' * 3000;
      final result = defaultTrimUserMessage(Message.user(longText), 100);
      expect(result, isNotNull);
      expect(utf8.encode(result!.content).length, lessThan(utf8.encode(longText).length));
    });
  });

  group('TestDefaultTokenCounter', () {
    test('counts tool tokens', () {
      final count = defaultSummarizationTokenCount(
        const TokenCounterInput(
          messages: [],
          tools: [ToolInfo(function: FunctionInfo(name: 'test_tool', description: 'description'))],
        ),
      );
      expect(count, greaterThan(0));
    });

    test('reuses latest assistant total tokens as baseline', () {
      final count = defaultSummarizationTokenCount(
        TokenCounterInput(
          messages: [
            Message.user('earlier context'),
            _assistantWithUsage('baseline'),
            Message.user('later context'),
          ],
        ),
      );
      expect(count, 100 + estimateMessageTokens(Message.user('later context')));
    });
  });

  group('TestGetAssistantTotalTokens', () {
    test('returns zero for nil message', () {
      expect(assistantTotalTokens(null), 0);
    });

    test('reads total tokens from assistant messages only', () {
      const msg = Message(
        role: RoleType.assistant,
        responseMeta: ResponseMeta(
          usage: TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 42),
        ),
      );
      expect(assistantTotalTokens(msg), 42);
      expect(assistantTotalTokens(Message.user('ignored')), 0);
    });
  });

  group('TestEstimateMessageTokens', () {
    test('returns zero for nil message', () {
      expect(estimateMessageTokens(null), 0);
    });

    test('counts assistant text reasoning and tool calls', () {
      const msg = Message(
        role: RoleType.assistant,
        reasoningContent: 'reason',
        toolCalls: [ToolCall(id: '', function: FunctionCall(name: 'tool', arguments: '{"k":"v"}'))],
        assistantGenMultiContent: [MessageOutputPart(type: ChatMessagePartType.text, text: 'answer')],
      );
      const expectedLen = 'answer'.length + 'reason'.length + 'tool'.length + '{"k":"v"}'.length;
      expect(estimateMessageTokens(msg), estimateTokenCount(expectedLen));
    });

    test('adds multimodal estimate for user content', () {
      const msg = Message(
        role: RoleType.user,
        userInputMultiContent: [
          MessageInputPart(type: ChatMessagePartType.text, text: 'hello'),
          MessageInputPart(type: ChatMessagePartType.imageUrl),
        ],
      );
      // `multimodalTokenEstimate` is private in the port: 2000, as in Go.
      const multimodalTokenEstimate = 2000;
      expect(estimateMessageTokens(msg), estimateTokenCount('hello'.length) + multimodalTokenEstimate);
    });
  });

  group('TestPostProcessSummary', () {
    test('with transcript path', () {
      final result = postProcessSummary(
        contextMessages: const [],
        summaryContent: 'summary content',
        transcriptPath: '/path/to/transcript.txt',
      );
      expect(result.content, contains('/path/to/transcript.txt'));
      expect(result.content, contains(getContinueInstruction()));
    });
  });

  // `emitEvent` and `emitGenerateSummaryEvent` are private in the port; they
  // are reached through `summarize` (whose first step is the before event)
  // and `generateWithRetry` (whose attempt sends the generate event and, as
  // in Go, returns a failure to send it as the attempt's error).
  group('TestEventHelpers', () {
    test('emitEvent returns wrapped error outside execution context', () async {
      final cm = _returns('ok');
      final mw = SummarizationMiddleware(model: cm, emitInternalEvents: true);
      await expectLater(
        mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')])),
        _throwsContaining('failed to send internal event'),
      );
      expect(cm.calls, 0);
    });

    test('emitGenerateSummaryEvent is skipped when internal events are disabled', () async {
      final mw = SummarizationMiddleware(model: _Model());
      final result = await mw.generateWithRetry(ctx, _returns('ok'), [Message.user('test')], null);
      expect(result.error, isNull);
      expect(result.response?.content, 'ok');
    });

    test('emitGenerateSummaryEvent returns wrapped error when enabled outside execution context', () async {
      final mw = SummarizationMiddleware(model: _Model(), emitInternalEvents: true);
      final result = await mw.generateWithRetry(ctx, _returns('ok'), [Message.user('test')], null);
      expect(result.error, isNotNull);
      expect('${result.error}', contains('failed to send internal event'));
    });
  });

  group('TestGetFailoverModel', () {
    final defaultInput = [Message.user('default')];
    // Go's `&FailoverContext{Attempt: 1}`; the instructions are required here.
    final fctx = SummarizationFailoverContext(
      attempt: 1,
      systemInstruction: Message.system(''),
      userInstruction: Message.user(''),
      originalMessages: const [],
    );

    test('requires failover config', () async {
      final mw = SummarizationMiddleware(model: _Model());
      await expectLater(
        mw.getFailoverModel(ctx, fctx, defaultInput),
        _throwsContaining('failover config is required'),
      );
    });

    test('uses primary model and default input when callback is not provided', () async {
      final primary = _Model();
      final mw = SummarizationMiddleware(model: primary, failover: const SummarizationFailoverConfig());
      final (mdl, input) = await mw.getFailoverModel(ctx, fctx, defaultInput);
      expect(mdl, same(primary));
      expect(input, defaultInput);
    });

    test('wraps callback error', () async {
      final mw = SummarizationMiddleware(
        model: _Model(),
        failover: SummarizationFailoverConfig(getFailoverModel: (ctx, fc) => throw const _GoError('boom')),
      );
      await expectLater(
        mw.getFailoverModel(ctx, fctx, defaultInput),
        _throwsContaining('failed to get failover model'),
      );
    });

    test('requires non empty failover input', () async {
      final failoverModel = _Model();
      final mw = SummarizationMiddleware(
        model: _Model(),
        failover: SummarizationFailoverConfig(getFailoverModel: (ctx, fc) => (failoverModel, const <Message>[])),
      );
      await expectLater(
        mw.getFailoverModel(ctx, fctx, defaultInput),
        _throwsContaining('failover model input messages are required'),
      );
    });

    test('returns custom failover model and input', () async {
      final failoverModel = _Model();
      final customInput = [Message.user('custom')];
      final mw = SummarizationMiddleware(
        model: _Model(),
        failover: SummarizationFailoverConfig(getFailoverModel: (ctx, fc) => (failoverModel, customInput)),
      );
      final (mdl, input) = await mw.getFailoverModel(ctx, fctx, defaultInput);
      expect(mdl, same(failoverModel));
      expect(input, hasLength(1));
      expect(input[0].content, 'custom');
    });
  });

  group('TestHelperBranches', () {
    // `typedShouldFailover` is private in the port: each Go assertion is
    // observed through `summarize`, whose failover decision it makes.
    group('should failover branches', () {
      test('nil config with an error: no failover', () async {
        final cm = _fails('x');
        final mw = SummarizationMiddleware(model: cm);
        await expectLater(
          mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')])),
          _throwsContaining('failed to generate summary: x'),
        );
        expect(cm.calls, 1);
      });

      // Go passes a nil response and a nil error; a Dart model always answers
      // something, so an answer without an error stands in for it.
      test('empty config without an error: no failover', () async {
        final cm = _returns('ok');
        final mw = SummarizationMiddleware(model: cm, failover: const SummarizationFailoverConfig());
        await mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')]));
        expect(cm.calls, 1);
      });

      test('empty config with an error: failover', () async {
        final cm = _Model((_, call) => call == 1 ? throw const _GoError('x') : Message.assistant('ok'));
        final mw = SummarizationMiddleware(model: cm, failover: const SummarizationFailoverConfig());
        await mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')]));
        expect(cm.calls, 2);
      });

      test('custom ShouldFailover on a response without error: failover', () async {
        final cm = _returns('ok');
        var failoverCalls = 0;
        final mw = SummarizationMiddleware(
          model: cm,
          failover: SummarizationFailoverConfig(
            maxRetries: 1,
            shouldFailover: (ctx, resp, err) => resp != null && err == null,
            getFailoverModel: (ctx, fc) {
              failoverCalls++;
              return (_fails('failover error'), [Message.user('failover input')]);
            },
          ),
        );
        await expectLater(
          mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')])),
          _throwsContaining('failover error'),
        );
        expect(failoverCalls, 1);
      });
    });

    // Go's `RetryConfig.check`, `FailoverConfig.check` and
    // `TriggerCondition.check` → the constructor.
    test('config check branches', () {
      expect(
        () => SummarizationMiddleware(model: _Model(), retry: const SummarizationRetryConfig(maxRetries: -1)),
        _throwsContaining('retry.MaxRetries must be non-negative'),
      );
      expect(
        () => SummarizationMiddleware(model: _Model(), failover: const SummarizationFailoverConfig(maxRetries: -1)),
        _throwsContaining('failover.MaxRetries must be non-negative'),
      );
      expect(
        () => SummarizationMiddleware(model: _Model(), trigger: const SummarizationTrigger()),
        _throwsContaining('at least one of contextTokens or contextMessages'),
      );
      expect(
        () => SummarizationMiddleware(model: _Model(), trigger: const SummarizationTrigger(contextTokens: -1)),
        _throwsContaining('contextTokens must be non-negative'),
      );
      expect(
        () => SummarizationMiddleware(
          model: _Model(),
          trigger: const SummarizationTrigger(contextMessages: -1, contextTokens: 1),
        ),
        _throwsContaining('contextMessages must be non-negative'),
      );
    });

    test('default backoff branches', () {
      expect(defaultSummaryBackoff(0), const Duration(seconds: 1));
      final delay = defaultSummaryBackoff(8);
      expect(delay, greaterThanOrEqualTo(const Duration(seconds: 10)));
      expect(delay, lessThan(const Duration(seconds: 15)));
    });

    test('user messages replaced note is present', () {
      final note = getUserMessagesReplacedNote();
      expect(note, isNotEmpty);
      expect([userMessagesReplacedNote, userMessagesReplacedNoteZh], contains(note));
    });
  });

  group('TestSummarize', () {
    test('basic summarization', () async {
      final cm = _returns('Summary content');
      final mw = SummarizationMiddleware(model: cm);
      final result = await mw.summarize(
        ctx,
        ChatModelAgentState(
          messages: [
            Message.system('You are a helpful assistant'),
            Message.user(_a100),
            Message.assistant(_b100),
          ],
        ),
      );
      expect(result, isNotEmpty);
      expect(result[0].role, RoleType.system);
      expect(cm.calls, 1);
    });

    test('model error propagates', () async {
      final cm = _fails('model error');
      final mw = SummarizationMiddleware(model: cm);
      await expectLater(
        mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')])),
        throwsA(anything),
      );
      expect(cm.calls, 1);
    });

    test('retry works', () async {
      final cm = _Model(
        (_, call) => call == 1 ? throw const _GoError('transient error') : Message.assistant('Summary after retry'),
      );
      final mw = SummarizationMiddleware(
        model: cm,
        retry: const SummarizationRetryConfig(maxRetries: 2, backoff: _zeroBackoff),
      );
      final result = await mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')]));
      expect(result, isNotEmpty);
      expect(cm.calls, 2);
    });

    test('failover works', () async {
      final primary = _fails('primary error');
      final failoverModel = _returns('Summary from failover');
      final mw = SummarizationMiddleware(
        model: primary,
        failover: SummarizationFailoverConfig(
          getFailoverModel: (ctx, fc) => (failoverModel, [Message.user('failover input')]),
        ),
      );
      final result = await mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')]));
      expect(result, isNotEmpty);
      expect(primary.calls, 1);
      expect(failoverModel.calls, 1);
    });

    test('callback is invoked', () async {
      final cm = _returns('Summary');
      var callbackCalled = false;
      int? beforeLength;
      int? afterLength;
      final mw = SummarizationMiddleware(
        model: cm,
        callback: (ctx, before, after) {
          callbackCalled = true;
          beforeLength = before.messages.length;
          afterLength = after.messages.length;
        },
      );
      final result = await mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')]));
      expect(result, isNotNull);
      expect(callbackCalled, isTrue);
      expect(beforeLength, 1);
      expect(afterLength, greaterThan(0));
      expect(cm.calls, 1);
    });

    test('custom finalize is used', () async {
      final cm = _returns('Summary');
      final mw = SummarizationMiddleware(
        model: cm,
        finalize: (ctx, originalMessages, summary) => [Message.system('custom system'), summary],
      );
      final result = await mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')]));
      expect(result, hasLength(2));
      expect(result[0].role, RoleType.system);
      expect(result[0].content, 'custom system');
      expect(cm.calls, 1);
    });

    test('callback error propagates', () async {
      final cm = _returns('Summary');
      final mw = SummarizationMiddleware(
        model: cm,
        callback: (ctx, before, after) => throw const _GoError('callback error'),
      );
      await expectLater(
        mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')])),
        _throwsContaining('callback error'),
      );
      expect(cm.calls, 1);
    });

    test('finalize error propagates', () async {
      final cm = _returns('Summary');
      final mw = SummarizationMiddleware(
        model: cm,
        finalize: (ctx, originalMessages, summary) => throw const _GoError('finalize error'),
      );
      await expectLater(
        mw.summarize(ctx, ChatModelAgentState(messages: [Message.user('hello')])),
        _throwsContaining('finalize error'),
      );
      expect(cm.calls, 1);
    });

    test('preserves system messages', () async {
      final cm = _returns('Summary');
      final mw = SummarizationMiddleware(model: cm);
      final result = await mw.summarize(
        ctx,
        ChatModelAgentState(
          messages: [Message.system('System 1'), Message.system('System 2'), Message.user(_a100)],
        ),
      );
      expect(result, hasLength(3));
      expect(result[0].role, RoleType.system);
      expect(result[0].content, 'System 1');
      expect(result[1].role, RoleType.system);
      expect(result[1].content, 'System 2');
      expect(cm.calls, 1);
    });
  });

  group('TestGetAssistantTextContent', () {
    test('schema.Message with MultiContent', () {
      const msg = Message(
        role: RoleType.assistant,
        content: 'fallback content',
        assistantGenMultiContent: [
          MessageOutputPart(type: ChatMessagePartType.text, text: 'hello'),
          MessageOutputPart(type: ChatMessagePartType.text, text: 'world'),
        ],
      );
      expect(assistantTextContent(msg), 'hello\nworld');
    });

    test('schema.Message with MultiContent skips non-text parts', () {
      const msg = Message(
        role: RoleType.assistant,
        content: 'fallback',
        assistantGenMultiContent: [
          MessageOutputPart(type: ChatMessagePartType.text, text: 'text part'),
          MessageOutputPart(type: ChatMessagePartType.imageUrl),
          MessageOutputPart(type: ChatMessagePartType.text, text: ''),
        ],
      );
      expect(assistantTextContent(msg), 'text part');
    });

    test('schema.Message falls back to Content when MultiContent is empty', () {
      const msg = Message(role: RoleType.assistant, content: 'plain content');
      expect(assistantTextContent(msg), 'plain content');
    });

    test('schema.Message falls back to Content when MultiContent has no text', () {
      const msg = Message(
        role: RoleType.assistant,
        content: 'fallback',
        assistantGenMultiContent: [MessageOutputPart(type: ChatMessagePartType.imageUrl)],
      );
      expect(assistantTextContent(msg), 'fallback');
    });
  });
}
